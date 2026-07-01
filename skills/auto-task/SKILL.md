---
name: auto-task
description: End-to-end autonomous task workflow — define → execute → verify → review → handover. One human gate in Phase 1 (clarifying Q&A + plan approval); everything after runs unattended until success, a hard blocker, or test flakiness. Use when asked to "auto", "auto-task", "run the whole thing", or when the user wants a task taken from description to PR with no intermediate stops.
license: MIT
metadata:
  author: ai-workflow
  version: "1.6"
---

# Auto-task

Autonomous pipeline that takes a task description from intake to pull request. Composes existing skills (`auto-task-plan`, `auto-task-implement`, `auto-task-verify`, `auto-task-code-review`, `auto-task-commit`) and `task-execution-verifier` agent passes around them.

## NON-YIELDING CONTRACT (read first — the highest-priority rule in this skill)

Phase 1 contains the **only** human-interaction surface in the entire pipeline. It has two parts that the user sees: (1) a single batch of clarifying questions presented up-front via `AskUserQuestion`, and (2) plan approval at the end of Phase 1. Both happen inside Phase 1 — there is no second human gate later.

After the user types `approved` / `looks good` / `proceed` / `yes` / `go ahead` at the Phase 1 plan gate, the pipeline runs to one of two terminal states **without stopping for the user**:

- **Success:** Phase 5 completes (commit landed + PR open OR explicit user choice to hold the push at the final handover prompt).
- **Hard stop:** a Loop-rule trigger fires (no-progress, out-of-scope, external blocker, test flakiness) per the "Surfacing protocol" below.

There are NO other legitimate stopping points between plan approval and Phase 5. In particular:

- A sub-skill (`auto-task-plan`, `auto-task-implement`, `auto-task-verify`, `auto-task-code-review`, `auto-task-commit`) returning a structured report is **INPUT**, not an end-of-turn. Parse it, act on it, continue.
- A verifier agent (`task-execution-verifier` at Gate A or Gate B) returning findings is **INPUT**. Apply fixes (Blocker/Required) or park (Follow-up), then continue.
- A green check from `/auto-task-verify` advances to Gate A. Continue.
- A clean `auto-task-code-review` pass (no Blockers/Required) advances to Gate B (or Phase 5 for LIGHT tier). Continue.
- A "No adversarial findings." from Gate B advances to Phase 5. Continue.
- Phase 5's gate-precheck passing advances to commit. Continue.
- A successful commit advances to push. Continue.
- Output-formatting cues that LOOK like end-of-turn — "Verdict:", "Summary:", a Markdown horizontal rule, a heading-shaped final line, a turn-final blank line, a checklist that has all items ticked — are **paragraph formatting**. They are not interaction points. Do not stop.

**The only sub-skill/sub-agent return that's allowed to end your turn is `auto-task-commit` after a successful push and `gh pr create` (Phase 5 final).** Everything else feeds the next step.

If you find yourself about to write a recap, a "next steps" summary, a "ready for your review" line, or any sentence that addresses the user in the second person mid-pipeline — STOP TYPING and instead make the next tool call. Recaps are for the post-Phase-5 message, not for mid-pipeline.

The single exception during Phase 5: pushing to remote and opening a PR are externally-visible actions per the "Executing actions with care" guideline in `~/.claude/CLAUDE.md`. You MAY ask once whether to push / push-and-PR / hold before the network call — and only that one prompt. Everything before that step still runs without asking.

