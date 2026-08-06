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

# Shared, PURE run-state resolver (branch/worktree/STATE + cross-branch scan).
# Sourced for the merge-gate block below; the commit-path resolution further down
# is intentionally left inline, byte-for-byte, so the ~100-assertion enforcement
# spine test keeps proving the commit gate unchanged. The helper is a faithful
# extraction of that same logic, and the ops guard uses it too, so the merge-gate
# and the guard cannot diverge from each other.
ENFORCE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# shellcheck source=/dev/null
. "$ENFORCE_SCRIPT_DIR/lib/resolve-run-state.sh" 2>/dev/null || true
# Shared, PURE fix-loop budget resolver — the single executable home of the
# effort-tier cap table, sourced by this hook AND by prevent-mid-protocol-stall.sh
# so the two cannot drift. Sourced permissively (`|| true`) like the resolver above;
# the loop-budget block below re-checks that its functions actually loaded, because
# a fail-CLOSED hook must not silently skip a guard just because a source failed.
# shellcheck source=/dev/null
. "$ENFORCE_SCRIPT_DIR/lib/loop-budget.sh" 2>/dev/null || true

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
# --- Merge gate (land action: git push / git merge) --------------------------
# The sole mandatory human gate is the merge/land. When a run set
# gates.merge.required=true and has not recorded gates.merge.acked, the land action
# is BLOCKED until the ack exists — mechanically, so an autonomous run cannot skip
# it. Detected with the SAME anti-evasion sub-patterns as commit, and placed BEFORE
# the commit-only early exit so a push/merge (which is never a `git commit`) is
# actually inspected instead of silently allowed (the fail-open the critique
# flagged). Two landing styles are covered: (a) push while on the run branch, and
# (b) direct-to-main (checkout on main / another branch) via the cross-branch
# active-run scan — so an on-main land is guarded, not fail-open.
land_mid="${wrap}${envp}${gitq}${opts}[[:space:]]+(push|merge)(\\b|\$)"
# Also gate `gh pr merge` — the land action for landing_model=pr (the default),
# where the run does not push-to-main. Reuses the wrapper/env prefix; `gh` is not
# path-qualified like git, so it is matched directly.
gh_mid="${wrap}${envp}gh[[:space:]]+pr[[:space:]]+merge(\\b|\$)"
if [ "$cmd_is_raw" -eq 1 ]; then
  land_re="(^|[;&|\`]|\\\$\\(|\")[[:space:]]*(${land_mid}|${gh_mid})"
else
  land_re="(^|[;&|\`]|\\\$\\()[[:space:]]*(${land_mid}|${gh_mid})"
fi
# HERESTRING, not `printf … | grep -qE`. This detector and the commit one below decide
# whether the hook engages AT ALL, so a false negative here silently skips EVERY gate in
# this file — review flags, staleness, Gate B, diff hygiene and the loop budget alike.
# `grep -q` exits at its first match, closing the pipe; `printf` is a shell BUILTIN, so
# SIGPIPE kills the subshell running it and `set -o pipefail` (line 17) promotes 141 to the
# pipeline's status, making the `if` read "no match". A herestring is not a pipeline, so
# the status is grep's alone.
#
# It needs a MULTI-LINE command to fire — BSD grep reads a single long line whole and never
# SIGPIPEs, which is why a 200 KB one-liner is fine and 4001 lines is not (measured
# rc=141 vs rc=0). End-to-end before this fix: `git commit -m x` chained with ~100 KB of
# further lines exited 0 against a state with `gates.code_review.passed=false` — a total,
# silent bypass of a fail-closed safety hook. Reachable via an ordinary compound call: a
# commit chained with a large heredoc, `git commit -F - <<EOF` with a big body, or a commit
# followed by a generated script.
if LC_ALL=C grep -qE "$land_re" <<< "$cmd"; then
  if command -v rrs_resolve_state >/dev/null 2>&1; then
    rrs_resolve_state "$input"
    cand=""
    [ -f "$RRS_STATE" ] && cand="$RRS_STATE"
    for br in $RRS_ACTIVE_OTHERS; do
      f="$RRS_PROJECT_DIR/.auto-task/$br/STATE.json"
      [ -f "$f" ] && cand="$cand
