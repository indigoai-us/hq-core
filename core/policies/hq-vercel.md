---
id: hq-vercel
title: Vercel — never deploy to a prod custom domain without confirmation
scope: global
when: deploy
on: [PreToolUse, UserPromptSubmit, AssistantIntent]
enforcement: hard
version: 2
created: 2026-04-29
updated: 2026-07-28
applies_to: [vercel]
public: true
vendor_public_ok: true
tags: [vendor:vercel, gate]
source: split-from-hq-vercel
---

## Rule

NEVER deploy to a production custom domain (e.g. `token.{your-domain}`, `{your-domain}.com`) without explicit user confirmation. An existing Vercel project that carries custom-domain aliases is a LIVE production site, and an accidental deploy or alias flip can take it down. "Deploy to a temporary Vercel site" means a fresh project with only a `*.vercel.app` URL and no custom-domain aliases — that is the safe default; anything touching a real domain needs a clear go-ahead first.

**Full Vercel reference** (CLI discipline, deploy routing, pnpm/peer-dep pinning, domain moves and Route 53 setup, project creation, and edge cases — 30+ rules) is on-demand in `hq-vercel-reference` — not auto-injected. `qmd get -c hq-infra hq-vercel-reference`.
