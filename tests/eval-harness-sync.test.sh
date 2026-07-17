#!/usr/bin/env bash
# Drift guard for the verifier eval harness.
#
# eval/verifier-eval.js embeds a COPY of the task-execution-verifier completeness
# prompt (the workflow sandbox can't read the agent file at runtime). This test is
# a pure, hermetic grep — no model, no network — asserting the de-anchoring
# "blind step" marker phrase appears in BOTH the shipped agent and the eval copy,
# so changing one without the other fails here and reminds the editor to sync.
#
# Usage: tests/eval-harness-sync.test.sh   Exit 0 = in sync.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT="$ROOT/agents/task-execution-verifier.md"
EVAL="$ROOT/eval/verifier-eval.js"

PASS=0; FAIL=0
check(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-50s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-50s got=%s want=%s\n' "$1" "$2" "$3"; fi; }

# Distinctive marker for the v0.20.0 blind de-anchoring step. Present verbatim in
# the agent file's completeness Procedure and mirrored into the eval prompt.
MARKER='correct-answer expectation (BLIND'

echo "================ eval-harness sync ================"
check "agent file present"            "$([ -f "$AGENT" ] && echo yes || echo no)" "yes"
check "eval script present"           "$([ -f "$EVAL" ]  && echo yes || echo no)" "yes"
check "agent has blind-step marker"   "$(grep -qF "$MARKER" "$AGENT" && echo yes || echo no)" "yes"
check "eval mirrors blind-step marker" "$(grep -qF "$MARKER" "$EVAL" && echo yes || echo no)" "yes"

echo ""
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
