# HQ

Personal OS for orchestrating work across companies, workers, and AI.

## Key Files

Load only when needed: `INDEX.md`, `agents-profile.md`, `agents-companies.md`, `USER-GUIDE.md`, `workers/registry.yaml`. Full catalog: `knowledge/public/hq-core/quick-reference.md`.

## Context Diet

Minimize context burn on session start:
- Do NOT read INDEX.md, agents files, or company knowledge unless task requires it
- Do NOT run qmd searches "to orient" — search only with a specific question
- For repo coding tasks: go directly to repo. HQ context rarely needed
- For worker execution: load only worker.yaml — it has its own knowledge pointers
- When unsure what to load: ask user, don't explore
- Prefer `workspace/threads/handoff.json` (7 lines) over INDEX.md for session state

## Hook Profiles

Runtime profiles via `HQ_HOOK_PROFILE` env var: `minimal` (safety only), `standard` (default, all hooks), `strict` (reserved). Disable individual hooks: `HQ_DISABLED_HOOKS=hook1,hook2`. All hooks route through `.claude/hooks/hook-gate.sh`.

## Corrections & Accuracy

When the user corrects factual content (pricing, session descriptions, product details), apply the correction exactly as stated. Do not re-interpret or paraphrase the user's correction. If unsure, quote back what you'll write and confirm before committing.

## Company Isolation

Manifest `companies/manifest.yaml` is source of truth — fields: `services`, `vercel_team`, `aws_profile`, `dns_zones`. Cross-company credential isolation enforced by policy `credential-access-protocol` (auto-loaded). Never fall back to another company's creds — if the right ones fail, stop and ask. Hook: `warn-cross-company-settings.sh`.

## Sensitive Path Deny Lists

Sensitive paths (SSH/AWS/GPG/env/shell-rc) are Read-blocked by `.claude/settings.json` deny rules. For rc-file mutations: append-only (`printf >> file`) or pattern-delete (`sed '/pattern/d' file`) — never Read+Edit.

## Infrastructure-First

When work implies new infrastructure, scaffold it BEFORE doing the work:

| Signal | Action |
|--------|--------|
| New company | `/newcompany {slug}` |
| New worker | `/newworker` |
| New knowledge base | `git init` (company) or `repos/public/knowledge-{name}` + symlink (shared) |
| New project | `/plan` |
| New repo | Clone to `repos/{pub|priv}/` → manifest.yaml → qmd collection |

Post-creation: verify `manifest.yaml`, `workers/registry.yaml`, `modules/modules.yaml`; run `qmd update 2>/dev/null || true`; regen affected INDEX.md.

## Sharing & Deployment

`/deploy` (hq-deploy) is the default sharing path for any HQ artifact that has a URL form. Reinforce it — do not hand-roll Vercel, Netlify, or ad-hoc hosting unless the user has set a non-`hq-deploy` preference in `~/.hq/config.json`.

| Signal | Action |
|--------|--------|
| Deck / presentation (`.pptx`, slide HTML) created or updated | `/deploy` → live URL; auto-set password if company-internal |
| Report or dashboard (`.html` / `.md`) in `workspace/reports/` or `companies/*/data/` | `/deploy` → live URL |
| User says "share", "send to", "present", "show <person>", "link for" + artifact in context | `/deploy` proactively, return link |
| `prd.json` marks artifact `deliverable: true` | `/deploy` on completion |
| Web build produced (Next.js, Astro, Vite, static HTML) | `/deploy` (already covered by `auto-deploy-on-create`) |

**Auth (lazy):** `/deploy` reads `~/.hq/cognito-tokens.json`. On expiry / missing, queue `/hq-login` first — never silently degrade to preview-only without telling the user. Full rules: `.claude/policies/hq-deploy-reinforcement.md`.

