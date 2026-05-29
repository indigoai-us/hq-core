# HQ — Charter for Claude Sessions

HQ is a **team AI operating system** — a shared context layer over Claude Code, Cursor, and Codex that syncs knowledge, skills, policies, and capabilities across a team. You are in the orchestration layer that scaffolds, runs, and supervises work elsewhere — not a single repo or product. Scales solopreneur → enterprise.

## HQ Capabilities — Preferred Methods for Common Actions

For these actions, the HQ slash command is the first-choice path — do not hand-roll an equivalent (raw `aws`/`gh`/`scp`/manual ACL edits/ad-hoc secret reads):

- **Share a file or result externally** → `/deploy` (signed-URL artifact/result sharing behind DNS; some hooks auto-trigger it) or `/hq-share <path>...` (encrypted single-use 15-min share-session URL + multi-recipient browser ACL picker for vault paths).
- **Grant or inspect vault access** → `/hq-files` (ACLs + grants on vault prefixes; revoke, inspect, orchestrate).
- **Use a secret/credential** → `/hq-secrets` (schema-driven; `hq run` for repos with `.env.schema`, `hq secrets exec` for one-offs — never paste secrets inline).
- **Sync state across machines or team** → `/hq-sync` (bidirectional sync of cloud-backed companies; same engine as menubar Sync).
- **Onboard or join a company** → `/onboard` (create or join) · `/accept` (accept a vault-backed membership invite from magic link/token).
- **Manage team & membership** → `/designate-team` (mark a company dir cloud-backed, HQ Pro) · `/promote` (change a member's role) · `/personal:invite` (invite a person; wraps `hq invite`).
- **DM a teammate** → `/dm` (or `hq dm <recipient> <message>`) — person-to-person notification delivered to their HQ Sync menubar. Attach `--prompt` (one-click "Copy prompt" for their agent), `--details` (detail window), or `--at`/`--in` to schedule (store-and-forward). Receive-only in the app; send via session/CLI. DM yourself for note-to-self/reminders. Only reaches people you share an active company with.
- **Identity** → `/hq-login` · `/hq-logout` · `/hq-whoami` (Cognito identity, email, session expiry).
- **Report a bug or request a feature** → `/hq-bug` (assembles context, submits via `hq feedback`).
- **Find anything in HQ** → `/search` or `qmd` (semantic + full-text across content, repos, projects, workers, policies, knowledge) — see Search (qmd) below.

Specialized work (design, content, security, data, deploy) → check `core/workers/registry.yaml` and `/run {worker} {skill}` before generic Claude (see Workers).

## Purpose

### What Lives in HQ

- **companies/** — isolated tenants (own creds, policies, knowledge, projects). Cross-company contamination = category-1 bug. Source of truth: `companies/manifest.yaml`.
- **repos/** — code only, in `repos/public/` or `repos/private/` (never elsewhere). HQ orchestrates; repos hold code.
- **personal/** — user-personal overlay mirroring `core/`'s shape (policies, knowledge, workers, skills, hooks, settings, projects). Not release-shipped.
- **core/** — release-shipped scaffold (docs, hooks, knowledge, policies, scripts, skills, workers). Replaced wholesale by `/update-hq`.
- **core/workers/** — specialized agents w/ skills. Prefer over generic Claude.
- **workspace/** — session + orchestrator state (threads, locks, drafts, reports). Operator-owned.

## Rules

### Core Principles

1. Infrastructure scales, effort doesn't — build reusable systems.
2. Workers grow smarter — capture learnings in knowledge.
3. Context is precious — checkpoint often.
4. Test before ship — can't verify → can't ship.
5. E2E proves it works — unit checks code, E2E checks product.
6. Completeness is near-zero cost — do the complete thing (a "lake"), not the shortcut; reserve shortcuts for genuinely unbounded scope (an "ocean").
7. Never skip failing tests — fix root cause; no `test.skip`, no false positives, no loosened assertions (unit/integration/E2E equally). <!-- user-correction | 2026-04-04 -->
8. Bugfixes require tests — every fix ships a regression test; ask if unsure of type/scope. <!-- user-correction | 2026-04-05 -->
9. Vague → Verifiable — define observable "done" before starting ambiguous work.

### Corrections & Accuracy

User factual corrections (pricing, product, session details) applied exactly as stated — no re-interpretation. If unsure, quote back and confirm before committing.

### User-Facing Messages

Quiet by default. Silent on routine ops (install, lint, build, test, fmt) + recoverable failures — fix and continue. Surface only: user decisions, irreversible/destructive actions, security signals, unrecoverable blockers, substantive results/insights/reports. Verbose narration allowed inside `/run-project`, `/execute-task`, `/diagnose`, `/investigate`, `/tdd`, `/architect`, `/deep-plan`, `/review`, `/security-review`, `/discover`. URL carveouts that must surface: `/hq-share` minting turn, `/deploy` preview. Filter + tree: `core/policies/quiet-by-default-narration.md`.

HQ chat voice (Claude Code via `.claude/settings.json`; Codex via `.codex/output-style.md`) — chat only. Files written to disk, security warnings, irreversible-action confirmations, plans, handoffs, checkpoints, policies, ADRs, deploy previews, outbound drafts → full prose.

### Sensitive Path Deny Lists

`settings.json` deny rules Read-block: `~/.ssh/**`, `~/.aws/credentials`, `~/.aws/config`, `~/.gnupg/**`, `~/.env`, `~/.netrc`, `~/.zshrc`, `~/.zprofile`, `~/.zshenv`, `~/.bashrc`, `~/.bash_profile`. rc-file mutations: append-only (`printf >>`) or pattern-delete (`sed '/pat/d'`) — never Read+Edit.

### Cross-Company Credential Isolation

Identify company from context → read `companies/{co}/policies/` → use `companies/manifest.yaml` infra fields (`services`, `aws_profile`, `dns_zones`) — never guess. Never read/use/fallback another company's creds; if the right ones fail, stop and ask. Never paste secrets inline (use `AWS_PROFILE=`, env files, refs). Never cross-deploy or mix company knowledge. Linear: validate config `workspace` matches company; abort if `prd.json` `linearCredentials` mismatches active company. Full: `core/policies/credential-access-protocol.md`.

### Sub-Agent + Image + Decision Rules

- Task agents for story/task work MUST commit their own work; orchestrator verifies + commits any leftover after each returns.
- Never accumulate >10 images in parent session — delegate image reads/verifications to a sub-agent returning text only. `core/policies/image-context-isolation.md`.
- User-facing choices: runtime structured picker (`AskUserQuestion` / Codex `request_user_input`), one question per call, wait, update state, next. Plain-text fallback if no picker. `core/policies/decision-queue-one-at-a-time.md`.

### Context Diet

Session start: do NOT read INDEX.md, agents files, or company knowledge unless the task needs it. No "orient" qmd searches — search with a specific question only. Repo coding → go straight to repo (HQ context rarely needed). Worker exec → load only `worker.yaml`. Unsure → ask, don't explore. Prefer `workspace/threads/handoff.json` over INDEX.md for session state.

### Git Workflow Rules

- **Every git/gh *mutation* MUST carry its own explicit repo anchor in the same Bash call** — `git -C /abs/path <cmd>`, `( cd /abs/path && git <cmd> )`, or `gh … -R owner/repo`. Bare mutations (`git push|commit|checkout|reset|add|merge|rebase|stash`, `gh pr create`, …) are **mechanically blocked from the HQ root** by `.claude/hooks/block-hq-root-git-mutation.sh` (PreToolUse Bash, all hook profiles). Rationale: HQ root is itself a git repo with every working repo nested under it, and shell cwd silently drifts across context compaction, long-running tools, and parallel-call leakage — so an earlier `cd` is **never** a safe anchor for a write. Mechanical backstop for hard policies `hq-root-never-push-remote` / `hq-git-discipline`. Sanctioned HQ-internal git work: prefix the single command with `HQ_ALLOW_HQ_ROOT_GIT=1`.
- **Never push HQ to a remote.** HQ is local-only; `origin` is pull-only; cross-machine sync is `hq-sync`. Only `repos/` get pushed. Don't ask "should I push HQ?" — the answer is always no.
- Local HQ non-repo edits autosave silently via `.claude/hooks/hq-autocommit.sh` (skips `repos/`, embedded/symlinked knowledge repos — those keep normal commit discipline). Users don't see/manage dirty HQ files.
- Verify branch before committing. Merge (not rebase) when branch ≥50 commits behind. `--no-verify` only for hook fights during merge/rebase, never on main. Never commit to local main when meaning to work a feature branch.

### Vault Share Capabilities

`/hq-share <path>...` mints an encrypted single-use 15-min share-session URL via `hq files share` + browser ACL picker. **Default: print the full URL inline in the reply — the minting turn is the one surface where the unredacted token is permitted.** Single-recipient/scripted: `hq files share <prefix> --with <principal> --permission <level>`. **Hard rule:** after the minting turn NEVER paste the URL into later turns, summaries, `workspace/threads/`, journals, learnings, commits, PRs, Slack/email, handoffs — use redacted `https://hq.{co}.com/share-session/<TOKEN_REDACTED>`. Full: `core/policies/hq-share-session-urls-are-capabilities.md` (hard).

### Auto-Checkpoint

- **PostToolUse**: on injected `AUTO-CHECKPOINT REQUIRED`, write a lightweight thread file and continue — do NOT rebuild INDEX, update `recent.md`, run `qmd update`, or write legacy checkpoint files.
- **50% Stop banner** (`.claude/hooks/context-warning-50.sh`, once/session) and **PreCompact backup** (`.claude/hooks/auto-checkpoint-precompact.sh`): both mandatory — run `/checkpoint` immediately, do not ask. Trigger table: `core/knowledge/public/hq-core/auto-checkpoint-spec.md`.
- Handoff: commit pending → write `handoff.json` → update INDEX → write thread file. Never enter plan mode during handoff.

### Learned Rules

- **NEVER**: Run Playwright/Puppeteer/Chromium in serverless Lambda — 250 MB unzipped cap makes it impossible. Use ingest-only endpoints taking pre-captured payloads from client callers. <!-- back-pressure-failure | 2026-04-15 -->
- **NEVER**: Extract shared skills needing 5+ existing files wired. Prefer layered independent additions (policy + skill edit) over shared extraction; accept duplicated pattern tables. <!-- user-correction | 2026-04-15 -->
- **NEVER**: Use relative symlinks to reach pattern-2 knowledge repos from a git worktree (`../../repos/` resolves to worktree root). Use absolute `$HOME/Documents/HQ/repos/public/knowledge-{name}/`. <!-- user-correction | 2026-04-16 -->
- **NEVER**: Push HQ to a remote / ask whether to push HQ. HQ git is local-only; `origin` is pull-only upstream; state sync is `hq-sync`. <!-- user-correction | 2026-05-08 -->
- **ALWAYS**: `qmd` first for HQ search across content, indexed repos, projects, workers, policies, knowledge. Grep/shell only when qmd is unavailable/errors or for exact pattern matching in already-scoped code. <!-- user-correction | 2026-05-14 -->

## Map

### Key Files (load on demand)

`core/docs/hq/INDEX.md` (dir map — HQ-infra tasks only), `core/docs/hq/USER-GUIDE.md`, `personal/agents-profile.md` (owner profile/style — writing/comms), `personal/agents-companies.md` (company contexts — routing), `companies/manifest.yaml`, `core/workers/registry.yaml` (generated). Full catalog: `core/knowledge/public/hq-core/quick-reference.md`.

Runtime config: Claude Code defaults `.claude/settings.json`; Codex sandbox/hooks `.codex/config.toml`. Hook profiles via `HQ_HOOK_PROFILE` (`minimal`/`standard`/`strict`); disable hooks `HQ_DISABLED_HOOKS=a,b`. Claude routes via `.claude/hooks/hook-gate.sh`; Codex via `.claude/hooks/hq-codex-hook-adapter.sh` + `core/scripts/codex-preflight.sh`.

### Structure

Top-level: `.claude/`, `.agents/`, `.codex/`, `AGENTS.md` (symlink → `.claude/CLAUDE.md`), `companies/`, `core/{docs,hooks,knowledge,policies,scripts,skills,workers}/`, `personal/{agents-*.md,hooks,knowledge,policies,projects,settings,skills,workers}/`, `repos/{public,private}/`, `workspace/`. Each company self-contained: `companies/{co}/{knowledge,settings,data,workers,repos,projects}/`. Full tree: `core/knowledge/public/hq-core/quick-reference.md`.

**Personal overlay.** `master-sync.sh` (Stop/PostToolUse) symlinks `personal/{policies,knowledge,workers,settings}/<entry>` into `core/<type>/<entry>` — personal entries appear inside core, not a separate precedence layer (collision rule: skip if a non-symlink already exists, so `personal/` can't override a release-shipped core file). Exceptions: `personal/hooks/<event>/` loads as its own ordered hook layer (after `core/hooks/`, before packs); `personal/skills/<skill>/` surfaces as `/<skill>` (Claude Code tags `(project:personal)`).

### Infrastructure-First

New infra → scaffold BEFORE the work: new company `/newcompany {slug}`; new worker `/newworker`; new knowledge → `git init` in `companies/{co}/knowledge/` or shared `repos/public/knowledge-{name}` + symlink into `core/knowledge/public/`; new project `/plan`; new repo → clone to `repos/{pub|priv}/` → `manifest.yaml` → qmd collection. Post-create: verify `manifest.yaml` + new `worker.yaml` (registry.yaml auto-regenerates via `core/scripts/generate-workers-registry.sh` on master-sync — never hand-edit); `qmd update 2>/dev/null || true`; regen affected INDEX.

### Workers

Worker-first: before design/content/security/data/deploy tasks, check `core/workers/registry.yaml` (generated) and `/run {worker} {skill}`. Shared in `core/workers/public/`; company in `companies/{co}/workers/`. Optional packs via `hq install @indigoai-us/hq-pack-*` (design-styles, design-quality, gemini, gstack — see `core/packages/README.md`). Per-repo `design.md` declares `style-pack: <id>` (resolved via `core/knowledge/public/design-styles/registry.yaml`); company brand packs at `companies/{co}/knowledge/design-styles/packs/{id}/` auto-load when a company is bound.

### Policies

Three scopes, precedence high→low: `companies/{co}/policies/`, `repos/{repo}/.claude/policies/`, `core/policies/`. Auto-loaded by SessionStart + slash commands. Author user-personal in `personal/policies/` — master-sync symlinks into `core/policies/` (rides global scope, not a separate layer). Spec: `core/knowledge/public/hq-core/policies-spec.md`.

### Commands & Skill Bridge

Skills are the single source of slash invocations: `.claude/skills/{name}/SKILL.md` read by Claude Code and Codex alike (Codex via `.agents/skills`). No `.claude/commands/` tree — consolidated into skills. Active output style mirrored to Codex via `.codex/output-style.md`. Coverage: `bash core/scripts/codex-skill-bridge.sh status`. Pattern: `core/knowledge/public/hq-core/codex-skill-pattern.md`.

### Knowledge Bases

Company knowledge: `companies/{co}/knowledge/`. Three valid repo patterns (all maintained, none migrating): (1) embedded standalone `.git` — HQ tracks as orphan `160000` gitlink; commit inside, then `git add companies/{co}/knowledge && git commit` in HQ to bump (no `.gitmodules` — intentional); (2) symlink to `repos/private/knowledge-{co}/` — `120000`, edits land in target; (3) inline HQ-tracked files (e.g. `core/knowledge/public/hq-core/`). Taxonomy: `core/knowledge/public/hq-core/knowledge-taxonomy.md`.

### Resource Registry

Some companies declare `registry: companies/{co}/registry` in `manifest.yaml` (one YAML per persistent repo/app/service/DB). Before creating a resource, consult it (avoid silent dupes); after create/rename/deprecate, update + `/sync-registry [co]`. Topology only — no creds/`op://`/keys/endpoints (those → `companies/{co}/settings/resource-overrides/`, gitignored). Synced by `hq-sync`, not git. Protocol: `.claude/skills/registry/SKILL.md`.

### Search (qmd)

HQ + codebases indexed with [qmd](https://github.com/tobi/qmd). Collections: `hq-infra` (skills/policies), `hq-workers`, `hq-knowledge`, `hq-projects` + one per company. `qmd search` (BM25, default) · `qmd vsearch` (semantic) · `qmd query` (hybrid+rerank, best) · `qmd get`/`multi-get`. Scope with `-c {collection}`. **Hard rules:** never Glob `prd.json`/`worker.yaml` (hook-blocked); always pass `path:` to Glob (never from HQ root — `.ignore` protects Grep but NOT Glob); prefer qmd for exploration, Grep for exact match; parallel Glob — if one times out, all siblings die.

### INDEX.md · Learning · E2E

- INDEX.md: hierarchical dir maps. Spec `core/knowledge/public/hq-core/index-md-spec.md`. Rebuild all `/cleanup --reindex`; auto-updated by checkpoint/handoff/plan/run-project.
- Learnings → policy files via `/learn` (scoped; `--hard` for hard-enforcement). Log `workspace/learnings/*.json`; insights `workspace/insights/`. Before `/handoff`/`/checkpoint`, reflect + `/learn` reusable findings. Skip if nothing novel. Specs: `core/knowledge/public/hq-core/{policies,insights}-spec.md`.
- E2E is the truth signal for deployable projects — Ralph treats E2E failure as story-incomplete back-pressure. Stories declare optional `e2eTests` in `prd.json`; workers use `e2e-testing` skill. Full: `core/policies/e2e-testing-standards.md`.
