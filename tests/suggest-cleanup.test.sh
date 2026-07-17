#!/usr/bin/env bash
# Focused test for hooks/suggest-cleanup.sh — the SessionStart worktree-cleanup nudge.
#
# Asserts: bash -n clean; the executable body uses NO `du` and NO `gh` (cheap
# contract, AC#6); silent outside a git repo; silent when worktree_cleanup_nudge
# is false (gated off, AC#4); fires (mentions /auto-task-gc) for a merged+clean
# worktree and for a clean+unmerged worktree past its per-type stale threshold;
# stays silent when the only worktree is clean+unmerged+recent (AC#5); never
# alters the worktree set; and the throttle is PER CLONE — nudging clone A does
# not suppress clone B, and re-running clone A inside the window is silent (AC#14).
#
# Hermetic: temp git repos + AUTO_TASK_SETTINGS_FILE/AUTO_TASK_HOME + AUTO_TASK_NOW,
# so it never touches a real ~/.claude and never hits the network. Exit 0 = passed.

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
SH="$HOOKS/suggest-cleanup.sh"
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
[ -f "$SH" ] || { echo "FAIL: $SH missing"; exit 1; }

PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-50s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-50s got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }
contains(){ case "$2" in *"$3"*) ok "$1" yes yes ;; *) ok "$1" "[$2]" "contains:$3" ;; esac; }

echo "================ suggest-cleanup.sh ================"
bash -n "$SH"; ok "bash -n clean" "$?" "0"

# AC#6 — no du / no gh in the executable body (strip comments first)
sed 's/#.*$//' "$SH" | grep -qE '\b(du|gh)\b' && body="FOUND" || body="CLEAN"
ok "no du/gh in body (cheap)" "$body" "CLEAN"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export AUTO_TASK_HOME="$T/home"; mkdir -p "$AUTO_TASK_HOME"
SETTINGS_FILE="$T/settings.json"; export AUTO_TASK_SETTINGS_FILE="$SETTINGS_FILE"
put(){ printf '%s\n' "$1" > "$SETTINGS_FILE"; }

# --- fixture: a clone with a merged+clean worktree and one unmerged worktree ---
mkrepo(){ # $1=dir  -> prints repo path; leaves cwd unchanged
  local r="$1"; git init -q -b main "$r"
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  ( cd "$r" && echo base > f && git add -A && git commit -qm base ) >/dev/null 2>&1
  # merged+clean: branch at main tip, no extra commits -> ancestor of main
  git -C "$r" worktree add -q .claude/worktrees/chore-done -b chore/done main >/dev/null 2>&1
  # unmerged: a feature branch with its own commit
  git -C "$r" worktree add -q .claude/worktrees/feat-open -b feat/open main >/dev/null 2>&1
  ( cd "$r/.claude/worktrees/feat-open" && echo x > g && git add -A && git commit -qm work ) >/dev/null 2>&1
}

R1="$T/r1"; mkrepo "$R1"
before_ct="$(git -C "$R1" worktree list | wc -l | tr -d ' ')"

# 1) not a git repo -> silent
out="$(cd "$T" && AUTO_TASK_SKIP_THROTTLE=1 bash "$SH" --plain 2>/dev/null)"; rc=$?
ok "non-git: exit 0" "$rc" "0"; ok "non-git: empty" "${out:-EMPTY}" "EMPTY"

# 2) gated off -> silent
put '{"worktree_cleanup_nudge": false}'
out="$(cd "$R1" && AUTO_TASK_SKIP_THROTTLE=1 bash "$SH" --plain 2>/dev/null)"
ok "gated off: empty" "${out:-EMPTY}" "EMPTY"

# 3) merged+clean worktree -> nudge mentions /auto-task-gc, count unchanged
put '{"worktree_cleanup_nudge": true, "worktree_stale_days_default": 999, "worktree_stale_days_feat": 999}'
out="$(cd "$R1" && AUTO_TASK_SKIP_THROTTLE=1 bash "$SH" --plain 2>/dev/null)"
contains "merged: nudge fires" "$out" "/auto-task-gc"
contains "merged: counts merged" "$out" "merged"
after_ct="$(git -C "$R1" worktree list | wc -l | tr -d ' ')"
ok "nudge never deletes (count)" "$after_ct" "$before_ct"

# 4) only unmerged+recent (feat threshold huge) -> silent.
#    Remove the merged worktree from the picture by pruning it, leaving feat/open.
git -C "$R1" worktree remove .claude/worktrees/chore-done >/dev/null 2>&1
out="$(cd "$R1" && AUTO_TASK_SKIP_THROTTLE=1 bash "$SH" --plain 2>/dev/null)"
ok "unmerged+recent: silent" "${out:-EMPTY}" "EMPTY"

# 5) same unmerged worktree, now STALE (low threshold + now advanced) -> fires
put '{"worktree_cleanup_nudge": true, "worktree_stale_days_feat": 1, "worktree_stale_days_default": 1}'
future="$(( $(date +%s) + 3*86400 ))"
out="$(cd "$R1" && AUTO_TASK_SKIP_THROTTLE=1 AUTO_TASK_NOW="$future" bash "$SH" --plain 2>/dev/null)"
contains "stale unmerged: nudge fires" "$out" "/auto-task-gc"
contains "stale unmerged: counts stale" "$out" "stale"

# 6) AC#14 — per-clone throttle. Fresh clone R2 (merged worktree). Nudge R1 (writes
#    R1 stamp), then confirm R2 still nudges (independent stamp), and a second R1
#    run inside the window is silent.
put '{"worktree_cleanup_nudge": true, "worktree_stale_days_default": 999, "worktree_stale_days_feat": 999}'
R2="$T/r2"; mkrepo "$R2"
now="$(date +%s)"
o1="$(cd "$R1" && AUTO_TASK_NOW="$now" bash "$SH" --plain 2>/dev/null)"   # writes R1 stamp (feat/open is not merged; but chore-done gone)
# R1 now only has unmerged feat/open with huge threshold -> may be empty; force a merged one back for a deterministic stamp write:
git -C "$R1" worktree add -q .claude/worktrees/chore-two -b chore/two main >/dev/null 2>&1
o1="$(cd "$R1" && AUTO_TASK_NOW="$now" bash "$SH" --plain 2>/dev/null)"   # fires + writes R1 stamp
contains "clone A: fires (stamp written)" "$o1" "/auto-task-gc"
o2="$(cd "$R2" && AUTO_TASK_NOW="$now" bash "$SH" --plain 2>/dev/null)"   # different clone -> NOT throttled
contains "clone B: not suppressed by A" "$o2" "/auto-task-gc"
o1b="$(cd "$R1" && AUTO_TASK_NOW="$(( now + 60 ))" bash "$SH" --plain 2>/dev/null)"  # within window
ok "clone A: throttled within window" "${o1b:-EMPTY}" "EMPTY"
# distinct stamp files exist per clone (absolutize the common dir like the hook does)
sA="$(cd "$R1" && cd "$(git rev-parse --git-common-dir)" && pwd -P)/auto-task-cleanup-nudge-stamp"
sB="$(cd "$R2" && cd "$(git rev-parse --git-common-dir)" && pwd -P)/auto-task-cleanup-nudge-stamp"
[ -f "$sA" ] && [ -f "$sB" ] && [ "$sA" != "$sB" ] && ok "per-clone stamps distinct" yes yes || ok "per-clone stamps distinct" no yes

echo "suggest-cleanup.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
