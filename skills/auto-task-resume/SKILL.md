---
name: auto-task-resume
description: Pick an auto-task run to resume from a clean terminal list — across every git worktree on this clone. Shows each run's state, title, effort, and last activity, then continues the one you choose. Use when asked to "resume auto-task", "resume a run", "which auto-task runs are open", "continue a run", "auto-task resume", or when `claude --resume` didn't land you back in the right run.
license: MIT
---

# Auto-task resume (run picker)

`claude --resume` resumes a *conversation*, not an auto-task *run*. An auto-task run lives in its own git worktree keyed to a branch (`.auto-task/<branch>/STATE.json` inside that worktree), and bare `/auto-task` only sees the run on the branch you happen to be on. So when several runs are in flight across worktrees, there is no way to see them all and pick one.

This skill is that picker: it enumerates every run on the clone, shows a clean table (state · title · effort · last activity), lets you choose one with an arrow-key prompt, positions the session into that run's worktree, and hands off to the normal `/auto-task` resume — which continues the run from wherever it left off.

It runs the bundled `hooks/auto-task-resume-list.sh` engine. **The engine is read-only** — it only reads STATE.json files; it never writes state, never touches git history, never removes anything.

## What it shows

One row per run, found by scanning every `git worktree list` path (plus the main tree) for `.auto-task/**/STATE.json`. A worktree with no STATE.json is never listed — a run is marked by its state file, not by a bare worktree. Each row shows:

- **State** — the run's `phase` (`execute`, `gate-b`, `done`, …). `●` = resumable (not yet done); `○` = done; `⚠` = the STATE.json could not be parsed (a truncated/interrupted write).
- **Title** — the human run label.
- **Effort** — the tier (light / standard / heavy).
- **Last activity** — a relative age from the newest history entry.
- **Markers** — `· current` (the run you are already in) and `· orphan` (state survives but the run's worktree was pruned).

Done and current runs appear for context but are **not** offered as resume targets.

## What to do when invoked

1. **Locate the engine** `hooks/auto-task-resume-list.sh`. `CLAUDE_PLUGIN_ROOT` is exported only to hooks, not into the Bash-tool environment, so probe across both install layouts (the same three-probe pattern the orchestrator uses for `check-version.sh`):

   ```bash
   s=""
   [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/hooks/auto-task-resume-list.sh" ] \
     && s="$CLAUDE_PLUGIN_ROOT/hooks/auto-task-resume-list.sh"
   if [ -z "$s" ]; then
     cache="$HOME/.claude/plugins/cache/auto-task-plugin/auto-task"
     if [ -d "$cache" ]; then
       d="$(ls -1 "$cache" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' \
            | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
       [ -n "$d" ] && [ -f "$cache/$d/hooks/auto-task-resume-list.sh" ] && s="$cache/$d/hooks/auto-task-resume-list.sh"
     fi
   fi
   if [ -z "$s" ]; then
     sk="$HOME/.claude/skills/auto-task-resume"
     if [ -L "$sk" ]; then
       tgt="$(readlink "$sk")"; case "$tgt" in /*) ;; *) tgt="$(dirname "$sk")/$tgt" ;; esac
       root="$(cd "$(dirname "$tgt")/.." 2>/dev/null && pwd)"
       [ -n "$root" ] && [ -f "$root/hooks/auto-task-resume-list.sh" ] && s="$root/hooks/auto-task-resume-list.sh"
     fi
   fi
   ```

   If `$s` is still empty, tell the user the engine could not be located (the plugin may not be fully installed) and stop.

2. **Show the list.** Run `bash "$s"` (read-only) and present its table verbatim — it is already formatted (state glyph, title, effort, relative age, current/orphan markers). Also capture the machine view: `runs="$(bash "$s" --json)"`.

3. **Build the picker option set — a pure function of the engine output.** The selectable runs are exactly the runs that are **resumable and not the current one**:

   ```bash
   echo "$runs" | jq -c '[.[] | select(.resumable == true and (.is_current | not))]'
   ```

   Never offer a `done` run or the `is_current` run as a resume target (they stay in the table for context only).

   - **Zero selectable** → there is nothing to resume. Say so plainly; if a `done` or current run is present, point at it for context, and suggest `/auto-task <description>` to start something new. Stop.
   - **One or more selectable** → present an **`AskUserQuestion`** with one option per selectable run (label = `<state> · <title>`, description = branch + last activity + any `· orphan` note). Cap the interactive options at ~4 by most-recent `last_activity_ts`; if there are more, add a final option "Show all / pick by number" that reprints the full numbered table and takes a typed number. **Even when there is exactly one selectable run, still confirm via the prompt** — never silently auto-resume.

4. **Position the session into the chosen run's worktree, then hand off.** From the picked run object read `branch`, `worktree`, and `worktree_present`:

   - **`worktree_present == true`** → enter the run's worktree with the **`EnterWorktree`** tool, passing `path: "<worktree>"` (entering an existing worktree by path — sanctioned when project instructions direct it, which this skill does). If `EnterWorktree` is unavailable in this session, tell the user to `cd "<worktree>"` (or `git switch "<branch>"`) themselves, then continue.
   - **`worktree_present == false`** (orphan — the state survived in the main tree/residual location but the run's worktree was pruned) → this is a destructive-adjacent recovery, so **confirm with the user first**, then:
     1. Recreate the worktree from the surviving branch: `git worktree add ".claude/worktrees/<type>-<slug>" "<branch>"` (derive `<type>-<slug>` from the branch by replacing `/` with `-`). If the branch ref itself is gone, the run cannot be resumed — report that and stop.
     2. **Relocate the run's state into the new worktree — this step is mandatory, or the resume finds nothing.** `.auto-task/` is gitignored and per-worktree, so `git worktree add` gives the new worktree an *empty* `.auto-task/`; the orphan's `STATE.json` still sits at the engine-reported `state_path` (its run dir is `dirname(state_path)`). Copy that whole run dir into the new worktree at `.auto-task/<branch>/`, e.g. `mkdir -p "<newwt>/.auto-task/$(dirname "<branch>")" && cp -R "<dirname of state_path>" "<newwt>/.auto-task/<branch>"` (a plain `cp -R` of the run dir; a bare branch with no slash makes the `dirname` a no-op `.`). Verify `<newwt>/.auto-task/<branch>/STATE.json` now exists.
     3. `EnterWorktree` into the new worktree. The subsequent standard resume (step 5) then reads the relocated `.auto-task/<branch>/STATE.json` for the now-current branch and continues.

5. **Resume the run.** Now that the session is in the correct worktree, hand off to the **standard `/auto-task` resume**: invoke the `auto-task` skill with no arguments. It reads `.auto-task/<branch>/STATE.json` for the now-current branch and continues the pipeline from its recorded `phase` — this skill deliberately does NOT reimplement the resume state machine; it only discovers and positions.

## Rules

- **Read-only discovery.** The engine and this skill never write STATE.json, never commit, never remove a worktree. The only mutation this skill can make is the *opt-in, confirmed* `git worktree add` when recovering an orphaned run — and only after the user agrees.
- **Never offer the current or a done run for resume.** They are shown for context; the resume target set is `resumable && !is_current`, taken straight from the engine's `--json`.
- **Confirm before entering, always** — even for a single selectable run. The picker is the confirmation.
- **Delegate, don't duplicate.** Resuming = position the worktree + invoke `/auto-task` (no args). Do not re-implement phase resumption here.
- Do not add `--force` / `--no-verify` to any git command; do not modify settings.
