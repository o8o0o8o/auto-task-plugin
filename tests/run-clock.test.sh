#!/usr/bin/env bash
# Focused test for hooks/lib/run-clock.sh + hooks/stamp-run-clock.sh — the run's
# MEASURED wall-clock.
#
# THE LOAD-BEARING ASSERTIONS are the three-state verdict ones. A run's duration
# used to be derived from model-written `state.history[].at` strings, i.e.
# narrated rather than measured. It now comes from a hook that stamps `date -u`
# into a sidecar clock. The sanity assertion rejects a negative or >12h span, and
# a rejection MUST be distinguishable from "no clock" — because jq's `//` treats
# `null` identically to absent, a two-state design would let a rejected duration
# fall through to the history number, fabricating the value the assertion exists
# to forbid. The `rejected` vs `absent` cases below are what pin that apart.
#
# Also covers: created_at immutability, sealing at phase=="done", the fail-open
# paths (no run / no jq / unwritable dir), the emitted rejection reason, and the
# Stop-block registration ORDER across all three registration sites (the stamper
# must run before record-outcome/send-telemetry or the recorded row would carry
# an updated_at predating the final turn).
#
# Usage: tests/run-clock.test.sh   Exit 0 = all passed.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/hooks/lib/run-clock.sh"
HOOK="$REPO/hooks/stamp-run-clock.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[ -f "$LIB" ]  || { echo "FAIL: $LIB missing"; exit 1; }
[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing"; exit 1; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-56s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-56s got=%s want=%s\n' "$1" "$2" "$3"; fi; }

# shellcheck source=../hooks/lib/run-clock.sh
. "$LIB"

T="$(mktemp -d)"; trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

# A clock <mins> wide, from a fixed origin so the arithmetic is deterministic.
mk_clock(){ # <path> <minutes> [sealed]
  jq -n --argjson m "$2" --argjson s "${3:-false}" \
    '{created_at:"2026-07-30T00:00:00Z",
      updated_at:("2026-07-30T00:00:00Z"|fromdateiso8601|.+($m*60)|todateiso8601),
      sealed:$s}' > "$1"
}

echo "================ rc_duration_min: the three-state verdict ================"

C="$T/c.json"

mk_clock "$C" 90
expect "90m -> ok 90"                  "$(rc_duration_min "$C" 2>/dev/null)"                  "ok 90"
expect "90m -> state ok"               "$(rc_verdict_state "$(rc_duration_min "$C" 2>/dev/null)")" "ok"
expect "90m -> value 90"               "$(rc_verdict_value "$(rc_duration_min "$C" 2>/dev/null)")" "90"

mk_clock "$C" 0
expect "0m is a legitimate duration"   "$(rc_duration_min "$C" 2>/dev/null)"                  "ok 0"

# --- the 12h boundary: 719 / 720 / 721 ---------------------------------------
mk_clock "$C" 719
expect "719m -> ok (under the bound)"  "$(rc_duration_min "$C" 2>/dev/null)"                  "ok 719"
mk_clock "$C" 720
expect "720m -> ok (ON the bound)"     "$(rc_duration_min "$C" 2>/dev/null)"                  "ok 720"
mk_clock "$C" 721
expect "721m -> rejected (over)"       "$(rc_duration_min "$C" 2>/dev/null)"                  "rejected"
expect "721m -> value null"            "$(rc_verdict_value "$(rc_duration_min "$C" 2>/dev/null)")" "null"

# --- negative ----------------------------------------------------------------
mk_clock "$C" -90
expect "negative -> rejected"          "$(rc_duration_min "$C" 2>/dev/null)"                  "rejected"
expect "negative -> value null"        "$(rc_verdict_value "$(rc_duration_min "$C" 2>/dev/null)")" "null"
# Any backwards clock rejects, including a sub-minute one (floor makes it -1).
jq -n '{created_at:"2026-07-30T00:00:30Z",updated_at:"2026-07-30T00:00:00Z",sealed:false}' > "$C"
expect "backwards by 30s -> rejected"  "$(rc_duration_min "$C" 2>/dev/null)"                  "rejected"

# --- absent: rejected and absent MUST NOT be conflated ------------------------
rm -f "$C"
expect "missing clock -> absent"       "$(rc_duration_min "$C" 2>/dev/null)"                  "absent"
expect "absent -> value null"          "$(rc_verdict_value "$(rc_duration_min "$C" 2>/dev/null)")" "null"
expect "absent -> state absent"        "$(rc_verdict_state "$(rc_duration_min "$C" 2>/dev/null)")" "absent"
printf 'not json at all\n' > "$C"
expect "corrupt clock -> absent"       "$(rc_duration_min "$C" 2>/dev/null)"                  "absent"
jq -n '{updated_at:"2026-07-30T01:00:00Z"}' > "$C"
expect "missing created_at -> absent"  "$(rc_duration_min "$C" 2>/dev/null)"                  "absent"
jq -n '{created_at:"not-a-date",updated_at:"2026-07-30T01:00:00Z"}' > "$C"
expect "unparseable stamp -> absent"   "$(rc_duration_min "$C" 2>/dev/null)"                  "absent"
expect "no path arg -> absent"         "$(rc_duration_min "" 2>/dev/null)"                    "absent"

# The distinction the whole design rests on: a REJECTED clock is not an ABSENT one.
mk_clock "$C" 721
expect "rejected != absent"            "$([ "$(rc_duration_min "$C" 2>/dev/null)" != "absent" ] && echo yes || echo no)" "yes"

echo ""
echo "================ rc_duration_min: the rejection is explained ================"

mk_clock "$C" -90
ERR="$(rc_duration_min "$C" 2>&1 >/dev/null)"
expect "negative reason names the bound" \
  "$([ "$(printf '%s' "$ERR" | grep -c 'run-clock: duration rejected — negative')" -ge 1 ] && echo yes || echo no)" "yes"
expect "negative reason carries created_at" \
  "$([ "$(printf '%s' "$ERR" | grep -c 'created_at=')" -ge 1 ] && echo yes || echo no)" "yes"
expect "negative reason carries updated_at" \
  "$([ "$(printf '%s' "$ERR" | grep -c 'updated_at=')" -ge 1 ] && echo yes || echo no)" "yes"
