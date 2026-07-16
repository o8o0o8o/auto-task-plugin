#!/usr/bin/env bash
# suggest-cleanup.sh — SessionStart hook. Best-effort, NON-DESTRUCTIVE nudge when
# this clone has auto-task worktrees that look reclaimable (merged, or clean and
# stale past their per-type retention threshold). It NEVER deletes anything — it
# only suggests running `/auto-task-gc`, which does the sizing and the (confirmed)
# removal.
#
# Design contract (same as check-version.sh): a SessionStart hook must NEVER
# break or noticeably slow a session. So this is deliberately CHEAP — LOCAL git
# only. It runs NO `du` (multi-GB node_modules scans are seconds of I/O) and NO
# network / `gh` (PR-merge lookups); those belong in the on-demand engine. Every
# error path exits 0 with no output. Throttled to at most once per
# `worktree_cleanup_throttle_hours` PER CLONE (stamp keyed to the git common dir,
# not a plugin-global dir, so one repo's nudge never suppresses another's).
#
# Gated OFF by `worktree_cleanup_nudge=false` (default true). Per-type staleness
# comes from `worktree_stale_days_<type>` (fallback `worktree_stale_days_default`).
#
# Test seams (harmless in production):
#   AUTO_TASK_SKIP_THROTTLE=1        bypass the throttle
#   AUTO_TASK_OUTPUT=plain | --plain emit the bare one-line notice, not SessionStart JSON
#   AUTO_TASK_NOW=<epoch>            override "now" (deterministic age math)
#   AUTO_TASK_SETTINGS_FILE / AUTO_TASK_GLOBAL_SETTINGS_FILE / AUTO_TASK_HOME
#                                    forwarded to settings.sh (hermetic settings)

set -u

emit_silent() { exit 0; }

PLAIN=0
case "${1:-}" in --plain) PLAIN=1 ;; esac
[ "${AUTO_TASK_OUTPUT:-}" = "plain" ] && PLAIN=1

# --- locate settings.sh (fail-open to built-in defaults if absent) -----------
ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$ROOT" ]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)" || ROOT=""
fi
SETTINGS="$ROOT/hooks/settings.sh"

# setting <key> <builtin-default> — prefer settings.sh; fall back to the default.
setting() {
  local key="$1" def="$2" v=""
  if [ -n "$SETTINGS" ] && [ -f "$SETTINGS" ]; then
    v="$(bash "$SETTINGS" get "$key" 2>/dev/null)"
  fi
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$def"
}

# --- must be in a git repo ---------------------------------------------------
command -v git >/dev/null 2>&1 || emit_silent
COMMON="$(git rev-parse --git-common-dir 2>/dev/null)" || emit_silent
[ -n "$COMMON" ] || emit_silent
COMMON="$(cd "$COMMON" 2>/dev/null && pwd -P)" || emit_silent

# --- master switch -----------------------------------------------------------
[ "$(setting worktree_cleanup_nudge true)" = "true" ] || emit_silent

now="${AUTO_TASK_NOW:-$(date +%s 2>/dev/null || echo 0)}"
case "$now" in ''|*[!0-9]*) now=0 ;; esac

# --- throttle (per clone) ----------------------------------------------------
STAMP="$COMMON/auto-task-cleanup-nudge-stamp"
throttle_h="$(setting worktree_cleanup_throttle_hours 24)"
case "$throttle_h" in ''|*[!0-9]*) throttle_h=24 ;; esac
if [ "${AUTO_TASK_SKIP_THROTTLE:-}" != "1" ] && [ -f "$STAMP" ] && [ "$now" -gt 0 ]; then
  last="$(cat "$STAMP" 2>/dev/null || echo 0)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$last" -gt 0 ] && [ $((now - last)) -lt $((throttle_h * 3600)) ]; then
    emit_silent
  fi
fi

# --- resolve the default branch tip (for the local ancestry-merge check) -----
def_ref=""
for c in origin/main origin/master main master; do
  if git rev-parse --verify --quiet "$c" >/dev/null 2>&1; then def_ref="$c"; break; fi
done

