---
name: auto-task-code-review
description: Review code via a strict 5-phase workflow (Investigate → Define → Execute → Prevent → Verify). Read-only — never edits code. Use when the user says "code review", "review this code", "find issues in", "what's wrong with this", or asks for a critique of a specific file/function/diff. For PR/staged-diff orchestration use `review`; this skill is the disciplined problem-finding pass.
---

# Code Review

Disciplined code-review workflow. Five phases run end-to-end without stopping; quoted evidence is required in Phase 5.

> **Caller note (do not strip):** When this skill is invoked from a fix-loop protocol (e.g. `/auto-task` Phase 4, `/fix`, `/feature`), the structured output below is INPUT to that loop, NOT an end-of-turn signal for the caller. The caller is responsible for parsing the findings, applying fixes for Blockers/Required, and re-invoking this skill until the report is clean. The "Verdict:" / "Summary:" footer is formatting, not a stop. Headings like "No significant issues found.", final-paragraph rules, and trailing one-sentence summaries are ALSO not stops. After this skill returns, the caller's next action is mandatory: update the relevant `gates.*` flag in `.auto-task/<branch>/STATE.json` AND make the next tool call (Gate B agent, fix Edit, or Phase 5 stage/commit). If the caller writes a recap to the user instead, that is a protocol violation. See `~/.claude/CLAUDE.md` ("Mid-protocol non-yielding") for the global rule.

## Read-before-review contract (run first)

If this branch has an auto-task history folder, read it before forming any finding — otherwise you'll re-raise issues the user already settled or miss ones an earlier pass flagged but never closed.

1. `git branch --show-current` → `$BRANCH`; look for `.auto-task/$BRANCH/`. If it doesn't exist, this branch isn't auto-task-tracked — skip to Phase 1 and review normally.
2. **`.auto-task/$BRANCH/CONTEXT.md`** (if present) — the run's curated summary. Never raise a finding about a decision recorded under **Human choices**, or a risk the user acknowledged at the Phase 1 disclaimer; those are settled (raise a follow-up only if the implementation made the risk materially worse than the plan anticipated).
3. **`.auto-task/$BRANCH/TRACE.md`** (if present) — the append-only log of prior passes. If a finding overlaps an earlier entry, cite that entry and say what's new; don't repeat a resolved issue as if fresh.
4. **`.auto-task/$BRANCH/STATE.json`** (if you need detail) — gates, effort tier, parked follow-ups.
5. **On completion, append a TRACE.md entry** (operation slug `code-review:standalone`) in the block format defined in the auto-task orchestrator SKILL.md → "Persistent history & trace contract" → "TRACE.md format". **Suppressed under orchestration:** when invoked from `/auto-task` (see the Caller note), the orchestrator appends the review's trace entry itself — reading still applies, but do NOT append your own or you double-write the log.

## Hard rules

