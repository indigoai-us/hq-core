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
  settings, projects, workers). Not release-shipped; mirrored into `core/` by the
  reindex step so owner-global rules survive a wholesale `/update-hq`.
- **`repos/`** — code only, split into `repos/public/` and `repos/private/`. The
  only trees that get pushed to git remotes.

## Working state

- **`workspace/`** — session, orchestration, locks, drafts, reports, and
  worktrees. Local-only working state.

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
