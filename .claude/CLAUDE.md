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

Sensitive system paths are blocked from Read access via `settings.json` deny rules: `~/.ssh/**`, `~/.aws/credentials`, `~/.aws/config`, `~/.gnupg/**`, `~/.env`, `~/.netrc`, `~/.zshrc`, `~/.zprofile`, `~/.zshenv`, `~/.bashrc`, `~/.bash_profile`. These protect SSH keys, AWS credentials, GPG secrets, local environment files, and shell rc files (which may contain hardcoded API keys — see company policies for details). User can override with explicit approval when prompted. For rc-file mutations, use append-only (`printf >> file`) or pattern-delete (`sed '/pattern/d' file`) rather than Read+Edit — both avoid pulling file contents into context. Company credential isolation is handled separately by hooks (see Company Isolation section).

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

**Shared** (`workers/public/`): frontend-designer, qa-tester, security-scanner, pretty-mermaid, exec-summary, accessibility-auditor, performance-benchmarker, dev-team (frontend-dev, motion-designer, context-manager, reality-checker, backend-dev) + content-team (5) + social-team (5) + gardener-team (3) + knowledge-tagger + site-builder + ascii-artist + paper-designer.
**Company** (`companies/{co}/workers/`): per-company workers listed in `workers/registry.yaml`.

**Optional packs** (install via `hq install @indigoai-us/hq-pack-*`): design-styles (curated style packs), design-quality (typography/color/spatial/motion references), gemini (6 gemini-* workers + gemini-cli knowledge — requires `gemini` on PATH), gstack (gstack-team + 26 g-* skills). See `packages/README.md`.

**Per-repo design context:** `design.md` at repo root. Declares `style-pack: <id>` in the Design Direction section. Workers resolve the pack via `knowledge/public/design-styles/registry.yaml` (shipped by the `design-styles` pack) → pack directory → `context_paths.required`. Pack schema: `knowledge/public/design-styles/PACK-SCHEMA.md`. Design quality references live in `knowledge/public/design-quality/` (shipped by the `design-quality` pack).

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

Parent session should never accumulate >10 images. When reading/verifying image files (.png/.jpg/.jpeg/.gif/.webp), delegate to a sub-agent: spawn agent with "Read {path} and describe: dimensions, content, visual quality, issues. Return text only." Mandatory for batch image verification and images >1500px. Full rules: `.claude/policies/image-context-isolation.md`

## File Locking

Story-scoped file flags prevent concurrent edit conflicts. Config: `settings/orchestrator.yaml`. Stories declare `files: []` in prd.json. `/execute-task` acquires locks in `{repo}/.file-locks.json` + state.json `checkedOutFiles` on start, releases on completion/failure. `/run-project` skips conflicting stories during task selection (configurable: `hard_block`, `soft_block`, `read_only_fallback`). Stale locks (dead PID + timeout) auto-cleaned.

**Repo Coordination (cross-session):** Repo-level active-run registry at `workspace/orchestrator/active-runs.json` prevents sibling sessions from editing a repo while `/run-project` owns it. Enforced by `scripts/repo-run-registry.sh` + SessionStart banner (`check-repo-active-runs.sh`) + PreToolUse hard block (`block-on-active-run.sh`). Blocks Edit/Write/destructive-Bash against owned repos with exit code 2; Read/Grep/Glob/`git status` always allowed. Config: `settings/orchestrator.yaml` → `repo_coordination:`. Bypass (emergency only): `HQ_IGNORE_ACTIVE_RUNS=1` — audit to `workspace/learnings/active-run-bypasses.jsonl`. Policy: `.claude/policies/repo-run-coordination.md`. Composes above story-level `.file-locks.json` without regression.

## Commands

30 commands in `.claude/commands/` (core only). Company/niche commands live on their owning workers. Full catalog: `knowledge/public/hq-core/quick-reference.md`

## Knowledge Bases

Public: listed in `modules/modules.yaml` (filter `access: public`). Company-level: each at `companies/{co}/knowledge/`. Full list: `knowledge/public/hq-core/quick-reference.md`

## Knowledge Repos

Knowledge folders use three patterns — all valid, none being migrated:

