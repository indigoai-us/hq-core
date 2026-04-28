---
id: hq-publish-pipeline-two-stop
enforcement: hard
scope: global
tags: [hq-core, publish, staging, promotion]
created: 2026-04-25
provenance: user-correction
---

## Rule

ALWAYS treat HQ publish as a two-stop pipeline:

1. HQ working tree → `repos/private/hq-core-staging/` (GitHub `indigoai-us/hq-core-staging`, **private** — indigo-team review + leak-scan CI)
2. Staging → `repos/public/hq-core/` (GitHub `indigoai-us/hq-core`, **public** — ships via `npx create-hq`) reached only via promotion (`/promote-hq-core` or manual rsync per `staging-promotion-required.md`).

NEVER open a PR, commit, or push directly to `indigoai-us/hq-core`. Emergency-hotfix bypass requires a same-PR (or 24 h paired) backport to staging.

Retired targets (do not target): `repos/public/hq/template/` (monorepo subdir, retired 2026-04-21 with `hq-core-split`) and `repos/public/hq-starter-kit/` (legacy fork).

## Rationale

Two stops give the indigo team a private review + leak-scan checkpoint before anything reaches the public repo. Direct pushes to `hq-core` bypass that gate and risk leaking internal artefacts into a publicly distributed package. Companion policies: `hq-publish-target-is-hq-core.md`, `hq-core-public-no-direct-pr.md`, `staging-promotion-required.md`.
