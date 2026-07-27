#!/usr/bin/env bash
# build-release-notes.sh — generate `.claude-plugin/release-notes.json` from
# `CHANGELOG.md`. DEV-ONLY: a maintainer tool, run at release time. It is not a
# hook, is never invoked by a session, and ships to users only as inert bytes.
#
# WHY THIS EXISTS
#   Users deserve a one-line "what changed" when the plugin updates. CHANGELOG.md
#   already carries that prose, but it is 100 KB+ of markdown — too big to fetch
#   on the update-check path and too costly to parse in a SessionStart hook. So
#   the changelog stays the single source of truth and this script distills it
#   into a small map the runtime surfaces can read directly:
#
#     { "0.24.0": "Tightens both main-sync points …", "0.23.0": "…" }
#
#   Consumer: `hooks/release-notes.sh`, the SessionStart hook that shows what you
#   just got. It reads the bundled copy of this file and makes no network request.
#
# USER-VISIBLE CHANGES ONLY
#   A release with nothing users can observe must not appear here. That judgment
#   lives in CHANGELOG.md as `<!-- release-notes: skip -->` placed as the FIRST
#   content of the release block, directly under its `## [X.Y.Z]` heading (or
#   `<!-- release-notes: text -->` there to override the wording). Position is part
#   of the contract, not a detail: written below the lead paragraph the marker is an
#   example rather than an instruction, and this script refuses to write until it
#   moves. Saying only "inside the block" here is what let a skip-marked internal
#   release publish silently.
#   Extraction rules — including the include-by-default rationale — are
#   documented in `hooks/lib/changelog-notes.sh`, which this script sources so
#   the generator and its drift test cannot disagree.
#
# RELEASE CHECKLIST
#   Run this whenever CHANGELOG.md gains a release entry, and commit the result
#   alongside it. `tests/release-notes-sync.test.sh` fails if the committed file
#   and a fresh generation disagree.
#
# Usage:
#   scripts/build-release-notes.sh              # write .claude-plugin/release-notes.json
#   scripts/build-release-notes.sh --check      # exit 3 if the file is stale (no write)
#   scripts/build-release-notes.sh --stdout     # print the JSON, write nothing
#   scripts/build-release-notes.sh --changelog <path> --out <path>
#
# Env: RELEASE_NOTES_KEEP (default 10) how many newest releases to keep
#      CN_MAX_LEN         (default 300) per-note character cap
#
# Exit: 0 ok / 2 usage or missing dependency / 3 --check found drift.

set -uo pipefail

die() { printf 'build-release-notes: %s\n' "$1" >&2; exit "${2:-2}"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)" \
  || die "cannot locate repo root"

CHANGELOG="$ROOT/CHANGELOG.md"
OUT="$ROOT/.claude-plugin/release-notes.json"
MODE="write"

while [ $# -gt 0 ]; do
  case "$1" in
    --check)     MODE="check" ;;
    --stdout)    MODE="stdout" ;;
    --changelog) shift; CHANGELOG="${1:-}" ;;
    --out)       shift; OUT="${1:-}" ;;
    -h|--help)   sed -n '1,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           die "unknown argument '$1'" ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || die "jq is required"
# Regular file, not merely readable: a FIFO is readable and awk would block on it
# forever. Dev-time, so this hangs a maintainer's terminal rather than a session - but it
# is the same class as the FIFO stamp and the FIFO notes file, and all three are fixed
# together rather than one cell at a time.
[ -f "$CHANGELOG" ] && [ -r "$CHANGELOG" ] \
  || die "changelog is not a readable regular file: $CHANGELOG"

# Guarded like every other path this script opens. `.` on a FIFO blocks until a writer
# appears, and this site had NO test at all - which is why the round-26 sweep missed it:
# that sweep grepped for existing `[ -r "` guards, and a grep for guards can only find
# sites that already have one. A site with no guard is structurally invisible to it. The
# lesson is method, not code: enumerate the OPERATIONS (open, source, write), not the
# guards. The hook guards its own `.` of the renderer lib for exactly this reason.
_CN_LIB="$ROOT/hooks/lib/changelog-notes.sh"
[ -f "$_CN_LIB" ] && [ -r "$_CN_LIB" ] \
  || die "hooks/lib/changelog-notes.sh is not a readable regular file: $_CN_LIB"
# shellcheck source=../hooks/lib/changelog-notes.sh
. "$_CN_LIB" || die "cannot source hooks/lib/changelog-notes.sh"

keep="${RELEASE_NOTES_KEEP:-10}"
case "$keep" in ''|*[!0-9]*) die "RELEASE_NOTES_KEEP must be a non-negative integer" ;; esac

