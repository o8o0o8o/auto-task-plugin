#!/usr/bin/env bash
# loop-budget.sh — SHARED, SOURCED helper resolving the effort-tier FIX-LOOP BUDGET.
#
# WHY THIS FILE EXISTS. The fix-loop cap is documented in prose in two places
# (`skills/auto-task/SKILL.md` Effort-tiers table and the duplicate table in
# `skills/auto-task/ARCHITECTURE.md`) and is now enforced by two hooks
# (`enforce-gates.sh` blocks the commit; `prevent-mid-protocol-stall.sh` releases
# the turn-end so the run can surface). Hardcoding the numbers in both hooks would
# put the cap table in FOUR unsynchronized places — the same duplication class that
# cost an earlier run four review rounds when one marker grammar lived in three
# rules. So the executable definition lives here, once, and both hooks source it.
# The prose tables remain (they are documentation), but they document THIS.
#
# PURE HELPER. Every function writes to stdout and returns; NONE of them `exit`,
# mutate a file, or decide a fail-policy — the caller owns that. Same contract as
# `hooks/lib/resolve-run-state.sh`, for the same reason: the two hooks that source
# this have OPPOSITE fail policies (the gate hook fails CLOSED, the stall hook fails
# OPEN), so a helper that exited or blocked would be wrong for one of them.
#
# Contract: source this file, then call the functions below.
#   lb_cap_for_tier <tier>            -> the fix-loop cap for that tier
#   lb_is_number <value>              -> 0 if a bare non-negative integer, else 1
#   lb_effective_budget <cap> <acked> -> the budget a run may spend before blocking
#   lb_strip_zeros <digits>           -> the value without leading zeros (octal-safe)
#   lb_next_budget <cap> <acked> [count] -> what an ack should record
#   lb_gate_b_cap <tier>              -> max MAIN-loop Gate B adversarial passes
#   lb_gate_b_regate_cap              -> max Gate B passes per re-gate site, per run

# lb_cap_for_tier <tier> -> cap on stdout
#   Mirrors the Effort-tiers table: LIGHT 2 / STANDARD 4 / HEAVY 6.
#   An unrecognized or empty tier yields the STANDARD cap, matching the
#   `.effort.tier // "standard"` default the gate hook already applies. NOTE for
#   callers: that default means "unrecognized tier" and "absent effort object" are
#   indistinguishable here — a caller that must NOT enforce on a legacy run (one
#   predating the effort object) has to probe for absence itself, before calling
#   this. The gate hook does exactly that; getting it wrong would block runs that
#   started before this feature existed.
lb_cap_for_tier() {
  case "${1:-}" in
    light)    printf '2' ;;
    heavy)    printf '6' ;;
    standard) printf '4' ;;
    *)        printf '4' ;;
  esac
}

# lb_is_number <value> -> return 0 when the value is a bare non-negative integer
#   that bash can actually compare.
#   Load-bearing in a fail-CLOSED caller. `[ "abc" -gt 6 ]` does not evaluate false
#   — it ERRORS (status 2, stderr noise), so an `if` around it takes the else branch
#   and the guard silently fails OPEN. That is precisely wrong in a hook whose
#   documented policy is to block when it cannot verify. Callers must validate
#   before comparing. Idiom borrowed from prevent-mid-protocol-stall.sh, which
#   already sanitizes its own counters this way.
#
#   Callers that go on to use the value in `$(( ))` must normalize it with
#   `lb_strip_zeros` first — bash ARITHMETIC reads a leading-zero value as octal and
#   dies on `09` ("value too great for base"), even though `[ 09 -gt 6 ]` compares
#   base-10 correctly. Validation alone is therefore not enough for an arithmetic
#   caller; see lb_strip_zeros below.
#
#   MAGNITUDE IS PART OF THE CONTRACT, not a nicety. A digits-only check is NOT
#   sufficient: `[ 99999999999999999999 -gt 4 ]` is all digits yet still errors with
#   "integer expression expected" (status 2), reproducing the exact fail-OPEN this
#   function exists to close — a run could set `iteration.fix` to a 20-digit number
#   and walk straight past the budget gate. bash compares via a signed 64-bit
#   conversion, so anything wider than INT64_MAX (19 digits, 9223372036854775807)
#   errors; 18 digits is the widest length that is unconditionally safe, and no real
#   iteration counter comes anywhere near it. Leading zeros are stripped before the
#   length test so `0000000000000000000005` is judged on its value, not its padding.
lb_is_number() {
  local v
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  v="$(lb_strip_zeros "$1")"
  [ "${#v}" -gt 18 ] && return 1
  return 0
}

