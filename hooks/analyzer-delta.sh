#!/usr/bin/env bash
# analyzer-delta.sh — hand the code review only the analyzer findings a run INTRODUCED.
#
# NOT a hook. A pure, deterministic helper (invoked by the auto-task orchestrator at
# Phase 4, before spawning the reviewer) that runs a static analyzer TWICE — once
# against the tree at <base>, once against the current tree — and reports the delta.
# Everything already broken in the repo appears on both sides and cancels.
#
# WHY TWO RUNS rather than a stored baseline: a baseline file goes stale, has to be
# regenerated, and becomes a second artifact to maintain. A delta recomputed from the
# two trees is correct by construction, and it absorbs analyzer-version drift for free
# — a new rule fires on BOTH sides and cancels (which is why the cache key below
# carries the analyzer version: a mid-run upgrade is the one case that does NOT cancel).
#
# WHY IDENTITY, NOT LINE NUMBERS: inserting N lines above a finding shifts every
# finding below it. A line-keyed set difference then reports all of them as new — a
# noise flood on exactly the change that touched the most code. So a finding is keyed
# on (file, position-stripped message): the line number never enters the key, the
# leading COLUMN is stripped (re-indenting a line moved it and churned the file), any
# remaining digits-only token collapses to `#`, and the path is made tree-relative so
# an absolute-path tool keys the same on both sides. `SC2086` survives intact, which is
# what still identifies the rule. Multiple occurrences of one rule in one file are
# distinguished by COUNT, not by position.
#
# THIS HELPER NEVER BLOCKS A RUN. Every failure path is `status:"skip"` with a stated
# reason and exit 0. Findings are ADVISORY input to Phase 4: severity comes from the
# tool, and the reachability grading that decides control flow stays with the
# orchestrator. There is no gate flag here and no `fail` row.
#
# FAIL OPEN, NEVER FAIL SILENT: every skip carries a non-empty `detail`. Fail-open
# keeps a run alive; a silent skip would make "the layer is off" indistinguishable
# from "nothing to report".
#
# KNOWN LIMIT — mutation detection is TRACKED-CONTENT ONLY. The check below hashes
# `git diff <base>`, which does not see untracked files. A linter that caches into the
# tree it scans (`.eslintcache`, `.ruff_cache`, `__pycache__`) therefore leaves those
# files in the live tree and the detector stays silent. That is deliberate rather than
# overlooked: such caches are conventionally gitignored, so they are invisible to
# `git ls-files --others --exclude-standard` too, and deleting a developer's cache
# files would be a destructive "fix" for a benign side effect. What matters — that the
# diff the commit gate hashes is unchanged — IS covered. Stated so a later reader does
# not mistake the narrow guarantee for a broad one.
#
# Usage:  analyzer-delta.sh --base <sha> [--cache <dir>]
# Output (one line): a JSON object; see emit_result() below.
#
# bash 3.2-safe (macOS default): no mapfile/readarray, no associative arrays, set -u
# guarded. jq NOT required for this script's own JSON (it is built with printf); the
# settings read below shells out to settings.sh, which uses jq and fails open without it.

set -uo pipefail

# Same reason checks.sh exports this: every `$p` handed to git here is a PATHSPEC, and
# git parses a leading `:` as pathspec MAGIC — so a file literally named `:leak.sh`
# would resolve to a nonexistent path and be silently skipped.
export GIT_LITERAL_PATHSPECS=1

base=""
cache=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base)  base="${2:-}"; shift 2 || shift ;;
    --cache) cache="${2:-}"; shift 2 || shift ;;
    *) shift ;;
  esac
done

# --- JSON emit (jq-free) ------------------------------------------------------
jesc(){ printf '%s' "${1:-}" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

emit_skip(){
  printf '{"analyzer":"%s","analyzer_source":"%s","status":"skip","base_source":null,' \
    "$(jesc "${ANALYZER_CMD:-}")" "$(jesc "${ANALYZER_SOURCE:-none}")"
  printf '"counts":{"base":0,"current":0,"introduced":0,"resolved":0},'
  printf '"introduced":[],"resolved":[],"detail":"%s"}\n' "$(jesc "$1")"
  exit 0
}

# --- Preconditions (all fail open) --------------------------------------------
ANALYZER_CMD=""
ANALYZER_SOURCE="none"
ANALYZER_ENUM=""

command -v git >/dev/null 2>&1 || emit_skip "git unavailable"
# perl is the timeout shim's only hard dependency (macOS has no timeout(1)). Unchecked,
# its absence surfaced as "the base tree could not be analyzed usefully" — fail-open
# held, but the stated reason named the wrong cause, which is the one thing a skip
# must never do.
command -v perl >/dev/null 2>&1 || emit_skip "perl unavailable - required for the analyzer timeout shim"
[ -n "$base" ] || emit_skip "no --base provided"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || emit_skip "not a git work tree"
git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 || emit_skip "base is not a commit"

# ONE canonicalisation rule, and every root that is compared against another goes through
# it. The identity key is built by stripping a root prefix from the analyzer's paths, and
# the base side's root derives from `$cache` while the current side's derives from the repo
# — so the two only cancel if they are spelled identically. THIS VALUE HAS NOW BROKEN THREE
# TIMES, once per spelling, and the suite was green after each fix:
#   1. relative vs absolute — a relative `--cache` left the base root relative
#   2. logical vs physical  — `cd … && pwd` keeps symlink components; git's toplevel does not
#   3. CDPATH               — the case below
# Each earlier fix addressed the spelling in front of it, which is why there was a next one.
# So this line is written to close the OPERAND-FORM AXIS rather than a third spelling, and
# each token earns its place:
#   `CDPATH=''` — a bare `cd` consults $CDPATH for any operand not starting with `/`, `./` or
#                `../`, and ECHOES the resolved directory to stdout when it matches. The
#                prescribed `--cache .auto-task/<branch>/artifacts` is exactly that operand
#                shape. Measured: `CDPATH=.` — an ordinary convenience setting — made this
#                function return a TWO-LINE value, and a decoy entry made it return the
#                WRONG directory. Both then became the slot path, i.e. awk's `root`.
#   `--`       — an operand beginning with `-` would otherwise parse as an option.
#   `pwd -P`   — physical, matching `git rev-parse --show-toplevel`. Measured divergence
#                `/…/sym/repo` vs `/…/real/repo`; on macOS `/tmp`, `/var` and `$TMPDIR` are
#                all symlinks, so this is the common case rather than the exotic one.
#   `[ -n … ]` — bash `cd ""` SUCCEEDS as a no-op, so an empty operand would otherwise
#                return rc=0 and the caller's cwd: a silent wrong answer from the one
#                function that exists to be the single source of truth.
# This is also the repo's existing convention (`hooks/settings.sh:215-219`, whose comment
# names this exact hazard — "mixing the two would otherwise split one clone across two
# keys"), followed by 13 other hooks.
canon_dir(){ [ -n "${1:-}" ] || return 1; ( CDPATH='' cd -- "$1" 2>/dev/null && pwd -P ) || return 1; }

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$repo_root" ] || emit_skip "cannot resolve repo root"
# DECORATIVE TODAY, and said plainly rather than implied: `git rev-parse --show-toplevel`
# already returns a physical path — it resists even `GIT_WORK_TREE=<symlink>`, measured — so
# removing this line leaves the suite green and changes no behaviour. It is kept so the
# invariant is "every compared root comes from canon_dir", which a reader can check by
# looking, rather than "one root happens to be canonical because of how git behaves", which
# they would have to know. No test pins it; that is recorded, not claimed otherwise.
repo_root="$(canon_dir "$repo_root")" || emit_skip "cannot resolve repo root"

# Default the cache beside the run's own state when the caller did not name one.
if [ -z "$cache" ]; then
  branch="$(git branch --show-current 2>/dev/null || true)"
  if [ -n "$branch" ] && [ -d "$repo_root/.auto-task/$branch" ]; then
    cache="$repo_root/.auto-task/$branch/artifacts"
  else
    cache="$repo_root/.auto-task/.analyzer-cache"
  fi
fi
mkdir -p "$cache" 2>/dev/null || emit_skip "cannot create cache dir: $cache"
# CANONICALISE IT, through the same rule as `repo_root` above — load-bearing, not tidiness.
# The base worktree slot is created inside `$cache`, and the slot path is what `scan_tree`
# hands awk as `root`: the prefix stripped from an absolute-path analyzer's findings so both
# sides key alike. Any spelling difference between this root and the repo root disjoints the
# two key spaces, and then every pre-existing finding reports as BOTH introduced and
# resolved with the slot path leaking into the payload. Two spellings have already done it,
# each measured on one fixture varying nothing but the cache form:
#   relative vs absolute  — absolute 0 introduced / 0 resolved, relative 1 / 1
#   logical vs physical   — plain 1 / 0, same dir via a symlink 2 / 1
# The first was reachable on the PRESCRIBED path (`phase-3-gates.md` documents
# `--cache .auto-task/<branch>/artifacts`, relative) while the built-in default above is
# absolute, which is why the default never showed it. The second is reachable wherever a
# path component is a symlink — on macOS that is `/tmp`, `/var` and `$TMPDIR`, so the test
# suite runs inside the hazard and still could not see it.
cache_arg="$cache"
cache="$(canon_dir "$cache")" || emit_skip "cannot resolve cache dir: $cache_arg"

# --- Settings (optional; jq-dependent, fails open) ----------------------------
# Located with the same three-probe pattern the orchestrator uses; CLAUDE_PLUGIN_ROOT
# is not exported into this environment, so it is probed but never relied on.
find_settings_sh(){
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/hooks/settings.sh" ]; then
    printf '%s' "$CLAUDE_PLUGIN_ROOT/hooks/settings.sh"; return 0
  fi
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$d/settings.sh" ] && { printf '%s' "$d/settings.sh"; return 0; }
  c="$HOME/.claude/plugins/cache/auto-task-plugin/auto-task"
  if [ -d "$c" ]; then
    # shellcheck disable=SC2010  # this is the plugin's own prescribed three-probe
    # pattern, copied verbatim from check-version.sh and the Phase-1 preamble; the
    # entries are version directories (X.Y.Z), so no odd filename can reach it, and
    # diverging here would leave one probe shaped unlike every other.
    v="$(ls -1 "$c" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
    [ -n "$v" ] && [ -f "$c/$v/hooks/settings.sh" ] && { printf '%s' "$c/$v/hooks/settings.sh"; return 0; }
  fi
  return 1
}

setting_get(){
  # $1 = key, $2 = fallback. Never fails the run: no settings.sh / no jq -> fallback.
  s_sh="$(find_settings_sh 2>/dev/null || true)"
  [ -n "$s_sh" ] || { printf '%s' "$2"; return 0; }
  v="$(bash "$s_sh" get "$1" 2>/dev/null || true)"
  case "$v" in ''|null) printf '%s' "$2" ;; *) printf '%s' "$v" ;; esac
}

