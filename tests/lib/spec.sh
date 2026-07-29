# tests/lib/spec.sh — spec-search helpers for the SKILL.md / references/ split.
#
# The auto-task spec used to be one file, so tests grepped `skills/auto-task/SKILL.md`
# directly. It is now a spine plus `skills/auto-task/references/*.md`. These helpers
# search the spine AND the references so an assertion keeps resolving wherever its
# prose ended up — and so a future boundary adjustment costs no test churn.
#
# Semantics are deliberate, because the suite contains four assertion SHAPES:
#
#   presence      spec_has "<pat>"            -> exit 0 if found anywhere
#   exact count   spec_count "<pat>"          -> SUMMED occurrences across all files
#   zero count    spec_count "<pat>" == 0     -> union scope is CORRECT here (see below)
#   positional    spec_line / spec_window / spec_before / spec_same_file
#
# Two choices are load-bearing:
#
#  * SUMMED, not per-file. An assertion like `spec_count 'five policy questions' == 2`
#    survives relocation only if occurrences are summed across spine + references.
#    Per-file counting breaks the moment one of the two sites moves.
#
#  * Union scope is CORRECT for zero-count (anti-regression) assertions, not merely
#    convenient. "This superseded phrasing is gone" must hold for the WHOLE spec;
#    scoping it to the spine would let stale phrasing survive unnoticed inside a
#    reference file. Union makes those assertions strictly stronger than before.
#
# Deliberately NOT provided: a helper that hides WHERE something lives. Contracts
# that must stay in the always-loaded spine are asserted against SKILL.md directly
# (see tests/enforcement-spine.test.sh), because a location-blind search would let a
# future edit quietly demote them into a reference and stay green.

# Resolve the repo root from this file's location, unless the caller set it.
if [ -z "${SPEC_ROOT:-}" ]; then
  SPEC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
SPEC_SPINE="${SPEC_SPINE:-$SPEC_ROOT/skills/auto-task/SKILL.md}"
SPEC_REFDIR="${SPEC_REFDIR:-$SPEC_ROOT/skills/auto-task/references}"

# spec_concat — write spine + references/*.md into one temp file and echo its path.
#
# This is how the pre-existing test files are re-plumbed with a ONE-LINE change
# instead of rewriting ~400 assertions: a test sets `SKILL="$(spec_concat)"` and
# every existing `grep -cF ... "$SKILL"`, `has "$SKILL" ...` and
# `sed -n "${a},${b}p" "$SKILL"` keeps working, now with union semantics —
# presence, SUMMED counts, union zero-counts, and intact line windows (windows
# stay intact because the co-location constraint keeps positionally-coupled
# prose inside a single source file, so concatenation never splits a window).
#
# This is NOT a committed build artifact: it is regenerated from the real
# sources on every run, so it cannot drift and adds no build step.
#
# CLEANUP: this function registers its own EXIT trap, so callers need do nothing — with
# ONE exception. If you set your own EXIT trap AFTER calling spec_concat_into, yours
# replaces ours and the temp file leaks; chain it yourself in that case:
#   trap 'rm -rf "$mytmp"; _spec_concat_cleanup' EXIT
# (tests/release-step.test.sh:852 does this.) Setting your trap BEFORE the call is safe —
# we detect and chain onto it.
# An earlier version claimed "the caller owns cleanup; tests already trap-remove
# their temp dirs" — that was false (no caller removed it, and the file is created
# in $TMPDIR rather than inside any test's temp dir), which leaked ~426 KB per call
# and accumulated tens of MB across runs.
#
# It deliberately does NOT replace the spine-only assertions: contracts that
# must stay in the always-loaded SKILL.md are still grepped against that file
# directly (tests/enforcement-spine.test.sh), because a union view would let a
# future edit quietly demote them into a reference and stay green.
# Re-source-safe: sourcing spec.sh twice must NOT wipe the tracked temp files, or the
# EXIT cleanup silently no-ops (that is exactly what happened when a caller sourced
# it a second time mid-file).
: "${_SPEC_CONCAT_FILES:=}"
# A REAL newline. Written as a variable because "\n" inside double quotes is a literal
# backslash-n, which is exactly the bug that made cleanup silently no-op for >=2 concats.
_SPEC_NL=$'\n'
# Newline-delimited, so a TMPDIR containing spaces cannot split a path apart. (An
# earlier version used unquoted word-splitting on a space-separated list.)
_spec_concat_cleanup() {
  [ -n "$_SPEC_CONCAT_FILES" ] || return 0
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && rm -f "$f"
  done <<< "$_SPEC_CONCAT_FILES"
  _SPEC_CONCAT_FILES=""
}

