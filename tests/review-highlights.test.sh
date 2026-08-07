#!/usr/bin/env bash
# Focused test for hooks/review-highlights.sh — diff-side "Review this first" candidates.
#
# Asserts: each of the three detectors fires on its own signal and STAYS SILENT on
# the near-miss that would make it noisy (a guard ADDED rather than removed, a
# logic file WITH a co-changed test naming it, a docs-only edit); the two empty
# shapes are distinguishable (`{}` on failure vs `{"candidates":[]}` on a clean
# diff — `jq '.candidates|length'` errors on the former, which is why callers must
# probe with `has("candidates")`); a REMOVED line cites its pre-image coordinate;
# and — critically — the output carries NO signal derived from commit history,
# since this helper reports only what the diff shows.
#
# Hermetic: builds throwaway git repos in a temp dir; touches nothing real.
# Usage: tests/review-highlights.test.sh

set -uo pipefail

SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/review-highlights.sh"
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
[ -f "$SH" ] || { echo "FAIL: $SH missing"; exit 1; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-52s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-52s got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }

echo "================ review-highlights.sh ================"
bash -n "$SH"; expect "bash -n clean" "$?" "0"
expect "is executable" "$([ -x "$SH" ] && echo yes || echo no)" "yes"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# newrepo <name> -> creates $T/<name> as a git repo, prints nothing
newrepo(){ git init -q "$T/$1"; git -C "$T/$1" config user.email t@t; git -C "$T/$1" config user.name t; }
base_of(){ git -C "$T/$1" rev-parse HEAD; }
commit_all(){ git -C "$T/$1" add -A; git -C "$T/$1" commit -qm "${2:-c}" >/dev/null 2>&1; }
run(){ bash "$SH" --repo "$T/$1" --base "$2"; }
count(){ printf '%s' "$1" | jq -r --arg d "$2" '[.candidates[]|select(.detector==$d)]|length'; }

# --- detector: weakened-check, removed guard ---------------------------------
newrepo guard; mkdir -p "$T/guard/src"
printf 'function f(x) {\n  if (!x) throw new Error("nope");\n  return x + 1;\n}\n' > "$T/guard/src/a.js"
printf 'covered\n' > "$T/guard/src/a.test.js"
commit_all guard base; B="$(base_of guard)"
printf 'function f(x) {\n  return x + 1;\n}\n' > "$T/guard/src/a.js"
J="$(run guard "$B")"
expect "removed guard -> valid JSON"       "$(printf '%s' "$J" | jq -e . >/dev/null 2>&1 && echo ok)" "ok"
expect "removed guard -> weakened-check"   "$(count "$J" weakened-check)" "1"
expect "removed guard cites pre-image line" \
  "$(printf '%s' "$J" | jq -r '[.candidates[]|select(.detector=="weakened-check")][0].line')" "2"
expect "removed guard marked (removed)" \
  "$(printf '%s' "$J" | jq -r '[.candidates[]|select(.detector=="weakened-check")][0].evidence' | grep -c '(removed)')" "1"

# NEAR MISS: adding a guard is an improvement, never a finding.
newrepo addguard; mkdir -p "$T/addguard/src"
printf 'function f(x) {\n  return x + 1;\n}\n' > "$T/addguard/src/b.js"
printf 'covered\n' > "$T/addguard/src/b.test.js"
commit_all addguard base; B="$(base_of addguard)"
printf 'function f(x) {\n  if (!x) throw new Error("nope");\n  return x + 1;\n}\n' > "$T/addguard/src/b.js"
expect "ADDED guard is not a finding" "$(count "$(run addguard "$B")" weakened-check)" "0"

