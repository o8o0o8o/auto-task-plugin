---
name: auto-task-verify
description: Verify that planned tasks are actually implemented. Use when asked to "verify implementation", "check the plan", "validate changes", "are all tasks done", or "run verification".
license: MIT
metadata:
  author: ai-workflow
  version: "1.0"
---

# Verify

Post-implementation verification. Checks that each planned task is actually implemented and runs available quality checks.

> **Working directory.** Plan, state, and run history live under the gitignored `.auto-task/<branch>/` root, where `<branch>` is the current git branch (`git branch --show-current`; if detached or not in a repo, fall back to a flat `.auto-task/`). When invoked inside an `/auto-task` run, use the exact path the orchestrator references. **Never commit anything under `.auto-task/`.**

> **Caller note (do not strip):** When invoked from an orchestration protocol (e.g. `/auto-task` Phase 3), the verification report is **INPUT returned to the caller**, not an end-of-turn. Do not address the user or suggest next commands (`/implement`, `/fix`) — the caller routes on the result (pass → advance; fail → fix-loop). When a human runs `/auto-task-verify` directly, the suggestions below are appropriate.

> **Read-before-review contract.** If `.auto-task/<branch>/` exists for the current branch (`git branch --show-current`), read its history before verifying so you don't contradict settled decisions or miss a prior pass's open issue:
> 1. **`CONTEXT.md`** (if present) — the run summary + Human choices; don't report a regression against a behavior the user deliberately chose.
> 2. **`TRACE.md`** (if present) — prior verification/review outcomes; note (don't repeat) issues already recorded, and surface anything an earlier pass flagged but left open.
> 3. **`STATE.json`** (if needed) — gates, effort tier, parked follow-ups.
> 4. **On completion, append a `TRACE.md` entry** (operation slug `verify:standalone`) in the block format defined in the auto-task orchestrator SKILL.md → "Persistent history & trace contract" → "TRACE.md format". **Suppressed under orchestration** — when invoked from `/auto-task` Phase 3 (see the Caller note), the orchestrator owns TRACE.md writes; read, but do not append.

## Process

### 1. Load the plan

- Read `.auto-task/<branch>/PLAN.md`. If it does not exist, tell the user there is no plan to verify and stop.
- Parse all tasks (both checked and unchecked).

### 2. Verify each task

For each task in the plan:

- Read the files listed in the task.
- Use Grep and Glob to confirm the described change exists in the codebase.
- Assign a status:
  - **COMPLETE** -- the change is fully implemented as described.
  - **PARTIAL** -- some aspects are implemented, others are missing. Specify what's missing.
  - **NOT FOUND** -- no evidence of implementation.
  - **SKIPPED** -- task was intentionally skipped (noted in plan).

### 3. Run quality checks

- Read `CLAUDE.md` or `package.json` to find available commands.
- If a lint command exists (e.g., `yarn lint`, `npm run lint`, `go vet`), run it.
- If a build command exists (e.g., `yarn build`, `npm run build`, `go build`), run it.
- If a test command exists (e.g., `yarn test`, `npm test`, `go test ./...`), run it.
- Report pass/fail for each.

### 4. Check for leftover issues

- Use Grep to search changed files for `TODO`, `FIXME`, `HACK`, `console.log` (in JS/TS projects).
- Report any findings.

### 5. Report

Output a verification report:

```
## Verification Report

| # | Task | Status |
|---|------|--------|
| 1 | Task description | COMPLETE |
| 2 | Task description | PARTIAL -- missing X |
| 3 | Task description | NOT FOUND |

## Quality Checks
- Lint: PASS / FAIL (summary)
- Build: PASS / FAIL (summary)
- Tests: PASS / FAIL / NOT CONFIGURED

## Leftovers
- `file.js:42` -- TODO: handle edge case

## Summary
X/Y tasks complete. Next steps: [suggestions based on results]
```

## Rules

- Do not fix issues during verification. Report only.
- If tasks are PARTIAL or NOT FOUND, suggest the user run `/implement` to resume.
- If quality checks fail, suggest the user fix the issues or run `/fix`.
- Be specific -- include file paths and line numbers where possible.
