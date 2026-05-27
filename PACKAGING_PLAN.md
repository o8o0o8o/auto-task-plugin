# Packaging plan — `auto-task-plugin`

## Goal

Ship `auto-task` as a self-contained Claude Code plugin, installable on any clone via `/plugin add <repo>`. Bundles the six forked sibling skills so install is one command. Ships the missing `task-execution-verifier` agent. Wires hooks + required permissions via a settings fragment. Zero memory writes; on-disk discovery is the contract surface.

## Decisions locked in

| Decision | Choice |
|---|---|
| Distribution target | Claude Code plugin (`.claude-plugin/plugin.json`, installable via `/plugin add` or marketplace) |
| Sibling skills (`plan`, `implement`, `verify`, `code-review`, `commit`, `fix`) | **Bundle forked copies.** Plugin owns the fork; sync from upstream on a manual cadence. |
| `task-execution-verifier` agent | **Author it.** Currently missing; Gate A/B can't spawn it. Ship a proper definition with a mode knob (`completeness` for Gate A, `adversarial` for Gate B). |
| Memory writes | **None.** All memory access is read-only. The "read before review" contract is enforced by patches to the bundled skills, not by writing to memory. |
| Read-before-review enforcement | Bundled skills check `.auto-task/<branch>/CONTEXT.md` + `TRACE.md` at start, append TRACE on completion. Optional `UserPromptSubmit` hook shipped commented-out for users who want non-bundled tools to discover the contract too. |
| Mid-protocol stall prevention | `Stop` hook reads `expected_next_action` from STATE.json and blocks turn-ends mid-pipeline. SKILL.md is already patched to write the field at every transition; the hook script ships in the plugin. |
| High-risk approval disclaimer | SKILL.md is already patched to assemble a triggered-by-rubric disclaimer at the Phase 1 approval gate. No additional packaging work — the updated SKILL.md carries the contract. |

## Package shape

```
auto-task-plugin/
├── .claude-plugin/
│   └── plugin.json                  # manifest (name, version, entry points)
├── skills/
│   ├── auto-task/{SKILL.md,ARCHITECTURE.md}
│   ├── plan/SKILL.md                # forked
│   ├── implement/SKILL.md           # forked
│   ├── verify/SKILL.md              # forked + history-check patches
│   ├── code-review/SKILL.md         # forked + history-check patches
│   ├── commit/SKILL.md              # forked
│   └── fix/SKILL.md                 # forked + history-check patches
├── agents/
│   └── task-execution-verifier.md   # authored from scratch
├── hooks/
│   ├── block-ai-attribution.sh      # extracted from settings.json
│   ├── enforce-gates.sh             # extracted + path fixed to .auto-task/<branch>/STATE.json
│   └── prevent-mid-protocol-stall.sh  # Stop hook; reads expected_next_action, blocks yields when "auto-continue"
├── settings-fragment.json           # snippet users merge into ~/.claude/settings.json
├── README.md                        # install / usage / troubleshooting / read-before-review contract
├── CHANGELOG.md
└── LICENSE                          # MIT
```

## Work items (in dependency order)

### Phase A — Fix correctness bugs BEFORE packaging (~2–3h)

These exist on the source machine today; packaging amplifies them.

1. **Fix the gate-enforcement hook path.** Update `~/.claude/settings.json` hook from hard-coded `.patches/AUTO-TASK-STATE.json` to resolve `.auto-task/<current-branch>/STATE.json` via `git branch --show-current`. Without this, every auto-task commit after the recent refactor goes through unblocked.
2. **Author the `task-execution-verifier` agent.** Single file with a `mode` knob (`completeness` | `adversarial`). Read-only tools (`Read`, `Glob`, `Grep`, `Bash`). Prompt scaffolding takes `{diff, AC table, prior findings, prior TRACE entries}` as input. Currently the skill references it but it doesn't exist → Gate A/B silently fall back or fail.
3. **Add a "read project memory" step to Phase 1 recon.** Before clarifying questions, if `~/.claude/projects/<slug>/memory/MEMORY.md` exists, read it so feedback/project memories feed into question generation and plan constraints. Read-only; no writes.
4. **Write the `Stop`-hook script and install it locally.** The skill is already patched to write `expected_next_action` at every transition (default `"auto-continue"`), but until the Stop hook ships, the field is informational. Author `hooks/prevent-mid-protocol-stall.sh`: read `.auto-task/$(git branch --show-current)/STATE.json`; allow yield when `phase === "done"`, `approved !== true`, or `expected_next_action ∈ {"user-approval", "user-push-prompt", null}`; otherwise return `{"decision": "block", "reason": "<phase + expected_next_action + instruction to make the next tool call>"}`. Also add a temporary copy to `~/.claude/settings.json` so the current machine benefits immediately. Without this, the recent SKILL.md changes around stall prevention have no mechanical teeth.

### Phase B — Genericize SKILL.md for outside users (~1–2h)

