---
type: reference
domain: [operations, engineering]
status: canonical
tags: [quick-reference, directory-structure, commands, workers, knowledge-bases]
relates_to: []
---

# HQ Quick Reference

## Directory Structure

```
HQ/
├── .claude/commands/   # Slash commands (44)
├── AGENTS.md           # Runtime entrypoint (symlink to .claude/CLAUDE.md)
├── companies/          # Company-scoped resources (14 companies)
│   └── {co}/
│       ├── knowledge/  # Embedded git repo (company knowledge)
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
│   │   ├── public/     # Symlinks → repos/public/knowledge-*
│   │   └── private/    # Symlinks → repos/private/knowledge-*
│   ├── policies/       # Cross-cutting + command-scoped policies
│   ├── settings/       # Orchestrator config
│   ├── skills/         # Core skills (surface as /<skill>)
│   └── workers/
│       └── public/     # Shareable workers (dev-team, content-*, social-*, gardener-*, gemini-*, etc.)
├── personal/           # User-personal overlay (mirrors core/ shape)
│   ├── hooks/          # Always-on user-global hooks (loaded AFTER core/hooks)
│   ├── projects/       # Personal/HQ project PRDs and brainstorms
│   ├── knowledge/      # Symlinked into core/knowledge/ by reindex
│   ├── policies/       # Symlinked into core/policies/ by reindex
│   ├── settings/       # Symlinked into core/settings/ by reindex
│   ├── skills/         # Surface as /<skill> with (project:personal) tag
│   └── workers/        # Symlinked into core/workers/ by reindex
├── repos/
│   ├── public/         # Open-source repos
│   └── private/        # Private repos
└── workspace/
    ├── checkpoints/    # Session saves
    ├── orchestrator/   # Ralph loop workflow state
    ├── reports/        # Generated reports
    ├── social-drafts/  # Social content pipeline
    └── threads/        # Session threads + handoff.json
```

**Personal overlay semantics.** `personal/` mirrors the shape of `core/` but is user-personal authoring space. Master-sync (a Stop/PostToolUse hook in `.claude/hooks/reindex.sh`) keeps the two in sync:

| Subdir | Runtime behavior |
|---|---|
| `personal/hooks/<event>/*.sh` | **Loaded as a separate ordered layer** — runs after `core/hooks/<event>/` and before `core/packages/*/hooks/<event>/` |
| `personal/skills/<skill>/SKILL.md` | Surfaces as `/<skill>` — same flat command name as a core skill. Claude Code's `.claude/commands/<subdir>/<name>.md` surfacing puts the subdirectory in the command *description* (`(project:personal)`), not the command name. Collisions with a core skill of the same name are won by whichever ordering Claude Code resolves first; rename your personal skill to disambiguate. |
| `personal/knowledge/<entry>` | Symlinked into `core/knowledge/<entry>` — appears inside core |
| `personal/policies/<entry>` | Symlinked into `core/policies/<entry>` — appears inside core; NOT a separate precedence layer |
| `personal/workers/<entry>` | Symlinked into `core/workers/<entry>` — appears inside core |
| `personal/settings/<entry>` | Symlinked into `core/settings/<entry>` — appears inside core |

Collision rule: if a real file/dir already sits at the link path, reindex logs and skips — personal never silently overwrites core.

## Companies (14)

| Company | Workers | Key Resources |
|---------|---------|---------------|
| {company} | cfo, analyst, infobip-admin, gtm, qa, deploy | Stripe, Gusto, Deel, QB, Shopify, Linear (acme-recover) |
| {company} | cmo | AWS (Route 53), Linear, LinkedIn, Loops |
| personal | x-user, invoices, social-council | Slack, Gmail, LinkedIn, X |
| acmework | site-builder, research-agent | Stripe |
| acmestudio | — | Band/music |
| acme-haven | — | Artist site + admin |
| acme-mgmt | — | Artist manager monorepo |
| acmebrands | — | AcmeBrands AI |
| acme-estate | — | Estate platform |
| acmebrand | — | Shopify store |
| acmeflow | — | Expo mobile app |
| acmedom | — | Domain management |
| acme-rebrand | — | GTM/growth |

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

## Commands (44)

**Session:** `/startwork`, `/reanchor`, `/checkpoint`, `/handoff`, `/recover-session`, `/remember`, `/learn`
**Workers:** `/run`, `/newworker`
**Projects:** `/plan`, `/run-project`, `/execute-task`, `/understand-project`, `/idea`, `/goals`, `/dashboard`, `/tdd`, `/quality-gate`
**Content:** `/contentidea`, `/suggestposts`, `/preview-post`, `/post`, `/post-results`, `/social-setup`
**Communication:** `/email`, `/checkemail`, `/imessage`
**Design:** `/generateimage`
**System:** `/cleanup`, `/garden`, `/search`, `/search-reindex`, `/harness-audit`, `/model-route`, `/update-hq`
**Company:** `/newcompany`, `/launch-brand`, `/pb-connect`, `/bootcamp-student`, `/personal-interview`
**Linear:** `/check-linear-acme-recover`, `/{product}-prd`
**Deploy:** `/pr`

