---
name: auto-task-docs
description: Refresh user-facing docs that a code change made stale. Use when asked to "update the docs", "docs are stale", "refresh the README", "sync the docs with the code", or as the optional docs-update step of an `/auto-task` run.
license: MIT
metadata:
  author: ai-workflow
  version: "1.0"
---

# Docs update

Bring user-facing documentation back in line with a change that has already been made. Read-only on the code — this skill edits **documentation, never behavior**.

> **Working directory.** When invoked inside an `/auto-task` run, the run's plan, state, and history live under the gitignored `.auto-task/<branch>/` root (`<branch>` = `git branch --show-current`). Read the paths the orchestrator hands you. **Never commit anything under `.auto-task/`**, and never commit at all — the caller owns commits.

> **Caller note (do not strip):** When invoked from an orchestration protocol (e.g. `/auto-task` Phase 5 step 1b), the staleness report and the applied-edit summary are **INPUT returned to the caller**, not an end-of-turn. Do not address the user, do not ask whether to apply the edits, and do not suggest next commands — the caller owns the `ask`-mode prompt (and decides whether one is warranted at all), the re-verify/re-review that follows, and the commit. A "Report before editing" table, a "no-op" result, or a closing summary line is **formatting, not a stop**. When a human runs `/auto-task-docs` directly, the report is for them and the standalone flow below applies as written.

> **Read-before-review contract.** If `.auto-task/<branch>/` exists for the current branch, read it before proposing any edit, so the docs you write match decisions already settled: **`CONTEXT.md`** (if present) for the run summary + Human choices, **`TRACE.md`** for prior passes on this branch, and **`PLAN.md`** for the Requirements + Acceptance Criteria that state what the change promises a user. Never document behavior that contradicts a recorded Human choice. **TRACE appends are suppressed under orchestration** — the `/auto-task` caller writes the trace entry for step 1b itself (read, but do not append); when run standalone, append your own entry with the operation slug `docs:standalone`.

## Scope (NON-NEGOTIABLE)

**In scope — the only files this skill may edit:**

- `README.md` at the repo root.
- Everything under `docs/**`.

**Explicitly OUT of scope — never edit these, even when they look stale:**

| Not a target | Why |
|---|---|
| `CHANGELOG.md` | Owned by the release flow, which writes it alongside the version bump. A docs step touching it would collide with, or pre-empt, a release commit. |
| `CLAUDE.md` (any level) | Instructions to the agent, not user documentation. Editing it changes how future runs behave — that is a behavior change wearing a docs costume. |
| Code comments, docstrings, JSDoc | They live in source files. Editing them puts a docs step inside the code diff, where it is indistinguishable from a logic change at review time. |
| Skill / agent instruction files | Same reason as `CLAUDE.md`. |
| Anything generated | Regenerate it from its source instead; hand-editing generated output is undone by the next build. |

If a genuinely stale doc lies outside the in-scope set, do **not** edit it — report it as a follow-up. The narrow scope is the point: it makes the docs step's diff trivially reviewable and impossible to confuse with the change it documents.

## Process

### 0. Read the invocation mode (REQUIRED — it decides whether you may edit)

The caller passes one of two modes. If none is stated, assume **`report-only`** — the safe default, because applying an unrequested edit is the one mistake this skill cannot undo for its caller.

| Mode | What you do | What you must NOT do |
|---|---|---|
| **`report-only`** | Steps 1-3: find the staleness, emit the report, then **STOP and return**. | Do not edit a single file. Not even an "obviously correct" one. |
| **`apply`** | If the caller handed you an **approved finding set**, that set is authoritative AND complete — apply exactly it (re-confirm each `file:line` still reads as described, then edit) and skip re-derivation. **This makes `apply` idempotent, which callers rely on for resume:** a finding whose text no longer reads as described has already been applied — skip it silently rather than re-editing or reporting a failure, so re-invoking on a partially-applied set completes it exactly once. Only when no set was handed over do you run steps 1-3 yourself first. Then verify (step 5). | Do not add, widen, or "while I'm here" any finding beyond the approved set — not even a real one you spot in passing. Report those as follow-ups instead. |

`/auto-task` uses both: Phase 5 step 1b invokes you in `report-only` to decide whether a prompt is even warranted, then — only on `always`, or on the user's yes in `ask` mode — re-invokes you in `apply`. Editing during a `report-only` call breaks that contract: the caller would prompt about changes that are already on disk, and a "no" answer could not be honoured.

### 1. Establish what changed

