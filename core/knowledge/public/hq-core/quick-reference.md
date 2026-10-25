---
type: reference
domain: [operations, engineering]
status: canonical
tags: [quick-reference, directory-structure, commands, workers, knowledge-bases]
relates_to: [knowledge/public/hq-core/hq-product-model.md, knowledge/public/hq-core/hq-cli-reference.md]
---

# HQ Quick Reference

## Product surfaces

HQ is the folder plus the `hq` CLI, the desktop app, the console
(hq.computer), bots and agents, chat-app connectors, deploy, and cloud sync.
Map and "which surface for which task": [hq-product-model.md](hq-product-model.md).

| Topic | Reference |
|---|---|
| Every `hq` command (generated) | [hq-cli-reference.md](hq-cli-reference.md) |
| Sync, vaults, company lifecycle | [hq-sync-model.md](hq-sync-model.md) |
| Bots and agents | [agents-and-bots.md](agents-and-bots.md), [external-agents-mcp.md](external-agents-mcp.md) |
| Console pages | [hq-console.md](hq-console.md) |
| Plans and billing (usage card for new signups from 2026-10-16; legacy plans for existing customers) | [plans-and-pricing.md](plans-and-pricing.md), [pricing.json](pricing.json) |
| Desktop app | [hq-desktop-app.md](hq-desktop-app.md) |
| Deploy | [deploy SKILL.md](../../../../.claude/skills/deploy/SKILL.md) |

## Directory Structure

```
HQ/
├── .claude/commands/   # Slash commands
├── AGENTS.md           # Runtime entrypoint (symlink to .claude/CLAUDE.md)
├── companies/          # Company-scoped resources (registry: companies/manifest.yaml)
│   └── {co}/
│       ├── knowledge/  # Plain company directory, synced through its vault
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
│   │   ├── public/     # Bundled real directories tracked by hq-core
│   │   └── private/    # Private real directories when configured
│   ├── policies/       # Cross-cutting + command-scoped policies
│   ├── settings/       # Orchestrator config
│   ├── skills/         # Core skills (surface as /<skill>)
│   └── workers/
│       └── public/     # Shareable workers (dev-team, content-*, social-*, gardener-*, gemini-*, etc.)
├── personal/           # User-personal overlay (mirrors core/ shape)
│   ├── hooks/          # Always-on user-global hooks (loaded AFTER core/hooks)
│   ├── projects/       # Personal/HQ project PRDs and brainstorms
│   ├── knowledge/      # Read directly from personal/ (no core/ mirror)
│   ├── policies/       # Read directly by the policy trigger hook (no core/ mirror)
│   ├── settings/       # Read directly from personal/ (no core/ mirror)
│   ├── skills/         # Surface as /<skill> with (project:personal) tag
│   └── workers/        # Read directly from personal/ (no core/ mirror)
├── repos/
│   ├── public/         # Open-source code repos
│   └── private/        # Private code repos
└── workspace/
    ├── checkpoints/    # Session saves
    ├── orchestrator/   # Ralph loop workflow state
    ├── reports/        # Generated reports
    └── threads/        # Session threads + handoff.json
```

**Personal overlay semantics.** `personal/` mirrors the shape of `core/` but is user-personal authoring space. The old reindex symlink mirror into `core/` was **retired** — `personal/{knowledge,policies,settings,workers}` are now read DIRECTLY from `personal/` by the code that consumes each (the policy trigger hook, the workers-registry generator, the session/knowledge readers), and reindex prunes any leftover mirror symlinks:

| Subdir | Runtime behavior |
|---|---|
| `personal/hooks/<event>/*.sh` | **Loaded as a separate ordered layer** — runs after `core/hooks/<event>/` and before `core/packages/*/hooks/<event>/` |
| `personal/skills/<skill>/SKILL.md` | Surfaces as `/<skill>` — same flat command name as a core skill. Claude Code's `.claude/commands/<subdir>/<name>.md` surfacing puts the subdirectory in the command *description* (`(project:personal)`), not the command name. Collisions with a core skill of the same name are won by whichever ordering Claude Code resolves first; rename your personal skill to disambiguate. |
| `personal/knowledge/<entry>` | Read directly from `personal/knowledge/` (no `core/` mirror) — loads alongside core |
| `personal/policies/<entry>` | Read directly by the policy trigger hook (no `core/policies/` mirror) — loads as global; NOT a separate precedence layer |
| `personal/workers/<entry>` | Walked directly by the workers-registry generator (no `core/workers/` mirror) — surfaces as a worker |
| `personal/settings/<entry>` | Read directly from `personal/settings/` (no `core/settings/` mirror) |

