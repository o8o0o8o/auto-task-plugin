---
name: auto-task
description: End-to-end autonomous task workflow — define → execute → verify → review → handover. One human gate in Phase 1 (clarifying Q&A + plan approval); everything after runs unattended until success, a hard blocker, or test flakiness. Use when asked to "auto", "auto-task", "run the whole thing", or when the user wants a task taken from description to PR with no intermediate stops.
license: MIT
metadata:
  author: ai-workflow
  version: "1.8"
---

# Auto-task

Autonomous pipeline that takes a task description from intake to pull request. Composes existing skills (`auto-task-plan`, `auto-task-implement`, `auto-task-verify`, `auto-task-code-review`, `auto-task-commit`) and `task-execution-verifier` agent passes around them.

## NON-YIELDING CONTRACT (read first — the highest-priority rule in this skill)

Phase 1 contains the pipeline's only **unconditional** human gate: in the default `supervised` mode it stops the run without needing a trigger to fire, unlike every later surface. (Under `autonomy: autonomous` even this gate is silenced and the **merge gate** becomes the sole mandatory stop — see "Autonomy modes & the merge gate".) It has two parts that the user sees: (1) clarifying questions, surfaced up-front via a mandatory routing question ("answer here" vs "forward as a comment") followed — only on the answer-here branch — by the questions themselves (the forward branch renders a paste-ready comment and pauses for the owner's answers); and (2) plan approval at the end of Phase 1. Both happen inside Phase 1, and nothing later stops the run *by default*. Three kinds of later surface exist, all documented and none of them a second unconditional gate. **(a)** *Procedural* prompts, none of which gates the work: in Phase 5 the push/PR ask (always) and the docs-update ask (only when `docs_update_mode` is `ask` **and** the docs-update step actually proposes a change — see Phase 5 step 1b); and in Phase 9 the release ask (only when `release_mode` is `ask` **and** there is actually something to release — see Phase 9 step 4). **(b)** Two Phase-5 *conditional* gates that DO stop the run, but only when their trigger fires: the step-7b **merge gate** (`autonomous`+`direct`, or `risk >= risk_gate_threshold`) and a **fix-loop budget ack** (only over budget). **(c)** The post-PR surfaces of Phases 6-9, where work is still owed. So the invariant to rely on is: *after plan approval, no surface stops the run unless its documented trigger fires.*

After the user types `approved` / `looks good` / `proceed` / `yes` / `go ahead` at the Phase 1 plan gate, the pipeline runs to one of two terminal states **without stopping for the user**:

- **Success:** Phase 5 completes (commit landed + PR open OR explicit user choice to hold the push at the final handover prompt) — and the post-PR phases run in order: **Phase 6 (bot-comment review, opt-in)** conservatively applies any actionable Cursor/GitHub-bot PR-comment fixes, then **Phase 7 (preview verification, when enabled/auto-learned)** records a final verdict (PASS/FAIL/INCONCLUSIVE), then **Phase 8 (external change application, when the run declared external actions)** applies + verifies the external change — a task that needs an external change is NOT `done` until Phase 8 applies it — and finally **Phase 9 (release, opt-in via `release_mode`)** cuts the version bump, changelog entry, release commit and annotated tag locally, and only then reaches terminal `done`. A preview `handoff`/timeout (`pending`), a Phase-6 poll/surface, and a Phase-8 apply-prompt / `auto`-run settle-poll / `awaiting-external` handoff are legitimate post-PR surfaces per the yield-point table (work still owed), not mid-pipeline stalls.
- **Hard stop:** a Loop-rule trigger fires (no-progress, out-of-scope, external blocker, test flakiness) per the "Surfacing protocol" below.

There are NO other legitimate stopping points between plan approval and Phase 5 — and within Phase 5 only the two documented *procedural* prompts (the docs-update ask in `ask` mode when a change is proposed, then push/PR), plus the conditional step-7b merge gate and any fix-loop budget ack. Past Phase 5, the post-PR phases add their own documented surfaces, including the Phase-9 release ask. In particular:

- A sub-skill (`auto-task-plan`, `auto-task-implement`, `auto-task-verify`, `auto-task-code-review`, `auto-task-commit`) returning a structured report is **INPUT**, not an end-of-turn. Parse it, act on it, continue.
- A verifier agent (`task-execution-verifier` at Gate A or Gate B) returning findings is **INPUT**. Apply fixes (Blocker/Required) or park (Follow-up), then continue.
- A green check from `/auto-task-verify` advances to Gate A. Continue.
- A clean `auto-task-code-review` pass (no Blockers/Required) advances to Gate B (or Phase 5 for LIGHT tier). Continue.
- A "No adversarial findings." from Gate B advances to Phase 5. Continue.
- Phase 5's gate-precheck passing advances to commit. Continue.
- A successful commit advances to push. Continue.
- Output-formatting cues that LOOK like end-of-turn — "Verdict:", "Summary:", a Markdown horizontal rule, a heading-shaped final line, a turn-final blank line, a checklist that has all items ticked — are **paragraph formatting**. They are not interaction points. Do not stop.

**The only sub-skill/sub-agent return that's allowed to end your turn is `auto-task-commit` after a successful push and `gh pr create` (Phase 5 final).** There are two further exceptions, and only these two, each a `report-only` return that IS the content of a conditional ask: the `auto-task-docs` staleness report in `ask` mode, when non-empty, which the Phase-5 docs prompt shows the user (Phase 5 step 1b); and the `auto-task-release` release plan in `ask` mode, when there is something to release, which the Phase-9 release prompt shows the user (Phase 9 step 4). Everything else feeds the next step.

If you find yourself about to write a recap, a "next steps" summary, a "ready for your review" line, or any sentence that addresses the user in the second person mid-pipeline — STOP TYPING and instead make the next tool call. Recaps are for the post-Phase-5 message, not for mid-pipeline.

Phase 5 has exactly two permitted **procedural** prompts, in this order (in addition to two *conditional* gates that are documented surfaces in their own right: the **step-7b merge gate**, which is mandatory when `autonomous`+`direct` or `risk >= risk_gate_threshold`, and a **fix-loop budget ack** when the commit is blocked over budget). **(1) The docs-update ask** — only when `docs_update_mode` is `ask` AND the docs-update step returned a non-empty staleness report; it is skipped entirely on `skip`/`always`/an empty report, and degrades to applying without yielding under `autonomous`/headless (Phase 5 step 1b). **(2) The push prompt** — pushing to remote and opening a PR are externally-visible actions per the "Executing actions with care" guideline in `~/.claude/CLAUDE.md`, so you MAY ask once whether to push / push-and-PR / hold before the network call. Those two procedural prompts, plus the conditional merge gate and budget ack named above — and no others. Everything else in Phase 5 still runs without asking.

