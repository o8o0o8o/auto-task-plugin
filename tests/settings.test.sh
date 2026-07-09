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

echo "--------------------------------------------------------"
echo "settings.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
