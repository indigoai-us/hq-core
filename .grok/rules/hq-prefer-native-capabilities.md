# HQ-native capabilities — deliverables go through /deploy, not the canvas

Grok-only project rule. Do not mirror into Claude hooks or the shared root charter.

The **message canvas is a rendering surface, not a delivery channel.** Rich
inline rendering (callouts, tables, charts, stats cards per
`.grok/rules/message-canvas.md`) is encouraged for *presenting* work in the
conversation — but the deliverable the user or a teammate walks away with must
land on HQ-governed infrastructure:

1. **`/deploy`** — any artifact with a URL form (reports, dashboards, decks,
   pages, apps). Deploy first, then share the returned link; render a canvas
   preview alongside it if useful.
2. **`/hq-share <path>`** — vault paths (single-use links or direct ACL
   grants).
3. **`/hq-secrets`, `hq run`, `hq secrets exec`** — anything involving
   credentials, tokens, or API keys. Never paste secret values into the
   canvas, a message, or a file.

Never treat a canvas render, a message attachment, or ad-hoc hosting
(pastebins, gists, temp servers) as the delivered result — those bypass HQ
ACLs, the vault, and tenant isolation.

Source of truth (full rule + rationale):

- `core/policies/hq-prefer-native-capabilities.md`
- Deploy-flow detail: `core/policies/hq-deploy-reinforcement.md`,
  `core/policies/auto-deploy-on-create.md`
