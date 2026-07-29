#!/usr/bin/env bash
# estimate.sh — pre-execution estimate of an auto-task run's cost.
#
# NOT a hook. A pure, deterministic helper (invoked by the auto-task
# orchestrator in Phase 1, after Difficulty/Risk scoring) that prints a compact
# JSON estimate of wall-clock time and OUTPUT token usage for the run about to
# start. The orchestrator writes the result to STATE.json `estimate` and PLAN.md,
# and the final summary compares it against measured actuals (see token-usage.sh).
#
#   duration_min  = tier_base_min + acs*PER_AC_MIN  + files*PER_FILE_MIN
#   tokens_output = tier_base_tok + acs*PER_AC_TOK  + files*PER_FILE_TOK
#
# WHY OUTPUT TOKENS, AND ONLY OUTPUT TOKENS
# -----------------------------------------
# This helper deliberately estimates ONE quantity: output tokens. It does not
# emit a `tokens_total` or a cache/input breakdown, because neither can be
# honestly predicted:
#
#   * input is negligible — measured at 821/820/1703/832 tokens across the four
#     calibration runs (same order as the table below). It is rounding error
#     against output.
#   * cache_read is unpredictable noise — the measured cache_read/output ratio
#     spans 189x to 467x across those same four runs. A predicted cache_read
#     would carry more variance than the total it is a component of.
#   * so a `tokens_total` estimate (output + input + cache_read) is a guess at a
#     number dominated by its least predictable term. Emitting one invites the
#     exact misuse this shape exists to prevent: the earlier version of this
#     script estimated a ~1M-token "total" which downstream compared against a
#     measured `actuals.tokens_total` of 107M-486M, i.e. a 66x-434x UNIT error
#     across the four runs that have actuals (76.9x/434.1x/173.6x/65.6x),
#     on the strength of which `auto-task-stats --recalibrate` would have
#     suggested scaling these constants by ~100x.
#
# `actuals` still records tokens_total plus the full input/output/cache_read/
# cache_creation breakdown — that is a real measurement worth keeping. It is
# simply never COMPARED against an estimate. The estimate/actual ratio is
# output-vs-output (see auto-task-stats.sh).
#
# CALIBRATION (n=4 — read this before trusting a single number)
# ------------------------------------------------------------
# The constants below are fitted to the four completed runs in this project that
# carry non-null actuals, using measured OUTPUT tokens:
#
#   tier      acs  files  measured output
#   standard    9      4          550,617
#   standard   19      5          443,770
#   heavy      15      8        1,027,985
#   heavy      15      7          582,636
#
# Per-tier base = mean residual after subtracting the acs/files terms. Fit
# quality on those four runs: actual/est 0.71x-1.25x. Median depends on the
# convention: 1.01x as the mean of the two middle ratios, 0.845x under the
# lower-median rule auto-task-stats itself uses -- artifacts/fit-check.sh prints
# the latter, on purpose, so the fit check and the reporting tool agree.
#
# Three honesty caveats a future reader needs:
#
#   1. n=4, with 2 standard, 2 heavy and ZERO light runs. The project's own floor
#      for an AUTOMATED recalibration suggestion is 10 (see
#      AUTO_TASK_STATS_RECAL_MIN_SAMPLE). These constants come from a directed
#      hand calibration that corrected a unit error, not from a well-powered fit.
#   2. Both light constants are EXTRAPOLATED, not fitted — no light-tier run has
#      ever completed with actuals. They are extrapolated by DIFFERENT rules, and
#      the two do not agree, so neither is a derivation of the other:
#        * TIER_BASE_TOK_light steps down from standard by the measured
#          heavy/standard ratio: 400000/1.75 = 228571 -> 225000.
#        * TIER_BASE_MIN_light is just the ~2.5x bump of the old 12 -> 30. The
#          token rule would give 88/1.75 = 50 instead; 30 was kept because the
#          time bases were bumped as a family and there is no light-tier duration
#          measurement to prefer 50 over 30.
#      Net effect: light/standard is 0.56 for tokens but 0.34 for minutes, so a
#      light run's duration estimate is proportionally tighter than its token
#      estimate. Recorded because it is arbitrary, not because it is principled —
#      the first measured light run should settle both.
#   3. The measured output figures EXCLUDE sub-agent (Task/Agent) tokens, which
#      do not appear in the transcript token-usage.sh reads. So this predicts
#      MAIN-LOOP output tokens only — Gate A/B verifier and critique-agent cost
#      is real but unmeasured, and therefore uncalibrated.
#
# The acs/files coefficients are deliberately SMALL relative to the base. The
# sample gives no support for a strong count coefficient: run 2 has 19 ACs
# against run 1's 9 yet LOWER output, and runs 3/4 share acs=15 with near-equal
# file counts yet differ 1.76x. Variance is dominated by tier, not by counts, so
# the coefficients only keep the estimate monotonic in acs/files rather than
# pretending to a signal n=4 does not show.
#
# Tier is taken from --tier; if absent it is derived from max(difficulty,risk)
# using the same buckets the orchestrator uses (0-2 light, 3-5 standard, 6-8
# heavy). If neither a valid tier nor numeric D/R is available, the estimate
# fields are emitted as null (NOT 0) so downstream math (the stats
# actual/estimate ratio) can EXCLUDE a non-estimate instead of dividing by zero.
#
# Failure policy: FAIL OPEN. Every path exits 0 and prints valid JSON. No jq
# dependency (output is built with printf over values this script controls).
#
# Usage:
#   estimate.sh --tier heavy --difficulty 7 --risk 3 --acs 11 --files 14
#   estimate.sh --difficulty 6 --risk 2 --acs 4 --files 5   # tier derived
# Output (one line):
#   {"duration_min":..,"tokens_output":..,"basis":".."}

