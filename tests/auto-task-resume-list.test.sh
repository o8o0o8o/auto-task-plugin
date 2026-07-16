#!/usr/bin/env bash
# Focused test for hooks/auto-task-resume-list.sh — the resume-run enumerator.
#
# Asserts (hermetic temp git repos + worktrees; AUTO_TASK_NOW for stable ages):
#   * bash -n clean.
#   * Enumeration: exact run count across main tree + every worktree, keyed off
#     STATE.json presence (a worktree with no STATE.json is never a run).
#   * --json: valid array; EVERY object (incl. the degraded/unparseable row) has
#     the full key set — so downstream has() checks hold.
#   * Robustness: a genuinely truncated STATE.json yields parse_ok:false, NOT a
#     crash; the engine still exits 0 (fail-open).
#   * Recency sort by last_activity_ts (newest first).
#   * AUTO_TASK_NOW age formatting ("2h ago", "20m ago").
#   * is_current: the run in the invoking worktree is flagged.
#   * worktree_present: a main-tree/residual run whose branch has no worktree is
#     an orphan (false); a run whose branch has a live worktree is true.
#   * Human table: exactly one numbered data row per JSON entry + a header token.
#   * --resume-mode truth table: none | direct | picker.
#   * SKILL contracts: the picker skill + the core-skill no-args wiring.
#
# Exit 0 = all assertions passed.

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
ROOTDIR="$(cd "$HOOKS/.." && pwd)"
SH="$HOOKS/auto-task-resume-list.sh"
SKILL="$ROOTDIR/skills/auto-task-resume/SKILL.md"
CORE="$ROOTDIR/skills/auto-task/SKILL.md"

command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[ -f "$SH" ] || { echo "FAIL: $SH missing"; exit 1; }

PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-52s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-52s got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }
contains(){ case "$2" in *"$3"*) ok "$1" yes yes ;; *) ok "$1" "[$2]" "contains:$3" ;; esac; }

echo "============ auto-task-resume-list.sh ============"
bash -n "$SH"; ok "bash -n clean" "$?" "0"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# fixed clock so relative ages are deterministic
BASE="$(jq -rn '"2030-01-01T00:00:00Z"|fromdateiso8601')"
NOW=$((BASE + 90000))
export AUTO_TASK_NOW="$NOW"
isoat(){ jq -rn --argjson e "$1" '$e|todateiso8601'; }   # epoch -> ISO

mkbase(){ local r="$1"; git init -q -b main "$r"
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  ( cd "$r" && echo base > f && git add -A && git commit -qm base ) >/dev/null 2>&1
  echo '.auto-task/' >> "$r/.git/info/exclude"; }

# write a STATE.json ($1=dir $2=phase $3=title $4=branch $5=effort $6=last-epoch)
mkstate(){ local d="$1"; mkdir -p "$d"
  jq -n --arg p "$2" --arg t "$3" --arg b "$4" --arg e "$5" --arg at "$(isoat "$6")" \
    '{phase:$p,title:$t,branch:$b,description:"d",effort:{tier:$e},
      history:[{phase:"start",at:"2029-12-31T00:00:00Z"},{phase:$p,at:$at}]}' \
    > "$d/STATE.json"; }

# ============================================================================
# Fixture R1 — enumeration / json / sort / orphan / is_current / degraded
# ============================================================================
R="$T/r1"; mkbase "$R"
git -C "$R" worktree add -q .claude/worktrees/feat-aaa -b feat/aaa main >/dev/null 2>&1
git -C "$R" worktree add -q .claude/worktrees/fix-bbb  -b fix/bbb  main >/dev/null 2>&1
git -C "$R" worktree add -q .claude/worktrees/feat-ccc -b feat/ccc main >/dev/null 2>&1
git -C "$R" worktree add -q .claude/worktrees/feat-ddd -b feat/ddd main >/dev/null 2>&1
git -C "$R" worktree add -q .claude/worktrees/no-state -b chore/nostate main >/dev/null 2>&1  # NO STATE.json -> not a run

