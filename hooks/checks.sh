#!/usr/bin/env bash
# checks.sh — universal, language-agnostic hygiene/defect checks over a run's diff.
#
# NOT a hook. A pure, deterministic helper (invoked by the auto-task orchestrator
# in Phase 3 self-verify) that inspects the change vs <base> and prints a JSON
# array of check rows. The orchestrator appends the rows to STATE.json `checks[]`
# (the comprehensive checks manifest surfaced in the final summary) and treats
# `fail` rows as self-verify failures that route into the fix loop.
#
# SCOPE OF "THE DIFF": tracked modifications (`git diff <base>`) AND untracked new
# files (`git ls-files --others --exclude-standard`). This matters: during a run,
# newly-created files are UNTRACKED until Phase 5 staging, so a plain `git diff`
# would miss them — exactly the files most likely to carry a planted secret.
#
# Checks (derived from the quality rubric):
#   F1 secret-scan     (security)  — API keys / tokens / PEM private keys in ADDED lines
#   F2 conflict-markers(integrity) — leftover `<<<<<<<` / `>>>>>>>` merge markers
#   F3 debug-artifacts (hygiene)   — console.log/debugger/pdb/pry + test-focus (.only/fdescribe/fit)
#   F4 large-files     (size)      — binary or very large additions
#   F5 test-integrity  (tests)     — tests WEAKENED to reach green: added skip/focus
#                                    markers (.skip/xit/.only/@pytest.mark.skip/…) or
#                                    assertions deleted from a test file with none
#                                    added back. `fail` (block-worthy). The
#                                    classic autonomous-agent failure the guard
#                                    exists to catch. The orchestrator gates its
#                                    RESPONSE on the `test_integrity_guard` setting;
#                                    this helper always emits the row (settings-free).
#   D1 diff-size       (size)      — files changed + lines added/removed (informational)
#   C1 tests-added     (tests)     — did the diff touch any test file?
#
# SEVERITY: F1/F2 are `fail` (block-worthy) on real source, but DEMOTE to `warn`
# on test/fixture paths — fixtures legitimately embed fake secrets and literal
# conflict-marker strings. Demotion is anchored to real path SEGMENTS (never the
# substring `*test*`, which would wrongly match `latest.config.js`, `contest/`,
# `src/testHelpers.ts` and hide a genuine secret). F3/F4 are `warn`, D1/C1 `info`.
#
# Never echoes matched secret CONTENT — only counts and file paths.
#
# Failure policy: FAIL OPEN. No --base, not a git repo, or an unreadable diff ->
# every row `skip`. Always exits 0. jq NOT required (JSON built with printf).
# bash 3.2-safe (macOS default): no mapfile, no associative arrays, set -u guarded.
#
# Usage:  checks.sh --base <sha> [--cached]
# Output (one line): a JSON array of {name,category,result,detail}.
#
# --cached inspects the INDEX (`git diff --cached <base>`) instead of the worktree, and
# skips the untracked leg (untracked files are by definition not in the index). Added
# because `git commit` commits the index, not the worktree: content that was staged and
# then edited out of the worktree is invisible to the default scan, so a credential
# could be staged, removed from the file, and committed with every check green. The
# commit-time caller in `enforce-gates.sh` runs BOTH modes and blocks on a `fail` from
# either.
#
# The DEFAULT (no --cached) invocation is unchanged for any repo with ordinary git config
# — same seven rows, same results — so the Phase-3 metrics caller is unaffected. It is
# deliberately NOT byte-identical in two cases, both corrections rather than drift: a repo
# whose `diff.external`/textconv config or `.gitattributes` was previously suppressing the
# content scan now reports the findings it was hiding. Do not "restore" byte-identity by
# reverting the pinned flags or the blob-based binary test; each closes a measured way to
# switch the scanner off from inside the repo.

set -uo pipefail

base=""
cached=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="${2:-}"; shift 2 || shift ;;
    --cached) cached=1; shift ;;
    *) shift ;;
  esac
done

