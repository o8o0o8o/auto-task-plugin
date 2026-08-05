#!/usr/bin/env bash
# Focused test for the DIFF-HYGIENE block in hooks/enforce-gates.sh.
#
# The block is the commit-time consultation of hooks/checks.sh: every OTHER block in
# that hook decides from a field the model wrote into STATE.json, so a diff carrying a
# real credential used to commit with every gate green. These assertions pin that it
# no longer can — and, just as importantly, that it does not over-block.
#
# What is asserted:
#   * a `fail` row blocks: secret in real source, leftover conflict marker, weakened test
#   * `warn`/`pass` never block: a clean diff commits; a secret DEMOTED on a test path commits
#   * fail-CLOSED where the scanner could not look: all-`skip`, missing checks.sh,
#     non-array output — and the all-`skip` message names the scanner's own reason
#   * the false-positive override works only when pinned: right check + current sha
#     clears; a stale sha, a different check name, and a malformed acked[] all still block
#   * the `scanner-unavailable` sentinel override reaches the case it exists for
#     (`base not a commit`, where a base-relative hash cannot even be computed)
#   * a legacy run with no `base` is skipped entirely (never a spurious block)
#   * `git commit --amend` and a merge-conflict finalize are both in scope
#   * a run-created file that hooks/intent-add-untracked.sh intent-added is still scanned
#
# TRIP-STRINGS ARE CONSTRUCTED AT RUNTIME, never verbatim in this tracked source. This
# is not decoration: this file lives under tests/, so checks.sh's `is_test_path`
# matches it and every line of a new file counts as ADDED — so a skip or focus marker
# written literally ANYWHERE in this file, **including in a comment like this one**,
# makes `test-integrity` fail on THIS repo's own diff, i.e. the change could not commit
# itself. The scanner greps text; it has no notion of code-vs-comment. Refer to the
# markers by name (skip, focus, exclusive-test) and never in their real syntax. Same
# convention as tests/checks.test.sh:99-103, and verified by running
# `hooks/checks.sh --base <base>` over this run's own diff.
#
# git commits happen INSIDE this script (a single Bash tool call), so the enforce-gates
# PreToolUse hook — which scans only the top-level command — does not intercept them.
#
# Usage: tests/enforce-gates-hygiene.test.sh   Exit 0 = all passed.

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
GATE="$HOOKS/enforce-gates.sh"
INTENT="$HOOKS/intent-add-untracked.sh"

