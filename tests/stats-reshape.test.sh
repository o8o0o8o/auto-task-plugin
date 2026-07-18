#!/usr/bin/env bash
# Behavioral tests for the v0.23.0 telemetry RESHAPE in auto-task-stats.sh:
#   - test-verified quality is the HEADLINE; completion is demoted to a labeled
#     liveness/operational signal (ordering + label).
#   - rate metrics carry a Wilson CI + sample size; n=0 populations are safe.
#   - version-over-version regression guard: flags >=MDE, silent on sub-MDE,
#     "insufficient data" below the sample floor or with a single version.
#   - thresholds are env-overridable.
#   - --recalibrate SUGGESTS estimate.sh constants (suggest-only; never edits it).
# Usage: tests/stats-reshape.test.sh   Exit 0 = all passed.

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
STATS="$HOOKS/auto-task-stats.sh"; EST="$HOOKS/estimate.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-54s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-54s got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }
has(){ if printf '%s' "$2" | grep -qE -- "$3"; then PASS=$((PASS+1)); printf '  PASS  %-54s (found)\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-54s (missing rx: %s)\n' "$1" "$3"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qE -- "$3"; then FAIL=$((FAIL+1)); printf '  FAIL  %-54s (unexpected rx: %s)\n' "$1" "$3"
  else PASS=$((PASS+1)); printf '  PASS  %-54s (absent)\n' "$1"; fi; }

# Emit N done rows for a plugin_version. $1=ver $2=count $3=late_count
# $4=est_tok $5=act_tok . flaky/tests fixed; est/act duration fixed.
emit(){ local ver="$1" n="$2" lc="$3" et="$4" at="$5" i late dl
  for i in $(seq 1 "$n"); do
    late=0; [ "$i" -le "$lc" ] && late=1
    printf '{"at":"2026-05-01T10:00:00Z","branch":"feat/%s-%d","base":"%s-%d","plugin_version":"%s","terminal_state":"done","tier":"standard","tier_initial":"standard","escalations":0,"fix_iterations":1,"review_iterations":1,"gate_b":"passed","followups":0,"duration_min":40,"est_duration_min":40,"est_tokens":%s,"act_duration_min":52,"act_tokens":%s,"defects_early":2,"defects_late":%d,"flaky":false,"tests_added":true,"diff_loc":80,"first_pass_ac":0.8,"checks_run":5,"checks_failed":0,"pr_url":null}\n' \
      "$ver" "$i" "$ver" "$i" "$ver" "$et" "$at" "$late"
  done
}
mkproj(){ local d; d="$(mktemp -d)"; ( cd "$d" && git init -q && git checkout -q -b main ); mkdir -p "$d/.auto-task"; printf '%s' "$d"; }
runs(){ AUTO_TASK_PR_RESOLVE=0 CLAUDE_PROJECT_DIR="$1" bash "$STATS" "${@:2}" 2>&1; }

echo "================ headline ordering + liveness demotion (AC#1) ================"
P1="$(mkproj)"; emit 0.22.0 12 2 900000 1000000 > "$P1/.auto-task/outcomes.jsonl"
O1="$(runs "$P1")"
nq="$(printf '%s\n' "$O1" | grep -n 'Quality (test-verified' | head -1 | cut -d: -f1)"
nc="$(printf '%s\n' "$O1" | grep -n 'Completion rate' | head -1 | cut -d: -f1)"
expect "quality header precedes completion (Nq<Nc)" "$([ -n "$nq" ] && [ -n "$nc" ] && [ "$nq" -lt "$nc" ] && echo yes || echo no)" "yes"
has "completion labeled liveness/operational"      "$O1" 'Liveness / operational \(NOT a quality signal\)'
has "completion line still present"                "$O1" 'Completion rate +[0-9]+%'

echo "================ Wilson CI + sample size on rate metrics (AC#2a) ================"
has "late-defect rate carries CI + n"  "$O1" 'Late-defect rate +[0-9.]+% \[[0-9.]+–[0-9.]+\] \(n=12\)'
has "tests-added rate carries CI + n"  "$O1" 'Tests-added rate +[0-9.]+% \[[0-9.]+–[0-9.]+\] \(n=12\)'
has "completion rate carries CI"       "$O1" 'Completion rate +[0-9]+% \[[0-9.]+–[0-9.]+\]'