# Env overrides follow the convention settings.sh already uses for
# AUTO_TASK_SETTINGS_SCHEMA_VERSION: an explicit env value wins over the settings
# file. They exist so the tests can drive a stub analyzer without writing a settings
# file into the developer's repo.
timeout_sec="${AUTO_TASK_ANALYZER_TIMEOUT:-$(setting_get analyzer_timeout_sec 120)}"
# `0` is digits-only, so the obvious validator accepted it — and `alarm 0` in perl
# CANCELS the alarm rather than firing immediately, which disarmed the only bound the
# helper has. Measured: a 60s stub ran the full 60s under `analyzer_timeout_sec: 0`,
# where 2s returned in 4s. `ver_bound` inherits the same value, so the version probe was
# unbounded too. A non-positive timeout is meaningless here; fall back to the default.
#
# Tested NUMERICALLY, not by enumerating literals. The first version of this guard listed
# `0` and nothing else, so `00` — digits-only, and not the string `0` — walked straight
# through it: measured `alarm 00` NOT_FIRED against a 10s sleep, a `sleep 30` stub running
# 91s, and the run then reporting `status:"ok"` with zero counts. Enumeration can only ever
# reject the spellings someone thought to list; `-gt 0` rejects the whole class. Leading
# zeros are safe to keep otherwise — bash's `[` is base-10 (no octal trap: `[ 008 -gt 0 ]`
# is true) and perl numifies `007` to 7, measured FIRED. The `2>/dev/null ||` arm also
# catches a value too wide for the shell's integer compare, which errors rather than
# comparing, and lands it on the default instead of an unbounded run.
case "$timeout_sec" in
  ''|*[!0-9]*) timeout_sec=120 ;;
  *) [ "$timeout_sec" -gt 0 ] 2>/dev/null || timeout_sec=120 ;;
esac

# Gitlink entries (mode 160000) are submodule roots. Computed once; consumed by
# scan_tree on both sides so a submodule's contents never enter the delta.
#
# `ls-files --stage` emits `<mode> SP <sha> SP <stage> TAB <path>`, so the path is
# everything after the FIRST TAB — anchor on that and there is nothing left to get
# wrong. Rebuilding the path from awk's whitespace-split fields instead ($1=$2=$3="")
# mangled two real shapes: a path containing consecutive spaces came back with the run
# collapsed to one, and a non-ASCII path arrived C-quoted ("caf\303\251/") because
# `core.quotePath` defaults on. Either way the prefix test below stops matching, the
# exclusion silently does not apply, and the submodule's pre-existing findings all
# report as `introduced` — the flood this layer exists to prevent, back verbatim.
# `-z` turns quoting off at the source (that is what it is for); records are then
# NUL-separated, so `tr` can restore the newline separator the consumer splits on
# without a quoting round-trip in between.
#
# KNOWN LIMIT, recorded so it is not rediscovered as a bug: a submodule path containing a
# LITERAL NEWLINE cannot survive this transport, because newline is the separator the
# consumer splits on. Such a record splits in two — the head yields a truncated prefix
# and the tail is dropped — so the real submodule stops being excluded AND the truncated
# prefix can falsely exclude an unrelated sibling that happens to match it. Not worth
# closing here: the analyzer's own output is line-oriented, so a finding inside such a
# path could not be keyed either way, and every alternative separator is a byte git also
# permits in a path.
submodule_paths="$(git -C "$repo_root" -c core.quotePath=false ls-files --stage -z 2>/dev/null \
  | LC_ALL=C tr '\0' '\n' \
  | LC_ALL=C sed -n 's/^160000 [0-9a-f][0-9a-f]* [0-9][0-9]*'"$(printf '\t')"'//p' || true)"

