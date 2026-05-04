# hq-core v14.0.0-beta

**Type**: Prerelease (beta)
**Published from**: `indigoai-us/hq-core-staging` @ `9d1b5be`
**Date**: 2026-05-04

This is a major version bump (v12.x → v14) representing roughly six months of HQ core evolution. Promoted via the staging buffer pattern documented in `hq-cmd-publish-kit-staging-flow-not-direct`. `-beta` denotes that 25 NEEDS_REVIEW items from the staging audit are deferred for v14.0.0 GA.

## Highlights

### New skills & commands

- `architect` — surface architectural impact before changes
- `diagnose` — disciplined root-cause workflow
- `out-of-scope` — record rejected feature requests with rationale
- `prd` (lightweight) + `review-plan` + `review` — paranoid pre-landing checks
- `adr` — capture Architecture Decision Records
- `search` — unified qmd/grep search
- `calibration-report`, `track-estimate`, `finish-estimate` — estimate calibration system
- `ascii-graphic` — block-art generator

### Hooks & policy infrastructure

- `master-hook.sh` + `master-sync.sh` — central hook router and sync
- `inject-policy-on-trigger.sh` — surfaces matching policies just-in-time
- `check-core-yaml-parity.sh` — enforces hq-core ↔ HQ version alignment
- `capture-estimates.sh` — feeds the calibration system
- `mirror-thread-to-company.sh` — auto-mirror session threads to company workspaces
- New output style: `Cavebro` (warm terse chat voice) — see `.claude/output-styles/`

### Policy system

- New consolidated `_digest.md` rebuilt by `scripts/build-policy-digest.sh`
- Policies now self-classify with `public:` frontmatter; promotion respects it
- 9 vendor-/internal-scoped policies stripped from this release (codex-pii-rubric advisory)
- 25 additional policies remain `NEEDS_REVIEW` for GA — see "Deferred" below

### Other

- `co-workspace-mirror` policy: HQ writes mirror into per-company workspace
- `companies/_template/` reorganized with cleaner skeleton + example files
- README/MIGRATION/CHANGELOG refreshed

## Breaking changes

- Major version jump: HQ installations updating from v12.x will need to:
  - Re-run `npx create-hq` or follow `MIGRATION.md`
  - Rebuild policy digest after sync
- Several command names normalized — see `MIGRATION.md` for the full mapping

## Deferred to v14.0.0 GA

These items are present in the staging tree but not yet audited for public release. They will ship in v14.0.0 GA after the audit closes.

- `installer/` (absent from public)
- `INDEX.md`, `GEMINI.md`, `.mcp.json`, `social-kit.yaml` (HQ-internal, not promoted)
- `.github/` workflows (staging-only — `pr-checks.yml` is the buffer's CI, not the public template's)
- `docs/`, `tools/`, `prompts/` directories from public are intentionally retained on public until staging-side equivalents land
- 25 `NEEDS_REVIEW` policies from the v14 audit pass remain unclassified

## Verification

- All `pr-checks.yml` jobs green on staging `main` after PR #53 merged
- `denylist-scan`, `policy-rationale-scan`, `users-path-tripwire`, `provenance-stripped`, `vendor-public-ok`, `public-frontmatter-revalidate`, `denylist-drift`, `core-yaml-locked`, `special-case-files` all passing
- `codex-pii-rubric` has no failing files after policy cleanup; remaining advisory failures are infrastructure-side (codex CLI flakiness on frontmatter-only diffs) and don't gate

## Next

- Triage the 25 deferred policies → v14.0.0 GA
- Backfill `docs/`, `tools/`, `prompts/` parity if still wanted on the public template
