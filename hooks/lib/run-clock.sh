#!/usr/bin/env bash
# run-clock.sh — SHARED, SOURCED helper: the run's MEASURED wall-clock.
#
# WHY THIS FILE EXISTS. A run's duration used to be *narrated*: it was derived
# from the first and last `state.history[].at` strings, and those strings are
# written by the model, which has no clock. The numbers were therefore whatever
# the model believed the time to be — frequently the same timestamp repeated, or
# the session date. This file replaces that with a real measurement: a hook
# (`hooks/stamp-run-clock.sh`) stamps `date -u` into a sidecar clock file, and
# every consumer derives the duration from those two stamps instead.
#
# Three consumers read it — `record-outcome.sh` (local ledger row),
# `send-telemetry.sh` (remote payload) and `auto-task-stats.sh` (aggregator
# DERIVE). Hardcoding the derivation and the sanity bounds in all three would put
# the same rule in three unsynchronized places, and two of them are already under
# an asserted VERBATIM lockstep. So the executable definition lives here, once,
# exactly like `hooks/lib/loop-budget.sh` does for the fix-loop cap.
#
# THE CLOCK FILE: .auto-task/<branch>/.run-clock.json, a hook-owned sidecar.
#   { "created_at": "<ISO-8601 Z>", "updated_at": "<ISO-8601 Z>",
#     "base": "<state.base — which RUN this clock describes>", "sealed": <bool> }
#
# `base` is what makes the clock run-scoped rather than branch-scoped. A branch
# folder outlives the run that created it, so without it a second run in the same
# folder would find a sealed clock and report the FIRST run's duration verbatim —
# and since that is a plausible number rather than a rejection, nothing
# downstream could detect it. The other two run-scoped sidecars key on `base` for
# exactly this reason (`record-outcome.sh`'s `.outcome-recorded`,
# `prevent-mid-protocol-stall.sh`'s base-in-signature).
# It is a SIDECAR, not a STATE.json field, and that is deliberate on two counts.
# (1) It matches the established convention — no hook in this plugin writes
# STATE.json; `prevent-mid-protocol-stall.sh`, `record-outcome.sh` and
# `send-telemetry.sh` all read it and write their own sidecars. (2) The model
# rewrites STATE.json many times per run; a full rewrite would drop `created_at`,
# the next stamp would re-seed it as "now", and the duration would silently
# collapse to ~0 — reintroducing the exact bug this file exists to fix.
#
# SEALING. The first stamp that observes `phase == "done"` writes one final
# `updated_at` and sets `sealed: true`; every later stamp is a no-op. Without it,
# any ad-hoc command run in the worktree days later would keep advancing
# `updated_at` and eventually trip the 12h bound, turning an already-recorded,
# perfectly good measurement into a rejection. Sealing at first-`done` lines up
# with when the row is actually written: `record-outcome.sh` is sentinel-guarded
# write-once per run and fires at that same first `done` turn-end.
#
# A run that is ALREADY `done` when the clock first sees it gets NO clock at all.
# Seeding one would write `created_at == updated_at` and seal instantly, reporting
# a fabricated `0` — and `0` is a legitimate duration, so the sanity assertion
# below cannot catch it. That is the state of every run completed before this
# feature existed, so the honest answer is `absent`: the clock never observed the
# run, and the caller falls back to its history formula.
#
# READERS STAMP BEFORE THEY READ. `record-outcome.sh` and `send-telemetry.sh` call
# `rc_stamp` themselves immediately before reading, rather than relying on the
# `Stop` stamper having run first. Hooks for one event are executed in PARALLEL,
# so registration order is not an execution-order contract — a reader that only
# read would race the stamper's write and record a row that undercounts by the
# whole final (and typically longest) turn, which its write-once sentinel would
# then make permanent. `rc_stamp` is idempotent and seals, so self-stamping is
# both safe and sufficient.
#
# PURE HELPER — with one deliberate exception. Every function writes to stdout
# and returns; none `exit` and none decide a fail policy, so a caller keeps its
# own (the stamping hook fails open and silent; the row builders must not emit
# anything on stdout at all). The exception is `rc_stamp`, which by its nature
# mutates the clock file — it is the writer. Readers never mutate.
#
# Contract: source this file, then call:
#   rc_clock_path <state_path>            -> the clock that describes that run
#   rc_stamp <clock_path> [state_path]    -> create / refresh / seal (the writer)
#   rc_duration_min <clock> [state]       -> the THREE-STATE verdict (see below)
#   rc_verdict_state <verdict>            -> ok | rejected | absent
#   rc_verdict_value <verdict>            -> the minutes, or the string `null`
#
# THE THREE-STATE VERDICT — the reason this is not simply "a number or null".
# jq's `//` operator treats `null` identically to absent. The row builders'
# fallback is `(.actuals.duration_min // $dur)`, so a duration *deliberately
# rejected* to `null` would fall straight through to the history-derived number —
# fabricating precisely the value the assertion exists to forbid. A two-state
# design is therefore unimplementable, and callers MUST branch on the state
# rather than on nullness:
#
#   ok <n>    clock present, both stamps parse, 0 <= n <= 720
#             -> duration is <n>; the clock wins over the history formula
#   rejected  clock present but the duration is negative or exceeds 12h
#             -> duration is null, and MUST NOT fall back to the history value
#   absent    no clock file, unparseable, a missing stamp, or no jq
#             -> the caller uses its pre-existing history-derived formula
#
# A rejection is explained rather than silent: `rc_duration_min` prints the verdict
# on stdout and a one-line reason on STDERR naming the bound and both stamps. Note
# who actually sees it — all three hook consumers redirect that stderr to
# /dev/null, and must, because a hook may not emit. The reason is therefore for the
# Phase-5 orchestrator (which calls the helper directly and records it in the
# `handover-metrics` history entry) and for anyone debugging the helper by hand.
#
# Failure policy: every path is fail-open and returns 0. An unmeasurable clock
# reports `absent` (so the caller keeps its old behavior) and a rejected one
# reports `rejected` — the two are distinguishable by design, the same reason
# `token-usage.sh` reports `null` rather than `0` for a failed measurement.

