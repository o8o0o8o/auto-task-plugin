#!/usr/bin/env bash
# Focused test for hooks/send-telemetry.sh — opt-in anonymous REMOTE telemetry.
#
# Asserts: OFF by default (no settings -> no-op); non-https endpoint -> no-op;
# enabled+https -> anonymized payload emitted (dry-run); payload carries NO
# task/branch/base/at and DOES carry non-empty client_id/plugin_version/os +
# schema_version; quality/perf + satisfaction/correctness present and a set
# satisfaction value reaches the payload; install id is stable across runs,
# regenerates after deletion, and is UUID-shaped; write-once sentinel; phase!=done
# -> no-op; fail-open when jq/curl is broken; the live send is bounded (never hangs)
# on an unroutable endpoint; and the payload field set is BOUND to record-outcome.sh's
# source row (no silent drift).
#
# Hermetic: AUTO_TASK_STATE_FILE / AUTO_TASK_HOME / AUTO_TASK_SETTINGS_FILE /
# AUTO_TASK_GLOBAL_SETTINGS_FILE + dry-run, so it never touches a real ~/.claude
# and never hits the network (except the deliberately-unroutable bounded test).
# Usage: tests/send-telemetry.test.sh   Exit 0 = all passed.

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
REPO_ROOT="$(cd "$HOOKS/.." && pwd)"
SH="$HOOKS/send-telemetry.sh"
RO="$HOOKS/record-outcome.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[ -f "$SH" ] || { echo "FAIL: $SH missing"; exit 1; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-52s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-52s got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }

echo "================ send-telemetry.sh ================"
bash -n "$SH"; expect "bash -n clean" "$?" "0"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
HOME_DIR="$T/home"; mkdir -p "$HOME_DIR"

# A complete phase==done STATE.json. $1 (optional) sets quality.satisfaction/correctness.
mk_state() {
  local out="$1" sat="${2:-null}" cor="${3:-null}"
  local satj corj
  if [ "$sat" = "null" ]; then satj="null"; else satj="\"$sat\""; fi
  if [ "$cor" = "null" ]; then corj="null"; else corj="\"$cor\""; fi
  cat > "$out" <<JSON
{
  "phase": "done", "branch": "feat/secret-branch", "base": "deadbeef",
  "description": "TASK TEXT THAT MUST NOT LEAK",
  "effort": { "tier": "standard", "history": [ { "from": "light" } ] },
  "estimate": { "duration_min": 100, "tokens_output": 5000 },
  "actuals": { "duration_min": 90, "tokens_total": 6000,
               "tokens_breakdown": { "input": 12, "output": 5500, "cache_read": 480, "cache_creation": 8 } },
  "quality": { "defects": { "early": 2, "late": 1 }, "flaky": false, "tests_added": true,
               "diff": { "loc_added": 40, "loc_removed": 8 }, "planning": { "first_pass_ac": 0.75 },
               "satisfaction": $satj, "correctness": $corj },
  "iteration": { "fix": 1, "review": 2 }, "followups": [ {"x":1}, {"x":2} ],
  "gates": { "gate_b": { "passed": true },
             "code_review": { "rounds": [ {"n":1}, {"n":2}, {"n":3}, {"n":4}, {"n":5} ] } },
  "checks": [ {"result":"pass"}, {"result":"pass"}, {"result":"fail"} ],
  "history": [ { "at": "2026-07-09T09:00:00Z" }, { "at": "2026-07-09T09:45:00Z" } ]
}
JSON
}

STATE="$T/STATE.json"; mk_state "$STATE"
NOFILE="$T/none.json"          # a settings file that does not exist -> defaults
ENDPOINT='{"telemetry_enabled":true,"telemetry_endpoint":"https://example.test/ingest"}'

run() { # run the hook hermetically; echoes stdout (the payload in dry-run)
  # `env` (not a bare assignment prefix) so extra VAR=val args passed via "$@"
  # are recognized as assignments even though they come from an expansion.
  env AUTO_TASK_HOME="$HOME_DIR" \
      AUTO_TASK_STATE_FILE="$STATE" \
      AUTO_TASK_SETTINGS_FILE="${SETTINGS:-$NOFILE}" \
      AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" \
      "$@" bash "$SH" 2>/dev/null
}

# A bounded-run wrapper: prefer timeout/gtimeout; if neither exists, run directly
# (the hook's own curl --connect-timeout/-m still bounds it).
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

