#!/usr/bin/env bash
# auto-task-resume-list.sh — read-only enumerator of auto-task runs across worktrees.
#
# NOT a hook. A standalone tool (wrapped by the auto-task-resume skill, and read by
# the core auto-task skill's no-args resume path) that answers: "which auto-task
# runs exist on this clone, and what state is each in?" so a run can be resumed
# without knowing which worktree/branch it lives in.
#
# WHY IT EXISTS: an auto-task run lives in its own git worktree keyed to a branch
# (.auto-task/<branch>/STATE.json inside that worktree). `claude --resume` resumes
# a conversation, not a run, and bare `/auto-task` only sees the current branch's
# state — so runs in other worktrees are invisible. This engine makes them visible.
#
# ENUMERATION: a run is marked by a STATE.json file — NEVER by a bare worktree.
# We scan every `git worktree list` path (incl. the main tree) for
# .auto-task/**/STATE.json, de-duplicated by absolute path. A worktree with no
# STATE.json is never surfaced as a run.
#
# ROBUSTNESS: every STATE.json is parsed defensively. Missing/renamed fields fall
# back to explicit nulls (schema drift is tolerated); a genuinely unparseable /
# truncated file yields a degraded row (parse_ok:false, all keys present as null,
# resumable:false) rather than a crash. Fail-open: exit 0 always.
#
# MODES:
#   auto-task-resume-list.sh                human table (default)
#   auto-task-resume-list.sh --json         JSON array of run objects
#   auto-task-resume-list.sh --resume-mode  one of: none | direct | picker
#                                           (the bare-/auto-task no-args decision)
#   -h | --help                             this header
#
# Each --json run object carries the FULL key set (explicit null when unknown):
#   phase title description branch worktree worktree_present is_current resumable
#   effort last_activity last_activity_ts pr_url state_path parse_ok
# Sorted most-recent-first by last_activity_ts.
#
# resumable      = phase != "done" AND the file parsed (an unknown-state run is
#                  not offered for resume).
# is_current     = the run's branch == the branch checked out in the invoking
#                  worktree (NOT merely the worktree its STATE.json sits in).
# worktree_present = the run's branch still has a live worktree (false = orphan:
#                  main-tree/residual state whose worktree was pruned).
#
# Test seams: AUTO_TASK_NOW (epoch, for deterministic relative ages).
# Exit 0 always (read-only; nothing to fail closed on).

set -uo pipefail

MODE="table"
for a in "$@"; do
  case "$a" in
    --json)        MODE="json" ;;
    --resume-mode) MODE="resume-mode" ;;
    -h|--help)     grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "auto-task-resume-list: unknown arg '$a' (use --json | --resume-mode)" >&2 ;;
  esac
done

# Diagnostics go to stderr so the --json / --resume-mode stdout sentinel stays
# clean (a caller capturing $(... --json) must not receive a prose line too).
command -v jq  >/dev/null 2>&1 || { echo "auto-task-resume-list: jq is not installed (a hard prerequisite of this plugin)." >&2; [ "$MODE" = json ] && echo "[]"; [ "$MODE" = resume-mode ] && echo "none"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "auto-task-resume-list: not a git environment." >&2; [ "$MODE" = json ] && echo "[]"; [ "$MODE" = resume-mode ] && echo "none"; exit 0; }
git rev-parse --git-common-dir >/dev/null 2>&1 || { echo "auto-task-resume-list: not in a git repo." >&2; [ "$MODE" = json ] && echo "[]"; [ "$MODE" = resume-mode ] && echo "none"; exit 0; }

now="${AUTO_TASK_NOW:-$(date +%s 2>/dev/null || echo 0)}"; case "$now" in ''|*[!0-9]*) now=0 ;; esac
cur_top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$cur_top" ] && cur_top="$(cd "$cur_top" 2>/dev/null && pwd -P || true)"

# --- worktree inventory: paths + their branches (porcelain) ------------------
# wt_paths[] parallel to wt_branches[]; wt_branch_set for membership tests.
wt_paths=(); wt_branches=(); wt_branch_set=" "
_p=""; _b=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*) _p="${line#worktree }" ;;
    "branch "*)   _b="${line#branch }"; _b="${_b#refs/heads/}" ;;
    "detached")   _b="" ;;
    "")  # end of a record
        if [ -n "$_p" ]; then
          _pp="$(cd "$_p" 2>/dev/null && pwd -P || echo "$_p")"
          wt_paths+=("$_pp"); wt_branches+=("$_b")
          [ -n "$_b" ] && wt_branch_set="${wt_branch_set}${_b} "
        fi
        _p=""; _b="" ;;
  esac
done < <(git worktree list --porcelain 2>/dev/null; echo)

