---
name: meeting-notes
description: Read a company's HQ-native meeting notes (recordings/transcripts/recaps captured by the HQ meeting bot). Use whenever the user asks for meeting notes, standup notes, a call recap, "what was said in {meeting}", or the latest notes for a company. Multi-tenant — resolves the active company and reads ITS native store at companies/{co}/sources/meetings/. HQ-native first; never defaults to email or third-party notetakers. If the store is empty or the feature isn't activated, surfaces turnkey activation steps instead of scraping email.
allowed-tools: Bash, Read, Grep, Glob
---

# /meeting-notes — Read HQ-native meeting notes

Meeting notes are an **HQ-native, per-company store** populated by the HQ meeting bot (Recall.ai). This skill is the generic, multi-company reader — it works for **every** company, not just ones that ship their own namespaced meeting flows.

**Canonical store:** `companies/{co}/sources/meetings/{uuid}.md` (+ `{uuid}.raw.json`), date index `companies/{co}/sources/_index/{YYYY-MM-DD}.json`.
**Generic CLI reader:** `hq meetings list|get|notes|transcript|search --company {slug}`.
**Mechanism/schema detail (read once if needed):** `core/knowledge/public/hq-core/native-knowledge-stores.md`.

## Hard rule

HQ-native first. **Never** default to email search or a third-party notetaker (Fireflies, Otter, Granola, Fathom, Zoom AI) to answer a "meeting notes" request. Only use email/external if the company's preference is *explicitly* set to it (see resolution below). If the native store is empty or unactivated, **steer the user to activate it** — do not silently fall back to scraping inboxes.

## Resolution (run every time)

1. **Resolve company.** `bash core/scripts/hq-session.sh get company_slug`. If unset, infer from cwd / `companies/manifest.yaml`; if still ambiguous, ask the user which company.
2. **Load preference (company over global, per-field merge).** Read, if present:
   - `companies/{co}/settings/knowledge/preferences.yaml` (override)
   - `personal/settings/knowledge-preferences.yaml` (global default)
   - Built-in default when neither sets it: `meeting_notes_source: hq-native`, `notetaker: recall`.
3. **Branch on `meeting_notes_source`:**
   - `hq-native` (default) → read the native store (below).
   - `email` / `external` → use that source per the user's stated preference; otherwise honor native.
4. **Term aliases.** Treat "standup notes", "recap", "call notes", "meeting recap" (plus any `aliases.meeting_notes` in the preference file) as meeting-notes requests.

## Reading the native store (`hq-native`)

Prefer the CLI; fall back to direct reads.

- **Latest / list:** `hq meetings list --company {co}` (most recent meetings, titles, dates, bot status). For a specific one: `hq meetings notes --company {co} --id {uuid}` or `hq meetings transcript ...`.
- **Direct fallback:** newest files in `companies/{co}/sources/meetings/` (sort by `scheduled_start_time`/`ingested_at` in frontmatter, or use the `_index/{date}.json`). Each `.md` carries frontmatter (`title`, `origin: recall.ai`, `meeting_platform`, `bot_status`, `scheduled_start_time`) and a `## Transcript` body.
- Pick the meeting the user means (latest, by title, by date). Summarize from the transcript/notes; quote sparingly.

## Empty / not-activated branch

If `hq meetings list` returns nothing and `companies/{co}/sources/meetings/` is empty or absent, the company hasn't activated HQ meeting capture. Do **not** scrape email. Instead surface the turnkey ladder (full version in the knowledge doc + USER-GUIDE):

1. Make the company cloud-backed → `/designate-team {co}` (`hq cloud provision company {co}`).
2. Invite the HQ meeting bot to the call (Recall.ai via `hq meetings` + bot-invite API).
3. Notes ingest automatically into `companies/{co}/sources/meetings/`; read them here next time.
4. Note: signals + ontology follow once provisioned; some of this runs on HQ cloud and **will require HQ Pro once billing ships (not yet — provisioned per-company today via `/designate-team`).**

Then offer: if they want "meeting notes" to mean their **email** for this company instead, set `meeting_notes_source: email` in `companies/{co}/settings/knowledge/preferences.yaml`.

## Ambiguity → ask once, then persist

If the term is genuinely ambiguous (e.g. the user has both a populated native store and a history of email recaps) and no preference is recorded, ask **once** which source they mean, then write the answer to the resolved scope (`companies/{co}/settings/knowledge/preferences.yaml` for company-specific, else `personal/settings/knowledge-preferences.yaml`). Don't re-ask afterward.

## Output

Quiet, plain summary of the notes the user asked for. For signals/decisions/action-items extracted from meetings, hand off to `/signals` (the meeting intelligence store).
