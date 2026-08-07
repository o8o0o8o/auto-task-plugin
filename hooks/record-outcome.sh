#!/usr/bin/env bash
# Records a one-line run-outcome row when an auto-task run reaches phase=="done".
#
# Registered as a Stop hook (alongside prevent-mid-protocol-stall.sh). This is
# PURE TELEMETRY — it never blocks a turn-end and never influences the pipeline.
# It exists so maintainers can measure completion rate and find where runs stall
# (via the auto-task-stats reader), preserving a record even after a per-branch
# .auto-task/<branch>/ folder is pruned.
#
# OPT-IN: the hook is a no-op unless the append-only ledger already exists. Opt in
# with `touch .auto-task/outcomes.jsonl` at the repo root; opt out by deleting it.
# No network, no data leaves the machine — the row is derived from fields already
# present locally in STATE.json.
#
# CLONE-WIDE LEDGER, not per-worktree. The ledger path is resolved through
# hooks/lib/clone-scope.sh to the MAIN working tree, NOT to `$project_dir` — which
# is retargeted below to whichever linked worktree the turn-end ran in. Those are
# deliberately different roots, and conflating them was a real bug: because
# auto-task isolates every run in its own worktree, `$project_dir/.auto-task/
# outcomes.jsonl` named a file a fresh worktree never has, so the opt-in gate
# failed closed and NOTHING was ever recorded — while the `auto-task-stats` reader
# looked at the main tree. Per-run state (STATE.json, the run clock, the sentinel
# below) stays per-worktree; only the cross-run ledger is clone-wide, because
# surviving individual branch folders is its entire purpose.
#
# Failure policy: FAIL OPEN, ALWAYS. Every path exits 0. Telemetry must never
# break a session: a missing jq, an unreadable state file, a write error — all
# silently skip. `set -e` is intentionally omitted so a stray non-zero can't
# abort the script before its final `exit 0`.
#
# Write-once per RUN (not per branch): the sentinel .auto-task/<branch>/.outcome-recorded
# stores the run's base SHA. A completion is skipped only when the sentinel's
# content equals the current state.base — so a fresh run that reuses a branch
# folder (new base) is still recorded, mirroring prevent-mid-protocol-stall.sh's
# base-in-signature run-scoping of .stall-block-count.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# --- Resolve the project root that owns .auto-task/<branch>/ ------------------
# Mirror prevent-mid-protocol-stall.sh: start from CLAUDE_PROJECT_DIR (or $PWD),
# resolve to the git toplevel, then retarget to a same-repo linked worktree when
# the turn-end actually ran in one (shared git-common-dir, different toplevel;
# common-dirs normalised via cd-into + `pwd -P`). Nested/embedded repos have
# their own common-dir and are left alone.
project_dir_base="${CLAUDE_PROJECT_DIR:-$PWD}"
project_dir="$(cd "$project_dir_base" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$project_dir" ] || project_dir="$project_dir_base"

_input=""
[ -t 0 ] || _input="$(cat 2>/dev/null || true)"
op_cwd=""
if [ -n "$_input" ] && command -v jq >/dev/null 2>&1; then
  op_cwd="$(printf '%s' "$_input" | jq -r '.cwd // ""' 2>/dev/null || true)"
fi
[ -n "$op_cwd" ] || op_cwd="$PWD"
if [ -d "$op_cwd" ]; then
  cwd_top="$(cd "$op_cwd" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$cwd_top" ] && [ "$cwd_top" != "$project_dir" ]; then
    cwd_common="$(cd "$op_cwd" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)" 2>/dev/null && pwd -P || true)"
    base_common="$(cd "$project_dir" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)" 2>/dev/null && pwd -P || true)"
    if [ -n "$cwd_common" ] && [ "$cwd_common" = "$base_common" ]; then
      project_dir="$cwd_top"
    fi
  fi
fi

branch="$(cd "$project_dir" && git branch --show-current 2>/dev/null || true)"
[ -n "$branch" ] || exit 0   # not a repo / detached HEAD → nothing to record

state="$project_dir/.auto-task/$branch/STATE.json"
[ -f "$state" ] || exit 0    # no run for this branch

