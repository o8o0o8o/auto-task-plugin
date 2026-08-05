#!/usr/bin/env bash
# intent-add-untracked.sh — make run-created files visible to `git diff <base>`.
#
# NOT a hook. A pure, deterministic helper (invoked by the auto-task orchestrator
# on entry to Phase 3 self-verify, and before any recomputation of a diff-pinned
# gate hash) that intent-to-adds every untracked, non-ignored path in the repo.
#
# WHY: every verification input in the pipeline is specified against
# `git diff <base>`, and nothing is staged or committed until Phase 5. A file
# created during the run therefore stays UNTRACKED and is invisible to Phase 4
# review, Gate A, Gate B, and the `gates.code_review.reviewed_diff_sha` /
# `gates.gate_b.verified_diff_sha` pins. Worse than the review blind spot: Phase 5
# staging pulls the file INTO that diff, so the hash moves after it was pinned and
# `enforce-gates.sh` hard-blocks the handover commit. The run deadlocks.
#
# `git add -N` (intent-to-add) points the index entry at the empty blob, so the
# path enters `git diff` while `git diff --cached` stays empty and `git commit`
# still finds nothing staged. Phase 5's "planned files only" staging therefore
# remains the sole decider of what actually lands. This is the mechanism the repo
# already chose for this problem at the two optional steps (phase-5-handover.md,
# phase-9-release.md, auto-task-docs/SKILL.md); this applies it at the root.
#
# SCOPE: repo-wide (resolves the toplevel, so it is correct from a subdirectory).
# `--exclude-standard` honours .gitignore AND the per-clone exclude file, so
# `.auto-task/` and `.claude/worktrees/` are skipped without a hand-maintained list.
#
# BASELINE EXCLUSION — the sweep touches only files THIS RUN created.
# `.auto-task/<branch>/untracked-baseline` (written at Phase-1 branch setup) lists
# the paths that were ALREADY untracked when the run began. Every path in it is
# skipped. On the normal path the file is EMPTY, because a run gets a fresh
# worktree cut from the default branch and a fresh worktree is clean — so for
# almost every run this changes nothing. It matters on the two paths that carry a
# user's pre-existing WIP into the run's tree (the already-in-a-worktree path and
# the in-place fallback), where phase-1-preamble.md's "Pre-existing staged/unstaged
# changes" rule forbids `git add` on that WIP.
#
# This exclusion exists because intent-adding a file the user owns is genuinely
# destructive, not merely untidy. Measured, on a plain untracked file:
#   - untouched by `git restore .` / `git checkout -- .` while it is untracked;
#   - TRUNCATED TO 0 BYTES by either command once it is intent-added (git restores
#     it from the empty blob), and REMOVED OUTRIGHT by a hard reset.
# So the sweep must never reach a file the run did not create. A missing baseline
# file fails open to the old repo-wide behaviour.
#
# One consequence remains for the run's OWN strays and is handled by `--undo`, not
# by this exclusion: an intent-added entry makes a path "not uptodate" for git, so
# a later `git merge` REFUSES outright — "error: Entry 'X' not uptodate. Cannot
# merge." (exit 128; the same merge exits 0 once released). That is Phase 5 step
# 7's main-sync merge.
#
# SELF-VERIFYING: a path is reported in `added` only after a re-query proves it
# left the untracked set — never on the strength of `git add`'s exit code. Same
# verify-then-claim convention as record-outcome.sh's post-append landing check.
#
# FAIL-OPEN: always exits 0. Outside a git repo, with git absent, or on a path
# git refuses, it reports the fact and returns rather than breaking the run.
#
# Usage:
#   intent-add-untracked.sh              intent-add every untracked non-ignored path
#   intent-add-untracked.sh --dry-run    report what WOULD be added; mutate nothing
#   intent-add-untracked.sh --undo       un-intent-add every still-intent-added path
#                                        (`git rm --cached`), restoring it to
#                                        untracked WITHOUT touching its content
#
# PRECONDITION for --undo (load-bearing): run it only AFTER the run's authored
# commit — its mandated site is Phase 5 step 7, before the main-sync merge. It
# identifies an entry as intent-added by "index blob is empty AND path absent
# from HEAD", and git writes that exact same entry for a NEW EMPTY file staged
# with a real `git add`. The two are indistinguishable in the index, so calling
# --undo BEFORE the commit would unstage such a file. After the commit the
# ambiguity is gone: anything meant to land is in HEAD and is skipped.
#
# Output: a single JSON object on stdout.
#   {"added":[...],"count":N,"failed":[...],"note":"..."}
#   (--undo reports the removed paths in the same `added` array.)

