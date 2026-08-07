#!/usr/bin/env bash
# Focused test for the BOUNDED Gate B adversarial loop.
#
# WHY THIS SUITE EXISTS. Gate B did not converge. Measured across seven completed
# runs it ran 4-11 adversarial passes each, required-finding counts never decayed
# (one HEAVY run went 3,2,3,3,3,2,3,4,0 over nine passes), blockers first appeared
# at passes 3 and 5 rather than pass 1 -- the fixes were manufacturing the next
# pass's findings -- and three of the seven runs ended by human fiat rather than by
# a clean pass. This suite pins the mechanisms that bound it.
#
# Asserts: the two new loop-budget helpers (values, bad-tier degradation, the
# pure-helper no-exit contract, and that the re-gate allowance cannot be influenced
# by the main-loop count); the convergence test on real measured sequences plus a
# still-decreasing control; content-hashed self_inflicted attribution SURVIVING a
# line shift; the AC-gated reopen decision including its fail-closed default and
# park_non_blocking's precedence over it; and that each of the three post-surface
# grants yields exactly one defined continuation.
#
# NOTE ON WHAT IS AND IS NOT TESTED HERE. No hook reads any of this -- a Gate B
# pass is an Agent spawn and hooks/hooks.json registers PreToolUse only for Bash --
# so there is no shell entry point to drive end-to-end. The rules live in
# references/phase-3-gates.md. This suite therefore does two separable things:
# (1) tests the shell helpers directly, and (2) implements each documented decision
# rule as a reference oracle and asserts the oracle's behaviour on the exact cases
# the spec claims. Where an oracle is used it is marked ORACLE, and a companion
# assertion pins the spec text the oracle mirrors, so the two cannot drift apart
# silently. Assertions of the spec PROSE itself live in enforcement-spine.test.sh.
#
# Usage: tests/gate-b-loop.test.sh   Exit 0 = all passed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LB="$ROOT/hooks/lib/loop-budget.sh"
GATES="$ROOT/skills/auto-task/references/phase-3-gates.md"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[ -f "$LB" ] || { echo "FAIL: $LB missing"; exit 1; }
[ -f "$GATES" ] || { echo "FAIL: $GATES missing"; exit 1; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-58s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-58s got=%s want=%s\n' "$1" "$2" "$3"; fi; }

# shellcheck source=/dev/null
. "$LB"

echo "================ Gate B: pass caps (loop-budget helpers) ================"

expect "lb_gate_b_cap standard"                 "$(lb_gate_b_cap standard)" "2"
expect "lb_gate_b_cap heavy"                    "$(lb_gate_b_cap heavy)"    "3"
# LIGHT used to yield 0 ("no pass permitted", NOT "unlimited") because it skipped the
# gate. It now runs it at one pass, so the self-review is no longer the only review.
expect "lb_gate_b_cap light is 1 (one independent pass)" "$(lb_gate_b_cap light)" "1"
# Degrade exactly like lb_cap_for_tier: unknown/empty -> the STANDARD value.
expect "lb_gate_b_cap '' degrades to standard"  "$(lb_gate_b_cap '')"       "2"
expect "lb_gate_b_cap bogus degrades to standard" "$(lb_gate_b_cap bogus)"  "2"
expect "lb_gate_b_regate_cap"                   "$(lb_gate_b_regate_cap)"   "2"

# Pure-helper contract: these are SOURCED into two hooks with opposite fail
# policies, so a helper that exited would be wrong for one of them. The trailing
# marker is the proof -- it cannot print if the helper exited the shell.
noexit="$(lb_gate_b_cap heavy >/dev/null; lb_gate_b_cap bogus >/dev/null; lb_gate_b_regate_cap >/dev/null; printf 'alive')"
expect "helpers never exit the shell (pure-helper contract)" "$noexit" "alive"

# The re-gate allowance must be STRUCTURALLY unable to see the main-loop count:
# were it coupled, a run that spent its main-loop passes could never re-earn
# gates.gate_b.passed and the handover commit would deadlock. Taking no argument
# is the enforcement, so passing garbage must not change the answer.
for probe in 0 2 3 99 "" bogus; do
  expect "regate cap ignores arg '$probe'" "$(lb_gate_b_regate_cap "$probe")" "2"
done
# The four existing helpers must be untouched by this additive change.
expect "regression: lb_cap_for_tier heavy"      "$(lb_cap_for_tier heavy)"      "6"
expect "regression: lb_effective_budget 6 12"   "$(lb_effective_budget 6 12)"   "12"
expect "regression: lb_next_budget 6 0 33"      "$(lb_next_budget 6 0 33)"      "36"

# GATE-A FINDING (AC 9): the invariance probes above are necessary but not
# sufficient -- they show the CURRENT helper ignores an argument, not that it is
# structurally unable to read the main-loop count. Assert the decoupling at the
# source: lb_gate_b_regate_cap's body must reference no positional parameter and no
# main-loop counter. Run against the function body only, so the surrounding comment
# (which legitimately mentions lb_gate_b_cap contrastively) cannot mask a real
# coupling. Gate A's literal reading of the originally-declared check failed for
# exactly that reason -- contrastive mentions in prose are not couplings.
regate_body="$(awk '/^lb_gate_b_regate_cap\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$LB")"
expect "regate cap body references no positional parameter" \
  "$(printf '%s' "$regate_body" | grep -cE '\$[0-9]|\$\{[0-9]|\$@|\$\*' | tr -d ' ')"       "0"
expect "regate cap body reads no main-loop counter" \
  "$(printf '%s' "$regate_body" | grep -cE 'lb_gate_b_cap|iteration|passes|acked' | tr -d ' ')" "0"
expect "regate cap body is a bare constant"        "$(printf '%s' "$regate_body" | grep -c "printf '2'" | tr -d ' ')" "1"

# GATE-A ROUND-2 FINDING: the body check above proves the HELPER cannot see the main
# count, but the criterion's claim is that no re-gate RULE reads it -- and the rules
# are prose. Gate A defeated the earlier version by rewriting a site's allowance
# clause to "sized by what is LEFT of lb_gate_b_cap after subtracting every
# passes.main entry" and nothing failed. So check the PROSE for the actual coupling
# tokens. `lb_gate_b_cap` is deliberately NOT one of them: every site names it
# contrastively ("counted separately from the main loop's lb_gate_b_cap"), which is
# the reason the originally-declared check could not work. `passes.main`,
# `passes\[` and `iteration.review` have no legitimate use in a re-gate allowance
# clause -- reading either IS the coupling.
REGSITES="$ROOT/skills/auto-task/references/phase-5-handover.md $ROOT/skills/auto-task/references/phase-6-8-post-pr.md $ROOT/skills/auto-task/references/phase-9-release.md"
# shellcheck disable=SC2086
regate_clauses="$(grep -h 'own Gate B allowance for this run' $REGSITES)"
expect "4 re-gate allowance clauses found"  "$(printf '%s\n' "$regate_clauses" | grep -c 'own Gate B allowance for this run' | tr -d ' ')" "4"
expect "no re-gate clause reads passes.main" \
  "$(printf '%s' "$regate_clauses" | grep -cE 'passes\.main|passes\[|\bmain\b entry' | tr -d ' ')" "0"
expect "no re-gate clause reads iteration.review" \
  "$(printf '%s' "$regate_clauses" | grep -c 'iteration.review' | tr -d ' ')" "0"
expect "no re-gate clause subtracts a spent main count" \
  "$(printf '%s' "$regate_clauses" | grep -ciE 'subtract|what is left of|remaining after' | tr -d ' ')" "0"
# The Step-0 allowance lookup must resolve a regate scope through its own helper and
# must not consult the main count either.
# ANCHOR AMBIGUITY, pinned rather than left to luck. `^### Step 0 —` matched exactly one
# heading until Phase 4 gained a Step 0 of its own; there are now two, and this awk takes
# the FIRST. It still resolves to Gate B only because Gate B ships earlier in the file --
# an ordering accident, not a guarantee. The repo already treats this as a hazard worth
# pinning rather than tolerating (`enforcement-spine.test.sh`: "`6. **Re-pass the gates`
# is AMBIGUOUS across the spec ... pin the count: if a third copy appears, the anchor
# becomes order-dependent"). Same treatment here, in both directions: the count is fixed
# at two, and the first occurrence must be Gate B's. A third heading, or a reorder that
# floats Phase 4's above Gate B's, reddens this instead of silently re-pointing the two
# region slices below at the wrong contract.
expect "anchor: '### Step 0 —' occurs exactly twice" \
  "$(grep -c '^### Step 0 —' "$GATES" | tr -d ' ')" "2"
expect "anchor: ...and the FIRST is Gate B's, which both slices assume" \
  "$(grep -m1 '^### Step 0 —' "$GATES" | grep -c 'pass accounting' | tr -d ' ')" "1"
step0="$(awk '/^### Step 0 —/{f=1} f{print} f&&/^### Step 1 —/{exit}' "$GATES")"
expect "Step 0 resolves regate scopes via their own helper" \
  "$(printf '%s' "$step0" | grep -c 'lb_gate_b_regate_cap` for any `regate:\*` scope' | tr -d ' ')" "1"
expect "Step 0 does not subtract the main count for a regate scope" \
  "$(printf '%s' "$step0" | grep -ciE 'subtract|what is left of' | tr -d ' ')" "0"

echo "================ Gate B: convergence test (loop-rule clause 5) ================"

# ORACLE for: "when a round's blocker+required count fails to DECREASE versus the
# previous round, the loop has CONVERGED". One round fires it; there is no
# two-consecutive requirement, because two-consecutive is unreachable under a cap
# of 2 -- the dead-clause defect this replaces.
converge_at(){ local prev="" i=0 n; for n in $1; do i=$((i+1))
    if [ -n "$prev" ] && [ "$n" -ge "$prev" ]; then printf '%s' "$i"; return; fi; prev="$n"; done; printf 'none'; }

# The real measured HEAVY sequence. Under the OLD rule this never fired.
expect "HEAVY 3 2 3 3 3 2 3 4 converges at pass 3" "$(converge_at "3 2 3 3 3 2 3 4")" "3"
# STANDARD's cap is 2, so the test must be able to fire at pass 2 or it is dead on
# the tier most runs use.
expect "STANDARD 3 3 converges at pass 2"          "$(converge_at "3 3")"            "2"
expect "  ...and pass 2 is within the STANDARD cap" \
  "$([ "$(converge_at "3 3")" -le "$(lb_gate_b_cap standard)" ] && echo yes || echo no)" "yes"
expect "HEAVY convergence within the HEAVY cap" \
  "$([ "$(converge_at "3 2 3 3 3 2 3 4")" -le "$(lb_gate_b_cap heavy)" ] && echo yes || echo no)" "yes"
# CONTROL: the rule must NOT fire while returns are genuinely still improving,
# else it is a rule that always fires and bounds nothing meaningful.
expect "control: still-decreasing 3 2 1 never converges" "$(converge_at "3 2 1")" "none"
expect "control: single pass cannot converge"            "$(converge_at "3")"     "none"
# GATE-B PASS-3 FINDING (Required): the arithmetic test does fire on 0,0 (0 is not a
# decrease from 0), but clause 5 now excludes a clean round from the CONSEQUENCE -- it
# "has nothing to park and takes its loop's clean exit, never surfacing". Pinned
# behaviourally just below (clean_round_action), after converge_action is defined.
expect "clean-after-clean: arithmetic still fires"       "$(converge_at "0 0")"   "2"

# CODE-REVIEW FINDING (Blocker): convergence used to park-and-advance unconditionally,
# but the counted findings are the REOPENING ones -- AC breaches, runtime-reachable
# regressions, security paths -- so a non-decreasing count shipped exactly those with
# no human in the loop, on a laxer test than the cap path uses on the same evidence.
# ORACLE for the corrected rule: the ACTION depends on whether any reopening finding
# is still open at the converging pass, and the two cases are disjoint.
# REVIEW ROUND 2: the earlier oracle had a park-and-advance branch for "0 reopening
# left", but that state never reaches this test -- the resolution step passes the gate
# first. The test is only entered with a live finding, so it has ONE outcome.
converge_action(){ # $1=sequence of REOPENING counts (all > 0 by construction)
  local at; at="$(converge_at "$1")"
  [ "$at" = "none" ] && { printf 'continue'; return; }
  printf 'surface'; }
expect "converged -> SURFACE (never park-and-advance)"  "$(converge_action "3 3")"   "surface"
expect "converged on 1,1 -> SURFACE"                    "$(converge_action "1 1")"   "surface"
expect "not converged -> keep going"                    "$(converge_action "3 2 1")" "continue"
# GATE-B PASS-3 FINDING (Required): clause 5's clean-round exclusion had no behavioural
# pin -- reverting the spine to "a clean round of course also converges" left this whole
# suite green. A clean round takes its loop's clean exit; it never reaches the surface.
clean_round_action(){ # $1=sequence of blocker+required counts (0 = a clean round)
  local last; last="${1##* }"
  [ "$last" = "0" ] && { printf 'clean-exit'; return; }
  converge_action "$1"; }
expect "clean round after a clean round -> clean exit"   "$(clean_round_action "0 0")" "clean-exit"
expect "clean round after a dirty round -> clean exit"   "$(clean_round_action "3 0")" "clean-exit"
expect "a still-dirty non-decreasing round -> surface"   "$(clean_round_action "3 3")" "surface"
expect "spec: a clean round never surfaces" \
  "$(grep -qF "takes its loop's clean exit, never surfacing" "$ROOT/skills/auto-task/SKILL.md" && echo yes || echo no)" "yes"
# A zero-reopening pass is resolved BEFORE convergence, so the sequences this test
# sees never contain 0. Guard that assumption explicitly.
expect "a 0 in the sequence means the gate already passed upstream" \
  "$(printf '%s' "3 0" | grep -cE '(^| )0( |$)' | tr -d ' ')"                        "1"
# The reachable case the review named: HEAVY, counts 1,1 -> fires at pass 2, strictly
# BEFORE the cap of 3, so the cap surface would never have run.
expect "HEAVY 1 1 converges at pass 2 (before the cap)" "$(converge_at "1 1")" "2"
expect "  ...and that pass surfaces rather than advancing" "$(converge_action "1 1")" "surface"

echo "================ Gate B: self_inflicted attribution (content-hashed) ================"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# A pass-1 fix ADDS two lines. We record a hash per added line -- deliberately NOT
# a line range: a later fix that edits the same file ABOVE the hunk shifts every
# line below it, so coordinates would both miss real self-inflicted findings and
# invent false ones.
mkdir -p "$T/src"
cat > "$T/src/thing.sh" <<'EOF'
setup() { :; }
guard_added_by_fix1() { [ -n "${1:-}" ] || return 1; }
helper_added_by_fix1() { printf 'x'; }
unrelated_original() { printf 'y'; }
EOF
hash_line(){ sed -n "${2}p" "$1" | shasum | cut -d' ' -f1; }
H_GUARD="$(hash_line "$T/src/thing.sh" 2)"
H_HELPER="$(hash_line "$T/src/thing.sh" 3)"
FIXED_LINES="$(jq -cn --arg a "$H_GUARD" --arg b "$H_HELPER" \
  '[{path:"src/thing.sh",hashes:[$a,$b]}]')"

# ORACLE for: "a later finding is self_inflicted when the current content of its
# cited file:line hashes to one of those recorded lines."
is_self_inflicted(){ # $1=file $2=line $3=fixed_lines-json $4=relpath
  local h; h="$(hash_line "$1" "$2")"
  printf '%s' "$3" | jq -e --arg p "$4" --arg h "$h" \
    'any(.[]; .path == $p and (.hashes | index($h)))' >/dev/null 2>&1 && printf 'true' || printf 'false'; }

expect "finding on a fix-added line -> self_inflicted" \
  "$(is_self_inflicted "$T/src/thing.sh" 2 "$FIXED_LINES" "src/thing.sh")" "true"
expect "finding on an original line -> not self_inflicted" \
  "$(is_self_inflicted "$T/src/thing.sh" 4 "$FIXED_LINES" "src/thing.sh")" "false"

# THE CASE A COORDINATE SCHEME FAILS: a pass-2 fix inserts three lines ABOVE the
# recorded hunk. Every recorded line moves 2 -> 5 and 3 -> 6.
python3 - "$T/src/thing.sh" <<'PY'
import sys
p=sys.argv[1]; L=open(p).read().split("\n")
L[1:1]=["inserted_by_fix2_a() { :; }","inserted_by_fix2_b() { :; }","inserted_by_fix2_c() { :; }"]
open(p,"w").write("\n".join(L))
PY
expect "line shifted 2->5 by a later fix" \
  "$(sed -n '5p' "$T/src/thing.sh" | grep -c 'guard_added_by_fix1')" "1"
expect "shifted line STILL self_inflicted (content-addressed)" \
  "$(is_self_inflicted "$T/src/thing.sh" 5 "$FIXED_LINES" "src/thing.sh")" "true"