echo "================ n=0 population is safe, no NaN (AC#2b) ================"
# A project with only a live in-flight run and an empty ledger: total>0, done=0,
# so agg runs over an empty row set → every rate population is 0.
P0="$(mkproj)"; : > "$P0/.auto-task/outcomes.jsonl"
mkdir -p "$P0/.auto-task/feat/live"
cat > "$P0/.auto-task/feat/live/STATE.json" <<EOF
{"phase":"execute","approved":true,"branch":"feat/live","base":"LIVE","history":[{"phase":"execute","result":"ok","at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}]}
EOF
O0="$(runs "$P0"; echo "EXIT=$?")"
has  "n=0 rate prints 'n=0 (no data)'" "$O0" 'Late-defect rate +n=0 \(no data\)'
hasnt "no NaN in output"               "$O0" 'nan|NaN|null%'
has  "exits 0 on n=0"                   "$O0" 'EXIT=0'

echo "================ regression guard: flag / sub-MDE / sparse / single (AC#7) ================"
# (a) two versions >=floor, late 16.7% -> 50% (Δ33.3pp) AND token ratio 1.1x->2x
PA="$(mkproj)"; { emit 0.22.0 12 2 900000 1000000; emit 0.23.0 12 6 900000 1800000; } > "$PA/.auto-task/outcomes.jsonl"
OA="$(runs "$PA")"
has "(a) flags late-defect >=MDE"   "$OA" '⚠ late-defect rate: 16.7% → 50%'
has "(a) flags token ratio >=MDE"   "$OA" '⚠ est/act token ratio:'
# (b) two versions >=floor, late 8.3% -> 16.7% (Δ8.3pp < 15) and SAME token ratio
PB="$(mkproj)"; { emit 0.22.0 12 1 900000 1000000; emit 0.23.0 12 2 900000 1000000; } > "$PB/.auto-task/outcomes.jsonl"
OB="$(runs "$PB")"
has  "(b) sub-MDE: no regression flagged" "$OB" 'no metric moved beyond the MDE'
hasnt "(b) sub-MDE: not 'insufficient'"   "$OB" 'insufficient data'
# (c) sparse: <floor per version
PC="$(mkproj)"; { emit 0.22.0 3 1 900000 1000000; emit 0.23.0 3 2 900000 1000000; } > "$PC/.auto-task/outcomes.jsonl"
has "(c) sparse -> insufficient data" "$(runs "$PC")" 'insufficient data'
# (d) single version only
PD="$(mkproj)"; emit 0.23.0 12 4 900000 1000000 > "$PD/.auto-task/outcomes.jsonl"
has "(d) single version -> insufficient" "$(runs "$PD")" 'insufficient data'

echo "================ thresholds env-overridable (AC#9) ================"
# same flagging fixture as (a); MDE=99pp + ratio 9x suppresses every flag
O_hi="$(AUTO_TASK_PR_RESOLVE=0 AUTO_TASK_STATS_MDE_PP=99 AUTO_TASK_STATS_RATIO_MDE=9 CLAUDE_PROJECT_DIR="$PA" bash "$STATS" 2>&1)"
has  "MDE=99 suppresses the flag" "$O_hi" 'no metric moved beyond the MDE'
hasnt "MDE=99: no late-defect flag" "$O_hi" '⚠ late-defect rate'
# min-sample override: raise floor to 20 -> the 12/12 fixture becomes insufficient
O_ms="$(AUTO_TASK_PR_RESOLVE=0 AUTO_TASK_STATS_MIN_SAMPLE=20 CLAUDE_PROJECT_DIR="$PA" bash "$STATS" 2>&1)"
has "MIN_SAMPLE=20 -> insufficient" "$O_ms" 'insufficient data'

echo "================ recalibration is suggest-only (AC#8) ================"
# n_tok=24 >= floor -> SUGGEST printed; NOT printed without --recalibrate
O_norec="$(runs "$PA")"
hasnt "no recal section without flag" "$O_norec" 'Recalibration suggestion'
O_rec="$(runs "$PA" --recalibrate)"
has "recal: suggestion header"       "$O_rec" 'Recalibration suggestion'
has "recal: suggests TOKEN constants" "$O_rec" 'Suggested TOKEN constants'
has "recal: names TIER_BASE_TOK"      "$O_rec" 'TIER_BASE_TOK'
has "recal: states suggestion-only"   "$O_rec" 'estimate.sh is unchanged'
# below floor -> refuses to suggest
O_low="$(runs "$PC" --recalibrate)"
has "recal below floor: refuses"      "$O_low" 'Not enough measured runs'
# estimate.sh was NOT edited by --recalibrate (suggest-only): constants intact
expect "estimate.sh heavy token base intact" "$([ "$(grep -c '1800000' "$EST")" -ge 1 ] && echo yes || echo no)" "yes"
has "estimate.sh still has heavy token base" "$(cat "$EST")" '1800000'
has "estimate.sh still has standard min base" "$(cat "$EST")" 'standard'

echo "================ malformed-input robustness (Gate B hardening) ================"
# (GB1) a lone "." RATIO_MDE must NOT blank the report (invalid --argjson guard).
O_dot="$(AUTO_TASK_PR_RESOLVE=0 AUTO_TASK_STATS_RATIO_MDE=. CLAUDE_PROJECT_DIR="$PA" bash "$STATS" 2>&1)"
has  "RATIO_MDE=. still renders quality data" "$O_dot" 'Late-defect rate +[0-9.]+% \['
hasnt "RATIO_MDE=. does NOT blank to n=0"      "$O_dot" 'Late-defect rate +n=0'
# (GB2) one row with a NON-STRING plugin_version must not blank the whole report;
# valid string-versioned rows in the same ledger still count.
PX="$(mkproj)"
{ emit 0.23.0 12 3 900000 1000000; printf '{"at":"2026-05-01T10:00:00Z","branch":"feat/bad","base":"BAD","plugin_version":23,"terminal_state":"done","tier":"standard","gate_b":"passed","followups":0,"defects_late":0,"flaky":false,"tests_added":true,"est_tokens":900000,"act_tokens":1000000,"est_duration_min":40,"act_duration_min":52,"first_pass_ac":0.8,"defects_early":1,"checks_run":1,"checks_failed":0,"pr_url":null}\n'; } > "$PX/.auto-task/outcomes.jsonl"
O_bad="$(AUTO_TASK_PR_RESOLVE=0 CLAUDE_PROJECT_DIR="$PX" bash "$STATS" 2>&1)"
has  "non-string version: report not blanked" "$O_bad" 'Late-defect rate +[0-9.]+% \[[0-9.]+–[0-9.]+\] \(n=13\)'
has  "non-string version: excluded from grouping (single valid version -> insufficient)" "$O_bad" 'insufficient data'

# cleanup
rm -rf "$P1" "$P0" "$PA" "$PB" "$PC" "$PD" "$PX"

echo ""
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
