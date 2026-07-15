#!/usr/bin/env bash
# settings.sh — project-specific user settings for the auto-task plugin.
#
# NOT a hook. A pure, fail-open reader/writer (invoked by the auto-task
# orchestrator — Phase 1 to snapshot settings, Phase 6 to gate the preview
# verification) that resolves a per-project JSON settings file, applies built-in
# defaults for anything the user did not set, and prints the result.
#
# WHERE SETTINGS LIVE (deliberately OUTSIDE the user's repo, so a setting never
# alters the tracked project or shows up in `git status`):
#
#     ${AUTO_TASK_HOME:-$HOME/.claude}/auto-task/<project-key>/settings.json   (PROJECT)
#     ${AUTO_TASK_HOME:-$HOME/.claude}/auto-task/settings.json                 (GLOBAL)
#
#   <project-key> = "<repo-basename>-<12-char-hash-of-abs-common-dir-parent>".
#   The key is derived from the git *common dir* (`git rev-parse --git-common-dir`),
#   which every linked worktree of one clone shares — so all worktrees of a repo
#   resolve to the SAME settings file (a setting is per-clone, not per-worktree).
#   Outside a git repo, the key falls back to the current directory.
#
# TWO SCOPES (both optional): a GLOBAL file applies to every project; a PROJECT
# file applies to one clone. They merge as  defaults ⊔ global ⊔ project  — the
# PROJECT file wins over GLOBAL, which wins over the built-in defaults. Either
# scope can enable or disable any key (e.g. opt telemetry in globally, then set
# `telemetry_enabled:false` in one project's file to exclude just that project).
#
# FALLBACK: every key has a built-in default (the single source of truth is the
# `default_for` table below). A missing file, malformed JSON, or an absent key
# all resolve to the default. `false`/`0`/`""` file values are honored (we test
# key *presence*, never jq's `//`, which would swallow a legitimate `false`).
#
# Failure policy: FAIL OPEN. Every path exits 0 and prints a usable value (the
# default when anything is wrong). Requires jq for `get`/`all`/`init` (without
# jq, `get` still emits the built-in default). NEVER writes inside the repo.
#
# Usage:
#   settings.sh path                      # print the resolved settings-file path
#   settings.sh get <key>                 # print value (file override, else default)
#   settings.sh present <key>             # true iff key is EXPLICITLY set in a file (not just a default)
#   settings.sh set <key> <value> [--global]  # persist a key (merge) into project/global file
#   settings.sh all                       # print merged (defaults ⊔ file) JSON
#   settings.sh init [--global]           # write a documented template if absent (project, or global)
#   settings.sh keys                      # list known default keys
#
# Test hooks (hermetic, no touching a real ~/.claude):
#   AUTO_TASK_SETTINGS_FILE=<path>        # use this PROJECT file verbatim (skips key derivation)
#   AUTO_TASK_GLOBAL_SETTINGS_FILE=<path> # use this GLOBAL file verbatim (skips derivation)
#   AUTO_TASK_HOME=<dir>                  # relocate the settings root (both scopes)

set -uo pipefail

# --- Central telemetry collection (BUNDLED defaults) -------------------------
# These ship WITH the plugin so a user who opts in (telemetry_enabled=true) sends
# anonymized rows to the project's central collector with NO endpoint/token setup.
# `telemetry_enabled` stays false — opting in is still explicit; only the DESTINATION
# is pre-wired. A user can override either value via project/global settings (e.g.
# to self-host their own dashboard).
#
# MAINTAINER — replace both at release time with your deployed dashboard values:
#   *_ENDPOINT : the dashboard's https `/api/ingest` URL.
#   *_TOKEN    : the dashboard's INGEST_TOKEN. This is a PUBLIC, WRITE-ONLY key by
#     design — it ships inside an open-source client, so it is world-readable and is
#     NOT a secret. A leak only permits appending junk rows (write-only; no read;
#     never exposes the Turso credential). Protect the endpoint with SERVER-SIDE
#     rate-limiting; rotate this value to cut off abuse. (Note: a real high-entropy
#     token committed here will trip secret scanners — expected for a public key.)
AUTO_TASK_TELEMETRY_DEFAULT_ENDPOINT="${AUTO_TASK_TELEMETRY_DEFAULT_ENDPOINT:-https://auto-task-plugin-admin.vercel.app/api/ingest}"
AUTO_TASK_TELEMETRY_DEFAULT_TOKEN="${AUTO_TASK_TELEMETRY_DEFAULT_TOKEN:-5defb6fff07f96a5fc534b1976f496ad5ff3754fb8f182075d06ef05add901e7}"