$f"
    done
    if [ -n "$cand" ]; then
      if ! command -v jq >/dev/null 2>&1; then
        printf 'Blocked by auto-task-plugin: a run state exists but `jq` is not installed, so the merge gate cannot be verified before this push/merge.\nInstall jq (a plugin prerequisite) and retry.\n' >&2
        exit 2
      fi
      # risk_gate_threshold, read the same way guard-dangerous-ops.sh reads its
      # setting. An unreadable setting falls back to the documented default (6)
      # rather than skipping the check — a gate that disables itself because a
      # config file could not be parsed is the fail-open this hook exists to
      # prevent.
      risk_threshold=6
      if [ -f "$ENFORCE_SCRIPT_DIR/settings.sh" ]; then
        rt="$(bash "$ENFORCE_SCRIPT_DIR/settings.sh" get risk_gate_threshold 2>/dev/null || echo "")"
        printf '%s' "$rt" | LC_ALL=C grep -qE '^[0-9]+$' && risk_threshold="$rt"
      fi
      while IFS= read -r sf; do
        [ -n "$sf" ] || continue
        [ -f "$sf" ] || continue
        jq empty "$sf" 2>/dev/null || continue
        [ "$(jq -r '.approved // false' "$sf" 2>/dev/null || echo false)" = "true" ] || continue
        [ "$(jq -r '.phase // ""' "$sf" 2>/dev/null || echo "")" = "done" ] && continue
        req="$(jq -r '.gates.merge.required // false' "$sf" 2>/dev/null || echo false)"
        ack="$(jq -r '.gates.merge.acked // false' "$sf" 2>/dev/null || echo false)"
        # High-risk backstop — the mechanical half of "high risk forces the gate
        # on regardless of mode".
        #
        # Nothing mechanical sets `gates.merge.required`. It is written by the
        # Phase-5 prompt at step 7b, so when that step is skipped the flag stays
        # false and the land sails through — on precisely the runs the gate exists
        # for. Observed: two runs in the local corpus scored `effort.risk >= 6`
        # against a threshold of 6; one recorded the gate, the other reached
        # `phase: done` with `required: false` and was never stopped.
        #
        # So the trigger is recomputed here from the same two values the prompt
        # reads. The prompt keeps its job (set the flag, surface the disclaimer and
        # the assumptions ledger); this is the backstop for when it doesn't run.
        # A missing or non-numeric `effort.risk` blocks nothing — an unscored run
        # behaves exactly as it did before.
        risk="$(jq -r '.effort.risk // ""' "$sf" 2>/dev/null || echo "")"
        if [ "$req" != "true" ] && [ "$ack" != "true" ] \
           && printf '%s' "$risk" | LC_ALL=C grep -qE '^[0-9]+$' \
           && [ "$risk" -ge "$risk_threshold" ]; then
          printf 'Blocked by auto-task-plugin: this run is high-risk, so the merge gate is mandatory — but it was never armed.\n  state: %s\n  effort.risk = %s  >=  risk_gate_threshold = %s\n  gates.merge.required = %s   (expected true)\nPhase 5 step 7b should have set gates.merge.required = true for this run and did not, so the land was about to proceed with no human stop. Do step 7b now: surface the red risk disclaimer + the assumptions ledger, get the user'"'"'s explicit go-ahead, then set gates.merge.required = true and gates.merge.acked = true before landing.\n' "$sf" "$risk" "$risk_threshold" "$req" >&2
          exit 2
        fi
        if [ "$req" = "true" ] && [ "$ack" != "true" ]; then
          printf 'Blocked by auto-task-plugin: the merge gate is not acknowledged for this run.\n  state: %s\n  gates.merge.required = true, gates.merge.acked != true\nThis is the run'"'"'s single mandatory human gate. Surface the red risk disclaimer + assumptions ledger, get the user'"'"'s explicit go-ahead, then set gates.merge.acked = true before landing.\n' "$sf" >&2
          exit 2
        fi
      done <<EOF
$cand
EOF
    fi
  fi
  # NOTE: do NOT exit here. A land action that is not blocked must fall through to
  # the commit detector below — otherwise a compound command like
  # `git commit -m x && git push` (which matches land_re on the push) would skip
  # the entire commit gate. A pure push/merge simply won't match commit_re and
  # exits 0 there; a chained commit is still gated.
fi

# HERESTRING for the same reason as the land detector above — see that comment. This is the
# more consequential of the two: a false negative here takes the `exit 0` below and skips
# every gate in the file.
if ! LC_ALL=C grep -qE "$commit_re" <<< "$cmd"; then
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

