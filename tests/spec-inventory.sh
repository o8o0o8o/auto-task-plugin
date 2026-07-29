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
# Re-baseline instead: confirm by eye that the reported lines were changed deliberately,
# then set SPEC_BASE_REF to the commit that introduced the intentional edit, e.g.
#   SPEC_BASE_REF=<new-commit> bash tests/spec-inventory.sh
# and, once satisfied, update the default below in the same commit as the spec edit so the
# guard keeps protecting everything from that point forward.
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
bc = collections.Counter(l for l in base if l.strip())
nc = collections.Counter(l for l in now if l.strip())
missing = [(l, c, nc.get(l, 0)) for l, c in bc.items() if nc.get(l, 0) < c]

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

print("missing=%d duplicated=%d restated=%d base_lines=%d spec_files=%d"
      % (len(missing), len(duplicated), len(restated), sum(bc.values()), 1 + len(refs)))
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
sys.exit(1 if bad else 0)
PYEOF
