---
name: auto-task-stats
description: Report local auto-task run-outcome telemetry — completion rate, where runs stall, per-tier fix/review effort, Gate B coverage. Read-only. Use when asked "auto-task stats", "run stats", "completion rate", "how often do runs stall", or to review telemetry recorded by the record-outcome hook.
license: MIT
---

# Auto-task stats

Read-only reporter over this repo's auto-task run outcomes. It answers: **what is the completion rate, and where do runs stall?** — by aggregating the append-only ledger `.auto-task/outcomes.jsonl` (completed runs, written by the `record-outcome.sh` Stop hook) together with every live `.auto-task/*/STATE.json` on disk (in-flight and stalled runs, which never reach the ledger).

This skill never writes anything and never changes pipeline behavior. It just runs the bundled `hooks/auto-task-stats.sh` aggregator and presents its output.

## Opt-in (one-time)

Telemetry is **off by default**. Turn it on per-clone with:

```
touch .auto-task/outcomes.jsonl
```

From then on, every `/auto-task` run that reaches `phase: done` appends one local JSON row (no network, no data leaves the machine — the row is derived from fields already in `STATE.json`). Opt out by deleting the file. Even before opting in, this skill still reports on live/stalled runs it finds on disk.

## Usage

- `/auto-task-stats` — report using the default 7-day stale threshold.
- `/auto-task-stats <days>` — a live, approved, non-done run whose newest history entry is older than `<days>` is classified **stalled** rather than **in-flight**.

## What to do when invoked

1. **Locate the aggregator** `hooks/auto-task-stats.sh`. `CLAUDE_PLUGIN_ROOT` is exported only to hooks, not into the Bash-tool environment, so probe across both install layouts (same three-probe pattern the orchestrator uses for `check-version.sh`):

   ```bash
   s=""
   # a) hook env, on the off chance it is exported here
   [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/hooks/auto-task-stats.sh" ] \
     && s="$CLAUDE_PLUGIN_ROOT/hooks/auto-task-stats.sh"
   # b) marketplace install: newest installed version dir that carries the script
   if [ -z "$s" ]; then
     cache="$HOME/.claude/plugins/cache/auto-task-plugin/auto-task"
     if [ -d "$cache" ]; then
       d="$(ls -1 "$cache" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' \
            | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
       [ -n "$d" ] && [ -f "$cache/$d/hooks/auto-task-stats.sh" ] \
         && s="$cache/$d/hooks/auto-task-stats.sh"
     fi
   fi
   # c) install.sh symlink layout: resolve the installed skill symlink to the repo root
   if [ -z "$s" ]; then
     sk="$HOME/.claude/skills/auto-task-stats"
     if [ -L "$sk" ]; then
       tgt="$(readlink "$sk")"; case "$tgt" in /*) ;; *) tgt="$(dirname "$sk")/$tgt" ;; esac
       root="$(cd "$(dirname "$tgt")/.." 2>/dev/null && pwd)"
       [ -n "$root" ] && [ -f "$root/hooks/auto-task-stats.sh" ] && s="$root/hooks/auto-task-stats.sh"
     fi
   fi
   ```

   If `$s` is still empty, tell the user the aggregator script could not be located (the plugin may not be fully installed) and stop.

2. **Run it** from the repo root, passing the optional stale-days argument the user gave: `bash "$s" <days-if-any>`. It is read-only and always exits 0.

3. **Present** the script's output to the user verbatim (it is already formatted as a readable summary). If the output is the "no runs recorded yet" message, remind the user of the opt-in step above.

## Rules

- **Read-only.** Never write to the ledger, never edit `STATE.json`, never modify pipeline files.
- Do not fabricate figures — report only what the script prints.
- "Gate B coverage" reports how many STANDARD/HEAVY runs ran the adversarial gate to a pass vs. were skipped (from the recorded `gate_b` outcome). It is a coverage figure, not a "bugs caught" count — present it as such.
