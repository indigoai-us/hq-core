---
type: reference
domain: [operations, product]
status: canonical
tags: [hq-console, hq.computer, bots, billing, deployments, integrations, secrets]
relates_to:
  - plans-and-pricing.md
  - quick-reference.md
  - work-mesh-live.md
verified_against:
  - hq-console@a227a042 (2026-09-27)
  - hq-deploy@9e42c1e (2026-09-27)
  - hq-pro@563bf1f39 (2026-09-27)
---

# HQ Console (hq.computer)

The console is the web UI for HQ. Most of what it does is also available from
`hq` CLI commands and HQ skills; this page maps console pages to tasks so an
agent can send a user to the right place. Company pages live under
`/companies/<slug>/…`.

"Flag" below means the page or feature is off unless a rollout flag is on for
that company or user. Missing or unreadable flags count as off. If a user
cannot see a page listed here, a flag or role is the likely reason.

## Company pages (`/companies/<slug>/…`)

| Page | Task | Gate |
|---|---|---|
| `/atlas` (company root redirects here) | Map of the company's live HQ objects | Starter sees an upgrade card |
| `/overview` | Company activity, board, team at a glance | |
| `/projects` | Kanban board of projects | |
| `/team` | Roster of people and bots (`?kind=` filter) | |
| `/team/invites` | Send and manage invites | Owner/admin |
| `/groups` | Create and delete groups, add and remove members | |
| `/grants` | Grant roles on other companies to groups; see inbound grants | Owner/admin |
| `/org-chart` | Org chart of people and bots | Flag `console.org-chart` |
| `/agents` (labelled "Bots") | Bot roster; add-bot wizard with Basic / Power / Dev sizes and a live monthly price before Create | Company-level agents switch in hq-pro. Claude provider option: flag `console.claude-provider` |
| Add-bot wizard, guided Slack step | Connect the new bot to Slack inside the wizard | Flag `slack.customer-created-default` |
| `/agents/<uid>/slack-setup` | Five-step guided Slack app setup for an existing bot | Owner/admin (no flag) |
| `/agents/<uid>/socket-mode` | Switch a bot's Slack connection to Socket Mode | Owner/admin |
| `/agents/<uid>/setup` | Setup recipe and enrollment status for an external bot | Member |
| `/agents/<uid>/sessions/<key>` | Read one Slack session's conversation | Member |
| `/agents/<uid>/dashboard`, `/agents/runtime` | Bot runtime views | Per-company hq-pro setting plus role |
| `/agents/enable` | Enable an Outpost or a bot, see the price, choose who pays | Member |
| `/telescope` | Bot task timelines and session history | Company setting `telescopeEnabled` plus the team-activity flag |
| `/fleet-health` | Bot fleet health | Flag `console.team-activity` plus admin |
| `/work-mesh` | All in-flight work across the company | Flag `console.team-activity` |
| `/team-activity` | Members, leaderboard, projects | Flag `console.team-activity` plus owner or permitted admin |
| `/activity` | Team, token, and live activity | Owner; admins if the company allows |
| `/activity-beta` | Redacted member event stream | Flag `console.company-activity` plus owner/admin |
| `/telemetry`, `/skill-usage` | Company telemetry and skill usage | Owner or permitted admin |
| `/knowledge` | Browse knowledge docs, new vs updated | |
| `/policies` | Read policy docs | |
| `/library` | Skills and workers shelf | Skills section: flag `console.skills` |
| `/skills`, `/skills/<uid>` | Browse skills by department with access badges | Filtered by the viewer's access |
| `/marketplace` | Catalog hub linking knowledge areas, skills, integrations | Not in the sidebar; skills card behind `console.skills` |
| `/vault` | Browse company files | |
| `/integrations` | Connect apps, set who can use them | Starter sees an upgrade card; QuickBooks card behind `integrations.quickbooks-connect` |
| `/connections` | Create external connections (vault-prefix wizard) | Owner/admin |
| `/secrets` | List, create, and view company secrets | Starter secret limit applies |
| `/pro` ("HQ Workforce") | Hub for Workforce companies | Non-guest members on Workforce |
| `/billing` | Plan, card, invoices, pay now, upgrade | Owner only |
| `/billing/seats` | Seats view | Owner/admin |
| `/billing/sponsorship` | Approve or revoke sponsorship requests | Owner/admin |
| `/billing/person` | Pay for your own resources ("I'll pay") via Stripe | Member |
| `/settings` | Delete the company | Owner only |

## Account and cross-company pages