# --- OPT-IN gate: the ledger must already exist -------------------------------
# Resolved CLONE-WIDE (main working tree), not from the worktree-retargeted
# $project_dir — see the header. Fail open: if the helper cannot be sourced or
# cannot resolve a main worktree (no git, bare repo, not a repo), fall back to the
# pre-existing per-tree path so this hook behaves exactly as it did before.
ledger=""
if [ -f "$SCRIPT_DIR/lib/clone-scope.sh" ]; then
  # shellcheck source=lib/clone-scope.sh
  if . "$SCRIPT_DIR/lib/clone-scope.sh" 2>/dev/null && command -v cs_ledger_path >/dev/null 2>&1; then
    ledger="$(cs_ledger_path "$project_dir" 2>/dev/null || true)"
  fi
fi
[ -n "$ledger" ] || ledger="$project_dir/.auto-task/outcomes.jsonl"
[ -f "$ledger" ] || exit 0   # not opted in → silent no-op

# --- jq required (fail open) --------------------------------------------------
command -v jq >/dev/null 2>&1 || exit 0
jq empty "$state" 2>/dev/null || exit 0   # unparseable state → skip

# --- Only record terminal runs ------------------------------------------------
phase="$(jq -r '.phase // ""' "$state" 2>/dev/null || echo "")"
[ "$phase" = "done" ] || exit 0

# --- Run-scoped write-once via base-keyed sentinel ----------------------------
base="$(jq -r '.base // ""' "$state" 2>/dev/null || echo "")"
sentinel="$project_dir/.auto-task/$branch/.outcome-recorded"
if [ -f "$sentinel" ]; then
  prev="$(cat "$sentinel" 2>/dev/null || echo "")"
  if [ -n "$base" ]; then
    # Run-scoped: skip only if THIS run (same base) was already recorded. A
    # reused branch folder on a fresh run has a new base → recorded again.
    [ "$prev" = "$base" ] && exit 0
  else
    # Degenerate/legacy state with no base to scope by: fall back to
    # presence-based dedup (the sentinel exists ⇒ this done-run was already
    # recorded). Without this, an empty base makes the match above always
    # false, so every turn-end after `done` would append a duplicate row.
    exit 0
  fi
fi

# --- Resolve plugin version (never empty) -------------------------------------
# plugin_version is NOT a STATE field — it lives in the plugin manifest. Resolved
# via CLAUDE_PLUGIN_ROOT (exported into hooks) or relative to this script, else
# "unknown". Recorded on the local row so auto-task-stats can group runs by plugin
# version (the version-over-version regression guard). Mirrors the same probe in
# send-telemetry.sh. Historical rows written before this field simply lack it and
# the reader buckets them as "unknown" (excluded from version-pair comparisons).
plugin_version=""
if [ -f "$SCRIPT_DIR/hooks.json" ]; then
  plugin_version="$(jq -r '.version // empty' "$SCRIPT_DIR/hooks.json" 2>/dev/null || echo "")"
fi
if [ -z "$plugin_version" ]; then
  for mf in "${CLAUDE_PLUGIN_ROOT:-}/.claude-plugin/plugin.json" "$SCRIPT_DIR/../.claude-plugin/plugin.json"; do
    [ -n "$mf" ] && [ -f "$mf" ] || continue
    plugin_version="$(jq -r '(.plugins[0].version // .version) // empty' "$mf" 2>/dev/null || echo "")"
    [ -n "$plugin_version" ] && break
  done
fi
[ -n "$plugin_version" ] || plugin_version="unknown"

