#!/usr/bin/env bash
# Drift guard for the optional release step (`release_mode` + `release_command` +
# the `auto-task-release` skill + Phase 9).
#
# WHY THIS EXISTS. The step is specified in prose across six files, and prose has
# no compiler. Its correctness depends on claims that a later edit can silently
# break: that Phase 9 runs BEFORE `phase: "done"` (or its commit is ungated and
# its run unrecorded), that it re-passes the gates (or it ships un-reviewed
# bytes), that it NEVER pushes or publishes, that `ask` cannot deadlock an
# unattended run, that each degrade path stays distinguishable from the others,
# that a `landing_model: pr` run defers instead of releasing onto a feature
# branch, that a partial failure is never reported as success, and that every
# "there are only N prompts" absolute in the contract was reconciled with the new
# yield. This test pins each of those as a grep.
#
# Pure and hermetic: greps files in the repo, plus one synthetic STATE fixture in
# a temp dir to exercise the run-state hooks. No model, no network, no writes to
# the repo.
# Usage: tests/release-step.test.sh   Exit 0 = in sync.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Spec search is union-scoped: the auto-task spec is a spine
# (skills/auto-task/SKILL.md) plus skills/auto-task/references/*.md. $SKILL below is a
# regenerated temp concatenation of both, so the assertions in this file keep resolving
# wherever their prose lives. See tests/lib/spec.sh for the semantics.
. "$ROOT/tests/lib/spec.sh"
spec_concat_into SKILL
SPINE_ONLY="$ROOT/skills/auto-task/SKILL.md"   # for spine-only assertions