# spec_concat_into <varname> — build the concatenation, assign its path to <varname>,
# and register cleanup. USE THIS, not `VAR="$(spec_concat)"`.
#
# Why the odd calling convention: a trap registered inside `$( ... )` is registered in
# the command-substitution SUBSHELL, which exits immediately — so the temp file would be
# deleted before the caller ever read it. Assigning through a named variable keeps the
# function in the caller's shell, so its EXIT trap actually covers the test run.
#
# The path comes from `mktemp`, i.e. it is UNIQUE per call. An earlier version used a
# deterministic name derived from "$0" to bound a leak; that was a mistake. $TMPDIR is
# per-user, not per-checkout, and this repo runs the same-named tests from several
# sibling worktrees at once — so the name collided, one run truncated or rm-ed another
# run's file, and `grep -c` on the foreign/missing file returned 0. That makes every
# zero-count anti-regression assertion pass for the WRONG reason. Uniqueness is not
# optional here; the EXIT trap below is what prevents the leak.
spec_concat_into() {
  local __spec_var="$1" __spec_out __spec_f __spec_prev __spec_need_chain
  case "$__spec_var" in
    __spec_*|"")
      echo "spec_concat_into: refusing target name '$__spec_var' (collides with this function's locals)" >&2
      return 1 ;;
  esac
  __spec_out="$(mktemp "${TMPDIR:-/tmp}/spec-concat.XXXXXX")" || {
    echo "spec_concat_into: mktemp failed" >&2; return 1; }
  while IFS= read -r __spec_f; do
    [ -n "$__spec_f" ] || continue
    cat "$__spec_f" >> "$__spec_out" || {
      echo "spec_concat_into: cannot read spec file '$__spec_f'" >&2
      rm -f "$__spec_out"   # no trap is registered yet, so nothing else would reclaim it
      return 1; }
  done < <(spec_files)
  # FAIL CLOSED on an empty concatenation. A spine that exists but is unreadable or
  # zero-byte would otherwise yield an empty union, and every zero-count assertion
  # would pass vacuously — the same silent-green class this library exists to stop.
  if [ ! -s "$__spec_out" ]; then
    echo "spec_concat_into: FATAL — the spec concatenation is empty (unreadable or zero-byte spine at '$SPEC_SPINE'?). Refusing to continue: zero-count assertions would pass vacuously." >&2
    rm -f "$__spec_out"
    exit 2
  fi
  # Chain onto any EXIT trap the caller already set, so we never clobber it. Let BASH
  # parse its own `trap -p` output rather than sed: the body may span newlines and may
  # contain single quotes rendered as '\'' , both of which a line-oriented sed either
  # misses (silently dropping the caller's handler) or double-escapes (corrupting it).
  # Re-chain on every call whose current EXIT trap lacks our cleanup — not just the first.
  # A caller that sets its own EXIT trap AFTER a concat clobbers the chain; re-chaining
  # recovers on the next concat. The single-concat-then-trap ordering still cannot be
  # recovered from inside this function, which is why the contract note above says the
  # caller must chain in that case (tests/release-step.test.sh does exactly that).
  #
  # The membership test MUST use command substitution, not `trap -p EXIT | grep -q`: bash
  # RESETS the EXIT trap inside a pipeline subshell, so `trap -p` there prints nothing and
  # the test never matches — which made this guard a no-op and let the trap body
  # accumulate one copy of the cleanup per concat. `$( )` does report it (the same reason
  # the chaining read below works).
  case "$(trap -p EXIT)" in
    *_spec_concat_cleanup*) __spec_need_chain=0 ;;
    *)                      __spec_need_chain=1 ;;
  esac
  if [ "$__spec_need_chain" = 1 ]; then
    local __spec_trap=()
    # shellcheck disable=SC2207
    eval "__spec_trap=($(trap -p EXIT))" 2>/dev/null || __spec_trap=()
    __spec_prev="${__spec_trap[2]:-}"
    if [ -n "$__spec_prev" ]; then
      # shellcheck disable=SC2064
      trap "_spec_concat_cleanup; $__spec_prev" EXIT
    else
      trap '_spec_concat_cleanup' EXIT
    fi
  fi
  _SPEC_CONCAT_FILES="${_SPEC_CONCAT_FILES:+$_SPEC_CONCAT_FILES$_SPEC_NL}$__spec_out"
  printf -v "$__spec_var" '%s' "$__spec_out"
}

