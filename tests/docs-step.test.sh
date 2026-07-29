#!/usr/bin/env bash
# Drift guard for the optional docs-update step (`docs_update_mode` + the
# `auto-task-docs` skill + Phase 5 step 1b).
#
# WHY THIS EXISTS. The step is specified in prose across six files, and prose has
# no compiler. Its correctness depends on claims that a later edit can silently
# break: that the step runs BEFORE staging (or its edits miss the single commit),
# that it re-passes the gates (or it ships un-reviewed bytes), that `ask` cannot
# deadlock an unattended run, that it does not quietly spend the fix-loop budget,
# and that every "there is only ONE prompt" absolute in the contract was
# reconciled with the new yield. This test pins each of those as a grep.
#
# Pure and hermetic: greps files in the repo. No model, no network, no writes.
# Usage: tests/docs-step.test.sh   Exit 0 = in sync.

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
DOCS="$ROOT/skills/auto-task-docs/SKILL.md"
SETTINGS="$ROOT/hooks/settings.sh"
INSTALL="$ROOT/install.sh"
README="$ROOT/README.md"

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-56s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-56s got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }
# has <file> <fixed-string>  -> yes|no
has(){ grep -qF "$2" "$1" 2>/dev/null && echo yes || echo no; }

echo "================ docs-update step ================"

# --- the new skill exists with the sibling frontmatter convention ------------
expect "auto-task-docs skill present"        "$([ -f "$DOCS" ] && echo yes || echo no)" "yes"
expect "frontmatter: name"                   "$(head -6 "$DOCS" 2>/dev/null | grep -c '^name: auto-task-docs$')" "1"
expect "frontmatter: non-empty description"  "$(head -6 "$DOCS" 2>/dev/null | grep -cE '^description: .+')"      "1"

