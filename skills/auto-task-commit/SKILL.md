---
name: auto-task-commit
description: Create a conventional commit from staged changes. Use when asked to "commit", "save changes", "commit my work", or "create a commit".
license: MIT
metadata:
  author: ai-workflow
  version: "1.0"
---

# Commit

Analyze staged changes and create a conventional commit with user confirmation.

## Process

### 1. Check state

- Run `git status` to see staged and unstaged changes.
- Run `git diff --cached` to see what's staged.
- If nothing is staged but there are unstaged changes, ask the user which files to stage.
- If there are no changes at all, tell the user and stop.
- Run `git log --oneline -5` to see recent commit style for consistency.

### 2. Analyze the diff

- Read the staged diff carefully.
- Determine the type of change and affected area.

### 3. Generate commit message

Create a message following Conventional Commits:

```
<type>(<scope>): <description>

<optional body>
```

**Types:**
- `feat` -- new feature or capability
- `fix` -- bug fix
- `docs` -- documentation only
- `style` -- formatting, whitespace, no logic change
- `refactor` -- restructure without behavior change
- `perf` -- performance improvement
- `test` -- adding or updating tests
- `build` -- build system or dependencies
- `ci` -- CI/CD configuration
- `chore` -- maintenance, tooling, config

**Message rules:**
- `<description>`: imperative mood, lowercase, no period, under 70 characters.
- `<scope>`: optional, use when change is clearly scoped to one area (e.g., `auth`, `header`, `api`).
- `<body>`: explain "why" if not obvious. Use for multi-task commits or significant changes.

### 4. Confirm and execute

- Present the proposed message to the user.
- Ask: "Commit with this message?" with options: Yes / Edit / Cancel.
- On "Yes": stage recommended files (if any) and execute the commit.
- On "Edit": ask for revisions and commit with the updated message.
- On "Cancel": abort.

## Rules

- Never commit files that look like secrets: `.env`, `credentials.*`, `*secret*`, `*.pem`, `*.key`. Warn the user if such files are staged.
- Never force push or amend unless the user explicitly asks.
- **Never commit anything under `.auto-task/`.** That directory is local auto-task harness, state, and run history — it is added to `.git/info/exclude` per-clone and must stay out of every commit. Before committing, run `git restore --staged .auto-task/ 2>/dev/null || true` and confirm `git diff --cached --name-only` shows no `.auto-task/` paths. If any appear, unstage them and warn the user.
- If changes span unrelated areas, suggest splitting into multiple commits.
- If the diff is very large (50+ files), warn the user and suggest reviewing first with `/review`.
