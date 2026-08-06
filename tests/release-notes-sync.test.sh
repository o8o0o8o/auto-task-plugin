#!/usr/bin/env bash
# Drift guard + unit test for scripts/build-release-notes.sh and
# hooks/lib/changelog-notes.sh — the CHANGELOG.md -> release-notes.json pipeline.
#
# THE LOAD-BEARING ASSERTION is the first one: the committed
# `.claude-plugin/release-notes.json` must be byte-identical to a fresh generation
# from the current CHANGELOG.md. That is what stops a release entry from shipping
# without the note users are supposed to see. This repo has no CI, so this test IS
# the enforcement — see README "Releasing (maintainers)".
#
# Also covers the curation rules that make the notes user-visible-only: the
# `<!-- release-notes: skip -->` marker, include-by-default for unmarked releases,
# the `<!-- release-notes: text -->` override, the lead-paragraph extraction, the
# first-bullet fallback for releases that have no lead paragraph, and the caps
# (newest N releases, per-note length).
#
# Usage: tests/release-notes-sync.test.sh   (requires jq)
# Exit 0 = all assertions passed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
GEN="$REPO/scripts/build-release-notes.sh"
LIB="$REPO/hooks/lib/changelog-notes.sh"
COMMITTED="$REPO/.claude-plugin/release-notes.json"
CHANGELOG="$REPO/CHANGELOG.md"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[ -f "$GEN" ] || { echo "FAIL: $GEN not found"; exit 1; }
[ -x "$GEN" ] || { echo "FAIL: $GEN is not executable"; exit 1; }
[ -r "$LIB" ] || { echo "FAIL: $LIB not found"; exit 1; }

PASS=0; FAIL=0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

expect_eq(){ # name got want
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-56s got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }
expect_contains(){ # name haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-56s missing=%s\n       got: %s\n' "$1" "$3" "$2"; fi; }

echo "== drift guard: committed notes match a fresh generation =="

if [ ! -f "$COMMITTED" ]; then
  FAIL=$((FAIL+1))
  printf '  FAIL  %s\n' "committed release-notes.json exists"
  printf '        run: scripts/build-release-notes.sh\n'
else
  PASS=$((PASS+1)); printf '  PASS  %s\n' "committed release-notes.json exists"

  bash "$GEN" --stdout > "$T/fresh.json" 2>"$T/gen.err"
  gen_rc=$?
  expect_eq "generator succeeds on the real CHANGELOG" "$gen_rc" "0"

  if diff -u "$COMMITTED" "$T/fresh.json" > "$T/drift.diff" 2>&1; then
    PASS=$((PASS+1)); printf '  PASS  %s\n' "committed notes are byte-identical to a fresh generation"
  else
    FAIL=$((FAIL+1))
    printf '  FAIL  %s\n' "committed notes are byte-identical to a fresh generation"
    printf '        CHANGELOG.md and .claude-plugin/release-notes.json have drifted.\n'
    printf '        FIX: run  scripts/build-release-notes.sh  and commit the result.\n'
    sed -n '1,20p' "$T/drift.diff" | sed 's/^/        /'
  fi

  # `--check` is the same guarantee in the form a releaser can run directly.
  bash "$GEN" --check >/dev/null 2>&1
  expect_eq "--check reports the committed file as current" "$?" "0"
fi

echo "== caps on the committed file =="

if [ -f "$COMMITTED" ]; then
  expect_eq "committed notes are a JSON object" \
    "$(jq -r 'type' "$COMMITTED")" "object"
  expect_eq "committed notes keep at most 10 releases" \
    "$(jq '(length <= 10)' "$COMMITTED")" "true"
  expect_eq "no committed note exceeds 300 characters" \
    "$(jq '([.[] | length] | max) <= 300' "$COMMITTED")" "true"
  expect_eq "no committed note is empty" \
    "$(jq '[.[] | select(length == 0)] | length' "$COMMITTED")" "0"
  expect_eq "every committed value is a string" \
    "$(jq '[.[] | select(type != "string")] | length' "$COMMITTED")" "0"
  expect_eq "every committed key is version-shaped" \
    "$(jq '[keys[] | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+") | not)] | length' "$COMMITTED")" "0"
fi

echo "== user-visible-only: the real CHANGELOG's internal releases are omitted =="

# These two are marked `skip` in CHANGELOG.md because nothing about them is
# observable to a user: 0.21.0 is a dev-only eval harness, 0.17.1 is a docs sync.
if [ -f "$COMMITTED" ]; then
  expect_eq "0.21.0 (dev-only eval harness) is omitted" \
    "$(jq 'has("0.21.0")' "$COMMITTED")" "false"
  expect_eq "0.17.1 (docs sync, no behaviour change) is omitted" \
    "$(jq 'has("0.17.1")' "$COMMITTED")" "false"
fi
# The inclusion side of this used to name two versions (`0.24.0`, `0.22.0`) and
# assert they were present. That is only true while they sit inside the window:
# RELEASE_NOTES_KEEP is a ROLLING window of the newest 10 releases, so the first
# release that rolls a named witness out reds the suite on a completely correct
# release. It duly happened at v0.30.1 — the window was exactly full at 10, and
# `0.22.0` fell off the tail. Re-pinning a newer version would only move the
# tripwire one release forward, so the property is asserted directly below, after
# `block_has_skip` exists to express it.

