#!/usr/bin/env bash
# Blocks commit messages / PR bodies containing AI-attribution markers.
#
# Registered as a PreToolUse hook on Bash. Reads the tool input via stdin
# (Claude Code hook contract: JSON on stdin with a `.tool_input.command` field).
# Exit 2 with a message on stderr blocks the tool call and surfaces the
# message to the model.
#
# SCOPE (why the marker scan is gated): the enforcement target is the text of a
# `git commit` or a `gh pr create|edit` (the commands that write a commit message
# or a PR body). Earlier this hook scanned EVERY Bash command for the marker
# strings, which false-positive-blocked innocuous commands that merely mention
# them — `git log --grep='Co-Authored-By: Claude'`, `grep -rn 'Co-Authored-By:
# Claude' .`, writing docs/tests that reference the markers — in every session.
# We now first confirm the command is a commit / PR-body writer, and only then
# scan it. This drops the false positives WITHOUT weakening real coverage: the
# old scan could only ever catch a marker present INLINE in the command text
# (never one in a `-F <file>` / `--body-file` / editor-driven message, which this
# hook has never seen), and every such inline case is a commit / gh-pr command.
#
# Robustness: works with or without jq. With jq it extracts `.tool_input.command`;
# without jq (or on a parse failure) it falls back to the raw stdin payload — the
# command boundary alternation then also admits the JSON value's opening `"`, and
# the marker strings appear verbatim in the JSON-encoded command either way, so a
# missing jq can never silently let an attribution marker through on a commit/PR.

set -uo pipefail

input="$(cat)"

cmd_is_raw=0
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
  # jq failed to parse (malformed payload) or the field was empty -> fall back to
  # the raw input so we still scan a commit/PR rather than an empty string.
  if [ -z "$cmd" ]; then cmd="$input"; cmd_is_raw=1; fi
else
  cmd="$input"; cmd_is_raw=1
fi

# --- Scope guard: is this a commit-message / PR-body writer? -------------------
# The commit sub-patterns MIRROR enforce-gates.sh's detector VERBATIM so this hook
# catches the same commit forms (global opts / env prefix / wrappers / quoted
# values / path-qualified git) without re-introducing a bypass; a `gh pr
# create|edit` branch is added for PR bodies. Kept inline (not a shared lib) to
# hold this fix to one file — a future hooks/lib/ split should dedupe it against
# enforce-gates.sh (see audit finding P6). If the two ever drift, THIS hook merely
# fails safe by scanning fewer commands; enforce-gates.sh remains authoritative.
sq="'"
# A shell "value" token: double-quoted span, single-quoted span, or a run of
# non-space chars — so a quoted value containing spaces does not break the walk.
val="(\"[^\"]*\"|${sq}[^${sq}]*${sq}|[^[:space:]])+"
# Optional leading command wrappers (bounded allowlist; engage only at a boundary).
wrap="((sudo|command|env|nice|doas|time|xargs)[[:space:]]+)*"
# Optional leading environment assignments (value may be quoted-with-spaces).
envp="([A-Za-z_][A-Za-z0-9_]*=${val}?[[:space:]]+)*"
# git / gh, optionally path-qualified (`/usr/bin/git`, `./gh`).
gitq="([^[:space:]]*/)?git"
ghq="([^[:space:]]*/)?gh"
# global options before the subcommand: each a -token, optionally followed by one
# value arg. grep matching is existential, so a flag directly before the verb
# still leaves the verb to match.
opts="([[:space:]]+-[^[:space:]]+([[:space:]]+${val})?)*"
commit_mid="${wrap}${envp}${gitq}${opts}[[:space:]]+commit(\\b|\$)"
pr_mid="${wrap}${envp}${ghq}${opts}[[:space:]]+pr${opts}[[:space:]]+(create|edit)(\\b|\$)"
# `git`/`gh` anchored to a command boundary (start / shell separator `; & |` /
# backtick / `$(` / — raw only — the JSON value's opening `"`), so prose never
# matches. Mirrors enforce-gates.sh's leading alternation.
if [ "$cmd_is_raw" -eq 1 ]; then
  target_re="(^|[;&|\`]|\\\$\\(|\")[[:space:]]*(${commit_mid}|${pr_mid})"
else
  target_re="(^|[;&|\`]|\\\$\\()[[:space:]]*(${commit_mid}|${pr_mid})"
fi
# Not a commit / PR-body writer -> nothing to enforce (this is the fix: unrelated
# commands that merely mention the markers are no longer blocked).
printf '%s' "$cmd" | LC_ALL=C grep -qE "$target_re" || exit 0

# --- The command writes a commit message / PR body: enforce the marker ban ----
if printf '%s' "$cmd" | LC_ALL=C grep -qE 'Co-Authored-By:[[:space:]]*Claude|Generated with \[Claude Code\]|🤖 Generated'; then
  printf 'Blocked by auto-task-plugin: commit messages and PR bodies must NOT contain "Co-Authored-By: Claude", "🤖 Generated with [Claude Code]", or any other AI-attribution marker. Rewrite the command without those lines and try again.\n' >&2
  exit 2
fi

exit 0
