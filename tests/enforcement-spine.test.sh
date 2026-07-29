#!/usr/bin/env bash
# Integration test for the auto-task ENFORCEMENT SPINE.
#
# Drives a real STATE.json through the full documented phase/gate lifecycle in a
# throwaway git repo and asserts the real hooks (enforce-gates.sh + the Stop
# hook) behave correctly at each transition, for both STANDARD and LIGHT tiers.
#
# What this DOES cover: the mechanical contract between the state machine and the
# hooks — commit blocked until gates pass, tier-specific Gate B requirement,
# review-staleness, the wrong-review-tool block, and every Stop-hook yield/block
# decision. What it does NOT cover: whether the model correctly follows the skill
# prose (that requires a live `/auto-task` run with the human gate).
#
# Usage: tests/enforcement-spine.test.sh   (requires git + jq, like the hooks)
# Exit 0 = all assertions passed.

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
GATE="$HOOKS/enforce-gates.sh"
STOP="$HOOKS/prevent-mid-protocol-stall.sh"
ATTR="$HOOKS/block-ai-attribution.sh"

for tool in git jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not installed (required by the hooks under test)"; exit 0; }
done

PASS=0; FAIL=0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cd "$T"
git init -q; git config user.email t@t.t; git config user.name t; git checkout -q -b feat/widget
printf 'export const n = 1;\n' > app.js; git add app.js; git commit -qm init
BASE="$(git rev-parse HEAD)"
SD=".auto-task/feat/widget"; mkdir -p "$SD"; ST="$SD/STATE.json"
COMMIT='{"tool_input":{"command":"git commit -m wip"}}'

gate(){ printf '%s' "$COMMIT" | CLAUDE_PROJECT_DIR="$T" bash "$GATE" >/dev/null 2>&1; echo $?; }
grun(){ printf '%s' "$1" | CLAUDE_PROJECT_DIR="$T" bash "$GATE" >/dev/null 2>&1; echo $?; }
attr(){ printf '%s' "$1" | bash "$ATTR" >/dev/null 2>&1; echo $?; }
# `</dev/null` is load-bearing, not decoration: the Stop hook does a guarded stdin
# read, and with stdin inherited from the test runner an invocation can BLOCK
# indefinitely. Without it this suite hangs rather than fails — observed while
# mutation-testing the loop-budget release, where the run wedged past a 6-minute
# bound and completed in seconds once stdin was closed. Pre-existing latent
# flakiness; the loop-budget block below adds ~12 more Stop invocations, which is
# what surfaced it.
stop(){ local o; o="$(CLAUDE_PROJECT_DIR="$T" bash "$STOP" </dev/null 2>/dev/null)"; [ -z "$o" ] && { echo allow; return; }; printf '%s' "$o" | jq -r '.decision // "allow"' 2>/dev/null; }
# Must use the SAME pinned flags as enforce-gates.sh, or the recorded sha won't
# match the hook's recompute under non-default git config.
DIFF_FLAGS='--no-color --no-ext-diff --no-textconv --no-renames --diff-algorithm=myers --src-prefix=a/ --dst-prefix=b/'
sha(){ git diff $DIFF_FLAGS "$BASE" | git hash-object --stdin; }
setstate(){ local tmp; tmp="$(jq "$1" "$ST")"; printf '%s' "$tmp" > "$ST"; }
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-54s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-54s got=%s want=%s\n' "$1" "$2" "$3"; fi; }

echo "================ STANDARD-tier run ================"
cat > "$ST" <<EOF
{"approved":false,"phase":"define","expected_next_action":null,"base":"$BASE","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
EOF
expect "P1 setup: stop allowed (not approved)"            "$(stop)" "allow"
expect "P1 setup: commit allowed (not approved)"          "$(gate)" "0"
setstate '.expected_next_action="user-approval"'
expect "P1 plan gate: stop allowed (user-approval)"       "$(stop)" "allow"
setstate '.approved=true|.phase="execute"|.expected_next_action="auto-continue"'
expect "P2 execute: stop BLOCKED (auto-continue)"         "$(stop)" "block"
expect "P2 execute: commit BLOCKED (no gates)"            "$(gate)" "2"
printf 'export const n = 2;\nexport const m = 3;\n' > app.js
setstate '.phase="self-verify"|.gates.self_verify={"passed":true}'
expect "P3 self-verify: commit still BLOCKED"             "$(gate)" "2"
expect "P3 self-verify: stop still BLOCKED"               "$(stop)" "block"
setstate '.phase="gate-a"|.gates.gate_a={"passed":true}'
expect "Gate A pass: commit still BLOCKED (no review)"    "$(gate)" "2"
RSHA="$(sha)"
setstate "$(printf '.phase="review"|.gates.code_review={"passed":true,"tool":"skill:auto-task-code-review","clean_pass_after_last_fix":true,"reviewed_diff_sha":"%s"}' "$RSHA")"
expect "P4 review clean: commit BLOCKED (STANDARD->Gate B)" "$(gate)" "2"
setstate '.phase="gate-b"|.gates.gate_b={"passed":true}'
expect "Gate B pass: commit ALLOWED"                      "$(gate)" "0"
printf 'export const n = 2;\nexport const m = 3;\nexport const STRAY = 9;\n' > app.js
expect "Staleness: post-review edit BLOCKS commit"        "$(gate)" "2"
printf 'export const n = 2;\nexport const m = 3;\n' > app.js
expect "Staleness: revert to reviewed diff ALLOWS"        "$(gate)" "0"

# ---- MERGE_HEAD staleness: ENFORCED during a merge (H1 fix) ------------------
# A conflict finalize (`git commit --no-edit` with MERGE_HEAD) is the ONLY merge
# that reaches this hook (a clean auto-merge commits via `git merge`, no `commit`
# verb). It carries authored resolution edits, so the staleness check is NOT
# skipped during a merge: a stale reviewed_diff_sha BLOCKS, and the merge commit
# is admitted only once the resolved tree is re-reviewed and the sha refreshed to
# match it. Boolean gates still hold throughout.
printf 'export const n = 2;\nexport const m = 3;\nexport const UPSTREAM = 7;\n' > app.js
expect "Merge: stale diff BLOCKS with no merge"           "$(gate)" "2"
git rev-parse HEAD > .git/MERGE_HEAD   # simulate an in-progress merge
expect "Merge: stale diff BLOCKS during merge (no re-review)" "$(gate)" "2"
setstate "$(printf '.gates.code_review.reviewed_diff_sha="%s"' "$(sha)")"   # re-review refreshed the sha to the merged tree
expect "Merge: refreshed sha ADMITS the merge commit"     "$(gate)" "0"
setstate '.gates.code_review.passed=false'
expect "Merge: boolean gates still enforced during merge" "$(gate)" "2"
setstate '.gates.code_review.passed=true'
rm -f .git/MERGE_HEAD                   # merge concluded
setstate "$(printf '.gates.code_review.reviewed_diff_sha="%s"' "$RSHA")"    # sha back to the pre-merge reviewed tree
expect "Merge: stale diff BLOCKS again post-merge"        "$(gate)" "2"
printf 'export const n = 2;\nexport const m = 3;\n' > app.js   # back to reviewed diff
expect "Merge: reviewed diff ALLOWED after merge"         "$(gate)" "0"
# ------------------------------------------------------------------------------

setstate '.phase="handover"|.expected_next_action="user-push-prompt"'
expect "P5 push prompt: stop ALLOWED"                     "$(stop)" "allow"
setstate '.phase="done"|.expected_next_action=null'
expect "Done: stop ALLOWED"                               "$(stop)" "allow"
expect "Done: commit ALLOWED (phase=done)"                "$(gate)" "0"

echo "================ LIGHT-tier run (Gate B skipped) ================"
git checkout -q -b fix/typo; SD2=".auto-task/fix/typo"; mkdir -p "$SD2"; ST2="$SD2/STATE.json"
B2="$(git rev-parse HEAD)"; RSHA2="$(git diff $DIFF_FLAGS "$B2" | git hash-object --stdin)"
gateL(){ printf '%s' "$COMMIT" | CLAUDE_PROJECT_DIR="$T" bash "$GATE" >/dev/null 2>&1; echo $?; }
cat > "$ST2" <<EOF
{"approved":true,"phase":"review","expected_next_action":"auto-continue","base":"$B2","effort":{"tier":"light"},
 "gates":{"code_review":{"passed":true,"tool":"skill:auto-task-code-review","clean_pass_after_last_fix":true,"reviewed_diff_sha":"$RSHA2"},
          "gate_b":{"passed":false,"skipped_reason":"tier=light"}}}
EOF
expect "LIGHT: commit ALLOWED (Gate B skipped)"           "$(gateL)" "0"
tmp="$(jq '.gates.code_review.tool="agent:code-reviewer"' "$ST2")"; printf '%s' "$tmp" > "$ST2"
expect "LIGHT: wrong review tool BLOCKED"                 "$(gateL)" "2"

echo "================ Raw-mode commit detection (jq decode empty) ================"
# Payloads with no .tool_input.command force the raw-JSON fallback regex.
# Restore feat/widget to a fully-blocking state so a *detected* commit blocks.
git checkout -q feat/widget
printf 'export const n = 2;\nexport const m = 3;\n' > app.js
cat > "$ST" <<EOF
{"approved":true,"phase":"execute","expected_next_action":"auto-continue","base":"$BASE","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
EOF
# A real commit verb at the value's opening quote → detected → blocked.
expect "Raw: bare commit payload BLOCKED"                 "$(grun '{"x":"git commit -m wip"}')" "2"
# Commit after a shell separator → detected → blocked.
expect "Raw: chained commit (&&) BLOCKED"                 "$(grun '{"x":"cd app && git commit -m wip"}')" "2"
# Prose mention mid-string (not at a command boundary) → NOT a commit → allowed.
expect "Raw: prose 'git commit' NOT blocked"              "$(grun '{"x":"please read the git commit guidelines"}')" "0"

echo "================ Bypass-form commit detection (fail-open regression) ================"
# feat/widget is still on the blocking state set just above (approved, phase=execute,
# gates false, no base/sha → staleness skipped), so any *detected* commit → exit 2 and
# any *undetected* one → exit 0. These lock in the fix for commit invocations that the
# old `git[[:space:]]+commit` regex missed and silently FAILED OPEN on. Labels are
# prefixed "Bypass:" so a skip-guard can count the PASS lines.
# ---- decoded payloads that MUST be detected (blocked, exit 2) ----
expect "Bypass: decoded git -C <path> commit"             "$(grun '{"tool_input":{"command":"git -C /x commit -m y"}}')" "2"
expect "Bypass: decoded git -c k=v commit"                "$(grun '{"tool_input":{"command":"git -c a.b=c commit -m y"}}')" "2"
expect "Bypass: decoded ENV=val git commit"               "$(grun '{"tool_input":{"command":"GIT_AUTHOR_NAME=x git commit -m y"}}')" "2"
expect "Bypass: decoded git -c quoted-value commit"       "$(grun "{\"tool_input\":{\"command\":\"git -c user.name='A B' commit\"}}")" "2"
expect "Bypass: decoded quoted-env-value git commit"      "$(grun "{\"tool_input\":{\"command\":\"GIT_AUTHOR_NAME='A B' git commit\"}}")" "2"
expect "Bypass: decoded git -p commit (flag before verb)" "$(grun '{"tool_input":{"command":"git -p commit"}}')" "2"
expect "Bypass: decoded git --no-pager commit"            "$(grun '{"tool_input":{"command":"git --no-pager commit"}}')" "2"
expect "Bypass: decoded sudo git commit"                  "$(grun '{"tool_input":{"command":"sudo git commit"}}')" "2"
expect "Bypass: decoded command git commit"               "$(grun '{"tool_input":{"command":"command git commit"}}')" "2"
expect "Bypass: decoded env FOO=x git commit"             "$(grun '{"tool_input":{"command":"env FOO=x git commit"}}')" "2"
expect "Bypass: decoded nice git commit"                  "$(grun '{"tool_input":{"command":"nice git commit -m z"}}')" "2"
expect "Bypass: decoded /usr/bin/git commit"              "$(grun '{"tool_input":{"command":"/usr/bin/git commit"}}')" "2"
expect "Bypass: decoded ./git commit"                     "$(grun '{"tool_input":{"command":"./git commit"}}')" "2"
expect "Bypass: decoded sudo git -C /x commit (combo)"    "$(grun '{"tool_input":{"command":"sudo git -C /x commit"}}')" "2"
# ---- raw payloads (no .tool_input.command → raw regex) that MUST be detected ----
expect "Bypass: raw git -C <path> commit"                 "$(grun '{"x":"git -C /x commit -m y"}')" "2"
expect "Bypass: raw ENV=val git commit"                   "$(grun '{"x":"GIT_AUTHOR_NAME=x git commit"}')" "2"
expect "Bypass: raw sudo git commit"                      "$(grun '{"x":"sudo git commit"}')" "2"
expect "Bypass: raw /usr/bin/git commit"                  "$(grun '{"x":"/usr/bin/git commit"}')" "2"
# ---- forms that MUST NOT be treated as a commit (allowed, exit 0) ----
expect "Bypass: decoded prose NOT blocked"                "$(grun '{"tool_input":{"command":"echo see the git commit guidelines"}}')" "0"
expect "Bypass: decoded git log --grep=commit NOT blocked" "$(grun '{"tool_input":{"command":"git log --grep=commit"}}')" "0"
expect "Bypass: decoded git status NOT blocked"           "$(grun '{"tool_input":{"command":"git status"}}')" "0"
expect "Bypass: decoded sudo git status NOT blocked"      "$(grun '{"tool_input":{"command":"sudo git status"}}')" "0"
expect "Bypass: decoded mid-sentence 'command' NOT blocked" "$(grun '{"tool_input":{"command":"echo run the command git commit to save"}}')" "0"
expect "Bypass: raw prose NOT blocked"                    "$(grun '{"x":"read the git commit docs first"}')" "0"

echo "================ Stall-breaker (Stop hook soft-lock release) ================"
# A valid mid-pipeline state blocks every turn-end. With AUTO_TASK_STALL_LIMIT
# low, repeated stops in the SAME state must eventually RELEASE to avoid a
# soft-lock; a state change must reset the counter so blocking resumes.
cat > "$ST" <<EOF
{"approved":true,"phase":"review","expected_next_action":"auto-continue","base":"$BASE","effort":{"tier":"standard"},
 "iteration":{"review":0,"fix":0},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
EOF
rm -f "$SD/.stall-block-count"
stopS(){ local o; o="$(CLAUDE_PROJECT_DIR="$T" AUTO_TASK_STALL_LIMIT=3 bash "$STOP" </dev/null 2>/dev/null)"; [ -z "$o" ] && { echo allow; return; }; printf '%s' "$o" | jq -r '.decision // "allow"' 2>/dev/null; }
expect "Stall: block #1 (count<limit)"                    "$(stopS)" "block"
expect "Stall: block #2 (count<limit)"                    "$(stopS)" "block"
expect "Stall: release #3 (count>=limit)"                 "$(stopS)" "allow"
setstate '.iteration.fix=1'   # state advanced → fresh block sequence
expect "Stall: blocking resumes after a release"         "$(stopS)" "block"

echo "== Phase-6 preview poll: preview.polls advances the signature (no false soft-lock) =="
# A `poll` wait holds phase/expected_next_action/iterations CONSTANT across many
# turn-ends, but bumps preview.polls each cycle. Each bump changes the signature,
# resetting the stall counter — so a PROGRESSING poll never force-releases as
# "frozen", even past AUTO_TASK_STALL_LIMIT.
rm -f "$SD/.stall-block-count"
cat > "$ST" <<EOF
{"approved":true,"phase":"preview","expected_next_action":"auto-continue","base":"$BASE","effort":{"tier":"standard"},
 "iteration":{"review":0,"fix":0},
 "gates":{"code_review":{"passed":true},"gate_b":{"passed":true}},
 "preview":{"status":"awaiting","polls":0}}
EOF
expect "Preview poll: block #1 (polls=0)"                "$(stopS)" "block"
setstate '.preview.polls=1'; expect "Preview poll: block (polls=1, counter reset)" "$(stopS)" "block"
setstate '.preview.polls=2'; expect "Preview poll: block (polls=2)"               "$(stopS)" "block"
setstate '.preview.polls=3'; expect "Preview poll: block (polls=3, still no release past limit)" "$(stopS)" "block"
setstate '.preview.polls=4'; expect "Preview poll: block (polls=4, progressing poll never soft-locks)" "$(stopS)" "block"
# A FROZEN poll (polls stops changing) is still caught by the backstop at the limit.
rm -f "$SD/.stall-block-count"; setstate '.preview.polls=99'   # fixed; unchanged across the next calls
expect "Frozen poll: block #1"                           "$(stopS)" "block"
expect "Frozen poll: block #2"                           "$(stopS)" "block"
expect "Frozen poll: RELEASE #3 (backstop intact)"       "$(stopS)" "allow"

echo "================ AI-attribution block ================"
expect "Attr: Co-Authored-By Claude BLOCKED"              "$(attr '{"tool_input":{"command":"git commit -m \"x\n\nCo-Authored-By: Claude <x@y>\""}}')" "2"
expect "Attr: clean commit ALLOWED"                       "$(attr '{"tool_input":{"command":"git commit -m clean"}}')" "0"
# Scoping: PR-body writers are still enforced ...
expect "Attr: gh pr create --body marker BLOCKED"         "$(attr '{"tool_input":{"command":"gh pr create --title t --body \"x Co-Authored-By: Claude <a@b>\""}}')" "2"
expect "Attr: gh pr edit --body marker BLOCKED"           "$(attr '{"tool_input":{"command":"gh pr edit 5 --body \"🤖 Generated with [Claude Code]\""}}')" "2"
expect "Attr: git -C <path> commit marker BLOCKED"        "$(attr '{"tool_input":{"command":"git -C /x commit -m \"Co-Authored-By: Claude\""}}')" "2"
expect "Attr: raw-fallback commit marker BLOCKED"         "$(attr '{"x":"git commit -m \"Co-Authored-By: Claude\""}')" "2"
# ... but non-commit / non-PR commands that merely MENTION a marker are no longer
# false-positive-blocked (the H2 fix). Previously each of these exited 2.
expect "Attr: git log --grep marker NOT blocked (scoped)" "$(attr '{"tool_input":{"command":"git log --grep=\"Co-Authored-By: Claude\""}}')" "0"
expect "Attr: grep for marker NOT blocked (scoped)"       "$(attr '{"tool_input":{"command":"grep -rn \"Co-Authored-By: Claude\" ."}}')" "0"
expect "Attr: git status + marker mention NOT blocked"    "$(attr '{"tool_input":{"command":"git status # Co-Authored-By: Claude"}}')" "0"
expect "Attr: gh pr view marker NOT blocked (not create/edit)" "$(attr '{"tool_input":{"command":"gh pr view 5 # 🤖 Generated"}}')" "0"