mkstate "$R/.claude/worktrees/feat-aaa/.auto-task/feat/aaa" "gate-b" "Alpha run" "feat/aaa" "standard" $((NOW-7200))   # 2h ago, resumable
mkstate "$R/.claude/worktrees/fix-bbb/.auto-task/fix/bbb"    "done"   "Bravo run" "fix/bbb"  "light"    $((NOW-1200))   # 20m ago, done (newest)
mkstate "$R/.claude/worktrees/feat-ddd/.auto-task/feat/ddd" "review" "Delta run" "feat/ddd" "light"    $((NOW-5000))   # 2nd resumable (for precedence)
mkstate "$R/.auto-task/feat/ghost"                          "done"   "Ghost run" "feat/ghost" "standard" $((NOW-90000)) # 1d ago, ORPHAN (no worktree), done
# truncated / unparseable STATE.json
mkdir -p "$R/.claude/worktrees/feat-ccc/.auto-task/feat/ccc"
printf '{ "phase": "review", "titl' > "$R/.claude/worktrees/feat-ccc/.auto-task/feat/ccc/STATE.json"

J="$(cd "$R" && bash "$SH" --json 2>/dev/null)"; erc=$?
ok "engine exits 0 despite truncated state" "$erc" "0"
ok "--json is an array" "$(printf '%s' "$J" | jq -e 'type=="array"' >/dev/null 2>&1; echo $?)" "0"
ok "enumeration count = 5 (STATE.json only)" "$(printf '%s' "$J" | jq 'length')" "5"
ok "no-state worktree NOT listed" "$(printf '%s' "$J" | jq '[.[]|select(.branch=="chore/nostate")]|length')" "0"

KEYS='["phase","title","description","branch","worktree","worktree_present","is_current","resumable","effort","last_activity","last_activity_ts","pr_url","state_path","parse_ok"]'
ok "every object has full key set (incl degraded)" \
  "$(printf '%s' "$J" | jq --argjson k "$KEYS" -e 'all(.[]; ([keys_unsorted[]] as $have | ($k - $have)|length)==0)' >/dev/null 2>&1; echo $?)" "0"

ok "recency sort: newest (Bravo) first" "$(printf '%s' "$J" | jq -r '.[0].branch')" "fix/bbb"
ok "truncated row parse_ok=false" "$(printf '%s' "$J" | jq '[.[]|select(.branch=="feat/ccc")][0].parse_ok')" "false"
ok "truncated row not resumable" "$(printf '%s' "$J" | jq '[.[]|select(.branch=="feat/ccc")][0].resumable')" "false"
ok "done run not resumable" "$(printf '%s' "$J" | jq '[.[]|select(.branch=="fix/bbb")][0].resumable')" "false"
ok "in-flight run resumable" "$(printf '%s' "$J" | jq '[.[]|select(.branch=="feat/aaa")][0].resumable')" "true"

ok "age formatting: 2h ago (Alpha)" "$(printf '%s' "$J" | jq -r '[.[]|select(.branch=="feat/aaa")][0].last_activity')" "2h ago"
ok "age formatting: 20m ago (Bravo)" "$(printf '%s' "$J" | jq -r '[.[]|select(.branch=="fix/bbb")][0].last_activity')" "20m ago"

# worktree_present: live-worktree branch=true, orphan (main-tree, no worktree)=false
ok "worktree_present true (feat/aaa live)" "$(printf '%s' "$J" | jq '[.[]|select(.branch=="feat/aaa")][0].worktree_present')" "true"
ok "worktree_present false (feat/ghost orphan)" "$(printf '%s' "$J" | jq '[.[]|select(.branch=="feat/ghost")][0].worktree_present')" "false"

# is_current is BRANCH-based: running from the MAIN tree (branch `main`), NO run
# here is on `main`, so none is current — incl. the main-tree ghost run, whose
# branch feat/ghost != main (the Gate-B finding-2 correction; toplevel would have
# wrongly flagged it current and stranded it were it resumable).
ok "is_current false for main-tree non-current branch" "$(printf '%s' "$J" | jq '[.[]|select(.branch=="feat/ghost")][0].is_current')" "false"
ok "is_current false for other worktree" "$(printf '%s' "$J" | jq '[.[]|select(.branch=="feat/aaa")][0].is_current')" "false"

