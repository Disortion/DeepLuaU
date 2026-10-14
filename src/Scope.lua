--!strict
-- DeepLuaU Scope resolver + local renamer.
-- Walks the AST tracking lexical scopes, resolves every Name to either a local
-- binding (renameable) or a free/global name (left untouched so API calls such as
-- game, print, pairs, require keep working), and rewrites all local bindings and
-- their references to fresh confusing identifiers. Pure lexical transform: it has
-- ZERO runtime cost -- the compiled bytecode is identical apart from debug names.

local Scope = {}

-- Confusing-but-valid identifier generator. Alphabet chosen so no combination can
-- ever spell a Lua/Luau keyword (keywords need letters outside this set).
local ALPH = { "l", "I", "i", "j", "_" }
local BASE = #ALPH

local function makeNameGen(prefix)
	local n = 0
	return function()
		n += 1
		local x = n
		local chars = {}
		repeat
			local d = (x - 1) % BASE
			chars[#chars + 1] = ALPH[d + 1]
			x = (x - d - 1) // BASE
		until x == 0
		return (prefix or "") .. table.concat(chars)
	end
end

----------------------------------------------------------------------

local Resolver = {}
Resolver.__index = Resolver

local function newResolver(nameGen)
	return setmetatable({ scopes = {}, nameGen = nameGen }, Resolver)
end

function Resolver:push() self.scopes[#self.scopes + 1] = {} end
function Resolver:pop() self.scopes[#self.scopes] = nil end

function Resolver:declare(name)
	local binding = { original = name, new = self.nameGen() }
	self.scopes[#self.scopes][name] = binding
	return binding
end

function Resolver:resolve(name)
	for i = #self.scopes, 1, -1 do
		local b = self.scopes[i][name]
		if b then return b end
	end
	return nil
end

----------------------------------------------------------------------
-- expression walk

function Resolver:expr(node)
	local k = node.kind
	if k == "Name" then
		local b = self:resolve(node.name)
		if b then node.name = b.new end
	elseif k == "Paren" then
		self:expr(node.expr)
	elseif k == "Field" then
		self:expr(node.obj) -- node.name is a key, never renamed
	elseif k == "Index" then
		self:expr(node.obj); self:expr(node.index)
	elseif k == "Call" then
		self:expr(node.func); self:exprList(node.args)
	elseif k == "MethodCall" then
		self:expr(node.obj); self:exprList(node.args) -- method name is a key
	elseif k == "Binop" then
		self:expr(node.lhs); self:expr(node.rhs)
	elseif k == "Unop" then
		self:expr(node.operand)
	elseif k == "Function" then
		self:func(node)
	elseif k == "Table" then
		for _, f in ipairs(node.fields) do
			if f.type == "rec" then self:expr(f.key) end
			-- f.name (record key) is never renamed
			self:expr(f.value)
		end
	elseif k == "IfExpr" then
		for _, c in ipairs(node.clauses) do self:expr(c.cond); self:expr(c.value) end
		self:expr(node.elseExpr)
	elseif k == "InterpString" then
		for _, part in ipairs(node.parts) do
			if part.t == "expr" then self:expr(part.expr) end
		end
	end
	-- literals / VarArg: nothing
end

function Resolver:exprList(list)
	for _, e in ipairs(list) do self:expr(e) end
end

function Resolver:func(node)
	self:push()
	for i, p in ipairs(node.params) do
		node.params[i] = self:declare(p).new
	end
	self:block(node.body)
	self:pop()
end

----------------------------------------------------------------------
-- statement walk

function Resolver:block(block)
	self:push()
	for _, s in ipairs(block.stats) do self:stat(s) end
	self:pop()
end

-- a block whose scope is already open (for loop bodies that share the loop scope)
function Resolver:blockInline(block)
	for _, s in ipairs(block.stats) do self:stat(s) end
end

function Resolver:stat(s)
	local k = s.kind
	if k == "LocalAssign" then
		self:exprList(s.exprs) -- RHS resolved in the pre-declaration scope
		for _, nm in ipairs(s.names) do
			nm.name = self:declare(nm.name).new
		end
	elseif k == "LocalFunction" then
		local b = self:declare(s.name) -- visible to its own body (recursion)
		s.name = b.new
		self:func(s.body)
	elseif k == "FunctionDecl" then
		self:expr(s.target) -- rename base if it is a local
		self:func(s.body)
	elseif k == "Assign" then
		for _, t in ipairs(s.targets) do self:expr(t) end
		self:exprList(s.exprs)
	elseif k == "CompoundAssign" then
		self:expr(s.target); self:expr(s.expr)
	elseif k == "ExprStat" then
		self:expr(s.expr)
	elseif k == "Do" then
		self:block(s.body)
	elseif k == "While" then
		self:expr(s.cond); self:block(s.body)
	elseif k == "Repeat" then
		-- until-condition can see locals declared in the body: share one scope
		self:push()
		self:blockInline(s.body)
		self:expr(s.cond)
		self:pop()
	elseif k == "If" then
		for _, c in ipairs(s.clauses) do
			self:expr(c.cond); self:block(c.body)
		end
		if s.elseBody then self:block(s.elseBody) end
	elseif k == "NumericFor" then
		self:expr(s.startE); self:expr(s.stopE)
		if s.stepE then self:expr(s.stepE) end
		self:push()
		s.var = self:declare(s.var).new
		self:blockInline(s.body)
		self:pop()
	elseif k == "GenericFor" then
		self:exprList(s.exprs)
		self:push()
		for i, nm in ipairs(s.names) do s.names[i] = self:declare(nm).new end
		self:blockInline(s.body)
		self:pop()
	elseif k == "Return" then
		self:exprList(s.exprs)
	end
	-- Break / Continue / TypeAlias: nothing
end

----------------------------------------------------------------------

function Scope.renameLocals(ast, opts)
	local nameGen = makeNameGen(opts and opts.prefix or nil)
	local r = newResolver(nameGen)
	r:push() -- top-level (chunk) scope; top-level locals are renameable too
	r:blockInline(ast)
	r:pop()
	return ast
end

Scope.makeNameGen = makeNameGen
return Scope