echo "================ Fail-open / fail-closed edges ================"
git checkout -q feat/widget
echo '{bad json' > "$ST"
expect "Malformed STATE.json: stop ALLOWS (no soft-lock)" "$(stop)" "allow"
MALF="$(printf '%s' "$COMMIT" | CLAUDE_PROJECT_DIR="$T" bash "$GATE" 2>&1 >/dev/null)"; MALFRC="$?"
expect "Malformed STATE.json: commit BLOCKED (fail closed)" "$MALFRC" "2"
# Status alone would also be satisfied by a fail-closed block attributed to the wrong
# cause. Pin the reason so the assertion proves WHY it blocked.
expect "Malformed STATE.json: names unparseable state as the reason" "$(printf '%s' "$MALF" | grep -qF 'not valid JSON' && echo y || echo n)" "y"

echo "================ Worktree / subdir / nested-repo resolution ================"
# Each assertion sets its OWN state and discriminates the fix from a revert — no
# reliance on state leaked from earlier blocks. CWD and CLAUDE_PROJECT_DIR are
# controlled per case.
git checkout -q feat/widget
# Give MAIN a VALID ungated mid-pipeline state (used by the nested-repo case below) —
# set explicitly, not the malformed leftover from the Fail-open block above.
cat > "$ST" <<EOF
{"approved":true,"phase":"execute","expected_next_action":"auto-continue","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
EOF
# Linked worktree on its own branch, with a nested subdirectory.
WT="$T/wt"; git worktree add -q "$WT" -b wt-feature >/dev/null 2>&1
SUB="$WT/pkg/sub"; mkdir -p "$SUB"
SDW="$WT/.auto-task/wt-feature"; mkdir -p "$SDW"
# Helpers: run a hook from an explicit CWD ($1) with CLAUDE_PROJECT_DIR UNSET.
gateAt(){ printf '%s' "$COMMIT" | ( cd "$1" && unset CLAUDE_PROJECT_DIR && bash "$GATE" ) >/dev/null 2>&1; echo $?; }
stopAt(){ local o; o="$( cd "$1" && unset CLAUDE_PROJECT_DIR && bash "$STOP" </dev/null 2>/dev/null )"; [ -z "$o" ] && { echo allow; return; }; printf '%s' "$o" | jq -r '.decision // "allow"' 2>/dev/null; }
# (1) WT-subdir-gate: ungated worktree state; CWD = worktree SUBDIR; CPD unset -> BLOCK.
#     Discriminates the fix: old `$PWD`=subdir resolution finds no state and fail-opens (0);
#     resolving the toplevel of the base finds the worktree root and blocks (2).
cat > "$SDW/STATE.json" <<EOF
{"approved":true,"phase":"execute","expected_next_action":"auto-continue","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
EOF
expect "WT-subdir-gate: ungated commit BLOCKED from worktree subdir (CPD unset)" "$(gateAt "$SUB")" "2"
# (2) WT-subdir-stall: same location + state, mid-pipeline turn-end -> BLOCK.
expect "WT-subdir-stall: mid-pipeline turn-end BLOCKED from worktree subdir" "$(stopAt "$SUB")" "block"
# (3) WT-subdir-allow (sanity control): gates-met worktree state (LIGHT, no base/sha so the
#     staleness check is skipped); CWD = worktree subdir; CPD unset -> ALLOWED.
cat > "$SDW/STATE.json" <<EOF
{"approved":true,"phase":"review","expected_next_action":"auto-continue","effort":{"tier":"light"},
 "gates":{"code_review":{"passed":true,"tool":"skill:auto-task-code-review","clean_pass_after_last_fix":true},
          "gate_b":{"passed":false,"skipped_reason":"tier=light"}}}
EOF
expect "WT-subdir-allow: gates-met commit ALLOWED from worktree subdir (CPD unset)" "$(gateAt "$SUB")" "0"
# (4) WT-nested-gate: a nested git repo embedded under MAIN; commit from inside it with
#     CLAUDE_PROJECT_DIR=main(=$T). Resolution must HONOR CPD ($T, ungated) and BLOCK — not
#     retarget the nested repo and fail open. Discriminates against show-toplevel-from-CWD,
#     which would resolve the nested repo, find no state, and allow (0) — the Gate B finding.
NESTED="$T/vendor/embedded"; mkdir -p "$NESTED"
( cd "$NESTED" && git init -q && git config user.email t@t.t && git config user.name t && printf 'y\n' > g && git add g && git commit -qm n ) >/dev/null 2>&1
gateNested(){ printf '%s' "$COMMIT" | ( cd "$NESTED" && CLAUDE_PROJECT_DIR="$T" bash "$GATE" ) >/dev/null 2>&1; echo $?; }
expect "WT-nested-gate: commit from nested repo honors CLAUDE_PROJECT_DIR, BLOCKED (no fail-open)" "$(gateNested)" "2"
git worktree remove --force "$WT" >/dev/null 2>&1 || true

echo "================ Worktree-isolated run, CLAUDE_PROJECT_DIR pinned to MAIN (the reported false positive) ================"
# auto-task isolates every run in a linked worktree, but the harness keeps
# CLAUDE_PROJECT_DIR pinned to the MAIN checkout. MAIN sits on a branch with no
# active run while ANOTHER branch has an active run (leftover state) — so the old
# resolution inspected MAIN and fired a bogus checkout-drift block. The fix
# retargets to the worktree (same repo: shared git common-dir, different
# toplevel), so the worktree's OWN gates govern. Its own isolated repo so MAIN's
# sibling state is exactly the drift trigger and nothing else interferes.
WARN="$HOOKS/warn-checkout-drift.sh"
INJECT="$HOOKS/inject-history-reminder.sh"
WI="$(mktemp -d)"
(
  cd "$WI"
  git init -q; git config user.email t@t.t; git config user.name t; git checkout -q -b main
  printf 'x\n' > a.js; git add a.js; git commit -qm init
  # An ACTIVE run on ANOTHER branch recorded in MAIN's .auto-task/ — the drift trigger.
  mkdir -p .auto-task/feat/sibling
  cat > .auto-task/feat/sibling/STATE.json <<JSON
{"approved":true,"phase":"execute","expected_next_action":"auto-continue","branch":"feat/sibling","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
JSON
  git worktree add -q wt -b feat/iso >/dev/null 2>&1
) >/dev/null 2>&1
WIWT="$WI/wt"; WISD="$WIWT/.auto-task/feat/iso"; mkdir -p "$WISD"
WIB="$(git -C "$WIWT" rev-parse HEAD)"
RWISHA="$(git -C "$WIWT" diff $DIFF_FLAGS "$WIB" | git hash-object --stdin)"
# gate from the worktree; CPD pinned to MAIN; payload carries NO .cwd → op_cwd
# falls back to $PWD=worktree (exercises the $PWD signal path).
wigate(){ printf '%s' "$COMMIT" | ( cd "$WIWT" && CLAUDE_PROJECT_DIR="$WI" bash "$GATE" ) >/dev/null 2>&1; echo $?; }
# (A) gates-met worktree run → ALLOWED. Pre-fix: BLOCKED (2) by the bogus drift guard.
cat > "$WISD/STATE.json" <<JSON
{"approved":true,"phase":"gate-b","expected_next_action":"auto-continue","branch":"feat/iso","base":"$WIB","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":true,"tool":"skill:auto-task-code-review","clean_pass_after_last_fix":true,"reviewed_diff_sha":"$RWISHA"},
          "gate_b":{"passed":true}}}
JSON
expect "WT-iso-allow: gates-met commit ALLOWED (CPD=main, active sibling run)"  "$(wigate)" "0"
# (B) ungated worktree run → BLOCKED: gate enforcement survives the retarget.
cat > "$WISD/STATE.json" <<JSON
{"approved":true,"phase":"execute","expected_next_action":"auto-continue","branch":"feat/iso","base":"$WIB","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
JSON
expect "WT-iso-gate: ungated commit BLOCKED (retargeted, gates enforced)"       "$(wigate)" "2"
# (C) AC#8: retarget driven by the JSON .cwd field while the hook $PWD is neutral
# (a dir inside MAIN, which by itself resolves to MAIN → no retarget). Only .cwd
# points at the worktree, so an ALLOW here proves the .cwd signal path works.
NEUTRAL="$WI/neutral"; mkdir -p "$NEUTRAL"
CWDPAY="$(jq -nc --arg c "$WIWT" '{tool_input:{command:"git commit -m wip"}, cwd:$c}')"
wigateCwd(){ printf '%s' "$CWDPAY" | ( cd "$NEUTRAL" && CLAUDE_PROJECT_DIR="$WI" bash "$GATE" ) >/dev/null 2>&1; echo $?; }
cat > "$WISD/STATE.json" <<JSON
{"approved":true,"phase":"gate-b","expected_next_action":"auto-continue","branch":"feat/iso","base":"$WIB","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":true,"tool":"skill:auto-task-code-review","clean_pass_after_last_fix":true,"reviewed_diff_sha":"$RWISHA"},
          "gate_b":{"passed":true}}}