# lb_strip_zeros <digits> -> the same value without leading zeros, on stdout.
#   Exists because a validated, all-digit counter can STILL blow up a caller: bash
#   arithmetic (`$(( ))`, unlike `[ ]`) treats a leading zero as an octal prefix, so
#   `$(( 09 + 1 ))` is a fatal "value too great for base" error. In a fail-CLOSED
#   hook that surfaced as raw shell noise plus an `acked_through: ` with no value —
#   an invalid `jq` recovery snippet, i.e. a block the documented recovery could not
#   clear. Every arithmetic path here normalizes through this first.
#   All-zeros collapses to the empty string, so restore a single 0.
lb_strip_zeros() {
  local v
  v="${1#"${1%%[!0]*}"}"
  [ -z "$v" ] && v=0
  printf '%s' "$v"
}

# lb_effective_budget <cap> <acked_through> -> budget on stdout
#   `max(cap, acked_through)`, NOT `acked_through` alone. If a run's tier escalates
#   after an ack (LIGHT→HEAVY takes the cap 2→6), an ack recorded at the old, lower
#   tier would otherwise leave the run under-budgeted and re-block immediately at
#   the new tier. Taking the max means an escalation can only ever RAISE the budget,
#   which matches "effort can only escalate" in the skill.
#   `acked_through` is an ABSOLUTE iteration number (not a multiple-of-cap counter),
#   so an escalation shifts only the next increment and never invalidates an ack
#   already given.
lb_effective_budget() {
  # `local` matters: callers legitimately use variables named cap/budget (see
  # enforce-gates.sh), and today the only thing preventing a collision is that every
  # call site happens to use $( ), which subshells. Scoping here removes the
  # dependency on that rather than trusting each future caller to remember it.
  local cap acked
  cap="${1:-4}"; acked="${2:-0}"
  lb_is_number "$cap"   || cap=4
  lb_is_number "$acked" || acked=0
  cap="$(lb_strip_zeros "$cap")"; acked="$(lb_strip_zeros "$acked")"
  if [ "$acked" -gt "$cap" ]; then printf '%s' "$acked"; else printf '%s' "$cap"; fi
}

# lb_next_budget <cap> <acked_through> [count] -> what an ack should record, on stdout
#   `count` is the run's LOOP COUNT — max(iteration.fix, iteration.review), the same
#   quantity both hooks block/release on; it is not the fix counter alone.
#   Advances the effective budget in WHOLE CAP STEPS until it clears `count`, so the
#   budget levels stay on cap multiples (HEAVY: 6 -> 12 -> 18 -> 24, check-ins at
#   loop count = 7, 13, 19, 25) and the surfaces stay predictable.
#
#   WHY `count` IS A PARAMETER. It used to compute `budget + cap` and never look at
#   the run's actual position. That is correct only when the run meets the gate
#   exactly one iteration past budget. But the gate runs at COMMIT time while the
#   counters accumulate through the loop, so a run that spent 33 rounds against a
#   HEAVY cap of 6 met the gate once, already at 33 — and a single-cap step meant FIVE
#   successive acks (12, 18, 24, 30, 36) to land, each one asking the user to approve
#   budget already spent, and each block announcing a "next check-in" (13, 19, 25...)
#   that was already in the past. A loop count of 33 against cap 6 is the exact run
#   cited as this feature's motivation, so the feature failed its motivating case.
#   Stepping to the first rung that clears `count` makes one ack always sufficient.
#
#   `count` is OPTIONAL and defaults to 0: omitted or non-numeric reproduces the old
#   single-step result, so a caller that cannot supply a position is never worse off.
lb_next_budget() {
  local cap budget count steps
  cap="${1:-4}"
  lb_is_number "$cap" || cap=4
  cap="$(lb_strip_zeros "$cap")"
  budget="$(lb_effective_budget "$cap" "${2:-0}")"
  count="${3:-0}"
  lb_is_number "$count" || count=0
  count="$(lb_strip_zeros "$count")"
  # At least one step (an ack must always raise the budget), then as many more whole
  # cap steps as it takes to cover `fix`. Integer ceiling: (d + cap - 1) / cap.
  steps=1
  if [ "$count" -gt "$budget" ]; then
    steps=$(( (count - budget + cap - 1) / cap ))
    [ "$steps" -lt 1 ] && steps=1
  fi
  printf '%s' "$(( budget + steps * cap ))"
}

