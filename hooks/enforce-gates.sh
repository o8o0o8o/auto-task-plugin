#!/usr/bin/env bash
# Enforces auto-task's gate-passage contract on `git commit`.
#
# Registered as a PreToolUse hook on Bash. When the command being run is
# `git commit` AND an auto-task run is active (STATE.json present + approved),
# blocks the commit until all required gates have passed.
#
# Path: resolves the per-branch STATE.json via `git branch --show-current`,
# so multiple concurrent branches each have their own state.
#
# Failure policy: this is a SAFETY hook, so it fails CLOSED. Once we know the
# command is a `git commit` and a STATE.json exists for the branch, anything
# that prevents verification (jq missing, malformed JSON) blocks the commit
# rather than letting it through. `set -e` is intentionally NOT used — a stray
# non-zero from jq must not crash the script into a fail-open exit.

set -uo pipefail

input="$(cat)"

# `cmd_is_raw=1` means cmd is the raw JSON payload (jq absent or decode failed),
# not a decoded shell command. The two need different commit-detection regexes:
# the decoded command can use shell-boundary anchors, but inside raw JSON the
# verb is preceded by `"` (not a boundary char), so an anchored regex would miss
# it — which would skip the fail-closed blocks below and fail OPEN.
cmd_is_raw=1
if command -v jq >/dev/null 2>&1; then
  has_jq=1
  decoded="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
  if [ -n "$decoded" ]; then cmd="$decoded"; cmd_is_raw=0; else cmd="$input"; fi
else
  has_jq=0
  cmd="$input"
fi

# Only fire on `git commit`. Decoded command: anchor to shell boundaries so we
# don't match `git committed-xyz` or the verb inside a quoted string. Raw JSON
# fallback: we can't decode, but we can still require `git commit` to sit at a
# command-ish boundary — start-of-string, a shell separator (`; & |` / backtick
# / `$(`), or immediately after the JSON value's opening quote. That catches a
# real commit (`"command":"git commit …"`, `cd x && git commit`) while no longer
# blocking unrelated commands that merely mention the phrase in prose
# (`echo see the git commit guidelines`). It keeps the fail-closed bias for the
# genuinely-ambiguous case (a value literally starting `git commit`).
if [ "$cmd_is_raw" -eq 1 ]; then
  commit_re='(^|[;&|`]|\$\(|")[[:space:]]*git[[:space:]]+commit(\b|$)'
else
  commit_re='(^|[;&|`]|\$\()[[:space:]]*git[[:space:]]+commit(\b|$)'
fi
if ! printf '%s' "$cmd" | LC_ALL=C grep -qE "$commit_re"; then
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

# From here: a commit is being attempted AND an auto-task state file exists for
# this branch. We MUST be able to read it to decide. Fail closed otherwise.
if [ "$has_jq" -eq 0 ]; then
  printf 'Blocked by auto-task-plugin: an auto-task run state file exists for branch "%s" but `jq` is not installed, so the gate contract cannot be verified before this commit.\nInstall jq (a hard prerequisite of this plugin) and retry. If no run is active, remove .auto-task/%s/.\n' "$branch" "$branch" >&2
  exit 2
fi
if ! jq empty "$state" 2>/dev/null; then
  printf 'Blocked by auto-task-plugin: .auto-task/%s/STATE.json is not valid JSON, so the gate contract cannot be verified.\nRepair the state file (it must parse and contain the gates object) and retry, or remove .auto-task/%s/ if no run is active.\n' "$branch" "$branch" >&2
  exit 2
fi

approved="$(jq -r '.approved // false' "$state" 2>/dev/null || echo false)"
[ "$approved" = "true" ] || exit 0

phase="$(jq -r '.phase // ""' "$state" 2>/dev/null || echo "")"
if [ "$phase" = "done" ]; then
  exit 0
fi

review_passed="$(jq -r '.gates.code_review.passed // false' "$state" 2>/dev/null || echo false)"
review_tool="$(jq -r '.gates.code_review.tool // ""' "$state" 2>/dev/null || echo "")"
review_clean="$(jq -r '.gates.code_review.clean_pass_after_last_fix // false' "$state" 2>/dev/null || echo false)"
reviewed_sha="$(jq -r '.gates.code_review.reviewed_diff_sha // ""' "$state" 2>/dev/null || echo "")"
base="$(jq -r '.base // ""' "$state" 2>/dev/null || echo "")"
tier="$(jq -r '.effort.tier // "standard"' "$state" 2>/dev/null || echo standard)"
gate_b_passed="$(jq -r '.gates.gate_b.passed // false' "$state" 2>/dev/null || echo false)"
gate_b_skipped="$(jq -r '.gates.gate_b.skipped_reason // ""' "$state" 2>/dev/null || echo "")"

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
#
# The diff flags are PINNED so the hash is stable regardless of the user's git
# config (and identical across machines that share the branch). Without them,
# diff.algorithm / diff.renames / diff.noprefix / diff.mnemonicPrefix / color /
# textconv / external-diff settings can each shift the diff text — and thus the
# hash — for an unchanged tree, producing a spurious staleness block. The skill
# records reviewed_diff_sha with this SAME flag set; the two must stay in lockstep.
DIFF_FLAGS='--no-color --no-ext-diff --no-textconv --no-renames --diff-algorithm=myers --src-prefix=a/ --dst-prefix=b/'
if [ -n "$base" ] && [ -n "$reviewed_sha" ]; then
  current_sha="$(cd "$project_dir" && git diff $DIFF_FLAGS "$base" 2>/dev/null | git hash-object --stdin 2>/dev/null || true)"
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