# The diff-reading flags are PINNED for the same reason `enforce-gates.sh` pins them
# when hashing: diff.external, textconv, a .gitattributes diff driver, diff.noprefix or
# color settings each change (or entirely replace) the diff TEXT this scanner greps —
# and since added/removed lines are derived from that text, an external-diff driver
# silently degrades every content check (secret-scan, conflict-markers, test-integrity)
# to `pass`. Verified: with `diff.external` set, a real `AKIA…` key went from `fail` to
# `pass`. A security scanner must not be switchable off by local repo config.
# Every `$p` this script hands to git is a PATHSPEC, not a literal path, and git parses
# leading `:` as pathspec MAGIC. So `git diff … -- ':leak.js'` resolved to the path
# `leak.js` (nonexistent) and printed NOTHING with rc=0 — no error to notice — leaving
# `added` empty and skipping every content check for that file. Measured: with the
# credential staged at `:leak.js`, `numstat -z` reported the path correctly while the
# per-file re-read returned 0 bytes, `secret-scan` said `pass`, and the hook exited 0.
# Forcing literal pathspecs fixes it in one place for every call site (and for the
# `ls-files` leg), and additionally stops a path containing `*`/`?`/`[` from being treated
# as a wildcard — that over-matched into a harmless superset, but literal is what is meant.
#
# Realism note kept deliberately: a plain `git add ':leak.js'` cannot even stage such a
# path (add applies the same magic), so producing one takes `GIT_LITERAL_PATHSPECS=1` or a
# tool that writes the index directly. Low likelihood, one-line fix, same class as the two
# bypasses found in the preceding rounds — which both also looked unlikely until measured.
export GIT_LITERAL_PATHSPECS=1

# Extract the ADDED / REMOVED content lines from one file's diff.
#
# Gated on having seen the first `@@` hunk header rather than filtering the `+++`/`---`
# file headers by pattern. The pattern form (`grep '^+' | grep -v '^+++'`) dropped any added
# line whose SOURCE begins with `++`, because that becomes `+++…` in the diff — and
# symmetrically any removed line whose source begins with `--`. Measured: a credential on a
# line starting with `++` reported `secret-scan: pass`. Header lines always precede the
# first `@@`, and content lines always follow one, so the gate is exact where the pattern
# was approximate. `sub()` strips exactly one leading marker, never more.
# LC_ALL=C is REQUIRED, not tidiness. Under a UTF-8 locale awk aborts on a line containing
# an invalid multibyte sequence ("towc: multibyte conversion failure") and emits NOTHING for
# it — measured: a file with one 0xFF byte plus a real `AKIA…` key went from `fail` to
# `pass` under `LC_ALL=en_US.UTF-8` while still failing under `LC_ALL=C`. A diff is a byte
# stream, not text in the ambient locale, so every tool that reads it here is pinned to C.
diff_added(){   printf '%s\n' "$1" | LC_ALL=C awk '/^@@/ { h = 1; next } h && /^\+/ { sub(/^\+/, ""); print }'; }
diff_removed(){ printf '%s\n' "$1" | LC_ALL=C awk '/^@@/ { h = 1; next } h && /^-/  { sub(/^-/,  ""); print }'; }

DIFF_READ_FLAGS='--no-color --no-ext-diff --no-textconv'
if [ "$cached" -eq 1 ]; then
  DIFF_SCOPE='--cached'
else
  DIFF_SCOPE=''
fi

# JSON-escape a detail string (no control chars, quotes, or backslashes leak).
jesc(){ printf '%s' "${1:-}" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'; }
row(){ printf '{"name":"%s","category":"%s","result":"%s","detail":"%s"}' "$1" "$2" "$3" "$(jesc "$4")"; }

emit_skip(){
  printf '[%s]\n' \
"$(row secret-scan security skip "$1"),$(row conflict-markers integrity skip "$1"),$(row debug-artifacts hygiene skip "$1"),$(row large-files size skip "$1"),$(row test-integrity tests skip "$1"),$(row diff-size size skip "$1"),$(row tests-added tests skip "$1")"
  exit 0
}

# --- Preconditions (fail open to all-skip) -----------------------------------
command -v git >/dev/null 2>&1 || emit_skip "git unavailable"
[ -n "$base" ] || emit_skip "no --base provided"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || emit_skip "not a git work tree"
git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 || emit_skip "base not a commit"

# Anchored test/fixture path test (segments + basename patterns), NOT substring.
is_test_path(){
  case "$1" in
    */tests/*|*/test/*|*/__tests__/*|*/__fixtures__/*|*/fixtures/*) return 0 ;;
    tests/*|test/*|__tests__/*|__fixtures__/*|fixtures/*) return 0 ;;
  esac
  b="${1##*/}"
  case "$b" in
    *.test.*|*.spec.*|*_test.*|test_*.*) return 0 ;;
  esac
  return 1
}

