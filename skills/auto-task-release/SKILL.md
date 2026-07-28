---
name: auto-task-release
description: Cut a release for work that has already landed — decide the version bump, write the changelog entry, run the project's release command, then commit and tag it locally. Use when asked to "cut a release", "release this", "bump the version", "tag a release", or as the optional release step of an `/auto-task` run.
license: MIT
metadata:
  author: ai-workflow
  version: "1.0"
---

# Release

Turn work that is already committed into a release: a version bump, a changelog entry, one `chore(release): vX.Y.Z` commit, and one annotated tag. **Local only** — this skill never pushes and never publishes.

> **Working directory.** When invoked inside an `/auto-task` run, the run's plan, state, and history live under the gitignored `.auto-task/<branch>/` root (`<branch>` = `git branch --show-current`). Read the paths the orchestrator hands you. **Never commit anything under `.auto-task/`.**

> **Caller note (do not strip):** When invoked from an orchestration protocol (e.g. `/auto-task` Phase 9), the release plan and the applied-release summary are **INPUT returned to the caller**, not an end-of-turn. Do not address the user, do not ask whether to proceed, and do not suggest next commands — the caller owns the `ask`-mode prompt (and decides whether one is warranted at all), the re-gate that precedes the commit, and the terminal state. A "Report before releasing" table, a "no-op" result, or a closing summary line is **formatting, not a stop**. When a human runs `/auto-task-release` directly, the report is for them and the standalone flow below applies as written.

> **Read-before-review contract.** If `.auto-task/<branch>/` exists for the current branch, read it before proposing a bump, so the release you cut describes what the run actually did: **`CONTEXT.md`** (if present) for the run summary + Human choices, **`TRACE.md`** for prior passes on this branch, and **`PLAN.md`** for the Requirements + Acceptance Criteria that state what the change promises a user — those are the sentences a changelog entry is written from. **TRACE appends are suppressed under orchestration** — the `/auto-task` caller writes the trace entry for Phase 9 itself (read, but do not append); when run standalone, append your own entry with the operation slug `release:standalone`.

## Scope (NON-NEGOTIABLE)

**In scope — the only things this skill may change:**

- `CHANGELOG.md` — the release entry. (This is the file the `auto-task-docs` skill is explicitly forbidden to touch, because the release flow owns it. The two skills are complements, not overlaps.)
- **Version manifests, but only ever via the project's `release_command`** — never by hand. A repo can keep its version in two or five places (this plugin keeps it in `.claude-plugin/plugin.json` *and* `.claude-plugin/marketplace.json`, plus a generated `release-notes.json`), and only the project knows the full set. When no `release_command` is configured, you do not guess: you emit a runbook (step 3).
- One `chore(release): vX.Y.Z` commit and one **annotated** tag `vX.Y.Z`, both local.

**Explicitly OUT of scope — never do these, even when they look like the obvious next step:**

| Not a target | Why |
|---|---|
| `git push` (any form, incl. `--tags`) | Publishing the release is the user's call, not a step's. Keeping the tag local is exactly what makes the unwind total (step 6). |
| `npm`/`pnpm`/`yarn publish`, `gh release create`, any deploy | Irreversible and externally visible. `guard-dangerous-ops.sh` blocks these at command position anyway, which mechanically reinforces the boundary. |
| `README.md`, `docs/**`, code comments | Documentation belongs to the `auto-task-docs` skill. A release step editing prose makes the release commit unreviewable. |
| Source, tests, config, dependency manifests | A release records work; it does not change it. If cutting the release reveals a bug, report it — do not fix it here. |
| History beyond the commit you just made | Never rebase, amend someone else's commit, or move an existing tag. A wrong release is undone forward (step 6), never by rewriting shared history. |

