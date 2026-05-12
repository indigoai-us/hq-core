---
id: hq-command-output-frontmatter-flag-contract
title: Use frontmatter flag + mtime as the contract between piped commands
scope: global
trigger: one HQ command produces an artifact that another command consumes (e.g. /brainstorm → /plan)
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: user-correction
learned_from: "/brainstorm → /plan research handoff: considered a registry or lockfile; chose a boolean `research_persisted: true` flag in brainstorm.md frontmatter + mtime staleness check. Zero new infrastructure, worst-case failure mode is a reused-stale doc (visible, fixable) rather than corrupted state."
---

## Rule

When one HQ command's output feeds another command, ALWAYS use a frontmatter flag + file-mtime staleness check as the handshake contract. Do NOT introduce a registry, lockfile, sidecar JSON, or database entry for this purpose.

Concrete shape:

1. **Producer command** writes a markdown artifact (e.g. `brainstorm.md`) with a YAML frontmatter boolean like `research_persisted: true` plus a timestamped `research_captured_at:` field.
2. **Consumer command** greps/reads the frontmatter, and if the flag is true AND the file mtime is within an acceptable staleness window, trusts the artifact and skips its own equivalent discovery phase. Otherwise it runs fresh.
3. **Contract lives in the two skill files** — no shared schema registry, no third-party coordinator.

NEVER replace this pattern with a heavier mechanism (registry, lockfile, `.handoff.json` sidecar, env var) unless the producer and consumer are in different runtimes or the contract needs multi-consumer fan-out. For single-producer → single-consumer flows inside one HQ runtime, the frontmatter-flag contract is the default.

## Rationale

A registry or lockfile couples two commands through a third file that must be authored, documented, migrated, garbage-collected, and recovered when corrupted. A frontmatter flag on the already-produced artifact has zero new surface area: the producer already writes the file, the consumer already reads it. The boolean flag is self-documenting (it lives in the file it describes). The worst-case soft-failure mode — consumer reuses a stale-but-valid artifact — is immediately visible to the user (they see the date in the frontmatter) and fixable by re-running the producer. A registry's worst-case failure is corrupted coordinator state, which is invisible, harder to diagnose, and can silently desync the two commands.
