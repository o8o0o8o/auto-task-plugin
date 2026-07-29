#!/usr/bin/env bash
# spec-helper.test.sh — tests for tests/lib/spec.sh.
#
# Covers all four assertion SHAPES the real suite contains (presence, summed
# count, zero count, positional) across a spine/reference boundary, using a
# throwaway fixture so the real spec is never touched.
#
# Also carries the AC #11 MUTATION PROBE: proof that a spine-only assertion
# actually FAILS when its content is relocated into a reference. Without that
# probe, "must-stay contracts are asserted in the spine" is an untested claim —
# the assertion could be passing via a union search and nobody would know.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
ok() { # ok <label> <actual> <expected>
  if [ "$2" = "$3" ]; then pass=$((pass+1));
  else fail=$((fail+1)); printf 'FAIL  %s\n        got:      %s\n        expected: %s\n' "$1" "$2" "$3" >&2; fi
}
okrc() { # okrc <label> <expected-rc> <cmd...>
  local label="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1));
  else fail=$((fail+1)); printf 'FAIL  %s\n        rc: %s expected: %s\n' "$label" "$got" "$want" >&2; fi
}

# ------------------------------------------------------------------ fixture
FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/skills/auto-task/references"

cat > "$FIX/skills/auto-task/SKILL.md" <<'EOF'
# Spine
SHARED_PHRASE appears once here.
SPINE_ONLY_CONTRACT must never move.
ANCHOR_A first anchor.
padding one
padding two
ANCHOR_B second anchor.
EOF

cat > "$FIX/skills/auto-task/references/ref-one.md" <<'EOF'
# Reference one
SHARED_PHRASE appears once here.
REF_ONLY_PHRASE lives only in a reference.
ANCHOR_C anchor in another file.
EOF

export SPEC_ROOT="$FIX"
export SPEC_SPINE="$FIX/skills/auto-task/SKILL.md"
export SPEC_REFDIR="$FIX/skills/auto-task/references"
# shellcheck source=tests/lib/spec.sh
. "$ROOT/tests/lib/spec.sh"

# ------------------------------------------------------- shape 1: presence
ok   "spec_files lists spine first"      "$(spec_files | head -1)" "$SPEC_SPINE"
ok   "spec_files finds both files"       "$(spec_files | wc -l | tr -d ' ')" "2"
okrc "spec_has finds a spine string"   0 spec_has "SPINE_ONLY_CONTRACT"
okrc "spec_has finds a REFERENCE-only string (the whole point)" 0 spec_has "REF_ONLY_PHRASE"
okrc "spec_has rejects an absent string" 1 spec_has "NO_SUCH_STRING_ANYWHERE"
okrc "spec_has_re matches a regex"     0 spec_has_re "REF_(ONLY|OTHER)_PHRASE"

# --------------------------------------------------- shape 2: summed count
# The load-bearing case: one occurrence in EACH file must sum to 2, so an
# exact-count assertion survives a phrase being relocated.
ok "spec_count sums across spine+reference" "$(spec_count 'SHARED_PHRASE')" "2"
ok "spec_count of a spine-only string"      "$(spec_count 'SPINE_ONLY_CONTRACT')" "1"
ok "spec_count of a reference-only string"  "$(spec_count 'REF_ONLY_PHRASE')" "1"
ok "spec_count_re sums by regex"            "$(spec_count_re 'ANCHOR_[AB]')" "2"

# ----------------------------------------------------- shape 3: zero count
# Anti-regression assertions: union scope is CORRECT, so stale phrasing cannot
# hide in a reference file.
ok "spec_count of an absent string is 0"    "$(spec_count 'NO_SUCH_STRING_ANYWHERE')" "0"
printf 'STALE_PHRASING lurking in a reference.\n' >> "$SPEC_REFDIR/ref-one.md"
ok "zero-count assertion CATCHES stale phrasing hidden in a reference" \
   "$(spec_count 'STALE_PHRASING')" "1"
# restore the fixture
grep -v 'STALE_PHRASING' "$SPEC_REFDIR/ref-one.md" > "$FIX/t" && mv "$FIX/t" "$SPEC_REFDIR/ref-one.md"
ok "fixture restored" "$(spec_count 'STALE_PHRASING')" "0"