# spec_files — ordered spec file list: spine first, then references sorted.
# Single source of truth for every other helper.
#
# Resolution is validated ONCE at source time (see the guard at the bottom of this
# file), not here: `spec_files` is always consumed from a subshell
# (`$(...)` / `< <(...)`), so an `exit` inside it would kill only that subshell and
# the caller would still see an empty list — the exact vacuous-pass it was meant to
# prevent. The source-time guard runs in the test's own shell, so it can actually
# abort the run.
spec_files() {
  [ -f "$SPEC_SPINE" ] && printf '%s\n' "$SPEC_SPINE"
  _spec_ref_files
}

# _spec_ref_files — the single source of truth for which reference files are in the union.
#
# Includes SYMLINKS (`-type l`), not just regular files. A bare `-type f` silently dropped
# a symlinked reference from the union AND from the guard that was supposed to validate it
# — the guard was a parallel traversal of the same filtered list, so it could only ever
# check files the union already saw. Every -r/-s test below follows symlinks, so including
# them here means one list is both searched and validated.
_spec_ref_files() {
  [ -d "$SPEC_REFDIR" ] || return 0
  find "$SPEC_REFDIR" -maxdepth 1 -name '*.md' \( -type f -o -type l \) 2>/dev/null | LC_ALL=C sort
}

# spec_has <fixed-string> — exit 0 if the pattern occurs in ANY spec file.
spec_has() {
  local pat="$1" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qF -- "$pat" "$f" && return 0
  done < <(spec_files)
  return 1
}

# spec_has_re <ere> — regex variant of spec_has.
spec_has_re() {
  local pat="$1" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qE -- "$pat" "$f" && return 0
  done < <(spec_files)
  return 1
}

# spec_count <fixed-string> — SUMMED occurrence count across all spec files.
spec_count() {
  local pat="$1" f total=0 n
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n="$(grep -cF -- "$pat" "$f" 2>/dev/null || true)"
    total=$((total + ${n:-0}))
  done < <(spec_files)
  printf '%s\n' "$total"
}

# spec_count_re <ere> — SUMMED regex occurrence count across all spec files.
spec_count_re() {
  local pat="$1" f total=0 n
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n="$(grep -cE -- "$pat" "$f" 2>/dev/null || true)"
    total=$((total + ${n:-0}))
  done < <(spec_files)
  printf '%s\n' "$total"
}

# spec_file_of <fixed-string> — path of the first spec file containing the pattern.
spec_file_of() {
  local pat="$1" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qF -- "$pat" "$f" && { printf '%s\n' "$f"; return 0; }
  done < <(spec_files)
  return 1
}

# spec_line <fixed-string> — "<file>:<lineno>" of the first match.
spec_line() {
  local pat="$1" f n
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n="$(grep -nF -- "$pat" "$f" 2>/dev/null | head -1 | cut -d: -f1)"
    [ -n "$n" ] && { printf '%s:%s\n' "$f" "$n"; return 0; }
  done < <(spec_files)
  return 1
}

# spec_window <fixed-string> <n> — the <n> lines FOLLOWING the first match,
# within the file that contains it. A window can never span two files, so an
# assertion built on it stays meaningful after a carve.
spec_window() {
  local pat="$1" n="$2" loc f ln
  loc="$(spec_line "$pat")" || return 1
  f="${loc%:*}"; ln="${loc##*:}"
  sed -n "${ln},$((ln + n))p" "$f"
}

# spec_same_file <patA> <patB> — exit 0 iff both anchors resolve to the same file.
# Guard for ordering assertions: positionally-coupled prose must stay co-located.
spec_same_file() {
  local a b
  a="$(spec_file_of "$1")" || return 1
  b="$(spec_file_of "$2")" || return 1
  [ "$a" = "$b" ]
}

