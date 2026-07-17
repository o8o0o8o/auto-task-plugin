#!/usr/bin/env bash
# guard-dangerous-ops.sh — the "destructive / out-of-envelope" interrupt gate.
#
# Registered as a PreToolUse hook on Bash. During an ACTIVE auto-task run, a
# command that falls OUTSIDE the safe action envelope (edit files, run
# tests/build/lint, git within the run's own worktree, read-only external calls)
# is BLOCKED (exit 2) so the model must surface it to the human instead of running
# it unattended. The insight: an autonomous code run should not need to run
# destructive / irreversible / external-side-effect commands, so rather than trying
# to detect "is this prod?", we deny a bounded set of dangerous verbs regardless of
# environment. The human either approves out of band, or the run is configured with
# `unattended_external: true` to opt the whole run out of this guard.
#
# FAIL POLICY (deliberately asymmetric — see hooks/lib/resolve-run-state.sh):
#   - fail-CLOSED on a MATCHED dangerous pattern (block), EVEN when jq is absent
#     (a raw-JSON matcher catches the pattern so a jq-less env can't defeat the
#     guard — mirrors enforce-gates' cmd_is_raw path);
#   - fail-OPEN for everything else (no run active, non-dangerous command, benign
#     target, the run's own-branch force-push, or `unattended_external:true`) —
#     the guard must NEVER police ordinary Bash, or users disable it and it is
#     worthless. A jq hiccup on a NON-matched command therefore just allows.

set -uo pipefail

input="$(cat)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/resolve-run-state.sh" 2>/dev/null || exit 0   # no lib -> cannot resolve -> allow

rrs_decode_command "$input"     # -> RRS_CMD, RRS_CMD_IS_RAW, RRS_HAS_JQ
cmd="$RRS_CMD"

# --- Is an auto-task run active on the current branch? ------------------------
# The guard only engages during a run; otherwise it is a no-op so normal shell use
# is never policed. A destructive command runs in the worktree where the run lives,
# so the CURRENT-branch STATE is the right signal (the cross-branch scan is for
# enforce-gates' land-on-main case, not here).
rrs_resolve_state "$input"      # -> RRS_PROJECT_DIR, RRS_BRANCH, RRS_STATE
state="$RRS_STATE"
[ -f "$state" ] || exit 0       # no run here -> allow
if [ "$RRS_HAS_JQ" -eq 1 ]; then
  jq empty "$state" 2>/dev/null || exit 0     # unreadable state -> not our business -> allow
  [ "$(jq -r '.approved // false' "$state" 2>/dev/null || echo false)" = "true" ] || exit 0
  [ "$(jq -r '.phase // ""' "$state" 2>/dev/null || echo "")" = "done" ] && exit 0
else
  # No jq: we cannot confirm approved/phase, so we cannot prove a run is active.
  # Do NOT manufacture a block from an unprovable run state (that would police
  # normal shell). Only the dangerous-pattern match below fires in this mode, and
  # only when a state file physically exists for the branch (checked above).
  :
fi

# --- Run-level opt-out -------------------------------------------------------
# `unattended_external: true` grants the run authority to run side-effecting
# commands without stopping. Resolve via settings.sh (honors AUTO_TASK_* test env).
settings_sh="$SCRIPT_DIR/settings.sh"
if [ -f "$settings_sh" ]; then
  if [ "$(bash "$settings_sh" get unattended_external 2>/dev/null || echo false)" = "true" ]; then
    exit 0
  fi
fi

# --- The dangerous envelope (bounded deny-list) ------------------------------
# Each alternative is a high-signal destructive / irreversible / external verb.
# Matched case-insensitively against the command (or the raw payload when jq is
# absent — the leading-boundary anchor differs but the verbs are the same).
lc="$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')"

# Leading command-boundary for anchored patterns (rm). In raw mode (jq absent) the
# verb is preceded by the JSON string's `"`, so include it — mirrors enforce-gates'
# cmd_is_raw dual regex, and is what keeps a jq-less env from un-matching. In
# decoded mode we omit `"` so a literal quoted string (echo "rm -rf /") does not
# false-positive.
# `rm` must sit at a COMMAND position: a command boundary, then an optional command
# wrapper and/or leading env-assignments (mirrors enforce-gates' wrap/envp). This
# catches `sudo rm -rf /`, `env FOO=bar rm -rf /`, `time rm …` while NOT matching
# `rm` inside a quoted string argument (`echo "run rm -rf /"`) — a bare-whitespace
# boundary would false-positive on the latter.
# Wrappers that may precede `rm` at a command position. Includes a shell -c /
# eval prefix (`bash -c "rm -rf /"`, `eval rm -rf /`) — otherwise a verb inside a
# `-c "…"` string sits after a quote, never at a command boundary, and slips the
# anchor. The optional trailing quote lets `-c "rm …"` / `eval 'rm …'` match.
rmwrap='((sudo|command|env|nice|doas|time|xargs)[[:space:]]+|(bash|sh|zsh|dash|ksh)[[:space:]]+-[a-z]*c[[:space:]]+["'"'"']?|eval[[:space:]]+["'"'"']?)*'
rmenvp='([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
if [ "$RRS_CMD_IS_RAW" -eq 1 ]; then rmbnd='(^|[;&|`"]|\$\()'; else rmbnd='(^|[;&|`]|\$\()'; fi

