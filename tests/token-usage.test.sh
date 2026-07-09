#!/usr/bin/env bash
# Focused test for hooks/token-usage.sh — actual token measurement from transcripts.
#
# Asserts: exact sums + breakdown from a fixture transcript; --since numeric
# filtering (excludes older lines, ignores non-assistant lines); slug-based
# auto-discovery INCLUDING dot-mapping (`.` -> `-`) and multi-transcript
# summation across a slug dir; and null-not-zero on a missing transcript/dir.
#
# Controls $HOME + cwd so slug discovery targets a throwaway projects dir.
# Usage: tests/token-usage.test.sh   Exit 0 = all passed.

set -uo pipefail

TU="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/token-usage.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[ -f "$TU" ] || { echo "FAIL: $TU missing"; exit 1; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-52s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-52s got=%s want=%s\n' "$1" "$2" "$3"; fi; }
field(){ printf '%s' "$1" | jq -r "$2"; }

echo "================ token-usage.sh ================"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# A fixture transcript: 2 in-window assistant lines, 1 pre-since assistant line
# (must be excluded), 1 non-assistant line (must be ignored).
# CRITICAL: real Claude Code transcript timestamps carry MILLISECONDS
# (2026-07-07T05:46:30.170Z) which jq fromdateiso8601 cannot parse — the
# fixtures MUST use that format or they'd mask the --since filter breaking on
# every real run. --since itself is integer-second (as STATE.history .at is).
mk_line(){ # ts input output cread ccreate
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' "$1" "$2" "$3" "$4" "$5"
}
TR="$T/session1.jsonl"
mk_line "2026-07-07T01:00:00.170Z" 100 10 1000 50  >  "$TR"
mk_line "2026-07-07T02:00:00.500Z" 200 20 2000 80  >> "$TR"
mk_line "2026-07-06T00:00:00.000Z" 999 99 9999 99  >> "$TR"   # pre-since -> excluded
printf '{"type":"user","timestamp":"2026-07-07T03:00:00.000Z","message":{"role":"user"}}\n' >> "$TR"

SINCE="2026-07-07T00:00:00Z"   # integer-second, as the orchestrator passes it
OUT="$(bash "$TU" --transcript "$TR" --since "$SINCE")"
expect "explicit transcript valid JSON" "$(printf '%s' "$OUT" | jq empty >/dev/null 2>&1; echo $?)" "0"
# expected sums (only the two in-window lines): input 300, output 30, cread 3000, ccreate 130, total 3460
expect "input sum"          "$(field "$OUT" .tokens_breakdown.input)"          "300"
expect "output sum"         "$(field "$OUT" .tokens_breakdown.output)"         "30"
expect "cache_read sum"     "$(field "$OUT" .tokens_breakdown.cache_read)"     "3000"
expect "cache_creation sum" "$(field "$OUT" .tokens_breakdown.cache_creation)" "130"
expect "total sum"          "$(field "$OUT" .tokens_total)"                    "3460"
expect "messages counted"   "$(field "$OUT" .messages)"                        "2"

# No --since => includes the pre-window line too (total 3460 + 11196 = 14656; msgs 3).
ALL="$(bash "$TU" --transcript "$TR")"
expect "no-since includes all assistant lines" "$(field "$ALL" .messages)" "3"

# --- model + Claude Code version extraction (anonymous) ----------------------
MV="$T/mv.jsonl"
printf '{"type":"assistant","version":"2.1.205","timestamp":"2026-07-07T05:00:00.0Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$MV"
MVOUT="$(bash "$TU" --transcript "$MV")"
expect "model extracted"            "$(field "$MVOUT" .model)"               "claude-opus-4-8"
expect "claude_code_version extracted" "$(field "$MVOUT" .claude_code_version)" "2.1.205"
# tokens_by_skill: attribution buckets output tokens per skill (auto-task: prefix
# stripped; unattributed -> "base").
BS="$T/byskill.jsonl"
printf '{"type":"assistant","attributionSkill":"auto-task:auto-task-code-review","message":{"usage":{"output_tokens":40}}}\n{"type":"assistant","message":{"usage":{"output_tokens":10}}}\n' > "$BS"
BSOUT="$(bash "$TU" --transcript "$BS")"
expect "by_skill review bucket"     "$(field "$BSOUT" '.tokens_by_skill["auto-task-code-review"]')" "40"
expect "by_skill base bucket"       "$(field "$BSOUT" '.tokens_by_skill.base')"                       "10"
# absent model/version -> null (the original fixture has neither)
expect "model null when absent"     "$(field "$ALL" .model)"                 "null"
expect "cc-version null when absent" "$(field "$ALL" .claude_code_version)"   "null"
# missing-file path also yields null model/version (fail-open shape)
expect "missing-file model null"    "$(field "$(bash "$TU" --transcript /no/such.jsonl)" .model)" "null"

# Slug auto-discovery WITH a dotted cwd (tests the '.'->'-' mapping) + multi-file.
WORK="$T/work.dir/sub"; mkdir -p "$WORK"     # note the dot in 'work.dir'
slug="$(printf '%s' "$WORK" | sed 's/[^a-zA-Z0-9]/-/g')"
PROJ="$T/home/.claude/projects/$slug"; mkdir -p "$PROJ"
mk_line "2026-07-07T01:00:00.170Z" 1 0 0 0 > "$PROJ/a.jsonl"     # 1 msg, total 1
mk_line "2026-07-07T01:00:00.900Z" 0 2 0 0 > "$PROJ/b.jsonl"     # 1 msg, total 2
DISC="$(cd "$WORK" && HOME="$T/home" bash "$TU" --since "$SINCE")"
expect "slug discovery valid JSON"  "$(printf '%s' "$DISC" | jq empty >/dev/null 2>&1; echo $?)" "0"
expect "multi-transcript summed"    "$(field "$DISC" .tokens_total)" "3"
expect "multi-transcript file count" "$(field "$DISC" .transcripts)" "2"

# Fail-open: missing transcript / dir -> null (NOT 0), exit 0.
MISS="$(bash "$TU" --transcript /no/such/file.jsonl --since "$SINCE")"
expect "missing file -> total null"  "$(field "$MISS" .tokens_total)" "null"
expect "missing file -> breakdown null" "$(field "$MISS" .tokens_breakdown.input)" "null"
expect "missing file exit 0" "$(bash "$TU" --transcript /no/such.jsonl >/dev/null 2>&1; echo $?)" "0"
# Empty match window (future --since) -> null, not 0.
FUT="$(bash "$TU" --transcript "$TR" --since 2099-01-01T00:00:00Z)"
expect "no matching msgs -> total null" "$(field "$FUT" .tokens_total)" "null"
# Malformed --since (contains a double-quote) must still emit VALID JSON, exit 0
# (regression: raw interpolation produced {"since":"x"y"} -> parse error).
BADQ="$(bash "$TU" --transcript /no/such.jsonl --since 'x"y')"
expect "quote in --since -> valid JSON" "$(printf '%s' "$BADQ" | jq empty >/dev/null 2>&1; echo $?)" "0"
expect "quote in --since -> exit 0"     "$(bash "$TU" --transcript /no/such.jsonl --since 'x\"y' >/dev/null 2>&1; echo $?)" "0"

echo ""
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
