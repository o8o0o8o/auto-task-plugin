#!/usr/bin/env bash
# review-highlights.sh — diff-side candidates for the PR body's "Review this first".
#
# NOT a hook. A pure reader (invoked by the auto-task orchestrator at Phase 5
# step 2b) that reads a run's diff and reports the small set of places a human
# reviewer should look at BEFORE reading the rest of the diff.
#
# ─────────────────────────────────────────────────────────────────────────────
# PATH-EMITTING CONTRACT (load-bearing — read before reusing anything here)
#
# This helper DELIBERATELY EMITS PATHS, file names and line numbers. That is its
# entire product: a reviewer instruction is worthless without the coordinate it
# points at.
#
# It is therefore the EXACT INVERSE of `hooks/repo-metrics.sh`, whose header
# states an anonymity contract — that helper must never emit a path, file name or
# module name, because its output is merged into the remote telemetry payload by
# `hooks/send-telemetry.sh`.
#
# The two must NOT share code, and this helper's output must NEVER be routed into
# a telemetry sink. Sharing a function between them is how a path ends up in an
# anonymous payload. The signals `repo-metrics.sh` computes (its change-heat
# ratios and its most-changed-file concentration) are also deliberately NOT
# recomputed here: this helper reports only what the diff itself shows, never a
# statistic about a file's history. See the plan's "combed list" rationale.
# ─────────────────────────────────────────────────────────────────────────────
#
# Three detectors, each chosen for low false-positive rate over breadth:
#
#   weakened-check  A guard / validation / assertion line was REMOVED, a test file
#                   was deleted, a skip marker was ADDED, or an error is swallowed
#                   by an empty catch. Near-zero false positives: a removed line
#                   matching `if (!x) throw` either is a removed guard or is not.
#   contract        The change touches a public surface whose blast radius is
#                   invisible in the diff: a migration / schema / IDL file, an
#                   exported declaration's signature line, or package.json
#                   `exports` / `bin`.
#   untested        A logic file changed with no co-changed test that names it.
#
# Deliberately ABSENT (decided when the detector list was combed): any signal
# derived from a file's commit history rather than from this diff, structural
# complexity scoring, module fan-in, sibling call sites, concurrency keyword
# matching, a security-surface keyword list, and generated-file marking.
#
# A fourth detector — "the run fought here" — is NOT implemented here. It reads
# STATE.json (`gates.code_review.rounds[].files`,
# `gates.gate_b.passes[].fixed_lines[].path`, `gates.code_review.deferred[].location`)
# and belongs to the orchestrator, which already holds that state.
#
# Output JSON, and the TWO shapes callers must distinguish:
#   success  {"candidates":[{detector,path,line,evidence}, ...]}   (possibly empty)
#   failure  {}                                                     (no key at all)
# An empty `candidates` array means "the diff is clean"; `{}` means "this helper
# could not run". They are different facts and the caller must not conflate them.
# Probe with `jq -e 'has("candidates")'` FIRST — note that `jq '.candidates|length'`
# ERRORS on `{}`, so probing by length cannot tell the two apart.
#
# `line` coordinates — three cases, and the rule behind all three is that a
# FABRICATED coordinate is worse than none, because it sends the reviewer somewhere
# arbitrary:
#   added line    cites its line number in the new file.
#   removed line  cites the PRE-IMAGE coordinate, and `evidence` is suffixed
#                 `(removed)` so the caller can mark it — a post-image number never
#                 held the removed code.
#   whole file    `line` is **null**. A deleted test or a migration is a finding
#                 ABOUT THE FILE; there is no line to point at, so none is invented.
#                 The caller renders these as `path — …`, dropping the `:line` half.
#
# Ranking and the 3-5 item cap are the CALLER's job, not this helper's: the PR
# line must read as an instruction, which is prose, and every sibling helper
# (`estimate.sh`, `repo-metrics.sh`, `requirements-coverage.sh`) likewise emits
# data and never prose. This helper emits every candidate it finds.
#
# Failure policy: FAIL OPEN. Non-repo, bad base, absent jq/git, or any internal
# error prints `{}` and exits 0. It never blocks, never errors the caller.
#
# Usage: review-highlights.sh --repo <dir> --base <sha>

set -uo pipefail

emit_empty(){ printf '{}\n'; exit 0; }

repo=""; base=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 || emit_empty ;;
    --base) base="${2:-}"; shift 2 || emit_empty ;;
    *) shift ;;
  esac
done

command -v jq  >/dev/null 2>&1 || emit_empty
command -v git >/dev/null 2>&1 || emit_empty
[ -n "$repo" ] && [ -d "$repo" ] || emit_empty
[ -n "$base" ] || emit_empty
git -C "$repo" rev-parse --git-dir  >/dev/null 2>&1 || emit_empty
git -C "$repo" rev-parse -q --verify "$base" >/dev/null 2>&1 || emit_empty

