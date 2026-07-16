#!/usr/bin/env bash
# auto-task-gc.sh — on-demand disk reporter + safe pruner for auto-task worktrees.
#
# The auto-task pipeline creates one git worktree per run under
# .claude/worktrees/<type>-<slug> and never removes it, so worktrees (each with a
# full node_modules) accumulate. This engine reports what they cost and, on
# explicit request, removes the reclaimable ones SAFELY.
#
# MODES:
#   auto-task-gc.sh                 report only (READ-ONLY; default)
#   auto-task-gc.sh --prune         DRY-RUN prune plan (deletes NOTHING without --yes)
#   auto-task-gc.sh --prune --yes   actually remove reclaimable worktrees
#   --all                           widen "reclaimable" to ALL clean worktrees
#                                   (any merge status / age), still never dirty
#                                   unless worktree_cleanup_prune_dirty=true
#   --dry-run                       force report/plan even with --yes
#
# SAFETY (defense in depth — this is the destructive surface):
#   * Deletes ONLY with `--prune --yes`. `--prune` alone prints the plan.
#   * NEVER removes the current worktree (matched by toplevel) or the main tree.
#   * Preserves the branch ref (committed work stays recoverable via the branch).
#   * Prunes the matching .auto-task/<branch>/ (in the removed worktree it goes
#     with the dir; a copy in the main tree is removed too) + empty parent dirs.
#   * Dirty worktrees are KEPT unless worktree_cleanup_prune_dirty=true; then the
#     dirty tree is WIP-committed (git add -A, tracked AND untracked-non-ignored)
#     to its branch BEFORE removal. If that commit fails (e.g. a pre-commit hook),
#     the worktree is KEPT, never force-removed. So no tracked or
#     untracked-non-ignored uncommitted work is silently destroyed.
#   * CAVEAT — gitignored files go with the worktree. Removal deletes the whole
#     directory, so gitignored content living inside it (node_modules — the point
#     — but also a local .env or other ignored scratch) is removed and NOT
#     captured by the WIP commit (`git add -A` never stages ignored paths). The
#     report (run `/auto-task-gc` first) lists exactly which worktrees will go.
#   * Never uses --force / --no-verify.
#
# Classification uses local git ancestry AND (best-effort, read-only) `gh` to
# catch squash-merged PRs. `du` sizing and `gh` run here — NOT in the SessionStart
# nudge, which stays cheap.
#
# Fail-open in report mode (exits 0). Test seams: AUTO_TASK_NOW, and settings via
# AUTO_TASK_SETTINGS_FILE / AUTO_TASK_GLOBAL_SETTINGS_FILE / AUTO_TASK_HOME.

set -uo pipefail

PRUNE=0 YES=0 ALL=0 DRYRUN=0
for a in "$@"; do
  case "$a" in
    --prune)   PRUNE=1 ;;
    --yes|-y)  YES=1 ;;
    --all)     ALL=1 ;;
    --dry-run) DRYRUN=1 ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "auto-task-gc: unknown arg '$a' (use --prune [--yes] [--all] [--dry-run])" >&2 ;;
  esac
done
# --yes only bites together with --prune; --dry-run forces plan-only.
ACT=0; { [ "$PRUNE" = 1 ] && [ "$YES" = 1 ] && [ "$DRYRUN" = 0 ]; } && ACT=1

# --- locate settings.sh ------------------------------------------------------
ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[ -z "$ROOT" ] && ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)"
SETTINGS="$ROOT/hooks/settings.sh"
setting() {
  local key="$1" def="$2" v=""
  [ -f "$SETTINGS" ] && v="$(bash "$SETTINGS" get "$key" 2>/dev/null)"
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$def"
}

command -v git >/dev/null 2>&1 || { echo "auto-task-gc: not a git environment"; exit 0; }
COMMON="$(git rev-parse --git-common-dir 2>/dev/null)" || { echo "auto-task-gc: not in a git repo"; exit 0; }
COMMON="$(cd "$COMMON" 2>/dev/null && pwd -P)" || exit 0
MAIN_ROOT="$(dirname "$COMMON")"

now="${AUTO_TASK_NOW:-$(date +%s 2>/dev/null || echo 0)}"; case "$now" in ''|*[!0-9]*) now=0 ;; esac
prune_dirty="$(setting worktree_cleanup_prune_dirty false)"

