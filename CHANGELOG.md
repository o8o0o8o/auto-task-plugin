# Changelog

All notable changes to `auto-task-plugin` are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/) and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased] — v0.1.0 (pre-release)

Initial extraction of the `auto-task` skill from `~/.claude/skills/auto-task/` into a self-contained, shareable Claude Code plugin. See `PACKAGING_PLAN.md` for the open work items that remain before a real v0.1.0 release.

### Added

- `skills/auto-task/` — orchestrator skill (SKILL.md + ARCHITECTURE.md).
- Forked bundled copies of the six sibling skills, namespaced under the `auto-task-` prefix to avoid clobbering the user's existing skills: `auto-task-plan`, `auto-task-implement`, `auto-task-verify`, `auto-task-code-review`, `auto-task-commit`, `auto-task-fix`. Snapshot date: TODO (record the upstream commit SHA on each).
- `agents/task-execution-verifier.md` — two-mode verifier (completeness / adversarial) spawned at Gate A and Gate B. Read-only tool set (`Read`, `Glob`, `Grep`, `Bash`). Implements the read-before-review contract (consults `TRACE.md` and `CONTEXT.md` before forming findings).
- `hooks/block-ai-attribution.sh` — refuses commits / PR bodies containing AI-attribution markers.
- `hooks/enforce-gates.sh` — blocks `git commit` during a run until all required gates have passed. Path now resolves `.auto-task/<branch>/STATE.json` (was `.patches/AUTO-TASK-STATE.json` in the source machine's settings.json).
- `hooks/prevent-mid-protocol-stall.sh` — Stop hook backed by `expected_next_action` in STATE.json. Blocks turn-ends mid-pipeline.
- `settings-fragment.json` — merge template for `~/.claude/settings.json` (the three hooks).
- `.claude-plugin/plugin.json` — plugin manifest. Field names are placeholders; verify against the current Claude Code plugin spec before locking.
- `README.md`, `LICENSE` (MIT), this changelog.
- `PACKAGING_PLAN.md` — the work plan and open questions for getting to v0.1.0.

### Known issues

- `task-execution-verifier` agent has a real prompt but has not yet been exercised end-to-end inside a real auto-task run — treat Gate A/B as functional but not battle-tested.
- Plugin manifest field names not verified against the current spec (the canonical install path is `install.sh`, not `/plugin add`, so the manifest is currently informational).
- Bundled skills do not yet have the full read-before-review patches applied — the verifier agent enforces the contract on its side, but the patched `auto-task-code-review` / `auto-task-verify` / `auto-task-fix` skills are still close to upstream (Phase C item 10 of the original packaging plan).
- `enforce-gates.sh` path resolution: assumes `CLAUDE_PROJECT_DIR` is set to the repo root (or falls back to `$PWD`). Verify this environment variable is provided by the Claude Code hook context.
