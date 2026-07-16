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
# the model should keep going (a valid STATE.json that says so). When the state
# cannot be read (jq absent, or STATE.json unparseable), this hook ALLOWS the
# stop and warns — it fails OPEN. This is the OPPOSITE of the PreToolUse gate
# hook, which fails closed: blocking one commit cannot loop, but blocking every
# turn-end can. Commits stay gate-blocked regardless, so allowing a stop here is
# recoverable (just resume) and cannot cause harm, whereas a wrongful block is
# not recoverable without user intervention.
# `set -e` is intentionally omitted so a stray jq error can't crash the script.
#
# Soft-lock breaker: a *valid* STATE.json stuck at expected_next_action other
# than a user-gate is exactly the state that would block every turn-end forever
# if the model genuinely cannot make progress. To bound that, the block path
# keeps a consecutive-block counter keyed on a signature of the run's progress
# fields (phase, expected_next_action, iteration counters, reviewed diff sha).
# While the run advances, the signature changes and the counter resets, so
# normal operation blocks indefinitely as designed. If the run is frozen in the
# EXACT same state for AUTO_TASK_STALL_LIMIT (default 25) consecutive turn-ends,
# the hook releases with a loud warning so the user can intervene rather than
# face an unrecoverable session. This is the portable substitute for a
# `stop_hook_active` signal, which Claude Code does not reliably surface here.

set -uo pipefail

# Resolve the project root that owns .auto-task/<branch>/. Start from
# CLAUDE_PROJECT_DIR (the session's project root) or $PWD, then resolve that to
# its git worktree root, so a turn-end from a subdirectory still finds
# .auto-task/<branch>/ at the top. Keep an explicitly-set CLAUDE_PROJECT_DIR
# authoritative for the common case — then retarget to a linked worktree of the
# same repo when the session actually runs in one (see enforce-gates.sh for the
# full rationale). Without the retarget, a worktree-isolated run resolves to the
# main checkout's branch (which has no active run), the state file is not found,
# and this hook fails OPEN — silently disabling the anti-stall guarantee for the
# entire run, exactly the workflow the plugin makes the default.
project_dir_base="${CLAUDE_PROJECT_DIR:-$PWD}"
project_dir="$(cd "$project_dir_base" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$project_dir" ] || project_dir="$project_dir_base"

# The turn-end's real cwd: prefer the payload's .cwd (authoritative session cwd),
# fall back to $PWD. Guarded stdin read so an interactive invocation never blocks
# on cat; the harness always pipes JSON here, so it reads promptly and closes.
_input=""
[ -t 0 ] || _input="$(cat 2>/dev/null || true)"
op_cwd=""
if [ -n "$_input" ] && command -v jq >/dev/null 2>&1; then
  op_cwd="$(printf '%s' "$_input" | jq -r '.cwd // ""' 2>/dev/null || true)"
fi
[ -n "$op_cwd" ] || op_cwd="$PWD"
# Retarget only for a same-repo linked worktree (shared git common-dir, different
# toplevel; common-dirs normalised via cd-into + `pwd -P`). Nested/embedded repos
# have their own common-dir and are left alone.
if [ -d "$op_cwd" ]; then
  cwd_top="$(cd "$op_cwd" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$cwd_top" ] && [ "$cwd_top" != "$project_dir" ]; then
    cwd_common="$(cd "$op_cwd" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)" 2>/dev/null && pwd -P || true)"
    base_common="$(cd "$project_dir" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)" 2>/dev/null && pwd -P || true)"
    if [ -n "$cwd_common" ] && [ "$cwd_common" = "$base_common" ]; then
      project_dir="$cwd_top"
    fi
  fi
fi
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

# Soft-lock breaker. Track consecutive blocks in the SAME run state; if the run
# is frozen (no progress) for AUTO_TASK_STALL_LIMIT turn-ends in a row, release
# the stop instead of blocking, so the session can't become unrecoverable.
count_file="$project_dir/.auto-task/$branch/.stall-block-count"
# `.base` leads the signature so the counter is run-scoped: a fresh run on a
# reused branch folder forks from a new base, changing the signature and
# resetting any residual count from a prior run (the file is only removed on a
# release, not on legitimate yield/done exits). Within a run (incl. resume) base
# is stable, so the counter accumulates as intended.
#
# `.preview.polls` (Phase 7 preview), `.bot_review.polls` (Phase 6 bot-comment
# review), and `.external.polls` (Phase 8 `auto`-run settle-poll — waiting for an
# async external apply to propagate before verifying; NOT the awaiting-external
# human handoff, which yields on user-approval and does not poll)
# are included so their long-lived `auto-continue` poll waits — where
# phase/expected_next_action/iterations all stay
# constant across many turn-ends while waiting for a deploy, for bot comments, or
# for an async external apply to settle —
# are not misread as a frozen run. Each poll cycle bumps the respective counter,
# which changes the signature and resets the block counter; a poll that STOPS
# bumping (a genuinely frozen model) keeps a constant signature and is still
# caught by the backstop. Backward-compatible: absent on every non-poll run
# (`// 0` → "0", constant), so it is inert for existing runs and does not alter
# their stall behavior.
sig="$(jq -r '[(.base // ""), (.phase // ""), (.expected_next_action // ""), ((.iteration.review // 0)|tostring), ((.iteration.fix // 0)|tostring), (.gates.code_review.reviewed_diff_sha // ""), ((.preview.polls // 0)|tostring), ((.bot_review.polls // 0)|tostring), ((.external.polls // 0)|tostring)] | join("|")' "$state" 2>/dev/null || echo "")"
prev_count=0; prev_sig=""
if [ -f "$count_file" ]; then
  prev_line="$(cat "$count_file" 2>/dev/null || echo "")"
  prev_count="${prev_line%%$'\n'*}"; prev_count="${prev_count%%|*}"
  prev_sig="${prev_line#*|}"
  case "$prev_count" in ''|*[!0-9]*) prev_count=0 ;; esac
fi
if [ "$sig" = "$prev_sig" ]; then count=$((prev_count + 1)); else count=1; fi
printf '%s|%s\n' "$count" "$sig" > "$count_file" 2>/dev/null || true

stall_limit="${AUTO_TASK_STALL_LIMIT:-25}"
case "$stall_limit" in ''|*[!0-9]*) stall_limit=25 ;; esac
if [ "$count" -ge "$stall_limit" ]; then
  echo "auto-task anti-stall: $count consecutive turn-ends blocked in the same state (phase=$phase, expected_next_action=$expected) — the run appears genuinely frozen with no progress. Releasing this stop to avoid an unrecoverable soft-lock. Inspect/repair .auto-task/$branch/STATE.json and resume with /auto-task." >&2
  rm -f "$count_file" 2>/dev/null || true
  exit 0
fi

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
