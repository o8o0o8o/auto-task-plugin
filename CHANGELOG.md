# Changelog

All notable changes to `auto-task-plugin` are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/) and the project adheres to [Semantic Versioning](https://semver.org/).

## [0.7.0]

Two post-PR capabilities. **Preview-deployment auto-learn**: the pipeline already detected deploys after a PR but never remembered the answer — it now persists the detection result so the check becomes deterministic. **Post-PR bot-comment review** (opt-in): after the PR opens, collect Cursor/GitHub review-bot comments and conservatively auto-apply the safe fixes. Both default to their prior behavior (auto-learn only fires when `has_preview_deployment` is unset; bot-review is off unless `bot_review_autofix` is set).

### Added

- **Preview-deployment auto-learn + persist** (`skills/auto-task/SKILL.md`). When `has_preview_deployment` has never been explicitly set, the preview phase now detects whether a deployment exists and **persists the answer** to project settings via `settings.sh set` — `true` (verify every subsequent run) if a deployment/URL resolves, `false` (skip thereafter) if none is found within the bound. An explicit `true`/`false` is honored verbatim and never overwritten; `preview_autodetect: false` disables auto-learn entirely. Fail-open: a failed persist never blocks the run. Recorded in a new `preview.learned` state field.
- **Phase 6 — post-PR bot-comment review (opt-in)** (`skills/auto-task/SKILL.md`). New `bot_review_autofix` (default `false`) enables a new phase after the PR opens: poll (bounded) for review-bot comments, triage them conservatively, and auto-apply only high-confidence in-scope fixes — each through the full verify → `auto-task-code-review` → gate → commit → push loop (so every bot-fix commit is fully re-reviewed; the pre-commit gate is unchanged). The rest are parked as follow-ups. One collection round (no re-comment chase); fork-PR / no-push-authority is fail-open. The prior preview phase is renumbered **Phase 6 → Phase 7** (bot-review runs first so preview verifies the final code).
- **`hooks/pr-bot-comments.sh`** — new fail-open helper that merges a PR's issue comments, inline review-thread comments, and review summaries, filters to bot authors (`[bot]` suffix / GitHub `type:Bot` / built-in known list / `--bots` extras), de-duplicates across the three surfaces, and emits a normalized JSON array (`[]` on any failure). Modeled on `pr-deploy-url.sh`, with a `--json-file` test hook.
- **`tests/pr-bot-comments.test.sh`** — focused test for the new helper: bot-vs-human filtering, `type:Bot`/`--bots` detection, inline path/line normalization, empty-review dropping, cross-surface de-duplication, malformed-element resilience (a bad element in one surface must not zero out the others), and fail-open `[]`.
- **New settings keys** (`hooks/settings.sh` `default_for` / `defaults_json` / `known_keys`): `bot_review_autofix` (`false`), `bot_review_timeout_min` (`10`), `bot_review_poll_interval_sec` (`30`), `bot_review_bots` (`""`). Documented in the README + SKILL.md settings tables.

### Changed

- **Anti-stall Stop-hook signature** (`hooks/prevent-mid-protocol-stall.sh`) now includes `bot_review.polls` alongside `preview.polls`, so the Phase-6 bot-comment poll wait is recognized as *progressing* rather than misread as a frozen run. Backward-compatible (absent → `0`, inert on existing runs). This is the only hook change — `enforce-gates.sh` / `record-outcome.sh` / `auto-task-stats.sh` are phase-agnostic and gate/record the new `bot-review` phase with no change.
- **STATE schema** gains a `bot_review` object, a `bot-review` phase value, and a `preview.learned` field; the single-commit rule documents a second exception (Phase-6 bot-fix commits, each gate-reviewed) and the yield-point table + NON-YIELDING contract cover the new post-PR ordering (Phase 6 bot-review → Phase 7 preview).

### Fixed

- **Repo-wide documentation/consistency sweep.** Corrected stale counts and claims across the docs to match the current code: README (eight skills / seven core hooks / current version / assertion count / SessionStart-notice claim), `marketplace.json` keywords (added `pull-request` to match `plugin.json`), main `SKILL.md` hook attributions (Stop/gate hooks registered via `hooks/hooks.json`, not `settings-fragment.json`/`~/.claude/settings.json`), the `actuals` STATE schema (`model`/`claude_code_version`/`tokens_by_skill`), the "only one hook reads `preview`" note (`send-telemetry.sh` also reads `.preview.verdict`), the remote-telemetry payload description (a superset of the local row), and the `checks.sh` row transform. Sibling skills now suggest the namespaced `/auto-task-*` commands instead of bare `/implement`,`/verify`,`/commit`,`/fix`. Hook usage/comment fixes in `settings.sh`, `send-telemetry.sh`, `token-usage.sh`. Brought `ARCHITECTURE.md` + `AUTONOMOUS-MODE.md` up to the current 7-phase pipeline, and synced `server/README.md`'s telemetry-payload docs. The `install.sh` / `settings-fragment.json` fallback installs now wire the `record-outcome.sh` + `send-telemetry.sh` Stop hooks that `hooks/hooks.json` already registers. Also collapsed a duplicate `## [Unreleased]` header (the stale v0.1.0 section is now `## [0.1.0]`). No behavior change to the running pipeline.

## [0.6.0]

Sharpens the opt-in telemetry's **change-type signal** into a bounded, dashboard-groupable enum and fixes a latent data-loss bug in the reference receiver. All telemetry stays opt-in, off by default, and anonymous by construction — no new field leaves the machine.

### Added

- **`deps/` branch type** in the Phase-1 branch picker (`skills/auto-task/SKILL.md`). Dependency add/remove/bump work now routes to `deps/` instead of `chore/`, so `task_type: deps` is actually producible instead of hiding inside `chore`.
- **`raw` forward-compat column** in the reference receiver (`server/schema.sql` + `server/ingest.mjs`) — persists the full JSON payload exactly as received, so nested or future fields (e.g. `tokens_by_skill`) survive before they get a dedicated column. This is the column the [0.4.0] notes promised but never actually added.
- **`tests/ingest-columns.test.sh`** — a drift-guard test asserting `server/ingest.mjs` `COLUMNS` stays in lockstep with `server/schema.sql`'s scalar columns (and that the `task_type` enum comment lists `deps`/`other`), so the receiver can't silently fall behind the client payload again.

### Changed

- **`task_type` normalized to a bounded enum** (`hooks/send-telemetry.sh`): `{feat, fix, deps, refactor, docs, chore, cleanup, other}`. The branch `<type>` prefix is lower-cased and mapped; any unrecognized or slash-less prefix folds to `other`; an empty/absent branch stays `null`. Still the prefix only, never the slug — anonymity unchanged. README documents the enum + a per-label description table + the "no per-run free text" note. `tests/send-telemetry.test.sh` gains the normalization cases (case-fold, unknown→other, slash-less→other) alongside the existing `feat→feat` / no-slug-leak assertions.
- **Reference ingest handler synced to the v2 payload** (`server/ingest.mjs`): its `COLUMNS` list was still the v1 set and silently dropped every v2 field (`task_type`, `difficulty`/`risk`, repo-metrics, `files_changed`, `comment`, `model`, …) on INSERT. It now covers the full scalar schema in declaration order and coerces `is_monorepo` (a JSON boolean) to 0/1 alongside `flaky`/`tests_added`. Undeployed reference — this prevents silent data loss on a future deploy.

### Notes

- No `schema_version` bump: `task_type`'s value domain is tightened (not a new field) and `raw` is a receiver-side column, so the client payload shape is unchanged and older rows keep parsing.

## [0.5.0]

Expands the opt-in remote telemetry into a richer, anonymous **v2 payload** with per-skill **token-cost attribution** and **zero-config preview auto-detection**, and folds in the clarifying-questions ticket-comment feature. All telemetry stays opt-in, off by default, and anonymous by construction.

### Added

- **Telemetry payload `schema_version: 2` (additive).** Beyond the v1 metrics: effort `difficulty`/`risk`, `model` + `claude_code_version` (from the transcript), `task_type` (the branch *prefix* only — never the slug), cache-excluded `tokens_input`/`tokens_output` (so the estimate ratio is meaningful, not cache-dominated), `files_changed`, `requirements_count`, `drift_events`, `preview_verdict`; **bucketed project size** (`repo_files_bucket`, `primary_language`, `is_monorepo`); and an **anonymous change-heat** signal (`churn_ratio`, `hotspot_concentration`, `dirs_touched`, `max_depth`) computed from a LOCAL path history that never leaves the machine. New helper `hooks/repo-metrics.sh` (buckets/numbers only — no paths, names, or hashes; `tests/repo-metrics.test.sh`).
- **Per-skill token-cost attribution (`tokens_by_skill`).** `hooks/token-usage.sh` now emits a deterministic per-skill output-token map from the transcript's `attributionSkill` (orchestrator / code-review / commit vs unattributed main loop). `send-telemetry.sh` **self-measures token usage at `phase: done`** (calling `token-usage.sh` directly) so the cost is sent on *every* completed run rather than depending on the orchestrator populating `state.actuals`. Documented limitation: sub-agent (Gate A/B verifier, review-subagent) tokens are not logged by Claude Code and are excluded — stated, never fabricated.
- **Preview auto-detection (`hooks/pr-deploy-url.sh`, default on).** With no preview settings, when a PR is opened Phase 6 polls the PR's comments/body for a deployment URL (Vercel/Netlify/Cloudflare Pages/Render/Fly/Railway/Firebase/… bot comments) and verifies against it — zero config. No URL within the bound ⇒ `skipped-no-url`, ends cleanly (no failure, no stall). New `preview_autodetect` setting (default `true`); `has_preview_deployment`/`preview_url` remain explicit overrides. `tests/pr-deploy-url.test.sh`.
- **`settings.sh` `present`/`set` subcommands** (from 0.4.1's consent work) plus the new `preview_autodetect`/`telemetry_*` keys.
- **Clarifying questions forwarded as a ticket comment + run title** (`skills/auto-task/SKILL.md`) — Phase 1 can surface the clarifying Q&A back to the originating ticket and set a readable run title.

### Notes

- Anonymous by construction throughout: no task text, branch, repo path, base SHA, or wall-clock timestamp. The optional satisfaction comment is the one consented, user-authored free-text field.
- `bundled` central-collector endpoint + public write-only ingest token ship in `hooks/settings.sh`; a user opts in with a single `telemetry_enabled: true` (or the once-per-repo Phase-1 prompt).

## [0.4.1]

Makes the remote-telemetry opt-in (0.4.0) **explicit for every user** via a once-per-repo consent prompt, instead of a flag they must discover. Still opt-in, still off until answered, still anonymous.

### Added

- **Once-per-repo telemetry consent prompt (`skills/auto-task/SKILL.md`, Phase 1).** On a NEW run in a repo with no recorded decision, Phase 1 asks a single question — *"Share anonymous auto-task telemetry from this repo?"* (**Enable** / **No thanks — don't ask again**) — as part of the existing human gate, and records the answer to the project settings so it is never asked again. Declining writes `telemetry_enabled: false` (a real decision). Skipped on resume and when already decided at project **or** global scope. Fail-open: if the prompt is unavailable (headless) or `settings.sh` can't be located, it proceeds with telemetry OFF — never blocks a run, never enables without an explicit answer.
- **`settings.sh` `present` + `set` subcommands.** `present <key>` reports whether a key is **explicitly set** in a settings file (project or global) versus only resolving to a built-in default — how the orchestrator tells "decided" from "never asked". `set <key> <value> [--global]` persists a choice into the project (or global) file, merging without clobbering existing keys, creating the file outside the repo. Both fail-open. `tests/settings.test.sh` extended.

### Notes

- The destination stays bundled (endpoint + public write-only ingest token from 0.4.0), so the consent answer is the only user-facing decision.

## [0.4.0]

Adds **opt-in anonymous remote telemetry** — the plugin can now send anonymized quality/performance metrics from completed runs to a central collector, on top of the existing local-only `outcomes.jsonl`. Off by default and anonymous by construction; a project that sets nothing behaves exactly as before.

### Added

- **`hooks/send-telemetry.sh` — opt-in remote telemetry (new Stop hook).** At `phase==done`, when `telemetry_enabled` is `true` and the endpoint is a valid `https://` URL, it derives an ANONYMIZED row from `STATE.json` and POSTs it — bounded (`--connect-timeout 2 -m 5`), fail-open, write-once per run (base-keyed sentinel). The payload is the `record-outcome.sh` metric set **minus** task/branch/base/completion-timestamp, **plus** a random resettable install id (`~/.claude/auto-task/client-id`, no PII), `plugin_version`, `os`, `schema_version`, the Phase-5 `satisfaction`/`correctness` answers, and an optional free-text `comment` (the one user-authored field, capped 500 chars). `Authorization: Bearer <token>` is sent when an ingest token is set. A drift test binds the payload field set to the source row so the two cannot silently diverge. `tests/send-telemetry.test.sh`.
- **Bundled central collector + `telemetry_*` settings.** New `settings.sh` keys: `telemetry_enabled` (default `false` — opting in stays explicit), `telemetry_endpoint`, `telemetry_ingest_token`, `telemetry_satisfaction_prompt` (default `true`). The endpoint + token ship as **built-in defaults** pointing at the project's central dashboard, so a user opts in with a single flag; both are overridable to self-host. The ingest token is a **public, write-only key by design** (world-readable in an open-source client; a leak only permits appending junk rows — no read, no DB credential).
- **Global settings layer.** `settings.sh` now merges `defaults ⊔ global ⊔ project` — a global file (`${AUTO_TASK_HOME:-$HOME/.claude}/auto-task/settings.json`) applies to every project; the per-project file overrides it. `init --global` seeds the global template. `read_obj` accepts exactly one JSON object (rejects scalars, arrays, and multi-document streams) so a corrupt file at one scope can't wipe the other.
- **Phase-5 satisfaction prompt.** When telemetry is on, the single existing push prompt gains one satisfaction/correctness question plus an optional comment (persisted to STATE before `phase==done`); no new interruption surface. `quality.satisfaction`/`correctness`/`comment` added to the state schema.
- **`server/` reference (undeployed).** Turso/libSQL `schema.sql` + a portable `fetch` ingest handler (`ingest.mjs`) + deploy guide, as a minimal reference receiver.
- **Docs** — README `### Remote telemetry (opt-in, off by default)` section (what is/isn't sent, single-flag enable, self-hosting, the public-key rationale) + the new keys in the settings table.

### Notes

- Anonymous by construction: no task text, branch, repo path, base SHA, or wall-clock timestamp is ever sent. The optional `comment` is the one user-authored, consented exception.
- Independent of the local `outcomes.jsonl` opt-in; the local ledger and its `auto-task-stats` reader are unchanged (`metrics-integration.test.sh` lockstep intact).
- Forward-compatible: the receiver retains the full payload in a `raw` column, so new fields survive before a column exists; `schema_version` is the migration anchor.

## [0.3.0]

Adds **project settings** and a gated **post-push preview-verification phase**. Both are purely additive and default-off — a project that sets nothing behaves exactly as before. Settings live outside your repo and never touch the tracked tree.

### Added

- **`hooks/settings.sh` — project settings (opt-in).** Pure, fail-open bash+jq reader for a per-project, per-user JSON settings file kept **outside the repo** at `${AUTO_TASK_HOME:-$HOME/.claude}/auto-task/<project-key>/settings.json`. The `<project-key>` is `<repo-basename>-<12-char-hash>` derived from the git **common dir**, so every worktree of one clone resolves to the same file (per-clone, not per-worktree) and nothing is ever written inside the working tree (never shows in `git status`). Every key has a built-in default (single source of truth in the script); a missing file, malformed JSON, or an absent key all fall back. `false`/`0`/`""` file values are honored (presence-tested, not jq's `//`). Subcommands: `get`/`all`/`path`/`init`/`keys`. Recognized keys (v1): `has_preview_deployment` (default `false`), `preview_url`, `preview_wait_mode` (`poll`|`handoff`), `preview_timeout_min` (30), `preview_poll_interval_sec` (60), `preview_bypass_header`, `preview_post_verdict_comment`. 28-assertion `tests/settings.test.sh`.
- **Phase 6 — post-push preview verification + verdict (`skills/auto-task/SKILL.md`).** Gated on `has_preview_deployment` + an actual push (else it no-ops straight to `done`, exactly as before). Waits for the preview deploy (`poll` default — bounded, configurable timeout — or `handoff` to a later resume), resolves the preview URL **bound to the pushed HEAD SHA** (`gh` deployment auto-detect, then a configured `preview_url` fallback), re-runs the URL-checkable Acceptance Criteria + a smoke check against the live preview, and records a **PASS / FAIL / INCONCLUSIVE** verdict in STATE + CONTEXT.md (optional PR comment via `preview_post_verdict_comment`). Auth-protected (401/403) previews → `INCONCLUSIVE` with a bypass-token hint (never silently masked); timeout → `pending` + resume; a completed verdict (incl. FAIL) is terminal so telemetry captures it. New STATE objects `settings`/`preview` + `phase: "preview"` + yield-point rows; a "User settings" section and a Phase-1 settings-load step.

### Changed

- **`hooks/prevent-mid-protocol-stall.sh` — `preview.polls` added to the soft-lock signature.** A Phase-6 `poll` wait is the one legitimately long-lived `auto-continue` state (phase/iterations constant across many turn-ends); each poll cycle bumps `preview.polls`, which advances the stall signature so a progressing poll is not misread as a frozen run — while a poll that stops bumping is still caught by the backstop. Backward-compatible: absent on every non-preview run (`// 0` → constant), so existing stall behavior is unchanged. `tests/enforcement-spine.test.sh` +8 assertions (progressing poll never soft-locks; frozen poll still released at the limit).
- **Docs** — README `## Project settings (opt-in)` + `### Preview verification (opt-in)` sections (location, keys, defaults, the post-push flow), and a feature-list entry.

### Notes

- **Default-off, zero behavior change.** With `has_preview_deployment` at its `false` default (and no settings file at all), the pipeline ends at Phase 5 exactly as in 0.2.x. The plugin's own repo has no preview deployment, so this release does not change how `/auto-task` runs here.

## [0.2.1]

Sharpens the PR handover so the async reviewer sees **intent vs. reality** at a glance, and lands the reference design for **Autonomous Mode** (the roadmap toward board-driven, self-approving, PR-only runs). Docs- and template-only — no behavioral hooks change, all existing tests pass.

### Added

- **`skills/auto-task/AUTONOMOUS-MODE.md` — design + roadmap reference.** Captures the locked target (a scheduled agent pulls a board card → self-approves → opens a PR it never merges, with async PR review + a post-deploy watch as the safety valves), the verification ladder (L0 code → L1 preview → L2 prod smoke → L3 monitor → L4 notify), all 11 locked decisions with rationale, the 8 new architecture pieces (board adapter, autonomous Phase 1, compensating gates, `never-merge` invariant, `post-deploy` AC gate, log-based probe adapter, Slack notifier, local runner), the Phase 0–F roadmap, and the honest limitations.

### Changed

- **PR body — `## Requirements coverage` → `## Task breakdown — planned vs. done` (`skills/auto-task/SKILL.md`, Phase 5).** The lead review section is now an intent-vs-reality table: one row per `state.requirements[]` plus drift-added/dropped rows, a `✅ done · ⚠️ changed · ❌ dropped · ➕ added` status, and a "done in fact" column citing the AC evidence that proves each item. Subsumes the old coverage block (keeps its `all_complete` tally) and pairs with the retained `## Acceptance Criteria` checklist (breakdown = intent vs. reality; checklist = each criterion's bound check). The local CONTEXT.md `## Requirements coverage` artifact is unchanged.

## [0.2.0]

Adds **run metrics** — the pipeline now estimates its cost before execution, measures the actuals, enumerates every verification it ran, reports quality as an honest signals panel (deliberately not a gameable single score), decomposes the task into a checked requirements list, and feeds all of it into the cross-run telemetry. Purely additive and fail-open — the measurement helpers never block a run, and the new STATE fields are invisible to the gate/stall hooks.

### Added

- **`hooks/estimate.sh` — pre-execution estimate.** Pure, deterministic, no-jq helper. From `--tier/--difficulty/--risk/--acs/--files` it prints a JSON estimate of wall-clock minutes + token usage (static tier heuristic; tier derivable from `max(D,R)`). Emits `null` (never `0`) on unusable input so the telemetry ratio can exclude it. Surfaced at the Phase-1 approval gate as PLAN.md `## Estimate`. 18-assertion `tests/estimate.test.sh`.
- **`hooks/token-usage.sh` — actual token measurement.** Sums `message.usage` from the session transcript JSONL under `~/.claude/projects/<slug>/`, **run-scoped** by `--since` (numeric ISO compare), summing across ALL transcripts in the slug dir (resume / new-session / post-compaction safe). Slug maps **every** non-alphanumeric char (incl. `.`) to `-`. `null` (not `0`) on any failure. 15-assertion `tests/token-usage.test.sh`.
- **`hooks/checks.sh` — universal hygiene/defect checks.** Scans tracked *and untracked* changes vs `<base>`: secret-scan, conflict-markers, debug-artifacts, large/binary files, diff-size, tests-added. F1/F2 are block-worthy on real source but demote to `warn` on test/fixture paths (segment-anchored, never substring `*test*`); never echoes secret content. bash-3.2-safe, fail-open. 11-assertion `tests/checks.test.sh`.
- **`hooks/requirements-coverage.sh` — requirement coverage/completion check.** Reads `state.requirements[]` and reports `covered/uncovered`, `complete/incomplete/dropped`, and `all_covered`/`all_complete`. Phase 1 requires every requirement covered by ≥1 AC; Phase 5 requires every requirement `done`. 16-assertion `tests/requirements-coverage.test.sh`.
- **`tests/metrics-integration.test.sh`** — 23-assertion behavioral test of the full data path (estimate → STATE → `record-outcome` ledger row → `auto-task-stats` render), including the null/0-estimate divide-by-zero guard.
- **Orchestrator wiring (`skills/auto-task/SKILL.md`).** New STATE objects `estimate`/`actuals`/`quality`/`checks`/`requirements`. Phase 1 computes the estimate + dissects the task into an unambiguous requirements list. Phase 3 self-verify runs `checks.sh` and records a comprehensive checks manifest (a real secret / conflict marker fails the run). Phase 5 measures actuals + assembles the quality signals panel and renders new CONTEXT.md/PR sections: `## Estimate vs actual`, `## Checks performed`, `## Quality signals`, `## Requirements coverage`.

### Changed

- **`hooks/record-outcome.sh` + `hooks/auto-task-stats.sh` (lockstep).** The ledger row and reader gain `est_/act_` time+token fields and quality-signal trend fields (`defects_early/late`, `flaky`, `tests_added`, `diff_loc`, `first_pass_ac`, `checks_run/failed`). The reader adds a **Run metrics** section: estimate-accuracy (median actual/estimate, null/0 excluded), late-defect / flakiness / tests-added rates. `tests/record-outcome.test.sh` extended to 60 assertions incl. forward-compat defaults and a DERIVE-lockstep guard.
- **Docs** — README `## Run metrics` section (+ sample stats output) and `auto-task-stats` skill doc describe the metrics, the run-scoped token caveat, and the "signals + trends, not a single score" quality philosophy.

### Notes

- **Quality is a signals panel, not a score.** By design there is no composite 0–100 quality number: a single figure invites optimizing to the metric and hides what a single autonomous run cannot see (business impact, collaboration, long-term maintainability). Maintainability is reused verbatim from the code-review verdict rather than recomputed.
- **Token accounting is approximate** for sub-agent sidechains and concurrent unrelated same-session work; `--since` scopes to the run but pre-STATE setup tokens are a minor undercount. Documented, not hidden.

## [0.1.16]

Adds opt-in, local run-outcome telemetry so maintainers can measure the pipeline's own completion rate and find where runs stall. Purely additive — no network, no new PII, no change to the orchestrator's runtime behavior.

### Added

- **`record-outcome.sh` — opt-in run-outcome archiver (Stop hook).** When the ledger `.auto-task/outcomes.jsonl` exists (opt in with `touch .auto-task/outcomes.jsonl`), a run reaching `phase: done` appends **one** JSON row derived entirely from `STATE.json` (tier, initial tier, effort escalations, fix/review iterations, Gate B outcome, follow-up count, duration). A **base-keyed sentinel** (`.auto-task/<branch>/.outcome-recorded`) makes it write exactly once per run — a fresh run reusing a branch folder (new `base`) is recorded again, and a `base`-less/legacy state falls back to presence-based dedup so it can never spam duplicate rows. Fail-open and non-blocking: it **always** exits 0 and emits no Stop-block decision, so telemetry can never interfere with a session or with the anti-stall hook. Silent no-op unless opted in; cheap early-exits keep non-auto-task repos free. Mirrors `prevent-mid-protocol-stall.sh`'s worktree-retarget + fail-open conventions.
- **`auto-task-stats.sh` + `auto-task-stats` skill — read-only telemetry reporter.** Merges the archived ledger with every live `.auto-task/*/STATE.json` on disk (so in-flight and stalled runs, which never reach the ledger, are still counted), de-duplicating on **branch+base**. Reports overall completion rate, where stalled runs died (phase + last-history summary), a per-tier table (count / median fix / median review / % escalated), **Gate B coverage** (how many STANDARD/HEAVY runs ran the adversarial gate to a pass vs. were skipped), effort mis-scoring rate, and average parked follow-ups. Reads every field with a `jq // default` for forward-compat across ledger-schema changes, and guards the empty/just-opted-in ledger (no divide-by-zero). Invoke as `/auto-task:auto-task-stats [stale-days]` (marketplace) or `/auto-task-stats` (install.sh fallback).
- **`tests/record-outcome.test.sh`** — 41 assertions covering the archiver (opt-out silence, non-done silence, write-once, run-scoped and empty-base sentinel behavior, field-correctness, never-blocks) and the reader (classification, branch+base dedup, empty-ledger guard, all output sections).

### Changed

- **`hooks/hooks.json`** — registers `record-outcome.sh` in the `Stop` array after `prevent-mid-protocol-stall.sh` (the blocking anti-stall hook runs first; the telemetry hook never blocks).
- **`install.sh`** — adds `auto-task-stats` to the `SKILLS` array so the offline/dev install links the new skill (marketplace installs auto-discover it).

### Notes

- A per-run "Gate B caught a bug" count is intentionally **not** reported: the orchestrator records a Gate B bounce only as a review-loop iteration, not a distinct `STATE.json` signal, so it can't be reconstructed after the fact without changing pipeline behavior. The honest, derivable "Gate B coverage" (ran-to-pass vs. skipped) is reported instead.

## [0.1.15]

Closes a verified fail-open in the `enforce-gates.sh` commit-detection regex — the core safety hook now catches the `git commit` invocations that previously slipped past it. Also re-syncs `marketplace.json` to the plugin version (it had drifted to 0.1.13).

### Fixed

- **`enforce-gates.sh` — commit-detection fail-open.** The PreToolUse commit gate required `git` to be **immediately** followed by `commit`, so several real invocations bypassed a hook that is designed to fail **closed** and let an ungated commit through: global options between verb and subcommand (`git -C <path> commit`, `git -c user.name=x commit`, `git --no-pager commit`), leading environment assignments (`GIT_AUTHOR_NAME=x git commit`), command wrappers (`sudo`/`command`/`env`/`nice`/`doas`/`time`/`xargs`), path-qualified binaries (`/usr/bin/git commit`, `./git commit`), and option/env **values containing quoted whitespace** (`git -c user.name='A B' commit`). Both `commit_re` regexes (decoded-command and raw-JSON-fallback) are now assembled from shared, quote-aware sub-patterns tolerating all of the above; the trailing `commit(\b|$)` anchor is unchanged, so existing detection is a **strict superset** (no regression) and prose / non-commit subcommands (`git status`, `git log --grep=commit`) still pass. The fix was validated against `/usr/bin/grep` (the binary the hook resolves at runtime). Covered by a new 24-assertion `Bypass-form commit detection` section in `tests/enforcement-spine.test.sh` (decoded + raw bypass forms plus over-match guards). Known residuals are documented in the hook comment and deferred (wrapper-*options* like `sudo -u bob`, non-allowlisted wrappers, git aliases, raw-mode backslash-escaped quoted values, bare subshell/brace-group prefixes `(git commit)` / `{ git commit; }`, and the pre-existing fail-safe `git commit-graph`/`commit-tree` over-block).

### Changed

- **`marketplace.json` version re-synced.** Bumped from a stale `0.1.13` to match `plugin.json` (`0.1.15`); the two version fields must move together on every release.

## [0.1.14]

Keeps auto-task branches conflict-free with the default branch by pulling `main` at both ends of a run — when the branch is created and again right before the handover commit — and always resolving any conflicts before the PR.

### Added

- **Phase-5 pre-commit main-sync.** Right before the handover commit, auto-task now pulls `origin/<default>` (`git fetch`, best-effort/fail-open — offline skips the whole sync), makes the single authored commit, then **merges `origin/<default>` into the branch** so the PR merges cleanly even when `main` advanced during a long run. Conflicts follow a **hybrid policy**: mechanical / non-overlapping conflicts are auto-resolved (reconcile-only, "when in doubt surface") and the merge is finalized with `git commit --no-edit`; conflicts needing judgment STOP and surface via the Surfacing protocol. `/auto-task-verify` re-runs after **every** merge (a clean merge can still pull in a behavior-breaking upstream change), and any *resolved* conflict additionally re-invokes the `auto-task-code-review` skill and refreshes `reviewed_diff_sha` before push — so authored resolution logic is never shipped un-reviewed. Post-merge re-checks are scoped to the run's own delta over the new `main`, not the upstream churn the merge pulled in.

### Changed

- **Phase-1 branch setup states the pull-main contract explicitly.** The existing best-effort `git fetch origin <default>` + fork-from-`origin/<default>` is now documented as the first half of "pull main so there are no conflicts": a brand-new branch is conflict-free with `main` by construction (nothing to merge at creation), with the Phase-5 re-sync as the second half. Behavior is unchanged (still fail-open for offline runs).
- **`enforce-gates.sh` — `MERGE_HEAD` staleness exemption.** The review-staleness hash check now skips **only** the hash comparison while a merge is in progress (`MERGE_HEAD` present), because the handover main-sync legitimately changes `git diff <base>` by pulling in upstream `main` (not un-reviewed authored work). Every boolean gate (review passed / correct tool / clean-after-fix / Gate B) still holds during the merge, so a merge cannot slip past an unpassed review; the skill compensates for the skipped staleness by re-reviewing any conflict resolution before push. Covered by new assertions in `tests/enforcement-spine.test.sh` (stale diff allowed during a merge, booleans still enforced during a merge, stale diff blocks again once the merge concludes).
- **Single-commit rule reconciled.** The NON-NEGOTIABLE single-commit rule now explicitly permits the Phase-5 main-sync **merge** commit as integration (not authored work), keeping the invariant that all of a run's authored changes are one reviewed commit.

## [0.1.13]

Makes updating the plugin a one-choice, no-typed-command action — there is always an option to update, and it applies itself.

### Added

- **`hooks/apply-update.sh` — non-interactive, fail-safe updater.** It self-detects the install layout and applies the update without any typed command: a **marketplace** install (plugin root under a `plugins/cache/` dir) runs `claude plugin update auto-task@auto-task-plugin --scope <scope>` (scope resolved from `claude plugin list`, default `user`); an **install.sh / dev** install (a git work tree) runs `git -C <root> fetch && git -C <root> pull --ff-only`; a **copy** install or any other layout gets a clear "unsupported — re-run install.sh" message. Layout detection is *positive* (never "not git ⇒ marketplace"), so a `--copy` install can't be misrouted to the marketplace path. Git updates are fast-forward only — never forced, never a branch switch — and a dirty/diverged/no-upstream tree fails cleanly instead of clobbering local work. An already-up-to-date git tree reports a no-op (not a false "applied") so the update offer can't loop. Success/failure is the exit code (not stdout text); `AUTO_TASK_UPDATE_DRYRUN=1` prints the planned command and mutates nothing. Covered by `tests/apply-update.test.sh` across every layout (git no-op vs fast-forward, marketplace scope resolution, copy/unknown, cwd-independent self-location) plus the never-force guarantee.

### Changed

- **Phase-1 "update" is now auto-apply, not a manual instruction.** When the per-run version check finds a newer version, the option is relabeled **"Update it for me (auto-apply)"**; choosing it runs `apply-update.sh` and then asks you to **restart** the session (a restart is required — hooks load at session start and a marketplace update only *stages* the new version, so a same-session re-invoke would reload nothing and re-offer the update in a loop). The branch is fail-open: if the updater can't be located or exits nonzero, it falls back to printing the manual `/plugin update …` command, exactly as before.
- **Version-notice text advertises auto-apply.** `check-version.sh` (both the SessionStart JSON and the `--plain` per-run modes) now says the next run can auto-apply the update, keeping the explicit `/plugin update …` command as a fallback. Detection logic is unchanged; the `--plain` contract (one line when behind, empty otherwise) is preserved.

## [0.1.12]

Fixes a false-positive that blocked commits from a worktree-isolated run — the exact failure mode the unconditional-worktree-isolation feature (0.1.9) made the default path.

### Fixed

- **Worktree-isolated runs are no longer misjudged by the enforcement-spine hooks.** All four hooks that resolve per-branch `.auto-task/` state (`enforce-gates.sh`, `warn-checkout-drift.sh`, `prevent-mid-protocol-stall.sh`, `inject-history-reminder.sh`) derived the project root from `CLAUDE_PROJECT_DIR`, which the harness keeps pinned to the **main checkout** even when the session runs inside a linked worktree. A `git commit` in the worktree therefore lands on the worktree's branch, but the hooks inspected the main checkout's branch + `.auto-task/`. When main sat on a branch with no active run while *other* branches had active runs, `enforce-gates.sh` fired a bogus **checkout-drift block** and refused the commit; `warn-checkout-drift.sh` spammed a false drift warning on every command; `prevent-mid-protocol-stall.sh` failed open, **silently disabling the anti-stall backstop** for the whole run; and `inject-history-reminder.sh` reported the wrong branch's (or no) read-before-review reminder. Each hook now detects when the operation's real cwd (from the payload's `.cwd`, falling back to `$PWD`) is a **linked worktree of the same repo** and retargets to it. Same-repo worktrees are distinguished from nested/embedded repos by the git common-dir (a linked worktree *shares* it; a nested repo has its own), normalised with `cd`-into + `pwd -P` so a relative `.git`, an absolute worktree path, and the macOS `/var`→`/private/var` symlink all compare correctly. Nested/embedded repos are never retargeted, preserving the no-fail-open guarantee for them.

## [0.1.11]

Adds **decision weighting** to the Phase-1 Clarifications gate, so the consequential calls auto-task makes on the user's behalf surface at approval instead of hiding in a flat list.

### Added

- **Decision weighting + Decision watchlist.** Every *Resolved* clarification (a decision auto-task made itself, backed by a cite) is now scored on two 0–2 axes: **Confidence (C)** — strength of the evidence — and **Cost-if-wrong (K)** — reversibility × blast radius, judged per-decision using the same dimensions as the Difficulty/Risk rubric. Decisions where `K == 2`, or where `K == 1` and `C <= 1`, are promoted into a new **Decision watchlist** rendered in `PLAN.md`'s `## Clarifications` and surfaced at the approval gate beside the risk disclaimer, each carrying *If wrong* / *Unwind* lines. This makes a thinly-cited or hard-to-unwind call visible for veto even though it had a cite — while cheap, well-cited, reversible decisions stay silent (no added burden). The watchlist is a **view over Resolved**, not a new bucket: the cite-or-ask binary and the "no third bucket" invariant are unchanged. Truly irreversible or external-write decisions still route to **Asked** (the user overrides before they happen) and never appear on the watchlist. The `define-clarify` state entry now records `weight: {c,k}` and a `watchlisted` flag.

## [0.1.10]

Fixes the per-run version check, which silently skipped on **every** run.

### Fixed

- **Per-run version check now actually runs.** Phase 1 located the checker only via `${CLAUDE_PLUGIN_ROOT}/hooks/check-version.sh`, but `CLAUDE_PLUGIN_ROOT` is exported only to *hooks* — it is empty in the Bash-tool environment where the skill's per-run check executes. The path resolved to a bare `/hooks/check-version.sh` that never existed, so the check hit its fail-open "not at the expected path → skip silently" branch on every run and no update notice ever appeared. The locate step now discovers `check-version.sh` without relying on that env var: it probes the marketplace cache (newest installed version dir) and the `install.sh` symlink layout (resolving `~/.claude/skills/auto-task` back to the repo root), still failing open if none are found. The `check-version.sh` script itself was correct and is unchanged.

### Added

- **`install.sh` and `settings-fragment.json` now wire the `SessionStart` version-check hook.** The offline/symlink install path previously emitted only the `PreToolUse` and `Stop` hooks, so `install.sh` users never got the session-start "newer version available" notice (marketplace installs got it via `hooks/hooks.json`). Both now include the `SessionStart` → `check-version.sh` entry.

## [0.1.9]

Worktree isolation is now **unconditional** and based on a **fresh default branch** — the last gap that let same-repo parallel runs interfere is closed, with zero user action.

### Changed

- **Every new-description run isolates, from any branch.** Previously auto-worktree only kicked in on `main`/`master` starts; a run launched on a prepared feature branch ran in the shared checkout and relied on the checkout-drift lock. Now Phase 1 forks a fresh `<type>/<slug>` branch for **every** run regardless of the current branch, and always in its own git worktree. Two parallel runs can no longer fight over one working tree.
- **Runs fork from the repo's default branch (`main`/`master`), not the current HEAD.** The default branch is resolved (`git symbolic-ref refs/remotes/origin/HEAD`, else local `main`/`master`), best-effort fetched (`git fetch origin <default>`, fail-open when offline), and the worktree is created from that ref (`git worktree add … -b <branch> <default-ref>`). Every run therefore starts from a clean, current base and never inherits the current checkout's branch identity or uncommitted WIP. Consequence: a run started on a feature branch forks fresh from the default rather than continuing that branch — to base a run on specific work, prepare a worktree by hand and run `/auto-task` inside it.
- **`marketplace.json` version corrected.** It was stuck at `0.1.5` while `plugin.json` advanced; both are now `0.1.9` and kept in lockstep.

### Added

- **Already-inside-a-worktree detection.** When the session is already in a linked worktree (`git rev-parse --git-dir` ≠ `--git-common-dir`), the run stays in place instead of nesting a second worktree — preserving the hand-made-worktree workflow.
- **Collision-safe naming.** Branch name AND worktree directory are both disambiguated (`-2`/`-3`…) before creation, so two runs with the same-slugified description never collide back onto a shared branch/checkout.
- **Resume never forks.** A resume (`/auto-task` no args) re-enters its existing worktree keyed by `state.branch`; isolation is a new-run action only.

### Docs

- `skills/auto-task/SKILL.md` (Phase 1 branch-setup rewritten), `ARCHITECTURE.md` (Phase 1 diagram box + "Parallel runs" section), and `README.md` ("Running multiple runs in parallel") all updated from *automatic-on-main/master* to *unconditional, from a fresh default branch*.

### Fixed

- The checkout-drift guard is now correctly framed as protecting only the in-place fallback path (the sole remaining shared-checkout case), not "prepared feature branch" runs (which now isolate).

## [0.1.8]

Automatic worktree isolation for parallel runs + a checkout-drift guard. Same-repo parallel `/auto-task` is now fully automatic instead of requiring you to hand-create a worktree first.

### Added

- **Automatic worktree isolation (new-branch runs).** Phase 1 branch setup no longer `git switch -c`s the shared checkout when you start on `main`/`master`. It now creates the run its own git worktree — `git worktree add .claude/worktrees/<type>-<slug> -b <branch> HEAD` (base pinned to the local HEAD so the `base = git rev-parse HEAD` contract holds regardless of the user's `worktree.baseRef` git config) — and relocates the session into it with the harness `EnterWorktree` tool. Parallel runs in one repo are now safe out of the box: each new-branch run gets its own working tree, the original checkout stays free, and git forbids two worktrees on one branch so they can't collide. If the current branch is anything other than `main`/`master`, the prepared checkout is respected and the run stays in place (auto-worktree only on the new-branch path). Ordered fallback with orphan-cleanup when `EnterWorktree`/`git worktree add` is unavailable or fails: undo any half-created worktree, then `git switch -c` in place. The auto-created worktree is KEPT on disk after the run (Phase 5 never removes it); prune manually with `git worktree remove`. Also excludes `.claude/worktrees/` via the common-dir exclude so an in-repo worktree never shows as untracked in — or is staged from — the parent checkout.
- **Checkout-drift guard (protects in-place runs).** New `warn-checkout-drift.sh` (PreToolUse/Bash, informational, NEVER blocks) warns on every command when an active run exists on a branch other than the one checked out; and `enforce-gates.sh` gains a fail-closed **drift block** that stops a `git commit` in that same situation. Together they close the previous silent fail-open where the working tree was switched off an in-place run's branch (e.g. from another terminal): the branch-keyed hooks found no state for the new branch and let an ungated commit land on the wrong branch. Both are scoped to the current working tree (`.auto-task/` is per-worktree), so a parallel run in another worktree can never trigger a false positive; the warn hook stays silent and near-free in non-auto-task repos and when `jq` is absent.

### Changed

- **Hook wiring.** `warn-checkout-drift.sh` is registered as a third `PreToolUse`/Bash hook in `hooks/hooks.json`, `install.sh`, and `settings-fragment.json` (the plugin now wires five core hooks).

### Docs

- `skills/auto-task/SKILL.md` (Phase 1 branch setup + a checkout-drift-guard/worktree-lifecycle note), `ARCHITECTURE.md` (Phase 1 diagram box, new Hook 3, drift-block note on Hook 2, and the "Parallel runs" section rewritten from *one-worktree-per-run-you-set-up* to *automatic*), and `README.md` (hook list, five-core-hooks count, "Running multiple runs in parallel") all updated.

### Tests

- `tests/enforcement-spine.test.sh` expanded 38 → 45 assertions — seven new drift assertions in an isolated fixture: the enforce-gates drift block, a no-drift control, and the warn hook's behavior on drift / matching-branch / jq-absent / malformed-state / no-`.auto-task/` cases.

## [0.1.7]

### Added

- **Pre-run version check.** Before each NEW `/auto-task` run, Phase 1 now does a fresh, best-effort version check — the SessionStart `check-version.sh` gains a `--plain` output mode (a bare one-line notice instead of the SessionStart JSON), and the Phase-1 step runs it with the 24h throttle bypassed and, if the installed plugin is strictly behind upstream, **asks once** whether to update first or proceed. Fully fail-open (no `${CLAUDE_PLUGIN_ROOT}` / script missing / offline / no jq / current-or-ahead → silent proceed); bounded by the script's existing `--connect-timeout 2 -m 5`; **skipped on resume** (`/auto-task` with no args, where swapping the plugin under a mid-flight run would be wrong). The per-run check does **not** write the SessionStart throttle stamp (so it can't suppress the next SessionStart notice), and the default SessionStart JSON output is unchanged. `tests/enforcement-spine.test.sh` grows 32 → 38 (six `CV-*` assertions covering plain-vs-JSON, silent-when-current/ahead/unreachable, and stamp-untouched); README and `ARCHITECTURE.md` document it.

## [0.1.6]

Worktree safety: `/auto-task` is now safe to run inside a linked git worktree, so several runs can execute in parallel (one worktree per run). Also folds in the unreleased `DRIFT CHECKPOINT` rename.

### Fixed

- **`.auto-task/` exclusion now works in a linked worktree.** Phase-1 branch setup resolved the literal `.git/info/exclude`, which errors in a worktree (there `.git` is a *file*, not a directory), so `.auto-task/` was never excluded and could leak into `git status`. It now resolves `$(git rev-parse --git-common-dir)/info/exclude` — `.git/info/exclude` in a normal checkout, the shared common-dir exclude from any worktree (one write covers every worktree of the clone). Exclude prose aligned across `skills/auto-task/SKILL.md`, `ARCHITECTURE.md`, `auto-task-plan`, `auto-task-commit`, and `README`.
- **Gate / Stop / history hooks resolve the run's worktree, not a stale dir.** `enforce-gates.sh`, `prevent-mid-protocol-stall.sh`, and `inject-history-reminder.sh` now resolve `project_dir` as the git worktree root **of** `${CLAUDE_PROJECT_DIR:-$PWD}` (toplevel-of-base), so a commit / turn-end from a subdirectory still finds `.auto-task/<branch>/` at the top — closing a latent fail-open — while keeping an explicitly-set `CLAUDE_PROJECT_DIR` authoritative (a commit from a nested/embedded repo or submodule is not silently retargeted). Byte-identical to the old resolution on the normal-checkout happy path; only the subdir-with-`CLAUDE_PROJECT_DIR`-unset case changes (was fail-open, now enforces).

### Changed

- **`COMMIT CHECKPOINT` → `DRIFT CHECKPOINT`.** The `auto-task-implement` checkpoint markers were renamed to reflect that they are drift-check points, not commit points (only Phase 5 commits).

### Docs

- **"Running multiple runs in parallel"** added to `README` and `ARCHITECTURE.md`: one git worktree per run; state and gate/Stop enforcement are isolated per worktree.

### Tests

- `tests/enforcement-spine.test.sh` expanded 28 → 32 assertions — per-worktree / subdirectory / nested-repo state resolution for the gate and Stop hooks, each proven to discriminate the fix from a revert.

## [0.1.5]

Findings from a full read-through evaluation of the pipeline. The enforcement spine (hooks) was already covered by the test suite; these are defects in the model-facing prose that the mechanical tests could not catch.

### Fixed

- **Gate B no longer reviews an empty diff.** The Gate B spawn prompt handed the adversarial `task-execution-verifier` `git diff <base>...HEAD`, but the single-commit rule means nothing is committed until Phase 5 — so at Gate B `HEAD == base` and that diff was **empty**. The adversarial pass (the strongest gate for STANDARD/HEAVY tasks) saw no code and trivially succeeded. It now uses `git diff <base>` (the uncommitted working tree), matching Phase 3 and Gate A; the verifier agent's input doc was corrected to use the working-tree diff for both gates and to treat a `..HEAD`/`...HEAD` form as a bug to fall back from.
- **Removed a self-contradicting operating principle.** SKILL.md's "Commit after each phase" operating principle contradicted the NON-NEGOTIABLE single-commit rule (only Phase 5 commits) and the `enforce-gates.sh` hook that backs it. It now states the single-commit behavior and attributes durability/resumability to the on-disk `STATE.json`, not to intermediate commits.

### Changed

- **The bundled siblings now implement the read-before-review contract themselves.** `auto-task-code-review`, `auto-task-verify`, and `auto-task-fix` now read `.auto-task/<branch>/` history (CONTEXT.md, TRACE.md, STATE.json) before forming findings — so they don't re-litigate settled Human choices or miss an issue an earlier pass left open — and append a standalone `TRACE.md` entry on completion. The append is **suppressed under `/auto-task` orchestration** (the orchestrator owns TRACE writes; a sibling append would double-write the log), mirroring the existing caller-note pattern. Each references the orchestrator's canonical TRACE.md format rather than duplicating it. Previously this behavior lived only in the orchestrator and the verifier agent.

### Docs

- **`.auto-task/<branch>/fixes/` is now in the canonical layout.** The orchestrator's branch-setup `mkdir` and both of SKILL.md's layout enumerations omitted `fixes/`, which `auto-task-fix` writes patch notes to and `auto-task-plan` / `auto-task-implement` / `auto-task-code-review` read; `ARCHITECTURE.md` already listed it. SKILL.md now creates and documents it, so all four layout enumerations agree.

## [0.1.4]

### Fixed

- **Review-staleness hash is now config-stable.** `enforce-gates.sh` pins the diff flags (`--no-color --no-ext-diff --no-textconv --no-renames --diff-algorithm=myers --src-prefix=a/ --dst-prefix=b/`) when computing `git diff <base> | git hash-object`. Without them, a user's git config (`diff.algorithm`, `diff.renames`, `diff.noprefix`, `color`, textconv, external diff) could shift the diff text and produce a spurious staleness block on an unchanged tree. The skill records `reviewed_diff_sha` with the same flags. Validated by the test suite under a hostile git config.
- **Raw-mode commit detection no longer over-blocks.** When `jq` can't decode the payload, `enforce-gates.sh` previously treated any Bash command merely *mentioning* "git commit" (e.g. `echo see the git commit guidelines`) as a commit and blocked it during an active run. The raw-JSON regex now requires `git commit` at a command boundary (start, a shell separator, or the JSON value's opening quote), keeping the fail-closed bias only for the genuinely-ambiguous case.
- **Stop hook can no longer soft-lock a session.** `prevent-mid-protocol-stall.sh` now keeps a consecutive-block counter keyed on the run's progress signature. While the run advances the counter resets and blocking continues as designed; if the run is frozen in the exact same state for `AUTO_TASK_STALL_LIMIT` (default 25) turn-ends, the hook releases the stop with a warning so a genuinely-stuck run stays recoverable.
- **`check-version.sh` no longer risks a network call on every session.** When `CLAUDE_PLUGIN_DATA` is unset the 24h throttle stamp now falls back to a temp dir (previously the throttle was skipped entirely, re-firing the `curl` each session). Added `--connect-timeout 2` to bound the worst case on an unreachable host.

### Changed

- **`install.sh --uninstall` now reports copy-mode leftovers.** Files installed with `--copy` (real files, not symlinks) are never auto-deleted, but uninstall now lists them with `rm -rf` suggestions instead of silently leaving them.

### Docs

- Fixed an incorrect branch-path example in `skills/auto-task/SKILL.md` (`fix/foo` maps to `.auto-task/fix/foo/`, not `.auto-task/auto-task-fix/foo/`).
- README Status now reflects the current version.
- Test suite expanded from 19 to 28 assertions: raw-mode commit detection, the Stop-hook stall-breaker, and the AI-attribution hook are now covered.

## [0.1.3]

### Changed

- **`hooks/check-version.sh` now compares versions in pure bash** instead of `sort -V`. This fixes two edge cases: (1) hosts whose `sort` lacks `-V` (e.g. BusyBox) no longer silently disable the notice for the wrong reason, and (2) SemVer prerelease/build strings are handled correctly — an upstream `0.2.0-beta` of the same core as your release no longer triggers a spurious "update available" notice, while a real release upgrade over a local prerelease still does. Build metadata (`+...`) is ignored; any parse ambiguity stays silent (fail-safe).

## [0.1.2]

### Fixed

- **Update command uses the marketplace-qualified plugin name.** The SessionStart notice (`hooks/check-version.sh`) and README now tell users to run `/plugin update auto-task@auto-task-plugin`; the bare `/plugin update auto-task` fails with "Plugin not found" (the `update` resolver requires the `@marketplace` qualifier, even though `install`/`details` accept the bare name).

## [0.1.1]

First version that is actually installable as a marketplace plugin (the v0.1.0 manifest failed `claude plugin validate` with 4 errors).

### Added

- **`.claude-plugin/marketplace.json`** — the repo is now its own single-plugin marketplace (`source: "./"`), installable with `/plugin marketplace add o8o0o8o/auto-task-plugin` + `/plugin install auto-task@auto-task-plugin`.
- **`hooks/hooks.json`** — plugin-native hook wiring (event map nested under the top-level `hooks` key) that auto-wires `block-ai-attribution`, `enforce-gates`, `prevent-mid-protocol-stall`, and the new SessionStart notice via `${CLAUDE_PLUGIN_ROOT}`. No `settings.json` editing required on install.
- **`hooks/check-version.sh`** — SessionStart update notice. Compares the installed version against the published `plugin.json` on GitHub at most once per 24h (cached in `${CLAUDE_PLUGIN_DATA}`) and prints a one-line `/plugin update auto-task@auto-task-plugin` reminder when behind. Fails open and silent on every error path (no jq/curl, offline, malformed, current/ahead).

### Changed

- **`.claude-plugin/plugin.json`** — rewritten to a spec-valid manifest (object `author`; dropped the invalid array `skills`/`agents`/`hooks` and the unrecognized `comment`/`requires` fields — components are auto-discovered). Plugin renamed to `auto-task`, so skills invoke as `/auto-task:auto-task` under a marketplace install.
- **`README.md`** — the marketplace flow is now the primary documented install; `install.sh` is demoted to the offline/dev fallback. Corrected the prerequisites list and the sibling-skill namespacing note.
- **`skills/auto-task/SKILL.md`** — component-preflight now documents that siblings are namespaced (`auto-task:<name>`) under a marketplace install and bare under the `install.sh` fallback; the orchestrator invokes whichever form is registered.
- **`settings-fragment.json`** — relabeled fallback-only; replaced the non-existent `${CLAUDE_PLUGIN_DIR}` (and the non-expanding `${CLAUDE_PLUGIN_ROOT}`) with an explicit absolute-path placeholder, since plugin path variables do not expand in a hand-merged `settings.json`.

## [0.1.0]

Initial extraction of the `auto-task` skill from `~/.claude/skills/auto-task/` into a self-contained, shareable Claude Code plugin. See `PACKAGING_PLAN.md` for the open work items that remain before a real v0.1.0 release.

### Added

- **Phase 1 approach selection (`auto-task` v1.6).** Before the detailed plan is written, the pipeline now decides *which* approach to plan when more than one materially-different implementation exists (the choice changes blast radius, risk, dependencies, API shape, or migration cost). It generates 2–3 short candidate sketches (inline for simple-but-branching tasks; parallel `general-purpose` agents from distinct angles for complex/high-risk ones), scores them on fixed dimensions, and selects. Clear winners are auto-selected; close calls and high-stakes choices (schema/data, external API, auth/payments) fold into the existing Phase 1 `AskUserQuestion` gate rather than adding a new interaction. The decision — chosen approach plus rejected candidates with rejection rationale — is recorded in `PLAN.md`'s new `## Approach` section, in `state.history` (`define-approach`), and in the CONTEXT.md handover. Closes the "wrong-approach-entirely plan sails through approval" gap: the pipeline previously only verified that the first approach the model landed on was *built correctly*, never whether a *better* approach existed.
- `skills/auto-task/` — orchestrator skill (SKILL.md + ARCHITECTURE.md).
- Forked bundled copies of the six sibling skills, namespaced under the `auto-task-` prefix to avoid clobbering the user's existing skills: `auto-task-plan`, `auto-task-implement`, `auto-task-verify`, `auto-task-code-review`, `auto-task-commit`, `auto-task-fix`. Snapshot date: TODO (record the upstream commit SHA on each).
- `agents/task-execution-verifier.md` — two-mode verifier (completeness / adversarial) spawned at Gate A and Gate B. Read-only tool set (`Read`, `Glob`, `Grep`, `Bash`). Implements the read-before-review contract (consults `TRACE.md` and `CONTEXT.md` before forming findings).
- `hooks/block-ai-attribution.sh` — refuses commits / PR bodies containing AI-attribution markers.
- `hooks/enforce-gates.sh` — blocks `git commit` during a run until all required gates have passed. Path now resolves `.auto-task/<branch>/STATE.json` (was `.patches/AUTO-TASK-STATE.json` in the source machine's settings.json).
- `hooks/prevent-mid-protocol-stall.sh` — Stop hook backed by `expected_next_action` in STATE.json. Blocks turn-ends mid-pipeline.
- `settings-fragment.json` — merge template for `~/.claude/settings.json` (the three hooks).
- `.claude-plugin/plugin.json` — plugin manifest. Field names are placeholders; verify against the current Claude Code plugin spec before locking.
- `README.md`, `LICENSE` (MIT), this changelog.
- `PACKAGING_PLAN.md` — the work plan and open questions for getting to v0.1.0.

### Changed

- **Phase 1 critique is now a bounded re-plan loop, not advisory-only (`auto-task` v1.6).** Previously the critique agent's output was appended to `PLAN.md` with an explicit "do NOT auto-amend" instruction — the user had to mine the bullet list for what mattered and request edits manually. Now each finding is classified **structural-fixable** (a plan defect resolvable without the user: missing edge case, omitted blast-radius file, non-falsifiable AC, missing rollback step) or **judgment-required** (a tradeoff/scope call). Structural findings are auto-amended and the critique is re-run on the revised plan (cap: LIGHT 1 round, STANDARD/HEAVY 2), mirroring the global "re-invoke code-review after every fix" rule. The `## Critique` section now has two parts — **Auto-fixed** and **For your judgment** — so the approval gate shows a repaired plan plus only the genuine judgment calls. Logged per round to `state.history` (`define-critique`).
- **`prevent-mid-protocol-stall.sh` now fails closed on a missing/null `expected_next_action` mid-run.** Previously an unset or `null` field allowed the stop, contradicting the skill's own stated default ("writing post-approval state without an explicit choice keeps the turn alive is the correct failure mode"). Now, once past the `approved`/`done` guards, only the two explicit user-gate values allow a stop; anything else — including a forgotten field — blocks. `SKILL.md`'s hook-behaviour spec was reconciled to match.
- **`base` is now defined as HEAD at run start** (the fork point for a new branch, the current tip for a reused one), making `git diff <base>` exactly this run's work for the change diagram, verifiers, and staleness hash. Documented the pre-existing-uncommitted-changes caveat. (Replaces the earlier, ambiguous "merge-base against default for reused branches" wording.)
- **`ARCHITECTURE.md` no longer claims the plugin ships `git push` deny / `gh pr create` ask permissions** — it doesn't. Reframed as opt-in recommended permissions, with the Phase 5 skill prompt as the actual shipped gate.
- **Hooks now fail safe instead of fail-open.** All three hooks dropped `set -e` (a stray non-zero from `jq` on malformed/partial JSON previously crashed the script into a fail-open exit) in favour of `set -uo pipefail` with individually guarded reads. Failure direction is now chosen per hook by recoverability (see the dedicated note below): `enforce-gates.sh` fails **closed** (blocking one commit can't loop); `prevent-mid-protocol-stall.sh` fails **open** (an unrecoverable block would soft-lock the session). Both still allow freely when no run is active, so unrelated repos and commits are unaffected. `block-ai-attribution.sh` now also works without `jq` by scanning the raw payload, so a missing `jq` can't let an attribution marker slip through.
- **`prevent-mid-protocol-stall.sh` fails OPEN (not closed) when it can't read state.** Verified against the Claude Code hook spec: Stop hooks have **no built-in loop protection** and no `stop_hook_active` signal, so an unconditional block soft-locks the session — and a `jq`-missing block in particular can't be cleared mid-session. The hook now blocks only on positive, readable evidence the model should continue (a valid STATE.json saying so); when `jq` is missing or STATE.json is unparseable it **allows the stop and warns**. This corrects the earlier (over-eager) decision to fail this hook closed. Commits stay gate-blocked regardless, so allowing a stop is recoverable and harmless; a wrongful block was not. Confirmed the `{"decision":"block","reason":…}` + exit 0 contract is correct, and that `"matcher": ""` is the right registration for Stop hooks.
- **`enforce-gates.sh` now enforces review staleness.** The gate booleans (`code_review.passed`, `clean_pass_after_last_fix`) are values the model sets for itself. The hook now also binds them to the actual code: on a clean review the orchestrator records `gates.code_review.reviewed_diff_sha = git diff <base> | git hash-object --stdin`, and the hook recomputes that hash at commit time and blocks if it differs — catching the common failure mode of editing code after the review went clean and committing without re-review. Backward-compatible: the check is skipped when `state.base` or `reviewed_diff_sha` is absent, so it can only add a block, never spuriously allow. New state fields: `base` (base-commit SHA) and `gates.code_review.reviewed_diff_sha`. `expected_next_action` also added to the `ARCHITECTURE.md` schema (it was already in `SKILL.md`).

### Fixed

- **Reconciled the sibling skills' standalone gates with the orchestrator's NON-YIELDING CONTRACT.** Only `auto-task-code-review` carried the protective "Caller note" that tells an orchestrator the skill's output is INPUT (not an end-of-turn); the other five still contained standalone stops that, taken literally during a run, break the "one human gate" guarantee: `auto-task-fix`'s "STOP for user approval" + a Phase 5 reviewer-agent spawn, `auto-task-commit`'s "Commit with this message? Yes/Edit/Cancel" prompt, `auto-task-implement`'s "Stop and wait for the user" at checkpoints, and `auto-task-plan` / `auto-task-verify`'s user-directed asks/suggestions. Added a conditional caller note to each: under orchestration the standalone gate is suppressed and control returns to the caller; run directly by a human, the gate behaves as before. Also pointed `auto-task-fix`'s standalone Phase 5 review at the `auto-task-code-review` skill instead of a hand-rolled `general-purpose`/`code-reviewer` agent.
- **Completed the `.patches/` → `.auto-task/<branch>/` migration across all six bundled sibling skills and `ARCHITECTURE.md`.** Previously only the orchestrator `SKILL.md` and `enforce-gates.sh` had been migrated; the siblings still read/wrote `.patches/`, which is not in `.git/info/exclude` and not pre-stage-cleaned — so harness scratch could leak into commits. The siblings now resolve everything under the gitignored `.auto-task/<branch>/` root.
- **`auto-task-commit` no longer instructs the model to commit harness files.** The rule "If `.patches/` files are in the diff, include them" directly contradicted the orchestrator's "never commit `.auto-task/`" invariant; it is replaced with an explicit unstage-and-warn rule.
- **Corrected the branch-path examples in `SKILL.md`** (`fix/auth-bug` → `.auto-task/fix/auth-bug/`, not the namespacing-mangled `.auto-task/auto-task-fix/auth-bug/`). A divergent path makes the gate and Stop hooks find no state file and fail open. Added an explicit note that the folder name must match `git branch --show-current` verbatim.
- **`ARCHITECTURE.md`** state-file path, filename (`STATE.json`, not `AUTO-TASK-STATE.json`), on-disk layout, and `gates.code_review.tool` value (`skill:auto-task-code-review`) brought back in sync with `SKILL.md` and the hooks.

### Added

- **`tests/enforcement-spine.test.sh`** — the plugin's first automated integration test. Drives a real `STATE.json` through the full documented phase/gate lifecycle (STANDARD + LIGHT tiers) in a throwaway repo and asserts the real hooks behave correctly at every transition: commit blocked until gates pass, tier-specific Gate B requirement, review-staleness (post-review edit re-blocks, revert clears), wrong-review-tool block, every Stop-hook yield/block decision, and the fail-open/fail-closed edges. 19 assertions, all passing. Covers the mechanical state-machine↔hooks contract (not model-follows-prose, which still needs a live run).
- **Component preflight in Phase 1.** Before any git work, the orchestrator confirms all six sibling skills and the `task-execution-verifier` agent are available, and STOPs with an install pointer if any is missing — instead of silently substituting a hand-rolled component and breaking the pipeline's guarantees. Re-runs on resume.
- **Optional recommended-permissions block** in `settings-fragment.json` (inert `_optional_recommended_permissions` key) — copy-pasteable `deny git push` / `ask gh pr create` defence-in-depth for the Phase 5 push, documented as opt-in in the README and `ARCHITECTURE.md`.
- `hooks/inject-history-reminder.sh` — the optional `UserPromptSubmit` hook referenced (but previously missing) in `settings-fragment.json`. Informs the session when `.auto-task/<branch>/` history exists so any reviewer honours the read-before-review contract. Off by default.

### Known issues

- `task-execution-verifier` agent has a real prompt but has not yet been exercised end-to-end inside a real auto-task run — treat Gate A/B as functional but not battle-tested.
- Plugin manifest field names not verified against the current spec (the canonical install path is `install.sh`, not `/plugin add`, so the manifest is currently informational). _Resolved in 0.1.1 — the manifest is now spec-valid and the marketplace install is the primary documented path._
- Bundled sibling skills now share the orchestrator's `.auto-task/<branch>/` working-directory convention, but their richer read-before-review behaviour (reading CONTEXT.md / TRACE.md, appending trace entries) still lives mostly in the orchestrator and the verifier agent rather than in each sibling. _Resolved in 0.1.5 — the three audit siblings (`auto-task-code-review`, `auto-task-verify`, `auto-task-fix`) now implement the contract directly._
- `enforce-gates.sh` path resolution: assumes `CLAUDE_PROJECT_DIR` is set to the repo root (or falls back to `$PWD`). Verify this environment variable is provided by the Claude Code hook context. _Resolved in 0.1.6 — all three hooks now resolve `project_dir` as the git worktree root of `${CLAUDE_PROJECT_DIR:-$PWD}`, robust to an unset/misset `CLAUDE_PROJECT_DIR`, subdirectories, and linked worktrees._