- **Read-only. No edits.** Do not modify source files. Do not paste rewritten versions of the code. Point to the line, name the issue.
- **Run all phases in one pass.** Do not pause for user approval between phases. The Phase 2 report is announced and then execution continues directly into Phase 3.
- **No speculative findings.** Every issue reported must trace to a specific line and a concrete failure mode (input that breaks it, caller that misuses it, behavior that diverges).
- **No padding.** If a dimension has no findings, say so in one line. Inventing weak nits to fill space is worse than a short review.
- **Match effort to risk.** Phase depth scales with the Phase 1 risk classification and any scope hint in the user's request. Reviewing a 30-line local helper does not require the same scaffolding as reviewing a shared CDC consumer.
- **Don't blow the scope.** Review what was asked — the named files, the diff, the function under review — not the surrounding codebase. Findings must be about code inside scope, or about a direct interaction between in-scope code and a specific caller/consumer/type that the in-scope code touches. Do NOT:
  - critique untouched neighboring code, pre-existing patterns, or "while we're here" cleanups
  - file findings about adjacent files just because you read them for context
  - propose refactors, renames, or architectural changes the user didn't ask for
  - expand a diff review into a full-file review (only changed lines + their direct call sites are in scope)
  - turn Phase 4 sibling search into a general code audit — siblings are evidence that an in-scope finding is systemic, not new findings of their own

  **The test for "same piece of work" vs "follow-up":** something is in scope if a reasonable author, fixing it now, would include it in *this* change without changing what the change is "about." A follow-up is a different piece of work — a different intent, a different commit message, a separate PR. When unsure, ask: would folding this in expand the scope of the change, or just complete it?

  **Example — PR adds null-safety to `parseUser()`:**
  - ✅ In scope (same piece of work): `parseAdmin()` in the same file has the identical null-deref pattern. The change is "harden user parsing"; leaving `parseAdmin()` broken means the work is half-done and the next bug report is inevitable.
  - ✅ In scope (direct interaction): a caller in `routes/auth.ts` passes a value that the new null-check now silently drops where it used to throw — the in-scope change altered the caller's contract.
  - 🟡 Out of scope → follow-up: `parseUser()` also has a confusingly named variable. Real, but unrelated to null-safety; cleaning it up changes what the PR is *about*.
  - 🟡 Out of scope → follow-up: the whole `parsers/` module uses callbacks instead of async/await. Separate refactor, separate decision.
  - 🟡 Out of scope → follow-up: `parseOrder()` in a sibling module has a null-deref too, but its callers and contract are different. Same bug class, different piece of work — flag as a follow-up, don't fold in.

  Rule of thumb: **same intent + same blast radius = same piece of work. Different intent OR materially wider blast radius = follow-up.** When you find a follow-up, list it under "Out-of-scope observations (not reviewed)" — one line, no fix. **Why:** scope creep wastes the user's attention, dilutes real findings, and turns a focused review into noise; but under-scoping leaves work half-done. **How to apply:** before recording any finding, ask "would folding this in *complete* the change, or *expand* it?"
- **Respect scope hints.** If the user says "keep it tight", "don't blow scope", "quick review", or names a narrow target, treat that as a hard cap: stay inside the named files, skip cross-codebase sibling sweeps unless a finding is clearly systemic, and skip the Phase 5 subagent.
- **Evidence required for every finding.** Each finding must cite a specific line and, where the failure depends on context, a quoted snippet of the producer/caller/type that proves it. Hand-waving claims get dropped.

## Phase 1 — Investigate

Goal: understand the code well enough to know what's actually at risk.

- Read the target scope (file, function, diff, or PR).
- If `.auto-task/<branch>/fixes/` exists, skim recent `.md` files for prior issue classes in this codebase.
- Trace execution: who calls this code, what does it call, what state does it touch?
- Map the **blast radius**: files, modules, callers, consumers, public APIs affected.
- Classify risk: **low** (isolated, pure logic, well-tested) or **high** (shared module, public contract, async/race, persistence, security, user input).
- Note the surrounding conventions (read `CLAUDE.md` if present, observe neighboring code style).

## Phase 2 — Define

Goal: write down what the review will cover, then continue.

Produce a short report:
1. **Scope** — exact files/functions/diff under review.
2. **Blast radius** — modules and callers that depend on this code.
3. **Risk** — low or high, with a one-line justification.
4. **Review dimensions** — which of {correctness, bugs, regressions, edge cases, complexity, consistency} apply, and any to skip with reason.
5. **Out of scope** — things the user might expect but won't be covered (e.g. performance if not asked, security if not relevant).

Print the report so the user can see the framing, then proceed directly to Phase 3 in the same turn. Do not wait for approval.

## Phase 3 — Execute

Goal: perform the review across the agreed dimensions. Read-only.

For each dimension, examine the code and record findings. Each finding has: `file:line`, one-line problem, one-line why-it-matters. **Findings must be about in-scope code** (see the "Don't blow the scope" hard rule). A finding about how an in-scope change interacts with a specific caller, consumer, or type is in scope; a finding about untouched neighboring code is not.

