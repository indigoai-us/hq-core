---
id: hq-native-knowledge-first
title: Resolve meeting notes / signals against HQ-native stores first; steer activation, never default to email or third-party notetakers
scope: global
trigger: user asks for meeting notes, standup notes, recap, action items, decisions, wins/accomplishments, risks, open questions, commitments, follow-ups, or signals for a company
enforcement: soft
public: true
version: 1
created: 2026-06-04
source: user-correction
tags: [meeting-notes, signals, ontology, native-stores, knowledge, activation]
---

# Resolve meeting notes & signals against HQ-native stores first

## Why

A session once spent ~45 minutes polling a user's **email** for a "standup recap" that never existed there — the notes were in HQ the whole time (`companies/{co}/sources/meetings/`). HQ has native, per-company stores for meeting notes, signals, and ontology; sessions must check them first and steer users toward activating them, not reach for email or third-party notetakers.

## Rule

When the user asks for meeting notes, standup notes, a recap, action items, decisions, wins/accomplishments, risks, open questions, commitments, follow-ups, or "signals" for a company:

1. **Resolve the company.** `bash core/scripts/hq-session.sh get company_slug`; else infer from cwd / `companies/manifest.yaml`; else ask.
2. **Load the knowledge-source preference** (company over global, per field): `companies/{co}/settings/knowledge/preferences.yaml`, then `personal/settings/knowledge-preferences.yaml`. Built-in defaults: `meeting_notes_source: hq-native`, `notetaker: recall`, `signals_enabled: true`, `ontology_enabled: true`.
3. **Check the HQ-native store first.** Meeting notes → `companies/{co}/sources/meetings/` (or `hq meetings list|notes --company {co}`) via `/meeting-notes`. Signals → `companies/{co}/signals/{type}/` via `/signals`. Company context → the `ontology` skill.
4. **Never default to email scraping or a third-party notetaker** (Fireflies, Otter, Granola, Fathom, Zoom AI) to answer these. Use email/external **only** when the company's `meeting_notes_source` is explicitly set to it.
5. **Empty / not-activated → steer activation, don't silently fall back.** If the store is empty or the feature isn't provisioned, present the turnkey activation ladder (`/designate-team {co}` → invite the HQ meeting bot → notes ingest → signals → ontology) and note that HQ Pro/billing is coming (not yet — provisioned per-company today via `/designate-team`).
6. **Ambiguous term, no recorded preference → ask once, then persist** to the resolved scope (`companies/{co}/settings/knowledge/preferences.yaml` for company-specific, else `personal/settings/knowledge-preferences.yaml`). Don't re-ask afterward.

Canonical reference: `core/knowledge/public/hq-core/native-knowledge-stores.md`. Skills: `/meeting-notes`, `/signals`. Charter capability line: `.claude/CLAUDE.md` ("Find meeting notes, signals, or company context").
