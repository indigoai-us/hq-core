# HQ pricing and billing

This page explains what HQ costs and how billing works. The numbers come from
`pricing.json` in this folder, which is a copy of the HQ API pricing endpoint
(`GET /v1/pricing` on the HQ API base, default https://hqapi.hq.computer)
taken at release time. When you need a price, read `pricing.json` or the endpoint. If they disagree, the
endpoint is correct and the shipped copy is stale. Policy:
`core/policies/hq-pricing-source-of-truth.md`.

## The usage card (new signups from 2026-10-16)

Companies and personal accounts created from `usage.newSignupsFrom`
(2026-10-16 18:00 UTC) are on the usage card in `usage`. There is no plan
fee, no seat price and no minimum. Every month includes `usage.includedUsd`
of usage, and usage past it is billed at the rates in `usage.meters`: syncs
that move files (per leg), gateway calls (connected apps and external MCP
servers through HQ), HQ MCP calls, agent runs, storage, stored secrets, and a
vault fee for each company vault and each personal vault. The vault fee is a
usage line, so the included usage covers it.

The trial is `usage.trial.days` days of usage free, capped at
`usage.trial.capUsd`. Meters marked `waivedInTrial` (the vault fee) are not
charged during the trial. Items in `usage.free` (deploys, DMs, background AI)
are never charged. Domains are priced in `usage.domains`.

Hosted boxes for new accounts use the sizes in `usage.boxes` (small, medium,
large, xlarge). Existing customers keep their current box prices (the agent
boxes table below).

New signups choose one of `signup.options`: sign up free (the usage card) or
request an enterprise demo. `signup.selfHosted` links to the guide for using
HQ free, self-hosted or on-prem.

## Legacy plans (existing customers)

Starter, Workforce and Individual are closed to new signups from the cutover
(`plans[].newSignupsUntil`). Existing customers keep their current plan and
box prices. The rest of this page up to "Current numbers" describes these
plans.

- **Starter** is free. It has fixed limits on members, secrets, storage and
  integrations, and it does not include hosted agents.
- **Workforce** is a flat monthly price per company. It has unlimited members
  and no resource limits. The current Workforce price includes no hosted
  agents; each agent is billed separately (see below).
- **Enterprise** is priced by contract. It has no resource limits.
- **Individual** is a flat monthly price for one person's personal vault. It
  does not include hosted agents.

## Members

Humans and self-run bots count as members. Members are never billed per seat.
Starter has a member cap. Workforce and Enterprise have unlimited members.

## Hosted agents

On the current Workforce price, every hosted agent is billed per box from the
first agent. Each agent runs on a box size, and each size has a listed
monthly price: basic (t3.medium) $100, power (t3.large) $250, and dev
(t3.xlarge) $500. Basic is the default. By default, billing charges
every agent at the default size's price. Agents are charged at their own
size's price only when the tiered billing mode is turned on. Only sizes marked "buyable today" in
the table below can be bought; the others are listed prices that are not yet
on sale. All three sizes are buyable today.

A daily sweep brings each subscription's agent charges in line with the
company's current agents. If you add or remove an agent, the bill reflects it
by the next sweep at the latest.

## Legacy Workforce subscriptions

Companies that subscribed on the legacy Workforce price keep its included
agent boxes. The included boxes are applied as credits by size. Agents beyond the included
boxes are billed at their size price. New Workforce subscriptions use the
current price, which includes no agents.

## Meeting hours

Recorded meeting time is metered per minute from the first minute. There is
no free allowance. It is billed monthly, after use, on the Workforce
subscription.

## Outposts

An outpost is an add-on with its own flat monthly price.

## Trials

On the usage card, see the trial above. On the legacy plans, an eligible Starter company can take a free-month offer once. The Workforce
checkout then starts with a 30-day trial and bills normally when the trial ends.

## Cancelling

Cancelling takes effect at the end of the paid period. The company then returns to
Starter limits and agent billing stops with the subscription. No data is
deleted.

## Invoices

Company owners manage invoices and payment methods in the Stripe billing
portal, which HQ opens for the company's owner.

## Current numbers

<!-- pricing:numbers:start -->
_Generated from pricing.json (statement generated 2026-10-20T05:12:44.286Z). Do not edit by hand; run core/scripts/refresh-pricing.sh._

### Usage card (new signups from 2026-10-16, card version 2026-10-16)

| Meter | Price | Per | Waived in trial |
|---|---|---|---|
| Sync | $0.10 | sync | no |
| Gateway call | $0.05 | call | no |
| HQ MCP call | $0.05 | call | no |
| Agent run | $0.05 | run | no |
| Storage | $2.00 | GB-month | no |
| Secret | $0.50 | secret-month | no |
| Vault | $5.00 | vault-month | yes |

- Included usage: $10 per month.
- Trial: 30 days, capped at $500 of usage.
- Free: deploys, DMs, background AI.
- Domains: $20 standard, $500 premium, per month.

### Boxes on the usage card (per box, per month)

| Size | Instance | Price |
|---|---|---|
| small | t3.small | $100 |
| medium | t3.medium | $200 |
| large | t3.large | $400 |
| xlarge | t3.xlarge | $800 |

### Signup

- Sign up free (`free`)
- Book a setup call (`enterprise`)
- Use HQ free, self-hosted or on-prem: https://docs.hq.computer/hq/guide/use-hq-for-free/

### Legacy plans (per month, USD)

| Plan | Price | Included agents | Members | Secrets | Deployments | Storage | Integrations | New signups |
|---|---|---|---|---|---|---|---|---|
| Starter | $0 | 0 | 5 | 10 | unlimited | 10 GB | 3 | closed from 2026-10-16 |
| Workforce | $500 | 0 | unlimited | unlimited | unlimited | unlimited | unlimited | closed from 2026-10-16 |
| Enterprise | contract | 0 | unlimited | unlimited | unlimited | unlimited | unlimited | open |
| Individual | $50 | 0 | 1 | 100 | unlimited | 10 GB | unlimited | closed from 2026-10-16 |

### Agent boxes on legacy plans (per agent, per month)

| Size | Instance | Price | Buyable today |
|---|---|---|---|
| basic (default) | t3.medium | $100 | yes |
| power | t3.large | $250 | yes |
| dev | t3.xlarge | $500 | yes |

### Add-ons

- Outpost: $80 per month.
- Meeting hours: $1 per hour, 0 hours included.

### Legacy Workforce price

- $500 per month, 3 agents included: 1 dev (t3.xlarge), 2 basic (t3.medium).
<!-- pricing:numbers:end -->