# ------------------------------------------------------ shape 4: positional
ok   "spec_file_of resolves the owning file" "$(basename "$(spec_file_of 'REF_ONLY_PHRASE')")" "ref-one.md"
ok   "spec_line reports file:lineno"         "$(spec_line 'ANCHOR_A' | sed 's#.*/##')" "SKILL.md:4"
ok   "spec_window stays inside the anchor's own file" \
     "$(spec_window 'ANCHOR_A' 3 | grep -c 'ANCHOR_B')" "1"
ok   "spec_window does NOT bleed into the other file" \
     "$(spec_window 'ANCHOR_A' 20 | grep -c 'ANCHOR_C')" "0"
okrc "spec_same_file: two spine anchors"   0 spec_same_file "ANCHOR_A" "ANCHOR_B"
okrc "spec_same_file: cross-file anchors"  1 spec_same_file "ANCHOR_A" "ANCHOR_C"
okrc "spec_before: correct order"          0 spec_before "ANCHOR_A" "ANCHOR_B"
okrc "spec_before: reversed order"         1 spec_before "ANCHOR_B" "ANCHOR_A"
# The guard that matters: a cross-file pair must fail LOUDLY (rc 2), never
# silently compare meaningless line numbers from two different files.
okrc "spec_before: cross-file fails LOUDLY with rc=2" 2 spec_before "ANCHOR_A" "ANCHOR_C"
okrc "spec_before: missing anchor fails with rc=2"    2 spec_before "ANCHOR_A" "NO_SUCH_ANCHOR"

# ------------------------------------------------- AC #11 mutation probe
# Relocate a "must-stay" contract out of the spine and into a reference, then
# assert that (a) a spine-only grep FAILS, while (b) spec_has still succeeds.
# This is what makes the spine-only assertions in enforcement-spine.test.sh a
# real guarantee rather than an untested claim.
grep -v 'SPINE_ONLY_CONTRACT' "$SPEC_SPINE" > "$FIX/t" && mv "$FIX/t" "$SPEC_SPINE"
printf 'SPINE_ONLY_CONTRACT must never move.\n' >> "$SPEC_REFDIR/ref-one.md"

ok   "mutation probe: spine-only grep now FAILS (the guarantee has teeth)" \
     "$(grep -c 'SPINE_ONLY_CONTRACT' "$SPEC_SPINE" || true)" "0"
okrc "mutation probe: union spec_has still finds it (so the split is intact)" \
     0 spec_has "SPINE_ONLY_CONTRACT"
ok   "mutation probe: summed count is still 1 (relocated, not duplicated)" \
     "$(spec_count 'SPINE_ONLY_CONTRACT')" "1"

# ------------------------------------------- spec_concat_into (the new machinery)
# Round-2 review finding: spec_concat_into had ZERO coverage, so its trap chaining,
# named-variable assignment and fail-closed emptiness check were all unasserted — and
# three real defects lived in code the suite reported green. These assertions run in
# SUBSHELLS ( ... ) so each gets its own EXIT trap without disturbing this script.

# path is UNIQUE per call (a deterministic name collided across sibling worktrees and
# let one run truncate another's file, turning zero-count assertions vacuously green)
(
  . "$ROOT/tests/lib/spec.sh"
  spec_concat_into P1; spec_concat_into P2
  [ "$P1" != "$P2" ] || { echo "FAIL  spec_concat_into: paths not unique" >&2; exit 1; }
  [ -s "$P1" ] || { echo "FAIL  spec_concat_into: concat is empty" >&2; rm -f "$P1" "$P2"; exit 1; }
  rm -f "$P1" "$P2"   # explicit: trap-removal is asserted separately, below
) && pass=$((pass+1)) || fail=$((fail+1))

# the concatenation really is the union (a reference-only string must be present)
(
  . "$ROOT/tests/lib/spec.sh"
  spec_concat_into C
  # fixture-scoped: SPEC_* are exported above, so the union is the FIXTURE's
  r=0; { grep -qF 'REF_ONLY_PHRASE' "$C" && grep -qF 'SHARED_PHRASE' "$C"; } || r=1
  rm -f "$C"; exit $r
) && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL  spec_concat_into: concat is not the union" >&2; }

# EXIT trap removes the file
# The [ -n "$tf" ] precondition is load-bearing: without it an empty $tf (which is what a
# failed spec_concat_into produces) makes `[ -e "" ]` false and reads as "gone" — so this
# assertion passed against a total no-op implementation.
tf="$(bash -c '. "'"$ROOT"'/tests/lib/spec.sh"; spec_concat_into V; echo "$V"' | tail -1)"
ok "spec_concat_into: returned a path at all" "$([ -n "$tf" ] && echo yes || echo no)" "yes"
ok "spec_concat_into: EXIT trap removed the temp file" \
   "$([ -n "$tf" ] && [ ! -e "$tf" ] && echo gone || echo present)" "gone"

