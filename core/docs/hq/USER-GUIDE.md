# HQ User Guide

The AI operating system for your company. A shared context layer on top of Claude Code, Cursor, and Codex — syncs knowledge, skills, and capabilities across your team. Scales from solopreneur to enterprise.

## Commands

### Session Management
| Command | What it does |
|---------|--------------|
| `/startwork` | Pick company/project/repo, gather context |
| `/checkpoint` | Save progress to `workspace/checkpoints/` |
| `/handoff` | Prepare handoff for fresh session |
| `/recover-session` | Recover dead sessions that hit context limits |
| `/learn` | Auto-capture learnings from task execution |

### Planning & Projects
| Command | What it does |
|---------|--------------|
| `/brainstorm` | Explore approaches and tradeoffs before committing to a PRD |
| `/plan` | Lightweight plan for a new project |
| `/prd` | Create an execution-ready PRD (`prd.json` + `README.md`) |
| `/deep-plan` | Deep planning with research subagents and tiered interview |
| `/idea` | Capture a project idea on the board without a full PRD |
| `/strategize` | Strategic prioritization — "what should I work on next?" |
| `/goals` | View and manage OKR structure |
| `/run-project` | Execute a PRD via Ralph loop / Codex runtime |
| `/run-pipeline` | Multi-project pipeline orchestrator |
| `/execute-task` | Execute a single PRD story through coordinated workers |
| `/architect` | Surface architectural friction and propose deepening opportunities |
| `/review-plan` | Stress-test a plan or PRD (EXPANSION / HOLD / REDUCTION modes) |

### Quality, Debugging & Review
| Command | What it does |
|---------|--------------|
| `/tdd` | Enforce test-driven development cycle |
| `/quality-gate` | Pre-commit quality checks (typecheck, lint, test, coverage) |
| `/investigate` | Iron Law debugging — root-cause investigation before fixes |
| `/diagnose` | Disciplined diagnosis loop for hard / intermittent bugs |
| `/review` | Review a pull request |
| `/retro` | Project or session retrospective |
| `/document-release` | Post-ship documentation sync |
| `/calibration-report` | Estimation calibration vs. actuals |
| `/track-estimate` | Record an estimate for a task |
| `/finish-estimate` | Close out an estimate with actuals |

### Workers
| Command | What it does |
|---------|--------------|
| `/run` | List workers |
| `/run {worker}` | Show worker's skills |
| `/run {worker} {skill}` | Execute skill |
| `/newworker` | Create new worker |

### Knowledge & Decisions
| Command | What it does |
|---------|--------------|
| `/adr` | Capture an Architectural Decision Record |
| `/out-of-scope` | Record what was deliberately rejected and why |
| `/search` | Search across HQ and indexed repos (qmd-powered) |
| `/garden` | Detect stale, duplicate, inaccurate content |

### Land & Ship
| Command | What it does |
|---------|--------------|
| `/land` | Land a PR — monitor CI, resolve review issues, merge, monitor production |
| `/land-batch` | Triage, review, and sequentially merge multiple open PRs |

### HQ Services & Sync
| Command | What it does |
|---------|--------------|
| `/hq-login` | Sign in to HQ Cognito (browser flow) |
| `/hq-logout` | Clear local Cognito session |
| `/hq-whoami` | Show current HQ identity + token expiry |
| `/hq-sync` | Run a full HQ sync across cloud-backed companies |
| `/resolve-conflicts` | Walk through HQ Sync conflicts interactively |

### HQ CLI: Files (vault sharing)

These are CLI commands (not slash commands) — direct surface for HQ vault access control. Full reference: `.claude/skills/hq-files/SKILL.md`.

| Command | What it does |
|---------|--------------|
| `hq files share <prefix>...` | **Browser flow** — opens a share-session page where you batch-pick recipients (members, groups, "Share with All") with per-recipient read/write. Add `--no-open` to print the URL only. |
| `hq files share <prefix> --with <email\|grp_*\|@all> --permission <read\|write>` | **Direct grant** — single recipient (or `@all` for company-wide) without leaving the terminal |
| `hq files unshare <prefix> --with <principal>` | Revoke a grant (idempotent — exits 0 if already absent) |
| `hq files acl <prefix>` | Show ACL entries, creator, and your effective permission |

Share-session URLs are encrypted single-use 15-minute capabilities — never paste them into commits, threads, or logs. See policy `core/policies/hq-share-session-urls-are-capabilities.md`.

### HQ CLI: Direct messages (`hq dm`)

