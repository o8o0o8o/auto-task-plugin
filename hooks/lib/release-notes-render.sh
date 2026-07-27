#!/usr/bin/env bash
# release-notes-render.sh — SHARED, SOURCED helper that turns a
# `release-notes.json` map plus a version range into the short, BOUNDED block of
# user-facing release notes both notification surfaces print.
#
# Sourced by hooks/release-notes.sh to render the BUNDLED notes — "what you just
# got" — over the range (stamped version -> installed version).
#
# It was also used to render an UPSTREAM notes file fetched over the network for a
# "what you would get before updating" notice. That second surface was DROPPED: five
# adversarial passes kept finding new ways for hostile fetched JSON to forge notice
# lines or blow the size bound (newline and U+2028 injection, unvalidated keys,
# non-string values, a multi-document stream defeating every cap), and the input
# space was effectively unbounded. Reading only the bundled artifact removes that
# trust boundary entirely rather than adding another validation layer to it.
#
# PURE RENDERING ONLY. Writes to stdout and returns; never `exit`s, never writes a
# file, never decides a fail-policy — the caller owns that. (Same contract as
# hooks/lib/resolve-run-state.sh, for the same reason: two callers, one behaviour.)
#
# THE RETURN CODE IS THE INTERESTING PART. It distinguishes two states that must
# NOT be conflated, because the caller's stamp handling depends on which occurred:
#
#   0 = answered. Either notes were printed, or the range genuinely contains
#       nothing to say (e.g. every release in it is an internal-only one the
#       maintainer marked `skip`). A settled fact — the caller may advance state.
#   1 = could not determine. No jq, or the notes file is missing / unparseable /
#       not a JSON object. Nothing is printed. The caller must NOT record this as
#       "shown", or the notes are lost permanently rather than retried later.
#
# BOUNDED OUTPUT. At most RNR_MAX_ITEMS notes (newest first), then a
# "(+N earlier releases)" line when more fell in range. A user many versions
# behind must not get a wall of text injected into a SessionStart message — see
# the never-noticeably-slow-a-session contract in hooks/check-version.sh.
#
# Contract:
#   rnr_render <notes-json-path> <from-version> <to-version>
#     Renders the notes a user gained moving `from` -> `to`, newest first:
#       to  >  from   the half-open range (from, to] — `from` exclusive (you
#                     already read it), `to` inclusive (it's what you now have).
#       to  <= from   ONLY `to`. This is the downgrade / revert / side-by-side
#                     case: "you are now on X, here is what X is" — enumerating
#                     everything at or below X would be noise, not news.
#     Pass an empty/absent `from` to mean "no lower bound".
#   Keeping this direction rule INSIDE the lib is deliberate: both callers get the
#   same behaviour without either having to reimplement a version comparison.
#
# BOUNDED IN BOTH DIMENSIONS — count AND size — and the key/value validation below
# is kept even though the input is now the bundled artifact. It is cheap, and the
# file is GENERATED rather than verified: `CN_MAX_LEN` is a documented generator
# tunable, so a conforming notes file can legitimately carry longer notes than this
# renderer wants to print, and a corrupted or hand-edited bundle should degrade
# quietly rather than dump 60 KB into a SessionStart message. Defence in depth on a
# trusted-but-unverified input, not a security boundary.
#
# Tunables (env):
#   RNR_MAX_ITEMS  max notes listed before eliding (default 3)
#   RNR_MAX_CHARS  max characters per rendered note (default 300)
#   RNR_BULLET     bullet prefix for each line (default "  • ")

: "${RNR_MAX_ITEMS:=3}"
: "${RNR_MAX_CHARS:=300}"
: "${RNR_BULLET:=  • }"

