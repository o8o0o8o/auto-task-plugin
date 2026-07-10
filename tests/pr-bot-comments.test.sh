#!/usr/bin/env bash
# Focused test for hooks/pr-bot-comments.sh — collect bot-authored PR comments.
# Uses the --json-file hook so it never touches gh/network.
#
# Asserts: bot authors kept & humans dropped across all three surfaces (issue
# comments, inline review comments, review summaries); [bot]-suffix + type=="Bot"
# + known-list + --bots detection; inline path/line normalization; empty-body
# reviews dropped; de-duplication across surfaces; and fail-open (missing file /
# bad JSON / no match) always prints a valid `[]`, exit 0.
#
# Usage: tests/pr-bot-comments.test.sh   Exit 0 = all passed.

set -uo pipefail

SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/pr-bot-comments.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[ -f "$SH" ] || { echo "FAIL: $SH missing"; exit 1; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-52s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-52s got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }
run(){ bash "$SH" --json-file "$1" ${2:+--bots "$2"}; }

echo "================ pr-bot-comments.sh ================"
bash -n "$SH"; expect "bash -n clean" "$?" "0"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# --- mixed surfaces: bots kept, humans dropped -------------------------------
cat > "$T/mixed.json" <<'EOF'
{
  "issue_comments": [
    {"author":{"login":"alice"},"body":"lgtm","url":"https://github.com/o/r/pull/1#ic-1","createdAt":"2026-07-10T10:00:00Z"},
    {"author":{"login":"cursor[bot]"},"body":"null-check foo","url":"https://github.com/o/r/pull/1#ic-2","createdAt":"2026-07-10T10:01:00Z"}
  ],
  "review_comments": [
    {"user":{"login":"coderabbitai[bot]","type":"Bot"},"body":"NPE here","path":"src/a.ts","line":42,"html_url":"https://github.com/o/r/pull/1#rc-1","created_at":"2026-07-10T10:02:00Z"},
    {"user":{"login":"bob","type":"User"},"body":"fine","path":"src/a.ts","line":10,"html_url":"https://github.com/o/r/pull/1#rc-2","created_at":"2026-07-10T10:03:00Z"}
  ],
  "reviews": [
    {"user":{"login":"sourcery-ai[bot]","type":"Bot"},"body":"summary","html_url":"https://github.com/o/r/pull/1#rv-1","submitted_at":"2026-07-10T10:04:00Z"},
    {"user":{"login":"carol","type":"User"},"body":"","html_url":"https://github.com/o/r/pull/1#rv-2","submitted_at":"2026-07-10T10:05:00Z"}
  ]
}
EOF
out="$(run "$T/mixed.json")"
expect "mixed: 3 bot comments kept"        "$(printf '%s' "$out" | jq 'length')" "3"
expect "mixed: human alice dropped"        "$(printf '%s' "$out" | jq '[.[]|select(.author=="alice")]|length')" "0"
expect "mixed: human bob dropped"          "$(printf '%s' "$out" | jq '[.[]|select(.author=="bob")]|length')" "0"
expect "mixed: cursor[bot] kept (suffix)"  "$(printf '%s' "$out" | jq '[.[]|select(.author=="cursor[bot]")]|length')" "1"
expect "mixed: coderabbit kept (type Bot)" "$(printf '%s' "$out" | jq '[.[]|select(.author=="coderabbitai[bot]")]|length')" "1"
expect "mixed: empty-body review dropped"  "$(printf '%s' "$out" | jq '[.[]|select(.author=="carol")]|length')" "0"

# --- inline path/line normalization ------------------------------------------
expect "inline path preserved"  "$(printf '%s' "$out" | jq -r '[.[]|select(.author=="coderabbitai[bot]")][0].path')" "src/a.ts"
expect "inline line preserved"  "$(printf '%s' "$out" | jq -r '[.[]|select(.author=="coderabbitai[bot]")][0].line')" "42"
expect "issue comment line null" "$(printf '%s' "$out" | jq -r '[.[]|select(.author=="cursor[bot]")][0].line')" "null"

# --- type=="Bot" but no [bot] suffix (still detected) ------------------------
cat > "$T/typebot.json" <<'EOF'
{"issue_comments":[],"review_comments":[{"user":{"login":"my-custom-reviewer","type":"Bot"},"body":"x","path":"a","line":1,"html_url":"https://github.com/o/r/pull/1#rc-9","created_at":"2026-07-10T10:00:00Z"}],"reviews":[]}
EOF
expect "type==Bot without [bot] suffix kept" "$(run "$T/typebot.json" | jq 'length')" "1"

