<h1 align="center">HQ by Indigo — The AI Operating System for Your Company</h1>

<p align="center">
  <strong>Shared context. Shared skills. Shared intelligence.<br>
  One person's breakthrough becomes everyone's baseline.</strong>
</p>

<p align="center">
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <a href="https://github.com/indigoai-us/hq-cli"><img src="https://img.shields.io/badge/CLI-hq--cli-green.svg" alt="HQ CLI"></a>
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> •
  <a href="#core-concepts">Core Concepts</a> •
  <a href="#commands">Commands</a> •
  <a href="#workers">Workers</a>
</p>

---

## What is HQ?

HQ is a **shared context layer** on top of any AI tool — Claude Code, Cursor, Codex, or whatever your team uses. It syncs knowledge, skills, and capabilities across everyone working with AI, so the most skilled user's workflow becomes the whole team's baseline.

Solo AI is easy. Team AI is hard. Every person builds their own context from scratch, every session. The most capable users have no clean way to share what they've built, and context evaporates between sessions and between people. HQ turns those individual wins into infrastructure the whole team inherits.

**It scales with you.** Solopreneurs use HQ to compound their own capabilities across projects, companies, and AI tools. Large enterprises use it to give every team member the same context, the same tools, and the same baseline of intelligence — without locking anyone into a single AI vendor.

Four systems sit at the core:

- **Cloud file system** — bidirectional sync between every team member's local HQ and a shared cloud store. Knowledge bases, policies, skills, workers, and threads stay in lockstep across the team. Conflicts surface for interactive review instead of silent overwrite, and the same context is reachable from web, mobile, or a remote AI session running in the cloud.
- **Access control** — company-scoped isolation by default. Roles and named groups govern who can see which files, secrets, and capabilities; cross-company contamination is architecturally impossible. Sign in once, and every HQ surface — vault, deploys, secrets, sync — works without re-authenticating. Every access is logged.
- **Secrets manager** — a per-company credential store with fine-grained ACLs. Each secret grants `read`, `write`, or `admin` to individuals or named groups, with optional company-wide open access. Values are injected directly into child processes — they never touch disk, stdout, or logs. For credentials a human holds, one-time links let a teammate hand off the value without any agent or operator ever seeing it.
- **Deployment** — one command ships any HQ artifact — reports, dashboards, decks, applications — to a shareable URL. Static sites and full server apps both work out of the box. Sensitive artifacts (PII, financial, private) are automatically password-protected. Deploy is opt-out and triggers itself when HQ produces something shareable, so the user gets a link without ever typing `deploy`.

```
┌──────────────────────────┐    ┌──────────────────────────┐    ┌──────────────────────────┐
│   COMPANY KNOWLEDGE      │    │                          │    │                          │
│   + CAPABILITIES         │ →  │         HQ LAYER         │ →  │        EVERY USER        │
├──────────────────────────┤    ├──────────────────────────┤    ├──────────────────────────┤
│  • Knowledge bases       │    │  • Cloud file system     │    │  • Claude Code           │
│  • Skills                │    │  • Access control        │    │  • Cursor                │
│  • Workers               │    │  • Secrets manager       │    │  • Codex                 │
│  • Policies              │    │  • Deployment            │    │  • Any AI tool           │
│  • Threads               │    │                          │    │                          │
└──────────────────────────┘    └──────────────────────────┘    └──────────────────────────┘
```

HQ is **model-agnostic**, so it works inside any AI tool and leverages the subscriptions your team already has — no new per-seat AI cost. It's **open source**. And it manages and creates context autonomously as your team works, so intelligence compounds without manual curation.

## Prerequisites

