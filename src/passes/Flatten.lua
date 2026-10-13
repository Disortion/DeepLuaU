--!strict
-- DeepLuaU control-flow flattening pass (profile "max").
--
-- Converts the linear statement spine of each function body and the chunk into a
-- state-machine dispatch loop:
--
--     local STATE = <start>
--     while STATE ~= 0 do
--         if     STATE == k1 then <stmtA>; STATE = k2
--         elseif STATE == k3 then <stmtB>; STATE = 0
--         elseif STATE == k2 then <stmtC>; STATE = k3
--         ...
--         end
--     end
--
-- State ids are a random permutation and the dispatch branches are shuffled, so the
-- original ordering is destroyed. Top-level `local`s are hoisted to shared slots so
-- their values survive across states. Nested control structures (loops, ifs) are
-- kept intact as opaque units -- so `break`/`continue` keep targeting their real
-- loop -- and nested functions are flattened independently.
--
-- COST: this adds a dispatch loop per flattened function, so it is NOT free. Use the
-- "max" profile on cold / non-hot modules, not on per-frame render code.

local Flatten = {}

local function nameNode(n) return { kind = "Name", name = n } end
local function numNode(v) return { kind = "Number", raw = tostring(v) } end

-- collect every identifier already present so injected names never collide
local function collectNames(root)
	local used = {}
	local seen = {}
	local function walk(node)
		if type(node) ~= "table" or seen[node] then return end
		seen[node] = true
		if node.kind == "Raw" then return end
		if type(node.name) == "string" then used[node.name] = true end
		if type(node.method) == "string" then used[node.method] = true end
		for k, v in pairs(node) do
			if type(v) == "table" then walk(v) end
		end
	end
	walk(root)
	return used
end

-- gather the chunk block plus every function body block
local function collectBlocks(ast)
	local blocks = { ast }
	local seen = {}
	local function walk(node)
		if type(node) ~= "table" or seen[node] then return end
		seen[node] = true
		if node.kind == "Raw" then return end
		if node.kind == "Function" and type(node.body) == "table" then
			blocks[#blocks + 1] = node.body
		end
		for _, v in pairs(node) do
			if type(v) == "table" then walk(v) end
		end
	end
	walk(ast)
	return blocks
end

local function flattenBlock(block, ctx, freshName)
	local stats = block.stats
	if #stats < 3 then return end
	-- bail if a top-level break/continue is present (would retarget the dispatcher)
	for _, s in ipairs(stats) do
		if s.kind == "Break" or s.kind == "Continue" then return end
	end

	local n = #stats
	-- random distinct nonzero state ids
	local ids = {}
	for i = 1, n do ids[i] = i end
	ctx.rng:shuffle(ids)

	local stateVar = freshName()
	local hoist = {}        -- hoisted local names, in order
	local hoistSeen = {}
	local branches = {}     -- { id, body = {stats}, }

	for idx, s in ipairs(stats) do
		local body = {}
		local isReturn = false
		if s.kind == "LocalAssign" then
			for _, nm in ipairs(s.names) do
				if not hoistSeen[nm.name] then
					hoistSeen[nm.name] = true
					hoist[#hoist + 1] = nm.name
				end
			end
			if #s.exprs > 0 then
				local targets = {}
				for _, nm in ipairs(s.names) do targets[#targets + 1] = nameNode(nm.name) end
				body[#body + 1] = { kind = "Assign", targets = targets, exprs = s.exprs }
			end
		elseif s.kind == "LocalFunction" then
			if not hoistSeen[s.name] then
				hoistSeen[s.name] = true
				hoist[#hoist + 1] = s.name
			end
			body[#body + 1] = {
				kind = "Assign",
				targets = { nameNode(s.name) },
				exprs = { s.body },
			}
		elseif s.kind == "Return" then
			isReturn = true
			body[#body + 1] = s
		else
			body[#body + 1] = s
		end

		if not isReturn then
			local nextId = (idx < n) and ids[idx + 1] or 0
			body[#body + 1] = {
				kind = "Assign",
				targets = { nameNode(stateVar) },
				exprs = { numNode(nextId) },
			}
		end
		branches[idx] = { id = ids[idx], body = body }
	end

	-- build shuffled dispatch order
	local order = {}
	for i = 1, n do order[i] = i end
	ctx.rng:shuffle(order)

	local clauses = {}
	for _, idx in ipairs(order) do
		local b = branches[idx]
		clauses[#clauses + 1] = {
			cond = { kind = "Binop", op = "==", lhs = nameNode(stateVar), rhs = numNode(b.id) },
			body = { kind = "Block", stats = b.body },
		}
	end
	local ifStat = { kind = "If", clauses = clauses, elseBody = nil }
	local whileStat = {
		kind = "While",
		cond = { kind = "Binop", op = "~=", lhs = nameNode(stateVar), rhs = numNode(0) },
		body = { kind = "Block", stats = { ifStat } },
	}

	local newStats = {}
	if #hoist > 0 then
		local names = {}
		for _, h in ipairs(hoist) do names[#names + 1] = { name = h } end
		newStats[#newStats + 1] = { kind = "LocalAssign", names = names, exprs = {} }
	end
	newStats[#newStats + 1] = {
		kind = "LocalAssign",
		names = { { name = stateVar } },
		exprs = { numNode(ids[1]) },
	}
	newStats[#newStats + 1] = whileStat
	block.stats = newStats
end

function Flatten.run(ast, ctx)
	local used = collectNames(ast)
	local counter = 0
	local function freshName()
		while true do
			counter += 1
			local candidate = "_DLUf" .. counter
			if not used[candidate] then
				used[candidate] = true
				return candidate
			end
		end
	end

	local blocks = collectBlocks(ast)
	for _, block in ipairs(blocks) do
		flattenBlock(block, ctx, freshName)
	end
	return ast
end

return Flatten
