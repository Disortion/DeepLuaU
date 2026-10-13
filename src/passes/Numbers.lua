--!strict
-- DeepLuaU number-obfuscation pass.
-- Rewrites integer literals as arithmetic expressions (sums/differences/products,
-- sometimes in hex). Luau's compiler constant-folds constant arithmetic, so the
-- emitted bytecode is identical to the original literal => ZERO runtime cost, while
-- the source no longer shows the real constants.

local Numbers = {}

-- parse an integer-valued literal; returns value or nil if not a plain integer
local function intValue(raw)
	local s = raw:gsub("_", "")
	if s:find("[eEpP.]") then return nil end -- float / hex-float / exponent: skip
	if s:match("^0[bB]") then
		local bits = s:sub(3)
		if bits == "" or bits:match("[^01]") then return nil end
		local v = 0
		for i = 1, #bits do v = v * 2 + (bits:byte(i) - 48) end
		return v
	end
	if s:match("^0[xX]") then
		local v = tonumber(s)
		return v
	end
	if s:match("^%d+$") then
		return tonumber(s)
	end
	return nil
end

local function num(raw)
	return { kind = "Number", raw = raw }
end

-- build an expression tree that evaluates to v (v is a non-negative integer)
local function encode(v, rng, depth)
	-- base cases / termination
	if depth <= 0 or v == 0 then
		if rng:chance(0.5) and v >= 0 and v < 2 ^ 31 then
			return num(string.format("0x%X", v))
		end
		return num(tostring(v))
	end
	local pick = rng:int(1, 3)
	if pick == 1 then
		-- v = a + b
		local a = rng:int(0, v)
		local b = v - a
		return { kind = "Binop", op = "+",
			lhs = encode(a, rng, depth - 1), rhs = encode(b, rng, depth - 1) }
	elseif pick == 2 then
		-- v = c - d, c > v
		local d = rng:int(1, math.max(1, v + 16))
		local c = v + d
		return { kind = "Binop", op = "-",
			lhs = encode(c, rng, depth - 1), rhs = encode(d, rng, depth - 1) }
	else
		-- v = f * g (+ r), using a small factor
		local f = rng:int(2, 9)
		local g = v // f
		local r = v - f * g
		local prod = { kind = "Binop", op = "*",
			lhs = encode(f, rng, depth - 1), rhs = encode(g, rng, depth - 1) }
		if r == 0 then return prod end
		return { kind = "Binop", op = "+", lhs = prod, rhs = encode(r, rng, depth - 1) }
	end
end

-- walk the AST and transform Number nodes in place (wrapped in Paren)
local function walk(node, rng, maxDepth, visited)
	if type(node) ~= "table" then return end
	if visited[node] then return end
	visited[node] = true

	if node.kind == "Number" then
		local v = intValue(node.raw)
		if v and v >= 0 and v < 2 ^ 53 then
			local expr = encode(v, rng, maxDepth)
			if expr.kind ~= "Number" then
				node.kind = "Paren"
				node.expr = expr
				node.raw = nil
			end
		end
		return
	end
	if node.kind == "Raw" then return end -- don't descend into injected source

	for key, child in pairs(node) do
		if type(child) == "table" and key ~= "str" then
			walk(child, rng, maxDepth, visited)
		end
	end
end

function Numbers.run(ast, ctx)
	local depth = (ctx.opts.numberDepth) or 2
	walk(ast, ctx.rng, depth, {})
	return ast
end

Numbers._intValue = intValue
return Numbers
