#!/usr/bin/env bash
# Focused test for hooks/analyzer-delta.sh — the two-run analyzer delta.
#
# The central claim under test is AC 1: inserting lines ABOVE an existing finding must
# introduce NOTHING. A line-keyed set difference reports every finding below an
# insertion as new, which is a noise flood on exactly the change that touched the most
# code. Every other case here defends a guard that a critique round found missing.
#
# Each case builds a throwaway git repo in a temp dir, commits a base, mutates the
# tree, and runs the helper. `git commit` happens INSIDE this script (a single Bash
# tool call), so the enforce-gates PreToolUse hook — which scans only the top-level
# command — does not intercept it. Same technique as tests/checks.test.sh.
#
# Analyzer stubs are plain scripts, so the delta logic is tested without depending on
# any real tool's rule set. Two stubs use DIFFERENT positional formats, which is what
# proves no per-tool parser is involved (AC 2).
#
# Usage: tests/analyzer-delta.test.sh   Exit 0 = all passed.

set -uo pipefail

AD="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/analyzer-delta.sh"
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
[ -f "$AD" ] || { echo "FAIL: $AD missing"; exit 1; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-54s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-54s got=%s want=%s\n' "$1" "$2" "$3"; fi; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# --- helpers ------------------------------------------------------------------
jget(){ printf '%s' "$1" | sed -n "s/.*\"$2\":\([0-9][0-9]*\).*/\1/p" | head -1; }
jstr(){ printf '%s' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" | head -1; }

# A positional stub in gcc style. Emits one finding per line matching TRIP.
mk_stub_gcc(){
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
# A Tier-1 command is self-contained: with no args, scan the cwd like a real linter.
# Flag-shaped args are ignored, as a real linter ignores its own options when
# deciding targets. Exit 0 when clean and 1 when findings exist -- the convention
# every real linter follows, and what the base-validity rule is written against.
args=""
for a in "$@"; do case "$a" in -*) ;; *) args="$args $a" ;; esac; done
set -- ${args:-$(ls *.sh 2>/dev/null)}
hit=0
for f in "$@"; do
  [ -f "$f" ] || continue
  n=0
  while IFS= read -r ln; do
    n=$((n+1))
    case "$ln" in *TRIP*) printf '%s:%s:1: note: Double quote to prevent globbing [SC2086]\n' "$f" "$n"; hit=1 ;; esac
  done < "$f"
done
exit $hit
STUB
  chmod +x "$1"
}

# A positional stub in a DIFFERENT layout (`file:line:col CODE msg`, no `note:`).
# Same delta logic must handle it with no tool-specific parsing.
mk_stub_alt(){
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
args=""
for a in "$@"; do case "$a" in -*) ;; *) args="$args $a" ;; esac; done
set -- ${args:-$(ls *.sh 2>/dev/null)}
hit=0
for f in "$@"; do
  [ -f "$f" ] || continue
  n=0
  while IFS= read -r ln; do
    n=$((n+1))
    case "$ln" in *TRIP*) printf '%s:%s:1 E501 line too long\n' "$f" "$n"; hit=1 ;; esac
  done < "$f"
done
exit $hit
STUB
  chmod +x "$1"
}

# A stub that behaves like a real linter WITH A CACHE: it writes state into whatever
# tree it scans. AC 5 names this explicitly — ShellCheck writes nothing, so a residue
# check driven by it is vacuous and cannot exercise the forced-removal cleanup ladder.
mk_stub_caching(){
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
args=""
for a in "$@"; do case "$a" in -*) ;; *) args="$args $a" ;; esac; done
set -- ${args:-$(ls *.sh 2>/dev/null)}
mkdir -p ./.mycache 2>/dev/null
date > ./.mycache/state 2>/dev/null
printf 'cache\n' > ./.eslintcache 2>/dev/null
hit=0
for f in "$@"; do
  [ -f "$f" ] || continue
  n=0
  while IFS= read -r ln; do
    n=$((n+1))
    case "$ln" in *TRIP*) printf '%s:%s:1: note: cached-linter finding [SC2086]\n' "$f" "$n"; hit=1 ;; esac
  done < "$f"
done
exit $hit
STUB
  chmod +x "$1"
}

# newrepo does NOT cd — it cannot. It is called in a command substitution, which runs
# in a SUBSHELL, so any `cd` inside it is discarded when the subshell exits. An earlier
# version did `cd` here and the parent shell therefore stayed in the auto-task worktree:
# every `git add -A && git commit` in this file ran against the REAL repository and put
# 51 stray commits on the run branch. The caller now cds explicitly, and commit_all()
# below refuses to run anywhere outside $TMPROOT so the mistake cannot recur silently.
newrepo(){
  d="$TMPROOT/$1"; mkdir -p "$d"
  git -C "$d" init -q . 2>/dev/null
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false 2>/dev/null || true
  printf '%s' "$d"
}