mk_clock "$C" 721
ERR="$(rc_duration_min "$C" 2>&1 >/dev/null)"
expect "over-12h reason names the bound" \
  "$([ "$(printf '%s' "$ERR" | grep -c 'run-clock: duration rejected — exceeds 12h')" -ge 1 ] && echo yes || echo no)" "yes"
# The reason goes to stderr ONLY — stdout must stay a parseable verdict, since the
# row builders capture it via $(...) and feed the result straight to jq.
expect "stdout stays clean on rejection" "$(rc_duration_min "$C" 2>/dev/null)"                "rejected"

echo ""
echo "================ rc_stamp: create, preserve, advance ================"

R="$T/run"; mkdir -p "$R"
S="$R/STATE.json"; printf '{"phase":"define"}\n' > "$S"   # a clock may only be STARTED at define
K="$(rc_clock_path "$S")"
expect "clock sits beside its STATE.json" "$K" "$R/.run-clock.json"

rc_stamp "$K" "$S"
expect "stamp created the clock"       "$([ -f "$K" ] && echo yes || echo no)"                "yes"
expect "clock is valid JSON"           "$(jq empty "$K" >/dev/null 2>&1; echo $?)"            "0"
C0="$(jq -r '.created_at' "$K")"; U0="$(jq -r '.updated_at' "$K")"
expect "created_at is ISO-8601 Z" \
  "$(printf '%s' "$C0" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')" "1"
expect "updated_at is ISO-8601 Z" \
  "$(printf '%s' "$U0" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')" "1"
expect "not sealed while running"      "$(jq -r '.sealed' "$K")"                              "false"

# created_at is immutable; updated_at tracks the latest stamp. Forge an older
# created_at and a stale updated_at so the assertion does not depend on wall-clock
# granularity between two back-to-back calls.
jq -n '{created_at:"2026-07-30T00:00:00Z",updated_at:"2026-07-30T00:00:01Z",sealed:false}' > "$K"
rc_stamp "$K" "$S"
expect "second stamp preserves created_at" "$(jq -r '.created_at' "$K")"                      "2026-07-30T00:00:00Z"
expect "second stamp advanced updated_at" \
  "$([ "$(jq -r '.updated_at' "$K")" != "2026-07-30T00:00:01Z" ] && echo yes || echo no)"     "yes"

# A corrupt clock is left untouched rather than rebuilt — rebuilding would re-seed
# created_at to now and report a bogus ~0 duration instead of falling back.
printf 'corrupt\n' > "$K"
rc_stamp "$K" "$S"
expect "corrupt clock is NOT rebuilt"  "$(cat "$K")"                                          "corrupt"
# `jq empty` accepts ANY valid JSON, so a non-object clock (`[]`, `5`) used to slip
# past the corrupt check and get rebuilt with created_at = now — the same ~0
# collapse. Require an object.
for bad in '[]' '5' '"str"' 'null'; do
  printf '%s\n' "$bad" > "$K"
  rc_stamp "$K" "$S"
  expect "non-object clock ($bad) is NOT rebuilt" "$(cat "$K")"                               "$bad"
done

echo ""
echo "================ rc_stamp: sealing at phase=done ================"

jq -n '{created_at:"2026-07-30T00:00:00Z",updated_at:"2026-07-30T00:30:00Z",sealed:false}' > "$K"
printf '{"phase":"done"}\n' > "$S"
rc_stamp "$K" "$S"
expect "stamp at done sets sealed"     "$(jq -r '.sealed' "$K")"                              "true"
expect "sealing preserves created_at"  "$(jq -r '.created_at' "$K")"                          "2026-07-30T00:00:00Z"
expect "sealing writes a final updated_at" \
  "$([ "$(jq -r '.updated_at' "$K")" != "2026-07-30T00:30:00Z" ] && echo yes || echo no)"     "yes"

# Forge a STALE updated_at before re-stamping. Comparing two stamps taken in the same
# second proves nothing — `date -u` has 1-second resolution, so `updated_at` is
# unchanged whether or not the seal made the later stamps no-ops, and deleting the seal
# rule entirely left this file green. The same cure is already applied above for
# created_at immutability.
jq --arg c "$(jq -r '.created_at' "$K")" -n --arg u "2026-07-30T00:00:01Z" \
  '{created_at:$c,updated_at:$u,sealed:true}' > "$K"
SEALED_AT="2026-07-30T00:00:01Z"
# Inert for as long as the run stays `done` — which is the terminal phase.
printf '{"phase":"done"}\n' > "$S"
rc_stamp "$K" "$S"
expect "a sealed clock stays sealed while done"  "$(jq -r '.sealed' "$K")"                     "true"
expect "a sealed clock stays frozen while done"  "$(jq -r '.updated_at' "$K")"                 "$SEALED_AT"
# But a sealed clock beside a state that is NOT done is deliberately re-seeded: a
# sealed clock describes a FINISHED run, so finding one next to a live run means the
# folder was reused by a new run whose fork point happens to match (see the
# fork-point section below). Treating it as "still sealed" is what let a 10-minute
# run report the previous run's 180 minutes.
printf '{"phase":"execute"}\n' > "$S"
rc_stamp "$K" "$S"
expect "sealed clock + live run -> clock REMOVED"  "$([ -f "$K" ] && echo no || echo yes)"      "yes"
expect "...so the verdict is absent"               "$(rc_duration_min "$K" "$S" 2>/dev/null)"   "absent"

echo ""
echo "================ run identity: a reused branch folder must not inherit ================"
# REGRESSION (code-review blocker). A branch folder outlives the run that created
# it, so a second run finds the first run's clock. Because a finished clock is
# SEALED, every later stamp was a no-op and run B reported run A's duration
# verbatim — not `rejected`, so nothing downstream could detect it, and frozen for
# every future run in that folder. The clock is now scoped by `state.base`, the
# same key the other two run-scoped sidecars use.
RI="$T/reuse"; mkdir -p "$RI"
RS="$RI/STATE.json"; RK="$RI/.run-clock.json"
mkstate(){ jq -n --arg b "$1" --arg p "${2:-execute}" '{phase:$p, base:$b}' > "$RS"; }

# Run A finished: a real 180-minute sealed clock.
mkstate AAA done
jq -n '{created_at:"2026-02-01T05:00:00Z",updated_at:"2026-02-01T08:00:00Z",base:"AAA",sealed:true}' > "$RK"
expect "run A clock reads 180m"        "$(rc_duration_min "$RK" 2>/dev/null)"                 "ok 180"