**Correctness**
- Does the logic match its stated intent?
- Async: promises awaited, rejections handled, no unhandled chains.
- Error paths: handled, propagated, or silently swallowed?

**Bugs**
- Null / undefined dereferences.
- Race conditions, ordering assumptions, shared mutable state.
- Logic errors: inverted conditions, wrong operator, wrong variable, copy-paste bugs.
- Type coercion surprises, truthy/falsy traps.
- Resource leaks: handles, listeners, timers.

**Regressions**
- Public API, return shape, or behavior contract changed?
- Existing callers still compatible? (Verify by reading call sites; if you can't, flag it.)
- Silent behavior changes (timing, ordering, defaults, error types)?

**Edge cases**
- Null/undefined, empty, single-element, max/min, boundary, off-by-one.
- Duplicate input, out-of-order input, concurrent input.

**Complexity**
- Overengineering: abstractions with one caller, premature generalization.
- Dead code, unreachable branches, commented-out blocks.
- Duplication of existing utilities.

**Consistency**
- Diverges from neighboring style, naming, or error-handling patterns?
- New patterns introduced where existing ones would do?
- Project conventions from `CLAUDE.md` violated?

## Phase 4 — Prevent

Goal: surface the same class of issue elsewhere in the codebase, when the issue is plausibly systemic.

- **Classify each finding** with a tag: `null-check`, `async`, `race-condition`, `off-by-one`, `state`, `types`, `validation`, `api-contract`, `dead-code`, `duplication`.
- **Search for siblings — only when warranted.** Run a sibling search for findings that look systemic (a pattern that could exist elsewhere, a misuse of a shared utility, an issue tied to a contract used by multiple callers). Skip the search for findings that are purely local (typo, copy-paste in one block, a dead branch in one function). State explicitly when a finding was scoped as local and no search was run.
- **Scope the search.** Default to the directly-affected module/package. Only widen to the whole codebase when the finding involves a shared contract or a repeated pattern likely to span modules. Under a "tight scope" hint, do not widen beyond the named files unless a finding is clearly systemic — and say so when you stop short.
- **Recommend a guardrail (optional, no edits).** For systemic issues, suggest the lightest preventive measure — a missing test, a type tightening, a lint rule, a runtime assertion at a boundary. Describe it; do not implement it.

## Phase 5 — Verify

Goal: prove each finding is real, with quoted evidence from the code.

- For each finding, quote the offending line(s) and, where relevant, the call site / test / type that proves the failure mode. No claim without a citation. Findings that cannot be backed by quoted evidence are dropped.
- **Fresh-context diff review — when warranted.** Spawn a subagent (e.g. `general-purpose`) with only the scope and the Phase 2 report and ask "what real problems would you flag in this code?" — but only when the Phase 1 risk is high *and* there is no "tight scope" hint from the user. For low-risk diffs, small local changes, or explicit tight-scope requests, skip the subagent and say so in one line. The subagent is a cross-check for high-stakes reviews, not a default ceremony.

## Output discipline

- Phase 1 output: blast radius + risk + conventions, in under ~10 lines.
- Phase 2 output: the structured report above, then continue immediately to Phase 3.
- Phase 3 output: findings grouped by dimension, each as `file:line — problem — why it matters`. Empty dimensions get one line: "No findings."
- Phase 4 output: tag per finding + sibling-search results when run (`file:line` list, used as evidence that an in-scope finding is systemic — not as new findings), or a one-line "scoped local — no sibling search" note + optional guardrail recommendations.
- Phase 5 output: per-finding quoted evidence + subagent review summary, or a one-line note that the subagent was skipped (with reason: low risk / tight-scope hint).
- **Out-of-scope observations (optional, ≤3 lines).** If you noticed something concerning outside the review scope, list it here as a note — not a finding. Skip the section if nothing applies.

If after Phase 3 there are no significant findings: **"Reviewed `<scope>`. No significant issues found."** Run a sibling search and the subagent only if Phase 1 flagged high risk and no tight-scope hint applies; otherwise stop there.
