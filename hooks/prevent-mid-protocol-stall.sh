#!/usr/bin/env bash
# Prevents the model from yielding mid-pipeline during an auto-task run.
#
# Registered as a Stop hook. Once the run is approved and not done, the two explicit
# user-gates allow a stop and everything else (including a missing/null field) blocks
# — subject to the two bounded release valves documented below (the soft-lock breaker
# and the fix-loop budget release), which are the only ways any other value yields.
# Reads the per-branch STATE.json's `expected_next_action`:
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

# Shared, PURE fix-loop budget resolver — the SAME file enforce-gates.sh sources,
# so the cap table has one executable home and the two hooks cannot drift.
# Sourced permissively: this hook is fail-OPEN by contract, so a missing helper must
# never break stop-handling. The budget release below simply does not fire if the
# functions are absent, which leaves today's behavior exactly as it was.
STALL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# shellcheck source=/dev/null
. "$STALL_SCRIPT_DIR/lib/loop-budget.sh" 2>/dev/null || true

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
#
# `.gates.loop_budget.acked_through` is in the signature for a narrower reason: a
# turn whose ONLY action is recording the user's over-budget ack would otherwise
# leave every signature field constant, so that turn would be counted as another
# frozen turn-end rather than as the progress it is. Same `// 0` backward-compat
# shape as the poll counters — absent on every run that never went over budget.
# `.gates.code_review.rounds | length` is in the signature for the SAME narrow reason
# as the poll counters and the budget ack above, and it is not optional. Since the
# Phase-4 graded round contract (references/phase-3-gates.md, "phase-4-round-mechanics"),
# a round whose findings are all DEFERRED applies no fix, bumps no counter and leaves
# `reviewed_diff_sha` untouched — so every other field here stays constant and the round
# would be miscounted as another frozen turn-end, exactly the false positive the ack
# field was added to prevent. Only the LENGTH is read; the contents are never inspected
# and no magnitude judgment is made. Absent on every run that predates the record, where
# it reads 0 and the signature behaves as before.
#
# TYPE-GUARDED, and that is not defensive habit — it is the one field here that can ABORT
# the whole expression. `// []` only replaces null/false, so a truthy non-array (`rounds:
# true`) reaches `length`, which errors on a boolean ("boolean (true) has no length",
# rc=5). The `|| echo ""` below then blanks the ENTIRE signature, and two consecutive
# blanks compare EQUAL, so the frozen-turn counter increments and this hook blocks a
# turn-end it should have released. Every sibling field is error-proof (`// ""` plus
# `tostring` cannot fail, booleans included), so the guard belongs here and only here.
sig="$(jq -r '[(.base // ""), (.phase // ""), (.expected_next_action // ""), ((.iteration.review // 0)|tostring), ((.iteration.fix // 0)|tostring), (.gates.code_review.reviewed_diff_sha // ""), ((.preview.polls // 0)|tostring), ((.bot_review.polls // 0)|tostring), ((.external.polls // 0)|tostring), ((.gates.loop_budget.acked_through // 0)|tostring), ((.gates.code_review.rounds | if type == "array" then length else 0 end)|tostring)] | join("|")' "$state" 2>/dev/null || echo "")"
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

