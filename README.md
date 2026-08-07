# auto-task-plugin

End-to-end autonomous task workflow for Claude Code. Takes a task description from intake to pull request with mechanical enforcement of every protocol invariant.

## How it works

The pipeline runs unattended between two anchor points: the **Phase-1 plan** (a human gate in `supervised` mode; recorded but not waited on in `autonomous`) and the **merge gate** — the single mandatory human stop before work lands, as a PR merge or a direct-to-main merge per your landing model. High-risk runs always stop at the merge gate regardless of mode. Progress is durably recorded in `STATE.json`, so an interrupted run resumes where it paused.

```mermaid
flowchart TD
    Start(["/auto-task &lt;description&gt;"]) --> Setup
    Setup["SETUP · pre-flight<br/>version check · first-run setup (autonomy · landing · telemetry) · pull main · fresh worktree"] --> Recon

    subgraph P1["PHASE 1 · DEFINE"]
        direction TB
        Recon["Recon · score effort tier + risk · clarify Q&amp;A"]
        Plan["Write PLAN.md + acceptance criteria + assumptions ledger"]
        Approve{"Plan approval<br/>supervised = human gate · autonomous = recorded, not waited on"}
        Recon --> Plan --> Approve
    end

    Approve -->|revise| Plan
    Approve -->|approved / auto-approved| Execute

    Execute["PHASE 2 · EXECUTE<br/>implement plan — one growing diff, no commits"] --> Verify
    Verify["PHASE 3 · SELF-VERIFY<br/>/auto-task-verify · types·unit·lint·build"]
    Verify -->|pass| GateA
    GateA{"GATE A · completeness<br/>runs on every tier"} -->|contract met| Review
    Review["PHASE 4 · CODE REVIEW<br/>auto-task-code-review · 5-phase"] -->|clean| GateB
    GateB{"GATE B · adversarial<br/>STANDARD / HEAVY"} -->|clean| Handover
    GateB -.->|LIGHT tier skips| Handover

    Verify -->|fail| Fix
    GateA -->|findings| Fix
    Review -->|reopening finding| Fix
    GateB -->|findings| Fix
    Fix["auto-task-fix<br/>then re-verify + re-review"] --> Verify

    Fix -.->|loop rule: no progress · out of scope · blocked · flaky · returns diminished| Surface(["STOP &amp; surface to user"])
    Execute -.->|interrupt-now: ambiguity · destructive op · test integrity · cost budget| Surface

    subgraph P5["PHASE 5 · HANDOVER"]
        direction TB
        Handover["re-sync main · single commit · CONTEXT.md"]
        Merge{"MERGE GATE — the one mandatory human stop<br/>required when supervised, autonomous+direct, or risk >= threshold"}
        Handover --> Merge
    end

    Merge -->|hold| Done(["✓ done"])
    Merge -->|ack| Land["LAND<br/>pr: push + open/merge PR · direct: merge to default branch"]
    Merge -.->|autonomous + low-risk pr: auto-ack| Land
    Land --> Done
    Land -.->|post-PR, if applicable| P6

    subgraph POST["POST-PR — optional · each runs only if its condition holds"]
        direction TB
        P6["PHASE 6 · Bot-comment review<br/>opt-in: bot_review_autofix"]
        P7["PHASE 7 · Preview verification<br/>opt-in / auto-learned"]
        P8["PHASE 8 · External change apply<br/>only if external actions declared"]
        P6 -.-> P7 -.-> P8
    end
    P8 -.-> Done

    classDef human fill:#fbf1de,stroke:#b5730a,stroke-width:2px,color:#3a2a05;
    classDef gate fill:#dcf1f2,stroke:#0d7b83,stroke-width:2px,color:#043033;
    classDef phase fill:#e9edfd,stroke:#3550d6,stroke-width:1.5px,color:#0f1a52;
    classDef fix fill:#eee7fb,stroke:#6b40cf,stroke-width:1.5px,color:#2a1358;
    classDef term fill:#e0f2e6,stroke:#1f8a4c,stroke-width:2px,color:#0a3d20;
    classDef stop fill:#fbe3e3,stroke:#c92a2a,stroke-width:1.5px,color:#5c0d0d;
    classDef cond fill:#eaeef3,stroke:#5a6675,stroke-width:1.5px,stroke-dasharray:5 4,color:#28313c;

    class Approve,Merge human;
    class GateA,GateB gate;
    class Setup,Recon,Plan,Execute,Verify,Review,Handover,Land phase;
    class Fix fix;
    class Start,Done term;
    class Surface stop;
    class P6,P7,P8 cond;
```

**Legend — solid border = always runs · dashed border = optional / conditional.** 🟦 phase / action · 🟨 human gate · 🟩 independent verifier gate (A/B) · 🟪 fix / review loop · ⬜ optional post-PR phase · 🟥 stop &amp; surface.

**Where the human stops (autonomy × landing model, chosen once at first-run setup):**

| mode | `pr` landing | `direct` landing |
|---|---|---|
| `supervised` (default) | plan approval + push/PR prompt | plan approval + prompt before landing |
| `autonomous` | plan recorded; low-risk auto-acks (disclaimer in PR body) | plan recorded; **merge-gate ack** before landing |

Any run with `effort.risk >= risk_gate_threshold` forces the **merge gate** regardless of mode. The **interrupt-now gates** (ambiguity · destructive op · test integrity · cost budget) can halt the run during any unattended phase, not just Phase 2. The **fix-loop budget** is enforced differently and deliberately narrower: exceeding the effort tier's iteration cap does not abort a phase — it blocks the *commit* until you ack it, and warns at a turn-end while the loop runs.

**Always runs:** Setup → Define → Execute → Self-verify → Gate A → Code review → Handover → merge gate. **Conditional:** Gate B pass counts vary by tier (LIGHT 1, STANDARD 2, HEAVY 3) — every tier runs it. **Optional (opt-in / only when applicable):** Phase 6 bot-comment review, Phase 7 preview verification, Phase 8 external-change application. Effort tier (LIGHT / STANDARD / HEAVY, scored in Phase 1) sets the verify scope, fix-loop cap, and whether Gate B runs.

## Autonomy modes & the merge gate (v0.22)

auto-task can run in two modes, chosen once per project in a **first-run setup** (five questions: telemetry, autonomy, landing style, unattended-external, docs update):

