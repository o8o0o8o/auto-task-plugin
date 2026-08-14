# Telemetry & metrics

Two independent, separately opted-in systems, plus per-run metrics that always run.

| | Where it goes | Default | Opt in by |
|---|---|---|---|
| [Local run ledger](#local-run-ledger-opt-in) | `.auto-task/outcomes.jsonl` on your disk | Off | `touch` the file |
| [Remote telemetry](#remote-telemetry-opt-in-off-by-default) | An HTTPS endpoint you choose | Off | `telemetry_enabled: true` |
| [Run metrics](#run-metrics--estimate-vs-actual) | The run's own summary and PR | Always on | — |

## Local run ledger (opt-in)

Off by default. When you want to measure how the pipeline actually performs — completion rate, where runs stall, whether Gate B earns its cost — opt in **per clone** by running this **at the repo root** (the main working tree):

```sh
touch .auto-task/outcomes.jsonl
```

From then on, every `/auto-task` run that reaches `phase: done` triggers the `record-outcome.sh` Stop hook, which appends **one JSON row** derived entirely from that run's `STATE.json`: tier, fix/review iterations, review rounds run, how many of those ran independently, effort escalations, Gate B outcome, follow-up count, duration.

It is **purely local** — no network, and no data beyond what `STATE.json` already stores on disk. A base-keyed sentinel (`.auto-task/<branch>/.outcome-recorded`) makes it write exactly once per run. The ledger lives under the gitignored `.auto-task/` and is never committed.

Opt out by deleting the file. The hook never blocks a turn-end and no-ops entirely when the ledger is absent, so leaving it off costs nothing.

### One ledger per clone, not per worktree

Runs are isolated in linked worktrees, but the ledger's whole purpose is history that outlives any single branch folder. So its location resolves to the **main working tree** (`hooks/lib/clone-scope.sh`), and a run finishing in any worktree appends to that one file.

**This is why the `touch` belongs at the repo root.** A ledger created *inside* a worktree is not the one the hooks use. If you have a stray one from an earlier attempt, fold it in:

```sh
cat <worktree>/.auto-task/outcomes.jsonl >> .auto-task/outcomes.jsonl
```

then delete it.

### Concurrent-write safety

Because the ledger is clone-wide it has multiple writers, so the append is guarded three ways:

1. A bounded `mkdir` mutex.
2. A post-append check that the row actually landed.
3. The sentinel is stamped *only* after that check passes — so a torn write leaves the run retryable on the next turn-end instead of losing it.

Anything the reader nonetheless has to skip is **counted and named** rather than dropped in silence: both an unparseable ledger line, and a live `STATE.json` it could not read, could not derive a row from, or found somewhere other than where its own `branch` field says it lives.

The mutex is fail-open and **bounded, not free.** An uncontended append costs a fraction of a second. The worst case — another writer holding the lock, or a `.auto-task/` it cannot write to — is a measured **~2 s** before it gives up and appends anyway. It never hangs and never blocks a turn-end, but "bounded" is the honest word rather than "instant".

### Reading the report

```
/auto-task:auto-task-stats            # marketplace install
/auto-task-stats                      # install.sh fallback
/auto-task-stats 14                   # override the stale-run threshold (days; default 7)
```

The reader merges the archived ledger with every live `.auto-task/*/STATE.json` **across every worktree of the clone**, de-duplicating on branch+base — so in-flight and stalled runs, which never reach the ledger, are still counted wherever they live. Run it from the main tree or any worktree; both see the same picture.

Sample output:

```
auto-task run stats  (stale threshold: 7d)
====================================================
5 runs on record — 3 done, 1 stalled, 1 in-flight
Completion rate    75%  (3/4 terminal; in-flight excluded)

Where stalled runs died
  feat/stalled @ phase=review — stuck on flaky test

By tier
  tier       #done     med fix     med review     med rounds        indep   escalated
  heavy          1           4              3              6            4          0%
  light          1           0              1              1            -          0%
  standard       1           2              2              4            2        100%

Gate B coverage        ran on 2/2 standard+heavy runs (0 skipped)
Effort mis-scoring     33% of completed runs escalated tier mid-run
Follow-up debt         1.3 parked follow-ups per completed run (avg)

Run metrics (estimate vs actual, quality signals)
Estimate accuracy      output tokens: actual/est median 1.15x (n=3)
                       time:          actual/est median 0.9x (n=3)
Late-defect rate       33% of completed runs had a late (Gate-B) defect
Flakiness rate         0% of completed runs hit a flaky test
Tests-added rate       100% of completed runs touched a test file
```

**Reading the columns:**

- **stalled vs in-flight** — a live, approved, non-`done` run whose newest history entry is older than the stale threshold is **stalled**; newer than it, **in-flight**.
- **Gate B coverage** — how many STANDARD/HEAVY runs actually ran the adversarial gate to a pass, versus were skipped. Derived from the recorded `gate_b` outcome.
- **`indep`** — the median number of review rounds that ran in a fresh-context reviewer rather than inline, read from each round's `via`. It is a median like `med rounds`, not a share of it: the two are computed independently, so **subtracting them is not any run's inline-round count.** It prints `-` when no run in that tier records the field, and appends `(n=K)` when its median covers a different set of runs than `med rounds` does.

> **Not reported: a per-run "did Gate B catch a bug" count.** The orchestrator doesn't record a Gate B bounce as a distinct `STATE.json` signal, only as a review-loop iteration — so it can't be reconstructed after the fact without changing pipeline behavior.

## Remote telemetry (opt-in, off by default)

The ledger above is **local only** — nothing leaves your machine. If you want to send the same quality and performance signals to a central endpoint, there is a **separate, explicit, off-by-default** remote path. It is independent of the local `outcomes.jsonl` opt-in.

### You are asked once per repo

The first time you run `/auto-task` in a repo with no telemetry decision recorded, Phase 1 asks a single consent question — *"Send anonymous usage stats for this repo?"* — with **No thanks** / **Yes, send anonymous stats**.

Your answer is saved to that project's settings, so you're never asked again for that repo. Declining is remembered as a decision. It's off until you answer, and a headless run with no prompt available just stays off.

### Or set it yourself

One key, in the [project or global settings](settings.md#telemetry):

```jsonc
// ~/.claude/auto-task/settings.json (global) — or <project-key>/settings.json (project)
{ "telemetry_enabled": true }
```

That's all a user needs — **the destination is pre-wired.** `telemetry_endpoint` and `telemetry_ingest_token` ship with the plugin as built-in defaults pointing at the project's central collector, so opting in sends there automatically.

Only the destination is bundled, **not** the consent. Collection stays OFF until you explicitly set `telemetry_enabled: true`.

**The bundled ingest token is a PUBLIC, write-only key — not a secret.** It ships inside this open-source client, so it is world-readable by design, like a Sentry DSN or an analytics write key. A leak only permits appending junk rows: it is write-only, can't read the dashboard, and never carries the Turso credential. The endpoint is protected server-side by rate-limiting; rotate the key to cut off abuse.

**Self-hosting.** Override `telemetry_endpoint` (and `telemetry_ingest_token`) to point at your own dashboard. Because settings merge `defaults ⊔ global ⊔ project`, you can opt in globally and exclude one project with `{ "telemetry_enabled": false }` in that project's file — or opt in for just one. A non-https or emptied endpoint sends nothing.

**Maintainers:** the shipped defaults live in `hooks/settings.sh` (`AUTO_TASK_TELEMETRY_DEFAULT_ENDPOINT` / `_TOKEN`). Set them to your deployed dashboard URL and its `INGEST_TOKEN` at release. `settings.sh get telemetry_endpoint` shows users exactly where data goes.

### What is sent

When on, once per completed run, at `phase: done`. Current `schema_version: 7`.

| Group | Fields |
|---|---|
| **Quality / perf** | tier, effort difficulty + risk, escalations, fix/review iterations, review rounds run *(distinct from the reopening count, so you can see the review running more without finding more)*, Gate B outcome, follow-up count, duration |
| **Estimate vs actual** | time, plus input/output tokens (cache-excluded) |
| **Signals** | defects early/late, flaky, tests-added, diff size, files changed, first-pass-AC, checks tally, requirements count, drift events, preview verdict |
| **Environment** | random install id, plugin version, OS, Claude model, Claude Code version |
| **Project shape** | change type (bounded enum, see below), bucketed project size, primary language, monorepo flag |
| **Change heat** | churn ratio, hotspot concentration, dirs-touched, max-depth — numbers derived from a *local* path history that never leaves |
| **Your answers** | Phase-5 satisfaction/correctness answers + optional comment |

### What is NOT sent

It's anonymous by construction: **no task description, no branch name, no repository path, no base commit SHA, and no wall-clock timestamp** — the server stamps its own `received_at`. The install id is a random UUID with no personal data.

**The one exception** is the optional satisfaction *comment* — free text you type at the prompt, sent verbatim. Leave it blank to send nothing free-form.

### Change type (`task_type`)

Each run is labelled with a bounded change-type enum, derived from the branch `<type>` prefix — **never the slug** — and normalized case-insensitively. Any unrecognized or slash-less prefix folds to `other`, so the set is closed and dashboard-groupable.

| `change_type` | Meaning |
|---|---|
| `fix` | Bug fix, regression, or broken behavior |
| `feat` | New feature or capability |
| `deps` | Dependency add/remove/bump (manifest / lockfile) |
| `refactor` | Code reorganization with no behavior change |
| `docs` | Docs / README / comments only |
| `chore` | Build/test config, formatting sweeps |
| `cleanup` | Dead-code or file removal |
| `other` | Anything that doesn't fit the labels above |

This is a bounded label — **no per-run free text.** The only user-authored free text remains the optional satisfaction comment.

### Satisfaction prompt

When telemetry is on, the single existing Phase-5 push prompt gains one extra question — *"Did this run give you what you wanted?"* (Yes / Mostly / No / Rather not say) — plus an **optional free-text comment**. So no new interruption point is introduced.

Set `telemetry_satisfaction_prompt: false` to collect metrics without the prompt.

The comment is the one field that isn't auto-anonymized. It is **whatever you type**, sent verbatim, capped at 500 characters. Leave it blank if you don't want free text to leave the machine.

### Reset or opt out

```sh
# Opt out — data stops immediately
bash hooks/settings.sh set telemetry_enabled false

# Reset your install id — a new random one is generated on the next send
rm ~/.claude/auto-task/client-id
```

### Transport

The client `curl`s the payload to your endpoint with a bounded timeout (`--connect-timeout 2 -m 5`) and is fail-open — a slow or dead endpoint never blocks or breaks a run. It fires once per run; a base-keyed sentinel prevents resends. Implemented in `hooks/send-telemetry.sh`.

### The endpoint + database

A **reference (undeployed)** ingest server and the Turso/libSQL table schema live under [`server/`](../server/README.md): a portable `fetch` handler (`server/ingest.mjs`) that writes to a `runs` table (`server/schema.sql`).

You deploy it and provision Turso yourself. The server holds the DB credential, so clients never carry one. It is write-only for now — a dashboard is future work.

## Run metrics — estimate vs actual

Every run measures itself and reports it in the final summary, and (if telemetry is opted in) as cross-run trends above.

### Estimate before execution

At the Phase-1 approval gate the plan carries an `## Estimate` of wall-clock time and **output** token usage, computed by `hooks/estimate.sh` from the scored tier/difficulty/risk, the Acceptance-Criteria count, and the blast-radius file count.

It is a simple tier-based heuristic, now **calibrated against measured actuals** rather than guessed — n=4 runs, fit 0.71x–1.25x, median 1.01x by the mean-of-middle convention and 0.845x by the lower-median convention `auto-task-stats` uses. But with 2 standard and 2 heavy runs and **zero** light-tier runs, **the light tier is extrapolated, not fitted.** Read it as a trend input, not a promise.

**It estimates output tokens only.** Measured `input` is ~1k per run and measured `cache_read` swings 189x–467x of output, so neither is predictable. The estimate-vs-actual comparison is therefore output-vs-output — comparing an estimate against the cache-inflated `tokens_total` is a unit error, and was one (66x–434x across the four measured runs) until this was corrected.

### Actual measurement

At handover, `hooks/token-usage.sh` sums `message.usage` from the session transcript(s) under `~/.claude/projects/<slug>/`, **run-scoped** by `--since <run-start>`. It sums across multiple transcripts, so a resumed, new-session, or post-compaction run isn't undercounted.

**Wall-clock is measured, not narrated.** It comes from the hook-stamped run clock: `hooks/stamp-run-clock.sh` writes `created_at`/`updated_at` from `date -u`, and `hooks/lib/run-clock.sh` derives the span. This replaced a figure computed from the model-written `state.history[].at` timestamps — the model has no clock, so those numbers were guesses.

A negative or over-12h span is **rejected to `null`**. A run paused overnight — forwarded questions, an awaiting-external handoff, a next-day resume — has a wall-clock that is not a meaningful "how long did this take", so it is excluded rather than reported. That's a deliberate accuracy-over-coverage trade: multi-day runs report no duration at all. A rejection stays distinguishable from an absent clock, which still falls back to the old history formula so runs predating this keep reporting.

**Caveat:** token accounting is approximate for sub-agent sidechains and any concurrent unrelated work in the same session. A failed measurement is recorded as `null`, never a fabricated `0`.

### Estimate vs actual

`CONTEXT.md` and the PR carry an `## Estimate vs actual` table (estimated · actual · Δ · ratio) for time and **output** tokens. The measured grand total (`tokens_total`, cache_read-dominated) is listed for the record but carries **no ratio** — nothing estimates it.

### Checks manifest

`## Checks performed` enumerates *every* verification the run executed, each with a pass/fail/warn result: typecheck, lint, build, unit, e2e/playwright, each AC bound-check, the universal `hooks/checks.sh` hygiene checks (secret-scan, conflict-markers, debug-artifacts, large-files, test-integrity, diff-size, tests-added), and the Gate A/B findings.

`checks.sh` runs in self-verify, where a real secret or leftover conflict marker outside test/fixture paths fails the run. It runs **again at commit time**, inside `enforce-gates.sh` — the self-verify pass is model-invoked, so the commit-time pass is what stops a secret leak or a gutted test from landing *silently*. Clearing one requires writing a durable, diff-pinned, reviewable `gates.hygiene.acked[]` record that says so.

It is not a claim of completeness: the scanner is regex-based, so a credential shape it doesn't recognize still passes, and the ack itself is prose-trusted.

### Quality signals — not a score

`## Quality signals` is a panel: defects caught early vs. late, delivery reliability (estimate accuracy + loop count), scope discipline, completeness, and a maintainability read **reused from the code-review verdict** — with an explicit note of what a single run *cannot* measure (business impact, collaboration, long-term maintainability).

There is deliberately **no composite 0–100 score.** A single number invites optimizing to the metric and hides those blind spots. Quality is best read as *signals plus trends over time*, which is what the telemetry sections above provide.

---

The measurement helpers are pure, deterministic, and fail-open — they never break a run — and each has a focused test under `tests/`.
