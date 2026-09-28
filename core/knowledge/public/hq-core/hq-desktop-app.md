---
type: reference
domain: [engineering, product]
status: canonical
tags: [desktop-app, hq-desktop, onboarding, local-bots, messaging, sync, company-isolation]
relates_to: [knowledge/public/hq-core/desktop-rich-messages.md, knowledge/public/hq-core/desktop-claude-code-integration.md, knowledge/public/hq-core/desktop-company-isolation.md]
verified_against:
  - repo: hq-desktop-app
    ref: origin/main@c621a6a1
    app_version: 0.10.347
    date: 2026-09-27
  - repo: hq-cli
    ref: origin/main@dfe49a48
    date: 2026-09-27
  - repo: hq-cloud
    ref: origin/main@e486a79
    date: 2026-09-27
---

# HQ Desktop App

HQ Desktop is one Tauri 2 app with a Svelte 5 interface. On a machine without
HQ it runs as the onboarding installer; after setup it is the long-lived HQ
workspace window plus a menu-bar (tray) icon. The shipped app is built from
`apps/sync`; the shared interface lives in `packages/ui` and the Rust logic in
`crates/hq-desktop-core`. This page lists what the app does as of version
0.10.347. For the pre-release React specs from February 2026, see
`hq-desktop/` (historical).

## Platforms

- macOS: one universal build (Apple silicon and Intel).
- Windows: native installers for x64 and arm64.
- Update channels: stable, beta, alpha, served from the app repo's GitHub
  Releases. The app defers a restart for an update while it is focused or a
  meeting is recording, and shows a sidebar card to apply pending updates.
- Global shortcut Opt/Alt+Shift+O opens and closes the main window.

## Layout

The main window is a messaging shell with a left sidebar and full-window pages.

| Area | What it is |
|---|---|
| Sidebar | Conversations (DMs, group messages, channels, bots), a pinned `#welcome` channel, and a **Companies** section that pins each company's home channel. The Companies section shows your three most active companies unless you pin some. A "Show bot messages" toggle (off by default) hides agent-to-agent traffic from the list, unread counts and notifications. |
| Title bar | Launch menu, Files and Projects icons, and navigation back/forward. |
| Notifications | Notification history. |
| Meetings | Detected and recorded meetings. |
| Marketplace | Desktop only (hidden in the web build). |
| Library | Tabs: skills, workers, installed, marketplace, submit, profile. |
| Files | Explorer for the personal vault and each company vault on this machine: reading view with properties, `[[links]]`, outline and backlinks. Settings folders and key files are never shown. |
| Projects | One company's projects at a time, as a board or a list. A company home channel also has a Projects tab next to Chat. |
| Settings | Sections: profile, companies, general, agents, bots, appearance, notifications, sync, meetings, updates. |

## Keyboard shortcuts

`Mod` is Cmd on macOS and Ctrl on Windows. Cmd+/ (Ctrl+/) shows the full list,
including while typing in a message box.

