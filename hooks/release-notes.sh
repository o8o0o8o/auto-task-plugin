#!/usr/bin/env bash
# release-notes.sh — SessionStart hook. Shows a short, user-facing summary of what
# changed the first time a session starts on a NEW plugin version.
#
# Deliberately a separate hook from check-version.sh, which answers a different
# question ("a newer version exists upstream"). This one answers "here is what the
# version you now HAVE contains" and makes NO network request at all: it reads only
# the notes file bundled with the installed plugin.
#
# Design contract (inherited from check-version.sh — a notification hook must NEVER
# break or noticeably slow a session): every error path exits 0 with no output. No
# network, no markdown parsing; it reads the small bundled
# `.claude-plugin/release-notes.json` that `scripts/build-release-notes.sh`
# generates from CHANGELOG.md at release time.
#
# SHOWN AT MOST ONCE PER VERSION, via a stamp at
#   ${AUTO_TASK_HOME:-$HOME/.claude}/auto-task/last-seen-version
# Deliberately ONE file, not keyed by plugin root. Keying by root was tried and
# reverted: a marketplace root path contains the version (.../auto-task/0.24.0/), so
# every update produced a new key, no stamp, and therefore a permanent "first
# install" -> the notice never fired at all for the primary install path. The
# problem keying was meant to solve (two wired installs at different versions
# re-notifying each other forever) is a rare misconfiguration and stays a recorded
# follow-up; breaking the common case to fix it is the wrong trade.
# That root is used (rather than $CLAUDE_PLUGIN_DATA, which check-version.sh uses
# for its 24h throttle) because it is stable and persists across plugin updates —
# the same root as settings.sh and the telemetry install id. A lost throttle stamp
# merely costs one extra network check; a lost "already read this" stamp would
# re-show notes the user has already seen.
#
# THREE RULES THAT LOOK LIKE EDGE CASES BUT ARE THE WHOLE DESIGN:
#
#   1. FIRST INSTALL IS SILENT. No stamp means no prior version, so there is no
#      delta to report — seed the stamp and say nothing. (This also makes the
#      rollout of this very feature quiet: nobody is greeted by notes for a
#      version they did not knowingly upgrade to.)
#   2. "NOTHING TO SAY" ADVANCES THE STAMP; "CANNOT DETERMINE" DOES NOT. A valid
#      notes file that simply has no entry for this version is a settled fact (an
#      internal-only release the maintainer marked `skip`) — stay silent and
#      advance. But if the notes file is missing/unparseable or jq is absent, we
#      cannot tell whether there was news; leave the stamp alone so the notes are
#      retried next session instead of lost forever.
#   3. IF THE STAMP CANNOT BE WRITTEN, THE NOTICE IS SUPPRESSED. The stamp is
#      written BEFORE printing. On a read-only HOME / sandboxed install, a
#      notifier that cannot remember would otherwise re-print every single
#      session — the loudest possible failure for a hook that must not disrupt.
#      Silence is the correct degradation.
#
# Test seams (harmless in production):
#   AUTO_TASK_HOME=<dir>            relocate the stamp root
#   AUTO_TASK_PLUGIN_ROOT=<dir>     override the plugin root being reported on
#   AUTO_TASK_NOTES_FILE=<path>     override the notes file
#   --plain | AUTO_TASK_OUTPUT=plain  emit the bare notice instead of SessionStart JSON

set -u

emit_silent() { exit 0; }

# Output mode: default = SessionStart JSON; plain = the bare notice.
# Parsed with safe expansion (set -u; the SessionStart invocation passes no args).
PLAIN=0
case "${1:-}" in --plain) PLAIN=1 ;; esac
[ "${AUTO_TASK_OUTPUT:-}" = "plain" ] && PLAIN=1

