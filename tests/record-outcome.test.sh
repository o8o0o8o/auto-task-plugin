#!/usr/bin/env bash
# Focused test for the run-outcome telemetry pair:
#   hooks/record-outcome.sh   — the archiver Stop hook
#   hooks/auto-task-stats.sh  — the reader/aggregator
#
# Kept SEPARATE from enforcement-spine.test.sh (that test owns the gate/Stop
# enforcement spine; this one owns telemetry). Uses throwaway git repos with
# fabricated STATE.json — no real commits are needed (the archiver reads `base`
# from STATE.json, not from git; the repo exists only for toplevel + branch
# resolution), which also keeps the enforce-gates PreToolUse hook out of the way.
#
# Usage: tests/record-outcome.test.sh   (requires git + jq, like the hooks)
# Exit 0 = all assertions passed.

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
REC="$HOOKS/record-outcome.sh"
STATS="$HOOKS/auto-task-stats.sh"

for tool in git jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not installed (required by the hooks under test)"; exit 0; }
done

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-56s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-56s got=%s want=%s\n' "$1" "$2" "$3"; fi; }
expect_has(){ if printf '%s' "$2" | grep -qF -- "$3"; then PASS=$((PASS+1)); printf '  PASS  %-56s (found)\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-56s (missing: %s)\n' "$1" "$3"; fi; }

# Portable "N days ago" ISO-8601 (BSD/macOS date, then GNU date).
days_ago(){ date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ; }
now_iso(){ date -u +%Y-%m-%dT%H:%M:%SZ; }

# rec: invoke the archiver with a JSON payload on stdin (so `cat` never blocks),
# CLAUDE_PROJECT_DIR pinned to the throwaway repo. Echoes the hook exit code.
rec(){ printf '{"cwd":"%s"}' "$1" | CLAUDE_PROJECT_DIR="$1" bash "$REC"; echo $?; }
# rec_out: capture the archiver's stdout (must stay empty — it never emits a block).
rec_out(){ printf '{"cwd":"%s"}' "$1" | CLAUDE_PROJECT_DIR="$1" bash "$REC" 2>/dev/null; }
rows(){ [ -f "$1/.auto-task/outcomes.jsonl" ] && wc -l < "$1/.auto-task/outcomes.jsonl" | tr -d ' ' || echo 0; }

echo "================ Archiver: record-outcome.sh ================"

T="$(mktemp -d)"; trap 'rm -rf "$T" "$T2" "$T3"' EXIT
( cd "$T" && git init -q && git checkout -q -b feat/widget )
SD="$T/.auto-task/feat/widget"; mkdir -p "$SD"
T0="$(days_ago 1)"; T0="${T0%T*}T10:00:00Z"     # a fixed start
# done-state fixture: tier escalated light->standard, fix=3 review=2, gate_b passed,
# a gate-b findings history entry, 2 followups, history spanning 27 minutes.
cat > "$SD/STATE.json" <<EOF
{"phase":"done","approved":true,"branch":"feat/widget","base":"BASE1",
 "description":"add a run-outcome telemetry feature to the plugin",
 "effort":{"tier":"standard","history":[{"from":"light","to":"standard","reason":"x","at":"2026-01-01T00:00:00Z"}]},
 "iteration":{"review":2,"fix":3},
 "history":[{"phase":"execute","result":"ok","at":"2026-01-01T10:00:00Z"},
            {"phase":"gate-b","result":"blocker","summary":"found a blocker","at":"2026-01-01T10:10:00Z"},
            {"phase":"handover","result":"done","at":"2026-01-01T10:27:00Z"}],
 "gates":{"gate_b":{"passed":true}},"followups":[{"note":"a"},{"note":"b"}]}
EOF

# (c) opt-OUT first: no ledger file → nothing written, no sentinel.
expect "opt-out: hook exits 0"                       "$(rec "$T")"                  "0"
expect "opt-out: no row written"                     "$(rows "$T")"                 "0"
expect "opt-out: no sentinel"                        "$([ -f "$SD/.outcome-recorded" ] && echo yes || echo no)" "no"

# (a)(e) opt-IN: ledger exists → exactly one row, sentinel created, exit 0.
: > "$T/.auto-task/outcomes.jsonl"
expect "opt-in done: hook exits 0 (never blocks)"    "$(rec "$T")"                  "0"
expect "opt-in done: exactly one row"                "$(rows "$T")"                 "1"
expect "opt-in done: sentinel == base"               "$(cat "$SD/.outcome-recorded" 2>/dev/null)" "BASE1"
expect "opt-in done: no block emitted on stdout"     "$(rec_out "$T" | grep -c block)" "0"

