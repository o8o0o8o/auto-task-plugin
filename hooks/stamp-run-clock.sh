#!/usr/bin/env bash
# stamp-run-clock.sh — stamps the run's MEASURED wall-clock from `date -u`.
#
# Registered on BOTH PreToolUse/Bash and Stop. This is PURE MEASUREMENT — it
# never blocks a tool call, never blocks a turn-end, and never influences the
# pipeline. It exists so a run's duration is something the machine observed
# rather than something the model narrated: the previous figure came from the
# first and last `state.history[].at` strings, which the model writes without
# access to a clock.
#
# WHY TWO EVENTS. `Stop` alone would stamp `created_at` at the first turn-end,
# which on this pipeline is the Phase-1 clarify or plan gate — potentially many
# minutes after the run actually started, a systematic undercount. Adding the
# PreToolUse/Bash registration means the first stamp lands on the next Bash
# command after STATE.json exists, which during branch setup is seconds away.
# Neither event type is new; both blocks already exist in hooks/hooks.json.
#
# ORDER ON `Stop` IS NOT RELIED ON. This hook is registered first in the Stop
# block, but that is cosmetic: an event's hooks are executed in PARALLEL, so array
# position is not an execution-order contract. The two row writers
# (`record-outcome.sh`, `send-telemetry.sh`) therefore call `rc_stamp` themselves
# immediately before reading, rather than racing this hook's write and recording a
# row whose `updated_at` predates the final — and typically longest — turn. This
# hook still matters for the runs neither writer touches: `record-outcome.sh`
# no-ops without an opted-in ledger and `send-telemetry.sh` no-ops with telemetry
# off, so without a Stop stamper an opted-out run's clock would never seal.
#
# The clock file, the sealing rule and the three-state duration verdict all live
# in hooks/lib/run-clock.sh; this script is only the trigger.
#
# Failure policy: FAIL OPEN, ALWAYS. Every path exits 0 and nothing is written to
# stdout (a PreToolUse hook's stdout is not a free-form channel). A missing jq, a
# missing run, an unreadable state file or a failed write all silently skip.
# `set -e` is intentionally omitted so a stray non-zero cannot abort the script
# before its final `exit 0`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# --- Resolve the project root that owns .auto-task/<branch>/ ------------------
# Mirrors record-outcome.sh: start from CLAUDE_PROJECT_DIR (or $PWD), resolve to
# the git toplevel, then retarget to a same-repo linked worktree when the event
# actually fired in one (shared git-common-dir, different toplevel; common-dirs
# normalised via cd-into + `pwd -P`). Nested/embedded repos have their own
# common-dir and are deliberately left alone.
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
[ -n "$branch" ] || exit 0   # not a repo / detached HEAD → nothing to stamp

state="$project_dir/.auto-task/$branch/STATE.json"
# No run for this branch → do NOT create a clock. The clock describes a run; a
# stray file in a repo that never invoked auto-task would be noise, and its
# absence is exactly what makes the `absent` verdict meaningful.
[ -f "$state" ] || exit 0
# An unparseable state is not an in-flight run — refuse rather than guess. Reading
# `phase` out of a truncated file yields "", which is not "done", so the
# already-done guard in rc_stamp would not fire and a clock would be seeded for a
# finished run (a fabricated `0`). `rc_stamp` gates on this too; this is
# defence-in-depth at the hook boundary.
#
# NOTE the check differs from the siblings ON PURPOSE. `record-outcome.sh` and
# `send-telemetry.sh` use `jq empty`, which ACCEPTS a zero-byte file (no values is
# valid input) — harmless for them, since they then read `phase` and no-op unless it
# is `done`. Here a missing phase is what triggers the bad write, so the check must
# be `type == "object"`. Do not "align" this with the siblings.
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' "$state" >/dev/null 2>&1 || exit 0

# shellcheck source=lib/run-clock.sh
. "$SCRIPT_DIR/lib/run-clock.sh" 2>/dev/null || exit 0
command -v rc_stamp >/dev/null 2>&1 || exit 0

rc_stamp "$(rc_clock_path "$state")" "$state" 2>/dev/null || true

exit 0
