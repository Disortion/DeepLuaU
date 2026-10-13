--!strict
-- DeepLuaU Parser
-- Recursive-descent parser: tokens -> AST. Parses the full Lua 5.1 grammar plus
-- Luau extensions (compound assignment, continue, if-expressions, type assertions,
-- generics and type annotations). Type annotations and `type`/`export type`
-- statements are PARSED and DROPPED: they carry no runtime meaning in Luau and
-- removing them strips information from the output.

local Lexer = require("./Lexer")

local Parser = {}
Parser.__index = Parser

-- binary operator binding powers {leftBP, rightBP}; right<left => right-assoc
local BINPRI = {
	["or"] = { 1, 1 },
	["and"] = { 2, 2 },
	["<"] = { 3, 3 }, [">"] = { 3, 3 }, ["<="] = { 3, 3 },
	[">="] = { 3, 3 }, ["~="] = { 3, 3 }, ["=="] = { 3, 3 },
	[".."] = { 9, 8 },
	["+"] = { 10, 10 }, ["-"] = { 10, 10 },
	["*"] = { 11, 11 }, ["/"] = { 11, 11 }, ["//"] = { 11, 11 }, ["%"] = { 11, 11 },
	["^"] = { 14, 13 },
}
local UNARY_PRI = 12

local COMPOUND = {
	["+="] = "+", ["-="] = "-", ["*="] = "*", ["/="] = "/",
	["//="] = "//", ["%="] = "%", ["^="] = "^", ["..="] = "..",
}

function Parser.new(source)
	local tokens = Lexer.new(source):tokenize()
	return setmetatable({ tokens = tokens, pos = 1 }, Parser)
end

function Parser:error(msg)
	local t = self.tokens[self.pos]
	error(("DeepLuaU parse error (line %s): %s (got %s %s)"):format(
		tostring(t and t.line), msg, tostring(t and t.type),
		tostring(t and (type(t.value) == "table" and "<str>" or t.value))), 0)
end

function Parser:peek(o) return self.tokens[self.pos + (o or 0)] end
function Parser:next() local t = self.tokens[self.pos]; self.pos += 1; return t end

function Parser:check(type_, value)
	local t = self.tokens[self.pos]
	if not t or t.type ~= type_ then return false end
	if value ~= nil and t.value ~= value then return false end
	return true
end

function Parser:accept(type_, value)
	if self:check(type_, value) then return self:next() end
	return nil
end

function Parser:expect(type_, value)
	local t = self:accept(type_, value)
	if not t then self:error("expected " .. type_ .. (value and (" '" .. value .. "'") or "")) end
	return t
end

function Parser:isKw(w) return self:check("Keyword", w) end
function Parser:isSym(s) return self:check("Symbol", s) end

----------------------------------------------------------------------
-- Type annotations: consumed and discarded.
----------------------------------------------------------------------

function Parser:skipGenericParams()
	-- <T, U, T..., R = Default>
	if not self:isSym("<") then return end
	self:next()
	local depth = 1
	while depth > 0 do
		local t = self:next()
		if not t or t.type == "EOF" then self:error("unterminated generic params") end
		if t.type == "Symbol" and t.value == "<" then depth += 1
		elseif t.type == "Symbol" and t.value == ">" then depth -= 1 end
	end
end

function Parser:skipTypeArgs()
	-- assumes current token is "<"; balance to matching ">"
	self:next()
	local depth = 1
	while depth > 0 do
		local t = self:next()
		if not t or t.type == "EOF" then self:error("unterminated type args") end
		if t.type == "Symbol" and t.value == "<" then depth += 1
		elseif t.type == "Symbol" and t.value == ">" then depth -= 1 end
	end
end

local CLOSE_OF = { ["("] = ")", ["{"] = "}", ["["] = "]" }

function Parser:skipBalanced(open)
	-- current token is `open`; consume through matching close, nesting-aware.
	local close = CLOSE_OF[open]
	self:next()
	local depth = 1
	while depth > 0 do
		local t = self:next()
		if not t or t.type == "EOF" then self:error("unterminated " .. open) end
		if t.type == "Symbol" then
			if t.value == open then depth += 1
			elseif t.value == close then depth -= 1 end
		end
	end
end

function Parser:skipSimpleType()
	if self:isSym("(") then
		self:skipBalanced("(")
	elseif self:isSym("{") then
		self:skipBalanced("{")
	elseif self:isSym("...") then
		self:next(); self:skipSimpleType()
	elseif self:check("String") or self:check("Number") then
		self:next()
	elseif self:check("Name") or self:isKw("nil") or self:isKw("true") or self:isKw("false")
		or self:check("Keyword", "function") then
		self:next()
		while self:isSym(".") do self:next(); self:expect("Name") end
		if self:isSym("<") then self:skipTypeArgs() end
	else
		self:error("expected a type")
	end
	while self:isSym("?") do self:next() end