# Run B reuses the folder with a NEW base. Mid-flight the writer REMOVES the
# inherited clock rather than re-seeding it: a clock cannot be STARTED for a run
# already past `define`, so a re-seed would refuse and leave the foreign clock on
# disk — still readable, and at `done` neither identity check would reject it.
mkstate BBB execute
rc_stamp "$RK" "$RS"
expect "run B removes the inherited clock" "$([ -f "$RK" ] && echo no || echo yes)"            "yes"
expect "run B duration is not 180"         "$([ "$(rc_duration_min "$RK" "$RS" 2>/dev/null)" = "ok 180" ] && echo INHERITED || echo own)" "own"
# ...and it stays gone once run B reaches `done`.
mkstate BBB done
expect "still absent after run B reaches done" "$(rc_duration_min "$RK" "$RS" 2>/dev/null)"    "absent"

# Same base = same run: an unsealed clock is preserved untouched, not restarted.
jq -n '{created_at:"2026-02-01T05:00:00Z",updated_at:"2026-02-01T05:30:00Z",base:"BBB",sealed:false}' > "$RK"
mkstate BBB execute
rc_stamp "$RK" "$RS"
expect "same base keeps created_at"    "$(jq -r '.created_at' "$RK")"                          "2026-02-01T05:00:00Z"

# THE WRITER's identity rule must be pinned in BOTH directions. Every other writer
# fixture pairs a based clock with a base-less state — the direction that stays true
# under the pre-fix "both bases must be non-empty" rule, which is the re-branding
# blocker's root cause. This is the inverse shape.
jq -n '{created_at:"2026-02-01T05:00:00Z",updated_at:"2026-02-01T08:00:00Z",sealed:false}' > "$RK"
mkstate DDD define
rc_stamp "$RK" "$RS"
expect "base-less clock + based state -> replaced" \
  "$([ "$(jq -r '.created_at' "$RK")" != "2026-02-01T05:00:00Z" ] && echo yes || echo no)"      "yes"
# ...and the replacement carries THIS RUN's base. Nothing else asserts the value the
# writer stamps: substituting the clock's own base for the state's made every real run
# base-less, then deleted, then `absent` — with every suite green.
expect "the writer stamps THIS run's base"         "$(jq -r '.base' "$RK")"                     "DDD"
rm -f "$RK"; mkstate EEE define; rc_stamp "$RK" "$RS"
expect "a fresh clock also carries this run's base" "$(jq -r '.base' "$RK")"                    "EEE"

# THE READER must reject a foreign clock too, not just the writer — the writer only
# runs when a hook fires, and the Phase-5 orchestrator reads without stamping.
jq -n '{created_at:"2026-02-01T05:00:00Z",updated_at:"2026-02-01T08:00:00Z",base:"AAA",sealed:true}' > "$RK"
mkstate ZZZ done
expect "reader rejects the foreign clock"  "$(rc_duration_min "$RK" "$RS" 2>/dev/null)"       "absent"
expect "reader without state keeps old behavior" "$(rc_duration_min "$RK" 2>/dev/null)"       "ok 180"
# The MATCHING case must still read — this is the shape rc_stamp emits for every
# real run, so without it a guard that rejected *every* identified clock (making the
# feature inert in production) would leave this file green.
mkstate AAA done
expect "reader ACCEPTS a matching clock"   "$(rc_duration_min "$RK" "$RS" 2>/dev/null)"       "ok 180"

# A stamp driven by a state with NO `base`, against a clock that HAS one, treats the
# clock as FOREIGN and removes it. Identity is an equality test, so "unprovable" and
# "different" are the same answer — deliberately: losing a clock costs only a history
# fallback, whereas keeping one risks reporting a previous run's duration as this
# run's. An earlier version preserved the clock's identity here, and that is exactly
# the shape the writer then re-branded (a base-less clock stamped with this run's
# base), which defeated the reader's guard on the two paths that write rows.
jq -n '{created_at:"2026-07-30T00:00:00Z",updated_at:"2026-07-30T00:30:00Z",base:"AAA",sealed:false}' > "$RK"
printf '{"phase":"define"}\n' > "$RS"     # degenerate/legacy state: no base
rc_stamp "$RK" "$RS"
expect "foreign created_at is discarded, not kept" \
  "$([ "$(jq -r '.created_at' "$RK")" != "2026-07-30T00:00:00Z" ] && echo yes || echo no)"      "yes"
# At `define` the removal is followed by a fresh seed, so a clock exists again — but it
# is THIS run's, never the foreign one re-branded.
expect "the replacement carries this run's (empty) base" "$(jq -r '.base' "$RK")"              ""

# Past `define` a base mismatch is left UNTOUCHED rather than removed — deleting there
# would destroy the running run's own clock on a momentary unreadable `base`, and the
# reader rejects the foreign clock at every phase anyway.
jq -n '{created_at:"2026-07-30T00:00:00Z",updated_at:"2026-07-30T00:30:00Z",base:"AAA",sealed:false}' > "$RK"
printf '{"phase":"execute","base":"BBB"}\n' > "$RS"
rc_stamp "$RK" "$RS"
expect "past define: foreign clock left untouched" "$(jq -r '.created_at' "$RK")"              "2026-07-30T00:00:00Z"
expect "past define: NOT re-branded"               "$(jq -r '.base' "$RK")"                     "AAA"
expect "past define: reader still rejects it"      "$(rc_duration_min "$RK" "$RS" 2>/dev/null)" "absent"
# A momentary unreadable `base` on the running run must NOT cost it its clock.
jq -n '{created_at:"2026-07-30T00:00:00Z",updated_at:"2026-07-30T01:30:00Z",base:"SHA1",sealed:false}' > "$RK"
printf '{"phase":"execute"}\n' > "$RS"
rc_stamp "$RK" "$RS"
expect "base-less blip preserves the clock"        "$([ -f "$RK" ] && echo yes || echo no)"     "yes"
expect "base-less blip preserves its identity"     "$(jq -r '.base' "$RK")"                     "SHA1"
printf '{"phase":"execute","base":"SHA1"}\n' > "$RS"
expect "and the run recovers"                      "$(rc_duration_min "$RK" "$RS" 2>/dev/null)" "ok 90"