# ---- Diff hygiene ----------------------------------------------------------
# Every block ABOVE this one decides from a field the model wrote into STATE.json.
# The hook was fail-closed about review BOOKKEEPING and blind to diff CONTENT, so a
# diff carrying a real `AKIA…` key committed with every gate green. `hooks/checks.sh`
# already detects secrets, leftover conflict markers and weakened tests
# deterministically — and it is the only component that also sees untracked files —
# but it is model-invoked in Phase 3, and nothing consulted it (or
# gates.self_verify.passed) at commit time. This block is that consultation.
#
# PLACEMENT is deliberate: after the gate contract above, before the fix-loop budget
# below. A run whose review has not passed hears THAT first (it is still legitimately
# working), and content hygiene outranks a volume check.
#
# FAIL-OPEN LIVES IN THE SCANNER, FAIL-CLOSED LIVES IN THE GATE. checks.sh emits
# all-`skip` when it cannot inspect the diff, which is right for its Phase-3 caller
# (a metrics manifest must not fabricate rows) and WRONG here — a scanner that could
# not look is not a clean bill of health. So all-skip blocks, as do a missing
# checks.sh and output that is not a row array. checks.sh's own contract is
# unchanged; only this caller reinterprets its silence.
#
# SCOPE is the WORKTREE **UNION THE INDEX** — the scanner is run twice, and a `fail`
# from either blocks. Neither alone is sufficient:
#   - The worktree scan (`git diff <base>` + untracked) is the primary one, consistent
#     with gates.code_review.reviewed_diff_sha and the staleness check above, and with
#     the single-commit rule under which the whole worktree diff IS the run's work.
#     Narrowing to the index would let a secret hide in an unstaged file through every
#     gate and land in a later commit of the same run.
#   - The INDEX scan (`--cached`) exists because `git commit` commits the index, not the
#     worktree. Content staged and then edited out of the worktree is structurally
#     invisible to the worktree diff — verified: stage a file carrying an `AKIA…` key,
#     then remove the key from the file, and the worktree scan reports zero findings
#     while the commit still carries it. Reachable by an ordinary `git add -A` → "oh,
#     that's a secret" → delete it from the file → commit sequence, where the fix is not
#     in the commit but the guard sees the fix.
# So the union is the honest scope: everything that will land, plus everything the run is
# still holding. The blast is bounded by this hook's applicability: it fires only while
# an approved, non-`done` run exists for the current branch, so it never touches a
# commit outside a run.
#
# `warn` NEVER blocks, so checks.sh's test/fixture-path demotion still lets a
# fixture credential through, exactly as before.
#
# Backward-compatible: skipped entirely when `base` is absent (legacy runs), like the
# staleness check — it can only ever add a block, never spuriously allow.
if [ -n "$base" ]; then
  checks_sh="$ENFORCE_SCRIPT_DIR/checks.sh"
  # The current diff hash, for pinning an ack. Same PINNED flags as the staleness
  # check — one formula, so an ack recorded against one cannot read as another.
  # Computed LAZILY, on the first ack lookup: acks are consulted only when something
  # already failed, so the clean path (every commit of a healthy run) must not pay for
  # a second full `git diff | hash-object` on the Bash hot path.
  # THE PIN must move whenever anything the SCANNER can see changes — otherwise an ack
  # granted for a genuine false positive silently clears later, unrelated, REAL findings
  # of the same check name. It is therefore deliberately NOT `git diff <base>`, the
  # formula the staleness check uses. Measured failure of that formula: ack a documented
  # docs placeholder, then create a NEW UNTRACKED file carrying a real `AKIA…` key — the
  # hash does not move (`4e8e62ad…` before and after), the stale ack still matches, and
  # the commit is ALLOWED while the scanner is reporting two matches. A staged-then-
  # deleted-from-worktree file is invisible to it for the same reason.
  #
  # Four parts, covering exactly the scanner's field of view, and every one is needed:
  #   1. `git rev-parse HEAD`                    — moves on any commit
  #   2. `git diff <flags> HEAD`                 — tracked WORKTREE content
  #   3. `git diff --cached <flags> HEAD`        — INDEX content, including a path staged
  #      and then deleted from the worktree, which part 2 cannot see at all
  #   4. `<path>\t<blob-hash>` per untracked file — the untracked path SET *and* content
  #
  # `git status --porcelain` is NOT a substitute for 2-4: it emits status codes and paths
  # but never content, so rewriting the bytes of a file already listed as ` M …`/`?? …`
  # would leave a porcelain-only pin identical.
  #
  # Part 4's `[ -f ]` guard mirrors the one the scanner's untracked leg has, and it exists to
  # prevent a HANG rather than a wrong value: `git ls-files --others` lists an untracked
  # SYMLINK, and `git hash-object` on a symlink pointing at a FIFO blocks forever — so
  # `|| echo unreadable` can never fire, the hook never reaches `exit 2`, and the harness
  # kills it. Measured: with a real `fail` row present and an untracked `src/link ->` a FIFO,
  # the full gate was killed at rc=142 instead of blocking. Fail direction is OPEN, which is
  # the one direction this block must never take. Note the reachability shape — the pin is
  # lazy, so it is only computed once a finding exists, i.e. only when a block is required.
  # A non-regular path degrades to the `unreadable` sentinel rather than being skipped, so
  # adding or removing one still moves the pin.
  #
  # Part 4 prefixes each path with `./` before handing it to `git hash-object`, for the same
  # reason the scanner's untracked leg does: `ls-files` emits paths bare, so an
  # option-shaped name is parsed as a switch (measured — git rejects an unknown switch for a
  # file named -e) and the entry degraded to the literal `unreadable`, meaning that file's
  # content never moved the pin and an ack stayed valid across rewrites of it.
  #
  # Part 4 hashes each path INDIVIDUALLY rather than piping the list through
  # `git hash-object --stdin-paths`: that ABORTS at the first unreadable path (rc=128), so
  # one mode-000 untracked file would drop the content of every path after it, and it
  # cannot consume the quoted form `git ls-files` emits for a path containing a newline.
  # A `-z` listing is never quoted, and an unreadable path degrades to the literal
  # `unreadable` for that entry alone.
  #
  # Being base-independent is also what makes the override REACHABLE when `state.base`
  # does not resolve — the headline reason to need one. An earlier version pinned to
  # `git diff <base>` with a fallback, which needed a resolvability probe because
  # `git diff <unresolvable-ref>` prints nothing yet the pipe still hashes EMPTY input,
  # yielding the empty-blob hash (e69de29bb2…) rather than an empty string. One formula
  # removes that trap along with the branch. Residual, accepted: with git itself
  # unavailable no hash exists and no override is possible — but then `git commit` is not
  # running either.
  hyg_sha=""
  hyg_sha_done=0
  hyg_resolve_sha(){
    [ "$hyg_sha_done" -eq 1 ] && return 0
    hyg_sha_done=1
    hyg_sha="$(cd "$project_dir" 2>/dev/null && {
      git rev-parse HEAD 2>/dev/null
      git diff $DIFF_FLAGS HEAD 2>/dev/null
      git diff --cached $DIFF_FLAGS HEAD 2>/dev/null
      git ls-files --others --exclude-standard -z 2>/dev/null | while IFS= read -r -d '' hyg_p; do
        if [ -f "./$hyg_p" ]; then
          printf '%s\t%s\n' "$hyg_p" "$(git hash-object "./$hyg_p" 2>/dev/null || echo unreadable)"
        else
          printf '%s\tunreadable\n' "$hyg_p"
        fi
      done
    } | git hash-object --stdin 2>/dev/null || true)"
  }
  # An ack is a diff-sha-pinned, durable, reviewable record naming ONE check. A grant
  # for one tree cannot cover a later one (the reviewed_diff_sha lesson applied to
  # acks). Anything unreadable — a malformed acked[], a non-array, a missing hash —
  # counts as NOT acked, so this leg can only ever preserve a block.
  hyg_acked(){
    hyg_resolve_sha
    [ -n "$hyg_sha" ] || return 1
    local n
    # The `if type == "array"` is REQUIRED, not belt-and-braces: a bare `[]?` iterates an
    # OBJECT's values just as happily as an array's elements, so `acked` supplied as
    # `{"k": {check, diff_sha}}` would be honored — contradicting this function's own
    # "a non-array counts as NOT acked" contract. Enumerate array elements only, and
    # require each element to be an object, so no other container shape can grant.
    n="$(jq -r --arg c "$1" --arg s "$hyg_sha" \
      '[ (.gates.hygiene.acked // []) | if type == "array" then .[] else empty end
         | select((type == "object") and ((.check? // "") == $c) and ((.diff_sha? // "") == $s)) ] | length' \
      "$state" 2>/dev/null || echo 0)"
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    [ "$n" -gt 0 ]
  }
  # The ack snippet a user PASTES. Absolute $state path, per the loop-budget ack fix:
  # a relative .auto-task/<branch>/ path pasted from a different checkout that shares
  # the branch name records the ack against the wrong run's state.
  #
  # The `if type == "array"` mirrors hyg_acked's own semantics, and it is what makes the
  # recovery actually work rather than merely look right. A bare `(.acked // [])` errors
  # under jq when `acked` is a non-array — which is EXACTLY the shape hyg_acked treats as
  # "not acked", i.e. a state that is both blocked and in need of this snippet. With the
  # error, `&& mv` never runs and the paste silently no-ops, dead-ending the documented
  # recovery in the one case that most needs it (the same failure mode the loop-budget
  # ack guards against below). Replacing a corrupt non-array with a fresh array is the
  # right repair: it cannot destroy a valid grant, because a non-array never held one.
  hyg_ack_cmd(){
    hyg_resolve_sha
    # The $state path is DOUBLE-QUOTED in the emitted command. Unquoted, the snippet
    # broke for any project under a path containing a space — routine on macOS
    # ("~/My Project/…") — because jq then received two file arguments and mv three.
    # Measured: pasting it exited 2 and the block stayed up, dead-ending the documented
    # recovery. (The loop-budget ack below still has the unquoted form; same one-line
    # shape, parked as a separate follow-up rather than edited here.)
    printf '  t="$(mktemp)" && jq \x27.gates.hygiene.acked = ((.gates.hygiene.acked | if type == "array" then . else [] end) + [{check: "%s", diff_sha: "%s", reason: "<why this is a false positive>", at: "\x27"$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)"\x27"}])\x27 "%s" > "$t" && mv "$t" "%s"\n' \
      "$1" "$hyg_sha" "$state" "$state"
  }

  if [ ! -f "$checks_sh" ] || [ ! -r "$checks_sh" ]; then
    if ! hyg_acked "scanner-unavailable"; then
      printf 'Blocked by auto-task-plugin: the diff-hygiene scanner is missing, so the commit content cannot be checked for secrets, conflict markers or weakened tests.\n  expected at: %s\nThis hook fails closed — a scanner that could not look is not a clean bill of health.\nRestore hooks/checks.sh (it ships with the plugin) and retry. If it genuinely cannot be restored, record a diff-pinned override:\n' "$checks_sh" >&2
      hyg_ack_cmd "scanner-unavailable" >&2
      exit 2
    fi
  else
    hyg_out="$(cd "$project_dir" 2>/dev/null && bash "$checks_sh" --base "$base" 2>/dev/null || true)"
    # Shape validation: a JSON array of row objects. Anything else (empty output, a
    # crash, a jq-less truncation) is unusable and blocks.
    #
    # The WORKTREE scan is validated FIRST, and the index scan is not even run until this
    # and the all-skip check below have passed. Order matters for two reasons found in
    # review: with a globally broken scanner, validating the index first fired a message
    # asserting "the worktree scan ran" when it had not — sending the reader to debug
    # `--cached` while the plain invocation was equally broken; and running the index scan
    # up front wasted a full second scanner pass (one `git diff` per changed file) on
    # every run that was going to block here anyway.
    hyg_rows="$(printf '%s' "$hyg_out" | jq -r 'if (type == "array") and (length > 0) and (all(.[]; (type == "object") and has("name") and has("result"))) then length else "bad" end' 2>/dev/null || echo bad)"
    case "$hyg_rows" in ''|*[!0-9]*) hyg_rows="bad" ;; esac
    if [ "$hyg_rows" = "bad" ]; then
      if ! hyg_acked "scanner-unavailable"; then
        printf 'Blocked by auto-task-plugin: the diff-hygiene scanner did not return a usable result, so the commit content cannot be checked.\n  scanner: %s --base %s\nThis hook fails closed. Run that command by hand to see what it reports (it should print a JSON array of check rows), fix the cause, and retry. If the scanner cannot be made to run here, record a diff-pinned override:\n' "$checks_sh" "$base" >&2
        hyg_ack_cmd "scanner-unavailable" >&2
        exit 2
      fi
    else
      hyg_skips="$(printf '%s' "$hyg_out" | jq -r '[ .[] | select(.result == "skip") ] | length' 2>/dev/null || echo 0)"
      case "$hyg_skips" in ''|*[!0-9]*) hyg_skips=0 ;; esac
      if [ "$hyg_skips" -eq "$hyg_rows" ]; then
        # EVERY row skipped: checks.sh could not inspect the diff at all. Four causes
        # (checks.sh preconditions): git unavailable, not a git work tree, base not a
        # commit, no --base. `base not a commit` is genuinely reachable in a real run
        # (a base ref rebased or pruned away), so the block must be DIAGNOSABLE:
        # carry the scanner's own detail text through verbatim, or the user hunts for
        # a nonexistent secret instead of repairing state.base.
        if ! hyg_acked "scanner-unavailable"; then
          hyg_why="$(printf '%s' "$hyg_out" | jq -r '[ .[] | select(.result == "skip") | .detail? // "" ] | map(select(. != "")) | unique | join("; ")' 2>/dev/null || true)"
          [ -n "$hyg_why" ] || hyg_why="(the scanner reported no reason)"
          printf 'Blocked by auto-task-plugin: the diff-hygiene scanner could not inspect this diff, so the commit content is unchecked.\n  scanner said: %s\n  state.base:   %s\nThis hook fails closed — "could not look" is not "nothing to find".\nFix the cause the scanner named above. For "base not a commit" that means state.base no longer resolves in this repo (a rebased or pruned ref): fetch the missing commit, or repair .base in the state file to the real fork point. Only if the base commit is genuinely unrecoverable, record a diff-pinned override:\n' "$hyg_why" "$base" >&2
          hyg_ack_cmd "scanner-unavailable" >&2
          exit 2
        fi
      else
        # The INDEX scan — the second half of the union scope described above, run only
        # now that the worktree scan has proved usable and non-empty. Its rows are merged
        # into the worktree rows below, so a `fail` from either blocks.
        #
        # It IS shape-validated, with the same predicate as the worktree scan, and that
        # validation is load-bearing rather than symmetry for its own sake. An earlier
        # version skipped it on the reasoning that "an unusable index scan must not be
        # able to relax the worktree verdict" — but the merge is a single `jq -s` over
        # BOTH documents, so unparseable index output failed the whole slurp and the
        # `|| echo '[]'` fallback discarded the worktree's already-validated `fail` rows
        # with it. Measured: a stub returning a real `secret-scan` fail for the worktree
        # and non-JSON for `--cached` produced exit 0 — the commit carrying the credential
        # was ALLOWED, the exact inversion this whole block exists to prevent. Two changes
        # close it: the index output is validated here, and the merge below can no longer
        # be the step that drops the worktree rows.
        # SKIP the index scan when the index is provably identical to the worktree for
        # tracked paths — `git diff` with no arguments compares exactly those two, so exit 0
        # means the worktree scan already examined byte-identical content and a second pass
        # can only repeat it. This is a correctness-preserving halving of the cost, not a
        # shortcut: the index scan exists solely to catch content that differs from the
        # worktree, and there is none. Only exit 0 is trusted; any other status (differences,
        # or an error) runs the scan, so the fail-safe direction is "scan more".
        #
        # Why it matters: the scanner spends one `git diff` per changed file, so running it
        # twice is linear in diff size — measured 6s total at 200 changed files and 18s at
        # 600, and `hooks/hooks.json` sets no explicit timeout for this hook. A PreToolUse
        # hook that is killed never reaches `exit 2`, so at some diff size a fail-closed gate
        # would fail OPEN by timing out. Phase 5 stages the planned files immediately before
        # committing, which is precisely the worktree==index case, so the common path now
        # pays for one scan instead of two. The residual risk on a genuinely divergent
        # very-large diff is recorded as a follow-up rather than papered over.
        # The skip BYPASSES validation rather than validating a synthetic `[]`. Relaxing the
        # predicate to accept a zero-length array so the placeholder would pass is a
        # fail-OPEN: a genuinely broken scanner that printed `[]` would then validate as
        # usable instead of blocking. Keep `length > 0` meaning "real rows", and gate the
        # validation on whether a scan actually ran.
        hyg_idx_skipped=0
        if (cd "$project_dir" 2>/dev/null && git diff --quiet 2>/dev/null); then
          hyg_out_idx='[]'; hyg_idx_skipped=1
        else
          hyg_out_idx="$(cd "$project_dir" 2>/dev/null && bash "$checks_sh" --base "$base" --cached 2>/dev/null || true)"
        fi
        if [ "$hyg_idx_skipped" -eq 1 ]; then
          hyg_rows_idx=0
        else
          hyg_rows_idx="$(printf '%s' "$hyg_out_idx" | jq -r 'if (type == "array") and (length > 0) and (all(.[]; (type == "object") and has("name") and has("result"))) then length else "bad" end' 2>/dev/null || echo bad)"
          case "$hyg_rows_idx" in ''|*[!0-9]*) hyg_rows_idx="bad" ;; esac
        fi
        if [ "$hyg_rows_idx" = "bad" ]; then
          # Fail CLOSED, exactly as for an unusable worktree scan: half of what the commit
          # carries went unexamined, and "could not look" is not "nothing to find".
          if ! hyg_acked "scanner-unavailable"; then
            printf 'Blocked by auto-task-plugin: the diff-hygiene scanner could not inspect the STAGED index, so half of what this commit carries is unchecked.\n  scanner: %s --base %s --cached\nThe worktree scan succeeded, so this is specific to the --cached invocation. `git commit` commits the INDEX, so the index scan is not optional. This hook fails closed.\nRun that command by hand to see what it reports (it should print a JSON array of check rows), fix the cause, and retry. If it cannot be made to run here, record a diff-pinned override:\n' "$checks_sh" "$base" >&2
            hyg_ack_cmd "scanner-unavailable" >&2
            exit 2
          fi
          hyg_out_idx='[]'   # acked: proceed on the worktree verdict alone
        fi
        # The real finding path. Collect `fail` rows not covered by a current ack.
        # Only `fail` blocks: `warn`/`info`/`pass`/`skip` never do, so the test-path
        # demotion of a secret to `warn` still commits.
        #
        # Rows from BOTH scans are merged, with index-only rows tagged so the message says
        # which side found them — a finding the worktree does not show is confusing
        # without that.
        # `if type == "array"` on BOTH sides, not a bare `[]?`: that operator iterates an
        # OBJECT's values as happily as an array's elements, which is the same bug class
        # already fixed in hyg_acked. Enumerate array elements only.
        # The index tag is applied ONLY to rows the worktree scan did not already report
        # identically. Applied unconditionally it produced a message that asserted something
        # false: a finding present in BOTH scopes printed the plain worktree detail AND a
        # second copy claiming it was "not the worktree".
        hyg_merged="$( { printf '%s\n' "$hyg_out"; printf '%s\n' "$hyg_out_idx"; } \
          | jq -cs '(.[0] // []) as $w | (.[1] // []) as $i
                    | ($w | if type == "array" then [ .[] | select(type == "object") ] else [] end) as $wr
                    | ($wr | map({n: (.name? // ""), d: (.detail? // "")})) as $seen
                    | [ $wr[],
                        ($i | if type == "array" then .[] else empty end | select(type == "object")
                            | if ([{n: (.name? // ""), d: (.detail? // "")}] - $seen) == []
                              then empty
                              else .detail = ((.detail? // "") + "  [found in the STAGED index, not the worktree]")
                              end) ]' \
          2>/dev/null || true)"
        # The merge must never be the step that loses a validated finding. If it produced
        # anything unusable, fall back to the worktree rows — which were shape-validated
        # above — rather than to an empty array. `|| echo '[]'` here was a measured
        # fail-OPEN: it discarded a real `secret-scan` fail and allowed the commit.
        case "$(printf '%s' "$hyg_merged" | jq -r 'type' 2>/dev/null || echo bad)" in
          array) ;;
          *) hyg_merged="$hyg_out" ;;
        esac
        # The fail-name enumeration. `|| echo '(unnamed-check)'` rather than `|| true`: this
        # is the last jq before the blocking decision, so its failure direction must be
        # CLOSED like every other guard in the block. With `|| true` a jq failure yielded no
        # names and the commit was allowed — unreachable today (this input already passed
        # the shape validation above), but it was the one open-direction fallback left, and
        # "unreachable" is how the earlier fail-opens in this block were described too.
        hyg_blocked=""
        while IFS= read -r hyg_name; do
          [ -n "$hyg_name" ] || continue
          hyg_acked "$hyg_name" && continue
          hyg_blocked="$hyg_blocked $hyg_name"
        done <<EOF
$(printf '%s' "$hyg_merged" | jq -r '[ .[] | select(.result == "fail") | (if ((.name? // "") == "") then "(unnamed-check)" else .name end) ] | unique | .[]' 2>/dev/null || echo '(unnamed-check)')
EOF
        # A `fail` row is never skipped for want of a name: an empty/null name maps to
        # `(unnamed-check)` above, which blocks via the default remedy arm. The shape
        # validation only requires `has("name")`, not a non-empty string, so without this
        # a nameless fail row would `continue` past the one loop that decides blocking.
        if [ -n "$hyg_blocked" ]; then
          printf 'Blocked by auto-task-plugin: the diff you are about to commit fails a hygiene check.\n' >&2
          for hyg_name in $hyg_blocked; do
            hyg_detail="$(printf '%s' "$hyg_merged" | jq -r --arg n "$hyg_name" '[ .[] | select((.name == $n) and (.result == "fail")) | .detail? // "" ] | map(select(. != "")) | unique | join("\n      ")' 2>/dev/null || true)"
            # `(unnamed-check)` matches no real row, so its detail lookup is empty by
            # construction — say something useful instead of printing a bare bracket
            # followed by "resolve the condition the detail above names".
            [ -n "$hyg_detail" ] || hyg_detail="(the scanner reported a failing row with no name or detail — inspect its raw output)"
            printf '\n  [%s] %s\n' "$hyg_name" "$hyg_detail" >&2
            case "$hyg_name" in
              secret-scan)
                printf '  If it IS a credential: remove it from the diff AND ROTATE IT. Committing a secret and deleting it in a later commit leaves it in history and in every clone — rotation is the only real fix.\n  If it is NOT a credential, this is a known false-positive shape and the ack below is the right answer: the pattern needs only the word api_key/secret/password/token, then a colon or equals, then 16+ unbroken characters inside quotes. A documented placeholder in a README (an API_KEY export line whose value is a dummy string of that length), an example in prose, or a long non-secret constant all match it. Docs and config paths get NO test/fixture demotion, so a README edit lands here. Shorten the dummy value, drop its quotes, make it obviously fake, or ack it.\n' >&2 ;;
              conflict-markers)
                printf '  If it IS an unfinished merge: finish the resolution — the listed file still carries conflict markers, and committing them yields code that does not parse.\n  If the file legitimately CONTAINS marker text at the start of a line — documentation showing what a conflict looks like, a test fixture outside a test path, a parser for merge output — that is a false positive and the ack below is the right answer.\n' >&2 ;;
              test-integrity)
                printf '  If a test really was weakened: restore it. A skip/focus marker was ADDED, or assertions were REMOVED with none added back — weakening a test to reach green is the failure this check exists to catch, so fix the code the test was failing on, not the test.\n  BUT CHECK THIS FIRST — three ordinary, harmless diffs produce the identical row, because the scan is per-file and rename-blind (it reads `git diff --no-renames`, which splits a rename into a delete plus an add):\n    * you RENAMED or MOVED a test file — the delete side looks exactly like a gutted test, even though the assertions are intact at the new path;\n    * you DELETED an obsolete test file outright;\n    * you moved assertions OUT of this file into another one.\n  None of those weakened anything, and none is fixed by "restoring" the file — the ack below is the correct and intended answer for them. Read the named path and decide which case you are in before touching the tests.\n' >&2 ;;
              *)
                printf '  Remedy: resolve the condition the detail above names.\n' >&2 ;;
            esac
          done
          printf '\nUnlike every other block in this hook, NO state edit clears a real finding — the remedy is to fix the diff.\nIf and only if a row is a genuine false positive, record a durable, diff-pinned, reviewable override (it counts only for THIS exact diff, so any later edit re-blocks and needs a fresh one):\n' >&2
          for hyg_name in $hyg_blocked; do
            hyg_ack_cmd "$hyg_name" >&2
          done
          exit 2
        fi
      fi
    fi
  fi
fi

# ---- Fix-loop budget -------------------------------------------------------
# The effort tier has always documented a fix-loop cap (LIGHT 2 / STANDARD 4 /
# HEAVY 6) and NOTHING enforced it. A real run reached iteration.fix=33 against a
# HEAVY cap of 6 — 5.5x over — and no mechanism could stop it: this hook never read
# the counter, and the Stop hook reads it only to detect *movement*, never magnitude.
# The plugin had a rigorous anti-stall guard and no anti-churn guard at all.
#
# BOTH LOOP COUNTERS COUNT, via max(iteration.fix, iteration.review). The skill keeps
# two: `iteration.fix` is bumped only on the Phase-3 self-verify failure path, while
# every Phase-4 review round that REOPENS and every Gate-B feedback round bumps
# `iteration.review`. (Since the Phase-4 graded round contract, a round whose findings
# were all deferred records a `gates.code_review.rounds[]` row and bumps nothing — so
# the counter now measures rounds that cost a fix, which is the volume being bounded.)
# A gate reading `fix` alone would therefore wave through the churn shape this feature
# exists to bound — fix=0 / review=28 is 28 rounds of iteration and would land
# unblocked. The budget bounds review VOLUME, so it is measured against whichever
# counter has run furthest. Taking the max (rather than the sum) keeps one ack
# sufficient and keeps the ladder on the documented cap rungs.
#
# Placed LAST, after the gate contract above, deliberately. A run that has not yet
# passed review is still legitimately working, and "you are over budget" would be
# noise ahead of "your review has not passed". By the time control reaches here the
# work is done and the only question left is whether an over-budget run may LAND.
#
# The block is recoverable-with-instructions, like every other block in this hook:
# the message carries the exact `jq` to record an ack. An ack raises the budget to the
# next cap multiple that clears the current counter, so ONE ack always suffices and the
# check-in returns one cap later (HEAVY: budget 6/12/18/24, check-ins at loop count
# 7/13/19/25) rather than nagging every turn. The "clears the current counter" part
# matters because this gate runs at commit time while the loop counters accumulate
# during the loop: a run can arrive here far past its budget, and a fixed single-cap
# step would then demand one ack per cap of overshoot (see lb_next_budget).
#
# Fail policy is deliberately MIXED here, and the asymmetry is the point:
#   - A LEGACY run (no `effort` object at all — it predates the tier feature) must
#     NOT be blocked. Absence is probed separately from the `// "standard"` default
#     read above, because that default yields cap 4 and WOULD block such a run.
#   - A CORRUPT counter must block. `[ "abc" -gt 6 ]` does not evaluate false, it
#     ERRORS, so an unguarded `if` takes the else branch and the guard fails OPEN —
#     wrong in a hook documented as fail-closed. Every value is validated first, and
#     `lb_is_number` rejects on MAGNITUDE as well as character class, because a
#     20-digit all-digits counter errors in `[ ]` exactly like "abc" does.
#   - A MISSING helper must block. If lib/loop-budget.sh failed to source we cannot
#     resolve the cap, and a fail-closed hook blocks rather than waving it through.
#   - A run carrying EITHER counter is in scope. Only a run with no `iteration`
#     counters at all (a legacy state file) is skipped; an absent sibling counter
#     reads as 0 rather than disabling the gate.
has_effort="$(jq -r 'if (.effort? // null) == null then "no" else (if (.effort.tier? // null) == null then "no" else "yes" end) end' "$state" 2>/dev/null || echo "no")"
has_iter="$(jq -r 'if (.iteration? // null) == null then "no" else (if ((.iteration.fix? // null) == null and (.iteration.review? // null) == null) then "no" else "yes" end) end' "$state" 2>/dev/null || echo "no")"
if [ "$has_effort" = "yes" ] && [ "$has_iter" = "yes" ]; then
  if ! command -v lb_cap_for_tier >/dev/null 2>&1 || ! command -v lb_effective_budget >/dev/null 2>&1; then
    printf 'Blocked by auto-task-plugin: hooks/lib/loop-budget.sh could not be sourced, so the fix-loop budget cannot be verified before this commit.\nThis hook fails closed. Restore hooks/lib/loop-budget.sh (it ships with the plugin) and retry.\n' >&2
    exit 2
  fi
  fix_count="$(jq -r '.iteration.fix // 0' "$state" 2>/dev/null || echo 0)"
  review_count="$(jq -r '.iteration.review // 0' "$state" 2>/dev/null || echo 0)"
  acked_through="$(jq -r '.gates.loop_budget.acked_through // 0' "$state" 2>/dev/null || echo 0)"
  if ! lb_is_number "$fix_count"; then
    printf 'Blocked by auto-task-plugin: .iteration.fix in .auto-task/%s/STATE.json is not a non-negative integer (got: %s), so the fix-loop budget cannot be verified.\nThis hook fails closed. Repair the counter and retry.\n' "$branch" "$fix_count" >&2
    exit 2
  fi
  if ! lb_is_number "$review_count"; then
    printf 'Blocked by auto-task-plugin: .iteration.review in .auto-task/%s/STATE.json is not a non-negative integer (got: %s), so the fix-loop budget cannot be verified.\nThis hook fails closed. Repair the counter and retry.\n' "$branch" "$review_count" >&2
    exit 2
  fi
  if ! lb_is_number "$acked_through"; then
    printf 'Blocked by auto-task-plugin: .gates.loop_budget.acked_through in .auto-task/%s/STATE.json is not a non-negative integer (got: %s), so the fix-loop budget cannot be verified.\nThis hook fails closed. Repair the value (or remove gates.loop_budget to reset the ack) and retry.\n' "$branch" "$acked_through" >&2
    exit 2
  fi
  cap="$(lb_cap_for_tier "$tier")"
  budget="$(lb_effective_budget "$cap" "$acked_through")"
  # The loop count is max(fix, review) — see the BOTH LOOP COUNTERS note above.
  loop_count="$fix_count"
  [ "$review_count" -gt "$loop_count" ] && loop_count="$review_count"
  if [ "$loop_count" -gt "$budget" ]; then
    next_budget="$(lb_next_budget "$cap" "$acked_through" "$loop_count")"
    # The ack snippet is a command the model PASTES, so it targets the absolute $state
    # path rather than a relative .auto-task/<branch>/ one. Relative was a two-runs-one-
    # path hazard of the same class as the /tmp/s temp file already fixed on this line:
    # pasted from a subdirectory the jq leg merely fails, but pasted from a DIFFERENT
    # checkout that happens to share the branch name it records the ack against the
    # wrong run's state. The descriptive blocks above keep the short relative form on
    # purpose — they are prose for a human to read, not commands to run.
    # The ack we print must be a value this same hook will ACCEPT on the next run.
    # lb_is_number bounds an INPUT at 18 digits (the widest bash can compare), but the
    # rung computed for an 18-digit counter can be 19 — so the recovery snippet would
    # advise a value the validator rejects, dead-ending the documented recovery in the
    # exact way lb_strip_zeros exists to prevent. Unreachable with any real counter; if
    # it ever happens the counter itself is the corruption, so say that instead of
    # printing an unusable ack.
    if ! lb_is_number "$next_budget"; then
      printf 'Blocked by auto-task-plugin: the fix-loop counter in .auto-task/%s/STATE.json is implausibly large (loop count: %s), so no ack value within the supported range can clear it.\nThis hook fails closed. Repair .iteration.fix / .iteration.review to the run\x27s real round counts and retry.\n' "$branch" "$loop_count" >&2
      exit 2
    fi
    printf 'Blocked by auto-task-plugin: this run is over its fix-loop budget.\n  loop count:      %s   (max of iteration.fix=%s and iteration.review=%s)\n  tier=%s cap:     %s\n  budget in force: %s   (max of the cap and any previous ack)\nThe effort tier documents a fix-loop cap; exceeding it means the run has iterated more than its budget allows, which is the signal to check in with the user rather than keep churning.\nSurface to the user: show the per-round finding severities so they can see whether returns have diminished, then let THEM decide to continue or stop. On their go-ahead, record the ack (raises the budget to the next cap rung that clears the current count, so ONE ack suffices and the next check-in is at %s):\n  t="$(mktemp)" && jq \x27.gates.loop_budget = {acked_through: %s, acked_at: "\x27"$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)"\x27", reason: "<why continuing is right>"}\x27 %s > "$t" && mv "$t" %s\nDo NOT set this yourself without asking — it is the user\x27s call, exactly like every other gate flag.\n' \
      "$loop_count" "$fix_count" "$review_count" "$tier" "$cap" "$budget" "$(( next_budget + 1 ))" "$next_budget" "$state" "$state" >&2
    exit 2
  fi
fi

exit 0
