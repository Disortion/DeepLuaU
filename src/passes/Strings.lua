--!strict
-- DeepLuaU string-encryption pass.
-- Every short/long string literal is removed from the source and placed, encrypted,
-- into a single pool that is decrypted ONCE at load time into a local table. Each
-- literal becomes `pool[i]`, i.e. a single table index at runtime -- so there is no
-- per-call / per-frame decryption cost. Interpolated (`backtick`) strings are left
-- untouched because they contain embedded expressions.
--
-- Encryption: per-slot keystream from an xorshift32 state seeded by (seed, slot),
-- XORed byte-by-byte (bit32.bxor). Slots are stored in a shuffled order with an
-- embedded permutation table, so slot numbers in the source reveal nothing.

local Strings = {}

local KMIX = 2654435761 -- Knuth multiplicative constant

local function ks(s)
	s = bit32.bxor(s, bit32.lshift(s, 13))
	s = bit32.bxor(s, bit32.rshift(s, 17))
	s = bit32.bxor(s, bit32.lshift(s, 5))
	return s
end

local function slotSeed(seed, j)
	return ((seed + j * KMIX) % 4294967295) + 1
end

-- build-time: real string value of a literal token
local function realValue(str)
	if str.kind == "long" then
		return str.value
	elseif str.kind == "short" then
		local literal = str.quote .. str.value .. str.quote
		local fn = loadstring("return " .. literal)
		if not fn then return nil end
		local ok, v = pcall(fn)
		if ok and type(v) == "string" then return v end
		return nil
	end
	return nil -- interp
end

local function encryptToLiteral(value, seed, j)
	local s = slotSeed(seed, j)
	local parts = {}
	for i = 1, #value do
		s = ks(s)
		local k = s % 256
		local enc = bit32.bxor(value:byte(i), k)
		parts[i] = "\\" .. enc
	end
	return '"' .. table.concat(parts) .. '"'
end

-- runtime decoder source (self-contained IIFE returning the pool table)
local function buildDecoderSource(dataLiterals, perm, seed)
	local data = "{" .. table.concat(dataLiterals, ",") .. "}"
	local permSrc = "{" .. table.concat(perm, ",") .. "}"
	return ([==[(function()
local d=%s
local p=%s
local SEED=%d
local function ks(s)
s=bit32.bxor(s,bit32.lshift(s,13))
s=bit32.bxor(s,bit32.rshift(s,17))
s=bit32.bxor(s,bit32.lshift(s,5))
return s
end
local pool={}
local bc=string.byte
local ch=string.char
local cc=table.concat
for j=1,#d do
local enc=d[j]
local s=((SEED+j*%d)%%4294967295)+1
local out={}
for i=1,#enc do
s=ks(s)
out[i]=ch(bit32.bxor(bc(enc,i),s%%256))
end
pool[p[j]]=cc(out)
end
return pool
end)()]==]):format(data, permSrc, seed, KMIX)
end

