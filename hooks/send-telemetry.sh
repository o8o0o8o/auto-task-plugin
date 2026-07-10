#!/usr/bin/env bash
# send-telemetry.sh — OPT-IN anonymous REMOTE telemetry for auto-task.
#
# Registered as a Stop hook (alongside record-outcome.sh). When an auto-task run
# reaches phase=="done" AND the user has explicitly opted in, this derives an
# ANONYMIZED quality/performance row from STATE.json and POSTs it to a configured
# HTTPS ingest endpoint. This is the ONLY code in the plugin that sends data off
# the machine — everything about it is off-by-default and fail-open.
#
# RELATIONSHIP TO record-outcome.sh: that hook writes the SAME class of metrics to
# a LOCAL, no-network ledger (.auto-task/outcomes.jsonl). This hook is the remote
# counterpart. They are INDEPENDENT opt-ins: local = touch the ledger file; remote
# = set telemetry_enabled + telemetry_endpoint in settings. The remote payload is
# derived independently here (not read from the local ledger) so the anonymization
# transform is explicit and the local ledger's lockstep row is never disturbed.
#
# OPT-IN (both required; default OFF):
#   - settings `telemetry_enabled == true`   (project or global; see settings.sh)
#   - settings `telemetry_endpoint`  a non-empty https:// URL
# Config resolves via settings.sh (defaults ⊔ global ⊔ project). A non-https
# endpoint is refused (metrics must never traverse cleartext).
#
# ANONYMOUS: the payload carries only quality/perf metrics + a random, resettable
# install id + environment (plugin version, OS) + a schema version. It deliberately
# EXCLUDES the task text, branch, base SHA, and the precise completion timestamp
# `at` (a per-run wall-clock paired with the stable client_id is a correlation
# vector, and the server stamps its own received_at).
#
# INSTALL ID: ${AUTO_TASK_HOME:-$HOME/.claude}/auto-task/client-id — a random UUID
# generated once per machine, no PII, resettable by deleting the file.
#
# Failure policy: FAIL OPEN, ALWAYS. Every path exits 0. Telemetry must never
# break a session: missing jq/curl, unreadable state, network error, slow/absent
# endpoint — all silently skip. The network call is BOUNDED (--connect-timeout 2
# -m 5) so a dead endpoint can never hang a turn-end. `set -e` is intentionally
# omitted. Best-effort, fire-and-forget: no retries.
#
# Write-once per RUN via a base-keyed sentinel .auto-task/<branch>/.telemetry-sent
# (mirrors record-outcome.sh), so a completed run sends at most one row.
#
# Test/automation hooks (hermetic):
#   AUTO_TASK_TELEMETRY_DRYRUN=1          # build + print payload to stdout, no curl
#   AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 # ignore + do not write the write-once sentinel
#   AUTO_TASK_STATE_FILE=<path>           # use this STATE.json verbatim (skip git resolution)
#   AUTO_TASK_HOME=<dir>                  # relocate the install-id / settings root
#   AUTO_TASK_SETTINGS_FILE / AUTO_TASK_GLOBAL_SETTINGS_FILE  # forwarded to settings.sh

set -uo pipefail

SCHEMA_VERSION=2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
settings_sh="$SCRIPT_DIR/settings.sh"

# --- jq required (fail open) --------------------------------------------------
command -v jq >/dev/null 2>&1 || exit 0

# --- Resolve the STATE.json ---------------------------------------------------
# Test/explicit override first; otherwise mirror record-outcome.sh's project-root
# resolution (CLAUDE_PROJECT_DIR/$PWD -> git toplevel -> same-repo linked worktree
# retarget), then compose .auto-task/<branch>/STATE.json.
state="${AUTO_TASK_STATE_FILE:-}"
if [ -z "$state" ]; then
  project_dir_base="${CLAUDE_PROJECT_DIR:-$PWD}"
  project_dir="$(cd "$project_dir_base" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$project_dir" ] || project_dir="$project_dir_base"

  _input=""
  [ -t 0 ] || _input="$(cat 2>/dev/null || true)"
  op_cwd=""
  if [ -n "$_input" ]; then
    op_cwd="$(printf '%s' "$_input" | jq -r '.cwd // ""' 2>/dev/null || true)"
  fi
  [ -n "$op_cwd" ] || op_cwd="$PWD"
  if [ -d "$op_cwd" ]; then
    cwd_top="$(cd "$op_cwd" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$cwd_top" ] && [ "$cwd_top" != "$project_dir" ]; then
      cwd_common="$(cd "$op_cwd" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)" 2>/dev/null && pwd -P || true)"
      base_common="$(cd "$project_dir" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)" 2>/dev/null && pwd -P || true)"
      if [ -n "$cwd_common" ] && [ "$cwd_common" = "$base_common" ]; then
        project_dir="$cwd_top"
      fi
    fi
  fi

  branch="$(cd "$project_dir" && git branch --show-current 2>/dev/null || true)"
  [ -n "$branch" ] || exit 0
  state="$project_dir/.auto-task/$branch/STATE.json"
