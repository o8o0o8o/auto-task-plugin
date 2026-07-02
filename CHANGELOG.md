# Changelog

All notable changes to `auto-task-plugin` are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/) and the project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.13]

Makes updating the plugin a one-choice, no-typed-command action — there is always an option to update, and it applies itself.

### Added

- **`hooks/apply-update.sh` — non-interactive, fail-safe updater.** It self-detects the install layout and applies the update without any typed command: a **marketplace** install (plugin root under a `plugins/cache/` dir) runs `claude plugin update auto-task@auto-task-plugin --scope <scope>` (scope resolved from `claude plugin list`, default `user`); an **install.sh / dev** install (a git work tree) runs `git -C <root> fetch && git -C <root> pull --ff-only`; a **copy** install or any other layout gets a clear "unsupported — re-run install.sh" message. Layout detection is *positive* (never "not git ⇒ marketplace"), so a `--copy` install can't be misrouted to the marketplace path. Git updates are fast-forward only — never forced, never a branch switch — and a dirty/diverged/no-upstream tree fails cleanly instead of clobbering local work. An already-up-to-date git tree reports a no-op (not a false "applied") so the update offer can't loop. Success/failure is the exit code (not stdout text); `AUTO_TASK_UPDATE_DRYRUN=1` prints the planned command and mutates nothing. Covered by `tests/apply-update.test.sh` across every layout (git no-op vs fast-forward, marketplace scope resolution, copy/unknown, cwd-independent self-location) plus the never-force guarantee.

### Changed

- **Phase-1 "update" is now auto-apply, not a manual instruction.** When the per-run version check finds a newer version, the option is relabeled **"Update it for me (auto-apply)"**; choosing it runs `apply-update.sh` and then asks you to **restart** the session (a restart is required — hooks load at session start and a marketplace update only *stages* the new version, so a same-session re-invoke would reload nothing and re-offer the update in a loop). The branch is fail-open: if the updater can't be located or exits nonzero, it falls back to printing the manual `/plugin update …` command, exactly as before.
- **Version-notice text advertises auto-apply.** `check-version.sh` (both the SessionStart JSON and the `--plain` per-run modes) now says the next run can auto-apply the update, keeping the explicit `/plugin update …` command as a fallback. Detection logic is unchanged; the `--plain` contract (one line when behind, empty otherwise) is preserved.

## [0.1.12]

Fixes a false-positive that blocked commits from a worktree-isolated run — the exact failure mode the unconditional-worktree-isolation feature (0.1.9) made the default path.

### Fixed

