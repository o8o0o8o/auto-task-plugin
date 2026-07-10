# auto-task — Autonomous Mode (design + roadmap)

Status: **design locked, incremental build in progress.** This document is the reference for evolving `/auto-task` from a human-triggered, human-gated pipeline into a self-driving one that picks tasks from a board, builds them, and opens PRs — **without regressing the "no issues" guarantee.**

It records the target architecture, every decision with its rationale, the phased roadmap, and the honest limitations. Read it before building any phase.

---

## The goal, stated precisely

> A scheduled agent pulls the next card from a project board (one board per repo), runs the pipeline while **auto-approving its own plan**, and ends at an **open PR it never merges** — with **async PR review** as the safety valve. After the PR is merged and deployed, a **watch** verifies the change live, monitors for regressions, and notifies on Slack.

Three asks pulled against the current design; here is how each is resolved:

| Ask | Tension with today | Resolution |
|---|---|---|
| "pick tasks" | No task source exists — input is always a human `<description>` | **Board-adapter contract** (pluggable: GitHub Issues → Asana → Jira/Trello) |
| "fully automatic" | Removes the one human gate (Phase 1 approval) — the keystone safety valve | Gate **moves downstream to async PR review**; plan self-approval is fenced by stricter automated gates + abstention |
| "no issues" | Directly opposes removing the gate | The safety valve doesn't disappear — it **moves from before execution to after it**, and is reinforced by the verification ladder below |

**The one idea that makes it safe:** "no human gate" and "no issues" can coexist only if the human safety valve moves from *approving the plan* to *reviewing the PR* (and, post-merge, watching the deploy). The machine compensates for the removed synchronous gate with stronger automated gates and an **abstention rule** — when a task is under-specified or too risky, the tool declines (moves the card to "Blocked" with the reason) rather than guessing.

---

## The verification ladder ("always good")

Quality is layered. Each rung catches a failure class the rung below physically cannot see. Rungs light up per what a repo declares (see the watch config); a repo with no deploy simply stops at L0/L1.

| Rung | Verifies | Catches | When | Owner |
|---|---|---|---|---|
| **L0 Code** | tests/types/lint/build + code review + Gate B | logic bugs, type/test regressions | in-run (today) | tool |
| **L1 Preview** | smoke ACs against the **PR preview deploy** | runtime/integration breakage, "builds but broken", config errors | in-run, pre-merge — **shipped today as Phase 7** (base pipeline, independent of autonomous mode) | tool |
| **L2 Prod smoke** | smoke ACs against the **production URL** | env-specific breakage: prod config, secrets, data shape | post-merge, on deploy | tool |
| **L3 Monitor** | error volume / uptime vs. baseline over a window | emergent regressions, downtime, error spikes | post-merge, T minutes | tool |
| **L4 Notify** | — | human unaware of outcome | after L3 | tool → user |

**The human merge gate sits between L1 and L2.** That is the structural consequence of *never merge*: L2–L4 cannot run inside the task run — they are a separate, event-driven **watch**, triggered by the deploy, keyed to the PR's commit, reusing that run's `CONTEXT.md` + AC table so it knows what to check.

---

## Decisions (locked) + rationale

| # | Decision | Chosen | Why |
|---|---|---|---|
| 1 | Task source | Board adapters, **one board per repo**; GitHub Issues first, then Asana | GitHub Issues needs zero extra auth (local `gh`); one-board-per-repo → tokens stay scoped, no central router needed |
| 2 | Plan-approval gate | **Auto-approve; safety → async PR review** | Keeps a human in the loop for correctness without blocking automation |
| 3 | Trigger / host | **Local run for now** (launchd/cron + driver script). CI (GitHub Actions) deferred | User scoped to local; CI is a later optional swap of the operational layer only |
| 4 | Handover | **Open PR, never merge, never touch `main`** | The PR is the safety valve; auto-merge is the one thing that reintroduces "issues" risk |
| 5 | Topology | **Per-repo (A)** on a shared reusable driver; 2–5 repos | Board-per-repo + few repos → central orchestrator's broad-token cost isn't justified |
| 6 | Model auth | Local `~/.claude` subscription | No `ANTHROPIC_API_KEY`, no metering (a local-run benefit) |
| 7 | Deploy setup | **Varies by repo** → watch is per-repo opt-in config | Not every repo deploys; config-driven rungs |
| 8 | Observability | **Logs only** (baseline); Sentry/Datadog are future backends | Universal signal with zero deps; honest coarse limitation (see below) |
| 9 | Regression action | **Alert loudly + auto-open revert PR** | Reversible, human-in-loop — the mirror of "never merge"; no destructive prod action |
| 10 | Notify channel | **Slack** (via incoming webhook, not the MCP) | The Slack MCP is interactively-authed and absent in headless runs |
| 11 | PR body | Add **planned-vs-done task breakdown** as the lead section | Async review is the safety valve → the PR must make intent-vs-reality obvious at a glance |

