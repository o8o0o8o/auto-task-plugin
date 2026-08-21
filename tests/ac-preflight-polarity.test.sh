#!/usr/bin/env bash
# Drift guard for AC pre-flight POLARITY + the discrimination check.
#
# WHY THIS EXISTS. Pre-flight already dry-ran every executable AC and pinned a
# baseline, but it never asked whether the baseline could MOVE. A `change` AC
# whose check already passes before any code changed cannot tell "done" from
# "not done": Phase 3 records a pass, Gate A has no movement to compare, and the
# run greens without verifying anything. That failure is silent, which is exactly
# the class a grep guard has to hold, because no hook enforces AC results (see
# the INCONCLUSIVE floor: "no hook enforces AC pass/fail").
#
# The contract is stated in TWO places by design — the always-loaded spine
# (skills/auto-task/SKILL.md) indexes it, references/phase-1-preamble.md carries
# it. Prose has no compiler, so the specific risks pinned here are:
#   * the two sites drifting apart on the result vocabulary (an index that lists
#     three values while the contract lists five is worse than no index),
#   * `vacuous` silently acquiring a human stop (it must be an AC rewrite, or
#     every red baseline costs the run its single approval gate),
#   * `pre-broken` silently losing its stop (the run would adopt someone else's
#     breakage as its own AC and spend fix-loop rounds on it),
#   * the discrimination step drifting after sample-verify, where a `vacuous` AC
#     would already have been sample-verified and pinned as sound.
#
# Pure and hermetic: greps files in the repo. No model, no network, no writes.
# Ends with a MUTATION CONTROL. Every claim this change introduced is collected in
# CLAIMS below and evaluated TWICE: against the real spec, where all must hold, and
# against a copy with the whole discrimination block excised, where ALL must fail.
# A weaker control (spot-checking two or three claims, or asserting only that the
# strip removed some lines) would pass while most of the battery asserted nothing —
# and a guard that can't fail is the exact defect this change exists to catch, so
# this file has to hold itself to its own rule.
#
# Usage: tests/ac-preflight-polarity.test.sh   Exit 0 = in sync.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/spec.sh"
spec_concat_into SKILL
SPINE="$ROOT/skills/auto-task/SKILL.md"          # spine-only: the index must stay loaded
PRE="$ROOT/skills/auto-task/references/phase-1-preamble.md"

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-58s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-58s got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }
# has <file> <fixed-string> -> yes|no
has(){ grep -qF "$2" "$1" 2>/dev/null && echo yes || echo no; }
# n <file> <fixed-string> -> occurrence count.
# `grep -c` already prints 0 on no match and exits 1; a `|| echo 0` fallback would
# print a SECOND zero on its own line, so every zero-count assertion would compare
# "0\n0" against "0" and fail for the wrong reason. Guard only the missing-file case.
n(){ local c; c="$(grep -cF -- "$2" "$1" 2>/dev/null)"; printf '%s\n' "${c:-0}"; }

ENUM='result: "pinned|vacuous|pre-broken|failed-syntax|unreliable-signal"'
OLD_ENUM='result: "pinned|failed-syntax|unreliable-signal"'
POL='polarity: "change|invariant"'

echo "================ AC pre-flight polarity ================"

# --- the history entry carries polarity AND the widened result enum ----------
# Both sites, or the index lies about the contract. SUMMED across the union: the
# spine's index and the preamble's contract are the two expected occurrences.
# The spine logs a bare `polarity` (its values are defined in the same sentence) —
# the 120 KB spine cap does not fund a second copy of the enum. So: the explicit
# enum lives in the contract exactly once, and the spine is pinned separately below.
expect "contract: explicit polarity enum"           "$(n "$SKILL" "$POL")"       "1"
expect "spine: logs a polarity field"               "$(has "$SPINE" 'ac, polarity, result:')" "yes"
expect "history entry: 5-value result enum, both"    "$(n "$SKILL" "$ENUM")"      "2"
# Anti-regression, union-scoped: the superseded 3-value enum is gone EVERYWHERE.
# A stale copy surviving in any reference would be read as the live vocabulary.
expect "superseded 3-value enum absent (union)"      "$(n "$SKILL" "$OLD_ENUM")"  "0"
expect "spine keeps the index (not demoted)"         "$(has "$SPINE" "$ENUM")"    "yes"
expect "contract carries the enum"                   "$(has "$PRE" "$ENUM")"      "yes"

