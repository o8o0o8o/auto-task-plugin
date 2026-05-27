---
name: verify
description: Verify that planned tasks are actually implemented. Use when asked to "verify implementation", "check the plan", "validate changes", "are all tasks done", or "run verification".
license: MIT
metadata:
  author: ai-workflow
  version: "1.0"
---

# Verify

Post-implementation verification. Checks that each planned task is actually implemented and runs available quality checks.

## Process

### 1. Load the plan

- Read `.patches/PLAN.md`. If it does not exist, tell the user there is no plan to verify and stop.
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
