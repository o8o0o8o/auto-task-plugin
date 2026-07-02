#!/usr/bin/env bash
# Unit test for hooks/apply-update.sh — the non-interactive plugin updater.
#
# Exercises layout classification + the exact command each layout WOULD run,
# using AUTO_TASK_UPDATE_DRYRUN=1 so NOTHING is mutated and no real update tool
# is invoked. A fake `claude` shim proves the marketplace path resolves scope
# and never calls `plugin update` during a dry-run.
#
# What this covers: git / marketplace(default+parsed scope) / copy-unknown /
# no-tool fail-open / cwd-independent self-location / the never-force guarantee.
# What it does NOT cover: a real network pull or a real `claude plugin update`
# (those need a live remote / installed marketplace).
#
# Usage: tests/apply-update.test.sh   (requires git, like the script under test)
# Exit 0 = all assertions passed.

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/apply-update.sh"

command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found/executable"; exit 1; }

PASS=0; FAIL=0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

expect_contains(){ # name haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-48s missing=%s\n       got: %s\n' "$1" "$3" "$2"; fi; }
expect_not_contains(){ # name haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then FAIL=$((FAIL+1)); printf '  FAIL  %-48s unexpected=%s\n' "$1" "$3"
  else PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; fi; }
expect_eq(){ # name got want
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-48s got=%s want=%s\n' "$1" "$2" "$3"; fi; }

# --- fake `claude` shim on PATH ---------------------------------------------
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'SHIM'
#!/usr/bin/env bash
# Fake claude: `plugin list` prints a block (scope from FAKE_SCOPE, or a
# different plugin id when FAKE_SCOPE=none so nothing resolves -> default user);
# `plugin update` must NOT run during a dry-run -> record if it ever does.
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "list" ]; then
  if [ "${FAKE_SCOPE:-user}" = "none" ]; then
    printf '  > other-plugin@somewhere\n    Version: 1.0.0\n    Scope: user\n'
  else
    printf '  > auto-task@auto-task-plugin\n    Version: 0.1.12\n    Scope: %s\n    Status: enabled\n' "${FAKE_SCOPE:-user}"
  fi
  exit 0
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "update" ]; then
  echo "REAL-UPDATE-CALLED" > "${UPDATE_MARKER:-/dev/null}"
  exit 0
fi
exit 0
SHIM
chmod +x "$BIN/claude"

echo "================ apply-update.sh ================"

# --- Case A: git work tree, dry-run -----------------------------------------
GITROOT="$T/gitroot"; mkdir -p "$GITROOT"
git init -q "$GITROOT"; git -C "$GITROOT" config user.email t@t.t; git -C "$GITROOT" config user.name t
printf 'x\n' > "$GITROOT/f"; git -C "$GITROOT" add f; git -C "$GITROOT" commit -qm init
HEAD_BEFORE="$(git -C "$GITROOT" rev-parse HEAD)"
outA="$(CLAUDE_PLUGIN_ROOT="$GITROOT" AUTO_TASK_UPDATE_DRYRUN=1 bash "$SCRIPT" 2>&1)"; rcA=$?
expect_eq       "A git dry-run exit 0"              "$rcA" "0"
expect_contains "A git dry-run reports git layout"  "$outA" "git dry-run"
expect_contains "A git dry-run plans ff-only pull"  "$outA" "pull --ff-only"
expect_eq       "A git dry-run mutates nothing"     "$(git -C "$GITROOT" rev-parse HEAD)" "$HEAD_BEFORE"

# --- Case A2: git tree, no upstream, REAL run -> clean fail, no mutation -----
outA2="$(CLAUDE_PLUGIN_ROOT="$GITROOT" bash "$SCRIPT" 2>&1)"; rcA2=$?
expect_eq       "A2 no-upstream real run nonzero"   "$rcA2" "1"
expect_contains "A2 no-upstream clear message"      "$outA2" "no upstream"
expect_eq       "A2 no-upstream mutates nothing"    "$(git -C "$GITROOT" rev-parse HEAD)" "$HEAD_BEFORE"

# --- Case B: marketplace (cache path), scope unresolved -> default user ------
MKT="$T/x/plugins/cache/auto-task-plugin/auto-task/0.1.13"; mkdir -p "$MKT"
MARK="$T/update-marker"
outB="$(CLAUDE_PLUGIN_ROOT="$MKT" AUTO_TASK_UPDATE_DRYRUN=1 FAKE_SCOPE=none UPDATE_MARKER="$MARK" \
        PATH="$BIN:$PATH" bash "$SCRIPT" 2>&1)"; rcB=$?
expect_eq       "B marketplace dry-run exit 0"          "$rcB" "0"
expect_contains "B marketplace layout"                  "$outB" "marketplace dry-run"
expect_contains "B default scope user"                  "$outB" "claude plugin update auto-task@auto-task-plugin --scope user"
expect_eq       "B did NOT call real update"            "$([ -e "$MARK" ] && echo called || echo no)" "no"

# --- Case B2: marketplace, scope parsed from `claude plugin list` = project --
outB2="$(CLAUDE_PLUGIN_ROOT="$MKT" AUTO_TASK_UPDATE_DRYRUN=1 FAKE_SCOPE=project \
         PATH="$BIN:$PATH" bash "$SCRIPT" 2>&1)"; rcB2=$?
