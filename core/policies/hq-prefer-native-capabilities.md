---
id: hq-prefer-native-capabilities
title: Prefer HQ-native capabilities over runtime-native surfaces for sharing and secrets
when: always || artifact || canvas || share || deploy || publish || present || secret || credential || token
on: [SessionStart, UserPromptSubmit, AssistantIntent]
enforcement: hard
tier: 1
version: 2
created: 2026-07-15
source: prd:hq-prefer-native-capabilities/US-001
public: true
---

## Rule

Use /deploy for URL-shaped deliverables and /hq-share for vault paths; explicitly requested local Slack attachments may use the native audited upload helper.

Deliverables land on HQ-governed infrastructure in **every** runtime (Claude
Code, Codex, Grok Build, Slack-connected agents). Do **NOT** publish or host
results through runtime-native surfaces:

- **Claude artifacts / Claude canvas** — rendering surfaces, not delivery
  channels. No access control, no vault, no tenant isolation.
- **Grok message canvas** — same rule: the canvas may render a preview, but
  the deliverable still goes through `/deploy`.
- **Slack canvas** — a rendering surface, not a delivery channel. Deploy a
  URL-shaped deliverable first, then share the link.
- **Slack file attachments** — when the user explicitly asks to attach a local
  file in Slack, use the native audited Slack upload helper. A requested file
  attachment is delivery inside an already-authorized Slack conversation, not
  publishing or hosting an artifact. This exception does not authorize posting
  to a different or unrequested channel.
- **Ad-hoc hosting** — one-off local servers, pastebins, gists, unmanaged
  buckets, or any hosting reached outside HQ commands.

HQ-native replacements:

| Need | Use |
|------|-----|
| Share a URL-shaped artifact (report, dashboard, deck, site) | `/deploy` |
| Share a vault path | `/hq-share <path>` |
| Attach a local file in the authorized Slack conversation, when explicitly requested | Native audited Slack upload helper |
| Browse or grant vault access | `/hq-files` |
| Use a credential / secret / token in a command | `/hq-secrets`, `hq run`, `hq secrets exec` |

Never paste secret values into any chat, canvas, artifact, or file surface —
inject them by name through the secrets commands above.

A runtime canvas MAY serve as an ephemeral preview while iterating. The moment
something is a URL-shaped deliverable — the user asks to publish, host,
present, or keep it at a link — it goes through `/deploy`. Vault paths go
through `/hq-share`. A request to attach a local file directly in the current
Slack conversation uses the narrowly scoped attachment exception above.

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
message canvas, or unrequested file uploads — deliveries that bypass HQ ACLs,
the vault, and tenant isolation. This policy closes that gap as a hard,
always-injected baseline across all companies while preserving an explicitly
authorized, audited Slack attachment path.

`when:` carries an explicit `always` head because `on: [SessionStart]`
policies are still gated by their `when:` expression at session start, and
SessionStart fact sets contain no artifact/canvas/share tokens — without
`always` the baseline injection would never fire. The reactive tokens after
`always` document the mid-session intent triggers (canvas / share / secret
wording) and keep the rule keyed to them if a future edit narrows `on:`.
