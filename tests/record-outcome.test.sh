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

echo "================ Worktree isolation: the clone-wide ledger ================"
# WHY THIS BLOCK EXISTS. auto-task isolates EVERY run in its own linked git
# worktree, yet this suite previously had zero worktree coverage — which is exactly
# how the ledger shipped recording nothing at all. The writer retargeted to the
# worktree and demanded a ledger a fresh worktree never has (opt-in gate failed
# closed → no row, no sentinel, ever), while the reader looked at the main tree.
# Everything below fails against that pre-fix code.

# mkwt: a throwaway clone with one linked worktree on its own branch, holding a
# `phase:done` run. Echoes "<main>" and "<worktree>" on SEPARATE LINES. $1 = branch,
# $2 = base value.
#
# Two lines, not one space-separated line, and `use_wt` below reads them without word
# splitting — because the callers feed these paths to `rm -rf`. With a space-separated
# result and an unquoted `set -- $(mkwt …)`, a `TMPDIR` containing a space (a
# user-set `TMPDIR=/Volumes/My Disk/tmp`, a Windows `…/First Last/AppData/…`) splits
# the paths into fragments: the fixtures then test the wrong locations, and the
# cleanup hands a truncated prefix like `/private/tmp` to `rm -rf`. This mirrors the
# reason hooks/lib/clone-scope.sh uses a newline-delimited accumulator instead of a
# space-delimited one.
# Paths are normalised with `pwd -P` to match the resolver, which normalises too:
# on macOS `mktemp -d` hands back a /var/... path while /var is a symlink to
# /private/var, so an un-normalised expectation would fail on a correct resolver.
mkwt(){
  local root main wt
  root="$(cd "$(mktemp -d)" && pwd -P)"; main="$root/main"
  mkdir -p "$main"
  ( cd "$main" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init )
  wt="$root/wt"
  ( cd "$main" && git worktree add -q "$wt" -b "$1" >/dev/null 2>&1 )
  mkdir -p "$wt/.auto-task/$1"
  cat > "$wt/.auto-task/$1/STATE.json" <<EOF
{"phase":"done","approved":true,"branch":"$1","base":"$2","pr_url":null,
 "description":"a worktree-isolated run","effort":{"tier":"standard","history":[]},
 "iteration":{"review":1,"fix":0},
 "history":[{"phase":"execute","result":"ok","at":"2026-01-01T10:00:00Z"},
            {"phase":"handover","result":"done","at":"2026-01-01T10:30:00Z"}],
 "gates":{"gate_b":{"passed":true}},"followups":[]}
EOF
  printf '%s\n%s\n' "$main" "$wt"
}
# use_wt <branch> <base> → sets WT_MAIN / WT_WT with no word splitting.
use_wt(){
  local out
  out="$(mkwt "$1" "$2")"
  WT_MAIN="$(printf '%s\n' "$out" | sed -n 1p)"
  WT_WT="$(printf '%s\n' "$out" | sed -n 2p)"
  wt_track "$(dirname "$WT_MAIN")"
}
# Newline-delimited accumulator (see mkwt's note); one path per line, never split.
WTROOTS=""
wt_track(){ [ -n "${1:-}" ] && WTROOTS="$WTROOTS$1
"; }
cleanup_wt(){
  while IFS= read -r d; do
    # Refuse anything that is not an absolute path with real depth — a belt against a
    # truncated value ever reaching `rm -rf`.
    case "$d" in ''|/|/*/) continue ;; /*/*) ;; *) continue ;; esac
    rm -rf "$d" 2>/dev/null || true
  done <<EOF
$WTROOTS
EOF
}
trap 'rm -rf "$T" "$T2" "$T3"; cleanup_wt' EXIT