# --- Accumulators ------------------------------------------------------------
secret_fail=0; secret_warn=0; secret_files=""
conflict_fail=0; conflict_warn=0; conflict_files=""
debug_warn=0; debug_files=""
files_changed=0; add_total=0; del_total=0; large_warn=0; large_files=""
tests_touched=0
ti_fail=0; ti_files=""

SECRET_STRICT='AKIA[0-9A-Z]{16}|gh[opsur]_[A-Za-z0-9]{36}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
SECRET_GENERIC='(api[_-]?key|secret|password|passwd|token)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9_/+=-]{16,}["'"'"']'
# test-integrity: skip/disable/focus markers that WEAKEN a test suite, and the
# assertion shapes whose wholesale removal signals gutted tests.
TI_SKIP='\.skip\b|\bxit\(|\bxdescribe\(|\bfit\(|\bfdescribe\(|\.only\(|it\.only\(|describe\.only\(|test\.only\(|context\.only\(|@pytest\.mark\.skip|@unittest\.skip|@Ignore\b|\bt\.Skip\(|#\[ignore\]'
# Require assertion-CALL / matcher syntax (a paren, a matcher, or a known assert
# helper) — NOT the bare words `assert`/`should`, which also appear in prose and
# comments (removing a `// TODO: assert …` comment must not read as a gutted test).
TI_ASSERT='expect\(|assert[a-z_]*\(|\.to(Be|Equal|Match|Contain|Have|Throw)|assert(Equal|True|False|Raises|NoError)|require\.(Equal|NoError|True|Error)|EXPECT_|ASSERT_'

# Scan one file's ADDED (and, for test files, REMOVED) content. Globals updated in
# place — not a subshell.
# Does $1 contain a match for ERE $2? ($3 = "i" for case-insensitive.)
#
# EVERY content check routes through this, and the HERESTRING is the whole point: it is
# NOT a pipeline, so its status is grep's alone.
#
# What this replaced, and why the obvious forms are wrong. The call sites used to read
# `printf '%s\n' "$added" | grep -Eq "$re"`. `grep -q` exits at its FIRST match, closing
# the pipe; once `$added` exceeds the pipe buffer (~64 KB) the producer takes SIGPIPE, and
# under `set -o pipefail` (above) that becomes the PIPELINE's status — so the condition
# read FALSE and THE MATCH WAS MISSED. Measured: a 1.7 MB block with the pattern near the
# start gave rc=141 with pipefail on, rc=0 with it off; end-to-end, a 320 KB file whose
# FIRST line carried a real `AKIA…` key reported `secret-scan: pass`. That silently
# disabled secret-scan, conflict-markers, test-integrity and debug-artifacts on large
# added hunks with an early hit — the diffs most likely to be hiding something, reported as
# a clean bill of health.
#
# `{ printf … || true; } | grep -q` does NOT fix it: SIGPIPE *kills* the subshell, so the
# `||` is never reached (verified — still missed). Dropping `pipefail` script-wide would
# work but removes a real guard everywhere else, and `grep -c` forces a full read of every
# hunk. A herestring has no pipe, no signal, and no reliance on pipefail semantics.
#
# Do NOT "simplify" this back into a pipeline at the call sites.
# LC_ALL=C for the same reason as diff_added/diff_removed above: the haystack is diff bytes,
# and a locale-aware matcher can decline to match a line carrying an invalid multibyte
# sequence. All patterns here are ASCII, so byte semantics lose nothing.
has_match(){
  local hay="$1" re="$2" ci="${3:-}"
  if [ "$ci" = "i" ]; then
    LC_ALL=C grep -Eiq "$re" <<< "$hay"
  else
    LC_ALL=C grep -Eq "$re" <<< "$hay"
  fi
}