---

## Architecture — the new pieces

### 1. Board-adapter contract (pluggable task source)
A thin interface so every board looks identical to the pipeline. Four verbs:

- `list_ready()` — cards in the designated "ready for auto-task" column/label/status
- `claim(card)` — move to "In Progress" (**idempotent** — prevents double-pick across overlapping runs)
- `link_pr(card, url)` — move to "In Review" + comment the PR link
- `block(card, reason)` — move to "Blocked" + comment the specific questions/risk

Selection: top-of-column by priority, one at a time, plus a **"definition-ready" check** — a card missing enough detail to build against is `block`ed, not attempted.

> **Headless-auth rule (applies to every adapter + the notifier):** interactively-authenticated MCP servers (claude.ai Asana, Slack) are **absent in headless/scheduled runs**. Adapters used unattended must use **token/REST** (Asana PAT, Jira token) or local `gh`. The MCP is fine only for a manual run while the user is present.

### 2. Autonomous Phase 1 (no human gate)
- *Clarifying questions* → can't ask a human. The evidence-gathering stages run as today; anything that would land in the "Asked" bucket and is decision-changing → **abstain** (`block` the card with the questions). Only evidence-resolvable ambiguities proceed.
- *Plan approval* → **self-approval gated by a readiness score**: auto-approve only if feasibility is GREEN/YELLOW, the critique has no unresolved judgment-required findings, and risk is within the autonomous ceiling. Otherwise abstain.

### 3. Compensating gates (autonomous mode only)
Because no human reviews the plan:
- Autonomous runs **never run LIGHT** — floor at STANDARD, so **Gate B always runs**.
- **Risk ceiling:** any risk-dimension = 2 (schema/data migration, external API, auth/payments/data-integrity/multi-tenant) → **abstain**. Autonomous mode only takes reversible, bounded work.
- **Blast-radius cap:** exceeds N files / M layers → abstain.
- Hard invariants preserved: never `--no-verify`, never push to `main`, **never auto-merge**.

### 4. PR-only handover + a `never-merge` invariant
Phase 5 forces the "open PR, never merge" branch, writes the PR link back to the card, and moves it to "In Review". A **hook invariant** blocks any merge/push-to-main during an autonomous run — the mechanical mirror of the existing gate hooks.

### 5. `post-deploy` AC gate class
Today ACs are gated `self-verify | gate-a | gate-b`. Add **`post-deploy`** — rows whose Verification method runs against a *deployed URL* (strictly **read-only** smoke checks — no destructive writes against prod). The run marks which ACs are prod-verifiable; the watch executes exactly those. Reuses the AC machinery rather than inventing a parallel one.

### 6. Probe adapter (monitoring) — mirrors the board adapter
- `baseline()` — snapshot metrics before deploy
- `check(window)` — sample over the window, compare to baseline + thresholds
- Backends: **log-tailing (baseline, ships first)**, then Sentry, Datadog. The repo declares its log-source command (`vercel logs`, cloud logs, `journalctl`, a file).

### 7. Notifier — Slack via incoming webhook
Success and regression both post to Slack, using a **webhook URL from the env file** (not the MCP). On regression: Slack alert + auto-open a revert PR.