# A base-less clock read beside a state that HAS a base is REJECTED, not adopted. It
# used to be adopted as a "pre-scoping clock", but that premise is false: `base` ships
# in the same release as the clock file, so no pre-scoping clock can exist on disk. Its
# only producer was a writer whose own `st_base` was empty — the artefact the
# unreadable-state refusal now prevents — so adopting it laundered a foreign duration.
jq -n '{created_at:"2026-02-01T05:00:00Z",updated_at:"2026-02-01T08:00:00Z",sealed:true}' > "$RK"
mkstate CCC done
expect "base-less clock + based state -> absent" "$(rc_duration_min "$RK" "$RS" 2>/dev/null)"   "absent"
# Two empty bases still match, so a caller-supplied state with no base is not dead-ended.
printf '{"phase":"done"}\n' > "$RS"
expect "both bases empty -> still reads"         "$(rc_duration_min "$RK" "$RS" 2>/dev/null)"   "ok 180"

echo ""
echo "================ never start a clock for a run already UNDERWAY ================"
# REGRESSION (Gate B pass 3, blocker). Seeding created_at = now for a run that began
# earlier measures the time since the clock appeared, not the run — and reports it as
# `ok <small>`, which OVERRIDES both fallbacks including a correct
# actuals.duration_min. Reproduced against the real run: history 269 min, clock `ok 0`.
#
# The gate is STRUCTURAL (`state.phase`), not a timestamp comparison. An earlier fix
# compared now against the run's earliest history `.at`, which made the feature depend
# on the very data it replaces: a narrated session-date or repeated timestamp — the two
# failure modes this feature exists for — refused to ever start a clock, so the feature
# silently never ran. The `define + narrated-badly` cases below are what pin that apart.
UW2="$T/underway"; mkdir -p "$UW2"
US2="$UW2/STATE.json"; UK2="$UW2/.run-clock.json"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
seeded(){ rm -f "$UK2"; rc_stamp "$UK2" "$US2"; [ -f "$UK2" ] && echo yes || echo no; }

# A run past Phase 1 never gets a NEW clock — it cannot have observed the start.
for ph in execute self-verify gate-a review gate-b handover bot-review preview external release done; do
  jq -n --arg p "$ph" --arg t "$NOW_ISO" '{phase:$p,base:"B1",history:[{at:$t}]}' > "$US2"
  expect "phase=$ph -> no clock seeded"        "$(seeded)"                                     "no"
done
expect "...and the verdict is absent (history fallback)" "$(rc_duration_min "$UK2" "$US2" 2>/dev/null)" "absent"

# A run still in `define` ALWAYS gets a clock — whatever the model narrated. These four
# would each have been refused by the timestamp-gap version.
jq -n --arg t "$NOW_ISO" '{phase:"define",base:"B2",history:[{at:$t}]}' > "$US2"
expect "define + accurate timestamp -> seeds"   "$(seeded)"                                     "yes"
jq -n '{phase:"define",base:"B2",history:[{at:"2026-07-30T02:00:00Z"}]}' > "$US2"
expect "define + stale session-date -> STILL seeds" "$(seeded)"                                 "yes"
jq -n '{phase:"define",base:"B2",history:[{at:"2026-07-29T09:00:00Z"},{at:"2026-07-29T09:00:00Z"}]}' > "$US2"
expect "define + repeated timestamp -> STILL seeds" "$(seeded)"                                 "yes"
jq -n '{phase:"define",base:"B2",history:[{at:"not-a-date"}]}' > "$US2"
expect "define + unparseable .at -> STILL seeds" "$(seeded)"                                    "yes"
jq -n '{phase:"define",base:"B3"}' > "$US2"
expect "define + no history -> seeds"           "$(seeded)"                                     "yes"

# An EXISTING clock keeps being refreshed at any phase — the gate is about STARTING one.
jq -n '{phase:"review",base:"B1",history:[{at:"2026-07-30T07:41:26Z"}]}' > "$US2"
jq -n '{created_at:"2026-07-30T07:41:30Z",updated_at:"2026-07-30T07:45:00Z",base:"B1",sealed:false}' > "$UK2"
rc_stamp "$UK2" "$US2"
expect "an existing clock is still refreshed mid-run" \
  "$([ "$(jq -r '.updated_at' "$UK2")" != "2026-07-30T07:45:00Z" ] && echo yes || echo no)"    "yes"
expect "and keeps its original created_at"     "$(jq -r '.created_at' "$UK2")"                 "2026-07-30T07:41:30Z"
# No state to judge by (rc_stamp is callable with one arg) -> seed.
rm -f "$UK2"; rc_stamp "$UK2"
expect "no state arg -> seeds"                 "$([ -f "$UK2" ] && echo yes || echo no)"       "yes"
# The gate must not be a timestamp comparison — assert the code, since a future
# "simplification" back to a gap check reintroduces the silent-never-runs failure.
expect "the seed gate is structural, not a timestamp gap" \
  "$([ "$(grep -c 'RC_SEED_PHASE' "$LIB")" -ge 2 ] && [ "$(grep -c 'RC_SEED_GRACE_MIN' "$LIB")" -eq 0 ] && echo yes || echo no)" "yes"

# AN UNREADABLE STATE IS NOT AN IN-FLIGHT RUN — refuse rather than guess.
# `jq -e 'type == "object"'` gates the obviously-broken shapes, but it ADMITS an object
# whose `.phase` is absent/null/false, or one whose consolidated read errors so the
# fallback blanks both fields (`.base` as an object makes the `join` fail — a
# consequence of merging the two reads into one jq call). With `st_phase` empty neither
# the already-done guard nor the seed-phase gate can fire, so a clock was seeded for a
# finished run and reported `ok <small>`, overriding the history formula AND a correct
# actuals.duration_min. That is the pass-3 blocker through a third door.
for bad in '{"history":[{"at":"2026-07-30T00:00:00Z"}]}' \
           '{"base":{"oops":1},"history":[{"at":"2026-07-30T00:00:00Z"}]}' \
           '{"phase":null,"base":"X"}' \
           '{"phase":false,"base":"X"}'; do
  printf '%s\n' "$bad" > "$US2"
  expect "object state, unreadable phase -> no clock"  "$(seeded)"                              "no"
done
# ...and the shapes that fail the object gate outright.
for bad in '' '{"phase":"done","base":"OLD"' 'not json' '[]'; do
  printf '%s\n' "$bad" > "$US2"
  expect "non-object state [${bad:-<empty>}] -> no clock"  "$(seeded)"                          "no"