# --- Bounded execution --------------------------------------------------------
# macOS has no timeout(1). This shim FORKS and kills the child's whole PROCESS GROUP;
# it deliberately does not `exec`. The obvious `perl -e 'alarm shift; exec @ARGV'`
# idiom is not enough: SIGALRM kills the exec'd shell, but a grandchild (a `sleep`, a
# hung linter subprocess) survives and keeps the command-substitution pipe open, so
# `$( )` blocks until the grandchild exits. Killing the group closes the pipe, which is
# what actually bounds the run. Returns 142 on timeout.
run_bounded(){
  perl -e '
    my $t = shift;
    my $pid = fork();
    if (!defined $pid) { exit 127 }
    if ($pid == 0) { setpgrp(0, 0); exec @ARGV; exit 127 }
    $SIG{ALRM} = sub { kill("KILL", -$pid); waitpid($pid, 0); exit 142 };
    alarm $t;
    waitpid($pid, 0);
    alarm 0;
    my $st = $?;
    # A SIGNALLED child must NOT be reported as exit 0. `$? >> 8` discards the signal
    # byte, so SIGKILL/SIGSEGV/SIGTERM (OOM killer, ulimit, a crashing linter plugin)
    # all came back as 0 — a truncated scan then looked like a clean one and the delta
    # fabricated `introduced` entries. Map a signal to 128+signo, which every caller
    # here treats as "did not run".
    if ($st & 127) { exit(128 + ($st & 127)) }
    exit($st >> 8);
  ' "$@"
}

# --- Discovery ----------------------------------------------------------------
# Tier 1: an explicit `analyzer_command` the user named.
# Tier 2: a direct invocation this script CONSTRUCTS ITSELF — which is precisely why
#         it can never carry `--fix`: we choose every token of it. Requires both a
#         marker in the repo AND the tool already on PATH, so it never names a tool
#         the machine lacks and never introduces a dependency.
# Tier 3: nothing -> skip.
#
# Deliberately NOT parsed: `npm run lint` / `make lint` script indirection (the --fix
# hides inside package.json where a surface check cannot see it), and CLAUDE.md prose
# (auto-task-verify reads that with an LLM; a grep here would routinely disagree).
# Both are reachable via Tier 1, where the user named them.
#
# Deliberately NOT in the table: `go vet` — it writes diagnostics to STDERR and exits
# 1, so under the stdout-only rule below a Go repo would score "non-zero exit, zero
# positional findings" and skip forever. Piping 2>&1 for one row would reopen the
# diagnostics-vs-findings ambiguity the stdout rule exists to close. Go is a Tier-1 case.
discover_analyzer(){
  explicit="${AUTO_TASK_ANALYZER_COMMAND:-$(setting_get analyzer_command '')}"
  if [ -n "$explicit" ]; then
    ANALYZER_CMD="$explicit"; ANALYZER_SOURCE="setting"; return 0
  fi
  if command -v shellcheck >/dev/null 2>&1; then
    # NOT `ls-files '*.sh'`: GIT_LITERAL_PATHSPECS=1 is exported above (it stops a file
    # named `:leak.sh` from being read as pathspec magic), which also makes `*.sh` a
    # LITERAL path matching nothing. Measured: discovery silently resolved to `none` on
    # a repo of 70 shell scripts. Filter the full listing instead.
    if git -C "$repo_root" ls-files 2>/dev/null | grep -q '\.sh$'; then
      ANALYZER_CMD="shellcheck --format=gcc"
      ANALYZER_ENUM="git ls-files | grep '[.]sh\$'"
      ANALYZER_SOURCE="discovered"; return 0
    fi
  fi
  if command -v eslint >/dev/null 2>&1; then
    for m in .eslintrc .eslintrc.js .eslintrc.json .eslintrc.yml eslint.config.js eslint.config.mjs; do
      [ -e "$repo_root/$m" ] && { ANALYZER_CMD="eslint --format unix ."; ANALYZER_SOURCE="discovered"; return 0; }
    done
  fi
  if command -v ruff >/dev/null 2>&1; then
    if [ -e "$repo_root/ruff.toml" ] || grep -q '\[tool\.ruff\]' "$repo_root/pyproject.toml" 2>/dev/null; then
      ANALYZER_CMD="ruff check ."; ANALYZER_SOURCE="discovered"; return 0
    fi
  fi
  return 1
}

discover_analyzer || emit_skip "no analyzer resolvable: no analyzer_command setting, and no recognized marker with its tool on PATH"

# The tool itself must exist. A Tier-1 command names its own binary.
analyzer_bin="${ANALYZER_CMD%% *}"
command -v "$analyzer_bin" >/dev/null 2>&1 || emit_skip "analyzer not installed: $analyzer_bin"

# --- Trust boundary: refuse auto-fixers (Tier 1 only can carry them) ----------
# Matched WORD-WISE, never as a substring: a bare `-w` substring test false-skips on
# `--no-warnings` and `-Werror`, which are ordinary read-only flags.
for tok in $ANALYZER_CMD; do
  case "$tok" in
    --fix|--write|-w|--fix-dry-run=false|--apply)
      emit_skip "refusing an auto-fixing analyzer command: token '$tok' would rewrite the working tree" ;;
  esac
done

# Bounded like every other analyzer invocation: this probe RUNS the tool, and an
# unbounded one here made the scan timeout unreachable -- measured 32s elapsed
# against a 2s cap, because a hanging analyzer hung on `--version` before any scan.
# C9: capture the pre-helper diff hash BEFORE the version probe, because that probe
# RUNS the analyzer binary. A Tier-1 wrapper that ignores unknown flags (the
# `make lint` shape) mutated the tree during `--version` and the detector, which
# used to start measuring afterwards, reported a clean run.
hash_before="$(git -C "$repo_root" diff --no-color --no-ext-diff --no-textconv "$base" 2>/dev/null | git hash-object --stdin 2>/dev/null || echo "")"

ver_bound=10
if [ "$timeout_sec" -lt 10 ] 2>/dev/null; then ver_bound="$timeout_sec"; fi
analyzer_version="$(run_bounded "$ver_bound" "$analyzer_bin" --version 2>/dev/null \
  | head -2 | LC_ALL=C tr -cd '[:print:]' | cut -c1-120 || true)"
# A probe result that looks like a FINDING is not a version. A wrapper that ignores
# `--version` echoed its scan output here, so the cache key tracked the tree's findings
# and every round paid a fresh worktree add plus a full base rescan — measured three
# distinct cache files across three rounds on one base. Refusing the positional shape is
# the closed form: a real version string does not look like `path:line:col:`.
case "$analyzer_version" in
  *[!:]:[0-9]*:[0-9]*:*) analyzer_version="unknown" ;;
esac
[ -n "$analyzer_version" ] || analyzer_version="unknown"

