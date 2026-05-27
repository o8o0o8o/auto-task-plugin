# Project context — `auto-task-plugin`

Entry-point document for anyone (human reviewer, future Claude session, contributor) picking up this repo cold. Read this first to understand WHAT this is, WHY it exists, and WHERE everything lives. For the work plan, read [`PACKAGING_PLAN.md`](./PACKAGING_PLAN.md) next.

## What this project is

A Claude Code plugin that ships the `auto-task` skill — an end-to-end autonomous task workflow that takes a plain-English task description from intake to pull request with one human gate at plan approval. Everything after approval runs unattended until success, a hard blocker, or test flakiness, with mechanical enforcement of every protocol invariant via hooks.

## Why this project exists

The `auto-task` skill was developed in-place at `~/.claude/skills/auto-task/` on the author's machine over multiple iterations. It had grown enough hidden dependencies (six sibling skills, two pre-commit hooks in `~/.claude/settings.json`, several "non-negotiable" rules in `~/.claude/CLAUDE.md`, an agent that didn't actually exist) that sharing it required surgical extraction. This repo is that extraction — a self-contained, installable package with everything the skill needs to run on a different machine.

## Status

**v0.1.0 — pre-release.** Scaffolded, copied existing assets, all hook scripts authored, but several items in `PACKAGING_PLAN.md` remain before tagging:

- The `task-execution-verifier` agent is a STUB (Phase A2). Gate A and Gate B fall back to `general-purpose` until it's fleshed out.
- Plugin manifest field names in `.claude-plugin/plugin.json` are placeholders. Verify against the current Claude Code plugin spec via Context7 before locking.
- The bundled sibling skills are forked verbatim; they need the read-before-review patches applied (Phase C item 10).
- No end-to-end clean-room install test yet (Phase E).
- Upstream snapshot SHAs for the six forked sibling skills are TODO in `CHANGELOG.md`.

## Layout

```
auto-task-plugin/
├── .claude-plugin/plugin.json         # plugin manifest — VERIFY FIELDS before release
├── skills/
│   ├── auto-task/                      # the orchestrator (SKILL.md + ARCHITECTURE.md)
│   └── {plan,implement,verify,code-review,commit,fix}/  # six bundled sibling skills
├── agents/
│   └── task-execution-verifier.md      # STUB — needs Phase A2 work
├── hooks/
│   ├── block-ai-attribution.sh         # PreToolUse — refuses AI-attribution markers
│   ├── enforce-gates.sh                # PreToolUse — blocks git commit until gates pass
│   └── prevent-mid-protocol-stall.sh   # Stop event — blocks mid-pipeline turn-ends
├── settings-fragment.json              # merge into ~/.claude/settings.json
├── examples/                           # (empty) worked-example transcripts go here
├── README.md                           # install + usage
├── PACKAGING_PLAN.md                   # remaining work + decisions + risks
├── CHANGELOG.md
├── LICENSE                             # MIT
└── CONTEXT.md                          # this file
```

## Key design decisions (locked)

These are the decisions made during extraction. If a reviewer wants to revisit any of them, treat that as a v0.2.0 conversation — not a v0.1.0 blocker.

| Decision | Choice | Why |
|---|---|---|
| Distribution | Claude Code plugin via `.claude-plugin/plugin.json` | Bundles skills + agent + hooks in one install. Marketplace-ready later. |
| Sibling skills | Bundle forked copies | One-step install. Fork drift is a known cost — managed via CHANGELOG snapshot SHAs and a manual resync cadence. |
| `task-execution-verifier` | Author from scratch with a `mode` knob | Was missing entirely on the source machine. Single agent with completeness/adversarial modes keeps Gate A/B aligned. |
| Memory | Strictly read-only. No writes ever from the plugin. | Per-user memory pollution risk is too high. Phase 1 reads `MEMORY.md` for context; Phase 5 surfaces candidate memories for the user to save manually. |
| Read-before-review enforcement | Bundled skills check `.auto-task/<branch>/CONTEXT.md` + `TRACE.md` at start | Self-contained — doesn't require modifying user CLAUDE.md or memory. On-disk discovery is the contract surface. |
| Mid-protocol stall prevention | Stop hook + `expected_next_action` field in STATE.json | The textual NON-YIELDING CONTRACT was being violated. The hook makes it mechanical. Models reliably honor a hook block where they reliably ignore a wall of text. |
| High-risk approval disclaimer | Triggered mechanically by the Risk rubric (HEAVY tier, R ≥ 5, any dimension = 2, or Critique [Rollback] non-empty) | Generic "are you sure?" trains the user to ignore. Specific per-trigger disclaimer changes behavior. |
| `.auto-task/<branch>/` is gitignored | Local history only — never lands on `main` | The user explicitly rejected committing a context artifact to the PR. On-disk per-branch is the alternative. |

## Where the truth lives

- **Behavioral contract:** `skills/auto-task/SKILL.md`. Source of truth for what the skill does and refuses to do.
- **Architecture map:** `skills/auto-task/ARCHITECTURE.md`. Pipeline diagram, phase table, file layout, invariants.
- **Work plan:** `PACKAGING_PLAN.md`. What's done, what's left, in dependency order.
- **User-facing docs:** `README.md`. How to install and use the plugin.
- **Why a decision was made:** this file (`CONTEXT.md`). See the table above.

## What a future Claude session should do here

1. Read this file (CONTEXT.md) first.
2. Read `PACKAGING_PLAN.md` to see remaining work in dependency order.
3. If a `.auto-task/<branch>/` folder exists for the current branch, read its `CONTEXT.md` and `TRACE.md` per the read-before-review contract. Append a TRACE entry on completion.
4. NEVER modify `skills/auto-task/SKILL.md` without also updating `ARCHITECTURE.md` and `PACKAGING_PLAN.md` to match. They are a triangle — drift between them is the most expensive class of bug for a future reader.
5. NEVER add a `Co-Authored-By: Claude` trailer or `🤖 Generated` marker to any commit / PR. The `block-ai-attribution.sh` hook will refuse anyway, but be aware.

## Provenance

Extracted from:
- `~/.claude/skills/auto-task/SKILL.md` (the live development copy)
- `~/.claude/skills/auto-task/ARCHITECTURE.md`
- `~/.claude/skills/auto-task/PACKAGING_PLAN.md`
- `~/.claude/settings.json` (hook scripts)
- `~/.claude/skills/{plan,implement,verify,code-review,commit,fix}/SKILL.md` (sibling-skill forks)

Date of extraction: 2026-05-27. Anything in this repo that diverges from those source paths after that date is a deliberate evolution, not a missed sync — the source paths are not the ongoing source of truth.

## Open questions

(Reproduced from `PACKAGING_PLAN.md` for quick reference — see plan for full context.)

1. **Plugin manifest spec.** Verify field names via Context7 before locking `.claude-plugin/plugin.json`.
2. **Stop-hook return shape.** Verify `{"decision": "block", "reason": "..."}` is the current schema.
3. **Sibling-skill upstream sync.** How often to diff forked skills against upstream and decide what to pull. Recommend pinning upstream SHA in CHANGELOG on each release.
4. **Memory-reading scope.** Which sections of MEMORY.md feed into Phase 1 (clarifying questions / plan-body constraints / recon targeting). Tie-breaker if a memory conflicts with the task description.

## License

MIT. See `LICENSE`.
