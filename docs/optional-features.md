# Optional features

Everything here is off by default or conditional. A run that opts into none of it behaves exactly as it did before these features existed.

| Feature | Turned on by | Runs at |
|---|---|---|
| [Docs update at handover](#docs-update-at-handover-docs_update_mode) | `docs_update_mode` | Phase 5, before staging |
| [Release at handover](#release-at-handover-release_mode) | `release_mode` | Phase 9, the last phase |
| [Bot-comment review](#post-pr-bot-comment-review-opt-in) | `bot_review_autofix` | Phase 6, after the PR opens |
| [Visual PR proof](#visual-pr-proof-opt-in) | `visual_assets_enabled` | Phase 5, on UI-scoped runs |
| [Preview verification](#preview-verification-opt-in--auto-learn) | `has_preview_deployment`, or auto-learned | Phase 7, after the PR |
| [External change application](#external-change-application-phase-8) | Declared in the plan | Phase 8 |
| [Worktree space control](#worktree-space-control-auto-task-gc) | On by default (nudge only) | On demand |

Configuration keys for all of these live in [Settings](settings.md).

## Docs update at handover (`docs_update_mode`)

A run changes behavior; the docs that describe that behavior go stale. `docs_update_mode` decides what auto-task does about it. It's one of the five questions asked once per repo at first-run setup.

| Value | Behavior |
|---|---|
| `skip` *(default)* | Never run the docs step, never ask again. |
| `always` | Refresh the docs on every run, no prompt. |
| `ask` | Ask once per run — **but only when there is actually something to update.** |

The step runs in **Phase 5, before staging**, which is the design decision that keeps it cheap: the docs edits join the run's **single handover commit** rather than needing a second one, and they re-pass the same gates as the code — re-verify → re-`auto-task-code-review` → refreshed review hash, plus a Gate B re-run on STANDARD/HEAVY.

It composes the bundled **`auto-task-docs`** skill, which you can also run on its own (`/auto-task-docs`) whenever docs have drifted.

Three properties stop an "optional step" from becoming an annoyance:

- **Scoped narrowly.** It edits `README.md` and `docs/**` only. Never `CHANGELOG.md` (the release flow owns that), never `CLAUDE.md` or skill/agent instructions (those change *behavior*, not documentation), never code comments (they belong to the code diff). Staleness found outside that set is reported as a follow-up, not edited.
- **Staleness is resolved before the prompt.** The skill produces a `file:line`-cited report first, so `ask` never interrupts you about a change that does not exist. A repo with no `README.md` and no `docs/` directory, or docs that are already current, is a silent no-op in every mode.
- **It never blocks an unattended run.** Under `autonomy: autonomous` — or headless, where there is nobody to ask — `ask` applies the edits without yielding and records the decision in the run's assumptions ledger, surfaced at the merge gate. A clean docs re-review does not consume the fix-loop budget, since no finding drove it.

Every edit is evidence-backed (each traces to a `file:line` staleness finding tied to the diff) and minimal (it corrects what the change falsified and leaves the rest alone), so the docs portion of the commit stays trivially separable from the real change at review time.

## Release at handover (`release_mode`)

A run finishes and the work has landed — but cutting the release is still a separate session: bump the version, write the changelog entry, commit, tag. `release_mode` lets the run do that last mile.

It's a **quiet default-off opt-in** you set in the settings file:

```sh
bash hooks/settings.sh set release_mode ask
```

Deliberately *not* a first-run-setup question — most projects do not want a task runner touching their version numbers, so it doesn't spend one of the setup prompts or force a settings reset.

| Value | Behavior |
|---|---|
| `skip` *(default)* | Never run the release step, never ask. |
| `always` | Cut the release every run, applying the derived version bump with no prompt. |
| `ask` | Ask once per run — **but only when there is actually something to release.** |

It runs as **Phase 9, the last phase** — after the work has genuinely landed and after any external change has been applied, which is the point at which a version number means something. It composes the bundled **`auto-task-release`** skill, which you can also run on its own (`/auto-task-release`).

### It never pushes and never publishes

The commit and the annotated tag stay local. The step hands you the exact commands rather than running them:

```sh
git push origin HEAD && git push origin vX.Y.Z
```

That boundary is what makes the whole thing safe to automate. Because nothing left your machine, a release you don't like is undone completely:

```sh
git tag -d vX.Y.Z && git reset --hard HEAD~1
```

The step surfaces those commands, with their precondition (the release commit is still `HEAD` and the tree is clean), whenever it applied anything.

### What keeps it from being a liability

Five properties worth knowing, because they are what stop an automated release from being a liability:

- **The version bump is delegated, never guessed.** Only your project knows where its version lives — this plugin's spans `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and a generated notes artifact. So the step runs your `release_command` and never hand-edits a manifest. With no command configured it emits a paste-ready runbook and changes nothing, which is an honest fallback rather than a half-bumped repo. It also verifies the bump actually happened before tagging, so a command that silently no-ops cannot leave a changelog entry for a version that does not exist.
- **The bump level is derived *with its evidence*, then confirmed.** A `PLAN.md` breaking-change note or a `feat!:` marker gives major; a `feat` or new capability gives minor; everything else patch. The prompt shows you the level *and the signal that produced it*, so you can override it. In `always` mode — or when the run is autonomous or headless — the derived level is applied unattended and recorded in the assumptions ledger.
- **The release commit is gate-reviewed like any other.** The bump and changelog are new authored bytes, so the step re-runs verification, re-runs `auto-task-code-review` to a clean pass, refreshes the review hash, and re-runs Gate B on STANDARD/HEAVY before committing. No hook was weakened to let a release through — which is also why Phase 9 runs *before* the run is marked done, not after.
- **Anything but an explicit `direct` landing defers instead of releasing.** A `chore(release):` commit belongs on the default branch, not inside a PR awaiting review, so the step records `deferred-pr` and hands you the runbook to run after the merge. The check is deliberately written to fail *safe*: it tests the run's recorded landing for an explicit `direct`, so `landing_model: pr` defers — and so does a run whose landing was never recorded (anything started before that field existed) or holds an unexpected value. If you see `deferred-pr` on a project you think is `direct`, that is why. And a partial failure — a commit whose tag did not land, the state most easily mistaken for success — is reported as a partial failure with both the continuation and the unwind, never as done.
- **An interrupted release is handed to you, not auto-resumed.** This is a deliberate limit rather than a gap. Cutting a release rewrites git history, and an automated recovery that guesses wrong can re-cut a release you just unwound, or re-apply a bump you reverted. So if a session dies mid-release, the step records what it was doing and the next run *surfaces* that state — the version, the step it died at, the current `git log` / `git tag` / `git status`, and the exact undo commands — instead of trying to finish the job itself. Same for a partial failure or a failed re-gate: auto-task never auto-resumes, auto-retries, or auto-reverts a release. What it guarantees mechanically is the part that matters — **an interrupted release never silently re-cuts and never reports success.** The judgement call is yours.

## Post-PR bot-comment review (opt-in)

Set `bot_review_autofix: true` and `/auto-task` adds **Phase 6** after the PR opens.

It polls — bounded, default 10 minutes — for comments left by review bots: Cursor, CodeRabbit, Sourcery, GitHub Copilot review, and any `[bot]`-suffix or GitHub `type:Bot` account (extend via `bot_review_bots`). `hooks/pr-bot-comments.sh` merges the PR's issue comments, inline review threads, and review summaries into one de-duplicated set.

Triage is **conservative**: only high-confidence, in-scope findings that don't contradict a decision you already made are auto-applied. Each is routed through the same verify → `auto-task-code-review` → gate → commit → push loop as any other change, so every bot-fix commit is fully re-reviewed before it can land — the pre-commit gate is unchanged. Everything else is parked as a follow-up and reported.

It runs exactly one collection round, so it does not chase comments its own fix-push re-triggers. A fork-PR or protected-branch push failure is fail-open: parked, never a hard stop.

Off by default, because enabling it lets the pipeline push bot-derived fixes to your PR branch.

## Visual PR proof (opt-in)

### Verification (always on for UI changes)

For UI and visual changes, `/auto-task` verifies on **local dev first** — reusing a running dev server, or improvising a bounded, disposable render (Storybook, a test harness, a static build, a mock server) and mocking or seeding only what's needed to reach the *real* UI. It then re-checks on the preview when one exists.

A UI it can't reach even after improvising is recorded **INCONCLUSIVE**, never a proxied pass, and never a hard stop. Playwright sessions and any disposable render are closed when done.

### Embedded screenshots (opt-in)

Set `visual_assets_enabled: true` — off by default; `/auto-task` asks once per repo, only on UI-scoped runs — and the run also embeds a **before/after screenshot pair** in the PR.

Images are uploaded to **Cloudinary** via an **unsigned** upload preset, and it works **out of the box** using a bundled shared disposable account, so no setup is needed to try it. Point `cloudinary_cloud_name` and `cloudinary_upload_preset` at your own account (or the `AUTO_TASK_CLOUDINARY_DEFAULT_*` env vars) for real or heavy use — the shared cloud is a common free-tier pool.

The delivery URL renders **inline for public and private projects alike**, because GitHub proxies external images through its Camo cache. It needs no `gh`, no repo, and no API secret, so it works from any checkout including a fork PR.

**Two caveats if you use your own account:**

- An unsigned preset is **world-writable**. Restrict yours — allowed formats and size, a fixed folder, moderation.
- Unsigned upload **cannot delete**, so screenshots **persist**. The free tier is ample for KB-scale crops.

Embedding is best-effort presentation. If the upload returns no `secure_url` — or the keys were overridden empty — the PR just carries a local-artifact and preview note. It never blocks the run.

## Preview verification (opt-in + auto-learn)

When a push happened and a preview is expected, `/auto-task` adds a final **Phase 7** after the PR, and after any Phase-6 bot fixes.

It waits for the preview deployment (bounded, configurable, default 30 minutes), resolves the preview URL, re-runs the URL-checkable Acceptance Criteria against the live preview plus a smoke check (loads, no console errors), and records a **final verdict** — `PASS` / `FAIL` / `INCONCLUSIVE` — in `STATE.json`, `CONTEXT.md`, and optionally a PR comment.

URL resolution tries, in order:

1. `gh` deployment statuses bound to the pushed commit
2. The PR's deploy-bot comment
3. The configured `preview_url`

**Outcomes:**

- A **timeout** records `pending` and asks you to resume.
- A **`FAIL`** surfaces with evidence. The commit already shipped, so it recommends a follow-up fix rather than auto-looping.
- An **auth-protected** preview (401/403) is reported as `INCONCLUSIVE` with a bypass-token hint, never masked.

### Auto-learn (zero config)

You don't have to set `has_preview_deployment`. Left unset, a post-PR run detects whether a preview deployment exists and **persists only a positive**: found → `true`, verified every subsequent run.

If none is found, **nothing is persisted.** The setting stays unset and the next post-PR run re-attempts detection, so a slow deploy bot or a degraded check (no `gh`, no auth, no PR) is a transient miss, never a permanent wrong `false`.

The tradeoff is a bounded re-check each post-PR run on a genuine no-preview repo. Set `has_preview_deployment: false` explicitly to skip with no polling. An explicit value is always honored and never overwritten; `preview_autodetect: false` turns auto-learn off entirely.

## External change application (Phase 8)

Some tasks aren't finished when the code ships — they also need a change in an **external system**: a CMS edit, a feature-flag toggle, a data migration run against live, a third-party API config. Shipping the script that *would* make that change is not the task being done.

So `/auto-task` treats these as first-class **external actions**.

**Declared up front.** In Phase 1 the plan names each external action and adds an Acceptance-Criteria row for it (`Gate = external`) — the target system, how to apply it, and how to verify it took. Detecting external side effects and marking the task not-done are **always-on**, like the honesty floor, never gated by a setting.

**Applied and verified in Phase 8**, after preview verification. (Phase 9, the opt-in release step, is the last phase.) The `external_actions_mode` setting decides how — see [Settings → External actions](settings.md#external-actions-phase-8).

Credentials are provided at the prompt or via an environment or secret-file reference. They are **never stored** in settings, state, the trace, or artifacts, and secret-shaped tokens are redacted from captured output.

**Not done until applied.** A task with an un-applied external change **never reaches `done`**. It stays in an explicit `awaiting-external` state — or `declared`, if the push was held — and the PR body, run summary, `CONTEXT.md`, and trace all carry a prominent banner:

> ⚠ TASK NOT DONE until external changes applied

Only once the change is applied *and* its post-apply verification passes does the run flip to `done`; Phase 8 then replaces the banner with an "applied + verified" confirmation.

Partial multi-action failures stop and surface with per-action rollback steps. Resuming skips already-applied actions, so an irreversible step never runs twice.

**Backward-compatible.** A code-only task declares no external actions, Phase 8 is a no-op, and the run completes exactly as before.

## Worktree space control (`/auto-task-gc`)

Each `/auto-task` run creates a git worktree under `.claude/worktrees/<type>-<slug>` and **keeps it**, so its branch and `.auto-task/<branch>/` history stay available. Because every worktree carries a full working tree — often a multi-GB `node_modules` — they accumulate. A busy repo can reach tens of GB.

Two pieces keep that in check, and **nothing deletes without you asking**.

### The SessionStart nudge

`hooks/suggest-cleanup.sh`, on by default. Cheap and local-only — no `du`, no network — and throttled once per `worktree_cleanup_throttle_hours`, **per clone**.

When at least one worktree looks reclaimable — **merged**, or **clean and stale** past its per-type threshold — it prints a one-line suggestion to run `/auto-task-gc`. It never deletes and never blocks. Silence it with `worktree_cleanup_nudge: false`.

### `/auto-task-gc`

The on-demand tool:

```sh
/auto-task-gc                 # report only, read-only
/auto-task-gc --prune         # preview the removal plan
/auto-task-gc --prune --yes   # perform it, after you confirm
/auto-task-gc --all           # widen to every clean worktree, regardless of merge/age
```

The report lists each worktree's size (`du`), age, type, and merge status — using local ancestry **and** `gh`, so squash-merged PRs are detected.

**Removal preserves the branch ref.** Committed work is recoverable with `git worktree add <path> <branch>`. The matching `.auto-task/<branch>/` is pruned alongside.

Dirty worktrees are kept unless `worktree_cleanup_prune_dirty: true`, in which case their work is WIP-committed first. The current and main worktrees are never removed.

> **One caveat.** Removing a worktree deletes its directory, so **gitignored** files inside it go too. That's the point for `node_modules`, but a local `.env` or other ignored scratch is removed, and is *not* captured by the WIP-commit. The report lists exactly which worktrees will be removed — run it first.

Retention is **per branch type**, so short-lived `chore`/`deps`/`docs`/`cleanup` work is reclaimed sooner than `feat`/`refactor`. Every threshold ships as a default and is overridable:

```sh
bash hooks/settings.sh set worktree_stale_days_feat 45
```

See [Settings → Worktree retention](settings.md#worktree-retention) for the full list.

### Pruning history without the worktree

Per-branch folders under `.auto-task/` never auto-prune during a run. `/auto-task-gc` removes reclaimable worktrees and prunes their matching `.auto-task/<branch>/` in one pass.

For a `.auto-task/<branch>/` folder that has no worktree, remove it by hand:

```sh
rm -rf .auto-task/<old-branch>/
```

Nothing in the plugin depends on stale folders being present.
