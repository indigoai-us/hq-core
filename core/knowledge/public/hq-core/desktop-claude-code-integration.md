---
type: reference
domain: [engineering, product]
status: canonical
tags: [desktop-app, claude-code, codex, grok, local-bots, launch, integration]
relates_to: [knowledge/public/hq-core/hq-desktop-app.md, knowledge/public/hq-core/desktop-rich-messages.md]
verified_against:
  - repo: hq-desktop-app
    ref: origin/main@c621a6a1
    app_version: 0.10.347
    date: 2026-09-27
  - repo: hq-cli
    ref: origin/main@dfe49a48
    date: 2026-09-27
---

# HQ Desktop and Coding Tools (Claude Code, Codex, Grok)

HQ Desktop does not run agent sessions itself. Agent work runs in the user's
own coding tool (Claude Code, Codex or Grok Build) against the HQ folder. The
desktop connects to those tools in four ways: the Launch menu, per-item
"Open in Claude Code" actions, local bots, and the Setup bot.

## What was removed

The in-app Sessions subsystem was removed in 0.10.270 (hq-desktop-app PR #826,
2026-09-16). That removal took out:

- the Sessions page, the composer's Session button, and session sharing;
- the Rust session runtime (`agent_session*`, `sessions*`, session share and
  link modules) and 31 session-owned Tauri commands;
- the older desktop-alt `DesktopApp.svelte` tree that only the Sessions shell
  routed to.

Kept, because other features depend on them: provider sign-in and preflight
(now `apps/sync/src-tauri/src/commands/agent_providers/`), usage telemetry
scanning, and Work Mesh wiring. Work Mesh still shows live sessions that
people start in their own tools.

Any earlier HQ doc describing Desktop spawning PTY terminals, a session tab
bar, `spawn_worker_skill`, or `orchestrator.rs` state writes describes code
that no longer ships.

## Launch menu

The title-bar Launch menu opens the HQ folder in a coding tool with no
prefilled prompt (`packages/ui/src/settings/launch-actions.ts`).

| Tool | Tried in order |
|---|---|
| Claude Code | `claude://` deep link to the Claude desktop app → `claude` CLI in a new terminal window → copy to clipboard |
| Codex | ChatGPT app Codex workspace → `codex` CLI in a new terminal → clipboard |
| Grok Build | `grok` CLI in a new terminal |

Safety checks in `apps/sync/src-tauri/src/commands/launch.rs`:

- The terminal launcher accepts only `claude`, `codex` or `grok`.
- `claude://` URLs are checked byte by byte before they reach the OS opener.
- "Reveal in Finder/Explorer" only opens paths inside the user's home
  directory.

The `#welcome` channel offers the same launchers with `/setup` prefilled for
people who prefer to run setup in their own tool. Because the Claude desktop
app scans skills before a link-opened folder is trusted, the deep link sends a
plain-language prompt that tells Claude to read
`.claude/skills/setup/SKILL.md` (with repair steps if HQ is incomplete)
instead of the bare `/setup` command.

## Open in Claude Code from Files and Projects

Files, project and issue views have "Open in Claude Code" actions. For files,
`open_authorized_file_in_claude` takes only an HQ-relative path, checks
company membership and the company scope gate, and builds the prompt and
deep link itself. No caller-supplied folder, prompt or URL is passed through.

## Local bots

A local bot is a long-running agent on the user's machine that uses the
user's own coding-tool login. The desktop's New bot flow and Settings → Bots
call the `hq` CLI (`hq bot … --json`); the CLI owns the bot's identity,
credentials, launchd agent and process
(`apps/sync/src-tauri/src/commands/bots.rs`).

- Runtimes: `--runtime claude|codex|grok`.
- Kinds: personal (acts as the owner, stays on this machine) or company
  (`--kind company --company <slug>`, its own identity, scoped to its
  companies).
- Other create flags the app passes: `--display-name`, `--worker`,
  `--intro`, `--kickoff`, `--memory synced|local`, `--model`,
  `--no-auto-approve`.
- Lifecycle: `list`, `list --remote`, `start`, `stop`, `rm`, `set --model
  --effort`, `adopt`, `restore [--all]`, `promote <name> --company <cmp_uid>`.
- When a bot's coding-tool sign-in expires, the bot's conversation shows a
  banner with one button that re-runs the vendor sign-in and restarts the
  paused bots.
- Settings → AI tools and Settings → Bots install the three CLIs and sign the
  user in.

See `hq-desktop-app.md` for personal vs company rules, handles and restore.

## Guided setup

Guided setup is a conversation with the **Setup bot**, a personal local bot
named `setup` created from `core/workers/public/setup`
(`packages/ui/src/chat/setup-bot.ts`). It runs under whichever coding tool is
signed in (Claude first, then Codex, then Grok). The bot works through the
same phases as `.claude/skills/setup/SKILL.md`, asks in plain words, and uses
`hq-block` `suggestions` and `setupDone` blocks for reply buttons and the
finish card (`desktop-rich-messages.md`).

If no coding tool is installed, the setup card offers a one-click Claude Code
install and then guides the user through signing in inside Claude Code. HQ
never receives the password.

## Shared HQ folder

Desktop sync and the coding tools read and write the same HQ folder. The sync
runner resolves conflicts with `--on-conflict keep`. There is no file locking
between the desktop and a coding tool; the desktop no longer writes project
or orchestrator state files, so the old `state.json` write race does not
apply.

## Sources

hq-desktop-app `origin/main@c621a6a1`:

- `CHANGELOG.md` (0.10.270, 0.10.347), PR #826 commit message
- `packages/ui/src/settings/launch-actions.ts`, `packages/ui/src/home/V4TitleBar.svelte`
- `packages/ui/src/chat/setup-channel.ts`, `setup-bot.ts`, `BotSignInBanner.svelte`
- `apps/sync/src-tauri/src/commands/launch.rs`, `bots.rs`, `desktop_alt.rs`, `agent_providers/mod.rs`
- `crates/hq-desktop-core/src/daemon.rs` (runner arguments)

hq-cli `origin/main@dfe49a48`: `src/commands/bot.ts`.