# ---- human table: exactly one numbered data row per JSON entry + header ----
TAB="$(cd "$R" && bash "$SH" 2>/dev/null)"
rows="$(printf '%s\n' "$TAB" | grep -cE '^ *[0-9]+[).] ')"
n="$(printf '%s' "$J" | jq 'length')"
ok "table: one numbered row per run" "$rows" "$n"
contains "table: header token present" "$TAB" "auto-task runs"
# read-loop column integrity (Gate B r3): a degraded row (feat/ccc truncated, so
# phase/title/effort render EMPTY) must NOT collapse columns — it must show the
# ⚠ unreadable glyph, and from the MAIN tree (branch `main`, no run on main) NO
# row may be marked "· current". A tab-IFS read would drop the empty leading
# fields and mis-render both.
contains "table: degraded row shows ⚠ unreadable" "$TAB" "unreadable"
# count ONLY numbered data rows (the footer legend also contains "· current")
ok "table: no false '· current' from column shift" "$(printf '%s\n' "$TAB" | grep -E '^ *[0-9]+[).] ' | grep -c '· current')" "0"

# ============================================================================
# --resume-mode truth table (current-worktree run takes precedence)
# ============================================================================
# picker: from R1's MAIN tree — its own run (ghost) is done, but feat/aaa & feat/ddd
# are resumable elsewhere -> picker.
ok "resume-mode = picker (no current run, others resumable)" "$(cd "$R" && bash "$SH" --resume-mode 2>/dev/null)" "picker"

# direct (precedence / loop-prevention): from feat-aaa, whose OWN run is resumable,
# WHILE feat/ddd is ALSO resumable elsewhere -> must still be direct, not picker.
# This is exactly the picker hand-off's re-entry: it must resume, not re-loop.
ok "resume-mode = direct (own run wins over other resumable)" "$(cd "$R/.claude/worktrees/feat-aaa" && bash "$SH" --resume-mode 2>/dev/null)" "direct"

# direct: a repo where the only resumable run is the CURRENT worktree's own
R2="$T/r2"; mkbase "$R2"
git -C "$R2" worktree add -q .claude/worktrees/feat-solo -b feat/solo main >/dev/null 2>&1
git -C "$R2" worktree add -q .claude/worktrees/fix-old   -b fix/old   main >/dev/null 2>&1
mkstate "$R2/.claude/worktrees/feat-solo/.auto-task/feat/solo" "execute" "Solo" "feat/solo" "light" $((NOW-600))
mkstate "$R2/.claude/worktrees/fix-old/.auto-task/fix/old"     "done"    "Old"  "fix/old"   "light" $((NOW-3600))
ok "resume-mode = direct (only current resumable)" "$(cd "$R2/.claude/worktrees/feat-solo" && bash "$SH" --resume-mode 2>/dev/null)" "direct"

# none: a repo whose only run is done
R3="$T/r3"; mkbase "$R3"
git -C "$R3" worktree add -q .claude/worktrees/fix-fin -b fix/fin main >/dev/null 2>&1
mkstate "$R3/.claude/worktrees/fix-fin/.auto-task/fix/fin" "done" "Fin" "fix/fin" "light" $((NOW-600))
ok "resume-mode = none (all done)" "$(cd "$R3" && bash "$SH" --resume-mode 2>/dev/null)" "none"

# none + empty table on a repo with zero runs
R4="$T/r4"; mkbase "$R4"
ok "resume-mode = none (no runs)" "$(cd "$R4" && bash "$SH" --resume-mode 2>/dev/null)" "none"
contains "zero-runs table is graceful" "$(cd "$R4" && bash "$SH" 2>/dev/null)" "No auto-task runs found"
ok "zero-runs --json = []" "$(cd "$R4" && bash "$SH" --json 2>/dev/null | jq -c .)" "[]"