# --- 1. OFF by default: no settings -> silent no-op (AC #1) ------------------
out="$(SETTINGS="$NOFILE" run AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1)"; rc=$?
expect "disabled -> exit 0"            "$rc"          "0"
expect "disabled -> no payload"        "${out:-EMPTY}" "EMPTY"

# --- 12. non-https endpoint -> no-op (AC #12) --------------------------------
printf '{"telemetry_enabled":true,"telemetry_endpoint":"http://example.test/ingest"}' > "$T/http.json"
out="$(SETTINGS="$T/http.json" run AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1)"; rc=$?
expect "http endpoint -> exit 0"       "$rc"          "0"
expect "http endpoint -> no payload"   "${out:-EMPTY}" "EMPTY"
# empty endpoint too
printf '{"telemetry_enabled":true,"telemetry_endpoint":""}' > "$T/noep.json"
out="$(SETTINGS="$T/noep.json" run AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1)"
expect "empty endpoint -> no payload"  "${out:-EMPTY}" "EMPTY"

# --- enabled + https -> payload emitted --------------------------------------
printf '%s' "$ENDPOINT" > "$T/on.json"
P="$(SETTINGS="$T/on.json" run AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1)"
expect "enabled+https -> valid JSON payload" "$(printf '%s' "$P" | jq -e . >/dev/null 2>&1 && echo ok)" "ok"

# --- 3. anonymity + non-empty env/id (AC #3) ---------------------------------
expect "no task"        "$(printf '%s' "$P" | jq -r 'has("task")')"   "false"
expect "no branch"      "$(printf '%s' "$P" | jq -r 'has("branch")')" "false"
expect "no base"        "$(printf '%s' "$P" | jq -r 'has("base")')"   "false"
expect "no at"          "$(printf '%s' "$P" | jq -r 'has("at")')"     "false"
expect "no description" "$(printf '%s' "$P" | jq -r 'has("description")')" "false"
expect "client_id non-empty"      "$(printf '%s' "$P" | jq -r '(.client_id|length)>0')"      "true"
expect "plugin_version non-empty" "$(printf '%s' "$P" | jq -r '(.plugin_version|length)>0')" "true"
expect "plugin_version not-unknown-in-repo" "$(printf '%s' "$P" | jq -r '.plugin_version != "unknown"')" "true"
expect "os present"               "$(printf '%s' "$P" | jq -r '(.os|length)>0')"             "true"
expect "schema_version numeric"   "$(printf '%s' "$P" | jq -r '(.schema_version|type)')"     "number"

# --- 7. quality/perf + satisfaction present; value carried (AC #7) -----------
expect "tier present"        "$(printf '%s' "$P" | jq -r 'has("tier")')"          "true"
expect "duration present"    "$(printf '%s' "$P" | jq -r 'has("duration_min")')"  "true"
expect "act_tokens present"  "$(printf '%s' "$P" | jq -r 'has("act_tokens")')"    "true"
expect "defects_early present" "$(printf '%s' "$P" | jq -r 'has("defects_early")')" "true"
expect "checks_run present"  "$(printf '%s' "$P" | jq -r 'has("checks_run")')"    "true"
expect "checks_failed=1"     "$(printf '%s' "$P" | jq -r '.checks_failed')"       "1"
expect "satisfaction key present" "$(printf '%s' "$P" | jq -r 'has("satisfaction")')" "true"
expect "correctness key present"  "$(printf '%s' "$P" | jq -r 'has("correctness")')"  "true"
# a set satisfaction value reaches the payload verbatim
mk_state "$STATE" "mostly" "yes"
Pv="$(SETTINGS="$T/on.json" run AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1)"
expect "satisfaction carried" "$(printf '%s' "$Pv" | jq -r '.satisfaction')" "mostly"
expect "correctness carried"  "$(printf '%s' "$Pv" | jq -r '.correctness')"  "yes"
mk_state "$STATE"   # reset to null

# --- 4. install id: stable, regenerated after delete, UUID-shaped (AC #4) ----
id1="$(printf '%s' "$P" | jq -r '.client_id')"
P2="$(SETTINGS="$T/on.json" run AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1)"
id2="$(printf '%s' "$P2" | jq -r '.client_id')"
expect "install id stable across runs" "$id1" "$id2"
expect "install id shape" "$(printf '%s' "$id1" | grep -qE '^[0-9a-fA-F-]{16,}$' && echo ok)" "ok"
expect "id file has no PII (== id only)" "$(cat "$HOME_DIR/auto-task/client-id")" "$id1"
rm -f "$HOME_DIR/auto-task/client-id"
P3="$(SETTINGS="$T/on.json" run AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1)"
id3="$(printf '%s' "$P3" | jq -r '.client_id')"
expect "install id regenerated after delete" "$([ -n "$id3" ] && [ "$id3" != "$id1" ] && echo ok)" "ok"

