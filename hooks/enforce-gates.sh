#!/usr/bin/env bash
# Enforces auto-task's gate-passage contract on `git commit`.
#
# Registered as a PreToolUse hook on Bash. When the command being run is
# `git commit` AND an auto-task run is active (STATE.json present + approved),
# blocks the commit until all required gates have passed.
#
# Path: resolves the per-branch STATE.json via `git branch --show-current`,
# so multiple concurrent branches each have their own state.
#
# Failure policy: this is a SAFETY hook, so it fails CLOSED. Once we know the
# command is a `git commit` and a STATE.json exists for the branch, anything
# that prevents verification (jq missing, malformed JSON) blocks the commit
# rather than letting it through. `set -e` is intentionally NOT used — a stray
# non-zero from jq must not crash the script into a fail-open exit.

set -uo pipefail

input="$(cat)"

# `cmd_is_raw=1` means cmd is the raw JSON payload (jq absent or decode failed),
# not a decoded shell command. The two need different commit-detection regexes:
# the decoded command can use shell-boundary anchors, but inside raw JSON the
# verb is preceded by `"` (not a boundary char), so an anchored regex would miss
# it — which would skip the fail-closed blocks below and fail OPEN.
cmd_is_raw=1
if command -v jq >/dev/null 2>&1; then
  has_jq=1
  decoded="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
  if [ -n "$decoded" ]; then cmd="$decoded"; cmd_is_raw=0; else cmd="$input"; fi
else
  has_jq=0
  cmd="$input"
fi

# Only fire on `git commit`. We must catch every real invocation of the commit
# subcommand while NOT matching the verb in prose (`echo see the git commit
# guidelines`) or inside a longer token (`git committed-xyz`, `mygit`). A real
# commit can be reached through several forms a naive `git[[:space:]]+commit`
# misses — each of which would silently FAIL OPEN (skip the fail-closed gate
# below), the exact defect this guards:
#   - global options between git and the subcommand: `git -C <path> commit`,
#     `git -c user.name=x commit`, `git --no-pager commit`
#   - leading environment assignments: `GIT_AUTHOR_NAME=x git commit`
#   - a command wrapper: `sudo git commit`, `command git commit`, `env A=b git commit`
#   - a path-qualified binary: `/usr/bin/git commit`, `./git commit`
#   - values containing quoted whitespace: `git -c user.name='A B' commit`
# The regex is assembled from shared sub-patterns so the decoded-command and
# raw-JSON-fallback variants stay in lockstep — they differ ONLY in the leading
# boundary alternation (the raw variant also allows the JSON value's opening `"`,
# since inside raw JSON the verb is preceded by `"` rather than a shell boundary).
# `git` is anchored to a command boundary (start / shell separator `; & |` /
# backtick / `$(` / — raw only — `"`), so prose mentions never match. The trailing
# `commit(\b|$)` is intentionally UNCHANGED.
#
# Deliberately NOT covered (documented, lower-realism, deferred — NOT a silent
# gap): wrapper OPTIONS (`sudo -u bob git commit`), wrappers outside the fixed
# allowlist, git aliases / shell functions shadowing `git`, and — on the raw
# jq-absent path only — quoted values whose inner quotes arrive backslash-escaped.
# `jq` is a hard prerequisite (the gate fails closed when it is absent and a state
# file exists), so raw mode is a degraded fallback. A fully evasion-proof detector
# would need shell parsing, out of scope for a PreToolUse regex on the Bash hot path.
# (Also pre-existing and untouched: the trailing `\b` over-blocks `git commit-graph`
# / `git commit-tree` — a fail-SAFE false positive, deferred separately.)
sq="'"
# A shell "value" token: a double-quoted span, a single-quoted span, or a run of
# non-space chars — so a quoted value containing spaces does not break the walk.
val="(\"[^\"]*\"|${sq}[^${sq}]*${sq}|[^[:space:]])+"
# Optional leading command wrappers (bounded allowlist — these reserved words only,
# so they engage only at a command boundary, never as prose words mid-sentence).
wrap="((sudo|command|env|nice|doas|time|xargs)[[:space:]]+)*"
# Optional leading environment assignments (value may be quoted-with-spaces).
envp="([A-Za-z_][A-Za-z0-9_]*=${val}?[[:space:]]+)*"
# git, optionally path-qualified (`/usr/bin/git`, `./git`).
gitq="([^[:space:]]*/)?git"
# git global options before the subcommand: each a -token, optionally followed by
# one value arg (covers `-C <path>`, `-c <k=v>`, quoted values). grep matching is
# existential, so a flag directly before `commit` still leaves `commit` to match.
opts="([[:space:]]+-[^[:space:]]+([[:space:]]+${val})?)*"
mid="${wrap}${envp}${gitq}${opts}[[:space:]]+commit(\\b|\$)"
if [ "$cmd_is_raw" -eq 1 ]; then
  commit_re="(^|[;&|\`]|\\\$\\(|\")[[:space:]]*${mid}"