JSON
expect "WT-iso-cwd-allow: .cwd retarget ALLOWS gates-met (hook \$PWD neutral)"   "$(wigateCwd)" "0"
cat > "$WISD/STATE.json" <<JSON
{"approved":true,"phase":"execute","expected_next_action":"auto-continue","branch":"feat/iso","base":"$WIB","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
JSON
expect "WT-iso-cwd-gate: .cwd retarget BLOCKS ungated (hook \$PWD neutral)"      "$(wigateCwd)" "2"
# (D) warn/stop/inject on an ACTIVE worktree run (approved, not done). State from (C) is active.
wiwarn(){ local o; o="$( cd "$WIWT" && CLAUDE_PROJECT_DIR="$WI" bash "$WARN" </dev/null 2>&1 )"; [ -n "$o" ] && echo warn || echo silent; }
wistop(){ local o; o="$( cd "$WIWT" && CLAUDE_PROJECT_DIR="$WI" bash "$STOP" </dev/null 2>/dev/null )"; [ -z "$o" ] && { echo allow; return; }; printf '%s' "$o" | jq -r '.decision // "allow"' 2>/dev/null; }
# History reminder is opt-in (P1 fix): wired but gated by `history_reminder_enabled`
# (default false). Enabled → emits; disabled → silent. AUTO_TASK_HOME/…_SETTINGS_FILE
# make the settings lookup hermetic (never touches the real ~/.claude).
HR_ON="$WI/hr-on.json";  printf '{"history_reminder_enabled":true}\n'  > "$HR_ON"
HR_OFF="$WI/hr-off.json"; printf '{"history_reminder_enabled":false}\n' > "$HR_OFF"
wiinject(){    ( cd "$WIWT" && AUTO_TASK_HOME="$WI" AUTO_TASK_SETTINGS_FILE="$HR_ON"  CLAUDE_PROJECT_DIR="$WI" bash "$INJECT" </dev/null 2>/dev/null ); }
wiinjectOff(){ ( cd "$WIWT" && AUTO_TASK_HOME="$WI" AUTO_TASK_SETTINGS_FILE="$HR_OFF" CLAUDE_PROJECT_DIR="$WI" bash "$INJECT" </dev/null 2>/dev/null ); }
# AC#5: no bogus drift warning — the worktree branch owns the active run.
expect "WT-iso-warn: SILENT (no false drift warning)"                           "$(wiwarn)" "silent"
# AC#6: anti-stall restored — a mid-pipeline turn-end BLOCKS.
expect "WT-iso-stop: mid-pipeline turn-end BLOCKED (anti-stall restored)"        "$(wistop)" "block"
# AC#9: read-before-review reminder names the WORKTREE branch, not silent/main.
wiinj="$(wiinject)"; case "$wiinj" in *"feat/iso"*) wiinjr=ok ;; *) wiinjr="silent-or-wrong" ;; esac
expect "WT-iso-inject: history reminder names the worktree branch (enabled)"    "$wiinjr" "ok"
# P1 gate: the same hook stays SILENT when history_reminder_enabled is off (default).
wiinjOff="$(wiinjectOff)"; [ -z "$wiinjOff" ] && wiinjOffr=silent || wiinjOffr="leaked"
expect "WT-iso-inject-off: SILENT when history_reminder_enabled=false"          "$wiinjOffr" "silent"
# Nested-repo protection still holds from a MAIN-neutral cwd (different common-dir → no retarget).
NEST2="$WI/vendor/embedded"; mkdir -p "$NEST2"
( cd "$NEST2" && git init -q && git config user.email t@t.t && git config user.name t && printf 'z\n'>g && git add g && git commit -qm n ) >/dev/null 2>&1
# MAIN itself carries an ungated active run so honoring CPD (no retarget) BLOCKS.
mkdir -p "$WI/.auto-task/main"
cat > "$WI/.auto-task/main/STATE.json" <<JSON
{"approved":true,"phase":"execute","expected_next_action":"auto-continue","branch":"main","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
JSON
wigateNest(){ printf '%s' "$COMMIT" | ( cd "$NEST2" && CLAUDE_PROJECT_DIR="$WI" bash "$GATE" ) >/dev/null 2>&1; echo $?; }
expect "WT-iso-nested: nested repo honors CPD, NOT retargeted, BLOCKED"          "$(wigateNest)" "2"
git -C "$WI" worktree remove --force "$WIWT" >/dev/null 2>&1 || true
rm -rf "$WI"

echo "================ Checkout-drift guard (enforce-gates block + warn hook) ================"
# Runs in its OWN isolated checkout ($DT) — NOT the shared $T, whose .auto-task/
# holds sibling active STATE dirs (feat/widget etc.) that would otherwise register
# as spurious drift for the silent-case assertions.
WARN="$HOOKS/warn-checkout-drift.sh"
DT="$(mktemp -d)"
(
  cd "$DT"
  git init -q; git config user.email t@t.t; git config user.name t
  git checkout -q -b feat/active
  printf 'x\n' > a.js; git add a.js; git commit -qm init
  git checkout -q -b chore/unrelated   # the "drifted" branch: no state of its own
  git checkout -q feat/active
  mkdir -p .auto-task/feat/active
  # feat/active carries an ACTIVE, gates-MET (LIGHT, no base/sha → staleness skipped)
  # run: "active" so it triggers drift from another branch, "gates-met" so the
  # no-drift control asserts an ALLOW (0), not a normal-gate block.
  cat > .auto-task/feat/active/STATE.json <<EOF
{"approved":true,"phase":"review","expected_next_action":"auto-continue","branch":"feat/active","effort":{"tier":"light"},
 "gates":{"code_review":{"passed":true,"tool":"skill:auto-task-code-review","clean_pass_after_last_fix":true},
          "gate_b":{"passed":false,"skipped_reason":"tier=light"}}}
EOF
) >/dev/null 2>&1
# git shim with NO jq, so the jq-absent path is exercised while git still works.
JQLESS="$(mktemp -d)"; ln -s "$(command -v git)" "$JQLESS/git" 2>/dev/null || true
dgate(){ printf '%s' "$COMMIT" | ( cd "$DT" && CLAUDE_PROJECT_DIR="$DT" bash "$GATE" ) >/dev/null 2>&1; echo $?; }
dwarn(){ local o ec; o="$( cd "$DT" && CLAUDE_PROJECT_DIR="$DT" bash "$WARN" 2>&1 )"; ec=$?; if [ -n "$o" ]; then printf 'warn:%s\n' "$ec"; else printf 'silent:%s\n' "$ec"; fi; }
dwarnNoJq(){ local o ec; o="$( cd "$DT" && PATH="$JQLESS" CLAUDE_PROJECT_DIR="$DT" /bin/bash "$WARN" 2>&1 )"; ec=$?; if [ -n "$o" ]; then printf 'warn:%s\n' "$ec"; else printf 'silent:%s\n' "$ec"; fi; }

git -C "$DT" checkout -q chore/unrelated   # drifted: on a branch with no run, feat/active active
expect "Drift: commit BLOCKED on drifted checkout"        "$(dgate)"      "2"
expect "Drift: warn hook fires, exit 0"                   "$(dwarn)"      "warn:0"
expect "Drift: warn SILENT + exit 0 when jq absent"       "$(dwarnNoJq)"  "silent:0"
git -C "$DT" checkout -q feat/active        # current branch owns the active (gates-met) run
expect "No-drift: gates-met commit ALLOWED (not drift-blocked)" "$(dgate)" "0"
expect "No-drift: warn SILENT on the active branch"       "$(dwarn)"      "silent:0"
# Malformed sibling state must not crash the warn hook (it is skipped → silent).
echo '{bad json' > "$DT/.auto-task/feat/active/STATE.json"
git -C "$DT" checkout -q chore/unrelated
expect "Malformed sibling state: warn exits 0 (no crash)" "$(dwarn)"      "silent:0"
# A repo with no .auto-task/ at all → warn stays silent (non-auto-task session).
DT2="$(mktemp -d)"
( cd "$DT2" && git init -q && git config user.email t@t.t && git config user.name t && git checkout -q -b solo && printf 'y\n' > f && git add f && git commit -qm i ) >/dev/null 2>&1
dwarn2(){ local o ec; o="$( cd "$DT2" && CLAUDE_PROJECT_DIR="$DT2" bash "$WARN" 2>&1 )"; ec=$?; if [ -n "$o" ]; then printf 'warn:%s\n' "$ec"; else printf 'silent:%s\n' "$ec"; fi; }
expect "No .auto-task/: warn SILENT (non-auto-task repo)"  "$(dwarn2)"     "silent:0"
rm -rf "$DT" "$DT2" "$JQLESS"

echo "================ check-version.sh --plain (per-run version check) ================"
CV="$HOOKS/check-version.sh"
PR="$(mktemp -d)"; mkdir -p "$PR/.claude-plugin" "$PR/data"; printf '{"version":"0.1.6"}' > "$PR/.claude-plugin/plugin.json"
# cvr <remote-version> [plain]: run check-version.sh against a known local 0.1.6, throttle bypassed.
# Env is set INSIDE the function body (not as a prefix to the function) so it reliably reaches the
# child bash; the optional second arg selects plain mode without clobbering the no-arg default path.
cvr(){ CLAUDE_PLUGIN_ROOT="$PR" CLAUDE_PLUGIN_DATA="$PR/data" AUTO_TASK_SKIP_THROTTLE=1 AUTO_TASK_REMOTE_VERSION="$1" bash "$CV" ${2:+--plain}; }
o="$(cvr 9.9.9 plain)"; m=other; case "$o" in *'is available'*) m=plain ;; esac; case "$o" in *hookSpecificOutput*|*'{'*) m=json ;; esac
expect "CV-plain-behind: bare line, not JSON"               "$m" "plain"
expect "CV-plain-current: silent"                           "$(cvr 0.1.6 plain)" ""
expect "CV-plain-ahead: silent"                             "$(cvr 0.0.1 plain)" ""
ou="$(CLAUDE_PLUGIN_ROOT="$PR" CLAUDE_PLUGIN_DATA="$PR/data" AUTO_TASK_SKIP_THROTTLE=1 AUTO_TASK_VERSION_URL=http://127.0.0.1:9/x bash "$CV" --plain)"; eu=$?
expect "CV-plain-unreachable: silent + exit 0"              "$ou:$eu" ":0"
od="$(cvr 9.9.9)"; d=other; case "$od" in *hookSpecificOutput*) d=json ;; esac
expect "CV-default-json: SessionStart JSON intact"          "$d" "json"
rm -f "$PR/data/.last-version-check"; cvr 9.9.9 plain >/dev/null; [ -f "$PR/data/.last-version-check" ] && s=present || s=absent
expect "CV-stamp-untouched: skip-throttle writes no stamp"  "$s" "absent"
rm -rf "$PR"

# ============================================================================
# Merge gate (v0.22): enforce-gates blocks a LAND action (git push / merge) when
# gates.merge.required && !acked. Covers push-on-run-branch AND direct-to-main.
# ============================================================================
PUSH='{"tool_input":{"command":"git push -u origin HEAD"}}'
MERGE='{"tool_input":{"command":"git merge feat/widget"}}'
# ensure we are on the run branch with its state file
git checkout -q feat/widget
printf '%s' '{"approved":true,"phase":"handover","gates":{"merge":{"required":true,"acked":false}}}' > "$ST"
expect "MG push: required+unacked -> block(2)"     "$(grun "$PUSH")"  "2"
printf '%s' '{"approved":true,"phase":"handover","gates":{"merge":{"required":true,"acked":true}}}' > "$ST"
expect "MG push: acked -> allow(0)"                "$(grun "$PUSH")"  "0"
printf '%s' '{"approved":true,"phase":"handover","gates":{"merge":{"required":false,"acked":false}}}' > "$ST"
expect "MG push: not required -> allow(0)"         "$(grun "$PUSH")"  "0"
# a run with no merge object at all (legacy) -> land allowed
printf '%s' '{"approved":true,"phase":"handover","gates":{}}' > "$ST"
expect "MG push: legacy no-merge-obj -> allow(0)"  "$(grun "$PUSH")"  "0"

# direct-to-main: checkout the base branch; run still lives on feat/widget
BASEBR="$(git rev-parse --abbrev-ref HEAD)"    # currently feat/widget
DEF="master"; git rev-parse --verify -q main >/dev/null 2>&1 && DEF="main"
git checkout -q "$DEF" 2>/dev/null || git checkout -q -b "$DEF"
printf '%s' '{"approved":true,"phase":"handover","gates":{"merge":{"required":true,"acked":false}}}' > "$ST"
expect "MG on-main merge run-branch: unacked -> block(2)" "$(grun "$MERGE")" "2"
expect "MG on-main push: active run unacked -> block(2)"  "$(grun "$PUSH")"  "2"
printf '%s' '{"approved":true,"phase":"handover","gates":{"merge":{"required":true,"acked":true}}}' > "$ST"
expect "MG on-main merge: acked -> allow(0)"       "$(grun "$MERGE")" "0"
# no active run anywhere -> land allowed
printf '%s' '{"approved":true,"phase":"done","gates":{"merge":{"required":true,"acked":false}}}' > "$ST"
expect "MG on-main: run is done -> allow(0)"       "$(grun "$MERGE")" "0"
git checkout -q feat/widget

# B1 regression: a chained `git commit && git push` must NOT bypass the commit gate
# via the land block. Commit gate not passed + merge not required -> still blocked.
CP='{"tool_input":{"command":"git commit -m x && git push origin HEAD"}}'
printf '%s' '{"approved":true,"phase":"handover","gates":{"code_review":{"passed":false},"merge":{"required":false,"acked":false}}}' > "$ST"
expect "B1 commit&&push, review not passed -> block(2)" "$(grun "$CP")" "2"
# same chain with gates passed -> allowed
printf '%s' '{"approved":true,"phase":"handover","gates":{"code_review":{"passed":true,"tool":"skill:auto-task-code-review","clean_pass_after_last_fix":true},"gate_b":{"passed":true},"merge":{"required":false,"acked":false}}}' > "$ST"
expect "B1 commit&&push, gates passed -> allow(0)"      "$(grun "$CP")" "0"

# Gate B: `gh pr merge` (the landing_model=pr land action) is gated by the merge gate
GHM='{"tool_input":{"command":"gh pr merge 12 --squash --delete-branch"}}'
printf '%s' '{"approved":true,"phase":"handover","landing":"pr","gates":{"merge":{"required":true,"acked":false}}}' > "$ST"
expect "MG gh pr merge, required+unacked -> block(2)" "$(grun "$GHM")" "2"
printf '%s' '{"approved":true,"phase":"handover","landing":"pr","gates":{"merge":{"required":true,"acked":true}}}' > "$ST"
expect "MG gh pr merge, acked -> allow(0)"            "$(grun "$GHM")" "0"

echo
echo "================ Fix-loop budget (anti-churn) ================"

