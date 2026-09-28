---
type: reference
domain: [engineering, operations]
status: canonical
tags: [agents, bots, fleet, local-bots, external-agents, slack, hq-cli]
relates_to:
  - core/knowledge/public/hq-core/external-agents-mcp.md
  - core/knowledge/public/hq-core/plans-and-pricing.md
  - core/knowledge/public/hq-core/agent-session-contract.md
  - core/knowledge/public/hq-core/outpost-jobs-spec.md
  - .claude/skills/new-agent/SKILL.md
verified_against:
  - hq-cli@dfe49a48 (2026-09-27)
  - hq-pro-agents@f6275ec7 (2026-09-27)
  - hq-agents-v2@5ec6d18 (2026-09-27)
  - hq-fleet-runtime@483c5a3 (2026-09-27)
  - hq-pro@563bf1f39 (2026-09-27)
  - hq-console@a227a042 (2026-09-27)
  - hq-desktop-app@c621a6a1 (2026-09-27)
  - hq-mcp@ccf910a (2026-09-27)
---

# Agents and bots in HQ

Every AI teammate in HQ is an `agt_` identity. What differs is where it runs,
whose model login it uses, and who pays for the compute. This page lists each
kind, how it is created, and the CLI surface that manages it.

Prices are not repeated here. See
[plans-and-pricing.md](plans-and-pricing.md).

## Taxonomy

| Kind | Created by | Runs where | Identity and credentials | Cost basis |
|---|---|---|---|---|
| Local bot, personal | `hq bot create <name>` (default `--kind personal`), or desktop Settings → Bots → New bot → Local | The owner's computer. launchd LaunchAgent on macOS (`hq bot daemon install`), otherwise a detached process | Own `agt_` machine identity. Acts as the owner, in every company the owner belongs to. Uses the owner's own `claude`, `codex`, or `grok` CLI login | No HQ hosting charge in the create path (`POST /v1/agents` with `computeMode: "local"` is identity only). Model usage bills to the owner's provider account |
| Local bot, company | `hq bot create <name> --kind company --company <slug>` (repeat `--company`), or the desktop flow with scope "company" | Same as personal | Acts as itself, as a member of each listed company. `hq bot companies <name> --add/--remove <slug>` changes the list | Same as personal |
| Hosted agent (agents-v2) | Console Bots page → Add bot → Hosted by HQ, `hq agents provision` (aliases `create`, `new`), or desktop New bot → Cloud | An HQ-managed EC2 box running the HqFleet runtime plus the HQ citizenship package from hq-agents-v2 | Own `agt_` identity and company membership. Brain is Codex, Grok, or Claude (Claude is behind a rollout flag in the console and requires the account to be enabled). Auth mode `subscription` (default) or `apiKey` | Company-specific monthly quote shown before creation; see pricing page |
| Agents-v3 worker | Not created directly. A v2 box with the agents-v3 opt-in dispatches scoped tasks to short-lived worker containers | Worker containers (ECS task definitions, optional per-company EFS access point) | Runs under the dispatching agent's task scope | Part of the hosted agent |
| External bot | Console Bots page → Add bot → External bot → framework → Create and get code; then `hq agent enroll <code>` on the bot's host | Hardware HQ does not own (laptop, VPS, container) | `agt_` identity with `runtime: "external"`. Ed25519 host key generated at enroll; mints are signed with it | No per-agent charge and zero seats. Blocked on the free plan (402); unlimited on paid plans |
| Chat-app connector | Console Integrations → Connect an agent → A person (Claude, ChatGPT, Claude Code, Codex, Grok tabs) | The hosted hq-mcp connector (URL shown in the console) | The person's own HQ login via OAuth in the browser. Not an `agt_` identity | See pricing page |
| Cowork plugin | `/hq-cowork-install` (pack `hq-pack-cowork`) | A host-launched stdio MCP server wrapping the local `hq` CLI and `qmd` | The person's local HQ login | Local |
| Legacy Slack watcher | `/run-bot` (pack `hq-pack-slack-bot`) | The operator's machine, as a Claude Code Monitor | A Slack bot token from the vault | Legacy; use a local bot or hosted agent instead |

