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
stop(){ local o; o="$(CLAUDE_PROJECT_DIR="$T" bash "$STOP" 2>/dev/null)"; [ -z "$o" ] && { echo allow; return; }; printf '%s' "$o" | jq -r '.decision // "allow"' 2>/dev/null; }
sha(){ git diff "$BASE" | git hash-object --stdin; }
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
B2="$(git rev-parse HEAD)"; RSHA2="$(git diff "$B2" | git hash-object --stdin)"
gateL(){ printf '%s' "$COMMIT" | CLAUDE_PROJECT_DIR="$T" bash "$GATE" >/dev/null 2>&1; echo $?; }
cat > "$ST2" <<EOF
{"approved":true,"phase":"review","expected_next_action":"auto-continue","base":"$B2","effort":{"tier":"light"},
 "gates":{"code_review":{"passed":true,"tool":"skill:auto-task-code-review","clean_pass_after_last_fix":true,"reviewed_diff_sha":"$RSHA2"},
          "gate_b":{"passed":false,"skipped_reason":"tier=light"}}}
EOF
expect "LIGHT: commit ALLOWED (Gate B skipped)"           "$(gateL)" "0"
tmp="$(jq '.gates.code_review.tool="agent:code-reviewer"' "$ST2")"; printf '%s' "$tmp" > "$ST2"
expect "LIGHT: wrong review tool BLOCKED"                 "$(gateL)" "2"

echo "================ Fail-open / fail-closed edges ================"
git checkout -q feat/widget
echo '{bad json' > "$ST"
expect "Malformed STATE.json: stop ALLOWS (no soft-lock)" "$(stop)" "allow"
printf '%s' "$COMMIT" | CLAUDE_PROJECT_DIR="$T" bash "$GATE" >/dev/null 2>&1; expect "Malformed STATE.json: commit BLOCKED (fail closed)" "$?" "2"

echo
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
