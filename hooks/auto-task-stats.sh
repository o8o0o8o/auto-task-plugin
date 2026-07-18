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
# Usage:  auto-task-stats.sh [STALE_DAYS] [--recalibrate]
#   STALE_DAYS (default 7, or $AUTO_TASK_STALL_DAYS): a live, approved, non-done
#   run whose newest history entry is older than this is classified "stalled";
#   otherwise "in-flight".
#   --recalibrate: additionally print a SUGGESTED estimate.sh coefficient
#   adjustment computed from pooled actual/estimate ratios (suggestion only — it
#   never edits estimate.sh; you apply it by hand). Gated behind a sample floor.
#
# Env-configurable thresholds (all optional; conservative defaults):
#   AUTO_TASK_STATS_MDE_PP        (default 15)  regression-guard minimum detectable
#                                               effect for RATE metrics, in percentage points
#   AUTO_TASK_STATS_RATIO_MDE     (default 0.5) MDE for est/act RATIO metrics (x)
#   AUTO_TASK_STATS_MIN_SAMPLE    (default 10)  min pooled runs PER VERSION before the
#                                               regression guard compares two versions
#   AUTO_TASK_STATS_RECAL_MIN_SAMPLE (default 10) min measured runs before --recalibrate suggests
# Exit 0 always (read-only; nothing to fail closed on).

set -uo pipefail

# --- Parse args: an optional numeric STALE_DAYS + an optional --recalibrate ----
RECAL=0
STALE_DAYS=""
for a in "$@"; do
  case "$a" in
    --recalibrate) RECAL=1 ;;
    *[!0-9]*|'') : ;;              # ignore non-numeric tokens
    *) [ -z "$STALE_DAYS" ] && STALE_DAYS="$a" ;;
  esac
done
[ -n "$STALE_DAYS" ] || STALE_DAYS="${AUTO_TASK_STALL_DAYS:-7}"
case "$STALE_DAYS" in ''|*[!0-9]*) STALE_DAYS=7 ;; esac

