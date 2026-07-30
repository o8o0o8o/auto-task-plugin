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
{"phase":"done","approved":true,"branch":"feat/widget","base":"BASE1","pr_url":"https://github.com/acme/widgets/pull/42",
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
expect "row.pr_url"            "$(printf '%s' "$ROW" | jq -r '.pr_url')"           "https://github.com/acme/widgets/pull/42"
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
# act_tokens_output is the est-ratio counterpart to est_tokens (both OUTPUT-scale).
# It must be PRESENT-and-null on a legacy/partial state, never absent: the reader
# treats an ABSENT act_tokens_output as "row written before the recalibration, its
# est_tokens is on the old total scale, exclude it from the ratio". A row this
# archiver emits is post-recalibration by construction, so it must always carry
# the key — otherwise every fresh row would be misread as legacy.
expect "row.act_tokens_output default null" "$(printf '%s' "$ROW" | jq -r '.act_tokens_output')" "null"
expect "row.act_tokens_output key present"  "$(printf '%s' "$ROW" | jq -r 'has("act_tokens_output")')" "true"
# est_tokens_scale records WHICH scale est_tokens is on. On a state with no estimate
# at all it is null ("unestimable"), NOT "total" — only a state that actually carries
# the old tokens_total field is legacy, and mislabelling an unmeasured run as
# pre-recalibration would put it in the reader's exclusion count under a false reason.
expect "row.est_tokens_scale null when no estimate" "$(printf '%s' "$ROW" | jq -r '.est_tokens_scale')" "null"
expect "row.est_duration_min null"     "$(printf '%s' "$ROW" | jq -r '.est_duration_min')" "null"
expect "row.act_duration_min = dur"    "$(printf '%s' "$ROW" | jq -r '.act_duration_min')" "27"
expect "row.checks_run default 0"      "$(printf '%s' "$ROW" | jq -r '.checks_run')"    "0"
expect "row.defects_late default 0"    "$(printf '%s' "$ROW" | jq -r '.defects_late')"  "0"
expect "row.flaky default false"       "$(printf '%s' "$ROW" | jq -r '.flaky')"         "false"
# plugin_version: resolved from the manifest (never a STATE field), a non-empty
# string on the row so auto-task-stats can group runs by version. Value depends on
# the resolved manifest, so assert only that it is a present, non-empty string.
expect "row.plugin_version is a string"  "$(printf '%s' "$ROW" | jq -r '.plugin_version | type')" "string"
expect "row.plugin_version non-empty"    "$(printf '%s' "$ROW" | jq -r '.plugin_version | length > 0')" "true"

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
# forward-compat: a legacy STATE without pr_url yields pr_url null (never errors).
expect "empty-base row.pr_url defaults null"         "$(head -1 "$TE/.auto-task/outcomes.jsonl" | jq -r '.pr_url')" "null"
rm -rf "$TE"

echo ""
echo "================ Duration: MEASURED from the run clock ================"
# The duration used to be derived from the first and last `state.history[].at`
# strings, which the model writes without a clock — narrated, not measured. It now
# comes from the hook-stamped .run-clock.json, with the history formula kept ONLY
# as the fallback for a run that has no clock.
#
# Every fixture below deliberately carries a VALID 5-minute history AND non-null
# `actuals.duration_min`, because those are exactly the two values a broken
# implementation would fall back to. jq's `//` treats `null` like absent, so if the
# rejection were expressed as a nullable value it would silently resolve to 7 (from
# actuals) or 5 (from history). Seeing `null` here is what proves the three-state
# verdict is actually branching on the state.
TC="$(mktemp -d)"
( cd "$TC" && { git init -q -b feat/clocked . 2>/dev/null || { git init -q .; git symbolic-ref HEAD refs/heads/feat/clocked; }; } )
CD="$TC/.auto-task/feat/clocked"; mkdir -p "$CD"
cat > "$CD/STATE.json" <<'EOF'
{"phase":"done","approved":true,"branch":"feat/clocked","base":"CLK","description":"d",
 "effort":{"tier":"standard","history":[]},"iteration":{"fix":0,"review":1},
 "history":[{"phase":"execute","at":"2026-03-01T10:00:00Z"},{"phase":"handover","at":"2026-03-01T10:05:00Z"}],
 "actuals":{"duration_min":7,"tokens_total":11,"tokens_breakdown":{"output":5}},
 "gates":{"gate_b":{"passed":true}},"followups":[]}
EOF
# Re-run the archiver from a clean ledger + sentinel and read back one field.
clk(){ # <minutes-wide | "none"> <jq field>
  rm -f "$CD/.outcome-recorded"; : > "$TC/.auto-task/outcomes.jsonl"
  if [ "$1" = "none" ]; then rm -f "$CD/.run-clock.json"
  elif [ "$1" = "corrupt" ]; then printf 'not json\n' > "$CD/.run-clock.json"
  else
    jq -n --argjson m "$1" '{created_at:"2026-03-01T00:00:00Z",
      updated_at:("2026-03-01T00:00:00Z"|fromdateiso8601|.+($m*60)|todateiso8601),base:"CLK",sealed:true}' > "$CD/.run-clock.json"
  fi
  rec "$TC" >/dev/null
  head -1 "$TC/.auto-task/outcomes.jsonl" | jq -r "$2"
}
: > "$TC/.auto-task/outcomes.jsonl"