# --- detector: weakened-check, skip marker + deleted test --------------------
newrepo skipm; mkdir -p "$T/skipm/tests"
printf 'it("works", () => {});\n' > "$T/skipm/tests/y.test.js"
commit_all skipm base; B="$(base_of skipm)"
# The fixture marker is COMPOSED from parts rather than written literally. Spelled
# out, this line would itself match `hooks/checks.sh`'s TI_SKIP pattern, and that
# guard scans added lines in any test path — so a test whose whole job is to prove
# skip-markers are detected would be reported as a weakened test. Composing it keeps
# that guard strict for every other file instead of carving out an exception.
dot='.'; kw='skip'
printf 'it%s%s("works", () => {});\n' "$dot" "$kw" > "$T/skipm/tests/y.test.js"
expect "added skip marker -> weakened-check" "$(count "$(run skipm "$B")" weakened-check)" "1"

newrepo deltest; mkdir -p "$T/deltest/tests"
printf 'a\n' > "$T/deltest/tests/gone.test.js"; printf 'keep\n' > "$T/deltest/readme.md"
commit_all deltest base; B="$(base_of deltest)"
rm "$T/deltest/tests/gone.test.js"
expect "deleted test file -> weakened-check" "$(count "$(run deltest "$B")" weakened-check)" "1"

# --- detector: weakened-check, swallowed error -------------------------------
newrepo swallow; mkdir -p "$T/swallow/src"
printf 'try { g(); } catch (e) { report(e); }\n' > "$T/swallow/src/c.js"
printf 'covered\n' > "$T/swallow/src/c.test.js"
commit_all swallow base; B="$(base_of swallow)"
printf 'try { g(); } catch (e) {}\n' > "$T/swallow/src/c.js"
expect "empty catch -> weakened-check" \
  "$(printf '%s' "$(run swallow "$B")" | jq -r '[.candidates[]|select(.evidence|test("swallowed"))]|length')" "1"

# --- detector: contract, migration + exported signature ----------------------
newrepo mig; printf 'x\n' > "$T/mig/readme.md"
commit_all mig base; B="$(base_of mig)"
mkdir -p "$T/mig/migrations"; printf 'ALTER TABLE users ADD COLUMN x int;\n' > "$T/mig/migrations/001_x.sql"
git -C "$T/mig" add -A
expect "migration file -> contract" "$(count "$(run mig "$B")" contract)" "1"

newrepo sig; mkdir -p "$T/sig/src"
printf 'const internal = 1;\n' > "$T/sig/src/api.ts"
printf 'covered\n' > "$T/sig/src/api.test.ts"
commit_all sig base; B="$(base_of sig)"
printf 'const internal = 1;\nexport function publicThing(a, b) { return a + b; }\n' > "$T/sig/src/api.ts"
expect "exported signature -> contract" "$(count "$(run sig "$B")" contract)" "1"

# NEAR MISS: a non-exported declaration is not a contract change.
newrepo nosig; mkdir -p "$T/nosig/src"
printf 'const a = 1;\n' > "$T/nosig/src/d.ts"; printf 'covered\n' > "$T/nosig/src/d.test.ts"
commit_all nosig base; B="$(base_of nosig)"
printf 'const a = 1;\nfunction helper(x) { return x; }\n' > "$T/nosig/src/d.ts"
expect "non-exported decl is not contract" "$(count "$(run nosig "$B")" contract)" "0"

# --- detector: untested -------------------------------------------------------
newrepo untested; mkdir -p "$T/untested/src"
printf 'const a = 1;\n' > "$T/untested/src/thing.js"
commit_all untested base; B="$(base_of untested)"
printf 'const a = 2;\nconst b = 3;\n' > "$T/untested/src/thing.js"
expect "logic, no test -> untested" "$(count "$(run untested "$B")" untested)" "1"

# NEAR MISS: a co-changed test naming the file suppresses it.
newrepo covered; mkdir -p "$T/covered/src" "$T/covered/tests"
printf 'const a = 1;\n' > "$T/covered/src/thing.js"; printf 'old\n' > "$T/covered/tests/thing.test.js"
commit_all covered base; B="$(base_of covered)"
printf 'const a = 2;\n' > "$T/covered/src/thing.js"; printf 'new\n' > "$T/covered/tests/thing.test.js"
expect "logic WITH matching test -> silent" "$(count "$(run covered "$B")" untested)" "0"