Send a person-to-person notification to a teammate. They receive it in their HQ Sync menubar app. Full reference: `.claude/skills/dm/SKILL.md` (`/dm`).

| Command | What it does |
|---------|--------------|
| `hq dm <email\|prs_*> "<message>"` | Send a DM — recipient gets a macOS notification in HQ Sync |
| `hq dm <r> "<m>" --prompt "<context>"` | Attach agent context — recipient gets a one-click **Copy prompt** action to paste into their own agent |
| `hq dm <r> "<m>" --details "<text>"` (or `--details-file <path>`) | Longer text shown in the recipient's **Open details** window |
| `hq dm <r> "<m>" --at <iso>` / `--in <30s\|10m\|2h\|1d>` | Schedule delivery (store-and-forward — arrives even if you're offline at that time) |

Receiving is handled by the **HQ Sync menubar app** (it's receive-only — there's no send UI; sending is session/CLI only). You can only DM someone you share an active company with; DM your own email for a note-to-self or reminder. Never put secrets in a DM body/prompt/details — they're stored server-side.

### Company & Infrastructure
| Command | What it does |
|---------|--------------|
| `/newcompany` | Scaffold new company with full infrastructure |
| `/designate-team` | Mark a company directory as cloud-backed |
| `/sync-registry` | Regenerate a company's resource registry index |
| `/discover` | Pull a repo into HQ and synthesize structured knowledge |
| `/import-claude` | Scan the machine for Claude artifacts and import into HQ |
| `/setup` | Interactive setup wizard for HQ Starter Kit |
| `/update-hq` | Upgrade HQ from latest hq-core release |
| `/convert-codex` | Additive conversion so Codex has first-class AGENTS.md guidance |
| `/tutorial` | Interactive hands-on tutorial on HQ principles and workflow |
| `/harness-audit` | Score HQ setup quality across categories |
| `/cleanup` | Audit and clean HQ to enforce current policies |

### Misc
| Command | What it does |
|---------|--------------|
| `/personal-interview` | Deep interview to populate profile / voice |
| `/ascii-graphic` | Generate ASCII block-art banners for posts and OG images |

## Workers

```
/run                                   # see all
/run frontend-designer
/run frontend-designer build
/run content-brand "tone analysis"
```

**Standalone public workers** (`core/workers/public/`):

| Worker | Purpose |
|--------|---------|
| frontend-designer | UI generation |
| qa-tester | Automated website testing (Playwright) |
| security-scanner | Security scanning |
| pretty-mermaid | Mermaid diagram generation |
| site-builder | Static site generation |
| knowledge-tagger | Knowledge classification |
| exec-summary | Executive summary generation |
| accessibility-auditor | Accessibility checks |
| performance-benchmarker | Performance analysis |
| ascii-artist | ASCII block-art generation |
| paper-designer | Document / paper layout |

**Dev Team (20)** — `core/workers/public/dev-team/`:
project-manager, task-executor, architect, backend-dev, database-dev, frontend-dev, infra-dev, motion-designer, code-reviewer, knowledge-curator, product-planner, qa-tester, reality-checker, context-manager, codex-engine, codex-coder, codex-reviewer, codex-debugger, gemini-coder, gemini-reviewer

**Content Team (5)** — `core/workers/public/content-*/`:
content-brand, content-sales, content-product, content-legal, content-shared (library)

**Social Team (5)** — `core/workers/public/social-*/`:
social-shared (library), social-strategist, social-reviewer, social-publisher, social-verifier

**Gardener Team (3)** — `core/workers/public/gardener-team/`:
garden-scout, garden-auditor, garden-curator

**Company Workers** (`companies/{co}/workers/`):

Each company can scaffold its own private workers via `/newworker`. They live under `companies/{co}/workers/` and stay isolated from other companies. Use `/run {worker-id} {skill}` to invoke them.

## Companies

Each company owns its settings, data, and knowledge.

```
companies/
├── _template/      # Skeleton copied when scaffolding a new company
├── manifest.yaml   # Company registry
└── {company}/      # Add one directory per company you manage (via /newcompany)
```

A scaffolded company contains:

```
companies/{co}/
├── data/           # Exports, reports, journal entries
├── hooks/          # Company-scoped hooks
├── knowledge/      # Company knowledge base (embedded git repo)
├── people/         # Contact / personnel records
├── policies/       # Company-scoped rules
├── projects/       # PRDs and project state
├── repos/          # Symlinks → repos/{public|private}/
├── settings/       # Credentials & config
├── skills/         # Company-scoped skills
├── workers/        # Company-scoped workers
└── workspace/      # Company-scoped scratch / drafts
```

## Projects

PRDs live at `companies/{co}/projects/{name}/prd.json` for company work, or `personal/projects/{name}/prd.json` for personal/HQ work, with `README.md` as the human-readable view.

```
/prd "Build dashboard"          # creates PRD
/run-project customer-cube      # execute via Ralph loop / Codex
```

## Directory Structure

```
HQ/
├── AGENTS.md                  # Charter for Claude / Codex sessions
├── .claude/
│   ├── CLAUDE.md
│   ├── commands/              # Slash commands (53)
│   ├── hooks/                 # Lifecycle hooks (32)
│   ├── skills/                # Skill definitions (55)
│   ├── output-styles/
│   ├── scripts/
│   ├── stack.yaml
│   └── settings.json / settings.local.json
├── core/
│   ├── core.yaml              # Core manifest
│   ├── docs/hq/               # README, CHANGELOG, MIGRATION, USER-GUIDE
│   ├── knowledge/
│   │   ├── public/            # Bundled public knowledge bases
│   │   └── private/           # Private knowledge bases (populated via packs / sync)
│   ├── packages/              # Packaged extensions
│   ├── policies/              # Cross-cutting rules (~259)
│   ├── scripts/               # Shared shell utilities
│   ├── settings/              # Orchestrator config
│   └── workers/
│       ├── public/            # Bundled workers (dev-team, content-*, social-*, gardener-team, …)
│       └── registry.yaml
├── companies/
│   ├── _template/             # Skeleton for new companies
│   ├── manifest.yaml
│   └── {co}/                  # One directory per company
├── personal/
│   ├── agents-profile.md
│   ├── agents-companies.md
│   ├── knowledge/
│   ├── projects/              # Personal/HQ project scratch
│   ├── policies/
│   ├── settings/
│   ├── skills/
│   └── workers/
├── repos/
│   ├── public/                # Open-source repos
│   └── private/               # Private repos
└── workspace/
    ├── baseline/              # Reference baselines
    ├── checkpoints/           # Session saves
    ├── drafts/                # In-flight drafts
    ├── learnings/             # Captured learnings
    ├── orchestrator/          # Ralph loop workflow state
    ├── reports/               # Generated reports
    ├── scratch/               # Free-form scratch
    └── threads/               # Session threads + handoff.json
```

## Meeting notes, signals & ontology

HQ captures these **natively, per company** — check HQ first, not your email or a third-party notetaker.

- **Meeting notes** — recordings/transcripts the HQ meeting bot ingests into `companies/{co}/sources/meetings/`. Read them with `/meeting-notes` (or `hq meetings list|notes --company {co}`).
- **Signals** — decisions, action items, wins, risks, open questions, and commitments extracted from your meetings, in `companies/{co}/signals/`. Read them with `/signals`.
- **Ontology** — situational context about a company (who/what is active, recent decisions) via the `ontology` skill.

**Turnkey setup (activation ladder):**

1. Make the company cloud-backed → `/designate-team {co}`.
2. Invite the HQ meeting bot to a call → notes ingest into `companies/{co}/sources/meetings/` automatically.
3. Signals are extracted from ingested notes into `companies/{co}/signals/`; ontology context follows.

**Your preference for "meeting notes":** defaults to HQ-native. To point a company at email instead, set `meeting_notes_source: email` in `companies/{co}/settings/knowledge/preferences.yaml` (global default lives in `personal/settings/knowledge-preferences.yaml`).

> Signals extraction and the ontology gardener run on HQ cloud and will require HQ Pro once billing ships. Billing isn't live yet — today these are provisioned per-company when you cloud-back it via `/designate-team`. Reference: `core/knowledge/public/hq-core/native-knowledge-stores.md`.

## Typical Session

1. `/startwork` — pick company/project/repo, gather context
2. Do work
3. `/checkpoint` — save progress
4. `/handoff` — prep for next session

## Knowledge Bases

**Public** (in `core/knowledge/public/`):
- `Ralph/` — coding methodology
- `agent-browser/` — browser automation patterns
- `ai-security-framework/` — security practices
- `dev-team/` — dev team patterns
- `getting-started/` — onboarding material
- `hq-core/` — thread schema, HQ patterns
- `loom/` — Loom agent patterns (reference)
- `projects/` — project templates
- `workers/` — worker framework reference

**Private** (in `core/knowledge/private/`):
- Empty by default — populated via packs (e.g. `@indigoai-us/hq-pack-*`) or sync.

**Company-level** (in `companies/{co}/knowledge/`):
- Each company has an embedded git repo populated through use.