# cn_extract_all emits newest-first in document order, so slicing the head keeps
# the newest. The `keep` truncation happens INSIDE jq, deliberately not via
# `head -n`: under `set -o pipefail`, `head` exiting early makes awk die of
# SIGPIPE once the changelog outgrows the pipe buffer, `pipefail` surfaces 141,
# and the whole generator fails with a misleading "extraction failed". That was a
# live time bomb — it triggered at ~60 releases with 45 already present.
#
# A JSON OBJECT (not an array) is the shape both runtime readers expect: they look
# up a version key directly, and `jq -r --arg v "$V" '.[$v]'` needs an object.
# Extraction runs on its own (not inside the jq pipeline) so its exit code is
# distinguishable. Return 3 means a release block was truncated by an unterminated
# comment or fence — refuse to write rather than emit a notes file that is quietly
# missing a release, which is the failure this feature exists to prevent and which
# the drift test cannot see (absent from both files reads as consistent).
notes_tsv="$(cn_extract_all "$CHANGELOG")"
extract_rc=$?
case "$extract_rc" in
  0) ;;
  3) die "CHANGELOG.md has a malformed release entry — see the changelog-notes line(s) above, which name the release and the problem. Fix it and re-run; writing anyway could leave a user-visible release with no note." ;;
  *) die "extraction failed (exit $extract_rc)" ;;
esac

notes_json="$(
  printf '%s\n' "$notes_tsv" \
    | jq -R -s --argjson keep "$keep" '
        split("\n")
        | map(select(length > 0) | split("\t") | select(length >= 2))
        | .[0:$keep]
        | map({ key: .[0], value: (.[1:] | join("\t")) })
        | from_entries
      '
)" || die "extraction failed"

printf '%s' "$notes_json" | jq -e 'type == "object"' >/dev/null 2>&1 \
  || die "generated payload is not a JSON object"

# Refuse to write an EMPTY notes file. The guard this replaces tested
# `[ -n "$notes_json" ]`, which could never fire: `from_entries` on an empty row set
# always returns the two-byte string `{}`, so a changelog the extractor finds no
# `## [X.Y.Z]` heading in - a mistyped --changelog path that resolves to some other
# real file, a heading convention that drifts to `## v0.25.0`, a truncated
# CHANGELOG.md - sailed straight through and CLOBBERED a good notes file with `{}`,
# exit 0, reporting "wrote … (0 releases, newest )". That is the maximal instance of
# the one thing this generator promises never to do. It also has a runtime tail: with
# an empty artifact the hook takes its valid-file-nothing-in-range path, which
# ADVANCES the stamp, so every release notice is consumed rather than deferred.
#
# Counted, not string-tested, because the count is the property that matters. Zero
# releases is always a broken input: this repo cannot reach 0 legitimately (the drift
# test asserts 10), and no caller wants an empty file written on purpose.
release_count="$(printf '%s' "$notes_json" | jq 'length')"
# The message names BOTH causes and asserts neither. Zero releases is also reachable
# with perfectly correct headings - when every release in the file is skip-marked - and
# a message blaming a missing heading would send the maintainer looking in the wrong
# place. Third time in this run that a diagnostic named a cause it could not know, so
# the rule is now explicit: refuse confidently, attribute tentatively.
[ "${release_count:-0}" -gt 0 ] 2>/dev/null \
  || die "extraction produced 0 releases from $CHANGELOG. Either no '## [X.Y.Z]' heading was found (wrong --changelog path, or the heading style changed), or every release in the file is marked <!-- release-notes: skip -->. Refusing to write $OUT, which would replace real notes with an empty object"

