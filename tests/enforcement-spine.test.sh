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

echo "== In-flight Agent spawn: bounded turn-end release (awaiting-agent) =="
# A backgrounded `Agent` spawn returns launch metadata, not the report; the report
# arrives later as a task notification, so YIELDING is the only way to receive it.
# That is the one mid-pipeline turn-end this hook releases on purpose. It is capped,
# because no hook can observe an Agent spawn (PreToolUse is Bash-only), so an
# uncapped release would be an unbounded stall hatch.
rm -f "$SD/.stall-block-count" "$SD/.agent-wait-count"
cat > "$ST" <<EOF
{"approved":true,"phase":"gate-a","expected_next_action":"awaiting-agent","base":"$BASE","effort":{"tier":"standard"},
 "iteration":{"review":0,"fix":0},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
EOF
# Raw stdout, so the JSON-object COUNT can be asserted (a Stop hook must emit exactly
# one object; an early draft emitted a systemMessage in front of the block's decision).
awRaw(){ CLAUDE_PROJECT_DIR="$T" AUTO_TASK_STALL_LIMIT=99 bash "$STOP" </dev/null 2>/dev/null; }
awD(){ local o; o="$(awRaw)"; [ -z "$o" ] && { echo allow; return; }; printf '%s' "$o" | jq -r '.decision // "allow"' 2>/dev/null; }
expect "Wait: release #1 (report in flight)"              "$(awD)" "allow"
expect "Wait: release #2"                                 "$(awD)" "allow"
expect "Wait: release #3 (default cap is 3)"              "$(awD)" "allow"
expect "Wait: BLOCK #4 (cap exhausted)"                   "$(awD)" "block"
expect "Wait: still blocks at #5"                         "$(awD)" "block"
# Pin WHY it blocked, not just that it did — a block attributed to the wrong cause
# would satisfy the decision assertion above while telling the run nothing usable.
AWR="$(awRaw | jq -r '.reason')"
expect "Wait: block reason names the synchronous-spawn fix" \
  "$(printf '%s' "$AWR" | grep -qF 'run_in_background: false' && echo y || echo n)" "y"
expect "Wait: block reason forbids polling the transcript" \
  "$(printf '%s' "$AWR" | grep -qF 'Do NOT poll the agent' && echo y || echo n)" "y"
expect "Wait: block reason forbids an outcome from a timeout" \
  "$(printf '%s' "$AWR" | grep -qF 'from the absence of a report' && echo y || echo n)" "y"
expect "Wait: stdout carries exactly ONE JSON object"     "$(awRaw | jq -s 'length')" "1"
# The report lands: the model writes auto-continue, the signature changes, and the
# NEXT gate's wait draws a full fresh allowance. A wait that is working never
# approaches the cap.
setstate '.expected_next_action="auto-continue"'; awD >/dev/null
setstate '.phase="gate-b"|.expected_next_action="awaiting-agent"'
expect "Wait: fresh allowance after the state advances"   "$(awD)" "allow"
# The frozen-run backstop must still be REACHABLE past an exhausted wait — the cap
# path falls through to the ordinary counter-and-block instead of deciding early, or
# a wait that never resolves would block forever with the soft-lock breaker
# unreachable: a bounded thrash traded for an unrecoverable session.
rm -f "$SD/.stall-block-count" "$SD/.agent-wait-count"
setstate '.phase="gate-a"|.expected_next_action="awaiting-agent"'
awS(){ local o; o="$(CLAUDE_PROJECT_DIR="$T" AUTO_TASK_STALL_LIMIT=2 AUTO_TASK_AGENT_WAIT_LIMIT=1 bash "$STOP" </dev/null 2>/dev/null)"; [ -z "$o" ] && { echo allow; return; }; printf '%s' "$o" | jq -r '.decision // "allow"' 2>/dev/null; }
expect "Wait+backstop: release #1 (wait cap 1)"           "$(awS)" "allow"
expect "Wait+backstop: block #1 (wait exhausted)"         "$(awS)" "block"
expect "Wait+backstop: soft-lock RELEASE still reachable" "$(awS)" "allow"
# Cap is env-overridable in the tightening direction too.
rm -f "$SD/.stall-block-count" "$SD/.agent-wait-count"
expect "Wait: AUTO_TASK_AGENT_WAIT_LIMIT=0 blocks immediately" \
  "$(o="$(CLAUDE_PROJECT_DIR="$T" AUTO_TASK_AGENT_WAIT_LIMIT=0 bash "$STOP" </dev/null 2>/dev/null)"; [ -z "$o" ] && echo allow || printf '%s' "$o" | jq -r '.decision // "allow"')" "block"
# NEAR-MISSES — the assertions that matter. Only the exact value releases; anything
# that merely LOOKS like a wait must still block, or the release becomes the hatch.
rm -f "$SD/.stall-block-count" "$SD/.agent-wait-count"
for v in awaiting-external awaiting awaiting-agents Awaiting-Agent "awaiting-agent " auto-continue; do
  rm -f "$SD/.stall-block-count" "$SD/.agent-wait-count"
  setstate ".expected_next_action=\"$v\""
  expect "Near-miss: '$v' still BLOCKS"                   "$(awD)" "block"
done
# And the ordinary block message is byte-identical to before — the wait note must not
# leak into a turn-end that never waited.
rm -f "$SD/.stall-block-count" "$SD/.agent-wait-count"
setstate '.expected_next_action="auto-continue"'
expect "Wait: ordinary block carries no in-flight note" \
  "$(awRaw | jq -r '.reason' | grep -c 'IN-FLIGHT WAIT')" "0"
# A RELEASED wait must not count as a frozen turn-end: the release sits before the
# soft-lock counter's write, so it cannot consume the backstop's budget.
rm -f "$SD/.stall-block-count" "$SD/.agent-wait-count"
setstate '.expected_next_action="awaiting-agent"'; awD >/dev/null; awD >/dev/null
expect "Wait: a release leaves no .stall-block-count"     "$([ -f "$SD/.stall-block-count" ] && echo yes || echo no)" "no"
expect "Wait: the release IS counted in its own sidecar"  "$([ -f "$SD/.agent-wait-count" ] && echo yes || echo no)" "yes"
rm -f "$SD/.stall-block-count" "$SD/.agent-wait-count"

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

# ---- High-risk backstop -----------------------------------------------------
# `gates.merge.required` is written by the Phase-5 prompt (step 7b), never by
# anything mechanical, so a skipped step 7b left the land completely unguarded on
# exactly the runs the gate exists for. Observed in the wild: of the two local runs
# scoring effort.risk >= 6 against a threshold of 6, one armed the gate and the
# other reached phase:done with required:false, unstopped. The hook now recomputes
# the trigger instead of trusting the flag.
#
# The first assertion is the regression; the rest pin the boundaries, because a
# backstop that blocks more than it should is its own outage.
hr(){ printf '%s' "{\"approved\":true,\"phase\":\"$2\",\"effort\":{\"tier\":\"heavy\",\"risk\":$1},\"gates\":{\"merge\":{\"required\":$3,\"acked\":$4}}}" > "$ST"; }

hr 6 handover false false
expect "MG hi-risk: risk>=thr, gate never armed -> block(2)" "$(grun "$PUSH")" "2"
hr 8 handover false false
expect "MG hi-risk: risk above thr -> block(2)"              "$(grun "$PUSH")" "2"
hr 5 handover false false
expect "MG hi-risk: risk below thr -> allow(0)"              "$(grun "$PUSH")" "0"
hr 6 handover false true
expect "MG hi-risk: already acked -> allow(0)"               "$(grun "$PUSH")" "0"
hr 6 handover true false
expect "MG hi-risk: armed+unacked -> block(2) as before"     "$(grun "$PUSH")" "2"
hr 6 done false false
expect "MG hi-risk: run already done -> allow(0)"            "$(grun "$PUSH")" "0"

# Back-compat: a run scored before effort.risk existed, or scored with junk, must
# behave exactly as it did before this backstop. An unscored run is not a safe run,
# but it is also not evidence of risk, and blocking on absence would wedge every
# legacy state file.
printf '%s' '{"approved":true,"phase":"handover","effort":{"tier":"heavy"},"gates":{"merge":{"required":false,"acked":false}}}' > "$ST"
expect "MG hi-risk: no effort.risk -> allow(0)"              "$(grun "$PUSH")" "0"
printf '%s' '{"approved":true,"phase":"handover","effort":{"risk":"high"},"gates":{"merge":{"required":false,"acked":false}}}' > "$ST"
expect "MG hi-risk: non-numeric risk -> allow(0)"            "$(grun "$PUSH")" "0"

# The threshold is a setting, not a constant. A project that raises it must not be
# blocked at the old default — otherwise the backstop silently overrides config.
SFILE="$T/risk-settings.json"
grun_thr(){ printf '%s' "$PUSH" | CLAUDE_PROJECT_DIR="$T" AUTO_TASK_SETTINGS_FILE="$SFILE" bash "$GATE" >/dev/null 2>&1; echo $?; }
printf '%s' '{"settings_schema_version":3,"risk_gate_threshold":8}' > "$SFILE"
hr 6 handover false false
expect "MG hi-risk: project raised thr to 8, risk 6 -> allow(0)" "$(grun_thr)" "0"
hr 8 handover false false
expect "MG hi-risk: project thr 8, risk 8 -> block(2)"           "$(grun_thr)" "2"
printf '%s' '{"settings_schema_version":3,"risk_gate_threshold":4}' > "$SFILE"
hr 5 handover false false
expect "MG hi-risk: project lowered thr to 4, risk 5 -> block(2)" "$(grun_thr)" "2"
rm -f "$SFILE"

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
docs_concat_into LBRDME   # README.md + docs/*.md (see tests/lib/spec.sh)
# Clause 5's test changed from "two consecutive rounds with zero blockers and zero
# required" to a single NON-DECREASE, because the old form could not fire where the
# churn is: Gate B exits on the first clean pass, so a second consecutive clean
# round is never observed, and it is unreachable under a Gate B cap of 2. The old
# base line is retired in tests/spec-inventory.sh with that reasoning.
# GATE-B PASS-2: the round-7 comparand qualifier was REVERTED. Pass 2 measured that it did
# not deliver -- the surviving comparand is always the run's minimum, so a later reopening
# round fires either way -- so the over-claim in Step B was corrected instead and the rule
# removed. Back on the plain form, which is once again the only one shipped.
expect "Loop rule carries the converged clause"          "$(grep -c 'fails to DECREASE versus the previous round, the loop has CONVERGED' "$LBSKILL")" "1"
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
expect "spine: yield table five-value preamble" \
  "$(spine_has "$SPINE_ONLY" 'MUST be one of these five values at all times after')"                                   "yes"
# ---- Synchronous spawns + the bounded in-flight release, pinned in the spec -------
# The hook half is asserted behaviourally above ("In-flight Agent spawn"); these pin
# the prose half, because prose IS the behavior for everything a hook cannot observe —
# and a hook cannot observe an `Agent` spawn at all (PreToolUse is Bash-only), so the
# synchronous-spawn rule has no mechanical backstop and only these hold it.
expect "spine: yield table row — awaiting-agent semantics" \
  "$(spine_has "$SPINE_ONLY" '| `"awaiting-agent"` | A spawned Agent is in flight; its report has not arrived. Stop hook allows the yield, **capped**.')" "yes"
expect "spine: awaiting-agent row names the synchronous spawn as the reason it never applies" \
  "$(spine_has "$SPINE_ONLY" 'Spawn with `run_in_background: false` so this never applies.')"                          "yes"
expect "spine: the hook rule states the bounded exception" \
  "$(spine_has "$SPINE_ONLY" '**One bounded exception:** `"awaiting-agent"` releases the turn-end')"                   "yes"
expect "spine: the exception names its cap variable" \
  "$(spine_has "$SPINE_ONLY" 'AUTO_TASK_AGENT_WAIT_LIMIT` (default 3) consecutive turn-ends in an unchanged state, then blocks again')" "yes"
expect "spine: the exception refuses to be read as a resting place" \
  "$(spine_has "$SPINE_ONLY" 'never a way to rest')"                                                                   "yes"
expect "spine: every Agent spawn is synchronous, critique included" \
  "$(spine_has "$SPINE_ONLY" '- Each Agent spawn (Phase-1 critique, Gate A, Gate B) is **synchronous** — pass `run_in_background: false`')" "yes"
# The legal-value list must be stated ONCE. A second enumeration is how this rule
# drifts: the fifth value would have had to be added in both places, and the copy
# that was missed would read as a prohibition. Assert the deferral, and assert the
# retired enumeration has not crept back.
expect "spine: the non-negotiables bullet defers instead of re-enumerating" \
  "$(spine_has "$SPINE_ONLY" 'The legal values are enumerated ONCE, in the "Yield-point contract" table above — defer to it, never restate it here.')" "yes"
expect "spine: the retired second enumeration is GONE" \
  "$(grep -c 'The only legitimate user-\* values are' "$SPINE_ONLY")"                                                  "0"
# The JSON SKELETON is the enumeration the prose-level deferral above cannot reach, and
# it is the copy the model reads on every turn. It went stale in exactly this change —
# the sibling in ARCHITECTURE.md was updated and this one was not, leaving the skeleton
# contradicting the value table four lines away and telling the model the fallback value
# is illegal. Pin BOTH copies, and pin them by the full value list so a future value has
# to update them or redden here.
AW_ARCH="$HOOKS/../skills/auto-task/ARCHITECTURE.md"
expect "spine: JSON skeleton enum carries every legal value" \
  "$(spine_has "$SPINE_ONLY" '"expected_next_action": "auto-continue|user-approval|user-push-prompt|awaiting-agent|null",')" "yes"
expect "spine: ARCHITECTURE skeleton enum matches the spine's" \
  "$(spine_has "$AW_ARCH" '"expected_next_action": "auto-continue|user-approval|user-push-prompt|awaiting-agent|null",')" "yes"
expect "spine: no skeleton still carries the retired four-value enum" \
  "$(cat "$SPINE_ONLY" "$AW_ARCH" | grep -c '"expected_next_action": "auto-continue|user-approval|user-push-prompt|null"')" "0"
# Reference half: all THREE spawn sites and the two prohibitions. Gate A owns the
# canonical statement; Gate B and the Phase-1 critique defer to it. The critique site
# is pinned separately and deliberately — it lives in a different reference file, it
# was the site the observed PLAN run thrashed on, and it is the one spawn the Gate A
# rule cannot reach by proximity.
AW_GATES="$HOOKS/../skills/auto-task/references/phase-3-gates.md"
AW_PRE="$HOOKS/../skills/auto-task/references/phase-1-preamble.md"
expect "spine: Gate A spawn passes run_in_background false" \
  "$(spine_has "$AW_GATES" 'pass `run_in_background: false` per the synchronous-spawn rule above')"                    "yes"
expect "spine: Gate B spawn passes run_in_background false" \
  "$(spine_has "$AW_GATES" 'pass `run_in_background: false` per the synchronous-spawn rule at Gate A')"                "yes"
expect "spine: Phase-1 critique spawn passes run_in_background false" \
  "$(spine_has "$AW_PRE" '**Spawn the critique agent SYNCHRONOUSLY: pass `run_in_background: false`.**')"               "yes"
expect "spine: the synchronous-spawn rule covers every spawn site" \
  "$(spine_has "$AW_GATES" 'This applies at every Agent spawn site in the pipeline — Gate A, Gate B, and the Phase-1 critique.')" "yes"
expect "spine: transcript files are not a completion signal" \
  "$(spine_has "$AW_GATES" "A subagent's transcript file is not a completion signal.")"                                "yes"
expect "spine: a timeout is not a result" \
  "$(spine_has "$AW_GATES" '**A timeout is not a result.**')"                                                          "yes"
expect "spine: the critique site carries both prohibitions too" \
  "$(spine_has "$AW_PRE" 'a subagent'"'"'s transcript file is not a completion signal')"                               "yes"
expect "spine: the in-flight fallback yields rather than polls" \
  "$(spine_has "$AW_GATES" 'wait by YIELDING — never by polling')"                                                     "yes"

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

# Phase 4's ANTI-STALL body stays WHOLLY inline — it is the anti-stall keystone, and
# that half is unchanged. NARROWED when Phase 4 became a graded, bounded loop: its
# round-grading LADDER now lives in references/phase-3-gates.md
# ("phase-4-round-mechanics"), beside the Gate B ladder whose reopen test it applies by
# reference. That siding is the point — two copies of a reachability test would drift,
# which is the failure the shared test exists to prevent — and the spine had 47 bytes of
# headroom against a hard ceiling, so an inline ladder was not affordable regardless.
# Phase 4 therefore now follows the SAME shape as Phase 3 / Gate A / Gate B: ladder in
# the reference, non-negotiables restated inline, and those bullets guarded below.
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
# Phase 4's graded round contract: the ladder is in the reference, so these four inline
# bullets are the whole mitigation against the reference never being read. Assert their
# BODIES in SKILL.md specifically — the heading-only shape a Gate B round already caught
# elsewhere would let them be relocated with the suite green.
expect "spine: Phase 4 cites phase-3-gates" \
  "$(spine_has "$SPINE_ONLY" 'references/phase-3-gates.md` ("phase-4-round-mechanics")')"                            "yes"
expect "spine: P4 non-negotiable — reachability test" \
  "$(spine_has "$SPINE_ONLY" '**A finding costs a round only if it (a) breaks an approved AC')"                       "yes"
# GATE A FINDING (weakly-satisfied AC 13, residual B). The fail-closed rule originally
# keyed on a literal `ac:` field, copied from Gate B — where the VERIFIER PROMPT mandates
# that field. `auto-task-code-review` emits `file:line` + a severity label and no `ac:`
# at all, so read literally every Phase-4 finding failed closed, reopened the loop, and
# the deferral path was unreachable: the contract was inert. It now says the orchestrator
# grades from PLAN.md's AC table and the diff, and fails closed on ITS OWN uncertainty.
# Both halves are pinned, because dropping either restores the inert reading.
# RE-AIMED: the reviewer now STATES `ac:`/`reachable:`, so pinning "emits no such field"
# would freeze a false claim in the always-loaded spine. The property being guarded is
# unchanged and is what the two halves still assert together: the ORCHESTRATOR grades, and
# a reviewer-supplied field is an input rather than the verdict. The hazard inverted (a
# rule waiting for an absent field → a rule obeying a present one), so the assertion
# follows it rather than the old wording.
expect "spine: P4 non-negotiable — the orchestrator grades" \
  "$(spine_has "$SPINE_ONLY" '**YOU grade it** — `auto-task-code-review` now states `ac:`/`reachable:` per finding, but those are INPUTS')" "yes"
expect "spine: P4 non-negotiable — a supplied field never decides" \
  "$(spine_has "$SPINE_ONLY" 'neither does a reviewer-supplied field')"                                                 "yes"
expect "spine: P4 non-negotiable — the retired 'emits no' claim is gone" \
  "$(grep -c 'emits no `ac:`' "$SPINE_ONLY" | tr -d ' ')"                                                               "0"
expect "spine: P4 non-negotiable — fail closed on uncertainty" \
  "$(spine_has "$SPINE_ONLY" '**fail closed on your own uncertainty:** a finding you cannot place counts as AC-breaking')" "yes"
expect "spine: P4 non-negotiable — deferred batch" \
  "$(spine_has "$SPINE_ONLY" 'is DEFERRED to `gates.code_review.deferred[]` — not parked, and costs no round')"       "yes"
expect "spine: P4 non-negotiable — batch spent once" \
  "$(spine_has "$SPINE_ONLY" '**The batch is spent once per run**')"                                                  "yes"
# GATE A FINDING (residual A), and its RESOLUTION HISTORY, because the shape of the answer
# changed twice. On STANDARD/HEAVY a post-batch non-reopening finding parks safely, since
# Gate B re-applies the identical test. LIGHT now runs Gate B too (one pass), so that park
# is re-graded at every tier and the residual this described is closed. A
# LIGHT-only HOLD was implemented to close it, and then REMOVED at Gate B pass 3: it had to
# be restated at every site stating the advance, and across three gates it produced more
# defects in its own hardening than the hole could cost — LIGHT is max(D,R)<=2, and a
# non-reopening finding breaks no AC, is not runtime-reachable and is not a security path.
# The gap was an accepted, documented limitation and is now CLOSED: `lb_gate_b_cap light`
# moved 0 -> 1, so Gate B re-grades a parked finding at every tier. This assertion used to
# pin the pre-closure clause verbatim, and by doing so it actively HELD a false claim in
# the always-loaded spine for a whole release -- one of four survivors the closure's own
# sweep missed, and the only one wearing a green assertion. What it pins now is the
# uniform rule plus the uniform re-grade; the retired clause's ABSENCE is pinned in
# tests/gate-b-loop.test.sh, which owns the LIGHT-closure sweep and is already excluded
# from it, so the retired phrasing does not have to be quoted here. NOTE the surviving
# wording: "Once spent — at any later round, not just the batch round". The
# batch-round-scoped phrasing it replaced was a live defect (Gate A round 3), and the
# assertion that pinned it green is why the cross-file group in gate-b-loop.test.sh now
# exists — the same lesson this line just re-taught.
expect "spine: P4 non-negotiable — post-batch parks at EVERY tier" \
  "$(spine_has "$SPINE_ONLY" '**parks at every tier**, where Gate B re-grades it at every tier too')" "yes"
expect "spine: ...and the removed LIGHT hold has not crept back" \
  "$(grep -ciE 'surfaces on LIGHT|hold the gate' "$SPINE_ONLY" | tr -d ' ')" "0"
expect "spine: P4 non-negotiable — record every round" \
  "$(spine_has "$SPINE_ONLY" '**Record the round on EVERY exit, reopen included.**')"                                 "yes"
expect "spine: P4 non-negotiable — reopened is the basis" \
  "$(spine_has "$SPINE_ONLY" '**`reopened` is the declared convergence basis, never the label counts.**')"            "yes"
expect "spine: P4 non-negotiable — minimal fix" \
  "$(spine_has "$SPINE_ONLY" '**Minimal fix.** Correct the defect in place')"                                         "yes"
# NEGATIVE CONTROL, and the load-bearing one: the entire change is that a severity LABEL
# no longer decides whether a round is spent. If the old unconditional sentence returns
# by revert or bad merge, the grading above is dead prose. This must go red then.
expect "spine: P4 label-driven step is GONE" \
  "$(spine_has "$SPINE_ONLY" 'If any Blocker or Required: apply the fix(es)')"                                        "no"
# The convergence test must be named as a Phase-4 surfacing trigger, not only at Gate B.
expect "spine: P4 exit names the convergence test" \
  "$(spine_has "$SPINE_ONLY" 'a fired convergence test** (`reopened` did not decrease)')"                             "yes"

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
  "$(grep -oE 'enforcement-spine\.test\.sh`\*\* \(([0-9]+) assertions' "$HOOKS/../CHANGELOG.md" | grep -oE '[0-9]+' | head -1)" \
  "$(grep -cE '^expect "spine: ' "$HOOKS/../tests/enforcement-spine.test.sh" | tr -d ' ')"
# CODE-REVIEW ROUND 2: the sibling gate-b-loop figure on that same CHANGELOG line was the
# only count NOT pinned, and it promptly rotted (463 stated, 465 actual) when a later fix
# added two assertions after the figures had been synced. The comment above says these
# counts rot and must be pinned; this is the one that was missed.
expect "spine: CHANGELOG gate-b-loop count is current" \
  "$(grep -oE 'gate-b-loop\.test\.sh` grows to \*\*([0-9]+) assertions' "$HOOKS/../CHANGELOG.md" | grep -oE '[0-9]+' | head -1)" \
  "$(bash "$HOOKS/../tests/gate-b-loop.test.sh" </dev/null 2>&1 | grep -oE 'PASS=[0-9]+' | head -1 | grep -oE '[0-9]+')"

# GATE-B ROUND-4 FINDING: README carried its own size claim and its own "no behavior
# change" assertion, and neither was pinned — the CHANGELOG's equivalent number had already
# rotted twice. README is the marketplace-published doc, so pin its number too.
expect "spine: README size claim matches the actual spine" \
  "$(grep -oE '\*\*[0-9,]+ B to [0-9,]+ B' "$LBRDME" | head -1 | sed 's/.* to //' | tr -d ', B')" \
  "$(wc -c < "$SPINE_ONLY" | tr -d ' ')"
expect "spine: README does not claim a pure no-behavior-change move" \
  "$(grep -c 'with no behavior change: the content is relocated' "$LBRDME")" "0"

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

# ─────────────────────────────────────────────────────────────────────────────
# GATE B IS BOUNDED. Measured across seven completed runs, Gate B ran 4-11
# adversarial passes each, required-finding counts never decayed (3,2,3,3,3,2,3,4,0
# over nine passes in one HEAVY run), blockers first appeared at passes 3 and 5
# rather than pass 1 -- each pass's fixes manufactured the next pass's findings --
# and three of the seven runs ended by human fiat. Two properties made it
# unbounded: a finding's SELF-ASSIGNED SEVERITY drove control flow regardless of
# whether it touched an Acceptance Criterion, and nothing counted the passes.
#
# These assertions pin the rules that close both. The decision LOGIC is exercised
# against oracles in tests/gate-b-loop.test.sh; what is pinned here is that the
# rules are actually stated in the shipped spec, since the spec IS the behavior.
# Each assertion keys on text unique to the rule it guards -- never on a word the
# rest of the spec also uses -- per the yield-table finding above.
GATESREF="$HOOKS/../skills/auto-task/references/phase-3-gates.md"
SCHEMAREF="$HOOKS/../skills/auto-task/references/state-schema.md"

# (1) AC-GATED RESOLUTION. The three reopen conditions must be stated as the ONLY
# grounds for reopening, and the park-otherwise rule must say it overrides the label.
expect "gate-b: reopen condition (a) breaks an AC" \
  "$(spine_has "$GATESREF" '**(a) It breaks an approved Acceptance Criterion**')"                     "yes"
expect "gate-b: reopen condition (b) runtime-reachable" \
  "$(spine_has "$GATESREF" '**(b) It is a runtime-reachable regression or bypass in the diff**')"     "yes"
expect "gate-b: reopen condition (c) security/data-loss" \
  "$(spine_has "$GATESREF" '**(c) It is a security or data-loss path**')"                             "yes"
expect "gate-b: reopen is if-and-only-if those three" \
  "$(spine_has "$GATESREF" 'Reopen Phase 4 for a finding if and only if AT LEAST ONE holds')"         "yes"
expect "gate-b: park-otherwise overrides the label" \
  "$(spine_has "$GATESREF" 'Every other finding parks in `state.followups`, whatever its label')"     "yes"
expect "gate-b: severity does not decide control flow" \
  "$(spine_has "$GATESREF" 'A finding'"'"'s severity label does not decide control flow.')"           "yes"
expect "gate-b: fail closed on a missing ac: field" \
  "$(spine_has "$GATESREF" '**Fail closed on a missing fact.**')"                                    "yes"
# The verifier must REPORT the two facts the decision consumes, or the rule above
# has no input and the fail-closed default fires on every finding.
AGENTF="$HOOKS/../agents/task-execution-verifier.md"
expect "gate-b: verifier output carries ac:"        "$(spine_has "$AGENTF" '- ac: <the number of the Acceptance Criterion')" "yes"
expect "gate-b: verifier output carries reachable:" "$(spine_has "$AGENTF" '- reachable: runtime | spec-only | docs-only')"  "yes"
expect "gate-b: verifier told they are facts not judgment" \
  "$(spine_has "$AGENTF" 'These are inputs the orchestrator acts on; your severity label is not.')"  "yes"

# (2) SELF-INFLICTED ATTRIBUTION. Content-hashed, and the SECOND such pass (not two
# consecutive) surfaces -- two-consecutive is unfirable under a cap of 2, which is
# the dead-clause defect the convergence test below exists to remove.
expect "gate-b: self_inflicted is content-hashed, not coordinates" \
  "$(spine_has "$GATESREF" '**Hash the content; never store line numbers.**')"                       "yes"
expect "gate-b: second (not consecutive) self_inflicted pass surfaces" \
  "$(spine_has "$GATESREF" '**The second pass with `self_inflicted: true` — not necessarily consecutive — surfaces to the user.**')" "yes"

# (3) PASS CAP + DELTA SCOPE. The caps must come from the shared helper, and the
# spec must NOT restate the numbers, or the single-definition property is lost.
expect "gate-b: main cap read from lb_gate_b_cap"     "$(spine_has "$GATESREF" 'lb_gate_b_cap <tier>')"        "yes"
expect "gate-b: re-gate cap read from its own helper" "$(spine_has "$GATESREF" 'lb_gate_b_regate_cap')"        "yes"
expect "gate-b: never hardcode the cap numbers"       "$(spine_has "$GATESREF" '**Never hardcode the numbers here**')" "yes"
expect "gate-b: delta-scoped after pass 1" \
  "$(spine_has "$GATESREF" '**Every later pass reads only what changed since the previous pass of that scope**')" "yes"
expect "gate-b: verified_diff_sha uses the reviewed_diff_sha formula" \
  "$(spine_has "$GATESREF" 'the **byte-identical** pinned-flag formula `reviewed_diff_sha` uses')"   "yes"
# The pinned-flag string must be ONE spelling across every site that computes a
# diff hash. Count > distinct proves each site exists; distinct == 1 proves identity.
# The `reviewed_diff_sha` copy moved from SKILL.md to state-schema.md when Phase 4
# became a graded loop: the spine needed the bytes, and the schema is where Gate B's
# `verified_diff_sha` note already pointed for "the byte-identical formula", so ONE
# copy now serves the spine, Gate B and the hook instead of three near-copies.
PINFLAGS='--no-color --no-ext-diff --no-textconv --no-renames --diff-algorithm=myers --src-prefix=a/ --dst-prefix=b/'
expect "gate-b: pinned diff flags occur at 3 sites" \
  "$(grep -ohF -- "$PINFLAGS" "$SCHEMAREF" "$GATESREF" "$HOOKS/enforce-gates.sh" | wc -l | tr -d ' ')" "3"
expect "gate-b: pinned diff flags are byte-identical everywhere" \
  "$(grep -ohF -- "$PINFLAGS" "$SCHEMAREF" "$GATESREF" "$HOOKS/enforce-gates.sh" | sort -u | wc -l | tr -d ' ')" "1"
# ...and the spine must no longer carry its own copy, or the relocation was cosmetic.
expect "gate-b: the spine carries no duplicate flag copy" \
  "$(grep -cF -- "$PINFLAGS" "$SPINE_ONLY" | tr -d ' ')" "0"

# (4) ENTRY BUDGET CHECK. The whole point is that it fires where the commit-time
# block cannot: this loop never commits.
expect "gate-b: budget checked at entry via the helper" \
  "$(spine_has "$GATESREF" '**Check the fix-loop budget HERE, not only at commit time.**')"          "yes"
expect "gate-b: entry check names lb_effective_budget" "$(spine_has "$GATESREF" 'lb_effective_budget <cap> <acked_through>')" "yes"

# (5) OVER-CAP SURFACE + THE THREE GRANTS. None may be self-granted, and a resumed
# run must act on the recorded grant rather than asking again.
expect "gate-b: at the cap it surfaces, not auto-continues" \
  "$(spine_has "$GATESREF" '**surface — do not auto-continue.**')"                                   "yes"
# GATE-A ROUND-2 FINDING: convergence and the cap had been conflated into one
# surface trigger, contradicting loop-rule clause 5 ("park the remaining findings
# and advance") and implying a yield the yield-point table does not list. They are
# now distinct: convergence is the AUTONOMOUS exit, the cap and the self-inflicted
# signal are the human check-ins. Pin both halves.
# CODE-REVIEW FINDING (Blocker): convergence was an unconditional "park and advance",
# but its count is scoped to REOPENING findings — AC breaches, runtime-reachable
# regressions, security paths. So a non-decreasing count shipped exactly those,
# unseen, on a laxer test than the cap path applies to the same evidence. The two
# cases are now disjoint: zero reopening left → autonomous exit; any still open →
# surface. Pin both, and pin that nothing meeting (a)/(b)/(c) escapes either way.
expect "gate-b: three triggers reach the surface" \
  "$(spine_has "$GATESREF" '**Three triggers reach this surface:**')"                                 "yes"
expect "gate-b: a fired convergence test is one of them" \
  "$(spine_has "$GATESREF" 'or **a fired convergence test** (Step 3)')"                               "yes"
# REVIEW ROUND 3: Step 4 kept the two-case qualifier after round 2 deleted the branch
# it referred to, and NOTHING asserted that paragraph — which is why it drifted. Close
# the class the way this diff already closes it twice elsewhere: pin each superseded
# phrasing to zero, so a reintroduction reddens instead of reading as a live option.
expect "gate-b: the retired two-case qualifier is gone" \
  "$(spec_count 'convergence test fired with one or more reopening findings still open')"             "0"
expect "gate-b: the retired disjoint-case claim is gone" \
  "$(spec_count 'applies to the disjoint case where')"                                                "0"
# REVIEW ROUND 4: the trigger LIST was renumbered to three but the sentence that says
# what to DO still read "either of those two triggers" -- and it is the actionable
# line, so a reader could exclude the convergence trigger from the surface rule and
# undo round 2's fix. Negative guards cover retired phrasings; a stale COUNT needs the
# action sentence pinned positively, which is what this does.
expect "gate-b: the surface instruction covers all three triggers" \
  "$(spine_has "$GATESREF" 'On any of those triggers, **surface — do not auto-continue.**')"          "yes"
expect "gate-b: no stale two-trigger count survives" \
  "$(spec_count 'either of those two triggers')"                                                      "0"
# REVIEW ROUND 2: the first fix split convergence into two cases, but the
# zero-reopening case is UNREACHABLE -- the resolution step already passes the gate
# when nothing reopens, so a fired convergence test always has a live finding. The
# branch was deleted rather than guarded: surfacing is now the test's only outcome,
# and clause 5's park-and-advance is located where it actually happens.
expect "gate-b: surfacing is convergence's only outcome" \
  "$(spine_has "$GATESREF" '**Surfacing (Step 4) is the only outcome this test has**')"               "yes"
expect "gate-b: convergence is reached only with a finding open" \
  "$(spine_has "$GATESREF" 'a zero-reopening pass has already passed the gate at Step 2')"            "yes"
expect "gate-b: clause 5 park-and-advance is located, not weakened" \
  "$(spine_has "$GATESREF" 'at Gate B that outcome is Step 2'"'"'s zero-reopening exit')"             "yes"
# GATE-B ROUND-1 FINDING (Blocker): clause 5's SPINE headline still read "park the
# remaining findings and advance" unqualified. The Gate-B carve-out below scopes only
# Gate B, so at Phase 3/4 the headline licensed parking live blockers/required --
# contradicting Phase 4's own exit condition ("no Blockers/Required"). Convergence now
# resolves to a SURFACE in every loop; park-and-advance is a user grant.
expect "spine: clause 5 converges to a surface, in every loop" \
  "$(spine_has "$SPINE_ONLY" 'the loop has CONVERGED: stop fixing and SURFACE')"                      "yes"
expect "spine: park-and-advance is a grant, never self-granted" \
  "$(spine_has "$SPINE_ONLY" 'in NO loop does an unfixed blocker or required finding pass a gate on this test alone')" "yes"
expect "spine: the retired unconditional park headline is gone" \
  "$(spec_count 'CONVERGED: park the remaining findings and advance')"                                "0"
# GATE-B ROUND-1 FINDING (Blocker): grant (ii) said only "pass the gate", so it passed
# over the very (a)/(b)/(c) finding that raised the surface -- the carve-out below was
# scoped to "a subsequent pass", which never runs on that path.
expect "gate-b: grant (ii) carves out the findings already on the table" \
  "$(spine_has "$GATESREF" 'pass the gate **only once nothing on the table meets (a)/(b)/(c)**')" "yes"
expect "gate-b: park_non_blocking binds the current table too" \
  "$(spine_has "$GATESREF" 'both the findings on the table when it was granted and those of every subsequent pass')" "yes"
expect "gate-b: no subsequent-pass-only carve-out survives" \
  "$(spec_count 'When set, a subsequent pass parks every finding')"                                   "0"
# GATE-B ROUND-1 FINDING (Required): every Step-2 branch terminated the gate, so Step 3
# -- which appends passes[] -- was unreachable on the reopen path, disarming the cap,
# self_inflicted and convergence on the one path they bound.
expect "gate-b: the pass is recorded on every exit, reopen included" \
  "$(spine_has "$GATESREF" '**Record the pass FIRST (Step 3), on every exit — reopen included.**')"   "yes"
# GATE-B ROUND-1 FINDING (Required): the delta command diffed against a BLOB hash,
# which is not a commit-ish, so pass 2 could not execute it.
expect "gate-b: verified_diff_sha is an equality token, not a revision" \
  "$(spine_has "$GATESREF" '**`verified_diff_sha` is an equality token, not a revision**')"           "yes"
expect "gate-b: later passes never get the full diff again" \
  "$(spine_has "$GATESREF" 'every later pass gets the Step-1 delta instead, never this full diff')"    "yes"
# GATE-B PASS-2 FINDING (Blocker): the boundary was snapshotted at the END of a pass,
# i.e. from the POST-fix tree, so the next pass's delta came back empty and the
# self-inflicted defects the ladder exists to catch were the one thing it never saw.
expect "gate-b: the boundary is snapshotted at pass start" \
  "$(spine_has "$GATESREF" '**Snapshot the boundary when the pass STARTS')"                           "yes"
expect "gate-b: no end-of-pass boundary refresh survives" \
  "$(spec_count 'Refresh `verified_diff_sha` at the end of every pass')"                              "0"
# GATE-B PASS-3 FINDING (Blocker): the fix landed in phase-3-gates.md only. state-schema.md
# -- the per-FIELD contract an orchestrator reads for this very field -- still said
# "Refresh it every pass; never carry a stale value forward", a direct counter-rule, and the
# negative guard above could not see it because it greps the other file's wording. Pin the
# schema side positively AND ban its retired phrasing (TRACE's Gate-A round-3 lesson: when a
# rule changes, grep EVERY site that restates it).
expect "gate-b: the schema states the boundary is set at spawn" \
  "$(spine_has "$SCHEMAREF" '**Set it when a pass SPAWNS, from the same diff handed to that pass')"   "yes"
expect "gate-b: no per-pass refresh phrasing survives anywhere" \
  "$(spec_count 'Refresh it every pass; never carry a stale value forward')"                          "0"
# GATE-B PASS-3 FINDING (Required): the convergence test declared `reopened` as its basis
# but the recorded row held only LABEL counts, so the test had to fall back to the basis the
# ladder calls untrustworthy. The row now carries `reopened`.
expect "gate-b: the row records the reopening count" \
  "$(spine_has "$GATESREF" '**`reopened` (the count of findings that met (a)/(b)/(c)')"               "yes"
expect "gate-b: the schema row carries reopened too" \
  "$(spine_has "$SCHEMAREF" '`reopened` is the count of findings that met the Step-2 reopen test')"    "yes"
expect "gate-b: no reopened-less row shape survives" \
  "$(spec_count '{ n, scope, blockers, required, followups, self_inflicted, fixed_lines, diff_sha, at }')" "0"
expect "gate-b: the test reads reopened, not the label counts" \
  "$(spine_has "$GATESREF" "reading both from the rows' \`reopened\` field")"                        "yes"
# GATE-B PASS-2 FINDING (Required): "record FIRST" demanded fixed_lines/self_inflicted,
# neither knowable until after the fix round -- so the rule was unfollowable and
# passes[] stayed empty either way.
expect "gate-b: the record splits the fields knowable now from the later ones" \
  "$(spine_has "$GATESREF" '**Append the row with the fields knowable now**')"                        "yes"
# GATE-B PASS-2 FINDING (Required): Step 0 added the granted allowance to the SPENT
# count, so grant (i) left the scope still at cap and re-surfaced the same check-in --
# the opposite sign from the oracle (cap + ack - used), which is why nothing reddened.
expect "gate-b: a granted allowance raises the cap, not the spent count" \
  "$(spine_has "$GATESREF" '**A granted allowance raises the CAP; it never adds to the spent count**')" "yes"
expect "gate-b: no allowance-added-to-spent phrasing survives" \
  "$(spec_count 'plus `gates.gate_b.allowance_acked[<scope>]` if the user granted extra')"            "0"
# GATE-B PASS-2 FINDING (Required): the pass-1 fix over-corrected -- an unconditional
# SURFACE made a CLEAN Phase-4 round converge-and-yield, contradicting the spine's own
# "a clean pass advances to Gate B ... Continue".
expect "spine: a clean round takes its clean exit, never the surface" \
  "$(spine_has "$SPINE_ONLY" 'has nothing to park and takes its loop'"'"'s clean exit, never surfacing')" "yes"
expect "spine: the retired always-converges claim is gone" \
  "$(spec_count 'One round fires it; a clean round of course also converges')"                        "0"
expect "gate-b: the delta is executable against a saved diff file" \
  "$(spine_has "$GATESREF" 'gate-b-<scope>-<n>.diff')"                                                "yes"
expect "gate-b: the unrunnable tree-diff command is gone" \
  "$(spec_count "recorded verified_diff_sha's tree")"                                                 "0"
expect "gate-b: the deleted unreachable branch is gone" \
  "$(spec_count '**Zero reopening findings open**')"                                                  "0"
expect "gate-b: nothing meeting (a)/(b)/(c) escapes the gate unseen" \
  "$(spine_has "$GATESREF" 'nothing meeting (a)/(b)/(c) ever leaves this gate without either a fix or a recorded human grant')" "yes"
# CODE-REVIEW FINDING (Required): park_non_blocking parked an AC-breaking `required`,
# and Phase 5's completion check reads only requirement STATUS, so it shipped silent.
# REVIEW ROUND 2: the carve-out covered (a) only, so (b) runtime regressions and (c)
# security paths were still routed by SEVERITY LABEL -- the basis this ladder opens by
# rejecting. It now carves out the same (a)/(b)/(c) set the convergence test uses.
expect "gate-b: park_non_blocking carves out the full reopen test" \
  "$(spine_has "$GATESREF" 'nor a finding meeting the Step-2 reopen test — (a) an AC breach, (b) a runtime-reachable regression or bypass, or (c) a security/data-loss path')" "yes"
expect "gate-b: the carve-out is mandatory and symmetric" \
  "$(spine_has "$GATESREF" '**The (a)/(b)/(c) carve-out is not optional, and it is deliberately the same set the convergence test uses.**')" "yes"
expect "gate-b: no (a)-only carve-out survives" \
  "$(spec_count '**The (a) carve-out is not optional.**')"                                            "0"
# CODE-REVIEW FINDING (Required): content-only hashing collides on duplicate lines.
expect "gate-b: attribution skips structural/blank added lines" \
  "$(spine_has "$GATESREF" 'skip lines that are blank, whitespace-only, or pure structure')"          "yes"
expect "gate-b: attribution requires a unique match" \
  "$(spine_has "$GATESREF" 'a match counts only if that content occurs exactly once in the file now')" "yes"
expect "gate-b: surface shows the per-pass severity table" \
  "$(spine_has "$GATESREF" '**per-pass severity table**')"                                          "yes"
expect "gate-b: grant (i) one more pass"   "$(spine_has "$GATESREF" '**One more pass**')"            "yes"
expect "gate-b: grant (ii) park and advance" "$(spine_has "$GATESREF" '**Park and advance**')"       "yes"
expect "gate-b: grant (iii) descope the residual" "$(spine_has "$GATESREF" '**Descope the residual**')" "yes"
expect "gate-b: resume acts on the recorded grant" \
  "$(spine_has "$GATESREF" 'do not re-surface the same check-in')"                                   "yes"
expect "gate-b: park_non_blocking precedence over fail-closed" \
  "$(spine_has "$GATESREF" 'it is evaluated BEFORE Step 2'"'"'s fail-closed rule')"                  "yes"
expect "gate-b: park_non_blocking is user-set only" \
  "$(spine_has "$GATESREF" '**a checkable artifact, never set speculatively.**')"                    "yes"
# Legacy tolerance: a run started before these fields existed must not be blocked.
expect "gate-b: absent passes[] counts as zero" \
  "$(spine_has "$GATESREF" '**An absent `passes[]` counts as 0**')"                                  "yes"

# (6) THE SPINE'S OWN RESTATEMENT. The spine is what is loaded every turn, so the
# bound must be visible there too -- not only in the reference.
expect "spine: gate-b is bounded, with the measured evidence" \
  "$(spine_has "$SPINE_ONLY" '**This gate is BOUNDED — it does not converge on its own.**')"         "yes"
# GATE-A ROUND-2 FINDING: the bullet's OPENING was pinned but its body was not, so
# replacing "cap them from <helper>" with hardcoded numbers violated a stated rule
# and tripped only the incidental byte-size assertions. Pin the mechanism itself.
expect "spine: gate-b caps come from the helper, never hardcoded" \
  "$(spine_has "$SPINE_ONLY" 'cap them from `lb_gate_b_cap` / `lb_gate_b_regate_cap` (**never hardcode**)')" "yes"
expect "spine: gate-b entry checks the budget (not only at commit)" \
  "$(spine_has "$SPINE_ONLY" 'check the fix-loop budget at **entry**')"                              "yes"
expect "spine: gate-b delta-scopes later passes" \
  "$(spine_has "$SPINE_ONLY" 'delta-scope each later pass via `gates.gate_b.verified_diff_sha`')"     "yes"
expect "spine: gate-b AC-gated reopen restated inline" \
  "$(spine_has "$SPINE_ONLY" 'A finding reopens Phase 4 only if it (a) breaks an approved AC')"      "yes"
expect "spine: gate-b at-cap surface restated inline" \
  "$(spine_has "$SPINE_ONLY" '**At the cap, SURFACE — never auto-continue and never self-grant.**')" "yes"
# GATE-A FINDING: this keyed only on the row's LEFT cell, so inverting the row's
# VALUE to `"auto-continue"` — which reverses the behaviour the surface exists to
# provide, and which prevent-mid-protocol-stall.sh reads BY VALUE at :107-111 —
# added zero assertion failures. Pin the whole row, value included, and pin the
# prose that actually sets the field. Same shape as the yield-table finding above:
# a location guard must key on text unique to the contract, never on half a row.
expect "spine: yield-table row for the over-cap surface" \
  "$(spine_has "$SPINE_ONLY" '| Gate B at its cap with no pass run, or on a reopening pass: at its cap, a second `self_inflicted` pass, or a fired convergence test | `"user-approval"` |')" "yes"
# CODE-REVIEW FINDING (Required): the reopening precondition was stated absolutely at
# the four SUMMARY sites, so the PRE-SPAWN arrival -- Step 0 item 5, where the scope is
# already at its cap and NO pass is spawned -- had no row here at all. With the table's
# default being auto-continue and `| Gate B pass | "auto-continue" |` the only other
# Gate-B row, a model resolving spine-vs-reference in favour of the always-loaded spine
# could auto-continue or self-grant on the one path the cap exists to bound. Reachable:
# grant "one more pass" at the cap, that pass reopens, Phase 4, re-enter Gate B on a
# spent allowance -> pre-spawn arrival, no pass to be "reopening". Pin BOTH arrivals.
expect "gate-b: the yield row covers the pre-spawn (no pass run) arrival" \
  "$(grep -c '^| Gate B .*no pass run.*`"user-approval"` |' "$SPINE_ONLY" | tr -d ' ')"              "1"
expect "gate-b: the over-cap surface sets user-approval (not auto-continue)" \
  "$(spine_has "$GATESREF" 'Set `expected_next_action: "user-approval"` and show the **per-pass severity table**')" "yes"
# And the inverse must be absent: no Gate-B surface may be wired to auto-continue.
# GATE-A FINDING (this run): the pattern keyed on the row's OLD prefix
# (`| Gate B at its cap`). Renaming the row left this grep matching nothing, so it read
# 0 — and kept reading 0 with the row's value flipped to `"auto-continue"`. A guard that
# cannot match the row it guards is vacuous, which is the exact shape of the finding that
# created it. It then went vacuous a SECOND time when the row was reworded again to cover
# the pre-spawn arrival, so it is now keyed on `convergence test` — a phrase in the row's
# TAIL, unique to the surface row, and untouched by any prefix rewording. Keeping it
# narrower than `^| Gate B ` still matters: `| Gate B pass | "auto-continue" |` (:306) is
# a legitimate auto-continue yield.
expect "gate-b: over-cap row is not wired to auto-continue" \
  "$(grep -c '^| Gate B .*convergence test.*auto-continue' "$SPINE_ONLY" | tr -d ' ')"              "0"

# ---- Gate B clean-exit precedence: a zero-reopening pass never reaches Step 4 ----
# A measured run surfaced on a pass that recorded reopened:0 -- it was at the cap and
# the 2nd self_inflicted -- and then, one pass later, DECLINED to surface in the same
# situation, reasoning in its own record that the gate had already passed at Step 2.
# The rule was right and unwritten, so the pipeline improvised it inconsistently.
# These pins put it at every site that states the trigger set. Each is ANCHORED to a
# landmark on the same line: a bare presence grep would be satisfied by the phrase
# turning up at some other site in the same file, which is how one edit can green a
# criterion that names a different site.
# CODE-REVIEW ROUND 2: this stopped before the pre-spawn clause, so the guard for the
# round-1 Required finding did not cover the clause that finding added. Extended past
# the semicolon at all three summary sites (here, ARCHITECTURE and README below).
expect "spine: gate-b bullet carries the clean-exit precedence" \
  "$(grep -c 'At the cap, SURFACE.*never a zero-reopening pass.*pre-spawn at-cap arrival always surfaces' "$SPINE_ONLY" | tr -d ' ')" "1"
expect "gate-b: Step 4 evaluates triggers only on a reopening pass" \
  "$(grep -c 'Three triggers reach this surface.*only on a pass that reopened something' "$GATESREF" | tr -d ' ')" "1"
expect "gate-b: Step 3 carries the same precedence" \
  "$(grep -c 'not necessarily consecutive.*zero-reopening pass takes Step 2' "$GATESREF" | tr -d ' ')" "1"
# Step 4 has TWO arrivals. Naming only the post-pass one would leave an at-cap scope
# with a live finding reading as having no surface at all -- it arrives pre-spawn,
# where no pass ran and there is no count to read, and it must still surface.
# These three are checked against Step 4's EXTRACTED BODY rather than by a same-line
# grep. GATE-A ROUND-2 FINDING: anchoring to `Step 4 has two arrivals` looked
# site-scoped but was not -- that phrase is part of the very sentence being checked,
# so the pattern was still whole-file, and a probe that RELOCATED the paragraph into
# Step 1 left every assertion green. An anchor is only real when it is a PRE-EXISTING
# line at the site (as the sibling pins below use) or when the section is extracted.
gb_step4() { awk '/^### Step 4 /{f=1;next} /^##+ /{f=0} f' "$GATESREF"; }
# CODE-REVIEW ROUND 2: these pinned the arrival NAMES, both of which sit inside the
# sentence stating the rule — so inverting "That arrival **always surfaces**" to "takes
# the clean exit too" kept them green. Pin each arrival's RULE, not its label.
expect "gate-b: Step 4 names the pre-spawn arrival" \
  "$(gb_step4 | grep -c 'pre-spawn arrival.*always surfaces' | tr -d ' ')"                           "1"
expect "gate-b: Step 4 names the post-pass arrival" \
  "$(gb_step4 | grep -c 'post-pass arrival.*only arrival the reopening precondition governs' | tr -d ' ')" "1"
# FAIL CLOSED, against the local convention. Both sites, because a reader who takes
# "an absent X counts as 0" from the neighbouring prose disarms all three triggers
# on every legacy row.
# CODE-REVIEW ROUND 2: `absent .reopened.*counts as reopening` also matches a statement
# of the OPPOSITE rule — the `.*` bridges "counts as zero and never" into "counts as
# reopening" — so the guard for the one drift this spec explicitly warns about could not
# see that drift happen. Pin the full clause, direction included.
expect "gate-b: absent reopened counts as reopening (gates ref)" \
  "$(gb_step4 | grep -c 'absent .reopened.*counts as reopening, never as zero' | tr -d ' ')"         "1"
expect "gate-b: absent reopened counts as reopening (state schema)" \
  "$(grep -c '\*\*`self_inflicted`\*\*.*absent .reopened.*counts as reopening, never as zero' "$SCHEMAREF" | tr -d ' ')" "1"
expect "gate-b: state-schema self_inflicted doc carries the precedence" \
  "$(grep -c '\*\*`self_inflicted`\*\*.*a zero-reopening pass has already passed the gate' "$SCHEMAREF" | tr -d ' ')" "1"
# ARCHITECTURE's two sites counted SEPARATELY -- that table is the one-screen summary
# a reader consults INSTEAD of the reference, so a stale copy there is how a retired
# claim survives.
expect "gate-b: ARCHITECTURE mermaid edge carries the precedence" \
  "$(grep -c '^ *GateBCls .*reopening pass takes the clean exit' "$LBARCH" | tr -d ' ')"             "1"
expect "gate-b: ARCHITECTURE Gate B row carries the precedence" \
  "$(grep -c '^| Gate B |.*reopening pass takes the clean exit.*pre-spawn at-cap arrival' "$LBARCH" | tr -d ' ')" "1"
expect "gate-b: README states it in user-facing prose" \
  "$(grep -cE '^(- \*\*Gate B\*\*|\| \*\*Gate B\*\* \|).*a pass that finds nothing to reopen just passes.*before a pass even runs still surfaces' "$LBRDME" | tr -d ' ')" "1"
# MUST NOT CHANGE. The precedence narrows one thing only; these four are the clauses
# most likely to be collateral, and the yield row's VALUE is read by
# prevent-mid-protocol-stall.sh.
expect "gate-b: Step 0's pre-spawn cap check is untouched" \
  "$(grep -c 'If this scope is already at its cap, do NOT spawn the agent' "$GATESREF" | tr -d ' ')" "1"
expect "gate-b: park_non_blocking's carve-out is untouched" \
  "$(grep -c 'by parking every finding that is neither literally' "$GATESREF" | tr -d ' ')"          "1"
# CODE-REVIEW FINDING (Minor): this was labelled `gate-b:` and commented as "the rule and
# its restatement in the rationale para" — both wrong. The two occurrences are in DIFFERENT
# contracts: Gate B's Step 3, and the Phase-4 loop's Step C. A reword of Phase 4's sentence
# would redden an assertion named for Gate B and send the fixer to the wrong line. Scope
# each to its own section instead, so the two cannot mask or blame each other.
gb_step3() { awk '/^### Step 3 /{f=1;next} /^##+ /{f=0} f' "$GATESREF"; }
p4_stepc() { awk '/^### Step C /{f=1;next} /^##+ /{f=0} f' "$GATESREF"; }
expect "gate-b: Step 3's convergence test is untouched" \
  "$(gb_step3 | grep -c 'If it did not DECREASE, the loop has converged' | tr -d ' ')"              "1"
expect "phase-4: Step C's convergence test is untouched" \
  "$(p4_stepc | grep -c 'If it did not DECREASE, the loop has converged' | tr -d ' ')"              "1"
expect "gate-b: the yield row still resolves to user-approval" \
  "$(grep -c '^| Gate B .*`\"user-approval\"` |' "$SPINE_ONLY" | tr -d ' ')"                         "1"
expect "spine: tier table carries the per-tier pass cap" \
  "$(spine_has "$SPINE_ONLY" 'run, max 2 passes')"                                                  "yes"
expect "spine: HEAVY tier pass cap"                "$(spine_has "$SPINE_ONLY" 'run, max 3 passes, cross-check')" "yes"
# Clause 5 must be the single-non-decrease test. The OLD two-consecutive wording
# must be GONE from the whole spec, or both rules ship and the weaker one wins.
expect "spine: clause 5 is the non-decrease test" \
  "$(spine_has "$SPINE_ONLY" 'fails to DECREASE versus the previous round, the loop has CONVERGED')" "yes"
expect "spine: old two-consecutive-clean test is gone" \
  "$(spec_count 'two consecutive review rounds producing zero blockers')"                            "0"
# The state schema must carry the new fields, or the rules above have nowhere to record.
expect "spine: gate_b schema has passes[]"          "$(spine_has "$SPINE_ONLY" '"passes": []')"      "yes"
# allowance_acked is an OBJECT keyed by scope, never a scalar: a bare integer would
# be added to whichever scope was evaluated, so one grant at the main-loop surface
# would raise all four re-gate allowances too (Gate A round 2).
expect "spine: gate_b schema has verified_diff_sha" "$(spine_has "$SPINE_ONLY" '"verified_diff_sha": null, "allowance_acked": {}')" "yes"
expect "spine: allowance_acked is not a bare scalar" "$(grep -c '"allowance_acked": [0-9]' "$SPINE_ONLY" | tr -d ' ')" "0"
expect "spine: loop_budget schema has park_non_blocking" \
  "$(spine_has "$SPINE_ONLY" '"park_non_blocking": false')"                                          "yes"

# (7) THE FOUR RE-GATE ALLOWANCES. Each site must carry its own, or an at-cap main
# loop can never re-earn gates.gate_b.passed and the handover commit deadlocks.
expect "gate-b: re-gate allowance stated at all four sites" \
  "$(spec_count 'own Gate B allowance for this run')"                                                "4"
expect "gate-b: docs re-gate scope named"     "$(spine_has "$HOOKS/../skills/auto-task/references/phase-5-handover.md" 'scope: "regate:docs"')"      "yes"
expect "gate-b: merge re-gate scope named"    "$(spine_has "$HOOKS/../skills/auto-task/references/phase-5-handover.md" 'scope: "regate:merge"')"     "yes"
expect "gate-b: bot-fix re-gate scope named"  "$(spine_has "$HOOKS/../skills/auto-task/references/phase-6-8-post-pr.md" 'scope: "regate:bot-fix"')"  "yes"
expect "gate-b: release re-gate scope named"  "$(spine_has "$HOOKS/../skills/auto-task/references/phase-9-release.md" 'scope: "regate:release"')"    "yes"
# The helpers themselves must exist and be sourceable, since every rule above
# defers its numbers to them.
expect "gate-b: lb_gate_b_cap is defined"        "$(bash -c '. "'"$HOOKS"'/lib/loop-budget.sh"; type lb_gate_b_cap >/dev/null 2>&1 && echo yes || echo no')"        "yes"
expect "gate-b: lb_gate_b_regate_cap is defined" "$(bash -c '. "'"$HOOKS"'/lib/loop-budget.sh"; type lb_gate_b_regate_cap >/dev/null 2>&1 && echo yes || echo no')" "yes"
expect "gate-b: the dedicated suite passes" \
  "$(bash "$HOOKS/../tests/gate-b-loop.test.sh" >/dev/null 2>&1 && echo yes || echo no)"             "yes"
# GATE-A ROUND-5 FINDING: ARCHITECTURE.md's "Phases at a glance" row still stated the
# pre-change Gate B exit condition and routing, contradicting the flowchart 67 lines
# above it in the SAME file — and the spine now points into that file for Gate B
# rationale, so a model following the pointer met both readings. ARCHITECTURE.md is
# outside spec-inventory's file set, so nothing else guards it. Pin both cells.
ARCHREF="$HOOKS/../skills/auto-task/ARCHITECTURE.md"
expect "arch: glance-table Gate B exit is the AC-impact test" \
  "$(spine_has "$ARCHREF" 'no finding meets the Step-2 AC-impact test')"                             "yes"
expect "arch: glance-table Gate B names the surface route" \
  "$(spine_has "$ARCHREF" 'or on a fired convergence test it **surfaces** instead')"                  "yes"
expect "arch: glance-table no longer states the retired exit condition" \
  "$(grep -c '| \*\*no\*\* | "No adversarial findings" or only follow-ups |' "$ARCHREF" | tr -d ' ')" "0"
# Convergence advances ONLY with zero reopening findings left; with any still open it
# routes to the surface node. Pin both edges so the disjointness cannot silently blur.
expect "arch: flowchart routes convergence to the surface" \
  "$(spine_has "$ARCHREF" 'or CONVERGED (count stopped falling)')"                                    "yes"
expect "arch: flowchart has no convergence->pass edge" \
  "$(grep -c 'CONVERGED.*park + advance' "$ARCHREF" | tr -d ' ')"                                     "0"

# GATE-A ROUND-2 FINDING (this change), and the SAME CLASS as the round-5 finding above —
# which is exactly why it is worth pinning rather than trusting. ARCHITECTURE.md's Phase-4
# flowchart and glance row still documented the RETIRED ungraded loop ("parse Blockers /
# Required / Follow-ups", "only follow-ups --> pass", "blocker / required --> fix"). A
# model following the authoritative diagram would therefore never grade a finding, never
# append a rounds[] row and never apply the batch — i.e. the whole contract inert by a
# second route, after the first inert reading was already fixed once this run. Pin the
# graded flow AND assert each retired edge is gone; ARCHITECTURE.md sits outside
# spec-inventory's file set, so nothing else guards it.
expect "arch: Phase-4 flowchart grades by reachability" \
  "$(spine_has "$ARCHREF" 'grade each finding: a AC breach / b runtime-reachable / c security')"       "yes"
expect "arch: Phase-4 flowchart records the rounds[] row" \
  "$(spine_has "$ARCHREF" 'append gates.code_review.rounds[] row')"                                   "yes"
expect "arch: Phase-4 flowchart has the deferral edge" \
  "$(spine_has "$ARCHREF" 'defer to gates.code_review.deferred[]<br/>costs NO round')"                "yes"
expect "arch: Phase-4 flowchart has the batch edge, spent once" \
  "$(spine_has "$ARCHREF" 'spent once per run')"                                                      "yes"
expect "arch: Phase-4 flowchart routes convergence to the surface" \
  "$(spine_has "$ARCHREF" 'convergence test fired<br/>surface: user-approval')"                       "yes"
expect "arch: Phase-4 label-driven pass edge is GONE" \
  "$(grep -c 'P4Cls -- only follow-ups -->' "$ARCHREF" | tr -d ' ')"                                   "0"
expect "arch: Phase-4 label-driven fix edge is GONE" \
  "$(grep -c 'P4Cls -- blocker / required -->' "$ARCHREF" | tr -d ' ')"                                "0"
expect "arch: Phase-4 label-driven parse note is GONE" \
  "$(grep -c 'parse Blockers / Required / Follow-ups' "$ARCHREF" | tr -d ' ')"                         "0"
expect "arch: glance-table Phase-4 exit is the graded test" \
  "$(spine_has "$ARCHREF" 'zero **reopening** findings (the Step-A grade, not the label)')"            "yes"
expect "arch: glance-table Phase-4 no longer states the retired exit" \
  "$(grep -c '| only follow-ups, no Blockers/Required |' "$ARCHREF" | tr -d ' ')"                      "0"
# ...and the retired-edge controls must be able to FAIL, or they certify nothing.
expect "  ...and the retired-edge control trips when restored" \
  "$(printf '    P4Cls -- only follow-ups --> P4OK[x]\n' | grep -c 'P4Cls -- only follow-ups -->' | tr -d ' ')" "1"

# restore a sane state file for anything appended after this block
printf '%s' '{"approved":true,"phase":"review","expected_next_action":"auto-continue"}' > "$ST"

echo
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
