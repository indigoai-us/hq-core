---
id: hq-settings-local-for-personal-allows
title: Personal permission allows belong in settings.local.json, not settings.json
scope: global
trigger: When asked to add pre-approved permissions for a single user or a non-public path
enforcement: hard
public: true
version: 1
created: 2026-04-17
updated: 2026-04-17
source: user-correction
---

## Rule

`.claude/settings.json` (HQ root) is core.yaml-locked and is the committed public kernel — it must not accumulate personal allow entries, absolute user paths, or entries tied to one owner's machine. Personal pre-approvals go in `.claude/settings.local.json` (gitignored, not core.yaml-tracked). Public defaults go in `repos/public/hq/template/.claude/settings.json` (shipped via `/publish-kit`).

Routing table:

| Audience | File | Notes |
|----------|------|-------|
| Only you | `.claude/settings.local.json` | Gitignored; safe for absolute paths and company-specific patterns |
| Every HQ user | `repos/public/hq/template/.claude/settings.json` | Use `{your-name}` placeholder; scrubbed by `/publish-kit` |
| HQ kernel | `.claude/settings.json` | Read-only — `protect-core.sh` blocks Edit/Write |

## Rationale

The root `.claude/settings.json` is locked to keep the committed kernel deterministic — if personal allows crept in, every fresh clone would inherit one user's workflow preferences. Meanwhile the template is the public default shipped to other HQ users; it needs the same allowlist logic but expressed with portable placeholders. Splitting by audience keeps all three files small, review-friendly, and scrub-clean.