**Where the never-push/never-publish boundary binds, stated honestly.** It **binds auto-task's own actions** — this skill will not run those verbs. It cannot bind a project's own `release_command`: that script runs under the user's authority and may internally push, publish, or deploy, and no guard can see inside it (`guard-dangerous-ops.sh` matches at command position, so a `npm publish` *inside* a delegated script escapes it). That is the user's configuration and the user's call — but it must never be a *surprise*, so the `report-only` pass must **surface what that command will do** before it is ever run (step 3).

## Process

### 0. Read the invocation mode (REQUIRED — it decides whether you may change anything)

The caller passes one of two modes. If none is stated, assume **`report-only`** — the safe default, because a release is the one thing a caller cannot quietly undo for the user.

| Mode | What you do | What you must NOT do |
|---|---|---|
| **`report-only`** | Steps 1-3: derive the bump, draft the entry, surface what the release command will do, emit the report, then **STOP and return**. | Do not edit a file, do not run the release command, do not commit, do not tag. Not even the "obviously correct" patch bump. |
| **`apply`** | If the caller handed you an **approved release plan** (version + bump level + entry text), that plan is authoritative AND complete — apply exactly it and skip re-derivation. **This makes `apply` idempotent, which callers rely on for resume:** re-confirm each step's precondition before doing it (entry already in `CHANGELOG.md` → skip; the bump already applied → skip; and, **standalone only**, a tag already at the intended commit → skip) rather than re-editing, re-running, or reporting a failure, so re-invoking on a partially-applied release completes it exactly once. Under orchestration the commit/tag preconditions are the caller's, since those substeps are its job. Only when no plan was handed over do you run steps 1-3 yourself first. Then step 4 — whose last two substeps (commit, tag) are **caller-owned under orchestration**; see the boundary below. | Do not change the version the caller approved, do not widen the changelog entry beyond the approved text, and do not push or publish. |

**Who commits — the one thing to get right (WARNING: getting this backwards deadlocks an `/auto-task` run).** Substeps 4.1-4.3 (changelog entry → `release_command` → verify the bump) are **always yours**. Substeps 4.4-4.5 (the commit and the tag) depend on who invoked you:

| Invoked by | Substeps 4.4-4.5 (commit + tag) |
|---|---|
| **An orchestration protocol** (`/auto-task` Phase 9) | **STOP after 4.3 and return.** Do **not** commit and do **not** tag. The caller owns them, and it must first re-run its gates and refresh `gates.code_review.reviewed_diff_sha` — the bump you just wrote is new authored bytes, so committing before that refresh is **hard-blocked by `enforce-gates.sh`** (its staleness check compares `hash(git diff <base>)` against the last reviewed hash). Committing here does not just violate a convention; it fails, leaving a bump on disk and no release. The caller also commits via the `auto-task-commit` skill, per its own "commit only with `auto-task-commit`" rule. |
| **A human directly** (`/auto-task-release`) | Perform them yourself — 4.4 then 4.5 — since there is no caller to do it. |

If you cannot tell which applies, assume **orchestration** and stop after 4.3: a missing commit is a one-command fix for the caller, while a premature one is a blocked, half-applied release.

`/auto-task` uses both: Phase 9 invokes you in `report-only` to decide whether a prompt is even warranted, then — only on `always`, or on the user's yes in `ask` mode — re-invokes you in `apply`. Editing during a `report-only` call breaks that contract: the caller would prompt about a release that is already cut, and a "no" answer could not be honoured.

### 1. Establish the current version and what changed

- **Current version.** Read it from wherever the project keeps it — resolve in this order and stop at the first hit: the `release_command`'s own source if it names one, `.claude-plugin/plugin.json`, `package.json`, `pyproject.toml`, `Cargo.toml`, `VERSION`, then the newest `## [X.Y.Z]` heading in `CHANGELOG.md`. Reading is always allowed; **editing** these is not (only the `release_command` writes them).
- **Cross-check the tags.** `git tag --list 'v*' --sort=-v:refname | head -5`. A manifest version that is *behind* the newest tag means someone released without bumping, or bumped without tagging — report it rather than papering over it.
- **What changed.** Take the range from the caller. Inside an `/auto-task` run that is the run's landed work (`git log <base>..HEAD`, plus `git diff <base>`); standalone, default to `git log <newest-tag>..HEAD`. Pair it with the untracked set (`git status --porcelain --untracked-files=all | grep '^??'`) — a brand-new user-facing file is exactly the kind of change a changelog must mention and a plain diff hides.
- If `.auto-task/<branch>/PLAN.md` exists, read its `## Requirements` and `## Acceptance Criteria`: they state what the change **promises the user**, which is what a changelog entry describes.

