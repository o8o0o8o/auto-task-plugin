#!/usr/bin/env bash
# Behavioral tests for the v0.23.0 telemetry RESHAPE in auto-task-stats.sh:
#   - test-verified quality is the HEADLINE; completion is demoted to a labeled
#     liveness/operational signal (ordering + label).
#   - rate metrics carry a Wilson CI + sample size; n=0 populations are safe.
#   - version-over-version regression guard: flags >=MDE, silent on sub-MDE,
#     "insufficient data" below the sample floor or with a single version.
#   - thresholds are env-overridable.
#   - --recalibrate SUGGESTS estimate.sh constants (suggest-only; never edits it).
# Usage: tests/stats-reshape.test.sh   Exit 0 = all passed.

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
STATS="$HOOKS/auto-task-stats.sh"; EST="$HOOKS/estimate.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-54s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-54s got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }
has(){ if printf '%s' "$2" | grep -qE -- "$3"; then PASS=$((PASS+1)); printf '  PASS  %-54s (found)\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-54s (missing rx: %s)\n' "$1" "$3"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qE -- "$3"; then FAIL=$((FAIL+1)); printf '  FAIL  %-54s (unexpected rx: %s)\n' "$1" "$3"
  else PASS=$((PASS+1)); printf '  PASS  %-54s (absent)\n' "$1"; fi; }

# Emit N done rows for a plugin_version. $1=ver $2=count $3=late_count
# $4=est_tok $5=act_tok . flaky/tests fixed; est/act duration fixed.
#
# $5 is the OUTPUT token actual — it lands in `act_tokens_output`, which is what
# the est/act ratio divides by `est_tokens` (both output-scale). `act_tokens` is
# separately set to 200x that, standing in for the cache_read-dominated grand
# total a real run records. That 200x gap is deliberate and load-bearing: if the
# ratio were ever repointed back at `act_tokens`, every ratio assertion below
# would shift by 200x and fail loudly instead of silently comparing mismatched
# units. A row must also CARRY act_tokens_output to be ratio-eligible at all —
# absence marks a pre-recalibration row the reader excludes on purpose.
emit(){ local ver="$1" n="$2" lc="$3" et="$4" at="$5" i late dl att
  att=$(( at * 200 ))
  for i in $(seq 1 "$n"); do
    late=0; [ "$i" -le "$lc" ] && late=1
    printf '{"at":"2026-05-01T10:00:00Z","branch":"feat/%s-%d","base":"%s-%d","plugin_version":"%s","terminal_state":"done","tier":"standard","tier_initial":"standard","escalations":0,"fix_iterations":1,"review_iterations":1,"gate_b":"passed","followups":0,"duration_min":40,"est_duration_min":40,"est_tokens":%s,"act_duration_min":52,"act_tokens":%s,"act_tokens_output":%s,"defects_early":2,"defects_late":%d,"flaky":false,"tests_added":true,"diff_loc":80,"first_pass_ac":0.8,"checks_run":5,"checks_failed":0,"pr_url":null}\n' \
      "$ver" "$i" "$ver" "$i" "$ver" "$et" "$att" "$at" "$late"
  done
}
mkproj(){ local d; d="$(mktemp -d)"; ( cd "$d" && git init -q && git checkout -q -b main ); mkdir -p "$d/.auto-task"; printf '%s' "$d"; }
runs(){ AUTO_TASK_PR_RESOLVE=0 CLAUDE_PROJECT_DIR="$1" bash "$STATS" "${@:2}" 2>&1; }

echo "================ headline ordering + liveness demotion (AC#1) ================"
P1="$(mkproj)"; emit 0.22.0 12 2 900000 1000000 > "$P1/.auto-task/outcomes.jsonl"
O1="$(runs "$P1")"
nq="$(printf '%s\n' "$O1" | grep -n 'Quality (test-verified' | head -1 | cut -d: -f1)"
nc="$(printf '%s\n' "$O1" | grep -n 'Completion rate' | head -1 | cut -d: -f1)"
expect "quality header precedes completion (Nq<Nc)" "$([ -n "$nq" ] && [ -n "$nc" ] && [ "$nq" -lt "$nc" ] && echo yes || echo no)" "yes"
has "completion labeled liveness/operational"      "$O1" 'Liveness / operational \(NOT a quality signal\)'
has "completion line still present"                "$O1" 'Completion rate +[0-9]+%'

