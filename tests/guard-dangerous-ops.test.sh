#!/usr/bin/env bash
# Focused test for hooks/guard-dangerous-ops.sh — the destructive/out-of-envelope
# interrupt gate.
#
# Asserts (independent behavioral checks — crafted payloads piped into the hook,
# exit code is the observable): during an ACTIVE run, dangerous/out-of-envelope
# commands are BLOCKED (exit 2); benign commands, own-branch force-push, a run that
# is not active, and unattended_external=true all ALLOW (exit 0); and a genuinely
# jq-absent environment still catches dangerous commands (raw-mode), i.e. missing
# jq cannot defeat the guard.
#
# git ops here are `git init`/`checkout` only (no `git commit`), so the
# enforce-gates PreToolUse hook — which matches `git commit` — never intercepts the
# setup, and the guard's own resolution needs only a branch + toplevel.
#
# Usage: tests/guard-dangerous-ops.test.sh   Exit 0 = all passed.

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
GUARD="$HOOKS/guard-dangerous-ops.sh"
for t in git jq; do command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not installed"; exit 0; }; done
[ -f "$GUARD" ] || { echo "FAIL: $GUARD missing"; exit 1; }

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-56s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-56s got=%s want=%s\n' "$1" "$2" "$3"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cd "$T"
git init -q -b main 2>/dev/null || git init -q
git checkout -q -b feat/x 2>/dev/null
SD=".auto-task/feat/x"; mkdir -p "$SD"; ST="$SD/STATE.json"
active(){ printf '{"approved":true,"phase":"execute","gates":{}}' > "$ST"; }
payload(){ printf '{"tool_input":{"command":%s},"cwd":"%s"}' "$(jq -Rn --arg c "$1" '$c')" "$T"; }
# run the guard with the crafted command; echo exit code
g(){ payload "$1" | CLAUDE_PROJECT_DIR="$T" bash "$GUARD" >/dev/null 2>&1; echo $?; }

echo "================ guard-dangerous-ops.sh ================"
bash -n "$GUARD"; expect "bash -n clean" "$?" "0"

# --- active run: dangerous commands BLOCK (exit 2) ---------------------------
active
expect "force-push to main -> block"      "$(g 'git push --force origin main')" "2"
expect "rm -rf / -> block"                "$(g 'rm -rf /')"                     "2"
expect "rm -rf \$HOME -> block"            "$(g 'rm -rf $HOME/x')"               "2"
expect "DROP TABLE -> block"              "$(g 'psql -c "DROP TABLE users"')"   "2"
expect "TRUNCATE -> block"               "$(g 'psql -c "TRUNCATE TABLE t"')"    "2"
expect "kubectl delete -> block"         "$(g 'kubectl delete pod p')"         "2"
expect "terraform destroy -> block"      "$(g 'terraform destroy -auto-approve')" "2"
expect "terraform apply -> block"        "$(g 'terraform apply')"              "2"
expect "prisma migrate deploy -> block"  "$(g 'npx prisma migrate deploy')"    "2"
expect "npm publish -> block"            "$(g 'npm publish')"                  "2"
expect "git reset --hard -> block"       "$(g 'git reset --hard HEAD~2')"      "2"

# --- active run: benign / in-envelope commands ALLOW (exit 0) ----------------
expect "npm test -> allow"               "$(g 'npm test')"                     "0"
expect "rm -rf ./node_modules -> allow"  "$(g 'rm -rf ./node_modules')"        "0"
expect "rm -rf dist -> allow"            "$(g 'rm -rf dist')"                  "0"
expect "git commit -> allow (guard)"     "$(g 'git commit -m x')"              "0"
expect "own-branch force-push -> allow"  "$(g 'git push --force origin feat/x')" "0"
expect "pnpm build -> allow"             "$(g 'pnpm build')"                   "0"
expect "echo quoted rm -> allow"         "$(g 'echo "rm -rf /"')"              "0"

