#!/usr/bin/env bash
# Focused test for hooks/auto-task-gc.sh — the on-demand worktree reporter/pruner.
#
# Asserts: bash -n clean; report mode lists worktrees + a totals line and is
# read-only (AC#7); `--prune` WITHOUT `--yes` is a dry-run that deletes nothing
# (AC#9 engine guard); `--prune --yes` removes a merged+clean worktree, PRESERVES
# its branch ref, prunes the matching main-tree .auto-task/<branch>/ + empty
# parents, and KEEPS a dirty worktree by default (AC#8); with
# worktree_cleanup_prune_dirty=true it WIP-commits a dirty worktree (BOTH a
# tracked edit AND an untracked file) then removes it, WIP retrievable on the
# branch (AC#13); the current worktree is never removed; and the SKILL exists and
# instructs confirmation + the engine three-probe (AC#9 skill half).
#
# Hermetic: temp git repos + AUTO_TASK_SETTINGS_FILE/AUTO_TASK_HOME. No network
# (gh is unauthenticated in CI -> local-ancestry only). Exit 0 = passed.

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
ROOTDIR="$(cd "$HOOKS/.." && pwd)"
SH="$HOOKS/auto-task-gc.sh"
SKILL="$ROOTDIR/skills/auto-task-gc/SKILL.md"
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
[ -f "$SH" ] || { echo "FAIL: $SH missing"; exit 1; }

PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-52s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-52s got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }
contains(){ case "$2" in *"$3"*) ok "$1" yes yes ;; *) ok "$1" "[$2]" "contains:$3" ;; esac; }

echo "================ auto-task-gc.sh ================"
bash -n "$SH"; ok "bash -n clean" "$?" "0"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export AUTO_TASK_HOME="$T/home"; mkdir -p "$AUTO_TASK_HOME"
SETTINGS_FILE="$T/settings.json"; export AUTO_TASK_SETTINGS_FILE="$SETTINGS_FILE"
put(){ printf '%s\n' "$1" > "$SETTINGS_FILE"; }
put '{"worktree_cleanup_prune_dirty": false}'
wtcount(){ git -C "$1" worktree list | wc -l | tr -d ' '; }

mkbase(){ # $1=dir
  local r="$1"; git init -q -b main "$r"
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  ( cd "$r" && echo base > f && git add -A && git commit -qm base ) >/dev/null 2>&1
}

# ---- report + dry-run guard (AC#7, AC#9-engine) ----
R="$T/r1"; mkbase "$R"
# real-world: auto-task ignores .auto-task/ via the common-dir info/exclude, and an
# auto-created worktree carries its own .auto-task/<branch>/ inside it. Reproduce
# that so the prune path is exercised as it runs in production (ignored files must
# NOT block `git worktree remove`).
echo '.auto-task/' >> "$R/.git/info/exclude"
git -C "$R" worktree add -q .claude/worktrees/chore-done -b chore/done main >/dev/null 2>&1  # merged+clean
mkdir -p "$R/.claude/worktrees/chore-done/.auto-task/chore/done"                              # ignored, inside the worktree
echo instate > "$R/.claude/worktrees/chore-done/.auto-task/chore/done/STATE.json"
mkdir -p "$R/.auto-task/chore/done"; echo x > "$R/.auto-task/chore/done/STATE.json"          # main-tree history copy
# the engine's clean-check must read this worktree as CLEAN despite the .auto-task/ dir
ok "worktree w/ ignored .auto-task reads clean" \
  "$(git -C "$R/.claude/worktrees/chore-done" ls-files --others --exclude-standard | head -1)" ""

n0="$(wtcount "$R")"
rep="$(cd "$R" && bash "$SH" 2>/dev/null)"
contains "report: header" "$rep" "worktree disk report"
contains "report: totals line" "$rep" "total:"
ok "report: read-only (count)" "$(wtcount "$R")" "$n0"

dry="$(cd "$R" && bash "$SH" --prune 2>/dev/null)"
contains "prune w/o --yes: DRY-RUN" "$dry" "DRY-RUN"
ok "prune w/o --yes: deletes nothing" "$(wtcount "$R")" "$n0"

# ---- prune --yes: merged removed, branch preserved, .auto-task pruned, dirty kept (AC#8) ----
git -C "$R" worktree add -q .claude/worktrees/chore-dirty -b chore/dirty main >/dev/null 2>&1
( cd "$R/.claude/worktrees/chore-dirty" && echo dirty >> f )   # uncommitted -> dirty (merged branch)
n1="$(wtcount "$R")"
out="$(cd "$R" && bash "$SH" --prune --yes 2>/dev/null)"
ok "prune: merged worktree gone" "$([ -d "$R/.claude/worktrees/chore-done" ] && echo yes || echo no)" "no"
ok "prune: branch ref preserved" "$(git -C "$R" rev-parse --verify --quiet chore/done >/dev/null 2>&1 && echo yes || echo no)" "yes"
ok "prune: .auto-task/<branch> pruned" "$([ -d "$R/.auto-task/chore/done" ] && echo yes || echo no)" "no"
ok "prune: empty parent pruned" "$([ -d "$R/.auto-task/chore" ] && echo yes || echo no)" "no"
ok "prune: dirty worktree KEPT (default)" "$([ -d "$R/.claude/worktrees/chore-dirty" ] && echo yes || echo no)" "yes"

# ---- current worktree never removed ----
R2="$T/r2"; mkbase "$R2"
git -C "$R2" worktree add -q .claude/worktrees/chore-cur -b chore/cur main >/dev/null 2>&1  # merged+clean
out="$(cd "$R2/.claude/worktrees/chore-cur" && bash "$SH" --prune --yes 2>/dev/null)"
ok "current worktree not removed" "$([ -d "$R2/.claude/worktrees/chore-cur" ] && echo yes || echo no)" "yes"

# ---- dirty prune with prune_dirty=true: WIP-commit tracked+untracked, then remove (AC#13) ----
put '{"worktree_cleanup_prune_dirty": true}'
R3="$T/r3"; mkbase "$R3"
git -C "$R3" worktree add -q .claude/worktrees/feat-wip -b feat/wip main >/dev/null 2>&1     # merged+clean, then dirty it
( cd "$R3/.claude/worktrees/feat-wip" && echo MOD >> f && echo NEW > newfile.txt )           # tracked edit + untracked file
out="$(cd "$R3" && bash "$SH" --prune --yes 2>/dev/null)"
ok "dirty-prune: worktree removed" "$([ -d "$R3/.claude/worktrees/feat-wip" ] && echo yes || echo no)" "no"
ok "dirty-prune: branch still resolves" "$(git -C "$R3" rev-parse --verify --quiet feat/wip >/dev/null 2>&1 && echo yes || echo no)" "yes"
# the WIP commit tip must contain BOTH the tracked modification and the untracked file
tracked="$(git -C "$R3" show feat/wip:f 2>/dev/null | tail -1)"
ok "dirty-prune: tracked edit in WIP commit" "$tracked" "MOD"
ok "dirty-prune: untracked file in WIP commit" "$(git -C "$R3" cat-file -e feat/wip:newfile.txt 2>/dev/null && echo yes || echo no)" "yes"

# ---- skill file (AC#9 skill half) ----
ok "SKILL.md exists" "$([ -f "$SKILL" ] && echo yes || echo no)" "yes"
grep -qi 'confirm' "$SKILL"; ok "SKILL instructs confirmation" "$?" "0"
grep -q 'CLAUDE_PLUGIN_ROOT' "$SKILL"; ok "SKILL has engine three-probe" "$?" "0"

echo "auto-task-gc.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