Collision rule: with the mirror retired there is no link path to collide on. Both the personal and the core copy are read; a consumer that dedups by identity resolves same-id twins with personal first (e.g. the policy trigger hook scans `personal/policies/` ahead of `core/policies/`, so an operator's global rule wins over a same-id core copy).

## Companies

Companies differ per install. Read `companies/manifest.yaml` for the list of
companies on this machine and their cloud state (`cloud_uid` when
cloud-backed). Each company's workers, repos, knowledge, and policies live
under `companies/{co}/`, which follows `companies/_template/`.

### Manifest owner fields

Each entry under `companies:` may carry three optional keys that describe the
owner's relationship to the company. The SessionStart banner
(`.claude/hooks/inject-local-context.sh`) groups the `Companies` list by them
so sessions do not assume the owner is staff at every company listed.

| Key | Values | Banner effect |
|---|---|---|
| `owner_role` | `self`, `operate`, `side`, `client`, `family`, `system`, `unclassified` | One line per role: `Self`, `Jobs (operate)`, `Side projects`, `Client / consulting`, `Family`, `Unclassified (confirm)`. `system` entries (scaffold such as `workspace`) are hidden. A missing role counts as `unclassified`. |
| `owner_status` | `active`, `slow-burn`, `on-hold`, `handover-pending`, `review` | `on-hold` adds `(hold)` and `handover-pending` adds `(handover)` after the slug. Other values print nothing. |
| `owner_note` | free text | Not printed; context for operators reading the manifest. |

A top-level `owner_summary: "<one line>"` prints as `Owner jobs: <one line>`
under the groups. Omit it and the line is omitted. Example:

```yaml
owner_summary: "CEO at Acme (acme), Co-CEO at Beta (beta). Not Gamma staff."
companies:
  acme:
    owner_role: operate
    owner_status: active
    owner_note: 'Day job.'
  gamma:
    owner_role: client
    owner_status: handover-pending
```

Regression test: `.claude/hooks/tests/inject-local-context-owner-groups.test.sh`.

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

## Commands

Slash commands live in `.claude/commands/` and `.claude/skills/`; packs and
companies add more. The list below is the common set, not a full inventory.

**Session:** `/startwork`, `/reanchor`, `/checkpoint`, `/handoff`, `/recover-session`, `/remember`, `/learn`
**Handoff:** `/delegate <recipient> [project]` — transfer a project to a person or fleet agent: vault grants (verified), branch push, secrets by name, board + work-mesh reassignment, and a self-pulling pickup DM (no `/hq-sync` needed on their side). Skill: `.claude/skills/delegate/SKILL.md`; manifest spec: `core/knowledge/public/hq-core/delegation-bundle-spec.md`.
**Workers:** `/run`, `/newworker`
**Projects:** `/prd`, `/run-project`, `/execute-task`, `/understand-project`, `/idea`, `/goals`, `/dashboard`, `/tdd`, `/quality-gate`
**System:** `/cleanup`, `/garden`, `/search`, `/search-reindex`, `/harness-audit`, `/model-route`, `/update-hq`
**Company:** `/newcompany`, `/personal-interview`, `/onboard`, `/new-hire`, `/new-agent`
**HQ services:** `/hq-sync`, `/hq-files`, `/hq-share`, `/hq-secrets`, `/hq-integrations`, `/dm`
**Ship:** `/pr` (pull request operations), `/deploy` (publish an artifact; there is no `hq deploy` command)

## Script: `hq-storage.sh` (autosave history size, big files, prune)

Autosave commits every edit into the HQ root repo and nothing prunes it.
`core/scripts/hq-storage.sh` reports the size, replaces big files in history
with cloud pointers, and squashes old history. Moving big files to the cloud
is the main way to free space; the date cutoff (`prune`) is secondary.

- `bash core/scripts/hq-storage.sh large --json [--min-bytes N]` — blobs above
  the threshold (default 50 MiB, env `HQ_OFFLOAD_MIN_BYTES`) anywhere in
  history, with `bytes`, `disk_bytes`, `paths`, `last_seen_at`, `in_head`; and
  current files above it with `mtime` and `idle_days`. `*.hqcloud`
  placeholders are not listed.
- `bash core/scripts/hq-storage.sh strip-large --manifest m.json --yes` —
  manifest `{"blobs":[{"sha","pointer_text"}]}`, written by `hq storage
  offload` only after it verified each upload. Replaces each listed blob in
  every commit with its pointer text (one `git fast-export | filter |
  fast-import` pass), keeps every commit, author, date and message, and
  re-points branches, tags and extra refs to the rewritten commits. Each
  pointer must start with `HQ-CLOUD-FILE v1`, and its `git-blob:` and `size:`
  lines must match the blob, or the run stops before changing anything. A
  pointer carries one path: the CLI uses the blob's first path (`paths[0]`
  from `large`), so a blob stored at several paths shows that one path
  everywhere. Blobs in HEAD's tree or any index are never replaced; they are
  listed in `skipped_current`. Refuses when a branch checked out in a linked
  worktree holds a listed blob. Verifies the ref set, commit count, commit
  metadata and the HEAD tree, and restores every ref if a check fails. Never
  touches working-tree files or the index. Expires reflogs except
  `refs/stash`, then `git gc --prune=now`. Holds the autosave lock.