# --- no active run: allow even dangerous ------------------------------------
rm -f "$ST"
expect "no run: rm -rf / -> allow"       "$(g 'rm -rf /')"                     "0"
active
# done run is not active
printf '{"approved":true,"phase":"done","gates":{}}' > "$ST"
expect "done run: rm -rf / -> allow"     "$(g 'rm -rf /')"                     "0"
# unapproved run is not active
printf '{"approved":false,"phase":"define","gates":{}}' > "$ST"
expect "unapproved run: terraform destroy -> allow" "$(g 'terraform destroy')" "0"

# --- unattended_external=true: opt the run out (allow dangerous) -------------
active
UF="$T/unattended.json"; printf '{"unattended_external":true}' > "$UF"
gx(){ payload "$1" | AUTO_TASK_SETTINGS_FILE="$UF" CLAUDE_PROJECT_DIR="$T" bash "$GUARD" >/dev/null 2>&1; echo $?; }
expect "unattended_external: rm -rf / -> allow" "$(gx 'rm -rf /')" "0"

# --- jq ABSENT (raw mode): dangerous still caught, benign still allowed ------
# Build a bin dir with everything EXCEPT jq, so only jq is missing.
FB="$T/fakebin"; mkdir -p "$FB"
for d in /bin /usr/bin /opt/homebrew/bin /usr/local/bin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do b="${f##*/}"; [ "$b" = jq ] && continue; [ -e "$FB/$b" ] || ln -s "$f" "$FB/$b" 2>/dev/null; done
done
if PATH="$FB" command -v jq >/dev/null 2>&1; then
  echo "  SKIP  jq-absent case (could not hide jq on this PATH)"
else
  active
  gj(){ payload "$1" | PATH="$FB" CLAUDE_PROJECT_DIR="$T" bash "$GUARD" >/dev/null 2>&1; echo $?; }
  expect "jq-absent: rm -rf / -> block"        "$(gj 'rm -rf /')"          "2"
  expect "jq-absent: terraform destroy -> block" "$(gj 'terraform destroy')" "2"
  expect "jq-absent: npm test -> allow"        "$(gj 'npm test')"          "0"
fi

# --- regression cases from code review -------------------------------------
active
# B2: wrapper before rm must not defeat the anchor
expect "sudo rm -rf / -> block"          "$(g 'sudo rm -rf /')"                 "2"
expect "command rm -rf ~ -> block"       "$(g 'command rm -rf ~')"              "2"
expect "env FOO=bar rm -rf /var -> block" "$(g 'env FOO=bar rm -rf /var/data')" "2"
expect "time rm -rf ~/.config -> block"  "$(g 'time rm -rf ~/.config')"         "2"
# wrapper allowlist must NOT false-positive on rm inside a quoted string arg
expect "echo run rm -rf / (in string) -> allow" "$(g 'echo "run rm -rf / carefully"')" "0"
expect "rm -r --force / (mixed flags) -> block" "$(g 'rm -r --force /')"         "2"
expect "rm -rf -- / (end-of-opts) -> block"     "$(g 'rm -rf -- /')"            "2"
# B3: aws read-only commands must NOT be blocked (substring rm/delete)
expect "aws cloudformation list -> allow" "$(g 'aws cloudformation list-stacks')" "0"
expect "aws s3 ls my-farm-bucket -> allow" "$(g 'aws s3 ls s3://my-farm-bucket')" "0"
expect "aws s3 rm (real) -> block"       "$(g 'aws s3 rm s3://b/k')"            "2"
expect "aws ec2 delete-vpc -> block"     "$(g 'aws ec2 delete-vpc --vpc-id v')" "2"
# R3: flags between kubectl and delete; +refspec force push
expect "kubectl -n prod delete -> block" "$(g 'kubectl -n prod delete deploy api')" "2"
expect "kubectl get (no delete) -> allow" "$(g 'kubectl -n prod get pods')"      "0"
expect "git push origin +main (+refspec) -> block" "$(g 'git push origin +main')" "2"
expect "git push origin +feat/x (own +refspec) -> allow" "$(g 'git push origin +feat/x')" "0"