- **Worktree-isolated runs are no longer misjudged by the enforcement-spine hooks.** All four hooks that resolve per-branch `.auto-task/` state (`enforce-gates.sh`, `warn-checkout-drift.sh`, `prevent-mid-protocol-stall.sh`, `inject-history-reminder.sh`) derived the project root from `CLAUDE_PROJECT_DIR`, which the harness keeps pinned to the **main checkout** even when the session runs inside a linked worktree. A `git commit` in the worktree therefore lands on the worktree's branch, but the hooks inspected the main checkout's branch + `.auto-task/`. When main sat on a branch with no active run while *other* branches had active runs, `enforce-gates.sh` fired a bogus **checkout-drift block** and refused the commit; `warn-checkout-drift.sh` spammed a false drift warning on every command; `prevent-mid-protocol-stall.sh` failed open, **silently disabling the anti-stall backstop** for the whole run; and `inject-history-reminder.sh` reported the wrong branch's (or no) read-before-review reminder. Each hook now detects when the operation's real cwd (from the payload's `.cwd`, falling back to `$PWD`) is a **linked worktree of the same repo** and retargets to it. Same-repo worktrees are distinguished from nested/embedded repos by the git common-dir (a linked worktree *shares* it; a nested repo has its own), normalised with `cd`-into + `pwd -P` so a relative `.git`, an absolute worktree path, and the macOS `/var`→`/private/var` symlink all compare correctly. Nested/embedded repos are never retargeted, preserving the no-fail-open guarantee for them.

## [0.1.11]

Adds **decision weighting** to the Phase-1 Clarifications gate, so the consequential calls auto-task makes on the user's behalf surface at approval instead of hiding in a flat list.

### Added

- **Decision weighting + Decision watchlist.** Every *Resolved* clarification (a decision auto-task made itself, backed by a cite) is now scored on two 0–2 axes: **Confidence (C)** — strength of the evidence — and **Cost-if-wrong (K)** — reversibility × blast radius, judged per-decision using the same dimensions as the Difficulty/Risk rubric. Decisions where `K == 2`, or where `K == 1` and `C <= 1`, are promoted into a new **Decision watchlist** rendered in `PLAN.md`'s `## Clarifications` and surfaced at the approval gate beside the risk disclaimer, each carrying *If wrong* / *Unwind* lines. This makes a thinly-cited or hard-to-unwind call visible for veto even though it had a cite — while cheap, well-cited, reversible decisions stay silent (no added burden). The watchlist is a **view over Resolved**, not a new bucket: the cite-or-ask binary and the "no third bucket" invariant are unchanged. Truly irreversible or external-write decisions still route to **Asked** (the user overrides before they happen) and never appear on the watchlist. The `define-clarify` state entry now records `weight: {c,k}` and a `watchlisted` flag.

## [0.1.10]

Fixes the per-run version check, which silently skipped on **every** run.

### Fixed

- **Per-run version check now actually runs.** Phase 1 located the checker only via `${CLAUDE_PLUGIN_ROOT}/hooks/check-version.sh`, but `CLAUDE_PLUGIN_ROOT` is exported only to *hooks* — it is empty in the Bash-tool environment where the skill's per-run check executes. The path resolved to a bare `/hooks/check-version.sh` that never existed, so the check hit its fail-open "not at the expected path → skip silently" branch on every run and no update notice ever appeared. The locate step now discovers `check-version.sh` without relying on that env var: it probes the marketplace cache (newest installed version dir) and the `install.sh` symlink layout (resolving `~/.claude/skills/auto-task` back to the repo root), still failing open if none are found. The `check-version.sh` script itself was correct and is unchanged.

### Added

- **`install.sh` and `settings-fragment.json` now wire the `SessionStart` version-check hook.** The offline/symlink install path previously emitted only the `PreToolUse` and `Stop` hooks, so `install.sh` users never got the session-start "newer version available" notice (marketplace installs got it via `hooks/hooks.json`). Both now include the `SessionStart` → `check-version.sh` entry.

## [0.1.9]

Worktree isolation is now **unconditional** and based on a **fresh default branch** — the last gap that let same-repo parallel runs interfere is closed, with zero user action.

### Changed

- **Every new-description run isolates, from any branch.** Previously auto-worktree only kicked in on `main`/`master` starts; a run launched on a prepared feature branch ran in the shared checkout and relied on the checkout-drift lock. Now Phase 1 forks a fresh `<type>/<slug>` branch for **every** run regardless of the current branch, and always in its own git worktree. Two parallel runs can no longer fight over one working tree.
- **Runs fork from the repo's default branch (`main`/`master`), not the current HEAD.** The default branch is resolved (`git symbolic-ref refs/remotes/origin/HEAD`, else local `main`/`master`), best-effort fetched (`git fetch origin <default>`, fail-open when offline), and the worktree is created from that ref (`git worktree add … -b <branch> <default-ref>`). Every run therefore starts from a clean, current base and never inherits the current checkout's branch identity or uncommitted WIP. Consequence: a run started on a feature branch forks fresh from the default rather than continuing that branch — to base a run on specific work, prepare a worktree by hand and run `/auto-task` inside it.
- **`marketplace.json` version corrected.** It was stuck at `0.1.5` while `plugin.json` advanced; both are now `0.1.9` and kept in lockstep.

### Added

- **Already-inside-a-worktree detection.** When the session is already in a linked worktree (`git rev-parse --git-dir` ≠ `--git-common-dir`), the run stays in place instead of nesting a second worktree — preserving the hand-made-worktree workflow.
- **Collision-safe naming.** Branch name AND worktree directory are both disambiguated (`-2`/`-3`…) before creation, so two runs with the same-slugified description never collide back onto a shared branch/checkout.
- **Resume never forks.** A resume (`/auto-task` no args) re-enters its existing worktree keyed by `state.branch`; isolation is a new-run action only.

### Docs

- `skills/auto-task/SKILL.md` (Phase 1 branch-setup rewritten), `ARCHITECTURE.md` (Phase 1 diagram box + "Parallel runs" section), and `README.md` ("Running multiple runs in parallel") all updated from *automatic-on-main/master* to *unconditional, from a fresh default branch*.

### Fixed

- The checkout-drift guard is now correctly framed as protecting only the in-place fallback path (the sole remaining shared-checkout case), not "prepared feature branch" runs (which now isolate).

## [0.1.8]

Automatic worktree isolation for parallel runs + a checkout-drift guard. Same-repo parallel `/auto-task` is now fully automatic instead of requiring you to hand-create a worktree first.

### Added

- **Automatic worktree isolation (new-branch runs).** Phase 1 branch setup no longer `git switch -c`s the shared checkout when you start on `main`/`master`. It now creates the run its own git worktree — `git worktree add .claude/worktrees/<type>-<slug> -b <branch> HEAD` (base pinned to the local HEAD so the `base = git rev-parse HEAD` contract holds regardless of the user's `worktree.baseRef` git config) — and relocates the session into it with the harness `EnterWorktree` tool. Parallel runs in one repo are now safe out of the box: each new-branch run gets its own working tree, the original checkout stays free, and git forbids two worktrees on one branch so they can't collide. If the current branch is anything other than `main`/`master`, the prepared checkout is respected and the run stays in place (auto-worktree only on the new-branch path). Ordered fallback with orphan-cleanup when `EnterWorktree`/`git worktree add` is unavailable or fails: undo any half-created worktree, then `git switch -c` in place. The auto-created worktree is KEPT on disk after the run (Phase 5 never removes it); prune manually with `git worktree remove`. Also excludes `.claude/worktrees/` via the common-dir exclude so an in-repo worktree never shows as untracked in — or is staged from — the parent checkout.
- **Checkout-drift guard (protects in-place runs).** New `warn-checkout-drift.sh` (PreToolUse/Bash, informational, NEVER blocks) warns on every command when an active run exists on a branch other than the one checked out; and `enforce-gates.sh` gains a fail-closed **drift block** that stops a `git commit` in that same situation. Together they close the previous silent fail-open where the working tree was switched off an in-place run's branch (e.g. from another terminal): the branch-keyed hooks found no state for the new branch and let an ungated commit land on the wrong branch. Both are scoped to the current working tree (`.auto-task/` is per-worktree), so a parallel run in another worktree can never trigger a false positive; the warn hook stays silent and near-free in non-auto-task repos and when `jq` is absent.

### Changed

- **Hook wiring.** `warn-checkout-drift.sh` is registered as a third `PreToolUse`/Bash hook in `hooks/hooks.json`, `install.sh`, and `settings-fragment.json` (the plugin now wires five core hooks).

### Docs

- `skills/auto-task/SKILL.md` (Phase 1 branch setup + a checkout-drift-guard/worktree-lifecycle note), `ARCHITECTURE.md` (Phase 1 diagram box, new Hook 3, drift-block note on Hook 2, and the "Parallel runs" section rewritten from *one-worktree-per-run-you-set-up* to *automatic*), and `README.md` (hook list, five-core-hooks count, "Running multiple runs in parallel") all updated.

### Tests

- `tests/enforcement-spine.test.sh` expanded 38 → 45 assertions — seven new drift assertions in an isolated fixture: the enforce-gates drift block, a no-drift control, and the warn hook's behavior on drift / matching-branch / jq-absent / malformed-state / no-`.auto-task/` cases.

## [0.1.7]

### Added

- **Pre-run version check.** Before each NEW `/auto-task` run, Phase 1 now does a fresh, best-effort version check — the SessionStart `check-version.sh` gains a `--plain` output mode (a bare one-line notice instead of the SessionStart JSON), and the Phase-1 step runs it with the 24h throttle bypassed and, if the installed plugin is strictly behind upstream, **asks once** whether to update first or proceed. Fully fail-open (no `${CLAUDE_PLUGIN_ROOT}` / script missing / offline / no jq / current-or-ahead → silent proceed); bounded by the script's existing `--connect-timeout 2 -m 5`; **skipped on resume** (`/auto-task` with no args, where swapping the plugin under a mid-flight run would be wrong). The per-run check does **not** write the SessionStart throttle stamp (so it can't suppress the next SessionStart notice), and the default SessionStart JSON output is unchanged. `tests/enforcement-spine.test.sh` grows 32 → 38 (six `CV-*` assertions covering plain-vs-JSON, silent-when-current/ahead/unreachable, and stamp-untouched); README and `ARCHITECTURE.md` document it.

## [0.1.6]

Worktree safety: `/auto-task` is now safe to run inside a linked git worktree, so several runs can execute in parallel (one worktree per run). Also folds in the unreleased `DRIFT CHECKPOINT` rename.

### Fixed

- **`.auto-task/` exclusion now works in a linked worktree.** Phase-1 branch setup resolved the literal `.git/info/exclude`, which errors in a worktree (there `.git` is a *file*, not a directory), so `.auto-task/` was never excluded and could leak into `git status`. It now resolves `$(git rev-parse --git-common-dir)/info/exclude` — `.git/info/exclude` in a normal checkout, the shared common-dir exclude from any worktree (one write covers every worktree of the clone). Exclude prose aligned across `skills/auto-task/SKILL.md`, `ARCHITECTURE.md`, `auto-task-plan`, `auto-task-commit`, and `README`.
- **Gate / Stop / history hooks resolve the run's worktree, not a stale dir.** `enforce-gates.sh`, `prevent-mid-protocol-stall.sh`, and `inject-history-reminder.sh` now resolve `project_dir` as the git worktree root **of** `${CLAUDE_PROJECT_DIR:-$PWD}` (toplevel-of-base), so a commit / turn-end from a subdirectory still finds `.auto-task/<branch>/` at the top — closing a latent fail-open — while keeping an explicitly-set `CLAUDE_PROJECT_DIR` authoritative (a commit from a nested/embedded repo or submodule is not silently retargeted). Byte-identical to the old resolution on the normal-checkout happy path; only the subdir-with-`CLAUDE_PROJECT_DIR`-unset case changes (was fail-open, now enforces).

### Changed

- **`COMMIT CHECKPOINT` → `DRIFT CHECKPOINT`.** The `auto-task-implement` checkpoint markers were renamed to reflect that they are drift-check points, not commit points (only Phase 5 commits).

### Docs

- **"Running multiple runs in parallel"** added to `README` and `ARCHITECTURE.md`: one git worktree per run; state and gate/Stop enforcement are isolated per worktree.

### Tests

- `tests/enforcement-spine.test.sh` expanded 28 → 32 assertions — per-worktree / subdirectory / nested-repo state resolution for the gate and Stop hooks, each proven to discriminate the fix from a revert.

## [0.1.5]

Findings from a full read-through evaluation of the pipeline. The enforcement spine (hooks) was already covered by the test suite; these are defects in the model-facing prose that the mechanical tests could not catch.

### Fixed

- **Gate B no longer reviews an empty diff.** The Gate B spawn prompt handed the adversarial `task-execution-verifier` `git diff <base>...HEAD`, but the single-commit rule means nothing is committed until Phase 5 — so at Gate B `HEAD == base` and that diff was **empty**. The adversarial pass (the strongest gate for STANDARD/HEAVY tasks) saw no code and trivially succeeded. It now uses `git diff <base>` (the uncommitted working tree), matching Phase 3 and Gate A; the verifier agent's input doc was corrected to use the working-tree diff for both gates and to treat a `..HEAD`/`...HEAD` form as a bug to fall back from.
- **Removed a self-contradicting operating principle.** SKILL.md's "Commit after each phase" operating principle contradicted the NON-NEGOTIABLE single-commit rule (only Phase 5 commits) and the `enforce-gates.sh` hook that backs it. It now states the single-commit behavior and attributes durability/resumability to the on-disk `STATE.json`, not to intermediate commits.

### Changed

- **The bundled siblings now implement the read-before-review contract themselves.** `auto-task-code-review`, `auto-task-verify`, and `auto-task-fix` now read `.auto-task/<branch>/` history (CONTEXT.md, TRACE.md, STATE.json) before forming findings — so they don't re-litigate settled Human choices or miss an issue an earlier pass left open — and append a standalone `TRACE.md` entry on completion. The append is **suppressed under `/auto-task` orchestration** (the orchestrator owns TRACE writes; a sibling append would double-write the log), mirroring the existing caller-note pattern. Each references the orchestrator's canonical TRACE.md format rather than duplicating it. Previously this behavior lived only in the orchestrator and the verifier agent.

### Docs

- **`.auto-task/<branch>/fixes/` is now in the canonical layout.** The orchestrator's branch-setup `mkdir` and both of SKILL.md's layout enumerations omitted `fixes/`, which `auto-task-fix` writes patch notes to and `auto-task-plan` / `auto-task-implement` / `auto-task-code-review` read; `ARCHITECTURE.md` already listed it. SKILL.md now creates and documents it, so all four layout enumerations agree.

## [0.1.4]

### Fixed

- **Review-staleness hash is now config-stable.** `enforce-gates.sh` pins the diff flags (`--no-color --no-ext-diff --no-textconv --no-renames --diff-algorithm=myers --src-prefix=a/ --dst-prefix=b/`) when computing `git diff <base> | git hash-object`. Without them, a user's git config (`diff.algorithm`, `diff.renames`, `diff.noprefix`, `color`, textconv, external diff) could shift the diff text and produce a spurious staleness block on an unchanged tree. The skill records `reviewed_diff_sha` with the same flags. Validated by the test suite under a hostile git config.
- **Raw-mode commit detection no longer over-blocks.** When `jq` can't decode the payload, `enforce-gates.sh` previously treated any Bash command merely *mentioning* "git commit" (e.g. `echo see the git commit guidelines`) as a commit and blocked it during an active run. The raw-JSON regex now requires `git commit` at a command boundary (start, a shell separator, or the JSON value's opening quote), keeping the fail-closed bias only for the genuinely-ambiguous case.
- **Stop hook can no longer soft-lock a session.** `prevent-mid-protocol-stall.sh` now keeps a consecutive-block counter keyed on the run's progress signature. While the run advances the counter resets and blocking continues as designed; if the run is frozen in the exact same state for `AUTO_TASK_STALL_LIMIT` (default 25) turn-ends, the hook releases the stop with a warning so a genuinely-stuck run stays recoverable.
- **`check-version.sh` no longer risks a network call on every session.** When `CLAUDE_PLUGIN_DATA` is unset the 24h throttle stamp now falls back to a temp dir (previously the throttle was skipped entirely, re-firing the `curl` each session). Added `--connect-timeout 2` to bound the worst case on an unreachable host.

