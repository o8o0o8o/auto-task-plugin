#!/usr/bin/env bash
# Enforces auto-task's gate-passage contract on `git commit`.
#
# Registered as a PreToolUse hook on Bash. When the command being run is
# `git commit` AND an auto-task run is active (STATE.json present + approved),
# blocks the commit until all required gates have passed.
#
# Path: resolves the per-branch STATE.json via `git branch --show-current`,
# so multiple concurrent branches each have their own state.

set -euo pipefail

cmd="$(jq -r '.tool_input.command // ""')"

# Only fire on `git commit` (at line/pipe boundaries; not `git committed-xyz`)
if ! printf '%s' "$cmd" | LC_ALL=C grep -qE '(^|[;&|`]|\$\()[[:space:]]*git[[:space:]]+commit(\b|$)'; then
  exit 0
fi

# Resolve the per-branch state file
project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
branch="$(cd "$project_dir" && git branch --show-current 2>/dev/null || true)"
if [ -z "$branch" ]; then
  exit 0  # detached HEAD or not a repo — let git handle it
fi
state="$project_dir/.auto-task/$branch/STATE.json"
[ -f "$state" ] || exit 0

approved="$(jq -r '.approved // false' "$state")"
[ "$approved" = "true" ] || exit 0

phase="$(jq -r '.phase // ""' "$state")"
if [ "$phase" = "done" ]; then
  exit 0
fi

review_passed="$(jq -r '.gates.code_review.passed // false' "$state")"
review_tool="$(jq -r '.gates.code_review.tool // ""' "$state")"
review_clean="$(jq -r '.gates.code_review.clean_pass_after_last_fix // false' "$state")"
reviewed_sha="$(jq -r '.gates.code_review.reviewed_diff_sha // ""' "$state")"
base="$(jq -r '.base // ""' "$state")"
tier="$(jq -r '.effort.tier // "standard"' "$state")"
gate_b_passed="$(jq -r '.gates.gate_b.passed // false' "$state")"
gate_b_skipped="$(jq -r '.gates.gate_b.skipped_reason // ""' "$state")"

if [ "$review_passed" != "true" ]; then
  printf 'Blocked by auto-task-plugin: auto-task run in progress (state: %s).\nA git commit is NOT permitted until the code-review loop has passed.\nRequired before commit:\n  gates.code_review.passed = true   (currently: %s)\nRun the code-review skill, fix all blockers/required findings, re-run the skill until it returns only follow-ups, then set the flags.\n' "$state" "$review_passed" >&2
  exit 2
fi

if [ "$review_tool" != "skill:auto-task-code-review" ]; then
  printf 'Blocked by auto-task-plugin: code-review must be invoked via the `auto-task-code-review` SKILL, not an agent or hand-rolled prompt.\nRequired:\n  gates.code_review.tool = "skill:auto-task-code-review"   (currently: %s)\nRe-run the review via the Skill tool with skill="auto-task-code-review" and update the flag with real evidence.\n' "$review_tool" >&2
  exit 2
fi

if [ "$review_clean" != "true" ]; then
  printf 'Blocked by auto-task-plugin: latest code-review pass is not clean after the most recent fix.\nRequired:\n  gates.code_review.clean_pass_after_last_fix = true   (currently: %s)\nAfter applying any fix, you MUST re-invoke the code-review skill; only set this flag when its latest output contains zero blockers and zero required findings.\n' "$review_clean" >&2
  exit 2
fi

# Review-staleness check: the gate flags above are booleans the model sets for
# itself. This binds them to the actual code. When the gate last passed clean,
# the model records reviewed_diff_sha = hash of `git diff <base>`. If the diff
# now hashes differently, code changed since the last clean review and a commit
# must NOT proceed without re-review. Backward-compatible: skipped when `base`
# or `reviewed_diff_sha` is absent (legacy/older runs), so it can only ever add
# a block, never spuriously allow.
if [ -n "$base" ] && [ -n "$reviewed_sha" ]; then
  current_sha="$(cd "$project_dir" && git diff "$base" 2>/dev/null | git hash-object --stdin 2>/dev/null || true)"
  if [ -n "$current_sha" ] && [ "$current_sha" != "$reviewed_sha" ]; then
    printf 'Blocked by auto-task-plugin: the working-tree diff changed since the last clean code-review pass.\n  reviewed_diff_sha: %s\n  current diff sha:  %s   (git diff %s)\nCode was modified after gates.code_review went clean, so the review no longer covers what you are about to commit.\nRe-run the auto-task-code-review skill on the current diff, drive it to a clean pass, then refresh gates.code_review.reviewed_diff_sha before committing.\n' "$reviewed_sha" "$current_sha" "$base" >&2
    exit 2
  fi
fi

if [ "$tier" != "light" ] && [ "$gate_b_passed" != "true" ] && [ -z "$gate_b_skipped" ]; then
  printf 'Blocked by auto-task-plugin: tier=%s requires Gate B before commit.\nRequired:\n  gates.gate_b.passed = true   OR   gates.gate_b.skipped_reason set\n' "$tier" >&2
  exit 2
fi

exit 0
