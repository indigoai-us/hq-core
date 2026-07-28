---
id: hq-linear
title: Linear — auth header, description cap, PRD-scan hygiene
scope: global
trigger: when working with Linear (issues, projects, MCP, sync)
when: linear
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
version: 2
created: 2026-04-29
updated: 2026-07-28
applies_to: [linear]
public: true
vendor_public_ok: true
tags: [vendor:linear, gate]
source: split-from-hq-linear
---

## Rule

Three always-on hard rules when touching the Linear API:

1. **Auth header — no `Bearer` prefix.** ALWAYS authenticate with `Authorization: <api_key>` (the plain key). NEVER `Authorization: Bearer <api_key>` — Linear API keys are not OAuth tokens and Linear rejects the Bearer prefix with a 400.

2. **`description` is capped at 255 chars — long bodies go in `content`.** Projects and issues expose two distinct fields: `description` (short summary, hard-capped at 255; `projectCreate`/`projectUpdate`/`issueCreate` reject >255 with HTTP 400 / `ARGUMENT_VALIDATION_FAILED`) and `content` (unlimited markdown). Any PRD→Linear sync MUST route the short summary to `description` (≤230 chars, truncated at a word boundary + `…`) and the full body to `content`. NEVER dump the long body or acceptance criteria into `description`.

3. **Scan checks existing PRDs first.** Before recommending a new PRD from a Linear scan, ALWAYS check `companies/{product}/projects/` for existing `prd.json` files whose `linearIssueId` covers the same issues, so you don't duplicate an existing project.

**Full Linear reference** (batched aliased mutations and rationale) is on-demand in `hq-linear-reference` — not auto-injected. `qmd get -c hq-infra hq-linear-reference`.