# rnr_render <notes-json-path> <from-version> <to-version>
rnr_render() {
  local notes="${1:-}" from="${2:-}" to="${3:-}"

  [ -n "$notes" ] || return 1
  # REGULAR FILE required, not merely readable. A FIFO is readable, so `-r` alone let jq
  # open it - and opening a FIFO for reading BLOCKS until a writer appears, hanging the
  # session start indefinitely. Same defect as the FIFO stamp closed one round earlier;
  # this is the second of three places in the feature where "readable" was standing in for
  # "a file I can actually read without blocking". Reachable via AUTO_TASK_NOTES_FILE or a
  # FIFO placed at the bundled path.
  [ -f "$notes" ] && [ -r "$notes" ] || return 1
  [ -n "$to" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  # Reject anything that is not a JSON object of version -> string up front, so a
  # half-valid payload can't render garbage. `jq -e` also covers unparseable input.
  # --slurp is load-bearing: without it jq evaluates EVERY document in a stream and
  # reports only the last, so a multi-document file passed this guard and the render
  # program below then ran once per document - multiplying RNR_MAX_ITEMS and the size
  # cap by the document count. Requiring exactly one top-level object closes that.
  jq -e -s 'length == 1 and (.[0] | type == "object")' "$notes" >/dev/null 2>&1 || return 1

  local max="$RNR_MAX_ITEMS"
  case "$max" in ''|*[!0-9]*) max=3 ;; esac

  local cap="$RNR_MAX_CHARS"
  case "$cap" in ''|*[!0-9]*) cap=300 ;; esac
  [ "$cap" -lt 16 ] && cap=16          # keep room for an ellipsis plus a few words

  local out
  # Version ordering is done in jq rather than bash: splitting "X.Y.Z" into an
  # array of numbers makes jq's own array comparison exactly semver ordering,
  # which avoids duplicating check-version.sh's `_ver_parse`/`_ver_newer` into a
  # second implementation that could drift from it.
  out="$(
    jq -r \
      --arg from "$from" \
      --arg to "$to" \
      --argjson max "$max" \
      --argjson cap "$cap" \
      --arg bullet "$RNR_BULLET" '
      def semver: (. // "") | split("+")[0] | split("-")[0] | split(".")
                  | map(tonumber? // 0);
      # A prerelease sorts BELOW its own release, matching check-version.sh.
      def prerel: (. // "") | if test("-") then 0 else 1 end;
      def key: [semver, prerel];

      ($to | key) as $hi
      | (if ($from | length) > 0 then ($from | key) else null end) as $lo
      # Direction rule (see the header): moving forward lists the whole gap;
      # standing still or moving backward reports only where you now are.
      | (($lo != null) and ($hi <= $lo)) as $backward
      | to_entries
      # SANITIZE before anything else. A note is rendered as ONE line, so any
      # control character in it is an injection vector — not a theoretical one:
      # a newline inside a conforming, length-legal note lets upstream content
      # forge additional "  • <version> — <text>" lines that are byte-identical in
      # shape to real ones. That defeats RNR_MAX_ITEMS and the elision count, and
      # SKILL.md instructs the model to present these lines VERBATIM in the
      # Phase-1 update prompt, so forged version/summary pairs would reach a
      # user-facing decision. Collapse every control char to a space, then drop
      # notes that are empty or whitespace-only (which would otherwise render a
      # content-free bullet and still advance the stamp on surface A).
      # Two hazards this comment block must itself avoid, both learned the hard
      # way right here: NO apostrophes (the whole jq program is one single-quoted
      # shell string, so one would silently truncate it) and NO literal control
      # bytes (a NUL terminates the program at the C level, so jq silently runs
      # only the part before it and returns a wrong-but-valid result). The test
      # suite now asserts both, for this file and for changelog-notes.sh.
      #
      # The class is POSIX [[:cntrl:]] plus U+2028/U+2029 written as SINGLE-backslash
      # escapes. Both details were learned by getting them wrong: a codepoint RANGE
      # (\u0000-\u001f) is resolved as a jq string escape before the regex engine
      # sees it and rewrote ordinary ASCII into garbage, while a DOUBLE-backslash
      # escape stayed a literal two-character \u2028 that Oniguruma ignored, so the
      # separators sailed through. Single backslash inside a POSIX class is the form
      # that actually works: jq turns it into the character, and the class matches it.
      # U+2028/U+2029 are needed because they are Unicode Zl/Zp, not Cc, so
      # [[:cntrl:]] never covered them - and an LLM reading the notes verbatim (see
      # SKILL.md) can plausibly treat them as line breaks, which is the forgery this
      # sanitiser exists to stop.
      # Value must already BE a string. tostring used to be applied first, which
      # happily rendered null as "null", 42 as "42" and an object as its JSON text.
      | map(select((.value | type) == "string"))
      # The KEY is untrusted too, and was previously interpolated raw. It reaches
      # the output at the same place as the value, so it needs the same treatment:
      # a newline in a key forged a second bullet line, and a 40 KB key produced a
      # 40 KB notice with both caps nominally in force. Require the documented
      # version shape, which rejects both, then sanitise defensively.
      | map(select(.key | test("^[0-9]+\\.[0-9]+\\.[0-9]+[0-9A-Za-z.+-]*$")))
      | map(.key |= (gsub("[[:cntrl:]\u2028\u2029]"; " ") | .[0:64]))
      | map(.value |= (gsub("[[:cntrl:]\u2028\u2029]"; " ")
                                | gsub(" +"; " ") | ltrimstr(" ") | rtrimstr(" ")))
      | map(select((.value | length) > 0))
      | (if $backward
           then map(select(.key == $to))
           else map(select((.key | key) <= $hi))
                | (if $lo == null then . else map(select((.key | key) > $lo)) end)
         end)
      | sort_by(.key | key) | reverse
      | . as $all
      | ($all | length) as $n
      # Re-truncate every note here, whatever its provenance. jq slicing is
      # CODEPOINT-based, so unlike a byte cut it can never split a character.
      | ($all[0:$max]
         | map($bullet + .key + " — "
               + (if (.value | length) > $cap
                    then ((.value | .[0:$cap-1]) + "…")
                    else .value end)))
        # "in these notes", not a bare count of releases. $n counts the in-range
        # entries THIS ARTIFACT holds, and the artifact keeps only the newest 10
        # releases - so for a user who skipped more than that, a bare "+7 earlier
        # releases" understates what they actually gained and reads as a total. The
        # renderer cannot know the real figure (the older entries are not in the
        # file it was given), so the honest move is to scope the claim to the notes
        # rather than to invent or imply a number it does not have.
        + (if $n > $max
             then ["  (+" + (($n - $max) | tostring) + " earlier release"
                   + (if ($n - $max) == 1 then "" else "s" end) + " in these notes)"]
             else [] end)
      | .[]
    ' "$notes" 2>/dev/null
  )" || return 1

  # An empty render is a legitimate "nothing to say" (all skipped / none in
  # range), NOT a failure — return 0 so the caller may still advance its stamp.
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}
