# Troubleshooting

Most of these are hooks working as designed. The general rule: **read the block message — it names exactly which gate is missing — and fix the underlying state rather than the flag.** Never speculatively set a gate flag.

## Hook blocks

### `Blocked by auto-task-plugin: auto-task run in progress`

**Meaning:** the gate-enforcement hook fired because gates haven't passed.

**Fix:** the message names which gate is missing. Re-run the relevant skill and update the flag with real evidence.

---

### `auto-task is mid-pipeline (phase=…)`

**Meaning:** the Stop hook fired because `expected_next_action === "auto-continue"`.

**Fix:** none needed — this is the anti-stall block working as intended. Make the next tool call instead of trying to end the turn.

---

### `this run is over its fix-loop budget`

**Meaning:** the run has iterated more times than its effort tier's cap allows. Not a bug — it's the anti-churn check-in.

The same budget is also checked at **Gate-B entry**, as a spec-level self-check rather than a hook block: a Gate B pass is an `Agent` spawn no hook can observe, so that loop would otherwise never meet the commit-time block at all.

**Fix:** review the per-round findings and decide.

- If returns have diminished — stop and park the rest.
- If continuing is genuinely right — record `gates.loop_budget.acked_through`. The block message prints the exact `jq`, which already steps the budget to the next cap rung above the current count, so **one ack always suffices**.

The count is `max(iteration.fix, iteration.review)`, so **reopening review rounds consume the budget too.**

---

### `auto-task loop budget: loop count N … exceeds …` (at a turn-end)

**Meaning:** the Stop hook released one turn-end so the run could surface its budget check-in. Expected behavior.

**Fix:** surface the per-round finding severities and let the user decide. Further turn-ends at the same loop count block again.

---

### `commit messages and PR bodies must NOT contain "Co-Authored-By: Claude"`

**Meaning:** the AI-attribution hook fired.

**Fix:** rewrite the commit message or PR body without the marker.

---

### `the working-tree diff changed since the last clean code-review pass`

**Meaning:** code was edited after the code-review gate went clean, so the staleness check fired.

**Fix:** re-run the `auto-task-code-review` skill on the current diff, drive it to a clean pass, then refresh `gates.code_review.reviewed_diff_sha`. **Do not bypass.**

---

### `jq is not installed` / `STATE.json is not valid JSON`

**Meaning:** a hook failed closed because it couldn't verify state during an active run.

**Fix:** install `jq`, or repair/remove `.auto-task/<branch>/STATE.json` if no run is active.

## Other symptoms

### `.auto-task/` showing up in `git status` as untracked

**Meaning:** the exclude entry didn't land.

**Fix:** append `.auto-task/` to the worktree-correct exclude file:

```sh
echo '.auto-task/' >> "$(git rev-parse --git-common-dir)/info/exclude"
```

The `--git-common-dir` form matters: in a worktree, `.git` is a file, so the bare `.git/info/exclude` path fails.

---

### A diff-hygiene block you believe is a false positive

The hygiene gate is the one block where **no state edit clears a real finding.** The remedy is to fix the diff — and for a secret, to rotate it.

For a genuine false positive, the only clearance is a `gates.hygiene.acked[]` entry that names the specific check and is **pinned to the current diff hash**, so a grant for one tree can never cover a later one. The block message prints the exact snippet.

The most common genuine false positive is the **rename-blind** one: the scanner is per-file, so a test-file rename or deletion reports `test-integrity`. The block message names that shape explicitly.

See [the commit gate in detail](components.md#the-commit-gate-in-detail).

---

### `claude --resume` didn't put me back in my run

**Meaning:** working as documented — `claude --resume` resumes a *conversation session*, not a run, and each run lives in its own worktree.

**Fix:** use `/auto-task-resume`, the picker that lists every run across your worktrees. See [the run picker](usage.md#the-run-picker-auto-task-resume).

---

### An interrupted release

auto-task never auto-resumes, auto-retries, or auto-reverts a release — deliberately. The next run *surfaces* the state it died in (the version, the step, the current `git log` / `git tag` / `git status`, and the exact undo commands) rather than trying to finish the job.

See [Release at handover](optional-features.md#release-at-handover-release_mode).