ARCH="$ROOT/skills/auto-task/ARCHITECTURE.md"
REL="$ROOT/skills/auto-task-release/SKILL.md"
SETTINGS="$ROOT/hooks/settings.sh"
INSTALL="$ROOT/install.sh"
README="$ROOT/README.md"

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-56s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-56s got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }
# at_least <label> <actual> <min>
at_least(){ if [ "${2:-0}" -ge "$3" ] 2>/dev/null; then PASS=$((PASS+1)); printf '  PASS  %-56s (%s>=%s)\n' "$1" "$2" "$3"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-56s got=[%s] want>=[%s]\n' "$1" "$2" "$3"; fi; }
has(){ grep -qF "$2" "$1" 2>/dev/null && echo yes || echo no; }

# File-wide extractions, hoisted so no assertion can consume one before it is assigned
# (that bug bit twice in this file: `$enum` and `$p9_region`). Keep new region/segment
# captures HERE, not inline next to their first use — and delete any that stop being
# used, so a stale capture cannot quietly become an empty string feeding an assertion.
# Positional/region assertions must read the file that OWNS the prose, not the union
# concatenation: the section heading stayed in the spine while its body moved to a
# reference, so a first-match anchor on $SKILL would land on the spine summary.
P9REF="$ROOT/skills/auto-task/references/phase-9-release.md"
p9_region="$(cat "$P9REF")"

echo "================ release step ===================="

# --- the new skill exists with the sibling frontmatter convention ------------
expect "auto-task-release skill present"     "$([ -f "$REL" ] && echo yes || echo no)" "yes"
expect "frontmatter: name"                   "$(head -6 "$REL" 2>/dev/null | grep -c '^name: auto-task-release$')" "1"
expect "frontmatter: non-empty description"  "$(head -6 "$REL" 2>/dev/null | grep -cE '^description: .+')"         "1"
expect "caller note present (do not strip)"  "$(has "$REL" 'Caller note (do not strip)')"                          "yes"
expect "read-before-review contract"         "$(has "$REL" 'Read-before-review contract')"                          "yes"

# --- the two-mode contract ---------------------------------------------------
# Anchored to the mode table's rows, not to bare word presence: an earlier draft
# of this guard counted occurrences of "apply" anywhere in the file, which any
# prose ("applies", "applying") satisfies while the table itself could be gone.
mode_rows="$(awk '/^\| Mode \| What you do/,/^### 1\./' "$REL" | grep -c '^| \*\*`')"
expect "mode table: exactly 2 rows"          "$mode_rows"                                                           "2"
expect "mode row: report-only"               "$(awk '/^\| Mode \| What you do/,/^### 1\./' "$REL" | grep -c '^| \*\*`report-only`\*\* |')" "1"
expect "mode row: apply"                     "$(awk '/^\| Mode \| What you do/,/^### 1\./' "$REL" | grep -c '^| \*\*`apply`\*\* |')"       "1"
expect "report-only is the safe default"     "$(has "$REL" 'assume **`report-only`**')"                             "yes"
expect "apply is idempotent (resume)"        "$(has "$REL" 'idempotent')"                                           "yes"
expect "approved plan is a ceiling"          "$(has "$REL" 'ceiling, not a starting point')"                        "yes"

# --- bump derivation: derived, THEN confirmed — never silently applied -------
expect "bump: derived-then-confirmed anchor" "$(has "$REL" 'derived-then-confirmed')"                               "yes"
expect "bump: proposal not applied silently" "$(has "$REL" 'treat it as a *proposal*')"                             "yes"
expect "bump: signal recorded with level"    "$(has "$REL" 'never present a bump without the evidence behind it')"  "yes"
expect "bump: major signal"                  "$(has "$REL" 'BREAKING CHANGE:')"                                     "yes"
expect "bump: pre-1.0 caveat"                "$(has "$REL" 'Pre-1.0 caveat')"                                       "yes"
expect "orchestrator surfaces bump + signal" "$(has "$SKILL" 'the derived bump AND the signal that decided it')"    "yes"

# --- never push / never publish, and the boundary scoped HONESTLY -----------
# The honesty clause matters: a delegated release_command CAN push or publish and
# no guard sees inside it, so the contract must say whose authority that is and
# require the report-only pass to surface it. Claiming an absolute the design
# cannot deliver would be worse than the gap.
expect "boundary: skill states never pushes" "$(has "$REL" 'never pushes')"                                         "yes"
expect "boundary: skill states never publishes" "$(has "$REL" 'never publishes')"                                   "yes"
expect "boundary: phase 9 states never push" "$(has "$SKILL" '**Never push and never publish**')"                   "yes"
expect "boundary: scoped to own actions"     "$(has "$REL" "binds auto-task's own actions")"                        "yes"
expect "boundary: report surfaces command"   "$(has "$REL" 'surface what that command will do')"                    "yes"
expect "boundary: orchestrator repeats it"   "$(has "$SKILL" 'surface what that command will do')"                   "yes"
expect "boundary: push cmd handed over"      "$(has "$REL" 'git push origin HEAD')"                                 "yes"
# The out-of-scope table must keep naming publish verbs as NON-targets.
for nt in 'git push' 'npm'; do
  at_least "boundary: non-target row: ${nt}"  "$(grep -c "^| \`\?${nt}" "$REL")"                                    1
done

# --- ordering: Phase 9 is the LAST phase, before `done` ---------------------
expect "ordering: phase 9 section exists"    "$(grep -c '^### Phase 9 — Release' "$SKILL")"                          "1"
expect "ordering: entry sets phase=release"  "$(grep -c '^\*\*On entry, set `phase: "release"`\*\*' "$SKILL")"        "1"
expect "ordering: phase enum has release"    "$(has "$SKILL" 'external|release|done')"                               "yes"
expect "ordering: release owns the done write" "$(has "$SKILL" 'it is the **last writer of `phase: "done"`**')"       "yes"
expect "ordering: runs before done, not after" "$(has "$SKILL" 'after `done` the gate hook exits 0')"                "yes"
# Gate A follow-up #2: `**Else release applicable**` is a prefix shared by the
# Phase-5 fork AND the Phase-6 fork, so this pin matched either one — the Phase-6
# site has its own more specific pin below, leaving the Phase-5 site effectively
# unpinned. Anchored on the Phase-5-only parenthetical instead.
expect "ordering: phase-5 routes to release" \
  "$(has "$SKILL" '**Else release applicable** (no bot-review, no preview, no external actions')"                      "yes"
expect "ordering: phase-8 routes to release"  "$(has "$SKILL" 'the release step is applicable? → set `phase: "release"`')" "yes"
# The named guard is the mechanism that stops an EARLIER phase writing `done`
# while a configured release still owes work. It must be referenced at more than
# the one site that defines it, or it only guards the branch already complying.
# Gate A: the Phase-7 -> Phase-9 route is the exit most runs WITH a preview take,
# and it had no dedicated pin — a future edit could delete it silently.
expect "ordering: phase-7 routes to release"  "$(has "$SKILL" 'a `release_mode` of `always`/`ask` routes to `phase: "release"` (Phase 9) instead of `done`')" "yes"
expect "ordering: phase-6 routes to release"  "$(has "$SKILL" '**Else release applicable** (`release_mode` is `always`/`ask`)')" "yes"
# Gate A: "no phase writes done ahead of release" had no literal pin. The guard's
# own enumeration IS that claim, so pin the enumeration listing every done-writer.
expect "ordering: no phase writes done ahead of release" \
  "$(has "$SKILL" "Before writing \`phase: \"done\"\` from ANY phase (Phase 5 step 12, Phase 6 step 6, Phase 7 step 1.4 / step 3's FAIL bullet / step 4, Phase 8 step 6)")" "yes"
expect "ordering: release terminal guard defined" "$(has "$SKILL" '**Release terminal guard —')"                     "yes"
at_least "ordering: guard referenced at >=4 sites" "$(grep -c 'release terminal guard' "$SKILL")"                    4
expect "ordering: guard is a no-op on skip"   "$(has "$SKILL" 'this guard is a no-op')"                              "yes"

# --- the yield point + the reconciled absolutes -----------------------------
at_least "yield: phase 9 rows in the table"   "$(grep -c '^| Phase 9 ' "$SKILL")"                                    3
expect "yield: release ask row is user-approval" "$(grep -c '^| Phase 9 release ask (step 4 .*| `"user-approval"` |$' "$SKILL")" "1"
expect "yield: release ask in user-approval semantics" "$(has "$SKILL" 'The Phase-9 release ask, when `release_mode` is `ask`')" "yes"
expect "yield: ask only when something to release" "$(has "$SKILL" 'AND there is actually something to release')"     "yes"
expect "yield: degrades under autonomous/headless" "$(has "$SKILL" 'release_mode=ask degraded to always')"            "yes"
# The contract's own absolutes had to be reconciled: a bare "only ONE prompt" or
# "at most 2 prompts" claim is now false.
# Gate A caught the original form of this assertion as VACUOUS: it pinned
# `and only that one prompt`, a string that never existed at the base commit, so it
# was true regardless of any regression. Replaced with the real invariant: an
# absolute claiming a maximum number of prompts must stay explicitly Phase-5-scoped,
# because Phase 9 adds a prompt OUTSIDE Phase 5. An unscoped claim would be false
# and would lead a model to skip the release ask.
# Gate A follow-up #1: the scoping test was enforced per LINE, so an ADDED unscoped
# claim was caught but an IN-PLACE de-scoping was not — appending an unscoped
# prompt-max sentence to an existing long line that mentions Phase 5 *elsewhere*
# left the whole line matching `Phase.?5` and slipped through. These files are
# written in very long paragraph-lines, so that is the likely shape of the
# regression, not the unlikely one. Now sentence-scoped: each line is split into
# sentences, and every SENTENCE carrying a prompt-max claim must itself be
# Phase-5-scoped. Same fail-closed contract; finer granularity.
promptmax_lines="$(grep -nE 'exactly two|at most 2|at-most-two|only the two' "$SKILL" "$ARCH" \
  | grep -iE 'prompt|interaction surface' || true)"
expect "absolutes: prompt-max claims exist to check" \
  "$([ "$(printf '%s' "$promptmax_lines" | grep -c .)" -ge 2 ] && echo ok || echo no)" "ok"
# Split every matched line into sentences, keep only the sentences that actually
# carry a prompt-max claim, then require each of those to name Phase 5.
unscoped="$(printf '%s\n' "$promptmax_lines" \
  | perl -ne 'chomp; ($loc,$rest)=/^([^:]*:\d+):(.*)$/ or next;
              for my $s (split /(?<=[.!?])\s+/, $rest) {
                next unless $s =~ /exactly two|at most 2|at-most-two|only the two/;
                next unless $s =~ /prompt|interaction surface/i;
                print "$loc: $s\n" unless $s =~ /Phase.?5/;
              }' || true)"
expect "absolutes: every prompt-max claim is Phase-5-scoped (sentence-scoped)" \
  "$(printf '%s' "$unscoped" | grep -c .)" "0"
[ -n "$unscoped" ] && printf '        offending sentence(s):\n%s\n' "$unscoped"
expect "absolutes: release ask named in contract" "$(has "$SKILL" 'and in Phase 9 the release ask')"                  "yes"
expect "absolutes: two report-only exceptions"  "$(has "$SKILL" 'There are two further exceptions, and only these two')" "yes"
expect "absolutes: post-PR range is 6-9"        "$(has "$SKILL" 'The post-PR surfaces of Phases 6-9')"                "yes"
expect "absolutes: arch non-yielding updated"   "$(has "$ARCH" 'the Phase 9 release ask')"                            "yes"

# --- R10: the "how many authored commits" absolutes Phase 9 falsifies -------
# Gate A found all four of these still claiming TWO exceptions while Exception 3
# exists — and the single-commit rule is the invariant the gate hook backs, so a
# spec that contradicts itself here is worse than ordinary prose drift.
expect "absolutes: operating principle names 3 extra commits" \
  "$(has "$SKILL" 'two opt-in authored commits — Phase-6 bot-fix commits (when `bot_review_autofix` is on) and the Phase-9 release commit')" "yes"
expect "absolutes: phase 6 is not 'the single exception'" \
  "$(grep -c 'the single exception to "only Phase 5 commits"' "$SKILL")"                                              "0"
expect "absolutes: phase 6 names the other exception" \
  "$(has "$SKILL" 'one of the two opt-in exceptions to "only Phase 5 commits"')"                                      "yes"
expect "absolutes: arch names phase 6 AND phase 9" \
  "$(has "$ARCH" 'the opt-in Phase 6 (bot-fixes) and Phase 9 (release) may add further authored commits')"             "yes"
expect "absolutes: readme no longer calls phase 8 last" \
  "$(grep -c '\*\*Applied + verified in Phase 8\*\* (the last phase' "$README")"                                      "0"
expect "absolutes: readme names phase 9 as last"  "$(has "$README" 'Phase 9, the opt-in release step, is the last phase')" "yes"

# --- the re-gate mandate (this is what makes the commit legal) --------------
expect "re-gate: single-commit Exception 3"    "$(has "$SKILL" 'Exception 3 — the Phase 9 release commit')"           "yes"
expect "re-gate: re-runs auto-task-verify"     "$(has "$SKILL" 'Re-run `/auto-task-verify` (current tier scope), re-invoke the **`auto-task-code-review`** skill on the new diff')" "yes"
expect "re-gate: refreshes reviewed_diff_sha"  "$(grep -cF "refresh \`gates.code_review.reviewed_diff_sha\` (Phase 4's pinned-flags formula) and \`clean_pass_after_last_fix\`" "$SKILL")"  "2"
expect "re-gate: gate B reset on STD/HEAVY"    "$(has "$SKILL" 'On **STANDARD/HEAVY** also set `gates.gate_b.passed = false`')" "yes"
expect "re-gate: interrupt marker before flags" "$(has "$SKILL" 'result: "in-progress", step: "re-gate", version, plan, files: [...], at }` BEFORE clearing any gate flag')" "yes"
# GB#3: every refresh must carry plan+version forward, or a step-6 interrupt surfaces
# without the version its own undo command is parameterised on.
expect "marker: continuity rule stated"        "$(has "$SKILL" '**Marker-continuity rule (REQUIRED): every later `in-progress` refresh (steps 6 and 8) MUST carry `version` and `plan` forward unchanged.**')" "yes"
expect "marker: refreshes append, not update"  "$(printf '%s' "$p9_region" | grep -c 'Append a refreshed in-flight marker')"  "2"
expect "marker: no stale 'Update the in-flight marker'" "$(printf '%s' "$p9_region" | grep -c 'Update the in-flight marker')" "0"
expect "marker: reader never walks back past newest" \
  "$(has "$SKILL" 'nothing should require a reader to walk backwards past the newest entry')"                            "yes"
expect "re-gate: no hook change required"      "$(has "$SKILL" 'No hook change is required or permitted')"            "yes"
# Gate A note: narrowing the docs guard's counters to a Phase-5 region left Phase
# 9's own interrupt markers guarded only by presence. Pin their counts in the
# Phase-9 region, the same discipline the docs guard uses for step 1b.
expect "re-gate: p9 apply sites"               "$(printf '%s' "$p9_region" | grep -o 'in \*\*`apply`\*\* mode' | grep -c .)" "3"
# Structural pins, not a raw count — same reason as the re-gating pins below: the marker
# is legitimately *referenced* in the lead-in enumeration and the fall-through note, so an
# occurrence count drifts on correct prose. Pin the branch and the write instead.
# Pin the two STRUCTURAL re-gating sites (the resume-guard branch and the marker
# write) rather than a raw occurrence count — prose that merely *references* the
# marker to explain why it matters would otherwise perturb a count assertion.
# A clean gate refresh must not eat the fix-loop budget.
expect "re-gate: clean pass spends no budget"  "$(has "$SKILL" 'does **not** increment `iteration.review`')"           "yes"
# And no hook file may actually have been touched to enable any of this.
# Use the SAME targeted predicate as the per-hook sweep below, not a bare `release`
# grep: the loose form fails spuriously the moment any comment says "released".
expect "re-gate: enforce-gates.sh unaware of release" \
  "$(grep -cE 'release_mode|phase.*"release"' "$ROOT/hooks/enforce-gates.sh")"                                         "0"

# --- WHO COMMITS: the contract the code review found contradictory -----------
# The skill's `apply` used to end in commit+tag while the orchestrator ALSO specified
# the commit two steps later, after the re-gate. Following the skill committed before
# `reviewed_diff_sha` was refreshed, which `enforce-gates.sh` hard-blocks — a deadlocked
# release with a bump on disk. These pin the resolution from both sides.
expect "commit: skill defers commit+tag under orchestration" \
  "$(has "$REL" 'Who commits — the one thing to get right')"                                                            "yes"
expect "commit: skill stops after substep 4.3"  "$(has "$REL" 'STOP after 4.3 and return')"                             "yes"
expect "commit: skill rule bans committing under orchestration" \
  "$(has "$REL" 'Under orchestration, never commit and never tag — the caller owns git state')"                         "yes"
expect "commit: ambiguity defaults to not committing" \
  "$(has "$REL" 'assume **orchestration** and stop after 4.3')"                                                         "yes"
expect "commit: orchestrator states apply does not commit" \
  "$(has "$SKILL" 'What `apply` does here — it does NOT commit')"                                                       "yes"
expect "commit: orchestrator owns commit at step 8" \
  "$(has "$SKILL" 'THIS phase does both, now that the gates are refreshed')"                                            "yes"
expect "commit: goes through auto-task-commit"  "$(has "$SKILL" 'commit via the **`auto-task-commit`** skill with the message exactly `chore(release): vX.Y.Z`')" "yes"
# Ordering, structurally: the re-gate step must precede the commit step in the file.
p9_regate_ln="$(printf '%s' "$p9_region" | grep -n '^6\. \*\*Re-pass the gates' | cut -d: -f1)"
p9_commit_ln="$(printf '%s' "$p9_region" | grep -n '^8\. \*\*Commit, tag, and verify' | cut -d: -f1)"
expect "commit: re-gate precedes the commit step" \
  "$([ -n "$p9_regate_ln" ] && [ -n "$p9_commit_ln" ] && [ "$p9_regate_ln" -lt "$p9_commit_ln" ] && echo yes || echo no)" "yes"

# --- RESUME: surfacing, not auto-resume (the descoped contract) ---------------
# The user descoped the crash-safe resume/terminal state machine after Gate B found
# repeated defects in it (2 blockers + 4 required on its second pass, on top of 13
# Blocker/Required from nine review passes). Phase 9 now SURFACES an interrupted
# release instead of resuming it. These pin the replacement contract, whose whole
# value is the invariant it keeps: an interrupted release never silently re-cuts and
# never reports success.
expect "resume: surfacing is the stated choice" \
  "$(has "$SKILL" 'Interruption is handled by SURFACING, not by auto-resume')"                                          "yes"
expect "resume: names the preserved invariant" \
  "$(has "$SKILL" 'an interrupted release never silently re-cuts and never reports success')"                            "yes"
expect "resume: in-progress branch surfaces"   "$(has "$SKILL" 'STOP and hand it over')"                                "yes"
expect "resume: refuses to guess from the tree" \
  "$(has "$SKILL" 'Do not infer which from the tree, and do not re-invoke `auto-task-release`')"                         "yes"
expect "resume: does not continue in the same turn" \
  "$(has "$SKILL" 'Do not continue to step 2 in the same turn')"                                                        "yes"
expect "resume: surfaces the recorded plan, not a re-derivation" \
  "$(has "$SKILL" 'surfaces this payload rather than re-deriving it')"                                                   "yes"
expect "resume: applied/declined are not re-derived" \
  "$(has "$SKILL" '**`applied` or `declined` — genuinely finished')"                                                      "yes"
# GB#2: the non-cut terminals MUST fall through for a live re-read, or a user who fixes
# the setting and resumes silently never gets a release.
expect "resume: non-cut terminals get a live re-read" \
  "$(has "$SKILL" 'fall through to step 2 for a LIVE re-read')"                                                          "yes"
expect "resume: names the stale-marker hazard"  "$(has "$SKILL" 'would re-introduce exactly the cross-session staleness step 2 is hardened against')" "yes"
expect "resume: re-derive is safe because nothing was cut" \
  "$(has "$SKILL" 'Re-deriving here is safe *because* nothing was cut')"                                                  "yes"
# No auto-resume, no auto-retry, no auto-revert — the three things the descope removed.
expect "resume: no auto-resume/retry/revert (yield table)" \
  "$(has "$SKILL" 'Phase 9 never auto-resumes, auto-retries or auto-reverts')"                                          "yes"
expect "resume: no auto-resume/retry/revert (state prose)" \
  "$(has "$SKILL" '**None of the three is auto-resumed, auto-retried, or auto-reverted**')"                              "yes"
expect "resume: unwind is handed over, never run" \
  "$(has "$SKILL" '**Auto-task never runs these itself**')"                                                             "yes"
expect "resume: interrupted unwind needs no recovery" \
  "$(has "$SKILL" 'an interrupted unwind is not a state this phase has to recover from')"                                "yes"

# --- GATE B (descoped design): every surfaced state can return to terminal ----
# GB#1 (blocker): `in-progress` had no route to any terminal status, so a resolved
# release stayed surfaced forever — permanently non-terminal, invisible to
# record-outcome.sh, stalled in auto-task-stats. All three surfaced states now share
# ONE resolution rule.
expect "resolve: one rule shared by all surfaced states" \
  "$(has "$SKILL" 'All three surfaced states share ONE resolution rule')"                                               "yes"
expect "resolve: names the permanently-non-terminal hazard" \
  "$(has "$SKILL" 'would make the run permanently non-terminal')"                                                        "yes"
expect "resolve: rule has a heading of its own" \
  "$(has "$SKILL" '**Resolution rule (how ANY surfaced state returns to terminal).**')"                                  "yes"
# The three honest outcomes — and the third is the one the old vocabulary lacked (GB#4).
expect "resolve: outcome complete pins identity" \
  "$(has "$SKILL" '**The release is complete — and it is the release that was planned.**')"                               "yes"
expect "resolve: verifies the tag points at the commit" \
  "$(has "$SKILL" 'git rev-parse "vX.Y.Z^{commit}"')"                                                                    "yes"
expect "resolve: a different version is not recorded as the plan" \
  "$(has "$SKILL" 'If the user released a DIFFERENT version than the plan')"                                              "yes"
expect "resolve: unrelated work in the commit is surfaced" \
  "$(has "$SKILL" 'if the commit sweeps in unrelated work, say so')"                                                      "yes"
expect "resolve: outcome undone -> nothing-to-release" "$(has "$SKILL" '**It was undone, and the user does not want it re-cut**')" "yes"
expect "resolve: outcome still-warranted -> re-enter step 2" \
  "$(has "$SKILL" '**Nothing was cut and the release is still warranted**')"                                             "yes"
expect "resolve: still-warranted is not forced into a false terminal" \
  "$(has "$SKILL" 'Do NOT force this case into `applied` or `nothing-to-release`')"                                      "yes"
# The user is not taken at their word — the state is verified.
expect "resolve: verifies rather than trusting the report" \
  "$(has "$SKILL" 'do not take their word for the outcome')"                                                            "yes"
expect "resolve: never records an unverified terminal" \
  "$(has "$SKILL" 'Never record a terminal status you did not verify')"                                                  "yes"

# GB#2 (required): the resolution path could record `applied` with the gates left
# cleared by a step-6 failure, implying gate coverage for a commit auto-task never
# gated. It must record the honesty note and must NOT flip a flag it did not earn.
expect "resolve: user commit is outside gate coverage" \
  "$(has "$SKILL" 'outside auto-task and is therefore outside its gate coverage')"                                       "yes"
expect "resolve: does not restore unearned gate flags" \
  "$(has "$SKILL" 'Do NOT restore or set any gate flag you did not earn')"                                              "yes"
expect "resolve: invariant restated precisely" \
  "$(has "$SKILL" 'every authored commit **auto-task makes** is individually gate-reviewed')"                            "yes"

# GB#3 (required): step 1 had no else-branch, so an out-of-enum result fell through
# to step 2 and re-cut the release. Now it fails safe by surfacing.
expect "reentry: unrecognized result is surfaced, not fall-through" \
  "$(has "$SKILL" 'an unrecognized `result` — is SURFACED, never a fall-through (fail safe)')"                            "yes"
expect "reentry: names where such values come from" \
  "$(has "$SKILL" 'can only come from a different plugin build')"                                                        "yes"
expect "reentry: a stale step name is surfaced too" \
  "$(has "$SKILL" 'names a stage this version of the phase no longer has')"                                              "yes"
# GB#4b: no transcript may be fabricated on the resolution path.
expect "resolve: no transcript fabricated on resolution" \
  "$(has "$SKILL" 'the command ran in a dead session, so this one has no transcript')"                                    "yes"
expect "resolve: and saves nothing rather than inventing one" \
  "$(has "$SKILL" 'In all four cases say so and save nothing')"                                                               "yes"
# GB#6: both docs describe the fail-safe trigger, not the narrower `landing_model: pr`.
expect "docs: arch node states the fail-safe trigger" \
  "$(has "$ARCH" 'landing is not an explicit direct')"                                                                   "yes"
expect "docs: no stale landing_model=pr edge label" "$(grep -c 'landing_model = pr' "$ARCH")"                            "0"
expect "docs: readme states the fail-safe trigger" \
  "$(has "$README" 'Anything but an explicit `direct` landing defers instead of releasing')"                              "yes"

# --- the single in-progress marker precedes EVERY mutating action -------------
# One marker replaced four (applying / applied-pending-authorization / re-gating /
# committing), which is what collapsed the enumeration-drift defect class: there is
# no per-marker routing table left to fall out of sync. But the marker must still
# precede each mutation, or step 1 cannot see that anything was attempted.
for st in apply re-gate commit-tag; do
  expect "marker: in-progress before '${st}'" \
    "$(printf '%s' "$p9_region" | grep -cF "result: \"in-progress\", step: \"${st}\"")"                                  "1"