# --- Built-in defaults (SINGLE SOURCE OF TRUTH) ------------------------------
# Keep this list and the `defaults_json` object below in lockstep.
default_for() {
  case "${1:-}" in
    has_preview_deployment)       printf 'false' ;;
    preview_autodetect)           printf 'true' ;;
    preview_url)                  printf '' ;;
    preview_wait_mode)            printf 'poll' ;;
    preview_timeout_min)          printf '30' ;;
    preview_poll_interval_sec)    printf '60' ;;
    preview_bypass_header)        printf '' ;;
    preview_post_verdict_comment) printf 'false' ;;
    bot_review_autofix)           printf 'false' ;;
    bot_review_timeout_min)       printf '10' ;;
    bot_review_poll_interval_sec) printf '30' ;;
    bot_review_bots)              printf '' ;;
    visual_assets_enabled)        printf 'false' ;;
    visual_assets_repo)           printf '' ;;
    visual_assets_visibility)     printf 'public' ;;
    telemetry_enabled)            printf 'false' ;;
    telemetry_endpoint)           printf '%s' "$AUTO_TASK_TELEMETRY_DEFAULT_ENDPOINT" ;;
    telemetry_ingest_token)       printf '%s' "$AUTO_TASK_TELEMETRY_DEFAULT_TOKEN" ;;
    telemetry_satisfaction_prompt) printf 'true' ;;
    history_reminder_enabled)     printf 'false' ;;
    *)                            printf '' ;;   # unknown key -> empty (fail-open)
  esac
}

# The same defaults as a JSON object (typed: booleans/numbers, not strings), used
# by `all` to merge under the file and by `init` to seed a template.
defaults_json() {
  jq -n \
    --arg ep "$AUTO_TASK_TELEMETRY_DEFAULT_ENDPOINT" \
    --arg tok "$AUTO_TASK_TELEMETRY_DEFAULT_TOKEN" \
    '{
    has_preview_deployment: false,
    preview_autodetect: true,
    preview_url: "",
    preview_wait_mode: "poll",
    preview_timeout_min: 30,
    preview_poll_interval_sec: 60,
    preview_bypass_header: "",
    preview_post_verdict_comment: false,
    bot_review_autofix: false,
    bot_review_timeout_min: 10,
    bot_review_poll_interval_sec: 30,
    bot_review_bots: "",
    visual_assets_enabled: false,
    visual_assets_repo: "",
    visual_assets_visibility: "public",
    telemetry_enabled: false,
    telemetry_endpoint: $ep,
    telemetry_ingest_token: $tok,
    telemetry_satisfaction_prompt: true,
    history_reminder_enabled: false
  }'
}

known_keys="has_preview_deployment preview_autodetect preview_url preview_wait_mode preview_timeout_min preview_poll_interval_sec preview_bypass_header preview_post_verdict_comment bot_review_autofix bot_review_timeout_min bot_review_poll_interval_sec bot_review_bots visual_assets_enabled visual_assets_repo visual_assets_visibility telemetry_enabled telemetry_endpoint telemetry_ingest_token telemetry_satisfaction_prompt history_reminder_enabled"