# The sanity bound, in minutes. 12h. A run's wall-clock legitimately exceeds this
# whenever it is paused overnight (forwarded clarifying questions, an
# awaiting-external handoff, a next-day resume), and such a span is not a
# meaningful "how long did this take" figure — so it is rejected to null rather
# than recorded as a number. This is a deliberate accuracy-over-coverage trade:
# multi-day runs report no duration at all.
RC_MAX_DURATION_MIN=720

# The phase at which a clock may legitimately be STARTED. A clock can only measure a
# run it observed FROM THE START: seeding `created_at = now` for a run that began
# earlier reports the time since the clock happened to appear, not the run's
# duration — as a plausible small number (`ok 0` in the reproducer), so the sanity
# bound cannot catch it, and because the verdict is `ok` it OVERRIDES both fallbacks.
#
# The signal is `state.phase`, which is STRUCTURAL: branch setup creates STATE.json
# at `define`, so "a clock first appearing while the run is still in `define`" is
# exactly "the clock observed the start". Any later phase with no clock means the
# clock missed it.
#
# It deliberately does NOT gate on `state.history[].at`. An earlier version did, and
# that made the feature depend on the very data it exists to replace: when the model
# narrates the first timestamp as the session date or repeats one — the two failure
# modes this file's header names — the gap check refuses to ever start a clock, so no
# clock is created, every consumer silently falls back to the narrated history, and
# nothing surfaces. Green tests could not distinguish "working" from "never runs".
RC_SEED_PHASE="define"

# rc_clock_path <state_path>
#   Prints the clock that describes the run owning <state_path> — i.e. the sibling
#   `.run-clock.json` in the same .auto-task/<branch>/ folder.
#
#   Deriving it from the STATE.json path rather than from (project_dir, branch) is
#   deliberate: `send-telemetry.sh` accepts an `AUTO_TASK_STATE_FILE` override and
#   in that mode never resolves a project dir or branch at all, so a
#   project+branch signature would be unusable there — and silently reporting
#   `absent` for an overridden state is exactly the kind of gap a test would miss.
#   "The clock lives beside the state it describes" holds in every mode.
rc_clock_path() {
  local state="${1:-}"
  [ -n "$state" ] || return 0
  printf '%s/.run-clock.json\n' "$(dirname "$state")"
}

