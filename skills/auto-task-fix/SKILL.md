---
name: auto-task-fix
description: Fix a bug via a strict 5-phase workflow (Investigate → Define → Execute → Prevent → Verify). Use when asked to "fix this bug", "debug this", "something is broken", "fix the error", or "patch this issue".
license: MIT
metadata:
  author: ai-workflow
  version: "2.0"
---

# Fix

Disciplined bug-fix workflow. Five phases, with a single hard stop for user approval after Phase 2 and quoted evidence required in Phase 5.

> **Working directory.** Run history and patch notes live under the gitignored `.auto-task/<branch>/` root, where `<branch>` is the current git branch (`git branch --show-current`; if detached or not in a repo, fall back to a flat `.auto-task/`). **Never commit anything under `.auto-task/`.** When invoked inside an `/auto-task` run, this skill only modifies the working tree — the orchestrator owns commits and state.

> **Caller note (do not strip):** When invoked from an orchestration / fix-loop protocol (e.g. `/auto-task` Phases 3–4 and Gates A/B), the caller owns the human gate, the commit, and the run state. In that mode the skill's standalone stops are **suppressed**:
> - **Phase 2's "STOP for user approval" does not apply** — the fix tasks come from the caller's already-approved plan and gate findings, so flow straight through Phases 3–5 without stopping.
> - **Do NOT spawn the Phase 5 diff-review subagent.** The caller owns code review via the `auto-task-code-review` skill plus the Gate A/B verifiers; a hand-rolled `general-purpose`/`code-reviewer` spawn here both duplicates that and violates the caller's "code review only via the skill" rule.
> - **Do NOT commit.** The working-tree change is the deliverable; the caller commits once, later, after its gates pass.
>
> Your output (root cause, change, evidence) is INPUT returned to the caller, not an end-of-turn. When a human runs `/auto-task-fix` directly, keep every gate below as written.

## Hard rules

- **One stop, after Phase 2.** Do not write code until the user approves the acceptance criteria.
- **No speculative edits.** Every code change must trace back to a verified hypothesis from Phase 1.
- **Stay in scope.** No refactors, renames, or "while I'm here" cleanups. Touch only what the fix requires.
- **Phase 4 is mandatory.** A fix that doesn't search for sibling occurrences and add a guardrail is not done.
- **Phase 5 requires quoted evidence.** Each acceptance criterion must be confirmed with a quoted snippet of real output (test result, type-check output, observed behavior). No hand-waving.

## Phase 1 — Investigate

Goal: understand the bug well enough to state the root cause as one sentence.

- Read the user's description, error output, stack trace, or failing test.
- If `.auto-task/<branch>/fixes/` exists, skim its `.md` files for prior fixes of the same class.
- Trace execution: read the relevant files, follow the call path, identify the exact failing condition.
- Map the **blast radius**: which files, modules, callers, and consumers are affected?
- Classify risk: **low** (isolated, pure logic, covered by tests) or **high** (shared module, public contract, async/race, persistence, security).
- State one explicit root-cause hypothesis. If you cannot, keep investigating — do not jump to Phase 2.

## Phase 2 — Define (STOP for user approval)

Goal: write down what "fixed" means in measurable terms, then wait.

Produce a short report:
1. **Root cause** — one sentence.
2. **Blast radius** — files/modules touched.
3. **Risk** — low or high, with a one-line justification.
4. **Acceptance criteria** — each item must be objectively verifiable (a passing test, a type-check, observable behavior). Always include "no regressions in existing functionality".
5. **Proposed minimal change** — bullets, not code.

**Then stop and wait for explicit user approval.** Do not proceed to Phase 3 without it.

## Phase 3 — Execute

Goal: implement the minimum change that satisfies the criteria.

- Modify only the lines the fix requires.
- No new files unless strictly necessary.
- Reuse existing patterns and utilities.
- Follow project conventions (`CLAUDE.md`, neighboring code).

## Phase 4 — Prevent (mandatory)

Goal: make this class of bug harder to recur.

- **Classify the root cause** with a tag: e.g. `null-check`, `async`, `race-condition`, `off-by-one`, `state`, `types`, `css`, `api`, `validation`.
- **Search for siblings.** Grep the codebase for the same class of issue (same pattern, same missing check, same misuse). Fix the ones you find, or list them in the patch file as follow-ups if out of scope.
- **Add a guardrail** appropriate to the cause: a unit test that pins the fixed behavior, a type tightening, a lint rule, a runtime assertion at a boundary, or a comment explaining a non-obvious invariant. Pick the lightest one that actually prevents recurrence.
- **Write the patch file.** Ensure `.auto-task/<branch>/fixes/` exists. Create `.auto-task/<branch>/fixes/YYYY-MM-DD-HH.mm.md`:

  ```markdown
  # <Short title>

  **Date:** YYYY-MM-DD
  **Tags:** <root-cause tags>

  ## Problem
  <How it manifested>

  ## Root Cause
  <Why — the actual technical cause>

  ## Solution
  <What changed and why>

  ## Sibling occurrences
  <Other places checked; fixed or noted as follow-ups>

  ## Guardrail
  <Test / type / lint / assertion added, and what it prevents>

  ## Files Changed
  - `path/to/file` — <what>
  ```

## Phase 5 — Verify

Goal: prove each acceptance criterion is met, with quoted evidence.

- Run the project's checks that apply: type-check, lint, tests, build. Quote the relevant lines of output.
- Reproduce the original bug scenario and confirm it's fixed. Quote the observed behavior.
- For each acceptance criterion from Phase 2, write one line: criterion → quoted evidence.
- **Fresh-context diff review.** Invoke the `auto-task-code-review` skill on the diff (not a hand-rolled `general-purpose`/`code-reviewer` agent — the disciplined skill is the required reviewer) and report its findings. _Suppressed under orchestration — see the Caller note; the orchestrator owns review._
- If a check fails, fix it and re-verify within the same phase.

## Output discipline

- Phase 1 output: hypothesis + blast radius + risk, in under ~10 lines.
- Phase 2 output: the structured report above, then stop.
- Phase 3 output: the diff.
- Phase 4 output: the patch file path + sibling-search summary + guardrail description.
- Phase 5 output: criterion-by-criterion evidence table + subagent review summary.
