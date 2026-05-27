#!/usr/bin/env bash
# Prevents the model from yielding mid-pipeline during an auto-task run.
#
# Registered as a Stop hook. Reads the per-branch STATE.json's
# `expected_next_action` field:
#   - "auto-continue"     → block the stop, re-prompt the model to continue
#   - "user-approval"     → allow (Phase 1 plan gate, Loop-rule surface)
#   - "user-push-prompt"  → allow (the one Phase 5 push/PR ask)
#   - null / unset        → allow (pre-approval or terminal state)
#
# Returns JSON on stdout per the Claude Code Stop-hook contract.
# Verify the exact field name against the current spec before shipping.

set -euo pipefail

project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
branch="$(cd "$project_dir" && git branch --show-current 2>/dev/null || true)"
if [ -z "$branch" ]; then
  exit 0  # not in a repo / detached HEAD → no auto-task state to consult
fi

state="$project_dir/.auto-task/$branch/STATE.json"
[ -f "$state" ] || exit 0

approved="$(jq -r '.approved // false' "$state")"
[ "$approved" = "true" ] || exit 0

phase="$(jq -r '.phase // ""' "$state")"
if [ "$phase" = "done" ]; then
  exit 0
fi

expected="$(jq -r '.expected_next_action // ""' "$state")"
case "$expected" in
  user-approval|user-push-prompt|"")
    exit 0  # legitimate yield point
    ;;
esac

# Mid-protocol stall. Block.
jq -n --arg p "$phase" --arg e "$expected" '{
  decision: "block",
  reason: ("auto-task is mid-pipeline (phase=\($p), expected_next_action=\($e)). " +
           "Per the NON-YIELDING CONTRACT in the auto-task skill, sub-skill and verifier reports are INPUT to the next step, not an end-of-turn. " +
           "Parse the most recent report and make the next tool call now (apply a fix, advance the phase, set a gate, or spawn the next verifier). " +
           "Do NOT compose a closing message. The only legitimate stops are Phase 1 plan approval, Phase 5 push prompt, or a Loop-rule surface — none of which apply here. " +
           "If you believe this block is wrong, the bug is in the skill, not the hook: STATE.json should have been updated to expected_next_action=\"user-approval\" before yielding.")
}'
exit 0
