# HQ — Charter for Claude Sessions

HQ is a personal operating system for orchestrating work across many companies, repos, workers, and AI sessions from one root directory. You are not in a single repo or product — you are in the orchestration layer that scaffolds, runs, and supervises work elsewhere. HQ is *not* a single-repo coding assistant, a one-shot workspace, or a knowledge dump.

## Purpose

### What Lives in HQ

- **companies/** — isolated tenants. Each has its own credentials, policies, knowledge, projects. Cross-company contamination is a category-1 bug.
- **repos/** — code (`repos/public/`, `repos/private/` — never elsewhere). HQ orchestrates; repos are where code actually lives.
- **personal/projects/** — personal/HQ PRDs, brainstorms, and plans that are not owned by a company.
- **companies/{co}/projects/** — company-owned PRDs, brainstorms, and plans.
- **core/workers/** — specialized agents with skills (design, content, security, deploy, …). Use them before generic Claude.
- **workspace/** — session and orchestrator state (threads, locks, drafts, reports).
- **core/knowledge/** — reusable facts, specs, playbooks. Indexed by qmd.
- **core/policies/** — auto-enforced shared rules. Loaded at session start by hooks; do not duplicate them in this file.

### Charter Rule for This File

CLAUDE.md contains exactly three things: **Purpose** (what HQ is and your role inside it) · **Rules** (always-on rules with no policy home of their own) · **Map** (pointers to commands, skills, knowledge, and the policy system).

It does NOT contain rules that have a policy home — those auto-load via SessionStart.
It does NOT contain skill help — that lives in the skill file.
It does NOT contain reference data — that lives in core/knowledge/.

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

### User-Facing Messages

Quiet by default. Silent on routine ops (install, lint, build, test, fmt) and recoverable failures — fix and continue without narrating. Surface only: user decisions, irreversible/destructive actions, security signals, blockers Claude can't self-resolve, substantive results / insights / reports. Verbose narration allowed inside `/run-project`, `/execute-task`, `/diagnose`, `/investigate`, `/tdd`, `/architect`, `/deep-plan`, `/review`, `/security-review`, `/discover`. Carveouts (URLs that must surface): `/hq-share` minting turn, `/deploy` preview. Full filter + decision tree: `.claude/policies/quiet-by-default-narration.md`.

Default chat voice is Cavebro for Claude Code and Codex: terse, warm, technically exact. Claude Code loads it from `.claude/settings.json`; Codex receives the same source through `.codex/output-style.md` plus this AGENTS.md bridge. Apply Cavebro to chat only. Files written to disk, security warnings, irreversible-action confirmations, plans, handoffs, checkpoints, policies, ADRs, deploy previews, and outbound drafts stay full prose.

### Sensitive Path Deny Lists

Sensitive paths (SSH/AWS/GPG/env/shell-rc) are Read-blocked by `.claude/settings.json` deny rules. For rc-file mutations: append-only (`printf >> file`) or pattern-delete (`sed '/pattern/d' file`) — never Read+Edit.

### Sub-Agent Rules

When spawning Task agents for story/task completion: each sub-agent MUST commit its own work before completing. The orchestrator should verify uncommitted changes after each sub-agent returns and commit them if the sub-agent failed to do so.

### Context Diet

Minimize context burn on session start:

- Do NOT read core/docs/hq/INDEX.md, agents files, or company knowledge unless task requires it
- Do NOT run qmd searches "to orient" — search only with a specific question
- For repo coding tasks: go directly to repo. HQ context rarely needed
- For worker execution: load only worker.yaml — it has its own knowledge pointers
- When unsure what to load: ask the user, don't explore
- Prefer `workspace/threads/handoff.json` (7 lines) over INDEX.md for session state

## Token Optimization

Claude Code defaults live in `.claude/settings.json`; Codex sandboxing and hook wiring live in `.codex/config.toml`.

| Setting | Value | Why |
|---------|-------|-----|
| `outputStyle` | `Cavebro` | Warm terse chat voice; keeps insights and auto-clarity carveouts. Synced to starter-kit and Codex bridge |
| `MAX_THINKING_TOKENS` | `31999` | Full fixed-budget thinking (adaptive disabled separately) |
| `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING` | `1` | Disables adaptive thinking on Opus/Sonnet 4.6 — uses fixed budget instead |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | `60` | Autocompact fires at 60%; a separate Stop-hook directive requires `/checkpoint` once at ~50% |
| `CLAUDE_CODE_SUBAGENT_MODEL` | `opus` | Subagents (Task tool) use Opus — all Claude work runs on Opus 4.6 |

Toggle thinking with Option+T.

## Hook Profiles

Runtime profiles via `HQ_HOOK_PROFILE` env var: `minimal` (safety only), `standard` (default, all hooks), `strict` (reserved). Disable individual hooks: `HQ_DISABLED_HOOKS=hook1,hook2`. Canonical hooks route through `.claude/hooks/hook-gate.sh`; Codex uses `.codex/hooks/hq-codex-hook-adapter.sh` when lifecycle hooks are wired, and `core/scripts/codex-preflight.sh` for explicit safety checks.

### Cross-Company Credential Isolation

Never fall back to another company's credentials. If the right ones fail, stop and ask. Manifest `companies/manifest.yaml` is source of truth for company-scoped fields. Full rules: `core/policies/credential-access-protocol.md` (auto-loaded).

### Image Context Isolation

Never accumulate >10 images in parent session; delegate image reads/verifications to a sub-agent that returns text only. Full rules: `core/policies/image-context-isolation.md`.

### User-Facing Decisions

Use the runtime's clickable/structured question UI for user-facing questions with selectable answers. Claude Code uses `AskUserQuestion`; Codex uses `request_user_input` when it is callable. Ask exactly one question per call, wait for the answer, update working state, then ask the next. If no structured picker is available, ask the same options as concise plain text. Full rules: `.claude/policies/decision-queue-one-at-a-time.md` and `.claude/policies/hq-codex-decision-gate-fallback.md`.

Top-level visible directories: `companies/`, `core/`, `personal/`, `repos/`, `workspace/`. Root `AGENTS.md` points at this file; `.claude/`, `.agents/`, and `.codex/` are hidden runtime entrypoints. Public HQ docs live in `core/docs/hq/`. Personal profile files and personal/HQ projects live under `personal/`. Each company is self-contained: `companies/{co}/{knowledge,settings,data,workers,repos,projects}/`. Full tree: `core/knowledge/public/hq-core/quick-reference.md`

- Verify which branch you're on before committing.
- Prefer merge over rebase when a branch is significantly behind (50+ commits).
- `--no-verify` is for hook fights only — never on main.
- Never commit to local main when intending to work on a feature branch.

---

## Map

### Key Files (load on demand)

`core/docs/hq/INDEX.md`, `core/docs/hq/USER-GUIDE.md`, `personal/agents-profile.md`, `personal/agents-companies.md`, `core/workers/registry.yaml`, `companies/manifest.yaml`. Full catalog: `core/knowledge/public/hq-core/quick-reference.md`.

### Structure

Top-level: `.claude/`, `.agents/`, `.codex/`, `AGENTS.md`, `companies/`, `core/{docs,hooks,knowledge,policies,settings,skills,workers}/` (system tree, shipped with HQ), `personal/{agents-profile.md,agents-companies.md,hooks,knowledge,policies,projects,settings,skills,workers}/` (user-personal overlay — see below), `repos/{public,private}/`, `workspace/`. Each company is self-contained: `companies/{co}/{knowledge,settings,data,workers,repos,projects}/`. Full tree: `core/knowledge/public/hq-core/quick-reference.md`.

**Personal overlay (`personal/`).** Mirrors the shape of `core/` but is user-personal. `master-sync.sh` (Stop/PostToolUse) symlinks `personal/{policies,knowledge,workers,settings}/<entry>` into `core/<type>/<entry>` — personal entries appear inside core and do *not* form a separate precedence layer. Exceptions: `personal/hooks/<event>/` is loaded as its own ordered hook layer (after `core/hooks/`, before packs), and `personal/skills/<skill>/` surfaces as `/<skill>` (the same flat command name as a core skill; Claude Code tags it with a `(project:personal)` description, the subdirectory does not become part of the command).

### Companies

Source of truth: `companies/manifest.yaml`. Each company is self-contained. Details: `core/knowledge/public/hq-core/quick-reference.md`.

Sensitive system paths are blocked from Read access via `settings.json` deny rules: `~/.ssh/**`, `~/.aws/credentials`, `~/.aws/config`, `~/.gnupg/**`, `~/.env`, `~/.netrc`, `~/.zshrc`, `~/.zprofile`, `~/.zshenv`, `~/.bashrc`, `~/.bash_profile`. These protect SSH keys, AWS credentials, GPG secrets, local environment files, and shell rc files (which may contain hardcoded API keys — see company policies for details). User can override with explicit approval when prompted. For rc-file mutations, use append-only (`printf >> file`) or pattern-delete (`sed '/pattern/d' file`) rather than Read+Edit — both avoid pulling file contents into context. Company credential isolation is handled separately by hooks (see Company Isolation section).

## Vault Share Capabilities

`/hq-share <path>...` mints an encrypted single-use share-session URL via `hq files share` and opens the browser picker for multi-recipient ACL grants. **Default behavior is to print the full URL inline in the assistant reply** — that's the minting turn and the one surface where the unredacted token is permitted. For single-recipient/scripted grants, use direct grant instead: `hq files share <prefix> --with <principal> --permission <level>`.

**Hard rule:** A share-session URL is a live, encrypted, single-use, 15-minute capability — any holder can redeem it to write ACLs in the issuer's name. After the minting turn, NEVER paste the URL into subsequent assistant turns, summaries, thread files (`workspace/threads/`), journals, learnings, commit messages, PR descriptions, Slack/email, or worker handoff payloads. Use the redacted form `https://hq.{co}.com/share-session/<TOKEN_REDACTED>` in any persisted or follow-up context. Full constraint set: `.claude/policies/hq-share-session-urls-are-capabilities.md` (enforcement: hard). Skill details: `.claude/skills/hq-share/SKILL.md`, `.claude/skills/hq-files/SKILL.md` § "Rules for Agent Workflows" #10.

### Infrastructure-First

When work implies new infrastructure, scaffold it BEFORE doing the work:

| Signal | Action |
|--------|--------|
| New company | `/newcompany {slug}` |
| New worker | `/newworker` |
| New knowledge base | `git init` (company) or `repos/public/knowledge-{name}` + symlink (shared) |
| New project | `/plan` |
| New repo | Clone to `repos/{pub\|priv}/` → manifest.yaml → qmd collection |

Post-creation: verify `manifest.yaml` and the newly-created `worker.yaml` (registry.yaml auto-regenerates via `core/scripts/generate-workers-registry.sh` on next master-sync); run `qmd update 2>/dev/null || true`; regen affected INDEX.md.

### INDEX.md System

Hierarchical INDEX.md files provide navigable directory maps. Spec: `core/knowledge/public/hq-core/index-md-spec.md`. Rebuild all: `/cleanup --reindex`. Auto-updated by checkpoint/handoff/plan/run-project.

### Search (qmd)

HQ + codebases indexed with [qmd](https://github.com/tobi/qmd). Modes: `search` (BM25), `vsearch` (semantic), `query` (hybrid+rerank), `get`/`multi-get`. Scope with `-c {collection}`. Hard rules: never Glob `prd.json`/`worker.yaml`; always pass `path:` to Glob. Full reference: `core/knowledge/public/hq-core/quick-reference.md`.

### Auto-Checkpoint

When `AUTO-CHECKPOINT REQUIRED` is injected by a PostToolUse hook, write a lightweight thread file and continue. Do NOT rebuild INDEX, run `qmd update`, or write legacy checkpoint files. When the **50% Stop banner** or **PreCompact backup** fires, run `/checkpoint` immediately without asking first. Trigger table: `core/knowledge/public/hq-core/auto-checkpoint-spec.md`.

### Session Handoffs

When preparing a session handoff: commit pending changes, write `handoff.json`, update INDEX files, create a thread file. Never enter plan mode during handoff — execute steps directly.

### Policies

Three scopes, precedence highest→lowest: `companies/{co}/policies/`, `repos/{repo}/.claude/policies/`, `core/policies/`. Auto-loaded by SessionStart hook + slash commands. Author user-personal policies in `personal/policies/` — master-sync symlinks them into `core/policies/`, so they ride the global scope (not a separate precedence layer). Spec: `core/knowledge/public/hq-core/policies-spec.md`. Template: `companies/_template/policies/example-policy.md`.

### Workers

Worker-first rule: before specialized tasks (design, content, security, data, deploy), check `core/workers/registry.yaml` (auto-generated from each `worker.yaml` by `core/scripts/generate-workers-registry.sh` on every master-sync run — do not hand-edit) and use `/run {worker} {skill}`. Per-repo design: `design.md` declares `style-pack: <id>` resolved via `core/knowledge/public/design-styles/registry.yaml`. Company-scoped brand packs (`scope: company`) live at `companies/{co}/knowledge/design-styles/packs/{id}/` and auto-load via the worker's `dynamic` context when a target company is bound. Roster + design quality refs: `core/knowledge/public/hq-core/quick-reference.md`.

### Commands & Skill Bridge

Skills are the single source of truth for slash invocations: `.claude/skills/{name}/SKILL.md` is read by Claude Code and Codex alike (Codex via `.agents/skills`). The active output style is mirrored to Codex through `.codex/output-style.md`. Coverage: `bash core/scripts/codex-skill-bridge.sh status`. Pattern: `core/knowledge/public/hq-core/codex-skill-pattern.md`.

### Knowledge Bases & Repos

Company knowledge: `companies/{co}/knowledge/`. Three valid repo patterns (embedded git, symlink, inline): `core/knowledge/public/hq-core/knowledge-taxonomy.md`.

### Learning System & Insights

60 skills in `.claude/skills/` (core only). Company/niche skills live on their owning workers. Full catalog: `core/knowledge/public/hq-core/quick-reference.md`

### E2E Testing

E2E tests verify the product works, not just the code. PRDs include optional `e2eTests` per story. Workers use the `e2e-testing` skill. Templates + infra guides: `core/knowledge/public/testing/`. Full guide: `core/knowledge/public/testing/e2e-cloud.md`.

### Skills Index

Frequently-used skills — invoke via `/<name>`. Full help lives in each skill's file.

1. **Embedded standalone `.git` dir** (most company knowledge): e.g. `companies/{company}/knowledge/`, `companies/personal/knowledge/`. HQ tracks these as orphan `160000` gitlinks — the inner repo is opaque to HQ, commits happen inside. To capture advancement: commit inside the inner repo, then `git add companies/{co}/knowledge && git commit` in HQ to bump the pointer. (HQ has no `.gitmodules` file — this is intentional, not a bug.)
2. **Symlink to `repos/private/knowledge-{co}/`** (e.g. `companies/{company}/knowledge`): tracked as `120000` symlink; edits land in the target repo.
3. **Inline files tracked by HQ git** (e.g. `core/knowledge/public/getting-started/`, `core/knowledge/public/hq-core/`, `companies/{company}/knowledge/`): simplest; no inner repo, just regular files.

When adding new knowledge: pick pattern 1 for company knowledge that will grow, pattern 2 if you want a shared clone, pattern 3 for small/shared content. Taxonomy: `core/knowledge/public/hq-core/knowledge-taxonomy.md`.

## Resource Registry

Some companies maintain a **resource registry** — a plain folder inside the company directory (`companies/{co}/registry/`) holding YAML topology files, one per persistent resource (repos, apps, services, databases, infra, packages). The registry is declared by setting `registry: companies/{co}/registry` on the company's entry in `companies/manifest.yaml`.

**Detection:** Check `companies.{co}.registry` in `manifest.yaml`. If set, the company has a registry.

**Before creating** a new repo/app/service/DB, consult the registry first:
```bash
yq '.resources[] | "  " + .id + " - " + .name + " (" + .type + ")"' companies/{co}/registry/registry.yaml
```
If a matching resource exists, reuse it rather than silently duplicating.

**After creating/renaming/deprecating** a resource, update the registry:
- Add/edit `companies/{co}/registry/resources/{id}.yaml`
- Regenerate the index: `cd companies/{co}/registry && bash scripts/generate-index.sh` (or `/sync-registry {co}`)

**Credentials never go in the shared topology** — they live in `companies/{co}/settings/resource-overrides/` (gitignored). The `resources/*.yaml` files carry topology only — no `op://` refs, no API keys, no endpoints.

**Sync across machines** is handled by `hq-sync`, not by git. The registry is not a standalone repo — it's part of the company filesystem and rides the same reconciliation path as everything else under `companies/{co}/`.

**Skill:** `.claude/skills/registry/SKILL.md` — full protocol (detect, list, pre-flight, update, deprecate, bootstrap).
**Bootstrap templates:** `.claude/skills/registry/templates/` — schema + generate-index script + README, copied into `companies/{co}/registry/` when a new registry is created.
**Command:** `/sync-registry [company]` — regenerates `registry.yaml` from `resources/*.yaml`. Runs no git actions.
**Hook (optional):** `.claude/hooks/auto-capture-registry.sh` — when `HQ_HOOK_PROFILE=standard`, writes stub resources on `gh repo create` (matched by `companies.{co}.github_org`) and `vercel deploy` (matched by `companies.{co}.vercel_team`). No-op for companies without a `registry:` declaration. In Codex, run the relevant `core/scripts/codex-preflight.sh` checks explicitly unless the hook adapter is active.

## Skills

`.claude/skills/` is the canonical skill tree and is exposed to Codex through `.agents/skills` plus the global skill bridge. Single source: `.claude/skills/<name>/SKILL.md` (used by both Claude Code and Codex). The active output style is exposed to Codex through `.codex/output-style.md`. Coverage: `bash core/scripts/codex-skill-bridge.sh status`. Full pattern: `core/knowledge/public/hq-core/codex-skill-pattern.md`.

## Search (qmd)

HQ and codebases indexed with [qmd](https://github.com/tobi/qmd) for semantic + full-text search (v1.0.0).

**Collections:** `hq-infra` (commands/skills/policies), `hq-workers` (worker defs), `hq-knowledge` (shared knowledge), `hq-projects` (PRDs) + one per company (derived from `companies/manifest.yaml`). Use `-c {collection}` to scope. Omit `-c` to search all collections.

**Commands:**
- `qmd search "<query>" --json -n 10` — BM25 keyword (fast, default)
- `qmd vsearch "<query>" --json -n 10` — semantic/conceptual
- `qmd query "<query>" --json -n 10` — hybrid BM25 + vector + re-ranking (best quality)
- `qmd get "<path>"` / `qmd multi-get "<pattern>"` — retrieve by path/glob
- Add `-c {collection}` to scope to a specific collection

**Search rules:**

| Need | Tool |
|------|------|
| HQ content by topic | `qmd search` or `qmd vsearch` |
| Code by concept | `qmd vsearch -c {collection}` |
| Project PRD / worker yaml | `qmd search` or direct Read (registry/manifest) |
| Files by path pattern | `Glob` with scoped `path:` |
| Exact pattern in code | `Grep` |

**Hard rules:** Never Glob for `prd.json`/`worker.yaml` (hook blocked). Always pass `path:` to Glob (never from HQ root). Prefer qmd for codebase exploration; Grep for exact matching. `.ignore` protects Grep from HQ root but NOT Glob. Parallel Glob calls: if one times out, ALL sibling calls die.

## Learning System

Learnings captured as policy files via `/learn` (scoped to company/repo/command/global). Use `/learn --hard` for hard-enforcement rules (formerly `/remember`). Event log: `workspace/learnings/*.json`. Before `/handoff` or `/checkpoint`, reflect and call `/learn` for reusable findings. Auto-triggered after infrastructure creation (see Infrastructure-First). Skip when nothing novel learned.

## Insights

Educational insights persist at `workspace/insights/`. Captured via `/learn`, auto-triggered by `/handoff` and `/checkpoint`. Spec: `core/knowledge/public/hq-core/insights-spec.md`.

## Git Workflow Rules

- For local HQ non-repo edits, users should not see or manage dirty HQ files. Silently autosave with `.claude/hooks/hq-autocommit.sh` after Claude Write/Edit/MultiEdit or Codex apply_patch/Edit/Write work. Skip `repos/`, embedded/symlinked knowledge repos, and specific repo work; those keep normal commit discipline.
- Always verify which branch you're on before committing.
- Prefer merge over rebase when a branch is significantly behind (50+ commits).
- If lint-staged or git hooks cause issues during merge/rebase, disable them temporarily with `--no-verify` rather than fighting through repeated failures.
- Never commit to local main when intending to work on a feature branch.

## Vercel Deployments

- Always verify the correct Vercel org/team before deploying (check with `vercel whoami` and `vercel teams ls`).
- Confirm framework detection is correct before deploying.
- If preview deploys are behind SSO, fall back to local testing immediately rather than debugging SSO.

## Learned Rules

- **NEVER**: Run Playwright/Puppeteer/Chromium in a Vercel Lambda — the 250 MB unzipped cap makes it architecturally impossible. Use ingest-only endpoints that accept pre-captured payloads from client-side callers (extensions, local scripts). <!-- back-pressure-failure | 2026-04-15 -->
- **NEVER**: Extract shared skills that require editing 5+ existing files to wire up. When extending behavior across multiple commands/skills, prefer layered independent additions (policy + command + skill edit) over shared extraction. Accept duplicated pattern tables as simpler than shared dependencies. <!-- user-correction | 2026-04-15 -->
- **NEVER**: Use relative symlinks to access pattern-2 knowledge repos from a git worktree — `../../repos/` resolves against worktree root, not HQ root. Use the canonical absolute path (`$HOME/Documents/HQ/repos/public/knowledge-{name}/`). <!-- user-correction | 2026-04-16 -->
- **ALWAYS**: Use `qmd` first for HQ search across content, indexed repos, projects, workers, policies, and knowledge. Fall back to Grep or shell search only when `qmd` is unavailable, errors, or the task is exact pattern matching in already-scoped code. <!-- user-correction | 2026-05-14 -->

## Auto-Checkpoint (PostToolUse Hook)

PostToolUse hooks detect checkpoint-worthy events and inject `AUTO-CHECKPOINT REQUIRED`. When you see this, write a lightweight thread file immediately and continue.

| Tool | Pattern | Trigger | Debounce |
|------|---------|---------|----------|
| Bash | `git commit` / `git push` | `git-commit` / `git-push` | NO |
| Bash | `gh pr create/merge` | `pr-operation` | 5min |
| Bash | `vercel deploy/--prod` | `deployment` | 5min |
| Bash | `npm/bun publish` | `package-publish` | 5min |
| Bash | `bun run test/npm test/bun test` | `test-run` | 5min |
| Bash | `curl -X POST/PUT/DELETE` | `api-mutation` | 5min |
| Edit | any file (excl. `workspace/threads/`) | `file-edit` | 5min |
| Write | `workspace/reports/`, `social-drafts/`, `companies/*/data/` | `file-generation` | 5min |

Also checkpoint after worker skill completion. Schema: `core/knowledge/public/hq-core/thread-schema.md`. Do NOT rebuild INDEX, update `recent.md`, run `qmd update`, or write legacy checkpoint files on auto-checkpoints. When edits touch knowledge files, commit to the knowledge repo — not HQ git.

## Auto-Checkpoint (Context Thresholds)

Context-usage checkpoints run in two stages. Both are mandatory checkpoint directives, not user-choice prompts.

1. **50% checkpoint (Stop hook).** `.claude/hooks/context-warning-50.sh` fires after an assistant turn when the transcript size crosses ~50% of the context window. Prints once per session (gated via `workspace/.context-warnings/{session_id}`). This intentionally leaves enough context to run `/checkpoint`, preserve state, and still orchestrate subagents for follow-up work.
2. **PreCompact backup.** `.claude/hooks/auto-checkpoint-precompact.sh` fires immediately before autocompact runs (threshold set by `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`). Autocompact cannot be blocked in Claude Code or Codex, so the banner tells the next assistant turn to run `/checkpoint` before continuing.

**When either banner appears**, run `/checkpoint` immediately. Do not ask the user first, and do not continue normal task work until the checkpoint is complete.

**Fallback (instruction-based):** If context feels heavy before either hook fires (many long turns, lots of file reads), proactively run `/checkpoint`. For end-of-session wrap-up, run `/handoff` manually.

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

**Full guide:** `core/policies/e2e-testing-standards.md` (auto-loaded hard-enforcement policy)