# lb_gate_b_cap <tier> -> max MAIN-loop Gate B adversarial passes, on stdout
#   A SECOND, INDEPENDENT bound, and it must not be confused with the fix-loop cap
#   above. The fix-loop cap counts ROUNDS OF ITERATION (max of iteration.fix and
#   iteration.review) and only bites at commit time; this one counts ADVERSARIAL
#   PASSES and bites at Gate-B entry. Measured runs are why both exist: across seven
#   completed runs Gate B ran 4-11 passes with required-finding counts that never
#   decayed (3,2,3,3,3,2,3,4,0 over nine passes in one HEAVY run), and blockers
#   arrived at passes 3 and 5 rather than pass 1 — i.e. the fixes were manufacturing
#   the next pass's findings. The fix-loop cap could not bound that, because it is
#   only read by `git commit` and the loop never commits.
#
#   LIGHT yields 0 because LIGHT SKIPS GATE B ENTIRELY (the Effort-tiers table sets
#   gate_b.skipped_reason='tier=light'). 0 here means "no pass is permitted", which
#   is the honest encoding of "this tier does not run this gate" — a caller must not
#   read it as "unlimited". An unrecognized or empty tier yields the STANDARD cap,
#   matching lb_cap_for_tier's default and the gate hook's `.effort.tier //
#   "standard"`; the same caveat applies, namely that "unrecognized tier" and
#   "absent effort object" are indistinguishable here, so a caller that must not
#   enforce on a legacy run has to probe for absence itself.
lb_gate_b_cap() {
  case "${1:-}" in
    light)    printf '0' ;;
    heavy)    printf '3' ;;
    standard) printf '2' ;;
    *)        printf '2' ;;
  esac
}

# lb_gate_b_regate_cap -> max Gate B passes for ONE re-gate site, for the whole run
#   Four sites re-run Gate B after the main loop ends (the Phase-5 docs step, the
#   Phase-5 merge-conflict finalize, the Phase-6 bot-fix commit, the Phase-9 release
#   commit). Each resets gates.gate_b.passed to false, and phase-5-handover.md says
#   of the docs one: "Leaving it `false` would block the handover commit."
#
#   SO THIS ALLOWANCE IS DELIBERATELY SEPARATE FROM lb_gate_b_cap, AND TAKES NO TIER
#   OR COUNTER ARGUMENT. Were a re-gate to draw on the main-loop cap, a run that
#   spent its passes in the main loop could never re-earn the gate, and the handover
#   commit would deadlock — with docs_update_mode=always that would be every run.
#   Taking no argument is the enforcement: there is no input through which the main
#   counter could leak in.
#
#   2 = one pass plus one fix-and-re-pass. It is PER SITE PER RUN, not per round:
#   a site that executes repeatedly (Phase 6 can, the docs step can) must not renew
#   its allowance, or the bounded re-gate becomes the same unbounded loop in a
#   smaller room. Exceeding it surfaces to the user; it never silently passes the
#   gate and never leaves the run wedged.
lb_gate_b_regate_cap() {
  printf '2'
}
