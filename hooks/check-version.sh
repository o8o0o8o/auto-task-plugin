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

# --- compare; notify ONLY when strictly behind ------------------------------
[ "$LOCAL_V" = "$REMOTE_V" ] && emit_silent
newest="$(printf '%s\n%s\n' "$LOCAL_V" "$REMOTE_V" | sort -V 2>/dev/null | tail -n1)"
[ "$newest" = "$REMOTE_V" ] || emit_silent   # local >= remote -> nothing to do

msg="auto-task $REMOTE_V is available (you have $LOCAL_V). Update with: /plugin update auto-task"
ctx="A newer version of the auto-task plugin is available upstream: $REMOTE_V (installed: $LOCAL_V). If relevant, suggest the user run /plugin update auto-task."
jq -cn --arg m "$msg" --arg c "$ctx" \
  '{systemMessage:$m, hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}' 2>/dev/null \
  || printf '%s\n' "$msg"
exit 0