else
  commit_re="(^|[;&|\`]|\\\$\\()[[:space:]]*${mid}"
fi
if ! printf '%s' "$cmd" | LC_ALL=C grep -qE "$commit_re"; then
  exit 0
fi

# Resolve the project root that owns .auto-task/<branch>/. Start from
# CLAUDE_PROJECT_DIR (the session's project root) or $PWD, then resolve that to
# its git worktree root, so a commit from a subdirectory still finds
# .auto-task/<branch>/ at the top. Resolving the toplevel OF the base keeps an
# explicitly-set CLAUDE_PROJECT_DIR authoritative for the common case. Fall back
# to base when it is not inside a working tree (no repo / bare / inside .git/).
project_dir_base="${CLAUDE_PROJECT_DIR:-$PWD}"
project_dir="$(cd "$project_dir_base" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$project_dir" ] || project_dir="$project_dir_base"

# Worktree retarget. auto-task isolates every run in a linked git worktree, but
# the harness keeps CLAUDE_PROJECT_DIR pinned to the MAIN checkout. A `git commit`
# actually runs in the worktree (the session's cwd), so it lands on the worktree's
# branch — yet the base resolution above points at the main checkout. Left
# uncorrected, this hook then inspects main's branch + .auto-task/ instead of the
# worktree's, and (when main has no active run but other branches do) fires a
# bogus checkout-drift block. Fix: when the operation's real cwd is a linked
# worktree OF THE SAME REPO, retarget project_dir to it. Same-repo worktree vs
# nested/embedded repo is discriminated by the git common-dir: a linked worktree
# SHARES the main repo's common-dir (different toplevel), while a nested/embedded
# repo has its OWN — so nested repos never retarget and the no-fail-open guarantee
# for them is preserved. Common-dirs are compared after `cd`-into + `pwd -P` so a
# relative `.git` (returned from a toplevel) vs an absolute path (from a worktree)
# and the macOS /var->/private/var symlink both normalise. The real cwd comes from
# the payload's .cwd (the authoritative session cwd), falling back to $PWD.
op_cwd=""
if [ "$has_jq" -eq 1 ]; then
  op_cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || true)"
fi
[ -n "$op_cwd" ] || op_cwd="$PWD"
if [ -d "$op_cwd" ]; then
  cwd_top="$(cd "$op_cwd" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$cwd_top" ] && [ "$cwd_top" != "$project_dir" ]; then
    cwd_common="$(cd "$op_cwd" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)" 2>/dev/null && pwd -P || true)"
    base_common="$(cd "$project_dir" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)" 2>/dev/null && pwd -P || true)"
    if [ -n "$cwd_common" ] && [ "$cwd_common" = "$base_common" ]; then
      project_dir="$cwd_top"   # same repo, linked worktree → the real commit target
    fi
  fi
fi
branch="$(cd "$project_dir" && git branch --show-current 2>/dev/null || true)"
if [ -z "$branch" ]; then
  exit 0  # detached HEAD or not a repo — let git handle it
fi
state="$project_dir/.auto-task/$branch/STATE.json"
if [ ! -f "$state" ]; then
  # No state for the CURRENT branch. Normally this means no auto-task run is
  # active here, so the commit is none of our business — allow it. BUT guard the
  # checkout-drift case: if the working tree moved off an in-place run's branch
  # (an active run exists for ANOTHER branch, not this one), committing here
  # would land on the wrong branch and bypass the gates of that run. This closes
  # what was previously a silent fail-open (the old `[ -f "$state" ] || exit 0`).
  # Requires jq to read states; without jq we cannot PROVE drift, so we do NOT
  # manufacture a block (the current-branch fail-closed rules below are
  # unaffected). Scope is the current working tree only — .auto-task/ is
  # per-worktree, so a parallel run in another worktree can never trigger this.
  autotask_dir="$project_dir/.auto-task"
  if [ "$has_jq" -eq 1 ] && [ -d "$autotask_dir" ]; then
    cur_active=0; others=""
    while IFS= read -r sf; do
      [ -n "$sf" ] || continue
      [ -f "$sf" ] || continue
      jq empty "$sf" 2>/dev/null || continue
      [ "$(jq -r '.approved // false' "$sf" 2>/dev/null || echo false)" = "true" ] || continue
      [ "$(jq -r '.phase // ""' "$sf" 2>/dev/null || echo "")" = "done" ] && continue
      rel="${sf#"$autotask_dir"/}"; br="${rel%/STATE.json}"
      [ "$br" != "$rel" ] || continue   # stray top-level STATE.json (no <branch>/ segment)
      [ -n "$br" ] || continue
      if [ "$br" = "$branch" ]; then cur_active=1; continue; fi
      case " $others " in *" $br "*) ;; *) others="$others $br" ;; esac
    done <<< "$(find "$autotask_dir" -name STATE.json 2>/dev/null)"
    if [ "$cur_active" -eq 0 ] && [ -n "$others" ]; then
      drifted="${others# }"
      printf 'Blocked by auto-task-plugin: the checkout moved underneath an active auto-task run.\nAn active run exists on branch(es) [%s], but the working tree is on "%s" (no run state here).\nCommitting now would land on the wrong branch and bypass the gates of that run.\nSwitch back (git switch %s) and resume, OR remove .auto-task/%s/ if that run is abandoned — then retry the commit.\n' "$drifted" "$branch" "$drifted" "$drifted" >&2
      exit 2
    fi
  fi
  exit 0