# --- Scan one tree ------------------------------------------------------------
# Contract: prints TAB-separated records `key<TAB>file<TAB>line<TAB>rest` on stdout,
# and writes a one-word status to the file named by $2:
#   ok           the side ran and its output shape was recognized
#   timeout      killed by the alarm shim -> ALWAYS loses, whatever it emitted first
#   unrecognized emitted >=1 non-blank line and none matched the positional shape
#   invalid      exited non-zero AND produced zero positional findings
#
# STDOUT ONLY. stderr carries diagnostics, not findings; keying it is what made
# "did this side actually run?" ambiguous in an earlier design.
#
# Number normalization: a token of ONLY digits becomes `#`; a mixed token is left
# alone. That is what makes a line shift cancel while `SC2086` still identifies the rule.
scan_tree(){
  tree="$1"; status_file="$2"
  # Some tools take their targets as arguments (shellcheck) and some default to the
  # cwd (eslint ., ruff check .). ANALYZER_ENUM, when set, is a snippet evaluated
  # INSIDE the tree being scanned — so the base side enumerates the base tree's files,
  # not the current tree's. A Tier-1 command is self-contained and sets no enum.
  # Targets are passed as separate ARGV entries, never interpolated into the command
  # string. Building `"$ANALYZER_CMD $targets"` and handing it to `sh -c` word-splits the
  # list and re-parses it as shell source: a tracked file named `my script.sh` silently
  # disabled the whole layer (reported as an unanalyzable base tree, which is the wrong
  # reason), and a file named `$(id -un).sh` was EXECUTED — command injection through a
  # filename, in a script that already exports GIT_LITERAL_PATHSPECS=1 because odd
  # filenames are a live concern. `sh -c '<cmd> "$@"' sh a b c` keeps every target a
  # single opaque argument no matter what it contains.
  set --
  if [ -n "${ANALYZER_ENUM:-}" ]; then
    tfile="$cache/.analyzer-targets.$$"
    ( cd "$tree" 2>/dev/null && eval "$ANALYZER_ENUM" 2>/dev/null ) > "$tfile" 2>/dev/null || true
    if [ ! -s "$tfile" ]; then
      rm -f "$tfile" 2>/dev/null || true
      printf 'ok' > "$status_file"; return 0   # nothing to scan = zero findings
    fi
    while IFS= read -r tgt; do
      [ -n "$tgt" ] && set -- "$@" "$tgt"
    done < "$tfile"
    rm -f "$tfile" 2>/dev/null || true
  fi
  # `--` before the targets: argv passing keeps the SHELL from reinterpreting a name,
  # but the analyzer still parses its own flags, so one tracked file called `-x.sh`
  # disabled the whole layer and reported "the base tree could not be analyzed usefully"
  # — fail-open holding while the stated reason named the wrong cause, which this file's
  # header calls the one thing a skip must never do.
  # `--` ONLY when targets are actually being passed. Appending it unconditionally
  # re-opened the very failure class the `--` was added to close, one tier over: with no
  # targets there is nothing for it to protect, and a command whose parser rejects a bare
  # `--` then fails. Measured: `go vet ./... --` -> "malformed import path: leading dash",
  # zero findings, surfacing as "the current tree could not be analyzed usefully" — the
  # layer silently off, blaming the tree. `$#` is exactly the "targets are being passed"
  # condition, since `set --` clears the list and only the enum branch refills it.
  if [ $# -gt 0 ]; then
    run_cmd="$ANALYZER_CMD -- \"\$@\""
  else
    run_cmd="$ANALYZER_CMD"
  fi
  # The timeout shim FORKS and kills the child's whole PROCESS GROUP; it does not
  # `exec`. macOS has no timeout(1), and the obvious `perl -e 'alarm shift; exec @ARGV'`
  # idiom is not enough here: SIGALRM kills the exec'd shell, but a grandchild (a
  # `sleep`, a hung linter subprocess) survives and keeps the command-substitution pipe
  # open, so `$( )` blocks until the grandchild exits. Measured: a 2s timeout against a
  # 30s sleep took the full 30s and reported "bounded: no". Killing the group closes
  # the pipe, which is what actually bounds the run.
  raw="$(cd "$tree" 2>/dev/null && run_bounded "$timeout_sec" /bin/sh -c "$run_cmd" sh "$@" 2>/dev/null)"
  rc=$?
  # 142 = SIGALRM from the shim. Anything >= 128 is a SIGNAL death (the shim maps a
  # signalled child to 128+signo — see run_bounded), and a signalled scan NEVER "ran":
  # it was cut off mid-stream, so whatever it printed is a truncated prefix. Treating
  # that as a normal exit is what let a SIGKILLed base scan read as clean and fabricate
  # `introduced` entries — measured 2 fabricated findings on a tree with zero changes.
  # 142 ONLY: the shim's ALRM handler exits 142 explicitly, so a bare `14` is not a
  # timeout signal — it is an analyzer that legitimately exited 14, and reporting that as
  # a timeout names the wrong cause.
  if [ "$rc" -eq 142 ]; then printf 'timeout' > "$status_file"; return 0; fi
  if [ "$rc" -ge 128 ]; then printf 'killed' > "$status_file"; return 0; fi

  nonblank="$(printf '%s\n' "$raw" | grep -c '[^[:space:]]' 2>/dev/null || echo 0)"
  case "$nonblank" in ''|*[!0-9]*) nonblank=0 ;; esac

  # SUBMODULE paths are dropped from BOTH sides. `git worktree add --detach` does not
  # initialise submodules, so the base slot has an empty gitlink directory while the live
  # tree has its content — every pre-existing finding inside a submodule then exists only
  # on the current side and reports as `introduced`. Measured: 2 false positives on a repo
  # whose true answer was 0, repeating on every round. The base-validity rule cannot catch
  # it (that side exits 0, so it "ran"). Dropping the paths is right on the merits too:
  # a submodule bump is not this run's code, and its contents are reviewed in their own
  # repository.
  # `tree` is stripped from the path so an ABSOLUTE-path tool keys identically on both
  # sides. eslint's `unix` formatter always prints result.filePath absolute, and
  # `eslint --format unix .` is both a Tier-2 discovery row and the documented example —
  # with the raw path in the key, base (inside the slot) and current (inside the repo)
  # were disjoint and EVERY finding reported as introduced AND resolved.
  # NO PATH TRAVELS THROUGH `-v`, here or at the rename map below. An `-v` assignment is
  # scanned for escape sequences, which mangles a path two ways and kills awk on a third:
  # `a\tb` -> `a<TAB>b` (4 chars in, 3 out); `a\qb` -> `aqb`, the backslash silently
  # dropped; and a literal newline is fatal (`awk: newline in string`, rc=2). Both values
  # are filesystem paths, so both were exposed, and they fail differently.
  # `submodule_paths` is newline-SEPARATED, so it hit the fatal case as soon as a repo had
  # TWO submodules: the exclusion worked with one and hard-failed with two, awk produced
  # no records at all, and the side was graded on empty output with a cause naming the
  # shape rather than the crash. `root` is a single path, so it fails quieter and worse —
  # a mangled `root` makes the `index(file, root "/")` test below miss, an absolute-path
  # tool's findings never become tree-relative, base and current keys go disjoint, and
  # EVERY finding reports as both introduced and resolved: the flood described directly
  # above, arriving through the escape parser instead. The trigger is the developer's
  # checkout path, not anything git controls — `check-ref-format` forbids a backslash in a
  # branch name, but nothing forbids one in a directory name.
  # ENVIRON has no escape processing and carries newlines, spaces and UTF-8 unaltered.
  recs="$(printf '%s\n' "$raw" | AT_ANALYZER_SUBS="$submodule_paths" AT_ANALYZER_ROOT="$tree" \
    LC_ALL=C awk -F: '
    BEGIN { ns = split(ENVIRON["AT_ANALYZER_SUBS"], sp, "\n"); root = ENVIRON["AT_ANALYZER_ROOT"] }
    /^[^:]+:[0-9]+:/ {
      file = $1; line = $2
      rest = substr($0, length(file) + length(line) + 3)
      # Strip a leading COLUMN (`5: ` or `5 `). The column is a position, not an
      # identity: re-indenting a line, or wrapping it in an if-block, moves it and made
      # the whole file churn. The earlier digit-collapse missed it because `5:` is not
      # digits-only, so the gcc and space-separated formats keyed DIFFERENTLY on this
      # axis — precisely the per-tool dependence this design forbids.
      sub(/^[0-9]+[: \t]+/, "", rest)
      # Any remaining digits-only token still collapses (counts inside messages).
      n = split(rest, tok, /[ \t]+/); out = ""
      for (i = 1; i <= n; i++) {
        t = tok[i]
        if (t ~ /^[0-9]+$/) t = "#"
        out = (out == "" ? t : out " " t)
      }
      gsub(/^[ \t]+|[ \t]+$/, "", out)
      if (root != "" && index(file, root "/") == 1) file = substr(file, length(root) + 2)
      # Then normalise a leading `./`, which is the OTHER shape a tool can emit and the
      # one the absolute-path strip above does not reach. `flake8 .`, `find . | xargs
      # shellcheck`, and most `make lint` wrappers all print `./pkg/x.sh`. Every consumer
      # below compares this path against a git-derived one, and git never writes `./`:
      # `index("./vendor/lib.sh", "vendor/")` is 3, not 1, so the submodule mark stays `K`
      # and the whole gitlink exclusion silently stops applying (measured: 2 false
      # `introduced` on a tree whose true answer was 0 — the pre-existing flood, back
      # verbatim); and the rename map, keyed on `git diff --name-status` output, misses
      # for the same reason, so a `git mv` double-reports (AC 16). One `sub()` here fixes
      # both, because this is where the identity key is minted. Do it AFTER the root strip,
      # so an absolute path that happens to contain `/./` is handled by the strip first.
      #
      # LOOPED, because the defect is the PREFIX CLASS, not the string `./`. A single
      # `sub()` strips one spelling and leaves its siblings breaching exactly as before:
      # measured against the real hook, `.//vendor/lib.sh` came out as `/vendor/lib.sh`
      # and `././vendor/lib.sh` as `./vendor/lib.sh`, both marked `K`, both reproducing
      # the introduced-flood in full (current 3, introduced 2, true answer 0). `.//` is
      # not exotic — it is what Make-style path composition emits whenever a directory
      # variable holding `.` is interpolated as `$(DIR)/`. Enumerating one spelling here
      # is the same shape as the original `|0` arm of the timeout guard, which was rewritten
      # into a property test for this exact reason; the two fixes landed together, so
      # they should fail together too. `/+` absorbs the run and the loop absorbs the
      # repetition. `../` and a bare `.` are left untouched; `./` alone reduces to the
      # empty string, which is why the guard below exists.
      while (sub(/^\.\/+/, "", file)) ;
      # An empty path is dropped HERE, at the emitter, and it cannot be left to the
      # consumer. The consumer reads these records with `IFS=<TAB> read`, and TAB is IFS
      # *whitespace*, so a run of tabs COLLAPSES: an empty `file` field does not arrive as
      # an empty variable, it vanishes and every later field shifts left. Measured on the
      # record `K<TAB><TAB>9<TAB>note: bogus` — the consumer parsed `f=9`, `l=note: bogus`,
      # so its `[ -n "$f" ]` guard never fired and the run emitted a contentless finding
      # keyed on the LINE NUMBER as though it were a filename. A downstream guard cannot
      # see a field that IFS already ate; only the producer can.
      if (file == "") next
      # Submodule records are MARKED, not dropped here. Dropping them inside the parse
      # made a side whose findings were all inside a submodule look like it produced no
      # positional output at all — so the shape test graded it `unrecognized` and the run
      # skipped with a cause that was not true. Measured on a real submodule fixture.
      # The shape test must see every positional line the tool emitted; only the DELTA
      # excludes submodule content.
      mark = "K"
      for (si = 1; si <= ns; si++) {
        if (sp[si] != "" && index(file, sp[si] "/") == 1) { mark = "S"; break }
      }
      # The record is TAB-DELIMITED, so a TAB inside a field breaks it — and `file` is the
      # only field that can carry one. `mark` is `K` or `S`, `line` is digits, and `out`
      # was rebuilt above by splitting on /[ \t]+/ and rejoining with single spaces; only
      # `file` arrives verbatim from the analyzer. Unsanitised, the consumer re-splits on
      # TAB and every later field shifts left: for `x<TAB>y.sh` it read `f="x"`,
      # `l="y.sh"`, and the key became `x\x1f2<TAB>note: …` — with THE LINE NUMBER INSIDE
      # THE IDENTITY KEY, which is the one thing this design forbids, so any line shift
      # then disjoints it. Measured on the literal AC-1 shape: 1 introduced + 1 resolved
      # where the true answer is 0/0.
      #
      # Substitute rather than drop, and do it AFTER the submodule test above so that test
      # still compares the real path against the real gitlink path. Both sides run this
      # identical substitution, so the key stays consistent and the finding survives — an
      # exotic filename should not silently lose its findings the way dropping would. This
      # is the same treatment `esc()` already applies for the JSON payload
      # (`gsub(/[[:cntrl:]]/, " ", s)`); the internal record transport simply never got it.
      #
      # ACCEPTED COST, recorded so it is not rediscovered: substitution COLLIDES
      # `a<TAB>b.sh` with `a b.sh`. Measured — a finding that moves between two such files
      # cancels to 0/0 where the truth is 1 introduced + 1 resolved, because multiplicity
      # sees one occurrence of the merged key on each side. It needs two paths in one repo
      # differing only by TAB-vs-space at the same offset, carrying an identical normalised
      # message. Dropping instead would lose findings unconditionally for every TAB-named
      # file, which is strictly worse, so the collision is the better of the two costs.
      #
      # KNOWN RESIDUAL of the same class, deliberately not closed here: `out` is not
      # sanitised, so a literal `\x1f` in a message makes the key three-component and the
      # rename rewrite (`split(key, kp, "\037")`) silently truncates it — measured
      # `1 introduced + 1 resolved` across a `git mv`. Unreachable in practice (no analyzer
      # emits a unit separator; colourising linters use `\x1b`), which is why `\x1f` was
      # chosen as the separator. The closed form for the whole delimiter class is one
      # substitution — `gsub(/[[:cntrl:]]/, " ", …)` on BOTH `file` and `out`, matching
      # esc() exactly — and it is the recommended shape if this is ever reopened.
      gsub(/\t/, " ", file)
      printf "%s\t%s\t%s\t%s\n", mark, file, line, out
    }')"

  found=0
  [ -n "$recs" ] && found="$(printf '%s\n' "$recs" | grep -c . || echo 0)"
  case "$found" in ''|*[!0-9]*) found=0 ;; esac

  # Empty stdout is RECOGNIZED — it means zero findings, the normal clean result.
  # The shape test applies only to lines that exist. Without this, a clean side would
  # skip instead of reporting `resolved`, which is the opposite of correct.
  #
  # Unparseable output is `unrecognized` REGARDLESS OF EXIT CODE, which is what AC 2b
  # says. The exit code was briefly recruited as a discriminator so that a clean tool
  # printing a banner ("All checks passed", `make` echoing its recipe) would not skip.
  # It cannot serve: `found==0, nonblank>0` is the SAME observation whether the tool is
  # clean-with-a-banner or emitting findings in a format we cannot parse, so keying on
  # `rc` did not separate the two cases — it just picked which one to be wrong about,
  # and picked the worse one. Grading `ok` there reports zero findings on BOTH sides and
  # an empty delta: a confident wrong answer, and the empty base then gets CACHED.
  # `skip` is the honest resting state — it says the layer determined nothing, which is
  # exactly what happened, and it is the same fail-open shape a missing analyzer takes.
  # The banner case costs an advisory finding; the alternative fabricates a clean bill of
  # health. `detail` names the shape so the fix (point `analyzer_command` at a
  # machine-readable formatter) is actionable rather than mysterious.
  if [ "$found" -eq 0 ] && [ "$nonblank" -gt 0 ]; then
    printf 'unrecognized' > "$status_file"; return 0
  fi
  if [ "$found" -eq 0 ] && [ "$rc" -ne 0 ]; then
    printf 'invalid' > "$status_file"; return 0
  fi

  # The key is (file, position-stripped message). The SOURCE LINE used to be part of it,
  # on the theory that content identifies a defect better than a line number does. It
  # does not survive contact: a file-scoped rule anchors at line 1 (SC2148 on a missing
  # shebang), so adding one leading comment changed the "identity" of a finding that had
  # not moved and reported it as both introduced and resolved. Dropping it is strictly
  # better AND simpler — a shift already cancels because the line number was never in the
  # key, duplicates are still counted by multiplicity, and it removes one `sed` per
  # finding. What is lost: two occurrences of one rule in one file are now
  # indistinguishable, which is exactly what multiplicity counting is for.
  printf '%s\n' "$recs" | while IFS="$(printf '\t')" read -r mark f l rest; do
    [ -n "${f:-}" ] || continue
    [ "$mark" = "S" ] && continue          # inside a submodule: absent from the base slot
    printf '%s\x1f%s\t%s\t%s\t%s\n' "$f" "$rest" "$f" "$l" "$rest"
  done
  printf 'ok' > "$status_file"
}