scan_content(){
  local f="$1" added="$2" removed="${3:-}"
  if is_test_path "$f"; then
    tests_touched=1
    # F5 test-integrity (test paths only): added skip/focus markers, OR assertions
    # deleted with none added back (a strong "gutted the test to go green" signal).
    if [ -n "$added" ] && has_match "$added" "$TI_SKIP"; then
      ti_fail=$((ti_fail+1)); ti_files="$ti_files ${f}(skip/focus-added)"
    elif [ -n "$removed" ] && has_match "$removed" "$TI_ASSERT" \
         && { [ -z "$added" ] || ! has_match "$added" "$TI_ASSERT"; }; then
      ti_fail=$((ti_fail+1)); ti_files="$ti_files ${f}(assertions-removed)"
    fi
  fi
  [ -n "$added" ] || return 0
  if has_match "$added" "$SECRET_STRICT" || has_match "$added" "$SECRET_GENERIC" i; then
    if is_test_path "$f"; then secret_warn=$((secret_warn+1)); else secret_fail=$((secret_fail+1)); fi
    secret_files="$secret_files $f"
  fi
  if has_match "$added" '^(<<<<<<<|>>>>>>>)'; then
    if is_test_path "$f"; then conflict_warn=$((conflict_warn+1)); else conflict_fail=$((conflict_fail+1)); fi
    conflict_files="$conflict_files $f"
  fi
  local dbg
  if is_test_path "$f"; then
    dbg='\.only\(|fdescribe\(|(^|[^A-Za-z])fit\('
  else
    dbg='console\.(log|debug|info|warn|error)\(|debugger|pdb\.set_trace\(|binding\.pry|\.only\(|fdescribe\('
  fi
  if has_match "$added" "$dbg"; then
    debug_warn=$((debug_warn+1)); debug_files="$debug_files $f"
  fi
}

