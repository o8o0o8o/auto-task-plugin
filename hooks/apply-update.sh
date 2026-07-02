#!/usr/bin/env bash
# apply-update.sh — apply an auto-task plugin update non-interactively, so the
# user never has to type an update command by hand. Invoked on opt-in from the
# Phase-1 version check (see skills/auto-task/SKILL.md) and runnable standalone.
#
# Design contract: FAIL OPEN. Every unsupported/broken path exits nonzero with a
# clear single-line message and mutates NOTHING it wasn't asked to; the caller
# falls back to printing the manual `/plugin update …` command. It updates git
# with fast-forward only (never a destructive or history-rewriting operation) so
# a dev's local work is never clobbered, and it NEVER switches the dev's branch.
#
# Layout detection is POSITIVE (never "not git ⇒ marketplace"):
#   marketplace  — plugin root lives under a `plugins/cache/` dir
#                  → `claude plugin update auto-task@auto-task-plugin --scope <scope>`
#   git          — plugin root is inside a git work tree
#                  → `git -C <root> fetch --quiet && git -C <root> pull --ff-only`
#   unknown/copy — anything else (e.g. `install.sh --copy`) → clear unsupported msg
#
# Result line (stdout): `apply-update: <layout> <status> — <detail>`. SUCCESS or
# FAILURE is the EXIT CODE, never the text (the update tools' stdout is not a
# stable contract).
#
# Test seam:
#   AUTO_TASK_UPDATE_DRYRUN=1  print the layout + the exact command it WOULD run,
#                              exit 0, and mutate/invoke nothing.

set -u

PLUGIN_ID="auto-task@auto-task-plugin"

emit() { printf 'apply-update: %s\n' "$1"; }

DRYRUN=0
[ "${AUTO_TASK_UPDATE_DRYRUN:-}" = "1" ] && DRYRUN=1

# --- locate the plugin root (same contract as check-version.sh) --------------
# $CLAUDE_PLUGIN_ROOT when exported; otherwise self-locate via BASH_SOURCE, which
# is robust for every install layout since this script sits at <root>/hooks/.
ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$ROOT" ]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)" || {
    emit "unknown failed — cannot locate plugin root"; exit 1; }
fi

# --- classify layout (positive detection) ------------------------------------
case "$ROOT" in
  */plugins/cache/*) LAYOUT="marketplace" ;;
  *)
    if command -v git >/dev/null 2>&1 \
       && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      LAYOUT="git"
    else
      LAYOUT="unknown"
    fi
    ;;
esac

case "$LAYOUT" in
  git)
    if [ "$DRYRUN" = 1 ]; then
      emit "git dry-run — would run: git -C $ROOT fetch --quiet && git -C $ROOT pull --ff-only (current branch, never forced)"
      exit 0
    fi
    up="$(git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || up=""
    if [ -z "$up" ]; then
      emit "git failed — current branch has no upstream configured; not switching branches (be on the release-tracking branch to update)"
      exit 1
    fi
    if ! git -C "$ROOT" fetch --quiet 2>/dev/null; then
      emit "git failed — fetch failed (offline or no remote)"
      exit 1
    fi
    before="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"
    if ! git -C "$ROOT" pull --ff-only >/dev/null 2>&1; then
      emit "git failed — cannot fast-forward (dirty or diverged tree); resolve manually (never forced)"
      exit 1
    fi
    after="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"
    if [ "$before" = "$after" ]; then
      # Pull succeeded but HEAD did not move: this branch is already up to date
      # and does NOT carry the newer release. Do NOT claim "applied" or tell the
      # user to restart — that would loop (restart, still behind, re-offer). Fail
      # with a clear pointer instead, so the caller's fail-open guidance kicks in.
      emit "git noop — $up already up to date; the newer release is on a different branch or remote, so nothing was applied (switch to the release-tracking branch, or update your remote, then retry)"
      exit 1
    fi
    emit "git applied — fast-forwarded $up; restart the session to load the new version"
    exit 0
    ;;

  marketplace)
    if ! command -v claude >/dev/null 2>&1; then
      emit "marketplace failed — claude CLI not found on PATH"
      exit 1
    fi
    # Resolve the install scope from `claude plugin list` (read-only); default
    # `user`. Parse the block for our plugin id and read its `Scope:` line.
    scope="user"
    s="$(claude plugin list 2>/dev/null | awk -v id="$PLUGIN_ID" '
        index($0, id) { found=1; next }
        found && /Scope:/ {
          sub(/.*Scope:[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit
        }
        found && index($0, "@") { exit }   # reached the next plugin block
      ')"
    case "$s" in user|project|local|managed) scope="$s" ;; esac

    if [ "$DRYRUN" = 1 ]; then
      emit "marketplace dry-run — would run: claude plugin update $PLUGIN_ID --scope $scope"
      exit 0
    fi
    if claude plugin update "$PLUGIN_ID" --scope "$scope" >/dev/null 2>&1; then
      emit "marketplace applied — updated $PLUGIN_ID (scope $scope); restart the session to load the new version"
      exit 0
    fi
    emit "marketplace failed — 'claude plugin update' exited nonzero"
    exit 1
    ;;

  *)
    emit "unknown unsupported — copy or unrecognized install layout at $ROOT; re-run install.sh from your clone to update"
    exit 1
    ;;
esac