fi

[ -f "$state" ] || exit 0
jq empty "$state" 2>/dev/null || exit 0

# --- Only send for terminal runs ----------------------------------------------
phase="$(jq -r '.phase // ""' "$state" 2>/dev/null || echo "")"
[ "$phase" = "done" ] || exit 0

# --- OPT-IN gate: enabled + https endpoint ------------------------------------
[ -f "$settings_sh" ] || exit 0
enabled="$(bash "$settings_sh" get telemetry_enabled 2>/dev/null || echo false)"
[ "$enabled" = "true" ] || exit 0
endpoint="$(bash "$settings_sh" get telemetry_endpoint 2>/dev/null || echo "")"
case "$endpoint" in
  https://*) : ;;                # ok
  *)         exit 0 ;;           # empty / non-https -> never send (no cleartext)
esac
# Optional shared bearer token for the ingest endpoint (e.g. the dashboard's
# INGEST_TOKEN). Sent as `Authorization: Bearer <token>` when non-empty. Never
# logged and never part of the payload; absent -> no auth header (open endpoint).
ingest_token="$(bash "$settings_sh" get telemetry_ingest_token 2>/dev/null || echo "")"

# --- Write-once per run (base-keyed sentinel next to the state file) -----------
base="$(jq -r '.base // ""' "$state" 2>/dev/null || echo "")"
sentinel="$(dirname "$state")/.telemetry-sent"
ignore_sentinel="${AUTO_TASK_TELEMETRY_IGNORE_SENTINEL:-}"
if [ -z "$ignore_sentinel" ] && [ -f "$sentinel" ]; then
  prev="$(cat "$sentinel" 2>/dev/null || echo "")"
  if [ -n "$base" ]; then
    [ "$prev" = "$base" ] && exit 0   # this run already sent
  else
    exit 0                            # no base to scope by -> presence dedup
  fi
fi

# --- Resolve install id (create once; random; no PII; resettable) -------------
home="${AUTO_TASK_HOME:-$HOME/.claude}"
id_file="$home/auto-task/client-id"
client_id=""
if [ -f "$id_file" ]; then
  client_id="$(cat "$id_file" 2>/dev/null || echo "")"
fi
if [ -z "$client_id" ]; then
  if command -v uuidgen >/dev/null 2>&1; then
    client_id="$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')"
  elif command -v openssl >/dev/null 2>&1; then
    client_id="$(openssl rand -hex 16 2>/dev/null)"
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    client_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
  elif [ -r /dev/urandom ]; then
    client_id="$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')"
  fi
  if [ -n "$client_id" ]; then
    mkdir -p "$(dirname "$id_file")" 2>/dev/null || true
    printf '%s' "$client_id" > "$id_file" 2>/dev/null || true
  fi
fi
[ -n "$client_id" ] || exit 0   # could not obtain an id -> skip (fail open)

# --- Resolve plugin version (never empty) -------------------------------------
# Prefer the sibling hooks.json (always ships next to this hook); then the
# plugin manifest via CLAUDE_PLUGIN_ROOT (exported into hooks) or relative to
# this script; finally "unknown".
plugin_version=""
if [ -f "$SCRIPT_DIR/hooks.json" ]; then
  plugin_version="$(jq -r '.version // empty' "$SCRIPT_DIR/hooks.json" 2>/dev/null || echo "")"
fi
if [ -z "$plugin_version" ]; then
  for mf in "${CLAUDE_PLUGIN_ROOT:-}/.claude-plugin/plugin.json" "$SCRIPT_DIR/../.claude-plugin/plugin.json"; do
    [ -n "$mf" ] && [ -f "$mf" ] || continue
    plugin_version="$(jq -r '(.plugins[0].version // .version) // empty' "$mf" 2>/dev/null || echo "")"
    [ -n "$plugin_version" ] && break
  done
fi
[ -n "$plugin_version" ] || plugin_version="unknown"