for tool in git jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not installed (required by the hook under test)"; exit 0; }
done
[ -f "$GATE" ] || { echo "FAIL: $GATE missing"; exit 1; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-56s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-56s got=%s want=%s\n' "$1" "$2" "$3"; fi; }
# substring presence, reported as yes/no so a failure prints readably
has(){ case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# Runtime-constructed trip-strings (see the header note).
SEC="AKIA$(printf 'A%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 | tr -d ' ')"
LT="$(printf '<%.0s' 1 2 3 4 5 6 7)"
SKIPM="$(printf '.%s(' skip)"

DIFF_FLAGS='--no-color --no-ext-diff --no-textconv --no-renames --diff-algorithm=myers --src-prefix=a/ --dst-prefix=b/'
# GATE-A FINDING (round 2): this suite hand-copies both DIFF_FLAGS and the fallback
# fingerprint formula from the hook, and nothing detected a one-sided edit — the suite
# would keep passing against its own copy of a formula the hook no longer uses. Pin the
# copy to the source. The fingerprint formula itself cannot be compared as a string, but
# it is exercised end-to-end by the sentinel-ack assertions, which can only pass while
# the two agree byte-for-byte.
HOOK_FLAGS="$(grep -m1 "^DIFF_FLAGS=" "$GATE" | sed "s/^DIFF_FLAGS='//; s/'$//")"

T="$(mktemp -d)"; HCOPY=""; trap 'rm -rf "$T" "$HCOPY"' EXIT
cd "$T"
git init -q
git config user.email t@t.t
git config user.name t
git checkout -q -b feat/widget
mkdir -p src tests
printf 'export const n = 1;\n' > src/app.js
printf 'test("n", () => { expect(n).toBe(1); expect(n).toBeDefined(); })\n' > tests/app.test.js
git add -A
git commit -qm init
BASE="$(git rev-parse HEAD)"

# Exclude .auto-task/ exactly as a real run does (Phase 1 branch-setup step 2). Without
# this the fixture's own STATE.json is untracked and therefore scanned by checks.sh,
# which is NOT how a real run looks — the fixture would diverge from production.
printf '.auto-task/\n' >> .git/info/exclude

SD=".auto-task/feat/widget"; mkdir -p "$SD"; ST="$T/$SD/STATE.json"

COMMIT='{"tool_input":{"command":"git commit -m wip"}}'
AMEND='{"tool_input":{"command":"git commit --amend --no-edit"}}'
MERGEFIN='{"tool_input":{"command":"git commit --no-edit"}}'

gate(){ printf '%s' "$COMMIT" | CLAUDE_PROJECT_DIR="$T" bash "$GATE" >/dev/null 2>&1; echo $?; }
grun(){ printf '%s' "$1" | CLAUDE_PROJECT_DIR="$T" bash "$GATE" >/dev/null 2>&1; echo $?; }
# stderr of a blocked commit, for message-content assertions
gerr(){ printf '%s' "$COMMIT" | CLAUDE_PROJECT_DIR="$T" bash "$GATE" 2>&1 >/dev/null; }
# gate against an ALTERNATE hooks dir (for the missing/broken-scanner cases)
galt(){ printf '%s' "$COMMIT" | CLAUDE_PROJECT_DIR="$T" bash "$1/enforce-gates.sh" >/dev/null 2>&1; echo $?; }
galterr(){ printf '%s' "$COMMIT" | CLAUDE_PROJECT_DIR="$T" bash "$1/enforce-gates.sh" 2>&1 >/dev/null; }

sha(){ git diff $DIFF_FLAGS "$BASE" | git hash-object --stdin; }
# The ack PIN formula, mirroring the hook's `hyg_resolve_sha`. Deliberately NOT `sha()`
# above: that is the staleness formula (`git diff <base>`), which cannot see untracked or
# index-only content, so an ack pinned to it survived a NEW untracked real secret.
pin_fp(){
  {
    git rev-parse HEAD
    git diff $DIFF_FLAGS HEAD
    git diff --cached $DIFF_FLAGS HEAD
    git ls-files --others --exclude-standard -z | while IFS= read -r -d '' p; do
      printf '%s\t%s\n' "$p" "$(git hash-object "$p" 2>/dev/null || echo unreadable)"
    done
  } | git hash-object --stdin
}
setstate(){ local tmp; tmp="$(jq "$1" "$ST")"; printf '%s' "$tmp" > "$ST"; }
# Refresh the review pin to the CURRENT tree. Load-bearing in every scenario that
# mutates the diff: without it the staleness block fires first and a test would read
# exit 2 as a hygiene block when it was really a staleness block — passing for the
# wrong reason.
repin(){ setstate "$(printf '.gates.code_review.reviewed_diff_sha="%s"' "$(sha)")"; }
# Repin against whatever base the STATE currently names, rather than the fixture's good
# BASE. Needed by the bad-base scenario: `git diff <bad-ref>` prints nothing, but the
# pipe still hashes EMPTY input, so the staleness check sees the empty-blob hash
# (e69de29…) rather than an empty string and fires ITS block first — which would mask
# the hygiene block under test. Pinning to that same value is also what a real resumed
# run does when it refreshes the pin while the base is unresolvable.
repin_state(){
  local b s
  b="$(jq -r '.base // ""' "$ST")"
  s="$(git diff $DIFF_FLAGS "$b" 2>/dev/null | git hash-object --stdin)"
  setstate "$(printf '.gates.code_review.reviewed_diff_sha="%s"' "$s")"
}
# Record a hygiene ack. $1=check name, $2=diff_sha to pin it to.
ack(){ setstate "$(printf '.gates.hygiene.acked=[{"check":"%s","diff_sha":"%s","reason":"fixture","at":"2026-01-01T00:00:00Z"}]' "$1" "$2")"; }
unack(){ setstate 'del(.gates.hygiene)'; }
# Return the fixture to its known-good state: index cleared, tracked files restored from
# HEAD, stray untracked files removed, and the one benign edit re-applied. `git clean -fd`
# without -x leaves IGNORED paths alone, and .auto-task/ is in this fixture's
# .git/info/exclude, so the run state survives. Needed because several scenarios below
# stage content or rename tracked files, and a half-cleaned tree makes the NEXT
# scenario's assertion fail for the wrong reason.
reset_tree(){
  git reset -q >/dev/null 2>&1
  git checkout -q -- . >/dev/null 2>&1
  git clean -qfd >/dev/null 2>&1
  printf 'export const n = 2;\n' > src/app.js
  unack
  repin
}

# A fully-green run: every pre-hygiene gate satisfied, so any exit 2 below is
# attributable to the hygiene block alone.
cat > "$ST" <<EOF
{"approved":true,"phase":"handover","expected_next_action":"auto-continue","base":"$BASE",
 "effort":{"tier":"standard"},"iteration":{"fix":1,"review":1},
 "gates":{"code_review":{"passed":true,"tool":"skill:auto-task-code-review",
   "clean_pass_after_last_fix":true,"reviewed_diff_sha":""},
  "gate_b":{"passed":true}}}
EOF

echo "================ diff hygiene: baseline ================"
expect "suite's DIFF_FLAGS copy matches the hook's"       "$HOOK_FLAGS" "$DIFF_FLAGS"
# Sanity: with a benign edit the whole gate chain allows. If this were 2 the suite
# would be measuring something other than what it claims.
printf 'export const n = 2;\n' > src/app.js
repin
expect "clean diff -> commit ALLOWED"                     "$(gate)" "0"

echo "================ fail rows BLOCK ================"
# (a) secret in real source
printf 'export const n = 2;\nconst k = "%s";\n' "$SEC" > src/app.js
repin
expect "secret in source -> commit BLOCKED"               "$(gate)" "2"
E="$(gerr)"
expect "  message names the failing check"                "$(has "$E" 'secret-scan')" "yes"
expect "  message says ROTATE (history is forever)"       "$(has "$E" 'ROTATE')" "yes"
expect "  message carries the ack jq snippet"             "$(has "$E" 'gates.hygiene.acked')" "yes"
expect "  ack snippet uses the ABSOLUTE state path"       "$(has "$E" "$T/$SD/STATE.json")" "yes"
expect "  ack snippet is not relative-only"               "$(has "$E" ' .auto-task/feat/widget/STATE.json >')" "no"
expect "  message says no state edit clears a finding"    "$(has "$E" 'NO state edit clears a real finding')" "yes"

# (b) leftover conflict marker in real source
printf 'export const n = 2;\n%s HEAD\nmore\n' "$LT" > src/app.js
repin
expect "conflict marker in source -> commit BLOCKED"      "$(gate)" "2"
expect "  message names conflict-markers"                 "$(has "$(gerr)" 'conflict-markers')" "yes"

# (c) weakened test — a skip marker added to a test file
printf 'export const n = 2;\n' > src/app.js
printf 'test%sn", () => { expect(n).toBe(2); })\n' "$SKIPM" > tests/app.test.js
repin
expect "weakened test (skip added) -> commit BLOCKED"     "$(gate)" "2"
expect "  message names test-integrity"                   "$(has "$(gerr)" 'test-integrity')" "yes"
expect "  message says fix the code, not the test"        "$(has "$(gerr)" 'not the test')" "yes"

# (d) weakened test — assertions removed with none added back
printf 'test("n", () => { const y = n; })\n' > tests/app.test.js
repin
expect "gutted test (assertions removed) -> BLOCKED"      "$(gate)" "2"
git checkout -q tests/app.test.js

echo "================ warn/pass NEVER block ================"
# The same credential on a test/fixture path is demoted to `warn` by checks.sh. That
# demotion must survive: fixtures legitimately embed fake secrets.
printf 'export const n = 2;\n' > src/app.js
mkdir -p tests/fixtures
printf 'const fake = "%s";\n' "$SEC" > tests/fixtures/creds.js
git add tests/fixtures/creds.js
repin
expect "secret on a test path (warn) -> ALLOWED"          "$(gate)" "0"
git rm -q --cached tests/fixtures/creds.js
rm -rf tests/fixtures
repin
expect "back to clean -> ALLOWED"                         "$(gate)" "0"

echo "================ the override, and its pinning ================"
# Re-establish a real finding, then exercise the ack in all four directions.
printf 'export const n = 2;\nconst k = "%s";\n' "$SEC" > src/app.js
repin
CUR="$(pin_fp)"
expect "unacked finding -> BLOCKED"                       "$(gate)" "2"
ack secret-scan "$CUR"
expect "ack (right check, current sha) -> ALLOWED"        "$(gate)" "0"
ack secret-scan "0000000000000000000000000000000000000000"
expect "ack with a STALE sha -> still BLOCKED"            "$(gate)" "2"
ack conflict-markers "$CUR"
expect "ack naming a DIFFERENT check -> still BLOCKED"    "$(gate)" "2"
setstate '.gates.hygiene={"acked":"not-an-array"}'
expect "acked as a string -> still BLOCKED"               "$(gate)" "2"
# GATE-A FINDING: a bare `[]?` in jq iterates an OBJECT's values as happily as an
# array's elements, so an object-shaped `acked` holding a well-formed grant was honored
# — contradicting the "a non-array counts as NOT acked" contract the hook itself states.
# Only the string shape had been asserted, which is how the gap survived. Pin every
# non-array container that could carry a grant-shaped value.
setstate "$(printf '.gates.hygiene={"acked":{"k":{"check":"secret-scan","diff_sha":"%s"}}}' "$CUR")"
expect "acked as an OBJECT of grants -> still BLOCKED"    "$(gate)" "2"
setstate '.gates.hygiene={"acked":7}'
expect "acked as a number -> still BLOCKED"               "$(gate)" "2"
setstate '.gates.hygiene={"acked":null}'
expect "acked as null -> still BLOCKED"                   "$(gate)" "2"
setstate "$(printf '.gates.hygiene={"acked":["%s"]}' "$CUR")"
expect "acked array of non-objects -> still BLOCKED"      "$(gate)" "2"
setstate '.gates.hygiene={"acked":[{"check":"secret-scan"}]}'
expect "ack with no diff_sha -> still BLOCKED"            "$(gate)" "2"
# An ack is invalidated by any later edit — the reviewed_diff_sha lesson. Grant it,
# then move the tree and assert it stopped counting.
ack secret-scan "$CUR"
expect "ack still valid before any edit"                  "$(gate)" "0"
printf 'export const n = 2;\nconst k = "%s";\nconst extra = 1;\n' "$SEC" > src/app.js
repin
expect "ack after a later edit -> BLOCKED again"          "$(gate)" "2"
unack
# CODE-REVIEW BLOCKER (round 4): the pin used the STALENESS formula (`git diff <base>`),
# which sees neither untracked nor index-only content. So an ack granted for a genuine
# false positive kept clearing NEW, unrelated, REAL findings of the same check name —
# measured: the hash did not move (4e8e62ad… before and after) and the commit was ALLOWED
# while the scanner reported two matches. The assertion above only edits a TRACKED file,
# which is why both drift shapes were uncovered. The pin now covers worktree, index and
# untracked content.
printf 'export const n = 2;\n' > src/app.js
printf 'const doc = "%s";\n' "$SEC" > src/fp.js       # stand-in false positive, tracked
git add src/fp.js
repin
expect "a finding to ack -> BLOCKED (setup)"              "$(gate)" "2"
ack secret-scan "$(pin_fp)"
expect "  acked -> ALLOWED"                               "$(gate)" "0"
printf 'const real = "%s";\n' "$SEC" > src/new-untracked.js   # NEW UNTRACKED real secret
expect "  NEW UNTRACKED secret under that ack -> BLOCKED" "$(gate)" "2"
rm -f src/new-untracked.js
expect "  ...ack valid again once it is gone"             "$(gate)" "0"
printf 'const real = "%s";\n' "$SEC" > src/staged-only.js
git add src/staged-only.js
rm -f src/staged-only.js                                      # in the INDEX, absent from worktree
expect "  INDEX-ONLY secret under that ack -> BLOCKED"    "$(gate)" "2"
reset_tree
git checkout -q src/app.js
printf 'export const n = 2;\n' > src/app.js
repin
expect "clean again -> ALLOWED"                           "$(gate)" "0"

echo "================ the INDEX is scanned, not just the worktree ================"
# CODE-REVIEW BLOCKER: `git commit` commits the INDEX. A credential staged and then
# edited out of the worktree is invisible to `git diff <base>`, so the commit carried it
# with every check green. The gate now scans worktree UNION index.
printf 'export const n = 2;\n' > src/app.js
printf 'const k = "%s";\n' "$SEC" > src/staged-leak.js
git add src/staged-leak.js
printf 'const k = "harmless";\n' > src/staged-leak.js   # worktree clean, index dirty
repin
expect "secret staged but edited out of worktree -> BLOCKED" "$(gate)" "2"
E="$(gerr)"
expect "  message says the find was in the STAGED index"  "$(has "$E" 'STAGED index')" "yes"
expect "  ...and still names secret-scan"                 "$(has "$E" 'secret-scan')" "yes"
reset_tree
expect "cleaned up -> ALLOWED"                            "$(gate)" "0"

echo "================ the scanner cannot be switched off from inside the repo ================"
# CODE-REVIEW BLOCKER: `numstat` reports `-  -` for a path a .gitattributes entry marks
# non-diffable, and the scanner treated `-` as "binary, skip content". So `*.js binary` or
# `* -diff` disabled secret-scan, conflict-markers AND test-integrity for every
# tracked/staged file — the content that actually gets committed — and the commit carrying
# a real credential was ALLOWED. Neither --no-ext-diff, --no-textconv nor --text changes
# numstat's verdict, so textual-ness is now decided from the blob instead.
printf 'const k = "%s";\n' "$SEC" > src/attr-leak.js
git add src/attr-leak.js
repin
expect "secret in a tracked file -> BLOCKED (control)"    "$(gate)" "2"
printf '*.js binary\n' > .gitattributes
git add .gitattributes
repin
expect "  ...still BLOCKED under '*.js binary'"           "$(gate)" "2"
printf '* -diff\n' > .gitattributes
git add .gitattributes
repin
expect "  ...still BLOCKED under '* -diff'"               "$(gate)" "2"
# A genuinely binary file must NOT be content-scanned (no false secret matches from bytes).
git rm -q -f --cached src/attr-leak.js >/dev/null 2>&1; rm -f src/attr-leak.js .gitattributes
# The negative control must be able to FAIL: give the binary file secret-shaped BYTES, so
# it passes only because the content scan really is skipped. The previous version used
# innocuous bytes and would have passed even if the scan had run.
printf 'junk\000%s\000more\000' "$SEC" > src/real.bin
git add src/real.bin
repin
expect "a genuinely binary file -> ALLOWED (not scanned)" "$(gate)" "0"
reset_tree
# CODE-REVIEW BLOCKER (round 4): `grep -Iq` exits at its first match, closing the pipe, so
# once the diff exceeds the pipe buffer `git diff` dies of SIGPIPE — and under
# `set -o pipefail` that became the PIPELINE's status, so the probe read "binary" and every
# content check was skipped. The gate therefore only closed the .gitattributes hole for
# SMALL files: measured, a 407 KB staged file carrying a real credential reported `pass`
# and the commit was ALLOWED while the same content at 1 KB blocked. Every assertion above
# used ~30-byte files, which is exactly why this survived four rounds.
printf '* binary\n' > .gitattributes
i=0; : > src/big.js
while [ "$i" -lt 6000 ]; do printf 'const filler_%s = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";\n' "$i" >> src/big.js; i=$((i+1)); done
printf 'const k = "%s";\n' "$SEC" >> src/big.js
git add .gitattributes src/big.js
repin
expect "LARGE attr-marked file (>pipe buffer) -> BLOCKED"  "$(gate)" "2"
# The size that matters is the --text diff the probe reads. WITHOUT --text an
# attribute-marked path yields only "Binary files differ", which is why measuring the plain
# diff showed a few bytes and looked fine.
expect "  ...its --text diff really is over the buffer"   "$([ "$(git diff --cached --no-color --no-ext-diff --no-textconv --text "$BASE" -- src/big.js | wc -c | tr -d ' ')" -gt 65536 ] && echo yes || echo no)" "yes"
reset_tree
# The same root cause also hit the scanner's OWN match conditions, which is worse because
# it needs no .gitattributes at all: `printf "$added" | grep -q` under pipefail returned
# 141 when grep exited early, so a hit near the START of a large added hunk was MISSED.
# Measured end-to-end: a 320 KB file whose first line carried a real credential reported
# `secret-scan: pass`. Assert an ordinary large file — no attribute — with the credential
# first, which is exactly the shape that read clean.
: > src/early.js
printf 'const k = "%s";\n' "$SEC" > src/early.js
i=0; while [ "$i" -lt 6000 ]; do printf 'const filler_%s = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";\n' "$i" >> src/early.js; i=$((i+1)); done
repin
expect "  ...its added hunk is over the buffer"           "$([ "$(wc -c < src/early.js | tr -d ' ')" -gt 65536 ] && echo yes || echo no)" "yes"
expect "LARGE plain file, secret FIRST -> BLOCKED"        "$(gate)" "2"
expect "  ...and the scanner itself reports the fail"     "$(bash "$HOOKS/checks.sh" --base "$BASE" | jq -r '.[]|select(.name=="secret-scan")|.result')" "fail"
reset_tree
# CODE-REVIEW BLOCKER (round 3): the binary test read the WORKTREE file while --cached
# scans the INDEX blob, so two divergence shapes skipped the content scan and let a staged
# credential land with exit 0. The assertions above stage the file AND keep the worktree
# copy, which is why a green suite missed both. Textual-ness now comes from the diffed
# content itself.
printf '*.js binary\n' > .gitattributes
printf 'const k = "%s";\n' "$SEC" > src/gone.js
git add .gitattributes src/gone.js
rm -f src/gone.js                       # index keeps the secret; worktree file is gone
repin
expect "staged secret, file DELETED from worktree -> BLOCKED" "$(gate)" "2"
expect "  ...reported as an index-side finding"           "$(has "$(gerr)" 'STAGED index')" "yes"
reset_tree
printf '*.js binary\n' > .gitattributes
printf 'const k = "%s";\n' "$SEC" > src/diverge.js
git add .gitattributes src/diverge.js
printf 'junk\000\001\002' > src/diverge.js   # worktree copy is genuinely binary now
repin
expect "index text-with-secret, worktree binary -> BLOCKED" "$(gate)" "2"
reset_tree

echo "================ non-ASCII and tab-bearing paths are scanned ================"
# CODE-REVIEW BLOCKER (round 6): `git diff --numstat` and `git ls-files --others` C-QUOTE any
# path with a byte outside ASCII under the DEFAULT core.quotePath=true — `"src/l\303\251ak.js"`.
# `$p` was then that literal quoted string, so the per-file diff matched nothing and the file
# was never scanned; the untracked leg failed `[ -f "$p" ]` and skipped it before even
# counting it, so diff-size read `0 file(s), +0/-0`. Measured: the credential that blocks on
# src/leak.js was ALLOWED on src/léak.js, tracked and untracked, as were conflict markers and
# weakened tests. This needed NO adversarial config, which made it the most reachable bypass
# of the run — any project with an accented or CJK filename. Both producers are now `-z`.
# Every fixture in this suite used ASCII paths, which is how it survived six rounds.
NON="src/l$(printf '\303\251')ak.js"
printf 'const k = "%s";\n' "$SEC" > "$NON"
git add "$NON"
repin
expect "secret on a NON-ASCII path, staged -> BLOCKED"    "$(gate)" "2"
reset_tree
printf 'const k = "%s";\n' "$SEC" > "$NON"
repin
expect "secret on a NON-ASCII path, untracked -> BLOCKED" "$(gate)" "2"
expect "  ...and the file is actually counted"           "$(bash "$HOOKS/checks.sh" --base "$BASE" | jq -r '.[]|select(.name=="diff-size")|.detail' | grep -cv '^0 file')" "1"
reset_tree
# A path containing a literal TAB would have been truncated by the old `IFS=$'\t' read a d p`
# even with quoting disabled; the parameter-expansion split keeps it intact.
TABP="src/we$(printf '\t')ird.js"
if printf 'const k = "%s";\n' "$SEC" > "$TABP" 2>/dev/null; then
  git add "$TABP" 2>/dev/null
  repin
  expect "secret on a path containing a TAB -> BLOCKED"  "$(gate)" "2"
  reset_tree
else
  echo "  SKIP  filesystem rejected a tab in a filename"
fi

echo "================ input shapes that used to defeat the scanner ================"
# CODE-REVIEW BLOCKER (round 7): `$p` is a PATHSPEC, not a literal path, and git reads a
# leading `:` as pathspec MAGIC — so `git diff -- ':leak.js'` resolved to `leak.js`
# (nonexistent) and printed nothing with rc=0, leaving the file unscanned. Measured:
# numstat -z reported the path, the per-file re-read returned 0 bytes, secret-scan said
# pass, and the hook exited 0 with the credential staged. Note a plain `git add` cannot
# stage such a path either, so the fixture needs GIT_LITERAL_PATHSPECS to build.
printf 'const k = "%s";\n' "$SEC" > ':colon.js'
GIT_LITERAL_PATHSPECS=1 git add ':colon.js' 2>/dev/null
repin
expect "leading-colon path (pathspec magic) -> BLOCKED"    "$(gate)" "2"
reset_tree
rm -f ':colon.js'
# CODE-REVIEW BLOCKER (round 8): the UNTRACKED leg is the only place a repo-controlled path
# reaches a tool that parses its own options, and `ls-files` emits paths bare — so
# `grep -Iq . -e` consumed `-e` as the pattern flag and the file was counted but read as
# nothing (`1 file(s), +0/-0`, secret-scan pass, hook exit 0). Worse, a file named exactly
# `-` is read as STDIN by grep and cat EVEN AFTER a `--` guard, and inside
# `while … done < <(git ls-files -z)` stdin is the record stream — so it swallowed the
# remaining records and every LATER untracked file vanished too. `./$p` fixes both. The
# tracked leg was never affected (its paths go to git after `--`), which is why the earlier
# `--`-named assertion passed while this shape did not.
for dashname in -e -x -- -r; do
  printf 'const k = "%s";\n' "$SEC" > "./$dashname"
  repin
  expect "untracked option-shaped path [$dashname] -> BLOCKED" "$(gate)" "2"
  rm -f "./$dashname"
done
reset_tree
# The stdin-theft shape: a file named `-` must not hide a LATER untracked file.
: > './-'
printf 'const k = "%s";\n' "$SEC" > ./zz-dashsteal.js
repin
expect "file named '-' does not hide later files"         "$(gate)" "2"
# The precise property is that the file listed AFTER `-` was scanned, so assert the finding
# names it. A file COUNT would also include the fixture's own modified tracked file.
expect "  ...and the later file is the one that was found"  "$(has "$(bash "$HOOKS/checks.sh" --base "$BASE" | jq -r '.[]|select(.name=="secret-scan")|.detail')" 'zz-dashsteal.js')" "yes"
rm -f './-' ./zz-dashsteal.js
reset_tree
# CODE-REVIEW BLOCKER (round 9): the ack-pin loop lacked the `[ -f ]` guard the scanner's
# untracked leg has. `git ls-files --others` lists an untracked SYMLINK, and `git hash-object`
# on one pointing at a FIFO blocks forever — so `|| echo unreadable` never fired, the hook
# never reached `exit 2`, and the harness killed it. Measured rc=142 (alarm) instead of 2.
# The pin is lazy, so this is reachable only once a finding exists, i.e. only when a block is
# required — a fail-OPEN in the one direction this block must never take. Bounded with a
# perl alarm because macOS has no `timeout`; a hang would otherwise wedge the whole suite.
printf 'const k = "%s";\n' "$SEC" > src/fifo-leak.js
FIFO_D="$(mktemp -d)"; mkfifo "$FIFO_D/p"
ln -s "$FIFO_D/p" src/fifo-link
repin
FIFO_RC="$(perl -e 'alarm shift; exec @ARGV' 15 sh -c "printf '%s' '$COMMIT' | CLAUDE_PROJECT_DIR='$T' bash '$GATE' >/dev/null 2>&1"; echo $?)"
expect "untracked symlink->FIFO: gate BLOCKS, no hang"    "$FIFO_RC" "2"
rm -f src/fifo-link src/fifo-leak.js; rm -rf "$FIFO_D"
reset_tree
# A source line beginning with `++` becomes `+++…` in the diff, so a pattern-based
# `grep -v '^+++'` dropped it; the extraction is now gated on the first `@@` hunk header.
printf '++api_key = "%s"\n' "$SEC" > src/plusplus.js
git add src/plusplus.js
repin
expect "credential on a ++-prefixed line -> BLOCKED"       "$(gate)" "2"
reset_tree
# A diff is a BYTE stream: under a UTF-8 locale, awk aborts on an invalid multibyte sequence
# and emits nothing for that line, so an 0xFF byte earlier in the file hid the credential.
# Both the extraction and the matcher are pinned to LC_ALL=C.
printf 'header \377 invalid utf8\nconst k = "%s";\n' "$SEC" > src/badenc.js
git add src/badenc.js
repin
expect "invalid UTF-8 byte + credential -> BLOCKED"        "$(gate)" "2"
expect "  ...under a UTF-8 locale too"                     "$(LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 bash "$HOOKS/checks.sh" --base "$BASE" --cached | jq -r '.[]|select(.name=="secret-scan")|.result')" "fail"
reset_tree
# The index scan is skipped when the index is provably identical to the worktree. It must
# still block on a worktree finding in that state — i.e. the skip must not lose a verdict.
printf 'const k = "%s";\n' "$SEC" > src/samestate.js
git add -A                       # stage EVERYTHING, or the fixture's own unstaged edit
                                 # leaves worktree != index and the skip path is never taken
repin
expect "  ...git agrees worktree==index (skip taken)"      "$(git diff --quiet && echo identical || echo differs)" "identical"
expect "worktree==index (scan skipped) -> still BLOCKED"   "$(gate)" "2"
reset_tree

echo "================ over-block: ordinary diffs and their diagnosis ================"
# CODE-REVIEW REQUIRED: the suite asserted it "does not over-block" while covering only a
# clean diff. These are the ordinary, harmless shapes that DO trip checks.sh (it is
# per-file and rename-blind). They must still block — a deleted test IS a weakened suite
# by the scanner's definition — but the message must DIAGNOSE them instead of saying
# "restore the tests / fix the code the test was failing on", which is wrong advice for a
# rename and sends the user to undo work they meant to do.
git mv tests/app.test.js tests/renamed.test.js
repin
expect "pure test-file RENAME -> BLOCKED (scanner is rename-blind)" "$(gate)" "2"
E="$(gerr)"
expect "  message names the rename false-positive"        "$(has "$E" 'RENAMED')" "yes"
expect "  message says the ack is the right answer"       "$(has "$E" 'ack below is the correct')" "yes"
reset_tree
expect "rename reverted -> ALLOWED"                       "$(gate)" "0"
git rm -q tests/app.test.js
repin
expect "test-file DELETION -> BLOCKED"                    "$(gate)" "2"
expect "  message names the deletion false-positive"      "$(has "$(gerr)" 'DELETED')" "yes"
reset_tree
expect "test file restored -> ALLOWED"                    "$(gate)" "0"
# A docs placeholder on a non-test path: no fixture demotion applies, so it blocks — and
# the message must say so rather than leading with "rotate the credential".
printf 'Set your key:\n\n    export API_%s=%s%s%s\n' KEY '"' "your-api-key-here" '"' > DOCS.md
repin
expect "docs placeholder -> BLOCKED"                      "$(gate)" "2"
E="$(gerr)"
expect "  message names the NOT-a-credential case"        "$(has "$E" 'If it is NOT a credential')" "yes"
expect "  message warns docs paths get no demotion"       "$(has "$E" 'NO test/fixture demotion')" "yes"
reset_tree
expect "docs removed -> ALLOWED"                          "$(gate)" "0"
# A real `warn` row on a SOURCE path (debug-artifacts) must not block — previously only
# the test-path secret demotion covered the warn direction.
printf 'export const n = 2;\nconsole.log("dbg");\n' > src/app.js
repin
expect "debug-artifacts warn on a source path -> ALLOWED" "$(gate)" "0"
reset_tree

echo "================ the printed ack snippet actually works ================"
# CODE-REVIEW REQUIRED: every ack assertion above builds its own JSON, so the snippet the
# hook PRINTS was never executed — which is how a jq error in it went unnoticed. Extract
# the real snippet from stderr and run it.
printf 'export const n = 2;\nconst k = "%s";\n' "$SEC" > src/app.js
repin
expect "unacked -> BLOCKED (setup)"                       "$(gate)" "2"
SNIP="$(gerr | grep -m1 'gates.hygiene.acked =')"
expect "  a snippet was printed"                          "$([ -n "$SNIP" ] && echo yes || echo no)" "yes"
eval "$SNIP" >/dev/null 2>&1
expect "  pasting the PRINTED snippet clears the block"   "$(gate)" "0"
# ...and it must also work from the corrupt non-array state, which is both blocked and
# exactly the state that needs the snippet.
setstate '.gates.hygiene={"acked":"not-an-array"}'
expect "  corrupt acked -> BLOCKED"                       "$(gate)" "2"
SNIP2="$(gerr | grep -m1 'gates.hygiene.acked =')"
eval "$SNIP2" >/dev/null 2>&1
expect "  printed snippet repairs a non-array acked"      "$(gate)" "0"
reset_tree
expect "clean after snippet checks -> ALLOWED"            "$(gate)" "0"

# CODE-REVIEW REQUIRED: the snippet emitted the state path UNQUOTED, so it broke for any
# project under a path containing a space (routine on macOS) — jq got two file arguments,
# mv got three, and the documented recovery dead-ended. Every assertion above runs from
# `mktemp -d`, which never has a space, so the suite could not see it. This fixture puts
# the whole repo under a directory with a space.
SPT="$(mktemp -d)/My Project"
mkdir -p "$SPT"
(
  cd "$SPT" || exit 1
  git init -q; git config user.email t@t.t; git config user.name t; git checkout -q -b feat/widget
  printf 'x\n' > a.js; git add -A; git commit -qm base
  printf '.auto-task/\n' >> .git/info/exclude
  mkdir -p .auto-task/feat/widget
)
SPB="$(cd "$SPT" && git rev-parse HEAD)"
printf 'const k = "%s";\n' "$SEC" > "$SPT/leak.js"
SPSHA="$(cd "$SPT" && git diff $DIFF_FLAGS "$SPB" | git hash-object --stdin)"
cat > "$SPT/.auto-task/feat/widget/STATE.json" <<EOF
{"approved":true,"phase":"handover","expected_next_action":"auto-continue","base":"$SPB",
 "effort":{"tier":"standard"},"iteration":{"fix":1,"review":1},
 "gates":{"code_review":{"passed":true,"tool":"skill:auto-task-code-review",
   "clean_pass_after_last_fix":true,"reviewed_diff_sha":"$SPSHA"},"gate_b":{"passed":true}}}
EOF
spgate(){ printf '%s' "$COMMIT" | CLAUDE_PROJECT_DIR="$SPT" bash "$GATE" >/dev/null 2>&1; echo $?; }
expect "space in path: unacked finding -> BLOCKED"        "$(spgate)" "2"
SPSNIP="$(printf '%s' "$COMMIT" | CLAUDE_PROJECT_DIR="$SPT" bash "$GATE" 2>&1 >/dev/null | grep -m1 'gates.hygiene.acked =')"
eval "$SPSNIP" >/dev/null 2>&1
expect "space in path: PRINTED snippet clears the block"  "$(spgate)" "0"
rm -rf "$(dirname "$SPT")"

echo "================ other commit shapes are in scope ================"
printf 'export const n = 2;\nconst k = "%s";\n' "$SEC" > src/app.js
repin
expect "git commit --amend -> BLOCKED"                    "$(grun "$AMEND")" "2"
# A merge-conflict finalize (`git commit --no-edit` with MERGE_HEAD present) is the one
# merge shape that reaches this hook, and a marker left in a resolved tree is exactly
# what conflict-markers exists to catch.
printf 'ref\n' > .git/MERGE_HEAD
expect "merge finalize (MERGE_HEAD present) -> BLOCKED"   "$(grun "$MERGEFIN")" "2"
rm -f .git/MERGE_HEAD
printf 'export const n = 2;\n' > src/app.js
repin
expect "amend on a clean diff -> ALLOWED"                 "$(grun "$AMEND")" "0"

echo "================ run-created (intent-added) files are scanned ================"
# Item 1 (hooks/intent-add-untracked.sh) intent-adds run-created files so they enter
# `git diff <base>`. They therefore LEAVE the untracked set that checks.sh scans
# separately — so this asserts the numstat path picks them up and coverage did not
# move from one blind spot to another.
if [ -f "$INTENT" ]; then
  printf 'const k = "%s";\n' "$SEC" > src/created.js
  bash "$INTENT" >/dev/null 2>&1 || true
  expect "intent-added file is no longer untracked"       "$(git ls-files --others --exclude-standard | grep -c 'src/created.js')" "0"
  expect "intent-added file IS in git diff <base>"        "$(git diff --name-only "$BASE" | grep -c 'src/created.js')" "1"
  repin
  expect "secret in an intent-added file -> BLOCKED"      "$(gate)" "2"
  git rm -q --cached src/created.js
  rm -f src/created.js
  repin
else
  echo "  SKIP  hooks/intent-add-untracked.sh absent (item 1 not landed)"
fi
expect "clean after cleanup -> ALLOWED"                   "$(gate)" "0"

echo "================ fail-CLOSED when the scanner cannot look ================"
# (a) all-skip via the REAL path, not a stub: a base that no longer resolves. This is
# the reachable production case (a rebased or pruned base ref), and it is also why the
# sentinel override needs a base-independent fingerprint — `git diff <bad-base>` has
# no hash to pin to.
GOODBASE="$BASE"
setstate '.base="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"'
# Pin the review sha to what the unresolvable base actually hashes to, so the staleness
# block passes and the hygiene block is the one under observation. See repin_state.
repin_state
expect "base not a commit -> BLOCKED (fail closed)"       "$(gate)" "2"
E="$(gerr)"
expect "  message carries the scanner's own reason"       "$(has "$E" 'base not a commit')" "yes"
expect "  message points at state.base"                   "$(has "$E" 'state.base')" "yes"
expect "  message offers the sentinel override"           "$(has "$E" 'scanner-unavailable')" "yes"
# The sentinel override must actually be reachable here — the pin is base-independent, so
# it still computes when `state.base` does not resolve, which is the case that needs it.
# There is now ONE pin formula (`pin_fp` above), so the base-resolvable and
# base-unresolvable paths share it and there is no second formula to drift.
ack scanner-unavailable "$(pin_fp)"
expect "sentinel ack (current fingerprint) -> ALLOWED"    "$(gate)" "0"
ack scanner-unavailable "0000000000000000000000000000000000000000"
expect "sentinel ack with a STALE pin -> BLOCKED"         "$(gate)" "2"
# GATE-A FINDING: the all-zero sha above never exercises REAL drift, which is how a
# porcelain-only fingerprint (status codes + paths, no content) passed for one that
# "moves on any edit". These three assertions drive actual drift instead: a content-only
# edit to an already-modified TRACKED file, and a content-only edit to an already-listed
# UNTRACKED file. Both must invalidate the grant.
ack scanner-unavailable "$(pin_fp)"
expect "  sentinel ack valid before any edit"             "$(gate)" "0"
printf 'export const n = 2;\nconst drift = 1;\n' > src/app.js
expect "  content edit to a MODIFIED tracked file -> BLOCKED" "$(gate)" "2"
ack scanner-unavailable "$(pin_fp)"
expect "  re-acked at the new fingerprint -> ALLOWED"     "$(gate)" "0"
printf 'first\n' > src/untracked-drift.js
ack scanner-unavailable "$(pin_fp)"
expect "  ack valid with the untracked file present"      "$(gate)" "0"
printf 'second\n' > src/untracked-drift.js
expect "  content edit to an UNTRACKED file -> BLOCKED"    "$(gate)" "2"
rm -f src/untracked-drift.js
# GATE-A FINDING (round 2): `git hash-object --stdin-paths` aborted at the first
# unreadable path, so a single mode-000 untracked file silently dropped the content of
# every untracked path listed AFTER it — a content-only edit to one of those would not
# move the fingerprint. Per-path hashing fixes it; this drives the exact shape. Skipped
# when running as root, where a mode-000 file is still readable.
printf 'blocked\n' > src/aaa-unreadable.js
chmod 000 src/aaa-unreadable.js
printf 'one\n' > src/zzz-after.js
if [ "$(id -u)" != "0" ] && ! cat src/aaa-unreadable.js >/dev/null 2>&1; then
  ack scanner-unavailable "$(pin_fp)"
  expect "  ack valid past an unreadable untracked file"  "$(gate)" "0"
  printf 'two\n' > src/zzz-after.js
  expect "  edit AFTER an unreadable path -> BLOCKED"     "$(gate)" "2"
else
  echo "  SKIP  unreadable-path case (running as root, or chmod 000 not enforced)"
fi
chmod 644 src/aaa-unreadable.js
rm -f src/aaa-unreadable.js src/zzz-after.js
unack
setstate "$(printf '.base="%s"' "$GOODBASE")"
repin
expect "restored base -> ALLOWED"                         "$(gate)" "0"

# (b) missing checks.sh, and (c) non-array output — both need an alternate hooks dir,
# since the block resolves the scanner beside itself.
HCOPY="$(mktemp -d)"
cp -R "$HOOKS/." "$HCOPY/"
rm -f "$HCOPY/checks.sh"
expect "missing checks.sh -> BLOCKED (fail closed)"       "$(galt "$HCOPY")" "2"
expect "  message names the expected scanner path"        "$(has "$(galterr "$HCOPY")" 'checks.sh')" "yes"
expect "  message offers the sentinel override"           "$(has "$(galterr "$HCOPY")" 'scanner-unavailable')" "yes"
printf '#!/usr/bin/env bash\nprintf %s\n' '"{\"not\":\"an array\"}"' > "$HCOPY/checks.sh"
chmod +x "$HCOPY/checks.sh"
expect "non-array scanner output -> BLOCKED"              "$(galt "$HCOPY")" "2"
printf '#!/usr/bin/env bash\nprintf %s\n' '"[1,2,3]"' > "$HCOPY/checks.sh"
expect "array of non-objects -> BLOCKED"                  "$(galt "$HCOPY")" "2"
printf '#!/usr/bin/env bash\nexit 1\n' > "$HCOPY/checks.sh"
expect "scanner that crashes -> BLOCKED"                  "$(galt "$HCOPY")" "2"

# CODE-REVIEW BLOCKER: every stub above corrupts BOTH invocations, i.e. only SYMMETRIC
# failure — which fails closed anyway. The dangerous shape is ASYMMETRIC: a valid worktree
# scan carrying a real finding plus an unusable `--cached` scan. The merge was a single
# `jq -s` over both documents, so unparseable index output failed the whole slurp and the
# `|| echo '[]'` fallback discarded the worktree's validated fail rows — exit 0, commit
# allowed. These stubs branch on --cached and pin the asymmetric direction.
cp -R "$HOOKS/." "$HCOPY/"                      # restore the real scanner
mv "$HCOPY/checks.sh" "$HCOPY/checks-real.sh"
mkasym(){ printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = "--cached" ] && { %s; exit 0; }; done\nexec bash "$(dirname "$0")/checks-real.sh" "$@"\n' "$1" > "$HCOPY/checks.sh"; chmod +x "$HCOPY/checks.sh"; }
# a real secret in the worktree, so the worktree scan genuinely reports fail
printf 'export const n = 2;\nconst k = "%s";\n' "$SEC" > src/app.js
repin
mkasym "printf 'garbage-not-json\\n'"
expect "index scan returns NON-JSON -> BLOCKED"           "$(galt "$HCOPY")" "2"
expect "  ...and says the STAGED index was unchecked"     "$(has "$(galterr "$HCOPY")" 'STAGED index')" "yes"
mkasym "printf '[{\"name\":\"secret-scan\"'"
expect "index scan returns TRUNCATED json -> BLOCKED"     "$(galt "$HCOPY")" "2"
mkasym "printf '{\"k\":{\"name\":\"x\",\"result\":\"fail\"}}\\n'"
expect "index scan returns an OBJECT -> BLOCKED"          "$(galt "$HCOPY")" "2"
mkasym "printf ''"
expect "index scan returns nothing -> BLOCKED"            "$(galt "$HCOPY")" "2"
expect "  ...names the --cached invocation specifically"  "$(has "$(galterr "$HCOPY")" 'specific to the --cached')" "yes"
# CODE-REVIEW REQUIRED (round 3): when BOTH scans are broken, the index branch used to fire
# first and assert "the worktree scan ran" — false, and it sent the reader to debug
# --cached while the plain invocation was equally broken. The worktree scan is validated
# first now, so a global failure reports globally.
printf '#!/usr/bin/env bash\nprintf %s\n' "'garbage'" > "$HCOPY/checks.sh"
chmod +x "$HCOPY/checks.sh"
expect "BOTH scans broken -> BLOCKED"                     "$(galt "$HCOPY")" "2"
E="$(galterr "$HCOPY")"
expect "  ...diagnosed globally, not as index-specific"   "$(has "$E" 'did not return a usable result')" "yes"
expect "  ...and does NOT claim the worktree scan ran"    "$(has "$E" 'STAGED index')" "no"
# ...and the worktree finding must still be the thing that blocks when the index scan is
# fine, i.e. the fix must not have made the index scan the only voice.
#
# CODE-REVIEW (round 6): this previously stubbed --cached to re-run the REAL scanner without
# --cached, so BOTH scans reported the same `fail` — the assertion would have passed even if
# the hook ignored the worktree rows entirely. Return a valid all-`pass` array for the index
# instead, so the worktree row is provably the only voice that can block.
mkasym "printf '%s' '[{\"name\":\"secret-scan\",\"category\":\"security\",\"result\":\"pass\",\"detail\":\"clean\"},{\"name\":\"diff-size\",\"category\":\"size\",\"result\":\"info\",\"detail\":\"0\"}]'"
expect "index scan clean -> still BLOCKED on the worktree"  "$(galt "$HCOPY")" "2"
expect "  ...and NOT mislabelled as an index finding"      "$(has "$(galterr "$HCOPY")" 'STAGED index')" "no"
reset_tree

echo "================ legacy + applicability ================"
# A run predating this feature has no `base`; it must be skipped entirely, exactly like
# the staleness check. A secret is planted to prove the skip is real and not just a
# clean-diff pass.
printf 'export const n = 2;\nconst k = "%s";\n' "$SEC" > src/app.js
setstate 'del(.base)|del(.gates.code_review.reviewed_diff_sha)'
expect "legacy run without base -> hygiene SKIPPED"       "$(gate)" "0"
setstate "$(printf '.base="%s"' "$GOODBASE")"
repin
expect "  ...and blocks again once base is present"       "$(gate)" "2"
# phase=done and approved=false are pre-existing early exits; the hygiene block must
# not have moved them ahead of their guards.
setstate '.phase="done"'
expect "phase=done -> ALLOWED (hook exits before gates)"  "$(gate)" "0"
setstate '.phase="handover"|.approved=false'
expect "approved=false -> ALLOWED"                        "$(gate)" "0"
setstate '.approved=true'
expect "re-approved -> BLOCKED again"                     "$(gate)" "2"
# A non-commit command must never reach the block.
expect "non-commit command -> ALLOWED"                    "$(grun '{"tool_input":{"command":"git status"}}')" "0"

echo "================ the detector cannot be padded past ================"
# CODE-REVIEW BLOCKER (round 5): the commit/land detectors used `printf "$cmd" | grep -qE`.
# `grep -q` exits at its first match, closing the pipe; `printf` is a BUILTIN, so SIGPIPE
# kills the subshell and `pipefail` promotes 141 to the pipeline's status — the `if` read
# "no match" and the hook took its `exit 0`, skipping EVERY gate in the file, not just this
# block. It needs a MULTI-LINE command (BSD grep reads one long line whole), so a 200 KB
# one-liner was fine while 4001 lines was not. Every other assertion in this suite uses the
# 46-byte `git commit -m wip`, which is why five rounds missed it.
printf 'export const n = 2;\nconst k = "%s";\n' "$SEC" > src/app.js
repin
expect "small commit command -> BLOCKED (control)"        "$(gate)" "2"
padded_payload(){   # $1 = number of extra lines appended to the command
  local extra="" i=0
  while [ "$i" -lt "$1" ]; do extra="${extra}echo filler line ${i} aaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n"; i=$((i+1)); done
  printf '{"tool_input":{"command":"git commit -m wip\\n%s"}}' "$extra"
}
expect "command padded with 2000 lines -> still BLOCKED"  "$(grun "$(padded_payload 2000)")" "2"
expect "command padded with 8000 lines -> still BLOCKED"  "$(grun "$(padded_payload 8000)")" "2"
# ...and a padded NON-commit command must still be allowed: the fix must not make the
# detector match everything.
padded_noncommit(){
  local extra="" i=0
  while [ "$i" -lt 3000 ]; do extra="${extra}echo filler line ${i} aaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n"; i=$((i+1)); done
  printf '{"tool_input":{"command":"git status\\n%s"}}' "$extra"
}
expect "padded NON-commit command -> ALLOWED"             "$(grun "$(padded_noncommit)")" "0"
reset_tree

echo "================ a fail row with no name still blocks ================"
# The `(unnamed-check)` mapping had no assertion, so it could regress silently. Stub a
# scanner that returns a nameless `fail` row and assert the gate still blocks and says
# something useful rather than printing an empty bracket.
cp -R "$HOOKS/." "$HCOPY/" 2>/dev/null || true
printf '#!/usr/bin/env bash\nprintf %s\n' '"[{\"name\":\"\",\"category\":\"x\",\"result\":\"fail\",\"detail\":\"\"},{\"name\":\"diff-size\",\"category\":\"size\",\"result\":\"info\",\"detail\":\"d\"}]"' > "$HCOPY/checks.sh"
chmod +x "$HCOPY/checks.sh"
expect "nameless fail row -> BLOCKED"                     "$(galt "$HCOPY")" "2"
E="$(galterr "$HCOPY")"
expect "  ...labelled as unnamed"                         "$(has "$E" 'unnamed-check')" "yes"
expect "  ...and does not print an empty detail"          "$(has "$E" 'no name or detail')" "yes"

echo ""
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