# --- 5a. write-once sentinel (AC #5) -----------------------------------------
rm -f "$T/.telemetry-sent"   # sentinel lives next to the state file (dir of STATE)
o1="$(SETTINGS="$T/on.json" run AUTO_TASK_TELEMETRY_DRYRUN=1)"   # emits + stamps
o2="$(SETTINGS="$T/on.json" run AUTO_TASK_TELEMETRY_DRYRUN=1)"   # sentinel present -> no emit
expect "write-once: first run emits"  "$(printf '%s' "$o1" | jq -e . >/dev/null 2>&1 && echo ok)" "ok"
expect "write-once: second run silent" "${o2:-EMPTY}" "EMPTY"

# --- 5a2. empty-base done-run is ALSO write-once (regression: sentinel must be
#         stamped even when base is empty, else it re-sends every turn-end) -----
rm -f "$T/.telemetry-sent"
jq '.base=""' "$STATE" > "$T/state-nobase.json"
eb1="$(env AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$T/state-nobase.json" \
  AUTO_TASK_SETTINGS_FILE="$T/on.json" AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" \
  AUTO_TASK_TELEMETRY_DRYRUN=1 bash "$SH" 2>/dev/null)"
eb2="$(env AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$T/state-nobase.json" \
  AUTO_TASK_SETTINGS_FILE="$T/on.json" AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" \
  AUTO_TASK_TELEMETRY_DRYRUN=1 bash "$SH" 2>/dev/null)"
expect "empty-base: first run emits"   "$(printf '%s' "$eb1" | jq -e . >/dev/null 2>&1 && echo ok)" "ok"
expect "empty-base: sentinel created"  "$( [ -f "$T/.telemetry-sent" ] && echo ok )" "ok"
expect "empty-base: second run silent" "${eb2:-EMPTY}" "EMPTY"

# --- 5b. phase != done -> no-op (AC #5) --------------------------------------
cp "$STATE" "$T/state-nd.json"; jq '.phase="review"' "$STATE" > "$T/state-nd.json"
out="$(AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$T/state-nd.json" \
  AUTO_TASK_SETTINGS_FILE="$T/on.json" AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" \
  AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 bash "$SH" 2>/dev/null)"; rc=$?
expect "phase!=done -> exit 0"    "$rc"           "0"
expect "phase!=done -> no payload" "${out:-EMPTY}" "EMPTY"

# --- 5c. fail-open: broken jq -> exit 0, no payload --------------------------
mkdir -p "$T/badbin"; printf '#!/bin/sh\nexit 127\n' > "$T/badbin/jq"; chmod +x "$T/badbin/jq"
out="$(PATH="$T/badbin:$PATH" AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$STATE" \
  AUTO_TASK_SETTINGS_FILE="$T/on.json" AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" \
  AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 bash "$SH" 2>/dev/null)"; rc=$?
expect "broken jq -> exit 0"      "$rc"           "0"
expect "broken jq -> no payload"  "${out:-EMPTY}" "EMPTY"

# --- 6. bounded live send: unroutable endpoint returns fast, exit 0 (AC #5/#6)
printf '{"telemetry_enabled":true,"telemetry_endpoint":"https://10.255.255.1/ingest"}' > "$T/dead.json"
rm -f "$T/.telemetry-sent"
if command -v curl >/dev/null 2>&1; then
  start=$SECONDS
  if [ -n "$TIMEOUT_BIN" ]; then
    env AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$STATE" \
      AUTO_TASK_SETTINGS_FILE="$T/dead.json" AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" \
      AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 \
      "$TIMEOUT_BIN" 9 bash "$SH" >/dev/null 2>&1; rc=$?
  else
    env AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$STATE" \
      AUTO_TASK_SETTINGS_FILE="$T/dead.json" AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" \
      AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 \
      bash "$SH" >/dev/null 2>&1; rc=$?
  fi
  elapsed=$((SECONDS-start))
  expect "unroutable send -> exit 0 (fail-open)" "$rc" "0"
  expect "unroutable send bounded (<9s)" "$([ "$elapsed" -lt 9 ] && echo ok)" "ok"
else
  echo "  SKIP  curl not installed (bounded-send test)"
fi