5. **Inline the load-bearing global rules** currently sourced from `~/.claude/CLAUDE.md`:
   - No AI-attribution markers in commits / PR bodies.
   - Code review always via the `code-review` skill (no agent / hand-rolled prompt substitution).
   - Mid-protocol non-yielding contract.
   - Task Execution Protocol (Define → Execute → Verify with DoD).
6. **Replace user-specific phrasing.** "The user has set it explicitly" → "this skill mandates". "Per `~/.claude/CLAUDE.md`" → "per the rules inlined in this skill".
7. **Remove personal-clone path references.** Keep one footer note pointing at `settings-fragment.json` for the global-hook install step.

### Phase C — Build the package (~1–2h)

8. **Create plugin layout** and write `.claude-plugin/plugin.json`. Verify required fields against the current Claude Code plugin spec via Context7 before locking the manifest — wrong fields fail silently at install.
9. **Fork the six sibling skills.** Verbatim copies as a v0.1.0 baseline.
10. **Patch the bundled skills** that participate in the read-before-review contract — `code-review`, `verify`, `fix` at minimum (also `review` if shipped). Two additions per file:
   - **Start of flow:** if `.auto-task/<branch>/` exists, read `CONTEXT.md` and `TRACE.md` before forming findings.
   - **End of flow:** append a TRACE entry per the format in `auto-task`'s SKILL.md.
11. **Extract the two PreToolUse hooks** from `settings.json` into `hooks/block-ai-attribution.sh` and `hooks/enforce-gates.sh`. Standalone scripts with `#!/usr/bin/env bash`, `set -euo pipefail`. Preserve jq/grep logic verbatim from the inline command but fix the gate-enforcement path per item 1.
12. **Move the Stop hook into the package.** Take the script from item 4 (`hooks/prevent-mid-protocol-stall.sh`) and stage it for plugin install. Confirm it returns the `block`-decision JSON shape that Claude Code's Stop hook expects (verify the exact field name via Context7 against the current hook spec).
13. **Author `agents/task-execution-verifier.md`** (paired with item 2 — this is the file that ships in the plugin).
14. **Write `settings-fragment.json`.** Contains:
    - Two `hooks.PreToolUse` entries pointing at the plugin's `hooks/block-ai-attribution.sh` and `hooks/enforce-gates.sh`.
    - One `hooks.Stop` entry pointing at `hooks/prevent-mid-protocol-stall.sh` — the mid-protocol stall enforcement.
    - `permissions.ask` entries: `Bash(git push:*)`, `Bash(gh pr create:*)`, `Bash(gh pr merge:*)` — these make Phase 5's push prompt fire as a real permission gate.
    - Optional, commented-out: a `UserPromptSubmit` hook block that injects a one-line system-reminder when the prompt mentions "review" / "audit" / "verify" AND `.auto-task/<current-branch>/` exists. Lets non-bundled tools opt into the contract.

### Phase D — Documentation (~1–2h)

15. **README.md** must cover:
    - Installation steps (`/plugin add`, settings-fragment merge).
    - Hard prerequisites (`jq`, `gh`, `git`).
    - The `/auto-task` invocation surface (new run vs. resume).
    - Worked example: a small task run end-to-end with the artifacts it produces.
    - **Read-before-review contract** section — explains how the on-disk discovery works so third-party tools (out-of-plugin reviewers) can opt in.
    - **Recommended project memories** — examples of feedback/reference memories that materially improve auto-task results (commit-authorization rules, subagent guardrails, project conventions). Documents the contract without shipping any memory files.
    - Troubleshooting matrix: what each hook block message means, how to resume runs, how to prune `.auto-task/<branch>/`.
16. **CHANGELOG.md** — v0.1.0 initial release. Note the upstream snapshot date for each bundled sibling skill so future syncs have a reference point.
17. **LICENSE** — MIT.

### Phase E — Test the install end-to-end (~1–2h)

18. **Clean-room install.** Throwaway `HOME` (or fresh `~/.claude/` test dir). Install the plugin, merge the settings fragment, run `/auto-task <trivial task>` on a sample repo. Confirm:
    - Phase 1 clarifying questions appear via `AskUserQuestion`.
    - Plan approval works.
    - `git commit` is blocked when gates are false.
    - `git commit` is allowed when gates are true.
    - `.auto-task/<branch>/` populated with `CONTEXT.md`, `TRACE.md`, `artifacts/`, `recon/`.
    - PR body contains the change diagram, no `.auto-task/` references, no AI-attribution markers.
19. **Negative tests.**
    - Forge `STATE.json` with `gates.code_review.passed: false` → confirm pre-commit hook blocks `git commit`.
    - Forge `gates.code_review.tool: "agent:code-reviewer"` → confirm pre-commit hook blocks.
    - Attempt to add an AI-attribution marker to a commit message → confirm AI-attribution hook blocks.
    - **Stop-hook test (item 12).** Forge `STATE.json` with `approved: true`, `phase: "review"`, `expected_next_action: "auto-continue"`. Simulate a mid-pipeline turn-end → confirm Stop hook returns `decision: "block"` with a reason naming the phase. Then set `expected_next_action: "user-approval"` and confirm the yield is allowed.
    - **Disclaimer trigger test.** Force a high-risk plan (e.g., AC touches `auth/` so the "production blast" dimension scores 2). Confirm Phase 1 presents a `## ⚠ Risk disclaimer` block above the Critique with the specific trigger named. Then force a low-risk plan and confirm no disclaimer appears (and `state.history` records `result: "not-required"`).
    - Document that `git commit --no-verify` bypasses repo-level git hooks but NOT settings.json `PreToolUse` hooks (those run on the Bash tool call, not the git invocation).
