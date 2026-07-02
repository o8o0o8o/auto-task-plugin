#!/usr/bin/env bash
# Integration test for the auto-task ENFORCEMENT SPINE.
#
# Drives a real STATE.json through the full documented phase/gate lifecycle in a
# throwaway git repo and asserts the real hooks (enforce-gates.sh + the Stop
# hook) behave correctly at each transition, for both STANDARD and LIGHT tiers.
#
# What this DOES cover: the mechanical contract between the state machine and the
# hooks — commit blocked until gates pass, tier-specific Gate B requirement,
# review-staleness, the wrong-review-tool block, and every Stop-hook yield/block
# decision. What it does NOT cover: whether the model correctly follows the skill
# prose (that requires a live `/auto-task` run with the human gate).
#
# Usage: tests/enforcement-spine.test.sh   (requires git + jq, like the hooks)
# Exit 0 = all assertions passed.

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
GATE="$HOOKS/enforce-gates.sh"
STOP="$HOOKS/prevent-mid-protocol-stall.sh"
ATTR="$HOOKS/block-ai-attribution.sh"

for tool in git jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not installed (required by the hooks under test)"; exit 0; }
done

PASS=0; FAIL=0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cd "$T"
git init -q; git config user.email t@t.t; git config user.name t; git checkout -q -b feat/widget
printf 'export const n = 1;\n' > app.js; git add app.js; git commit -qm init
BASE="$(git rev-parse HEAD)"
SD=".auto-task/feat/widget"; mkdir -p "$SD"; ST="$SD/STATE.json"
COMMIT='{"tool_input":{"command":"git commit -m wip"}}'

gate(){ printf '%s' "$COMMIT" | CLAUDE_PROJECT_DIR="$T" bash "$GATE" >/dev/null 2>&1; echo $?; }
grun(){ printf '%s' "$1" | CLAUDE_PROJECT_DIR="$T" bash "$GATE" >/dev/null 2>&1; echo $?; }
attr(){ printf '%s' "$1" | bash "$ATTR" >/dev/null 2>&1; echo $?; }
stop(){ local o; o="$(CLAUDE_PROJECT_DIR="$T" bash "$STOP" 2>/dev/null)"; [ -z "$o" ] && { echo allow; return; }; printf '%s' "$o" | jq -r '.decision // "allow"' 2>/dev/null; }
# Must use the SAME pinned flags as enforce-gates.sh, or the recorded sha won't
# match the hook's recompute under non-default git config.
DIFF_FLAGS='--no-color --no-ext-diff --no-textconv --no-renames --diff-algorithm=myers --src-prefix=a/ --dst-prefix=b/'
sha(){ git diff $DIFF_FLAGS "$BASE" | git hash-object --stdin; }
setstate(){ local tmp; tmp="$(jq "$1" "$ST")"; printf '%s' "$tmp" > "$ST"; }
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-54s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-54s got=%s want=%s\n' "$1" "$2" "$3"; fi; }