# The effort tier has always documented a fix-loop cap and NOTHING enforced it: a real
# run reached iteration.fix=33 against a HEAVY cap of 6 (5.5x over) because this hook
# never read the counter, and the Stop hook read it only to detect movement, never
# magnitude. The plugin had a rigorous anti-stall guard and no anti-churn guard at all.
# Caps live in hooks/lib/loop-budget.sh so the two enforcing hooks cannot drift.

LB_GATES='"code_review":{"passed":true,"tool":"skill:auto-task-code-review","clean_pass_after_last_fix":true},"gate_b":{"passed":true}'
# lbstate <tier> <fix> <acked|empty for no loop_budget object>
lbstate(){ local lb=""; [ -n "$3" ] && lb="\"loop_budget\":{\"acked_through\":$3},"
  printf '{"phase":"review","approved":true,"expected_next_action":"auto-continue","effort":{"tier":"%s"},"iteration":{"fix":%s,"review":1},"gates":{%s%s}}' \
    "$1" "$2" "$lb" "$LB_GATES" > "$ST"; }
lberr(){ printf '%s' "$COMMIT" | CLAUDE_PROJECT_DIR="$T" bash "$GATE" 2>&1 >/dev/null; }

# --- the block fires, and its message is actionable -------------------------
lbstate heavy 7 ""
expect "LB heavy fix=7 no ack -> block(2)"              "$(gate)" "2"
LBE="$(lberr)"
expect "LB msg names the loop count"                    "$(printf '%s' "$LBE" | grep -qF 'loop count:      7' && echo y || echo n)" "y"
expect "LB msg names BOTH counters it maxed"            "$(printf '%s' "$LBE" | grep -qF 'max of iteration.fix=7 and iteration.review=1' && echo y || echo n)" "y"
expect "LB msg names the tier cap"                      "$(printf '%s' "$LBE" | grep -qF 'cap:     6' && echo y || echo n)" "y"
# The ack wording must describe what lb_next_budget actually does. It used to say
# "raises the budget by one cap" while stepping to the first rung that clears the
# counter - at heavy/fix=33 that is a five-cap jump, so the sentence was false.
expect "LB msg describes the rung-clearing ack"         "$(printf '%s' "$LBE" | grep -qF 'next cap rung that clears the current count' && echo y || echo n)" "y"
expect "LB msg does NOT claim a one-cap raise"          "$(printf '%s' "$LBE" | grep -qF 'raises the budget by one cap' && echo y || echo n)" "n"
expect "LB msg names the budget in force"               "$(printf '%s' "$LBE" | grep -qF 'budget in force: 6' && echo y || echo n)" "y"
expect "LB msg carries the jq ack snippet"              "$(printf '%s' "$LBE" | grep -qF 'gates.loop_budget = {acked_through: 12' && echo y || echo n)" "y"
expect "LB msg says the ack is the user's call"         "$(printf '%s' "$LBE" | grep -qF "user's call" && echo y || echo n)" "y"

# --- the ack ladder: budget = max(cap, acked_through), block on >, ack adds a cap.
# HEAVY cap 6 -> budgets 6/12/18, so the check-ins land at fix 7/13/19.
lbstate heavy 6  "";   expect "LB fix=6 == cap -> allow(0) (equal is not over)"    "$(gate)" "0"
lbstate heavy 7  "";   expect "LB fix=7 > cap -> block(2)"                         "$(gate)" "2"
lbstate heavy 7  12;   expect "LB fix=7 acked=12 -> allow(0)"                      "$(gate)" "0"
lbstate heavy 12 12;   expect "LB fix=12 == budget -> allow(0)"                    "$(gate)" "0"
lbstate heavy 13 12;   expect "LB fix=13 > budget -> block(2) (check-in returns)"  "$(gate)" "2"
lbstate heavy 13 18;   expect "LB fix=13 acked=18 -> allow(0)"                     "$(gate)" "0"
# a stale ack BELOW the cap must not lower the budget (tier-escalation safety)
lbstate heavy 5  2;    expect "LB stale ack(2) < cap(6): max() keeps budget"       "$(gate)" "0"

# --- BOTH counters are in force: the budget is max(fix, review) -------------
# iteration.fix is bumped only on the Phase-3 self-verify failure path; every Phase-4
# review round and Gate-B feedback round bumps iteration.review instead. A gate reading
# fix alone lets the churn shape this feature exists to bound (fix=0/review=28) land
# unblocked, while the docs call the cap "a hook-enforced budget, not a suggestion".
# lbstate2 <tier> <fix> <review> <acked|empty>
lbstate2(){ local lb=""; [ -n "$4" ] && lb="\"loop_budget\":{\"acked_through\":$4},"
  printf '{"phase":"review","approved":true,"expected_next_action":"auto-continue","effort":{"tier":"%s"},"iteration":{"fix":%s,"review":%s},"gates":{%s%s}}' \
    "$1" "$2" "$3" "$lb" "$LB_GATES" > "$ST"; }
lbstate2 heavy 0 28 "";  expect "LB review=28 fix=0 -> block(2) (the motivating shape)" "$(gate)" "2"
lbstate2 heavy 0 7  "";  expect "LB review=7 > cap -> block(2)"                         "$(gate)" "2"
lbstate2 heavy 0 6  "";  expect "LB review=6 == cap -> allow(0)"                        "$(gate)" "0"
lbstate2 heavy 7 0  "";  expect "LB fix drives it too (fix=7, review=0) -> block(2)"    "$(gate)" "2"
lbstate2 heavy 5 5  "";  expect "LB max not sum: 5+5 but max=5 <= cap -> allow(0)"      "$(gate)" "0"
lbstate2 heavy 0 28 30;  expect "LB review=28 acked=30 -> allow(0)"                     "$(gate)" "0"
LBR="$(lbstate2 heavy 2 28 "" ; lberr)"
expect "LB msg reports the review counter as the driver" "$(printf '%s' "$LBR" | grep -qF 'max of iteration.fix=2 and iteration.review=28' && echo y || echo n)" "y"
expect "LB  ...and one ack clears it (rung 30, not 12)"  "$(printf '%s' "$LBR" | grep -qF 'acked_through: 30' && echo y || echo n)" "y"
# an absent sibling counter reads as 0, it does not disable the gate
printf '{"phase":"review","approved":true,"effort":{"tier":"heavy"},"iteration":{"fix":7},"gates":{%s}}' "$LB_GATES" > "$ST"
expect "LB iteration.review absent, fix over -> block(2)"  "$(gate)" "2"
printf '{"phase":"review","approved":true,"effort":{"tier":"heavy"},"iteration":{"review":7},"gates":{%s}}' "$LB_GATES" > "$ST"
expect "LB iteration.fix absent, review over -> block(2)"  "$(gate)" "2"
printf '{"phase":"review","approved":true,"effort":{"tier":"heavy"},"iteration":{"review":"abc"},"gates":{%s}}' "$LB_GATES" > "$ST"
expect "LB non-numeric iteration.review -> block(2), fail closed" "$(gate)" "2"

# --- per-tier caps come from the shared lib --------------------------------
lbstate light    3 ""; expect "LB tier=light cap2, fix=3 -> block(2)"     "$(gate)" "2"
lbstate light    2 ""; expect "LB tier=light cap2, fix=2 -> allow(0)"     "$(gate)" "0"
lbstate standard 5 ""; expect "LB tier=standard cap4, fix=5 -> block(2)"  "$(gate)" "2"
lbstate standard 4 ""; expect "LB tier=standard cap4, fix=4 -> allow(0)"  "$(gate)" "0"

# --- quiet paths: the budget gate must not fire here -----------------------
printf '{"phase":"done","approved":true,"effort":{"tier":"heavy"},"iteration":{"fix":99},"gates":{%s}}' "$LB_GATES" > "$ST"
expect "LB phase=done -> allow(0)"                       "$(gate)" "0"
printf '{"phase":"review","approved":false,"effort":{"tier":"heavy"},"iteration":{"fix":99},"gates":{%s}}' "$LB_GATES" > "$ST"
expect "LB approved=false -> allow(0)"                   "$(gate)" "0"
printf '{"phase":"review","approved":true,"iteration":{"fix":99},"gates":{%s}}' "$LB_GATES" > "$ST"
expect "LB legacy run, no effort object -> allow(0)"     "$(gate)" "0"
printf '{"phase":"review","approved":true,"effort":{},"iteration":{"fix":99},"gates":{%s}}' "$LB_GATES" > "$ST"
expect "LB effort.tier absent -> allow(0)"               "$(gate)" "0"
printf '{"phase":"review","approved":true,"effort":{"tier":"heavy"},"gates":{%s}}' "$LB_GATES" > "$ST"
expect "LB iteration absent -> allow(0)"                 "$(gate)" "0"

# --- fail CLOSED on a corrupt counter -------------------------------------
# `[ "abc" -gt 6 ]` does not evaluate false, it ERRORS - so an unguarded `if` takes the
# else branch and the guard would fail OPEN inside a hook documented fail-CLOSED.
printf '{"phase":"review","approved":true,"effort":{"tier":"heavy"},"iteration":{"fix":"abc"},"gates":{%s}}' "$LB_GATES" > "$ST"
expect "LB non-numeric iteration.fix -> block(2), fail closed" "$(gate)" "2"
# Capture into a var BEFORE grepping: `set -o pipefail` is on and lberr's exit
# status is the hook's 2 (blocked), so `lberr | grep -q` would report failure even
# when the pattern matched. This bit two assertions here.
LBE2="$(lberr)"
expect "LB  ...and says why"                             "$(printf '%s' "$LBE2" | grep -qF 'not a non-negative integer' && echo y || echo n)" "y"
# MAGNITUDE, not just character class. `[ 99999999999999999999 -gt 6 ]` is all digits
# and STILL errors ("integer expression expected"), reproducing the same fail-OPEN the
# "abc" case above closes - a 20-digit counter walked straight past this gate.
printf '{"phase":"review","approved":true,"effort":{"tier":"heavy"},"iteration":{"fix":99999999999999999999},"gates":{%s}}' "$LB_GATES" > "$ST"
expect "LB huge iteration.fix -> block(2), not fail-open" "$(gate)" "2"
printf '{"phase":"review","approved":true,"effort":{"tier":"heavy"},"iteration":{"fix":0,"review":99999999999999999999},"gates":{%s}}' "$LB_GATES" > "$ST"
expect "LB huge iteration.review -> block(2)"            "$(gate)" "2"
printf '{"phase":"review","approved":true,"effort":{"tier":"heavy"},"iteration":{"fix":7},"gates":{"loop_budget":{"acked_through":99999999999999999999},%s}}' "$LB_GATES" > "$ST"
expect "LB huge acked_through -> block(2)"               "$(gate)" "2"
# ...and the block is not raw shell noise: it names the field, like every other block.
LBE2b="$(lberr)"
expect "LB  ...huge value block names the field"         "$(printf '%s' "$LBE2b" | grep -qF 'acked_through in .auto-task' && echo y || echo n)" "y"
# A zero-padded counter is accepted by the character-class check and compares fine in
# `[ ]`, but `$(( 09 ))` is octal and fatal - so the ack snippet the block prints must
# still be VALID jq with a real number, and stderr must carry no arithmetic error.
printf '{"phase":"review","approved":true,"effort":{"tier":"heavy"},"iteration":{"fix":"09"},"gates":{%s}}' "$LB_GATES" > "$ST"
expect "LB zero-padded counter -> block(2)"              "$(gate)" "2"
LBE2c="$(lberr)"
expect "LB  ...ack snippet carries a real number"        "$(printf '%s' "$LBE2c" | grep -qE 'acked_through: [0-9]+' && echo y || echo n)" "y"
expect "LB  ...and no octal arithmetic error leaks"      "$(printf '%s' "$LBE2c" | grep -c 'too great for base')" "0"
printf '{"phase":"review","approved":true,"effort":{"tier":"heavy"},"iteration":{"fix":7},"gates":{"loop_budget":{"acked_through":"x"},%s}}' "$LB_GATES" > "$ST"
expect "LB non-numeric acked_through -> block(2)"        "$(gate)" "2"

# The ack the block PRINTS must be a value this same hook will ACCEPT next run.
# lb_is_number bounds an input at 18 digits, but the rung computed for an 18-digit
# counter is 19 - so the recovery snippet used to advise a value the validator then
# rejected, dead-ending the documented recovery (the class lb_strip_zeros exists to
# prevent). Now such a counter is named as the corruption it is.
printf '{"phase":"review","approved":true,"effort":{"tier":"heavy"},"iteration":{"fix":999999999999999999},"gates":{%s}}' "$LB_GATES" > "$ST"
expect "LB 18-digit counter -> block(2)"                 "$(gate)" "2"
LBE2d="$(lberr)"
expect "LB  ...names the counter as implausible"         "$(printf '%s' "$LBE2d" | grep -qF 'implausibly large' && echo y || echo n)" "y"
expect "LB  ...and prints NO un-ackable ack value"       "$(printf '%s' "$LBE2d" | grep -c 'acked_through: [0-9]\{19,\}')" "0"
# ...while ordinary counters still print a usable, re-acceptable ack.
lbstate heavy 33 ""
LBE2e="$(lberr)"
expect "LB normal counter still prints its ack"          "$(printf '%s' "$LBE2e" | grep -qF 'acked_through: 36' && echo y || echo n)" "y"
expect "LB  ...and that ack is itself valid input"       "$(bash -c ". '$HOOKS/lib/loop-budget.sh'; lb_is_number 36 && echo y || echo n")" "y"
# The printed recovery must not funnel two parallel runs through one global temp path:
# both pasting `> /tmp/s && mv /tmp/s <state>` can move run B's STATE.json onto run A's.
expect "LB ack snippet uses mktemp, not a fixed path"    "$(printf '%s' "$LBE2e" | grep -c '> /tmp/s')" "0"
# ...and its TARGET is absolute too (FU-LB13). A relative .auto-task/<branch>/ path is
# the same two-runs-one-path hazard as the temp file: pasted from a subdirectory the jq
# leg just fails, but pasted from a different checkout sharing the branch name it writes
# the ack to the wrong run's state. The hook already holds the absolute path in $state.
# Asserted on the PROPERTY (leading /), not on a literal path: the hook resolves
# project_dir through `git rev-parse --show-toplevel`, which on macOS returns the
# /private-prefixed form of $TMPDIR, so a literal comparison would be fragile for a
# reason unrelated to what is being pinned.
expect "LB ack snippet targets an absolute state path"   "$(printf '%s' "$LBE2e" | grep -qE "' /[^ ]*/STATE\.json > " && echo y || echo n)" "y"
expect "LB  ...and mv restores it to that same path"     "$(printf '%s' "$LBE2e" | grep -qE "mv \"\\\$t\" /[^ ]*/STATE\.json" && echo y || echo n)" "y"
expect "LB  ...with no relative .auto-task target left"  "$(printf '%s' "$LBE2e" | grep -c 'mv "\$t" \.auto-task/')" "0"
expect "LB  ...and routes through \$t"                   "$(printf '%s' "$LBE2e" | grep -qF 'mktemp' && echo y || echo n)" "y"

