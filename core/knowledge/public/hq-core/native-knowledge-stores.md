---
type: reference
domain: [operations, engineering]
status: canonical
tags: [meeting-notes, signals, ontology, recall-ai, native-stores, activation, preferences]
relates_to:
  - ontology-gardener.md
  - knowledge-taxonomy.md
---

# HQ-Native Knowledge Stores — Meeting Notes, Signals & Ontology

HQ captures **native, per-company stores** for meeting notes, meeting/comms intelligence ("signals"), and entity context ("ontology"). When a user asks for any of these, **check the HQ-native store first** — never default to searching their email or a third-party notetaker. This doc is the canonical reference behind the charter capability line and the `/meeting-notes`, `/signals` skills and the `hq-native-knowledge-first` policy.

> **Why this exists:** a session once spent ~45 minutes polling a user's email for a "standup recap" that never existed in email — the notes were in HQ the whole time. HQ core now tells every session where to look and how to steer activation.

## The three stores

### 1. Meeting notes — `companies/{co}/sources/meetings/`
- **Path:** `companies/{co}/sources/meetings/{uuid}.md` (transcript + metadata) `+ {uuid}.raw.json` (raw API payload).
- **Index:** `companies/{co}/sources/_index/{YYYY-MM-DD}.json` (per-date list of ingested meetings).
- **Origin:** the HQ meeting bot (**Recall.ai**) — invited to a call, records, transcribes, ingests.
- **Frontmatter:** `id`, `title`, `origin: recall.ai`, `meeting_platform` (google_meet|zoom|teams), `meeting_url`, `scheduled_start_time`, `created_at`/`ingested_at`, `recall_bot_id`, `bot_status`. Body: `## Transcript` (speaker + timestamp segments).
- **Generic reader:** `hq meetings list|get|notes|transcript|search --company {slug}` (read-only, multi-company). Direct Read of the `.md` files is the fallback.
- **Skill:** `/meeting-notes`.

### 2. Signals — `companies/{co}/signals/`
- **Path:** `companies/{co}/signals/{type}/{sha256}.md` (content-addressed; YAML frontmatter + body).
- **Index:** `companies/{co}/signals/_index/{YYYY-MM-DD}.json` (per-date list of written signals).
- **8 types:** `action_item`, `commitment`, `decision`, `risk`, `question`, `key_point`, `participant_contribution`, `summary`.
- **Frontmatter:** `canonical_content` (one-line normalized statement), `citations[]` (`location` timestamp, `source_ref`, verbatim `text`), `entity_refs[]` (`person/…`, `project/…`, `company/…`), `source_ref` (the meeting it came from), `type`, `signal_id`.
- **Produced by:** signal extraction over ingested meeting notes (and other sources) — runs on HQ cloud once a company is provisioned.
- **Skill:** `/signals` (generic, all companies). A company may also ship its own namespaced interface (e.g. `{co}:signals` / `{co}:action-items`) over the same store — those are company-specific conveniences; `/signals` is the generic reader.

### 3. Ontology — vault-backed entity graph
- **Path:** vault S3 `ontology/entities/{type}/{slug}.md` (types: person/project/company/concept) + `company-brief.md` at bucket root; watermark `ontology/.last-run`.
- **Produced by:** the ontology gardener (scheduled + event-driven Lambda). Mechanism: `ontology-gardener.md`.
- **Skill:** `ontology` (already multi-tenant — resolves the active company and reads ITS vault).

## Preference resolution — "what does *meeting notes* mean here?"

A user's meaning of "meeting notes" can differ by company. Resolve it from two optional YAML files, **company over global, per-field**:

1. `companies/{co}/settings/knowledge/preferences.yaml` (per-company override)
2. `personal/settings/knowledge-preferences.yaml` (global default; symlinks into `core/` via reindex)
3. Built-in defaults when neither sets a field: `meeting_notes_source: hq-native`, `notetaker: recall`, `signals_enabled: true`, `ontology_enabled: true` — so a brand-new company works with no file.

Schema:
```yaml
version: 1
meeting_notes_source: hq-native    # hq-native | email | external
notetaker: recall                  # recall | none
signals_enabled: true
ontology_enabled: true
aliases:
  meeting_notes: [standup notes, recap, call notes, meeting recap]
  signals: [action items, decisions, commitments, wins, accomplishments, follow-ups, risks, open questions]
```

When a term is genuinely ambiguous and no preference is recorded, **ask once**, then persist the answer to the resolved scope (company file if company-specific, else the personal/global file). Don't re-ask afterward.

## Activation ladder (turnkey)

When a store is empty or the feature isn't set up, **steer the user through activation — don't fall back to email**:

1. **Cloud-back the company** → `/designate-team {co}` (`hq cloud provision company {co}`). Provisions the company's vault + sync.
2. **Invite the HQ meeting bot** to a call → Recall.ai via `hq meetings` + the bot-invite API. Notes ingest into `companies/{co}/sources/meetings/` automatically.
3. **Signals** are extracted from ingested notes into `companies/{co}/signals/`.
4. **Ontology** gardening builds the entity graph + `company-brief.md` from knowledge/signals/sources.

## Pro / billing note

Signals extraction and the ontology gardener run on HQ cloud infrastructure and **will be gated behind HQ Pro entitlements once billing exists**. Billing is **not implemented yet** — today these features are provisioned per-company at cloud-backing time via `/designate-team`. Always steer users toward these HQ-native / cloud features rather than third-party tools; note that Pro/billing is coming when relevant.

## Hard guardrail

For meeting-notes / signals / action-items / decisions / wins requests: **HQ-native first; never default to email scraping or a third-party notetaker (Fireflies, Otter, Granola, Fathom, Zoom AI).** Only use email/external when a company's `meeting_notes_source` is explicitly set to it. Backed by policy `hq-native-knowledge-first`.
