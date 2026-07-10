#!/usr/bin/env bash
# pr-bot-comments.sh — collect review comments left by BOTS (Cursor, CodeRabbit,
# Sourcery, GitHub Copilot review, …) on a PR, so the auto-task Phase-6
# bot-comment review can triage + conservatively fix them.
#
# It fetches THREE comment surfaces and merges them into one normalized,
# de-duplicated JSON array (most recent first is not guaranteed — order follows
# the fetch order; callers should not rely on ordering):
#   1. issue-level PR comments   (`gh pr view --json comments`)
#   2. inline review-thread comments, with file/line
#                                (`gh api repos/{o}/{r}/pulls/{n}/comments`)
#   3. review summaries with a body
#                                (`gh api repos/{o}/{r}/pulls/{n}/reviews`)
#
# "Bot" = a comment whose author login ends in `[bot]`, OR whose GitHub account
# `type == "Bot"` (available on the REST surfaces), OR whose login is in the
# built-in known list, OR in a caller-supplied `--bots` list.
#
# Output: a JSON array `[{author,path,line,body,url,created_at}]`. ALWAYS a valid
# JSON array — `[]` when nothing matches or on ANY failure (no `gh`, not
# authenticated, no PR, bad JSON). Never blocks or errors the caller (exit 0).
#
# Usage:  pr-bot-comments.sh [--ref <branch|pr-number|url>] [--bots "a[bot] b[bot]"]
#   --ref    which PR (default: current branch's PR).
#   --bots   extra bot logins to treat as bots, space/comma separated.
#   --json-file <f>  test hook: read a combined fixture instead of calling gh.
#            Fixture shape: {"issue_comments":[…gh pr-view shape…],
#                            "review_comments":[…REST pulls/comments shape…],
#                            "reviews":[…REST pulls/reviews shape…]}

set -uo pipefail

ref=""; extra_bots=""; json_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ref)       ref="${2:-}"; shift 2 || shift ;;
    --bots)      extra_bots="${2:-}"; shift 2 || shift ;;
    --json-file) json_file="${2:-}"; shift 2 || shift ;;
    *) shift ;;
  esac
done

# jq is a hard prerequisite of the plugin; without it, fail-open with an empty set.
command -v jq >/dev/null 2>&1 || { printf '[]\n'; exit 0; }

# Built-in known bot logins (backstop; the `[bot]` suffix + type=="Bot" catch most).
known_bots="cursor[bot] coderabbitai[bot] sourcery-ai[bot] github-actions[bot] copilot-pull-request-reviewer[bot] github-advanced-security[bot] deepsource-autofix[bot] codium-ai[bot] sonarcloud[bot] coderabbit[bot] devin-ai-integration[bot] greptile-apps[bot] ellipsis-dev[bot]"

# Normalize the caller-supplied extras: allow comma OR space separation.
extra_bots="$(printf '%s' "$extra_bots" | tr ',' ' ')"

# --- Assemble the combined fixture ------------------------------------------
# Either from the test hook (--json-file) or from live gh calls. Both produce the
# same {issue_comments,review_comments,reviews} shape fed to the jq normalizer.
if [ -n "$json_file" ]; then
  [ -f "$json_file" ] || { printf '[]\n'; exit 0; }
  combined="$(cat "$json_file" 2>/dev/null || true)"