# Command-position prefix (raw-aware) for the CLI-based tiers below (SQL / infra /
# migration / deploy). Requiring the dangerous CLI to sit at a COMMAND boundary —
# start, a separator, or after a wrapper — is what stops ordinary read-only
# investigation (`grep "DELETE FROM …"`, `rg "drop table"`, `git grep …`, `sed`,
# `cat`) from tripping the guard: the SQL/migration verb inside a search tool's
# ARGUMENT is not at a command position. (The guard must never police read-only
# Bash — see the header.) `npx` is a wrapper so `npx prisma migrate deploy` matches.
# Command wrappers and leading env-assignments, INTERLEAVED in any order, so all of
# `sudo psql …`, `env PGPASSWORD=x psql …`, `VAR=v psql …`, and `DATABASE_URL=x npx
# prisma …` (env-assign THEN wrapper) resolve the client/CLI to a command position.
cpos="${rmbnd}[[:space:]]*(((sudo|command|env|nice|doas|time|xargs|npx)|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)[[:space:]]+)*"

danger=""
# rm -rf on a DANGEROUS target: absolute path, home, root, wildcard, . / .. — NOT
# a relative build dir (node_modules/dist/build/.next/coverage/target). The target
# test keys on the first token after the flags.
# Dangerous rm target = absolute (/…), home (~ / $HOME), bare wildcard (*), the cwd
# itself (bare `.`), or a parent-escaping path (`..` / `../…`). A relative subdir
# like `./node_modules` or `dist` is BENIGN build cleanup and must NOT match.
rmflags='(-[a-z]*r[a-z]*f|-[a-z]*f[a-z]*r|-r[[:space:]]+-f|-f[[:space:]]+-r|-r[[:space:]]+--force|--force[[:space:]]+-r|-f[[:space:]]+--recursive|--recursive[[:space:]]+-f|--recursive[[:space:]]+--force|--force[[:space:]]+--recursive)'
if printf '%s' "$lc" | grep -qE "${rmbnd}[[:space:]]*${rmwrap}${rmenvp}rm[[:space:]]+${rmflags}([[:space:]]+--?[a-z-]+)*([[:space:]]+--)?[[:space:]]+[\"']?(/|~|\\\$\{?(home|pwd)|\*([[:space:]]|\$)|\.([[:space:]]|\$)|\.\.(/|[[:space:]]|\$))"; then
  danger="rm -rf on a dangerous target"
fi
# Destructive git
# `git([flag [value]])* <subcommand>` — allow a value token after a global flag
# (`git -C <path> push …`, `git -c k=v push …`); a bare `-[^space]+`-only walk
# stops at the value and skips the subcommand (the enforce-gates `opts` sub-pattern
# handles this; the guard must too).
if [ -z "$danger" ] && printf '%s' "$lc" | grep -qE 'git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+(reset[[:space:]]+--hard|clean[[:space:]]+-[a-z]*f|push[[:space:]]+.*(--delete|--force(-with-lease)?|-f([[:space:]]|$)|--mirror|[[:space:]]\+[^[:space:]]))'; then
  # force-push / delete-push: dangerous ONLY when it targets a protected/default
  # branch (main/master). A force-push of the run's OWN worktree branch is fine.
  # `--mirror` and `--all …--force` clobber ALL branches (incl. main) without
  # naming it, so treat them as protected regardless of an explicit main/master.
  if printf '%s' "$lc" | grep -qE 'push'; then
    if printf '%s' "$lc" | grep -qE '(main|master)([[:space:]]|$|:)' \
       || printf '%s' "$lc" | grep -qE 'push[[:space:]]+--force(-with-lease)?[[:space:]]*$' \
       || printf '%s' "$lc" | grep -qE 'push[[:space:]]+.*--mirror' \
       || printf '%s' "$lc" | grep -qE 'push[[:space:]]+.*--all([[:space:]]|$)' ; then
      danger="force/delete/mirror push to a protected branch"
    fi
  else
    danger="destructive git (reset --hard / clean -f)"
  fi
