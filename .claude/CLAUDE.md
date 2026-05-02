# HQ — Charter for Claude Sessions

HQ is a personal operating system for orchestrating work across many companies, repos, workers, and AI sessions from one root directory. You are not in a single repo or product — you are in the orchestration layer that scaffolds, runs, and supervises work elsewhere. HQ is *not* a single-repo coding assistant, a one-shot workspace, or a knowledge dump.

## Purpose

### What Lives in HQ

- **companies/** — isolated tenants. Each has its own credentials, policies, knowledge, projects. Cross-company contamination is a category-1 bug.
- **repos/** — code (`repos/public/`, `repos/private/` — never elsewhere). HQ orchestrates; repos are where code actually lives.
- **projects/** — PRDs, brainstorms, and plans for work that may span repos and companies.
- **workers/** — specialized agents with skills (design, content, security, deploy, …). Use them before generic Claude.
- **workspace/** — session and orchestrator state (threads, locks, drafts, reports).
- **knowledge/** — reusable facts, specs, playbooks. Indexed by qmd.
- **policies/** — auto-enforced rules. Loaded at session start by hooks; do not duplicate them in this file.

### Charter Rule for This File

CLAUDE.md contains exactly three things: **Purpose** (what HQ is and your role inside it) · **Rules** (always-on rules with no policy home of their own) · **Map** (pointers to commands, skills, knowledge, and the policy system).

It does NOT contain rules that have a policy home — those auto-load via SessionStart.
It does NOT contain skill help — that lives in the skill file.
It does NOT contain reference data — that lives in knowledge/.

When adding something here, ask first: should this be a policy, a skill, or a knowledge file? If yes, put it there.

---

## Rules

### Core Principles

1. **Infrastructure scales, effort doesn't** — Build reusable systems
2. **Workers should grow smarter** — Capture learnings in knowledge bases
3. **Context is precious** — Checkpoint often, don't let work evaporate
4. **Test before ship** — If you can't verify it works, you can't ship it
5. **E2E tests prove it works** — Unit tests check code; E2E tests check the product
6. **Completeness is near-zero cost** — AI makes the marginal cost of doing the complete thing close to zero. Always do the complete thing when achievable (a "lake"), not the shortcut. Reserve shortcuts for genuinely unbounded scope (an "ocean")
7. **Never skip failing tests** — Always fix tests properly. Never use test.skip, never create false positives, never loosen assertions as a workaround. Investigate root cause and fix it — unit, integration, and E2E equally <!-- user-correction | 2026-04-04 -->
8. **Bugfixes require tests** — Every bug fix must include test or E2E coverage that catches the regression. Ask user if unsure about test type/scope. A fix without a regression test is incomplete <!-- user-correction | 2026-04-05 -->
9. **Vague → Verifiable** — When a request lacks clear success criteria ("fix the bug", "make it faster", "clean this up"), define what "done" looks like before starting. A test that passes, a metric that improves, a behavior that changes — something observable

### Corrections & Accuracy

When the user corrects factual content (pricing, session descriptions, product details), apply the correction exactly as stated. Do not re-interpret or paraphrase. If unsure, quote back what you'll write and confirm before committing.

### Sensitive Path Deny Lists

Sensitive paths (SSH/AWS/GPG/env/shell-rc) are Read-blocked by `.claude/settings.json` deny rules. For rc-file mutations: append-only (`printf >> file`) or pattern-delete (`sed '/pattern/d' file`) — never Read+Edit.

### Sub-Agent Rules

When spawning Task agents for story/task completion: each sub-agent MUST commit its own work before completing. The orchestrator should verify uncommitted changes after each sub-agent returns and commit them if the sub-agent failed to do so.

### Context Diet

Minimize context burn on session start:

- Do NOT read INDEX.md, agents files, or company knowledge unless task requires it
- Do NOT run qmd searches "to orient" — search only with a specific question
- For repo coding tasks: go directly to repo. HQ context rarely needed
- For worker execution: load only worker.yaml — it has its own knowledge pointers
- When unsure what to load: ask the user, don't explore
- Prefer `workspace/threads/handoff.json` (7 lines) over INDEX.md for session state

### Hook Profiles

Runtime profiles via `HQ_HOOK_PROFILE` env var: `minimal` (safety only), `standard` (default, all hooks), `strict` (reserved). Disable individual hooks: `HQ_DISABLED_HOOKS=hook1,hook2`. All hooks route through `.claude/hooks/hook-gate.sh`.

### Cross-Company Credential Isolation

Never fall back to another company's credentials. If the right ones fail, stop and ask. Manifest `companies/manifest.yaml` is source of truth for company-scoped fields. Full rules: `.claude/policies/credential-access-protocol.md` (auto-loaded).

### Image Context Isolation

Never accumulate >10 images in parent session; delegate image reads/verifications to a sub-agent that returns text only. Full rules: `.claude/policies/image-context-isolation.md`.

### Token Optimization

Env vars and `.claude/settings.json` control cost/style defaults:

| Setting | Value | Why |
|---------|-------|-----|
| `outputStyle` | `Explanatory` | Insight blocks + educational explanations |
| `MAX_THINKING_TOKENS` | `31999` | Full fixed-budget thinking |
| `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING` | `1` | Disable adaptive; use fixed budget |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | `75` | Autocompact at 75%; ~60% Stop-hook advisory |
| `CLAUDE_CODE_SUBAGENT_MODEL` | `opus` | Subagents (Task tool) use Opus |

Toggle thinking with Option+T.

### Git Workflow

- Verify which branch you're on before committing.
- Prefer merge over rebase when a branch is significantly behind (50+ commits).
- `--no-verify` is for hook fights only — never on main.
- Never commit to local main when intending to work on a feature branch.

---

## Map

### Key Files (load on demand)

`INDEX.md`, `agents-profile.md`, `agents-companies.md`, `USER-GUIDE.md`, `workers/registry.yaml`, `companies/manifest.yaml`. Full catalog: `knowledge/public/hq-core/quick-reference.md`.

### Structure

Top-level: `.claude/`, `agents-*.md`, `companies/`, `knowledge/{public,private}/`, `projects/` (personal/HQ only), `repos/{public,private}/`, `settings/`, `workers/public/`, `workspace/`. Each company is self-contained: `companies/{co}/{knowledge,settings,data,workers,repos,projects}/`. Full tree: `knowledge/public/hq-core/quick-reference.md`.

### Companies

Source of truth: `companies/manifest.yaml`. Each company is self-contained. Details: `knowledge/public/hq-core/quick-reference.md`.

### Infrastructure-First

When work implies new infrastructure, scaffold it BEFORE doing the work:

| Signal | Action |
|--------|--------|
| New company | `/newcompany {slug}` |
| New worker | `/newworker` |
| New knowledge base | `git init` (company) or `repos/public/knowledge-{name}` + symlink (shared) |
| New project | `/plan` |
| New repo | Clone to `repos/{pub\|priv}/` → manifest.yaml → qmd collection |

Post-creation: verify `manifest.yaml`, `workers/registry.yaml`, `modules/modules.yaml`; run `qmd update 2>/dev/null || true`; regen affected INDEX.md.

### INDEX.md System

Hierarchical INDEX.md files provide navigable directory maps. Spec: `knowledge/public/hq-core/index-md-spec.md`. Rebuild all: `/cleanup --reindex`. Auto-updated by checkpoint/handoff/plan/run-project.

### Search (qmd)

HQ + codebases indexed with [qmd](https://github.com/tobi/qmd). Modes: `search` (BM25), `vsearch` (semantic), `query` (hybrid+rerank), `get`/`multi-get`. Scope with `-c {collection}`. Hard rules: never Glob `prd.json`/`worker.yaml`; always pass `path:` to Glob. Full reference: `knowledge/public/hq-core/quick-reference.md`.

### Auto-Checkpoint

When `AUTO-CHECKPOINT REQUIRED` is injected by a PostToolUse hook, write a lightweight thread file and continue. Do NOT rebuild INDEX, run `qmd update`, or write legacy checkpoint files. When the **60% Stop banner** or **75% PreCompact banner** fires, present the 3 options (checkpoint / handoff / continue) and wait for the user — never auto-run `/checkpoint`. Trigger table: `knowledge/public/hq-core/auto-checkpoint-spec.md`.

### Session Handoffs

When preparing a session handoff: commit pending changes, write `handoff.json`, update INDEX files, create a thread file. Never enter plan mode during handoff — execute steps directly.

### Policies

Three scopes, precedence highest→lowest: `companies/{co}/policies/`, `repos/{repo}/.claude/policies/`, `.claude/policies/`. Auto-loaded by SessionStart hook + slash commands. Spec: `knowledge/public/hq-core/policies-spec.md`. Template: `companies/_template/policies/example-policy.md`.

### Workers

Worker-first rule: before specialized tasks (design, content, security, data, deploy), check `workers/registry.yaml` and use `/run {worker} {skill}`. Per-repo design: `design.md` declares `style-pack: <id>` resolved via `knowledge/public/design-styles/registry.yaml`. Roster + design quality refs: `knowledge/public/hq-core/quick-reference.md`.

### Commands & Skill Bridge

Core commands in `.claude/commands/`; company/niche commands live on their owning workers. Codex bridge: `.claude/skills/{name}/SKILL.md` mirrors each command. Coverage: `bash scripts/codex-skill-bridge.sh status`. Pattern: `knowledge/public/hq-core/codex-skill-pattern.md`.

### Knowledge Bases & Repos

Public list: `modules/modules.yaml` (filter `access: public`). Company knowledge: `companies/{co}/knowledge/`. Three valid repo patterns (embedded git, symlink, inline): `knowledge/public/hq-core/knowledge-taxonomy.md`.

### Learning System & Insights

Learnings captured as policies via `/learn` (scoped to company/repo/command/global). `/learn --hard` for hard-enforcement. Event log: `workspace/learnings/*.json`. Educational insights persist at `workspace/insights/`. Spec: `knowledge/public/hq-core/insights-spec.md`.

### E2E Testing

E2E tests verify the product works, not just the code. PRDs include optional `e2eTests` per story. Workers use the `e2e-testing` skill. Templates + infra guides: `knowledge/public/testing/`. Full guide: `knowledge/public/testing/e2e-cloud.md`.

### Skills Index

Frequently-used skills — invoke via `/<name>`. Full help lives in each skill's file.

| Need | Skill / Pointer |
|------|-----------------|
| Share an artifact (deck, report, dashboard) | `/deploy` — auto-passwords for PII/financial/private. Full rules: `.claude/policies/hq-deploy-reinforcement.md` |
| Get a secret | `/hq-secrets` — `hq secrets exec --only KEY -- <cmd>`. Never wrap in `$(...)` or pipe — values may leak |
| Plan a project | `/plan` (generates PRD, registers on board) |
| Run a worker | `/run {worker} {skill}` — roster: `workers/registry.yaml` |
| Save context | `/checkpoint`, or `/handoff` for fresh-session handoff |
| File locks / orchestrator runs | `settings/orchestrator.yaml` + `.claude/policies/repo-run-coordination.md` (bypass: `HQ_IGNORE_ACTIVE_RUNS=1`, auto-audited) |