# --- --bots extension for a login that is neither [bot] nor type Bot ---------
cat > "$T/extra.json" <<'EOF'
{"issue_comments":[{"author":{"login":"housebot-ci"},"body":"y","url":"https://github.com/o/r/pull/1#ic-9","createdAt":"2026-07-10T10:00:00Z"}],"review_comments":[],"reviews":[]}
EOF
expect "unknown non-bot login dropped by default" "$(run "$T/extra.json" | jq 'length')" "0"
expect "--bots extension keeps it"                "$(run "$T/extra.json" "housebot-ci" | jq 'length')" "1"
expect "--bots comma-separated form"              "$(run "$T/extra.json" "foo,housebot-ci,bar" | jq 'length')" "1"

# --- de-duplication across surfaces (same url on two surfaces) ---------------
cat > "$T/dup.json" <<'EOF'
{
  "issue_comments":[{"author":{"login":"cursor[bot]"},"body":"dup finding","url":"https://github.com/o/r/pull/1#same","createdAt":"2026-07-10T10:00:00Z"}],
  "review_comments":[{"user":{"login":"cursor[bot]","type":"Bot"},"body":"dup finding","path":"a","line":1,"html_url":"https://github.com/o/r/pull/1#same","created_at":"2026-07-10T10:01:00Z"}],
  "reviews":[]
}
EOF
expect "dedup by url -> single entry" "$(run "$T/dup.json" | jq 'length')" "1"

# same body/author/path/line but no url -> dedup by content key
cat > "$T/dupnourl.json" <<'EOF'
{
  "issue_comments":[],
  "review_comments":[
    {"user":{"login":"cursor[bot]","type":"Bot"},"body":"same   text","path":"a.ts","line":5,"html_url":"","created_at":"2026-07-10T10:00:00Z"},
    {"user":{"login":"cursor[bot]","type":"Bot"},"body":"same text","path":"a.ts","line":5,"html_url":"","created_at":"2026-07-10T10:01:00Z"}
  ],
  "reviews":[]
}
EOF
expect "dedup by content key (no url)" "$(run "$T/dupnourl.json" | jq 'length')" "1"

# --- malformed element in one surface must NOT zero out the others -----------
# (a non-object element, and an object whose author/user is a bare string)
cat > "$T/malformed.json" <<'EOF'
{
  "issue_comments":[
    "Not Found",
    {"author":{"login":"cursor[bot]"},"body":"real finding","url":"https://github.com/o/r/pull/1#ic-m","createdAt":"2026-07-10T10:00:00Z"}
  ],
  "review_comments":[
    {"user":"malformed-string-user","body":"junk","path":"a","line":1,"html_url":"https://github.com/o/r/pull/1#rc-m","created_at":"t"},
    {"user":{"login":"coderabbitai[bot]","type":"Bot"},"body":"real inline","path":"b.ts","line":9,"html_url":"https://github.com/o/r/pull/1#rc-n","created_at":"t"}
  ],
  "reviews":[]
}
EOF
mout="$(run "$T/malformed.json")"
expect "malformed element does not poison result" "$(printf '%s' "$mout" | jq -e 'type=="array"' >/dev/null 2>&1; echo $?)" "0"
expect "valid bots survive a bad sibling element"  "$(printf '%s' "$mout" | jq 'length')" "2"
expect "cursor[bot] survived bad issue element"    "$(printf '%s' "$mout" | jq '[.[]|select(.author=="cursor[bot]")]|length')" "1"
expect "coderabbit survived bad review element"    "$(printf '%s' "$mout" | jq '[.[]|select(.author=="coderabbitai[bot]")]|length')" "1"

# --- fail-open: always a valid [] --------------------------------------------
expect "missing file -> []"  "$(bash "$SH" --json-file "$T/nope.json")" "[]"
printf '%s' 'not json {{{' > "$T/bad.json"
expect "bad json -> []"      "$(run "$T/bad.json")" "[]"
printf '%s' '{"issue_comments":[],"review_comments":[],"reviews":[]}' > "$T/empty.json"
expect "empty surfaces -> []" "$(run "$T/empty.json")" "[]"
printf '%s' '{"issue_comments":[{"author":{"login":"human1"},"body":"hi","url":"u1","createdAt":"t"}],"review_comments":[],"reviews":[]}' > "$T/humans.json"
expect "only humans -> []"    "$(run "$T/humans.json")" "[]"

# output is always valid JSON array
expect "output parses as array (mixed)" "$(printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1; echo $?)" "0"

echo "-------------------------------------------------"
printf 'pr-bot-comments.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
