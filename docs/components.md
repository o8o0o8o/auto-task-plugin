# Components

Everything the plugin ships, and what each piece is responsible for.

- [Skills](#skills)
- [The spec's two halves](#the-specs-two-halves)
- [Agent](#agent)
- [Core hooks](#core-hooks)
- [The commit gate in detail](#the-commit-gate-in-detail)
- [Test coverage](#test-coverage)

## Skills

### The orchestrator

**`auto-task`** composes the eight bundled sibling skills and the verifier agent across the pipeline — Define → Execute → Self-verify → Review → Handover, plus the optional post-push phases. It ships as a **spine plus reference files**; see [below](#the-specs-two-halves).

### Eight namespaced sibling skills

`auto-task-plan` · `auto-task-implement` · `auto-task-verify` · `auto-task-code-review` · `auto-task-commit` · `auto-task-fix` · `auto-task-docs` · `auto-task-release`

The first six are forked from the upstream skills and patched to participate in the [read-before-review contract](usage.md#read-before-review-contract). `auto-task-docs` and `auto-task-release` are new to this plugin — the two [optional steps](optional-features.md).

The `auto-task-` prefix keeps them distinct from your existing `/plan`, `/verify`, and so on. Under a marketplace install they are further namespaced (`auto-task:auto-task-plan`); under the `install.sh` fallback they keep the bare form.

### Standalone tools (NOT part of the pipeline)

| Skill | What it does |
|---|---|
| **`auto-task-stats`** | Read-only maintainer tool. Reports local run-outcome telemetry — completion rate, where runs stall, per-tier fix/review effort, Gate B coverage. See [Telemetry](telemetry.md). |
| **`auto-task-gc`** | Disk and worktree cleanup. Reports each worktree's size, age, and merge status, then safely reclaims the merged/stale ones on confirmation — branch refs preserved, matching `.auto-task/<branch>/` pruned. See [Worktree space control](optional-features.md#worktree-space-control-auto-task-gc). |
| **`auto-task-resume`** | Run picker. Lists every run across your worktrees in a clean table and continues the one you choose. Fixes the `claude --resume` gap — that resumes a *conversation*, not a *run*. Backed by the read-only `hooks/auto-task-resume-list.sh` engine. See [the run picker](usage.md#the-run-picker-auto-task-resume). |

Invoke each as `/auto-task:auto-task-<name>` (marketplace) or `/auto-task-<name>` (`install.sh` fallback).

## The spec's two halves

Only `SKILL.md` is loaded into context on every turn of every run, so the spec is split.

**`SKILL.md` is the always-loaded spine** — the pipeline, the loop rule, the effort tiers, the yield-point/anti-stall contract, the Acceptance-Criteria contract and INCONCLUSIVE floor, the trace contract, and each phase's gate condition plus non-negotiables.

**`skills/auto-task/references/` is the on-demand half.** The bulky step-by-step contracts live in seven files that the spine points at with a `**MANDATORY READ:**` directive at the point of use:

| Reference | Carries |
|---|---|
| `phase-1-preamble.md` | Phase 1's procedural steps, AC pre-flight, the critique loop, the risk disclaimer, comment-voice resolution |
| `phase-3-gates.md` | Phase 3 (self-verify), Gate A, Gate B — full contracts |
| `phase-5-handover.md` | All twelve Phase-5 handover steps + the single-commit rule's exceptions |
| `phase-6-8-post-pr.md` | Phases 6 (bot review), 7 (preview), 8 (external changes) |
| `phase-9-release.md` | Phase 9 (release) |
| `settings.md` | The full settings-key table, two-scope merge, remote telemetry, autonomy sub-contracts |
| `state-schema.md` | `STATE.json` per-object semantics |

### What the split cost and what guards it

The carve cut the always-loaded spine from **397,676 B to 122,866 B (−69.1%)** — roughly 97k tokens down to ~30k on every turn.

**Every line of the original spec was preserved byte-for-byte at the time of the carve**, so no contract was dropped or reworded by the split itself.

Sixty-five of those base lines have since been deliberately **retired** — each with a stated reason, covering the estimate schema change, the hook-stamped run clock, Gate B becoming a bounded loop, the Phase-4 loop being graded the same way, the review moving into a subagent, and the PR body's lede/`## Review this first` reshape. `tests/spec-inventory.sh` names each retirement with its reason and reports the count (`retired=65`), so a retirement is reviewable rather than silent, and everything not named stays under guard.

**It is not a *pure* move, though.** A large minority of the spine's 623 non-blank lines are freshly written per-phase summaries and `MANDATORY READ` directives — and since this spec *is* the behavior, treat that as a real (if narrow) behavioral surface. Reviewing the change caught several summaries that over-generalised their source contract; the guards below exist to keep that class from recurring.

Two guards keep it honest:

- **`tests/spec-inventory.sh`** proves every base line survives somewhere, **except the ones explicitly retired in its `RETIRED_PREFIXES` list**. A prefix matching zero or several base lines, or an entry that stops corresponding to a real shortfall, is itself reported. It also proves no heading is duplicated.
- **`tests/enforcement-spine.test.sh`** asserts the must-stay contracts are in **`SKILL.md` specifically**, with a mutation probe in `tests/spec-helper.test.sh` proving those assertions really fail if the content is moved.

Test assertions search the spine *and* the references via `tests/lib/spec.sh`, so a future boundary adjustment costs no test churn.

## Agent

**`task-execution-verifier`** — a read-only verifier spawned at Gate A (completeness) and Gate B (adversarial), with fresh context per spawn. See [where independence lives](architecture.md#where-independence-actually-lives).

## Core hooks

All wired automatically by the plugin install, via `hooks/hooks.json`.

### Blocking hooks (PreToolUse on Bash)

| Hook | What it enforces |
|---|---|
| `enforce-gates.sh` | The commit gate. [Detailed below](#the-commit-gate-in-detail). Fails **closed**. |
| `block-ai-attribution.sh` | Refuses commits and PR bodies containing `Co-Authored-By: Claude`, `🤖 Generated`, and similar. |
| `guard-dangerous-ops.sh` | Fail-closed interrupt during an active run. Blocks commands outside the safe action envelope — destructive filesystem removals, force-push to a protected branch, destructive SQL, infrastructure delete/apply, migration-apply, deploy/publish — unless `unattended_external` is true, so the model must surface them instead of running them unattended. Raw-mode aware; benign build cleanup and own-branch force-push are allowed. |
| `prevent-mid-protocol-stall.sh` | *(Stop event)* Blocks turn-ends mid-pipeline by reading `expected_next_action` from `STATE.json`. The antidote to sub-skill output looking completion-shaped. |

### Non-blocking hooks

| Hook | Event | What it does |
|---|---|---|
| `warn-checkout-drift.sh` | PreToolUse | Warns on every command when an active run exists on a branch other than the one checked out — the proactive half of the checkout-drift guard. **Never blocks.** Silent and near-free in non-auto-task repos. |
| `stamp-run-clock.sh` | PreToolUse + Stop | **Pure measurement.** Stamps `created_at` once and refreshes `updated_at` from `date -u`. [Details below](#the-run-clock). |
| `record-outcome.sh` | Stop | **Opt-in.** Appends one derived JSON row to the clone's local ledger at `phase: done`. See [Telemetry](telemetry.md#local-run-ledger-opt-in). |
| `send-telemetry.sh` | Stop | **Opt-in, off by default.** The remote counterpart — POSTs an anonymized row to your HTTPS endpoint. See [Remote telemetry](telemetry.md#remote-telemetry-opt-in-off-by-default). |
| `release-notes.sh` | SessionStart | Best-effort "what's new" notice, read from the bundled `.claude-plugin/release-notes.json`. No network, no changelog parsing. See [Release notes](install.md#release-notes--what-you-just-got). |
| `check-version.sh` | SessionStart | Best-effort update notice, at most once per 24h. See [Updating](install.md#updating). |
| `suggest-cleanup.sh` | SessionStart | Best-effort worktree-cleanup nudge. Cheap and local-only — no `du`, no network. See [Worktree space control](optional-features.md#worktree-space-control-auto-task-gc). |
| `inject-history-reminder.sh` | UserPromptSubmit | **Opt-in, off by default.** Tells non-bundled tools an `.auto-task/<branch>/` history folder exists. See [Optional extras](install.md#optional--opt-in-extras). |

Every non-blocking hook fails open and silent on every error path.

### Deterministic helpers (NOT hooks)

Pure, deterministic scripts the orchestrator calls directly. No hook event, no `hooks.json` entry — they read, compute and print JSON.

| Helper | Called at | What it does |
|---|---|---|
| `checks.sh` | Phase 3, and again at commit time | Seven hygiene/defect rows over the diff — secret-scan, conflict markers, debug artifacts, large files, **test-integrity**, diff size, tests-added. A `fail` row blocks. |
| `analyzer-delta.sh` | Phase 4, before the reviewer spawns | Runs a static analyzer **twice** — at `<base>` and on the current tree — and returns only the findings the run **introduced**. Never blocks: every failure is `status: "skip"` with a reason. [Details below](#the-analyzer-delta-layer). |
| `requirements-coverage.sh` | Phase 1 and Phase 5 | Reports whether every dissected requirement is covered by an AC and satisfied at the end. |
| `estimate.sh` | Phase 1 | Pre-execution duration/token estimate from tier, D/R, AC count and file count. |

### The analyzer-delta layer

The problem it solves: a linter run against a codebase reports everything already wrong with it. Handing that to a code review buries the change's own defects in pre-existing noise.

So the analyzer runs on both sides and only the difference is reported. Anything broken before appears in both runs and cancels.

**Findings are matched by identity, never by position.** Inserting ten lines at the top of a file shifts every finding below it; a position-keyed comparison would report all of them as new — a noise flood on exactly the change that touched the most code. A finding is keyed on `(file, position-stripped message)`: the line number never enters the key, the column is stripped, remaining digit-only tokens collapse to `#`, and paths are made tree-relative so a tool that prints absolute paths still keys identically on both sides. `SC2086` survives, so the rule is still identified; repeated occurrences of one rule in one file are told apart by count.

**Which analyzer runs**, in order: the `analyzer_command` setting → a direct invocation the helper constructs itself (a marker in the repo *and* the tool already on `PATH`) → skip. It never installs anything and adds no dependency; a machine without a suitable tool simply gets a skip row. Project scripts like `npm run lint` are reachable only by naming them in the setting, because a `--fix` hidden inside `package.json` is invisible to a surface check. Name a tool that prints **machine-readable `file:line` output on stdout** rather than a wrapper. **Only stdout is keyed** — stderr carries diagnostics, not findings, and mixing the two is what made "did this side run?" ambiguous; it is discarded before the output is examined at all, so findings written there are simply not seen. Redirect such a tool (`2>&1`) or pick a stdout formatter. Separately, stdout with no positional shape is skipped rather than guessed at, regardless of exit code, so a clean-run banner ("All checks passed!", a `make` recipe echo) produces a permanent skip whose `detail` names the shape.

**Safety properties**, each measured rather than assumed:

- The base tree comes from a detached worktree, never `git stash` — stashing moves the very hash `reviewed_diff_sha` pins.
- A command containing `--fix`, `--write`, `-w`, `--apply` or `--fix-dry-run=false` is refused; if one mutates the tree anyway it is detected and reported, never auto-reverted.
- Both sides are bounded by `analyzer_timeout_sec`, killing the whole process group; a timeout always outranks the "did this side run?" test so a truncated scan cannot inflate the result.
- The base result is cached per `(base sha, command, tool version, key format)`, written atomically with a record-count sentinel — a truncated cache is recomputed, never trusted. The **key format** component is the one whose omission was measured to matter: the cache stores keys, so changing how a key is built made a warm cache incomparable with a fresh scan and reported every finding as both introduced and resolved.
- Renames are followed, so moving a file does not double-report every finding in it.
- Submodule contents are excluded from both sides. `git worktree add` does not initialise submodules, so a submodule's pre-existing findings would otherwise exist only on the current side and report wholesale as introduced — measured at 2 false positives on a tree whose true answer was 0.

Findings reach Phase 4 as **advisory context**: severity comes from the tool, and the reachability grading that decides control flow stays with the orchestrator.

### The run clock

`stamp-run-clock.sh` writes into a hook-owned sidecar, `.auto-task/<branch>/.run-clock.json`, so a run's duration is **observed rather than narrated**. It previously came from the first and last `state.history[].at` strings, which the model writes without access to a clock.

- The clock **seals** at `phase: done`, so a later ad-hoc command in the worktree cannot inflate an already-recorded run.
- A negative or over-12h span is **rejected to `null`** rather than reported as a number — a run paused overnight is not a meaningful "how long did this take" figure. That rejection is deliberately distinguishable from "no clock", which still falls back to the old history formula for runs that predate this.
- Derivation and bounds live once in `hooks/lib/run-clock.sh`, read by all three duration consumers (`record-outcome.sh`, `send-telemetry.sh`, `auto-task-stats.sh`).
- The two row writers stamp the clock themselves immediately before reading it, so the recorded row includes the final turn regardless of hook execution order. An event's hooks run in parallel, so registration order is not a contract.

It never writes `STATE.json`, and fails open and silent (`tests/run-clock.test.sh`).

### Per-run version check

On top of `check-version.sh`'s cached SessionStart notice, Phase 1 runs a fresh **per-run version check** — the same script via `--plain`, throttle bypassed — at the start of every NEW run. If you're behind, it asks once whether to auto-apply the update via `hooks/apply-update.sh` or proceed on the current version.

It is separately bounded (`--connect-timeout 2 -m 5`), fully fail-open, never touches the SessionStart throttle stamp, and is skipped on resume.

### `settings-fragment.json`

Fallback only. The marketplace install wires the hooks for you; this snippet is for the offline/dev `install.sh` path, plus the optional recommended-permissions block. The history reminder is wired in both install paths and gated by the `history_reminder_enabled` setting, so no snippet edit is needed to enable it.

## The commit gate in detail

`enforce-gates.sh` blocks `git commit` during an auto-task run unless every one of these holds. It **fails closed**: with `jq` missing or `STATE.json` unparseable during an active run, it blocks rather than letting the commit through.

### 1. Review gates passed

All of `gates.code_review.passed`, `gates.code_review.tool === "skill:auto-task-code-review"`, `gates.code_review.clean_pass_after_last_fix`, and Gate B's gate (or its skip reason).

### 2. Review freshness

If `git diff <base>` no longer hashes to the recorded `gates.code_review.reviewed_diff_sha`, code changed after the review went clean, and the commit is blocked until a re-review.

### 3. The fix-loop budget

It also enforces the **fix-loop budget**. Once the loop count `max(iteration.fix, iteration.review)` exceeds the effort tier's cap — LIGHT 2 / STANDARD 4 / HEAVY 6, defined once in `hooks/lib/loop-budget.sh` — the commit blocks until `gates.loop_budget.acked_through` records your go-ahead. The ack raises the budget to the next cap rung above the current count, so one ack always suffices and the check-in returns rather than being dismissed forever.

The same budget is additionally consulted at **Gate-B entry**, as a spec-level self-check — a Gate B pass is an `Agent` spawn no hook observes. The same helper defines Gate B's own per-scope pass caps (`lb_gate_b_cap`, `lb_gate_b_regate_cap`).

### 4. Diff hygiene

**The one check that reads the *diff itself*** rather than a field the run wrote about the diff.

It runs `hooks/checks.sh` over the **worktree union the index** — `git diff <base>` plus untracked files, *and* `git diff --cached <base>`, because `git commit` commits the index, and content staged then edited out of the working file would otherwise be invisible.

It blocks on any `fail` row: a credential outside test/fixture paths, a leftover merge-conflict marker, or a weakened test (a skip/focus marker added, or assertions removed with none added back). `warn` rows never block, so a fake credential in a fixture still commits.

**Hardening — each of these was a measured bypass.** The scanner reads the diff with pinned flags, literal pathspecs, and byte (`LC_ALL=C`) semantics; enumerates paths NUL-delimited; passes every path to a non-git tool as `./path` so an option-shaped filename cannot be eaten as a flag; extracts content lines by hunk position rather than by `+++`-prefix pattern; and decides binary-ness from the diffed content rather than from `numstat`.

So a local `diff.external` / textconv setting, a `.gitattributes` entry (`* -diff`, `*.js binary`), and a non-ASCII or tab-bearing filename are all unable to silently degrade a content check to `pass`. The filename one needed no config at all: `core.quotePath` defaults to true, and a C-quoted path matched nothing.

Its match tests — and the hook's own commit/land detectors — avoid pipelines entirely, because `grep -q` exiting early under `set -o pipefail` used to make a large input read as *no match*. A 320 KB file whose first line held a real key reported clean, and a `git commit` command padded with ~100 KB of further lines skipped **every** gate in the hook.

**If either scan cannot be inspected, the commit blocks** rather than proceeding on half the picture. Because a scanner that *could not look* is not a clean bill of health, an all-`skip` result, a missing `checks.sh`, or unusable output also block — with the scanner's own reason in the message.

It is per-file and rename-blind, so a test-file rename or deletion does report `test-integrity`. The block message names that false-positive shape and points at the override, rather than telling you to restore the file.

**Clearing a finding.** A genuine false positive is cleared only by a `gates.hygiene.acked[]` entry naming that check and **pinned to the current diff hash**, so a grant for one tree can never cover a later one. Unlike every other block here, **no state edit clears a real finding** — the remedy is to fix the diff, and for a secret, to rotate it.

### 5. Checkout drift

Committing while the working tree sits on a branch other than an active in-place run's branch is blocked. This previously failed open, silently.

## Test coverage

**`tests/enforcement-spine.test.sh`** — 584 assertions covering the full STANDARD + LIGHT lifecycle, gate ordering, review-staleness (including enforcement during a merge and under hostile git config), raw-mode commit detection, the Stop-hook stall-breaker, the AI-attribution block, the fail-open/fail-closed edges, per-worktree / subdirectory / nested-repo state resolution, worktree-isolated-run resolution with `CLAUDE_PROJECT_DIR` pinned to the main checkout, the checkout-drift block and warning, and `check-version.sh --plain` behavior.

**`tests/enforce-gates-hygiene.test.sh`** — 139 assertions on the commit-time diff-hygiene gate: non-ASCII, tab-bearing, pathspec-magic and option-shaped paths (including a file named `-`); a credential on a `++`-prefixed line; an invalid-UTF-8 byte under a UTF-8 locale; the commit detector under a multi-line command padded past the pipe buffer, with a padded non-commit negative control; each blocking row; the `warn`-demotion pass-through; the index scan, including a staged secret whose file was deleted from the worktree; the fail-closed cases both symmetric and *asymmetric*; the `.gitattributes` / `diff.external` off-switches with a genuinely-binary negative control; **large** diffs above the pipe buffer in both the attribute-marked and plain shapes; every non-array shape of the override record; the override's pinning under tracked/untracked/index drift; the hook's own printed override snippet executed as-shipped from a path containing a space; and the ordinary diffs that trip the rename-blind scanner.

Two of those 139 are skipped where a mode-000 file is still readable — for example, running as root.

Plus 33 other suites. Every measurement helper has a focused test under `tests/`.