# NEAR MISS: docs are not logic.
newrepo docs; printf 'old\n' > "$T/docs/README.md"
commit_all docs base; B="$(base_of docs)"
printf 'new\nmore\n' > "$T/docs/README.md"
expect "docs edit is not untested logic" "$(count "$(run docs "$B")" untested)" "0"

# --- the two empty shapes are distinguishable --------------------------------
newrepo clean; mkdir -p "$T/clean/tests"
printf 'a\n' > "$T/clean/tests/x.test.js"
commit_all clean base; B="$(base_of clean)"
printf 'a\nb\n' > "$T/clean/tests/x.test.js"
JC="$(run clean "$B")"
expect "nothing fires -> candidates:[]"    "$(printf '%s' "$JC" | jq -c .)" '{"candidates":[]}'
printf '%s' "$JC" | jq -e 'has("candidates")' >/dev/null 2>&1
expect "nothing fires -> has(candidates)"  "$?" "0"

JF="$(bash "$SH" --repo "$T/not-a-repo" --base x)"; rc=$?
expect "non-repo -> exit 0"                "$rc" "0"
expect "non-repo -> {}"                    "$(printf '%s' "$JF" | jq -c .)" "{}"
printf '%s' "$JF" | jq -e 'has("candidates")' >/dev/null 2>&1
expect "fail-open -> NO candidates key"    "$?" "1"

JB="$(bash "$SH" --repo "$T/clean" --base deadbeefdeadbeef)"; rc=$?
expect "bad base -> exit 0"                "$rc" "0"
expect "bad base -> {}"                    "$(printf '%s' "$JB" | jq -c .)" "{}"
JN="$(bash "$SH")"; rc=$?
expect "no args -> exit 0"                 "$rc" "0"
expect "no args -> {}"                     "$(printf '%s' "$JN" | jq -c .)" "{}"

# --- Gate-A regressions: four defects the AC table did not cover -------------

# (1) A whole-file DELETE has `+++ /dev/null`. Taking the path from that header
# attributed every removed line to `/dev/null`, so a deleted source file's guards
# rendered as `/dev/null:2` — a coordinate pointing at nothing.
newrepo delsrc; mkdir -p "$T/delsrc/src"
printf 'function f(x) {\n  if (!x) throw new Error("nope");\n  return x;\n}\n' > "$T/delsrc/src/gone.js"
printf 'covered\n' > "$T/delsrc/src/gone.test.js"
commit_all delsrc base; B="$(base_of delsrc)"
rm "$T/delsrc/src/gone.js"
JD="$(run delsrc "$B")"
expect "deleted source -> no /dev/null path" \
  "$(printf '%s' "$JD" | jq -r '[.candidates[]|select(.path=="/dev/null")]|length')" "0"
expect "deleted source -> real pre-image path" \
  "$(printf '%s' "$JD" | jq -r '[.candidates[]|select(.path=="src/gone.js")]|length>0')" "true"

# (2) A content line reading `++ x` is emitted by diff as `+++ x` and was swallowed
# as a file header, re-pointing the current path at a bogus value for the rest of
# the hunk. Diff fixtures inside test files are the natural trigger.
newrepo difftext; mkdir -p "$T/difftext/src"
printf 'const a = 1;\n' > "$T/difftext/src/dt.js"; printf 'covered\n' > "$T/difftext/src/dt.test.js"
commit_all difftext base; B="$(base_of difftext)"
printf 'const a = 1;\n++ not a header\n-- also not a header\nconst b = 2;\n' > "$T/difftext/src/dt.js"
JT="$(run difftext "$B")"
expect "diff-looking content -> valid JSON" \
  "$(printf '%s' "$JT" | jq -e . >/dev/null 2>&1 && echo ok)" "ok"