done
expect "marker: apply marker carries the approved plan" \
  "$(has "$SKILL" 'the only durable copy of what the user approved')"                                                    "yes"
expect "marker: precedes the apply call"       "$(has "$SKILL" 'The marker must precede the call')"                     "yes"
expect "marker: precedes clearing a gate flag" \
  "$(has "$SKILL" 'BEFORE clearing any gate flag')"                                                                     "yes"
expect "marker: precedes staging"              "$(has "$SKILL" 'BEFORE staging anything')"                              "yes"
# The four old markers must be gone from Phase 9 (the docs step keeps its own).
for old in applied-pending-authorization re-gating committing; do
  expect "marker: old '${old}' retired from phase 9" \
    "$(printf '%s' "$p9_region" | grep -c "result: \"${old}\"")"                                                         "0"
done
expect "marker: descoped not a live status"     "$(printf '%s' "$p9_region" | grep -c 'status: "descoped"')"             "0"
# It IS named once, in the fail-safe bullet, as a legacy value from a different build —
# that reference is the point (it tells a reader where such a value comes from).
expect "marker: descoped named only as legacy"  "$(printf '%s' "$p9_region" | grep -c 'pre-descope `applying`')"          "1"

# --- CLOSURE: every status is either terminal or surfaced, nothing else -------
# The vocabulary is now closed by a two-way split rather than by three hand-kept
# enumerations, so this check is correspondingly simpler — and still derives BOTH
# sides from the file. FAIL CLOSED: any extraction failure prints a sentinel, so a
# drifted anchor cannot silently switch the check off.
closure_gaps="$(python3 - "$SKILL" "$P9REF" <<'PYCLOSURE'
import io,re,sys
try:
    s=io.open(sys.argv[1],encoding='utf-8').read()
    # The Phase-9 HEADING stays in the always-loaded spine while its body lives in
    # references/phase-9-release.md, so slicing the union between the heading and the
    # next spine heading would capture only the spine summary. Read the owning
    # reference instead; the status enum still comes from the state schema in `s`.
    p9=io.open(sys.argv[2],encoding='utf-8').read()
    m=re.search(r'"status": "(skipped-disabled\|skipped-invalid-value[^"]*)"', s)
    if not m:
        print('EXTRACTION-FAILED: release status enum not found'); raise SystemExit(0)
    enum=[v for v in m.group(1).split('|') if v]
    if len(enum) < 5:
        print('EXTRACTION-FAILED: enum parsed empty'); raise SystemExit(0)
    # step 9 two closing categories are the authority on which is which
    # (an apostrophe here would break the enclosing $( ) — bash tracks quotes
    #  through a quoted heredoc while scanning for the closing paren)
    tail=p9[p9.index('**terminal statuses**'):]
    term=tail[:tail.index('**Transitional status**')]
    rest=tail[tail.index('**Transitional status**'):]
    trans=rest[:rest.index('**Surfaced statuses**')]
    # Bound the surfaced slice to the END OF ITS OWN PARAGRAPH. Unbounded it ran to
    # the end of the Phase-9 region, swallowing the trailing `**Release step off?**`
    # paragraph — which names `skipped-disabled`. Today the `both` arm still cannot
    # fire on that (the terminal side matches the skipped family by the `any
    # `skipped-*`` wildcard, not by literal name), but a future status added to the
    # trailing paragraph WOULD be silently read as surfaced. Bounding it keeps the
    # check honest by construction rather than by that coincidence.
    _s=rest.index('**Surfaced statuses**')
    _e=rest.find('\n\n', _s)
    surf=rest[_s:_e if _e != -1 else len(rest)]
    gaps=[v for v in enum
          if f'`{v}`' not in term and f'`{v}`' not in surf and f'`{v}`' not in trans
          and not (v.startswith('skipped-') and 'any `skipped-*`' in term)]
    both=[v for v in enum
          if sum(1 for seg in (term,trans,surf) if f'`{v}`' in seg) > 1]
    print(' '.join(['UNCATEGORIZED:'+g for g in gaps]+['BOTH:'+b for b in both]))