# --- precedence: the primary gate contract reports before the budget ------
printf '{"phase":"review","approved":true,"effort":{"tier":"heavy"},"iteration":{"fix":99},"gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}' > "$ST"
LBE3="$(lberr)"
expect "LB review-not-passed reports first"              "$(printf '%s' "$LBE3" | grep -qF 'code-review loop has passed' && echo y || echo n)" "y"
expect "LB  ...and the budget message is NOT shown"      "$(printf '%s' "$LBE3" | grep -qF 'over its fix-loop budget' && echo y || echo n)" "n"

echo
echo "================ Fix-loop budget - Stop-hook release ================"

# The release is a backstop, not a precondition for surfacing: the hook already exits 0
# on expected_next_action=user-approval, which the ack ritual tells the model to set. What
# these assertions pin is the behavior for a run that never updated the field. This is the
# mirror of the soft-lock breaker: that releases on too LITTLE progress, this on too MUCH
# volume.
LBMARK="$SD/.loop-budget-released"
lbclean(){ rm -f "$LBMARK" "$SD/.stall-block-count"; }
sstate(){ local lb=""; [ -n "$3" ] && lb="\"loop_budget\":{\"acked_through\":$3},"
  printf '{"phase":"review","approved":true,"expected_next_action":"auto-continue","base":"%s","effort":{"tier":"%s"},"iteration":{"fix":%s,"review":1},"gates":{%s"code_review":{"reviewed_diff_sha":"s"}}}' \
    "$BASE" "$1" "$2" "$lb" > "$ST"; }
swarn(){ CLAUDE_PROJECT_DIR="$T" bash "$STOP" </dev/null 2>&1 >/dev/null; }

# CONTROL FIRST: under budget must still BLOCK, otherwise "allow" proves nothing.
lbclean; sstate heavy 3 ""
expect "LBS control: under budget still blocks"          "$(stop)" "block"
# One invocation, both streams: the release fires ONCE per iteration count, so a
# second call at the same count correctly produces no warning. Reading the decision
# and the warning from separate invocations would have tested the wrong thing.
lbclean; sstate heavy 7 ""
LBSOUT="$(CLAUDE_PROJECT_DIR="$T" bash "$STOP" </dev/null 2>"$T/lbs.err")"
expect "LBS over budget releases the turn-end"           "$([ -z "$LBSOUT" ] && echo allow || printf '%s' "$LBSOUT" | jq -r '.decision // "allow"')" "allow"
expect "LBS  ...and warns naming the budget"             "$(grep -qF 'loop budget' "$T/lbs.err" && echo y || echo n)" "y"
# stderr alone is NOT delivery: on an ALLOW a Stop hook has no guaranteed model-facing
# channel (only a block is fed back), so the notice also goes out as a systemMessage -
# the field check-version.sh/release-notes.sh/suggest-cleanup.sh already use. Carries no
# `decision`, so the stop is still allowed.
expect "LBS  ...and surfaces via systemMessage too"      "$(printf '%s' "$LBSOUT" | jq -r '.systemMessage // ""' 2>/dev/null | grep -qF 'loop budget' && echo y || echo n)" "y"
expect "LBS  ...without turning the release into a block" "$([ -z "$LBSOUT" ] && echo allow || printf '%s' "$LBSOUT" | jq -r '.decision // "allow"' 2>/dev/null)" "allow"
# ONCE per iteration count - a second turn-end at the same fix blocks again.
expect "LBS 2nd turn-end at same fix -> block"           "$(stop)" "block"
expect "LBS 3rd turn-end at same fix -> block"           "$(stop)" "block"
sstate heavy 8 ""
expect "LBS new iteration count releases once more"      "$(stop)" "allow"
expect "LBS  ...then blocks again at that count"         "$(stop)" "block"
# after the ack raises the budget, no release
lbclean; sstate heavy 8 12
expect "LBS acked (budget 12), fix=8 -> block"           "$(stop)" "block"
# the soft-lock counter must KEEP accumulating across releases - an earlier draft
# deleted it, which would have stopped AUTO_TASK_STALL_LIMIT ever firing.
# Assert on the RELEASE turn itself. An earlier version of this test only checked the
# count after three turn-ends, which a deleting release masks: it removes turn 1's
# count, and turns 2-3 (which do not release) rebuild it past the threshold. Mutation
# testing caught that — the deletion mutant stayed green.
lbclean; sstate heavy 7 ""
stop >/dev/null                                   # the one turn-end that releases
expect "LBS release does NOT delete the soft-lock counter" "$([ -f "$SD/.stall-block-count" ] && echo y || echo n)" "y"
expect "LBS  ...and the count survives that turn"          "$(cut -d'|' -f1 "$SD/.stall-block-count" 2>/dev/null)" "1"
stop >/dev/null; stop >/dev/null
expect "LBS soft-lock counter keeps accumulating"          "$([ "$(cut -d'|' -f1 "$SD/.stall-block-count" 2>/dev/null)" -gt 1 ] && echo y || echo n)" "y"
# The release must measure the SAME loop count the gate blocks on - max(fix, review).
# If it read fix alone, a review-heavy run (fix=0/review=28) would have its commit
# blocked by enforce-gates.sh while never getting the turn-end it needs to surface the
# check-in: the two halves of the feature would disagree and the run would soft-lock.
sstate2(){ local lb=""; [ -n "$4" ] && lb="\"loop_budget\":{\"acked_through\":$4},"
  printf '{"phase":"review","approved":true,"expected_next_action":"auto-continue","base":"%s","effort":{"tier":"%s"},"iteration":{"fix":%s,"review":%s},"gates":{%s"code_review":{"reviewed_diff_sha":"s"}}}' \
    "$BASE" "$1" "$2" "$3" "$lb" > "$ST"; }
lbclean; sstate2 heavy 0 28 ""
LBSOUT2="$(CLAUDE_PROJECT_DIR="$T" bash "$STOP" </dev/null 2>"$T/lbs2.err")"
expect "LBS review-driven overage releases too"          "$([ -z "$LBSOUT2" ] && echo allow || printf '%s' "$LBSOUT2" | jq -r '.decision // "allow"')" "allow"
expect "LBS  ...and the warning names both counters"     "$(grep -qF 'iteration.fix=0 and iteration.review=28' "$T/lbs2.err" && echo y || echo n)" "y"
expect "LBS  ...once only, at that loop count"           "$(stop)" "block"
lbclean; sstate2 heavy 0 6 ""
expect "LBS review == cap -> no release, block"          "$(stop)" "block"
# The ack itself is PROGRESS. `gates.loop_budget.acked_through` joins the anti-stall
# signature for one narrow reason: a turn whose ONLY action is recording the user's
# over-budget ack leaves every other signature field constant, so without it that turn
# is counted as another frozen turn-end and pushes the run toward a spurious
# AUTO_TASK_STALL_LIMIT force-release. Asserted behaviorally (counter resets), because
# a grep on the jq line would pass on a sig that never reads the value. Mutation-tested:
# deleting the field from the sig reds this assertion and nothing else in the suite.
lbclean; sstate2 heavy 3 1 ""
stop >/dev/null; stop >/dev/null; stop >/dev/null
expect "LBS stall counter accumulated before the ack"    "$(cut -d'|' -f1 "$SD/.stall-block-count" 2>/dev/null)" "3"
sstate2 heavy 3 1 12
stop >/dev/null
expect "LBS an ack-only turn RESETS the stall counter"   "$(cut -d'|' -f1 "$SD/.stall-block-count" 2>/dev/null)" "1"

# PARITY WITH THE GATE, on the states where the two used to diverge. The gate treats an
# absent sibling counter as 0 and an empty-string tier as tier-present (cap 4); this
# hook must agree, or a run is refused a landing with no released turn-end and no
# in-band warning. Every fixture above writes BOTH counters, so these shapes are the
# only ones that can catch it - an earlier draft passed the whole suite while diverging.
lbstall(){ printf '{"phase":"review","approved":true,"expected_next_action":"auto-continue","base":"%s","effort":{"tier":"%s"},"iteration":%s,"gates":{"code_review":{"reviewed_diff_sha":"s"}}}' "$BASE" "$1" "$2" > "$ST"; }
lbclean; lbstall heavy '{"review":28}'
expect "LBS fix absent, review over -> release"          "$(stop)" "allow"
lbclean; lbstall heavy '{"fix":null,"review":28}'
expect "LBS fix null, review over -> release"            "$(stop)" "allow"
lbclean; lbstall heavy '{"fix":28}'
expect "LBS review absent, fix over -> release"          "$(stop)" "allow"
lbclean; lbstall "" '{"fix":28}'
expect "LBS empty tier (gate uses cap 4) -> release"     "$(stop)" "allow"
lbclean; lbstall heavy '{"fix":1,"review":1}'
expect "LBS  ...control: under budget still blocks"      "$(stop)" "block"
lbclean; sstate2 heavy 0 28 30
expect "LBS review acked past -> no release, block"      "$(stop)" "block"
# legacy / corrupt -> no release, normal block. This hook is fail-OPEN, so silence
# from the budget branch means "let the existing logic decide", not "allow".
lbclean
printf '{"phase":"review","approved":true,"expected_next_action":"auto-continue","base":"%s","iteration":{"fix":99},"gates":{}}' "$BASE" > "$ST"
expect "LBS legacy (no effort.tier) -> block, no release" "$(stop)" "block"
printf '{"phase":"review","approved":true,"expected_next_action":"auto-continue","base":"%s","effort":{"tier":"heavy"},"iteration":{"fix":"abc"},"gates":{}}' "$BASE" > "$ST"
expect "LBS non-numeric fix -> block, no release"        "$(stop)" "block"
# user gates still yield
printf '{"phase":"review","approved":true,"expected_next_action":"user-approval","base":"%s","effort":{"tier":"heavy"},"iteration":{"fix":99},"gates":{}}' "$BASE" > "$ST"
expect "LBS user-approval still allowed"                 "$(stop)" "allow"
# fail-OPEN on malformed JSON, with the warning as the POSITIVE discriminator: a
# crashed hook or a broken harness also produces no block, so "allow" alone is weak.
printf '{not json' > "$ST"
expect "LBS malformed JSON -> allow (fail open)"         "$(stop)" "allow"
SWERR="$(swarn)"
expect "LBS  ...and the fail-open warning is emitted"    "$(printf '%s' "$SWERR" | grep -qF 'not valid JSON' && echo y || echo n)" "y"

echo
echo "================ Fix-loop budget - review fixes ================"
RLIB="$HOOKS/lib/loop-budget.sh"
nb(){ bash -c ". '$RLIB'; lb_next_budget $*"; }

# --- R1: ONE ack must clear the block, however far past budget the run is ----
# The gate runs at COMMIT time while iteration.fix accumulates during the fix loop, so
# a run arrives here already far past its budget. lb_next_budget used to step a single
# cap regardless of position, which demanded one ack per cap of overshoot: a HEAVY run
# at fix=33 needed FIVE (12, 18, 24, 30, 36), each asking the user to approve budget
# already spent, and each block announcing a check-in point already in the past.
lbstate heavy 33 ""
expect "R1 heavy fix=33 no ack -> block"                 "$(gate)" "2"
LBE33="$(lberr)"
expect "R1  ...ack clears it in ONE step (not 12)"       "$(printf '%s' "$LBE33" | grep -o 'acked_through: [0-9]*' | head -1)" "acked_through: 36"
expect "R1  ...and the promised check-in is AHEAD of 33" "$(printf '%s' "$LBE33" | grep -o 'next check-in is at [0-9]*' | head -1)" "next check-in is at 37"
lbstate heavy 33 36
expect "R1  ...and that single ack really allows it"     "$(gate)" "0"

# The documented ladder must be UNCHANGED where a run meets the gate one past budget:
# HEAVY budgets 6/12/18/24, check-ins at fix 7/13/19/25.
expect "R1 ladder rung 1 unchanged (fix=7 -> 12)"        "$(nb 6 0 7)"    "12"
expect "R1 ladder rung 2 unchanged (fix=13 -> 18)"       "$(nb 6 12 13)"  "18"
expect "R1 ladder rung 3 unchanged (fix=19 -> 24)"       "$(nb 6 18 19)"  "24"
expect "R1 far overshoot steps in whole caps (33 -> 36)" "$(nb 6 0 33)"   "36"
expect "R1 light cap2 overshoot (fix=9 -> 10)"           "$(nb 2 0 9)"    "10"
expect "R1 standard cap4 overshoot (fix=17 -> 20)"       "$(nb 4 0 17)"   "20"
# back-compat + sanitization: a caller with no position, or a garbage one, gets the old
# single-step answer rather than an error or a wild number.
expect "R1 fix omitted -> old single-step result"        "$(nb 6 0)"      "12"
expect "R1 non-numeric fix ignored"                      "$(nb 6 0 abc)"  "12"
expect "R1 an ack always RAISES (fix well under budget)" "$(nb 6 0 3)"    "12"

# --- R3: a failed marker write must not turn the release sticky --------------
# It was `> marker || true` then an unconditional exit 0, so an unwritable directory
# converted "release once per count" into "release every turn" - exactly the hole the
# marker exists to prevent. Falling through to the block is pre-existing behavior, so
# gating the release on the write costs no soft-lock risk.
lbclean; sstate heavy 7 ""
chmod a-w "$SD"
R3A="$(stop)"; R3B="$(stop)"; R3C="$(stop)"
chmod u+w "$SD"
expect "R3 unwritable marker: turn 1 blocks (no release)" "$R3A" "block"
expect "R3  ...turn 2 blocks"                             "$R3B" "block"
expect "R3  ...turn 3 blocks (not sticky)"                "$R3C" "block"
# CONTROL: the same sequence in a writable dir must still release exactly once, else
# the three assertions above would pass on a hook that never releases at all.
lbclean; sstate heavy 7 ""
expect "R3 control: writable dir releases once"           "$(stop)" "allow"
expect "R3 control:  ...then blocks"                      "$(stop)" "block"

