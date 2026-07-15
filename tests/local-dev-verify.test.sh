#!/usr/bin/env bash
# Structural regression guard for LOCAL-DEV-FIRST VISUAL VERIFICATION (v0.12.0).
#
# v0.11.0 made "missing visual proof" a HARD BLOCKER in three spots and uploaded
# images via a fragile authenticated-browser user-attachments flow. v0.12.0
# reworks this: verify on local dev first (then preview), never hard-block
# (unreachable UI -> INCONCLUSIVE, embed failure -> note), mock/cut-corners to
# reach the REAL UI (scoped so it never replaces the visual observation), close
# Playwright sessions when done, and embed via an OPT-IN, visibility-aware
# dedicated GitHub assets repo instead of user-attachments.
#
# This pins the load-bearing literals so the rework can't silently regress.
# What it does NOT cover: runtime behavior (needs a live `/auto-task` run).
#
# Usage: tests/local-dev-verify.test.sh   (needs grep + the settings.sh helper)
# Exit 0 = all assertions passed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skills/auto-task/SKILL.md"
SETTINGS="$ROOT/hooks/settings.sh"
README="$ROOT/README.md"

PASS=0; FAIL=0

# assert_ge <file> <min-count> <fixed-string>
assert_ge() {
  local file="$1" min="$2" pat="$3"
  local n; n="$(grep -Fc -- "$pat" "$file" 2>/dev/null)"; n="${n:-0}"
  if [ "$n" -ge "$min" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: expected >=$min of [$pat] in $(basename "$file"), got $n"; fi
}
# assert_gei <file> <min-count> <pattern>   (case-insensitive)
assert_gei() {
  local file="$1" min="$2" pat="$3"
  local n; n="$(grep -ic -- "$pat" "$file" 2>/dev/null)"; n="${n:-0}"
  if [ "$n" -ge "$min" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: expected >=$min (ci) of [$pat] in $(basename "$file"), got $n"; fi
}
# assert_absent <file> <fixed-string>
assert_absent() {
  local file="$1" pat="$2"
  local n; n="$(grep -Fc -- "$pat" "$file" 2>/dev/null)"; n="${n:-0}"
  if [ "$n" -eq 0 ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: expected [$pat] ABSENT from $(basename "$file"), found $n"; fi
}
# assert_eq_cmd <expected> <description> <cmd...>
assert_eq_cmd() {
  local expected="$1" desc="$2"; shift 2
  local got; got="$("$@" 2>/dev/null)"
  if [ "$got" = "$expected" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $desc — expected [$expected], got [$got]"; fi
}

# --- AC1/AC2/AC8: the three v0.11.0 visual-proof HARD BLOCKS are gone ---
assert_absent "$SKILL" "the user chose blocking over silent degradation"
assert_absent "$SKILL" "this becomes a Phase 5 hard blocker"
# Only the 3 unrelated "hard blocker" mentions may remain (frontmatter, component
# preflight, bot-push fail-open) — none tied to visual proof. Guard the count.
hb="$(grep -c "hard blocker" "$SKILL" 2>/dev/null)"; hb="${hb:-0}"
if [ "$hb" -le 3 ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "FAIL: expected <=3 'hard blocker' mentions (unrelated only), got $hb"; fi
# and the embedding step must explicitly never block
assert_ge "$SKILL" 1 "nothing in this step ever blocks the run"

# --- AC3 / rule 9: local-dev-first, then preview (AC contract + Phase 3) ---
assert_gei "$SKILL" 2 "local dev first"
assert_ge  "$SKILL" 1 "Local dev first, then preview"

# --- AC4 / rule 8: mock/cut-corners scoped to reaching the REAL UI ---
assert_ge "$SKILL" 1 "mock/seed data or cut corners to reach the *real* UI"
assert_ge "$SKILL" 1 "may NEVER stand in *for* the visual observation"
assert_ge "$SKILL" 1 "data-dependent"

# --- AC5 / R4: dev-server reuse-or-improvise-else-surface + retained no-auto rule ---
assert_ge "$SKILL" 1 "reuse-or-improvise-else-surface"
assert_ge "$SKILL" 1 "auto-start the project's long-running dev server"
assert_ge "$SKILL" 1 "disposable render"

# --- AC6 / R5: close Playwright sessions when done ---
assert_ge "$SKILL" 2 "browser_close"

# --- AC7 / R6: assets-repo mechanism REPLACES user-attachments everywhere ---
assert_absent "$SKILL" "user-attachments"
assert_ge "$SKILL" 1 "raw.githubusercontent.com/<assets_repo>"
assert_ge "$SKILL" 2 "visual_assets_repo"

# --- AC11/AC14: visibility-aware embedding (public inline / private links) ---
assert_ge "$SKILL" 1 "visual_assets_visibility"
assert_ge "$SKILL" 1 "member-only blob-view links"
assert_ge "$SKILL" 1 "default branch"

# --- AC15: embedding failure modes fall back to a note, never a STOP ---
assert_ge "$SKILL" 1 "fall back to a note, NEVER a STOP"
assert_ge "$SKILL" 1 "fork PR"

# --- AC17/AC18 / R9: explicit per-project opt-in, off by default, gated ---
assert_ge "$SKILL" 1 "Visual-assets consent check"
assert_ge "$SKILL" 1 "visual_assets_enabled"
assert_ge "$SKILL" 1 "Opt-in gate"

# --- AC10/AC16: settings keys are first-class (defaults + discoverable) ---
assert_eq_cmd "false"  "visual_assets_enabled default"    bash "$SETTINGS" get visual_assets_enabled
assert_eq_cmd "public" "visual_assets_visibility default" bash "$SETTINGS" get visual_assets_visibility
keys_hit="$(bash "$SETTINGS" keys 2>/dev/null | grep -c 'visual_assets_')"; keys_hit="${keys_hit:-0}"
if [ "$keys_hit" -eq 3 ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "FAIL: expected 3 visual_assets_* keys via 'settings.sh keys', got $keys_hit"; fi

# --- README documents the feature ---
assert_ge "$README" 1 "visual_assets_enabled"

echo "----------------------------------------"
echo "local-dev-verify: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