# And the coordinate that USED to hold it must no longer match -- this is the
# false positive a stored range would produce.
expect "old coordinate 2 now holds other code -> not self_inflicted" \
  "$(is_self_inflicted "$T/src/thing.sh" 2 "$FIXED_LINES" "src/thing.sh")" "false"
expect "a different path never matches" \
  "$(is_self_inflicted "$T/src/thing.sh" 5 "$FIXED_LINES" "src/other.sh")" "false"

# CODE-REVIEW FINDING (Required): content-only hashing over-matches. Identical lines
# hash identically, and fixes add non-unique lines constantly (`}`, `fi`, `else`,
# blanks), so one added `  fi` would mark every other `  fi` in the file
# self-inflicted -- corrupting the very signal the user reads to decide. Two rules
# close it: skip trivial/blank added lines when RECORDING, and require the content to
# occur exactly ONCE in the file when MATCHING.
is_trivial(){ # empty input is handled first: grep sees NO lines and would say "no"
  case "$1" in *[![:space:]]*) ;; *) echo yes; return ;; esac
  printf '%s\n' "$1" | grep -qE '^[[:space:]]*([}{]|fi|else|done|esac|then|do|;;)[[:space:]]*$' && echo yes || echo no; }
expect "blank line is trivial (not recordable)"      "$(is_trivial "")"          "yes"
expect "whitespace-only line is trivial"             "$(is_trivial "   ")"       "yes"
expect "'  fi' is trivial"                           "$(is_trivial "  fi")"      "yes"
expect "'}' is trivial"                              "$(is_trivial "}")"         "yes"
expect "a real code line is NOT trivial"             "$(is_trivial "  guard_x() { :; }")" "no"

# MATCHING must require uniqueness. Fixture: two identical '  fi' lines.
cat > "$T/src/dup.sh" <<'EOF'
a() {
  if x; then
    p
  fi
}
b() {
  if y; then
    q
  fi
}
EOF
occurrences(){ local c; c="$(sed -n "${2}p" "$1")"; grep -cxF -- "$c" "$1"; }
is_self_inflicted_unique(){ # $1=file $2=line $3=fixed_lines $4=relpath
  [ "$(occurrences "$1" "$2")" -ne 1 ] && { printf 'false'; return; }
  is_self_inflicted "$1" "$2" "$3" "$4"; }
H_FI="$(hash_line "$T/src/dup.sh" 4)"
DUP_FIXED="$(jq -cn --arg a "$H_FI" '[{path:"src/dup.sh",hashes:[$a]}]')"
expect "duplicate '  fi' lines DO hash identically (the hazard)" \
  "$([ "$(hash_line "$T/src/dup.sh" 4)" = "$(hash_line "$T/src/dup.sh" 9)" ] && echo yes || echo no)" "yes"
expect "naive content match false-positives on the OTHER fi (line 9)" \
  "$(is_self_inflicted "$T/src/dup.sh" 9 "$DUP_FIXED" "src/dup.sh")" "true"
expect "uniqueness rule rejects it (line 9)" \
  "$(is_self_inflicted_unique "$T/src/dup.sh" 9 "$DUP_FIXED" "src/dup.sh")" "false"
expect "uniqueness rule also rejects the original (line 4)" \
  "$(is_self_inflicted_unique "$T/src/dup.sh" 4 "$DUP_FIXED" "src/dup.sh")" "false"
# ...and a genuinely unique line still attributes correctly.
UNIQ="$(hash_line "$T/src/thing.sh" 5)"
U_FIXED="$(jq -cn --arg a "$UNIQ" '[{path:"src/thing.sh",hashes:[$a]}]')"
expect "unique fix-added line still attributes" \
  "$(is_self_inflicted_unique "$T/src/thing.sh" 5 "$U_FIXED" "src/thing.sh")" "true"

# ORACLE for: "the SECOND pass with self_inflicted: true -- not necessarily
# consecutive -- surfaces." Two-consecutive would be unfirable under a cap of 2.
surface_at(){ local i=0 c=0 v; for v in $1; do i=$((i+1)); [ "$v" = "true" ] && c=$((c+1))
    [ "$c" -ge 2 ] && { printf '%s' "$i"; return; }; done; printf 'none'; }
expect "2nd self_inflicted pass surfaces (consecutive)"     "$(surface_at "true true")"        "2"
expect "2nd self_inflicted pass surfaces (NON-consecutive)" "$(surface_at "true false true")"  "3"
expect "one self_inflicted pass alone does not surface"      "$(surface_at "true false false")" "none"
expect "  non-consecutive case is within the HEAVY cap" \
  "$([ "$(surface_at "true false true")" -le "$(lb_gate_b_cap heavy)" ] && echo yes || echo no)" "yes"

echo "================ Gate B: AC-gated reopen decision ================"

