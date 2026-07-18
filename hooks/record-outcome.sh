#!/usr/bin/env bash
# Records a one-line run-outcome row when an auto-task run reaches phase=="done".
#
# Registered as a Stop hook (alongside prevent-mid-protocol-stall.sh). This is
# PURE TELEMETRY — it never blocks a turn-end and never influences the pipeline.
# It exists so maintainers can measure completion rate and find where runs stall
# (via the auto-task-stats reader), preserving a record even after a per-branch
# .auto-task/<branch>/ folder is pruned.
#
# OPT-IN: the hook is a no-op unless the append-only ledger .auto-task/outcomes.jsonl
# already exists. Opt in with `touch .auto-task/outcomes.jsonl`; opt out by
# deleting it. No network, no data leaves the machine — the row is derived from
# fields already present locally in STATE.json.
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
ledger="$project_dir/.auto-task/outcomes.jsonl"
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

# --- Derive the one-line row from STATE.json ----------------------------------
# Every field guarded with a default so a partial/legacy state never errors.
# Free-text fields are length-capped (task ~140, gate_b ~120). The row now also
# carries run metrics (estimate/actual time+tokens, quality-signal trend fields);
# it may exceed the old 512B PIPE_BUF target, so append atomicity relies on the
# single O_APPEND `printf >>` write (a completing run is effectively single-writer
# per working tree — concurrent same-tree completions are not a real scenario).
# The metric fields mirror auto-task-stats.sh's DERIVE VERBATIM (lockstep — a
# regression test asserts the two field sets match). est_*/act_* are `null` when
# unmeasured so the reader's ratio can exclude them (no divide-by-zero / poison).
row="$(jq -c \
  --arg plugin_version "$plugin_version" \
  '
  (.history // []) as $h
  | ($h | map(.at // empty)) as $ats
  | ($ats | first) as $t0
  | ($ats | last) as $t1
  | (if ($t0 != null and $t1 != null)
       then (((($t1 | fromdateiso8601?) // 0) - (($t0 | fromdateiso8601?) // 0)) / 60 | floor)
       else 0 end) as $dur
  | {
      at: ($t1 // ""),
      branch: (.branch // ""),
      base: (.base // ""),
      pr_url: (.pr_url // null),
      task: ((.description // "") | .[0:140]),
      terminal_state: "done",
      plugin_version: $plugin_version,
      tier: (.effort.tier // ""),
      tier_initial: (((.effort.history // []) | first | .from) // (.effort.tier // "")),
      escalations: ((.effort.history // []) | length),
      fix_iterations: (.iteration.fix // 0),
      review_iterations: (.iteration.review // 0),
      gate_b: (if (.gates.gate_b.passed // false) then "passed"
               else ((.gates.gate_b.skipped_reason // "") | .[0:120]) end),
      followups: ((.followups // []) | length),
      duration_min: $dur,
      est_duration_min: (.estimate.duration_min // null),
      est_tokens: (.estimate.tokens_total // null),
      act_duration_min: (.actuals.duration_min // $dur),
      act_tokens: (.actuals.tokens_total // null),
      defects_early: (.quality.defects.early // 0),
      defects_late: (.quality.defects.late // 0),
      flaky: (.quality.flaky // false),
      tests_added: (.quality.tests_added // false),
      diff_loc: (((.quality.diff.loc_added // 0) + (.quality.diff.loc_removed // 0))),
      first_pass_ac: (.quality.planning.first_pass_ac // null),
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

# --- Append (single atomic write) + stamp the run-scoped sentinel -------------
printf '%s\n' "$row" >> "$ledger" 2>/dev/null || exit 0
printf '%s' "$base" > "$sentinel" 2>/dev/null || true

exit 0
