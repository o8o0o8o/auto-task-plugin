#!/usr/bin/env bash
# spec-inventory.sh — structural guard for the SKILL.md / references/ split.
#
# Two modes:
#   (default)      content conservation + heading uniqueness vs a base commit
#   --directives   every reference file is cited by a MANDATORY READ directive
#                  inside its owning spine section
#
# Why this exists: AC #1 caps the always-loaded spine at 120 KB, which *rewards
# deletion*. Nothing else in the suite would notice a 20 KB section quietly
# reduced to a two-line summary, because the tests grep for phrases, not mass.
# This script is the counterweight.
#
# The carve relocates content BYTE-EXACT, so line-level conservation is both
# simpler and strictly stronger than any body-byte ratio: if every non-blank
# base line still exists (with multiplicity) somewhere across spine +
# references, nothing was dropped, truncated, or paraphrased away.
#
# Exit 0 on success; non-zero with a report on any violation.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPINE="$ROOT/skills/auto-task/SKILL.md"
REFDIR="$ROOT/skills/auto-task/references"
# BASE_REF is the pre-split commit this conservation check diffs against.
#
# MAINTENANCE (read before "fixing" a MISSING report): this check asserts that every
# non-blank line of the pre-split spec still exists somewhere. That is exactly right while
# the split is the newest change, but it also means the FIRST legitimate reword or deletion
# of any base line reports `MISSING` and reddens the suite — the report reads like
# accidental loss when it is an intentional edit.
#
# When that happens, do NOT simply delete the assertion (that retires the guard wholesale).
# There are two sanctioned fixes; prefer the FIRST for an ordinary edit:
#
#   1. RETIRE THE SPECIFIC LINES (preferred). Add each reworded/deleted base line to
#      RETIRED_PREFIXES in the inventory below, with a comment saying why. This forgives
#      exactly the lines you name and keeps every other base line under guard — so a line
#      lost by ACCIDENT in the same commit still reports. The list self-polices: a prefix
#      matching zero or several distinct base lines is reported (BAD RETIRED PREFIX), and an
#      entry that stops corresponding to a real shortfall is reported (STALE RETIRED), so it
#      cannot rot into a blanket exemption.
#   2. RE-BASELINE (only when a whole section is legitimately rewritten, i.e. when a
#      line-by-line list would be longer than the diff). Confirm by eye that the reported
#      lines were changed deliberately, then set SPEC_BASE_REF to the commit that introduced
#      the intentional edit, e.g.
#        SPEC_BASE_REF=<new-commit> bash tests/spec-inventory.sh
#      and, once satisfied, update the default below in the same commit as the spec edit so
#      the guard keeps protecting everything from that point forward. Note the cost: moving
#      the base forgives every line the new base dropped, accidental ones included, which is
#      why option 1 is preferred.
BASE_REF="${SPEC_BASE_REF:-12aa8187e2e6af1261071ee0a68362c96ea264dc}"

mode="${1:-inventory}"

# Owning spine section per reference file. A directive for the file must appear
# inside this section's line range. phase-3-gates.md and phase-6-8-post-pr.md
# are cited from several phase sections; the one named here is the owner and the
# others are legitimate extra citations.
owner_of() {
  case "$1" in
    state-schema.md)      echo '## State file' ;;
    settings.md)          echo '## User settings' ;;
    phase-1-preamble.md)  echo '### Phase 1 — Define (HUMAN GATE)' ;;
    phase-3-gates.md)     echo '### Phase 3 — Self-verify (auto, NO COMMIT)' ;;
    phase-5-handover.md)  echo '### Phase 5 — Handover (auto, SINGLE COMMIT)' ;;
    phase-6-8-post-pr.md) echo '### Phase 6 — PR bot-comment review & conservative fix (auto, GATED, opt-in)' ;;
    phase-9-release.md)   echo '### Phase 9 — Release (auto, GATED, opt-in, ONE additional authored commit)' ;;
    *)                    echo '' ;;
  esac
}

if [ ! -f "$SPINE" ]; then echo "spec-inventory: no spine at $SPINE" >&2; exit 2; fi
if [ ! -d "$REFDIR" ]; then echo "spec-inventory: no references dir at $REFDIR" >&2; exit 2; fi

