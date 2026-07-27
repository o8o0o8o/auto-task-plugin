#!/usr/bin/env bash
# changelog-notes.sh — SHARED, SOURCED helper that distills CHANGELOG.md release
# entries into the short, USER-FACING notes shown by the release-notes surfaces.
#
# DEV-TIME ONLY. This is the CHANGELOG->notes extractor consumed by
# `scripts/build-release-notes.sh` (the generator) and by
# `tests/release-notes-sync.test.sh` (the drift guard). It is deliberately NOT
# sourced by any runtime hook: the runtime surfaces read the generated
# `.claude-plugin/release-notes.json` instead, so no session ever pays for
# parsing a 100 KB+ markdown file. Factoring it here is what keeps the generator
# and its drift test from diverging on what a "note" is.
#
# PURE EXTRACTION ONLY. Every function writes to stdout and returns; NONE of them
# `exit`, mutate a file, or decide a fail-policy — the caller owns that. (Same
# contract as hooks/lib/resolve-run-state.sh, for the same reason.)
#
# WHAT COUNTS AS A NOTE
#   For each `## [X.Y.Z]` heading, the note is that release's LEAD PARAGRAPH: the
#   first block of contiguous prose after the heading. Markdown emphasis, inline
#   code, and links are flattened to their text; whitespace is collapsed; the
#   result is truncated at a word boundary to CN_MAX_LEN characters.
#
#   FALLBACK — first-bullet headline. Four early releases (0.1.2/0.1.3/0.1.4/
#   0.1.7) have NO lead paragraph: they open straight into a `### Fixed` /
#   `### Changed` bullet list. Their changes are still user-visible (0.1.2 fixed
#   the `/plugin update` command users type), so dropping them would be wrong.
#   For those, the note falls back to the FIRST bullet — preferring its bold
#   lead-in (`- **Some headline.** rest…` -> "Some headline.") since that is
#   already a one-line summary, and using the whole bullet when it has none.
#
# USER-VISIBLE ONLY (the governing product rule)
#   A release whose changes are invisible to users must NOT appear in the notes.
#   Because that is a judgment no parser can make, it is declared in the
#   CHANGELOG itself with an HTML comment inside the release's own block:
#
#     <!-- release-notes: skip -->            omit this release entirely
#     <!-- release-notes: some short text -->  use this text as the note verbatim
#
#   POSITION MATTERS: the marker must be the FIRST content of the release block -
#   directly under the `## [X.Y.Z]` heading, before the lead paragraph or any bullet.
#   Written lower down it is an EXAMPLE, not an instruction (a release documenting
#   this feature must not delete its own note), and the extractor reports it rather
#   than guessing. Saying only "inside the block" is what produced a silent R5 breach.
#
#   A marker is recognized ONLY as a WHOLE LINE (surrounding whitespace aside) and
#   ONLY outside fenced code blocks. That strictness is load-bearing, not fussy:
#   release entries legitimately *mention* the marker when documenting it, and a
#   substring match would let a sentence like "mark internal releases with
#   `<!-- release-notes: skip -->`" silently delete that release's own notes — or
#   an example of the override form silently retitle it. A notification feature
#   quietly doing nothing is the worst failure this design has, so the directive
#   form and the documented form must not be confusable.
#
#   Unmarked releases are INCLUDED (include-by-default). The asymmetry is
#   deliberate: including an internal release is visible noise a maintainer can
#   correct, whereas excluding by default would silently swallow a user-facing
#   release — a notification feature quietly doing nothing, which is worse.
#
# Contract: source this file, then call the functions below.
#   cn_extract_all <changelog-path>   TSV to stdout: "<version>\t<note>" per
#                                     included release, in document order
#                                     (newest first). Skipped releases are
#                                     absent. Prints nothing if the file is
#                                     missing/unreadable.
#                                     RETURNS 3 (and explains on stderr) when a
#                                     release block was TRUNCATED by an
#                                     unterminated `<!--` or fence — the one case
#                                     where staying quiet could cost a
#                                     user-visible release its note. Callers must
#                                     treat 3 as fatal rather than write a notes
#                                     file that is silently missing a release.
#   cn_note <changelog-path> <version>  the single note for <version>, or nothing
#                                     when absent/skipped.
#
# "Pure" above means no `exit` and no file writes — it does not mean silent at any
# cost. Signalling malformed input through a return code keeps the fail-policy with
# the caller, which is the part of the contract that matters.
#
# Tunables (env, honoured by both callers so the generator and the test agree):
#   CN_MAX_LEN   max note length in characters (default 300)