def_ref=""
for c in origin/main origin/master main master; do
  git rev-parse --verify --quiet "$c" >/dev/null 2>&1 && { def_ref="$c"; break; }
done
cur_top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$cur_top" ] && cur_top="$(cd "$cur_top" 2>/dev/null && pwd -P || true)"
have_gh=0; command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && have_gh=1

hr() { awk -v k="$1" 'BEGIN{if(k>=1048576)printf "%.1fG",k/1048576;else if(k>=1024)printf "%.0fM",k/1024;else printf "%dK",k}'; }

# gh_merged <branch> -> 0 if a merged PR exists for that head branch
gh_merged() {
  [ "$have_gh" = 1 ] || return 1
  local n; n="$(gh pr list --state merged --head "$1" --json number -q 'length' 2>/dev/null)"
  case "$n" in ''|0|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

# --- enumerate + classify ----------------------------------------------------
# Rows: path \t branch \t status \t reason \t size_k \t age_days
rows=""; total_k=0; reclaim_k=0; reclaim_n=0; kept_n=0
wt_path="" wt_branch="" wt_head=""
DET="__DETACHED__"
classify() {
  [ -n "$wt_path" ] || return 0
  case "$wt_path" in */.claude/worktrees/*) ;; *) return 0 ;; esac
  local br="${wt_branch#refs/heads/}"
  [ -n "$br" ] && [ "$br" != "$DET" ] || return 0
  local top; top="$(cd "$wt_path" 2>/dev/null && pwd -P || true)"
  local size_k; size_k="$(du -sk "$wt_path" 2>/dev/null | awk '{print $1}')"; case "$size_k" in ''|*[!0-9]*) size_k=0 ;; esac
  total_k=$((total_k + size_k))
  local ct age_days=-1
  ct="$(git -C "$wt_path" log -1 --format=%ct 2>/dev/null)"; case "$ct" in ''|*[!0-9]*) ct=0 ;; esac
  [ "$now" -gt 0 ] && [ "$ct" -gt 0 ] && age_days=$(( (now - ct) / 86400 ))
  local dirty=0
  { git -C "$wt_path" diff --quiet 2>/dev/null && git -C "$wt_path" diff --cached --quiet 2>/dev/null \
      && [ -z "$(git -C "$wt_path" ls-files --others --exclude-standard 2>/dev/null | head -1)" ]; } || dirty=1
  local merged=0
  if [ -n "$def_ref" ] && git merge-base --is-ancestor "$wt_head" "$def_ref" 2>/dev/null; then merged=1
  elif gh_merged "$br"; then merged=1; fi
  local type="${br%%/*}" thr status reason
  thr="$(setting "worktree_stale_days_${type}" "")"; [ -n "$thr" ] || thr="$(setting worktree_stale_days_default 14)"
  case "$thr" in ''|*[!0-9]*) thr=14 ;; esac

  if [ -n "$top" ] && [ "$top" = "$cur_top" ]; then
    status="keep"; reason="current worktree"
  elif [ "$dirty" = 1 ]; then
    if { [ "$merged" = 1 ] || [ "$ALL" = 1 ] || { [ "$age_days" -ge 0 ] && [ "$age_days" -gt "$thr" ]; }; } && [ "$prune_dirty" = "true" ]; then
      status="reclaim"; reason="dirty (WIP-commit then remove)"
    else
      status="keep"; reason="dirty — uncommitted work"
    fi
  elif [ "$merged" = 1 ]; then
    status="reclaim"; reason="merged"
  elif [ "$ALL" = 1 ]; then
    status="reclaim"; reason="--all (clean, unmerged)"
  elif [ "$age_days" -ge 0 ] && [ "$age_days" -gt "$thr" ]; then
    status="reclaim"; reason="stale ${age_days}d > ${thr}d (${type})"
  else
    status="keep"; reason="unmerged, recent (${age_days}d <= ${thr}d)"
  fi

  if [ "$status" = "reclaim" ]; then reclaim_n=$((reclaim_n + 1)); reclaim_k=$((reclaim_k + size_k)); else kept_n=$((kept_n + 1)); fi
  rows="${rows}${wt_path}	${br}	${status}	${reason}	${size_k}	${age_days}
"
}
while IFS= read -r line; do
  case "$line" in
    "worktree "*) classify; wt_path="${line#worktree }"; wt_branch=""; wt_head="" ;;
    "HEAD "*)     wt_head="${line#HEAD }" ;;
    "branch "*)   wt_branch="${line#branch }" ;;
    "detached")   wt_branch="$DET" ;;
  esac
done <<EOF
$(git worktree list --porcelain 2>/dev/null)
EOF
classify

# --- report ------------------------------------------------------------------
echo "auto-task worktree disk report — $(basename "$MAIN_ROOT")"
[ "$have_gh" = 1 ] || echo "(note: gh unavailable/unauthenticated — merge status is local-ancestry only; squash-merged PRs may show as unmerged)"
if [ -z "$rows" ]; then
  echo "  no auto-task worktrees under .claude/worktrees/ — nothing to do."
  exit 0
fi
printf '  %-9s %7s %6s  %-32s %s\n' "STATUS" "SIZE" "AGE" "BRANCH" "REASON"
printf '%s' "$rows" | while IFS=$'\t' read -r p br st rs sz ag; do
  [ -n "$p" ] || continue
  agh=$([ "$ag" -ge 0 ] 2>/dev/null && echo "${ag}d" || echo "-")
  printf '  %-9s %7s %6s  %-32s %s\n' "$st" "$(hr "$sz")" "$agh" "$br" "$rs"
done
echo "  ---"
echo "  total: $(hr "$total_k") across $((reclaim_n + kept_n)) worktree(s) · reclaimable now: $(hr "$reclaim_k") in $reclaim_n · keeping $kept_n"

if [ "$PRUNE" = 0 ]; then
  [ "$reclaim_n" -gt 0 ] && echo "  run \`/auto-task-gc --prune\` to preview removal, then \`--prune --yes\` to reclaim."
  exit 0
fi

# --- prune plan / action -----------------------------------------------------
if [ "$ACT" = 0 ]; then
  echo ""; echo "DRY-RUN — would remove $reclaim_n worktree(s), reclaiming $(hr "$reclaim_k"). Nothing deleted. Re-run with --prune --yes to proceed."
fi
[ "$reclaim_n" -gt 0 ] || { echo "Nothing reclaimable."; exit 0; }

removed=0 freed_k=0
printf '%s' "$rows" | { removed=0; freed_k=0
while IFS=$'\t' read -r p br st rs sz ag; do
  [ "$st" = "reclaim" ] || continue
  if [ "$ACT" = 0 ]; then echo "  would remove: $br ($(hr "$sz"))"; continue; fi
  # dirty + prune_dirty: WIP-commit (tracked + untracked) BEFORE removal; keep on failure.
  if [ "$rs" = "dirty (WIP-commit then remove)" ]; then
    if git -C "$p" add -A 2>/dev/null && git -C "$p" commit -q -m "wip: auto-task-gc preserve uncommitted work before cleanup" 2>/dev/null; then
      echo "  wip-committed: $br @ $(git -C "$p" rev-parse --short HEAD 2>/dev/null)"
    else
      echo "  KEPT (WIP commit failed — not removing dirty worktree): $br"; continue
    fi
  fi
  if git worktree remove "$p" 2>/dev/null; then
    # prune a copy of .auto-task/<branch>/ in the MAIN tree + empty parents
    at="$MAIN_ROOT/.auto-task/$br"
    if [ -d "$at" ]; then rm -rf "$at" 2>/dev/null || true
      d="$(dirname "$at")"
      while [ "$d" != "$MAIN_ROOT/.auto-task" ] && [ "$d" != "$MAIN_ROOT" ] && [ -d "$d" ]; do
        rmdir "$d" 2>/dev/null || break; d="$(dirname "$d")"
      done
    fi
    echo "  removed: $br ($(hr "$sz")) — branch ref preserved"
    removed=$((removed + 1)); freed_k=$((freed_k + sz))
  else
    echo "  FAILED to remove: $br (left in place)"
  fi
done
[ "$ACT" = 1 ] && echo "  ---" && echo "  removed $removed worktree(s), reclaimed $(hr "$freed_k"). Branch refs preserved (re-add with: git worktree add <path> <branch>)."
}
exit 0