done
# REFUSE BEFORE ACTING. The coverage above only proves a clock is not CREATED — every
# case rm -f's first. The destructive removal used to run BEFORE the refusal, so an
# unreadable state blanked `st_base`, the equality test read the RUNNING run's own clock
# as foreign, and it was DELETED permanently (nothing can re-seed past `define`). These
# assert an EXISTING clock survives.
SURV="$T/survive"; mkdir -p "$SURV"
SVS="$SURV/STATE.json"; SVK="$SURV/.run-clock.json"
for bad in '{"phase":{"name":"execute"},"base":"SHA1"}' \
           '{"phase":"execute","base":{"sha":"SHA1"}}' \
           '{"base":"SHA1"}'; do
  jq -n '{created_at:"2026-07-30T00:00:00Z",updated_at:"2026-07-30T01:30:00Z",base:"SHA1",sealed:false}' > "$SVK"
  printf '%s\n' "$bad" > "$SVS"
  rc_stamp "$SVK" "$SVS"
  expect "unreadable state preserves an existing clock" "$([ -f "$SVK" ] && echo yes || echo no)" "yes"
  expect "...and does not touch its created_at"         "$(jq -r '.created_at' "$SVK" 2>/dev/null)" "2026-07-30T00:00:00Z"
done
# The run recovers once the state is readable again.
printf '{"phase":"done","base":"SHA1"}\n' > "$SVS"
expect "run recovers after a transient bad state" "$(rc_duration_min "$SVK" "$SVS" 2>/dev/null)" "ok 90"
# The documented one-arg call refreshes rather than deleting or re-branding: with no
# state there is no identity to compare, so the clock's own must be kept.
jq -n '{created_at:"2026-07-30T00:00:00Z",updated_at:"2026-07-30T00:10:00Z",base:"KEEP",sealed:false}' > "$SVK"
rc_stamp "$SVK"
expect "one-arg stamp keeps created_at"        "$(jq -r '.created_at' "$SVK")"                 "2026-07-30T00:00:00Z"
expect "one-arg stamp keeps the clock's base"  "$(jq -r '.base' "$SVK")"                       "KEEP"
expect "one-arg stamp still advances updated_at" \
  "$([ "$(jq -r '.updated_at' "$SVK")" != "2026-07-30T00:10:00Z" ] && echo yes || echo no)"    "yes"

# The refusal must NOT swallow the legitimate no-state-ARGUMENT case (rc_stamp takes
# one arg); that is "nothing to judge by", not "unreadable".
rm -f "$UK2"; rc_stamp "$UK2"
expect "no state ARGUMENT -> still seeds"      "$([ -f "$UK2" ] && echo yes || echo no)"       "yes"
# An already-`done` run with no clock: the honest verdict is absent, not a fabricated 0.
printf '{"phase":"done","base":"OLD"}\n' > "$US2"
expect "already-done + no clock -> no clock"   "$(seeded)"                                     "no"
expect "already-done + no clock -> absent"     "$(rc_duration_min "$UK2" "$US2" 2>/dev/null)"  "absent"

# The HOOK's own state-validity gate. Testing it through fixtures that rc_stamp ALSO
# rejects proves nothing — both mutants (deleting the hook's line, or weakening it to
# `jq empty`) left all five suites green. The hook's gate is genuinely redundant with
# the helper's, so assert it structurally: the hook must carry an object-shaped gate,
# and must NOT be "aligned" to `jq empty`, which its own comment forbids because an
# empty file is valid input to `jq empty`.
expect "hook carries an object-shaped state gate" \
  "$(grep -c "jq -e 'type == \"object\"' \"\$state\"" "$HOOK")"                                   "1"
expect "hook does NOT use jq empty on the state" \
  "$(grep -c 'jq empty "\$state"' "$HOOK")"                                                    "0"
# Behavior at the hook layer for every unreadable shape (belt: the helper also gates).
HG="$T/hookgate2"; mkdir -p "$HG"
( cd "$HG" && { git init -q -b feat/hg2 . 2>/dev/null || { git init -q .; git symbolic-ref HEAD refs/heads/feat/hg2; }; } )
mkdir -p "$HG/.auto-task/feat/hg2"
for bad in '' '{"phase":"define","base":"X"' 'not json' '[]' '{"base":{"o":1}}'; do
  printf '%s\n' "$bad" > "$HG/.auto-task/feat/hg2/STATE.json"
  rm -f "$HG/.auto-task/feat/hg2/.run-clock.json"
  CLAUDE_PROJECT_DIR="$HG" bash "$HOOK" < /dev/null
  expect "hook refuses unreadable state [${bad:-<empty>}]" \
    "$([ -f "$HG/.auto-task/feat/hg2/.run-clock.json" ] && echo yes || echo no)"                "no"
done
printf '{"phase":"define","base":"X"}\n' > "$HG/.auto-task/feat/hg2/STATE.json"
rm -f "$HG/.auto-task/feat/hg2/.run-clock.json"
CLAUDE_PROJECT_DIR="$HG" bash "$HOOK" < /dev/null
expect "hook clocks a readable define run"     "$([ -f "$HG/.auto-task/feat/hg2/.run-clock.json" ] && echo yes || echo no)" "yes"

# THE RE-SEED HALF of the split. A sealed clock beside a `define` state must be both
# removed AND replaced: blanking the reset that follows the removal leaves `sealed=yes`,
# the "a sealed clock is inert" rule returns before the seed, and the new run gets NO
# clock for its entire life (nothing can start one past `define`) — with every suite
# green, because every other fixture for this branch uses `execute`, the one phase where
# re-seeding is correctly impossible.
RS2="$T/reseed"; mkdir -p "$RS2"
RSS="$RS2/STATE.json"; RSK="$RS2/.run-clock.json"
jq -n '{created_at:"2026-02-01T05:00:00Z",updated_at:"2026-02-01T08:00:00Z",base:"SAME",sealed:true}' > "$RSK"
printf '{"phase":"define","base":"SAME"}\n' > "$RSS"
rc_stamp "$RSK" "$RSS"
expect "sealed clock + define -> replaced, not just removed" "$([ -f "$RSK" ] && echo yes || echo no)" "yes"
expect "the replacement is unsealed"          "$(jq -r '.sealed' "$RSK")"                      "false"
expect "the replacement has a fresh created_at" \
  "$([ "$(jq -r '.created_at' "$RSK")" != "2026-02-01T05:00:00Z" ] && echo yes || echo no)"    "yes"
