---
id: hq-alert-baseline-calibration
title: Calibrate Alert Thresholds Against Known Patterns
scope: global
trigger: when creating monitoring, alerts, health checks, or anomaly detection
enforcement: soft
version: 1
created: 2026-04-02
updated: 2026-04-02
source: session-learning
public: true
---

## Rule

1. **Before setting alert thresholds, document the expected baseline behavior** including known patterns that should NOT trigger alerts. If 51% of a certain event type is expected to lack a particular field, that is not an anomaly — it is the baseline.
2. **Every alert rule must include an "expected exceptions" section** that lists known conditions under which the metric will appear abnormal but is actually healthy. Examples: new brands with no historical data, disconnected accounts, known platform behavior (e.g., Shopify checkout events without identity).
3. **Use percentage-of-baseline thresholds rather than absolute thresholds** when the metric varies by entity (brand, account, region). A brand doing 2 checkouts/day dropping to 1 is noise; a brand doing 200/day dropping to 5 is critical.
4. **Include a warm-up/calibration period for new entities.** New brands, new integrations, and recently reconnected accounts should be excluded from alerts for a defined period (e.g., 7 days) until a stable baseline is established.
5. **When an alert fires and is determined to be a false positive, immediately update the alert rule** to exclude that pattern. Do not dismiss the alert and leave the rule unchanged — it will fire again and erode trust in the monitoring system.

## Rationale

A health monitor fired CRIT 2 alerts claiming 20 brands were below 25% baseline — but the baseline itself was miscalibrated. 51% of checkout events having no identity data triggered anomaly alerts, but that is expected Shopify behavior. Stuck messages from disconnected brands were flagged as critical. Each false positive required investigation time and eroded trust in the alerting system, making it more likely that a real alert would be ignored.