# TRAP CHAINING — assert BOTH halves. A round-3 review finding: asserting only that the
# caller's handler ran is one-directional and useless, because bash fires the caller's
# EXIT trap by DEFAULT. Those assertions passed against `spec_concat_into(){ return 1; }`
# — a total no-op — and that is precisely how a broken cleanup (the literal-"\n"
# separator bug) shipped green. Every chaining case must therefore verify the caller's
# handler ran AND the temp file was removed.
chain_probe() { # chain_probe <label> <trap-setting-snippet>
  local label="$1" setup="$2" out p ran gone
  out="$(bash -c "$setup"'; . "'"$ROOT"'/tests/lib/spec.sh"; spec_concat_into V; echo "PROBEPATH=$V"' 2>&1)"
  p="$(printf '%s' "$out" | sed -n 's/^PROBEPATH=//p')"
  ran="$(printf '%s' "$out" | grep -c CALLER_RAN)"
  gone="$([ -n "$p" ] && [ ! -e "$p" ] && echo gone || echo present)"
  ok "$label: caller handler still ran"   "$ran"  "1"
  ok "$label: temp file was ALSO removed" "$gone" "gone"
  [ -n "$p" ] && rm -f "$p"
}
chain_probe "chain single-line trap" 'trap "echo CALLER_RAN" EXIT'
chain_probe "chain MULTI-LINE trap"  'trap "
echo CALLER_RAN" EXIT'
chain_probe "chain trap with apostrophe" 'trap '"'"'echo "CALLER_RAN it'"'"'\'"'"''"'"'s done"'"'"' EXIT'

# The separator bug only manifests with TWO OR MORE concats in one shell (a single entry
# needs no separator), so cover that explicitly — this is the assertion that catches it.
multi="$(bash -c '. "'"$ROOT"'/tests/lib/spec.sh"; spec_concat_into A; spec_concat_into B; echo "P1=$A"; echo "P2=$B"' 2>&1)"
m1="$(printf '%s' "$multi" | sed -n 's/^P1=//p')"; m2="$(printf '%s' "$multi" | sed -n 's/^P2=//p')"
ok "two concats in one shell: BOTH cleaned up" \
   "$([ -n "$m1" ] && [ -n "$m2" ] && [ ! -e "$m1" ] && [ ! -e "$m2" ] && echo gone || echo leaked)" "gone"
rm -f "$m1" "$m2" 2>/dev/null

# An unreadable REFERENCE must fail closed, not contribute 0 matches silently.
badref="$(mktemp -d)"; mkdir -p "$badref/refs"
printf 'STALE_PHRASING\n' > "$badref/refs/r.md"; chmod 000 "$badref/refs/r.md"
bash -c 'export SPEC_SPINE="'"$SPEC_SPINE"'" SPEC_REFDIR="'"$badref"'/refs"; . "'"$ROOT"'/tests/lib/spec.sh"' >/dev/null 2>&1
ok "spec.sh: unreadable REFERENCE fails closed (exit 2)" "$?" "2"
chmod 644 "$badref/refs/r.md"; rm -rf "$badref"

# refuses a target name that collides with its own locals (would silently no-op)
# rc==1 alone is satisfied by ANY failure (a no-op returns 1 too), so also assert the
# specific refusal reached stderr and that the caller's variable was left unassigned.
collide_out="$(bash -c '. "'"$ROOT"'/tests/lib/spec.sh"; spec_concat_into __spec_out; echo "rc=$?"; echo "val=[${__spec_out:-UNSET}]"' 2>&1)"
ok "spec_concat_into: rejects a colliding target name (rc)" \
   "$(printf '%s' "$collide_out" | grep -c 'rc=1')" "1"
ok "spec_concat_into: says WHY it refused" \
   "$(printf '%s' "$collide_out" | grep -c 'refusing target name')" "1"
ok "spec_concat_into: leaves the colliding target unassigned" \
   "$(printf '%s' "$collide_out" | grep -c 'val=\[UNSET\]')" "1"