### Changed

- **`install.sh --uninstall` now reports copy-mode leftovers.** Files installed with `--copy` (real files, not symlinks) are never auto-deleted, but uninstall now lists them with `rm -rf` suggestions instead of silently leaving them.

### Docs

- Fixed an incorrect branch-path example in `skills/auto-task/SKILL.md` (`fix/foo` maps to `.auto-task/fix/foo/`, not `.auto-task/auto-task-fix/foo/`).
- README Status now reflects the current version.
- Test suite expanded from 19 to 28 assertions: raw-mode commit detection, the Stop-hook stall-breaker, and the AI-attribution hook are now covered.

## [0.1.3]

### Changed

- **`hooks/check-version.sh` now compares versions in pure bash** instead of `sort -V`. This fixes two edge cases: (1) hosts whose `sort` lacks `-V` (e.g. BusyBox) no longer silently disable the notice for the wrong reason, and (2) SemVer prerelease/build strings are handled correctly — an upstream `0.2.0-beta` of the same core as your release no longer triggers a spurious "update available" notice, while a real release upgrade over a local prerelease still does. Build metadata (`+...`) is ignored; any parse ambiguity stays silent (fail-safe).

## [0.1.2]

### Fixed

- **Update command uses the marketplace-qualified plugin name.** The SessionStart notice (`hooks/check-version.sh`) and README now tell users to run `/plugin update auto-task@auto-task-plugin`; the bare `/plugin update auto-task` fails with "Plugin not found" (the `update` resolver requires the `@marketplace` qualifier, even though `install`/`details` accept the bare name).