expect "diff-looking content -> no bogus path" \
  "$(printf '%s' "$JT" | jq -r '[.candidates[]|select(.path|startswith("src/")|not)]|length')" "0"

# (3) `*[Tt]est*` as a bare substring classified `src/latest.js` (l-a-test) as a
# test file, suppressing a real finding. Markers must sit at a name boundary.
newrepo latest; mkdir -p "$T/latest/src"
printf 'const a = 1;\n' > "$T/latest/src/latest.js"
commit_all latest base; B="$(base_of latest)"
printf 'const a = 2;\nconst b = 3;\n' > "$T/latest/src/latest.js"
expect "latest.js is NOT treated as a test" "$(count "$(run latest "$B")" untested)" "1"

# ...and stem matching is equality, not containment: a test for `other` must not
# count as coverage for `a.js`.
newrepo stem; mkdir -p "$T/stem/src" "$T/stem/tests"
printf 'const x = 1;\n' > "$T/stem/src/a.js"; printf 'old\n' > "$T/stem/tests/other.test.js"
commit_all stem base; B="$(base_of stem)"
printf 'const x = 2;\n' > "$T/stem/src/a.js"; printf 'new\n' > "$T/stem/tests/other.test.js"
expect "unrelated test does not cover a.js" "$(count "$(run stem "$B")" untested)" "1"

# (4) The line regexes have no string awareness, so fixture text inside a test file
# read as production error handling. Observed live on this run's own diff.
newrepo fixture; mkdir -p "$T/fixture/tests"
printf 'const t = 1;\n' > "$T/fixture/tests/f.test.js"
commit_all fixture base; B="$(base_of fixture)"
printf 'const t = 1;\nprintf("try { g(); } catch (e) {}");\n' > "$T/fixture/tests/f.test.js"
expect "catch{} inside a test fixture -> silent" \
  "$(printf '%s' "$(run fixture "$B")" | jq -r '[.candidates[]|select(.evidence|test("swallowed"))]|length')" "0"

# ...but a real swallowed error in production code still fires.
newrepo prodcatch; mkdir -p "$T/prodcatch/src"
printf 'try { g(); } catch (e) { report(e); }\n' > "$T/prodcatch/src/p.js"
printf 'covered\n' > "$T/prodcatch/src/p.test.js"
commit_all prodcatch base; B="$(base_of prodcatch)"
printf 'try { g(); } catch (e) {}\n' > "$T/prodcatch/src/p.js"
expect "catch{} in production code still fires" \
  "$(printf '%s' "$(run prodcatch "$B")" | jq -r '[.candidates[]|select(.evidence|test("swallowed"))]|length')" "1"

# ...and a commented-out marker is not live code.
newrepo cmt; mkdir -p "$T/cmt/src"
printf 'const a = 1;\n' > "$T/cmt/src/c2.js"; printf 'covered\n' > "$T/cmt/src/c2.test.js"
commit_all cmt base; B="$(base_of cmt)"
printf 'const a = 1;\n// export function wasHere(a) {}\n' > "$T/cmt/src/c2.js"
expect "commented-out signature -> silent" "$(count "$(run cmt "$B")" contract)" "0"

# --- every advertised skip marker actually fires -----------------------------
# The Rust ignore attribute was unreachable: the comment guard treats a leading `#`
# as a comment, and a Rust attribute always sits at line start — so the helper
# advertised Rust skip detection and had none. The guard now exempts `#` followed by
# `[`. Each marker gets an assertion so a future guard change cannot silently kill
# one again. The fixture marker is COMPOSED (as the JS one above is) because writing
# it literally would match `hooks/checks.sh`'s TI_SKIP and report this file as a
# weakened test.
newrepo rustskip; mkdir -p "$T/rustskip/tests"
printf 'fn a() {}\n' > "$T/rustskip/tests/a_test.rs"
commit_all rustskip base; B="$(base_of rustskip)"
attr='[ignore]'
printf '#%s\nfn a() {}\n' "$attr" > "$T/rustskip/tests/a_test.rs"
expect "rust ignore attribute -> weakened-check" "$(count "$(run rustskip "$B")" weakened-check)" "1"