except SystemExit:
    raise
except Exception as e:
    print(f'EXTRACTION-FAILED: {type(e).__name__} — an anchor this check indexes on has drifted')
PYCLOSURE
)"
expect "closure: every status is terminal xor transitional xor surfaced"  "${closure_gaps:-none}"                        "none"
expect "closure: the transitional carve-out is named" \
  "$(has "$SKILL" 'with exactly one **transitional** exception')"                                                        "yes"
expect "closure: transitional should not reach step 9" \
  "$(has "$SKILL" '`resolved-re-derive` should never reach step 9')"                                                      "yes"
# GB#4: it CAN be observed at rest (across the ask prompt), so the contract says so
# rather than promising a transience it does not have.
expect "closure: transience claim is honest"   "$(has "$SKILL" 'It **can be observed at rest**')"                        "yes"
expect "closure: guarantee is consumed-on-next-read" \
  "$(has "$SKILL" 'consumed on the next step-1 read*, not *overwritten on the same pass*')"                               "yes"
expect "closure: resting at the ask prompt is not a bug" \
  "$(has "$SKILL" 'that is expected, not a bug')"                                                                        "yes"
expect "closure: the split is stated"          \
  "$(has "$SKILL" 'either **terminal** (step 9 writes `done`) or **surfaced** (step 1 hands it to the user)')"            "yes"
expect "closure: no value can rest without finishing or handing over" \
  "$(has "$SKILL" 'no value can sit in the state file without either finishing the run or handing it to the user')"       "yes"
expect "closure: surfaced set is exactly the three" \
  "$(has "$SKILL" '`in-progress` / `partial-failure` / `failed` → stay `phase: "release"`')"                             "yes"

# --- FOLLOW-UPS from the optional-release-step run ----------------------------
# Each assertion below pins one parked follow-up. Two of them (marker wording,
# declined producers) were already closed incidentally by later fixes in that run;
# they are pinned here so they cannot silently reopen.

# #20: the append-only history means these refresh sites APPEND, never update.
expect "marker: refresh sites say append, not update" \
  "$(grep -c 'Append a refreshed in-flight marker' "$SKILL")"                                                          "2"
expect "marker: no update-the-marker wording survives" \
  "$(grep -c 'Update the in-flight marker' "$SKILL")"                                                                  "0"

# #26: `declined` has two producers that differ on whether anything ever ran.
expect "declined: record is producer-aware" \
  "$(has "$SKILL" 'which producer it came from decides what to record')"                                               "yes"

# #12: the release command runs at apply substep 4.2, NOT at the commit step.
p9_step8="$(sed -n '/^   - \*\*`failed`\*\* (a blocker such as a pre-existing tag/p' "$SKILL")"
expect "attribution: step-8 failed is not where a command failure is raised" \
  "$(printf '%s' "$p9_step8" | grep -c 'substep 4.2')"                                                                 "1"

# resolution rule outcome 3 is the only one that does not route to step 9.
expect "resolution: outcome 3 sets the yield field" \
  "$(has "$SKILL" 'Set `expected_next_action: "auto-continue"` on this outcome (REQUIRED).')"                          "yes"

# an accepted partial-failure must be visible to step 1, which reads history.
expect "accepted partial: discriminator is defined" \
  "$(has "$SKILL" 'result: "accepted-partial-failure"')"                                                               "yes"
expect "accepted partial: terminal pair is explicit" \
  "$(has "$SKILL" 'This exception writes `phase: "done"` AND `expected_next_action: null`')"                           "yes"
expect "accepted partial: step 9 names its discriminator" \
  "$(has "$SKILL" 'Read the acceptance from the newest `release` entry in `state.history`')"                            "yes"
expect "accepted partial: protected set says three, not two" \
  "$(has "$SKILL" 'They are two of the three protected values')"                                                       "yes"
expect "accepted partial: no stale only-two claim" \
  "$(grep -c 'These are the only two terminal values that must NOT be re-derived' "$SKILL")"                           "0"
