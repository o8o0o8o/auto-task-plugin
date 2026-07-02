# auto-task-plugin

End-to-end autonomous task workflow for Claude Code. Takes a task description from intake to pull request with one human gate at plan approval and mechanical enforcement of every protocol invariant after that.

## What it ships

- **`auto-task` skill** — the orchestrator. Composes the six bundled sibling skills and the verifier agent across five phases (Define → Execute → Self-verify → Review → Handover).
- **Six namespaced sibling skills** — `auto-task-plan`, `auto-task-implement`, `auto-task-verify`, `auto-task-code-review`, `auto-task-commit`, `auto-task-fix`. Forked from the upstream skills and patched to participate in the read-before-review contract. The `auto-task-` prefix keeps them distinct from your existing `/plan`, `/verify`, etc.; under a marketplace install they are further namespaced (`auto-task:auto-task-plan`), and under the `install.sh` fallback they keep the bare `auto-task-plan` form.
- **`task-execution-verifier` agent** — read-only verifier spawned at Gate A (completeness) and Gate B (adversarial). Fresh context per spawn.
- **Four hooks**, all wired automatically by the plugin install (`hooks/hooks.json`) —
  - `block-ai-attribution.sh` (PreToolUse on Bash): refuses commits and PR bodies containing `Co-Authored-By: Claude`, `🤖 Generated`, etc.
  - `enforce-gates.sh` (PreToolUse on Bash): blocks `git commit` during an auto-task run unless `gates.code_review.passed`, `gates.code_review.tool === "skill:auto-task-code-review"`, `gates.code_review.clean_pass_after_last_fix`, and Gate B's gate (or skip reason) are all satisfied. It also enforces **review staleness** — if `git diff <base>` no longer hashes to the recorded `gates.code_review.reviewed_diff_sha`, code changed after the review went clean and the commit is blocked until a re-review. It also carries the **checkout-drift block** — a `git commit` while the working tree sits on a branch other than an active in-place run's branch is blocked (previously a silent fail-open). Fails closed: with `jq` missing or `STATE.json` unparseable during an active run, it blocks rather than letting the commit through.
  - `warn-checkout-drift.sh` (PreToolUse on Bash): informational, NEVER blocks. Warns on every command when an active run exists on a branch other than the one checked out (the proactive half of the checkout-drift guard; the enforce-gates block is the mechanical half). Silent and near-free in non-auto-task repos.
  - `prevent-mid-protocol-stall.sh` (Stop event): blocks turn-ends mid-pipeline by reading `expected_next_action` from STATE.json. The antidote to sub-skill output looking completion-shaped.
  - `check-version.sh` (SessionStart): best-effort update notice. Once per 24h it compares the installed version against the published `plugin.json` on GitHub and, if you're behind, prints a one-line reminder to run `/plugin update auto-task@auto-task-plugin`. Fails open and silent when current, offline, or unparseable — this cached SessionStart notice never blocks or slows a session. **Per-run version check:** on top of that notice, `/auto-task` Phase 1 runs a fresh **per-run version check** (the same script via `--plain`, throttle bypassed) at the start of every NEW run and, if you're behind, asks once whether to auto-apply the update (via `hooks/apply-update.sh` — no manual command) or proceed on the current version. It is separately bounded (`--connect-timeout 2 -m 5`) and fully fail-open — it never blocks the run and never touches the SessionStart throttle stamp. Skipped on resume.
- **`inject-history-reminder.sh`** (optional, `UserPromptSubmit`): tells non-bundled tools that an `.auto-task/<branch>/` history folder exists for the current branch. **Off by default** (token overhead on every prompt); opt in via the snippet in `settings-fragment.json`.
- **`settings-fragment.json`** — fallback only. The marketplace install wires the hooks for you; this snippet is for the offline/dev `install.sh` path and for opting into the two optional hooks.

## Install (marketplace — recommended)

This repo is its own plugin marketplace. From inside Claude Code:

```
/plugin marketplace add o8o0o8o/auto-task-plugin
/plugin install auto-task@auto-task-plugin
```

That copies the plugin into your plugin cache and **auto-wires everything** — the seven skills, the `task-execution-verifier` agent, and all five core hooks (`hooks/hooks.json`). No `settings.json` editing, no symlinks, no `install.sh`.

Plugin skills are namespaced under the plugin name, so you invoke the orchestrator as:

```
/auto-task:auto-task <plain-English task description>
```

and the siblings as `/auto-task:auto-task-plan`, `/auto-task:auto-task-fix`, etc.

### Updating

**Auto-apply (no command to type).** When a newer version exists, the next `/auto-task` run offers to update — choose **"Update it for me (auto-apply)"** and the bundled `hooks/apply-update.sh` applies it for you, detecting your install layout automatically:

