---
name: plan
description: Analyze requirements and create a structured implementation plan. Use when asked to "plan", "design a solution", "break down this task", "create a plan", or "how should I implement this".
license: MIT
metadata:
  author: ai-workflow
  version: "1.0"
---

# Plan

Create a structured implementation plan from requirements. Produces `.patches/PLAN.md` with numbered tasks and checkboxes.

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

- If `.patches/` exists, read all `.md` files there (excluding PLAN.md) for past bug fixes and lessons learned.
- Note any relevant patterns or warnings in the plan's Context section.

### 4. Write the plan

Ensure `.patches/` directory exists (create it if needed). Write `.patches/PLAN.md`:

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

<!-- COMMIT CHECKPOINT -->

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
- For plans with 5+ tasks, insert `<!-- COMMIT CHECKPOINT -->` lines at logical boundaries (every 3-5 tasks).
- Order tasks by dependency -- things that must happen first come first.
- Do NOT start implementation. Planning only.
- If a `.patches/PLAN.md` already exists, ask the user whether to replace it or work on the existing one.