# --- AC1: the shared resolver returns the MAIN worktree's ledger from anywhere --
# shellcheck source=../hooks/lib/clone-scope.sh
if [ -f "$HOOKS/lib/clone-scope.sh" ] && . "$HOOKS/lib/clone-scope.sh" 2>/dev/null; then
  use_wt feat/resolve RESOLVE1; WMAIN="$WT_MAIN"; WWT="$WT_WT"
  wt_track "$(dirname "$WMAIN")"
  expect "resolver: ledger from the worktree == main's" \
    "$(cs_ledger_path "$WWT")" "$WMAIN/.auto-task/outcomes.jsonl"
  expect "resolver: ledger from main == the same path" \
    "$(cs_ledger_path "$WMAIN")" "$WMAIN/.auto-task/outcomes.jsonl"
  expect "resolver: main worktree resolved from the worktree" \
    "$(cs_main_worktree "$WWT")" "$WMAIN"
  # Roots must be de-duplicated — callers tally runs under them, so a repeat would
  # double-count. Two worktrees here, but only ones with an existing .auto-task/.
  mkdir -p "$WMAIN/.auto-task"
  expect "resolver: roots de-duplicated" \
    "$(cs_autotask_roots "$WWT" | sort | uniq -d | wc -l | tr -d ' ')" "0"
  expect "resolver: roots cover both trees" \
    "$(cs_autotask_roots "$WWT" | wc -l | tr -d ' ')" "2"
  # Fail-open: outside a repo there is no honest answer, so the answer is EMPTY —
  # never a guess. Callers detect this and keep their prior behavior.
  expect "resolver: empty outside a repo"  "$(cs_ledger_path /tmp)" ""
  # A BARE repo has no working tree, so `.auto-task/` under it is meaningless. Note a
  # bare `foo.git` IS a real directory, so an `[ -d ]` test alone wrongly accepts it —
  # this asserts the dedicated bare check, which is the documented mitigation.
  BARE="$(cd "$(mktemp -d)" && pwd -P)"; wt_track "$BARE"
  ( cd "$BARE" && git init -q --bare bare.git )
  expect "resolver: bare repo yields empty (no working tree)" \
    "$(cs_main_worktree "$BARE/bare.git")" ""
  expect "resolver: bare repo yields no ledger path" \
    "$(cs_ledger_path "$BARE/bare.git")" ""

  # --- `--separate-git-dir`: the git dir is NOT a working tree ------------------
  # `git worktree list --porcelain`'s FIRST entry here is the GIT DIR, not the
  # working tree (measured on git 2.44). Taking it positionally resolved the ledger
  # to `<git-dir>/.auto-task/outcomes.jsonl`, so the opt-in gate tested a path inside
  # the git dir and silently recorded nothing — a REGRESSION against the pre-change
  # behavior, which recorded fine here. The resolver must return the WORKING tree.
  SGD="$(cd "$(mktemp -d)" && pwd -P)"; wt_track "$SGD"
  ( cd "$SGD" && git init -q --separate-git-dir="$SGD/repo.git" work \
    && cd work && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  expect "separate-git-dir: resolver returns the WORKING tree" \
    "$(cs_main_worktree "$SGD/work")" "$SGD/work"
  expect "separate-git-dir: ledger is under the working tree" \
    "$(cs_ledger_path "$SGD/work")" "$SGD/work/.auto-task/outcomes.jsonl"
  expect "separate-git-dir: git dir is never named as a worktree" \
    "$(cs_worktree_paths "$SGD/work" | grep -c 'repo\.git')" "0"

  # --- bare clone + linked worktrees: no main working tree exists ---------------
  # First entry is `bare.git`, a real directory that an `[ -d ]` test accepts. There
  # is genuinely no main working tree, so the honest answer is empty (caller falls
  # back) — and the bare git dir must not be offered as a scannable root either.
  BC="$(cd "$(mktemp -d)" && pwd -P)"; wt_track "$BC"
  ( cd "$BC" && git init -q --bare bc.git && cd bc.git \
    && git worktree add -q "$BC/wk" -b fb ) >/dev/null 2>&1
  expect "bare+worktrees: resolver empty from the worktree" \
    "$(cs_main_worktree "$BC/wk")" ""
  expect "bare+worktrees: bare git dir not listed as a worktree" \
    "$(cs_worktree_paths "$BC/wk" | grep -c 'bc\.git')" "0"
  expect "bare+worktrees: the real worktree IS listed" \
    "$(cs_worktree_paths "$BC/wk" | grep -c "$BC/wk")" "1"

  # --- the single-tree regression, end to end through the WRITER ----------------
  # The resolver assertions above are necessary but not sufficient: what actually
  # regressed was a recorded row. Assert the row, not just the path.
  mkdir -p "$SGD/work/.auto-task/feat/sgd"
  cat > "$SGD/work/.auto-task/feat/sgd/STATE.json" <<'EOF'
{"phase":"done","approved":true,"branch":"feat/sgd","base":"SGD1","pr_url":null,
 "description":"separate-git-dir single tree","effort":{"tier":"light","history":[]},
 "iteration":{"review":0,"fix":0},
 "history":[{"phase":"handover","result":"done","at":"2026-01-01T10:30:00Z"}],
 "gates":{"gate_b":{"skipped_reason":"tier=light"}},"followups":[]}
EOF
  ( cd "$SGD/work" && git checkout -q -b feat/sgd ) >/dev/null 2>&1
  : > "$SGD/work/.auto-task/outcomes.jsonl"
  expect "separate-git-dir: writer records the row (was a regression)" \
    "$(printf '{"cwd":"%s"}' "$SGD/work" | CLAUDE_PROJECT_DIR="$SGD/work" bash "$REC" >/dev/null; rows "$SGD/work")" "1"
  expect "separate-git-dir: sentinel stamped" \
    "$(cat "$SGD/work/.auto-task/feat/sgd/.outcome-recorded" 2>/dev/null)" "SGD1"

  # --- The main tree must be PRESENT in the roots, not merely un-corrupted ------
  # Rejecting the git-dir entry is only half the job. Once a LINKED worktree exists
  # the entry list is non-empty, so any fallback gated on "output entirely empty"
  # never contributes the main tree — it silently vanishes from the scan roots and
  # the reader stops counting the runs living there. The single-tree assertions above
  # cannot see this, because with no linked worktree the fallback did fire. So: add a
  # linked worktree and assert CONTAINMENT.
  ( cd "$SGD/work" && git commit -q --allow-empty -m base && git worktree add -q "$SGD/lw" -b sgdlw ) >/dev/null 2>&1
  expect "separate-git-dir + linked wt: main tree still in the roots" \
    "$(cs_worktree_paths "$SGD/work" | grep -cxF "$SGD/work")" "1"
  expect "separate-git-dir + linked wt: linked wt also present" \
    "$(cs_worktree_paths "$SGD/work" | grep -cxF "$SGD/lw")" "1"
  expect "separate-git-dir + linked wt: git dir still excluded" \
    "$(cs_worktree_paths "$SGD/work" | grep -c 'repo\.git')" "0"
  # KNOWN, DELIBERATE LIMITATION — pinned so it reads as decided, not overlooked.
  # From a LINKED worktree of a `--separate-git-dir` repo the main working tree is
  # genuinely undiscoverable: `worktree list` names only the git dir, and (measured)
  # `core.worktree` is NOT set for this layout, unlike a submodule's. So the resolver
  # returns empty and the caller keeps its own root — which is exactly the pre-change
  # behavior for this layout, i.e. parity, not a regression. Asserting the honest
  # outcome here stops a future change from "fixing" it with a guess.
  expect "separate-git-dir linked wt: main tree honestly unresolvable" \
    "$(cs_main_worktree "$SGD/lw")" ""
  # And end-to-end: the reader must still see the main tree's done run.
  OUTSG="$(cd "$SGD/work" && CLAUDE_PROJECT_DIR="$SGD/work" bash "$STATS" 2>&1)"
  expect_has "separate-git-dir + linked wt: reader counts the main-tree run" "$OUTSG" "1 done"

  # --- Same shape for a git SUBMODULE, whose .git is also a gitdir: file --------
  # `worktree list` names `super/.git/modules/sub` rather than the submodule checkout,
  # so a submodule with an auto-task run worktree hits the identical path.
  SUB="$(cd "$(mktemp -d)" && pwd -P)"; wt_track "$SUB"
  ( cd "$SUB" && git init -q inner && cd inner && git config user.email t@t \
    && git config user.name t && git commit -q --allow-empty -m i ) >/dev/null 2>&1
  ( cd "$SUB" && git init -q super && cd super && git config user.email t@t \
    && git config user.name t && git commit -q --allow-empty -m i \
    && git -c protocol.file.allow=always submodule add -q "$SUB/inner" sub \
    && git commit -q -m addsub ) >/dev/null 2>&1
  if [ -f "$SUB/super/sub/.git" ]; then
    expect "submodule: resolver returns the submodule working tree" \
      "$(cs_main_worktree "$SUB/super/sub")" "$SUB/super/sub"
    ( cd "$SUB/super/sub" && git worktree add -q "$SUB/sublw" -b sublw ) >/dev/null 2>&1
    expect "submodule + linked wt: main tree still in the roots" \
      "$(cs_worktree_paths "$SUB/super/sub" | grep -cxF "$SUB/super/sub")" "1"
    expect "submodule + linked wt: git dir excluded from the roots" \
      "$(cs_worktree_paths "$SUB/super/sub" | grep -c 'modules/sub')" "0"
    # A submodule's config DOES carry a core.worktree back-pointer, so unlike the
    # --separate-git-dir case the main tree is reachable from a linked worktree too.
    expect "submodule linked wt: main tree found via core.worktree" \
      "$(cs_main_worktree "$SUB/sublw")" "$SUB/super/sub"
    expect "submodule linked wt: main tree present in the roots" \
      "$(cs_worktree_paths "$SUB/sublw" | grep -cxF "$SUB/super/sub")" "1"
  else
    PASS=$((PASS+1)); printf '  PASS  %-56s (skipped: submodule not created)\n' "submodule: layout unavailable"
  fi
else
  FAIL=$((FAIL+1)); printf '  FAIL  %-56s (cannot source clone-scope.sh)\n' "resolver: lib present"
fi

# --- AC7: opt-out still costs nothing, in a worktree too -----------------------
use_wt feat/optout OPTOUT1; WMAIN="$WT_MAIN"; WWT="$WT_WT"
WSD="$WWT/.auto-task/feat/optout"
expect "wt opt-out: hook exits 0" \
  "$(printf '{"cwd":"%s"}' "$WWT" | CLAUDE_PROJECT_DIR="$WMAIN" bash "$REC"; echo $?)" "0"
expect "wt opt-out: no row at main"      "$(rows "$WMAIN")" "0"
expect "wt opt-out: no row in worktree"  "$(rows "$WWT")"   "0"
expect "wt opt-out: no sentinel"         "$([ -f "$WSD/.outcome-recorded" ] && echo yes || echo no)" "no"

# --- AC2: opt in at MAIN, run lives in the WORKTREE → row lands at MAIN --------
# The headline regression. Pre-fix this wrote 0 rows and no sentinel.
mkdir -p "$WMAIN/.auto-task"; : > "$WMAIN/.auto-task/outcomes.jsonl"
expect "wt opt-in: hook exits 0" \
  "$(printf '{"cwd":"%s"}' "$WWT" | CLAUDE_PROJECT_DIR="$WMAIN" bash "$REC"; echo $?)" "0"
expect "wt opt-in: exactly one row in MAIN's ledger" "$(rows "$WMAIN")" "1"
expect "wt opt-in: no stray worktree ledger created" "$(rows "$WWT")"   "0"
expect "wt opt-in: sentinel written in the WORKTREE" \
  "$(cat "$WSD/.outcome-recorded" 2>/dev/null)" "OPTOUT1"
expect "wt opt-in: row carries the worktree run's branch" \
  "$(head -1 "$WMAIN/.auto-task/outcomes.jsonl" | jq -r '.branch')" "feat/optout"
# AC10: still a silent, non-blocking Stop hook on the new path.
expect "wt opt-in: nothing on stdout" \
  "$(printf '{"cwd":"%s"}' "$WWT" | CLAUDE_PROJECT_DIR="$WMAIN" bash "$REC" 2>/dev/null | wc -c | tr -d ' ')" "0"
# Write-once still holds across the new resolution.
expect "wt opt-in: second call adds no duplicate" \
  "$(printf '{"cwd":"%s"}' "$WWT" | CLAUDE_PROJECT_DIR="$WMAIN" bash "$REC" >/dev/null; rows "$WMAIN")" "1"

# --- AC3: the reader finds the clone-wide ledger from inside a worktree --------
OUTW="$(cd "$WWT" && CLAUDE_PROJECT_DIR="$WWT" bash "$STATS" 2>&1; echo "EXIT=$?")"
expect_has "wt reader: exit 0"                        "$OUTW" "EXIT=0"
expect_has "wt reader: counts the archived run"       "$OUTW" "1 runs on record"
if printf '%s' "$OUTW" | grep -q "telemetry is not opted in"; then
  FAIL=$((FAIL+1)); printf '  FAIL  %-56s (reader still blind to the clone ledger)\n' "wt reader: sees the opt-in"
else
  PASS=$((PASS+1)); printf '  PASS  %-56s (found)\n' "wt reader: sees the opt-in"
fi

# --- AC4: from MAIN, a done run living only in a worktree is counted, once -----
use_wt feat/livewt LIVEWT1; LMAIN="$WT_MAIN"; LWT="$WT_WT"
# MAIN has NO per-branch folder at all — the real shape of an auto-task clone.
OUTL="$(cd "$LMAIN" && CLAUDE_PROJECT_DIR="$LMAIN" bash "$STATS" 2>&1; echo "EXIT=$?")"
expect_has "main reader: exit 0"                          "$OUTL" "EXIT=0"
expect_has "main reader: counts the worktree's done run"  "$OUTL" "1 runs on record — 1 done"
# Same run reachable from BOTH roots must still count once (branch+base dedup).
mkdir -p "$LMAIN/.auto-task/feat/livewt"
cp "$LWT/.auto-task/feat/livewt/STATE.json" "$LMAIN/.auto-task/feat/livewt/STATE.json"
OUTD="$(cd "$LMAIN" && CLAUDE_PROJECT_DIR="$LMAIN" bash "$STATS" 2>&1)"
expect_has "main reader: no double-count across roots"   "$OUTD" "1 runs on record — 1 done"

# --- AC13: a live NON-TERMINAL run reachable from two roots counts once --------
# These tallies had no dedup at all before, because one root guaranteed one sighting.
use_wt feat/inflight INFL1; IMAIN="$WT_MAIN"; IWT="$WT_WT"
NOWI="$(now_iso)"
for d in "$IWT/.auto-task/feat/inflight" "$IMAIN/.auto-task/feat/inflight"; do
  mkdir -p "$d"
  cat > "$d/STATE.json" <<EOF
{"phase":"review","approved":true,"branch":"feat/inflight","base":"INFL1",
 "effort":{"tier":"standard","history":[]},"iteration":{"review":1,"fix":0},
 "history":[{"phase":"review","result":"ok","at":"$NOWI"}],
 "gates":{},"followups":[]}
EOF
done
OUTI="$(cd "$IMAIN" && CLAUDE_PROJECT_DIR="$IMAIN" bash "$STATS" 2>&1)"
expect_has "live dedup: in-flight counted exactly once"  "$OUTI" "1 runs on record — 0 done, 0 stalled, 1 in-flight"

# The non-terminal dedup must use its OWN set, not the done rows' set. Sharing one
# would let a non-terminal sighting claim the key first and SUPPRESS a done run found
# later under another root — making the report depend on `find` order.
#
# ORDER MATTERS IN THE FIXTURE, and getting it backwards makes this test vacuous. The
# roots are scanned MAIN FIRST, so putting the `done` copy at main lets it claim the
# key first and no suppression is possible whatever set is used — verified by
# mutation: with `done`-at-main, reverting to the shared `$seen` left the suite green.
# So the non-terminal copy goes at MAIN and the `done` copy in the WORKTREE, which is
# also the shape a real auto-task clone has (runs live in worktrees). The done run must
# still be counted.
mkdir -p "$IMAIN/.auto-task/feat/mixed" "$IWT/.auto-task/feat/mixed"
cat > "$IMAIN/.auto-task/feat/mixed/STATE.json" <<EOF
{"phase":"review","approved":true,"branch":"feat/mixed","base":"MIX1",
 "effort":{"tier":"light","history":[]},"iteration":{"review":1,"fix":0},
 "history":[{"phase":"review","result":"ok","at":"$NOWI"}],
 "gates":{},"followups":[]}
EOF
cat > "$IWT/.auto-task/feat/mixed/STATE.json" <<EOF
{"phase":"done","approved":true,"branch":"feat/mixed","base":"MIX1","pr_url":null,
 "description":"done in the worktree","effort":{"tier":"light","history":[]},
 "iteration":{"review":0,"fix":0},
 "history":[{"phase":"handover","result":"done","at":"2026-01-01T10:30:00Z"}],
 "gates":{"gate_b":{"skipped_reason":"tier=light"}},"followups":[]}
EOF
OUTM="$(cd "$IMAIN" && CLAUDE_PROJECT_DIR="$IMAIN" bash "$STATS" 2>&1)"
expect_has "separate sets: done-in-worktree is not suppressed by main's non-terminal" \
  "$OUTM" "1 done"
# Pin the whole headline, so a regression that merely relabels the run is caught too.
# The `1 done` is what discriminates: with a shared set, main's non-terminal sighting
# of MIX1 claims the key first and the worktree's done copy is skipped -> `0 done`.
# The `2 in-flight` is the PARKED cross-population behavior (feat/mixed counted once
# as done and once as in-flight, plus feat/inflight) — base parity, deliberately not
# changed by this run, so it is pinned here as expected rather than treated as a bug.
expect_has "separate sets: full tally is correct"  "$OUTM" "3 runs on record — 1 done, 0 stalled, 2 in-flight"

# --- AC12: two worktrees completing concurrently both land intact rows --------
CROOT="$(mktemp -d)"; wt_track "$CROOT"
CMAIN="$CROOT/main"; mkdir -p "$CMAIN"
( cd "$CMAIN" && git init -q && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init )
for i in 1 2; do
  ( cd "$CMAIN" && git worktree add -q "$CROOT/wt$i" -b "feat/conc$i" >/dev/null 2>&1 )
  mkdir -p "$CROOT/wt$i/.auto-task/feat/conc$i"
  cat > "$CROOT/wt$i/.auto-task/feat/conc$i/STATE.json" <<EOF
{"phase":"done","approved":true,"branch":"feat/conc$i","base":"CONC$i","pr_url":null,
 "description":"concurrent completion $i","effort":{"tier":"standard","history":[]},
 "iteration":{"review":1,"fix":0},
 "history":[{"phase":"handover","result":"done","at":"2026-01-01T10:30:00Z"}],
 "gates":{"gate_b":{"passed":true}},"followups":[]}
EOF
done
mkdir -p "$CMAIN/.auto-task"; : > "$CMAIN/.auto-task/outcomes.jsonl"
for i in 1 2; do
  printf '{"cwd":"%s"}' "$CROOT/wt$i" | CLAUDE_PROJECT_DIR="$CMAIN" bash "$REC" >/dev/null 2>&1 &
done
wait
expect "concurrent: exactly two rows" "$(rows "$CMAIN")" "2"
CBAD=0
while IFS= read -r cl || [ -n "$cl" ]; do
  [ -n "$cl" ] || continue
  printf '%s' "$cl" | jq empty 2>/dev/null || CBAD=$((CBAD+1))
done < "$CMAIN/.auto-task/outcomes.jsonl"
expect "concurrent: every row is valid JSON (none torn)" "$CBAD" "0"
expect "concurrent: both branches recorded" \
  "$(jq -r '.branch' < "$CMAIN/.auto-task/outcomes.jsonl" | sort | tr '\n' ' ')" "feat/conc1 feat/conc2 "
expect "concurrent: no lock dir left behind" \
  "$([ -d "$CMAIN/.auto-task/outcomes.jsonl.lock" ] && echo yes || echo no)" "no"

# --- The mutex must be BOUNDED even when a stale lock cannot be removed --------
# This is the assertion the concurrency block was missing: "no lock dir left behind"
# passes identically whether the mutex ran or never existed, so nothing previously
# exercised the lock-contention path. An earlier revision `continue`d after a failed
# `rmdir` without advancing the counter or sleeping and spun forever at full CPU —
# in a Stop hook with no timeout that hangs EVERY turn-end, permanently. A stale
# lock dir containing a stray file makes `rmdir` fail, which is the trigger.
# Bounded via a perl alarm: macOS ships no `timeout`/`gtimeout`.
run_bounded(){ # run_bounded <seconds> <cmd...> → echoes the exit code (142 = timed out)
  local secs="$1"; shift
  perl -e 'my $s=shift; $SIG{ALRM}=sub{ exit 142 }; alarm $s; exec @ARGV or exit 127;' \
    "$secs" "$@" >/dev/null 2>&1
  echo $?
}
use_wt feat/stalelock STALE1; SMAIN="$WT_MAIN"; SWT="$WT_WT"
SSD="$SWT/.auto-task/feat/stalelock"
mkdir -p "$SMAIN/.auto-task"; : > "$SMAIN/.auto-task/outcomes.jsonl"
SLOCK="$SMAIN/.auto-task/outcomes.jsonl.lock"
mkdir -p "$SLOCK"
touch -t 202001010000 "$SLOCK" 2>/dev/null || true   # stale…
# …and genuinely UN-REMOVABLE: a read-only parent makes both the reclaim and a fresh
# `mkdir` fail, so the loop must exhaust its attempts and fall through. (A stray file
# inside the lock is no longer sufficient — the reclaim uses `rm -rf`, since a
# legitimately-held lock now contains its owner's token file.) Appending to the
# already-existing ledger still works, because that needs write on the FILE, not on
# the directory — which is what makes this a clean test of the lock path alone.
chmod 500 "$SMAIN/.auto-task"
SEC="$(printf '{"cwd":"%s"}' "$SWT" > "$SWT/.payload"; \
  run_bounded 12 bash -c "cat '$SWT/.payload' | CLAUDE_PROJECT_DIR='$SMAIN' bash '$REC'")"
expect "stale lock: writer returns (does NOT hang)" "$SEC" "0"
# Fail-open: unable to lock is not a reason to skip the row.
expect "stale lock: row still recorded (fail-open)"  "$(rows "$SMAIN")" "1"
expect "stale lock: sentinel still stamped"          "$(cat "$SSD/.outcome-recorded" 2>/dev/null)" "STALE1"
chmod 700 "$SMAIN/.auto-task"
rm -rf "$SLOCK"

# --- Lock OWNERSHIP: never remove a lock we do not own ------------------------
# Identifying "my lock" by path alone breaks once stale-reclaim exists: if our
# critical section outlives the staleness window another writer reclaims our live
# lock, and our own release would then delete THEIRS, admitting a third writer while
# they still believe they hold the mutex. The fix is an ownership token, so these
# assertions pin the invariant "a lock bearing someone else's id is left alone".
# (The interleaved three-process race itself is not reachable through this hook's
# only entry point — a single turn-end invocation — so what is testable is the
# ownership rule the fix rests on, plus the no-orphan guarantees around it.)
use_wt feat/lockown OWN1; KMAIN="$WT_MAIN"; KWT="$WT_WT"
mkdir -p "$KMAIN/.auto-task"; : > "$KMAIN/.auto-task/outcomes.jsonl"
KLOCK="$KMAIN/.auto-task/outcomes.jsonl.lock"
# A FRESH lock owned by someone else: we must fail-open (still record) and must NOT
# touch their lock or their token.
mkdir -p "$KLOCK"; printf 'someone-else-99999' > "$KLOCK/owner"
expect "foreign fresh lock: hook exits 0" \
  "$(printf '{"cwd":"%s"}' "$KWT" | CLAUDE_PROJECT_DIR="$KMAIN" bash "$REC"; echo $?)" "0"
expect "foreign fresh lock: row still recorded (fail-open)" "$(rows "$KMAIN")" "1"
expect "foreign fresh lock: their lock dir survives" \
  "$([ -d "$KLOCK" ] && echo yes || echo no)" "yes"
expect "foreign fresh lock: their token is untouched" \
  "$(cat "$KLOCK/owner" 2>/dev/null)" "someone-else-99999"
# Now make that same foreign lock STALE: it must be reclaimed AND fully released,
# leaving neither an orphan dir nor a leftover token.
touch -t 202001010000 "$KLOCK" 2>/dev/null || true
rm -f "$KMAIN/.auto-task/outcomes.jsonl"; : > "$KMAIN/.auto-task/outcomes.jsonl"
rm -f "$KWT/.auto-task/feat/lockown/.outcome-recorded"
expect "foreign stale lock: reclaimed and row recorded" \
  "$(printf '{"cwd":"%s"}' "$KWT" | CLAUDE_PROJECT_DIR="$KMAIN" bash "$REC" >/dev/null; rows "$KMAIN")" "1"
expect "foreign stale lock: no orphan lock dir left" \
  "$([ -e "$KLOCK" ] && echo yes || echo no)" "no"

# --- The ownership PROTOCOL itself, driven directly ----------------------------
# The assertions above are necessary but NOT sufficient, and it is worth being exact
# about why: a *fresh* foreign lock is never acquired, so `_ro_release_lock` is never
# even called — those assertions are satisfied by `mkdir` failing, not by the token
# check. Verified by mutation: deleting the token comparison, or restoring the
# `|| true` that let a lock be claimed without being marked, left the suite fully
# green. The release-with-a-foreign-token transition is unreachable through the
# hook's only entry point (one turn-end invocation), so drive the protocol directly:
# extract the three functions VERBATIM from the hook and exercise each transition.
# Extracting rather than reimplementing is what keeps this a test of the shipped
# code instead of a copy that can silently diverge from it.
PROTO="$(mktemp -d)"; wt_track "$PROTO"
awk '/^lock="\$ledger\.lock"$/{f=1} f{print} /^_ro_release_lock\(\) \{/{g=1} g&&/^\}$/{exit}' \
  "$REC" > "$PROTO/proto.sh"
expect "protocol: extracted from the shipped hook (non-empty)" \
  "$([ -s "$PROTO/proto.sh" ] && echo yes || echo no)" "yes"
expect "protocol: extraction captured the token compare" \
  "$(grep -c '_ro_id' "$PROTO/proto.sh" | awk '$1>=3{print "yes"} $1<3{print "no"}')" "yes"
(
  ledger="$PROTO/outcomes.jsonl"; : > "$ledger"; base="PROTOBASE"
  # shellcheck disable=SC1090
  . "$PROTO/proto.sh"
  r=""
  _ro_take_lock && r="acquired" || r="refused"
  printf 'A:%s\n' "$r"
  printf 'B:%s\n' "$([ "$(cat "$lock_token" 2>/dev/null)" = "$_ro_id" ] && echo token-ours || echo token-wrong)"
  _ro_take_lock && printf 'C:%s\n' "reacquired-BUG" || printf 'C:%s\n' "refused-while-held"
  _ro_release_lock
  printf 'D:%s\n' "$([ -e "$lock" ] && echo still-there-BUG || echo released)"
  # The transition the hook cannot reach: we hold nothing, a FOREIGN token sits there.
  mkdir -p "$lock"; printf 'someone-else' > "$lock_token"
  _ro_release_lock
  printf 'E:%s\n' "$([ -d "$lock" ] && echo foreign-preserved || echo foreign-DELETED-BUG)"
  printf 'F:%s\n' "$(cat "$lock_token" 2>/dev/null)"
  rm -rf "$lock"
  # Acquisition must FAIL when the lock is creatable but CANNOT BE MARKED (round-2
  # fix). Getting this scenario right is the whole test: pre-creating `owner` as a
  # directory does NOT work, because then `mkdir "$lock"` fails first and the token
  # path is never reached — the assertion would pass for the wrong reason and stay
  # green under the mutation it exists to catch (observed). `umask 0577` is the lever:
  # `mkdir` succeeds with mode d-w------- (no execute), so creating a file inside is
  # denied while the directory itself is created fine.
  ( umask 0577
    if _ro_take_lock; then printf 'G:%s\n' "claimed-unmarkable-BUG"
    else printf 'G:%s\n' "refused-unmarkable"; fi )
  # …and the refused attempt must leave nothing behind.
  printf 'H:%s\n' "$([ -e "$lock" ] && echo orphan-left-BUG || echo cleaned-up)"
  rm -rf "$lock" 2>/dev/null || true
) > "$PROTO/out.txt" 2>&1
pget(){ grep "^$1:" "$PROTO/out.txt" 2>/dev/null | head -1 | cut -d: -f2-; }
expect "protocol: acquire on a clean path"              "$(pget A)" "acquired"
expect "protocol: token written is ours"                "$(pget B)" "token-ours"
expect "protocol: re-acquire while held is refused"     "$(pget C)" "refused-while-held"
expect "protocol: owner releases its own lock"          "$(pget D)" "released"
expect "protocol: a FOREIGN-token lock is never removed" "$(pget E)" "foreign-preserved"
expect "protocol: the foreign token is left untouched"  "$(pget F)" "someone-else"
expect "protocol: unmarkable lock is not claimed"        "$(pget G)" "refused-unmarkable"
expect "protocol: refused attempt leaves no orphan"      "$(pget H)" "cleaned-up"

# --- Staleness must be measurable on GNU as well as BSD ------------------------
# `stat` order is load-bearing: on GNU/Linux `stat -f %m` selects *filesystem* mode
# where %m is not a valid directive yet the statfs SUCCEEDS printing garbage, so a
# BSD-first order never falls through on Linux and staleness silently becomes
# unmeasurable — turning the orphaned-lock self-healing into dead code on every Linux
# host, invisibly to macOS reviewers. hooks/auto-task-resume-list.sh already
# documents this. Assert the GNU-first order in the shipped source.
expect "stat order: GNU-first (-c %Y before -f %m)" \
  "$(grep -c 'stat -c %Y "\$1" 2>/dev/null || stat -f %m' "$REC")" "1"
expect "stat order: no BSD-first occurrence remains" \
  "$(grep -c 'stat -f %m "\$1" 2>/dev/null || stat -c %Y' "$REC")" "0"

# --- The mutex attempt count must ADAPT to the sleep granularity ------------------
# Pinned TEXTUALLY, for the same reason the stat order above is: the integer-only-sleep
# branch is unreachable on a platform whose `sleep` accepts fractions (macOS does), so a
# behavioural assertion here would pass on any implementation. This is the direct
# descendant of the round-1 defect where a documented ~1.5s bound was really 15s — with a
# flat count, a shell whose `sleep` floors to whole seconds turns the ~2s contended ceiling
# into ~15s of turn-end delay in a Stop hook.
expect "mutex bound: attempt count adapts to sleep granularity" \
  "$(grep -c '_ro_frac_sleep" -eq 1 \]; then _ro_max=15; else _ro_max=2' "$REC")" "1"
