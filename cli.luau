--!strict
-- DeepLuaU command-line interface (for the Lune runtime: https://lune-rs.github.io).
--
-- Usage:
--   lune run cli.luau -- <input.luau> [options]
--
-- Options:
--   -o, --output <file>     write result to <file> (default: stdout)
--   -p, --profile <name>    none | light | balanced | max   (default: balanced)
--   -s, --seed <number>     deterministic seed (default: random per run)
--   --no-header             omit the "Protected with DeepLuaU" banner comment
--   -h, --help              show this help
--
-- Examples:
--   lune run cli.luau -- game/client.luau -o out/client.luau -p balanced -s 123
--   lune run cli.luau -- module.luau -p max > module.obf.luau

local fs = require("@lune/fs")
local process = require("@lune/process")
local Obfuscator = require("./dist/deepluau")

local function die(msg)
	process.stdout:write("error: " .. msg .. "\n")
	process.exit(1)
end

local HELP = [[DeepLuaU -- Luau source obfuscator

Usage: lune run cli.luau -- <input.luau> [options]

Options:
  -o, --output <file>   write result to <file> (default: stdout)
  -p, --profile <name>  none | light | balanced | max  (default: balanced)
  -s, --seed <number>   deterministic seed (default: random)
      --no-header       omit the banner comment
  -h, --help            show this help
]]

local args = process.args
local input, output, profile, seed = nil, nil, "balanced", nil
local header = true

local i = 1
while i <= #args do
	local a = args[i]
	if a == "-h" or a == "--help" then
		process.stdout:write(HELP)
		process.exit(0)
	elseif a == "-o" or a == "--output" then
		i += 1; output = args[i]
	elseif a == "-p" or a == "--profile" then
		i += 1; profile = args[i]
	elseif a == "-s" or a == "--seed" then
		i += 1; seed = tonumber(args[i])
		if not seed then die("--seed expects a number") end
	elseif a == "--no-header" then
		header = false
	elseif a:sub(1, 1) == "-" then
		die("unknown option: " .. a)
	else
		if input then die("multiple input files given") end
		input = a
	end
	i += 1
end

if not input then
	process.stdout:write(HELP)
	process.exit(1)
end
if not fs.isFile(input) then die("input file not found: " .. input) end

local source = fs.readFile(input)
local ok, result = pcall(Obfuscator.obfuscate, source, {
	profile = profile,
	seed = seed,
	header = header,
})
if not ok then die("obfuscation failed: " .. tostring(result)) end

if output then
	fs.writeFile(output, result)
	process.stdout:write(("DeepLuaU: %s -> %s  (profile=%s, %d -> %d bytes)\n")
		:format(input, output, profile, #source, #result))
else
	process.stdout:write(result)
end
