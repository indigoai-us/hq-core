---
name: discover
description: |
  Pull a repo into HQ at latest main, fan out parallel exploration, and
  synthesize structured knowledge + (gated) policies under the owning company.
  Use when the user says "discover this repo", "ingest <repo>", "pull <repo>
  into HQ", or asks to learn a codebase HQ doesn't yet know.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, Agent
public: true
---

# Discover

Front door for "I want HQ to know this repo." Acquires the repo at latest `main`, fans out parallel exploration, writes structured knowledge under the owning company (or standalone), and proposes scoped policies for crystal-clear conventions only. Phased ceremony with explicit gates — inspired by gstack.

## Input

`$ARGUMENTS` may be:

- `https://github.com/<org>/<name>` or `git@github.com:<org>/<name>.git`
- `<org>/<name>` shorthand
- An absolute local path to an existing checkout

Optional flags: `--company <slug>`, `--private`, `--no-policies`.

## Phase 1 — Acquire (idempotent)

| Input shape | Action |
|---|---|
| Full git URL | Use as-is |
| `<org>/<name>` shorthand | Expand to `https://github.com/<org>/<name>` |
| Absolute local path | Skip clone; verify `.git/` exists |

1. Detect visibility + default branch:
   ```bash
   gh repo view <org>/<name> --json visibility,defaultBranchRef,owner,description,primaryLanguage
   ```
   Skip if already a local path.
2. Pick target: `repos/public/<name>` (PUBLIC) or `repos/private/<name>` (PRIVATE). `--private` forces private placement.
3. **Clone (if absent):**
   ```bash
   git clone --depth=50 <url> repos/{pub|priv}/<name>
   ```
   Shallow is sufficient for discovery.
4. **Sync (if present):**
   - `git -C <path> status --porcelain` — bail loudly if dirty (NEVER `reset --hard`)
   - `git -C <path> fetch origin`
   - `git -C <path> checkout <default_branch>`
   - `git -C <path> pull --ff-only`
5. Capture `head_sha`, `last_commit` (ISO), file count, line count.

## Phase 2 — Register (auto-detect company; never ask if any tier resolves)

Resolve owning company in priority order:

| Tier | Source | Win condition |
|---|---|---|
| 1 | `--company <slug>` flag | Always wins if present |
| 2 | Active session: `workspace/threads/handoff.json` `.company`, or `$HQ_ACTIVE_COMPANY` | Use if non-empty and present in `companies/manifest.yaml` |
| 3 | GitHub org match: owner login → `companies/{co}.github_org` in manifest | Single match auto-uses; multiple → AskUserQuestion |
| 4 | Path heuristic: target lives under `companies/<co>/repos/...` | Infer that company |
| 5 | Standalone | Knowledge writes to `core/knowledge/public/repos/<name>/`; manifest gets `unaffiliated_repos[]` append |

Then:

1. Update `companies/manifest.yaml`: append target path to `{company}.repos[]` (idempotent, sorted, no-op if present). For standalone: append to top-level `unaffiliated_repos[]`.
2. Register qmd collection:
   ```bash
   qmd collection add <path> --name <name> --mask "**/*.md" 2>/dev/null || true
   ```
3. **Drift gate:** if the repo path already exists under a *different* company, STOP and surface via AskUserQuestion before overwriting.

## Phase 3 — Fan-out exploration (parallel `Agent` calls, `subagent_type=Explore`)

Spawn these IN A SINGLE MESSAGE so they run concurrently. Each returns ≤500 words under fixed headings — orchestrator collates, does NOT re-read source files.

