#!/usr/bin/env bash
# Informs the session when an auto-task history folder exists for the current
# branch, so any reviewer (including non-bundled tools) honours the
# "Read-before-review contract" and reads CONTEXT.md / TRACE.md before issuing
# findings.
#
# Registered as an OPTIONAL UserPromptSubmit hook (off by default — see
# settings-fragment.json). Stdout from a UserPromptSubmit hook is injected into
# the model's context. This hook is purely informational: it never blocks, and
# it stays silent when no auto-task history exists for the branch so unrelated
# prompts pay no token cost.

set -uo pipefail

# Resolve the project root that owns .auto-task/<branch>/. Start from
# CLAUDE_PROJECT_DIR (the session's project root) or $PWD, then resolve that to
# its git worktree root, so the reminder fires from a subdirectory too. Resolving
# the toplevel OF the base (not from raw CWD) keeps an explicitly-set
# CLAUDE_PROJECT_DIR authoritative — being inside a nested/embedded repo or
# submodule does not silently retarget a different repo. Fall back to base when
# it is not inside a working tree (no repo / bare / inside .git/).
project_dir_base="${CLAUDE_PROJECT_DIR:-$PWD}"
project_dir="$(cd "$project_dir_base" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$project_dir" ] || project_dir="$project_dir_base"
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

printf 'auto-task history exists for branch "%s" at .auto-task/%s/.' "$branch" "$branch"
[ "$have_context" = true ] && printf ' CONTEXT.md (run summary + human choices) present.'
[ "$have_trace" = true ]   && printf ' TRACE.md (append-only operation log) present.'
[ "$have_state" = true ]   && printf ' STATE.json (run state machine) present.'
printf ' Per the Read-before-review contract, any code-review or audit pass on this branch should read CONTEXT.md and TRACE.md before issuing findings, and append a TRACE.md entry when done.\n'

exit 0