- **Marketplace install** → runs `claude plugin update auto-task@auto-task-plugin` (at your install scope).
- **Offline / development install** (git clone via `install.sh`) → runs `git pull --ff-only` in the clone. Fast-forward only — it never forces and never switches your branch, so be on the release-tracking branch (`main`) to pull a release; a dirty/diverged/no-upstream tree fails cleanly with a message instead of clobbering your work.
- **Copy install** (`install.sh --copy`) → cannot self-update (files were copied with no source link); re-run `install.sh` from your clone.

**Restart to load.** An update *stages* the new version but the running session keeps the old code — hooks load at session start and a marketplace update needs a restart to apply. So after auto-apply, **restart Claude Code** and re-run `/auto-task`; re-invoking in the same session would reload nothing.

You can also run the updater standalone (`bash hooks/apply-update.sh`) or update by hand:

```
/plugin update auto-task@auto-task-plugin
```

The bundled `check-version.sh` SessionStart hook also reminds you (at most once per day) when a newer version has been published, so you don't have to remember to check. Updates ship only when the maintainer bumps `version` in `plugin.json`.

### Optional hooks (opt-in)

Two hooks are off by default — see `settings-fragment.json`:

- **`inject-history-reminder.sh`** (`UserPromptSubmit`) — lets third-party tools discover the per-branch history folder. Off by default to avoid token overhead on every prompt.
- **Recommended permissions** — the inert `_optional_recommended_permissions` block denies bare `git push` and asks before `gh pr create`, turning the Phase 5 push prompt into a mechanical gate. Not required (the skill already prompts once), and it affects all your work, so it's opt-in.

## Install (offline / development — fallback)

If you can't use the marketplace (air-gapped, or hacking on the plugin itself), `install.sh` symlinks the skills + agent into `~/.claude/` and prints a hooks snippet to merge into `~/.claude/settings.json`:

```sh
git clone https://github.com/o8o0o8o/auto-task-plugin.git ~/.claude/auto-task-plugin
cd ~/.claude/auto-task-plugin
./install.sh
```

It symlinks the seven skills into `~/.claude/skills/` and the verifier agent into `~/.claude/agents/`, then prints a settings snippet with absolute paths for the hooks. Merge that snippet into `~/.claude/settings.json` — preserve your existing keys, append to the `hooks.PreToolUse` / `hooks.Stop` arrays if they already exist. The skills load without the merge, but the gate-enforcement and anti-stall hooks won't fire. With this path the skills are invoked by their bare names (`/auto-task`), not namespaced.

Pass `--copy` instead of the default to copy files (no symlinks), or `--uninstall` to remove the links. To update: `git pull` inside the clone (symlinks pick up changes automatically; if you used `--copy`, re-run `./install.sh`). The SessionStart update-notice only fires on a marketplace install (it needs `${CLAUDE_PLUGIN_ROOT}`).

## Hard prerequisites

- `git` ≥ 2.30
- `gh` (GitHub CLI) for PR creation
- `jq` (used by the hook scripts)
- `curl` (used by the SessionStart update-notice hook; absence just disables the notice)
- `bash` ≥ 3.2 (the version macOS ships with works; POSIX `sh` does not — the hook scripts use bash features)

## Usage

### Start a new run

```
/auto-task <plain-English task description>
```

The skill creates a branch, sets up the per-branch history folder at `.auto-task/<branch>/`, runs Phase 1 reconnaissance (read-only — Playwright, Context7, Figma, etc.), asks clarifying questions, selects an implementation approach when more than one is viable (generating and scoring candidates, surfacing close calls to you), builds an Acceptance Criteria table, critiques the plan and auto-repairs its structural gaps, and presents a plan for your approval.

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

### Running multiple runs in parallel

Each run is isolated by **branch** and keeps all state under `.auto-task/<branch>/`. Parallel runs in the same repo are now **automatic** — no manual setup:

- **Launch from any branch — it just works.** For every new-description run, Phase 1 forks a fresh `<type>/<slug>` branch **from the repo's default branch** (`main`/`master`, best-effort fetched first) and gives it its OWN git worktree (`git worktree add .claude/worktrees/<type>-<slug> -b <branch> <default-ref>`, then it relocates the session in via the `EnterWorktree` tool). This is unconditional — it does not matter what branch you are currently on or what the shared checkout is doing. Your original checkout is left untouched and free for other work, and a second `/auto-task` started elsewhere gets its own worktree too — git forbids two worktrees on one branch (and names are disambiguated before creation), so they can never collide. The worktree is kept on disk after the run; prune it with `git worktree remove .claude/worktrees/<type>-<slug>` when done.
- **Based on the default branch, not your current HEAD.** Every run starts clean from a current default base, so it never inherits the current checkout's branch or uncommitted WIP. A run started while on a feature branch forks fresh from the default rather than continuing that branch — to base a run on specific work, prepare a worktree for it by hand (below) and run `/auto-task` inside it.
- **Manual worktrees still work** if you want to base a run on specific existing work:

  ```sh
  git worktree add ../auto-task-feat-x -b feat/x   # one worktree per task
  cd ../auto-task-feat-x && claude                  # then run /auto-task here
  ```

  auto-task detects it is already inside a linked worktree and runs in place there, without nesting a second worktree.
