#!/usr/bin/env bash
# Focused test for hooks/repo-metrics.sh — anonymous size + change-heat signals.
#
# Asserts: file-count bucket + primary language + monorepo heuristic; churn_ratio
# rises when files are re-touched (via a LOCAL history that never leaves); hotspot
# concentration + dirs_touched + max_depth; and — critically — the output carries
# NO path/file names (anonymity). Fail-open: non-repo / no base -> valid JSON, no crash.
#
# Hermetic: builds throwaway git repos in a temp dir; AUTO_TASK_CHURN_FILE keeps
# the churn history out of any real location. Usage: tests/repo-metrics.test.sh

set -uo pipefail

SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/repo-metrics.sh"
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
[ -f "$SH" ] || { echo "FAIL: $SH missing"; exit 1; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-50s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-50s got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }

echo "================ repo-metrics.sh ================"
bash -n "$SH"; expect "bash -n clean" "$?" "0"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
R="$T/repo"; git init -q "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
mkdir -p "$R/src/app" "$R/src/lib" "$R/packages/p" "$R/apps/a"
printf 'a\nb\n' > "$R/src/app/main.ts"; printf 'u\n' > "$R/src/lib/u.ts"; printf '{}' > "$R/package.json"
git -C "$R" add -A; git -C "$R" commit -qm base >/dev/null 2>&1
BASE="$(git -C "$R" rev-parse HEAD)"
CF="$T/churn.tsv"

# change main.ts heavily + add new.ts
printf 'a\nb\nc\nd\ne\n' > "$R/src/app/main.ts"; printf 'n\n' > "$R/src/app/new.ts"
git -C "$R" add -A; git -C "$R" commit -qm c1 >/dev/null 2>&1
J1="$(AUTO_TASK_CHURN_FILE="$CF" bash "$SH" --repo "$R" --base "$BASE")"
expect "valid JSON"                "$(printf '%s' "$J1" | jq -e . >/dev/null 2>&1 && echo ok)" "ok"
expect "files bucket <100"         "$(printf '%s' "$J1" | jq -r .repo_files_bucket)" "<100"
expect "primary language ts"       "$(printf '%s' "$J1" | jq -r .primary_language)" "ts"
expect "monorepo detected"         "$(printf '%s' "$J1" | jq -r .is_monorepo)" "true"
expect "churn 0 on first sight"    "$(printf '%s' "$J1" | jq -r .churn_ratio)" "0.000"
expect "dirs_touched = 1 (src)"    "$(printf '%s' "$J1" | jq -r .dirs_touched)" "1"
expect "max_depth = 3"             "$(printf '%s' "$J1" | jq -r .max_depth)" "3"
# hotspot: main.ts +3, new.ts +1 -> 3/4 = 0.75
expect "hotspot concentration .75" "$(printf '%s' "$J1" | jq -r .hotspot_concentration)" "0.750"
# ANONYMITY: no path/file name in the output
expect "no path leaked (main.ts)"  "$(printf '%s' "$J1" | jq -r 'tostring | test("main\\.ts|src/|new\\.ts") | not')" "true"

# second run re-touches main.ts -> churn > 0 (it's in local history now)
printf 'a\n' > "$R/src/app/main.ts"; git -C "$R" add -A; git -C "$R" commit -qm c2 >/dev/null 2>&1
J2="$(AUTO_TASK_CHURN_FILE="$CF" bash "$SH" --repo "$R" --base "$(git -C "$R" rev-parse HEAD~1)")"
expect "churn 1.0 on re-touch"     "$(printf '%s' "$J2" | jq -r .churn_ratio)" "1.000"

# fail-open: not a repo dir -> {} , exit 0
J3="$(bash "$SH" --repo "$T/not-a-repo" --base x)"; rc=$?
expect "non-repo -> exit 0"        "$rc" "0"
expect "non-repo -> {}"            "$(printf '%s' "$J3" | jq -c .)" "{}"
# fail-open: repo but no base -> valid JSON, churn/dirs null
J4="$(AUTO_TASK_CHURN_FILE="$CF" bash "$SH" --repo "$R")"
expect "no base -> valid JSON"     "$(printf '%s' "$J4" | jq -e . >/dev/null 2>&1 && echo ok)" "ok"
expect "no base -> churn null"     "$(printf '%s' "$J4" | jq -r .churn_ratio)" "null"

echo "repo-metrics.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
