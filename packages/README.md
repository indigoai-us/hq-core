# packages/

Drop-in contribution bundles — the add-on tier of HQ.

`hq-core` ships a minimal scaffold. Optional capabilities (rich design styles, quality audits, Gemini CLI workers, gstack sprint team) live as separate `@indigoai-us/hq-pack-*` npm packages and install into this directory.

## Install a pack

```bash
hq install @indigoai-us/hq-pack-gstack        # npm
hq install https://github.com/{org}/pack-foo  # git (pins to commit SHA)
hq install ./local-pack                       # local path
```

The installer:

1. Resolves the transport (npm / git / local).
2. Extracts into `packages/{name}/`.
3. Validates `package.yaml` against the schema.
4. Registers contributions in `modules/modules.yaml` under `strategy: package`.
5. Symlinks declared contributions into `.claude/commands/`, `.claude/skills/`, `workers/`, `knowledge/`, etc. on the next session start via `scripts/scan-packages.sh`.

## Recommended packs

See `core.yaml:recommended_packages`. A fresh `npx create-hq` run prompts to install all of them. `--full` installs everything unconditionally; `--minimal` skips the prompt.

Current packs (published as `@indigoai-us/hq-pack-*`):

- `design-styles` — 12 MB of curated style packs (brutalist, editorial, warm-neutral, etc.) + registry + pack schema.
- `design-quality` — typography / color / spatial / motion quality references for design-audit skills.
- `gemini` — six Gemini CLI workers (coder, reviewer, frontend, designer, stylist, ux-auditor) + `gemini-cli` knowledge. Conditional: skipped when `gemini` is not on `PATH`.
- `gstack` — gstack-team workers (26 g-* skills) + `scripts/gstack-bridge.sh`.

## Writing a pack

Each pack declares `package.yaml` at its root:

```yaml
name: hq-pack-{slug}
version: 1.0.0
publisher: '@indigoai-us'
access: public
requires:
  hqCore: '>=12.0.0'
contributes:
  workers: [worker-a, worker-b]
  knowledge: [shared-knowledge-slug]
  skills: [skill-name]
  hooks: []     # run on tool events — user-confirm prompt on install
  policies: []
  commands: []
```

Schema: see the [hq package spec](https://github.com/indigoai-us/hq/blob/main/docs/hq-package-spec.md). The canonical JSON Schema lives at [`packages/hq-cli/src/schemas/hq-package.schema.json`](https://github.com/indigoai-us/hq/blob/main/packages/hq-cli/src/schemas/hq-package.schema.json).

## Backwards compatibility

Existing `modules/modules.yaml` entries using `strategy: link`, `strategy: merge`, and `strategy: embedded` continue to resolve. `strategy: package` is additive — packs co-exist with legacy strategies without migration.