# --- R4: the marker must be run-scoped by base ------------------------------
# .stall-block-count is run-scoped (.base leads its signature) and record-outcome.sh
# keys its sentinel by base for the same reason. The marker was the only per-run file
# that was not, so residue from a prior run in a reused .auto-task/<branch>/ folder
# swallowed a new run's release AND its stderr warning - the only in-band notice.
lbclean; printf 'B_OLD|7\n' > "$LBMARK"
sstate heavy 7 ""
R4OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$STOP" </dev/null 2>"$T/r4.err")"
expect "R4 prior-run residue does not swallow release"    "$([ -z "$R4OUT" ] && echo allow || printf '%s' "$R4OUT" | jq -r '.decision // "allow"')" "allow"
expect "R4  ...and the warning still reaches the user"    "$(grep -qF 'loop budget' "$T/r4.err" && echo y || echo n)" "y"
expect "R4  ...marker is keyed by base, not bare count"   "$(cat "$LBMARK" 2>/dev/null)" "$BASE|7"
# CONTROL: within the SAME run the once-per-count behavior must be intact, else R4's
# assertion would be satisfied by a hook that simply ignores the marker.
expect "R4 control: same run, 2nd turn-end blocks"        "$(stop)" "block"

echo
echo "================ Shared cap definition + doc contracts ================"

LBLIB="$HOOKS/lib/loop-budget.sh"
expect "lib/loop-budget.sh exists"                       "$([ -f "$LBLIB" ] && echo y || echo n)" "y"
expect "lib/loop-budget.sh parses"                       "$(bash -n "$LBLIB" 2>/dev/null && echo y || echo n)" "y"
# Both enforcing hooks must source the SAME definition, or the cap table reverts to
# two hardcoded copies - the duplication this file exists to prevent.
# Presence, not an exact count: the path appears in the source line AND in the
# comments explaining why the lib is shared, and pinning a count would red the suite
# for anyone who edits a comment.
expect "enforce-gates sources the shared lib"            "$(grep -q '^\. .*lib/loop-budget.sh' "$GATE" && echo y || echo n)" "y"
expect "stall hook sources the shared lib"               "$(grep -q '^\. .*lib/loop-budget.sh' "$STOP" && echo y || echo n)" "y"
expect "lib cap light=2"    "$(bash -c ". '$LBLIB'; lb_cap_for_tier light")"    "2"
expect "lib cap standard=4" "$(bash -c ". '$LBLIB'; lb_cap_for_tier standard")" "4"
expect "lib cap heavy=6"    "$(bash -c ". '$LBLIB'; lb_cap_for_tier heavy")"    "6"
expect "lib unknown tier -> standard cap" "$(bash -c ". '$LBLIB'; lb_cap_for_tier bogus")" "4"
expect "lib budget = max(cap, acked)"     "$(bash -c ". '$LBLIB'; lb_effective_budget 6 3")" "6"
expect "lib next budget adds one cap"     "$(bash -c ". '$LBLIB'; lb_next_budget 6 12")" "18"
expect "lib rejects non-numeric"          "$(bash -c ". '$LBLIB'; lb_is_number abc && echo y || echo n")" "n"
expect "lib rejects negative"             "$(bash -c ". '$LBLIB'; lb_is_number -3 && echo y || echo n")" "n"
# Magnitude is part of the contract: bash compares via a signed 64-bit conversion, so
# an all-digits value wider than INT64_MAX errors in `[ ]` exactly like "abc" does and
# would fail the guard OPEN. 18 digits is the widest unconditionally safe length.
expect "lib accepts 18 digits"            "$(bash -c ". '$LBLIB'; lb_is_number 999999999999999999 && echo y || echo n")" "y"
expect "lib rejects 19 digits"            "$(bash -c ". '$LBLIB'; lb_is_number 9999999999999999999 && echo y || echo n")" "n"
expect "lib rejects 20 digits"            "$(bash -c ". '$LBLIB'; lb_is_number 99999999999999999999 && echo y || echo n")" "n"
expect "lib judges value, not zero-padding" "$(bash -c ". '$LBLIB'; lb_is_number 0000000000000000000005 && echo y || echo n")" "y"
expect "lib accepts all-zeros"            "$(bash -c ". '$LBLIB'; lb_is_number 000 && echo y || echo n")" "y"
# a rejected huge value must degrade to the default, never to shell noise
expect "lib huge acked -> falls back to cap" "$(bash -c ". '$LBLIB'; lb_effective_budget 4 99999999999999999999 2>/dev/null")" "4"
# Octal safety: bash ARITHMETIC (unlike `[ ]`) reads a leading zero as an octal
# prefix, so `$(( 09 ))` is a fatal "value too great for base" error. A validated
# all-digit counter can therefore still blow up an arithmetic caller - which in the
# fail-CLOSED gate printed raw shell noise and an `acked_through: ` with NO value,
# i.e. a block whose own documented recovery snippet was invalid jq.
expect "lib strips leading zeros"         "$(bash -c ". '$LBLIB'; lb_strip_zeros 0000009")" "9"
expect "lib strip keeps all-zeros as 0"   "$(bash -c ". '$LBLIB'; lb_strip_zeros 000")" "0"
expect "lib next budget survives octal"   "$(bash -c ". '$LBLIB'; lb_next_budget 6 0 09 2>/dev/null")" "12"
expect "lib  ...with no arithmetic error" "$(bash -c ". '$LBLIB'; lb_next_budget 6 0 09 2>&1 >/dev/null" | grep -c 'too great for base')" "0"
expect "lib budget survives octal acked"  "$(bash -c ". '$LBLIB'; lb_effective_budget 4 08 2>/dev/null")" "8"
expect "lib does not leak v to the caller" \
  "$(bash -c '. "'"$LBLIB"'"; v=S; lb_is_number 5; printf "%s" "$v"')" "S"
# The helper must not clobber caller variables. enforce-gates.sh legitimately uses
# `cap` and `budget` itself, and today every call site happens to use $( ) (a
# subshell), which masks the problem — so this asserts on DIRECT calls, where a
# missing `local` would actually bite. Flagged as a latent fragility by verify.
expect "lib does not leak cap/budget to the caller" \
  "$(bash -c '. "'"$LBLIB"'"; cap=S; budget=S; lb_effective_budget 6 12 >/dev/null; lb_next_budget 6 12 >/dev/null; printf "%s%s" "$cap" "$budget"')" "SS"

# Doc contracts: greps for claims this change FALSIFIED. A stale one means a
# maintainer reads a guarantee the code no longer provides.
# Spec search is union-scoped: the auto-task spec is a spine
# (skills/auto-task/SKILL.md) plus skills/auto-task/references/*.md. $SKILL below is a
# regenerated temp concatenation of both, so the assertions in this file keep resolving
# wherever their prose lives. See tests/lib/spec.sh for the semantics.
. "$HOOKS/../tests/lib/spec.sh"
spec_concat_into LBSKILL
SPINE_ONLY="$HOOKS/../skills/auto-task/SKILL.md"   # for spine-only assertions

LBARCH="$HOOKS/../skills/auto-task/ARCHITECTURE.md"
LBRDME="$HOOKS/../README.md"
expect "Loop rule carries the converged clause"          "$(grep -c 'zero blockers and zero required findings means the loop has CONVERGED' "$LBSKILL")" "1"
expect "SKILL documents the fix-loop budget section"     "$(grep -c '^### Fix-loop budget' "$LBSKILL")" "1"
expect "SKILL documents the ack ritual"                  "$(grep -c 'The ack ritual' "$LBSKILL")" "1"
expect "SKILL schema carries gates.loop_budget"          "$(grep -c '"loop_budget": { "acked_through"' "$LBSKILL")" "1"
expect "SKILL: no stale 'reads only gates.*'"            "$(grep -c 'reads only `gates\.\*`' "$LBSKILL")" "0"
expect "SKILL: no stale 'ONLY new object'"               "$(grep -c 'ONLY new object a hook reads' "$LBSKILL")" "0"
expect "SKILL: no stale 'no fixed numeric cap'"          "$(grep -c 'no fixed numeric cap' "$LBSKILL")" "0"
expect "SKILL: actuals is an explicit obligation"        "$(grep -c 'is an OBLIGATION, not best-effort' "$LBSKILL")" "1"
expect "SKILL: obligation keyed on the history entry"    "$(grep -c 'history entry EXISTS' "$LBSKILL")" "1"
# The obligation must be a NAMED guard checked at every writer of phase:"done", not a
# sentence buried in the step that performs it - a rule stated only inside the step it
# obliges guards just the branch that would already have complied. Precedent: the
# external-actions terminal guard, which is restated at every Phase-7 done-writer.
# >= rather than == : the guard is deliberately restated at every done-writer, so the
# count grows whenever a new terminal branch is added. An exact count would red on the
# very edit that EXTENDS coverage - the opposite of what this pins. The per-writer
# assertions below are what actually enforce placement; this one guards the name.
expect "SKILL: the obligation is a named guard"          "$([ "$(grep -ic 'run-metrics terminal guard' "$LBSKILL")" -ge 6 ] && echo y || echo n)" "y"
expect "SKILL: guard cited at the Phase-5 done fork"     "$(sed -n '/^12\. Write .pr_url. to state/p' "$LBSKILL" | grep -qF 'run-metrics terminal guard' && echo y || echo n)" "y"
expect "SKILL: guard cited at the Phase-6 done writer"   "$(sed -n '/^\*\*6\. Terminal handoff\.\*\*/p' "$LBSKILL" | grep -qF 'run-metrics terminal guard' && echo y || echo n)" "y"
expect "SKILL: guard cited at the Phase-8 done writer"   "$(sed -n '/^\*\*6\. Terminal state\.\*\*/p' "$LBSKILL" | grep -qF 'run-metrics terminal guard' && echo y || echo n)" "y"
# Per-WRITER, not per-phase: the earlier pin counted the phrase somewhere in Phase 7,
# which one standalone paragraph satisfied while step 3's FAIL branch (a done-writer in
# its own numbered step) cited only the external-actions guard - "addressed in name, not
# in behavior", the exact shape this guard exists to prevent.
expect "SKILL: Phase-7 FAIL branch cites both guards"    "$(sed -n '/^   - \*\*FAIL\*\* — the preview was reachable/p' "$LBSKILL" | grep -qF 'run-metrics terminal guard' && echo y || echo n)" "y"
expect "SKILL: Phase-7 terminal bullet cites the guard"  "$(sed -n '/^   - \*\*Terminal state (or handoff to Phase 8)/p' "$LBSKILL" | grep -qF 'run-metrics terminal guard' && echo y || echo n)" "y"
expect "SKILL: Phase-7 step 1.4 cites all three guards"  "$(sed -n '/^   4\. \*\*No URL by/p' "$LBSKILL" | grep -qF 'ALL THREE terminal guards' && echo y || echo n)" "y"
expect "SKILL: both guard enumerations name step 3"      "$(grep -c "step 3's FAIL bullet" "$LBSKILL")" "2"
# The two hooks' agreement is scoped to well-formed states; on an unverifiable counter
# they diverge BY DESIGN (opposite fail policies). The old absolute was false - fuzzing
# found ~9 corrupt shapes where the gate blocks and the release stays silent.
expect "SKILL: no false never-disagree absolute"         "$(grep -c 'can never disagree with each other' "$LBSKILL")" "0"
expect "SKILL: divergence-by-design documented"          "$(grep -c 'they diverge \*by design\*' "$LBSKILL")" "1"
expect "SKILL: guard cited at the Phase-7 done writers"  "$(grep -c 'Terminal guards . the external-actions terminal guard, the run-metrics terminal guard AND the release terminal guard' "$LBSKILL")" "1"
expect "ARCH gate table lists the loop-budget gate"      "$(grep -q 'loop-budget gate' "$LBARCH" && echo y || echo n)" "y"
# The gate skips when EITHER side is missing (`has_effort && has_iter`). The row used
# to read as a conjunction ("no effort.tier AND no iteration counters"), which predicts
# a block at cap 4 for {"iteration":{"fix":99}} with no effort object - the code exits 0.
# This is the row the design nominates as the single non-stale source, so its content
# gets a guard, not just its existence.
expect "ARCH row states the skip as EITHER-side"         "$(grep -c 'missing EITHER side' "$LBARCH")" "1"
expect "ARCH row does not state it as a conjunction"     "$(grep -c 'no .effort.tier. and no .iteration. counters' "$LBARCH")" "0"
expect "ARCH cap table points at the shared lib"         "$(grep -c 'single executable definition' "$LBARCH")" "1"
expect "README gate list mentions the fix-loop budget"   "$(grep -c 'It also enforces the \*\*fix-loop budget\*\*' "$LBRDME")" "1"
# The ack does NOT buy a flat one cap - it steps to the first rung that clears the
# count (see lb_next_budget). Mutation testing showed this README row was the ONE
# corrected surface no assertion pinned: restoring the stale wording left the suite
# fully green. Same shape as the SKILL stale-claim guards above.
expect "README: no stale one-cap ack claim"              "$(grep -c 'buys one more cap' "$LBRDME")" "0"
expect "README budget rows name both counters"           "$([ "$(grep -c 'max(iteration.fix, iteration.review)' "$LBRDME")" -ge 2 ] && echo y || echo n)" "y"
expect "README has a budget troubleshooting row"         "$(grep -c 'over its fix-loop budget' "$LBRDME")" "1"


# ============================================================================
# SPINE-ONLY GUARDS — contracts that must never leave the always-loaded SKILL.md
# ============================================================================
# The spec is a spine plus references/*.md, and most assertions in this suite are
# union-scoped (see tests/lib/spec.sh) so relocating prose costs no test churn.
# That convenience has a cost: a union search cannot tell you WHERE a contract
# lives, so a future edit could quietly demote a must-stay contract into a
# reference file and the suite would stay green.
#
# These assertions close that hole. They grep SKILL.md DIRECTLY — never through
# spec_has/spec_count — so each one fails if its content is moved to a reference.
# tests/spec-helper.test.sh carries the mutation probe proving that failure
# actually happens, which is what makes this a guarantee rather than a claim.
#
# Everything below is read on EVERY turn of EVERY run, or is the mechanism that
# stops a run from stalling / committing ungated. None of it is deferrable.
spine_has() { grep -qF -- "$2" "$1" 2>/dev/null && echo yes || echo no; }

