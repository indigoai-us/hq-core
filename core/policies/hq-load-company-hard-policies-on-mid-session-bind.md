---
id: hq-load-company-hard-policies-on-mid-session-bind
title: Load a company's hard policies when it is bound mid-session, before any infra/deploy/credential work
when: company
on: [SessionStart, PreToolUse, UserPromptSubmit]
enforcement: hard
public: true
vendor_public_ok: true
version: 1
created: 2026-05-31
updated: 2026-06-01
source: user-correction
tags: [hq-core, company-isolation, credentials, policies, session]
---

## Rule

ALWAYS, when a company is bound mid-session (e.g. `hq-session.sh set company_slug`, or working straight into a company task), load that company's hard-enforcement policies (`companies/{co}/policies/`) BEFORE any infrastructure, deploy, or credential work. SessionStart only injects company policies for the company known at session start, so a mid-session bind leaves them unloaded until you read them explicitly.

For company AWS/prod work (e.g. deploying a company app to production), credentials come ONLY via `hq secrets exec` — agent sessions have NO local AWS-profile fallback. So a `NoCredentials` error means reach for the vault (`hq secrets exec`), never give up and never fall back to another company's profile.

## Rationale

The SessionStart hook can only inject policies for the company it knew at launch. Binding a different company later (or starting from the HQ root and anchoring into a company) silently skips that injection, so the company's credential-isolation and infra guardrails are absent exactly when infra/deploy/credential work begins — the highest-stakes moment. Explicitly reading `companies/{co}/policies/` on bind closes that window. Pairs with `credential-access-protocol` (cross-company credential isolation) and `natural-language-mode` (anchor before company work).