echo "================ STANDARD-tier run ================"
cat > "$ST" <<EOF
{"approved":false,"phase":"define","expected_next_action":null,"base":"$BASE","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
EOF
expect "P1 setup: stop allowed (not approved)"            "$(stop)" "allow"
expect "P1 setup: commit allowed (not approved)"          "$(gate)" "0"
setstate '.expected_next_action="user-approval"'
expect "P1 plan gate: stop allowed (user-approval)"       "$(stop)" "allow"
setstate '.approved=true|.phase="execute"|.expected_next_action="auto-continue"'
expect "P2 execute: stop BLOCKED (auto-continue)"         "$(stop)" "block"
expect "P2 execute: commit BLOCKED (no gates)"            "$(gate)" "2"
printf 'export const n = 2;\nexport const m = 3;\n' > app.js
setstate '.phase="self-verify"|.gates.self_verify={"passed":true}'
expect "P3 self-verify: commit still BLOCKED"             "$(gate)" "2"
expect "P3 self-verify: stop still BLOCKED"               "$(stop)" "block"
setstate '.phase="gate-a"|.gates.gate_a={"passed":true}'
expect "Gate A pass: commit still BLOCKED (no review)"    "$(gate)" "2"
RSHA="$(sha)"
setstate "$(printf '.phase="review"|.gates.code_review={"passed":true,"tool":"skill:auto-task-code-review","clean_pass_after_last_fix":true,"reviewed_diff_sha":"%s"}' "$RSHA")"
expect "P4 review clean: commit BLOCKED (STANDARD->Gate B)" "$(gate)" "2"
setstate '.phase="gate-b"|.gates.gate_b={"passed":true}'
expect "Gate B pass: commit ALLOWED"                      "$(gate)" "0"
printf 'export const n = 2;\nexport const m = 3;\nexport const STRAY = 9;\n' > app.js
expect "Staleness: post-review edit BLOCKS commit"        "$(gate)" "2"
printf 'export const n = 2;\nexport const m = 3;\n' > app.js
expect "Staleness: revert to reviewed diff ALLOWS"        "$(gate)" "0"
setstate '.phase="handover"|.expected_next_action="user-push-prompt"'
expect "P5 push prompt: stop ALLOWED"                     "$(stop)" "allow"
setstate '.phase="done"|.expected_next_action=null'
expect "Done: stop ALLOWED"                               "$(stop)" "allow"
expect "Done: commit ALLOWED (phase=done)"                "$(gate)" "0"

echo "================ LIGHT-tier run (Gate B skipped) ================"
git checkout -q -b fix/typo; SD2=".auto-task/fix/typo"; mkdir -p "$SD2"; ST2="$SD2/STATE.json"
B2="$(git rev-parse HEAD)"; RSHA2="$(git diff $DIFF_FLAGS "$B2" | git hash-object --stdin)"
gateL(){ printf '%s' "$COMMIT" | CLAUDE_PROJECT_DIR="$T" bash "$GATE" >/dev/null 2>&1; echo $?; }
cat > "$ST2" <<EOF
{"approved":true,"phase":"review","expected_next_action":"auto-continue","base":"$B2","effort":{"tier":"light"},
 "gates":{"code_review":{"passed":true,"tool":"skill:auto-task-code-review","clean_pass_after_last_fix":true,"reviewed_diff_sha":"$RSHA2"},
          "gate_b":{"passed":false,"skipped_reason":"tier=light"}}}
EOF
expect "LIGHT: commit ALLOWED (Gate B skipped)"           "$(gateL)" "0"
tmp="$(jq '.gates.code_review.tool="agent:code-reviewer"' "$ST2")"; printf '%s' "$tmp" > "$ST2"
expect "LIGHT: wrong review tool BLOCKED"                 "$(gateL)" "2"

echo "================ Raw-mode commit detection (jq decode empty) ================"
# Payloads with no .tool_input.command force the raw-JSON fallback regex.
# Restore feat/widget to a fully-blocking state so a *detected* commit blocks.
git checkout -q feat/widget
printf 'export const n = 2;\nexport const m = 3;\n' > app.js
cat > "$ST" <<EOF
{"approved":true,"phase":"execute","expected_next_action":"auto-continue","base":"$BASE","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
EOF
# A real commit verb at the value's opening quote → detected → blocked.
expect "Raw: bare commit payload BLOCKED"                 "$(grun '{"x":"git commit -m wip"}')" "2"
# Commit after a shell separator → detected → blocked.
expect "Raw: chained commit (&&) BLOCKED"                 "$(grun '{"x":"cd app && git commit -m wip"}')" "2"
# Prose mention mid-string (not at a command boundary) → NOT a commit → allowed.
expect "Raw: prose 'git commit' NOT blocked"              "$(grun '{"x":"please read the git commit guidelines"}')" "0"

echo "================ Stall-breaker (Stop hook soft-lock release) ================"
# A valid mid-pipeline state blocks every turn-end. With AUTO_TASK_STALL_LIMIT
# low, repeated stops in the SAME state must eventually RELEASE to avoid a
# soft-lock; a state change must reset the counter so blocking resumes.
cat > "$ST" <<EOF
{"approved":true,"phase":"review","expected_next_action":"auto-continue","base":"$BASE","effort":{"tier":"standard"},
 "iteration":{"review":0,"fix":0},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
EOF
rm -f "$SD/.stall-block-count"
stopS(){ local o; o="$(CLAUDE_PROJECT_DIR="$T" AUTO_TASK_STALL_LIMIT=3 bash "$STOP" 2>/dev/null)"; [ -z "$o" ] && { echo allow; return; }; printf '%s' "$o" | jq -r '.decision // "allow"' 2>/dev/null; }
expect "Stall: block #1 (count<limit)"                    "$(stopS)" "block"
expect "Stall: block #2 (count<limit)"                    "$(stopS)" "block"
expect "Stall: release #3 (count>=limit)"                 "$(stopS)" "allow"
setstate '.iteration.fix=1'   # state advanced → fresh block sequence
expect "Stall: blocking resumes after a release"         "$(stopS)" "block"

echo "================ AI-attribution block ================"
expect "Attr: Co-Authored-By Claude BLOCKED"              "$(attr '{"tool_input":{"command":"git commit -m \"x\n\nCo-Authored-By: Claude <x@y>\""}}')" "2"
expect "Attr: clean commit ALLOWED"                       "$(attr '{"tool_input":{"command":"git commit -m clean"}}')" "0"

echo "================ Fail-open / fail-closed edges ================"
git checkout -q feat/widget
echo '{bad json' > "$ST"
expect "Malformed STATE.json: stop ALLOWS (no soft-lock)" "$(stop)" "allow"
printf '%s' "$COMMIT" | CLAUDE_PROJECT_DIR="$T" bash "$GATE" >/dev/null 2>&1; expect "Malformed STATE.json: commit BLOCKED (fail closed)" "$?" "2"

echo "================ Worktree / subdir / nested-repo resolution ================"
# Each assertion sets its OWN state and discriminates the fix from a revert — no
# reliance on state leaked from earlier blocks. CWD and CLAUDE_PROJECT_DIR are
# controlled per case.
git checkout -q feat/widget
# Give MAIN a VALID ungated mid-pipeline state (used by the nested-repo case below) —
# set explicitly, not the malformed leftover from the Fail-open block above.
cat > "$ST" <<EOF
{"approved":true,"phase":"execute","expected_next_action":"auto-continue","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
EOF
# Linked worktree on its own branch, with a nested subdirectory.
WT="$T/wt"; git worktree add -q "$WT" -b wt-feature >/dev/null 2>&1
SUB="$WT/pkg/sub"; mkdir -p "$SUB"
SDW="$WT/.auto-task/wt-feature"; mkdir -p "$SDW"
# Helpers: run a hook from an explicit CWD ($1) with CLAUDE_PROJECT_DIR UNSET.
gateAt(){ printf '%s' "$COMMIT" | ( cd "$1" && unset CLAUDE_PROJECT_DIR && bash "$GATE" ) >/dev/null 2>&1; echo $?; }
stopAt(){ local o; o="$( cd "$1" && unset CLAUDE_PROJECT_DIR && bash "$STOP" 2>/dev/null )"; [ -z "$o" ] && { echo allow; return; }; printf '%s' "$o" | jq -r '.decision // "allow"' 2>/dev/null; }
# (1) WT-subdir-gate: ungated worktree state; CWD = worktree SUBDIR; CPD unset -> BLOCK.
#     Discriminates the fix: old `$PWD`=subdir resolution finds no state and fail-opens (0);
#     resolving the toplevel of the base finds the worktree root and blocks (2).
cat > "$SDW/STATE.json" <<EOF
{"approved":true,"phase":"execute","expected_next_action":"auto-continue","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
EOF
expect "WT-subdir-gate: ungated commit BLOCKED from worktree subdir (CPD unset)" "$(gateAt "$SUB")" "2"
# (2) WT-subdir-stall: same location + state, mid-pipeline turn-end -> BLOCK.
expect "WT-subdir-stall: mid-pipeline turn-end BLOCKED from worktree subdir" "$(stopAt "$SUB")" "block"
# (3) WT-subdir-allow (sanity control): gates-met worktree state (LIGHT, no base/sha so the
#     staleness check is skipped); CWD = worktree subdir; CPD unset -> ALLOWED.
cat > "$SDW/STATE.json" <<EOF
{"approved":true,"phase":"review","expected_next_action":"auto-continue","effort":{"tier":"light"},
 "gates":{"code_review":{"passed":true,"tool":"skill:auto-task-code-review","clean_pass_after_last_fix":true},
          "gate_b":{"passed":false,"skipped_reason":"tier=light"}}}
EOF
expect "WT-subdir-allow: gates-met commit ALLOWED from worktree subdir (CPD unset)" "$(gateAt "$SUB")" "0"
# (4) WT-nested-gate: a nested git repo embedded under MAIN; commit from inside it with
#     CLAUDE_PROJECT_DIR=main(=$T). Resolution must HONOR CPD ($T, ungated) and BLOCK — not
#     retarget the nested repo and fail open. Discriminates against show-toplevel-from-CWD,
#     which would resolve the nested repo, find no state, and allow (0) — the Gate B finding.
NESTED="$T/vendor/embedded"; mkdir -p "$NESTED"
( cd "$NESTED" && git init -q && git config user.email t@t.t && git config user.name t && printf 'y\n' > g && git add g && git commit -qm n ) >/dev/null 2>&1
gateNested(){ printf '%s' "$COMMIT" | ( cd "$NESTED" && CLAUDE_PROJECT_DIR="$T" bash "$GATE" ) >/dev/null 2>&1; echo $?; }
expect "WT-nested-gate: commit from nested repo honors CLAUDE_PROJECT_DIR, BLOCKED (no fail-open)" "$(gateNested)" "2"
git worktree remove --force "$WT" >/dev/null 2>&1 || true

echo "================ Worktree-isolated run, CLAUDE_PROJECT_DIR pinned to MAIN (the reported false positive) ================"
# auto-task isolates every run in a linked worktree, but the harness keeps
# CLAUDE_PROJECT_DIR pinned to the MAIN checkout. MAIN sits on a branch with no
# active run while ANOTHER branch has an active run (leftover state) — so the old
# resolution inspected MAIN and fired a bogus checkout-drift block. The fix
# retargets to the worktree (same repo: shared git common-dir, different
# toplevel), so the worktree's OWN gates govern. Its own isolated repo so MAIN's
# sibling state is exactly the drift trigger and nothing else interferes.
WARN="$HOOKS/warn-checkout-drift.sh"
INJECT="$HOOKS/inject-history-reminder.sh"
WI="$(mktemp -d)"
(
  cd "$WI"
  git init -q; git config user.email t@t.t; git config user.name t; git checkout -q -b main
  printf 'x\n' > a.js; git add a.js; git commit -qm init
  # An ACTIVE run on ANOTHER branch recorded in MAIN's .auto-task/ — the drift trigger.
  mkdir -p .auto-task/feat/sibling
  cat > .auto-task/feat/sibling/STATE.json <<JSON
{"approved":true,"phase":"execute","expected_next_action":"auto-continue","branch":"feat/sibling","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
JSON
  git worktree add -q wt -b feat/iso >/dev/null 2>&1
) >/dev/null 2>&1
WIWT="$WI/wt"; WISD="$WIWT/.auto-task/feat/iso"; mkdir -p "$WISD"
WIB="$(git -C "$WIWT" rev-parse HEAD)"
RWISHA="$(git -C "$WIWT" diff $DIFF_FLAGS "$WIB" | git hash-object --stdin)"
# gate from the worktree; CPD pinned to MAIN; payload carries NO .cwd → op_cwd
# falls back to $PWD=worktree (exercises the $PWD signal path).
wigate(){ printf '%s' "$COMMIT" | ( cd "$WIWT" && CLAUDE_PROJECT_DIR="$WI" bash "$GATE" ) >/dev/null 2>&1; echo $?; }
# (A) gates-met worktree run → ALLOWED. Pre-fix: BLOCKED (2) by the bogus drift guard.
cat > "$WISD/STATE.json" <<JSON
{"approved":true,"phase":"gate-b","expected_next_action":"auto-continue","branch":"feat/iso","base":"$WIB","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":true,"tool":"skill:auto-task-code-review","clean_pass_after_last_fix":true,"reviewed_diff_sha":"$RWISHA"},
          "gate_b":{"passed":true}}}
JSON
expect "WT-iso-allow: gates-met commit ALLOWED (CPD=main, active sibling run)"  "$(wigate)" "0"
# (B) ungated worktree run → BLOCKED: gate enforcement survives the retarget.
cat > "$WISD/STATE.json" <<JSON
{"approved":true,"phase":"execute","expected_next_action":"auto-continue","branch":"feat/iso","base":"$WIB","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
JSON
expect "WT-iso-gate: ungated commit BLOCKED (retargeted, gates enforced)"       "$(wigate)" "2"
# (C) AC#8: retarget driven by the JSON .cwd field while the hook $PWD is neutral
# (a dir inside MAIN, which by itself resolves to MAIN → no retarget). Only .cwd
# points at the worktree, so an ALLOW here proves the .cwd signal path works.
NEUTRAL="$WI/neutral"; mkdir -p "$NEUTRAL"
CWDPAY="$(jq -nc --arg c "$WIWT" '{tool_input:{command:"git commit -m wip"}, cwd:$c}')"
wigateCwd(){ printf '%s' "$CWDPAY" | ( cd "$NEUTRAL" && CLAUDE_PROJECT_DIR="$WI" bash "$GATE" ) >/dev/null 2>&1; echo $?; }
cat > "$WISD/STATE.json" <<JSON
{"approved":true,"phase":"gate-b","expected_next_action":"auto-continue","branch":"feat/iso","base":"$WIB","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":true,"tool":"skill:auto-task-code-review","clean_pass_after_last_fix":true,"reviewed_diff_sha":"$RWISHA"},
          "gate_b":{"passed":true}}}
JSON
expect "WT-iso-cwd-allow: .cwd retarget ALLOWS gates-met (hook \$PWD neutral)"   "$(wigateCwd)" "0"
cat > "$WISD/STATE.json" <<JSON
{"approved":true,"phase":"execute","expected_next_action":"auto-continue","branch":"feat/iso","base":"$WIB","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
JSON
expect "WT-iso-cwd-gate: .cwd retarget BLOCKS ungated (hook \$PWD neutral)"      "$(wigateCwd)" "2"
# (D) warn/stop/inject on an ACTIVE worktree run (approved, not done). State from (C) is active.
wiwarn(){ local o; o="$( cd "$WIWT" && CLAUDE_PROJECT_DIR="$WI" bash "$WARN" </dev/null 2>&1 )"; [ -n "$o" ] && echo warn || echo silent; }
wistop(){ local o; o="$( cd "$WIWT" && CLAUDE_PROJECT_DIR="$WI" bash "$STOP" </dev/null 2>/dev/null )"; [ -z "$o" ] && { echo allow; return; }; printf '%s' "$o" | jq -r '.decision // "allow"' 2>/dev/null; }
wiinject(){ ( cd "$WIWT" && CLAUDE_PROJECT_DIR="$WI" bash "$INJECT" </dev/null 2>/dev/null ); }
# AC#5: no bogus drift warning — the worktree branch owns the active run.
expect "WT-iso-warn: SILENT (no false drift warning)"                           "$(wiwarn)" "silent"
# AC#6: anti-stall restored — a mid-pipeline turn-end BLOCKS.
expect "WT-iso-stop: mid-pipeline turn-end BLOCKED (anti-stall restored)"        "$(wistop)" "block"
# AC#9: read-before-review reminder names the WORKTREE branch, not silent/main.
wiinj="$(wiinject)"; case "$wiinj" in *"feat/iso"*) wiinjr=ok ;; *) wiinjr="silent-or-wrong" ;; esac
expect "WT-iso-inject: history reminder names the worktree branch"              "$wiinjr" "ok"
# Nested-repo protection still holds from a MAIN-neutral cwd (different common-dir → no retarget).
NEST2="$WI/vendor/embedded"; mkdir -p "$NEST2"
( cd "$NEST2" && git init -q && git config user.email t@t.t && git config user.name t && printf 'z\n'>g && git add g && git commit -qm n ) >/dev/null 2>&1
# MAIN itself carries an ungated active run so honoring CPD (no retarget) BLOCKS.
mkdir -p "$WI/.auto-task/main"
cat > "$WI/.auto-task/main/STATE.json" <<JSON
{"approved":true,"phase":"execute","expected_next_action":"auto-continue","branch":"main","effort":{"tier":"standard"},
 "gates":{"code_review":{"passed":false},"gate_b":{"passed":false}}}
