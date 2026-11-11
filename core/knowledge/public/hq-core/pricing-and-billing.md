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
servers through HQ), HQ MCP calls, agent runs, storage, stored secrets,
recorded meeting hours, and a vault fee for each company vault and each
personal vault. The vault fee and meeting hours are usage lines, so the
included usage covers them.

The trial is `usage.trial.days` days of usage free, capped at
`usage.trial.capUsd`. Meters marked `waivedInTrial` (the vault fee) are not
charged during the trial. Items in `usage.free` (deploys, DMs, background AI)
are never charged. Domains are priced in `usage.domains`: `standardUsd` and
`premiumUsd` for connecting a domain, and `purchase` for buying a new domain
through HQ (the registrar's price plus a yearly markup, renewed yearly on the
same basis and charged before each renewal; see the `domain-purchase` billing
rule).

Hosted boxes on usage pricing are billed at the list price for their size in
`usage.boxes`: small (t3.small) $100, medium (t3.medium) $200, large
(t3.large) $400 and xlarge (t3.xlarge) $800 a month. New accounts pay these
prices. When an owner switches an existing company on their own, its running
boxes move to these list prices at once. On the scheduled switch, boxes keep
their current price until HQ moves them to list prices, with notice
beforehand. Legacy box prices (the agent boxes table below) apply only until
then.

New signups choose one of `signup.options`: sign up free (the usage card) or
book a setup call (enterprise). `signup.selfHosted` links to the guide for using
HQ free, self-hosted or on-prem.

## Legacy plans (existing customers)