# --- Resolve the MEASURED run duration ----------------------------------------
# The duration used to come from the first and last `state.history[].at` strings,
# which the model writes without access to a clock — a narrated number, not a
# measured one. It now comes from the hook-stamped run clock
# (.auto-task/<branch>/.run-clock.json, written by stamp-run-clock.sh from
# `date -u`), with the history formula kept ONLY as the fallback for a run that
# has no clock (a legacy or in-flight run).
#
# THREE STATES, not two — and this is load-bearing. jq's `//` treats `null`
# exactly like absent, so a duration deliberately REJECTED to `null` by the
# sanity assertion would fall straight through `(.actuals.duration_min // $dur)`
# to the history-derived number, fabricating the very value the assertion exists
# to forbid. So the verdict is passed as a VALUE plus a STATE, and the jq below
# branches on the state:
#   ok       -> the clock value wins
#   rejected -> null, and NEVER the history fallback
#   absent   -> the pre-existing history formula, unchanged
# The definition (including the negative / >12h bounds) lives in
# hooks/lib/run-clock.sh so all three DERIVE sites cannot drift apart.
#
# Fail-open: if the helper cannot be sourced, the state stays `absent` and this
# hook behaves exactly as it did before the run clock existed.
#
# STAMP BEFORE READING — do not rely on the `Stop` stamper having run first. Hooks
# for one event execute in PARALLEL, so registration order is not an
# execution-order contract: a reader that only read could race the stamper's write
# and record a row whose `updated_at` predates the final (and typically longest)
# turn, which the write-once sentinel above would then make permanent. `rc_stamp`
# is idempotent, seals a `done` run, and refuses to start a clock for a run that
# was already over — so calling it here is safe and makes the guarantee local
# instead of assumed.
clock_state="absent"; clock_dur="null"
if [ -f "$SCRIPT_DIR/lib/run-clock.sh" ]; then
  # shellcheck source=lib/run-clock.sh
  if . "$SCRIPT_DIR/lib/run-clock.sh" 2>/dev/null && command -v rc_duration_min >/dev/null 2>&1; then
    _rc_clock="$(rc_clock_path "$state")"
    rc_stamp "$_rc_clock" "$state" 2>/dev/null || true
    _rc_verdict="$(rc_duration_min "$_rc_clock" "$state" 2>/dev/null || echo absent)"
    clock_state="$(rc_verdict_state "$_rc_verdict")"
    clock_dur="$(rc_verdict_value "$_rc_verdict")"
  fi
fi

