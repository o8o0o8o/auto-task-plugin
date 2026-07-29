# Phase 3 & Gates A/B — full reference

_Phase 3 (self-verify), Gate A (independent verifier) and Gate B (adversarial verifier) in full, including the MCP allowance, the AC-execution contract, the checks manifest and both verifier prompts. `SKILL.md` keeps each step's entry condition, its gate rule, and its non-negotiables. **Phase 4 (code review + fix loop) deliberately stays wholly inline** — it is the anti-stall keystone and the phase most likely to be mid-loop when context is tight._

_Split out of `skills/auto-task/SKILL.md`; the content below is verbatim. `SKILL.md` points here with a MANDATORY READ directive._

## Cross-references

The prose below is reproduced verbatim, so its internal "see X" pointers still read as if the spec were one file. Where a named target now lives elsewhere:

- the Acceptance-Criteria contract and the INCONCLUSIVE floor → `SKILL.md`

---

## phase3-body — relocated verbatim from SKILL.md


**On entry, set `phase: "self-verify"`** (`expected_next_action: "auto-continue"`).

Invoke the `auto-task-verify` skill on the **uncommitted working-tree diff** (`git diff <base>` — no `..HEAD`, the changes are not yet committed). Parse its report.

**MCP usage in verification is open.** Any MCP available to the session may be used during self-verify and the gates if it's the most direct way to execute a Verification method or confirm an observation. Common picks:

- **playwright** — live UI / browser-driven AC checks (selector present, no console errors, screenshot diff, network call returns expected payload). **Local dev first** (rule 9): resolve a local UI via the recon reuse-or-improvise ladder (running server → disposable render → mock/seed to reach the *real* UI) and run the check there; the preview (Phase 7) is the second rung. If the UI can't be reached even after improvising, record the AC **INCONCLUSIVE** (never a proxied pass, never a hard STOP) per the floor. **For any visual AC (rule 8), the screenshot you take to verify the criterion IS the "after" image** — drive the app to the same state the Phase 1 baseline captured, `browser_take_screenshot`, save as `.auto-task/<branch>/recon/screenshot-after.png` (same crop/viewport as `screenshot-before.png`). One shot serves both the assertion and the PR. **Close every Playwright session when the check is done** (`browser_close`), and shut down any disposable render harness you started — don't leave browsers or servers running across phases.
- **ide** — `getDiagnostics` to assert no new type/lint errors in the touched files.
- **claude_ai_Context7** — confirm an external library API the code now calls actually behaves the way the plan assumed.
- **plugin_figma_figma** — visual reference comparison for design-driven ACs.
- Others (Notion, Drive, Slack, etc.) only when the AC explicitly references content in that system.

Same rules as Phase 1 recon apply: **read-only by default** (writes to external systems are forbidden during verification without explicit user authorization in this run); auth prompts are not blockers — log `result: "ac-blocked"` for that AC and treat it as fail, since an AC that can't be executed can't pass; mandatory prerequisite skills (`figma-use` before `use_figma`) still load. If the AC's `Verification method` literally names an MCP call, run that call; otherwise, prefer the cheapest tool that produces the evidence.

**AC execution contract (NON-NEGOTIABLE).** In addition to whatever the `auto-task-verify` skill runs by default, you MUST execute every row in PLAN.md's Acceptance Criteria table whose `Gate` column contains `self-verify`. For each such row:

1. Run the `Verification method` literally as written (the command, assertion, or MCP call).
2. Capture stdout/stderr/exit code (or MCP response payload) and compare against `Expected result`.
3. Record the run in `state.history` as `{ phase: "self-verify-ac", ac: <#>, result: "pass|fail|inconclusive", evidence: "<command or MCP call + result snippet>", mcps: ["..."] (if any), at: "ISO-8601" }`.

**Do not substitute a weaker method (verification-method binding, AC contract rule 6).** Run the AC's *declared* `Verification method`. If it is live/manual/real-data and you cannot execute it here (dev server user-run, preview unreachable, data not configured), do NOT green it with a `grep`/unit/code-reading proxy — record `result: "inconclusive"` per the INCONCLUSIVE floor and let it route to the human surface (verify-now, or explicit descope). A `self-verify`-gated AC should never *be* live-only in the first place (rule 4/6 routes those to `gate-a`); if you find one that is, that is a plan defect — fix it, don't proxy it.