set -uo pipefail

EMPTY_BLOB='e69de29bb2d1d6434b8b29ae775ad8c2e48c5391'

dry_run=0
undo=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --undo)    undo=1 ;;
    # Content-addressed, verbatim the convention in hooks/auto-task-gc.sh. A
    # hardcoded line range would silently rot the moment the header changes
    # length; this cannot. (It also sweeps up the body's full-line comments —
    # the same behaviour auto-task-gc.sh has, and preferable to diverging.)
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ;;   # unknown flags ignored — fail-open, never abort a run over an argument
  esac
done

# JSON string escaper. Order matters: backslash first, then quote, then the
# control characters a path can legally carry (tab, newline, CR).
jesc() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | awk '{ printf "%s", (NR>1 ? "\\n" : "") $0 } END { print "" }' \
    | sed -e 's/\t/\\t/g' -e 's/\r/\\r/g'
}

emit() {   # emit <added-list> <count> <failed-list> <note>
  printf '{"added":[%s],"count":%s,"failed":[%s],"note":"%s"}\n' "$1" "$2" "$3" "$4"
}

command -v git >/dev/null 2>&1 || { emit "" 0 "" "git not available — nothing done"; exit 0; }

toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$toplevel" ] || [ ! -d "$toplevel" ]; then
  emit "" 0 "" "not a git repository — nothing done"
  exit 0
fi
cd "$toplevel" 2>/dev/null || { emit "" 0 "" "cannot enter repo toplevel — nothing done"; exit 0; }

added=""; failed=""; count=0; fail_count=0
skipped=0