expect "and the new run can be measured"      "$(rc_duration_min "$RSK" "$RSS" 2>/dev/null)"   "ok 0"

echo ""
echo "================ base is a FORK POINT, not a run identity ================"
# REGRESSION (Gate B pass 2). Two DISTINCT runs in one branch folder share `base`
# whenever the default branch has not moved between them (run A finishes on feat/x,
# its branch is discarded unmerged, the same task is re-run). The base check cannot
# see that, and the inherited clock is sealed, so every later stamp was a no-op and
# run B reported run A's duration verbatim — B1's exact failure mode.
FP="$T/forkpoint"; mkdir -p "$FP"
FS="$FP/STATE.json"; FK="$FP/.run-clock.json"
jq -n '{created_at:"2026-02-01T05:00:00Z",updated_at:"2026-02-01T08:00:00Z",base:"mainZ",sealed:true}' > "$FK"
printf '{"phase":"execute","base":"mainZ"}\n' > "$FS"
expect "reader abstains: sealed clock beside a live run" "$(rc_duration_min "$FK" "$FS" 2>/dev/null)" "absent"
rc_stamp "$FK" "$FS"
expect "writer REMOVES the foreign clock"  "$([ -f "$FK" ] && echo no || echo yes)"             "yes"
expect "...still absent once run B reaches done" "$(printf '{"phase":"done","base":"mainZ"}\n' > "$FS"; rc_duration_min "$FK" "$FS" 2>/dev/null)" "absent"
expect "run B no longer reports 180"       "$([ "$(rc_duration_min "$FK" "$FS" 2>/dev/null)" = "ok 180" ] && echo INHERITED || echo own)" "own"
# The inference must NOT over-fire: a genuinely finished run's sealed clock still reads.
jq -n '{created_at:"2026-02-01T05:00:00Z",updated_at:"2026-02-01T08:00:00Z",base:"mainZ",sealed:true}' > "$FK"
printf '{"phase":"done","base":"mainZ"}\n' > "$FS"
expect "a done run's sealed clock still reads"      "$(rc_duration_min "$FK" "$FS" 2>/dev/null)" "ok 180"
# ...and an UNSEALED clock on a live run is this run's, so Phase 5 (phase=handover)
# must still get its measurement.
jq -n '{created_at:"2026-02-01T05:00:00Z",updated_at:"2026-02-01T08:00:00Z",base:"mainZ",sealed:false}' > "$FK"
printf '{"phase":"handover","base":"mainZ"}\n' > "$FS"
expect "handover reads its own unsealed clock"      "$(rc_duration_min "$FK" "$FS" 2>/dev/null)" "ok 180"
# A clock with an identity read against a state WITHOUT one: abstain, do not adopt.
jq -n '{created_at:"2026-02-01T05:00:00Z",updated_at:"2026-02-01T08:00:00Z",base:"mainZ",sealed:true}' > "$FK"
printf '{"phase":"done"}\n' > "$FS"
expect "base-less state abstains rather than adopts" "$(rc_duration_min "$FK" "$FS" 2>/dev/null)" "absent"

echo ""
echo "================ fail-open paths ================"

# No jq: both functions must no-op rather than error. PATH= hides jq while the
# functions' remaining needs (printf, case, [) are shell builtins.
NJ="$T/nojq"; mkdir -p "$NJ"; jq -n '{created_at:"2026-07-30T00:00:00Z",updated_at:"2026-07-30T01:00:00Z",sealed:false}' > "$NJ/c.json"
expect "no jq -> rc_duration_min absent" "$( ( PATH=""; rc_duration_min "$NJ/c.json" 2>/dev/null ) )" "absent"
BEFORE="$(jq -c . "$NJ/c.json")"
( PATH=""; rc_stamp "$NJ/c.json" ) 2>/dev/null
expect "no jq -> rc_stamp changed nothing" "$(jq -c . "$NJ/c.json")"                          "$BEFORE"

# Unwritable directory: the write fails, nothing is created, and we return 0.
UW="$T/unwritable"; mkdir -p "$UW"; chmod 500 "$UW"
# The fixture MUST be a `define` state. With any later phase rc_stamp returns at the
# seed-phase gate before it ever computes `dir`, so these assertions never reach the
# writability check — deleting the guard left all 150 assertions green.
UWS="$T/uw-state.json"; printf '{"phase":"define","base":"UW"}\n' > "$UWS"
UW_ERR="$(rc_stamp "$UW/.run-clock.json" "$UWS" 2>&1 >/dev/null)"; rc_rc=$?
expect "unwritable dir -> returns 0"   "$rc_rc"                                               "0"
expect "unwritable dir -> no clock"    "$([ -f "$UW/.run-clock.json" ] && echo yes || echo no)" "no"
# The guard's STATED purpose is silence: a redirection into an unwritable directory
# fails in the SHELL, before the command runs, so its "permission denied" reaches the
# helper's own stderr and cannot be suppressed by redirecting the command.
expect "unwritable dir -> helper stays SILENT" "${UW_ERR:-none}"                              "none"
chmod 700 "$UW"

# A directory that does not exist at all.
rc_stamp "$T/nope/.run-clock.json" "$UWS"
expect "missing dir -> returns 0"      "$?"                                                   "0"
expect "missing dir -> no clock"       "$([ -f "$T/nope/.run-clock.json" ] && echo yes || echo no)" "no"

echo ""
echo "================ stamp-run-clock.sh (the hook) ================"

# hooks.json execs the hook directly, so the mode is load-bearing, not cosmetic.
expect "hook is executable"            "$([ -x "$HOOK" ] && echo yes || echo no)"             "yes"

G="$T/repo"; mkdir -p "$G"
( cd "$G" && { git init -q -b feat/clock . 2>/dev/null || { git init -q .; git symbolic-ref HEAD refs/heads/feat/clock; }; } )
expect "fixture repo is on feat/clock" "$(cd "$G" && git branch --show-current)"              "feat/clock"

# No run for this branch: the hook must NOT create a stray clock. Its absence is
# precisely what makes the `absent` verdict meaningful.
CLAUDE_PROJECT_DIR="$G" bash "$HOOK" < /dev/null; hrc=$?
expect "no STATE.json -> exit 0"       "$hrc"                                                 "0"
expect "no STATE.json -> no clock"     "$([ -f "$G/.auto-task/feat/clock/.run-clock.json" ] && echo yes || echo no)" "no"

