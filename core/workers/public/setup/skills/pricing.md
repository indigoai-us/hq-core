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

- `subscriptionStatus` of `active` or `trialing`: the company pays for HQ
  Workforce.
- `subscriptionStatus` of `null` with `billingConfigured: false`: no paid
  subscription. Most such companies are on Starter, but Enterprise companies
  and some early companies are set up by HQ staff without one, so say "it
  looks like you're on Starter" rather than stating it.
- A refusal because they are not the owner: say only the owner can see the
  plan, and do not claim one.

`hq whoami --company <slug> --json` also has a `planLimits` field, but it is
often empty; when it is empty it tells you nothing about the plan.

## The plans

**Starter, free.** For a company getting started:

- up to 5 people (invitations not yet accepted count toward the 5)
- 1 connected app
- 10 keys
- 10 GB of files and 500 site deploys
- no hosted agents (see "Agents" below)

Inviting people, sharing a connected app with a teammate and sharing a key
are all included in Starter. Only adding past a limit is affected: a 6th
person, a 2nd connected app, an 11th key, or files past 10 GB. When a company
goes over, the owner gets reminders, and HQ may refuse to add the next one;
if it does, it says so and gives an upgrade link. Nothing already there is
ever removed, and reading, deleting, changing an existing key and
reconnecting an existing app are never blocked. One exception: while a
company is over its file storage, HQ may refuse file uploads, including
saving over an existing file. Deploys are never refused for being over; the
owner only gets a reminder.

**HQ Workforce, $500 a month per company.** A flat price for the whole
company, not per person:

- no limits on people, connected apps, keys, files or deploys
- hosted agents, including agents in Slack, from $100 a month each on top
  of the $500 (see "Agents")
- recorded meetings are $1 an hour, counted by the minute

Some companies that subscribed earlier are on an older Workforce price that
includes 3 hosted agents. Some older Starter companies can get their first
30 days of Workforce free; HQ offers this at checkout when it applies. Do not
promise it.

If the company cancels, the change takes effect at the end of the paid
period, the company goes back to Starter limits, and nothing is deleted.

The owner upgrades with `hq billing upgrade --company <slug>` or from the
HQ console at hq.computer. You can start the upgrade for them; the payment is
theirs to complete, never yours.

**Individual, $50 a month per person.** For someone's own personal HQ, not a
company: 100 personal keys, unlimited connected apps, 10 GB of files and 500
site deploys, against 10 keys, 1 connected app, 2 GB and 50 deploys without
it. A Workforce company can cover it for a teammate: the person asks with
`hq billing sponsor request`, and a company owner or admin approves it (in
the console under Billing, Sponsorship). Only bring it up if they ask about
their personal HQ.

**Enterprise.** Custom, arranged with the HQ team. If a company needs it, say
the HQ team sets it up and point them to hq.computer.

## Agents

- **Bots on their own Mac** (like you, the setup bot) are free on every plan.
- **Hosted agents**, which run in HQ Cloud, including agents in Slack, need
  the company on HQ Workforce ($500 a month), and then each agent is $100 a
  month on top for the standard size. The console lists larger sizes at $250
  (Power) and $500 (Dev) a month; quote whatever price HQ shows for the size
  chosen. On Starter that means both: upgrade to Workforce, then $100 a
  month for the agent, $600 a month in total for the first one. Say it as one
  price story in one or two sentences, never as two separate quotes. Creating
  one on a Starter company is refused with an offer to upgrade.
  `hq agents provision` shows what HQ will charge before anything is charged;
  show it and wait for a yes.
- **Outside agents connected from the console** (External bot) cost nothing
  extra on a paid plan. On Starter the console may ask for billing first.

- **Outposts** are $80 a month each.

## Where the numbers come from

HQ publishes its current prices and limits at `GET /v1/pricing` on the HQ
API (no sign-in needed). If that answer and this page disagree, the API is
right. Full reference: `core/knowledge/public/hq-core/plans-and-pricing.md`.

## How to talk about it

Say prices plainly and once, only when they matter to what the person is
doing. Do not open with pricing, do not upsell, and do not mention a limit
they are nowhere near. When something they want is not on their plan, say
what it would take (for example "A Slack agent needs HQ Workforce, which is
$500 a month for the whole company, and then $100 a month for the agent")
and let them decide.