# --- baseline: paths that were already untracked when the run began -----------
# NUL-delimited so it round-trips any path git can produce. Resolved from the
# current branch, which is how every other auto-task component finds its run
# folder. Absent/unreadable -> empty -> the old repo-wide behaviour (fail-open).
baseline_paths=()
_br="$(git branch --show-current 2>/dev/null || true)"
if [ -n "$_br" ] && [ -f ".auto-task/$_br/untracked-baseline" ]; then
  while IFS= read -r -d '' _bp; do
    [ -n "$_bp" ] && baseline_paths[${#baseline_paths[@]}]="$_bp"
  done < ".auto-task/$_br/untracked-baseline"
fi

# Exact string comparison in-process. Deliberately NOT `grep -z -f <file>`: BSD
# grep splits a PATTERN FILE on newlines even under -z, so it silently truncates
# a NUL-delimited baseline at the first entry and skips only that one path — a
# false pass that looks like it works. Comparing with `=` cannot misread a path
# containing spaces, newlines, or regex metacharacters. The loop is O(n*m) with
# both counts tiny (m is 0 on the normal fresh-worktree path) and spawns nothing.
in_baseline() {   # in_baseline <path> -> 0 when the path was already untracked at run start
  local x="$1" bp
  for bp in ${baseline_paths+"${baseline_paths[@]}"}; do
    [ "$bp" = "$x" ] && return 0
  done
  return 1
}

# --- --undo: restore intent-added paths to untracked --------------------------
# An entry is ours to undo iff its index blob is the EMPTY blob AND the path is
# absent from HEAD. That pair is exact: a genuinely-empty file the run COMMITTED
# is in HEAD (excluded), and any path with real staged content has a non-empty
# blob (excluded). `git rm --cached` drops the index entry and leaves the file on
# disk untouched — verified: content preserved, path back in the untracked set.
if [ "$undo" -eq 1 ]; then
  while IFS= read -r -d '' entry; do
    [ -n "$entry" ] || continue
    sha="$(printf '%s' "$entry" | awk '{print $2}')"
    [ "$sha" = "$EMPTY_BLOB" ] || continue
    # strip "<mode> <sha> <stage>\t" — the path is everything after the first TAB,
    # so a path containing spaces or tabs-after-the-first survives intact.
    p="${entry#*	}"
    [ -n "$p" ] || continue
    git cat-file -e "HEAD:$p" 2>/dev/null && continue   # tracked in HEAD — not ours
    git rm --cached --quiet -- "$p" >/dev/null 2>&1 || true
    still_indexed="$(git ls-files -- "$p" 2>/dev/null || true)"
    if [ -z "$still_indexed" ]; then
      added="$added${added:+,}\"$(jesc "$p")\""
      count=$((count + 1))
    else
      failed="$failed${failed:+,}\"$(jesc "$p")\""
      fail_count=$((fail_count + 1))
    fi
  done < <(git ls-files -s -z 2>/dev/null || true)

  if [ "$count" -eq 0 ] && [ "$fail_count" -eq 0 ]; then
    note="no intent-added paths — nothing to undo"
  elif [ "$fail_count" -gt 0 ]; then
    note="un-intent-added $count path(s); $fail_count could not be removed (reported, not fatal)"
  else
    note="un-intent-added $count path(s) — back to untracked, content untouched"
  fi
  emit "$added" "$count" "$failed" "$note"
  exit 0
fi

# -z: NUL-delimited, so paths with spaces, quotes or newlines survive intact and
# git does not apply its quoting transform. Process substitution keeps the NUL
# stream out of a command substitution (which would strip it).
while IFS= read -r -d '' p; do
  [ -n "$p" ] || continue

  # The run did not create this path — leave the user's file strictly alone.
  if in_baseline "$p"; then
    skipped=$((skipped + 1))
    continue
  fi

  if [ "$dry_run" -eq 1 ]; then
    added="$added${added:+,}\"$(jesc "$p")\""
    count=$((count + 1))
    continue
  fi

  git add -N -- "$p" >/dev/null 2>&1 || true

  # Verify-then-claim: re-query rather than trusting the exit code above. A path
  # that genuinely entered the index no longer appears in the untracked set.
  still_untracked="$(git ls-files --others --exclude-standard -- "$p" 2>/dev/null || true)"
  if [ -z "$still_untracked" ]; then
    added="$added${added:+,}\"$(jesc "$p")\""
    count=$((count + 1))
  else
    failed="$failed${failed:+,}\"$(jesc "$p")\""
    fail_count=$((fail_count + 1))
  fi
done < <(git ls-files --others --exclude-standard -z 2>/dev/null || true)

skip_note=""
[ "$skipped" -gt 0 ] && skip_note="; skipped $skipped pre-existing untracked path(s) per the run baseline"

if [ "$dry_run" -eq 1 ]; then
  note="dry-run — $count untracked path(s) would be intent-added; nothing mutated$skip_note"
elif [ "$count" -eq 0 ] && [ "$fail_count" -eq 0 ]; then
  note="no run-created untracked paths — nothing to do$skip_note"
elif [ "$fail_count" -gt 0 ]; then
  note="intent-added $count path(s); $fail_count path(s) could not be added (reported, not fatal)$skip_note"
else
  note="intent-added $count path(s) — now visible to git diff <base>, no content staged$skip_note"
fi

emit "$added" "$count" "$failed" "$note"
exit 0