JSON
wigateNest(){ printf '%s' "$COMMIT" | ( cd "$NEST2" && CLAUDE_PROJECT_DIR="$WI" bash "$GATE" ) >/dev/null 2>&1; echo $?; }
expect "WT-iso-nested: nested repo honors CPD, NOT retargeted, BLOCKED"          "$(wigateNest)" "2"
git -C "$WI" worktree remove --force "$WIWT" >/dev/null 2>&1 || true
rm -rf "$WI"

echo "================ Checkout-drift guard (enforce-gates block + warn hook) ================"
# Runs in its OWN isolated checkout ($DT) — NOT the shared $T, whose .auto-task/
# holds sibling active STATE dirs (feat/widget etc.) that would otherwise register
# as spurious drift for the silent-case assertions.
WARN="$HOOKS/warn-checkout-drift.sh"
DT="$(mktemp -d)"
(
  cd "$DT"
  git init -q; git config user.email t@t.t; git config user.name t
  git checkout -q -b feat/active
  printf 'x\n' > a.js; git add a.js; git commit -qm init
  git checkout -q -b chore/unrelated   # the "drifted" branch: no state of its own
  git checkout -q feat/active
  mkdir -p .auto-task/feat/active
  # feat/active carries an ACTIVE, gates-MET (LIGHT, no base/sha → staleness skipped)
  # run: "active" so it triggers drift from another branch, "gates-met" so the
  # no-drift control asserts an ALLOW (0), not a normal-gate block.
  cat > .auto-task/feat/active/STATE.json <<EOF
{"approved":true,"phase":"review","expected_next_action":"auto-continue","branch":"feat/active","effort":{"tier":"light"},
 "gates":{"code_review":{"passed":true,"tool":"skill:auto-task-code-review","clean_pass_after_last_fix":true},
          "gate_b":{"passed":false,"skipped_reason":"tier=light"}}}
EOF
) >/dev/null 2>&1
# git shim with NO jq, so the jq-absent path is exercised while git still works.
JQLESS="$(mktemp -d)"; ln -s "$(command -v git)" "$JQLESS/git" 2>/dev/null || true
dgate(){ printf '%s' "$COMMIT" | ( cd "$DT" && CLAUDE_PROJECT_DIR="$DT" bash "$GATE" ) >/dev/null 2>&1; echo $?; }
dwarn(){ local o ec; o="$( cd "$DT" && CLAUDE_PROJECT_DIR="$DT" bash "$WARN" 2>&1 )"; ec=$?; if [ -n "$o" ]; then printf 'warn:%s\n' "$ec"; else printf 'silent:%s\n' "$ec"; fi; }
dwarnNoJq(){ local o ec; o="$( cd "$DT" && PATH="$JQLESS" CLAUDE_PROJECT_DIR="$DT" /bin/bash "$WARN" 2>&1 )"; ec=$?; if [ -n "$o" ]; then printf 'warn:%s\n' "$ec"; else printf 'silent:%s\n' "$ec"; fi; }

