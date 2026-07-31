#!/usr/bin/env bash
# clone-scope.sh — SHARED, SOURCED helper resolving CLONE-WIDE (not per-worktree)
# auto-task locations.
#
# WHY THIS EXISTS. auto-task isolates every run in its own linked git worktree,
# so per-run state (`.auto-task/<branch>/STATE.json`, the run clock, the outcome
# sentinel) correctly lives per worktree. But the run-outcome ledger
# (`.auto-task/outcomes.jsonl`) is the opposite kind of thing: its whole purpose
# is CROSS-run history that outlives any one branch folder. Resolved per worktree
# it fragments into nothing — which is exactly the bug this file fixes:
#
#   * record-outcome.sh retargeted `project_dir` to the linked worktree, then
#     required `$project_dir/.auto-task/outcomes.jsonl`. A fresh worktree never
#     has that file, so the opt-in gate failed closed: no row, no sentinel, on
#     EVERY worktree-isolated run (i.e. every real run).
#   * auto-task-stats.sh resolved the ledger from the UN-retargeted toplevel and
#     scanned live STATE.json only there — so writer and reader never agreed, and
#     the reader saw none of the runs living in worktrees despite README's promise
#     that it counts them.
#
# The fix is one definition of "where does clone-wide state live", read by both
# sides, so they cannot drift apart again. That is this file. Writer/reader drift
# WAS the defect; duplicating the logic per caller would re-arm it. Same rationale
# as hooks/lib/loop-budget.sh (one executable definition of the loop budget) and
# hooks/lib/run-clock.sh (one definition of duration, read by all three DERIVE
# sites).
#
# CONTRACT — PURE RESOLUTION ONLY, mirroring hooks/lib/resolve-run-state.sh:
# every function echoes a value (or nothing) and returns. NONE of them `exit`,
# print to the user, print diagnostics, or decide a fail-policy. Callers have
# different policies (the writer is a never-blocking Stop hook; the reader is a
# user-facing report), so failure handling stays with the caller. An unresolvable
# answer is returned as EMPTY OUTPUT — never a guess, never a partial path — so a
# caller can detect it with `[ -n "$x" ]` and fall back to its own prior behavior.
#
# NO HARD DEPENDENCIES. git may be missing, the cwd may not be a repo, the repo
# may be bare. Every path degrades to empty output rather than erroring, so a
# sourcing hook stays fail-open.
#
# ── Pre-existing duplicate worktree logic (CONSOLIDATION TARGETS, not yet done) ──
# Two families of near-identical logic predate this file. They are deliberately
# NOT changed by the run that introduced it (each has its own regression suite and
# no bearing on the ledger). Listed here so the next reader adopts `cs_*` instead
# of adding yet another copy:
#
#   Worktree ENUMERATION (`git worktree list --porcelain`):
#     - hooks/auto-task-resume-list.sh   (paths + branches; the most developed —
#                                         cs_worktree_paths is modelled on it)
#     - hooks/auto-task-gc.sh
#     - hooks/suggest-cleanup.sh
#
#   Same-repo LINKED-WORKTREE RETARGET (git-common-dir comparison):
#     - hooks/lib/resolve-run-state.sh   (rrs_resolve_state)
#     - hooks/record-outcome.sh, hooks/send-telemetry.sh,
#       hooks/prevent-mid-protocol-stall.sh, hooks/stamp-run-clock.sh,
#       hooks/warn-checkout-drift.sh, hooks/enforce-gates.sh,
#       hooks/inject-history-reminder.sh
#   NOT hooks/auto-task-stats.sh — it deliberately does NO retarget (it resolves only
#   `--show-toplevel` and then goes clone-wide through cs_autotask_roots). Listing it
#   here would send the next reader looking for logic that is not there, and would
#   obscure half of this bug's root cause: the reader never retargeted at all.
#
# That retarget answers a DIFFERENT question than this file ("which worktree owns
# the current run?" vs "what is clone-wide?"), so it is not simply replaceable by
# cs_* — do not conflate them.

