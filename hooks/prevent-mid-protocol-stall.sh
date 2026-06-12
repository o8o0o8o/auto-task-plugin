#!/usr/bin/env bash
# Prevents the model from yielding mid-pipeline during an auto-task run.
#
# Registered as a Stop hook. Once the run is approved and not done, the ONLY
# values that allow a stop are the two explicit user-gates; everything else
# (including a missing/null field) blocks. Reads the per-branch STATE.json's
# `expected_next_action`:
#   - "user-approval"     → allow (Phase 1 plan gate, Loop-rule surface)
#   - "user-push-prompt"  → allow (the one Phase 5 push/PR ask)
#   - "auto-continue"     → block the stop, re-prompt the model to continue
#   - null / unset / other → block. A null/unset value is only legitimate while
#     approved=false or after phase=done, and BOTH are handled by the guards
#     below before this field is consulted — so a null reached here means the
#     field was not set, and the safe default is to keep the turn alive.
#
# Failure policy: this hook only BLOCKS when it has positive, readable evidence
# the model should keep going (a valid STATE.json that says so). Claude Code has
# NO built-in Stop-hook loop protection and provides no `stop_hook_active`
# signal, so an unconditional block would soft-lock the session — and a
# jq-missing block in particular cannot be cleared mid-session. Therefore, when
# the state cannot be read (jq absent, or STATE.json unparseable), this hook
# ALLOWS the stop and warns — it fails OPEN. This is the OPPOSITE of the
# PreToolUse gate hook, which fails closed: blocking one commit cannot loop,
# but blocking every turn-end can. Commits stay gate-blocked regardless, so
# allowing a stop here is recoverable (just resume) and cannot cause harm,
# whereas a wrongful block is not recoverable without user intervention.
# `set -e` is intentionally omitted so a stray jq error can't crash the script.

set -uo pipefail

project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
branch="$(cd "$project_dir" && git branch --show-current 2>/dev/null || true)"
if [ -z "$branch" ]; then
  exit 0  # not in a repo / detached HEAD → no auto-task state to consult
fi

state="$project_dir/.auto-task/$branch/STATE.json"
[ -f "$state" ] || exit 0

# A state file exists for this branch. If we cannot read it, fail OPEN (allow
# the stop) with a warning — blocking here would risk an unrecoverable loop
# (see the failure-policy note above). Commits remain gate-blocked regardless.
if ! command -v jq >/dev/null 2>&1; then
  echo "auto-task anti-stall: jq is not installed, so STATE.json cannot be read — mid-pipeline stop-blocking is DISABLED for branch '$branch'. Commits remain gate-blocked. Install jq (a hard prerequisite) to restore the anti-stall guarantee." >&2
  exit 0
fi
if ! jq empty "$state" 2>/dev/null; then
  echo "auto-task anti-stall: .auto-task/$branch/STATE.json is not valid JSON, so the yield point cannot be determined — allowing this stop. Repair STATE.json (it must parse and carry phase/approved/expected_next_action) to restore the anti-stall guarantee, or remove .auto-task/$branch/ if no run is active." >&2
  exit 0
fi

approved="$(jq -r '.approved // false' "$state" 2>/dev/null || echo false)"
[ "$approved" = "true" ] || exit 0

phase="$(jq -r '.phase // ""' "$state" 2>/dev/null || echo "")"
if [ "$phase" = "done" ]; then
  exit 0
fi

expected="$(jq -r '.expected_next_action // ""' "$state" 2>/dev/null || echo "")"
case "$expected" in
  user-approval|user-push-prompt)
    exit 0  # the only legitimate mid-run yield points
    ;;
esac

# We are past the approved + done guards, so the run is mid-pipeline. ANY value
# other than the two explicit user-gates blocks — including an unset/null field.
# Per the skill ("writing state without an explicit choice keeps the turn alive
# is the correct failure mode"), a missing expected_next_action must fail closed,
# not open. Make the unset case explicit in the reason so the model knows to set
# the field rather than hunt for a phantom gate.
[ -n "$expected" ] || expected="(unset/null — must be set on every post-approval state write)"

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