# ...and a genuine `#` comment is still treated as a comment.
newrepo shcomment; mkdir -p "$T/shcomment/src"
printf 'echo hi\n' > "$T/shcomment/src/s.sh"; printf 'covered\n' > "$T/shcomment/src/s.test.sh"
commit_all shcomment base; B="$(base_of shcomment)"
printf 'echo hi\n# if (!x) throw new Error("nope");\n' > "$T/shcomment/src/s.sh"
expect "commented-out guard still ignored" "$(count "$(run shcomment "$B")" weakened-check)" "0"

# --- coordinate contract: no coordinate is ever fabricated -------------------
# A whole-file candidate (a migration, a deleted test) is a finding ABOUT THE FILE.
# Pinning it to line 1 sends the reviewer somewhere arbitrary, which is the very
# thing the /dev/null fallback exists to prevent — so `line` must be null and the
# caller drops the `:line` half when rendering.
newrepo coord; printf 'x\n' > "$T/coord/readme.md"
mkdir -p "$T/coord/tests"; printf 'a\n' > "$T/coord/tests/old.test.js"
commit_all coord base; B="$(base_of coord)"
mkdir -p "$T/coord/migrations"; printf 'ALTER TABLE u ADD COLUMN x int;\n' > "$T/coord/migrations/001_x.sql"
rm "$T/coord/tests/old.test.js"; git -C "$T/coord" add -A
JCO="$(run coord "$B")"
expect "migration candidate has null line" \
  "$(printf '%s' "$JCO" | jq -r '[.candidates[]|select(.path=="migrations/001_x.sql")][0].line')" "null"
expect "deleted-test candidate has null line" \
  "$(printf '%s' "$JCO" | jq -r '[.candidates[]|select(.path=="tests/old.test.js")][0].line')" "null"
expect "no candidate fabricates line 1" \
  "$(printf '%s' "$JCO" | jq -r '[.candidates[]|select(.line==1)]|length')" "0"
# The assertion above was VACUOUS on its own: the `coord` fixture changes only a
# migration and a deleted test, neither of which can produce an `untested`
# candidate — so it could never observe the third whole-file emitter, which was
# still hardcoding 1. Assert on a fixture that actually produces one.
expect "untested candidate has null line" \
  "$(printf '%s' "$(run untested "$(base_of untested)")" | jq -r '[.candidates[]|select(.detector=="untested")][0].line')" "null"
expect "untested fixture fabricates no line 1" \
  "$(printf '%s' "$(run untested "$(base_of untested)")" | jq -r '[.candidates[]|select(.line==1)]|length')" "0"
# ...while a genuine line-level candidate still carries its real coordinate.
expect "line-level candidate keeps its coordinate" \
  "$(printf '%s' "$(run guard "$(base_of guard)")" | jq -r '[.candidates[]|select(.detector=="weakened-check")][0].line')" "2"

# --- Gate-B regressions: the PATH and the ENVIRONMENT, not the file status ---
# Every earlier fixture used an ASCII, space-free path in a config-free repo. The
# fixture-shape monoculture had been broken for file STATUS (A/M/D/R) but never for
# the file NAME or the ambient git config, which is where these three lived.

# (1) A path containing a space was truncated at the space, because the awk header
# rules took the path from `$2` (whitespace-split). The reviewer got `src/my:2`.
newrepo spacepath; mkdir -p "$T/spacepath/src"
printf 'function f(x) {\n  if (!x) throw new Error("no");\n  return x;\n}\n' > "$T/spacepath/src/my file.js"
printf 'covered\n' > "$T/spacepath/src/my file.test.js"
commit_all spacepath base; B="$(base_of spacepath)"
printf 'function f(x) {\n  return x;\n}\n' > "$T/spacepath/src/my file.js"
JSP="$(run spacepath "$B")"
expect "path with a space is not truncated" \
  "$(printf '%s' "$JSP" | jq -r '[.candidates[]|select(.path=="src/my file.js")]|length>0')" "true"