echo "================ Wilson CI + sample size on rate metrics (AC#2a) ================"
has "late-defect rate carries CI + n"  "$O1" 'Late-defect rate +[0-9.]+% \[[0-9.]+–[0-9.]+\] \(n=12\)'
has "tests-added rate carries CI + n"  "$O1" 'Tests-added rate +[0-9.]+% \[[0-9.]+–[0-9.]+\] \(n=12\)'
has "completion rate carries CI"       "$O1" 'Completion rate +[0-9]+% \[[0-9.]+–[0-9.]+\]'

echo "================ n=0 population is safe, no NaN (AC#2b) ================"
# A project with only a live in-flight run and an empty ledger: total>0, done=0,
# so agg runs over an empty row set → every rate population is 0.
P0="$(mkproj)"; : > "$P0/.auto-task/outcomes.jsonl"
mkdir -p "$P0/.auto-task/feat/live"
cat > "$P0/.auto-task/feat/live/STATE.json" <<EOF
{"phase":"execute","approved":true,"branch":"feat/live","base":"LIVE","history":[{"phase":"execute","result":"ok","at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}]}
EOF
O0="$(runs "$P0"; echo "EXIT=$?")"
has  "n=0 rate prints 'n=0 (no data)'" "$O0" 'Late-defect rate +n=0 \(no data\)'
hasnt "no NaN in output"               "$O0" 'nan|NaN|null%'
has  "exits 0 on n=0"                   "$O0" 'EXIT=0'

echo "================ regression guard: flag / sub-MDE / sparse / single (AC#7) ================"
# (a) two versions >=floor, late 16.7% -> 50% (Δ33.3pp) AND token ratio 1.1x->2x
PA="$(mkproj)"; { emit 0.22.0 12 2 900000 1000000; emit 0.23.0 12 6 900000 1800000; } > "$PA/.auto-task/outcomes.jsonl"
OA="$(runs "$PA")"
has "(a) flags late-defect >=MDE"   "$OA" '⚠ late-defect rate: 16.7% → 50%'
has "(a) flags token ratio >=MDE"   "$OA" '⚠ est/act token ratio:'
# (b) two versions >=floor, late 8.3% -> 16.7% (Δ8.3pp < 15) and SAME token ratio
PB="$(mkproj)"; { emit 0.22.0 12 1 900000 1000000; emit 0.23.0 12 2 900000 1000000; } > "$PB/.auto-task/outcomes.jsonl"
OB="$(runs "$PB")"
has  "(b) sub-MDE: no regression flagged" "$OB" 'no metric moved beyond the MDE'
hasnt "(b) sub-MDE: not 'insufficient'"   "$OB" 'insufficient data'
# (c) sparse: <floor per version
PC="$(mkproj)"; { emit 0.22.0 3 1 900000 1000000; emit 0.23.0 3 2 900000 1000000; } > "$PC/.auto-task/outcomes.jsonl"
has "(c) sparse -> insufficient data" "$(runs "$PC")" 'insufficient data'
# (d) single version only
PD="$(mkproj)"; emit 0.23.0 12 4 900000 1000000 > "$PD/.auto-task/outcomes.jsonl"
has "(d) single version -> insufficient" "$(runs "$PD")" 'insufficient data'

echo "================ thresholds env-overridable (AC#9) ================"
# same flagging fixture as (a); MDE=99pp + ratio 9x suppresses every flag
O_hi="$(AUTO_TASK_PR_RESOLVE=0 AUTO_TASK_STATS_MDE_PP=99 AUTO_TASK_STATS_RATIO_MDE=9 CLAUDE_PROJECT_DIR="$PA" bash "$STATS" 2>&1)"
has  "MDE=99 suppresses the flag" "$O_hi" 'no metric moved beyond the MDE'
hasnt "MDE=99: no late-defect flag" "$O_hi" '⚠ late-defect rate'
# min-sample override: raise floor to 20 -> the 12/12 fixture becomes insufficient
O_ms="$(AUTO_TASK_PR_RESOLVE=0 AUTO_TASK_STATS_MIN_SAMPLE=20 CLAUDE_PROJECT_DIR="$PA" bash "$STATS" 2>&1)"
has "MIN_SAMPLE=20 -> insufficient" "$O_ms" 'insufficient data'

echo "================ recalibration is suggest-only (AC#8) ================"
# n_tok=24 >= floor -> SUGGEST printed; NOT printed without --recalibrate
O_norec="$(runs "$PA")"
hasnt "no recal section without flag" "$O_norec" 'Recalibration suggestion'
O_rec="$(runs "$PA" --recalibrate)"
has "recal: suggestion header"       "$O_rec" 'Recalibration suggestion'
has "recal: suggests TOKEN constants" "$O_rec" 'Suggested TOKEN constants'
has "recal: names TIER_BASE_TOK"      "$O_rec" 'TIER_BASE_TOK'
has "recal: states suggestion-only"   "$O_rec" 'estimate.sh is unchanged'
# below floor -> refuses to suggest
O_low="$(runs "$PC" --recalibrate)"
has "recal below floor: refuses"      "$O_low" 'Not enough measured runs'
# estimate.sh was NOT edited by --recalibrate (suggest-only): constants intact.
#
# Keyed to whatever constant estimate.sh CURRENTLY declares, never to a frozen
# literal. The previous version asserted the literal `1800000`, which meant the
# check had to be hand-edited on every recalibration — and a stale literal here
# would have failed for the wrong reason (constant changed) rather than the right
# one (--recalibrate mutated the file). Snapshot before, compare after.
est_heavy_tok_before="$(sed -n 's/.*TIER_BASE_TOK_heavy=\([0-9]\{1,\}\).*/\1/p' "$EST" | head -1)"
est_sha_before="$(cksum < "$EST")"
expect "estimate.sh declares a numeric heavy token base" \
  "$([ -n "$est_heavy_tok_before" ] && echo yes || echo no)" "yes"
_ignored="$(runs "$PA" --recalibrate)"   # a --recalibrate run must not touch the file
expect "estimate.sh heavy token base intact after --recalibrate" \
  "$(sed -n 's/.*TIER_BASE_TOK_heavy=\([0-9]\{1,\}\).*/\1/p' "$EST" | head -1)" "$est_heavy_tok_before"
expect "estimate.sh byte-identical after --recalibrate" "$(cksum < "$EST")" "$est_sha_before"
has "estimate.sh still declares the standard tier" "$(cat "$EST")" 'TIER_BASE_TOK_standard='

echo "================ malformed-input robustness (Gate B hardening) ================"
# (GB1) a lone "." RATIO_MDE must NOT blank the report (invalid --argjson guard).
O_dot="$(AUTO_TASK_PR_RESOLVE=0 AUTO_TASK_STATS_RATIO_MDE=. CLAUDE_PROJECT_DIR="$PA" bash "$STATS" 2>&1)"
has  "RATIO_MDE=. still renders quality data" "$O_dot" 'Late-defect rate +[0-9.]+% \['
hasnt "RATIO_MDE=. does NOT blank to n=0"      "$O_dot" 'Late-defect rate +n=0'
# (GB2) one row with a NON-STRING plugin_version must not blank the whole report;
# valid string-versioned rows in the same ledger still count.
PX="$(mkproj)"
{ emit 0.23.0 12 3 900000 1000000; printf '{"at":"2026-05-01T10:00:00Z","branch":"feat/bad","base":"BAD","plugin_version":23,"terminal_state":"done","tier":"standard","gate_b":"passed","followups":0,"defects_late":0,"flaky":false,"tests_added":true,"est_tokens":900000,"act_tokens":200000000,"act_tokens_output":1000000,"est_duration_min":40,"act_duration_min":52,"first_pass_ac":0.8,"defects_early":1,"checks_run":1,"checks_failed":0,"pr_url":null}\n'; } > "$PX/.auto-task/outcomes.jsonl"
O_bad="$(AUTO_TASK_PR_RESOLVE=0 CLAUDE_PROJECT_DIR="$PX" bash "$STATS" 2>&1)"
has  "non-string version: report not blanked" "$O_bad" 'Late-defect rate +[0-9.]+% \[[0-9.]+–[0-9.]+\] \(n=13\)'
has  "non-string version: excluded from grouping (single valid version -> insufficient)" "$O_bad" 'insufficient data'

echo "================ pre-recalibration row exclusion is REPORTED (R10) ================"
# The est/act token ratio is output-vs-output. A row whose estimate predates that
# change is on the old cache-inclusive scale (~100x larger), so pooling it would
# reintroduce the unit error the recalibration removed. It must be EXCLUDED and the
# exclusion must be VISIBLE — a silent drop renders as "no measured runs yet",
# which reads as never-measured rather than measured-on-the-old-scale.
#
# Two shapes must both be caught, because they are detected by different means:
#   (L1) archived by the OLD builder -> `act_tokens_output` absent entirely.
#   (L2) a live STATE.json (or a run archived by the NEW builder from an old-shape
#        state) -> the field IS present; only `est_tokens_scale == "total"` reveals it.
# L2 is the DEFAULT path: the ledger is opt-in (record-outcome.sh no-ops without
# it), so a user who never opted in has only live rows.
PL="$(mkproj)"
{ emit 0.26.1 1 0 800000 880000
  # (L1) legacy archived row: no act_tokens_output, old-scale est_tokens.
  printf '{"at":"2026-05-01T10:00:00Z","branch":"feat/legacy","base":"BL","plugin_version":"0.25.0","terminal_state":"done","tier":"heavy","gate_b":"passed","followups":0,"defects_late":0,"defects_early":1,"flaky":false,"tests_added":true,"est_tokens":900000,"act_tokens":180000000,"est_duration_min":40,"act_duration_min":52,"first_pass_ac":0.8,"checks_run":1,"checks_failed":0,"pr_url":null}\n'; } > "$PL/.auto-task/outcomes.jsonl"
O_L1="$(runs "$PL")"
has  "(L1) archived legacy row is reported as excluded" "$O_L1" '1 pre-recalibration row\(s\) excluded'
has  "(L1) names the old total scale as the reason"     "$O_L1" 'cache-inclusive total scale'
has  "(L1) ratio counts only the new row (n=1)"         "$O_L1" 'output tokens: actual/est median [0-9.]+x \(n=1\)'
hasnt "(L1) report is not blanked"                       "$O_L1" 'no measured runs yet'

# (L2) a LIVE done STATE.json whose estimate predates the change: the field is
# present-and-null, so key-absence cannot see it. Regression guard for the gap
# where this row vanished with no notice.
PM="$(mkproj)"; mkdir -p "$PM/.auto-task/feat/oldshape"
cat > "$PM/.auto-task/feat/oldshape/STATE.json" <<'EOS'
{"phase":"done","approved":true,"branch":"feat/oldshape","base":"OB","plugin_version":"0.26.1",
 "effort":{"tier":"heavy","history":[]},"iteration":{"review":1,"fix":1},
 "estimate":{"duration_min":114,"tokens_total":2750000},
 "actuals":{"duration_min":133,"tokens_total":180398722,
            "tokens_breakdown":{"input":832,"output":582636,"cache_read":178385321,"cache_creation":1429933}},
 "quality":{"defects":{"early":1,"late":0},"flaky":false,"tests_added":true,
            "diff":{"loc_added":10,"loc_removed":2},"planning":{"first_pass_ac":1}},
 "checks":[],"gates":{"gate_b":{"passed":true}},"followups":[],
 "history":[{"phase":"execute","result":"ok","at":"2026-05-01T10:00:00Z"},
            {"phase":"handover","result":"done","at":"2026-05-01T12:13:00Z"}]}
EOS
O_L2="$(runs "$PM")"
has  "(L2) live old-shape run reported as excluded"  "$O_L2" '1 pre-recalibration row\(s\) excluded'
has  "(L2) its duration still pools (n=1)"           "$O_L2" 'time: +actual/est median [0-9.]+x \(n=1\)'

# (L3) a POST-change run whose estimate was simply unestimable must NOT be
# mislabelled "pre-recalibration" — that is "not measured", a different thing.
PN="$(mkproj)"; mkdir -p "$PN/.auto-task/feat/nullest"
sed -e 's/"feat\/oldshape"/"feat\/nullest"/' -e 's/"OB"/"NB"/' \
    -e 's/"estimate":{"duration_min":114,"tokens_total":2750000}/"estimate":{"duration_min":null,"tokens_output":null,"basis":"unestimable"}/' \
    "$PM/.auto-task/feat/oldshape/STATE.json" > "$PN/.auto-task/feat/nullest/STATE.json"
O_L3="$(runs "$PN")"
hasnt "(L3) unestimable run NOT called pre-recalibration" "$O_L3" 'pre-recalibration row'

# (L3b) the SAME protection for the OLD-builder shape: a row with no
# act_tokens_output AND no estimate at all. Clause (b) guards this with
# `(.est_tokens // 0) > 0`; without that guard the row is counted as
# "pre-recalibration ... measured on the old scale" when it was never estimated.
# L3 above cannot catch a regression here — it exercises the NEW-builder shape,
# which clause (a) handles, so the guard was uncovered until this case existed.
PO="$(mkproj)"
printf '{"at":"2026-05-01T10:00:00Z","branch":"feat/oldnull","base":"ON","plugin_version":"0.25.0","terminal_state":"done","tier":"heavy","gate_b":"passed","followups":0,"defects_late":0,"defects_early":1,"flaky":false,"tests_added":true,"est_tokens":null,"act_tokens":180000000,"est_duration_min":null,"act_duration_min":133,"first_pass_ac":0.8,"checks_run":1,"checks_failed":0,"pr_url":null}\n' > "$PO/.auto-task/outcomes.jsonl"
O_L3b="$(runs "$PO")"
hasnt "(L3b) old-builder unestimable row NOT called pre-recalibration" "$O_L3b" 'pre-recalibration row'
has   "(L3b) report still renders"                                     "$O_L3b" 'Estimate accuracy'

# (L4) a clean all-new ledger prints no exclusion notice at all.
O_L4="$(runs "$PA")"
hasnt "(L4) all-new ledger prints no exclusion notice" "$O_L4" 'pre-recalibration row'

echo "================ jq agg program: no quote-terminating apostrophe ================"
# STRUCTURAL GUARD. The big agg pass in auto-task-stats.sh is a SINGLE-QUOTED bash
# string, so one apostrophe anywhere inside it - including in a prose comment -
# closes the quote, leaves $agg unbound, and blanks the entire report while every
# heading still prints. `bash -n` does not catch it. That happened THREE times during
# the change that added these tests, twice in a comment that had just been written to
# warn about it. A prose warning is evidently not enough; this asserts it.
# Bounds: the program opens on a line that is exactly two spaces + a single quote,
# and closes on the line carrying `}' "$rows"`. Both delimiter lines are EXCLUDED
# from the count - they hold the program's own quotes.
AGG_OPEN="$(awk '/^agg="\$\(jq -s/{f=NR} f && NR>f && /^  .$/{print NR; exit}' "$STATS")"
AGG_CLOSE="$(grep -n "}. \"\$rows\"" "$STATS" | head -1 | cut -d: -f1)"
expect "agg program bounds located" \
  "$([ -n "$AGG_OPEN" ] && [ -n "$AGG_CLOSE" ] && [ "$AGG_CLOSE" -gt "$AGG_OPEN" ] && echo yes || echo no)" "yes"
apo="$(awk -v a="$AGG_OPEN" -v b="$AGG_CLOSE" 'NR>a && NR<b' "$STATS" | tr -cd "'" | wc -c | tr -d ' ')"
expect "zero apostrophes inside the jq agg program" "$apo" "0"
# And prove the program actually still binds: a trivial run must not blank the report.
PZ="$(mkproj)"; emit 0.26.1 1 0 800000 880000 > "$PZ/.auto-task/outcomes.jsonl"
O_Z="$(runs "$PZ")"
has "agg pass binds (report not blanked)" "$O_Z" 'output tokens: actual/est median [0-9.]+x'

echo "================ live DERIVE reads the OUTPUT fields (R4, default path) ================"
# The DERIVE block normalises a live done STATE.json into a row. It is the DEFAULT
# path: record-outcome.sh no-ops unless .auto-task/outcomes.jsonl already exists
# (opt-in), so a user who never opted in has ONLY live rows. Both token repointings
# were previously unguarded here — reverting either left all 28 suites green while
# the report either printed a ~100x unit error or claimed "no measured runs yet".
#
# The fixture is deliberately a REAL post-change shape (tokens_output present,
# tokens_total absent) with three mutually distinguishable numbers, so each wrong
# source produces a different visible wrong answer:
#   est.tokens_output = 800,000   act.breakdown.output = 1,000,000  -> 1.25x (correct)
#   act.tokens_total  = 200,000,000 (cache-inflated) -> 250x if act is mis-sourced
#   est.tokens_total  absent        -> "no measured runs yet" if est is mis-sourced
PV="$(mkproj)"; mkdir -p "$PV/.auto-task/feat/newshape"
cat > "$PV/.auto-task/feat/newshape/STATE.json" <<'EOS'
{"phase":"done","approved":true,"branch":"feat/newshape","base":"NS","plugin_version":"0.26.1",
 "effort":{"tier":"heavy","history":[]},"iteration":{"review":1,"fix":1},
 "estimate":{"duration_min":100,"tokens_output":800000,"basis":"calibrated(n=4) tier=heavy"},
 "actuals":{"duration_min":125,"tokens_total":200000000,
            "tokens_breakdown":{"input":800,"output":1000000,"cache_read":198000000,"cache_creation":999200}},
 "quality":{"defects":{"early":1,"late":0},"flaky":false,"tests_added":true,
            "diff":{"loc_added":10,"loc_removed":2},"planning":{"first_pass_ac":1}},
 "checks":[],"gates":{"gate_b":{"passed":true}},"followups":[],
 "history":[{"phase":"execute","result":"ok","at":"2026-05-01T10:00:00Z"},
            {"phase":"handover","result":"done","at":"2026-05-01T12:05:00Z"}]}
EOS
O_DV="$(runs "$PV")"
has   "(D1) live row pooled at the OUTPUT ratio 1.25x"      "$O_DV" 'output tokens: actual/est median 1\.25x \(n=1\)'
hasnt "(D2) NOT the cache-inflated total ratio (250x)"      "$O_DV" 'median 250'
hasnt "(D3) est_tokens did not fall back to null"           "$O_DV" 'output tokens: no measured runs yet'
hasnt "(D4) a current-shape live row is not called legacy"  "$O_DV" 'pre-recalibration row'
has   "(D5) its duration still pools"                       "$O_DV" 'time: +actual/est median [0-9.]+x \(n=1\)'

echo "================ tok_legacy is honest, not merely wide (R10) ================"
# (D6) legacy and ratio-eligible must be MUTUALLY EXCLUSIVE. A row carrying
# scale=="total" alongside a usable est_tokens is not producible by either builder
# here, but a hand-edited or foreign ledger can hold one; without the `tok_ok | not`
# guard the report pooled it AND counted it excluded, contradicting itself.
PW="$(mkproj)"
{ emit 0.26.1 1 0 800000 880000
  printf '{"at":"2026-05-01T10:00:00Z","branch":"feat/both","base":"BO","plugin_version":"0.26.1","terminal_state":"done","tier":"heavy","gate_b":"passed","followups":0,"defects_late":0,"defects_early":1,"flaky":false,"tests_added":true,"est_tokens":2750000,"est_tokens_scale":"total","act_tokens":180000000,"act_tokens_output":582636,"est_duration_min":40,"act_duration_min":52,"first_pass_ac":0.8,"checks_run":1,"checks_failed":0,"pr_url":null}\n'; } > "$PW/.auto-task/outcomes.jsonl"
O_BOTH="$(runs "$PW")"
n_pooled="$(printf '%s' "$O_BOTH" | grep -oE 'output tokens: actual/est median [0-9.]+x \(n=[0-9]+\)' | grep -oE 'n=[0-9]+' | tr -d 'n=')"
n_excl="$(printf '%s' "$O_BOTH" | grep -oE '[0-9]+ pre-recalibration row' | grep -oE '^[0-9]+')"
[ -z "$n_excl" ] && n_excl=0
expect "(D6) pooled + excluded never exceeds the row count (2)"   "$([ $(( ${n_pooled:-0} + n_excl )) -le 2 ] && echo yes || echo no)" "yes"

# (D7) an OLD-shape estimate whose actuals came back null was never comparable for a
# reason unrelated to the scale change, so it must not be attributed to it.
PY2="$(mkproj)"; mkdir -p "$PY2/.auto-task/feat/oldnullact"
cat > "$PY2/.auto-task/feat/oldnullact/STATE.json" <<'EOS'
{"phase":"done","approved":true,"branch":"feat/oldnullact","base":"ONA","plugin_version":"0.26.1",
 "effort":{"tier":"heavy","history":[]},"iteration":{"review":1,"fix":1},
 "estimate":{"duration_min":114,"tokens_total":2750000},
 "actuals":{"duration_min":133,"tokens_total":null,
            "tokens_breakdown":{"input":null,"output":null,"cache_read":null,"cache_creation":null}},
 "quality":{"defects":{"early":1,"late":0},"flaky":false,"tests_added":true,
            "diff":{"loc_added":1,"loc_removed":1},"planning":{"first_pass_ac":1}},
 "checks":[],"gates":{"gate_b":{"passed":true}},"followups":[],
 "history":[{"phase":"execute","result":"ok","at":"2026-05-01T10:00:00Z"},
            {"phase":"handover","result":"done","at":"2026-05-01T12:13:00Z"}]}
EOS
O_ONA="$(runs "$PY2")"
hasnt "(D7) null-actuals row NOT attributed to the recalibration" "$O_ONA" 'pre-recalibration row'
has   "(D7) report still renders"                                 "$O_ONA" 'Estimate accuracy'

echo "================ --recalibrate reads estimate.sh LIVE (R6) ================"
# The suggestion used to hardcode the constants, which is how they went stale
# through a recalibration — the exact defect the block exists to catch. A test that
# asserted the NEW literals would rot identically, so this MUTATES a throwaway copy
# of estimate.sh and asserts the suggestion follows it. The negative assertion is
# the load-bearing half: without it, printing both a live and a stale value passes.
ESTTMP="$(mktemp -d)"
# NB: the constant is NOT at line start — three token bases share one line — so
# match it mid-line, the same way est_const does.
real_heavy="$(grep -v '^[[:space:]]*#' "$EST" \
  | sed -n -e 's/^TIER_BASE_TOK_heavy=\([0-9]\{1,\}\).*/\1/p' \
           -e 's/.*[^A-Za-z0-9_]TIER_BASE_TOK_heavy=\([0-9]\{1,\}\).*/\1/p' | head -1)"
expect "estimate.sh exposes a numeric heavy token base" \
  "$([ -n "$real_heavy" ] && echo yes || echo no)" "yes"
sed "s/TIER_BASE_TOK_heavy=$real_heavy/TIER_BASE_TOK_heavy=4242424/" "$EST" > "$ESTTMP/estimate.sh"
expect "mutation applied to the throwaway copy" \
  "$(grep -c 'TIER_BASE_TOK_heavy=4242424' "$ESTTMP/estimate.sh")" "1"
O_LIVE="$(AUTO_TASK_PR_RESOLVE=0 AUTO_TASK_STATS_RECAL_MIN_SAMPLE=1 \
          AUTO_TASK_ESTIMATE_SH="$ESTTMP/estimate.sh" \
          CLAUDE_PROJECT_DIR="$PA" bash "$STATS" --recalibrate 2>&1)"
has   "recal: suggestion produced"                  "$O_LIVE" 'Suggested TOKEN constants'
has   "recal: prints the MUTATED base (live read)"  "$O_LIVE" '4242424'
hasnt "recal: does NOT print the real base"         "$O_LIVE" "$real_heavy"

# A comment must not shadow the real assignment (the read strips comment lines, and
# estimate.sh documents its constants in prose directly above them).
sed "s/^# Tokens: OUTPUT tokens.*/# decoy TIER_BASE_TOK_heavy=999111 in a comment/" \
  "$ESTTMP/estimate.sh" > "$ESTTMP/decoy.sh"
O_DEC="$(AUTO_TASK_PR_RESOLVE=0 AUTO_TASK_STATS_RECAL_MIN_SAMPLE=1 \
         AUTO_TASK_ESTIMATE_SH="$ESTTMP/decoy.sh" \
         CLAUDE_PROJECT_DIR="$PA" bash "$STATS" --recalibrate 2>&1)"
has   "recal: comment decoy does not shadow the assignment" "$O_DEC" '4242424'
hasnt "recal: comment value not reported"                   "$O_DEC" '999111'

# A longer identifier ENDING in the same name must not shadow it either.
{ echo 'MY_TIER_BASE_TOK_heavy=999222'; cat "$ESTTMP/estimate.sh"; } > "$ESTTMP/suffix.sh"
O_SFX="$(AUTO_TASK_PR_RESOLVE=0 AUTO_TASK_STATS_RECAL_MIN_SAMPLE=1 \
         AUTO_TASK_ESTIMATE_SH="$ESTTMP/suffix.sh" \
         CLAUDE_PROJECT_DIR="$PA" bash "$STATS" --recalibrate 2>&1)"
has   "recal: suffix identifier does not shadow"  "$O_SFX" '4242424'
hasnt "recal: suffix value not reported"          "$O_SFX" '999222'

# A TRAILING comment on an earlier line must not shadow either (stripping only
# full-line comments was not enough), nor must a `-`-prefixed token, which is a
# flag rather than an assignment.
{ echo 'foo=1  # was TIER_BASE_TOK_heavy=999333'; cat "$ESTTMP/estimate.sh"; } > "$ESTTMP/trail.sh"
O_TR="$(AUTO_TASK_PR_RESOLVE=0 AUTO_TASK_STATS_RECAL_MIN_SAMPLE=1 \
        AUTO_TASK_ESTIMATE_SH="$ESTTMP/trail.sh" \
        CLAUDE_PROJECT_DIR="$PA" bash "$STATS" --recalibrate 2>&1)"
has   "recal: trailing comment does not shadow" "$O_TR" '4242424'
hasnt "recal: trailing comment value not used"  "$O_TR" '999333'
{ echo 'X=1 -TIER_BASE_TOK_heavy=999444'; cat "$ESTTMP/estimate.sh"; } > "$ESTTMP/flag.sh"
O_FL="$(AUTO_TASK_PR_RESOLVE=0 AUTO_TASK_STATS_RECAL_MIN_SAMPLE=1 \
        AUTO_TASK_ESTIMATE_SH="$ESTTMP/flag.sh" \
        CLAUDE_PROJECT_DIR="$PA" bash "$STATS" --recalibrate 2>&1)"
has   "recal: '-'-prefixed token does not shadow" "$O_FL" '4242424'
hasnt "recal: '-'-prefixed value not used"        "$O_FL" '999444'
# A non-integer constant must read as "could not read", never truncate to an int.
sed 's/^PER_AC_MIN=2;/PER_AC_MIN=1.5;/' "$ESTTMP/estimate.sh" > "$ESTTMP/float.sh"
O_FLT="$(AUTO_TASK_PR_RESOLVE=0 AUTO_TASK_STATS_RECAL_MIN_SAMPLE=1 \
         AUTO_TASK_ESTIMATE_SH="$ESTTMP/float.sh" \
         CLAUDE_PROJECT_DIR="$PA" bash "$STATS" --recalibrate 2>&1)"
has   "recal: float constant -> could-not-read path" "$O_FLT" 'Could not read the current constants'

# Fail-open must NOT reinstate a literal — that is the staleness being eliminated.
O_NOF="$(AUTO_TASK_PR_RESOLVE=0 AUTO_TASK_STATS_RECAL_MIN_SAMPLE=1 \
         AUTO_TASK_ESTIMATE_SH="$ESTTMP/nope.sh" \
         CLAUDE_PROJECT_DIR="$PA" bash "$STATS" --recalibrate 2>&1)"
has   "recal fail-open: says it could not read"   "$O_NOF" 'Could not read the current constants'
has   "recal fail-open: still names the factors"  "$O_NOF" 'multiply the TIER_BASE_TOK'
hasnt "recal fail-open: prints no constant"       "$O_NOF" "$real_heavy"
has   "recal fail-open: report still renders"     "$O_NOF" 'Estimate accuracy'
rm -rf "$ESTTMP"

# cleanup
rm -rf "$P1" "$P0" "$PA" "$PB" "$PC" "$PD" "$PX" "$PL" "$PM" "$PN" "$PO" "$PV" "$PW" "$PY2" "$PZ"

echo ""
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
