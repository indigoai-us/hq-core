# HQ Directory Map

The top-level layout of an HQ root. The Charter (`.claude/CLAUDE.md`, mirrored
to `AGENTS.md`) references this file as the canonical directory map under its
"Load On Demand" section.

## Release-shipped scaffold

- **`core/`** — the release-shipped HQ scaffold. Replaced wholesale by
  `/update-hq`. Contains:
  - `core.yaml` — release manifest: version, locked/excluded paths, recommended
    packs, and the `replace_from_staging` overlay contract.
  - `docs/hq/` — HQ documentation: `README.md`, `USER-GUIDE.md`, `CHANGELOG.md`,
    release notes, `LICENSE`, and this `INDEX.md`.
  - `policies/` — release-shipped policy rules (markdown with YAML frontmatter).
  - `scripts/` — orchestration and automation scripts, plus `tests/`.
    Includes `core/scripts/hq-agent-session.sh` — on-box HQ Agent Session
    entrypoint (contract owner for fleet agent turns; see
    `core/knowledge/public/hq-core/agent-session-contract.md`).
  - `schemas/` — versioned JSON Schema contracts (e.g. agent-session
    request/response envelopes).
  - `knowledge/` — shared knowledge stores, conventions, and specs.
  - `workers/` — worker definitions and the generated `registry.yaml`.
  - `packages/` — installed `@indigoai-us/hq-pack-*` packages.
  - `settings/` — orchestrator and runtime settings.
  - `hooks/` — release-shipped lifecycle hooks.
  - `skills/` — extension point for release-shipped skills.

## Harness surfaces

- **`.claude/`** — the live Claude Code harness: `CLAUDE.md` (the Charter),
  `settings.json`, `hooks/`, `skills/`, `output-styles/`, `scripts/`, and
  `audit/`.
- **`.codex/`** — the Codex adapter: `config.toml`, hook adapter, and symlinks
  that route Codex lifecycle events through the same `.claude/hooks/` gate.
- **`.cursor/`** — Cursor project rules (`.cursor/rules/hq.mdc`, MDC format
  used by Cursor 0.47+ / 3.x) pointing at `.claude/CLAUDE.md`.
- **`.agents/`**, **`.obsidian/`** — overlay symlinks and Obsidian vault config.
- **`AGENTS.md`** — symlink to `.claude/CLAUDE.md` so Codex and other agents read
  the same Charter.

## Runtime recovery

- **[HQ hooks not firing](HOOKS-NOT-FIRING.md)** — diagnose and repair missing
  project hook settings, then configure Claude Desktop or SDK `cwd` and
  `settingSources` correctly.

## Tenancy and overlays

- **`companies/`** — isolated tenants, each with their own knowledge, policies,
  settings, projects, workers, and registries. Source of truth:
  `companies/manifest.yaml`. The release ships only `companies/_template/`.
- **`personal/`** — the owner overlay (policies, knowledge, skills, hooks,
  settings, projects, workers). Not release-shipped. Consumers read it directly
  from `personal/`; the old reindex mirror into `core/` is retired and reindex
  prunes leftover mirror links. `/update-hq` does not touch `personal/`.
- **`repos/`** — code only, split into `repos/public/` and `repos/private/`. The
  only trees that get pushed to git remotes.

## Working state

- **`workspace/`** — session, orchestration, locks, drafts, reports, and
  worktrees. Local working state; only `workspace/threads/handoff.json` (plus
  the thread it points to), `workspace/agency/`, and `workspace/.session-logs/`
  sync to the personal vault.

## Tooling

- **`.github/`** — CI workflows (promote, beta, release, PR checks, audit).
- **`.leak-scan/`** — pre-release leak-scan tooling and rubrics (CI/dev only;
  not part of the release bundle).
- Root ignore files — `.gitignore`, `.claudeignore`, `.hqignore`, `.ignore`,
  `.gitattributes`.

## See also

- `core/docs/hq/USER-GUIDE.md` — command and capability reference.
- `core/knowledge/public/hq-core/quick-reference.md` — quick reference.
- `core/core.yaml` — the authoritative locked/excluded path lists.

## Product reference (`core/knowledge/public/hq-core/`)

- [hq-product-model.md](../../knowledge/public/hq-core/hq-product-model.md) — surfaces, local vs cloud, identity types, which surface for which task. Start here.
- [hq-cli-reference.md](../../knowledge/public/hq-core/hq-cli-reference.md) — every `hq` command, generated from the CLI.
- [hq-sync-model.md](../../knowledge/public/hq-core/hq-sync-model.md) — vaults, sync modes, company lifecycle, conflicts, daemons.
- [hq-desktop-app.md](../../knowledge/public/hq-core/hq-desktop-app.md) — the desktop app.
- [desktop-claude-code-integration.md](../../knowledge/public/hq-core/desktop-claude-code-integration.md) — Launch menu and local bots with Claude Code, Codex, Grok.
- [desktop-company-isolation.md](../../knowledge/public/hq-core/desktop-company-isolation.md) — desktop company scope gate.
- [desktop-rich-messages.md](../../knowledge/public/hq-core/desktop-rich-messages.md) — `hq-block` rich message contract.
- [agents-and-bots.md](../../knowledge/public/hq-core/agents-and-bots.md) — local bots, hosted agents, external bots.
- [external-agents-mcp.md](../../knowledge/public/hq-core/external-agents-mcp.md) — hq-mcp connector, `hq agent mcp`, Cowork plugin.
- [hq-console.md](../../knowledge/public/hq-core/hq-console.md) — console pages by task.
- [plans-and-pricing.md](../../knowledge/public/hq-core/plans-and-pricing.md) — plans, limits, billing.
