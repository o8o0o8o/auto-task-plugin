#!/usr/bin/env bash
# Focused test for hooks/checks.sh — universal hygiene/defect checks over a diff.
#
# Asserts: secret in real source -> fail; the SAME secret in a test/fixture path
# -> demoted to warn; conflict marker in an UNTRACKED new file -> fail (untracked
# files are scanned); debug artifact -> warn; tests-added detection; diff-size
# info; and all-skip on no --base / non-repo. Trip-strings (fake secret, conflict
# marker) are CONSTRUCTED AT RUNTIME so they never live verbatim in this tracked
# test source (which would make checks.sh flag its own repo).
#
# git commits happen INSIDE this script (a single Bash tool call), so the
# enforce-gates PreToolUse hook — which scans only the top-level command — does
# not intercept them.
#
# Usage: tests/checks.test.sh   Exit 0 = all passed.

set -uo pipefail

CH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/checks.sh"
for t in git jq; do command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not installed"; exit 0; }; done
[ -f "$CH" ] || { echo "FAIL: $CH missing"; exit 1; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-52s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-52s got=%s want=%s\n' "$1" "$2" "$3"; fi; }
# result of a named check row from the JSON array output
res(){ printf '%s' "$1" | jq -r --arg n "$2" '.[] | select(.name==$n) | .result'; }

# Runtime-constructed trip-strings (never verbatim in tracked source).
SEC="AKIA$(printf 'A%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 | tr -d ' ')"  # AKIA + 16 upper
LT="$(printf '<%.0s' 1 2 3 4 5 6 7)"   # 7 '<'

echo "================ checks.sh ================"

# --- Scenario 1: secret in real source + conflict in untracked + debug ---------
T="$(mktemp -d)"; trap 'rm -rf "$T" "$T2"' EXIT
(
  cd "$T"
  git init -q; git config user.email t@t; git config user.name t
  echo seed > seed.txt; git add -A; git commit -qm base
)
BASE="$(cd "$T" && git rev-parse HEAD)"
# tracked-modified source file carrying a secret + a debug line
printf 'const k = "%s"\nconsole.log("dbg")\n' "$SEC" > "$T/src.js"
( cd "$T" && git add src.js )   # tracked
# untracked NEW source file carrying a conflict marker
printf '%s HEAD\ncode\n' "$LT" > "$T/newmod.js"
# a fixture/test-path file carrying the same secret -> should demote to warn
mkdir -p "$T/tests"
printf 'const fake = "%s"\n' "$SEC" > "$T/tests/data.test.js"

OUT="$(cd "$T" && bash "$CH" --base "$BASE")"
expect "valid JSON array"            "$(printf '%s' "$OUT" | jq 'type' 2>/dev/null)" '"array"'
expect "secret in source -> fail"    "$(res "$OUT" secret-scan)"      "fail"
expect "conflict (untracked) -> fail" "$(res "$OUT" conflict-markers)" "fail"
expect "debug artifact -> warn"      "$(res "$OUT" debug-artifacts)"  "warn"
expect "tests-added -> pass"         "$(res "$OUT" tests-added)"      "pass"
expect "diff-size -> info"           "$(res "$OUT" diff-size)"        "info"
expect "checks.sh exits 0"           "$(cd "$T" && bash "$CH" --base "$BASE" >/dev/null 2>&1; echo $?)" "0"

# --- Scenario 2: secret ONLY in a fixture path -> demoted to warn --------------
T2="$(mktemp -d)"
(
  cd "$T2"
  git init -q; git config user.email t@t; git config user.name t
  echo seed > seed.txt; git add -A; git commit -qm base
)
B2="$(cd "$T2" && git rev-parse HEAD)"
mkdir -p "$T2/__fixtures__"
printf 'token = "%s"\n' "$SEC" > "$T2/__fixtures__/creds.txt"   # untracked, fixture path
OUT2="$(cd "$T2" && bash "$CH" --base "$B2")"
expect "secret in fixture only -> warn" "$(res "$OUT2" secret-scan)" "warn"

# --- Scenario 3: no --base / not a repo -> all skip ---------------------------
OUT3="$(bash "$CH")"
expect "no base -> secret skip"      "$(res "$OUT3" secret-scan)" "skip"
expect "no base -> valid JSON"       "$(printf '%s' "$OUT3" | jq 'length' 2>/dev/null)" "6"
OUT4="$(cd /tmp && bash "$CH" --base deadbeef)"
expect "bad base -> skip"            "$(res "$OUT4" secret-scan)" "skip"

# --- Scenario 4: secret in a RENAMED+modified file must still be caught --------
# (regression: `git diff --numstat` without --no-renames emits a brace-form path
# `{old => new}` that `git diff -- "$p"` can't resolve, silently skipping the scan.)
T3="$(mktemp -d)"
(
  cd "$T3"
  git init -q; git config user.email t@t; git config user.name t
  echo original > old.js; git add -A; git commit -qm base
)
B3="$(cd "$T3" && git rev-parse HEAD)"
( cd "$T3" && git mv old.js new.js )                 # staged rename
printf 'const k = "%s"\n' "$SEC" >> "$T3/new.js"     # + a secret in the renamed file
OUT5="$(cd "$T3" && bash "$CH" --base "$B3")"
expect "secret in renamed file -> fail" "$(res "$OUT5" secret-scan)" "fail"
rm -rf "$T3"

echo ""
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