git -C "$DT" checkout -q chore/unrelated   # drifted: on a branch with no run, feat/active active
expect "Drift: commit BLOCKED on drifted checkout"        "$(dgate)"      "2"
expect "Drift: warn hook fires, exit 0"                   "$(dwarn)"      "warn:0"
expect "Drift: warn SILENT + exit 0 when jq absent"       "$(dwarnNoJq)"  "silent:0"
git -C "$DT" checkout -q feat/active        # current branch owns the active (gates-met) run
expect "No-drift: gates-met commit ALLOWED (not drift-blocked)" "$(dgate)" "0"
expect "No-drift: warn SILENT on the active branch"       "$(dwarn)"      "silent:0"
# Malformed sibling state must not crash the warn hook (it is skipped → silent).
echo '{bad json' > "$DT/.auto-task/feat/active/STATE.json"
git -C "$DT" checkout -q chore/unrelated
expect "Malformed sibling state: warn exits 0 (no crash)" "$(dwarn)"      "silent:0"
# A repo with no .auto-task/ at all → warn stays silent (non-auto-task session).
DT2="$(mktemp -d)"
( cd "$DT2" && git init -q && git config user.email t@t.t && git config user.name t && git checkout -q -b solo && printf 'y\n' > f && git add f && git commit -qm i ) >/dev/null 2>&1
dwarn2(){ local o ec; o="$( cd "$DT2" && CLAUDE_PROJECT_DIR="$DT2" bash "$WARN" 2>&1 )"; ec=$?; if [ -n "$o" ]; then printf 'warn:%s\n' "$ec"; else printf 'silent:%s\n' "$ec"; fi; }
expect "No .auto-task/: warn SILENT (non-auto-task repo)"  "$(dwarn2)"     "silent:0"
rm -rf "$DT" "$DT2" "$JQLESS"

