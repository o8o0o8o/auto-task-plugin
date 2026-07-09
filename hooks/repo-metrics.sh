#!/usr/bin/env bash
# repo-metrics.sh — ANONYMOUS project-size + change-heat signals for telemetry.
#
# Emits a small JSON object of buckets/numbers derived from a repo + the run's
# base commit. Called by send-telemetry.sh (fail-open) and merged into the payload.
#
# ANONYMITY CONTRACT (load-bearing): this NEVER emits a path, file name, module
# name, language-specific identifier, or repo name — only coarse buckets and
# numbers that cannot be reconstructed back to a specific repo:
#   repo_files_bucket      "<100" | "100-1k" | "1k-10k" | "10k-100k" | ">100k"
#   primary_language       a coarse family from the dominant file extension
#                          (js|ts|py|go|rust|java|ruby|php|c|cpp|shell|other|"")
#   is_monorepo            bool heuristic (workspaces / apps+packages dirs)
#   churn_ratio            0..1 — fraction of THIS run's changed files that were
#                          changed in a PRIOR run on this clone (a "rework/heat"
#                          signal). Computed from a LOCAL history of changed paths
#                          kept in the git common dir; the paths NEVER leave.
#   hotspot_concentration  0..1 — share of changed lines in the single most-changed
#                          file (1 = one file dominated; low = spread out)
#   dirs_touched           count of distinct top-level dirs changed this run
#   max_depth              deepest path depth changed this run
#
# The local churn history lives at  <git-common-dir>/auto-task-churn.tsv  (per
# clone, shared across worktrees, uncommitted, never sent). Delete it to reset.
#
# Failure policy: FAIL OPEN. Any field that can't be computed is null; a total
# failure prints `{}` and exits 0. Never blocks or errors the caller.
#
# Usage: repo-metrics.sh --repo <dir> [--base <sha>]
# Test hook: AUTO_TASK_CHURN_FILE=<path> overrides the churn-history location.

set -uo pipefail

repo=""; base=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --base) base="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

emit_empty() { printf '{}\n'; exit 0; }

command -v jq >/dev/null 2>&1 || emit_empty
[ -n "$repo" ] && [ -d "$repo" ] || emit_empty
command -v git >/dev/null 2>&1 || emit_empty
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || emit_empty

# --- size: file count -> bucket ----------------------------------------------
files_total="$(git -C "$repo" ls-files 2>/dev/null | wc -l | tr -d ' ')"
[ -n "$files_total" ] || files_total=0
files_bucket=""
if   [ "$files_total" -lt 100 ]; then files_bucket="<100"
elif [ "$files_total" -lt 1000 ]; then files_bucket="100-1k"
elif [ "$files_total" -lt 10000 ]; then files_bucket="1k-10k"
elif [ "$files_total" -lt 100000 ]; then files_bucket="10k-100k"
else files_bucket=">100k"
fi

# --- primary language: dominant extension -> coarse family -------------------
top_ext="$(git -C "$repo" ls-files 2>/dev/null \
  | grep -oE '\.[A-Za-z0-9]+$' \
  | tr 'A-Z' 'a-z' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}' | tr -d '.')"
lang=""
case "$top_ext" in
  js|jsx|mjs|cjs)   lang="js" ;;
  ts|tsx)           lang="ts" ;;
  py)               lang="py" ;;
  go)               lang="go" ;;
  rs)               lang="rust" ;;
  java|kt)          lang="java" ;;
  rb)               lang="ruby" ;;
  php)              lang="php" ;;
  c|h)              lang="c" ;;
  cc|cpp|cxx|hpp)   lang="cpp" ;;
  sh|bash)          lang="shell" ;;
  "")               lang="" ;;
  *)                lang="other" ;;
esac

# --- monorepo heuristic ------------------------------------------------------
is_monorepo=false
if [ -f "$repo/pnpm-workspace.yaml" ] \
   || [ -d "$repo/packages" ] && [ -d "$repo/apps" ] \
   || git -C "$repo" ls-files 2>/dev/null | grep -qE '^(packages|apps)/[^/]+/(package\.json|Cargo\.toml|go\.mod)$'; then
  is_monorepo=true
fi

# --- change set (this run's commit vs base) ----------------------------------
# Numbers only; the paths are used locally for churn and then discarded.
changed=""
if [ -n "$base" ] && git -C "$repo" rev-parse -q --verify "$base" >/dev/null 2>&1; then
  changed="$(git -C "$repo" diff --name-only "$base" HEAD 2>/dev/null | grep -v '^\.auto-task/' || true)"
fi

churn_ratio="null"; concentration="null"; dirs_touched="null"; max_depth="null"
if [ -n "$changed" ]; then
  n_changed="$(printf '%s\n' "$changed" | grep -c . )"
  # dirs touched (distinct top-level segment) + max depth
  dirs_touched="$(printf '%s\n' "$changed" | sed 's#/.*##' | sort -u | grep -c . )"
  max_depth="$(printf '%s\n' "$changed" | awk -F/ '{print NF} END{}' | sort -rn | head -1)"
  [ -n "$max_depth" ] || max_depth="null"

  # --- churn ratio vs LOCAL history (paths never leave) ----------------------
  churn_file="${AUTO_TASK_CHURN_FILE:-}"
  if [ -z "$churn_file" ]; then
    common="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null || true)"
    if [ -n "$common" ]; then
      case "$common" in /*) : ;; *) common="$repo/$common" ;; esac
      churn_file="$common/auto-task-churn.tsv"
    fi
  fi
  if [ -n "$churn_file" ]; then
    seen=0
    if [ -f "$churn_file" ]; then
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        if grep -qxF "$p" "$churn_file" 2>/dev/null; then seen=$((seen+1)); fi
      done <<EOF
$changed
EOF
    fi
    if [ "$n_changed" -gt 0 ]; then
      churn_ratio="$(awk "BEGIN{printf \"%.3f\", $seen/$n_changed}")"
    fi
    # append this run's changed paths (dedup) to the local history
    { [ -f "$churn_file" ] && cat "$churn_file"; printf '%s\n' "$changed"; } 2>/dev/null \
      | grep -v '^$' | sort -u > "$churn_file.tmp" 2>/dev/null \
      && mv "$churn_file.tmp" "$churn_file" 2>/dev/null || true
  fi

  # --- hotspot concentration: biggest-file share of changed lines ------------
  numstat="$(git -C "$repo" diff --numstat "$base" HEAD 2>/dev/null | grep -v '	\.auto-task/' || true)"
  if [ -n "$numstat" ]; then
    concentration="$(printf '%s\n' "$numstat" | awk '
      { a=$1; b=$2; if (a=="-") a=0; if (b=="-") b=0; loc=a+b; tot+=loc; if (loc>mx) mx=loc }
      END { if (tot>0) printf "%.3f", mx/tot; else print "null" }')"
    [ -n "$concentration" ] || concentration="null"
  fi
fi

# --- assemble (numbers/buckets only) -----------------------------------------
jq -n \
  --arg fb "$files_bucket" \
  --arg lang "$lang" \
  --argjson mono "$is_monorepo" \
  --argjson churn "$churn_ratio" \
  --argjson conc "$concentration" \
  --argjson dirs "$dirs_touched" \
  --argjson depth "$max_depth" \
  '{
    repo_files_bucket: $fb,
    primary_language: $lang,
    is_monorepo: $mono,
    churn_ratio: $churn,
    hotspot_concentration: $conc,
    dirs_touched: $dirs,
    max_depth: $depth
  }' 2>/dev/null || emit_empty