# --- Rename map ---------------------------------------------------------------
# `file` is part of the identity key, so a plain `git mv` of an unmodified file would
# report every pre-existing finding in it as `introduced` at the new path AND
# `resolved` at the old — the same noise flood the line-shift rule prevents, arriving
# through a different door. So base-side paths are rewritten to their CURRENT names
# before comparing. (checks.sh met this class and pinned --no-renames; the fix here is
# the opposite direction — follow the rename rather than split it.)
#
# Known limit, deliberately deferred: `git diff -M` cannot see a rename whose
# destination is still untracked. The pipeline does not present that shape — Phase 4
# always runs after Phase-3 entry, where intent-add-untracked.sh has intent-added the
# run's new files. Closing it here would require mutating the index, which would move
# `git diff <base>` — the very hash reviewed_diff_sha pins.
rename_map="$cache/.analyzer-renames.$$"
: > "$rename_map"
git -C "$repo_root" diff -M --name-status "$base" 2>/dev/null | LC_ALL=C awk -F'\t' '
  $1 ~ /^R/ && NF >= 3 { printf "%s\t%s\n", $2, $3 }' >> "$rename_map" 2>/dev/null || true

# --- Base side ----------------------------------------------------------------
# KEY_FORMAT is part of the cache key, and it is not decoration. The cached base side
# stores KEYS, so any change to how a key is built makes an old cache incomparable with
# a freshly-scanned current side — every key disjoint, every finding reported as BOTH
# introduced and resolved. Measured during this run: after the key dropped its source-line
# component, a warm cache produced `introduced:366, resolved:366` on a tree whose true
# answer was 0/0. The analyzer-version component guards a rule-set change; this guards a
# change to our own algorithm. BUMP IT whenever the key construction in scan_tree changes.
# 2 -> 3: the `./` prefix normalisation changed key construction, so a base cached before
# it (keys `./x.sh\x1fmsg`) would compare disjoint against a post-fix current side
# (`x.sh\x1fmsg`) — precisely the double-report described above. No such cache can exist
# outside this branch, since the helper is unreleased; bumped anyway because the rule
# above is unconditional, and a stated invariant that is honoured only when someone
# judges it to matter is not an invariant.
# 3 -> 4: the TAB substitution in `file` likewise changed key construction, for every
# TAB-bearing path. Caught by review, not by the author — which is the point of the
# preceding sentence: the 2 -> 3 bump was reasoned out at length and the very next change
# to the same algorithm still missed it. Reproduced: a cache warmed by a pre-fix build and
# reused by the fixed one reports `1 introduced + 1 resolved` on the literal AC-1 shape.
KEY_FORMAT="${AUTO_TASK_ANALYZER_KEY_FORMAT:-4}"
cache_key="$(printf '%s|%s|%s|%s' "$base" "$ANALYZER_CMD" "$analyzer_version" "$KEY_FORMAT" \
             | LC_ALL=C cksum | tr -d ' ' | cut -c1-24)"