echo "================ check-version.sh --plain (per-run version check) ================"
CV="$HOOKS/check-version.sh"
PR="$(mktemp -d)"; mkdir -p "$PR/.claude-plugin" "$PR/data"; printf '{"version":"0.1.6"}' > "$PR/.claude-plugin/plugin.json"
# cvr <remote-version> [plain]: run check-version.sh against a known local 0.1.6, throttle bypassed.
# Env is set INSIDE the function body (not as a prefix to the function) so it reliably reaches the
# child bash; the optional second arg selects plain mode without clobbering the no-arg default path.
cvr(){ CLAUDE_PLUGIN_ROOT="$PR" CLAUDE_PLUGIN_DATA="$PR/data" AUTO_TASK_SKIP_THROTTLE=1 AUTO_TASK_REMOTE_VERSION="$1" bash "$CV" ${2:+--plain}; }
o="$(cvr 9.9.9 plain)"; m=other; case "$o" in *'is available'*) m=plain ;; esac; case "$o" in *hookSpecificOutput*|*'{'*) m=json ;; esac
expect "CV-plain-behind: bare line, not JSON"               "$m" "plain"
expect "CV-plain-current: silent"                           "$(cvr 0.1.6 plain)" ""
expect "CV-plain-ahead: silent"                             "$(cvr 0.0.1 plain)" ""
ou="$(CLAUDE_PLUGIN_ROOT="$PR" CLAUDE_PLUGIN_DATA="$PR/data" AUTO_TASK_SKIP_THROTTLE=1 AUTO_TASK_VERSION_URL=http://127.0.0.1:9/x bash "$CV" --plain)"; eu=$?
expect "CV-plain-unreachable: silent + exit 0"              "$ou:$eu" ":0"
od="$(cvr 9.9.9)"; d=other; case "$od" in *hookSpecificOutput*) d=json ;; esac
expect "CV-default-json: SessionStart JSON intact"          "$d" "json"
rm -f "$PR/data/.last-version-check"; cvr 9.9.9 plain >/dev/null; [ -f "$PR/data/.last-version-check" ] && s=present || s=absent
expect "CV-stamp-untouched: skip-throttle writes no stamp"  "$s" "absent"
rm -rf "$PR"

echo
echo "================ SUMMARY: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