The console's "Connect an agent → An agent" view is a different thing: it
toggles whether an existing hosted agent can read HQ through the same MCP
connector.

Details for external bots and connectors: [external-agents-mcp.md](external-agents-mcp.md).

## Local bots (`hq bot …`)

`hq bot` is described in the CLI as "Personal local bots that run on this
computer with your own model login".

| Command | Purpose |
|---|---|
| `create <name>` | Provision the identity, scaffold the worker folder, install the LaunchAgent, start it. Options: `--kind personal\|company`, `--company <slug>` (repeatable), `--runtime claude\|codex\|grok` (default `claude`), `--model`, `--effort`, `--worker <id>`, `--display-name`, `--intro`, `--kickoff`, `--memory synced\|local`, `--no-auto-approve`, `--no-daemon`, `--no-start` |
| `list [--remote]` | Local bots, or with `--remote` every local bot the account owns |
| `status`, `logs`, `start`, `stop`, `restart`, `run` | Process control. `run` is what launchd runs |
| `set <name>` | Change model and thinking level |
| `intro <name>` | Re-send the introduction DM |
| `companies <name>` | Show or change a company bot's memberships |
| `workers` | Workers a bot can be created from |
| `adopt <name>`, `restore [--all]` | Bring owned bots back to this computer. Re-issuing credentials rotates the machine secret; one machine runs a local bot at a time |
| `jobs <name>` | List, add (`--add` with `--every` or `--cron`, `--tz`), or remove (`--rm`) recurring jobs. The schedule lives in hq-pro-agents on EventBridge, not on the computer |
| `promote <name> --company <cmp_uid>` | Move the bot to HQ Fleet compute while keeping its agent UID and DM conversation |
| `rm <name>` | Stop, remove the LaunchAgent, delete the cloud identity and local state |
| `daemon install\|uninstall\|status <name>` | Manage the LaunchAgent |

Promotion notes (hq-cli `docs/local-bot-promotion.md`): the command takes a
company UID, not a slug; re-running it resumes the same operation; the cloud
instance needs its own model subscription sign-in (local OAuth tokens are not
copied); the local bot stays held after activation. The doc states the
feature depends on backend changes and does not imply general production
availability.

## Hosted agents (`hq agents …`)

`hq agents` is described as "Manage a company's cloud (fleet) agents".

| Command | Purpose |
|---|---|
| `provision <name>` (`create`, `new`) | Create a hosted agent. Options: `--company`, `--slug`, `--provider`, `--model`, `--auth-mode subscription\|apiKey`, `--api-key-env <VAR>`, `--size basic\|power\|dev`, `--slack-bot-token`, `--slack-app-token`, `--slack-tokens-stdin`, `--title`, `--description`, `--yes`, `--json` |
| `models [--provider codex\|grok\|claude]` | Model catalog |
| `list`, `status <agent>` | Roster and setup state |
| `message <agent> <text>`, `thread <agent>`, `terminal <agent>` | Talk to an agent |
| `login-code <agentUid> [code]` | Submit a Claude subscription sign-in code |
| `rename`, `set` | Display name and profile |
| `config <agentUid>` | Model, reasoning effort, service tier. `--provider` migrates the brain and is destructive (terminates and reprovisions the box; needs `--model` and `--yes`) |
| `start`, `stop`, `retry`, `rm` | Box lifecycle |
| `jobs list\|pause\|cancel` | Manage an agent's hq-pro scheduled jobs |
| `rotate`, `revoke` | External bot credential lifecycle (admin) |

Provider rules:

- The CLI accepts `--provider codex|grok|claude|agents-v2`. With `--model`
  and no `--provider`, it sends `agents-v2`. With neither, it sends no
  provider and the server defaults to `agents-v2`.
