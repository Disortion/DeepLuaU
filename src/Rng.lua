--!strict
-- Deterministic xorshift32 RNG so a given seed always yields the same build.
local Rng = {}
Rng.__index = Rng

function Rng.new(seed)
	seed = (seed or 0) % 4294967296
	if seed == 0 then seed = 0x9E3779B9 end
	return setmetatable({ s = seed }, Rng)
end

function Rng:next() -- returns 32-bit integer
	local s = self.s
	s = bit32.bxor(s, bit32.lshift(s, 13))
	s = bit32.bxor(s, bit32.rshift(s, 17))
	s = bit32.bxor(s, bit32.lshift(s, 5))
	self.s = s
	return s
end

function Rng:float() return self:next() / 4294967296 end

function Rng:int(lo, hi)
	if hi < lo then return lo end
	local span = hi - lo + 1
	return lo + (self:next() % span)
end

function Rng:chance(p) return self:float() < p end

function Rng:pick(list) return list[self:int(1, #list)] end

function Rng:shuffle(list)
	for i = #list, 2, -1 do
		local j = self:int(1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

return Rng
