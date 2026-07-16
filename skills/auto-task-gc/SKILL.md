---
name: auto-task-gc
description: Report and reclaim disk used by auto-task git worktrees and artifacts. Shows per-worktree size, age, and merge status, then safely removes reclaimable ones (branch refs preserved) on explicit confirmation. Use when asked "auto-task gc", "clean up worktrees", "reclaim disk", "how much space do worktrees take", "prune old worktrees", or "worktree cleanup".
license: MIT
---

# Auto-task gc (worktree/disk cleanup)

The auto-task pipeline creates one git worktree per run under `.claude/worktrees/<type>-<slug>` and **keeps it forever** — each worktree carries a full working tree (often a multi-GB `node_modules`), so they accumulate. This skill reports what they cost and safely reclaims the ones that are done with.

It runs the bundled `hooks/auto-task-gc.sh` engine. **Reporting is read-only. Deletion happens only after you show the user the plan and they confirm** — the engine also refuses to delete without an explicit `--yes`, so confirmation is enforced at both layers.

## What is safe to reclaim (defaults, user-overridable)

- **Merged + clean** worktrees — always reclaimable (branch merged into the default branch by local ancestry, or via a merged PR that `gh` reports).
- **Clean + unmerged** worktrees — reclaimable only once older than their **per-type** stale threshold (`worktree_stale_days_<type>`, fallback `worktree_stale_days_default`; defaults: `feat`/`refactor` 30d, `fix` 14d, `chore`/`deps`/`docs`/`cleanup` 7d).
- **Dirty** worktrees (uncommitted work) — **kept** by default. Only when `worktree_cleanup_prune_dirty=true` does `--prune --yes` WIP-commit the dirty tree (tracked + untracked, via `git add -A`) to its branch *before* removal.
- The **current** worktree and the **main** working tree are never removed.

Removal always **preserves the branch ref** (committed work is recoverable with `git worktree add <path> <branch>`) and prunes the matching `.auto-task/<branch>/` history folder. **Caveat:** removing a worktree deletes its whole directory, so any **gitignored** files inside it go too — that's the point for `node_modules`, but it also means a local `.env` or other ignored scratch in a worktree is removed and is *not* captured by the dirty WIP-commit (`git add -A` never stages ignored paths). Always run the report first (it lists exactly which worktrees will be removed) so nothing you rely on is a surprise. Change any threshold with `bash hooks/settings.sh set worktree_stale_days_feat 45` (or edit the settings file); see `hooks/settings.sh` for the full key list.

## Usage

- `/auto-task-gc` — report only (sizes, ages, merge status, what is reclaimable). Read-only.
- `/auto-task-gc --prune` — preview the removal plan (deletes nothing).
- `/auto-task-gc --prune --yes` — actually remove the reclaimable worktrees.
- `/auto-task-gc --all` — widen "reclaimable" to every clean worktree regardless of merge/age (still never dirty unless `worktree_cleanup_prune_dirty=true`).

## What to do when invoked

1. **Locate the engine** `hooks/auto-task-gc.sh`. `CLAUDE_PLUGIN_ROOT` is exported only to hooks, not into the Bash-tool environment, so probe across both install layouts (the same three-probe pattern the orchestrator uses for `check-version.sh`):

   ```bash
   s=""
   [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/hooks/auto-task-gc.sh" ] \
     && s="$CLAUDE_PLUGIN_ROOT/hooks/auto-task-gc.sh"
   if [ -z "$s" ]; then
     cache="$HOME/.claude/plugins/cache/auto-task-plugin/auto-task"
     if [ -d "$cache" ]; then
       d="$(ls -1 "$cache" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' \
            | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
       [ -n "$d" ] && [ -f "$cache/$d/hooks/auto-task-gc.sh" ] && s="$cache/$d/hooks/auto-task-gc.sh"
     fi
   fi
   if [ -z "$s" ]; then
     sk="$HOME/.claude/skills/auto-task-gc"
     if [ -L "$sk" ]; then
       tgt="$(readlink "$sk")"; case "$tgt" in /*) ;; *) tgt="$(dirname "$sk")/$tgt" ;; esac
       root="$(cd "$(dirname "$tgt")/.." 2>/dev/null && pwd)"
       [ -n "$root" ] && [ -f "$root/hooks/auto-task-gc.sh" ] && s="$root/hooks/auto-task-gc.sh"
     fi
   fi
   ```

   If `$s` is still empty, tell the user the engine could not be located (the plugin may not be fully installed) and stop.

2. **Always report first.** Run `bash "$s"` (read-only) from the repo root and present its output verbatim — it is already a formatted table with sizes, ages, merge status, and a reclaimable total.

3. **If the user asked to prune** (`--prune` / "clean up" / "reclaim"):
   - Run `bash "$s" --prune` (add `--all` only if they asked to reclaim everything). This prints the **dry-run plan** — it deletes nothing.
   - Present the plan and **ask the user to confirm** the exact worktrees to be removed. This is a destructive-action confirmation per `~/.claude/CLAUDE.md` "Executing actions with care" — do not skip it, and do not pass `--yes` until the user has confirmed.
   - Only after explicit confirmation, run `bash "$s" --prune --yes` (carrying `--all` if used) and report what was removed.

4. **Do not fabricate figures** — report only what the engine prints. Do not add `--force` or `--no-verify` to any git command.

## Rules

- **Report is read-only; prune requires confirmation.** Never run `--prune --yes` before showing the plan and getting the user's go-ahead.
- Removal preserves branch refs and prunes only the matching `.auto-task/<branch>/`. Committed work is always recoverable.
- Dirty worktrees are protected: kept by default; only WIP-committed-then-removed when `worktree_cleanup_prune_dirty=true`, and if the WIP commit fails the worktree is kept, never force-removed. Tracked and untracked-non-ignored work is preserved; **gitignored** files inside a removed worktree are deleted with it (not WIP-committed) — surface this if the user might have ignored scratch (a local `.env`) in a worktree slated for removal.
- This skill never edits pipeline files, `STATE.json`, or settings (except when the user explicitly asks to change a retention setting via `settings.sh set`).