expect "spine: NON-YIELDING CONTRACT heading"      "$(spine_has "$SPINE_ONLY" '## NON-YIELDING CONTRACT')"            "yes"
expect "spine: Operating principles heading"       "$(spine_has "$SPINE_ONLY" '## Operating principles')"              "yes"
expect "spine: Loop rule heading"                  "$(spine_has "$SPINE_ONLY" '## Loop rule (the only exit conditions)')" "yes"
expect "spine: Effort tiers table"                 "$(spine_has "$SPINE_ONLY" '| Tier     | Range |')"                 "yes"
expect "spine: Fix-loop budget heading"            "$(spine_has "$SPINE_ONLY" '### Fix-loop budget (mechanically enforced)')" "yes"
expect "spine: Surfacing protocol heading"         "$(spine_has "$SPINE_ONLY" '## Surfacing protocol')"                 "yes"
# GATE-A ROUND-2 FINDING: the heading alone was relocation-blind — the round-2 verifier
# moved the whole 11-line body (all four steps) into a reference and the suite stayed
# 329/0. Assert the steps, which ARE the contract.
expect "spine: surfacing step 1 (state write)" \
  "$(spine_has "$SPINE_ONLY" 'Save current state to `.auto-task/<branch>/STATE.json`, setting `expected_next_action:')" "yes"
expect "spine: surfacing step 2 (trace entry)"  "$(spine_has "$SPINE_ONLY" '`operation: auto-task:surfaced`')"                "yes"
expect "spine: surfacing step 3 (why stopped)"  "$(spine_has "$SPINE_ONLY" '**Why stopped** — which loop-rule clause triggered')" "yes"
expect "spine: surfacing step 4 (no auto-resume)" "$(spine_has "$SPINE_ONLY" 'Do not auto-resume. Wait for the user.')"       "yes"

# The NON-YIELDING contract's two terminal states are the contract; its heading is not.
expect "spine: non-yielding success terminal"   "$(spine_has "$SPINE_ONLY" '- **Success:** Phase 5 completes (commit landed + PR open')" "yes"
expect "spine: non-yielding hard-stop terminal" "$(spine_has "$SPINE_ONLY" '- **Hard stop:** a Loop-rule trigger fires')"     "yes"

# The per-transition table is the mapping that tells the model WHICH value to write at
# each phase point. Relocating it left the suite green in round 2.
expect "spine: per-transition table header"     "$(spine_has "$SPINE_ONLY" '| Transition / phase point | Set `expected_next_action` to |')" "yes"
expect "spine: per-transition plan-approval row" "$(spine_has "$SPINE_ONLY" 'Phase 1 plan presented for approval')"           "yes"
expect "spine: per-transition push-prompt row"  "$(spine_has "$SPINE_ONLY" 'Phase 5 just-before `git push` / `gh pr create`')" "yes"
expect "spine: Rules heading"                      "$(spine_has "$SPINE_ONLY" '## Rules')"                              "yes"

# The yield-point contract is the anti-stall mechanism: it is consulted at every
# state write, so it must be inline, table and all.
expect "spine: Yield-point contract heading"       "$(spine_has "$SPINE_ONLY" '### Yield-point contract')"              "yes"
# GATE-A FINDING: these were originally `grep -c auto-continue >= 5` and a bare
# `user-push-prompt` presence check. Both passed on a mutated spine with the ENTIRE
# four-value table deleted, because `auto-continue` occurs 45 times and
# `user-push-prompt` 9 times OUTSIDE the table. A location guard must key on text
# UNIQUE to the contract's body, never on a word the rest of the spine also uses.
expect "spine: yield table row — auto-continue semantics" \
  "$(spine_has "$SPINE_ONLY" '| `"auto-continue"` | Pipeline is mid-flight; the model MUST make the next tool call.')" "yes"
expect "spine: yield table row — user-approval semantics" \
  "$(spine_has "$SPINE_ONLY" '| `"user-approval"` | A legitimate human gate. Stop hook allows.')"                      "yes"
expect "spine: yield table row — user-push-prompt semantics" \
  "$(spine_has "$SPINE_ONLY" '| `"user-push-prompt"` | The single allowed Phase 5 push/PR/hold prompt.')"              "yes"
expect "spine: yield table row — null semantics" \
  "$(spine_has "$SPINE_ONLY" '| `null` | Pre-approval or terminal state. Stop hook allows.')"                          "yes"
expect "spine: yield table four-value preamble" \
  "$(spine_has "$SPINE_ONLY" 'MUST be one of these four values at all times after')"                                   "yes"

# Loop rule: the HEADING is not the contract — the five clauses are. The heading-only
# assertion above passed with all five clauses deleted.
expect "spine: loop clause 1 (progress)"      "$(spine_has "$SPINE_ONLY" '**Progress** — each iteration makes measurable progress')"      "yes"
expect "spine: loop clause 2 (in-scope)"      "$(spine_has "$SPINE_ONLY" '**In-scope** — remaining issues map to the approved Acceptance Criteria')" "yes"
expect "spine: loop clause 3 (unblocked)"     "$(spine_has "$SPINE_ONLY" '**Unblocked** — no external blocker')"                          "yes"
expect "spine: loop clause 4 (no flakiness)"  "$(spine_has "$SPINE_ONLY" '**No test flakiness** — every test failure is reproducible')"   "yes"
expect "spine: loop clause 5 (diminishing returns)" \
  "$(spine_has "$SPINE_ONLY" '**Returns have not diminished**')"                                                        "yes"

# Effort tiers: assert the actual cap numbers, not just the table header.
expect "spine: tier row LIGHT"    "$(spine_has "$SPINE_ONLY" '| LIGHT    | 0-2   |')"    "yes"
expect "spine: tier row STANDARD" "$(spine_has "$SPINE_ONLY" '| STANDARD | 3-5   |')"    "yes"
expect "spine: tier row HEAVY"    "$(spine_has "$SPINE_ONLY" '| HEAVY    | 6-8   |')"    "yes"

# The AC correctness core stays inline by explicit design decision: its silent
# degradation would be the hardest failure in the pipeline to notice.
expect "spine: Acceptance Criteria contract"       "$(spine_has "$SPINE_ONLY" '**Acceptance Criteria contract (NON-NEGOTIABLE)')" "yes"
# GATE-A FINDING: the line above asserts only the contract's intro sentence, so the
# eleven rules it introduces could be relocated with the suite green. Assert the rules.
expect "spine: AC rule 1 observable"          "$(spine_has "$SPINE_ONLY" '**Observable** — phrased as something a third party can witness')"      "yes"
expect "spine: AC rule 2 bound to a check"    "$(spine_has "$SPINE_ONLY" '**Bound to a check** —')"                                              "yes"
expect "spine: AC rule 3 falsifiable"         "$(spine_has "$SPINE_ONLY" '**Falsifiable** —')"                                                   "yes"
expect "spine: AC rule 4 gate-bound"          "$(spine_has "$SPINE_ONLY" '**Gate-bound** — every row')"                                          "yes"
expect "spine: AC rule 5 complete"            "$(spine_has "$SPINE_ONLY" '**Complete** — together, the AC rows cover every behavior')"           "yes"
expect "spine: AC rule 9 local dev first"     "$(spine_has "$SPINE_ONLY" '**Local dev first, then preview** —')"                                  "yes"
expect "spine: AC rule 6 method is binding"   "$(spine_has "$SPINE_ONLY" '**Verification method is binding**')"                                  "yes"
expect "spine: AC rule 7 data precondition"   "$(spine_has "$SPINE_ONLY" '**Data precondition is explicit**')"                                   "yes"
expect "spine: AC rule 8 visual-by-default"   "$(spine_has "$SPINE_ONLY" '**Visual-by-default for UI changes**')"                                "yes"
expect "spine: AC rule 10 before/after pair"  "$(spine_has "$SPINE_ONLY" 'A before/after pair is REQUIRED to call a visual change done')"         "yes"
expect "spine: AC rule 11 external actions"   "$(spine_has "$SPINE_ONLY" '**External actions are declared and gated on Phase 8')"                "yes"
# INCONCLUSIVE floor: its resolution vocabulary is the contract, not its heading.
expect "spine: floor — verify-now resolution"  "$(spine_has "$SPINE_ONLY" '**Verify now** —')"                                                   "yes"
expect "spine: floor — descope resolution"     "$(spine_has "$SPINE_ONLY" '**Descope from this run** —')"                                        "yes"
expect "spine: floor — never PASS never FAIL"  "$(spine_has "$SPINE_ONLY" '**INCONCLUSIVE is never PASS and never FAIL.**')"                      "yes"
expect "spine: INCONCLUSIVE floor"                 "$(spine_has "$SPINE_ONLY" '**The INCONCLUSIVE floor')"              "yes"
expect "spine: requirements decomposition"         "$(spine_has "$SPINE_ONLY" '**Requirements decomposition')"          "yes"
expect "spine: D/R rubric"                         "$(spine_has "$SPINE_ONLY" '**Difficulty / Risk rubric')"            "yes"

# Phase 4 (code review + fix loop) is the anti-stall keystone and stays WHOLLY
# inline — unlike Phase 3 / Gate A / Gate B, whose bodies moved to a reference.
# The per-phase "Non-negotiables restated inline" bullets ARE the mitigation the
# Phase-1 silent-degradation acknowledgment rests on. Round 2 showed they were unguarded.
expect "spine: P3 non-negotiable — execute every self-verify AC" \
  "$(spine_has "$SPINE_ONLY" '**Execute EVERY AC row gated `self-verify`**')"                                                "yes"
expect "spine: P3 non-negotiable — never substitute a weaker method" \
  "$(spine_has "$SPINE_ONLY" '**Never substitute a weaker method.**')"                                                       "yes"
expect "spine: P3 non-negotiable — inconclusive blocks the gate" \
  "$(spine_has "$SPINE_ONLY" 'An `inconclusive` AC is NOT a pass and blocks the gate exactly like a fail.')"                  "yes"
expect "spine: GateA non-negotiable — short-circuit on fail" \
  "$(spine_has "$SPINE_ONLY" 'Any `fail` **short-circuits Gate A**')"                                                        "yes"
expect "spine: GateA non-negotiable — never passes while inconclusive" \
  "$(spine_has "$SPINE_ONLY" '**`gates.gate_a.passed` never becomes `true` while any AC is recorded `inconclusive`.**')"      "yes"
expect "spine: GateB non-negotiable — diff the working tree" \
  "$(spine_has "$SPINE_ONLY" '**Diff the working tree, not HEAD.**')"                                                        "yes"
expect "spine: Phase 4 heading"                    "$(spine_has "$SPINE_ONLY" '### Phase 4 — Code review + fix loop')"  "yes"
expect "spine: Phase 4 mandates the review skill"  "$(spine_has "$SPINE_ONLY" 'skill:auto-task-code-review')"           "yes"
expect "spine: Phase 4 trip-wire retained inline"  "$(spine_has "$SPINE_ONLY" 'Trip-wire test before ending the turn here.')" "yes"

# The trace contract stays inline for a load-bearing reason, not by accident:
# three sibling skills cite it by section path (auto-task-fix, auto-task-verify,
# auto-task-code-review all say "orchestrator SKILL.md -> Persistent history &
# trace contract -> TRACE.md format"). Moving it would dangle those citations.
expect "spine: trace contract heading"             "$(spine_has "$SPINE_ONLY" '## Persistent history & trace contract')" "yes"
expect "spine: TRACE.md format subheading"         "$(spine_has "$SPINE_ONLY" '### TRACE.md format')"                    "yes"
expect "spine: read-before-review contract"        "$(spine_has "$SPINE_ONLY" '### Read-before-review contract')"        "yes"

# Every reference must be reachable from the spine, and the spine must stay under
# the always-loaded budget. These two are the point of the whole split.
# GATE-B FINDING: the guards above were HEADING-ONLY for several every-turn contracts, so
# their bodies could be relocated with the suite green (only the CHANGELOG byte-count
# assertion fired, and that is not a location guard — its routine repair is to update the
# number). Gate A round 2 fixed this shape for the Surfacing protocol; the same defect was
# left in place for the contracts below. Assert their BODIES, keyed on unique text.

# Fix-loop budget: the ack ritual is the user gate that bounds review volume.
expect "spine: budget loop-count definition"   "$(spine_has "$SPINE_ONLY" '**Loop count** = `max(iteration.fix, iteration.review)`')"        "yes"
expect "spine: budget effective-budget rule"   "$(spine_has "$SPINE_ONLY" '**Effective budget** = `max(cap, gates.loop_budget.acked_through)`')" "yes"
expect "spine: budget ack is a USER gate"      "$(spine_has "$SPINE_ONLY" 'this is a user gate, not a self-serve flag')"                     "yes"
expect "spine: budget ack records acked_through" "$(spine_has "$SPINE_ONLY" 'gates.loop_budget = { acked_through:')"                         "yes"

# Stop-hook decision algorithm: this three-branch rule IS the anti-stall mechanism.
expect "spine: stop-hook allow on done"        "$(spine_has "$SPINE_ONLY" '`phase === "done"` → allow stop.')"                             "yes"
expect "spine: stop-hook allow pre-approval"   "$(spine_has "$SPINE_ONLY" '`approved !== true` → allow stop.')"                              "yes"
expect "spine: stop-hook blocks otherwise"     "$(spine_has "$SPINE_ONLY" 'allow only when `expected_next_action ∈ {"user-approval", "user-push-prompt"}')" "yes"

# TRACE.md format: three sibling skills cite this block by section path, so its BODY (the
# field list), not just its heading, must stay inline.
expect "spine: trace field Phase / context"    "$(spine_has "$SPINE_ONLY" '- **Phase / context:**')"                                         "yes"
expect "spine: trace field Outcome"            "$(spine_has "$SPINE_ONLY" '- **Outcome:** <pass | fail | partial | surfaced | no-op>')"      "yes"
expect "spine: trace field Artifacts produced" "$(spine_has "$SPINE_ONLY" '- **Artifacts produced:**')"                                      "yes"

