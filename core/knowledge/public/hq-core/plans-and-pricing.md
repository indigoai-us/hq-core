---
type: reference
domain: [operations, billing]
status: canonical
tags: [pricing, plans, billing, limits, hq-pro, hq-cli]
relates_to:
  - hq-console.md
  - vault-databases.md
  - native-knowledge-stores.md
  - ../../../workers/public/setup/skills/pricing.md
verified_against:
  - hq-pro@563bf1f39 (2026-09-27)
  - hq-cli@dfe49a48 (2026-09-27)
  - hq-deploy@9e42c1e (2026-09-27)
  - hq-console@a227a042 (2026-09-27)
---

# HQ plans and pricing

This page is the hq-core mirror of hq-pro's pricing statement. Prices and
limits change. The source of truth is the live API:

```bash
curl -s https://hqapi.hq.computer/v1/pricing | jq .
```

`GET /v1/pricing` needs no sign-in, is cached for 5 minutes, and returns
`version`, `generatedAt`, `currency`, `interval`, `plans`, `agentRungs`,
`addOns` (`outpost`, `meetingHours`, `notes`), `grandfather`, `billingRules`,
and `writerModes`. A `503 PRICING_UNAVAILABLE` means the catalog could not be
loaded; do not fall back to guessing. When this page and the API disagree, the
API is right.

Billing is live: Stripe checkout, invoices, and the billing webhook are wired
in hq-pro, and `hq billing` drives them from the CLI.

## Plans

| Plan id (internal) | Name | Scope | Price | People | Secrets | Integrations | Deploys | Storage | Hosted agents included |
|---|---|---|---|---|---|---|---|---|---|
| `free` | Starter | company | $0 | 5 | 10 | 1 | 500 (lifetime) | 10 GiB | 0 |
| `paid-500` | HQ Workforce | company | $500/mo flat | unlimited | unlimited | unlimited | unlimited | unlimited | 0 (current price); 3 on the legacy price |
| `enterprise` | Enterprise | company | per contract | unlimited | unlimited | unlimited | unlimited | unlimited | per contract |
| `personal-50` | Individual | person | $50/mo | 1 | 100 | unlimited | 500 | 10 GiB | 0 |
| (unpaid personal scope) | none | person | $0 | 1 | 10 | 1 | 50 (lifetime) | 2 GiB | 0 |

Notes:

- Starter "people" counts humans and self-run bots, and unaccepted invites
  count toward the 5.
- Workforce is priced per company, not per person. A $20/mo seat price exists
  in the Stripe catalog, but seat billing is switched off and is not part of
  the pricing statement.
- Enterprise has no public price. HQ staff assign it.
- Naming: the product is "HQ Workforce". Internal leftovers still say "team"
  (Stripe lookup keys `hq-team-flat-monthly` and `-v2`, `requiredPlan: "team"`
  in some 402 bodies, the "HQ Team Meeting Hours" product, and a few error
  strings). Treat "HQ Team" in any message as HQ Workforce.

### Workforce versions

| Version | Stripe lookup key | Included hosted agents | Status |
|---|---|---|---|
| v1 | `hq-team-flat-monthly` | 3 (one Dev box and two Basic boxes, applied as credits) | legacy, kept for existing subscribers |
| v2 | `hq-team-flat-monthly-v2` | 0 | current |

On Workforce the company's setup agent does account work (signals extraction,
ontology gardening) and is part of the plan. It cannot be deleted while the
company is on the plan.

## Add-ons

| Add-on | Price | Notes |
|---|---|---|
| Hosted agent, Basic (t3.medium) | $100/mo | Default size. |
| Hosted agent, Power (t3.large) | $250/mo | Listed in the console wizard. |
| Hosted agent, Dev (t3.xlarge) | $500/mo | Listed in the console wizard. |
| Outpost | $80/mo | |
| Meeting hours | $1/hour | Metered per minute from the first minute, no included hours, billed monthly in arrears on the Workforce subscription. |

Hosted agents require Workforce (or Enterprise). Creating one on Starter is
refused with "HQ Workforce plan required to create an agent" and an upgrade
link. Whether Power and Dev are charged at their own price or at the Basic
price depends on a server-side billing mode; `hq agents provision` and the
console's add-bot wizard show the price HQ will charge before anything is
charged. Quote that price.

External agents connected from the console (the "External" bot type) cost
nothing extra on a paid plan. On Starter, enrollment is refused with
`BILLING_REQUIRED`.

## Trial