branch_has_worktree() { case "$wt_branch_set" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# The current branch = the branch checked out in the invoking worktree (cur_top).
# is_current keys off THIS, not the worktree a run's STATE.json physically sits in
# — otherwise a residual/in-place run for another branch, living in the main tree,
# would be misread as "the run I'm in" when invoked from the main tree, and be
# excluded from both the picker and direct-resume (stranded). Empty if detached.
current_branch=""
_i=0
for p in ${wt_paths[@]+"${wt_paths[@]}"}; do
  [ "$p" = "$cur_top" ] && { current_branch="${wt_branches[$_i]}"; break; }
  _i=$((_i+1))
done

# --- collect STATE.json files across every worktree path (dedup by abs path) --
declare -a STATE_FILES=()
seen=" "
for p in ${wt_paths[@]+"${wt_paths[@]}"}; do
  [ -d "$p/.auto-task" ] || continue
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    af="$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)/$(basename "$f")"
    case "$seen" in *" $af "*) continue ;; esac
    seen="${seen}${af} "
    STATE_FILES+=("$af")
  done < <(find "$p/.auto-task" -maxdepth 4 -name STATE.json 2>/dev/null)
done

# --- build one JSON object per run -------------------------------------------
# humanage + object assembly live in jq so keys are always present with nulls.
JQ_OBJ='
  def humanage($d):
    if $d < 60 then "just now"
    elif $d < 3600 then "\(($d/60)|floor)m ago"
    elif $d < 86400 then "\(($d/3600)|floor)h ago"
    else "\(($d/86400)|floor)d ago" end;
  . as $s
  # type-guarded against schema drift: history may not be an array, an entry may
  # be a scalar (no .at), effort may be a string not an object — none of these
  # valid-but-drifted shapes may error the program (that would wrongly degrade
  # the whole row). `?` suppresses index-on-wrong-type; guards keep it total.
  | (($s.history // []) | (if type=="array" then . else [] end) | map(.at? // empty)) as $ats
  | (($ats | last) // null) as $lastat
  | ((($lastat | fromdateiso8601?) // $mtime) | floor) as $lts
  # String leaves are coerced to string-or-null via jq strings (passes only
  # string values), so every scalar field is a string or null. This keeps the
  # table @tsv consumer from aborting on a non-scalar leaf: a valid but drifted
  # STATE.json with e.g. effort:{tier:[...]} or a non-string title would
  # otherwise poison @tsv and silently drop healthy rows from the table.
  | {
      phase:            (($s.phase | strings) // null),
      title:            (($s.title | strings) // null),
      description:      (($s.description | strings | .[0:120]) // null),
      branch:           (($s.branch | strings) // $bfp),
      worktree:         $wt,
      worktree_present: $wtp,
      is_current:       $cur,
      resumable:        ((($s.phase | strings) // "done") != "done"),
      effort:           (($s.effort.tier? | strings) // null),
      last_activity:    humanage(($now - $lts)),
      last_activity_ts: $lts,
      pr_url:           ($s.pr_url // null),
      state_path:       $sp,
      parse_ok:         true
    }'

objs=""
for f in ${STATE_FILES[@]+"${STATE_FILES[@]}"}; do
  # which worktree path owns this file? (longest matching prefix)
  owner="$cur_top"; best=0
  for p in ${wt_paths[@]+"${wt_paths[@]}"}; do
    case "$f" in "$p"/*) if [ "${#p}" -gt "$best" ]; then best="${#p}"; owner="$p"; fi ;; esac
  done
  # branch from path: strip "<owner>/.auto-task/" and "/STATE.json"
  rel="${f#"$owner"/.auto-task/}"; bfp="${rel%/STATE.json}"
  # parsed branch (fallback bfp), and whether that branch has a live worktree
  sbranch="$(jq -r '.branch // empty' "$f" 2>/dev/null)"; [ -n "$sbranch" ] || sbranch="$bfp"
  if branch_has_worktree "$sbranch"; then wtp="true"; else wtp="false"; fi
  # is_current: this run's branch == the branch checked out where we were invoked.
  if [ -n "$current_branch" ] && [ "$sbranch" = "$current_branch" ]; then cur="true"; else cur="false"; fi
  # mtime: GNU-first (`stat -c %Y`), then BSD (`stat -f %m`). GNU-first is
  # deliberate — on GNU/Linux `stat -f %m` selects *filesystem* mode where %m is
  # not a valid directive yet the statfs SUCCEEDS (exit 0) printing garbage, so a
  # BSD-first order would never fall through on Linux and yield a non-numeric
  # mtime. On macOS `stat -c` is rejected (exit 1) and falls through to `-f %m`.
  # The numeric guard is the real backstop: mtime is the only shell->--argjson
  # value fed to jq, and a non-numeric one aborts the jq (invalid --argjson) and
  # drops the whole run. Sanitize exactly like `now` above.
  mtime="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now")"
  case "$mtime" in ''|*[!0-9]*) mtime="$now" ;; esac

  obj="$(jq -c \
    --argjson now "$now" --argjson mtime "$mtime" --argjson cur "$cur" \
    --argjson wtp "$wtp" --arg wt "$owner" --arg bfp "$bfp" --arg sp "$f" \
    "$JQ_OBJ" "$f" 2>/dev/null)"

  if [ -z "$obj" ]; then
    # degraded: unparseable/truncated STATE.json — full key set, explicit nulls.
    obj="$(jq -cn \
      --argjson mtime "$mtime" --argjson now "$now" --argjson cur "$cur" \
      --argjson wtp "$wtp" --arg wt "$owner" --arg bfp "$bfp" --arg sp "$f" '
      {
        phase:null, title:null, description:null, branch:$bfp, worktree:$wt,
        worktree_present:$wtp, is_current:$cur, resumable:false, effort:null,
        last_activity:(if ($now-$mtime) < 86400 then "\((($now-$mtime)/3600)|floor)h ago" else "\((($now-$mtime)/86400)|floor)d ago" end),
        last_activity_ts:$mtime, pr_url:null, state_path:$sp, parse_ok:false
      }')"
  fi
  objs="${objs}${obj}"$'\n'
done

RUNS="$(printf '%s' "$objs" | jq -s 'sort_by(-.last_activity_ts)' 2>/dev/null)"
[ -n "$RUNS" ] || RUNS="[]"

# --- output per mode ----------------------------------------------------------
if [ "$MODE" = "json" ]; then
  printf '%s\n' "$RUNS"
  exit 0
fi

if [ "$MODE" = "resume-mode" ]; then
  # The current worktree's OWN resumable run wins: if you're sitting in a run,
  # `/auto-task` should continue IT, not pop a picker. Only when the current
  # location has no resumable run do we consider others. This precedence is also
  # what makes the picker hand-off terminate: auto-task-resume enters the chosen
  # worktree then re-invokes `/auto-task`, which now sees curr>0 -> direct and
  # resumes, instead of re-computing picker (others still exist) and looping.
  curr=$(printf '%s'  "$RUNS" | jq '[.[] | select(.resumable and .is_current)] | length')
  other=$(printf '%s' "$RUNS" | jq '[.[] | select(.resumable and (.is_current|not))] | length')
  if   [ "${curr:-0}"  -gt 0 ]; then echo "direct"
  elif [ "${other:-0}" -gt 0 ]; then echo "picker"
  else echo "none"; fi
  exit 0
fi

# --- human table --------------------------------------------------------------
reponame="$(basename "$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd -P)")" 2>/dev/null)"
total=$(printf '%s' "$RUNS" | jq 'length')
line="  ────────────────────────────────────────────────────────────────────────"
echo
echo "  auto-task runs — ${reponame:-repo}  (${total} found)"
echo "$line"
if [ "${total:-0}" -eq 0 ]; then
  echo "   No auto-task runs found on this clone."
  echo "$line"
  echo "   Start one with:  /auto-task <description>"
  echo
  exit 0
fi
printf '   %-3s %-1s %-11s %-38s %-7s %-9s %s\n' "#" "" "STATE" "TITLE" "EFFORT" "LAST" ""
echo "$line"
# emit numbered data rows (regex-stable: each starts with "  N) ")
i=0
# Fields are joined with the unit separator (0x1f), NOT a tab: `read` treats tab
# as IFS-whitespace and would strip/collapse empty leading/middle fields (a
# drifted or degraded row has empty phase/title/effort), shifting every later
# column into the wrong variable. A non-whitespace IFS preserves empty fields
# and never merges consecutive delimiters. The jq side gsubs any newline/CR/0x1f
# out of the values so no field can break the line or fake a delimiter.
while IFS=$'\037' read -r phase title effort last resumable is_cur wt_present parse_ok; do
  i=$((i+1))
  if [ "$parse_ok" = "false" ]; then glyph="⚠"; state="unreadable"
  elif [ "$resumable" = "false" ]; then glyph="○"; state="${phase:-done}"
  else glyph="●"; state="${phase:-?}"; fi
  # markers
  mark=""
  [ "$is_cur" = "true" ] && mark="${mark} · current"
  [ "$wt_present" = "false" ] && mark="${mark} · orphan"
  ttl="${title:-(untitled)}"; [ "${#ttl}" -gt 38 ] && ttl="${ttl:0:37}…"
  printf '  %2d) %s %-11s %-38s %-7s %-9s%s\n' "$i" "$glyph" "$state" "$ttl" "${effort:-–}" "${last:-–}" "$mark"
done < <(printf '%s' "$RUNS" | jq -r '.[] | [(.phase//""),(.title//""),(.effort//""),(.last_activity//""),(.resumable|tostring),(.is_current|tostring),(.worktree_present|tostring),(.parse_ok|tostring)] | map(gsub("[\r\n\u001f]";" ")) | join("\u001f")')
echo "$line"
echo "  ● resumable   ○ done   ⚠ unreadable    markers: · current (you're here) · orphan (worktree pruned)"
echo
exit 0
