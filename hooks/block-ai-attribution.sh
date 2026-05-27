#!/usr/bin/env bash
# Blocks commits/PR bodies containing AI-attribution markers.
#
# Registered as a PreToolUse hook on Bash. Reads the tool input via stdin
# (Claude Code hook contract: JSON on stdin with a `.tool_input.command` field).
# Exit 2 with a message on stderr blocks the tool call and surfaces the
# message to the model.

set -euo pipefail

cmd="$(jq -r '.tool_input.command // ""')"

if printf '%s' "$cmd" | LC_ALL=C grep -qE 'Co-Authored-By:[[:space:]]*Claude|Generated with \[Claude Code\]|🤖 Generated'; then
  printf 'Blocked by auto-task-plugin: commit messages and PR bodies must NOT contain "Co-Authored-By: Claude", "🤖 Generated with [Claude Code]", or any other AI-attribution marker. Rewrite the command without those lines and try again.\n' >&2
  exit 2
fi

exit 0
