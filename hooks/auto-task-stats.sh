#!/usr/bin/env bash
# auto-task-stats — read-only aggregator over auto-task run outcomes.
#
# NOT a hook. A standalone maintainer tool (wrapped by the auto-task-stats skill)
# that answers: what is auto-task's completion rate, and where do runs stall?
#
# It reads two sources and merges them:
#   1. .auto-task/outcomes.jsonl  — the append-only archive of COMPLETED runs
#      (written by the record-outcome.sh Stop hook; survives folder pruning).
#   2. every live .auto-task/*/STATE.json on disk — so in-flight and stalled runs
#      (which never reach the archive) are still counted, and a just-completed
#      run that predates opt-in is picked up.
#
# Dedup is on branch+base (a run's identity), NOT branch alone: a reused branch
# folder forks a new base, so a fresh run must count separately — keying on
# branch alone would collapse it into the old archived row (the same branch-reuse
# bug record-outcome.sh's base-scoped sentinel avoids).
#
# Forward-compat: every field is read with a `// <default>`, so a row written by
# an older or newer schema (missing a field) is tolerated, never a hard error.
#
# Usage:  auto-task-stats.sh [STALE_DAYS] [--recalibrate]
#   STALE_DAYS (default 7, or $AUTO_TASK_STALL_DAYS): a live, approved, non-done
#   run whose newest history entry is older than this is classified "stalled";
#   otherwise "in-flight".
#   --recalibrate: additionally print a SUGGESTED estimate.sh coefficient
#   adjustment computed from pooled actual/estimate ratios (suggestion only — it
#   never edits estimate.sh; you apply it by hand). Gated behind a sample floor.
#
# Env-configurable thresholds (all optional; conservative defaults):
#   AUTO_TASK_STATS_MDE_PP        (default 15)  regression-guard minimum detectable
#                                               effect for RATE metrics, in percentage points
#   AUTO_TASK_STATS_RATIO_MDE     (default 0.5) MDE for est/act RATIO metrics (x)
#   AUTO_TASK_STATS_MIN_SAMPLE    (default 10)  min pooled runs PER VERSION before the
#                                               regression guard compares two versions
#   AUTO_TASK_STATS_RECAL_MIN_SAMPLE (default 10) min measured runs before --recalibrate suggests
# Exit 0 always (read-only; nothing to fail closed on).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# --- The run clock (fail-open) -------------------------------------------------
# Supplies the MEASURED duration for live STATE.json files below. Archived ledger
# rows already carry their own `duration_min`, so only the live path needs this.
# If the helper cannot be sourced, RC_AVAILABLE stays 0 and every live row falls
# back to the history-timestamp formula — exactly the pre-clock behavior.
RC_AVAILABLE=0
if [ -f "$SCRIPT_DIR/lib/run-clock.sh" ]; then
  # shellcheck source=lib/run-clock.sh
  if . "$SCRIPT_DIR/lib/run-clock.sh" 2>/dev/null && command -v rc_duration_min >/dev/null 2>&1; then
    RC_AVAILABLE=1
  fi
fi

# --- Parse args: an optional numeric STALE_DAYS + an optional --recalibrate ----
RECAL=0
STALE_DAYS=""
for a in "$@"; do
  case "$a" in
    --recalibrate) RECAL=1 ;;
    *[!0-9]*|'') : ;;              # ignore non-numeric tokens
    *) [ -z "$STALE_DAYS" ] && STALE_DAYS="$a" ;;
  esac
done
[ -n "$STALE_DAYS" ] || STALE_DAYS="${AUTO_TASK_STALL_DAYS:-7}"
case "$STALE_DAYS" in ''|*[!0-9]*) STALE_DAYS=7 ;; esac

# --- estimate.sh location (for the --recalibrate suggestion) -------------------
# The recalibration suggestion prints estimate.sh's CURRENT constants scaled by
# the pooled ratio, so it must READ them rather than carry its own copies. An
# earlier version hardcoded them, which is how they silently went stale through a
# recalibration — the exact failure mode this suggestion exists to fix. Resolved
# as a sibling of this script; env-overridable so a test can point it at a fixture.
EST_SH="${AUTO_TASK_ESTIMATE_SH:-}"
if [ -z "$EST_SH" ]; then
  _sd="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  [ -n "$_sd" ] && EST_SH="$_sd/estimate.sh"
fi

# Read one `NAME=<digits>` assignment out of estimate.sh. Prints nothing when the
# file is unreadable or the constant is absent/non-integer — callers treat empty as
# "could not read" and must NOT substitute a literal.
#
# What the match requires, and why each part is there:
#   * Comments stripped FIRST, full-line AND trailing. estimate.sh documents its
#     constants in prose directly above them, so a comment mentioning e.g.
#     `TIER_BASE_TOK_heavy=999` would otherwise be the first match and be reported
#     as the current constant — and the AC-10 mutation probe, which edits the real
#     assignment, could not catch that. Full-line stripping alone was insufficient:
#     a TRAILING comment on any earlier line had the same effect.
#   * Boundary `(^|[[:space:]]|;)` — the only things that precede a real shell
#     assignment. This rejects a LONGER identifier ending in the same name
#     (`MY_TIER_BASE_TOK_heavy=999`) and a token that merely contains one
#     (`-TIER_BASE_TOK_heavy=999`, a flag, not an assignment). A looser "any
#     non-identifier char" boundary accepted the second.
#   * Trailing `([^0-9.]|$)` — rejects a non-integer rather than truncating it:
#     `PER_AC_MIN=1.5` reads as empty (the honest "could not read" path) instead of
#     silently becoming `1`.
#
# Known limit: awk `exit`s on the FIRST match, whereas bash would use the LAST
# assignment. Only reachable if someone recalibrates by appending an override rather
# than editing the constant in place.
#
# WHY awk AND NOT sed — load-bearing, not taste. This match needs alternation, and
# BRE alternation (`\|`) is a GNU extension that BSD/macOS sed ignores SILENTLY:
# every constant then reads empty, and the fail-open path reports "could not read
# the constants", which looks like a correct message. That exact bug shipped twice
# during this change; only the positive liveness assertions in
# tests/stats-reshape.test.sh caught it. awk has real ERE everywhere. Do not
# "simplify" this back to sed.
est_const() {
  [ -n "$EST_SH" ] && [ -r "$EST_SH" ] || return 0
  awk -v name="$1" '
    { sub(/[ \t]#.*$/, ""); sub(/^[ \t]*#.*$/, "") }
    match($0, "(^|[[:space:]]|;)" name "=[0-9]+([^0-9.]|$)") {
      seg = substr($0, RSTART, RLENGTH)
      if (match(seg, /=[0-9]+/)) { print substr(seg, RSTART + 1, RLENGTH - 1); exit }
    }
  ' "$EST_SH" 2>/dev/null
}

# Regression-guard + recalibration thresholds (env-overridable).
MDE_PP="${AUTO_TASK_STATS_MDE_PP:-15}";        case "$MDE_PP" in ''|*[!0-9]*) MDE_PP=15 ;; esac
MIN_SAMPLE="${AUTO_TASK_STATS_MIN_SAMPLE:-10}"; case "$MIN_SAMPLE" in ''|*[!0-9]*) MIN_SAMPLE=10 ;; esac
RECAL_MIN="${AUTO_TASK_STATS_RECAL_MIN_SAMPLE:-10}"; case "$RECAL_MIN" in ''|*[!0-9]*) RECAL_MIN=10 ;; esac
# ratio MDE is a float; validate and fall back to 0.5. Reject empty, any non
# [0-9.] char, or more than one dot — AND require at least one digit, so a lone
# "." (valid under the char-class test but NOT valid --argjson input, which would
# error the whole agg pass into a silently-blanked report) is caught.
RATIO_MDE="${AUTO_TASK_STATS_RATIO_MDE:-0.5}"
case "$RATIO_MDE" in ''|*[!0-9.]*|*.*.*) RATIO_MDE=0.5 ;; esac
case "$RATIO_MDE" in *[0-9]*) : ;; *) RATIO_MDE=0.5 ;; esac

if ! command -v jq >/dev/null 2>&1; then
  echo "auto-task-stats: jq is not installed (a hard prerequisite of this plugin). Install jq and retry."
  exit 0
fi

# Resolve the project root that owns .auto-task/.
project_dir_base="${CLAUDE_PROJECT_DIR:-$PWD}"
project_dir="$(cd "$project_dir_base" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$project_dir" ] || project_dir="$project_dir_base"

AT="$project_dir/.auto-task"