| Keys | Action |
|---|---|
| Mod+K | Command palette |
| Mod+, | Settings |
| Mod+/ | Keyboard shortcut sheet |
| Mod+1 | Notifications |
| Mod+2 | Meetings |
| Mod+3 | Marketplace (desktop only) |
| Mod+4 | Library |
| Mod+5 | Files (desktop only) |
| Mod+6 | Projects (desktop only) |
| Mod+N | New chat |
| Mod+F | Search messages |
| Mod+Shift+F | Jump to conversation |
| Mod+Shift+] / Mod+Shift+[ | Next / previous conversation, in sidebar order |
| Mod+P | Sidebar: show only personal |
| Mod+O (in Files) | Jump to any file |
| Cmd+[ / Cmd+] (macOS), Alt+Left / Alt+Right (Windows) | Back / forward inside the app |

Shortcuts other than Mod+/ and Escape do not fire while focus is in a text
field.

## Onboarding and the Setup bot

1. First launch plays a short welcome film, then the onboarding wizard:
   sign-in, HQ folder choice, usage-data consent (defaults to "Share usage
   data"), connector import, dependency install and HQ template download.
   When no coding tool is installed, the setup card offers a one-click Claude
   Code install and then walks the person through signing in inside Claude
   Code's own window; HQ never receives the password.
2. The app opens on `#welcome`. This is a client-side pinned channel (wire id
   `setup`, display name `welcome`). Boot keeps landing there until setup has
   been run once on this machine.
3. **Run Setup** creates the **Setup bot**: a personal local bot named `setup`,
   created with `hq bot create setup --worker setup` from the core worker
   template `core/workers/public/setup`. It gets a random friendly display
   name (for example Pickles or Mochi) that no bot the person can see already
   uses. The runtime is the first signed-in coding tool in the order Claude,
   Codex, Grok.
4. The bot posts a fixed intro (`--intro`), then runs one kickoff turn
   (`--kickoff`, prefixed `Kickoff:`) that checks the machine, HQ Cloud
   sign-in and company state, and asks whether to explain HQ first or jump
   straight in. The conversation is the bot's DM; the bot stays afterwards as
   a general helper.
5. The bot can end a message with a `suggestions` block (reply buttons) and
   ends setup with a `setupDone` block (finish card). See
   `desktop-rich-messages.md`.
6. People who already use Claude Code or Codex can skip the bot: the Launch
   menu opens the HQ folder there and they run `/setup` themselves.

If no coding tool is signed in, the bot cannot start and the app says so
("No coding tool is signed in on this Mac/PC/computer yet").

The older scripted `/setup --guided` run (step card driven by
`[hq-setup] step=` and `card=` marker lines) is still in the source tree
(`packages/ui/src/chat/setup-run.ts`), but it needs the in-app session engine,
which was removed. The shipped host passes no session API, so that path does
not run.

## Launch menu

In-app agent sessions (the Sessions page, the composer's Session button, and
the PTY/session backend) were removed in 0.10.270 (PR #826, September 2026).
Agent work now runs in the user's own coding tool. The title-bar **Launch**
menu opens the HQ folder in:

| Tool | Order tried |
|---|---|
| Claude Code | Claude desktop deep link (`claude://`), then `claude` CLI in a terminal, then copy to clipboard |
| Codex | ChatGPT app Codex workspace, then `codex` CLI in a terminal, then clipboard |
| Grok Build | `grok` CLI in a terminal |

The terminal launcher only accepts `claude`, `codex` or `grok`
(`apps/sync/src-tauri/src/commands/launch.rs`). The Launch menu opens a plain
workspace with no prefilled prompt. Work Mesh still shows live sessions
started in those tools.

## Local bots

Settings → Bots and the sidebar's **New bot** flow wrap the `hq bot` CLI
(`hq bot … --json`). The CLI owns the bot's identity, credentials, launchd
agent and process; the app never sees secrets.

| App action | CLI |
|---|---|
| Create | `hq bot create <name> --runtime claude\|codex\|grok [--kind company --company <slug>…] [--display-name] [--worker] [--intro] [--kickoff] [--memory synced\|local] [--model] [--no-auto-approve]` |
| List | `hq bot list` (`--remote` for bots you own on other machines) |
| Start / stop / remove | `hq bot start\|stop\|rm <name>` |
| Model and effort | `hq bot set <name> --model … --effort …` |
| Start on this computer | `hq bot adopt <name>` |
| Restore my bots | `hq bot restore [--all]` |
| Promote to cloud (company bots only) | `hq bot promote <name> --company <cmp_uid>` |

Rules the app enforces:

- **Kinds.** "Personal - acts as you" works under the owner's account, stays
  on this machine, and has no company identity, so teammates cannot find it.
  "For a company" has its own identity, belongs to one or more companies, only
  reaches those companies' files, and can be promoted to the cloud. Setup is
  always a personal bot.
- **Names and handles.** The display name is free text (letters, spaces,
  apostrophes, periods, hyphens; up to 35 characters for the CLI). The
  @handle is derived from it (lowercase letters, digits, single hyphens, up to
  40 characters). If the handle is taken, the form opens a Handle field.
- **Channel reach.** The owner can add a personal bot to a channel; everyone
  in that channel can then @mention it there. Nobody else can add it to a
  channel, tag it into a channel it is not in, or DM it.
- **Restore.** When HQ finds bots the user owns that are not set up on this
  machine and a coding tool is signed in, it restores them automatically.
  Settings → Bots keeps "Restore my bots" and a per-bot "Start on this
  computer" action. Cloud-hosted bots are never offered for local restore.
- **Sidebar.** A bot gets a sidebar row only after it has messaged you, you
  messaged it, you pinned it, or you own it.
- **Cloud bots.** New bot → Cloud → pick a company → name and @handle. The app
  shows the company's price quote first. Runtimes are Codex and Grok, plus
  Claude when a server flag enables it. If the plan cannot host a bot, the
  plan card appears.

## Messaging

- DMs, group messages, channels and threads.
- DM requests from people outside your workspaces: Accept, Decline or Block.
- `@mentions` and `@here`. `@here` notifies the people in a channel or group
  message; it does not reach bots and is not offered in one-to-one DMs.
- File shares render as a tile card with in-thread preview for images, PDFs
  and text.
- Rich agent messages (`hq-block`): stat tiles, tables, charts, badges,
  key-value lists, progress bars, callouts and decision buttons. Contract:
  `desktop-rich-messages.md`.

## Companies

- Each company has exactly one home channel. The app opens the channel the
  server names (`homeChannelId`); a company without one shows "No company
  channel yet."
- Create a company from search ("Create company <name>") or from "New company"
  in the sidebar or company switcher. The form checks the handle while you
  type and can invite people by email. The app then switches to the new
  company and opens its channel.
- A company you were just added to (including one the Setup bot creates) is
  synced onto the machine automatically, once per company per session. The
  "Added to …" banner only appears if that pull fails, and its Sync now button
  retries.

## Company scope gate

File reads from the desktop pass through
`crates/hq-desktop-core/src/scope_gate.rs`. When the Files explorer opens a
company vault, the app binds that company as the session's active company.
Reads under `companies/<other>/` are then refused, and with no company bound
only `companies/manifest.yaml` and `companies/_template/` are readable.
Details: `desktop-company-isolation.md`.

## Sign-in guard

The app refuses to sign in as a machine. If the saved HQ credentials belong
to a fleet agent or an outpost, it signs out and asks for a person's sign-in.
A token is treated as non-human when any of these hold: the Cognito
`custom:entityType` attribute is set (`agent`, `outpost`, or any other value);
the `custom:entityUid` starts with `agt_`/`agt-` or `otp_`/`otp-`; or the email
is on an `agents.` domain or has an `agt-`, `conn-` or `otp-` local part.

## Sync

- The desktop runs the hq-cloud sync runner through
  `npx -y --package=@indigoai-us/hq-cloud@~6.18.5 hq-sync-runner`
  (`HQ_CLOUD_VERSION` in `crates/hq-desktop-core/src/hq_cloud.rs`). The `hq`
  CLI uses the same hq-cloud line, so Update/Restore and `hq rescue` run the
  same engine.
- Auto-sync runs the runner in watch mode:
  `--companies --direction both --on-conflict keep --watch`, plus
  `--event-push` when instant sync is on (the default) and `--skip-personal`
  when personal sync is off. Paused companies are passed in
  `HQ_SYNC_SKIP_COMPANIES`.
- The desktop does not pass `--poll-remote-ms`. The runner then polls the
  remote on a load-aware interval: 60 seconds on an idle machine, stretching
  toward 10 minutes under full CPU load. Event push carries real-time changes;
  the poll is a backstop.
- The HQ folder is resolved in this order: `hqPath` in `~/.hq/menubar.json`,
  `hqFolderPath` in the HQ config file, discovery of a folder containing
  `core/core.yaml`, then the default location.

## Notifications and deep links

- Notification preferences (pause for 1 hour, 8 hours, until tomorrow 8am, or
  indefinitely; DMs, mentions, shared files, all activity, added-to-channel;
  let DMs through while paused) are stored on the HQ account through
  `/v1/notify/prefs` and apply on every device. Each channel has a level:
  all, mentions, files or muted.
- Clicking a DM, mention or file-share notification opens the main window on
  that conversation.
- `hq://` links open a screen: `hq://inbox/dm/<personUid>`,
  `hq://inbox/channel/<channelId>[/<eventId>]`, `hq://files/<vault>/<path>`,
  `hq://company/<slug>[/<tab>]`, `hq://meetings`. Query strings, fragments,
  credentials, ports and dot segments are rejected.
- `hq-desktop://` accepts only two targets: `setup?checkout=done&company=cmp_…`
  (checkout return) and a parameterless `signin`.

## Meetings

- The Recall desktop SDK detects calls (Slack huddles, Zoom, Google Meet,
  Teams, Webex) and shows a "meeting detected" prompt.
- Settings → Meetings has "Record meetings automatically". It is off by
  default. When on, detected calls start recording without a click; calls a
  scheduled HQ bot is already recording are not recorded twice.

## Sources

hq-desktop-app `origin/main@c621a6a1`:

- `README.md`, `CHANGELOG.md`, `versions.toml`
- `packages/ui/src/shell/DesktopApp.svelte` (shortcuts, setup bot wiring)
- `packages/ui/src/shell/navigation-history.ts`, `navigation-shortcuts.ts`, `embedded-navigation.ts`
- `packages/ui/src/chat/setup-bot.ts`, `setup-channel.ts`, `setup-agent.svelte.ts`, `setup-run.ts`
- `packages/ui/src/chat/create-bot/create-bot-model.ts`, `CreateModal.svelte`, `DmRequestsPanel.svelte`, `mentions.ts`
- `packages/ui/src/settings/launch-actions.ts`, `packages/ui/src/home/V4TitleBar.svelte`
- `packages/ui/src/files/explorer/VaultExplorer.svelte`
- `apps/sync/src-tauri/src/commands/bots.rs`, `launch.rs`, `auth.rs`, `desktop_alt.rs`, `vault_explorer.rs`
- `apps/sync/src-tauri/src/deep_link.rs`, `main.rs`
- `crates/hq-desktop-core/src/scope_gate.rs`, `cognito.rs`, `deep_link.rs`, `hq_cloud.rs`, `daemon.rs`, `paths.rs`, `notify_prefs.rs`, `meeting_auto_record.rs`

hq-cli `origin/main@dfe49a48`: `src/commands/bot.ts`.
hq-cloud `origin/main@e486a79`: `src/bin/sync-runner-watch-loop.ts`.