expect "no clock: duration falls back to history"  "$(clk none .duration_min)"           "5"
expect "no clock: act falls back to actuals"       "$(clk none .act_duration_min)"       "7"
expect "clock 90m: duration is MEASURED"           "$(clk 90 .duration_min)"             "90"
expect "clock 90m: act uses the clock, not actuals" "$(clk 90 .act_duration_min)"        "90"
expect "clock 0m: a real zero is recorded"         "$(clk 0 .duration_min)"              "0"
expect "clock 720m (on the bound): recorded"       "$(clk 720 .duration_min)"            "720"
# The two rejection cases — null, and NOT the 5 / 7 a `//` fallback would produce.
expect "clock 721m: duration rejected to null"     "$(clk 721 .duration_min)"            "null"
expect "clock 721m: act rejected to null (not 7)"  "$(clk 721 .act_duration_min)"        "null"
expect "negative clock: duration null"             "$(clk "-90" .duration_min)"          "null"
expect "negative clock: act null (not 7)"          "$(clk "-90" .act_duration_min)"      "null"
# A rejected row must still be a well-formed row — the key is present-and-null, not
# dropped, so the reader can tell "rejected" from "field predates this build".
expect "rejected row still has the key"            "$(clk 721 'has("duration_min")')"    "true"
expect "rejected row is valid JSON"                "$(clk 721 . >/dev/null 2>&1; echo $?)" "0"
# A corrupt clock is unmeasurable, NOT rejected → the history fallback applies.
expect "corrupt clock: falls back, not rejected"   "$(clk corrupt .duration_min)"        "5"

# STAMP-BEFORE-READ, behaviorally. Every case above uses a SEALED clock, which
# makes rc_stamp a no-op — so none of them prove the archiver stamps at all, and a
# reader that only read would pass them. Here the clock is UNSEALED with
# updated_at == created_at (a zero span) and created_at set 45 minutes in the past.
# Without the self-stamp the row would read 0; with it, updated_at moves to now and
# the row reads ~45. That difference is the whole R1 guarantee (an event's hooks run
# in parallel, so the archiver cannot depend on the Stop stamper winning the race).
ago(){ date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ; }
C45="$(ago 45)"
rm -f "$CD/.outcome-recorded"; : > "$TC/.auto-task/outcomes.jsonl"
jq -n --arg c "$C45" '{created_at:$c,updated_at:$c,base:"CLK",sealed:false}' > "$CD/.run-clock.json"
rec "$TC" >/dev/null
D_STAMPED="$(head -1 "$TC/.auto-task/outcomes.jsonl" | jq -r '.duration_min')"
expect "unsealed clock: archiver stamped before reading (~45, not 0)" \
  "$([ "$D_STAMPED" -ge 44 ] && [ "$D_STAMPED" -le 46 ] && echo yes || echo "no($D_STAMPED)")" "yes"
expect "the self-stamp also sealed the clock"      "$(jq -r '.sealed' "$CD/.run-clock.json")" "true"
expect "the self-stamp preserved created_at"       "$(jq -r '.created_at' "$CD/.run-clock.json")" "$C45"
# The archiver never blocks or leaks on a rejection.
rm -f "$CD/.outcome-recorded"; : > "$TC/.auto-task/outcomes.jsonl"
jq -n '{created_at:"2026-03-01T12:00:00Z",updated_at:"2026-03-01T00:00:00Z",base:"CLK",sealed:true}' > "$CD/.run-clock.json"
expect "rejection: hook still exits 0"             "$(rec "$TC")"                        "0"
expect "rejection: nothing on stdout"              "$(rec_out "$TC" | wc -c | tr -d ' ')" "0"
rm -rf "$TC"

echo "================ Reader: auto-task-stats.sh ================"

