#!/usr/bin/env bash
# Focused test for hooks/pr-deploy-url.sh — extract a deployment URL from a PR's
# comments/body. Uses the --json-file hook so it never touches gh/network.
#
# Asserts: known preview hosts (vercel/netlify/cloudflare/…) are matched; the
# most-recent comment wins; markdown links + trailing emoji/punctuation are
# stripped; non-deploy URLs are ignored; --hosts extends the suffix list; and
# fail-open (missing file / bad JSON / no match) prints nothing, exit 0.
#
# Usage: tests/pr-deploy-url.test.sh   Exit 0 = all passed.

set -uo pipefail

SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/pr-deploy-url.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[ -f "$SH" ] || { echo "FAIL: $SH missing"; exit 1; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-48s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-48s got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }
run(){ bash "$SH" --json-file "$1" ${2:+--hosts "$2"}; }

echo "================ pr-deploy-url.sh ================"
bash -n "$SH"; expect "bash -n clean" "$?" "0"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

printf '%s' '{"body":"desc","comments":[{"author":{"login":"a"},"body":"hi"},{"author":{"login":"vercel[bot]"},"body":"Preview: https://app-git-feat.vercel.app 🎉"}]}' > "$T/v.json"
expect "vercel comment"        "$(run "$T/v.json")" "https://app-git-feat.vercel.app"

printf '%s' '{"body":"Deploy preview [ready](https://deploy-preview-12--site.netlify.app)","comments":[]}' > "$T/n.json"
expect "netlify markdown body" "$(run "$T/n.json")" "https://deploy-preview-12--site.netlify.app"

printf '%s' '{"body":"","comments":[{"body":"https://my-proj.pages.dev/"}]}' > "$T/cf.json"
expect "cloudflare pages"      "$(run "$T/cf.json")" "https://my-proj.pages.dev/"

# most-recent comment wins (last in the array is newest)
printf '%s' '{"body":"","comments":[{"body":"https://old-abc.vercel.app"},{"body":"https://new-xyz.vercel.app"}]}' > "$T/recent.json"
expect "most-recent comment wins" "$(run "$T/recent.json")" "https://new-xyz.vercel.app"

# non-deploy URLs ignored
printf '%s' '{"body":"see https://github.com/x/y and https://example.com","comments":[]}' > "$T/no.json"
expect "non-deploy url ignored" "[$(run "$T/no.json")]" "[]"

# custom host only via --hosts
printf '%s' '{"body":"","comments":[{"body":"https://pr-9.preview.acme.internal/"}]}' > "$T/custom.json"
expect "custom host w/o --hosts" "[$(run "$T/custom.json")]" "[]"
expect "custom host w/ --hosts"  "$(run "$T/custom.json" "acme.internal")" "https://pr-9.preview.acme.internal/"

# fail-open
expect "missing file -> empty"  "[$(bash "$SH" --json-file /no/such.json)]" "[]"
expect "missing file exit 0"    "$(bash "$SH" --json-file /no/such.json >/dev/null 2>&1; echo $?)" "0"
printf 'not json' > "$T/bad.json"
expect "bad json -> empty"      "[$(run "$T/bad.json")]" "[]"

echo "pr-deploy-url.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