# ---------------------------------------------------------------- directives
if [ "$mode" = "--directives" ]; then
  found=0; total=0; misplaced=0; report=""
  for f in "$REFDIR"/*.md; do
    b="$(basename "$f")"; total=$((total+1))
    owner="$(owner_of "$b")"
    if [ -z "$owner" ]; then
      report+="  UNKNOWN-OWNER $b (add it to owner_of)\n"; misplaced=$((misplaced+1)); continue
    fi
    dlines="$(grep -n '\*\*MANDATORY READ' "$SPINE" | grep -F "references/$b" | cut -d: -f1)"
    if [ -z "$dlines" ]; then
      report+="  MISSING-DIRECTIVE $b\n"; continue
    fi
    found=$((found+1))
    start="$(grep -nxF "$owner" "$SPINE" | head -1 | cut -d: -f1)"
    if [ -z "$start" ]; then
      report+="  OWNER-SECTION-NOT-FOUND $b ($owner)\n"; misplaced=$((misplaced+1)); continue
    fi
    # Section ends at the next heading of the same-or-higher level.
    case "$owner" in
      '## '*) pat='^## ' ;;
      *)      pat='^#\{2,3\} ' ;;
    esac
    end="$(awk -v s="$start" -v p="$pat" 'NR>s && $0 ~ p {print NR; exit}' "$SPINE")"
    [ -z "$end" ] && end="$(wc -l < "$SPINE")"
    inside=0
    for dl in $dlines; do
      if [ "$dl" -gt "$start" ] && [ "$dl" -lt "$end" ]; then inside=1; break; fi
    done
    if [ "$inside" -ne 1 ]; then
      report+="  DIRECTIVE-OUTSIDE-OWNER $b (owner lines $start-$end, directives at $(echo $dlines | tr '\n' ' '))\n"
      misplaced=$((misplaced+1))
    fi
  done
  echo "directives=$found/$total misplaced=$misplaced"
  if [ "$found" -ne "$total" ] || [ "$misplaced" -ne 0 ]; then
    printf "%b" "$report" >&2; exit 1
  fi
  exit 0
fi

# ---------------------------------------------------------------- inventory
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
if ! git -C "$ROOT" show "$BASE_REF:skills/auto-task/SKILL.md" > "$tmp/base.md" 2>/dev/null; then
  echo "spec-inventory: cannot read $BASE_REF:skills/auto-task/SKILL.md" >&2; exit 2
fi

SPEC_BASE="$tmp/base.md" SPEC_SPINE="$SPINE" SPEC_REFDIR="$REFDIR" python3 <<'PYEOF'
import re, os, sys, glob, collections

base_p = os.environ['SPEC_BASE']
spine_p = os.environ['SPEC_SPINE']
refdir = os.environ['SPEC_REFDIR']

def lines_of(p):
    return open(p, encoding='utf-8').read().split('\n')

def headings(path):
    """Fence-aware ##/### heading lines."""
    fence = False
    out = []
    for l in lines_of(path):
        if l.startswith('```'):
            fence = not fence
            continue
        if fence:
            continue
        if re.match(r'^#{2,3} ', l):
            out.append(l)
    return out

base = lines_of(base_p)
refs = sorted(glob.glob(os.path.join(refdir, '*.md')))
now = lines_of(spine_p)
for f in refs:
    now += lines_of(f)

# 1. LOSS — every non-blank base line must survive, with multiplicity.
#
# RETIRED: base lines a later change deliberately reworded or deleted. Each entry
# names WHY, so a retirement is reviewable in-repo instead of invisible.
#
# This list exists in preference to moving BASE_REF forward past the edit. Both
# silence the MISSING report, but re-baselining silences it for EVERY line the new
# base happens to have dropped — including any lost by accident in the same commit
# — whereas an explicit list forgives exactly the lines named and keeps the other
# ~1,320 under guard. The maintenance note above forbids deleting the assertion;
# this is the narrow alternative to that and to a blanket re-baseline.
#
# Adding an entry is a claim that the line's contract still holds somewhere in
# reworded form (or was intentionally repealed). Do not add one to quiet a report
# you have not read.
# Keys are a stable PREFIX of the retired base line (several run past 800 chars, so
# quoting them whole would be unreadable and would itself rot). Each prefix must
# resolve to exactly ONE distinct base line — enforced below — so a prefix cannot
# quietly widen into a blanket exemption. The value is how many COPIES of that line
# are retired. Only ONE line is genuinely duplicated between the estimate and actuals
# blocks -- the `duration_min` one -- and only the estimate copy changed; the actuals
# `tokens_breakdown` line differs (cache_read/cache_creation vs cache), so it was never
# a collision. The count exists for that single shared line.
RETIRED_PREFIXES = {
  # --- Phase 4 became a GRADED, bounded loop (the Phase-4 sibling of the Gate B
  # --- bounding that retired thirteen lines in 0.29.0) ----------------------
  # Gate B was bounded in 0.29.0 because measured runs went 4-11 passes; the churn
  # then simply moved to Phase 4, which had no reachability grading, no per-round
  # record and no in-loop bound (`enforce-gates.sh` sees only `git commit`, and
  # this loop never reaches one). Measured: `iteration.review` hit 9 and 5 against
  # a STANDARD cap of 4, while the nine-round run's `gate_b.passes[]` holds two
  # rows, both `reopened: 0` — so every one of those rounds was a Phase-4 round.
  # Per-round counts read 6,7,2,3,1,3 (non-convergent) while the *reachable*
  # findings were decaying, because README figures and missing test assertions
  # were labelled at the same severity as security holes.
  #
  # Each line below is replaced, in this same commit, by a graded equivalent that
  # states the contract at least as strongly: the label no longer decides control
  # flow (the Gate B (a)/(b)/(c) reopen test does, fail-closed on a missing `ac:`),
  # a non-reopening blocker/required is DEFERRED and fixed in one batch rather
  # than buying a full review cycle, and every round is recorded so the
  # convergence test and the budget ack's evidence requirement are satisfiable.
  # Full contract: `references/phase-3-gates.md` ("phase-4-round-mechanics").
  #
  # The three-step resolution list — now grades, records, and routes the batch.
  '1. Parse the findings into Blockers / Required / Follow-ups.': 1,
  '2. If only Follow-ups: park them in `state.followups`, set the gate,': 1,
  '3. If any Blocker or Required: apply the fix(es), re-run `/auto-task-verify`': 1,
  # The "Categorize findings" block: three label definitions that the reachability
  # test supersedes as the control-flow basis. The labels still exist (the review
  # skill assigns them); they simply no longer decide whether a round is spent.
  'Categorize findings:': 1,
  '- **Blockers** — bugs, regressions, security issues, plan violations.': 1,
  '- **Required fixes** — style/correctness issues the project conventions': 1,
  '- **Follow-ups** — nice-to-haves, future improvements, out-of-scope ideas.': 1,
  # The unconditional per-finding fix instruction, replaced by the graded ladder
  # (reopening -> fix now and bump the counter; deferred -> batch).
  'For each blocker and required fix: invoke `/auto-task-fix`': 1,
  # Both exit conditions: the first keyed on "only follow-ups" (a label reading),
  # now keyed on zero REOPENING findings plus a spent/empty `deferred[]`; the
  # second now also names the fired convergence test as a surfacing trigger.
  "- Reviewer's latest pass produces only follow-ups → set `gates.code_review = { passed: true,": 1,
  '- Loop rule triggers (no progress / out-of-scope / blocker / flakiness)': 1,
  # The loop's own exit condition, keyed on the LABEL ("only follow-ups, no blockers, no
  # required fixes"). Under the graded contract a round can legitimately exit with a
  # deferred-and-batch-fixed or parked `blocker`/`required`, so this predicate both
  # excluded a legitimate exit and licensed the retired label-driven one — Gate A round 3
  # found it contradicting the Phase-4 bullet in the same file. Replaced by the graded
  # form ("zero reopening findings and an empty or spent `deferred[]`"), which states the
  # exit at least as strongly and now agrees with clause 5 and the Phase-4 section.
  '- The most recent `auto-task-code-review` produces only follow-ups': 1,
  # CODE-REVIEW ROUND-3 BLOCKER (B1). The SEVENTH site stating the Phase-4 exit, and the
  # most-read one: the always-loaded top-of-file NON-YIELDING CONTRACT. It stated the exit
  # in LABEL terms ("no Blockers/Required"), which is STRICTER than the graded exit in the
  # same file, so a model following it keeps re-reviewing while a deferred `required`
  # exists — reinstating the exact churn this change removes. Two lines above it, the
  # verifier-agent bullet already carried the equivalent Gate B caveat from 0.29.0, so the
  # omission was the same "fix landed in fewer sites than state the rule" class this run
  # hit four rounds running. Replaced by the graded form, which states the exit at least
  # as strongly; the new property guard in tests/gate-b-loop.test.sh now fails on ANY
  # spine line that gates a Phase-4 advance on label counts, so an eighth site cannot
  # reappear silently.
  '- A clean `auto-task-code-review` pass (no Blockers/Required) advances to Gate B': 1,
  # The `reviewed_diff_sha` formula: relocated to `references/state-schema.md`
  # (`gates.code_review` notes) so the spine, Gate B's `verified_diff_sha` and the
  # staleness hook all cite ONE copy instead of three. Reworded there, not dropped
  # — every clause survives, including the flag-parity requirement.
  '  - **`reviewed_diff_sha`** pins the exact diff this clean pass covered': 1,
  # CODE-REVIEW ROUND-3 REQUIRED (R1), deferred then fixed in the batch. The relocation
  # above left the staleness paragraph pointing at the flags' OLD home — "the pinned flags
  # are listed under Phase 4 `reviewed_diff_sha`" — where Phase 4 now carries only a
  # pointer of its own, so the reader got a redirect instead of the flags and the spine
  # held zero copies (`grep -cF -- '--diff-algorithm=myers' SKILL.md` → 0). Re-pointed at
  # `references/state-schema.md`, the one place the formula now lives. Pointer text only;
  # every clause of the staleness rule is unchanged.
  'Beyond the booleans, the hook enforces two further things. The first is **review staleness**': 1,
  # GATE-B PASS-3 (finding 4). SKILL.md:28 and :76 stopped restating the Phase-4 exit
  # predicate and now DEFER to it -- the structural fix for a rule that had drifted across
  # seven sites. But the block they defer to lists TWO bullets, the second of which is
  # "STOP and surface", so an unqualified "meets Phase 4's exit conditions ... Continue"
  # could be read as advancing on the very round the contract exists to surface. The heading
  # now names the first bullet as THE ADVANCE CONDITION and the deferrals point at that,
  # making the referent single-valued. Heading text only; neither exit condition changed.
  'Exit conditions for this phase:': 1,
  # The `gates.code_review` schema line: gained `rounds` and `deferred`, and wraps
  # onto two lines. Additive only; no existing field changed.
  '    "code_review": { "passed": false, "tool": null, "clean_pass_after_last_fix": false, "reviewed_diff_sha": null, "at": null, "evidence": null },': 1,
  # The loop-count definition: `iteration.review` now counts Phase-4 rounds that
  # REOPEN, not every round. The replacement states the same max() rule and adds
  # the narrowing, so the budget still bounds the same quantity (fix volume).
  '**Loop count** = `max(iteration.fix, iteration.review)` — and it must be both counters': 1,
  # --- byte budget: two Phase-4 anti-stall restatements compressed -----------
  # Not a contract change. The Phase-4 section duplicated the top-of-file
  # NON-YIELDING CONTRACT nearly verbatim; the spine has a HARD 122,880 B ceiling
  # (`tests/enforcement-spine.test.sh`) and 47 bytes of headroom, so the graded
  # contract above had to be paid for. Every clause of both lines is still stated
  # in the spine: the re-invoke cue by the "Do not stop" paragraph and step 3, and
  # the Phase-4 "Mechanical backstop" by the identical top-of-file section plus
  # the Yield-point contract's own no-speculative-`user-approval` rule. The
  # replacements point at those, so nothing became unreachable.
  'If the latest skill output contains words like "needs one more fix"': 1,
  '**Mechanical backstop.** The Stop hook reads `STATE.json` on every turn-end.': 1,
  '**Do not stop, summarize for the user, ask permission, or wait.**': 1,
  # --- intent-add before every diff-sha re-pin (RELIABILITY-AUDIT item 1) ----
  # The merge-conflict finalize is a `reviewed_diff_sha` re-pin site like the
  # Phase-6 bot-fix one, but it carried no intent-add instruction: a resolution
  # that CREATES a file (split-out module, regenerated artifact) left that path
  # untracked, so it entered `git diff <base>` only at the finalize commit —
  # moving the hash after it was pinned and hard-blocking the very
  # `git commit --no-edit` the line mandates. The replacement inserts that
  # instruction mid-sentence and keeps every other clause verbatim, so it states
  # the contract strictly more strongly than the line it retires.
  '       - **Mandatory re-check BEFORE finalizing the merge commit:**': 1,
  # --- estimate.sh output-token recalibration -------------------------------
  # `estimate.sh` stopped emitting a cache-inclusive `tokens_total` and a
  # `tokens_breakdown` it could not honestly predict (measured input ~1k;
  # measured cache_read swings 189x-467x of output). The estimate/actual token
  # comparison is now output-vs-output. Every line below is the OLD total-shaped
  # wording, replaced in the same commit by an output-shaped equivalent that
  # states the contract at least as strongly as the line it retires.
  #
  # state.estimate schema block — one of two identical lines; the actuals copy
  # keeps tokens_total, because the ACTUAL total is a real measurement.
  '    "duration_min": 0, "tokens_total": 0,': 1,
  '    "tokens_breakdown": { "input": 0, "output": 0, "cache": 0 },': 1,
  # Phase-1 estimate prose: the field list it names no longer exists.
  'Write the parsed result to `state.estimate` (`duration_min`, `tokens_total`, `tokens_breakdown`': 1,
  # Phase-5 "Estimate vs actual" table: the token row became output-vs-output and
  # gained an un-compared total row; the caveat gained the sub-agent exclusion.
  '   | Wall-clock (min) | <state.estimate.duration_min>': 1,
  '   | Tokens (total)   | <state.estimate.tokens_total>': 1,
  '   Token scope caveat: run-scoped via `--since`': 1,
  # Quality panel + CONTEXT.md template: both named the ratio without saying which
  # token figure it divides, which is the ambiguity that allowed the unit error.
  '   - **Delivery reliability:** time <est_time_ratio>× · tokens <est_token_ratio>×': 1,
  '   <compact table from state.estimate/actuals: metric | estimated | actual | actual/est': 1,
  '   - **Quality signals (NOT a score).** Assemble `state.quality`': 1,
  # settings.md: the payload schema_version claim moved 4 -> 5 with the est_tokens
  # semantics change.
  "**Remote telemetry (opt-in, off by default).** The endpoint + ingest token": 1,

  # --- duration is measured, not narrated -----------------------------------
  # The run duration used to be derived from the first and last
  # `state.history[].at` strings, which the model writes without access to a
  # clock. It now comes from a hook-stamped sidecar (`hooks/stamp-run-clock.sh` +
  # `hooks/lib/run-clock.sh`) and a span that is negative or over 12h is rejected
  # to `null`. Both lines below are the OLD history-derived wording, replaced in
  # the same commit by a clock-derived equivalent that states the contract more
  # strongly than the line it retires (each now also names the three-state
  # verdict, which is what keeps a rejection from collapsing into the fallback).
  #
  # Phase-5 actuals step: it told the orchestrator to recompute the duration with
  # "the same first→last history-timestamp formula record-outcome.sh uses" — the
  # narration this change removes.
  '   - **Actuals.** Locate `hooks/token-usage.sh` (three-probe pattern)': 1,
  # state-schema null-not-zero contract: it was scoped to "a measurement could not
  # be taken", which does not cover a measurement that WAS taken and rejected, and
  # it predates `duration_min` becoming nullable.
  '**Run-metrics objects (`estimate`, `actuals`, `quality`, `checks`).**': 1,

  # --- the Gate B adversarial loop is bounded --------------------------------
  # Gate B did not converge. Measured across seven completed runs it ran 4-11
  # adversarial passes each, required-finding counts never decayed (one HEAVY run
  # went 3,2,3,3,3,2,3,4,0 over nine passes), blockers first appeared at passes 3
  # and 5 rather than pass 1 -- i.e. each pass's fixes manufactured the next
  # pass's findings -- and three of the seven runs ended by human fiat rather
  # than by a clean pass. Two properties made it unbounded: a finding's
  # SELF-ASSIGNED SEVERITY drove control flow regardless of whether it touched an
  # Acceptance Criterion, and nothing counted the passes. Every line retired
  # below is the OLD unbounded wording, replaced in the same commit by a rule
  # that states the contract strictly more strongly than the line it retires.
  #
  # Loop-rule clause 5: the old test was "two consecutive review rounds producing
  # zero blockers and zero required findings". That is unreachable exactly where
  # the churn is -- Gate B exits on the FIRST clean pass, so a second consecutive
  # clean round is never observed, and any non-clean round resets the streak. It
  # fired ONCE across all seven runs, in a docs re-gate. It is also arithmetically
  # unreachable under a Gate B pass cap of 2 (STANDARD). The replacement fires on
  # a single non-DECREASING round, which is observable in-loop on both tiers.
  '5. **Returns have not diminished** — **two consecutive review rounds producing zero blockers': 1,
  # Effort-tiers table: the STANDARD and HEAVY rows' `Gate B` cell said only "run"
  # / "run, with cross-check pass" and named no pass bound. Both now carry the
  # per-tier pass cap (2 / 3), documenting `lb_gate_b_cap` in `loop-budget.sh`
  # rather than duplicating it. LIGHT is unchanged -- it skips Gate B entirely.
  '| STANDARD | 3-5   | types + unit + lint                              | 4            | run  ': 1,
  '| HEAVY    | 6-8   | types + unit + lint + build (+ e2e if touched)   | 6            | run, w': 1,
  # State schema: `gates.gate_b` gained the pass-accounting fields (`passes[]`,
  # `verified_diff_sha`, `allowance_acked`) and `gates.loop_budget` gained
  # `park_non_blocking`. Both are additive and absent-tolerant, so the retired
  # lines' contract is preserved in full and only extended.
  '    "gate_b":      { "passed": false, "at": null, "evidence": null, "skipped_reason": null },': 1,
  '    "loop_budget": { "acked_through": 0, "acked_at": null, "reason": null }': 1,
  # Gate B resolution ladder: it resolved BY SEVERITY, so any blocker/required
  # reopened Phase 4 unconditionally and loop-rule clause 2 (in-scope = maps to an
  # approved AC) was never applied at this gate. It now resolves by AC IMPACT --
  # reopen only on (a) an AC breach, (b) a runtime-reachable regression/bypass, or
  # (c) a security/data-loss path; park everything else whatever its label -- with
  # a fail-CLOSED default when the finding's `ac:` field is missing, so the
  # replacement can only ever do MORE work than the retired rule, never less.
  'Resolve by severity:': 1,
  '- Any **blocker** or **required** finding → feed back to Phase 4 with the finding as a new fix task;': 1,
  # The three RE-GATE sites each restated the old ladder inside their re-gate step:
  # "only on a clean adversarial pass (a Blocker/Required there loops back to
  # fixing, exactly as in the main pipeline)". Once the main pipeline stopped
  # reopening on a label, two of those parenthetical parity claims became FALSE and
  # the third contradicted the new rule outright -- a docs-only `required` at a
  # re-gate now PARKS per Step 2 while these lines still said it loops back to
  # fixing. Found by Gate A round 3. Each replacement states the ladder by reference
  # to the Step-2 AC-impact test, and is strictly more specific than the line it
  # retires.
  #
  # ROUTING DIFFERS BY SITE, and the phase-9 entry must not be read as claiming
  # otherwise (Gate A round 4 caught the first attempt doing exactly that): at the
  # docs and bot-fix re-gates a finding that MEETS the test loops back to fixing,
  # while phase 9 SURFACES instead -- that phase's own adjacent rule is "SURFACE --
  # do not loop and do not auto-revert". So for phase 9 the parity restored is the
  # ladder (what counts as a finding worth acting on), not the routing.
  '   6. **Re-pass the gates (MANDATORY) — now that every docs path is visible to `git diff`.**': 1,
  '**3. Apply the actionable fixes (ONE bounded round).** For each actionable finding:': 1,
  '6. **Re-pass the gates (MANDATORY).** The bump + changelog are new authored bytes added after the review went clean,': 1,
  # Phase 9's SURFACE rule resolved the re-run Gate B BY LABEL ("A Blocker/Required
  # ... means the release diff itself is not shippable"), so a `required` the new
  # ladder parks would clear the gate at step 6 and simultaneously fail the release
  # here -- one pass, two outcomes, in adjacent lines. Gate A round 4. The
  # replacement routes on the Step-2 AC-impact test and says explicitly that a
  # failing-the-test finding does not fail the release.
  '   - **If either re-gate does not come back clean, SURFACE — do not loop and do not auto-revert.**': 1,
  # Gate B's spawn-input bullet handed EVERY pass "the full diff vs. base", which
  # contradicted Step 1's delta-scoping the moment that step became executable --
  # pass N would have re-read all N-1 rounds of fixes, the unbounded search surface
  # the cap exists to close. Found by the Gate B adversarial pass. The replacement
  # keeps the whole bullet verbatim for pass 1 and states the delta for later ones,
  # so it is strictly more specific than the line it retires.
  '- The full diff vs. base (`git diff <base>` — the uncommitted working-tree diff;': 1,
  # The anti-stall contract's one-line summary of both verifier gates still said
  # "Apply fixes (Blocker/Required) or park (Follow-up)" -- the pre-change mapping,
  # sitting in the ALWAYS-LOADED spine alongside the new AC-gated ladder with no
  # precedence between them. Gate A round 4 (ranked observation). The replacement
  # defers to each gate's own ladder rather than restating either.
  '- A verifier agent (`task-execution-verifier` at Gate A or Gate B) returning findings is **INPUT**.': 1,
}

bc = collections.Counter(l for l in base if l.strip())
nc = collections.Counter(l for l in now if l.strip())

# Resolve each prefix to exactly one distinct base line. A prefix matching zero
# lines is stale (the base moved); matching several is too broad to be a named
# retirement. Both are reported rather than silently tolerated.
RETIRED = {}
bad_prefixes = []
for pref, n in RETIRED_PREFIXES.items():
    hits = [l for l in bc if l.startswith(pref)]
    if len(hits) != 1:
        bad_prefixes.append((pref, len(hits)))
        continue
    RETIRED[hits[0]] = n

# A retired line is forgiven up to its recorded multiplicity. Anything beyond that
# still reports, so retiring one copy of a duplicated line cannot hide the others.
missing = [(l, c, nc.get(l, 0)) for l, c in bc.items()
           if c - nc.get(l, 0) - RETIRED.get(l, 0) > 0]

# A RETIRED entry that no longer corresponds to a real shortfall is dead weight —
# the line came back, or the entry was always wrong. Report it so the list cannot
# rot into a permanent blanket exemption.
stale_retired = [l for l, n in RETIRED.items() if bc.get(l, 0) - nc.get(l, 0) < n]

# 2. DUPLICATION — a base heading must own exactly one home. Restating one
#    would flip summed spec_count assertions from n to n+1.
bh = collections.Counter(headings(base_p))
nh = collections.Counter(headings(spine_p))
for f in refs:
    nh.update(headings(f))
duplicated = [(h, nh.get(h, 0), bh[h]) for h in bh if nh.get(h, 0) > bh[h]]

# 3. CROSS-BOUNDARY RESTATEMENT — a substantive line must not appear in BOTH the
#    spine and a reference. The spine's job is to summarize and point; restating
#    verbatim prose inflates summed spec_count assertions from n to n+1 and, worse,
#    makes a first-match positional anchor (spec_line / spec_window / an awk region
#    slice) resolve to the SUMMARY instead of the real contract. That is not
#    hypothetical: it is exactly how the co-location check first failed here.
#    Threshold: >=40 chars, so structural noise ("---", short list markers) is
#    ignored while real prose and table rows are caught.
spine_sub = set(l.strip() for l in lines_of(spine_p) if len(l.strip()) >= 40)
restated = []
for f in refs:
    for l in lines_of(f):
        t = l.strip()
        if len(t) >= 40 and t in spine_sub:
            restated.append((os.path.basename(f), t))

print("missing=%d retired=%d duplicated=%d restated=%d base_lines=%d spec_files=%d"
      % (len(missing), len(RETIRED), len(duplicated), len(restated), sum(bc.values()), 1 + len(refs)))
bad = False
for l, want, got in missing[:40]:
    print("  MISSING (want %d, got %d): %s" % (want, got, l[:100]), file=sys.stderr)
    bad = True
for h, got, want in duplicated:
    print("  DUPLICATED (x%d, base has %d): %s" % (got, want, h[:100]), file=sys.stderr)
    bad = True
for f, t in restated[:40]:
    print("  RESTATED (in spine and %s): %s" % (f, t[:100]), file=sys.stderr)
    bad = True
for l in stale_retired:
    print("  STALE RETIRED (entry no longer matches a real shortfall; remove it): %s"
          % l[:100], file=sys.stderr)
    bad = True
for pref, n in bad_prefixes:
    print("  BAD RETIRED PREFIX (matched %d distinct base lines, want exactly 1): %s"
          % (n, pref[:100]), file=sys.stderr)
    bad = True
sys.exit(1 if bad else 0)
PYEOF
