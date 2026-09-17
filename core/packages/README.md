# core/packages/

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
4. Symlinks declared contributions into `.claude/skills/`, `core/workers/`, `core/knowledge/`, etc. on the next session start via `core/scripts/scan-packages.sh`.

## Recommended packs

See `core/core.yaml:recommended_packages`. A fresh `npx create-hq` run prompts to install all of them. `--full` installs everything unconditionally; `--minimal` skips the prompt.

Current packs — sourced from [`indigoai-us/hq-packages`](https://github.com/indigoai-us/hq-packages) via `github:` shorthand + subpath. The `@indigoai-us/hq-pack-*` npm names are reserved for when these publish to a registry; until then `core/core.yaml:recommended_packages` points at the git source.

- `design-styles` — 12 MB of curated style packs (brutalist, editorial, warm-neutral, etc.) + registry + pack schema.
- `design-quality` — typography / color / spatial / motion quality references for design-audit skills.
- `diagrams` — `/diagram`: editorial diagrams as self-contained HTML. Token-driven (the SVG carries classes, never colours), brand-bound via the `design-styles` diagram formula, and linted. Includes a reasoning family — decision record, blast radius, confidence ladder, handoff chain — that has no standard equivalent.
- `charts` — `/chart`: editorial data charts and report sheets as self-contained HTML. Same token contract as `diagrams` (the SVG carries classes, never colours; `--ch-*` roles fall back to `--dg-*`), three families (ledger / plain / signal), three report sheets, data-shape-first selection, and a linter that checks the honesty contract.
- `gemini` — six Gemini CLI workers (coder, reviewer, frontend, designer, stylist, ux-auditor) + `gemini-cli` knowledge. Conditional: skipped when `gemini` is not on `PATH`.
- `gstack` — gstack-team workers (26 g-* skills) + `core/scripts/gstack-bridge.sh`.
- `engineering` — the engineering surface extracted from shipped `core/` in v15.0.0: 17 dev skills (`/tdd`, `/review`, `/execute-task`, `/run-project`, `/land`, …), 6 workers, 4 knowledge bases, 4 policies. `/update-hq` auto-installs it for anyone upgrading from `< 15.0.0`; greenfield installs opt in.

## Other installed packs

Not part of the recommended set and not resolvable from the public registry — present in a tree only because someone installed them by path or from a gated source.

- `client-service` — turns any HQ company into a client-service firm (agency, consultancy, studio, fractional practice). Contributes the generic `client-services` lifecycle worker, the `/onboard-firm`, `/new-client`, `/client-pack` and `/handover-client` skills, the `client-service` knowledge corpus (adapter contracts + config schema), and 4 pack-scoped hard policies. Tool-agnostic: every integration is an *adapter slot* the firm binds to its own tooling in `companies/{firm}/client-service.yaml`, and an unbound slot degrades to a named report rather than an error. **Now published to the `@indigoai-us` marketplace at 0.1.1** (carrying a branded `cover.jpg`). The registry listing is Cognito/entitlement-gated at install, and local path remains the pack's verified distribution path — so install by local path, and read the pack's own `README.md` and `CHANGELOG.md` for what is verified and what is still unproven.

## Writing a pack

Each pack declares `package.yaml` at its root:

```yaml
name: hq-pack-{slug}
version: 1.0.0
publisher: '@indigoai-us'
access: public   # npm-style install SCOPE, not the marketplace gate — registry
                 # listings are Cognito/entitlement-gated at install regardless
requires:
  hqCore: '>=12.0.0'
contributes:
  workers: [worker-a, worker-b]
  knowledge: [shared-knowledge-slug]
  skills: [skill-name]
  hooks: []     # run on tool events — user-confirm prompt on install
  policies: []
  commands: []
  scripts: []  # land in core/scripts/ — declare only when the pack really needs it
```

Wiring ground truth: `core/scripts/scan-packages.sh` — its header comment carries the full `contributes.<key>` → host-path mapping and is the thing that actually creates the symlinks.

Schema: `package-yaml-spec.md` in the `knowledge-hq-core` repo (authoritative). Note that several references — including `scan-packages.sh`'s own header — point at `core/knowledge/public/hq-core/package-yaml-spec.md`, which is not currently shipped in `core/`.