fi

# From here: a commit is being attempted AND an auto-task state file exists for
# this branch. We MUST be able to read it to decide. Fail closed otherwise.
if [ "$has_jq" -eq 0 ]; then
  printf 'Blocked by auto-task-plugin: an auto-task run state file exists for branch "%s" but `jq` is not installed, so the gate contract cannot be verified before this commit.\nInstall jq (a hard prerequisite of this plugin) and retry. If no run is active, remove .auto-task/%s/.\n' "$branch" "$branch" >&2
  exit 2
fi
if ! jq empty "$state" 2>/dev/null; then
  printf 'Blocked by auto-task-plugin: .auto-task/%s/STATE.json is not valid JSON, so the gate contract cannot be verified.\nRepair the state file (it must parse and contain the gates object) and retry, or remove .auto-task/%s/ if no run is active.\n' "$branch" "$branch" >&2
  exit 2
fi

approved="$(jq -r '.approved // false' "$state" 2>/dev/null || echo false)"
[ "$approved" = "true" ] || exit 0

phase="$(jq -r '.phase // ""' "$state" 2>/dev/null || echo "")"
if [ "$phase" = "done" ]; then
  exit 0
fi

review_passed="$(jq -r '.gates.code_review.passed // false' "$state" 2>/dev/null || echo false)"
review_tool="$(jq -r '.gates.code_review.tool // ""' "$state" 2>/dev/null || echo "")"
review_clean="$(jq -r '.gates.code_review.clean_pass_after_last_fix // false' "$state" 2>/dev/null || echo false)"
reviewed_sha="$(jq -r '.gates.code_review.reviewed_diff_sha // ""' "$state" 2>/dev/null || echo "")"
base="$(jq -r '.base // ""' "$state" 2>/dev/null || echo "")"
tier="$(jq -r '.effort.tier // "standard"' "$state" 2>/dev/null || echo standard)"
gate_b_passed="$(jq -r '.gates.gate_b.passed // false' "$state" 2>/dev/null || echo false)"
gate_b_skipped="$(jq -r '.gates.gate_b.skipped_reason // ""' "$state" 2>/dev/null || echo "")"

if [ "$review_passed" != "true" ]; then
  printf 'Blocked by auto-task-plugin: auto-task run in progress (state: %s).\nA git commit is NOT permitted until the code-review loop has passed.\nRequired before commit:\n  gates.code_review.passed = true   (currently: %s)\nRun the code-review skill, fix all blockers/required findings, re-run the skill until it returns only follow-ups, then set the flags.\n' "$state" "$review_passed" >&2
  exit 2
fi

if [ "$review_tool" != "skill:auto-task-code-review" ]; then
  printf 'Blocked by auto-task-plugin: code-review must be invoked via the `auto-task-code-review` SKILL, not an agent or hand-rolled prompt.\nRequired:\n  gates.code_review.tool = "skill:auto-task-code-review"   (currently: %s)\nRe-run the review via the Skill tool with skill="auto-task-code-review" and update the flag with real evidence.\n' "$review_tool" >&2
  exit 2
fi

if [ "$review_clean" != "true" ]; then
  printf 'Blocked by auto-task-plugin: latest code-review pass is not clean after the most recent fix.\nRequired:\n  gates.code_review.clean_pass_after_last_fix = true   (currently: %s)\nAfter applying any fix, you MUST re-invoke the code-review skill; only set this flag when its latest output contains zero blockers and zero required findings.\n' "$review_clean" >&2
  exit 2
fi

