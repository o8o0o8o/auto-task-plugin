#!/usr/bin/env bash
# Focused test for hooks/extract-links.sh — the recon link extractor/classifier.
#
# Asserts: valid JSON always; per-kind classification (video/figma/doc/page);
# every row carries a non-empty strategy; URL normalization (markdown links,
# trailing punctuation, uppercase hosts, www.-scheme-less promotion); order-
# preserving dedupe; stdin path; fail-open (empty/junk input -> [] + exit 0);
# unknown flags ignored; deferred bare scheme-less hosts NOT extracted.
# extract-links.sh needs no jq, but this test parses with jq.
#
# Usage: tests/extract-links.test.sh   Exit 0 = all assertions passed.

set -uo pipefail

EL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/extract-links.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[ -f "$EL" ] || { echo "FAIL: $EL missing"; exit 1; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-52s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-52s got=%s want=%s\n' "$1" "$2" "$3"; fi; }
expect_true(){ if [ "$2" -eq 1 ] 2>/dev/null; then PASS=$((PASS+1)); printf '  PASS  %-52s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-52s (condition false)\n' "$1"; fi; }

j(){ bash "$EL" "$@"; }
valid(){ printf '%s' "$1" | jq empty >/dev/null 2>&1; echo $?; }

echo "================ extract-links.sh ================"

# --- Executable bit ----------------------------------------------------------
expect "script is executable" "$([ -x "$EL" ] && echo 1 || echo 0)" "1"

# --- Always valid JSON -------------------------------------------------------
expect "empty (no args, no stdin): valid JSON" "$(bash "$EL" </dev/null | jq empty >/dev/null 2>&1; echo $?)" "0"
expect "empty -> empty array"     "$(bash "$EL" </dev/null | jq -c '.')" "[]"
expect "no-links text -> []"      "$(j --text 'nothing to see here' | jq -c '.')" "[]"
expect "always exits 0 (junk)"    "$(bash "$EL" --text 'no links' >/dev/null 2>&1; echo $?)" "0"
expect "unknown flags ignored"    "$(valid "$(j --wat x --text 'https://example.com')")" "0"

# --- Classification ----------------------------------------------------------
V="$(j --text 'https://www.loom.com/share/abc')"
expect "loom -> video"            "$(printf '%s' "$V" | jq -r '.[0].kind')" "video"
expect "video strategy non-empty" "$(printf '%s' "$V" | jq -r '.[0].strategy | length > 0')" "true"
expect "youtu.be -> video"        "$(j --text 'https://youtu.be/x' | jq -r '.[0].kind')" "video"
expect "vimeo -> video"           "$(j --text 'https://vimeo.com/1' | jq -r '.[0].kind')" "video"
expect "figma -> figma"           "$(j --text 'https://figma.com/file/1' | jq -r '.[0].kind')" "figma"
expect "notion -> doc"            "$(j --text 'https://notion.so/p' | jq -r '.[0].kind')" "doc"
expect "google docs -> doc"       "$(j --text 'https://docs.google.com/d/1' | jq -r '.[0].kind')" "doc"
expect "slack subdomain -> doc"   "$(j --text 'https://acme.slack.com/x' | jq -r '.[0].kind')" "doc"
expect "generic -> page"          "$(j --text 'https://example.com/x' | jq -r '.[0].kind')" "page"
# Dot-anchored host match: real domains that merely END in a known host must NOT
# be swallowed (regression: bare-suffix `*loom.com` matched `bloom.com`).
expect "bloom.com -> page (not video)"  "$(j --text 'https://bloom.com/x' | jq -r '.[0].kind')" "page"
expect "notyoutube.com -> page"         "$(j --text 'https://notyoutube.com/x' | jq -r '.[0].kind')" "page"
expect "loom.com apex -> video"         "$(j --text 'https://loom.com/x' | jq -r '.[0].kind')" "video"
expect "sub.loom.com -> video"          "$(j --text 'https://sub.loom.com/x' | jq -r '.[0].kind')" "video"
expect "page strategy non-empty"  "$(j --text 'https://example.com/x' | jq -r '.[0].strategy | length > 0')" "true"

# Every row always carries a non-empty strategy.
ALL="$(j --text 'https://loom.com/a https://figma.com/b https://notion.so/c https://x.io/d')"
expect "every row has strategy"   "$(printf '%s' "$ALL" | jq '[.[] | select(.strategy|length>0)] | length')" "4"

# --- Normalization -----------------------------------------------------------
expect "markdown link unwrapped -> video" "$(j --text 'see [demo](https://loom.com/x) now' | jq -r '.[0].kind')" "video"
expect "angle-bracket unwrapped"   "$(j --text 'ref <https://notion.so/doc>' | jq -r '.[0].kind')" "doc"
expect "trailing period stripped"  "$(j --text 'go to https://example.com/a.' | jq -r '.[0].url')" "https://example.com/a"
expect "trailing paren stripped"   "$(j --text '(https://example.com/b)' | jq -r '.[0].url')" "https://example.com/b"
expect "uppercase host classified" "$(j --text 'WWW.LOOM.COM/share/1' | jq -r '.[0].kind')" "video"
expect "www scheme-less promoted"  "$(j --text 'visit www.vimeo.com/9' | jq -r '.[0].url')" "https://www.vimeo.com/9"
# Markdown emphasis / inline-code wrappers stripped from edges (Gate B regression).
expect "backtick-wrapped url -> video"  "$(j --text 'repro at `https://loom.com/demo` here' | jq -r '.[0].kind')" "video"
expect "bold-wrapped url -> figma"      "$(j --text 'see **https://figma.com/f** now' | jq -r '.[0].kind')" "figma"
expect "underscore-wrapped url"         "$(j --text 'ref _https://notion.so/p_ end' | jq -r '.[0].kind')" "doc"
# Interior underscores/asterisks in the path must be PRESERVED (not edge-trimmed).
expect "interior underscore kept"       "$(j --text 'https://example.com/foo_bar_baz' | jq -r '.[0].url')" "https://example.com/foo_bar_baz"

# --- Order-preserving dedupe -------------------------------------------------
ORD="$(j --text 'first https://www.loom.com/x then https://example.com/y then dupe https://www.loom.com/x')"
expect "dedupe -> 2 unique"        "$(printf '%s' "$ORD" | jq 'length')" "2"
expect "source order kept idx0"    "$(printf '%s' "$ORD" | jq -r '.[0].kind')" "video"
expect "source order kept idx1"    "$(printf '%s' "$ORD" | jq -r '.[1].kind')" "page"

# --- Deferred: bare scheme-less hosts (no www., no scheme) are NOT extracted --
expect "bare scheme-less deferred" "$(j --text 'check loom.com/share/x and notion.so/p' | jq -c '.')" "[]"

# --- stdin path --------------------------------------------------------------
expect "reads from stdin"          "$(printf 'watch https://loom.com/z' | bash "$EL" | jq -r '.[0].kind')" "video"

# --- port + query + fragment do not break host classification ----------------
expect "port/query/fragment host"  "$(j --text 'https://figma.com:443/f?x=1#top' | jq -r '.[0].kind')" "figma"

echo ""
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
