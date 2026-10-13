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

----------------------------------------------------------------------

function Strings.run(ast, ctx)
	local seed = ctx.seed % 4294967296
	local poolName = ctx.poolName -- placeholder local name, renamed later

	local values = {}       -- ordered unique real values
	local indexOf = {}      -- realValue -> index
	local targets = {}      -- list of String nodes to rewrite -> index

	local function collect(node)
		local v = realValue(node.str)
		if v == nil then return nil end
		local idx = indexOf[v]
		if not idx then
			values[#values + 1] = v
			idx = #values
			indexOf[v] = idx
		end
		return idx
	end

	-- walk and rewrite String nodes in place
	local visited = {}
	local function walk(node)
		if type(node) ~= "table" or visited[node] then return end
		visited[node] = true
		if node.kind == "Raw" then return end
		if node.kind == "String" then
			local idx = collect(node)
			if idx then
				node.kind = "Index"
				node.obj = { kind = "Name", name = poolName }
				node.index = { kind = "Number", raw = tostring(idx) }
				node.str = nil
			end
			return
		end
		for key, child in pairs(node) do
			if type(child) == "table" and key ~= "str" then walk(child) end
		end
	end
	for _, s in ipairs(ast.stats) do walk(s) end

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