# --- Gate B adversarial regressions ----------------------------------------
active
# shell -c / eval must not smuggle a dangerous verb past the anchor
expect "bash -c rm -rf / -> block"       "$(g 'bash -c "rm -rf /"')"            "2"
expect "sh -c rm -rf / -> block"         "$(g "sh -c 'rm -rf /'")"              "2"
expect "eval rm -rf / -> block"          "$(g 'eval rm -rf /')"                 "2"
expect "eval \"rm -rf \$HOME\" -> block"  "$(g 'eval "rm -rf $HOME"')"           "2"
expect "bash -c npm test -> allow"       "$(g 'bash -c "npm test"')"            "0"
# braced variable target
expect "rm -rf \${HOME} -> block"         "$(g 'rm -rf ${HOME}')"                "2"
expect "rm -rf \"\${HOME}/x\" -> block"    "$(g 'rm -rf "${HOME}/x"')"            "2"
# git -C / -c global flag-with-value before a destructive push
expect "git -C . push --force main -> block" "$(g 'git -C . push --force origin main')" "2"
expect "git -c k=v push --force main -> block" "$(g 'git -c user.name=x push --force origin main')" "2"
expect "git -C sub push feat/x -> allow" "$(g 'git -C sub push origin feat/x')"  "0"
# force flag positioned AFTER the refspec must also be caught
expect "push origin main --force (after refspec) -> block" "$(g 'git push origin main --force')" "2"
expect "push origin main --force-with-lease -> block" "$(g 'git push origin main --force-with-lease')" "2"
expect "push origin feat/x --force (own branch) -> allow" "$(g 'git push origin feat/x --force')" "0"

# --- Gate B round 3: command-position anchoring (no over-block of read-only) ---
active
# read-only investigation of SQL/migration/infra code must NOT block
expect "grep DELETE FROM -> allow"       "$(g 'grep -rn "DELETE FROM users" src/')" "0"
expect "git grep DELETE FROM -> allow"   "$(g 'git grep -n "DELETE FROM orders"')"  "0"
expect "rg drop table -> allow"          "$(g 'rg "drop table if exists foo" migrations/')" "0"
expect "grep terraform destroy -> allow" "$(g 'grep -rn "terraform destroy" infra/')" "0"
expect "npm run db:migrate:status -> allow" "$(g 'npm run db:migrate:status')"       "0"
expect "npm publish --dry-run -> allow"  "$(g 'npm publish --dry-run')"              "0"
# but the real destructive forms still block (anchored to a CLI at command position)
expect "psql -c DROP TABLE -> block"     "$(g 'psql -c "DROP TABLE users"')"         "2"
expect "psql -c DELETE FROM -> block"    "$(g 'psql -h db -c "DELETE FROM sessions"')" "2"
expect "npm run db:migrate -> block"     "$(g 'npm run db:migrate')"                 "2"
expect "rails db:migrate -> block"       "$(g 'rails db:migrate')"                   "2"
# whole-repo force push clobbers main without naming it -> block
expect "git push --all --force -> block" "$(g 'git push --all --force origin')"      "2"
expect "git push --mirror -> block"      "$(g 'git push --mirror origin')"           "2"
# env-assignment / wrapper before the CLI (any order) must not defeat cpos
expect "env VAR=x psql TRUNCATE -> block" "$(g 'env PGPASSWORD=x psql -c "TRUNCATE t"')" "2"
expect "VAR=x psql DROP -> block"        "$(g 'PGPASSWORD=x psql -c "DROP TABLE x"')" "2"
expect "VAR=x npx prisma deploy -> block" "$(g 'DATABASE_URL=x npx prisma migrate deploy')" "2"
expect "VAR=x psql SELECT -> allow"      "$(g 'PGPASSWORD=x psql -c "SELECT 1"')"    "0"
expect "VAR=x npm db:migrate:status -> allow" "$(g 'DATABASE_URL=x npm run db:migrate:status')" "0"

echo "--------------------------------------------------------"
echo "guard-dangerous-ops.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
