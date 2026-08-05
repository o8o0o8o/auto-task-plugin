#!/usr/bin/env bash
# Focused test for hooks/intent-add-untracked.sh — making run-created files
# visible to `git diff <base>`.
#
# Asserts: the core premise (an untracked file is absent from the diff) and the
# fix; the Phase-5 HANDOVER DEADLOCK regression WITH A NEGATIVE CONTROL (the sha
# must diverge without the helper and match with it, or the test cannot fail);
# flag parity with the real enforce-gates.sh formula; no content staged;
# idempotency; ignored-path exclusion; --dry-run inertness; repo-wide scope from
# a subdirectory; paths with spaces and empty files; fail-open on a non-repo and
# a clean tree; and checks.sh counting a created file exactly once either side of
# the intent-add.
#
# Usage: tests/intent-add-untracked.test.sh   Exit 0 = all passed.

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
H="$HOOKS/intent-add-untracked.sh"
EG="$HOOKS/enforce-gates.sh"
CHECKS="$HOOKS/checks.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[ -f "$H" ] || { echo "FAIL: $H missing"; exit 1; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-56s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-56s got=%s want=%s\n' "$1" "$2" "$3"; fi; }

echo "================ intent-add-untracked.sh ================"

# The diff formula is not restated here: it is EXTRACTED from enforce-gates.sh, so
# a future edit to the hook's flags cannot silently desync this test from the
# hash the gate actually computes. A test that hard-coded the flags would keep
# passing while production deadlocked.
DIFF_FLAGS="$(sed -n "s/^DIFF_FLAGS='\(.*\)'$/\1/p" "$EG" | head -1)"
expect "diff flags extracted from enforce-gates.sh" \
  "$([ -n "$DIFF_FLAGS" ] && echo yes || echo no)" "yes"
expect "extracted flags include --no-renames" \
  "$(printf '%s' "$DIFF_FLAGS" | grep -c -- '--no-renames')" "1"

# --- fixture -----------------------------------------------------------------
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ORIG="$PWD"
B=""

