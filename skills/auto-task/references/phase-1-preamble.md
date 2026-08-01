# Phase 1 — Define: procedural preamble reference

_The full contract for Phase 1's procedural steps, AC pre-flight, the critique loop, the risk disclaimer, and the comment-voice resolution. The correctness core — requirements decomposition, the Acceptance Criteria contract, the INCONCLUSIVE floor, the D/R rubric, the estimate step and the autonomy branch — deliberately stays inline in `SKILL.md`._

_Split out of `skills/auto-task/SKILL.md`; the content below is verbatim. `SKILL.md` points here with a MANDATORY READ directive._

## Cross-references

The prose below is reproduced verbatim, so its internal "see X" pointers still read as if the spec were one file. Where a named target now lives elsewhere:

- "Autonomy modes & the merge gate" (incl. "First-run setup") → `SKILL.md` (the H2 section + the autonomy×landing matrix) + `references/settings.md` (First-run setup, merge gate, interrupt-now gates, assumptions ledger, settings reset)
- "User settings" → summarized in `SKILL.md`; full key table in `references/settings.md`
- "State file" → `SKILL.md` (JSON schema) + `references/state-schema.md` (object notes)

---

## comment-voice — relocated verbatim from SKILL.md

**Resolve a voice guide (`VOICE.md`) in this precedence — first *non-empty* file wins:**

1. **Project-local:** `<repo-root>/.claude/VOICE.md`, where `<repo-root>` is `git rev-parse --show-toplevel` (in a linked worktree, the worktree root). Read it with the Read tool.
2. **Global:** `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/VOICE.md`.

Fall-through, not first-*present*: if the project-local file is **absent, empty, whitespace-only, or unreadable**, continue to the global file. Only when **both** levels yield no usable content do you fall back to built-in defaults. (So an empty project-local `.claude/VOICE.md` never masks a populated global one.)

**Apply the resolved voice:**

- **Found a non-empty VOICE.md** → treat it as the tone/phrasing guide for the comment's **free prose**: the ticket-comment question wording, the PR `## Summary` bullets and `## Run notes`, the PR title, and the preview verdict sentence. Match its voice; do not quote or mention the file.
- **Found none** → use the built-in default style contract already specified at each surface (this is the pre-VOICE behavior, unchanged).

**Hard constraints always outrank voice.** VOICE.md shapes *how the prose reads*, never *what may appear*. It does **not** override, relax, or reinterpret:

- the **no-AI-attribution** rule (no `Co-Authored-By: Claude`, no "🤖 Generated with…", no AI-authorship marker) on any commit message, PR title, PR body, **or PR comment** — including the Phase-7 preview verdict comment;
- the **ticket-comment structural contract** (no names, no greetings/salutation, strictly-business functional questions only);
- the **PR body's machine-structured content** — the required section headings, the task-breakdown/AC tables, the AC checklist, the Mermaid change diagram, and the `## Visual changes` before/after table stay verbatim and structural. Voice touches narrative prose, not tables, checklists, headings, diagrams, or embedded images;
- the **per-surface length/brevity limits** — the ticket comment's "keep it short / tightly phrased" rule and the PR title's "under 70 chars" cap. A verbose or essayistic voice does not license a bloated ticket comment or an over-length PR title; trim to fit the limit while keeping the voice.

If the resolved voice would push a comment to violate any of the above, the constraint wins and the voice yields.

**Fail-open, silent, presentation-only.** Resolving or reading VOICE.md must never block, slow, or error a run — a missing/empty/unreadable file just means "use defaults." Never surface anything to the user about voice resolution, never prompt about it: this adds **no new gate, no new yield, no new `AskUserQuestion`**, and it never alters `expected_next_action`. It changes only the wording of comments the pipeline already emits.


## phase1-preamble-steps — relocated verbatim from SKILL.md

**Version check (best-effort, fail-open — NEW runs only, before everything else).** On a new run (`/auto-task <description>`), before the component preflight, do a fresh **per-run version check** and offer to update if the plugin is behind. This is best-effort and MUST NOT block, slow (beyond the bounded fetch), or error the run — any failure means proceed silently. **Skip it entirely on resume** (`/auto-task` with no args): a resume continues an already-approved, mid-flight run, where swapping the plugin under the running pipeline would be wrong.

1. **Locate** the checker. `CLAUDE_PLUGIN_ROOT` is exported only to *hooks*, **not** into this Bash-tool environment, so it is normally empty here — do not rely on it alone (that was the original bug: `${CLAUDE_PLUGIN_ROOT}/hooks/check-version.sh` resolved to a bare `/hooks/...` path that never existed, so the check silently skipped on every run). Discover the script across both install layouts:

   ```bash
   cv=""
   # a) hook env, on the off chance it is exported into this shell
   [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/hooks/check-version.sh" ] \
     && cv="$CLAUDE_PLUGIN_ROOT/hooks/check-version.sh"
   # b) marketplace install: newest installed version dir that carries the hook
   if [ -z "$cv" ]; then
     cache="$HOME/.claude/plugins/cache/auto-task-plugin/auto-task"
     if [ -d "$cache" ]; then
       d="$(ls -1 "$cache" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' \
            | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
       [ -n "$d" ] && [ -f "$cache/$d/hooks/check-version.sh" ] \
         && cv="$cache/$d/hooks/check-version.sh"
     fi
   fi
   # c) install.sh symlink layout: resolve the installed skill symlink to the repo root
   if [ -z "$cv" ]; then
     sk="$HOME/.claude/skills/auto-task"
     if [ -L "$sk" ]; then
       tgt="$(readlink "$sk")"; case "$tgt" in /*) ;; *) tgt="$(dirname "$sk")/$tgt" ;; esac
       root="$(cd "$(dirname "$tgt")/.." 2>/dev/null && pwd)"
       [ -n "$root" ] && [ -f "$root/hooks/check-version.sh" ] && cv="$root/hooks/check-version.sh"
     fi
   fi
   ```

   If `$cv` is still empty after all three probes, **skip silently** and go straight to Component preflight (fail-open — a version notice is never worth blocking a run).
2. **Run it fresh + plain:** `out="$(AUTO_TASK_SKIP_THROTTLE=1 bash "$cv" --plain 2>/dev/null || true)"`. This bypasses the 24h throttle (a true per-run check) WITHOUT touching the SessionStart throttle stamp, bounds the network call (the script's own `--connect-timeout 2 -m 5`), and prints the one-line notice ONLY when the installed version is strictly behind — empty on current / ahead / offline / no-jq / malformed.
3. **Decide:** if `$out` is **non-empty** (a newer version exists), ask ONCE via `AskUserQuestion`: present `$out` and two options — **"Proceed on current (Recommended)"** and **"Update it for me (auto-apply)"**. On *proceed* → continue into Component preflight. On *update* → **auto-apply the update, no manual command**:

   a. Locate the bundled updater with the SAME three probes used above for `$cv`, but resolving `hooks/apply-update.sh` instead of `hooks/check-version.sh` (reuse the exact `cv` block, substituting the filename into an `au` variable — the `CLAUDE_PLUGIN_ROOT`, marketplace-cache-newest-dir, and `install.sh`-symlink→repo-root probes are identical).

   b. If `$au` resolved: run `bash "$au"` (it self-detects the install layout — `claude plugin update …` for a marketplace install, `git pull --ff-only` for an install.sh/dev clone — and applies the update without any typed command). Report its one-line `apply-update: …` result to the user, then **STOP** and tell them to **restart the Claude Code session** (a restart is required — hooks load at SessionStart and a marketplace update only *stages* the new version, so re-invoking in the same session would reload nothing and re-trigger this offer in a loop) and then re-run `/auto-task`.

   c. **Fail-open:** if `$au` did not resolve, or `bash "$au"` exits nonzero (unsupported/copy layout, dirty git tree, missing `claude` CLI, offline, etc.), fall back to the manual path — STOP and tell the user to run `/plugin update auto-task@auto-task-plugin` (or `git pull` in their clone) and re-run `/auto-task`. The branch never dead-ends.

   If `$out` is **empty** → say nothing, continue into Component preflight.

This ask is part of the existing Phase-1 human surface — it runs while `approved: false`, so the Stop hook's `approved !== true → allow` guard already permits the yield (`expected_next_action` stays `null` while `approved:false`). It is NOT a new mid-pipeline yield, and it never runs after approval.

**First-run setup (pre-run, NEW runs only — runs right after the version check; see "Autonomy modes & the merge gate → First-run setup" for the authoritative spec).** Locate `settings.sh` (three-probe pattern). Run `bash "$settings_sh" schema-status`. If it returns `unconfigured` or `stale`, this is the one-time setup: on `stale` first `bash "$settings_sh" reset --backup` (project-scoped, backs up, never touches the global file), then ask the **five policy questions** in one pass and record each with `settings.sh set` (project scope): **telemetry** (this is exactly the telemetry-consent question below — when First-run setup runs, ask it here as question 1 of 5 rather than separately), **autonomy** (`supervised`/`autonomous`), **landing_model** (`pr`/`direct`), **unattended_external** (default no), **docs_update_mode** (`skip`/`always`/`ask`, default `skip` — whether the Phase-5 docs-update step runs). The first `set` also stamps `settings_schema_version` so setup does not re-fire. For telemetry re-consent use `present --scope project` (a global opt-in is surfaced, not silently inherited). Skipped on resume; fail-open (headless/error → keep safe defaults `supervised`/`pr`/`false`/`skip`/telemetry-off and proceed). If `schema-status` returns `current`, skip setup and fall through to the individual telemetry-consent check below (which then no-ops because telemetry is already decided). This is a Phase-1 surface while `approved:false`, so the Stop hook allows the yields.

**Telemetry consent check (pre-run, NEW runs only — runs right after the version check).** This is a **pre-run check, grouped with the version check above** — decide it before any git setup, not mid-Phase-1. Remote telemetry is opt-in and its destination is bundled (see "User settings"), so the only thing a user decides is *whether to share*; ask that **once per repo**, never silently, never repeatedly. Like the version check, it is best-effort/fail-open, NEW-runs-only, and **skipped entirely on resume**. A SessionStart hook can't do this (hooks can't prompt), so it is model-driven here.

