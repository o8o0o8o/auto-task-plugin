#!/usr/bin/env bash
# Focused test for hooks/settings.sh — project-specific user settings.
#
# Asserts: built-in defaults when no file; file overrides; a `false` file value
# is honored (NOT swallowed by jq's `//`); missing key / malformed JSON / missing
# file all fall back to defaults (fail-open, exit 0); `all` merges defaults ⊔ file;
# the resolved path lives OUTSIDE the repo (under AUTO_TASK_HOME) and is stable
# across cwds of one clone; `init` seeds a template and never overwrites; and the
# helper never writes anything inside a git repo.
#
# Hermetic: uses AUTO_TASK_SETTINGS_FILE / AUTO_TASK_HOME so it never touches a
# real ~/.claude. Usage: tests/settings.test.sh   Exit 0 = all passed.

set -uo pipefail

SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/settings.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[ -f "$SH" ] || { echo "FAIL: $SH missing"; exit 1; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-52s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-52s got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }

echo "================ settings.sh ================"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# --- syntax ------------------------------------------------------------------
bash -n "$SH"; expect "bash -n clean" "$?" "0"

# --- defaults when the file is absent ---------------------------------------
V="$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get has_preview_deployment)"; rc=$?
expect "absent file -> default false"        "$V"  "false"
expect "absent file exit 0"                  "$rc" "0"
expect "default preview_wait_mode"           "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get preview_wait_mode)" "poll"
expect "default preview_timeout_min"         "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get preview_timeout_min)" "30"

# --- file overrides default --------------------------------------------------
printf '{"has_preview_deployment":true,"preview_timeout_min":45,"preview_wait_mode":"handoff"}' > "$T/s.json"
expect "override bool true"    "$(AUTO_TASK_SETTINGS_FILE="$T/s.json" bash "$SH" get has_preview_deployment)" "true"
expect "override number 45"    "$(AUTO_TASK_SETTINGS_FILE="$T/s.json" bash "$SH" get preview_timeout_min)"     "45"
expect "override string"       "$(AUTO_TASK_SETTINGS_FILE="$T/s.json" bash "$SH" get preview_wait_mode)"       "handoff"
# a key NOT in the file still returns its built-in default
expect "unset key -> default"  "$(AUTO_TASK_SETTINGS_FILE="$T/s.json" bash "$SH" get preview_poll_interval_sec)" "60"

# --- the jq `//` trap: a file value of `false` must be honored, not swallowed
printf '{"has_preview_deployment":false}' > "$T/f.json"
expect "false is honored (not default-swapped)" "$(AUTO_TASK_SETTINGS_FILE="$T/f.json" bash "$SH" get has_preview_deployment)" "false"

# --- malformed JSON -> default, fail-open exit 0 -----------------------------
printf '{ this is not json' > "$T/bad.json"
V="$(AUTO_TASK_SETTINGS_FILE="$T/bad.json" bash "$SH" get preview_wait_mode)"; rc=$?
expect "malformed -> default"     "$V"  "poll"
expect "malformed exit 0"         "$rc" "0"

# --- unknown key -> empty, exit 0 -------------------------------------------
V="$(AUTO_TASK_SETTINGS_FILE="$T/s.json" bash "$SH" get totally_unknown_key)"; rc=$?
expect "unknown key -> empty"     "$V"  ""
expect "unknown key exit 0"       "$rc" "0"

# --- all merges defaults ⊔ file (file wins, defaults fill the rest) ----------
printf '{"preview_url":"https://x.example"}' > "$T/m.json"
ALL="$(AUTO_TASK_SETTINGS_FILE="$T/m.json" bash "$SH" all)"
expect "all valid JSON"           "$(printf '%s' "$ALL" | jq empty >/dev/null 2>&1; echo $?)" "0"
expect "all: file value wins"     "$(printf '%s' "$ALL" | jq -r .preview_url)"            "https://x.example"
expect "all: default filled"      "$(printf '%s' "$ALL" | jq -r .has_preview_deployment)" "false"
expect "all: default number kept" "$(printf '%s' "$ALL" | jq -r .preview_timeout_min)"    "30"

# --- keys lists the known defaults ------------------------------------------
expect "keys lists has_preview_deployment" \
  "$(bash "$SH" keys | grep -c '^has_preview_deployment$')" "1"