# --- 13. payload field set bound to record-outcome.sh source row (AC #13) -----
if [ -f "$RO" ]; then
  # Extract the row object's keys from record-outcome.sh source text.
  ro_keys="$(sed -n '/row="\$(jq/,/^    }/p' "$RO" | grep -oE '^ +[a-zA-Z_]+:' | tr -d ' :' | sort -u)"
  # Expected payload key set = ro_keys - {task,branch,base,at} + {6 additions}.
  # Base = record-outcome row keys MINUS identifiers, PLUS the v2 additions the
  # sender derives itself. (Optional repo-metrics keys are NOT here — they only
  # appear when the measured merge runs, which needs a repo dir; this dry-run has
  # none. They're covered by the repo-metrics merge test below.)
  #
  # `act_tokens_output` is excluded deliberately, and it is a RENAME not a drop:
  # the local row calls the measured output `act_tokens_output` (pairing it with
  # `act_tokens`), while the payload has carried the identical value as
  # `tokens_output` since v2 — both are `.actuals.tokens_breakdown.output`. Adding
  # the second name would duplicate the measurement AND require a new server
  # column, so the sender keeps the established one. If the payload ever stops
  # carrying `tokens_output`, the v5 assertions above fail — that is the guard.
  #
  # `est_tokens_scale` is excluded for a different reason: it is a LOCAL-reader
  # discriminator for pooling pre- and post-recalibration rows in one ledger. The
  # payload has no need of it because `schema_version` already tells a consumer
  # which scale `est_tokens` is on, which is exactly what the 4->5 bump is for.
  expected="$( { printf '%s\n' "$ro_keys" | grep -vE '^(task|branch|base|at|pr_url|act_tokens_output|est_tokens_scale)$'
                 printf '%s\n' client_id plugin_version os schema_version \
                   satisfaction correctness comment \
                   difficulty risk task_type requirements_count drift_events \
                   tokens_input tokens_output tokens_by_skill files_changed preview_verdict \
                   model claude_code_version
               } | sort -u )"
  actual="$(printf '%s' "$P" | jq -r 'keys[]' | sort -u)"
  expect "payload keys == source-derived set" "$actual" "$expected"
  # sanity: the parse actually found the known source keys
  expect "row-source parse found >=20 keys" "$([ "$(printf '%s\n' "$ro_keys" | grep -c .)" -ge 20 ] && echo ok)" "ok"
else
  echo "  SKIP  record-outcome.sh missing (drift test)"
fi

# --- 13b. free-text comment carried through, and capped at 500 chars ---------
CST="$T/state-comment.json"
jq '.quality.comment = "worked great, but the estimate was way off"' "$STATE" > "$CST"
Pc="$(AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$CST" AUTO_TASK_SETTINGS_FILE="$T/on.json" \
  AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 \
  bash "$SH" 2>/dev/null)"
expect "comment carried verbatim" \
  "$(printf '%s' "$Pc" | jq -r '.comment')" "worked great, but the estimate was way off"
# 600-char comment must be truncated to 500 in the payload
long="$(printf 'x%.0s' $(seq 1 600))"
jq --arg c "$long" '.quality.comment = $c' "$STATE" > "$CST"
Pt="$(AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$CST" AUTO_TASK_SETTINGS_FILE="$T/on.json" \
  AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 \
  bash "$SH" 2>/dev/null)"
expect "comment capped at 500 chars" "$(printf '%s' "$Pt" | jq -r '.comment | length')" "500"
# absent comment -> null
expect "comment null when unset" "$(printf '%s' "$P" | jq -r '.comment')" "null"