- Recovery point (strip-large and prune): before any ref moves, every ref is
  copied under `refs/hq-storage/backup/<epoch>-<pid>/`. The old history stays
  on disk until a later run after the grace period
  (`HQ_STORAGE_BACKUP_GRACE_HOURS`, default 24) or `hq-storage.sh
  drop-backups` deletes the backup; output has `backup_ref` and
  `reclaim_after` (ISO date). `--no-backup` frees the space at once with no
  undo. `drop-backups --expired` drops only backups past the grace period.
- Every subcommand accepts `--json` (output is always JSON).
- Autosave (`.claude/hooks/hq-autocommit.sh` and the Bash sweep) never commits
  a file above `HQ_OFFLOAD_MIN_BYTES`. The skip is logged once per path and size
  in `workspace/logs/hq-autocommit.log`. `*.hqcloud` placeholders are always
  committed.

- `bash core/scripts/hq-storage.sh report --json` — git dir size, tracked file
  size, commit count, and five age tranches (7d, 30d, 90d, 365d, older) with
  commit counts and an estimate of reclaimable bytes. The estimate uses the same
  keep-set as prune: blobs that another branch, a tag or the stash still reaches
  count as kept. `holding_refs` (`[{name, commit_date}]`) and
  `holding_refs_count` list those refs when they share history with HEAD.
  `git_dir_bytes` comes from `git count-objects -v`. The history part is cached
  for 10 minutes (`HQ_STORAGE_CACHE_TTL`) under `workspace/.storage-cache/`;
  `--no-cache` skips it.
- `bash core/scripts/hq-storage.sh prune --before YYYY-MM-DD --dry-run` — JSON
  with `would_remove_commits`, `est_bytes`, `flattened_merges`, `retained_refs`,
  `holding_refs`, `holding_refs_count`, `refs_to_remove`, and
  `refs_to_remove_sample` (up to 5 names). `est_bytes`
  counts only objects that nothing kept (branches, tags, stash) still reaches.
  `report --json` also has `extra_refs`, the count of refs prune would delete
  or move.
- `bash core/scripts/hq-storage.sh prune --before YYYY-MM-DD --yes` — squashes
  every commit before the cutoff into one root commit, replays newer commits
  byte-for-byte (merges are flattened to their first parent, same tree), moves
  the branch, then expires reflogs except `refs/stash` (every stash entry is
  kept) and runs `git gc --prune=now`. The new commits are built in one batch
  (about 45 s for 25,000 kept commits including gc). Refuses with exit 4 when
  `est_bytes` is 0, naming the refs that hold the old history, unless
  `--force`. Holds the autosave lock and refuses with staged changes, an
  in-progress rebase or merge, a detached HEAD, remote-tracking branches, or
  the branch checked out in another worktree. Extra refs (anything outside
  `refs/heads/`, `refs/tags/`, `refs/remotes/`, and `refs/stash`, such as
  `refs/cmux/last-turn/*` and `refs/original/*`) are moved to the rewritten
  commit when they point at a kept commit on the branch, and deleted otherwise.
  Other branches, tags, and stash are left alone and keep the objects they
  reach, so a branch or tag forked from old history keeps that history on disk.