expect "no truncated path emitted" \
  "$(printf '%s' "$JSP" | jq -r '[.candidates[]|select(.path=="src/my")]|length')" "0"

# (2) A non-ASCII path is quoted by git under the default core.quotePath=true, which
# defeated the prefix strip and every extension test downstream.
newrepo utf8path; mkdir -p "$T/utf8path/src"
printf 'function f(x) {\n  if (!x) throw new Error("no");\n  return x;\n}\n' > "$T/utf8path/src/café.js"
commit_all utf8path base; B="$(base_of utf8path)"
printf 'function f(x) {\n  return x;\n}\n' > "$T/utf8path/src/café.js"
JU8="$(run utf8path "$B")"
expect "non-ascii path is unquoted and unprefixed" \
  "$(printf '%s' "$JU8" | jq -r '[.candidates[]|select(.path=="src/café.js")]|length>0')" "true"
expect "no b/-prefixed path leaks out" \
  "$(printf '%s' "$JU8" | jq -r '[.candidates[]|select(.path|startswith("\"") or startswith("b/"))]|length')" "0"

# (3) Ambient git config must not change the result. With color.ui=always the awk
# rules all stopped matching and the helper returned the SUCCESS shape with zero
# candidates — a removed guard silently reported as a clean diff.
git -C "$T/spacepath" config color.ui always
git -C "$T/spacepath" config diff.mnemonicPrefix true
JCFG="$(run spacepath "$(base_of spacepath)")"
expect "color.ui=always does not blind the detectors" \
  "$(printf '%s' "$JCFG" | jq -r '[.candidates[]|select(.detector=="weakened-check")]|length')" "1"
expect "mnemonicPrefix does not leak w/ into paths" \
  "$(printf '%s' "$JCFG" | jq -r '[.candidates[]|select(.path|test("^[a-z]/"))]|length')" "0"

# --- prose is not code: the line-level detectors run only on logic files -----
# Found by DOGFOODING — running the helper against this run's own diff flagged
# README.md as a removed guard, because the prose "everything not named stays
# under guard." matches the guard/assertion pattern. Markdown cannot contain a
# removed null-check. `is_logic_path` gated only `untested` until then.
newrepo prose
printf 'everything not named stays under guard.\nif absent, return early.\n' > "$T/prose/NOTES.md"
commit_all prose base; B="$(base_of prose)"
printf 'rewritten.\n' > "$T/prose/NOTES.md"
expect "prose .md yields no weakened-check" "$(count "$(run prose "$B")" weakened-check)" "0"
expect "prose .md yields no contract"       "$(count "$(run prose "$B")" contract)" "0"

# ...but package.json entry points are still detected, even though .json is not a
# logic extension — the guard is scoped to the four code detectors, not the block.
newrepo pkg
printf '{\n  "name": "x",\n  "main": "old.js"\n}\n' > "$T/pkg/package.json"
commit_all pkg base; B="$(base_of pkg)"
printf '{\n  "name": "x",\n  "main": "new.js"\n}\n' > "$T/pkg/package.json"
# Two candidates, not one: a CHANGED entry point fires on both diff sides — the
# removed `"main": "old.js"` (evidence suffixed `(removed)`) and the added
# `"main": "new.js"`. Both are true statements about the change.
expect "package.json entry point still fires" "$(count "$(run pkg "$B")" contract)" "2"

# --- contract guard: no history-derived signal in the implementation ---------
# The combed detector list deliberately excludes every signal about a file's
# history. Comments are stripped first so the header may name what it excludes.
expect "no history-derived signal implemented" \
  "$(sed 's/#.*//' "$SH" | grep -ciE 'churn|hotspot|fan.?in|revert' | tr -d ' ')" "0"

echo "review-highlights.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