set -uo pipefail

# --- Tunable heuristic constants (calibrated — see the header) ----------------
# Time: bases bumped ~2.5x from the original static guess (12/35/70), which
# under-predicted measured wall-clock by 1.17x-1.85x on the three usable runs.
# Per-acs/per-file minutes are unchanged at 2 — with these bases, measured comes in
# at 0.93x/0.97x/0.61x OF THE ESTIMATE on those same three (measured/estimate, the
# same act/est direction auto-task-stats reports).
#
# Only THREE of the four runs are usable for duration. Run 1 is excluded because its
# history timestamps are mutually inconsistent, so no defensible span can be derived
# from them:
#   * the array is non-monotonic (indices 6 and 33 both go backwards);
#   * entry 49 reports commit 6da53ba at 2026-07-28T22:20:00Z, but that commit's
#     real committer date is 06:55:05Z — 15h25m EARLIER than the entry describing it;
#   * the two candidate span formulas disagree by 4.1x (first-to-last = 400 min;
#     min-to-max = 1648.5 min), and the recorded actuals.duration_min = 1629 matches
#     neither the first-to-last formula this repo documents (phase-5-handover.md,
#     record-outcome.sh `($ats|first)`/`($ats|last)`) nor any same-day computation.
# Which timestamps are authentic is deliberately NOT asserted here: three successive
# attempts to explain it in this comment were each refuted by deeper inspection, and
# the exclusion does not depend on the answer. What the exclusion needs is only that
# no figure can be trusted. The full evidence trail (including the three retractions)
# is in .auto-task/<branch>/recon/calibration-derivation.md — that is LOCAL to the
# machine that ran the calibration and is gitignored, so an installed copy of this
# plugin will not have it; every fact the exclusion rests on is restated above so this
# comment stands alone.
#
# Run 1's TOKEN figure IS used in the fit above, and its one real dependency is
# disclosed rather than waved away: token-usage.sh selects which messages to sum by
# comparing each `.timestamp` against `--since` (token-usage.sh:87-91), and the
# orchestrator passes the earliest history `.at`. Run 1's own
# artifacts/token-usage.json records `since: 2026-07-27T18:56:29Z` over 440 messages
# -> 550,617 output tokens. So the token window is timestamp-anchored too; it is used
# because 550,617 is a real sum over a real window, not because it is timestamp-free.
TIER_BASE_MIN_light=30;   TIER_BASE_MIN_standard=88;   TIER_BASE_MIN_heavy=175
# Tokens: OUTPUT tokens (never a cache-inclusive total — see the header).
TIER_BASE_TOK_light=225000; TIER_BASE_TOK_standard=400000; TIER_BASE_TOK_heavy=700000
PER_AC_MIN=2;    PER_FILE_MIN=2
PER_AC_TOK=5000; PER_FILE_TOK=6000