## CLI: `hq mesh` (Work Mesh Live)

Presence and per-turn activity are automatic via hooks + `hq mesh daemon`. Manual verbs only: `task-status`, `blocked`, `note`. See `core/knowledge/public/hq-core/work-mesh-live.md` and `core/skills/work-mesh/`.

| Command | Use |
|---------|-----|
| `hq mesh daemon install\|status\|doctor` | Resident presence + spool flush (replaces pack listen) |
| `hq mesh context reconcile` (`--observation-file`/`--observation-json`) | Resolve company/project (no `--session`) |
| `hq mesh context organize\|correct\|untracked` (`--session` / sessionId arg) | Bind, correct, or mark untracked |
| `hq mesh context default get\|set\|clear` | Device default company |
| `hq mesh session task-status\|blocked\|note\|flush` (`--session-id`) | Discrete Board signals |

## CLI: `hq fingerprint` (session fingerprints)

Commits and PRs made from an HQ session carry `HQ-Fingerprint: hqfp1:<company>:<identity>:<machine>:<session>`. No trailer means no fingerprint. Guide: `core/docs/hq/USER-GUIDE.md#session-fingerprints`.

| Command | Use |
|---------|-----|
| `hq fingerprint <value> [--json]` | Resolve a fingerprint (local records, then the HQ registry). Exit 0 found, 1 no record, 2 not an HQ fingerprint |
| `hq fingerprint self [--json] [--offline] [--no-register]` | Print this session's fingerprint; registers it once per session unless `--no-register`. Always exits 0 |
| `bash core/scripts/hq-fingerprint-hooks.sh status\|enable [--replace]\|disable [--dry-run]` | Commit trailer hook. `disable` writes `enabled: false` to `personal/settings/fingerprint.yaml`. Exit 0 ok, 2 usage or setup error |
| `bash core/scripts/hq-pr-create.sh [gh pr create args...]` | `gh pr create` with the fingerprint footer |

## CLI: `hq files` (vault sharing)

Not slash commands — direct CLI surface for HQ vault access control. Skill: `.claude/skills/hq-files/SKILL.md`.

| Command | Use |
|---------|-----|
| `hq files share <prefix>...` | Browser flow — multi-recipient share-session page (no `--with` flag) |
| `hq files share <prefix> --no-open` | Browser flow but print URL instead of launching |
| `hq files share <prefix> --with <email\|grp_*\|@all> --permission <read\|write>` | Direct grant |
| `hq files unshare <prefix> --with <principal>` | Revoke (idempotent) |
| `hq files acl <prefix>` | Inspect ACL + your effective permission |
| `hq access <path-or-query>` | Cannot find or open a file? Reports never-existed / not-synced / no-access (exit 2/0/3), fetches + pins when you have access, otherwise asks the grantor via DM after one confirmation. Skill: `/hq-access`. hq-cli >= 5.109.0 |

Share-session URLs are encrypted single-use 15-minute capabilities — never persist them in commits, threads, or logs. See `core/policies/hq-share-session-urls-are-capabilities.md`.

## CLI: `hq db` (vault databases)

Local SQLite per company (always) + optional remote Postgres-class on a paid plan. On the legacy plans that is **HQ Workforce** (internal id `paid-500`, existing customers only; closed to new signups from 2026-10-16). For accounts on the usage card, relay what HQ returns. Billing is live. Guide: `core/knowledge/public/hq-core/vault-databases.md`. Requires `@indigoai-us/hq-cli` ≥ 5.62.0.

| Command | Use |
|---------|-----|
| `hq db status --company {co}` | Ensure local `~/.hq/db/{co}/vault.db` (WAL); report schema version |
| `hq db sql --company {co} -- 'SELECT …'` | Query local DB (read-only default; `--write` for mutations) |
| `hq db migrate --company {co} --hq-root {HQ}` | Apply `companies/{co}/db/migrations/*.sql` |
| `hq db provision --company {co}` | Remote binding — paid plan only (legacy: HQ Workforce) |
| `hq db usage --company {co} --app {app}` | App database usage, included amounts, ceiling and estimated charge |
| `hq db sql --company {co} --app {app} -- '…'` | SQL against an app's database (read-only unless `--write`) |
| `hq db dump --company {co} --app {app}` | Export an app's database to a SQL file |
| `hq db destroy --company {co} --app {app}` | Delete an app's database now (owner or admin, typed confirmation) |
| `hq db sql --company {co} --remote -- '…'` | Flag exists but always fails today (no remote executor wired); use local SQL |