# --- Clone-wide resolution (ledger + every worktree's .auto-task root) --------
# auto-task isolates each run in its own linked worktree, so BOTH halves of this
# reader have to look clone-wide or they see almost nothing:
#   * the ledger is written to the MAIN working tree (hooks/lib/clone-scope.sh),
#     so resolving it from `$project_dir` finds no file whenever this is invoked
#     from a worktree;
#   * live STATE.json files live in the worktrees, so scanning only `$AT` reports
#     0 in-flight / 0 stalled no matter how many runs are actually on disk — the
#     opposite of what this tool exists to answer, and contrary to the documented
#     promise that live runs are merged in.
# Fail open on every branch: if the helper is unavailable or cannot resolve a main
# worktree (no git, bare repo, not a repo), fall back to the pre-existing
# single-root behavior.
ledger=""
scan_roots=""
if [ -f "$SCRIPT_DIR/lib/clone-scope.sh" ]; then
  # shellcheck source=lib/clone-scope.sh
  if . "$SCRIPT_DIR/lib/clone-scope.sh" 2>/dev/null && command -v cs_ledger_path >/dev/null 2>&1; then
    ledger="$(cs_ledger_path "$project_dir" 2>/dev/null || true)"
    scan_roots="$(cs_autotask_roots "$project_dir" 2>/dev/null || true)"
  fi
fi
[ -n "$ledger" ] || ledger="$AT/outcomes.jsonl"
[ -n "$scan_roots" ] || scan_roots="$AT"

# Nothing to report only when there is NO ledger AND no .auto-task root that actually
# EXISTS anywhere in the clone. Keying this on `$AT` alone was wrong once the other
# two are clone-wide: invoked from a worktree with no .auto-task/ of its own, it would
# bail while a populated ledger and other worktrees' runs sat right there.
#
# Test each root for existence rather than testing `$scan_roots` for emptiness: the
# fallback at the top of this block sets it to `$AT` unconditionally, and `$AT` is
# never an empty string, so an emptiness test could never fire — it would be dead
# code that silently replaced the pre-existing "nothing to report" message.
_any_root=0
while IFS= read -r _root; do
  [ -n "$_root" ] && [ -d "$_root" ] && { _any_root=1; break; }
done <<EOF
$scan_roots
EOF
if [ ! -f "$ledger" ] && [ "$_any_root" -eq 0 ]; then
  echo "auto-task-stats: no .auto-task/ directory in this clone — nothing to report."
  exit 0
fi