# --- Tracked modifications (numstat gives add/del/binary + path) --------------
# NUL-DELIMITED (`-z`) and split by shell parameter expansion rather than `IFS=$'\t' read`.
# Both halves are load-bearing, and the plain form was a silent security bypass:
#
# Without `-z`, git renders a path containing any byte outside ASCII in C-QUOTED form under
# the default `core.quotePath=true` — `1  0  "src/l\303\251ak.js"`. `$p` was then that
# literal 20-character quoted string, so the per-file `git diff … -- "$p"` below matched
# nothing, `added` came back empty, and `scan_content` returned immediately. Measured: the
# same credential that blocks on `src/leak.js` reported `secret-scan: pass` and the commit
# was ALLOWED on `src/léak.js`; conflict markers and weakened tests on non-ASCII paths were
# equally invisible. That needed NO adversarial repo config — `core.quotePath` defaults to
# true — which made it the most reachable bypass of the lot: any project with an accented or
# CJK filename. (`-c core.quotePath=false` would fix that much; `-z` is chosen because it
# also fixes the next shape.)
#
# The parameter-expansion split then handles a path containing a literal TAB, which
# `IFS=$'\t' read -r a d p` would truncate at the tab: `-z` makes the RECORD boundary NUL,
# and taking everything after the second tab keeps the rest of the path intact. Verified on
# both `src/léak.js` and `src/we<TAB>ird.js`.
while IFS= read -r -d '' rec; do
  a="${rec%%$'\t'*}"; rest="${rec#*$'\t'}"; d="${rest%%$'\t'*}"; p="${rest#*$'\t'}"
  [ -n "${p:-}" ] || continue
  files_changed=$((files_changed+1))
  if [ "$a" = "-" ] || [ "$d" = "-" ]; then
    large_warn=$((large_warn+1)); large_files="$large_files ${p}(binary)"
    # numstat's `-` means "not line-diffable", which is NOT the same as "not text": a
    # `.gitattributes` entry (`* -diff`, `*.js binary`) forces it on perfectly textual
    # files, and neither --no-ext-diff nor --no-textconv nor --text overrides it there.
    # Letting `-` gate the content scan meant a one-line .gitattributes addition disabled
    # secret-scan, conflict-markers AND test-integrity for every tracked/staged file —
    # exactly the content that gets committed. Measured: with `*.js binary`, a real
    # `AKIA…` key went from `fail` to `pass`.
    #
    # So textual-ness is decided from the CONTENT BEING DIFFED — never from the worktree
    # path. Under --cached the scanned content is the INDEX blob, which can differ from
    # the working file or outlive it entirely (stage a file, then delete it from the
    # worktree: the commit still carries it). A `-f "$p"` / `grep -Iq "$p"` test skipped
    # the scan for exactly those shapes and let a staged credential land with exit 0.
    #
    # THREE constraints make the probe below look odd; each is load-bearing.
    #   1. `|| true` inside the braces — NOT redundant. `grep -Iq` exits at its first
    #      match, closing the pipe, so once the diff exceeds the pipe buffer (~64 KB)
    #      `git diff` dies of SIGPIPE (141). With `set -o pipefail` (above) that becomes
    #      the PIPELINE's status, the condition reads false, and the file is treated as
    #      binary — silently skipping every content check on any attribute-marked file
    #      larger than a pipe buffer. Measured: a 407 KB staged file carrying a real
    #      `AKIA…` key reported `pass` and the commit was ALLOWED, while the same content
    #      at 1 KB correctly blocked. `|| true` makes the left side's status irrelevant so
    #      only grep decides, which is the intent.
    #   2. A PIPE, not a captured string — `$( )` strips NUL bytes, so grepping a captured
    #      diff would classify a real binary as textual and scan its bytes as source.
    #   3. `grep -I` on the diff, not on the path — see above.
    # Cost: one extra `git diff` on the not-line-diffable path only.
    if { git diff $DIFF_SCOPE $DIFF_READ_FLAGS --text "$base" -- "$p" 2>/dev/null || true; } | grep -Iq .; then
      fdiff="$(git diff $DIFF_SCOPE $DIFF_READ_FLAGS --text "$base" -- "$p" 2>/dev/null || true)"
      added="$(diff_added "$fdiff")"
      removed="$(diff_removed "$fdiff")"
      scan_content "$p" "$added" "$removed"
    else
      scan_content "$p" "" ""     # genuinely binary — still record tests_touched via path
    fi
  else
    case "$a" in ''|*[!0-9]*) a=0 ;; esac
    case "$d" in ''|*[!0-9]*) d=0 ;; esac
    add_total=$((add_total + a)); del_total=$((del_total + d))
    [ "$a" -gt 800 ] && { large_warn=$((large_warn+1)); large_files="$large_files ${p}(+${a})"; }
    fdiff="$(git diff $DIFF_SCOPE $DIFF_READ_FLAGS "$base" -- "$p" 2>/dev/null || true)"
    added="$(diff_added "$fdiff")"
    removed="$(diff_removed "$fdiff")"
    scan_content "$p" "$added" "$removed"
  fi
done < <(git diff $DIFF_SCOPE --numstat --no-renames -z "$base" 2>/dev/null || true)
# --no-renames: a rename+modify would otherwise emit a brace-form path
# (`dir/{old => new}`) that `git diff -- "$p"` can't resolve, silently skipping
# the secret/conflict/debug scan of the renamed file. --no-renames splits it into
# a plain delete + a plain add whose path resolves and gets scanned.