# ORACLE for Step 2: reopen iff (a) breaks an approved AC, (b) reachable:runtime
# regression/bypass, or (c) security/data-loss -- otherwise PARK whatever the
# label. Fail closed when ac: is missing/unparseable. park_non_blocking is
# evaluated FIRST and leaves only a literal `blocker` reopening.
reopen(){ # $1=finding json  $2=park_non_blocking(true|false)  $3=descoped ACs (json array, optional)
  # NOTE: `.ac` is bound to $a FIRST. Writing `$descoped | index(.ac)` rebinds `.`
  # to $descoped inside the pipe, so `.ac` there indexes the ARRAY with a string and
  # jq aborts ("Cannot index array with string") -- which surfaced as an empty
  # result, i.e. a silently broken oracle rather than a loud failure.
  printf '%s' "$1" | jq -r --arg park "$2" --argjson descoped "${3:-[]}" '
    (.ac) as $a |
    # park_non_blocking parks non-blockers, but NEVER an AC breach (condition (a)):
    # Gate A does not re-run, and the Phase-5 completion check reads only requirement
    # STATUS, so a parked breach would ship with all_complete still true.
    # NOTE: no apostrophes in this comment -- it sits INSIDE a single-quoted jq
    # program, where one would terminate the string (a bug this repo has hit before).
    # The carve-out is the FULL Step-2 reopen test, not (a) alone: carving out only (a)
    # would leave (b) runtime regressions and (c) security paths routed by the severity
    # label, which is the basis this ladder rejects.
    if $park == "true" then
      (if .severity == "blocker" then "reopen"
       elif (($a | type) == "number" and (($descoped | index($a)) == null)) then "reopen"
       elif .reachable == "runtime" then "reopen"
       elif (.security // false) then "reopen"
       else "park" end)
    elif ($a | type) != "number" and ($a != "none") then "reopen"        # fail closed
    # (a) requires the row be an APPROVED criterion: a user-descoped row is no
    # longer a criterion of this run, so a finding against it must NOT reopen.
    # Gate A caught the oracle missing this; the spec has always required it.
    elif ($a | type) == "number" and (($descoped | index($a)) == null) then "reopen"
    elif .reachable == "runtime" then "reopen"                            # (b)
    elif (.security // false) then "reopen"                               # (c)
    else "park" end' ; }

f(){ jq -cn --argjson o "$1" '$o'; }
expect "(a) breaks AC 4, label required -> reopen" \
  "$(reopen "$(f '{"severity":"required","ac":4,"reachable":"spec-only"}')" false)" "reopen"
expect "(b) runtime-reachable, ac none -> reopen" \
  "$(reopen "$(f '{"severity":"required","ac":"none","reachable":"runtime"}')" false)" "reopen"
expect "(c) security path, ac none, not runtime -> reopen" \
  "$(reopen "$(f '{"severity":"required","ac":"none","reachable":"spec-only","security":true}')" false)" "reopen"
# The measured failure mode: a README-wording finding self-labelled `required`
# reopened the whole loop. It must now park.
expect "docs-only 'required' (README wording) -> PARK" \
  "$(reopen "$(f '{"severity":"required","ac":"none","reachable":"docs-only"}')" false)" "park"
expect "spec-only 'blocker' with no AC -> PARK despite label" \
  "$(reopen "$(f '{"severity":"blocker","ac":"none","reachable":"spec-only"}')" false)" "park"
# Fail closed: a missing or unparseable ac: is read as AC-breaking. The safe
# direction is extra work, never parking a possible real breach.
expect "fail closed: ac: absent -> reopen" \
  "$(reopen "$(f '{"severity":"required","reachable":"docs-only"}')" false)" "reopen"
expect "fail closed: ac: unparseable -> reopen" \
  "$(reopen "$(f '{"severity":"required","ac":"probably #3?","reachable":"docs-only"}')" false)" "reopen"
# park_non_blocking precedence: it MUST beat the fail-closed default, or a missing
# ac: would force every finding AC-breaking and defeat the flag entirely.
expect "park_non_blocking beats fail-closed (ac: absent)" \
  "$(reopen "$(f '{"severity":"required","reachable":"docs-only"}')" true)" "park"
# Round-1 wrote this asserting `park`; review round 2 established that parking a
# runtime-reachable finding routes (b) by severity label, which the ladder rejects.
expect "park_non_blocking does NOT park a runtime 'required'" \
  "$(reopen "$(f '{"severity":"required","ac":"none","reachable":"runtime"}')" true)" "reopen"
expect "park_non_blocking still reopens a literal blocker" \
  "$(reopen "$(f '{"severity":"blocker","ac":"none","reachable":"runtime"}')" true)" "reopen"
# CODE-REVIEW FINDING (Required): the flag must not park a breach of an approved AC.
expect "park_non_blocking does NOT park an AC-breaking required" \
  "$(reopen "$(f '{"severity":"required","ac":7,"reachable":"runtime"}')" true)" "reopen"
expect "park_non_blocking does NOT park an AC breach even if docs-only" \
  "$(reopen "$(f '{"severity":"required","ac":7,"reachable":"docs-only"}')" true)" "reopen"
expect "park_non_blocking DOES park a descoped-row finding (a no longer applies)" \
  "$(reopen "$(f '{"severity":"required","ac":7,"reachable":"docs-only"}')" true '[7]')" "park"
# REVIEW ROUND 2: (b) and (c) must be carved out too, symmetrically with convergence.
expect "park_non_blocking does NOT park a runtime regression (b)" \
  "$(reopen "$(f '{"severity":"required","ac":"none","reachable":"runtime"}')" true)" "reopen"
expect "park_non_blocking does NOT park a security path (c)" \
  "$(reopen "$(f '{"severity":"required","ac":"none","reachable":"spec-only","security":true}')" true)" "reopen"
expect "park_non_blocking still parks a docs-only required" \
  "$(reopen "$(f '{"severity":"required","ac":"none","reachable":"docs-only"}')" true)" "park"
# A user-descoped AC is no longer a criterion of the run, so (a) must not fire on
# it. Gate A found the oracle treating ANY numeric ac: as (a) while the spec says
# "a row ... that is not user-descoped" -- untested until now.
expect "descoped AC row, docs-only -> PARK (not an approved criterion)" \
  "$(reopen "$(f '{"severity":"required","ac":5,"reachable":"docs-only"}')" false '[5]')" "park"
expect "non-descoped AC row still reopens"  "$(reopen "$(f '{"severity":"required","ac":4,"reachable":"docs-only"}')" false '[5]')" "reopen"
expect "descoped row but runtime-reachable -> reopen via (b)" \
  "$(reopen "$(f '{"severity":"required","ac":5,"reachable":"runtime"}')" false '[5]')" "reopen"

echo "================ Gate B: pass accounting + post-surface grants ================"

# ORACLE for Step 0: count passes for THIS scope, add the user's granted extra,
# compare against the scope's own cap. Absent passes[] counts as 0 so a run that
# predates these fields is never blocked.
remaining(){ # $1=state json  $2=scope  $3=tier
  # allowance_acked is an OBJECT KEYED BY SCOPE. A bare integer would be added to
  # whichever scope is being evaluated, so one grant at the main-loop surface would
  # raise every re-gate site's allowance too -- four grants the user never gave.
  printf '%s' "$1" | jq -r --arg s "$2" --arg t "$3" \
    --argjson mc "$(lb_gate_b_cap "$3")" --argjson rc "$(lb_gate_b_regate_cap)" '
    ((.gates.gate_b.passes // []) | map(select(.scope == $s)) | length) as $used
    | (((.gates.gate_b.allowance_acked // {})[$s]) // 0) as $ack
    | (if $s == "main" then $mc else $rc end) as $cap
    | ($cap + $ack - $used)'; }

AT_CAP='{"gates":{"gate_b":{"passes":[{"scope":"main"},{"scope":"main"},{"scope":"main"}]}}}'
expect "HEAVY main loop at 3 passes -> 0 remaining"  "$(remaining "$AT_CAP" main heavy)" "0"
# THE DEADLOCK CASE: main loop exhausted, but every re-gate must still have its
# own allowance or the handover commit can never be earned.
for sc in regate:docs regate:merge regate:bot-fix regate:release; do
  expect "at main cap, $sc still has 2" "$(remaining "$AT_CAP" "$sc" heavy)" "2"
done
# ...and the re-gate allowance must not move as the main count grows.
for n in 0 2 3 99; do
  st="$(jq -cn --argjson n "$n" '{gates:{gate_b:{passes:[range($n)|{scope:"main"}]}}}')"
  expect "regate allowance invariant at main=$n" "$(remaining "$st" regate:docs heavy)" "2"
done
expect "legacy run: absent passes[] counts as 0" \
  "$(remaining '{"gates":{"gate_b":{}}}' main heavy)" "3"
expect "legacy run: absent gates entirely" "$(remaining '{}' main heavy)" "3"

# The three post-surface grants must each yield exactly ONE defined continuation.
# None may resolve to "surface again", or nothing has been bounded.
grant(){ printf '%s' "$1" | jq -r '
  if (.gates.gate_b.skipped_reason // null) != null then "gate-passes-descoped"
  elif (.gates.loop_budget.park_non_blocking // false) then "park-and-advance"
  elif (((.gates.gate_b.allowance_acked // {}) | to_entries | map(.value) | add // 0) > 0) then "another-pass-permitted"
  else "surface" end'; }
expect "grant (i) +1 pass -> another pass permitted" \
  "$(grant '{"gates":{"gate_b":{"allowance_acked":{"main":1}}}}')" "another-pass-permitted"
ACK_MAIN='{"gates":{"gate_b":{"allowance_acked":{"main":1},"passes":[{"scope":"main"},{"scope":"main"},{"scope":"main"}]}}}'
expect "grant (i) raises remaining above 0"  "$(remaining "$ACK_MAIN" main heavy)" "1"
# GATE-A FINDING: allowance_acked was specified per-scope in prose but typed as a
# bare integer, so a scalar grant leaked into EVERY other scope. A +1 at the
# main-loop surface must not hand the four re-gate sites a third pass each.
for sc in regate:docs regate:merge regate:bot-fix regate:release; do
  expect "grant at main does NOT leak into $sc" "$(remaining "$ACK_MAIN" "$sc" heavy)" "2"
done
expect "a grant at regate:docs raises only that scope" \
  "$(remaining '{"gates":{"gate_b":{"allowance_acked":{"regate:docs":1}}}}' regate:docs heavy)" "3"
expect "  ...and leaves main untouched" \
  "$(remaining '{"gates":{"gate_b":{"allowance_acked":{"regate:docs":1}}}}' main heavy)" "3"
expect "absent allowance_acked key counts as 0" \
  "$(remaining '{"gates":{"gate_b":{"allowance_acked":{}}}}' main heavy)" "3"
expect "grant (ii) park_non_blocking -> park and advance" \
  "$(grant '{"gates":{"loop_budget":{"park_non_blocking":true}}}')" "park-and-advance"
# GATE-B ROUND-1 FINDING (Blocker): the grant (ii) oracle took NO finding input, so it
# resolved to park-and-advance whether or not an (a)/(b)/(c) finding was live -- exactly
# the hole the spec fix closes. The grant covers a finding only when the carve-out lets
# it: an AC breach, a runtime-reachable regression or a security path still needs a fix
# or grant (iii), on the current table as much as on a later pass.
covered(){ printf '%s' "$1" | jq -r '
  if (.ac // "none") != "none" then "not-covered-ac"
  elif (.reachable // "") == "runtime" then "not-covered-runtime"
  elif (.security // false) then "not-covered-security"
  else "parked" end'; }
expect "grant (ii) parks a docs-only required finding" \
  "$(covered '{"severity":"required","ac":"none","reachable":"docs-only"}')" "parked"
expect "grant (ii) does NOT cover a live AC breach" \
  "$(covered '{"severity":"required","ac":7,"reachable":"spec-only"}')" "not-covered-ac"
expect "grant (ii) does NOT cover a runtime-reachable regression" \
  "$(covered '{"severity":"required","ac":"none","reachable":"runtime"}')" "not-covered-runtime"
expect "grant (ii) does NOT cover a security/data-loss path" \
  "$(covered '{"severity":"follow-up","ac":"none","reachable":"spec-only","security":true}')" "not-covered-security"
expect "grant (iii) skipped_reason -> gate passes on descope" \
  "$(grant '{"gates":{"gate_b":{"skipped_reason":"user-descope-at-cap"}}}')" "gate-passes-descoped"
expect "no grant recorded -> surface (the pre-answer state)" "$(grant '{}')" "surface"

echo "================ Gate B: the oracles mirror the shipped spec ================"

# Each oracle above encodes a rule that lives in prose. These assertions bind the
# two together, so an oracle cannot keep passing after the rule it mirrors is
# changed or deleted. (Full prose assertions live in enforcement-spine.test.sh.)
has(){ grep -qF "$2" "$1" && echo yes || echo no; }
expect "spec: cap read from lb_gate_b_cap"        "$(has "$GATES" 'lb_gate_b_cap')"            "yes"
expect "spec: re-gate allowance helper named"     "$(has "$GATES" 'lb_gate_b_regate_cap')"     "yes"
expect "spec: budget checked at entry"            "$(has "$GATES" 'lb_effective_budget')"      "yes"
expect "spec: fail-closed on a missing ac:"       "$(has "$GATES" 'Fail closed on a missing fact')" "yes"
expect "spec: content-hash, not line numbers"     "$(has "$GATES" 'Hash the content; never store line numbers')" "yes"
expect "spec: second (not consecutive) self_inflicted pass" \
  "$(has "$GATES" 'The second pass with `self_inflicted: true` — not necessarily consecutive — surfaces')" "yes"
expect "spec: convergence on non-decrease"        "$(has "$GATES" 'it did not DECREASE')"      "yes"
expect "spec: park_non_blocking precedence"       "$(has "$GATES" 'evaluated BEFORE Step 2')"  "yes"
expect "spec: allowance raises the cap, not the spent count" \
  "$(has "$GATES" 'A granted allowance raises the CAP; it never adds to the spent count')" "yes"
expect "spec: the boundary is snapshotted at pass start" \
  "$(has "$GATES" 'Snapshot the boundary when the pass STARTS')" "yes"
expect "spec: absent passes[] counts as 0"        "$(has "$GATES" 'An absent `passes[]` counts as 0')" "yes"
expect "spec: resume reads the grant"             "$(has "$GATES" 'do not re-surface the same check-in')" "yes"
# (a) must require an APPROVED row: a user-descoped row is not a criterion any more.
expect "spec: (a) requires a non-descoped row" \
  "$(has "$GATES" "names a row in PLAN.md's AC table that is not user-descoped")" "yes"

# GATE-A FINDING (AC 12): the declared "no hardcoded cap literal" check was never
# implemented, and run over the WHOLE Gate-B section it would fail on legitimate
# explanatory prose ("unreachable under a Gate B cap of 2"). The requirement is
# narrower and that is what is asserted here: the Step-0 CAP-LOOKUP items -- the
# text that tells the orchestrator where the numbers come from -- must contain no
# cap literal, so the numbers can only be obtained from the helper. Explanatory
# prose elsewhere may name a number; a lookup step may not.
lookup_block="$(awk '/^### Step 0 —/{f=1} f{print} f&&/^### Step 1 —/{exit}' "$GATES")"
expect "Step-0 cap lookup names the helper"   "$(printf '%s' "$lookup_block" | grep -c 'lb_gate_b_cap <tier>' | tr -d ' ')" "1"
expect "Step-0 cap lookup names the regate helper" "$(printf '%s' "$lookup_block" | grep -c 'lb_gate_b_regate_cap' | tr -d ' ')" "1"
# The lookup items must not restate a cap value. Scoped to the two sentences that
# resolve the cap, so a future edit cannot paste "2" / "3" in place of the call.
expect "cap-lookup item states the ban"        "$(printf '%s' "$lookup_block" | grep -c '\*\*Never hardcode the numbers here\*\*' | tr -d ' ')" "1"
# GATE-A ROUND-2 FINDING: the earlier version anchored on the literal phrase "Read
# the applicable cap", so renaming that phrase disarmed the check silently -- Gate A
# pasted cap literals into the lookup item after retitling it and nothing failed.
# Anchor-free replacement: check the ENTIRE Step-0 block, which is number-free by
# design because every value there comes from a helper. Markdown ordered-list
# markers are stripped first (the item's own "2." is not a cap literal), and inline
# code spans are stripped so a helper name or a JSON key can never trip it.
# GATE-A ROUND-3 FINDING: an earlier version also stripped inline code spans, on the
# theory that a helper name or JSON key is never a cap literal. That opened the exact
# hole it was meant to close -- Gate A pasted "the values are `2` (STANDARD) and `3`
# (HEAVY)" into this very item and nothing reddened, because backticks are the repo's
# dominant style FOR values. The strip is gone: Gate A confirmed no code span in
# Step 0 contains a digit, so it was protecting nothing and admitting everything.
# Stripped now, and only: markdown ordered-list markers, and Phase-/Step-/Gate-
# references ("Phase-4" would otherwise match \b4\b for a reason unrelated to caps).
step0_prose="$(printf '%s' "$lookup_block" \
  | sed 's/^[[:space:]]*[0-9]*\.[[:space:]]//' \
  | sed -E 's/([Pp]hase|[Ss]tep|[Gg]ate)[- ][0-9]+//g')"
expect "Step-0 block carries no cap literal anywhere" \
  "$(printf '%s' "$step0_prose" | grep -cE '\b(2|3|4|6)\b' | tr -d ' ')" "0"
# Proof the check discriminates: injecting a literal into the block must trip it.
expect "  ...and it trips when a literal is injected" \
  "$(printf '%s\n%s' "$step0_prose" 'cap them at 2 for STANDARD and 3 for HEAVY' | grep -cE '\b(2|3|4|6)\b' | tr -d ' ')" "1"
# Gate A round-3's defeater: the same literal in BACKTICKS, the repo's dominant style
# for values. It must trip the check too, or the ban is style-dependent.
expect "  ...and it trips on a backticked literal (round-3 defeater)" \
  "$(printf '%s\n%s' "$step0_prose" 'For reference the values are `2` (STANDARD) and `3` (HEAVY).' | grep -cE '\b(2|3|4|6)\b' | tr -d ' ')" "1"
# And the entry budget check must resolve the budget through the helper, not restate it.
expect "entry budget check names the helper"  "$(printf '%s' "$lookup_block" | grep -c 'lb_effective_budget <cap> <acked_through>' | tr -d ' ')" "1"

echo "================ Phase 4: the graded round contract ================"
# WHY THIS GROUP LIVES IN THIS SUITE. Bounding Gate B did not bound the run -- the
# churn moved one phase upstream. Measured: `iteration.review` reached 9 and 5 against
# a STANDARD cap of 4, while the nine-round run's `gate_b.passes[]` holds exactly two
# rows, both `reopened: 0`. So every one of those rounds was a Phase-4 round, and the
# Phase-4 contract is the sibling of the Gate B ladder above, sharing its reopen test
# by reference. Keeping both in one suite is deliberate: a separate file would let the
# two drift apart, which is the failure the shared test exists to prevent.
SPINE="$ROOT/skills/auto-task/SKILL.md"
[ -f "$SPINE" ] || { echo "FAIL: $SPINE missing"; exit 1; }
P4="$(awk '/^## phase-4-round-mechanics/,/^## fix-loop-budget-mechanics/' "$GATES")"

# The section must exist at all. Everything below reads from it, so a zero-length
# extract would make every later grep vacuously "0" rather than failing loudly.
expect "P4: the section exists in the reference" \
  "$([ -n "$P4" ] && echo yes || echo no)" "yes"

# --- Step A: grading, by the SAME test Gate B applies ----------------------------
# All three clauses must be present, and the fail-closed default with them: a finding
# whose `ac:` cannot be read is the one case where guessing wrong ships a real breach.
expect "P4: reopen clause (a) AC breach" \
  "$(printf '%s' "$P4" | grep -c 'breaks an approved Acceptance Criterion' | tr -d ' ')" "1"
expect "P4: reopen clause (b) runtime-reachable" \
  "$(printf '%s' "$P4" | grep -c 'runtime-reachable regression or bypass' | tr -d ' ')" "1"
expect "P4: reopen clause (c) security/data-loss" \
  "$(printf '%s' "$P4" | grep -c 'security or data-loss path' | tr -d ' ')" "1"
# GATE A round-1 finding (residual B): the fail-closed rule keyed on a literal `ac:`
# field copied from Gate B, where the VERIFIER PROMPT mandates it. auto-task-code-review
# emits no such field, so read literally EVERY Phase-4 finding failed closed, reopened
# the loop, and the deferral path was unreachable -- the contract was inert. Both halves
# of the correction are pinned: the orchestrator grades, and it fails closed on its own
# uncertainty. Dropping either one restores the inert reading.
expect "P4: the orchestrator grades, not the review skill" \
  "$(printf '%s' "$P4" | grep -c 'the review skill does not hand you a classification' | tr -d ' ')" "1"
expect "P4: names the missing ac:/reachable: fields as the reason" \
  "$(printf '%s' "$P4" | grep -c 'emits .file:line. plus a severity label and \*\*no such fields\*\*' | tr -d ' ')" "1"
expect "P4: grades from the AC table and the diff" \
  "$(printf '%s' "$P4" | grep -c "PLAN.md's Acceptance Criteria table" | tr -d ' ')" "1"
expect "P4: fail-closed on the orchestrator's own uncertainty" \
  "$(printf '%s' "$P4" | grep -c 'Fail closed on your own uncertainty' | tr -d ' ')" "1"
expect "P4: an unplaceable finding counts as AC-breaking" \
  "$(printf '%s' "$P4" | grep -c 'treat it as AC-breaking and reopen' | tr -d ' ')" "1"
# GATE A round-1 finding (residual A): the batch round's own non-reopening findings park,
# which is safe ONLY because Gate B re-applies the identical test. That is now true at
# EVERY tier -- LIGHT runs Gate B at one pass, so the park is re-graded rather than final,
# and the residual this comment used to describe is closed. A LIGHT-only hold was built for
# it once and REMOVED; the closure deletes the special case instead of restoring the hold.
# See the closure paragraph in the reference.
expect "P4: the rule covers every round after the batch, not just that round" \
  "$(printf '%s' "$P4" | grep -c 'ONE rule covering every round after the batch' | tr -d ' ')" "1"
# GATE-A ROUND-2 FINDING (runtime-reachable): the LIGHT exception was scoped to a finding
# "first raised in the batch round", but rounds continue AFTER the batch -- the batch
# pass's reopening findings re-enter Step A, so a later round can raise a fresh
# non-reopening blocker/required with no batch left to fix it in. On LIGHT that was
# neither fixed nor surfaced and the gate passed over it: residual A displaced by one
# round. The rule must NOT be batch-round-scoped, and this pins that it is not.
expect "P4: the post-batch rule is not scoped to the batch round" \
  "$(printf '%s' "$P4" | grep -c 'deliberately \*\*not\*\* scoped to the batch round' | tr -d ' ')" "1"
expect "P4: names the later-round trigger explicitly" \
  "$(printf '%s' "$P4" | grep -c 'a \*later\* round can raise a fresh non-reopening' | tr -d ' ')" "1"
expect "P4: the batch-lands-before-the-gate claim is scoped, not absolute" \
  "$(printf '%s' "$P4" | grep -c 'because the unqualified claim is false' | tr -d ' ')" "1"
# It must apply Gate B's test BY REFERENCE, not restate it. A second copy would drift,
# and the whole point of siding this contract with Gate B's is that it cannot.
expect "P4: applies the Gate B test by reference" \
  "$(printf '%s' "$P4" | grep -c 'Step-2 reopen test verbatim' | tr -d ' ')" "1"

# --- Step B: the deferred batch, and its once-per-run bound ----------------------
# Deferral is NOT Gate B's park. The distinction is the user's explicit choice: a wrong
# README figure still gets fixed, it just does not buy a full review cycle.
expect "P4: deferred is not parked" \
  "$(printf '%s' "$P4" | grep -c 'not parked and not round-triggering' | tr -d ' ')" "1"
expect "P4: the whole set is fixed in ONE batch" \
  "$(printf '%s' "$P4" | grep -c 'in ONE fix step' | tr -d ' ')" "1"
expect "P4: the batch is spent once per run" \
  "$(printf '%s' "$P4" | grep -c 'spent once per run and never renews' | tr -d ' ')" "1"
# The spent-marker must be the RECORD, not a parallel boolean that could disagree with
# it -- the same reasoning that made gate_b's allowance an object keyed by scope.
expect "P4: spent-marker is a batch:true row, not a boolean" \
  "$(printf '%s' "$P4" | grep -c 'existence of a .rounds\[\]. row with .batch: true' | tr -d ' ')" "1"
# A batch that could renew is the same unbounded loop in a smaller room.
expect "P4: a post-batch non-reopening finding earns no second batch" \
  "$(printf '%s' "$P4" | grep -c 'does not earn a second batch' | tr -d ' ')" "1"
# CODE-REVIEW ROUND-1 BLOCKER (B1). Two bullets two lines apart gave OPPOSITE answers for
# the batch pass's own non-reopening findings on LIGHT: one said "park in state.followups"
# with no tier qualifier, the next said park on STANDARD/HEAVY and SURFACE on LIGHT. The
# batch pass IS a round after the batch is spent, so both governed it -- and the losing
# reading is precisely the gate passing over a blocker/required nobody re-checked. Four
# Gate A rounds and the cross-file group all missed it because it is INTRA-file: every
# guard compared files, never two statements inside one. Collapsed to ONE rule; this pins
# that the unqualified park sentence does not return.
expect "P4: the unqualified park sentence is GONE" \
  "$(printf '%s' "$P4" | grep -c 'findings \*\*park in `state.followups`\*\*, because the batch has been spent' | tr -d ' ')" "0"
expect "P4: the park rule is stated exactly ONCE, and it is park-at-every-tier" \
  "$(printf '%s' "$P4" | grep -c 'parks in `state.followups` at every tier' | tr -d ' ')" "1"
# The batch must land BEFORE the gate passes, or deferral would mean "ships unfixed".
# This is also what keeps LIGHT (no Gate B) honest, so both are pinned.
expect "P4: the batch lands before the gate passes" \
  "$(printf '%s' "$P4" | grep -c 'BEFORE the gate passes, at every tier' | tr -d ' ')" "1"
expect "P4: LIGHT tier addressed explicitly" \
  "$(printf '%s' "$P4" | grep -c 'at every tier, LIGHT included' | tr -d ' ')" "1"

# --- Step C: the record, and the convergence basis -------------------------------
# Recording on EVERY exit is load-bearing for the same reason it is at Gate B: an
# absent array counts as zero rows, so a round that resolves without recording
# silently disarms the test on the very path it exists to bound.
expect "P4: record on every exit, reopen included" \
  "$(printf '%s' "$P4" | grep -c 'on EVERY exit, reopen included' | tr -d ' ')" "1"
expect "P4: the rounds[] row names every field" \
  "$(printf '%s' "$P4" | grep -c 'n, blockers, required, reopened, deferred, followups, batch, via, diff_sha, at' | tr -d ' ')" "1"
# GATE-A FINDING (AC #12). `via` was named ONCE, in Step 0's inline-fallback rung, and in
# none of the three places that define the row -- so an orchestrator following the row
# definition verbatim drops it. That matters because Step 0's ladder can turn a run inline
# MID-RUN (a twice-failed spawn, or a detected edit, which also disables the agent for the
# rest of the run), leaving a run that reports review_in_subagent: true while most of its
# rounds were self-reviewed -- and silently contaminating the review_rounds telemetry this
# change added to measure exactly that. All three definitions now carry it.
expect "P4: via records WHERE the round's review ran" \
  "$(printf '%s' "$P4" | grep -c 'where this round.s review actually ran' | tr -d ' ')" "1"
expect "P4: ...written on EVERY row, not only a degraded one" \
  "$(printf '%s' "$P4" | grep -c 'Write it on every row, not only on a degraded one' | tr -d ' ')" "1"
expect "P4: ...and an absent via is unknown, never subagent" \
  "$(printf '%s' "$P4" | grep -c 'reads as unknown, never as .subagent.' | tr -d ' ')" "1"
# CODE-REVIEW ROUND-1 FINDING (required). The enum was `subagent` / `inline` ("the
# review_in_subagent: false configuration") / `inline-fallback` ("a Step-0 degradation"),
# and those three did not cover the case the field was ADDED for: every round after the
# sha-moved rung sets subagent_disabled. Those rounds have the setting on, ran inline, and
# carry no degradation event of their own -- so they matched no value, in the majority-of-
# rounds scenario. `inline` now covers both routes to the main loop, which makes the enum
# total; pin the totality claim and the second route explicitly, since a future edit that
# re-narrows `inline` to the setting would silently reopen the hole.
expect "P4: the via enum is declared TOTAL over Step-0 paths" \
  "$(printf '%s' "$P4" | grep -c 'total over every path Step 0 can take' | tr -d ' ')" "1"
expect "P4: ...and inline covers the subagent_disabled route" \
  "$(printf '%s' "$P4" | grep -c 'it is on but `gates.code_review.subagent_disabled` is `true`' | tr -d ' ')" "1"
expect "P4: ...inline-fallback is the degradation round ITSELF" \
  "$(printf '%s' "$P4" | grep -c 'the degradation round \*itself\*' | tr -d ' ')" "1"
expect "P4: the schema mirrors the totality claim" \
  "$(grep -c 'The three values are \*\*total\*\*' "$ROOT/skills/auto-task/references/state-schema.md" | tr -d ' ')" "1"
# GATE-B PASS-1 FINDING (required). The justification added alongside the `via` fix
# claimed that omitting the field "silently contaminates the review_rounds telemetry".
# False in both directions: review_rounds is `rounds[] | length`, and no derivation reads
# `via` at all -- `grep -n '\bvia\b'` over the three hooks returns nothing. Pin the
# CORRECTED claim plus the real limit it replaced the false one with, and pin the
# negative control on the hooks so the prose cannot drift back into asserting a wiring
# that does not exist. This is the repo's own "verify prose against code" lesson: the
# suite pinned the sentence's wording without ever checking its truth.
expect "P4: via is scoped to STATE.json, and says so" \
  "$(printf '%s' "$P4" | grep -c 'It lives in `STATE.json` and \*\*nowhere else\*\*' | tr -d ' ')" "1"
expect "P4: ...and the retired false telemetry claim is gone" \
  "$(printf '%s' "$P4" | grep -c 'silently contaminates the .review_rounds. telemetry' | tr -d ' ')" "0"
expect "P4: ...replaced by the real limit (same count either way)" \
  "$(printf '%s' "$P4" | grep -c 'reports the same `review_rounds: 6` as a fully independent run' | tr -d ' ')" "1"
# Match a FIELD ACCESS (`.via`, `"via"`, `via:`), never the English preposition -- all
# three hooks use "via" in prose comments, so a bare word match reports 10 and proves
# nothing. If a derivation ever starts reading the field, this trips and the prose above
# has to be rewritten to match the wiring rather than the other way round.
expect "P4: NEGATIVE CONTROL — no hook derivation reads the via FIELD" \
  "$(grep -hoE '\.via\b|"via"|(^|[[:space:]])via:' "$ROOT/hooks/record-outcome.sh" "$ROOT/hooks/send-telemetry.sh" \
      "$ROOT/hooks/auto-task-stats.sh" 2>/dev/null | wc -l | tr -d ' ')" "0"
# CONTROL for that control: the pattern must actually match a real field read.
expect "P4: ...and that pattern does match a real field read" \
  "$(printf '      review_via: (.gates.code_review.rounds[0].via),\n' | grep -coE '\.via\b|"via"|(^|[[:space:]])via:' | tr -d ' ')" "1"
# GATE-B PASS-1 FINDING (follow-up, fixed in the same pass because it is the same
# paragraph). The sha-moved rung asserted the inline re-review "re-pins
# reviewed_diff_sha" -- false whenever that re-review reopens, since the field is written
# only on a clean round. No gate hole (the hook keeps blocking), but the rung's stated
# safety argument did not hold on the common post-incident path.
expect "P4: the sha-moved rung no longer claims to re-pin" \
  "$(printf '%s' "$P4" | grep -c 'inline re-review re-pins `reviewed_diff_sha`' | tr -d ' ')" "0"
expect "P4: ...and credits the hook instead, naming the reopen case" \
  "$(printf '%s' "$P4" | grep -c 'if the inline re-review reopens, nothing re-pins it' | tr -d ' ')" "1"
for f in "$ROOT/skills/auto-task/SKILL.md" "$ROOT/skills/auto-task/references/state-schema.md"; do
  expect "P4: $(basename "$f") row definition includes via" \
    "$(grep -c 'batch, via, diff_sha, at' "$f" | tr -d ' ')" "1"
done
# The disable must survive a RESUME, which means it lives in state rather than in the
# orchestrator's head: a resumed run re-reads review_in_subagent: true and would otherwise
# re-enable the agent that edited the tree mid-review.
expect "P4: subagent_disabled is recorded in state" \
  "$(grep -c 'subagent_disabled' "$ROOT/skills/auto-task/references/state-schema.md" | tr -d ' ')" "1"
expect "P4: ...and is in the state skeleton" \
  "$(grep -c '"subagent_disabled": false' "$ROOT/skills/auto-task/SKILL.md" | tr -d ' ')" "1"
expect "P4: ...absent counts as false (no migration)" \
  "$(grep -c 'Absent counts as .false., so no existing run changes shape' "$ROOT/skills/auto-task/references/state-schema.md" | tr -d ' ')" "1"
# GATE-A ROUND-2 FINDING. The three assertions above pin the WRITE only, and a flag that
# is written but never consulted closes nothing: the spawn decision lived at one line that
# named the setting and nothing else, so a RESUMED orchestrator re-read
# `review_in_subagent: true` and re-spawned the agent the flag exists to keep out. Pin the
# READ at its decision point, and pin that the resume reason is stated -- otherwise a
# future edit can drop the condition and leave three green write-side assertions behind.
expect "P4: the spawn decision READS subagent_disabled" \
  "$(printf '%s' "$P4" | grep -c 'gates.code_review.subagent_disabled` is not `true`' | tr -d ' ')" "1"
expect "P4: ...naming the resume as the reason it must be state" \
  "$(printf '%s' "$P4" | grep -c 'a resumed orchestrator that consulted only the setting' | tr -d ' ')" "1"
expect "P4: ...and the schema says the flag is read, not just written" \
  "$(grep -c "Step 0's spawn decision READS this flag" "$ROOT/skills/auto-task/references/state-schema.md" | tr -d ' ')" "1"
# ATTRIBUTION, not merely presence. Inserting the subagent_disabled bullet mid-run of the
# rounds[] field definitions moved five of them under a boolean's bullet -- byte-identical
# text, so spec-inventory's conservation check reported missing=0 restated=0 while the
# reference had stopped defining `n`, `reopened`, `blockers`, `required` and `batch` as
# fields of the row. Words surviving is not the same as the right bullet owning them.
RB="$(awk '/^- \*\*`rounds\[\]`\*\*/,/^- \*\*`subagent_disabled`\*\*/' "$ROOT/skills/auto-task/references/state-schema.md")"
for fld in 'n` is `1 +` the prior row count' 'reopened` is the count of findings' \
           'blockers`/`required` are the raw label counts' 'deferred` is the count this round added' \
           'batch: true` marks the single round'; do
  expect "P4: rounds[] bullet still defines ${fld%%\`*}${fld#*\`}" \
    "$(printf '%s' "$RB" | grep -cF "$fld" | tr -d ' ')" "1"
done
expect "P4: absent rounds[] counts as zero rows" \
  "$(printf '%s' "$P4" | grep -c 'absent or empty .rounds\[\]. counts as zero rows' | tr -d ' ')" "1"
# The basis must be `reopened`, NEVER the label counts -- a deferred blocker cost no
# round, so counting it would let a run that deferred everything look like churn.
expect "P4: reopened is the declared convergence basis" \
  "$(printf '%s' "$P4" | grep -c 'declared convergence basis' | tr -d ' ')" "1"
expect "P4: never the label counts" \
  "$(printf '%s' "$P4" | grep -c 'Never .blockers./.required.' | tr -d ' ')" "1"
expect "P4: one non-decreasing round fires it" \
  "$(printf '%s' "$P4" | grep -c 'One round is enough to fire' | tr -d ' ')" "1"
expect "P4: a fired test surfaces, never advances" \
  "$(printf '%s' "$P4" | grep -c 'surfacing is the only outcome this test has' | tr -d ' ')" "1"
# The deferred entry -- and the missing entry-time cap -- must both be reasoned, not
# silently absent. An unexplained omission is indistinguishable from an oversight.
expect "P4: the absent entry-time cap is argued, not omitted" \
  "$(printf '%s' "$P4" | grep -c 'Why no separate entry-time pass cap' | tr -d ' ')" "1"
expect "P4: minimal-fix rule stated" \
  "$(printf '%s' "$P4" | grep -c '\*\*Minimal fix\.\*\*' | tr -d ' ')" "1"

# --- The spine must carry the non-negotiables AND point at the contract ----------
# Same mitigation Gate B relies on: the reference holds the ladder, the spine restates
# what a model must not get wrong even if the reference was never read.
expect "P4 spine: cites phase-3-gates for the round mechanics" \
  "$(grep -c 'phase-3-gates.md` ("phase-4-round-mechanics")' "$SPINE" | tr -d ' ')" "1"
expect "P4 spine: non-negotiable — the three-clause test" \
  "$(grep -c 'A finding costs a round only if it (a) breaks an approved AC' "$SPINE" | tr -d ' ')" "1"
expect "P4 spine: non-negotiable — deferred, not parked" \
  "$(grep -c 'is DEFERRED to `gates.code_review.deferred\[\]`' "$SPINE" | tr -d ' ')" "1"
expect "P4 spine: non-negotiable — record every round" \
  "$(grep -c 'Record the round on EVERY exit, reopen included' "$SPINE" | tr -d ' ')" "1"
expect "P4 spine: non-negotiable — minimal fix" \
  "$(grep -c '\*\*Minimal fix\.\*\* Correct the defect in place' "$SPINE" | tr -d ' ')" "1"
# NEGATIVE CONTROL. The whole change is that a label no longer decides the round. If
# the old unconditional sentence ever comes back -- a revert, a bad merge, a
# well-meaning restoration -- the grading is dead prose and this must go red.
expect "P4 spine: the unconditional label-driven step is GONE" \
  "$(grep -c 'If any Blocker or Required: apply the fix(es)' "$SPINE" | tr -d ' ')" "0"
expect "P4 spine: the label-driven exit condition is GONE" \
  "$(grep -c "latest pass produces only follow-ups" "$SPINE" | tr -d ' ')" "0"
# ...and the control discriminates: the sentence must be detectable when present.
expect "  ...and that control trips on the restored sentence" \
  "$(printf '3. If any Blocker or Required: apply the fix(es), re-run x\n' | grep -c 'If any Blocker or Required: apply the fix(es)' | tr -d ' ')" "1"

# --- The record must be documented, and visible to the anti-stall fingerprint ----
SCHEMA="$ROOT/skills/auto-task/references/state-schema.md"
STALL="$ROOT/hooks/prevent-mid-protocol-stall.sh"
expect "P4: rounds[] documented in the state schema" \
  "$(grep -c '\*\*`rounds\[\]`\*\*' "$SCHEMA" | tr -d ' ')" "1"
expect "P4: deferred[] documented in the state schema" \
  "$(grep -c '\*\*`deferred\[\]`\*\*' "$SCHEMA" | tr -d ' ')" "1"
# A round that defers everything applies no fix, bumps no counter and leaves
# reviewed_diff_sha alone -- so without this field every signature component is
# constant and the round reads as a frozen turn-end. Same case the hook's own comment
# already documents for the poll counters and the budget ack.
expect "P4: rounds length is in the no-progress fingerprint" \
  "$(grep -c 'if type == \"array\" then length else 0 end' "$STALL" | tr -d ' ')" "1"
# CODE-REVIEW ROUND-1 BLOCKER (B2), reproduced before fixing: `// []` only replaces
# null/false, so a truthy non-array (`rounds: true`) reached `length`, which ERRORS on a
# boolean -- blanking the whole signature via `|| echo ""`. Two consecutive blanks compare
# EQUAL, so the frozen-turn counter incremented and the hook blocked a turn-end it should
# have released. It is the only field in that expression that can abort the expression, so
# the guard belongs exactly here. Asserted behaviourally, not just by grepping the source.
expect "P4: a non-array rounds does not abort the fingerprint" \
  "$(printf '{"gates":{"code_review":{"rounds":true}}}' | jq -r '(.gates.code_review.rounds | if type == "array" then length else 0 end)|tostring' 2>/dev/null || echo ABORTED)" "0"
expect "P4: ...and the pre-fix form DID abort (control)" \
  "$(printf '{"gates":{"code_review":{"rounds":true}}}' | jq -r '((.gates.code_review.rounds // []) | length)|tostring' 2>/dev/null || echo ABORTED)" "ABORTED"
expect "P4: an array rounds still yields its length" \
  "$(printf '{"gates":{"code_review":{"rounds":[1,2,3]}}}' | jq -r '(.gates.code_review.rounds | if type == "array" then length else 0 end)|tostring')" "3"
expect "P4: an absent rounds still reads zero" \
  "$(printf '{}' | jq -r '(.gates.code_review.rounds | if type == "array" then length else 0 end)|tostring')" "0"
# CODE-REVIEW ROUND-1 REQUIRED (R1): the spine's step 2 routed on `deferred[]` non-empty
# with NO spent guard, and nothing anywhere clears `deferred[]` -- the marker is the
# `batch: true` row precisely so it cannot be inferred from the array being empty. Read as
# written it re-batched forever, on every run that defers anything. Now guarded.
expect "P4 spine: step 2 guards the batch on unspent" \
  "$(grep -c 'non-empty \*\*and the batch is unspent\*\*' "$SPINE" | tr -d ' ')" "1"
expect "P4 spine: the unguarded re-batch route is GONE" \
  "$(grep -c 'zero reopening but `deferred\[\]` non-empty → apply the batch' "$SPINE" | tr -d ' ')" "0"
# It must read the LENGTH only. Inspecting contents, or judging magnitude, would make
# the anti-stall hook depend on findings data it has no business interpreting.
expect "P4: the fingerprint reads only the length" \
  "$(grep -c 'Only the LENGTH is read' "$STALL" | tr -d ' ')" "1"

echo "======== Phase 4: CROSS-FILE agreement (the guard that was missing) ========"
# WHY THIS GROUP EXISTS, AND WHY IT IS NOT MORE OF THE SAME. Gate A ran THREE rounds on
# this contract and every round found the previous round's fix incomplete -- not because
# the rule was wrong, but because the rule is stated in SIX places and each fix updated
# fewer than all six: the reference ladder, the spine's inline non-negotiables, the spine's
# loop-rule clause 5, the spine's loop exit conditions, ARCHITECTURE.md's flowchart, and
# ARCHITECTURE.md's Phases-at-a-glance row. Round 2's finding was round 1's fix scoped too
# narrowly; round 3's was round 2's fix applied to the reference but not the spine -- and
# the spine assertion added alongside it then pinned the STALE wording green.
#
# Every guard in this file and in enforcement-spine.test.sh is a per-file substring
# presence/absence check, so two files stating OPPOSITE rules both pass. That is the hole
# the three rounds fell through, and the same class that "cost an earlier run four review
# rounds when one marker grammar lived in three rules" (hooks/lib/loop-budget.sh header).
# These assertions compare the sites against EACH OTHER instead. They are cheap, and one
# of them fails on exactly the drift each Gate A round found by hand.
SPINEONLY="$SPINE"
ARCH="$ROOT/skills/auto-task/ARCHITECTURE.md"
[ -f "$ARCH" ] || { echo "FAIL: $ARCH missing"; exit 1; }

# All six sites must exist to be compared. A missing one silently vacuums the checks below.
expect "xfile: all six statement sites are present" \
  "$([ -n "$P4" ] && grep -q 'Non-negotiables restated inline' "$SPINEONLY" \
     && grep -q 'Returns have not diminished' "$SPINEONLY" \
     && grep -q 'The most recent `auto-task-code-review` round' "$SPINEONLY" \
     && grep -q 'P4Cls' "$ARCH" && grep -q '| 4 Code review |' "$ARCH" && echo yes || echo no)" "yes"

# (1) ROUND-3 FINDING A, mechanised. The reference declares the park/surface rule is NOT
# batch-round-scoped. If it says that, NO site may still scope it to the batch round.
# This is the assertion that would have caught the spine lagging the reference.
if printf '%s' "$P4" | grep -q 'deliberately \*\*not\*\* scoped to the batch round'; then
  expect "xfile: no site still scopes the LIGHT rule to the batch round" \
    "$(grep -l 'batch-round `blocker`' "$SPINEONLY" "$ARCH" 2>/dev/null | wc -l | tr -d ' ')" "0"
else
  expect "xfile: reference declares the rule unscoped" "absent" "present"
fi

# (2) ROUND-3 FINDING A, second half. The reference retracts the UNQUALIFIED claim that
# deferral never ships a defect unfixed. No site may still assert it without the scope.
expect "xfile: the unqualified never-ships-unfixed claim is gone everywhere" \
  "$(grep -c 'so deferral never ships a defect unfixed' "$SPINEONLY" "$ARCH" "$GATES" 2>/dev/null | grep -cv ':0$' | tr -d ' ')" "0"

# (3) ROUND-3 FINDING C. Clause 5's reopened-basis carve-out must cover BOTH graded loops.
# Scoped to "At Gate B" it licensed label counting at Phase 4 -- the exact misfire measured
# as 6,7,2,3,1,3 -- while the Phase-4 bullet 540 lines below said the opposite.
expect "xfile: clause 5 applies the reopened basis to both loops" \
  "$(grep -c 'In \*\*both\*\* graded loops — Phase 4 and Gate B — count only findings that \*\*reopened\*\*' "$SPINEONLY" | tr -d ' ')" "1"
expect "xfile: clause 5 no longer scopes it to Gate B alone" \
  "$(grep -c 'At Gate B, count only findings that \*\*reopened\*\*' "$SPINEONLY" | tr -d ' ')" "0"

# (4) ROUND-3 FINDING C, second half. The loop's own exit condition must state the graded
# test, not the label test it contradicted.
# Re-pinned at Gate B pass 2: this bullet no longer RESTATES the predicate (restating it at
# seven sites is what the state-once guard above now forbids) — it defers to the single
# statement. The graded-not-label property it was protecting is unchanged and still pinned:
# the deferral names Phase 4's exit conditions, whose one statement is graded, and the
# label-driven form is separately asserted absent two lines below.
expect "xfile: the loop exit condition is graded, not label-driven" \
  "$(grep -cF "round meets Phase 4's advance condition — the grade decides, not the label" "$SPINEONLY" | tr -d ' ')" "1"
expect "xfile: the label-driven loop exit is gone" \
  "$(grep -c 'produces only follow-ups (no blockers, no required fixes)' "$SPINEONLY" | tr -d ' ')" "0"

# (5) ROUND-3 FINDING B. Edge TARGETS and GUARDS, which no substring check covered. The
# deferral edge must NOT return to the review node -- that is another review pass, which
# "costs NO round" denies -- and the gate-pass edge must carry the `spent` qualifier or the
# diagram routes a spent batch back into a renewing one.
expect "xfile: the deferral edge does not trigger another review pass" \
  "$(grep -c '^ *P4Def --> P4$' "$ARCH" | tr -d ' ')" "0"
expect "xfile: the deferral edge returns to the decision node" \
  "$(grep -c 'P4Def --> P4Cls' "$ARCH" | tr -d ' ')" "1"
expect "xfile: the batch edge is guarded on NOT spent" \
  "$(grep -c 'deferred non-empty AND batch NOT spent' "$ARCH" | tr -d ' ')" "1"
expect "xfile: the gate-pass edge admits a spent batch" \
  "$(grep -c 'deferred empty OR batch spent' "$ARCH" | tr -d ' ')" "1"
# ...and the flowchart must carry the LIGHT duty the glance row and the spine both state,
# or the three sites disagree again in the direction that ships a finding unfixed.
expect "xfile: the flowchart states the park-at-every-tier rule" \
  "$(grep -c 'post-batch non-reopening blocker/required parks at every tier' "$ARCH" | tr -d ' ')" "1"

# (5b) CODE-REVIEW ROUND-2 BLOCKER (B3), and the guardrail that stops it needing a fourth
# round. The batch-ENTRY condition is stated at four sites and, before this group, was
# guarded at ZERO of them (`grep -c 'ZERO reopening findings and'` returned 0 in both test
# files) -- which is why round 1's fix reached SKILL.md and ARCHITECTURE.md but missed
# references/phase-3-gates.md, the file the spine's MANDATORY READ defers to as the
# contract. Nothing clears `deferred[]`; the spent-marker is deliberately the `batch: true`
# row so it cannot be inferred from the array being empty. So an entry test that omits the
# unspent condition re-fires on every later zero-reopening round, unbounded, on the normal
# path. Assert EVERY site carries the guard, and that no site states entry without it.
expect "xfile: the reference's batch-entry test carries the unspent guard" \
  "$(printf '%s' "$P4" | grep -c 'AND the batch is still unspent' | tr -d ' ')" "1"
expect "xfile: the unguarded reference entry test is GONE" \
  "$(printf '%s' "$P4" | grep -c 'ZERO reopening findings and `deferred\[\]` is non-empty\*\*, do not pass' | tr -d ' ')" "0"
expect "xfile: the spine's batch-entry test carries the unspent guard" \
  "$(grep -c 'is non-empty \*\*and the batch is unspent\*\*' "$SPINEONLY" | tr -d ' ')" "1"
expect "xfile: the flowchart's batch edge carries the unspent guard" \
  "$(grep -c 'deferred non-empty AND batch NOT spent' "$ARCH" | tr -d ' ')" "1"
expect "xfile: the state schema's batch-entry mention carries it too" \
  "$(grep -c 'zero reopening findings \*\*and the batch is still unspent\*\*' "$ROOT/skills/auto-task/references/state-schema.md" | tr -d ' ')" "1"
# The set form: every site that mentions applying the batch must also mention the spent
# condition within the same file. This is the shape that generalises beyond B3's wording --
# a future re-statement in different words still has to carry a spent qualifier somewhere.
for site_desc in "reference:$GATES" "spine:$SPINEONLY" "architecture:$ARCH" "schema:$ROOT/skills/auto-task/references/state-schema.md"; do
  sdesc="${site_desc%%:*}"; sfile="${site_desc#*:}"
  expect "xfile: $sdesc pairs batch entry with a spent condition" \
    "$(grep -ciE 'unspent|NOT spent|or spent|spent once per run' "$sfile" | tr -d ' ' | awk '{print ($1>0)?1:0}')" "1"
done

# (6) The invariants every site that states the rule must agree on, checked as a set rather
# than one file at a time. `reopened`-not-labels and batch-spent-once are the two the three
# Gate A rounds kept splitting on.
for site_desc in "reference:$GATES" "spine:$SPINEONLY" "architecture:$ARCH"; do
  sdesc="${site_desc%%:*}"; sfile="${site_desc#*:}"
  expect "xfile: $sdesc states the reopened basis, not label counts" \
    "$(grep -c 'reopening\|reopened' "$sfile" | tr -d ' ' | awk '{print ($1>0)?1:0}')" "1"
  expect "xfile: $sdesc states the batch is spent once" \
    "$(grep -ci 'spent once per run\|batch spent\|batch NOT spent\|or spent' "$sfile" | tr -d ' ' | awk '{print ($1>0)?1:0}')" "1"
done
# Proof the set-check discriminates rather than matching anything: a file that states
# neither must fail it. LICENSE is the control -- it mentions no loop rule at all.
expect "  ...and the set-check fails on a file stating neither" \
  "$(grep -c 'reopening\|reopened' "$ROOT/LICENSE" | tr -d ' ' | awk '{print ($1>0)?1:0}')" "0"

echo "===== Phase 4: the PROPERTY guard (what ends the enumeration treadmill) ====="
# CODE-REVIEW ROUND-3 BLOCKER (B1), and the reason this group is shaped differently from
# every other guard in this file. FOUR consecutive rounds -- Gate A round 3, review rounds
# 1, 2 and 3 -- each found the SAME class: a rule updated at fewer sites than state it.
# Every fix was correct and every guard added alongside it was a hand-maintained list of
# the sites known at that moment, so each round bought exactly one more enumeration and
# the next round found the site the list omitted. B1 was the seventh site (SKILL.md's
# always-loaded top-of-file NON-YIELDING CONTRACT) while the cross-file group above
# enumerates six.
#
# So this assertion does not name a site. It asserts the PROPERTY: no line in the spine
# may gate a Phase-4 advance on a LABEL count. Any line that mentions the review skill AND
# a label-based clean predicate fails it -- including a future rephrasing at a site nobody
# has thought of yet, which is precisely what the enumerations cannot do.
# TWO checks, because they fail on different things and neither alone is enough. Round 4
# measured the first attempt at this guard: it required a line to contain BOTH the literal
# string `auto-task-code-review` AND one of three hard-coded label phrases, and it caught
# 0 of 5 plausible rephrasings of the very bug it was written for. A phrase list is an
# enumeration of WORDINGS -- the same treadmill as an enumeration of sites, one level down.
#
# CHECK 1 is the actual invariant, and it is closed-form rather than open-ended: a line may
# not state a Phase-4 advance without naming BOTH halves of the exit predicate. It does not
# care what words gate the advance, so a future rewording in words nobody has thought of
# still has to name `zero reopening` and `deferred[]` or it goes red. This is what caught
# round 4's B1-new, where the fix for round 3's B1 kept the first half and dropped the
# second -- a shape a label-phrase blacklist cannot see, because the offending line
# contained no label phrase at all.
P4_ADVANCE='advances? to Gate B'
# GATE-B PASS-2 BLOCKER (finding 1), and the STRUCTURAL fix for this run's recurring class.
# Seven sites stated the Phase-4 advance and every fix reached a subset -- SKILL.md:28 alone
# was found defective THREE times (round 3, round 4, Gate B pass 2). Requiring each site to
# repeat the predicate correctly IS the treadmill; the fix is to let only ONE site state it.
# Every other mention now DEFERS ("meets Phase 4's exit conditions"), which cannot drift
# because it carries no predicate to get wrong.
p4_advance_missing() {  # $1=file  $2=required substring (grep -F)
  grep -inE "$P4_ADVANCE" "$1" 2>/dev/null | grep -ivF "$2" | grep -c . | tr -d ' '
}
# GATE-B PASS-3 (finding 1). The first cut of this was DISJUNCTIVE -- it exempted a line
# containing EITHER 'zero reopening' OR the deferral phrase -- which silently re-admitted
# round 4's B1-new shape (reopening half stated, `deferred[]` half dropped), the exact
# blocker the guard was written for. It is now a conjunction: a line either states BOTH
# halves, or it defers using the EXACT phrase. A loose substring was the other half of that
# bug: 'exit conditions' matched any line saying those two words, including one stating a
# different predicate, so the phrase is now pinned in full.
P4_DEFER="Phase 4's advance condition"
p4_advance_bad() {  # advance lines that neither state the full predicate nor properly defer
  grep -inE "$P4_ADVANCE" "$1" 2>/dev/null \
    | grep -ivF "$P4_DEFER" \
    | grep -viE 'zero reopening.*deferred\[\]|deferred\[\].*zero reopening' \
    | grep -c . | tr -d ' '
}
expect "prop: every spine Phase-4 advance states BOTH halves or defers exactly" \
  "$(p4_advance_bad "$SPINEONLY")" "0"
# ...and the SHIPPED guard gets its own controls, which the disjunctive version never had:
# its two "must discriminate" assertions exercised p4_advance_missing, a helper with no
# live use, so the guard that actually runs was uncontrolled.
P4BAD="$T/p4-advance-bad.txt"
{ printf -- '- A clean `auto-task-code-review` pass (no Blockers/Required) advances to Gate B.\n'
  printf -- '- A round with **zero reopening findings** advances to Gate B (Phase 5 at LIGHT).\n'
  printf -- '- A round advances to Gate B once the exit conditions (no blockers) are met.\n'
} > "$P4BAD"
expect "  ...and it flags all three bad shapes (r3 neither / r4 half / loose-defer)" \
  "$(p4_advance_bad "$P4BAD")" "3"
{ printf -- "- A round meeting Phase 4's advance condition advances to Gate B. Continue.\n"
  printf -- '- **Zero reopening findings and an empty (or spent) `deferred[]`** advances to Gate B.\n'
} > "$P4BAD"
expect "  ...and spares both legitimate shapes (proper deferral / full predicate)" \
  "$(p4_advance_bad "$P4BAD")" "0"
# GATE-B PASS-4 (finding 1). The first version of this fixture said "goes to Gate B", which
# never matched the anchor -- so it was spared one stage EARLY and the `grep -ivF "$P4_DEFER"`
# branch was reached by no line at all, live or fixture. Mutating P4_DEFER to a garbage string
# left the suite green: dead code wearing a control's clothes, the same zero-control defect
# pass 3 raised one level up, reproduced inside its own fix. Both halves are closed -- the
# fixture now uses the anchored verb, and SKILL.md:28 was restored to "advances" so the branch
# has a LIVE subject as well. These two assert the branch is load-bearing instead of trusting it.
p4_advance_bad_with() {  # $1=file  $2=deferral phrase to use
  grep -inE "$P4_ADVANCE" "$1" 2>/dev/null | grep -ivF "$2" \
    | grep -viE 'zero reopening.*deferred\[\]|deferred\[\].*zero reopening' | grep -c . | tr -d ' '
}
expect "  ...and the deferral branch is LIVE: a wrong phrase flags the deferring line" \
  "$(p4_advance_bad_with "$P4BAD" 'ZZZ-NEVER-APPEARS')" "1"
expect "  ...and it is live over the SPINE too, not just the fixture" \
  "$(p4_advance_bad_with "$SPINEONLY" 'ZZZ-NEVER-APPEARS')" "1"
# THE STRUCTURAL GUARD: the spine may state the exit predicate exactly ONCE. A second copy
# is how sites 2..7 came to exist, so the COUNT is pinned, not merely the wording.
expect "prop: the spine states the Phase-4 exit predicate exactly once" \
  "$(grep -cF 'reopening findings and an empty (or spent) `deferred[]`' "$SPINEONLY" | tr -d ' ')" "1"
expect "prop: ...and no line restates it in the other word order" \
  "$(grep -cF 'zero reopening findings** and an empty or spent `deferred[]`' "$SPINEONLY" | tr -d ' ')" "0"
# The two always-loaded sites must DEFER -- these are the exact lines Gate B pass 2 found
# still saying "advances ... Continue." with no LIGHT hold.
expect "prop: the NON-YIELDING list defers instead of restating" \
  "$(grep -cF "round meeting Phase 4's advance condition advances to Gate B" "$SPINEONLY" | tr -d ' ')" "1"
expect "prop: the loop-rule exit bullet defers instead of restating" \
  "$(grep -cF "round meets Phase 4's advance condition" "$SPINEONLY" | tr -d ' ')" "1"
# (A companion assertion here required the legitimate-stops sentence to name a LIGHT surface.
# It was deleted with the LIGHT hold at Gate B pass 3; :23 is back at its base wording, and
# spec-inventory reported the retirement STALE, which is how the revert was caught.)
# ...and CHECK 1 must discriminate. Both historical shapes go red: round 3's B1 (neither
# half, label-gated) and round 4's B1-new (reopening half only, no `deferred[]`) -- the
# latter is the one that matters, since it is the shape a blacklist provably misses.
# Reuse the fixture dir created at the top of the self_inflicted group rather than taking
# a second `mktemp` + `trap`. CODE-REVIEW ROUND-5 BLOCKER: bash allows ONE EXIT trap per
# shell and a second `trap ... EXIT` REPLACES the first, it does not chain -- so the
# `trap 'rm -rf "$T"' EXIT` above stopped running the moment this group added its own, and
# every run of this suite orphaned $T (measured: TMPDIR +1 per run, holding src/thing.sh
# and src/dup.sh). Reusing $T removes the second trap entirely, which is why it cannot be
# re-broken by the next addition the way a chained-trap helper could.
P4CTL="$T/p4-control.txt"
{ printf -- '- A clean `auto-task-code-review` pass (no Blockers/Required) advances to Gate B.\n'
  printf -- '- A round with **zero reopening findings** advances to Gate B (Phase 5 at LIGHT).\n'
} > "$P4CTL"
expect "  ...and it trips on the round-3 shape (neither half)" \
  "$(p4_advance_missing "$P4CTL" 'zero reopening')" "1"
expect "  ...and on the round-4 shape (reopening half only)" \
  "$(p4_advance_missing "$P4CTL" 'deferred[]')" "2"

# CHECK 2 is a blacklist of the retired label predicates, and is labelled as one -- it
# generalises no further than the phrasings listed. It earns its place by covering the
# lines CHECK 1's anchor misses (an advance stated without the words "advance to Gate B"),
# and it is dropped from the skill-name conjunction the first attempt used, which was what
# let "A clean code-review pass (no Blockers/Required) advances" through.
#
# SCOPE, stated rather than implied: spine + ARCHITECTURE.md only. `phase-3-gates.md` is
# excluded because it legitimately QUOTES the retired rule when explaining why it was
# replaced ("The earlier \"two consecutive rounds with zero blockers and zero required\"
# test could not fire..."), and a guard that reddens on a file's own account of its history
# would just get deleted.
P4_LABEL_GATE='\(no blockers?/required\)|no blockers,? and no required|zero blockers and zero required|reports only follow-ups|nothing but follow-ups'
expect "prop: no retired label predicate gates an advance (spine)" \
  "$(grep -icE "$P4_LABEL_GATE" "$SPINEONLY" | tr -d ' ')" "0"
expect "prop: no retired label predicate gates an advance (architecture)" \
  "$(grep -icE "$P4_LABEL_GATE" "$ARCH" | tr -d ' ')" "0"
# CHECK 2's discrimination, measured against the five rephrasings that defeated the first
# attempt -- all five must now go red, including the two that never name the review skill.
{ printf -- '- A clean code-review pass (no Blockers/Required) advances to Gate B. Continue.\n'
  printf -- '- A review round with no blockers and no required fixes advances to Gate B.\n'
  printf -- '- An `auto-task-code-review` round advances when the reviewer reports only Follow-ups.\n'
  printf -- '- An `auto-task-code-review` pass with zero blockers and zero required fixes advances.\n'
  printf -- '- The `auto-task-code-review` skill returning nothing but follow-ups advances the gate.\n'
} > "$P4CTL"
expect "  ...and CHECK 2 trips on all five rephrasings that defeated v1" \
  "$(grep -icE "$P4_LABEL_GATE" "$P4CTL" | tr -d ' ')" "5"
# ...and it must NOT fire on the two legitimate label statements in the spine: clause 5's
# description of a CLEAN round taking its clean exit, and Gate B's own park disposition.
# Both are correct prose; a guard that reddened on them would be reverted, not obeyed.
{ printf -- 'a clean round (zero blockers, zero required) has nothing to park and takes its exit.\n'
  printf -- '- **Only follow-ups -> park** in `state.followups` and set the gate.\n'
} > "$P4CTL"
expect "  ...and CHECK 2 spares the legitimate label prose it sits beside" \
  "$(grep -icE "$P4_LABEL_GATE" "$P4CTL" | tr -d ' ')" "0"

# B1 and B1-new pinned at their own site too -- belt and braces on the exact line four
# rounds of guards failed to cover.
expect "prop: the label-driven top-of-file advance line is GONE" \
  "$(grep -cF 'no Blockers/Required) advances to Gate B' "$SPINEONLY" | tr -d ' ')" "0"
expect "prop: ...replaced by a deferral, so it carries no predicate to drift" \
  "$(grep -cF "round meeting Phase 4's advance condition advances to Gate B (Phase 5 at LIGHT). Continue." "$SPINEONLY" | tr -d ' ')" "1"

# GATE-B PASS-3: the LIGHT-only HOLD was REMOVED, not repaired. It had to be restated at
# every site stating the advance, and across three gates it produced more defects in its own
# hardening than the hole it closed could cost -- LIGHT is max(D,R)<=2 and a non-reopening
# finding breaks no AC, is not runtime-reachable and is not a security path. The gap is now
# a DOCUMENTED limitation. These controls keep the removal honest: the hold must not creep
# back as prose without the reasoning, and the limitation must stay stated.
expect "light: the removed hold has not crept back into the spine" \
  "$(grep -ciE 'hold the gate|HELD, not passed|pending its surface' "$SPINEONLY" | tr -d ' ')" "0"
expect "light: ...nor into the flowchart" \
  "$(grep -c 'P4Hold' "$ARCH" | tr -d ' ')" "0"
# The limitation is now CLOSED: LIGHT runs Gate B at one pass, so the residue those
# assertions guarded no longer exists. They are replaced rather than deleted, because
# the reasoning that justified the closure is the thing most likely to be lost -- and
# because a stale "the limitation is stated" assertion would keep passing while the
# prose it pins describes a gap that is gone, which is a false guarantee, not a guard.
expect "light: the closure is recorded, not silently swapped in" \
  "$(printf '%s' "$P4" | grep -c 'The LIGHT-tier limitation, now closed' | tr -d ' ')" "1"
expect "light: ...and states LIGHT now runs the gate, capped at one pass" \
  "$(printf '%s' "$P4" | grep -c 'LIGHT now runs Gate B, capped at one pass' | tr -d ' ')" "1"
expect "light: ...and the retired 'stated rather than engineered around' framing is GONE" \
  "$(printf '%s' "$P4" | grep -c 'stated rather than engineered around' | tr -d ' ')" "0"
expect "light: ...and still records that a hold was tried and removed" \
  "$(printf '%s' "$P4" | grep -c 'a LIGHT-only hold was implemented and then removed' | tr -d ' ')" "1"
expect "light: ...and keeps the MIS-GRADE argument that justified closing it" \
  "$(printf '%s' "$P4" | grep -c 'a mis-graded finding is by construction not cosmetic' | tr -d ' ')" "1"
expect "light: ...and keeps the measurement the one-pass cap rests on" \
  "$(printf '%s' "$P4" | grep -c 'found in one pass what six Phase-4 rounds had missed' | tr -d ' ')" "1"
expect "light: ...and still does not claim Gate B unconditionally follows" \
  "$(printf '%s' "$P4" | grep -c 'Gate B normally follows and re-applies the identical test' | tr -d ' ')" "1"
# The cap is the mechanical half; the prose above is the reason. Pin both directions so
# a future edit cannot quietly restore the skip through either one.
# Sweep the WHOLE spec + test tree, not just the three files the closure edited. The
# narrow version of this assertion passed while two stale claims survived -- a comment in
# enforcement-spine.test.sh and a "skipped — tier=light" example in the handover report
# template. Both were found by hand in review, which is the wrong mechanism. Excludes the
# CHANGELOG (historical entries describe old behaviour and must keep saying so) and this
# file (it names the retired phrases to assert their absence).
# WIDENED after three survivors were found by hand a release later. The pattern set
# above was a list of FIXED phrasings, so it matched none of `README.md`'s "on LIGHT,
# which skips Gate B, nothing re-grades it", `ARCHITECTURE.md`'s identical clause, or
# `SKILL.md`'s "on LIGHT nothing does" -- three live claims contradicting the closure,
# in the three most-read files, with this assertion green. The two additions below are
# shaped to catch the relative-clause and the elliptical forms rather than one more
# literal. They must NOT match the legitimate past-tense record in the reference
# ("LIGHT used to skip Gate B"), which is history and has to keep saying so; the
# negative control below pins exactly that boundary in both directions.
LIGHT_SKIP_RX='LIGHT skips Gate B|skipped \(Gate A only\)|skipped at LIGHT|skipped for .tier=light|LIGHT SKIPS GATE B|LIGHT,? which skips|on LIGHT nothing does'
expect "light: nothing outside the CHANGELOG still claims LIGHT skips Gate B" \
  "$(grep -rniE "$LIGHT_SKIP_RX" \
       "$ROOT/skills" "$ROOT/hooks" "$ROOT/tests" "$ROOT/README.md" 2>/dev/null \
     | grep -vE '/(gate-b-loop\.test\.sh|spec-inventory\.sh):' | wc -l | tr -d ' ')" "0"
# CONTROL, in both directions -- a sweep that cannot fail is the failure mode that let
# the three survivors through. The widened pattern must trip on each retired phrasing
# and stay silent on the past-tense record that must survive.
expect "light CONTROL: widened rx trips on the relative-clause form" \
  "$(printf 'on LIGHT, which skips Gate B, nothing re-grades it\n' | grep -ciE "$LIGHT_SKIP_RX" | tr -d ' ')" "1"
expect "light CONTROL: widened rx trips on the elliptical form" \
  "$(printf 'On STANDARD/HEAVY Gate B re-grades it; on LIGHT nothing does\n' | grep -ciE "$LIGHT_SKIP_RX" | tr -d ' ')" "1"
expect "light CONTROL: widened rx spares the past-tense record" \
  "$(printf 'LIGHT used to skip Gate B, so a park there was final\n' | grep -ciE "$LIGHT_SKIP_RX" | tr -d ' ')" "0"
expect "light: ...and that past-tense record is still in the reference" \
  "$(printf '%s' "$P4" | grep -c 'LIGHT used to skip Gate B' | tr -d ' ')" "1"
# The spine's own copy, pinned HERE rather than in enforcement-spine.test.sh. That file
# is not one of the sweep's two exclusions, so quoting the retired clause there would
# make the sweep report its own guard as a survivor -- while excluding a third file
# would widen exactly the blind spot that let these three through. This file already
# names every retired phrasing for that reason, so the absence check belongs with them.
expect "light: the retired LIGHT-skip clause is gone from the spine" \
  "$(grep -c 'on LIGHT nothing does' "$ROOT/skills/auto-task/SKILL.md" | tr -d ' ')" "0"
expect "light: ...and the spine states the uniform re-grade instead" \
  "$(grep -c 'where Gate B re-grades it at every tier too' "$ROOT/skills/auto-task/SKILL.md" | tr -d ' ')" "1"
# Both exclusions are load-bearing, not convenience: this file names the retired phrases in
# order to assert their absence, and spec-inventory.sh must quote the retired base line
# verbatim as its RETIRED_PREFIXES key. Excluding anything else would hide a real survivor.
# `skipped_reason` itself is NOT dead -- user descope and park_non_blocking still write it.
# Only the literal value `tier=light` is unwritable now, so pin that distinction: the field
# survives, the tier-specific value does not.
expect "light: skipped_reason survives as a field (descope path)" \
  "$(grep -c 'skipped_reason' "$GATES" | tr -d ' ' | awk '{print ($1>0)?"yes":"no"}')"      "yes"
expect "light: ...but no spec tells the model to write tier=light" \
  "$(grep -rn 'tier=light' "$ROOT/skills" 2>/dev/null | wc -l | tr -d ' ')"                  "0"

# ---- Step 0: WHERE the Phase-4 review runs (`review_in_subagent`) ------------
# Phases 2, 3 and 4 all ran in the main loop, so the model that wrote the diff also
# reviewed it. Moving Phase 4 into a fresh-context agent is the fix, and the danger is
# the mirror image of the shadow pass's: not that it fails, but that it quietly loosens
# the one rule the commit gate depends on. Every assertion below pins a property that,
# if lost, would either weaken the gate or let a failure mode strand a run.
S0="$(awk '/^### Step 0 — where the review RUNS/,/^### Step A/' "$GATES")"
expect "step0: the contract exists in the phase-4 reference" \
  "$([ -n "$S0" ] && echo yes || echo no)"                                                       "yes"
expect "step0: default is ON"                      "$(bash "$ROOT/hooks/settings.sh" get review_in_subagent 2>/dev/null)" "true"
expect "step0: the key is resolvable"              "$(bash "$ROOT/hooks/settings.sh" keys 2>/dev/null | grep -c '^review_in_subagent$' | tr -d ' ')" "1"
expect "step0: it appears in the merged defaults"  "$(bash "$ROOT/hooks/settings.sh" all 2>/dev/null | jq -r '.review_in_subagent')" "true"
expect "step0: false restores the inline call"     \
  "$(printf '%s' "$S0" | grep -c 'Set `review_in_subagent: false` to invoke it inline instead' | tr -d ' ')" "1"
# THE GATE IS NOT LOOSENED. This is the assertion that matters most: the whole change is
# defensible only because the reviewer is still the skill and `tool` still records it.
expect "step0: the agent MUST invoke the review skill" \
  "$(printf '%s' "$S0" | grep -c 'MUST tell it to invoke the `auto-task-code-review` skill via the Skill tool' | tr -d ' ')" "1"
expect "step0: a hand-rolled prompt is still the forbidden substitution" \
  "$(printf '%s' "$S0" | grep -c 'A hand-rolled review prompt in an agent is the substitution' | tr -d ' ')" "1"
expect "step0: ...and says why the hook is unaffected" \
  "$(printf '%s' "$S0" | grep -c 'cannot see \*where\* the skill ran' | tr -d ' ')" "1"
# GATE-B PASS-1 FINDING (required), and the sharpest one in the run. Step 0 asserted the
# skill is still the reviewer and then added detectors for three LOUD failures (spawn
# failure, malformed report, tree edit) while leaving the quiet one open: an agent that
# never calls the Skill tool and returns a plausible review anyway. It has the diff, the
# plan, TRACE.md and the prior findings -- everything needed to write one. That report is
# not empty, not malformed, not truncated, and edits nothing, so NO rung fired and the
# round would record `tool: "skill:auto-task-code-review"` for a review the skill never
# performed -- the exact lie the section forbids two paragraphs earlier. Inline, the
# orchestrator knows first-hand because the Skill call is in its own tool log; moving the
# call site is precisely what destroys that evidence, so the move has to replace it.
expect "step0: the report must EVIDENCE that the skill ran" \
  "$(printf '%s' "$S0" | grep -c 'REQUIRE EVIDENCE that it ran' | tr -d ' ')" "1"
expect "step0: ...via the skill's Phase-2 structured report" \
  "$(printf '%s' "$S0" | grep -c 'The marker is the skill.s Phase-2 structured report, and ONLY that' | tr -d ' ')" "1"
expect "step0: ...and a report lacking it is handled as malformed" \
  "$(printf '%s' "$S0" | grep -c 'treat it exactly as a malformed report' | tr -d ' ')" "1"
expect "step0: ...the malformed rung names the no-evidence case too" \
  "$(printf '%s' "$S0" | grep -c "lacks the skill.s Phase-2 structured report" | tr -d ' ')" "1"
# CODE-REVIEW ROUND-4 FINDING (required), and the reason the marker is ONE block rather
# than the whole five-phase shape. The first version of this clause demanded "the skill's
# five-phase structure ... with Phase-5's per-finding quoted evidence". That is
# unsatisfiable by a CLEAN review: `auto-task-code-review`'s own output discipline
# short-circuits after Phase 3 ("If after Phase 3 there are no significant findings ...
# otherwise stop there"), so Prevent is skipped by instruction and Phase 5 has nothing to
# quote. A correct clean subagent review would have been read as "the skill did not run",
# discarded, retried, and forced inline -- the feature disabling itself on the success
# path, a false positive strictly worse than the hole it closed. Pin the narrowing AND the
# reason, so a future edit reaching for completeness reads why it must not.
expect "step0: the marker is unconditional, and says why that matters" \
  "$(printf '%s' "$S0" | grep -c 'the only one the skill emits unconditionally' | tr -d ' ')" "1"
expect "step0: ...and explicitly forbids extending it to Phase 4/5 content" \
  "$(printf '%s' "$S0" | grep -c 'Do NOT extend the check to Phase 4 or Phase 5 content' | tr -d ' ')" "1"
expect "step0: ...naming the clean-review rejection it would cause" \
  "$(printf '%s' "$S0" | grep -c 'would reject a \*\*correct clean review\*\*' | tr -d ' ')" "1"
expect "step0: ...and the rung says a short clean report is a SUCCESS" \
  "$(printf '%s' "$S0" | grep -c 'short \*because the review was clean\* is a \*\*success\*\*' | tr -d ' ')" "1"
# REGRESSION GUARD: the retired over-broad predicate must not come back anywhere.
expect "step0: the retired five-phase demand is gone" \
  "$(grep -c "five-phase structure" "$GATES" | tr -d ' ')" "0"
# HONESTY: a structural signal is not proof, and the contract must not pretend otherwise.
expect "step0: ...and does not overclaim it as proof" \
  "$(printf '%s' "$S0" | grep -c 'a \*structural\* signal, not proof' | tr -d ' ')" "1"
# GATE-B PASS-2 FINDING (required). Every check on the marker so far asked whether the
# SKILL EMITS the block. None asked whether the ORCHESTRATOR RECEIVES it -- and only the
# agent's returned output crosses the subagent boundary, while the skill's clean-review
# short-circuit ends the turn with a one-liner. So a faithful agent could hand back a
# final message without the block and a correct clean review would be rejected: the same
# self-disabling failure the narrowing was granted to remove, relocated to the transport.
expect "step0: emitted is distinguished from RETURNED" \
  "$(printf '%s' "$S0" | grep -c 'EMITTED IS NOT RETURNED' | tr -d ' ')" "1"
expect "step0: ...and the prompt must require the block in the FINAL MESSAGE" \
  "$(printf '%s' "$S0" | grep -c 'verbatim in your final message; that message is the only thing I receive' | tr -d ' ')" "1"
expect "step0: ...the discriminator is the block, never the length" \
  "$(printf '%s' "$S0" | grep -c 'The discriminator is the BLOCK, never the length' | tr -d ' ')" "1"
# GATE-B PASS-2 FINDING (required): rung order. Stated as a rule, not left to the order
# the bullets happen to sit in, because a first-match ladder with the report rung first
# lets the correlated fabricate-and-edit agent skip detection.
expect "step0: the tree is checked before the report" \
  "$(printf '%s' "$S0" | grep -c 'check the TREE before judging the REPORT' | tr -d ' ')" "1"
expect "step0: ...but only when an agent actually returned" \
  "$(printf '%s' "$S0" | grep -c 'only when an agent actually returned' | tr -d ' ')" "1"
expect "step0: ...a failed spawn short-circuits above the edit rung" \
  "$(printf '%s' "$S0" | grep -c 'No agent returned at all' | tr -d ' ')" "1"
expect "step0: ...naming the spurious disable it prevents" \
  "$(printf '%s' "$S0" | grep -c 'did not move .because of. a reviewer' | tr -d ' ')" "1"
# GATE-B PASS-3 FINDING: ordinals go stale the moment the order changes -- they did,
# twice. The rungs are named now, and the contract says why.
expect "step0: the rungs are NAMED, not numbered" \
  "$(printf '%s' "$S0" | grep -c 'the \*\*spawn-failure\*\* case, the \*\*edit\*\* rung, and the \*\*report\*\* rung' | tr -d ' ')" "1"
expect "step0: ...and no stale rung-1 ordinal survives" \
  "$(printf '%s' "$S0" | grep -c "rung 1" | tr -d ' ')" "0"
expect "step0: ...the two cross-references name the report rung" \
  "$(printf '%s' "$S0" | grep -c 'the \*\*report rung\*\* below' | tr -d ' ')" "2"
expect "step0: ...naming the edited-tree baseline it prevents" \
  "$(printf '%s' "$S0" | grep -c 'already-edited tree' | tr -d ' ')" "1"
# POSITIONAL: the edit rung must physically precede the report rung, since the ladder is
# first-match. Prose alone would not survive a reorder.
# Anchored on the rung NAMES, which is the point of naming them: the previous version of
# this assertion keyed on 'The spawn failed;' and silently degraded to a comparison
# against an empty string the moment that rung gained its name prefix.
_edit_ln="$(printf '%s' "$S0" | grep -n '^- \*\*The EDIT rung' | head -1 | cut -d: -f1)"
_rept_ln="$(printf '%s' "$S0" | grep -n '^- \*\*The REPORT rung' | head -1 | cut -d: -f1)"
expect "step0: both rungs resolve to a line (anchor not degraded)" \
  "$([ -n "$_edit_ln" ] && [ -n "$_rept_ln" ] && echo both || echo missing)" "both"
expect "step0: edit rung physically precedes the report rung" \
  "$([ "$_edit_ln" -lt "$_rept_ln" ] && echo yes || echo no)" "yes"
# NEGATIVE CONTROL on the gate itself: `enforce-gates.sh` must be untouched by this
# change. If a future edit teaches the hook about the call site, the contract's central
# claim ("the commit gate needs no change") has silently stopped being true.
expect "step0: enforce-gates.sh still pins only the tool literal" \
  "$(grep -c 'review_in_subagent' "$ROOT/hooks/enforce-gates.sh" | tr -d ' ')"                    "0"
expect "step0: ...and still requires the skill literal" \
  "$([ "$(grep -c 'skill:auto-task-code-review' "$ROOT/hooks/enforce-gates.sh")" -ge 1 ] && echo yes || echo no)" "yes"
# Spawn shape. Synchronous for the same reason every other spawn is; read-only for the
# same reason the shadow pass is, and with the same absent mechanical backstop.
expect "step0: ONE general-purpose Agent, synchronously" \
  "$(printf '%s' "$S0" | grep -c 'ONE `general-purpose` Agent, \*\*synchronously\*\*' | tr -d ' ')" "1"
expect "step0: the prompt must forbid edits, in those words" \
  "$(printf '%s' "$S0" | grep -c 'prompt MUST forbid edits, in those words' | tr -d ' ')"          "1"
expect "step0: ...and names the reviewed_diff_sha consequence" \
  "$(printf '%s' "$S0" | grep -c 'moves `reviewed_diff_sha` and blocks the commit' | tr -d ' ')"   "1"
expect "step0: the orchestrator applies every fix, not the reviewer" \
  "$(printf '%s' "$S0" | grep -c 'the orchestrator applies every fix' | tr -d ' ')"                "1"
# Inputs. A reviewer with no memory of the run re-raises settled findings, which is the
# churn 0.29.0/0.30.0 bounded arriving through a new door.
expect "step0: CONTEXT.md + TRACE.md per the read-before-review contract" \
  "$(printf '%s' "$S0" | grep -c 'CONTEXT.md` and `TRACE.md` per the read-before-review contract' | tr -d ' ')" "1"
expect "step0: prior rounds' findings passed by name" \
  "$(printf '%s' "$S0" | grep -c 'the findings of every prior round this run' | tr -d ' ')"        "1"
expect "step0: and says why that is load-bearing, not courteous" \
  "$(printf '%s' "$S0" | grep -c 're-raises findings earlier rounds already considered and resolved' | tr -d ' ')" "1"
# Delta-scoping — the cost bound, reusing Gate B Step 1's mechanism rather than a second
# copy of it. Round 1 full, every later round the delta.
expect "step0: round 1 full, rounds 2+ delta-scoped" \
  "$(printf '%s' "$S0" | grep -c 'Round 1 reviews the full working-tree diff. Every later round reviews only the delta' | tr -d ' ')" "1"
# CODE-REVIEW ROUND-1 FINDING (required). The boundary was named as `reviewed_diff_sha`
# "the same mechanism Gate B's Step 1 already uses". Both halves were wrong, and wrong on
# exactly the rounds delta-scoping runs on. `reviewed_diff_sha` is the COMMIT GATE's field,
# written only when a round comes back CLEAN -- but a round 2 exists only because round 1
# REOPENED, so the named boundary is null or stale precisely when it is first needed. The
# two ways out are both defects: re-read the full diff (losing the cost bound that
# justifies the step) or write the hook-read field at spawn from a pre-fix tree. Gate B is
# no precedent either: `verified_diff_sha` is written at spawn and bound by no hook, which
# is why IT can serve as a boundary. `rounds[n-1].diff_sha` already exists, is recorded on
# EVERY exit including a reopen, and is the correct referent.
expect "step0: boundary is rounds[n-1].diff_sha, not reviewed_diff_sha" \
  "$(printf '%s' "$S0" | grep -c 'The boundary is `rounds\[n-1\].diff_sha` — NOT `reviewed_diff_sha`' | tr -d ' ')" "1"
expect "step0: ...and says why that field is null on a reopening round" \
  "$(printf '%s' "$S0" | grep -c 'written .only when a round comes back clean' | tr -d ' ')"       "1"
expect "step0: ...and distinguishes Gate B's spawn-written verified_diff_sha" \
  "$(printf '%s' "$S0" | grep -c 'is written at \*spawn\* and is bound by no hook' | tr -d ' ')"   "1"
expect "step0: ...so it no longer claims to be the SAME mechanism" \
  "$(printf '%s' "$S0" | grep -c 'the same mechanism Gate B.s Step 1 already uses' | tr -d ' ')"   "0"
# NEGATIVE CONTROL on the whole class -- and it must sweep the TREE, not the slice.
#
# GATE-B PASS-1 FINDING. The first version of this control grepped `$S0` (the Step-0 awk
# region) and was labelled "on the whole class". It was not: the retired boundary survived
# verbatim in THREE other files -- `references/settings.md` and `README.md` (both the
# `review_in_subagent` key row) and the CHANGELOG -- and `references/settings.md` is a
# MANDATORY READ, so two contract files gave the orchestrator opposite boundaries while
# this assertion reported clean. A control scoped to the reproducer can only ever prove
# the reproducer was fixed. Sweep every spec + doc surface instead, excluding this file
# (which must quote the retired phrasing to assert its absence).
RDS_RX="delta since the previous round.s .reviewed_diff_sha"
expect "step0: no delta boundary anywhere still points at reviewed_diff_sha" \
  "$(grep -rniE "$RDS_RX" "$ROOT/skills" "$ROOT/hooks" "$ROOT/README.md" "$ROOT/CHANGELOG.md" 2>/dev/null \
     | grep -vE '/gate-b-loop\.test\.sh:' | wc -l | tr -d ' ')" "0"
# CONTROL for the control: the widened pattern must actually trip on the retired sentence.
expect "step0: ...and the widened sweep trips on the retired phrasing" \
  "$(printf 'only the delta since the previous round%s `reviewed_diff_sha` — that is what\n' "'s" | grep -ciE "$RDS_RX" | tr -d ' ')" "1"
expect "step0: ...and the diff bytes are written at SPAWN time" \
  "$(printf '%s' "$S0" | grep -c 'artifacts/review-<n>.diff` at \*\*spawn\*\* time' | tr -d ' ')"  "1"
# The three bookkeeping clauses. Each closes a hole the edit-prohibition cannot reach,
# because `.auto-task/` is excluded from git and therefore invisible to the sha check.
expect "step0: reviewer writes nothing under .auto-task/" \
  "$(printf '%s' "$S0" | grep -c 'The reviewer writes nothing under `.auto-task/`' | tr -d ' ')"   "1"
expect "step0: ...and says the sha check cannot catch that" \
  "$(printf '%s' "$S0" | grep -c 'never moves the diff hash' | tr -d ' ')"                         "1"
expect "step0: agent is told it runs under /auto-task orchestration" \
  "$(printf '%s' "$S0" | grep -c 'Tell it that it is running under `/auto-task` orchestration' | tr -d ' ')" "1"
expect "step0: ...naming the double-write it prevents" \
  "$(printf '%s' "$S0" | grep -c 'double-writes the log' | tr -d ' ')"                             "1"
# The condition Step 0 relies on must actually exist in the review skill, or clause 2 is
# aimed at nothing. Pin the skill side too, so removing it there reds this.
expect "step0: the review skill really suppresses its trace under /auto-task" \
  "$(grep -c 'Suppressed under orchestration' "$ROOT/skills/auto-task-code-review/SKILL.md" | tr -d ' ')" "1"
expect "step0: agent is told it is the reviewer, not the caller" \
  "$(printf '%s' "$S0" | grep -c 'Tell it that it is the reviewer, not the caller' | tr -d ' ')"   "1"
expect "step0: ...and that the Caller note is addressed to the orchestrator" \
  "$(printf '%s' "$S0" | grep -c 'addressed to the orchestrator that spawned this agent' | tr -d ' ')" "1"
# shadow_review is superseded, and the skip is RECORDED rather than omitted -- otherwise
# a run's telemetry cannot distinguish "measured nothing" from "did not measure".
expect "step0: shadow_review is skipped while this is on" \
  "$(printf '%s' "$S0" | grep -c '`shadow_review` is skipped while this is on' | tr -d ' ')"       "1"
expect "step0: ...recorded as a status, not omitted" \
  "$(printf '%s' "$S0" | grep -c 'note: \"review_in_subagent is on\"' | tr -d ' ')"                "1"
# CODE-REVIEW ROUND-1 FINDING (required). The recorded skip was stated UNCONDITIONALLY,
# which on a stock run (shadow_review false, review_in_subagent true) fired at the same
# time as the schema's "absent on every run where the setting is off, so nothing migrates
# and no existing run changes shape" -- two rules, opposite instructions, both true by
# default. Writing the object on every default run is the one thing that guarantee
# promises never happens. The skip is conditional on the user having asked for the pass.
expect "step0: the skip record is conditional on the setting being true" \
  "$(printf '%s' "$S0" | grep -c 'only when the user actually asked for the pass' | tr -d ' ')"    "1"
expect "step0: ...and off keeps the object absent as before" \
  "$(printf '%s' "$S0" | grep -c 'the object stays absent exactly as before' | tr -d ' ')"         "1"
expect "step0: the schema states both conditions are required" \
  "$(grep -c 'Both conditions are required' "$ROOT/skills/auto-task/references/state-schema.md" | tr -d ' ')" "1"
expect "step0: ...and keeps its absent-by-default guarantee intact" \
  "$(grep -c 'keeps the first sentence of this paragraph true on a stock run' "$ROOT/skills/auto-task/references/state-schema.md" | tr -d ' ')" "1"
expect "step0: the schema documents the recorded skip" \
  "$(grep -c 'review_in_subagent is on' "$ROOT/skills/auto-task/references/state-schema.md" | tr -d ' ')" "1"

# ---- Step 0's degradation ladder, as an ORACLE not as prose ------------------
# Asserting that the ladder is WRITTEN proves nothing about whether it is bounded --
# "verify-by-grep is not verification". No hook drives this path (a review spawn is an
# Agent call, and hooks.json registers PreToolUse only for Bash), so as everywhere else
# in this suite the rule is implemented as a reference oracle and driven over the exact
# cases the spec claims, with companion prose assertions so the two cannot drift.
#
# ORACLE for Step 0's ladder. Returns "<round-recorded>|<gate-touched>|<retries>|
# <next-call>|<subagent-still-enabled>|<tool>" so every clause is observable at once.
# STEP0_MUTATE is the control's injection point: set it to a rung name and that rung
# returns a WRONG outcome, so the same assertion battery below can be re-run against a
# broken ladder and required to fail. Empty (the normal case) changes nothing.
STEP0_MUTATE="${STEP0_MUTATE:-}"
step0_outcome(){ # $1: ok|clean-short|spawn-fail|empty|malformed|no-marker|sha-moved|sha-moved+no-marker|spawn-fail+sha-moved  $2=retry-also-failed(yes|no)
  if [ -n "$STEP0_MUTATE" ] && [ "$STEP0_MUTATE" = "$1" ]; then
    # The single most dangerous variant: a degraded rung that SETS the gate. It would
    # commit a diff no review ever read.
    printf 'discarded|YES-SET|0|inline-rerun|no|skill:auto-task-code-review'; return
  fi
  case "$1" in
    ok)          printf 'yes|no|0|record-round|yes|skill:auto-task-code-review' ;;
    # GATE-B PASS-2 CASES. `clean-short` is the SUCCESS the marker rule must not reject:
    # a clean review returns a short report that still carries the Phase-2 block, so it
    # records an ordinary round. `no-marker` is the failure: the block is absent however
    # long the report is. Brevity is never the test -- these two cases are what make that
    # discriminator executable instead of merely asserted, and their absence is why the
    # emitted-vs-returned defect was invisible to this suite.
    clean-short) printf 'yes|no|0|record-round|yes|skill:auto-task-code-review' ;;
    no-marker)
      if [ "$2" = "yes" ]; then printf 'no|no|1|inline-fallback|yes|skill:auto-task-code-review'
      else                      printf 'no|no|1|respawn|yes|skill:auto-task-code-review'; fi ;;
    # GATE-B PASS-3 CASE. A spawn that produced no agent cannot have had its tree edited
    # BY a reviewer, so it must reach the retry rung even when the sha moved meanwhile
    # (autosave, formatter, a concurrent user edit). An "unconditional" sha check would
    # instead discard the round, set subagent_disabled for the rest of the run and write a
    # false TRACE incident -- switching the feature off permanently on a spurious trigger.
    'spawn-fail+sha-moved'|spawn-fail|empty|malformed)
      # Not a round: nothing recorded, gate untouched, sha untouched. Exactly one retry,
      # then the INLINE call -- never a further retry and never a user stop, or an
      # unavailable subagent could hold a run hostage over a setting whose whole point
      # is that both call sites produce the same review.
      if [ "$2" = "yes" ]; then printf 'no|no|1|inline-fallback|yes|skill:auto-task-code-review'
      else                      printf 'no|no|1|respawn|yes|skill:auto-task-code-review'; fi ;;
    # ORDERING. The edit rung is checked before the report rung, so an agent that BOTH edited
    # the tree AND returned a marker-less report gets the sha-moved handling -- findings
    # discarded, inline re-run, subagent disabled. Under a report-first ladder this input
    # would match the no-marker rung, skip detection entirely, and let the retry baseline
    # its sha from the already-edited tree.
    sha-moved|'sha-moved+no-marker')
      # Findings describe a tree that no longer exists, so they are discarded rather than
      # acted on; the round re-runs INLINE against the current tree; the subagent is
      # disabled for the rest of the run so one incident cannot repeat every round; and
      # NOTHING is auto-reverted. (The inline re-run does NOT re-pin reviewed_diff_sha --
      # that field is written only on a CLEAN round, and the hook keeps blocking until one
      # happens. Gate B pass 1 corrected the spec sentence that claimed otherwise.)
      printf 'discarded|no|0|inline-rerun|no|skill:auto-task-code-review' ;;
    *) printf 'UNSPECIFIED' ;;
  esac; }
f(){ printf '%s' "$1" | cut -d'|' -f"$2"; }

for ev in spawn-fail empty malformed; do
  o="$(step0_outcome "$ev" yes)"
  expect "ladder/$ev: not recorded as a round"      "$(f "$o" 1)" "no"
  expect "ladder/$ev: gate left untouched"          "$(f "$o" 2)" "no"
  expect "ladder/$ev: exactly one retry"            "$(f "$o" 3)" "1"
  expect "ladder/$ev: then falls back inline"       "$(f "$o" 4)" "inline-fallback"
  expect "ladder/$ev: tool literal unchanged"       "$(f "$o" 6)" "skill:auto-task-code-review"
done
o="$(step0_outcome spawn-fail no)"
expect "ladder: first failure respawns, not inline" "$(f "$o" 4)" "respawn"

o="$(step0_outcome sha-moved)"
expect "ladder/sha-moved: findings discarded"       "$(f "$o" 1)" "discarded"
expect "ladder/sha-moved: gate NOT set"             "$(f "$o" 2)" "no"
expect "ladder/sha-moved: re-runs inline"           "$(f "$o" 4)" "inline-rerun"
expect "ladder/sha-moved: subagent disabled for the run" "$(f "$o" 5)" "no"
expect "ladder/sha-moved: tool literal unchanged"   "$(f "$o" 6)" "skill:auto-task-code-review"
o="$(step0_outcome ok)"
expect "ladder/ok: an ordinary round IS recorded"   "$(f "$o" 1)" "yes"
expect "ladder/ok: subagent stays enabled"          "$(f "$o" 5)" "yes"

# GATE-B PASS-2 FINDINGS (required), and the two cases whose ABSENCE is why the first
# defect got through. Everything about the marker rule had been pinned by grep, so the
# suite could see that the sentence existed but never that a clean review classifies as a
# success. These two drive the discriminator itself.
o="$(step0_outcome clean-short)"
expect "ladder/clean-short: a SHORT clean report is a success" "$(f "$o" 1)" "yes"
expect "ladder/clean-short: ...it records an ordinary round"   "$(f "$o" 4)" "record-round"
expect "ladder/clean-short: ...and does NOT disable the agent" "$(f "$o" 5)" "yes"
o="$(step0_outcome no-marker yes)"
expect "ladder/no-marker: a marker-less report is NOT a round" "$(f "$o" 1)" "no"
expect "ladder/no-marker: ...gate untouched"                   "$(f "$o" 2)" "no"
expect "ladder/no-marker: ...one retry, then inline"           "$(f "$o" 4)" "inline-fallback"
# The pair is the whole point: identical brevity, opposite outcomes, discriminated by the
# BLOCK and not by length. If a future edit re-conflates them these two disagree.
expect "ladder: brevity is not the test — the two differ" \
  "$([ "$(f "$(step0_outcome clean-short)" 1)" != "$(f "$(step0_outcome no-marker yes)" 1)" ] \
     && echo discriminated || echo conflated)" "discriminated"
# ORDERING (G2): an agent that edited the tree AND returned no marker must get the
# SHA-MOVED handling, not rung 1's. A report-first ladder would skip detection entirely,
# leave subagent_disabled unset, and let the retry baseline its sha from the edited tree.
o="$(step0_outcome 'sha-moved+no-marker')"
expect "ladder/edited+no-marker: sha check wins, findings discarded" "$(f "$o" 1)" "discarded"
expect "ladder/edited+no-marker: ...subagent IS disabled"            "$(f "$o" 5)" "no"
expect "ladder/edited+no-marker: ...and it re-runs inline"           "$(f "$o" 4)" "inline-rerun"
expect "ladder/edited+no-marker: ...not the report rung's retry path" \
  "$([ "$(f "$o" 3)" = "0" ] && echo no-retry-burned || echo took-report-rung)" "no-retry-burned"
# GATE-B PASS-3 FINDING (required). The ordering rule that fixed the case above said "run
# the sha check UNCONDITIONALLY", which over-reached: on a spawn that produced no agent,
# a tree that moved meanwhile (autosave, formatter, concurrent user edit) is not
# attributable to a reviewer that never existed. Unconditional would have discarded the
# round, set subagent_disabled for the REST OF THE RUN and written a false TRACE incident
# — switching the feature off permanently on a spurious trigger, surviving a resume. The
# rule is now ordered: no-agent-returned short-circuits ABOVE the edit rung.
o="$(step0_outcome 'spawn-fail+sha-moved' yes)"
expect "ladder/spawn-fail+sha-moved: takes the RETRY path"      "$(f "$o" 4)" "inline-fallback"
expect "ladder/spawn-fail+sha-moved: ...not the edit rung"      "$(f "$o" 1)" "no"
expect "ladder/spawn-fail+sha-moved: ...subagent NOT disabled"  "$(f "$o" 5)" "yes"
# The pair that makes the ordering rule executable: a moved sha means opposite things
# depending on whether an agent returned. If a future edit re-reads the check as
# unconditional, these two collapse to the same outcome and this trips.
expect "ladder: a moved sha is attributed ONLY when an agent returned" \
  "$([ "$(f "$(step0_outcome 'spawn-fail+sha-moved' yes)" 5)" != "$(f "$(step0_outcome 'sha-moved+no-marker')" 5)" ] \
     && echo attributed-correctly || echo blames-a-nonexistent-agent)" "attributed-correctly"
# CONTROL: the oracle must be capable of failing, and the control must DEMONSTRATE that
# by producing a failure -- not by comparing two literals to each other.
#
# GATE-A FINDING (AC #14). The first version of this control defined a second function
# returning a hardcoded mutant string and asserted that string differed from "no". It
# passed without running a single ladder assertion, and would have kept passing verbatim
# with every assertion above deleted -- a tautology dressed as a mutation probe, which is
# the "verify-by-grep is not verification" failure in a new costume. The replacement
# re-runs THE ASSERTIONS THEMSELVES against a mutated oracle in a counting sandbox and
# requires the count of failures to be non-zero.
battery_failures(){ # $1=an outcome string; echo how many sha-moved ladder assertions it violates
  local o="$1" n=0
  [ "$(f "$o" 1)" = "discarded" ]                     || n=$((n+1))
  [ "$(f "$o" 2)" = "no" ]                            || n=$((n+1))
  [ "$(f "$o" 4)" = "inline-rerun" ]                  || n=$((n+1))
  [ "$(f "$o" 5)" = "no" ]                            || n=$((n+1))
  [ "$(f "$o" 6)" = "skill:auto-task-code-review" ]   || n=$((n+1))
  printf '%s' "$n"; }
expect "ladder CONTROL: a gate-setting mutant makes the battery FAIL" \
  "$([ "$(battery_failures "$(STEP0_MUTATE=sha-moved step0_outcome sha-moved)")" -gt 0 ] \
     && echo failed-as-required || echo silently-passed)"                                          "failed-as-required"
# ...and specifically on the gate clause, not incidentally on some other field: a control
# that fired for the wrong reason would still be a control that proves nothing.
expect "ladder CONTROL: ...and it is the gate clause that trips" \
  "$(f "$(STEP0_MUTATE=sha-moved step0_outcome sha-moved)" 2)"                                     "YES-SET"
# The un-mutated oracle must produce ZERO failures through the SAME battery, or the
# control above would report success on an oracle that is simply always broken.
expect "ladder CONTROL: the un-mutated oracle produces no failures" \
  "$(battery_failures "$(step0_outcome sha-moved)")"                                               "0"
# Companion prose assertions: the oracle mirrors the spec, so pin the spec's own wording
# for each rung. If the ladder is reworded, one of these reds and the oracle gets re-read.
L0="$(awk "/^#### Step 0's degradation ladder/,/^\*\*\`shadow_review\` is skipped/" "$GATES")"
expect "ladder prose: exists"                       "$([ -n "$L0" ] && echo yes || echo no)"       "yes"
expect "ladder prose: no failure may deadlock or pass the gate" \
  "$(printf '%s' "$L0" | grep -c 'None of these may deadlock the run, pass the gate' | tr -d ' ')" "1"
expect "ladder prose: a failed/empty/malformed report is NOT a round" \
  "$(printf '%s' "$L0" | grep -c 'this is not a round' | tr -d ' ')"                               "1"
expect "ladder prose: retry exactly once"           \
  "$(printf '%s' "$L0" | grep -c 'Retry the spawn exactly once' | tr -d ' ')"                      "1"
expect "ladder prose: then invoke the skill inline" \
  "$(printf '%s' "$L0" | grep -c 'invoke the skill inline for this round' | tr -d ' ')"            "1"
expect "ladder prose: the sha is recompared after the agent returns" \
  "$(printf '%s' "$L0" | grep -c 'recompute it with the byte-identical pinned-flag formula' | tr -d ' ')" "1"
expect "ladder prose: a move means the tree changed mid-review" \
  "$(printf '%s' "$L0" | grep -c 'A move means the tree changed while the review was reading it' | tr -d ' ')" "1"
expect "ladder prose: subagent disabled for the rest of the run" \
  "$(printf '%s' "$L0" | grep -c 'disable the subagent for the remainder of the run' | tr -d ' ')" "1"
# NO AUTO-REVERT is a deliberate refusal, not an omission: scripting a revert of
# model-authored edits is destructive and can take a concurrent legitimate edit with it.
expect "ladder prose: explicitly refuses to auto-revert" \
  "$(printf '%s' "$L0" | grep -c 'Do NOT automatically revert' | tr -d ' ')"                       "1"
expect "ladder prose: the detector's blind spot is stated, not implied" \
  "$(printf '%s' "$L0" | grep -c 'It is blind to `.auto-task/`' | tr -d ' ')"                      "1"
expect "ladder prose: tool literal holds on every degraded path" \
  "$(printf '%s' "$L0" | grep -c 'still reads `skill:auto-task-code-review`' | tr -d ' ')"         "1"

# ---- Shadow second opinion (opt-in, measurement only) ------------------------
# The danger with this feature is not that it fails -- it is that it quietly becomes an
# authority. Every assertion below pins the "decides nothing" half, because that is the
# property that keeps it from reintroducing the review churn 0.29.0/0.30.0 bounded.
SR="$(awk '/^### Shadow second opinion/,/^\*\*The per-round record is also/' "$GATES")"
expect "shadow: the contract exists in the phase-4 reference" \
  "$([ -n "$SR" ] && echo yes || echo no)"                                                       "yes"
expect "shadow: default is OFF"                    "$(bash "$ROOT/hooks/settings.sh" get shadow_review 2>/dev/null)" "false"
expect "shadow: the key is resolvable"             "$(bash "$ROOT/hooks/settings.sh" keys 2>/dev/null | grep -c '^shadow_review$' | tr -d ' ')" "1"
expect "shadow: it appears in the merged defaults" "$(bash "$ROOT/hooks/settings.sh" all 2>/dev/null | jq -r '.shadow_review')" "false"
expect "shadow: runs ONCE per run, after Phase 4 goes clean" \
  "$(printf '%s' "$SR" | grep -c 'run this ONCE per run, immediately after Phase 4 sets' | tr -d ' ')" "1"
# GATE-A ROUND-3 FINDING. This rationale's two peer copies (README + settings.md) were
# rescoped to the `false` configuration, but the copy HERE -- the highest-authority one,
# the spec the orchestrator actually reads -- kept the unconditional present tense
# "Phases 2, 3 and 4 all run in the main loop", two lines below the supersession note that
# contains but does not correct it. AC #8's method is a grep for the key plus the LIGHT
# sweep, neither of which can see a stale independence claim, so it stayed green over a
# live contradiction. Pin the scoping, and pin the retired absolute's absence, in the one
# file where being wrong would mislead the model rather than a reader.
expect "shadow: the rationale is scoped to the false configuration" \
  "$(printf '%s' "$SR" | grep -c 'In the .review_in_subagent: false. configuration — the only one where this pass runs at all' | tr -d ' ')" "1"
expect "shadow: ...and no longer claims Phase 4 runs in the main loop unconditionally" \
  "$(printf '%s' "$SR" | grep -c '^\*\*What it is for.*\*\* Phases 2, 3 and 4 all run in the main loop' | tr -d ' ')" "0"
expect "shadow: it decides nothing -- stated as its own rule" \
  "$(printf '%s' "$SR" | grep -c '\*\*It decides nothing\.\*\*' | tr -d ' ')" "1"
expect "shadow: ...sets no gate, reopens nothing, never routes" \
  "$(printf '%s' "$SR" | grep -c 'sets no gate flag, reopens no round, blocks no commit' | tr -d ' ')" "1"
expect "shadow: it MUST invoke the review skill, not a hand-rolled prompt" \
  "$(printf '%s' "$SR" | grep -c 'invoke the `auto-task-code-review` skill' | tr -d ' ')" "1"
expect "shadow: ...and the hand-rolled fallback is explicitly forbidden" \
  "$(printf '%s' "$SR" | grep -c 'Do NOT hand it a hand-rolled review prompt' | tr -d ' ')" "1"
expect "shadow: an unavailable skill records status, never a hand review" \
  "$(printf '%s' "$SR" | grep -c 'record `status: \"unavailable\"`' | tr -d ' ')" "1"
expect "shadow: spawned synchronously like every other Agent" \
  "$(printf '%s' "$SR" | grep -c 'synchronously, per the synchronous-spawn rule at Gate A' | tr -d ' ')" "1"
# READ-ONLY is load-bearing and has no mechanical backstop: general-purpose carries Edit and
# Write, unlike task-execution-verifier's declared tool list. An edit here would move
# reviewed_diff_sha after Phase 4 went clean and block the commit -- a measurement pass must
# not be able to touch the artifact it measures.
expect "shadow: the prompt must forbid edits" \
  "$(printf '%s' "$SR" | grep -c 'prompt MUST forbid edits, in those words' | tr -d ' ')"    "1"
expect "shadow: ...and says why the tool set makes it necessary" \
  "$(printf '%s' "$SR" | grep -c 'carries the full tool set including `Edit`/`Write`' | tr -d ' ')" "1"
expect "shadow: ...and names the reviewed_diff_sha consequence" \
  "$(printf '%s' "$SR" | grep -c 'moves `gates.code_review.reviewed_diff_sha`' | tr -d ' ')" "1"
expect "shadow: missed[] is graded by Phase 4's Step-A test BY REFERENCE" \
  "$(printf '%s' "$SR" | grep -c 'taken by reference so the two cannot drift' | tr -d ' ')" "1"
expect "shadow: it must never block the advance to Gate B" \
  "$(printf '%s' "$SR" | grep -c 'never block the advance to Gate B' | tr -d ' ')" "1"
expect "shadow: bounded to one pass with no loop" \
  "$(printf '%s' "$SR" | grep -c 'one pass, one run, no loop' | tr -d ' ')" "1"
# NEGATIVE CONTROL: no hook may read the object. If one ever does, the measurement has
# become control flow and this assertion is the tripwire.
expect "shadow: NO hook reads state.shadow_review" \
  "$(grep -rl 'shadow_review' "$ROOT/hooks" 2>/dev/null | grep -v 'settings.sh' | wc -l | tr -d ' ')" "0"
expect "shadow: the schema records that no hook reads it" \
  "$(grep -c 'read by \*\*no hook at all\*\*' "$ROOT/skills/auto-task/references/state-schema.md" | tr -d ' ')" "1"

# GATE-B PASS-2 REQUIRED (finding 3), and this block is SHORTER than what it replaces.
# Pass 1 said Step C's comparand ("the previous round") fires on every batch round, since
# the batch trigger has `reopened: 0` by definition. The fix qualified the comparand to
# "the previous round with a reopening finding" -- and pass 2 measured that the fix does
# not deliver: the surviving comparand is always the run's running MINIMUM, so any later
# reopening round fires either way. Round 7's own history entry had already recorded
# "it fires under the old previous-row reading too". So the qualifier was reverted and the
# real defect fixed instead: Step B's promise, which over-claimed. A rule was removed, not
# added. The tautological `conv_fires()` control went with it -- it asserted a function the
# test file defined two lines above, so inverting the shipped prose left it green.
expect "conv: the comparand is plain and unqualified again" \
  "$(printf '%s' "$P4" | grep -c "against the previous round's" | tr -d ' ')" "1"
expect "conv: the reverted qualifier is GONE from the reference" \
  "$(printf '%s' "$P4" | grep -c 'previous round with at least one reopening finding' | tr -d ' ')" "0"
expect "conv: ...and from the spine" \
  "$(grep -cF 'with a reopening finding**' "$SPINEONLY" | tr -d ' ')" "0"
# Step B must no longer promise an ordinary round for a post-batch reopening finding.
expect "conv: Step B no longer over-claims 're-enters normally'" \
  "$(printf '%s' "$P4" | grep -c "re-enters Step A's graded loop normally" | tr -d ' ')" "0"
expect "conv: Step B states the batch pass is NOT exempt from Step C" \
  "$(printf '%s' "$P4" | grep -c 'It is not exempt from Step C either' | tr -d ' ')" "1"
expect "conv: ...and says to expect a surface there, not another round" \
  "$(printf '%s' "$P4" | grep -c 'Expect a surface here rather than another round' | tr -d ' ')" "1"

# CODE-REVIEW ROUND-5 BLOCKER, regression guard. This suite may hold exactly ONE
# `trap ... EXIT`, because bash replaces rather than chains them: the second one added
# silently disabled the fixture-directory cleanup and orphaned $T on every run, while the
# suite kept exiting 0 -- so nothing here or in AC 9 noticed. Counted on non-comment lines
# only, since the explanation above legitimately says the word.
expect "hygiene: this suite installs exactly one EXIT trap" \
  "$(grep -cE "^[[:space:]]*[^#]*\btrap[[:space:]]+'" "$0" | tr -d ' ')" "1"

# CODE-REVIEW ROUND-3 REQUIRED (R2). The graded contract adds ONE Phase-4 user-approval
# surfaces; the Yield-point table enumerated Gate B's equivalents and neither of these. A
# spine-only reader therefore hit the table's strict-case `auto-continue` default, and on
# LIGHT -- where Gate B is skipped -- the gate passed over an unre-checked blocker/required,
# reopening the hole the LIGHT rule was added to close. The row is pinned WITH ITS VALUE,
# for the reason the over-cap row above already records: keying on the left cell alone lets
# the value be inverted to `auto-continue` with zero assertion failures.
expect "yield: the table carries a Phase-4 surface row, value included" \
  "$(grep -cF '| Phase 4 fired convergence test | `"user-approval"` |' "$SPINEONLY" | tr -d ' ')" "1"
expect "yield: the Phase-4 row is not wired to auto-continue" \
  "$(grep -c '| Phase 4 fired convergence test.*auto-continue' "$SPINEONLY" | tr -d ' ')" "0"
# The inline non-negotiable must name the field too, not just the duty -- naming only
# "surfaces on LIGHT" is what let the table's default win for a reader who skipped the
# MANDATORY READ.

echo
printf 'gate-b-loop: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