1. **Locate `settings.sh`** with the same three-probe pattern used for `check-version.sh` above (`CLAUDE_PLUGIN_ROOT` is empty in the Bash-tool env), substituting `hooks/settings.sh` into a `settings_sh` variable. If it can't be found, **skip silently** (fail-open — never block a run on consent) and proceed to Component preflight. Note the settings project-key is derived from the git **common dir**, which is identical before and after branch/worktree setup, so resolving it here targets the same project file the run will use.
2. **Already decided?** Run `bash "$settings_sh" present telemetry_enabled`. If `true`, the user has already chosen (enabled or declined) at the project or global scope — **skip the prompt**. Only when `false` (never asked in this repo) do you ask.
3. **Ask exactly once** via a single `AskUserQuestion` (part of the Phase-1 human surface; `approved` is still `false`, so the Stop hook allows the yield — set `expected_next_action` `null`/`"user-approval"` as for any Phase-1 ask): *"Share anonymous auto-task telemetry from this repo? Quality/performance metrics only — no code, task text, branch, paths, or identifiers leave your machine (see README → Remote telemetry). Change it anytime in settings."* Options: **"Enable — share anonymous metrics"** / **"No thanks — don't ask again for this repo"**.
4. **Record immediately**, project-scoped, so it is remembered and never re-asked: enable → `bash "$settings_sh" set telemetry_enabled true`; decline → `bash "$settings_sh" set telemetry_enabled false` (writing `false` is a real *decision* — `present` then returns `true`, so it won't fire again). Log `{ phase: "define-telemetry-consent", decision: "enabled|declined", at: "ISO-8601" }` to `state.history` once state exists (or defer the log to state-init if it isn't created yet — the recorded settings value is the source of truth either way).
5. **Fail-open:** if `AskUserQuestion` is unavailable (headless) or anything errors, proceed with telemetry OFF (the default) — never block, never enable without an explicit answer. A global explicit `telemetry_enabled` (either value) also counts as decided and suppresses the per-repo prompt.