# --- 13c. schema v6 fields present + anonymized (task_type is prefix only) ----
# v5 changed est_tokens SEMANTICS (predicted OUTPUT tokens, comparable to
# tokens_output) without changing the field set. The version bump is what lets a
# consumer tell a v5 output-scale est_tokens from a v4 cache-inclusive total —
# the two are ~100x apart, so pooling them without branching is a unit error.
#
# v6 bumps on the same reasoning for `duration_min`, which changed on TWO axes at
# once: narrated (derived from model-written history timestamps) -> measured (from
# a hook-stamped `date -u` clock), AND always-a-number (it fell back to 0) ->
# nullable (null when unmeasured or rejected as implausible). Neither is visible in
# the value — a v5 fallback 0 reads as a real fast run — so the version is the only
# thing that lets a consumer know whether a duration was ever actually measured.
# EVERY surface that states the payload version must move together. The 5->6 bump was
# closed against its reproducer (the server-side consumer docs), and README.md was caught
# only incidentally by the Phase-5 docs step — whose scope is README.md + docs/**, so it
# structurally cannot reach skills/**. A fourth surface (the orchestrator's own telemetry
# reference) was left declaring v5, contradicting the shipped sender with every suite
# green. Derive the expected value from the sender rather than pinning a literal, so the
# next bump fails here instead of silently splitting the surfaces again.
SV="$(grep -oE '^SCHEMA_VERSION=[0-9]+' "$SH" | cut -d= -f2)"
expect "sender declares a numeric SCHEMA_VERSION" "$([ -n "$SV" ] && echo yes || echo no)" "yes"
for doc in "$REPO_ROOT/README.md" "$REPO_ROOT/skills/auto-task/references/settings.md"; do
  expect "$(basename "$doc") states schema_version $SV" \
    "$(grep -c "schema_version: $SV" "$doc")" "1"
  expect "$(basename "$doc") has no stale schema_version literal" \
    "$(grep -oE 'schema_version: [0-9]+' "$doc" | grep -vc "schema_version: $SV")" "0"
done

expect "schema_version is 7"        "$(printf '%s' "$P" | jq -r '.schema_version')" "7"
# [v7] `review_rounds` — the count of Phase-4 rounds RUN, which is a different quantity
# from `review_iterations` (rounds that REOPENED). The fixture deliberately sets them to
# different values (5 rounds vs 2 reopening iterations) so a field wired to the wrong
# source, or copy-pasted from its sibling, cannot pass this pair.
expect "review_rounds counts rounds run"   "$(printf '%s' "$P" | jq -r '.review_rounds')"      "5"
expect "review_iterations still counts reopens" "$(printf '%s' "$P" | jq -r '.review_iterations')" "2"
# CODE-REVIEW ROUND-1 FINDING, mirrored from record-outcome.test.sh: the discriminator
# is the `rounds` KEY, not `gates.code_review`. A state that lacks the key predates it
# (0.30.0) and is UNMEASURABLE -> null, so the receiver can exclude it; a state carrying
# an empty `rounds: []` really did run zero rounds -> 0, a measurement. Coalescing the
# first into the second fabricates a review-volume drop during exactly the transition
# the null was introduced for.
SNR="$T/state-norounds.json"; jq 'del(.gates.code_review)' "$STATE" > "$SNR"
Pnr="$(AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$SNR" AUTO_TASK_SETTINGS_FILE="$T/on.json" \
  AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" AUTO_TASK_TELEMETRY_DRYRUN=1 \
  AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 bash "$SH" 2>/dev/null)"
expect "no code_review -> null (unmeasurable)"  "$(printf '%s' "$Pnr" | jq -r '.review_rounds')"    "null"
SER="$T/state-emptyrounds.json"; jq '.gates.code_review = {"rounds":[]}' "$STATE" > "$SER"
Per="$(AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$SER" AUTO_TASK_SETTINGS_FILE="$T/on.json" \
  AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" AUTO_TASK_TELEMETRY_DRYRUN=1 \
  AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 bash "$SH" 2>/dev/null)"
expect "empty rounds[] -> 0, a real measurement" "$(printf '%s' "$Per" | jq -r '.review_rounds')"   "0"
expect "est_tokens is the OUTPUT estimate" "$(printf '%s' "$P" | jq -r '.est_tokens')" "5000"
expect "tokens_output is the measured output" "$(printf '%s' "$P" | jq -r '.tokens_output')" "5500"
expect "act_tokens keeps total semantics"  "$(printf '%s' "$P" | jq -r '.act_tokens')" "6000"
for k in difficulty risk task_type requirements_count drift_events tokens_input tokens_output tokens_by_skill files_changed preview_verdict external_status model claude_code_version; do
  expect "v3 field present: $k" "$(printf '%s' "$P" | jq -r "has(\"$k\")")" "true"
done
# external_status: null when no external object, echoed verbatim when present
expect "external_status null by default" "$(printf '%s' "$P" | jq -r '.external_status')" "null"
ES="$T/state-ext.json"; jq '.external={"status":"applied-verified"}' "$STATE" > "$ES"
Pes="$(AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$ES" AUTO_TASK_SETTINGS_FILE="$T/on.json" \
  AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 bash "$SH" 2>/dev/null)"
