/*
 * DeepLuaU — browser/JS port of the Luau obfuscator.
 * Faithful translation of src/*.lua. Runs fully client-side (no backend).
 * Exposes: DeepLuaU.obfuscate(source, { profile, seed, header }) -> string
 * Validated by running its output through the real `luau` interpreter.
 */
(function (root) {
  "use strict";

  // ---------------------------------------------------------------- RNG
  function Rng(seed) {
    seed = (seed >>> 0) || 0x9e3779b9;
    this.s = seed >>> 0;
  }
  Rng.prototype.next = function () {
    let s = this.s;
    s ^= (s << 13) >>> 0; s >>>= 0;
    s ^= s >>> 17; s >>>= 0;
    s ^= (s << 5) >>> 0; s >>>= 0;
    this.s = s >>> 0;
    return this.s;
  };
  Rng.prototype.float = function () { return this.next() / 4294967296; };
  Rng.prototype.int = function (lo, hi) {
    if (hi < lo) return lo;
    const span = hi - lo + 1;
    return lo + (this.next() % span);
  };
  Rng.prototype.chance = function (p) { return this.float() < p; };
  Rng.prototype.shuffle = function (list) {
    for (let i = list.length - 1; i >= 1; i--) {
      const j = this.int(0, i);
      const t = list[i]; list[i] = list[j]; list[j] = t;
    }
    return list;
  };

  // ---------------------------------------------------------------- Lexer
  const KEYWORDS = new Set(["and","break","do","else","elseif","end","false","for",
    "function","if","in","local","nil","not","or","repeat","return","then","true",
    "until","while"]);
  const isDigit = c => c >= "0" && c <= "9";
  const isHex = c => (c>="0"&&c<="9")||(c>="a"&&c<="f")||(c>="A"&&c<="F");
  const isAlpha = c => (c>="a"&&c<="z")||(c>="A"&&c<="Z")||c==="_";
  const isAlphaNum = c => isAlpha(c)||isDigit(c);

  const SYMBOLS = ["...","..=","//=","::","->","==","~=","<=",">=","..","+=","-=",
    "*=","/=","%=","^=","//","+","-","*","/","%","^","#","<",">","=","(",")","{","}",
    "[","]",";",":",",",".","?","&","|"];

  function Lexer(src) { this.src=src; this.pos=0; this.line=1; this.len=src.length; this.tokens=[]; }
  Lexer.prototype.error = function (m){ throw new Error("DeepLuaU lex error (line "+this.line+"): "+m); };
  Lexer.prototype.peek = function (o){ const i=this.pos+(o||0); return i>=this.len?"":this.src[i]; };
  Lexer.prototype.advance = function (){ const c=this.src[this.pos++]; if(c==="\n")this.line++; return c; };
  Lexer.prototype.match = function (s){
    if (this.src.substr(this.pos, s.length)===s){ for(let i=0;i<s.length;i++)this.advance(); return true; }
    return false;
  };
  Lexer.prototype.tryLongBracket = function (){
    const start=this.pos;
    if (this.peek()!=="[") return null;
    let p=this.pos+1, level=0;
    while (this.src[p]==="=") { level++; p++; }
    if (this.src[p]!=="[") return null;
    this.pos=p+1;
    if (this.peek()==="\r") this.advance();
    if (this.peek()==="\n") this.advance();
    const close="]"+"=".repeat(level)+"]";
    const idx=this.src.indexOf(close, this.pos);
    if (idx<0){ this.pos=start; this.error("unterminated long bracket"); }
    const content=this.src.substring(this.pos, idx);
    for (let i=this.pos;i<idx+close.length;i++) this.advance();
    return { content, level };
  };
  Lexer.prototype.readShortString = function (quote){
    const buf=[]; this.advance();
    while (true){
      const c=this.peek();
      if (c===""||c==="\n") this.error("unterminated string");
      if (c===quote){ this.advance(); break; }
      if (c==="\\"){ this.advance(); const e=this.advance(); buf.push("\\"+e); }
      else buf.push(this.advance());
    }
    return buf.join("");
  };
  Lexer.prototype.readInterpString = function (){
    const buf=[]; this.advance(); let depth=0;
    while (true){
      const c=this.peek();
      if (c==="") this.error("unterminated interpolated string");
      if (c==="\\"){ buf.push(this.advance()); buf.push(this.advance()); }
      else if (c==="{"){ depth++; buf.push(this.advance()); }
      else if (c==="}"){ if(depth>0)depth--; buf.push(this.advance()); }
      else if (c==="`"&&depth===0){ this.advance(); break; }
      else buf.push(this.advance());
    }
    return buf.join("");
  };
  Lexer.prototype.readNumber = function (){
    const start=this.pos;
    if (this.peek()==="0"&&(this.peek(1)==="x"||this.peek(1)==="X")){
      this.advance(); this.advance();
      while (isHex(this.peek())||this.peek()==="_") this.advance();
      if (this.peek()==="."){ this.advance(); while(isHex(this.peek())||this.peek()==="_")this.advance(); }
      if (this.peek()==="p"||this.peek()==="P"){ this.advance(); if(this.peek()==="+"||this.peek()==="-")this.advance(); while(isDigit(this.peek())||this.peek()==="_")this.advance(); }
    } else if (this.peek()==="0"&&(this.peek(1)==="b"||this.peek(1)==="B")){
      this.advance(); this.advance();
      while (this.peek()==="0"||this.peek()==="1"||this.peek()==="_") this.advance();
    } else {
      while (isDigit(this.peek())||this.peek()==="_") this.advance();
      if (this.peek()==="."){ this.advance(); while(isDigit(this.peek())||this.peek()==="_")this.advance(); }
      if (this.peek()==="e"||this.peek()==="E"){ this.advance(); if(this.peek()==="+"||this.peek()==="-")this.advance(); while(isDigit(this.peek())||this.peek()==="_")this.advance(); }
    }
    return this.src.substring(start, this.pos);
  };
  Lexer.prototype.add = function (type, value){ this.tokens.push({ type, value, line:this.line }); };
  Lexer.prototype.tokenize = function (){
    while (this.pos<this.len){
      const c=this.peek();
      if (c===" "||c==="\t"||c==="\r"||c==="\n"){ this.advance(); }
      else if (c==="-"&&this.peek(1)==="-"){
        this.advance(); this.advance();
        if (this.peek()==="["){ const lb=this.tryLongBracket(); if(lb===null){ while(this.peek()!=="\n"&&this.peek()!=="")this.advance(); } }
        else { while(this.peek()!=="\n"&&this.peek()!=="")this.advance(); }
      }
      else if (c==="["&&(this.peek(1)==="["||this.peek(1)==="=")){
        const lb=this.tryLongBracket();
        if (lb!==null) this.add("String",{kind:"long",value:lb.content,level:lb.level});
        else { this.advance(); this.add("Symbol","["); }
      }
      else if (c==='"'||c==="'"){ const v=this.readShortString(c); this.add("String",{kind:"short",value:v,quote:c}); }
      else if (c==="`"){ const v=this.readInterpString(); this.add("String",{kind:"interp",value:v}); }
      else if (c==="@"){ this.advance(); const s=this.pos; while(isAlphaNum(this.peek()))this.advance(); this.add("Attribute",this.src.substring(s,this.pos)); }
      else if (isDigit(c)||(c==="."&&isDigit(this.peek(1)))){ this.add("Number",this.readNumber()); }
      else if (isAlpha(c)){
        const s=this.pos; while(isAlphaNum(this.peek()))this.advance();
        const w=this.src.substring(s,this.pos);
        this.add(KEYWORDS.has(w)?"Keyword":"Name", w);
      }
      else {
        let matched=false;
        for (const sym of SYMBOLS){ if(this.match(sym)){ this.add("Symbol",sym); matched=true; break; } }
        if (!matched) this.error("unexpected character '"+c+"'");
      }
    }
    this.add("EOF", null);
    return this.tokens;
  };

  // ---------------------------------------------------------------- Parser
  const BINPRI = {
    "or":[1,1],"and":[2,2],
    "<":[3,3],">":[3,3],"<=":[3,3],">=":[3,3],"~=":[3,3],"==":[3,3],
    "..":[9,8],"+":[10,10],"-":[10,10],
    "*":[11,11],"/":[11,11],"//":[11,11],"%":[11,11],"^":[14,13],
  };
  const UNARY_PRI = 12;
  const COMPOUND = {"+=":"+","-=":"-","*=":"*","/=":"/","//=":"//","%=":"%","^=":"^","..=":".."};
  const CLOSE_OF = {"(":")","{":"}","[":"]"};

  function Parser(src){ this.tokens=new Lexer(src).tokenize(); this.pos=0; }
  Parser.prototype.error = function (m){
    const t=this.tokens[this.pos];
    throw new Error("DeepLuaU parse error (line "+(t&&t.line)+"): "+m+" (got "+(t&&t.type)+" "+(t&&(typeof t.value==="object"?"<str>":t.value))+")");
  };
  Parser.prototype.peek = function (o){ return this.tokens[this.pos+(o||0)]; };
  Parser.prototype.nextTok = function (){ return this.tokens[this.pos++]; };
  Parser.prototype.check = function (type,value){
    const t=this.tokens[this.pos];
    if (!t||t.type!==type) return false;
    if (value!==undefined && value!==null && t.value!==value) return false;
    return true;
  };
  Parser.prototype.accept = function (type,value){ return this.check(type,value)?this.nextTok():null; };
  Parser.prototype.expect = function (type,value){ const t=this.accept(type,value); if(!t)this.error("expected "+type+(value?(" '"+value+"'"):"")); return t; };
  Parser.prototype.isKw = function (w){ return this.check("Keyword",w); };
  Parser.prototype.isSym = function (s){ return this.check("Symbol",s); };

  Parser.prototype.skipGenericParams = function (){
    if (!this.isSym("<")) return;
    this.nextTok(); let depth=1;
    while (depth>0){ const t=this.nextTok(); if(!t||t.type==="EOF")this.error("unterminated generic params");
      if(t.type==="Symbol"&&t.value==="<")depth++; else if(t.type==="Symbol"&&t.value===">")depth--; }
  };
  Parser.prototype.skipTypeArgs = function (){
    this.nextTok(); let depth=1;
    while (depth>0){ const t=this.nextTok(); if(!t||t.type==="EOF")this.error("unterminated type args");
      if(t.type==="Symbol"&&t.value==="<")depth++; else if(t.type==="Symbol"&&t.value===">")depth--; }
  };
  Parser.prototype.skipBalanced = function (open){
    const close=CLOSE_OF[open]; this.nextTok(); let depth=1;
    while (depth>0){ const t=this.nextTok(); if(!t||t.type==="EOF")this.error("unterminated "+open);
      if(t.type==="Symbol"){ if(t.value===open)depth++; else if(t.value===close)depth--; } }
  };
  Parser.prototype.skipSimpleType = function (){
    if (this.isSym("(")) this.skipBalanced("(");
    else if (this.isSym("{")) this.skipBalanced("{");
    else if (this.isSym("...")){ this.nextTok(); this.skipSimpleType(); }
    else if (this.check("String")||this.check("Number")) this.nextTok();
    else if (this.check("Name")||this.isKw("nil")||this.isKw("true")||this.isKw("false")||this.check("Keyword","function")){
      this.nextTok();
      while (this.isSym(".")){ this.nextTok(); this.expect("Name"); }
      if (this.isSym("<")) this.skipTypeArgs();
    } else this.error("expected a type");
    while (this.isSym("?")) this.nextTok();
  };
  Parser.prototype.skipType = function (){
    this.skipSimpleType();
    while (true){
      if (this.isSym("|")||this.isSym("&")){ this.nextTok(); this.skipSimpleType(); }
      else if (this.isSym("->")){ this.nextTok(); this.skipSimpleType(); }
      else break;
    }
  };

  Parser.prototype.parse = function (){
    const block=this.parseBlock();
    if (!this.check("EOF")) this.error("unexpected trailing token");
    return block;
  };
  const BLOCK_END = new Set(["end","else","elseif","until"]);
  Parser.prototype.atBlockEnd = function (){
    if (this.check("EOF")) return true;
    const t=this.tokens[this.pos];
    return t.type==="Keyword"&&BLOCK_END.has(t.value);
  };
  Parser.prototype.parseBlock = function (){
    const stats=[];
    while (!this.atBlockEnd()){
      if (this.isKw("return")){ stats.push(this.parseReturn()); break; }
      const s=this.parseStatement();
      if (s) stats.push(s);
    }
    return { kind:"Block", stats };
  };
  Parser.prototype.parseReturn = function (){
    this.nextTok();
    let exprs=[];
    if (!this.atBlockEnd() && !this.isSym(";")) exprs=this.parseExprList();
    this.accept("Symbol",";");
    return { kind:"Return", exprs };
  };
  Parser.prototype.parseStatement = function (){
    if (this.isSym(";")){ this.nextTok(); return null; }
    let attribs=null;
    while (this.check("Attribute")){ attribs=attribs||[]; attribs.push(this.nextTok().value); }
    if (this.isKw("local")) return this.parseLocal(attribs);
    if (this.isKw("if")) return this.parseIf();
    if (this.isKw("while")) return this.parseWhile();
    if (this.isKw("for")) return this.parseFor();
    if (this.isKw("repeat")) return this.parseRepeat();
    if (this.isKw("do")){ this.nextTok(); const body=this.parseBlock(); this.expect("Keyword","end"); return {kind:"Do",body}; }
    if (this.isKw("function")) return this.parseFunctionStat(attribs);
    if (this.isKw("break")){ this.nextTok(); return {kind:"Break"}; }
    if (this.isKw("return")) return this.parseReturn();
    if (this.check("Name","continue") && !this.isFollowedByCall()){ this.nextTok(); return {kind:"Continue"}; }
    if (this.check("Name","type") && this.peek(1) && this.peek(1).type==="Name") return this.parseTypeAlias(false);
    if (this.check("Name","export") && this.peek(1) && this.peek(1).type==="Name" && this.peek(1).value==="type"){ this.nextTok(); return this.parseTypeAlias(true); }
    return this.parseExprStatement();
  };
  Parser.prototype.isFollowedByCall = function (){
    const n=this.peek(1); if(!n) return false;
    if (n.type==="Symbol"){ const v=n.value;
      return v==="("||v==="."||v===":"||v==="["||v==="="||v===","||v==="{"||COMPOUND[v]!==undefined; }
    return n.type==="String";
  };
  Parser.prototype.parseTypeAlias = function (){
    this.nextTok(); this.expect("Name"); this.skipGenericParams();
    this.expect("Symbol","="); this.skipType();
    return { kind:"TypeAlias" };
  };
  Parser.prototype.parseLocal = function (attribs){
    this.nextTok();
    if (this.isKw("function")){
      this.nextTok(); const name=this.expect("Name").value; const body=this.parseFunctionBody();
      return { kind:"LocalFunction", name, body, attribs };
    }
    const names=[];
    do {
      const n=this.expect("Name").value;
      if (this.isSym("<")) this.skipTypeArgs();
      if (this.accept("Symbol",":")) this.skipType();
      names.push({ name:n, attrib:null });
    } while (this.accept("Symbol",","));
    let exprs=[];
    if (this.accept("Symbol","=")) exprs=this.parseExprList();
    return { kind:"LocalAssign", names, exprs };
  };
  Parser.prototype.parseIf = function (){
    this.nextTok(); const clauses=[];
    let cond=this.parseExpr(); this.expect("Keyword","then");
    clauses.push({ cond, body:this.parseBlock() });
    while (this.isKw("elseif")){ this.nextTok(); const c=this.parseExpr(); this.expect("Keyword","then"); clauses.push({cond:c,body:this.parseBlock()}); }
    let elseBody=null;
    if (this.accept("Keyword","else")) elseBody=this.parseBlock();
    this.expect("Keyword","end");
    return { kind:"If", clauses, elseBody };
  };
  Parser.prototype.parseWhile = function (){
    this.nextTok(); const cond=this.parseExpr(); this.expect("Keyword","do");
    const body=this.parseBlock(); this.expect("Keyword","end");
    return { kind:"While", cond, body };
  };
  Parser.prototype.parseRepeat = function (){
    this.nextTok(); const body=this.parseBlock(); this.expect("Keyword","until");
    const cond=this.parseExpr();
    return { kind:"Repeat", body, cond };
  };
  Parser.prototype.parseFor = function (){
    this.nextTok(); const first=this.expect("Name").value;
    if (this.accept("Symbol",":")) this.skipType();
    if (this.isSym("=")){
      this.nextTok(); const startE=this.parseExpr(); this.expect("Symbol",",");
      const stopE=this.parseExpr(); let stepE=null;
      if (this.accept("Symbol",",")) stepE=this.parseExpr();
      this.expect("Keyword","do"); const body=this.parseBlock(); this.expect("Keyword","end");
      return { kind:"NumericFor", var:first, startE, stopE, stepE, body };
    }
    const names=[first];
    while (this.accept("Symbol",",")){ names.push(this.expect("Name").value); if(this.accept("Symbol",":"))this.skipType(); }
    this.expect("Keyword","in"); const exprs=this.parseExprList();
    this.expect("Keyword","do"); const body=this.parseBlock(); this.expect("Keyword","end");
    return { kind:"GenericFor", names, exprs, body };
  };
  Parser.prototype.parseFunctionStat = function (attribs){
    this.nextTok();
    let base={ kind:"Name", name:this.expect("Name").value };
    let isMethod=false;
    while (this.isSym(".")){ this.nextTok(); base={kind:"Field",obj:base,name:this.expect("Name").value}; }
    if (this.accept("Symbol",":")){ base={kind:"Field",obj:base,name:this.expect("Name").value}; isMethod=true; }
    const body=this.parseFunctionBody();
    if (isMethod) body.params.unshift("self");
    return { kind:"FunctionDecl", target:base, body, isMethod, attribs };
  };
  Parser.prototype.parseFunctionBody = function (){
    this.skipGenericParams(); this.expect("Symbol","(");
    const params=[]; let isVararg=false;
    if (!this.isSym(")")){
      do {
        if (this.isSym("...")){ this.nextTok(); isVararg=true; if(this.accept("Symbol",":"))this.skipType(); break; }
        const p=this.expect("Name").value;
        if (this.accept("Symbol",":")) this.skipType();
        params.push(p);
      } while (this.accept("Symbol",","));
    }
    this.expect("Symbol",")");
    if (this.accept("Symbol",":")) this.skipType();
    const body=this.parseBlock(); this.expect("Keyword","end");
    return { kind:"Function", params, isVararg, body };
  };
  Parser.prototype.parseExprStatement = function (){
    const first=this.parseSuffixedExpr();
    if (this.check("Symbol") && COMPOUND[this.tokens[this.pos].value]){
      const op=COMPOUND[this.nextTok().value]; const rhs=this.parseExpr();
      return { kind:"CompoundAssign", op, target:first, expr:rhs };
    }
    if (this.isSym("=")||this.isSym(",")){
      const targets=[first];
      while (this.accept("Symbol",",")) targets.push(this.parseSuffixedExpr());
      this.expect("Symbol","="); const exprs=this.parseExprList();
      return { kind:"Assign", targets, exprs };
    }
    if (first.kind==="Call"||first.kind==="MethodCall") return { kind:"ExprStat", expr:first };
    this.error("syntax error: unexpected expression statement");
  };
  Parser.prototype.parseExprList = function (){
    const list=[this.parseExpr()];
    while (this.accept("Symbol",",")) list.push(this.parseExpr());
    return list;
  };
  Parser.prototype.parseExpr = function (limit){
    limit=limit||0; let left;
    if (this.isKw("not")||this.isSym("-")||this.isSym("#")){
      const op=this.nextTok().value; const operand=this.parseExpr(UNARY_PRI);
      left={ kind:"Unop", op, operand };
    } else if (this.isKw("if")) left=this.parseIfExpr();
    else left=this.parseSimpleExpr();
    while (this.isSym("::")){ this.nextTok(); this.skipType(); }
    while (true){
      const t=this.tokens[this.pos]; let opval;
      if (t&&t.type==="Symbol"&&BINPRI[t.value]) opval=t.value;
      else if (t&&t.type==="Keyword"&&(t.value==="and"||t.value==="or")) opval=t.value;
      if (!opval) break;
      const pri=BINPRI[opval];
      if (pri[0]<=limit) break;
      this.nextTok();
      const right=this.parseExpr(pri[1]);
      left={ kind:"Binop", op:opval, lhs:left, rhs:right };
      while (this.isSym("::")){ this.nextTok(); this.skipType(); }
    }
    return left;
  };
  Parser.prototype.parseIfExpr = function (){
    this.nextTok(); const clauses=[];
    let cond=this.parseExpr(); this.expect("Keyword","then");
    clauses.push({ cond, value:this.parseExpr() });
    while (this.isKw("elseif")){ this.nextTok(); const c=this.parseExpr(); this.expect("Keyword","then"); clauses.push({cond:c,value:this.parseExpr()}); }
    this.expect("Keyword","else"); const elseExpr=this.parseExpr();
    return { kind:"IfExpr", clauses, elseExpr };
  };
  Parser.prototype.parseSimpleExpr = function (){
    if (this.check("Number")) return { kind:"Number", raw:this.nextTok().value };
    if (this.check("String")) return { kind:"String", str:this.nextTok().value };
    if (this.isKw("nil")){ this.nextTok(); return {kind:"Nil"}; }
    if (this.isKw("true")){ this.nextTok(); return {kind:"True"}; }
    if (this.isKw("false")){ this.nextTok(); return {kind:"False"}; }
    if (this.isSym("...")){ this.nextTok(); return {kind:"VarArg"}; }
    if (this.isSym("{")) return this.parseTable();
    if (this.isKw("function")){ this.nextTok(); return this.parseFunctionBody(); }
    return this.parseSuffixedExpr();
  };
  Parser.prototype.parsePrimaryExpr = function (){
    if (this.isSym("(")){ this.nextTok(); const e=this.parseExpr(); this.expect("Symbol",")"); return {kind:"Paren",expr:e}; }
    if (this.check("Name")) return { kind:"Name", name:this.nextTok().value };
    this.error("unexpected symbol, expected an expression");
  };
  Parser.prototype.parseSuffixedExpr = function (){
    let e=this.parsePrimaryExpr();
    while (true){
      if (this.isSym(".")){ this.nextTok(); e={kind:"Field",obj:e,name:this.expect("Name").value}; }
      else if (this.isSym("[")){ this.nextTok(); const idx=this.parseExpr(); this.expect("Symbol","]"); e={kind:"Index",obj:e,index:idx}; }
      else if (this.isSym(":")){ this.nextTok(); const m=this.expect("Name").value; const args=this.parseCallArgs(); e={kind:"MethodCall",obj:e,method:m,args}; }
      else if (this.isSym("(")||this.isSym("{")||this.check("String")){ const args=this.parseCallArgs(); e={kind:"Call",func:e,args}; }
      else break;
    }
    return e;
  };
  Parser.prototype.parseCallArgs = function (){
    if (this.check("String")) return [{ kind:"String", str:this.nextTok().value }];
    if (this.isSym("{")) return [this.parseTable()];
    this.expect("Symbol","(");
    let args=[];
    if (!this.isSym(")")) args=this.parseExprList();
    this.expect("Symbol",")");
    return args;
  };
  Parser.prototype.parseTable = function (){
    this.expect("Symbol","{");
    const fields=[];
    while (!this.isSym("}")){
      if (this.isSym("[")){
        this.nextTok(); const key=this.parseExpr(); this.expect("Symbol","]"); this.expect("Symbol","=");
        fields.push({ type:"rec", key, value:this.parseExpr() });
      } else if (this.check("Name") && this.peek(1) && this.peek(1).type==="Symbol" && this.peek(1).value==="="){
        const name=this.nextTok().value; this.nextTok();
        fields.push({ type:"name", name, value:this.parseExpr() });
      } else {
        fields.push({ type:"list", value:this.parseExpr() });
      }
      if (!(this.accept("Symbol",",")||this.accept("Symbol",";"))) break;
    }
    this.expect("Symbol","}");
    return { kind:"Table", fields };
  };

  // ---------------------------------------------------------------- Generator
  const DANGER = new Set(["--","..","::","//","==","~=","<=",">=","->","+=","-=","*=","/=","%=","^=","..."]);
  const isWordCh = c => c!=="" && /[\w]/.test(c);
  function Generator(){ this.out=[]; this.last=""; this.lastType=""; }
  Generator.prototype.emit = function (s, tokType){
    if (s==="") return;
    const first=s[0], lastC=this.last; let need=false;
    if (isWordCh(lastC)&&isWordCh(first)) need=true;
    else if (DANGER.has(lastC+first)) need=true;
    else if (this.lastType==="Number"&&first===".") need=true;
    if (need) this.out.push(" ");
    this.out.push(s); this.last=s[s.length-1]; this.lastType=tokType||"";
  };
  Generator.prototype.result = function (){ return this.out.join(""); };
  Generator.prototype.emitString = function (str){
    if (str.kind==="short") this.emit(str.quote+str.value+str.quote,"String");
    else if (str.kind==="long"){ const eq="=".repeat(str.level||0); this.emit("["+eq+"[\n"+str.value+"]"+eq+"]","String"); }
    else this.emit("`"+str.value+"`","String");
  };
  const OP_NODE = new Set(["Binop","Unop","IfExpr"]);
  Generator.prototype.emitWrapped = function (node){
    if (OP_NODE.has(node.kind)){ this.emit("("); this.emitExpr(node); this.emit(")"); }
    else this.emitExpr(node);
  };
  Generator.prototype.emitExpr = function (node){
    const k=node.kind;
    if (k==="Nil") this.emit("nil");
    else if (k==="True") this.emit("true");
    else if (k==="False") this.emit("false");
    else if (k==="VarArg") this.emit("...");
    else if (k==="Number") this.emit(node.raw,"Number");
    else if (k==="String") this.emitString(node.str);
    else if (k==="Name") this.emit(node.name,"Name");
    else if (k==="Raw"){ this.emit("("); this.out.push(node.text); this.last=node.text[node.text.length-1]; this.lastType=""; this.emit(")"); }
    else if (k==="Paren"){ this.emit("("); this.emitExpr(node.expr); this.emit(")"); }
    else if (k==="Field"){ this.emitExpr(node.obj); this.emit("."); this.emit(node.name,"Name"); }
    else if (k==="Index"){ this.emitExpr(node.obj); this.emit("["); this.emitExpr(node.index); this.emit("]"); }
    else if (k==="Call"){ this.emitExpr(node.func); this.emitArgs(node.args); }
    else if (k==="MethodCall"){ this.emitExpr(node.obj); this.emit(":"); this.emit(node.method,"Name"); this.emitArgs(node.args); }
    else if (k==="Function"){ this.emit("function"); this.emitParams(node); this.emitBlock(node.body); this.emit("end"); }
    else if (k==="Table") this.emitTable(node);
    else if (k==="Binop"){ this.emitWrapped(node.lhs); if(node.op==="and"||node.op==="or")this.emit(node.op,"Name"); else this.emit(node.op); this.emitWrapped(node.rhs); }
    else if (k==="Unop"){ if(node.op==="not")this.emit("not","Name"); else this.emit(node.op); this.emitWrapped(node.operand); }
    else if (k==="IfExpr"){
      node.clauses.forEach((c,i)=>{ this.emit(i===0?"if":"elseif"); this.emitExpr(c.cond); this.emit("then"); this.emitExpr(c.value); });
      this.emit("else"); this.emitExpr(node.elseExpr);
    }
    else throw new Error("Generator: unknown expr kind "+k);
  };
  Generator.prototype.emitArgs = function (args){
    this.emit("("); args.forEach((a,i)=>{ if(i>0)this.emit(","); this.emitExpr(a); }); this.emit(")");
  };
  Generator.prototype.emitParams = function (node){
    this.emit("("); const n=node.params.length;
    node.params.forEach((p,i)=>{ if(i>0)this.emit(","); this.emit(p,"Name"); });
    if (node.isVararg){ if(n>0)this.emit(","); this.emit("..."); }
    this.emit(")");
  };
  Generator.prototype.emitTable = function (node){
    this.emit("{");
    node.fields.forEach((f,i)=>{
      if (i>0) this.emit(",");
      if (f.type==="list") this.emitExpr(f.value);
      else if (f.type==="name"){ this.emit(f.name,"Name"); this.emit("="); this.emitExpr(f.value); }
      else { this.emit("["); this.emitExpr(f.key); this.emit("]"); this.emit("="); this.emitExpr(f.value); }
    });
    this.emit("}");
  };
  Generator.prototype.emitBlock = function (block){ for(const s of block.stats) this.emitStat(s); };
  Generator.prototype.emitExprList = function (list){ list.forEach((e,i)=>{ if(i>0)this.emit(","); this.emitExpr(e); }); };
  Generator.prototype.emitStat = function (s){
    const k=s.kind;
    if (k==="TypeAlias") return;
    else if (k==="LocalAssign"){
      this.emit("local");
      s.names.forEach((nm,i)=>{ if(i>0)this.emit(","); this.emit(nm.name,"Name"); });
      if (s.exprs.length>0){ this.emit("="); this.emitExprList(s.exprs); }
      this.emit(";");
    }
    else if (k==="LocalFunction"){ this.emit("local"); this.emit("function"); this.emit(s.name,"Name"); this.emitParams(s.body); this.emitBlock(s.body.body); this.emit("end"); this.emit(";"); }
    else if (k==="FunctionDecl"){ this.emit("function"); this.emitExpr(s.target); this.emitParams(s.body); this.emitBlock(s.body.body); this.emit("end"); this.emit(";"); }
    else if (k==="Assign"){ s.targets.forEach((t,i)=>{ if(i>0)this.emit(","); this.emitExpr(t); }); this.emit("="); this.emitExprList(s.exprs); this.emit(";"); }
    else if (k==="CompoundAssign"){ this.emitExpr(s.target); this.emit(s.op+"="); this.emitExpr(s.expr); this.emit(";"); }
    else if (k==="ExprStat"){ this.emitExpr(s.expr); this.emit(";"); }
    else if (k==="Do"){ this.emit("do"); this.emitBlock(s.body); this.emit("end"); }
    else if (k==="While"){ this.emit("while"); this.emitExpr(s.cond); this.emit("do"); this.emitBlock(s.body); this.emit("end"); }
    else if (k==="Repeat"){ this.emit("repeat"); this.emitBlock(s.body); this.emit("until"); this.emitExpr(s.cond); this.emit(";"); }
    else if (k==="If"){
      s.clauses.forEach((c,i)=>{ this.emit(i===0?"if":"elseif"); this.emitExpr(c.cond); this.emit("then"); this.emitBlock(c.body); });
      if (s.elseBody){ this.emit("else"); this.emitBlock(s.elseBody); }
      this.emit("end");
    }
    else if (k==="NumericFor"){
      this.emit("for"); this.emit(s.var,"Name"); this.emit("="); this.emitExpr(s.startE); this.emit(","); this.emitExpr(s.stopE);
      if (s.stepE){ this.emit(","); this.emitExpr(s.stepE); }
      this.emit("do"); this.emitBlock(s.body); this.emit("end");
    }
    else if (k==="GenericFor"){
      this.emit("for"); s.names.forEach((nm,i)=>{ if(i>0)this.emit(","); this.emit(nm,"Name"); });
      this.emit("in"); this.emitExprList(s.exprs); this.emit("do"); this.emitBlock(s.body); this.emit("end");
    }
    else if (k==="Return"){ this.emit("return"); this.emitExprList(s.exprs); this.emit(";"); }
    else if (k==="Break"){ this.emit("break"); this.emit(";"); }
    else if (k==="Continue"){ this.emit("continue"); this.emit(";"); }
    else throw new Error("Generator: unknown stat kind "+k);
  };
  function generate(ast){ const g=new Generator(); g.emitBlock(ast); return g.result(); }

  // ---------------------------------------------------------------- Scope / rename
  const ALPH = ["l","I","i","j","_"]; const BASE = ALPH.length;
  function makeNameGen(prefix){
    let n=0;
    return function(){
      n++; let x=n; const chars=[];
      do { const d=(x-1)%BASE; chars.push(ALPH[d]); x=Math.floor((x-d-1)/BASE); } while (x>0);
      return (prefix||"")+chars.join("");
    };
  }
  function Resolver(nameGen){ this.scopes=[]; this.nameGen=nameGen; }
  Resolver.prototype.push=function(){ this.scopes.push({}); };
  Resolver.prototype.pop=function(){ this.scopes.pop(); };
  Resolver.prototype.declare=function(name){ const b={original:name,new:this.nameGen()}; this.scopes[this.scopes.length-1][name]=b; return b; };
  Resolver.prototype.resolve=function(name){ for(let i=this.scopes.length-1;i>=0;i--){ const b=this.scopes[i][name]; if(b)return b; } return null; };
  Resolver.prototype.expr=function(node){
    if (!node) return;
    const k=node.kind;
    if (k==="Name"){ const b=this.resolve(node.name); if(b)node.name=b.new; }
    else if (k==="Paren") this.expr(node.expr);
    else if (k==="Field") this.expr(node.obj);
    else if (k==="Index"){ this.expr(node.obj); this.expr(node.index); }
    else if (k==="Call"){ this.expr(node.func); this.exprList(node.args); }
    else if (k==="MethodCall"){ this.expr(node.obj); this.exprList(node.args); }
    else if (k==="Binop"){ this.expr(node.lhs); this.expr(node.rhs); }
    else if (k==="Unop") this.expr(node.operand);
    else if (k==="Function") this.func(node);
    else if (k==="Table"){ for(const f of node.fields){ if(f.type==="rec")this.expr(f.key); this.expr(f.value); } }
    else if (k==="IfExpr"){ for(const c of node.clauses){ this.expr(c.cond); this.expr(c.value); } this.expr(node.elseExpr); }
  };
  Resolver.prototype.exprList=function(list){ for(const e of list) this.expr(e); };
  Resolver.prototype.func=function(node){
    this.push();
    for (let i=0;i<node.params.length;i++) node.params[i]=this.declare(node.params[i]).new;
    this.block(node.body);
    this.pop();
  };
  Resolver.prototype.block=function(block){ this.push(); for(const s of block.stats) this.stat(s); this.pop(); };
  Resolver.prototype.blockInline=function(block){ for(const s of block.stats) this.stat(s); };
  Resolver.prototype.stat=function(s){
    const k=s.kind;
    if (k==="LocalAssign"){ this.exprList(s.exprs); for(const nm of s.names) nm.name=this.declare(nm.name).new; }
    else if (k==="LocalFunction"){ const b=this.declare(s.name); s.name=b.new; this.func(s.body); }
    else if (k==="FunctionDecl"){ this.expr(s.target); this.func(s.body); }
    else if (k==="Assign"){ for(const t of s.targets) this.expr(t); this.exprList(s.exprs); }
    else if (k==="CompoundAssign"){ this.expr(s.target); this.expr(s.expr); }
    else if (k==="ExprStat") this.expr(s.expr);
    else if (k==="Do") this.block(s.body);
    else if (k==="While"){ this.expr(s.cond); this.block(s.body); }
    else if (k==="Repeat"){ this.push(); this.blockInline(s.body); this.expr(s.cond); this.pop(); }
    else if (k==="If"){ for(const c of s.clauses){ this.expr(c.cond); this.block(c.body); } if(s.elseBody)this.block(s.elseBody); }
    else if (k==="NumericFor"){ this.expr(s.startE); this.expr(s.stopE); if(s.stepE)this.expr(s.stepE); this.push(); s.var=this.declare(s.var).new; this.blockInline(s.body); this.pop(); }
    else if (k==="GenericFor"){ this.exprList(s.exprs); this.push(); for(let i=0;i<s.names.length;i++)s.names[i]=this.declare(s.names[i]).new; this.blockInline(s.body); this.pop(); }
    else if (k==="Return") this.exprList(s.exprs);
  };
  function renameLocals(ast, opts){
    const r=new Resolver(makeNameGen(opts&&opts.prefix));
    r.push(); r.blockInline(ast); r.pop();
    return ast;
  }

  // ---------------------------------------------------------------- Numbers pass
  function intValue(raw){
    let s=raw.replace(/_/g,"");
    if (/[eEpP.]/.test(s)) return null;
    if (/^0[bB]/.test(s)){ const bits=s.slice(2); if(bits===""||/[^01]/.test(bits))return null; let v=0; for(let i=0;i<bits.length;i++)v=v*2+(bits.charCodeAt(i)-48); return v; }
    if (/^0[xX]/.test(s)){ const v=parseInt(s,16); return isNaN(v)?null:v; }
    if (/^\d+$/.test(s)) return parseInt(s,10);
    return null;
  }
  const numNode = raw => ({ kind:"Number", raw:String(raw) });
  function encodeNum(v, rng, depth){
    if (depth<=0||v===0){
      if (rng.chance(0.5)&&v>=0&&v<2**31) return numNode("0x"+v.toString(16).toUpperCase());
      return numNode(v);
    }
    const pick=rng.int(1,3);
    if (pick===1){ const a=rng.int(0,v); const b=v-a; return {kind:"Binop",op:"+",lhs:encodeNum(a,rng,depth-1),rhs:encodeNum(b,rng,depth-1)}; }
    if (pick===2){ const d=rng.int(1,Math.max(1,v+16)); const c=v+d; return {kind:"Binop",op:"-",lhs:encodeNum(c,rng,depth-1),rhs:encodeNum(d,rng,depth-1)}; }
    const f=rng.int(2,9); const g=Math.floor(v/f); const r=v-f*g;
    const prod={kind:"Binop",op:"*",lhs:encodeNum(f,rng,depth-1),rhs:encodeNum(g,rng,depth-1)};
    if (r===0) return prod;
    return { kind:"Binop", op:"+", lhs:prod, rhs:encodeNum(r,rng,depth-1) };
  }
  function numbersRun(ast, ctx){
    const depth=ctx.opts.numberDepth||2; const rng=ctx.rng; const visited=new Set();
    function walk(node){
      if (typeof node!=="object"||node===null||visited.has(node)) return;
      visited.add(node);
      if (node.kind==="Number"){
        const v=intValue(node.raw);
        if (v!==null&&v>=0&&v<2**53){
          const expr=encodeNum(v,rng,depth);
          if (expr.kind!=="Number"){ node.kind="Paren"; node.expr=expr; delete node.raw; }
        }
        return;
      }
      if (node.kind==="Raw") return;
      for (const key in node){ const child=node[key]; if (typeof child==="object"&&child!==null&&key!=="str"){ if(Array.isArray(child)){ for(const c of child) walk(c); } else walk(child); } }
    }
    walk(ast);
    return ast;
  }

  // ---------------------------------------------------------------- Strings pass
  const KMIX = 2654435761;
  function ks(s){ s=((s^((s<<13)>>>0))>>>0); s=((s^(s>>>17))>>>0); s=((s^((s<<5)>>>0))>>>0); return s>>>0; }
  function slotSeed(seed,j){ return ((seed + j*KMIX) % 4294967295) + 1; }

  const utf8 = (typeof TextEncoder!=="undefined") ? new TextEncoder() : null;
  function strToBytes(str){
    if (utf8) return Array.from(utf8.encode(str));
    const out=[]; for (let i=0;i<str.length;i++){ let c=str.charCodeAt(i);
      if (c<0x80) out.push(c);
      else if (c<0x800){ out.push(0xC0|(c>>6),0x80|(c&0x3F)); }
      else { out.push(0xE0|(c>>12),0x80|((c>>6)&0x3F),0x80|(c&0x3F)); } }
    return out;
  }
  // unescape a Lua short-string inner body to a byte array
  function shortToBytes(inner){
    const bytes=[]; let i=0;
    function pushStr(s){ for (const b of strToBytes(s)) bytes.push(b); }
    while (i<inner.length){
      const c=inner[i];
      if (c!=="\\"){ pushStr(c); i++; continue; }
      i++; const e=inner[i];
      if (e===undefined) break;
      if (e==="n"){ bytes.push(10); i++; }
      else if (e==="t"){ bytes.push(9); i++; }
      else if (e==="r"){ bytes.push(13); i++; }
      else if (e==="a"){ bytes.push(7); i++; }
      else if (e==="b"){ bytes.push(8); i++; }
      else if (e==="f"){ bytes.push(12); i++; }
      else if (e==="v"){ bytes.push(11); i++; }
      else if (e==="\\"){ bytes.push(92); i++; }
      else if (e==='"'){ bytes.push(34); i++; }
      else if (e==="'"){ bytes.push(39); i++; }
      else if (e==="\n"){ bytes.push(10); i++; }
      else if (e==="x"){ const h=inner.substr(i+1,2); bytes.push(parseInt(h,16)&0xFF); i+=3; }
      else if (e==="z"){ i++; while(i<inner.length&&/\s/.test(inner[i]))i++; }
      else if (e==="u"){ // \u{XXXX}
        let j=i+1; if(inner[j]==="{"){ j++; let hex=""; while(j<inner.length&&inner[j]!=="}"){ hex+=inner[j]; j++; } const cp=parseInt(hex,16); pushStr(String.fromCodePoint(cp)); i=j+1; }
        else { bytes.push(117); i++; }
      }
      else if (/[0-9]/.test(e)){ let d=e; let j=i+1; let n=1; while(n<3&&j<inner.length&&/[0-9]/.test(inner[j])){ d+=inner[j]; j++; n++; } bytes.push(parseInt(d,10)&0xFF); i=j; }
      else { pushStr(e); i++; }
    }
    return bytes;
  }
  function realBytes(str){
    if (str.kind==="long") return strToBytes(str.value);
    if (str.kind==="short") return shortToBytes(str.value);
    return null;
  }
  function encryptToLiteral(bytes, seed, j){
    let s=slotSeed(seed,j); const parts=[];
    for (let i=0;i<bytes.length;i++){ s=ks(s); const k=s%256; const enc=(bytes[i]^k)&0xFF; parts.push("\\"+enc); }
    return '"'+parts.join("")+'"';
  }
  function buildDecoderSource(dataLiterals, perm, seed){
    const data="{"+dataLiterals.join(",")+"}";
    const permSrc="{"+perm.join(",")+"}";
    return "(function()\n"+
      "local d="+data+"\n"+
      "local p="+permSrc+"\n"+
      "local SEED="+seed+"\n"+
      "local function ks(s)\n"+
      "s=bit32.bxor(s,bit32.lshift(s,13))\n"+
      "s=bit32.bxor(s,bit32.rshift(s,17))\n"+
      "s=bit32.bxor(s,bit32.lshift(s,5))\n"+
      "return s\n"+
      "end\n"+
      "local pool={}\n"+
      "local bc=string.byte\n"+
      "local ch=string.char\n"+
      "local cc=table.concat\n"+
      "for j=1,#d do\n"+
      "local enc=d[j]\n"+
      "local s=((SEED+j*"+KMIX+")%4294967295)+1\n"+
      "local out={}\n"+
      "for i=1,#enc do\n"+
      "s=ks(s)\n"+
      "out[i]=ch(bit32.bxor(bc(enc,i),s%256))\n"+
      "end\n"+
      "pool[p[j]]=cc(out)\n"+
      "end\n"+
      "return pool\n"+
      "end)()";
  }
  function stringsRun(ast, ctx){
    const seed=ctx.seed>>>0; const poolName=ctx.poolName;
    const values=[]; const indexOf=new Map(); const byteCache=[];
    const visited=new Set();
    function collect(node){
      const bytes=realBytes(node.str);
      if (bytes===null) return null;
      const key=bytes.join(",");
      let idx=indexOf.get(key);
      if (idx===undefined){ values.push(bytes); idx=values.length; indexOf.set(key,idx); }
      return idx;
    }
    function walk(node){
      if (typeof node!=="object"||node===null||visited.has(node)) return;
      visited.add(node);
      if (node.kind==="Raw") return;
      if (node.kind==="String"){
        const idx=collect(node);
        if (idx){ node.kind="Index"; node.obj={kind:"Name",name:poolName}; node.index={kind:"Number",raw:String(idx)}; delete node.str; }
        return;
      }
      for (const key in node){ const child=node[key]; if (typeof child==="object"&&child!==null&&key!=="str"){ if(Array.isArray(child)){ for(const c of child) walk(c); } else walk(child); } }
    }
    for (const s of ast.stats) walk(s);
    const n=values.length;
    if (n===0) return { ast, prelude:null };
    const perm=[]; for (let i=1;i<=n;i++) perm.push(i); ctx.rng.shuffle(perm);
    const dataLiterals=[];
    for (let j=1;j<=n;j++){ const originalIndex=perm[j-1]; dataLiterals.push(encryptToLiteral(values[originalIndex-1], seed, j)); }
    const decoder=buildDecoderSource(dataLiterals, perm, seed);
    const prelude={ kind:"LocalAssign", names:[{name:poolName}], exprs:[{kind:"Raw",text:decoder}] };
    return { ast, prelude };
  }

  // ---------------------------------------------------------------- Flatten pass
  const nameNode = n => ({ kind:"Name", name:n });
  function collectNamesSet(root){
    const used=new Set(); const seen=new Set();
    function walk(node){
      if (typeof node!=="object"||node===null||seen.has(node)) return;
      seen.add(node);
      if (node.kind==="Raw") return;
      if (typeof node.name==="string") used.add(node.name);
      if (typeof node.method==="string") used.add(node.method);
      for (const key in node){ const v=node[key]; if (typeof v==="object"&&v!==null){ if(Array.isArray(v)){ for(const c of v) walk(c); } else walk(v); } }
    }
    walk(root); return used;
  }
  function collectBlocks(ast){
    const blocks=[ast]; const seen=new Set();
    function walk(node){
      if (typeof node!=="object"||node===null||seen.has(node)) return;
      seen.add(node);
      if (node.kind==="Raw") return;
      if (node.kind==="Function"&&typeof node.body==="object") blocks.push(node.body);
      for (const key in node){ const v=node[key]; if (typeof v==="object"&&v!==null){ if(Array.isArray(v)){ for(const c of v) walk(c); } else walk(v); } }
    }
    walk(ast); return blocks;
  }
  function flattenBlock(block, ctx, freshName){
    const stats=block.stats;
    if (stats.length<3) return;
    for (const s of stats){ if (s.kind==="Break"||s.kind==="Continue") return; }
    const n=stats.length;
    const ids=[]; for (let i=1;i<=n;i++) ids.push(i); ctx.rng.shuffle(ids);
    const stateVar=freshName();
    const hoist=[]; const hoistSeen=new Set(); const branches=[];
    for (let idx=0;idx<n;idx++){
      const s=stats[idx]; const body=[]; let isReturn=false;
      if (s.kind==="LocalAssign"){
        for (const nm of s.names){ if(!hoistSeen.has(nm.name)){ hoistSeen.add(nm.name); hoist.push(nm.name); } }
        if (s.exprs.length>0){ const targets=s.names.map(nm=>nameNode(nm.name)); body.push({kind:"Assign",targets,exprs:s.exprs}); }
      } else if (s.kind==="LocalFunction"){
        if(!hoistSeen.has(s.name)){ hoistSeen.add(s.name); hoist.push(s.name); }
        body.push({ kind:"Assign", targets:[nameNode(s.name)], exprs:[s.body] });
      } else if (s.kind==="Return"){ isReturn=true; body.push(s); }
      else body.push(s);
      if (!isReturn){ const nextId=(idx<n-1)?ids[idx+1]:0; body.push({kind:"Assign",targets:[nameNode(stateVar)],exprs:[numNode(nextId)]}); }
      branches[idx]={ id:ids[idx], body };
    }
    const order=[]; for (let i=0;i<n;i++) order.push(i); ctx.rng.shuffle(order);
    const clauses=order.map(idx=>({ cond:{kind:"Binop",op:"==",lhs:nameNode(stateVar),rhs:numNode(branches[idx].id)}, body:{kind:"Block",stats:branches[idx].body} }));
    const ifStat={ kind:"If", clauses, elseBody:null };
    const whileStat={ kind:"While", cond:{kind:"Binop",op:"~=",lhs:nameNode(stateVar),rhs:numNode(0)}, body:{kind:"Block",stats:[ifStat]} };
    const newStats=[];
    if (hoist.length>0) newStats.push({ kind:"LocalAssign", names:hoist.map(h=>({name:h})), exprs:[] });
    newStats.push({ kind:"LocalAssign", names:[{name:stateVar}], exprs:[numNode(ids[0])] });
    newStats.push(whileStat);
    block.stats=newStats;
  }
  function flattenRun(ast, ctx){
    const used=collectNamesSet(ast); let counter=0;
    function freshName(){ while(true){ counter++; const cand="_DLUf"+counter; if(!used.has(cand)){ used.add(cand); return cand; } } }
    for (const block of collectBlocks(ast)) flattenBlock(block, ctx, freshName);
    return ast;
  }

  // ---------------------------------------------------------------- Pipeline
  const PROFILES = {
    none:     { rename:false, strings:false, numbers:false, flatten:false },
    light:    { rename:true,  strings:false, numbers:false, flatten:false },
    balanced: { rename:true,  strings:true,  numbers:true,  flatten:false },
    max:      { rename:true,  strings:true,  numbers:true,  flatten:true  },
  };
  function obfuscate(source, opts){
    opts=opts||{};
    const profileName=opts.profile||"balanced";
    const profile=PROFILES[profileName];
    if (!profile) throw new Error("DeepLuaU: unknown profile '"+profileName+"'");
    const seed=(opts.seed!==undefined&&opts.seed!==null)?opts.seed:(Math.floor(Math.random()*4294967296));
    const rng=new Rng(seed>>>0);
    const ast=new Parser(source).parse();
    const ctx={ rng, seed:seed>>>0, opts, poolName:"_DLU_pool" };
    let prelude=null;
    if (profile.strings){ const r=stringsRun(ast, ctx); prelude=r.prelude; }
    if (profile.numbers) numbersRun(ast, ctx);
    if (prelude) ast.stats.unshift(prelude);
    if (profile.rename) renameLocals(ast, { prefix:opts.namePrefix });
    if (profile.flatten) flattenRun(ast, ctx);
    let out=generate(ast);
    if (opts.header!==false) out="--[[ Protected with DeepLuaU ]] "+out;
    return out;
  }

  const api = { obfuscate, PROFILES, _internal:{ Lexer, Parser, generate, renameLocals } };
  if (typeof module!=="undefined"&&module.exports) module.exports=api;
  root.DeepLuaU=api;
})(typeof globalThis!=="undefined"?globalThis:this);
