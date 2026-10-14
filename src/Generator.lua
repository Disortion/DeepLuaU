--!strict
-- DeepLuaU Generator
-- AST -> minified Luau source. Token-aware spacing (only inserts a separator when
-- two adjacent tokens would otherwise merge), statements separated by ';' (legal in
-- Luau) to avoid call/newline ambiguities, and operator sub-expressions parenthesized
-- for precedence safety while `Paren` nodes from the source are preserved verbatim so
-- multi-return truncation semantics are never altered.

local Generator = {}
Generator.__index = Generator

local function isWord(c)
	return c ~= "" and (c:match("[%w_]") ~= nil)
end

local DANGER = {
	["--"] = true, [".."] = true, ["::"] = true, ["//"] = true,
	["=="] = true, ["~="] = true, ["<="] = true, [">="] = true,
	["->"] = true, ["+="] = true, ["-="] = true, ["*="] = true,
	["/="] = true, ["%="] = true, ["^="] = true, ["..."] = true,
}

function Generator.new()
	return setmetatable({ out = {}, last = "", lastType = "" }, Generator)
end

function Generator:emit(s, tokType)
	if s == "" then return end
	local first = s:sub(1, 1)
	local lastC = self.last
	local need = false
	if isWord(lastC) and isWord(first) then
		need = true
	elseif DANGER[lastC .. first] then
		need = true
	elseif self.lastType == "Number" and first == "." then
		need = true
	end
	if need then self.out[#self.out + 1] = " " end
	self.out[#self.out + 1] = s
	self.last = s:sub(-1)
	self.lastType = tokType or ""
end

function Generator:result()
	return table.concat(self.out)
end

----------------------------------------------------------------------

function Generator:emitString(str)
	if str.kind == "short" then
		self:emit(str.quote .. str.value .. str.quote, "String")
	elseif str.kind == "long" then
		local eq = string.rep("=", str.level or 0)
		-- newline after the opening bracket so content beginning with ] is safe
		self:emit("[" .. eq .. "[\n" .. str.value .. "]" .. eq .. "]", "String")
	else -- interp
		self:emit("`" .. str.value .. "`", "String")
	end
end

local OP_NODE = { Binop = true, Unop = true, IfExpr = true }

function Generator:emitWrapped(node)
	if OP_NODE[node.kind] then
		self:emit("(")
		self:emitExpr(node)
		self:emit(")")
	else
		self:emitExpr(node)
	end
end

function Generator:emitExpr(node)
	local k = node.kind
	if k == "Nil" then self:emit("nil")
	elseif k == "True" then self:emit("true")
	elseif k == "False" then self:emit("false")
	elseif k == "VarArg" then self:emit("...")
	elseif k == "Number" then self:emit(node.raw, "Number")
	elseif k == "String" then self:emitString(node.str)
	elseif k == "Name" then self:emit(node.name, "Name")
	elseif k == "Raw" then
		self:emit("(")
		self.out[#self.out + 1] = node.text
		self.last = node.text:sub(-1)
		self.lastType = ""
		self:emit(")")
	elseif k == "Paren" then
		self:emit("(")
		self:emitExpr(node.expr)
		self:emit(")")
	elseif k == "Field" then
		self:emitExpr(node.obj)
		self:emit(".")
		self:emit(node.name, "Name")
	elseif k == "Index" then
		self:emitExpr(node.obj)
		self:emit("[")
		self:emitExpr(node.index)
		self:emit("]")
	elseif k == "Call" then
		self:emitExpr(node.func)
		self:emitArgs(node.args)
	elseif k == "MethodCall" then
		self:emitExpr(node.obj)
		self:emit(":")
		self:emit(node.method, "Name")
		self:emitArgs(node.args)
	elseif k == "Function" then
		self:emit("function")
		self:emitParams(node)
		self:emitBlock(node.body)
		self:emit("end")
	elseif k == "Table" then
		self:emitTable(node)
	elseif k == "Binop" then
		self:emitWrapped(node.lhs)
		if node.op == "and" or node.op == "or" then
			self:emit(node.op, "Name")
		else
			self:emit(node.op)
		end
		self:emitWrapped(node.rhs)
	elseif k == "Unop" then
		if node.op == "not" then self:emit("not", "Name") else self:emit(node.op) end
		self:emitWrapped(node.operand)
	elseif k == "IfExpr" then
		for i, c in ipairs(node.clauses) do
			self:emit(i == 1 and "if" or "elseif")
			self:emitExpr(c.cond)
			self:emit("then")
			self:emitExpr(c.value)
		end
		self:emit("else")
		self:emitExpr(node.elseExpr)
	elseif k == "InterpString" then
		local s = "`"
		for _, part in ipairs(node.parts) do
			if part.t == "str" then
				s = s .. part.value
			else
				local g = Generator.new()
				g:emitExpr(part.expr)
				s = s .. "{ " .. g:result() .. " }" -- padded: Luau forbids {{ and }}
			end
		end
		self:emit(s .. "`", "String")
	else
		error("Generator: unknown expr kind " .. tostring(k))
	end
end

function Generator:emitArgs(args)
	-- single string / single table call forms are re-emitted as (...) uniformly
	self:emit("(")
	for i, a in ipairs(args) do
		if i > 1 then self:emit(",") end
		self:emitExpr(a)
	end
	self:emit(")")
end

function Generator:emitParams(node)
	self:emit("(")
	local n = #node.params
	for i, p in ipairs(node.params) do
		if i > 1 then self:emit(",") end
		self:emit(p, "Name")
	end
	if node.isVararg then
		if n > 0 then self:emit(",") end
		self:emit("...")
	end
	self:emit(")")
end

function Generator:emitTable(node)
	self:emit("{")
	for i, f in ipairs(node.fields) do
		if i > 1 then self:emit(",") end
		if f.type == "list" then
			self:emitExpr(f.value)
		elseif f.type == "name" then
			self:emit(f.name, "Name")
			self:emit("=")
			self:emitExpr(f.value)
		else -- rec
			self:emit("[")
			self:emitExpr(f.key)
			self:emit("]")
			self:emit("=")
			self:emitExpr(f.value)
		end
	end
	self:emit("}")
end

----------------------------------------------------------------------

function Generator:emitBlock(block)
	for _, stat in ipairs(block.stats) do
		self:emitStat(stat)
	end
end

function Generator:emitStat(s)
	local k = s.kind
	if k == "TypeAlias" then
		-- dropped
		return
	elseif k == "LocalAssign" then
		self:emit("local")
		for i, nm in ipairs(s.names) do
			if i > 1 then self:emit(",") end
			self:emit(nm.name, "Name")
		end
		if #s.exprs > 0 then
			self:emit("=")
			self:emitExprList(s.exprs)
		end
		self:emit(";")
	elseif k == "LocalFunction" then
		self:emit("local")
		self:emit("function")
		self:emit(s.name, "Name")
		self:emitParams(s.body)
		self:emitBlock(s.body.body)
		self:emit("end")
		self:emit(";")
	elseif k == "FunctionDecl" then
		self:emit("function")
		self:emitExpr(s.target)
		self:emitParams(s.body)
		self:emitBlock(s.body.body)
		self:emit("end")
		self:emit(";")
	elseif k == "Assign" then
		for i, t in ipairs(s.targets) do
			if i > 1 then self:emit(",") end
			self:emitExpr(t)
		end
		self:emit("=")
		self:emitExprList(s.exprs)
		self:emit(";")
	elseif k == "CompoundAssign" then
		self:emitExpr(s.target)
		self:emit(s.op .. "=")
		self:emitExpr(s.expr)
		self:emit(";")
	elseif k == "ExprStat" then
		self:emitExpr(s.expr)
		self:emit(";")
	elseif k == "Do" then
		self:emit("do"); self:emitBlock(s.body); self:emit("end")
	elseif k == "While" then
		self:emit("while"); self:emitExpr(s.cond); self:emit("do")
		self:emitBlock(s.body); self:emit("end")
	elseif k == "Repeat" then
		self:emit("repeat"); self:emitBlock(s.body)
		self:emit("until"); self:emitExpr(s.cond); self:emit(";")
	elseif k == "If" then
		for i, c in ipairs(s.clauses) do
			self:emit(i == 1 and "if" or "elseif")
			self:emitExpr(c.cond)
			self:emit("then")
			self:emitBlock(c.body)
		end
		if s.elseBody then
			self:emit("else")
			self:emitBlock(s.elseBody)
		end
		self:emit("end")
	elseif k == "NumericFor" then
		self:emit("for"); self:emit(s.var, "Name"); self:emit("=")
		self:emitExpr(s.startE); self:emit(","); self:emitExpr(s.stopE)
		if s.stepE then self:emit(","); self:emitExpr(s.stepE) end
		self:emit("do"); self:emitBlock(s.body); self:emit("end")
	elseif k == "GenericFor" then
		self:emit("for")
		for i, nm in ipairs(s.names) do
			if i > 1 then self:emit(",") end
			self:emit(nm, "Name")
		end
		self:emit("in"); self:emitExprList(s.exprs)
		self:emit("do"); self:emitBlock(s.body); self:emit("end")
	elseif k == "Return" then
		self:emit("return")
		self:emitExprList(s.exprs)
		self:emit(";")
	elseif k == "Break" then
		self:emit("break"); self:emit(";")
	elseif k == "Continue" then
		self:emit("continue"); self:emit(";")
	else
		error("Generator: unknown stat kind " .. tostring(k))
	end
end

function Generator:emitExprList(list)
	for i, e in ipairs(list) do
		if i > 1 then self:emit(",") end
		self:emitExpr(e)
	end
end

local function generate(ast)
	local g = Generator.new()
	g:emitBlock(ast)
	return g:result()
end

return { new = Generator.new, generate = generate }