# The archiver-equivalent derivation: normalize a done STATE.json into a row so
# live-but-unarchived done runs are counted identically to archived ones. Kept in
# lockstep with record-outcome.sh's jq derivation — the metric fields (est_*/act_*
# + quality-signal trend fields) MUST match that block VERBATIM (a regression test
# asserts the two field sets are identical). est_*/act_* are `null` when unmeasured
# so the accuracy ratio below can exclude them.
#
# DURATION: supplied by the caller as `$clock_dur` + `$clock_state`, resolved per
# state file from the hook-stamped run clock (hooks/lib/run-clock.sh). The state
# is a separate arg because jq's `//` treats `null` identically to absent, so a
# duration deliberately REJECTED by the sanity assertion cannot be expressed as a
# nullable value — it would fall through to the history-derived number. `absent`
# is the only state that reaches the legacy history formula.
DERIVE='
  # NUMERIC COERCION AT THE SOURCE. Every field below that a consumer does arithmetic
  # on is read through num0/numN, because these all come from model-written STATE.json
  # and any of them can legitimately hold a string or a boolean. Two properties of jq
  # make an untyped read dangerous rather than merely wrong: `add` and `/` are FATAL on
  # a mixed type, and a bare `> 0` guard does NOT filter strings out (jq sorts strings
  # after numbers, so "40" > 0 is true) — so a positivity guard passes the bad value
  # straight into the division. A fatal error in the aggregator blanks EVERY metric
  # section of the report instead of one field, which is how a non-numeric
  # first_pass_ac silently emptied a real 9-run report.
  def num0: if type == "number" then . else 0 end;
  def numN: if type == "number" then . else null end;
  # Same discipline for the STRING fields, and for the same reason: a `.[0:N]`
  # slice is just as fatal on a wrong type as `add` is, and it lives outside both
  # numeric guard layers. A numeric `effort.tier` made the whole By-tier table
  # render as headers with no rows, losing the well-formed rows too, with no skip
  # counter touched — the failure was invisible on screen.
  def str0: if type == "string" then . else "" end;
  (.history // []) as $h
  | ($h | map(.at // empty)) as $ats
  | ($ats | first) as $t0
  | ($ats | last) as $t1
  | (if ($t0 != null and $t1 != null)
       then (((($t1 | fromdateiso8601?) // 0) - (($t0 | fromdateiso8601?) // 0)) / 60 | floor)
       else 0 end) as $hdur
  | (if $clock_state == "ok" then $clock_dur
     elif $clock_state == "rejected" then null
     else $hdur end) as $dur
  | (if $clock_state == "absent" then ((.actuals.duration_min | numN) // $dur) else $dur end) as $adur
  | {
      at: ($t1 // ""),
      branch: (.branch // ""),
      base: (.base // ""),
      pr_url: (.pr_url // null),
      plugin_version: (.plugin_version // null),
      terminal_state: "done",
      tier: (.effort.tier | str0),
      tier_initial: ((((.effort.history // []) | first | .from) | str0) as $f
                     | if $f == "" then (.effort.tier | str0) else $f end),
      escalations: ((.effort.history // []) | length),
      fix_iterations: (.iteration.fix | num0),
      review_iterations: (.iteration.review | num0),
      # Mirrors the derivation in record-outcome.sh exactly -- see the note there for
      # why rounds and iterations are both carried, and why the discriminator is the
      # `rounds` KEY rather than `gates.code_review`. This path is the one that made
      # the distinction load-bearing: it derives rows LIVE from STATE.json files still
      # on disk, so a pre-0.30.0 state reaches the aggregator directly, and a `// []`
      # here would feed it a fabricated 0 that med_rounds below cannot exclude.
      review_rounds: (if (.gates.code_review | type) == "object"
                         and (.gates.code_review | has("rounds"))
                      then ((.gates.code_review.rounds // []) | length | num0)
                      else null end),
      # Byte-identical to the copy in record-outcome.sh -- see the long note there for
      # why only `via == "subagent"` counts, why an absent `via` is not independent,
      # and why an absent `rounds` key is null rather than 0. THIS path is why the
      # parity is enforced by a test rather than trusted: it derives rows LIVE from
      # STATE.json files on disk, so the same run reaches the aggregator through two
      # code paths and they must agree.
      review_rounds_independent: (if (.gates.code_review | type) == "object"
                                     and (.gates.code_review | has("rounds"))
                                     and ((.gates.code_review.rounds | type) == "array")
                                  then ((.gates.code_review.rounds
                                          | map(select((.via? // "") == "subagent"))
                                          | length) | num0)
                                  else null end),
      gate_b: (if (.gates.gate_b.passed // false) then "passed" else ((.gates.gate_b.skipped_reason | str0) | .[0:120]) end),
      followups: ((.followups // []) | length),
      duration_min: $dur,
      est_duration_min: (.estimate.duration_min | numN),
      est_tokens: (.estimate.tokens_output | numN),
      est_tokens_scale: (if ((.estimate.tokens_output | numN) != null) then "output"
                         elif ((.estimate.tokens_total | numN) != null) then "total"
                         else null end),
      act_duration_min: $adur,
      act_tokens: (.actuals.tokens_total | numN),
      act_tokens_output: (.actuals.tokens_breakdown.output | numN),
      defects_early: (.quality.defects.early | num0),
      defects_late: (.quality.defects.late | num0),
      flaky: (.quality.flaky // false),
      tests_added: (.quality.tests_added // false),
      diff_loc: (((.quality.diff.loc_added | num0) + (.quality.diff.loc_removed | num0))),
      # NUMBER-ONLY. `quality.planning.first_pass_ac` is model-written and is, in real
      # state files, freely a string ("6/6 self-verify ACs green") or a boolean. The
      # aggregator sums this field, and jq cannot add a number to a string — that is a
      # FATAL error in the single agg pass, which blanks EVERY metric section of the
      # report rather than printing one wrong number. Coercing here keeps the bad value
      # out of the row entirely; the aggregator additionally re-filters, because rows
      # already appended to an append-only ledger cannot be fixed retroactively.
      first_pass_ac: (if ((.quality.planning.first_pass_ac | type) == "number")
                      then .quality.planning.first_pass_ac else null end),
      checks_run: ((.checks // []) | length),
      checks_failed: ((.checks // []) | map(select(.result=="fail")) | length)
    }'

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
rows="$tmp/rows.jsonl"        # deduped DONE rows (archive + live-done)
: > "$rows"
seen="$tmp/seen"; : > "$seen" # branch<TAB>base identities already counted (DONE rows)
# Live NON-terminal sightings are collected here and reduced after the scan, so the
# freshest sighting of a run wins rather than whichever root `find` reached first. Kept
# entirely separate from `$seen`: sharing one set with the done rows would let a
# non-terminal sighting claim a key and SUPPRESS a `done` run found later under another
# root, and would hide a genuinely resumed run whose earlier attempt is already
# archived in the ledger.
live_raw="$tmp/live_raw.tsv";   : > "$live_raw"
live_best="$tmp/live_best.tsv"; : > "$live_best"

now="$(date +%s)"
cutoff=$(( now - STALE_DAYS * 86400 ))

in_flight=0
stalled=0
stalled_list="$tmp/stalled.txt"; : > "$stalled_list"

# Every `grep` on a key below uses `--`. `norm_key` puts the BRANCH first, so a branch
# value beginning with `-` makes grep parse the key as an option; with no file operand
# left, grep then reads the ENCLOSING LOOP's stdin and swallows the rest of the ledger
# or the rest of the find results — every remaining run vanishes with no counter
# touched. hooks/record-outcome.sh already passes `--` for the same reason.
norm_key(){ printf '%s\t%s' "$1" "$2"; }
# Flatten any control character that would break the line-and-field-oriented live
# sighting records below (real newlines/tabs come out of `jq -r` unescaping a
# model-written summary; \037 is the field separator itself).
_san(){ printf '%s' "${1:-}" | tr '\n\r\t\037' '    '; }

# 1. Archive rows (each line one row). Normalize field defaults through jq.
# `|| [ -n "$line" ]` so a final row lacking a trailing newline is not dropped.
skipped_rows=0
# Live-done STATE.json files whose derivation failed (see the done branch below).
# Counted so a dropped completed run is reported rather than silently missing.
skipped_live=0
# The PATHS behind that count, so the report can name them instead of telling the
# maintainer to inspect "the file(s) named by the skip count" — which names none.
skipped_live_list="$tmp/skipped_live.txt"; : > "$skipped_live_list"
if [ -f "$ledger" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    # A line that is not EXACTLY ONE JSON value is COUNTED, not silently dropped.
    #
    # `jq empty` alone is NOT sufficient, and assuming it was hid a real data loss:
    # jq parses a STREAM, so a glued line `{…}{…}` — produced whenever something
    # appended to a ledger that did not end in a newline — passes `jq empty` happily.
    # The consequences compound: the glued line is counted once by `wc -l` below but
    # slurped as TWO elements by the `jq -s` aggregation, so the headline count and the
    # per-tier/rate tables disagree; `jq -r '.branch'` emits two lines and pollutes the
    # dedup keys; and a genuinely-recorded run silently vanishes while this notice
    # stays at zero. `jq -s length` is the actual one-value-per-line check.
    # `length == 1` is necessary but NOT sufficient: a scalar line (`123`, `null`,
    # `[]` — reachable from a hand-edit or a foreign JSONL folded in via the
    # documented `cat … >> …` migration) is exactly one JSON value, so it would be
    # admitted, counted as a done run, and then kill the aggregation on the first
    # `.plugin_version` lookup — blanking the whole report with no skipped-row notice,
    # i.e. the same failure this check exists to report. Require an OBJECT.
    _ok="$(printf '%s' "$line" | jq -s 'length == 1 and (.[0] | type == "object")' 2>/dev/null || echo false)"
    [ "$_ok" = "true" ] || { skipped_rows=$((skipped_rows + 1)); continue; }
    br="$(printf '%s' "$line" | jq -r '.branch // ""' 2>/dev/null || echo "")"
    ba="$(printf '%s' "$line" | jq -r '.base // ""' 2>/dev/null || echo "")"
    key="$(norm_key "$br" "$ba")"
    grep -qxF -- "$key" "$seen" 2>/dev/null && continue
    printf '%s\n' "$key" >> "$seen"
    printf '%s\n' "$line" >> "$rows"
  done < "$ledger"
fi

# 2. Live STATE.json files (branch may contain slashes → use find).
while IFS= read -r sf; do
  [ -n "$sf" ] || continue
  [ -f "$sf" ] || continue
  # An unparseable STATE.json is counted, not dropped in silence — the pipeline
  # rewrites this file continuously, so a killed session can leave it truncated
  # mid-write, and that file may well be a COMPLETED run. Counting it here is what
  # makes skipped_live's promise ("a dropped completed run is reported") true for the
  # unparseable case as well as the underivable one. Unparseable means we cannot know
  # the phase, so it is reported rather than classified.
  if ! jq empty "$sf" 2>/dev/null; then
    skipped_live=$((skipped_live + 1)); printf '%s\n' "$sf" >> "$skipped_live_list"; continue
  fi
  approved="$(jq -r '.approved // false' "$sf" 2>/dev/null || echo false)"
  phase="$(jq -r '.phase // ""' "$sf" 2>/dev/null || echo "")"
  br="$(jq -r '.branch // ""' "$sf" 2>/dev/null || echo "")"
  ba="$(jq -r '.base // ""' "$sf" 2>/dev/null || echo "")"

  # IS THIS FILE A RUN'S STATE, OR A COPY OF ONE? A run's state lives at exactly
  # <root>/<its own branch>/STATE.json, so the file's location must agree with the branch
  # it declares. A snapshot parked under <branch>/artifacts/… declares the real branch but
  # sits at a deeper path, so it is rejected; a genuine run on ANY branch — including one
  # literally named `fixes/typo` or `feat/artifacts` — agrees and is kept.
  #
  # This replaces two earlier attempts that were both wrong in opposite directions. A
  # `-maxdepth` cap dropped real runs on three-segment branches. A `! -path '*/artifacts/*'`
  # filter was worse: `-path` matches the WHOLE absolute path, so it excluded every run in
  # any clone that merely LIVES under a directory named artifacts/recon/fixes (measured: a
  # clone at /…/fixes/repo reported zero runs and then affirmatively denied they existed) —
  # reinstating, for a whole class of clone locations, the very blindness this change
  # removes. Comparing the declared branch against the path is exact, position-independent
  # and depth-independent. Fail-open: a state file with no `.branch` is kept, since
  # dropping a real run is the worse error.
  # Two DIFFERENT kinds of disagreement, and collapsing them would silently drop a run.
  # A snapshot sits UNDER its own branch folder (path_branch starts with "<branch>/"), which
  # is expected and uninteresting — skip it quietly. Anything else is a genuine mismatch: a
  # renamed branch folder, a hand-moved file, a corrupt `.branch`. That may well be a real
  # completed run, so it is COUNTED and named rather than vanishing — the same promise
  # skipped_live makes for unreadable and underivable files.
  if [ -n "$br" ]; then
    _rel="${sf##*/.auto-task/}"; _pb="${_rel%/STATE.json}"
    # Compare by FILE IDENTITY, not by string. A byte compare of a git ref name against a
    # path component is wrong on a case-insensitive filesystem — macOS APFS by default, and
    # Windows. Measured: `git checkout -b Feat/b` reports `Feat/b`, but `mkdir -p
    # .auto-task/Feat/b` beside an existing `.auto-task/feat/` yields `feat/b` on disk, so
    # `find` hands back `feat/b/STATE.json` while `.branch` says `Feat/b`. The string
    # compare then failed and DROPPED a completed run — a regression against base, which
    # counted it — while also misreporting it as unreadable. `-ef` compares device+inode, so
    # the filesystem's own canonicalization (and any symlinked worktree path) is handled by
    # the same test that answers the real question: is this file the one that the branch's
    # own folder holds?
    _match=0
    if [ "$_pb" = "$br" ]; then
      _match=1
    else
      _root_pfx="${sf%"/.auto-task/$_rel"}"
      _expect="$_root_pfx/.auto-task/$br/STATE.json"
      [ -e "$_expect" ] && [ "$sf" -ef "$_expect" ] && _match=1
    fi
    if [ "$_match" -eq 0 ]; then
      case "$_pb" in
        "$br"/*) continue ;;                       # a snapshot under the run's own folder
        *) skipped_live=$((skipped_live + 1)); printf '%s\n' "$sf" >> "$skipped_live_list"; continue ;;
      esac
    fi
  fi

  if [ "$phase" = "done" ]; then
    key="$(norm_key "$br" "$ba")"
    grep -qxF -- "$key" "$seen" 2>/dev/null && continue   # already archived → ledger wins
    # Per-state clock verdict. Resolved here (not once for the whole run) because
    # each STATE.json has its own sibling clock file.
    clock_state="absent"; clock_dur="null"
    if [ "$RC_AVAILABLE" -eq 1 ]; then
      _rc_verdict="$(rc_duration_min "$(rc_clock_path "$sf")" "$sf" 2>/dev/null || echo absent)"
      clock_state="$(rc_verdict_state "$_rc_verdict")"
      clock_dur="$(rc_verdict_value "$_rc_verdict")"
    fi
    # CLAIM THE KEY ONLY AFTER THE DERIVATION SUCCEEDS. Claiming first meant a
    # STATE.json whose derivation errors (the one arithmetic in DERIVE is on
    # `quality.diff.loc_*`, so a string there is enough) both lost that run AND
    # suppressed a well-formed copy of the same run found later at another root —
    # so the run vanished entirely. This is the same claim-before-verify mistake the
    # non-terminal population was fixed for; the done population was still doing it
    # to itself, and the cross-root form only became reachable once this scan went
    # clone-wide. A failed derivation is also COUNTED now, so it cannot be silent.
    _derived="$(jq -c --argjson clock_dur "$clock_dur" --arg clock_state "$clock_state" \
      "$DERIVE" "$sf" 2>/dev/null || true)"
    if [ -n "$_derived" ] && printf '%s' "$_derived" | jq empty 2>/dev/null; then
      printf '%s\n' "$key" >> "$seen"
      printf '%s\n' "$_derived" >> "$rows"
    else
      skipped_live=$((skipped_live + 1)); printf '%s\n' "$sf" >> "$skipped_live_list"
    fi
    continue
  fi

  # Non-done: only count runs that actually started (approved).
  [ "$approved" = "true" ] || continue
  # COLLECT every non-terminal sighting; classify AFTER the scan (see the reduce step
  # below). Deciding here would make the outcome depend on which root `find` reached
  # first: an earlier revision claimed the branch+base key on first sighting and then
  # computed freshness from THAT copy, so a stale copy at one root could report a live
  # run as `stalled` — with the wrong `phase` attributed — in the very "where do runs
  # stall?" list this tool exists to produce. Freshness is a property of the RUN, not
  # of whichever path was walked first, so the freshest sighting has to win.
  newest="$(jq -r '[.history[]?.at // empty] | map(fromdateiso8601? // 0) | max // 0' "$sf" 2>/dev/null || echo 0)"
  case "$newest" in ''|*[!0-9]*) newest=0 ;; esac
  last_phase="$(jq -r '(.history // []) | last | (.phase // .result // "unknown")' "$sf" 2>/dev/null || echo unknown)"
  last_sum="$(jq -r '(.history // []) | last | (.summary // .result // "")' "$sf" 2>/dev/null || echo "")"
  # One record per sighting, with branch and base as their OWN fields — deliberately
  # not `norm_key`, whose output already contains a tab and would therefore shift
  # every later field by one (observed: `newest` received the base SHA, so every live
  # run scored 0 and was reported as stalled).
  #
  # THE SEPARATOR IS \x1f (US), NOT A TAB, and that is load-bearing. A tab is IFS
  # *whitespace*, so `read` collapses runs of it and drops empty fields: a STATE.json
  # with no `base` emits `branch<TAB><TAB>newest…`, which `read` collapses so `newest`
  # receives the phase string, scores 0, and the live run is misreported as stalled
  # (measured). `\x1f` is not whitespace, so empty fields survive intact, and both
  # `sort -t` and `awk -F` accept it.
  #
  # The three free-text fields are also SANITISED, because `jq -r` unescapes `\n` and
  # `\t` in a model-written history summary into real control characters — and a real
  # newline splits one record into two, the continuation of which `awk` then counts as
  # an extra run (measured: NF=1 bogus record, inflating the stalled tally). Before
  # this collect step existed the summary was only ever printed, so a newline in it
  # was merely cosmetic; feeding it to a line-oriented reduce is what made it wrong.
  printf '%s\037%s\037%s\037%s\037%s\n' \
    "$(_san "${br:-?}")" "$(_san "$ba")" "$newest" "$(_san "$last_phase")" "$(_san "$last_sum")" \
    >> "$live_raw"
# The find is deliberately UNFILTERED and uncapped: deciding what is a run happens in the
# loop above, by checking each file's declared branch against its location. Filtering here
# cannot work — a depth cap drops real runs on multi-segment branches, and a `! -path`
# exclusion matches the whole absolute path and so drops every run in any clone that merely
# lives under a directory of that name. See the branch-vs-path check above.
done <<< "$(printf '%s\n' "$scan_roots" | while IFS= read -r _root; do
  [ -n "$_root" ] && [ -d "$_root" ] && find "$_root" -name STATE.json 2>/dev/null
done)"

# --- Reduce the non-terminal sightings: one row per run, the FRESHEST one ---------
# `sort -t<tab> -k1,1 -k2,2nr` groups by the branch+base key and orders each group by
# `newest` descending, so the first line per key is the most recent sighting; `awk`
# then keeps exactly that one. This is what makes the in-flight/stalled split
# independent of `find` order, and it also supplies the dedup the tallies need (the
# `seen_live` set it replaces did both jobs, but decided freshness too early).
if [ -s "$live_raw" ]; then
  _US="$(printf '\037')"
  LC_ALL=C sort -t"$_US" -k1,1 -k2,2 -k3,3nr "$live_raw" 2>/dev/null \
    | awk -F'\037' '!seen[$1 FS $2]++' > "$live_best" 2>/dev/null || cp "$live_raw" "$live_best"
  # Guard against an empty reduce (a sort/awk failure) silently dropping every live
  # run: fall back to the raw sightings, which over-counts at worst but never hides.
  [ -s "$live_best" ] || cp "$live_raw" "$live_best" 2>/dev/null || true
  while IFS="$_US" read -r _br _ba _newest _lphase _lsum; do
    [ -n "${_br:-}" ] || continue
    case "${_newest:-}" in ''|*[!0-9]*) _newest=0 ;; esac
    if [ "$_newest" -ge "$cutoff" ] && [ "$_newest" -gt 0 ]; then
      in_flight=$((in_flight + 1))
    else
      stalled=$((stalled + 1))
      printf '  %s @ phase=%s — %s\n' "${_br:-?}" "${_lphase:-unknown}" "${_lsum:-}" >> "$stalled_list"
    fi
  done < "$live_best"
fi

done_count="$(wc -l < "$rows" | tr -d ' ')"
total=$((done_count + stalled + in_flight))

# --- Empty-ledger / no-runs guard (never divide by zero) ---------------------
if [ "$total" -eq 0 ]; then
  echo "auto-task run stats"
  echo "==================="
  # The skipped-row notice MUST be reachable here, not only in the normal report
  # below. The worst realistic case for a torn write is a clone whose ONLY completed
  # run had its row torn: total is then 0, and without this branch the reader would
  # answer "the ledger is empty — complete a run to populate it" about a ledger that
  # is not empty and about a run that did complete. That is precisely the silent data
  # loss this notice exists to prevent, in its most misleading form.
  if [ "$skipped_rows" -gt 0 ]; then
    printf '%d unparseable ledger row(s) skipped (likely a torn concurrent append) — see %s\n' \
      "$skipped_rows" "$ledger"
    echo "The ledger is NOT empty: it holds row(s) that could not be parsed, so the run(s) they"
    echo "represent are not counted below. Inspect the file to recover or remove them."
  fi
  # State what is known and no more. An UNPARSEABLE file is counted before its phase can
  # be read (see the scan loop), so "a completed run IS on disk" would be an over-claim —
  # the honest wording is that one of them MAY be one. And the files are NAMED: telling a
  # maintainer to "inspect the file(s) named by the skip count" is unfollowable advice,
  # since a count names nothing.
  if [ "$skipped_live" -gt 0 ]; then
    printf '%d live STATE.json file(s) skipped — unreadable, underivable, or not where their branch says\n' \
      "$skipped_live"
    echo "One of those may be a completed run, which would then not be counted above:"
    [ -s "$skipped_live_list" ] && sed 's/^/    /' "$skipped_live_list"
  fi
  # Two INDEPENDENT things have to be said here, and collapsing them into one if/elif
  # chain broke each in turn. (1) The OPT-IN STATE is worth reporting regardless of any
  # skip — an earlier revision let a non-zero skip count shadow it, hiding the only
  # actionable line in this path (`touch <canonical path>`) from a clone that had never
  # opted in. (2) The "nothing is here" sentence must never contradict a skip notice
  # printed above it: claiming "the ledger is empty and no live runs are on disk", or
  # telling the maintainer to go complete a run, is false when something WAS skipped.
  # So: report the opt-in state unconditionally, and emit the emptiness claim only when
  # nothing at all was skipped.
  if [ ! -f "$ledger" ]; then
    echo "The ledger does not exist, so completed runs are not being archived."
    echo "Opt in with:  touch \"$ledger\""
  fi
  if [ "$skipped_rows" -eq 0 ] && [ "$skipped_live" -eq 0 ]; then
    if [ -f "$ledger" ]; then
      echo "No runs recorded yet — the ledger is empty and no live runs are on disk."
    fi
    echo "Complete an /auto-task run to populate it."
  elif [ "$skipped_rows" -gt 0 ] && [ "$skipped_live" -eq 0 ]; then
    echo "No countable runs — every ledger row was unparseable."
  fi
  exit 0
fi

# --- Aggregate the done-row population in one jq pass -------------------------
# Rate metrics now carry a Wilson 95% score interval + sample size (a bare
# percentage over a handful of runs is not a trustworthy signal). Per-version
# groups feed the version-over-version regression guard, and pooled act/est ratios
# feed the (suggest-only) recalibration. All thresholds arrive from bash env.
agg="$(jq -s \
  --argjson mde_pp "$MDE_PP" \
  --argjson min_sample "$MIN_SAMPLE" \
  --argjson ratio_mde "$RATIO_MDE" \
  --argjson recal_min "$RECAL_MIN" \
  '
  # Same numeric discipline as DERIVE. These protect rows ALREADY in the append-only
  # ledger, which cannot be corrected retroactively, and they matter because `add`
  # and `/` are FATAL on a mixed type while a bare `> 0` does NOT exclude a string
  # (jq sorts strings after numbers). A fatal error here blanks the whole report.
  def n0: if type == "number" then . else 0 end;
  def isnum: type == "number";
  # A `> 0` predicate does NOT exclude a non-number: jq sorts strings/arrays/objects
  # AFTER numbers, so `"none" > 0`, `[] > 0` and `{} > 0` are all true. Counting sites
  # were therefore never safe either — a malformed legacy row was counted as a defect
  # and reported as a real rate. `pos` is the honest "is a positive number" test.
  def pos: (type == "number") and (. > 0);
  def median: (map(n0) | sort) as $s | if ($s|length)==0 then 0 else $s[(($s|length-1)/2)|floor] end;
  # Wilson 95% score interval → {lo,hi} as percentages, or null when n<=0.
  def wilson(k; n):
    if (n <= 0) then null
    else
      (k/n) as $p | 1.96 as $z | (1.96*1.96) as $z2
      | (($p + $z2/(2*n)) / (1 + $z2/n)) as $c
      | (($z * ((($p*(1-$p) + $z2/(4*n))/n) | sqrt)) / (1 + $z2/n)) as $m
      | { lo: (((([($c-$m), 0] | max) * 1000) | round) / 10),
          hi: (((([($c+$m), 1] | min) * 1000) | round) / 10) }
    end;
  # A binomial rate over the row set: {k,n,pct,ci}. pct/ci null when n==0.
  def rate(cond):
    (map(select(cond)) | length) as $k | length as $n
    | { k: $k, n: $n,
        pct: (if $n==0 then null else (($k*1000/$n)|round)/10 end),
        ci: wilson($k; $n) };
  def vrate(cond): if length==0 then 0 else ((map(select(cond))|length)*1000/length|round)/10 end;
  # --- Token-ratio row eligibility (the est/act comparison is OUTPUT-vs-OUTPUT) -
  # NOTE: no apostrophes anywhere in this jq program — it is single-quoted in
  # bash, so a lone apostrophe in a comment silently terminates the quote and
  # unbinds $agg (which is how this block first broke).
  #
  # `est_tokens` is the predicted OUTPUT tokens and `act_tokens_output` the
  # measured output. `act_tokens` (the cache_read-dominated grand total) is
  # deliberately NOT the numerator: comparing it against an output-scale estimate
  # is a unit error worth 66x-434x on the four runs that have actuals.
  #
  # The guard MUST test the same field the division uses. Testing `act_tokens`
  # while dividing `act_tokens_output` would admit a legacy row and then evaluate
  # `null / number`, which is a FATAL jq error — and per the --argjson note above,
  # an error in this agg pass blanks the whole report rather than printing a
  # wrong number.
  #
  # A pre-recalibration row carries an `est_tokens` on the old cache-inclusive
  # total scale, so pooling it would reintroduce that same unit error. `tok_ok`
  # rejects it (on the scale marker, not merely on positivity) and `tok_legacy`
  # counts it, so the exclusion is REPORTED rather than silent — a dropped row must
  # never look like "no measured runs yet".
  #
  # Legacy is detected in TWO ways, because one alone misses real rows:
  #   (a) `est_tokens_scale == "total"` — the explicit marker both row builders
  #       now emit. This is the ONLY thing that catches a live STATE.json whose
  #       `estimate` predates the change, or a run that STARTED before the
  #       upgrade and was archived after it. Key-absence cannot see either case,
  #       because both row builders always CONSTRUCT `act_tokens_output`.
  #   (b) `act_tokens_output` absent entirely — a row archived by the OLD builder,
  #       which never emitted the field. Such rows also predate the marker, so (a)
  #       is unavailable for them and only (b) works.
  # Neither clause fires for a post-change row whose estimate was simply
  # unestimable (`est_tokens_scale` null, `est_tokens` null): that is "not
  # measured", not "measured on the old scale", and conflating them would
  # mislabel it.
  #
  # Two guards make the classifier honest rather than merely wide:
  #   * the leading `tok_ok | not` makes legacy and ratio-eligible MUTUALLY
  #     EXCLUSIVE by construction. It resolves the overlap toward EXCLUSION only
  #     because `tok_ok` is itself scale-aware (above) — that ordering matters and
  #     was got wrong once: with a positivity-only `tok_ok`, this guard handed
  #     precedence to the numbers over the `scale=="total"` marker,
  #     so a foreign row was pooled into the ratio and the exclusion notice
  #     disappeared. The pair must be read together, not separately.
  #   * clause (a) additionally requires a measured output. An old-shape estimate
  #     whose `actuals` came back null was never comparable for a reason unrelated
  #     to the scale change (token-usage.sh legitimately returns null when the
  #     transcript window holds no attributable messages), so attributing it to the
  #     recalibration would over-count what the change cost. Clause (b) keeps
  #     `est_tokens > 0` as its equivalent guard.
  # `tok_ok` is scale-AWARE, and that is load-bearing: it is what the disjointness
  # guard in tok_legacy defers to. A row declaring est_tokens_scale=="total" says its
  # own estimate is on the ~100x cache-inclusive scale, so it must never enter the
  # ratio no matter how positive its numbers look. Without this clause, adding
  # `tok_ok | not` to tok_legacy gave positivity precedence over the numbers rather than
  # the scale marker: such a row was POOLED (dragging a 1.1x median to 0.21x) and the
  # exclusion notice vanished, which is strictly less information than reporting it.
  def tok_ok: (.est_tokens | isnum) and (.act_tokens_output | isnum)
              and ((.est_tokens) > 0) and ((.act_tokens_output) > 0)
              and (.est_tokens_scale? != "total");
  def tok_legacy: (tok_ok | not)
                  and ( ((.est_tokens_scale? == "total") and (.act_tokens_output | isnum) and ((.act_tokens_output) > 0))
                        or ((has("act_tokens_output") | not) and (.est_tokens | isnum) and ((.est_tokens) > 0)) );
  def tok_ratio: (.act_tokens_output / .est_tokens);
  length as $N
  | (map(select((.plugin_version | type) == "string" and .plugin_version != "" and .plugin_version != "unknown"))
     | group_by(.plugin_version)
     | map({ version: .[0].plugin_version, n: length,
             late:  vrate(.defects_late | pos),
             tests: vrate(.tests_added == true),
             flaky: vrate(.flaky == true),
             ratio_tokens: (map(select(tok_ok) | tok_ratio) | median),
             n_tok: (map(select(tok_ok)) | length) })
     | sort_by(.version | split(".") | map(tonumber? // 0))) as $versions
  | (map(select(tok_ok) | tok_ratio) | median) as $rtok
  | (map(select(tok_ok)) | length) as $ntok
  | (map(select(tok_legacy)) | length) as $nlegacy
  | (map(select((.est_duration_min | isnum) and (.act_duration_min | isnum)
              and ((.est_duration_min) > 0) and ((.act_duration_min) > 0))
       | (.act_duration_min/.est_duration_min)) | median) as $rdur
  | (map(select((.est_duration_min | isnum) and (.act_duration_min | isnum)
              and ((.est_duration_min) > 0) and ((.act_duration_min) > 0))) | length) as $ndur
  | ($versions | map(select(.n >= $min_sample))) as $elig
  | {
    quality: {
      # NUMBERS ONLY — `select(type=="number")`, not merely `// empty`. This field is
      # model-written and real state files carry strings ("6/6 self-verify ACs green")
      # and booleans as often as numbers; `add` on a mixed array is a FATAL jq error,
      # and per the --argjson note above an error here blanks the ENTIRE report rather
      # than one metric. Measured on a real 9-run clone: every quality rate printed
      # `n=0 (no data)`, the whole By-tier table printed empty, Gate-B coverage printed
      # `0/0` and follow-up debt `0` — wrong numbers presented as facts, in the section
      # the header of this very file calls THE headline. The DERIVE blocks now coerce at the
      # source too; this filter is what protects rows ALREADY written to an append-only
      # ledger, which cannot be corrected retroactively.
      first_pass: ((map(.first_pass_ac | select(type == "number"))) as $fp
        | { n: ($fp|length),
            mean_pct: (if ($fp|length)==0 then null else (($fp|add)/($fp|length)*1000|round)/10 end) }),
      late:  rate(.defects_late | pos),
      tests: rate(.tests_added == true),
      flaky: rate(.flaky == true),
      early_mean: (if $N==0 then null else ((map(.defects_early | n0)|add)/$N*100|round)/100 end)
    },
    tiers: (group_by(.tier) | map({
        tier: (.[0].tier // "?"),
        n: length,
        med_fix: (map(.fix_iterations // 0) | median),
        med_review: (map(.review_iterations // 0) | median),
        # NULL-EXCLUDING, unlike its two siblings above, and the difference is
        # deliberate. Two kinds of row carry null here: every pre-[v7] ledger row (the
        # ledger is append-only), AND any row -- ledger or live-derived -- whose
        # STATE.json predates `rounds[]`. That is why this selects by TYPE rather than
        # by schema_version: the version is strictly narrower than the null set. The
        # `// 0` idiom the siblings use would read each of those as "this run ran zero
        # review rounds" and drag the median toward 0 -- reporting a fabricated
        # improvement exactly when you are trying to measure one. Selecting numbers
        # first means the median is over the rows that actually carry the field; when
        # none do, `median` on an empty array yields 0 and `n_rounds` is 0, which is
        # how a reader tells "no data" from "a real 0".
        med_rounds: (map(.review_rounds | select(type == "number")) | median),
        n_rounds: (map(.review_rounds | select(type == "number")) | length),
        # Independent-round median, carrying the SAME null-exclusion idiom as the two
        # lines above rather than a `// 0`. The exposure here is larger, not smaller:
        # every row written before this field existed carries no value at all, so
        # coalescing would report "0 independent rounds" for the entire history and
        # manufacture exactly the regression a reader would be looking for. `n_indep`
        # is what separates "no data" from a real 0, and the renderer prints "-" when
        # it is 0 for that reason.
        med_indep: (map(.review_rounds_independent | select(type == "number")) | median),
        n_indep: (map(.review_rounds_independent | select(type == "number")) | length),
        # THE TWO MEDIANS RUN OVER DIFFERENT ROW POPULATIONS, and the renderer must say so.
        # `med_rounds` is taken over rows carrying `review_rounds`; `med_indep` over the
        # (usually smaller) set carrying `review_rounds_independent`, because every row
        # written before that field existed lacks it. Nulls are excluded rather than
        # coalesced -- correct, and the reason the two denominators diverge.
        #
        # Left unsaid, that produces an arithmetically IMPOSSIBLE reading: independent
        # rounds are a subset of rounds, so `indep > med rounds` cannot happen for any
        # single run, yet it happens routinely across a mixed ledger (three legacy rows at
        # rounds=1 and three new rows at rounds=6/indep=6 give med_rounds=1, med_indep=6).
        # A reader comparing the columns then sees a self-contradiction presented as fact --
        # the "blank table into a WRONG table presented as right" failure this file already
        # warns about a few lines below. So the renderer prints the sample size whenever the
        # populations differ, and this flag is what tells it to.
        indep_pop_differs: ((map(.review_rounds_independent | select(type == "number")) | length)
                            != (map(.review_rounds | select(type == "number")) | length)),
        pct_escalated: (if length==0 then 0 else ((map(select(.escalations | pos)) | length) * 100 / length | floor) end)
      })),
    sh_total: (map(select(.tier=="standard" or .tier=="heavy")) | length),
    sh_ran: (map(select((.tier=="standard" or .tier=="heavy") and (.gate_b=="passed"))) | length),
    pct_misscored: (if length==0 then 0 else ((map(select(.escalations | pos)) | length) * 100 / length | floor) end),
    avg_followups: (if length==0 then 0 else ((map(.followups | n0) | add) / length) end),
    ratio_tokens: $rtok, n_tok: $ntok, n_tok_legacy: $nlegacy,
    ratio_dur: $rdur, n_dur: $ndur,
    versions: $versions,
    regression: (
      if ($elig|length) < 2
      then { status: "insufficient", eligible: ($elig|length), total_versions: ($versions|length), min_sample: $min_sample }
      else ($elig[-2]) as $a | ($elig[-1]) as $b
        | { status: "ok", from: $a.version, to: $b.version, from_n: $a.n, to_n: $b.n,
            flags: (
              ([ { metric: "late-defect rate", from: $a.late,  to: $b.late,  delta: (((($b.late-$a.late)*10)|round)/10),   unit: "pp" },
                 { metric: "tests-added rate", from: $a.tests, to: $b.tests, delta: (((($b.tests-$a.tests)*10)|round)/10), unit: "pp" },
                 { metric: "flakiness rate",   from: $a.flaky, to: $b.flaky, delta: (((($b.flaky-$a.flaky)*10)|round)/10), unit: "pp" } ]
               | map(select((.delta|fabs) >= $mde_pp)))
              + (if ($a.n_tok > 0 and $b.n_tok > 0 and ((($b.ratio_tokens-$a.ratio_tokens))|fabs) >= $ratio_mde)
                 then [ { metric: "est/act token ratio", from: (($a.ratio_tokens*100|round)/100), to: (($b.ratio_tokens*100|round)/100), delta: (((($b.ratio_tokens-$a.ratio_tokens))*100|round)/100), unit: "x" } ]
                 else [] end)
            ) }
      end),
    recal: (
      if $ntok >= $recal_min
      then { suggest: true,  ratio_tokens: (($rtok*100|round)/100), n_tok: $ntok, ratio_dur: (($rdur*100|round)/100), n_dur: $ndur }
      else { suggest: false, n_tok: $ntok, need: $recal_min } end)
  }' "$rows" 2>/dev/null || echo '{}')"

terminal=$((done_count + stalled))
if [ "$terminal" -gt 0 ]; then
  comp_pct=$(( done_count * 100 / terminal ))
else
  comp_pct=0
fi

# Format a rate object {pct,ci,n} as "P% [lo–hi] (n=N)"; "n=0 (no data)" when empty.
fmt_rate(){ # $1 = jq path into $agg, e.g. .quality.late
  local obj n pct lo hi
  obj="$(printf '%s' "$agg" | jq -c "$1" 2>/dev/null || echo '{}')"
  n="$(printf '%s' "$obj" | jq -r '.n // 0' 2>/dev/null || echo 0)"
  pct="$(printf '%s' "$obj" | jq -r 'if .pct == null then "null" else (.pct|tostring) end' 2>/dev/null || echo null)"
  if [ "$n" = "0" ] || [ "$pct" = "null" ]; then printf 'n=0 (no data)'; return; fi
  lo="$(printf '%s' "$obj" | jq -r '.ci.lo // empty' 2>/dev/null || echo "")"
  hi="$(printf '%s' "$obj" | jq -r '.ci.hi // empty' 2>/dev/null || echo "")"
  if [ -n "$lo" ] && [ -n "$hi" ]; then printf '%s%% [%s–%s] (n=%s)' "$pct" "$lo" "$hi" "$n"
  else printf '%s%% (n=%s)' "$pct" "$n"; fi
}

echo "auto-task run stats  (stale threshold: ${STALE_DAYS}d)"
echo "===================================================="
printf '%d runs on record — %d done, %d stalled, %d in-flight\n' "$total" "$done_count" "$stalled" "$in_flight"
# Surface unparseable ledger lines rather than dropping them silently. Only a torn
# concurrent append can produce one, meaning a real completed run's row — so a
# silent skip would be invisible data loss in the one tool whose job is an honest
# run history. Same principle as the pre-recalibration exclusion note below.
if [ "$skipped_rows" -gt 0 ]; then
  printf '%d unparseable ledger row(s) skipped (likely a torn concurrent append) — see %s\n' \
    "$skipped_rows" "$ledger"
fi
if [ "$skipped_live" -gt 0 ]; then
  printf '%d live STATE.json file(s) skipped — unreadable, underivable, or not where their branch says\n' \
    "$skipped_live"
  # Name them. "Inspect the file(s) named by the skip count" was unfollowable advice —
  # a count names nothing, unlike the ledger notice which prints its path.
  [ -s "$skipped_live_list" ] && sed 's/^/  /' "$skipped_live_list"
fi
echo ""

# --- Quality (test-verified — THE headline) ---------------------------------
# What matters is whether runs produced test-verified, defect-free work — NOT
# whether they reached Handover. Completion is a liveness signal (further down),
# not a quality signal: an agent can reach "done" with a confidently-wrong result.
fp_n="$(printf '%s' "$agg" | jq -r '.quality.first_pass.n // 0' 2>/dev/null || echo 0)"
fp_mean="$(printf '%s' "$agg" | jq -r 'if (.quality.first_pass.mean_pct // null) == null then "n/a" else (.quality.first_pass.mean_pct|tostring) end' 2>/dev/null || echo n/a)"
early_mean="$(printf '%s' "$agg" | jq -r 'if (.quality.early_mean // null) == null then "n/a" else (.quality.early_mean|tostring) end' 2>/dev/null || echo n/a)"
echo "Quality (test-verified — the headline)"
if [ "$fp_n" = "0" ] || [ "$fp_mean" = "n/a" ]; then
  printf '  First-pass AC pass     n/a (no measured runs)\n'
else
  printf '  First-pass AC pass     %s%% mean (n=%s)\n' "$fp_mean" "$fp_n"
fi
printf '  Late-defect rate       %s   (Gate-B / code-review — lower is better)\n' "$(fmt_rate '.quality.late')"
printf '  Early-defect capture   %s avg per run (Gate-A / self-verify)\n' "$early_mean"
printf '  Tests-added rate       %s\n' "$(fmt_rate '.quality.tests')"
printf '  Flakiness rate         %s\n' "$(fmt_rate '.quality.flaky')"
echo ""

# --- Merge acceptance: the REAL success signal ------------------------------
# A completed run only OPENS a PR; whether it MERGED is decided later, off-machine.
# The PR-opened count is derived locally from the done rows; merge state is
# resolved best-effort via `gh` HERE in the reader (never in the no-network
# record-outcome hook). AUTO_TASK_PR_RESOLVE=0 disables the lookup (tests, offline);
# it also short-circuits when gh is absent/unauthenticated, so the local
# "opened a PR" count always prints even when the merge rate cannot.
pr_urls="$(jq -r '.pr_url // empty' "$rows" 2>/dev/null | sed '/^null$/d;/^$/d')"
pr_total=0; [ -n "$pr_urls" ] && pr_total="$(printf '%s\n' "$pr_urls" | wc -l | tr -d ' ')"
resolve="${AUTO_TASK_PR_RESOLVE:-1}"
echo "Merge acceptance"
if [ "$pr_total" -eq 0 ]; then
  echo "  No completed run has opened a PR yet."
elif [ "$resolve" = "1" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  merged=0; closed=0; opened=0; unresolved=0
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    st="$(gh pr view "$url" --json state --jq '.state' 2>/dev/null || echo "")"
    case "$st" in
      MERGED) merged=$((merged+1)) ;;
      CLOSED) closed=$((closed+1)) ;;
      OPEN)   opened=$((opened+1)) ;;
      *)      unresolved=$((unresolved+1)) ;;
    esac
  done <<< "$pr_urls"
  decided=$((merged + closed))
  printf '  %d of %d completed runs opened a PR\n' "$pr_total" "$done_count"
  printf '  Merged %d · closed-unmerged %d · still open %d · unresolved %d\n' "$merged" "$closed" "$opened" "$unresolved"
  if [ "$decided" -gt 0 ]; then
    printf '  Merge-acceptance rate  %d%%  (%d/%d decided PRs merged)\n' "$(( merged * 100 / decided ))" "$merged" "$decided"
  else
    printf '  Merge-acceptance rate  n/a  (no opened PR has merged or closed yet)\n'
  fi
else
  printf '  %d of %d completed runs opened a PR\n' "$pr_total" "$done_count"
  if [ "$resolve" = "1" ]; then
    echo "  (merge state unresolved — gh CLI unavailable or unauthenticated; run from an authenticated gh to populate the acceptance rate)"
  else
    echo "  (merge-state resolution disabled via AUTO_TASK_PR_RESOLVE=0)"
  fi
fi
echo ""

# --- Liveness / operational (NOT a quality signal) --------------------------
# Completion = "reached Handover", which is construct-invalid as a quality metric:
# it looks healthy exactly when a confidently-wrong run should not be trusted. It
# lives here as an operational/liveness signal, paired with WHERE runs stall.
if [ "$terminal" -gt 0 ]; then
  comp_ci="$(printf '%s' "$agg" | jq -rn --argjson k "$done_count" --argjson n "$terminal" '
    def wilson(k;n): if n<=0 then null else (k/n) as $p | (1.96*1.96) as $z2
      | (($p+$z2/(2*n))/(1+$z2/n)) as $c
      | ((1.96*((($p*(1-$p)+$z2/(4*n))/n)|sqrt))/(1+$z2/n)) as $m
      | "[\((([($c-$m),0]|max)*1000|round)/10)–\((([($c+$m),1]|min)*1000|round)/10)]" end;
    wilson($k;$n) // ""' 2>/dev/null || echo "")"
else
  comp_ci=""
fi
echo "Liveness / operational (NOT a quality signal)"
printf '  Completion rate        %d%% %s (%d/%d terminal; in-flight excluded)\n' "$comp_pct" "$comp_ci" "$done_count" "$terminal"
echo "  Where stalled runs died"
if [ "$stalled" -eq 0 ]; then
  echo "    (none)"
else
  sed 's/^  /    /' "$stalled_list"
fi
echo ""

echo "By tier"
printf '  %-10s %5s %11s %14s %14s %12s %11s\n' "tier" "#done" "med fix" "med review" "med rounds" "indep" "escalated"
# Columns are \037-delimited and read with IFS=\037, NOT whitespace-split. A tier value
# containing a space — a `tostring`ed array like ["a b"], or simply a string tier with a
# space — otherwise spills into the #done column and shifts every later one, turning a
# blank table into a WRONG table presented as right. \037 is not whitespace, so the field
# boundaries survive whatever the value contains.
printf '%s' "$agg" | jq -r '.tiers[]? | "\(.tier | if type == "string" then .[0:10] else (tostring | .[0:10]) end)\(.n)\(.med_fix)\(.med_review)\(if .n_rounds > 0 then (.med_rounds|tostring) else "-" end)\(if .n_indep > 0 then ((.med_indep|tostring) + (if .indep_pop_differs then (" (n=" + (.n_indep|tostring) + ")") else "" end)) else "-" end)\(.pct_escalated)"' 2>/dev/null \
  | while IFS="$(printf '\037')" read -r t n mf mr mrd mi pe; do printf '  %-10s %5s %11s %14s %14s %12s %10s%%\n' "$t" "$n" "$mf" "$mr" "$mrd" "$mi" "$pe"; done
[ "$done_count" -eq 0 ] && echo "  (no completed runs yet)"
echo ""

sh_total="$(printf '%s' "$agg" | jq -r '.sh_total // 0' 2>/dev/null || echo 0)"
sh_ran="$(printf '%s' "$agg" | jq -r '.sh_ran // 0' 2>/dev/null || echo 0)"
sh_skipped=$(( sh_total - sh_ran ))
[ "$sh_skipped" -lt 0 ] && sh_skipped=0
pct_misscored="$(printf '%s' "$agg" | jq -r '.pct_misscored // 0' 2>/dev/null || echo 0)"
avg_followups="$(printf '%s' "$agg" | jq -r '(.avg_followups // 0) | (.*10|round)/10' 2>/dev/null || echo 0)"

printf 'Gate B coverage        ran on %s/%s standard+heavy runs (%s skipped)\n' "$sh_ran" "$sh_total" "$sh_skipped"
printf 'Effort mis-scoring     %s%% of completed runs escalated tier mid-run\n' "$pct_misscored"
printf 'Follow-up debt         %s parked follow-ups per completed run (avg)\n' "$avg_followups"
echo ""

# --- Estimate accuracy (calibration input) -----------------------------------
rt="$(printf '%s' "$agg" | jq -r '(.ratio_tokens // 0) | (.*100|round)/100' 2>/dev/null || echo 0)"
rd="$(printf '%s' "$agg" | jq -r '(.ratio_dur // 0) | (.*100|round)/100' 2>/dev/null || echo 0)"
n_tok="$(printf '%s' "$agg" | jq -r '.n_tok // 0' 2>/dev/null || echo 0)"
n_dur="$(printf '%s' "$agg" | jq -r '.n_dur // 0' 2>/dev/null || echo 0)"
n_tok_legacy="$(printf '%s' "$agg" | jq -r '.n_tok_legacy // 0' 2>/dev/null || echo 0)"
case "$n_tok_legacy" in ''|*[!0-9]*) n_tok_legacy=0 ;; esac

echo "Estimate accuracy (calibration input)"
if [ "$n_tok" -gt 0 ]; then
  printf '  output tokens: actual/est median %sx (n=%s)\n' "$rt" "$n_tok"
else
  printf '  output tokens: no measured runs yet\n'
fi
if [ "$n_dur" -gt 0 ]; then
  printf '  time:          actual/est median %sx (n=%s)\n' "$rd" "$n_dur"
fi
# Report legacy exclusions rather than dropping them silently — without this line
# a ledger full of pre-recalibration rows renders as "no measured runs yet",
# which reads as "never measured" instead of "measured on the old scale".
if [ "$n_tok_legacy" -gt 0 ]; then
  printf '  %s pre-recalibration row(s) excluded from the token ratio — their estimate was on the old\n' "$n_tok_legacy"
  printf '    cache-inclusive total scale, which is not comparable to the output-token estimate.\n'
fi
printf '  (the token ratio is OUTPUT-vs-OUTPUT: estimate.sh predicts output tokens, and the measured\n'
printf '   grand total is cache_read-dominated, so comparing against it would be a unit error.\n'
printf '   median actual/est >1 means runs cost MORE than estimated; <1 means less. Pooled — read with the n.)\n'
echo ""

# --- Regression guard (version-over-version) ---------------------------------
# Compares the two most-recent plugin versions that each clear the sample floor,
# flagging a metric only when its delta exceeds the MDE. Small local ledgers will
# usually report "insufficient data" — that is the honest state, not a failure
# (required N scales with 1/effect^2, so only large shifts are ever detectable).
echo "Regression guard (version-over-version)"
reg_status="$(printf '%s' "$agg" | jq -r '.regression.status // "insufficient"' 2>/dev/null || echo insufficient)"
if [ "$reg_status" = "ok" ]; then
  reg_from="$(printf '%s' "$agg" | jq -r '.regression.from' 2>/dev/null)"
  reg_to="$(printf '%s' "$agg" | jq -r '.regression.to' 2>/dev/null)"
  reg_fn="$(printf '%s' "$agg" | jq -r '.regression.from_n' 2>/dev/null)"
  reg_tn="$(printf '%s' "$agg" | jq -r '.regression.to_n' 2>/dev/null)"
  nflags="$(printf '%s' "$agg" | jq -r '.regression.flags | length' 2>/dev/null || echo 0)"
  printf '  comparing v%s (n=%s) → v%s (n=%s), MDE %spp / %sx\n' "$reg_from" "$reg_fn" "$reg_to" "$reg_tn" "$MDE_PP" "$RATIO_MDE"
  if [ "$nflags" = "0" ]; then
    echo "  ✓ no metric moved beyond the MDE — no regression flagged"
  else
    printf '%s' "$agg" | jq -r '.regression.flags[] | "  ⚠ \(.metric): \(.from)\(if .unit=="pp" then "%" else "x" end) → \(.to)\(if .unit=="pp" then "%" else "x" end)  (Δ\(.delta)\(.unit))"' 2>/dev/null
  fi
else
  reg_elig="$(printf '%s' "$agg" | jq -r '.regression.eligible // 0' 2>/dev/null || echo 0)"
  reg_totv="$(printf '%s' "$agg" | jq -r '.regression.total_versions // 0' 2>/dev/null || echo 0)"
  printf '  insufficient data — need ≥2 plugin versions with ≥%s runs each (have %s eligible of %s version(s) on record)\n' "$MIN_SAMPLE" "$reg_elig" "$reg_totv"
fi
echo ""

# --- Recalibration suggestion (--recalibrate only; suggest-only, never edits) -
if [ "$RECAL" = "1" ]; then
  echo "Recalibration suggestion (estimate.sh — apply by hand; nothing is auto-edited)"
  recal_ok="$(printf '%s' "$agg" | jq -r '.recal.suggest // false' 2>/dev/null || echo false)"
  if [ "$recal_ok" = "true" ]; then
    rc_rt="$(printf '%s' "$agg" | jq -r '.recal.ratio_tokens' 2>/dev/null)"
    rc_nt="$(printf '%s' "$agg" | jq -r '.recal.n_tok' 2>/dev/null)"
    rc_rd="$(printf '%s' "$agg" | jq -r '.recal.ratio_dur' 2>/dev/null)"
    rc_nd="$(printf '%s' "$agg" | jq -r '.recal.n_dur' 2>/dev/null)"
    printf '  Pooled actual/est: output tokens %sx (n=%s), time %sx (n=%s) — floor of %s met.\n' "$rc_rt" "$rc_nt" "$rc_rd" "$rc_nd" "$RECAL_MIN"
    # Suggest scaling estimate.sh's CURRENT constants by the pooled ratio. The
    # values are read live (est_const) — never hardcoded here, or they go stale on
    # the first recalibration and this block starts lying.
    tbt_l="$(est_const TIER_BASE_TOK_light)";  tbt_s="$(est_const TIER_BASE_TOK_standard)"
    tbt_h="$(est_const TIER_BASE_TOK_heavy)";  pat="$(est_const PER_AC_TOK)"
    pft="$(est_const PER_FILE_TOK)"
    tbm_l="$(est_const TIER_BASE_MIN_light)";  tbm_s="$(est_const TIER_BASE_MIN_standard)"
    tbm_h="$(est_const TIER_BASE_MIN_heavy)";  pam="$(est_const PER_AC_MIN)"
    pfm="$(est_const PER_FILE_MIN)"
    if [ -n "$tbt_l" ] && [ -n "$tbt_s" ] && [ -n "$tbt_h" ] && [ -n "$pat" ] && [ -n "$pft" ] \
       && [ -n "$tbm_l" ] && [ -n "$tbm_s" ] && [ -n "$tbm_h" ] && [ -n "$pam" ] && [ -n "$pfm" ]; then
      printf '%s' "$agg" | jq -rn --argjson rt "$rc_rt" \
        --argjson l "$tbt_l" --argjson s "$tbt_s" --argjson h "$tbt_h" \
        --argjson a "$pat" --argjson f "$pft" '
        def sc(v): (v*$rt)|round;
        "  Suggested TOKEN constants (× \($rt)) — output tokens:",
        "    TIER_BASE_TOK  light \($l)→\(sc($l))  standard \($s)→\(sc($s))  heavy \($h)→\(sc($h))",
        "    PER_AC_TOK \($a)→\(sc($a))   PER_FILE_TOK \($f)→\(sc($f))"' 2>/dev/null
      # The TIME suggestion needs its OWN sample guard. `$RECAL_MIN` is checked
      # against n_tok, and `median` of an empty array returns 0 (not null), so a
      # ledger whose durations are all null yields ratio_dur 0 and this block would
      # advise multiplying every wall-clock constant by ZERO — from a sample of
      # none. Durations are null far more often than tokens now that an implausible
      # span (negative, or over 12h — a run paused overnight) is deliberately
      # rejected rather than recorded, so the two sample counts genuinely diverge
      # and the token guard cannot stand in for this one. The report body already
      # guards its time line on n_dur; the actionable-constants path must too.
      if [ "${rc_nd:-0}" -gt 0 ] 2>/dev/null; then
        printf '%s' "$agg" | jq -rn --argjson rd "$rc_rd" \
          --argjson l "$tbm_l" --argjson s "$tbm_s" --argjson h "$tbm_h" \
          --argjson a "$pam" --argjson f "$pfm" '
          def sc(v): (v*$rd)|round;
          "  Suggested TIME constants (× \($rd)):",
          "    TIER_BASE_MIN  light \($l)→\(sc($l))  standard \($s)→\(sc($s))  heavy \($h)→\(sc($h))",
          "    PER_AC_MIN \($a)→\(sc($a))   PER_FILE_MIN \($f)→\(sc($f))"' 2>/dev/null
      else
        printf '  No TIME constants suggested — no run in the sample has a measured duration.\n'
      fi
    else
      # Fail-open WITHOUT reinstating literals: a hardcoded fallback is precisely
      # the staleness this block was rewritten to eliminate, so print the factors
      # and say the constants could not be read.
      printf '  Could not read the current constants from estimate.sh (%s) — no values suggested.\n' \
        "${EST_SH:-not found}"
      printf '  Apply by hand: multiply the TIER_BASE_TOK_*/PER_*_TOK constants by %sx (n=%s).\n' "$rc_rt" "$rc_nt"
      # Same sample guard as the values branch above — this fail-open path emits the
      # very same ×0 advice when no run in the sample has a measured duration, and it
      # printed no `n`, so nothing on screen revealed the factor came from zero runs.
      if [ "${rc_nd:-0}" -gt 0 ] 2>/dev/null; then
        printf '  Multiply the TIER_BASE_MIN_*/PER_*_MIN constants by %sx (n=%s).\n' "$rc_rd" "$rc_nd"
      else
        printf '  Do NOT scale the TIER_BASE_MIN_*/PER_*_MIN constants — no run in the sample has a measured duration.\n'
      fi
    fi
    echo "  (Suggestion only — estimate.sh is unchanged. Review the n before applying; a small n is noisy.)"
  else
    rc_nt="$(printf '%s' "$agg" | jq -r '.recal.n_tok // 0' 2>/dev/null || echo 0)"
    printf '  Not enough measured runs to suggest a calibration — have %s, need ≥%s.\n' "$rc_nt" "$RECAL_MIN"
  fi
  echo ""
fi

exit 0
