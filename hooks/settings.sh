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
#     ${AUTO_TASK_HOME:-$HOME/.claude}/auto-task/<project-key>/settings.json
#
#   <project-key> = "<repo-basename>-<12-char-hash-of-abs-common-dir-parent>".
#   The key is derived from the git *common dir* (`git rev-parse --git-common-dir`),
#   which every linked worktree of one clone shares — so all worktrees of a repo
#   resolve to the SAME settings file (a setting is per-clone, not per-worktree).
#   Outside a git repo, the key falls back to the current directory.
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
#   settings.sh all                       # print merged (defaults ⊔ file) JSON
#   settings.sh init                      # write a documented template if absent
#   settings.sh keys                      # list known default keys
#
# Test hooks (hermetic, no touching a real ~/.claude):
#   AUTO_TASK_SETTINGS_FILE=<path>        # use this file verbatim (skips key derivation)
#   AUTO_TASK_HOME=<dir>                  # relocate the settings root

set -uo pipefail

# --- Built-in defaults (SINGLE SOURCE OF TRUTH) ------------------------------
# Keep this list and the `defaults_json` object below in lockstep.
default_for() {
  case "${1:-}" in
    has_preview_deployment)       printf 'false' ;;
    preview_url)                  printf '' ;;
    preview_wait_mode)            printf 'poll' ;;
    preview_timeout_min)          printf '30' ;;
    preview_poll_interval_sec)    printf '60' ;;
    preview_bypass_header)        printf '' ;;
    preview_post_verdict_comment) printf 'false' ;;
    *)                            printf '' ;;   # unknown key -> empty (fail-open)
  esac
}

# The same defaults as a JSON object (typed: booleans/numbers, not strings), used
# by `all` to merge under the file and by `init` to seed a template.
defaults_json() {
  jq -n '{
    has_preview_deployment: false,
    preview_url: "",
    preview_wait_mode: "poll",
    preview_timeout_min: 30,
    preview_poll_interval_sec: 60,
    preview_bypass_header: "",
    preview_post_verdict_comment: false
  }'
}

known_keys="has_preview_deployment preview_url preview_wait_mode preview_timeout_min preview_poll_interval_sec preview_bypass_header preview_post_verdict_comment"

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

# --- Merged view (defaults ⊔ file; file wins) --------------------------------
merged_json() {
  local file d
  file="$(resolve_file)"
  d="$(defaults_json 2>/dev/null || printf '{}')"
  if [ -f "$file" ] && jq empty "$file" >/dev/null 2>&1; then
    # right operand of `*` wins for objects -> file overrides defaults.
    jq --argjson d "$d" '$d * .' "$file" 2>/dev/null || printf '%s' "$d"
  else
    printf '%s' "$d"
  fi
}

# --- Subcommands -------------------------------------------------------------
cmd_path() { resolve_file; printf '\n'; }

cmd_keys() { printf '%s\n' "$known_keys" | tr ' ' '\n'; }

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
  # The resolved path lives OUTSIDE the repo by construction (resolve_file
  # targets ~/.claude, keyed off the git common dir — proven by the path/no-write
  # tests), so `init` never writes inside the user's working tree.
  local file dir
  file="$(resolve_file)"
  dir="$(dirname "$file")"
  if [ -f "$file" ]; then
    echo "settings.sh init: settings already exist at $file (left unchanged)." >&2
    printf '%s\n' "$file"
    exit 0
  fi
  mkdir -p "$dir" 2>/dev/null || { echo "settings.sh init: could not create $dir" >&2; exit 0; }
  defaults_json \
    | jq '. + {"_comment":"auto-task project settings. Stored outside your repo; edit values below. Any key you omit falls back to the built-in default. See hooks/settings.sh for the key reference."}' \
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
  all)  cmd_all ;;
  init) cmd_init ;;
  *)    echo "settings.sh: unknown subcommand '$sub' (use: path|get|all|init|keys)" >&2 ;;
esac
exit 0
