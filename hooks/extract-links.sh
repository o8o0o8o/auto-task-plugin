#!/usr/bin/env bash
# extract-links.sh — extract + classify links from an auto-task task description.
#
# NOT a hook. A pure, deterministic helper (invoked by the auto-task orchestrator
# in Phase 1 reconnaissance) that scans the task description text for URLs and
# prints a JSON array classifying each link by KIND and the recon STRATEGY to
# apply. The orchestrator uses it as a mechanical ASSIST to build its recon
# target list; the model still reads the description directly for scheme-less /
# bare-host references this helper deliberately defers (see below).
#
# For each unique URL (in first-occurrence order) one object is emitted:
#   {"url":"..","host":"..","kind":"..","strategy":".."}
#
# KIND / STRATEGY (host matched case-insensitively):
#   video : loom, youtube/youtu.be, vimeo, wistia
#           -> "playwright: screenshots + transcript"
#   figma : figma.com
#           -> "figma mcp (load figma-use first)"
#   doc   : notion.so, docs/drive.google.com, *.slack.com, linear.app,
#           *.atlassian.net
#           -> "mcp if available, else fetch->playwright fallback"
#   page  : any other http(s) URL
#           -> "fetch->playwright fallback"
#
# The two-tier idea ("try an ordinary fetch first, fall back to Playwright when
# there is no usable data") lives in the recon PROSE; this helper only labels
# each link with which strategy the model should run.
#
# URL NORMALIZATION: markdown links `[label](url)` and angle-bracket `<url>` are
# unwrapped; trailing sentence punctuation (.,;:!?) and unbalanced wrappers
# )]>"' are stripped; `www.`-prefixed scheme-less URLs are promoted to https.
# Bare scheme-less hosts WITHOUT `www.` (e.g. `loom.com/x`) are intentionally NOT
# extracted — a `word.word/…` heuristic produces too many false positives; the
# recon prose makes the model responsible for eyeballing those.
#
# Failure policy: FAIL OPEN. No input, no URLs, unknown flags, or unusable input
# -> prints `[]` and exits 0. jq NOT required (JSON built with printf, values
# JSON-escaped). bash 3.2-safe (macOS default): no mapfile, no associative
# arrays, set -u guarded.
#
# Usage:
#   extract-links.sh --text "see https://www.loom.com/share/abc and https://x.com"
#   echo "$DESCRIPTION" | extract-links.sh
# Output (one line): a JSON array of {url,host,kind,strategy}.

set -uo pipefail
set -f   # disable pathname expansion: URL tokens are split unquoted below and
         # must never be glob-expanded against the CWD (keeps output deterministic)

text=""
have_text=0
while [ $# -gt 0 ]; do
  case "$1" in
    --text) text="${2:-}"; have_text=1; shift 2 || shift ;;
    *) shift ;;   # ignore unknown args (fail-open)
  esac
done

# No --text -> read stdin (if any). Never blocks: only reads when stdin is a pipe
# or file, and an empty read is fine (yields []).
if [ "$have_text" -eq 0 ]; then
  if [ ! -t 0 ]; then
    text="$(cat 2>/dev/null || true)"
  fi
fi

emit_empty(){ printf '[]\n'; exit 0; }

[ -n "$text" ] || emit_empty

# --- Tokenize on whitespace and on markdown/wrapper delimiters ----------------
# Replace the delimiters that wrap URLs — ()[]<> and quotes — with spaces so a
# markdown link `[t](url)` or `<url>` yields a bare token. Then iterate tokens.
scrubbed="$(printf '%s' "$text" | tr '()[]<>"'"'" '        ' | tr '\t\n\r' '   ')"

