--!strict
-- DeepLuaU Lexer
-- Tokenizes Luau source into a flat token stream for the parser.
-- Handles: identifiers/keywords, all numeric forms (dec/hex/binary, underscores,
-- floats, exponents), short and long strings, long/short comments, every operator
-- and compound-assignment operator, type-annotation punctuation (:, ::), attributes
-- (@native, @checked ...) and backtick interpolated strings.

local Lexer = {}
Lexer.__index = Lexer

local KEYWORDS = {
	["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
	["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
	["function"] = true, ["if"] = true, ["in"] = true, ["local"] = true,
	["nil"] = true, ["not"] = true, ["or"] = true, ["repeat"] = true,
	["return"] = true, ["then"] = true, ["true"] = true, ["until"] = true,
	["while"] = true,
}

local function isDigit(c) return c >= "0" and c <= "9" end
local function isHex(c)
	return (c >= "0" and c <= "9") or (c >= "a" and c <= "f") or (c >= "A" and c <= "F")
end
local function isAlpha(c)
	return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"
end
local function isAlphaNum(c)
	return isAlpha(c) or isDigit(c)
end

function Lexer.new(source)
	return setmetatable({
		src = source,
		pos = 1,
		line = 1,
		len = #source,
		tokens = {},
	}, Lexer)
end

function Lexer:error(msg)
	error(("DeepLuaU lex error (line %d): %s"):format(self.line, msg), 0)
end

function Lexer:peek(o)
	local i = self.pos + (o or 0)
	if i > self.len then return "" end
	return self.src:sub(i, i)
end

function Lexer:advance()
	local c = self.src:sub(self.pos, self.pos)
	self.pos += 1
	if c == "\n" then self.line += 1 end
	return c
end

function Lexer:match(s)
	if self.src:sub(self.pos, self.pos + #s - 1) == s then
		for _ = 1, #s do self:advance() end
		return true
	end
	return false
end

-- Reads a long bracket body [[ ]], [=[ ]=], ... returns (content, level) or nil.
function Lexer:tryLongBracket()
	local start = self.pos
	if self:peek() ~= "[" then return nil end
	local p = self.pos + 1
	local level = 0
	while self.src:sub(p, p) == "=" do level += 1; p += 1 end
	if self.src:sub(p, p) ~= "[" then return nil end
	-- consume opening
	self.pos = p + 1
	-- skip a leading newline per Lua spec
	if self:peek() == "\r" then self:advance() end
	if self:peek() == "\n" then self:advance() end
	local close = "]" .. string.rep("=", level) .. "]"
	local idx = self.src:find(close, self.pos, true)
	if not idx then
		self.pos = start
		self:error("unterminated long bracket")
	end
	local content = self.src:sub(self.pos, idx - 1)
	-- advance over content + close, counting newlines
	for _ = self.pos, idx + #close - 1 do self:advance() end
	return content, level
end

function Lexer:readShortString(quote)
	local buf = {}
	self:advance() -- opening quote
	while true do
		local c = self:peek()
		if c == "" or c == "\n" then self:error("unterminated string") end
		if c == quote then self:advance(); break end
		if c == "\\" then
			self:advance()
			local e = self:advance()
			buf[#buf + 1] = "\\" .. e
			-- multi-char escapes (\ddd, \xHH, \u{...}, \z) are preserved verbatim;
			-- subsequent chars handled on next loop iterations.
		else
			buf[#buf + 1] = self:advance()
		end
	end
	return table.concat(buf)
end

-- Backtick interpolated string -> captured raw; parser treats it opaquely.
function Lexer:readInterpString()
	local buf = {}
	self:advance() -- opening backtick
	local depth = 0
	while true do
		local c = self:peek()
		if c == "" then self:error("unterminated interpolated string") end
		if c == "\\" then
			buf[#buf + 1] = self:advance()
			buf[#buf + 1] = self:advance()
		elseif c == "{" then
			depth += 1; buf[#buf + 1] = self:advance()
		elseif c == "}" then
			if depth > 0 then depth -= 1 end
			buf[#buf + 1] = self:advance()
		elseif c == "`" and depth == 0 then
			self:advance(); break
		else
			buf[#buf + 1] = self:advance()
		end
	end
	return table.concat(buf)
end

function Lexer:readNumber()
	local start = self.pos
	if self:peek() == "0" and (self:peek(1) == "x" or self:peek(1) == "X") then
		self:advance(); self:advance()
		while isHex(self:peek()) or self:peek() == "_" do self:advance() end
		-- hex float / binary exponent
		if self:peek() == "." then
			self:advance()
			while isHex(self:peek()) or self:peek() == "_" do self:advance() end
		end
		if self:peek() == "p" or self:peek() == "P" then
			self:advance()
			if self:peek() == "+" or self:peek() == "-" then self:advance() end
			while isDigit(self:peek()) or self:peek() == "_" do self:advance() end
		end
	elseif self:peek() == "0" and (self:peek(1) == "b" or self:peek(1) == "B") then
		self:advance(); self:advance()
		while self:peek() == "0" or self:peek() == "1" or self:peek() == "_" do self:advance() end
	else
		while isDigit(self:peek()) or self:peek() == "_" do self:advance() end
		if self:peek() == "." then
			self:advance()
			while isDigit(self:peek()) or self:peek() == "_" do self:advance() end
		end
		if self:peek() == "e" or self:peek() == "E" then
			self:advance()
			if self:peek() == "+" or self:peek() == "-" then self:advance() end
			while isDigit(self:peek()) or self:peek() == "_" do self:advance() end
		end
	end
	return self.src:sub(start, self.pos - 1)
end

function Lexer:add(type_, value)
	self.tokens[#self.tokens + 1] = { type = type_, value = value, line = self.line }
end

-- Ordered longest-first so multi-char operators win.
local SYMBOLS = {
	"...", "..=", "//=", "::", "->",
	"==", "~=", "<=", ">=", "..", "+=", "-=", "*=", "/=", "%=", "^=", "//",
	"+", "-", "*", "/", "%", "^", "#", "<", ">", "=", "(", ")", "{", "}",
	"[", "]", ";", ":", ",", ".", "?", "&", "|",
}

function Lexer:tokenize()
	while self.pos <= self.len do
		local c = self:peek()

		-- whitespace
		if c == " " or c == "\t" or c == "\r" or c == "\n" then
			self:advance()
		-- comments
		elseif c == "-" and self:peek(1) == "-" then
			self:advance(); self:advance()
			if self:peek() == "[" then
				local content = self:tryLongBracket()
				if content == nil then
					while self:peek() ~= "\n" and self:peek() ~= "" do self:advance() end
				end
			else
				while self:peek() ~= "\n" and self:peek() ~= "" do self:advance() end
			end
		-- long strings
		elseif c == "[" and (self:peek(1) == "[" or self:peek(1) == "=") then
			local content, level = self:tryLongBracket()
			if content ~= nil then
				self:add("String", { kind = "long", value = content, level = level })
			else
				self:advance(); self:add("Symbol", "[")
			end
		-- short strings
		elseif c == '"' or c == "'" then
			local v = self:readShortString(c)
			self:add("String", { kind = "short", value = v, quote = c })
		-- interpolated strings
		elseif c == "`" then
			local v = self:readInterpString()
			self:add("String", { kind = "interp", value = v })
		-- attributes @native @checked ...
		elseif c == "@" then
			self:advance()
			local s = self.pos
			while isAlphaNum(self:peek()) do self:advance() end
			self:add("Attribute", self.src:sub(s, self.pos - 1))
		-- numbers
		elseif isDigit(c) or (c == "." and isDigit(self:peek(1))) then
			self:add("Number", self:readNumber())
		-- identifiers / keywords
		elseif isAlpha(c) then
			local s = self.pos
			while isAlphaNum(self:peek()) do self:advance() end
			local word = self.src:sub(s, self.pos - 1)
			if KEYWORDS[word] then
				self:add("Keyword", word)
			else
				self:add("Name", word)
			end
		else
			-- symbols
			local matched = false
			for _, sym in ipairs(SYMBOLS) do
				if self:match(sym) then
					self:add("Symbol", sym)
					matched = true
					break
				end
			end
			if not matched then
				self:error("unexpected character '" .. c .. "'")
			end
		end
	end
	self:add("EOF", nil)
	return self.tokens
end

return Lexer