expect "mutex bound: the granularity is probed exactly once" \
  "$(grep -c '^sleep 0.1 2>/dev/null && _ro_frac_sleep=1' "$REC")" "1"
expect "mutex bound: no flat attempt count remains" \
  "$(grep -cE '^_ro_max=(15|[0-9]+)$' "$REC")" "0"
# And prove staleness is actually measurable HERE, whichever platform this is — the
# order assertions above are textual, this one is behavioural. Kept in a function
# because a `case`/`esac` inlined into an `expect` argument breaks the shell parse.
mtime_is_measurable(){
  local probe a
  probe="$(mktemp -d)"
  touch -t 202001010000 "$probe" 2>/dev/null || true
  a="$(stat -c %Y "$probe" 2>/dev/null || stat -f %m "$probe" 2>/dev/null || true)"
  rmdir "$probe" 2>/dev/null || true
  case "$a" in ''|*[!0-9]*) echo unmeasurable ;; *) echo measurable ;; esac
}
expect "staleness: mtime IS measurable on this platform" "$(mtime_is_measurable)" "measurable"

# --- The sentinel write must not leak stderr or storm duplicates ---------------
# Same redirection-order rule as the append; this instance sat two lines away.
use_wt feat/sentfail SENT1; PMAIN="$WT_MAIN"; PWT="$WT_WT"
mkdir -p "$PMAIN/.auto-task"; : > "$PMAIN/.auto-task/outcomes.jsonl"
chmod 500 "$PWT/.auto-task/feat/sentfail"      # STATE.json readable, sentinel unwritable
SOUT="$(printf '{"cwd":"%s"}' "$PWT" | CLAUDE_PROJECT_DIR="$PMAIN" bash "$REC" 2>&1; echo "EXIT=$?")"
expect_has "unwritable sentinel: exit 0"  "$SOUT" "EXIT=0"
expect "unwritable sentinel: emits nothing (stdout+stderr)" \
  "$(printf '%s' "$SOUT" | sed 's/EXIT=0//' | tr -d '[:space:]' | wc -c | tr -d ' ')" "0"
chmod 700 "$PWT/.auto-task/feat/sentfail"

# --- A REMOVABLE stale lock is reclaimed, not merely waited out ---------------
use_wt feat/oldlock OLD1; OMAIN="$WT_MAIN"; OWT="$WT_WT"
mkdir -p "$OMAIN/.auto-task"; : > "$OMAIN/.auto-task/outcomes.jsonl"
OLOCK="$OMAIN/.auto-task/outcomes.jsonl.lock"
mkdir -p "$OLOCK"; touch -t 202001010000 "$OLOCK" 2>/dev/null || true
expect "old lock: reclaimed and row recorded" \
  "$(printf '{"cwd":"%s"}' "$OWT" | CLAUDE_PROJECT_DIR="$OMAIN" bash "$REC" >/dev/null; rows "$OMAIN")" "1"
expect "old lock: lock released afterwards" \
  "$([ -d "$OLOCK" ] && echo yes || echo no)" "no"

# --- Guard 2 DETECT: a successful append whose row is ABSENT stays retryable ---
# AC14a exercises an *open* failure, which never reaches the verification step. This
# exercises the round-2 deliverable itself: printf succeeds, yet the row is not in
# the file, so the sentinel must NOT be stamped. Simulated by making the ledger a
# symlink to /dev/null — writes succeed, reads never contain the row.
use_wt feat/detect DETECT1; DMAIN="$WT_MAIN"; DWT="$WT_WT"
DSD="$DWT/.auto-task/feat/detect"
mkdir -p "$DMAIN/.auto-task"
ln -sf /dev/null "$DMAIN/.auto-task/outcomes.jsonl"
expect "detect guard: hook exits 0" \
  "$(printf '{"cwd":"%s"}' "$DWT" | CLAUDE_PROJECT_DIR="$DMAIN" bash "$REC"; echo $?)" "0"
expect "detect guard: row absent → sentinel NOT stamped" \
  "$([ -f "$DSD/.outcome-recorded" ] && echo yes || echo no)" "no"
rm -f "$DMAIN/.auto-task/outcomes.jsonl"

# --- An appendable-but-UNREADABLE ledger must not cause a duplicate storm ------
# grep exits >1 when it cannot read the file. Treating that as "row absent" would
# withhold the sentinel forever, appending a fresh copy every single turn-end.
# "Cannot verify" must fall back to trusting the append, not to infinite retry.
use_wt feat/noread NOREAD1; NMAIN="$WT_MAIN"; NWT="$WT_WT"
NSD="$NWT/.auto-task/feat/noread"
mkdir -p "$NMAIN/.auto-task"; : > "$NMAIN/.auto-task/outcomes.jsonl"
chmod 200 "$NMAIN/.auto-task/outcomes.jsonl"    # write-only: appendable, unreadable
printf '{"cwd":"%s"}' "$NWT" | CLAUDE_PROJECT_DIR="$NMAIN" bash "$REC" >/dev/null 2>&1
expect "unreadable ledger: sentinel stamped (no retry storm)" \
  "$(cat "$NSD/.outcome-recorded" 2>/dev/null)" "NOREAD1"
printf '{"cwd":"%s"}' "$NWT" | CLAUDE_PROJECT_DIR="$NMAIN" bash "$REC" >/dev/null 2>&1
chmod 644 "$NMAIN/.auto-task/outcomes.jsonl"
expect "unreadable ledger: exactly one row after two calls" "$(rows "$NMAIN")" "1"

# --- Degraded environments: no git, no jq (writer must stay silent + exit 0) ---
use_wt feat/degraded DEG1; GMAIN="$WT_MAIN"; GWT="$WT_WT"
mkdir -p "$GMAIN/.auto-task"; : > "$GMAIN/.auto-task/outcomes.jsonl"
STUBBIN="$(cd "$(mktemp -d)" && pwd -P)"; wt_track "$STUBBIN"
# Everything the hook may legitimately need EXCEPT the tool under test. `bash` is
# deliberately NOT stubbed in — it is invoked by absolute path below, so the stub
# PATH stays an honest "these are the only commands available" statement.
#
# `dirname` matters and must be present: it is POSIX-mandated and ships with every
# system that has bash, so omitting it would test an environment that cannot occur
# — and it would fail for the wrong reason (the pre-existing SCRIPT_DIR resolution
# leaks a "dirname: command not found" to stderr, which has nothing to do with the
# git/jq absence these two cases exist to probe).
for tool in dirname sed grep cat mkdir rmdir rm date stat sleep wc head; do
  src="$(command -v "$tool" 2>/dev/null)" && ln -sf "$src" "$STUBBIN/$tool" 2>/dev/null
done
BASH_ABS="$(command -v bash)"
# no git on PATH
OUTNG="$(printf '{"cwd":"%s"}' "$GWT" | PATH="$STUBBIN" CLAUDE_PROJECT_DIR="$GMAIN" \
  "$BASH_ABS" "$REC" 2>&1; echo "EXIT=$?")"
expect "no git: exits 0"        "$(printf '%s' "$OUTNG" | grep -c 'EXIT=0')" "1"
expect "no git: emits nothing"  "$(printf '%s' "$OUTNG" | sed 's/EXIT=0//' | tr -d '[:space:]' | wc -c | tr -d ' ')" "0"
# git present, jq absent
ln -sf "$(command -v git)" "$STUBBIN/git" 2>/dev/null
OUTNJ="$(printf '{"cwd":"%s"}' "$GWT" | PATH="$STUBBIN" CLAUDE_PROJECT_DIR="$GMAIN" \
  "$BASH_ABS" "$REC" 2>&1; echo "EXIT=$?")"