expect "accepted partial: step 1 recognizes it" \
  "$(has "$SKILL" '**`accepted-partial-failure` — the user was shown a half-cut release')"                             "yes"

# Phase-4 review: the history-only value needs an explicit carve-out from the
# status-write rule, or it silently contradicts the closed-enum MUST.
expect "record: mirror clause keeps its own parenthetical" \
  "$(has "$SKILL" 'per the status-write rule above** (so a completed release logs `result: "applied"`)')"              "yes"
expect "record: TRACE entry is written on every path" \
  "$(has "$SKILL" '(The TRACE entry above is still written, on every path.)')"                                         "yes"
expect "accepted partial: carve-out from the status-write rule" \
  "$(has "$SKILL" 'One carve-out, and only one: `accepted-partial-failure`')"                                          "yes"
expect "accepted partial: is history-only, never a status" \
  "$(has "$SKILL" 'is therefore a **history-only** value')"                                                            "yes"
expect "accepted partial: stays out of the status enum" \
  "$(rel_enum="$(grep -m1 '"status": "skipped-disabled|skipped-invalid-value' "$SKILL")"; \
      if [ -z "$rel_enum" ]; then echo "ANCHOR-DRIFTED"; \
      else printf '%s' "$rel_enum" | grep -c 'accepted-partial-failure'; fi)"                                          "0"

# GB5#3: the release object is written ONLY by Phase 9.
expect "phase-5 else fork does not write the release object" \
  "$(has "$SKILL" 'Leave `release` as `null` here — do NOT write `skipped-disabled`')"                                 "yes"


# GB7#1/#2/#3: step-8 push-detection precision.
expect "push probe: absent vs unreachable is named" \
  "$(has "$SKILL" 'absent from the remote and an unreachable remote are indistinguishable')"                            "yes"
expect "push probe: unwind claim is qualified" \
  "$(has "$SKILL" 'pushes the commit without the tag')"                                                                "yes"
expect "push probe: applied states its precondition" \
  "$(has "$SKILL" 'only when the commit AND the tag both exist')"                                                      "yes"

# GB7#4: three no-transcript producers, not two.
expect "transcript: count is four" \
  "$(has "$SKILL" 'ALL FOUR of these statuses can be recorded with no transcript in *this* session')"                      "yes"
expect "transcript: stale three-count is gone" \
  "$(grep -c 'three of these statuses can be reached' "$SKILL")"                                                       "0"
expect "transcript: names the resolution-path partial-failure route" \
  "$(has "$SKILL" 'recorded on that same resolution path (outcome 4, the *accepted* half-cut release)')"               "yes"
expect "transcript: stale two-count is gone" \
  "$(grep -c 'two of these statuses can be reached without the command having run' "$SKILL")"                          "0"

# GB7#5: the amendment path must act on a corrected-report blocker.
expect "amendment: acts on a corrected-report blocker" \
  "$(has "$SKILL" 'act on its Blockers line exactly as step 3 does')"                                                  "yes"

# GB5#6b: the flowchart routes report-only/apply blockers from P9Run, not P9Cut.
expect "flowchart: P9Run has a surfaced edge" \
  "$(grep -cE '^\s*P9Run -\.' "$ARCH")"                                                                                "1"
expect "flowchart: P9Gate has a surfaced edge" \
  "$(grep -cE '^\s*P9Gate -\.' "$ARCH")"                                                                               "1"
# GB5: a substep-4.2 command failure belongs to the APPLY call, not to the
# report-only node — the same misattribution R3 removed from the prose.
expect "flowchart: apply is its own node" \
  "$(grep -cE 'P9Apply\[skill: auto-task-release' "$ARCH")"                                                              "1"
expect "flowchart: substep 4.2 hangs off apply, not report-only" \
  "$(grep -cE '^\s*P9Apply -\.' "$ARCH")"                                                                              "1"
expect "flowchart: report-only edge no longer claims substep 4.2" \
  "$(grep -E '^\s*P9Run -\.' "$ARCH" | grep -c 'substep 4.2')"                                                         "0"

# --- GATE B pass 5: the two Required (honesty/reporting axis) -----------------
# GB5#1: nothing in the phase read what `apply` RETURNED. A legitimately failing
# release_command (this repo's own generator refuses to write when the version has no
# changelog entry) would fall straight through to step 5, burn a full re-gate on a tree
# whose bump never happened, and reach step 8 indistinguishable from success. The enum
# defined `failed` for exactly this and no step produced it.
expect "applyret: reads what apply returned"   "$(has "$SKILL" 'Read what `apply` RETURNED before going anywhere near step 5')" "yes"
expect "applyret: stops rather than re-gating"  "$(has "$SKILL" 'Do NOT continue to step 5')"                            "yes"
expect "applyret: names the wasted re-gate"     "$(has "$SKILL" 'a version that was never bumped')"                      "yes"
expect "applyret: hands over the partial-write undo" \
  "$(has "$SKILL" 'The tree may hold a partial write the command made before failing')"                                   "yes"
expect "applyret: step 9 routes a step-4 failure" \
  "$(has "$SKILL" 'a `failed` raised at step 4, 6 or 8')"                                                                "yes"
# GB5#2: the "what the command will do" disclosure was delivered ONLY via the ask-mode
# prompt, which `always` and the autonomous/headless degrade skip — so on two of three
# modes it had no reader and no recorded home. And step 8's "nothing was pushed"
# confirmation had no failure branch, so a delegated command that pushed would still be
# reported with the push commands as un-run: a false summary.
expect "disclosure: recorded, not merely displayed" \
  "$(has "$SKILL" '**Record that disclosure, do not merely display it.**')"                                              "yes"
expect "disclosure: names the no-prompt modes"  "$(has "$SKILL" 'on `always` and on the autonomous/headless degrade **there is no prompt**')" "yes"
expect "disclosure: in the release schema"      "$(grep -c '"command_effects":' "$SKILL")"                              "1"
expect "disclosure: written at step 3"          "$(has "$SKILL" 'carry it into `release.command_effects`')"                "yes"
expect "disclosure: not a disclosure if unread" \
  "$(has "$SKILL" 'is not a disclosure')"                                                                               "yes"
# #27: step 3 instructed recording the disclosure in `## Release`, but step 9's field
# list — the authoritative enumeration a model follows when writing that section —
# omitted it, so the human-facing half of the GB5#2 fix was unwired. Same
# decide-site/implement-site propagation class as #21/#22/GB4#1/GB4#2.
expect "disclosure: in the ## Release field list" \
  "$(has "$SKILL" '**`command_effects` — what the `release_command` was determined to do**')"                             "yes"
expect "disclosure: field list explains why it is there" \
  "$(has "$SKILL" 'omitting it here would leave the disclosure with no home a human reads')"                              "yes"
expect "pushdetect: field list handles the pushed case" \
  "$(has "$SKILL" 'when `pushed_by_command` is set, that the command pushed on its own')"                                 "yes"
expect "pushdetect: names the false claim it avoids" \
  "$(has "$SKILL" 'would be false there')"                                                                               "yes"
# GB6#1: the detector must key off POSITIVE evidence of a push. Gate B pass 6 verified
# on this very worktree that `git status -sb` prints no tracking segment on a branch with
# no upstream — so "not ahead of upstream" is true while nothing has been pushed, and the
# old negative-signal form would record `pushed_by_command` for a purely local release and
# then withhold the local unwind that is its only recovery. Fail safe toward "local".
expect "pushdetect: keys off positive evidence" \
  "$(has "$SKILL" 'positive evidence that the release DID reach the remote')"                                             "yes"
expect "pushdetect: fails safe toward local"    "$(has "$SKILL" 'the check must fail safe toward "local"')"               "yes"
expect "pushdetect: treats as local by default" \
  "$(has "$SKILL" '**treat the release as local unless**')"                                                              "yes"
expect "pushdetect: names the ls-remote probe"   "$(has "$SKILL" 'ls-remote --tags origin')"                              "yes"
expect "pushdetect: names the upstream-contains probe" \
  "$(has "$SKILL" 'merge-base --is-ancestor <release-sha>')"                                                              "yes"
expect "pushdetect: rejects the status -sb signal" \
  "$(has "$SKILL" 'Do **not** key off `git status -sb` showing the branch "in sync"')"                                    "yes"
expect "pushdetect: names the no-upstream case"  "$(has "$SKILL" 'a branch with no upstream at all')"                     "yes"
expect "pushdetect: names the held-push trigger" \
  "$(has "$SKILL" 'any `direct` run whose push was held at the Phase-5 prompt')"                                          "yes"
expect "pushdetect: unreachable remote is unverified, not pushed" \
  "$(has "$SKILL" 'the push state is *unverified*')"                                                                      "yes"
expect "pushdetect: unverified does not set the flag" \
  "$(has "$SKILL" 'do not set `pushed_by_command`')"                                                                      "yes"
# The skill's own confirmation must agree with the orchestrator's, or an implementer has
# two readings for the no-upstream case.
expect "pushdetect: skill agrees — positive evidence" \
  "$(has "$REL" 'looking for *positive evidence that it was*')"                                                        "yes"