# --- classification helpers ---------------------------------------------------
# A path is a test when a conventional test marker appears at a NAME BOUNDARY —
# a test directory component, or a `.test.` / `.spec.` / `_test` / `test_` affix on
# the filename. Deliberately NOT a bare `*test*` substring: that classifies
# `src/latest.js` (l-a-**test**) as a test file, which both suppresses a real
# `untested` finding and lets an unrelated file satisfy another file's coverage.
is_test_path(){
  case "$1" in
    */tests/*|tests/*|*/test/*|test/*|*/spec/*|spec/*|*/__tests__/*|__tests__/*) return 0 ;;
  esac
  b="$(basename "$1")"
  case "$b" in
    *.test.*|*.spec.*|*_test.*|*_spec.*|test_*|spec_*|*Test.*|*Tests.*|*Spec.*) return 0 ;;
    *) return 1 ;;
  esac
}

# The subject a test file covers: its basename with the test affixes and extension
# stripped (`thing.test.js` -> `thing`, `test_thing.py` -> `thing`, `thing_test.go`
# -> `thing`). Comparing STEMS for equality is what makes coverage matching precise;
# a substring test lets a short stem like `a` be "covered" by any test path
# containing that letter.
test_subject(){
  b="$(basename "$1")"; b="${b%.*}"
  b="${b%.test}"; b="${b%.spec}"; b="${b%_test}"; b="${b%_spec}"
  b="${b#test_}"; b="${b#spec_}"
  b="${b%Test}"; b="${b%Tests}"; b="${b%Spec}"
  printf '%s' "$b"
}

# A path is "logic" when its extension is a programming language we can reason
# about. Docs, config, data and lockfiles are excluded on purpose: an untested
# markdown edit is not a finding.
is_logic_path(){
  case "$1" in
    *.js|*.jsx|*.mjs|*.cjs|*.ts|*.tsx|*.py|*.go|*.rs|*.java|*.kt|*.rb|*.php) return 0 ;;
    *.c|*.h|*.cc|*.cpp|*.cxx|*.hpp|*.sh|*.bash|*.swift|*.scala|*.cs) return 0 ;;
    *) return 1 ;;
  esac
}

# A path whose blast radius is invisible in the diff itself.
is_contract_path(){
  case "$1" in
    *migrations/*|*migrate/*|*/migration/*) return 0 ;;
    *openapi*|*swagger*|*.proto|*schema.graphql|*.graphql|*schema.sql) return 0 ;;
    *) return 1 ;;
  esac
}

# --- pinned git invocation (load-bearing — do not simplify) -------------------
# Both `git diff` calls below are pinned against ambient config drift, the same
# way `state-schema.md` pins the `reviewed_diff_sha` formula and for the same
# reason. Measured failures without these flags:
#   color.ui=always        every line gains an ESC[..m prefix, so `/^diff --git /`,
#                          `/^\+\+\+ /` and `/^[-+]/` ALL stop matching. The helper
#                          then emits `{"candidates":[]}` — the SUCCESS shape — so a
#                          removed guard is silently reported as a clean diff. That
#                          is the worst possible failure for this helper: a false
#                          negative wearing the success shape.
#   diff.mnemonicPrefix    prefixes become `i/`,`w/`,`c/` instead of `a/`,`b/`, so
#                          the prefix strip no-ops and a `w/src/x.js` path is emitted.
#   core.quotePath=true    (the DEFAULT) a non-ASCII path is emitted as
#                          `"b/src/caf\303\251.js"` — quotes and octal escapes and
#                          all — which defeats the prefix strip and the extension
#                          tests downstream.
GIT_PIN="-c core.quotePath=false"
DIFF_PIN="--no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/"

# shellcheck disable=SC2086
changed="$(git -C "$repo" $GIT_PIN diff --name-status $DIFF_PIN "$base" 2>/dev/null)" || emit_empty

[ -n "$changed" ] || { printf '{"candidates":[]}\n'; exit 0; }

tsv=""
add(){ tsv="${tsv}${1}	${2}	${3}	${4}
"; }

# --- detector: contract + weakened-check (deleted tests) — path level ---------
while IFS='	' read -r status path rest; do
  [ -n "${path:-}" ] || continue
  case "$status" in
    R*) path="${rest:-$path}" ;;
  esac
  # `-` means "no meaningful coordinate" (see the `line` contract in the header):
  # a whole-file candidate is about the FILE, so pinning it to line 1 would send a
  # reviewer somewhere arbitrary — the same failure the /dev/null fallback avoids.
  if is_contract_path "$path"; then
    add "contract" "$path" "-" "public surface: migration/schema/IDL file"
  fi
  case "$status" in
    D*) if is_test_path "$path"; then
          add "weakened-check" "$path" "-" "test file deleted (removed)"
        fi ;;
  esac
done <<CHANGED
$changed
CHANGED

# --- line-level detectors -----------------------------------------------------
# `-U0` so only genuinely changed lines are inspected; context lines would
# otherwise be attributed to the change that merely sits near them.
#
# Two subtleties the awk below handles deliberately:
#
#  (a) `+++ `/`--- ` are ONLY file headers at the top of a file section. A CONTENT
#      line reading `++ x` is emitted by diff as `+++ x`, and one reading `-- x` as
#      `--- x` — indistinguishable by prefix alone. Matching on the prefix therefore
#      re-points the current path at a bogus value (or silently drops the line) for
#      the rest of the hunk. Diff fixtures inside test files are the natural trigger,
#      and this repo has several. So headers are recognised only in the `hdr` state,
#      which `diff --git` opens and the `+++` line closes.
#  (b) A whole-file DELETE has `+++ /dev/null`, so taking the path from the `+++`
#      header attributes every removed line to `/dev/null`. The `--- a/<path>`
#      pre-image header carries the real name; keep it and fall back to it.
# Classification happens INSIDE this awk, not in a shell loop over its output. The
# shell version spawned a `sed` plus up to four `printf | grep` pairs PER CHANGED
# LINE — measured at ~8.3 ms/line, so a 3,000-line diff cost 25 s and a 10k-line one
# would stall handover for ~85 s. Phase 5 runs this on every run and has no timeout,
# and the single-commit rule explicitly contemplates very large diffs. One awk pass
# is O(1) processes regardless of diff size.
#
# Two false-positive guards, unchanged in behaviour from the shell version:
# a commented-out line is not live code; and `catch {}` / an exported signature
# inside a TEST file is almost always fixture text, not production code (observed
# live — this helper's own test file writes a `catch (e) {}` inside a printf string).
# The skip-marker check is deliberately NOT scoped that way: test paths are the only
# place it means anything.
# shellcheck disable=SC2086
line_rows="$(git -C "$repo" $GIT_PIN diff -U0 $DIFF_PIN "$base" 2>/dev/null | awk '
  function is_test(p,   b) {
    if (p ~ /(^|\/)(tests|test|spec|__tests__)\//) return 1
    b = p; sub(/.*\//, "", b)
    if (b ~ /\.(test|spec)\./)  return 1
    if (b ~ /_(test|spec)\./)   return 1
    if (b ~ /^(test|spec)_/)    return 1
    if (b ~ /(Test|Tests|Spec)\./) return 1
    return 0
  }
  # The line-level detectors look for CODE constructs, so they must only run on
  # code. Without this, prose matches them: this helper run against its own diff
  # flagged `README.md` as a removed guard, because the sentence "everything not
  # named stays under guard." matches the guard/assertion pattern. Markdown cannot
  # contain a removed null-check, an added skip marker, or an exported signature.
  # Mirrors the shell `is_logic_path`, which until now gated only `untested`.
  function is_logic(p,   e) {
    if (p !~ /\./) return 0
    e = p; sub(/.*\./, "", e)
    return (e ~ /^(js|jsx|mjs|cjs|ts|tsx|py|go|rs|java|kt|rb|php)$/ \
         || e ~ /^(c|h|cc|cpp|cxx|hpp|sh|bash|swift|scala|cs)$/)
  }
  function emit(det, ln, ev) { print det "\t" f "\t" ln "\t" ev }
  /^diff --git /{ hdr=1; f=""; of=""; next }
  # Take the path by OFFSET, never by field. `$2` is whitespace-split, so
  # `+++ b/src/my file.js` yielded `src/my` — a path that does not exist, emitted
  # to a reviewer as a coordinate. `--- a/` and `+++ b/` are both exactly 6 chars
  # (the prefixes are pinned above, so this offset cannot drift). git also appends
  # a trailing tab to `--- a/<path>` when the name contains a space; strip it.
  hdr && /^--- /{
    of = ($0 == "--- /dev/null") ? "/dev/null" : substr($0,7)
    sub(/\t.*$/,"",of); next
  }
  hdr && /^\+\+\+ /{
    f = ($0 == "+++ /dev/null") ? "/dev/null" : substr($0,7)
    sub(/\t.*$/,"",f)
    if (f == "/dev/null" && of != "" && of != "/dev/null") f=of
    hdr=0; intest=is_test(f); islogic=is_logic(f); next
  }
  /^@@ /{
    match($0, /-[0-9]+/); ol = substr($0, RSTART+1, RLENGTH-1)+0
    match($0, /\+[0-9]+/); nl = substr($0, RSTART+1, RLENGTH-1)+0
    next
  }
  f == "" { next }
  /^[-+]/{
    minus = (substr($0,1,1) == "-")
    c = substr($0,2)
    ln = minus ? ol : nl
    if (minus) ol++; else nl++
    # `#` is a comment sigil (shell, Python, Ruby) EXCEPT in `#[...]`, which is a
    # Rust attribute — and `#[ignore]` is one of the skip markers below. Treating a
    # bare `#` as always-comment made that alternative unreachable: the guard
    # consumed the line before the marker check ever ran, so the helper advertised
    # Rust skip detection and silently had none. `#` still comments when followed by
    # anything else, or when it is the whole line.
    if (c ~ /^[[:space:]]*(#($|[^[])|\/\/|\*|\/\*)/) next
    # The four CODE detectors below run only on code. The package.json check after
    # them is deliberately OUTSIDE this guard: `.json` is not a logic extension, so
    # gating the whole block would have silently killed the entry-point detector.
    if (islogic) {
    if (minus) {
      if (c ~ /(^|[^A-Za-z_])(if|unless)([^A-Za-z_]).*(throw|return|raise|panic|abort|exit|reject)/ \
       || c ~ /(^|[^A-Za-z_])(assert|invariant|precondition|require|guard|validate)([^A-Za-z_]|$)/)
        emit("weakened-check", ln, "guard or assertion removed here (removed)")
    } else {
      if (c ~ /(\.skip\(|\.only\(|(^|[^A-Za-z_])xit\(|(^|[^A-Za-z_])xdescribe\(|@pytest\.mark\.skip|t\.Skip\(|#\[ignore\])/)
        emit("weakened-check", ln, "test skip marker added here")
      if (!intest && c ~ /(catch[^{]*\{[[:space:]]*\}|except[^:]*:[[:space:]]*pass[[:space:]]*$)/)
        emit("weakened-check", ln, "error swallowed by an empty handler here")
      if (!intest && c ~ /^[[:space:]]*(export[[:space:]]+(default[[:space:]]+)?(function|const|class|interface|type|enum|async)|pub[[:space:]]+(fn|struct|enum|trait)|func[[:space:]]+[A-Z])/)
        emit("contract", ln, "exported declaration signature changed here")
    }
    }
    if (f ~ /package\.json$/ && c ~ /"(exports|bin|main|types)"[[:space:]]*:/)
      emit("contract", ln, "package entry point changed here" (minus ? " (removed)" : ""))
    next
  }
' 2>/dev/null)" || line_rows=""

if [ -n "$line_rows" ]; then tsv="${tsv}${line_rows}
"; fi

# --- detector: untested -------------------------------------------------------
# A logic file is flagged when NO changed test file has it as its SUBJECT. Stem
# equality (not substring containment) is the convention every ecosystem here
# follows — foo.ts -> foo.test.ts, foo_test.go, test_foo.py — and it keeps a large
# diff that does carry tests from flagging every file in it.
test_subjects="$(printf '%s\n' "$changed" | awk -F'\t' '{print $2}' | while IFS= read -r p; do
  [ -n "${p:-}" ] || continue
  if is_test_path "$p"; then test_subject "$p"; printf '\n'; fi
done)"

while IFS='	' read -r status path rest; do
  [ -n "${path:-}" ] || continue
  case "$status" in
    R*) path="${rest:-$path}" ;;
    D*) continue ;;
  esac
  is_logic_path "$path" || continue
  is_test_path  "$path" && continue
  stem="$(basename "$path")"; stem="${stem%.*}"
  [ -n "$stem" ] || continue
  if ! printf '%s\n' "$test_subjects" | grep -qxF -- "$stem"; then
    # `-` (no coordinate), like the other two whole-file emitters: "this file has
    # no co-changed test" implicates the FILE, not a line. Emitting 1 here sent the
    # reviewer to the top of the file — and this is the most frequently-firing
    # detector, so it was the common case, not a corner.
    add "untested" "$path" "-" "logic changed with no co-changed test naming it"
  fi
done <<CHANGED2
$changed
CHANGED2

# --- emit ---------------------------------------------------------------------
if [ -z "$tsv" ]; then printf '{"candidates":[]}\n'; exit 0; fi

out="$(printf '%s' "$tsv" | jq -R -s -c '
  { candidates: (
      split("\n")
      | map(select(length > 0))
      | map(split("\t"))
      | map(select(length >= 4))
      | map({ detector: .[0], path: .[1],
              line: (if .[2] == "-" then null else (.[2] | tonumber? // null) end),
              evidence: .[3] })
      | unique
    ) }
' 2>/dev/null || true)"

[ -n "$out" ] || emit_empty
printf '%s' "$out" | jq empty 2>/dev/null || emit_empty
printf '%s\n' "$out"
exit 0