# ---- the SHIPPED release must actually be covered -------------------------------
# The count guard above only catches ZERO releases. One mistyped heading catches
# nothing: `##  [0.26.0]` (two spaces), `##[0.26.0]`, `## 0.26.0`, `### [0.26.0]`,
# `## [v0.26.0]` and `## [0.26]` all fail the strict heading rule, so that release is
# swallowed as preamble and dropped - 9 releases instead of 10, count guard satisfied,
# and the drift test CANNOT see it because a release absent from both the committed
# file and a fresh generation reads as perfectly consistent. The user then updates into
# exactly that version, the renderer finds no key for it, and the hook advances the
# stamp: the notice is consumed and the release ships with no notes at all, forever.
#
# "The heading did not parse" was the one member of the extractor's family of
# maintainer-error guards left silent - duplicate heading, unterminated fence or
# comment, mispositioned marker, near-miss payload and empty block all report.
#
# The cross-check is cheap because of the release checklist's own order: step 2 bumps
# plugin.json, step 3 runs this script, so the version being shipped is already on
# disk and this script simply never read it. Requiring that version to be either
# PRESENT in the notes or explicitly SKIP-marked also catches a forgotten changelog
# entry and a note that flattened to nothing, in one check.
#
# Scoped to the repo's own changelog: a --changelog fixture has no relationship to
# plugin.json, so the check would be meaningless (and would red every test).
# `-ef` (same device + inode), not string equality. A raw comparison let any other
# spelling of the same file disable the check - `--changelog CHANGELOG.md`,
# `--changelog ./CHANGELOG.md`, an absolute path with a `/./` in it - while `--out`
# still defaulted to the real artifact, so the generator happily wrote the shipping
# notes file with the newest release missing and reported success. The fixture escape
# hatch is meant to be "a DIFFERENT changelog", not "a different way to type this one".
if [ "$CHANGELOG" -ef "$ROOT/CHANGELOG.md" ] \
   && [ -f "$ROOT/.claude-plugin/plugin.json" ] && [ -r "$ROOT/.claude-plugin/plugin.json" ]; then
  shipped="$(jq -r '.version // empty' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null || true)"
  if [ -n "$shipped" ]; then
    # Skip-marked is checked with the SAME strict whole-line, first-content-agnostic
    # shape the extractor honours, restricted to the shipped release's own block.
    # CRLF is stripped FIRST, exactly as cn_extract_all does. Without it the
    # `-->[ \t]*$` anchor could never match `-->\r`, so on a core.autocrlf=true
    # checkout a legitimately skip-marked shipped release (the 0.21.0 / 0.17.1 shape)
    # was reported as absent while the extractor - which DOES strip CR - correctly
    # omitted it. Both halves right, their conjunction a hard refusal on a valid
    # release, with a message asserting three causes that were all false. This is a
    # second, independent awk program over the same file, so it had to inherit the
    # normalisation rather than assume it; there is no .gitattributes here.
    shipped_skipped="$(awk -v want="## [$shipped]" '
      { sub(/\r$/, "") }
      index($0, want) == 1 { inblk = 1; next }
      inblk && /^## \[/ { exit }
      inblk && /^[ \t]*<!--[ \t]*release-notes:[ \t]*skip[ \t]*-->[ \t]*$/ { found = 1 }
      END { print (found ? "yes" : "no") }
    ' "$CHANGELOG")"
    shipped_present="$(printf '%s' "$notes_json" | jq -r --arg v "$shipped" 'has($v)')"
    if [ "$shipped_present" != "true" ] && [ "$shipped_skipped" != "yes" ]; then
      die "the version being shipped ($shipped, from .claude-plugin/plugin.json) has no note and no skip marker. Either its '## [$shipped]' heading is missing or mistyped (it must match '## [X.Y.Z]' exactly - no extra spaces, no leading v, three components), or CHANGELOG.md has no entry for it yet, or its entry produced no usable note. Refusing to write $OUT, which would ship $shipped with no release notes at all"
    fi
  fi
fi

# Pretty-printed with a trailing newline so the committed file is diff-friendly
# and byte-stable across runs (the drift test compares bytes).
rendered="$(printf '%s' "$notes_json" | jq -S '.')" || die "render failed"

case "$MODE" in
  stdout)
    printf '%s\n' "$rendered"
    ;;
  check)
    if [ ! -f "$OUT" ]; then
      printf 'build-release-notes: %s is missing — run scripts/build-release-notes.sh\n' "$OUT" >&2
      exit 3
    fi
    if ! printf '%s\n' "$rendered" | diff -q - "$OUT" >/dev/null 2>&1; then
      printf 'build-release-notes: %s is stale — run scripts/build-release-notes.sh\n' "$OUT" >&2
      exit 3
    fi
    printf 'build-release-notes: %s is up to date (%s releases)\n' \
      "$OUT" "$(printf '%s' "$rendered" | jq 'length')"
    ;;
  write)
    # Refuse to write to an existing non-regular path. `> "$OUT"` on a FIFO blocks until a
    # reader appears; on a character device it would write into whatever that device is.
    if [ -e "$OUT" ] && [ ! -f "$OUT" ]; then
      die "refusing to write $OUT: it exists but is not a regular file"
    fi
    mkdir -p "$(dirname "$OUT")" || die "cannot create $(dirname "$OUT")"
    printf '%s\n' "$rendered" > "$OUT" || die "cannot write $OUT"
    # Newest version comes from the already-extracted TSV, not a second
    # `cn_extract_all … | head -1`. That re-ran the whole extraction just to print
    # one word, and re-introduced the very `pipefail` + `head` shape removed from
    # the pipeline above — harmless here only by accident of being a printf
    # argument. Reusing $notes_tsv is both cheaper and free of the pattern.
    printf 'build-release-notes: wrote %s (%s releases, newest %s)\n' \
      "$OUT" \
      "$(printf '%s' "$rendered" | jq 'length')" \
      "$(printf '%s\n' "$notes_tsv" | awk -F'\t' 'NR==1 { print $1; exit }')"
    ;;
esac
exit 0