| Tool | Required | Install |
|------|----------|---------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | Yes | `npm install -g @anthropic-ai/claude-code` |
| [GitHub CLI](https://cli.github.com/) | Yes | `brew install gh` then `gh auth login` |
| [qmd](https://github.com/tobi/qmd) | Recommended | `brew install tobi/tap/qmd` |
| [OpenAI Codex](https://openai.com/codex) | Optional | `npm install -g @openai/codex` then `codex login` |
| [Vercel CLI](https://vercel.com/docs/cli) | Optional | `npm install -g vercel` then `vercel login` |
| [ggshield](https://docs.gitguardian.com/ggshield-docs/getting-started/installation) | Recommended | `brew install ggshield` then `ggshield auth login` |

### LSP (Language Server Protocol)

Enable LSP tools for code intelligence (go-to-definition, find-references, type info) by setting:

```bash
echo 'export ENABLE_LSP_TOOL=1' >> ~/.zshrc && source ~/.zshrc
```

Then restart Claude Code. With LSP enabled, Claude prefers LSP over grep for code navigation — faster and more accurate for symbol lookups, type checking, and reference finding.

`/setup` checks for these automatically and guides you through anything missing.

### Secret Scanning (recommended)

Prevent API keys, tokens, and credentials from being committed:

```bash
brew install ggshield
ggshield auth login
ggshield install --mode global
```

This enables a pre-commit hook across all repos that blocks commits containing secrets. Free tier covers personal use.

## Quick Start

```bash
# 1. Clone the HQ template
git clone https://github.com/indigoai-us/hq-core.git my-hq
cd my-hq

# 2. Open in Claude Code
claude

# 3. Run setup wizard (checks deps, creates profile, scaffolds knowledge repos)
/setup

# 4. Build your profile (optional but recommended)
/personal-interview
```

`/setup` asks your name, work, and goals, then scaffolds your first knowledge repo as a symlinked git repo (see [Knowledge Repos](#knowledge-repos) below). `/personal-interview` goes deeper — a tiered interview that builds your voice, preferences, and working style.

## Core Concepts

### Workers
Autonomous agents with defined skills. They *do things*.

| Type | Purpose | Examples |
|------|---------|----------|
| **CodeWorker** | Implement features, fix bugs | codex-coder, backend-dev, frontend-dev |
| **ContentWorker** | Draft content, maintain voice | content-brand, content-sales, content-product |
| **SocialWorker** | Compose, review, publish posts | social-strategist, social-publisher, social-verifier |
| **ResearchWorker** | Analyze data, surface insights | reality-checker, knowledge-curator |
| **OpsWorker** | Reports, automation, audits | accessibility-auditor, exec-summary, performance-benchmarker |
| **Library** | Shared utilities (no skills) | content-shared, social-shared |

### Knowledge Bases
Workers learn from and contribute to shared knowledge:

- `core/knowledge/public/Ralph/` — Autonomous coding methodology
- `core/knowledge/public/workers/` — Worker patterns & templates
- `core/knowledge/public/ai-security-framework/` — Security best practices
- `core/knowledge/public/dev-team/` — Development patterns
- `core/knowledge/public/hq-core/` — Thread schema, INDEX spec
- `core/knowledge/public/agent-browser/` — Browser automation patterns
- `core/knowledge/public/loom/` — Loom agent patterns (reference)
- `core/knowledge/public/projects/` — Project templates
- `core/knowledge/public/getting-started/` — Onboarding material
- `personal/knowledge/` — Your user-personal knowledge overlay. Entries here are symlinked into `core/knowledge/` by master-sync, so they appear inside core without changing precedence.

Optional packs (e.g. `@indigoai-us/hq-pack-design-styles`, `@indigoai-us/hq-pack-gemini`) install additional knowledge bases.

### Commands
Slash commands orchestrate everything:

```bash
/run worker-name skill    # Execute a worker skill
/checkpoint               # Save session state
/handoff                  # Prepare for fresh session
```

### Threads
Work survives context limits via `workspace/threads/` — checkpoints, handoffs, and resumable session state.

```bash
/checkpoint               # Save state
# ... context fills up → auto-handoff triggers ...
/recover-session          # Resume from a dead session
```

---

## Commands

The repo ships **53 slash commands** in `.claude/commands/`. The most-used are listed below; see `USER-GUIDE.md` for the full reference.

### Session
| Command | What it does |
|---------|--------------|
| `/startwork` | Pick company/project/repo, gather context |
| `/checkpoint` | Save progress to `workspace/checkpoints/` |
| `/handoff` | Prepare handoff for fresh session |
| `/recover-session` | Recover dead sessions that hit context limits |
| `/learn` | Auto-capture learnings from task execution |

### Workers
| Command | What it does |
|---------|--------------|
| `/run` | List workers / show skills / execute skill |
| `/newworker` | Create a new worker |

### Planning & Projects
| Command | What it does |
|---------|--------------|
| `/brainstorm` | Explore approaches before committing to a PRD |
| `/prd` | Create an execution-ready PRD |
| `/deep-plan` | Deep planning with research subagents and tiered interview |
| `/idea` | Capture a project idea on the board without a full PRD |
| `/goals` | View and manage OKR structure |
| `/strategize` | Strategic prioritization |
| `/run-project` | Execute a PRD via Ralph loop / Codex |
| `/run-pipeline` | Multi-project pipeline orchestrator |
| `/execute-task` | Execute a single PRD story |
| `/architect` | Surface architectural friction |
| `/review-plan` | Stress-test a plan or PRD |

### Quality, Debugging & Review
| Command | What it does |
|---------|--------------|
| `/tdd` | RED→GREEN→REFACTOR with coverage validation |
| `/quality-gate` | Pre-commit checks (typecheck, lint, test, coverage) |
| `/investigate` | Iron Law debugging — root-cause investigation before fixes |
| `/diagnose` | Disciplined diagnosis loop for hard / intermittent bugs |
| `/review` | Review a pull request |
| `/retro` | Project or session retrospective |
| `/document-release` | Post-ship documentation sync |
| `/calibration-report`, `/track-estimate`, `/finish-estimate` | Estimate calibration |

### Land & Ship
| Command | What it does |
|---------|--------------|
| `/land` | Land a PR — monitor CI, resolve review issues, merge, monitor production |
| `/land-batch` | Triage, review, and sequentially merge multiple open PRs |

### Knowledge & Decisions
| Command | What it does |
|---------|--------------|
| `/adr` | Capture an Architectural Decision Record |
| `/out-of-scope` | Record what was deliberately rejected and why |
| `/search` | Search across HQ and indexed repos (qmd-powered) |
| `/garden` | Detect stale, duplicate, inaccurate content |

### HQ Services & Sync
| Command | What it does |
|---------|--------------|
| `/hq-login`, `/hq-logout`, `/hq-whoami` | Cognito identity flows |
| `/hq-sync` | Run a full HQ sync across cloud-backed companies |
| `/resolve-conflicts` | Walk through HQ Sync conflicts interactively |

### System
| Command | What it does |
|---------|--------------|
| `/setup` | Interactive setup wizard |
| `/cleanup` | Audit and clean HQ |
| `/harness-audit` | Score HQ setup quality |
| `/update-hq` | Upgrade HQ from latest hq-core release |
| `/convert-codex` | Make Codex first-class alongside Claude Code |
| `/personal-interview` | Deep interview to build profile + voice |
| `/tutorial` | Interactive hands-on tutorial |
| `/ascii-graphic` | ASCII block-art generator |

---

## Workers

The repo ships **44 bundled workers** under `core/workers/public/`:

- **11 standalone**: `frontend-designer`, `qa-tester`, `security-scanner`, `pretty-mermaid`, `site-builder`, `knowledge-tagger`, `exec-summary`, `accessibility-auditor`, `performance-benchmarker`, `ascii-artist`, `paper-designer`
- **Dev Team (20)** in `dev-team/`: `project-manager`, `task-executor`, `architect`, `backend-dev`, `database-dev`, `frontend-dev`, `infra-dev`, `motion-designer`, `code-reviewer`, `knowledge-curator`, `product-planner`, `qa-tester`, `reality-checker`, `context-manager`, `codex-engine`, `codex-coder`, `codex-reviewer`, `codex-debugger`, `gemini-coder`, `gemini-reviewer`
- **Content Team (5)** in `content-*/`: `content-brand`, `content-sales`, `content-product`, `content-legal`, `content-shared` (library)
- **Social Team (5)** in `social-*/`: `social-strategist`, `social-reviewer`, `social-publisher`, `social-verifier`, `social-shared` (library)
- **Gardener Team (3)** in `gardener-team/`: `garden-scout`, `garden-auditor`, `garden-curator`

### Codex workers

Three production workers powered by the OpenAI Codex SDK via MCP:

| Worker | Purpose |
|--------|---------|
| **codex-coder** | Code generation in Codex sandbox |
| **codex-reviewer** | Second-opinion review + automated improvements |
| **codex-debugger** | Auto-escalation on back-pressure failure |

They share a `codex-engine` MCP server (also under `dev-team/`) that wraps the Codex SDK. To use them, sign in via `codex login` (the CLI manages credentials).

```bash
# Generate code
/run codex-coder generate-code --task "Create a rate limiter middleware"

# Review for security issues
/run codex-reviewer review-code --files src/auth/*.ts --focus security

# Debug a failing test
/run codex-debugger debug-issue --issue "TS2345 type error" --error-output "$(cat errors.txt)"
```

See `core/workers/public/dev-team/codex-coder/worker.yaml` for the full pattern.

### Build your own

```bash
# Option 1: Interactive scaffold
/newworker

# Option 2: Manual — copy a template
cp -r core/workers/public/dev-team/frontend-dev core/workers/public/my-worker
# Edit core/workers/public/my-worker/worker.yaml
```

Worker YAML structure (with modern patterns):

```yaml
worker:
  id: my-worker
  name: "My Worker"
  type: CodeWorker
  version: "1.0"

execution:
  mode: on-demand
  max_runtime: 15m
  retry_attempts: 1
  spawn_method: task_tool

skills:
  - id: do-thing
    file: skills/do-thing.md

verification:
  post_execute:
    - check: typescript
      command: npm run typecheck
    - check: test
      command: npm test
  approval_required: true

# MCP Integration (optional)
# mcp:
#   server:
#     command: node
#     args: [path/to/mcp-server.js]
#   tools:
#     - tool_name

state_machine:
  enabled: true
  max_retries: 1
  hooks:
    post_execute: [auto_checkpoint, log_metrics]
    on_error: [log_error, checkpoint_error_state]
```

See `core/knowledge/public/workers/` for the full framework, templates, and patterns.

---

## Project Execution

HQ uses the **Ralph Methodology** for autonomous coding.

### The Loop

```
1. Orchestrator picks next story from PRD (passes: false)
2. Spawn fresh Claude session with story assignment
3. Run back pressure (tests, lint, typecheck)
4. If passing → commit, mark passes: true
5. Retry failures (up to 2 attempts), then skip
6. Repeat until all stories complete
```

### Why It Works

- **Fresh context per story** — No accumulated confusion
- **Back pressure validates** — Code that doesn't pass isn't done
- **Atomic commits** — One story = one commit
- **PRD is truth** — Simple JSON, easy to inspect
- **State machine** — Survives interruptions, resumes where it left off
- **File locks** — Prevents concurrent edit conflicts across stories

### Running a Project

```bash
# 1. Create PRD
/prd "Build user authentication"

# 2. Execute via Ralph loop
/run-project auth-system

# 3. Monitor progress
/run-project auth-system --status

# 4. Resume after interruption
/run-project auth-system --resume

# 5. Retry failed stories
/run-project auth-system --retry-failed
```

The orchestrator script lives at `core/scripts/run-project.sh` and can also be run directly:

```bash
core/scripts/run-project.sh my-project --dry-run     # Preview without executing
core/scripts/run-project.sh my-project --verbose     # Detailed output
core/scripts/run-project.sh my-project --timeout 30  # Per-story timeout (minutes)
```

---

## Knowledge Repos

Knowledge bases in HQ are **independent git repos**, symlinked into `core/knowledge/`. This lets you version, share, and publish each knowledge base separately from HQ itself.

### How it works

```
repos/private/knowledge-personal/                                  ← actual git repo
    └── README.md, notes.md, ...

core/knowledge/public/personal → ../../../repos/private/knowledge-personal   ← symlink
```

HQ git tracks the symlink. The repo contents are tracked by their own git. Tools (`qmd`, `Glob`, `Read`) follow symlinks transparently.

### Creating a knowledge repo

```bash
# 1. Create and init the repo
mkdir -p repos/public/knowledge-my-topic
cd repos/public/knowledge-my-topic
git init
echo "# My Topic" > README.md
git add . && git commit -m "init knowledge repo"
cd -

# 2. Symlink into HQ
ln -s ../../../repos/public/knowledge-my-topic core/knowledge/public/my-topic
```

For company-scoped knowledge:
```bash
ln -s ../../../repos/private/knowledge-acme companies/acme/knowledge/acme
```

### Committing knowledge changes

Changes appear in `git status` of the *target repo*, not HQ:

```bash
cd repos/public/knowledge-my-topic
git add . && git commit -m "update notes" && git push
```

### Bundled knowledge

The starter kit ships Ralph, workers, security framework, etc. as plain directories under `core/knowledge/public/`. These work as-is. To convert one to a versioned repo later:

```bash
mv core/knowledge/public/Ralph repos/public/knowledge-ralph
cd repos/public/knowledge-ralph && git init && git add . && git commit -m "init"
cd -
ln -s ../../../repos/public/knowledge-ralph core/knowledge/public/Ralph
```

---

## Directory Structure

```
my-hq/
├── AGENTS.md                  # Charter for Claude / Codex sessions
├── README.md
├── CHANGELOG.md
├── MIGRATION.md
├── RELEASE-NOTES-*.md
├── USER-GUIDE.md
├── .claude/
│   ├── CLAUDE.md              # Session protocol + Context Diet
│   ├── commands/              # 53 slash commands
│   ├── hooks/                 # 32 lifecycle hooks (master-hook, detect-secrets, observe-patterns, …)
│   ├── skills/                # 55 skill definitions
│   ├── output-styles/         # Output styles (e.g. Cavebro)
│   ├── scripts/               # Claude-scoped helpers (run-project.sh, monitor-project.sh, …)
│   ├── stack.yaml
│   └── settings.json / settings.local.json
├── core/
│   ├── core.yaml              # Core manifest
│   ├── knowledge/
│   │   ├── public/            # Bundled public knowledge bases
│   │   └── private/           # Private knowledge bases (populated via packs / sync)
│   ├── modules/               # Pluggable modules (modules.yaml)
│   ├── packages/              # Packaged extensions
│   ├── policies/              # Cross-cutting rules (~259), with `_digest.md`
│   ├── scripts/               # Shared shell utilities (run-project.sh, audit-log.sh, …)
│   ├── settings/              # Orchestrator config
│   └── workers/
│       ├── public/            # Bundled workers (44 across dev-team, content-*, social-*, gardener-team, …)
│       └── registry.yaml
├── companies/
│   ├── _template/             # Skeleton for new companies
│   ├── manifest.yaml
│   └── {co}/                  # One directory per company (created via /newcompany)
├── data/
│   └── journal/               # Cross-company journal
├── projects/                  # Top-level project scratch
├── repos/
│   ├── public/                # Open-source repos + knowledge repos
│   └── private/               # Private repos + knowledge repos
└── workspace/
    ├── baseline/              # Reference baselines
    ├── checkpoints/           # Session saves
    ├── drafts/                # In-flight drafts
    ├── learnings/             # Captured insights
    ├── orchestrator/          # Ralph loop workflow state
    ├── reports/               # Generated reports
    ├── scratch/               # Free-form scratch
    └── threads/               # Auto-saved sessions + handoff.json
```

---

## Part of the HQ Framework

| Component | Purpose |
|-----------|---------|
| **hq-core** | This repo — personal OS template |
| **[hq-cli](https://github.com/indigoai-us/hq-cli)** | Module management CLI |

---

## Customization

This is a **template**. Make it yours:

- Build workers for your workflows (`/newworker`)
- Create knowledge bases for your domains
- Add commands for your patterns
- Connect tools via MCP
- Run `/personal-interview` to teach it your voice

---

## Credits

- **Ralph Methodology** by [Geoffrey Huntley](https://ghuntley.com/ralph/)
- **Loom Agent Architecture** by [Geoffrey Huntley](https://github.com/ghuntley/loom) — Thread system, state machine, and agent patterns
- Inspired by personal knowledge systems and AI workflow patterns

## License

MIT — Do whatever you want with it.