## [0.1.1]

First version that is actually installable as a marketplace plugin (the v0.1.0 manifest failed `claude plugin validate` with 4 errors).

### Added

- **`.claude-plugin/marketplace.json`** — the repo is now its own single-plugin marketplace (`source: "./"`), installable with `/plugin marketplace add o8o0o8o/auto-task-plugin` + `/plugin install auto-task@auto-task-plugin`.
- **`hooks/hooks.json`** — plugin-native hook wiring (event map nested under the top-level `hooks` key) that auto-wires `block-ai-attribution`, `enforce-gates`, `prevent-mid-protocol-stall`, and the new SessionStart notice via `${CLAUDE_PLUGIN_ROOT}`. No `settings.json` editing required on install.
- **`hooks/check-version.sh`** — SessionStart update notice. Compares the installed version against the published `plugin.json` on GitHub at most once per 24h (cached in `${CLAUDE_PLUGIN_DATA}`) and prints a one-line `/plugin update auto-task@auto-task-plugin` reminder when behind. Fails open and silent on every error path (no jq/curl, offline, malformed, current/ahead).

### Changed

- **`.claude-plugin/plugin.json`** — rewritten to a spec-valid manifest (object `author`; dropped the invalid array `skills`/`agents`/`hooks` and the unrecognized `comment`/`requires` fields — components are auto-discovered). Plugin renamed to `auto-task`, so skills invoke as `/auto-task:auto-task` under a marketplace install.
- **`README.md`** — the marketplace flow is now the primary documented install; `install.sh` is demoted to the offline/dev fallback. Corrected the prerequisites list and the sibling-skill namespacing note.
- **`skills/auto-task/SKILL.md`** — component-preflight now documents that siblings are namespaced (`auto-task:<name>`) under a marketplace install and bare under the `install.sh` fallback; the orchestrator invokes whichever form is registered.
- **`settings-fragment.json`** — relabeled fallback-only; replaced the non-existent `${CLAUDE_PLUGIN_DIR}` (and the non-expanding `${CLAUDE_PLUGIN_ROOT}`) with an explicit absolute-path placeholder, since plugin path variables do not expand in a hand-merged `settings.json`.