| Agent | Brief |
|---|---|
| **Stack & architecture** | Languages, frameworks (Next/Astro/Bun/Vite/Hono/Expo/etc.), entry points, package manager (lockfile-detected), build/test/lint commands, deploy target. Read `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, top-level configs. |
| **Environment & services** | `.env.example` keys grouped by external service (Stripe, Clerk, Vercel, AWS, Shopify, etc.). Cross-link to `companies/{co}.services[]` in manifest. |
| **Conventions & operations** | Test strategy (unit/E2E presence), CI workflows under `.github/workflows/`, branching/PR rules from `CONTRIBUTING.md` / README, husky/lefthook hooks, `.editorconfig`, `.prettierrc`. |
| **Domain & purpose** *(skip if README < 30 lines)* | What the product does, who it serves, public docs links, top-level modules. |

## Phase 4 — Synthesize knowledge

**Target dir:**
- Company-owned: `companies/<co>/knowledge/repos/<name>/`
- Standalone: `core/knowledge/public/repos/<name>/`

Write four files (overwrite on re-run; they're regenerated artifacts):

- `overview.md` — purpose, stack summary, scale signals (file/line counts, contributors), default branch + last-commit ISO
- `architecture.md` — entry points, top-level layout, key dependencies
- `environment.md` — env-var table, external services, links to manifest service entries
- `conventions.md` — test/lint/build commands, CI summary, branch model

**Knowledge frontmatter** (every file):

```yaml
---
type: reference
domain: [engineering]
status: canonical
tags: [repo:<name>, discovered]
source: discover
generated_at: <ISO-8601 UTC>
head_sha: <sha>
relates_to: []
---
```

## Phase 5 — Propose policies (conservative, user-gated)

**Skip entirely if `--no-policies`.** Otherwise propose ONLY when signal is unambiguous:

| Signal | Draft rule |
|---|---|
| `pnpm-lock.yaml` exists, no `package-lock.json` / `yarn.lock` / `bun.lock` | Use pnpm; do not generate other lockfiles |
| `bun.lock` exists | Use bun |
| Husky `pre-commit` runs lint/typecheck/tests | Pre-commit hook is authoritative; do not pass `--no-verify` |
| Single `.github/workflows/deploy*.yml` with explicit deploy command | Deploy via `<workflow>` only; no manual `vercel deploy` / `netlify deploy` |
| `engines.node` pin in `package.json`, or `.nvmrc`, or `.python-version` | Use `<version>` for this repo |

**Scope auto-decision (no prompt unless ambiguous):**

| Heuristic | Scope chosen |
|---|---|
| Signal references repo-unique paths/workflows/scripts | **repo** → `repos/{pub\|priv}/<name>/.claude/policies/<id>.md` |
| Same signal present in ≥2 sibling repos under `{company}.repos[]` (read-only, cap at 5 siblings) | **company** → `companies/<co>/policies/<id>.md` |
| Standalone repo (no company) | **repo** always |
| Tied / unclear | Default **repo** (narrower wins; widen later via `/learn` or `/garden`) |

**For each candidate**, present via `AskUserQuestion` with options: **Write**, **Edit then write**, **Skip**. Never auto-write without confirmation.

**Policy frontmatter** (per `core/knowledge/public/hq-core/policies-spec.md`):

```yaml
---
id: <scope-prefix>-<slug>          # e.g. <repo>-pnpm-only, <co>-pre-commit-authoritative
title: <short title>
scope: repo | company
trigger: <when this applies>
enforcement: soft                   # discover never produces hard policies — let user upgrade later
version: 1
created: <YYYY-MM-DD>
updated: <YYYY-MM-DD>
public: false                       # all discover-generated policies start private
source: discover
learned_from: discover/<repo>@<head_sha_short>
---
```

If ≥1 policy was written, run:

```bash
bash core/scripts/build-policy-digest.sh
```

…so the next session loads it.

## Phase 6 — Index & report

1. `qmd update 2>/dev/null || true`
2. Print summary table:
   - Repo path, head SHA, default branch
   - Files written (count + paths)
   - Policies written (count + scopes)
   - Manifest changes (none / `<co>.repos[]` += / `unaffiliated_repos[]` +=)
3. Suggest next: `/run dev-team context-manager` for deeper analysis, or `/plan` to start a project against this repo.

## Idempotence guarantees

| Re-run behavior | Phase |
|---|---|
| Latest main pulled (no-op if up to date) | 1 |
| No manifest churn if already registered | 2 |
| Knowledge files overwritten with fresh `generated_at` + `head_sha` | 4 |
| Policies skipped if a file with same `id` already exists | 5 |

## Out of scope

- Auto-writing `CLAUDE.md` inside the discovered repo (user runs `/init` if desired)
- Spawning workers for the repo (`/newworker`)
- Branches other than default
- Cross-repo dependency graphs

## Safety

- Never `git reset --hard`, never `--force` push, never delete files in target repo.
- Working-tree dirty in an existing clone → bail with a clear "stash or commit first" message.
- Drift between proposed and existing manifest entries → AskUserQuestion before overwrite.
- All proposed policies are `enforcement: soft` and `public: false` — the user explicitly upgrades later.
