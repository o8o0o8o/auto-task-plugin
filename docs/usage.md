# Usage

- [Start a new run](#start-a-new-run)
- [What Phase 1 does](#what-phase-1-does)
- [What runs after approval](#what-runs-after-approval)
- [Resume an interrupted run](#resume-an-interrupted-run)
- [The run picker (`/auto-task-resume`)](#the-run-picker-auto-task-resume)
- [Running multiple runs in parallel](#running-multiple-runs-in-parallel)
- [Surfacing protocol](#surfacing-protocol)
- [Read-before-review contract](#read-before-review-contract)
- [Recommended project memories](#recommended-project-memories)

## Start a new run

```
/auto-task <plain-English task description>
```

The skill creates a branch, sets up the per-branch history folder at `.auto-task/<branch>/`, runs Phase 1 reconnaissance, asks clarifying questions, builds an Acceptance Criteria table, critiques its own plan, and presents it for your approval.

## What Phase 1 does

### Reconnaissance

Read-only, using whatever tooling is available — Playwright, Context7, Figma. Any link in the task card is loaded **two-tier**: an ordinary fetch first, with a Playwright fallback when that returns no usable data. Videos like Loom get screenshots plus a transcript. `hooks/extract-links.sh` classifies the links as a mechanical assist, and has a focused test under `tests/`.

### Approach selection

When more than one implementation is viable, Phase 1 generates and scores candidates, then picks one — surfacing close calls to you rather than deciding silently.

### Forwarding clarifying questions to the ticket owner

The person running `/auto-task` often isn't the one who owns the ticket and holds the answers. So when Phase 1 has open questions (or folds an approach choice to you), it **first asks how you want to handle them**:

- **Answer them here** — the questions appear as pickers.
- **Get a paste-ready ticket comment to forward** — it renders the comment (short, human-like, no names, no greetings, functionality only) and **pauses**. Drop it into the ticket, then resume `/auto-task` with the owner's answers and it picks up where it left off.

Making the comment a first-class choice, rather than an easy-to-miss aside, is what guarantees it always shows up.

### Comments in your voice (`VOICE.md`)

Every comment the pipeline drafts — the Phase-1 ticket comment, the Phase-5 PR title and body, the Phase-7 preview verdict comment — is written in the voice from a `VOICE.md` when one exists.

Resolution takes the first non-empty file:

1. Project-local `<repo>/.claude/VOICE.md` — wins
2. Global `~/.claude/VOICE.md`
3. Otherwise, the built-in default style

Voice shapes only the free prose. It never overrides hard rules: the no-AI-attribution ban, the ticket comment's no-names / no-greetings / functional-only contract, or the PR body's structured tables, checklist, and diagram. It's fail-open and silent — a missing or empty file just means defaults, and it adds no prompt, stop, or gate.

### Every run has a title

Phase 1 derives a concise **run title** from your task and surfaces it so you can tell sessions apart at a glance. It prefixes every sub-agent's status label (the running-agent line reads `<title> · Gate B adversarial verify`) and leads each phase message with a `▶ auto-task: <title> — Phase N` banner.

It's purely cosmetic — derived locally, no tracker integration, and it changes no gate or control flow.

## What runs after approval

After you type `approved` / `proceed` / `yes`, the pipeline runs unattended through:

| Phase | What it does |
|---|---|
| **Phase 2 · Execute** | Invokes `auto-task-implement`; drift-checks each checkpoint against the plan's Blast Radius |
| **Phase 3 · Self-verify** | Invokes `auto-task-verify`; runs every Acceptance Criterion bound to the `self-verify` gate |
| **Gate A** | Spawns `task-execution-verifier` in `completeness` mode; runs every AC bound to `gate-a` |
| **Phase 4 · Code review** | Invokes `auto-task-code-review`, by default from a fresh-context agent |
| **Gate B** | Spawns `task-execution-verifier` in `adversarial` mode, at every tier, bounded by a per-scope pass cap. Once a pass has run its surfacing triggers are read only on a pass that reopened something — a pass that finds nothing to reopen just passes, and never interrupts you; reaching the cap before a pass even runs still surfaces |
| **Phase 5 · Handover** | Optionally refreshes stale docs, then a single commit, push, and PR with an embedded change diagram. Asks once: push & open PR / push only / hold |
| **Phase 9 · Release** *(opt-in)* | Optionally cuts the landed work as a release. **Local only — never pushes, never publishes** |

Phases 4 and Gate B carry the most nuance — how findings are graded, when a round reopens the loop, and what the caps are. That contract is in **[Architecture → The review loop](architecture.md#the-review-loop)**.

## Resume an interrupted run

```
/auto-task
```

With no argument, it reads `.auto-task/<current-branch>/STATE.json` and continues from where it left off.

Resume re-enters the recorded phase **from the top**. Phases are designed to be re-entrant: re-running self-verify, a gate, or the review loop on the current working tree is idempotent, because it recomputes from disk state rather than double-applying. The component preflight re-runs on every resume, in case a skill or the verifier agent was uninstalled between sessions.

## The run picker (`/auto-task-resume`)

Each run lives in its own git worktree keyed to a branch, with `STATE.json` **inside that worktree**. Two consequences:

- `claude --resume` resumes a *conversation session*, not a run — so it can drop you somewhere with no run in sight.
- Bare `/auto-task` only knows about the run on the branch you happen to be on.

When several runs are in flight across worktrees, neither lands you where you meant to go. **`/auto-task-resume`** is the picker that fixes this. It enumerates every run on the clone — scanning each `git worktree list` path for a `STATE.json`, never listing a bare worktree with no state — prints a table, and lets you choose:

```
  auto-task runs — my-app  (4 found)
  ────────────────────────────────────────────────────────────────────────
   #     STATE       TITLE                                  EFFORT  LAST
  ────────────────────────────────────────────────────────────────────────
   1) ● gate-b      Apply & verify external CMS changes    standard 39m ago
   2) ○ done        Sync comments, code & docs             light   3h ago
   3) ● review      Worktree cleanup nudge                 standard 18h ago  · current
   4) ● execute     Add reCAPTCHA to order approval        heavy   2d ago    · orphan
  ────────────────────────────────────────────────────────────────────────
  ● resumable   ○ done   ⚠ unreadable    markers: · current (you're here) · orphan (worktree pruned)
```

Pick a run with an arrow-key prompt — it offers only the resumable ones, while done and current runs stay in the table for context. It then enters that run's worktree and hands off to the standard resume, continuing from the recorded phase.

An **orphaned** run (state survives but its worktree was pruned) is offered a one-step recreate via `git worktree add` first.

It's read-only discovery. Nothing is written or removed without your say-so.

Bare **`/auto-task`** uses this engine too: it consults `--resume-mode` and shows the picker when runs exist beyond your current branch, resumes directly when the only run is your current branch's, or asks for a description when there are none.

## Running multiple runs in parallel

Each run is isolated by **branch** and keeps all state under `.auto-task/<branch>/`. Parallel runs in the same repo are **automatic** — no manual setup.

### Launch from any branch — it just works

For every new-description run, Phase 1 forks a fresh `<type>/<slug>` branch **from the repo's default branch** (`main`/`master`, best-effort fetched first) and gives it its own git worktree:

```sh
git worktree add .claude/worktrees/<type>-<slug> -b <branch> <default-ref>
```

It then relocates the session into it via the `EnterWorktree` tool.

This is unconditional — it does not matter what branch you are on or what the shared checkout is doing. Your original checkout is left untouched and free for other work. A second `/auto-task` started elsewhere gets its own worktree too, and git forbids two worktrees on one branch (names are disambiguated before creation), so they can never collide.

The worktree is kept on disk after the run. Reclaim it with [`/auto-task-gc`](optional-features.md#worktree-space-control-auto-task-gc).

### Based on the default branch, not your current HEAD

Every run starts clean from a current default base, so it never inherits the current checkout's branch or uncommitted WIP. A run started while on a feature branch forks fresh from the default rather than continuing that branch.

To base a run on specific work, prepare a worktree for it by hand:

```sh
git worktree add ../auto-task-feat-x -b feat/x   # one worktree per task
cd ../auto-task-feat-x && claude                  # then run /auto-task here
```

auto-task detects it is already inside a linked worktree and runs in place there, without nesting a second one.

### The in-place fallback is guarded

If `EnterWorktree` / `git worktree add` is unavailable, the run falls back to the shared checkout. The **checkout-drift guard** then catches the case where that checkout is switched off the run's branch from another terminal:

- `warn-checkout-drift.sh` warns on every command.
- `enforce-gates.sh` hard-blocks any commit until you switch back or clear the abandoned run.

This previously failed open, silently.

### Isolation guarantees

Each worktree has its own working tree, branch, and `.auto-task/<branch>/` history. The gate and Stop hooks resolve state per-worktree via `git rev-parse --show-toplevel`, so concurrent runs never interfere — even though they share one clone's object store and common-dir exclude file. Merge or open a PR from each worktree independently.

## Surfacing protocol

The pipeline stops mid-flight only when the Loop rule fires:

1. **No progress** — two consecutive iterations with no measurable improvement.
2. **Out of scope** — remaining issues don't map to the approved AC.
3. **External blocker** — missing credentials, broken infra, an undecided design.
4. **Test flakiness** — a non-deterministic failure.
5. **Returns diminished** — a round's blocker+required count failed to decrease, so the loop has converged.

Clause 5 has two qualifiers worth knowing. It fires **only while findings remain** — a clean round has nothing to park and takes its loop's ordinary clean exit. And at Gate B, the count is of findings that actually **reopened** the loop, not of everything the verifier labelled.

Park-and-advance is your grant to give. The pipeline never self-grants it, and no unfixed blocker or required finding passes a gate on this test alone.

When the rule fires you get a status with **why it stopped** + **current state** + **suggested next move**. Resume with `/auto-task`, or `/auto-task-resume` to pick from all runs.

## Read-before-review contract

When the bundled `auto-task-code-review`, `auto-task-verify`, or `auto-task-fix` skill runs in a repo with an existing `.auto-task/<branch>/` folder, it reads `CONTEXT.md` and `TRACE.md` first — so it doesn't re-litigate settled decisions or miss real issues that earlier reviewers flagged but never followed up on.

**For third-party tools that want to participate**, the contract is:

> If `.auto-task/$(git branch --show-current)/` exists, read `CONTEXT.md` and `TRACE.md` before forming findings; append a new TRACE entry on completion (block format documented in `skills/auto-task/SKILL.md`).

Adopt this in your own tool to interoperate.

## Recommended project memories

Auto-task reads `~/.claude/projects/<slug>/memory/MEMORY.md` during Phase 1 recon. Useful entries to maintain per project:

| Memory | What it should say |
|---|---|
| `feedback_no_unrequested_commits.md` | `"continue"` / `"proceed"` should not authorize commits; only an explicit `"commit"` does |
| `feedback_subagents_dangerous_git.md` | Sub-agents should never run `git reset --hard`, `git push --force`, or similar in dispatch prompts |
| `project_team_review_policy.md` | Who must review PRs touching specific paths |
| `reference_external_systems.md` | Pointers to Linear / Notion / Slack channels where decisions are tracked |

The plugin does **not** ship memory entries. They are per-user, per-project, and opt-in.
