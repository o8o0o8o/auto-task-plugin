#!/usr/bin/env bash
# Blocks commits/PR bodies containing AI-attribution markers.
#
# Registered as a PreToolUse hook on Bash. Reads the tool input via stdin
# (Claude Code hook contract: JSON on stdin with a `.tool_input.command` field).
# Exit 2 with a message on stderr blocks the tool call and surfaces the
# message to the model.
#
# Robustness: works with or without jq. With jq it extracts the command field;
# without jq it scans the raw stdin payload (the marker strings appear verbatim
# in the JSON-encoded command either way), so a missing jq can never silently
# let an attribution marker through.

set -uo pipefail

input="$(cat)"

if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
  # If jq failed to parse (malformed payload), fall back to the raw input so we
  # still scan for markers rather than scanning an empty string.
  [ -n "$cmd" ] || cmd="$input"
else
  cmd="$input"
fi

if printf '%s' "$cmd" | LC_ALL=C grep -qE 'Co-Authored-By:[[:space:]]*Claude|Generated with \[Claude Code\]|🤖 Generated'; then
  printf 'Blocked by auto-task-plugin: commit messages and PR bodies must NOT contain "Co-Authored-By: Claude", "🤖 Generated with [Claude Code]", or any other AI-attribution marker. Rewrite the command without those lines and try again.\n' >&2
  exit 2
fi

exit 0