end

function Parser:skipType()
	self:skipSimpleType()
	while true do
		if self:isSym("|") or self:isSym("&") then
			self:next(); self:skipSimpleType()
		elseif self:isSym("->") then
			self:next(); self:skipSimpleType()
		else
			break
		end
	end
end

----------------------------------------------------------------------
-- Program / blocks
----------------------------------------------------------------------

function Parser:parse()
	local block = self:parseBlock()
	if not self:check("EOF") then self:error("unexpected trailing token") end
	return block
end

local BLOCK_END = {
	["end"] = true, ["else"] = true, ["elseif"] = true, ["until"] = true,
}

function Parser:atBlockEnd()
	if self:check("EOF") then return true end
	local t = self.tokens[self.pos]
	return t.type == "Keyword" and BLOCK_END[t.value] or false
end

function Parser:parseBlock()
	local stats = {}
	while not self:atBlockEnd() do
		if self:isKw("return") then
			stats[#stats + 1] = self:parseReturn()
			break
		end
		local s = self:parseStatement()
		if s then stats[#stats + 1] = s end
	end
	return { kind = "Block", stats = stats }
end

function Parser:parseReturn()
	self:next()
	local exprs = {}
	if not self:atBlockEnd() and not self:isSym(";") then
		exprs = self:parseExprList()
	end
	self:accept("Symbol", ";")
	return { kind = "Return", exprs = exprs }
end

----------------------------------------------------------------------
-- Statements
----------------------------------------------------------------------

function Parser:parseStatement()
	-- stray semicolons
	if self:isSym(";") then self:next(); return nil end

	-- attributes precede function decls: @native function ...
	local attribs = nil
	while self:check("Attribute") do
		attribs = attribs or {}
		attribs[#attribs + 1] = self:next().value
	end

	if self:isKw("local") then return self:parseLocal(attribs) end
	if self:isKw("if") then return self:parseIf() end
	if self:isKw("while") then return self:parseWhile() end
	if self:isKw("for") then return self:parseFor() end
	if self:isKw("repeat") then return self:parseRepeat() end
	if self:isKw("do") then
		self:next()
		local body = self:parseBlock()
		self:expect("Keyword", "end")
		return { kind = "Do", body = body }
	end
	if self:isKw("function") then return self:parseFunctionStat(attribs) end
	if self:isKw("break") then self:next(); return { kind = "Break" } end
	if self:isKw("return") then return self:parseReturn() end

	-- contextual keywords: continue, type, export type
	if self:check("Name", "continue") and not self:isFollowedByCall() then
		self:next(); return { kind = "Continue" }
	end
	if self:check("Name", "type") and self:peek(1) and self:peek(1).type == "Name" then
		return self:parseTypeAlias(false)
	end
	if self:check("Name", "export") and self:peek(1) and self:peek(1).type == "Name"
		and self:peek(1).value == "type" then
		self:next()
		return self:parseTypeAlias(true)
	end

	return self:parseExprStatement()
end

-- distinguishes `continue` statement from a var named continue used in a call/assign
function Parser:isFollowedByCall()
	local n = self:peek(1)
	if not n then return false end
	if n.type == "Symbol" then
		local v = n.value
		return v == "(" or v == "." or v == ":" or v == "[" or v == "="
			or v == "," or v == "{" or COMPOUND[v] ~= nil
	end
	return n.type == "String"
end

function Parser:parseTypeAlias(isExport)
	self:next() -- 'type'
	self:expect("Name")
	self:skipGenericParams()
	self:expect("Symbol", "=")
	self:skipType()
	return { kind = "TypeAlias" } -- dropped by generator
end

function Parser:parseLocal(attribs)
	self:next() -- 'local'
	if self:isKw("function") then
		self:next()
		local name = self:expect("Name").value
		local body = self:parseFunctionBody()
		return { kind = "LocalFunction", name = name, body = body, attribs = attribs }
	end
	local names = {}
	repeat
		local n = self:expect("Name").value
		local attrib = nil
		-- Luau variable attributes: local x <const> ...  (rare) -> skip
		if self:isSym("<") then self:skipTypeArgs() end
		if self:accept("Symbol", ":") then self:skipType() end
		names[#names + 1] = { name = n, attrib = attrib }
	until not self:accept("Symbol", ",")
	local exprs = {}
	if self:accept("Symbol", "=") then exprs = self:parseExprList() end
	return { kind = "LocalAssign", names = names, exprs = exprs }
end

function Parser:parseIf()
	self:next()
	local clauses = {}
	local cond = self:parseExpr()
	self:expect("Keyword", "then")
	clauses[#clauses + 1] = { cond = cond, body = self:parseBlock() }
	while self:isKw("elseif") do
		self:next()
		local c = self:parseExpr()
		self:expect("Keyword", "then")
		clauses[#clauses + 1] = { cond = c, body = self:parseBlock() }
	end
	local elseBody = nil
	if self:accept("Keyword", "else") then elseBody = self:parseBlock() end
	self:expect("Keyword", "end")
	return { kind = "If", clauses = clauses, elseBody = elseBody }
end

function Parser:parseWhile()
	self:next()
	local cond = self:parseExpr()
	self:expect("Keyword", "do")
	local body = self:parseBlock()
	self:expect("Keyword", "end")
	return { kind = "While", cond = cond, body = body }
end

function Parser:parseRepeat()
	self:next()
	local body = self:parseBlock()
	self:expect("Keyword", "until")
	local cond = self:parseExpr()
	return { kind = "Repeat", body = body, cond = cond }
end

function Parser:parseFor()
	self:next()
	local first = self:expect("Name").value
	if self:accept("Symbol", ":") then self:skipType() end
	if self:isSym("=") then
		self:next()
		local startE = self:parseExpr()
		self:expect("Symbol", ",")
		local stopE = self:parseExpr()
		local stepE = nil
		if self:accept("Symbol", ",") then stepE = self:parseExpr() end
		self:expect("Keyword", "do")
		local body = self:parseBlock()
		self:expect("Keyword", "end")
		return { kind = "NumericFor", var = first, startE = startE, stopE = stopE, stepE = stepE, body = body }
	end
	local names = { first }
	while self:accept("Symbol", ",") do
		names[#names + 1] = self:expect("Name").value
		if self:accept("Symbol", ":") then self:skipType() end
	end
	self:expect("Keyword", "in")
	local exprs = self:parseExprList()
	self:expect("Keyword", "do")
	local body = self:parseBlock()
	self:expect("Keyword", "end")
	return { kind = "GenericFor", names = names, exprs = exprs, body = body }
end

function Parser:parseFunctionStat(attribs)
	self:next() -- 'function'
	-- funcname: Name {. Name} [: Name]
	local base = { kind = "Name", name = self:expect("Name").value }
	local isMethod = false
	while self:isSym(".") do
		self:next()
		base = { kind = "Field", obj = base, name = self:expect("Name").value }
	end
	if self:accept("Symbol", ":") then
		base = { kind = "Field", obj = base, name = self:expect("Name").value }
		isMethod = true
	end
	local body = self:parseFunctionBody()
	if isMethod then
		-- insert implicit self param
		table.insert(body.params, 1, "self")
	end
	return { kind = "FunctionDecl", target = base, body = body, isMethod = isMethod, attribs = attribs }
end

-- funcbody after the name: [generics] ( params ) [: rettype] block end
function Parser:parseFunctionBody()
	self:skipGenericParams()
	self:expect("Symbol", "(")
	local params = {}
	local isVararg = false
	if not self:isSym(")") then
		repeat
			if self:isSym("...") then
				self:next()
				isVararg = true
				if self:accept("Symbol", ":") then self:skipType() end
				break
			end
			local p = self:expect("Name").value
			if self:accept("Symbol", ":") then self:skipType() end
			params[#params + 1] = p
		until not self:accept("Symbol", ",")
	end
	self:expect("Symbol", ")")
	if self:accept("Symbol", ":") then
		-- return type: either (a,b) or single type
		self:skipType()
	end
	local body = self:parseBlock()
	self:expect("Keyword", "end")
	return { kind = "Function", params = params, isVararg = isVararg, body = body }
end

-- expression statement: either a call (valid statement) or an assignment
function Parser:parseExprStatement()
	local first = self:parseSuffixedExpr()

	-- compound assignment
	if self:check("Symbol") and COMPOUND[self.tokens[self.pos].value] then
		local op = COMPOUND[self:next().value]
		local rhs = self:parseExpr()
		return { kind = "CompoundAssign", op = op, target = first, expr = rhs }
	end

	if self:isSym("=") or self:isSym(",") then
		local targets = { first }
		while self:accept("Symbol", ",") do
			targets[#targets + 1] = self:parseSuffixedExpr()
		end
		self:expect("Symbol", "=")
		local exprs = self:parseExprList()
		return { kind = "Assign", targets = targets, exprs = exprs }
	end

	if first.kind == "Call" or first.kind == "MethodCall" then
		return { kind = "ExprStat", expr = first }
	end
	self:error("syntax error: unexpected expression statement")
end

----------------------------------------------------------------------
-- Expressions
----------------------------------------------------------------------

function Parser:parseExprList()
	local list = { self:parseExpr() }
	while self:accept("Symbol", ",") do
		list[#list + 1] = self:parseExpr()
	end
	return list
end

function Parser:parseExpr(limit)
	limit = limit or 0
	local left

	-- unary
	if self:isKw("not") or self:isSym("-") or self:isSym("#") then
		local op = self:next().value
		local operand = self:parseExpr(UNARY_PRI)
		left = { kind = "Unop", op = op, operand = operand }
	elseif self:isKw("if") then
		left = self:parseIfExpr()
	else
		left = self:parseSimpleExpr()
	end

	-- type assertion  e :: T  (drop the type)
	while self:isSym("::") do
		self:next()
		self:skipType()
	end

	-- binary
	while true do
		local t = self.tokens[self.pos]
		local opval
		if t and t.type == "Symbol" and BINPRI[t.value] then opval = t.value
		elseif t and t.type == "Keyword" and (t.value == "and" or t.value == "or") then opval = t.value
		end
		if not opval then break end
		local pri = BINPRI[opval]
		if pri[1] <= limit then break end
		self:next()
		local right = self:parseExpr(pri[2])
		left = { kind = "Binop", op = opval, lhs = left, rhs = right }
		while self:isSym("::") do self:next(); self:skipType() end
	end

	return left
end

function Parser:parseIfExpr()
	self:next() -- 'if'
	local clauses = {}
	local cond = self:parseExpr()
	self:expect("Keyword", "then")
	clauses[#clauses + 1] = { cond = cond, value = self:parseExpr() }
	while self:isKw("elseif") do
		self:next()
		local c = self:parseExpr()
		self:expect("Keyword", "then")
		clauses[#clauses + 1] = { cond = c, value = self:parseExpr() }
	end
	self:expect("Keyword", "else")
	local elseExpr = self:parseExpr()
	return { kind = "IfExpr", clauses = clauses, elseExpr = elseExpr }
end

function Parser:parseSimpleExpr()
	if self:check("Number") then
		return { kind = "Number", raw = self:next().value }
	end
	if self:check("String") then
		return { kind = "String", str = self:next().value }
	end
	if self:isKw("nil") then self:next(); return { kind = "Nil" } end
	if self:isKw("true") then self:next(); return { kind = "True" } end
	if self:isKw("false") then self:next(); return { kind = "False" } end
	if self:isSym("...") then self:next(); return { kind = "VarArg" } end
	if self:isSym("{") then return self:parseTable() end
	if self:isKw("function") then
		self:next()
		return self:parseFunctionBody()
	end
	return self:parseSuffixedExpr()
end

function Parser:parsePrimaryExpr()
	if self:isSym("(") then
		self:next()
		local e = self:parseExpr()
		self:expect("Symbol", ")")
		return { kind = "Paren", expr = e }
	end
	if self:check("Name") then
		return { kind = "Name", name = self:next().value }
	end
	self:error("unexpected symbol, expected an expression")
end

function Parser:parseSuffixedExpr()
	local e = self:parsePrimaryExpr()
	while true do
		if self:isSym(".") then
			self:next()
			e = { kind = "Field", obj = e, name = self:expect("Name").value }
		elseif self:isSym("[") then
			self:next()
			local idx = self:parseExpr()
			self:expect("Symbol", "]")
			e = { kind = "Index", obj = e, index = idx }
		elseif self:isSym(":") then
			self:next()
			local m = self:expect("Name").value
			local args = self:parseCallArgs()
			e = { kind = "MethodCall", obj = e, method = m, args = args }
		elseif self:isSym("(") or self:isSym("{") or self:check("String") then
			local args = self:parseCallArgs()
			e = { kind = "Call", func = e, args = args }
		else
			break
		end
	end
	return e
end

function Parser:parseCallArgs()
	if self:check("String") then
		return { { kind = "String", str = self:next().value } }
	end
	if self:isSym("{") then
		return { self:parseTable() }
	end
	self:expect("Symbol", "(")
	local args = {}
	if not self:isSym(")") then
		args = self:parseExprList()
	end
	self:expect("Symbol", ")")
	return args
end

function Parser:parseTable()
	self:expect("Symbol", "{")
	local fields = {}
	while not self:isSym("}") do
		if self:isSym("[") then
			self:next()
			local key = self:parseExpr()
			self:expect("Symbol", "]")
			self:expect("Symbol", "=")
			local val = self:parseExpr()
			fields[#fields + 1] = { type = "rec", key = key, value = val }
		elseif self:check("Name") and self:peek(1) and self:peek(1).type == "Symbol"
			and self:peek(1).value == "=" then
			local name = self:next().value
			self:next() -- '='
			local val = self:parseExpr()
			fields[#fields + 1] = { type = "name", name = name, value = val }
		else
			fields[#fields + 1] = { type = "list", value = self:parseExpr() }
		end
		if not (self:accept("Symbol", ",") or self:accept("Symbol", ";")) then
			break
		end
	end
	self:expect("Symbol", "}")
	return { kind = "Table", fields = fields }
end

return Parser