- **`supervised`** (default) — today's behavior: one human gate at plan approval, plus the push prompt.
- **`autonomous`** — the procedural gates go silent and the run proceeds unattended; the **merge is the sole mandatory human gate**. Safety comes from *exception-triggered* interrupts that stop the run only on real trouble: **ambiguity** (hard stop for a decision it can't resolve with evidence), a **destructive / out-of-envelope command** (blocked by `guard-dangerous-ops.sh` unless `unattended_external` is on), **test integrity** (tests weakened to reach green), a soft **cost-blowout** check-in, and the **fix-loop budget** — exceeding the tier's iteration cap blocks the *commit* until you acknowledge it (and warns during the loop), which is the mechanism that stops a run churning indefinitely without your say-so. High-risk runs (`effort.risk >= risk_gate_threshold`) force the merge gate on regardless of mode, showing a red disclaimer + an **assumptions ledger** of every call the run made unattended.

> **Settings reset when the settings model changes.** The settings file is version-stamped, and a release that adds a policy question bumps the stamp. On the first `/auto-task` after such an update, each project's settings are backed up (`settings.json.pre-<n>`) and cleared so the one-time setup re-runs and telemetry is re-consented. Your shared **global** settings file is never touched — restore prior values by copying the backup back. This has happened twice so far: at 0.22 (the autonomy/landing/unattended questions) and again when `docs_update_mode` joined the set.

## What it ships

- **`auto-task` skill** — the orchestrator. Composes the eight bundled sibling skills and the verifier agent across the pipeline (Define → Execute → Self-verify → Review → Handover, plus the optional post-push Preview-verification and Release phases). Ships as a **spine plus reference files** — see below.
- **`skills/auto-task/references/` — the spec's on-demand half.** Only `SKILL.md` is loaded into context on every turn of every run, so the spec is split: `SKILL.md` is the always-loaded **spine** (the pipeline, the loop rule, the effort tiers, the yield-point/anti-stall contract, the Acceptance-Criteria contract and INCONCLUSIVE floor, the trace contract, and each phase's gate condition + non-negotiables), while the bulky step-by-step contracts live in seven reference files the spine points at with a `**MANDATORY READ:**` directive at the point of use:

  | Reference | Carries |
  |---|---|
  | `phase-1-preamble.md` | Phase 1's procedural steps, AC pre-flight, the critique loop, the risk disclaimer, comment-voice resolution |
  | `phase-3-gates.md` | Phase 3 (self-verify), Gate A, Gate B — full contracts |
  | `phase-5-handover.md` | All twelve Phase-5 handover steps + the single-commit rule's exceptions |
  | `phase-6-8-post-pr.md` | Phases 6 (bot review), 7 (preview), 8 (external changes) |
  | `phase-9-release.md` | Phase 9 (release) |
  | `settings.md` | The full settings-key table, two-scope merge, remote telemetry, autonomy sub-contracts |
  | `state-schema.md` | `STATE.json` per-object semantics |

  This cut the always-loaded spine from **397,676 B to 122,582 B (−69.2%)** — roughly 97k tokens down to ~30k on every turn. **Every line of the original spec was preserved byte-for-byte at the time of the carve**, so no contract was dropped or reworded by the split itself. Fifty-nine of those base lines have since been deliberately **retired**: the `state.estimate` schema block and the Estimate-vs-actual prose (reworded when the estimate switched to output-only tokens), the run-duration prose (reworded when the clock became hook-stamped), thirteen lines reworded when Gate B became a bounded loop (the resolution ladder, loop-rule clause 5, the two tier-table rows, the two `gates` schema lines, the spawn-input bullet, the anti-stall verifier-gate summary, three re-gate steps and Phase 9's surface rule), and twenty reworded when the **Phase-4 loop** was graded the same way — bounding Gate B had simply moved the churn one phase upstream (the three-step resolution list, the four "Categorize findings" lines, the per-finding fix instruction, all three exit conditions — the loop's own and Phase 4's two — the top-of-file contract's label-driven advance and the Phase-4 exit-conditions heading, the `reviewed_diff_sha` formula and the staleness paragraph's pointer to it, the `gates.code_review` schema line, the loop-count definition, and three Phase-4 anti-stall restatements compressed to pay for the new contract's bytes), and two more when the Phase-4 review moved into a fresh-context subagent (the MANDATORY-tool paragraph and the Rules bullet, both of which described the review's call site as inline-only). `tests/spec-inventory.sh` names each retirement with its reason and reports the count (`retired=59`), so a retirement is reviewable rather than silent, and everything not named stays under guard. It is not a *pure* move, though: a large minority of the spine's 623 non-blank lines are freshly written per-phase summaries and `MANDATORY READ` directives, and since this spec *is* the behavior, treat that as a real (if narrow) behavioral surface. Reviewing this change caught several summaries that over-generalised their source contract; the guards described below exist to keep that class from recurring. Two guards keep it honest: `tests/spec-inventory.sh` proves every base line survives somewhere **except the ones explicitly retired in its `RETIRED_PREFIXES` list** (each with a stated reason; a prefix matching zero or several base lines, or an entry that stops corresponding to a real shortfall, is itself reported), and that no heading is duplicated, and `tests/enforcement-spine.test.sh` asserts the must-stay contracts are in **`SKILL.md` specifically** (with a mutation probe in `tests/spec-helper.test.sh` proving those assertions really fail if the content is moved). Test assertions search the spine *and* the references via `tests/lib/spec.sh`, so a future boundary adjustment costs no test churn.
- **`hooks/settings.sh` — project settings (opt-in).** Reads a per-project, per-user JSON settings file kept **outside your repo** (`~/.claude/auto-task/<project-key>/settings.json`), with a built-in default for every key. First key: `has_preview_deployment`, which turns on the post-push preview verification. See "Project settings (opt-in)" below. Pure, fail-open, `tests/settings.test.sh`.
- **Eight namespaced sibling skills** — `auto-task-plan`, `auto-task-implement`, `auto-task-verify`, `auto-task-code-review`, `auto-task-commit`, `auto-task-fix`, `auto-task-docs`, `auto-task-release`. The first six are forked from the upstream skills and patched to participate in the read-before-review contract; `auto-task-docs` and `auto-task-release` are new to this plugin (the two optional steps — see "Docs update at handover" and "Release at handover"). The `auto-task-` prefix keeps them distinct from your existing `/plan`, `/verify`, etc.; under a marketplace install they are further namespaced (`auto-task:auto-task-plan`), and under the `install.sh` fallback they keep the bare `auto-task-plan` form.
- **`task-execution-verifier` agent** — read-only verifier spawned at Gate A (completeness) and Gate B (adversarial). Fresh context per spawn.
- **`auto-task-stats` skill** — standalone, read-only maintainer tool (NOT part of the pipeline). Reports local run-outcome telemetry: completion rate, where runs stall, per-tier fix/review effort, Gate B coverage. See "Run telemetry (opt-in)" below. Invoke as `/auto-task:auto-task-stats` (marketplace) or `/auto-task-stats` (install.sh fallback).
- **`auto-task-gc` skill** — standalone disk/worktree cleanup tool (NOT part of the pipeline). Reports each auto-task worktree's size, age, and merge status, then safely reclaims the merged/stale ones on confirmation (branch refs preserved, matching `.auto-task/<branch>/` pruned). Retention is per branch type and fully defaulted/overridable. See "Worktree space control" below. Invoke as `/auto-task:auto-task-gc` (marketplace) or `/auto-task-gc` (install.sh fallback).
- **`auto-task-resume` skill** — standalone run picker (NOT part of the pipeline). Lists every auto-task run across your worktrees — state, title, effort, last activity — in a clean table, lets you pick one, and continues it from where it left off. Fixes the `claude --resume` gap (that resumes a *conversation*, not a *run*). Backed by the read-only `hooks/auto-task-resume-list.sh` engine (`tests/auto-task-resume-list.test.sh`). See "Resuming runs" below. Invoke as `/auto-task:auto-task-resume` (marketplace) or `/auto-task-resume` (install.sh fallback).
- **Core hooks**, all wired automatically by the plugin install (`hooks/hooks.json`) —
  - `stamp-run-clock.sh` (PreToolUse on Bash + Stop): **pure measurement, never blocks.** Stamps `created_at` once and refreshes `updated_at` from `date -u` into a hook-owned sidecar `.auto-task/<branch>/.run-clock.json`, so a run's duration is **observed rather than narrated** — it previously came from the first and last `state.history[].at` strings, which the model writes without access to a clock. The clock **seals** at `phase: done` so a later ad-hoc command in the worktree cannot inflate an already-recorded run. A negative or over-12h span is **rejected to `null`** rather than reported as a number (a run paused overnight is not a meaningful "how long did this take" figure), and that rejection is deliberately distinguishable from "no clock", which still falls back to the old history formula for runs that predate this. Derivation and bounds live once in `hooks/lib/run-clock.sh`, read by all three duration consumers (`record-outcome.sh`, `send-telemetry.sh`, `auto-task-stats.sh`). The two row writers stamp the clock themselves immediately before reading it, so the recorded row includes the final turn regardless of hook execution order (an event's hooks run in parallel, so registration order is not a contract). It never writes `STATE.json`; fails open and silent (`tests/run-clock.test.sh`).
  - `block-ai-attribution.sh` (PreToolUse on Bash): refuses commits and PR bodies containing `Co-Authored-By: Claude`, `🤖 Generated`, etc.
  - `enforce-gates.sh` (PreToolUse on Bash): blocks `git commit` during an auto-task run unless `gates.code_review.passed`, `gates.code_review.tool === "skill:auto-task-code-review"`, `gates.code_review.clean_pass_after_last_fix`, and Gate B's gate (or skip reason) are all satisfied. It also enforces **review staleness** — if `git diff <base>` no longer hashes to the recorded `gates.code_review.reviewed_diff_sha`, code changed after the review went clean and the commit is blocked until a re-review. It also enforces the **fix-loop budget** — once the loop count `max(iteration.fix, iteration.review)` exceeds the effort tier's cap (LIGHT 2 / STANDARD 4 / HEAVY 6, defined once in `hooks/lib/loop-budget.sh`) the commit is blocked until `gates.loop_budget.acked_through` records your go-ahead, which raises the budget to the next cap rung above the current count so one ack always suffices and the check-in returns rather than being dismissed forever. The same budget is additionally consulted at **Gate-B entry** — as a spec-level self-check, since a Gate B pass is an `Agent` spawn no hook observes — and the same helper defines Gate B's own per-scope pass caps (`lb_gate_b_cap`, `lb_gate_b_regate_cap`). It also enforces **diff hygiene** — the one check that reads the *diff itself* rather than a field the run wrote about the diff. It runs `hooks/checks.sh` over the **worktree union the index** — `git diff <base>` plus untracked files, *and* `git diff --cached <base>`, because `git commit` commits the index and content staged then edited out of the working file would otherwise be invisible — and blocks the commit on any `fail` row: a credential outside test/fixture paths, a leftover merge-conflict marker, or a weakened test (a skip/focus marker added, or assertions removed with none added back). `warn` rows never block, so a fake credential in a fixture still commits. The scanner reads the diff with **pinned flags**, **literal pathspecs**, and **byte (`LC_ALL=C`) semantics**, enumerates paths **NUL-delimited**, passes every path to a non-git tool as `./path` so an option-shaped filename cannot be eaten as a flag, extracts content lines by hunk position rather than by `+++`-prefix pattern, and decides binary-ness from the diffed content rather than from `numstat` — so a local `diff.external` / textconv setting, a `.gitattributes` entry (`* -diff`, `*.js binary`), and a non-ASCII or tab-bearing filename are all unable to silently degrade a content check to `pass`. Each was a measured bypass; the filename one needed no config at all, since `core.quotePath` defaults to true and a C-quoted path matched nothing. Its match tests — and the hook's own commit/land detectors — avoid pipelines entirely, because `grep -q` exiting early under `set -o pipefail` used to make a large input read as *no match*: a 320 KB file whose first line held a real key reported clean, and a `git commit` command padded with ~100 KB of further lines skipped **every** gate in the hook. If either scan (worktree or index) cannot be inspected, the commit blocks rather than proceeding on half the picture. It is per-file and rename-blind, so a test-file rename or deletion does report `test-integrity` — the block message names that false-positive shape and points at the override rather than telling you to restore the file. Because a scanner that *could not look* is not a clean bill of health, an all-`skip` result, a missing `checks.sh`, or unusable output also block — with the scanner's own reason in the message. A genuine false positive is cleared only by a `gates.hygiene.acked[]` entry naming that check and **pinned to the current diff hash**, so a grant for one tree can never cover a later one; unlike every other block here, no state edit clears a real finding — the remedy is to fix the diff (and for a secret, to rotate it). And it carries the **checkout-drift block** — committing while the working tree sits on a branch other than an active in-place run's branch is blocked (previously a silent fail-open). Fails closed: with `jq` missing or `STATE.json` unparseable during an active run, it blocks rather than letting the commit through.
  - `warn-checkout-drift.sh` (PreToolUse on Bash): informational, NEVER blocks. Warns on every command when an active run exists on a branch other than the one checked out (the proactive half of the checkout-drift guard; the enforce-gates block is the mechanical half). Silent and near-free in non-auto-task repos.
  - `guard-dangerous-ops.sh` (PreToolUse on Bash): fail-closed interrupt during an active run. Blocks commands outside the safe action envelope — destructive filesystem removals, force-push to a protected branch, destructive SQL, infrastructure delete/apply, migration-apply, deploy/publish — unless `unattended_external` is true, so the model must surface them instead of running them unattended. Raw-mode aware; benign build cleanup and own-branch force-push are allowed. See "Autonomy modes & the merge gate".
  - `prevent-mid-protocol-stall.sh` (Stop event): blocks turn-ends mid-pipeline by reading `expected_next_action` from STATE.json. The antidote to sub-skill output looking completion-shaped.
  - `record-outcome.sh` (Stop event): **opt-in, never blocks.** When the clone's `.auto-task/outcomes.jsonl` exists and a run reaches `phase: done`, appends one derived JSON row (fields from STATE.json — no network, no new data). The ledger is resolved **clone-wide** to the main working tree — "where does clone-wide state live" is defined once in `hooks/lib/clone-scope.sh` and read by both the writer and `auto-task-stats.sh`, the same single-definition convention as `run-clock.sh` and `loop-budget.sh` — so a run completing in any worktree records to the one shared file; per-run state (STATE.json, run clock, sentinel) stays per-worktree. A base-keyed sentinel makes it write once per run, and is stamped only after the row is verified to have landed. Silent no-op unless opted in. Read by `auto-task-stats`. See "Run telemetry (opt-in)".
  - `send-telemetry.sh` (Stop event): **opt-in, off by default, never blocks.** The **remote** counterpart to `record-outcome.sh` — when `telemetry_enabled`+`telemetry_endpoint` are set (see "Remote telemetry"), POSTs an anonymized quality/perf row to your HTTPS endpoint at `phase: done`. Bounded, fail-open, write-once per run. Silent no-op unless opted in.
  - `release-notes.sh` (SessionStart): best-effort "what's new" notice. The first session after the installed version changes, it prints a short user-facing summary of everything you gained, read from the bundled `.claude-plugin/release-notes.json` — **no network, no changelog parsing**. Shown once per version via a stamp at `~/.claude/auto-task/last-seen-version`; a fresh install is silent (no delta to report), and a release with nothing user-visible produces nothing. Fails open and silent on every error path, and if the stamp can't be written the notice is suppressed rather than repeated every session. See "Release notes" under Updating.
  - `check-version.sh` (SessionStart): best-effort update notice. Once per 24h it compares the installed version against the published `plugin.json` on GitHub and, if you're behind, prints a one-line reminder to run `/plugin update auto-task@auto-task-plugin`. Fails open and silent when current, offline, or unparseable — this cached SessionStart notice never blocks or slows a session. **Per-run version check:** on top of that notice, `/auto-task` Phase 1 runs a fresh **per-run version check** (the same script via `--plain`, throttle bypassed) at the start of every NEW run and, if you're behind, asks once whether to auto-apply the update (via `hooks/apply-update.sh` — no manual command) or proceed on the current version. It is separately bounded (`--connect-timeout 2 -m 5`) and fully fail-open — it never blocks the run and never touches the SessionStart throttle stamp. Skipped on resume.
  - `suggest-cleanup.sh` (SessionStart): best-effort, non-destructive worktree-cleanup nudge. Cheap and **local-only** (no `du`, no network) and throttled once per `worktree_cleanup_throttle_hours` **per clone**; when ≥1 auto-task worktree looks reclaimable (merged, or clean-and-stale past its per-type threshold) it prints a one-line suggestion to run `/auto-task-gc`. Never deletes, never blocks; fails open and silent, and is gated off by `worktree_cleanup_nudge: false`. See "Worktree space control".
