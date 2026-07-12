---
type: reference
domain: [operations, engineering]
status: canonical
tags: [hq-cli, vault, databases, sqlite, secrets, team-plan]
relates_to:
  - quick-reference.md
  - native-knowledge-stores.md
---

# Vault databases (`hq db`)

Structured storage as a first-class HQ surface: **local SQLite per company** on every machine, and (on **HQ Team**, $500/mo) a **remote Postgres-class** DB provisioned by the platform — secrets never printed.

Markdown / qmd / ontology remain the primary knowledge store. Vault DB is for **relational agent and app state**, not for replacing company knowledge docs.

## Two tiers

| Tier | When | Path / binding |
|------|------|----------------|
| **Local (C1)** | Always — no Team plan required | `~/.hq/db/{company}/vault.db` (WAL). Binary files **outside** the vault tree (not hq-sync’d). |
| **Remote (C2)** | **HQ Team plan only** | Control-plane provision; connection material only in HQ Secrets / SecretBinding. |

Local and remote share the CLI surface but are **not** auto-replicated in v1.

## Jobs that fit

- Agent skills that need small tables (ledgers, caches, registries, inventories)
- Implementation partners standardizing client installs (same migration layout every company)
- Team multi-machine shared operational data (Team remote)
- Deployed apps needing `DATABASE_URL` via **existing SecretBinding** (Team remote)

## Jobs that do **not** fit v1

- Primary company knowledge (use markdown / qmd / ontology)
- Multi-master sync of local `.db` via hq-sync
- Amass-scale analytics warehouses as the default product
- Public multi-tenant DBaaS outside HQ
- Day-one forced migration of every existing Neon project

## Commands

| Command | Purpose |
|---------|---------|
| `hq db status --company {co}` | Ensure local SQLite exists; report path + schema version (never prints remote URLs) |
| `hq db sql --company {co} -- 'SELECT …'` | Query **local** DB (read-only default; `--write` for mutations) |
| `hq db migrate --company {co} --hq-root {HQ}` | Apply vault text migrations |
| `hq db provision --company {co}` | Remote binding (Team plan; live control plane when deployed) |
| `hq db sql --company {co} --remote -- '…'` | Remote SQL via secrets injection (when wired) |

## Paths

| Item | Location |
|------|----------|
| Local DB file | `~/.hq/db/{companySlug}/vault.db` |
| Migrations (vault **text**, reviewable/syncable) | `companies/{companySlug}/db/migrations/*.sql` |
| Platform ledger | `hq_schema_migrations` table inside the local DB |

Never place `*.db` under `companies/` — binary state must not enter vault sync or git.

## Security (category-1)

- **Never print** `postgres://` / connection strings (CLI, API, logs, agent transcripts).
- Company scope from HQ identity + membership + `--company` — not free-text path alone.
- `ATTACH` / path overrides that open another company’s DB are denied.
- Remote provision requires **Team plan**; non-Team gets a clear plan error. Local remains available.

## Skill / implementer contract

**Do:**

```bash
hq db status --company {co}
hq db migrate --company {co} --hq-root {HQ_ROOT}
hq db sql --company {co} -- 'SELECT …'
```

**Do not:** hard-code `~/.hq/db/...` or invent ad-hoc SQLite paths in skills; do not assume laptop rows exist on another machine.

## Customer-shaped journeys (summary)

1. **Solo / learn-by-doing** — local only; install HQ, run status/migrate/sql for agent state.
2. **Implementation partner** — same local conventions for every client; upsell Team remote when multi-machine or deploy injection is needed.
3. **Team admin** — provision remote once; agents use CLI; apps use SecretBinding.

## Related

- Quick reference: `core/knowledge/public/hq-core/quick-reference.md` (CLI: `hq db`)
- Hard policy: never print DB connection strings (core policies)
- CLI package: `@indigoai-us/hq-cli` ≥ 5.62.0
