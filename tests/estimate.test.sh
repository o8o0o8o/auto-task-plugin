#!/usr/bin/env bash
# Focused test for hooks/estimate.sh — the pre-execution estimate helper.
#
# Asserts: valid JSON always; tier monotonicity (heavy >= standard >= light for
# equal scale); scaling with --acs / --files; tier derivation from --difficulty
# / --risk; and null-not-zero on unusable input (the divide-by-zero guard's
# upstream half). estimate.sh needs no jq, but this test parses with jq.
#
# Also pins the OUTPUT-TOKEN contract (as of the n=4 calibration): the emitted
# token field is `tokens_output`, and `tokens_total`/`tokens_breakdown` are ABSENT
# rather than null. That shape is load-bearing, not cosmetic — emitting a
# cache-inclusive "total" is what let a ~1M estimate be compared against a
# 107M-486M measured total, a 66x-434x unit error. The absence assertions are the
# half that matters: a null-but-present `tokens_total` would invite the same
# misuse back, and `.tokens_total` on an object without the key ALSO reads as
# null, so only has() can tell the two apart.
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
ht="$(field "$H" .tokens_output)"; st="$(field "$S" .tokens_output)"; lt="$(field "$L" .tokens_output)"
expect_true "duration monotonic heavy>=standard"  "$([ "$hd" -ge "$sd" ] && echo 1 || echo 0)"
expect_true "duration monotonic standard>=light"  "$([ "$sd" -ge "$ld" ] && echo 1 || echo 0)"
expect_true "tokens monotonic heavy>=standard"    "$([ "$ht" -ge "$st" ] && echo 1 || echo 0)"
expect_true "tokens monotonic standard>=light"    "$([ "$st" -ge "$lt" ] && echo 1 || echo 0)"

# Scaling: more ACs / files => larger.
A0="$(field "$(j --tier heavy --acs 0 --files 0)" .duration_min)"
A9="$(field "$(j --tier heavy --acs 9 --files 0)" .duration_min)"
F9="$(field "$(j --tier heavy --acs 0 --files 9)" .tokens_output)"
F0="$(field "$(j --tier heavy --acs 0 --files 0)" .tokens_output)"
expect_true "duration scales with acs"   "$([ "$A9" -gt "$A0" ] && echo 1 || echo 0)"
expect_true "tokens scales with files"   "$([ "$F9" -gt "$F0" ] && echo 1 || echo 0)"

echo "---------------- output-token shape (no estimable total/breakdown) ----------------"
# The emitted token field is tokens_output. tokens_total / tokens_breakdown must be
# ABSENT, not null: `.tokens_total` reads null either way, so has() is the only
# assertion that can tell "deliberately not emitted" from "emitted as null".
expect "emits tokens_output"              "$(field "$H" 'has("tokens_output")')"    "true"
expect "does NOT emit tokens_total"       "$(field "$H" 'has("tokens_total")')"     "false"
expect "does NOT emit tokens_breakdown"   "$(field "$H" 'has("tokens_breakdown")')" "false"
# Same on the null path — the shape must not change between the two exits.
NUL="$(j)"
expect "null path emits tokens_output"        "$(field "$NUL" 'has("tokens_output")')"    "true"
expect "null path omits tokens_total"         "$(field "$NUL" 'has("tokens_total")')"     "false"
expect "null path omits tokens_breakdown"     "$(field "$NUL" 'has("tokens_breakdown")')" "false"
# The basis must say the figure is output tokens, so a reader of PLAN.md / STATE.json
# cannot mistake it for the old cache-inclusive total.
expect "basis names the output scale"     "$(printf '%s' "$H" | jq -r '.basis | test("tok-output") | tostring')" "true"
expect "basis records the calibration n"  "$(printf '%s' "$H" | jq -r '.basis | test("calibrated\\(n=") | tostring')" "true"

echo "---------------- calibrated constants (n=4 fit) ----------------"
# Pin the calibrated values. These are derived in
# .auto-task/<branch>/recon/calibration-derivation.md from four measured runs
# (output 443,770-1,027,985). A silent edit away from them re-breaks the estimate,
# so the fit is asserted end-to-end rather than by grepping the constants.
#   heavy, acs=15, files=8  -> 700000 + 15*5000 + 8*6000 = 823000
#   standard, acs=19,files=5 -> 400000 + 19*5000 + 5*6000 = 525000
#   light, acs=0, files=0    -> 225000 (extrapolated tier - no light run measured)
expect "heavy 15ac/8f  == 823000"   "$(field "$(j --tier heavy --acs 15 --files 8)" .tokens_output)"    "823000"
expect "standard 19ac/5f == 525000" "$(field "$(j --tier standard --acs 19 --files 5)" .tokens_output)" "525000"
expect "light base == 225000"       "$(field "$(j --tier light --acs 0 --files 0)" .tokens_output)"     "225000"
# Time bases after the ~2.5x bump (12/35/70 -> 30/88/175); PER_*_MIN stay at 2.
expect "heavy time base == 175"     "$(field "$(j --tier heavy --acs 0 --files 0)" .duration_min)"      "175"
expect "standard time base == 88"   "$(field "$(j --tier standard --acs 0 --files 0)" .duration_min)"   "88"
expect "light time base == 30"      "$(field "$(j --tier light --acs 0 --files 0)" .duration_min)"      "30"
expect "PER_AC_MIN+PER_FILE_MIN=2 each" "$(field "$(j --tier light --acs 1 --files 1)" .duration_min)"  "34"
# The token estimate must stay in the measured band for a realistic heavy run —
# the actual defect being guarded is an order-of-magnitude drift, not a few percent.
HB="$(field "$(j --tier heavy --acs 15 --files 8)" .tokens_output)"
expect_true "heavy estimate within measured 200k-2M band" \
  "$([ "$HB" -ge 200000 ] && [ "$HB" -le 2000000 ] && echo 1 || echo 0)"

# Tier derivation from D/R (no --tier): max(D,R)=7 -> heavy bucket == explicit heavy.
DERIVED="$(field "$(j --difficulty 7 --risk 3 --acs 3 --files 3)" .duration_min)"
expect "derived heavy == explicit heavy" "$DERIVED" "$hd"
DSTD="$(field "$(j --difficulty 4 --risk 1 --acs 3 --files 3)" .duration_min)"
expect "derived standard == explicit standard" "$DSTD" "$sd"

# Null (not zero) on unusable input.
expect "no args -> duration null"   "$(field "$(j)" .duration_min)"          "null"
expect "no args -> tokens null"     "$(field "$(j)" .tokens_output)"         "null"
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