## [Unreleased] — v0.1.0 (pre-release)

Initial extraction of the `auto-task` skill from `~/.claude/skills/auto-task/` into a self-contained, shareable Claude Code plugin. See `PACKAGING_PLAN.md` for the open work items that remain before a real v0.1.0 release.

### Added

- **Phase 1 approach selection (`auto-task` v1.6).** Before the detailed plan is written, the pipeline now decides *which* approach to plan when more than one materially-different implementation exists (the choice changes blast radius, risk, dependencies, API shape, or migration cost). It generates 2–3 short candidate sketches (inline for simple-but-branching tasks; parallel `general-purpose` agents from distinct angles for complex/high-risk ones), scores them on fixed dimensions, and selects. Clear winners are auto-selected; close calls and high-stakes choices (schema/data, external API, auth/payments) fold into the existing Phase 1 `AskUserQuestion` gate rather than adding a new interaction. The decision — chosen approach plus rejected candidates with rejection rationale — is recorded in `PLAN.md`'s new `## Approach` section, in `state.history` (`define-approach`), and in the CONTEXT.md handover. Closes the "wrong-approach-entirely plan sails through approval" gap: the pipeline previously only verified that the first approach the model landed on was *built correctly*, never whether a *better* approach existed.
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

- **Phase 1 critique is now a bounded re-plan loop, not advisory-only (`auto-task` v1.6).** Previously the critique agent's output was appended to `PLAN.md` with an explicit "do NOT auto-amend" instruction — the user had to mine the bullet list for what mattered and request edits manually. Now each finding is classified **structural-fixable** (a plan defect resolvable without the user: missing edge case, omitted blast-radius file, non-falsifiable AC, missing rollback step) or **judgment-required** (a tradeoff/scope call). Structural findings are auto-amended and the critique is re-run on the revised plan (cap: LIGHT 1 round, STANDARD/HEAVY 2), mirroring the global "re-invoke code-review after every fix" rule. The `## Critique` section now has two parts — **Auto-fixed** and **For your judgment** — so the approval gate shows a repaired plan plus only the genuine judgment calls. Logged per round to `state.history` (`define-critique`).
- **`prevent-mid-protocol-stall.sh` now fails closed on a missing/null `expected_next_action` mid-run.** Previously an unset or `null` field allowed the stop, contradicting the skill's own stated default ("writing post-approval state without an explicit choice keeps the turn alive is the correct failure mode"). Now, once past the `approved`/`done` guards, only the two explicit user-gate values allow a stop; anything else — including a forgotten field — blocks. `SKILL.md`'s hook-behaviour spec was reconciled to match.
- **`base` is now defined as HEAD at run start** (the fork point for a new branch, the current tip for a reused one), making `git diff <base>` exactly this run's work for the change diagram, verifiers, and staleness hash. Documented the pre-existing-uncommitted-changes caveat. (Replaces the earlier, ambiguous "merge-base against default for reused branches" wording.)
- **`ARCHITECTURE.md` no longer claims the plugin ships `git push` deny / `gh pr create` ask permissions** — it doesn't. Reframed as opt-in recommended permissions, with the Phase 5 skill prompt as the actual shipped gate.
- **Hooks now fail safe instead of fail-open.** All three hooks dropped `set -e` (a stray non-zero from `jq` on malformed/partial JSON previously crashed the script into a fail-open exit) in favour of `set -uo pipefail` with individually guarded reads. Failure direction is now chosen per hook by recoverability (see the dedicated note below): `enforce-gates.sh` fails **closed** (blocking one commit can't loop); `prevent-mid-protocol-stall.sh` fails **open** (an unrecoverable block would soft-lock the session). Both still allow freely when no run is active, so unrelated repos and commits are unaffected. `block-ai-attribution.sh` now also works without `jq` by scanning the raw payload, so a missing `jq` can't let an attribution marker slip through.
- **`prevent-mid-protocol-stall.sh` fails OPEN (not closed) when it can't read state.** Verified against the Claude Code hook spec: Stop hooks have **no built-in loop protection** and no `stop_hook_active` signal, so an unconditional block soft-locks the session — and a `jq`-missing block in particular can't be cleared mid-session. The hook now blocks only on positive, readable evidence the model should continue (a valid STATE.json saying so); when `jq` is missing or STATE.json is unparseable it **allows the stop and warns**. This corrects the earlier (over-eager) decision to fail this hook closed. Commits stay gate-blocked regardless, so allowing a stop is recoverable and harmless; a wrongful block was not. Confirmed the `{"decision":"block","reason":…}` + exit 0 contract is correct, and that `"matcher": ""` is the right registration for Stop hooks.
- **`enforce-gates.sh` now enforces review staleness.** The gate booleans (`code_review.passed`, `clean_pass_after_last_fix`) are values the model sets for itself. The hook now also binds them to the actual code: on a clean review the orchestrator records `gates.code_review.reviewed_diff_sha = git diff <base> | git hash-object --stdin`, and the hook recomputes that hash at commit time and blocks if it differs — catching the common failure mode of editing code after the review went clean and committing without re-review. Backward-compatible: the check is skipped when `state.base` or `reviewed_diff_sha` is absent, so it can only add a block, never spuriously allow. New state fields: `base` (base-commit SHA) and `gates.code_review.reviewed_diff_sha`. `expected_next_action` also added to the `ARCHITECTURE.md` schema (it was already in `SKILL.md`).

### Fixed

- **Reconciled the sibling skills' standalone gates with the orchestrator's NON-YIELDING CONTRACT.** Only `auto-task-code-review` carried the protective "Caller note" that tells an orchestrator the skill's output is INPUT (not an end-of-turn); the other five still contained standalone stops that, taken literally during a run, break the "one human gate" guarantee: `auto-task-fix`'s "STOP for user approval" + a Phase 5 reviewer-agent spawn, `auto-task-commit`'s "Commit with this message? Yes/Edit/Cancel" prompt, `auto-task-implement`'s "Stop and wait for the user" at checkpoints, and `auto-task-plan` / `auto-task-verify`'s user-directed asks/suggestions. Added a conditional caller note to each: under orchestration the standalone gate is suppressed and control returns to the caller; run directly by a human, the gate behaves as before. Also pointed `auto-task-fix`'s standalone Phase 5 review at the `auto-task-code-review` skill instead of a hand-rolled `general-purpose`/`code-reviewer` agent.
- **Completed the `.patches/` → `.auto-task/<branch>/` migration across all six bundled sibling skills and `ARCHITECTURE.md`.** Previously only the orchestrator `SKILL.md` and `enforce-gates.sh` had been migrated; the siblings still read/wrote `.patches/`, which is not in `.git/info/exclude` and not pre-stage-cleaned — so harness scratch could leak into commits. The siblings now resolve everything under the gitignored `.auto-task/<branch>/` root.
- **`auto-task-commit` no longer instructs the model to commit harness files.** The rule "If `.patches/` files are in the diff, include them" directly contradicted the orchestrator's "never commit `.auto-task/`" invariant; it is replaced with an explicit unstage-and-warn rule.
- **Corrected the branch-path examples in `SKILL.md`** (`fix/auth-bug` → `.auto-task/fix/auth-bug/`, not the namespacing-mangled `.auto-task/auto-task-fix/auth-bug/`). A divergent path makes the gate and Stop hooks find no state file and fail open. Added an explicit note that the folder name must match `git branch --show-current` verbatim.
- **`ARCHITECTURE.md`** state-file path, filename (`STATE.json`, not `AUTO-TASK-STATE.json`), on-disk layout, and `gates.code_review.tool` value (`skill:auto-task-code-review`) brought back in sync with `SKILL.md` and the hooks.

### Added

- **`tests/enforcement-spine.test.sh`** — the plugin's first automated integration test. Drives a real `STATE.json` through the full documented phase/gate lifecycle (STANDARD + LIGHT tiers) in a throwaway repo and asserts the real hooks behave correctly at every transition: commit blocked until gates pass, tier-specific Gate B requirement, review-staleness (post-review edit re-blocks, revert clears), wrong-review-tool block, every Stop-hook yield/block decision, and the fail-open/fail-closed edges. 19 assertions, all passing. Covers the mechanical state-machine↔hooks contract (not model-follows-prose, which still needs a live run).
- **Component preflight in Phase 1.** Before any git work, the orchestrator confirms all six sibling skills and the `task-execution-verifier` agent are available, and STOPs with an install pointer if any is missing — instead of silently substituting a hand-rolled component and breaking the pipeline's guarantees. Re-runs on resume.
- **Optional recommended-permissions block** in `settings-fragment.json` (inert `_optional_recommended_permissions` key) — copy-pasteable `deny git push` / `ask gh pr create` defence-in-depth for the Phase 5 push, documented as opt-in in the README and `ARCHITECTURE.md`.
- `hooks/inject-history-reminder.sh` — the optional `UserPromptSubmit` hook referenced (but previously missing) in `settings-fragment.json`. Informs the session when `.auto-task/<branch>/` history exists so any reviewer honours the read-before-review contract. Off by default.

### Known issues

- `task-execution-verifier` agent has a real prompt but has not yet been exercised end-to-end inside a real auto-task run — treat Gate A/B as functional but not battle-tested.
- Plugin manifest field names not verified against the current spec (the canonical install path is `install.sh`, not `/plugin add`, so the manifest is currently informational). _Resolved in 0.1.1 — the manifest is now spec-valid and the marketplace install is the primary documented path._
- Bundled sibling skills now share the orchestrator's `.auto-task/<branch>/` working-directory convention, but their richer read-before-review behaviour (reading CONTEXT.md / TRACE.md, appending trace entries) still lives mostly in the orchestrator and the verifier agent rather than in each sibling. _Resolved in 0.1.5 — the three audit siblings (`auto-task-code-review`, `auto-task-verify`, `auto-task-fix`) now implement the contract directly._
- `enforce-gates.sh` path resolution: assumes `CLAUDE_PROJECT_DIR` is set to the repo root (or falls back to `$PWD`). Verify this environment variable is provided by the Claude Code hook context. _Resolved in 0.1.6 — all three hooks now resolve `project_dir` as the git worktree root of `${CLAUDE_PROJECT_DIR:-$PWD}`, robust to an unset/misset `CLAUDE_PROJECT_DIR`, subdirectories, and linked worktrees._
