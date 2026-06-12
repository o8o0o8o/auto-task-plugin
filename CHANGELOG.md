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

### Changed

- **Hooks now fail safe instead of fail-open.** All three hooks dropped `set -e` (a stray non-zero from `jq` on malformed/partial JSON previously crashed the script into a fail-open exit) in favour of `set -uo pipefail` with individually guarded reads. The two safety hooks fail **closed**: once `enforce-gates.sh` knows the command is a `git commit` and a STATE.json exists, missing `jq` or unparseable JSON blocks the commit; `prevent-mid-protocol-stall.sh` blocks the stop when an `approved` run's state can't be read (per the skill's "keeping the turn alive is the correct failure mode"). Both still allow freely when no run is active, so unrelated repos and commits are unaffected. `block-ai-attribution.sh` now also works without `jq` by scanning the raw payload, so a missing `jq` can't let an attribution marker slip through.
- **`enforce-gates.sh` now enforces review staleness.** The gate booleans (`code_review.passed`, `clean_pass_after_last_fix`) are values the model sets for itself. The hook now also binds them to the actual code: on a clean review the orchestrator records `gates.code_review.reviewed_diff_sha = git diff <base> | git hash-object --stdin`, and the hook recomputes that hash at commit time and blocks if it differs — catching the common failure mode of editing code after the review went clean and committing without re-review. Backward-compatible: the check is skipped when `state.base` or `reviewed_diff_sha` is absent, so it can only add a block, never spuriously allow. New state fields: `base` (base-commit SHA) and `gates.code_review.reviewed_diff_sha`. `expected_next_action` also added to the `ARCHITECTURE.md` schema (it was already in `SKILL.md`).

### Fixed

- **Reconciled the sibling skills' standalone gates with the orchestrator's NON-YIELDING CONTRACT.** Only `auto-task-code-review` carried the protective "Caller note" that tells an orchestrator the skill's output is INPUT (not an end-of-turn); the other five still contained standalone stops that, taken literally during a run, break the "one human gate" guarantee: `auto-task-fix`'s "STOP for user approval" + a Phase 5 reviewer-agent spawn, `auto-task-commit`'s "Commit with this message? Yes/Edit/Cancel" prompt, `auto-task-implement`'s "Stop and wait for the user" at checkpoints, and `auto-task-plan` / `auto-task-verify`'s user-directed asks/suggestions. Added a conditional caller note to each: under orchestration the standalone gate is suppressed and control returns to the caller; run directly by a human, the gate behaves as before. Also pointed `auto-task-fix`'s standalone Phase 5 review at the `auto-task-code-review` skill instead of a hand-rolled `general-purpose`/`code-reviewer` agent.
- **Completed the `.patches/` → `.auto-task/<branch>/` migration across all six bundled sibling skills and `ARCHITECTURE.md`.** Previously only the orchestrator `SKILL.md` and `enforce-gates.sh` had been migrated; the siblings still read/wrote `.patches/`, which is not in `.git/info/exclude` and not pre-stage-cleaned — so harness scratch could leak into commits. The siblings now resolve everything under the gitignored `.auto-task/<branch>/` root.
- **`auto-task-commit` no longer instructs the model to commit harness files.** The rule "If `.patches/` files are in the diff, include them" directly contradicted the orchestrator's "never commit `.auto-task/`" invariant; it is replaced with an explicit unstage-and-warn rule.
- **Corrected the branch-path examples in `SKILL.md`** (`fix/auth-bug` → `.auto-task/fix/auth-bug/`, not the namespacing-mangled `.auto-task/auto-task-fix/auth-bug/`). A divergent path makes the gate and Stop hooks find no state file and fail open. Added an explicit note that the folder name must match `git branch --show-current` verbatim.
- **`ARCHITECTURE.md`** state-file path, filename (`STATE.json`, not `AUTO-TASK-STATE.json`), on-disk layout, and `gates.code_review.tool` value (`skill:auto-task-code-review`) brought back in sync with `SKILL.md` and the hooks.

### Added

- `hooks/inject-history-reminder.sh` — the optional `UserPromptSubmit` hook referenced (but previously missing) in `settings-fragment.json`. Informs the session when `.auto-task/<branch>/` history exists so any reviewer honours the read-before-review contract. Off by default.

### Known issues

- `task-execution-verifier` agent has a real prompt but has not yet been exercised end-to-end inside a real auto-task run — treat Gate A/B as functional but not battle-tested.
- Plugin manifest field names not verified against the current spec (the canonical install path is `install.sh`, not `/plugin add`, so the manifest is currently informational).
- Bundled sibling skills now share the orchestrator's `.auto-task/<branch>/` working-directory convention, but their richer read-before-review behaviour (reading CONTEXT.md / TRACE.md, appending trace entries) still lives mostly in the orchestrator and the verifier agent rather than in each sibling.
- `enforce-gates.sh` path resolution: assumes `CLAUDE_PROJECT_DIR` is set to the repo root (or falls back to `$PWD`). Verify this environment variable is provided by the Claude Code hook context.
