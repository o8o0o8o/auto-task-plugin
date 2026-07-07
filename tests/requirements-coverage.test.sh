#!/usr/bin/env bash
# Focused test for hooks/requirements-coverage.sh — requirement coverage/completion.
#
# Asserts: covered vs uncovered (>=1 AC), complete vs incomplete (status==done),
# dropped requirements excluded from the incomplete set, all_covered/all_complete
# booleans, and fail-open (missing file / no requirements -> valid empty object).
#
# Usage: tests/requirements-coverage.test.sh   Exit 0 = all passed.

set -uo pipefail

RC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/requirements-coverage.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[ -f "$RC" ] || { echo "FAIL: $RC missing"; exit 1; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-52s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-52s got=%s want=%s\n' "$1" "$2" "$3"; fi; }
field(){ printf '%s' "$1" | jq -c "$2"; }

echo "================ requirements-coverage.sh ================"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# R1 covered+done, R2 covered+pending (incomplete), R3 uncovered+pending, R4 dropped.
cat > "$T/state.json" <<'EOF'
{"requirements":[
  {"id":"R1","text":"a","covered_by_acs":[1,2],"status":"done"},
  {"id":"R2","text":"b","covered_by_acs":[3],"status":"pending"},
  {"id":"R3","text":"c","covered_by_acs":[],"status":"pending"},
  {"id":"R4","text":"d","covered_by_acs":[],"status":"dropped"}
]}
EOF
OUT="$(bash "$RC" "$T/state.json")"
expect "valid JSON"              "$(printf '%s' "$OUT" | jq empty >/dev/null 2>&1; echo $?)" "0"
expect "total counts all incl dropped" "$(field "$OUT" .total)"        "4"
expect "covered (active w/ >=1 ac)"     "$(field "$OUT" .covered)"      "2"
expect "uncovered lists R3 only"        "$(field "$OUT" .uncovered)"    '["R3"]'
expect "complete (status done)"         "$(field "$OUT" .complete)"     "1"
expect "incomplete lists R2,R3"         "$(field "$OUT" .incomplete)"   '["R2","R3"]'
expect "dropped lists R4"               "$(field "$OUT" .dropped)"      '["R4"]'
expect "all_covered false (R3)"         "$(field "$OUT" .all_covered)"  "false"
expect "all_complete false"             "$(field "$OUT" .all_complete)" "false"

# All good scenario.
cat > "$T/good.json" <<'EOF'
{"requirements":[
  {"id":"R1","text":"a","covered_by_acs":[1],"status":"done"},
  {"id":"R2","text":"b","covered_by_acs":[2],"status":"done"}
]}
EOF
G="$(bash "$RC" "$T/good.json")"
expect "good: all_covered true"   "$(field "$G" .all_covered)"  "true"
expect "good: all_complete true"  "$(field "$G" .all_complete)" "true"

# Fail-open: missing file, no requirements, no arg.
M="$(bash "$RC" /no/such/state.json)"
expect "missing file valid JSON"  "$(printf '%s' "$M" | jq empty >/dev/null 2>&1; echo $?)" "0"
expect "missing file total 0"     "$(field "$M" .total)" "0"
expect "missing file all_complete true" "$(field "$M" .all_complete)" "true"
printf '{}' > "$T/empty.json"
E="$(bash "$RC" "$T/empty.json")"
expect "no requirements total 0"  "$(field "$E" .total)" "0"
expect "no-arg exits 0"           "$(bash "$RC" >/dev/null 2>&1; echo $?)" "0"

# Guard against the jq-1.6-incompatible trailing comma (a `,` immediately before
# a `}`/`]` compiles on jq>=1.7 but ERRORS on jq 1.6 — where fail-open would then
# silently return all_covered/all_complete=true). Scan all new metric helpers.
HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
tc="$(awk '
  prev ~ /,[[:space:]]*$/ && $0 ~ /^[[:space:]]*[]}]/ { print FILENAME":"NR-1 }
  { prev=$0 }
' "$HDIR/estimate.sh" "$HDIR/token-usage.sh" "$HDIR/checks.sh" "$HDIR/requirements-coverage.sh" 2>/dev/null)"
expect "no jq-1.6-breaking trailing comma in helpers" "${tc:-none}" "none"

echo ""
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