# --- Path resolution ---------------------------------------------------------
hash_str() {
  # First 12 hex/decimal chars of a stable hash of "$1"; empty if no hasher.
  local s="${1:-}" h=""
  if   command -v shasum  >/dev/null 2>&1; then h="$(printf '%s' "$s" | shasum 2>/dev/null | awk '{print $1}')"
  elif command -v sha1sum >/dev/null 2>&1; then h="$(printf '%s' "$s" | sha1sum 2>/dev/null | awk '{print $1}')"
  elif command -v md5     >/dev/null 2>&1; then h="$(printf '%s' "$s" | md5 2>/dev/null)"
  elif command -v md5sum  >/dev/null 2>&1; then h="$(printf '%s' "$s" | md5sum 2>/dev/null | awk '{print $1}')"
  elif command -v cksum   >/dev/null 2>&1; then h="$(printf '%s' "$s" | cksum 2>/dev/null | awk '{print $1$2}')"
  fi
  printf '%s' "$h" | cut -c1-12
}

canonical_repo_root() {
  # Parent of the git common dir — identical for the main tree and every linked
  # worktree of the clone. `pwd -P` resolves symlinks so the key is STABLE
  # regardless of whether git hands us a relative `.git` (main tree) or a
  # symlink-resolved absolute path (worktree); mixing the two would otherwise
  # split one clone across two keys. Falls back to $PWD outside a git repo.
  local cdir=""
  cdir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$cdir" ]; then
    cdir="$(cd "$cdir" 2>/dev/null && pwd -P || true)"
  fi
  if [ -n "$cdir" ]; then
    dirname "$cdir"
  else
    pwd -P
  fi
}

project_key() {
  local root base h
  root="${1:-$(canonical_repo_root)}"
  base="$(basename "$root" 2>/dev/null || printf 'repo')"
  base="$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '-')"
  h="$(hash_str "$root")"
  if [ -n "$h" ]; then printf '%s-%s' "$base" "$h"; else printf '%s' "$base"; fi
}

resolve_file() {
  if [ -n "${AUTO_TASK_SETTINGS_FILE:-}" ]; then
    printf '%s' "$AUTO_TASK_SETTINGS_FILE"
    return 0
  fi
  local home key
  home="${AUTO_TASK_HOME:-$HOME/.claude}"
  key="$(project_key)"
  printf '%s/auto-task/%s/settings.json' "$home" "$key"
}

# Concrete global-file path (used by `init --global`): the explicit override, or
# the derived ~/.claude/auto-task/settings.json.
global_file_path() {
  if [ -n "${AUTO_TASK_GLOBAL_SETTINGS_FILE:-}" ]; then
    printf '%s' "$AUTO_TASK_GLOBAL_SETTINGS_FILE"
    return 0
  fi
  printf '%s/auto-task/settings.json' "${AUTO_TASK_HOME:-$HOME/.claude}"
}

# Global file to LAYER UNDER the project file during a merge. Same as
# global_file_path EXCEPT: when the caller pins a verbatim PROJECT file via
# AUTO_TASK_SETTINGS_FILE but does NOT pin a global, we return empty so the merge
# does not silently pull in the real ~/.claude global — this keeps the explicit
# AUTO_TASK_SETTINGS_FILE mode hermetic and backward-compatible with old tests.
resolve_global_file() {
  if [ -n "${AUTO_TASK_GLOBAL_SETTINGS_FILE:-}" ]; then
    printf '%s' "$AUTO_TASK_GLOBAL_SETTINGS_FILE"
    return 0
  fi
  if [ -n "${AUTO_TASK_SETTINGS_FILE:-}" ]; then
    printf ''   # explicit project override, no explicit global -> no global layer
    return 0
  fi
  printf '%s/auto-task/settings.json' "${AUTO_TASK_HOME:-$HOME/.claude}"
}