20. **Cross-platform smoke.** macOS is primary; if Linux users are in scope, verify the bash hooks under `bash` + `dash` and confirm jq behavior is consistent.

### Phase F — Distribution (~0.5h)

21. **Pick hosting.** Public GitHub repo (e.g. `github.com/<user>/auto-task-plugin`)? Add to `claude-plugins-official` marketplace for discovery? Tag `v0.1.0`, write release notes pointing at the CHANGELOG.

## Open questions to resolve along the way

- **Plugin manifest format.** Verify required fields in `.claude-plugin/plugin.json` against the current Claude Code plugin spec via Context7 before locking. Spec may have shifted; wrong fields fail silently.
- **Stop-hook return shape.** Verify via Context7 that `{"decision": "block", "reason": "..."}` is the current schema for blocking a Stop event (field names occasionally differ between versions). If the harness expects different JSON, adapt `hooks/prevent-mid-protocol-stall.sh` accordingly.
- **`enabledPlugins.figma`** as an optional integration. Phase 1 recon uses the Figma MCP for design-driven tasks. Document as optional in README — plugin works without it; just skips the Figma branch.
- **Sibling-skill upstream sync strategy.** Once forked, how do you pick up upstream improvements? Recommended cadence: pin upstream commit SHAs in CHANGELOG for each bundled skill; on each minor release, diff against upstream and decide what to pull. Surface this in CONTRIBUTING.md if other people will help maintain.
- **Memory-reading scope (item A3).** Define which sections of MEMORY.md feed into Phase 1: clarifying questions vs. plan-body constraints vs. recon targeting. Define tie-breaker if a memory conflicts with the task description (recommend: memory wins, surface the conflict to the user before approval).

## Risks

1. **Plugin manifest spec may have changed** since auto-task was last touched — verify field names via Context7 before locking the manifest.
2. **Forked sibling skills drift from upstream.** Within ~3 months upstream `code-review` or `verify` may evolve in ways worth pulling; build a "resync" review cadence into your routine.
3. **Hook scripts require `jq`.** Hard dependency. Document prominently; silent install failure if jq missing.
4. **`task-execution-verifier` authoring is non-trivial.** Two modes (completeness, adversarial), strict read-only tool set, fresh-context contract. Worth time-boxing — if mode-switching is messier than expected, fall back to two separate agents (`verifier-completeness`, `verifier-adversarial`).
5. **Stop hook can over-block.** If the skill forgets to set `expected_next_action` correctly at a legitimate yield point (e.g., a future-added gate), the user will see the hook's block message instead of the intended prompt. Mitigation: include the Stop-hook test (item 19) on every release; treat block-when-yield-was-intended as a P1 bug.
6. **Disclaimer fatigue.** If the rubric scores most tasks as high-risk in some codebases (e.g., a monorepo where everything touches "auth"), users will desensitize to the disclaimer. Mitigation in v0.1.0: keep the trigger thresholds where they are and review them after the first 10 runs in a real repo; tighten if disclaimer-rate exceeds ~30% of runs.

## Effort estimate

**~9–13h of focused work** end-to-end (~1h added for the Stop-hook scripting + tests). Phases A and B are the most thoughtful (real bug fixes + content rewriting); C–F are mostly mechanical.

## Suggested execution order

1. A1 (hook path fix) — unblocks all subsequent commits.
2. A2 (author verifier agent) — unblocks Gate A/B testing later.
3. A3 (memory read in Phase 1 recon) — small skill addition.
4. A4 (Stop-hook script + local install) — turns the existing SKILL.md changes into mechanical enforcement on the current machine; valuable even before packaging.
5. B5–B7 (genericize SKILL.md content).
6. C8–C14 in parallel (packaging mechanics; includes Stop-hook integration into the plugin).
7. D15–D17 (docs).
8. E18–E20 (test — now includes Stop-hook and disclaimer-trigger tests).
9. F21 (release).

## Non-goals for v0.1.0

- Memory **writes** of any kind (per the locked decision; revisit in v0.2.0 only if a concrete need surfaces).
- Auto-syncing bundled sibling skills from upstream.
- Marketplace listing (can ship as a public repo first; marketplace later).
- Cross-shell hook portability beyond `bash` + `zsh` on POSIX systems.

## Approval / kick-off

If this plan is approved, the natural next step is:

```
/auto-task package the auto-task skill as a Claude Code plugin per .claude/skills/auto-task/PACKAGING_PLAN.md
```

For the run itself: do items A1–A3 manually first (correctness fixes that change upstream skill state — better with a human in the loop), then let `/auto-task` handle phases B–E in one supervised run. F is a single tag + release-notes command at the end.