# mkrepo MUST NOT be called in a command substitution: `$( )` runs a subshell, so
# its `cd` would be discarded and every scenario below would then run against the
# REAL repo — creating fixture files and even a commit in the developer's tree.
# That happened during development. Hence: the base SHA is returned via the global
# $B rather than stdout, and the scratch-dir guard below is a hard abort, not a
# warning. Never "fix" this by capturing the output.
mkrepo(){   # mkrepo <dir>  -> sets $B to the base SHA
  local d="$1"
  mkdir -p "$d"
  cd "$d" || { echo "FATAL: cannot cd $d"; exit 1; }
  case "$PWD" in
    "$T"/*) ;;
    *) echo "FATAL: refusing to build a fixture outside the scratch dir (PWD=$PWD)"; exit 1 ;;
  esac
  git init -q .
  git config --local user.email t@example.com
  git config --local user.name tester
  git config --local commit.gpgsign false
  echo base > tracked.txt; printf 'ignored.log\n' > .gitignore
  git add tracked.txt .gitignore
  git commit -qm base
  B="$(git rev-parse HEAD)"
}
sha_of(){ git diff $DIFF_FLAGS "$1" | git hash-object --stdin; }

# =============================================================================
# 1. Core premise + fix: a created file is invisible to the diff, then visible.
# =============================================================================
mkrepo "$T/core"
echo created > new.txt
expect "premise: created file is untracked" \
  "$(git ls-files -o --exclude-standard | grep -c '^new\.txt$')" "1"
expect "premise: created file ABSENT from git diff <base>" \
  "$(git diff --name-only "$B" | grep -c '^new\.txt$')" "0"
OUT="$(bash "$H")"
expect "helper emits valid JSON" "$(printf '%s' "$OUT" | jq empty >/dev/null 2>&1; echo $?)" "0"
expect "helper reports count=1"  "$(printf '%s' "$OUT" | jq -r .count)" "1"
expect "helper reports the path" "$(printf '%s' "$OUT" | jq -r '.added[0]')" "new.txt"
expect "helper reports no failures" "$(printf '%s' "$OUT" | jq -r '.failed | length')" "0"
expect "fix: created file PRESENT in git diff <base>" \
  "$(git diff --name-only "$B" | grep -c '^new\.txt$')" "1"
expect "fix: file left the untracked set" \
  "$(git ls-files -o --exclude-standard | grep -c '^new\.txt$')" "0"

# =============================================================================
# 2. THE DEADLOCK REGRESSION, with a negative control.
#    Phase 4 pins reviewed_diff_sha; Phase 5 stages; enforce-gates.sh compares.
# =============================================================================
# --- negative control: WITHOUT the helper the sha must DIVERGE ---------------
mkrepo "$T/deadlock-control"
echo created > new.txt                  # a file the run creates in Phase 2
PINNED="$(sha_of "$B")"                 # Phase 4 pins the sha (file invisible)
git add -A                              # Phase 5 stages the planned files
AT_COMMIT="$(sha_of "$B")"              # enforce-gates.sh recomputes
expect "negative control: sha DIVERGES without the helper" \
  "$([ "$PINNED" != "$AT_COMMIT" ] && echo diverged || echo matched)" "diverged"
expect "negative control: that divergence is what blocks the commit" \
  "$([ "$PINNED" = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391" ] && echo empty-hash || echo other)" \
  "empty-hash"

# --- with the helper the sha must MATCH -------------------------------------
mkrepo "$T/deadlock-fixed"
echo created > new.txt
bash "$H" >/dev/null                    # Phase 3 entry — the mandated call
PINNED="$(sha_of "$B")"                 # Phase 4 pins the sha (file now visible)
git add -A                              # Phase 5 stages
AT_COMMIT="$(sha_of "$B")"
expect "deadlock closed: sha MATCHES across staging" \
  "$([ "$PINNED" = "$AT_COMMIT" ] && echo matched || echo diverged)" "matched"
expect "deadlock closed: the pinned sha is not the empty hash" \
  "$([ "$PINNED" != "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391" ] && echo real || echo empty)" "real"

# =============================================================================
# 3. Stages no content; commit finds nothing staged; idempotent.
# =============================================================================
mkrepo "$T/nocontent"
echo created > new.txt
bash "$H" >/dev/null
expect "git diff --cached is EMPTY (no content staged)" \
  "$(git diff --cached --name-only | grep -c .)" "0"
expect "intent-added entry points at the empty blob" \
  "$(git ls-files -s -- new.txt | awk '{print $2}')" "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
git commit -qm should-be-empty >/dev/null 2>&1
expect "git commit finds nothing staged (HEAD unmoved)" \
  "$(git rev-parse HEAD)" "$B"
OUT2="$(bash "$H")"
expect "idempotent: second run adds nothing" "$(printf '%s' "$OUT2" | jq -r .count)" "0"
expect "idempotent: file still in the diff" \
  "$(git diff --name-only "$B" | grep -c '^new\.txt$')" "1"

# =============================================================================
# 4. Ignored paths are never touched (.gitignore AND the per-clone exclude).
# =============================================================================
mkrepo "$T/ignored"
echo secret > ignored.log                       # matched by .gitignore
mkdir -p .auto-task/branch; echo s > .auto-task/branch/STATE.json
mkdir -p .claude/worktrees/x; echo w > .claude/worktrees/x/f
printf '.auto-task/\n.claude/worktrees/\n' >> "$(git rev-parse --git-common-dir)/info/exclude"
echo real > real.txt
OUT="$(bash "$H")"
expect "ignored: only the non-ignored path added"    "$(printf '%s' "$OUT" | jq -r .count)" "1"
expect "ignored: .gitignore path not added"          "$(printf '%s' "$OUT" | jq -r '.added|index("ignored.log")')" "null"
expect "ignored: .auto-task/ not in the diff" \
  "$(git diff --name-only "$B" | grep -c '^\.auto-task/')" "0"
expect "ignored: .claude/worktrees/ not in the diff" \
  "$(git diff --name-only "$B" | grep -c '^\.claude/worktrees/')" "0"

# =============================================================================
# 5. --dry-run reports but never mutates.
# =============================================================================
mkrepo "$T/dryrun"
echo created > new.txt
OUT="$(bash "$H" --dry-run)"
expect "dry-run: reports the path"        "$(printf '%s' "$OUT" | jq -r .count)" "1"
expect "dry-run: note says dry-run"       "$(printf '%s' "$OUT" | jq -r .note | grep -c '^dry-run')" "1"
expect "dry-run: file STILL untracked"    "$(git ls-files -o --exclude-standard | grep -c '^new\.txt$')" "1"
expect "dry-run: file STILL absent from the diff" \
  "$(git diff --name-only "$B" | grep -c '^new\.txt$')" "0"

# =============================================================================
# 6. Repo-wide scope from a subdirectory + spaces in paths + empty files.
# =============================================================================
mkrepo "$T/scope"
mkdir -p deep/nested; echo top > top.txt; echo deep > "deep/nested/a file.txt"; : > deep/empty.txt
cd deep/nested || exit 1
OUT="$(bash "$H")"                       # invoked from a subdirectory
cd "$T/scope" || exit 1
expect "subdir: all 3 repo-wide paths added" "$(printf '%s' "$OUT" | jq -r .count)" "3"
expect "subdir: sibling path outside cwd added" \
  "$(git diff --name-only "$B" | grep -c '^top\.txt$')" "1"
expect "spaces: path with a space added"     "$(git diff --name-only "$B" | grep -c 'a file\.txt$')" "1"
expect "spaces: JSON keeps the space intact" \
  "$(printf '%s' "$OUT" | jq -r '.added[]' | grep -c '^deep/nested/a file\.txt$')" "1"
expect "empty file: degenerate case still enters the diff" \
  "$(git diff --name-only "$B" | grep -c '^deep/empty\.txt$')" "1"

# =============================================================================
# 7. Fail-open: non-repo, clean tree, absent-but-harmless conditions.
# =============================================================================
mkdir -p "$T/notarepo"; cd "$T/notarepo" || exit 1
OUT="$(bash "$H")"; RC=$?
expect "fail-open: non-repo exits 0"          "$RC" "0"
expect "fail-open: non-repo emits valid JSON" "$(printf '%s' "$OUT" | jq empty >/dev/null 2>&1; echo $?)" "0"
expect "fail-open: non-repo count=0"          "$(printf '%s' "$OUT" | jq -r .count)" "0"
expect "fail-open: non-repo note explains"    "$(printf '%s' "$OUT" | jq -r .note | grep -c 'not a git repository')" "1"

mkrepo "$T/clean"
OUT="$(bash "$H")"; RC=$?
expect "fail-open: clean tree exits 0"        "$RC" "0"
expect "fail-open: clean tree count=0"        "$(printf '%s' "$OUT" | jq -r .count)" "0"
expect "fail-open: clean tree note explains"  "$(printf '%s' "$OUT" | jq -r .note | grep -c 'nothing to do')" "1"

# =============================================================================
# 8. checks.sh parity — the created file migrates between checks.sh's two scan
#    sets (untracked -> tracked diff) and must be counted exactly once either
#    side, with its content still scanned for secrets.
# =============================================================================
if [ -f "$CHECKS" ]; then
  mkrepo "$T/checks"
  printf 'aws_secret_access_key = "AKIAIOSFODNN7EXAMPLE0000"\n' > leak.py
  BEFORE="$(bash "$CHECKS" --base "$B" 2>/dev/null || true)"
  bash "$H" >/dev/null
  AFTER="$(bash "$CHECKS" --base "$B" 2>/dev/null || true)"
  n_before="$(printf '%s' "$BEFORE" | jq -r '[.[]|select(.name=="diff-size")]|.[0].detail' | grep -oE '^[0-9]+' | head -1)"
  n_after="$(printf '%s' "$AFTER"  | jq -r '[.[]|select(.name=="diff-size")]|.[0].detail' | grep -oE '^[0-9]+' | head -1)"
  expect "checks.sh: files-changed identical either side of intent-add" \
    "$n_before" "$n_after"
  expect "checks.sh: file counted exactly once after intent-add" "$n_after" "1"
  expect "checks.sh: secret still detected BEFORE intent-add" \
    "$(printf '%s' "$BEFORE" | jq -r '[.[]|select(.name=="secret-scan")]|.[0].result')" "fail"
  expect "checks.sh: secret still detected AFTER intent-add" \
    "$(printf '%s' "$AFTER"  | jq -r '[.[]|select(.name=="secret-scan")]|.[0].result')" "fail"
else
  echo "  SKIP  checks.sh not present — parity scenario skipped"
fi

# =============================================================================
# 9. --undo: the Phase-5 step-7 release. GATE B BLOCKER REGRESSION.
#    An intent-added path the commit did not take makes git call it "not
#    uptodate", so the main-sync merge REFUSES (exit 128). This is the F1
#    deadlock traded for a different one, so it carries a negative control too.
# =============================================================================
mkrepo "$T/undo"
# Do NOT hardcode "main": mkrepo uses a plain `git init`, so the initial branch
# is whatever init.defaultBranch says on the host. Ask git what it actually is.
RUNBR="$(git rev-parse --abbrev-ref HEAD)"
: > tracked-empty.txt                       # a genuinely-empty file, COMMITTED
git add tracked-empty.txt; git commit -qm "a real empty file"
git branch main-remote                      # stand-in for origin/<default>
git checkout -q main-remote; echo adv > upstream.txt
git add upstream.txt; git commit -qm "main advances during the run"
git checkout -q "$RUNBR"
echo authored > tracked.txt; git add tracked.txt; git commit -qm "step-6 authored commit"
echo wip > "user wip.txt"                   # user's WIP — step 5 does NOT stage it
: > run-scratch-empty.txt                   # a run scratch file, also unstaged
bash "$H" >/dev/null                        # Phase-3 entry sweep

# --- negative control: WITHOUT --undo the merge must REFUSE -----------------
git merge --no-edit main-remote >/dev/null 2>&1
expect "undo negative control: merge REFUSES while intent-adds are held" "$?" "128"
git merge --abort >/dev/null 2>&1 || true

OUT="$(bash "$H" --undo)"
expect "undo: releases both unstaged intent-adds"  "$(printf '%s' "$OUT" | jq -r .count)" "2"
expect "undo: reports no failures"                 "$(printf '%s' "$OUT" | jq -r '.failed|length')" "0"
expect "undo: merge now SUCCEEDS" \
  "$(git merge --no-edit main-remote >/dev/null 2>&1; echo $?)" "0"

# The false positive this detection must never make: a genuinely-empty file that
# the run COMMITTED shares the empty blob with an intent-added entry. Absence
# from HEAD is what separates them.
expect "undo: committed empty file left TRACKED" \
  "$(git ls-files -- tracked-empty.txt | grep -c .)" "1"
expect "undo: committed non-empty file left tracked" \
  "$(git ls-files -- tracked.txt | grep -c .)" "1"
expect "undo: user WIP content preserved byte-for-byte" "$(cat 'user wip.txt')" "wip"
expect "undo: user WIP back in the untracked set" \
  "$(git ls-files -o --exclude-standard -- 'user wip.txt' | grep -c .)" "1"
expect "undo: run scratch file back in the untracked set" \
  "$(git ls-files -o --exclude-standard -- run-scratch-empty.txt | grep -c .)" "1"
OUT="$(bash "$H" --undo)"
expect "undo: idempotent (second call is a no-op)" "$(printf '%s' "$OUT" | jq -r .count)" "0"
expect "undo: no-op note explains"  "$(printf '%s' "$OUT" | jq -r .note | grep -c 'nothing to undo')" "1"
expect "undo: fail-open outside a repo" \
  "$(cd "$T/notarepo" && bash "$H" --undo >/dev/null 2>&1; echo $?)" "0"

# =============================================================================
# 10. BASELINE EXCLUSION — the sweep must never touch a file the run did not
#     create. GATE B PASS-2 REGRESSION (data loss on a user's own WIP).
#     Measured: intent-adding a plain untracked file makes `git restore .` and
#     `git checkout -- .` truncate it to 0 bytes and a hard reset remove it,
#     where the same commands leave an untracked file untouched.
# =============================================================================
mkrepo "$T/baseline"
BR_DIR=".auto-task/$(git rev-parse --abbrev-ref HEAD)"
mkdir -p "$BR_DIR"
# Branch setup excludes .auto-task/ per-clone before pinning the baseline; without
# this the baseline file lists ITSELF and the scenario silently tests the wrong thing.
printf '.auto-task/\n' >> "$(git rev-parse --git-common-dir)/info/exclude"
printf 'USER PRECIOUS WIP\n' > "user wip.txt"     # pre-existing, NOT the run's
printf 'meta\n'             > pre-existing2.txt
# Phase-1 branch setup pins the baseline BEFORE the run touches anything.
git ls-files --others --exclude-standard -z > "$BR_DIR/untracked-baseline"
echo run-created > run-made.txt                   # created AFTER the baseline

OUT="$(bash "$H")"
expect "baseline: only the run-created path intent-added" \
  "$(printf '%s' "$OUT" | jq -r .count)" "1"
expect "baseline: that path is the run's"          "$(printf '%s' "$OUT" | jq -r '.added[0]')" "run-made.txt"
expect "baseline: note reports the skips"          "$(printf '%s' "$OUT" | jq -r .note | grep -c 'skipped 2 pre-existing')" "1"
expect "baseline: user WIP still untracked" \
  "$(git ls-files -o --exclude-standard -- 'user wip.txt' | grep -c .)" "1"
expect "baseline: user WIP NOT in the index" \
  "$(git ls-files -- 'user wip.txt' | grep -c .)" "0"
expect "baseline: run-created path IS in the diff" \
  "$(git diff --name-only "$B" | grep -c '^run-made\.txt$')" "1"

# The data-loss assertion: the destructive commands must leave the user's file alone.
git checkout -- . 2>/dev/null || true
git restore . 2>/dev/null || true
expect "baseline: user WIP survives 'git restore .' / 'git checkout -- .' intact" \
  "$(cat 'user wip.txt' 2>/dev/null)" "USER PRECIOUS WIP"
expect "baseline: user WIP still non-empty afterwards" \
  "$([ -s 'user wip.txt' ] && echo yes || echo no)" "yes"

# Fail-open: no baseline file at all -> old repo-wide behaviour, nothing crashes.
mkrepo "$T/nobaseline"
printf 'wip\n' > stray.txt
OUT="$(bash "$H")"
expect "baseline: absent file fails open to repo-wide" "$(printf '%s' "$OUT" | jq -r .count)" "1"
expect "baseline: absent file mentions no skips"       "$(printf '%s' "$OUT" | jq -r .note | grep -c 'skipped')" "0"

cd "$ORIG" || true
echo
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
