# HQ

Personal OS for orchestrating work across companies, workers, and AI.

## Key Files

- `INDEX.md` - Directory map (load only for HQ infra tasks or when disoriented)
- `agents-profile.md` - Owner profile + style (load only for writing/comms tasks)
- `agents-companies.md` - Company contexts + roles (load only when company routing needed)
- `USER-GUIDE.md` - Commands, workers, typical session
- `workers/registry.yaml` - Worker index

## Context Diet

Minimize context burn on session start:
- Do NOT read INDEX.md, agents files, or company knowledge unless task requires it
- Do NOT run qmd searches "to orient" — search only with a specific question
- For repo coding tasks: go directly to repo. HQ context rarely needed
- For worker execution: load only worker.yaml — it has its own knowledge pointers
- When unsure what to load: ask user, don't explore
- Prefer `workspace/threads/handoff.json` (7 lines) over INDEX.md for session state

## Token Optimization

Env vars and settings in `.claude/settings.json` control cost/style defaults:

| Setting | Value | Why |
|---------|-------|-----|
| `outputStyle` | `Explanatory` | Enables Insight blocks + educational explanations. Synced to starter-kit |
| `MAX_THINKING_TOKENS` | `31999` | Full fixed-budget thinking (adaptive disabled separately) |
| `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING` | `1` | Disables adaptive thinking on Opus/Sonnet 4.6 — uses fixed budget instead |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | `75` | Autocompact fires at 75%; a separate Stop-hook advisory warns once at ~60% |
| `CLAUDE_CODE_SUBAGENT_MODEL` | `opus` | Subagents (Task tool) use Opus — all Claude work runs on Opus 4.6 |

Toggle thinking with Option+T.

## Hook Profiles

Runtime profiles via `HQ_HOOK_PROFILE` env var: `minimal` (safety only), `standard` (default, all hooks), `strict` (reserved). Disable individual hooks: `HQ_DISABLED_HOOKS=hook1,hook2`. All hooks route through `.claude/hooks/hook-gate.sh`.

## Session Handoffs

When preparing a session handoff: always commit all pending changes first, write a handoff.json with current progress state (completed stories, remaining work, blockers), update INDEX files, and create a thread file. Never enter plan mode during handoff — execute steps directly.

## Corrections & Accuracy

When the user corrects factual content (pricing, session descriptions, product details), apply the correction exactly as stated. Do not re-interpret or paraphrase the user's correction. If unsure, quote back what you'll write and confirm before committing.

## INDEX.md System

Hierarchical INDEX.md files provide navigable directory maps. Spec: `knowledge/public/hq-core/index-md-spec.md`. Rebuild all: `/cleanup --reindex`. Auto-updated by checkpoint/handoff/plan/run-project commands.

## Structure

Top-level: `.claude/commands/`, `agents-profile.md`, `agents-companies.md`, `companies/`, `knowledge/{public,private}/`, `projects/` (personal/HQ only), `repos/{public,private}/`, `settings/` (shared only — post-bridge, orchestrator), `workers/public/`, `workspace/{checkpoints,orchestrator,reports,social-drafts}/`. Each company is self-contained: `companies/{co}/{knowledge,settings,data,workers,repos,projects}/`. Full tree: `knowledge/public/hq-core/quick-reference.md`

## Companies

Listed in `companies/manifest.yaml` (source of truth). Each is self-contained: `settings/` (creds), `data/` (exports), `knowledge/` (embedded git repo), `workers/` (company-scoped), `repos/` (symlinks to canonical clones), `projects/` (PRDs). Details: `knowledge/public/hq-core/quick-reference.md`

## Company Isolation

Manifest: `companies/manifest.yaml` — maps companies to repos, workers, knowledge, deploy targets. Fields: `services`, `vercel_team`, `aws_profile`, `dns_zones`.

