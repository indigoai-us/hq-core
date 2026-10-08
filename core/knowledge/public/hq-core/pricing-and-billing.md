# HQ pricing and billing

This page explains what HQ costs and how billing works. The numbers come from
`pricing.json` in this folder, which is a copy of the HQ API pricing endpoint
(`GET /v1/pricing` on the HQ API base, default https://hqapi.hq.computer)
taken at release time. When you need a price, read `pricing.json` or the endpoint. If they disagree, the
endpoint is correct and the shipped copy is stale. Policy:
`core/policies/hq-pricing-source-of-truth.md`.

## Plans

- **Starter** is free. It has fixed limits on members, secrets, deployments,
  storage and integrations, and it does not include hosted agents.
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

An eligible Starter company can take a free-month offer once. The Workforce
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
_Generated from pricing.json (statement generated 2026-10-08T17:06:11.358Z). Do not edit by hand; run core/scripts/refresh-pricing.sh._

### Plans (per month, USD)

| Plan | Price | Included agents | Members | Secrets | Deployments | Storage | Integrations |
|---|---|---|---|---|---|---|---|
| Starter | $0 | 0 | 5 | 10 | 500 | 10 GB | 3 |
| Workforce | $500 | 0 | unlimited | unlimited | unlimited | unlimited | unlimited |
| Enterprise | contract | 0 | unlimited | unlimited | unlimited | unlimited | unlimited |
| Individual | $50 | 0 | 1 | 100 | 500 | 10 GB | unlimited |

### Agent boxes (per agent, per month)

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
