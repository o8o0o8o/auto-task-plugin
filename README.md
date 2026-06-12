# auto-task-plugin

End-to-end autonomous task workflow for Claude Code. Takes a task description from intake to pull request with one human gate at plan approval and mechanical enforcement of every protocol invariant after that.

## What it ships

- **`auto-task` skill** — the orchestrator. Composes the six bundled sibling skills and the verifier agent across five phases (Define → Execute → Self-verify → Review → Handover).
- **Six namespaced sibling skills** — `auto-task-plan`, `auto-task-implement`, `auto-task-verify`, `auto-task-code-review`, `auto-task-commit`, `auto-task-fix`. Forked from the upstream skills and patched to participate in the read-before-review contract. The `auto-task-` prefix avoids clobbering your existing `/plan`, `/verify`, etc.
- **`task-execution-verifier` agent** — read-only verifier spawned at Gate A (completeness) and Gate B (adversarial). Fresh context per spawn.
- **Three hooks** —
  - `block-ai-attribution.sh` (PreToolUse on Bash): refuses commits and PR bodies containing `Co-Authored-By: Claude`, `🤖 Generated`, etc.
  - `enforce-gates.sh` (PreToolUse on Bash): blocks `git commit` during an auto-task run unless `gates.code_review.passed`, `gates.code_review.tool === "skill:auto-task-code-review"`, `gates.code_review.clean_pass_after_last_fix`, and Gate B's gate (or skip reason) are all satisfied. It also enforces **review staleness** — if `git diff <base>` no longer hashes to the recorded `gates.code_review.reviewed_diff_sha`, code changed after the review went clean and the commit is blocked until a re-review. Fails closed: with `jq` missing or `STATE.json` unparseable during an active run, it blocks rather than letting the commit through.
  - `prevent-mid-protocol-stall.sh` (Stop event): blocks turn-ends mid-pipeline by reading `expected_next_action` from STATE.json. The antidote to sub-skill output looking completion-shaped.
- **`settings-fragment.json`** — snippet to merge into `~/.claude/settings.json` that wires up the three hooks.

## Install

Clone the repo, run `install.sh`, merge the printed JSON into `~/.claude/settings.json`.

```sh
git clone https://github.com/o8o0o8o/auto-task-plugin.git ~/.claude/auto-task-plugin
cd ~/.claude/auto-task-plugin
./install.sh
```

`install.sh` symlinks the seven skills into `~/.claude/skills/` and the verifier agent into `~/.claude/agents/`, then prints a settings snippet with absolute paths for the hooks. Merge that snippet into `~/.claude/settings.json` — preserve your existing keys, append to the `hooks.PreToolUse` / `hooks.Stop` arrays if they already exist. If you don't have a `~/.claude/settings.json` yet, save the printed snippet as that file. The skill will load without the merge, but the gate-enforcement and anti-stall hooks won't fire.

Pass `--copy` instead of the default to copy files (no symlinks), or `--uninstall` to remove the links.

**Optional hardening:** `settings-fragment.json` also carries an inert `_optional_recommended_permissions` block. Merging its `permissions` into your settings.json denies bare `git push` and asks before `gh pr create`, turning the Phase 5 push prompt into a mechanical gate. Not required — the skill already prompts once before pushing — and it affects all your work, not just auto-task, so it's opt-in.

To update later: `git pull` inside the clone. Symlinks pick up changes automatically; if you used `--copy`, re-run `./install.sh`.

## Hard prerequisites

- `git` ≥ 2.30
- `gh` (GitHub CLI) for PR creation
- `jq` (used by all three hook scripts)
- `bash` ≥ 3.2 (the version macOS ships with works; POSIX `sh` does not — the hook scripts use bash features)

## Usage

### Start a new run

```
/auto-task <plain-English task description>
```

The skill creates a branch, sets up the per-branch history folder at `.auto-task/<branch>/`, runs Phase 1 reconnaissance (read-only — Playwright, Context7, Figma, etc.), asks clarifying questions, builds an Acceptance Criteria table, and presents a plan for your approval.

After you type `approved` / `proceed` / `yes`, the pipeline runs unattended through:

- **Phase 2** Execute — invokes the bundled `auto-task-implement` skill; drift-checks each checkpoint against the plan's Blast Radius.
- **Phase 3** Self-verify — invokes `auto-task-verify`; runs every Acceptance Criterion bound to the `self-verify` gate.
- **Gate A** — spawns `task-execution-verifier` in `completeness` mode; runs every Acceptance Criterion bound to `gate-a`.
- **Phase 4** Code review — invokes `auto-task-code-review`, applies any blockers / required fixes, re-invokes until the latest pass is clean.
- **Gate B** — spawns `task-execution-verifier` in `adversarial` mode (skipped for `tier=light` tasks).
- **Phase 5** Handover — single commit, push, PR with embedded change diagram. Asks once whether to push & open PR / push only / hold.

### Resume an interrupted run

```
/auto-task
```

