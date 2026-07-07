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

## Run metrics (estimate accuracy + quality trends)

Since v0.2.0 each completed run also records run-metrics fields to `outcomes.jsonl` (populated by the Phase-5 handover from `estimate.sh` / `token-usage.sh` and the quality-signals panel): `est_duration_min`, `est_tokens`, `act_duration_min`, `act_tokens`, `defects_early`, `defects_late`, `flaky`, `tests_added`, `diff_loc`, `first_pass_ac`, `checks_run`, `checks_failed`. The aggregator (kept in DERIVE-lockstep with `record-outcome.sh`) turns them into cross-run trend lines under a **"Run metrics"** section:

- **Estimate accuracy** — median `actual/estimate` ratio for tokens and time across completed runs (`>1` = ran costlier than estimated, `<1` = cheaper). Runs whose estimate or actual is `null`/`0` (a failed measurement) are EXCLUDED, so the ratio is never poisoned or divided by zero.
- **Late-defect rate** — % of completed runs that had a defect caught only late (Gate B).
- **Flakiness rate** — % of completed runs that hit a flaky test.
- **Tests-added rate** — % of completed runs whose diff touched a test file.

These are **trends, not snapshots** (a single run is a snapshot; the ledger makes it a trend) and are process/reliability signals — deliberately NOT a single composite "quality score" (a composite invites gaming and hides what a run cannot see). Older ledger rows lacking these fields are tolerated (`// default`) and simply don't contribute to the ratio.

## Rules

- **Read-only.** Never write to the ledger, never edit `STATE.json`, never modify pipeline files.
- Do not fabricate figures — report only what the script prints.
- "Gate B coverage" reports how many STANDARD/HEAVY runs ran the adversarial gate to a pass vs. were skipped (from the recorded `gate_b` outcome). It is a coverage figure, not a "bugs caught" count — present it as such.
- "Estimate accuracy" is a median actual/estimate ratio over runs that actually recorded both — present it as calibration signal, not a guarantee. "Late-defect / flakiness / tests-added" are process signals, not a quality score.