expect "pushdetect: skill rejects absence-of-upstream reasoning" \
  "$(has "$REL" 'the absence of an upstream is not the absence of a push')"                                            "yes"
expect "pushdetect: skill never concludes pushed when inconclusive" \
  "$(has "$REL" 'Never conclude "pushed" from an inconclusive check')"                                                 "yes"
expect "pushdetect: skill drops the in-sync form" \
  "$(has "$REL" 'shows the branch ahead of its upstream, not in sync')"                                                "no"
# GB6#2: the branch names a status, so step 9 can route it. `applied` (not a failure
# status) — nothing failed and nothing is half-done; the honesty owed is the disclosure.
expect "pushdetect: branch names its status" \
  "$(has "$SKILL" 'When the evidence IS positive → `status: "applied"`')"                                                 "yes"
expect "pushdetect: explains why not partial-failure" \
  "$(has "$SKILL" 'deliberately `applied` and not `partial-failure`/`failed`')"                                           "yes"
expect "pushdetect: does not print push cmds as owed" \
  "$(has "$SKILL" 'that summary would be false')"                                                                        "yes"
expect "pushdetect: records pushed_by_command"  "$(has "$SKILL" 'release.pushed_by_command = true')"                      "yes"
expect "pushdetect: local unwind no longer applies" \
  "$(has "$SKILL" 'the local unwind no longer applies')"                                                                  "yes"
# The one enum value the per-status loop omitted (it is in neither the fall-through nor
# the surfaced region, so it was unpinned by construction) — GB5#6a.
expect "enum: resolved-re-derive is pinned too"  "$(printf '%s' "$p9_region" | grep -c 'result: "resolved-re-derive"')"    "1"

# --- #24: the fourth resolution outcome (accepted partial release) ------------
# Without it, a user who declines BOTH offered options (finish / unwind) matched none of
# the three outcomes and the run sat surfaced forever — the permanently-non-terminal hole
# the resolution rule exists to close. The pre-descope design had this outcome; it was
# removed with the rest of the exit machinery and is now restored, minimally.
expect "outcomes: there are four, not three"   "$(has "$SKILL" 'choosing from exactly four honest outcomes')"            "yes"
expect "outcomes: accepted partial is an outcome" \
  "$(has "$SKILL" 'The release is partly cut and the user accepts it as-is')"                                             "yes"
expect "outcomes: accepted partial is not relabelled" \
  "$(has "$SKILL" '**do NOT relabel it as success** — record the acceptance')"                                            "yes"
expect "outcomes: accepted partial is terminal at step 9" \
  "$(has "$SKILL" '**except an *accepted* `partial-failure`**')"                                                          "yes"
expect "outcomes: names the hole it closes"    "$(has "$SKILL" 'the run would sit surfaced forever')"                     "yes"
expect "outcomes: catch-all now says four"     "$(has "$SKILL" 'matches none of the four')"                               "yes"

# --- GATE B pass 4: five findings, four Required ------------------------------
# GB4#1 + GB4#2 are both the #21/#22 class one site further out: a fix applied at
# step 1 but not at the State-file paragraph, and not at step 9's record bullet.
expect "propagation: state prose uses the post-#21 vocabulary" \
  "$(has "$SKILL" '`declined` (it was cut and then unwound, and the user does not want it re-cut)')"                      "yes"
expect "propagation: state prose warns off nothing-to-release" \
  "$(has "$SKILL" '**Note `declined`, not `nothing-to-release`:**')"                                                      "yes"
expect "propagation: no stale resolution vocabulary outside step 1" \
  "$(grep -c 'resolution rule\*\* — `applied`, `nothing-to-release`, or' "$SKILL")"                                       "0"
# GB4#2: declined gets its OWN step-9 bullet, since its two producers differ on
# whether anything ever ran.
expect "record: declined has its own bullet" \
  "$(has "$SKILL" '**`declined`** — which producer it came from decides what to record')"                                 "yes"
expect "record: undone producer records what ran" \
  "$(has "$SKILL" 'do NOT write "the plan that was not cut"')"                                                           "yes"
expect "record: cut-and-reversed fact must not be lost" \
  "$(has "$SKILL" 'That cut-and-reversed fact is the most audit-relevant thing')"                                         "yes"
expect "record: no-run bullet no longer claims declined" \
  "$(has "$SKILL" '**`nothing-to-release` / `deferred-pr` / `runbook`, and either step-3 `failed`**')"                    "yes"
# #25: step 3 writes `failed` from TWO producers (the refusal and a report-only blocker);
# the parenthetical must describe both, not just the refusal.
expect "record: step-3 failed covers both producers" \
  "$(has "$SKILL" 'or a report-only blocker stopped it before it ran')"                                                   "yes"
# GB4#3: a report-only blocker knowable BEFORE any mutation must be acted on there.
expect "blockers: report-only blocker fails at step 3" \
  "$(has "$SKILL" 'The report lists ANY other blocker')"                                                                 "yes"
expect "blockers: acted on at the earliest knowable point" \
  "$(has "$SKILL" 'act on it *at the earliest point it is knowable*')"                                                    "yes"
expect "blockers: does not fall through to apply" \
  "$(has "$SKILL" '**Do not fall through to step 4.**')"                                                                 "yes"
expect "blockers: names the wasted re-gate"    "$(has "$SKILL" 'against a diff nothing changed')"                        "yes"
# GB4#4: completeness must not be anchored to HEAD, or a correct finished release is
# stranded permanently non-terminal.
expect "identity: does not assume the release is HEAD" \
  "$(has "$SKILL" 'do not assume the release commit is still `HEAD`')"                                                    "yes"
expect "identity: locates the commit via the tag" \
  "$(has "$SKILL" 'git rev-parse -q --verify "refs/tags/vX.Y.Z^{commit}"')"                                              "yes"
expect "identity: HEAD-ness only picks the unwind" \
  "$(has "$SKILL" 'changes only which unwind you hand over, never whether the release counts as complete')"               "yes"
# GB4#5: the marker must carry the FINAL approved plan on the amendment path.
expect "marker: written before apply, not before the corrected report-only" \
  "$(has "$SKILL" 'write the marker before the `apply` one, never before the corrected `report-only`')"                    "yes"
expect "marker: must carry the final approved plan" \
  "$(has "$SKILL" 'The marker must always carry the *final* approved plan')"                                              "yes"

# --- #21/#22: one producer per status, and no residual false transience claim --
# #21: GB#2 routed `nothing-to-release` to a live re-read on the premise that nothing
# was ever cut — true of step 3's no-op, FALSE of the resolution rule's "undone" outcome,
# where a release was cut then unwound. Two producers with opposite safe routings meant a
# resume re-cut a release the user had explicitly declined (the pass-7 `descoped` defect,
# re-opened through a different value). The undone outcome now records `declined`, which
# step 1 already refuses to re-derive.
expect "producers: undone outcome records declined" \
  "$(has "$SKILL" '**Deliberately `declined`, not `nothing-to-release`:**')"                                            "yes"
expect "producers: names the re-cut it prevents" \
  "$(has "$SKILL" 're-cut with no prompt the very release the user just declined')"                                      "yes"
expect "producers: states the one-producer rule" \
  "$(has "$SKILL" 'One value must not carry two producers with opposite safe routings')"                                 "yes"
# Single-producer check, derived: `nothing-to-release` must be written exactly once in the
# phase (step 3's no-op), since its routing depends on that producer's premise.
expect "producers: nothing-to-release has ONE producer" \
  "$(printf '%s' "$p9_region" | grep -c 'status: "nothing-to-release"')"                                                 "1"
# And the fall-through set must not intersect the resolution rule's terminal outcomes.
expect "producers: fall-through set excludes declined" \
  "$(has "$SKILL" '`nothing-to-release` / `runbook` / `deferred-pr` / any `skipped-*` — fall through to step 2 for a LIVE re-read')" "yes"
# #22: the GB#4 correction had missed a fourth site. Assert the false claim is ABSENT,
# not merely that the corrected wording exists somewhere — that negative is what the
# earlier vacuous-assertion class taught this file to add.
expect "transience: no residual overwrite-on-same-pass claim" \
  "$(grep -c 'immediately overwrites it with a real outcome' "$SKILL")"                                                  "0"
expect "transience: supersede paragraph carries the honest form" \
  "$(has "$SKILL" 'It **can legitimately be observed at rest** while the run sits at step 4')"                            "yes"

# --- #18: superseding a surfaced marker, against an append-only history -------
# Code review: "clear the surfaced marker" was unimplementable — state.history is
# append-only (step 2's skill-absent bullet depends on exactly that), and no
# superseding write was specified. An interrupt across the re-entry would then
# re-surface an already-resolved state with a stale plan.
expect "supersede: says supersede, not clear"  "$(has "$SKILL" '**supersede the surfaced marker and fall through to step 2**')" "yes"
expect "supersede: no stale clear-the-marker instruction" \
  "$(grep -c 'clear the surfaced marker' "$SKILL")"                                                                      "0"