# --- the outcome count was reconciled in both places ------------------------
# The count is load-bearing prose: a reader who trusts "three" stops classifying
# after the third cell and never reaches pre-broken.
expect "contract: five outcomes"                     "$(has "$PRE" 'Pre-flight produces one of five outcomes:')" "yes"
expect "spine: five outcomes restated"               "$(has "$SPINE" '**Five outcomes, restated inline:**')"     "yes"
expect "stale 'three outcomes' absent (union)"       "$(n "$SKILL" 'one of three outcomes')"                     "0"
expect "stale 'Three outcomes' absent (union)"       "$(n "$SKILL" 'Three outcomes, restated inline')"           "0"

# --- polarity is DEFINED, not just named ------------------------------------
# Naming the field without the classification rule leaves every AC unclassifiable.
expect "polarity: change must FAIL at baseline"      "$(has "$PRE" 'The baseline MUST **fail**')"  "yes"
expect "polarity: invariant must PASS at baseline"   "$(has "$PRE" 'The baseline MUST **pass**')"  "yes"
expect "spine states change-baseline direction"      "$(has "$SPINE" '`change` (baseline MUST fail)')"    "yes"
expect "spine states invariant-baseline direction"   "$(has "$SPINE" '`invariant` (baseline MUST pass)')"  "yes"

# --- the two defect cells, and their ASYMMETRIC routing ---------------------
# This is the pair most likely to be "simplified" into one rule. They must not be:
# vacuous is a flaw in the AC (rewrite it, no gate cost); pre-broken is a flaw in
# the premise (only the user can decide). Collapsing them either burns the
# approval gate on every red baseline or silently adopts foreign breakage.
expect "vacuous cell named"                          "$(has "$PRE" 'already passes → `vacuous`')"                 "yes"
expect "pre-broken cell named"                        "$(has "$PRE" 'already fails → `pre-broken`')"               "yes"
expect "vacuous: routes to an AC rewrite"            "$(has "$PRE" 'rewrite the AC into a check that discriminates')" "yes"
expect "vacuous: does NOT stop for approval"         "$(has "$PRE" 'Do NOT stop for human approval')"             "yes"
expect "vacuous: unmeasurable fallback is a stop"    "$(has "$PRE" 'cannot articulate measurable AC')"            "yes"
# The bound is SHARED with `failed-syntax` — the route `vacuous` was modelled on,
# which loops the same way and had no bound of its own. A one-sided bound would
# leave the twin spinning while the contract claimed the loop was handled.
expect "budget: stated once, for both routes"        "$(has "$PRE" '**Rewrite budget (applies to `failed-syntax` and `vacuous` alike).**')" "yes"
expect "budget: two rewrites per AC"                 "$(has "$PRE" 'At most two rewrites per AC')"                   "yes"
expect "budget: count is reconstructible on resume"  "$(has "$PRE" 'reconstructible on resume')"                     "yes"
expect "budget: failed-syntax route cites it"        "$(has "$PRE" 'within the rewrite budget above')"               "yes"
expect "budget: syntax step cites it"                "$(has "$PRE" 'Bounded by the same **rewrite budget** as `vacuous`')" "yes"
expect "budget: names why no hook can enforce it"    "$(has "$PRE" 'sees only `git commit`, which Phase 1 never reaches')" "yes"
# Anti-regression: the retracted uniqueness claim must not come back. It was false —
# `failed-syntax` was an equally unbounded route at the time it was written.
expect "no false 'only unbounded route' claim"       "$(n "$SKILL" 'the only unbounded-looking route')"              "0"
expect "pre-broken: stops BEFORE the human gate"     "$(has "$PRE" 'STOP and surface BEFORE the human gate** with the failing output')" "yes"
expect "pre-broken: names the fix-loop cost"         "$(has "$PRE" "spends fix-loop rounds on someone else's breakage")" "yes"
# The outcome list must route all five, or the list and the cells disagree.
expect "outcome list: vacuous routed"                "$(has "$PRE" 'whose baseline already passes (`vacuous`)')"   "yes"
expect "outcome list: pre-broken routed"             "$(has "$PRE" 'whose baseline already fails (`pre-broken`)')" "yes"
expect "spine: vacuous routed"                       "$(has "$SPINE" 'already passes (`vacuous`')"                 "yes"
expect "spine: pre-broken routed"                    "$(has "$SPINE" 'already fails (`pre-broken`)')"              "yes"