fi
# SQL DDL / mass delete — require a DB CLIENT at command position AND a destructive
# SQL verb, so `grep "DELETE FROM …"` / `rg "drop table"` (verb inside a search
# arg, no DB client at command position) do NOT false-positive.
sqlcli='(psql|mysql|mariadb|sqlite3?|mongosh|mongo|cockroach|clickhouse-client|duckdb|pgcli|mycli|usql|sqlcmd|psql|bq)'
if [ -z "$danger" ] && printf '%s' "$lc" | grep -qE "${cpos}${sqlcli}([[:space:]]|$)" \
   && printf '%s' "$lc" | grep -qE '(drop[[:space:]]+(table|database|schema)[[:space:]]|truncate[[:space:]]+(table[[:space:]]+)?[a-z0-9_"]|delete[[:space:]]+from[[:space:]])'; then
  danger="destructive SQL (DROP/TRUNCATE/DELETE FROM)"
fi
# Infra deletes / applies — CLI at command position (so `grep "terraform destroy"`
# does not match); rm/delete matched as whole tokens after the CLI (so `aws
# cloudformation …` / `aws s3 ls …farm…` do not false-positive); flags between the
# CLI and the verb allowed (`kubectl -n prod delete …`).
if [ -z "$danger" ] && printf '%s' "$lc" | grep -qE "${cpos}(kubectl([[:space:]]+[^[:space:]]+)*[[:space:]]+delete|terraform[[:space:]]+(destroy|apply)|aws([[:space:]]+[^[:space:]]+)*[[:space:]]+(rm|delete|delete-[a-z])|gcloud([[:space:]]+[^[:space:]]+)*[[:space:]]+delete|az([[:space:]]+[^[:space:]]+)*[[:space:]]+delete)"; then
  danger="infrastructure delete/apply"
fi
# Migration apply — migration CLI at command position + a WRITE migrate verb;
# read-only status/list (`npm run db:migrate:status`, `… migrate status`) is
# excluded (the npm-run form requires the script name to END at `migrate`).
if [ -z "$danger" ] && { \
     printf '%s' "$lc" | grep -qE "${cpos}(prisma[[:space:]]+migrate[[:space:]]+(deploy|reset)|drizzle-kit[[:space:]]+push|alembic[[:space:]]+(upgrade|downgrade)|knex[[:space:]]+migrate:latest|sequelize[[:space:]]+db:migrate([[:space:]]|\$)|flyway[[:space:]]+migrate([[:space:]]|\$)|atlas[[:space:]]+migrate[[:space:]]+apply|goose[[:space:]]+up|dbmate[[:space:]]+up)" \
  || printf '%s' "$lc" | grep -qE "${cpos}(bundle[[:space:]]+exec[[:space:]]+)?rails[[:space:]].*db:migrate([[:space:]]|\$)" \
  || printf '%s' "$lc" | grep -qE "${cpos}php[[:space:]]+artisan[[:space:]]+migrate([[:space:]]|\$)" \
  || printf '%s' "$lc" | grep -qE "${cpos}(npm|pnpm|yarn)[[:space:]]+run[[:space:]]+[^[:space:]]*migrate([[:space:]]|\$)" ; }; then
  danger="database migration apply"
fi
# Deploy / publish — CLI at command position; the read-only `--dry-run` form is
# excluded (`npm publish --dry-run`, `vercel deploy --dry-run`).
if [ -z "$danger" ] \
   && printf '%s' "$lc" | grep -qE "${cpos}((npm|pnpm|yarn)[[:space:]]+publish|vercel[[:space:]]+.*(--prod|deploy)|netlify[[:space:]]+deploy.*--prod|gh[[:space:]]+release[[:space:]]+create|docker[[:space:]]+push|fly[[:space:]]+deploy|railway[[:space:]]+up)" \
   && ! printf '%s' "$lc" | grep -qE '\-\-dry-run'; then
  danger="deploy/publish (external side effect)"
fi

if [ -n "$danger" ]; then
  printf 'Blocked by auto-task-plugin (dangerous-ops guard): this command is OUTSIDE the safe action envelope for an unattended run.\n  Detected: %s\n  Command: %s\n\nAn autonomous auto-task run should not run destructive / irreversible / external-side-effect commands without a human eye. Options:\n  1. Surface this to the user and get explicit approval before running it out of band; OR\n  2. If this whole run is trusted to act externally, set unattended_external=true for the project (bash hooks/settings.sh set unattended_external true) and retry.\n' "$danger" "$cmd" >&2
  exit 2
fi

exit 0
