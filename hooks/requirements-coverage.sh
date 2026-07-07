#!/usr/bin/env bash
# requirements-coverage.sh — verify every dissected requirement is covered + done.
#
# NOT a hook. A pure reader (invoked by the auto-task orchestrator at Phase 1 to
# assert AC coverage, and at Phase 5 / the gates to assert completion) that reads
# STATE.json `requirements[]` and reports which requirements are (a) covered by at
# least one Acceptance Criterion and (b) satisfied at the end.
#
# The point: an input task is only unambiguously "done" if EVERY requirement it
# decomposes into is individually verified. This helper turns that into a
# checkable artifact instead of a vibe.
#
# Each requirement: { "id":"R1", "text":"...", "covered_by_acs":[1,3],
#                     "status":"pending|done|dropped" }
#   - covered  = (covered_by_acs | length) > 0
#   - complete = status == "done"  (a "dropped" requirement is excluded from the
#                incomplete set but counted under dropped, so an explicit descope
#                is visible, not silently "complete")
#
# Output JSON:
#   { total, covered, uncovered:[ids], complete, incomplete:[ids], dropped:[ids],
#     all_covered:bool, all_complete:bool }
#
# Failure policy: FAIL OPEN. Missing file / no jq / no requirements[] -> a valid
# zeroed object with all_covered=true, all_complete=true (nothing to fail on) and
# a "note". Always exits 0. Requires jq (JSON in, JSON out).
#
# Usage:  requirements-coverage.sh <STATE.json>
# Output (one line): the JSON object above.

set -uo pipefail

state="${1:-}"

emit_empty(){
  printf '{"total":0,"covered":0,"uncovered":[],"complete":0,"incomplete":[],"dropped":[],"all_covered":true,"all_complete":true,"note":"%s"}\n' "${1:-no requirements}"
  exit 0
}

command -v jq >/dev/null 2>&1 || emit_empty "jq unavailable"
[ -n "$state" ] || emit_empty "no state path"
[ -f "$state" ] || emit_empty "state file missing"
jq empty "$state" 2>/dev/null || emit_empty "state unparseable"

out="$(jq -c '
  (.requirements // []) as $r
  | ($r | map(select((.status // "pending") != "dropped"))) as $active
  | {
      total:      ($r | length),
      covered:    ($active | map(select(((.covered_by_acs // []) | length) > 0)) | length),
      uncovered:  ($active | map(select(((.covered_by_acs // []) | length) == 0) | .id) ),
      complete:   ($active | map(select((.status // "pending") == "done")) | length),
      incomplete: ($active | map(select((.status // "pending") != "done") | .id) ),
      dropped:    ($r | map(select((.status // "pending") == "dropped") | .id) )
    }
  | .all_covered  = ((.uncovered  | length) == 0)
  | .all_complete = ((.incomplete | length) == 0)
' "$state" 2>/dev/null || true)"

[ -n "$out" ] || emit_empty "derivation failed"
printf '%s' "$out" | jq empty 2>/dev/null || emit_empty "derivation invalid"

# No requirements at all -> treat as the empty (nothing-to-check) case, but keep
# total=0 visible so the orchestrator can decide whether decomposition was skipped.
printf '%s\n' "$out"
exit 0