# --- Untracked new files (entire content is "added") --------------------------
# NUL-delimited for the same reason as the numstat loop above: `git ls-files --others`
# C-quotes a non-ASCII path under the default `core.quotePath=true`, so `$p` was the literal
# quoted string, `[ -f "$p" ]` failed, and the file was `continue`d BEFORE `files_changed++`
# — leaving it invisible even to the diff-size row, which reported `0 file(s), +0/-0` while
# an untracked file carrying a real credential sat in the tree. `-z` never quotes.
while IFS= read -r -d '' p; do
  [ -n "$p" ] || continue
  [ -f "$p" ] || continue
  files_changed=$((files_changed+1))
  # `./$p`, NOT "$p", for every non-git tool below. This leg is the only place a
  # repo-controlled path reaches a tool that does its own option parsing, and `ls-files`
  # emits paths bare (no `./`), so an OPTION-SHAPED name was consumed as a flag:
  # `grep -Iq . -e` treats `-e` as the pattern flag, `cat --` as end-of-options. Measured —
  # an untracked file carrying a real credential reported `secret-scan: pass` at each of
  # `-e`, `-x`, `-r`, `--`, and under a `-p/` directory, while `diff-size` said
  # `1 file(s), +0/-0`: counted, then read as nothing.
  #
  # `./` rather than a `--` guard, deliberately: `--` fixes `-e` but NOT a file named
  # exactly `-`, which grep and cat still read as STDIN even after `--` (measured). That
  # case is worse than a silent skip — inside `while … done < <(git ls-files -z)` stdin IS
  # the NUL record stream, so one file named `-` swallowed the remaining records and every
  # LATER untracked file vanished from the scan too. `./-` is unambiguously a path to both
  # tools, so it fixes the option case and the stdin-theft case together.
  #
  # The tracked/index leg needs none of this: every path there goes to git after `--`.
  if ! grep -Iq . "./$p" 2>/dev/null; then     # grep -I: binary file => no text match
    large_warn=$((large_warn+1)); large_files="$large_files ${p}(binary)"
    scan_content "$p" "" ""
  else
    c="$(grep -c '' "./$p" 2>/dev/null || echo 0)"; case "$c" in ''|*[!0-9]*) c=0 ;; esac
    add_total=$((add_total + c))
    [ "$c" -gt 800 ] && { large_warn=$((large_warn+1)); large_files="$large_files ${p}(+${c})"; }
    scan_content "$p" "$(cat "./$p" 2>/dev/null || true)" ""   # new file: nothing removed
  fi
done < <(if [ "$cached" -eq 0 ]; then git ls-files --others --exclude-standard -z 2>/dev/null || true; fi)

# --- Assemble rows -----------------------------------------------------------
if   [ "$secret_fail" -gt 0 ]; then r_secret="$(row secret-scan security fail "$secret_fail secret-like match(es) in source:${secret_files}")"
elif [ "$secret_warn" -gt 0 ]; then r_secret="$(row secret-scan security warn "$secret_warn match(es) in test/fixture paths only:${secret_files}")"
else r_secret="$(row secret-scan security pass "no secret-like content in added lines")"; fi

if   [ "$conflict_fail" -gt 0 ]; then r_conflict="$(row conflict-markers integrity fail "$conflict_fail file(s) with conflict markers:${conflict_files}")"
elif [ "$conflict_warn" -gt 0 ]; then r_conflict="$(row conflict-markers integrity warn "markers in test/fixture paths only:${conflict_files}")"
else r_conflict="$(row conflict-markers integrity pass "no leftover conflict markers")"; fi

if [ "$debug_warn" -gt 0 ]; then r_debug="$(row debug-artifacts hygiene warn "$debug_warn file(s) with debug/focus artifacts:${debug_files}")"
else r_debug="$(row debug-artifacts hygiene pass "no debug/focus artifacts")"; fi

if [ "$large_warn" -gt 0 ]; then r_large="$(row large-files size warn "$large_warn large/binary addition(s):${large_files}")"
else r_large="$(row large-files size pass "no oversized or binary additions")"; fi

if [ "$ti_fail" -gt 0 ]; then r_ti="$(row test-integrity tests fail "$ti_fail test file(s) weakened (skip/focus added or assertions removed):${ti_files}")"
else r_ti="$(row test-integrity tests pass "no tests weakened (no skip/focus added, no assertions gutted)")"; fi

r_size="$(row diff-size size info "$files_changed file(s), +${add_total}/-${del_total}")"

if [ "$tests_touched" -eq 1 ]; then r_tests="$(row tests-added tests pass "diff touches test file(s)")"
elif [ "$files_changed" -gt 0 ]; then r_tests="$(row tests-added tests warn "no test file touched by this diff")"
else r_tests="$(row tests-added tests info "no changes")"; fi

printf '[%s]\n' "$r_secret,$r_conflict,$r_debug,$r_large,$r_ti,$r_size,$r_tests"
exit 0