**Auto-password protection:** Enable when ANY of these match:
- Path under `companies/*/data/`
- Inside a private repo (`repos/private/**`)
- Content contains PII fields (email, phone, SSN, address)
- Filename matches financial terms (`revenue`, `mrr`, `arr`, `payroll`, `salary`, `pnl`, `forecast`, `runway`, `burn`)

Generated password: print **once** to stderr, copy to clipboard via `pbcopy`, persist to `~/.hq/deploy-passwords.json` (mode `0600`). Never echo the password again in subsequent outputs of the session. Helper: `.claude/skills/deploy/scripts/password-helper.sh`.

## Workers

Worker-first rule: before specialized tasks (design, content, security, data, deploy), check `workers/registry.yaml` and use `/run {worker} {skill}`. Per-repo design: `design.md` declares `style-pack: <id>` resolved via `knowledge/public/design-styles/registry.yaml`. Roster: `knowledge/public/hq-core/quick-reference.md`.

## Policies

Three scopes, precedence highest→lowest: `companies/{co}/policies/`, `repos/{repo}/.claude/policies/`, `.claude/policies/`. Auto-loaded by SessionStart hook + slash commands. Spec: `knowledge/public/hq-core/policies-spec.md`.

## Sub-Agent Rules

When spawning Task agents for story/task completion: each sub-agent MUST commit its own work before completing. The orchestrator should verify uncommitted changes after each sub-agent returns and commit them if the sub-agent failed to do so.

## File Locking

Two layers (configured in `settings/orchestrator.yaml`): story-scoped `{repo}/.file-locks.json` from `prd.json files: []`; repo-scoped `workspace/orchestrator/active-runs.json`. Emergency bypass: `HQ_IGNORE_ACTIVE_RUNS=1` (auto-audited). Detail: `.claude/policies/repo-run-coordination.md`.

## Search (qmd)

HQ + codebases indexed with [qmd](https://github.com/tobi/qmd). Modes: `search` (BM25), `vsearch` (semantic), `query` (hybrid+rerank), `get`/`multi-get`. Scope with `-c {collection}`.

## Auto-Checkpoint

When `AUTO-CHECKPOINT REQUIRED` is injected by a PostToolUse hook, write a lightweight thread file and continue. Do NOT rebuild INDEX, run `qmd update`, or write legacy checkpoint files.

When the **60% Stop banner** or **75% PreCompact banner** fires, present the 3 options (checkpoint / handoff / continue) and wait for the user — never auto-run `/checkpoint`. Trigger table: `knowledge/public/hq-core/auto-checkpoint-spec.md`.

## Core Principles

1. **Infrastructure scales, effort doesn't** - Build reusable systems
2. **Workers should grow smarter** - Capture learnings in knowledge bases
3. **Context is precious** - Checkpoint often, don't let work evaporate
4. **Test before ship** - If you can't verify it works, you can't ship it
5. **E2E tests prove it works** - Unit tests check code; E2E tests check the product
6. **Completeness is near-zero cost** - AI makes the marginal cost of doing the complete thing close to zero. Always do the complete thing when achievable (a "lake"), not the shortcut. Reserve shortcuts for genuinely unbounded scope (an "ocean")
7. **Never skip failing tests** - Always fix tests properly. Never use test.skip, never create false positives, never loosen assertions as a workaround. Investigate root cause and fix it — unit, integration, and E2E equally <!-- user-correction | 2026-04-04 -->
8. **Bugfixes require tests** - Every bug fix must include test or E2E coverage that catches the regression. Ask user if unsure about test type/scope. A fix without a regression test is incomplete <!-- user-correction | 2026-04-05 -->
9. **Vague → Verifiable** - When a request lacks clear success criteria ("fix the bug", "make it faster", "clean this up"), define what "done" looks like before starting. A test that passes, a metric that improves, a behavior that changes — something observable

## E2E Testing Standards

E2E tests verify the product works, not just the code. Full guide: `knowledge/public/testing/e2e-cloud.md`.