- **The in-place fallback is guarded.** If `EnterWorktree`/`git worktree add` is unavailable, the run falls back to the shared checkout — and the **checkout-drift guard** catches the case where that checkout is switched off the run's branch from another terminal: `warn-checkout-drift.sh` warns on every command and `enforce-gates.sh` hard-blocks any commit until you switch back (or clear an abandoned run). Previously this failed open silently.

Each worktree has its own working tree, branch, and `.auto-task/<branch>/` history, and the gate + Stop hooks resolve state per-worktree (via `git rev-parse --show-toplevel`), so concurrent runs never interfere — even though they share one clone's object store and common-dir exclude file. Merge or open a PR from each worktree independently.

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

- The plugin never commits anything under `.auto-task/` — that folder is local-only, gitignored via the common-dir exclude (`$(git rev-parse --git-common-dir)/info/exclude`) on branch setup.
- The plugin never writes to your memory store. Phase 1 reads it; Phase 5 surfaces candidate memories for you to save if you choose. No autonomous writes.
- The plugin never bypasses hooks. Pre-commit hook block → fix the underlying state, don't `--no-verify`.
- The plugin never adds `Co-Authored-By: Claude` or `🤖 Generated` markers — both the skill and the hook enforce this.

## Troubleshooting

| Error message | Meaning | Fix |
|---|---|---|
| `Blocked by auto-task-plugin: auto-task run in progress` | The gate-enforcement hook fired because gates haven't passed. | Read the message — it names which gate is missing. Re-run the relevant skill and update the flag with real evidence. Do NOT speculatively set flags. |
| `auto-task is mid-pipeline (phase=…)` | The Stop hook fired because `expected_next_action === "auto-continue"`. | This is the anti-stall block working as intended. Make the next tool call instead of trying to end the turn. |
| `commit messages and PR bodies must NOT contain "Co-Authored-By: Claude"` | The AI-attribution hook fired. | Rewrite the commit message / PR body without the marker. |
| `.auto-task/` showing up in `git status` as untracked | The exclude entry didn't land. | Append `.auto-task/` to `$(git rev-parse --git-common-dir)/info/exclude` (worktree-correct — in a worktree `.git` is a file, so the bare `.git/info/exclude` path fails). |
| `the working-tree diff changed since the last clean code-review pass` | Code was edited after the code-review gate went clean, so the staleness check fired. | Re-run the `auto-task-code-review` skill on the current diff, drive it to a clean pass, then refresh `gates.code_review.reviewed_diff_sha`. Do not bypass. |
| `jq is not installed` / `STATE.json is not valid JSON` (hook block) | A hook failed closed because it couldn't verify state during an active run. | Install `jq`, or repair/remove `.auto-task/<branch>/STATE.json` if no run is active. |

## Pruning history

Per-branch folders under `.auto-task/` never auto-prune. After a branch is merged and deleted, you can `rm -rf .auto-task/<old-branch>/` to keep the tree compact. Nothing in the plugin depends on stale folders being present.

## License

MIT — see `LICENSE`.

## Status

**v0.1.12 — pre-release.** The install path has been verified in a throwaway directory. The enforcement spine (state-machine ↔ hooks) has an automated integration test — `tests/enforcement-spine.test.sh`, 53 assertions covering the full STANDARD + LIGHT lifecycle, gate ordering, review-staleness (including under hostile git config), raw-mode commit detection, the Stop-hook stall-breaker, the AI-attribution block, the fail-open/fail-closed edges, per-worktree / subdirectory / nested-repo state resolution, the worktree-isolated-run resolution with `CLAUDE_PROJECT_DIR` pinned to the main checkout, the checkout-drift block + warning (`enforce-gates.sh` + `warn-checkout-drift.sh`), and the `check-version.sh --plain` per-run-check behavior. What is **not** yet exercised end-to-end is the *model-follows-the-prose* path: the `task-execution-verifier` agent (Gate A/B) and the orchestrator's phase-driving have a real protocol but have not been run inside a live `/auto-task` against a real task — treat those as functional but not yet battle-tested. File issues on GitHub.