**Visual-assets consent check (Phase 1, opt-in — off by default, per-project).** Embedding before/after screenshots in a PR means **uploading images to a public Cloudinary account** (see Phase 5 "Visual changes"), so — exactly like telemetry and `bot_review_autofix` — it is **off by default** and requires an **explicit per-repo opt-in**. This check is model-driven (a hook can't prompt), best-effort/fail-open, and **skipped on resume**. Unlike the telemetry check it is **UI-scoped**: only ask when this run would actually produce visual proof, so backend/docs/config repos are never nagged.

1. **Trigger.** Evaluate this **after reconnaissance** (so UI/visual scope is known) and **before the plan-approval gate**. Ask ONLY when the run has UI/visual scope — the task changes something a user sees, OR recon identified a reachable UI target / a visual AC is planned. If the run has no UI/visual scope, **skip silently** (do not ask, do not record) — a later UI run in this repo will ask then.
2. **Locate `settings.sh`** (three-probe pattern, `hooks/settings.sh`). If it can't be found, skip silently (feature stays off — fail-open).
3. **Already decided?** `bash "$settings_sh" present visual_assets_enabled` → if `true`, the user already chose (enabled or declined) at project or global scope; **skip the prompt**. Only when `false` (never asked) do you ask.
4. **Ask exactly once** via a single `AskUserQuestion` (Phase-1 surface; set `expected_next_action: "user-approval"`): *"Embed before/after screenshots in PRs for visual changes? auto-task uploads UI screenshots via an unsigned preset and embeds them inline (renders for public and private projects; the image bytes are public). Works out of the box via a bundled shared Cloudinary — or point `cloudinary_cloud_name`/`cloudinary_upload_preset` at your own. Off by default; change anytime."* Options: **"Enable — embed screenshots in PRs"** / **"No thanks — don't ask again for this repo"**. Surface with the run banner.
5. **Record immediately**, project-scoped: enable → `bash "$settings_sh" set visual_assets_enabled true`; decline → `bash "$settings_sh" set visual_assets_enabled false` (writing `false` is a decision — `present` then returns `true`, so it won't re-ask). Log `{ phase: "define-visual-assets-consent", decision: "enabled|declined|skipped-no-ui-scope", at: "ISO-8601" }` to `state.history`. **Fail-open:** any error / headless `AskUserQuestion` → proceed with the feature OFF (never enable without an explicit yes). A global explicit `visual_assets_enabled` (either value) counts as decided and suppresses the prompt.
6. **Config honesty (on enable).** Both keys ship with **bundled defaults** (the shared disposable Cloudinary), so embedding normally works immediately on enable — no extra setup. The one edge case: if a user has explicitly overridden `cloudinary_cloud_name` or `cloudinary_upload_preset` to **empty**, check them (`bash "$settings_sh" get …`) and surface a one-line note that embedding stays inert until both are non-empty, naming the commands `bash "$settings_sh" set cloudinary_cloud_name <name>` / `set cloudinary_upload_preset <unsigned-preset>`. Do NOT try to collect the values through `AskUserQuestion` (free-text is unreliable there). This keeps the opt-in honest: the consent never promises embedding the current config can't deliver.

**Component preflight (on a new run this runs right after the version check; on resume — `/auto-task` no args — it is the first step).** This pipeline is only sound if every component it composes is present. Before touching git, confirm the six **mandatory** composed skills — `auto-task-plan`, `auto-task-implement`, `auto-task-verify`, `auto-task-fix`, `auto-task-code-review`, `auto-task-commit` — and the `task-execution-verifier` agent are available in this session. **`auto-task-docs` and `auto-task-release` are OPTIONAL and deliberately NOT hard-stops:** each is only reachable when its mode setting is `always`/`ask` (both default to `skip`), and a `git`-layout self-update fast-forwards the clone without re-running `install.sh`, so their symlinks can legitimately be missing on a symlink install. If `auto-task-docs` is absent, do NOT stop the run — degrade the Phase-5 docs step to `skip`, log `{ phase: "define-preflight", result: "docs-skill-absent", note: "auto-task-docs not registered; docs step degraded to skip — re-run install.sh to enable it", at }`, and surface that one line at the plan-approval gate when the resolved `docs_update_mode` is not `skip` (so the user learns the step they configured will not run). If `auto-task-release` is absent, apply the identical treatment — degrade the Phase-9 release step to `skip`, log `{ phase: "define-preflight", result: "release-skill-absent", note: "auto-task-release not registered; release step degraded to skip — re-run install.sh to enable it", at }`, and surface it at the gate when the resolved `release_mode` is not `skip`. In neither case may you improvise the missing skill's work yourself: that would escape its scope contract (for the release skill, the never-push/never-publish boundary and the never-hand-edit-a-version-manifest rule). Every OTHER component named above remains a hard blocker (they appear in the available-skills / available-agents lists). **Invocation-name note:** under a marketplace install these siblings are registered *namespaced* — `auto-task:auto-task-plan`, `auto-task:auto-task-code-review`, etc. — while under the `install.sh` symlink fallback they keep their bare names (`auto-task-plan`, …). Everywhere this skill says "invoke the `auto-task-plan` skill" (and likewise for the other siblings and the verifier agent), invoke whichever form actually appears in your available-skills list for this session; the bare name in the prose is the identifier, not a literal string that must be passed verbatim. If any **mandatory** component is missing, **STOP and tell the user the plugin is not fully installed** (point them at `install.sh` and the README "Install" section); do not start the run. (The only exceptions are the optional `auto-task-docs` and `auto-task-release`, handled above — each degrades to `skip` and never stops a run.) Silently substituting a missing component (e.g. a hand-rolled review prompt for `auto-task-code-review`, or skipping a verifier gate) breaks the guarantees the user is relying on — a missing **mandatory** piece is a hard blocker, not something to work around. This is a one-time check; on resume (`/auto-task` with no args) it still runs, since a component could have been uninstalled between sessions.

**Branch setup (new runs only).** Before invoking `auto-task-plan`, isolate the run:

1. **Branch.** Every new-description run gets its OWN fresh branch named `<type>/<slug>`, created from the repo's **default branch** (`main`/`master`) — regardless of what branch is currently checked out. This is unconditional: auto-task no longer runs "in place" on a prepared feature branch (see "Isolate the new branch" below for why, the resolution, and the one exception — already being inside a linked worktree). Match the repo's existing convention (sample with `git for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin | head -30` and pick the dominant pattern — most repos here use `feat/`, `fix/`, `chore/`, `deps/`, `docs/`, `cleanup/`, `refactor/`). Pick `<type>` from the task description:

   - `fix/` — bug reports, "X is broken", "doesn't work", "scrolls to wrong place", "throws error", "wrong output", "regression"
   - `feat/` — "add X", "implement Y", "new feature", "support Z", "enable …"
   - `deps/` — dependency add/remove/bump: package-manifest / lockfile changes ("bump X", "update dependency", "upgrade package", "add library")
   - `chore/` — internal cleanup, build/test config, formatting-only sweeps
   - `refactor/` — code reorganization with no behavior change
   - `docs/` — docs/README/comments-only changes
   - `cleanup/` — removal of dead code or files
   - When ambiguous between `feat` and `auto-task-fix`, prefer `auto-task-fix` if the user describes existing-but-broken behavior, `feat` if the user describes capability that doesn't exist yet
   - Default if truly unclear: `chore/`

   `<slug>` is the task description slugified to kebab-case (lowercase, ASCII, ~40 chars at a word boundary, strip stop words like "the", "a", "and"). Do not prepend `auto/` — the branch name should look like one a human would write, since it ends up in `git log` and the PR.

   Ensure uniqueness of BOTH the branch and its worktree directory before creating anything (two runs whose descriptions slugify the same must not collide): check `git branch --list <name>`, `git ls-remote --heads origin <name>` (skip the remote check if origin is unreachable), AND that `.claude/worktrees/<type>-<slug>` does not already exist; append `-2`, `-3`, etc. to the slug (updating both branch name and dir) until all three are free.

   **Isolate every run in its own git worktree, based on a fresh default branch (automatic, unconditional — this is what makes same-repo parallel runs safe with zero user action).** A run keys ALL its state to the checked-out branch, and the gate + Stop hooks resolve state via `git branch --show-current`. So running directly in a shared checkout means a branch switch from another terminal (or a second run) yanks the working tree out from under this one. The fix is: give **every** new-description run its own working tree, forked from the repo's default branch — never operate in the shared checkout.

   1. **Already inside a linked worktree?** If the session is running inside a linked git worktree rather than the main working tree, do NOT nest a second worktree — this checkout is already isolated, and the user deliberately entered it to base the run on this branch's work. Detect it by comparing the git-dir and common-dir **in absolute form** — a bare `git rev-parse --git-dir` is absolute but `--git-common-dir` is returned *relative* when you are in a subdirectory, so comparing the two raw outputs gives a false "worktree" positive from any subdir of the main tree. Absolutize both first:
      ```sh
      gd="$(git rev-parse --absolute-git-dir)"
      gcd="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
      [ "$gd" != "$gcd" ]   # true → linked worktree; false (equal) → main tree
      ```
      This holds from the worktree/main-tree root AND from any subdirectory (in a linked worktree `gd` is `…/.git/worktrees/<name>` while `gcd` is `…/.git`; in the main tree both resolve to `…/.git`). Then, respecting the prepared checkout:
      - If the worktree is on a feature branch (anything other than `main`/`master`), **use that branch as-is** — do NOT fork a new one (forking would abandon the very work the user prepared). Set `state.branch` to the current branch and `state.base = git rev-parse HEAD`.
      - Only if the worktree happens to sit on `main`/`master` (committing there would be wrong), fork a fresh unique `<type>/<slug>` branch in place: `git switch -c "<branch>"` off the current HEAD.
      This preserves the "prepare a worktree by hand, then run `/auto-task` inside it" workflow. Skip steps 2-3.

   2. **In the main working tree — resolve a fresh default base, then create the worktree and enter it:**
      - **Resolve the default branch** `<default>` (`main`/`master`): prefer `git symbolic-ref --short refs/remotes/origin/HEAD` (strip the `origin/`); else whichever of `main` / `master` exists locally. This is the base for the new branch, regardless of what branch is currently checked out.
      - **Pull the default branch before creating the new branch — a sanctioned exception to the "leave the shared checkout untouched" rule (best-effort, fail-open).** Outside branch setup and the final land step, this skill refuses to touch the main working tree; at run start it deliberately does, because syncing local `<default>` to its remote first keeps the local default current AND bases the new branch on the freshest main — so any integration conflict surfaces (and gets resolved) as early as possible instead of piling up until handover. Fast-forward the local default to its remote with `git pull --ff-only` — a pure fast-forward, never a merge commit. Because `git pull` acts on the checked-out branch, the main working tree must be on `<default>` first: if it is on something else and clean, `git switch "<default>"` then `git pull --ff-only origin "<default>"`. **WIP guard — the one thing this exception must never do is destroy user work:** if switching would clobber uncommitted changes in the shared checkout, do NOT discard them — **skip the pull** and branch off `origin/<default>` instead. Bounded; ignore any other failure — offline, no remote, a dirty tree, or a divergence that can't fast-forward just means we branch from whatever local `<default>` tip we have. **Then do the checkout** off the now-current default (next bullet). This is the first half of the "pull main so there are no conflicts" contract: because the new branch is cut directly from the freshly-pulled default, **a brand-new branch is conflict-free with main by construction** — there is nothing to merge and nothing to resolve at creation time. (The second half — re-syncing with main right before the handover commit, where main may have advanced during the run — is enforced in Phase 5.)
      - **Create the worktree from the fresh default ref:** `git worktree add ".claude/worktrees/<type>-<slug>" -b "<branch>" "<default-ref>"` where `<default-ref>` is the local `<default>` (now fast-forwarded to its remote), or `origin/<default>` if the pull was skipped/failed but the remote-tracking ref is newer. The directory name is the branch with `/`→`-` (a single safe path segment). Basing on the default ref (not `HEAD`) is deliberate — every run starts from a clean, current default branch, so it never inherits the current checkout's branch identity or uncommitted WIP.
      - **Enter it** with the **`EnterWorktree`** tool, passing `path: ".claude/worktrees/<type>-<slug>"` (entering an existing worktree by path — the tool's docs sanction this when project instructions direct it, which this skill is). From here the session CWD is the worktree root; every subsequent step (exclude, folders, state, and all later phases) resolves against it, and the shared checkout — left on the freshly-pulled `<default>` (or wherever the WIP guard kept it) — is free for other work.
      - Set `state.base = git rev-parse HEAD` inside the new worktree (the SHA the branch was forked from — the fresh default tip).

   3. **Ordered fallbacks (never leave a half-made worktree behind):**
      - **`git worktree add` failed because the branch/dir was taken** (a concurrent same-slug run won the TOCTOU race after the uniqueness check): this is NOT a reason to abandon isolation — re-disambiguate the slug (`-2`/`-3`… for both branch AND dir) and RETRY `git worktree add … -b "<branch>" "<default-ref>"`, up to a few times. Only if it keeps failing for a non-collision reason fall through to the in-place path below. This keeps the losing run isolated rather than dropping it into the shared checkout.
      - If the `EnterWorktree` tool is not available in this session (older harness / headless run) OR `git worktree add` fails for a structural reason (not a name collision) → skip the worktree and run in place. Because the current checkout may be on any branch, base the in-place branch on the fresh default too: `git switch -c "<branch>" "<default-ref>"` (re-disambiguate the name first if it now exists). **Caveat — dirty tree:** cutting the new branch at `<default-ref>` (rather than the current HEAD) means `git switch -c` will refuse if uncommitted changes in the shared checkout would be overwritten by the switch; if that happens, surface it (do NOT discard the user's WIP) rather than forcing the switch. Log `{ phase: "define-setup", result: "worktree-fallback", reason: "<what failed>", at: "ISO-8601" }` to `state.history`. The run is then a normal in-place run; the checkout-drift guard (below) covers the residual risk.
      - If `git worktree add` SUCCEEDED but `EnterWorktree` then failed, the worktree exists on disk yet the session is still in the original checkout — undo the orphan before falling back: `git worktree remove --force ".claude/worktrees/<type>-<slug>"` then `git branch -D "<branch>"` (the branch is unused since you never entered it), then `git switch -c "<branch>" "<default-ref>"` in place.

   **Note — this fork-from-default behavior is the step-2/3 (main-working-tree) path.** A run launched from the main working tree while on a feature branch does NOT continue that branch; it forks fresh from the default. (The step-1 already-in-a-worktree path is the exception: there a prepared feature branch IS used as-is.) So to base a run on specific pre-existing work, prepare a worktree for that branch by hand and run `/auto-task` inside it (step 1's in-place path). Write the resolved branch name to `state.branch`.

   **Resume (`/auto-task` with no args) never creates a worktree.** Isolation is a NEW-run action only. A resume continues an existing run keyed by `state.branch` — it stays in whatever worktree/checkout that run already lives in; do not fork a new branch or worktree on resume.

   **Pre-existing staged/unstaged changes:** if `git status` shows any work in progress before setup, do NOT touch it (no `git add`, no `git stash` unless the user agrees). On the normal step-2 worktree path this WIP simply stays in the shared checkout, untouched — the isolated worktree is a separate working tree cut from `<default-ref>`, so it starts clean and never inherits or disturbs the WIP. On the step-1 already-in-a-worktree path (branch used as-is) the WIP is part of that worktree and carried along — fine, as long as you never stage it in your own commits. Only the step-3 in-place fallback can conflict with the WIP (it switches the shared checkout to a branch cut at `<default-ref>`); per that fallback's caveat, surface a conflict rather than discarding changes. If a user file conflicts with creating `.auto-task/<branch>/`, surface it and ask.

2. **Exclude `.auto-task/` (and the worktree store) from git.** Resolve the exclude file as `excl="$(git rev-parse --git-common-dir)/info/exclude"` — that expands to `.git/info/exclude` in a normal checkout and to the shared common-dir exclude from any linked worktree (where `.git` is a *file*, not a directory, so the bare `.git/info/exclude` path would error with "Not a directory"). Append `.auto-task/` (the root, NOT the per-branch sub-path) idempotently: `grep -qxF '.auto-task/' "$excl" || echo '.auto-task/' >> "$excl"`. Also append `.claude/worktrees/` the same way (`grep -qxF '.claude/worktrees/' "$excl" || echo '.claude/worktrees/' >> "$excl"`) so an auto-created worktree living under the repo never shows as untracked in — or gets accidentally staged from — the parent checkout. This is per-clone, so it never lands in the repo's `.gitignore`. One `.auto-task/` entry covers every per-branch folder (and, via the common dir, every linked worktree of the clone), including ones from prior runs that should remain readable for history.

3. **Create the per-branch folder.** `mkdir -p .auto-task/<branch>/artifacts .auto-task/<branch>/recon .auto-task/<branch>/fixes`. Slashes in the branch name are preserved literally (branch `fix/auth-bug` → `.auto-task/fix/auth-bug/`). This MUST match `git branch --show-current` verbatim — the gate and Stop hooks resolve `.auto-task/<branch>/STATE.json` from it, and any divergence (extra prefix, rewritten slug) makes them silently find no state file and fail open.

   **Then remove any stale run clock: `rm -f .auto-task/<branch>/.run-clock.json`.** A branch folder outlives the run that created it, and the clock records the *previous* run's start/end plus a `sealed` marker that makes every later stamp a no-op — so a new run reusing the folder would report the old run's duration verbatim (a plausible number, undetectable downstream). `state.base` scoping in `hooks/lib/run-clock.sh` cannot carry this alone, because `base` is the **fork point**: two runs share it whenever the default branch has not moved between them. The run that owns the folder declaring its clock fresh is the reliable fix; the helper's sealed-clock-beside-a-live-run inference is the belt. Do NOT delete `.outcome-recorded` / `.telemetry-sent` — those are base-keyed and self-heal.

4. **State.** Initialize `.auto-task/<branch>/STATE.json` with `phase: "define"`, `expected_next_action: null`, `approved: false`, `title: "<derived run title>"`, `description: "<verbatim task input>"`, `branch: "<resolved name>"`, `base: "<base-commit SHA>"`, and empty containers for the rest (see "State file" schema). **Derive `title`** — a concise (~≤60 char) human-readable label for the run, distilled from the task description (e.g. "Forward clarifying Qs to ticket owner"), NOT the raw description verbatim. This is the "Run label" surfaced in agent labels + phase banners (see Operating principles). Fallbacks so it is never blank: if the distillation yields empty/whitespace-only or otherwise unusable text (e.g. a non-Latin description that leaves nothing legible), fall back to the branch slug `<type>/<slug>`. On **resume** (`/auto-task` no args), reuse the stored `title` and do NOT re-derive — EXCEPT a pre-existing in-flight STATE written before this field existed will have no `title`; in that one case derive it once on first resume and persist it, so the banner/label is never empty. Capture `base` as `git rev-parse HEAD` at run start — for the isolated worktree this is the fresh default-branch fork point (set in branch-setup step 2); for the in-place fallback it is the tip the new branch was cut from. Either way `git diff <base>` is then exactly *this run's* uncommitted work, which is what the change diagram, the verifiers, and the review-staleness gate hook all measure against. `base` must NOT change for the life of the run. **Caveat:** the isolated worktree starts clean, so there is normally no pre-existing WIP in it; but if a run somehow starts with pre-existing uncommitted changes (e.g. the in-place fallback on a dirty tree), those are part of `git diff <base>` too — the baseline-exclusion rule keeps them out of *commits*, but reviewers and the staleness hash will see them. When that happens, note it under PLAN.md Unknowns so a reviewer isn't surprised. `expected_next_action` is `null` while `approved` is `false` — the Stop hook allows yields freely until the user has approved the plan.

5. **Initialize TRACE.md.** Create `.auto-task/<branch>/TRACE.md` with the header block from the "Persistent history & trace contract" section, and append the first trace entry: `operation: auto-task:phase-1-start`, summary: "Branch <name> created from <base>; task: <one-line task summary>".

6. **Load settings (auto, fail-open).** Read the project's settings via `hooks/settings.sh` (see "User settings"; locate it with the three-probe pattern). Write a snapshot to `state.settings`: `{ source: "<settings.sh path>", resolved: { has_preview_deployment, preview_wait_mode, preview_timeout_min, telemetry_enabled, telemetry_satisfaction_prompt, ... }, at }` — capture at least the preview-, telemetry-, and `docs_update_mode`-relevant keys via `settings.sh all` (the merged `defaults ⊔ global ⊔ project` view). This snapshot records what the run read (later phases re-read live values; the snapshot is for the audit trail + the approval-gate surface). If `settings.sh` cannot be located or errors, record `state.settings = { source: null, resolved: {}, note: "settings unavailable — using built-in defaults", at }` and proceed on defaults (never block). Surface the resolved `has_preview_deployment` (and whether it is explicitly set vs. will auto-learn) at the plan-approval gate so the user knows whether a Phase-7 preview verification will run; likewise surface `bot_review_autofix` so they know whether Phase-6 bot-comment review is enabled, and `docs_update_mode` when it is not `skip` so they know a Phase-5 docs step will run (and, if preflight recorded `docs-skill-absent`, that it will be degraded to `skip` until `install.sh` is re-run). On **resume**, re-read settings (they may have changed between sessions) and refresh the snapshot. This step is additive and never gates anything. **Also snapshot the autonomy policy:** write `state.autonomy` = resolved `autonomy` and `state.landing` = resolved `landing_model`, and include both (plus `risk_gate_threshold`, `unattended_external`, `test_integrity_guard`, `budget_blowout_factor`) in `state.settings.resolved` — these drive the plan-approval branch and the Phase-5 merge gate (see "Autonomy modes & the merge gate"). Pinning them here keeps the run's interaction model stable even if settings change mid-run.

**Do NOT make any commit during branch setup.** The branch starts empty (zero commits ahead of the base). The first commit comes only after the user approves the plan, in Phase 2 — and it commits real code changes, not `.auto-task/<branch>/` content. The plan itself lives on disk under `.auto-task/<branch>/` for the user to read and for resumption, but it is never part of the git history.

All commits in the run go through the `auto-task-commit` skill. Before invoking `auto-task-commit`, run `git restore --staged .auto-task/ 2>/dev/null || true` defensively, even though the exclude entry from step 2 (`$(git rev-parse --git-common-dir)/info/exclude`) should already keep `.auto-task/` out of the index.

**Checkout-drift guard (protects the in-place fallback path).** With unconditional worktree isolation, the ONLY run that operates in the shared checkout is the worktree fallback above (when `EnterWorktree`/`git worktree add` was unavailable). Such a run is guarded proactively against the working tree being switched off its branch underneath it. Two hooks enforce this, both keyed on `git branch --show-current` versus the active run's `.auto-task/<branch>/`: (1) `warn-checkout-drift.sh` (PreToolUse/Bash, informational, NEVER blocks) warns on every command when an active run exists on a branch other than the one checked out; (2) `enforce-gates.sh` HARD-BLOCKS a `git commit` in that same situation — closing the old silent fail-open where a moved checkout found no state for the current branch and allowed an ungated commit onto the wrong branch. Resolve a drift warning/block by either `git switch <run-branch>` (then resume with `/auto-task`) or `rm -rf .auto-task/<run-branch>/` if the run is abandoned. Runs isolated in their own worktree are structurally immune — git forbids two worktrees on one branch, and `.auto-task/` is per-worktree — so the guard is a safety net for the in-place path, not a substitute for worktree isolation.

**Worktree lifecycle.** An auto-created worktree is KEPT on disk after the run — Phase 5 never removes it — so its branch and `.auto-task/<branch>/` history/artifacts stay available for follow-up and review. Do NOT call `ExitWorktree` to auto-remove it. To reclaim disk later, run **`/auto-task-gc`** (the `auto-task-gc` skill) — it reports per-worktree size/age/merge-status and safely removes the reclaimable ones (merged, or clean-and-stale past their per-type retention threshold), preserving branch refs and pruning the matching `.auto-task/<branch>/`. A SessionStart nudge (`suggest-cleanup.sh`, gated by `worktree_cleanup_nudge`) surfaces this when reclaimable worktrees accumulate. You can still prune by hand with `git worktree remove .claude/worktrees/<type>-<slug>` if you prefer.

**Clarifying questions (HUMAN GATE — first interaction).** Before reconnaissance or planning, surface every decision-changing ambiguity that you cannot resolve yourself. The goal: once the user answers (and reviews your auto-resolved items at plan approval), you can plan, execute, verify, and ship the task without coming back for clarification. This is the FIRST half of Phase 1's human gate; plan approval at the end of Phase 1 is the second half. There is no separate gate later — anything you'll need to know to finish the run, resolve or surface now.

**Core principle:** do not burden the user with anything you can answer with reliable evidence. Do NOT guess, assume, or extrapolate from "looks like the convention" — if you don't have a verifiable cite, ask the user. Every candidate that you resolve yourself is recorded in PLAN.md with its source so the user can audit your evidence at approval time.

**Resume dispatcher (checked FIRST on any Phase-1 re-entry — before the clarify router AND the approach-selection fold).** This is the single, always-reachable **Resume short-circuit (checked before the router)** for a forwarded pause. It lives here — at the very top of the clarify gate, ahead of stage 1 and ahead of approach selection — precisely so it fires regardless of whether the Asked bucket is empty this pass (the approach-fold case resumes with an empty clarify bucket, which would skip stage 4; the dispatcher runs before that skip, so both surfaces are covered). On a `/auto-task` resume, before re-running any stage below or the approach-selection fold, check the marker: if `clarify_forward_pending.pending` is truthy, do NOT re-present either router — branch on `clarify_forward_pending.kind` (the origin discriminator; the two surfaces must be recorded in different places):
- **`kind: "clarify"`** — if the user supplied the owner's answers, map each to its pending question, record under `## Clarifications → ### Asked` and log a per-question `state.history` entry with `resolution: "asked-forwarded"`; clear the marker; continue to stage 5.
- **`kind: "approach"`** — if the user supplied the decision, treat it as the binding approach pick and clear the marker, then continue to approach-selection **step 4 (Record)**, which writes the SINGLE `## Approach` section + one `{ phase: "define-approach", chosen, method: "user", at }` entry (noting it was forwarded). Do NOT write `## Approach` or log `define-approach` in this branch — the record happens exactly once, in that step, so there is no double-record.
- **Either kind, no answer yet** — if the user resumed WITHOUT the answer, re-surface the still-pending question(s)/decision (NOT the router) and keep waiting.

"Clear the marker" means set `pending: false`, `kind: null`, empty `questions`. This dispatcher is a legitimate Phase-1 surface (`approved:false`), not "mid-pipeline re-asking" — the no-mid-pipeline-re-asking rule governs Phase 2–5, which this predates. On a fresh run (marker not pending) it is a no-op; proceed to stage 1.

Process (mandatory six-stage gate — do them in order, do not skip stages):

1. **Draft the full candidate question list.** Read the task description carefully. Enumerate every potential decision-changing ambiguity — do NOT filter yet, do NOT try to answer yet, just list them. Cover every category that has any ambiguity for this task (omit categories with none):

   - **Scope** — what's in / out (which files, modules, routes, user segments, platforms); whether adjacent broken things get fixed or parked.
   - **Acceptance** — what "done" looks like that the task left implicit (specific behavior, visual outcome, error/empty/edge handling, accessibility, i18n, mobile).
   - **Approach** — when more than one viable implementation exists and the choice changes blast radius, risk, dependency, API shape, or migration cost.
   - **Constraints** — runtime/browser/version compatibility, performance budget, dependency policy (add new dep vs. inline), naming or style conventions where the task could land either way.
   - **Data / state** — schema changes, defaults for new fields, behavior for existing rows, idempotency, backfill strategy.
   - **External systems** — credentials available, write authorization (which MCPs/APIs may mutate), target environment (staging vs prod), live URLs to inspect, design references.
   - **Verification** — how the user will judge success (specific URL/route/test/manual check), what counts as a regression worth blocking on.
   - **Trade-offs** — explicit user preferences that contradict obvious defaults ("fewer dependencies even if more code", "ship behind a flag", "prefer rewrite over patch").

   Apply the decision-changing test: "If I picked the wrong answer here, would the run fail, drift out of scope, miss an AC, or produce something the user wouldn't accept?" Drop questions that don't pass. The remainder is your draft list.

2. **Research each draft question.** For every candidate on the list, spend bounded effort trying to find a verifiable answer. Go deep enough to reach reliable evidence OR confirm there isn't any, then move on. Sources are limited to material that produces a CITE — a `file:line`, a doc URL, an MCP response, a memory entry, or the user's own verbatim words in the task description. No inference from "this looks like the convention." Sources, in roughly this order:

   - The task description itself — re-read carefully; users often answer in the prompt without realizing it. Cite the quoted phrase.
   - Repo state — `README.md`, `CLAUDE.md`, `package.json` / pyproject / equivalent for stack and dep policy, the directories and entry points the task obviously touches. Cite the `file:line`.
   - Prior auto-task runs — `.auto-task/<branch>/CONTEXT.md` if it exists for this branch, and the most recent CONTEXT.md from adjacent branches on the same area. Cite the section.
   - User memory — `~/.claude/projects/<slug>/memory/MEMORY.md` if it exists; project/feedback/reference memories often resolve approach/policy questions. Cite the memory file name.
   - Codebase via `Read` / `Glob` / `Grep` — for scope, existing patterns. Cite the `file:line`. **One example is not a convention** — to cite "the repo uses pattern X", you need ≥3 occurrences in distinct files and zero counter-examples in the area the task touches.
   - MCPs — the same allowance as the recon step below. Context7 for library API shape, Figma for design refs, Playwright for live-URL behavior, etc. Cite the MCP and the specific response.

   What you CANNOT cite, you CANNOT resolve. "Probably X", "usually X", "looks like X", "would make sense", "common pattern" — these are not cites. If your only basis is inference without evidence, the question goes to the Asked bucket in stage 3.

3. **Triage each candidate into one of two buckets.**

   - **Resolved** — verifiable answer found with a cite. Record under `## Clarifications` as `Q: <question> / A: <answer> / Source: <cite — file:line, doc URL, MCP source, memory entry, or quoted phrase from the task description>`. If you cannot produce a cite in this format, the candidate is NOT resolved — push it to Asked.
   - **Asked** — no verifiable answer found, OR the decision is high-stakes in a way even strong evidence cannot settle: a **write to an external system** or a **truly irreversible operation** (schema/data migration, deletion, anything in CLAUDE.md's "Executing actions with care" territory). For these, always ask even if you have a cite — the user has standing to override *before* the action happens, so they never land on the watchlist below (which records calls already made on the user's behalf). This is distinct from a merely *costly-but-reversible* decision: that stays Resolved and is surfaced on the Decision watchlist instead (see the weighting step next, and the render in stage 5).

   There is no third bucket. Do not invent "Defaulted", "Assumed", "Probably-X". Either you have a cite and resolve, or you don't and you ask.

   **Weight each Resolved decision — this is a *view* over Resolved, not a third bucket.** The bucketing above stays binary (cite → Resolved, no cite → Asked). But not every Resolved decision is equally safe to have made silently: a thinly-cited or hard-to-unwind call deserves the user's eyes even though it carried a cite. So score each **Resolved** decision on two independent 0–2 axes:

   - **Confidence (C)** — strength of the evidence behind the resolution. `2` = an explicit cite or ≥3 concordant occurrences with zero counter-examples; `1` = inferred from a single example or a soft signal; `0` = no real cite — in which case it was never Resolved and belongs in Asked.
   - **Cost-if-wrong (K)** — reversibility × blast radius, using the same two dimensions as the Difficulty (D) / Risk (R) rubric's reversibility and production-blast rows (defined later in Phase 1), but judged for this one decision. `2` = shapes a public API or a widely-consumed function signature, or is otherwise **expensive-but-possible to unwind** (reversible in principle); `1` = localized but non-trivial to change later; `0` = cosmetic or trivially reversible.

   **Reversible-vs-irreversible boundary.** `K == 2` covers only decisions that are yours to make but *costly to reverse*. A **truly irreversible** decision — one that fails the "reversible in principle" test (migrations, deletions, external writes) — is not a `K == 2` Resolved item at all; it routes to **Asked** per the override above. The two never overlap: irreversible → Asked; costly-but-reversible → Resolved + watchlisted.

   Scoring is inline with this triage — no separate pass — and applies at every effort tier (it is cheap prose, not a phase); when the Resolved bucket is empty there is nothing to score. The promotion rule that turns these two scores into the surfaced Decision watchlist lives in stage 5.

4. **Route, then ask (the two-step clarify surface).** If the Asked bucket is empty after stages 1–3, skip this step entirely — do NOT invent questions to "look thorough" (no router, no comment, nothing to record). A run where every ambiguity was resolved with evidence is a *better* run, not a lazier one. Otherwise, present the Asked bucket through the routing flow below.

   **On resume, this router is already bypassed.** The Resume dispatcher at the top of this gate (see above) runs before Step 4a and fully handles any forwarded pause; so if control reaches Step 4a here, `clarify_forward_pending.pending` is guaranteed false and the router presents normally. There is no second short-circuit inside this block — the single one lives in the dispatcher, which is why it can't be reordered below the router.

   <!-- CLARIFY-ROUTER-BEGIN -->
   **The person running `/auto-task` is often not the person who owns the ticket and holds the answers.** So the clarify surface is a **two-step router**, not a single question dump: first ask *how* the user wants to handle the open questions, then branch. This makes "forward it to the owner" a **first-class choice** the user can't miss, rather than a skippable aside. In a single pass the clarify step makes at most two `AskUserQuestion` calls (the router, then — on the answer-here branch — the questions); the forward branch makes only the router and defers the rest to a later resume (where re-surfacing still-pending items may add a call). This is one Phase-1 surface, not a new gate.

   **Step 4a — routing question (ALWAYS FIRST, MANDATORY).** This step runs only when the Asked bucket is non-empty and `clarify_forward_pending.pending` is false (on resume from a forwarded pause, the Resume dispatcher at the top of this gate has already handled it before this point). Before showing any clarifying question, present a single routing `AskUserQuestion` — "How do you want to handle these <N> open question(s)?" — with exactly two options:
   - **`Answer them here`** — the user answers inline now.
   - **`Give me a comment to forward`** — render a paste-ready ticket comment the user drops into the ticket for the actual owner.

   Set `expected_next_action: "user-approval"` and prefix the message with the run banner (per the Run-label convention).

   **Step 4b-answer — the user chose `Answer them here`.** Present the Asked-bucket questions via `AskUserQuestion` (1–4 per call; if more than 4, prioritize the highest-impact and fold the rest into PLAN.md's Unknowns). Each question MUST:
   - Be answerable with a short selection (offer 2–4 concrete options; avoid open-ended phrasing).
   - State the decision impact in the description so the user knows why it matters (what changes if A vs B).
   - Lead with the option you'd pick if forced to decide alone, marked `(Recommended)`.
   - Use a short header chip (≤12 chars).

   Record the answers as the Asked-bucket answers and continue to stage 5.

   **Step 4b-forward — the user chose `Give me a comment to forward`.** Render a **paste-ready ticket comment** wrapping the Asked-bucket questions (style contract below) in a fenced block under a short lead-in like "Forward these to the ticket owner:". Then PAUSE the run so the user can get the answers from the owner:
   - Write the STATE marker `clarify_forward_pending` = `{ "pending": true, "kind": "clarify", "questions": [ { "id": "...", "text": "..." } ], "at": "ISO-8601" }`.
   - Log a `{ phase: "define-clarify-forwarded", questions: [...], at }` entry to `state.history`.
   - Set `expected_next_action: "user-approval"` (a legitimate Phase-1 pause while `approved:false` — the Stop hook allows it) and STOP with a short banner'd surface: "Paste the comment into the ticket. When you have the owner's answers, resume `/auto-task` (or paste them here) and I'll record them and continue."

   Do NOT also show the question pickers in this branch — the whole point is that the user is delegating the answers.

   **Resume detection** for this forward pause is handled by the **Resume dispatcher** at the top of this gate (it runs before Step 4a, branches on `clarify_forward_pending.kind`, records the answers, and clears the marker) — so Step 4b-forward's only responsibility is to write the marker and pause, above. The dispatcher is where the `kind: "clarify"` / `kind: "approach"` branches live; keeping the resume logic in that single reachable location is what prevents a router re-fire on either the clarify or the approach-fold path.

   **Style contract for the paste-ready comment (Step 4b-forward).** The comment MUST:
   - **Keep it short.** Only the questions, tightly phrased. No preamble, no restating the whole task.
   - **Human-like**, as a teammate would actually write in a ticket thread — not a bulleted machine dump of option labels.
   - **No names.** Do not address anyone and do not sign off.
   - **No greetings / no "hi" / no salutation** and no closing pleasantries.
   - **Strictly business — functionality only.** Each line is a concrete functional/behavioral question about what the thing should do; drop process/meta framing ("I'm the AI running auto-task…"), confidence hedges, and decision-impact commentary meant for the developer.
   - **Voice.** Draft the question wording in the resolved **Comment voice** (see the `## Comment voice` section above). If a `VOICE.md` resolves, the questions should read in that voice; if none does, keep the plain teammate tone shown in the example. The rules above — no names, no greetings, functional-only, **and keep it short** — are hard constraints; they bind regardless of the voice.

   Example shape (adapt to the actual questions; do not copy verbatim):
   ```
   A few things to confirm before implementation:
   - Should the reCAPTCHA load only on the order-approval page, or across the whole account area?
   - On an expired approval link, show an error page or silently redirect to a fresh request?
   ```

   **Record it.** When the **forward branch** rendered a comment, include it verbatim in the `## Clarifications → ### Ticket comment` subsection in stage 5 below, so it is persisted with the questions it wraps (and available on resume / to a later reviewer). On the answer-here branch no comment exists, so there is nothing to record there; if the Asked bucket was empty there is no router at all.
   <!-- CLARIFY-ROUTER-END -->

5. **Record everything.** Write a `## Clarifications` section at the very top of `.auto-task/<branch>/PLAN.md` (above Feasibility). The section contains the two buckets, followed by the Decision watchlist view (a subset of Resolved — see the promotion rule below), and finally the paste-ready Ticket comment (only when the **forward branch** was taken in stage 4 — Step 4b-forward — since that is the only branch that renders a comment), in this order:

   ```
   ## Clarifications

   ### Resolved (evidence-backed)
   - **Q:** <question>
     **A:** <answer>
     **Source:** <cite — file:line, doc URL, MCP source, memory entry, or quoted task phrase>
   - ...

   ### Asked (user-provided)
   - **Q:** <question>
     **A:** <user's answer>
   - ...

   ### Decision watchlist (resolved by me, but consequential)
   - **Decision:** <the call I made>
     **Source:** <cite — same as this decision's Resolved entry>
     **Confidence:** <0-2>   **Cost-if-wrong:** <0-2>
     **If wrong:** <what breaks downstream if this call was wrong>
     **Unwind:** <how we'd back it out, or "hard to reverse — see risk disclaimer">
   - ...

   ### Ticket comment (paste-ready, only when the forward branch was taken — Step 4b-forward)
   <the exact human-like, name-free, business-only comment rendered in Step 4b-forward, in its own fenced block — see the CLARIFY-ROUTER block above>
   ```

   **Promotion rule (the Decision watchlist is a view over Resolved, not a new bucket).** After scoring in stage 3, copy a Resolved decision into the `### Decision watchlist` section when **`K == 2`**, OR when **`K == 1` and `C <= 1`**; every other Resolved decision stays silently in the Resolved subsection. A watchlisted item *also* remains in its Resolved entry — the watchlist is a view over Resolved that lifts the consequential calls to where the user will see them at approval, beside the risk disclaimer. It never surfaces a decision that isn't already Resolved, so the "no third bucket" rule holds: this is presentation, not a new classification.

   Omit any subsection whose content is empty. For the two buckets, an empty subsection is simply dropped. For the **Decision watchlist**, when nothing is promoted, drop the `### Decision watchlist` heading entirely — no "None." placeholder, since it is a derived view rather than a bucket the user must confirm is empty. Likewise the **Ticket comment** subsection is present only when the stage-4 **forward branch** was taken (it holds that comment verbatim); on the answer-here branch, or when there was nothing to ask at all, drop the `### Ticket comment` heading entirely. If both *buckets* are empty (no ambiguity at all), write `## Clarifications\n\nNone — task description was unambiguous against current repo state.\n` and skip the rest.

   Log to `state.history`: one entry per candidate question, in either bucket: `{ phase: "define-clarify", question: "...", answer: "...", resolution: "resolved|asked|asked-forwarded", source: "<cite for resolved; \"user\" for asked; \"user (forwarded)\" for asked-forwarded>", weight: { c: <0-2>, k: <0-2> }, watchlisted: <true|false>, at: "ISO-8601" }`. (`asked-forwarded` is an Asked question the user chose to forward via Step 4b-forward and answered on resume — see the Resume detection paragraph.) The `weight` object and `watchlisted` flag are set for **Resolved** entries (score `c`/`k` per stage 3; `watchlisted` true iff the promotion rule fired); for **Asked** entries set `weight: null` and `watchlisted: false`. Treat answers from both buckets as binding inputs to recon, plan body, AC table, and tier scoring.

6. **No mid-pipeline re-asking.** After this step, Phase 2–5 must not stop to ask clarifying questions. If a genuine new ambiguity surfaces later (typically because the codebase contradicts a Phase 1 assumption), that's a Loop-rule clause 3 ("external blocker") trigger — STOP and surface per the Surfacing protocol; do not silently ask. This is what forces stages 1–5 to be exhaustive *here*.

After clarifications are recorded, proceed to reconnaissance.

**Pre-plan reconnaissance (auto, no human gate).** Before invoking `auto-task-plan`, decide whether the task requires inspecting an external system, a running UI, or a documentation source to plan it properly. Do the inspection yourself — never punt this to the user.

Trigger reconnaissance when the task description involves any of:
- Visual / UI / styling / layout / responsive behavior ("the card looks wrong", "background image is off", "spacing on mobile").
- A specific page, route, component, or user-facing flow whose current behavior must be observed (not just inferred from code).
- A bug report tied to runtime behavior (console errors, network failures, interaction states, hover/focus/animation).
- A reference to an external/live URL the user provided (load it per the **Link handling** protocol below — two-tier fetch→Playwright, videos get screenshots + transcript).
- A library / framework / SDK / API whose current syntax or behavior is load-bearing on the plan (use Context7 MCP).
- A Figma file, design system, or visual reference the user linked or named (use the Figma MCP).
- Any other external system the task explicitly references (Notion docs, Slack threads, Linear tickets, Drive files, Gmail, Calendar, Asana, Ahrefs, Sanity, etc.) where the relevant facts are not in the repo.

Skip reconnaissance for pure backend / library / config / refactor / type-only changes, or tasks where reading the code is sufficient (and note the skip in `state.history` with `result: "recon-skipped"` and a one-line reason).

**MCP usage in Phase 1 is open.** Any MCP server currently available to the session may be used during reconnaissance if it is the most direct way to gather a fact the plan depends on. Common picks:

- **playwright** — running UI / live URL inspection (DOM, screenshots, console, network).
- **claude_ai_Context7** — official library / framework / SDK docs whenever the plan touches an external API; prefer this over web search per the Context7 server instructions.
- **plugin_figma_figma** — design files, component metadata, screenshots, design tokens, Code Connect mappings.
- **claude_ai_Notion / Google_Drive / Gmail / Google_Calendar / Slack / Asana / Ahrefs / FR_Sanity** — only when the task explicitly references content in that system.
- **ide** — `getDiagnostics` when the task hinges on currently-reported type/lint errors.

Rules that apply to every MCP used in recon:

1. **Read-only by default.** Do not mutate external state, send messages, post comments, create files in third-party systems, click destructive UI controls, submit forms, or sign in with real credentials unless the user explicitly authorized that specific write in the task description. Writes to MCPs are externally-visible actions per `~/.claude/CLAUDE.md` "Executing actions with care" — surface and ask first, otherwise stay read-only.
2. **Auth prompts are not a recon blocker.** If an MCP requires `__authenticate` / `__complete_authentication`, do NOT invoke it interactively during recon — log `result: "recon-blocked"` with reason `"<server> requires user auth"` and proceed to plan with the limitation called out in Unknowns.
3. **Mandatory prerequisite skills still apply.** Before any `use_figma` call, load the `figma-use` skill; before any `generate_diagram` call, load the `figma-generate-diagram` skill. The skill's own instructions override generic recon guidance.
4. **Stop as soon as the observation is sufficient.** Recon is not a full audit. One or two MCPs covering the relevant fact is enough.
5. **Close Playwright sessions when done (resource hygiene, applies to EVERY phase that opens one — recon, link-handling, Phase 3 verify, Gate A/B, Phase 7 preview).** A Playwright browser is a live process; leaving it open leaks resources and can wedge later navigations. As soon as you've captured what a step needs (snapshot, screenshot, console/network read, an AC check), call `browser_close` (and `browser_tabs` cleanup if you opened extra tabs). Likewise shut down any **disposable render harness / mock server** you started to reach a UI. Never carry an open browser across phase boundaries; the next phase that needs one opens its own.

**Link handling (two-tier load + resource-aware recon).** Any link posted in the task card / prompt is load-bearing context — a bug repro, a design ref, a spec, a demo video. Load each one; never plan around a link you didn't open.

1. **Enumerate the links.** Read the task description for URLs. As a mechanical assist you MAY call `hooks/extract-links.sh` (locate via the three-probe pattern used for `check-version.sh`; `CLAUDE_PLUGIN_ROOT` is empty in the Bash-tool env) — pipe the description in (`--text "<desc>"` or stdin) and it returns a JSON array of `{url,host,kind,strategy}` where `kind ∈ video|figma|doc|page`. It is fail-open (bad/no input → `[]`, exit 0) and is only an **assist, not the sole source**: it deliberately DEFERS bare scheme-less hosts (`loom.com/x`, `notion.so/x`) to avoid false positives, so you MUST also eyeball the description yourself for scheme-less or link-text references it won't surface.
2. **Two-tier load (the default for every link).** For each link, **first try an ordinary fetch** — `WebFetch` (or `curl` for a raw payload). If that returns **no usable data** — an empty body, a JS-only shell / SPA skeleton, a bot / consent / login wall, a non-2xx status, or content that plainly doesn't contain what the task points at — **fall back to Playwright**: `browser_navigate` to the URL, let it render, then `browser_snapshot` (and `browser_console_messages` / `browser_network_requests` when runtime behavior matters). The ordinary fetch is cheap and first; the Playwright fallback is the reliable second tier for anything client-rendered or gated. Record which tier produced the usable data.
3. **Videos (Loom and similar → screenshots + transcript).** For a link whose `kind` is `video` (Loom, YouTube/youtu.be, Vimeo, Wistia), a fetch returns almost nothing useful, so go straight to Playwright: `browser_navigate` to the video, capture a few **representative screenshots** (`browser_take_screenshot`) at key frames, and extract the **transcript** — open the transcript / captions panel and read it out of the DOM via the snapshot (or `browser_evaluate`). Save the screenshots under `.auto-task/<branch>/recon/` and fold the transcript's relevant points into the recon notes. A silent or transcript-less video is a limitation to note under Unknowns, not a blocker.
4. **Generalize to all external resource types.** This two-tier, resource-aware pattern applies to **all external resources** referenced in the task, not just plain web pages and videos — pick the most direct reader per `kind` and keep the fetch→Playwright fallback underneath: `figma` → the Figma MCP (load `figma-use` first); `doc` systems (Notion, Google Docs/Drive, Slack, Linear, Atlassian) → that system's MCP when available, else the ordinary fetch, else the Playwright fallback; `page` → fetch→Playwright. The generalization is the point: whatever the resource, try the cheap/native reader first and fall back to a real browser when it comes back empty.

**Cost bound.** Recon is bounded, never a stall: when a card carries many links, load the few most load-bearing on the plan and skip decorative or duplicate ones. Two-tier loading and video capture are subject to the same "stop as soon as the observation is sufficient" rule as every other recon step. The read-only / auth-is-not-a-blocker / prerequisite-skill rules above remain authoritative for every fetch and Playwright call here.

When triggered:

1. **Pick the target(s).**
   - If the user gave a URL → use it.
   - If the user named a library/framework/API → resolve via Context7.
   - If the user gave a Figma URL → use the Figma MCP after loading `figma-use`.
   - Else if the task is about a web app and a UI can be reached → prefer **local dev** (this is the local-dev-first principle that also governs verification). Resolve a local UI with this **reuse-or-improvise-else-surface ladder**:
     1. **Reuse** an already-running dev server if reachable (probe `http://localhost:3000` and common ports with a quick `curl -sI` or `browser_navigate`). **Do NOT auto-start the project's long-running dev server** — `pnpm dev` (and equivalents) is user-run per CLAUDE.md; that rule stands.
     2. **Improvise** a bounded, disposable render if no server is running: a component workbench the repo already has (Storybook, `ladle`, a test/preview harness), a one-off static build preview, or a minimal mock server — whatever renders the specific component/route. This is a *disposable* render for observation, distinct from the project dev server: it is spun up bounded and **closed right after** (see Playwright session cleanup). Mock/seed any data needed only to *reach* the real UI (see the mock/cut-corners rule in the AC contract).
     3. **Surface** only if no path to the UI exists at all (log `result: "recon-blocked"`, reason `"no reachable UI (no running server, no render harness)"`, note under Unknowns) — do not fabricate an observation.
   - Else if the task is about a known production/staging URL discoverable from the repo (e.g., README, env files) → use that, read-only.
   - If no target can be identified, log `result: "recon-skipped"` with reason `"no reachable target"` and proceed to plan — do NOT ask the user (the recon is best-effort; the plan can still proceed and flag the missing observation under Unknowns).

2. **Inspect.** Use the selected MCP(s) and/or `curl` to gather only what's needed to plan. For any link in the card / prompt, apply the **Link handling** protocol above (two-tier fetch→Playwright load; videos → screenshots + transcript; resource-aware reader per kind):
   - Current visible behavior of the relevant element/flow.
   - Console errors and failed network requests on the affected page.
   - DOM/computed-style facts that disambiguate the task.
   - **Baseline "before" screenshot (UI-visual tasks — capture when a UI can be reached).** If the change alters anything a user *sees* (layout, spacing, color, size, component appearance, a visible flow), this is the ONLY moment the pre-change state is renderable — capture it now (it is the "before" the PR pair uses *when* visual embedding is enabled). Reach the UI via the recon target-selection ladder above (reuse a running server → improvise a disposable render → mock/seed only what's needed to reach the real UI). Then Playwright: `browser_navigate`, drive the app to the exact state the change touches (open the dialog, expand the panel, reach the screen), `browser_take_screenshot` → `.auto-task/<branch>/recon/screenshot-before.png` (tight element/region crop, not full-page). **Close the Playwright session when done** (`browser_close`) — don't leave it open across phases. Record in the Recon notes which state was captured. **Never a blocker:** if no UI can be reached even after improvising, just note under PLAN.md Unknowns that no baseline was captured and continue — the "after" verification (Phase 3) and embedding (Phase 5) degrade gracefully (INCONCLUSIVE / note), they do not hard-stop.
   - Current library API shape / version-specific syntax when an external dependency is touched.
   - Design metadata (component names, tokens, layout dimensions) when a Figma reference is provided.
   - Stop as soon as the observation is sufficient to write a concrete plan. This is reconnaissance, not a full audit.

3. **Record.** Append a `## Recon` section to `.auto-task/<branch>/PLAN.md` (immediately after `Effort:`, before `## Critique`) with: target(s), MCPs used, what was checked, key observations (3-8 terse bullets), any screenshots saved under `.auto-task/<branch>/recon/`, and any blockers. Log a `state.history` entry: `{ phase: "define-recon", result: "done|skipped|blocked", mcps: ["..."], target: "...", summary: "...", at: "ISO-8601" }`.

Use the recon findings as input to the next step.

**Deferred consent check — run it now.** The **Visual-assets consent check** (defined in the Phase-1 pre-run section, grouped with the telemetry-consent check) is deliberately deferred to *here*: only now is UI/visual scope known. If this run has UI/visual scope and `visual_assets_enabled` is undecided, run that check now (before approach selection / the plan gate); otherwise it stays skipped. This is the "evaluate after reconnaissance" trigger of that check — do not run it earlier, or UI scope isn't yet known and it would wrongly self-skip.

**Approach selection (auto, with a conditional fold into the human gate).** Before invoking `auto-task-plan`, decide whether the task admits more than one materially different implementation. The detailed plan breaks down *one* approach — choosing which one is a decision in its own right, and everything downstream only verifies that the chosen approach was built correctly, never whether a better approach existed. This step makes that choice explicit and auditable so a wrong-approach-entirely plan can't sail through to approval looking internally coherent.

1. **Trigger.** Run approach selection when more than one viable approach exists AND the choice changes any of: blast radius, risk/reversibility, dependencies, public API shape, or migration cost (the same test as the clarifying-questions "Approach" category). If the task has a single obvious implementation — a localized bug fix, a copy change, a config tweak — skip it and log `{ phase: "define-approach", result: "skipped", reason: "single viable approach", at: "ISO-8601" }`. Do NOT manufacture alternatives to look thorough; a task with one honest approach is a faster run, not a lazier one.

2. **Generate candidates.** Produce 2–3 *short* approach sketches — NOT full task breakdowns (that work is wasted on the rejected ones). Each sketch has: **Name** (a 2–4 word handle, e.g. `inline-guard`, `extract-middleware`, `schema-migration`); **Description** (one paragraph — what it does and how); **Blast radius** (files/modules/layers touched); **Key risk** (the main thing that can go wrong); **Effort** (rough relative size); **Tradeoff** (the one-line "buys X at the cost of Y"). Scale generation effort to apparent complexity — the real Effort tier is computed later, from the chosen plan, so this is a provisional read:
   - Apparently simple-but-branching task → draft 2 sketches inline.
   - Apparently complex / high-blast / high-risk task → spawn 2–3 `general-purpose` Agents in parallel, each asked for ONE approach from a distinct angle (e.g. minimal-diff, idiomatic-to-this-codebase, robustness-first), each returning a sketch in the format above. Independent agents give genuine diversity; inline variants tend to be three flavors of the first idea. Prefix each Agent's `label` with `state.title` per the "Run label" convention.

3. **Score and select.** Score each candidate on fixed dimensions: AC-fit (does it deliver every behavior the task promises), blast radius, risk/reversibility, dependency cost, alignment with existing repo patterns, effort. Then:
   - **Clear winner** (one candidate dominates on the dimensions that matter for this task) → select it yourself.
   - **Close call OR high-stakes choice** — when no candidate clearly dominates, OR the choice touches a Risk-rubric score-2 dimension (schema/data migration, external/third-party API, auth/payments/data-integrity/multi-tenant) → do NOT self-decide. Present the top approaches to the user via `AskUserQuestion` as part of the Phase 1 human gate — this folds into the clarifying-questions surface, it is NOT a new gate. One question, 2–3 options (candidate name + one-line tradeoff each), lead with your recommended candidate marked `(Recommended)`. The user's pick is binding. Set `expected_next_action: "user-approval"` for the call, as for any Phase 1 `AskUserQuestion`. This folded question **`routes through the CLARIFY-ROUTER`** exactly like the clarifying-questions stage above: present the router first ("answer here" vs "forward as a comment"); on the forward branch, render the paste-ready comment and pause, and the fold's forward branch reuses clarify_forward_pending with `kind: "approach"`. On resume the **Resume dispatcher** at the top of the clarify gate (which runs on every Phase-1 re-entry, before this fold) handles it via its `kind: "approach"` branch: it treats the reply as the binding pick, clears the marker, and lets **step 4 (Record) below** write the single `## Approach` section + one `define-approach` entry — so the approach choice is neither lost, recorded as a clarify `asked-forwarded` answer, nor double-written. Because an approach choice is a decision among options (not an open question), phrase it in the comment as ONE concise functional question that states the decision and lists the candidate options (e.g. "Which approach for the reCAPTCHA fix — (a) load on the order page only, or (b) self-load on demand for every webhook?"), still obeying the style contract (no names, no greetings, functionality only).

4. **Record.** Write an `## Approach` section to `.auto-task/<branch>/PLAN.md`, immediately after `## Recon` (before the plan body): the chosen approach, then each rejected candidate with its scores and a one-line rejection rationale. If the approach choice was folded to the user and a ticket comment was rendered for it, persist that comment verbatim here too, as a `### Ticket comment` note under `## Approach` — kept separate from the clarify-stage `### Ticket comment` note (which, when present, holds only the clarifying comment; it may not exist at all if the Asked bucket was empty). The approach comment lives with its own decision log — same intent: it stays available on resume / to a later reviewer. This decision log lets a reviewer — or a resumed run — see not just what was built but why this path over the others. Log to `state.history`: `{ phase: "define-approach", candidates: ["<names>"], chosen: "<name>", method: "auto|user", at: "ISO-8601" }`.

`auto-task-plan` then breaks down ONLY the chosen approach.

Invoke the `auto-task-plan` skill internally. The plan MUST include an explicit **Acceptance Criteria** section with objectively verifiable items. The `auto-task-plan` skill's default template does NOT produce one — you MUST append it before stopping, or the run cannot proceed.


## ac-preflight — relocated verbatim from SKILL.md

**AC pre-flight (NON-NEGOTIABLE — runs BEFORE the critique pass and BEFORE the human gate).** The AC self-checks above test the *shape* of the table; pre-flight tests the *premise* of every AC against the actual repo state. Without it, an AC can look perfect on paper while resting on a false assumption (a wrong jq path, a stale baseline, a tool that produces unreliable output) — and the failure mode is that approval is granted on a flawed plan and the run wastes effort discovering it in Phase 2.

For each AC row whose `Verification method` is an executable command:

1. **Dry-run the command** against the current working tree (before any code change). Capture exit code + relevant output.
2. **Pin the baseline** — write the output (or a summary if large) to `.auto-task/<branch>/recon/ac-<#>-baseline.{json|txt}` and reference it from `state.history` as `{ phase: "define-preflight", ac: <#>, result: "pinned|failed-syntax|unreliable-signal", baseline: "<value or path>", at: "ISO-8601" }`.
3. **Sample-verify when the AC depends on an external tool's output** (knip, jscpd, ts-prune, knip-ish dead-code detectors, complexity scanners, dependency analyzers, anything that produces a list of "things to fix"):
   - Pick a sample of **≥5 entries** from the tool's list (or all entries, whichever is smaller).
   - For each sample entry, run an independent check that would falsify the tool's claim (e.g., for "unused export X", run `grep -rln '\bX\b' <scope>` and require 0 hits; for "complexity > 10 in function Y", read the function and count branches).
   - Compute the false-positive rate: `FP = (entries whose independent check contradicts the tool) / sample size`.
   - **If FP > 20% (more than 1-in-5 wrong on the sample):** the AC's premise is **unreliable**. Do NOT advance to the human gate. STOP and surface to the user with: the tool, the sample tested, the FP rate, the contradictions found, and a suggested pivot (configure the tool, switch tools, or drop the AC). Treat this as a Loop rule clause 2 ("out-of-scope") trigger BEFORE the run even starts — better to surface during define than mid-execute.
   - **If FP = 0 on a small (5) sample but the kill list is large (>50 entries):** widen the sample to ~10% of the list (capped at 20) and re-test. A clean small sample on a large list is suggestive, not conclusive.
4. **Pre-flight syntax check.** If the AC command itself errors out (jq path wrong, file not found, tool not installed) — fix the AC command, not just the symptom. An AC that can't be executed at all is also unreliable.

Pre-flight produces one of three outcomes:

- **All ACs pinned, FP ≤ 20% on every sampled list** → advance to the critique pass.
- **Any AC's command errors** → fix the AC text (re-write the command), re-run pre-flight for that AC. Do not stop for human approval until every AC has a clean dry-run.
- **Any sampled list shows FP > 20%** → STOP and surface BEFORE the human gate. The plan is built on a wrong premise; user must pivot scope or switch tools.

Pre-flight evidence (the pinned baselines + sample-verification log) MUST appear in `.auto-task/<branch>/PLAN.md` as a `## AC Pre-flight` section between Acceptance Criteria and Critique, with one terse bullet per AC: `AC #N — baseline pinned (<value>); sample-verified N entries, FP=X%`.

In addition to what `auto-task-plan` produces, write a short feasibility note at the top of `.auto-task/<branch>/PLAN.md`:
- **Feasibility:** GREEN / YELLOW / RED with one sentence.
- **Unknowns:** items that would change the plan if learned.
- **Blast radius:** files/modules touched, consumers to keep working.
- **Effort:** `<TIER> — D=<n> R=<n>` (see rubric below).


## critique-and-disclaimer — relocated verbatim from SKILL.md

**Critique pass.** Before stopping for human approval, spawn a `general-purpose` Agent (prefix its `label` with `state.title` per the "Run label" convention) with a fresh-context prompt containing:
- `.auto-task/<branch>/PLAN.md` as the only input.
- Explicit ask: "Critique this plan on four dimensions. Return at most 6 terse bullets total, one issue per bullet, prefixed with the dimension tag. Omit a dimension if it has no issues. If nothing to flag, return exactly `No issues found.`
  - **[AC]** Each Acceptance Criterion objectively verifiable? (Good: 'login route returns 200 for valid creds'. Bad: 'auth works correctly'.)
  - **[Blast]** Blast Radius honest given the AC? Files or layers likely missing?
  - **[Edge]** Missing edge cases the plan should explicitly handle or explicitly defer.
  - **[Rollback]** For schema/data/migration/irreversible changes, is rollback addressed? Mark N/A for pure code.
  Do not propose new work or rewrite the plan — only flag concerns."

**Critique → re-plan loop.** The critique is not advisory wallpaper that the user has to mine for what matters — its mechanically-fixable findings get fixed *before* the human sees the plan, so the approval gate adjudicates only genuine judgment calls. After the agent returns, classify each finding:

- **Structural-fixable** — a plan defect resolvable without the user: a missing edge case a task should handle, a blast-radius file the plan omitted, a non-falsifiable/unobservable Acceptance Criterion, a missing rollback step for an irreversible change. These are gaps in the plan's own internal completeness.
- **Judgment-required** — a concern needing a human decision: a scope tradeoff, an approach-worth-the-risk question, anything where the "fix" is a choice rather than a correction.

Then loop, bounded by tier (LIGHT: 1 round; STANDARD/HEAVY: 2 rounds):

1. Amend `.auto-task/<branch>/PLAN.md` to resolve every **structural-fixable** finding (add the edge case to a task, widen Blast Radius, rewrite the weak AC, add the rollback step). Keep each amendment minimal and traceable to the finding that prompted it.
2. Re-run the critique agent on the amended plan (fresh context, same prompt). Do NOT trust the amend blindly — the re-critique is the safety net, mirroring the global "re-invoke code-review after every fix" rule.
3. Exit the loop when the critique returns `No issues found.`, only **judgment-required** findings remain, or the round cap is hit.
4. Log each round to `state.history`: `{ phase: "define-critique", round: <n>, fixed: ["<finding tags>"], remaining: ["<finding tags>"], at: "ISO-8601" }`.

**Record.** Write the final `## Critique` section in `.auto-task/<branch>/PLAN.md`, placed immediately after the `Effort:` line and before the plan body, with two parts: **Auto-fixed** (what the loop resolved — one bullet each, naming the finding and the amendment) and **For your judgment** (the remaining judgment-required findings, verbatim). If the loop closed everything, the second part is `None — all critique findings were structural and auto-fixed.`; if the critique found nothing at all, the whole section is `No issues found.` verbatim. The user reads the plan (now repaired) plus the residual judgment calls, and decides whether to amend further, accept, or reject. The `[Rollback]`-dimension trigger for the risk disclaimer (below) fires on a concern surfaced in *either* part.

**High-risk disclaimer (assembled BEFORE the approval presentation).** The approval gate is the user's last chance to refuse the run before code starts changing. For low-risk tasks the plan + critique is enough — adding a disclaimer just trains the user to ignore them. For high-risk tasks a disclaimer is mandatory and must be specific enough to change the user's behavior, not generic boilerplate.

A disclaimer is REQUIRED when ANY of the following holds (compute from the rubric scores you already wrote):

- `effort.tier === "heavy"` (i.e., `max(D, R) >= 6`).
- `effort.risk >= 5` (cumulative risk is high even if difficulty is modest).
- Any single risk dimension scored a `2`. Recheck each one — they map to specific, concrete user-visible failure modes:

| Dimension | Score-2 trigger | What the disclaimer must say |
|---|---|---|
| Reversibility | schema migration / data migration / irreversible side effect | "This run includes irreversible changes (schema/data). A bad outcome cannot be rolled back by reverting the commit — recovery requires manual data work. Confirm before proceeding." |
| External integration | external API / third-party | "This run wires up an external third-party (<name>). Bad input or misuse can incur charges, leak data, or rate-limit the service. Confirm the integration target and credentials are correct." |
| Test coverage | none on touched code | "The touched code currently has no automated test coverage. Regressions introduced by this run will not be caught by `auto-task-verify` and may only surface in production. Confirm you accept the lower verification floor." |
| Production blast | auth / payments / data integrity / multi-tenant | "This run touches a critical surface (<auth | payments | data integrity | multi-tenant>). Bugs here can compromise user accounts, mis-charge, corrupt records, or cross tenant boundaries. The blast radius if something goes wrong is large." |

Also REQUIRED when the Critique pass returned a specific concern in the `[Rollback]` dimension, even if it didn't pass any other threshold above.

Assembly rules:

1. **Trigger by score, not by feel.** If thresholds say disclaimer, you include one — even if the plan looks "obviously safe" to you. Conversely, do NOT add one for LIGHT/STANDARD tasks that don't trip any threshold; noise dilutes the signal.
2. **Be specific.** Replace `<name>`, `<auth | payments | …>`, and the like with the actual values from the plan. A generic "this is risky, are you sure?" does not change behavior.
3. **List every trigger that fired.** If two risk dimensions both hit `2`, both bullets appear. Don't pick the "biggest one" — the user needs to see the full surface.
4. **End with an explicit ask.** The disclaimer block closes with a single line: `**Confirm you understand these risks before approving the plan.**` This tells the user that typing `approved` carries weight.
5. **Place it BELOW the plan body and ABOVE the Critique** in the presentation, under a heading `## ⚠ Risk disclaimer (REQUIRED — read before approving)`. Position matters: the user is more likely to scroll past it if it's at the very top (looks like boilerplate) or at the very bottom (already typed approval). Mid-presentation, just before the section they'll read most carefully (Critique), is the highest-attention slot.
6. **Log the assembly.** Write a `state.history` entry `{ phase: "define-disclaimer", triggers: ["<list of triggers that fired>"], dimensions: ["<dimension names>"], at: "ISO-8601" }`. If no disclaimer was warranted, log `{ phase: "define-disclaimer", result: "not-required", at: "..." }` — the explicit "no" record makes it auditable whether the call was made or skipped.

The disclaimer is generated from the rubric values + plan metadata; do NOT invent risks the rubric didn't score. If you find yourself wanting to write a disclaimer for something the rubric scored as low-risk, that's a signal the rubric was wrong — re-score `effort` and update `effort.history` instead of adding ad-hoc warnings.

If the user proceeds with approval despite a disclaimer, that's a binding choice — record it in CONTEXT.md under `Human choices → Plan approval → Disclaimer acknowledged` with the list of triggers the user accepted. Later phases (Phase 4 review, Gate B) should NOT re-raise the same risk as a finding to fix; the user already made the call. They MAY raise it as a follow-up if the implementation made the risk worse than the plan anticipated.

## run-label-convention — relocated verbatim from SKILL.md

_The Run-label / phase-banner convention, moved here from the spine's Operating principles. It lives in the Phase-1 reference because `state.title` is **derived in branch-setup step 4** above, which is the point from which the label and banner become available. It is carved out rather than summarized because it is **presentation only** — by its own terms it introduces no gate, no yield and no `AskUserQuestion`, and never alters `expected_next_action` — so it is exactly the kind of prose the always-loaded spine should not spend bytes on. The spine keeps the operational rule (prefix every Agent label; prefix an already-occurring user-facing message with the banner) and points here for the enumeration of qualifying surfaces._

- **Run label (cosmetic — never changes control flow).** Every run carries a concise human-readable `state.title` (derived at branch setup, see Phase 1). Surface it two ways so a session is identifiable at a glance: **(a)** prefix EVERY spawned Agent's `label`/`description` with the title, so the running-agent status line reads `<title> · <activity>` (e.g. `Ticket-comment forwarding · Gate B adversarial verify`) — this applies uniformly to the Phase-1 critique agent, the approach-selection `general-purpose` agents, and the Gate A / Gate B `task-execution-verifier` agents, with NO spawn site exempt; **(b)** whenever a phase *already legitimately* emits a user-facing message AND `state.title` already exists (it is derived in branch-setup step 4, so the banner is available from that point on), PREFIX that message with a one-line banner `▶ auto-task: <title> — Phase N (<phase-name>)`. The qualifying surfaces are: the Phase-1 telemetry-consent / clarifying-questions / plan-approval prompts (clarifying-questions here covers the Phase-1 clarify routing question and the forwarded-comment pause), the Phase-5 docs-update ask (`ask` mode, non-empty staleness report), the Phase-5 push/PR prompt, a Phase-6 bot-review surface, a Phase-7 preview surface, the Phase-9 release ask (`ask` mode, something to release) or a Phase-9 `partial-failure`/`failed` surface, a Loop-rule surface, or a destructive-action confirmation. **Carve-out:** the one sanctioned user surface that fires *before* branch setup — the pre-preflight version-check ask (new runs only) — runs before any title, branch, or slug exists, so it carries NO banner. (These qualifying surfaces are the post-title `user-approval`/`user-push-prompt` rows of the yield-point table, plus the pre-approval telemetry-consent ask, minus that pre-title version-check row.) This adds NO new message: it only labels the messages that already occur. It does **not** license a per-phase "message to the user" — the unattended phases (2, 3, 4, Gate A/B) stay silent and make tool calls per the NON-YIELDING CONTRACT above, so they emit no banner. This is presentation only: it introduces no gate, no yield, and no new `AskUserQuestion`, and it never alters `expected_next_action`.
