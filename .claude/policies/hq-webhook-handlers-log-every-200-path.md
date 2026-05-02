---
id: hq-webhook-handlers-log-every-200-path
title: Webhook handlers must log on every silent-success path
scope: global
trigger: writing or reviewing any HTTP webhook handler that returns a 200 response
enforcement: soft
public: true
version: 1
created: 2026-04-25
updated: 2026-04-25
source: session-learning
---

## Rule

ALWAYS emit a tagged log line on every code path that returns 200 (or any 2xx) from a webhook handler — including the silent-skip paths. This is non-negotiable for handlers fronting an external delivery system (Resend, Stripe, Slack, GitHub, etc.) where the operator needs to distinguish:

- "Provider stopped delivering" (no log lines at all)
- "Provider is delivering but our handler is filtering" (log lines present, but skip-tag set)

Every 200 response path must include a log line of the form `[<handler-tag>] <action>` — for example `[sendbox] Webhook received event=<type>`, `[sendbox] Webhook skipped reason=no-identity`, `[sendbox] Webhook skipped reason=non-target-event`. NEVER write a bare `return Response.json({ ok: true }, 200)` without an accompanying tagged log line.

The log tag must be:

1. Stable (do not rename across releases — alarms grep on it)
2. Distinctive (no generic `[webhook]` — collisions defeat metric filters)
3. Present on EVERY 200-return path including `try/catch` short-circuits, validation failures that we treat as success, and provider-replay short-circuits

## Rationale

A 28-day sendbox inbound outage was invisible to operators because `createWebhookHandler` short-circuited on non-`email.received` event types and on `No identity found` errors with a bare `return Response.json({ ok: true, ... }, 200)` — no log line on either skip path. The CloudWatch alarm `HollerMgmt-SendboxInbound-Stalled` correctly detected the absence of `[sendbox] Webhook` log lines and fired, but the operator could not tell from logs alone whether Resend had stopped delivering or our handler was silent-skipping legitimate inbound traffic.

A logged silent-success path turns the handler into a CloudWatch metric source — making suppression vs filtering distinguishable in seconds, not days.
