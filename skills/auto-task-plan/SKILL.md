---
name: auto-task-plan
description: Analyze requirements and create a structured implementation plan. Use when asked to "plan", "design a solution", "break down this task", "create a plan", or "how should I implement this".
license: MIT
metadata:
  author: ai-workflow
  version: "1.0"
---

# Plan

Create a structured implementation plan from requirements. Produces `.auto-task/<branch>/PLAN.md` with numbered tasks and checkboxes.

> **Working directory.** Plan, state, and run history live under the gitignored `.auto-task/<branch>/` root, where `<branch>` is the current git branch (`git branch --show-current`; if detached or not in a repo, fall back to a flat `.auto-task/`). When invoked inside an `/auto-task` run, the orchestrator owns this directory — write to the exact path it references. **Never commit anything under `.auto-task/`** (it is added to `.git/info/exclude` per-clone).

> **Caller note (do not strip):** When invoked from an orchestration protocol (e.g. `/auto-task` Phase 1), the caller has already run its own clarifying-questions gate, reconnaissance, and approach selection. If the caller has written an `## Approach` section to `PLAN.md`, break down ONLY the chosen approach — do not re-litigate the alternatives. Do NOT run a second `AskUserQuestion` round and do NOT present the plan for approval — write `PLAN.md` to the path the caller specifies and return. The caller appends Acceptance Criteria / Critique / AC pre-flight and owns the single approval gate. When a human runs `/auto-task-plan` directly, gather requirements and present the plan as described below.

## Process

### 1. Gather context

- Read `CLAUDE.md` in the project root (if it exists) for project conventions, tech stack, commands, and structure.
- Ask the user for requirements if not already provided. Use AskUserQuestion to clarify ambiguity before planning.

### 2. Explore the codebase

- Use Glob to understand project structure and find relevant files.
- Use Grep to find existing patterns, similar features, and conventions.
- Read key files to understand the current architecture.
- Identify files that will need modification and files to use as reference.

### 3. Check for past lessons

- If `.auto-task/<branch>/fixes/` exists, read its `.md` files for past bug fixes and lessons learned on this branch.
- Note any relevant patterns or warnings in the plan's Context section.

### 4. Write the plan

Ensure the `.auto-task/<branch>/` directory exists (create it if needed). Write `.auto-task/<branch>/PLAN.md`:

```markdown
# Plan: <title>

**Created:** <date>
**Status:** IN PROGRESS

## Context
<Brief summary of requirements, relevant codebase findings, and any lessons from past patches>

## Tasks

- [ ] 1. <Task description>
  - Files: `path/to/file.js`
  - Details: <what to do and why>

- [ ] 2. <Task description>
  - Files: `path/to/file.js`
  - Details: <what to do and why>

<!-- DRIFT CHECKPOINT -->

- [ ] 3. <Task description>
  ...

## Notes
<Risks, open questions, dependencies>
```

### 5. Present the plan

Show the user the plan summary and tell them to run `/implement` when ready to start.

## Rules

- Each task must be a single, atomic unit of work (one logical change).
- Include the specific files to modify in each task.
- For plans with 5+ tasks, insert `<!-- DRIFT CHECKPOINT -->` lines at logical boundaries (every 3-5 tasks).
- Order tasks by dependency -- things that must happen first come first.
- Do NOT start implementation. Planning only.
- If a `.auto-task/<branch>/PLAN.md` already exists, ask the user whether to replace it or work on the existing one.
