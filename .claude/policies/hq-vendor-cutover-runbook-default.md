---
id: hq-vendor-cutover-runbook-default
title: Default Phase-4 vendor cutovers to runbook + code-side verification, not dashboard automation
scope: global
trigger: migration phase involving Vercel/Clerk/Stripe/Supabase/Resend/Auth0/Twilio dashboard work
enforcement: soft
public: true
version: 1
created: 2026-04-24
updated: 2026-04-24
source: session-learning
---

## Rule

Phase-4 vendor cutovers (any migration step that requires touching a vendor dashboard — Vercel project settings, Clerk app config, Stripe webhook URLs, Supabase project rotation, Resend domain verification, etc.) should default to a `runbook + code-side verification` deliverable rather than attempting dashboard automation via the vendor's API or CLI.

Deliverable shape:
- A short numbered runbook the human follows in the vendor console (with screenshots/anchors when the UI is non-obvious)
- An automated code-side verification script that probes the production surface after the human flips the switch (HTTP probes, DB queries, webhook test events) and reports pass/fail

Treat the vendor console as out-of-band. Only pursue dashboard automation when the vendor publishes a stable, scoped API and the same migration step will recur ≥3 times.

## Rationale

Both stalled when first attempted as automated dashboard mutations: Vercel's project-settings API is partially undocumented and gated by team-scoped tokens; Clerk's allowlist endpoints require an admin-tier secret that the migration session didn't carry. The runbook + verification path completed both in minutes once we stopped fighting the API. The verification script (curl probes against production) caught the actual cutover failures (apex-redirect mismatch in US-012) — exactly what dashboard automation would NOT have caught, since it tests the dashboard side, not the served-traffic side.