expect "supersede: names the append-only constraint" \
  "$(has "$SKILL" '`state.history` is append-only — you cannot delete the marker')"                                       "yes"
expect "supersede: specifies the superseding entry" \
  "$(has "$SKILL" 'result: "resolved-re-derive", superseded:')"                                                          "yes"
expect "supersede: resolved-re-derive is a recognized branch" \
  "$(printf '%s' "$p9_region" | grep -c '^   - \*\*`resolved-re-derive`\*\*')"                                            "1"
expect "supersede: names the interrupt it prevents" \
  "$(has "$SKILL" 're-surface a state the user has already resolved')"                                                    "yes"

# --- B2's refusal path now has a status and a record -------------------------
# Gate B pass 2: "refuses to run" had no status, no record and no terminal write.
expect "refusal: caught in report-only, before running" \
  "$(has "$SKILL" 'The command commits or tags by itself')"                                                             "yes"
expect "refusal: records a real status"        "$(has "$SKILL" 'this step needs a file-only command')"                  "yes"
expect "refusal: nothing ran so nothing to undo" \
  "$(has "$SKILL" 'Nothing was run, so nothing needs undoing')"                                                         "yes"
expect "refusal: step 9 routes it as no-transcript" \
  "$(has "$SKILL" 'either step-3 `failed`** (the command was refused before running')"                                   "yes"

# --- B4: the non-clean re-gate surfaces, and the undo is CORRECT -------------
# Gate B pass 2 verified empirically that `git checkout --` on an intent-added path
# leaves a 0-byte staged addition rather than removing it. The route no longer
# auto-reverts at all, and the handed-over undo names the correct commands.
expect "regate: non-clean re-gate surfaces"    "$(has "$SKILL" 'SURFACE — do not loop and do not auto-revert')"         "yes"
expect "regate: undo handles a CREATED file correctly" \
  "$(has "$SKILL" 'plus `git rm --cached <path>` and deleting the file**')"                                             "yes"
expect "regate: names the 0-byte trap"         "$(has "$SKILL" 'leaving a 0-byte staged addition rather than removing it')" "yes"
expect "regate: no false 'total revert' claim" "$(printf '%s' "$p9_region" | grep -c 'nothing was committed yet, so this is total')" "0"

# --- record discipline: never write a record of something that did not happen -
expect "record: skipped-* writes no fabricated artifact" \
  "$(has "$SKILL" 'do NOT create an `artifacts/release-*.txt` for a command that was never executed')"                  "yes"
expect "record: transcript only when the command ran" \
  "$(has "$SKILL" 'the release command ran **in this session**, so save its transcript')"                               "yes"
# GB6#3: the transcript mandate now covers a `failed` raised at step 4, and a step-4
# `failed` can precede the command ever running (the skill hard-stops on substep 4.1 too).
# The bullet must verify its own premise or it mandates a fabricated artifact — the exact
# thing the skipped-* bullet two rows up forbids.
expect "record: transcript premise is verified, not assumed" \
  "$(has "$SKILL" 'verify that premise before acting on it')"                                                            "yes"
expect "record: names all four no-transcript producers" \
  "$(has "$SKILL" 'ALL FOUR of these statuses can be recorded with no transcript in *this* session')"                        "yes"
expect "record: step-4 failed can precede the command" \
  "$(has "$SKILL" 'a step-4 **`failed`** raised **before** substep 4.2 ever ran the command')"                         "yes"
# GB6#4: step 4's undo must NOT cite step 5's intent-add — step 5 runs after step 4.
expect "undo: step-4 form deletes the untracked file" \
  "$(has "$SKILL" 'simply deleting the untracked file')"                                                                  "yes"
expect "undo: step-4 names why it differs from step 6" \
  "$(has "$SKILL" 'step 5 runs *after* this branch — nothing is intent-added here')"                                      "yes"
expect "undo: step-4 no longer claims a step-5 intent-add" \
  "$(has "$SKILL" 'for anything it created and step 5 intent-added')"                                                     "no"
expect "record: invalid value goes to history not release.mode" \
  "$(has "$SKILL" 'Record the offending value in the `state.history` entry, NOT in `release.mode`')"                     "yes"

# --- the five DISTINCT degrade paths ---------------------------------------
# Each must stay separately recordable: collapsing two of them would make a
# skipped release indistinguishable from a failed one in the ledger.
expect "degrade: skipped-disabled"             "$(has "$SKILL" 'status: "skipped-disabled", mode: "skip"')"            "yes"
expect "degrade: skipped-invalid-value"        "$(has "$SKILL" 'status: "skipped-invalid-value"')"                     "yes"
expect "degrade: skipped-skill-absent"         "$(has "$SKILL" 'status: "skipped-skill-absent"')"                      "yes"
expect "degrade: runbook when command unset"   "$(has "$SKILL" 'status: "runbook"')"                                   "yes"
expect "degrade: failed command recorded"      "$(has "$SKILL" 'status: "failed"')"                                    "yes"
# The canonical enum must carry every one of them exactly once.
enum="$(grep -m1 '"status": "skipped-disabled|skipped-invalid-value' "$SKILL")"
for st in skipped-disabled skipped-invalid-value skipped-skill-absent deferred-pr nothing-to-release runbook in-progress applied partial-failure failed declined; do
  expect "enum: contains ${st}"                "$(printf '%s' "$enum" | grep -c "|\?${st}[|\"]")"                      "1"
done
expect "degrade: five distinct status values"  "$(printf '%s' "$enum" | tr '|' '\n' | grep -cE 'skipped-disabled|skipped-invalid-value|skipped-skill-absent|runbook|failed')" "5"
expect "degrade: skill-absent checked live"    "$(has "$SKILL" 'Check this **live**, not from a `define-preflight` history entry')" "yes"
expect "degrade: matches either reg. form"     "$(has "$SKILL" 'Probe for **either** registration form')"              "yes"
expect "degrade: never improvise the skill"    "$(has "$SKILL" 'Do **not** improvise the release yourself')"           "yes"
expect "degrade: preflight is not a hard stop" "$(has "$SKILL" 'release-skill-absent')"                                "yes"

# --- landing_model: pr defers instead of releasing -------------------------
expect "landing: pr defers"                    "$(has "$SKILL" 'A `chore(release): vX.Y.Z` commit belongs on the default branch')" "yes"
# Code review: this used to re-test the SAME substring as the line above under a
# label claiming distinct coverage. Now it pins the linkage AC #10 actually declares —
# that the deferral names the landing model AND its rationale on one line.
expect "landing: deferral cites landing_model" \
  "$(grep -cE 'state\.landing == "direct"`.*belongs on the default branch' "$SKILL")"                                  "1"
expect "landing: status is deferred-pr"        "$(has "$SKILL" 'status: "deferred-pr"')"                                "yes"
expect "landing: only direct proceeds"         "$(has "$SKILL" 'Only an explicit `landing: "direct"` proceeds')"        "yes"
expect "landing: skill warns off-default-branch" "$(has "$REL" 'Not on the default branch')"                            "yes"
expect "landing: readme documents deferral"    "$(has "$README" 'defers instead of releasing')"                         "yes"

# --- unwind + partial failure --------------------------------------------
expect "unwind: git tag -d surfaced"           "$(has "$SKILL" 'git tag -d vX.Y.Z')"                                    "yes"
expect "unwind: git reset --hard HEAD~1"       "$(has "$SKILL" 'git reset --hard HEAD~1')"                              "yes"
expect "unwind: reset precondition stated"     "$(has "$SKILL" 'only safe while the release commit is still `HEAD` and the tree is clean')" "yes"
expect "unwind: revert fallback"               "$(has "$SKILL" 'git revert <release-sha>')"                             "yes"
expect "unwind: persisted to release.unwind"   "$(has "$SKILL" 'Persist what you handed over to `release.unwind`')"      "yes"
expect "unwind: skill states precondition too" "$(has "$REL" 'only safe while the release commit is still `HEAD` and the tree is clean')" "yes"
expect "edge: pre-existing tag"                "$(has "$REL" 'already exists')"                                         "yes"
expect "edge: never moves an existing tag"     "$(has "$REL" 'Never move or delete an existing tag')"                    "yes"
expect "edge: absent CHANGELOG"                "$(has "$REL" 'absent, or has no recognizable insertion point')"          "yes"
expect "edge: commit-without-tag partial failure" "$(has "$REL" 'Commit landed but the tag failed')"                      "yes"
expect "edge: partial failure not called done" "$(has "$SKILL" 'never describe it as done')"                             "yes"
expect "edge: partial failure surfaces"        "$(has "$SKILL" 'status: "partial-failure"')"                             "yes"
expect "edge: failed is never auto-retried"    "$(has "$SKILL" 'Auto-task does not finish or undo it for you')"        "yes"
expect "edge: verifies bump before tagging"    "$(has "$REL" 'Verify the bump actually happened')"                       "yes"
expect "edge: annotated not lightweight"       "$(has "$SKILL" 'is `tag` (annotated, not lightweight)')"                 "yes"