expect "external_status echoed"          "$(printf '%s' "$Pes" | jq -r '.external_status')" "applied-verified"
# task_type carries ONLY the branch <type> prefix, never the slug
STT="$T/state-tt.json"; jq '.branch="feat/super-secret-project-name"' "$STATE" > "$STT"
Ptt="$(AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$STT" AUTO_TASK_SETTINGS_FILE="$T/on.json" \
  AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 bash "$SH" 2>/dev/null)"
expect "task_type is the prefix only" "$(printf '%s' "$Ptt" | jq -r '.task_type')" "feat"
expect "task_type leaks no slug"      "$(printf '%s' "$Ptt" | jq -r 'tostring | test("super-secret") | not')" "true"

# --- 13c-norm. task_type normalized to the bounded enum ----------------------
# known prefix -> canonical; deps split-out -> deps; case-folded; unknown or
# slash-less branch -> other; empty/no branch -> null.
tt_case() { # $1=branch ("" = no branch)  $2=expected task_type
  local sj="$T/state-ttn.json" out
  if [ -n "$1" ]; then jq --arg b "$1" '.branch=$b' "$STATE" > "$sj"
  else jq 'del(.branch)' "$STATE" > "$sj"; fi
  out="$(AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$sj" AUTO_TASK_SETTINGS_FILE="$T/on.json" \
    AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 bash "$SH" 2>/dev/null)"
  expect "task_type norm: ${1:-<none>} -> $2" "$(printf '%s' "$out" | jq -r '.task_type')" "$2"
}
tt_case "deps/bump-lodash" "deps"
tt_case "wibble/secret"    "other"
tt_case "fix/x"            "fix"
tt_case "Fix/x"            "fix"
tt_case "main"             "other"
tt_case ""                 "null"

# --- 13d. repo-shape fields FROZEN as of v4: NOT emitted, even with a repo dir --
# The client no longer merges repo-metrics into the payload (frozen at schema_version 4,
# and still not emitted at v5).
# Even when AUTO_TASK_REPO_DIR points at a real repo, none of the 7 repo-shape
# fields may appear. (repo-metrics.sh itself is retained + unit-tested separately.)
if command -v git >/dev/null 2>&1; then
  RR="$T/repo"; git init -q "$RR"; git -C "$RR" config user.email t@t; git -C "$RR" config user.name t
  printf 'x\n' > "$RR/a.ts"; git -C "$RR" add -A; git -C "$RR" commit -qm base >/dev/null 2>&1
  RB="$(git -C "$RR" rev-parse HEAD)"; printf 'x\ny\n' > "$RR/a.ts"; git -C "$RR" add -A; git -C "$RR" commit -qm ch >/dev/null 2>&1
  jq --arg b "$RB" '.base=$b' "$STATE" > "$T/state-repo.json"
  Prm="$(AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$T/state-repo.json" AUTO_TASK_REPO_DIR="$RR" \
    AUTO_TASK_SETTINGS_FILE="$T/on.json" AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" \
    AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 bash "$SH" 2>/dev/null)"
  expect "repo-shape frozen: no files bucket"  "$(printf '%s' "$Prm" | jq -r 'has("repo_files_bucket")')" "false"
  expect "repo-shape frozen: no primary_language" "$(printf '%s' "$Prm" | jq -r 'has("primary_language")')" "false"
  expect "repo-shape frozen: none of the 7 present" \
    "$(printf '%s' "$Prm" | jq -r 'any(keys[]; . == "repo_files_bucket" or . == "primary_language" or . == "is_monorepo" or . == "churn_ratio" or . == "hotspot_concentration" or . == "dirs_touched" or . == "max_depth")')" "false"
else
  echo "  SKIP  git not installed (repo-shape freeze test)"
fi

# --- 13e. token cost measured AT SEND TIME (reliable, not orchestrator-dependent)
# Even with EMPTY state.actuals, the hook's own token-usage measurement populates
# the payload (via the AUTO_TASK_TOKEN_USAGE_JSON override standing in for the tool).
jq '.actuals = {}' "$STATE" > "$T/state-noactuals.json"
TU='{"tokens_total":123,"tokens_breakdown":{"input":40,"output":80,"cache_read":3},"model":"claude-opus-4-8","claude_code_version":"2.1.9","tokens_by_skill":{"base":50,"auto-task-code-review":30}}'
Ptu="$(env AUTO_TASK_TOKEN_USAGE_JSON="$TU" AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$T/state-noactuals.json" \
  AUTO_TASK_SETTINGS_FILE="$T/on.json" AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" \
  AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 bash "$SH" 2>/dev/null)"
