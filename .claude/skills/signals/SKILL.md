---
name: signals
description: Read a company's HQ-native "signals" — meeting/comms intelligence extracted into companies/{co}/signals/. Use when the user asks for action items, decisions, commitments, risks, open questions, wins/accomplishments, key points, or "what did {person} commit to / decide / flag". Multi-tenant — resolves the active company and reads ITS signals store. Generic reader so every company gets first-class signals, not only ones that ship their own namespaced signals skill. Read-only; if the store is empty/unactivated, surfaces turnkey activation instead of guessing.
allowed-tools: Bash, Read, Grep, Glob
---

# /signals — Read HQ-native signals (decisions, action items, wins, risks…)

Signals are an **HQ-native, per-company store** of meeting/comms intelligence — discrete, cited items extracted from meeting notes and other sources. This is the generic, multi-company reader. A company may also ship its own namespaced interface (e.g. `{co}:signals`, `{co}:action-items`) over the *same* store; this skill serves **all** companies.

**Canonical store:** `companies/{co}/signals/{type}/{sha256}.md`, daily index `companies/{co}/signals/_index/{YYYY-MM-DD}.json`.
**Mechanism/schema detail (read once if needed):** `core/knowledge/public/hq-core/native-knowledge-stores.md`.

## Signal types (8)

| Type | Use it for |
|---|---|
| `action_item` | tasks/to-dos assigned to an owner |
| `commitment` | explicit promises a participant made |
| `decision` | decisions reached |
| `risk` | blockers, concerns, threats raised |
| `question` | open questions, unresolved |
| `key_point` | notable discussion points |
| `participant_contribution` | what a specific person contributed |
| `summary` | per-meeting summaries |

"Wins / accomplishments" → read `decision` + `key_point` (and `summary`). "Follow-ups" → `action_item` + `commitment`.

Each signal `.md` has frontmatter: `canonical_content` (one-line normalized statement), `citations[]` (`location` timestamp, `source_ref`, verbatim `text`), `entity_refs[]` (`person/…`, `project/…`), `source_ref`, `type`, `signal_id`.

## Hard rule

HQ-native first. Read the signals store to answer these asks. **Never** default to scraping email or a third-party notetaker. If the store is empty/unactivated, steer the user to activation (below) — don't fabricate or guess.

## Resolution (run every time)

1. **Resolve company.** `bash core/scripts/hq-session.sh get company_slug`; else infer from cwd/manifest; else ask.
2. **Load preference (company over global).** Read `companies/{co}/settings/knowledge/preferences.yaml` then `personal/settings/knowledge-preferences.yaml`. Built-in default: `signals_enabled: true`. If a company has `signals_enabled: false`, tell the user it's disabled and offer to enable it (flip the flag) rather than reading.
3. **Classify the ask** via the type table (and any `aliases.signals` in the preference file): action items → `action_item`, "what did we decide" → `decision`, wins → `decision`+`key_point`, risks → `risk`, open questions → `question`, "{person} committed" → `commitment` filtered by `entity_refs` person.

## Reading

- **Recency:** use the latest `_index/{date}.json` files (newest dates first) to find recently-written signals; or list newest files under `companies/{co}/signals/{type}/`.
- **Filter:** by type (dir), by owner/person (`entity_refs` contains `person/{slug}`), by project (`project/{slug}`), by date.
- **Present:** group by type; show `canonical_content` per item with its owner/source; cite the meeting (`source_ref`) and timestamp from `citations[]` when useful. For mutable action-item tracking with status lifecycle, note that a company may ship a dedicated namespaced tracker (e.g. `{co}:action-items`); this skill is read-only.

## Empty / not-activated branch

If `companies/{co}/signals/` is empty or absent, signals haven't been extracted for this company yet. Surface the turnkey ladder (full version in the knowledge doc + USER-GUIDE):

1. `/designate-team {co}` to make the company cloud-backed.
2. Capture meetings with the HQ meeting bot (`/meeting-notes` covers this) → notes ingest.
3. Signals are extracted from ingested notes into `companies/{co}/signals/` automatically once provisioned.
4. Note: signals extraction runs on HQ cloud and **will require HQ Pro once billing ships (not yet — provisioned per-company today via `/designate-team`).**

## Output

Quiet, plain, grouped summary of the signals the user asked for — decisions, action items, wins, risks, etc. — with light citations.