# --- the rationale that keeps the step from being read as ceremony ----------
# Without it a future edit reads the step as TDD ritual and drops it as overhead.
# The claim is specific and falsifiable, so it is worth pinning verbatim.
expect "rationale: never-failed == cannot-fail"      "$(has "$PRE" 'indistinguishable from a check that *cannot* fail')" "yes"
expect "rationale: fail-to-pass named"               "$(has "$PRE" 'fail-to-pass')"                                     "yes"
expect "rationale: pre-change tree is the only shot" "$(has "$PRE" 'the only moment the pre-change tree still exists')"  "yes"
# The spine keeps the SHORT form of the rationale; the full argument is contract-side.
# Byte budget: the spine sits 15 B under its 122,880 B cap, so the index carries the
# claim that stops a future editor reading the step as TDD ceremony, and nothing more.
expect "spine carries the discrimination reason"     "$(has "$SPINE" 'it cannot tell done from not-done')"              "yes"

# --- ORDER: discrimination runs before sample-verification ------------------
# Positional, and co-location-guarded by spec_before (it refuses a cross-file
# pair). A `vacuous` AC sample-verified first is pinned as sound before anything
# asks whether its check can move at all.
spec_before 'Discrimination check' 'Sample-verify when the AC depends'; ord=$?
expect "order: discrimination BEFORE sample-verify"  "$ord" "0"
spec_before 'Discrimination check' 'Pre-flight syntax check'; ord2=$?
expect "order: discrimination BEFORE syntax check"   "$ord2" "0"
# Step numbering stayed consistent through the insertion (no duplicate ordinals).
expect "steps renumbered: sample-verify is 4"        "$(has "$PRE" '4. **Sample-verify when the AC depends')" "yes"
expect "steps renumbered: syntax check is 5"         "$(has "$PRE" '5. **Pre-flight syntax check.**')"        "yes"

# --- the PLAN.md evidence bullet surfaces polarity to the human gate --------
# The gate is where a human can still catch a vacuous AC; a bullet that omits
# polarity hides exactly the field they would check.
expect "PLAN.md bullet carries polarity"             "$(has "$PRE" 'AC #N — <change|invariant>; baseline pinned')" "yes"
expect "PLAN.md bullet states baseline direction"    "$(has "$PRE" '<fails|passes> as required')"                  "yes"

# --- MUTATION CONTROL -------------------------------------------------------
# See the header: the battery is re-evaluated against a mutant with the whole
# discrimination block excised. Every claim below must hold on the real spec and
# FAIL on the mutant. A claim that survives the mutation is not anchored to the
# clause it purports to guard.

# Every fixed string this change introduced into the contract or the spine.
CLAIMS=(
  "$POL"
  "$ENUM"
  'Pre-flight produces one of five outcomes:'
  '**Five outcomes, restated inline:**'
  'The baseline MUST **fail**'
  'The baseline MUST **pass**'
  '`change` (baseline MUST fail)'
  '`invariant` (baseline MUST pass)'
  'Discrimination check'
  'already passes → `vacuous`'
  'already fails → `pre-broken`'
  'rewrite the AC into a check that discriminates'
  'Do NOT stop for human approval'
  'At most two rewrites per AC'
  'Rewrite budget (applies to `failed-syntax` and `vacuous` alike)'
  'max 2 rewrites'
  'Neither cell fits?'
  'do not invent a third polarity value'
  "spends fix-loop rounds on someone else's breakage"
  'indistinguishable from a check that *cannot* fail'
  'fail-to-pass'
  'the only moment the pre-change tree still exists'
  'it cannot tell done from not-done'
  'AC #N — <change|invariant>; baseline pinned'
  '<fails|passes> as required'
)