# ---- Fix-loop budget release ----------------------------------------------
# Placed AFTER the soft-lock counter above, deliberately: the counter must keep
# accumulating while a run sits over budget, because "over budget" and "genuinely
# frozen" are different conditions and the frozen backstop must still work. This
# release also does NOT delete the counter file — an earlier draft did, which would
# have stopped AUTO_TASK_STALL_LIMIT ever accumulating during exactly the window a
# freeze is most likely.
#
# WHY A RELEASE AT ALL. Not because surfacing would otherwise be impossible — a model
# that follows the ack ritual sets expected_next_action=user-approval first, and the
# early-exit above already allows that yield. The release plus its warning (emitted on
# BOTH channels — see the surfacing note at the echo below) are for the run that goes
# wrong the other way: one that keeps churning WITHOUT updating
# the field, where the anti-stall contract would force it onward with nothing telling
# it the budget is blown. This is the mirror of the soft-lock breaker: that one
# releases when the run has made too LITTLE progress, this one when it has spent too
# MUCH budget.
#
# FIRED ONCE PER ITERATION COUNT, not every turn. A naive "release while over
# budget" would leave the non-yielding contract off for the whole over-budget
# window, which would be a large hole in the anti-stall guarantee. The marker file
# records the loop count we last released at; a second turn-end at the same count
# falls through and blocks normally, so the model gets exactly one opportunity to
# surface per new loop iteration.
#
# THE LOOP COUNT IS max(iteration.fix, iteration.review) — the identical measure
# enforce-gates.sh blocks on, and it has to be, or the two halves of this feature
# disagree: a review-heavy run (fix=0, review=28) would have its commit blocked by
# the gate while this hook never releases the turn-end it needs to surface the
# check-in. Both counters bound the same thing (review volume); see the note in
# enforce-gates.sh.
#
# HONEST LIMITATION: a Stop hook can only PERMIT a stop, never require one, and the
# stop it permits is any stop — not provably the budget check-in. What makes the
# budget non-advisory is the pair: this release makes surfacing possible, and
# enforce-gates.sh refuses the commit until the user's ack is recorded. Neither half
# is sufficient alone, and this one does not pretend to be.
if command -v lb_cap_for_tier >/dev/null 2>&1 && command -v lb_effective_budget >/dev/null 2>&1; then
  lb_tier="$(jq -r '.effort.tier // ""' "$state" 2>/dev/null || echo "")"
  lb_has_tier="$(jq -r 'if (.effort? // null) == null then "no" else (if (.effort.tier? // null) == null then "no" else "yes" end) end' "$state" 2>/dev/null || echo "no")"
  # BOTH counters default to 0, matching enforce-gates.sh's `// 0` reads EXACTLY.
  # An earlier draft defaulted lb_fix to "" so that an absent counter would fail
  # lb_is_number and skip the branch — but that made the two hooks disagree on the
  # very state the gate was widened to support: `iteration:{review:28}` with no
  # `fix` key blocked the commit while this hook stayed silent, i.e. the run was
  # refused a landing with no released turn-end and no in-band warning. `// 0` is
  # safe for a legacy run precisely because 0 is never > budget, so absence still
  # produces silence — it just produces it by arithmetic rather than by bailing out.
  lb_fix="$(jq -r '.iteration.fix // 0' "$state" 2>/dev/null || echo 0)"
  lb_review="$(jq -r '.iteration.review // 0' "$state" 2>/dev/null || echo 0)"
  lb_acked="$(jq -r '.gates.loop_budget.acked_through // 0' "$state" 2>/dev/null || echo 0)"
  # Only act when the run carries a tier and every counter is sane. The tier test is
  # `has_effort`-shaped rather than `-n`: the gate hook treats only a MISSING
  # tier as legacy (an empty-string tier falls through to its `// "standard"`
  # default and blocks at cap 4), so keying on emptiness here would reopen the same
  # disagreement in a second place. Anything unsane: stay silent and let the normal
  # block/allow logic below decide — fail-open, per this hook's contract.
  if [ "$lb_has_tier" = "yes" ] && lb_is_number "$lb_fix" && lb_is_number "$lb_review" && lb_is_number "$lb_acked"; then
    lb_cap="$(lb_cap_for_tier "$lb_tier")"
    lb_budget="$(lb_effective_budget "$lb_cap" "$lb_acked")"
    lb_count="$lb_fix"
    [ "$lb_review" -gt "$lb_count" ] && lb_count="$lb_review"
    if [ "$lb_count" -gt "$lb_budget" ]; then
      lb_marker="$project_dir/.auto-task/$branch/.loop-budget-released"
      # RUN-SCOPED, keyed by `base`, exactly like record-outcome.sh's .outcome-recorded
      # sentinel and like this hook's own .base-led stall signature above. Without the
      # base, residue from a PRIOR run in a reused .auto-task/<branch>/ folder swallows
      # the new run's release at the same iteration count — and swallows the stderr
      # warning with it, which is the only in-band notification the model gets. Keying
      # by base also removes the need to clean the file up at phase=done in the common
      # case: a run forked from an advanced default branch has a new base, so the old
      # key cannot match. It is not a total guarantee — two runs forked from an
      # UNMOVED default share a base, so residue at the same loop count can still
      # swallow one release (and its warning). Bounded: the commit gate still blocks,
      # and the run surfaces the ordinary way. Tracked as FU-LB9.
      lb_base="$(jq -r '.base // ""' "$state" 2>/dev/null || echo "")"
      lb_key="$lb_base|$lb_count"
      lb_prev=""
      [ -f "$lb_marker" ] && lb_prev="$(cat "$lb_marker" 2>/dev/null || echo "")"
      if [ "$lb_prev" != "$lb_key" ]; then
        # R3: the release is conditional on the marker WRITE SUCCEEDING. It used to be
        # `> marker || true` followed by an unconditional exit 0, so an unwritable
        # directory or a full disk turned "release once per count" into "release every
        # turn" — verbatim the large hole in the anti-stall guarantee the comment above
        # says the marker prevents. Falling through to the block is this hook's
        # pre-existing behavior, so making the release conditional adds no soft-lock
        # risk: the worst case is the run does not get its extra yield and must set
        # expected_next_action=user-approval to surface, which the ack ritual does anyway.
        if printf '%s\n' "$lb_key" > "$lb_marker" 2>/dev/null; then
          lb_msg="auto-task loop budget: loop count $lb_count (max of iteration.fix=$lb_fix and iteration.review=$lb_review) exceeds the tier=$lb_tier budget of $lb_budget (cap $lb_cap). Releasing this turn-end ONCE so the run can surface a budget check-in — show the user the per-round finding severities so they can judge whether returns have diminished, then let them decide. A commit stays blocked until gates.loop_budget.acked_through is raised on their go-ahead. Further turn-ends at this same iteration count will block again."
          # SURFACE ON BOTH CHANNELS. stderr alone is not enough on an ALLOW: for a Stop
          # hook, `exit 0` means "allow" and only the block path's stdout JSON is
          # model-facing, so a stderr-only notice can be written and never delivered —
          # which would be precisely the run this release exists for (one that keeps
          # churning without updating expected_next_action, i.e. with nothing telling it
          # the budget is blown). `systemMessage` is this repo's established surfacing
          # field (check-version.sh, release-notes.sh, suggest-cleanup.sh all use it) and
          # carries no `decision`, so the stop is still ALLOWED. stderr stays as the
          # belt-and-suspenders, exactly as warn-checkout-drift.sh pairs the two.
          # Emitted best-effort: if jq is somehow unavailable here the release still fires.
          jq -n --arg m "$lb_msg" '{systemMessage:$m}' 2>/dev/null || true
          echo "$lb_msg" >&2
          exit 0
        fi
      fi
    fi
  fi
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