# JSON-escape a string (backslash, doublequote, control chars).
json_escape(){
  # shellcheck disable=SC2001
  s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# lowercase helper (bash 3.2 has no ${x,,})
lc(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Classify a lowercased host -> "kind|strategy". Patterns are dot-anchored:
# each host matches the apex exactly (`loom.com`) OR a subdomain (`*.loom.com`),
# so `bloom.com` / `notyoutube.com` fall through to `page` rather than being
# swallowed by a bare-suffix `*loom.com`.
classify(){
  h="$1"
  case "$h" in
    loom.com|*.loom.com|youtube.com|*.youtube.com|youtu.be|*.youtu.be|vimeo.com|*.vimeo.com|wistia.com|*.wistia.com|wistia.net|*.wistia.net)
      printf 'video|playwright: screenshots + transcript' ;;
    figma.com|*.figma.com)
      printf 'figma|figma mcp (load figma-use first)' ;;
    notion.so|*.notion.so|docs.google.com|drive.google.com|*.slack.com|linear.app|*.linear.app|atlassian.net|*.atlassian.net)
      printf 'doc|mcp if available, else fetch->playwright fallback' ;;
    *)
      printf 'page|fetch->playwright fallback' ;;
  esac
}

# --- Walk tokens, collect normalized URLs in first-occurrence order -----------
seen=""     # newline-delimited list of URLs already emitted (dedupe)
out=""      # accumulated JSON objects, comma-separated
count=0

for tok in $scrubbed; do
  # Trim markdown emphasis / inline-code wrappers (` * _ ~) and trailing sentence
  # punctuation from the token EDGES only — a URL wrapped like `**https://x**`,
  # `` `https://x` ``, or `_https://x_` still parses. Edge-only trimming preserves
  # interior characters, so URLs with underscores/asterisks in the path/query are
  # unharmed (only rare, real trailing `_`/`*` chars are lost — same tradeoff as
  # the trailing-punctuation strip). Leading trim runs before the scheme check so
  # a leading wrapper doesn't hide the `http(s)://` / `www.` prefix.
  while :; do
    case "$tok" in
      [\`*_~]*) tok="${tok#?}" ;;
      *) break ;;
    esac
  done
  while :; do
    case "$tok" in
      *[.,\;:\!\?\`*_~]) tok="${tok%?}" ;;
      *) break ;;
    esac
  done
  # Promote www.-prefixed scheme-less tokens to https (case-insensitive prefix).
  case "$(lc "$tok")" in
    www.*)
      case "$tok" in
        http://*|https://*) : ;;
        *) tok="https://$tok" ;;
      esac ;;
  esac
  # Keep only http(s) URLs.
  case "$tok" in
    http://*|https://*) : ;;
    *) continue ;;
  esac
  url="$tok"
  # Must still have a host after the scheme.
  rest="${url#*://}"
  [ -n "$rest" ] || continue
  host="${rest%%/*}"
  host="${host%%\?*}"
  host="${host%%#*}"
  host="${host%%:*}"       # strip :port
  [ -n "$host" ] || continue
  # Host must look like a domain (contain a dot).
  case "$host" in *.*) : ;; *) continue ;; esac

  # Dedupe on the normalized URL, first-occurrence order preserved.
  case "$(printf '\n%s\n' "$seen")" in
    *"$(printf '\n%s\n' "$url")"*) continue ;;
  esac
  seen="$seen
$url"

  hl="$(lc "$host")"
  cs="$(classify "$hl")"
  kind="${cs%%|*}"
  strategy="${cs#*|}"

  ju="$(json_escape "$url")"
  jh="$(json_escape "$host")"
  jk="$(json_escape "$kind")"
  js="$(json_escape "$strategy")"

  obj="{\"url\":\"$ju\",\"host\":\"$jh\",\"kind\":\"$jk\",\"strategy\":\"$js\"}"
  if [ "$count" -eq 0 ]; then out="$obj"; else out="$out,$obj"; fi
  count=$((count+1))
done

[ "$count" -gt 0 ] || emit_empty
printf '[%s]\n' "$out"
exit 0