# Review-staleness check: the gate flags above are booleans the model sets for
# itself. This binds them to the actual code. When the gate last passed clean,
# the model records reviewed_diff_sha = hash of `git diff <base>`. If the diff
# now hashes differently, code changed since the last clean review and a commit
# must NOT proceed without re-review. Backward-compatible: skipped when `base`
# or `reviewed_diff_sha` is absent (legacy/older runs), so it can only ever add
# a block, never spuriously allow.
#
# The diff flags are PINNED so the hash is stable regardless of the user's git
# config (and identical across machines that share the branch). Without them,
# diff.algorithm / diff.renames / diff.noprefix / diff.mnemonicPrefix / color /
# textconv / external-diff settings can each shift the diff text — and thus the
# hash — for an unchanged tree, producing a spurious staleness block. The skill
# records reviewed_diff_sha with this SAME flag set; the two must stay in lockstep.
#
# Staleness is ENFORCED DURING A MERGE TOO (this closes a former exemption that
# skipped the check wholesale while MERGE_HEAD was present and thereby let
# un-reviewed authored edits ride in on a merge commit — the one place a
# fail-closed gate had a fail-open crack). Why enforcing here is correct, not
# spurious:
#   - A CLEAN auto-merge (`git merge --no-edit`, no conflicts) auto-commits with
#     NO `git commit` verb, so it never matches the commit detector above and
#     never reaches this hook — there is nothing to exempt.
#   - The ONLY merge that reaches here is a CONFLICT finalize (`git commit
#     --no-edit` with MERGE_HEAD present) — i.e. exactly when authored resolution
#     edits exist and MUST be re-reviewed. The skill re-reviews the resolved tree
#     and refreshes reviewed_diff_sha to `hash(git diff <base>)` of that tree
#     BEFORE this commit (Phase 5 step 7), so a correct run MATCHES here, while a
#     run that skipped the re-review (stale sha from before the merge) is BLOCKED.
#     The re-review is thus a MECHANICAL requirement, not prose the model must
#     remember.
# reviewed_diff_sha is the full `git diff <base>` hash and legitimately includes
# the merged-in upstream after a refresh — that is fine: the sha only detects tree
# change; the review SCOPE stays the run's own delta (see SKILL Phase 5 step 7).
# merge_in_progress now only TAILORS the block message. Backward-compatible:
# skipped only when base or reviewed_diff_sha is absent (legacy runs), never a
# spurious allow. Boolean gates (review passed / tool / clean-after-fix above,
# gate_b below) are unchanged and still hold during a merge.
DIFF_FLAGS='--no-color --no-ext-diff --no-textconv --no-renames --diff-algorithm=myers --src-prefix=a/ --dst-prefix=b/'
merge_in_progress=0
if git -C "$project_dir" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  merge_in_progress=1
fi
if [ -n "$base" ] && [ -n "$reviewed_sha" ]; then
  current_sha="$(cd "$project_dir" && git diff $DIFF_FLAGS "$base" 2>/dev/null | git hash-object --stdin 2>/dev/null || true)"
  if [ -n "$current_sha" ] && [ "$current_sha" != "$reviewed_sha" ]; then
    if [ "$merge_in_progress" -eq 1 ]; then
      printf 'Blocked by auto-task-plugin: a merge is in progress and the working-tree diff does not match the last clean code-review pass.\n  reviewed_diff_sha: %s\n  current diff sha:  %s   (git diff %s)\nThe merged / conflict-resolved tree has not been re-reviewed. BEFORE finalizing the merge commit: re-run the auto-task-code-review skill on the post-merge diff, drive it to a clean pass, refresh gates.code_review.reviewed_diff_sha to the resolved tree (and on STANDARD/HEAVY reset gates.gate_b.passed=false and re-run Gate B).\n' "$reviewed_sha" "$current_sha" "$base" >&2
    else
      printf 'Blocked by auto-task-plugin: the working-tree diff changed since the last clean code-review pass.\n  reviewed_diff_sha: %s\n  current diff sha:  %s   (git diff %s)\nCode was modified after gates.code_review went clean, so the review no longer covers what you are about to commit.\nRe-run the auto-task-code-review skill on the current diff, drive it to a clean pass, then refresh gates.code_review.reviewed_diff_sha before committing.\n' "$reviewed_sha" "$current_sha" "$base" >&2
    fi
    exit 2
  fi
fi

if [ "$tier" != "light" ] && [ "$gate_b_passed" != "true" ] && [ -z "$gate_b_skipped" ]; then
  printf 'Blocked by auto-task-plugin: tier=%s requires Gate B before commit.\nRequired:\n  gates.gate_b.passed = true   OR   gates.gate_b.skipped_reason set\n' "$tier" >&2
  exit 2
fi

exit 0