(no argument) — reads `.auto-task/<current-branch>/STATE.json` and continues from where it left off. Resume re-enters the phase recorded in `STATE.json` from the top; phases are designed to be re-entrant (re-running self-verify, a gate, or the review loop on the current working tree is idempotent — it recomputes from disk state, it doesn't double-apply). The component preflight (above) re-runs on every resume in case a skill or the verifier agent was uninstalled between sessions.

### Surfacing protocol

The pipeline stops mid-flight only when the Loop rule fires:

1. No progress (two consecutive iterations with no measurable improvement).
2. Out-of-scope (remaining issues don't map to the approved AC).
3. External blocker (missing creds, broken infra, undecided design).
4. Test flakiness (non-deterministic failure).

You get a status with **why stopped** + **current state** + **suggested next move**. Resume with `/auto-task`.

## Read-before-review contract

When the bundled `auto-task-code-review`, `auto-task-verify`, or `auto-task-fix` skill runs in a repo with an existing `.auto-task/<branch>/` folder, it reads `CONTEXT.md` and `TRACE.md` first so it doesn't re-litigate decisions or miss real issues that earlier reviewers flagged but never followed up on.

**For third-party tools that want to participate:** the contract is "if `.auto-task/$(git branch --show-current)/` exists, read `CONTEXT.md` and `TRACE.md` before forming findings; append a new TRACE entry on completion (block format documented in `skills/auto-task/SKILL.md`)." Adopt this in your own tool to interoperate.

## Recommended project memories

Auto-task reads `~/.claude/projects/<slug>/memory/MEMORY.md` during Phase 1 recon. Useful entries to maintain per-project:

- **`feedback_no_unrequested_commits.md`** — `"continue"` / `"proceed"` should not authorize commits; only an explicit `"commit"` does.
- **`feedback_subagents_dangerous_git.md`** — sub-agents should never run `git reset --hard`, `git push --force`, or similar in dispatch prompts.
- **`project_team_review_policy.md`** — who must review PRs touching specific paths.
- **`reference_external_systems.md`** — pointers to Linear / Notion / Slack channels where decisions are tracked.

The plugin does NOT ship memory entries. They are per-user, per-project, opt-in.

## What does NOT happen

- The plugin never commits anything under `.auto-task/` — that folder is local-only, gitignored via `.git/info/exclude` on branch setup.
- The plugin never writes to your memory store. Phase 1 reads it; Phase 5 surfaces candidate memories for you to save if you choose. No autonomous writes.
- The plugin never bypasses hooks. Pre-commit hook block → fix the underlying state, don't `--no-verify`.
- The plugin never adds `Co-Authored-By: Claude` or `🤖 Generated` markers — both the skill and the hook enforce this.

## Troubleshooting

| Error message | Meaning | Fix |
|---|---|---|
| `Blocked by auto-task-plugin: auto-task run in progress` | The gate-enforcement hook fired because gates haven't passed. | Read the message — it names which gate is missing. Re-run the relevant skill and update the flag with real evidence. Do NOT speculatively set flags. |
| `auto-task is mid-pipeline (phase=…)` | The Stop hook fired because `expected_next_action === "auto-continue"`. | This is the anti-stall block working as intended. Make the next tool call instead of trying to end the turn. |
| `commit messages and PR bodies must NOT contain "Co-Authored-By: Claude"` | The AI-attribution hook fired. | Rewrite the commit message / PR body without the marker. |
| `.auto-task/` showing up in `git status` as untracked | The `.git/info/exclude` entry didn't land. | Append `.auto-task/` to `.git/info/exclude` manually. |
| `the working-tree diff changed since the last clean code-review pass` | Code was edited after the code-review gate went clean, so the staleness check fired. | Re-run the `auto-task-code-review` skill on the current diff, drive it to a clean pass, then refresh `gates.code_review.reviewed_diff_sha`. Do not bypass. |
| `jq is not installed` / `STATE.json is not valid JSON` (hook block) | A hook failed closed because it couldn't verify state during an active run. | Install `jq`, or repair/remove `.auto-task/<branch>/STATE.json` if no run is active. |

## Pruning history

Per-branch folders under `.auto-task/` never auto-prune. After a branch is merged and deleted, you can `rm -rf .auto-task/<old-branch>/` to keep the tree compact. Nothing in the plugin depends on stale folders being present.

## License

MIT — see `LICENSE`.

## Status

**v0.1.0 — pre-release.** The install path has been verified in a throwaway directory. The enforcement spine (state-machine ↔ hooks) has an automated integration test — `tests/enforcement-spine.test.sh`, 19 assertions covering the full STANDARD + LIGHT lifecycle, gate ordering, review-staleness, and the fail-open/fail-closed edges. What is **not** yet exercised end-to-end is the *model-follows-the-prose* path: the `task-execution-verifier` agent (Gate A/B) and the orchestrator's phase-driving have a real protocol but have not been run inside a live `/auto-task` against a real task — treat those as functional but not yet battle-tested. File issues on GitHub.