# --- Derive the one-line row from STATE.json ----------------------------------
# Every field guarded with a default so a partial/legacy state never errors.
# Free-text fields are length-capped (task ~140, gate_b ~120). The row now also
# carries run metrics (estimate/actual time+tokens, quality-signal trend fields)
# and runs ~800-1000B, past the 512B PIPE_BUF size where a single write is
# comfortably indivisible.
#
# CONCURRENCY — the ledger is CLONE-WIDE, so it has multiple writers. The older
# note here reasoned that "a completing run is effectively single-writer per
# working tree"; that held only while the ledger was per-worktree. Two runs in two
# worktrees of one clone can now finish at the same instant and append to the SAME
# file. The append below is therefore guarded three ways (see the append section).
# The metric fields mirror auto-task-stats.sh's DERIVE VERBATIM (lockstep — a
# regression test asserts the two field sets match). est_*/act_* are `null` when
# unmeasured so the reader's ratio can exclude them (no divide-by-zero / poison).
#
# TOKEN FIELDS — three, with distinct roles. `est_tokens` is the estimate's
# predicted OUTPUT tokens (estimate.sh emits only that; see its header for why a
# cache-inclusive total cannot be estimated). `act_tokens_output` is the measured
# output — the ONLY actual that is comparable to `est_tokens`, and the numerator
# of the reader's est/act ratio. `act_tokens` is the measured grand total
# (input+output+cache_read+cache_creation); it is recorded because it is a real
# measurement, but it is cache_read-dominated (107M-486M against ~500k of output
# on real runs) and is therefore never compared against an estimate.
#
# `est_tokens_scale` records WHICH scale `est_tokens` is on ("output" post-change,
# "total" for a run whose STATE.json predates it, null when unestimable). The
# reader needs it because a row written by THIS builder always carries
# `act_tokens_output`, so field-absence alone cannot distinguish a run that
# started before the upgrade and completed after it from a current one — only the
# marker can. Field-absence still identifies rows written by the OLD builder,
# which predate the marker; the reader checks both.
row="$(jq -c \
  --arg plugin_version "$plugin_version" \
  --argjson clock_dur "$clock_dur" \
  --arg clock_state "$clock_state" \
  '
  # NUMERIC COERCION AT THE SOURCE. Every field below that a consumer does arithmetic
  # on is read through num0/numN, because these all come from model-written STATE.json
  # and any of them can legitimately hold a string or a boolean. Two properties of jq
  # make an untyped read dangerous rather than merely wrong: `add` and `/` are FATAL on
  # a mixed type, and a bare `> 0` guard does NOT filter strings out (jq sorts strings
  # after numbers, so "40" > 0 is true) — so a positivity guard passes the bad value
  # straight into the division. A fatal error in the aggregator blanks EVERY metric
  # section of the report instead of one field, which is how a non-numeric
  # first_pass_ac silently emptied a real 9-run report.
  def num0: if type == "number" then . else 0 end;
  def numN: if type == "number" then . else null end;
  # Same discipline for the STRING fields, and for the same reason: a `.[0:N]`
  # slice is just as fatal on a wrong type as `add` is, and it lives outside both
  # numeric guard layers. A numeric `effort.tier` made the whole By-tier table
  # render as headers with no rows, losing the well-formed rows too, with no skip
  # counter touched — the failure was invisible on screen.
  def str0: if type == "string" then . else "" end;
  (.history // []) as $h
  | ($h | map(.at // empty)) as $ats
  | ($ats | first) as $t0
  | ($ats | last) as $t1
  | (if ($t0 != null and $t1 != null)
       then (((($t1 | fromdateiso8601?) // 0) - (($t0 | fromdateiso8601?) // 0)) / 60 | floor)
       else 0 end) as $hdur
  | (if $clock_state == "ok" then $clock_dur
     elif $clock_state == "rejected" then null
     else $hdur end) as $dur
  | (if $clock_state == "absent" then ((.actuals.duration_min | numN) // $dur) else $dur end) as $adur
  | {
      at: ($t1 // ""),
      branch: (.branch // ""),
      base: (.base // ""),
      pr_url: (.pr_url // null),
      task: ((.description | str0) | .[0:140]),
      terminal_state: "done",
      plugin_version: $plugin_version,
      tier: (.effort.tier | str0),
      tier_initial: ((((.effort.history // []) | first | .from) | str0) as $f
                     | if $f == "" then (.effort.tier | str0) else $f end),
      escalations: ((.effort.history // []) | length),
      fix_iterations: (.iteration.fix | num0),
      review_iterations: (.iteration.review | num0),
      # ROUNDS vs ITERATIONS -- they are different quantities and both are needed to
      # read the review loop. `review_iterations` counts only rounds that REOPENED
      # (the graded-loop narrowing); `review_rounds` counts every round the reviewer
      # ran, reopening or not. Comparing them is what distinguishes "the review keeps
      # finding real breaches" from "the review keeps running and finding nothing".
      #
      # THE DISCRIMINATOR IS THE `rounds` KEY, NOT `gates.code_review`, and the
      # difference is the whole point of the column. `0` must mean "this run ran zero
      # review rounds" -- a measurement -- while `null` means the state cannot say,
      # so the aggregator can EXCLUDE the second rather than average it in.
      # A `// [] | length` would collapse the two: every STATE.json written before
      # `rounds[]` existed (0.30.0) reports a hard 0, and those states are still on
      # disk and still get derived live by auto-task-stats.sh. That fabricates a
      # review-volume drop precisely during the transition the null-exclusion exists
      # for. The state skeleton initializes `rounds: []`, so a post-0.30.0 run that
      # never reached Phase 4 still HAS the key and correctly reads 0; only a state
      # that lacks it is unmeasurable. `num0` guards the array-length arithmetic; the
      # null branch bypasses it deliberately.
      review_rounds: (if (.gates.code_review | type) == "object"
                         and (.gates.code_review | has("rounds"))
                      then ((.gates.code_review.rounds // []) | length | num0)
                      else null end),
      gate_b: (if (.gates.gate_b.passed // false) then "passed"
               else ((.gates.gate_b.skipped_reason | str0) | .[0:120]) end),
      followups: ((.followups // []) | length),
      duration_min: $dur,
      est_duration_min: (.estimate.duration_min | numN),
      est_tokens: (.estimate.tokens_output | numN),
      est_tokens_scale: (if ((.estimate.tokens_output | numN) != null) then "output"
                         elif ((.estimate.tokens_total | numN) != null) then "total"
                         else null end),
      act_duration_min: $adur,
      act_tokens: (.actuals.tokens_total | numN),
      act_tokens_output: (.actuals.tokens_breakdown.output | numN),
      defects_early: (.quality.defects.early | num0),
      defects_late: (.quality.defects.late | num0),
      flaky: (.quality.flaky // false),
      tests_added: (.quality.tests_added // false),
      diff_loc: (((.quality.diff.loc_added | num0) + (.quality.diff.loc_removed | num0))),
      # NUMBER-ONLY. `quality.planning.first_pass_ac` is model-written and is, in real
      # state files, freely a string ("6/6 self-verify ACs green") or a boolean. The
      # aggregator sums this field, and jq cannot add a number to a string — that is a
      # FATAL error in the single agg pass, which blanks EVERY metric section of the
      # report rather than printing one wrong number. Coercing here keeps the bad value
      # out of the row entirely; the aggregator additionally re-filters, because rows
      # already appended to an append-only ledger cannot be fixed retroactively.
      first_pass_ac: (if ((.quality.planning.first_pass_ac | type) == "number")
                      then .quality.planning.first_pass_ac else null end),
      checks_run: ((.checks // []) | length),
      checks_failed: ((.checks // []) | map(select(.result=="fail")) | length),
      external_status: (.external.status // null),
      autonomy: (.settings.resolved.autonomy // null),
      landing_model: (.settings.resolved.landing_model // null),
      merge_gate_required: (.gates.merge.required // false),
      merge_gate_acked: (.gates.merge.acked // false),
      test_integrity_fail: ((.checks // []) | map(select((.name // "")=="test-integrity" and (.result // "")=="fail")) | length)
    }
' "$state" 2>/dev/null || true)"

# A malformed/empty derivation must not corrupt the ledger — skip silently.
[ -n "$row" ] || exit 0
printf '%s' "$row" | jq empty 2>/dev/null || exit 0

# --- Append + stamp the run-scoped sentinel -----------------------------------
# Three guards, because the ledger is clone-wide and therefore multi-writer:
#
#   1. PREVENT — a bounded, best-effort `mkdir` mutex. `mkdir` is atomic on every
#      POSIX filesystem and needs no external tool; `flock(1)` is unavailable on
#      macOS, which ships none. MEASURED ceiling ~2.0s on the full 15-attempt
#      contention path (~2.5s when a stale reclaim is also attempted each pass) —
#      the 15 sleeps are only 1.5s of it, plus the one-off granularity probe and
#      ~25ms per iteration of `mkdir`/`date`/`stat`/`cat`. On a shell whose `sleep`
#      takes only whole seconds the attempt count adapts to 2, so ~2s either way.
#      FAIL-OPEN: this is a Stop hook, so it must never hold up a turn-end. Not
#      acquiring the lock only means falling back to guard 2.
#   2. DETECT — after appending, confirm the exact row is present in the file.
#      Checked with `grep -qxF` (whole-line, literal) rather than `tail -n 1`
#      deliberately: a concurrent writer may legitimately append after us, so a
#      position-based check would misreport our intact row as torn. This detects a
#      genuinely torn/interleaved write regardless of who else wrote.
#   3. RETRY — stamp the sentinel ONLY after guard 2 passes. An unstamped sentinel
#      IS the pre-existing retry path (the run is still `done`, so the next
#      turn-end re-derives and re-appends), which is what stops a torn write from
#      silently destroying a completed run's telemetry — `printf` reports success
#      on a torn write, so without this the row would be lost permanently and the
#      reader would discard the fragment without a word.
#
# Biased toward retrying when unsure, because the two failure modes are NOT
# symmetric: the reader de-duplicates on branch+base (auto-task-stats.sh), so a
# duplicate row is collapsed and harmless, whereas a dropped row is unrecoverable
# data loss. The reader also now COUNTS and REPORTS unparseable lines, so the
# residual garbage a torn write can leave behind is visible rather than silent.
lock="$ledger.lock"
lock_token="$lock/owner"
locked=0
# An OWNERSHIP TOKEN, not just a directory. Identifying "my lock" by path alone is
# not sufficient once stale-reclaim exists, and the gap is real (reproduced): if our
# critical section outlives the staleness window — a big ledger, a throttled CI
# runner, an NFS home dir, a laptop sleeping mid-write — another writer reclaims our
# live lock, and our own unconditional `rmdir` on completion would then delete THEIR
# lock, admitting a third writer while they still believe they hold the mutex. So the
# holder stamps an id and release is conditional on that id still being ours.
_ro_id="$$-$base"
_ro_lock_is_stale() {
  # A lock dir left behind by a killed process must not wedge later writers.
  #
  # `stat` is GNU-FIRST (`-c %Y`), then BSD (`-f %m`), and the order is load-bearing
  # — this repo already measured and documented the trap at
  # hooks/auto-task-resume-list.sh:167-175: on GNU/Linux `stat -f %m` selects
  # *filesystem* mode, where `%m` is not a valid directive yet the statfs SUCCEEDS
  # (exit 0) printing garbage. A BSD-first order therefore never falls through on
  # Linux, the numeric guard below rejects the garbage, and this function returns
  # false forever — silently turning the orphaned-lock self-healing described here
  # into dead code on every Linux host. On macOS `stat -c` is rejected (exit 1) and
  # falls through to `-f %m`, which is exactly why a BSD-first order looks correct
  # when every reviewer is on a Mac. If neither form works we never declare a lock
  # stale, which is the safe direction.
  #
  # The window is deliberately much longer than any plausible critical section
  # (append + one `grep` over the ledger). It only has to be short enough that an
  # ORPHANED lock self-heals, and long enough that a merely slow holder is never
  # mistaken for a dead one — the false-stale direction is the harmful one, and
  # waiting is free here because failing to lock just falls through to guard 2.
  local now age
  now="$(date +%s 2>/dev/null)" || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  age="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true)"
  case "$age" in ''|*[!0-9]*) return 1 ;; esac
  [ "$(( now - age ))" -ge 60 ]
}
_ro_take_lock() {
  # Create the lock, then stamp ownership. Creating the token inside the dir also
  # refreshes the dir's mtime, so staleness is measured from acquisition.
  mkdir "$lock" 2>/dev/null || return 1
  # The token IS the ownership claim, so a failed write must FAIL the acquisition
  # rather than being swallowed. Holding a lock we could not mark would be
  # self-contradictory under this protocol: `_ro_release_lock` would not recognise it
  # as ours and would refuse to remove it, orphaning the lock until the staleness
  # window elapses. Undoing the attempt is clean because we just created the dir and
  # nothing else can be in it yet; returning 1 falls through to guard 2 exactly like
  # any other failure to lock.
  if ! printf '%s' "$_ro_id" 2>/dev/null > "$lock_token"; then
    rm -f "$lock_token" 2>/dev/null || true
    rmdir "$lock" 2>/dev/null || true
    return 1
  fi
  return 0
}
_ro_release_lock() {
  # Release ONLY a lock we still own. If a stale-reclaim replaced the token while we
  # were working, the lock is someone else's now and removing it is exactly the bug
  # this token exists to prevent — so leave it alone and let its owner release it.
  [ -d "$lock" ] || return 0
  [ "$(cat "$lock_token" 2>/dev/null || true)" = "$_ro_id" ] || return 0
  rm -f "$lock_token" 2>/dev/null || true
  rmdir "$lock" 2>/dev/null || true
}
# EVERY iteration costs one attempt — including the stale-lock branch. An earlier
# revision `continue`d after a failed `rmdir` WITHOUT incrementing the counter or
# sleeping, so a stale lock that cannot be removed (a stray file inside it, a
# read-only parent, another uid's dir, `chflags uchg`) spun forever at full CPU.
# In a Stop hook with no timeout in hooks.json that hangs EVERY turn-end,
# permanently — the exact opposite of the bounded, fail-open contract above. The
# loop is now unconditionally bounded: at most 15 attempts, each of which either
# acquires the lock, or sleeps and advances the counter.
# Attempt count is chosen from the granularity `sleep` actually supports, so the
# wall-clock bound holds either way: 15 x 0.1s where fractional sleep works, but only
# 2 x 1s where it does not (POSIX only requires integer seconds). Deciding this once
# up front — rather than per iteration — is what keeps the ~2s measured ceiling from
# silently becoming ~15s of turn-end delay on a shell with an integer-only sleep.
_ro_frac_sleep=0
sleep 0.1 2>/dev/null && _ro_frac_sleep=1
if [ "$_ro_frac_sleep" -eq 1 ]; then _ro_max=15; else _ro_max=2; fi
_ro_try=0
while [ "$_ro_try" -lt "$_ro_max" ]; do
  _ro_try=$((_ro_try + 1))
  if _ro_take_lock; then locked=1; break; fi
  # A stale lock gets ONE removal attempt per iteration; if it fails we fall
  # through to the sleep like any other contended attempt rather than retrying
  # `rmdir` in a tight loop. `rm -rf` rather than `rmdir` because a reclaimed lock
  # legitimately contains the previous owner's token file.
  if [ -d "$lock" ] && _ro_lock_is_stale "$lock"; then
    if rm -rf "$lock" 2>/dev/null && _ro_take_lock; then locked=1; break; fi
  fi
  if [ "$_ro_frac_sleep" -eq 1 ]; then sleep 0.1 2>/dev/null || true; else sleep 1 2>/dev/null || true; fi
done

# NOTE the redirection ORDER: `2>/dev/null` must come BEFORE `>>`. Bash applies
# redirections left to right, so with `>> "$ledger" 2>/dev/null` a failure to OPEN
# the ledger (read-only file, unwritable dir) is reported on the still-attached
# stderr — and this is a Stop hook that must stay completely silent. Silencing
# stderr first suppresses the open failure too.
# NEWLINE-SAFE APPEND. If the ledger does not already end in a newline, our row would
# be GLUED onto the last one, producing `{…}{…}` on a single line. That is not merely
# ugly: it destroys the previously-valid row, and it slips past the reader's per-line
# validation because `jq empty` accepts a STREAM of values, so the glued line counts
# as parseable and neither row is reported as skipped. The shape is reachable — the
# documented stray-ledger migration (`cat <worktree>/… >> .auto-task/outcomes.jsonl`)
# produces it whenever the source file lacks a trailing newline, as does a torn write
# truncated before its newline, or any hand-edit. `tail -c 1` is the cheap check; if it
# cannot be read we simply skip the repair rather than guessing.
_ro_lead=""
if [ -s "$ledger" ] && command -v tail >/dev/null 2>&1; then
  _ro_last="$(tail -c 1 "$ledger" 2>/dev/null || printf '\n')"
  [ "$_ro_last" = "" ] || _ro_lead=$'\n'
fi
printf '%s%s\n' "$_ro_lead" "$row" 2>/dev/null >> "$ledger" || {
  [ "$locked" -eq 1 ] && _ro_release_lock
  exit 0   # append failed outright → sentinel unwritten → retried next turn-end
}

# Guard 2, still inside the lock so a same-instant writer cannot interleave here.
#
# THREE outcomes, not two, and conflating them causes real damage. grep exits 0 =
# found, 1 = not found, >1 = it could not read the file at all. Treating "could not
# read" as "not found" would leave the sentinel unwritten forever on a ledger that
# is appendable but unreadable (`chmod 200`), so every subsequent turn-end appends
# another copy — an unbounded duplicate storm, strictly worse than the pre-change
# behavior. When verification is IMPOSSIBLE we fall back to trusting the successful
# append (exactly what this hook did before guard 2 existed); we only withhold the
# sentinel when we positively determined the row is ABSENT.
#
# grep is also the one new external tool this path needs, so it is `command -v`
# guarded like jq/git/stat/date elsewhere: no grep → cannot verify → same fallback.
landed=1
if command -v grep >/dev/null 2>&1; then
  grep -qxF -- "$row" "$ledger" 2>/dev/null
  case $? in
    0) landed=1 ;;   # verified present
    1) landed=0 ;;   # verified ABSENT → torn/interleaved → stay retryable
    *) landed=1 ;;   # unreadable → cannot verify → trust the append
  esac
fi
[ "$locked" -eq 1 ] && _ro_release_lock

# Guard 3: only a verified-landed row marks this run recorded.
#
# Same redirection-order rule as the append above, and for the same two reasons —
# this instance sat two lines away and was missed when the rule was introduced. With
# `> "$sentinel" 2>/dev/null` a failure to OPEN the sentinel (an unwritable
# `.auto-task/<branch>/` — read-only mount, full disk, `chmod 500`) is reported on
# the still-attached stderr, breaking the silence contract on EVERY turn-end. And
# because the sentinel then never gets stamped while the run stays `done`, guard 3
# re-appends a fresh row every turn-end — the same unbounded duplicate storm the
# guard-2 comment above reasons about, just reached from the other side.
[ "$landed" -eq 1 ] || exit 0
printf '%s' "$base" 2>/dev/null > "$sentinel" || true

exit 0