- The server rejects a new agent whose provider is not `agents-v2` with
  `LEGACY_MANAGED_PROVIDER_RETIRED` ("Choose Codex, Grok, or Claude as the
  Agents v2 brain instead"). Retries of an existing historical row are the
  only exception.
- `claude` with `--auth-mode apiKey` is refused locally.

Price and checkout:

- Every create path fetches the company-specific quote. Without `--yes` the
  CLI prints the quote and stops. Interactive terminals without `--size`
  prompt for a size.
- When the server returns `AGENT_PLAN_LIMIT` (403), the CLI prints the
  checkout URL and exits with status `3` (payment required). It offers to
  open the URL only in an interactive terminal; `--json`, CI, and TTY-less
  runs never open a browser.
- A 402 with billing detail prints a payment link and exits `1`.

Setup steps, in order: `identity`, `membership`, `vault`, `runtime`,
`codex-auth`, `sync`, `channels`, `audit`, `runtime-install`. The last step
installs and activates the HqFleet runtime over SSM, so `phase: ready` means
the box is on v2.

## Slack for hosted agents

Two Slack setup paths exist in the console. Which one the Add bot wizard
shows is a per-company rollout flag (`isSlackCustomerCreatedDefaultEnabled`);
when the flag is off or unreadable, the older factory step is shown.

Customer-created app (guided flow at
`/companies/<slug>/agents/<agentUid>/slack-setup`):

1. Open Slack with the template. The console links to Slack's create-app page
   with the full-scope manifest pre-filled (`manifest_json`). If the URL would
   exceed 8,192 bytes, or the workspace blocks the link, the page shows the
   manifest to copy instead.
2. Create the app and install it to the workspace. Some workspaces require
   admin approval; the page links a plain explanation of the permissions for
   that admin.
3. Generate the app-level token: Basic Information → App-Level Tokens →
   Generate Token and Scopes → `connections:write`.
4. Copy the Bot User OAuth Token (`xoxb-`) from OAuth & Permissions.
5. Paste both tokens into the console page.

The manifest sets Socket Mode on, interactivity on, token rotation off, and
org deploy off. The server validates the bot token with `auth.test`, compares
its scopes with the manifest, and opens a Socket Mode connection before it
stores anything. A rotating token (`xoxe.xoxb-`) is rejected with a message to
turn rotation off.

Factory app (older path): when status shows `FACTORY_ROOT_MISSING`, an owner
or admin connects the company's Slack workspace once from the console Bots
page. HQ then mints the agent's app. `hq agents status` surfaces pending
actions of type `slack-install` (install link) and `slack-app-token` (create
a `connections:write` app-level token and paste it on the console).

CLI reuse of an existing app: `--slack-bot-token`, `HQ_SLACK_BOT_TOKEN`, or
`--slack-tokens-stdin`. An `agents-v2` provision needs the app token too
(`--slack-app-token`, `HQ_SLACK_APP_TOKEN`, or the second stdin line).
Reusing one bot token for several agents shares one Slack identity between
them.

## Open Fleet trust model

Hosted agents (hq-pro-agents `docs/open-fleet-communications.md`) accept
conversation from anyone on their connected Slack, Telegram, Teams, email,
and HQ DM surfaces. Legacy owner/member/caller lists no longer decide who can
start an ordinary conversation. Verification is separate:

- A verified member stays verified. Unresolved or former members are marked
  unverified and never inherit the owner's identity or permissions.
- Signed transport, channel bindings, session isolation, deduplication, spend
  and rate limits, and resource/action authorization still apply.
- Run controls, pending-decision answers, Telegram routing migration, and
  owner administration still require a verified member.
- Agents are instructed to treat impersonation, secret requests, and
  permission bypass attempts as suspicious and refuse the unsafe action while
  ordinary conversation continues.

The same doc records that no production deployment or live channel smoke test
had been performed at the time it was written.

Local bots follow the same model (hq-cli `docs/open-bot-comms.md`): they reply
to any sender on connected channels; each DM correspondent gets a separate
model session; only the owner receives the owner-context block; suspicious
requests pause the risky action for owner verification.

## Busy gate (hosted agents)

The `hq_busy_gate` plugin (hq-agents-v2, shipped in the HqFleet v2.56
artifact with runtime patches P21-P23) holds every user message and makes one
decision per message: answer directly, run, or queue. A background loop
resumes queued work when the box is free and pauses a running turn only under
memory pressure.

It is off by default (`render-config.sh` defaults `BUSY_GATE=false`). The
control plane toggles it per agent through the runtime-config field
`busyGateEnabled`, which provisions a decision token before re-rendering the
box. hq-cli at the verified SHA has no flag for it.

## Turn-cost reporting (hosted agents)

The `hq_turn_cost` plugin reports Codex and Claude input and output token
usage for interactive hqdm and hqslack turns, after the inbox item is
acknowledged. Metrics land in CloudWatch `HQPro/AgentTurnCost`. The hq-pro
flag `agents.turn-cost-capture` is the only gate, and it defaults off.

## Scheduled jobs

| Surface | Store and scheduler |
|---|---|
| `hq bot jobs <name>` (local bots) | hq-pro-agents job record, fired by EventBridge; the bot's inbox loop runs the fired job |
| `hq agents jobs list\|pause\|cancel` (hosted agents) | Same hq-pro EventBridge jobs. Pause sets the schedule to DISABLED; cancel deletes the schedule and the record |
| HqFleet cron on a v2 box | Runtime-native cron on the box clock (no per-job timezone). `hq-agents-v2-import-jobs` migrates an agent's hq-pro jobs onto it and pauses the originals |
| Outpost jobs (`/schedule`) | systemd user timers on a user's Outpost; see [outpost-jobs-spec.md](outpost-jobs-spec.md) |

## Which one to use

| Need | Use |
|---|---|
| A bot on your own machine with your own model login | `hq bot create` |
| An always-on company agent in Slack, Telegram, Teams, email, or HQ DM | Hosted agent via console or `/new-agent` |
| An agent you already run elsewhere (OpenClaw, grokbot, Muse, any MCP-capable agent) | External bot |
| Your own Claude, ChatGPT, Codex, or Grok reading HQ | Chat-app connector |
| HQ tools inside Cowork's sandbox | Cowork plugin |

## Sources

- hq-cli@dfe49a48: `src/commands/bot.ts`, `bot-jobs.ts`, `agents.ts`,
  `src/lib/bot/config.ts`, `src/lib/bot/api.ts`,
  `docs/agent-create-payment-required.md`, `docs/local-bot-promotion.md`,
  `docs/open-bot-comms.md`, `docs/external-agents-cli.md`
- hq-pro-agents@f6275ec7: `src/agents/handler.ts` (provider default and
  `LEGACY_MANAGED_PROVIDER_RETIRED`, `busyGateEnabled`, Slack routes),
  `src/agents/local-bot-routes.ts`, `src/agent-config/setup-steps.ts`,
  `src/slack-apps/manifest-template.ts`, `src/slack-apps/setup-link.ts`,
  `src/agents/channels/supplied-slack-tokens.ts`,
  `src/agents/jobs-control-endpoints.ts`, `docs/open-fleet-communications.md`,
  `docs/agents-v2-provisioning.md`, `docs/slack-prefill-link.md`,
  `docs/agents-v3/`
- hq-agents-v2@5ec6d18: `plugins/hq_busy_gate/`, `plugins/hq_turn_cost/`,
  `provision/render-config.sh`, `docs/PROVISIONING.md`, `docs/UPSTREAM-PIN.md`,
  `docs/ARCHITECTURE.md`
- hq-pro@563bf1f39: `src/agents/external/handlers.ts`,
  `src/agents/external/plan-gate.ts`
- hq-console@a227a042: `src/components/agents/AddAgentWizard.tsx`,
  `ExternalBotFlow.tsx`, `external-agent.ts`,
  `src/app/(shell)/companies/[slug]/agents/page.tsx`,
  `.../agents/[agentUid]/slack-setup/slack-setup.tsx`,
  `.../integrations/_connect-agent-modal.tsx`,
  `src/lib/console-rollout-flags.ts`, `src/lib/claude-code-link.ts`
- hq-desktop-app@c621a6a1: `packages/ui/src/chat/create-bot/`,
  `packages/ui/src/settings/BotsSettingsPane.svelte`
- hq-mcp@ccf910a: `src/server.ts`, `src/cloud/lambda.ts`
