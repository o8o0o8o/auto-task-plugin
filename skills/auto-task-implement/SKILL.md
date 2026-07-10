---
name: auto-task-implement
description: Execute tasks from the implementation plan. Use when asked to "implement the plan", "start implementing", "continue implementation", "resume work", or "execute the plan".
license: MIT
metadata:
  author: ai-workflow
  version: "1.0"
---

# Implement

Execute tasks from `.auto-task/<branch>/PLAN.md` one by one. Supports session resumption.

> **Working directory.** Plan, state, and run history live under the gitignored `.auto-task/<branch>/` root, where `<branch>` is the current git branch (`git branch --show-current`; if detached or not in a repo, fall back to a flat `.auto-task/`). When invoked inside an `/auto-task` run, the orchestrator owns this directory — read and write the exact path it references. **Never commit anything under `.auto-task/`.**

> **Caller note (do not strip):** When invoked from an orchestration protocol (e.g. `/auto-task` Phase 2), the `<!-- DRIFT CHECKPOINT -->` markers are **drift-check points, not commit-or-stop points**. Do NOT pause, do NOT wait for the user, and do NOT commit at a checkpoint — the caller inspects drift and continues the loop itself. Return when all tasks are ticked. When a human runs `/auto-task-implement` directly, keep the checkpoint pause below.

## Process

### 1. Load context

- Read `CLAUDE.md` for project conventions (if it exists).
- Read `.auto-task/<branch>/PLAN.md`. If it does not exist, tell the user to run `/auto-task-plan` first and stop.
- Read any `.md` files in `.auto-task/<branch>/fixes/` to learn from past fixes. If a patch says "always check for X" or "avoid pattern Y", apply that knowledge during implementation.

### 2. Determine starting point

- Parse the checkboxes in PLAN.md.
- Find the first unchecked task (`- [ ]`). This is where work resumes.
- If all tasks are checked, tell the user implementation is complete and suggest `/auto-task-verify`.
- Show progress: "Resuming from task N of M" (or "Starting task 1 of M" if fresh).

### 3. Execute tasks

For each unchecked task, in order:

1. Create a TaskCreate entry with the task description as subject and an activeForm like "Implementing task N".
2. Set the task to `in_progress` via TaskUpdate.
3. Implement the change described in the plan. Follow project conventions from CLAUDE.md.
4. After completing the change, immediately update the checkbox in `.auto-task/<branch>/PLAN.md` from `- [ ]` to `- [x]`.
5. Set the task to `completed` via TaskUpdate.
6. Move to the next task.

### 4. Checkpoints

When you reach a `<!-- DRIFT CHECKPOINT -->` line in the plan:

- Pause implementation.
- Tell the user: "Reached a checkpoint after task N. You can run `/auto-task-commit` to save progress, then `/auto-task-implement` to continue."
- Stop and wait for the user.

### 5. Completion

When all tasks are checked:

- Update the Status in PLAN.md from "IN PROGRESS" to "COMPLETE".
- Tell the user: "All tasks complete. Run `/auto-task-verify` to check the work, then `/auto-task-commit` to save."

## Rules

- Implement tasks in the order specified. Do not skip or reorder.
- If a task is unclear, use AskUserQuestion to clarify before proceeding.
- If a task fails or cannot be completed, add a note under the task in PLAN.md and ask the user how to proceed. Do not mark it as complete.
- Always update the checkbox in PLAN.md immediately after completing each task. This is critical for session resumption.
- Do not modify the plan structure -- only update checkboxes and add notes under tasks if needed.
- Apply lessons from patches: if past patches warn about specific patterns, follow their guidance.