T2="$(mktemp -d)"
( cd "$T2" && git init -q && git checkout -q -b main )
mkdir -p "$T2/.auto-task"
# archived ledger: light / standard / heavy. These rows deliberately carry a
# legacy `gate_b_bounced` field the current archiver no longer emits — a
# forward-compat regression guard: the reader must tolerate old-schema rows
# (it reads every field via `// default`) and ignore the removed one.
cat > "$T2/.auto-task/outcomes.jsonl" <<'EOF'
{"at":"2026-02-01T10:00:00Z","branch":"feat/a","base":"AAA","terminal_state":"done","tier":"light","tier_initial":"light","escalations":0,"fix_iterations":0,"review_iterations":1,"gate_b":"tier=light","gate_b_bounced":0,"followups":0,"duration_min":12,"pr_url":"https://github.com/x/y/pull/5"}
{"at":"2026-02-02T10:00:00Z","branch":"feat/b","base":"BBB","terminal_state":"done","tier":"standard","tier_initial":"light","escalations":1,"fix_iterations":2,"review_iterations":2,"gate_b":"passed","gate_b_bounced":1,"followups":3,"duration_min":40,"pr_url":"https://github.com/x/y/pull/7"}
{"at":"2026-02-03T10:00:00Z","branch":"feat/c","base":"CCC","terminal_state":"done","tier":"heavy","tier_initial":"heavy","escalations":0,"fix_iterations":4,"review_iterations":3,"gate_b":"passed","gate_b_bounced":0,"followups":1,"duration_min":95,"pr_url":"https://github.com/x/y/pull/8"}
EOF
# live in-flight (recent history) and stalled (old history)
mkdir -p "$T2/.auto-task/feat/inflight" "$T2/.auto-task/feat/stalled"
cat > "$T2/.auto-task/feat/inflight/STATE.json" <<EOF
{"phase":"execute","approved":true,"branch":"feat/inflight","base":"IFL","history":[{"phase":"execute","result":"ok","at":"$(now_iso)"}]}
EOF
cat > "$T2/.auto-task/feat/stalled/STATE.json" <<EOF
{"phase":"review","approved":true,"branch":"feat/stalled","base":"STL","history":[{"phase":"review","result":"no-progress","summary":"stuck on flaky test","at":"$(days_ago 30)"}]}
EOF

# AUTO_TASK_PR_RESOLVE=0 keeps the reader hermetic: the local PR-opened count is
# still derived from rows, but no gh/network lookup is attempted.
OUT="$(AUTO_TASK_PR_RESOLVE=0 CLAUDE_PROJECT_DIR="$T2" bash "$STATS" 2>/dev/null)"
# (h) all promised sections present and correct.
expect_has "reader: exit-0 output non-empty"        "$OUT" "auto-task run stats"
expect_has "reader: merge-acceptance section"       "$OUT" "Merge acceptance"
expect_has "reader: PR-opened count (local)"        "$OUT" "3 of 3 completed runs opened a PR"
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
OUT2="$(AUTO_TASK_PR_RESOLVE=0 CLAUDE_PROJECT_DIR="$T2" bash "$STATS" 2>/dev/null)"
expect_has "dedup match: still 3 done (ledger wins)" "$OUT2" "3 done"
# same branch, DIFFERENT base → counts separately (branch-reuse not collapsed).
tmpjson="$(jq '.base="BBB2"' "$T2/.auto-task/feat/b/STATE.json")"; printf '%s' "$tmpjson" > "$T2/.auto-task/feat/b/STATE.json"
OUT3="$(AUTO_TASK_PR_RESOLVE=0 CLAUDE_PROJECT_DIR="$T2" bash "$STATS" 2>/dev/null)"
expect_has "dedup base-change: now 4 done (rerun counts)" "$OUT3" "4 done"

# (l) merge-state resolution via a stubbed gh: pull/7 merged, pull/8 closed,
# pull/5 open → of 2 decided PRs, 1 merged = 50% acceptance. Hermetic (no network).
STUB="$T2/bin"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
[ "$1" = "auth" ] && exit 0            # `gh auth status` → authenticated
url="$3"                               # `gh pr view <url> --json state --jq .state`
case "$url" in
  *pull/7) echo MERGED ;;
  *pull/8) echo CLOSED ;;
  *)       echo OPEN ;;
esac
SH
chmod +x "$STUB/gh"
OUTPR="$(AUTO_TASK_PR_RESOLVE=1 PATH="$STUB:$PATH" CLAUDE_PROJECT_DIR="$T2" bash "$STATS" 2>/dev/null)"
expect_has "reader: gh-resolved merged count"        "$OUTPR" "Merged 1"
expect_has "reader: merge-acceptance rate 50%"       "$OUTPR" "Merge-acceptance rate  50%"

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
for k in duration_min est_duration_min est_tokens est_tokens_scale act_duration_min act_tokens act_tokens_output \
         defects_early defects_late flaky tests_added diff_loc first_pass_ac \
         checks_run checks_failed plugin_version; do
  ir="$(grep -c "${k}:" "$REC_SH" 2>/dev/null || echo 0)"
  is="$(grep -c "${k}:" "$STATS_SH" 2>/dev/null || echo 0)"
  if [ "$ir" -ge 1 ] && [ "$is" -ge 1 ]; then
    PASS=$((PASS+1)); printf '  PASS  %-52s (both)\n' "lockstep: $k"
  else
    FAIL=$((FAIL+1)); printf '  FAIL  %-52s rec=%s stats=%s\n' "lockstep: $k" "$ir" "$is"
  fi
