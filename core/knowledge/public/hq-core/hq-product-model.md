---
type: reference
domain: [product, engineering, operations]
status: canonical
tags: [product-model, surfaces, identity, sync, plans, hq-cli, desktop-app, hq-console]
relates_to:
  - knowledge/public/hq-core/hq-cli-reference.md
  - knowledge/public/hq-core/hq-sync-model.md
  - knowledge/public/hq-core/hq-desktop-app.md
  - knowledge/public/hq-core/hq-console.md
  - knowledge/public/hq-core/agents-and-bots.md
  - knowledge/public/hq-core/plans-and-pricing.md
verified_against:
  - derived from sibling docs on 2026-09-27, not from source directly
  - hq-desktop-app.md, desktop-rich-messages.md, desktop-claude-code-integration.md, desktop-company-isolation.md
  - agents-and-bots.md, external-agents-mcp.md
  - hq-console.md, plans-and-pricing.md
  - hq-cli-reference.md (CLI 5.247.0), hq-sync-model.md
  - .claude/skills/deploy/SKILL.md
---

# HQ product model

HQ is a shared context and capability layer for a person and the companies
they work in. The base is a folder of plain files (the HQ folder). Coding
agents work in that folder, the `hq` CLI connects it to HQ's cloud services,
and the desktop app, web console, bots, and chat-app connectors are other ways
into the same companies, files, and people.

This page is the map. Each section links the reference doc that has the
details.

## Surfaces

### HQ folder and coding agents

The HQ folder holds `core/` (release-shipped scaffold), `companies/` (one
folder per company), `personal/`, `repos/`, and `workspace/`. Skills, policies,
knowledge, and workers are files in it. Supported coding hosts are Claude
Code, Codex, Cursor, and Grok. The CLI converges hook trust for Claude Code,
Codex, and Grok (`hq reindex`), and its updater covers Claude, Codex, and
Grok. Directory map: [INDEX.md](../../../docs/hq/INDEX.md).

### `hq` CLI

The CLI (`@indigoai-us/hq-cli`, 5.247.0 at last check) has 55 top-level
commands, 52 of them public. It covers sign-in, companies and cloud
provisioning, sync, vault files, secrets, messaging, search, bots and agents,
work mesh, integrations, packs, and billing. There is no `hq deploy`; deploys
go through the `/deploy` skill. Reference:
[hq-cli-reference.md](hq-cli-reference.md).

### HQ Desktop app

A Tauri app for macOS and Windows. It is the onboarding installer on a new
machine and afterwards a messaging workspace (DMs, groups, channels, bots,
company home channels) with Files, Projects, Meetings, and Library pages. It
runs sync in the background. It has no in-app agent sessions: the Launch menu
opens the HQ folder in Claude Code, Codex, or Grok. First run creates a Setup
bot, a personal local bot you DM. References:
[hq-desktop-app.md](hq-desktop-app.md),
[desktop-claude-code-integration.md](desktop-claude-code-integration.md),
[desktop-company-isolation.md](desktop-company-isolation.md),
[desktop-rich-messages.md](desktop-rich-messages.md).

### Console (hq.computer)

The web UI. Company pages cover team and invites, groups and grants, bots,
integrations, secrets, vault, billing, and (behind flags) work mesh and fleet
health. Account pages cover deployments, personal vault and secrets, and
personal billing. Most console tasks also have a CLI command or skill.
Reference: [hq-console.md](hq-console.md).

### Bots and agents

Every AI teammate is an `agt_` identity. Kinds: local bots on your own machine
with your own model login (`hq bot`), hosted agents that HQ runs (console or
`/new-agent`), and external bots on hardware HQ does not own
(`hq agent enroll`). External bots need a paid plan. Reference:
[agents-and-bots.md](agents-and-bots.md).

### Chat-app connectors and MCP

A person connects Claude, ChatGPT, Claude Code, Codex, or Grok to HQ through
the hosted connector whose URL the console shows (console →
Integrations → Connect an agent). External bots use `hq agent mcp` over stdio.
Reference: [external-agents-mcp.md](external-agents-mcp.md).

### Deploy

The `/deploy` skill publishes generated artifacts through hq-deploy with an
access mode (public, password, company, selected, or private email allowlist).
Static deploys can opt into identity-verified comments (`--comments on`);
owners read and resolve them through the skill's owner API routes. The console
`/deployments` page shows deployed apps and visit counts. Reference:
[deploy SKILL.md](../../../../.claude/skills/deploy/SKILL.md).