mkdir -p "$G/.auto-task/feat/clock"
printf '{"phase":"define"}\n' > "$G/.auto-task/feat/clock/STATE.json"
CLAUDE_PROJECT_DIR="$G" bash "$HOOK" < /dev/null; hrc=$?
expect "with a run -> exit 0"          "$hrc"                                                 "0"
expect "with a run -> clock created"   "$([ -f "$G/.auto-task/feat/clock/.run-clock.json" ] && echo yes || echo no)" "yes"
expect "hook wrote valid JSON"         "$(jq empty "$G/.auto-task/feat/clock/.run-clock.json" >/dev/null 2>&1; echo $?)" "0"
# A PreToolUse hook's stdout is not a free-form channel — it must stay silent.
OUT="$(CLAUDE_PROJECT_DIR="$G" bash "$HOOK" < /dev/null 2>/dev/null)"
expect "hook prints nothing on stdout" "${OUT:-empty}"                                        "empty"

# The hook never touches STATE.json — that is the whole reason the clock is a
# sidecar (a model rewrite of STATE.json would otherwise drop created_at).
ST_BEFORE="$(cat "$G/.auto-task/feat/clock/STATE.json")"
CLAUDE_PROJECT_DIR="$G" bash "$HOOK" < /dev/null
expect "hook does not modify STATE.json" "$(cat "$G/.auto-task/feat/clock/STATE.json")"       "$ST_BEFORE"

# Seals through the hook once the run is done.
printf '{"phase":"done"}\n' > "$G/.auto-task/feat/clock/STATE.json"
CLAUDE_PROJECT_DIR="$G" bash "$HOOK" < /dev/null
expect "hook seals a done run"         "$(jq -r '.sealed' "$G/.auto-task/feat/clock/.run-clock.json")" "true"

echo "================ the hook finds a run in a LINKED WORKTREE ================"
# This is the only case that matters in production: auto-task isolates every
# new-description run in a linked worktree, while CLAUDE_PROJECT_DIR still points at the
# main clone. The retarget block in the hook is what makes it look in the worktree at
# all — blanking that block makes the feature completely inert (no clock is ever seeded
# for any real run) while every suite stays green, because nothing else here builds a
# worktree.
WT="$T/wtmain"; mkdir -p "$WT"
( cd "$WT" && { git init -q -b main . 2>/dev/null || git init -q .; } && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init ) >/dev/null 2>&1
git -C "$WT" worktree add -q "$WT/wt" -b feat/wtrun >/dev/null 2>&1
if [ -d "$WT/wt" ] && [ "$(git -C "$WT/wt" branch --show-current 2>/dev/null)" = "feat/wtrun" ]; then
  mkdir -p "$WT/wt/.auto-task/feat/wtrun"
  printf '{"phase":"define","base":"WTSHA"}\n' > "$WT/wt/.auto-task/feat/wtrun/STATE.json"
  # CLAUDE_PROJECT_DIR = the MAIN clone; the payload cwd = the worktree — exactly how
  # Claude Code invokes a hook from inside an entered worktree.
  printf '{"cwd":"%s"}' "$WT/wt" | CLAUDE_PROJECT_DIR="$WT" bash "$HOOK"
  expect "hook clocks a run in a linked worktree" \
    "$([ -f "$WT/wt/.auto-task/feat/wtrun/.run-clock.json" ] && echo yes || echo no)"          "yes"
  expect "...and writes that run's base" \
    "$(jq -r '.base' "$WT/wt/.auto-task/feat/wtrun/.run-clock.json" 2>/dev/null)"              "WTSHA"
  expect "...and nothing leaks into the main clone" \
    "$([ -f "$WT/.auto-task/main/.run-clock.json" ] && echo yes || echo no)"                   "no"
else
  echo "  SKIP  linked-worktree fixture unavailable in this environment"
fi

echo ""
echo "================ Stop-block registration ORDER ================"
# The stamper must precede record-outcome.sh and send-telemetry.sh on `Stop`.
# Those two derive and write the run's row during the same turn-end, so a stamper
# registered after them would leave the row carrying an updated_at that predates
# the final — and typically longest — turn. Checked at all three registration
# sites, since they are hand-maintained copies of one list.

