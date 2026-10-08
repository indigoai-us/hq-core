---
type: reference
domain: [operations, engineering]
status: canonical
tags: [quick-reference, directory-structure, commands, workers, knowledge-bases]
relates_to: [knowledge/public/hq-core/hq-product-model.md, knowledge/public/hq-core/hq-cli-reference.md]
---

# HQ Quick Reference

## Product surfaces

HQ is the folder plus the `hq` CLI, the desktop app, the console
(hq.computer), bots and agents, chat-app connectors, deploy, and cloud sync.
Map and "which surface for which task": [hq-product-model.md](hq-product-model.md).

| Topic | Reference |
|---|---|
| Every `hq` command (generated) | [hq-cli-reference.md](hq-cli-reference.md) |
| Sync, vaults, company lifecycle | [hq-sync-model.md](hq-sync-model.md) |
| Bots and agents | [agents-and-bots.md](agents-and-bots.md), [external-agents-mcp.md](external-agents-mcp.md) |
| Console pages | [hq-console.md](hq-console.md) |
| Plans and billing | [plans-and-pricing.md](plans-and-pricing.md) |
| Desktop app | [hq-desktop-app.md](hq-desktop-app.md) |
| Deploy | [deploy SKILL.md](../../../../.claude/skills/deploy/SKILL.md) |

## Directory Structure

```
HQ/
├── .claude/commands/   # Slash commands
├── AGENTS.md           # Runtime entrypoint (symlink to .claude/CLAUDE.md)
├── companies/          # Company-scoped resources (registry: companies/manifest.yaml)
│   └── {co}/
│       ├── knowledge/  # Plain company directory, synced through its vault
│       ├── policies/   # Standing operational rules
│       ├── repos/      # Symlinks → repos/{pub|priv}/
│       ├── settings/   # Credentials & config
│       ├── workers/    # Company-scoped workers
│       ├── data/       # Exports, reports
│       └── board.json  # OKR board
├── core/               # System tree (canonical, shipped with HQ)
│   ├── hooks/          # Always-on system hooks (loaded first)
│   ├── docs/hq/        # Public HQ docs (README, CHANGELOG, MIGRATION, USER-GUIDE)
│   ├── knowledge/
│   │   ├── public/     # Bundled real directories tracked by hq-core
│   │   └── private/    # Private real directories when configured
│   ├── policies/       # Cross-cutting + command-scoped policies
│   ├── settings/       # Orchestrator config
│   ├── skills/         # Core skills (surface as /<skill>)
│   └── workers/
│       └── public/     # Shareable workers (dev-team, content-*, social-*, gardener-*, gemini-*, etc.)
├── personal/           # User-personal overlay (mirrors core/ shape)
│   ├── hooks/          # Always-on user-global hooks (loaded AFTER core/hooks)
│   ├── projects/       # Personal/HQ project PRDs and brainstorms
│   ├── knowledge/      # Read directly from personal/ (no core/ mirror)
│   ├── policies/       # Read directly by the policy trigger hook (no core/ mirror)
│   ├── settings/       # Read directly from personal/ (no core/ mirror)
│   ├── skills/         # Surface as /<skill> with (project:personal) tag
│   └── workers/        # Read directly from personal/ (no core/ mirror)
├── repos/
│   ├── public/         # Open-source code repos
│   └── private/        # Private code repos
└── workspace/
    ├── checkpoints/    # Session saves
    ├── orchestrator/   # Ralph loop workflow state
    ├── reports/        # Generated reports
    └── threads/        # Session threads + handoff.json
```

**Personal overlay semantics.** `personal/` mirrors the shape of `core/` but is user-personal authoring space. The old reindex symlink mirror into `core/` was **retired** — `personal/{knowledge,policies,settings,workers}` are now read DIRECTLY from `personal/` by the code that consumes each (the policy trigger hook, the workers-registry generator, the session/knowledge readers), and reindex prunes any leftover mirror symlinks:

