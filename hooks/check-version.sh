#!/usr/bin/env bash
# check-version.sh — SessionStart hook. Best-effort notice when a newer
# auto-task plugin version exists upstream on GitHub.
#
# Design contract: a notification hook must NEVER break or noticeably slow a
# session. Every error path (no jq, no curl, offline, malformed JSON, bad
# version strings, corrupt cache) exits 0 with no output. It only ever prints
# when it is certain the installed version is STRICTLY behind upstream.
#
# Portable for every installer: self-locates via $CLAUDE_PLUGIN_ROOT (exported
# to plugin hooks) and falls back to its own path for dev/symlink installs.
# Throttles to at most one network check per 24h using $CLAUDE_PLUGIN_DATA,
# which persists across plugin updates.
#
# Test seams (harmless in production; used by the acceptance-criteria checks):
#   AUTO_TASK_REMOTE_VERSION  inject the upstream version, skipping the network
#   AUTO_TASK_VERSION_URL     override the fetch URL (point at an unreachable
#                             host to exercise the real curl-failure branch)
#   AUTO_TASK_SKIP_THROTTLE=1 bypass the 24h cache

set -u

emit_silent() { exit 0; }

# --- version compare (pure bash; no dependency on `sort -V`) -----------------
# _ver_parse "X.Y.Z[-pre][+build]" -> echoes "MAJOR MINOR PATCH PREFLAG"
# (build metadata stripped; PREFLAG=1 when a prerelease suffix is present).
# Returns nonzero (and echoes nothing) when the core is not numeric-dotted.
_ver_parse() {
  local v="${1:-}" core pre="" maj min pat IFS='.'
  v="${v%%+*}"                                   # drop build metadata
  core="${v%%-*}"                                # core = part before first '-'
  case "$v" in *-*) pre="${v#*-}" ;; esac
  case "$core" in ''|*[!0-9.]*) return 1 ;; esac # core must be digits + dots
  set -- $core
  maj="${1:-0}"; min="${2:-0}"; pat="${3:-0}"
  maj="${maj:-0}"; min="${min:-0}"; pat="${pat:-0}"
  case "$maj$min$pat" in ''|*[!0-9]*) return 1 ;; esac
  printf '%d %d %d %d' "$((10#$maj))" "$((10#$min))" "$((10#$pat))" \
    "$([ -n "$pre" ] && printf 1 || printf 0)"
}

# _ver_newer REMOTE LOCAL -> true (0) iff REMOTE is STRICTLY newer than LOCAL.
# Conservative: any parse failure or ambiguity returns false (stay silent).
_ver_newer() {
  local ra rb rmaj rmin rpat rpre lmaj lmin lpat lpre
  ra="$(_ver_parse "${1:-}")" || return 1
  rb="$(_ver_parse "${2:-}")" || return 1
  set -- $ra; rmaj="$1"; rmin="$2"; rpat="$3"; rpre="$4"
  set -- $rb; lmaj="$1"; lmin="$2"; lpat="$3"; lpre="$4"
  [ "$rmaj" -ne "$lmaj" ] && { [ "$rmaj" -gt "$lmaj" ]; return; }
  [ "$rmin" -ne "$lmin" ] && { [ "$rmin" -gt "$lmin" ]; return; }
  [ "$rpat" -ne "$lpat" ] && { [ "$rpat" -gt "$lpat" ]; return; }
  # cores equal: newer only if LOCAL is a prerelease and REMOTE is a full release
  [ "$lpre" = "1" ] && [ "$rpre" = "0" ]
}

# --- locate the plugin root + manifest --------------------------------------
ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$ROOT" ]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)" || emit_silent
fi
MANIFEST="$ROOT/.claude-plugin/plugin.json"
[ -f "$MANIFEST" ] || emit_silent

command -v jq >/dev/null 2>&1 || emit_silent

# --- installed version ------------------------------------------------------
LOCAL_V="$(jq -r '.version // empty' "$MANIFEST" 2>/dev/null)"
[ -n "$LOCAL_V" ] || emit_silent

# --- throttle: at most one network check per 24h ----------------------------
DATA_DIR="${CLAUDE_PLUGIN_DATA:-}"
STAMP=""
[ -n "$DATA_DIR" ] && STAMP="$DATA_DIR/.last-version-check"
now="$(date +%s 2>/dev/null || echo 0)"
if [ "${AUTO_TASK_SKIP_THROTTLE:-}" != "1" ] && [ -n "$STAMP" ] && [ -f "$STAMP" ]; then
  last="$(cat "$STAMP" 2>/dev/null || echo 0)"
  case "$last" in *[!0-9]*|'') last=0 ;; esac   # corrupt/empty stamp -> stale
  if [ "$now" -gt 0 ] && [ "$last" -gt 0 ] && [ $((now - last)) -lt 86400 ]; then
    emit_silent
  fi
fi

# --- upstream version -------------------------------------------------------
REMOTE_V="${AUTO_TASK_REMOTE_VERSION:-}"
if [ -z "$REMOTE_V" ]; then
  command -v curl >/dev/null 2>&1 || emit_silent
  URL="${AUTO_TASK_VERSION_URL:-https://raw.githubusercontent.com/o8o0o8o/auto-task-plugin/main/.claude-plugin/plugin.json}"
  body="$(curl -fsS -m 5 "$URL" 2>/dev/null)" || body=""
  REMOTE_V="$(printf '%s' "$body" | jq -r '.version // empty' 2>/dev/null)"
fi

# record the attempt (success OR failure) so we don't re-hit the network for 24h
if [ -n "$STAMP" ] && [ "$now" -gt 0 ]; then
  mkdir -p "$DATA_DIR" 2>/dev/null && printf '%s\n' "$now" > "$STAMP" 2>/dev/null || true
fi

# offline / unreachable / malformed upstream -> nothing to say
[ -n "$REMOTE_V" ] || emit_silent
case "$REMOTE_V" in *[!0-9.a-zA-Z+-]*) emit_silent ;; esac   # not version-shaped

# --- compare; notify ONLY when remote is strictly newer ---------------------
_ver_newer "$REMOTE_V" "$LOCAL_V" || emit_silent

msg="auto-task $REMOTE_V is available (you have $LOCAL_V). Update with: /plugin update auto-task@auto-task-plugin"
ctx="A newer version of the auto-task plugin is available upstream: $REMOTE_V (installed: $LOCAL_V). If relevant, suggest the user run /plugin update auto-task@auto-task-plugin."
jq -cn --arg m "$msg" --arg c "$ctx" \
  '{systemMessage:$m, hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}' 2>/dev/null \
  || printf '%s\n' "$msg"
exit 0
