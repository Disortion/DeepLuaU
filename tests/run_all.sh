#!/usr/bin/env bash
# DeepLuaU test runner: for every example and every profile, obfuscate the program
# and assert the transformed program produces identical runtime output. Rebuilds the
# bundle first and verifies it matches the module build.
set -u
cd "$(dirname "$0")/.."

PROFILES=(none light balanced max)
EXAMPLES=(examples/*.luau)
fail=0
total=0
pass=0

echo "== building bundle =="
python3 tools/bundle.py || { echo "bundle failed"; exit 1; }

echo
echo "== behavioural equivalence (original vs obfuscated) =="
for ex in "${EXAMPLES[@]}"; do
	for p in "${PROFILES[@]}"; do
		total=$((total+1))
		out=$(python3 tests/harness.py "$ex" "$p" 2>&1)
		if echo "$out" | grep -q "MATCH"; then
			pass=$((pass+1))
			printf "  ok   %-28s %-9s %s\n" "$(basename "$ex")" "$p" "$(echo "$out" | grep -o '(orig.*)')"
		else
			fail=$((fail+1))
			printf "  FAIL %-28s %-9s\n" "$(basename "$ex")" "$p"
			echo "$out" | sed 's/^/        /'
		fi
	done
done

echo
echo "== summary: $pass/$total passed =="
[ "$fail" -eq 0 ] || { echo "FAILURES: $fail"; exit 1; }
echo "all green"