`gates.self_verify.passed` cannot be set to `true` unless EVERY `self-verify`-gated AC row has a recorded `result: "pass"` entry from the current iteration. An AC recorded `inconclusive` is NOT a pass and blocks the gate exactly like a fail (it resolves only through the INCONCLUSIVE floor's human decision, never by inventing a proxy pass). If the `auto-task-verify` skill's report says "all quality checks PASS" but an AC's bound check was never executed (e.g., the test file the AC names doesn't exist yet), that is a FAIL — surface it as a missing test, not a pass. Do not treat AC coverage as optional just because the generic checks were green.

**Checks-manifest capture (NON-NEGOTIABLE — builds the "comprehensive checks" the summary enumerates).** Every verification run in this phase MUST be recorded to `state.checks[]` so the final summary can list them all. A check row is `{ name, category, command, gate, result: "pass|fail|warn|info|skip", evidence, at }`. Populate it from two sources:

1. **Each `auto-task-verify` check** (typecheck, lint, build, unit, e2e/playwright) and **each `self-verify` AC bound-check** — one row per check, `gate: "self-verify"`, `result` from its exit code / comparison, `evidence` a short snippet.
2. **Universal hygiene/defect checks** via `hooks/checks.sh` (locate with the three-probe pattern). Run `checks.sh --base <base>` — it returns rows shaped `{name, category, result, detail}` (secret-scan, conflict-markers, debug-artifacts, large-files, diff-size, tests-added). Map each into a `state.checks[]` entry by renaming `detail`→`evidence` and adding `gate: "self-verify"` (plus `command`/`at` where known) so the appended rows match the `state.checks[]` schema. **A `result: "fail"` row (a real secret or a leftover conflict marker outside test/fixture paths) FAILS self-verify** — route it into the fix loop exactly like a failing quality check. `warn`/`info` rows are recorded but do not block.

Gate A and Gate B likewise append their findings to `state.checks[]` (tagged with the appropriate `gate`), so the manifest is complete by Phase 5. This is additive to the `self-verify-ac` / `gate-a-ac` history entries — reuse their evidence rather than re-running. Fail-open: if `checks.sh` cannot be located, record a single `metric-unavailable` note and proceed (never a silent skip that reads as "all clean").

- All `auto-task-verify`-skill tasks COMPLETE + all quality checks PASS + every `self-verify` AC executed with `result: "pass"` + no `checks.sh` `fail` row → set `gates.self_verify = { passed: true, at: <ISO>, evidence: "<short summary of checks that passed, including which AC rows ran>" }` and advance to Gate A.
- Any task PARTIAL/NOT FOUND, or any quality check FAIL → diagnose:
  - If the failure indicates flakiness (intermittent test, retry-passes-without-change) → STOP and surface per Loop rule.
  - Otherwise → invoke `/auto-task-fix` against the failing item (which modifies the working tree, no commit), then return to start of Phase 3. Increment `iteration.fix`.
- **Re-score hook.** Before incrementing `iteration.fix`, check whether the failure exposes anything outside PLAN.md's Blast Radius / Unknowns. If so, re-run the rubric, update `effort`, log to `effort.history`, and apply the new tier's caps and `/auto-task-verify` scope to the next iteration.
- Apply the Loop rule between iterations to detect "no progress". If `iteration.fix` has reached the current tier's fix-loop cap, do a forced re-score before STOPPING; if the tier escalates, the new (higher) cap applies, which raises the budget. Two independent mechanisms are in play and neither silently undoes the other: a **tier escalation** raises the cap itself, whereas a **user ack** (`gates.loop_budget.acked_through`) raises the budget to the next cap rung that clears the current loop count, without changing the tier — the effective budget is `max(cap, acked_through)`, so both are honoured. Note the budget is measured against `max(iteration.fix, iteration.review)`, so review rounds consume it too.


## gate-a-body — relocated verbatim from SKILL.md


**On entry, set `phase: "gate-a"`** (`expected_next_action: "auto-continue"`).

