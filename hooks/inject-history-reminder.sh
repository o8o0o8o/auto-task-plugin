#!/usr/bin/env bash
# Informs the session when an auto-task history folder exists for the current
# branch, so any reviewer (including non-bundled tools) honours the
# "Read-before-review contract" and reads CONTEXT.md / TRACE.md before issuing
# findings.
#
# Registered as a UserPromptSubmit hook (wired in hooks.json / settings-fragment.json).
# It is OPT-IN and OFF BY DEFAULT: it stays silent unless the setting
# `history_reminder_enabled` is true (see settings.sh). Being wired-but-gated —
# rather than enabled only by pasting a snippet into ~/.claude/settings.json — is
# deliberate: `${CLAUDE_PLUGIN_ROOT}` does not expand inside settings.json and a
# marketplace plugin lives in an opaque, per-version cache dir, so a pasted
# absolute path is unreachable/fragile there. Gating on a settings key makes
# enabling it (`settings.sh set history_reminder_enabled true`) work identically
# for marketplace and install.sh installs.
#
# Stdout from a UserPromptSubmit hook is injected into the model's context. This
# hook is purely informational: it never blocks, and even when enabled it stays
# silent when no auto-task history exists for the branch, so prompts pay no token
# cost outside auto-task branches.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# Resolve the project root that owns .auto-task/<branch>/. Start from
# CLAUDE_PROJECT_DIR (the session's project root) or $PWD, then resolve that to
# its git worktree root, so the reminder fires from a subdirectory too. Keep an
# explicitly-set CLAUDE_PROJECT_DIR authoritative for the common case — then
# retarget to a linked worktree of the same repo when the session runs in one
# (see enforce-gates.sh for the full rationale). Without the retarget, a
# worktree-isolated run resolves to the main checkout's branch and injects the
# wrong branch's — or no — read-before-review reminder.
project_dir_base="${CLAUDE_PROJECT_DIR:-$PWD}"
project_dir="$(cd "$project_dir_base" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$project_dir" ] || project_dir="$project_dir_base"

# The prompt's real cwd: prefer the payload's .cwd (authoritative session cwd),
# fall back to $PWD. Guarded stdin read so an interactive invocation never blocks
# on cat; the harness always pipes JSON here, so it reads promptly and closes.
_input=""
[ -t 0 ] || _input="$(cat 2>/dev/null || true)"
op_cwd=""
if [ -n "$_input" ] && command -v jq >/dev/null 2>&1; then
  op_cwd="$(printf '%s' "$_input" | jq -r '.cwd // ""' 2>/dev/null || true)"
fi
[ -n "$op_cwd" ] || op_cwd="$PWD"
# Retarget only for a same-repo linked worktree (shared git common-dir, different
# toplevel; common-dirs normalised via cd-into + `pwd -P`). Nested/embedded repos
# have their own common-dir and are left alone.
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
[ -n "$branch" ] || exit 0

dir="$project_dir/.auto-task/$branch"
[ -d "$dir" ] || exit 0

have_context=false; [ -f "$dir/CONTEXT.md" ] && have_context=true
have_trace=false;   [ -f "$dir/TRACE.md" ]   && have_trace=true
have_state=false;   [ -f "$dir/STATE.json" ] && have_state=true

# Nothing meaningful on disk — stay silent.
if [ "$have_context" = false ] && [ "$have_trace" = false ] && [ "$have_state" = false ]; then
  exit 0
fi

# Opt-in gate (checked last, only when we would otherwise emit, so disabled or
# non-auto-task prompts pay only cheap git + filesystem checks, never a settings
# read). Silent unless `history_reminder_enabled` is true. Fail-safe: if
# settings.sh is unreachable or errs, treat as disabled (matches the default-off)
# and stay silent.
if [ ! -f "$SCRIPT_DIR/settings.sh" ] \
   || [ "$(bash "$SCRIPT_DIR/settings.sh" get history_reminder_enabled 2>/dev/null || echo false)" != "true" ]; then
  exit 0
fi

printf 'auto-task history exists for branch "%s" at .auto-task/%s/.' "$branch" "$branch"
[ "$have_context" = true ] && printf ' CONTEXT.md (run summary + human choices) present.'
[ "$have_trace" = true ]   && printf ' TRACE.md (append-only operation log) present.'
[ "$have_state" = true ]   && printf ' STATE.json (run state machine) present.'
printf ' Per the Read-before-review contract, any code-review or audit pass on this branch should read CONTEXT.md and TRACE.md before issuing findings, and append a TRACE.md entry when done.\n'

exit 0