- **`inject-history-reminder.sh`** (`UserPromptSubmit`, opt-in): tells non-bundled tools that an `.auto-task/<branch>/` history folder exists for the current branch. **Wired but OFF by default** — it stays silent unless you enable it with `settings.sh set history_reminder_enabled true` (works identically for marketplace and `install.sh`). Even when enabled it emits nothing outside auto-task branches, so unrelated prompts pay no token cost.
- **`settings-fragment.json`** — fallback only. The marketplace install wires the hooks for you; this snippet is for the offline/dev `install.sh` path (and the optional recommended-permissions block). The history reminder is wired in both install paths and gated by the `history_reminder_enabled` setting — no snippet edit is needed to enable it.

## Install (marketplace — recommended)

This repo is its own plugin marketplace. From inside Claude Code:

```
/plugin marketplace add o8o0o8o/auto-task-plugin
/plugin install auto-task@auto-task-plugin
```

That copies the plugin into your plugin cache and **auto-wires everything** — the twelve skills, the `task-execution-verifier` agent, and all eleven core hooks (`hooks/hooks.json`). No `settings.json` editing, no symlinks, no `install.sh`.

Plugin skills are namespaced under the plugin name, so you invoke the orchestrator as:

```
/auto-task:auto-task <plain-English task description>
```

and the siblings as `/auto-task:auto-task-plan`, `/auto-task:auto-task-fix`, etc.

### Updating

**Auto-apply (no command to type).** When a newer version exists, the next `/auto-task` run offers to update — choose **"Update it for me (auto-apply)"** and the bundled `hooks/apply-update.sh` applies it for you, detecting your install layout automatically:

- **Marketplace install** → runs `claude plugin update auto-task@auto-task-plugin` (at your install scope).
- **Offline / development install** (git clone via `install.sh`) → runs `git pull --ff-only` in the clone. Fast-forward only — it never forces and never switches your branch, so be on the release-tracking branch (`main`) to pull a release; a dirty/diverged/no-upstream tree fails cleanly with a message instead of clobbering your work.
- **Copy install** (`install.sh --copy`) → cannot self-update (files were copied with no source link); re-run `install.sh` from your clone.

**Restart to load.** An update *stages* the new version but the running session keeps the old code — hooks load at session start and a marketplace update needs a restart to apply. So after auto-apply, **restart Claude Code** and re-run `/auto-task`; re-invoking in the same session would reload nothing.

You can also run the updater standalone (`bash hooks/apply-update.sh`) or update by hand:

```
/plugin update auto-task@auto-task-plugin
```

The bundled `check-version.sh` SessionStart hook also reminds you (at most once per day) when a newer version has been published, so you don't have to remember to check. Updates ship only when the maintainer bumps `version` in `plugin.json`.

#### Release notes — what you just got

You never have to read the changelog to find out what an update did. The first session on a new version, the bundled `release-notes.sh` hook prints a short, **user-facing** summary of everything you gained:

```
auto-task is now on 0.24.0 — what's new:
  • 0.24.0 — Tightens both main-sync points so a run always starts from the latest default branch…
  • 0.23.0 — Reshapes run-outcome telemetry to be actionable, not vanity…
```

It reads `.claude-plugin/release-notes.json`, which ships with the plugin — **no network request** — and shows each version exactly once, tracked by a single stamp at `~/.claude/auto-task/last-seen-version`. A **fresh install stays silent** (there is no delta to report), and when several versions landed at once you get the newest three plus a `(+N earlier releases in these notes)` line. The qualifier is deliberate: the bundled file keeps only the newest ten releases, so for a wider gap that count is what these notes hold, not everything you gained.

**Only user-visible changes appear.** A release that changes nothing you can observe — an internal refactor, a dev-only tool, a docs sync — is marked `<!-- release-notes: skip -->` in the changelog and produces no note and no notice, rather than filler.

Strictly best-effort: a missing or unreadable notes file, or no `jq`, means you simply see nothing — never an error and never a slower session. If the "already shown" stamp cannot be written, the notice is suppressed rather than repeated every session.

> **Not included: a "what *would* I get?" preview before updating.** An earlier version of this feature also fetched the notes for versions you did not have yet and appended them to the update notice. It was dropped: rendering a file fetched over the network kept opening ways for hostile JSON to forge notice lines or blow the message size, and the input space is unbounded. Reading only the bundled artifact removes that trust boundary instead of adding another layer of validation to it.

### Optional / opt-in

- **`inject-history-reminder.sh`** (`UserPromptSubmit`) — lets non-bundled tools discover the per-branch history folder so they honour the read-before-review contract. Wired in every install but **gated OFF by default**; enable with `settings.sh set history_reminder_enabled true` (`false` to disable). It emits nothing outside auto-task branches, so unrelated prompts pay no token cost. Enabling via a settings key — rather than a pasted `settings.json` snippet — is what makes it reachable on a marketplace install, where the plugin lives in an opaque, per-version cache dir that `${CLAUDE_PLUGIN_ROOT}` can't expand into `settings.json`.
- **Recommended permissions** — the inert `_optional_recommended_permissions` block in `settings-fragment.json` denies bare `git push` and asks before `gh pr create`, turning the Phase 5 push prompt into a mechanical gate. Not required (the skill already prompts once), and it affects all your work, so it's opt-in.

## Install (offline / development — fallback)

If you can't use the marketplace (air-gapped, or hacking on the plugin itself), `install.sh` symlinks the skills + agent into `~/.claude/` and prints a hooks snippet to merge into `~/.claude/settings.json`:

```sh
git clone https://github.com/o8o0o8o/auto-task-plugin.git ~/.claude/auto-task-plugin
cd ~/.claude/auto-task-plugin
./install.sh
```

It symlinks the twelve skills into `~/.claude/skills/` and the verifier agent into `~/.claude/agents/`, then prints a settings snippet with absolute paths for the hooks. Merge that snippet into `~/.claude/settings.json` — preserve your existing keys, append to the `hooks.PreToolUse` / `hooks.Stop` arrays if they already exist. The skills load without the merge, but the gate-enforcement and anti-stall hooks won't fire. With this path the skills are invoked by their bare names (`/auto-task`), not namespaced.

Pass `--copy` instead of the default to copy files (no symlinks), or `--uninstall` to remove the links. To update: `git pull` inside the clone (symlinks pick up changes automatically; if you used `--copy`, re-run `./install.sh`). The SessionStart update-notice fires under either install path — `check-version.sh` self-locates its manifest (via `${CLAUDE_PLUGIN_ROOT}` under the marketplace install, or relative to its own path for the `install.sh`/symlink layout).

## Hard prerequisites

- `git` ≥ 2.30
- `gh` (GitHub CLI) for PR creation
- `jq` (used by the hook scripts)
- `curl` (used by the SessionStart update-notice hook; absence just disables the notice)
- `bash` ≥ 3.2 (the version macOS ships with works; POSIX `sh` does not — the hook scripts use bash features)

## Usage

### Start a new run

```
/auto-task <plain-English task description>
```

The skill creates a branch, sets up the per-branch history folder at `.auto-task/<branch>/`, runs Phase 1 reconnaissance (read-only — Playwright, Context7, Figma, etc.; any link in the card is loaded **two-tier** — an ordinary fetch first, a Playwright fallback when that returns no usable data — and videos like Loom get screenshots + transcript, with `hooks/extract-links.sh` classifying the links as a mechanical assist, and a focused test under `tests/`), asks clarifying questions, selects an implementation approach when more than one is viable (generating and scoring candidates, surfacing close calls to you), builds an Acceptance Criteria table, critiques the plan and auto-repairs its structural gaps, and presents a plan for your approval.

**Forward clarifying questions to the ticket owner.** The person running `/auto-task` often isn't the one who owns the ticket and holds the answers, so when Phase 1 has open questions (or folds an approach choice to you) it **first asks how you want to handle them** — a routing question with two options: **answer them here**, or **get a paste-ready ticket comment to forward**. Choose *answer here* and the questions appear as pickers; choose *forward* and it renders the comment (short, human-like, no names, no greetings, functionality only) and **pauses** — you drop it into the ticket, then resume `/auto-task` with the owner's answers and it picks up where it left off. Making the comment a first-class choice (rather than an easy-to-miss aside) is what guarantees it always shows up.

**Comments in your voice (`VOICE.md`).** Every comment the pipeline drafts — the Phase-1 ticket comment, the Phase-5 PR title/body, and the Phase-7 preview verdict comment — is written in the voice from a `VOICE.md` when one exists. Resolution takes the first non-empty file of **project-local `<repo>/.claude/VOICE.md`** (wins) then **global `~/.claude/VOICE.md`**; with no `VOICE.md` at either level it falls back to the built-in default style. Voice shapes only the free prose — it never overrides hard rules (no AI-attribution, the ticket comment's no-names/no-greetings/functional-only contract, or the PR body's structured tables/checklist/diagram). It's fail-open and silent: a missing or empty file just means defaults, and it adds no prompt, stop, or gate.

**Every run has a title.** Phase 1 derives a concise **run title** from your task and surfaces it so you can tell sessions apart at a glance — it prefixes every sub-agent's status label (the running-agent line reads `<title> · Gate B adversarial verify`) and leads each phase message with a `▶ auto-task: <title> — Phase N` banner. It's purely cosmetic — derived locally, no tracker integration, and it changes no gate or control flow.

**Where independence actually lives — read this before assuming a phase is a second opinion.** Phases 2 and 3 are **skills invoked in the main loop**, so the same model that wrote the code also self-verifies it. That is deliberate: those skills need the run's full context. **Phase 4 used to be in that list and no longer is.** By default (`review_in_subagent`) the code review is invoked from a fresh-context `general-purpose` Agent, so the model that wrote the diff is not the one that reviews it — and it is still the `auto-task-code-review` skill doing the reviewing, pinned by `enforce-gates.sh` (`gates.code_review.tool`), which is what stops a bespoke review prompt being substituted for a disciplined one. The hook reads that field and cannot see the call site, so moving the call site loosens nothing; set `review_in_subagent: false` to get the old inline behaviour back. Independent, fresh-context judgment then enters at three points — **Phase 4**, **Gate A** and **Gate B** — the latter two each a `task-execution-verifier` Agent spawned with only the diff, the plan and the prior-review history, never the parent conversation. If you want a second model looking at the work, those three are what do it; **a green Phase 3 is still the author checking their own work**, and the pipeline does not claim otherwise. Two caveats on Phase 4's independence, both stated rather than glossed: turning `review_in_subagent` off returns it to a self-review, and even with it on, a twice-failed spawn or a reviewer caught editing the tree falls back to the inline call — the round records `via` so you can tell which happened. **All Agent spawns are synchronous** (`run_in_background: false`) so the verifier's report is the tool result — a backgrounded spawn returns launch metadata instead, and the run would have nothing to act on.

After you type `approved` / `proceed` / `yes`, the pipeline runs unattended through:

