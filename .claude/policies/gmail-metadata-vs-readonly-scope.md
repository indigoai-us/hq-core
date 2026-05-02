---
id: hq-gmail-metadata-vs-readonly-scope
title: Prefer gmail.metadata over gmail.readonly to avoid CASA pentest
scope: global
trigger: Picking a Gmail API scope for a new integration or Google Cloud OAuth client
enforcement: soft
public: true
version: 1
created: 2026-04-17
updated: 2026-04-17
source: session-learning
applies_to: [gmail]
---

## Rule

ALWAYS: When choosing Gmail API scopes, prefer `https://www.googleapis.com/auth/gmail.metadata` (headers only: From / To / Cc / Date / Subject — no body, no attachment bytes) over `gmail.readonly` whenever header-level data is sufficient for the feature.

Use `gmail.readonly` **only** when you genuinely need message body content (e.g. parsing receipt line items, running NLP over thread text, extracting attachment files). If the feature is enumeration, ranking, or "who did I email recently" — that's metadata-only.

The same reasoning applies across any provider with a metadata-vs-content scope split (Google Drive, Microsoft Graph, Dropbox). Default to the narrower scope; expand only when a specific feature requires it.

## Rationale

Google's OAuth scope tiers materially differ in review obligations:

| Scope tier | Example | Review |
|------------|---------|--------|
| Sensitive | `gmail.metadata`, `drive.metadata.readonly` | Brand review, domain verification, privacy policy check — cleared via standard app verification (~1–2 weeks) |
| Restricted | `gmail.readonly`, `gmail.modify`, `drive`, `drive.readonly` | All of the above PLUS CASA (Cloud Application Security Assessment) pentest + annual recertification. Tier-2 CASA costs ~$5K–$15K per cycle. Tier-3 is more. |

For the Gmail teammate-discovery feature, `gmail.metadata` returns From/To/Cc/Date headers — enough to enumerate unique addresses at the user's corporate domain, rank by co-occurrence + recency, and surface suggestions. No body access is needed. Choosing `gmail.metadata` here avoids an annual ~$10K cost center and a weeks-long third-party pentest cycle without losing any feature capability.

When in doubt, prototype with `gmail.metadata` first — if the feature fundamentally can't work without body content, the gap becomes obvious and the CASA cost is a deliberate decision rather than a default.

References:
- https://developers.google.com/gmail/api/auth/scopes
- https://support.google.com/cloud/answer/13463073 (verification requirements)
- https://cloud.google.com/security/compliance/casa
