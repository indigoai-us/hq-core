---
name: pricing
description: How HQ is priced, what each plan includes, what happens at a limit, and how to find out which plan a company is actually on. Never guess a plan.
---

# How HQ is priced

Use this whenever a plan, a price or a limit comes up. Two rules first:

1. **Never guess a company's plan.** Check it (below) before you say anything
   that depends on it. If you cannot check it, say what the plans are and that
   you could not see which one they are on. Do not assume "free" because the
   company is new.
2. **When HQ answers, pass its answer on.** If a command quotes a price,
   refuses something or returns an upgrade link, tell the person exactly that,
   in plain words, with the link. HQ's answer wins over anything written here.

## Finding out which plan a company is on

Run `hq billing status --company <slug> --json` (owners can run it).

- Companies and personal accounts created from 2026-10-16 18:00 UTC are on
  the usage card (below). If the status output or any HQ message talks about
  usage, included usage or the trial cap, the account is on the usage card.
- `subscriptionStatus` of `active` or `trialing` on a company created before
  the cutover: the company pays for HQ Workforce (a legacy plan).
- `subscriptionStatus` of `null` with `billingConfigured: false` on a company
  created before the cutover: no paid subscription. Most such companies are
  on Starter, but Enterprise companies and some early companies are set up by
  HQ staff without one, so say "it looks like you're on Starter" rather than
  stating it.
- A refusal because they are not the owner: say only the owner can see the
  plan, and do not claim one.

`hq whoami --company <slug> --json` also has a `planLimits` field, but it is
often empty; when it is empty it tells you nothing about the plan.

## The usage card (everyone who signs up from 2026-10-16)

New signups choose **Sign up free** or **Request an enterprise demo**. Sign
up free puts the account on the usage card: no plan fee, no seat price, and
$10 of usage included every month. Past the $10, they pay for what they use:

- sync: $0.10 per moved file, per leg
- a call to a connected app or an outside MCP server through HQ: $0.05
- an HQ MCP call: $0.05
- an agent run: $0.05
- files: $2.00 per GB a month
- keys: $0.50 per key a month
- each company vault and each personal vault: $5 a month (part of the $10
  included usage; free during the trial)

Deploys, DMs and background AI are free. The first 30 days are a trial: usage
is free up to $500, and the vault fee is waived.

Hosted boxes (hosted agents, agents in Slack, Outposts) are a monthly price
per box: small $100, medium $200, large $400, xlarge $800. Quote the price HQ
shows for the size chosen.

Someone who wants HQ without HQ cloud (advanced, enterprise or government
teams, or anyone who prefers to self-host) can use HQ free, self-hosted or
on-prem: https://docs.hq.computer/hq/guide/use-hq-for-free/

Enterprise is custom, arranged with the HQ team after a demo request
("Request an enterprise demo" when signing up).

## Legacy plans (existing customers only)

Starter, HQ Workforce and Individual are closed to new signups from
2026-10-16. Existing customers keep their plan and their box prices. Never
offer these to a new account; describe them only to someone already on one.

**Starter, free.** Up to 5 people (invitations not yet accepted count), 1
connected app, 10 keys, 10 GB of files, unlimited site deploys, no hosted
agents. Only adding past a limit is affected: a 6th person, a 2nd connected
app, an 11th key, or files past 10 GB. When a company goes over, the owner
gets reminders, and HQ may refuse to add the next one; if it does, it says so
and gives a link. Nothing already there is ever removed, and reading,
deleting, changing an existing key and reconnecting an existing app are never
blocked. While a company is over its file storage, HQ may refuse file
uploads, including saving over an existing file.

**HQ Workforce, $500 a month per company.** No limits on people, connected
apps, keys, files or deploys. Hosted agents are billed per box on top: $100
(basic), $250 (power) or $500 (dev) a month. Recorded meetings are $1 an
hour, counted by the minute. Some companies that subscribed earlier are on an
older Workforce price that includes 3 hosted agents. If the company cancels,
the change takes effect at the end of the paid period, the company goes back
to Starter limits, and nothing is deleted.

**Individual, $50 a month per person.** For someone's own personal HQ: 100
personal keys, unlimited connected apps, 10 GB of files and unlimited site
deploys. A Workforce company can cover it for a teammate through
`hq billing sponsor request`.

Outposts on legacy plans are $80 a month each.

## Agents

- **Bots on their own Mac** (like you, their assistant) are free on every plan.
- **Hosted agents**, which run in HQ Cloud, including agents in Slack, run on
  a box. On the usage card that is a box price (from $100 a month for small)
  plus $0.05 per agent run. On a legacy Starter company, creating one is
  refused with an offer to upgrade; on Workforce, the agent is billed per box
  on top of the $500. `hq agents provision` shows what HQ will charge before
  anything is charged; show it and wait for a yes.
- **Outside agents connected from the console** (External bot) cost nothing
  extra on a paid plan. HQ may ask for billing first; pass that on.

## Where the numbers come from

HQ publishes its current prices and limits at `GET /v1/pricing` on the HQ
API (no sign-in needed). If that answer and this page disagree, the API is
right. Full reference: `core/knowledge/public/hq-core/plans-and-pricing.md`.

## How to talk about it

Say prices plainly and once, only when they matter to what the person is
doing. Do not open with pricing, do not upsell, and do not mention a limit
they are nowhere near. When something they want is not on their plan, say
what it would take (for example "A Slack agent runs on a hosted box, $100 a
month for the small size, plus $0.05 each time it runs") and let them decide.