- **Phase 2** Execute — invokes the bundled `auto-task-implement` skill; drift-checks each checkpoint against the plan's Blast Radius.
- **Phase 3** Self-verify — invokes `auto-task-verify`; runs every Acceptance Criterion bound to the `self-verify` gate.
- **Gate A** — spawns `task-execution-verifier` in `completeness` mode; runs every Acceptance Criterion bound to `gate-a`.
- **Phase 4** Code review — invokes `auto-task-code-review`, **by default from a fresh-context `general-purpose` agent** (`review_in_subagent`) so the diff's author is not its reviewer, with round 1 reading the full diff and every later round only the delta since the previous round. It **grades each finding by reachability rather than by its severity label**: a finding reopens the loop only if it breaks an approved Acceptance Criterion, is a runtime-reachable regression or bypass, or is a security / data-loss path — the same test Gate B applies, by reference, so the two cannot drift. A `blocker`/`required` that fails that test is **deferred**, not round-triggering; once a round comes back with zero reopening findings, the whole deferred set is fixed in ONE batch, followed by a single re-review. **That batch is spent once per run**, so a non-reopening `blocker`/`required` raised after it **parks as a follow-up rather than being fixed** — there is no second batch, and Gate B re-grades it at every tier. Every round is recorded in `gates.code_review.rounds[]`, and a convergence test on the graded count surfaces with that per-round table instead of looping on.
- **Gate B** — spawns `task-execution-verifier` in `adversarial` mode at **every tier**, and it is **bounded**: a per-scope pass cap read from `hooks/lib/loop-budget.sh` — the main loop gets 1 (LIGHT), 2 (STANDARD) or 3 (HEAVY), and each of the four re-gate scopes gets its own flat 2, counted separately so a spent main loop can never deadlock the handover — with every later pass reviewing only the delta since the previous one. A finding reopens Phase 4 only if it breaks an approved Acceptance Criterion, is a runtime-reachable regression or bypass, or is a security / data-loss path — everything else parks, whatever its label. At the cap, on a second self-inflicted pass (findings that are defects in the previous pass's own fixes), or on a fired convergence test, it surfaces with three grants: one more pass · park and advance · descope the residual.
- **Phase 5** Handover — optionally refreshes stale docs first (`docs_update_mode`, off by default), then a single commit, push, PR with embedded change diagram. Asks once whether to push & open PR / push only / hold.
- **Phase 9** Release (opt-in) — optionally cuts the landed work as a release (`release_mode`, off by default): version bump via your own `release_command`, changelog entry, `chore(release): vX.Y.Z` commit and an annotated tag. **Local only — it never pushes and never publishes.**

### Resume an interrupted run

```
/auto-task
```

(no argument) — reads `.auto-task/<current-branch>/STATE.json` and continues from where it left off. Resume re-enters the phase recorded in `STATE.json` from the top; phases are designed to be re-entrant (re-running self-verify, a gate, or the review loop on the current working tree is idempotent — it recomputes from disk state, it doesn't double-apply). The component preflight (above) re-runs on every resume in case a skill or the verifier agent was uninstalled between sessions.

### Running multiple runs in parallel

Each run is isolated by **branch** and keeps all state under `.auto-task/<branch>/`. Parallel runs in the same repo are now **automatic** — no manual setup:

- **Launch from any branch — it just works.** For every new-description run, Phase 1 forks a fresh `<type>/<slug>` branch **from the repo's default branch** (`main`/`master`, best-effort fetched first) and gives it its OWN git worktree (`git worktree add .claude/worktrees/<type>-<slug> -b <branch> <default-ref>`, then it relocates the session in via the `EnterWorktree` tool). This is unconditional — it does not matter what branch you are currently on or what the shared checkout is doing. Your original checkout is left untouched and free for other work, and a second `/auto-task` started elsewhere gets its own worktree too — git forbids two worktrees on one branch (and names are disambiguated before creation), so they can never collide. The worktree is kept on disk after the run; prune it with `git worktree remove .claude/worktrees/<type>-<slug>` when done.
- **Based on the default branch, not your current HEAD.** Every run starts clean from a current default base, so it never inherits the current checkout's branch or uncommitted WIP. A run started while on a feature branch forks fresh from the default rather than continuing that branch — to base a run on specific work, prepare a worktree for it by hand (below) and run `/auto-task` inside it.
- **Manual worktrees still work** if you want to base a run on specific existing work:

  ```sh
  git worktree add ../auto-task-feat-x -b feat/x   # one worktree per task
  cd ../auto-task-feat-x && claude                  # then run /auto-task here
  ```

  auto-task detects it is already inside a linked worktree and runs in place there, without nesting a second worktree.
- **The in-place fallback is guarded.** If `EnterWorktree`/`git worktree add` is unavailable, the run falls back to the shared checkout — and the **checkout-drift guard** catches the case where that checkout is switched off the run's branch from another terminal: `warn-checkout-drift.sh` warns on every command and `enforce-gates.sh` hard-blocks any commit until you switch back (or clear an abandoned run). Previously this failed open silently.

Each worktree has its own working tree, branch, and `.auto-task/<branch>/` history, and the gate + Stop hooks resolve state per-worktree (via `git rev-parse --show-toplevel`), so concurrent runs never interfere — even though they share one clone's object store and common-dir exclude file. Merge or open a PR from each worktree independently.

### Surfacing protocol

The pipeline stops mid-flight only when the Loop rule fires:

1. No progress (two consecutive iterations with no measurable improvement).
2. Out-of-scope (remaining issues don't map to the approved AC).
3. External blocker (missing creds, broken infra, undecided design).
4. Test flakiness (non-deterministic failure).
5. Returns diminished (a round's blocker+required count failed to decrease, so the loop has converged). It fires only while findings remain — a clean round has nothing to park and takes its loop's ordinary clean exit. At Gate B the count is of findings that actually **reopened** the loop, not of everything the verifier labelled. Park-and-advance is your grant to give — the pipeline never self-grants it, and no unfixed blocker or required finding passes a gate on this test alone.

You get a status with **why stopped** + **current state** + **suggested next move**. Resume with `/auto-task` (or `/auto-task-resume` to pick from all runs — see below).

## Resuming runs (`/auto-task-resume`)

Each run lives in its own git worktree keyed to a branch (`.auto-task/<branch>/STATE.json` **inside that worktree**). Two consequences: `claude --resume` resumes a *conversation session*, not a run, so it can drop you somewhere with no run in sight; and bare `/auto-task` (no args) only knows about the run on the branch you happen to be on. When several runs are in flight across worktrees, neither lands you where you meant to go.

**`/auto-task-resume`** is the picker that fixes this. It enumerates every run on the clone (scanning each `git worktree list` path for a `STATE.json` — a bare worktree with no state is never listed), prints a clean table, and lets you choose:

```
  auto-task runs — my-app  (4 found)
  ────────────────────────────────────────────────────────────────────────
   #     STATE       TITLE                                  EFFORT  LAST
  ────────────────────────────────────────────────────────────────────────
   1) ● gate-b      Apply & verify external CMS changes    standard 39m ago
   2) ○ done        Sync comments, code & docs             light   3h ago
   3) ● review      Worktree cleanup nudge                 standard 18h ago  · current
   4) ● execute     Add reCAPTCHA to order approval        heavy   2d ago    · orphan
  ────────────────────────────────────────────────────────────────────────
  ● resumable   ○ done   ⚠ unreadable    markers: · current (you're here) · orphan (worktree pruned)
```

Pick a run with an arrow-key prompt (it offers only the resumable runs — done and current ones stay in the table for context), and it enters that run's worktree and hands off to the standard resume, continuing from the recorded phase. An **orphaned** run (state survives but its worktree was pruned) is offered a one-step recreate (`git worktree add`) first. It's read-only discovery — nothing is written or removed without your say-so.

Bare **`/auto-task`** (no args) also uses this now: it consults the engine's `--resume-mode` and shows the picker when runs exist beyond your current branch, resumes directly when the only run is your current branch's, or asks for a description when there are none.

## Read-before-review contract

When the bundled `auto-task-code-review`, `auto-task-verify`, or `auto-task-fix` skill runs in a repo with an existing `.auto-task/<branch>/` folder, it reads `CONTEXT.md` and `TRACE.md` first so it doesn't re-litigate decisions or miss real issues that earlier reviewers flagged but never followed up on.

**For third-party tools that want to participate:** the contract is "if `.auto-task/$(git branch --show-current)/` exists, read `CONTEXT.md` and `TRACE.md` before forming findings; append a new TRACE entry on completion (block format documented in `skills/auto-task/SKILL.md`)." Adopt this in your own tool to interoperate.

## Recommended project memories

Auto-task reads `~/.claude/projects/<slug>/memory/MEMORY.md` during Phase 1 recon. Useful entries to maintain per-project:

- **`feedback_no_unrequested_commits.md`** — `"continue"` / `"proceed"` should not authorize commits; only an explicit `"commit"` does.
- **`feedback_subagents_dangerous_git.md`** — sub-agents should never run `git reset --hard`, `git push --force`, or similar in dispatch prompts.
- **`project_team_review_policy.md`** — who must review PRs touching specific paths.
- **`reference_external_systems.md`** — pointers to Linear / Notion / Slack channels where decisions are tracked.

The plugin does NOT ship memory entries. They are per-user, per-project, opt-in.

## What does NOT happen

- The plugin never commits anything under `.auto-task/` — that folder is local-only, gitignored via the common-dir exclude (`$(git rev-parse --git-common-dir)/info/exclude`) on branch setup.
- The plugin never writes to your memory store. Phase 1 reads it; Phase 5 surfaces candidate memories for you to save if you choose. No autonomous writes.
- The plugin never bypasses hooks. Pre-commit hook block → fix the underlying state, don't `--no-verify`.
- The plugin never adds `Co-Authored-By: Claude` or `🤖 Generated` markers — both the skill and the hook enforce this.

## Troubleshooting

| Error message | Meaning | Fix |
|---|---|---|
| `Blocked by auto-task-plugin: auto-task run in progress` | The gate-enforcement hook fired because gates haven't passed. | Read the message — it names which gate is missing. Re-run the relevant skill and update the flag with real evidence. Do NOT speculatively set flags. |
| `auto-task is mid-pipeline (phase=…)` | The Stop hook fired because `expected_next_action === "auto-continue"`. | This is the anti-stall block working as intended. Make the next tool call instead of trying to end the turn. |
| `this run is over its fix-loop budget` | The run has iterated more times than its effort tier's cap allows. The same budget is also checked at **Gate-B entry** — as a spec-level self-check, not a hook block: a Gate B pass is an `Agent` spawn that no hook can observe, so that loop would otherwise never meet the commit-time block at all. | Not a bug — it is the anti-churn check-in. Review the per-round findings: if returns have diminished, stop and park the rest; if continuing is genuinely right, record `gates.loop_budget.acked_through` (the block message prints the exact `jq`, which already steps the budget to the next cap rung above the current count, so one ack always suffices). The count is `max(iteration.fix, iteration.review)`, so **reopening** review rounds consume the budget too. |
| `auto-task loop budget: loop count N … exceeds …` at a turn-end | The Stop hook released one turn-end so the run could surface its budget check-in. The count is `max(iteration.fix, iteration.review)`, so **reopening** review rounds trigger it too. | Expected. Surface the per-round finding severities and let the user decide. Further turn-ends at the same loop count block again. |
| `commit messages and PR bodies must NOT contain "Co-Authored-By: Claude"` | The AI-attribution hook fired. | Rewrite the commit message / PR body without the marker. |
| `.auto-task/` showing up in `git status` as untracked | The exclude entry didn't land. | Append `.auto-task/` to `$(git rev-parse --git-common-dir)/info/exclude` (worktree-correct — in a worktree `.git` is a file, so the bare `.git/info/exclude` path fails). |
| `the working-tree diff changed since the last clean code-review pass` | Code was edited after the code-review gate went clean, so the staleness check fired. | Re-run the `auto-task-code-review` skill on the current diff, drive it to a clean pass, then refresh `gates.code_review.reviewed_diff_sha`. Do not bypass. |
| `jq is not installed` / `STATE.json is not valid JSON` (hook block) | A hook failed closed because it couldn't verify state during an active run. | Install `jq`, or repair/remove `.auto-task/<branch>/STATE.json` if no run is active. |

## Project settings (opt-in)

Per-project, per-user configuration for the pipeline. **Optional and fully defaulted** — a project with no settings file behaves exactly as it did before this feature existed.

- **Kept OUTSIDE your repo.** Settings live at `${AUTO_TASK_HOME:-$HOME/.claude}/auto-task/<project-key>/settings.json`. The `<project-key>` is derived from the repo's git **common dir** (`git rev-parse --git-common-dir`), which every worktree of one clone shares — so settings are **project-specific and per-clone** (all worktrees resolve to the same file), and a setting **never alters your repo** (nothing is written in the working tree; it never appears in `git status`).
- **JSON, with fallback.** A flat `key: value` object. Any key you omit falls back to the built-in default — the single source of truth is the `default_for` table in `hooks/settings.sh`. A missing file, malformed JSON, or an absent key all resolve to defaults (the reader is fail-open and never errors a run).
- **Two scopes: global + project.** Besides the per-project file, a **global** file at `${AUTO_TASK_HOME:-$HOME/.claude}/auto-task/settings.json` applies to every project. They merge as `defaults ⊔ global ⊔ project` — the **project file wins**, so you can set a default globally and override it (either direction) per clone. Both scopes are optional.
- **Managing them.** `bash hooks/settings.sh path` prints the project file location; `bash hooks/settings.sh init` seeds a project template and `bash hooks/settings.sh init --global` seeds the global one; `bash hooks/settings.sh get <key>` / `all` read the merged values. (The orchestrator reads them automatically in Phase 1.)

Recognized keys (v1):

| Key | Default | Meaning |
|---|---|---|
| `has_preview_deployment` | `false` (unset) | Whether the project has a preview deployment. **Auto-learned when unset:** on a post-PR run, `/auto-task` detects whether a deployment exists and **persists only a positive** here (found → `true`, verified every run thereafter). A non-detection is **not** persisted — the setting stays unset and re-learns next run, so a slow/degraded check can never leave a permanent wrong `false`. Set an explicit `false` to skip (and stop the per-run re-check); explicit `true`/`false` is honored and never overwritten. |
| `preview_autodetect` | `true` | Gates auto-learn: on each undecided post-PR run (until a positive resolves or you set an explicit value), when `has_preview_deployment` is unset and a PR is opened, poll its comments for a deployment URL (Vercel/Netlify/Cloudflare/… bot comment) and persist a positive result (`true`) — zero config. A non-detection is never persisted (stays unset, re-learns next run). Set `false` to disable auto-learn (unset then means "no preview", nothing persisted). |
| `preview_url` | `""` | Optional preview URL template (fallback when `gh` finds no deployment); `{branch}` is substituted. |
| `preview_wait_mode` | `"poll"` | `poll` = bounded in-session wait for the deploy; `handoff` = defer the check to a later `/auto-task` resume. |
| `preview_timeout_min` | `30` | Max minutes to wait for the preview before recording `pending`. |
| `preview_poll_interval_sec` | `60` | Seconds between readiness polls. |
| `preview_bypass_header` | `""` | Optional `Name: value` header for deployment-protection bypass tokens. |
| `preview_post_verdict_comment` | `false` | When `true`, post the verdict as a PR comment (an external write — off by default). |
| `bot_review_autofix` | `false` | Opt-in: after the PR opens, collect **Cursor/GitHub review-bot** comments and conservatively auto-apply the high-confidence, in-scope fixes (each through the full verify→review→gate→commit→push loop); park the rest. Off by default — enabling grants write authority to your PR branch. See "Post-PR bot-comment review" below. |
| `bot_review_timeout_min` | `10` | Max minutes to poll for bot comments after the PR opens. |
| `bot_review_poll_interval_sec` | `30` | Seconds between bot-comment polls. |
| `bot_review_bots` | `""` | Extra bot logins to treat as review bots (space/comma-separated), beyond the built-in list + any `[bot]`/`type:Bot` account. |
| `external_actions_mode` | `"ask"` | How **Phase 8** applies an external-system change (CMS edit, feature-flag toggle, live data migration, third-party API config). `ask` (default) = ask once for permission + credentials, then run the script and verify — fall back to a runbook if declined. `runbook` = never auto-run; always emit a runbook and wait. `auto` = pre-authorized to run without the prompt (any *irreversible* action still prompts; unreachable creds degrade to runbook). Gates only *how* it applies — **detection + the "not done until applied" marking are always-on**, never gated. See "External change application" below. |
| `external_actions_timeout_min` | `30` | Max minutes Phase 8's in-session **settle-poll** (an `auto`-run apply whose external effect is asynchronous) waits for the change to propagate before surfacing. A `runbook`/`awaiting-external` human handoff does **not** poll — it yields and waits for a `/auto-task` resume — so this bound does not apply there. |
| `external_actions_poll_interval_sec` | `60` | Seconds between Phase-8 settle-poll cycles. |
| `docs_update_mode` | `"skip"` | Whether the optional **docs-update step** runs at handover, so a run's docs do not go stale. `skip` (default) = never run it, never ask. `always` = refresh docs every run, no prompt. `ask` = ask each run — but only when the step actually finds something stale, so a docs-current run stays silent. Scoped to `README.md` + `docs/**`; never `CHANGELOG.md`, `CLAUDE.md`, or code comments. Chosen at first-run setup; any unrecognized value reads as `skip`. See "Docs update at handover" below. |
| `release_mode` | `"skip"` | Whether the optional **release step** (**Phase 9**, the last phase) runs, so landed work can be cut as a release in the same run. `skip` (default) = never run it, never ask. `always` = cut the release every run, applying the derived bump with no prompt. `ask` = ask each run — but only when there is actually something to release, so a nothing-to-release run stays silent. **Local only: it never pushes and never publishes.** Not a first-run-setup question — like `bot_review_autofix`, it is a quiet default-off opt-in you edit in the settings file. Any unrecognized value reads as `skip`. See "Release at handover" below. |
| `release_command` | `""` | Your project's own release command that the release step runs to write the version bump. It must only **write files** — `scripts/release.sh`, or `npm version minor --no-git-tag-version`. A command that commits and tags by itself (bare `npm version`, `standard-version`, `semantic-release`) breaks the hand-off, because auto-task commits after its own re-gate; the step detects that in its dry-run report and refuses rather than running it. Delegated on purpose — only your project knows its full version-file set. **Unset (the default) → the step emits a paste-ready runbook and runs nothing**, rather than guessing a multi-file bump. A delegated command runs under **your** authority and may itself push or publish; the step tells you what it will do before running it. |
| `review_in_subagent` | `true` | **Where Phase 4's code review runs.** `true` (default) spawns ONE fresh-context `general-purpose` agent that **invokes the `auto-task-code-review` skill** via the Skill tool — so the model that wrote the diff is not the model that reviews it. `false` invokes the same skill inline in the main loop, restoring the earlier behaviour. Both modes run the same skill on the same diff and record the same `gates.code_review.tool`, so the commit gate is byte-identical either way; only the reading context changes. **On the `true` path only**, round 1 reviews the full working-tree diff and every later round only the **delta** since the previous round's recorded boundary (`rounds[n-1].diff_sha`) — that is what keeps the cost near half of a full re-review rather than doubling it. `false` reviews the full diff every round, exactly as before. The agent's prompt forbids edits and forbids writing anything under `.auto-task/` — it reports, the orchestrator fixes. A failed spawn or a malformed report falls back to the inline call after one retry, so the setting can never deadlock a run. Skips `shadow_review` while on. |
| `shadow_review` | `false` | **Measurement only — decides nothing.** When `true`, one fresh-context `general-purpose` agent re-reviews the diff once per run, right after Phase 4 goes clean, by **invoking the `auto-task-code-review` skill** (never a hand-rolled prompt). It sets no gate, reopens no round and blocks nothing; it records what the self-review missed into `state.shadow_review.missed[]`, each entry graded by Phase 4's own Step-A test so you can tell a missed AC breach from a missed README nit. **Skipped while `review_in_subagent` is on**, which is the default — with the review already independent there is no self-review left to measure, and the skip is recorded as a status rather than omitted. It is for the `review_in_subagent: false` configuration, where Phases 2-4 all run in the main loop and the model that wrote the diff also reviews it. Costs roughly one Gate-A-sized pass (~24k output tokens) per run while it actually runs. |
| `visual_assets_enabled` | `false` | Opt-in: embed **before/after screenshots** in PRs for visual changes (uploaded to **Cloudinary**, embedded inline). Off by default; `/auto-task` asks once per repo (only on UI-scoped runs) before enabling. Off → verification still runs locally; the PR gets a local-artifact + preview note instead. Requires `cloudinary_cloud_name` + `cloudinary_upload_preset`. See "Visual PR proof" below. |
| `cloudinary_cloud_name` | *(bundled)* | Cloudinary cloud name uploads go to. Defaults to a **bundled shared** disposable cloud so opt-in embedding works out of the box; override with your own (or `AUTO_TASK_CLOUDINARY_DEFAULT_CLOUD`). Not a secret — it's in every delivery URL. |
| `cloudinary_upload_preset` | *(bundled)* | The **unsigned** upload preset. Defaults to the bundled preset; override with your own (or `AUTO_TASK_CLOUDINARY_DEFAULT_PRESET`). Not a secret. An unsigned preset is world-writable, so self-hosters should restrict their own (allowed formats/size, fixed folder, moderation). |
| `telemetry_enabled` | `false` | Opt-in for **remote** anonymous telemetry. Default OFF. See "Remote telemetry" below. |
| `telemetry_endpoint` | *(bundled)* | HTTPS ingest URL the anonymized row is POSTed to. **Defaults to the bundled central collector** (shipped in `hooks/settings.sh`); override to self-host. Must be `https://…` — a non-https/empty value sends nothing. |
| `telemetry_ingest_token` | *(bundled)* | Bearer token sent as `Authorization: Bearer …`. **Defaults to the bundled PUBLIC write-only key** (world-readable by design; a leak only permits junk writes). Override to self-host, or clear it to send no auth header. |
| `telemetry_satisfaction_prompt` | `true` | When telemetry is on, whether Phase 5 asks a satisfaction/correctness question at the push prompt. |
| `history_reminder_enabled` | `false` | Opt-in `UserPromptSubmit` hook (`inject-history-reminder.sh`) that tells non-bundled tools an `.auto-task/<branch>/` history folder exists for the current branch. Wired in every install but OFF by default; enable with `settings.sh set history_reminder_enabled true`. Emits nothing outside auto-task branches. |
| `worktree_cleanup_nudge` | `true` | Whether the SessionStart hook nudges you (non-destructively) when reclaimable auto-task worktrees accumulate. Set `false` to silence it. See "Worktree space control" below. |
| `worktree_cleanup_throttle_hours` | `24` | Minimum hours between cleanup nudges, **per clone**. |
| `worktree_cleanup_prune_dirty` | `false` | Whether `/auto-task-gc --prune --yes` may reclaim a **dirty** worktree — by WIP-committing its uncommitted work (tracked + untracked) to its branch first. Off by default: dirty worktrees are kept. |
| `worktree_stale_days_default` | `14` | Days a **clean, unmerged** worktree must be untouched (by last-commit date) before it counts as reclaimable — fallback for any type without its own key. |
| `worktree_stale_days_feat` / `_refactor` | `30` | Per-type stale threshold for `feat/` and `refactor/` branches (longer-lived work). |
| `worktree_stale_days_fix` | `14` | Per-type stale threshold for `fix/` branches. |
| `worktree_stale_days_chore` / `_deps` / `_docs` / `_cleanup` | `7` | Per-type stale threshold for short-lived `chore/`, `deps/`, `docs/`, `cleanup/` branches. |

### Worktree space control (`/auto-task-gc`)

Each `/auto-task` run creates a git worktree under `.claude/worktrees/<type>-<slug>` and **keeps it** so its branch and `.auto-task/<branch>/` history stay available. Because every worktree carries a full working tree (often a multi-GB `node_modules`), they accumulate — a busy repo can reach tens of GB.

Two pieces keep that in check, and **nothing deletes without you asking**:

- **A SessionStart nudge** (`hooks/suggest-cleanup.sh`, on by default) — cheap and local-only (no `du`, no network), throttled once per `worktree_cleanup_throttle_hours` **per clone**. When ≥1 worktree looks reclaimable — **merged**, or **clean and stale** past its per-type `worktree_stale_days_<type>` threshold — it prints a one-line suggestion to run `/auto-task-gc`. It never deletes and never blocks; silence it with `worktree_cleanup_nudge: false`.
- **`/auto-task-gc`** (the `auto-task-gc` skill) — the on-demand tool. `/auto-task-gc` **reports** each worktree's size (`du`), age, type, and merge status (local ancestry **and** `gh` for squash-merged PRs) read-only. `/auto-task-gc --prune` previews the removal plan; `/auto-task-gc --prune --yes` performs it after you confirm. Removal **preserves the branch ref** (committed work is recoverable with `git worktree add <path> <branch>`) and prunes the matching `.auto-task/<branch>/`. Dirty worktrees are kept unless `worktree_cleanup_prune_dirty: true` (then WIP-committed first); the current and main worktrees are never removed; `--all` widens to every clean worktree regardless of merge/age. One caveat: removing a worktree deletes its directory, so **gitignored** files inside it go too (that's the point for `node_modules`, but a local `.env` or other ignored scratch is removed and is *not* captured by the WIP-commit) — the report lists exactly which worktrees will be removed, so run it first.

Retention is **per branch type** so short-lived `chore`/`deps`/`docs`/`cleanup` work is reclaimed sooner than `feat`/`refactor`. Every threshold ships as a default and is overridable, e.g. `bash hooks/settings.sh set worktree_stale_days_feat 45`.

### Docs update at handover (`docs_update_mode`)

A run changes behavior; the docs that describe that behavior go stale. `docs_update_mode` decides what auto-task does about it, and it is one of the five questions asked once per repo at first-run setup:

| Value | Behavior |
|---|---|
| `skip` *(default)* | Never run the docs step, never ask again. Exactly the pre-feature behavior. |
| `always` | Refresh the docs on every run, no prompt. |
| `ask` | Ask once per run — **but only when there is actually something to update.** |

The step runs in **Phase 5, before staging**, which is the design decision that keeps it cheap: the docs edits join the run's **single handover commit** rather than needing a second commit, and they re-pass the same gates as the code (re-verify → re-`auto-task-code-review` → refreshed review hash, plus a Gate B re-run on STANDARD/HEAVY). It composes the bundled **`auto-task-docs`** skill, which you can also run on its own (`/auto-task-docs`) whenever docs have drifted.

Three properties worth knowing, because they are what stop an "optional step" from becoming an annoyance:

- **Scoped narrowly.** It edits `README.md` and `docs/**` only — never `CHANGELOG.md` (the release flow owns that), never `CLAUDE.md` or skill/agent instructions (those change *behavior*, not documentation), never code comments (they belong to the code diff). Staleness found outside that set is reported as a follow-up, not edited.
- **Staleness is resolved before the prompt.** The skill produces a `file:line`-cited report first, so `ask` never interrupts you about a change that does not exist. A repo with no `README.md` and no `docs/` directory, or docs that are already current, is a silent no-op in every mode.
- **It never blocks an unattended run.** Under `autonomy: autonomous` — or headless, where there is nobody to ask — `ask` applies the edits without yielding and records the decision in the run's assumptions ledger, which is surfaced at the merge gate. And a clean docs re-review does not consume the fix-loop budget, since no finding drove it.

Every edit is evidence-backed (each traces to a `file:line` staleness finding tied to the diff) and minimal (it corrects what the change falsified, and leaves the rest alone) — so the docs portion of the commit stays trivially separable from the real change at review time.

### Release at handover (`release_mode`)

A run finishes and the work has landed — but cutting the release is still a separate session: bump the version, write the changelog entry, commit, tag. `release_mode` lets the run do that last mile. It is a **quiet default-off opt-in** you set in the settings file (`bash hooks/settings.sh set release_mode ask`), deliberately *not* a first-run-setup question — most projects do not want a task runner touching their version numbers, so it does not spend one of the setup prompts or force a settings reset.

| Value | Behavior |
|---|---|
| `skip` *(default)* | Never run the release step, never ask. Exactly the pre-feature behavior. |
| `always` | Cut the release every run, applying the derived version bump with no prompt. |
| `ask` | Ask once per run — **but only when there is actually something to release.** |

It runs as **Phase 9, the last phase** — after the work has genuinely landed and after any external change has been applied, which is the point at which a version number means something. It composes the bundled **`auto-task-release`** skill, which you can also run on its own (`/auto-task-release`) whenever you want to cut a release by hand.

**It never pushes and never publishes.** The commit and the annotated tag stay local, and the step hands you the exact `git push origin HEAD && git push origin vX.Y.Z` (plus any publish step) rather than running them. That boundary is what makes the whole thing safe to automate: because nothing left your machine, a release you do not like is undone completely with `git tag -d vX.Y.Z` and `git reset --hard HEAD~1` — and the step surfaces those commands, with their precondition (the release commit is still `HEAD` and the tree is clean), whenever it applied anything.

Five properties worth knowing, because they are what stop an automated release from being a liability:

- **The version bump is delegated, never guessed.** Only your project knows where its version lives — this plugin's spans `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and a generated notes artifact. So the step runs your `release_command` and never hand-edits a manifest. With no command configured it emits a paste-ready **runbook** and changes nothing, which is an honest fallback rather than a half-bumped repo. It also verifies the bump actually happened before tagging, so a command that silently no-ops cannot leave a changelog entry for a version that does not exist.
- **The bump level is derived *with its evidence*, then confirmed.** A `PLAN.md` breaking-change note or a `feat!:` marker gives major, a `feat`/new-capability gives minor, everything else patch — and the prompt shows you the level *and the signal that produced it*, so you can override it. In `always` mode (or when the run is autonomous/headless) the derived level is applied unattended and recorded in the assumptions ledger.
- **The release commit is gate-reviewed like any other.** The bump and changelog are new authored bytes, so the step re-runs verification, re-runs `auto-task-code-review` to a clean pass, refreshes the review hash, and re-runs Gate B on STANDARD/HEAVY before committing. No hook was weakened to let a release through — which is also why Phase 9 runs *before* the run is marked done, not after.
- **Anything but an explicit `direct` landing defers instead of releasing.** A `chore(release):` commit belongs on the default branch, not inside a PR awaiting review, so the step records `deferred-pr` and hands you the runbook to run after the merge. The check is deliberately written to fail *safe*: it tests the run's recorded landing for an explicit `direct`, so `landing_model: pr` defers — and so does a run whose landing was never recorded (anything started before that field existed) or holds an unexpected value. If you see `deferred-pr` on a project you think is `direct`, that is why. And a partial failure — a commit whose tag did not land, the state most easily mistaken for success — is reported as a partial failure with both the continuation and the unwind, never as done.
- **An interrupted release is handed to you, not auto-resumed.** This is a deliberate limit rather than a gap. Cutting a release rewrites git history, and an automated recovery that guesses wrong can re-cut a release you just unwound or re-apply a bump you reverted — so if a session dies mid-release, the step records what it was doing and the next run *surfaces* that state (the version, the step it died at, the current `git log`/`git tag`/`git status`, and the exact undo commands) instead of trying to finish the job itself. Same for a partial failure or a failed re-gate: auto-task never auto-resumes, auto-retries, or auto-reverts a release. What it does guarantee mechanically is the part that matters — **an interrupted release never silently re-cuts and never reports success.** The judgement call is yours.

### Post-PR bot-comment review (opt-in)

Set `bot_review_autofix: true` and `/auto-task` adds **Phase 6** after the PR opens: it polls (bounded, default 10 min) for comments left by review bots — Cursor, CodeRabbit, Sourcery, GitHub Copilot review, and any `[bot]`-suffix / GitHub `type:Bot` account (extend via `bot_review_bots`) — via `hooks/pr-bot-comments.sh`, which merges the PR's issue comments, inline review threads, and review summaries into one de-duplicated set. It triages them **conservatively**: only high-confidence, in-scope findings that don't contradict a decision you already made are auto-applied, each routed through the same verify → `auto-task-code-review` → gate → commit → push loop as any other change (so every bot-fix commit is fully re-reviewed before it can land — the pre-commit gate is unchanged). Everything else is parked as a follow-up and reported. It runs exactly one collection round (it does not chase comments its own fix-push re-triggers); a fork-PR / protected-branch push failure is fail-open (parked, never a hard stop). Off by default — enabling it lets the pipeline push bot-derived fixes to your PR branch.

### Visual PR proof (opt-in)

For UI/visual changes, `/auto-task` verifies on **local dev first** (reusing a running dev server, or improvising a bounded, disposable render — Storybook / a test harness / a static build / a mock server — and mocking or seeding only what's needed to reach the *real* UI), then re-checks on the preview when one exists. A UI it can't reach even after improvising is recorded **INCONCLUSIVE** (never a proxied pass), never a hard stop. Playwright sessions and any disposable render are closed when done.

Set `visual_assets_enabled: true` (off by default; `/auto-task` asks once per repo on UI-scoped runs) and the run also embeds a **before/after screenshot pair** in the PR. Images are uploaded to **Cloudinary** via an **unsigned** upload preset — and it works **out of the box** using a **bundled shared** (disposable) Cloudinary account, so no setup is needed to try it. Point `cloudinary_cloud_name` + `cloudinary_upload_preset` at your own account (or the `AUTO_TASK_CLOUDINARY_DEFAULT_*` env vars) to use your own — recommended for real/heavy use, since the shared cloud is a common free-tier pool. The delivery URL renders **inline for public and private projects alike** (GitHub proxies external images through its Camo cache), needs no `gh`, no repo, and no API secret, so it works from any checkout including a fork PR. Two caveats for your own account: an unsigned preset is **world-writable** (restrict it — allowed formats/size, fixed folder, moderation), and unsigned upload **cannot delete**, so screenshots **persist** (the free tier is ample for KB-scale crops). Embedding is best-effort presentation — if the upload returns no `secure_url` (or the keys were overridden empty), the PR just carries a local-artifact + preview note; it never blocks the run.

### Preview verification (opt-in + auto-learn)

When a push happened and a preview is expected, `/auto-task` adds a final **Phase 7** after the PR (and after any Phase-6 bot-fixes): it waits for the preview deployment (bounded, configurable — default 30 min), resolves the preview URL (from `gh` deployment statuses bound to the pushed commit, else the PR's deploy-bot comment, else the configured `preview_url`), re-runs the URL-checkable Acceptance Criteria against the live preview plus a smoke check (loads, no console errors), and records a **final verdict** — `PASS` / `FAIL` / `INCONCLUSIVE` — in `STATE.json`, `CONTEXT.md`, and (optionally) a PR comment. A timeout records `pending` and asks you to resume; a `FAIL` surfaces with evidence (the commit already shipped, so it recommends a follow-up fix rather than auto-looping); an auth-protected (401/403) preview is reported as `INCONCLUSIVE` with a bypass-token hint, never masked.

**Auto-learn (zero config).** You don't have to set `has_preview_deployment`. Left unset, a post-PR run detects whether a preview deployment exists and **persists only a positive**: found → `true` (verified every subsequent run). If none is found, **nothing is persisted** — the setting stays unset and the next post-PR run re-attempts detection, so a slow deploy bot or a degraded check (no `gh`/auth/PR) is a transient miss, never a permanent wrong `false`. The tradeoff is a bounded re-check each post-PR run on a genuine no-preview repo: set `has_preview_deployment: false` explicitly to skip with no polling. An explicit `has_preview_deployment` is always honored and never overwritten; set `preview_autodetect: false` to turn auto-learn off entirely.

### External change application (Phase 8)

Some tasks aren't finished when the code ships — they also need a change in an **external system**: a CMS edit, a feature-flag toggle, a data migration run against live, a third-party API config. Shipping the script that *would* make that change is not the task being done. So `/auto-task` treats these as first-class **external actions**:

- **Declared up front.** In Phase 1 the plan names each external action and adds an Acceptance-Criteria row for it (`Gate = external`) — the target system, how to apply it, and how to verify it took. Detecting external side effects and marking the task not-done are **always-on** (like the honesty floor), never gated by a setting.
- **Applied + verified in Phase 8** (after preview verification; Phase 9, the opt-in release step, is the last phase). By default (`external_actions_mode: ask`) it asks **once** for permission + credentials, runs the change, then re-verifies the external-action ACs plus a smoke check. `runbook` mode never auto-runs — it emits a paste-ready runbook (with a rollback/recovery section) and waits; `auto` pre-authorizes running without the prompt (but any action marked **irreversible** still prompts, and unreachable credentials degrade to a runbook). Credentials are provided at the prompt or via an environment/secret-file reference — **never stored** in settings, state, the trace, or artifacts, and secret-shaped tokens are redacted from captured output.
- **Not done until applied.** A task with an un-applied external change **never reaches `done`** — it stays in an explicit `awaiting-external` (or `declared`, if the push was held) state, and the PR body, run summary, `CONTEXT.md`, and trace all carry a prominent **"⚠ TASK NOT DONE until external changes applied"** banner. Only once the change is applied *and* its post-apply verification passes does the run flip to `done`; Phase 8 then replaces the banner with an "applied + verified" confirmation. Partial multi-action failures stop and surface with per-action rollback steps; resuming skips already-applied actions so an irreversible step never runs twice.
- **Backward-compatible.** A code-only task declares no external actions, Phase 8 is a no-op, and the run completes exactly as before.

## Run telemetry (opt-in)

Off by default. When you want to measure how the pipeline actually performs — completion rate, where runs stall, whether Gate B earns its cost — opt in **per-clone** by running this **at the repo root** (the main working tree):

```sh
touch .auto-task/outcomes.jsonl
```

From then on, every `/auto-task` run that reaches `phase: done` triggers the `record-outcome.sh` Stop hook, which appends **one JSON row** derived entirely from the run's `STATE.json` (tier, fix/review iterations, **review rounds run**, effort escalations, Gate B outcome, follow-up count, duration). It is **purely local** — no network, and no data beyond what `STATE.json` already stores on disk. A base-keyed sentinel (`.auto-task/<branch>/.outcome-recorded`) makes it write exactly once per run; the ledger lives under the gitignored `.auto-task/` and is never committed. Opt out by deleting the file. The hook never blocks a turn-end and no-ops entirely when the ledger file is absent, so leaving it off costs nothing.

**One ledger per clone, not per worktree.** Runs are isolated in linked worktrees, but the ledger's whole purpose is history that outlives any single branch folder — so its location is resolved to the **main working tree** (`hooks/lib/clone-scope.sh`), and a run finishing in any worktree appends to that one file. This is why the `touch` belongs at the repo root: a ledger created *inside* a worktree is not the one the hooks use. If you have a stray one from an earlier attempt, fold it in with `cat <worktree>/.auto-task/outcomes.jsonl >> .auto-task/outcomes.jsonl` and delete it.

Because the ledger is clone-wide it now has multiple writers, so the append is guarded: a bounded `mkdir` mutex, a post-append check that the row actually landed, and the sentinel stamped *only* after that check passes, so a torn write leaves the run retryable on the next turn-end instead of losing it. Anything the reader nonetheless has to skip is **counted and named** rather than dropped in silence — both an unparseable ledger line and a live `STATE.json` it could not read, could not derive a row from, or found somewhere other than where its own `branch` field says it lives.

The mutex is fail-open and **bounded, not free**: an uncontended append costs a fraction of a second, and the worst case — another writer holding the lock, or a `.auto-task/` it cannot write to — is a measured **~2 s** before it gives up and appends anyway. It never hangs and never blocks a turn-end, but "bounded" is the honest word rather than "instant".

Read the aggregated report with:

```
/auto-task:auto-task-stats            # marketplace install
/auto-task-stats                      # install.sh fallback
/auto-task-stats 14                   # override the stale-run threshold (days; default 7)
```

The reader merges the archived ledger with every live `.auto-task/*/STATE.json` **across every worktree of the clone** (so in-flight and stalled runs — which never reach the ledger — are still counted, wherever they live), de-duplicating on branch+base. Run it from the main tree or from any worktree; both see the same picture. Sample output:

```
auto-task run stats  (stale threshold: 7d)
====================================================
5 runs on record — 3 done, 1 stalled, 1 in-flight
Completion rate    75%  (3/4 terminal; in-flight excluded)

Where stalled runs died
  feat/stalled @ phase=review — stuck on flaky test

By tier
  tier       #done     med fix     med review     med rounds   escalated
  heavy          1           4              3              6          0%
  light          1           0              1              1          0%
  standard       1           2              2              4        100%

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

A live, approved, non-`done` run whose newest history entry is older than the stale threshold is reported as **stalled**; newer than it, **in-flight**. "Gate B coverage" is how many STANDARD/HEAVY runs actually ran the adversarial gate to a pass (vs. were skipped) — derived from the recorded `gate_b` outcome. (A per-run "did Gate B catch a bug" count isn't reported: the orchestrator doesn't record a Gate B bounce as a distinct `STATE.json` signal, only as a review-loop iteration, so it can't be reconstructed after the fact without changing pipeline behavior.)

### Remote telemetry (opt-in, off by default)

The telemetry above is **local only** — nothing leaves your machine. If you want to send the same quality/performance signals to a central endpoint (to build a cross-user dashboard later), there is a **separate, explicit, off-by-default** remote path. It is independent of the local `outcomes.jsonl` opt-in.

**You are asked once per repo.** The first time you run `/auto-task` in a repo with no telemetry decision recorded, Phase 1 asks a single consent question — *"Share anonymous auto-task telemetry from this repo?"* — with **Enable** / **No thanks (don't ask again)**. Your answer is saved to that project's settings (`telemetry_enabled: true` or `false`), so you're never asked again for that repo. Declining is remembered as a decision. It's off until you answer; a headless run with no prompt available just stays off.

**Or set it yourself** with a single key in the [project or global settings](#project-settings-opt-in):

```jsonc
// ~/.claude/auto-task/settings.json (global)  — or  <project-key>/settings.json (project)
{ "telemetry_enabled": true }
```

That's all a user needs — the **destination is pre-wired**. `telemetry_endpoint` and `telemetry_ingest_token` ship with the plugin as built-in defaults pointing at the project's central collector (the `auto-task-plugin-admin` dashboard), so opting in sends there automatically. Only the destination is bundled, **not** the consent — collection stays OFF until you explicitly set `telemetry_enabled: true`.

- **The bundled ingest token is a PUBLIC, write-only key — not a secret.** It ships inside this open-source client, so it is world-readable by design (like a Sentry DSN / analytics write key). A leak only permits appending junk rows: it is write-only, can't read the dashboard, and never carries the Turso credential. The endpoint is protected server-side (rate-limiting); rotate the key to cut off abuse.
- **Self-host** by overriding `telemetry_endpoint` (and `telemetry_ingest_token`) in your settings to point at your own dashboard.
- Because settings merge `defaults ⊔ global ⊔ project`, you can opt in globally and **exclude one project** with `{ "telemetry_enabled": false }` in that project's file (or opt in for just one). A non-https or emptied endpoint sends nothing.
- **Maintainers:** the shipped defaults live in `hooks/settings.sh` (`AUTO_TASK_TELEMETRY_DEFAULT_ENDPOINT` / `_TOKEN`) — set them to your deployed dashboard URL and its `INGEST_TOKEN` at release. `settings.sh get telemetry_endpoint` shows users exactly where data goes.

**What is sent** (when on, once per completed run, at `phase: done`; `schema_version: 7`): the run's quality/perf metrics — tier, effort **difficulty/risk**, escalations, fix/review iterations, **review rounds run** (distinct from the reopening count, so you can see the review running more without finding more), Gate B outcome, follow-up count, duration, estimate-vs-actual time + **input/output tokens** (cache-excluded), defects early/late, flaky, tests-added, diff size + **files changed**, first-pass-AC, checks tally, requirements count, drift events, preview verdict — **plus** environment (random install id, plugin version, OS, **Claude model + Claude Code version**), the **change type** (`task_type`, a bounded enum — see the table below; e.g. `feat`/`fix`/… — the branch *prefix* only, never the slug), **bucketed project size + primary language + monorepo flag**, an anonymous **change-heat** signal (churn ratio, hotspot concentration, dirs-touched, max-depth — numbers derived from a *local* path history that never leaves), a schema version, and your Phase-5 satisfaction/correctness answers + optional comment.

**What is NOT sent — it's anonymous by construction:** no task description, no branch name, no repository path, no base commit SHA, and no wall-clock timestamp (the server stamps its own `received_at`). The install id is a random UUID with no personal data. The **one exception** is the optional satisfaction *comment* — free text you type at the prompt, sent verbatim; leave it blank to send nothing free-form.

**Change type (`task_type`).** Each run is labelled with a bounded change-type enum, derived from the branch `<type>` prefix (never the slug) and normalized case-insensitively. Any unrecognized or slash-less prefix folds to `other`, so the set is closed and dashboard-groupable. **`change_type` is a bounded label — no per-run free text** (the only user-authored free text remains the optional satisfaction comment below).

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

**Satisfaction prompt.** When telemetry is on, the single existing Phase-5 push prompt gains one extra question — *"Did this run produce a correct, satisfactory result?"* (`yes`/`mostly`/`no`/`skip`) — plus an **optional free-text comment**. So no new interruption point is introduced. Set `telemetry_satisfaction_prompt: false` to collect metrics without the prompt. The comment is the one field that isn't auto-anonymized — it is **whatever you type**, sent verbatim (capped 500 chars) to your endpoint, so leave it blank if you don't want free text to leave the machine.

**Reset or opt out.**
- Opt out: set `telemetry_enabled: false` (or remove the endpoint). Data stops immediately.
- Reset your install id: `rm ~/.claude/auto-task/client-id` — a new random id is generated on the next send.

**Transport.** The client `curl`s the payload to your endpoint with a bounded timeout (`--connect-timeout 2 -m 5`) and is fail-open — a slow or dead endpoint never blocks or breaks a run. It fires once per run (a base-keyed sentinel prevents resends). Implemented in `hooks/send-telemetry.sh`.

**The endpoint + database.** A **reference (undeployed)** ingest server and the Turso/libSQL table schema live under [`server/`](server/README.md): a portable `fetch` handler (`server/ingest.mjs`) that writes to a `runs` table (`server/schema.sql`). You deploy it and provision Turso yourself; the server holds the DB credential so clients never carry one. It is write-only for now (a dashboard is future work).

## Run metrics — estimate vs actual, quality signals

Every run now measures itself and reports it in the final summary (and, if telemetry is opted in, as cross-run trends above).

- **Estimate before execution.** At the Phase-1 approval gate the plan carries an `## Estimate` of wall-clock time and **output** token usage, computed by `hooks/estimate.sh` from the scored tier/difficulty/risk, the Acceptance-Criteria count, and the blast-radius file count. It is a simple tier-based heuristic, now **calibrated against measured actuals** (n=4 runs; fit 0.71x-1.25x; median 1.01x by the mean-of-middle convention, 0.845x by the lower-median convention `auto-task-stats` uses) rather than guessed — though with 2 standard + 2 heavy and **zero** light-tier runs, the light tier is extrapolated, not fitted. Read it as a trend input, not a promise. It estimates **output tokens only**: measured `input` is ~1k per run and measured `cache_read` swings 189x-467x of output, so neither is predictable. The estimate-vs-actual comparison is therefore output-vs-output — comparing an estimate against the cache-inflated `tokens_total` is a unit error, and was one (66x-434x across the four measured runs) until this was corrected.
- **Actual measurement.** At handover, `hooks/token-usage.sh` sums `message.usage` from the session transcript(s) under `~/.claude/projects/<slug>/`, **run-scoped** by `--since <run-start>` (it sums across multiple transcripts, so a resumed / new-session / post-compaction run isn't undercounted). **Wall-clock is measured, not narrated:** it comes from the hook-stamped run clock (`hooks/stamp-run-clock.sh` writes `created_at`/`updated_at` from `date -u`; `hooks/lib/run-clock.sh` derives the span), replacing a figure that used to be computed from the model-written `state.history[].at` timestamps — the model has no clock, so those numbers were guesses. A negative or over-12h span is **rejected to `null`**: a run paused overnight (forwarded questions, an awaiting-external handoff, a next-day resume) has a wall-clock that is not a meaningful "how long did this take", so it is excluded rather than reported. That is a deliberate accuracy-over-coverage trade — multi-day runs report no duration at all — and a rejection stays distinguishable from an absent clock, which still falls back to the old history formula so runs predating this keep reporting. Caveat: token accounting is approximate for sub-agent sidechains and any concurrent unrelated work in the same session. A failed measurement is recorded as `null` (never a fabricated `0`).
- **Estimate vs actual.** The CONTEXT.md and PR carry an `## Estimate vs actual` table (estimated · actual · Δ · ratio) for time and **output** tokens. The measured grand total (`tokens_total`, cache_read-dominated) is listed for the record but carries **no ratio** — nothing estimates it.
- **Checks manifest.** `## Checks performed` enumerates *every* verification the run executed — typecheck, lint, build, unit, e2e/playwright, each AC bound-check, the universal `hooks/checks.sh` hygiene checks (secret-scan, conflict-markers, debug-artifacts, large-files, test-integrity, diff-size, tests-added), and the Gate A/B findings — each with a pass/fail/warn result. `checks.sh` runs in self-verify; a real secret or leftover conflict marker outside test/fixture paths fails the run. It runs **again at commit time**, inside `enforce-gates.sh` — the self-verify pass is model-invoked, so the commit-time pass is what stops a secret leak or a gutted test from landing *silently*: clearing one requires writing a durable, diff-pinned, reviewable `gates.hygiene.acked[]` record that says so. It is not a claim of completeness — the scanner is regex-based, so a credential shape it does not recognize still passes, and the ack itself is prose-trusted (see the audit's F2 class).
- **Quality signals — not a score.** `## Quality signals` is a panel (defects caught early vs. late, delivery reliability = estimate accuracy + loop count, scope discipline, completeness, and a maintainability read **reused from the code-review verdict**), with an explicit note of what a single run *cannot* measure (business impact, collaboration, long-term maintainability). There is deliberately **no composite 0–100 score**: a single number invites optimizing to the metric and hides those blind spots. Quality is best read as *signals plus trends over time* — which is what the telemetry section above provides.

The measurement helpers are pure, deterministic, fail-open (they never break a run), and each has a focused test under `tests/`.

## Pruning history & worktrees

Per-branch folders under `.auto-task/` never auto-prune during a run. Reclaim them (and the far larger worktree checkouts) with **`/auto-task-gc`**, which removes reclaimable worktrees and prunes their matching `.auto-task/<branch>/` in one pass — see "Worktree space control" above. For a `.auto-task/<branch>/` folder that has no worktree, `rm -rf .auto-task/<old-branch>/` by hand. Nothing in the plugin depends on stale folders being present.

## Releasing (maintainers)

Cutting a release is a dedicated commit, separate from the feature commits it describes:

1. **Write the changelog entry.** Add a `## [X.Y.Z]` section to `CHANGELOG.md` opening with a one-paragraph lead that describes the release **from the user's point of view** — that paragraph becomes the release note users actually see.
   - If the release changes nothing a user can observe (internal refactor, dev-only tooling, a docs sync), add `<!-- release-notes: skip -->` so it produces **no** note. Unmarked releases are included by default.
   - To show different wording than the lead paragraph, use `<!-- release-notes: your short text -->`.
   - **Put either marker directly under the `## [X.Y.Z]` heading**, above the lead paragraph. A marker written lower down is treated as an *example* rather than an instruction — otherwise a release that documents this feature would delete its own note — and the generator refuses to write until you move it. If you do want to show the marker in an entry, put it in a fenced code block or inline code (an unfenced HTML comment renders as nothing anyway).
2. **Bump the version** in `.claude-plugin/plugin.json` *and* `.claude-plugin/marketplace.json` (they must match). Do this *before* step 3 — the generator cross-checks the version it finds in `plugin.json`, so bumping first is what lets it verify the release you are actually shipping.
3. **Regenerate the notes file** — `scripts/build-release-notes.sh`. This distills `CHANGELOG.md` into `.claude-plugin/release-notes.json` (newest 10 releases, each capped at 300 characters) and must be committed alongside the changelog. `scripts/build-release-notes.sh --check` reports staleness without writing; `--stdout` previews.
   - It **refuses to write** rather than ship a release with no notes, and says which problem it found. The one worth recognising: *"the version being shipped … has no note and no skip marker"* means the `## [X.Y.Z]` heading for that version is missing or mistyped (it must match exactly — no extra spaces, no leading `v`, three components), or the entry produced no usable text. Fix the heading or the entry; do not work around it.
4. **Verify.** Run `tests/release-notes-sync.test.sh` — it fails if the committed `release-notes.json` and a fresh generation disagree, which is the guard against a changelog entry shipping without its note.
5. **If your entry contains a fenced code block, close it.** That is the one malformed shape nothing can catch for you: a fence left unclosed *inside* its own entry but closed by a later ` ``` ` is balanced overall, so every release heading it spans is swallowed with no diagnostic. It eats the *older* entries below it rather than yours, so eyeballing the file for your own version would not reveal it. Nesting is handled correctly — showing a fenced block inside a longer fence works as CommonMark specifies — so this only happens with a genuinely unbalanced fence, which most markdown renderers also render wrongly.
6. **Commit** as `chore(release): vX.Y.Z`, tag it annotated, and push the commit and the tag.

> **Automating this checklist.** Steps 1-3 and 6 are exactly what the optional **release step** does (see "Release at handover"): point `release_command` at a script that performs steps 2-3 (bump both files, then `scripts/build-release-notes.sh`), set `release_mode` to `ask`, and a run will draft the changelog entry, cut `chore(release): vX.Y.Z`, and tag it — leaving the push to you. Step 4's drift test then runs as part of the step's own re-verification. Step 5 stays yours: an unbalanced fence is the one shape nothing can catch.

> **Note:** there is no CI in this repo, so nothing runs these steps for you. Two things do check your work once you run them: the generator itself refuses to write when the version in `plugin.json` has no note and no `skip` marker (step 3), and the drift test catches a changelog edited without regenerating (step 4). If you edit `CHANGELOG.md` and skip step 3 entirely, the test suite is what tells you.

## License

MIT — see `LICENSE`.

## Status

**v0.29.0.** The install path is verified in a throwaway directory, and the enforcement spine (state-machine ↔ hooks) is covered by an automated integration test — `tests/enforcement-spine.test.sh`, 503 assertions covering the full STANDARD + LIGHT lifecycle, gate ordering, review-staleness (including enforcement during a merge and under hostile git config), raw-mode commit detection, the Stop-hook stall-breaker, the AI-attribution block, the fail-open/fail-closed edges, per-worktree / subdirectory / nested-repo state resolution, the worktree-isolated-run resolution with `CLAUDE_PROJECT_DIR` pinned to the main checkout, the checkout-drift block + warning (`enforce-gates.sh` + `warn-checkout-drift.sh`), and the `check-version.sh --plain` per-run-check behavior — alongside 31 other suites, including `tests/enforce-gates-hygiene.test.sh` (139 assertions covering the commit-time diff-hygiene gate: non-ASCII, tab-bearing, pathspec-magic and option-shaped paths (including a file named `-`), a credential on a ++-prefixed line, an invalid-UTF-8 byte under a UTF-8 locale, the commit detector under a multi-line command padded past the pipe buffer (with a padded non-commit negative control), each blocking row, the `warn`-demotion pass-through, the index scan — including a staged secret whose file was deleted from the worktree — the fail-closed cases both symmetric and *asymmetric*, the `.gitattributes`/`diff.external` off-switches with a genuinely-binary negative control, **large** diffs above the pipe buffer in both the attribute-marked and plain shapes, every non-array shape of the override record, the override's pinning under tracked/untracked/index drift, the hook's own printed override snippet executed as-shipped from a path containing a space, and the ordinary diffs that trip the rename-blind scanner — two of the 139 are skipped where a mode-000 file is still readable, e.g. running as root). The *model-follows-the-prose* path is no longer untested either: Gate A/B and the orchestrator's phase-driving have driven many live `/auto-task` runs against real tasks, and the telemetry those runs record (see **Run telemetry**) is what several releases — including the Gate B bounding in 0.29.0 — were derived from. File issues on GitHub.