json_stop_idx(){ # <file> <hook basename> -> index within the Stop block, or -1
  jq -r --arg h "$2" '
    (.hooks.Stop[0].hooks // []) | map(.command | sub(".*/hooks/"; ""))
    | (index($h) // -1)' "$1" 2>/dev/null || echo -1
}
for f in hooks/hooks.json settings-fragment.json; do
  i_stamp="$(json_stop_idx "$REPO/$f" stamp-run-clock.sh)"
  i_rec="$(json_stop_idx "$REPO/$f" record-outcome.sh)"
  i_tel="$(json_stop_idx "$REPO/$f" send-telemetry.sh)"
  expect "$f: stamper is in the Stop block" "$([ "$i_stamp" -ge 0 ] && echo yes || echo no)"  "yes"
  expect "$f: stamper before record-outcome" \
    "$([ "$i_stamp" -ge 0 ] && [ "$i_rec" -gt "$i_stamp" ] && echo yes || echo no)"           "yes"
  expect "$f: stamper before send-telemetry" \
    "$([ "$i_stamp" -ge 0 ] && [ "$i_tel" -gt "$i_stamp" ] && echo yes || echo no)"           "yes"
done

# The `PreToolUse`/Bash registration is HALF the design's rationale and was asserted
# nowhere: dropping it from all three sites left every suite green while silently
# degrading to the `stop-only` approach PLAN.md rejects — `created_at` would land at the
# first turn-end (the Phase-1 clarify or plan gate), still `phase: define` so the seed
# gate happily allows it, so the feature keeps returning `ok <number>` while
# systematically undercounting. The Stop-block cross-check cannot catch it either,
# because release-notes-sync derives its canon FROM hooks.json.
json_pre_idx(){ # <file> <hook basename> -> index within the PreToolUse block, or -1
  jq -r --arg h "$2" '
    (.hooks.PreToolUse[0].hooks // []) | map(.command | sub(".*/hooks/"; ""))
    | (index($h) // -1)' "$1" 2>/dev/null || echo -1
}
for f in hooks/hooks.json settings-fragment.json; do
  expect "$f: stamper is in the PreToolUse block" \
    "$([ "$(json_pre_idx "$REPO/$f" stamp-run-clock.sh)" -ge 0 ] && echo yes || echo no)"      "yes"
done
pre_slice(){ awk '/"PreToolUse"[[:space:]]*:/ {inb=1} inb {print} inb && /^[[:space:]]*\],[[:space:]]*$/ {exit}' "$REPO/install.sh"; }
expect "install.sh: stamper is in the PreToolUse block" \
  "$([ "$(pre_slice | grep -c 'stamp-run-clock.sh')" -ge 1 ] && echo yes || echo no)"          "yes"

# install.sh embeds the same list inside a heredoc, so it is compared by line
# position within the Stop block rather than parsed as JSON.
stop_slice(){ awk '/"Stop"[[:space:]]*:/ {inb=1} inb {print} inb && /^[[:space:]]*\],[[:space:]]*$/ {exit}' "$REPO/install.sh"; }
line_of(){ stop_slice | grep -n "$1" | head -1 | cut -d: -f1; }
i_stamp="$(line_of 'stamp-run-clock.sh')"; i_rec="$(line_of 'record-outcome.sh')"; i_tel="$(line_of 'send-telemetry.sh')"
expect "install.sh: stamper is in the Stop block" "$([ -n "$i_stamp" ] && echo yes || echo no)" "yes"
expect "install.sh: Stop block also lists the two row writers" \
  "$([ -n "$i_rec" ] && [ -n "$i_tel" ] && echo yes || echo no)"                              "yes"
expect "install.sh: stamper before record-outcome" \
  "$([ -n "$i_stamp" ] && [ -n "$i_rec" ] && [ "$i_rec" -gt "$i_stamp" ] && echo yes || echo no)" "yes"
expect "install.sh: stamper before send-telemetry" \
  "$([ -n "$i_stamp" ] && [ -n "$i_tel" ] && [ "$i_tel" -gt "$i_stamp" ] && echo yes || echo no)" "yes"

echo ""
echo "================ the three consumers all use the helper ================"
for f in record-outcome send-telemetry auto-task-stats; do
  # Anchor on the SOURCE STATEMENT, not a bare `run-clock` substring — the latter
  # also matches the explanatory comment block above it, so the assertion would
  # still pass if the `.` line were deleted and the comment left behind.
  expect "hooks/$f.sh sources run-clock" \
    "$(grep -cE '\.[[:space:]]+"\$SCRIPT_DIR/lib/run-clock\.sh"' "$REPO/hooks/$f.sh")" "1"
  # Branching on the state (not on nullness) is the fix for jq's `//` collapsing
  # null into the fallback. Assert the branch exists in all three.
  expect "hooks/$f.sh branches on clock_state" \
    "$([ "$(grep -c 'clock_state == "rejected"' "$REPO/hooks/$f.sh")" -ge 1 ] && echo yes || echo no)" "yes"
done

# The two ROW WRITERS must stamp before they read. An event's hooks run in
# parallel, so relying on the Stop stamper winning that race would let a reader
# record a row whose updated_at predates the final turn — permanently, because its
# write-once sentinel never revisits. auto-task-stats.sh is a read-only reporter
# and must NOT stamp.
for f in record-outcome send-telemetry; do
  # Presence AND ORDER. A presence-only grep passes even if the rc_stamp call is
  # moved BELOW the read, which reinstates exactly the race R1 was raised for — so
  # compare line numbers rather than just counting the call.
  n_stamp="$(grep -n 'rc_stamp "\$_rc_clock" "\$state"' "$REPO/hooks/$f.sh" | head -1 | cut -d: -f1)"
  n_read="$(grep -n 'rc_duration_min "\$_rc_clock"' "$REPO/hooks/$f.sh" | head -1 | cut -d: -f1)"
  expect "hooks/$f.sh stamps before reading" \
    "$([ -n "$n_stamp" ] && [ -n "$n_read" ] && [ "$n_stamp" -lt "$n_read" ] && echo yes || echo no)" "yes"
  # And the read must pass the STATE, or the reader-side run-identity guard is
  # skipped and a foreign clock is adopted.
  expect "hooks/$f.sh passes state to the reader" \
    "$(grep -c 'rc_duration_min "\$_rc_clock" "\$state"' "$REPO/hooks/$f.sh")" "1"
done
expect "auto-task-stats.sh passes state to the reader" \
  "$(grep -c 'rc_duration_min "\$(rc_clock_path "\$sf")" "\$sf"' "$REPO/hooks/auto-task-stats.sh")" "1"
# The Phase-5 spec is the FOURTH consumer, and it is a documented caller rather than
# code — it must pass the state too, or the orchestrator writes an inherited duration
# into actuals.duration_min and it launders out through act_duration_min.
expect "the Phase-5 spec passes state to the reader" \
  "$([ "$(grep -c 'rc_duration_min "\$(rc_clock_path <STATE.json path>)" <STATE.json path>' "$REPO/skills/auto-task/references/phase-5-handover.md")" -ge 1 ] && echo yes || echo no)" "yes"
# The PRIMARY defence against the fork-point collision is a Phase-1 branch-setup
# instruction — a new run removes any stale clock, because the sealed-beside-live
# inference cannot cover a folder whose previous run reached `done` and whose new run
# is also read at `done`. It was prose with no assertion anywhere: spec-inventory's
# conservation check only protects lines present in its pinned BASE_REF, so a line
# ADDED by this commit is outside that guard entirely.
expect "the Phase-1 spec removes a stale clock at branch setup" \
  "$([ "$(grep -c 'rm -f .auto-task/<branch>/.run-clock.json' "$REPO/skills/auto-task/references/phase-1-preamble.md")" -ge 1 ] && echo yes || echo no)" "yes"
expect "auto-task-stats.sh does NOT stamp (read-only reporter)" \
  "$(grep -c 'rc_stamp' "$REPO/hooks/auto-task-stats.sh")" "0"

# jq 1.6 rejects a trailing comma before a closing brace/bracket; the same scan the
# other metric helpers get.
tc="$(awk '
  prev ~ /,[[:space:]]*$/ && $0 ~ /^[[:space:]]*[]}]/ { print FILENAME":"NR-1 }
  { prev=$0 }
' "$LIB" "$HOOK" 2>/dev/null)"
expect "no jq-1.6-breaking trailing comma" "${tc:-none}" "none"

echo ""
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