### 2. Derive the bump level — **derived-then-confirmed**, never silently applied

Compute a proposal, and treat it as a *proposal*: the caller shows it to the user for confirmation (or applies it unattended only in `always` mode / the documented degrade). Derivation rules, first match wins:

| Signal | Bump |
|---|---|
| A breaking change declared in `PLAN.md`, a `BREAKING CHANGE:` trailer, or a `!` conventional-commit marker (`feat!:`) | **major** |
| A new user-facing capability: branch type `feat/`, a `feat:` commit, a new command/skill/setting/flag/route | **minor** |
| Everything else: `fix/`, `chore/`, `deps/`, `docs/`, `refactor/`, `cleanup/` | **patch** |

Pre-1.0 caveat: when the current major is `0`, say so in the report — many projects treat `0.x` minor bumps as their breaking channel, and the user may want minor where the table says major. State the proposal, the signal that produced it, and the resulting `vX.Y.Z`; never present a bump without the evidence behind it.

### 3. Report before releasing

Emit a short report, then stop or continue per the mode. It contains:

- **Version:** `<current>` → `<proposed>` (**<major|minor|patch>**), and the signal that decided it.
- **Changelog entry:** the drafted `## [X.Y.Z]` block, in the project's existing format (match the neighbouring entries' heading depth, section names, and lead-paragraph convention — many projects, including this one, turn that lead paragraph into the user-visible release note).
- **Release command:** the resolved `release_command`, verbatim, **and what it will do** — read the script and say plainly whether it (a) **commits or tags by itself** (the default for `npm version`, `standard-version`, `semantic-release`, `cargo-release`), or (b) pushes, publishes, deploys, or writes outside the repo. Both matter and for different reasons: (b) reaches further than this skill promises to, and (a) breaks the orchestrated hand-off outright — see the "commits or tags by itself" row in step 5. This is the one place the user learns either fact before anything runs.
- **Tag:** the exact `git tag -a vX.Y.Z` that will be created.
- **Blockers:** anything from step 5's edge list that is already true (tag exists, no changelog, dirty tree).

Then:

- **Nothing to release → stop and report a no-op.** No user-observable change since the last tag, or the version is already released, is a correct and *good* outcome. Do not manufacture a release to look useful.
- **`release_command` unset → emit a runbook, run nothing.** The report becomes paste-ready steps: bump these files, add this entry, commit as `chore(release): vX.Y.Z`, `git tag -a vX.Y.Z -m …`. This is the honest fallback — guessing a multi-file version bump is how a repo ends up half-bumped. Report it as a runbook outcome, not a failure.
- **In `report-only` mode, STOP HERE.** The report is your complete return value — do **not** continue to step 4, and leave the working tree and refs byte-for-byte unchanged.

### 4. Apply the release

**`apply` mode only** — if you arrived here from a `report-only` invocation, you have already gone too far; stop and return the report.

In this order, each step conditional on the previous having succeeded, and each skipped when already done (idempotence, step 0):

