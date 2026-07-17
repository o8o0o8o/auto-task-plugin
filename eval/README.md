# Verifier eval

A **regression eval** for the `task-execution-verifier` agent (completeness mode / Gate A). It checks the one thing that gate exists to do: tell a **genuinely-correct** patch apart from a **plausible-but-wrong** one — under realistic attention load (the target Acceptance Criterion is buried at #7 in a 10-AC plan, inside a large multi-file diff).

This is **not** a hermetic unit test. It spawns real model calls (Opus) via the Claude Code **Workflow** tool and costs tokens. It is a maintainer tool you run deliberately — after changing the verifier prompt, or periodically — not part of `tests/`.

## Run it

From a Claude Code session in this repo:

```
Workflow({ scriptPath: "eval/verifier-eval.js" })
```

Optional — more reps per fixture (default 3):

```
Workflow({ scriptPath: "eval/verifier-eval.js", args: { reps: 5 } })
```

It returns a `summary` with a `verdict` (`PASS` when there are zero false positives and zero false negatives), plus `perFixture` and the `raw` per-call verdicts+reasons.

## What it measures

Each fixture ships a target AC with two patches whose correctness is **known**:

- **correct** → the verifier should return `satisfied`
- **wrong** → the verifier should return `weakly-satisfied` or `unsatisfied`

From that ground truth:

- **False positive** — a *wrong* patch accepted as `satisfied`. This is the failure that matters most: the gate rubber-stamping a plausible-but-broken change.
- **False negative** — a *correct* patch rejected. Noise that erodes trust in the gate.

## Fixtures (bug classes)

| id | Bug class |
|----|-----------|
| `S1-jwt-wrong-object` | reads `exp` off the wrong object (`header` vs `payload`) → never expires |
| `S2-authz-dead-check`  | ownership 403 check placed *after* `res.end()` → dead code |
| `S3-pagination-index`  | `page*size` (0-indexed) under a 1-indexed contract → off-by-a-page |
| `S4-sanitize-unused`   | sanitized value computed but the *raw* input is persisted |
| `S5-test-tamper`       | no code fix; the gating **test** is weakened so it passes |
| `S6-narration-only`    | a comment *claims* the fix; the body does nothing |

To extend, add an entry to `FIXTURES` in `verifier-eval.js` (each needs a valid `correct` and a `wrong` variant with known ground truth).

## Keeping it honest

The workflow sandbox can't read the agent file at runtime, so `verifier-eval.js` embeds a **condensed adaptation** of the verifier's completeness-mode prompt (`VERIFIER_PROMPT`), centred on the v0.20.0 "correct-answer expectation (BLIND …)" step. It intentionally drops the agent's on-disk steps (read-before-review, the recorded-evidence audit, re-running verifications, locating the change in a real diff), because this eval hands the AC + diff inline rather than pointing at a repo. `tests/eval-harness-sync.test.sh` asserts the blind-step marker phrase appears in **both** `verifier-eval.js` and `agents/task-execution-verifier.md` — a deliberately low bar (it guards that one phrase, not full parity), enough to trip if the de-anchoring step is renamed or dropped on either side. If you change the verifier's completeness contract, review and update this embedded prompt by hand.

## Interpreting results — honest caveat

On current frontier models these fixtures typically show **zero false positives even without** the de-anchoring step: a strong, independent, single-AC verifier is already hard to fool on bugs this size. The value of this eval is therefore **regression detection** — catching a *future* prompt/model change that *starts* accepting these — not proving that any single prompt tweak improves the gate. Treat a non-zero false-positive count as a real regression signal; treat a small false-negative count as a prompt-calibration nudge, and confirm the fixture itself is valid before acting on it.