expect_eq       "B2 marketplace dry-run exit 0"         "$rcB2" "0"
expect_contains "B2 parsed scope project"               "$outB2" "--scope project"

# --- Case C: copy/unknown layout (not git, not cache path) ------------------
PLAIN="$T/plain"; mkdir -p "$PLAIN"
outC="$(CLAUDE_PLUGIN_ROOT="$PLAIN" AUTO_TASK_UPDATE_DRYRUN=1 PATH="$BIN:$PATH" bash "$SCRIPT" 2>&1)"; rcC=$?
expect_eq          "C copy/unknown nonzero"             "$rcC" "1"
expect_contains    "C copy/unknown reports unsupported" "$outC" "unsupported"
expect_not_contains "C copy/unknown does NOT misroute"  "$outC" "claude plugin update"

# --- Case D: marketplace path but no usable claude CLI -> fail open ----------
# PATH limited to system dirs (bash/coreutils present) but excluding the dir
# where the real `claude` lives, so the marketplace path finds no usable CLI.
outD="$(CLAUDE_PLUGIN_ROOT="$MKT" PATH="/usr/bin:/bin" bash "$SCRIPT" 2>&1)"; rcD=$?
expect_eq       "D no-tool nonzero"                     "$rcD" "1"
expect_contains "D no-tool clear message"               "$outD" "claude CLI not found"

# --- Case E: cwd-independent self-location (no CLAUDE_PLUGIN_ROOT) -----------
# Copy the script into a throwaway git repo's hooks/ and run it by its REAL path
# from a foreign cwd; it must self-locate its root to that repo, not the cwd.
REPO="$T/repo"; mkdir -p "$REPO/hooks"; cp "$SCRIPT" "$REPO/hooks/apply-update.sh"; chmod +x "$REPO/hooks/apply-update.sh"
git init -q "$REPO"; git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
printf 'y\n' > "$REPO/g"; git -C "$REPO" add g hooks; git -C "$REPO" commit -qm init
outE="$(cd "$T" && env -u CLAUDE_PLUGIN_ROOT AUTO_TASK_UPDATE_DRYRUN=1 bash "$REPO/hooks/apply-update.sh" 2>&1)"; rcE=$?
expect_eq       "E self-locate exit 0"                  "$rcE" "0"
expect_contains "E self-located to its own repo root"   "$outE" "$REPO"
expect_contains "E self-locate detects git layout"      "$outE" "git dry-run"

# --- Case G: git REAL pull, already up to date -> noop, NOT a false "applied"
ORIGIN="$T/origin"; git init -q --bare "$ORIGIN"
CLONE="$T/clone"; git clone -q "$ORIGIN" "$CLONE" 2>/dev/null
git -C "$CLONE" config user.email t@t.t; git -C "$CLONE" config user.name t
printf 'v1\n' > "$CLONE/f"; git -C "$CLONE" add f; git -C "$CLONE" commit -qm v1
git -C "$CLONE" push -q origin HEAD 2>/dev/null
HEAD_G="$(git -C "$CLONE" rev-parse HEAD)"
outG="$(CLAUDE_PLUGIN_ROOT="$CLONE" bash "$SCRIPT" 2>&1)"; rcG=$?
expect_eq          "G up-to-date is NOT a false 'git applied'" "$(printf '%s' "$outG" | grep -c 'git applied')" "0"
expect_contains    "G up-to-date reports noop"             "$outG" "noop"
expect_eq          "G up-to-date exits nonzero"            "$rcG" "1"
expect_eq          "G up-to-date mutates nothing"          "$(git -C "$CLONE" rev-parse HEAD)" "$HEAD_G"

# --- Case H: git REAL pull, upstream ahead -> applied, HEAD advances --------
C2="$T/clone2"; git clone -q "$ORIGIN" "$C2" 2>/dev/null
git -C "$C2" config user.email t@t.t; git -C "$C2" config user.name t
printf 'v2\n' >> "$C2/f"; git -C "$C2" add f; git -C "$C2" commit -qm v2
git -C "$C2" push -q origin HEAD 2>/dev/null
outH="$(CLAUDE_PLUGIN_ROOT="$CLONE" bash "$SCRIPT" 2>&1)"; rcH=$?
expect_eq       "H fast-forward exits 0"              "$rcH" "0"
expect_contains "H fast-forward reports applied"      "$outH" "git applied"
expect_eq       "H HEAD advanced"                     "$([ "$(git -C "$CLONE" rev-parse HEAD)" != "$HEAD_G" ] && echo moved || echo same)" "moved"

# --- Case F: never-force static guarantee (mirrors AC #4c) ------------------
expect_contains "F uses --ff-only"                      "$(cat "$SCRIPT")" "--ff-only"
if grep -Eq -- 'reset --hard|--force|checkout -f|clean -[a-z]*f' "$SCRIPT"; then
  FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "F contains NO git forcing primitive"
else PASS=$((PASS+1)); printf '  PASS  %s\n' "F contains NO git forcing primitive"; fi

echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