| Subdir | Runtime behavior |
|---|---|
| `personal/hooks/<event>/*.sh` | **Loaded as a separate ordered layer** — runs after `core/hooks/<event>/` and before `core/packages/*/hooks/<event>/` |
| `personal/skills/<skill>/SKILL.md` | Surfaces as `/<skill>` — same flat command name as a core skill. Claude Code's `.claude/commands/<subdir>/<name>.md` surfacing puts the subdirectory in the command *description* (`(project:personal)`), not the command name. Collisions with a core skill of the same name are won by whichever ordering Claude Code resolves first; rename your personal skill to disambiguate. |
| `personal/knowledge/<entry>` | Read directly from `personal/knowledge/` (no `core/` mirror) — loads alongside core |
| `personal/policies/<entry>` | Read directly by the policy trigger hook (no `core/policies/` mirror) — loads as global; NOT a separate precedence layer |
| `personal/workers/<entry>` | Walked directly by the workers-registry generator (no `core/workers/` mirror) — surfaces as a worker |
| `personal/settings/<entry>` | Read directly from `personal/settings/` (no `core/settings/` mirror) |

Collision rule: with the mirror retired there is no link path to collide on. Both the personal and the core copy are read; a consumer that dedups by identity resolves same-id twins with personal first (e.g. the policy trigger hook scans `personal/policies/` ahead of `core/policies/`, so an operator's global rule wins over a same-id core copy).

## Companies

Companies differ per install. Read `companies/manifest.yaml` for the list of
companies on this machine and their cloud state (`cloud_uid` when
cloud-backed). Each company's workers, repos, knowledge, and policies live
under `companies/{co}/`, which follows `companies/_template/`.

## Workers

**Public (`core/workers/public/`):** frontend-designer, qa-tester, security-scanner, pretty-mermaid, site-builder, knowledge-tagger, exec-summary, accessibility-auditor, performance-benchmarker

**Dev Team (17):** `core/workers/public/dev-team/`
project-manager, task-executor, architect, backend-dev, database-dev, frontend-dev, infra-dev, motion-designer, code-reviewer, knowledge-curator, product-planner, dev-qa-tester, codex-engine, codex-coder, codex-reviewer, codex-debugger, reality-checker

**Content Team (5):** `core/workers/public/content-*/`
content-brand, content-sales, content-product, content-legal, content-shared

**Social Team (5):** `core/workers/public/social-*/`
social-shared, social-strategist, social-reviewer, social-publisher, social-verifier

**Gardener Team (3):** `core/workers/public/gardener-team/`
garden-scout, garden-auditor, garden-curator

**Gemini Team (3):** `core/workers/public/gemini-*/`
(gemini-coder, gemini-reviewer, gemini-frontend — install via @indigoai-us/hq-pack-gemini)

**Company Workers:** Located at `companies/{co}/workers/`. See manifest.yaml for full list per company.

## Commands

Slash commands live in `.claude/commands/` and `.claude/skills/`; packs and
companies add more. The list below is the common set, not a full inventory.

**Session:** `/startwork`, `/reanchor`, `/checkpoint`, `/handoff`, `/recover-session`, `/remember`, `/learn`
**Handoff:** `/delegate <recipient> [project]` — transfer a project to a person or fleet agent: vault grants (verified), branch push, secrets by name, board + work-mesh reassignment, and a self-pulling pickup DM (no `/hq-sync` needed on their side). Skill: `.claude/skills/delegate/SKILL.md`; manifest spec: `core/knowledge/public/hq-core/delegation-bundle-spec.md`.
**Workers:** `/run`, `/newworker`
**Projects:** `/prd`, `/run-project`, `/execute-task`, `/understand-project`, `/idea`, `/goals`, `/dashboard`, `/tdd`, `/quality-gate`
**System:** `/cleanup`, `/garden`, `/search`, `/search-reindex`, `/harness-audit`, `/model-route`, `/update-hq`
**Company:** `/newcompany`, `/personal-interview`, `/onboard`, `/new-hire`, `/new-agent`
**HQ services:** `/hq-sync`, `/hq-files`, `/hq-share`, `/hq-secrets`, `/hq-integrations`, `/dm`
**Ship:** `/pr` (pull request operations), `/deploy` (publish an artifact; there is no `hq deploy` command)

## CLI: `hq mesh` (Work Mesh Live)

Presence and per-turn activity are automatic via hooks + `hq mesh daemon`. Manual verbs only: `task-status`, `blocked`, `note`. See `core/knowledge/public/hq-core/work-mesh-live.md` and `core/skills/work-mesh/`.

| Command | Use |
|---------|-----|
| `hq mesh daemon install\|status\|doctor` | Resident presence + spool flush (replaces pack listen) |
| `hq mesh context reconcile` (`--observation-file`/`--observation-json`) | Resolve company/project (no `--session`) |
| `hq mesh context organize\|correct\|untracked` (`--session` / sessionId arg) | Bind, correct, or mark untracked |
| `hq mesh context default get\|set\|clear` | Device default company |
| `hq mesh session task-status\|blocked\|note\|flush` (`--session-id`) | Discrete Board signals |

## CLI: `hq files` (vault sharing)

Not slash commands — direct CLI surface for HQ vault access control. Skill: `.claude/skills/hq-files/SKILL.md`.

| Command | Use |
|---------|-----|
| `hq files share <prefix>...` | Browser flow — multi-recipient share-session page (no `--with` flag) |
| `hq files share <prefix> --no-open` | Browser flow but print URL instead of launching |
| `hq files share <prefix> --with <email\|grp_*\|@all> --permission <read\|write>` | Direct grant |
| `hq files unshare <prefix> --with <principal>` | Revoke (idempotent) |
| `hq files acl <prefix>` | Inspect ACL + your effective permission |
| `hq access <path-or-query>` | Cannot find or open a file? Reports never-existed / not-synced / no-access (exit 2/0/3), fetches + pins when you have access, otherwise asks the grantor via DM after one confirmation. Skill: `/hq-access`. hq-cli >= 5.109.0 |

Share-session URLs are encrypted single-use 15-minute capabilities — never persist them in commits, threads, or logs. See `core/policies/hq-share-session-urls-are-capabilities.md`.

## CLI: `hq db` (vault databases)

Local SQLite per company (always) + optional remote Postgres-class on **HQ Workforce** ($500/mo per company; internal id `paid-500`). Billing is live. Guide: `core/knowledge/public/hq-core/vault-databases.md`. Requires `@indigoai-us/hq-cli` ≥ 5.62.0.

| Command | Use |
|---------|-----|
| `hq db status --company {co}` | Ensure local `~/.hq/db/{co}/vault.db` (WAL); report schema version |
| `hq db sql --company {co} -- 'SELECT …'` | Query local DB (read-only default; `--write` for mutations) |
| `hq db migrate --company {co} --hq-root {HQ}` | Apply `companies/{co}/db/migrations/*.sql` |
| `hq db provision --company {co}` | Remote binding — **HQ Workforce plan only** |
| `hq db usage --company {co} --app {app}` | App database usage, included amounts, ceiling and estimated charge |
| `hq db sql --company {co} --app {app} -- '…'` | SQL against an app's database (read-only unless `--write`) |
| `hq db dump --company {co} --app {app}` | Export an app's database to a SQL file |
| `hq db destroy --company {co} --app {app}` | Delete an app's database now (owner or admin, typed confirmation) |
| `hq db sql --company {co} --remote -- '…'` | Flag exists but always fails today (no remote executor wired); use local SQL |

App databases (`database: true` on a deploy, `@hq/db`, `db/migrations/`): Team plan, $10 a month per app with 250k DPU and 1 GB included, read-only at 4x, 30-day retention after delete. Details: `app-databases.md`.

Migrations are vault **text**; binary `.db` files stay machine-local (never under `companies/`). Never print connection strings. Local and remote are not auto-replicated in v1.

## CLI: `hq dm` (direct messages)

Full messaging: DMs, group messages, channels, and threads, in the HQ Desktop App (macOS and Windows) or from a session. Skill: `.claude/skills/dm/SKILL.md` (`/dm`).

| Command | Use |
|---------|-----|
| `hq dm <recipient-or-channel> "<message>"` | Send to a person (email, `prs_*`), bot, or channel |
| `hq dm <r> "<m>" --prompt "<ctx>"` | Attach agent context — recipient gets a one-click "Copy prompt" action |
| `hq dm <r> "<m>" --details "<text>"` / `--details-file <path>` | Longer text shown in an "Open details" view |
| `hq dm <r> "<m>" --at <iso>` / `--in <30s\|10m\|2h\|1d>` | Schedule delivery (store-and-forward) |
| `hq dm inbox` | Recent incoming messages |
| `hq dm thread <person>` (alias `read`) | Two-way conversation with a person or bot |
| `hq dm channel <name>` (alias `history`) | Recent messages in a channel or group DM; `hq channels` lists them |
| `hq dm requests` / `accept` / `decline` / `block` | Connection requests from people outside your companies |

DM your own email for a note-to-self or reminder. Never put secrets in a DM (stored server-side).

## Command ↔ Skill Shapes

Every command exists as `.claude/commands/{name}.md` (the slash-command entry point) and most have a paired `.claude/skills/{name}/SKILL.md` (the Skill-tool canonical logic). Two valid shapes:

**Consolidated (default for new commands)** — `.md` is a ~20-line delegator stub, `SKILL.md` holds the canonical logic. One source of truth, no drift. Converted pairs (Phase 3.1 audit): `search`, `audit-log`, `brainstorm`, `startwork`, `plan`, `handoff`, `learn`, `execute-task`.

**Thin-router split (only one)** — `run-project`. The `.md` is the canonical docs/flags/examples source (622 lines). The `SKILL.md` is a ~66-line bash wrapper that execs `core/scripts/run-project.sh`. They stay forked because one is human-facing documentation and the other is a dispatch shim — different jobs, neither redundant.

**Intentional exceptions (metadata stubs, no SKILL.md)** — `review`, `investigate`, `retro`, `document-release`, `review-plan`. These are frontmatter-only commands that dispatch prompts; no skill logic to split.

**Rule for new commands:** start with the consolidated shape — write the canonical logic in `SKILL.md`, leave `.md` as a stub copying `.claude/commands/startwork.md`'s shape (frontmatter → H1 → intro → `## Steps` → `## After`). Only fork if you have a genuine thin-router reason like `run-project`.

## Pricing and Billing

What HQ costs and how billing works: `core/knowledge/public/hq-core/pricing-and-billing.md`. Numbers: `core/knowledge/public/hq-core/pricing.json` (copy of the HQ API pricing endpoint (`GET /v1/pricing` on the HQ API base, default https://hqapi.hq.computer)). Quote only from those or the endpoint (policy `hq-pricing-source-of-truth`).

## Knowledge Bases

**Public** (`core/knowledge/public/`): Ralph, ai-security-framework, agent-browser, curious-minds, dev-team, hq-core, loom, projects, workers. Optional packs (install via `hq install @indigoai-us/hq-pack-*`) add: design-styles, design-quality, gemini-cli.

**Private** (`core/knowledge/private/`): linear

**Company-level** (`companies/{co}/knowledge/`): one per company; see `companies/manifest.yaml`.

## Policies

Standing operational rules per company. Location: `companies/{co}/policies/*.md`
Cross-cutting rules: `core/policies/*.md`
Spec: `core/knowledge/public/hq-core/policies-spec.md`. Template: `companies/_template/policies/example-policy.md`
