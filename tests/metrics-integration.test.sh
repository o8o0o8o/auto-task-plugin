#!/usr/bin/env bash
# Behavioral integration test for the run-metrics DATA PATH.
#
# The auto-task orchestrator PROSE (Phase-1 estimate render, Phase-5 CONTEXT.md
# sections) is inert during a self-modifying run, so it cannot be exercised
# end-to-end here. This test instead proves the executable spine: a STATE.json
# carrying estimate/actuals/quality/checks flows through record-outcome.sh into
# the ledger with the metric fields, and auto-task-stats.sh renders the
# estimate-accuracy + quality-trend lines with correct numbers — including the
# divide-by-zero guard that EXCLUDES a null/0 estimate from the ratio.
#
# git ops run inside this script (one Bash tool call), so enforce-gates does not
# intercept them.
# Usage: tests/metrics-integration.test.sh   Exit 0 = all passed.

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
REC="$HOOKS/record-outcome.sh"; STATS="$HOOKS/auto-task-stats.sh"
for t in git jq; do command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not installed"; exit 0; }; done

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-52s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-52s got=%s want=%s\n' "$1" "$2" "$3"; fi; }
expect_has(){ if printf '%s' "$2" | grep -qF -- "$3"; then PASS=$((PASS+1)); printf '  PASS  %-52s (found)\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-52s (missing: %s)\n' "$1" "$3"; fi; }
# regex variant (tolerant of column spacing in the reshaped stats output)
expect_rx(){ if printf '%s' "$2" | grep -qE -- "$3"; then PASS=$((PASS+1)); printf '  PASS  %-52s (found)\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-52s (missing rx: %s)\n' "$1" "$3"; fi; }

echo "================ metrics data path: record-outcome ================"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
( cd "$T" && git init -q && git checkout -q -b feat/metrics )
SD="$T/.auto-task/feat/metrics"; mkdir -p "$SD"
# Full-metrics done fixture. tokens actual/est = 2.0 ; duration actual/est = 1.2.
cat > "$SD/STATE.json" <<'EOF'
{"phase":"done","approved":true,"branch":"feat/metrics","base":"BASEM",
 "description":"metrics integration fixture",
 "effort":{"tier":"heavy","history":[]},
 "iteration":{"review":1,"fix":1},
 "estimate":{"duration_min":100,"tokens_total":1000000},
 "actuals":{"duration_min":120,"tokens_total":2000000},
 "quality":{"defects":{"early":1,"late":2},"flaky":true,"tests_added":true,
            "diff":{"loc_added":50,"loc_removed":10},"planning":{"first_pass_ac":0.8}},
 "checks":[{"name":"secret-scan","result":"pass"},{"name":"conflict-markers","result":"pass"},
           {"name":"debug-artifacts","result":"warn"},{"name":"large-files","result":"pass"},
           {"name":"diff-size","result":"info"},{"name":"lint","result":"fail"}],
 "history":[{"phase":"execute","result":"ok","at":"2026-03-01T10:00:00Z"},
            {"phase":"handover","result":"done","at":"2026-03-01T12:00:00Z"}],
 "gates":{"gate_b":{"passed":true}},"followups":[]}
EOF
: > "$T/.auto-task/outcomes.jsonl"   # opt in

printf '{"cwd":"%s"}' "$T" | CLAUDE_PROJECT_DIR="$T" bash "$REC"
ROW="$(head -1 "$T/.auto-task/outcomes.jsonl")"
expect "ledger has exactly one row"   "$(wc -l < "$T/.auto-task/outcomes.jsonl" | tr -d ' ')" "1"
expect "row.est_tokens"        "$(printf '%s' "$ROW" | jq -r '.est_tokens')"        "1000000"
expect "row.act_tokens"        "$(printf '%s' "$ROW" | jq -r '.act_tokens')"        "2000000"
expect "row.est_duration_min"  "$(printf '%s' "$ROW" | jq -r '.est_duration_min')"  "100"
expect "row.act_duration_min"  "$(printf '%s' "$ROW" | jq -r '.act_duration_min')"  "120"
expect "row.defects_early"     "$(printf '%s' "$ROW" | jq -r '.defects_early')"      "1"
expect "row.defects_late"      "$(printf '%s' "$ROW" | jq -r '.defects_late')"       "2"
expect "row.flaky"             "$(printf '%s' "$ROW" | jq -r '.flaky')"              "true"
expect "row.tests_added"       "$(printf '%s' "$ROW" | jq -r '.tests_added')"        "true"
expect "row.diff_loc"          "$(printf '%s' "$ROW" | jq -r '.diff_loc')"           "60"
expect "row.first_pass_ac"     "$(printf '%s' "$ROW" | jq -r '.first_pass_ac')"      "0.8"
expect "row.checks_run"        "$(printf '%s' "$ROW" | jq -r '.checks_run')"         "6"
expect "row.checks_failed"     "$(printf '%s' "$ROW" | jq -r '.checks_failed')"      "1"

echo "================ metrics data path: auto-task-stats ================"
OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$STATS" 2>/dev/null)"
# Reshaped output (v0.23.0): test-verified quality is the headline block; the
# estimate/actual ratio lives under "Estimate accuracy (calibration input)"; the
# late-defect/flakiness/tests-added rates moved INTO the quality headline and now
# carry a Wilson CI + sample size (so match value tolerant of the CI + spacing).
expect_has "stats: quality headline"        "$OUT" "Quality (test-verified"
expect_has "stats: estimate accuracy line"  "$OUT" "Estimate accuracy"
expect_has "stats: token ratio 2x"          "$OUT" "median 2x"
expect_has "stats: n=1 measured"            "$OUT" "(n=1)"
expect_rx  "stats: late-defect 100% (quality, CI)" "$OUT" 'Late-defect rate +100% \['
expect_rx  "stats: flakiness 100% (quality, CI)"   "$OUT" 'Flakiness rate +100% \['
expect_rx  "stats: tests-added 100% (quality, CI)" "$OUT" 'Tests-added rate +100% \['
expect_has "stats: completion demoted to liveness" "$OUT" "NOT a quality signal"

echo "================ divide-by-zero guard: null estimate excluded ================"
# Append a second done row whose estimate FAILED (null) — must NOT poison/divide.
cat >> "$T/.auto-task/outcomes.jsonl" <<'EOF'
{"at":"2026-03-02T10:00:00Z","branch":"feat/other","base":"BASEO","terminal_state":"done","tier":"standard","est_tokens":null,"act_tokens":500000,"est_duration_min":null,"act_duration_min":30,"defects_late":0,"flaky":false,"tests_added":false,"gate_b":"passed","followups":0}
EOF
OUT2="$(CLAUDE_PROJECT_DIR="$T" bash "$STATS" 2>/dev/null)"
expect_has "stats still exits cleanly (2 done)"  "$OUT2" "2 done"
expect_has "null-est row excluded: still n=1"    "$OUT2" "(n=1)"
expect_has "ratio unchanged at 2x"               "$OUT2" "median 2x"

echo ""
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