# current worktree root (matched by toplevel, so a subdir launch still matches)
cur_top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$cur_top" ] && cur_top="$(cd "$cur_top" 2>/dev/null && pwd -P || true)"

# --- enumerate worktrees, classify (LOCAL signals only) ----------------------
reclaimable=0 merged_n=0 stale_n=0
wt_path="" wt_branch="" wt_head=""
flush() {
  [ -n "$wt_path" ] || return 0
  case "$wt_path" in */.claude/worktrees/*) ;; *) return 0 ;; esac   # ours only
  local br="${wt_branch#refs/heads/}"
  [ -n "$br" ] && [ "$br" != "$wt_branch_detached" ] || return 0     # skip detached
  # never the current worktree
  local top; top="$(cd "$wt_path" 2>/dev/null && pwd -P || true)"
  [ -n "$top" ] && [ "$top" = "$cur_top" ] && return 0
  # clean? (dirty is never reclaimable in the nudge)
  git -C "$wt_path" diff --quiet 2>/dev/null && git -C "$wt_path" diff --cached --quiet 2>/dev/null || return 0
  [ -z "$(git -C "$wt_path" ls-files --others --exclude-standard 2>/dev/null | head -1)" ] || return 0
  # merged into default by local ancestry?
  if [ -n "$def_ref" ] && git merge-base --is-ancestor "$wt_head" "$def_ref" 2>/dev/null; then
    reclaimable=$((reclaimable + 1)); merged_n=$((merged_n + 1)); return 0
  fi
  # unmerged: stale only if last commit older than the type threshold
  local ct age_days type days
  ct="$(git -C "$wt_path" log -1 --format=%ct 2>/dev/null)"
  case "$ct" in ''|*[!0-9]*) return 0 ;; esac
  [ "$now" -gt 0 ] || return 0
  age_days=$(( (now - ct) / 86400 ))
  type="${br%%/*}"
  days="$(setting "worktree_stale_days_${type}" "")"
  [ -n "$days" ] || days="$(setting worktree_stale_days_default 14)"
  case "$days" in ''|*[!0-9]*) days=14 ;; esac
  if [ "$age_days" -gt "$days" ]; then
    reclaimable=$((reclaimable + 1)); stale_n=$((stale_n + 1))
  fi
}
wt_branch_detached="__DETACHED__"
while IFS= read -r line; do
  case "$line" in
    "worktree "*) flush; wt_path="${line#worktree }"; wt_branch=""; wt_head="" ;;
    "HEAD "*)     wt_head="${line#HEAD }" ;;
    "branch "*)   wt_branch="${line#branch }" ;;
    "detached")   wt_branch="$wt_branch_detached" ;;
  esac
done <<EOF
$(git worktree list --porcelain 2>/dev/null)
EOF
flush

[ "$reclaimable" -ge 1 ] || emit_silent

# --- record the nudge (throttle) + emit --------------------------------------
if [ "${AUTO_TASK_SKIP_THROTTLE:-}" != "1" ] && [ "$now" -gt 0 ]; then
  printf '%s\n' "$now" > "$STAMP" 2>/dev/null || true
fi

parts=""
[ "$merged_n" -gt 0 ] && parts="$merged_n merged"
[ "$stale_n" -gt 0 ] && parts="${parts:+$parts, }$stale_n stale"
msg="auto-task: $reclaimable worktree(s) look reclaimable (${parts}) — run /auto-task-gc to review sizes and reclaim disk (nothing is deleted without your confirmation). Silence this with worktree_cleanup_nudge=false."

if [ "$PLAIN" = "1" ]; then
  printf '%s\n' "$msg"
  exit 0
fi
ctx="This clone has $reclaimable auto-task worktree(s) that look reclaimable ($parts). Suggest the user run /auto-task-gc to see per-worktree disk sizes and safely reclaim them (branch refs preserved). Do not delete anything without the user asking."
if command -v jq >/dev/null 2>&1; then
  jq -cn --arg m "$msg" --arg c "$ctx" \
    '{systemMessage:$m, hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}' 2>/dev/null \
    || printf '%s\n' "$msg"
else
  printf '%s\n' "$msg"
fi
exit 0