# The markers must actually be present in the changelog, or the omissions above
# would be passing for the wrong reason (e.g. a parser bug dropping them).
# Assert the marker is present IN THE BLOCK of each release we expect to be
# skipped — not a whole-file count. An exact count is brittle in two ways that both
# red the suite on a CORRECT release: marking a third internal release `skip`
# (step 1 of the README checklist) changes the total, and a fenced example
# containing a marker line counts too. The invariant that actually matters is
# per-release, so measure that instead of a proxy for it.
block_has_skip(){ # <version> -> "yes"/"no"
  awk -v v="[$1]" '
    index($0, "## " v) == 1 { inblk = 1; next }
    inblk && /^## \[/ { exit }
    inblk && /^[ \t]*<!--[ \t]*release-notes:[ \t]*skip[ \t]*-->[ \t]*$/ { found = 1 }
    END { print (found ? "yes" : "no") }
  ' "$CHANGELOG"; }

expect_eq "0.21.0 carries a skip DIRECTIVE in its own block" "$(block_has_skip 0.21.0)" "yes"
expect_eq "0.17.1 carries a skip DIRECTIVE in its own block" "$(block_has_skip 0.17.1)" "yes"
expect_eq "0.24.0 carries no skip directive"                 "$(block_has_skip 0.24.0)" "no"
expect_eq "0.22.0 carries no skip directive"                 "$(block_has_skip 0.22.0)" "no"

# The inclusion invariant, stated so it cannot age out (see the note above).
# Every release the committed notes DO carry must be one the changelog did not
# mark `skip` — that is the curation contract, and unlike a named witness it holds
# for every future release without edit. It is also strictly stronger: the old
# form checked two versions, this checks all ten.
if [ -f "$COMMITTED" ]; then
  leaked=""
  for v in $(jq -r 'keys_unsorted[]' "$COMMITTED" 2>/dev/null); do
    [ "$(block_has_skip "$v")" = "no" ] || leaked="$leaked $v"
  done
  expect_eq "every release inside the window is user-visible (none skip-marked)" \
    "${leaked:-none}" "none"
  # And the window is actually populated — an empty notes file would satisfy the
  # loop above vacuously, which is the one way this could pass for no reason.
  expect_eq "the window is non-empty" \
    "$(jq 'keys | length > 0' "$COMMITTED")" "true"
fi
# And prove the whole-line shape is what distinguishes a directive from a mention.
expect_eq "a prose mention of the marker is not a directive" \
  "$(printf 'Mark it with `<!-- release-notes: skip -->` in the entry.\n' \
      | grep -cE '^[[:space:]]*<!--[[:space:]]*release-notes:[[:space:]]*skip[[:space:]]*-->[[:space:]]*$')" "0"

echo "== curation rules, against a synthetic CHANGELOG =="

cat > "$T/fixture.md" <<'MD'
# Changelog

Preamble prose that belongs to no release and must never be emitted.

## [2.0.0]

A user-visible headline for two-oh with **bold** and `code` and a [link](http://x).

### Added

- Some detail nobody needs in the notes.

## [1.9.0]

<!-- release-notes: skip -->

An internal-only release whose lead paragraph must never reach users.

## [1.8.0]

<!-- release-notes: Overridden wording wins. -->

The lead paragraph that the override replaces.

## [1.7.0]

### Fixed

- **Bullet headline fallback.** Trailing prose that should be dropped.

## [1.6.0]

### Changed

- A plain bullet with no bold lead-in at all.

## [1.5.0]

Single *asterisk* emphasis and an identifier like node_modules and covered_by_acs.

## [0.9.0]

Ignores generated `*.sql` files and treats a *conversation* as distinct from a run.

## [0.8.0]

<!-- release-notes: Migrates A -> B automatically. -->

Lead paragraph the override must replace.

## [0.7.0]

<!-- an unrelated whole-line comment -->

The real lead paragraph must win.

## [0.6.0]

<!--
an unrelated multi-line comment
-->

A multi-line comment must not become the note.

## [0.5.0]

<!-- unrelated:
     continued -->

A comment split across lines must not become the note.

## [1.4.0]

A release that DOCUMENTS the marker: set `<!-- release-notes: skip -->` to omit one.

## [1.3.0]

A release documenting the override: use `<!-- release-notes: your text -->` instead.

## [1.2.0]

A release with the marker shown inside a fence.

```
<!-- release-notes: skip -->
```

## [1.1.0]

   <!-- release-notes: Indented whole-line override. -->

Replaced lead paragraph.
MD

# RELEASE_NOTES_KEEP is lifted well above the fixture's release count so every
# curation case below is actually present. At the default 10, later cases fall
# outside the keep window and assert against `null` — a fixture artefact, not a
# behaviour. The two assertions that DO exercise the cap set it explicitly.
# The `:-` matters: a plain `RELEASE_NOTES_KEEP=50` prefix would override the
# callers below that deliberately set the cap to exercise it.
gen_fixture(){ RELEASE_NOTES_KEEP="${RELEASE_NOTES_KEEP:-50}" \
                 bash "$GEN" --changelog "$T/fixture.md" --stdout 2>/dev/null; }
FX="$(gen_fixture)"

expect_eq "unmarked release is INCLUDED (include-by-default)" \
  "$(printf '%s' "$FX" | jq 'has("2.0.0")')" "true"
expect_eq "no committed note still carries raw markdown" \
  "$(jq '[.[] | select(test("\\*|`|\\]\\("))] | length' "$COMMITTED")" "0"
expect_eq "skip-marked release is OMITTED" \
  "$(printf '%s' "$FX" | jq 'has("1.9.0")')" "false"
expect_eq "markdown emphasis/code/link flattened to text" \
  "$(printf '%s' "$FX" | jq -r '."2.0.0"')" \
  "A user-visible headline for two-oh with bold and code and a link."
expect_eq "override marker replaces the lead paragraph" \
  "$(printf '%s' "$FX" | jq -r '."1.8.0"')" "Overridden wording wins."
expect_eq "no-lead-paragraph release falls back to the bullet's bold headline" \
  "$(printf '%s' "$FX" | jq -r '."1.7.0"')" "Bullet headline fallback."
expect_eq "no-lead, no-bold release falls back to the whole bullet" \
  "$(printf '%s' "$FX" | jq -r '."1.6.0"')" "A plain bullet with no bold lead-in at all."
expect_eq "preamble prose is never emitted" \
  "$(printf '%s' "$FX" | jq -r '[.[] | select(test("Preamble prose"))] | length')" "0"
expect_eq "a skipped release leaks nothing" \
  "$(printf '%s' "$FX" | jq -r '[.[] | select(test("internal-only"))] | length')" "0"

# --- the marker must be a DIRECTIVE, never a mention -------------------------
# A release entry that documents the marker (which the release shipping this
# feature necessarily does) must not thereby suppress or retitle ITSELF. Before
# the whole-line + fence-aware match, every one of these silently misbehaved.
expect_eq "a release that MENTIONS the skip marker is still included" \
  "$(printf '%s' "$FX" | jq 'has("1.4.0")')" "true"
expect_eq "  ...and keeps its own lead paragraph" \
  "$(printf '%s' "$FX" | jq -r '."1.4.0" | startswith("A release that DOCUMENTS the marker")')" "true"
expect_eq "an inline override EXAMPLE does not hijack the note text" \
  "$(printf '%s' "$FX" | jq -r '."1.3.0" | startswith("A release documenting the override")')" "true"
expect_eq "a marker inside a fenced code block is not a directive" \
  "$(printf '%s' "$FX" | jq 'has("1.2.0")')" "true"
expect_eq "an indented whole-line override still applies" \
  "$(printf '%s' "$FX" | jq -r '."1.1.0"')" "Indented whole-line override."

# --- emphasis flattening, including the single-asterisk form -----------------
expect_eq "single-asterisk italics are flattened" \
  "$(printf '%s' "$FX" | jq -r '."1.5.0"')" \
  "Single asterisk emphasis and an identifier like node_modules and covered_by_acs."
expect_eq "  ...without mangling snake_case identifiers" \
  "$(printf '%s' "$FX" | jq -r '."1.5.0" | test("node_modules") and test("covered_by_acs")')" "true"

# A glob star beside a real italic must not pair with it. Matching italic PAIRS
# produced ".sql … conversation*" here — words rearranged AND a stray delimiter
# left behind, worse than the raw markdown. Deleting every asterisk is why this
# holds; the assertion pins the exact output, not just "no asterisk".
expect_eq "a glob star beside an italic does not corrupt the note" \
  "$(printf '%s' "$FX" | jq -r '."0.9.0"')" \
  "Ignores generated .sql files and treats a conversation as distinct from a run."
expect_eq "no fixture note retains a stray asterisk" \
  "$(printf '%s' "$FX" | jq '[.[] | select(test("\\*"))] | length')" "0"

# An override payload containing ">" must still apply. With the payload matched as
# [^>]* the marker line failed the rule, fell through to prose collection, and
# BECAME the note — publishing a raw HTML comment to users.
expect_eq "an override payload containing '>' still applies" \
  "$(printf '%s' "$FX" | jq -r '."0.8.0"')" "Migrates A -> B automatically."
expect_eq "an unrelated whole-line comment never becomes the note" \
  "$(printf '%s' "$FX" | jq -r '."0.7.0"')" "The real lead paragraph must win."

# Comment handling is a STATE MACHINE, not a per-line pattern, so every spelling
# is covered. Matching one line at a time let a multi-line comment through: its
# inner lines were collected as prose and the note became the literal string
# "<!-- release-notes: skip -->", while the skip directive was silently dropped.
expect_eq "a multi-line comment never becomes the note" \
  "$(printf '%s' "$FX" | jq -r '."0.6.0"')" "A multi-line comment must not become the note."
expect_eq "a comment split across lines never becomes the note" \
  "$(printf '%s' "$FX" | jq -r '."0.5.0"')" "A comment split across lines must not become the note."
# Scoped to "a note must not BE a comment". A note may legitimately *quote* the
# marker — that is exactly what the 1.4.0 / 1.3.0 cases above assert — so a blanket
# "contains no <!--" check would contradict them.
expect_eq "no fixture note begins with a raw HTML comment" \
  "$(printf '%s' "$FX" | jq '[.[] | select(startswith("<!--"))] | length')" "0"

echo "== caps are configurable and enforced =="

expect_eq "RELEASE_NOTES_KEEP bounds the output" \
  "$(RELEASE_NOTES_KEEP=2 gen_fixture | jq 'length')" "2"
expect_eq "RELEASE_NOTES_KEEP keeps the NEWEST releases" \
  "$(RELEASE_NOTES_KEEP=2 gen_fixture | jq -r '[keys[]] | sort | join(",")')" "1.8.0,2.0.0"

# A long lead paragraph must be truncated to CN_MAX_LEN, ellipsis included.
{ printf '# Changelog\n\n## [3.0.0]\n\n'
  awk 'BEGIN{for(i=0;i<60;i++) printf "averylongwordy phrase "; print ""}'
} > "$T/long.md"
long_note="$(bash "$GEN" --changelog "$T/long.md" --stdout 2>/dev/null | jq -r '."3.0.0"')"
expect_eq "long note is truncated within the cap" \
  "$([ "${#long_note}" -le 300 ] && echo yes || echo "no(${#long_note})")" "yes"
expect_contains "truncated note is marked with an ellipsis" "$long_note" "…"
expect_eq "a smaller CN_MAX_LEN is honoured" \
  "$(CN_MAX_LEN=80 bash "$GEN" --changelog "$T/long.md" --stdout 2>/dev/null \
      | jq -r '."3.0.0" | length <= 80')" "true"

echo "== --check detects drift and says how to fix it =="

cp "$T/fresh.json" "$T/stale.json" 2>/dev/null || bash "$GEN" --stdout > "$T/stale.json"
printf '{"0.0.1":"deliberately wrong"}\n' > "$T/stale.json"
err="$(bash "$GEN" --out "$T/stale.json" --check 2>&1)"; rc=$?
expect_eq       "--check exits 3 on drift" "$rc" "3"
expect_contains "--check names the fix command" "$err" "scripts/build-release-notes.sh"

rm -f "$T/absent.json"
err="$(bash "$GEN" --out "$T/absent.json" --check 2>&1)"; rc=$?
expect_eq       "--check exits 3 when the file is missing" "$rc" "3"
expect_contains "--check names the fix command when missing" "$err" "scripts/build-release-notes.sh"

# --check must never write.
expect_eq "--check does not create the file" \
  "$([ -f "$T/absent.json" ] && echo created || echo absent)" "absent"

echo "== docs contract: the release checklist that prevents drift =="

# This repo has no CI, so the README checklist is the PREVENTION half of the
# no-drift guarantee (this test file being the detection half). If the checklist
# stops naming the generator, a future releaser has nothing telling them to run it.
#
# The slice extractor is the `f`-flag form, NOT awk's `/start/,/end/` range: the
# range form breaks here because the start line ("## Releasing (maintainers)")
# also matches the end pattern ("^## "), closing the range immediately and
# yielding a useless 1-line slice. Scoping to the slice matters — a match
# anywhere else in the README must not satisfy this.
README="$REPO/README.md"
readme_slice(){ awk '/^## Releasing \(maintainers\)/{f=1;next} f&&/^## /{exit} f' "$README"; }
SLICE="$(readme_slice)"

expect_eq "README has a Releasing (maintainers) section" \
  "$(grep -c '^## Releasing (maintainers)' "$README")" "1"
expect_eq "the release-checklist slice is non-trivial" \
  "$([ "$(printf '%s\n' "$SLICE" | grep -c .)" -gt 1 ] && echo yes || echo no)" "yes"
expect_eq "the checklist names the generator script" \
  "$([ "$(printf '%s' "$SLICE" | grep -cF 'scripts/build-release-notes.sh')" -ge 1 ] && echo yes || echo no)" "yes"
expect_eq "the checklist names the generated notes file" \
  "$([ "$(printf '%s' "$SLICE" | grep -cF 'release-notes.json')" -ge 1 ] && echo yes || echo no)" "yes"
# The checklist must document the guard a maintainer will actually MEET. Every prior
# instance of this class cost a round: three documents said only "inside the release
# block" while the code required first-content position, which is what produced Gate B
# round 8's required finding. A refusal with no README explanation is the same shape.
expect_eq "the checklist explains the shipped-version refusal" \
  "$([ "$(printf '%s' "$SLICE" | grep -cF 'has no note and no skip marker')" -ge 1 ] && echo yes || echo no)" "yes"
expect_eq "the checklist states the bump-before-regenerate dependency" \
  "$([ "$(printf '%s' "$SLICE" | grep -cE '[Bb]efore\*? step 3')" -ge 1 ] && echo yes || echo no)" "yes"
expect_eq "the checklist no longer claims the drift test is the ONLY enforcement" \
  "$(printf '%s' "$SLICE" | grep -cF 'enforced only by the checklist')" "0"

expect_eq "the checklist points at this drift test" \
  "$([ "$(printf '%s' "$SLICE" | grep -cF 'release-notes-sync.test.sh')" -ge 1 ] && echo yes || echo no)" "yes"

# The new SessionStart hook changed the wired-hook count; the old figure must not
# survive anywhere in the README or the fallback fragment.
# DERIVE the expected count from hooks.json rather than pinning a word. The base
# figure was already stale by one (README said eight while nine were wired), so simply
# incrementing it inherited the error - and a word-pinned assertion would then red the
# suite for whoever fixed it. inject-history-reminder.sh is wired but gated OFF by
# default and documented separately, so it is not an "always-on" hook.
#
# The gated hooks are NAMED, not assumed to number exactly one. `wired - 1` encoded
# "there is precisely one opt-in hook", so wiring a second one would have silently
# shifted the expected count by one and reported the README as wrong at a number that
# was actually right - the same off-by-one this assertion exists to catch. Names also
# fail loudly: if a listed hook stops being wired, the presence check below says so
# instead of quietly mis-counting. Basenames are deduped because a hook wired to two
# events is still one hook in the README list.
HOOKS_JSON="$REPO/hooks/hooks.json"
GATED_HOOKS="inject-history-reminder.sh"
all_hooks="$(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$HOOKS_JSON" | sed 's#.*/hooks/##' | sort -u)"
wired="$(printf '%s\n' "$all_hooks" | grep -c .)"
gated_present=0; gated_missing=""
for g in $GATED_HOOKS; do
  if printf '%s\n' "$all_hooks" | grep -qx "$g"; then gated_present=$((gated_present + 1))
  else gated_missing="$gated_missing $g"; fi
done
expect_eq "every hook named as gated is actually wired" "$gated_missing" ""
always_on=$((wired - gated_present))
count_word(){ case "$1" in 8) echo eight ;; 9) echo nine ;; 10) echo ten ;; 11) echo eleven ;; 12) echo twelve ;; *) echo "$1" ;; esac; }
expect_eq "README core-hook count matches hooks.json minus the gated opt-in" \
  "$(grep -c "$(count_word "$always_on") core hooks" "$README")" "1"
expect_eq "no stale core-hook count survives in README" \
  "$(grep -cE '(eight|nine) core hooks' "$README")" "0"
# GB6#5: the README skill counter went stale (said "ten skills" while install.sh
# wired 12). Pinned the same way the hook count above is — derived from the source
# of truth, not hardcoded — so the next skill addition fails loudly here instead of
# leaving a wrong number in the install instructions. install.sh's SKILLS array is
# that source: it is what the fallback installer actually symlinks.
n_skills="$(sed -n 's/^SKILLS=(\(.*\))$/\1/p' "$REPO/install.sh" | tr ' ' '\n' | grep -c .)"
expect_eq "install.sh SKILLS array is parseable" "$([ "$n_skills" -ge 8 ] && echo ok || echo "no ($n_skills)")" "ok"
expect_eq "README skill count matches install.sh SKILLS" \
  "$(grep -c "$(count_word "$n_skills") skills" "$README")" "2"
expect_eq "no stale skill count survives in README" \
  "$(grep -cE '(eight|nine|ten|eleven) skills' "$README")" "0"

missing_bullets=""
for h in $all_hooks; do
  case " $GATED_HOOKS " in *" $h "*) continue ;; esac
  grep -q "^  - .$h." "$README" || missing_bullets="$missing_bullets $h"
done
expect_eq "every always-on hook has a README bullet" "${missing_bullets:-none}" "none"

# The version -> CHANGELOG coupling. This change makes an existing convention (every
# release gets a CHANGELOG entry) load-bearing for a user-visible feature: cut a
# release without an entry and the hook takes rule 2b - valid file, no key in range -
# which ADVANCES the stamp, so that notice is consumed rather than deferred and can
# never be recovered. Heading presence is the right check: it stays correct for a
# skip-marked release, which deliberately has no key in the notes file.
installed_v="$(jq -r '.version' "$REPO/.claude-plugin/plugin.json")"
expect_eq "the installed version has a CHANGELOG entry" \
  "$(grep -c "^## \\[$installed_v\\]" "$CHANGELOG")" "1"
expect_eq "settings-fragment no longer claims eight always-on hooks" \
  "$(grep -c 'eight always-on hooks' "$REPO/settings-fragment.json")" "0"

# ALL THREE wiring surfaces must register the new hook, or an install layout
# silently ships without the notice. There are three, not two: hooks.json
# (marketplace), settings-fragment.json (reference), and the block install.sh
# PRINTS for the user to paste — README tells users to prefer install.sh's output,
# so a hook missing there is invisible to exactly the people following the docs.
# This bug class has bitten before (see CHANGELOG 0.1.x, check-version.sh).
expect_eq "hooks.json registers release-notes.sh on SessionStart" \
  "$(jq -r '[.hooks.SessionStart[].hooks[].command] | map(test("release-notes.sh")) | any' \
      "$REPO/hooks/hooks.json")" "true"
expect_eq "settings-fragment registers release-notes.sh on SessionStart" \
  "$(jq -r '[.hooks.SessionStart[].hooks[].command] | map(test("release-notes.sh")) | any' \
      "$REPO/settings-fragment.json")" "true"
expect_eq "install.sh PRINTS release-notes.sh in its SessionStart block" \
  "$(grep -c 'hooks/release-notes.sh' "$REPO/install.sh")" "1"

# Guard the count itself: every SessionStart hook in hooks.json must also appear
# in install.sh's printed block, so the next hook added cannot repeat this.
# ALL events, not just SessionStart. Scoping this loop to the event THIS run happens to
# touch was a guard that looked general and was not: it passed while install.sh was
# missing guard-dangerous-ops.sh (PreToolUse) - the fail-closed dangerous-ops interrupt
# the README describes as always-on - and inject-history-reminder.sh (UserPromptSubmit).
# Both had been absent since v0.22.0; settings-fragment.json, the other fallback, had
# them all along, so install.sh was the only surface that had drifted.
missing=""
for h in $(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$REPO/hooks/hooks.json" \
            | sed 's#.*/hooks/##; s/"$//' | sort -u); do
  grep -q "hooks/$h" "$REPO/install.sh" || missing="$missing $h"
done
expect_eq "install.sh prints every hook that hooks.json wires, across ALL events" \
  "${missing:-none}" "none"
# And the same for the other fallback surface, so neither can drift alone again.
missing_frag=""
for h in $(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$REPO/hooks/hooks.json" \
            | sed 's#.*/hooks/##; s/"$//' | sort -u); do
  grep -q "hooks/$h" "$REPO/settings-fragment.json" || missing_frag="$missing_frag $h"
done
expect_eq "settings-fragment.json lists every hook that hooks.json wires" \
  "${missing_frag:-none}" "none"
# PER EVENT, not file-wide. The loops above ask only "does this basename appear
# somewhere in the file", so moving guard-dangerous-ops.sh out of PreToolUse and into
# the SessionStart array would leave every one of them green - a hook firing at the
# wrong time, pasted by hand from a block nothing checked structurally. install.sh
# prints its block inside a heredoc, so it is extracted and parsed as real JSON rather
# than grepped: that also proves the block a user pastes is still valid JSON.
inst_json="$(awk '/^\{$/{f=1} f{print} /^\}$/{if(f) exit}' "$REPO/install.sh" \
             | sed 's#\$REPO_ROOT#/PLACEHOLDER#g')"
expect_eq "install.sh's printed block is valid JSON" \
  "$(printf '%s' "$inst_json" | jq -e 'type == "object"' >/dev/null 2>&1 && echo yes || echo no)" "yes"
event_map(){ # <file-or-json> <mode>
  if [ "$2" = raw ]; then printf '%s' "$1"; else cat "$1"; fi \
    | jq -S -r '.hooks | to_entries | map({key, value: [.value[].hooks[].command | sub(".*/hooks/"; "")] | sort}) | from_entries' 2>/dev/null; }
canon="$(event_map "$REPO/hooks/hooks.json" file)"
expect_eq "install.sh maps every EVENT to the same hooks as hooks.json" \
  "$(event_map "$inst_json" raw)" "$canon"
expect_eq "settings-fragment.json maps every EVENT to the same hooks as hooks.json" \
  "$(event_map "$REPO/settings-fragment.json" file)" "$canon"

# Every event key must appear in both fallbacks too - a whole missing event was how
# UserPromptSubmit went unnoticed.
missing_ev=""
for e in $(jq -r '.hooks | keys[]' "$REPO/hooks/hooks.json"); do
  grep -q "\"$e\"" "$REPO/install.sh" || missing_ev="$missing_ev install.sh:$e"
  grep -q "\"$e\"" "$REPO/settings-fragment.json" || missing_ev="$missing_ev fragment:$e"
done
expect_eq "every wired hook EVENT appears in both fallback surfaces" \
  "${missing_ev:-none}" "none"

echo "== a heading that is only SHOWN (fenced or commented) is not a release =="

# awk evaluates rules top-down, so an unguarded heading rule fired even for a
# heading merely displayed inside a fenced example — the natural way to document
# this feature. That parsed the example as a real release AND reset the fence flag,
# so the real closing fence opened one and the truncation guard aborted the whole
# generator on VALID markdown, naming a release that does not exist. The heading
# rule is now guarded by !fence && !incomment.
cat > "$T/fenced-heading.md" <<'MD'
# Changelog

## [0.25.0]

Adds release notes at update time. Mark an internal release like this:

```
## [0.24.1]

<!-- release-notes: skip -->
```

## [0.24.0]

A normal earlier release.
MD
out="$(bash "$GEN" --changelog "$T/fenced-heading.md" --stdout 2>&1)"; rc=$?
expect_eq "fenced heading example: generator succeeds on valid markdown" "$rc" "0"
expect_eq "fenced heading example: the example is NOT parsed as a release" \
  "$(printf '%s' "$out" | jq 'has("0.24.1")')" "false"
expect_eq "fenced heading example: the real releases both survive" \
  "$(printf '%s' "$out" | jq -r '[keys[]] | sort | join(",")')" "0.24.0,0.25.0"
expect_eq "fenced heading example: the documenting release keeps its own note" \
  "$(printf '%s' "$out" | jq -r '."0.25.0"')" \
  "Adds release notes at update time. Mark an internal release like this:"
expect_eq "fenced heading example: no phantom-release diagnostic" \
  "$(printf '%s' "$out" | grep -c 'unterminated')" "0"

# The same coupling reached through the comment state machine.
cat > "$T/commented-heading.md" <<'MD'
# Changelog

## [1.0.0]

<!--
## [0.9.9]
-->

The real lead paragraph must win.
MD
out="$(bash "$GEN" --changelog "$T/commented-heading.md" --stdout 2>&1)"; rc=$?
expect_eq "commented-out heading: generator succeeds" "$rc" "0"
expect_eq "commented-out heading: is NOT parsed as a release" \
  "$(printf '%s' "$out" | jq 'has("0.9.9")')" "false"
expect_eq "commented-out heading: the real release keeps its lead paragraph" \
  "$(printf '%s' "$out" | jq -r '."1.0.0"')" "The real lead paragraph must win."

echo "== malformed input fails LOUDLY, never silently drops a release =="

# The worst outcome this feature can have is a user-visible release quietly
# getting no note. An unterminated <!-- or fence truncates the release block, and
# the drift test structurally cannot catch it — a release missing from BOTH the
# committed file and a fresh generation looks perfectly consistent. So the
# generator must refuse to write instead.
cat > "$T/unterminated-comment.md" <<'MD'
# Changelog

## [7.0.0]

<!-- unterminated comment

A user-visible release whose block gets swallowed.

## [6.0.0]

A normal release.
MD
out="$(bash "$GEN" --changelog "$T/unterminated-comment.md" --stdout 2>&1)"; rc=$?
expect_eq       "unterminated comment: generator refuses to write" "$rc" "2"
expect_contains "unterminated comment: names the offending release" "$out" "[7.0.0]"
expect_contains "unterminated comment: explains the fix"           "$out" "unterminated HTML comment"
expect_eq       "unterminated comment: emits no notes JSON at all" \
  "$(printf '%s' "$out" | grep -c '^{')" "0"

cat > "$T/unterminated-fence.md" <<'MD'
# Changelog

## [7.0.0]

```
unclosed fence

A user-visible release whose block gets swallowed.

## [6.0.0]

A normal release.
MD
out="$(bash "$GEN" --changelog "$T/unterminated-fence.md" --stdout 2>&1)"; rc=$?
expect_eq       "unterminated fence: generator refuses to write" "$rc" "2"
expect_contains "unterminated fence: names the offending release" "$out" "[7.0.0]"
expect_contains "unterminated fence: identifies it as a fence"   "$out" "fenced code block"

# And the well-formed real changelog must still be accepted — the guard must not
# be so eager that it blocks the normal path.
bash "$GEN" --check >/dev/null 2>&1
expect_eq "the real CHANGELOG is not tripped by the truncation guard" "$?" "0"

echo "== truncation is UTF-8 safe at every byte offset =="

# The truncation cuts at a BYTE offset, which can land mid-character. In a UTF-8
# locale the next regex match on that string made awk abort with
# "towc: multibyte conversion failure" and the generator died naming no release;
# under LC_ALL=C it could emit a severed sequence. The fix forces the C locale and
# strips a trailing incomplete sequence. Sweep the offsets where a multi-byte char
# straddles the cut — the previous code failed hard at two of these.
utf8_probe(){ # <byte-offset-of-multibyte-char>
  python3 - "$1" "$T/utf8.md" <<'PY'
import sys
off, path = int(sys.argv[1]), sys.argv[2]
pad = 'word ' * 100
body = pad[:off-1] + 'w• and then more trailing prose to push well past the cap'
open(path, 'w').write('# C\n\n## [1.0.0]\n\n' + body + '\n')
PY
  bash "$GEN" --changelog "$T/utf8.md" --stdout 2>&1; }

utf8_fail=0; utf8_bad=0
for off in 293 294 295 296 297 298 299 300; do
  out="$(utf8_probe "$off")"; rc=$?
  [ "$rc" -eq 0 ] || utf8_fail=$((utf8_fail+1))
  printf '%s' "$out" | jq -e '.["1.0.0"] | test("^[\\s\\S]*$")' >/dev/null 2>&1 || utf8_bad=$((utf8_bad+1))
done
expect_eq "truncation never hard-fails across the byte-boundary sweep" "$utf8_fail" "0"
expect_eq "truncated notes stay valid UTF-8 across the sweep"         "$utf8_bad" "0"

# A single ultra-long token leaves no space to cut back to, so the explicit
# incomplete-sequence strip is the only thing keeping it valid.
python3 - "$T/utf8w.md" <<'PY'
import sys
open(sys.argv[1], 'w').write('# C\n\n## [1.0.0]\n\n' + 'x'*294 + '•' + 'y'*80 + '\n')
PY
out="$(bash "$GEN" --changelog "$T/utf8w.md" --stdout 2>&1)"
expect_eq "ultra-long single token truncates to valid UTF-8" \
  "$(printf '%s' "$out" | jq -r '.["1.0.0"]' | python3 -c "
import sys
d = sys.stdin.buffer.read().rstrip(b'\n')
print('ok' if len(d) > 0 else 'empty')" 2>/dev/null)" "ok"

echo "== a noteless, unmarked release is reported, never silently dropped =="

# note == \"\" with skip == 0 used to fall through with exit 0 and no stderr, so the
# generator wrote a notes file missing a user-visible release and --check called it
# up to date. The drift test cannot see that: absent from both files reads as
# consistent. This is the same worst-case outcome the truncation guard prevents.
cat > "$T/noteless.md" <<'MD'
# Changelog

## [0.26.0]

| col | col |
|---|---|
| a | b |

## [0.24.0]

A normal release.
MD
out="$(bash "$GEN" --changelog "$T/noteless.md" --out "$T/noteless.json" 2>&1)"; rc=$?
expect_eq       "noteless release: generator refuses to write" "$rc" "2"
expect_contains "noteless release: names the offending release" "$out" "[0.26.0]"
expect_contains "noteless release: suggests the skip marker"    "$out" "release-notes: skip"
expect_eq       "noteless release: no notes file is produced" \
  "$([ -f "$T/noteless.json" ] && echo created || echo absent)" "absent"

# The documented remedy must actually clear it.
cat > "$T/noteless-fixed.md" <<'MD'
# Changelog

## [0.26.0]

<!-- release-notes: skip -->

| col | col |
|---|---|
| a | b |

## [0.24.0]

A normal release.
MD
out="$(bash "$GEN" --changelog "$T/noteless-fixed.md" --stdout 2>&1)"; rc=$?
expect_eq "marking it skip clears the error" "$rc" "0"
expect_eq "  ...and the remaining release is emitted" \
  "$(printf '%s' "$out" | jq -r '."0.24.0"')" "A normal release."

echo "== rule precedence: state is tracked everywhere, comment outranks fence =="

# These are the two cases the round-6 heading guard did NOT cover, both on VALID
# markdown. The fix moved fence/comment tracking ABOVE the preamble drop and put
# the comment swallow ABOVE the fence toggle, so precedence is now
# comment > fence > directive > heading > preamble > content.

# (a) A fenced example in the PREAMBLE. Tracking used to begin only after the first
#     heading, so the example heading became a phantom release, the real next
#     release vanished, and the run aborted naming a version that does not exist.
cat > "$T/pre-fence.md" <<'MD'
# Changelog

A release entry looks like:

```
## [1.2.3]

A one-paragraph user-facing summary.
```

## [0.25.0]

The real release.

## [0.24.0]

An earlier real release.
MD
out="$(bash "$GEN" --changelog "$T/pre-fence.md" --stdout 2>&1)"; rc=$?
expect_eq "preamble fenced example: generator succeeds" "$rc" "0"
expect_eq "preamble fenced example: no phantom release" \
  "$(printf '%s' "$out" | jq 'has("1.2.3")')" "false"
expect_eq "preamble fenced example: both real releases survive" \
  "$(printf '%s' "$out" | jq -r '[keys[]] | sort | join(",")')" "0.24.0,0.25.0"

# (b) A fence line INSIDE a comment used to flip the fence flag mid-comment and
#     swallow the comment closer, then report a "missing -->" that was present.
printf '# Changelog\n\n## [0.25.0]\n\n<!--\n```bash\nold draft\n-->\n\nThe real lead paragraph.\n\n## [0.24.0]\n\nEarlier.\n' > "$T/fence-in-comment.md"
out="$(bash "$GEN" --changelog "$T/fence-in-comment.md" --stdout 2>&1)"; rc=$?
expect_eq "fence inside a comment: generator succeeds" "$rc" "0"
expect_eq "fence inside a comment: the real lead paragraph wins" \
  "$(printf '%s' "$out" | jq -r '."0.25.0"')" "The real lead paragraph."
expect_eq "fence inside a comment: no bogus unterminated report" \
  "$(printf '%s\n' "$out" | grep -c 'unterminated')" "0"

# A marker in the preamble belongs to no release and must not leak into the first
# one - a new hazard created by running the marker rule before the preamble drop.
printf '# Changelog\n\n<!-- release-notes: skip -->\n\n## [0.25.0]\n\nMust still be published.\n' > "$T/pre-marker.md"
expect_eq "a preamble marker does not leak into the first release" \
  "$(bash "$GEN" --changelog "$T/pre-marker.md" --stdout 2>/dev/null | jq -r '."0.25.0"')" \
  "Must still be published."

# A preamble-only break leaves ver=="" so flush() returns early; without the END
# guard this emitted zero releases with exit 0 and the generator wrote an empty
# notes file - total silent loss.
printf '# Changelog\n\n```\nunclosed\n\n## [0.25.0]\n\nLead.\n' > "$T/pre-broken.md"
out="$(bash "$GEN" --changelog "$T/pre-broken.md" --out "$T/pre-broken.json" 2>&1)"; rc=$?
expect_eq       "unterminated preamble fence: refuses to write" "$rc" "2"
expect_contains "unterminated preamble fence: says it swallowed the file" "$out" "before the first release heading"
expect_eq       "unterminated preamble fence: no notes file produced" \
  "$([ -f "$T/pre-broken.json" ] && echo created || echo absent)" "absent"

echo "== a closing fence may carry ONLY whitespace (CommonMark) =="

# Half of the closer rule was implemented at first (same char, run >= opener) and the
# other half omitted: a closer may not carry an info string. Since a nested example
# block is nearly always language-tagged, ```bash inside a ``` block was accepted as
# a closer, the fence state inverted, and the innermost line escaped as prose to
# become the release note - a line of example code shipped to users while all flags
# stayed balanced and every guard stayed green.
python3 - "$T/nest-ok.md" <<'PYX'
import sys
open(sys.argv[1], "w").write(
"""# Changelog

## [0.25.0]

````markdown
## [0.24.1]

<!-- release-notes: skip -->

```bash
scripts/build-release-notes.sh
```
````

Users now see a short summary of what changed whenever the plugin updates.

## [0.24.0]

Lead 0.24.0.
""")
PYX
nk="$(bash "$GEN" --changelog "$T/nest-ok.md" --stdout 2>&1)"
expect_eq "tagged inner fence is content, not a closer" \
  "$(printf '%s' "$nk" | jq -r '."0.25.0"')" \
  "Users now see a short summary of what changed whenever the plugin updates."
expect_eq "  ...and no example code leaks into any note" \
  "$(printf '%s' "$nk" | jq '[.[] | select(test("build-release-notes"))] | length')" "0"
expect_eq "  ...and the fenced example heading is not a release" \
  "$(printf '%s' "$nk" | jq 'has("0.24.1")')" "false"

# The unrepresentable shape (3-backtick fence inside a 3-backtick fence) is genuinely
# malformed markdown. It must fail LOUDLY rather than silently publish example code,
# which is what the old blind toggle did by counting an even number of fence lines.
python3 - "$T/nest-bad.md" <<'PYX'
import sys
open(sys.argv[1], "w").write(
"""# Changelog

## [0.25.0]

```
## [0.24.1]

```bash
scripts/build-release-notes.sh
```
```

Users now see a short summary.
""")
PYX
nb="$(bash "$GEN" --changelog "$T/nest-bad.md" --stdout 2>&1)"; nb_rc=$?
expect_eq       "unrepresentable nesting fails loudly instead of leaking" "$nb_rc" "2"
expect_contains "  ...and names the release" "$nb" "[0.25.0]"

echo "== KNOWN LIMITATION, pinned so it stays visible =="

# A fence left unclosed inside its own release but closed by a later ``` is
# BALANCED overall, so no flag is open at any boundary and nothing reports it. Every
# heading the fence spans is swallowed, so a real release is dropped with exit 0.
# This is pinned rather than fixed because it is NOT distinguishable from the
# legitimate documented example (a release entry showing what a release entry looks
# like) — any detector would fire on every release that documents the format. The
# assertion exists so the limitation cannot quietly change without someone noticing,
# and so the lib header cannot drift back to claiming the guard is total.
printf '# Changelog\n\n## [0.26.0]\n\n```\nopen\n\n## [0.25.0]\n\nstill inside\n```\n\nAfter.\n' > "$T/span.md"
span="$(bash "$GEN" --changelog "$T/span.md" --stdout 2>&1)"; span_rc=$?
expect_eq "known limitation: a boundary-spanning balanced fence still exits 0" "$span_rc" "0"
expect_eq "known limitation: the spanned release IS dropped (documented, not fixed)" \
  "$(printf '%s' "$span" | jq 'has("0.25.0")')" "false"
expect_eq "known limitation: the lib header records it instead of claiming totality" \
  "$(grep -c 'KNOWN LIMITATION' "$LIB")" "1"
expect_eq "known limitation: the header no longer claims the guard cannot be silent" \
  "$(grep -c 'it cannot be silent' "$LIB")" "0"

# NO ACCOUNTING INVARIANT HERE, deliberately - one was added and then REMOVED.
# The idea was to assert (release headings) - (skip directives) == (extracted notes)
# so a swallowed release would break the equality. It is unsound: the two counters
# are plain greps with no fence or comment awareness, while the extractor they are
# compared against is deliberately fence-aware. They therefore disagree on exactly
# the shapes the extractor was hardened to support - a fenced example of the marker
# (which the release checklist tells maintainers to write) counts as a directive and
# reds this suite on correct input, measured H=45 S=3 E=43 against an expected 42.
# Making the counters fence-aware does not help either: they would then share the
# extractor blindness and the equality would hold trivially. There is no sound
# version, so the limitation stays documented and pinned above rather than guarded
# by a check that fires on valid changelogs.

echo "== fence nesting follows CommonMark (char + run length) =="

# A blind fence toggle let an INNER fence close an OUTER one, so the innermost
# content escaped as prose and became the release note - a line of example code
# shipped to users in place of the real lead paragraph, with every flag balanced and
# every guard green. Showing a fenced block inside a longer fence is the standard
# way a changelog entry documents this feature, so this is a shape the repo will hit.
{ printf '# Changelog\n\n## [0.25.0]\n\n'
  printf '````markdown\n## [X.Y.Z]\n\n```bash\nscripts/build-release-notes.sh\n```\n````\n\n'
  printf 'Adds the release-notes surfaces so you can see what an update contains.\n\n'
  printf '## [0.24.0]\n\nA real earlier release.\n'; } > "$T/nest.md"
nest="$(bash "$GEN" --changelog "$T/nest.md" --stdout 2>&1)"
expect_eq "nested fence: the real lead paragraph becomes the note" \
  "$(printf '%s' "$nest" | jq -r '."0.25.0"')" \
  "Adds the release-notes surfaces so you can see what an update contains."
expect_eq "nested fence: no example code leaks into a note" \
  "$(printf '%s' "$nest" | jq '[.[] | select(test("build-release-notes"))] | length')" "0"

printf '# Changelog\n\n## [0.25.0]\n\n~~~\n```\nINNER LEAK\n```\n~~~\n\nThe real lead paragraph.\n' > "$T/nest2.md"
expect_eq "mixed tilde/backtick nesting: inner content does not leak" \
  "$(bash "$GEN" --changelog "$T/nest2.md" --stdout 2>/dev/null | jq -r '."0.25.0"')" \
  "The real lead paragraph."

printf '# Changelog\n\n## [0.25.0]\n\n`````\n```\nstill inside\n```\n`````\n\nReal lead.\n' > "$T/nest3.md"
expect_eq "a shorter fence does not close a longer one" \
  "$(bash "$GEN" --changelog "$T/nest3.md" --stdout 2>/dev/null | jq -r '."0.25.0"')" "Real lead."

# And the single-level behaviour rounds 6/8 established must be unchanged.
printf '# Changelog\n\n## [0.25.0]\n\nLead.\n\n```\n## [0.24.1]\n<!-- release-notes: skip -->\n```\n\n## [0.24.0]\n\nEarlier.\n' > "$T/nest4.md"
expect_eq "single-level fenced heading example still ignored" \
  "$(bash "$GEN" --changelog "$T/nest4.md" --stdout 2>/dev/null | jq -r '[keys[]] | sort | join(",")')" \
  "0.24.0,0.25.0"

echo "== mentions the marker vs IS the marker, in all three contexts =="

# This distinction had to be made three times, in three different contexts, and each
# fix anchored one and left the next unanchored: inline prose (round 1), an own-line
# demonstration (round 6), and inside a comment (round 14). The last one was the worst
# of the three: a substring match fired on a commented-out draft that merely DISCUSSED
# the marker, blocking a valid changelog AND printing advice - "put it on one line" -
# that would have converted that prose into a real directive and silently omitted the
# release. All three now key on the same whole-line shape.
python3 - "$T/discuss.md" <<'PYX'
import sys
open(sys.argv[1], "w").write("""# Changelog

## [0.30.0]

<!--
Draft note: we should probably use release-notes: skip for the next internal one.
-->

A real user-visible release.
""")
PYX
dis="$(bash "$GEN" --changelog "$T/discuss.md" --stdout 2>&1)"; dis_rc=$?
expect_eq "prose DISCUSSING the marker inside a comment is not a directive" "$dis_rc" "0"
expect_eq "  ...and the release keeps its note" \
  "$(printf '%s' "$dis" | jq -r '."0.30.0"')" "A real user-visible release."

# The genuine multi-line spelling must still be reported, indented or not.
printf '# Changelog\n\n## [0.30.0]\n\n<!--\nrelease-notes: skip\n-->\n\nInternal.\n' > "$T/mlbare.md"
expect_eq "a bare multi-line directive is still reported" \
  "$(bash "$GEN" --changelog "$T/mlbare.md" --stdout >/dev/null 2>&1; echo $?)" "2"
printf '# Changelog\n\n## [0.30.0]\n\n<!--\n   release-notes: skip\n-->\n\nInternal.\n' > "$T/mlind.md"
expect_eq "  ...including the indented spelling" \
  "$(bash "$GEN" --changelog "$T/mlind.md" --stdout >/dev/null 2>&1; echo $?)" "2"

# Anchoring at `skip[ \t]*$` alone traded the false positive for a false NEGATIVE, which
# is the worse direction: a maintainer who breaks the comment as `<!--` / `release-notes:
# skip -->` gets NO diagnostic and the internal release publishes. The closer legitimately
# shares the payload line, and the colon-split spellings never reach the payload rule with
# a recognisable key at all, so they are caught where the comment OPENS. Table-driven so a
# future tightening of either anchor has to face every spelling at once.
ml_fatal(){ # <label> <body>
  printf '# Changelog\n\n## [0.30.0]\n\n%b\n\nInternal only.\n\n## [0.29.0]\n\nNormal.\n' "$2" > "$T/mlx.md"
  out="$(bash "$GEN" --changelog "$T/mlx.md" --stdout 2>&1)"; rc=$?
  expect_eq "genuine multi-line directive is reported: $1" "$rc" "2"
  expect_contains "  ...and it says the marker is not recognised: $1" "$out" "not recognised"
}
ml_fatal "closer on the payload line"  '<!--\nrelease-notes: skip -->'
ml_fatal "split at the colon"          '<!-- release-notes:\n     skip -->'
ml_fatal "split at the colon, 3 lines" '<!-- release-notes:\nskip\n-->'
ml_fatal "split multi-line override"   '<!-- release-notes: a long\n  override -->'

# THE PAYLOAD AXIS. Rule 1 hardcoded `skip` for two rounds while rules 4 and 5 both
# accepted any payload, so an orphaned OVERRIDE payload line was the single cell of the
# grammar that stayed silent - the maintainer chosen wording discarded with no signal.
# All three rules now agree, and all six cells are pinned here so a future round cannot
# patch one and leave its neighbour open (four consecutive rounds did exactly that).
ml_fatal "orphaned override payload line" '<!--\nrelease-notes: Some override text\n-->'
ml_fatal "orphaned override, closer shared" '<!--\nrelease-notes: Some override text -->'

# The two HONOURED cells - the complete one-line form - must be untouched by all of it.
printf '# Changelog\n\n## [0.30.0]\n\n<!-- release-notes: skip -->\n\nInternal.\n\n## [0.29.0]\n\n<!-- release-notes: Override wins. -->\n\nLead.\n' > "$T/honour.md"
hon="$(bash "$GEN" --changelog "$T/honour.md" --stdout 2>/dev/null)"
expect_eq "one-line skip is still HONOURED, not reported" \
  "$(printf '%s' "$hon" | jq 'has("0.30.0")')" "false"
expect_eq "one-line override is still HONOURED, not reported" \
  "$(printf '%s' "$hon" | jq -r '."0.29.0"')" "Override wins."

# A near-miss payload is rule 4's third outcome, and since rule 1 became payload-agnostic
# the one-line and split forms finally AGREE on it. Pinned in both forms so the agreement
# is a property of the suite rather than a coincidence of this round.
for nm in 'SKIP' 'skip.'; do
  printf '# Changelog\n\n## [0.30.0]\n\n<!-- release-notes: %s -->\n\nLead.\n' "$nm" > "$T/nm1.md"
  expect_eq "near-miss payload [$nm] reports on ONE line" \
    "$(bash "$GEN" --changelog "$T/nm1.md" --stdout >/dev/null 2>&1; echo $?)" "2"
  printf '# Changelog\n\n## [0.30.0]\n\n<!--\nrelease-notes: %s\n-->\n\nLead.\n' "$nm" > "$T/nm2.md"
  expect_eq "near-miss payload [$nm] reports when SPLIT too" \
    "$(bash "$GEN" --changelog "$T/nm2.md" --stdout >/dev/null 2>&1; echo $?)" "2"
done

# An EMPTY payload is silent in both forms - nothing to honour, nothing lost. Asserted so
# the payload axis reads as uniform rather than leaving a reader to wonder about the cell.
printf '# Changelog\n\n## [0.30.0]\n\n<!-- release-notes: -->\n\nLead.\n' > "$T/e1.md"
expect_eq "empty payload is silent on one line" \
  "$(bash "$GEN" --changelog "$T/e1.md" --stdout 2>/dev/null | jq -r '."0.30.0"')" "Lead."
printf '# Changelog\n\n## [0.30.0]\n\n<!--\nrelease-notes:\n-->\n\nLead.\n' > "$T/e2.md"
expect_eq "empty payload is silent when split too" \
  "$(bash "$GEN" --changelog "$T/e2.md" --stdout 2>/dev/null | jq -r '."0.30.0"')" "Lead."

ml_silent(){ # <label> <body>
  printf '# Changelog\n\n## [0.30.0]\n\n%b\n\nInternal only.\n' "$2" > "$T/mls.md"
  out="$(bash "$GEN" --changelog "$T/mls.md" --stdout 2>&1)"; rc=$?
  expect_eq "not a directive, stays silent: $1" "$rc" "0"
  expect_eq "  ...and the release keeps its note: $1" \
    "$(printf '%s' "$out" | jq -r '."0.30.0"')" "Internal only."
}
# BOUNDARY, stated deliberately: the key BEGINNING the line is what makes a line the
# marker - not the absence of trailing words. `release-notes: skip is the marker` at line
# start is an override attempt whose payload happens to read like prose, and under the
# payload-agnostic rule it reports rather than vanishing. This assertion was the reverse
# while rule 1 was skip-only; it is flipped on the principle, not to fit the code. The
# HARMFUL shape from round 14 - prose with words BEFORE the key - is the next case down
# and still stays silent, which is the half that actually mattered.
ml_fatal  "key at line start, prose-like payload" '<!--\nrelease-notes: skip is the marker\n-->'
ml_silent "leading words plus a closer" '<!--\nsee release-notes: skip -->'
ml_silent "ordinary multi-line comment" '<!--\nan unrelated multi-line comment\n-->'
ml_silent "FENCED example of a marker"  '```\n<!-- release-notes: skip -->\n```'

echo "== every diagnostic names WHERE it fired, never an empty release =="

# Both multi-line guards interpolated `ver` unguarded, so a marker in the PREAMBLE
# printed "release []" - from a message whose own caller promises it "names the release
# and the problem", sending a maintainer to grep for a release that does not exist. The
# END guard already worded the preamble case correctly; the wording is now shared.
# Asserted as a SWEEP rather than per-rule: the next guard someone adds gets covered
# without having to remember this round.
no_empty_release(){ # <label> <body>
  printf '%b' "$2" > "$T/loc.md"
  err="$(bash "$GEN" --changelog "$T/loc.md" --stdout 2>&1 >/dev/null)"
  expect_eq "no empty release name in the diagnostic: $1" \
    "$(printf '%s' "$err" | grep -c 'release \[\]')" "0"
}
no_empty_release "preamble, bare payload line" \
  '# Changelog\n\n<!--\nrelease-notes: skip\n-->\n\n## [0.30.0]\n\nReal.\n'
no_empty_release "preamble, split at the colon" \
  '# Changelog\n\n<!-- release-notes: skip\n  x -->\n\n## [0.30.0]\n\nReal.\n'
no_empty_release "preamble, unterminated comment" \
  '# Changelog\n\n<!-- never closed\n\n## [0.30.0]\n\nReal.\n'
no_empty_release "preamble, unterminated fence" \
  '# Changelog\n\n```\nopen\n\n## [0.30.0]\n\nReal.\n'
no_empty_release "in-release, bare payload line" \
  '# Changelog\n\n## [0.30.0]\n\n<!--\nrelease-notes: skip\n-->\n\nInternal.\n'

# And the preamble wording is positively asserted, not merely "not []".
printf '# Changelog\n\n<!--\nrelease-notes: skip\n-->\n\n## [0.30.0]\n\nReal.\n' > "$T/pre.md"
pre_err="$(bash "$GEN" --changelog "$T/pre.md" --stdout 2>&1 >/dev/null)"
expect_contains "a preamble fault says so in words" "$pre_err" "before the first release heading"
# ...while a fault inside a release still names that release.
printf '# Changelog\n\n## [0.30.0]\n\n<!-- release-notes:\n  skip -->\n\nInternal.\n' > "$T/inr.md"
inr_err="$(bash "$GEN" --changelog "$T/inr.md" --stdout 2>&1 >/dev/null)"
expect_contains "a fault inside a release still names the release" "$inr_err" "release [0.30.0]"

echo "== a directive counts only as the FIRST content in its block =="

# The natural way to DOCUMENT this feature is prose, then the marker on its own line
# as the example - and that shape silently deleted the documenting release own note,
# with no diagnostic, which made the very next release commit the likely victim. A
# whole-line match anywhere in the block was not a strict enough rule: a directive is
# an instruction only as the first content, and anything after prose or a bullet has
# begun is a demonstration.
python3 - "$T/selfdoc.md" <<'PYX'
import sys
open(sys.argv[1], "w").write("""# Changelog

## [0.25.0]

Adds release notes shown at update time.

### Added

- **Curation.** A release with nothing user-visible is marked in its changelog block with

<!-- release-notes: skip -->

  and then produces no note at all.

## [0.24.0]

Tightens both main-sync points.
""")
PYX
sd="$(bash "$GEN" --changelog "$T/selfdoc.md" --stdout 2>&1)"; sd_rc=$?
# UPDATED at Gate B round 7, and the direction matters. Round 14 established that this
# shape must not SILENTLY delete the documenting release note. It then stayed silent in
# the other direction too, which was the actual R5 breach: a real `skip` written below the
# lead paragraph published the internal release, rc 0, no diagnostic. Both readings of the
# shape are unresolvable by parsing, but they share ONE correct instruction - move a real
# directive to the top of the block; fence a real example - so the generator now reports
# and says exactly that. Round 14 requirement (no silent note deletion) still holds: the
# note is not deleted, the build stops.
expect_eq "a marker below the lead paragraph is REPORTED, not silently ignored" "$sd_rc" "2"
expect_contains "  ...and the message names the release" "$sd" "[0.25.0]"
expect_contains "  ...and it says a directive must be the FIRST content" "$sd" "FIRST content"
expect_contains "  ...and it offers the example escape hatch" "$sd" "fenced code block"

# And the advice the message gives must actually WORK - a fenced example keeps its note.
# This is the shape a release documenting the feature should use (an unfenced HTML comment
# renders as nothing, so it never displayed the marker to a reader anyway).
python3 - "$T/selfdoc-fenced.md" <<'PYX'
import sys
open(sys.argv[1], "w").write("""# Changelog

## [0.25.0]

Adds release notes shown at update time.

### Added

- **Curation.** Mark a release with nothing user-visible like this:

  ```
  <!-- release-notes: skip -->
  ```

  and it produces no note at all.

## [0.24.0]

Tightens both main-sync points.
""")
PYX
sdf="$(bash "$GEN" --changelog "$T/selfdoc-fenced.md" --stdout 2>&1)"; sdf_rc=$?
expect_eq "the FENCED way to document the marker succeeds" "$sdf_rc" "0"
expect_eq "  ...and the documenting release keeps its own note" \
  "$(printf '%s' "$sdf" | jq -r '."0.25.0"')" "Adds release notes shown at update time."
expect_eq "  ...and the other release is unaffected" \
  "$(printf '%s' "$sdf" | jq -r '."0.24.0"')" "Tightens both main-sync points."

echo "== POSITION axis: a real directive below the lead paragraph never vanishes =="

# Gate B round 7. All three documents said only "inside the release block", so this is the
# placement the docs invited - and both payload kinds failed in the harmful direction: the
# skip-marked internal release was PUBLISHED to users (the R5 breach the feature exists to
# prevent) and the maintainer override was DISCARDED. rc 0, no stderr, and the drift test
# structurally cannot see it. Position is now part of the documented contract.
pos_check(){ # <label> <body>
  printf '# Changelog\n\n## [0.26.0]\n\nA lead paragraph first.\n\n%b\n' "$2" > "$T/pos.md"
  out="$(bash "$GEN" --changelog "$T/pos.md" --stdout 2>&1)"; rc=$?
  expect_eq "marker below the lead is reported: $1" "$rc" "2"
  expect_contains "  ...naming the release: $1" "$out" "[0.26.0]"
}
pos_check "skip"     '<!-- release-notes: skip -->'
pos_check "override" '<!-- release-notes: Adds a resume picker. -->'

# Below a BULLET counts as below content too.
printf '# Changelog\n\n## [0.26.0]\n\n### Fixed\n\n- **A bullet.** Some detail.\n\n<!-- release-notes: skip -->\n' > "$T/posb.md"
expect_eq "marker below a bullet is reported too" \
  "$(bash "$GEN" --changelog "$T/posb.md" --stdout >/dev/null 2>&1; echo $?)" "2"

# The CORRECT placement must still honour both payload kinds - the fix must not have
# turned the feature off.
printf '# Changelog\n\n## [0.26.0]\n\n<!-- release-notes: skip -->\n\nInternal.\n\n## [0.25.0]\n\n<!-- release-notes: Adds a resume picker. -->\n\nLead.\n' > "$T/posok.md"
pok="$(bash "$GEN" --changelog "$T/posok.md" --stdout 2>/dev/null)"
expect_eq "correct placement: skip still omits the release" \
  "$(printf '%s' "$pok" | jq 'has("0.26.0")')" "false"
expect_eq "correct placement: override still applies" \
  "$(printf '%s' "$pok" | jq -r '."0.25.0"')" "Adds a resume picker."

echo "== a note that FLATTENS to empty is refused, not shipped as \"\" =="

# Gate B round 8. flush() tested the RAW note while the print path emitted clean(note),
# and clean() deletes every asterisk - so a `***` thematic break as the first content
# passed the guard and shipped as "X.Y.Z": "". The whole loud-refusal contract was
# bypassed: generator printed success, --check said up to date, and at runtime the
# renderer drops an empty value so the hook took its nothing-to-report branch and
# ADVANCED the stamp, consuming that release's notice forever. Every CommonMark break
# spelling is pinned, because the asterisk ones flattened to empty while `---` and `___`
# survived clean() and shipped a note reading literally "---" - one defect, two symptoms.
for br in '***' '* * *' '****' '___' '_ _ _' '---' '- - -' '-----' '  ***  '; do
  printf '# Changelog\n\n## [0.26.0]\n\n%s\n\n## [0.25.0]\n\nOrdinary.\n' "$br" > "$T/br.md"
  br_out="$(bash "$GEN" --changelog "$T/br.md" --stdout 2>&1)"; br_rc=$?
  expect_eq "thematic break [$br] as first content is refused" "$br_rc" "2"
  expect_eq "  ...and no empty note is emitted for it" \
    "$(printf '%s' "$br_out" | jq -r '."0.26.0" // "absent"' 2>/dev/null || echo absent)" "absent"
done
expect_contains "the refusal names BOTH causes, asserting neither" \
  "$(printf '# Changelog\n\n## [0.26.0]\n\n***\n' > "$T/br2.md"; bash "$GEN" --changelog "$T/br2.md" --stdout 2>&1)" \
  "flattened to empty text"

# Real bullets and real leads must be untouched by the break predicate. `- - -` is a
# BREAK, `- a` is a BULLET, and one shared is_break() keeps the bullet capture and the
# structural test agreeing - when only the structural test knew, the bullet capture ran
# first and shipped a note reading "- -".
for b in '- **Headline.** Detail.' '- plain bullet' '* star bullet' '+ plus bullet' '- a'; do
  printf '# Changelog\n\n## [0.26.0]\n\n### Fixed\n\n%s\n' "$b" > "$T/bl.md"
  expect_eq "a real bullet is still a bullet: [$b]" \
    "$([ -n "$(bash "$GEN" --changelog "$T/bl.md" --stdout 2>/dev/null | jq -r '."0.26.0" // ""')" ] && echo ok || echo BROKEN)" "ok"
done
printf '# Changelog\n\n## [0.26.0]\n\nThe real lead paragraph.\n\n---\n\nTrailing prose.\n' > "$T/brlead.md"
expect_eq "a break AFTER the lead does not join the note" \
  "$(bash "$GEN" --changelog "$T/brlead.md" --stdout 2>/dev/null | jq -r '."0.26.0"')" "The real lead paragraph."

echo "== a fence STARTS the block, so a marker after one is not first content =="

# Gate B round 8. Rule 2's fence toggle was the only content-producing rule that left
# block_started at 0, so a marker placed after a fenced block but before any prose was
# still honoured as the FIRST content - rule 4b never saw it. A release documenting this
# feature with a fenced example followed by an unfenced one therefore deleted its own
# note, rc 0, no diagnostic. It also falsified the in-code claim that no cell is silent.
printf '# Changelog\n\n## [0.26.0]\n\n```md\nexample\n```\n\n<!-- release-notes: skip -->\n\nLead.\n' > "$T/fencemark.md"
fm="$(bash "$GEN" --changelog "$T/fencemark.md" --stdout 2>&1)"; fm_rc=$?
expect_eq       "marker after a fence is reported, not honoured" "$fm_rc" "2"
expect_contains "  ...as a mispositioned directive"              "$fm" "FIRST content"
# A fence-first release with a normal lead paragraph is unaffected.
printf '# Changelog\n\n## [0.26.0]\n\n```md\nexample\n```\n\nThe real lead paragraph.\n' > "$T/fencelead.md"
expect_eq "a fence-first release still takes its lead paragraph" \
  "$(bash "$GEN" --changelog "$T/fencelead.md" --stdout 2>/dev/null | jq -r '."0.26.0"')" "The real lead paragraph."

echo "== the SHIPPED release must be covered by the notes =="

# Gate B round 8. The count guard only catches ZERO releases; one mistyped heading
# catches nothing. `##  [X.Y.Z]` (two spaces), `##[X.Y.Z]`, `## X.Y.Z`, `### [X.Y.Z]`,
# `## [vX.Y.Z]`, `## [X.Y]` all fail the strict heading rule, so that release is
# swallowed as preamble - 9 releases instead of 10, count guard satisfied, and the drift
# test CANNOT see it (absent from both files reads as consistent). The user updates into
# that version, the renderer finds no key, and the hook advances the stamp: notes gone.
# Tested in an ISOLATED fake root, because the script derives ROOT from dirname $0/.. -
# so a copy under <tmp>/scripts sees <tmp> as the repo and the real tree is untouched.
FAKE="$T/fakeroot"
mkdir -p "$FAKE/scripts" "$FAKE/hooks/lib" "$FAKE/.claude-plugin"
cp "$GEN" "$FAKE/scripts/build-release-notes.sh"
cp "$LIB" "$FAKE/hooks/lib/changelog-notes.sh"
fake_run(){ # <plugin-version> <changelog-body>  -> "rc|refused"
  printf '{ "version": "%s" }\n' "$1" > "$FAKE/.claude-plugin/plugin.json"
  printf '%b' "$2" > "$FAKE/CHANGELOG.md"
  out="$(bash "$FAKE/scripts/build-release-notes.sh" --stdout 2>&1)"; rc=$?
  printf '%s|%s' "$rc" "$(printf '%s' "$out" | grep -qF 'has no note and no skip marker' && echo refused || echo allowed)"; }

GOOD='# Changelog\n\n## [0.26.0]\n\nA user-visible release.\n'
expect_eq "shipped version present in the notes: allowed" \
  "$(fake_run 0.26.0 "$GOOD")" "0|allowed"
expect_eq "shipped version legitimately skip-marked: allowed" \
  "$(fake_run 0.26.0 '# Changelog\n\n## [0.26.0]\n\n<!-- release-notes: skip -->\n\nInternal.\n\n## [0.25.0]\n\nOther.\n')" "0|allowed"
expect_eq "shipped version has no CHANGELOG entry at all: refused" \
  "$(fake_run 0.99.0 "$GOOD")" "2|refused"
for bad in '##  [0.26.0]' '##[0.26.0]' '## 0.26.0' '### [0.26.0]' '## [v0.26.0]' '## [0.26]'; do
  expect_eq "mistyped shipped heading refused: [$bad]" \
    "$(fake_run 0.26.0 "# Changelog\n\n$bad\n\nA user-visible release.\n\n## [0.25.0]\n\nOther.\n")" "2|refused"
done
expect_contains "the refusal explains the heading rule" \
  "$(printf '{ "version": "0.26.0" }\n' > "$FAKE/.claude-plugin/plugin.json"; printf '# Changelog\n\n##  [0.26.0]\n\nX.\n\n## [0.25.0]\n\nY.\n' > "$FAKE/CHANGELOG.md"; bash "$FAKE/scripts/build-release-notes.sh" --stdout 2>&1)" \
  "no extra spaces, no leading v, three components"
# A --changelog FIXTURE must not trip the check: a fixture has no relation to plugin.json.
expect_eq "a --changelog fixture does not trigger the shipped-version check" \
  "$(printf '# Changelog\n\n## [0.1.0]\n\nUnrelated fixture.\n' > "$T/unrel.md"; bash "$GEN" --changelog "$T/unrel.md" --stdout >/dev/null 2>&1; echo $?)" "0"

echo "== every `.` source site is guarded — enumerated by OPERATION, not by guard =="

# Round 27. The round-26 sweep grepped for existing `[ -r "` guards and concluded it was
# exhaustive - but a grep for guards can only find sites that already HAVE one, so the
# generator's own `. "$ROOT/hooks/lib/changelog-notes.sh"`, which had no test at all, was
# structurally invisible to it. Sourcing a FIFO blocks, so that hung the generator.
# This assertion inverts the method: enumerate the OPERATION (`.`) and require a guard for
# each, so a future unguarded source fails here instead of being missed by a pattern.
: > "$T/unguarded_sources"
# EXACT-EXPRESSION matching. Two earlier versions of this check passed while the defect was
# present, each for its own reason, and both were caught by mutation-testing the assertion
# rather than trusting it: the first matched only `. "$VAR"` and missed
# `. "$ROOT/path/x.sh"`; the second reduced the argument to its first variable, so a guard
# on `[ -f "$ROOT/.claude-plugin/plugin.json" ]` satisfied a source of `"$ROOT/hooks/..."`
# because both start with $ROOT. Requiring the guard to name the SAME expression is both
# simpler and exactly the property worth enforcing: guard the thing you actually open.
for f in "$REPO/hooks/release-notes.sh" "$REPO/hooks/lib/release-notes-render.sh" \
         "$REPO/hooks/lib/changelog-notes.sh" "$REPO/scripts/build-release-notes.sh"; do
  grep -vE '^[[:space:]]*#' "$f" \
    | grep -oE '^[[:space:]]*(\.|source)[[:space:]]+"[^"]*"' \
    | grep -oE '"[^"]*"' \
    | while read -r arg; do
        [ -n "$arg" ] || continue
        grep -qF "[ -f $arg" "$f" \
          || printf '%s:%s\n' "$(basename "$f")" "$arg" >> "$T/unguarded_sources"
      done
done
expect_eq "no \`.\` sources a path without a regular-file guard on the SAME expression" \
  "$(tr '\n' ' ' < "$T/unguarded_sources")" ""
src_count=0
for f in "$REPO/hooks/release-notes.sh" "$REPO/scripts/build-release-notes.sh"; do
  n="$(grep -vE '^[[:space:]]*#' "$f" | grep -cE '^[[:space:]]*(\.|source)[[:space:]]+"')"
  src_count=$((src_count + n))
done
expect_eq "  ...and the enumeration found both source sites (not vacuous)" "$src_count" "2"

# The generator's own lib source, behaviourally: a FIFO must fail fast, not block.
GENFAKE="$T/genfake"
mkdir -p "$GENFAKE/scripts" "$GENFAKE/hooks/lib" "$GENFAKE/.claude-plugin"
cp "$GEN" "$GENFAKE/scripts/build-release-notes.sh"
printf '{ "version": "0.1.0" }\n' > "$GENFAKE/.claude-plugin/plugin.json"
printf '# Changelog\n\n## [0.1.0]\n\nX.\n' > "$GENFAKE/CHANGELOG.md"
mkfifo "$GENFAKE/hooks/lib/changelog-notes.sh" 2>/dev/null
perl -e 'alarm 8; exec @ARGV' bash "$GENFAKE/scripts/build-release-notes.sh" --stdout \
  >/dev/null 2>"$T/genlib_err"
gl_rc=$?
expect_eq       "FIFO generator lib: completes without blocking" "$([ "$gl_rc" -ge 140 ] && echo HUNG || echo ok)" "ok"
expect_eq       "FIFO generator lib: refuses"                    "$gl_rc" "2"
expect_contains "FIFO generator lib: says why"                   "$(cat "$T/genlib_err")" "not a readable regular file"

echo "== a non-regular --changelog or --out must fail fast, never block =="

# Round 26, the dev-time half of the same class the FIFO stamp and FIFO notes file
# belong to. `[ -r ]` passes for a FIFO, so awk would block reading one forever and
# `> "$OUT"` blocks writing to one until a reader appears - a maintainer's terminal
# hung instead of a session, but the same defect. Each runs under an ALARM so a
# regression fails the suite rather than hanging it (macOS has no `timeout`).
mkfifo "$T/cl.fifo" 2>/dev/null
perl -e 'alarm 8; exec @ARGV' bash "$GEN" --changelog "$T/cl.fifo" --stdout >/dev/null 2>"$T/clf_err"
clf_rc=$?
expect_eq       "FIFO --changelog: completes without blocking" "$([ "$clf_rc" -ge 140 ] && echo HUNG || echo ok)" "ok"
expect_eq       "FIFO --changelog: refuses"                    "$clf_rc" "2"
expect_contains "FIFO --changelog: says why"                   "$(cat "$T/clf_err")" "not a readable regular file"

mkfifo "$T/out.fifo" 2>/dev/null
perl -e 'alarm 8; exec @ARGV' bash "$GEN" --out "$T/out.fifo" >/dev/null 2>"$T/outf_err"
outf_rc=$?
expect_eq       "FIFO --out: completes without blocking" "$([ "$outf_rc" -ge 140 ] && echo HUNG || echo ok)" "ok"
expect_eq       "FIFO --out: refuses"                    "$outf_rc" "2"
expect_contains "FIFO --out: says why"                   "$(cat "$T/outf_err")" "not a regular file"
expect_eq       "FIFO --out: the FIFO was left a FIFO"   "$([ -p "$T/out.fifo" ] && echo fifo || echo CHANGED)" "fifo"

# A directory as --changelog must also fail fast rather than produce a confusing parse.
# The extractor validates its own input too - it is a sourced public contract and the
# drift test calls it directly, so it does not rely on the generator having checked.
. "$LIB"
mkfifo "$T/cn.fifo" 2>/dev/null
perl -e 'alarm 8; exec @ARGV' bash -c '. "$1"; cn_extract_all "$2"' _ "$LIB" "$T/cn.fifo" >/dev/null 2>&1
cnf_rc=$?
expect_eq "FIFO into cn_extract_all: completes without blocking" \
  "$([ "$cnf_rc" -ge 140 ] && echo HUNG || echo ok)" "ok"
expect_eq "FIFO into cn_extract_all: returns 0 with no output" "$cnf_rc" "0"
expect_eq "  ...and the real changelog still extracts" \
  "$([ "$(cn_extract_all "$CHANGELOG" | grep -c .)" -gt 40 ] && echo yes || echo no)" "yes"

expect_eq "a DIRECTORY as --changelog refuses" \
  "$(mkdir -p "$T/cldir"; bash "$GEN" --changelog "$T/cldir" --stdout >/dev/null 2>&1; echo $?)" "2"

echo "== the generator refuses to write an EMPTY notes file =="

# Gate B round 7. The old guard tested `[ -n "$notes_json" ]`, which could never fire
# because from_entries on an empty row set returns the two-byte string `{}`. A changelog
# with no `## [X.Y.Z]` heading therefore CLOBBERED a good notes file with `{}` at exit 0,
# reporting "wrote … (0 releases, newest )" - the maximal instance of the one thing this
# generator promises never to do, with a runtime tail: an empty artifact makes the hook
# take its nothing-in-range path, which ADVANCES the stamp and consumes every notice.
printf '{ "0.24.0": "a real note" }\n' > "$T/keep.json"
printf '# Changelog\n\nPreamble prose but no release headings at all.\n' > "$T/nohead.md"
zr="$(bash "$GEN" --changelog "$T/nohead.md" --out "$T/keep.json" 2>&1)"; zr_rc=$?
expect_eq       "zero releases: refuses to write"        "$zr_rc" "2"
expect_contains "zero releases: says why"                "$zr" "0 releases"
expect_contains "zero releases: names the missing shape" "$zr" '## [X.Y.Z]'
expect_eq       "zero releases: the existing file is UNTOUCHED" \
  "$(cat "$T/keep.json")" '{ "0.24.0": "a real note" }'
: > "$T/byteempty.md"
expect_eq "a byte-empty changelog also refuses" \
  "$(bash "$GEN" --changelog "$T/byteempty.md" --stdout >/dev/null 2>&1; echo $?)" "2"
printf '# Changelog\n\n## v0.25.0\n\nA drifted heading style.\n' > "$T/drifted.md"
expect_eq "a drifted heading style also refuses" \
  "$(bash "$GEN" --changelog "$T/drifted.md" --stdout >/dev/null 2>&1; echo $?)" "2"

# The refusal must name BOTH causes and assert neither. Zero releases is also reachable
# with correct headings - every release skip-marked - and blaming a missing heading would
# send the maintainer to the wrong place. Third diagnostic in this run to name a cause it
# could not know, so it is pinned rather than trusted.
printf '# Changelog\n\n## [0.26.0]\n\n<!-- release-notes: skip -->\n\nInternal.\n\n## [0.25.0]\n\n<!-- release-notes: skip -->\n\nAlso internal.\n' > "$T/allskip.md"
as_err="$(bash "$GEN" --changelog "$T/allskip.md" --out "$T/allskip.json" 2>&1)"; as_rc=$?
expect_eq       "every-release-skipped also refuses to write" "$as_rc" "2"
expect_contains "  ...and names the all-skipped cause"        "$as_err" "every release in the file is marked"
expect_contains "  ...and still names the missing-heading cause" "$as_err" '## [X.Y.Z]'
expect_eq       "  ...and writes nothing" "$([ -e "$T/allskip.json" ] && echo exists || echo absent)" "absent"

# The accepted false positive is PINNED, not left to be rediscovered as a bug: a marker in
# a 4-space indented code block reports. Narrowing rule 4b to ignore it would make a real
# directive indented by four spaces silent again, which is the worse direction.
printf '# Changelog\n\n## [0.26.0]\n\nA lead paragraph first.\n\n    <!-- release-notes: skip -->\n' > "$T/indented.md"
expect_eq "ACCEPTED: a marker in an indented code block reports (noisy beats silent)" \
  "$(bash "$GEN" --changelog "$T/indented.md" --stdout >/dev/null 2>&1; echo $?)" "2"


# The genuine forms - marker as the first content - must still work in both flavours.
printf '# Changelog\n\n## [0.30.0]\n\n<!-- release-notes: skip -->\n\nInternal.\n\n## [0.29.0]\n\n<!-- release-notes: Real override. -->\n\nReplaced.\n\n## [0.28.0]\n\nNormal.\n' > "$T/first.md"
fst="$(bash "$GEN" --changelog "$T/first.md" --stdout 2>/dev/null)"
expect_eq "a leading skip directive still omits the release" \
  "$(printf '%s' "$fst" | jq 'has("0.30.0")')" "false"
expect_eq "a leading override directive still applies" \
  "$(printf '%s' "$fst" | jq -r '."0.29.0"')" "Real override."

# And the two real skip-marked releases put the marker first, so they are unaffected.
. "$LIB"
expect_eq "real 0.21.0 is still skipped" "$(cn_note "$CHANGELOG" 0.21.0)" ""
expect_eq "real 0.17.1 is still skipped" "$(cn_note "$CHANGELOG" 0.17.1)" ""

echo "== a directive spelled across lines is reported, not ignored =="

# Rule 1 swallows a multi-line comment before the directive rule can see it, so a
# `skip` written that way was silently ignored and the internal release published -
# R5 violated with no signal at all. The asymmetry was the tell: the same intent on
# ONE line was already fatal.
printf '# Changelog\n\n## [0.30.0]\n\n<!--\nrelease-notes: skip\n-->\n\nInternal only.\n' > "$T/mldir.md"
ml="$(bash "$GEN" --changelog "$T/mldir.md" --stdout 2>&1)"; ml_rc=$?
expect_eq       "multi-line skip directive: refuses to write" "$ml_rc" "2"
expect_contains "multi-line skip directive: names the release" "$ml" "[0.30.0]"
expect_contains "multi-line skip directive: says it is not recognised" "$ml" "MULTI-LINE comment"

echo "== maintainer-error shapes that used to be silent =="

# (a) A duplicated release heading: the generator sliced ROWS before collapsing
# duplicate keys, so the stale older block won AND one in-window release vanished,
# with exit 0 and no diagnostic.
python3 - "$T/dup.md" <<'PYX'
import sys
parts = ["# Changelog\n"]
for i, v in enumerate(["0.30.0","0.29.0","0.28.0","0.27.0","0.26.0",
                       "0.25.0","0.24.0","0.23.0","0.22.0","0.21.0"]):
    parts.append("\n## [%s]\n\nLead for %s.\n" % (v, v))
    if i == 1:
        parts.append("\n## [0.30.0]\n\nSTALE duplicate.\n")
open(sys.argv[1], "w").write("".join(parts))
PYX
dup="$(bash "$GEN" --changelog "$T/dup.md" --stdout 2>&1)"; dup_rc=$?
expect_eq       "duplicate heading: refuses to write" "$dup_rc" "2"
expect_contains "duplicate heading: names the release" "$dup" "[0.30.0]"
expect_contains "duplicate heading: explains the consequence" "$dup" "appears more than once"

# (b) A release that opens with structure and has no lead paragraph: later prose -
# including a 4-space indented code block, which no fence rule tracks - became the
# note, so the documented first-bullet fallback never ran.
python3 - "$T/leadless.md" <<'PYX'
import sys
open(sys.argv[1], "w").write("""# Changelog

## [0.26.0]

### Added

- **Documents the curation marker.** Maintainers can mark internal releases.

      ## [9.9.9]
      Fake note that must never ship to users.
""")
PYX
# The lead phase must NOT close on just any structural line: a release whose lead
# paragraph follows a blockquote callout or a table is legitimate. Closing there made
# the callout case take the bullet instead, and the table case fail outright with
# "yielded no note". Only capturing a BULLET closes the phase.
python3 - "$T/callout.md" <<'PYX'
import sys
open(sys.argv[1], "w").write("""# Changelog

## [0.26.0]

> **Heads-up.** Settings reset once per project.

Adds an autonomy model with exception-triggered gates.

### Added

- **Something.** detail
""")
PYX
expect_eq "a lead paragraph AFTER a blockquote callout is still the note" \
  "$(bash "$GEN" --changelog "$T/callout.md" --stdout 2>/dev/null | jq -r '."0.26.0"')" \
  "Adds an autonomy model with exception-triggered gates."

python3 - "$T/table.md" <<'PYX'
import sys
open(sys.argv[1], "w").write("""# Changelog

## [0.26.0]

| a | b |
|---|---|
| 1 | 2 |

Real lead paragraph after the table.
""")
PYX
expect_eq "a lead paragraph AFTER a table is still the note" \
  "$(bash "$GEN" --changelog "$T/table.md" --stdout 2>/dev/null | jq -r '."0.26.0"')" \
  "Real lead paragraph after the table."

expect_eq "lead-less release uses the first-bullet fallback" \
  "$(bash "$GEN" --changelog "$T/leadless.md" --stdout 2>/dev/null | jq -r '."0.26.0"')" \
  "Documents the curation marker."
expect_eq "  ...and indented example content never becomes the note" \
  "$(bash "$GEN" --changelog "$T/leadless.md" --stdout 2>/dev/null | jq '[.[] | select(test("9.9.9"))] | length')" "0"

# (c) A near-miss directive fell through to the override branch, so a release the
# maintainer meant to hide was published AND titled with the typo.
printf '# Changelog\n\n## [0.30.0]\n\n<!-- release-notes: SKIP -->\n\nInternal.\n' > "$T/nearmiss.md"
nm="$(bash "$GEN" --changelog "$T/nearmiss.md" --stdout 2>&1)"; nm_rc=$?
expect_eq       "near-miss skip directive: refuses to write" "$nm_rc" "2"
expect_contains "near-miss skip directive: explains the fix" "$nm" "misspelled skip directive"

# The genuine forms must still work.
printf '# Changelog\n\n## [0.30.0]\n\n<!-- release-notes: skip -->\n\nInternal.\n\n## [0.29.0]\n\n<!-- release-notes: Real override. -->\n\nReplaced.\n\n## [0.28.0]\n\nNormal.\n' > "$T/ok.md"
ok="$(bash "$GEN" --changelog "$T/ok.md" --stdout 2>/dev/null)"
expect_eq "genuine skip still omits the release" "$(printf '%s' "$ok" | jq 'has("0.30.0")')" "false"
expect_eq "genuine override still applies"       "$(printf '%s' "$ok" | jq -r '."0.29.0"')" "Real override."

# And the four real lead-less releases still resolve via the bullet fallback.
. "$LIB"
expect_eq "real 0.1.2 still uses its bullet headline" \
  "$(cn_note "$CHANGELOG" 0.1.2)" "Update command uses the marketplace-qualified plugin name."

echo "== CRLF input, and one diagnostic per problem =="

# A CRLF checkout (no .gitattributes here, so core.autocrlf=true produces one) made
# `-->[ \t]*$` unmatchable, which SILENTLY discarded every curation directive and
# leaked raw CR into the notes - where it returns the terminal cursor to column 0
# and the note overwrites its own bullet prefix.
python3 - "$T/crlf.md" <<'PYX'
import sys
body = ("# Changelog\n\n## [0.25.0]\n\n<!-- release-notes: skip -->\n\n"
        "Internal only.\n\n## [0.24.0]\n\nA real release.\n")
open(sys.argv[1], "wb").write(body.replace("\n", "\r\n").encode())
PYX
crlf="$(bash "$GEN" --changelog "$T/crlf.md" --stdout 2>/dev/null)"
expect_eq "CRLF: the skip directive is still honoured" \
  "$(printf '%s' "$crlf" | jq 'has("0.25.0")')" "false"
expect_eq "CRLF: the real release is still emitted" \
  "$(printf '%s' "$crlf" | jq -r '."0.24.0"')" "A real release."
expect_eq "CRLF: no carriage return reaches a note value" \
  "$(printf '%s' "$crlf" | jq '[.[] | select(test("\\r"))] | length')" "0"

# A truncated block always leaves note=="" too, so both guards used to fire for the
# same release - and the second one advised adding a `skip` marker, which is the one
# action that converts this loud failure into the silent dropped release the guard
# exists to prevent.
python3 - "$T/trunc2.md" <<'PYX'
import sys
open(sys.argv[1], "w").write(
    "# Changelog\n\n## [0.25.0]\n\n<!-- release-notes: skip\n\n"
    "Adds the release-notes surfaces.\n\n### Added\n\n- **Thing.** detail\n")
PYX
tr_out="$(bash "$GEN" --changelog "$T/trunc2.md" --stdout 2>&1)"
expect_eq "truncated block: reported as unterminated" \
  "$(printf '%s\n' "$tr_out" | grep -c 'unterminated HTML comment')" "1"
expect_eq "truncated block: NOT also reported as noteless" \
  "$(printf '%s\n' "$tr_out" | grep -c 'yielded no note')" "0"

echo "== embedded programs carry no self-truncating characters =="

# Two mistakes made while writing this feature, both of which produced a WRONG BUT
# VALID result rather than an error, so neither `bash -n` nor a normal test caught
# them: an apostrophe inside the single-quoted awk/jq program silently truncated it
# at the shell level, and a literal NUL byte in a comment silently truncated the jq
# program at the C level (jq then ran only the part before it). Cheap to assert,
# and it would have caught both instantly.
for lib in hooks/lib/changelog-notes.sh hooks/lib/release-notes-render.sh; do
  ctrl="$(python3 - "$REPO/$lib" <<'PYCHK'
import sys
d = open(sys.argv[1], "rb").read()
bad = sorted({b for b in d if b < 9 or (10 < b < 32)})
print(",".join(str(b) for b in bad) if bad else "none")
PYCHK
)"
  expect_eq "$lib has no stray control bytes" "$ctrl" "none"

  # Apostrophes may appear in shell comments OUTSIDE the quoted program, but never
  # inside it. Extract the single-quoted program body and check that.
  apos="$(python3 - "$REPO/$lib" <<'PYCHK'
import re, sys
src = open(sys.argv[1]).read()
# the embedded program is the longest single-quoted run passed to awk/jq
runs = re.findall(r"(?:awk|jq)\b[^\n]*'\n(.*?)\n\s*'", src, re.S)
print(sum(r.count("'") for r in runs))
PYCHK
)"
  expect_eq "$lib embedded program contains no apostrophes" "$apos" "0"