# (f) field correctness on the one row.
ROW="$(head -1 "$T/.auto-task/outcomes.jsonl")"
expect "row.terminal_state"    "$(printf '%s' "$ROW" | jq -r '.terminal_state')"   "done"
expect "row.branch"            "$(printf '%s' "$ROW" | jq -r '.branch')"           "feat/widget"
expect "row.base"              "$(printf '%s' "$ROW" | jq -r '.base')"             "BASE1"
expect "row.tier"              "$(printf '%s' "$ROW" | jq -r '.tier')"             "standard"
expect "row.tier_initial"      "$(printf '%s' "$ROW" | jq -r '.tier_initial')"     "light"
expect "row.escalations"       "$(printf '%s' "$ROW" | jq -r '.escalations')"      "1"
expect "row.fix_iterations"    "$(printf '%s' "$ROW" | jq -r '.fix_iterations')"   "3"
expect "row.review_iterations" "$(printf '%s' "$ROW" | jq -r '.review_iterations')" "2"
expect "row.gate_b"            "$(printf '%s' "$ROW" | jq -r '.gate_b')"           "passed"
expect "row.followups"         "$(printf '%s' "$ROW" | jq -r '.followups')"        "2"
expect "row.duration_min"      "$(printf '%s' "$ROW" | jq -r '.duration_min')"     "27"
# Forward-compat: a legacy STATE without estimate/actuals/quality/checks still
# yields a valid row with the new metric fields defaulted (null / 0 / false).
expect "row.est_tokens default null"   "$(printf '%s' "$ROW" | jq -r '.est_tokens')"    "null"
expect "row.act_tokens default null"   "$(printf '%s' "$ROW" | jq -r '.act_tokens')"    "null"
expect "row.est_duration_min null"     "$(printf '%s' "$ROW" | jq -r '.est_duration_min')" "null"
expect "row.act_duration_min = dur"    "$(printf '%s' "$ROW" | jq -r '.act_duration_min')" "27"
expect "row.checks_run default 0"      "$(printf '%s' "$ROW" | jq -r '.checks_run')"    "0"
expect "row.defects_late default 0"    "$(printf '%s' "$ROW" | jq -r '.defects_late')"  "0"
expect "row.flaky default false"       "$(printf '%s' "$ROW" | jq -r '.flaky')"         "false"

# (b) second run, SAME base → sentinel dedups, still one row.
expect "same-run rerun: hook exits 0"                "$(rec "$T")"                  "0"
expect "same-run rerun: still one row (dedup)"       "$(rows "$T")"                 "1"

# (g) run-scoped sentinel: reuse the branch folder with a NEW base → recorded again.
tmpjson="$(jq '.base="BASE2"' "$SD/STATE.json")"; printf '%s' "$tmpjson" > "$SD/STATE.json"
expect "new-base rerun: hook exits 0"                "$(rec "$T")"                  "0"
expect "new-base rerun: SECOND row recorded"         "$(rows "$T")"                 "2"

# (d) phase != done → no new row.
tmpjson="$(jq '.phase="execute"|.base="BASE3"' "$SD/STATE.json")"; printf '%s' "$tmpjson" > "$SD/STATE.json"
expect "non-done: hook exits 0"                      "$(rec "$T")"                  "0"
expect "non-done: no new row"                        "$(rows "$T")"                 "2"

# (k) empty/absent base must NOT break write-once: a done state with no base
# records once, then presence-dedups (regression: previously appended a
# duplicate row on every turn-end because the base-match guard was always false).
TE="$(mktemp -d)"; ( cd "$TE" && git init -q && git checkout -q -b feat/nobase )
SDE="$TE/.auto-task/feat/nobase"; mkdir -p "$SDE"; : > "$TE/.auto-task/outcomes.jsonl"
cat > "$SDE/STATE.json" <<'EOF'
{"phase":"done","approved":true,"branch":"feat/nobase","description":"legacy state with no base field",
 "effort":{"tier":"light","history":[]},"iteration":{"review":0,"fix":0},
 "history":[{"phase":"handover","result":"done","at":"2026-01-01T10:00:00Z"}],
 "gates":{"gate_b":{"skipped_reason":"tier=light"}},"followups":[]}
EOF
expect "empty-base: first run records"               "$(rec "$TE"; rows "$TE")"     "$(printf '0\n1')"
expect "empty-base: rerun does NOT duplicate"        "$(rec "$TE"; rec "$TE"; rows "$TE")" "$(printf '0\n0\n1')"
rm -rf "$TE"

echo "================ Reader: auto-task-stats.sh ================"