Starter, Workforce and Individual are closed to new signups from the cutover
(`plans[].newSignupsUntil`). Existing customers keep their current plan and
box prices only until the company moves to usage pricing, by the owner's own
switch or by the scheduled switch (see "Moving existing customers to usage
pricing"). The sections from here through "Trials" describe these plans as they
bill before the switch.

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

A hosted bot on the Workforce agent line, or billed on its own agent line on
any plan, is billed by its box's run state. On the Workforce agent line, a box that is running, launching
or pending is billed, even if a stop was requested and did not take. A bot that
is still being set up (no run state recorded yet) is billed, and so is an
autoscaled bot that HQ has idled without a stop. A box that is stopped,
terminated, parked by a rule, or in an unknown state is not billed, and it is
billed again when it starts. A bot on its own agent line is billed while its
box is running or pending, paused while the box is stopped (autoscaled bots
included), and left as it is when the box's state cannot be read. Local bots,
which run on your computer with no HQ box, are not billed.

On the current Workforce price, every running hosted agent is billed per box
from the first agent until the company switches to usage pricing. Each agent
runs on a box size with a legacy price: basic (t3.medium) $100, power
(t3.large) $250 and dev (t3.xlarge) $500 a month. Basic is the default. By
default, billing charges every agent at the default size's price. Agents are
charged at their own size's price only when the tiered billing mode is turned
on. Only sizes marked "buyable today" in the legacy table below can be bought;
all three sizes are buyable today. These legacy prices apply only until the
company's boxes move to `usage.boxes` list prices (see "Moving existing
customers to usage pricing").

A daily sweep brings each subscription's agent charges in line with the
company's running agents. If you add, stop, start or remove an agent, the bill
reflects it by the next sweep at the latest. A bot billed on its own agent line
is paused or resumed when it stops or starts, and a check every 5 minutes
catches any change that was missed. Stripe prorates each change: a stop gives a
credit for the rest of the period, and a start charges for it.

## Legacy Workforce subscriptions

Companies that subscribed on the legacy Workforce price keep its included
agent boxes. The included boxes are applied as credits by size. Agents beyond the included
boxes are billed at their size price. Only billed boxes use the included
boxes; a stopped or local bot never takes one. New Workforce subscriptions use the
current price, which includes no agents.

## Meeting hours

Recorded meeting time is metered per minute from the first minute. On usage
pricing, meeting hours are a usage line at $1 an hour (the `meeting-hour`
meter in `usage.meters`). The monthly `usage.includedUsd` ($10) covers them
like every other usage line, and they count toward the spend limit. On the
legacy Workforce plan there is no free allowance; meeting hours are billed
monthly, after use, on the Workforce subscription.

## Outposts

An outpost is an add-on with a flat monthly price for each size.

New Outposts are billed by size, starting at $100: $100 small, $200 medium,
$400 large, $800 xlarge. When a company moves to usage pricing, each of its
existing $80 Outposts is due to move to the price for its size. HQ makes
that price change as a separate step. Until then, an existing Outpost stays
at $80.

## Trials

On the usage card, see the trial above. On the legacy plans, an eligible Starter company can take a free-month offer once. The Workforce
checkout then starts with a 30-day trial and bills normally when the trial ends.

## Moving existing customers to usage pricing

Existing Workforce, Individual and Outpost-only accounts move to usage pricing
on December 19, 2026 at 00:00 UTC (the scheduled switch). Each account is
emailed beforehand with what changes for it. On the switch date the flat plan
ends with a prorated credit, and a 30-day preview starts: the company is on
usage pricing and sees its usage, but usage is not charged. Usage billing
starts 30 days after the switch date (January 18, 2027 for a December 19, 2026
switch), at the rates in `usage.meters` with `usage.includedUsd` of usage
included a month. Boxes keep their current price until HQ moves them to their
`usage.boxes` list prices, with notice beforehand. After that, HQ adds a box
to the bill when a bot starts. A bot billed on its own line is paused when it
stops. A company that has switched stays on usage pricing; there is no
switch back.

Before that date, a company owner may be offered a switch in the desktop app.
The app shows a preview first: the price today, the estimated price a month
after the switch, the box lines at list prices, the items that are kept, and
the spend limit before and after. The switch applies exactly what the preview
showed, including moving running boxes to list prices. If anything changed
since the preview, nothing is switched and the app shows the new preview. An
owner's own switch has no 30-day preview: usage is billed from the moment of
the switch. Only an owner can switch. The switch is not offered when HQ has
turned self-serve switching off with a server setting, or when the company's
plan is discounted, comped (enterprise, invoiced or staff-set), past due or
otherwise not active, was moved back by HQ staff before, carries items the
switch cannot keep, has a box setup that needs HQ support, or does not yet
have a complete usage estimate. A free company without a card on file is also
refused.

## Free accounts

Free companies and free personal accounts, legacy Starter companies included,
move to usage pricing 14 days after HQ sends them a notice. The notice gives
the date. From then, the first `usage.includedUsd` ($10) of usage a month stays
free. Above that, paid usage pauses until a card is added. No one is charged
without a card on file. Items in `usage.free` (deploys, DMs, background AI)
never pause.

For now, HQ is not sending these switch and usage notices. Each kind of
notice is turned on separately.

## Spend limit

On usage pricing, the default spend limit is `usage.spendLimit.defaultUsd`
($100) a month. The limit counts spend in each calendar month (UTC). An
existing company that has moved to usage pricing (by its
own switch or the scheduled switch) and has a card on file has no default
limit. An owner or admin can set a limit from $10 to $10,000 in whole dollars,
or remove it, on the company's Billing page in the desktop app. Spend is measured once a day,
so a pause can land up to a day after usage crosses the limit. When it does,
cloud sync, new secrets and gateway calls pause. They resume within about a
minute when an owner or admin raises the limit above the spend, or otherwise
on the first day of the next month (UTC). Deploys, DMs and sign-in never pause.
Spend alerts at set shares of the limit land after November 14, 2026.

## Canceling

An account on usage pricing has no plan fee to cancel; it pays for what it
uses. An owner or admin limits what the company can spend by lowering the
spend limit in the desktop app. The spend limit covers usage; box lines bill
separately (see "Moving existing customers to usage pricing"). No data is
deleted.

A legacy plan that is canceled takes effect at the end of the paid period.
Until December 19, 2026, the company then returns to Starter limits. From
December 19, 2026, it moves to usage pricing instead. Agent billing on the
plan stops with the subscription. No data is deleted.

## Invoices

Company owners open invoices and payment methods from the company's Billing
page in the desktop app (the Invoices button). The app opens Stripe's billing
page for the owner. Other members cannot open it.

Usage bills as one Stripe invoice a month. A usage-priced account gets one
usage subscription once it has usage to bill. The subscription carries every
metered line and the `usage.includedUsd` allowance. Its period ends on the 2nd at 12:00 UTC and
bills the previous calendar month (UTC).

Past-due reminders after the first failed-payment email come from dunning,
which runs once a day on its own schedule, separate from the plan-limit
checks.

## Current numbers

<!-- pricing:numbers:start -->
_Generated from pricing.json (statement generated 2026-11-10T23:49:38.455Z). Do not edit by hand; run core/scripts/refresh-pricing.sh._

### Usage card (new signups from 2026-10-16, card version 2026-10-16)

| Meter | Price | Per | Waived in trial |
|---|---|---|---|
| Sync | $0.10 | sync | no |
| Gateway call | $0.001 | call | no |
| HQ MCP call | $0.05 | call | no |
| Agent run | $0.05 | run | no |
| Storage | $2.00 | GB-month | no |
| Secret | $0.50 | secret-month | no |
| Vault | $5.00 | vault-month | yes |
| Meeting hours | $1.00 | hour | no |

- Included usage: $10 per month.
- Trial: 30 days, capped at $500 of usage.
- Free: deploys, DMs, background AI.
- Domains: $20 standard, $500 premium, per month.
- Domain purchase: registrar price plus $3 a year, renewing yearly on the same basis, charged before each renewal.

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

- Outpost: $100 per month.
- Meeting hours: $1 per hour, 0 hours included.

### Legacy Workforce price

- $500 per month, 3 agents included: 1 dev (t3.xlarge), 2 basic (t3.medium).
<!-- pricing:numbers:end -->