-- decode a backtick interpolation literal segment (with escapes) to a real string
local function decodeInterp(seg)
	local out = {}
	local i = 1
	local n = #seg
	while i <= n do
		local c = seg:sub(i, i)
		if c ~= "\\" then out[#out + 1] = c; i = i + 1
		else
			local e = seg:sub(i + 1, i + 1)
			if e == "n" then out[#out + 1] = "\n"; i = i + 2
			elseif e == "t" then out[#out + 1] = "\t"; i = i + 2
			elseif e == "r" then out[#out + 1] = "\r"; i = i + 2
			elseif e == "a" then out[#out + 1] = "\7"; i = i + 2
			elseif e == "b" then out[#out + 1] = "\8"; i = i + 2
			elseif e == "f" then out[#out + 1] = "\12"; i = i + 2
			elseif e == "v" then out[#out + 1] = "\11"; i = i + 2
			elseif e == "x" then out[#out + 1] = string.char(tonumber(seg:sub(i + 2, i + 3), 16) or 0); i = i + 4
			elseif e:match("%d") then
				local d = seg:match("^%d%d?%d?", i + 1)
				out[#out + 1] = string.char(tonumber(d) % 256); i = i + 1 + #d
			else out[#out + 1] = e; i = i + 2 end -- \{ \} \` \\ \" \' and others -> literal
		end
	end
	return table.concat(out)
end

----------------------------------------------------------------------

function Strings.run(ast, ctx)
	local seed = ctx.seed % 4294967296
	local poolName = ctx.poolName -- placeholder local name, renamed later
	local hideMembers = ctx.members and true or false

	local values = {}       -- ordered unique real values
	local indexOf = {}      -- realValue -> index

	local function slotFor(v)
		local idx = indexOf[v]
		if not idx then values[#values + 1] = v; idx = #values; indexOf[v] = idx end
		return idx
	end
	local function pool(v)
		return { kind = "Index", obj = { kind = "Name", name = poolName },
			index = { kind = "Number", raw = tostring(slotFor(v)) } }
	end

	local tx
	tx = function(node)
		if type(node) ~= "table" then return node end
		local k = node.kind
		if k == nil or k == "Raw" then return node end

		if k == "String" then
			local v = realValue(node.str)
			if v ~= nil then
				node.kind = "Index"
				node.obj = { kind = "Name", name = poolName }
				node.index = { kind = "Number", raw = tostring(slotFor(v)) }
				node.str = nil
			end
			return node
		elseif k == "InterpString" then
			local ops = {}
			for _, part in ipairs(node.parts) do
				if part.t == "str" then
					local v = decodeInterp(part.value)
					if #v > 0 then ops[#ops + 1] = pool(v) end
				else
					ops[#ops + 1] = { kind = "Call", func = { kind = "Name", name = "tostring" }, args = { tx(part.expr) } }
				end
			end
			local expr
			if #ops == 0 then expr = pool("")
			else
				expr = ops[1]
				for i = 2, #ops do expr = { kind = "Binop", op = "..", lhs = expr, rhs = ops[i] } end
			end
			for key in pairs(node) do node[key] = nil end
			node.kind = "Paren"; node.expr = expr
			return node
		elseif k == "Field" then
			node.obj = tx(node.obj)
			if hideMembers then
				local idx = pool(node.name)
				node.kind = "Index"; node.index = idx; node.name = nil
			end
			return node
		elseif k == "MethodCall" then
			node.obj = tx(node.obj)
			for i = 1, #node.args do node.args[i] = tx(node.args[i]) end
			if hideMembers and node.obj.kind == "Name" then
				local nm = node.obj.name
				local newArgs = { { kind = "Name", name = nm } }
				for _, a in ipairs(node.args) do newArgs[#newArgs + 1] = a end
				node.kind = "Call"
				node.func = { kind = "Index", obj = { kind = "Name", name = nm }, index = pool(node.method) }
				node.args = newArgs
				node.obj = nil; node.method = nil
			end
			return node
		elseif k == "FunctionDecl" then
			if hideMembers and node.target.kind == "Field" then
				local target = tx(node.target)
				local fn = tx(node.body)
				for key in pairs(node) do node[key] = nil end
				node.kind = "Assign"; node.targets = { target }; node.exprs = { fn }
				return node
			end
			node.target = tx(node.target)
			node.body = tx(node.body)
			return node
		elseif k == "Table" then
			for _, f in ipairs(node.fields) do
				if f.type == "rec" then
					f.key = tx(f.key); f.value = tx(f.value)
				elseif f.type == "name" then
					f.value = tx(f.value)
					if hideMembers then f.type = "rec"; f.key = pool(f.name); f.name = nil end
				else
					f.value = tx(f.value)
				end
			end
			return node
		else
			-- a single child node carries a `kind`; anything else table-valued is an
			-- array of nodes (stats, exprs, args, clauses, …) we recurse element-wise
			for key, child in pairs(node) do
				if type(child) == "table" and key ~= "str" then
					if child.kind ~= nil then
						node[key] = tx(child)
					else
						for i, c in ipairs(child) do child[i] = tx(c) end
					end
				end
			end
			return node
		end
	end
	for i = 1, #ast.stats do ast.stats[i] = tx(ast.stats[i]) end

	local n = #values
	if n == 0 then
		return ast, nil -- nothing to do
	end

	-- shuffled storage: data[j] encodes values[perm[j]]
	local perm = {}
	for i = 1, n do perm[i] = i end
	ctx.rng:shuffle(perm)

	local dataLiterals = {}
	for j = 1, n do
		local originalIndex = perm[j]
		dataLiterals[j] = encryptToLiteral(values[originalIndex], seed, j)
	end

	local decoder = buildDecoderSource(dataLiterals, perm, seed)
	local prelude = {
		kind = "LocalAssign",
		names = { { name = poolName } },
		exprs = { { kind = "Raw", text = decoder } },
	}
	return ast, prelude
end

Strings._ks = ks
return Strings