App databases (`database: true` on a deploy, `@hq/db`, `db/migrations/`): Team plan, $10 a month per app with 250k DPU and 1 GB included, read-only at 4x, 30-day retention after delete. Details: `app-databases.md`.

Migrations are vault **text**; binary `.db` files stay machine-local (never under `companies/`). Never print connection strings. Local and remote are not auto-replicated in v1.

## CLI: `hq dm` (direct messages)

Full messaging: DMs, group messages, channels, and threads, in the HQ Desktop App (macOS and Windows) or from a session. Skill: `.claude/skills/dm/SKILL.md` (`/dm`).

| Command | Use |
|---------|-----|
| `hq dm <recipient-or-channel> "<message>"` | Send to a person (email, `prs_*`), bot, or channel |
| `hq dm <r> "<m>" --prompt "<ctx>"` | Attach agent context — recipient gets a one-click "Copy prompt" action |
| `hq dm <r> "<m>" --details "<text>"` / `--details-file <path>` | Longer text shown in an "Open details" view |
| `hq dm <r> "<m>" --at <iso>` / `--in <30s\|10m\|2h\|1d>` | Schedule delivery (store-and-forward) |
| `hq dm inbox` | Recent incoming messages |
| `hq dm thread <person>` (alias `read`) | Two-way conversation with a person or bot |
| `hq dm channel <name>` (alias `history`) | Recent messages in a channel or group DM; `hq channels` lists them |
| `hq dm requests` / `accept` / `decline` / `block` | Connection requests from people outside your companies |

DM your own email for a note-to-self or reminder. Never put secrets in a DM (stored server-side).

## Command ↔ Skill Shapes

Every command exists as `.claude/commands/{name}.md` (the slash-command entry point) and most have a paired `.claude/skills/{name}/SKILL.md` (the Skill-tool canonical logic). Two valid shapes:

**Consolidated (default for new commands)** — `.md` is a ~20-line delegator stub, `SKILL.md` holds the canonical logic. One source of truth, no drift. Converted pairs (Phase 3.1 audit): `search`, `audit-log`, `brainstorm`, `startwork`, `plan`, `handoff`, `learn`, `execute-task`.

**Thin-router split (only one)** — `run-project`. The `.md` is the canonical docs/flags/examples source (622 lines). The `SKILL.md` is a ~66-line bash wrapper that execs `core/scripts/run-project.sh`. They stay forked because one is human-facing documentation and the other is a dispatch shim — different jobs, neither redundant.

**Intentional exceptions (metadata stubs, no SKILL.md)** — `review`, `investigate`, `retro`, `document-release`, `review-plan`. These are frontmatter-only commands that dispatch prompts; no skill logic to split.

**Rule for new commands:** start with the consolidated shape — write the canonical logic in `SKILL.md`, leave `.md` as a stub copying `.claude/commands/startwork.md`'s shape (frontmatter → H1 → intro → `## Steps` → `## After`). Only fork if you have a genuine thin-router reason like `run-project`.

## Pricing and Billing

What HQ costs and how billing works: `core/knowledge/public/hq-core/pricing-and-billing.md`. Numbers: `core/knowledge/public/hq-core/pricing.json` (copy of the HQ API pricing endpoint (`GET /v1/pricing` on the HQ API base, default https://hqapi.hq.computer)). Quote only from those or the endpoint (policy `hq-pricing-source-of-truth`).

## Knowledge Bases

**Public** (`core/knowledge/public/`): Ralph, ai-security-framework, agent-browser, curious-minds, dev-team, hq-core, loom, projects, workers. Optional packs (install via `hq install @indigoai-us/hq-pack-*`) add: design-styles, design-quality, gemini-cli.

**Private** (`core/knowledge/private/`): linear

**Company-level** (`companies/{co}/knowledge/`): one per company; see `companies/manifest.yaml`.

## Policies

Standing operational rules per company. Location: `companies/{co}/policies/*.md`
Cross-cutting rules: `core/policies/*.md`
Spec: `core/knowledge/public/hq-core/policies-spec.md`. Template: `companies/_template/policies/example-policy.md`
