---
id: hq-vault-db-no-print-connection-strings
title: Never print vault database connection strings
scope: core
trigger: Implementing or reviewing hq db, remote provision, SecretBinding, or logging around databases
enforcement: hard
public: true
when: (hq && db) || (vault && database) || database_url || postgres || postgresql || (db && provision) || better-sqlite
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
tags: [security, hq-cli, vault, databases, secrets]
created: 2026-07-12
provenance: vault-databases-feature
---

## Rule

ALWAYS:

- Keep remote DB connection material only in HQ Secrets / Secrets Manager / runtime SecretBinding injection.
- Company-scope every `hq db` command and control-plane route from identity + membership + resolved `--company`.
- Keep local binary DB files at `~/.hq/db/{co}/vault.db` — never under `companies/` (not vault-synced, not git-tracked).

NEVER:

- Print, log, or return `postgres://` / `postgresql://` connection strings in CLI stdout/stderr, API JSON, agent transcripts, commits, or chat.
- Open another company's local DB path by free-text override without an explicit dangerous flag (default deny).
- Treat local SQLite and remote Postgres as auto-replicated in v1.
- Hard-code ad-hoc `.db` paths in skills when `hq db` is the company surface.

## Rationale

Category-1 tenant isolation and secret hygiene. Connection strings are credentials. Local binary state fights the text-first vault sync model — keep it machine-local.
