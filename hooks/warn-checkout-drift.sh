#!/usr/bin/env bash
# Warns when the checkout moved underneath an active auto-task run.
#
# Registered as an informational PreToolUse hook on Bash. auto-task keys all run
# state by the CURRENT branch (.auto-task/<branch>/), and the gate + Stop hooks
# resolve state via `git branch --show-current`. So if an in-place run is live on
# branch X and the working tree is switched to Y (e.g. from another terminal),
# those hooks would silently find no state for Y and fail OPEN — the run's own
# safety net disappears exactly when it is needed. This hook is the proactive
# half of the guard: it fires on every Bash command and, when an active run
# exists on a branch other than the one checked out, tells the model to switch
# back (or clear an abandoned run). The mechanical half is in enforce-gates.sh,
# which hard-BLOCKS a commit in the same situation.
#
# This hook mirrors inject-history-reminder's contract: it is purely
# informational and NEVER blocks — it always exits 0. When it cannot determine
# drift (not a repo, no .auto-task/ dir, jq absent, unparseable state) it stays
# SILENT so unrelated sessions and non-auto-task repos pay ~nothing and never see
# spurious output. Only the enforce-gates commit gate is allowed to block.
#
# Note on the same-working-tree scope: .auto-task/ lives in the WORKING TREE, so
# each linked git worktree has its own .auto-task/. A scan therefore only ever
# sees runs started in the current tree — a parallel run in another worktree can
# never trigger a false-positive here.
#
# `set -e` is intentionally omitted so a stray non-zero from jq/find can't crash
# the script into a non-zero (and thus tool-affecting) exit.

set -uo pipefail

# Resolve the project root that owns .auto-task/<branch>/, identically to the
# sibling hooks: start from CLAUDE_PROJECT_DIR (or $PWD), resolve to the git
# worktree root so a command from a subdirectory still finds .auto-task/ at the
# top, and keep an explicitly-set CLAUDE_PROJECT_DIR authoritative.
project_dir_base="${CLAUDE_PROJECT_DIR:-$PWD}"
project_dir="$(cd "$project_dir_base" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$project_dir" ] || project_dir="$project_dir_base"
branch="$(cd "$project_dir" && git branch --show-current 2>/dev/null || true)"
[ -n "$branch" ] || exit 0   # detached HEAD or not a repo — nothing to guard

autotask_dir="$project_dir/.auto-task"
[ -d "$autotask_dir" ] || exit 0            # no auto-task history here → silent, cheap
command -v jq >/dev/null 2>&1 || exit 0     # can't read state without jq → stay silent (never nag)

# `active` reads BOTH approved+phase in ONE jq call (this runs on every Bash
# command, so we minimise process spawns): returns 0 iff the file parses AND
# approved==true AND phase!="done". Malformed / missing → non-zero (skipped).
active(){ [ -f "$1" ] && jq -e '(.approved==true) and (.phase!="done")' "$1" >/dev/null 2>&1; }

# FAST PATH (the common case, kept O(1)): if the CURRENT branch owns an active
# run there is no drift by definition — return immediately without scanning the
# whole .auto-task/ tree. This is what keeps the every-command cost flat as run
# history accumulates; only when the current branch has no active run do we pay
# for the full scan below.
active "$autotask_dir/$branch/STATE.json" && exit 0

# Current branch has no active run. Scan every per-branch STATE.json in THIS
# working tree for an active run on ANOTHER branch. A run's branch identity is
# its folder path under .auto-task/ (the canonical key every hook resolves by;
# equal to .branch by the SKILL setup contract and always present, even for
# legacy states). Drift = some other branch has an active run.
others=""
while IFS= read -r sf; do
  [ -n "$sf" ] || continue
  active "$sf" || continue
  rel="${sf#"$autotask_dir"/}"; br="${rel%/STATE.json}"
  [ "$br" != "$rel" ] || continue   # skip a stray top-level STATE.json (no <branch>/ segment)
  [ -n "$br" ] || continue
  [ "$br" = "$branch" ] && continue # current branch (already known inactive; defensive)
  case " $others " in *" $br "*) ;; *) others="$others $br" ;; esac
done <<< "$(find "$autotask_dir" -name STATE.json 2>/dev/null)"

# No drift: no active run on any other branch.
[ -n "$others" ] || exit 0

drifted="${others# }"   # strip the single leading space accumulated above
msg="auto-task checkout-drift WARNING: an active auto-task run exists on branch(es) [$drifted], but the working tree is currently on \"$branch\" (which has no active run). auto-task keys its state and safety hooks by the checked-out branch, so continuing here risks operating on / committing to the wrong branch — and \`git commit\` is HARD-BLOCKED until this is resolved. Resolve by ONE of: (a) \`git switch $drifted\` (or work in a dedicated git worktree) to resume that run; or (b) if that run is abandoned, \`rm -rf .auto-task/$drifted/\` to clear it."

# Surface to the model via PreToolUse additionalContext (hookEventName MUST be
# "PreToolUse" here — do not copy check-version.sh's "SessionStart"), and ALSO to
# the transcript via stderr as a belt-and-suspenders in case additionalContext
# injection is not honored on a given Claude Code version. Never block: exit 0.
printf '%s\n' "$msg" >&2
jq -n --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}' 2>/dev/null || true
exit 0
