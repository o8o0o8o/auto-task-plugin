#!/usr/bin/env bash
# token-usage.sh — measure ACTUAL token usage of an auto-task run.
#
# NOT a hook. A pure reader (invoked by the auto-task orchestrator in Phase 5,
# and usable by record-outcome.sh which has the transcript_path in its payload)
# that sums `message.usage` from Claude Code session transcript JSONL files and
# prints a compact JSON breakdown. The final summary compares this against the
# Phase-1 estimate (see estimate.sh).
#
# WHICH TRANSCRIPTS: Claude Code stores one JSONL per session under
#   ~/.claude/projects/<slug>/<session-id>.jsonl
# where <slug> is the absolute CWD with EVERY non-alphanumeric character mapped
# to '-'. NOTE: this includes '.', so `/.claude/` becomes `--claude-` — a
# '/'-only mapping would point at a nonexistent dir and silently report zero.
# By default we scan ALL *.jsonl in that dir and sum across them, so a run that
# spans multiple transcripts (resume, a new session, a post-compaction file) is
# not undercounted. --transcript overrides to a single explicit file.
#
# RUN-SCOPING: --since <iso> keeps only assistant lines with
#   (.timestamp | fromdateiso8601) >= (since | fromdateiso8601)
# compared NUMERICALLY (not lexically), so a run's tokens are separated from
# earlier same-session work. Caveat (approximate, by design): sub-agent
# sidechain lines and concurrent unrelated same-session work after <since> are
# still counted; tokens spent before the first STATE write (version check,
# worktree setup) are a minor undercount.
#
# Failure policy: FAIL OPEN. Missing dir/file, no jq, unparseable input, or zero
# matching messages -> tokens_total AND breakdown are `null` (NOT 0), so a failed
# measurement is DISTINGUISHABLE from a real zero and is excluded from the stats
# actual/estimate ratio rather than poisoning it. Always exits 0.
#
# Usage:
#   token-usage.sh --since 2026-07-07T00:00:00Z
#   token-usage.sh --transcript /path/to/session.jsonl --since <iso>
# Output (one line):
#   {"tokens_total":..,"tokens_breakdown":{"input":..,"output":..,"cache_read":..,"cache_creation":..},"messages":..,"transcripts":..,"since":".."}

set -uo pipefail

transcript=""; since=""
while [ $# -gt 0 ]; do
  case "$1" in
    --transcript) transcript="${2:-}"; shift 2 || shift ;;
    --since)      since="${2:-}"; shift 2 || shift ;;
    *) shift ;;
  esac
done

# JSON-escaped copy of --since for OUTPUT only (the raw value still feeds jq via
# --arg, which is safe). A malformed --since (e.g. containing a `"`) must not
# break the emitted JSON — that would violate the fail-open valid-JSON contract.
since_esc="$(printf '%s' "$since" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"

emit_null(){
  printf '{"tokens_total":null,"tokens_breakdown":{"input":null,"output":null,"cache_read":null,"cache_creation":null},"messages":0,"transcripts":%d,"since":"%s"}\n' "${1:-0}" "$since_esc"
  exit 0
}

command -v jq >/dev/null 2>&1 || emit_null 0

# --- Resolve the transcript file list ----------------------------------------
files=()
if [ -n "$transcript" ]; then
  [ -f "$transcript" ] || emit_null 0
  files=("$transcript")
else
  slug="$(printf '%s' "$PWD" | sed 's/[^a-zA-Z0-9]/-/g')"
  dir="$HOME/.claude/projects/$slug"
  [ -d "$dir" ] || emit_null 0
  # Collect *.jsonl (nullglob so an empty dir yields an empty array).
  shopt -s nullglob 2>/dev/null || true
  for f in "$dir"/*.jsonl; do files+=("$f"); done
  shopt -u nullglob 2>/dev/null || true
  [ "${#files[@]}" -gt 0 ] || emit_null 0
fi

# --- Sum message.usage across all files in a single streaming jq pass ---------
agg="$(jq -n --arg since "$since" '
  # Claude Code transcript timestamps carry fractional seconds (e.g.
  # 2026-07-07T05:46:30.170Z), which jq fromdateiso8601 canNOT parse. Strip the
  # ".<frac>" before the Z (and any trailing offset colon is already absent for
  # UTC "Z") so both sides parse to epoch seconds and compare numerically.
  def epoch: if type=="string" then (sub("\\.[0-9]+";"") | fromdateiso8601? // null) else null end;
  ($since | if . == "" then null else epoch end) as $s
  | reduce inputs as $l (
      {input:0, output:0, cache_read:0, cache_creation:0, messages:0};
      if ($l.type == "assistant") and ($l.message.usage != null)
         and ( $s == null
               or ( ($l.timestamp | epoch) as $t
                    | ($t != null) and ($t >= $s) ) )
      then
        .input          += ($l.message.usage.input_tokens // 0)
        | .output       += ($l.message.usage.output_tokens // 0)
        | .cache_read   += ($l.message.usage.cache_read_input_tokens // 0)
        | .cache_creation += ($l.message.usage.cache_creation_input_tokens // 0)
        | .messages     += 1
      else . end
    )
  | .total = (.input + .output + .cache_read + .cache_creation)
' "${files[@]}" 2>/dev/null || true)"

[ -n "$agg" ] || emit_null "${#files[@]}"
printf '%s' "$agg" | jq empty 2>/dev/null || emit_null "${#files[@]}"

messages="$(printf '%s' "$agg" | jq -r '.messages // 0' 2>/dev/null || echo 0)"
case "$messages" in ''|*[!0-9]*) messages=0 ;; esac
[ "$messages" -gt 0 ] || emit_null "${#files[@]}"   # no matching data -> null, not 0

total="$(printf '%s' "$agg" | jq -r '.total // 0')"
in_tok="$(printf '%s' "$agg" | jq -r '.input // 0')"
out_tok="$(printf '%s' "$agg" | jq -r '.output // 0')"
cr_tok="$(printf '%s' "$agg" | jq -r '.cache_read // 0')"
cc_tok="$(printf '%s' "$agg" | jq -r '.cache_creation // 0')"

printf '{"tokens_total":%s,"tokens_breakdown":{"input":%s,"output":%s,"cache_read":%s,"cache_creation":%s},"messages":%s,"transcripts":%d,"since":"%s"}\n' \
  "$total" "$in_tok" "$out_tok" "$cr_tok" "$cc_tok" "$messages" "${#files[@]}" "$since_esc"

exit 0