**Mechanical backstop.** The textual contract above is paired with a `Stop` hook (shipped in the plugin's `settings-fragment.json`) that reads `expected_next_action` from STATE.json and **blocks the model's turn from ending** when the field says `"auto-continue"`. The hook is the antidote to completion-shaped sub-skill output fooling the model into stopping. The contract is: at every state write, set `expected_next_action` to one of `auto-continue` / `user-approval` / `user-push-prompt` / `null` per the "Yield-point contract" section below. The default is `"auto-continue"` — if you write state without an explicit choice, the hook will keep the turn alive, which is the correct failure mode.

## Operating principles

- **One human gate.** The plan produced in Phase 1 is the contract. After the user approves it, do not stop for confirmation — proceed through Execute → Verify → Review → Handover automatically.
- **Surface only when the loop rule says to.** See "Loop rule" below. Never invent new stops outside that rule.
- **Single commit at handover.** Phases 2 through Gate B make NO commits — all changes accumulate as one growing uncommitted diff against the branch base, and only Phase 5 commits, after every required gate has passed (see the "Single-commit rule" below, mechanically enforced by the pre-commit hook). Durability and resumability come from `.auto-task/<branch>/STATE.json` on disk, not from intermediate commits.
- **`.auto-task/` is the persistent local history root — gitignored, NEVER committed.** Layout: `.auto-task/<branch-name>/` per run, where `<branch-name>` mirrors the git branch path verbatim (so branch `fix/auth-bug` → `.auto-task/fix/auth-bug/`). Inside each per-run folder:
  - `STATE.json` — the run-state machine ([[state-file-schema]]).
  - `PLAN.md` — the approved plan + approach decision log + critique + AC pre-flight + recon.
  - `CONTEXT.md` — generated at Phase 5; carries task, human choices, AC results, verification trail, drift events, change diagram, follow-ups. The handover artifact for downstream reviewers (human, `/auto-task-code-review`, `/review`, future `/auto-task` runs touching the same area).
  - `TRACE.md` — append-only log of every operation that touched this branch (auto-task phases AND external tool runs like a later `/auto-task-code-review` session). See the "Persistent history & trace contract" section.
  - `recon/` — Phase 1 reconnaissance outputs (screenshots, fetched docs, change-diagram source).
  - `fixes/` — per-fix patch notes written by `auto-task-fix` (root cause + lesson per fix), read by later plan / implement / code-review steps to avoid repeating earlier mistakes on this branch.
  - `artifacts/` — proofs of completion (test output logs, screenshots confirming the fix, build logs, diff snapshots, command transcripts). Reviewers verify "the fix actually works" by reading these without needing to re-run the run.

  None of this lands in the git index. On branch setup, append `.auto-task/` to the repo's exclude file — resolve it as `$(git rev-parse --git-common-dir)/info/exclude` (that is `.git/info/exclude` in a normal checkout, and the shared common-dir exclude from any linked worktree, where `.git` is a file not a directory) — so it's ignored per-clone (do not modify the repo's `.gitignore` — that's a shared file). Before every `git commit` (including the `auto-task-commit` skill), defensively unstage any `.auto-task/` paths: `git restore --staged .auto-task/ 2>/dev/null || true`. If `git status` after staging shows anything under `.auto-task/`, that's a bug — fix it before committing.
- **State on disk.** Maintain `.auto-task/<branch>/STATE.json` so the workflow can be interrupted and resumed via `/auto-task` with no arguments. It lives locally only — see the rule above.
- **No scope creep.** Every change must trace to the approved plan's Acceptance Criteria. Out-of-scope findings get parked as follow-ups, not implemented.
- **Evidence at every transition.** The plan gets critiqued before approval; the execution diff is checked against blast radius at every commit; the PR carries an audit trail of judgment calls so the run is reviewable without replaying it.

## Loop rule (the only exit conditions)

Continue iterating while ALL of these hold:

1. **Progress** — each iteration makes measurable progress versus the previous one (fewer failing checks, fewer review findings, or net-new code that addresses a finding). Two consecutive iterations with no measurable progress → STOP and surface.
2. **In-scope** — remaining issues map to the approved Acceptance Criteria. Out-of-scope finding → STOP and surface.
3. **Unblocked** — no external blocker (missing credentials, broken infra, design decision the plan didn't cover, third-party outage). Blocker → STOP and surface.
4. **No test flakiness** — every test failure is reproducible. Any flake (test fails then passes on retry without code change, or fails non-deterministically) → STOP and surface.

Exit the loop successfully when:
- All `/auto-task-verify` checks pass.
- The most recent `task-execution-verifier` agent says DoD satisfied.
- The most recent `auto-task-code-review` produces only follow-ups (no blockers, no required fixes).

There is no fixed numeric cap on iterations — caps are set by the current effort tier (see below) and can rise when the tier escalates.

## Effort tiers

Define-phase scoring (see Phase 1 rubric) produces Difficulty (D) and Risk (R), each 0-8. The tier is `max(D, R)` bucketed:

| Tier     | Range | `/auto-task-verify` scope                                  | Fix-loop cap | Gate B                          |
|----------|-------|--------------------------------------------------|--------------|---------------------------------|
| LIGHT    | 0-2   | types + unit                                     | 2            | skipped (Gate A only)           |
| STANDARD | 3-5   | types + unit + lint                              | 4            | run                             |
| HEAVY    | 6-8   | types + unit + lint + build (+ e2e if touched)   | 6            | run, with cross-check pass      |

- Tier does NOT change which model is used — model selection stays with the user. The pipeline only adjusts verification scope, loop budget, and gate intensity.
- Effort can only **escalate**. Auto-de-escalation is forbidden — the user can downshift manually by editing PLAN.md's `Effort:` line and re-running.
- Every tier change writes an entry to `effort.history` in state with `{from, to, reason, at}`.

## Inputs

- `/auto-task <description>` — start a new run. `<description>` is the task to solve.
- `/auto-task` (no args) — resume an existing run from `.auto-task/<branch>/STATE.json`. If no state file exists, tell the user to provide a description.

## State file

`.auto-task/<branch>/STATE.json`:

```json
{
  "phase": "define|execute|self-verify|gate-a|review|gate-b|handover|done",
  "expected_next_action": "auto-continue|user-approval|user-push-prompt|null",
  "approved": true,
  "description": "<verbatim task input from /auto-task argument>",
  "branch": "<branch name where the run lives>",
  "base": "<base-commit SHA captured at branch setup — the point the branch forked from>",
  "effort": {
    "tier": "light|standard|heavy",
    "difficulty": 0,
    "risk": 0,
    "history": [
      { "from": "standard", "to": "heavy", "reason": "schema migration not in initial blast radius", "at": "ISO-8601" }
    ]
  },
  "iteration": { "review": 0, "fix": 0 },
  "history": [
    { "phase": "self-verify", "result": "fail", "summary": "2 tests failing", "at": "ISO-8601" }
  ],
  "gates": {
    "self_verify": { "passed": false, "at": null, "evidence": null },
    "gate_a":      { "passed": false, "at": null, "evidence": null },
    "code_review": { "passed": false, "tool": null, "clean_pass_after_last_fix": false, "reviewed_diff_sha": null, "at": null, "evidence": null },
    "gate_b":      { "passed": false, "at": null, "evidence": null, "skipped_reason": null }
  },
  "followups": [
    { "source": "code-review", "note": "Consider extracting X helper", "at": "ISO-8601" }
  ],
  "pr_url": null
}
```

Update this file at every phase transition and at the end of every loop iteration.

### Yield-point contract (mechanical anti-stall enforcement)

The NON-YIELDING CONTRACT at the top of this skill is text. Models reliably violate it when sub-skill output looks completion-shaped ("Verdict:", horizontal rules, headed sections). The `expected_next_action` field is the mechanical backstop — paired with a `Stop` hook that **blocks** the model's turn from ending when the field says auto-continue.

`expected_next_action` MUST be one of these four values at all times after `approved: true`:

| Value | Semantics | When set |
|---|---|---|
| `"auto-continue"` | Pipeline is mid-flight; the model MUST make the next tool call. Stop hook blocks any attempt to end the turn. | The default for every non-terminal transition. Set this whenever you advance a phase, complete a sub-skill, finish a verifier agent, apply a fix, or set a gate. |
| `"user-approval"` | A legitimate human gate. Stop hook allows. | Phase 1 plan-presentation point (before user types `approved` / `proceed`). Loop-rule surface (when the Surfacing protocol fires). |
| `"user-push-prompt"` | The single allowed Phase 5 push/PR/hold prompt. Stop hook allows. | Just before the `git push` / `gh pr create` permission ask in Phase 5. |
| `null` | Pre-approval or terminal state. Stop hook allows. | While `approved: false` (Phase 1 setup, before user approves) OR after `phase: "done"`. |

Set the field as part of EVERY state write — no exceptions. The discipline is: when you write `phase`, `gates.*`, `iteration.*`, or any history entry, also write `expected_next_action`. Default to `"auto-continue"` and only set the user-* values at the three legitimate yield points.

The Stop hook reads `STATE.json` on every Stop event:

- `phase === "done"` → allow stop.
- `approved !== true` → allow stop.
- Otherwise (run is mid-pipeline) → allow only when `expected_next_action ∈ {"user-approval", "user-push-prompt"}`. **Every other value — `"auto-continue"`, an unknown string, or an unset/null field — blocks.** A missing field is treated as auto-continue (fail closed): per the default rule above, writing post-approval state without an explicit choice keeps the turn alive, which is the correct failure mode. `null` is only legitimate while `approved: false` or after `phase: "done"`, both of which are already handled by the two guards above — so a null encountered mid-pipeline means the field was not set and the hook blocks.

The hook is shipped in the plugin's `settings-fragment.json`. Without it, the field is informational; with it, the field is enforced. Both must be aligned — never set `"user-approval"` speculatively to "escape" the hook, because that defeats the entire mechanism. The pre-commit hook for gates is the analogous precedent: don't flip flags speculatively.

**Setting the value at each phase / transition:**

| Transition / phase point | Set `expected_next_action` to |
|---|---|
| Phase 1 version-check ask (new runs only, pre-preflight) | `"user-approval"` (a Phase-1 user gate; `approved` is still `false`, so the Stop hook allows regardless) |
| Phase 1 setup (branch created, before plan) | `null` (still `approved: false`) |
| Phase 1 clarifying-questions presented | `"user-approval"` (the AskUserQuestion call is itself a user gate) |
| Phase 1 plan presented for approval | `"user-approval"` |
| User types approval keyword | `"auto-continue"` (and `approved: true`) |
| Phase 2 → 3 advance | `"auto-continue"` |
| Phase 3 self-verify pass | `"auto-continue"` |
| Phase 3 fix-loop iteration | `"auto-continue"` |
| Gate A pass | `"auto-continue"` |
| Phase 4 code-review skill returns | `"auto-continue"` (the report is INPUT) |
| Phase 4 fix applied | `"auto-continue"` |
| Gate B pass | `"auto-continue"` |
| Phase 5 step 1–4 (gates verify, diagram, artifacts, CONTEXT.md) | `"auto-continue"` |
| Phase 5 step 5–7 (stage, commit, verify, push prep) | `"auto-continue"` |
| Phase 5 just-before `git push` / `gh pr create` | `"user-push-prompt"` |
| Phase 5 PR opened, state written | `null` (and `phase: "done"`) |
| Loop-rule surface (anywhere) | `"user-approval"` |
| Destructive action confirmation prompt | `"user-approval"` |

If you cannot map the current transition to one of these, the default is `"auto-continue"` — strict case, never lenient.

`gates` is the mechanical contract enforced by the global pre-commit hook (`enforce-gates.sh`). **No commit is permitted during an auto-task run until `gates.code_review.passed === true`, `gates.code_review.clean_pass_after_last_fix === true`, and (for STANDARD/HEAVY tier) `gates.gate_b.passed === true` or `gates.gate_b.skipped_reason` is set.** The hook reads this file at every `git commit`/`git commit --amend` invocation. Setting these flags is a checkable artifact — only set them after the agent actually ran and returned a clean result; never set them speculatively. If a gate fails, leave `passed: false` and surface.

Beyond the booleans, the hook also enforces **review staleness**: when `state.base` and `gates.code_review.reviewed_diff_sha` are both present, it recomputes `git diff <pinned-flags> <base> | git hash-object --stdin` (the pinned flags are listed under Phase 4 `reviewed_diff_sha`) and blocks the commit if the result differs from `reviewed_diff_sha`. This catches the most common real failure mode — review passes clean, then more code is edited (a "quick" Gate B fix, a stray tweak) and committed without re-review. The flags are self-attested; this binds them to the actual bytes of the diff. The only way past it is to re-review the current diff and refresh the sha, which is exactly the intended behavior.

## Pipeline

### Phase 1 — Define (HUMAN GATE)

**Version check (best-effort, fail-open — NEW runs only, before everything else).** On a new run (`/auto-task <description>`), before the component preflight, do a fresh **per-run version check** and offer to update if the plugin is behind. This is best-effort and MUST NOT block, slow (beyond the bounded fetch), or error the run — any failure means proceed silently. **Skip it entirely on resume** (`/auto-task` with no args): a resume continues an already-approved, mid-flight run, where swapping the plugin under the running pipeline would be wrong.

1. **Locate** the checker: `cv="${CLAUDE_PLUGIN_ROOT:-}/hooks/check-version.sh"`. If `CLAUDE_PLUGIN_ROOT` is unset or `$cv` is not a file (e.g. an `install.sh` symlink layout without the env var), **skip silently** and go straight to Component preflight.
2. **Run it fresh + plain:** `out="$(AUTO_TASK_SKIP_THROTTLE=1 bash "$cv" --plain 2>/dev/null || true)"`. This bypasses the 24h throttle (a true per-run check) WITHOUT touching the SessionStart throttle stamp, bounds the network call (the script's own `--connect-timeout 2 -m 5`), and prints the one-line notice ONLY when the installed version is strictly behind — empty on current / ahead / offline / no-jq / malformed.
3. **Decide:** if `$out` is **non-empty** (a newer version exists), ask ONCE via `AskUserQuestion`: present `$out` and two options — **"Proceed on current (Recommended)"** and **"I'll update first"**. On *proceed* → continue into Component preflight. On *update first* → STOP and tell the user to run `/plugin update auto-task@auto-task-plugin` and re-invoke `/auto-task`. If `$out` is **empty** → say nothing, continue into Component preflight.

This ask is part of the existing Phase-1 human surface — it runs while `approved: false`, so the Stop hook's `approved !== true → allow` guard already permits the yield (`expected_next_action` stays `null` while `approved:false`). It is NOT a new mid-pipeline yield, and it never runs after approval.

**Component preflight (on a new run this runs right after the version check; on resume — `/auto-task` no args — it is the first step).** This pipeline is only sound if every component it composes is present. Before touching git, confirm all six composed skills — `auto-task-plan`, `auto-task-implement`, `auto-task-verify`, `auto-task-fix`, `auto-task-code-review`, `auto-task-commit` — and the `task-execution-verifier` agent are available in this session (they appear in the available-skills / available-agents lists). **Invocation-name note:** under a marketplace install these siblings are registered *namespaced* — `auto-task:auto-task-plan`, `auto-task:auto-task-code-review`, etc. — while under the `install.sh` symlink fallback they keep their bare names (`auto-task-plan`, …). Everywhere this skill says "invoke the `auto-task-plan` skill" (and likewise for the other siblings and the verifier agent), invoke whichever form actually appears in your available-skills list for this session; the bare name in the prose is the identifier, not a literal string that must be passed verbatim. If any is missing, **STOP and tell the user the plugin is not fully installed** (point them at `install.sh` and the README "Install" section); do not start the run. Silently substituting a missing component (e.g. a hand-rolled review prompt for `auto-task-code-review`, or skipping a verifier gate) breaks the guarantees the user is relying on — a missing piece is a hard blocker, not something to work around. This is a one-time check; on resume (`/auto-task` with no args) it still runs, since a component could have been uninstalled between sessions.

**Branch setup (new runs only).** Before invoking `auto-task-plan`, isolate the run:

1. **Branch.** If the current branch is `main` or `master`, create a new one named `<type>/<slug>` to match the repo's existing convention (sample with `git for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin | head -30` and pick the dominant pattern — most repos here use `feat/`, `fix/`, `chore/`, `docs/`, `cleanup/`, `refactor/`). Pick `<type>` from the task description:

   - `fix/` — bug reports, "X is broken", "doesn't work", "scrolls to wrong place", "throws error", "wrong output", "regression"
   - `feat/` — "add X", "implement Y", "new feature", "support Z", "enable …"
   - `chore/` — internal cleanup, dependency bumps, build/test config, formatting-only sweeps
   - `refactor/` — code reorganization with no behavior change
   - `docs/` — docs/README/comments-only changes
   - `cleanup/` — removal of dead code or files
   - When ambiguous between `feat` and `auto-task-fix`, prefer `auto-task-fix` if the user describes existing-but-broken behavior, `feat` if the user describes capability that doesn't exist yet
   - Default if truly unclear: `chore/`

   `<slug>` is the task description slugified to kebab-case (lowercase, ASCII, ~40 chars at a word boundary, strip stop words like "the", "a", "and"). Do not prepend `auto/` — the branch name should look like one a human would write, since it ends up in `git log` and the PR.

   Ensure uniqueness via `git branch --list <name>` and `git ls-remote --heads origin <name>` (skip the remote check if origin is unreachable); append `-2`, `-3`, etc. until unique.

   **Isolate the new branch in its own git worktree (automatic — this is what makes same-repo parallel runs safe).** A run keys ALL its state to the checked-out branch, and the gate + Stop hooks resolve state via `git branch --show-current`. So running directly in a shared checkout means a branch switch from another terminal (or a second run) yanks the working tree out from under this one. To prevent that, when you had to CREATE the branch (you were on `main`/`master`), give the run its own working tree instead of switching the shared one:

   1. Create a worktree from the CURRENT HEAD and enter it:
      - `git worktree add ".claude/worktrees/<type>-<slug>" -b "<branch>" HEAD` — the directory name is the branch with `/`→`-` (a single safe path segment); trailing `HEAD` pins the worktree's base to the local tip **regardless of the user's `worktree.baseRef` git config** (whose default `fresh` would branch from `origin/<default>` and break the `base = git rev-parse HEAD` contract below).
      - Then relocate the session into it with the **`EnterWorktree`** tool, passing `path: ".claude/worktrees/<type>-<slug>"` (entering an existing worktree by path — the tool's docs sanction this when project instructions direct it, which this skill is). From here the session CWD is the worktree root; every subsequent step (exclude, folders, state, and all later phases) resolves against it, and the shared checkout is left untouched and free for other work.
   2. **Ordered fallbacks (never leave a half-made worktree behind):**
      - If the `EnterWorktree` tool is not available in this session (older harness / headless run) OR `git worktree add` fails → skip the worktree and run in place: `git switch -c "<branch>"`. Log `{ phase: "define-setup", result: "worktree-fallback", reason: "<what failed>", at: "ISO-8601" }` to `state.history`. The run is then a normal in-place run; the checkout-drift guard (below) covers the residual risk.
      - If `git worktree add` SUCCEEDED but `EnterWorktree` then failed, the worktree exists on disk yet the session is still in the original checkout — undo the orphan before falling back: `git worktree remove --force ".claude/worktrees/<type>-<slug>"` then `git branch -D "<branch>"` (the branch is unused since you never entered it), then `git switch -c "<branch>"` in place.

   If the current branch is anything **other** than `main`/`master`, use it as-is — assume the user prepared it — and do NOT create a worktree (the isolation policy is: auto-worktree only on the new-branch path; a prepared checkout is respected). The checkout-drift guard protects this in-place case. Write the resolved branch name to `state.branch`.

   **Pre-existing staged/unstaged changes:** if `git status` shows any work in progress before you create the branch, do NOT touch it (no `git add`, no `git stash` unless the user agrees). The branch switch will carry those changes along in the working tree — that's fine, as long as you never stage them in your own commits. If a user file conflicts with creating `.auto-task/<branch>/`, surface it and ask.

2. **Exclude `.auto-task/` (and the worktree store) from git.** Resolve the exclude file as `excl="$(git rev-parse --git-common-dir)/info/exclude"` — that expands to `.git/info/exclude` in a normal checkout and to the shared common-dir exclude from any linked worktree (where `.git` is a *file*, not a directory, so the bare `.git/info/exclude` path would error with "Not a directory"). Append `.auto-task/` (the root, NOT the per-branch sub-path) idempotently: `grep -qxF '.auto-task/' "$excl" || echo '.auto-task/' >> "$excl"`. Also append `.claude/worktrees/` the same way (`grep -qxF '.claude/worktrees/' "$excl" || echo '.claude/worktrees/' >> "$excl"`) so an auto-created worktree living under the repo never shows as untracked in — or gets accidentally staged from — the parent checkout. This is per-clone, so it never lands in the repo's `.gitignore`. One `.auto-task/` entry covers every per-branch folder (and, via the common dir, every linked worktree of the clone), including ones from prior runs that should remain readable for history.

3. **Create the per-branch folder.** `mkdir -p .auto-task/<branch>/artifacts .auto-task/<branch>/recon .auto-task/<branch>/fixes`. Slashes in the branch name are preserved literally (branch `fix/auth-bug` → `.auto-task/fix/auth-bug/`). This MUST match `git branch --show-current` verbatim — the gate and Stop hooks resolve `.auto-task/<branch>/STATE.json` from it, and any divergence (extra prefix, rewritten slug) makes them silently find no state file and fail open.

4. **State.** Initialize `.auto-task/<branch>/STATE.json` with `phase: "define"`, `expected_next_action: null`, `approved: false`, `description: "<verbatim task input>"`, `branch: "<resolved name>"`, `base: "<base-commit SHA>"`, and empty containers for the rest (see "State file" schema). Capture `base` as `git rev-parse HEAD` at run start — for a freshly-created branch that is the fork point; for a reused branch it is the branch's current tip. Either way `git diff <base>` is then exactly *this run's* uncommitted work, which is what the change diagram, the verifiers, and the review-staleness gate hook all measure against. `base` must NOT change for the life of the run. **Caveat:** if the working tree already has pre-existing uncommitted changes at run start (see the pre-existing-staged handling below), those are part of `git diff <base>` too — the baseline-exclusion rule keeps them out of *commits*, but reviewers and the staleness hash will see them. When that happens, note it under PLAN.md Unknowns so a reviewer isn't surprised. `expected_next_action` is `null` while `approved` is `false` — the Stop hook allows yields freely until the user has approved the plan.

5. **Initialize TRACE.md.** Create `.auto-task/<branch>/TRACE.md` with the header block from the "Persistent history & trace contract" section, and append the first trace entry: `operation: auto-task:phase-1-start`, summary: "Branch <name> created from <base>; task: <one-line task summary>".

**Do NOT make any commit during branch setup.** The branch starts empty (zero commits ahead of the base). The first commit comes only after the user approves the plan, in Phase 2 — and it commits real code changes, not `.auto-task/<branch>/` content. The plan itself lives on disk under `.auto-task/<branch>/` for the user to read and for resumption, but it is never part of the git history.

All commits in the run go through the `auto-task-commit` skill. Before invoking `auto-task-commit`, run `git restore --staged .auto-task/ 2>/dev/null || true` defensively, even though the exclude entry from step 2 (`$(git rev-parse --git-common-dir)/info/exclude`) should already keep `.auto-task/` out of the index.

**Checkout-drift guard (protects in-place runs).** A run that is NOT in its own worktree — a prepared feature branch, or the worktree fallback above — is guarded proactively against the working tree being switched off its branch underneath it. Two hooks enforce this, both keyed on `git branch --show-current` versus the active run's `.auto-task/<branch>/`: (1) `warn-checkout-drift.sh` (PreToolUse/Bash, informational, NEVER blocks) warns on every command when an active run exists on a branch other than the one checked out; (2) `enforce-gates.sh` HARD-BLOCKS a `git commit` in that same situation — closing the old silent fail-open where a moved checkout found no state for the current branch and allowed an ungated commit onto the wrong branch. Resolve a drift warning/block by either `git switch <run-branch>` (then resume with `/auto-task`) or `rm -rf .auto-task/<run-branch>/` if the run is abandoned. Runs isolated in their own worktree are structurally immune — git forbids two worktrees on one branch, and `.auto-task/` is per-worktree — so the guard is a safety net for the in-place path, not a substitute for worktree isolation.

**Worktree lifecycle.** An auto-created worktree is KEPT on disk after the run — Phase 5 never removes it — so its branch and `.auto-task/<branch>/` history/artifacts stay available for follow-up and review. Prune it manually with `git worktree remove .claude/worktrees/<type>-<slug>` once you are done. Do NOT call `ExitWorktree` to auto-remove it.

**Clarifying questions (HUMAN GATE — first interaction).** Before reconnaissance or planning, surface every decision-changing ambiguity that you cannot resolve yourself. The goal: once the user answers (and reviews your auto-resolved items at plan approval), you can plan, execute, verify, and ship the task without coming back for clarification. This is the FIRST half of Phase 1's human gate; plan approval at the end of Phase 1 is the second half. There is no separate gate later — anything you'll need to know to finish the run, resolve or surface now.

**Core principle:** do not burden the user with anything you can answer with reliable evidence. Do NOT guess, assume, or extrapolate from "looks like the convention" — if you don't have a verifiable cite, ask the user. Every candidate that you resolve yourself is recorded in PLAN.md with its source so the user can audit your evidence at approval time.

Process (mandatory six-stage gate — do them in order, do not skip stages):

1. **Draft the full candidate question list.** Read the task description carefully. Enumerate every potential decision-changing ambiguity — do NOT filter yet, do NOT try to answer yet, just list them. Cover every category that has any ambiguity for this task (omit categories with none):

   - **Scope** — what's in / out (which files, modules, routes, user segments, platforms); whether adjacent broken things get fixed or parked.
   - **Acceptance** — what "done" looks like that the task left implicit (specific behavior, visual outcome, error/empty/edge handling, accessibility, i18n, mobile).
   - **Approach** — when more than one viable implementation exists and the choice changes blast radius, risk, dependency, API shape, or migration cost.
   - **Constraints** — runtime/browser/version compatibility, performance budget, dependency policy (add new dep vs. inline), naming or style conventions where the task could land either way.
   - **Data / state** — schema changes, defaults for new fields, behavior for existing rows, idempotency, backfill strategy.
   - **External systems** — credentials available, write authorization (which MCPs/APIs may mutate), target environment (staging vs prod), live URLs to inspect, design references.
   - **Verification** — how the user will judge success (specific URL/route/test/manual check), what counts as a regression worth blocking on.
   - **Trade-offs** — explicit user preferences that contradict obvious defaults ("fewer dependencies even if more code", "ship behind a flag", "prefer rewrite over patch").

   Apply the decision-changing test: "If I picked the wrong answer here, would the run fail, drift out of scope, miss an AC, or produce something the user wouldn't accept?" Drop questions that don't pass. The remainder is your draft list.

2. **Research each draft question.** For every candidate on the list, spend bounded effort trying to find a verifiable answer. Go deep enough to reach reliable evidence OR confirm there isn't any, then move on. Sources are limited to material that produces a CITE — a `file:line`, a doc URL, an MCP response, a memory entry, or the user's own verbatim words in the task description. No inference from "this looks like the convention." Sources, in roughly this order:

   - The task description itself — re-read carefully; users often answer in the prompt without realizing it. Cite the quoted phrase.
   - Repo state — `README.md`, `CLAUDE.md`, `package.json` / pyproject / equivalent for stack and dep policy, the directories and entry points the task obviously touches. Cite the `file:line`.
   - Prior auto-task runs — `.auto-task/<branch>/CONTEXT.md` if it exists for this branch, and the most recent CONTEXT.md from adjacent branches on the same area. Cite the section.
   - User memory — `~/.claude/projects/<slug>/memory/MEMORY.md` if it exists; project/feedback/reference memories often resolve approach/policy questions. Cite the memory file name.
   - Codebase via `Read` / `Glob` / `Grep` — for scope, existing patterns. Cite the `file:line`. **One example is not a convention** — to cite "the repo uses pattern X", you need ≥3 occurrences in distinct files and zero counter-examples in the area the task touches.
   - MCPs — the same allowance as the recon step below. Context7 for library API shape, Figma for design refs, Playwright for live-URL behavior, etc. Cite the MCP and the specific response.

   What you CANNOT cite, you CANNOT resolve. "Probably X", "usually X", "looks like X", "would make sense", "common pattern" — these are not cites. If your only basis is inference without evidence, the question goes to the Asked bucket in stage 3.

3. **Triage each candidate into one of two buckets.**

   - **Resolved** — verifiable answer found with a cite. Record under `## Clarifications` as `Q: <question> / A: <answer> / Source: <cite — file:line, doc URL, MCP source, memory entry, or quoted phrase from the task description>`. If you cannot produce a cite in this format, the candidate is NOT resolved — push it to Asked.
   - **Asked** — no verifiable answer found, OR the question is high-stakes enough that even strong evidence isn't sufficient (writes to external systems, irreversible operations, anything in CLAUDE.md's "Executing actions with care" territory — for these, always ask even if you have a cite, because the user has standing to override).

   There is no third bucket. Do not invent "Defaulted", "Assumed", "Probably-X". Either you have a cite and resolve, or you don't and you ask.

4. **Ask only the Asked bucket** via `AskUserQuestion`. Present 1–4 questions per call (the tool's cap). If you genuinely have more than 4 items in the Asked bucket, prioritize the highest-impact and fold the rest into PLAN.md's Unknowns. Each question MUST:
   - Be answerable with a short selection (offer 2–4 concrete options; avoid open-ended phrasing).
   - State the decision impact in the description so the user knows why it matters (what changes if A vs B).
   - Lead with the option you'd pick if forced to decide alone, marked `(Recommended)`.
   - Use a short header chip (≤12 chars).

   If the Asked bucket is empty after stages 1–3, skip this step entirely — do NOT invent questions to "look thorough". A run where every ambiguity was resolved with evidence is a *better* run, not a lazier one.

5. **Record everything.** Write a `## Clarifications` section at the very top of `.auto-task/<branch>/PLAN.md` (above Feasibility). The section contains both buckets in this order:

   ```
   ## Clarifications

   ### Resolved (evidence-backed)
   - **Q:** <question>
     **A:** <answer>
     **Source:** <cite — file:line, doc URL, MCP source, memory entry, or quoted task phrase>
   - ...

   ### Asked (user-provided)
   - **Q:** <question>
     **A:** <user's answer>
   - ...
   ```

   Omit any subsection whose bucket is empty. If both buckets are empty (no ambiguity at all), write `## Clarifications\n\nNone — task description was unambiguous against current repo state.\n` and skip the rest.

   Log to `state.history`: one entry per candidate question, in either bucket: `{ phase: "define-clarify", question: "...", answer: "...", resolution: "resolved|asked", source: "<cite for resolved; \"user\" for asked>", at: "ISO-8601" }`. Treat answers from both buckets as binding inputs to recon, plan body, AC table, and tier scoring.

6. **No mid-pipeline re-asking.** After this step, Phase 2–5 must not stop to ask clarifying questions. If a genuine new ambiguity surfaces later (typically because the codebase contradicts a Phase 1 assumption), that's a Loop-rule clause 3 ("external blocker") trigger — STOP and surface per the Surfacing protocol; do not silently ask. This is what forces stages 1–5 to be exhaustive *here*.

After clarifications are recorded, proceed to reconnaissance.

**Pre-plan reconnaissance (auto, no human gate).** Before invoking `auto-task-plan`, decide whether the task requires inspecting an external system, a running UI, or a documentation source to plan it properly. Do the inspection yourself — never punt this to the user.

Trigger reconnaissance when the task description involves any of:
- Visual / UI / styling / layout / responsive behavior ("the card looks wrong", "background image is off", "spacing on mobile").
- A specific page, route, component, or user-facing flow whose current behavior must be observed (not just inferred from code).
- A bug report tied to runtime behavior (console errors, network failures, interaction states, hover/focus/animation).
- A reference to an external/live URL the user provided.
- A library / framework / SDK / API whose current syntax or behavior is load-bearing on the plan (use Context7 MCP).
- A Figma file, design system, or visual reference the user linked or named (use the Figma MCP).
- Any other external system the task explicitly references (Notion docs, Slack threads, Linear tickets, Drive files, Gmail, Calendar, Asana, Ahrefs, Sanity, etc.) where the relevant facts are not in the repo.

Skip reconnaissance for pure backend / library / config / refactor / type-only changes, or tasks where reading the code is sufficient (and note the skip in `state.history` with `result: "recon-skipped"` and a one-line reason).

**MCP usage in Phase 1 is open.** Any MCP server currently available to the session may be used during reconnaissance if it is the most direct way to gather a fact the plan depends on. Common picks:

- **playwright** — running UI / live URL inspection (DOM, screenshots, console, network).
- **claude_ai_Context7** — official library / framework / SDK docs whenever the plan touches an external API; prefer this over web search per the Context7 server instructions.
- **plugin_figma_figma** — design files, component metadata, screenshots, design tokens, Code Connect mappings.
- **claude_ai_Notion / Google_Drive / Gmail / Google_Calendar / Slack / Asana / Ahrefs / FR_Sanity** — only when the task explicitly references content in that system.
- **ide** — `getDiagnostics` when the task hinges on currently-reported type/lint errors.

Rules that apply to every MCP used in recon:

1. **Read-only by default.** Do not mutate external state, send messages, post comments, create files in third-party systems, click destructive UI controls, submit forms, or sign in with real credentials unless the user explicitly authorized that specific write in the task description. Writes to MCPs are externally-visible actions per `~/.claude/CLAUDE.md` "Executing actions with care" — surface and ask first, otherwise stay read-only.
2. **Auth prompts are not a recon blocker.** If an MCP requires `__authenticate` / `__complete_authentication`, do NOT invoke it interactively during recon — log `result: "recon-blocked"` with reason `"<server> requires user auth"` and proceed to plan with the limitation called out in Unknowns.
3. **Mandatory prerequisite skills still apply.** Before any `use_figma` call, load the `figma-use` skill; before any `generate_diagram` call, load the `figma-generate-diagram` skill. The skill's own instructions override generic recon guidance.
4. **Stop as soon as the observation is sufficient.** Recon is not a full audit. One or two MCPs covering the relevant fact is enough.

When triggered:

1. **Pick the target(s).**
   - If the user gave a URL → use it.
   - If the user named a library/framework/API → resolve via Context7.
   - If the user gave a Figma URL → use the Figma MCP after loading `figma-use`.
   - Else if the task is about `apps/web` and a local dev server is reachable → use `http://localhost:3000` (probe with a quick `curl -sI` or `browser_navigate`; do NOT start the dev server yourself — `pnpm dev` is user-run per CLAUDE.md).
   - Else if the task is about a known production/staging URL discoverable from the repo (e.g., README, env files) → use that, read-only.
   - If no target can be identified, log `result: "recon-skipped"` with reason `"no reachable target"` and proceed to plan — do NOT ask the user (the recon is best-effort; the plan can still proceed and flag the missing observation under Unknowns).

2. **Inspect.** Use the selected MCP(s) and/or `curl` to gather only what's needed to plan:
   - Current visible behavior of the relevant element/flow.
   - Console errors and failed network requests on the affected page.
   - DOM/computed-style facts that disambiguate the task.
   - Current library API shape / version-specific syntax when an external dependency is touched.
   - Design metadata (component names, tokens, layout dimensions) when a Figma reference is provided.
   - Stop as soon as the observation is sufficient to write a concrete plan. This is reconnaissance, not a full audit.

3. **Record.** Append a `## Recon` section to `.auto-task/<branch>/PLAN.md` (immediately after `Effort:`, before `## Critique`) with: target(s), MCPs used, what was checked, key observations (3-8 terse bullets), any screenshots saved under `.auto-task/<branch>/recon/`, and any blockers. Log a `state.history` entry: `{ phase: "define-recon", result: "done|skipped|blocked", mcps: ["..."], target: "...", summary: "...", at: "ISO-8601" }`.

Use the recon findings as input to the next step.

**Approach selection (auto, with a conditional fold into the human gate).** Before invoking `auto-task-plan`, decide whether the task admits more than one materially different implementation. The detailed plan breaks down *one* approach — choosing which one is a decision in its own right, and everything downstream only verifies that the chosen approach was built correctly, never whether a better approach existed. This step makes that choice explicit and auditable so a wrong-approach-entirely plan can't sail through to approval looking internally coherent.

1. **Trigger.** Run approach selection when more than one viable approach exists AND the choice changes any of: blast radius, risk/reversibility, dependencies, public API shape, or migration cost (the same test as the clarifying-questions "Approach" category). If the task has a single obvious implementation — a localized bug fix, a copy change, a config tweak — skip it and log `{ phase: "define-approach", result: "skipped", reason: "single viable approach", at: "ISO-8601" }`. Do NOT manufacture alternatives to look thorough; a task with one honest approach is a faster run, not a lazier one.

2. **Generate candidates.** Produce 2–3 *short* approach sketches — NOT full task breakdowns (that work is wasted on the rejected ones). Each sketch has: **Name** (a 2–4 word handle, e.g. `inline-guard`, `extract-middleware`, `schema-migration`); **Description** (one paragraph — what it does and how); **Blast radius** (files/modules/layers touched); **Key risk** (the main thing that can go wrong); **Effort** (rough relative size); **Tradeoff** (the one-line "buys X at the cost of Y"). Scale generation effort to apparent complexity — the real Effort tier is computed later, from the chosen plan, so this is a provisional read:
   - Apparently simple-but-branching task → draft 2 sketches inline.
   - Apparently complex / high-blast / high-risk task → spawn 2–3 `general-purpose` Agents in parallel, each asked for ONE approach from a distinct angle (e.g. minimal-diff, idiomatic-to-this-codebase, robustness-first), each returning a sketch in the format above. Independent agents give genuine diversity; inline variants tend to be three flavors of the first idea.

3. **Score and select.** Score each candidate on fixed dimensions: AC-fit (does it deliver every behavior the task promises), blast radius, risk/reversibility, dependency cost, alignment with existing repo patterns, effort. Then:
   - **Clear winner** (one candidate dominates on the dimensions that matter for this task) → select it yourself.
   - **Close call OR high-stakes choice** — when no candidate clearly dominates, OR the choice touches a Risk-rubric score-2 dimension (schema/data migration, external/third-party API, auth/payments/data-integrity/multi-tenant) → do NOT self-decide. Present the top approaches to the user via `AskUserQuestion` as part of the Phase 1 human gate — this folds into the clarifying-questions surface, it is NOT a new gate. One question, 2–3 options (candidate name + one-line tradeoff each), lead with your recommended candidate marked `(Recommended)`. The user's pick is binding. Set `expected_next_action: "user-approval"` for the call, as for any Phase 1 `AskUserQuestion`.

4. **Record.** Write an `## Approach` section to `.auto-task/<branch>/PLAN.md`, immediately after `## Recon` (before the plan body): the chosen approach, then each rejected candidate with its scores and a one-line rejection rationale. This decision log lets a reviewer — or a resumed run — see not just what was built but why this path over the others. Log to `state.history`: `{ phase: "define-approach", candidates: ["<names>"], chosen: "<name>", method: "auto|user", at: "ISO-8601" }`.

`auto-task-plan` then breaks down ONLY the chosen approach.

Invoke the `auto-task-plan` skill internally. The plan MUST include an explicit **Acceptance Criteria** section with objectively verifiable items. The `auto-task-plan` skill's default template does NOT produce one — you MUST append it before stopping, or the run cannot proceed.

**Acceptance Criteria contract (NON-NEGOTIABLE).** Phase 1 cannot complete unless `.auto-task/<branch>/PLAN.md` contains an `## Acceptance Criteria` section that satisfies every rule below. If any rule fails, do NOT stop for human approval — fix the AC table first, then stop. The user approval gate verifies these rules are met before accepting "approved".

Required format — a table, not prose:

```
## Acceptance Criteria

| # | Criterion (observable outcome) | Verification method | Expected result | Gate |
|---|--------------------------------|---------------------|-----------------|------|
| 1 | <what is true after the change> | <exact command / file:line assertion / UI observation> | <pass condition> | self-verify / gate-a / gate-b |
```

Rules each row MUST satisfy:

1. **Observable** — phrased as something a third party can witness from outside the code ("login route returns 200 for valid creds", "CLS on /home mobile drops below 0.1"). NOT internal/aspirational ("auth works correctly", "code is cleaner").
2. **Bound to a check** — `Verification method` is a concrete command, assertion, or observation step. Examples: `pnpm test packages/ui/__tests__/Foo.test.ts`, `curl -s localhost:3000/api/x | jq .status`, `grep -n 'export const Bar' packages/ui/src/Bar.tsx`, `playwright: navigate to /home, screenshot, confirm no layout shift on scroll`. NOT vague ("manually check", "looks right").
3. **Falsifiable** — `Expected result` is a value or boolean that can be compared. ("status code = 200", "exit code 0", "selector `.cls-warning` absent", "console errors empty"). NOT "no problems".
4. **Gate-bound** — every row's `Gate` column names which gate runs the check: `self-verify` (Phase 3 / `auto-task-verify` skill — types, lint, build, tests), `gate-a` (independent verifier reads diff + runs check), or `gate-b` (adversarial pass). Every AC MUST appear in at least one gate. ACs with `Gate = self-verify` MUST have a `Verification method` that the `auto-task-verify` skill actually runs (a test file, a build command, a lint rule) — if there's no automated check, the gate is `gate-a` with a manual observation step.
5. **Complete** — together, the AC rows cover every behavior the task description promises. If the task description mentions UX behavior X but no row checks X, the AC is incomplete.

After writing the table, run a self-check before stopping:

- Count rows. If `< 2` for non-trivial tasks (Tier ≥ STANDARD), that's almost certainly missing coverage — re-read the task description and add rows.
- For each row, mentally run the `Verification method` and ask: "If this command/observation returned the `Expected result`, would I believe the criterion is satisfied?" If no, the row is too weak — rewrite it.
- For each row with `Gate = self-verify`, confirm the verification method maps to a check the current tier's `/auto-task-verify` scope actually runs. Types-only tier won't run a build assertion — escalate the tier or move the row to `gate-a`.

If the AC table fails any of these self-checks, the human gate is NOT reached — fix the table first. The Critique pass's `[AC]` dimension is a second line of defense, not a substitute.

**AC pre-flight (NON-NEGOTIABLE — runs BEFORE the critique pass and BEFORE the human gate).** The AC self-checks above test the *shape* of the table; pre-flight tests the *premise* of every AC against the actual repo state. Without it, an AC can look perfect on paper while resting on a false assumption (a wrong jq path, a stale baseline, a tool that produces unreliable output) — and the failure mode is that approval is granted on a flawed plan and the run wastes effort discovering it in Phase 2.

For each AC row whose `Verification method` is an executable command:

1. **Dry-run the command** against the current working tree (before any code change). Capture exit code + relevant output.
2. **Pin the baseline** — write the output (or a summary if large) to `.auto-task/<branch>/recon/ac-<#>-baseline.{json|txt}` and reference it from `state.history` as `{ phase: "define-preflight", ac: <#>, result: "pinned|failed-syntax|unreliable-signal", baseline: "<value or path>", at: "ISO-8601" }`.
3. **Sample-verify when the AC depends on an external tool's output** (knip, jscpd, ts-prune, knip-ish dead-code detectors, complexity scanners, dependency analyzers, anything that produces a list of "things to fix"):
   - Pick a sample of **≥5 entries** from the tool's list (or all entries, whichever is smaller).
   - For each sample entry, run an independent check that would falsify the tool's claim (e.g., for "unused export X", run `grep -rln '\bX\b' <scope>` and require 0 hits; for "complexity > 10 in function Y", read the function and count branches).
   - Compute the false-positive rate: `FP = (entries whose independent check contradicts the tool) / sample size`.
   - **If FP > 20% (more than 1-in-5 wrong on the sample):** the AC's premise is **unreliable**. Do NOT advance to the human gate. STOP and surface to the user with: the tool, the sample tested, the FP rate, the contradictions found, and a suggested pivot (configure the tool, switch tools, or drop the AC). Treat this as a Loop rule clause 2 ("out-of-scope") trigger BEFORE the run even starts — better to surface during define than mid-execute.
   - **If FP = 0 on a small (5) sample but the kill list is large (>50 entries):** widen the sample to ~10% of the list (capped at 20) and re-test. A clean small sample on a large list is suggestive, not conclusive.
4. **Pre-flight syntax check.** If the AC command itself errors out (jq path wrong, file not found, tool not installed) — fix the AC command, not just the symptom. An AC that can't be executed at all is also unreliable.

Pre-flight produces one of three outcomes:

- **All ACs pinned, FP ≤ 20% on every sampled list** → advance to the critique pass.
- **Any AC's command errors** → fix the AC text (re-write the command), re-run pre-flight for that AC. Do not stop for human approval until every AC has a clean dry-run.
- **Any sampled list shows FP > 20%** → STOP and surface BEFORE the human gate. The plan is built on a wrong premise; user must pivot scope or switch tools.

Pre-flight evidence (the pinned baselines + sample-verification log) MUST appear in `.auto-task/<branch>/PLAN.md` as a `## AC Pre-flight` section between Acceptance Criteria and Critique, with one terse bullet per AC: `AC #N — baseline pinned (<value>); sample-verified N entries, FP=X%`.

In addition to what `auto-task-plan` produces, write a short feasibility note at the top of `.auto-task/<branch>/PLAN.md`:
- **Feasibility:** GREEN / YELLOW / RED with one sentence.
- **Unknowns:** items that would change the plan if learned.
- **Blast radius:** files/modules touched, consumers to keep working.
- **Effort:** `<TIER> — D=<n> R=<n>` (see rubric below).

**Difficulty / Risk rubric.** Score each dimension 0 / 1 / 2; sum gives D and R (each 0-8). Tier = `max(D, R)` per the Effort tiers table.

*Difficulty*
- Blast radius — files touched: 1 (0), 2-5 (1), 6+ (2)
- New abstractions: pure edits (0), new module within an existing layer (1), new system or cross-layer plumbing (2)
- Layers touched: single (0), two (1), three+ (2)
- Unknowns count: 0 (0), 1-2 (1), 3+ (2)

*Risk*
- Reversibility: pure code (0), config / feature flag (1), schema / data migration / irreversible side effect (2)
- External integration: none (0), internal service (1), external API or third-party (2)
- Test coverage of touched code: good (0), sparse (1), none (2)
- Production blast: internal tool (0), user-facing (1), auth / payments / data integrity / multi-tenant (2)

Write D, R, and the resulting tier into both `.auto-task/<branch>/PLAN.md` and state's `effort` object.

**Critique pass.** Before stopping for human approval, spawn a `general-purpose` Agent with a fresh-context prompt containing:
- `.auto-task/<branch>/PLAN.md` as the only input.
- Explicit ask: "Critique this plan on four dimensions. Return at most 6 terse bullets total, one issue per bullet, prefixed with the dimension tag. Omit a dimension if it has no issues. If nothing to flag, return exactly `No issues found.`
  - **[AC]** Each Acceptance Criterion objectively verifiable? (Good: 'login route returns 200 for valid creds'. Bad: 'auth works correctly'.)
  - **[Blast]** Blast Radius honest given the AC? Files or layers likely missing?
  - **[Edge]** Missing edge cases the plan should explicitly handle or explicitly defer.
  - **[Rollback]** For schema/data/migration/irreversible changes, is rollback addressed? Mark N/A for pure code.
  Do not propose new work or rewrite the plan — only flag concerns."

**Critique → re-plan loop.** The critique is not advisory wallpaper that the user has to mine for what matters — its mechanically-fixable findings get fixed *before* the human sees the plan, so the approval gate adjudicates only genuine judgment calls. After the agent returns, classify each finding:

- **Structural-fixable** — a plan defect resolvable without the user: a missing edge case a task should handle, a blast-radius file the plan omitted, a non-falsifiable/unobservable Acceptance Criterion, a missing rollback step for an irreversible change. These are gaps in the plan's own internal completeness.
- **Judgment-required** — a concern needing a human decision: a scope tradeoff, an approach-worth-the-risk question, anything where the "fix" is a choice rather than a correction.

Then loop, bounded by tier (LIGHT: 1 round; STANDARD/HEAVY: 2 rounds):

1. Amend `.auto-task/<branch>/PLAN.md` to resolve every **structural-fixable** finding (add the edge case to a task, widen Blast Radius, rewrite the weak AC, add the rollback step). Keep each amendment minimal and traceable to the finding that prompted it.
2. Re-run the critique agent on the amended plan (fresh context, same prompt). Do NOT trust the amend blindly — the re-critique is the safety net, mirroring the global "re-invoke code-review after every fix" rule.
3. Exit the loop when the critique returns `No issues found.`, only **judgment-required** findings remain, or the round cap is hit.
4. Log each round to `state.history`: `{ phase: "define-critique", round: <n>, fixed: ["<finding tags>"], remaining: ["<finding tags>"], at: "ISO-8601" }`.

**Record.** Write the final `## Critique` section in `.auto-task/<branch>/PLAN.md`, placed immediately after the `Effort:` line and before the plan body, with two parts: **Auto-fixed** (what the loop resolved — one bullet each, naming the finding and the amendment) and **For your judgment** (the remaining judgment-required findings, verbatim). If the loop closed everything, the second part is `None — all critique findings were structural and auto-fixed.`; if the critique found nothing at all, the whole section is `No issues found.` verbatim. The user reads the plan (now repaired) plus the residual judgment calls, and decides whether to amend further, accept, or reject. The `[Rollback]`-dimension trigger for the risk disclaimer (below) fires on a concern surfaced in *either* part.

**High-risk disclaimer (assembled BEFORE the approval presentation).** The approval gate is the user's last chance to refuse the run before code starts changing. For low-risk tasks the plan + critique is enough — adding a disclaimer just trains the user to ignore them. For high-risk tasks a disclaimer is mandatory and must be specific enough to change the user's behavior, not generic boilerplate.

A disclaimer is REQUIRED when ANY of the following holds (compute from the rubric scores you already wrote):

- `effort.tier === "heavy"` (i.e., `max(D, R) >= 6`).
- `effort.risk >= 5` (cumulative risk is high even if difficulty is modest).
- Any single risk dimension scored a `2`. Recheck each one — they map to specific, concrete user-visible failure modes:

| Dimension | Score-2 trigger | What the disclaimer must say |
|---|---|---|
| Reversibility | schema migration / data migration / irreversible side effect | "This run includes irreversible changes (schema/data). A bad outcome cannot be rolled back by reverting the commit — recovery requires manual data work. Confirm before proceeding." |
| External integration | external API / third-party | "This run wires up an external third-party (<name>). Bad input or misuse can incur charges, leak data, or rate-limit the service. Confirm the integration target and credentials are correct." |
| Test coverage | none on touched code | "The touched code currently has no automated test coverage. Regressions introduced by this run will not be caught by `auto-task-verify` and may only surface in production. Confirm you accept the lower verification floor." |
| Production blast | auth / payments / data integrity / multi-tenant | "This run touches a critical surface (<auth | payments | data integrity | multi-tenant>). Bugs here can compromise user accounts, mis-charge, corrupt records, or cross tenant boundaries. The blast radius if something goes wrong is large." |

Also REQUIRED when the Critique pass returned a specific concern in the `[Rollback]` dimension, even if it didn't pass any other threshold above.

Assembly rules:

1. **Trigger by score, not by feel.** If thresholds say disclaimer, you include one — even if the plan looks "obviously safe" to you. Conversely, do NOT add one for LIGHT/STANDARD tasks that don't trip any threshold; noise dilutes the signal.
2. **Be specific.** Replace `<name>`, `<auth | payments | …>`, and the like with the actual values from the plan. A generic "this is risky, are you sure?" does not change behavior.
3. **List every trigger that fired.** If two risk dimensions both hit `2`, both bullets appear. Don't pick the "biggest one" — the user needs to see the full surface.
4. **End with an explicit ask.** The disclaimer block closes with a single line: `**Confirm you understand these risks before approving the plan.**` This tells the user that typing `approved` carries weight.
5. **Place it BELOW the plan body and ABOVE the Critique** in the presentation, under a heading `## ⚠ Risk disclaimer (REQUIRED — read before approving)`. Position matters: the user is more likely to scroll past it if it's at the very top (looks like boilerplate) or at the very bottom (already typed approval). Mid-presentation, just before the section they'll read most carefully (Critique), is the highest-attention slot.
6. **Log the assembly.** Write a `state.history` entry `{ phase: "define-disclaimer", triggers: ["<list of triggers that fired>"], dimensions: ["<dimension names>"], at: "ISO-8601" }`. If no disclaimer was warranted, log `{ phase: "define-disclaimer", result: "not-required", at: "..." }` — the explicit "no" record makes it auditable whether the call was made or skipped.

The disclaimer is generated from the rubric values + plan metadata; do NOT invent risks the rubric didn't score. If you find yourself wanting to write a disclaimer for something the rubric scored as low-risk, that's a signal the rubric was wrong — re-score `effort` and update `effort.history` instead of adding ad-hoc warnings.

If the user proceeds with approval despite a disclaimer, that's a binding choice — record it in CONTEXT.md under `Human choices → Plan approval → Disclaimer acknowledged` with the list of triggers the user accepted. Later phases (Phase 4 review, Gate B) should NOT re-raise the same risk as a finding to fix; the user already made the call. They MAY raise it as a follow-up if the implementation made the risk worse than the plan anticipated.

Before presenting the plan, set `expected_next_action: "user-approval"` in STATE.json — the Stop hook will allow the yield. Then present the plan summary (with the Critique section visible AND, if assembled above, the Risk disclaimer block) and **STOP**. Wait for explicit user approval (keywords: `approved`, `looks good`, `continue`, `proceed`, `yes`, `go ahead`).

When presenting, surface the `## Clarifications` section so the user can audit your evidence. For every Resolved entry, the cite is visible inline — the user can spot a wrong resolution by checking the cite. The Asked entries are the user's own answers from stage 4, replayed for verification.

On approval: write `approved: true` AND `expected_next_action: "auto-continue"` to state, then advance to Phase 2. From this point on, the Stop hook will block any attempt to end the turn until you reach a legitimate yield point or `phase: "done"`. **Do not commit on approval** — `.auto-task/<branch>/PLAN.md` stays out of git, and per the single-commit rule below, no code commit happens until Phase 5.

### Single-commit rule (NON-NEGOTIABLE)

**Phases 2, 3, Gate A, Phase 4, and Gate B do NOT commit.** All code changes — initial implementation, self-verify fixes, Gate A fixes, code-review fixes, Gate B fixes — accumulate in the working tree against the branch base. The git state across these phases looks like one growing uncommitted diff vs. the base branch.

Phase 5 produces exactly one commit (or, if the diff is very large, a small number of logically-grouped commits at the end) — only AFTER `gates.code_review.passed === true` and (for STANDARD/HEAVY tier) `gates.gate_b.passed === true`.

The global pre-commit hook in `~/.claude/settings.json` enforces this mechanically by reading `gates.*.passed` from the state file. Attempts to commit before the gates pass will be blocked. Do not try to work around the hook — fix what the hook is telling you and try again. If the hook is wrong (e.g., resuming a run where gates legitimately already passed in a prior session), that is a bug in this skill or the state file, not license to bypass; surface to the user.

### Phase 2 — Execute (auto, NO COMMIT)

Invoke the `auto-task-implement` skill. It will tick off tasks in `.auto-task/<branch>/PLAN.md`. Treat each `<!-- DRIFT CHECKPOINT -->` marker as a **drift check — NOT a commit point** (nothing commits until Phase 5).

At each checkpoint:

1. **Drift check.** Get the list of changed files (`git status --short`). Filter out `.auto-task/<branch>/` paths. Diff the remaining list against PLAN.md's Blast Radius file list.
2. Classify each file outside Blast Radius:
   - **Adjacent** (continue silently, log to `state.history` with `result: "adjacent"`): test fixtures co-located with touched code, type-only imports, generated files (e.g., Prisma client output), lockfile updates, files in the same module as a planned file.
   - **Drift** (act on it): files in a top-level app/package the plan did not list; schema migrations (`prisma/migrations/`, `*.sql`); CI/CD config (`.github/workflows/`); `package.json` dependency add/remove; auth/payments/data-integrity touchpoints; any file the Risk rubric would now score as `2`.
3. On **Drift**:
   - Append `{ phase: "execute-checkpoint", result: "drift", files: [...], summary: "...", at: "ISO-8601" }` to `state.history`.
   - Re-run the D/R rubric with the actual touched set. If tier escalates, log to `effort.history` and apply the new tier's `/auto-task-verify` scope and fix-loop cap to subsequent iterations.
   - If the drift represents work outside the plan's intent (not just outside the planned file list — e.g., the plan was about typography and the drift adds auth code, or the plan was a pure-code change and the drift introduces an irreversible side effect not anticipated in Unknowns) → treat as out-of-scope per Loop rule clause 2 → STOP and surface. Otherwise continue.
4. Re-invoke `auto-task-implement` until all tasks are checked.

When `auto-task-implement` reports "all tasks complete", advance to Phase 3. **Do not commit.**

### Phase 3 — Self-verify (auto, NO COMMIT)

Invoke the `auto-task-verify` skill on the **uncommitted working-tree diff** (`git diff <base>` — no `..HEAD`, the changes are not yet committed). Parse its report.

**MCP usage in verification is open.** Any MCP available to the session may be used during self-verify and the gates if it's the most direct way to execute a Verification method or confirm an observation. Common picks:

- **playwright** — live UI / browser-driven AC checks (selector present, no console errors, screenshot diff, network call returns expected payload).
- **ide** — `getDiagnostics` to assert no new type/lint errors in the touched files.
- **claude_ai_Context7** — confirm an external library API the code now calls actually behaves the way the plan assumed.
- **plugin_figma_figma** — visual reference comparison for design-driven ACs.
- Others (Notion, Drive, Slack, etc.) only when the AC explicitly references content in that system.

Same rules as Phase 1 recon apply: **read-only by default** (writes to external systems are forbidden during verification without explicit user authorization in this run); auth prompts are not blockers — log `result: "ac-blocked"` for that AC and treat it as fail, since an AC that can't be executed can't pass; mandatory prerequisite skills (`figma-use` before `use_figma`) still load. If the AC's `Verification method` literally names an MCP call, run that call; otherwise, prefer the cheapest tool that produces the evidence.

**AC execution contract (NON-NEGOTIABLE).** In addition to whatever the `auto-task-verify` skill runs by default, you MUST execute every row in PLAN.md's Acceptance Criteria table whose `Gate` column contains `self-verify`. For each such row:

1. Run the `Verification method` literally as written (the command, assertion, or MCP call).
2. Capture stdout/stderr/exit code (or MCP response payload) and compare against `Expected result`.
3. Record the run in `state.history` as `{ phase: "self-verify-ac", ac: <#>, result: "pass|fail", evidence: "<command or MCP call + result snippet>", mcps: ["..."] (if any), at: "ISO-8601" }`.

`gates.self_verify.passed` cannot be set to `true` unless EVERY `self-verify`-gated AC row has a recorded `result: "pass"` entry from the current iteration. If the `auto-task-verify` skill's report says "all quality checks PASS" but an AC's bound check was never executed (e.g., the test file the AC names doesn't exist yet), that is a FAIL — surface it as a missing test, not a pass. Do not treat AC coverage as optional just because the generic checks were green.

- All `auto-task-verify`-skill tasks COMPLETE + all quality checks PASS + every `self-verify` AC executed with `result: "pass"` → set `gates.self_verify = { passed: true, at: <ISO>, evidence: "<short summary of checks that passed, including which AC rows ran>" }` and advance to Gate A.
- Any task PARTIAL/NOT FOUND, or any quality check FAIL → diagnose:
  - If the failure indicates flakiness (intermittent test, retry-passes-without-change) → STOP and surface per Loop rule.
  - Otherwise → invoke `/auto-task-fix` against the failing item (which modifies the working tree, no commit), then return to start of Phase 3. Increment `iteration.fix`.
- **Re-score hook.** Before incrementing `iteration.fix`, check whether the failure exposes anything outside PLAN.md's Blast Radius / Unknowns. If so, re-run the rubric, update `effort`, log to `effort.history`, and apply the new tier's caps and `/auto-task-verify` scope to the next iteration.
- Apply the Loop rule between iterations to detect "no progress". If `iteration.fix` has reached the current tier's fix-loop cap, do a forced re-score before STOPPING; if the tier escalates, the new cap applies and one more iteration is granted.

### Gate A — Independent verifier (auto, NO COMMIT)

**Before spawning the agent**, execute every AC row whose `Gate` column contains `gate-a`. Run the `Verification method` literally as written and compare exit code / output (or MCP response) against `Expected result`. The MCP allowance from Phase 3 applies here too — any available MCP may be used to execute a bound check, read-only by default. Record each as `{ phase: "gate-a-ac", ac: <#>, result: "pass|fail", evidence: "<command or MCP call + result snippet>", mcps: ["..."] (if any), at: "ISO-8601" }` in `state.history`. Any `gate-a` AC with `result: "fail"` short-circuits Gate A immediately — treat as an unsatisfied criterion and feed back to Phase 2 without running the agent (the agent's judgment is moot if a bound check already failed).

If every `gate-a` AC passed (or there are none), spawn the `task-execution-verifier` Agent with a fresh-context prompt containing:
- The Acceptance Criteria table from `.auto-task/<branch>/PLAN.md`.
- The current working-tree diff (`git diff <base>` — uncommitted).
- The list of `state.history` entries with `phase: "gate-a-ac"` (so the agent sees which checks already ran and what they returned).
- Explicit ask: "For each row in the Acceptance Criteria table, confirm the diff satisfies the `Criterion` AND that the listed `Verification method` would actually produce the `Expected result` if re-run now. For rows already executed above, validate the evidence is real (not fabricated) and that 'pass' actually maps to the criterion's intent (not a superficial match). Flag any criterion that is unsatisfied, weakly satisfied, or whose bound check doesn't truly test it. Do not propose new work — only judge completeness."

If any AC row failed its bound check OR the agent reports any criterion unsatisfied / weakly satisfied: feed findings back as a fix list, return to Phase 2 (append each unsatisfied criterion as a new implement task under a "Gate A findings" section in PLAN.md). After fixing, return to Phase 3. **Do not commit between iterations.**

If every `gate-a` AC passed its bound check AND the agent confirms all criteria satisfied: set `gates.gate_a = { passed: true, at: <ISO>, evidence: "<agent summary + which AC rows were executed with pass results>" }` and advance to Phase 4.

**Reminder (see top-of-file NON-YIELDING CONTRACT):** the verifier's report is INPUT. Set the gate, update state, write the next phase header, and immediately call the next tool — do not write a recap to the user.

### Phase 4 — Code review + fix loop (auto, NO COMMIT)

**MANDATORY tool:** invoke the `auto-task-code-review` **skill** via the Skill tool, on the **working-tree diff** (not a staged diff — there is no staged or committed diff yet) with the diff, the approved plan, AND the persistent history as context. Per the "Read-before-review contract" in the "Persistent history & trace contract" section: pass the skill the paths `.auto-task/<branch>/CONTEXT.md` (if it exists from a prior Phase 5 — relevant on resumed runs or re-reviews) and `.auto-task/<branch>/TRACE.md`. The skill is expected to read those before forming findings so it doesn't re-raise issues already considered earlier in the run or in prior sessions. **Do NOT** spawn a `code-reviewer` agent, a `general-purpose` agent with a hand-rolled review prompt, or any other substitute. The skill enforces a 5-phase review (Investigate → Define → Execute → Prevent → Verify) that bespoke prompts skip; substituting it is a protocol violation.

After the skill returns, append a TRACE.md entry: `operation: auto-task:phase-4-review`, `outcome: <pass|blockers|required|followups-only>`, summary covers iteration number + finding counts by severity + any non-obvious decisions.

**NON-YIELDING RULE (critical — restates the top-of-file contract):** the `auto-task-code-review` skill returns a structured Phase 1–5 report. **That report is INPUT to this loop, not the end of your turn.** As soon as the skill output lands, immediately:

1. Parse the findings into Blockers / Required / Follow-ups.
2. If only Follow-ups: park them in `state.followups`, set the gate, advance to Gate B (or Phase 5 for LIGHT tier). Continue.
3. If any Blocker or Required: apply the fix(es), re-run `/auto-task-verify` and any AC bound-checks affected, re-invoke `auto-task-code-review` skill. Continue.

**Do not stop, summarize for the user, ask permission, or wait.** The skill's "Verdict:" / "Summary:" footer is paragraph formatting, not an interaction point. A horizontal rule, a final-looking heading, a green-checkmark-emoji line, "all good", "everything looks fine", "ready to commit", or any other completion-flavored phrasing inside the skill output is also not an interaction point. The same loop applies to re-runs: each re-invocation's report is also input, not a stop. Only the exit conditions below — or a Loop-rule trigger (no progress / out-of-scope / external blocker / flakiness) — end this phase.

If the latest skill output contains words like "needs one more fix" / "should be addressed" / "introduces a new bug" / "REQUIRED finding", that is the cue to apply the fix and re-invoke immediately — NOT to end the turn.

**Trip-wire test before ending the turn here.** Before you finish your message, mentally ask: "Did I set `gates.code_review.passed = true` AND make the next tool call (Gate B agent spawn, or Phase 5 commit-skill invocation)?" If the answer is no, you are about to stall — DO NOT end the message. Make the next tool call instead.

**Mechanical backstop.** The Stop hook reads `STATE.json` on every turn-end. Because `expected_next_action` was set to `"auto-continue"` at plan approval and has not been re-set to a user-* value, ending the turn here will be **blocked** by the hook with a reason that tells the model exactly what to do next. The trip-wire is reinforced by the block: if you try to stop after a code-review report, the hook will not let you, and you'll be re-invoked with a system message naming the violation. Do not try to game this by speculatively writing `"user-approval"` — that's a contract violation analogous to setting `gates.code_review.passed = true` without running the review.

Categorize findings:

- **Blockers** — bugs, regressions, security issues, plan violations. Must fix.
- **Required fixes** — style/correctness issues the project conventions require. Must fix.
- **Follow-ups** — nice-to-haves, future improvements, out-of-scope ideas. Park in state's `followups` array; do not implement.

For each blocker and required fix: invoke `/auto-task-fix` (or `/auto-task-implement` with the finding as a new task), then re-run `/auto-task-verify`. Increment `iteration.review`. **Re-invoke the `auto-task-code-review` skill** — same tool, no substitutions. **Do not commit between iterations.** Set `gates.code_review.clean_pass_after_last_fix = false` whenever any fix is applied; only set it back to `true` after a *subsequent* `auto-task-code-review` skill run reports only follow-ups.

**Re-score hooks.**
- Before re-spawning the reviewer: if the latest pass surfaced blockers in files/areas outside PLAN.md's Blast Radius, re-run the rubric, update `effort`, log to `effort.history`, and apply the new tier's caps and `/auto-task-verify` scope to subsequent iterations.
- Before STOPPING on Loop-rule "no progress": forced re-score. If the tier escalates, grant ONE more iteration at the new tier (expanded `/auto-task-verify`, larger fix-loop budget, Gate B reinstated if previously skipped). If that iteration also makes no progress, STOP.

Exit conditions for this phase:
- Reviewer's latest pass produces only follow-ups → set `gates.code_review = { passed: true, tool: "skill:auto-task-code-review", clean_pass_after_last_fix: true, reviewed_diff_sha: "<sha>", at: <ISO>, evidence: "<reviewer summary; only follow-ups, no blockers/required>" }` → advance to Gate B (skipped at LIGHT tier — set `gates.gate_b.skipped_reason = "tier=light"` and go straight to Phase 5). The `tool` field MUST be the literal string `"skill:auto-task-code-review"` — the pre-commit hook rejects any other value (including agent invocations).
  - **`reviewed_diff_sha`** pins the exact diff this clean pass covered: compute it as `git diff --no-color --no-ext-diff --no-textconv --no-renames --diff-algorithm=myers --src-prefix=a/ --dst-prefix=b/ <base> | git hash-object --stdin` (where `<base>` is `state.base`). The flags MUST match those the `enforce-gates.sh` hook uses verbatim — they pin the diff text against git-config drift so an unchanged tree always hashes the same; omitting them risks a spurious staleness block. The pre-commit hook recomputes the same hash at commit time and **blocks the commit if it differs** — i.e. if any tracked code changed after the review went clean. Recompute and overwrite this field on every subsequent clean pass (e.g. after a Gate B fix forces a re-review). Never copy a stale value forward; set it from a freshly-computed hash only when the review is genuinely clean, exactly like the boolean flags.
- Loop rule triggers (no progress / out-of-scope / blocker / flakiness) **after** the re-score hook has been given its chance → STOP and surface (do NOT set `gates.code_review.passed`).

### Gate B — Adversarial verifier (auto, NO COMMIT)

Second `task-execution-verifier` pass with an **adversarial** stance — flip the prompt from "is this complete?" to "find what's wrong." Pass only if the agent genuinely tries and fails to find issues.

Spawn with a fresh-context prompt containing:
- The Acceptance Criteria from `.auto-task/<branch>/PLAN.md`.
- The full diff vs. base (`git diff <base>` — the uncommitted working-tree diff; per the single-commit rule nothing is committed until Phase 5, so `<base>..HEAD` / `<base>...HEAD` would be empty here and the adversarial verifier would see no code).
- The list of review findings that were addressed in Phase 4.
- Explicit ask: "Adversarially review this diff. Your job is to find what's wrong, not confirm what's right. Hunt for:
  - An acceptance criterion only superficially satisfied (the test exists but doesn't exercise the AC's intent).
  - A regression — any existing behavior this diff could break.
  - A bypass — input or sequence that reaches the new code with protections circumvented.
  - An edge case the diff doesn't handle (empty / null / concurrent / large / malformed input).
  - A Phase 4 review finding 'addressed' in name but not in behavior.
  Return up to 6 specific findings. For each: cite `file:line`, describe how to reproduce or trigger it, rate severity (blocker / required / follow-up). If you genuinely cannot find any after thorough search, return exactly `No adversarial findings.` — but the bar is 'you tried and failed,' not 'you didn't try.'"

Resolve by severity:
- Any **blocker** or **required** finding → feed back to Phase 4 with the finding as a new fix task; increment `iteration.review`. **Do NOT set `gates.gate_b.passed` and do NOT advance.** Reset `gates.code_review.passed` to `false` since the addressed-by-name-only failure means the review didn't really hold up.
- Only **follow-up** findings → park in `state.followups`, set `gates.gate_b = { passed: true, at: <ISO>, evidence: "<adversarial summary; only follow-ups>" }`, advance to Phase 5.
- `No adversarial findings.` → set `gates.gate_b = { passed: true, at: <ISO>, evidence: "No adversarial findings" }`, advance to Phase 5.

**Trip-wire test (same shape as Phase 4's):** after the Gate B agent returns, before ending the turn — did you (a) write the gate-b resolution to state AND (b) make the next tool call (a Phase 4 fix Edit if blockers, or the Phase 5 git-stage command if clean)? If not, you're about to stall. Don't end the message. Call the next tool.

### Phase 5 — Handover (auto, SINGLE COMMIT)

This is the **only phase that commits**. By the time you reach it, the working tree contains the entire accumulated diff (initial implementation + all fixes from self-verify, Gate A, code-review, Gate B) and the state file records that all required gates passed.

1. **Verify gates** before doing anything else:
   - `gates.code_review.passed === true` — required.
   - For STANDARD/HEAVY tier: `gates.gate_b.passed === true` (or `gates.gate_b.skipped_reason` set with a valid reason).
   If either is missing, STOP and surface — something went wrong in the pipeline and you should not be in Phase 5. Do NOT manually set the flags to escape this.
2. **Build the change diagram.** Produce a human-readable Mermaid diagram that the reviewer can scan in ~10 seconds to understand what the run did and (where applicable) what the prior state looked like. Embed it in the PR body under `## Change diagram` so GitHub renders it inline. This is a MANDATORY step — every auto-task PR must carry a diagram or a one-line documented skip.

   **Pick the diagram type that matches the change.** Use ONE diagram unless the task spans multiple concerns and a second adds clear value:

   | Task shape | Mermaid diagram type | What to show |
   |---|---|---|
   | Module / architecture change, refactor, new component wiring | `flowchart` with `subgraph Before` and `subgraph After` | Boxes for modules/files; arrows for calls/imports/data flow. Highlight added/removed/changed nodes (see styling below). |
   | New user flow, request lifecycle, API call sequence | `sequenceDiagram` | Actors as lanes; messages in order. If pre-existing flow exists, show it once with `Note over X: before` annotations on the steps that changed. |
   | State-machine or status change | `stateDiagram-v2` | All states + transitions. Mark new transitions with a comment. |
   | Schema / data-model change | `erDiagram` | Entities + relationships. Annotate new fields/tables in a `Note:` line below the diagram. |
   | File-tree reorganization, large rename/move | `flowchart` tree (top-down) | Before tree on the left, After on the right via two `subgraph`s. |
   | Bug fix in an existing flow | `sequenceDiagram` or `flowchart` | Show the flow once; annotate the broken step (`Note over X: was: <bad>`) next to the fixed step. |
   | Pure config / docs / dep bump / typo / formatting-only | — (skip) | Write a single bullet under `## Change diagram` instead: `Skipped — <type>-only change, no flow/structure shift.` Log to state. |

   **Before/After convention.** When the prior state matters, show it. Two patterns are acceptable:
   - **Two subgraphs in one diagram** (preferred for compactness): `subgraph Before` / `subgraph After`. Use the same node IDs across subgraphs only if they refer to the same artifact.
   - **Two separate fenced diagrams** under sub-headings `### Before` and `### After` — use this when the diagrams are too dense to share a single canvas.

   For greenfield additions where there is no meaningful "before" (e.g., a brand-new module): show only `## After` and add a one-line note: `No prior state — this is a net-new <thing>.` Don't fabricate a "before" just to fill the slot.

   **Highlight what changed.** Within the diagram, mark new/changed/removed elements so the reviewer's eye lands on the delta:
   - Mermaid `classDef` styling — define `added`, `removed`, `changed` classes and apply with `class NodeId added`. Example:
     ```
     classDef added fill:#dcfce7,stroke:#16a34a,stroke-width:2px
     classDef changed fill:#fef9c3,stroke:#ca8a04,stroke-width:2px
     classDef removed fill:#fee2e2,stroke:#dc2626,stroke-dasharray:4 2
     ```
   - For sequence/state diagrams where classDef doesn't apply, use `Note over X: NEW` / `Note over X: CHANGED` / strike-through prose in a `Note`.

   **Source of truth.** Derive the diagram from the actual staged diff plus PLAN.md's Blast Radius — not from the original task description. The diagram must reflect what was *built*, not what was *planned* (the two can diverge legitimately via drift events; the diagram tracks the final state).

   **Length budget.** Aim for ≤ 25 nodes / ≤ 15 sequence messages / ≤ 8 entities. If the diagram would exceed that, abstract: collapse a cluster of small files into one node labeled with the cluster name, or split the diagram into ≤ 2 focused views (one per concern). A bloated diagram is worse than no diagram.

   **Render check.** Mermaid syntax errors break the PR-body render. Sanity-check the diagram for unmatched brackets, unquoted node labels that contain spaces, reserved words, and trailing semicolons (Mermaid is whitespace-sensitive). If unsure, simplify rather than ship a broken render. If a richer canvas is genuinely needed (multi-page architecture, design-system diagram), use the `figma-generate-diagram` skill — load it first per its own MANDATORY-prerequisite rule — to produce a FigJam diagram and link the resulting URL under `## Change diagram` instead of embedding Mermaid.

   **Persist the source.** Save the chosen diagram (or the skip line) to `.auto-task/<branch>/recon/change-diagram.mmd` so it can be regenerated on resume. Log a `state.history` entry: `{ phase: "handover-diagram", type: "<flowchart|sequenceDiagram|stateDiagram-v2|erDiagram|skipped>", reason: "<one line>", at: "ISO-8601" }`.

3. **Collect verification artifacts.** Before writing CONTEXT.md, gather the proofs of completion that confirm the fix/feature actually works, and save them under `.auto-task/<branch>/artifacts/`. These are gitignored — they exist for local review, future `/auto-task-code-review` sessions, and your own audit trail. Examples per task shape:
   - **Tests added/touched.** Save `<test-runner> <changed-test-paths> 2>&1` output as `artifacts/tests.txt`. Include exit code on the last line.
   - **Type / lint / build.** Save the final passing run as `artifacts/typecheck.txt`, `artifacts/lint.txt`, `artifacts/build.txt` (only the runs whose ACs reference them).
   - **UI / visual changes.** Save the playwright screenshots (before + after if a "before" was captured during Phase 1 recon) as `artifacts/screenshot-before.png` / `artifacts/screenshot-after.png`.
   - **Network / API changes.** Save `curl -i` transcripts or playwright network logs as `artifacts/request-<n>.txt`.
   - **Performance changes.** Save the lab measurement (Lighthouse, PSI, vitals output) as `artifacts/perf-before.json` / `artifacts/perf-after.json`.
   - **Diff snapshot.** Always save `git diff <base> > artifacts/final-diff.patch` so a reviewer can replay the change without pulling the branch.
   - **AC-specific evidence.** For each AC whose Verification method produced significant output, save it as `artifacts/ac-<#>-evidence.{txt|json|png}`.

   Skip categories that don't apply — don't fabricate files. Log one `state.history` entry summarizing what was saved: `{ phase: "handover-artifacts", saved: ["tests.txt", "final-diff.patch", ...], at: "ISO-8601" }`.

4. **Write the CONTEXT.md artifact (LOCAL ONLY, gitignored).** Write a single Markdown file at `.auto-task/<branch>/CONTEXT.md` that captures everything a downstream consumer (human, a later `/auto-task-code-review` session, `/review` skill, or future `/auto-task` run touching the same area) needs to understand this run without replaying the conversation. This file is **NOT committed** — it lives in the gitignored `.auto-task/` tree alongside STATE.json, PLAN.md, TRACE.md, and `artifacts/`.

   If `.auto-task/<branch>/CONTEXT.md` already exists (re-run, resumed run), overwrite without prompting — it's generated content.

   **Required sections (in this order; if a section has nothing to say, keep the heading and write `None.` with a one-line reason — predictable structure is the artifact's whole point):**

   ```markdown
   # Auto-task run context — `<branch-name>`

   _Generated by `/auto-task` on <ISO date>. Local, gitignored. Lives at `.auto-task/<branch>/CONTEXT.md` until the branch folder is pruned._

   ## Task
   <verbatim task description from state.description>

   ## Human choices
   The user's explicit decisions during this run. Load-bearing — they constrain what was built and why. Future reviewers should not re-litigate them unless they disagree with the choice itself, not its consequences.

   ### Clarifying Q&A (Phase 1, before plan)
   This section reflects ONLY entries where the user actually weighed in. The Resolved bucket from PLAN.md's `## Clarifications` is auditable in PLAN.md itself and does not belong in CONTEXT.md's `Human choices` — those were not user choices.

   For each state.history entry with `phase: "define-clarify"` AND `resolution: "asked"`:
   - **Q:** <question text as presented via AskUserQuestion>
     - Options offered: <option labels, comma-separated; mark the recommended one with *>
     - **Chosen:** <user's selected option, verbatim>
     - Why it matters: <one line, derived from the question's description>

   If no `resolution: "asked"` entries exist (every candidate was Resolved with a cite, or there were no candidates at all), write: `None — every ambiguity was resolved with evidence; see PLAN.md ## Clarifications for the cites.`

   ### Approach decision
   - Chosen approach: <name from PLAN.md `## Approach`, or "N/A — single viable approach" if selection was skipped>
   - Selected by: <"auto (clear winner)" | "user (close-call/high-stakes pick)">
   - Rejected alternatives: <names + one-line rejection rationale each, or "None">

   ### Plan approval
   - Approved at: <ISO timestamp when `approved: true` was set>
   - Approval keyword the user typed: <verbatim, if captured; else "approved (exact wording not captured)">
   - Plan critique surfaced before approval: <the `## Critique` section's **Auto-fixed** and **For your judgment** parts, or "No issues found." verbatim>
   - User amendments before approval: <if the user asked for plan edits prior to typing approval, summarize them; else "None — plan accepted as written.">

   ### Mid-run user interventions (if any)
   Any Surfacing-protocol stops the user resolved during the run (loop-rule triggers, destructive-action confirmations, drift escalations the user weighed in on). For each: when it happened, what was surfaced, what the user decided, what changed in the run as a result. If none, write `None — run completed without mid-pipeline user intervention.`

   ### Push / PR decision (Phase 5)
   - At the Phase 5 push prompt, the user chose: <"push & open PR" | "push only" | "hold — do not push" | "auto (no prompt — see CLAUDE.md authorization)">

   ## Plan summary
   <verbatim Feasibility/Unknowns/Blast-radius/Effort header lines from PLAN.md, then a 2-4-bullet summary of the plan body>

   ## Effort & tier
   - Initial: <tier> (D=<n>, R=<n>)
   - Final: <tier> (D=<n>, R=<n>)
   - Escalations: <one bullet per `effort.history` entry, in order; or "None.">

   ## Acceptance Criteria results
   For each AC row in PLAN.md:
   - **AC #N — <criterion text>**
     - Gate: <self-verify | gate-a | gate-b>
     - Verification method: <command/observation, verbatim from PLAN.md>
     - Result: <pass | fail-then-fixed | n/a>
     - Evidence: <last state.history entry's `evidence` field for this AC; if a file was saved, link as `artifacts/ac-<#>-evidence.<ext>`>

   ## Verification trail
   - **Self-verify** (Phase 3): <gates.self_verify.evidence; iteration count if > 1>
   - **Gate A** (independent verifier): <gates.gate_a.evidence; or "skipped — <reason>" if applicable>
   - **Code review** (Phase 4, `auto-task-code-review` skill): <gates.code_review.evidence; iteration count if > 1>
   - **Gate B** (adversarial verifier): <gates.gate_b.evidence; or "skipped — tier=light" / other skip reason>

   ## Drift events
   One bullet per `state.history` entry with `result: "drift"`. Format: `<phase>: <files outside Blast Radius> — <one-line summary> — <action taken: continued | tier escalated | surfaced>`. Skip `result: "adjacent"` entries. If none, write `None — execution stayed within planned Blast Radius.`

   ## Files touched
   Output of `git diff --cached --name-status <base>` at the moment of staging, grouped by status (Added / Modified / Deleted / Renamed). Include line counts per file (`--numstat` summary). Full unified diff is in `artifacts/final-diff.patch`.

   ## Change diagram
   The Mermaid diagram from step 2, inlined here so this file is self-contained.

   ## Artifacts saved
   One bullet per file under `.auto-task/<branch>/artifacts/` with a one-line "what it shows": `artifacts/tests.txt — pnpm test packages/ui/__tests__/Foo.test.ts (exit 0, 24 passing)`.

   ## Parked follow-ups
   One bullet per `state.followups` entry: `<source>: <note>`. If none, write `None.`

   ## Reviewer notes
   Anything that would help a `/auto-task-code-review` re-run or a human reviewer skip dead ends:
   - Areas the run touched but deliberately did NOT change (with one-line "why not").
   - Known weak spots in the diff the reviewer should look at first.
   - Test files the user should run if they want to spot-check.
   - Any external system (live URL, design file, MCP-fetched doc) that was load-bearing during Phase 1 recon — link or path.
   ```

   **Source of truth.** Every line MUST be derivable from `state` + PLAN.md + the staged diff + saved artifacts. Do not invent facts, do not embellish, do not paraphrase user choices — quote verbatim where possible.

   **Render check.** Confirm the file parses as valid Markdown — fenced code blocks are closed, no stray triple-backticks inside the Mermaid block.

   Log a `state.history` entry: `{ phase: "handover-context", path: ".auto-task/<branch>/CONTEXT.md", at: "ISO-8601" }`.

5. **Stage the code changes.** Run `git restore --staged .auto-task/ 2>/dev/null || true` defensively (catches both `.auto-task/<branch>/` and any stray sibling), then `git add` the planned files only — never `.auto-task/`, never CONTEXT.md, never the artifacts. Confirm `git diff --cached --name-only` shows no `.auto-task/` paths and no files outside PLAN.md's Blast Radius (counting drift events that legitimately escalated tier).
6. **Commit.** Use the `auto-task-commit` skill — message derives from PLAN.md's summary. The pre-commit hook will validate the gates; if it blocks, do not work around it.
7. Verify `.auto-task/` did not leak into history: `git log <base>..HEAD --name-only -- .auto-task/` MUST be empty.
8. **Yield-point: push / PR prompt.** Set `expected_next_action: "user-push-prompt"` in STATE.json — this is the single allowed Phase 5 interaction surface and the Stop hook will allow the yield. Ask the user once whether to push & open PR / push only / hold. After the user answers, write back `expected_next_action: "auto-continue"` and proceed with their choice. If the user holds, jump to step 11 (record state, skip 9–10).
9. Push the branch if it has no upstream: `git push -u origin HEAD`.
10. Create the PR with `gh pr create`. Title from the plan summary (under 70 chars). Body:

   ```
   ## Summary
   <2-4 bullets from the approved plan>

   ## Change diagram
   ```mermaid
   <diagram from step 2, or the skip line>
   ```

   ## Acceptance Criteria
   <checklist from PLAN.md, all checked>

   ## Test plan
   <quality checks run + their results>

   ## Run notes
   <derived from state — see "Run notes content" below>

   ## Follow-ups (not in scope)
   <items from state.followups, if any>
   ```

   Per the global rule in `~/.claude/CLAUDE.md`: do NOT add a `Co-Authored-By: Claude` trailer, a `🤖 Generated with [Claude Code]` line, or any other AI-attribution marker to the PR body or title.

   The PR body does NOT reference `.auto-task/<branch>/CONTEXT.md` or anything under `.auto-task/` — those paths are local-only and would be broken links for anyone reading the PR on GitHub. Reviewers who want the full context fetch the branch and read `.auto-task/<branch>/CONTEXT.md` locally; the `/auto-task-code-review` skill is expected to do this automatically (see "Read-before-review contract").

11. **Append the handover trace.** Append a final entry to `.auto-task/<branch>/TRACE.md` summarizing the completed run (see "Persistent history & trace contract" for format): operation=`auto-task:phase-5`, summary covers PR URL, files touched count, AC pass count, follow-up count.

12. Write `pr_url`, `phase: "done"`, AND `expected_next_action: null` to state — the run has reached its terminal state and the Stop hook allows the final yield. Report the PR URL to the user along with: (a) a one-line description of the diagram type used, and (b) a one-line pointer that local context + artifacts live at `.auto-task/<branch>/` for future reviews.

**Run notes content.** Derive entirely from state and PLAN.md — do not invent. Include only buckets that produced bullets; omit empty ones. Format as labeled bullet groups:

- **Effort escalations** — one line per entry in `effort.history`: `LIGHT → STANDARD (schema migration entered blast radius, Phase 2 checkpoint 3)`.
- **Drift events** — one line per `state.history` entry with `result: "drift"`: summary + files. (Skip `result: "adjacent"` entries — they're noise.)
- **Loop iterations** — only if `iteration.fix > 1` or `iteration.review > 1`: `Self-verify ran N times; review loop ran M times`.
- **Verifier findings addressed** — one line per Gate A / Gate B finding that triggered a fix (derive from `state.history` entries from those phases).
- **Plan critique at approval** — if `.auto-task/<branch>/PLAN.md` `## Critique` section was non-empty (not `No issues found.`), include both its **Auto-fixed** and **For your judgment** parts verbatim under this label so reviewers see what the re-plan loop repaired and what concerns were left for human judgment before approval.

If none of the above produced bullets, write a single line: `Clean run — no escalations, no drift, no loop retries.`

## Persistent history & trace contract

`.auto-task/` is the local, gitignored audit trail of every `/auto-task` run on this clone. It survives across runs, branches, and Claude Code sessions so any later operation (a `/auto-task-code-review` re-run from a fresh session, a `/auto-task-verify` pass, a future `/auto-task` touching the same code) can pick up the history without replaying conversations.

### Folder layout (per branch)

```
.auto-task/
└── <branch-name>/                # branch path preserved literally (fix/foo → .auto-task/fix/foo/)
    ├── STATE.json                # run-state machine
    ├── PLAN.md                   # approved plan + Approach + Critique + AC + Pre-flight + Recon
    ├── CONTEXT.md                # Phase 5 handover artifact (regenerated each Phase 5)
    ├── TRACE.md                  # append-only operation log (this section's contract)
    ├── recon/                    # Phase 1 reconnaissance outputs + change-diagram.mmd
    ├── fixes/                    # per-fix patch notes / lessons (written by auto-task-fix)
    └── artifacts/                # proofs of completion (tests, screenshots, diffs, logs)
```

Per-branch folders are NEVER auto-deleted by `/auto-task`. They accumulate. A user who wants to prune may `rm -rf .auto-task/<old-branch>/` manually; the skill never touches another branch's folder. On a fresh clone where `.auto-task/` doesn't exist, create it on first run.

### TRACE.md format

`TRACE.md` is an **append-only** Markdown log. Never rewrite or delete prior entries — even if a prior entry was wrong, append a new one correcting it (the value of the log is partly that it reflects what was actually believed at each step). Header on first creation:

```markdown
# Auto-task trace — `<branch-name>`

Append-only log of every operation that touched this branch. Source-agnostic — `/auto-task` writes here, but so should any later `/auto-task-code-review`, `/auto-task-verify`, `/auto-task-fix`, or other audit-relevant tool. Read top-to-bottom to reconstruct the run's history.

---
```

Each entry is one Markdown block in this exact shape:

```markdown
## <ISO-8601 timestamp> · <operation> · <source>

- **Phase / context:** <e.g., auto-task phase-3-self-verify, external /auto-task-code-review session, manual /auto-task-fix>
- **Inputs:** <what the op read — STATE.json snapshot? PLAN.md? a specific file/diff range?>
- **Summary:** <one to three sentences, plain prose. What was done, what was decided, what changed.>
- **Outcome:** <pass | fail | partial | surfaced | no-op>
- **Artifacts produced:** <bullets pointing to files under artifacts/ that this op created; "none" is OK>
- **Notes for future reviewers:** <optional — surprises, dead ends explored, things to look out for next time>

---
```

Field rules:

- **`<operation>`** — short slug: `auto-task:phase-1-define`, `auto-task:phase-3-self-verify`, `auto-task:phase-4-review`, `auto-task:phase-5-handover`, `code-review:standalone`, `verify:standalone`, `fix:standalone`, `manual:<one-line>`. The slug carries enough that `grep` finds it.
- **`<source>`** — `claude-code session <session-id-or-date>` if running inside a Claude Code session; `human` if a person edited the trace manually; `ci` if a CI job appended; `external-llm:<tool>` for other LLM-driven reviews. The point is to know *who* spoke, so trust can be calibrated.
- **`<ISO-8601 timestamp>`** — to-the-minute is fine; entries from the same minute are ordered by appearance.
- **`Summary`** — write so a future reader who didn't see the original conversation can still understand the decision. No internal jargon, no "see chat above".

### When to append a trace entry

`/auto-task` itself appends an entry at every phase transition (Phase 1 start, Phase 1 plan-approved, Phase 2 → 3, Gate A done, Phase 4 → 5, Phase 5 commit done, Phase 5 PR opened) and at every loop-rule surface or drift event. The schema is the same — don't write free-form prose outside the block format.

Any other tool or session that does meaningful work on the branch SHOULD append too. Specifically:

- **A standalone `/auto-task-code-review` on the branch** — append before stopping. Entry summarizes: how many findings, severity breakdown, whether they were applied, and whether the reviewer read this trace first.
- **A standalone `/auto-task-verify`** — append the verification outcome (passing checks, failing checks, what was inferred about regression risk).
- **A standalone `/auto-task-fix` after the PR is open** — append what the bug was, root cause, the patch summary.
- **A manual code change pushed to the branch outside `/auto-task`** — when the user mentions it, append `manual:<short-reason>` with the gist.

Skipping an append leaves a gap in the trail. The contract is *append liberally* — when in doubt, append a short entry; never lengthy back-fills.

### Read-before-review contract

**Any code-review or audit operation on a branch MUST first check whether `.auto-task/<branch>/` exists and, if so, read CONTEXT.md and TRACE.md before issuing findings.** The reason: a reviewer that doesn't know the run's human choices, drift events, prior review iterations, and parked follow-ups will (a) re-raise findings that were explicitly considered and resolved, (b) miss real issues that earlier reviewers flagged but never followed up on, and (c) waste user time on already-decided questions.

The contract for any consumer (the `/auto-task-code-review` skill, the `/review` skill, a `general-purpose` agent doing a review, a future `/auto-task` run touching the same code):

1. **Discover.** `git branch --show-current` → look for `.auto-task/<current-branch>/`. If absent, the branch isn't auto-task-tracked; proceed normally without history input.
2. **Read CONTEXT.md** if present — it's the curated summary. Pay attention to the "Human choices" section: never re-raise findings about choices the user already weighed in on (unless you genuinely disagree with the choice itself).
3. **Read TRACE.md** if present — it shows what prior reviewers found and how those findings were resolved. If your finding overlaps with a TRACE entry, cite the prior entry and explain what's different now.
4. **Read the latest STATE.json** if you need machine-readable detail (gates, effort tier, iteration counters).
5. **Append your own trace entry** when the operation completes, per the TRACE.md format above. This is how the next reviewer benefits from your work in turn.

`/auto-task`'s Phase 4 code-review skill invocation is itself a consumer of this contract — when it runs, it should pick up any prior TRACE.md entries (e.g., from an out-of-session manual review) and account for them.

### Pruning

Per-branch folders are never auto-pruned. Recommended user practice: after a branch is merged and deleted, `rm -rf .auto-task/<branch>/` to keep the tree compact. The skill provides no automation for this — it's the user's local disk, and stale folders are harmless beyond disk space.

## Surfacing protocol (when loop rule triggers)

When the workflow stops mid-pipeline:

1. Save current state to `.auto-task/<branch>/STATE.json`, setting `expected_next_action: "user-approval"` — surfacing is a legitimate yield and the Stop hook will allow it. Without this write, the Stop hook will block your status message from being delivered because `expected_next_action` is still `"auto-continue"` from the previous transition.
2. Append a TRACE.md entry: `operation: auto-task:surfaced`, `outcome: surfaced`, summary covers the loop-rule clause + the evidence (e.g., "Iteration 4 of review loop produced the same 2 findings as iteration 3 — no progress"), and links to any artifacts that show the failure (e.g., `artifacts/test-fail.txt`).
3. Write a short status to the user including:
   - **Why stopped** — which loop-rule clause triggered, with evidence.
   - **Current state** — what's done, what's pending, what's failing.
   - **Suggested next move** — one or two concrete options for the user.
4. Do not auto-resume. Wait for the user. When the user resumes, write `expected_next_action: "auto-continue"` before making the next tool call.

## Rules

- **Acceptance Criteria are mandatory and load-bearing.** Phase 1 cannot stop for human approval unless `.auto-task/<branch>/PLAN.md` contains an AC table that satisfies all five rules in the "Acceptance Criteria contract" above. Phase 3's `gates.self_verify.passed` cannot be set to `true` unless every `self-verify` AC has been executed with a recorded pass. Gate A's `gates.gate_a.passed` cannot be set to `true` unless every `gate-a` AC has been executed with a recorded pass AND the independent verifier confirmed the bound checks really test the criterion's intent. There is no escape hatch — "the task is too simple for AC", "the AC was implicit", or "the generic verify checks covered it" are not acceptable reasons to skip. If you genuinely cannot articulate measurable AC for a task, STOP and surface to the user; do not invent passes.
- **`expected_next_action` is mandatory and mechanically enforced.** Every state write that occurs after `approved: true` MUST include an `expected_next_action` value. The Stop hook reads this field on every turn-end and blocks the model from yielding when the value is `"auto-continue"`. The only legitimate user-* values are `"user-approval"` (Phase 1 plan presentation, Loop-rule surface, destructive-action confirmation) and `"user-push-prompt"` (the single Phase 5 push/PR/hold ask). Setting a user-* value when no user gate is actually pending is a contract violation analogous to flipping a gate flag without running the gate. The Stop hook is the antidote to sub-skill output looking completion-shaped; do not work around it.
- Do not modify `CLAUDE.md`, project settings, or git config.
- Never use `--no-verify`, `--no-gpg-sign`, or `--force` on git operations unless the user has already explicitly authorized them in this run.
- Commit only with the `auto-task-commit` skill so messages stay consistent.
- **Never commit anything under `.auto-task/`.** That directory is local harness + history only — see the "harness scratch" rule in "Operating principles" and the "Persistent history & trace contract" section. Every commit must be code/test/doc changes that pertain to the user's task. Before each commit, run `git restore --staged .auto-task/ 2>/dev/null || true` and then check `git diff --cached --name-only` — if any `.auto-task/` path appears, stop and unstage it.
- **Never commit other people's pre-staged work.** When the run starts, capture `git diff --cached --name-only` into `state.history` as the "pre-existing-staged" baseline. At every commit, exclude any path in that baseline that you did not modify yourself — those belong to the user's separate work and must not be swept into auto-task commits.
- Each Agent spawn (Gate A, Gate B) gets fresh context with only the diff and the plan — do not pass conversation history into them. Agents MAY read `.auto-task/<branch>/CONTEXT.md` and `.auto-task/<branch>/TRACE.md` if instructed in their prompt; this is the recommended way to give them prior-review history without leaking the parent session's conversation.
- Phase 4 code review is invoked via the **`auto-task-code-review` skill** through the Skill tool. Never spawn a `code-reviewer` agent, never spawn a `general-purpose` agent with a hand-rolled review prompt, and never write your own review prompt inline. This is a non-negotiable rule (the user has set it explicitly) and is enforced by the pre-commit hook: `gates.code_review.tool` must equal `"skill:auto-task-code-review"`. Before invoking the skill, hand it the path `.auto-task/<branch>/CONTEXT.md` (and TRACE.md if it exists) per the "Read-before-review contract" so it can pick up prior decisions.
- If `.auto-task/<branch>/STATE.json` exists when starting a new `/auto-task <description>`, ask the user: resume the existing run, or start fresh? On "start fresh", advise the user to either rename / remove `.auto-task/<branch>/` (preserving history if they want) and (optionally) switch off the prior run's branch (recorded in `state.branch`) before re-running — auto-task will not delete prior work.
- If a previous bad run created a commit containing `.auto-task/` files (legacy behavior before this rule existed), do NOT silently rewrite history. Surface the issue: report the offending commit hash(es) and ask the user how to clean up (interactive rebase to drop, `git reset --soft` and recommit, or leave it).
- Mark items as follow-ups liberally. The bar for adding to the active loop is "addresses an Acceptance Criterion or fixes a blocker"; everything else parks.
