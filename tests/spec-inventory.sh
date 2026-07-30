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