os="$(uname -s 2>/dev/null || echo unknown)"

# --- Derive the ANONYMIZED payload from STATE.json ----------------------------
# Field set = record-outcome.sh's row MINUS {task,branch,base,at} PLUS
# {satisfaction,correctness,comment,client_id,plugin_version,os,schema_version}. A
# drift test (tests/send-telemetry.test.sh) binds this set to the source row so the
# two cannot silently diverge. Every field is defaulted so a partial state never
# errors. `comment` is the ONE free-text field — user-authored at the Phase-5
# prompt, capped to 500 chars, null unless the user typed a note.
payload="$(jq -c \
  --arg client_id "$client_id" \
  --arg plugin_version "$plugin_version" \
  --arg os "$os" \
  --argjson schema_version "$SCHEMA_VERSION" \
  '
  (.history // []) as $h
  | ($h | map(.at // empty)) as $ats
  | ($ats | first) as $t0
  | ($ats | last)  as $t1
  | (if ($t0 != null and $t1 != null)
       then (((($t1 | fromdateiso8601?) // 0) - (($t0 | fromdateiso8601?) // 0)) / 60 | floor)
       else 0 end) as $dur
  | (((.branch // "") | split("/") | .[0]) // "") as $ttype0
  | (if $ttype0 == "" then null
     else ($ttype0 | ascii_downcase) as $lc
       | (if (["fix","feat","deps","refactor","docs","chore","cleanup"] | index($lc)) != null
          then $lc else "other" end)
     end) as $ttype
  | {
      terminal_state: "done",
      tier: (.effort.tier // ""),
      tier_initial: (((.effort.history // []) | first | .from) // (.effort.tier // "")),
      difficulty: (.effort.difficulty // null),
      risk: (.effort.risk // null),
      escalations: ((.effort.history // []) | length),
      task_type: $ttype,
      fix_iterations: (.iteration.fix // 0),
      review_iterations: (.iteration.review // 0),
      gate_b: (if (.gates.gate_b.passed // false) then "passed"
               else ((.gates.gate_b.skipped_reason // "") | .[0:120]) end),
      followups: ((.followups // []) | length),
      requirements_count: ((.requirements // []) | length),
      drift_events: ((.history // []) | map(select(.result == "drift")) | length),
      duration_min: $dur,
      est_duration_min: (.estimate.duration_min // null),
      est_tokens: (.estimate.tokens_total // null),
      act_duration_min: (.actuals.duration_min // $dur),
      act_tokens: (.actuals.tokens_total // null),
      tokens_input: (.actuals.tokens_breakdown.input // null),
      tokens_output: (.actuals.tokens_breakdown.output // null),
      tokens_by_skill: (.actuals.tokens_by_skill // null),
      defects_early: (.quality.defects.early // 0),
      defects_late: (.quality.defects.late // 0),
      flaky: (.quality.flaky // false),
      tests_added: (.quality.tests_added // false),
      diff_loc: (((.quality.diff.loc_added // 0) + (.quality.diff.loc_removed // 0))),
      files_changed: (.quality.diff.files // null),
      first_pass_ac: (.quality.planning.first_pass_ac // null),
      checks_run: ((.checks // []) | length),
      checks_failed: ((.checks // []) | map(select(.result=="fail")) | length),
      preview_verdict: (.preview.verdict // null),
      satisfaction: (.quality.satisfaction // null),
      correctness: (.quality.correctness // null),
      comment: ((.quality.comment // null) | if type == "string" then .[0:500] else . end),
      model: (.actuals.model // null),
      claude_code_version: (.actuals.claude_code_version // null),
      client_id: $client_id,
      plugin_version: $plugin_version,
      os: $os,
      schema_version: $schema_version
    }
' "$state" 2>/dev/null || true)"

# --- Merge measured repo metrics (size + churn) — bounded, fail-open ----------
# Sourced from the sibling repo-metrics.sh against the run's repo; every field is
# nullable and the whole block is optional (older/failed measurements just omit it,
# and the DB/dashboard treat missing as null). Keeps the anonymity contract: the
# helper emits only buckets/numbers, never paths or names.
if [ -n "$payload" ] && [ -f "$SCRIPT_DIR/repo-metrics.sh" ]; then
  repo_dir="${AUTO_TASK_REPO_DIR:-${project_dir:-}}"
  if [ -n "$repo_dir" ]; then
    rm_base="$(jq -r '.base // ""' "$state" 2>/dev/null || echo "")"
    rmjson="$(bash "$SCRIPT_DIR/repo-metrics.sh" --repo "$repo_dir" --base "$rm_base" 2>/dev/null || true)"
    if [ -n "$rmjson" ] && printf '%s' "$rmjson" | jq empty 2>/dev/null; then
      payload="$(printf '%s' "$payload" | jq -c --argjson rm "$rmjson" '. * $rm' 2>/dev/null || printf '%s' "$payload")"
    fi
  fi
fi

# --- Authoritative token measurement (reliable, at send time) ----------------
# The token cost (total/breakdown/model/version/by-skill) is measured HERE by
# calling token-usage.sh directly, so it is sent on EVERY completed run — instead
# of depending on the orchestrator having populated state.actuals in Phase 5
# (which is model-driven and may be skipped). Tool output overrides the STATE
# values field-by-field; STATE stays the fallback when a field is unmeasured.
#   AUTO_TASK_TOKEN_USAGE_JSON  (test hook): if SET, use verbatim instead of
#   running the tool (empty => skip recompute, keep state.actuals). Unset in a
#   real run => run the tool. Skipped in AUTO_TASK_STATE_FILE mode (hermetic)
#   unless the override is provided, so tests never scan a real transcript.
if [ -n "$payload" ]; then
  tu_json="${AUTO_TASK_TOKEN_USAGE_JSON-__RUN__}"
  if [ "$tu_json" = "__RUN__" ]; then
    if [ -z "${AUTO_TASK_STATE_FILE:-}" ] && [ -f "$SCRIPT_DIR/token-usage.sh" ]; then
      run_start="$(jq -r '[.history[].at] | map(select(. != null)) | first // ""' "$state" 2>/dev/null || echo "")"
      tu_json="$(bash "$SCRIPT_DIR/token-usage.sh" --since "$run_start" 2>/dev/null || true)"
    else
      tu_json=""
    fi
  fi
  if [ -n "$tu_json" ] && printf '%s' "$tu_json" | jq empty 2>/dev/null; then
    payload="$(printf '%s' "$payload" | jq -c --argjson tu "$tu_json" '
      .act_tokens          = ($tu.tokens_total // .act_tokens)
      | .tokens_input      = ($tu.tokens_breakdown.input  // .tokens_input)
      | .tokens_output     = ($tu.tokens_breakdown.output // .tokens_output)
      | .model             = ($tu.model // .model)
      | .claude_code_version = ($tu.claude_code_version // .claude_code_version)
      | .tokens_by_skill   = (if (($tu.tokens_by_skill // {}) | length) > 0
                              then $tu.tokens_by_skill else .tokens_by_skill end)
    ' 2>/dev/null || printf '%s' "$payload")"
  fi
fi

# A malformed/empty derivation must not send garbage — skip silently.
[ -n "$payload" ] || exit 0
printf '%s' "$payload" | jq empty 2>/dev/null || exit 0

# --- Dry-run: print + (optionally) stamp, no network --------------------------
if [ -n "${AUTO_TASK_TELEMETRY_DRYRUN:-}" ]; then
  printf '%s\n' "$payload"
  # Stamp UNCONDITIONALLY (mirror record-outcome.sh:146). The write-once READ
  # check has an empty-base presence-dedup branch that only works if the file is
  # created even when base is empty — guarding the write on [ -n base ] would
  # leave a degenerate empty-base done-run re-emitting on every turn-end.
  if [ -z "$ignore_sentinel" ]; then
    printf '%s' "$base" > "$sentinel" 2>/dev/null || true
  fi
  exit 0
fi

# --- Send (bounded, fail-open, fire-and-forget) -------------------------------
command -v curl >/dev/null 2>&1 || exit 0
curl_args=( -sS --connect-timeout 2 -m 5 -X POST -H 'Content-Type: application/json' )
[ -n "$ingest_token" ] && curl_args+=( -H "Authorization: Bearer $ingest_token" )
curl_args+=( --data @- "$endpoint" )
printf '%s' "$payload" | curl "${curl_args[@]}" >/dev/null 2>&1 || true

# Stamp the run-scoped sentinel (best-effort; no retry regardless of send result).
# UNCONDITIONAL (mirror record-outcome.sh:146) so an empty-base done-run is still
# deduped by sentinel presence and cannot re-POST on every subsequent turn-end.
if [ -z "$ignore_sentinel" ]; then
  printf '%s' "$base" > "$sentinel" 2>/dev/null || true
fi

exit 0
