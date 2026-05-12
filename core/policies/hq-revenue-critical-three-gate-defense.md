---
id: hq-revenue-critical-three-gate-defense
title: Revenue-critical surfaces need three-gate MTTD defense (human + machine + data)
scope: global
trigger: when designing monitoring/alerting for a checkout flow, signup funnel, subscription renewal, or any user-facing surface whose breakage loses money per hour of downtime
enforcement: soft
public: true
version: 1
created: 2026-04-23
updated: 2026-04-23
source: session-learning
---

## Rule

When an MTTD (mean time to detect) bug has shipped to production and stayed broken for days, a single gate is insufficient. Revenue-critical surfaces MUST be defended by **at least three independent gates operating on different time-scales and different signals**. Each gate alone would have caught the original failure; together they cap MTTD at the fastest-gate interval.

### The three gates

1. **Human-loop gate** — pre-push hook, PR review checklist, or stage-gate in `/run-project`. Runs at commit time. Catches failures before they ship. Signal source: reviewer eyes + automated lint/type/test.
2. **Machine-loop gate** — scheduled heartbeat canary (hourly minimum, 3×/day acceptable for lower-traffic surfaces). Runs canned E2E tests against production URLs: "is the signup page reachable, does it render the form, does the submit button exist, does a test submission get a 2xx?" Signal source: synthetic traffic mimicking a real user.
3. **Data-loop gate** — rate-drop alert on actual conversion metrics (signups/day, orders/hour, checkout completions). Fires when the moving average drops >N% vs. trailing baseline. Signal source: real user behavior aggregated from the product DB / analytics.

### Why all three

Each layer has blind spots the others cover:

| Gate | Blind spot | Covered by |
|------|-----------|------------|
| Human pre-push | Regressions introduced by dependency updates, config drift, or external service changes after the push | Machine heartbeat |
| Machine heartbeat | Bugs that only affect a user segment (specific browser, specific auth state, specific data shape) | Data-loop |
| Data-loop | Slow/zero traffic surfaces where "signups dropped 50%" is statistically invisible for days | Machine heartbeat |

A single gate misses some axis of failure. Two gates still leaves a blind spot (e.g. machine + data misses local-env regressions caught by human review). Three independent gates, by construction, cover the cross-product.

### MTTD math

- Pre-push alone: MTTD = "time until someone notices" (days, in practice).
- Pre-push + heartbeat (1h): MTTD ≤ 1h regardless of whether anyone's looking.
- Pre-push + heartbeat (1h) + rate-drop alert: heartbeat catches reachable-but-broken; rate-drop catches subtle segment bugs the canary doesn't notice.

Worst-case MTTD with three gates is bounded by the heartbeat interval, ~5h for a 3×/day heartbeat and ~1h for hourly.

### When this applies

Apply the three-gate pattern to any surface where breakage costs money per hour: signup, checkout, subscription renewal, payment webhook, auth flow that gates paid features, lead form that feeds a sales pipeline. Do NOT apply it blanket to every page — the ops cost of three independent gates isn't justified for, say, a marketing blog post.

### Reference implementation

A signup-safeguards project shipped all three gates in 2026-04-22, with company-scoped policies for:
- Human-loop: a `gate-prod-deploy-on-signup-playwright` policy — pre-deploy Playwright runs against prod
- Machine-loop: a `post-deploy-html-canary-onboarding` policy + `signup-heartbeat` skill — hourly canary
- Data-loop: a `signup-floor-drop-alert` policy — floor-drop threshold on actual signup metrics

Replicate this triad for every revenue-critical surface. Company-scoped policies are concrete realizations of this abstract pattern.

## Rationale

Observed in the signup-safeguards post-mortem 2026-04-22: a signup-flow regression had been in production for multiple days before a manual spot-check surfaced it. The root cause was a middleware change that silently broke the signup submit endpoint for a subset of cookie states. Pre-push tests passed (didn't exercise the affected cookie shape). No canary existed. The signup-floor alert hadn't been wired up because "the signup page works, I just tested it."

Each of the three gates alone would have detected the regression within hours instead of days. Layering them is cheap (the canary is ~50 lines of Playwright; the rate-drop alert is a scheduled SQL + Slack webhook) relative to the revenue cost of even one day of silent breakage on a paid-signup funnel. For any surface where "silent" and "revenue-critical" can both be true, single-gate defense is malpractice.

This is the generalized pattern; company-scoped policies under `companies/{co}/policies/` hold the specific implementations.