# Max note length. Kept as a variable, not a literal, so the generator and the
# drift test cannot disagree about the cap.
: "${CN_MAX_LEN:=300}"

# cn_extract_all <changelog-path>
#   Emits "<version>\t<note>" for every INCLUDED release, newest first.
cn_extract_all() {
  local file="${1:-}"
  [ -n "$file" ] || return 0
  # Regular file, not merely readable: awk would block forever on a FIFO. The generator
  # validates this too, but this lib is a sourced public contract with other callers (the
  # drift test calls it directly), so it validates its own input rather than trusting them.
  [ -f "$file" ] && [ -r "$file" ] || return 0

  # LC_ALL=C is load-bearing, not cargo-culted. The truncation below cuts at a BYTE
  # offset, which can land mid-character; in a UTF-8 locale the next regex match on
  # that string makes awk abort with "towc: multibyte conversion failure" and the
  # generator dies with a diagnostic naming no release (reproduced at exactly the
  # byte offsets where a multi-byte char straddles the cut). Forcing the C locale
  # makes awk byte-oriented throughout, so a split sequence is inert data rather
  # than a fatal conversion — which is what the truncation comment below has always
  # assumed. Every pattern in this program is ASCII, so nothing else changes.
  LC_ALL=C awk -v maxlen="${CN_MAX_LEN}" '
    # ---- input normalisation, before ANY rule inspects a line ---------------
    # Strip a trailing CR so a CRLF checkout behaves identically to LF. Without
    # this, `-->[ \t]*$` cannot match `-->\r`, so every curation directive is
    # SILENTLY discarded (the release gets published despite a `skip`); blank lines
    # stop terminating a lead paragraph; and raw CR reaches the notes file, where
    # it returns the terminal cursor to column 0 and the note overwrites its own
    # bullet prefix. There is no .gitattributes here, so a contributor with
    # core.autocrlf=true gets CRLF.
    { sub(/\r$/, "") }

    # ---- where are we? ------------------------------------------------------
    # Names the location for a diagnostic. Before the first heading there IS no
    # release, and interpolating `ver` there printed "release []" - a message whose
    # own caller promises it "names the release and the problem", sending a
    # maintainer to grep for a release that does not exist. The END guard below
    # already worded this case correctly; this makes that wording shared rather than
    # a precedent each new guard has to remember to copy.
    function where() {
      return (ver == "" ? "the preamble (before the first release heading)" \
                        : "release [" ver "]")
    }

    # ---- flush the release we just finished collecting ---------------------
    function flush() {
      if (ver == "") return
      # NEVER truncate silently. An unterminated <!-- or fence swallows the rest
      # of the release block, which can leave a user-visible release with NO note
      # at all — the one outcome this whole feature must not have ("a
      # notification feature quietly doing nothing"). A missing --> is an ordinary
      # editing typo, and the drift test cannot catch it (a release absent from
      # both the committed file and a fresh generation looks perfectly
      # consistent). So report it and make the generator fail loudly instead.
      if (incomment || fence) {
        printf("changelog-notes: release [%s] has an unterminated %s; its block was truncated and its note may be missing\n", \
               ver, (incomment ? "HTML comment (missing -->)" : "fenced code block")) > "/dev/stderr"
        malformed = 1
        truncated = 1
      }
      # Precedence: explicit override > lead paragraph > first-bullet headline.
      note = override
      if (note == "") note = lead
      if (note == "") note = bullet_headline(bullet)
      # Test the CLEANED note, not the raw one. The guard below used to check `note`
      # while the print path emitted `clean(note)`, and clean() can empty a
      # raw-non-empty string: it deletes every asterisk, so a markdown thematic
      # break (`***` or `* * *`, both valid CommonMark) as the first content passed
      # the guard and then shipped as "X.Y.Z": "". That bypassed the whole
      # loud-refusal contract - the generator printed success, --check reported up to
      # date, and at runtime the renderer drops an empty value, so the hook took its
      # nothing-to-report branch and ADVANCED the stamp: the release notice consumed
      # forever. Cleaning once and branching on the result closes the gap between
      # "something was extracted" and "something survives flattening".
      cleaned = clean(note)
      if (!skip && cleaned != "") {
        print ver "\t" cleaned
      } else if (!skip && cleaned == "" && !truncated) {
        # A release the maintainer did NOT mark `skip`, yet nothing usable came out
        # of it. Silently omitting it is the same worst-case outcome the truncation
        # guard above exists to prevent, and the drift test structurally cannot see
        # it: a release absent from both the committed file and a fresh generation
        # reads as perfectly consistent. So report it and let the generator refuse to
        # write. If the release genuinely has nothing user-visible to say, the fix is
        # to mark it `skip` — which makes the intent explicit instead of inferring it
        # from an empty block.
        #
        # Both causes are named and neither is asserted: nothing was extracted at all
        # (a table-only entry, an empty heading), or something was extracted and
        # flattened to nothing (a thematic break, a line of pure markup). Guessing
        # between them would send a maintainer to the wrong place.
        printf("changelog-notes: release [%s] yielded no usable note and is not marked skip. Either it has no lead paragraph and no bullet, or its first content flattened to empty text (a `***` thematic break, or a line of pure markup). Add a lead paragraph, or an explicit <!-- release-notes: skip --> marker as the first content of the block\n", \
               ver) > "/dev/stderr"
        malformed = 1
      }
      ver = ""; lead = ""; override = ""; bullet = ""; skip = 0; lead_done = 0; fence = 0; fencechar = ""; fencelen = 0; incomment = 0; truncated = 0; block_started = 0
    }

    # ---- is this line a CommonMark THEMATIC BREAK? --------------------------
    # Three or more `*`, `-` or `_`, optionally space-separated, alone on a line.
    # ONE definition with two call sites (the bullet capture and the structural-line
    # test) because both have to agree: `- - -` is a thematic break, NOT a bullet, and
    # when only the structural test knew that, the bullet capture - which runs first -
    # still grabbed it and shipped a note reading "- -". Two copies of one predicate
    # drifting apart is precisely how the marker grammar ended up with three different
    # spellings of the same question.
    function is_break(l) {
      return (l ~ /^[ \t]*((\*[ \t]*){3,}|(-[ \t]*){3,}|(_[ \t]*){3,})[ \t]*$/)
    }

    # ---- first-bullet fallback: prefer the bold lead-in ---------------------
    # "- **Headline.** trailing prose" -> "Headline."   (already a summary)
    # "- plain bullet text"            -> "plain bullet text"
    function bullet_headline(b) {
      if (b == "") return ""
      sub(/^[-*+][ \t]+/, "", b)
      if (b ~ /^\*\*/) {
        tmp = b
        sub(/^\*\*/, "", tmp)
        if (match(tmp, /\*\*/)) return substr(tmp, 1, RSTART - 1)
      }
      return b
    }

    # ---- markdown -> plain text, collapse, truncate on a word boundary -----
    function clean(s) {
      # Asterisks: delete every one, rather than trying to match italic PAIRS.
      # Pairing is wrong here because a changelog sentence mixes emphasis with
      # glob stars, and the asterisk of a glob happily pairs with the opening
      # delimiter of a real italic — "*.sql ... *conversation*" came out as
      # ".sql ... conversation*": text corrupted AND a stray delimiter left
      # behind, i.e. worse than the raw markdown it was meant to clean. Deleting
      # every asterisk can never reorder words or leave a dangling delimiter;
      # the only cost is that a glob reads as ".sql" rather than "*.sql", which
      # is fine in a one-line plain-text summary.
      gsub(/\*/, "", s)                        # bold + italic + glob stars
      # Underscore emphasis is deliberately NOT handled: this changelog never
      # uses it, while `_` appears constantly inside identifiers (node_modules,
      # covered_by_acs), and stripping those would corrupt notes.
      # NOT stripped here: an HTML comment appearing INLINE within prose. Tried
      # and reverted deliberately. Comment lines are already discarded upstream
      # (the whole-line rule and the multi-line state machine), so the only thing
      # an inline strip adds is deleting a comment a maintainer QUOTED on purpose
      # — and the realistic instance of that is a release documenting this very
      # feature, whose note then reads "mark internal releases with and it
      # produces no note." A gappy sentence for a normal case is worse than a
      # visible comment in a case nobody writes; leave quoted text intact.
      gsub(/`/, "", s)                         # inline code
      while (match(s, /\[[^]]*\]\([^)]*\)/)) { # [text](url) -> text
        link = substr(s, RSTART, RLENGTH)
        txt  = link
        sub(/^\[/, "", txt); sub(/\].*$/, "", txt)
        s = substr(s, 1, RSTART - 1) txt substr(s, RSTART + RLENGTH)
      }
      gsub(/[ \t]+/, " ", s)                   # collapse whitespace
      sub(/^ +/, "", s); sub(/ +$/, "", s)
      # Truncate at a word boundary. Cutting only at an ASCII space keeps the
      # result valid UTF-8 (the changelog is full of em dashes), which a blind
      # substr() would not guarantee.
      #
      # Budget the ellipsis BEFORE cutting, so the FINAL string honours maxlen —
      # truncating to maxlen and then appending would overshoot. We reserve 3
      # units because awk here measures bytes (C locale) and U+2026 is 3 bytes;
      # reserving the byte cost is the conservative choice, and a byte-length
      # under maxlen also guarantees a CODEPOINT length under maxlen (UTF-8 uses
      # >= 1 byte per codepoint), which is what jq measures when the cap is
      # asserted downstream.
      if (length(s) > maxlen) {
        s = substr(s, 1, maxlen - 3)
        if (match(s, / [^ ]*$/)) s = substr(s, 1, RSTART - 1)
        # Cutting back to a space normally removes any half-character with the
        # partial word. The exception is a window holding no space at all (one
        # ultra-long token), so drop a trailing incomplete UTF-8 sequence
        # explicitly: continuation bytes first, then a lead byte left dangling.
        # Byte ranges are safe to write because the C locale is forced above.
        sub(/[\200-\277]+$/, "", s)
        sub(/[\302-\364]$/, "", s)
        # Trailing punctuation, ASCII only. An em dash was removed from this class
        # deliberately: under the forced C locale a bracket expression matches
        # BYTES, so listing a 3-byte character here would strip its bytes
        # individually and could corrupt an adjacent multi-byte character.
        sub(/[ ,;:.-]+$/, "", s)
        s = s "\xe2\x80\xa6"                   # ellipsis
      }
      return s
    }

    # ============ THE MARKER GRAMMAR IS A MATRIX (read this too) =============
    # Three rules below each answer a DIFFERENT question about the same syntax, and
    # each question crosses both payload kinds. Four consecutive review rounds each
    # patched one cell of this matrix and left the adjacent cell open, which is why
    # the same twenty lines produced a defect four times running. Enumerated here so
    # the axis is visible instead of rediscovered:
    #
    #                                        payload = skip     payload = override
    #   rule 4  complete one-line directive  honour (skip=1)    honour (override=m)
    #   rule 1  orphaned payload line        report             report
    #   rule 5  opener carries the key       report             report
    #
    # Rule 4 has a THIRD outcome not shown above, and it is not an exception to the
    # payload axis: a payload that normalises to "skip" but is not exactly `skip`
    # (SKIP, skip.) is a near-miss TYPO, so it reports rather than being published as
    # override text titled "SKIP". Listed here because this table exists to stop the
    # axis being rediscovered, and a table that showed only honour/honour could invite
    # someone to simplify that guard away. Since rule 1 became payload-agnostic the
    # two forms agree: a near-miss reports whether it is written on one line or split.
    #
    # There is a SECOND axis the table above does not show, and hiding it is what let
    # a silent cell survive to Gate B round 7: POSITION. Rule 4 honours only as the
    # FIRST content of a block (`block_started == 0`); the identical line written
    # below the lead paragraph used to fall through every rule and vanish - the
    # skip-marked release published, the override discarded, rc 0. Rule 4b now reports
    # it. So the full grammar is (context x payload x position), and every cell either
    # honours or reports; none is silent.
    #
    # Rules 1 and 5 REPORT rather than honour on purpose: a directive split across
    # lines is not recognised by rule 4, so acting on it would mean inventing a
    # second syntax, while ignoring it silently loses the maintainer intent. Both
    # rows must stay payload-agnostic - rule 1 hardcoded `skip` for two rounds and
    # that single asymmetry was the round-17 defect. tests/release-notes-sync.test.sh
    # pins all six cells plus the non-directive shapes that must stay silent.
    #
    # ================= RULE PRECEDENCE (read this before editing) ============
    # awk evaluates rules top-down, and every earlier bug in this program came from
    # that order rather than from any single rule. The order below is the contract:
    #
    #   1. inside a comment   swallow (a comment hides EVERYTHING, even a fence)
    #   2. fence toggle       structural, tracked from byte 0 (preamble included)
    #   3. inside a fence     swallow (a fence hides headings and directives)
    #   4. curation marker    a directive only when outside comment AND fence
    #   5. comment open       starts state 1
    #   6. release heading    unreachable inside a comment or fence, by 1/3 above
    #   7. preamble content   dropped (AFTER state tracking, never before it)
    #   8. content            lead paragraph / first bullet
    #
    # Three concrete failures this ordering fixes, all on VALID markdown:
    #   * A fenced example in the PREAMBLE. Tracking used to start only after the
    #     first heading, so the opening fence was never seen; the example heading
    #     became a phantom release, the real next release vanished, and the run
    #     aborted naming a version that does not exist.
    #   * A fence line INSIDE a comment. The fence rule used to run first and flip
    #     the flag mid-comment, swallowing the comment closer, then reporting a
    #     "missing -->" that was in fact present.
    #   * A heading merely SHOWN in a fenced or commented example — the natural way
    #     to document this very feature — parsed as a real release.
    #
    # Tradeoff, accepted deliberately: a genuinely unterminated fence or comment
    # swallows every LATER release too, not just its own block. In that case it is
    # reported — flush(), or the END guard for a preamble-only break — and the
    # generator refuses to write.
    #
    # KNOWN LIMITATION, and deliberately NOT guarded. The reporting above keys on a
    # flag still being OPEN at a release boundary or at EOF. A fence that is left
    # unclosed inside its own release but happens to be closed by a later ``` is
    # therefore BALANCED overall, so nothing reports it, and every heading it spans
    # is swallowed — a real release can be dropped with exit 0 and no diagnostic:
    #
    #     ## [0.26.0]
    #     ```
    #     open
    #                          <- ## [0.25.0] here is swallowed, silently
    #     still inside
    #     ```
    #     After.               <- becomes 0.26.0 lead paragraph
    #
    # It is NOT detectable at parse time: "a heading inside a fence" is exactly the
    # shape of the LEGITIMATE documented example that rounds 6 and 8 exist to
    # support (a release entry showing what a release entry looks like), so any
    # line-level check would fire on every release that documents the format.
    #
    # It is not soundly detectable by ACCOUNTING either, which was tried and
    # reverted: comparing (headings) - (skip directives) against (extracted notes)
    # needs counters that are fence-aware to agree with this extractor, and a
    # fence-aware counter shares the same blindness, so the equality holds
    # trivially. A fence-blind counter instead reds on valid input - a fenced
    # example of the marker, which the release checklist asks maintainers to write,
    # counts as a directive. So this limitation is documented and pinned by a test
    # that asserts the CURRENT behaviour, not guarded by a check that cannot be
    # made correct. It requires a fence unbalanced WITHIN a release, which markdown
    # renderers also mis-handle, and the nesting fix above removes the most likely
    # way to hit it by accident.

    # 1. Inside a multi-line HTML comment: swallow everything until it closes.
    #    FIRST, so a fence line inside a comment cannot touch the fence flag.
    incomment {
      # A directive spelled across several lines is swallowed here before the
      # directive rule can see it, so `skip` written that way was silently ignored
      # and the internal release published - R5 violated with no signal.
      #
      # ANCHORED, not a substring match. A substring match also fired on a
      # commented-out draft that merely DISCUSSED the marker ("we should probably use
      # release-notes: skip for the next one"), which blocked a valid changelog AND
      # printed advice - "put it on one line" - that would have turned that prose
      # into a real directive and silently omitted the release. A confidently wrong
      # diagnostic is worse than none. This is the third context in which "mentions
      # the marker" had to be separated from "IS the marker" (inline prose, an
      # own-line demonstration, and now inside a comment), so the whole-line form is
      # the shared shape every one of those rules keys on.
      #
      # The optional trailing `-->` is NOT decoration. Anchoring at `skip[ \t]*$`
      # alone demanded that the payload end the line, but the most natural way to
      # break a comment is `<!--` then `release-notes: skip -->` - the closer SHARES
      # the payload line. That shape was reported by the older substring test and
      # became silent under a bare end-anchor: the anchor traded a false positive for
      # a narrower false NEGATIVE, which is the worse direction here because the
      # release then publishes with no diagnostic at all. Prose is still excluded,
      # because prose has words on one side or the other of the payload.
      #
      # PAYLOAD-AGNOSTIC, deliberately. This rule used to hardcode `skip`, while its
      # two siblings (rule 4, rule 5) accept any payload - so an orphaned OVERRIDE
      # payload line was the one cell of the grammar that stayed silent, discarding
      # the wording a maintainer chose. Rule 5 already states the principle: a split
      # override is equally unrecognised and equally silent, so it is equally worth
      # reporting. The three rules now agree on the payload axis. See the matrix note
      # above the RULE PRECEDENCE block.
      if ($0 ~ /^[ \t]*release-notes:[ \t]*[^ \t].*$/) {
        printf("changelog-notes: %s has a release-notes marker inside a MULTI-LINE comment, which is not recognised; put the whole directive on one line as <!-- release-notes: skip --> or <!-- release-notes: short text -->\n", \
               where()) > "/dev/stderr"
        malformed = 1
      }
      if ($0 ~ /-->/) incomment = 0
      next
    }

    # 2. Fence toggle. Deliberately NOT gated on `ver`, so fences are tracked in
    #    the preamble too. Also ends the lead paragraph, a fence being structural.
    #
    #    NOT a plain boolean flip. CommonMark closes a fence only with the SAME
    #    character and a run at least as long as the opener, which is exactly how a
    #    changelog entry SHOWS a fenced block: wrap it in a longer or different
    #    fence. A blind toggle let the inner fence close the outer one, so the
    #    innermost content escaped as prose and became the release note — a line of
    #    example code shipped to users in place of the real lead paragraph, with
    #    every flag balanced and every guard green. Tracking the opener character
    #    and length is what makes nesting work.
    /^[ \t]*(```+|~~~+)/ {
      line = $0
      sub(/^[ \t]*/, "", line)
      fchar = substr(line, 1, 1)
      flen = 0
      while (substr(line, flen + 1, 1) == fchar) flen++
      rest = substr(line, flen + 1)
      if (!fence) {
        # An OPENER may carry an info string (```bash), so rest is not inspected.
        fence = 1; fencechar = fchar; fencelen = flen
      } else if (fchar == fencechar && flen >= fencelen && rest ~ /^[ \t]*$/) {
        # A CLOSER may be followed ONLY by whitespace. That second half of the
        # CommonMark rule is what makes nesting actually work: an inner fence is
        # nearly always language-tagged, so accepting ```bash as a closer let the
        # inner fence close the outer one and the innermost line escaped as prose
        # to become the release note - exactly the leak this rule claims to close.
        fence = 0; fencechar = ""; fencelen = 0
      }
      # A non-matching fence line inside a fence is content: it neither opens nor
      # closes, and rule 3 below swallows the rest of the block regardless.
      #
      # A fence STARTS THE BLOCK. This rule was the only content-producing rule that
      # left `block_started` at 0, which left one silent cell in the position axis: a
      # marker written after a fenced block but before any prose was still treated as
      # the FIRST content, so rule 4 honoured it and rule 4b never saw it. A release
      # documenting this feature with a fenced example followed by an unfenced one
      # therefore deleted its own note, rc 0, no diagnostic - the round-14 class
      # again. It also falsified the matrix comment claim that no cell is silent.
      # A fence is content by the same reasoning that makes it end the lead
      # paragraph, so the two flags move together.
      block_started = 1
      if (lead != "") lead_done = 1
      next
    }

    # 3. Fenced content is documentation: no headings, no directives, no prose.
    fence { next }

    # 4. The curation marker: WHOLE LINE only, and only inside a release.
    #    Anchored at both ends so an entry that merely documents the marker cannot
    #    suppress or retitle itself. The payload is `.*`, not `[^>]*`: an override
    #    like "<!-- release-notes: Migrates A -> B. -->" contains a `>`, and
    #    excluding it made the line fall through to prose and BECOME the note.
    #    `ver != ""` matters now that this rule runs before the preamble drop — a
    #    marker outside any release must not leak into the first one.
    # `block_started == 0` is the load-bearing half of this rule. A whole-line match
    # anywhere in the block is not enough: the natural way to DOCUMENT this feature is
    # prose, then the marker on its own line as the example - and that shape silently
    # deleted the note of the release doing the documenting, with no diagnostic, which is the
    # worst outcome in this design and was most likely to hit the very next release.
    # A directive therefore only counts as the FIRST content in the release block;
    # anything after prose or a bullet has begun is a demonstration, not an
    # instruction. Both real skip-marked releases (0.21.0, 0.17.1) put it there.
    ver != "" && block_started == 0 && /^[ \t]*<!--[ \t]*release-notes:.*-->[ \t]*$/ {
      m = $0
      sub(/^[ \t]*<!--[ \t]*release-notes:[ \t]*/, "", m)
      sub(/[ \t]*-->[ \t]*$/, "", m)
      if (m == "skip") { skip = 1 }
      else if (m != "") {
        # A payload that is *almost* `skip` is a typo, not an override. Publishing a
        # release the maintainer meant to hide - and titling it "SKIP" - is the
        # worst reading of an ambiguous input, so report instead of guessing.
        probe = tolower(m)
        gsub(/[^a-z]/, "", probe)
        if (probe == "skip") {
          printf("changelog-notes: release [%s] has a marker payload \"%s\" that looks like a misspelled skip directive; use exactly <!-- release-notes: skip --> or reword the override\n", \
                 ver, m) > "/dev/stderr"
          malformed = 1
        } else {
          override = m
        }
      }
      next
    }

    # 4b. The SAME one-line directive shape, but NOT as the first content. Rule 4
    #     above consumed the block_started == 0 case with `next`, so anything
    #     reaching here is a directive written below the lead paragraph or below a
    #     bullet - and it used to VANISH: the release published despite `skip`, or
    #     the maintainer override discarded in favour of the lead paragraph, rc 0,
    #     no diagnostic. That is the R5 breach this whole feature exists to prevent,
    #     and it is the shape the docs invite, because all three of them said only
    #     "inside the release block" and never stated a position requirement.
    #
    #     Why REPORT rather than honour: round 14 established that a directive
    #     cannot count as an instruction wherever it appears, because a release
    #     documenting this feature would then delete its own note. Both readings are
    #     unresolvable by parsing - but they share ONE correct instruction, which is
    #     what makes reporting safe. An unfenced HTML comment renders as NOTHING in
    #     markdown, so showing the marker that way never displayed it to a reader in
    #     the first place; a real example belongs in a fence or inline code (both
    #     already ignored here), and a real directive belongs at the top of the
    #     block. The message says exactly that, so it is correct under either intent.
    #     ACCEPTED FALSE POSITIVE, recorded so it reads as a decision rather than an
    #     oversight. `^[ \t]*` also admits the four leading spaces of an INDENTED code
    #     block, so a maintainer documenting the marker that way gets a refusal even
    #     though indented code is valid markdown. Narrowing 4b to ignore 4-space
    #     indents was considered and rejected: it would make a real directive indented
    #     by four spaces silent again, reopening the exact hole this rule closes, in
    #     exchange for a false positive whose advice - use a fence - is safe and
    #     actionable. Prefer the noisy failure. Related: this extractor does not track
    #     indented code blocks at all (a separate recorded follow-up).
    ver != "" && /^[ \t]*<!--[ \t]*release-notes:.*-->[ \t]*$/ {
      printf("changelog-notes: release [%s] has a release-notes marker BELOW its lead paragraph or bullets; a directive only counts as the FIRST content of its block, so this one would be ignored. Move it directly under the ## [%s] heading - or, if it is meant as an example, put it in a fenced code block or inline code (an unfenced HTML comment renders as nothing anyway)\n", \
             ver, ver) > "/dev/stderr"
      malformed = 1
      next
    }

    # 5. A comment opens. Single-line comments close here and are simply dropped
    #    (metadata, never user-facing text); multi-line ones hand off to rule 1.
    /^[ \t]*<!--/ {
      if ($0 !~ /-->/) {
        # A comment that OPENS with the marker and does not close on this line is a
        # directive split at the colon - `<!-- release-notes:` then `skip -->`. Rule
        # 1 cannot see it, because by then the payload line no longer carries the
        # `release-notes:` key, so it published the release with no signal. This is
        # the one place the attempt is still unambiguous, and it cannot false-positive
        # the way a substring test did: a DOCUMENTED one-line example closes on its
        # own line and never reaches this branch, and prose discussing the marker does
        # not open a comment with it. Reported for any payload, not just skip - a
        # split override is equally unrecognised and equally silent today.
        if ($0 ~ /^[ \t]*<!--[ \t]*release-notes:/) {
          printf("changelog-notes: %s opens a MULTI-LINE comment with a release-notes marker, which is not recognised; put the whole directive on one line as <!-- release-notes: skip -->\n", \
                 where()) > "/dev/stderr"
          malformed = 1
        }
        incomment = 1
      }
      next
    }

    # 6. A new release heading ends the previous release. The !fence && !incomment
    #    guard is redundant given rules 1 and 3 — kept anyway so that reordering
    #    this block cannot silently reintroduce the phantom-release parse.
    !fence && !incomment && /^## \[[0-9]+\.[0-9]+\.[0-9]+[^]]*\]/ {
      flush()
      v = $0
      sub(/^## \[/, "", v); sub(/\].*$/, "", v)
      # A DUPLICATED heading is a maintainer error that used to be silent and
      # destructive: the generator sliced rows before collapsing duplicate keys, so
      # the stale older block won AND one in-window release was dropped entirely.
      # Report it here, where the other loud guards live, rather than papering over
      # it with a dedupe that would still pick a block arbitrarily.
      if (v in seen) {
        printf("changelog-notes: release [%s] appears more than once; remove the duplicate heading (a duplicate silently replaces the note and drops another release)\n", \
               v) > "/dev/stderr"
        malformed = 1
      }
      seen[v] = 1
      ver = v; fence = 0; fencechar = ""; fencelen = 0; incomment = 0; block_started = 0
      next
    }

    # 7. Anything else before the first release heading is preamble. This drop sits
    #    AFTER state tracking on purpose; when it ran before, the preamble was a
    #    blind spot for both state machines.
    ver == "" { next }

    # ---- collect the lead paragraph (and the first bullet, as fallback) -----
    {
      line = $0

      # Remember the first list item of the release, for the no-lead-paragraph
      # fallback. Captured even after the lead is closed, since it is only ever
      # consulted when the lead came back empty.
      if (line !~ /^[ \t]*$/) block_started = 1
      if (bullet == "" && line ~ /^[-*+][ \t]+/ && !is_break(line)) {
        bullet = line
        # Capturing a bullet closes the lead phase. Without this, a release that has
        # no lead paragraph left the phase open and ANY later prose became `lead`,
        # which flush() prefers over `bullet` - so the documented first-bullet
        # fallback never ran and example content could ship as the note.
        lead_done = 1
      }

      if (lead_done) next

      # A structural line ends the lead paragraph once one has started. It must NOT
      # close the lead phase unconditionally: a release whose lead paragraph follows
      # a blockquote callout or a table is legitimate, and closing on the callout
      # made it take the bullet instead - or fail outright with "yielded no note".
      #
      # The narrower rule that fixes the real problem is below: capturing the FIRST
      # BULLET closes the lead phase, because after a bullet list has started a lead
      # paragraph can no longer legitimately appear. That is what stops later prose -
      # from becoming the note of a release that has no lead paragraph at all.
        # Known gap, deliberately not claimed as covered: a 4-space indented code
        # block placed BEFORE any bullet still lands in `lead`, because nothing has
        # closed the lead phase at that point. The real changelog has no indented
        # code blocks (grep -c "^    [^ *-]" = 0), so this is recorded rather than
        # fixed - but the comment must not assert coverage it lacks.
      # A THEMATIC BREAK is structure, not prose. Three or more `*`, `-` or `_`,
      # optionally space-separated, alone on a line (CommonMark). Without this, such a
      # line was collected as text: the asterisk spellings then flattened to empty and
      # shipped as "X.Y.Z": "" (the guard in flush() now catches that), while `---` and
      # `___` survived clean() untouched and shipped as a note reading literally
      # "---" - junk on a user screen either way. Both spellings are the same defect,
      # so both are fixed at the source rather than only where one of them showed up.
      # The real changelog has no such lines (grep -c = 0), so no note changes.
      if (is_break(line) \
          || line ~ /^#/ || line ~ /^>/ || line ~ /^[-*+][ \t]/ || line ~ /^\|/) {
        block_started = 1
        if (lead != "") lead_done = 1
        next
      }
      if (line ~ /^[ \t]*$/) {                 # blank line
        if (lead != "") lead_done = 1          # ends the lead once started
        next
      }
      lead = (lead == "" ? line : lead " " line)
    }

    # Exit 3 (not 0) when any release block was truncated, so the caller can
    # refuse to write a notes file that is quietly missing a release.
    END {
      flush()
      # flush() reports a truncated RELEASE, but it returns early when ver == "" —
      # which is exactly the preamble-only case (an unterminated fence or comment
      # before the first heading swallows the entire file). Without this, that
      # would emit zero releases with exit 0 and the generator would happily write
      # an empty notes file: total silent loss, the worst outcome in this design.
      if (fence || incomment) {
        printf("changelog-notes: unterminated %s before the first release heading; the whole file was swallowed\n", \
               (incomment ? "HTML comment (missing -->)" : "fenced code block")) > "/dev/stderr"
        malformed = 1
      }
      if (malformed) exit 3
    }
  ' "$file"
}

# cn_note <changelog-path> <version>
#   The note for one version, or nothing when the release is absent or skipped.
cn_note() {
  local file="${1:-}" want="${2:-}" tsv rc
  [ -n "$file" ] && [ -n "$want" ] || return 0
  # Extract FIRST, then select — deliberately not one pipeline. A pipeline yields
  # the LAST command status, which silently swallowed cn_extract_all's return 3, so
  # a truncated changelog looked identical to "this version has no note" and the
  # documented contract held for only one of the two exported functions.
  tsv="$(cn_extract_all "$file")"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n' "$tsv" | awk -F'\t' -v v="$want" '$1 == v { print $2; exit }'
}