### 8. Local runner (operational layer)
- **Scheduler:** `launchd` (macOS-native, reliable) or `cron`, calling a driver script — *not* the skill directly.
- **Driver** (`auto-task-cron.sh`): `source` env → `cd` repo → `flock` lockfile → `timeout 45m claude -p "/auto-task --auto" --permission-mode acceptEdits`. Loop: `claim` → run → PR → `link_pr` → repeat until queue empty / blocker / **budget cap**.
- **Env vars:** `~/.config/auto-task/env` (chmod 600) — `ASANA_PAT`, `SLACK_WEBHOOK_URL`, etc. Never in the repo, never in the crontab line.
- **Permission prompts:** an unattended run can't answer them, so it runs non-interactive. Safe here because the **guardrails are hooks, not prompts** (`enforce-gates.sh`, single-commit, reviewed-diff hash — all shipped and firing regardless of permission mode; plus `never-merge`, **planned for Phase C**, not yet a firing hook).
- **macOS gotcha:** plain cron won't fire while asleep → launchd + `caffeinate`, or accept "only while awake".

---

## Roadmap (local-first; each phase independently useful)

| Phase | Deliverable | Notes |
|---|---|---|
| **0 — quick win** ✅ | PR **planned-vs-done task breakdown** section (Phase 5 body) | Landed. Helps every run today, not just autonomous mode. |
| **A** | Board-adapter contract + **GitHub Issues adapter** + `/auto-task --from-board` — **human gate still ON** | Proves source→pipeline→PR-link with zero external auth and full safety |
| **B** | Autonomous mode: `autonomous` flag, self-approval + readiness score, **abstention rules**, compensating gates (**L1 preview smoke already shipped as Phase 7** — autonomous mode reuses it) | The one risky change (gate removal) lands alone, with abstention as the net |
| **C** | PR-only handover + board write-back + **`never-merge` hook invariant** | Locks the downstream safety valve mechanically |
| **D (local)** | Driver script + `launchd`/cron + `flock` + `~/.config/auto-task/env` + budget caps | Unattended local operation |
| **F (watch)** | Per-repo watch config + **`post-deploy` gate** + **log probe** + deploy-detection + **L2/L3** + **Slack notify** + **revert-PR** on regression | Decoupled — triggered by the deploy event, keyed to the PR commit |
| ~~E (CI)~~ | GitHub Actions reusable workflow + Secrets + `ANTHROPIC_API_KEY` | **Deferred** until CI is wanted; swaps only the operational layer |

Ordering is deliberate: the dangerous step (removing the human gate, Phase B) happens only *after* the source (A) is proven, and the downstream safety valve (C) is locked before any scheduler (D) runs unattended.

---

## Honest limitations

- **Log-only monitoring is coarse.** L3 catches "did error volume spike after deploy," not subtle latency/perf regressions. The probe-adapter contract leaves that slot open for a metrics backend (Sentry/Datadog) later.
- **The safety valve depends on the human actually reviewing PRs.** If autonomous PRs pile up unreviewed and get bulk-merged, the guarantee evaporates. Mitigation: a cap on open auto-PRs before the driver pauses.
- **Watch requires infra the tool doesn't own.** Deploy URL, deploy-detection, log source, thresholds, and which ACs are prod-safe are all repo-provided config. No config → no watch (fine — stops at L0/L1).
- **Prod smoke checks must be read-only.** Destructive checks against production are forbidden — same rule as recon MCP writes.
- **Abstention over throughput.** Autonomous mode will decline more than a human would. That is the intended trade: a bounced card is a non-event; a bad auto-merged change is an "issue".

---

## Boundaries (who owns what)

- **Tool owns:** orchestration — pick, plan, build, verify (L0/L1), open PR; and post-merge: detect deploy, run smoke ACs (L2), query probes (L3), notify (L4), open revert PR.
- **Repo provides (opt-in config):** board mapping; deploy/preview URLs; deploy-detection method; log source + thresholds; which ACs are prod-safe.
- **Human owns:** the merge decision, and authorizing any irreversible rollback.
