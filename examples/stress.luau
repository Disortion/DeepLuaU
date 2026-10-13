-- coroutines
local co = coroutine.create(function(a, b)
	local c = coroutine.yield(a + b)
	return c * 2
end)
local _, s1 = coroutine.resume(co, 3, 4)
local _, s2 = coroutine.resume(co, 10)
print(s1, s2)

-- pcall / error with table values
local ok, err = pcall(function() error({ code = 42, msg = "boom" }) end)
print(ok, type(err), err.code, err.msg)

-- metatable __index chain + __call + __add
local Base = {}; Base.__index = Base
function Base.new(v) return setmetatable({ v = v }, Base) end
function Base:double() return self.v * 2 end
local Derived = setmetatable({}, { __index = Base })
Derived.__index = Derived
setmetatable(Derived, { __index = Base })
function Derived.new(v) local o = Base.new(v); return setmetatable(o, Derived) end
function Derived:triple() return self.v * 3 end
local d = Derived.new(5)
print(d:double(), d:triple())

local callable = setmetatable({}, { __call = function(self, x) return x + 1 end })
print(callable(41))
local addable = setmetatable({ n = 1 }, { __add = function(a, b) return a.n + b end })
print(addable + 9)

-- varargs packed into table, select, table.pack/unpack
local function pack(...) return { n = select("#", ...), ... } end
local p = pack("a", nil, "c")
print(p.n, p[1], p[3])
print(table.unpack({ 7, 8, 9 }))

-- string library heavy
local str = "Hello, World 123"
print(str:lower(), str:upper())
print(str:gsub("%d", "#"))
print(str:find("World"))
local out = {}
for word in str:gmatch("%a+") do out[#out + 1] = word end
print(table.concat(out, "|"))
print(string.format("%d-%s-%.2f", 5, "x", 3.14159))

-- numeric precision sanity
print(2^53, 0.1 + 0.2, math.floor(7.9), 10 % 3, 17 // 5)

-- closures capturing loop (fresh var per iteration)
local fns = {}
for i = 1, 3 do fns[i] = function() return i end end
print(fns[1](), fns[2](), fns[3]())

-- deeply nested + recursion
local function fib(n) if n < 2 then return n end return fib(n-1) + fib(n-2) end
print(fib(10))