T2="$(mktemp -d)"
( cd "$T2" && git init -q && git checkout -q -b main )
mkdir -p "$T2/.auto-task"
# archived ledger: light / standard / heavy. These rows deliberately carry a
# legacy `gate_b_bounced` field the current archiver no longer emits — a
# forward-compat regression guard: the reader must tolerate old-schema rows
# (it reads every field via `// default`) and ignore the removed one.
cat > "$T2/.auto-task/outcomes.jsonl" <<'EOF'
{"at":"2026-02-01T10:00:00Z","branch":"feat/a","base":"AAA","terminal_state":"done","tier":"light","tier_initial":"light","escalations":0,"fix_iterations":0,"review_iterations":1,"gate_b":"tier=light","gate_b_bounced":0,"followups":0,"duration_min":12}
{"at":"2026-02-02T10:00:00Z","branch":"feat/b","base":"BBB","terminal_state":"done","tier":"standard","tier_initial":"light","escalations":1,"fix_iterations":2,"review_iterations":2,"gate_b":"passed","gate_b_bounced":1,"followups":3,"duration_min":40}
{"at":"2026-02-03T10:00:00Z","branch":"feat/c","base":"CCC","terminal_state":"done","tier":"heavy","tier_initial":"heavy","escalations":0,"fix_iterations":4,"review_iterations":3,"gate_b":"passed","gate_b_bounced":0,"followups":1,"duration_min":95}
EOF
# live in-flight (recent history) and stalled (old history)
mkdir -p "$T2/.auto-task/feat/inflight" "$T2/.auto-task/feat/stalled"
cat > "$T2/.auto-task/feat/inflight/STATE.json" <<EOF
{"phase":"execute","approved":true,"branch":"feat/inflight","base":"IFL","history":[{"phase":"execute","result":"ok","at":"$(now_iso)"}]}
EOF
cat > "$T2/.auto-task/feat/stalled/STATE.json" <<EOF
{"phase":"review","approved":true,"branch":"feat/stalled","base":"STL","history":[{"phase":"review","result":"no-progress","summary":"stuck on flaky test","at":"$(days_ago 30)"}]}
EOF

OUT="$(CLAUDE_PROJECT_DIR="$T2" bash "$STATS" 2>/dev/null)"
# (h) all promised sections present and correct.
expect_has "reader: exit-0 output non-empty"        "$OUT" "auto-task run stats"
expect_has "reader: 3 done"                          "$OUT" "3 done"
expect_has "reader: 1 stalled"                       "$OUT" "1 stalled"
expect_has "reader: 1 in-flight"                     "$OUT" "1 in-flight"
expect_has "reader: completion 75%"                  "$OUT" "75%"
expect_has "reader: per-tier standard row"           "$OUT" "standard"
expect_has "reader: per-tier heavy row"              "$OUT" "heavy"
expect_has "reader: Gate B coverage ran 2/2"         "$OUT" "ran on 2/2"
expect_has "reader: where stalled died lists branch" "$OUT" "feat/stalled"
expect_has "reader: stalled reason surfaced"         "$OUT" "flaky test"
expect_has "reader: follow-up debt line"             "$OUT" "Follow-up debt"

# (i) dedup on branch+base: a live done matching an archived row counts ONCE.
mkdir -p "$T2/.auto-task/feat/b"
cat > "$T2/.auto-task/feat/b/STATE.json" <<'EOF'
{"phase":"done","approved":true,"branch":"feat/b","base":"BBB","effort":{"tier":"standard","history":[]},"iteration":{"fix":0,"review":0},"history":[{"phase":"handover","result":"done","at":"2026-02-02T10:00:00Z"}],"gates":{"gate_b":{"passed":true}},"followups":[]}
EOF
OUT2="$(CLAUDE_PROJECT_DIR="$T2" bash "$STATS" 2>/dev/null)"
expect_has "dedup match: still 3 done (ledger wins)" "$OUT2" "3 done"
# same branch, DIFFERENT base → counts separately (branch-reuse not collapsed).
tmpjson="$(jq '.base="BBB2"' "$T2/.auto-task/feat/b/STATE.json")"; printf '%s' "$tmpjson" > "$T2/.auto-task/feat/b/STATE.json"
OUT3="$(CLAUDE_PROJECT_DIR="$T2" bash "$STATS" 2>/dev/null)"
expect_has "dedup base-change: now 4 done (rerun counts)" "$OUT3" "4 done"

# (j) empty-ledger guard: touched but empty, no live runs → friendly message, no crash.
T3="$(mktemp -d)"
( cd "$T3" && git init -q && git checkout -q -b main )
mkdir -p "$T3/.auto-task"; : > "$T3/.auto-task/outcomes.jsonl"
OUTE="$(CLAUDE_PROJECT_DIR="$T3" bash "$STATS"; echo "EXIT=$?")"
expect_has "empty ledger: friendly no-runs message"  "$OUTE" "No runs recorded yet"
expect_has "empty ledger: exit 0"                    "$OUTE" "EXIT=0"

echo "================ Lockstep: metric fields present in BOTH DERIVE blocks ================"
# record-outcome.sh (archiver) and auto-task-stats.sh (reader) must derive the
# SAME metric fields, or archived rows and live-done rows disagree. Assert every
# metric field name appears in both scripts' derivations.
REC_SH="$HOOKS/record-outcome.sh"; STATS_SH="$HOOKS/auto-task-stats.sh"
for k in est_duration_min est_tokens act_duration_min act_tokens \
         defects_early defects_late flaky tests_added diff_loc first_pass_ac \
         checks_run checks_failed; do
  ir="$(grep -c "${k}:" "$REC_SH" 2>/dev/null || echo 0)"
  is="$(grep -c "${k}:" "$STATS_SH" 2>/dev/null || echo 0)"
  if [ "$ir" -ge 1 ] && [ "$is" -ge 1 ]; then
    PASS=$((PASS+1)); printf '  PASS  %-52s (both)\n' "lockstep: $k"
  else
    FAIL=$((FAIL+1)); printf '  FAIL  %-52s rec=%s stats=%s\n' "lockstep: $k" "$ir" "$is"
  fi
done

echo ""
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
