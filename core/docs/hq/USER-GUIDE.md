# HQ User Guide

The AI operating system for your company. A shared context layer on top of Claude Code, Codex, Cursor, and Grok — syncs knowledge, skills, and capabilities across your team. Scales from solopreneur to enterprise.

For a first-time setup, begin with the **[guided HQ tutorial](https://www.hqforwork.com/getting-started/tutorials/install-hq-macos?source=hq_user_guide)**. Its seven videos, written walkthroughs, and screenshots take you from installation through your first shared worker. The `/tutorial` command below is the complementary adaptive course inside your local HQ.

## Prerequisites & platforms

HQ's shell layer (hooks, scripts, skills) runs on **Linux, macOS, and Windows Git Bash**. Required tools: bash, git, node, **jq**.

Per-OS install commands, known limitations (including `/deploy` identity `missing_dependency`), and contributor conventions (`portable.sh`, `hook-lib.sh`) live in:

→ [core/knowledge/public/hq-core/cross-platform-support.md](../../knowledge/public/hq-core/cross-platform-support.md)

If a skill is skipped as invalid YAML or a hook reports a launch failure, use the runtime-contract troubleshooting section in that guide. HQ attempts safe execute-bit repair first; unrecoverable failures include an exact remediation command without exposing hook payloads or secrets.

## Commands

### Session Management
| Command | What it does |
|---------|--------------|
| `/startwork` | Pick company/project/repo, gather context |
| `/checkpoint` | Save progress to `workspace/checkpoints/` |
| `/handoff` | Prepare handoff for fresh session |
| `/delegate <recipient> [project]` | Hand a project to a teammate or fleet agent with exact grant receipts, a published dossier, local board and PRD ownership updates, and a pickup DM. Recipient access and Work Mesh ownership require separate confirmation. Requires HQ CLI 5.109.7+. `--share` keeps ownership; `--dry-run` changes nothing |
| `/recover-session` | Recover dead sessions that hit context limits |
| `/learn` | Auto-capture learnings from task execution |
| `/pin` | Anchor the session to one goal with done criteria, re-read at every wake and resume |
| `/dm-bind` | Bind the session to one HQ DM channel: post status there, take replies as steering |

### Planning & Projects
| Command | What it does |
|---------|--------------|
| `/brainstorm` | Explore approaches and tradeoffs before committing to a PRD |
| `/plan` | Lightweight plan for a new project |
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
| `hq doctor` | Verify HQ hook guardrails are wired and firing (read-only, offline) — see [hq doctor](#hq-doctor--hook-guardrail-diagnostics) |
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
| `/hq-login` | Sign in to HQ (Cognito browser flow). `hq login --provider google\|microsoft\|picker`; Google is the default, the picker also covers email and password accounts |
| `/hq-logout` | Clear the local HQ session |
| `/hq-whoami` | Show current HQ identity and token expiry |
| `/hq-sync` | Run a full HQ sync across cloud-backed companies |
| `/resolve-conflicts` | Walk through HQ Sync conflicts interactively |

### HQ CLI (most used)

The full command list (55 roots in CLI 5.247.0) is generated from the CLI and
lives in [hq-cli-reference.md](../../knowledge/public/hq-core/hq-cli-reference.md).
Run `hq <command> --help` for options. Commonly used:

| Command | What it does |
|---------|--------------|
| `hq login` / `hq whoami` | Sign in; show the current identity |
| `hq sync now` | Push then pull the active company (`--all` for every membership plus the personal vault) |
| `hq files share <prefix>...` | Share vault paths. Opens a share-session page; `--with <email\|grp_*\|@all> --permission <read\|write>` grants directly. Full reference: `.claude/skills/hq-files/SKILL.md` |
| `hq secrets` / `hq run` | Manage secrets; run a command with secrets injected |
| `hq dm <recipient-or-channel> "<message>"` | Send a direct message (see below) |
| `hq search "<query>"` | Search the local HQ qmd index |
| `hq bot` | Local bots on this computer |
| `hq integrations` | Connected company apps |
| `hq billing status --company <slug>` | Plan and subscription status |
| `hq db status\|sql\|migrate --company {co}` | Local vault SQLite database. Guide: [vault-databases.md](../../knowledge/public/hq-core/vault-databases.md) |

Share-session URLs are encrypted single-use 15-minute capabilities. Never paste them into commits, threads, or logs. See policy `core/policies/hq-share-session-urls-are-capabilities.md`.

`hq db provision` creates a remote vault DB and requires the HQ Workforce plan. `hq db sql --remote` exists but does not work yet (no remote executor is wired); use local SQL. Never commit `*.db` files into the vault tree.

### Direct messages (`hq dm`, `/dm`)

HQ has full messaging: DMs, group messages, channels, and threads. You can send and read in the HQ Desktop App on macOS and Windows, or from a session with `hq dm` / `/dm`. Full reference: `.claude/skills/dm/SKILL.md`.

| Command | What it does |
|---------|--------------|
| `hq dm <recipient-or-channel> "<message>"` | Send to a person (email, `prs_*`), a bot, or a channel |
| `hq dm <r> "<m>" --prompt "<context>"` | Attach agent context the recipient can copy into their own agent |
| `hq dm <r> "<m>" --details "<text>"` (or `--details-file <path>`) | Longer text shown in an **Open details** view |
| `hq dm <r> "<m>" --at <iso>` / `--in <30s\|10m\|2h\|1d>` | Schedule delivery (store-and-forward) |
| `hq dm inbox` | Recent incoming messages |
| `hq dm thread <person>` | Two-way conversation with one person or bot |
| `hq dm channel <name>` | Recent messages in a channel or group DM (`hq channels` lists them) |
| `hq dm requests` / `accept` / `decline` / `block` | Manage connection requests from people outside your companies |

DM your own email for a note-to-self or reminder. Never put secrets in a message body, prompt, or details; they are stored server-side.

### Company & Infrastructure
| Command | What it does |
|---------|--------------|
| `/newcompany` | Scaffold new company with full infrastructure |
| `/designate-team` | Mark a company directory as cloud-backed |
| `/sync-registry` | Regenerate a company's resource registry index |
| `/discover` | Pull a repo into HQ and synthesize structured knowledge |
| `/import-context` | Scan the machine for prior AI artifacts and conversation history (Claude Code, Codex, Grok, claude.ai) and import into HQ (alias: `/import-claude`) |
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

## Attaching a script to a command (`command.sh`)

A slash command is normally a prompt: Claude reads the skill and decides what to
do. Sometimes you want a plain, deterministic step to run on invocation instead
— print the current deploy status, stamp a timestamp, warm a cache.

Drop an executable `command.sh` next to a skill's `SKILL.md`:

```
personal/skills/deploy-status/
├── SKILL.md
└── command.sh
```

When you type `/deploy-status`, the `UserPromptSubmit` hook
`core/hooks/UserPromptSubmit/40-skill-command-script.sh` runs that script and
shows its output to you. The turn then proceeds normally — the script does not
replace or block the skill.

**The output is shown to you only.** It is delivered as `systemMessage`, which
the harness renders in your terminal and does not add to the model's context.
If Claude should see the output instead, write your own hook that returns
`hookSpecificOutput.additionalContext`.

Folders searched, highest precedence first:

| Folder | Invoked as |
|---|---|
| `companies/<active-company>/skills/<name>/` | `/<name>` or `/<company>:<name>` |
| `personal/skills/<name>/` | `/<name>` or `/personal:<name>` |
| `core/packages/<pack>/skills/<name>/` | `/<name>` or `/<pack>:<name>` |
| `.claude/skills/<name>/` | `/<name>` |
| `core/skills/<name>/` | `/<name>` |

A company's `command.sh` runs only when that company is the session's active
company. `/othercompany:thing` is refused rather than searched for.

The script gets the hook payload on stdin, plus `HQ_ROOT`, `HQ_COMMAND_NAME`,
`HQ_COMMAND_ARGS` (everything you typed after the command), `HQ_COMMAND_SCOPE`,
and `HQ_ACTIVE_COMPANY`. Output is capped and the script is stopped after 5
seconds, so a slow or runaway script cannot wedge your turn. A non-zero exit is
reported to you and the turn still proceeds.

Knobs: `HQ_SKILL_COMMAND_SCRIPTS=0` turns the whole thing off,
`HQ_SKILL_COMMAND_FILE` changes the filename, `HQ_SKILL_COMMAND_TIMEOUT` and
`HQ_SKILL_COMMAND_MAX_BYTES` change the bounds.

## hq doctor — hook guardrail diagnostics

`hq doctor` is the single command that answers whether your HQ hook guardrails
are actually wired and firing, on whichever agent platform you are running
(Claude Code, Codex, or Grok Build). It is read-only and fully offline — no HQ
login, no vault access, no network — because it has to work precisely when the
rest of the toolchain is suspect. It absorbs the older `check-hq-hooks.sh` (now a
thin wrapper that calls `hq doctor` and degrades to an inline check when the CLI
is absent) and the `/harness-audit` hook-coverage score.

| Invocation | What it does |
|------------|--------------|
| `hq doctor` | Wiring checks: every hook registration across Claude/Codex/Grok is present, executable, correctly gated, and not word-split; plus the runtime probe (did hooks actually fire this session). Never executes a hook. |
| `hq doctor --deep-test` | Everything above, then actually fires your blocking hooks with crafted inputs through the real `hook-gate.sh` under all three profiles — in a throwaway sandbox, never your live tree — to prove they block what they claim to. |
| `hq doctor --fix` | Applies only the allowlisted safe repairs (restore an executable bit, add a hook id to gate profiles it is missing from, re-register an on-disk hook) behind a backup, a diff preview, interactive confirmation, and a dirty-tree refusal. Never rewrites a hook's body or deletes a file. |
| `hq doctor --json` | Emits the machine-readable, versioned document (schema version, detected platform, resolved root, and every result). This is what `/harness-audit` and CI consume. |
| `hq doctor --session-id <id>` | Scopes the runtime probe's ledger check to that exact session, so an older session's ledger cannot be mistaken for the current runtime (useful on app/SDK hosts). |

**Exit code:** `0` unless some result is `FAIL` or `UNKNOWN`; `1` when any is.
`WARN`, `UNTESTED`, `NA`, and `KNOWN-DEFECT` are reported but never fail the
command — a doctor that goes red on a healthy install would train you to ignore
it, which is the exact failure mode it exists to prevent.

**Status vocabulary** (the load-bearing part — these never collapse into `PASS`):

| Status | Meaning |
|--------|---------|
| `PASS` | Verified correct. |
| `FAIL` | Verified broken — fix it. |
| `WARN` | Non-blocking concern worth a look (e.g. an orphaned hook, a stale allowed-divergence entry). |
| `UNTESTED` | Wired but never exercised: the hook is registered but has no fixture, so its behaviour has not been proven. Coverage is reported as a `tested/total` line so this stays visible. |
| `NA` | Untestable on this platform (e.g. a Grok `SessionStart` hook, whose stdout Grok ignores). Not a pass and not a failure — the platform simply cannot run the check. |
| `UNKNOWN` | Could not be determined — the host platform was unidentifiable, or a check could not run. Fails the command rather than claiming a verdict it cannot support. |
| `KNOWN-DEFECT` | A tracked, unfixed defect pinned by an `expectedFailure` fixture marker. Always printed and counted separately, but never fails the command; if it starts passing, the doctor warns that the marker is stale. |

The distinction between `UNTESTED` / `NA` / `UNKNOWN` and `PASS` is the design's
central safeguard: a false `PASS` is worse than no tool, because it retires the
instinct to check by hand.

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

**Dev Team (18)** — `core/workers/public/dev-team/`:
project-manager, task-executor, architect, backend-dev, database-dev, frontend-dev, infra-dev, motion-designer, code-reviewer, knowledge-curator, product-planner, qa-tester, reality-checker, context-manager, codex-engine, codex-coder, codex-reviewer, codex-debugger
(Gemini CLI workers gemini-coder / gemini-reviewer install via the optional `@indigoai-us/hq-pack-gemini` pack.)

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
/plan "Build dashboard"          # creates PRD
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

> Signals extraction and the ontology gardener run on HQ cloud. Billing is live: inviting the HQ meeting bot requires the HQ Workforce plan (internal id `paid-500`), and a Starter company is refused with an upgrade link. Plans: [plans-and-pricing.md](../../knowledge/public/hq-core/plans-and-pricing.md). Reference: [native-knowledge-stores.md](../../knowledge/public/hq-core/native-knowledge-stores.md).

## Product surfaces

For the map of HQ surfaces (CLI, desktop app, console, bots, connectors, deploy, sync), identity types, and which surface to use for a task, read [hq-product-model.md](../../knowledge/public/hq-core/hq-product-model.md).

## HQ Desktop app

A macOS and Windows app. On a new machine it runs onboarding; after that it is a messaging workspace (DMs, groups, channels, bots, a home channel per company) with Files, Projects, Meetings, and Library pages, and it runs sync in the background. It has no built-in agent sessions: the **Launch** menu opens the HQ folder in Claude Code, Codex, or Grok. First run creates a **Setup bot**, a personal local bot you DM to finish setup. Reference: [hq-desktop-app.md](../../knowledge/public/hq-core/hq-desktop-app.md).

## Bots & agents

- **Local bots** run on your computer with your own Claude, Codex, or Grok login: `hq bot create <name>`, or desktop Settings → Bots.
- **Hosted agents** run on HQ infrastructure for a company: `/new-agent`, `hq agents provision`, or the console Bots page.
- **External bots** run on your own hardware and enroll with `hq agent enroll <code>`. They require a paid plan and are unlimited on it.
- **Chat-app connectors** let a person use HQ from Claude, ChatGPT, Claude Code, Codex, or Grok through the hosted HQ connector (console → Integrations → Connect an agent shows the URL).

Reference: [agents-and-bots.md](../../knowledge/public/hq-core/agents-and-bots.md), [external-agents-mcp.md](../../knowledge/public/hq-core/external-agents-mcp.md).

## Console

[hq.computer](https://hq.computer) is the web UI: team and invites, groups and grants, bots, integrations, secrets, vault, billing, and deployments. Most pages have a matching CLI command or skill. Reference: [hq-console.md](../../knowledge/public/hq-core/hq-console.md). Plans and billing: [plans-and-pricing.md](../../knowledge/public/hq-core/plans-and-pricing.md).

## Deploy

`/deploy` publishes a generated artifact through hq-deploy and returns a link. Access modes are public (default), password, company sign-in, selected people or groups, and a private email allowlist. There is no `hq deploy` command.

Comments are opt-in per deploy (`/deploy --comments on`, static deploys only). Signed-in viewers pin, box, or highlight parts of the page and comment; the owner reads and resolves them in the page's side pane, or asks the agent to use the `/deploy` owner routes. The console has no comment UI. Reference: [deploy SKILL.md](../../../.claude/skills/deploy/SKILL.md).

## Sync

Cloud-backed companies sync to a company vault; the rest of your HQ folder (minus `repos/` and most of `workspace/`) syncs to your personal vault. Run `/hq-sync` or `hq sync now`; the desktop app syncs in the background. Reference: [hq-sync-model.md](../../knowledge/public/hq-core/hq-sync-model.md).

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
