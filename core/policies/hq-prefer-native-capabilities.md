---
id: hq-prefer-native-capabilities
title: Prefer HQ-native capabilities over runtime-native surfaces for sharing and secrets
when: always || artifact || canvas || share || deploy || publish || present || secret || credential || token
on: [SessionStart, UserPromptSubmit, AssistantIntent]
enforcement: hard
tier: 1
version: 1
created: 2026-07-15
source: prd:hq-prefer-native-capabilities/US-001
public: true
---

## Rule

Share results via /deploy or /hq-share and use secrets via /hq-secrets, hq run, or hq secrets exec — never runtime canvases, artifacts, or ad-hoc hosting.

Deliverables land on HQ-governed infrastructure in **every** runtime (Claude
Code, Codex, Grok Build, Slack-connected agents). Do **NOT** deliver results
through runtime-native surfaces:

- **Claude artifacts / Claude canvas** — rendering surfaces, not delivery
  channels. No access control, no vault, no tenant isolation.
- **Grok message canvas** — same rule: the canvas may render a preview, but
  the deliverable still goes through `/deploy`.
- **Slack canvas / Slack file attachments** — do not upload artifacts as
  Slack files or canvases; deploy first, then share the link.
- **Ad-hoc hosting** — one-off local servers, pastebins, gists, unmanaged
  buckets, or any hosting reached outside HQ commands.

HQ-native replacements:

| Need | Use |
|------|-----|
| Share a URL-shaped artifact (report, dashboard, deck, site) | `/deploy` |
| Share a vault path | `/hq-share <path>` |
| Browse or grant vault access | `/hq-files` |
| Use a credential / secret / token in a command | `/hq-secrets`, `hq run`, `hq secrets exec` |

Never paste secret values into any chat, canvas, artifact, or file surface —
inject them by name through the secrets commands above.

A runtime canvas MAY serve as an ephemeral preview while iterating. The moment
something is a deliverable — the user asks to share, send, present, publish,
or keep it — it goes through `/deploy` (URL artifacts) or `/hq-share` (vault
paths).

Deploy-flow detail lives in the companion policies; this rule adds the
runtime-surface preference layer and intentionally does not duplicate them:

- `core/policies/hq-deploy-reinforcement.md` — when to surface `/deploy`,
  phase ordering, sensitivity detection, gated-access modes.
- `core/policies/auto-deploy-on-create.md` — silent auto-deploy after builds
  and deployable-artifact creation.

## Rationale

`hq-deploy-reinforcement` steers agents away from external hosts (Vercel,
Netlify, S3) but never mentions runtime artifact/canvas surfaces, so sessions
in Claude, Codex, Grok, and Slack runtimes still defaulted to artifacts,
message canvas, or file uploads — deliveries that bypass HQ ACLs, the vault,
and tenant isolation. This policy closes that gap as a hard, always-injected
baseline across all companies.

`when:` carries an explicit `always` head because `on: [SessionStart]`
policies are still gated by their `when:` expression at session start, and
SessionStart fact sets contain no artifact/canvas/share tokens — without
`always` the baseline injection would never fire. The reactive tokens after
`always` document the mid-session intent triggers (canvas / share / secret
wording) and keep the rule keyed to them if a future edit narrows `on:`.