cache_file="$cache/analyzer-base-${cache_key}.tsv"
base_recs="$cache/.analyzer-base-recs.$$"
base_status="$cache/.analyzer-status.$$"
base_source="worktree"
slot=""
cur_recs=""
cur_status=""

# shellcheck disable=SC2329  # reached via the `trap cleanup ...` lines below, which
# ShellCheck does not follow. NOT a silencing of a real finding: the residue AC proves
# the trap fires (0 leftover slot dirs after a run), and the timeout AC proves it fires
# on the abort path too. The code is SC2329 ("function never invoked"), not SC2317
# ("command unreachable") — naming the wrong one disables nothing, which is how the
# first attempt at this comment left the finding standing.
cleanup(){
  if [ -n "${slot:-}" ] && [ -d "$slot" ]; then
    git -C "$repo_root" worktree remove --force "$slot" >/dev/null 2>&1 || true
    rm -rf "$slot" 2>/dev/null || true
    git -C "$repo_root" worktree prune >/dev/null 2>&1 || true
  fi
  rm -f "$base_recs" "$base_status" "$rename_map" 2>/dev/null || true
  # The atomic-write temp file matched neither this list nor the prune glob, so a signal
  # between the `cp` and the `mv` stranded it under artifacts/ permanently.
  rm -f "$cache"/analyzer-base-*.tmp.$$ 2>/dev/null || true
  rm -f "$cache"/.analyzer-targets.$$ 2>/dev/null || true
  [ -n "${cur_recs:-}" ] && rm -f "$cur_recs" 2>/dev/null || true
  [ -n "${cur_status:-}" ] && rm -f "$cur_status" 2>/dev/null || true
}
# INT/TERM must EXIT, not fall through. A bare `trap cleanup INT TERM` runs the handler
# and then RESUMES at the interrupted point — cleanup had already unlinked the record
# files, so the delta read two empty files and reported a confident `status:"ok",
# introduced:0` for a run that was killed mid-scan. That is the fail-SILENT this
# file's header forbids in those words.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# A complete cache file ends with a sentinel carrying its record count. A truncated
# file is indistinguishable from a complete one without it — and the process that
# writes it can die without its trap running — so a file whose sentinel is missing or
# disagrees is IGNORED and recomputed, never trusted. Trusting one would compare
# against a short baseline and manufacture `introduced` findings forever.
cache_valid=0
if [ -f "$cache_file" ]; then
  sentinel="$(tail -1 "$cache_file" 2>/dev/null || true)"
  case "$sentinel" in
    "#COUNT="*)
      want="${sentinel#\#COUNT=}"
      # NO `|| echo 0`: `grep -cv` prints `0` and EXITS 1 when the count is zero, so the
      # fallback also fired and `have` became "0\n0" — never equal to `want`. Measured: a
      # clean base never warmed its cache, so every Phase-4 round paid a full worktree add
      # plus a full scan, contradicting "the base side is computed once per run".
      have="$(grep -cv '^#COUNT=' "$cache_file" 2>/dev/null)"
      case "$have" in ''|*[!0-9]*) have="x" ;; esac
      case "$want" in ''|*[!0-9]*) want="x" ;; esac
      [ "$want" = "$have" ] && cache_valid=1 ;;
  esac