tier=""; difficulty=""; risk=""; acs=""; files=""

while [ $# -gt 0 ]; do
  case "$1" in
    --tier)        tier="${2:-}"; shift 2 || shift ;;
    --difficulty)  difficulty="${2:-}"; shift 2 || shift ;;
    --risk)        risk="${2:-}"; shift 2 || shift ;;
    --acs)         acs="${2:-}"; shift 2 || shift ;;
    --files)       files="${2:-}"; shift 2 || shift ;;
    *) shift ;;   # ignore unknown args (fail-open)
  esac
done

is_num(){ case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac }

# Emit a null (non-)estimate and exit 0. Used whenever inputs are unusable.
# NOTE: the keys are still PRESENT with null values — downstream distinguishes
# "estimated as null" (measurement impossible) from a missing key, and the
# stats ratio excludes a null rather than dividing by zero.
emit_null(){
  printf '{"duration_min":null,"tokens_output":null,"basis":"%s"}\n' "${1:-no valid tier or D/R}"
  exit 0
}

# --- Resolve tier ------------------------------------------------------------
case "$tier" in
  light|standard|heavy) : ;;
  *)
    # Derive from max(difficulty, risk) when tier not explicitly valid.
    if is_num "$difficulty" || is_num "$risk"; then
      d=0; r=0
      is_num "$difficulty" && d="$((10#$difficulty))"
      is_num "$risk" && r="$((10#$risk))"
      m="$d"; [ "$r" -gt "$m" ] && m="$r"
      if   [ "$m" -le 2 ]; then tier="light"
      elif [ "$m" -le 5 ]; then tier="standard"
      else                       tier="heavy"
      fi
    else
      emit_null "unknown tier '${tier:-}' and no numeric difficulty/risk"
    fi
    ;;
esac

# --- Normalize scale inputs (default 0, must be numeric) ----------------------
# Force base-10 (10#): a numeric arg with a leading zero (e.g. "08") would
# otherwise be read as octal by $(( )) and "08"/"09" throw "value too great for
# base", aborting before any JSON is printed — a fail-open hole. Strip to base-10.
is_num "$acs"   || acs=0
is_num "$files" || files=0
acs=$((10#$acs)); files=$((10#$files))

# --- Compute ----------------------------------------------------------------
eval "base_min=\$TIER_BASE_MIN_$tier"
eval "base_tok=\$TIER_BASE_TOK_$tier"

duration_min=$(( base_min + acs * PER_AC_MIN + files * PER_FILE_MIN ))
tokens_output=$(( base_tok + acs * PER_AC_TOK + files * PER_FILE_TOK ))

basis="calibrated(n=4) tier=$tier base(${base_min}min/${base_tok}tok-output) + acs=$acs*(${PER_AC_MIN}min/${PER_AC_TOK}tok) + files=$files*(${PER_FILE_MIN}min/${PER_FILE_TOK}tok)"

printf '{"duration_min":%d,"tokens_output":%d,"basis":"%s"}\n' \
  "$duration_min" "$tokens_output" "$basis"

exit 0