done
# Name-parity above is necessary but not sufficient for est_tokens_scale: its entire
# purpose is that BOTH builders classify a row the same way, so a drift in the
# EXPRESSION (e.g. one reading .estimate.tokens_output, the other
# .estimate.tokens_breakdown.output) would keep the names matching while silently
# splitting the classification. Compare the normalized expression text too.
# Extract from `est_tokens_scale:` up to and including the line that closes the
# expression (`end),`), rather than a fixed line window: a hard `grep -A2` silently
# degrades to comparing a PREFIX the moment a 4th elif/else line is added, so a
# divergent line 4 would pass. awk range + an explicit terminator keeps the
# comparison whole however the expression grows.
scale_expr(){ awk '/est_tokens_scale:/,/end\),/' "$1" | tr -d ' \n'; }
expect "lockstep: est_tokens_scale EXPRESSION identical" \
  "$([ "$(scale_expr "$REC_SH")" = "$(scale_expr "$STATS_SH")" ] && echo yes || echo no)" "yes"
expect "lockstep: est_tokens_scale expression is non-empty" \
  "$([ -n "$(scale_expr "$REC_SH")" ] && echo yes || echo no)" "yes"
# The extraction must actually reach the terminator, or the assertion above is
# comparing truncated text and cannot see a drift past the cut.
expect "lockstep: extraction reaches the closing end)," \
  "$(scale_expr "$REC_SH" | grep -c 'end),')" "1"

# The duration selection carries the same "both must classify identically" burden
# as est_tokens_scale, and a sharper one: it is the expression that keeps a
# REJECTED duration from collapsing into the history fallback via jq's `//`. If one
# builder branched on the state and the other did not, an archived row and a
# live-done row for the same run would disagree — one `null`, one a fabricated
# number — and nothing else in this suite compares the two builders' output.
# The top-level `duration_min` is the field this whole change is named after, and the
# expression slice below stops before the object literal — so its ASSIGNMENT could
# drift between the two builders undetected. Compare it directly. The pattern excludes
# a preceding `_` so it cannot match `act_duration_min`.
dur_field(){ grep -oE '(^|[^_a-z])duration_min: \$[a-z]+' "$1" | head -1 | tr -d ' '; }
expect "lockstep: duration_min assignment identical" \
  "$([ "$(dur_field "$REC_SH")" = "$(dur_field "$STATS_SH")" ] && echo yes || echo no)" "yes"
expect "lockstep: duration_min assignment is non-empty" \
  "$([ -n "$(dur_field "$REC_SH")" ] && echo yes || echo no)" "yes"
dur_expr(){ awk '/if \$clock_state == "ok" then/,/end\) as \$adur/' "$1" | tr -d ' \n'; }
expect "lockstep: duration selection EXPRESSION identical" \
  "$([ "$(dur_expr "$REC_SH")" = "$(dur_expr "$STATS_SH")" ] && echo yes || echo no)" "yes"
expect "lockstep: duration selection expression is non-empty" \
  "$([ -n "$(dur_expr "$REC_SH")" ] && echo yes || echo no)" "yes"
# As above: prove the slice reached its terminator, or it is comparing truncated
# text and blind to any drift past the cut.
expect "lockstep: duration extraction reaches \$adur" \
  "$(dur_expr "$REC_SH" | grep -c 'as\$adur')" "1"
# Both must also actually RESOLVE the verdict, not merely contain the jq branch —
# a builder that never sourced the helper would leave clock_state permanently
# absent and silently report the old narrated number.
for f in "$REC_SH" "$STATS_SH"; do
  expect "lockstep: $(basename "$f") resolves the clock verdict" \
    "$([ "$(grep -c 'rc_duration_min' "$f")" -ge 1 ] && echo yes || echo no)" "yes"
done

# pr_url is an identifying field (not a metric) but must be derived by BOTH, or a
# live-done run's PR would be invisible to merge-acceptance until it is archived.
ir="$(grep -c 'pr_url:' "$REC_SH" 2>/dev/null || echo 0)"
is="$(grep -c 'pr_url:' "$STATS_SH" 2>/dev/null || echo 0)"
expect "lockstep: pr_url derived in both" "$([ "$ir" -ge 1 ] && [ "$is" -ge 1 ] && echo yes || echo no)" "yes"

echo ""
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
