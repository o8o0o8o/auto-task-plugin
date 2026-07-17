#!/usr/bin/env bash
# Structural regression guard for the Phase-1 TWO-STEP CLARIFY ROUTER.
#
# The "forward to the ticket owner" paste-ready comment used to live only as
# prose rendered alongside the clarifying questions — no test, no hook — so the
# model reliably SKIPPED it. This test pins the router's load-bearing literals so
# the reliability fix can't silently regress: the router markers, both options,
# the gating sentence, the two branches, the forward-pause + resume marker, the
# approach-fold reuse, the reconciled contract prose (yield-point rows, banner
# list, NON-YIELDING wording, history enum), and the doc updates.
#
# What this DOES cover: that the router's contract PROSE + markers are present and
# the superseded phrasings are gone. What it does NOT cover: whether the model
# actually renders the router at runtime (that needs a live `/auto-task` run with
# the human gate) — same limitation the enforcement-spine test documents.
#
# Usage: tests/clarify-router.test.sh   (only needs grep)
# Exit 0 = all assertions passed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skills/auto-task/SKILL.md"
README="$ROOT/README.md"
CHANGELOG="$ROOT/CHANGELOG.md"

PASS=0; FAIL=0

# assert_ge <file> <min-count> <fixed-string>
assert_ge() {
  local file="$1" min="$2" pat="$3"
  local n; n="$(grep -Fc -- "$pat" "$file" 2>/dev/null)"; n="${n:-0}"
  if [ "$n" -ge "$min" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL: expected >=$min of [$pat] in $(basename "$file"), got $n"
  fi
}

# assert_absent <file> <fixed-string>   (superseded phrasing must be gone)
assert_absent() {
  local file="$1" pat="$2"
  local n; n="$(grep -Fc -- "$pat" "$file" 2>/dev/null)"; n="${n:-0}"
  if [ "$n" -eq 0 ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL: expected [$pat] ABSENT from $(basename "$file"), found $n"
  fi
}

# --- SKILL.md: router structure ---
assert_ge "$SKILL" 1 "<!-- CLARIFY-ROUTER-BEGIN -->"
assert_ge "$SKILL" 1 "<!-- CLARIFY-ROUTER-END -->"
assert_ge "$SKILL" 1 "Answer them here"
assert_ge "$SKILL" 1 "Give me a comment to forward"
assert_ge "$SKILL" 1 "This step runs only when the Asked bucket is non-empty"
assert_ge "$SKILL" 1 "Step 4b-answer"
assert_ge "$SKILL" 1 "Step 4b-forward"

# --- SKILL.md: forward-pause + resume mechanics ---
assert_ge "$SKILL" 1 "define-clarify-forwarded"
assert_ge "$SKILL" 3 "clarify_forward_pending"
assert_ge "$SKILL" 1 "resolved|asked|asked-forwarded"
# resume short-circuit MUST precede the mandatory router (guards the double-ask-loop fix)
assert_ge "$SKILL" 1 "Resume short-circuit (checked before the router)"
# origin discriminator MUST route clarify vs approach on resume (guards the mis-route fix)
assert_ge "$SKILL" 1 'kind: "clarify"'
assert_ge "$SKILL" 1 'kind: "approach"'

# ORDERING: the resume dispatcher/short-circuit MUST physically precede the mandatory Step 4a
# router (guards the double-ask-loop fix — presence alone is not enough; position is the invariant).
sc_line="$(grep -n -F 'Resume short-circuit (checked before the router)' "$SKILL" 2>/dev/null | head -1 | cut -d: -f1)"
s4a_line="$(grep -n -F 'Step 4a — routing question' "$SKILL" 2>/dev/null | head -1 | cut -d: -f1)"
if [ -n "$sc_line" ] && [ -n "$s4a_line" ] && [ "$sc_line" -lt "$s4a_line" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); echo "FAIL: resume short-circuit (line ${sc_line:-missing}) must precede Step 4a router (line ${s4a_line:-missing})"
fi

# --- SKILL.md: approach-fold reuses the router ---
assert_ge "$SKILL" 1 "routes through the CLARIFY-ROUTER"
assert_ge "$SKILL" 1 "the fold's forward branch reuses clarify_forward_pending"

# --- SKILL.md: reconciled contract prose (new yield-table rows + banner) ---
assert_ge "$SKILL" 1 "Phase 1 clarify routing question presented"
assert_ge "$SKILL" 1 "Phase 1 clarify — comment forwarded, awaiting owner's answers"
assert_ge "$SKILL" 1 "Phase 1 clarify resume — pending questions re-surfaced"
assert_ge "$SKILL" 1 "the Phase-1 clarify routing question and the forwarded-comment pause"

# --- SKILL.md: superseded phrasings gone ---
assert_absent "$SKILL" "single batch of clarifying"
assert_absent "$SKILL" "no new prompt, no new yield"
assert_absent "$SKILL" "render the paste-ready comment alongside it"
assert_absent "$SKILL" "<!-- TICKET-COMMENT-BEGIN -->"
assert_absent "$SKILL" "<!-- TICKET-COMMENT-END -->"

# --- README.md ---
assert_ge "$README" 1 "first asks how you want to handle them"
assert_absent "$README" "no new prompt and no new stop"

# --- CHANGELOG.md ---
assert_ge "$CHANGELOG" 1 "two-step clarify"

echo "----"
echo "clarify-router.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
