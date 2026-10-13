import { execFileSync } from "node:child_process";
import { writeFileSync, readFileSync, readdirSync } from "node:fs";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const DeepLuaU = require("../web/deepluau.js");

const profiles = ["none","light","balanced","max"];
const examples = readdirSync("examples").filter(f=>f.endsWith(".luau")).map(f=>"examples/"+f);
const run = p => execFileSync("luau",[p],{encoding:"utf8"});

let pass=0, fail=0;
for (const ex of examples){
  const src = readFileSync(ex,"utf8");
  let base;
  try { base = run(ex); } catch(e){ console.log("SKIP (orig fails):", ex); continue; }
  for (const prof of profiles){
    let out;
    try { out = DeepLuaU.obfuscate(src,{profile:prof, seed:12345}); }
    catch(e){ console.log(`  FAIL ${ex} ${prof}: obf threw: ${e.message}`); fail++; continue; }
    const tmp = `/tmp/jsval_${prof}.luau`;
    writeFileSync(tmp,out);
    let got;
    try { got = run(tmp); }
    catch(e){ console.log(`  FAIL ${ex} ${prof}: luau run error:\n    ${String(e.stderr||e.message).split("\n").slice(0,3).join("\n    ")}`); fail++; continue; }
    if (got===base){ console.log(`  ok   ${ex.padEnd(22)} ${prof.padEnd(9)} ${src.length}->${out.length}`); pass++; }
    else { console.log(`  FAIL ${ex} ${prof}: output mismatch`);
      console.log("    base:", JSON.stringify(base.slice(0,120)));
      console.log("    got :", JSON.stringify(got.slice(0,120))); fail++; }
  }
}
console.log(`\n${pass}/${pass+fail} passed`);
process.exit(fail?1:0);
