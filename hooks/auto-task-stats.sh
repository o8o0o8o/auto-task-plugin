#!/usr/bin/env bash
# auto-task-stats — read-only aggregator over auto-task run outcomes.
#
# NOT a hook. A standalone maintainer tool (wrapped by the auto-task-stats skill)
# that answers: what is auto-task's completion rate, and where do runs stall?
#
# It reads two sources and merges them:
#   1. .auto-task/outcomes.jsonl  — the append-only archive of COMPLETED runs
#      (written by the record-outcome.sh Stop hook; survives folder pruning).
#   2. every live .auto-task/*/STATE.json on disk — so in-flight and stalled runs
#      (which never reach the archive) are still counted, and a just-completed
#      run that predates opt-in is picked up.
#
# Dedup is on branch+base (a run's identity), NOT branch alone: a reused branch
# folder forks a new base, so a fresh run must count separately — keying on
# branch alone would collapse it into the old archived row (the same branch-reuse
# bug record-outcome.sh's base-scoped sentinel avoids).
#
# Forward-compat: every field is read with a `// <default>`, so a row written by
# an older or newer schema (missing a field) is tolerated, never a hard error.
#
# Usage:  auto-task-stats.sh [STALE_DAYS]
#   STALE_DAYS (default 7, or $AUTO_TASK_STALL_DAYS): a live, approved, non-done
#   run whose newest history entry is older than this is classified "stalled";
#   otherwise "in-flight".
# Exit 0 always (read-only; nothing to fail closed on).

set -uo pipefail

STALE_DAYS="${1:-${AUTO_TASK_STALL_DAYS:-7}}"
case "$STALE_DAYS" in ''|*[!0-9]*) STALE_DAYS=7 ;; esac

if ! command -v jq >/dev/null 2>&1; then
  echo "auto-task-stats: jq is not installed (a hard prerequisite of this plugin). Install jq and retry."
  exit 0
fi

# Resolve the project root that owns .auto-task/.
project_dir_base="${CLAUDE_PROJECT_DIR:-$PWD}"
project_dir="$(cd "$project_dir_base" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$project_dir" ] || project_dir="$project_dir_base"

AT="$project_dir/.auto-task"
ledger="$AT/outcomes.jsonl"

if [ ! -d "$AT" ]; then
  echo "auto-task-stats: no .auto-task/ directory under $project_dir — nothing to report."
  exit 0
fi