# spec_before <patA> <patB> — exit 0 iff both resolve to the SAME file and A's
# line precedes B's. Fails LOUDLY (message on stderr, exit 2) on a cross-file
# pair rather than silently comparing meaningless line numbers.
spec_before() {
  local la lb fa fb na nb
  la="$(spec_line "$1")" || { echo "spec_before: anchor not found: $1" >&2; return 2; }
  lb="$(spec_line "$2")" || { echo "spec_before: anchor not found: $2" >&2; return 2; }
  fa="${la%:*}"; na="${la##*:}"
  fb="${lb%:*}"; nb="${lb##*:}"
  if [ "$fa" != "$fb" ]; then
    echo "spec_before: cross-file comparison is meaningless — '$1' is in $(basename "$fa") but '$2' is in $(basename "$fb"). Positionally-coupled prose must stay co-located." >&2
    return 2
  fi
  [ "$na" -lt "$nb" ]
}

# ---------------------------------------------------------------------------
# SOURCE-TIME FAIL-CLOSED GUARD (must stay at the bottom — it runs on `source`).
#
# Every helper above consumes `spec_files` from a subshell, so a missing spine
# yields an EMPTY list rather than an error. `spec_count` then returns 0, which
# turns every zero-count anti-regression assertion ("this superseded phrasing is
# gone") into a VACUOUS PASS — silently green for the wrong reason, the worst
# outcome for a guard whose job is catching silent regressions.
#
# This guard runs in the sourcing shell, so it can abort the run. It matches the
# repo's convention: tests/spec-inventory.sh exits 2 on a missing spine, and
# hooks/enforce-gates.sh blocks rather than allowing when it cannot verify.
# Test READABILITY and non-emptiness, not mere existence: a spine that exists but is
# unreadable (mode 000) or zero-byte passes an `-f` test while making every zero-count
# assertion pass vacuously — the same silent-green hole as a missing spine.
if [ ! -f "$SPEC_SPINE" ] || [ ! -r "$SPEC_SPINE" ] || [ ! -s "$SPEC_SPINE" ]; then
  echo "spec.sh: FATAL — spine at '$SPEC_SPINE' is missing, unreadable, or empty." >&2
  echo "  Refusing to continue: an empty spec file list makes zero-count assertions pass vacuously." >&2
  echo "  Set SPEC_ROOT (or SPEC_SPINE/SPEC_REFDIR) before sourcing tests/lib/spec.sh." >&2
  exit 2
fi
# The references dir is optional in principle, but if it is set to a path that exists and
# yet yields no .md files, the union silently narrows to the spine. Say so loudly.
# SPEC_REFDIR must EXIST and be a directory. Previously both this guard and spec_files
# gated on `[ -d ]`, so a typo or renamed references/ sourced cleanly and narrowed the
# union to the spine in silence — zero-count assertions then passed vacuously.
if [ ! -d "$SPEC_REFDIR" ]; then
  echo "spec.sh: FATAL — references dir '$SPEC_REFDIR' does not exist (or is not a directory)." >&2
  echo "  Refusing to continue: the spec union would silently narrow to the spine and zero-count assertions would pass vacuously." >&2
  exit 2
fi
if [ -z "$(_spec_ref_files | head -1)" ]; then
  echo "spec.sh: FATAL — '$SPEC_REFDIR' contains no *.md; the spec union would silently narrow to the spine." >&2
  exit 2
fi
# Validate EVERY reference file, not just the spine. `find -name '*.md'` happily lists an
# unreadable file (directory entries are readable), so the check above passes while
# `grep` on that file fails, is silenced by `2>/dev/null`, and contributes 0 matches —
# making a zero-count anti-regression assertion pass for the wrong reason. Rounds 1 and 2
# each closed one instance of this class (missing spine, unreadable spine); this is the
# third. Doing it here means all nine helpers inherit the guarantee.
if true; then
  while IFS= read -r _spec_ref; do
    [ -n "$_spec_ref" ] || continue
    if [ ! -f "$_spec_ref" ] || [ ! -r "$_spec_ref" ] || [ ! -s "$_spec_ref" ]; then
      echo "spec.sh: FATAL — reference '$_spec_ref' is not a readable, non-empty regular file." >&2
      echo "  Refusing to continue: grep would silently contribute 0 matches and zero-count assertions would pass vacuously." >&2
      exit 2
    fi
  done < <(_spec_ref_files)
  unset _spec_ref
fi
