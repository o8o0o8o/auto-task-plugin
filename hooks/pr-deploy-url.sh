#!/usr/bin/env bash
# pr-deploy-url.sh — find a preview/deployment URL in a PR's comments + body.
#
# The common CI pattern: a deploy bot (Vercel, Netlify, Cloudflare Pages, Render,
# Fly, Railway, …) posts a PR comment (or edits the PR body) with the preview URL.
# This extracts the FIRST such URL so Phase-6 preview verification can run
# out-of-the-box, with NO project settings, on any repo whose PRs get a deploy
# comment. The orchestrator calls this repeatedly to POLL (bots take a minute).
#
# Resolution: `gh pr view <ref> --json comments,body,url` → scan the PR body and
# every comment body for an https URL whose host matches a known preview-host
# suffix (or a caller-supplied one). Bot-authored comments are preferred, and
# among matches the MOST RECENT comment wins (bots update the URL per push).
#
# Failure policy: FAIL OPEN. No `gh` / not authenticated / no PR / no match →
# print nothing, exit 0. Never blocks or errors the caller.
#
# Usage:  pr-deploy-url.sh [--ref <branch|pr-number|url>] [--hosts "a.com b.net"]
#   --ref    which PR (default: current branch's PR).
#   --hosts  extra space-separated host suffixes to accept, in addition to the
#            built-in list (e.g. a company preview domain).
# Prints:  one URL on success, nothing otherwise.

set -uo pipefail

ref=""; extra_hosts=""; json_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ref)       ref="${2:-}"; shift 2 || shift ;;
    --hosts)     extra_hosts="${2:-}"; shift 2 || shift ;;
    --json-file) json_file="${2:-}"; shift 2 || shift ;;  # test hook: PR JSON from a file, skip gh
    *) shift ;;
  esac
done

command -v jq >/dev/null 2>&1 || exit 0

# Built-in preview host suffixes (extend via --hosts or preview settings).
default_hosts="vercel.app netlify.app pages.dev onrender.com fly.dev up.railway.app railway.app web.app firebaseapp.com deno.dev surge.sh ngrok-free.app trycloudflare.com github.io herokuapp.com"
hosts="$default_hosts $extra_hosts"

# Fetch the PR body + comments (most-recent last). `gh pr view` with no ref uses
# the current branch's PR. Any failure → fail-open empty. A --json-file override
# (test hook) supplies the same JSON shape without touching gh/network.
if [ -n "$json_file" ]; then
  [ -f "$json_file" ] || exit 0
  pr_json="$(cat "$json_file" 2>/dev/null || true)"
else
  command -v gh >/dev/null 2>&1 || exit 0
  gh auth status >/dev/null 2>&1 || exit 0   # must be authenticated; else fail-open
  pr_json="$(gh pr view $ref --json comments,body 2>/dev/null || true)"
fi
[ -n "$pr_json" ] || exit 0
printf '%s' "$pr_json" | jq empty 2>/dev/null || exit 0

# Build a newline-separated list of candidate text blocks, MOST RECENT FIRST:
# bot comments first (reverse chronological), then all comments, then the body.
# We just concatenate reverse-chronological comment bodies + the PR body; the
# first matching URL in that order wins.
texts="$(printf '%s' "$pr_json" | jq -r '
  ( .comments // [] | reverse | .[]?.body ),
  ( .body // "" )
' 2>/dev/null || true)"
[ -n "$texts" ] || exit 0

# Extract https URLs and return the first whose host ends in a known suffix.
# (grep out URLs, then match against the host list.)
# NOTE: parentheses are deliberately EXCLUDED from the URL char class so a
# markdown link `[x](https://host)` terminates the URL at the closing paren.
urls="$(printf '%s\n' "$texts" | grep -oE 'https://[A-Za-z0-9._~:/?#@!$&*+,;=%-]+' 2>/dev/null || true)"
[ -n "$urls" ] || exit 0

while IFS= read -r u; do
  [ -n "$u" ] || continue
  # strip to host
  host="$(printf '%s' "$u" | sed -E 's#^https://##; s#[/?#].*$##; s#:.*$##')"
  for suf in $hosts; do
    case "$host" in
      "$suf"|*."$suf")
        # strip a trailing ) . , ] that often follows a URL in markdown
        printf '%s\n' "$u" | sed -E 's#[).,\]]+$##'
        exit 0 ;;
    esac
  done
done <<EOF
$urls
EOF

exit 0