fi

if [ "$cache_valid" -eq 1 ]; then
  grep -v '^#COUNT=' "$cache_file" > "$base_recs" 2>/dev/null || : > "$base_recs"
  base_source="cache"
else
  # Unique per invocation so concurrent runs never collide on one slot.
  rnd="$(od -An -N2 -tu2 < /dev/urandom 2>/dev/null | tr -d ' ' || echo 0)"
  slot="$cache/.analyzer-base-$$-${rnd:-0}"
  # Prune only a PROVABLY DEAD peer slot. "Older than me" would delete a live peer
  # mid-scan — a peer that started two seconds ago is by definition older.
  for old in "$cache"/.analyzer-base-*; do
    [ -d "$old" ] || continue
    [ "$old" = "$slot" ] && continue
    opid="$(basename "$old" | sed 's/^\.analyzer-base-//; s/-.*$//')"
    case "$opid" in ''|*[!0-9]*) continue ;; esac
    # Liveness is the test; MTIME is the recycled-pid backstop the plan specified and
    # this code first omitted. Without it a recycled pid leaks a dead slot and a stale
    # worktree registry entry forever. `kill -0` also returns EPERM for a live process
    # owned by ANOTHER user, which reads as dead — so the age check has to agree before
    # anything is removed.
    # Remove when the pid is dead OR the slot is stale — the two legs are alternatives,
    # not conjuncts. Dead-pid alone catches the ordinary crash immediately; the 60-minute
    # age leg is the backstop for a RECYCLED pid, where `kill -0` succeeds for an
    # unrelated live process and the slot would otherwise leak forever.
    # (`kill -0` also fails with EPERM for another user's live process, which reads as
    # dead. Not reachable here: the slot lives under this run own `.auto-task/` cache
    # dir, so another user does not own one.)
    if kill -0 "$opid" 2>/dev/null; then
      [ -n "$(find "$old" -maxdepth 0 -mmin +60 2>/dev/null)" ] || continue   # alive and fresh
    fi
    git -C "$repo_root" worktree remove --force "$old" >/dev/null 2>&1 || true
    rm -rf "$old" 2>/dev/null || true
  done
  git -C "$repo_root" worktree prune >/dev/null 2>&1 || true
  # Completed cache files accumulate one per (base sha x command x version x key format)
  # and nothing removed them. Drop the stale ones; a deleted cache costs one rescan.
  find "$cache" -maxdepth 1 -name 'analyzer-base-*.tsv' -mtime +7 -delete 2>/dev/null || true

  if ! git -C "$repo_root" worktree add --detach "$slot" "$base" >/dev/null 2>&1; then
    emit_skip "could not create the base worktree at $slot"
  fi
  scan_tree "$slot" "$base_status" > "$base_recs" 2>/dev/null || true
  bstat="$(cat "$base_status" 2>/dev/null || echo invalid)"

  # Precedence, stated once: timeout-kill -> shape-unrecognized -> base-invalid -> ok.
  # A timeout ALWAYS loses, however many findings it emitted first: a truncated base
  # side would otherwise satisfy "produced findings" and inflate `introduced`.
  # FAIL CLOSED on anything that is not a clean `ok`. The first version of this listed
  # only the three failure statuses it knew about, so `killed` — added by the signal fix
  # directly above — fell through to the success path: a SIGKILLed base scan reported
  # zero findings, every current-side finding was fabricated as `introduced`, and the
  # empty base was then persisted to the cache so later rounds repeated it without even
  # re-scanning. Measured: base=0, current=2, introduced=2 on a tree with zero true
  # introductions. The `*)` default is the closed-form fix — a status this code has never
  # heard of can only ever become a skip, never a pass.
  case "$bstat" in
    ok)           : ;;
    killed)       emit_skip "the analyzer was killed by a signal while scanning the base tree — its output is a truncated prefix, not a clean result" ;;
    timeout)      emit_skip "analyzer timed out after ${timeout_sec}s on the base tree" ;;
    unrecognized) emit_skip "analyzer output shape not recognized on the base tree (no file:line findings); expected positional output" ;;
    invalid)      emit_skip "the base tree could not be analyzed usefully (non-zero exit, zero findings) — reporting a delta against it would flag pre-existing findings as introduced" ;;
    *)            emit_skip "the base-side scan returned an unhandled status '$bstat' — refusing to report a delta from a side this code cannot vouch for" ;;
  esac

  n="$(grep -c . "$base_recs" 2>/dev/null || echo 0)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  tmp_cache="$cache_file.tmp.$$"
  # Written as explicit branches, not `A && B || C`: in that form C also runs when B
  # fails *after* A succeeded, which here would delete a temp file the mv had already
  # consumed. The cache is the one piece of persisted state, so its write stays legible.
  if cp "$base_recs" "$tmp_cache" 2>/dev/null; then
    if printf '#COUNT=%s\n' "$n" >> "$tmp_cache" 2>/dev/null; then
      if ! mv -f "$tmp_cache" "$cache_file" 2>/dev/null; then
        rm -f "$tmp_cache" 2>/dev/null || true
      fi
    else
      rm -f "$tmp_cache" 2>/dev/null || true
    fi
  fi

  git -C "$repo_root" worktree remove --force "$slot" >/dev/null 2>&1 || true
  rm -rf "$slot" 2>/dev/null || true
  git -C "$repo_root" worktree prune >/dev/null 2>&1 || true
  slot=""
fi

# --- Current side, with mutation detection ------------------------------------
# The flag refusal above is the real guard; this is the backstop for a command that
# rewrites the tree anyway. A move is REPORTED, never absorbed: silence would let a
# mutation reach the commit gate as a mystery. No auto-restore — scripted reversion of
# tool-authored changes is destructive and can take a legitimate concurrent edit with
# it, the same stance phase-3-gates.md Step 0's edit rung takes.
cur_recs="$cache/.analyzer-cur-recs.$$"
cur_status="$cache/.analyzer-cur-status.$$"
scan_tree "$repo_root" "$cur_status" > "$cur_recs" 2>/dev/null || true
cstat="$(cat "$cur_status" 2>/dev/null || echo invalid)"

hash_after="$(git -C "$repo_root" diff --no-color --no-ext-diff --no-textconv "$base" 2>/dev/null | git hash-object --stdin 2>/dev/null || echo "")"
if [ -n "$hash_before" ] && [ "$hash_before" != "$hash_after" ]; then
  emit_skip "the analyzer MUTATED the working tree (diff $hash_before -> $hash_after) running '$ANALYZER_CMD' — not auto-reverted; resolve by hand before continuing"
fi