**Before spawning the agent**, execute every AC row whose `Gate` column contains `gate-a`. Run the `Verification method` **as declared** (verification-method binding, AC contract rule 6) and compare exit code / output (or MCP response) against `Expected result`. The MCP allowance from Phase 3 applies here too — any available MCP may be used to execute a bound check, read-only by default. Record each as `{ phase: "gate-a-ac", ac: <#>, result: "pass|fail|inconclusive", evidence: "<command or MCP call + result snippet>", mcps: ["..."] (if any), at: "ISO-8601" }` in `state.history`. Any `gate-a` AC with `result: "fail"` short-circuits Gate A immediately — treat as an unsatisfied criterion and feed back to Phase 2 without running the agent (the agent's judgment is moot if a bound check already failed).

**A live/manual/real-data AC whose declared method you cannot run here is `inconclusive`, NOT a proxied pass (the INCONCLUSIVE floor).** Do not substitute a `grep`/unit/code-reading check for a declared live method to clear the gate. An `inconclusive` `gate-a` AC does not pass the gate; it routes to the human surface (verify-now, or explicit descope) exactly as the floor specifies — and until the user resolves it (re-verified to `pass`, or descoped so its requirement is `dropped`), `gates.gate_a.passed` stays `false`. Surface it (`expected_next_action: "user-approval"`); do not spin Phase 2 trying to "fix" an AC whose only blocker is that the verification target is unreachable.

If every `gate-a` AC passed (or there are none), spawn the `task-execution-verifier` Agent (prefix its `label` with `state.title` per the "Run label" convention) with a fresh-context prompt containing:
- The Acceptance Criteria table from `.auto-task/<branch>/PLAN.md`, **with any user-descoped rows removed** (a row whose requirement the user marked `dropped` via the INCONCLUSIVE floor is no longer a criterion of this run — do not hand it to the verifier, or it will correctly flag the very row the user already descoped and bounce the run). Tell the agent, in one line, which rows (if any) were descoped and why, so it does not treat their absence as missing coverage.
- The current working-tree diff (`git diff <base>` — uncommitted).
- The list of `state.history` entries with `phase: "gate-a-ac"` (so the agent sees which checks already ran and what they returned).
- Explicit ask: "For each row in the Acceptance Criteria table, confirm the diff satisfies the `Criterion` AND that the listed `Verification method` would actually produce the `Expected result` if re-run now. For rows already executed above, validate the evidence is real (not fabricated) and that 'pass' actually maps to the criterion's intent (not a superficial match). **Reject any 'pass' where a weaker proxy (a `grep`, a unit test, code-reading, or a local fixture) was used to satisfy a criterion whose declared `Verification method` is live / manual / Playwright / real-data — that is not a pass, it is INCONCLUSIVE.** Likewise flag any criterion whose real-world outcome depends on external/runtime data but was only checked against fixtures. Flag any criterion that is unsatisfied, weakly satisfied, or whose bound check doesn't truly test it. Do not propose new work — only judge completeness."

If any AC row failed its bound check OR the agent reports any criterion unsatisfied / weakly satisfied / proxied-when-live: feed findings back as a fix list, return to Phase 2 (append each unsatisfied criterion as a new implement task under a "Gate A findings" section in PLAN.md). After fixing, return to Phase 3. **Do not commit between iterations.** (A criterion the agent flags as proxied-for-live is re-classed `inconclusive` and routes to the human surface, not the Phase-2 fix loop — its blocker is an unreachable target, not missing code.)

If every `gate-a` AC passed its bound check (none left `inconclusive`) AND the agent confirms all criteria satisfied: set `gates.gate_a = { passed: true, at: <ISO>, evidence: "<agent summary + which AC rows were executed with pass results>" }` and advance to Phase 4. An `inconclusive` gate-a AC must first be *resolved* through the INCONCLUSIVE floor before the gate can pass — either re-verified to `pass` (target made reachable) or descoped (its requirement marked `dropped`, and the row removed from the gate-a set, per the floor). The gate never passes while any AC is still recorded `inconclusive`; there is no "deferred-but-passing" state.

**Reminder (see top-of-file NON-YIELDING CONTRACT):** the verifier's report is INPUT. Set the gate, update state, write the next phase header, and immediately call the next tool — do not write a recap to the user.


## gate-b-body — relocated verbatim from SKILL.md


**On entry, set `phase: "gate-b"`** (`expected_next_action: "auto-continue"`).

Second `task-execution-verifier` pass with an **adversarial** stance — flip the prompt from "is this complete?" to "find what's wrong." Pass only if the agent genuinely tries and fails to find issues.

Spawn with a fresh-context prompt (prefix the Agent's `label` with `state.title` per the "Run label" convention) containing:
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