done

echo "== the return-3 contract holds for BOTH exported functions =="

# The header promises callers must treat 3 as fatal. cn_note used to pipe through a
# second awk, and a pipeline yields the LAST status — so the 3 was swallowed and a
# truncated changelog was indistinguishable from "no note for this version".
# shellcheck source=../hooks/lib/changelog-notes.sh
. "$LIB"
printf '# Changelog\n\n## [7.0.0]\n\n<!-- unterminated\n\nLead.\n' > "$T/rc.md"
cn_extract_all "$T/rc.md" >/dev/null 2>&1
expect_eq "cn_extract_all returns 3 on a truncated changelog" "$?" "3"
cn_note "$T/rc.md" 7.0.0 >/dev/null 2>&1
expect_eq "cn_note also returns 3 (contract holds for both)" "$?" "3"
cn_note "$CHANGELOG" 0.24.0 >/dev/null 2>&1
expect_eq "cn_note returns 0 on a well-formed changelog" "$?" "0"
expect_eq "cn_note still returns the right note" \
  "$(cn_note "$CHANGELOG" 0.24.0 | cut -c1-38)" "Tightens both main-sync points so a ru"
expect_eq "cn_note returns nothing for a skip-marked release" \
  "$(cn_note "$CHANGELOG" 0.21.0)" ""

echo "== generator hygiene =="

err="$(bash "$GEN" --changelog "$T/nope.md" --stdout 2>&1)"; rc=$?
expect_eq       "missing changelog exits 2" "$rc" "2"
expect_contains "missing changelog explains why" "$err" "not a readable regular file"
expect_contains "missing changelog names the path"  "$err" "nope.md"

err="$(bash "$GEN" --bogus-flag 2>&1)"; rc=$?
expect_eq "unknown flag exits 2" "$rc" "2"

# Writing is idempotent: two runs produce the same bytes.
bash "$GEN" --out "$T/w1.json" >/dev/null 2>&1
bash "$GEN" --out "$T/w2.json" >/dev/null 2>&1
expect_eq "generation is idempotent" \
  "$(cmp -s "$T/w1.json" "$T/w2.json" && echo same || echo differs)" "same"

printf '================ SUMMARY: %d passed, %d failed ================\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