# Fail closed, exactly as the base side above. A killed CURRENT scan reported
# `current:0` and flagged every pre-existing finding as `resolved` — a confident
# `status:"ok"` for a scan that never finished.
case "$cstat" in
  ok)           : ;;
  killed)       emit_skip "the analyzer was killed by a signal while scanning the current tree — its output is a truncated prefix, not a clean result" ;;
  timeout)      emit_skip "analyzer timed out after ${timeout_sec}s on the current tree" ;;
  unrecognized) emit_skip "analyzer output shape not recognized (no file:line findings); expected positional output" ;;
  invalid)      emit_skip "the current tree could not be analyzed usefully (non-zero exit, zero findings)" ;;
  *)            emit_skip "the current-side scan returned an unhandled status '$cstat' — refusing to report a delta from a side this code cannot vouch for" ;;
esac

# --- Delta --------------------------------------------------------------------
# Per-key multiplicity, so 1 occurrence at base and 3 now yields exactly 2 introduced.
# The two sides are tagged into ONE stream rather than passed as two files.
# `FNR == NR` — the usual two-file awk idiom — is WRONG here and was measured wrong:
# when the base file is EMPTY, awk never reads a record from it, so FNR==NR stays true
# for the first record of the SECOND file and the current side is counted as the base.
# That inverts the result precisely when the base is clean, i.e. when every finding is
# genuinely introduced: measured base=1/current=0/introduced=0 on a fixture whose true
# answer was base=0/current=1/introduced=1. A side tag cannot be fooled by an empty side.
# `renames` goes through ENVIRON for the reason spelled out at the scan_tree awk above:
# `-v` escape-processing mangles a path (`a\tb` -> one TAB, `a\qb` -> `aqb`). This leg
# fails the most quietly of the three, because `getline` reports a bad path the same way
# it reports end-of-file: `(getline rl < renames) > 0` is simply false at once, the loop
# body never runs, the rename map is silently empty, and a `git mv` then double-reports
# every pre-existing finding in the moved file — AC 16's exact failure, with no error
# raised anywhere and every status still reading ok.
delta_out="$( { sed 's/^/B\t/' "$base_recs" 2>/dev/null; sed 's/^/C\t/' "$cur_recs" 2>/dev/null; } \
  | AT_ANALYZER_RENAMES="$rename_map" LC_ALL=C awk -F'\t' '
  # C8: strip control characters, exactly as jesc() does on the skip path. A colourising
  # linter (ANSI escapes) or a CR from a CRLF source produced literal control bytes in
  # the success payload and `jq` refused to parse it — the helper emitting unparseable
  # output precisely when it had something to say.
  function esc(s) { gsub(/[[:cntrl:]]/, " ", s); gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
  # R1: the tool DOES establish a severity and a rule code; the spec says so at three
  # sites and the payload used to drop both into an unparsed `message`. Pull them out
  # when the shape offers them, and emit null when it does not — never a guess.
  function sev(m) {
    if (m ~ /(^|[: ])(error|Error|ERROR)([: ]|$)/)   return "error"
    if (m ~ /(^|[: ])(warning|Warning|WARN)([: ]|$)/) return "warning"
    if (m ~ /(^|[: ])(note|info|style)([: ]|$)/)      return "note"
    return ""
  }
  function code(m,   a) {
    if (match(m, /\[[A-Z]+[0-9]+\]/))  { return substr(m, RSTART + 1, RLENGTH - 2) }
    if (match(m, /(^| )[A-Z]+[0-9]+( |$)/)) { a = substr(m, RSTART, RLENGTH); gsub(/ /, "", a); return a }
    return ""
  }
  function entry(f, l, m,   s, c, out) {
    s = sev(m); c = code(m)
    out = "{\"file\":\"" esc(f) "\""
    if (l != "") out = out ",\"line\":" (l + 0)
    out = out ",\"severity\":" (s == "" ? "null" : "\"" esc(s) "\"")
    out = out ",\"code\":"     (c == "" ? "null" : "\"" esc(c) "\"")
    return out ",\"message\":\"" esc(m) "\"}"
  }
  BEGIN {
    renames = ENVIRON["AT_ANALYZER_RENAMES"]
    while ((getline rl < renames) > 0) {
      split(rl, r, "\t"); if (r[1] != "" && r[2] != "") ren[r[1]] = r[2]
    }
    close(renames)
  }
  $1 == "B" {
    key = $2
    split(key, kp, "\037")
    # TWO components since the source line left the key. Rebuilding three appended a
    # trailing separator, so a renamed file never matched and both rename cases churned.
    if (kp[1] in ren) key = ren[kp[1]] "\037" kp[2]   # follow the rename
    bc[key]++; if (!(key in bmeta)) bmeta[key] = $3 "\t" $4 "\t" $5
    next
  }
  $1 == "C" {
    cc[$2]++
    # Keep every occurrence, newest last. First-wins meant all `d` emitted entries
    # carried the FIRST occurrence line — the one that is not new — so the reviewer
    # was pointed d times at the pre-existing location and never at the added ones.
    cmeta[$2 SUBSEP cc[$2]] = $3 "\t" $4 "\t" $5
  }
  END {
    ni = 0; nr = 0; nb = 0; nc = 0
    for (k in bc) nb += bc[k]
    for (k in cc) nc += cc[k]
    intro = ""; res = ""
    for (k in cc) {
      d = cc[k] - (k in bc ? bc[k] : 0)
      if (d > 0) {
        # Emit the LAST d occurrences: with b already present at base, the surplus is the
        # newest ones, which are the ones the reviewer needs to look at.
        for (i = cc[k] - d + 1; i <= cc[k]; i++) {
          split(cmeta[k SUBSEP i], m, "\t")
          intro = intro (intro == "" ? "" : ",") entry(m[1], m[2], m[3])
          ni++
        }
      }
    }
    for (k in bc) {
      d = bc[k] - (k in cc ? cc[k] : 0)
      if (d > 0) {
        split(bmeta[k], m, "\t")
        for (i = 0; i < d; i++) {
          res = res (res == "" ? "" : ",") entry(m[1], "", m[3])
          nr++
        }
      }
    }
    printf "%d\t%d\t%d\t%d\t[%s]\t[%s]", nb, nc, ni, nr, intro, res
  }')"

nb="$(printf '%s' "$delta_out" | cut -f1)"
nc="$(printf '%s' "$delta_out" | cut -f2)"
ni="$(printf '%s' "$delta_out" | cut -f3)"
nr="$(printf '%s' "$delta_out" | cut -f4)"
intro="$(printf '%s' "$delta_out" | cut -f5)"
res="$(printf '%s' "$delta_out" | cut -f6)"
case "$nb" in ''|*[!0-9]*) nb=0 ;; esac
case "$nc" in ''|*[!0-9]*) nc=0 ;; esac
case "$ni" in ''|*[!0-9]*) ni=0 ;; esac
case "$nr" in ''|*[!0-9]*) nr=0 ;; esac
[ -n "$intro" ] || intro="[]"
[ -n "$res" ] || res="[]"

printf '{"analyzer":"%s","analyzer_source":"%s","analyzer_version":"%s","status":"ok","base_source":"%s",' \
  "$(jesc "$ANALYZER_CMD")" "$(jesc "$ANALYZER_SOURCE")" "$(jesc "$analyzer_version")" "$base_source"
printf '"counts":{"base":%s,"current":%s,"introduced":%s,"resolved":%s},' "$nb" "$nc" "$ni" "$nr"
printf '"introduced":%s,"resolved":%s,' "$intro" "$res"
printf '"detail":"%s introduced, %s resolved (base %s, current %s)"}\n' "$ni" "$nr" "$nb" "$nc"
exit 0