# Guard: stage+commit ONLY inside the throwaway tree. If $PWD ever escapes $TMPROOT the
# test aborts loudly instead of committing to whatever repo it happens to be standing in.
commit_all(){
  case "$PWD/" in
    "$TMPROOT"/*) ;;
    *) echo "FATAL: refusing to git-commit outside \$TMPROOT (PWD=$PWD)" >&2; exit 2 ;;
  esac
  git add -A >/dev/null 2>&1
  git commit -qm "${1:-base}" >/dev/null 2>&1
}

echo "analyzer-delta.sh"

# --- case: line-shift (AC 1) — THE central claim ------------------------------
d="$(newrepo shift)"; mk_stub_gcc "$d/stub"
cd "$d" || exit 1
printf 'echo TRIP one\necho ok\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
# insert 20 lines ABOVE the finding: its line number moves 1 -> 21
{ for i in $(seq 20); do echo "# pad $i"; done; cat a.sh; } > a.sh.new && mv a.sh.new a.sh
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.adcache" 2>/dev/null)"
expect "line-shift: introduced" "$(jget "$out" introduced)" "0"
expect "line-shift: resolved"   "$(jget "$out" resolved)"   "0"

# --- case: line-shift in a TAB-NAMED file (AC 1) ------------------------------
# The record handed between the emitter and the consumer is TAB-delimited, and `file` is
# the only field that can carry a TAB verbatim from the analyzer. Unsanitised, the
# consumer re-splits on it and every later field shifts left, so the key absorbs the LINE
# NUMBER — after which the central claim of this whole feature (a shift introduces
# nothing) fails on exactly the shape it is written against. Every other fixture in this
# file uses ASCII, TAB-free names, so the record-transport class was unreachable by
# construction: the same monoculture as the `--cache` form, one field over.
# Deliberately the identical body to `line-shift` above, differing only in the filename.
# NOT mk_stub_gcc: that walks `for f in $(ls *.sh)`, which word-splits on the very TAB
# under test, so it never opens the file and both sides come back empty — the case would
# then pass with introduced=0 for a reason unrelated to the fix. The positive controls
# below caught exactly that during development. NUL-delimited so the stub is not itself
# the thing that breaks on the input.
tabname="$(printf 'x\ty.sh')"
d="$(newrepo tabshift)"
cd "$d" || exit 1
cat > "$d/stub" <<'STUB'
#!/usr/bin/env bash
hit=0
while IFS= read -r -d '' f; do
  f="${f#./}"
  n=0
  while IFS= read -r ln; do
    n=$((n+1))
    case "$ln" in *TRIP*) printf '%s:%s:1: note: msg [SC2086]\n' "$f" "$n"; hit=1 ;; esac
  done < "$f"
done < <(find . -name '*.sh' -not -path './.git/*' -print0 | sort -z)
exit $hit
STUB
chmod +x "$d/stub"
printf 'echo TRIP one\necho ok\n' > "$tabname"
commit_all base
BASE="$(git rev-parse HEAD)"
if git ls-files --error-unmatch "$tabname" >/dev/null 2>&1; then
  { for i in $(seq 20); do echo "# pad $i"; done; cat "$tabname"; } > pad.tmp && mv pad.tmp "$tabname"
  out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.tabc" 2>/dev/null)"
  expect "tab-name: status is ok" "$(jstr "$out" status)" "ok"
  # Positive control: the stub really did find the pre-existing finding on both sides.
  expect "tab-name: base side produced a finding (not a vacuous pass)" "$(jget "$out" base)" "1"
  expect "tab-name: current side produced a finding (not a vacuous pass)" "$(jget "$out" current)" "1"
  # Unsanitised these read 1 and 1 — the shifted line number having entered the key.
  expect "tab-name: a line shift still introduces nothing" "$(jget "$out" introduced)" "0"
  expect "tab-name: and resolves nothing" "$(jget "$out" resolved)" "0"
  # The line number must never appear as a filename in the payload.
  expect "tab-name: no finding keyed on a line number as its filename" \
    "$(printf '%s' "$out" | grep -c '"file":"2[0-9]*"')" "0"
else
  echo "  note  tab-name case skipped: filesystem rejected a TAB in the filename"
fi

# --- case: new finding, gcc format (AC 2) -------------------------------------
d="$(newrepo newgcc)"; mk_stub_gcc "$d/stub"
cd "$d" || exit 1
printf 'echo ok\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
printf 'echo ok\necho TRIP added\n' > a.sh
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.adcache" 2>/dev/null)"
expect "new-finding-gcc: introduced" "$(jget "$out" introduced)" "1"

# --- case: new finding, alternate positional format (AC 2) --------------------
d="$(newrepo newalt)"; mk_stub_alt "$d/stub"
cd "$d" || exit 1
printf 'echo ok\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
printf 'echo ok\necho TRIP added\n' > a.sh
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.adcache" 2>/dev/null)"
expect "new-finding-alt (no per-tool parser): introduced" "$(jget "$out" introduced)" "1"

# --- case: resolved (AC 3) — and empty output must NOT read as unrecognized ---
d="$(newrepo resolved)"; mk_stub_gcc "$d/stub"
cd "$d" || exit 1
printf 'echo TRIP one\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
printf 'echo fixed\n' > a.sh
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.adcache" 2>/dev/null)"
expect "resolved: status is ok (empty output != unrecognized)" "$(jstr "$out" status)" "ok"
expect "resolved: resolved"   "$(jget "$out" resolved)"   "1"
expect "resolved: introduced" "$(jget "$out" introduced)" "0"

# --- case: duplicate counting (AC 4) ------------------------------------------
d="$(newrepo dup)"; mk_stub_gcc "$d/stub"
cd "$d" || exit 1
printf 'echo TRIP x\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
printf 'echo TRIP x\necho TRIP x\necho TRIP x\n' > a.sh
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.adcache" 2>/dev/null)"
expect "duplicate-count: 1 at base, 3 now -> introduced" "$(jget "$out" introduced)" "2"

# --- case: rename, git mv (AC 16) ---------------------------------------------
d="$(newrepo rename)"; mk_stub_gcc "$d/stub"
cd "$d" || exit 1
printf 'echo TRIP one\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
git mv a.sh b.sh >/dev/null 2>&1
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.adcache" 2>/dev/null)"
expect "rename(git mv): introduced" "$(jget "$out" introduced)" "0"
expect "rename(git mv): resolved"   "$(jget "$out" resolved)"   "0"

# --- case: rename via bare mv + intent-add (AC 16, the shape Phase 4 meets) ---
d="$(newrepo rename2)"; mk_stub_gcc "$d/stub"
cd "$d" || exit 1
printf 'echo TRIP one\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
mv a.sh c.sh; git rm -q --cached a.sh >/dev/null 2>&1; git add -N c.sh >/dev/null 2>&1
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.adcache" 2>/dev/null)"
expect "rename(mv + add -N): introduced" "$(jget "$out" introduced)" "0"
expect "rename(mv + add -N): resolved"   "$(jget "$out" resolved)"   "0"

# --- case: unrecognized output shape (AC 2b) ----------------------------------
d="$(newrepo shape)"
cd "$d" || exit 1
cat > "$d/stub" <<'STUB'
#!/usr/bin/env bash
echo "some prose with no file colon line shape at all"
exit 1
STUB
chmod +x "$d/stub"
printf 'echo ok\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.adcache" 2>/dev/null)"
expect "unrecognized-shape: status" "$(jstr "$out" status)" "skip"
expect "unrecognized-shape: detail names the shape" \
  "$(printf '%s' "$out" | grep -c 'shape not recognized')" "1"

# --- case: unparseable output is unrecognized REGARDLESS OF EXIT CODE (AC 2b) --
# The sibling above exits 1; this one is byte-identical but exits 0. AC 2b says the exit
# code does not enter the shape decision, and PLAN.md:192 says so in as many words. The
# rule briefly keyed on `rc` so that the banner case below would not skip — which turned
# THIS case into `status:ok` with all-zero counts, i.e. a confident report of a clean
# tree from a tool whose output was never understood, with the empty base then cached.
# Nothing pinned it, which is how the suite stayed green while the AC was violated.
d="$(newrepo shape0)"
cd "$d" || exit 1
cat > "$d/stub" <<'STUB'
#!/usr/bin/env bash
echo "some prose with no file colon line shape at all"
exit 0
STUB
chmod +x "$d/stub"
printf 'echo ok\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.adcache0" 2>/dev/null)"
expect "unrecognized-shape-exit0: status is skip, not a zero-count ok" "$(jstr "$out" status)" "skip"
expect "unrecognized-shape-exit0: detail names the shape" \
  "$(printf '%s' "$out" | grep -c 'shape not recognized')" "1"

# --- case: a clean run that prints a banner ALSO skips (AC 2b) ----------------
# A DELIBERATE, DOCUMENTED LOSS — read this before "fixing" it back.
# `make lint` echoes its recipe line; plenty of linters print "All checks passed". Such a
# side is (found=0, nonblank>0), which is byte-for-byte the same observation as the
# exit-0 case above — the text cannot separate "clean with a banner" from "findings we
# cannot parse", and the exit code cannot either (it only picks which one to be wrong
# about). So one of the two must lose, and it is this one: skipping costs an ADVISORY
# finding on an opt-in reviewer-context layer, while the alternative fabricates a clean
# bill of health and caches it. `detail` names the shape, so the fix — point
# `analyzer_command` at a machine-readable formatter — is actionable.
d="$(newrepo banner)"
cd "$d" || exit 1
printf 'echo ok\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
printf 'echo ok\necho TRIP added\n' > a.sh
cat > "$d/banner" <<'STUB'
#!/usr/bin/env bash
hit=0
out=""
for f in $(ls *.sh 2>/dev/null); do
  n=0
  while IFS= read -r ln; do
    n=$((n+1))
    case "$ln" in *TRIP*) out="$out$f:$n:1: note: msg [SC2086]
"; hit=1 ;; esac
  done < "$f"
done
if [ "$hit" -eq 0 ]; then echo "All checks passed!"; exit 0; fi
printf '%s' "$out"
exit 1
STUB
chmod +x "$d/banner"
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/banner" bash "$AD" --base "$BASE" --cache "$d/.bn" 2>/dev/null)"
expect "clean-banner: skips honestly rather than reporting a fabricated clean" \
  "$(jstr "$out" status)" "skip"
expect "clean-banner: detail names the shape, so the cause is actionable" \
  "$(printf '%s' "$out" | grep -c 'shape not recognized')" "1"

# --- case: submodule content must not report as introduced (AC 1) -------------
# `git worktree add --detach` does NOT initialise submodules, so the base slot has an
# empty gitlink directory while the live tree has content. Every pre-existing finding
# inside a submodule then exists only on the current side and reads as introduced —
# measured 2 false positives on a tree whose true answer was 0, repeating every round.
# The base-validity rule cannot catch it: that side exits 0, so it "ran".
sroot="$TMPROOT/sublib"; mkdir -p "$sroot"
( cd "$sroot" \
  && git init -q . \
  && git config user.email t@t.t && git config user.name t \
  && printf 'echo TRIP one\necho TRIP two\n' > lib.sh \
  && git add -A && git commit -qm sub ) >/dev/null 2>&1
d="$(newrepo submod)"
cd "$d" || exit 1
printf 'echo ok\n' > top.sh
cat > "$d/sstub" <<'STUB'
#!/usr/bin/env bash
hit=0
for f in $(find . -name '*.sh' -not -path './.git/*' | sed 's|^\./||' | sort); do
  n=0
  while IFS= read -r ln; do
    n=$((n+1))
    case "$ln" in *TRIP*) printf '%s:%s:1: note: msg [SC2086]\n' "$f" "$n"; hit=1 ;; esac
  done < "$f"
done
exit $hit
STUB
chmod +x "$d/sstub"
git -c protocol.file.allow=always submodule add "$sroot" vendor >/dev/null 2>&1
commit_all base
BASE="$(git rev-parse HEAD)"
printf 'echo ok\necho still ok\n' > top.sh   # introduces NOTHING
if [ -f vendor/lib.sh ]; then
  out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/sstub" bash "$AD" --base "$BASE" --cache "$d/.sm" 2>/dev/null)"
  expect "submodule: run is not graded unrecognized" "$(jstr "$out" status)" "ok"
  expect "submodule: contents do not report as introduced" "$(jget "$out" introduced)" "0"
  expect "submodule: contents do not report as resolved"   "$(jget "$out" resolved)"   "0"
else
  echo "  note  submodule case skipped: submodule checkout unavailable here"
fi

# --- case: the exclusion survives TWO submodules and awkward paths (AC 1) -----
# Two independent ways the exclusion silently stopped applying, both of which return the
# introduced-flood verbatim while every status still reads healthy:
#   (a) the gitlink path was rebuilt from awk's whitespace-split fields, so `a  b/sub`
#       came back with the space run collapsed and a non-ASCII path arrived C-quoted
#       ("caf\303\251/sub") because core.quotePath defaults on. Either way the prefix
#       test stops matching. Fixed by anchoring on the record's first TAB, with -z to
#       turn quoting off at the source.
#   (b) the path list was handed to awk through `-v`, which is scanned for escape
#       sequences and rejects a literal newline: macOS awk (20200816) dies with
#       `awk: newline in string` as soon as there are TWO paths. So the feature worked
#       with one submodule and hard-failed with two. Fixed by passing it in ENVIRON.
# The single-submodule case above passes under BOTH bugs, which is why this pins two.
sroot2="$TMPROOT/sublib2"; mkdir -p "$sroot2"
( cd "$sroot2" \
  && git init -q . \
  && git config user.email t@t.t && git config user.name t \
  && printf 'echo TRIP three\n' > lib2.sh \
  && git add -A && git commit -qm sub2 ) >/dev/null 2>&1
d="$(newrepo submod2)"
cd "$d" || exit 1
# top.sh carries a TRIP on BOTH sides, purely as a POSITIVE CONTROL. Without it this
# fixture has zero expected findings anywhere, so a stub that silently walks nothing —
# a degraded `sort -z`, `find -print0` or process substitution, whose stderr scan_tree
# discards — returns empty, grades `ok`, and satisfies introduced=0/resolved=0 for a
# reason unrelated to the exclusion. That is exactly how this case's first draft passed
# under every mutation. The counts assertions below are what make a blind stub fail loud.
printf 'echo ok\necho TRIP top\n' > top.sh
# NOT the sibling case's stub: that one walks `for f in $(find ...)`, which word-splits
# on the very paths under test, so it never opens `ven  dor/lib2.sh` and BOTH sides come
# back with zero findings. The case then passes with introduced=0 for the wrong reason —
# a vacuous pass that survives every mutation of the code it claims to pin. NUL-delimited
# here so the stub itself is not the thing that breaks on a space.
cat > "$d/sstub" <<'STUB'
#!/usr/bin/env bash
hit=0
while IFS= read -r -d '' f; do
  f="${f#./}"
  n=0
  while IFS= read -r ln; do
    n=$((n+1))
    case "$ln" in *TRIP*) printf '%s:%s:1: note: msg [SC2086]\n' "$f" "$n"; hit=1 ;; esac
  done < "$f"
done < <(find . -name '*.sh' -not -path './.git/*' -print0 | sort -z)
exit $hit
STUB
chmod +x "$d/sstub"
# Two submodules, and the second sits at a path with a doubled space.
git -c protocol.file.allow=always submodule add "$sroot" "vendor one" >/dev/null 2>&1
git -c protocol.file.allow=always submodule add "$sroot2" "ven  dor" >/dev/null 2>&1
commit_all base
BASE="$(git rev-parse HEAD)"
# Keeps the TRIP (the positive control) and adds a line: introduces NOTHING, and the
# control finding stays visible on both sides. Its line number moves are irrelevant —
# the line was deliberately left out of the identity key (see the key comment in the
# helper), which the line-shift case at the top of this file pins directly.
printf 'echo ok\necho TRIP top\necho still ok\n' > top.sh
if [ -f "vendor one/lib.sh" ] && [ -f "ven  dor/lib2.sh" ]; then
  out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/sstub" bash "$AD" --base "$BASE" --cache "$d/.sm2" 2>/dev/null)"
  expect "two-submodules: run is graded ok (awk did not die on the -v newline)" \
    "$(jstr "$out" status)" "ok"
  # The positive control. Without these two, a stub that silently walks nothing satisfies
  # every assertion below and the case proves only that zero equals zero.
  expect "two-submodules: base side actually produced findings (not a vacuous pass)" \
    "$(jget "$out" base)" "1"
  expect "two-submodules: current side actually produced findings (not a vacuous pass)" \
    "$(jget "$out" current)" "1"
  expect "two-submodules: neither submodule's content reports as introduced" \
    "$(jget "$out" introduced)" "0"
  expect "two-submodules: neither reports as resolved" "$(jget "$out" resolved)" "0"
else
  echo "  note  two-submodule case skipped: submodule checkout unavailable here"
fi

# --- case: a checkout path with a BACKSLASH does not break the delta (AC 1, 16) -
# `awk -v x=<value>` runs the value through escape processing, so a path is silently
# mangled before awk ever sees it: `a\tb` becomes a 3-char string with a real TAB, and
# `a\qb` becomes `aqb` with the backslash dropped. Both `root` (the tree prefix stripped
# from absolute-path findings) and `renames` (the rename-map filename) travelled that way.
# A mangled `root` makes the prefix strip miss, so base keys (inside the slot) and current
# keys (inside the repo) go disjoint and EVERY finding reports as introduced AND resolved
# — the same flood the tree-strip exists to prevent. Nothing in git forbids this:
# `check-ref-format` bans a backslash in a BRANCH name, but the trigger here is the
# developer's checkout directory. Uses an absolute-path analyzer, because that is the
# only shape for which the strip is load-bearing (`eslint --format unix` is both a
# documented example and a Tier-2 discovery row).
# The stub lives OUTSIDE the backslash directory, deliberately. With the analyzer binary
# itself under a backslash path the run skips before any of this is reached (the command
# path is mangled on its way to invocation — a separate, pre-existing issue parked as a
# follow-up), and the case would then pass or fail for a reason unrelated to `root`.
# Keeping the TREE backslashed and the COMMAND clean isolates exactly the mangling this
# case exists to pin.
absstub="$TMPROOT/absstub"
d="$(newrepo 'back\slash')"
cd "$d" || exit 1
cat > "$absstub" <<'STUB'
#!/usr/bin/env bash
# Emits ABSOLUTE paths, exactly as `eslint --format unix` does.
hit=0
for f in $(ls *.sh 2>/dev/null); do
  n=0
  while IFS= read -r ln; do
    n=$((n+1))
    case "$ln" in *TRIP*) printf '%s/%s:%s:1: note: msg [SC2086]\n' "$PWD" "$f" "$n"; hit=1 ;; esac
  done < "$f"
done
exit $hit
STUB
chmod +x "$absstub"
printf 'echo ok\necho TRIP keep\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
printf 'echo ok\necho TRIP keep\necho TRIP added\n' > a.sh
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$absstub" bash "$AD" --base "$BASE" --cache "$d/.bs" 2>/dev/null)"
expect "backslash-path: status is ok" "$(jstr "$out" status)" "ok"
# The positive control: both sides must actually have found the pre-existing TRIP. If the
# tree-strip breaks, these still read 1 and 2 — it is the delta below that goes wrong.
expect "backslash-path: base side found the pre-existing finding" "$(jget "$out" base)" "1"
expect "backslash-path: current side found both" "$(jget "$out" current)" "2"
# The assertion that matters: exactly ONE new finding, and nothing reported as resolved.
# With a mangled `root` the keys are disjoint, so this reads introduced=2, resolved=1.
expect "backslash-path: exactly one introduced (keys not disjoint)" "$(jget "$out" introduced)" "1"
expect "backslash-path: nothing falsely resolved" "$(jget "$out" resolved)" "0"

# The SECOND path that travelled through `-v`: the rename-map FILENAME, which lives under
# `--cache` and therefore inherits the backslash. This leg fails the most quietly of all —
# `(getline rl < renames) > 0` reports a bad path exactly as it reports end-of-file, so the
# map silently reads empty, no error surfaces anywhere, and a `git mv` double-reports every
# pre-existing finding in the moved file. The case above cannot catch it (no rename means
# an empty map either way), so AC 16 needs its own backslash fixture.
# Stub OUTSIDE the backslash dir for the same reason as the case above; the CACHE stays
# inside it, which is what puts a backslash in the rename-map filename.
relstub="$TMPROOT/relstub"; mk_stub_gcc "$relstub"
d="$(newrepo 'back\slash2')"
cd "$d" || exit 1
printf 'echo TRIP one\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
git mv a.sh b.sh >/dev/null 2>&1
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$relstub" bash "$AD" --base "$BASE" --cache "$d/.bs2" 2>/dev/null)"
expect "backslash-rename: base side found the pre-existing finding" "$(jget "$out" base)" "1"
expect "backslash-rename: rename followed, nothing introduced" "$(jget "$out" introduced)" "0"
expect "backslash-rename: rename followed, nothing resolved"   "$(jget "$out" resolved)"   "0"

# --- case: a ./-emitting analyzer (AC 1, AC 16) -------------------------------
# THE INPUT CLASS THE OTHER FIXTURES STRUCTURALLY CANNOT PRODUCE. Both submodule stubs
# strip `./` before printing (one via `sed 's|^\./||'`, one via `f="${f#./}"`), so every
# mutation harness built around them — including the one that correctly caught the
# doubled-space and two-submodule legs — is blind to this shape by construction. A fix
# validated only against those fixtures is validated against a path form the fixtures
# cannot emit. `flake8 .`, `find . | xargs shellcheck --format=gcc` and most `make lint`
# wrappers all print `./pkg/x.sh`.
#
# Two consumers compare the emitted path against a git-derived one, and git never writes
# a leading `./`: the submodule prefix test (`index("./vendor/lib.sh", "vendor/")` is 3,
# not 1, so the mark stays `K` and the exclusion silently lapses) and the rename map
# (keyed on `git diff --name-status`, which also has no `./`).
sroot3="$TMPROOT/sublib3"; mkdir -p "$sroot3"
( cd "$sroot3" \
  && git init -q . \
  && git config user.email t@t.t && git config user.name t \
  && printf 'echo TRIP s1\necho TRIP s2\n' > lib.sh \
  && git add -A && git commit -qm sub3 ) >/dev/null 2>&1
d="$(newrepo dotslash)"
cd "$d" || exit 1
# Emits ./-relative paths and does NOT strip the prefix — that is the whole point.
#
# The prefix is PARAMETERISED via $DS_PREFIX rather than hardcoded, so the case runs as a
# table over the whole prefix class instead of the one spelling someone happened to think
# of. This is the run's recurring failure mode made mechanical: a mutation harness only
# proves a fix load-bearing for the shapes its fixture can express, and the first version
# of this fix passed its own new test while `.//` and `././` still reproduced the flood
# in full. A table cannot have that blind spot for the axis it enumerates.
cat > "$d/dstub" <<'STUB'
#!/usr/bin/env bash
hit=0
while IFS= read -r -d '' f; do
  f="${f#./}"
  n=0
  while IFS= read -r ln; do
    n=$((n+1))
    case "$ln" in *TRIP*) printf '%s%s:%s:1: note: msg [SC2086]\n' "${DS_PREFIX:-./}" "$f" "$n"; hit=1 ;; esac
  done < "$f"
done < <(find . -name '*.sh' -not -path './.git/*' -print0 | sort -z)
exit $hit
STUB
chmod +x "$d/dstub"
printf 'echo ok\necho TRIP top\n' > top.sh
git -c protocol.file.allow=always submodule add "$sroot3" vendor >/dev/null 2>&1
commit_all base
BASE="$(git rev-parse HEAD)"
printf 'echo ok\necho TRIP top\necho still ok\n' > top.sh   # introduces NOTHING
if [ -f vendor/lib.sh ]; then
  # The whole prefix class, not one spelling. `.//` is what Make-style composition emits
  # when a directory variable holding `.` is interpolated as `$(DIR)/`; `././` is what a
  # wrapper prepending `./` to an already-relative path produces.
  dsi=0
  for pfx in './' './/' '././' './//./'; do
    dsi=$((dsi+1))
    out="$(DS_PREFIX="$pfx" AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/dstub" bash "$AD" --base "$BASE" --cache "$d/.ds$dsi" 2>/dev/null)"
    expect "dotslash[$pfx]: run is graded ok" "$(jstr "$out" status)" "ok"
    # Positive control: the stub really did walk the tree and emit findings.
    expect "dotslash[$pfx]: base side produced findings (not a vacuous pass)" "$(jget "$out" base)" "1"
    expect "dotslash[$pfx]: current side produced findings (not a vacuous pass)" "$(jget "$out" current)" "1"
    # The assertion that matters. Unfixed this reads introduced=2 — the submodule's two
    # pre-existing findings, on a tree whose true answer is 0.
    expect "dotslash[$pfx]: submodule content still excluded" "$(jget "$out" introduced)" "0"
    expect "dotslash[$pfx]: nothing falsely resolved" "$(jget "$out" resolved)" "0"
  done
else
  echo "  note  dotslash submodule case skipped: submodule checkout unavailable here"
fi

# The same normalisation gap breaks rename-following, through the rename map rather than
# the submodule list — a separate consumer, so it needs its own case.
d="$(newrepo dotslash-rename)"
cd "$d" || exit 1
cp "$TMPROOT/dotslash/dstub" "$d/dstub" 2>/dev/null
chmod +x "$d/dstub"
printf 'echo TRIP one\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
git mv a.sh b.sh >/dev/null 2>&1
dri=0
for pfx in './' './/' '././'; do
  dri=$((dri+1))
  out="$(DS_PREFIX="$pfx" AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/dstub" bash "$AD" --base "$BASE" --cache "$d/.dsr$dri" 2>/dev/null)"
  expect "dotslash-rename[$pfx]: base produced findings (not a vacuous pass)" "$(jget "$out" base)" "1"
  expect "dotslash-rename[$pfx]: rename followed, nothing introduced" "$(jget "$out" introduced)" "0"
  expect "dotslash-rename[$pfx]: rename followed, nothing resolved"   "$(jget "$out" resolved)"   "0"
done

# --- case: the CACHE FORM axis — relative --cache must behave (AC 1, AC 16) ---
# THE AXIS EVERY OTHER FIXTURE HOLDS CONSTANT. Every other `--cache` argument in this
# file are absolute (`"$d/…"`), and so is the helper's own built-in default — so a defect
# keyed on the cache PATH FORM was unreachable by construction, no matter how many trees
# the fixtures varied. That is what let this ship: the base worktree slot is created inside
# `$cache` and the slot path becomes awk's `root`, while the current side's root always
# comes from `git rev-parse --show-toplevel` and is absolute. With a relative `--cache` the
# prefix strip therefore succeeded on one side and failed on the other, keys went fully
# disjoint, and EVERY pre-existing finding reported as both introduced and resolved — with
# the slot path leaking into the payload. Reachable on the PRESCRIBED path:
# `phase-3-gates.md` documents `--cache .auto-task/<branch>/artifacts`, which is relative.
#
# Needs an ABSOLUTE-path analyzer, since the strip only matters for that shape.
# Emits `pwd -P`, i.e. the PHYSICAL cwd — what `path.resolve` (eslint), `os.getcwd()`
# (ruff/flake8/mypy) and every compiled linter actually produce. The suite's two other
# absolute-path stubs both use `$PWD`, the LOGICAL cwd, which by construction equals
# whatever `cd "$tree"` set and therefore always equals awk's `root` — so no existing
# fixture can express a getcwd()-based analyzer, and the logical/physical axis was
# unreachable. That blind spot is why `cd && pwd` shipped where the repo convention
# (hooks/settings.sh:215-219, and 13 other hooks) says `pwd -P`.
absstub2="$TMPROOT/absstub2"
cat > "$absstub2" <<'STUB'
#!/usr/bin/env bash
hit=0
here="$(pwd -P)"
for f in $(ls *.sh 2>/dev/null); do
  n=0
  while IFS= read -r ln; do
    n=$((n+1))
    case "$ln" in *TRIP*) printf '%s/%s:%s:1: note: msg [SC2086]\n' "$here" "$f" "$n"; hit=1 ;; esac
  done < "$f"
done
exit $hit
STUB
chmod +x "$absstub2"
cfi=0
for cform in abs rel dotrel symlink cdpath; do
  cfi=$((cfi+1))
  d="$(newrepo "cacheform-$cfi")"
  cd "$d" || exit 1
  printf 'echo ok\necho TRIP keep\n' > a.sh
  commit_all base
  BASE="$(git rev-parse HEAD)"
  printf 'echo ok\necho TRIP keep\necho TRIP added\n' > a.sh
  case "$cform" in
    abs)    carg="$d/.cf" ;;
    rel)    mkdir -p "$d/relcf"; carg="relcf" ;;      # bare relative, as the spec writes
    dotrel) mkdir -p "$d/dotcf"; carg="./dotcf" ;;    # ./-prefixed relative
    # Absolute and already-created, reached through a symlink. This is the logical/physical
    # axis: `cd && pwd` keeps `linkcf` while git's toplevel is physical, so the two roots
    # stop cancelling. NOTE the coverage is platform-contingent — under a PHYSICAL temp root
    # (Linux CI, where mktemp gives /tmp/…) this is the ONLY row that fails a logical-`pwd`
    # regression; on macOS all four fail, but only because `/var` is itself a symlink and
    # `mktemp -d` returns `/var/folders/…`. So this row is the portable guard, and its
    # premise is asserted below rather than assumed.
    symlink) mkdir -p "$d/realcf"; ln -s "$d/realcf" "$d/linkcf" 2>/dev/null; carg="$d/linkcf" ;;
    # The OPERAND-FORM axis: a bare-relative operand is what `cd` searches $CDPATH for, and
    # `CDPATH=.` is an ordinary convenience setting. Unfixed this makes canon_dir return a
    # two-line value (the cd echo plus pwd -P), which becomes the slot path and disjoints
    # the keys. Nothing else in this file varies the inherited environment at all.
    cdpath) mkdir -p "$d/cdpcf"; carg="cdpcf" ;;
  esac
  # PREMISE ASSERTIONS. Any fixture whose setup is built by a command that can fail quietly
  # must assert the setup took effect, or the row degenerates into a duplicate of another
  # and passes for a reason unrelated to its name. The `symlink` row's `ln -s` is
  # `2>/dev/null`, and if it fails the helper's own `mkdir -p "$cache"` creates the path as
  # a real directory — measured: neutering the `ln -s` left all six of its assertions green.
  case "$cform" in
    symlink) expect "cacheform[symlink]: premise — the cache arg really is a symlink" \
               "$([ -L "$d/linkcf" ] && echo yes || echo no)" "yes" ;;
    cdpath)  bare=yes; case "$carg" in /*|./*|../*) bare=no ;; esac
             expect "cacheform[cdpath]: premise — the operand is bare-relative" "$bare" "yes" ;;
  esac
  # CDPATH is exported for the cdpath row ONLY, and `.` is deliberately the benign value:
  # it resolves to the correct directory, so the row isolates the stdout-echo defect rather
  # than conflating it with a wrong-directory redirect.
  case "$cform" in
    cdpath) out="$(CDPATH="." AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$absstub2" bash "$AD" --base "$BASE" --cache "$carg" 2>/dev/null)" ;;
    *)      out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$absstub2" bash "$AD" --base "$BASE" --cache "$carg" 2>/dev/null)" ;;
  esac
  expect "cacheform[$cform]: status is ok" "$(jstr "$out" status)" "ok"
  # Positive controls — both sides must really have scanned, or the deltas below are vacuous.
  expect "cacheform[$cform]: base side found the pre-existing finding" "$(jget "$out" base)" "1"
  expect "cacheform[$cform]: current side found both" "$(jget "$out" current)" "2"
  # The assertions that matter. Unfixed, `rel` and `dotrel` read introduced=2, resolved=1.
  expect "cacheform[$cform]: exactly one introduced (keys not disjoint)" "$(jget "$out" introduced)" "1"
  expect "cacheform[$cform]: nothing falsely resolved" "$(jget "$out" resolved)" "0"
  # The slot path must never reach the payload. Unfixed it appears inside a `resolved` entry.
  expect "cacheform[$cform]: no base-slot path leaked into the payload" \
    "$(printf '%s' "$out" | grep -c 'analyzer-base-')" "0"
done

# --- case: a path that normalises to EMPTY is dropped, not mis-parsed ---------
# `./` alone reduces to "" under the prefix strip. The record must be dropped at the
# EMITTER: the consumer reads with `IFS=<TAB> read`, and TAB is IFS whitespace, so an empty
# field does not arrive empty — the tab run collapses and every later field shifts left.
# Measured before the fix: `K<TAB><TAB>9<TAB>note: bogus` parsed as f=9, l=note: bogus, so
# the consumer's own `[ -n "$f" ]` guard never fired and the run emitted a contentless
# finding whose "filename" was the line number. A downstream guard cannot see a field IFS
# already ate.
d="$(newrepo emptypath)"
cd "$d" || exit 1
cat > "$d/estub" <<'STUB'
#!/usr/bin/env bash
# A real finding, plus — on the CURRENT side only — one whose path field is exactly `./`.
# One-sidedness is what makes the payload assertion below able to fail at all: emitted on
# both sides the bogus key cancels in the delta, so `introduced` is empty whatever the
# guard does, and the assertion passes even with the guard deleted. That is exactly the
# vacuity this suite has produced four times, so the fixture is built to preclude it.
# The sentinel is untracked, so it exists in the live tree and not in the base worktree.
printf 'a.sh:1:1: note: real [SC2086]\n'
[ -f ONESIDED ] && printf './:9:1: note: bogus [SC1000]\n'
exit 1
STUB
chmod +x "$d/estub"
printf 'echo ok\n' > a.sh
commit_all base
: > ONESIDED
BASE="$(git rev-parse HEAD)"
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/estub" bash "$AD" --base "$BASE" --cache "$d/.ep" 2>/dev/null)"
expect "emptypath: status is ok" "$(jstr "$out" status)" "ok"
# The current side emits the bogus line and the base side does not, so a surviving record
# would show up as a NEW finding — which is what makes the assertions below falsifiable.
# The base control is stated rather than left transitive: without it a zero base would
# still trip `introduced`, but only by accident of arithmetic.
expect "emptypath: base side really scanned (not a vacuous pass)" "$(jget "$out" base)" "1"
expect "emptypath: the './' line never becomes a record" "$(jget "$out" current)" "1"
expect "emptypath: no finding is keyed on a line number as its filename" \
  "$(printf '%s' "$out" | grep -c '"file":"9"')" "0"
expect "emptypath: the dropped line does not surface as an introduced finding" \
  "$(jget "$out" introduced)" "0"

# --- case: analyzer absent (AC 7) ---------------------------------------------
d="$(newrepo absent)"
cd "$d" || exit 1
printf 'echo ok\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/definitely-not-installed-xyz" bash "$AD" --base "$BASE" --cache "$d/.adcache" 2>/dev/null)"
rc=$?
expect "analyzer-absent: status" "$(jstr "$out" status)" "skip"
expect "analyzer-absent: exit code (never blocks)" "$rc" "0"
expect "analyzer-absent: detail non-empty" \
  "$([ -n "$(jstr "$out" detail)" ] && echo yes || echo no)" "yes"

# --- case: auto-fix refused (AC 18) -------------------------------------------
d="$(newrepo autofix)"; mk_stub_gcc "$d/stub"
cd "$d" || exit 1
printf 'echo TRIP one\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
# The byte-identical leg must be driven by a stub that WOULD rewrite the tree if it ran.
# Driven by the read-only gcc stub it asserted nothing: mutation-proved to PASS with the
# refusal arm deleted, because a stub that never writes leaves the hash unchanged either
# way. This one appends to a.sh, so the leg fails the moment the refusal stops working.
cat > "$d/writer" <<'STUB'
#!/usr/bin/env bash
printf 'echo mutated-by-autofix
' >> a.sh
printf 'a.sh:1:1: note: msg [SC2086]
'
exit 1
STUB
chmod +x "$d/writer"
h_bf="$(git diff "$BASE" | git hash-object --stdin)"
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/writer --fix" bash "$AD" --base "$BASE" --cache "$d/.adcache" 2>/dev/null)"
expect "autofix-refused: status" "$(jstr "$out" status)" "skip"
expect "autofix-refused: detail names the flag" \
  "$(printf '%s' "$out" | grep -c 'auto-fixing')" "1"

# --- case: flag false-positive must NOT be refused (AC 18) --------------------
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub --no-warnings" bash "$AD" --base "$BASE" --cache "$d/.adcache2" 2>/dev/null)"
expect "flag-false-positive (--no-warnings) runs normally" "$(jstr "$out" status)" "ok"
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub -Werror" bash "$AD" --base "$BASE" --cache "$d/.adcache3" 2>/dev/null)"
expect "flag-false-positive (-Werror) runs normally" "$(jstr "$out" status)" "ok"
# AC 18 also requires the refused case to leave the fixture byte-identical.
h_af="$(git diff "$BASE" | git hash-object --stdin)"
expect "autofix-refused: fixture byte-identical" "$h_af" "$h_bf"

# --- case: mutation detected (AC 19) ------------------------------------------
d="$(newrepo mutate)"
cd "$d" || exit 1
cat > "$d/stub" <<'STUB'
#!/usr/bin/env bash
# a "linter" that rewrites the tree it scans
printf 'echo mutated\n' >> a.sh
echo "a.sh:1:1: note: whatever [SC2086]"
exit 1
STUB
chmod +x "$d/stub"
printf 'echo ok\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.adcache" 2>/dev/null)"
rc=$?
expect "mutation-detected: status" "$(jstr "$out" status)" "skip"
expect "mutation-detected: detail says MUTATED" \
  "$(printf '%s' "$out" | grep -c 'MUTATED')" "1"
expect "mutation-detected: exit code (still never blocks)" "$rc" "0"

# --- case: cache warm + truncated (AC 6) --------------------------------------
d="$(newrepo cache)"; mk_stub_gcc "$d/stub"
cd "$d" || exit 1
printf 'echo TRIP one\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
printf 'echo TRIP one\necho TRIP two\n' > a.sh
out1="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.adcache" 2>/dev/null)"
expect "cache-cold: base_source" "$(jstr "$out1" base_source)" "worktree"
out2="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.adcache" 2>/dev/null)"
expect "cache-warm: base_source" "$(jstr "$out2" base_source)" "cache"
expect "cache-warm: same introduced" "$(jget "$out2" introduced)" "$(jget "$out1" introduced)"
# truncate the cache: sentinel disagrees -> must recompute, not trust
cf=""
for c in "$d/.adcache"/analyzer-base-*.tsv; do [ -f "$c" ] && { cf="$c"; break; }; done
if [ -n "$cf" ]; then
  head -0 "$cf" > "$cf.t" 2>/dev/null; printf '#COUNT=99\n' >> "$cf.t"; mv "$cf.t" "$cf"
  out3="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.adcache" 2>/dev/null)"
  expect "cache-truncated: recomputed" "$(jstr "$out3" base_source)" "worktree"
  expect "cache-truncated: introduced unchanged" "$(jget "$out3" introduced)" "$(jget "$out1" introduced)"
else
  expect "cache-truncated: cache file located" "no" "yes"
fi

# --- case: a stale-FORMAT cache must not be reused (AC 6) ---------------------
# The cache stores KEYS. If the key-construction algorithm changes, an old cache is
# incomparable with a freshly-scanned current side and EVERY key goes disjoint —
# introduced and resolved both equal the full finding count. Measured for real during
# this run: 366/366 on a tree whose true answer was 0/0. KEY_FORMAT in the cache key is
# what prevents it; this pins that it is actually part of the key.
d="$(newrepo keyfmt)"; mk_stub_gcc "$d/stub"
cd "$d" || exit 1
printf 'echo TRIP one\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
printf 'echo TRIP one\necho TRIP two\n' > a.sh
out1="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.kf" 2>/dev/null)"
kf_before=0
for c in "$d/.kf"/analyzer-base-*.tsv; do [ -f "$c" ] && kf_before=$((kf_before+1)); done
# A different KEY_FORMAT must select a DIFFERENT cache file rather than reuse this one.
out2="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" AUTO_TASK_ANALYZER_KEY_FORMAT=99 bash "$AD" --base "$BASE" --cache "$d/.kf" 2>/dev/null)"
kf_after=0
for c in "$d/.kf"/analyzer-base-*.tsv; do [ -f "$c" ] && kf_after=$((kf_after+1)); done
expect "key-format: first run warms one cache file" "$kf_before" "1"
expect "key-format: a different format writes a SECOND cache file" "$kf_after" "2"
expect "key-format: recomputed, not reused" "$(jstr "$out2" base_source)" "worktree"
expect "key-format: delta identical across formats" "$(jget "$out2" introduced)" "$(jget "$out1" introduced)"

# --- case: a SIGNAL-KILLED scan must not read as a clean one (AC 11) ----------
# The `killed` status was produced and never consumed once, so a SIGKILLed scan fell
# through to the success path and fabricated findings. Both sides are pinned, because
# they are separate consumer sites and the base-side one also poisons the cache.
d="$(newrepo killed)"          # drives $d/kstub below, not the shared gcc stub
cd "$d" || exit 1
printf 'echo TRIP one\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
# Dies only when the marker file is ABSENT — i.e. in the base checkout, where untracked
# files do not exist. The current tree has the marker, so that side completes normally.
cat > "$d/kstub" <<'STUB'
#!/usr/bin/env bash
if [ ! -f ./.marker ]; then kill -9 $$; fi
args=""
for a in "$@"; do case "$a" in --) ;; -*) ;; *) args="$args $a" ;; esac; done
set -- ${args:-$(ls *.sh 2>/dev/null)}
hit=0
for f in "$@"; do
  [ -f "$f" ] || continue
  n=0
  while IFS= read -r ln; do
    n=$((n+1))
    case "$ln" in *TRIP*) printf '%s:%s:1: note: msg [SC2086]\n' "$f" "$n"; hit=1 ;; esac
  done < "$f"
done
exit $hit
STUB
chmod +x "$d/kstub"
printf 'x\n' > .marker
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/kstub" bash "$AD" --base "$BASE" --cache "$d/.k" 2>/dev/null)"
expect "killed-base: status is skip, not ok" "$(jstr "$out" status)" "skip"
expect "killed-base: detail names the signal" \
  "$(printf '%s' "$out" | grep -c 'killed by a signal')" "1"
kcache=0
for c in "$d/.k"/analyzer-base-*.tsv; do [ -f "$c" ] && kcache=$((kcache+1)); done
expect "killed-base: no poisoned cache written" "$kcache" "0"

# Current side: dies when the marker IS present, so the base checkout scans fine.
d="$(newrepo killed2)"
cd "$d" || exit 1
printf 'echo TRIP one\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
cat > "$d/kstub2" <<'STUB'
#!/usr/bin/env bash
if [ -f ./.marker ]; then kill -9 $$; fi
printf 'a.sh:1:1: note: msg [SC2086]\n'
exit 1
STUB
chmod +x "$d/kstub2"
printf 'x\n' > .marker
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/kstub2" bash "$AD" --base "$BASE" --cache "$d/.k2" 2>/dev/null)"
expect "killed-current: status is skip, not ok" "$(jstr "$out" status)" "skip"
expect "killed-current: nothing reported as resolved" \
  "$(printf '%s' "$out" | grep -c '"resolved":\[\]')" "1"

# --- case: a Tier-1 command with no targets gets no `--` appended (AC 9) ------
# The `--` that protects flag-shaped filenames must be added ONLY when targets are
# actually passed. Appended unconditionally it broke commands whose parser rejects a
# bare `--` — measured on `go vet ./... --` — surfacing as a skip that blamed the tree.
# This stub REJECTS a bare `--`, so it fails if the unconditional form ever returns.
d="$(newrepo nodashes)"
cd "$d" || exit 1
printf 'echo ok\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
printf 'echo ok\necho TRIP added\n' > a.sh
cat > "$d/picky" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in --) echo "malformed argument: leading dash" >&2; exit 2 ;; esac
done
hit=0
for f in $(ls *.sh 2>/dev/null); do
  n=0
  while IFS= read -r ln; do
    n=$((n+1))
    case "$ln" in *TRIP*) printf '%s:%s:1: note: msg [SC2086]\n' "$f" "$n"; hit=1 ;; esac
  done < "$f"
done
exit $hit
STUB
chmod +x "$d/picky"
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/picky" bash "$AD" --base "$BASE" --cache "$d/.nd" 2>/dev/null)"
expect "no-targets: picky Tier-1 command still runs" "$(jstr "$out" status)" "ok"
expect "no-targets: delta correct" "$(jget "$out" introduced)" "1"

# --- case: a flag-shaped filename must not disable the layer (AC 10) ----------
# This exercises TIER 2 deliberately, with the real analyzer: the helper only passes
# filenames as arguments on the self-constructed path, so a Tier-1 stub cannot reach the
# defect. A tracked `-x.sh` was consumed by the tool as an option, disabling the layer
# while reporting "the base tree could not be analyzed usefully" — fail-open holding with
# the wrong stated cause. `--` before the targets is what closes it.
if command -v shellcheck >/dev/null 2>&1; then
  d="$(newrepo dashfile)"
  cd "$d" || exit 1
  # shellcheck disable=SC2016  # The single quotes are REQUIRED and the `$f` is literal:
  # this printf writes a FIXTURE that must itself contain an unquoted `$f`, because that
  # is what makes the real ShellCheck emit SC2086 against the generated file. Expanding
  # here would write the harness's own empty variable and the fixture would be clean —
  # the case would pass while testing nothing.
  printf 'f=$1\ncat $f\n' > a.sh
  printf 'echo ok\n' > ./-x.sh
  commit_all base
  BASE="$(git rev-parse HEAD)"
  # shellcheck disable=SC2016  # same literal-fixture reason as above
  printf 'f=$1\ncat $f\ncat $f\n' > a.sh
  out="$(AUTO_TASK_HOME="$TMPROOT/home" bash "$AD" --base "$BASE" --cache "$d/.d" 2>/dev/null)"
  expect "dash-filename: layer still runs (not a misreported skip)" "$(jstr "$out" status)" "ok"
  expect "dash-filename: delta still correct" "$(jget "$out" introduced)" "1"
else
  echo "  note  dash-filename case skipped: shellcheck not installed"
fi

# --- case: no residue (AC 5) --------------------------------------------------
# Driven by the CACHING stub, per AC 5: the cleanup ladder only matters for a linter
# that writes into the tree it scans, and `git worktree remove` refuses a worktree
# holding untracked files without --force.
d="$(newrepo residue)"; mk_stub_caching "$d/stub"
cd "$d" || exit 1
printf 'echo TRIP one\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
printf 'echo TRIP one\necho TRIP two\n' > a.sh
h_before="$(git diff "$BASE" | git hash-object --stdin)"
wt_before="$(git worktree list | grep -c .)"
rout="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.adcache" 2>/dev/null)"
h_after="$(git diff "$BASE" | git hash-object --stdin)"
wt_after="$(git worktree list | grep -c .)"
slots=0
for s in "$d/.adcache"/.analyzer-base-*; do [ -d "$s" ] && slots=$((slots+1)); done
# leg (c): everything under the cache dir EXCEPT the expected base .tsv must be gone —
# the temp record files, the status files, the rename map, and any stranded .tmp.$$.
stray=0
for f in "$d/.adcache"/* "$d/.adcache"/.[!.]*; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in
    analyzer-base-*.tsv) ;;                    # the cache itself is expected
    *) stray=$((stray+1)) ;;
  esac
done
# Self-guard: without this, all four legs below would pass vacuously if a future change
# made the helper skip before it ever created a slot. Gate A flagged exactly that. A
# residue check that cannot tell "cleaned up properly" from "never ran" is the same
# class of defect as the vacuous stub this case was already rebuilt to avoid.
expect "residue: the run actually ran (not a vacuous pass)" "$(jstr "$rout" status)" "ok"
expect "residue: diff hash unchanged"     "$h_before" "$h_after"
expect "residue: worktree count unchanged" "$wt_before" "$wt_after"
expect "residue: no slot dirs left"        "$slots" "0"
expect "residue: cache dir holds only the expected .tsv" "$stray" "0"

# --- case: stale slot self-heals, live peer survives (AC 17) ---------------
d="$(newrepo slots)"; mk_stub_gcc "$d/stub"
cd "$d" || exit 1
printf 'echo TRIP one\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
mkdir -p "$d/.adcache/.analyzer-base-999999-1"   # dead pid
mkdir -p "$d/.adcache/.analyzer-base-$$-7"       # THIS shell: alive
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.adcache" 2>/dev/null)"
expect "stale-slot: run still ok" "$(jstr "$out" status)" "ok"
expect "stale-slot: dead slot removed" \
  "$([ -d "$d/.adcache/.analyzer-base-999999-1" ] && echo yes || echo no)" "no"
expect "live-peer-slot: alive peer preserved" \
  "$([ -d "$d/.adcache/.analyzer-base-$$-7" ] && echo yes || echo no)" "yes"

# --- case: timeout is bounded and fails open (AC 21) --------------------------
d="$(newrepo timeout)"
cd "$d" || exit 1
cat > "$d/stub" <<'STUB'
#!/usr/bin/env bash
sleep 30
STUB
chmod +x "$d/stub"
printf 'echo ok\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
t0=$(date +%s)
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" AUTO_TASK_ANALYZER_TIMEOUT=2 bash "$AD" --base "$BASE" --cache "$d/.adcache" 2>/dev/null)"
t1=$(date +%s)
expect "timeout: status"   "$(jstr "$out" status)" "skip"
expect "timeout: bounded"  "$([ $((t1-t0)) -lt 25 ] && echo yes || echo no)" "yes"
# Pin the REASON, not just the outcome. Without this the case passed with run_bounded
# replaced by `return 127` — the skip reason silently became "base tree could not be
# analyzed usefully" and nothing about the alarm shim, the process-group kill, or the
# 142 mapping was exercised. AC 21 requires that `detail` name the timeout.
expect "timeout: detail names the timeout" \
  "$(printf '%s' "$out" | grep -c 'timed out after')" "1"

# --- case: a NON-POSITIVE timeout falls back, however it is spelled (AC 21) ---
# `alarm 0` in perl CANCELS the alarm instead of firing, so a zero timeout disarms the
# only bound the helper has. The first guard enumerated the literal `0`, which left `00`
# — digits-only, and not the string `0` — walking straight through: measured `alarm 00`
# NOT_FIRED against a 10s sleep, and a `sleep 30` stub then running 91s and reporting
# `status:"ok"` with zero counts, i.e. a fabricated clean tree from a scan that never
# finished. Nothing pinned the guard at all, so reverting it left the suite fully green.
# `00` is the case that actually escaped; `000` is here because an enumerating guard
# would need a third literal for it, which is the point.
# Observed through the VERSION PROBE, which is what makes this testable in seconds. The
# scan bound cannot distinguish the two states in a fast test: whether the fallback gives
# 120s or the bug gives no bound at all, any stub short enough to run in a suite finishes
# on its own first. `ver_bound` does distinguish, because it is DERIVED from the same
# value — `ver_bound=10` unless `timeout_sec` is smaller. With the guard defeated
# `timeout_sec` stays `00`, `[ 00 -lt 10 ]` is true, so the probe inherits `00` and runs
# unbounded; with the fallback applied `timeout_sec` is 120, so the probe is bounded at
# 10s. A stub that hangs for 25s on `--version` therefore separates them cleanly: ~10s
# fixed versus ~25s broken. This is the two-door failure pass 1 measured, caught at the
# door that is cheap to observe.
for tv in 0 00; do
  d="$(newrepo "tmo-$tv")"
  cd "$d" || exit 1
  cat > "$d/stub" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in --version) sleep 25; echo "stub 1.0"; exit 0 ;; esac
done
exit 0
STUB
  chmod +x "$d/stub"
  printf 'echo ok\n' > a.sh
  commit_all base
  BASE="$(git rev-parse HEAD)"
  out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" AUTO_TASK_ANALYZER_TIMEOUT="$tv" bash "$AD" --base "$BASE" --cache "$d/.tmo" 2>/dev/null)"
  # Asserted on the PAYLOAD, not on the clock. An elapsed-time assertion here would
  # discriminate the same two states (measured 10s fixed vs 25s broken) but only by a
  # margin a loaded machine can erase, and it adds nothing: with the probe bounded at 10s
  # the 25s `--version` is killed and `analyzer_version` stays `unknown`, while a
  # defeated guard lets the probe finish and reports `stub 1.0`. That is the same
  # discrimination with no load dependency. It also cannot pass vacuously — `emit_skip`
  # emits no `analyzer_version` key at all, so any skip makes `jstr` return empty and
  # this assertion red, rather than silently green on a fixture that never ran.
  expect "timeout-$tv: non-positive falls back, so the version probe stays bounded" \
    "$(jstr "$out" analyzer_version)" "unknown"
done

# A positive timeout with LEADING ZEROS must still be honoured — the guard rejects
# non-positive values, not zero-padded ones. `[ 007 -gt 0 ]` is true in bash (base-10,
# no octal trap) and perl numifies `007` to 7, measured FIRED. Without this the obvious
# over-correction — rejecting anything starting with `0` — would silently rewrite a
# 7-second bound to 120.
d="$(newrepo tmo-pad)"
cd "$d" || exit 1
cat > "$d/stub" <<'STUB'
#!/usr/bin/env bash
sleep 30
STUB
chmod +x "$d/stub"
printf 'echo ok\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
t0=$(date +%s)
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" AUTO_TASK_ANALYZER_TIMEOUT=002 bash "$AD" --base "$BASE" --cache "$d/.pad" 2>/dev/null)"
t1=$(date +%s)
expect "timeout-002: honoured as 2s, not rejected to the 120s default" \
  "$([ $((t1-t0)) -lt 25 ] && echo yes || echo no)" "yes"
expect "timeout-002: detail names the timeout" \
  "$(printf '%s' "$out" | grep -c 'timed out after')" "1"

# --- case: works with jq absent (AC 8) ----------------------------------------
d="$(newrepo nojq)"; mk_stub_gcc "$d/stub"
cd "$d" || exit 1
printf 'echo ok\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
printf 'echo ok\necho TRIP added\n' > a.sh
mkdir -p "$d/poison"
cat > "$d/poison/jq" <<'STUB'
#!/usr/bin/env bash
echo poisoned > "$JQ_MARKER"
exit 127
STUB
chmod +x "$d/poison/jq"
out="$(cd "$d" && JQ_MARKER="$d/jq-was-called" PATH="$d/poison:$PATH" \
      AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" /bin/bash "$AD" --base "$BASE" --cache "$d/.adcache" 2>/dev/null)"
expect "no-jq: still produces a delta" "$(jget "$out" introduced)" "1"
expect "no-jq: valid JSON (has counts)" \
  "$(printf '%s' "$out" | grep -c '"counts"')" "1"
# The marker records whether jq was invoked at all. Either answer is acceptable per
# AC 8 — settings.sh legitimately calls jq and fails open — but leaving it unasserted
# made the shim dead weight rather than evidence. What must hold is that the helper
# produced a correct delta regardless, which the assertion above establishes.
echo "  note  jq invoked during the no-jq run: $([ -f "$d/jq-was-called" ] && echo yes || echo no)"
# Runs the helper under whatever /bin/bash is, and reports that version for context.
# It deliberately does NOT assert the host is bash 3.2: that is a property of the
# machine, not of this code, and it hard-failed the whole suite on any Linux box where
# /bin/bash is 5.x. The 3.2 guarantee is exercised by RUNNING under /bin/bash above.
echo "  note  /bin/bash is $(/bin/bash --version 2>/dev/null | head -1 | sed 's/.*version //; s/ .*//')"

# --- case: discovery honours priority order (AC 9) ----------------------------
# Tier 1 (explicit setting) must outrank Tier 2 (self-constructed), and Tier 2 must
# outrank the skip. Probed by removing one tier at a time from the same fixture.
d="$(newrepo discover)"; mk_stub_gcc "$d/stub"
cd "$d" || exit 1
printf 'echo ok\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.c1" 2>/dev/null)"
expect "discovery: setting wins when present" "$(jstr "$out" analyzer_source)" "setting"
# Tier 1 removed: a repo with .sh files + shellcheck on PATH self-constructs a command.
if command -v shellcheck >/dev/null 2>&1; then
  out="$(AUTO_TASK_HOME="$TMPROOT/home" bash "$AD" --base "$BASE" --cache "$d/.c2" 2>/dev/null)"
  expect "discovery: falls to self-constructed invocation" "$(jstr "$out" analyzer_source)" "discovered"
else
  # No tautological expect here — `expect x x` would inflate the pass count while
  # asserting nothing. Report the skip and move on.
  echo "  note  discovery tier-2 case skipped: shellcheck not installed"
fi
# Tier 2 removed too (no marker: no .sh files, and PATH stripped of every known tool).
e="$(newrepo discover2)"
cd "$e" || exit 1
printf 'hello\n' > README.md
commit_all base
BASE2="$(git rev-parse HEAD)"
out="$(AUTO_TASK_HOME="$TMPROOT/home" PATH=/usr/bin:/bin bash "$AD" --base "$BASE2" --cache "$e/.c" 2>/dev/null)"
expect "discovery: nothing resolvable -> none" "$(jstr "$out" analyzer_source)" "none"
expect "discovery: nothing resolvable -> skip" "$(jstr "$out" status)" "skip"

# --- case: marker present but tool absent (AC 10) -----------------------------
# The helper must never NAME a tool the machine lacks — that would be a failed
# invocation reported as a finding-less run rather than an honest "not available".
d="$(newrepo marker)"
cd "$d" || exit 1
printf 'echo ok\n' > a.sh          # marker for shellcheck
commit_all base
BASE="$(git rev-parse HEAD)"
out="$(AUTO_TASK_HOME="$TMPROOT/home" PATH=/usr/bin:/bin bash "$AD" --base "$BASE" --cache "$d/.c" 2>/dev/null)"
expect "marker-no-tool: analyzer_source" "$(jstr "$out" analyzer_source)" "none"
expect "marker-no-tool: status"          "$(jstr "$out" status)" "skip"
expect "marker-no-tool: detail says no analyzer available" \
  "$(printf '%s' "$out" | grep -c 'no analyzer resolvable')" "1"

# --- case: base side could not run usefully (AC 11) ---------------------------
# Closed-form rule: a side "ran" iff it exited 0 OR produced >=1 positional finding.
# A stub that exits non-zero with no findings fails both legs, so the base is
# untrustworthy and the run must SKIP rather than report every finding as introduced.
d="$(newrepo basebroken)"
cd "$d" || exit 1
printf 'echo TRIP one\n' > a.sh
commit_all base
BASE="$(git rev-parse HEAD)"
# Emits findings only when the marker file exists — absent in the base checkout
# (untracked), present now. That models a linter whose deps are missing at base.
cat > "$d/stub" <<'STUB'
#!/usr/bin/env bash
if [ ! -f ./.deps-present ]; then
  echo "cannot find module: deps missing" >&2
  exit 2
fi
echo "a.sh:1:1: note: msg [SC2086]"
exit 1
STUB
chmod +x "$d/stub"
printf 'x\n' > .deps-present
out="$(AUTO_TASK_HOME="$TMPROOT/home" AUTO_TASK_ANALYZER_COMMAND="$d/stub" bash "$AD" --base "$BASE" --cache "$d/.c" 2>/dev/null)"
expect "base-broken: status" "$(jstr "$out" status)" "skip"
# Not `introduced == 0` — emit_skip hardcodes that on every skip, so the assertion
# could never fail. Assert the payload carries no entries instead.
expect "base-broken: introduced array is empty" \
  "$(printf '%s' "$out" | grep -c '"introduced":\[\]')" "1"
expect "base-broken: detail names the unusable base" \
  "$(printf '%s' "$out" | grep -c 'base tree could not be analyzed')" "1"

echo
echo "analyzer-delta.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