# --- the settings keys ----------------------------------------------------
expect "settings: release_mode default skip"   "$(bash "$SETTINGS" get release_mode 2>/dev/null)"                        "skip"
expect "settings: release_command default ''"  "$(bash "$SETTINGS" get release_command 2>/dev/null)"                     ""
expect "settings: release_mode in defaults_json" "$(bash "$SETTINGS" all 2>/dev/null | jq -r '.release_mode')"            "skip"
expect "settings: release_command in defaults_json" "$(bash "$SETTINGS" all 2>/dev/null | jq -r '.release_command')"       ""
expect "settings: both in known_keys"          "$(grep -c 'release_mode release_command' "$SETTINGS")"                    "1"
# The keys are additive and must NOT force a settings reset on existing users.
expect "settings: schema version NOT bumped"   "$(grep -c 'AUTO_TASK_SETTINGS_SCHEMA_VERSION:-3}' "$SETTINGS")"           "1"
expect "settings: not a first-run question"    "$(has "$SKILL" 'Not a First-run-setup question')"                         "yes"

# --- install + docs surfaces --------------------------------------------
expect "install: SKILLS array has the skill"   "$(grep -c '^SKILLS=(.*auto-task-release' "$INSTALL")"                    "1"
at_least "readme: documents the step"          "$(grep -c 'auto-task-release' "$README")"                               1
expect "readme: Release at handover section"   "$(grep -c '^### Release at handover' "$README")"                          "1"
# GB5#4: the count the diff itself authored must match its bullets. R10's guard only
# covered counts the new phase FALSIFIED, so a newly-written wrong count was unpinned.
rel_props="$(awk '/properties worth knowing, because they are what stop an automated release/,/^### Post-PR/' "$README" | grep -c '^- \*\*')"
expect "readme: release property count matches"  "$(awk '/properties worth knowing, because they are what stop an automated release/{print $1}' "$README")" "Five"
expect "readme: release has five property bullets" "$rel_props"                                                          "5"
expect "readme: release_mode settings row"     "$(grep -c '^| `release_mode` |' "$README")"                               "1"
expect "readme: release_command settings row"  "$(grep -c '^| `release_command` |' "$README")"                            "1"
expect "readme: skill count corrected"         "$(grep -c 'Seven namespaced' "$README")"                                  "0"
expect "readme: documents the surfacing limit" \
  "$(has "$README" 'An interrupted release is handed to you, not auto-resumed')"                                        "yes"
expect "readme: states the preserved invariant" \
  "$(has "$README" 'an interrupted release never silently re-cuts and never reports success')"                          "yes"
expect "arch: flowchart node says surfaced-for-manual-resolution" \
  "$(has "$ARCH" 'SURFACED for manual resolution')"                                                                     "yes"
expect "readme: skill count is eight"          "$(grep -c 'Eight namespaced' "$README")"                                  "1"
at_least "arch: documents the step"            "$(grep -c 'auto-task-release' "$ARCH")"                                  3
expect "arch: phase table row"                 "$(grep -c '^| 9 Release (gated, opt-in)' "$ARCH")"                        "1"
expect "arch: flowchart has the phase-9 gate"  "$(has "$ARCH" 'P9{release_mode?')"                                        "yes"
expect "state: release object documented"      "$(has "$SKILL" '**`release` object (Phase 9 — release step).**')"          "yes"
expect "state: terminal vs in-flight rule"     "$(has "$SKILL" '**Terminal vs in-flight for `phase: "release"`.**')"        "yes"
expect "state: no hook reads the object"       "$(has "$SKILL" '**No hook reads this object**')"                           "yes"

# --- the run-state hooks handle phase=release, with NO hook edited ---------
# Independent of every grep above: build a synthetic release-phase STATE and run
# the three hooks that parse run state against it.
# Chain the spec-concat cleanup: this trap is set AFTER spec_concat_into, so a bare
# trap here would clobber the cleanup it registered.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"; _spec_concat_cleanup' EXIT
(
  cd "$tmp" || exit 1
  git init -q . 2>/dev/null
  git config user.email t@t; git config user.name t
  mkdir -p .auto-task/feat/x
  echo hi > f.txt; git add f.txt; git commit -qm init 2>/dev/null
  base="$(git rev-parse HEAD)"
  git switch -qc feat/x 2>/dev/null
  cat > .auto-task/feat/x/STATE.json <<JSON
{"phase":"release","expected_next_action":"user-approval","approved":true,
 "title":"t","description":"d","branch":"feat/x","base":"$base",
 "effort":{"tier":"standard","difficulty":3,"risk":1,"history":[]},
 "iteration":{"review":1,"fix":1},
 "history":[{"phase":"release","result":"partial-failure","summary":"tag missing","at":"2026-01-01T00:00:00Z"}],
 "gates":{"code_review":{"passed":true,"tool":"skill:auto-task-code-review","clean_pass_after_last_fix":true,"reviewed_diff_sha":null},"gate_b":{"passed":true}},
 "release":{"status":"partial-failure","version":"1.2.0","bump":"minor"}}
JSON
) >/dev/null 2>&1

rl="$(cd "$tmp" && bash "$ROOT/hooks/auto-task-resume-list.sh" --json 2>/dev/null || echo '[]')"
expect "hook: release-phase run is resumable" \
  "$(printf '%s' "$rl" | jq -r '[.[]|select(.phase=="release")]|first|.resumable // "missing"' 2>/dev/null)" "true"
expect "hook: resume-mode sees it as direct" \
  "$(cd "$tmp" && bash "$ROOT/hooks/auto-task-resume-list.sh" --resume-mode 2>/dev/null)" "direct"
# The Stop hook must treat phase=release exactly like every other mid-pipeline
# phase: block on auto-continue, allow on a user gate. This is what gives Phase 9's
# non-yielding contract mechanical backing, and it is the assertion that proves the
# new phase string needed no hook change. NOTE it decides via a JSON payload on
# STDOUT, not an exit code — an exit-code test reads every case as "allowed" and so
# would pass even if the hook ignored the release phase entirely.
dec(){ (cd "$tmp" && CLAUDE_PROJECT_DIR="$tmp" AUTO_TASK_HOME="$tmp/$1" \
  bash "$ROOT/hooks/prevent-mid-protocol-stall.sh" <<<'{}' 2>/dev/null) \
  | jq -r '.decision // "allow"' 2>/dev/null || echo allow; }
d_ua="$(dec sh_ua)"; [ -n "$d_ua" ] || d_ua=allow
expect "hook: stall hook allows release+user-approval" "$d_ua" "allow"
python3 - "$tmp/.auto-task/feat/x/STATE.json" <<'PYX'
import json,sys,io
p=sys.argv[1]; d=json.load(io.open(p)); d["expected_next_action"]="auto-continue"
io.open(p,'w').write(json.dumps(d))
PYX
d_ac="$(dec sh_ac)"; [ -n "$d_ac" ] || d_ac=allow
expect "hook: stall hook blocks release+auto-continue" "$d_ac" "block"

# record-outcome must NOT record a non-done run.
ro="$(cd "$tmp" && CLAUDE_PROJECT_DIR="$tmp" AUTO_TASK_HOME="$tmp/home" bash "$ROOT/hooks/record-outcome.sh" <<<'{}' 2>&1; echo "exit=$?")"
expect "hook: record-outcome skips phase=release" \
  "$([ -f "$tmp/home/auto-task/outcomes.jsonl" ] && echo recorded || echo skipped)" "skipped"
# Gate A: PLAN.md's AC #17 names auto-task-stats.sh and expects a release-phase run
# to bucket as stalled/in-flight, NOT done. record-outcome's "did not record" is a
# weaker proxy, so assert the declared expectation directly.
stats="$( (cd "$tmp" && CLAUDE_PROJECT_DIR="$tmp" AUTO_TASK_HOME="$tmp/home" \
  bash "$ROOT/hooks/auto-task-stats.sh" 2>/dev/null) || true)"
expect "hook: stats does not count release as done" \
  "$(printf '%s' "$stats" | grep -cE '1 runs? on record — 0 done')"                                                    "1"
# stalled vs in-flight depends only on the history timestamp's age, and BOTH are the
# honest "not done" reading — assert it is counted as active either way, which is the
# property AC #17 actually cares about.
expect "hook: stats counts release as active"    \
  "$(printf '%s' "$stats" | grep -cE '0 done, (1 stalled, 0 in-flight|0 stalled, 1 in-flight)')"                        "1"

# No hook file may mention the release phase — the design's whole claim is that
# a new phase string needs no hook change.
hookrefs=0
for h in "$ROOT"/hooks/*.sh; do
  case "$(basename "$h")" in settings.sh) continue ;; esac
  grep -q 'release_mode\|phase.*"release"' "$h" 2>/dev/null && hookrefs=$((hookrefs+1))
done
expect "hook: no hook keys on the release phase" "$hookrefs" "0"

echo
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