# Read a settings file into a compact JSON OBJECT; {} when absent/unreadable/
# invalid/non-object. The `type=="object"` guard (not just `jq empty` for syntax)
# is load-bearing: a valid-JSON-but-non-object file (`null`, `[..]`, `42`, `"x"` —
# a plausible corrupt/partial hand-edit) would otherwise flow into merged_json's
# `$d * $g * $p`, crash the multiply, and collapse the whole merged view to bare
# defaults — silently discarding a VALID file at the OTHER scope. Treating a
# non-object as absent ({}) keeps the other scopes + defaults intact.
read_obj() {
  local f="${1:-}" out
  if [ -n "$f" ] && [ -f "$f" ]; then
    # SLURP (-s) and require EXACTLY ONE top-level value that is an object, then
    # emit it. This rejects, in one shot: invalid JSON (jq errors -> empty);
    # a scalar/array (`null`/`[..]`/`42`/`"x"` -> length 1 non-object -> empty);
    # AND a multi-document stream (`{}{}` / an appended object -> length>1 ->
    # empty). Emitting a single compact object is what keeps merged_json's
    # `--argjson` from ever receiving invalid or multi-value input and collapsing
    # the merged view to bare defaults (which would silently drop the OTHER scope).
    out="$(jq -cs 'if (length==1 and ((.[0]|type)=="object")) then .[0] else empty end' "$f" 2>/dev/null)"
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
  fi
  printf '{}'
}

# --- Merged view (defaults ⊔ global ⊔ project; project wins) -----------------
merged_json() {
  local d g p
  d="$(defaults_json 2>/dev/null || printf '{}')"
  g="$(read_obj "$(resolve_global_file)")"
  p="$(read_obj "$(resolve_file)")"
  # `*` deep-merges objects, right operand winning -> project > global > default.
  # Object VALUES are merged (presence-based), so a file's `false`/`0`/`""` is
  # honored rather than swallowed as a falsey `//` default.
  jq -n --argjson d "$d" --argjson g "$g" --argjson p "$p" '$d * $g * $p' 2>/dev/null \
    || printf '%s' "$d"
}

# --- Subcommands -------------------------------------------------------------
cmd_path() { resolve_file; printf '\n'; }

cmd_keys() { printf '%s\n' "$known_keys" | tr ' ' '\n'; }