# rc_stamp <clock_path> [state_path]
#   THE WRITER. Seeds `created_at` on first sight, always refreshes `updated_at`,
#   and seals when <state_path> reports phase=="done". Never rewrites an existing
#   `created_at` — that immutability is what makes the measurement trustworthy.
#   Silent and fail-open: a missing jq, an unparseable clock, a missing directory
#   or a failed write all leave the tree untouched and return 0.
rc_stamp() {
  local clock="${1:-}" state="${2:-}"
  [ -n "$clock" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  [ -n "$now" ] || return 0

  # Read the two facts we need from the run's state ONCE: which run this is
  # (`base`) and whether it is over (`phase`).
  #
  # AN UNREADABLE STATE IS NOT AN IN-FLIGHT RUN. Without the validity gate below, a
  # truncated or half-written STATE.json yields `phase == ""`, which is not "done",
  # so the already-done guard further down would NOT fire and a brand-new clock
  # would be seeded — then adopted and sealed once the state is readable again,
  # reporting a fabricated `0`. That is exactly the bug the guard exists to prevent,
  # reached through a read the code never checked succeeded. Both sibling
  # STATE-reading hooks gate on validity the same way (`record-outcome.sh`,
  # `send-telemetry.sh`); refuse to act rather than guess.
  #
  # NOTE this gate is deliberately redundant with the unreadable-phase refusal below,
  # which is the behavioral backstop (swapping this for `jq empty` changes no observable
  # behavior, because an empty file then reads no `phase` and the refusal catches it).
  # It is kept because it exits BEFORE two jq reads and mirrors the hook's own gate,
  # where it is the only one.
  #
  # The check is `type == "object"`, NOT `jq empty`: an EMPTY file is valid input to
  # `jq empty` (zero values parse fine, exit 0), and a zero-byte STATE.json is the
  # single most likely half-written shape — a `Write` interrupted, or read while
  # being replaced. `jq empty` would wave it straight through into the "phase is not
  # done, so seed a clock" path this gate exists to block.
  local st_base="" st_phase="" st_ok="" state_given=0
  if [ -n "$state" ]; then
    state_given=1
    [ -f "$state" ] || return 0
    # ONE jq call for the validity check and both fields — this runs on every Bash
    # tool call for the life of a run, so per-field invocations are real cost. A
    # non-object yields no output, which is the refusal.
    st_ok="$(jq -r 'if type == "object" then "ok" else empty end' "$state" 2>/dev/null || echo "")"
    [ "$st_ok" = "ok" ] || return 0
    # Split on US (\037), NOT a tab. Tab is IFS-*whitespace*, so `read` collapses
    # runs of it and drops leading/trailing fields — an empty `base` would shift
    # `phase` into `st_base`. A non-whitespace separator preserves empty fields,
    # which is the whole point here since either field is legitimately empty.
    IFS=$'\037' read -r st_base st_phase <<STEOF
$(jq -r '[(.base // ""), (.phase // "")] | join("\u001f")' "$state" 2>/dev/null || printf '\037')
STEOF
  fi

  local created="" sealed="no" clk_base="" clock_existed=0
  if [ -f "$clock" ]; then
    clock_existed=1
    # `jq empty` accepts ANY valid JSON, including `[]` or `5`, on which every
    # `.field` read below yields empty and the clock would be silently rebuilt
    # with `created_at = now` — the same ~0 collapse this branch exists to
    # prevent. Require an OBJECT before trusting it.
    if jq -e 'type == "object"' "$clock" >/dev/null 2>&1; then
      # One jq call for all three fields (see the state read above for why).
      IFS=$'\037' read -r sealed created clk_base <<CEOF
$(jq -r '[(if (.sealed // false) == true then "yes" else "no" end), (.created_at // ""), (.base // "")] | join("\u001f")' "$clock" 2>/dev/null || printf 'no')
CEOF
      [ -n "$sealed" ] || sealed="no"
    else
      # A corrupt (or non-object) clock is left EXACTLY as it is rather than
      # rebuilt. Rebuilding would re-seed `created_at` to now and quietly report
      # a ~0 duration; going untouched makes `rc_duration_min` report `absent`,
      # so the caller falls back to its history formula and nothing fabricates a
      # number.
      return 0
    fi
  fi

  # RUN IDENTITY. A branch folder is reused by later runs, so a clock found here
  # may describe a DIFFERENT run — and because a finished clock is sealed, every
  # later run would otherwise inherit the first run's duration verbatim (not even
  # `rejected`, so nothing downstream could detect it). Scope the clock to
  # `state.base`, exactly as the other two run-scoped sidecars do
  # (`record-outcome.sh`'s `.outcome-recorded`, `prevent-mid-protocol-stall.sh`'s
  # base-in-signature). A different base means a different run: discard the
  # inherited stamps and start this run's clock fresh.
  #
  # REFUSE BEFORE ACTING — this must precede the removal below, not follow it. A state
  # WAS supplied but yielded no readable `phase`, so we cannot judge anything about this
  # run: not whether it is over, not whether the clock is ours. Ordered after the
  # removal, "refuse rather than guess" protected nothing — an unreadable state made
  # `st_base` empty, the equality test then read the RUNNING run's own clock as foreign,
  # and it was deleted permanently (the seed gate refuses to start a new one past
  # `define`, so the run reverted to narrated history for the rest of its life).
  #
  # Distinct from "no state ARGUMENT", handled below: that is "nothing to judge by" on a
  # caller that never had state, not a state we failed to read.
  if [ "$state_given" -eq 1 ] && [ -z "$st_phase" ]; then
    return 0
  fi

  # IDENTITY IS ONLY JUDGEABLE WITH A STATE. With no state argument the caller gave us
  # nothing to compare against, so leave an existing clock alone (refresh it) rather
  # than treating it as foreign — deleting on an unjudgeable call is the same mistake
  # as above, and the one-arg form is a documented part of the contract.
  # A SEALED clock beside a state that is NOT `done` is unambiguously a previous run's:
  # a live run's own clock is never sealed, because sealing happens only at `done`. So
  # this one is safe to REMOVE at any phase — and it must be, because it is the closure
  # for the fork-point collision `base` cannot see (`base` is the fork point, not a run
  # identity: two runs share it whenever the default branch has not moved). Leaving it
  # would let the reader match it once the new run reaches `done`, where the
  # sealed-beside-live test no longer applies.
  if [ "$state_given" -eq 1 ] && [ "$clock_existed" -eq 1 ] \
     && [ "$sealed" = "yes" ] && [ -n "$st_phase" ] && [ "$st_phase" != "done" ]; then
    rm -f "$clock" 2>/dev/null || true
    created=""; sealed="no"; clk_base=""
  # A BASE MISMATCH is the other identity signal, and it is deliberately handled
  # differently, because unlike sealing it can also mean "this run's own state
  # momentarily has no readable base" rather than "this clock is someone else's".
  # Identity is EQUALITY here too (an earlier version required both bases non-empty, so
  # a base-less clock was never discarded and the writer re-branded it with THIS run's
  # base, defeating the reader's guard on the two paths that write rows). Two empty
  # bases still match.
  #
  # At `define` the clock is REPLACED — removed, then re-seeded below as this run's. At
  # any later phase we merely STOP, leaving it exactly as found and writing nothing.
  # Stopping matters as much as replacing: deleting would destroy the RUNNING run's own
  # clock on a momentary unreadable `base`, unrecoverably (nothing starts a clock past
  # `define`), and falling through to the write would re-brand a genuinely foreign one.
  # Neither is needed — the reader applies the same equality test at every phase, so an
  # untouched foreign clock already reads `absent`.
  elif [ "$state_given" -eq 1 ] && [ "$clock_existed" -eq 1 ] && [ "$clk_base" != "$st_base" ]; then
    if [ "$st_phase" = "$RC_SEED_PHASE" ]; then
      rm -f "$clock" 2>/dev/null || true
      created=""; sealed="no"; clk_base=""
    else
      return 0
    fi
  fi

  # A sealed clock is inert — the run is over and its duration already recorded.
  [ "$sealed" = "yes" ] && return 0

  # No state argument at all (rc_stamp is callable with one) — nothing to judge by,
  # and no evidence of an earlier start, so seed. See RC_SEED_PHASE for why the gate
  # below is a phase comparison and not a timestamp one.
  if [ -z "$created" ] && [ -n "$st_phase" ] && [ "$st_phase" != "$RC_SEED_PHASE" ]; then
    return 0
  fi

  [ -n "$created" ] || created="$now"

  # Seal on the first stamp that sees a completed run.
  local seal="false"
  [ "$st_phase" = "done" ] && seal="true"

  local dir tmp
  dir="$(dirname "$clock" 2>/dev/null || true)"
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  # Check writability BEFORE opening the temp file. A redirection into an
  # unwritable directory fails in the SHELL, before the command runs, so its
  # "Permission denied" goes to the script's own stderr and cannot be suppressed
  # by redirecting the command — and this helper is sourced by hooks that must
  # stay silent.
  [ -w "$dir" ] || return 0

  # NEVER ERASE AN IDENTITY WE CANNOT REPLACE. `out_base` is this run's base; when we
  # have none to write (no state argument, or a state whose `base` is unreadable) keep
  # whatever the clock already carries. Blanking it would strip the running run's own
  # clock of its identity, so the very next stamp — with a readable base again — would
  # see a mismatch and treat the clock as foreign.
  #
  # This is NOT the re-branding hazard: by this point the clock is known to be THIS
  # run's (a foreign one returned or was removed above), so there is nothing to launder.
  local out_base="$st_base"
  [ -n "$out_base" ] || out_base="$clk_base"

  tmp="$clock.tmp.$$.${RANDOM:-0}$(date -u +%N 2>/dev/null || echo 0)"
  if ! jq -n --arg c "$created" --arg u "$now" --arg b "$out_base" --argjson s "$seal" \
       '{created_at: $c, updated_at: $u, base: $b, sealed: $s}' > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi
  mv -f "$tmp" "$clock" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  return 0
}

# rc_duration_min <clock_path> [state_path]
#   Prints the three-state verdict: `ok <minutes>` | `rejected` | `absent`.
#   On `rejected`, also prints a one-line reason on stderr. Never mutates.
#
#   Pass <state_path> so the READER can reject a clock belonging to a different
#   run. Scoping only the writer is not enough: a run that is already `done` the
#   first time the clock is seen gets no clock written at all (see rc_stamp), so a
#   foreign clock left in a reused branch folder would survive and be read as this
#   run's duration — the exact inheritance the scoping exists to stop. Defending at
#   the read point also covers the case where no writer ran. Omitting <state_path>
#   skips the check (the pre-scoping behavior), so a caller with no state in hand
#   still works.
rc_duration_min() {
  local clock="${1:-}" state="${2:-}"
  [ -n "$clock" ] || { printf 'absent\n'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'absent\n'; return 0; }
  [ -f "$clock" ] || { printf 'absent\n'; return 0; }
  jq -e 'type == "object"' "$clock" >/dev/null 2>&1 || { printf 'absent\n'; return 0; }

  # Run identity: a clock that names a different `base` than the state describes
  # is not this run's clock. Both sides must be non-empty to judge — an empty
  # clock `base` is a pre-scoping clock (adopt it) and an empty state `base` is a
  # degenerate state we cannot scope by.
  if [ -n "$state" ] && [ -f "$state" ]; then
    local clk_base clk_sealed st_base st_phase
    # One jq call per file rather than one per field (this runs on every recorded
    # row, and the writer path runs on every Bash tool call). Split on US (\037),
    # NOT a tab: tab is IFS-whitespace, so `read` would collapse it and an empty
    # `base` would shift `phase` into the wrong variable. Either field can
    # legitimately be empty, so the separator must be non-whitespace.
    IFS=$'\037' read -r clk_sealed clk_base <<CLKEOF
$(jq -r '[(if (.sealed // false) == true then "yes" else "no" end), (.base // "")] | join("\u001f")' "$clock" 2>/dev/null || printf 'no')
CLKEOF
    IFS=$'\037' read -r st_base st_phase <<STEOF
$(jq -r 'if type == "object" then [(.base // ""), (.phase // "")] | join("\u001f") else "" end' "$state" 2>/dev/null || printf '\037')
STEOF
    # IDENTITY MUST MATCH, not merely "not differ". Requiring equality closes three
    # holes at once: a clock naming a different `base`; a clock carrying a `base` when
    # the state has none (unprovable — abstaining costs only a history fallback); and a
    # clock with NO `base` beside a state that has one. That last shape used to be
    # adopted as a "pre-scoping clock", but that premise is false: `base` ships in the
    # same release as the clock file, so no pre-scoping clock can exist on disk. Its
    # only producer is a writer whose `st_base` was empty — precisely the artefact the
    # unreadable-state refusal above now prevents — so adopting it was a laundering
    # path, not backward compatibility. Two empty bases still match (a caller-supplied
    # state with no base reading a clock with none), which keeps the degenerate case
    # working rather than dead-ending it.
    if [ "$clk_base" != "$st_base" ]; then
      printf 'absent\n'; return 0
    fi
    # A SEALED clock describes a FINISHED run. Beside a state that is still
    # mid-flight it must belong to a previous run in a reused folder — the
    # fork-point collision `base` cannot detect. The writer re-seeds in this case;
    # the reader abstains, because the Phase-5 orchestrator reads without stamping.
    if [ "$clk_sealed" = "yes" ] && [ -n "$st_phase" ] && [ "$st_phase" != "done" ]; then
      printf 'absent\n'; return 0
    fi
  fi

  local c u
  c="$(jq -r '.created_at // ""' "$clock" 2>/dev/null || echo "")"
  u="$(jq -r '.updated_at // ""' "$clock" 2>/dev/null || echo "")"
  [ -n "$c" ] && [ -n "$u" ] || { printf 'absent\n'; return 0; }

  # Whole minutes, floored — the same scale and rounding the history-derived
  # formula has always used, so a clock row and a legacy row stay comparable.
  local d
  d="$(jq -rn --arg c "$c" --arg u "$u" '
        ($c | fromdateiso8601? // null) as $ec
      | ($u | fromdateiso8601? // null) as $eu
      | if ($ec == null or $eu == null) then "absent"
        else ((($eu - $ec) / 60) | floor | tostring) end' 2>/dev/null || echo absent)"
  [ "$d" = "absent" ] && { printf 'absent\n'; return 0; }
  # Accept only an optional leading `-` followed by digits. Anything else (an
  # empty string, an exponent, a stray sign) reads as unmeasurable rather than
  # being fed to `[ -lt ]`, which would error on a non-numeric operand.
  local _mag="${d#-}"
  case "$_mag" in ''|*[!0-9]*) printf 'absent\n'; return 0 ;; esac

  if [ "$d" -lt 0 ]; then
    printf 'rejected\n'
    printf 'run-clock: duration rejected — negative (created_at=%s updated_at=%s delta=%sm)\n' "$c" "$u" "$d" >&2
    return 0
  fi
  if [ "$d" -gt "$RC_MAX_DURATION_MIN" ]; then
    printf 'rejected\n'
    printf 'run-clock: duration rejected — exceeds 12h (created_at=%s updated_at=%s delta=%sm)\n' "$c" "$u" "$d" >&2
    return 0
  fi
  printf 'ok %s\n' "$d"
  return 0
}

# rc_verdict_state <verdict> -> ok | rejected | absent
#   Callers pass this to jq as `--arg clock_state`. Anything unrecognized reads
#   as `absent`, which is the conservative answer: it preserves the caller's
#   pre-existing behavior rather than nulling a duration on a parse slip.
rc_verdict_state() {
  case "${1:-}" in
    ok\ *)    printf 'ok\n' ;;
    rejected) printf 'rejected\n' ;;
    *)        printf 'absent\n' ;;
  esac
}

# rc_verdict_value <verdict> -> the minutes, or the STRING `null`
#   Callers pass this to jq as `--argjson clock_dur`, so it must always be valid
#   JSON. Only an `ok` verdict carries a number.
rc_verdict_value() {
  case "${1:-}" in
    ok\ *) printf '%s\n' "${1#ok }" ;;
    *)     printf 'null\n' ;;
  esac
}