# stdout stays clean when a prereq is missing (diagnostics on stderr): a non-git
# dir must yield exactly the sentinel on stdout, not the prose line too.
NG="$T/notgit"; mkdir -p "$NG"
ok "non-git --resume-mode stdout is clean 'none'" "$(cd "$NG" && bash "$SH" --resume-mode 2>/dev/null)" "none"
ok "non-git --json stdout is clean '[]'" "$(cd "$NG" && bash "$SH" --json 2>/dev/null)" "[]"

# ============================================================================
# Schema-drift tolerance (Gate B finding 1): a VALID json with a drifted field
# TYPE (effort a string, a scalar history entry) must NOT degrade the whole row.
# ============================================================================
R5="$T/r5"; mkbase "$R5"
git -C "$R5" worktree add -q .claude/worktrees/feat-drift -b feat/drift main >/dev/null 2>&1
mkdir -p "$R5/.claude/worktrees/feat-drift/.auto-task/feat/drift"
# effort is a STRING (not {tier}); history has a scalar entry alongside a valid one
jq -n --arg at "$(isoat $((NOW-3600)))" '
  {phase:"gate-a", title:"Drift", branch:"feat/drift", description:"d",
   effort:"heavy", history:[{phase:"start",at:$at}, "oops-a-scalar"]}' \
  > "$R5/.claude/worktrees/feat-drift/.auto-task/feat/drift/STATE.json"
# a SECOND drifted run with a NON-SCALAR leaf (effort.tier an array) — the exact
# shape that aborts @tsv in the table consumer if leaves aren't coerced.
git -C "$R5" worktree add -q .claude/worktrees/feat-leaf -b feat/leaf main >/dev/null 2>&1
mkdir -p "$R5/.claude/worktrees/feat-leaf/.auto-task/feat/leaf"
jq -n --arg at "$(isoat $((NOW-7200)))" '
  {phase:"review", title:"Leaf", branch:"feat/leaf", description:"d",
   effort:{tier:["x"]}, history:[{phase:"start",at:$at}]}' \
  > "$R5/.claude/worktrees/feat-leaf/.auto-task/feat/leaf/STATE.json"

JD="$(cd "$R5" && bash "$SH" --json 2>/dev/null)"
ok "drift: row NOT degraded (parse_ok true)" "$(printf '%s' "$JD" | jq '[.[]|select(.branch=="feat/drift")][0].parse_ok')" "true"
ok "drift: still resumable" "$(printf '%s' "$JD" | jq '[.[]|select(.branch=="feat/drift")][0].resumable')" "true"
ok "drift: string effort -> null (not a crash)" "$(printf '%s' "$JD" | jq '[.[]|select(.branch=="feat/drift")][0].effort')" "null"
ok "drift: non-scalar effort.tier -> null" "$(printf '%s' "$JD" | jq '[.[]|select(.branch=="feat/leaf")][0].effort')" "null"
ok "drift: engine exit 0" "$(cd "$R5" && bash "$SH" --json >/dev/null 2>&1; echo $?)" "0"
# table mode must NOT abort/drop rows on the non-scalar leaf: rows == json length
DR_ROWS="$(cd "$R5" && bash "$SH" 2>/dev/null | grep -cE '^ *[0-9]+[).] ')"
DR_N="$(printf '%s' "$JD" | jq 'length')"
ok "drift: table rows == json count (no @tsv abort)" "$DR_ROWS" "$DR_N"
ok "drift: table has no jq error leak" "$(cd "$R5" && bash "$SH" 2>/dev/null | grep -c 'jq: error')" "0"

# ============================================================================
# is_current is BRANCH-based (Gate B finding 2): a resumable main-tree residual
# run for a NON-current branch must be reachable (is_current=false -> picker),
# and a run for the CURRENT branch must be is_current=true.
# ============================================================================
R6="$T/r6"; mkbase "$R6"   # main tree checked out on `main`
mkstate "$R6/.auto-task/feat/residual" "execute" "Residual" "feat/residual" "standard" $((NOW-4000)) # main-tree, no worktree
JR="$(cd "$R6" && bash "$SH" --json 2>/dev/null)"
ok "residual: is_current FALSE (branch != current)" "$(printf '%s' "$JR" | jq '[.[]|select(.branch=="feat/residual")][0].is_current')" "false"
ok "residual: worktree_present FALSE (orphan)" "$(printf '%s' "$JR" | jq '[.[]|select(.branch=="feat/residual")][0].worktree_present')" "false"
ok "residual: resumable TRUE" "$(printf '%s' "$JR" | jq '[.[]|select(.branch=="feat/residual")][0].resumable')" "true"
ok "residual: reachable via picker (not stranded)" "$(cd "$R6" && bash "$SH" --resume-mode 2>/dev/null)" "picker"
ok "residual: in the picker option set" "$(printf '%s' "$JR" | jq '[.[]|select(.resumable and (.is_current|not))|.branch]|index("feat/residual")|type')" "\"number\""

