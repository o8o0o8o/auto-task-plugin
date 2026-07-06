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

# --- Derive the one-line row from STATE.json ----------------------------------
# Every field guarded with a default so a partial/legacy state never errors.
# Free-text fields are length-capped (task ~200, gate_b ~120) so the compact
# row stays well under PIPE_BUF (512B) and the single `printf >>` append is
# atomic even if two Stop events in the same working tree race.
row="$(jq -c '
  (.history // []) as $h
  | ($h | map(.at // empty)) as $ats
  | ($ats | first) as $t0
  | ($ats | last) as $t1
  | {
      at: ($t1 // ""),
      branch: (.branch // ""),
      base: (.base // ""),
      task: ((.description // "") | .[0:200]),
      terminal_state: "done",
      tier: (.effort.tier // ""),
      tier_initial: (((.effort.history // []) | first | .from) // (.effort.tier // "")),
      escalations: ((.effort.history // []) | length),
      fix_iterations: (.iteration.fix // 0),
      review_iterations: (.iteration.review // 0),
      gate_b: (if (.gates.gate_b.passed // false) then "passed"
               else ((.gates.gate_b.skipped_reason // "") | .[0:120]) end),
      followups: ((.followups // []) | length),
      duration_min: (
        if ($t0 != null and $t1 != null) then
          (((($t1 | fromdateiso8601?) // 0) - (($t0 | fromdateiso8601?) // 0)) / 60 | floor)
        else 0 end)
    }
' "$state" 2>/dev/null || true)"

# A malformed/empty derivation must not corrupt the ledger — skip silently.
[ -n "$row" ] || exit 0
printf '%s' "$row" | jq empty 2>/dev/null || exit 0

# --- Append (single atomic write) + stamp the run-scoped sentinel -------------
printf '%s\n' "$row" >> "$ledger" 2>/dev/null || exit 0
printf '%s' "$base" > "$sentinel" 2>/dev/null || true

exit 0
