#!/usr/bin/env bash
# Focused test for hooks/estimate.sh — the pre-execution estimate helper.
#
# Asserts: valid JSON always; tier monotonicity (heavy >= standard >= light for
# equal scale); scaling with --acs / --files; tier derivation from --difficulty
# / --risk; and null-not-zero on unusable input (the divide-by-zero guard's
# upstream half). estimate.sh needs no jq, but this test parses with jq.
#
# Usage: tests/estimate.test.sh   Exit 0 = all assertions passed.

set -uo pipefail

EST="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/estimate.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[ -f "$EST" ] || { echo "FAIL: $EST missing"; exit 1; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-52s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-52s got=%s want=%s\n' "$1" "$2" "$3"; fi; }
expect_true(){ if [ "$2" -eq 1 ] 2>/dev/null; then PASS=$((PASS+1)); printf '  PASS  %-52s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-52s (condition false)\n' "$1"; fi; }

j(){ bash "$EST" "$@"; }
field(){ printf '%s' "$1" | jq -r "$2"; }

echo "================ estimate.sh ================"

H="$(j --tier heavy --acs 3 --files 3)"
S="$(j --tier standard --acs 3 --files 3)"
L="$(j --tier light --acs 3 --files 3)"

expect "heavy is valid JSON"        "$(printf '%s' "$H" | jq empty >/dev/null 2>&1; echo $?)" "0"
expect "standard is valid JSON"     "$(printf '%s' "$S" | jq empty >/dev/null 2>&1; echo $?)" "0"
expect "light is valid JSON"        "$(printf '%s' "$L" | jq empty >/dev/null 2>&1; echo $?)" "0"

hd="$(field "$H" .duration_min)"; sd="$(field "$S" .duration_min)"; ld="$(field "$L" .duration_min)"
ht="$(field "$H" .tokens_total)"; st="$(field "$S" .tokens_total)"; lt="$(field "$L" .tokens_total)"
expect_true "duration monotonic heavy>=standard"  "$([ "$hd" -ge "$sd" ] && echo 1 || echo 0)"
expect_true "duration monotonic standard>=light"  "$([ "$sd" -ge "$ld" ] && echo 1 || echo 0)"
expect_true "tokens monotonic heavy>=standard"    "$([ "$ht" -ge "$st" ] && echo 1 || echo 0)"
expect_true "tokens monotonic standard>=light"    "$([ "$st" -ge "$lt" ] && echo 1 || echo 0)"

# Scaling: more ACs / files => larger.
A0="$(field "$(j --tier heavy --acs 0 --files 0)" .duration_min)"
A9="$(field "$(j --tier heavy --acs 9 --files 0)" .duration_min)"
F9="$(field "$(j --tier heavy --acs 0 --files 9)" .tokens_total)"
F0="$(field "$(j --tier heavy --acs 0 --files 0)" .tokens_total)"
expect_true "duration scales with acs"   "$([ "$A9" -gt "$A0" ] && echo 1 || echo 0)"
expect_true "tokens scales with files"   "$([ "$F9" -gt "$F0" ] && echo 1 || echo 0)"

# Breakdown sums to <= total and is present.
bsum="$(printf '%s' "$H" | jq '.tokens_breakdown.input + .tokens_breakdown.output + .tokens_breakdown.cache')"
expect "breakdown sums to total"    "$bsum" "$ht"

# Tier derivation from D/R (no --tier): max(D,R)=7 -> heavy bucket == explicit heavy.
DERIVED="$(field "$(j --difficulty 7 --risk 3 --acs 3 --files 3)" .duration_min)"
expect "derived heavy == explicit heavy" "$DERIVED" "$hd"
DSTD="$(field "$(j --difficulty 4 --risk 1 --acs 3 --files 3)" .duration_min)"
expect "derived standard == explicit standard" "$DSTD" "$sd"

# Null (not zero) on unusable input.
expect "no args -> duration null"   "$(field "$(j)" .duration_min)"          "null"
expect "no args -> tokens null"     "$(field "$(j)" .tokens_total)"          "null"
expect "bad tier -> duration null"  "$(field "$(j --tier frob)" .duration_min)" "null"
expect "no args still valid JSON"   "$(bash "$EST" | jq empty >/dev/null 2>&1; echo $?)" "0"
expect "unknown flags ignored (valid JSON)" "$(bash "$EST" --wat x --tier light | jq empty >/dev/null 2>&1; echo $?)" "0"
expect "estimate.sh always exits 0" "$(bash "$EST" --tier frob >/dev/null 2>&1; echo $?)" "0"
# Leading-zero counts must NOT be read as octal (regression: "08"/"09" aborted
# arithmetic -> unbound var -> exit 1, no JSON).
OCT="$(j --tier heavy --acs 08 --files 09)"
expect "octal-looking acs/files: valid JSON" "$(printf '%s' "$OCT" | jq empty >/dev/null 2>&1; echo $?)" "0"
expect "octal-looking acs/files: exit 0"     "$(bash "$EST" --tier heavy --acs 08 --files 09 >/dev/null 2>&1; echo $?)" "0"
expect "08 treated as decimal 8"             "$(field "$OCT" .duration_min)" "$(field "$(j --tier heavy --acs 8 --files 9)" .duration_min)"

echo ""
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
