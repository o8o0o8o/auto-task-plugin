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
# Usage:  checks.sh --base <sha>
# Output (one line): a JSON array of {name,category,result,detail}.

set -uo pipefail

base=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="${2:-}"; shift 2 || shift ;;
    *) shift ;;
  esac
done

# JSON-escape a detail string (no control chars, quotes, or backslashes leak).
jesc(){ printf '%s' "${1:-}" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'; }
row(){ printf '{"name":"%s","category":"%s","result":"%s","detail":"%s"}' "$1" "$2" "$3" "$(jesc "$4")"; }

emit_skip(){
  printf '[%s]\n' \
"$(row secret-scan security skip "$1"),$(row conflict-markers integrity skip "$1"),$(row debug-artifacts hygiene skip "$1"),$(row large-files size skip "$1"),$(row diff-size size skip "$1"),$(row tests-added tests skip "$1")"
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

SECRET_STRICT='AKIA[0-9A-Z]{16}|gh[opsur]_[A-Za-z0-9]{36}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
SECRET_GENERIC='(api[_-]?key|secret|password|passwd|token)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9_/+=-]{16,}["'"'"']'

# Scan one file's ADDED content (globals updated in place — not a subshell).
scan_content(){
  local f="$1" added="$2"
  is_test_path "$f" && tests_touched=1
  [ -n "$added" ] || return 0
  if printf '%s\n' "$added" | grep -Eq "$SECRET_STRICT" || printf '%s\n' "$added" | grep -Eiq "$SECRET_GENERIC"; then
    if is_test_path "$f"; then secret_warn=$((secret_warn+1)); else secret_fail=$((secret_fail+1)); fi
    secret_files="$secret_files $f"
  fi
  if printf '%s\n' "$added" | grep -Eq '^(<<<<<<<|>>>>>>>)'; then
    if is_test_path "$f"; then conflict_warn=$((conflict_warn+1)); else conflict_fail=$((conflict_fail+1)); fi
    conflict_files="$conflict_files $f"
  fi
  local dbg
  if is_test_path "$f"; then
    dbg='\.only\(|fdescribe\(|(^|[^A-Za-z])fit\('
  else
    dbg='console\.(log|debug|info|warn|error)\(|debugger|pdb\.set_trace\(|binding\.pry|\.only\(|fdescribe\('
  fi
  if printf '%s\n' "$added" | grep -Eq "$dbg"; then
    debug_warn=$((debug_warn+1)); debug_files="$debug_files $f"
  fi
}

# --- Tracked modifications (numstat gives add/del/binary + path) --------------
while IFS=$'\t' read -r a d p; do
  [ -n "${p:-}" ] || continue
  files_changed=$((files_changed+1))
  if [ "$a" = "-" ] || [ "$d" = "-" ]; then
    large_warn=$((large_warn+1)); large_files="$large_files ${p}(binary)"
    scan_content "$p" ""          # still record tests_touched via path
  else
    case "$a" in ''|*[!0-9]*) a=0 ;; esac
    case "$d" in ''|*[!0-9]*) d=0 ;; esac
    add_total=$((add_total + a)); del_total=$((del_total + d))
    [ "$a" -gt 800 ] && { large_warn=$((large_warn+1)); large_files="$large_files ${p}(+${a})"; }
    added="$(git diff "$base" -- "$p" 2>/dev/null | grep '^+' | grep -v '^+++' | sed 's/^+//' || true)"
    scan_content "$p" "$added"
  fi
done < <(git diff --numstat --no-renames "$base" 2>/dev/null || true)
# --no-renames: a rename+modify would otherwise emit a brace-form path
# (`dir/{old => new}`) that `git diff -- "$p"` can't resolve, silently skipping
# the secret/conflict/debug scan of the renamed file. --no-renames splits it into
# a plain delete + a plain add whose path resolves and gets scanned.

# --- Untracked new files (entire content is "added") --------------------------
while IFS= read -r p; do
  [ -n "$p" ] || continue
  [ -f "$p" ] || continue
  files_changed=$((files_changed+1))
  if ! grep -Iq . "$p" 2>/dev/null; then      # grep -I: binary file => no text match
    large_warn=$((large_warn+1)); large_files="$large_files ${p}(binary)"
    scan_content "$p" ""
  else
    c="$(grep -c '' "$p" 2>/dev/null || echo 0)"; case "$c" in ''|*[!0-9]*) c=0 ;; esac
    add_total=$((add_total + c))
    [ "$c" -gt 800 ] && { large_warn=$((large_warn+1)); large_files="$large_files ${p}(+${c})"; }
    scan_content "$p" "$(cat "$p" 2>/dev/null || true)"
  fi
done < <(git ls-files --others --exclude-standard 2>/dev/null || true)

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

r_size="$(row diff-size size info "$files_changed file(s), +${add_total}/-${del_total}")"

if [ "$tests_touched" -eq 1 ]; then r_tests="$(row tests-added tests pass "diff touches test file(s)")"
elif [ "$files_changed" -gt 0 ]; then r_tests="$(row tests-added tests warn "no test file touched by this diff")"
else r_tests="$(row tests-added tests info "no changes")"; fi

printf '[%s]\n' "$r_secret,$r_conflict,$r_debug,$r_large,$r_size,$r_tests"
exit 0