**Before company-scoped operations:** identify company from context → read `companies/{co}/policies/` → use manifest infrastructure fields (don't guess).

**Hard rules:**
- NEVER read/use credentials from a different company's settings
- NEVER try another company's credentials as "fallback" — if the right company's creds fail, stop and ask
- NEVER paste secrets inline in bash commands — use `AWS_PROFILE=`, env files, or config refs
- NEVER deploy to a company's Vercel project / GitHub repo from a different company's context
- NEVER mix company knowledge in outputs
- NEVER use Linear credentials from a different company's settings
- Before any Linear API call, validate: config.json `workspace` field matches expected company
- If prd.json `linearCredentials` path doesn't match active company per manifest, ABORT and warn
- When task spans multiple companies (rare), explicitly acknowledge cross-company scope

Credential access: policy `credential-access-protocol.md`. Hook: `warn-cross-company-settings.sh`.

## Sensitive Path Deny Lists

Sensitive paths (SSH/AWS/GPG/env/shell-rc) are Read-blocked by `settings.json` deny rules. For rc-file mutations use append-only (`printf >> file`) or pattern-delete (`sed '/pattern/d' file`) — never Read+Edit. Full list lives in `.claude/settings.json` `permissions.deny`.

## Infrastructure-First

When work implies new infrastructure, scaffold it BEFORE doing the work:

| Signal | Action |
|--------|--------|
| New company | `/newcompany {slug}` — creates dir, manifest, knowledge repo, qmd collection |
| New worker needed | `/newworker` — scaffolds worker.yaml in `companies/{co}/workers/`, registers in registry + manifest |
| New knowledge base | For company: `git init` in `companies/{co}/knowledge/`. For shared: create repo in `repos/public/knowledge-{name}` → symlink to `knowledge/public/`. Add to `modules/modules.yaml` |
| New project | `/plan` — creates `companies/{co}/projects/{name}/` with prd.json + README |
| New repo | Clone to `repos/{pub|priv}/` → add to `manifest.yaml` → add qmd collection |

**Post-infrastructure checklist (mandatory after ANY creation):**
1. `manifest.yaml` — verify no `null` values for company entry
2. `workers/registry.yaml` — verify new workers registered
3. `modules/modules.yaml` — verify new knowledge repos registered
4. `qmd update 2>/dev/null || true` — reindex search
5. Regenerate affected INDEX.md files

**Always reindex (`qmd update 2>/dev/null || true`) after:**
- Creating/modifying workers, knowledge, commands, projects
- Completion of `/newworker`, `/plan`, `/learn`, `/cleanup`, `/handoff`, `/execute-task`, `/run-project`
- Git commits touching `knowledge/`, `workers/`, `.claude/commands/`, `projects/`

## Workers

**Shared** (`workers/public/`): frontend-designer, impeccable-designer (**deprecated 2026-04-15** — use dev-team/frontend-dev + design-styles knowledge), qa-tester, security-scanner, pretty-mermaid, exec-summary, accessibility-auditor, performance-benchmarker, gstack-team (26 g-* skills) + dev-team (frontend-dev: +4 design quality skills audit/polish/typeset/harden, full design-styles context; motion-designer: style-coherent animation via design-styles) + content-team (5) + social-team (5) + gardener-team (3) + gemini-team (6) + knowledge-tagger + site-builder.
**Company** (`companies/{co}/workers/`): per-company workers listed in `workers/registry.yaml`.

**Per-repo design context:** `design.md` at repo root (renamed from `.impeccable.md`). Declares `style-pack: <id>` in the Design Direction section. Workers resolve the pack via `knowledge/public/design-styles/registry.yaml` → pack directory → `context_paths.required`. Pack schema: `knowledge/public/design-styles/PACK-SCHEMA.md`. Design quality references (typography, color, spatial, etc.) live in `knowledge/public/design-quality/`.

**Worker-first rule:** Before specialized tasks (design, content writing, security, data analysis, deployment), check `workers/registry.yaml` for a matching worker. Use `/run {worker} {skill}` — workers carry domain instructions + learned rules. Only work directly if no suitable worker exists.

## Policies

Rules stored as policy files (YAML frontmatter + `## Rule` + `## Rationale`). Three directories, checked in precedence:
1. `companies/{co}/policies/` — company-scoped (highest)
2. `repos/{repo}/.claude/policies/` — repo-scoped
3. `.claude/policies/` — cross-cutting + command-scoped (lowest)

Hard enforcement blocks on violation; soft notes deviations. Commands auto-load applicable policies (`/startwork`, `/run-project`, `/execute-task`, `/plan`, `/run`, `/learn`). Spec: `knowledge/public/hq-core/policies-spec.md`. Template: `companies/_template/policies/example-policy.md`.

## Sub-Agent Rules

When spawning Task agents for story/task completion: each sub-agent MUST commit its own work before completing. The orchestrator should verify uncommitted changes after each sub-agent returns and commit them if the sub-agent failed to do so.

## Image Context Isolation

Never accumulate >10 images in parent session; delegate image reads/verifications to a sub-agent that returns text only. Full rules: `.claude/policies/image-context-isolation.md`

## File Locking

Two coordination layers, both configured in `settings/orchestrator.yaml`:

1. **Story-scoped** — `/execute-task` acquires `{repo}/.file-locks.json` from `prd.json` `files: []`; `/run-project` skips conflicting stories.
2. **Repo-scoped (cross-session)** — `workspace/orchestrator/active-runs.json` blocks Edit/Write/destructive-Bash against owned repos. Bypass (emergency only): `HQ_IGNORE_ACTIVE_RUNS=1` — auto-audited.

Full policy: `.claude/policies/repo-run-coordination.md`.

## Commands

30 commands in `.claude/commands/` (core only). Company/niche commands live on their owning workers. Full catalog: `knowledge/public/hq-core/quick-reference.md`

## Knowledge Bases

Public: listed in `modules/modules.yaml` (filter `access: public`). Company-level: each at `companies/{co}/knowledge/`. Full list: `knowledge/public/hq-core/quick-reference.md`

## Knowledge Repos

Three valid patterns: (1) embedded `.git` dir tracked as `160000` gitlink (most company knowledge), (2) symlink to `repos/private/knowledge-{co}/` tracked as `120000`, (3) inline files tracked by HQ git. All three coexist; none are being migrated. Register new knowledge in `modules/modules.yaml`. Pattern selection + commit semantics: `knowledge/public/hq-core/knowledge-taxonomy.md`.

## Skills

`.claude/skills/` is the canonical skill tree. Codex bridge: `scripts/codex-skill-bridge.sh install`. Dual-format: `.claude/commands/{name}.md` (Claude Code source) + `.claude/skills/{name}/SKILL.md` (Codex adaptation). All user-facing Claude commands should have a matching Codex skill. Coverage: `bash scripts/codex-skill-bridge.sh status`. Full pattern: `knowledge/public/hq-core/codex-skill-pattern.md`.

## Search (qmd)

HQ + codebases indexed with [qmd](https://github.com/tobi/qmd) (v1.0.0). Modes: `search` (BM25), `vsearch` (semantic), `query` (hybrid+rerank), `get`/`multi-get`. Scope with `-c {collection}`. Collection list + command reference: `knowledge/public/hq-core/quick-reference.md`.

**Hard rules:** Never Glob for `prd.json`/`worker.yaml` (hook blocked). Always pass `path:` to Glob (never from HQ root). Prefer qmd for codebase exploration; Grep for exact matching. `.ignore` protects Grep but NOT Glob. Parallel Glob calls: if one times out, ALL sibling calls die.

## Learning System

Learnings captured as policy files via `/learn` (scoped to company/repo/command/global). Use `/learn --hard` for hard-enforcement rules (formerly `/remember`). Event log: `workspace/learnings/*.json`. Before `/handoff` or `/checkpoint`, reflect and call `/learn` for reusable findings. Auto-triggered after infrastructure creation (see Infrastructure-First). Skip when nothing novel learned.

## Insights

Educational insights persist at `workspace/insights/`. Captured via `/learn`, auto-triggered by `/handoff` and `/checkpoint`. Spec: `knowledge/public/hq-core/insights-spec.md`.

## Git Workflow Rules

- Always verify which branch you're on before committing.
- Prefer merge over rebase when a branch is significantly behind (50+ commits).
- If lint-staged or git hooks cause issues during merge/rebase, disable them temporarily with `--no-verify` rather than fighting through repeated failures.
- Never commit to local main when intending to work on a feature branch.

## Vercel Deployments

- Always verify the correct Vercel org/team before deploying (check with `vercel whoami` and `vercel teams ls`).
- Confirm framework detection is correct before deploying.
- If preview deploys are behind SSO, fall back to local testing immediately rather than debugging SSO.

## Auto-Checkpoint

When `AUTO-CHECKPOINT REQUIRED` is injected by a PostToolUse hook (after git-commit/push, deploys, publishes, file-edit, etc.), write a lightweight thread file and continue. Do NOT rebuild INDEX, update `recent.md`, run `qmd update`, or write legacy checkpoint files. Knowledge edits commit to the knowledge repo, not HQ git.

When the **60% Stop banner** or **75% PreCompact banner** fires, present the 3 options (checkpoint / handoff / continue) and wait for the user — never auto-run `/checkpoint`. If context feels heavy outside those banners, proactively suggest `/checkpoint` or `/handoff`.

Trigger table + thresholds spec: `knowledge/public/hq-core/auto-checkpoint-spec.md`.

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

For deployable projects (web, API, CLI):
- E2E tests verify the product works, not just the code
- Tests are back-pressure in the Ralph loop (fail = task incomplete)
- Knowledge base: `knowledge/public/testing/` (templates, infra guides, agent-browser)
- PRDs include optional `e2eTests` per story
- Workers use `e2e-testing` skill for writing/running tests

**Full guide:** `knowledge/public/testing/e2e-cloud.md`

## Secrets

Use `/hq-secrets` for the full playbook. Core rules:

- **Inject via exec:** `hq secrets exec --only KEY1,KEY2 -- <command>` — values become env vars in the child process, never stdout.
- **Get redacts by default:** `hq secrets get <NAME>` shows metadata only; `--reveal` is an explicit escape hatch.
- **Never capture exec output:** do not wrap `exec` in `$(...)`, pipe it, or echo `process.env.SECRET` — secret values may appear in subprocess output. This is a prompt-level guardrail, not technical enforcement.
- **Discover with list:** `hq secrets list` shows available secrets (metadata only).
- **Human-supplied values:** `hq secrets generate-link <NAME>` produces a URL for a human to enter a value you should not see.