# FAIL-CLOSED: an unreadable spine must abort, never yield a vacuous zero-count
un="$(mktemp)"; printf 'STALE_PHRASING\n' > "$un"; chmod 000 "$un"
bash -c 'export SPEC_SPINE="'"$un"'" SPEC_REFDIR=/nonexistent-refs; . "'"$ROOT"'/tests/lib/spec.sh"' >/dev/null 2>&1
ok "spec.sh: unreadable spine fails closed (exit 2)" "$?" "2"
chmod 644 "$un"; rm -f "$un"

# FAIL-CLOSED: a refdir that exists but holds no *.md must abort, not silently narrow
emptyref="$(mktemp -d)"
bash -c 'export SPEC_REFDIR="'"$emptyref"'"; . "'"$ROOT"'/tests/lib/spec.sh"' >/dev/null 2>&1
ok "spec.sh: empty references dir fails closed (exit 2)" "$?" "2"
rmdir "$emptyref"

# A SYMLINKED reference must be IN the union (a bare -type f dropped it from both the
# union and the guard meant to validate it, so its content was invisible -> vacuous 0).
symfx="$(mktemp -d)"; mkdir -p "$symfx/refs"
printf '# Spine\nSPINEBIT\n' > "$symfx/SKILL.md"
printf 'REALREF\n' > "$symfx/refs/ref-one.md"
printf 'SYMLINKED_PHRASE\n' > "$symfx/target.md"; ln -s "$symfx/target.md" "$symfx/refs/ref-two.md"
# NOTE: `export` inside the subshell, NOT `VAR=x . file`. In bash 3.2 a prefix assignment
# on the `.` builtin is temporary-environment only, so the variable reverts to unset once
# the source returns — and a helper called afterwards would search the DEFAULT spec paths
# instead of the fixture (this silently broke the symlink assertion below when written
# that way). Sourcing-only checks survive the old idiom, but exporting is correct for all.
ok "symlinked reference is included in the union" \
   "$(bash -c 'export SPEC_SPINE="'"$symfx"'/SKILL.md" SPEC_REFDIR="'"$symfx"'/refs"; . "'"$ROOT"'/tests/lib/spec.sh"; spec_count SYMLINKED_PHRASE' 2>/dev/null)" "1"
rm -rf "$symfx"

# A MISSING references dir must fail closed, not silently narrow the union to the spine.
missfx="$(mktemp -d)"; printf '# Spine\nOK\n' > "$missfx/SKILL.md"
bash -c 'export SPEC_SPINE="'"$missfx"'/SKILL.md" SPEC_REFDIR="'"$missfx"'/nope"; . "'"$ROOT"'/tests/lib/spec.sh"' >/dev/null 2>&1
ok "spec.sh: missing references dir fails closed (exit 2)" "$?" "2"
rm -rf "$missfx"

# A .md entry that is a symlink to a DIRECTORY must fail closed. Both -r and -s pass on a
# directory (it has non-zero size), so it was admitted into the union while greps of it
# silently contributed nothing — the last traversal-exclusion route of that class.
dirfx="$(mktemp -d)"; mkdir -p "$dirfx/refs" "$dirfx/adir"
printf '# Spine\nOK\n' > "$dirfx/SKILL.md"; printf 'REALREF\n' > "$dirfx/refs/ok.md"
ln -s "$dirfx/adir" "$dirfx/refs/dirlink.md"
bash -c 'export SPEC_SPINE="'"$dirfx"'/SKILL.md" SPEC_REFDIR="'"$dirfx"'/refs"; . "'"$ROOT"'/tests/lib/spec.sh"' >/dev/null 2>&1
ok "spec.sh: directory-symlink reference fails closed (exit 2)" "$?" "2"
rm -rf "$dirfx"

# The cleanup must be registered exactly ONCE however many concats happen. The membership
# test has to use command substitution: bash resets the EXIT trap in a PIPELINE subshell,
# so `trap -p EXIT | grep -q` never matches and the body accumulated one copy per concat.
ok "spec_concat_into: cleanup registered exactly once for N concats" \
   "$(bash -c '. "'"$ROOT"'/tests/lib/spec.sh"; spec_concat_into A; spec_concat_into B; spec_concat_into C; trap -p EXIT' 2>/dev/null | grep -o _spec_concat_cleanup | wc -l | tr -d ' ')" "1"

# ------------------------------------------------------------------ summary
printf '\n================ SUMMARY: %d passed, %d failed ==============\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
