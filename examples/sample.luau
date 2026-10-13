--!strict
-- a representative program exercising many Luau constructs
type Point = { x: number, y: number }
local function dist(a: Point, b: Point): number
	local dx, dy = a.x - b.x, a.y - b.y
	return math.sqrt(dx * dx + dy * dy)
end

local Vec = {}
Vec.__index = Vec
function Vec.new(x: number, y: number): Point
	return setmetatable({ x = x, y = y }, Vec)
end
function Vec:length(): number
	return dist(self, { x = 0, y = 0 })
end

local list = { 10, 20, 30, [100] = "hundred", name = "nums" }
local total = 0
for i = 1, #list do
	total += list[i]
end
for k, v in pairs({ a = 1, b = 2 }) do
	total = total + v
end

local msg = "total=" .. tostring(total) .. "\n"
local flag = if total > 50 then "big" else "small"
local n = 0xFF + 0b1010 + 3.5e1 // 2

local function counter()
	local c = 0
	return function()
		c += 1
		return c
	end
end
local next = counter()

local s = [[raw
string]]
print(dist(Vec.new(0, 0), Vec.new(3, 4)), Vec.new(1,1):length())
print(total, flag, n, next(), next(), #s, msg == "total=60\n")
local parts = ("x,y,z"):split(",")
print(parts[1], parts[2], parts[3], #parts)
local function variadic(...)
	return select("#", ...), ...
end
print(variadic(1, 2, 3))
