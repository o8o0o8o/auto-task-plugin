#!/usr/bin/env bash
# install.sh — symlink auto-task skills + agent + hooks into ~/.claude/,
# and print the settings JSON to merge into ~/.claude/settings.json.
#
# Usage:
#   ./install.sh           # symlink + print settings to stdout
#   ./install.sh --copy    # copy files instead of symlinking (for offline use)
#   ./install.sh --uninstall
#
# Idempotent: re-running replaces existing symlinks that point into this repo
# and leaves unrelated files alone.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SKILLS_DIR="$CLAUDE_DIR/skills"
AGENTS_DIR="$CLAUDE_DIR/agents"

SKILLS=(auto-task auto-task-plan auto-task-implement auto-task-verify auto-task-code-review auto-task-commit auto-task-fix)
AGENTS=(task-execution-verifier.md)

MODE="link"
case "${1:-}" in
  --copy) MODE="copy" ;;
  --uninstall) MODE="uninstall" ;;
  "" ) ;;
  *) echo "Unknown flag: $1" >&2; exit 2 ;;
esac

check_prereqs() {
  local missing=()
  for tool in git gh jq bash; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if (( ${#missing[@]} > 0 )); then
    echo "Missing required tools: ${missing[*]}" >&2
    echo "Install them before continuing. See README.md 'Hard prerequisites'." >&2
    exit 1
  fi
}

link_or_copy() {
  local src="$1" dest="$2"
  if [[ -L "$dest" || -e "$dest" ]]; then
    if [[ -L "$dest" ]] && [[ "$(readlink "$dest")" == "$src" ]]; then
      echo "  ok   $dest"
      return
    fi
    echo "  skip $dest (already exists, not managed by this installer)"
    return
  fi
  if [[ "$MODE" == "copy" ]]; then
    cp -R "$src" "$dest"
    echo "  copy $dest"
  else
    ln -s "$src" "$dest"
    echo "  link $dest"
  fi
}

# Tracks copy-mode (or foreign) leftovers that uninstall can't safely auto-remove.
LEFTOVERS=()

unlink_if_ours() {
  local dest="$1" expected_src="$2"
  if [[ -L "$dest" ]] && [[ "$(readlink "$dest")" == "$expected_src" ]]; then
    rm "$dest"
    echo "  rm   $dest"
  elif [[ -e "$dest" ]]; then
    # Could be a --copy install (a real file/dir, not a symlink) or a foreign
    # file the user manages. We never auto-delete real files — they may hold
    # user edits — but we DO surface them so a copy-mode uninstall isn't silent.
    echo "  skip $dest (not a symlink into this repo — left in place)"
    LEFTOVERS+=("$dest")
  fi
}

install() {
  cat <<'BANNER'
────────────────────────────────────────────────────────────────────
NOTE: The recommended install is now the plugin marketplace, which
auto-wires the skills, agent, AND all hooks (no settings.json editing):

    /plugin marketplace add o8o0o8o/auto-task-plugin
    /plugin install auto-task@auto-task-plugin

This install.sh is the offline / development fallback (symlinks + a
hooks snippet you merge by hand). Continuing with that now.
────────────────────────────────────────────────────────────────────
BANNER
  mkdir -p "$SKILLS_DIR" "$AGENTS_DIR"
  echo "Installing skills into $SKILLS_DIR:"
  for s in "${SKILLS[@]}"; do
    link_or_copy "$REPO_ROOT/skills/$s" "$SKILLS_DIR/$s"
  done
  echo "Installing agents into $AGENTS_DIR:"
  for a in "${AGENTS[@]}"; do
    link_or_copy "$REPO_ROOT/agents/$a" "$AGENTS_DIR/$a"
  done
  print_settings
}

uninstall() {
  echo "Removing symlinks from $SKILLS_DIR:"
  for s in "${SKILLS[@]}"; do
    unlink_if_ours "$SKILLS_DIR/$s" "$REPO_ROOT/skills/$s"
  done
  echo "Removing symlinks from $AGENTS_DIR:"
  for a in "${AGENTS[@]}"; do
    unlink_if_ours "$AGENTS_DIR/$a" "$REPO_ROOT/agents/$a"
  done
  echo
  if (( ${#LEFTOVERS[@]} > 0 )); then
    echo "These were installed with --copy (or are not managed by this installer)"
    echo "and were NOT removed (they may contain edits). Remove manually if desired:"
    for p in "${LEFTOVERS[@]}"; do echo "  rm -rf $p"; done
    echo
  fi
  echo "Note: hooks and permissions entries in ~/.claude/settings.json were"
  echo "not modified. Remove them manually if you no longer want them."
}

print_settings() {
  cat <<EOF

────────────────────────────────────────────────────────────────────
Next step: merge the following into ~/.claude/settings.json.
Do NOT replace the file — preserve your existing keys.
Paths below are absolute and point at this clone ($REPO_ROOT).
────────────────────────────────────────────────────────────────────

{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "$REPO_ROOT/hooks/block-ai-attribution.sh" },
          { "type": "command", "command": "$REPO_ROOT/hooks/enforce-gates.sh" },
          { "type": "command", "command": "$REPO_ROOT/hooks/warn-checkout-drift.sh" }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "$REPO_ROOT/hooks/prevent-mid-protocol-stall.sh" }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "$REPO_ROOT/hooks/check-version.sh" }
        ]
      }
    ]
  }
}

If you already have entries under "hooks.PreToolUse", "hooks.Stop", or
"hooks.SessionStart", append to the existing arrays rather than overwriting them.
EOF
}

check_prereqs

# Ensure hook scripts are executable.
chmod +x "$REPO_ROOT"/hooks/*.sh 2>/dev/null || true

case "$MODE" in
  link|copy) install ;;
  uninstall) uninstall ;;
esac