A 30-day free month of Workforce, once per company, offered at Workforce
checkout only when all of these hold: the caller is the owner, the company is
on Starter and not paying or exempt, it has not used the offer, and it was
created before 2026-07-31. Newer companies do not get it. Do not promise it;
checkout shows it when it applies.

## Sponsorship

- **Individual plan sponsorship:** a Workforce company pays a member's $50
  Individual plan. No cap on how many. A company on any other plan gets
  `403 SPONSOR_PLAN_REQUIRED`.
- **Resource sponsorship:** a company pays for a member's personal Outpost or
  agent. At most one sponsor per resource.
- **Flow:** the member runs `hq billing sponsor request` (or asks in the
  console); an owner or admin approves or declines on the console's Billing →
  Sponsorship page or with `hq billing sponsor approve|decline`. `list`,
  `revoke`, and `withdraw` round out the CLI.

## What happens at a limit

For companies, only Starter limits are enforced. Paying, exempt,
grandfathered, and sponsored companies are skipped. Individual and unpaid
personal scopes have their own ceilings (table above).

- **Reminders.** At 80% or more of a limit, responses can carry a warning and
  the owner gets reminders.
- **Hard stops (402).** Four actions can be refused when the company is over
  that same resource: adding a person, adding a new secret, connecting a new
  integration, and uploading files (while over storage, file uploads are
  refused even for existing paths). The body has `error: "plan_limit_reached"`
  plus `upgradeUrl`. The CLI renders it as "Starter plan limit reached:
  <resource> <used>/<limit> used." Whether stops are active is a server
  setting (`off`, `observe`, `on`); if evaluation fails, the request is let
  through.
- **Never refused:** reads, deletes, rotating an existing secret, reconnecting
  an existing integration, deploys, and hosted agents (agents are reminder
  only in this model; creation is gated by the Workforce requirement above).
- **Deploys.** hq-deploy never blocks a deploy on plan limits. Starter
  companies near or over the 500-deploy limit get a `planLimits` nag in some
  deploy responses.
- **Custom deploy domains** check a separate staff-assigned plan field
  (`pro` or `enterprise`); see the `/deploy` skill.
- **Remote vault DB** (`hq db provision`) requires Workforce; see
  `vault-databases.md`.
- **Meeting bot invites** require Workforce (`MEETING_PLAN_REQUIRED`).

Cancelling Workforce takes effect at the end of the paid period. The company
returns to Starter limits and no data is deleted.

## Checking and changing a plan

| Task | CLI | Console |
|---|---|---|
| See subscription status (owner only) | `hq billing status --company <slug> [--json]` | Company → Billing |
| Upgrade a company to Workforce | `hq billing upgrade --company <slug>` (opens Stripe Checkout) | Company → Billing |
| Add a card (Stripe card-capture link) | `hq billing checkout --company <slug>`; `--personal` for your own charges | Company → Billing, or Account → Billing |
| Pay for your own resources in a company ("I'll pay") | none | Company → Billing → Person |
| Sponsorship | `hq billing sponsor request|list|approve|decline|revoke|withdraw` | Company → Billing → Sponsorship |
| Seats view | none | Company → Billing → Seats |

There is no `hq pricing` command; use `GET /v1/pricing`. Payment is always
completed by the person paying, never by an agent.

## Sources

- hq-pro `src/billing/pricing-statement.ts` (statement served by `GET /v1/pricing`)
- hq-pro `src/vault-service/handlers/pricing.ts`, `infra/vault-service.ts` (route, no auth)
- hq-pro `src/billing/plan-limits.ts` (plan ceilings, unpaid personal limits)
- hq-pro `infra/stripe-catalog.ts` (prices, agent rungs, Workforce v1/v2, outpost, seat)
- hq-pro `src/billing/free-month.ts` (trial), `src/billing/plan-sponsorship.ts`, `infra/sponsorship-table.ts`, `src/billing/sponsorship-request.ts`
- hq-pro `src/billing/plan-hard-stop.ts`, `src/billing/plan-limit-status.ts` (enforcement)
- hq-pro `src/billing/team-agent-credit.ts` (setup agent), `src/meetings/bot/bot.service.ts` (meeting gate), `src/agents/external/plan-gate.ts`
- hq-cli `src/commands/billing.ts`, `src/commands/billing-sponsor.ts`, `src/utils/plan-gate-error.ts`, `src/commands/agents.ts`
- hq-deploy `src/services/deployment-plan-limit-gate.ts`, `src/services/usage-limits-client.ts`, `src/api/routes/lifecycle-mutations.ts`
- hq-console `src/components/agents/AddAgentWizard.tsx`, `src/app/(shell)/companies/[slug]/billing/`