1. **Embedded standalone `.git` dir** (most company knowledge): e.g. `companies/{company}/knowledge/`, `companies/personal/knowledge/`. HQ tracks these as orphan `160000` gitlinks — the inner repo is opaque to HQ, commits happen inside. To capture advancement: commit inside the inner repo, then `git add companies/{co}/knowledge && git commit` in HQ to bump the pointer. (HQ has no `.gitmodules` file — this is intentional, not a bug.)
2. **Symlink to `repos/private/knowledge-{co}/`** (e.g. `companies/{company}/knowledge`): tracked as `120000` symlink; edits land in the target repo.
3. **Inline files tracked by HQ git** (e.g. `knowledge/public/gemini-cli/`, `knowledge/public/getting-started/`, `companies/{company}/knowledge/`): simplest; no inner repo, just regular files.

When adding new knowledge: pick pattern 1 for company knowledge that will grow, pattern 2 if you want a shared clone, pattern 3 for small/shared content. Register in `modules/modules.yaml`. Taxonomy: `knowledge/public/hq-core/knowledge-taxonomy.md`.

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
**Hook (optional):** `.claude/hooks/auto-capture-registry.sh` — when `HQ_HOOK_PROFILE=standard`, writes stub resources on `gh repo create` (matched by `companies.{co}.github_org`) and `vercel deploy` (matched by `companies.{co}.vercel_team`). No-op for companies without a `registry:` declaration.

## Skills

`.claude/skills/` is the canonical skill tree. Codex bridge: `scripts/codex-skill-bridge.sh install`. Dual-format: `command.md` (Claude Code) + `SKILL.md` (Codex). 12 promoted skills (Codex-ready). Coverage: `bash scripts/codex-skill-bridge.sh status`. Full pattern: `knowledge/public/hq-core/codex-skill-pattern.md`.

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

## Learned Rules

- **NEVER**: Run Playwright/Puppeteer/Chromium in a Vercel Lambda — the 250 MB unzipped cap makes it architecturally impossible. Use ingest-only endpoints that accept pre-captured payloads from client-side callers (extensions, local scripts). <!-- back-pressure-failure | 2026-04-15 -->
- **NEVER**: Extract shared skills that require editing 5+ existing files to wire up. When extending behavior across multiple commands/skills, prefer layered independent additions (policy + command + skill edit) over shared extraction. Accept duplicated pattern tables as simpler than shared dependencies. <!-- user-correction | 2026-04-15 -->
- **NEVER**: Use relative symlinks to access pattern-2 knowledge repos from a git worktree — `../../repos/` resolves against worktree root, not HQ root. Use the canonical absolute path (`$HOME/Documents/HQ/repos/public/knowledge-{name}/`). <!-- user-correction | 2026-04-16 -->

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

Also checkpoint after worker skill completion. Schema: `knowledge/public/hq-core/thread-schema.md`. Do NOT rebuild INDEX, update `recent.md`, run `qmd update`, or write legacy checkpoint files on auto-checkpoints. When edits touch knowledge files, commit to the knowledge repo — not HQ git.

## Auto-Checkpoint (Two-Stage Advisory)

Context-usage advisories run in two stages. Both present the same three options (checkpoint, handoff, or continue) — neither forces action.

1. **60% advisory (Stop hook).** `.claude/hooks/context-warning-60.sh` fires after an assistant turn when the transcript size crosses ~60% of the context window. Prints once per session (gated via `workspace/.context-warnings/{session_id}`). Purely informational — runway still exists before autocompact.
2. **75% advisory (PreCompact hook).** `.claude/hooks/auto-checkpoint-precompact.sh` fires immediately before autocompact runs (threshold set by `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=75`). Autocompact cannot be blocked in Claude Code, so the banner surfaces options right before compaction proceeds.

**When either banner appears**, present the 3 options to the user and wait for their decision. Do not auto-run `/checkpoint`; let the user pick.

**Fallback (instruction-based):** If context feels heavy (many long turns, lots of file reads), proactively suggest `/checkpoint` or `/handoff`. For end-of-session wrap-up, run `/handoff` manually.

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
