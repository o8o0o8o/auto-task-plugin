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
- `/auto-task-stats --recalibrate` — additionally print a **suggested** `estimate.sh` coefficient adjustment computed from the pooled actual/estimate ratios (gated behind a sample floor). It is a suggestion only — it never edits `estimate.sh`; you apply it by hand.

**Env-configurable thresholds** (all optional; conservative defaults so small ledgers rarely false-alarm): `AUTO_TASK_STATS_MDE_PP` (default 15) — regression-guard minimum detectable effect for rate metrics, in percentage points; `AUTO_TASK_STATS_RATIO_MDE` (default 0.5) — MDE for est/act ratio metrics; `AUTO_TASK_STATS_MIN_SAMPLE` (default 10) — min pooled runs per plugin version before the guard compares two versions; `AUTO_TASK_STATS_RECAL_MIN_SAMPLE` (default 10) — min measured runs before `--recalibrate` suggests.

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

## What the report shows (reshaped in v0.23.0)

Each completed run records run-metrics fields to `outcomes.jsonl` (populated by the Phase-5 handover from `estimate.sh` / `token-usage.sh` and the quality-signals panel): `est_duration_min`, `est_tokens`, `act_duration_min`, `act_tokens`, `defects_early`, `defects_late`, `flaky`, `tests_added`, `diff_loc`, `first_pass_ac`, `checks_run`, `checks_failed`, plus `plugin_version` (for version grouping). The aggregator (kept in DERIVE-lockstep with `record-outcome.sh`) reports them in **decision-ordered** sections:

- **Quality (test-verified) — the headline.** What matters is whether runs produced test-verified, defect-free work: first-pass AC-pass rate, late-defect rate (Gate-B / code-review), early-defect capture (Gate-A / self-verify), tests-added rate, flakiness. Rate metrics carry a **Wilson 95% confidence interval + sample size** (`P% [lo–hi] (n=N)`) — a bare percentage over a handful of runs is not a trustworthy signal. An empty population prints `n=0 (no data)`, never a divide-by-zero.
- **Merge acceptance** — the real success signal (PRs merged vs decided), resolved via `gh`.
- **Liveness / operational — NOT a quality signal.** Completion rate ("reached Handover") is *construct-invalid as quality*: an agent can reach `done` with a confidently-wrong result, so completion looks healthy exactly when a run should not be trusted. It lives here as an operational/liveness signal, paired with where stalled runs died.
- **Estimate accuracy (calibration input)** — median `actual/estimate` ratio for tokens and time (`>1` = costlier than estimated). Runs whose estimate/actual is `null`/`0` are EXCLUDED, so the ratio is never poisoned or divided by zero.
- **Regression guard (version-over-version)** — compares the two most-recent plugin versions that each clear the sample floor, flagging a metric only when its delta exceeds the MDE. Small local ledgers usually report **"insufficient data"** — the honest state, not a failure (required N scales with 1/effect², so only large shifts are ever detectable at small scale).
- **Recalibration suggestion** (`--recalibrate` only) — suggests scaled `estimate.sh` constants from the pooled ratios; **suggest-only, never edits `estimate.sh`.**

These are **trends, not snapshots** and a **signals panel, not a single composite score** (a composite invites gaming and hides what a run cannot see). Older ledger rows lacking a field (including pre-v0.23.0 rows with no `plugin_version`) are tolerated (`// default`) — they bucket as `unknown` and are excluded from version-pair comparisons.

## Rules

- **Read-only.** Never write to the ledger, never edit `STATE.json`, never modify pipeline files.
- Do not fabricate figures — report only what the script prints.
- "Gate B coverage" reports how many STANDARD/HEAVY runs ran the adversarial gate to a pass vs. were skipped (from the recorded `gate_b` outcome). It is a coverage figure, not a "bugs caught" count — present it as such.
- "Estimate accuracy" is a median actual/estimate ratio over runs that actually recorded both — present it as calibration signal, not a guarantee. The quality-headline rates are process/correctness signals, not a composite score.
- **Completion rate is a liveness signal, not a quality metric** — never present "reached Handover" as evidence the work is correct; pair it with merge-acceptance and the test-verified quality block.
- **Read rates with their CI + n.** A rate over a handful of runs has a wide interval; do not over-interpret a small-n percentage. When the regression guard says "insufficient data," report exactly that — do not manufacture a trend the sample can't support.
- **`--recalibrate` is suggest-only** — it never edits `estimate.sh`. Present its output as a proposal for the maintainer to apply by hand after eyeballing the sample size.