else
  command -v gh >/dev/null 2>&1 || { printf '[]\n'; exit 0; }
  gh auth status >/dev/null 2>&1 || { printf '[]\n'; exit 0; }

  pr_view="$(gh pr view $ref --json number,url,comments 2>/dev/null || true)"
  [ -n "$pr_view" ] || { printf '[]\n'; exit 0; }
  printf '%s' "$pr_view" | jq empty 2>/dev/null || { printf '[]\n'; exit 0; }

  number="$(printf '%s' "$pr_view" | jq -r '.number // empty' 2>/dev/null || true)"
  url="$(printf '%s' "$pr_view" | jq -r '.url // empty' 2>/dev/null || true)"
  issue_comments="$(printf '%s' "$pr_view" | jq -c '.comments // []' 2>/dev/null || echo '[]')"

  # owner/repo from the PR url (works for github.com and GHE); fall back to gh.
  nwo="$(printf '%s' "$url" | sed -nE 's#^https?://[^/]+/([^/]+/[^/]+)/pull/.*$#\1#p')"
  [ -n "$nwo" ] || nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"

  # Fetch the paginated array endpoints. `gh api --paginate` emits ONE array PER
  # PAGE (concatenated: `[…]\n[…]`) once a PR has >30 comments/reviews — NOT a
  # single merged array — so we stream each element with `-q '.[]'` and re-slurp
  # into one array with `jq -s '.'`. This is robust to 0, 1, or N pages (empty
  # stream → `[]`). Doing the naive capture-then-argjson would reject the
  # multi-value string and silently drop every bot comment on a busy PR.
  review_comments='[]'; reviews='[]'
  if [ -n "$nwo" ] && [ -n "$number" ]; then
    rc="$(gh api "repos/$nwo/pulls/$number/comments" --paginate -q '.[]' 2>/dev/null | jq -s '.' 2>/dev/null || true)"
    printf '%s' "$rc" | jq -e 'type=="array"' >/dev/null 2>&1 && review_comments="$rc"
    rv="$(gh api "repos/$nwo/pulls/$number/reviews" --paginate -q '.[]' 2>/dev/null | jq -s '.' 2>/dev/null || true)"
    printf '%s' "$rv" | jq -e 'type=="array"' >/dev/null 2>&1 && reviews="$rv"
  fi

  combined="$(jq -n \
    --argjson ic "$issue_comments" \
    --argjson rc "$review_comments" \
    --argjson rv "$reviews" \
    '{issue_comments:$ic, review_comments:$rc, reviews:$rv}' 2>/dev/null || echo '{}')"
fi

[ -n "$combined" ] || { printf '[]\n'; exit 0; }
printf '%s' "$combined" | jq empty 2>/dev/null || { printf '[]\n'; exit 0; }

# --- Normalize → filter to bots → de-duplicate → emit ------------------------
printf '%s' "$combined" | jq -c \
  --arg known "$known_bots" \
  --arg extra "$extra_bots" \
  '
  ($known + " " + $extra | ascii_downcase | split(" ") | map(select(length>0))) as $botlist |

  # Each surface element is guarded with select(type=="object") (skip a bare
  # string/number/array element) and nested access uses ? (tolerate an object
  # whose .author/.user is not itself an object). A malformed element in ONE
  # surface must degrade to skipping that element, NOT poison the whole program
  # (which the trailing || [] would then collapse to [], silently dropping the
  # valid findings from the healthy surfaces).
  def norm:
    [ ( (.issue_comments // [])[] | select(type=="object")
        | { author:(.author.login? // ""), type:"",
            path:null, line:null,
            body:(.body? // ""), url:(.url? // ""), created_at:(.createdAt? // "") } ),
      ( (.review_comments // [])[] | select(type=="object")
        | { author:(.user.login? // ""), type:(.user.type? // ""),
            path:(.path? // null), line:(.line? // .original_line? // null),
            body:(.body? // ""), url:(.html_url? // ""), created_at:(.created_at? // "") } ),
      ( (.reviews // [])[] | select(type=="object")
        | select((.body? // "") != "")
        | { author:(.user.login? // ""), type:(.user.type? // ""),
            path:null, line:null,
            body:(.body? // ""), url:(.html_url? // ""), created_at:(.submitted_at? // "") } ) ];

  def is_bot:
    (.author | ascii_downcase) as $a
    | ((.author | test("\\[bot\\]$"))
       or (.type == "Bot")
       or (($botlist | index($a)) != null));

  def dkey:
    if (.url // "") != "" then .url
    else (.author + "|" + (.path // "") + "|" + ((.line // "")|tostring) + "|"
          + ((.body // "") | gsub("\\s+";" ") | ascii_downcase)) end;

  ( norm | map(select(is_bot)) ) as $bots |
  ( reduce $bots[] as $x ({seen:{}, out:[]};
      ($x | dkey) as $k
      | if .seen[$k] then . else {seen:(.seen + {($k):true}), out:(.out + [$x])} end
    ) | .out )
  | map({author, path, line, body, url, created_at})
  ' 2>/dev/null || printf '[]\n'

exit 0