# The archiver-equivalent derivation: normalize a done STATE.json into a row so
# live-but-unarchived done runs are counted identically to archived ones. Kept in
# lockstep with record-outcome.sh's jq derivation — the metric fields (est_*/act_*
# + quality-signal trend fields) MUST match that block VERBATIM (a regression test
# asserts the two field sets are identical). est_*/act_* are `null` when unmeasured
# so the accuracy ratio below can exclude them.
DERIVE='
  (.history // []) as $h
  | ($h | map(.at // empty)) as $ats
  | ($ats | first) as $t0
  | ($ats | last) as $t1
  | (if ($t0 != null and $t1 != null)
       then (((($t1 | fromdateiso8601?) // 0) - (($t0 | fromdateiso8601?) // 0)) / 60 | floor)
       else 0 end) as $dur
  | {
      at: ($t1 // ""),
      branch: (.branch // ""),
      base: (.base // ""),
      pr_url: (.pr_url // null),
      terminal_state: "done",
      tier: (.effort.tier // ""),
      tier_initial: (((.effort.history // []) | first | .from) // (.effort.tier // "")),
      escalations: ((.effort.history // []) | length),
      fix_iterations: (.iteration.fix // 0),
      review_iterations: (.iteration.review // 0),
      gate_b: (if (.gates.gate_b.passed // false) then "passed" else ((.gates.gate_b.skipped_reason // "") | .[0:120]) end),
      followups: ((.followups // []) | length),
      duration_min: $dur,
      est_duration_min: (.estimate.duration_min // null),
      est_tokens: (.estimate.tokens_total // null),
      act_duration_min: (.actuals.duration_min // $dur),
      act_tokens: (.actuals.tokens_total // null),
      defects_early: (.quality.defects.early // 0),
      defects_late: (.quality.defects.late // 0),
      flaky: (.quality.flaky // false),
      tests_added: (.quality.tests_added // false),
      diff_loc: (((.quality.diff.loc_added // 0) + (.quality.diff.loc_removed // 0))),
      first_pass_ac: (.quality.planning.first_pass_ac // null),
      checks_run: ((.checks // []) | length),
      checks_failed: ((.checks // []) | map(select(.result=="fail")) | length)
    }'

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
rows="$tmp/rows.jsonl"        # deduped DONE rows (archive + live-done)
: > "$rows"
seen="$tmp/seen"; : > "$seen" # branch<TAB>base identities already counted

now="$(date +%s)"
cutoff=$(( now - STALE_DAYS * 86400 ))

in_flight=0
stalled=0
stalled_list="$tmp/stalled.txt"; : > "$stalled_list"

norm_key(){ printf '%s\t%s' "$1" "$2"; }

# 1. Archive rows (each line one row). Normalize field defaults through jq.
# `|| [ -n "$line" ]` so a final row lacking a trailing newline is not dropped.
if [ -f "$ledger" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    printf '%s' "$line" | jq empty 2>/dev/null || continue
    br="$(printf '%s' "$line" | jq -r '.branch // ""' 2>/dev/null || echo "")"
    ba="$(printf '%s' "$line" | jq -r '.base // ""' 2>/dev/null || echo "")"
    key="$(norm_key "$br" "$ba")"
    grep -qxF "$key" "$seen" 2>/dev/null && continue
    printf '%s\n' "$key" >> "$seen"
    printf '%s\n' "$line" >> "$rows"
  done < "$ledger"
fi

# 2. Live STATE.json files (branch may contain slashes → use find).
while IFS= read -r sf; do
  [ -n "$sf" ] || continue
  [ -f "$sf" ] || continue
  jq empty "$sf" 2>/dev/null || continue
  approved="$(jq -r '.approved // false' "$sf" 2>/dev/null || echo false)"
  phase="$(jq -r '.phase // ""' "$sf" 2>/dev/null || echo "")"
  br="$(jq -r '.branch // ""' "$sf" 2>/dev/null || echo "")"
  ba="$(jq -r '.base // ""' "$sf" 2>/dev/null || echo "")"

  if [ "$phase" = "done" ]; then
    key="$(norm_key "$br" "$ba")"
    grep -qxF "$key" "$seen" 2>/dev/null && continue   # already archived → ledger wins
    printf '%s\n' "$key" >> "$seen"
    jq -c "$DERIVE" "$sf" 2>/dev/null >> "$rows" || true
    continue
  fi

  # Non-done: only count runs that actually started (approved).
  [ "$approved" = "true" ] || continue
  newest="$(jq -r '[.history[]?.at // empty] | map(fromdateiso8601? // 0) | max // 0' "$sf" 2>/dev/null || echo 0)"
  case "$newest" in ''|*[!0-9]*) newest=0 ;; esac
  if [ "$newest" -ge "$cutoff" ] && [ "$newest" -gt 0 ]; then
    in_flight=$((in_flight + 1))
  else
    stalled=$((stalled + 1))
    last_phase="$(jq -r '(.history // []) | last | (.phase // .result // "unknown")' "$sf" 2>/dev/null || echo unknown)"
    last_sum="$(jq -r '(.history // []) | last | (.summary // .result // "")' "$sf" 2>/dev/null || echo "")"
    printf '  %s @ phase=%s — %s\n' "${br:-?}" "$last_phase" "$last_sum" >> "$stalled_list"
  fi
done <<< "$(find "$AT" -name STATE.json 2>/dev/null)"

done_count="$(wc -l < "$rows" | tr -d ' ')"
total=$((done_count + stalled + in_flight))

# --- Empty-ledger / no-runs guard (never divide by zero) ---------------------
if [ "$total" -eq 0 ]; then
  echo "auto-task run stats"
  echo "==================="
  if [ ! -f "$ledger" ]; then
    echo "No runs recorded yet, and telemetry is not opted in."
    echo "Opt in with:  touch \"$ledger\""
    echo "Then complete an /auto-task run to populate it."
  else
    echo "No runs recorded yet — the ledger is empty and no live runs are on disk."
    echo "Complete an /auto-task run to populate it."
  fi
  exit 0
fi

# --- Aggregate the done-row population in one jq pass -------------------------
agg="$(jq -s '
  def median: (map(. // 0) | sort) as $s | if ($s|length)==0 then 0 else $s[(($s|length-1)/2)|floor] end;
  {
    tiers: (group_by(.tier) | map({
        tier: (.[0].tier // "?"),
        n: length,
        med_fix: (map(.fix_iterations // 0) | median),
        med_review: (map(.review_iterations // 0) | median),
        pct_escalated: (if length==0 then 0 else ((map(select((.escalations // 0) > 0)) | length) * 100 / length | floor) end)
      })),
    sh_total: (map(select(.tier=="standard" or .tier=="heavy")) | length),
    sh_ran: (map(select((.tier=="standard" or .tier=="heavy") and (.gate_b=="passed"))) | length),
    pct_misscored: (if length==0 then 0 else ((map(select((.escalations // 0) > 0)) | length) * 100 / length | floor) end),
    avg_followups: (if length==0 then 0 else ((map(.followups // 0) | add) / length) end),
    ratio_tokens: (map(select(((.est_tokens // 0) > 0) and ((.act_tokens // 0) > 0)) | (.act_tokens / .est_tokens)) | median),
    n_tok: (map(select(((.est_tokens // 0) > 0) and ((.act_tokens // 0) > 0))) | length),
    ratio_dur: (map(select(((.est_duration_min // 0) > 0) and ((.act_duration_min // 0) > 0)) | (.act_duration_min / .est_duration_min)) | median),
    n_dur: (map(select(((.est_duration_min // 0) > 0) and ((.act_duration_min // 0) > 0))) | length),
    late_rate: (if length==0 then 0 else ((map(select((.defects_late // 0) > 0)) | length) * 100 / length | floor) end),
    flaky_rate: (if length==0 then 0 else ((map(select(.flaky == true)) | length) * 100 / length | floor) end),
    tests_rate: (if length==0 then 0 else ((map(select(.tests_added == true)) | length) * 100 / length | floor) end)
  }' "$rows" 2>/dev/null || echo '{}')"

terminal=$((done_count + stalled))
if [ "$terminal" -gt 0 ]; then
  comp_pct=$(( done_count * 100 / terminal ))
else
  comp_pct=0
fi

echo "auto-task run stats  (stale threshold: ${STALE_DAYS}d)"
echo "===================================================="
printf '%d runs on record — %d done, %d stalled, %d in-flight\n' "$total" "$done_count" "$stalled" "$in_flight"
printf 'Completion rate    %d%%  (%d/%d terminal; in-flight excluded)\n' "$comp_pct" "$done_count" "$terminal"
echo ""

# --- Merge acceptance: the REAL success signal ------------------------------
# A completed run only OPENS a PR; whether it MERGED is decided later, off-machine.
# The PR-opened count is derived locally from the done rows; merge state is
# resolved best-effort via `gh` HERE in the reader (never in the no-network
# record-outcome hook). AUTO_TASK_PR_RESOLVE=0 disables the lookup (tests, offline);
# it also short-circuits when gh is absent/unauthenticated, so the local
# "opened a PR" count always prints even when the merge rate cannot.
pr_urls="$(jq -r '.pr_url // empty' "$rows" 2>/dev/null | sed '/^null$/d;/^$/d')"
pr_total=0; [ -n "$pr_urls" ] && pr_total="$(printf '%s\n' "$pr_urls" | wc -l | tr -d ' ')"
resolve="${AUTO_TASK_PR_RESOLVE:-1}"
echo "Merge acceptance"
if [ "$pr_total" -eq 0 ]; then
  echo "  No completed run has opened a PR yet."
elif [ "$resolve" = "1" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  merged=0; closed=0; opened=0; unresolved=0
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    st="$(gh pr view "$url" --json state --jq '.state' 2>/dev/null || echo "")"
    case "$st" in
      MERGED) merged=$((merged+1)) ;;
      CLOSED) closed=$((closed+1)) ;;
      OPEN)   opened=$((opened+1)) ;;
      *)      unresolved=$((unresolved+1)) ;;
    esac
  done <<< "$pr_urls"
  decided=$((merged + closed))
  printf '  %d of %d completed runs opened a PR\n' "$pr_total" "$done_count"
  printf '  Merged %d · closed-unmerged %d · still open %d · unresolved %d\n' "$merged" "$closed" "$opened" "$unresolved"
  if [ "$decided" -gt 0 ]; then
    printf '  Merge-acceptance rate  %d%%  (%d/%d decided PRs merged)\n' "$(( merged * 100 / decided ))" "$merged" "$decided"
  else
    printf '  Merge-acceptance rate  n/a  (no opened PR has merged or closed yet)\n'
  fi
else
  printf '  %d of %d completed runs opened a PR\n' "$pr_total" "$done_count"
  if [ "$resolve" = "1" ]; then
    echo "  (merge state unresolved — gh CLI unavailable or unauthenticated; run from an authenticated gh to populate the acceptance rate)"
  else
    echo "  (merge-state resolution disabled via AUTO_TASK_PR_RESOLVE=0)"
  fi
fi
echo ""

echo "Where stalled runs died"
if [ "$stalled" -eq 0 ]; then
  echo "  (none)"
else
  cat "$stalled_list"
fi
echo ""

echo "By tier"
printf '  %-10s %5s %11s %14s %11s\n' "tier" "#done" "med fix" "med review" "escalated"
printf '%s' "$agg" | jq -r '.tiers[]? | "  \(.tier|.[0:10]) \(.n) \(.med_fix) \(.med_review) \(.pct_escalated)"' 2>/dev/null \
  | while read -r t n mf mr pe; do printf '  %-10s %5s %11s %14s %10s%%\n' "$t" "$n" "$mf" "$mr" "$pe"; done
[ "$done_count" -eq 0 ] && echo "  (no completed runs yet)"
echo ""

sh_total="$(printf '%s' "$agg" | jq -r '.sh_total // 0' 2>/dev/null || echo 0)"
sh_ran="$(printf '%s' "$agg" | jq -r '.sh_ran // 0' 2>/dev/null || echo 0)"
sh_skipped=$(( sh_total - sh_ran ))
[ "$sh_skipped" -lt 0 ] && sh_skipped=0
pct_misscored="$(printf '%s' "$agg" | jq -r '.pct_misscored // 0' 2>/dev/null || echo 0)"
avg_followups="$(printf '%s' "$agg" | jq -r '(.avg_followups // 0) | (.*10|round)/10' 2>/dev/null || echo 0)"

printf 'Gate B coverage        ran on %s/%s standard+heavy runs (%s skipped)\n' "$sh_ran" "$sh_total" "$sh_skipped"
printf 'Effort mis-scoring     %s%% of completed runs escalated tier mid-run\n' "$pct_misscored"
printf 'Follow-up debt         %s parked follow-ups per completed run (avg)\n' "$avg_followups"
echo ""

# --- Run metrics: estimate accuracy + quality-signal trends ------------------
rt="$(printf '%s' "$agg" | jq -r '(.ratio_tokens // 0) | (.*100|round)/100' 2>/dev/null || echo 0)"
rd="$(printf '%s' "$agg" | jq -r '(.ratio_dur // 0) | (.*100|round)/100' 2>/dev/null || echo 0)"
n_tok="$(printf '%s' "$agg" | jq -r '.n_tok // 0' 2>/dev/null || echo 0)"
n_dur="$(printf '%s' "$agg" | jq -r '.n_dur // 0' 2>/dev/null || echo 0)"
late_rate="$(printf '%s' "$agg" | jq -r '.late_rate // 0' 2>/dev/null || echo 0)"
flaky_rate="$(printf '%s' "$agg" | jq -r '.flaky_rate // 0' 2>/dev/null || echo 0)"
tests_rate="$(printf '%s' "$agg" | jq -r '.tests_rate // 0' 2>/dev/null || echo 0)"

echo "Run metrics (estimate vs actual, quality signals)"
if [ "$n_tok" -gt 0 ]; then
  printf 'Estimate accuracy      tokens: actual/est median %sx (n=%s)\n' "$rt" "$n_tok"
else
  printf 'Estimate accuracy      tokens: no measured runs yet\n'
fi
if [ "$n_dur" -gt 0 ]; then
  printf '                       time:   actual/est median %sx (n=%s)\n' "$rd" "$n_dur"
fi
printf 'Late-defect rate       %s%% of completed runs had a late (Gate-B) defect\n' "$late_rate"
printf 'Flakiness rate         %s%% of completed runs hit a flaky test\n' "$flaky_rate"
printf 'Tests-added rate       %s%% of completed runs touched a test file\n' "$tests_rate"
printf '(A median actual/est ratio >1 means runs cost MORE than estimated; <1 means less.)\n'

exit 0
