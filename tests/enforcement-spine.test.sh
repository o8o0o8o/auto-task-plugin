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
stop(){ local o; o="$(CLAUDE_PROJECT_DIR="$T" bash "$STOP" 2>/dev/null)"; [ -z "$o" ] && { echo allow; return; }; printf '%s' "$o" | jq -r '.decision // "allow"' 2>/dev/null; }
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
stopS(){ local o; o="$(CLAUDE_PROJECT_DIR="$T" AUTO_TASK_STALL_LIMIT=3 bash "$STOP" 2>/dev/null)"; [ -z "$o" ] && { echo allow; return; }; printf '%s' "$o" | jq -r '.decision // "allow"' 2>/dev/null; }
expect "Stall: block #1 (count<limit)"                    "$(stopS)" "block"
expect "Stall: block #2 (count<limit)"                    "$(stopS)" "block"
expect "Stall: release #3 (count>=limit)"                 "$(stopS)" "allow"
setstate '.iteration.fix=1'   # state advanced → fresh block sequence
expect "Stall: blocking resumes after a release"         "$(stopS)" "block"

echo "================ AI-attribution block ================"
expect "Attr: Co-Authored-By Claude BLOCKED"              "$(attr '{"tool_input":{"command":"git commit -m \"x\n\nCo-Authored-By: Claude <x@y>\""}}')" "2"
expect "Attr: clean commit ALLOWED"                       "$(attr '{"tool_input":{"command":"git commit -m clean"}}')" "0"

echo "================ Fail-open / fail-closed edges ================"
git checkout -q feat/widget
echo '{bad json' > "$ST"
expect "Malformed STATE.json: stop ALLOWS (no soft-lock)" "$(stop)" "allow"
printf '%s' "$COMMIT" | CLAUDE_PROJECT_DIR="$T" bash "$GATE" >/dev/null 2>&1; expect "Malformed STATE.json: commit BLOCKED (fail closed)" "$?" "2"

echo
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