# --- locate the plugin root + manifest (same contract as check-version.sh) ----
# `${x%/*}` rather than `dirname`. The two sibling SessionStart hooks spell this with
# `dirname`, and the `2>/dev/null` in that idiom sits on the `cd` - NOT on the inner
# `$(dirname ...)` - so with a broken PATH bash reports `dirname: command not found` on
# the inherited stderr. 60 bytes at every session start, which contradicts this file's
# own header contract that every error path emits nothing on either stream. Parameter
# expansion is a builtin, so the dependency disappears instead of being muffled. The
# `%/*` case where the path has no slash is handled by the `.` fallback.
_self="${BASH_SOURCE[0]:-$0}"
case "$_self" in */*) _selfdir="${_self%/*}" ;; *) _selfdir="." ;; esac
ROOT="${AUTO_TASK_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
if [ -z "$ROOT" ]; then
  ROOT="$(cd "$_selfdir/.." 2>/dev/null && pwd)" || emit_silent
fi
MANIFEST="$ROOT/.claude-plugin/plugin.json"
[ -f "$MANIFEST" ] || emit_silent

command -v jq >/dev/null 2>&1 || emit_silent

INSTALLED="$(jq -r '.version // empty' "$MANIFEST" 2>/dev/null)"
[ -n "$INSTALLED" ] || emit_silent
case "$INSTALLED" in *[!0-9.a-zA-Z+-]*) emit_silent ;; esac   # not version-shaped

# --- the "already seen" stamp -------------------------------------------------
# $HOME is guarded rather than assumed: under `set -u` a bare $HOME expansion
# aborts the hook with an unbound-variable error and a NONZERO exit, which would
# break the "every error path exits 0 with no output" contract above. A stampless
# environment simply means we cannot remember, so we stay silent.
_home="${AUTO_TASK_HOME:-${HOME:-}}"
[ -n "$_home" ] || emit_silent
case "${AUTO_TASK_HOME:-}" in
  '') STAMP_DIR="$_home/.claude/auto-task" ;;   # default root: ~/.claude
  *)  STAMP_DIR="$_home/auto-task" ;;           # explicit override is the root
esac
STAMP="$STAMP_DIR/last-seen-version"

# write_stamp <version> -> 0 on success. Never prints, on stdout OR stderr.
# The write runs in a subshell so `2>/dev/null` is installed BEFORE the `>`
# redirection is attempted; written the other way round, bash reports a failing
# `> "$STAMP"` on the inherited stderr (leaking a filesystem path at every
# session start) precisely in the read-only-HOME case this must degrade quietly.
write_stamp() {
  # REFUSE anything that is not a regular file. Opening a FIFO for writing BLOCKS until
  # a reader appears, and rule 1 below routes every non-regular stamp here (`[ ! -f ]` is
  # true for a FIFO), so a FIFO at this path hung the session start indefinitely - the
  # worst failure available to a SessionStart hook, and strictly worse than the stderr
  # leak two rounds spent closing. A character device would be written to instead, which
  # for a symlink to /dev/tty means printing into the user terminal. `-e` before `-f` so
  # a missing stamp (the normal first-install path) still proceeds.
  if [ -e "$STAMP" ] && [ ! -f "$STAMP" ]; then return 1; fi
  ( mkdir -p "$STAMP_DIR" && printf '%s\n' "$1" > "$STAMP" ) 2>/dev/null || return 1
  return 0
}

# Rule 1: first install — seed and stay silent.
if [ ! -f "$STAMP" ]; then
  write_stamp "$INSTALLED" || true
  emit_silent
fi

# Read in a SUBSHELL, for exactly the reason write_stamp does. Redirections are
# applied left to right, so `< "$STAMP" 2>/dev/null` lets bash report a failing open
# on the INHERITED stderr before the suppression is installed - leaking the user's
# absolute home path at every session start. An unreadable stamp FILE (root-owned from
# a sudo-run session, a restrictive ACL or umask, NFS root-squash, a shared home) is
# the shape that reaches here with a failing open, and it does not self-heal: the
# write below fails on the same file, so the stamp never moves and the leak repeats
# every session forever. Three Gate B rounds probed an unreadable stamp DIRECTORY, a
# directory-as-stamp and a garbage stamp; the unreadable regular file was the one that
# reached this line. The write path carried this fix from the start - this is the same
# hazard on the read side.
# CANNOT-OPEN and CORRUPT are separated, and neither uses an external command.
#
# The previous form was `tr -d ' \t\n\r' < "$STAMP"` in a subshell. The subshell fixed
# the stderr leak, but it also collapsed EVERY failure into the empty string - which the
# corrupt-stamp branch below then treats as a settled fact and reseeds, ADVANCING the
# stamp. So an unreachable or failing `tr` (a PATH without /usr/bin while /bin still has
# mkdir, a wrapper that exits non-zero) silently consumed the notice and no later session
# could recover it. That inverts this file's own Rule 2: a failure to read is a "cannot
# determine", not "no news". `dirname` was removed for being an unguarded external at
# round 23; `tr` was the last one, and the comment claiming the hook depends on no
# external command was one command short of true.
#
# Openability is tested with `:` (a builtin) inside a subshell, so a failing open is both
# suppressed AND distinguishable from an empty file. Whitespace is then stripped by
# parameter expansion. `read -r` also takes only the FIRST line, which is stricter than
# the old whole-file strip: a two-line stamp used to concatenate into something that
# still looked version-shaped.
if ! ( : < "$STAMP" ) 2>/dev/null; then
  # Cannot determine what was last seen. Leave the stamp EXACTLY as it is so the notice
  # is retried once the condition clears, and say nothing.
  emit_silent
fi
_seen_raw="$( (IFS= read -r _seen_line < "$STAMP"; printf '%s' "${_seen_line:-}") 2>/dev/null )"
SEEN="${_seen_raw//[$' \t\r\n']/}"
# A corrupt/empty stamp is indistinguishable from a first install: reseed quietly
# rather than reporting a delta against garbage. Reachable only when the file OPENED,
# so reseeding here is a settled fact rather than a guess.
case "$SEEN" in
  ''|*[!0-9.a-zA-Z+-]*) write_stamp "$INSTALLED" || true; emit_silent ;;
esac

# Nothing changed since the last session — the common case, and the cheapest exit.
[ "$SEEN" = "$INSTALLED" ] && emit_silent

# --- render the notes for what changed ---------------------------------------
NOTES="${AUTO_TASK_NOTES_FILE:-$ROOT/.claude-plugin/release-notes.json}"

LIB="$_selfdir/lib/release-notes-render.sh"
# Regular file, not merely readable: `.` on a FIFO blocks until a writer appears, which
# would hang the session start. The lib ships inside the plugin so this is remote, but it
# is the same class as the FIFO stamp and the FIFO notes file and costs one test.
[ -f "$LIB" ] && [ -r "$LIB" ] || emit_silent
# shellcheck source=lib/release-notes-render.sh
. "$LIB" 2>/dev/null || emit_silent

body="$(rnr_render "$NOTES" "$SEEN" "$INSTALLED")"
rc=$?

# Rule 2a: could not determine (no notes file / unparseable / no jq) — say nothing
# AND leave the stamp untouched so this is retried, not silently consumed.
[ "$rc" -ne 0 ] && emit_silent

# Rule 2b: valid data, genuinely nothing to report (e.g. an internal-only release).
# Settled fact -> advance the stamp so we don't re-check every session.
if [ -z "$body" ]; then
  write_stamp "$INSTALLED" || true
  emit_silent
fi

# Rule 3: record BEFORE emitting. If we cannot remember having shown this, we must
# not show it — otherwise it repeats every session.
write_stamp "$INSTALLED" || emit_silent

msg="auto-task is now on $INSTALLED — what's new:
$body"
ctx="The auto-task plugin version changed to $INSTALLED (previously $SEEN). Its release notes were just shown to the user; this is informational only and requires no action."

if [ "$PLAIN" = "1" ]; then
  printf '%s\n' "$msg"
  exit 0
fi
jq -cn --arg m "$msg" --arg c "$ctx" \
  '{systemMessage:$m, hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}' 2>/dev/null \
  || printf '%s\n' "$msg"
exit 0