**Mechanical backstop.** The textual contract above is paired with a `Stop` hook (registered via the plugin's `hooks/hooks.json` on the recommended marketplace install; the `settings-fragment.json` fallback wires it for `install.sh`/manual installs) that reads `expected_next_action` from STATE.json and **blocks the model's turn from ending** when the field says `"auto-continue"`. The hook is the antidote to completion-shaped sub-skill output fooling the model into stopping. The contract is: at every state write, set `expected_next_action` to one of `auto-continue` / `user-approval` / `user-push-prompt` / `null` per the "Yield-point contract" section below. The default is `"auto-continue"` — if you write state without an explicit choice, the hook will keep the turn alive, which is the correct failure mode.

## Operating principles

- **Human gates depend on the autonomy mode (see "Autonomy modes & the merge gate").** In the default `supervised` mode the model below is exactly as written: the Phase-1 plan is the one gate, plus the Phase-5 push prompt (and, when `docs_update_mode` is `ask` and the docs step proposes a change, the Phase-5 docs-update ask). In `autonomous` mode those procedural gates go silent and the **merge gate** is the sole mandatory stop, with the interrupt-now gates (ambiguity / destructive-op / test-integrity / cost budget) as the safety net. The rest of this bullet describes `supervised` mode. **One human gate (supervised).** The plan produced in Phase 1 is the contract. After the user approves it, do not stop for confirmation — proceed through Execute → Verify → Review → Handover (→ bot-comment review, when opted in → Preview verification, when enabled/auto-learned → External change application, when external actions were declared) automatically. The mid-run exceptions remain the Phase 5 push/PR prompt, the Phase-5 docs-update ask (only when `docs_update_mode` is `ask` and the docs step proposes a change), the single Phase-8 apply prompt for external changes, and the Phase-9 release ask (only when `release_mode` is `ask` and there is something to release); a post-PR surface (a Phase-6 bot-review poll/surface, a Phase-7 preview handoff/timeout, a Phase-8 `awaiting-external`/failure surface, or a Phase-9 `partial-failure`/`failed` surface, where work is still owed) is a documented yield, not a new gate.
- **Surface only when the loop rule says to.** See "Loop rule" below. Never invent new stops outside that rule.
- **Run label (cosmetic — never changes control flow).** Every run carries a concise human-readable `state.title` (derived at branch setup, see Phase 1). Surface it two ways so a session is identifiable at a glance: **(a)** prefix EVERY spawned Agent's `label`/`description` with the title, so the running-agent status line reads `<title> · <activity>` (e.g. `Ticket-comment forwarding · Gate B adversarial verify`) — this applies uniformly to the Phase-1 critique agent, the approach-selection `general-purpose` agents, and the Gate A / Gate B `task-execution-verifier` agents, with NO spawn site exempt; **(b)** whenever a phase *already legitimately* emits a user-facing message AND `state.title` already exists (it is derived in branch-setup step 4, so the banner is available from that point on), PREFIX that message with a one-line banner `▶ auto-task: <title> — Phase N (<phase-name>)`. The qualifying surfaces are: the Phase-1 telemetry-consent / clarifying-questions / plan-approval prompts (clarifying-questions here covers the Phase-1 clarify routing question and the forwarded-comment pause), the Phase-5 docs-update ask (`ask` mode, non-empty staleness report), the Phase-5 push/PR prompt, a Phase-6 bot-review surface, a Phase-7 preview surface, the Phase-9 release ask (`ask` mode, something to release) or a Phase-9 `partial-failure`/`failed` surface, a Loop-rule surface, or a destructive-action confirmation. **Carve-out:** the one sanctioned user surface that fires *before* branch setup — the pre-preflight version-check ask (new runs only) — runs before any title, branch, or slug exists, so it carries NO banner. (These qualifying surfaces are the post-title `user-approval`/`user-push-prompt` rows of the yield-point table, plus the pre-approval telemetry-consent ask, minus that pre-title version-check row.) This adds NO new message: it only labels the messages that already occur. It does **not** license a per-phase "message to the user" — the unattended phases (2, 3, 4, Gate A/B) stay silent and make tool calls per the NON-YIELDING CONTRACT above, so they emit no banner. This is presentation only: it introduces no gate, no yield, and no new `AskUserQuestion`, and it never alters `expected_next_action`.
- **Single commit at handover.** Phases 2 through Gate B make NO commits — all changes accumulate as one growing uncommitted diff against the branch base, and only Phase 5 commits, after every required gate has passed (see the "Single-commit rule" below, mechanically enforced by the pre-commit hook). The only additional commits permitted are the Phase-5 main-sync merge (integration, not authored) and two opt-in authored commits — Phase-6 bot-fix commits (when `bot_review_autofix` is on) and the Phase-9 release commit (when `release_mode` is on) — each of which re-passes the full gate loop before it can land. Durability and resumability come from `.auto-task/<branch>/STATE.json` on disk, not from intermediate commits.
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
- **No scope creep.** Every change must trace to the approved plan's Acceptance Criteria. Out-of-scope findings get parked as follow-ups, not implemented. **But a follow-up may not carve away the user-visible portion of a *primary* requirement.** If a requirement is part of what the task headline promises the user will see or be able to do, the slice that delivers that visible behavior stays in-loop — it cannot be renamed a "follow-up" and deferred (the DTG-run mistake: "the three styles are selectable/visible" was the headline, parked as a CMS-thumbnail follow-up). Leaving such a slice out of this run requires an *explicit user descope* (recorded in CONTEXT.md Human choices; the requirement is marked `dropped`) — never a silent park.
- **Evidence at every transition.** The plan gets critiqued before approval; the execution diff is checked against blast radius at every commit; the PR carries an audit trail of judgment calls so the run is reviewable without replaying it.

## Loop rule (the only exit conditions)

Continue iterating while ALL of these hold:

1. **Progress** — each iteration makes measurable progress versus the previous one (fewer failing checks, fewer review findings, or net-new code that addresses a finding). Two consecutive iterations with no measurable progress → STOP and surface.
2. **In-scope** — remaining issues map to the approved Acceptance Criteria. Out-of-scope finding → STOP and surface.
3. **Unblocked** — no external blocker (missing credentials, broken infra, design decision the plan didn't cover, third-party outage). Blocker → STOP and surface.
4. **No test flakiness** — every test failure is reproducible. Any flake (test fails then passes on retry without code change, or fails non-deterministically) → STOP and surface.
5. **Returns have not diminished** — **two consecutive review rounds producing zero blockers and zero required findings means the loop has CONVERGED: park the remaining findings and advance.** Do not take a follow-up "while we're here". Clause 1 measures whether progress *happened*, and it structurally cannot catch a loop that keeps finding **genuine but trivial** defects, because such a loop always shows progress. A real run demonstrated the gap: 28 review rounds, every one finding something real, clause 1 never able to fire, and by the tail a "required" finding meant a hostile artifact deliberately planted inside a plugin install directory. Once a round comes back clean, the bar for another fix is the **Acceptance Criteria** — not the mere existence of a finding. Every fix costs a full re-review cycle, so an optional one is never free.

Exit the loop successfully when:
- All `/auto-task-verify` checks pass.
- The most recent `task-execution-verifier` agent says DoD satisfied.
- The most recent `auto-task-code-review` produces only follow-ups (no blockers, no required fixes).

Caps are set by the current effort tier (see below), can rise when the tier escalates, and — as of the loop-budget gate — are **mechanically enforced** rather than advisory: `enforce-gates.sh` refuses a commit once the loop count `max(iteration.fix, iteration.review)` exceeds the tier's budget until the user has acknowledged it, and `prevent-mid-protocol-stall.sh` warns and releases one turn-end per over-budget loop count as a backstop for a run that never set `expected_next_action` to a yielding value. See "Fix-loop budget" under Effort tiers.

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

### Fix-loop budget (mechanically enforced)

The "Fix-loop cap" column is a **budget**, not a suggestion. Two hooks enforce it, and both read the cap from the single executable definition in `hooks/lib/loop-budget.sh` — the prose table above documents that file rather than duplicating it.

- **`enforce-gates.sh`** refuses a commit once the **loop count** exceeds the effective budget. Placed after the code-review / Gate-B checks, so a run that is still legitimately working hears about its real gate first.
- **`prevent-mid-protocol-stall.sh`** emits a warning and releases **one** turn-end per over-budget loop count. Note precisely what this does and does not buy, because it is easy to overstate: a model that follows the ack ritual below sets `expected_next_action: "user-approval"` first, and the Stop hook already allows that yield — so the release is **not** a precondition for surfacing. It is a **backstop plus a best-effort notice** for the case that actually goes wrong: a run that keeps churning without updating the field, where the anti-stall contract would otherwise force it onward with nothing telling it the budget is blown. A second turn-end at the same loop count blocks normally. Be precise about the notice's reach: on an ALLOW the hook has no guaranteed model-facing channel (only a *block* is fed back), so it emits the warning as a `systemMessage` **and** on stderr — surfaced best-effort. The guaranteed half of the pair is the commit block, which is model-facing by construction.

**Loop count** = `max(iteration.fix, iteration.review)` — and it must be both counters, because the two track different halves of the same churn. `iteration.fix` is bumped only on the Phase-3 self-verify failure path; every Phase-4 review round and every Gate-B feedback round bumps `iteration.review` instead. A budget keyed on `fix` alone would wave through a run at `fix: 0, review: 28` — 28 rounds of iteration, the exact volume this budget exists to bound. Both hooks measure the identical `max`, so on any well-formed state the commit block and the turn-end release agree. On a state neither can verify — a counter that is non-numeric, negative, fractional, or too wide for a 64-bit compare — they diverge *by design*, because their fail policies are opposite: the gate blocks the commit (fail-closed) while the release stays silent (fail-open) and the run surfaces the ordinary way, by setting `expected_next_action: "user-approval"`. It is a `max`, not a sum: a run is bounded by how far its longest loop has run, and one ack still clears it.

**Effective budget** = `max(cap, gates.loop_budget.acked_through)`. The `max` matters because effort can only escalate: an ack recorded at a lower tier must never leave the run under-budgeted after an escalation.

**The ack ritual — this is a user gate, not a self-serve flag.** When the budget block fires:

1. Set `expected_next_action: "user-approval"` and **surface**, showing the **per-round finding severities** so the user can see for themselves whether returns have diminished. That evidence is the whole point — "we have done N rounds" alone does not tell them whether to continue.
2. On their explicit go-ahead, record `gates.loop_budget = { acked_through: <the next cap rung above the budget that clears the current loop count>, acked_at: <ISO-8601>, reason: "<why continuing is right>" }`. **Do not compute this by hand — the block message prints the exact value, and `lb_next_budget <cap> <acked> <loop count>` in `hooks/lib/loop-budget.sh` is its definition.** The budget levels stay on cap multiples so the check-in returns rather than being permanently dismissed — on HEAVY the budget steps 6 → 12 → 18 → 24 and the check-ins land at loop count 7, 13, 19, 25. It is *not* a flat `budget + cap`: because this gate runs at commit time while the counters accumulate through the loop, a run can arrive far past its budget (the motivating run hit 33 against a HEAVY cap of 6), and a fixed one-cap step would then demand one ack per cap of overshoot — each asking the user to approve budget already spent. Stepping to the first rung that clears the count means **one ack is always sufficient**.
3. Set `expected_next_action: "auto-continue"` and continue.

`gates.loop_budget.acked_through` carries the identical trust model as every other gate flag: **a checkable artifact, never set speculatively.** Writing it without asking is the same contract violation as flipping `gates.code_review.passed` without running the review — and it defeats the only mechanism that makes the cap real.

## Inputs

- `/auto-task <description>` — start a new run. `<description>` is the task to solve.
- `/auto-task` (no args) — resume an existing run. Because a run lives in its own worktree keyed to a branch, and this session may not be on that branch, the resume path is **worktree-aware** (see "Resume (no-args) dispatch" below) — it does not blindly assume the current branch's `.auto-task/<branch>/STATE.json` is the one you meant.

### Resume (no-args) dispatch

On `/auto-task` with no arguments, decide which run to continue by consulting the bundled enumeration engine `hooks/auto-task-resume-list.sh` (locate it with the standard three-probe pattern; `CLAUDE_PLUGIN_ROOT` is empty in the Bash-tool env). Run `bash "$engine" --resume-mode`, which prints one of three words computed from the full set of runs across every worktree + the current toplevel. The current worktree's own run takes precedence — if you are sitting in a resumable run, `/auto-task` continues *that*, never a picker:

- **`direct`** — the current worktree's own run is resumable. Resume the **single current-branch run** exactly as before: read `.auto-task/<branch>/STATE.json` for the current branch and continue from its `phase`. This preserves the original, zero-friction behavior (no picker, no extra prompt) and holds even when other resumable runs exist elsewhere — which is also what makes the picker hand-off terminate rather than loop.
- **`picker`** — the current worktree has **no** resumable run of its own, but resumable runs exist in other worktrees. Do NOT guess. Invoke the **`auto-task-resume`** skill (the run picker), which lists every run, lets the user choose, positions the session into the chosen worktree, and hands back here — where `--resume-mode` now returns `direct` and resumes it. (Invoke whichever name is registered this session — `auto-task:auto-task-resume` under a marketplace install, or `auto-task-resume` under the symlink fallback.)
- **`none`** — no resumable run anywhere. Keep the original message: tell the user to provide a description (`/auto-task <description>`).

Fail-open: if the engine cannot be located or errors, fall back to the original current-branch behavior (resume `.auto-task/<branch>/STATE.json` if present, else ask for a description) — the picker is a convenience, never a hard dependency.

## State file

`.auto-task/<branch>/STATE.json`:

```json
{
  "phase": "define|execute|self-verify|gate-a|review|gate-b|handover|bot-review|preview|external|release|done",
  "expected_next_action": "auto-continue|user-approval|user-push-prompt|null",
  "approved": true,
  "title": "<concise human-readable run title derived from the task at Phase 1 — surfaced in agent labels + phase banners>",
  "description": "<verbatim task input from /auto-task argument>",
  "branch": "<branch name where the run lives>",
  "base": "<base-commit SHA captured at branch setup — the point the branch forked from>",
  "autonomy": "supervised|autonomous",
  "landing": "pr|direct",
  "effort": {
    "tier": "light|standard|heavy",
    "difficulty": 0,
    "risk": 0,
    "history": [
      { "from": "standard", "to": "heavy", "reason": "schema migration not in initial blast radius", "at": "ISO-8601" }
    ]
  },
  "estimate": {
    "duration_min": 0, "tokens_total": 0,
    "tokens_breakdown": { "input": 0, "output": 0, "cache": 0 },
    "basis": "<from estimate.sh; fields are null when unestimable>", "at": "ISO-8601"
  },
  "actuals": {
    "duration_min": 0, "tokens_total": 0,
    "tokens_breakdown": { "input": 0, "output": 0, "cache_read": 0, "cache_creation": 0 },
    "tokens_by_skill": {}, "model": null, "claude_code_version": null,
    "at": "ISO-8601"
  },
  "quality": {
    "defects": { "early": 0, "late": 0, "by_severity": {} },
    "tests_added": false, "flaky": false,
    "diff": { "files": 0, "loc_added": 0, "loc_removed": 0 },
    "planning": { "est_time_ratio": null, "est_token_ratio": null, "drift": 0, "escalations": 0, "first_pass_ac": null },
    "maintainability_note": "<reused verbatim from the code-review verdict — NOT a bespoke score>",
    "not_measured": ["business impact", "collaboration", "long-term maintainability"],
    "satisfaction": null,
    "correctness": null,
    "comment": null
  },
  "checks": [
    { "name": "typecheck", "category": "build", "command": "tsc --noEmit", "gate": "self-verify", "result": "pass", "evidence": "exit 0", "at": "ISO-8601" }
  ],
  "requirements": [
    { "id": "R1", "text": "<atomic, unambiguous requirement dissected from the task>", "covered_by_acs": [1, 3], "status": "pending|done|dropped" }
  ],
  "iteration": { "review": 0, "fix": 0 },
  "clarify_forward_pending": { "pending": false, "kind": null, "questions": [], "at": null },
  "history": [
    { "phase": "self-verify", "result": "fail", "summary": "2 tests failing", "at": "ISO-8601" }
  ],
  "gates": {
    "self_verify": { "passed": false, "at": null, "evidence": null },
    "gate_a":      { "passed": false, "at": null, "evidence": null },
    "code_review": { "passed": false, "tool": null, "clean_pass_after_last_fix": false, "reviewed_diff_sha": null, "at": null, "evidence": null },
    "gate_b":      { "passed": false, "at": null, "evidence": null, "skipped_reason": null },
    "merge":       { "required": false, "acked": false, "acked_at": null, "reason": null, "disclaimer": null },
    "loop_budget": { "acked_through": 0, "acked_at": null, "reason": null }
  },
  "assumptions": [
    { "kind": "auto-approved-ambiguity|thin-cite-decision|drift-auto-continue|risk-accepted", "note": "<what was assumed to stay unattended>", "at": "ISO-8601" }
  ],
  "followups": [
    { "source": "code-review", "note": "Consider extracting X helper", "at": "ISO-8601" }
  ],
  "pr_url": null,
  "settings": {
    "source": "<resolved settings-file path from settings.sh, or null when none exists>",
    "resolved": { "has_preview_deployment": false, "preview_wait_mode": "poll", "preview_timeout_min": 30 },
    "at": "ISO-8601"
  },
  "bot_review": {
    "status": "skipped-disabled|skipped-no-push|skipped-no-comments|applied|no-action|surfaced",
    "polls": 0,
    "comments_found": 0,
    "applied": [ { "url": "<comment url>", "path": "<file or null>", "line": 0, "summary": "<what was fixed>", "at": "ISO-8601" } ],
    "parked": [ { "url": "<comment url>", "author": "<bot login>", "note": "<why parked>", "at": "ISO-8601" } ],
    "at": "ISO-8601"
  },
  "preview": {
    "status": "skipped-disabled|skipped-no-push|skipped-no-url|skipped-learned-none|awaiting|pending|verified|failed|inconclusive",
    "wait_mode": "poll|handoff",
    "url": "<resolved preview URL, or null>",
    "deployment_sha": "<the pushed HEAD SHA the preview was bound to, or null>",
    "polls": 0,
    "learned": "<{ value: true, at } when auto-learn persisted has_preview_deployment=true this run; null otherwise — a non-detection is never persisted>",
    "verdict": "PASS|FAIL|INCONCLUSIVE|null",
    "checks": [ { "ac": 3, "result": "pass|fail", "evidence": "<url check + result>", "at": "ISO-8601" } ],
    "at": "ISO-8601"
  },
  "external": {
    "status": "skipped-disabled|none|declared|awaiting-external|applying|verifying|applied-verified|applied-unverified|failed",
    "mode": "ask|runbook|auto",
    "actions": [ { "id": "E1", "system": "<CMS/flag-service/API/migration target>", "description": "<what the change does>", "script": "<command or file to run, or manual steps>", "verify": "<how to confirm it took>", "reversible": true, "rollback": "<undo/recovery steps, or 'IRREVERSIBLE — cannot be undone' when reversible=false>" } ],
    "applied": [ { "id": "E1", "at": "ISO-8601", "evidence": "<command + result / confirmation>" } ],
    "verify": [ { "ac": 5, "result": "pass|fail", "evidence": "<post-apply check + result>", "at": "ISO-8601" } ],
    "polls": 0,
    "at": "ISO-8601"
  },
  "release": {
    "status": "skipped-disabled|skipped-invalid-value|skipped-skill-absent|deferred-pr|nothing-to-release|runbook|in-progress|resolved-re-derive|applied|partial-failure|failed|declined",
    "mode": "skip|ask|always",
    "command": "<the resolved release_command, or null when unset>",
    "command_effects": "<what the report-only pass determined the command does — notably whether it commits/tags, pushes, publishes or deploys; recorded on EVERY path, since the ask-mode prompt is the only place it is displayed>",
    "from_version": "<version before the bump, or null>",
    "version": "<the released version, e.g. 1.4.0, or null>",
    "bump": "major|minor|patch|null",
    "bump_signal": "<the evidence that decided the bump — a PLAN.md breaking-change note, a feat! marker, the branch type>",
    "commit": "<release-commit SHA, or null>",
    "tag": "<annotated tag name, or null>",
    "files": [ "<files the release touched>" ],
    "unwind": "<the exact undo commands handed to the user, with the reset precondition>",
    "at": "ISO-8601"
  }
}
```

Update this file at every phase transition and at the end of every loop iteration. **Write the `phase` field EXPLICITLY on entry to each phase** — it is the resume anchor and part of the anti-stall signature, so leaving it stale (e.g. at `"define"` through the core pipeline) breaks `/auto-task` resume and can trip the stall backstop on a non-frozen run. The per-phase values are: Phase 1 setup → `"define"`; Phase 2 → `"execute"`; Phase 3 → `"self-verify"`; Gate A → `"gate-a"`; Phase 4 → `"review"`; Gate B → `"gate-b"`; Phase 5 → `"handover"`; then the post-PR states `"bot-review"` / `"preview"` / `"external"` / `"release"`; and finally `"done"`. Pair every `phase` write with the matching `expected_next_action` (see the yield-point contract).

**Per-object notes.** `clarify_forward_pending`, the run-metrics objects (`estimate`/`actuals`/`quality`/`checks`), the phase objects (`settings`/`preview`/`bot_review`/`external`/`release`), the terminal-vs-in-flight rules, and the autonomy+merge-gate objects each carry additive semantics, null-vs-zero rules, and the honesty rule deciding whether a run may write `phase: "done"`.

**MANDATORY READ:** read `references/state-schema.md` before acting here. This summary is an index, NOT the contract.

Two invariants restated inline, because getting either wrong silently corrupts telemetry or strands a run:
- **`estimate`/`actuals` token+time fields are `null`, never `0`** when unmeasured — `auto-task-stats` excludes nulls instead of dividing by zero.
- **A task needing an external change is NOT `done` until Phase 8 applies AND verifies it.** `declared`/`awaiting-external` stay `phase: "external"`; only `applied-verified`, an accepted `applied-unverified`, `none`, or an explicit descope reach `done`.


### Yield-point contract (mechanical anti-stall enforcement)

The NON-YIELDING CONTRACT at the top of this skill is text. Models reliably violate it when sub-skill output looks completion-shaped ("Verdict:", horizontal rules, headed sections). The `expected_next_action` field is the mechanical backstop — paired with a `Stop` hook that **blocks** the model's turn from ending when the field says auto-continue.

`expected_next_action` MUST be one of these four values at all times after `approved: true`:

| Value | Semantics | When set |
|---|---|---|
| `"auto-continue"` | Pipeline is mid-flight; the model MUST make the next tool call. Stop hook blocks any attempt to end the turn. | The default for every non-terminal transition. Set this whenever you advance a phase, complete a sub-skill, finish a verifier agent, apply a fix, or set a gate. |
| `"user-approval"` | A legitimate human gate. Stop hook allows. | Phase 1 plan-presentation point (before user types `approved` / `proceed`). Loop-rule surface (when the Surfacing protocol fires). The Phase-5 docs-update ask, when `docs_update_mode` is `ask` AND the step actually proposes a change (see Phase 5 step 1b). The Phase-9 release ask, when `release_mode` is `ask` AND there is actually something to release (see Phase 9 step 4). |
| `"user-push-prompt"` | The single allowed Phase 5 push/PR/hold prompt. Stop hook allows. | Just before the `git push` / `gh pr create` permission ask in Phase 5. |
| `null` | Pre-approval or terminal state. Stop hook allows. | While `approved: false` (Phase 1 setup, before user approves) OR after `phase: "done"`. |

Set the field as part of EVERY state write — no exceptions. The discipline is: when you write `phase`, `gates.*`, `iteration.*`, or any history entry, also write `expected_next_action`. Default to `"auto-continue"` and only set the user-* values at the three legitimate yield points.

The Stop hook reads `STATE.json` on every Stop event:

- `phase === "done"` → allow stop.
- `approved !== true` → allow stop.
- Otherwise (run is mid-pipeline) → allow only when `expected_next_action ∈ {"user-approval", "user-push-prompt"}`. **Every other value — `"auto-continue"`, an unknown string, or an unset/null field — blocks.** A missing field is treated as auto-continue (fail closed): per the default rule above, writing post-approval state without an explicit choice keeps the turn alive, which is the correct failure mode. `null` is only legitimate while `approved: false` or after `phase: "done"`, both of which are already handled by the two guards above — so a null encountered mid-pipeline means the field was not set and the hook blocks.

The hook is registered via the plugin's `hooks/hooks.json` (marketplace install) or the `settings-fragment.json` fallback (`install.sh`/manual). Without it, the field is informational; with it, the field is enforced. Both must be aligned — never set `"user-approval"` speculatively to "escape" the hook, because that defeats the entire mechanism. The pre-commit hook for gates is the analogous precedent: don't flip flags speculatively.

**Setting the value at each phase / transition:**

| Transition / phase point | Set `expected_next_action` to |
|---|---|
| Phase 1 version-check ask (new runs only, pre-preflight) | `"user-approval"` (a Phase-1 user gate; `approved` is still `false`, so the Stop hook allows regardless) |
| Phase 1 setup (branch created, before plan) | `null` (still `approved: false`) |
| Phase 1 clarify routing question presented | `"user-approval"` (Step 4a router — the AskUserQuestion is itself a user gate) |
| Phase 1 clarify questions presented (answer-here branch) | `"user-approval"` (Step 4b-answer — the AskUserQuestion is itself a user gate) |
| Phase 1 clarify — comment forwarded, awaiting owner's answers | `"user-approval"` (Step 4b-forward pause; `approved:false`, so the Stop hook allows regardless) |
| Phase 1 clarify resume — pending questions re-surfaced | `"user-approval"` (resume without answers; `approved:false`) |
| Phase 1 plan presented for approval | `"user-approval"` |
| User types approval keyword | `"auto-continue"` (and `approved: true`) |
| Phase 2 → 3 advance | `"auto-continue"` |
| Phase 3 self-verify pass | `"auto-continue"` |
| Phase 3 fix-loop iteration | `"auto-continue"` |
| Gate A pass | `"auto-continue"` |
| Phase 4 code-review skill returns | `"auto-continue"` (the report is INPUT) |
| Phase 4 fix applied | `"auto-continue"` |
| Gate B pass | `"auto-continue"` |
| Phase 5 steps 1, 1b, 2–4 (gates verify, docs update, diagram, artifacts, CONTEXT.md) — except the step-1b `ask` prompt below | `"auto-continue"` |
| Phase 5 step 5–7 (stage, commit, verify, push prep) | `"auto-continue"` |
| Phase 5 docs-update ask (step 1b — `docs_update_mode == "ask"` AND a staleness report is non-empty; skipped entirely on `skip`/`always`/empty-report, and degraded without yielding under `autonomous`/headless) | `"user-approval"` |
| Phase 5 just-before `git push` / `gh pr create` | `"user-push-prompt"` |
| Phase 5 push/PR done, no post-PR phase applicable (`bot_review_autofix` false AND preview not applicable AND no external actions declared; or push held with no external actions declared) | `null` (and `phase: "done"`) |
| Phase 5 push/PR done, bot-review applicable → entering Phase 6 | `"auto-continue"` (and `phase: "bot-review"`) |
| Phase 5 push/PR done, bot-review not applicable, preview applicable → entering Phase 7 | `"auto-continue"` (and `phase: "preview"`) |
| Phase 6 polling for bot comments (`poll`) — bump `bot_review.polls`, wait, re-poll | `"auto-continue"` (the `bot_review.polls` bump advances the anti-stall signature) |
| Phase 6 applying a bot-fix / re-review / commit / push | `"auto-continue"` |
| Phase 6 completes → hands off to Phase 7 (preview applicable) | `"auto-continue"` (and `phase: "preview"`) |
| Phase 6 completes → no preview, but external actions declared → entering Phase 8 | `"auto-continue"` (and `phase: "external"`) |
| Phase 6 completes → no preview applicable AND no external actions declared | `null` (and `phase: "done"`) |
| Phase 6 surfaces an ambiguous bot-flagged blocker for user judgment | `"user-approval"` (and `phase: "bot-review"`) |
| Phase 7 polling for the preview deployment (`poll` mode) | `"auto-continue"` |
| Phase 7 handoff mode (wait deferred to a later resume) | `"user-approval"` (and `phase: "preview"`) |
| Phase 7 timeout — deploy not ready within `preview_timeout_min` | `"user-approval"` (and `phase: "preview"`, `preview.status: "pending"`) |
| Phase 7 poll cycle (not yet ready) — bump `preview.polls`, wait, re-poll | `"auto-continue"` (the `preview.polls` bump advances the anti-stall signature) |
| Phase 7 verdict written, external actions applicable → entering Phase 8 | `"auto-continue"` (and `phase: "external"`) |
| Phase 7 verdict PASS / FAIL / INCONCLUSIVE, no external actions | `null` (and `phase: "done"`) — a completed verification is terminal; FAIL is reported prominently but the run is done (fix = new run) |
| Phase 5/6/7 done, external actions declared but push HELD → entering Phase 8 | `"auto-continue"` (and `phase: "external"`, `external.status: "declared"`) |
| Phase 8 per-run apply prompt (`ask` mode, or any `reversible:false` action) — permission + credentials | `"user-push-prompt"` (the externally-consequential apply is a single allowed prompt, like the Phase-5 push) |
| Phase 8 applying / verifying (running the script, post-apply checks) | `"auto-continue"` |
| Phase 8 `auto`-run in-session settle-poll (waiting for an async external apply to propagate before verifying) — bump `external.polls`, wait, re-poll | `"auto-continue"` (the `external.polls` bump advances the anti-stall signature) |
| Phase 8 `awaiting-external` (runbook handed to a human) / `declared` (push held) — yields and waits for `/auto-task` resume; auto-task does NOT poll a human | `"user-approval"` (and `phase: "external"`) |
| Phase 8 settle-poll timeout — an `auto`-run async external apply did not settle within `external_actions_timeout_min` | `"user-approval"` (and `phase: "external"`, `external.status: "applied-unverified"`) — surfaced; resume re-verifies (does not re-apply) |
| Phase 8 completes, release applicable → entering Phase 9 | `"auto-continue"` (and `phase: "release"`) |
| Phase 8 `applied-verified` / accepted `applied-unverified` / descope / `none`, **no release applicable** | `null` (and `phase: "done"`) — a completed application is terminal |
| Phase 8 `failed` (apply or post-apply verify failed, or partial-failure) | `"user-approval"` (and `phase: "external"`, `external.status: "failed"`) — surfaced, not auto-looped |
| Phase 9 steps 1-3 (resolve mode, `report-only` release plan) and steps 5-8 (authorize, re-gate, commit, tag, record) | `"auto-continue"` |
| Phase 9 release ask (step 4 — `release_mode == "ask"` AND the `report-only` pass found something to release; skipped entirely on `skip`/`always`/nothing-to-release, and degraded without yielding under `autonomous`/headless) | `"user-approval"` |
| Phase 9 `applied` / `nothing-to-release` / `declined` / `runbook` / `deferred-pr` / any `skipped-*` | `null` (and `phase: "done"`) — a completed release step is terminal |
| Phase 9 `partial-failure` (release commit landed, tag missing) / `failed` (a blocker, or a non-clean re-gate) / `in-progress` (a mutating action was interrupted) | `"user-approval"` (and `phase: "release"`) — **surfaced for the user to resolve by hand; Phase 9 never auto-resumes, auto-retries or auto-reverts** (see Phase 9 step 1) |
| Loop-rule surface (anywhere) | `"user-approval"` |
| Destructive action confirmation prompt | `"user-approval"` |

If you cannot map the current transition to one of these, the default is `"auto-continue"` — strict case, never lenient.

`gates` carries most of the mechanical contract enforced by the global pre-commit hook (`enforce-gates.sh`) — but not all of it: the hook additionally enforces review staleness and the fix-loop budget, and the budget's trigger fields (`effort.tier`, `iteration.fix`, `iteration.review`) live outside `gates.*`. **No commit is permitted during an auto-task run until `gates.code_review.passed === true`, `gates.code_review.clean_pass_after_last_fix === true`, and (for STANDARD/HEAVY tier) `gates.gate_b.passed === true` or `gates.gate_b.skipped_reason` is set.** The hook reads this file at every `git commit`/`git commit --amend` invocation. Setting these flags is a checkable artifact — only set them after the agent actually ran and returned a clean result; never set them speculatively. If a gate fails, leave `passed: false` and surface.

Beyond the booleans, the hook enforces two further things. The first is **review staleness**: when `state.base` and `gates.code_review.reviewed_diff_sha` are both present, it recomputes `git diff <pinned-flags> <base> | git hash-object --stdin` (the pinned flags are listed under Phase 4 `reviewed_diff_sha`) and blocks the commit if the result differs from `reviewed_diff_sha`. This catches the most common real failure mode — review passes clean, then more code is edited (a "quick" Gate B fix, a stray tweak) and committed without re-review. The flags are self-attested; this binds them to the actual bytes of the diff. The only way past it is to re-review the current diff and refresh the sha, which is exactly the intended behavior.

The second is the **fix-loop budget**: the hook blocks the commit while the loop count `max(iteration.fix, iteration.review)` exceeds `max(tier cap, gates.loop_budget.acked_through)`. Unlike the two above it is not about review quality at all — it bounds review *volume*, which is why it counts review rounds as well as fix rounds. Note that neither this gate nor the staleness check is keyed purely on `gates.*`: the budget reads `effort.tier`, `iteration.fix` and `iteration.review`, and staleness reads `state.base`. See "Fix-loop budget" under Effort tiers for the cap table and the ack ritual, and the gate table in ARCHITECTURE.md for the authoritative list of every field the hook reads.

## User settings

Per-project, per-user configuration. **Optional and fully defaulted** — a project with no settings file behaves exactly as before. Read (never written) by the orchestrator via `hooks/settings.sh`.

**Where they live:** `${AUTO_TASK_HOME:-$HOME/.claude}/auto-task/<project-key>/settings.json`, keyed by the git **common dir** so every linked worktree of a clone resolves to the same file. Nothing is written inside the working tree, so a setting never shows in `git status`.

**Locate** `hooks/settings.sh` with the three-probe pattern (`CLAUDE_PLUGIN_ROOT` is empty in the Bash-tool env), then: `get <key>` · `all` (merged JSON) · `present <key>` (explicitly decided?) · `set <key> <value>` · `path` · `init` · `schema-status` · `reset --backup`.

**MANDATORY READ:** read `references/settings.md` before acting here. This summary is an index, NOT the contract. It carries the full recognized-key table, the two-scope merge rule, the remote-telemetry payload contract, settings reset — **and the autonomy sub-contracts** (First-run setup, merge gate, interrupt-now gates, assumptions ledger), since those are all policy resolution.

**Fail-open, always:** a missing file, malformed JSON, or an absent key resolve to built-in defaults; `settings.sh` never errors a run. Resolution is `defaults ⊔ global ⊔ project` — the project file wins.

## Autonomy modes & the merge gate

This section defines the run's interaction model. The guiding principle: the model is trusted with the *work* (competence is already gated by self-verify, Gate A/B, and code-review); a human is needed only for **irreversibility** (a follow-up commit can't undo it) and **wrong-intent** (the run confidently built the wrong thing). So autonomy is opt-in, and the only always-on human stop is the merge.

The gate that fires is a function of `autonomy` × `landing_model`:

| `autonomy` | `landing_model` | Phase-1 plan gate | Handover / land |
|---|---|---|---|
| supervised | pr | STOP for approval | push/PR prompt |
| supervised | direct | STOP for approval | prompt before the land onto the default branch |
| autonomous | pr | auto-approve | push + open PR unattended; disclaimer in the PR body. **Exception:** `risk >= risk_gate_threshold` forces one pre-push ack. |
| autonomous | direct | auto-approve | **merge gate**: stop once, show disclaimer + assumptions ledger, land on ack |

`supervised` (default) is the behavior described throughout this skill. `autonomous` silences the *procedural* gates; the **merge gate** becomes the sole mandatory human stop, backed by five interrupt-now gates (ambiguity, destructive/out-of-envelope op, test integrity, budget blowout by cost, and the **fix-loop budget by iteration count**). Of the two budget gates, cost is model-driven (there is no token-usage hook) while the iteration-count one is hook-enforced; the destructive-op gate is hook-enforced too, via `guard-dangerous-ops.sh`.

**Two hard stops survive autonomous mode** — a non-empty clarify **Asked bucket**, and an **unresolved INCONCLUSIVE AC**. Neither is ever auto-approved; they are what makes optional plan-approval defensible.

`gates.merge` is the autonomy object the **land** gate reads: `enforce-gates.sh` blocks a land (`git push`, direct-to-main `git merge`, or `gh pr merge`) while `required && !acked`. It is not the only autonomy-adjacent object a hook reads — `gates.loop_budget.acked_through` is read by `enforce-gates.sh` (the commit-time fix-loop budget block) and by `prevent-mid-protocol-stall.sh`. What no hook reads is the **assumptions ledger**, which is surfaced to the human rather than enforced.

**MANDATORY READ:** read `references/settings.md` before acting here. This summary is an index, NOT the contract.

## Comment voice

Every user-facing **comment** this pipeline drafts — the Phase-1 paste-ready **ticket comment**, the Phase-5 **PR title + body**, and the Phase-7 **preview verdict** PR comment — is prose someone else reads on a ticket or a PR. When the user has a house writing voice, those comments should sound like it. This section is the single source of truth for that; the three comment surfaces reference it rather than re-specifying it.

**Resolve a voice guide (`VOICE.md`), first *non-empty* file wins:** (1) `<repo-root>/.claude/VOICE.md`, then (2) `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/VOICE.md`. Fall-through, not first-*present* — an empty project file never masks a populated global one. Found: treat it as the tone guide for the comment's **free prose**. Found none: use each surface's built-in default style.

**MANDATORY READ:** read `references/phase-1-preamble.md` before acting here. This summary is an index, NOT the contract.

**Hard constraints always outrank voice** — VOICE.md shapes *how prose reads*, never *what may appear*:
- The **no-AI-attribution** rule (no `Co-Authored-By: Claude`, no "🤖 Generated with…") on every commit message, PR title, PR body, and PR comment.
- The **ticket-comment contract** (no names, no greetings, strictly-business functional questions) and the **PR body's machine-structured content** (headings, tables, checklists, diagrams stay verbatim).
- The **per-surface length limits** (ticket comment stays short; PR title under 70 chars).

**Fail-open, silent, presentation-only:** resolving VOICE.md never blocks or errors a run, adds no gate, no yield, and no `AskUserQuestion`, and never alters `expected_next_action`.

## Pipeline

### Phase 1 — Define (HUMAN GATE)

**MANDATORY READ (first action of Phase 1):** read `references/phase-1-preamble.md` before doing anything else in this phase. It is the authoritative contract for every step below; this list is an index, NOT a substitute.

1. **Version check** (NEW runs only, first) — locate `hooks/check-version.sh` via the three-probe pattern, run it fresh, and if a newer version exists ask ONCE: proceed, or auto-apply. Skipped on resume. Fail-open.
2. **First-run setup** (NEW runs only) — if `settings.sh schema-status` is `unconfigured`/`stale`, run the five-question policy setup in one pass and stamp the version.
3. **Telemetry consent** (NEW runs only) — ask once per repo, only when `present telemetry_enabled` is `false`; record immediately (writing `false` is a real decision).
4. **Component preflight** — confirm the six **mandatory** composed skills + the `task-execution-verifier` agent exist. `auto-task-docs` and `auto-task-release` are **OPTIONAL and deliberately NOT hard-stops**: if either is absent, do NOT stop — degrade its step (Phase-5 docs / Phase-9 release) to `skip`, log the reason, and continue.
5. **Branch setup** — derive `<type>/<slug>`, pull the default branch, create + enter an isolated worktree, append `.auto-task/` and `.claude/worktrees/` to the git-common-dir exclude, create run folders, init `STATE.json` + `TRACE.md`, pin `state.base`.
6. **Clarifying questions** (HUMAN GATE) — six stages: draft candidates → research each for a **cite** → triage into Resolved (cite) or Asked (no cite) → route via the two-step router (answer here vs forward a comment) → record → no mid-pipeline re-asking.
7. **Recon + link handling** — inspect the running UI / live URL / library docs / design refs when needed. Two-tier load (fetch, then Playwright when it returns nothing); videos get screenshots + transcript. Read-only by default. **Capture the baseline "before" screenshot here** for a visual change — this is the only moment the pre-change state is renderable.
8. **Visual-assets consent** — evaluated *after* recon (UI scope must be known), only when the run has UI/visual scope.
9. **Approach selection** — when >1 viable approach changes blast radius, risk, dependencies, API shape, or migration cost: sketch 2-3, score, self-select on a clear winner or fold into the human gate on a close call.

**Non-negotiables that hold even if the reference was not read:**
- **Every ambiguity is either cited or asked** — there is no third bucket. "Probably X" / "looks like the convention" are not cites; one example is not a convention (≥3 occurrences, zero counter-examples).
- **No mid-pipeline *clarifying* questions.** After approval, Phases 2-5 must not stop to ask **clarifying questions** (a genuine new ambiguity is a Loop-rule clause-3 surface instead). This bounds clarification ONLY — it does **not** cancel the procedural yields defined elsewhere in this skill: the Phase-5 push/PR prompt, the Phase-5 step-1b docs ask, and any Loop-rule or destructive-action surface all remain. See the Yield-point contract for the authoritative list.
- **A missing *mandatory* component stops the run** — never hand-roll a substitute for `auto-task-code-review`, never skip a verifier gate. The two OPTIONAL skills (`auto-task-docs`, `auto-task-release`) are the deliberate exception: absent, they degrade their step to `skip` rather than halting.
- **`state.base` must not change for the life of the run.**

**Requirements decomposition (NON-NEGOTIABLE — the task, made unambiguous).** Before (or alongside) the AC table, dissect the raw task description into an explicit, numbered `## Requirements` list in `.auto-task/<branch>/PLAN.md`, and mirror it to `state.requirements[]`. Each requirement is:

- **Atomic** — one testable obligation, not a paragraph. Split "estimate time and tokens, then compare" into separate requirements.
- **Unambiguous** — phrased so a third party reads exactly one meaning; resolve vagueness using the Clarifications (asked answers + evidence-backed resolutions), never by leaving it fuzzy.
- **Traceable** — an `id` (`R1`, `R2`, …), the requirement `text`, `covered_by_acs` (the AC row numbers that verify it), and a `status` (`pending` → `done`, or `dropped` with a reason if explicitly descoped).

Then bind the two together: **every Acceptance Criterion names the requirement(s) it verifies (add a `Req` column to the AC table), and every requirement is covered by ≥1 AC.** Run `hooks/requirements-coverage.sh <STATE.json>` (locate via the three-probe pattern) and require `all_covered == true` BEFORE presenting the plan for approval — an uncovered requirement means the AC table is incomplete, so fix it (add an AC) rather than stopping. This is what makes "is the task done?" a checklist, not a judgment call: Phase 5 re-runs the same helper to confirm `all_complete == true`. Log `{ phase: "define-requirements", count: <n>, all_covered: <bool>, at: "ISO-8601" }`.

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
6. **Verification method is binding** — the `Verification method` you write is a *commitment*, not a hint. A later phase may NOT substitute a weaker proxy (a `grep`, a unit test, code-reading, or a local fixture) for a method declared as live / manual / Playwright / real-data. If a criterion can only be witnessed on a running app, a live URL, or against real external data, its `Verification method` MUST say so and its `Gate` MUST be `gate-a` (or a Phase-7 preview check) — never `self-verify` with a proxy standing in. This is the specific failure this contract exists to prevent: "I traced the wiring / fixtures pass" is NOT "I saw it work." (This restates and sharpens rule 4: a `self-verify` method must be one `auto-task-verify` actually runs; a live-only criterion is `gate-a`/Phase-7, not proxied.)
7. **Data precondition is explicit** — if a criterion's real-world outcome depends on external or runtime data that the code alone does not determine (Salesforce/CMS product config, a feature flag's live value, a third-party API's data, seeded DB rows), the row MUST name that precondition (add a short `Data precondition:` note to the `Verification method` cell). Local fixtures alone CANNOT mark such a row PASS — a fixture proves the code path, not that the criterion holds on the data users actually have. It requires the live/preview check against **representative real data**; absent that, it is INCONCLUSIVE (see the INCONCLUSIVE floor below), never PASS.
8. **Visual-by-default for UI changes** — when a criterion is about something a user *sees* (layout, spacing, size, color, component appearance, a visible flow), the PRIMARY row's `Verification method` MUST be a Playwright observation of the rendered result **on local dev** — e.g. `playwright: navigate to /settings (local dev), open the confirm dialog, screenshot, assert action button computed height = 48px` — with `Gate = gate-a`. A code proxy (grep for a class, an RTL `data-*` assertion) is allowed only as a *secondary* row that supplements the visual check, never as the sole evidence for a visual outcome. Rationale: a proxy like "`data-size="default"` is present" can pass while the pixels are still wrong; the reviewer needs the actual rendered result. This is rule 6 applied to pixels: a visual outcome is live-only, so it is `gate-a`, never `self-verify` with a proxy. **Reaching the UI is a solvable problem, not a blocker:** use the reuse-or-improvise ladder (running server → disposable render → **mock/seed data or cut corners to reach the *real* UI**). The mock/cut-corners allowance is scoped: it may only *stage or reach* the real component so a real screenshot can be taken — it may NEVER stand in *for* the visual observation, and for a **data-dependent** criterion (rule 7) mocked data does not satisfy it (that stays real-data-or-INCONCLUSIVE). If the UI genuinely cannot be rendered even after improvising **and** it can't be confirmed on the preview, the row is **INCONCLUSIVE** (per the floor), never a proxied pass and never a hard STOP.
9. **Local dev first, then preview** — for ANY criterion checkable against a running app (not just visual — a route's response, an interaction, a rendered state), verify on **local dev first** (reuse-or-improvise a local UI per the recon ladder), and treat the preview (Phase 7) as the *second* confirmation rung, not the first. A criterion that can't be witnessed locally even after mock/cut-corners falls to INCONCLUSIVE (resolved by verify-now or explicit descope) and, when a preview exists, is additionally re-checked there — it is never forced green with a proxy and never hard-stops the run.
10. **A before/after pair is REQUIRED to call a visual change done — and recreating the exact state is your job, not a blocker.** For any user-visible change, the run is **not done** without a real **before/after** screenshot pair of the *exact* thing that changed, captured on local dev (rule 8) and/or the preview (rule 9). **This proof is an explicit acceptance-criterion row, not an implicit step:** a UI/visual-scoped AC table MUST contain a dedicated row whose criterion is *"before/after of `<the exact changed state>` captured, and the rendered result confirms `<the request/issue>`"*, with `Gate = gate-a` — so capturing the screenshots and confirming the request is satisfied flows through Gate A and the completeness self-check like any other AC (the Phase-1 baseline is the "before", the Phase-3 verification shot is the "after"). "I would have had to change a prop / flip a setting / seed a row to see it" is **never** a reason to skip, downgrade, or hand-wave the proof — it is exactly the work to do:
    - **Recreate the precise look.** Drive the app (or a disposable harness) to the specific state the change affects and capture the same crop/viewport for both shots, so the delta is the *only* difference the reviewer sees.
    - **Temporary wiring is allowed to *reach* the state** — mount the component with specific props, flip a feature flag/setting, seed/mock the data, add a one-off story/route/harness — purely to render the real component (this is the rule-8 mock/cut-corners allowance; it stages the view, it never *stands in for* the observation, and a data-dependent criterion (rule 7) still needs real data).
    - **ALWAYS clean up after yourself (mechanically enforced by the single-commit rule).** Every temporary edit made *only* to reach the visual state MUST be reverted before Phase 5 staging. The committed diff must contain **only** the intended change — no scaffold props, no flipped defaults, no mock data, no throwaway story/route/harness. Track what you temp-wired and undo each item; then confirm `git diff <base>` (the exact bytes that will be committed) shows none of it. A leftover scaffold in the diff is a bug, not acceptable collateral.
    - **Genuinely impossible ≠ done.** Only after honestly exhausting temp-wiring + a disposable harness + the preview may a visual proof be unobtainable; that AC is **INCONCLUSIVE**, which (per the floor) blocks its gate and **surfaces as incomplete** — the run does **not** silently report a visual change "done" without its before/after. It resolves the floor's usual two ways (verify-now once a target is reachable, or an explicit user descope).
11. **External actions are declared and gated on Phase 8 — shipping the script is NOT done.** If a task's real-world outcome requires a change in an **external system** beyond shipping code — a CMS edit, a feature-flag toggle, a data migration applied to live, a third-party API config, or any "run this script/apply this config against the live system" step — the AC table MUST carry a dedicated **external-action row** for it, with `Gate = external` (Phase 8). The row names the target system, the apply method (the exact script/steps), and the post-apply verification. Mark the covered requirement so the row's completion is tracked. **Seed the manifest Phase 8 consumes:** for each such AC row, write a matching `state.external.actions[]` entry now (at declaration) — `{ id, system, description, script, verify, reversible, rollback }` (the schema's `actions[]` shape) — with `state.external.status: "declared"`; leave the runtime fields (`applied[]`, `verify[]`, the terminal `status`) for Phase 8. Refine an action's `script`/`verify`/`reversible`/`rollback` during implement (Phase 2) if the exact command/steps only become concrete then. This declaration IS the producer of `external.actions[]` — Phase 8 loads it, it does not invent it. This is always-on honesty (like the INCONCLUSIVE floor, and NOT gated by any setting): a task that needs an external change is **not `done` until that change is applied AND its post-apply verification passes** (Phase 8). An external-action AC that is declared-but-unapplied leaves the run in the not-done `awaiting-external`/`declared` state — it is never quietly reported "done" on the strength of the shipped script alone. (The `external_actions_mode` setting governs only *how* Phase 8 applies it — auto-run vs runbook — never *whether* the not-done gate applies.)

After writing the table, run a self-check before stopping:

- Count rows. If `< 2` for non-trivial tasks (Tier ≥ STANDARD), that's almost certainly missing coverage — re-read the task description and add rows.
- For each row, mentally run the `Verification method` and ask: "If this command/observation returned the `Expected result`, would I believe the criterion is satisfied?" If no, the row is too weak — rewrite it.
- For each row with `Gate = self-verify`, confirm the verification method maps to a check the current tier's `/auto-task-verify` scope actually runs. Types-only tier won't run a build assertion — escalate the tier or move the row to `gate-a`.

- For each row whose declared `Verification method` is live/manual/real-data (rule 6) or carries a `Data precondition:` (rule 7), decide NOW how it will be verified: against a target reachable during the run (a dev server the user is running, a reachable staging/preview URL) → run it at `gate-a`; or, if no pre-PR target is reachable, mark the row as one the run will surface at the approval gate (see the INCONCLUSIVE floor) so the user pre-decides. Do NOT silently downgrade it to a proxy to make it `self-verify`-green.
- **If the run has UI/visual scope, the table MUST contain the before/after-capture-and-confirm row from rule 10** (`Gate = gate-a`, verification = a Playwright before/after observation that confirms the requested visual change). If it's missing, the AC table is incomplete — add it before stopping. The screenshot proof is an acceptance criterion in its own right, never an unwritten side-effect.
- **If the task needs an external-system change (rule 11), the table MUST contain an external-action row** (`Gate = external`, naming the system + apply method + post-apply verification). If it's missing, the AC table is incomplete — add it before stopping. Detecting external side effects is part of recon: if the task says "run this against the CMS/DB/flag service/API" or the plan's change only takes effect after a live config/data step, that is an external action, not a code-only change.

If the AC table fails any of these self-checks, the human gate is NOT reached — fix the table first. The Critique pass's `[AC]` dimension is a second line of defense, not a substitute.

**The INCONCLUSIVE floor (NON-NEGOTIABLE — the honest resting state for an unrun verification).** An acceptance criterion has three outcomes, not two: **PASS**, **FAIL**, and **INCONCLUSIVE**. INCONCLUSIVE is recorded when a criterion's *declared* `Verification method` (rule 6/7) could not be executed in the current phase — the dev server is user-run and not running, the preview is unreachable, the required real data is not configured. It is the antidote to the failure mode where a live AC gets forced to PASS on the strength of a proxy because "not-verified" had no place to go.

Rules for INCONCLUSIVE:

- **INCONCLUSIVE is never PASS and never FAIL.** It does not count as a gate pass: `gates.self_verify.passed` / `gates.gate_a.passed` stay unsatisfied while any of their ACs is INCONCLUSIVE (an un-`pass` AC already blocks the gate — INCONCLUSIVE simply *names* the honest state so it is surfaced instead of quietly forced green). Do NOT invent a passing proxy to clear it.
- **INCONCLUSIVE never auto-advances the gate and never deadlocks.** Because the only live gate (Phase 7 preview) is *post-PR*, an INCONCLUSIVE AC cannot be quietly "deferred to Phase 7" and allowed past the pre-PR gate — that would ship an unverified PR. Instead it forces a **surface to the user** (the existing Loop-rule "external blocker" yield — set `expected_next_action: "user-approval"`), ideally *pre-empted at the Phase-1 approval gate* by flagging live-only ACs up front so the user pre-decides. It resolves ONE of exactly two recorded ways — there is no third "passes while still inconclusive" state (an unresolved INCONCLUSIVE AC always blocks its gate, per the bullet above):
  - **Verify now** — the user makes the target reachable (starts the dev server, provides a URL / configures the data); re-run the *declared* method → the AC becomes PASS or FAIL. This is the only way an INCONCLUSIVE AC becomes a pass.
  - **Descope from this run** — the user *explicitly* decides this criterion will not gate this run. Record it as a Human choice in CONTEXT.md and mark the covered requirement `dropped` (the status Gate A and the Phase-5 requirements-completion check already recognize — this is why descope, unlike a fictitious "deferred" status, does not deadlock downstream). The descope reason MAY be "will be verified post-PR on the preview" or "follow-up run" — and note that, independently, **Phase 7 still auto-verifies every URL-checkable AC on the pushed branch** when the project has a preview, so descoping-as-a-pre-PR-gate does not necessarily mean "never verified"; it means "not a pre-PR blocker for this run." A *primary* requirement's user-visible slice may only leave the run this way — an explicit, recorded descope — never a silent park (see "No scope creep").

  (There is deliberately no "accept and keep it as an unverified pass" option: the pipeline cannot honestly record a pass it never observed. Either it is verified now, or it is explicitly descoped — the honest states the existing `pass` / `dropped` vocabulary already represents.)
- **Record it.** Log INCONCLUSIVE AC outcomes in `state.history` (`result: "inconclusive"`) exactly like pass/fail entries — the documented AC-result vocabulary is `pass | fail | inconclusive`. In `state.checks[]`, an INCONCLUSIVE AC records `result: "info"` with an `inconclusive`-flagged evidence note (the checks manifest counts only `fail` as blocking, so `info` is correct there). A run that reaches Phase 5 with an unresolved INCONCLUSIVE AC (one that is neither re-verified to `pass` nor descoped to a `dropped` requirement) has a bug — surface, do not commit.

The floor is prose the model must honor (no hook enforces AC pass/fail — the commit hook gates the `gates.*` booleans, the review-staleness hash, and the fix-loop budget, but never an AC result). Its teeth are: (a) the "cannot set the gate unless every AC recorded pass" rule above, (b) the Gate A verifier being explicitly told to reject a proxy standing in for a live-declared method, and (c) this being a visible, reviewable contract so a false PASS is a catchable violation rather than an invisible judgment call.

**AC pre-flight (NON-NEGOTIABLE — runs BEFORE the critique pass and BEFORE the human gate).** The AC self-checks above test the table's *shape*; pre-flight tests each AC's *premise* against the real repo. For every AC whose `Verification method` is an executable command: dry-run it against the current tree, **pin the baseline** to `.auto-task/<branch>/recon/ac-<#>-baseline.*`, and log `{ phase: "define-preflight", ac, result: "pinned|failed-syntax|unreliable-signal", baseline, at }`.

**MANDATORY READ:** read `references/phase-1-preamble.md` before acting here. This summary is an index, NOT the contract. It carries the sample-verification protocol for tool-generated "list of things to fix" ACs (knip / jscpd / ts-prune / complexity scanners): sample ≥5 entries, independently falsify each, compute the false-positive rate, and **surface BEFORE the human gate if FP > 20%** — the plan rests on a wrong premise, so the user must pivot scope or switch tools.

**Three outcomes, restated inline:** all ACs pinned with FP ≤ 20% → advance to critique. An AC command that errors → fix the AC text and re-run pre-flight (do not stop for approval with a broken command). Any sampled list with FP > 20% → STOP and surface before the gate.

Pre-flight evidence goes in `PLAN.md` as `## AC Pre-flight`, one terse bullet per AC.

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

**Run-metrics estimate (auto — pre-execution).** Once tier/D/R are scored and the AC table + blast-radius file list exist, compute the pre-execution estimate so the user sees the run's likely cost at the approval gate. Locate the helper via the same three-probe pattern used for `check-version.sh` (`CLAUDE_PLUGIN_ROOT` is empty in the Bash-tool env), substituting `hooks/estimate.sh`. Then:

```bash
est="$(bash "$estimate_sh" --tier "$TIER" --difficulty "$D" --risk "$R" --acs "$AC_COUNT" --files "$BLAST_FILES")"
```

Write the parsed result to `state.estimate` (`duration_min`, `tokens_total`, `tokens_breakdown`, `basis`, `at`) and add an `## Estimate` section to `.auto-task/<branch>/PLAN.md` (a small table: metric | estimate | basis). Surface it in the plan presentation at the approval gate — this is the "estimate before execution" the metrics feature promises; the final summary later compares it against measured actuals. Log `{ phase: "define-estimate", result: "<duration>min/<tokens>tok", at: "ISO-8601" }` to `state.history`. **Fail-open:** if the helper cannot be located or returns null fields, record the estimate as unavailable (a visible note, never a fabricated number) and proceed — the estimate never blocks the run. **Bootstrap caveat:** if this run is itself modifying `estimate.sh`, the not-yet-installed helper cannot self-estimate; compute the estimate manually from the same heuristic and note it.

**Critique pass, critique → re-plan loop, and the high-risk disclaimer.** Before stopping for approval: spawn a fresh-context `general-purpose` agent to critique `PLAN.md` on four dimensions (`[AC]`, `[Blast]`, `[Edge]`, `[Rollback]`); classify each finding **structural-fixable** (resolve it yourself) or **judgment-required** (needs the human); amend for every structural finding and re-critique, bounded by tier (LIGHT 1 round; STANDARD/HEAVY 2). Then assemble the disclaimer if any trigger fired.

**MANDATORY READ:** read `references/phase-1-preamble.md` before acting here. This summary is an index, NOT the contract. It carries the exact critique prompt, the loop's exit conditions and recording format, and the full disclaimer trigger table with the wording each dimension requires.

**Non-negotiables restated inline:**
- **Mechanically-fixable findings are fixed BEFORE the human sees the plan**, so the gate adjudicates only genuine judgment calls.
- **A disclaimer is REQUIRED** when `effort.tier == "heavy"`, `effort.risk >= 5`, **any single risk dimension scored 2**, or the critique raised a `[Rollback]` concern. Trigger by score, not by feel — and add none when nothing trips, since noise dilutes the signal.
- **Never invent risks the rubric didn't score.** Wanting to warn about something scored low-risk means the rubric was wrong: re-score `effort` and log to `effort.history`.
- Log the assembly either way — an explicit `result: "not-required"` makes the call auditable.

**Autonomy branch (see "Autonomy modes & the merge gate").** If `state.autonomy == "autonomous"`, the plan-approval gate does NOT stop — with two mandatory exceptions that still hard-stop even in autonomous mode: (a) the clarify **Asked bucket is non-empty** (a genuine ambiguity — the ambiguity interrupt), or (b) an **unresolved INCONCLUSIVE** AC exists. Absent those, auto-approve: append a `state.assumptions[]` entry for each consequential call made without the user (every Decision-watchlist item → `kind: "thin-cite-decision"`; a fired risk disclaimer the user did not see → `kind: "risk-accepted"`), then write `approved: true`, `phase: "execute"`, `expected_next_action: "auto-continue"` and advance to Phase 2 WITHOUT stopping. The plan, critique, disclaimer, and watchlist are still fully generated and recorded to PLAN.md; they are simply surfaced later at the merge gate (Phase 5) instead of blocking here. If `state.autonomy == "supervised"` (default), use the normal gate below.

Before presenting the plan (supervised mode), set `expected_next_action: "user-approval"` in STATE.json — the Stop hook will allow the yield. Then present the plan summary (with the Critique section visible AND, if assembled above, the Risk disclaimer block) and **STOP**. Wait for explicit user approval (keywords: `approved`, `looks good`, `continue`, `proceed`, `yes`, `go ahead`).

When presenting, surface the `## Clarifications` section so the user can audit your evidence. For every Resolved entry, the cite is visible inline — the user can spot a wrong resolution by checking the cite. The Asked entries are the user's own answers from stage 4, replayed for verification.

Surface the **Decision watchlist** subsection prominently too, since it and the disclaimer both answer "what could bite later." **Present it exactly once** — it is a physical subsection of the `## Clarifications` block you surface just above, so decide its single slot and don't render it twice: when a risk disclaimer was assembled, lift the watchlist out and render it right beside the disclaimer (the highest-attention slot), and do NOT also leave a copy in the `## Clarifications` block you present. When no disclaimer fired (a `K == 2` decision does not necessarily trip the plan-level disclaimer thresholds), render it within the `## Clarifications` block as its own called-out subsection — it must not be buried. Either way the user sees it once. These are the consequential calls resolved without asking; the user should be able to veto or amend any of them at approval even though each carried a cite. **De-dup against the disclaimer:** if a watchlist item names the same risk a triggered disclaimer bullet already spells out (e.g. a `K == 2` external-integration decision that also fired the disclaimer's external-integration bullet), cross-reference it in one line rather than printing the risk twice — the disclaimer owns the plan-level risk, the watchlist owns the specific decision. If the watchlist is empty (nothing was promoted), say nothing about it — its absence is the signal that no self-made call was consequential enough to flag.

On approval: write `approved: true`, `phase: "execute"`, AND `expected_next_action: "auto-continue"` to state, then advance to Phase 2. From this point on, the Stop hook will block any attempt to end the turn until you reach a legitimate yield point or `phase: "done"`. **Do not commit on approval** — `.auto-task/<branch>/PLAN.md` stays out of git, and per the single-commit rule below, no code commit happens until Phase 5.

### Single-commit rule (NON-NEGOTIABLE)

**Phases 2, 3, Gate A, Phase 4, and Gate B do NOT commit.** All code changes — initial implementation, self-verify fixes, Gate A fixes, code-review fixes, Gate B fixes — accumulate in the working tree against the branch base. The git state across these phases looks like one growing uncommitted diff vs. the base branch.

Phase 5 produces exactly one **authored** commit (or, if the diff is very large, a small number of logically-grouped commits at the end) — only AFTER `gates.code_review.passed === true` and (for STANDARD/HEAVY tier) `gates.gate_b.passed === true`.

**Three exceptions, each gate-reviewed before it can land** (full contracts in `references/phase-5-handover.md`):
1. **The handover main-sync merge commit** — integration, not authored work, so it does not violate the rule. A clean auto-merge never reaches `enforce-gates.sh`; a conflict finalize (`git commit --no-edit`) does, and the staleness check applies during a merge too, so a resolved tree is admitted only once re-reviewed and `reviewed_diff_sha` refreshed.
2. **Phase-6 bot-fix commits** (opt-in) and 3. **the Phase-9 release commit** (opt-in) — authored commits after the Phase-5 one (the release commit is **Exception 3**, cited by that number from `references/phase-9-release.md`), permitted BECAUSE each re-passes the full machinery: re-verify, re-`auto-task-code-review` to a clean pass, refresh `reviewed_diff_sha`, **and on STANDARD/HEAVY reset `gates.gate_b.passed = false` and re-run Gate B**. The hook binds a freshness sha only to `code_review`, so without that reset a bot-fix would ship un-re-reviewed adversarially.

The invariant therefore holds in its true form: **every authored commit in the run is individually gate-reviewed** — code-review always, Gate B on the tiers that mandate it.

### Phase 2 — Execute (auto, NO COMMIT)

**On entry, set `phase: "execute"`** (with `expected_next_action: "auto-continue"`) in `.auto-task/<branch>/STATE.json`.

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
**On entry:** set `phase: "self-verify"` with `expected_next_action: "auto-continue"`.

Invoke the `auto-task-verify` skill on the **uncommitted working-tree diff** (`git diff <base>` — nothing is committed until Phase 5, so `..HEAD` would be empty). Parse its report.

**MANDATORY READ:** read `references/phase-3-gates.md` before acting here. This summary is an index, NOT the contract. It carries the MCP allowance, the full AC-execution contract, the checks-manifest capture (`checks.sh`), and the fix-loop / re-score mechanics.

**Non-negotiables restated inline:**
- **Execute EVERY AC row gated `self-verify`**, running its `Verification method` literally as written, and record each to `state.history` as `{ phase: "self-verify-ac", ac, result: "pass|fail|inconclusive", evidence, at }`.
- **`gates.self_verify.passed` cannot be `true`** unless every `self-verify` AC has a recorded `pass` from the current iteration. An `inconclusive` AC is NOT a pass and blocks the gate exactly like a fail.
- **Never substitute a weaker method.** If a declared live/manual/real-data method can't run here, record `inconclusive` per the INCONCLUSIVE floor — never green it with a `grep`, unit test, code-reading, or fixture proxy.
- **"All quality checks PASS" is a FAIL if an AC's bound check never executed** (e.g. the test file the AC names does not exist). Surface it as a missing test, not a pass.
- **A `checks.sh` `fail` row** (a real secret, or a conflict marker outside test/fixture paths) fails self-verify and routes into the fix loop.
- **Flakiness → STOP and surface** (Loop rule clause 4); otherwise `/auto-task-fix` the failing item and return to the start of Phase 3, incrementing `iteration.fix`. **No commit between iterations.**

### Gate A — Independent verifier (auto, NO COMMIT)
**On entry:** set `phase: "gate-a"` with `expected_next_action: "auto-continue"`.

**MANDATORY READ:** read `references/phase-3-gates.md` before acting here. This summary is an index, NOT the contract. It carries the full verifier prompt and the AC-execution detail.

**Non-negotiables restated inline:**
- **Execute every `gate-a` AC BEFORE spawning the agent**, running each declared `Verification method` as written; record `{ phase: "gate-a-ac", ac, result, evidence, at }`. Any `fail` **short-circuits Gate A** — feed back to Phase 2 without running the agent, since the agent's judgment is moot once a bound check failed.
- **A live/manual/real-data AC you cannot run here is `inconclusive`, not a proxied pass.** It routes to the human surface (verify-now, or explicit descope) — do NOT spin Phase 2 trying to "fix" an AC whose only blocker is an unreachable target.
- **Hand the verifier the AC table with user-descoped rows REMOVED**, and tell it which rows were descoped and why, or it will correctly flag the very row the user already descoped and bounce the run.
- **Tell the verifier to reject any proxied pass** — a `grep`, unit test, code-reading or local fixture standing in for a declared live method is INCONCLUSIVE, not a pass.
- **`gates.gate_a.passed` never becomes `true` while any AC is recorded `inconclusive`.** There is no "deferred-but-passing" state.
- The verifier's report is **INPUT**: set the gate, update state, and immediately make the next tool call — do not write a recap.

### Phase 4 — Code review + fix loop (auto, NO COMMIT)

**On entry, set `phase: "review"`** (`expected_next_action: "auto-continue"`).

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
- Before STOPPING on Loop-rule "no progress": forced re-score. If the tier escalates, grant ONE more iteration at the new tier (expanded `/auto-task-verify`, larger fix-loop budget, Gate B reinstated if previously skipped). If that iteration also makes no progress, STOP. This one-iteration grant is a *no-progress* concession; the loop-budget ack is a *volume* concession granted by the user. They are independent, and a run can be subject to both.

Exit conditions for this phase:
- Reviewer's latest pass produces only follow-ups → set `gates.code_review = { passed: true, tool: "skill:auto-task-code-review", clean_pass_after_last_fix: true, reviewed_diff_sha: "<sha>", at: <ISO>, evidence: "<reviewer summary; only follow-ups, no blockers/required>" }` → advance to Gate B (skipped at LIGHT tier — set `gates.gate_b.skipped_reason = "tier=light"` and go straight to Phase 5). The `tool` field MUST be the literal string `"skill:auto-task-code-review"` — the pre-commit hook rejects any other value (including agent invocations).
  - **`reviewed_diff_sha`** pins the exact diff this clean pass covered: compute it as `git diff --no-color --no-ext-diff --no-textconv --no-renames --diff-algorithm=myers --src-prefix=a/ --dst-prefix=b/ <base> | git hash-object --stdin` (where `<base>` is `state.base`). The flags MUST match those the `enforce-gates.sh` hook uses verbatim — they pin the diff text against git-config drift so an unchanged tree always hashes the same; omitting them risks a spurious staleness block. The pre-commit hook recomputes the same hash at commit time and **blocks the commit if it differs** — i.e. if any tracked code changed after the review went clean. Recompute and overwrite this field on every subsequent clean pass (e.g. after a Gate B fix forces a re-review). Never copy a stale value forward; set it from a freshly-computed hash only when the review is genuinely clean, exactly like the boolean flags.
- Loop rule triggers (no progress / out-of-scope / blocker / flakiness) **after** the re-score hook has been given its chance → STOP and surface (do NOT set `gates.code_review.passed`).

### Gate B — Adversarial verifier (auto, NO COMMIT)
**On entry:** set `phase: "gate-b"` with `expected_next_action: "auto-continue"`.

A second `task-execution-verifier` pass with an **adversarial** stance — flip the question from "is this complete?" to "find what's wrong." It passes only if the agent genuinely tries and fails to find issues.

**MANDATORY READ:** read `references/phase-3-gates.md` before acting here. This summary is an index, NOT the contract. It carries the full adversarial prompt (the five hunt categories) and the spawn inputs.

**Non-negotiables restated inline:**
- **Diff the working tree, not HEAD.** Pass `git diff <base>` — per the single-commit rule nothing is committed yet, so `<base>..HEAD` would be empty and the verifier would review no code.
- **Any blocker or required finding → back to Phase 4** with the finding as a fix task; increment `iteration.review`; do NOT set `gates.gate_b.passed`; and **reset `gates.code_review.passed` to `false`**, because an "addressed in name only" finding means the review did not really hold up.
- **Only follow-ups → park** in `state.followups` and set the gate. `No adversarial findings.` → set the gate.
- **The bar is "you tried and failed", not "you didn't try."**
- Trip-wire before ending the turn: did you write the gate-b resolution to state AND make the next tool call (a Phase-4 fix edit if blockers, the Phase-5 staging command if clean)? If not, you are about to stall.

### Phase 5 — Handover (auto, SINGLE COMMIT)
**On entry:** set `phase: "handover"` with `expected_next_action: "auto-continue"`.

This is the **only phase that commits**. The working tree holds the whole accumulated diff (implementation + every fix from self-verify, Gate A, code-review, Gate B) and state records that all required gates passed.

**MANDATORY READ (before step 1):** read `references/phase-5-handover.md`. Several steps carry ordering rules whose violation silently drops work from the commit. This index is NOT a substitute.

1. **Verify gates** — `gates.code_review.passed`, plus `gates.gate_b.passed` (or a valid `skipped_reason`) on STANDARD/HEAVY; then the **requirements completion check** (`requirements-coverage.sh` must report `all_complete == true`).
Step 1b — **docs update** (opt-in): runs BEFORE staging, and re-passes the full gate loop since its edits are new authored bytes.
2. **Change diagram** — Mermaid, type chosen by change shape. A pure visual change gets a before/after pair instead — but embedding is **opt-in and default-OFF**: only when `visual_assets_enabled` is `true` are screenshots uploaded and embedded; otherwise the PR gets a local-artifact note and nothing is uploaded.
3. **Collect verification artifacts** into `.auto-task/<branch>/artifacts/`.
4. **Write `CONTEXT.md`** (local, gitignored) — including run metrics (`token-usage.sh` → `state.actuals`) and the `state.quality` signals panel.
5. **Main-sync, then stage** — fetch the default branch, then stage the planned files only.
6. **Commit** via the `auto-task-commit` skill — the single authored commit.
7. **Integrate main** (merge), then verify `.auto-task/` did not leak into history.
7b. **Merge gate** — set AFTER the step-7 merge, never before, or the gate blocks its own integration merge.
8. **Push/PR prompt** — the `user-push-prompt` yield, plus the optional satisfaction ask (persist those answers HERE, before any `phase: "done"`). It is the last of Phase 5's **at-most-two procedural** surfaces — the optional step-1b docs ask is the other — and it is NOT the only human surface in the phase: the **step-7b merge gate** and an over-budget ack are separate conditional stops, and 7b is the *only mandatory* stop in `autonomous`+`direct`.
9-10. **Push**, then **open the PR** with the structured body.
11. **Append the handover trace.** 12. **Write `pr_url`**, then decide the terminal transition (Phase 6 → 7 → 8 → 9, or `done`).

**Non-negotiables restated inline:**
- **Never commit anything under `.auto-task/`** — run `git restore --staged .auto-task/ 2>/dev/null || true` before every commit, then re-check `git diff --cached --name-only`.
- **Never commit other people's pre-staged work** — exclude every path in the pre-existing-staged baseline you did not modify yourself.
- **Temp-scaffold cleanup is a blocker, not collateral.** Every edit made only to reach a visual state is reverted before staging; the committed diff is the change and nothing but the change.
- **A run reaching Phase 5 with an unresolved INCONCLUSIVE AC has a bug** — surface, do not commit. And never hand-set a gate flag to escape step 1.

### Phase 6 — PR bot-comment review & conservative fix (auto, GATED, opt-in)
Review bots (Cursor, CodeRabbit, Sourcery, Copilot review, …) often comment a minute or two after the PR opens. This phase collects them, triages **conservatively**, and auto-applies only high-confidence, in-scope fixes. Runs only when a push happened, a PR exists, AND `bot_review_autofix === true` (opt-in, default `false`).

**MANDATORY READ:** read `references/phase-6-8-post-pr.md` before acting here. This summary is an index, NOT the contract. (Phases 6, 7 and 8 in full.)

**Non-negotiables restated inline:**
- **Bot-fix commits are permitted ONLY because each re-passes the full gate machinery first** — re-verify, re-`auto-task-code-review` clean, refresh `reviewed_diff_sha`, and on STANDARD/HEAVY reset + re-run **Gate B** against the bot-fix diff.
- **Exactly ONE collection round.** Never re-poll for comments your own fix-push triggered — that is an unbounded loop.
- **When unsure, PARK.** Never "fix" something the user explicitly accepted at the risk disclaimer.
- **Every poll cycle bumps `bot_review.polls`**, or the anti-stall backstop reads the wait as a frozen run.

### Phase 7 — Preview verification & final verdict (auto, GATED, NO new authored commit)
The last verification rung: confirm the change works on the **deployed preview**, then record a verdict. Runs when a push happened AND either `has_preview_deployment === true`, or auto-learn is eligible (key unset, `preview_autodetect !== false`, a PR was opened).

**MANDATORY READ:** read `references/phase-6-8-post-pr.md` before acting here. This summary is an index, NOT the contract.

**Non-negotiables restated inline:**
- **NO new authored commit.** A FAIL is reported, never auto-fixed — the fix is a separate run.
- **Auto-learn persists ONLY a positive.** A non-detection is never written as `false` (a slow deploy bot looks identical to a genuine no-preview repo); the key stays unset and re-learns next run.
- **A 401/403 is deployment protection, not a failure** — record `INCONCLUSIVE`; never mask a possible regression behind an auth wall and never call it a pass.
- **Bind the deployment to the pushed SHA** — a `success` deployment for an older SHA is not ready for us.
- **Every poll cycle bumps `preview.polls`.**
- **External-actions terminal guard:** at EVERY Phase-7 exit that would write `phase: "done"`, first check for un-applied declared external actions — if any exist, route to Phase 8 instead.

### Phase 8 — External change application & verification (auto, GATED, NO new authored commit)
The honesty rung for tasks needing a change in an **external system** — a CMS edit, a flag toggle, a migration applied to live, a third-party API config. **Shipping the script is not the task being done.** Runs last, whenever the run declared external actions in Phase 1.

**MANDATORY READ:** read `references/phase-6-8-post-pr.md` before acting here. This summary is an index, NOT the contract.

**Non-negotiables restated inline:**
- **NO new authored commit.**
- **Detection + the not-done marking are ALWAYS ON**, never gated by a setting. `external_actions_mode` governs only *how* a change is applied, never *whether* the not-done gate applies.
- **`reversible: false` ALWAYS prompts**, in every mode, and the prompt must name the action as irreversible.
- **Auto-apply at most once, and only where auto-task is itself the applier.** On resume: `declared` → apply, skipping anything already in `external.applied[]`; **`awaiting-external` → VERIFY ONLY, never re-apply** (a human applied it, so `applied[]` cannot gate a re-run); `applied-unverified` → re-verify only; `failed` → surface, never auto-retry.
- **Credentials are NEVER written** to STATE, TRACE, CONTEXT, `artifacts/`, or the PR — redact secret-shaped tokens from every recorded sink.
- **A partial failure is always reported**, with per-action rollback and an explicit flag for anything irreversible.

### Phase 9 — Release (auto, GATED, opt-in, ONE additional authored commit)
The optional final rung: cut a release once the work has landed. Gated by `release_mode` (default `skip`, so a default run never enters this phase and `state.release` stays `null`).

**MANDATORY READ:** read `references/phase-9-release.md` before acting here. This summary is an index, NOT the contract.

**Non-negotiables restated inline:**
- **May make ONE additional authored commit** (the release commit), and only after re-passing the full gate loop.
- **Terminal vs surfaced is an honesty rule.** TERMINAL (`phase: "done"`, recorded): `applied`, `nothing-to-release`, `declined`, `runbook`, `deferred-pr`, every `skipped-*`. **SURFACED** (stays `phase: "release"`, NOT recorded): `in-progress`, `partial-failure` (a commit with no tag — the state most easily misread as success), `failed`.
- **None of the three surfaced states is auto-resumed, auto-retried, or auto-reverted.** Hand the recorded state + undo commands to the user and wait: the phase never silently re-cuts and never reports success it did not achieve.
- **The five degrade paths are recorded distinctly** (`skipped-disabled`, `skipped-invalid-value`, `skipped-skill-absent`, `runbook`, `failed`), so a skipped release is never indistinguishable from a failed one.
- **`bump` must record `bump_signal`** — the evidence for the derived level.

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
    ├── recon/                    # Phase 1 reconnaissance outputs + change-diagram.mmd + before/after screenshots + visual-changes.json
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

Per-branch folders are never auto-pruned by a run. Recommended user practice: reclaim with **`/auto-task-gc`** (the `auto-task-gc` skill), which removes reclaimable worktrees and prunes their matching `.auto-task/<branch>/` in the same pass; or, for a `.auto-task/<branch>/` folder with no worktree, `rm -rf .auto-task/<branch>/` by hand. `/auto-task` itself never deletes another branch's folder. Stale folders are harmless beyond disk space.

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

- **Acceptance Criteria are mandatory and load-bearing.** Phase 1 cannot stop for human approval unless `.auto-task/<branch>/PLAN.md` contains an AC table that satisfies all ten rules in the "Acceptance Criteria contract" above (including rule 6 verification-method binding, rule 7 data-precondition, and rules 8-10 governing visual/UI ACs). Phase 3's `gates.self_verify.passed` cannot be set to `true` unless every `self-verify` AC has been executed with a recorded pass (an `inconclusive` AC is not a pass and blocks the gate — see the INCONCLUSIVE floor). Gate A's `gates.gate_a.passed` cannot be set to `true` unless every `gate-a` AC has been executed with a recorded pass (none `inconclusive`) AND the independent verifier confirmed the bound checks really test the criterion's intent — with no proxy standing in for a live-declared method. There is no escape hatch — "the task is too simple for AC", "the AC was implicit", or "the generic verify checks covered it" are not acceptable reasons to skip. If you genuinely cannot articulate measurable AC for a task, STOP and surface to the user; do not invent passes.
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
- Mark items as follow-ups liberally. The bar for adding to the active loop is "addresses an Acceptance Criterion or fixes a blocker"; everything else parks. **One exception (see "No scope creep"): the user-visible slice of a *primary* requirement can never be parked as a follow-up** — it stays in-loop unless the user explicitly descopes it (recorded). Parking the visible behavior a task headline promised is the failure this rule prevents, not the brevity it licenses.
- **Verification honesty (the INCONCLUSIVE floor).** An acceptance criterion's declared `Verification method` is binding: never satisfy a live/manual/Playwright/real-data criterion with a `grep`/unit/code-reading/fixture proxy. When the declared method can't be run in-phase, record the AC `inconclusive` (never PASS), which blocks its gate. It resolves exactly two ways — **verify now** (make the target reachable → pass/fail) or **explicit descope** (a recorded Human choice; the covered requirement is marked `dropped`) — never a "deferred-but-passing" state, never a silent green. "I traced the wiring / fixtures pass" is not "I saw it work." See the "Acceptance Criteria contract → The INCONCLUSIVE floor".