expect "no jq: exits 0"         "$(printf '%s' "$OUTNJ" | grep -c 'EXIT=0')" "1"
expect "no jq: emits nothing"   "$(printf '%s' "$OUTNJ" | sed 's/EXIT=0//' | tr -d '[:space:]' | wc -c | tr -d ' ')" "0"
expect "no jq: records nothing (row needs jq)" "$(rows "$GMAIN")" "0"
# The READER must also survive both, and say so rather than crashing.
OUTRJ="$(cd "$GMAIN" && PATH="$STUBBIN" CLAUDE_PROJECT_DIR="$GMAIN" "$BASH_ABS" "$STATS" 2>&1; echo "EXIT=$?")"
expect_has "no jq: reader exits 0"            "$OUTRJ" "EXIT=0"
expect_has "no jq: reader explains why"       "$OUTRJ" "jq is not installed"

# --- AC14a: a FAILED append leaves the run retryable (sentinel unwritten) ------
# The critical honesty property: printf reports success on a torn write, so if the
# sentinel were stamped unconditionally the run's telemetry would be lost forever.
use_wt feat/retry RETRY1; RMAIN="$WT_MAIN"; RWT="$WT_WT"
RSD="$RWT/.auto-task/feat/retry"
mkdir -p "$RMAIN/.auto-task"; : > "$RMAIN/.auto-task/outcomes.jsonl"
chmod 444 "$RMAIN/.auto-task/outcomes.jsonl"
expect "failed append: hook still exits 0" \
  "$(printf '{"cwd":"%s"}' "$RWT" | CLAUDE_PROJECT_DIR="$RMAIN" bash "$REC"; echo $?)" "0"
expect "failed append: sentinel NOT written (stays retryable)" \
  "$([ -f "$RSD/.outcome-recorded" ] && echo yes || echo no)" "no"
chmod 644 "$RMAIN/.auto-task/outcomes.jsonl"
expect "failed append: retry now records the row" \
  "$(printf '{"cwd":"%s"}' "$RWT" | CLAUDE_PROJECT_DIR="$RMAIN" bash "$REC" >/dev/null; rows "$RMAIN")" "1"
expect "failed append: retry stamps the sentinel" \
  "$(cat "$RSD/.outcome-recorded" 2>/dev/null)" "RETRY1"

# --- AC14b: the reader COUNTS and REPORTS unparseable rows ---------------------
use_wt feat/torn TORN1; TMAIN="$WT_MAIN"; TWT="$WT_WT"
mkdir -p "$TMAIN/.auto-task"
{ printf '{"at":"2026-05-01T10:00:00Z","branch":"feat/ok","base":"OK1","plugin_version":"0.28.0","terminal_state":"done","tier":"standard","gate_b":"passed","followups":0,"defects_late":0,"defects_early":0,"flaky":false,"tests_added":true,"duration_min":30,"fix_iterations":0,"review_iterations":1,"escalations":0,"checks_run":1,"checks_failed":0,"pr_url":null}\n'
  printf '{"at":"2026-05-01T11:00:00Z","branch":"feat/tor\n'; } > "$TMAIN/.auto-task/outcomes.jsonl"
rm -rf "$TWT/.auto-task"   # isolate: only the ledger is in play
OUTT="$(cd "$TMAIN" && CLAUDE_PROJECT_DIR="$TMAIN" bash "$STATS" 2>&1; echo "EXIT=$?")"
expect_has "torn row: reader exits 0"                    "$OUTT" "EXIT=0"
expect_has "torn row: skip is reported, not silent"      "$OUTT" "1 unparseable ledger row(s) skipped"
expect_has "torn row: the valid run is still counted"    "$OUTT" "1 runs on record"

# --- The worst shape: EVERY row torn, so total==0 ------------------------------
# The `1 valid + 1 torn` fixture above keeps total>0 and so only ever reaches the
# normal report path. The realistic bad case is a clone whose ONLY completed run had
# its row torn: total is 0, and the empty-ledger early-exit must NOT claim the ledger
# is empty and tell the user to go complete a run — that is the silent data loss this
# notice exists to prevent, in its most misleading form.
use_wt feat/alltorn ALLTORN1; AMAIN="$WT_MAIN"; AWT="$WT_WT"
rm -rf "$AWT/.auto-task"
mkdir -p "$AMAIN/.auto-task"
printf '{"at":"2026-05-01T11:00:00Z","branch":"feat/tor\n' > "$AMAIN/.auto-task/outcomes.jsonl"
OUTA="$(cd "$AMAIN" && CLAUDE_PROJECT_DIR="$AMAIN" bash "$STATS" 2>&1; echo "EXIT=$?")"
expect_has "all-torn: reader exits 0"                  "$OUTA" "EXIT=0"
expect_has "all-torn: the skip is still reported"      "$OUTA" "1 unparseable ledger row(s) skipped"
if printf '%s' "$OUTA" | grep -q "the ledger is empty"; then
  FAIL=$((FAIL+1)); printf '  FAIL  %-56s (claims empty while holding a torn row)\n' "all-torn: does not claim empty"
else
  PASS=$((PASS+1)); printf '  PASS  %-56s (found)\n' "all-torn: does not claim empty"
fi