R7="$T/r7"; mkbase "$R7"   # main tree on `main`, with an in-place run ON `main`
mkstate "$R7/.auto-task/main" "review" "OnMain" "main" "light" $((NOW-2000))
JM="$(cd "$R7" && bash "$SH" --json 2>/dev/null)"
ok "current-branch run: is_current TRUE" "$(printf '%s' "$JM" | jq '[.[]|select(.branch=="main")][0].is_current')" "true"
ok "current-branch run: resume-mode direct" "$(cd "$R7" && bash "$SH" --resume-mode 2>/dev/null)" "direct"

# ============================================================================
# Portability (Gate B r4): a `stat` that prints garbage and exits 0 (as GNU
# `stat -f %m` does on Linux) must NOT drop the run — the numeric mtime guard
# falls back to `now` so --argjson never gets a non-numeric value.
# ============================================================================
R8="$T/r8"; mkbase "$R8"
git -C "$R8" worktree add -q .claude/worktrees/feat-plat -b feat/plat main >/dev/null 2>&1
mkstate "$R8/.claude/worktrees/feat-plat/.auto-task/feat/plat" "execute" "Plat" "feat/plat" "light" $((NOW-100))
BIN="$T/fakebin"; mkdir -p "$BIN"
printf '#!/bin/sh\necho "?"\nexit 0\n' > "$BIN/stat"; chmod +x "$BIN/stat"   # garbage + exit 0, any args
JP="$(cd "$R8" && PATH="$BIN:$PATH" bash "$SH" --json 2>/dev/null)"
ok "garbage-stat: run still enumerated (not dropped)" "$(printf '%s' "$JP" | jq '[.[]|select(.branch=="feat/plat")]|length')" "1"
ok "garbage-stat: last_activity_ts is numeric" "$(printf '%s' "$JP" | jq '[.[]|select(.branch=="feat/plat")][0].last_activity_ts | type')" "\"number\""
ok "garbage-stat: engine exit 0" "$(cd "$R8" && PATH="$BIN:$PATH" bash "$SH" --json >/dev/null 2>&1; echo $?)" "0"

# ============================================================================
# SKILL contracts
# ============================================================================
ok "picker SKILL.md exists" "$([ -f "$SKILL" ] && echo yes || echo no)" "yes"
contains "picker SKILL: three-probe" "$(cat "$SKILL")" "CLAUDE_PLUGIN_ROOT"
contains "picker SKILL: EnterWorktree" "$(cat "$SKILL")" "EnterWorktree"
contains "picker SKILL: AskUserQuestion" "$(cat "$SKILL")" "AskUserQuestion"
contains "picker SKILL: is_current handling" "$(cat "$SKILL")" "is_current"
contains "picker SKILL: orphan/worktree add" "$(cat "$SKILL")" "worktree add"
contains "picker SKILL: orphan state relocation" "$(cat "$SKILL")" "cp -R"
contains "picker SKILL: relocation is mandatory" "$(cat "$SKILL")" "Relocate the run's state"
contains "picker SKILL: option predicate" "$(cat "$SKILL")" "resumable == true and (.is_current | not)"

contains "core SKILL: references picker" "$(cat "$CORE")" "auto-task-resume"
contains "core SKILL: delegates to resume-mode" "$(cat "$CORE")" "resume-mode"
contains "core SKILL: preserved-behavior sentinel" "$(cat "$CORE")" "single current-branch run"

echo "--------------------------------------------------"
echo "auto-task-resume-list.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