# --- the skill's scope contract (in-scope AND the explicit non-targets) ------
# The narrow scope is the whole reason the docs diff stays reviewable; losing a
# non-target line would let the step edit behavior files or the release CHANGELOG.
# ANCHORED to the structure, not mere presence. The first version of these three
# asserted only that "CHANGELOG.md" appeared SOMEWHERE in the file — which passes
# just as happily if the name is moved into the in-scope list. Gate B caught that:
# the labels claimed to assert exclusion while testing nothing of the kind. Each
# non-target is now pinned to its row in the "Explicitly OUT of scope" table AND
# checked absent from the in-scope bullets.
expect "scope: README.md in scope"           "$(grep -c '^- `README.md` at the repo root\.$' "$DOCS")"      "1"
expect "scope: docs/** in scope"             "$(grep -c '^- Everything under `docs/\*\*`\.$' "$DOCS")"     "1"
for nt in 'CHANGELOG.md' 'CLAUDE.md` (any level)' 'Code comments, docstrings, JSDoc'; do
  expect "scope: non-target row present: ${nt:0:22}" "$(grep -c "^| \`\?${nt%%\`*}" "$DOCS")" "1"
done
# The in-scope list is exactly two bullets — a third would mean something was
# promoted into editable scope.
in_scope_n="$(awk '/^\*\*In scope/,/^\*\*Explicitly OUT/' "$DOCS" | grep -c '^- ')"
expect "scope: in-scope list is exactly 2 bullets" "$in_scope_n" "2"
for nt in 'CHANGELOG' 'CLAUDE.md'; do
  expect "scope: $nt absent from in-scope list" \
    "$(awk '/^\*\*In scope/,/^\*\*Explicitly OUT/' "$DOCS" | grep -c "$nt")" "0"
done
expect "skill: never commits"                "$(has "$DOCS" 'Never commit, never stage, never push')" "yes"
expect "skill: report precedes editing"      "$(has "$DOCS" 'Report before editing')"                 "yes"
expect "skill: a no-op is a valid result"    "$(has "$DOCS" 'A no-op is a valid result')"              "yes"

# --- the setting is registered in all three lockstep sites -------------------
expect "settings: default_for entry"         "$(grep -cE "docs_update_mode\) +printf 'skip'" "$SETTINGS")" "1"
expect "settings: defaults_json entry"       "$(grep -c 'docs_update_mode: "skip"' "$SETTINGS")"                    "1"
expect "settings: known_keys entry"          "$(grep -c 'unattended_external docs_update_mode' "$SETTINGS")"        "1"
expect "settings: schema stamped 3"          "$(grep -c 'AUTO_TASK_SETTINGS_SCHEMA_VERSION:-3' "$SETTINGS")"        "1"

# --- first-run setup asks FIVE questions, with no stale count phrasing -------
expect "spec: five policy questions (2 sites)" "$(grep -c 'five policy questions' "$SKILL")" "2"
expect "spec: question 1 of 5"                 "$(grep -c 'question 1 of 5' "$SKILL")"       "1"
expect "spec: no stale 'four' count phrasing"  "$(grep -cE 'four (policy )?questions|question 1 of 4|four questions' "$SKILL")" "0"
expect "spec: docs bullet in setup"            "$(has "$SKILL" '**Docs update** — after a run')" "yes"
expect "spec: settings-table row"              "$(grep -c '^| `docs_update_mode` |' "$SKILL")"   "1"
# Preflight must NAME the docs skill (so it is discoverable) while treating it as
# optional (B3). Both halves matter: naming it satisfies R8; the optional framing
# is what stops a missing symlink from hard-stopping every run.
expect "spec: preflight names auto-task-docs"  "$(has "$SKILL" '`auto-task-docs` and `auto-task-release` are OPTIONAL')" "yes"
expect "spec: preflight no longer demands seven" "$(grep -c 'all seven composed skills' "$SKILL")" "0"

# --- Phase 5 step 1b: placed BEFORE staging ---------------------------------
# Ordering is load-bearing: after the stage step, docs edits would miss the
# single handover commit entirely.
expect "phase5: step 1b present"             "$(grep -c '^1b\. \*\*Docs update' "$SKILL")" "1"
# Positional/region assertions must read the file that OWNS the prose, not the union
# concatenation: the section heading stayed in the spine while its body moved to a
# reference, so a first-match anchor on $SKILL would land on the spine summary.
P5REF="$ROOT/skills/auto-task/references/phase-5-handover.md"
docs_at="$(grep -n '^1b\. \*\*Docs update' "$P5REF" | head -1 | cut -d: -f1)"
stage_at="$(grep -n 'Pre-commit main-sync' "$P5REF" | head -1 | cut -d: -f1)"
diagram_at="$(grep -n '^2\. \*\*Build the change diagram' "$P5REF" | head -1 | cut -d: -f1)"
expect "phase5: 1b precedes staging"         "$([ -n "$docs_at" ] && [ -n "$stage_at" ] && [ "$docs_at" -lt "$stage_at" ] && echo yes || echo no)" "yes"
expect "phase5: 1b precedes change diagram"  "$([ -n "$docs_at" ] && [ -n "$diagram_at" ] && [ "$docs_at" -lt "$diagram_at" ] && echo yes || echo no)" "yes"

# --- Phase 5 step 1b: the four components it must name ----------------------
for n in auto-task-docs auto-task-verify auto-task-code-review reviewed_diff_sha; do
  expect "phase5 1b names $n" "$(sed -n "${docs_at},$((docs_at+40))p" "$P5REF" | grep -cF "$n" | awk '{print ($1>0)?"yes":"no"}')" "yes"
done
expect "phase5 1b: Gate B reset on STANDARD/HEAVY" \
  "$(sed -n "${docs_at},$((docs_at+40))p" "$P5REF" | grep -cF 'gates.gate_b.passed = false' | awk '{print ($1>0)?"yes":"no"}')" "yes"

# --- the four behavioral guarantees of step 1b -------------------------------
expect "1b: unknown value reads as skip"     "$(has "$SKILL" 'Any unrecognized value')"                    "yes"
expect "1b: staleness resolved before prompt" "$(has "$SKILL" 'Resolve staleness FIRST, before any prompt')" "yes"
expect "1b: empty report yields nothing"      "$(has "$SKILL" 'a real no-op, with NO yield')"               "yes"
expect "1b: degrades under autonomous/headless" "$(has "$SKILL" 'degrade to `always`, without yielding')"   "yes"
expect "1b: records an assumption"            "$(has "$SKILL" 'state.assumptions[]` entry `{ kind: "auto-approved-ambiguity"')" "yes"
expect "1b: clean re-review spends no budget" "$(has "$SKILL" 'does **not** increment `iteration.review`')"  "yes"
expect "1b: real finding does count"          "$(has "$SKILL" 'that is a genuine fix round')"                "yes"

# --- the yield contract is reconciled, not merely mentioned ------------------
expect "yield: user-approval row cites the docs ask" \
  "$(grep -c '^| `"user-approval"` |.*docs-update ask' "$SKILL")" "1"
expect "yield: per-transition docs row -> user-approval" \
  "$(grep -c '^| Phase 5 docs-update ask .* | `"user-approval"` |' "$SKILL")" "1"

# Each of the six absolutes a new Phase-5 yield would falsify must now admit it.
# Losing any one of these leaves the spec self-contradicting.
expect "absolute 1 (only human surface) reconciled"  "$(has "$SKILL" 'Three kinds of later surface exist')"             "yes"
expect "absolute 1 counts procedural prompts only"  "$(has "$SKILL" '*Procedural* prompts, none of which gates the work')" "yes"
expect "absolute 1 keeps the by-default clause"     "$(has "$SKILL" 'nothing later stops the run *by default*')"      "yes"
expect "absolute 1 states the trigger invariant"    "$(has "$SKILL" 'no surface stops the run unless its documented trigger fires')" "yes"
# --- INVARIANT 2: a "no later gate" EXISTENCE claim must carry a qualifier -----
# Companion to invariant 1 (which covers prompt-COUNT claims). Three consecutive
# review rounds hit one root cause: a clause was added to satisfy a count concern
# without re-reading the sentence it attached to, and round 3's fix produced a
# sentence-pair that said "there is no second human gate later" immediately before
# naming two later gates. An unqualified existence claim is the same defect class,
# so it gets the same mechanical treatment.
# NOTE on form: this is an ABSENCE/PRESENCE pair, not a filtered line grep. A
# line-granular `grep -v qualifier` is unsound here — SKILL.md's paragraphs are
# single ~1500-char lines, so a qualifier occurring ANYWHERE on the line satisfies
# the filter even when the offending clause is unqualified. That is the same
# neighbouring-match defect round 1 found in the absolute-5 assertion; the fix
# there, and here, is to assert the bad phrasing is gone rather than to filter.
for bad in 'there is no second human gate later' 'there is no second human *gate* later' \
           'contains the **only** human-interaction surface'; do
  expect "unqualified gate claim absent: ${bad:0:34}…" "$(grep -cF "$bad" "$SKILL")" "0"
done
expect "opening clause qualified as unconditional" \
  "$(has "$SKILL" "the pipeline's only **unconditional** human gate")"           "yes"
# Round 5: the first gloss on that term over-claimed — "the one surface that stops
# every run regardless of configuration" is FALSE, because `autonomy: autonomous`
# silences the Phase-1 plan gate. Pin the term (above) but NOT the gloss, and bar
# the specific over-claim so it cannot return.
expect "opening gloss does not over-claim"          "$(grep -c 'regardless of configuration' "$SKILL")" "0"
expect "opening clause names the autonomous carve-out" \
  "$(has "$SKILL" 'Under `autonomy: autonomous` even this gate is silenced')"     "yes"
# HONEST LIMITATION: the three assertions above are a REGRESSION guard (three known
# phrasings), not a class-level invariant like the prompt-count one. A newly-worded
# unqualified claim would still pass. A true class guard needs sentence segmentation,
# which this file's single-line-paragraph format does not support — so the scope is
# "the sentences this feature touched", pinned exactly.
expect "absolute 2 (no other stopping points)"       "$(has "$SKILL" 'within Phase 5 only the two documented *procedural* prompts')" "yes"
expect "absolute 3 (only sub-skill return)"          "$(has "$SKILL" 'the `auto-task-docs` staleness report in `ask` mode')" "yes"
expect "absolute 4 (single Phase-5 exception)"       "$(has "$SKILL" 'Phase 5 has exactly two permitted **procedural** prompts')" "yes"
# Code review caught the first version of this over-claiming: "exactly two
# permitted prompts … and no others" is FALSE, because step 7b's merge gate and a
# fix-loop budget ack are both Phase-5 user-approval surfaces. A model trusting the
# absolute could skip the 7b ack and then deadlock, since enforce-gates.sh blocks
# the land on `merge.required && !acked` with no sanctioned prompt to clear it.
expect "prompt enumeration admits the merge gate"    "$(has "$SKILL" 'the **step-7b merge gate**')"                    "yes"
expect "prompt enumeration admits the budget ack"    "$(has "$SKILL" 'fix-loop budget ack')"                           "yes"
# Anchored on the sentence the new yield actually falsifies ("The single mid-run
# exception remains …"), NOT merely on the docs qualifier appearing somewhere in
# the bullet. Gate A caught exactly that: an earlier version of this assertion
# matched a neighbouring sentence, so the falsified one stayed unreconciled and
# the guard passed anyway. Assert BOTH the new phrasing and the absence of the old.
expect "absolute 5 (supervised gates + push) reconciled" \
  "$(has "$SKILL" 'The mid-run exceptions remain the Phase 5 push/PR prompt, the Phase-5 docs-update ask')" "yes"
expect "absolute 5: old single-exception phrasing gone" \
  "$(grep -c 'The single mid-run exception remains' "$SKILL")" "0"
# Two further single-prompt absolutes the original six-site list missed.
expect "absolute 7 (Phase-5 step 8 operative prose)" \
  "$(grep -c 'this is the single allowed Phase 5 interaction surface' "$SKILL")" "0"
expect "absolute 7: replaced with the two-surface phrasing" \
  "$(has "$SKILL" "at-most-two *procedural* interaction surfaces")" "yes"
expect "absolute 8 (ARCHITECTURE pipeline mermaid)" \
  "$(grep -c 'only allowed prompt mid-run' "$ARCH")" "0"
# Branch targets inside step 1b's nested list must name the OUTER Phase-5 step,
# or a model resolving "step 2" locally would invoke auto-task-docs on the skip
# path (the default mode) instead of leaving the step.
expect "1b: no ambiguous bare 'go to step 2'" "$(grep -c 'go to step 2' "$SKILL")" "0"
expect "1b: branch targets name Phase 5 step 2" \
  "$([ "$(grep -c 'go to Phase 5 step 2 ("Build the change diagram")' "$SKILL")" -ge 3 ] && echo ok || echo no)" "ok"
expect "yield table enumerates step 1b" "$(has "$SKILL" 'Phase 5 steps 1, 1b, 2–4')" "yes"
expect "absolute 6 (run-label banner enumeration)"   "$(has "$SKILL" 'the Phase-5 docs-update ask (`ask` mode, non-empty staleness report), the Phase-5 push/PR prompt')" "yes"

# --- fixes from code review round 1 -----------------------------------------
# B1: `$settings_sh` is bound only in the Phase-1 pre-run cluster, and every Bash
# call is a fresh shell — so step 1b MUST re-locate the helper. Without this the
# read returns empty, the unknown-value guard reads `skip`, and the feature
# silently self-disables for every user who configured always/ask.
expect "1b re-locates settings.sh (fresh shell)" \
  "$(has "$SKILL" 'Locate `settings.sh` via the three-probe pattern first')" "yes"
# B2: step 5 stages "planned files only" and rejects paths outside the Blast
# Radius, so the docs paths must be authorized on BOTH sides or the edits are
# silently dropped from the commit while the run reports success.
expect "1b authorizes docs paths for staging" \
  "$(has "$SKILL" 'Authorize the edited paths for staging')"                  "yes"
expect "step 5 stage rule admits the docs paths" \
  "$(has "$SKILL" 'the step-1b docs update authorized there')"                "yes"
# B3: auto-task-docs is OPTIONAL. A git-layout self-update fast-forwards the clone
# without re-running install.sh, so its symlink can be missing — making it a hard
# preflight blocker would stop every run on symlink installs after an update.
expect "preflight requires only the six mandatory skills" \
  "$(has "$SKILL" 'confirm the six **mandatory** composed skills')"           "yes"
expect "preflight treats auto-task-docs as optional" \
  "$(has "$SKILL" 'are OPTIONAL and deliberately NOT hard-stops')"           "yes"
expect "absent docs skill degrades to skip, not a stop" \
  "$(has "$SKILL" 'docs-skill-absent')"                                      "yes"
# R1: resetting gate_b without restoring it on a clean pass blocks the commit.
expect "1b restores gate_b on a clean adversarial pass" \
  "$(has "$SKILL" 'setting it back to `true` **only on a clean adversarial pass**')" "yes"
# R2: the skill is composed mid-pipeline, so it needs the sibling caller note or
# its report can read as an end-of-turn and stall Phase 5.
expect "docs skill carries the caller note"   "$(grep -c 'Caller note (do not strip)' "$DOCS")" "1"
expect "docs skill has read-before-review"    "$(grep -c 'Read-before-review contract' "$DOCS")" "1"
expect "docs skill suppresses TRACE under orchestration" \
  "$(has "$DOCS" 'TRACE appends are suppressed under orchestration')"         "yes"
# Gate B #1 (blocker): the skill had no report-and-return contract, so a linear
# read applied edits BEFORE the caller could ask — and the declined branch then
# left unstaged edits that trip the staleness gate and dead-end the run.
expect "docs skill has an invocation-mode gate"  "$(has "$DOCS" 'Read the invocation mode')"            "yes"
expect "docs skill: report-only is a hard stop"  "$(has "$DOCS" 'In `report-only` mode, STOP HERE')"    "yes"
expect "docs skill: apply step is mode-guarded"  "$(has "$DOCS" '**`apply` mode only**')"               "yes"
expect "1b invokes report-only first"            "$(has "$SKILL" 'explicitly in `report-only` mode')"   "yes"
p5_region="$(awk '/^1\. \*\*Verify gates\*\*/,/^2\. \*\*Build the change diagram/' "$P5REF")"
apply_sites="$(printf '%s' "$p5_region" | grep -o 'in \*\*`apply`\*\* mode' | grep -c .)"
expect "1b re-invokes apply at all 3 sites"      "$apply_sites"                                         "3"
# Gate B #2: a plain diff hides untracked files — the new-capability staleness
# class is unreachable without the untracked set, and a CREATED doc file escapes
# the review-staleness hash unless intent-to-added.
expect "docs skill pairs diff with untracked set" "$(has "$DOCS" 'A plain diff HIDES new files')"       "yes"
expect "1b hands over the untracked set"          "$(has "$SKILL" 'the untracked set')"                 "yes"
expect "created docs are intent-to-added"         "$(has "$SKILL" 'git add -N')"                        "yes"
# Gate B #3: the preflight degrade was recorded and never read.
expect "1b honours the preflight degrade"         "$(has "$SKILL" 'skipped-skill-absent')"              "yes"
# The degrade must key on the LIVE availability check, not on a state.history
# entry: history is append-only across sessions, so a stale `docs-skill-absent`
# record would keep the docs step disabled even after the user ran install.sh to
# fix it. Pin the live predicate and bar the history-keyed formulation.
expect "degrade keyed on live available-skills"   "$(has "$SKILL" "does not appear in **this session's** available-skills list")" "yes"
expect "degrade NOT keyed on history presence"    "$(has "$SKILL" 'Do NOT key this on a `define-preflight` history entry')"       "yes"
expect "docs_update_mode surfaced at plan gate"   "$(has "$SKILL" 'so they know a Phase-5 docs step will run')" "yes"
# Gate B #4: interrupt window between clearing gate_b and re-running it.
expect "1b marks the re-gate before clearing"     "$(has "$SKILL" 'to `state.history` BEFORE clearing **either** flag')" "yes"
expect "step 1 recovers an interrupted re-gate"   "$(has "$SKILL" 'One recovery exception:')"           "yes"
# --- Gate B round 2 fixes -----------------------------------------------------
# #1: `apply` must be bound to the APPROVED finding set. Re-deriving lets it edit
# lines the user never saw — which defeats ask mode, whose only job is consent.
expect "apply is bound to the approved set"       "$(has "$DOCS" 'that set is authoritative AND complete')"          "yes"
expect "apply set is a ceiling, not a start"      "$(has "$DOCS" 'An approved set is a ceiling, not a starting point')" "yes"
expect "1b hands the approved report to apply"    "$(has "$SKILL" 'passing the approved report **verbatim as the finding set**')" "yes"
# #2: the window between "edits on disk" and authorization needs a resume anchor,
# or a resumed run gets an empty report, exits at sub-step 3, and silently drops
# the docs work while reporting success.
# Pin the COUNT, not mere presence: the marker must appear at all three sites
# (logged on apply, read by the sub-step-0 resume guard, read by step 1's recovery
# clause). A bare presence check passed a probe that removed two of the three.
# Four occurrences: logged on apply, enumerated in the guard's in-flight lead-in,
# its own guard branch, and step 1's recovery clause. Pinning the count (not mere
# presence) is deliberate — a probe that removed two of three once slipped past a
# bare presence check, and this same assertion then caught the F7 fix adding a
# legitimate fourth. If you add a site, update the number; do not relax to presence.
pend_n="$(printf '%s' "$p5_region" | grep -o 'applied-pending-authorization' | grep -c .)"
expect "pending marker present at all 4 sites"    "$pend_n"                                                          "4"
# Gate B r3 #1: the anchor must be written BEFORE the apply call — an interrupt
# across the sub-agent return boundary would otherwise leave edits on disk with no
# marker at all, which is the exact drop the marker exists to prevent.
expect "apply is bracketed by two markers"        "$(has "$SKILL" 'Bracket every apply with two markers — the first BEFORE the call')" "yes"
expect "pre-call applying marker exists"          "$(has "$SKILL" 'result: "applying", files:')"                      "yes"
# Gate B r4 #2: the marker must persist the APPROVED SET, not just paths — it is
# the only durable copy of what the user consented to, and a resumed session
# cannot see the dead session's conversation.
expect "applying marker persists the findings set" "$(has "$SKILL" 'findings: [<the approved report VERBATIM')"          "yes"
expect "findings payload flagged load-bearing"     "$(has "$SKILL" 'The `findings` payload is load-bearing')"            "yes"
# Gate B r4 #1: a tree check cannot distinguish "edited by the apply" from "edited
# by the run's own change" (README.md is routinely in both), so the resume must be
# idempotent rather than inferential.
expect "resume does NOT infer from the tree"       "$(has "$SKILL" 'Do not try to tell which from the tree')"             "yes"
expect "resume re-applies idempotently"            "$(has "$SKILL" 'make the resume **idempotent**')"                     "yes"
expect "tree-inference branch is gone"             "$(grep -c 'Any of them modified/created' "$SKILL")"                    "0"
expect "apply contract states idempotence"         "$(has "$DOCS" 'This makes `apply` idempotent, which callers rely on for resume')" "yes"
expect "guard handles the in-flight applying case" "$(has "$SKILL" 'the apply call was in flight when the session died')" "yes"
# Gate B r3 #2: a marketplace install registers the sibling as
# `auto-task:auto-task-docs`, so probing only the bare name would force skip on the
# DEFAULT install layout and silently ignore a configured always/ask.
expect "degrade probe accepts both name forms"    "$(has "$SKILL" 'Match EITHER registration form when you run that probe')" "yes"
# r4 #3: the rationale must sit AFTER the conditional's consequent, or the
# consequent grammatically attaches to the hypothetical instead of the real case.
expect "degrade conditional keeps its consequent"  "$(has "$SKILL" 'available-skills list (the same authoritative signal the component preflight reads), then force `mode="skip"`')" "yes"
expect "degrade probe names the namespaced form"  "$(has "$SKILL" '`auto-task:auto-task-docs` under a marketplace install')" "yes"
# Gate B r3 #3: the re-gating branch resumes at 6 (sub-step 5 already ran), and
# every marker's payload now matches what a resumer reads.
expect "re-gating branch resumes at sub-step 6"   "$(has "$SKILL" 'Resume at sub-step **6** (the re-gate), not 5')"    "yes"
expect "re-gating marker carries a files list"    "$(has "$SKILL" 'result: "re-gating", files:')"                     "yes"
expect "1b has a resume guard as sub-step 0"      "$(has "$SKILL" 'Resume guard (check FIRST, before resolving the mode)')" "yes"
# F7: the guard's report-only prohibition must be scoped to the three IN-FLIGHT
# markers. Quantified over "every case below" it also covered the catch-all, which
# is the normal fresh-run path — skipping the report there leaves `apply` with no
# finding set, so it re-derives a superset with no report ever shown. This is the
# drift class to watch if a fifth branch is ever added.
expect "guard prohibition scoped to in-flight"    "$(has "$SKILL" 'In the three in-flight cases below')"               "yes"
expect "guard has no blanket 'every case' scope"  "$(grep -c 'In every case below' "$SKILL")"                          "0"
expect "guard names the fresh-run path explicitly" "$(has "$SKILL" 'The fourth branch is the opposite case and the normal one')" "yes"
# #3: the docs re-review's fix loop can clear code_review.passed too, so the
# recovery clause must cover BOTH flags or the resume dead-ends on the sibling one.
expect "recovery covers both gate flags"          "$(has "$SKILL" 'if **either** `gates.code_review.passed` or `gates.gate_b.passed` is `false`')" "yes"
# #4: ordering. reviewed_diff_sha is computed from `git diff <base>`, which hides
# untracked paths — so intent-to-add MUST precede the pin or the sha either misses
# the created file or is invalidated by it (hard-blocking the commit).
expect "authorize precedes the re-gate"           "$(has "$SKILL" 'BEFORE the re-gate (REQUIRED; ordering is load-bearing)')" "yes"
expect "intent-to-add lands before the sha pin"   "$(has "$SKILL" 'before sub-step 6 pins the sha')"                 "yes"
# Anchor on the OWNING reference, not the union concat: `6. **Re-pass the gates`
# also occurs in references/phase-9-release.md, so a first-match on the concat
# resolves to phase-5 only by spec_files sort order — a rename could silently
# repoint it at phase-9 and make the ordering assertion meaningless.
auth_at="$(grep -n '^   5\. \*\*Authorize the edited paths' "$P5REF" | head -1 | cut -d: -f1)"
regate_at="$(grep -n '^   6\. \*\*Re-pass the gates' "$P5REF" | head -1 | cut -d: -f1)"
expect "sub-step order: 5 authorize < 6 re-gate" \
  "$([ -n "$auth_at" ] && [ -n "$regate_at" ] && [ "$auth_at" -lt "$regate_at" ] && echo yes || echo no)" "yes"
# #5: the sibling skill Phase 5 composes right after the docs ask no longer claims
# a single human interaction.
expect "commit skill note admits the docs ask"    "$(grep -c 'the single human interaction' "$ROOT/skills/auto-task-commit/SKILL.md")" "0"

# F1: the optional-component carve-out must not be contradicted by the paragraph's
# own later absolutes. Both "if any is missing -> STOP" and "a missing piece is a
# hard blocker" have to be scoped to MANDATORY components, or a model reading
# linearly hard-stops on the optional skill anyway.
expect "preflight STOP is scoped to mandatory"  "$(has "$SKILL" 'If any **mandatory** component is missing')"        "yes"
expect "hard-blocker line scoped to mandatory"  "$(has "$SKILL" 'a missing **mandatory** piece is a hard blocker')"  "yes"
expect "preflight cross-ref points upward"      "$(grep -c 'Every OTHER component below remains' "$SKILL")"          "0"

# --- INVARIANT: no exhaustive Phase-5 prompt-count claim may omit the merge gate
# This replaces the brittle per-site wording greps for exhaustivity. Two review
# rounds each found a *different* sentence asserting a two-prompt maximum while
# the step-7b merge gate and the fix-loop budget ack also stop the run there — a
# model trusting such a claim skips the 7b ack and then deadlocks, because
# enforce-gates.sh blocks the land on `merge.required && !acked` with no sanctioned
# prompt to clear it. One invariant catches the whole class instead of eight greps.
# The selector is deliberately narrow — claim-phrase AND Phase-5 AND prompt/surface
# — so it targets only Phase-5 prompt-count sentences. A broader match false-flags
# unrelated pre-existing prose ("resolves exactly two ways" in the INCONCLUSIVE
# floor, "at most two AskUserQuestion calls" in the Phase-1 clarify router).
p5_claims="$(grep -nE 'only the two|exactly two|at-most-two|at most 2' "$SKILL" \
  | grep -E 'Phase 5|Phase-5' | grep -iE 'prompt|interaction surface' || true)"
expect "Phase-5 prompt-count sentences found"        "$([ "$(printf '%s' "$p5_claims" | grep -c .)" -ge 3 ] && echo ok || echo no)" "ok"
bad_claims="$(printf '%s' "$p5_claims" | grep -v 'procedural' || true)"
expect "no exhaustive prompt claim omits 'procedural'" "$(printf '%s' "$bad_claims" | grep -c . )" "0"
[ -n "$bad_claims" ] && printf '        offending line(s):\n%s\n' "$bad_claims"

# --- ARCHITECTURE.md: all four regions in sync ------------------------------
expect "arch: pipeline mermaid has the docs branch" "$(has "$ARCH" 'P5DocsRun')"                          "yes"
expect "arch: mermaid re-gates before staging"      "$(has "$ARCH" 'P5DocsGate')"                         "yes"
expect "arch: phases-at-a-glance Phase-5 row"       "$(grep -c '^| 5 Handover | optional `auto-task-docs`' "$ARCH")" "1"
expect "arch: composed-skills mermaid node"         "$(has "$ARCH" 'AT --> Docs[skill: auto-task-docs')"  "yes"
expect "arch: composed-skills bullet"               "$(grep -c '^- \*\*`auto-task-docs`\*\*' "$ARCH")"    "1"
expect "arch: related-files row"                    "$(has "$ARCH" 'auto-task-docs/SKILL.md')"            "yes"
expect "arch: own non-yielding rule reconciled"     "$(has "$ARCH" 'the Phase 5 docs-update ask')"        "yes"

# --- packaging + user docs ---------------------------------------------------
expect "install.sh SKILLS includes it"       "$(grep -c 'auto-task-fix auto-task-docs' "$INSTALL")"        "1"
expect "install.sh syntax clean"             "$(bash -n "$INSTALL" 2>/dev/null && echo 0 || echo 1)"       "0"
expect "README: settings-table row"          "$(grep -c '^| `docs_update_mode` |' "$README")"              "1"
expect "README: feature section"             "$(grep -c '^### Docs update at handover' "$README")"         "1"
expect "README: sibling count is current"    "$(grep -c 'Eight namespaced sibling skills' "$README")"      "1"
expect "README: no stale count/banner"       "$(grep -cE 'Six namespaced sibling skills|the six bundled sibling|four questions|upgrading to 0.22' "$README")" "0"
expect "README: five-question setup"         "$(has "$README" 'five questions: telemetry, autonomy, landing style, unattended-external, docs update')" "yes"

# --- self-integrity: this file must not itself carry a weakening marker ------
# `checks.sh`'s test-integrity guard scans ADDED lines of any test path for
# skip/focus markers. Because this suite asserts *about* a setting whose value is
# literally `skip`, it is easy to write a grep pattern that leaves a marker-shaped
# substring behind — using a bare `.` as a wildcard for the quotes in
# `printf 'skip'` produces exactly the dot-plus-keyword shape the guard looks for,
# which reports a false "tests weakened" FAIL at handover. That happened once;
# this pins it. Note the marker shape must not appear even in a COMMENT here (the
# guard scans source text, not code) — hence the prose above spells it out rather
# than quoting it. The pattern below is assembled at runtime so it cannot
# match itself.
SELF_TI="$(printf '\\.%s\\b|\\.%s\\(' skip only)"
expect "this file carries no skip/focus marker" \
  "$(grep -cE "$SELF_TI" "${BASH_SOURCE[0]}" 2>/dev/null)" "0"

echo ""
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