## CLI: `hq files` (vault sharing)

Not slash commands — direct CLI surface for HQ vault access control. Skill: `.claude/skills/hq-files/SKILL.md`.

| Command | Use |
|---------|-----|
| `hq files share <prefix>...` | Browser flow — multi-recipient share-session page (no `--with` flag) |
| `hq files share <prefix> --no-open` | Browser flow but print URL instead of launching |
| `hq files share <prefix> --with <email\|grp_*\|@all> --permission <read\|write>` | Direct grant |
| `hq files unshare <prefix> --with <principal>` | Revoke (idempotent) |
| `hq files acl <prefix>` | Inspect ACL + your effective permission |

Share-session URLs are encrypted single-use 15-minute capabilities — never persist them in commits, threads, or logs. See `core/policies/hq-share-session-urls-are-capabilities.md`.

## CLI: `hq db` (vault databases)

Local SQLite per company (always) + optional remote Postgres-class on **HQ Team** ($500/mo). Guide: `core/knowledge/public/hq-core/vault-databases.md`. Requires `@indigoai-us/hq-cli` ≥ 5.62.0.

| Command | Use |
|---------|-----|
| `hq db status --company {co}` | Ensure local `~/.hq/db/{co}/vault.db` (WAL); report schema version |
| `hq db sql --company {co} -- 'SELECT …'` | Query local DB (read-only default; `--write` for mutations) |
| `hq db migrate --company {co} --hq-root {HQ}` | Apply `companies/{co}/db/migrations/*.sql` |
| `hq db provision --company {co}` | Remote binding — **Team plan only** (when control plane live) |

Migrations are vault **text**; binary `.db` files stay machine-local (never under `companies/`). Never print connection strings. Local and remote are not auto-replicated in v1.

## CLI: `hq dm` (direct messages)

Send a person-to-person notification to a teammate's HQ Desktop App. Skill: `.claude/skills/dm/SKILL.md` (`/dm`).

| Command | Use |
|---------|-----|
| `hq dm <email\|prs_*> "<message>"` | Plain DM — recipient gets an HQ Desktop App notification |
| `hq dm <r> "<m>" --prompt "<ctx>"` | Attach agent context — recipient gets a one-click "Copy prompt" action |
| `hq dm <r> "<m>" --details "<text>"` / `--details-file <path>` | Longer text shown in the recipient's "Open details" window |
| `hq dm <r> "<m>" --at <iso>` / `--in <30s\|10m\|2h\|1d>` | Schedule delivery (store-and-forward) |

Receive-only in the app — sending is session/CLI only. You can only DM someone you share an active company with; DM your own email for a note-to-self/reminder. Never put secrets in a DM (stored server-side).

## Command ↔ Skill Shapes

Every command exists as `.claude/commands/{name}.md` (the slash-command entry point) and most have a paired `.claude/skills/{name}/SKILL.md` (the Skill-tool canonical logic). Two valid shapes:

**Consolidated (default for new commands)** — `.md` is a ~20-line delegator stub, `SKILL.md` holds the canonical logic. One source of truth, no drift. Converted pairs (Phase 3.1 audit): `search`, `audit-log`, `brainstorm`, `startwork`, `plan`, `handoff`, `learn`, `execute-task`.

**Thin-router split (only one)** — `run-project`. The `.md` is the canonical docs/flags/examples source (622 lines). The `SKILL.md` is a ~66-line bash wrapper that execs `core/scripts/run-project.sh`. They stay forked because one is human-facing documentation and the other is a dispatch shim — different jobs, neither redundant.

**Intentional exceptions (metadata stubs, no SKILL.md)** — `review`, `investigate`, `retro`, `document-release`, `review-plan`. These are frontmatter-only commands that dispatch prompts; no skill logic to split.

**Rule for new commands:** start with the consolidated shape — write the canonical logic in `SKILL.md`, leave `.md` as a stub copying `.claude/commands/startwork.md`'s shape (frontmatter → H1 → intro → `## Steps` → `## After`). Only fork if you have a genuine thin-router reason like `run-project`.

## Knowledge Bases

**Public** (`core/knowledge/public/`): Ralph, ai-security-framework, agent-browser, curious-minds, dev-team, hq-core, loom, projects, workers. Optional packs (install via `hq install @indigoai-us/hq-pack-*`) add: design-styles, design-quality, gemini-cli.

**Private** (`core/knowledge/private/`): linear

**Company-level** (`companies/{co}/knowledge/`): All 14 companies have embedded git repos.

## Policies

Standing operational rules per company. Location: `companies/{co}/policies/*.md`
Cross-cutting rules: `core/policies/*.md` (47 policies)
Spec: `core/knowledge/public/hq-core/policies-spec.md`. Template: `companies/_template/policies/example-policy.md`
