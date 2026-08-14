# Install & update

- [Marketplace install (recommended)](#marketplace-install-recommended)
- [Updating](#updating)
- [Release notes — what you just got](#release-notes--what-you-just-got)
- [Offline / development install (fallback)](#offline--development-install-fallback)
- [Optional / opt-in extras](#optional--opt-in-extras)
- [Hard prerequisites](#hard-prerequisites)

## Marketplace install (recommended)

This repo is its own plugin marketplace. From inside Claude Code:

```
/plugin marketplace add o8o0o8o/auto-task-plugin
/plugin install auto-task@auto-task-plugin
```

That copies the plugin into your plugin cache and **auto-wires everything** — the twelve skills, the `task-execution-verifier` agent, and all eleven core hooks (`hooks/hooks.json`). No `settings.json` editing, no symlinks, no `install.sh`.

Plugin skills are namespaced under the plugin name, so you invoke the orchestrator as:

```
/auto-task:auto-task <plain-English task description>
```

and the siblings as `/auto-task:auto-task-plan`, `/auto-task:auto-task-fix`, and so on.

## Updating

### Auto-apply (no command to type)

When a newer version exists, the next `/auto-task` run offers to update. Choose **"Update it for me (auto-apply)"** and the bundled `hooks/apply-update.sh` applies it, detecting your install layout automatically:

| Your install | What auto-apply runs |
|---|---|
| Marketplace | `claude plugin update auto-task@auto-task-plugin`, at your install scope |
| Offline / dev (`install.sh`) | `git pull --ff-only` in the clone |
| Copy (`install.sh --copy`) | Nothing — re-run `install.sh` from your clone |

The git path is **fast-forward only**. It never forces and never switches your branch, so be on the release-tracking branch (`main`) to pull a release. A dirty, diverged, or upstream-less tree fails cleanly with a message rather than clobbering your work. A copy install has no source link to pull from, which is why it can't self-update.

### Restart to load

An update *stages* the new version, but the running session keeps the old code — hooks load at session start, and a marketplace update needs a restart to apply.

So after auto-apply: **restart Claude Code**, then re-run `/auto-task`. Re-invoking in the same session would reload nothing.

### Updating by hand

```
/plugin update auto-task@auto-task-plugin
```

You can also run the updater standalone with `bash hooks/apply-update.sh`.

The bundled `check-version.sh` SessionStart hook reminds you at most once per day when a newer version is published, so you don't have to remember to check. Updates ship only when the maintainer bumps `version` in `plugin.json`.

## Release notes — what you just got

You never have to read the changelog to find out what an update did. The first session on a new version, the bundled `release-notes.sh` hook prints a short, **user-facing** summary:

```
auto-task is now on 0.24.0 — what's new:
  • 0.24.0 — Tightens both main-sync points so a run always starts from the latest default branch…
  • 0.23.0 — Reshapes run-outcome telemetry to be actionable, not vanity…
```

It reads `.claude-plugin/release-notes.json`, which ships with the plugin — **no network request** — and shows each version exactly once, tracked by a single stamp at `~/.claude/auto-task/last-seen-version`.

A few deliberate behaviors:

- **A fresh install stays silent.** There is no delta to report.
- **Several versions at once** shows the newest three plus a `(+N earlier releases in these notes)` line. That qualifier is deliberate: the bundled file keeps only the newest ten releases, so for a wider gap, that count is what these notes hold — not everything you gained.
- **Only user-visible changes appear.** A release that changes nothing you can observe (an internal refactor, dev-only tooling, a docs sync) is marked `<!-- release-notes: skip -->` in the changelog and produces no note at all, rather than filler.
- **Strictly best-effort.** A missing or unreadable notes file, or no `jq`, means you simply see nothing — never an error, never a slower session. If the "already shown" stamp can't be written, the notice is suppressed rather than repeated every session.

> **Not included: a "what *would* I get?" preview before updating.**
>
> An earlier version of this feature also fetched notes for versions you did not have yet. It was dropped: rendering a file fetched over the network kept opening ways for hostile JSON to forge notice lines or blow up the message size, and the input space is unbounded. Reading only the bundled artifact removes that trust boundary instead of adding another validation layer on top of it.

## Offline / development install (fallback)

If you can't use the marketplace — air-gapped, or hacking on the plugin itself — `install.sh` symlinks the skills and agent into `~/.claude/` and prints a hooks snippet:

```sh
git clone https://github.com/o8o0o8o/auto-task-plugin.git ~/.claude/auto-task-plugin
cd ~/.claude/auto-task-plugin
./install.sh
```

It symlinks the twelve skills into `~/.claude/skills/` and the verifier agent into `~/.claude/agents/`, then prints a settings snippet with absolute paths for the hooks.

**Merge that snippet into `~/.claude/settings.json` yourself.** Preserve your existing keys, and append to the `hooks.PreToolUse` / `hooks.Stop` arrays if they already exist. The skills load without the merge, but the gate-enforcement and anti-stall hooks won't fire.

With this path the skills use their bare names (`/auto-task`), not the namespaced form.

**Flags and updates:**

- `--copy` copies files instead of symlinking.
- `--uninstall` removes the links.
- To update: `git pull` inside the clone. Symlinks pick up changes automatically; if you used `--copy`, re-run `./install.sh`.

The SessionStart update-notice fires under either install path — `check-version.sh` self-locates its manifest, via `${CLAUDE_PLUGIN_ROOT}` on a marketplace install or relative to its own path on the symlink layout.

## Optional / opt-in extras

### `inject-history-reminder.sh` (`UserPromptSubmit`)

Lets non-bundled tools discover the per-branch history folder so they honour the [read-before-review contract](usage.md#read-before-review-contract). Wired in every install but **gated OFF by default**:

```sh
bash hooks/settings.sh set history_reminder_enabled true    # false to disable
```

It emits nothing outside auto-task branches, so unrelated prompts pay no token cost.

Enabling via a settings key — rather than a pasted `settings.json` snippet — is what makes it reachable on a marketplace install, where the plugin lives in an opaque per-version cache dir that `${CLAUDE_PLUGIN_ROOT}` can't expand into `settings.json`.

### Recommended permissions

The inert `_optional_recommended_permissions` block in `settings-fragment.json` denies bare `git push` and asks before `gh pr create`, turning the Phase 5 push prompt into a mechanical gate.

It's opt-in for two reasons: the skill already prompts once, and the block affects all your work, not just auto-task runs.

## Hard prerequisites

- `git` ≥ 2.30
- `gh` (GitHub CLI) for PR creation
- `jq` (used by the hook scripts)
- `curl` (used by the SessionStart update-notice hook; absence just disables the notice)
- `bash` ≥ 3.2 — the version macOS ships with works, but POSIX `sh` does not, since the hook scripts use bash features