# --- visual-assets keys (v0.12.0): first-class defaults + discoverable --------
expect "visual_assets_enabled default false" \
  "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get visual_assets_enabled)" "false"
expect "cloudinary_cloud_name defaults to bundled shared cloud" \
  "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get cloudinary_cloud_name)" "idy02pku"
expect "cloudinary_upload_preset defaults to bundled preset" \
  "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get cloudinary_upload_preset)" "ml_default"
expect "cloudinary_cloud_name honors env override" \
  "$(AUTO_TASK_CLOUDINARY_DEFAULT_CLOUD=custom AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get cloudinary_cloud_name)" "custom"
expect "keys lists the single visual_assets_* key (master switch only)" \
  "$(bash "$SH" keys | grep -c '^visual_assets_')" "1"
expect "keys lists both cloudinary_* keys" \
  "$(bash "$SH" keys | grep -c '^cloudinary_')" "2"
expect "defaults_json (all) includes cloudinary_cloud_name" \
  "$(bash "$SH" all | jq -r .cloudinary_cloud_name)" "idy02pku"

# --- path lives OUTSIDE the repo, under AUTO_TASK_HOME, stable across cwds ----
# Build a temp git repo with a linked worktree; the resolved path must be identical
# from the main tree, the worktree, and a subdirectory — and must sit under HOME.
REPO="$T/repo"; HOME_DIR="$T/home"
mkdir -p "$REPO" "$HOME_DIR"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
  && mkdir -p sub && git commit -q --allow-empty -m init ) >/dev/null 2>&1
( cd "$REPO" && git worktree add -q "$T/wt" -b wt-branch ) >/dev/null 2>&1

