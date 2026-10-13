#!/usr/bin/env python3
"""Test harness: embeds a Luau source file into a driver that obfuscates it and
compares captured print() output of the original vs the transformed program.

Usage: python3 tests/harness.py <source.luau> [profile]
Exit code 0 on match, 1 on mismatch/error.
"""
import subprocess, sys, os

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def bracket(src: str) -> str:
    lvl = 0
    while ("]" + "=" * lvl + "]") in src or ("[" + "=" * lvl + "[") in src:
        lvl += 1
    eq = "=" * lvl
    return f"[{eq}[\n{src}]{eq}]"

DRIVER = r'''
local SRC = __SRC__
local Obfuscator = require("../src/Obfuscator")

local transformed = Obfuscator.obfuscate(SRC, { profile = __PROFILE__, seed = 12345 })

local function runCaptured(code, label)
	local buf = {}
	local realprint = print
	local env = setmetatable({ print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
		buf[#buf + 1] = table.concat(parts, "\t")
	end }, { __index = getfenv and getfenv() or _G })
	local fn, err = loadstring(code, label)
	if not fn then return nil, "compile error: " .. tostring(err) end
	if setfenv then setfenv(fn, env) end
	local ok, rerr = pcall(fn)
	if not ok then return nil, "runtime error: " .. tostring(rerr) end
	return table.concat(buf, "\n")
end

local a, ea = runCaptured(SRC, "orig")
local b, eb = runCaptured(transformed, "obf")

if not a then error("ORIG_FAIL: " .. tostring(ea)) end
if not b then
	print("OBF_FAIL: " .. tostring(eb))
	print("---- transformed source ----")
	print(transformed)
	error("obf failed")
end
if a == b then
	print(("MATCH  (orig %d chars -> obf %d chars)"):format(#SRC, #transformed))
else
	print("MISMATCH")
	print("--- orig output ---"); print(a)
	print("--- obf output ---"); print(b)
	print("--- transformed source (first 1200 chars) ---")
	print(transformed:sub(1, 1200))
	error("mismatch")
end
'''

def main():
    if len(sys.argv) < 2:
        print("usage: harness.py <source.luau> [profile]"); sys.exit(2)
    src_path = sys.argv[1]
    profile = sys.argv[2] if len(sys.argv) > 2 else "balanced"
    with open(src_path) as f:
        src = f.read()
    driver = DRIVER.replace("__SRC__", bracket(src)).replace("__PROFILE__", '"%s"' % profile)
    drv_path = os.path.join(REPO, "tests", "_driver.luau")
    with open(drv_path, "w") as f:
        f.write(driver)
    r = subprocess.run(["luau", "tests/_driver.luau"], cwd=REPO,
                       capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    if r.stderr.strip():
        sys.stderr.write(r.stderr)
    sys.exit(0 if r.returncode == 0 and "MATCH" in r.stdout else 1)

if __name__ == "__main__":
    main()