# `present <key>` — has the key been EXPLICITLY set in a settings file (project or
# global), as opposed to only resolving to a built-in default? Prints true/false.
# This is how the orchestrator distinguishes "user has decided" from "never asked"
# for the once-per-repo telemetry consent prompt — `get` can't, since it always
# returns the default.
cmd_present() {
  local key="${1:-}"
  if [ -z "$key" ] || ! command -v jq >/dev/null 2>&1; then printf 'false\n'; return 0; fi
  local g p
  g="$(read_obj "$(resolve_global_file)")"
  p="$(read_obj "$(resolve_file)")"
  if printf '%s' "$p" | jq -e --arg k "$key" 'has($k)' >/dev/null 2>&1 \
     || printf '%s' "$g" | jq -e --arg k "$key" 'has($k)' >/dev/null 2>&1; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

# `set <key> <value> [--global]` — persist a key into the project (default) or
# global settings file, merging with (never clobbering) existing keys. Creates the
# file/dir if absent. `true`/`false`/`null`/numbers are written as JSON literals;
# anything else as a string. Prints the file path. Writes OUTSIDE the repo by
# construction (resolve_file / global_file_path target ~/.claude). Fail-open.
cmd_set() {
  local key="${1:-}" val="${2:-}" scope="project"
  [ "${3:-}" = "--global" ] && scope="global"
  if [ -z "$key" ]; then echo "settings.sh set: missing <key>" >&2; exit 0; fi
  if ! command -v jq >/dev/null 2>&1; then echo "settings.sh set: jq required" >&2; exit 0; fi
  local file dir cur out
  if [ "$scope" = "global" ]; then file="$(global_file_path)"; else file="$(resolve_file)"; fi
  dir="$(dirname "$file")"
  mkdir -p "$dir" 2>/dev/null || { echo "settings.sh set: cannot create $dir" >&2; exit 0; }
  cur="$(read_obj "$file")"   # {} when absent/invalid
  if printf '%s' "$val" | grep -qE '^(true|false|null|-?[0-9]+(\.[0-9]+)?)$'; then
    out="$(printf '%s' "$cur" | jq --arg k "$key" --argjson v "$val" '.[$k] = $v' 2>/dev/null)"
  else
    out="$(printf '%s' "$cur" | jq --arg k "$key" --arg v "$val" '.[$k] = $v' 2>/dev/null)"
  fi
  if [ -z "$out" ]; then echo "settings.sh set: merge failed" >&2; exit 0; fi
  printf '%s\n' "$out" > "$file" 2>/dev/null || { echo "settings.sh set: write failed" >&2; exit 0; }
  printf '%s\n' "$file"
}

cmd_get() {
  local key="${1:-}"
  if [ -z "$key" ]; then
    echo "settings.sh get: missing <key>" >&2
    exit 0   # fail-open: no key -> nothing to print
  fi
  # Without jq we cannot read the file, but we can still honor built-in defaults.
  if ! command -v jq >/dev/null 2>&1; then
    default_for "$key"; printf '\n'; return 0
  fi
  local m present
  m="$(merged_json)"
  present="$(printf '%s' "$m" | jq -r --arg k "$key" '(has($k) and (.[$k] != null))' 2>/dev/null || echo false)"
  if [ "$present" = "true" ]; then
    printf '%s' "$m" | jq -r --arg k "$key" '.[$k]' 2>/dev/null
  else
    # Key not present in merged view. For a known key this cannot happen (defaults
    # cover it); for an unknown key, emit its (empty) default.
    default_for "$key"; printf '\n'
  fi
}

cmd_all() {
  if ! command -v jq >/dev/null 2>&1; then
    echo '{}' ; return 0
  fi
  merged_json
  printf '\n'
}

cmd_init() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "settings.sh init: jq is required to write a template." >&2
    exit 0
  fi
  # The resolved path lives OUTSIDE the repo by construction (resolve_file /
  # global_file_path target ~/.claude, keyed off the git common dir — proven by
  # the path/no-write tests), so `init` never writes inside the user's tree.
  local scope="project" file dir comment
  if [ "${1:-}" = "--global" ]; then scope="global"; fi
  if [ "$scope" = "global" ]; then
    file="$(global_file_path)"
    comment="auto-task GLOBAL settings (apply to every project; a per-project file overrides these). Stored outside your repos; edit values below. Any key you omit falls back to the built-in default. See hooks/settings.sh for the key reference."
  else
    file="$(resolve_file)"
    comment="auto-task PROJECT settings (this clone only; override the global file). Stored outside your repo; edit values below. Any key you omit falls back to the built-in default. See hooks/settings.sh for the key reference."
  fi
  dir="$(dirname "$file")"
  if [ -f "$file" ]; then
    echo "settings.sh init: settings already exist at $file (left unchanged)." >&2
    printf '%s\n' "$file"
    exit 0
  fi
  mkdir -p "$dir" 2>/dev/null || { echo "settings.sh init: could not create $dir" >&2; exit 0; }
  defaults_json \
    | jq --arg c "$comment" '. + {"_comment":$c}' \
    > "$file" 2>/dev/null || { echo "settings.sh init: write failed" >&2; exit 0; }
  printf '%s\n' "$file"
}

# --- Dispatch ----------------------------------------------------------------
sub="${1:-get}"
shift || true
case "$sub" in
  path) cmd_path ;;
  keys) cmd_keys ;;
  get)  cmd_get "${1:-}" ;;
  present) cmd_present "${1:-}" ;;
  set)  cmd_set "$@" ;;
  all)  cmd_all ;;
  init) cmd_init "${1:-}" ;;
  *)    echo "settings.sh: unknown subcommand '$sub' (use: path|get|present|set|all|init|keys)" >&2 ;;
esac
exit 0