expect "send-time tokens: output"       "$(printf '%s' "$Ptu" | jq -r '.tokens_output')" "80"
expect "send-time tokens: input"        "$(printf '%s' "$Ptu" | jq -r '.tokens_input')"  "40"
expect "send-time tokens: model"        "$(printf '%s' "$Ptu" | jq -r '.model')"         "claude-opus-4-8"
expect "send-time tokens: by_skill review" "$(printf '%s' "$Ptu" | jq -r '.tokens_by_skill["auto-task-code-review"]')" "30"
# empty override => keep state.actuals (deterministic; no real-transcript scan)
jq '.actuals.tokens_breakdown = {"input":11,"output":22}' "$STATE" > "$T/state-actuals.json"
Pkeep="$(env AUTO_TASK_TOKEN_USAGE_JSON='' AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$T/state-actuals.json" \
  AUTO_TASK_SETTINGS_FILE="$T/on.json" AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" \
  AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 bash "$SH" 2>/dev/null)"
expect "empty override keeps state actuals" "$(printf '%s' "$Pkeep" | jq -r '.tokens_output')" "22"

# --- 14. bearer auth header: sent iff telemetry_ingest_token is set ----------
mkdir -p "$T/curlbin"
cat > "$T/curlbin/curl" <<'STUB'
#!/bin/sh
# stub curl: record args to $CURL_CAPTURE, consume the piped payload, exit 0.
printf '%s\n' "$*" > "$CURL_CAPTURE"
cat >/dev/null 2>&1 || true
exit 0
STUB
chmod +x "$T/curlbin/curl"
printf '{"telemetry_enabled":true,"telemetry_endpoint":"https://x/y","telemetry_ingest_token":"tok-abc"}' > "$T/auth.json"
rm -f "$T/.telemetry-sent"
env CURL_CAPTURE="$T/cap1.txt" PATH="$T/curlbin:$PATH" \
  AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$STATE" \
  AUTO_TASK_SETTINGS_FILE="$T/auth.json" AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" \
  AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 bash "$SH" >/dev/null 2>&1
expect "bearer header sent when token set" \
  "$(grep -c 'Authorization: Bearer tok-abc' "$T/cap1.txt" 2>/dev/null)" "1"
# With the token EXPLICITLY empty (overriding the bundled default), no header is
# sent. (An unset token in the file resolves to the bundled default, which IS
# sent — that is exercised by the enable-only case below.)
printf '{"telemetry_enabled":true,"telemetry_endpoint":"https://x/y","telemetry_ingest_token":""}' > "$T/noauth.json"
env CURL_CAPTURE="$T/cap2.txt" PATH="$T/curlbin:$PATH" \
  AUTO_TASK_TELEMETRY_DEFAULT_TOKEN='' \
  AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$STATE" \
  AUTO_TASK_SETTINGS_FILE="$T/noauth.json" AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" \
  AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 bash "$SH" >/dev/null 2>&1
expect "no auth header when token explicitly empty" \
  "$(grep -c 'Authorization' "$T/cap2.txt" 2>/dev/null)" "0"

# --- 15. enable-only flow uses the BUNDLED default endpoint + token ----------
# A user who sets ONLY telemetry_enabled:true (no endpoint/token) must still send
# to the central collector via the shipped defaults.
printf '{"telemetry_enabled":true}' > "$T/enableonly.json"
Pd="$(env AUTO_TASK_TELEMETRY_DEFAULT_ENDPOINT='https://central.example/api/ingest' \
  AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$STATE" \
  AUTO_TASK_SETTINGS_FILE="$T/enableonly.json" AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" \
  AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 bash "$SH" 2>/dev/null)"
expect "enable-only -> payload via bundled endpoint" \
  "$(printf '%s' "$Pd" | jq -e . >/dev/null 2>&1 && echo ok)" "ok"
env CURL_CAPTURE="$T/cap3.txt" PATH="$T/curlbin:$PATH" \
  AUTO_TASK_TELEMETRY_DEFAULT_ENDPOINT='https://central.example/api/ingest' \
  AUTO_TASK_TELEMETRY_DEFAULT_TOKEN='bundled-tok' \
  AUTO_TASK_HOME="$HOME_DIR" AUTO_TASK_STATE_FILE="$STATE" \
  AUTO_TASK_SETTINGS_FILE="$T/enableonly.json" AUTO_TASK_GLOBAL_SETTINGS_FILE="$NOFILE" \
  AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1 bash "$SH" >/dev/null 2>&1
expect "enable-only: bundled token sent" \
  "$(grep -c 'Authorization: Bearer bundled-tok' "$T/cap3.txt" 2>/dev/null)" "1"
