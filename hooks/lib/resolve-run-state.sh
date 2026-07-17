#!/usr/bin/env bash
# resolve-run-state.sh — SHARED, SOURCED helper for the PreToolUse/Bash gate hooks
# (`enforce-gates.sh` and `guard-dangerous-ops.sh`).
#
# PURE RESOLUTION ONLY. Every function here sets `RRS_*` shell variables and
# returns; NONE of them `exit`, print to the user, or decide a fail-policy. The
# two callers need OPPOSITE failure policies — enforce-gates fails CLOSED (block
# the commit when it cannot verify), the ops guard fails OPEN for non-dangerous
# commands (never police normal Bash) — so failure handling and any `printf … >&2`
# / `exit 2` stay in the caller, not here. This split is what lets one helper serve
# both without one hook's policy leaking into the other.
#
# Contract: source this file, then call `rrs_decode_command "$input"` and/or
# `rrs_resolve_state "$input"` where `$input` is the raw PreToolUse JSON payload
# read from stdin. Read the `RRS_*` outputs afterward.
#
# This file is behavior-preserving with the resolution logic previously inline in
# enforce-gates.sh (its ~100-assertion enforcement-spine test is the regression net).

# rrs_decode_command <input>
#   RRS_HAS_JQ     1 if jq is available, else 0
#   RRS_CMD        the Bash command being run (decoded from .tool_input.command);
#                  when jq is absent/decoding fails, the RAW json payload
#   RRS_CMD_IS_RAW 1 when RRS_CMD is the raw payload (no decode), else 0.
#                  Callers that regex-match the command MUST use a raw-aware
#                  pattern when this is 1 (the verb is preceded by `"` not a shell
#                  boundary) so a jq-less environment is not silently un-matched.
rrs_decode_command() {
  local input="${1:-}"
  RRS_CMD_IS_RAW=1
  if command -v jq >/dev/null 2>&1; then
    RRS_HAS_JQ=1
    local decoded
    decoded="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
    if [ -n "$decoded" ]; then RRS_CMD="$decoded"; RRS_CMD_IS_RAW=0; else RRS_CMD="$input"; fi
  else
    # No jq: leave RRS_CMD as the RAW payload and flag it. Callers that regex-match
    # MUST include `"` in their leading command boundary (the verb sits after
    # `"command":"` in the JSON), exactly like enforce-gates' cmd_is_raw path. We do
    # NOT try to sed/awk the value out — portable JSON-string extraction across BSD
    # and GNU is fragile (BSD sed lacks `\|`), and raw-aware matching is what
    # enforce-gates already relies on, so we keep the two hooks consistent.
    RRS_HAS_JQ=0
    RRS_CMD="$input"
  fi
}

# rrs_resolve_state <input>
#   RRS_PROJECT_DIR    the git worktree root that owns .auto-task/<branch>/
#   RRS_BRANCH         `git branch --show-current` in RRS_PROJECT_DIR ("" if detached/none)
#   RRS_STATE          path to the current-branch STATE.json (may not exist)
#   RRS_ACTIVE_OTHERS  space-separated branch names (git-path form) of APPROVED,
#                      non-done runs on branches OTHER than RRS_BRANCH — the
#                      cross-branch scan used to guard an on-main / drifted land.
#                      Requires jq; empty when jq is absent (caller decides policy).
rrs_resolve_state() {
  local input="${1:-}"
  local has_jq=0
  command -v jq >/dev/null 2>&1 && has_jq=1

  # Resolve the project root that owns .auto-task/<branch>/. Start from
  # CLAUDE_PROJECT_DIR or $PWD, resolve to the git worktree root so a command from
  # a subdirectory still finds the top. Fall back to base when not in a worktree.
  local project_dir_base project_dir
  project_dir_base="${CLAUDE_PROJECT_DIR:-$PWD}"
  project_dir="$(cd "$project_dir_base" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$project_dir" ] || project_dir="$project_dir_base"

  # Worktree retarget: a linked worktree OF THE SAME REPO is the real target even
  # though CLAUDE_PROJECT_DIR points at the main checkout. Discriminate a linked
  # worktree (shares the common-dir, different toplevel) from a nested/embedded
  # repo (own common-dir) so nested repos never retarget.
  local op_cwd=""
  if [ "$has_jq" -eq 1 ]; then
    op_cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || true)"
  fi
  [ -n "$op_cwd" ] || op_cwd="$PWD"
  if [ -d "$op_cwd" ]; then
    local cwd_top cwd_common base_common
    cwd_top="$(cd "$op_cwd" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$cwd_top" ] && [ "$cwd_top" != "$project_dir" ]; then
      cwd_common="$(cd "$op_cwd" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)" 2>/dev/null && pwd -P || true)"
      base_common="$(cd "$project_dir" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)" 2>/dev/null && pwd -P || true)"
      if [ -n "$cwd_common" ] && [ "$cwd_common" = "$base_common" ]; then
        project_dir="$cwd_top"
      fi
    fi
  fi

  RRS_PROJECT_DIR="$project_dir"
  RRS_BRANCH="$(cd "$project_dir" 2>/dev/null && git branch --show-current 2>/dev/null || true)"
  RRS_STATE="$project_dir/.auto-task/$RRS_BRANCH/STATE.json"

  # Cross-branch active-run scan: approved, non-done runs on OTHER branches. Used
  # to guard a land performed while the checkout is on main / another branch.
  RRS_ACTIVE_OTHERS=""
  local autotask_dir="$project_dir/.auto-task"
  if [ "$has_jq" -eq 1 ] && [ -d "$autotask_dir" ]; then
    local sf rel br
    while IFS= read -r sf; do
      [ -n "$sf" ] || continue
      [ -f "$sf" ] || continue
      jq empty "$sf" 2>/dev/null || continue
      [ "$(jq -r '.approved // false' "$sf" 2>/dev/null || echo false)" = "true" ] || continue
      [ "$(jq -r '.phase // ""' "$sf" 2>/dev/null || echo "")" = "done" ] && continue
      rel="${sf#"$autotask_dir"/}"; br="${rel%/STATE.json}"
      [ "$br" != "$rel" ] || continue
      [ -n "$br" ] || continue
      [ "$br" = "$RRS_BRANCH" ] && continue
      case " $RRS_ACTIVE_OTHERS " in *" $br "*) ;; *) RRS_ACTIVE_OTHERS="$RRS_ACTIVE_OTHERS $br" ;; esac
    done <<< "$(find "$autotask_dir" -name STATE.json 2>/dev/null)"
    RRS_ACTIVE_OTHERS="${RRS_ACTIVE_OTHERS# }"
  fi
}