# Regression-guard + recalibration thresholds (env-overridable).
MDE_PP="${AUTO_TASK_STATS_MDE_PP:-15}";        case "$MDE_PP" in ''|*[!0-9]*) MDE_PP=15 ;; esac
MIN_SAMPLE="${AUTO_TASK_STATS_MIN_SAMPLE:-10}"; case "$MIN_SAMPLE" in ''|*[!0-9]*) MIN_SAMPLE=10 ;; esac
RECAL_MIN="${AUTO_TASK_STATS_RECAL_MIN_SAMPLE:-10}"; case "$RECAL_MIN" in ''|*[!0-9]*) RECAL_MIN=10 ;; esac
# ratio MDE is a float; validate and fall back to 0.5. Reject empty, any non
# [0-9.] char, or more than one dot — AND require at least one digit, so a lone
# "." (valid under the char-class test but NOT valid --argjson input, which would
# error the whole agg pass into a silently-blanked report) is caught.
RATIO_MDE="${AUTO_TASK_STATS_RATIO_MDE:-0.5}"
case "$RATIO_MDE" in ''|*[!0-9.]*|*.*.*) RATIO_MDE=0.5 ;; esac
case "$RATIO_MDE" in *[0-9]*) : ;; *) RATIO_MDE=0.5 ;; esac

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
      plugin_version: (.plugin_version // null),
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
# Rate metrics now carry a Wilson 95% score interval + sample size (a bare
# percentage over a handful of runs is not a trustworthy signal). Per-version
# groups feed the version-over-version regression guard, and pooled act/est ratios
# feed the (suggest-only) recalibration. All thresholds arrive from bash env.
agg="$(jq -s \
  --argjson mde_pp "$MDE_PP" \
  --argjson min_sample "$MIN_SAMPLE" \
  --argjson ratio_mde "$RATIO_MDE" \
  --argjson recal_min "$RECAL_MIN" \
  '
  def median: (map(. // 0) | sort) as $s | if ($s|length)==0 then 0 else $s[(($s|length-1)/2)|floor] end;
  # Wilson 95% score interval → {lo,hi} as percentages, or null when n<=0.
  def wilson(k; n):
    if (n <= 0) then null
    else
      (k/n) as $p | 1.96 as $z | (1.96*1.96) as $z2
      | (($p + $z2/(2*n)) / (1 + $z2/n)) as $c
      | (($z * ((($p*(1-$p) + $z2/(4*n))/n) | sqrt)) / (1 + $z2/n)) as $m
      | { lo: (((([($c-$m), 0] | max) * 1000) | round) / 10),
          hi: (((([($c+$m), 1] | min) * 1000) | round) / 10) }
    end;
  # A binomial rate over the row set: {k,n,pct,ci}. pct/ci null when n==0.
  def rate(cond):
    (map(select(cond)) | length) as $k | length as $n
    | { k: $k, n: $n,
        pct: (if $n==0 then null else (($k*1000/$n)|round)/10 end),
        ci: wilson($k; $n) };
  def vrate(cond): if length==0 then 0 else ((map(select(cond))|length)*1000/length|round)/10 end;
  length as $N
  | (map(select((.plugin_version | type) == "string" and .plugin_version != "" and .plugin_version != "unknown"))
     | group_by(.plugin_version)
     | map({ version: .[0].plugin_version, n: length,
             late:  vrate((.defects_late // 0) > 0),
             tests: vrate(.tests_added == true),
             flaky: vrate(.flaky == true),
             ratio_tokens: (map(select(((.est_tokens // 0) > 0) and ((.act_tokens // 0) > 0)) | (.act_tokens/.est_tokens)) | median),
             n_tok: (map(select(((.est_tokens // 0) > 0) and ((.act_tokens // 0) > 0))) | length) })
     | sort_by(.version | split(".") | map(tonumber? // 0))) as $versions
  | (map(select(((.est_tokens // 0) > 0) and ((.act_tokens // 0) > 0)) | (.act_tokens/.est_tokens)) | median) as $rtok
  | (map(select(((.est_tokens // 0) > 0) and ((.act_tokens // 0) > 0))) | length) as $ntok
  | (map(select(((.est_duration_min // 0) > 0) and ((.act_duration_min // 0) > 0)) | (.act_duration_min/.est_duration_min)) | median) as $rdur
  | (map(select(((.est_duration_min // 0) > 0) and ((.act_duration_min // 0) > 0))) | length) as $ndur
  | ($versions | map(select(.n >= $min_sample))) as $elig
  | {
    quality: {
      first_pass: ((map(.first_pass_ac // empty)) as $fp
        | { n: ($fp|length),
            mean_pct: (if ($fp|length)==0 then null else (($fp|add)/($fp|length)*1000|round)/10 end) }),
      late:  rate((.defects_late // 0) > 0),
      tests: rate(.tests_added == true),
      flaky: rate(.flaky == true),
      early_mean: (if $N==0 then null else ((map(.defects_early // 0)|add)/$N*100|round)/100 end)
    },
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
    ratio_tokens: $rtok, n_tok: $ntok,
    ratio_dur: $rdur, n_dur: $ndur,
    versions: $versions,
    regression: (
      if ($elig|length) < 2
      then { status: "insufficient", eligible: ($elig|length), total_versions: ($versions|length), min_sample: $min_sample }
      else ($elig[-2]) as $a | ($elig[-1]) as $b
        | { status: "ok", from: $a.version, to: $b.version, from_n: $a.n, to_n: $b.n,
            flags: (
              ([ { metric: "late-defect rate", from: $a.late,  to: $b.late,  delta: (((($b.late-$a.late)*10)|round)/10),   unit: "pp" },
                 { metric: "tests-added rate", from: $a.tests, to: $b.tests, delta: (((($b.tests-$a.tests)*10)|round)/10), unit: "pp" },
                 { metric: "flakiness rate",   from: $a.flaky, to: $b.flaky, delta: (((($b.flaky-$a.flaky)*10)|round)/10), unit: "pp" } ]
               | map(select((.delta|fabs) >= $mde_pp)))
              + (if ($a.n_tok > 0 and $b.n_tok > 0 and ((($b.ratio_tokens-$a.ratio_tokens))|fabs) >= $ratio_mde)
                 then [ { metric: "est/act token ratio", from: (($a.ratio_tokens*100|round)/100), to: (($b.ratio_tokens*100|round)/100), delta: (((($b.ratio_tokens-$a.ratio_tokens))*100|round)/100), unit: "x" } ]
                 else [] end)
            ) }
      end),
    recal: (
      if $ntok >= $recal_min
      then { suggest: true,  ratio_tokens: (($rtok*100|round)/100), n_tok: $ntok, ratio_dur: (($rdur*100|round)/100), n_dur: $ndur }
      else { suggest: false, n_tok: $ntok, need: $recal_min } end)
  }' "$rows" 2>/dev/null || echo '{}')"

terminal=$((done_count + stalled))
if [ "$terminal" -gt 0 ]; then
  comp_pct=$(( done_count * 100 / terminal ))
else
  comp_pct=0
fi

# Format a rate object {pct,ci,n} as "P% [lo–hi] (n=N)"; "n=0 (no data)" when empty.
fmt_rate(){ # $1 = jq path into $agg, e.g. .quality.late
  local obj n pct lo hi
  obj="$(printf '%s' "$agg" | jq -c "$1" 2>/dev/null || echo '{}')"
  n="$(printf '%s' "$obj" | jq -r '.n // 0' 2>/dev/null || echo 0)"
  pct="$(printf '%s' "$obj" | jq -r 'if .pct == null then "null" else (.pct|tostring) end' 2>/dev/null || echo null)"
  if [ "$n" = "0" ] || [ "$pct" = "null" ]; then printf 'n=0 (no data)'; return; fi
  lo="$(printf '%s' "$obj" | jq -r '.ci.lo // empty' 2>/dev/null || echo "")"
  hi="$(printf '%s' "$obj" | jq -r '.ci.hi // empty' 2>/dev/null || echo "")"
  if [ -n "$lo" ] && [ -n "$hi" ]; then printf '%s%% [%s–%s] (n=%s)' "$pct" "$lo" "$hi" "$n"
  else printf '%s%% (n=%s)' "$pct" "$n"; fi
}

echo "auto-task run stats  (stale threshold: ${STALE_DAYS}d)"
echo "===================================================="
printf '%d runs on record — %d done, %d stalled, %d in-flight\n' "$total" "$done_count" "$stalled" "$in_flight"
echo ""

# --- Quality (test-verified — THE headline) ---------------------------------
# What matters is whether runs produced test-verified, defect-free work — NOT
# whether they reached Handover. Completion is a liveness signal (further down),
# not a quality signal: an agent can reach "done" with a confidently-wrong result.
fp_n="$(printf '%s' "$agg" | jq -r '.quality.first_pass.n // 0' 2>/dev/null || echo 0)"
fp_mean="$(printf '%s' "$agg" | jq -r 'if (.quality.first_pass.mean_pct // null) == null then "n/a" else (.quality.first_pass.mean_pct|tostring) end' 2>/dev/null || echo n/a)"
early_mean="$(printf '%s' "$agg" | jq -r 'if (.quality.early_mean // null) == null then "n/a" else (.quality.early_mean|tostring) end' 2>/dev/null || echo n/a)"
echo "Quality (test-verified — the headline)"
if [ "$fp_n" = "0" ] || [ "$fp_mean" = "n/a" ]; then
  printf '  First-pass AC pass     n/a (no measured runs)\n'
else
  printf '  First-pass AC pass     %s%% mean (n=%s)\n' "$fp_mean" "$fp_n"
fi
printf '  Late-defect rate       %s   (Gate-B / code-review — lower is better)\n' "$(fmt_rate '.quality.late')"
printf '  Early-defect capture   %s avg per run (Gate-A / self-verify)\n' "$early_mean"
printf '  Tests-added rate       %s\n' "$(fmt_rate '.quality.tests')"
printf '  Flakiness rate         %s\n' "$(fmt_rate '.quality.flaky')"
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

# --- Liveness / operational (NOT a quality signal) --------------------------
# Completion = "reached Handover", which is construct-invalid as a quality metric:
# it looks healthy exactly when a confidently-wrong run should not be trusted. It
# lives here as an operational/liveness signal, paired with WHERE runs stall.
if [ "$terminal" -gt 0 ]; then
  comp_ci="$(printf '%s' "$agg" | jq -rn --argjson k "$done_count" --argjson n "$terminal" '
    def wilson(k;n): if n<=0 then null else (k/n) as $p | (1.96*1.96) as $z2
      | (($p+$z2/(2*n))/(1+$z2/n)) as $c
      | ((1.96*((($p*(1-$p)+$z2/(4*n))/n)|sqrt))/(1+$z2/n)) as $m
      | "[\((([($c-$m),0]|max)*1000|round)/10)–\((([($c+$m),1]|min)*1000|round)/10)]" end;
    wilson($k;$n) // ""' 2>/dev/null || echo "")"
else
  comp_ci=""
fi
echo "Liveness / operational (NOT a quality signal)"
printf '  Completion rate        %d%% %s (%d/%d terminal; in-flight excluded)\n' "$comp_pct" "$comp_ci" "$done_count" "$terminal"
echo "  Where stalled runs died"
if [ "$stalled" -eq 0 ]; then
  echo "    (none)"
else
  sed 's/^  /    /' "$stalled_list"
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

# --- Estimate accuracy (calibration input) -----------------------------------
rt="$(printf '%s' "$agg" | jq -r '(.ratio_tokens // 0) | (.*100|round)/100' 2>/dev/null || echo 0)"
rd="$(printf '%s' "$agg" | jq -r '(.ratio_dur // 0) | (.*100|round)/100' 2>/dev/null || echo 0)"
n_tok="$(printf '%s' "$agg" | jq -r '.n_tok // 0' 2>/dev/null || echo 0)"
n_dur="$(printf '%s' "$agg" | jq -r '.n_dur // 0' 2>/dev/null || echo 0)"

echo "Estimate accuracy (calibration input)"
if [ "$n_tok" -gt 0 ]; then
  printf '  tokens: actual/est median %sx (n=%s)\n' "$rt" "$n_tok"
else
  printf '  tokens: no measured runs yet\n'
fi
if [ "$n_dur" -gt 0 ]; then
  printf '  time:   actual/est median %sx (n=%s)\n' "$rd" "$n_dur"
fi
printf '  (median actual/est >1 means runs cost MORE than estimated; <1 means less. Pooled — read with the n.)\n'
echo ""

# --- Regression guard (version-over-version) ---------------------------------
# Compares the two most-recent plugin versions that each clear the sample floor,
# flagging a metric only when its delta exceeds the MDE. Small local ledgers will
# usually report "insufficient data" — that is the honest state, not a failure
# (required N scales with 1/effect^2, so only large shifts are ever detectable).
echo "Regression guard (version-over-version)"
reg_status="$(printf '%s' "$agg" | jq -r '.regression.status // "insufficient"' 2>/dev/null || echo insufficient)"
if [ "$reg_status" = "ok" ]; then
  reg_from="$(printf '%s' "$agg" | jq -r '.regression.from' 2>/dev/null)"
  reg_to="$(printf '%s' "$agg" | jq -r '.regression.to' 2>/dev/null)"
  reg_fn="$(printf '%s' "$agg" | jq -r '.regression.from_n' 2>/dev/null)"
  reg_tn="$(printf '%s' "$agg" | jq -r '.regression.to_n' 2>/dev/null)"
  nflags="$(printf '%s' "$agg" | jq -r '.regression.flags | length' 2>/dev/null || echo 0)"
  printf '  comparing v%s (n=%s) → v%s (n=%s), MDE %spp / %sx\n' "$reg_from" "$reg_fn" "$reg_to" "$reg_tn" "$MDE_PP" "$RATIO_MDE"
  if [ "$nflags" = "0" ]; then
    echo "  ✓ no metric moved beyond the MDE — no regression flagged"
  else
    printf '%s' "$agg" | jq -r '.regression.flags[] | "  ⚠ \(.metric): \(.from)\(if .unit=="pp" then "%" else "x" end) → \(.to)\(if .unit=="pp" then "%" else "x" end)  (Δ\(.delta)\(.unit))"' 2>/dev/null
  fi
else
  reg_elig="$(printf '%s' "$agg" | jq -r '.regression.eligible // 0' 2>/dev/null || echo 0)"
  reg_totv="$(printf '%s' "$agg" | jq -r '.regression.total_versions // 0' 2>/dev/null || echo 0)"
  printf '  insufficient data — need ≥2 plugin versions with ≥%s runs each (have %s eligible of %s version(s) on record)\n' "$MIN_SAMPLE" "$reg_elig" "$reg_totv"
fi
echo ""

# --- Recalibration suggestion (--recalibrate only; suggest-only, never edits) -
if [ "$RECAL" = "1" ]; then
  echo "Recalibration suggestion (estimate.sh — apply by hand; nothing is auto-edited)"
  recal_ok="$(printf '%s' "$agg" | jq -r '.recal.suggest // false' 2>/dev/null || echo false)"
  if [ "$recal_ok" = "true" ]; then
    rc_rt="$(printf '%s' "$agg" | jq -r '.recal.ratio_tokens' 2>/dev/null)"
    rc_nt="$(printf '%s' "$agg" | jq -r '.recal.n_tok' 2>/dev/null)"
    rc_rd="$(printf '%s' "$agg" | jq -r '.recal.ratio_dur' 2>/dev/null)"
    rc_nd="$(printf '%s' "$agg" | jq -r '.recal.n_dur' 2>/dev/null)"
    printf '  Pooled actual/est: tokens %sx (n=%s), time %sx (n=%s) — floor of %s met.\n' "$rc_rt" "$rc_nt" "$rc_rd" "$rc_nd" "$RECAL_MIN"
    # Suggest scaling the estimate.sh token/time constants by the pooled ratio.
    printf '%s' "$agg" | jq -rn --argjson rt "$rc_rt" '
      def s(v): (v*$rt)|round;
      "  Suggested TOKEN constants (× \($rt)):",
      "    TIER_BASE_TOK  light 300000→\(s(300000))  standard 900000→\(s(900000))  heavy 1800000→\(s(1800000))",
      "    PER_AC_TOK 40000→\(s(40000))   PER_FILE_TOK 50000→\(s(50000))"' 2>/dev/null
    printf '%s' "$agg" | jq -rn --argjson rd "$rc_rd" '
      def s(v): (v*$rd)|round;
      "  Suggested TIME constants (× \($rd)):",
      "    TIER_BASE_MIN  light 12→\(s(12))  standard 35→\(s(35))  heavy 70→\(s(70))",
      "    PER_AC_MIN 2→\(s(2))   PER_FILE_MIN 2→\(s(2))"' 2>/dev/null
    echo "  (Suggestion only — estimate.sh is unchanged. Review the n before applying; a small n is noisy.)"
  else
    rc_nt="$(printf '%s' "$agg" | jq -r '.recal.n_tok // 0' 2>/dev/null || echo 0)"
    printf '  Not enough measured runs to suggest a calibration — have %s, need ≥%s.\n' "$rc_nt" "$RECAL_MIN"
  fi
  echo ""
fi

exit 0
