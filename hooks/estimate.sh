#!/usr/bin/env bash
# estimate.sh — pre-execution estimate of an auto-task run's cost.
#
# NOT a hook. A pure, deterministic helper (invoked by the auto-task
# orchestrator in Phase 1, after Difficulty/Risk scoring) that prints a compact
# JSON estimate of wall-clock time and token usage for the run about to start.
# The orchestrator writes the result to STATE.json `estimate` and PLAN.md, and
# the final summary compares it against measured actuals (see token-usage.sh).
#
# Model: a STATIC tier-based heuristic — no calibration against history (there is
# no accumulated token/time data to learn from yet; calibration is a documented
# follow-up). It is intentionally simple and legible, not precise: the value is
# the estimate-vs-actual *trend* over many runs, not any single run's accuracy.
#
#   duration_min = tier_base_min  + acs*PER_AC_MIN    + files*PER_FILE_MIN
#   tokens_total = tier_base_tok  + acs*PER_AC_TOK     + files*PER_FILE_TOK
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
#   {"duration_min":..,"tokens_total":..,"tokens_breakdown":{"input":..,"output":..,"cache":..},"basis":".."}

set -uo pipefail

# --- Tunable heuristic constants (documented above) --------------------------
TIER_BASE_MIN_light=12;   TIER_BASE_MIN_standard=35;   TIER_BASE_MIN_heavy=70
TIER_BASE_TOK_light=300000; TIER_BASE_TOK_standard=900000; TIER_BASE_TOK_heavy=1800000
PER_AC_MIN=2;    PER_FILE_MIN=2
PER_AC_TOK=40000; PER_FILE_TOK=50000

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
emit_null(){
  printf '{"duration_min":null,"tokens_total":null,"tokens_breakdown":{"input":null,"output":null,"cache":null},"basis":"%s"}\n' "${1:-no valid tier or D/R}"
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
tokens_total=$(( base_tok + acs * PER_AC_TOK + files * PER_FILE_TOK ))

# Breakdown: cache-read dominated in practice. output ~7%, input ~8%, cache ~85%.
out_tok=$(( tokens_total * 7 / 100 ))
in_tok=$((  tokens_total * 8 / 100 ))
cache_tok=$(( tokens_total - out_tok - in_tok ))

basis="static tier=$tier base(${base_min}min/${base_tok}tok) + acs=$acs*(${PER_AC_MIN}min/${PER_AC_TOK}tok) + files=$files*(${PER_FILE_MIN}min/${PER_FILE_TOK}tok)"

printf '{"duration_min":%d,"tokens_total":%d,"tokens_breakdown":{"input":%d,"output":%d,"cache":%d},"basis":"%s"}\n' \
  "$duration_min" "$tokens_total" "$in_tok" "$out_tok" "$cache_tok" "$basis"

exit 0
