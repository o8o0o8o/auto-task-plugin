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
# LIGHT skips Gate B entirely, so 0 is "no pass permitted" -- NOT "unlimited".
expect "lb_gate_b_cap light is 0 (gate skipped)" "$(lb_gate_b_cap light)"   "0"
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

echo
printf 'gate-b-loop: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