- Take the diff from the caller. Inside an `/auto-task` run that is `git diff <base>` (the run's accumulated, uncommitted work — `state.base` is the fork point). Standalone, default to `git diff` plus `git diff --cached`, or the range the user names.
- **A plain diff HIDES new files, which are the changes most likely to need docs.** `git diff` shows nothing for an untracked path, so a brand-new command, skill, script, or module — exactly the kind of net-new user-facing surface that belongs in the README — is invisible in it. Always pair the diff with the untracked set: `git status --porcelain --untracked-files=all | grep '^??'`, and read those files directly. (Concretely: the run that introduced *this* skill added two untracked files, and neither appeared in its own `git diff <base>`.) Without this, the staleness class "a new user-facing capability with no documentation at all" below is unreachable and the step reports "already current" on the very gap it exists to catch.
- If a plan exists at `.auto-task/<branch>/PLAN.md`, read its `## Requirements` and `## Acceptance Criteria` — they state what the change *promises the user*, which is exactly what documentation is supposed to describe.
- Build a short list of **user-observable** changes: new or removed settings/flags, new commands or skills, changed defaults, changed CLI/API surface, new or removed phases/steps, changed install or setup instructions, renamed concepts. Ignore pure internals (refactors, test-only changes, private helpers) — they are invisible to a reader of the docs and must not trigger doc churn.

### 2. Find the staleness

For each user-observable change, search the in-scope docs for text that the change **falsifies**:

- A documented default that no longer matches the code.
- A count or enumeration that is now wrong ("four questions", "six skills", "three modes").
- A named setting, command, flag, or file that was renamed or removed.
- A version-pinned statement that has been overtaken ("as of 0.22 …").
- A described behavior or sequence the change altered.
- A new user-facing capability with no documentation at all.

Grep for the concrete identifiers involved (setting keys, command names, file paths) rather than reading whole documents — the identifier is what ties code to prose. **Cite each finding as `file:line`.** A staleness claim without a line reference is a guess, and a guess is not a reason to edit someone's docs.

### 3. Report before editing

Emit a short table — one row per finding: `file:line` · what it says now · why the change falsifies it · the proposed edit. Then:

- **Nothing found → stop here and report a no-op.** "The docs are already current" is a correct, common, and *good* outcome. Do not manufacture edits to look useful, do not reword prose you merely dislike, and do not reformat. An empty finding list is the whole result.
- **No in-scope targets exist** (no `README.md`, no `docs/` directory) → also a no-op. Report it plainly.
- When the caller wants approval before edits (the `/auto-task` `ask` mode), this report **is** what the user is shown. Resolving staleness *before* asking is deliberate: it means the user is never prompted about a change that does not exist.
- **In `report-only` mode, STOP HERE.** The report is your complete return value — do **not** continue to step 4, and leave the working tree byte-for-byte unchanged. Only a subsequent `apply` invocation may edit. (A `report-only` call that edits leaves the caller unable to honour a "no", and — inside `/auto-task` — leaves unstaged edits that trip the review-staleness gate and dead-end the run.)

### 4. Apply the minimal edit

**`apply` mode only** — if you arrived here from a `report-only` invocation, you have already gone too far; stop and return the report.

For each confirmed finding:

- Change **only** what the code change falsified. Correct the count, the default, the name, the described behavior. Do not rewrite surrounding prose, restructure sections, fix unrelated typos, or "improve" wording — every unrelated line inflates the diff a reviewer must separate from the real change.
- Match the document's existing voice, heading depth, and table shape. A new settings row goes in the existing settings table in the same column order; a new feature section matches its siblings' heading level and length.
- Add documentation for a new user-facing capability at the same level of detail as comparable existing entries — no more.
- Keep every factual claim verifiable against the code you just read. Never document intent, a roadmap, or behavior the diff does not implement.

### 5. Verify

- Re-read each edited region and confirm the statement is now true of the code.
- Confirm no out-of-scope file was touched: `git diff --name-only` must list only `README.md` and `docs/**` paths *beyond* whatever the caller's own change already touched.
- Check the mechanics: valid Markdown, closed fences, intact tables, and no broken relative links introduced by a rename.
- Report the final list of edited files with a one-line summary each, plus any out-of-scope staleness parked as a follow-up.

## Rules

- **Docs only.** Never edit source, config, tests, or dependency manifests. If documenting a change reveals a *code* bug, report it — do not fix it here.
- **Never commit, never stage, never push.** The caller owns git state. Inside `/auto-task` the docs edits join that run's single handover commit. One exception, and only in `apply` mode: if you **create** a new doc file, run `git add -N <path>` (intent-to-add) so it becomes visible to `git diff` — otherwise an untracked file is invisible to the caller's review-staleness hash and would ship un-reviewed. Intent-to-add stages no content; the caller still owns the real staging.
- **Respect the invocation mode (step 0).** `report-only` means zero file modifications. This is the one rule whose violation the caller cannot detect before it has already prompted the user.
- **An approved set is a ceiling, not a starting point.** In `apply` mode with a handed-over finding set, edit exactly those findings. Re-deriving and editing a superset silently edits lines the user never saw — which defeats the entire purpose of `ask` mode, whose only job is consent. A finding you would have added goes in the follow-up list, not the diff.
- **Evidence or silence.** Every edit traces to a `file:line` staleness finding tied to a specific change in the diff. No cite, no edit.
- **A no-op is a valid result.** Report "already current" and stop; never edit to justify the invocation.
- **Minimal diff.** Correct what is false; leave everything else exactly as it is.
- **No scope creep into behavior.** Documentation describes what the code does. If prose and code disagree, the code is the truth and the prose gets corrected — never the reverse.