1. **Write the changelog entry** at the top of the release list, in the project's format, using the approved text. Do not reword neighbouring entries.
2. **Run the `release_command`.** Bound it; capture stdout/stderr and the exit code. A **non-zero exit is a hard stop** — do not commit, do not tag; report the failed outcome with the transcript and the current (unchanged) state. Many release commands are themselves validators (this repo's regenerates a notes artifact and *refuses to write* when the version has no entry), so a failure usually means the entry or the bump is wrong, not that the command is broken.
3. **Verify the bump actually happened** — re-read the version sources from step 1 and confirm they now agree on the new version. A command that silently no-ops leaves a changelog entry for a version that does not exist; catch it here, not after tagging.
4. **Commit** as exactly `chore(release): vX.Y.Z`. Per the repo's global rule, add **no** AI-attribution trailer (`Co-Authored-By: Claude`, `🤖 Generated with …`) to the message. **Under orchestration this substep is NOT yours — stop after substep 3 and return** (see "Who commits" in step 0).
5. **Tag**, annotated, at that commit: `git tag -a vX.Y.Z -m "vX.Y.Z"`. Annotated, not lightweight — a release tag carries a date and an author. **Also caller-owned under orchestration.**

**Never `git push` and never publish**, in any mode. Report the exact commands the user would run (`git push origin HEAD && git push origin vX.Y.Z`, plus their publish step if any) and hand them over.

### 5. Edge cases and partial failure — each a named outcome, never a silent half-release

| Situation | What to do |
|---|---|
| **Tag `vX.Y.Z` already exists** (locally or on a remote ref) | STOP before step 4. Never move or delete an existing tag — it may already be public. Report it: the version is taken, so either the release already happened or the bump proposal is wrong. |
| **`CHANGELOG.md` absent, or has no recognizable insertion point** | Do not invent a file structure mid-release. If absent, report it and offer the entry text for the user to place (a runbook outcome). If present but unparseable (no `## [X.Y.Z]` headings to insert above), report the ambiguity rather than guessing a location. |
| **Release command failed** (non-zero exit) | Hard stop, nothing committed, nothing tagged. Report the transcript. The tree may carry a partial bump the command wrote before failing — say so explicitly and hand over `git checkout -- <files>` for the files it touched. |
| **Commit landed but the tag failed** | The release is half-cut, and this is the state most likely to be misread as success. Report it as a *partial failure*, naming the commit SHA, and hand over both continuations: tag it (`git tag -a vX.Y.Z -m "vX.Y.Z" <sha>`) or unwind it (see below). |
| **Not on the default branch** (a feature branch, or a branch with an open PR) | Report it before step 4: a `chore(release): vX.Y.Z` commit belongs on the default branch, so cutting it here would bury the release inside a branch that may never merge — or merge much later, under a version number chosen today. Under `/auto-task` this is decided upstream by the orchestrator (`landing_model: pr` → the release is **deferred** with status `deferred-pr` and a runbook for after the merge, so Phase 9 never invokes `apply` on a PR branch). Standalone, say so and let the user confirm they really mean to release from this branch. |
| **The `release_command` commits or tags by itself** (`npm version`, `standard-version`, `semantic-release`, `cargo-release` all do by default) | **Detect this in `report-only` (step 3) and say so, because it breaks the orchestrated contract.** The design assumes the command only *writes files*: the caller commits and tags after its re-gate. A command that commits internally lands an authored commit that never passes through a Bash-tool `git commit`, so `enforce-gates.sh` never sees it — an un-gated commit, outside the single-commit rule — and it then wedges the caller's step 8, whose commit precondition compares `git log -1 --format=%s` against `chore(release): vX.Y.Z` and finds the command's own message instead. **Under orchestration:** if the report shows the command commits/tags, do NOT run it — report a blocker and tell the user to switch to the file-only form (`npm version <level> --no-git-tag-version`, `standard-version --skip.commit --skip.tag`, `cargo-release --no-commit --no-tag`) or point `release_command` at a wrapper that only writes the manifests. **Standalone** it is harmless: you own the commit and tag anyway, so just note that the command already did them and skip substeps 4.4-4.5. |
| **Dirty tree with unrelated changes** | Report it before step 4. A release commit must contain only the bump and the changelog; sweeping in unrelated work makes it unreviewable — and it invalidates the unwind below. |

### 6. Unwind (surface it whenever anything was applied)

Because nothing is pushed and nothing is published, a release this skill cut is **completely reversible locally**. Whenever you report an applied or partially-applied release, hand over the undo:

- Remove the tag: `git tag -d vX.Y.Z`
- Drop the release commit: `git reset --hard HEAD~1`

**State the precondition with them, every time:** `git reset --hard HEAD~1` is only safe while the release commit is still `HEAD` and the tree is clean — it discards uncommitted work and is the wrong command if anything landed after the release. When either is untrue, hand over `git revert <release-sha>` instead, which is always safe.

### 7. Verify

**Under orchestration you stopped after substep 4.3, so verify only what you did:** the changelog entry reads correctly, the `release_command` exited 0, and every version source now agrees on the new version. The commit/tag confirmations below belong to whoever performed them — the caller, which re-verifies them itself. Then report the bump, the files touched, and the unwind for the part you applied (`git checkout -- <files>` restores an uncommitted bump).

**Standalone (you performed the commit and tag):**

- Confirm `git log -1 --format=%s` is exactly `chore(release): vX.Y.Z`.
- Confirm `git tag --list vX.Y.Z` returns the tag and `git cat-file -t vX.Y.Z` is `tag` (annotated, not a lightweight ref to a commit).
- Confirm `git show --stat HEAD` touches only the changelog and version manifests — nothing else.
- Confirm the working tree is clean, and confirm **nothing was pushed** by looking for *positive evidence that it was* rather than for evidence that it was not — the absence of an upstream is not the absence of a push, and a branch with no tracking ref cannot be "in sync" with one. So: the release is local unless `git ls-remote --tags origin "refs/tags/vX.Y.Z"` returns a ref, or the branch has an upstream (`git rev-parse --abbrev-ref "@{upstream}"` succeeds) that already contains the release commit (`git merge-base --is-ancestor <release-sha> "@{upstream}"`). **Never conclude "pushed" from an inconclusive check** — if the remote is unreachable, say the push state could not be verified rather than picking either answer.
- Report the version, the commit SHA, the tag, the files the release touched, the push/publish commands you did **not** run, and the unwind from step 6.

## Rules

- **Local only. Never push, never publish, never deploy.** Not with `--follow-tags`, not "since it's already tagged". The user pushes.
- **Under orchestration, never commit and never tag — the caller owns git state.** This is the release analogue of the `auto-task-docs` rule, and it is load-bearing rather than stylistic: the caller must refresh its review hash before the commit, so committing here is blocked outright by `enforce-gates.sh` and leaves a half-applied release. Standalone, you do commit and tag (step 0's "Who commits" table).
- **Never hand-edit a version manifest.** Only the project's `release_command` writes versions; with none configured, emit a runbook. Guessing the file set is how a repo ends up half-bumped.
- **Respect the invocation mode (step 0).** `report-only` means zero file modifications, zero commands run, zero refs created. This is the one rule whose violation the caller cannot detect before it has already prompted the user.
- **An approved release plan is a ceiling, not a starting point.** In `apply` mode with a handed-over plan, cut exactly that version with exactly that entry. Re-deriving a different bump silently releases something the user never approved.
- **Evidence or silence.** Every changelog claim traces to a commit, a diff, or a `PLAN.md` requirement. Never document intent, a roadmap, or work the range does not contain.
- **A no-op is a valid result.** "Nothing user-observable since the last tag" is a correct outcome; never cut a release to justify the invocation.
- **Never rewrite or move shared history.** No amend of anyone else's commit, no moving an existing tag, no rebase. A wrong release is undone forward.
- **Report a partial failure as a partial failure.** A commit without its tag is not a release. Name the state, hand over both the continuation and the unwind, and never describe it as done.
- **The release is separable.** The commit contains the bump and the changelog and nothing else — that is what lets a reviewer read it in seconds and what makes the unwind a single `reset`.