| Page | Task | Gate |
|---|---|---|
| `/home` | Multi-company dashboard | Attention panel: flag `console.attention-home` |
| `/dashboard` | Older personal activity rollup | |
| `/welcome`, `/onboarding` | First-run setup: install, join, sync, training | |
| `/companies` | Pick a company | |
| `/deployments`, `/deployments/<id>` | Deployed apps with search, sort, last visit, and 30-day views; per-app detail | |
| `/usage` | 30-day session, token, and error counts per deployment | Not in the sidebar |
| `/telemetry` | Your own work over 7/30/90 days | |
| `/explore` | Tree view of a company vault | Not in the sidebar |
| `/personal/vault` | Your personal files (read-only) | |
| `/personal/secrets` | Your personal secrets | |
| `/personal/integrations` | Connect Google and personal Slack | Email forwarding: flag `integrations.forwarding-email` plus staff |
| `/personal/profile` | Name, avatar, secondary emails, sign-in methods | |
| `/personal/outpost` | Manage your Outpost | Staff only today; others see "coming soon" |
| `/account/billing` | Personal plan and Stripe billing portal | |
| `/signup/team` | Self-serve HQ Workforce signup, then first-bot setup | Can be disabled server-side |
| `/pro/partner` | Create, claim, or edit your firm's listing in the partner directory | Sidebar link appears only when a membership has a live listing |

## Link and token pages

| Page | Task |
|---|---|
| `/share-session/<token>` | Pick who to share a session with |
| `/secrets-input/<token>` | One-time link where a person types a secret value; the page shows only the secret's name |
| `/invite/<token>` | Accept a company invite |
| `/integrations/approve/<queueId>` | One-tap owner approval of a queued integration action |
| `/resolve/agents/<uid>` | Fix whatever a bot needs (Slack, reconnect) |
| `/attention/<incidentId>` | Landing page from a Slack reconnect DM |
| `/link/slack` | Link a Slack identity to HQ |
| `/slack-app-permissions` | Explains the Slack app's permissions to Slack admins |
| `/cli-auth`, `/mobile-auth`, `/signin`, `/request-access`, `/migrate` | Sign-in flows |
| `/r/<code>` | Referral link; redirects to hqforwork.com. Recording the referral at signup is behind flag `affiliate.tracking` |

## Not in the console

- **Deploy comments.** There is no console UI for reading or resolving deploy
  comments. Use the in-page side pane on the deployed site, or the owner API
  routes in the `/deploy` skill.
- **Meetings.** No meetings pages. Use `/meeting-notes` and `hq meetings`.
- **Affiliate program.** No affiliate dashboard. `/pro/partner` is a partner
  directory listing, not an affiliate program.

## Common tasks

| User wants to | Console | CLI or skill |
|---|---|---|
| Invite a teammate | `/team/invites` | `/new-hire` |
| Add a bot | `/agents` → add-bot wizard | `/new-agent`, `hq agents provision` |
| Connect a bot to Slack | wizard Slack step (flagged) or `/agents/<uid>/slack-setup` | |
| Upgrade to Workforce | `/billing` | `hq billing upgrade --company <slug>` |
| Approve a sponsorship request | `/billing/sponsorship` | `hq billing sponsor approve` |
| Connect an app | `/integrations` | `/hq-integrations` |
| Add a secret | `/secrets` | `/hq-secrets` |
| Share files | `/vault` | `/hq-share`, `/hq-files` |
| See deploy traffic | `/deployments` | `GET /api/apps` (`lastVisitAt`, `views30d`) via `/deploy` |
| Manage groups and grants | `/groups`, `/grants` | `/designate-team`, `/promote` |
| See in-flight work | `/work-mesh` (flagged) | `hq mesh`, `/work-mesh` |

Prices shown in the console come from hq-pro; see `plans-and-pricing.md`.

## Sources

- hq-console `src/app/(shell)/` page tree and `src/app/` public pages
- hq-console `src/components/nav/nav-model.ts` (sidebar)
- hq-console `src/components/agents/AddAgentWizard.tsx` (bot sizes and prices)
- hq-console `src/lib/console-rollout-flags.ts`, `src/lib/feature-flags.ts`, `src/lib/work-mesh-gate.ts`, `src/lib/team-activity-client.ts`, `src/lib/org-chart-client.ts`, `src/lib/company-activity-gate.ts`, `src/lib/attention-client.ts`, `src/lib/flag-gates.ts`, `src/lib/affiliate-tracking.ts`, `src/lib/agents-client.ts`
- hq-console `src/app/(shell)/personal/outpost/_staff-gate.ts`
- hq-deploy `README.md` (visit tracking fields consumed by the console)