# Read-before-review contract: the numbered steps are what downstream tools must follow.
expect "spine: read-before-review step 1"      "$(spine_has "$SPINE_ONLY" '1. **Discover.** `git branch --show-current`')"                    "yes"
expect "spine: read-before-review step 2"      "$(spine_has "$SPINE_ONLY" '2. **Read CONTEXT.md**')"                                          "yes"
expect "spine: read-before-review step 3"      "$(spine_has "$SPINE_ONLY" '3. **Read TRACE.md**')"                                            "yes"

# Rules: the commit-hygiene rules are the last line of defence before a bad commit.
expect "spine: rule AC mandatory"              "$(spine_has "$SPINE_ONLY" '- **Acceptance Criteria are mandatory and load-bearing.**')"        "yes"
expect "spine: rule expected_next_action"      "$(spine_has "$SPINE_ONLY" '- **`expected_next_action` is mandatory and mechanically enforced.**')" "yes"
expect "spine: rule never commit .auto-task"   "$(spine_has "$SPINE_ONLY" '- **Never commit anything under `.auto-task/`.**')"                 "yes"
expect "spine: rule never commit others work"  "$(spine_has "$SPINE_ONLY" "- **Never commit other people's pre-staged work.**")"            "yes"

# GATE-B ROUND-2 FINDING: every guard above is a hand-curated instance, so a contract
# NOT on the list could be relocated with the suite green. Gate B demonstrated it on
# `### Single-commit rule (NON-NEGOTIABLE)` and on all of Phase 2: inventory stayed clean
# (`missing=0 duplicated=0 restated=0`), directives stayed 7/7, every other suite stayed
# green, and the ONLY failure was the CHANGELOG byte-count pin — which is a doc-freshness
# check, not a location guard, and which anyone doing the relocation would update in the
# same edit. So R10's guarantee did not hold for the class.
#
# This manifest closes it structurally: it pins the COMPLETE set of headings that must
# live in the always-loaded spine. The last two entries sit inside fenced examples (the
# AC-table template and the TRACE-entry block format) rather than being sections in their
# own right — they are pinned because those templates are themselves spine contracts that
# downstream tools and three sibling skills reproduce verbatim. A relocation of any of them fails here regardless of
# whether someone remembered to add a bespoke guard for it.
spine_manifest() {
  cat <<'MANIFEST'
## NON-YIELDING CONTRACT (read first — the highest-priority rule in this skill)
## Operating principles
## Loop rule (the only exit conditions)
## Effort tiers
### Fix-loop budget (mechanically enforced)
## Inputs
### Resume (no-args) dispatch
## State file
### Yield-point contract (mechanical anti-stall enforcement)
## User settings
## Autonomy modes & the merge gate
## Comment voice
## Pipeline
### Phase 1 — Define (HUMAN GATE)
### Single-commit rule (NON-NEGOTIABLE)
### Phase 2 — Execute (auto, NO COMMIT)
### Phase 3 — Self-verify (auto, NO COMMIT)
### Gate A — Independent verifier (auto, NO COMMIT)
### Phase 4 — Code review + fix loop (auto, NO COMMIT)
### Gate B — Adversarial verifier (auto, NO COMMIT)
### Phase 5 — Handover (auto, SINGLE COMMIT)
### Phase 6 — PR bot-comment review & conservative fix (auto, GATED, opt-in)
### Phase 7 — Preview verification & final verdict (auto, GATED, NO new authored commit)
### Phase 8 — External change application & verification (auto, GATED, NO new authored commit)
### Phase 9 — Release (auto, GATED, opt-in, ONE additional authored commit)
## Persistent history & trace contract
### Folder layout (per branch)
### TRACE.md format
### When to append a trace entry
### Read-before-review contract
### Pruning
## Surfacing protocol (when loop rule triggers)
## Rules
## Acceptance Criteria
## <ISO-8601 timestamp> · <operation> · <source>
MANIFEST
}
missing_sections=0
while IFS= read -r _sec; do
  [ -n "$_sec" ] || continue
  grep -qxF "$_sec" "$SPINE_ONLY" || { missing_sections=$((missing_sections+1)); printf '        MISSING FROM SPINE: %s\n' "$_sec" >&2; }
done < <(spine_manifest)
expect "spine: complete section manifest present (none relocated)" "$missing_sections" "0"
expect "spine: manifest covers every spine heading (no unlisted section)" \
  "$(comm -13 <(spine_manifest | LC_ALL=C sort) <(grep -E '^#{2,3} ' "$SPINE_ONLY" | LC_ALL=C sort -u) | wc -l | tr -d ' ')" "0"

# Bodies of the two sections Gate B actually relocated, so the manifest is not the only
# thing standing between a demotion and a green suite.
expect "spine: single-commit rule body — phases that do NOT commit" \
  "$(spine_has "$SPINE_ONLY" '**Phases 2, 3, Gate A, Phase 4, and Gate B do NOT commit.**')"                    "yes"
expect "spine: single-commit rule body — one authored commit" \
  "$(spine_has "$SPINE_ONLY" 'Phase 5 produces exactly one **authored** commit')"                               "yes"
expect "spine: phase-2 body — drift checkpoint" \
  "$(spine_has "$SPINE_ONLY" '<!-- DRIFT CHECKPOINT -->')"                                                      "yes"
expect "spine: phase-2 body — out-of-scope drift surfaces" \
  "$(spine_has "$SPINE_ONLY" 'treat as out-of-scope per Loop rule clause 2')"                                   "yes"

# GATE-B ROUND-3 FINDING: the manifest above only checks that the heading LINE is present,
# so a heading-KEPT body relocation slipped through — which is the shape a real carve takes.
# Reproduced: moving the BODY of `## Comment voice`, `## Operating principles` or
# `## Autonomy modes & the merge gate` into a reference left conservation clean, the manifest
# satisfied, and exactly ONE failure — the CHANGELOG byte pin — after which the routine
# resync that the pin's own comment invites made the suite FULLY GREEN. Body guards existed
# for only the two sections round 2 happened to demonstrate.
#
# This floor closes the class for every section at once: each spine section must retain at
# least half its current non-blank body lines. Normal editing passes; wholesale relocation
# (which drops a body to ~0) cannot. Floors are a ratchet — raise them deliberately, never
# lower one to make a relocation pass.
spine_body_floors() {
  cat <<'FLOORS'
8|## NON-YIELDING CONTRACT (read first — the highest-priority rule in this skill)
8|## Operating principles
5|## Loop rule (the only exit conditions)
4|## Effort tiers
5|### Fix-loop budget (mechanically enforced)
1|## Inputs
2|### Resume (no-args) dispatch
62|## State file
35|### Yield-point contract (mechanical anti-stall enforcement)
2|## User settings
6|## Autonomy modes & the merge gate
4|## Comment voice
0|## Pipeline
47|### Phase 1 — Define (HUMAN GATE)
3|### Single-commit rule (NON-NEGOTIABLE)
6|### Phase 2 — Execute (auto, NO COMMIT)
5|### Phase 3 — Self-verify (auto, NO COMMIT)
4|### Gate A — Independent verifier (auto, NO COMMIT)
11|### Phase 4 — Code review + fix loop (auto, NO COMMIT)
4|### Gate B — Adversarial verifier (auto, NO COMMIT)
10|### Phase 5 — Handover (auto, SINGLE COMMIT)
3|### Phase 6 — PR bot-comment review & conservative fix (auto, GATED, opt-in)
4|### Phase 7 — Preview verification & final verdict (auto, GATED, NO new authored commit)
4|### Phase 8 — External change application & verification (auto, GATED, NO new authored commit)
4|### Phase 9 — Release (auto, GATED, opt-in, ONE additional authored commit)
0|## Persistent history & trace contract
6|### Folder layout (per branch)
11|### TRACE.md format
3|### When to append a trace entry
4|### Read-before-review contract
0|### Pruning
4|## Surfacing protocol (when loop rule triggers)
6|## Rules
FLOORS
}
thin_sections=0
while IFS='|' read -r _floor _sec; do
  [ -n "$_sec" ] || continue
  _start="$(grep -nxF "$_sec" "$SPINE_ONLY" | head -1 | cut -d: -f1)"
  [ -n "$_start" ] || continue   # absence is the manifest check's job, not this one's
  _body="$(awk -v s="$_start" 'NR<=s {next} /^```/ {f=!f; next} f {print; next} /^#{2,3} / {exit} {print}' "$SPINE_ONLY" | grep -c '[^[:space:]]')"
  if [ "$_body" -lt "$_floor" ]; then
    thin_sections=$((thin_sections+1))
    printf '        BODY TOO THIN IN SPINE: %s (%s non-blank lines, floor %s)\n' "$_sec" "$_body" "$_floor" >&2
  fi
done < <(spine_body_floors)
expect "spine: every section retains its body (no heading-kept relocation)" "$thin_sections" "0"

expect "spine: references/ dir exists"             "$([ -d "$HOOKS/../skills/auto-task/references" ] && echo yes || echo no)" "yes"
# What matters is that EVERY reference file is cited, not the raw directive count
# (several phases carry more than one directive, which is fine and not brittle).
expect "spine: every reference is cited by a directive" \
  "$(grep -o 'references/[a-z0-9-]*\.md' "$SPINE_ONLY" | sort -u | wc -l | tr -d ' ')"                                "7"
expect "spine: at least one directive per reference"    \
  "$([ "$(grep -c '\*\*MANDATORY READ' "$SPINE_ONLY")" -ge 7 ] && echo yes || echo no)"                               "yes"
# The CHANGELOG quotes the spine's byte size, and that number drifted out of date twice
# during this change (each re-carve shifts it). Pin it to reality so it cannot rot again.
# GATE-B ROUND-2 FINDING: the byte-size claim was pinned but the two assertion COUNTS one
# line either side of it were not, and both had rotted 3x stale (26 vs 47, 26 vs 95) across
# seven fix rounds. Pin them too — a published release note for a marketplace plugin should
# not understate its own guard coverage.
expect "spine: CHANGELOG spec-helper count is current" \
  "$(grep -oE '`tests/spec-helper\.test\.sh`\*\* — [0-9]+ assertions' "$HOOKS/../CHANGELOG.md" | grep -oE '[0-9]+')" \
  "$(bash "$HOOKS/../tests/spec-helper.test.sh" </dev/null 2>&1 | grep -oE '[0-9]+ passed' | head -1 | grep -oE '[0-9]+')"
expect "spine: CHANGELOG spine-guard count is current" \
  "$(grep -oE 'enforcement-spine\.test\.sh`\*\* \(([0-9]+) assertions' "$HOOKS/../CHANGELOG.md" | grep -oE '[0-9]+')" \
  "$(grep -cE '^expect "spine: ' "$HOOKS/../tests/enforcement-spine.test.sh" | tr -d ' ')"

# GATE-B ROUND-4 FINDING: README carried its own size claim and its own "no behavior
# change" assertion, and neither was pinned — the CHANGELOG's equivalent number had already
# rotted twice. README is the marketplace-published doc, so pin its number too.
expect "spine: README size claim matches the actual spine" \
  "$(grep -oE '\*\*[0-9,]+ B to [0-9,]+ B' "$HOOKS/../README.md" | head -1 | sed 's/.* to //' | tr -d ', B')" \
  "$(wc -c < "$SPINE_ONLY" | tr -d ' ')"
expect "spine: README does not claim a pure no-behavior-change move" \
  "$(grep -c 'with no behavior change: the content is relocated' "$HOOKS/../README.md")" "0"

expect "spine: CHANGELOG size claim matches the actual spine" \
  "$(grep -oE '\*\*[0-9,]+ B spine\*\*' "$HOOKS/../CHANGELOG.md" | head -1 | tr -d '*, B spine' )" \
  "$(wc -c < "$SPINE_ONLY" | tr -d ' ')"

expect "spine: under the 120 KB budget"            "$([ "$(wc -c < "$SPINE_ONLY")" -le 122880 ] && echo yes || echo no)" "yes"
# CO-LOCATION — positionally-coupled prose must stay in ONE file, or an ordering
# assertion silently degrades into a meaningless cross-file line comparison.
# Phase 5's three step anchors are the live case (tests/docs-step.test.sh indexes
# on them with a +40-line window and two `-lt` comparisons).
expect "spine: phase-5 anchors co-located (1b vs main-sync)" \
  "$(spec_same_file '1b. **Docs update' 'Pre-commit main-sync' && echo yes || echo no)"              "yes"
expect "spine: phase-5 anchors co-located (1b vs diagram)" \
  "$(spec_same_file '1b. **Docs update' '2. **Build the change diagram' && echo yes || echo no)"     "yes"
expect "spine: phase-5 anchor order preserved" \
  "$(spec_before '1b. **Docs update' 'Pre-commit main-sync' && echo yes || echo no)"                 "yes"
# CODE-REVIEW FINDING: the guards above covered only the Phase-5 `1b` trio. Two more
# live positional pairs existed with no co-location assertion; if a future carve
# separated either, the `-lt` comparison would become a meaningless cross-file compare.
expect "spine: clarify-router anchors co-located" \
  "$(spec_same_file 'Resume short-circuit (checked before the router)' 'Step 4a — routing question' && echo yes || echo no)" "yes"
expect "spine: phase-5 docs sub-step anchors co-located" \
  "$(spec_same_file '5. **Authorize the edited paths' '6. **Re-pass the gates' && echo yes || echo no)"   "yes"
# `6. **Re-pass the gates` is AMBIGUOUS across the spec (it also occurs in
# phase-9-release.md), so pin the count: if a third copy appears, the anchor becomes
# order-dependent and callers must switch to an owning-file grep.
expect "spine: re-pass-the-gates anchor occurs exactly twice" "$(spec_count '6. **Re-pass the gates')" "2"

expect "spine: no cross-boundary restatement" \
  "$(bash "$HOOKS/../tests/spec-inventory.sh" 2>&1 | grep -oE 'restated=[0-9]+')"                    "restated=0"

expect "spine: structural inventory clean"         "$(bash "$HOOKS/../tests/spec-inventory.sh" >/dev/null 2>&1 && echo yes || echo no)" "yes"
expect "spine: directives land in owning sections" "$(bash "$HOOKS/../tests/spec-inventory.sh" --directives >/dev/null 2>&1 && echo yes || echo no)" "yes"

# restore a sane state file for anything appended after this block
printf '%s' '{"approved":true,"phase":"review","expected_next_action":"auto-continue"}' > "$ST"

echo
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