# TWO mutants, because "the claim is real" and "the claim is anchored" are
# different properties and a single strip conflates them.
#
# M1 = the spec at HEAD, i.e. the feature never added. Every claim must be ABSENT
# there, which is what "this change introduced it" means. This is the control that
# catches a tautological assertion — one pinning text that already existed, and so
# would stay green if the whole feature were reverted. It is not circular: HEAD is
# an independent artifact, not a strip of the strings under test.
#
# M2 = the discrimination block excised from the contract. Only the claims whose
# home IS that block are required to die here; the rest legitimately live in step
# 2's history entry, the outcome list, or the evidence bullet. The subset is
# computed from the block text rather than hardcoded, so it cannot rot.
echo "---------------- mutation control ----------------"
M1="$(mktemp "${TMPDIR:-/tmp}/ac-preflight-m1.XXXXXX")"
M2="$(mktemp "${TMPDIR:-/tmp}/ac-preflight-m2.XXXXXX")"
BLOCK="$(mktemp "${TMPDIR:-/tmp}/ac-preflight-blk.XXXXXX")"
trap 'rm -f "$M1" "$M2" "$BLOCK"; _spec_concat_cleanup' EXIT

git -C "$ROOT" show "HEAD:skills/auto-task/SKILL.md"                        >  "$M1" 2>/dev/null
git -C "$ROOT" show "HEAD:skills/auto-task/references/phase-1-preamble.md"  >> "$M1" 2>/dev/null
# Fail closed: an empty M1 would make every absence assertion pass vacuously.
expect "control premise: HEAD spec readable"         "$([ -s "$M1" ] && echo yes || echo no)" "yes"

# The block under test, and the contract without it.
awk '/^3\. \*\*Discrimination check/{s=1} /^4\. \*\*Sample-verify when the AC depends/{s=0} s' "$PRE" > "$BLOCK"
awk '/^3\. \*\*Discrimination check/{s=1} /^4\. \*\*Sample-verify when the AC depends/{s=0} !s' "$PRE" > "$M2"
expect "control premise: block is non-empty"         "$([ -s "$BLOCK" ] && echo yes || echo no)" "yes"
expect "control premise: block was excised"          "$([ "$(wc -l < "$M2")" -lt "$(wc -l < "$PRE")" ] && echo yes || echo no)" "yes"

real_held=0; m1_held=0; anchored=0; m2_held=0
for c in "${CLAIMS[@]}"; do
  [ "$(has "$SKILL" "$c")" = yes ] && real_held=$((real_held+1))
  if [ "$(has "$M1" "$c")" = yes ]; then
    m1_held=$((m1_held+1)); printf '        PRE-EXISTING at HEAD (tautological?): %s\n' "$c"
  fi
  # Anchored claims: those whose text lives inside the discrimination block.
  if [ "$(has "$BLOCK" "$c")" = yes ]; then
    anchored=$((anchored+1))
    if [ "$(has "$M2" "$c")" = yes ]; then
      m2_held=$((m2_held+1)); printf '        survived block excision: %s\n' "$c"
    fi
  fi
done
expect "battery: every claim holds on the real spec"  "$real_held" "${#CLAIMS[@]}"
expect "M1: no claim pre-exists at HEAD"              "$m1_held"   "0"
expect "M2: the block owns a real share of claims"    "$([ "$anchored" -ge 8 ] && echo yes || echo no)" "yes"
expect "M2: no anchored claim survives excision"      "$m2_held"   "0"

echo "-------------------------------------------------"
printf 'PASS=%d FAIL=%d (claims=%d, block-anchored=%d)\n' "$PASS" "$FAIL" "${#CLAIMS[@]}" "$anchored"
[ "$FAIL" -eq 0 ] || exit 1