P_main="$( cd "$REPO"     && AUTO_TASK_HOME="$HOME_DIR" bash "$SH" path )"
P_sub="$(  cd "$REPO/sub" && AUTO_TASK_HOME="$HOME_DIR" bash "$SH" path )"
P_wt="$(   cd "$T/wt"     && AUTO_TASK_HOME="$HOME_DIR" bash "$SH" path )"
expect "path stable main==sub"   "$P_main" "$P_sub"
expect "path stable main==wt"    "$P_main" "$P_wt"
# (compute the prefix checks OUTSIDE command substitution — bash 3.2 mis-parses a
# `case` with `)`-terminated patterns nested inside $()).
UNDER=no;  case "$P_main" in "$HOME_DIR"/auto-task/*) UNDER=yes ;; esac
INREPO=outside; case "$P_main" in "$REPO"/*) INREPO=inside ;; esac
expect "path under AUTO_TASK_HOME" "$UNDER"  "yes"
expect "path NOT under repo"       "$INREPO" "outside"

# --- init seeds a template, does not overwrite, never writes in the repo -----
F="$( cd "$REPO" && AUTO_TASK_HOME="$HOME_DIR" bash "$SH" init )"
expect "init created a file"      "$( [ -f "$F" ] && echo yes || echo no )" "yes"
expect "init file valid JSON"     "$(jq empty "$F" >/dev/null 2>&1; echo $?)" "0"
expect "init seeded default"      "$(jq -r .has_preview_deployment "$F")" "false"
# running init again must NOT clobber a user edit
printf '%s' "$(jq '.has_preview_deployment=true' "$F")" > "$F"
( cd "$REPO" && AUTO_TASK_HOME="$HOME_DIR" bash "$SH" init ) >/dev/null 2>&1
expect "init does not overwrite"  "$(jq -r .has_preview_deployment "$F")" "true"
# and after init + get, the repo working tree is pristine (nothing written inside)
( cd "$REPO" && AUTO_TASK_HOME="$HOME_DIR" bash "$SH" get has_preview_deployment ) >/dev/null 2>&1
DIRTY="$( cd "$REPO" && git status --porcelain )"
expect "repo tree untouched by settings" "$DIRTY" ""

# --- telemetry keys: defaults ------------------------------------------------
# telemetry_enabled stays OFF by default (opt-in is still explicit); only the
# DESTINATION (endpoint + token) is pre-wired to the bundled central collector.
expect "telemetry_enabled default false"        "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get telemetry_enabled)" "false"
expect "telemetry_satisfaction_prompt default"   "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get telemetry_satisfaction_prompt)" "true"
# endpoint/token default to the BUNDLED central values (maintainer-overridable via
# env for a hermetic assert here):
expect "telemetry_endpoint bundled default"      "$(AUTO_TASK_TELEMETRY_DEFAULT_ENDPOINT='https://t.example/api/ingest' AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get telemetry_endpoint)" "https://t.example/api/ingest"
expect "telemetry_ingest_token bundled default"  "$(AUTO_TASK_TELEMETRY_DEFAULT_TOKEN='tok-default' AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get telemetry_ingest_token)" "tok-default"
# the SHIPPED endpoint default must be a non-empty https URL (never cleartext/empty)
expect "shipped endpoint default is https"       "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get telemetry_endpoint | grep -c '^https://')" "1"
printf '{"telemetry_ingest_token":"tok-xyz"}' > "$T/tok.json"
expect "telemetry_ingest_token override"         "$(AUTO_TASK_SETTINGS_FILE="$T/tok.json" bash "$SH" get telemetry_ingest_token)" "tok-xyz"

# --- global layer + precedence (defaults ⊔ global ⊔ project; project wins) ---
G="$T/global.json"; P="$T/project.json"; NG="$T/no-global.json"; NP="$T/no-project.json"
# global-only enable, project absent -> enabled true
printf '{"telemetry_enabled":true,"telemetry_endpoint":"https://g.example/i"}' > "$G"
expect "global-only enable -> true" \
  "$(AUTO_TASK_GLOBAL_SETTINGS_FILE="$G" AUTO_TASK_SETTINGS_FILE="$NP" bash "$SH" get telemetry_enabled)" "true"
expect "global-only endpoint inherited" \
  "$(AUTO_TASK_GLOBAL_SETTINGS_FILE="$G" AUTO_TASK_SETTINGS_FILE="$NP" bash "$SH" get telemetry_endpoint)" "https://g.example/i"
# project explicit false beats global true
printf '{"telemetry_enabled":false}' > "$P"
expect "project false beats global true" \
  "$(AUTO_TASK_GLOBAL_SETTINGS_FILE="$G" AUTO_TASK_SETTINGS_FILE="$P" bash "$SH" get telemetry_enabled)" "false"
# project true beats global absent
printf '{"telemetry_enabled":true}' > "$P"
expect "project true, global absent -> true" \
  "$(AUTO_TASK_GLOBAL_SETTINGS_FILE="$NG" AUTO_TASK_SETTINGS_FILE="$P" bash "$SH" get telemetry_enabled)" "true"
# project overrides a global endpoint
printf '{"telemetry_endpoint":"https://p.example/i"}' > "$P"
expect "project endpoint overrides global" \
  "$(AUTO_TASK_GLOBAL_SETTINGS_FILE="$G" AUTO_TASK_SETTINGS_FILE="$P" bash "$SH" get telemetry_endpoint)" "https://p.example/i"
# a project-set key does not leak a global key it didn't mention: preview default holds
expect "unrelated key still defaults under merge" \
  "$(AUTO_TASK_GLOBAL_SETTINGS_FILE="$G" AUTO_TASK_SETTINGS_FILE="$P" bash "$SH" get preview_wait_mode)" "poll"

# --- non-object file at either scope is treated as absent (must NOT discard the
#     other scope's valid settings; regression guard for read_obj) --------------
printf '{"preview_wait_mode":"handoff","telemetry_enabled":true}' > "$P"
for bad in 'null' '[1,2,3]' '42' '"x"'; do
  printf '%s' "$bad" > "$G"
  expect "non-object global ($bad): project preview kept" \
    "$(AUTO_TASK_GLOBAL_SETTINGS_FILE="$G" AUTO_TASK_SETTINGS_FILE="$P" bash "$SH" get preview_wait_mode)" "handoff"
  expect "non-object global ($bad): project telemetry kept" \
    "$(AUTO_TASK_GLOBAL_SETTINGS_FILE="$G" AUTO_TASK_SETTINGS_FILE="$P" bash "$SH" get telemetry_enabled)" "true"
done
# non-object PROJECT file falls back to global + defaults (not a crash to nothing)
printf '{"telemetry_enabled":true}' > "$G"; printf '[1,2,3]' > "$P"
expect "non-object project: global still applies" \
  "$(AUTO_TASK_GLOBAL_SETTINGS_FILE="$G" AUTO_TASK_SETTINGS_FILE="$P" bash "$SH" get telemetry_enabled)" "true"
expect "non-object project: unrelated default holds" \
  "$(AUTO_TASK_GLOBAL_SETTINGS_FILE="$G" AUTO_TASK_SETTINGS_FILE="$P" bash "$SH" get preview_wait_mode)" "poll"
# MULTI-DOCUMENT stream at either scope is treated as absent (must not collapse
# the merge to defaults and drop the other scope). Regression guard for read_obj.
printf '{"preview_wait_mode":"handoff","telemetry_endpoint":"https://p/x"}' > "$P"
printf '{}{}' > "$G"
expect "multi-doc global: project preview kept" \
  "$(AUTO_TASK_GLOBAL_SETTINGS_FILE="$G" AUTO_TASK_SETTINGS_FILE="$P" bash "$SH" get preview_wait_mode)" "handoff"
expect "multi-doc global: project endpoint kept" \
  "$(AUTO_TASK_GLOBAL_SETTINGS_FILE="$G" AUTO_TASK_SETTINGS_FILE="$P" bash "$SH" get telemetry_endpoint)" "https://p/x"
printf '{"telemetry_enabled":true}' > "$G"; printf '{"a":1}{"b":2}' > "$P"
expect "multi-doc project: global still applies" \
  "$(AUTO_TASK_GLOBAL_SETTINGS_FILE="$G" AUTO_TASK_SETTINGS_FILE="$P" bash "$SH" get telemetry_enabled)" "true"
# a legitimate single object is still honored after the slurp change
printf '{}' > "$G"; printf '{"telemetry_enabled":true}' > "$P"
expect "single {} global still honored" \
  "$(AUTO_TASK_GLOBAL_SETTINGS_FILE="$G" AUTO_TASK_SETTINGS_FILE="$P" bash "$SH" get telemetry_enabled)" "true"

# --- present / set (once-per-repo telemetry consent machinery) ---------------
PS="$T/consent.json"
expect "present: never-asked -> false" \
  "$(AUTO_TASK_SETTINGS_FILE="$T/absent.json" bash "$SH" present telemetry_enabled)" "false"
AUTO_TASK_SETTINGS_FILE="$PS" bash "$SH" set telemetry_enabled true >/dev/null
expect "set true -> present true"  "$(AUTO_TASK_SETTINGS_FILE="$PS" bash "$SH" present telemetry_enabled)" "true"
expect "set true -> get true"      "$(AUTO_TASK_SETTINGS_FILE="$PS" bash "$SH" get telemetry_enabled)" "true"
# declining is a DECISION: false is recorded, present() true, so it never re-asks
AUTO_TASK_SETTINGS_FILE="$PS" bash "$SH" set telemetry_enabled false >/dev/null
expect "set false -> decision recorded (present true)" "$(AUTO_TASK_SETTINGS_FILE="$PS" bash "$SH" present telemetry_enabled)" "true"
expect "set false -> get false"    "$(AUTO_TASK_SETTINGS_FILE="$PS" bash "$SH" get telemetry_enabled)" "false"
# set merges (preserves existing keys)
printf '{"preview_wait_mode":"handoff"}' > "$PS"
AUTO_TASK_SETTINGS_FILE="$PS" bash "$SH" set telemetry_enabled true >/dev/null
expect "set preserves other keys"  "$(jq -r '.preview_wait_mode' "$PS")" "handoff"
expect "set added the key"         "$(jq -r '.telemetry_enabled' "$PS")" "true"
# a global explicit value also counts as "decided" (suppresses the per-repo prompt)
printf '{"telemetry_enabled":false}' > "$T/gdecide.json"
expect "present: global decision counts" \
  "$(AUTO_TASK_GLOBAL_SETTINGS_FILE="$T/gdecide.json" AUTO_TASK_SETTINGS_FILE="$T/absent.json" bash "$SH" present telemetry_enabled)" "true"
# set --global targets the global file
GP="$(AUTO_TASK_HOME="$T/sethome" bash "$SH" set telemetry_enabled true --global)"
expect "set --global writes global file" "$(basename "$(dirname "$GP")")/$(basename "$GP")" "auto-task/settings.json"
expect "set --global value"        "$(jq -r '.telemetry_enabled' "$GP")" "true"

# --- init --global seeds the global file, keeps telemetry keys ---------------
HG="$T/home-global"
GFILE="$(AUTO_TASK_HOME="$HG" bash "$SH" init --global)"
expect "init --global created a file" "$( [ -f "$GFILE" ] && echo yes || echo no )" "yes"
expect "init --global path is the global file" "$(basename "$(dirname "$GFILE")")/$(basename "$GFILE")" "auto-task/settings.json"
expect "init --global seeded telemetry_enabled" "$(jq -r .telemetry_enabled "$GFILE")" "false"

# --- worktree-retention keys (space control) --------------------------------
expect "default worktree_cleanup_nudge"        "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get worktree_cleanup_nudge)" "true"
expect "default worktree_cleanup_throttle_hours" "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get worktree_cleanup_throttle_hours)" "24"
expect "default worktree_cleanup_prune_dirty"  "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get worktree_cleanup_prune_dirty)" "false"
expect "default worktree_stale_days_default"   "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get worktree_stale_days_default)" "14"
expect "default worktree_stale_days_feat"      "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get worktree_stale_days_feat)" "30"
expect "default worktree_stale_days_refactor"  "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get worktree_stale_days_refactor)" "30"
expect "default worktree_stale_days_fix"       "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get worktree_stale_days_fix)" "14"
expect "default worktree_stale_days_chore"     "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get worktree_stale_days_chore)" "7"
expect "default worktree_stale_days_deps"      "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get worktree_stale_days_deps)" "7"
expect "default worktree_stale_days_docs"      "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get worktree_stale_days_docs)" "7"
expect "default worktree_stale_days_cleanup"   "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get worktree_stale_days_cleanup)" "7"
# surfaced in merged view + keys + init template
WALL="$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" all)"
expect "all: worktree_cleanup_nudge present"   "$(printf '%s' "$WALL" | jq -r 'has("worktree_cleanup_nudge")')" "true"
expect "all: worktree_stale_days_feat present" "$(printf '%s' "$WALL" | jq -r 'has("worktree_stale_days_feat")')" "true"
expect "keys lists >=11 worktree_ keys"        "$( [ "$(bash "$SH" keys | grep -c '^worktree_')" -ge 11 ] && echo ok || echo no )" "ok"
HW="$T/home-wt"; WFILE="$(AUTO_TASK_HOME="$HW" bash "$SH" init)"
expect "init seeds worktree_stale_days_feat"   "$(jq -r '.worktree_stale_days_feat' "$WFILE")" "30"
# user override + present
PW="$T/pw.json"; printf '{}' > "$PW"
AUTO_TASK_SETTINGS_FILE="$PW" bash "$SH" set worktree_stale_days_feat 45 >/dev/null
expect "override worktree_stale_days_feat->45" "$(AUTO_TASK_SETTINGS_FILE="$PW" bash "$SH" get worktree_stale_days_feat)" "45"
expect "present worktree_stale_days_feat"      "$(AUTO_TASK_SETTINGS_FILE="$PW" bash "$SH" present worktree_stale_days_feat)" "true"
expect "present unset worktree key -> false"   "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" present worktree_stale_days_feat)" "false"

# --- external_actions_* defaults + override --------------------------------
expect "default external_actions_mode"            "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get external_actions_mode)" "ask"
expect "default external_actions_timeout_min"     "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get external_actions_timeout_min)" "30"
expect "default external_actions_poll_interval_sec" "$(AUTO_TASK_SETTINGS_FILE="$T/nope.json" bash "$SH" get external_actions_poll_interval_sec)" "60"
expect "all: external_actions_mode present"       "$(bash "$SH" all | jq -r 'has("external_actions_mode")')" "true"
expect "known: external_actions_mode listed"      "$( bash "$SH" keys | grep -qx 'external_actions_mode' && echo ok || echo no )" "ok"
printf '{"external_actions_mode":"runbook"}' > "$T/ext.json"
expect "override external_actions_mode->runbook"  "$(AUTO_TASK_SETTINGS_FILE="$T/ext.json" bash "$SH" get external_actions_mode)" "runbook"

echo "--------------------------------------------------------"
echo "settings.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
