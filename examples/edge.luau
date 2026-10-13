-- vararg / multiret truncation must be preserved
local function mr() return 1, 2, 3 end
local function id(...) return ... end
print(mr())            -- 1 2 3
print((mr()))          -- 1   (paren truncates)
local t = { mr() }     -- {1,2,3}
local t2 = { (mr()), 9 }
print(#t, #t2, t2[1], t2[2])
print(select("#", id(mr())))  -- 3

-- short circuit & side effects
local calls = 0
local function f(x) calls += 1; return x end
local a = f(false) and f("no") or f("yes")
print(a, calls)

-- compound assignment on fields + concat assign
local o = { n = 10, s = "a" }
o.n += 5; o.n *= 2; o.s ..= "b"
print(o.n, o.s)

-- repeat/until sees body locals; continue
local sum = 0
local i = 0
repeat
  i += 1
  if i % 2 == 0 then continue end
  local step = i
  sum += step
until i >= 7
print(sum)  -- 1+3+5+7 = 16

-- nested closures / upvalues
local function make()
  local acc = {}
  return function(x) acc[#acc+1] = x; return acc end
end
local g = make()
g("p"); local r = g("q")
print(r[1], r[2], #r)

-- string escapes and long-bracket edge
local esc = "tab\there\n\"quote\"\\slash\65"
print(#esc, esc:sub(1,3), esc:byte(#esc))
local long = [==[has ]] inside]==]
print(long)

-- numeric edge cases: these must NOT be corrupted
print(0, 1, -5, 3.14, 1e3, 0xABCDEF, 0.5, 100000000000)
local neg = -(2 ^ 10)
print(neg)

-- method chain + table key strings
local M = {}; M.__index = M
function M.new() return setmetatable({v=0}, M) end
function M:add(n) self.v += n; return self end
function M:get() return self.v end
print(M.new():add(3):add(4):get())
local keyed = { ["a b"] = 1, ["c"] = 2 }
print(keyed["a b"], keyed.c)
