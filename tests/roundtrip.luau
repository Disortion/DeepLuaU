local Parser = require("../src/Parser")
local Generator = require("../src/Generator")

local path = ...
local f = assert(io.open(path, "r"))
local src = f:read("*a"); f:close()

local ast = Parser.new(src):parse()
local out = Generator.generate(ast)
io.stdout:write(out)