# The basename of the cross-run outcome ledger, relative to a `.auto-task/` root.
# Named once so the writer, the reader and the tests cannot disagree on it.
CS_LEDGER_BASENAME="outcomes.jsonl"

# _cs_git <start_dir> <git args...>
#   Run git inside <start_dir>, swallowing all diagnostics. Echoes nothing on any
#   failure (not a repo, git absent, bare repo without the queried property).
_cs_git() {
  local dir="${1:-}"; shift || return 0
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  ( cd "$dir" 2>/dev/null && git "$@" 2>/dev/null ) || true
}

# _cs_is_main_worktree <dir>
#   True when <dir> is inside a WORKING TREE that is the repo's MAIN one (not a
#   linked worktree). The test is `absolute-git-dir == git-common-dir`: for the main
#   tree the two are the same path, while a linked worktree's git dir is
#   `<common>/worktrees/<name>`. Both are absolutised first — `--git-common-dir` is
#   returned RELATIVE in some positions (a bare `.git` from the toplevel, `.` from a
#   bare repo), so comparing raw output gives false answers.
_cs_is_main_worktree() {
  local dir="${1:-}" gd gcd
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  # Must be an actual working tree. Belt-and-braces rather than load-bearing: the
  # `--show-toplevel` step in cs_main_worktree also fails outside a work tree, so a
  # bare repo / separate git dir is rejected either way (removing this line alone does
  # not change any observable behavior). Kept because it states the precondition where
  # the predicate is defined, but do not read the bare-repo assertions in the test
  # suite as pinning THIS line — they pin the outcome, which `--show-toplevel` delivers.
  [ "$(_cs_git "$dir" rev-parse --is-inside-work-tree)" = "true" ] || return 1
  gd="$(_cs_git "$dir" rev-parse --absolute-git-dir)"
  gcd="$(_cs_git "$dir" rev-parse --git-common-dir)"
  [ -n "$gd" ] && [ -n "$gcd" ] || return 1
  case "$gcd" in /*) ;; *) gcd="$dir/$gcd" ;; esac
  gd="$(cd "$gd" 2>/dev/null && pwd -P || true)"
  gcd="$(cd "$gcd" 2>/dev/null && pwd -P || true)"
  [ -n "$gd" ] && [ "$gd" = "$gcd" ]
}

# cs_main_worktree [start_dir]
#   Echoes the absolute path of the clone's MAIN working tree — the one whose
#   `.auto-task/` is clone-wide — resolved from any linked worktree or from the
#   main tree itself. Echoes NOTHING when it cannot be determined, which the
#   caller must treat as "keep your previous behavior".
#
#   ORDER MATTERS, and this is the second attempt at it. The first asked
#   `git worktree list --porcelain` and took its FIRST entry, on the belief that the
#   first entry is always the main working tree. **It is not.** Measured on git
#   2.44: under `git init --separate-git-dir=…` the first entry is the GIT DIR
#   (`…/B.git`), not the working tree — and since a git dir is a real directory, an
#   `[ -d ]` test accepts it. The same happens for a bare clone with linked
#   worktrees, where the first entry is `…/bare.git`. In both cases the resolver
#   handed back `<git-dir>/.auto-task/outcomes.jsonl`, so the writer's opt-in gate
#   tested a path inside the git dir, found nothing and silently recorded nothing —
#   reintroducing the exact bug this file exists to remove, for a different repo
#   shape, and REGRESSING the plain `--separate-git-dir` single-tree case against
#   the pre-change behavior.
#
#   So: ask about the CURRENT working tree first, and only enumerate as a fallback.
#     1. If `start_dir` is itself the main working tree, its `--show-toplevel` IS
#        the answer. `--show-toplevel` is correct in every layout (it is what every
#        other hook in this repo anchors on), which is what makes the
#        `--separate-git-dir` single-tree case come out right.
#     2. Otherwise we are in a linked worktree, so enumerate and return the first
#        entry that is genuinely a main working tree — validated with
#        `_cs_is_main_worktree`, never assumed from position.
#   If neither yields one, echo nothing. That is the honest answer for a bare clone
#   with worktrees (no main working tree exists at all) and for a linked worktree of
#   a `--separate-git-dir` repo (whose real working tree `worktree list` never
#   names). Per the contract above, empty means "caller, keep your own root" — never
#   a guess.
cs_main_worktree() {
  local start="${1:-$PWD}" main="" p

  # 1. Are we already standing in the main working tree?
  if _cs_is_main_worktree "$start"; then
    main="$(_cs_git "$start" rev-parse --show-toplevel)"
    if [ -n "$main" ]; then
      main="$(cd "$main" 2>/dev/null && pwd -P || true)"
      [ -n "$main" ] && [ -d "$main" ] && { printf '%s\n' "$main"; return 0; }
    fi
  fi

  # 2. Linked worktree (or an unusual position): enumerate and VALIDATE each entry.
  while IFS= read -r p; do
    case "$p" in worktree\ *) p="${p#worktree }" ;; *) continue ;; esac
    [ -n "$p" ] || continue
    _cs_is_main_worktree "$p" || continue
    main="$(_cs_git "$p" rev-parse --show-toplevel)"
    [ -n "$main" ] || continue
    main="$(cd "$main" 2>/dev/null && pwd -P || true)"
    [ -n "$main" ] && [ -d "$main" ] && { printf '%s\n' "$main"; return 0; }
  done <<EOF
$(_cs_git "$start" worktree list --porcelain)
EOF

  # 3. `core.worktree` in the common dir's config — a genuine back-pointer from a git
  #    dir to its working tree, and the only way to reach the main tree of a git
  #    SUBMODULE from one of its linked worktrees (measured: a submodule's config
  #    carries `core.worktree = ../../../sub`, while `worktree list` names only the
  #    git dir `super/.git/modules/sub`). The value is relative to the GIT DIR, so it
  #    is resolved against the common dir, then validated like any other candidate.
  #
  #    Note this does NOT rescue `git init --separate-git-dir`, which leaves
  #    `core.worktree` unset (also measured) — from one of ITS linked worktrees the
  #    main working tree is genuinely undiscoverable, so we return empty and the
  #    caller keeps its own root. That is the contract's "never a guess" clause, and
  #    it matches the pre-change behavior for that layout rather than regressing it.
  local common cw
  common="$(_cs_git "$start" rev-parse --git-common-dir)"
  if [ -n "$common" ]; then
    case "$common" in /*) ;; *) common="$start/$common" ;; esac
    common="$(cd "$common" 2>/dev/null && pwd -P || true)"
    if [ -n "$common" ] && [ -f "$common/config" ] && command -v git >/dev/null 2>&1; then
      cw="$(git config -f "$common/config" --get core.worktree 2>/dev/null || true)"
      if [ -n "$cw" ]; then
        case "$cw" in /*) ;; *) cw="$common/$cw" ;; esac
        cw="$(cd "$cw" 2>/dev/null && pwd -P || true)"
        if [ -n "$cw" ] && _cs_is_main_worktree "$cw"; then
          printf '%s\n' "$cw"; return 0
        fi
      fi
    fi
  fi

  return 0   # nothing determinable → empty output
}

# cs_ledger_path [start_dir]
#   Echoes the ONE canonical cross-run ledger path for this clone:
#   <main worktree>/.auto-task/outcomes.jsonl. Echoes nothing when the main
#   worktree is unresolvable.
#
#   Note this returns the path whether or not the file exists — existence is the
#   OPT-IN signal and belongs to the caller (record-outcome.sh no-ops when the
#   file is absent; auto-task-stats.sh prints an opt-in hint naming this path).
cs_ledger_path() {
  local main
  main="$(cs_main_worktree "${1:-$PWD}")"
  [ -n "$main" ] || return 0
  printf '%s/.auto-task/%s\n' "$main" "$CS_LEDGER_BASENAME"
}

# cs_worktree_paths [start_dir]
#   Echoes the toplevel of EVERY working tree of this clone, one per line, MAIN TREE
#   FIRST. Each path is normalised with `pwd -P`, verified to be a real working tree,
#   and the list is DE-DUPLICATED; non-existent or pruned-but-still-listed entries are
#   dropped. Echoes nothing outside a repo.
#
#   De-duplication is load-bearing, not hygiene: callers tally runs found under these
#   roots, so a repeated path would double-count a run. Producing a unique list here
#   means every caller gets that guarantee for free.
#
#   THE MAIN TREE IS SEEDED FROM `cs_main_worktree`, NOT TAKEN FROM THE LIST. This is
#   the third and last place the same wrong assumption bit: `git worktree list` does
#   NOT always name the main working tree. Under `--separate-git-dir` — and for EVERY
#   git submodule, whose `.git` is a `gitdir:` file — it names the git dir instead
#   (measured on git 2.44). The per-entry working-tree filter below correctly rejects
#   that entry, but rejecting it is only half the job: an earlier revision then relied
#   on a fallback gated on the output being ENTIRELY empty, so as soon as one linked
#   worktree existed (which, in auto-task, every run creates) the main tree was
#   silently absent from the list — and the reader stopped counting the runs living
#   there. Seeding unconditionally is what actually delivers the "main tree first"
#   contract in the header above; the list then contributes only the other worktrees,
#   and dedup absorbs the normal case where it names the main tree too.
cs_worktree_paths() {
  local start="${1:-$PWD}" line p seen="" out="" main=""

  main="$(cs_main_worktree "$start")"
  if [ -n "$main" ]; then
    seen="$main
"
    out="$main
"
  fi

  while IFS= read -r line; do
    case "$line" in
      worktree\ *) ;;
      *) continue ;;
    esac
    p="${line#worktree }"
    [ -n "$p" ] || continue
    p="$(cd "$p" 2>/dev/null && pwd -P || true)"
    [ -n "$p" ] && [ -d "$p" ] || continue
    # Must be an actual WORKING TREE, not merely an existing directory. `worktree
    # list` also names a bare repo / separate git dir as its first entry (measured on
    # git 2.44), and those are real directories that `[ -d ]` waves through — which
    # would have callers scanning `<git-dir>/.auto-task` for runs.
    [ "$(_cs_git "$p" rev-parse --is-inside-work-tree)" = "true" ] || continue
    # Membership test on a newline-delimited accumulator. Paths can contain
    # spaces, so a space-delimited `case` set (the idiom used elsewhere in these
    # hooks for branch names) would be wrong here.
    case "
$seen" in
      *"
$p
"*) continue ;;
    esac
    seen="$seen$p
"
    out="$out$p
"
  done <<EOF
$(_cs_git "$start" worktree list --porcelain)
EOF

  # No trailing fallback is needed: the main tree was seeded above (covering a git too
  # old for `worktree list --porcelain`), and empty output now means only what it
  # should — no resolvable main tree AND no listed worktree, i.e. not a working tree
  # of a repo at all.
  [ -n "$out" ] && printf '%s' "$out"
}

# cs_autotask_roots [start_dir]
#   Echoes every EXISTING `<worktree toplevel>/.auto-task` directory in this
#   clone, one per line, main tree first. Absent ones are skipped, so the output
#   is directly usable as a `find` root list. De-duplicated by construction (its
#   input is). Echoes nothing when none exist.
cs_autotask_roots() {
  local p out=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -d "$p/.auto-task" ] || continue
    out="$out$p/.auto-task
"
  done <<EOF
$(cs_worktree_paths "${1:-$PWD}")
EOF
  [ -n "$out" ] && printf '%s' "$out"
}
