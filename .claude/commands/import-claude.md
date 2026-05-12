---
description: Scan the machine for Claude artifacts (sessions, MCPs, commands, skills, hooks, policies, knowledge, repos, plans) and guide a selective import into HQ
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, Task
argument-hint: "[--dry-run] [--scope=<dir>] [--ontology-only] [--cluster-min-skills=<N>]"
visibility: public
---

# /import-claude — Adopt Prior Claude Footprint into HQ

Discover Claude-related artifacts scattered across disk, classify them, and walk a guided import into HQ — hydrating the skeleton that `/setup` scaffolds.

**Args:** $ARGUMENTS

## When to run

- After `/setup` on a fresh HQ install, to pull existing commands/skills/policies/MCP configs/knowledge into the new tree.
- Anytime to **dry-run** a discovery pass (`--dry-run`) without touching state.
- To **seed company knowledge from plan history** (`--ontology-only`) without importing artifacts.

## What it does

1. **Scans** an allowlist of safe parent dirs (`~/.claude/`, `~/Documents`, `~/code`, `~/dev`, `~/Projects`, `~/src`, `~/work`, `~/github`, `~/repos`) plus any `--scope=` flags.
2. **Catalogs** findings into `workspace/imports/{scan_id}/report.json` with per-category entries (commands, skills, hooks, policies, CLAUDE.md, settings fragments, MCP servers, knowledge dirs, claude-bearing repos, plans).
3. **Infers ontology** from prior `/plan` outputs — proposes companies, recurring workflows, tool preferences. Seeds `companies/{co}/knowledge/context.md` on approval.
4. **Guides import** via `AskUserQuestion` — per-category triage, per-item decide (keep / merge / skip / rename / assign-to-company), credential-redaction prompts, per-repo adoption prompts.
5. **Synthesizes workers** when discovered skills + knowledge form a cluster (inline-invokes `/newworker`).
6. **Creates missing companies** inline via `/newcompany {slug}` when an artifact implies an unknown company.
7. **Registers** everything in `companies/manifest.yaml`, `core/workers/registry.yaml`, `core/modules/modules.yaml` (no null fields).
8. **Reindexes** with `qmd update` and writes `workspace/imports/{scan_id}/summary.md`.

## Safety

- **Denylist** skips `node_modules`, `.git/objects`, `~/.claude/projects/` (6+GB session transcripts), `~/Library` (except desktop config), HQ root itself.
- **Credential redaction** happens before any preview is shown to the user or written to report.json (`sk-…`, `ghp_…`, `xox*-…`, `AKIA…`, `Bearer …`, `AIza…`, `apiKey*`, env `*_KEY/_TOKEN/_SECRET`).
- **Dry-run** (`--dry-run`) halts after the catalog is written — no imports, no registry writes.
- **Idempotent** — re-runs skip already-imported items via `workspace/imports/index.json` sha256 hash store.
- **Refuses** in plan mode, inside another run's owned repo, or when scope resolves inside HQ itself (self-protection via `realpath`).

## Invocation

Skill lives at `.claude/skills/import-claude/SKILL.md` — delegates orchestration there. Run with no args for default allowlist + interactive flow. See skill for full phase specification.

## Flags

| Flag | Effect |
|---|---|
| `--dry-run` | Scan + catalog only; no imports, no registry writes |
| `--scope=<dir>` | Add a custom parent dir to scan (repeatable) |
| `--ontology-only` | Run scan + ontology inference; skip artifact import |
| `--cluster-min-skills=<N>` | Minimum skills to trigger worker-synthesis cluster detection (default: 2) |

## Post-run

- Suggests `/cleanup --audit` to validate nothing landed in a broken state.
- Emits a `/learn` entry summarizing what was imported.