expect "enable-only: bundled endpoint used" \
  "$(grep -c 'https://central.example/api/ingest' "$T/cap3.txt" 2>/dev/null)" "1"


# --- 16. duration is MEASURED from the run clock ------------------------------
# The payload's duration used to come from the first/last `state.history[].at`
# strings, which the model writes without a clock. It now comes from the
# hook-stamped .run-clock.json sitting beside this STATE.json.
#
# The fixture is chosen so a broken implementation is caught rather than
# coincidentally right: its history spans 45 min and `actuals.duration_min` is 90.
# Because jq's `//` treats `null` like absent, expressing the sanity rejection as a
# nullable value would resolve it to one of those instead of to null — so the
# rejection assertions below are what prove the state is really being branched on.
CLK="$(dirname "$STATE")/.run-clock.json"
mk_clk(){ # <minutes wide>
  jq -n --argjson m "$1" '{created_at:"2026-07-09T00:00:00Z",
    updated_at:("2026-07-09T00:00:00Z"|fromdateiso8601|.+($m*60)|todateiso8601),base:"deadbeef",sealed:true}' > "$CLK"
}
pf(){ printf '%s' "$1" | jq -r "$2"; }
# Same invocation the payload assertions above use: settings via SETTINGS, dry-run,
# and IGNORE_SENTINEL so the write-once guard does not swallow repeated runs.
emit(){ SETTINGS="$T/on.json" run AUTO_TASK_TELEMETRY_DRYRUN=1 AUTO_TASK_TELEMETRY_IGNORE_SENTINEL=1; }

rm -f "$CLK"
Pn="$(emit)"
expect "no clock: duration from history (45)"  "$(pf "$Pn" .duration_min)"      "45"
expect "no clock: act from actuals (90)"       "$(pf "$Pn" .act_duration_min)"  "90"

mk_clk 120
Pc="$(emit)"
expect "clock 120m: payload duration measured" "$(pf "$Pc" .duration_min)"      "120"
expect "clock 120m: act uses the clock"        "$(pf "$Pc" .act_duration_min)"  "120"

mk_clk 720
expect "clock 720m (on the bound): sent"       "$(pf "$(emit)" .duration_min)" "720"

mk_clk 721
Pr="$(emit)"
expect "clock 721m: duration null (not 45/90)" "$(pf "$Pr" .duration_min)"      "null"
expect "clock 721m: act null (not 90)"         "$(pf "$Pr" .act_duration_min)"  "null"
# The key must remain PRESENT-and-null: the receiver's column is nullable, but an
# absent key would be indistinguishable from a payload built before this change.
expect "clock 721m: key still present"         "$(pf "$Pr" 'has("duration_min")')" "true"
expect "clock 721m: payload still valid JSON"  "$(printf '%s' "$Pr" | jq -e . >/dev/null 2>&1 && echo ok)" "ok"

# STAMP-BEFORE-READ, behaviorally. Every case above uses a SEALED clock, on which
# rc_stamp is a no-op by design — so none of them prove this hook stamps at all, and
# a neutered call (renamed helper, broken source guard) would leave them green while
# the payload silently undercounts the final turn. Here the clock is UNSEALED with a
# zero span 45 minutes back: without the self-stamp the payload reads 0, with it ~45.
ago_min(){ date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ; }
A45="$(ago_min 45)"
jq -n --arg c "$A45" '{created_at:$c,updated_at:$c,base:"deadbeef",sealed:false}' > "$CLK"
Pu="$(emit)"
DU="$(pf "$Pu" .duration_min)"
expect "unsealed clock: sender stamped before reading (~45, not 0)" \
  "$([ "$DU" -ge 44 ] && [ "$DU" -le 46 ] && echo yes || echo "no($DU)")"                     "yes"
expect "the self-stamp sealed the clock"       "$(jq -r '.sealed' "$CLK")"                     "true"
expect "the self-stamp preserved created_at"   "$(jq -r '.created_at' "$CLK")"                 "$A45"

mk_clk -120
Pneg="$(emit)"
expect "negative clock: duration null"         "$(pf "$Pneg" .duration_min)"     "null"
expect "negative clock: act null"              "$(pf "$Pneg" .act_duration_min)" "null"
# A rejection must not suppress the payload — the rest of the row is still useful.
expect "negative clock: payload still emitted" "$(printf '%s' "$Pneg" | jq -r '.terminal_state')" "done"
rm -f "$CLK"

echo "send-telemetry.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
