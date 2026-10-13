--!strict
-- DeepLuaU Obfuscator -- pipeline orchestrator.
--
-- Profiles (performance vs. resistance trade-off):
--   "none"      parse + minify only (debug/baseline)
--   "light"     + local renaming                         -- zero runtime cost
--   "balanced"  + string encryption + number obfuscation -- near-zero runtime cost
--               (DEFAULT: strings decrypted once at load; numbers fold at compile)
--   "max"       + control-flow flattening + junk          -- resistance over speed
--
-- The honest trade-off: "light"/"balanced" are designed to add no measurable
-- per-frame cost (ideal for game / render loops). "max" adds a dispatch loop and
-- so costs some performance; use it for cold / non-hot modules.

local Parser = require("./Parser")
local Generator = require("./Generator")
local Scope = require("./Scope")
local Rng = require("./Rng")
local Numbers = require("./passes/Numbers")
local Strings = require("./passes/Strings")
local Flatten = require("./passes/Flatten")

local Obfuscator = {}

local PROFILES = {
	none = { rename = false, strings = false, numbers = false, flatten = false },
	light = { rename = true, strings = false, numbers = false, flatten = false },
	balanced = { rename = true, strings = true, numbers = true, flatten = false },
	max = { rename = true, strings = true, numbers = true, flatten = true },
}

function Obfuscator.obfuscate(source, opts)
	opts = opts or {}
	local profileName = opts.profile or "balanced"
	local profile = PROFILES[profileName]
	if not profile then error("DeepLuaU: unknown profile '" .. tostring(profileName) .. "'", 0) end

	local seed = opts.seed or (os.time and os.time()) or 1
	local rng = Rng.new(seed)

	local ast = Parser.new(source):parse()

	local ctx = {
		rng = rng,
		seed = seed,
		opts = opts,
		poolName = "_DLU_pool",
	}

	-- string encryption (produces a prelude that declares the pool local)
	local prelude = nil
	if profile.strings then
		ast, prelude = Strings.run(ast, ctx)
	end

	-- number obfuscation (fold-safe arithmetic)
	if profile.numbers then
		Numbers.run(ast, ctx)
	end

	-- inject the string-pool prelude at the very top, before renaming so the
	-- pool variable and all its references are renamed consistently
	if prelude then
		table.insert(ast.stats, 1, prelude)
	end

	-- local renaming (names resolved & rewritten before flattening)
	if profile.rename then
		Scope.renameLocals(ast, { prefix = opts.namePrefix })
	end

	-- control-flow flattening last: operates on the renamed AST so that all name
	-- resolution is already baked into identifiers and hoisting locals is safe
	if profile.flatten then
		Flatten.run(ast, ctx)
	end

	local out = Generator.generate(ast)

	if opts.header ~= false then
		out = "--[[ Protected with DeepLuaU ]] " .. out
	end
	return out
end

Obfuscator.PROFILES = PROFILES
return Obfuscator