# --- The "nothing to report" guard must still be reachable ---------------------
# It is keyed on whether any scanned root EXISTS, not on the roots string being
# empty: the fallback sets that string to `$AT` unconditionally and `$AT` is never
# empty, so an emptiness test would be dead code that silently swallowed this
# pre-existing message.
NR="$(cd "$(mktemp -d)" && pwd -P)"; wt_track "$NR"
( cd "$NR" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
OUTNR="$(cd "$NR" && CLAUDE_PROJECT_DIR="$NR" bash "$STATS" 2>&1; echo "EXIT=$?")"
expect_has "no .auto-task anywhere: nothing-to-report message" "$OUTNR" "nothing to report"
expect_has "no .auto-task anywhere: exit 0"                    "$OUTNR" "EXIT=0"

# --- A ledger with NO trailing newline must not glue rows together -------------
# `jq empty` accepts a STREAM, so a glued `{…}{…}` line passes per-line validation:
# the previously-valid row is destroyed, the skipped-row counter stays 0, and the
# headline (`wc -l`) disagrees with the `jq -s` aggregation. The documented stray-
# ledger migration (`cat <worktree>/… >> .auto-task/outcomes.jsonl`) produces exactly
# this shape whenever the source lacks a trailing newline.
use_wt feat/nonl NONL1; NLMAIN="$WT_MAIN"; NLWT="$WT_WT"
mkdir -p "$NLMAIN/.auto-task"
printf '{"at":"2026-05-01T10:00:00Z","branch":"feat/old","base":"OLD","plugin_version":"0.28.0","terminal_state":"done","tier":"light","gate_b":"passed","followups":0,"defects_late":0,"defects_early":0,"flaky":false,"tests_added":true,"duration_min":10,"fix_iterations":0,"review_iterations":0,"escalations":0,"checks_run":1,"checks_failed":0,"pr_url":null}' \
  > "$NLMAIN/.auto-task/outcomes.jsonl"    # deliberately NO trailing newline
printf '{"cwd":"%s"}' "$NLWT" | CLAUDE_PROJECT_DIR="$NLMAIN" bash "$REC" >/dev/null 2>&1
expect "no-trailing-newline: two separate rows, not one glued" "$(rows "$NLMAIN")" "2"
count_multi(){ # lines that are not EXACTLY one JSON value
  local n bad=0 l
  while IFS= read -r l || [ -n "$l" ]; do
    [ -n "$l" ] || continue
    n="$(printf '%s' "$l" | jq -s 'length' 2>/dev/null || echo 0)"
    [ "$n" = "1" ] || bad=$((bad + 1))
  done < "$1"
  echo "$bad"
}
expect "no-trailing-newline: no glued/multi-value line exists" \
  "$(count_multi "$NLMAIN/.auto-task/outcomes.jsonl")" "0"
expect "no-trailing-newline: the pre-existing row survived" \
  "$(jq -r '.branch' < "$NLMAIN/.auto-task/outcomes.jsonl" | grep -cxF 'feat/old')" "1"
OUTNL="$(cd "$NLMAIN" && CLAUDE_PROJECT_DIR="$NLMAIN" bash "$STATS" 2>&1)"
expect_has "no-trailing-newline: headline counts both runs" "$OUTNL" "2 runs on record — 2 done"
expect "no-trailing-newline: no spurious skipped-row notice" \
  "$(printf '%s' "$OUTNL" | grep -c 'unparseable ledger row')" "0"

# --- A ledger that ALREADY contains a glued line must be reported, not swallowed --
use_wt feat/glued GLUED1; GMAIN2="$WT_MAIN"; GWT2="$WT_WT"
rm -rf "$GWT2/.auto-task"
mkdir -p "$GMAIN2/.auto-task"
{ printf '{"at":"2026-05-01T10:00:00Z","branch":"feat/a","base":"A","plugin_version":"0.28.0","terminal_state":"done","tier":"light","gate_b":"passed","followups":0,"defects_late":0,"defects_early":0,"flaky":false,"tests_added":true,"duration_min":10,"fix_iterations":0,"review_iterations":0,"escalations":0,"checks_run":1,"checks_failed":0,"pr_url":null}'
  printf '{"at":"2026-05-02T10:00:00Z","branch":"feat/b","base":"B","plugin_version":"0.28.0","terminal_state":"done","tier":"light","gate_b":"passed","followups":0,"defects_late":0,"defects_early":0,"flaky":false,"tests_added":true,"duration_min":10,"fix_iterations":0,"review_iterations":0,"escalations":0,"checks_run":1,"checks_failed":0,"pr_url":null}\n'; } \
  > "$GMAIN2/.auto-task/outcomes.jsonl"    # two values on ONE line
OUTG2="$(cd "$GMAIN2" && CLAUDE_PROJECT_DIR="$GMAIN2" bash "$STATS" 2>&1; echo "EXIT=$?")"
expect_has "glued line: reader exits 0"                   "$OUTG2" "EXIT=0"
expect_has "glued line: reported as unparseable"          "$OUTG2" "1 unparseable ledger row(s) skipped"

# --- Freshness must decide in-flight vs stalled, NOT find order ----------------
# The same run sighted under two roots with DIFFERENT history: the freshest sighting
# must win, and the verdict must be identical whichever root holds the fresh copy.
# An earlier revision claimed the key on first sighting and read freshness from THAT
# copy, so a stale copy at main reported a live run as stalled with the wrong phase.
use_wt feat/fresh FRESH1; FMAIN="$WT_MAIN"; FWT="$WT_WT"
OLDI="$(days_ago 30)"
write_live(){ # write_live <dir> <phase> <at>
  mkdir -p "$1"
  cat > "$1/STATE.json" <<EOF
{"phase":"$2","approved":true,"branch":"feat/fresh","base":"FRESH1",
 "effort":{"tier":"light","history":[]},"iteration":{"review":0,"fix":0},
 "history":[{"phase":"$2","result":"ok","at":"$3"}],"gates":{},"followups":[]}
EOF
}
write_live "$FMAIN/.auto-task/feat/fresh" execute "$OLDI"        # stale at main
write_live "$FWT/.auto-task/feat/fresh"   review  "$(now_iso)"   # live in worktree
OUTF1="$(cd "$FMAIN" && CLAUDE_PROJECT_DIR="$FMAIN" bash "$STATS" 2>&1)"
expect_has "freshness: live-in-worktree beats stale-at-main" \
  "$OUTF1" "1 runs on record — 0 done, 0 stalled, 1 in-flight"
write_live "$FMAIN/.auto-task/feat/fresh" review  "$(now_iso)"   # now reversed
write_live "$FWT/.auto-task/feat/fresh"   execute "$OLDI"
OUTF2="$(cd "$FMAIN" && CLAUDE_PROJECT_DIR="$FMAIN" bash "$STATS" 2>&1)"
expect_has "freshness: verdict is identical with the roots reversed" \
  "$OUTF2" "1 runs on record — 0 done, 0 stalled, 1 in-flight"
# And a genuinely stale run (every sighting old) must still report as stalled.
write_live "$FMAIN/.auto-task/feat/fresh" execute "$OLDI"
write_live "$FWT/.auto-task/feat/fresh"   execute "$OLDI"
OUTF3="$(cd "$FMAIN" && CLAUDE_PROJECT_DIR="$FMAIN" bash "$STATS" 2>&1)"
expect_has "freshness: an all-stale run is still stalled" \
  "$OUTF3" "1 runs on record — 0 done, 1 stalled, 0 in-flight"

# --- Live-sighting records must survive an EMPTY field and a newline in the text ---
# The sighting records are line-and-field oriented, so two things corrupt the tally if
# unhandled. (a) A missing `base` emits an empty field; with a TAB separator `read`
# collapses it (tab is IFS whitespace), so `newest` receives the phase string, scores
# 0, and a LIVE run is misreported as stalled. (b) `jq -r` unescapes `\n` in a
# model-written summary into a real newline, splitting one record into two — the
# continuation is then counted as an extra run.
use_wt feat/fieldint FI1; QMAIN="$WT_MAIN"; QWT="$WT_WT"
rm -rf "$QWT/.auto-task"
NOWQ="$(now_iso)"
mkdir -p "$QMAIN/.auto-task/feat/nobase2"
# No `base` at all -> an empty field in the middle of the record.
cat > "$QMAIN/.auto-task/feat/nobase2/STATE.json" <<EOF
{"phase":"review","approved":true,"branch":"feat/nobase2",
 "effort":{"tier":"light","history":[]},"iteration":{"review":1,"fix":0},
 "history":[{"phase":"review","result":"ok","at":"$NOWQ"}],"gates":{},"followups":[]}
EOF
OUTQ1="$(cd "$QMAIN" && CLAUDE_PROJECT_DIR="$QMAIN" bash "$STATS" 2>&1)"
expect_has "field integrity: a run with no base is in-flight, not stalled" \
  "$OUTQ1" "1 runs on record — 0 done, 0 stalled, 1 in-flight"
# A summary containing an escaped newline and tab -> must stay ONE record.
rm -rf "$QMAIN/.auto-task/feat/nobase2"
mkdir -p "$QMAIN/.auto-task/feat/multiline"
cat > "$QMAIN/.auto-task/feat/multiline/STATE.json" <<EOF
{"phase":"review","approved":true,"branch":"feat/multiline","base":"ML1",
 "effort":{"tier":"light","history":[]},"iteration":{"review":1,"fix":0},
 "history":[{"phase":"review","result":"ok","summary":"first line\\nsecond line\\twith tab","at":"$NOWQ"}],
 "gates":{},"followups":[]}
EOF
OUTQ2="$(cd "$QMAIN" && CLAUDE_PROJECT_DIR="$QMAIN" bash "$STATS" 2>&1)"
expect_has "field integrity: a multi-line summary yields exactly one run" \
  "$OUTQ2" "1 runs on record — 0 done, 0 stalled, 1 in-flight"
# Same, but stale, so it reaches the stalled list where the summary is printed.
cat > "$QMAIN/.auto-task/feat/multiline/STATE.json" <<EOF
{"phase":"execute","approved":true,"branch":"feat/multiline","base":"ML1",
 "effort":{"tier":"light","history":[]},"iteration":{"review":0,"fix":0},
 "history":[{"phase":"execute","result":"ok","summary":"first line\\nsecond line","at":"$(days_ago 30)"}],
 "gates":{},"followups":[]}
EOF
OUTQ3="$(cd "$QMAIN" && CLAUDE_PROJECT_DIR="$QMAIN" bash "$STATS" 2>&1)"
expect_has "field integrity: multi-line summary counted once when stalled" \
  "$OUTQ3" "1 runs on record — 0 done, 1 stalled, 0 in-flight"
# The separator itself must not be a whitespace character, or empty fields collapse.
expect "field integrity: sighting separator is \\037, not a tab" \
  "$(grep -c "printf '%s\\\\037%s\\\\037%s\\\\037%s\\\\037%s" "$STATS")" "1"
expect "field integrity: free-text fields are sanitised" \
  "$(grep -c '^_san()' "$STATS")" "1"

# --- The harness's own cleanup must never rm -rf a shallow/truncated path ------
# This suite feeds fixture paths to `rm -rf`, so the accumulator is newline-delimited
# and the cleanup rejects anything without real depth. A space-containing TMPDIR used
# to word-split the paths and hand a prefix like `/private/tmp` to `rm -rf`.
# These drive the REAL `cleanup_wt` in a subshell with a controlled WTROOTS — not a
# hand-copied reimplementation of its guard. That distinction is the whole point:
# asserting against a duplicate of the logic passes even when the shipped guard is
# deleted (verified by mutation), which is exactly the vacuous-coverage trap this run
# has hit repeatedly.
SPB="$(cd "$(mktemp -d)" && pwd -P)"; wt_track "$SPB"
mkdir -p "$SPB/a b/deep" "$SPB/a"; : > "$SPB/a/KEEP"
( WTROOTS="$SPB/a b/deep
"; cleanup_wt )
expect "cleanup: removes a fixture path containing a space" \
  "$([ -e "$SPB/a b/deep" ] && echo no || echo yes)" "yes"
expect "cleanup: does NOT delete the split-off prefix" \
  "$([ -f "$SPB/a/KEEP" ] && echo yes || echo no)" "yes"
# And the depth guard, again through the real function: a relative path must be
# refused outright rather than resolved against the cwd.
mkdir -p "$SPB/cwd/relcanary"; : > "$SPB/cwd/relcanary/KEEP"
( cd "$SPB/cwd" && WTROOTS="relcanary
"; cleanup_wt )
expect "cleanup: refuses a relative path (no cwd-relative delete)" \
  "$([ -f "$SPB/cwd/relcanary/KEEP" ] && echo yes || echo no)" "yes"
expect "harness: accumulator is newline-delimited, not space" \
  "$(grep -c 'WTROOTS="\$WTROOTS\$1' "$0")" "1"

# --- A model-written non-numeric first_pass_ac must not blank the whole report ---
# `quality.planning.first_pass_ac` is free-text in real state files (strings and
# booleans as often as numbers). The aggregator SUMS it, and jq cannot add a number to
# a string — a fatal error in the single agg pass, which blanks EVERY metric section
# rather than one metric. Measured on a real 9-run clone: all quality rates read
# `n=0 (no data)`, the By-tier table printed empty, Gate-B coverage `0/0`.
use_wt feat/fpac FPAC1; PMAIN2="$WT_MAIN"; PWT2="$WT_WT"
rm -rf "$PWT2/.auto-task"
mkdir -p "$PMAIN2/.auto-task"
mk_done_row(){ # mk_done_row <dir> <branch> <base> <first_pass_ac literal>
  mkdir -p "$1"
  cat > "$1/STATE.json" <<EOF
{"phase":"done","approved":true,"branch":"$2","base":"$3","pr_url":null,"description":"d",
 "effort":{"tier":"standard","history":[]},"iteration":{"review":1,"fix":1},
 "history":[{"phase":"handover","result":"done","at":"2026-01-01T10:30:00Z"}],
 "gates":{"gate_b":{"passed":true}},
 "quality":{"tests_added":true,"flaky":false,"defects":{"early":2,"late":0},
            "diff":{"loc_added":10,"loc_removed":2},"planning":{"first_pass_ac":$4}},
 "followups":[]}
EOF
}
mk_done_row "$PMAIN2/.auto-task/feat/num"  feat/num  N1 '0.9'
mk_done_row "$PMAIN2/.auto-task/feat/str"  feat/str  S1 '"6/6 self-verify ACs green on the first pass"'
mk_done_row "$PMAIN2/.auto-task/feat/bool" feat/bool B1 'false'
OUTFP="$(cd "$PMAIN2" && CLAUDE_PROJECT_DIR="$PMAIN2" bash "$STATS" 2>&1)"
expect_has "mixed first_pass_ac: all three runs counted"      "$OUTFP" "3 runs on record — 3 done"
# The load-bearing part: the aggregate sections must carry REAL numbers, not blanks.
expect_has "mixed first_pass_ac: tests-added rate is computed"  "$OUTFP" "Tests-added rate       100%"
expect_has "mixed first_pass_ac: early-defect capture computed" "$OUTFP" "Early-defect capture   2 avg"
expect_has "mixed first_pass_ac: By-tier table has rows"        "$OUTFP" "standard       3"
expect_has "mixed first_pass_ac: Gate B coverage is real"       "$OUTFP" "ran on 3/3 standard+heavy runs"
# Only the numeric one feeds the first-pass mean; the string/boolean are excluded.
expect_has "mixed first_pass_ac: mean over the numeric row only" "$OUTFP" "First-pass AC pass     90% mean (n=1)"

# --- EVERY arithmetic field must survive a non-numeric value, not just first_pass_ac -
# Same class, same file: `add` and `/` are fatal on a mixed type, and a bare `> 0` does
# NOT exclude a string (jq sorts strings after numbers, so "40" > 0 is true and the
# value flows straight into the division). One fatal error blanks the whole report, so
# this fixture makes EVERY numeric field a string at once and demands a real report.
mkdir -p "$PMAIN2/.auto-task/feat/allstr"
cat > "$PMAIN2/.auto-task/feat/allstr/STATE.json" <<'EOF'
{"phase":"done","approved":true,"branch":"feat/allstr","base":"AS1","pr_url":null,"description":"d",
 "effort":{"tier":"standard","history":[]},
 "iteration":{"review":"two","fix":"one"},
 "estimate":{"duration_min":"40","tokens_output":"900000"},
 "actuals":{"duration_min":"52","tokens_total":"180000000","tokens_breakdown":{"output":"1000000"}},
 "history":[{"phase":"handover","result":"done","at":"2026-01-01T10:30:00Z"}],
 "gates":{"gate_b":{"passed":true}},
 "quality":{"tests_added":true,"flaky":false,
            "defects":{"early":"several","late":"none"},
            "diff":{"loc_added":"10","loc_removed":"2"},
            "planning":{"first_pass_ac":"most of them"}},
 "followups":[]}
EOF
OUTAS="$(cd "$PMAIN2" && CLAUDE_PROJECT_DIR="$PMAIN2" bash "$STATS" 2>&1; echo "EXIT=$?")"
expect_has "all-string fields: reader exits 0"                "$OUTAS" "EXIT=0"
expect_has "all-string fields: the run is still counted"      "$OUTAS" "4 runs on record — 4 done"
# The proof that nothing went fatal: the aggregate sections still carry real numbers.
expect_has "all-string fields: tests-added rate still real"   "$OUTAS" "Tests-added rate       100%"
expect_has "all-string fields: By-tier table still has rows"  "$OUTAS" "standard       4"
expect_has "all-string fields: Gate B coverage still real"    "$OUTAS" "ran on 4/4 standard+heavy runs"
# A string duration/token must be EXCLUDED from the ratios, never coerced into them.
expect "all-string fields: no bogus duration ratio" \
  "$(printf '%s' "$OUTAS" | grep -c 'time:.*actual/est')" "0"
# And the writer must produce a row whose numeric fields are numbers or null.
mkdir -p "$PMAIN2/.auto-task" && : > "$PMAIN2/.auto-task/outcomes.jsonl"
( cd "$PMAIN2" && git checkout -q -b feat/allstr 2>/dev/null || true )
printf '{"cwd":"%s"}' "$PMAIN2" | CLAUDE_PROJECT_DIR="$PMAIN2" bash "$REC" >/dev/null 2>&1
if [ "$(rows "$PMAIN2")" = "1" ]; then
  BADT="$(head -1 "$PMAIN2/.auto-task/outcomes.jsonl" | jq -r '
    [ .fix_iterations, .review_iterations, .defects_early, .defects_late, .diff_loc,
      .est_duration_min, .est_tokens, .act_tokens, .act_tokens_output, .first_pass_ac ]
    | map(select(. != null and (type != "number"))) | length')"
  expect "writer row: no non-numeric value in any arithmetic field" "$BADT" "0"
else
  PASS=$((PASS+1)); printf '  PASS  %-56s (row not applicable here)\n' "writer row: numeric fields"
fi

# --- A non-string `tier` must not blank the By-tier table ------------------------
# `.[0:N]` is as fatal on a wrong type as `add` is, and it sits OUTSIDE both numeric
# guard layers — so a numeric effort.tier rendered the whole section as headers with no
# rows, losing the well-formed rows too, with no skip counter touched.
use_wt feat/tiertype TT1; YMAIN="$WT_MAIN"; YWT="$WT_WT"
rm -rf "$YWT/.auto-task"
mkdir -p "$YMAIN/.auto-task"
mk_tier_row(){ # mk_tier_row <dir> <branch> <base> <tier literal>
  mkdir -p "$1"
  cat > "$1/STATE.json" <<EOF
{"phase":"done","approved":true,"branch":"$2","base":"$3","pr_url":null,"description":"d",
 "effort":{"tier":$4,"history":[]},"iteration":{"review":1,"fix":1},
 "history":[{"phase":"handover","result":"done","at":"2026-01-01T10:30:00Z"}],
 "gates":{"gate_b":{"passed":true}},
 "quality":{"tests_added":true,"flaky":false,"defects":{"early":1,"late":0},
            "diff":{"loc_added":5,"loc_removed":1},"planning":{"first_pass_ac":1}},
 "followups":[]}
EOF
}
mk_tier_row "$YMAIN/.auto-task/feat/goodtier" feat/goodtier GT1 '"standard"'
mk_tier_row "$YMAIN/.auto-task/feat/numtier"  feat/numtier  NT1 '7'
mk_tier_row "$YMAIN/.auto-task/feat/booltier" feat/booltier BT2 'true'
OUTTT="$(cd "$YMAIN" && CLAUDE_PROJECT_DIR="$YMAIN" bash "$STATS" 2>&1; echo "EXIT=$?")"
expect_has "non-string tier: reader exits 0"                 "$OUTTT" "EXIT=0"
expect_has "non-string tier: all three runs counted"         "$OUTTT" "3 runs on record — 3 done"
# The load-bearing assertion: the well-formed row must still appear in the table.
expect_has "non-string tier: the good tier row still renders" "$OUTTT" "standard       1"
expect "non-string tier: By-tier table is not empty" \
  "$(printf '%s' "$OUTTT" | awk '/^By tier/{f=1;next} /^Gate B coverage/{f=0} f&&/^  [a-z?]/{c++} END{print c+0}')" "2"

# --- A skip notice must never be contradicted in the same report -----------------
# Gate A already fixed this for a skipped LEDGER row; adding skipped_live reintroduced
# the shape — the counter printed, then "no live runs are on disk / complete a run to
# populate it" denied it, telling the maintainer to redo a run that had completed.
use_wt feat/contra CT1; CMAIN2="$WT_MAIN"; CWT2="$WT_WT"
rm -rf "$CWT2/.auto-task"
mkdir -p "$CMAIN2/.auto-task/feat/broken"; : > "$CMAIN2/.auto-task/outcomes.jsonl"
cat > "$CMAIN2/.auto-task/feat/broken/STATE.json" <<'EOF'
{"phase":"done","approved":true,"branch":"feat/broken","base":"BRK1","pr_url":null,
 "effort":{"tier":"light","history":[]},"iteration":{"review":0,"fix":0},
 "history":"this should be an array","gates":{},"followups":[]}
EOF
OUTCT="$(cd "$CMAIN2" && CLAUDE_PROJECT_DIR="$CMAIN2" bash "$STATS" 2>&1; echo "EXIT=$?")"
expect_has "skip contradiction: exits 0"                   "$OUTCT" "EXIT=0"
expect_has "skip contradiction: the skip is reported"      "$OUTCT" "live STATE.json file(s) skipped"
# The claim must be HEDGED, not asserted: an unparseable file is counted before its phase
# can be read, so "a completed run IS on disk" would be an over-claim.
expect_has "skip contradiction: the claim is hedged, not asserted" "$OUTCT" "may be a completed run"
if printf '%s' "$OUTCT" | grep -q "A completed run IS on disk"; then
  FAIL=$((FAIL+1)); printf '  FAIL  %-56s (over-claims a completion it cannot know)\n' "skip contradiction: no over-claim"
else
  PASS=$((PASS+1)); printf '  PASS  %-56s (found)\n' "skip contradiction: no over-claim"
fi
# The skipped file must be NAMED — "inspect the file named by the skip count" names none.
expect "skip contradiction: the skipped file is named" \
  "$(printf '%s' "$OUTCT" | grep -c 'feat/broken/STATE.json')" "1"
if printf '%s' "$OUTCT" | grep -qE 'no live runs are on disk|Complete an /auto-task run to populate it'; then
  FAIL=$((FAIL+1)); printf '  FAIL  %-56s (denies the skip it just reported)\n' "skip contradiction: no denial"
else
  PASS=$((PASS+1)); printf '  PASS  %-56s (found)\n' "skip contradiction: no denial"
fi
# An UNPARSEABLE state file must be counted too, not dropped in silence.
printf '{"phase":"done","approved":true,"branch":"feat/trunc","base":"TR1","effort":{"tier":"lig' \
  > "$CMAIN2/.auto-task/feat/broken/STATE.json"
OUTTR="$(cd "$CMAIN2" && CLAUDE_PROJECT_DIR="$CMAIN2" bash "$STATS" 2>&1)"
expect_has "truncated state file: counted, not silently dropped" "$OUTTR" "live STATE.json file(s) skipped"

# --- A skip must never shadow the opt-in hint ------------------------------------
# The two things are independent: the opt-in state is worth reporting regardless of any
# skip. An if/elif chain let a non-zero skip count hide the only actionable line in this
# whole path — `touch <canonical path>` — from a clone that had never opted in.
rm -f "$CMAIN2/.auto-task/outcomes.jsonl"
OUTSH="$(cd "$CMAIN2" && CLAUDE_PROJECT_DIR="$CMAIN2" bash "$STATS" 2>&1)"
expect_has "skip + no ledger: the skip is still reported" "$OUTSH" "live STATE.json file(s) skipped"
expect_has "skip + no ledger: the opt-in hint is NOT shadowed" "$OUTSH" "Opt in with:  touch"
expect "skip + no ledger: the hint names the canonical path" \
  "$(printf '%s' "$OUTSH" | grep -c "$CMAIN2/.auto-task/outcomes.jsonl")" "1"

# --- The NORMAL report path must also name its skipped files ----------------------
# There are two copies of the naming block: the total==0 one and the normal-report one.
# Only the first was pinned, because every skip fixture so far had total==0. This one has
# a real counted run ALONGSIDE a broken file, so the normal report is what renders.
use_wt feat/namenorm NN1; NN_MAIN="$WT_MAIN"; NN_WT="$WT_WT"
mkdir -p "$NN_MAIN/.auto-task/feat/alsobroken"
cat > "$NN_MAIN/.auto-task/feat/alsobroken/STATE.json" <<'EOF'
{"phase":"done","approved":true,"branch":"feat/alsobroken","base":"AB1","pr_url":null,
 "effort":{"tier":"light","history":[]},"iteration":{"review":0,"fix":0},
 "history":"this should be an array","gates":{},"followups":[]}
EOF
OUTNN="$(cd "$NN_MAIN" && CLAUDE_PROJECT_DIR="$NN_MAIN" bash "$STATS" 2>&1)"
expect_has "normal report: the good run is counted"        "$OUTNN" "1 runs on record — 1 done"
expect_has "normal report: the skip is reported"           "$OUTNN" "live STATE.json file(s) skipped"
expect "normal report: the skipped file is NAMED here too" \
  "$(printf '%s' "$OUTNN" | grep -c 'feat/alsobroken/STATE.json')" "1"

# --- A branch value beginning with '-' must not hijack grep's stdin ---------------
# `norm_key` puts the branch first, so the dedup key can start with `-`. Without `--`,
# grep parses the key as an option, is left with no file operand, and reads the ENCLOSING
# LOOP's stdin — swallowing every remaining ledger row with no counter touched.
use_wt feat/dashkey DK1; DK_MAIN="$WT_MAIN"; DK_WT="$WT_WT"
rm -rf "$DK_WT/.auto-task"
mkdir -p "$DK_MAIN/.auto-task"
emit_dash(){ printf '{"at":"2026-05-0%sT10:00:00Z","branch":"%s","base":"D%s","plugin_version":"0.28.0","terminal_state":"done","tier":"light","gate_b":"passed","followups":0,"defects_late":0,"defects_early":0,"flaky":false,"tests_added":true,"duration_min":10,"fix_iterations":0,"review_iterations":0,"escalations":0,"checks_run":1,"checks_failed":0,"pr_url":null}\n' "$1" "$2" "$1"; }
{ emit_dash 1 '-x'; emit_dash 2 'feat/second'; emit_dash 3 'feat/third'; } > "$DK_MAIN/.auto-task/outcomes.jsonl"
OUTDK="$(cd "$DK_MAIN" && CLAUDE_PROJECT_DIR="$DK_MAIN" bash "$STATS" 2>&1; echo "EXIT=$?")"
expect_has "dash branch: reader exits 0"                        "$OUTDK" "EXIT=0"
expect_has "dash branch: all three rows survive the dedup scan" "$OUTDK" "3 runs on record — 3 done"
# The DISCRIMINATING case. Without `--`, grep treats the key as options: it exits 2 (an
# error) rather than 1 (no match), so the `&& continue` dedup check can never fire and a
# duplicated row is counted twice. (On a grep that parses the options and then finds no
# file operand, the same missing `--` makes it read the enclosing loop's stdin instead —
# same root cause, worse symptom. `--` is correct on both.)
{ emit_dash 1 '-x'; emit_dash 1 '-x'; } > "$DK_MAIN/.auto-task/outcomes.jsonl"
OUTDK2="$(cd "$DK_MAIN" && CLAUDE_PROJECT_DIR="$DK_MAIN" bash "$STATS" 2>&1)"
expect_has "dash branch: a duplicated '-'-leading key still dedups to one run" \
  "$OUTDK2" "1 runs on record — 1 done"
# THE OTHER GREP. There are two key lookups — one over ledger rows, one over live-done
# STATE.json — and the fixture above only reaches the ledger one, so the live-done `--` was
# unpinned even though the code change landed at both. Same run sighted under two roots:
# without `--` the cross-root dedup is dead and it counts twice.
use_wt chore/dashlive DL1; DL_MAIN="$WT_MAIN"; DL_WT="$WT_WT"
rm -rf "$DL_WT/.auto-task"
for _r in "$DL_MAIN" "$DL_WT"; do
  mkdir -p "$_r/.auto-task/-x"
  cat > "$_r/.auto-task/-x/STATE.json" <<'EOF'
{"phase":"done","approved":true,"branch":"-x","base":"DX1","pr_url":null,"description":"d",
 "effort":{"tier":"light","history":[]},"iteration":{"review":0,"fix":0},
 "history":[{"phase":"handover","result":"done","at":"2026-01-01T10:30:00Z"}],
 "gates":{"gate_b":{"skipped_reason":"tier=light"}},"followups":[]}
EOF
done
OUTDL="$(cd "$DL_MAIN" && CLAUDE_PROJECT_DIR="$DL_MAIN" bash "$STATS" 2>&1)"
expect_has "dash branch: a '-'-leading LIVE run at two roots dedups to one" \
  "$OUTDL" "1 runs on record — 1 done"

# --- A LEDGER row written before the coercion existed must not blank the report ---
# The DERIVE coercion stops bad types entering NEW rows, so it alone cannot protect
# rows already appended to an append-only ledger — those cannot be corrected
# retroactively, and they are precisely what the aggregator's own type guards are for.
# This seeds such a row directly (every arithmetic field a string) and demands a real
# report; without the agg guards the whole thing blanks.
use_wt feat/legacyrow LR1; LMAIN2="$WT_MAIN"; LWT2="$WT_WT"
rm -rf "$LWT2/.auto-task"
mkdir -p "$LMAIN2/.auto-task"
{ printf '{"at":"2026-05-01T10:00:00Z","branch":"feat/good","base":"G1","plugin_version":"0.28.0","terminal_state":"done","tier":"standard","gate_b":"passed","followups":2,"defects_late":0,"defects_early":3,"flaky":false,"tests_added":true,"duration_min":30,"est_duration_min":40,"act_duration_min":52,"est_tokens":900000,"act_tokens_output":1000000,"est_tokens_scale":"output","first_pass_ac":0.9,"diff_loc":12,"fix_iterations":1,"review_iterations":2,"escalations":0,"checks_run":1,"checks_failed":0,"pr_url":null}\n'
  printf '{"at":"2026-05-02T10:00:00Z","branch":"feat/legacy","base":"L1","plugin_version":"0.28.0","terminal_state":"done","tier":"standard","gate_b":"passed","followups":"two","defects_late":"none","defects_early":"several","flaky":false,"tests_added":true,"duration_min":"30","est_duration_min":"40","act_duration_min":"52","est_tokens":"900000","act_tokens_output":"1000000","est_tokens_scale":"output","first_pass_ac":"most","diff_loc":"12","fix_iterations":"one","review_iterations":"two","escalations":0,"checks_run":1,"checks_failed":0,"pr_url":null}\n'; } \
  > "$LMAIN2/.auto-task/outcomes.jsonl"
OUTLR="$(cd "$LMAIN2" && CLAUDE_PROJECT_DIR="$LMAIN2" bash "$STATS" 2>&1; echo "EXIT=$?")"
expect_has "legacy ledger row: reader exits 0"                 "$OUTLR" "EXIT=0"
expect_has "legacy ledger row: both rows counted"              "$OUTLR" "2 runs on record — 2 done"
# The load-bearing assertions: aggregates must still be real, not blanked.
expect_has "legacy ledger row: tests-added rate still real"     "$OUTLR" "Tests-added rate       100%"
expect_has "legacy ledger row: early-defect capture still real" "$OUTLR" "Early-defect capture   1.5 avg"
expect_has "legacy ledger row: By-tier table still has rows"    "$OUTLR" "standard       2"
expect_has "legacy ledger row: first-pass mean over the good row only" "$OUTLR" "First-pass AC pass     90% mean (n=1)"
# The string-typed durations/tokens must be EXCLUDED from the ratios, not coerced in.
# ANCHOR THE ORACLE TO THE TOKEN LINE. A bare "(n=1)" is satisfied by the First-pass and
# time lines regardless of what the token line says, which left tok_ok's isnum guard
# unpinned: without it a string est_tokens passes the positivity test, `"1000000" /
# "900000"` becomes a jq STRING SPLIT yielding ["1000000"], median scores that array as 0,
# and the report prints a fabricated `0x` ratio — the number --recalibrate scales the
# estimate constants by.
TOKLINE="$(printf '%s' "$OUTLR" | grep 'output tokens:' | head -1)"
expect_has "legacy ledger row: the token ratio line names n=1" "$TOKLINE" "(n=1)"
expect "legacy ledger row: the token ratio is not a fabricated 0x" \
  "$(printf '%s' "$TOKLINE" | grep -c 'median 0x')" "0"
expect "legacy ledger row: the token ratio is a real multiplier" \
  "$(printf '%s' "$TOKLINE" | grep -cE 'median [0-9]+\.[0-9]+x')" "1"

# --- Guard 2's "verified ABSENT" branch — the mechanism R11/AC14 rests on ---------
# Every other AC14 case reaches the append-FAILS path (`printf … || exit 0`), which is a
# different branch. Nothing produced a SUCCESSFUL append whose row is then absent, which
# is the sole reason guards 2 and 3 exist — so `1) landed=0` was unpinned and could have
# been collapsed to "always trust the append", restoring the permanent silent data loss
# R11 was written to close. Driven here by PATH-shadowing `grep` so `-qxF` reports
# not-found while the real append succeeds.
use_wt feat/g2absent G2A; QA_MAIN="$WT_MAIN"; QA_WT="$WT_WT"
QA_SD="$QA_WT/.auto-task/feat/g2absent"
mkdir -p "$QA_MAIN/.auto-task"; : > "$QA_MAIN/.auto-task/outcomes.jsonl"
QA_BIN="$(cd "$(mktemp -d)" && pwd -P)"; wt_track "$QA_BIN"
REAL_GREP="$(command -v grep)"
cat > "$QA_BIN/grep" <<EOS
#!/usr/bin/env bash
# Report "not found" for guard 2's whole-line probe; delegate everything else.
case " \$* " in *" -qxF "*) exit 1 ;; esac
exec "$REAL_GREP" "\$@"
EOS
chmod +x "$QA_BIN/grep"
printf '{"cwd":"%s"}' "$QA_WT" | PATH="$QA_BIN:$PATH" CLAUDE_PROJECT_DIR="$QA_MAIN" bash "$REC" >/dev/null 2>&1
expect "guard 2 absent: the row was still appended"       "$(rows "$QA_MAIN")" "1"
expect "guard 2 absent: sentinel WITHHELD (stays retryable)" \
  "$([ -f "$QA_SD/.outcome-recorded" ] && echo yes || echo no)" "no"
# With grep working again, the retry must recover the run and stamp it.
printf '{"cwd":"%s"}' "$QA_WT" | CLAUDE_PROJECT_DIR="$QA_MAIN" bash "$REC" >/dev/null 2>&1
expect "guard 2 absent: retry stamps the sentinel"        "$(cat "$QA_SD/.outcome-recorded" 2>/dev/null)" "G2A"

# --- The WRITER's str0 coercions must land strings in the row ---------------------
# The live-state fixtures cannot pin these: the READER's DERIVE coercion neutralises a
# bad type before the report is reached, so only the written row proves the writer half.
use_wt feat/wstr WS1; WS_MAIN="$WT_MAIN"; WS_WT="$WT_WT"
WS_SD="$WS_WT/.auto-task/feat/wstr"
cat > "$WS_SD/STATE.json" <<'EOF'
{"phase":"done","approved":true,"branch":"feat/wstr","base":"WS1","pr_url":null,
 "description":{"not":"a string"},
 "effort":{"tier":7,"history":[{"from":false}]},"iteration":{"review":1,"fix":0},
 "history":[{"phase":"handover","result":"done","at":"2026-01-01T10:30:00Z"}],
 "gates":{"gate_b":{"passed":false,"skipped_reason":["not","a","string"]}},"followups":[]}
EOF
mkdir -p "$WS_MAIN/.auto-task"; : > "$WS_MAIN/.auto-task/outcomes.jsonl"
printf '{"cwd":"%s"}' "$WS_WT" | CLAUDE_PROJECT_DIR="$WS_MAIN" bash "$REC" >/dev/null 2>&1
expect "writer str0: a row was written despite non-string fields" "$(rows "$WS_MAIN")" "1"
WSROW="$(head -1 "$WS_MAIN/.auto-task/outcomes.jsonl" 2>/dev/null || echo '{}')"
expect "writer str0: task is a string"    "$(printf '%s' "$WSROW" | jq -r '.task | type')"    "string"
expect "writer str0: tier is a string"    "$(printf '%s' "$WSROW" | jq -r '.tier | type')"    "string"
expect "writer str0: tier_initial is a string" "$(printf '%s' "$WSROW" | jq -r '.tier_initial | type')" "string"
expect "writer str0: gate_b is a string"  "$(printf '%s' "$WSROW" | jq -r '.gate_b | type')"  "string"

# --- The READER's str0 on skipped_reason, and the report-side tier guard ----------
# The report-side guard is reachable ONLY from a LEDGER row (live rows are coerced in
# DERIVE first), so it needs a seeded row — and a whitespace-bearing one, because the
# column read must not split on it.
use_wt feat/rdstr RS1; RS_MAIN="$WT_MAIN"; RS_WT="$WT_WT"
rm -rf "$RS_WT/.auto-task"
mkdir -p "$RS_MAIN/.auto-task/feat/rdgate"
cat > "$RS_MAIN/.auto-task/feat/rdgate/STATE.json" <<'EOF'
{"phase":"done","approved":true,"branch":"feat/rdgate","base":"RG1","pr_url":null,"description":"d",
 "effort":{"tier":"standard","history":[]},"iteration":{"review":1,"fix":1},
 "history":[{"phase":"handover","result":"done","at":"2026-01-01T10:30:00Z"}],
 "gates":{"gate_b":{"passed":false,"skipped_reason":{"o":"bj"}}},
 "quality":{"tests_added":true,"flaky":false,"defects":{"early":1,"late":0},
            "diff":{"loc_added":5,"loc_removed":1},"planning":{"first_pass_ac":1}},
 "followups":[]}
EOF
OUTRS="$(cd "$RS_MAIN" && CLAUDE_PROJECT_DIR="$RS_MAIN" bash "$STATS" 2>&1; echo "EXIT=$?")"
expect_has "reader str0: non-string skipped_reason does not break the report" "$OUTRS" "1 runs on record — 1 done"
expect_has "reader str0: reader exits 0"                                      "$OUTRS" "EXIT=0"
# Now a LEDGER row whose tier is a non-string CONTAINING A SPACE: the By-tier row must
# render with its columns intact, not shifted by whitespace splitting.
# TWO SEPARATE GUARDS need two separate fixtures, and the earlier single one pinned
# neither. (i) The report-side TYPE guard is only load-bearing for a tier that cannot be
# sliced — a NUMBER. An array is sliceable (`["a b"] | .[0:10]` is a legal array slice), so
# an array fixture makes removing the guard a no-op. (ii) The \037 column read is only
# load-bearing for a tier containing WHITESPACE. And the oracle must be anchored to the
# FRONT of the row: a whitespace split shifts fields in from the left, so a window measured
# from NF is identical either way and cannot fail.
rm -rf "$RS_MAIN/.auto-task/feat/rdgate"
# (i) a NUMBER tier — pins the type guard (without it the whole table renders empty).
printf '{"at":"2026-05-01T10:00:00Z","branch":"feat/nt","base":"NT9","plugin_version":"0.28.0","terminal_state":"done","tier":5,"gate_b":"passed","followups":0,"defects_late":0,"defects_early":1,"flaky":false,"tests_added":true,"escalations":0,"fix_iterations":3,"review_iterations":4,"checks_run":1,"checks_failed":0,"pr_url":null}\n' \
  > "$RS_MAIN/.auto-task/outcomes.jsonl"
OUTNT="$(cd "$RS_MAIN" && CLAUDE_PROJECT_DIR="$RS_MAIN" bash "$STATS" 2>&1)"
expect_has "report tier guard: a numeric tier still counts as a run" "$OUTNT" "1 runs on record — 1 done"
expect "report tier guard: a numeric tier still renders a By-tier ROW" \
  "$(printf '%s' "$OUTNT" | awk '/^By tier/{f=1;next} /^$/{f=0} f&&!/^  tier/{c++} END{print c+0}')" "1"
# (ii) a WHITESPACE-bearing tier — pins the \037 read. Oracle anchored to the FRONT.
printf '{"at":"2026-05-01T10:00:00Z","branch":"feat/lt","base":"LT1","plugin_version":"0.28.0","terminal_state":"done","tier":"std heavy","gate_b":"passed","followups":0,"defects_late":0,"defects_early":1,"flaky":false,"tests_added":true,"escalations":0,"fix_iterations":3,"review_iterations":4,"checks_run":1,"checks_failed":0,"pr_url":null}\n' \
  > "$RS_MAIN/.auto-task/outcomes.jsonl"
OUTLT="$(cd "$RS_MAIN" && CLAUDE_PROJECT_DIR="$RS_MAIN" bash "$STATS" 2>&1)"
expect_has "report tier guard: the By-tier row renders at all" "$OUTLT" "1 runs on record — 1 done"
LTROW="$(printf '%s' "$OUTLT" | awk '/^By tier/{f=1;next} /^$/{f=0} f&&!/^  tier/{print; exit}')"
# Fields 1..2 are the two words of the tier; a whitespace split makes field 3 the tier's
# second word instead of #done, so reading from the FRONT is what discriminates.
expect "column read: #done is #done, not a fragment of the tier" \
  "$(printf '%s' "$LTROW" | awk '{print $3, $4, $5}')" "1 3 4"

# --- median must not be poisoned by a string iteration count ---------------------
printf '{"at":"2026-05-01T10:00:00Z","branch":"feat/mn","base":"MN1","plugin_version":"0.28.0","terminal_state":"done","tier":"standard","gate_b":"passed","followups":0,"defects_late":0,"defects_early":1,"flaky":false,"tests_added":true,"escalations":0,"fix_iterations":"three","review_iterations":"four","checks_run":1,"checks_failed":0,"pr_url":null}\n' \
  > "$RS_MAIN/.auto-task/outcomes.jsonl"
OUTMN="$(cd "$RS_MAIN" && CLAUDE_PROJECT_DIR="$RS_MAIN" bash "$STATS" 2>&1)"
MNROW="$(printf '%s' "$OUTMN" | awk '/^By tier/{f=1;next} /^$/{f=0} f&&!/^  tier/{print; exit}')"
expect "median n0: a string iteration count reads as 0, not as the string" \
  "$(printf '%s' "$MNROW" | awk '{print $3, $4}')" "0 0"

# --- A string defect/escalation count must not be counted as a defect ------------
# `"none" > 0` is TRUE in jq, so a bare `> 0` predicate reported a malformed legacy row
# as a real defect — a plausible false number in the headline metric, which is harder to
# notice than a blank.
{ printf '{"at":"2026-05-01T10:00:00Z","branch":"feat/p1","base":"P1","plugin_version":"0.28.0","terminal_state":"done","tier":"standard","gate_b":"passed","followups":0,"defects_late":0,"defects_early":1,"flaky":false,"tests_added":true,"escalations":0,"fix_iterations":1,"review_iterations":1,"checks_run":1,"checks_failed":0,"pr_url":null}\n'
  printf '{"at":"2026-05-02T10:00:00Z","branch":"feat/p2","base":"P2","plugin_version":"0.28.0","terminal_state":"done","tier":"standard","gate_b":"passed","followups":0,"defects_late":"none","defects_early":1,"flaky":false,"tests_added":true,"escalations":"none","fix_iterations":1,"review_iterations":1,"checks_run":1,"checks_failed":0,"pr_url":null}\n'; } \
  > "$RS_MAIN/.auto-task/outcomes.jsonl"
OUTPOS="$(cd "$RS_MAIN" && CLAUDE_PROJECT_DIR="$RS_MAIN" bash "$STATS" 2>&1)"
expect_has "pos predicate: both rows counted"                    "$OUTPOS" "2 runs on record — 2 done"
expect_has "pos predicate: a string defect count is NOT a defect" "$OUTPOS" "Late-defect rate       0%"
expect_has "pos predicate: a string escalation is NOT an escalation" "$OUTPOS" "Effort mis-scoring     0%"
# `pos` is applied at FOUR sites and the pooled fixture above only reaches two. The other
# two are the PER-VERSION late rate (which feeds regression.flags, so a malformed row there
# fabricates a regression alarm — worse than a wrong headline) and the By-tier `escalated`
# column. Both need ≥2 versions × ≥10 rows to become visible, so build that population.
POSV="$RS_MAIN/.auto-task/outcomes.jsonl"; : > "$POSV"
emit_pos(){ # emit_pos <version> <n> <defects_late literal> <escalations literal>
  local v="$1" n="$2" dl="$3" es="$4" i=1
  while [ "$i" -le "$n" ]; do
    printf '{"at":"2026-05-01T10:00:00Z","branch":"feat/%s-%s","base":"%s%s","plugin_version":"%s","terminal_state":"done","tier":"standard","gate_b":"passed","followups":0,"defects_late":%s,"defects_early":1,"flaky":false,"tests_added":true,"escalations":%s,"fix_iterations":1,"review_iterations":1,"checks_run":1,"checks_failed":0,"pr_url":null}\n' \
      "$v" "$i" "$v" "$i" "$v" "$dl" "$es" >> "$POSV"
    i=$((i + 1))
  done
}
# Both versions are genuinely defect-free and escalation-free, but v2's values are STRINGS.
emit_pos 1.0.0 12 0 0
emit_pos 2.0.0 12 '"none"' '"none"'
OUTPV="$(cd "$RS_MAIN" && CLAUDE_PROJECT_DIR="$RS_MAIN" bash "$STATS" 2>&1)"
expect_has "pos per-version: all 24 rows counted" "$OUTPV" "24 runs on record — 24 done"
# A bare `> 0` counts every v2 row as a defect (0% -> 100%), which the regression guard
# then reports as a real jump. With `pos` there is nothing to flag.
if printf '%s' "$OUTPV" | grep -qE 'late-defect rate.*→|late-defect rate.*->'; then
  FAIL=$((FAIL+1)); printf '  FAIL  %-56s (fabricated a regression from a string field)\n' "pos per-version: no fabricated regression flag"
else
  PASS=$((PASS+1)); printf '  PASS  %-56s (found)\n' "pos per-version: no fabricated regression flag"
fi
expect "pos per-version: the By-tier escalated column is 0%" \
  "$(printf '%s' "$OUTPV" | awk '/^By tier/{f=1;next} /^$/{f=0} f&&/^  standard/{print $NF; exit}')" "0%"

# --- A STATE.json parked below the branch folder is not a phantom run ------------
# A snapshot under <branch>/artifacts/ must not count as a second completed run (branch+base
# dedup cannot help, since its identity differs). It is excluded by the BRANCH-VS-PATH check:
# the snapshot declares the real branch but does not live at that branch's own folder. There
# is no depth cap and no path filter — both were tried and both were wrong (a cap dropped
# real runs on multi-segment branches; a `! -path` exclusion dropped every run in a clone
# living under a dir named artifacts/recon/fixes).
use_wt feat/depth DP1; DP_MAIN="$WT_MAIN"; DP_WT="$WT_WT"
mkdir -p "$DP_WT/.auto-task/feat/depth/artifacts/snapshot"
sed 's/"base":"DP1"/"base":"DP2"/; s|"branch":"feat/depth"|"branch":"feat/snap"|' \
  "$DP_WT/.auto-task/feat/depth/STATE.json" > "$DP_WT/.auto-task/feat/depth/artifacts/snapshot/STATE.json"
OUTDP="$(cd "$DP_MAIN" && CLAUDE_PROJECT_DIR="$DP_MAIN" bash "$STATS" 2>&1)"
expect_has "sub-folder filter: the artifact snapshot is not a phantom run" "$OUTDP" "1 runs on record — 1 done"
# recon/ and fixes/ are NOT special-cased anywhere — they are excluded for exactly the same
# reason as any other sub-folder: their path is below the branch's own folder.
mkdir -p "$DP_WT/.auto-task/feat/depth/recon" "$DP_WT/.auto-task/feat/depth/fixes"
sed 's/"base":"DP1"/"base":"DP3"/' "$DP_WT/.auto-task/feat/depth/STATE.json" > "$DP_WT/.auto-task/feat/depth/recon/STATE.json"
sed 's/"base":"DP1"/"base":"DP4"/' "$DP_WT/.auto-task/feat/depth/STATE.json" > "$DP_WT/.auto-task/feat/depth/fixes/STATE.json"
OUTDP2="$(cd "$DP_MAIN" && CLAUDE_PROJECT_DIR="$DP_MAIN" bash "$STATS" 2>&1)"
expect_has "sub-folder filter: recon/ and fixes/ snapshots excluded too" "$OUTDP2" "1 runs on record — 1 done"
# THE OTHER HALF, and the reason the discriminator is branch-vs-path rather than anything
# positional: a branch name carries its slashes into the path, so a three-segment branch sits
# deeper than a two-segment one. Any depth cap tight enough to exclude <branch>/artifacts/
# also drops these real runs.
use_wt feat/deep DEEP1; DE_MAIN="$WT_MAIN"; DE_WT="$WT_WT"
rm -rf "$DE_WT/.auto-task/feat/deep"
for b in "feature/JIRA-123/foo" "a/b/c/d"; do
  mkdir -p "$DE_WT/.auto-task/$b"
  cat > "$DE_WT/.auto-task/$b/STATE.json" <<EOF
{"phase":"done","approved":true,"branch":"$b","base":"$(printf '%s' "$b" | tr -d '/-')","pr_url":null,"description":"d",
 "effort":{"tier":"light","history":[]},"iteration":{"review":0,"fix":0},
 "history":[{"phase":"handover","result":"done","at":"2026-01-01T10:30:00Z"}],
 "gates":{"gate_b":{"skipped_reason":"tier=light"}},"followups":[]}
EOF
done
OUTDE="$(cd "$DE_MAIN" && CLAUDE_PROJECT_DIR="$DE_MAIN" bash "$STATS" 2>&1)"
expect_has "deep branch names: 3- and 4-segment branches are still counted" \
  "$OUTDE" "2 runs on record — 2 done"

# --- A branch NAMED like a sub-folder must still be counted ----------------------
# The mirror image of the depth-cap bug, and the reason the discriminator is
# branch-vs-path rather than a path exclusion: `! -path '*/artifacts/*'` matches the WHOLE
# absolute path, so it dropped a branch literally named `fixes/typo` — and, far worse,
# every run in any clone that merely LIVES under a directory called artifacts/recon/fixes.
for _b in fixes/typo feat/artifacts recon/notes; do
  use_wt "chore/seg-$(printf '%s' "$_b" | tr '/' '-')" "SEG1"; SG_MAIN="$WT_MAIN"; SG_WT="$WT_WT"
  rm -rf "$SG_WT/.auto-task"
  mkdir -p "$SG_MAIN/.auto-task/$_b"
  cat > "$SG_MAIN/.auto-task/$_b/STATE.json" <<EOF
{"phase":"done","approved":true,"branch":"$_b","base":"SEGB","pr_url":null,"description":"d",
 "effort":{"tier":"light","history":[]},"iteration":{"review":0,"fix":0},
 "history":[{"phase":"handover","result":"done","at":"2026-01-01T10:30:00Z"}],
 "gates":{"gate_b":{"skipped_reason":"tier=light"}},"followups":[]}
EOF
  OUTSG2="$(cd "$SG_MAIN" && CLAUDE_PROJECT_DIR="$SG_MAIN" bash "$STATS" 2>&1)"
  expect_has "branch named '$_b' is still counted" "$OUTSG2" "1 runs on record — 1 done"
done
# And the severe shape: a CLONE whose own path contains such a segment.
CLOC="$(cd "$(mktemp -d)" && pwd -P)/fixes"; wt_track "$(dirname "$CLOC")"
mkdir -p "$CLOC/repo/.auto-task/feat/widget"
( cd "$CLOC/repo" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
cat > "$CLOC/repo/.auto-task/feat/widget/STATE.json" <<'EOF'
{"phase":"done","approved":true,"branch":"feat/widget","base":"CLW1","pr_url":null,"description":"d",
 "effort":{"tier":"light","history":[]},"iteration":{"review":0,"fix":0},
 "history":[{"phase":"handover","result":"done","at":"2026-01-01T10:30:00Z"}],
 "gates":{"gate_b":{"skipped_reason":"tier=light"}},"followups":[]}
EOF
OUTCL="$(cd "$CLOC/repo" && CLAUDE_PROJECT_DIR="$CLOC/repo" bash "$STATS" 2>&1)"
expect_has "a clone living under a dir named 'fixes' still sees its runs" \
  "$OUTCL" "1 runs on record — 1 done"

# --- A snapshot is skipped QUIETLY; a genuine mismatch is skipped LOUDLY ----------
# Both fail the branch-vs-path check, but they mean different things. A file under the
# run's OWN folder is an expected copy — reporting it would be noise. A file whose location
# is unrelated to the branch it declares (a renamed folder, a hand-moved file, a corrupt
# .branch) may well be a real completed run, so it must be counted and named rather than
# vanishing — the same promise skipped_live makes for unreadable and underivable files.
use_wt chore/mismatch MM1; MM_MAIN="$WT_MAIN"; MM_WT="$WT_WT"
rm -rf "$MM_WT/.auto-task"
mkdir -p "$MM_MAIN/.auto-task/feat/real/artifacts/snap"
cat > "$MM_MAIN/.auto-task/feat/real/STATE.json" <<'EOF'
{"phase":"done","approved":true,"branch":"feat/real","base":"MMR1","pr_url":null,"description":"d",
 "effort":{"tier":"light","history":[]},"iteration":{"review":0,"fix":0},
 "history":[{"phase":"handover","result":"done","at":"2026-01-01T10:30:00Z"}],
 "gates":{"gate_b":{"skipped_reason":"tier=light"}},"followups":[]}
EOF
sed 's/"base":"MMR1"/"base":"MMR2"/' "$MM_MAIN/.auto-task/feat/real/STATE.json" \
  > "$MM_MAIN/.auto-task/feat/real/artifacts/snap/STATE.json"
OUTMM1="$(cd "$MM_MAIN" && CLAUDE_PROJECT_DIR="$MM_MAIN" bash "$STATS" 2>&1)"
expect_has "snapshot: the real run is counted once"  "$OUTMM1" "1 runs on record — 1 done"
expect "snapshot: skipped QUIETLY (no skip notice)" \
  "$(printf '%s' "$OUTMM1" | grep -c 'live STATE.json file(s) skipped')" "0"
# Now a genuine mismatch: the folder says old/name, the file declares new/name.
rm -rf "$MM_MAIN/.auto-task/feat/real"
mkdir -p "$MM_MAIN/.auto-task/old/name"
cat > "$MM_MAIN/.auto-task/old/name/STATE.json" <<'EOF'
{"phase":"done","approved":true,"branch":"new/name","base":"MMX1","pr_url":null,"description":"d",
 "effort":{"tier":"light","history":[]},"iteration":{"review":0,"fix":0},
 "history":[{"phase":"handover","result":"done","at":"2026-01-01T10:30:00Z"}],
 "gates":{"gate_b":{"skipped_reason":"tier=light"}},"followups":[]}
EOF
OUTMM2="$(cd "$MM_MAIN" && CLAUDE_PROJECT_DIR="$MM_MAIN" bash "$STATS" 2>&1)"
expect_has "mismatch: skipped LOUDLY (reported)" "$OUTMM2" "live STATE.json file(s) skipped"
expect "mismatch: the file is named"             "$(printf '%s' "$OUTMM2" | grep -c 'old/name/STATE.json')" "1"
# The notice must not assert a cause that is FALSE for this class. A mismatched file is
# perfectly readable and derivable; telling the maintainer it is "unreadable or underivable"
# sends them looking for corruption that is not there.
expect_has "mismatch: the notice admits the location cause" "$OUTMM2" "not where their branch says"

# --- A case-differing branch folder must still be counted -------------------------
# On a case-INSENSITIVE filesystem (macOS APFS by default, Windows) git can hand out
# `Feat/b` while the directory on disk is `feat/b`, so a byte compare of the ref name
# against the path component fails and DROPS a completed run — a regression against base,
# which counted it. The check therefore compares file IDENTITY (device+inode), which the
# filesystem's own canonicalization satisfies. Skipped where the filesystem is
# case-sensitive, since the scenario cannot be constructed there.
CIP="$(cd "$(mktemp -d)" && pwd -P)"; wt_track "$CIP"
: > "$CIP/casetest"
if [ -e "$CIP/CASETEST" ]; then
  mkdir -p "$CIP/repo/.auto-task/feat/a"
  ( cd "$CIP/repo" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  mk_case(){ mkdir -p "$CIP/repo/.auto-task/$1"; cat > "$CIP/repo/.auto-task/$1/STATE.json" <<EOF
{"phase":"done","approved":true,"branch":"$2","base":"$3","pr_url":null,"description":"d",
 "effort":{"tier":"light","history":[]},"iteration":{"review":0,"fix":0},
 "history":[{"phase":"handover","result":"done","at":"2026-01-01T10:30:00Z"}],
 "gates":{"gate_b":{"skipped_reason":"tier=light"}},"followups":[]}
EOF
  }
  mk_case "feat/a" "feat/a" "CA1"
  # `Feat/b` beside an existing `feat/` lands on disk as `feat/b`, but declares `Feat/b`.
  mk_case "Feat/b" "Feat/b" "CB1"
  OUTCI="$(cd "$CIP/repo" && CLAUDE_PROJECT_DIR="$CIP/repo" bash "$STATS" 2>&1)"
  expect_has "case-folded branch folder: BOTH runs counted" "$OUTCI" "2 runs on record — 2 done"
  expect "case-folded branch folder: no false skip notice" \
    "$(printf '%s' "$OUTCI" | grep -c 'live STATE.json file(s) skipped')" "0"
else
  PASS=$((PASS+2)); printf '  PASS  %-56s (skipped: case-sensitive filesystem)\n' "case-folded branch folder"
fi

# --- A scalar (non-object) ledger line must be reported, not counted as a run ----
# `jq -s length == 1` alone admits `123`/`null`/`[]`, which would then be counted as a
# done run and kill the aggregation on the first `.plugin_version` lookup.
use_wt feat/scalar SCAL1; SMAIN2="$WT_MAIN"; SWT2="$WT_WT"
rm -rf "$SWT2/.auto-task"
mkdir -p "$SMAIN2/.auto-task"
{ printf '{"at":"2026-05-01T10:00:00Z","branch":"feat/ok2","base":"OK2","plugin_version":"0.28.0","terminal_state":"done","tier":"light","gate_b":"passed","followups":0,"defects_late":0,"defects_early":0,"flaky":false,"tests_added":true,"duration_min":10,"fix_iterations":0,"review_iterations":0,"escalations":0,"checks_run":1,"checks_failed":0,"pr_url":null}\n'
  printf '123\n'; } > "$SMAIN2/.auto-task/outcomes.jsonl"
OUTSC="$(cd "$SMAIN2" && CLAUDE_PROJECT_DIR="$SMAIN2" bash "$STATS" 2>&1; echo "EXIT=$?")"
expect_has "scalar ledger line: exits 0"                  "$OUTSC" "EXIT=0"
expect_has "scalar ledger line: reported as unparseable"  "$OUTSC" "1 unparseable ledger row(s) skipped"
expect_has "scalar ledger line: only the real run counted" "$OUTSC" "1 runs on record — 1 done"

# --- A live done STATE.json whose derivation fails is reported, not silent -------
# Claiming the dedup key before deriving used to lose the run AND suppress a good copy
# of it at another root. The trigger is a structurally-wrong `history` (a string where
# an array belongs), which breaks the derivation outright — deliberately NOT a
# non-numeric arithmetic field, because those are now coerced at the source and no
# longer fail (verified: a string `loc_added` derives fine and the run is counted).
use_wt feat/badtype BT1; TMAIN2="$WT_MAIN"; TWT2="$WT_WT"
# Drop mkwt's own run so the tally isolates exactly the identity under test: one run
# (feat/bad / BAD1) sighted twice — broken at main, well-formed in the worktree.
rm -rf "$TWT2/.auto-task/feat/badtype"
mkdir -p "$TMAIN2/.auto-task/feat/bad" "$TWT2/.auto-task/feat/bad"
cat > "$TMAIN2/.auto-task/feat/bad/STATE.json" <<'EOF'
{"phase":"done","approved":true,"branch":"feat/bad","base":"BAD1","pr_url":null,"description":"d",
 "effort":{"tier":"light","history":[]},"iteration":{"review":0,"fix":0},
 "history":"this should be an array",
 "gates":{"gate_b":{"skipped_reason":"tier=light"}},"followups":[]}
EOF
mk_done_row "$TWT2/.auto-task/feat/bad" feat/bad BAD1 '1'   # well-formed copy, same identity
OUTBT="$(cd "$TMAIN2" && CLAUDE_PROJECT_DIR="$TMAIN2" bash "$STATS" 2>&1)"
expect_has "bad-typed live row: the good copy is still counted" "$OUTBT" "1 runs on record — 1 done"
expect_has "bad-typed live row: the failure is reported"        "$OUTBT" "live STATE.json file(s) skipped"

# --- AC8: fail-open when the shared lib is unavailable ------------------------
# Degrades to the pre-change per-tree behavior rather than erroring.
NOLIB="$(mktemp -d)"; wt_track "$NOLIB"
cp -R "$HOOKS" "$NOLIB/hooks"
rm -f "$NOLIB/hooks/lib/clone-scope.sh"
NLP="$NOLIB/proj"; mkdir -p "$NLP"
( cd "$NLP" && git init -q && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init && git checkout -q -b feat/nolib )
mkdir -p "$NLP/.auto-task/feat/nolib"
cat > "$NLP/.auto-task/feat/nolib/STATE.json" <<'EOF'
{"phase":"done","approved":true,"branch":"feat/nolib","base":"NOLIB1","pr_url":null,
 "description":"lib-absent fallback","effort":{"tier":"light","history":[]},
 "iteration":{"review":0,"fix":0},
 "history":[{"phase":"handover","result":"done","at":"2026-01-01T10:30:00Z"}],
 "gates":{"gate_b":{"skipped_reason":"tier=light"}},"followups":[]}
EOF
mkdir -p "$NLP/.auto-task"; : > "$NLP/.auto-task/outcomes.jsonl"
expect "no-lib: hook exits 0" \
  "$(printf '{"cwd":"%s"}' "$NLP" | CLAUDE_PROJECT_DIR="$NLP" bash "$NOLIB/hooks/record-outcome.sh"; echo $?)" "0"
expect "no-lib: same-tree row still recorded"  "$(rows "$NLP")" "1"
expect "no-lib: nothing on stdout" \
  "$(printf '{"cwd":"%s"}' "$NLP" | CLAUDE_PROJECT_DIR="$NLP" bash "$NOLIB/hooks/record-outcome.sh" 2>/dev/null | wc -c | tr -d ' ')" "0"
expect "no-lib: reader still reports" \
  "$(cd "$NLP" && CLAUDE_PROJECT_DIR="$NLP" bash "$NOLIB/hooks/auto-task-stats.sh" 2>&1 | grep -c '1 runs on record')" "1"

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