### Vault, sync, and cloud

Each cloud-backed company has a company vault; each person has a personal
vault. Sync moves files between the HQ folder and the vaults (`hq sync`,
`/hq-sync`, the desktop runner, or `hq daemon`). Secrets live in the HQ secret
store (`hq secrets`, `/hq-secrets`). Reference:
[hq-sync-model.md](hq-sync-model.md).

## Local and cloud

| Content | Where it lives |
|---|---|
| `repos/` | Local only. Code moves through git, not sync. |
| `workspace/` | Local only, except `workspace/threads/handoff.json` plus the thread it points to, `workspace/agency/`, and `workspace/.session-logs/`, which go to the personal vault. |
| Top-level `.git` | Local only. |
| Rest of the HQ root (`core/`, `personal/`, `.claude/`, …) | Personal vault. |
| `companies/<slug>/` for a local-only company | Personal vault. |
| `companies/<slug>/` for a cloud-backed company | That company's vault. What a pull downloads depends on the membership's sync mode (`all`, `shared`, `custom`). |
| `companies/manifest.yaml` | Personal vault. |

Company lifecycle:

1. **Local-only.** A folder under `companies/` (for example from
   `/newcompany`). Rides in the personal vault.
2. **Cloud-backed.** `hq onboard create-company` for a new company,
   `hq onboard join` for an existing one, or `hq cloud provision company
   <slug>` to promote a local company.
3. **Retired.** `hq cloud retire company <slug>` (owner) or the console
   soft-tombstones the cloud entity. Files are not deleted.
4. **Demoted.** `hq cloud demote company <slug>` returns a retired company to
   local-only.

Details, ignore rules, and conflicts: [hq-sync-model.md](hq-sync-model.md).

## Identity types

| Type | How it signs in | Notes |
|---|---|---|
| Person | Cognito via `hq login` / `hq auth login` with `--provider google\|microsoft\|picker` (Google by default; the picker also covers email and password) | The desktop app only accepts a person's sign-in. Chat-app connectors use the person's login via OAuth. |
| Bot or agent | Own `agt_` machine identity | Local bots, hosted agents, and external bots. External bots sign mints with an Ed25519 host key created at enroll. Outposts use `otp_` identities. |
| API key | `HQ_API_KEY` from `hq api-keys create` | For CI and automation. Only some commands accept it; `hq bot` refuses it. `--deploy-app` mints a deploy-scoped key. |

## Plans

Companies are on Starter (free), HQ Workforce (internal id `paid-500`), or
Enterprise. People have an Individual plan or the unpaid personal scope.
Billing is live through Stripe and `hq billing`. The live price source is
`GET https://hqapi.hq.computer/v1/pricing`. Reference:
[plans-and-pricing.md](plans-and-pricing.md).

## Which surface to use

| Task | Use |
|---|---|
| Code, write, or run skills against HQ context | A coding host in the HQ folder (Claude Code, Codex, Cursor, Grok), or the desktop Launch menu |
| Message a teammate or bot | Desktop app, or `hq dm` / `/dm` |
| Set up HQ on a new machine | Desktop app onboarding, or `/setup` in a coding host |
| Invite a teammate | `/new-hire`, or console `/team/invites` |
| Add a bot on your own machine | `hq bot create`, or desktop Settings → Bots |
| Add a hosted company agent | `/new-agent`, `hq agents provision`, or console Bots page |
| Connect an agent that runs elsewhere | Console → Add bot → External bot, then `hq agent enroll <code>` |
| Use HQ from Claude, ChatGPT, Codex, or Grok chat | Chat-app connector (console → Integrations → Connect an agent) |
| Connect a company app (Linear, Notion, …) | `/hq-integrations`, `hq integrations`, or console `/integrations` |
| Store or use a secret | `/hq-secrets`, `hq secrets`, `hq run`; console `/secrets` |
| Share a file or folder | `/hq-share`, `/hq-files`; console `/vault` |
| Publish an artifact | `/deploy` |
| Read deploy comments | `/deploy` owner routes, or the side pane on the deployed page |
| Sync files | `/hq-sync`, `hq sync now`; the desktop app syncs in the background |
| Search local HQ | `hq search`, `/search`, `qmd` |
| Upgrade or check billing | `hq billing`, or console Billing |
| Promote, retire, or demote a company | `hq cloud provision\|retire\|demote company <slug>` |
