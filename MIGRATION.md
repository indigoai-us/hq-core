## Migrating to v12.3.0 — 2026-05-02

### Headline

No migration steps required — all changes are backward-compatible.

### What changed

- **Codex policy + hook bridges** are additive — they install symlinks/adapters in `.codex/` without touching anything in `.claude/`. Operators who use Claude Code only see no change.
- **`/deploy` Phase A speed refactor** keeps the same external interface; only internal sub-agent fan-out was replaced with inline parallel scripts.
- **`CLAUDE.md` charter restructure + `AGENTS.md` symlink** preserve all instruction content. The symlink unifies Claude + Codex on the same source. Operators who customized `AGENTS.md` directly should reapply their customizations to `.claude/CLAUDE.md` (the symlink target) — note that `AGENTS.md` is now a regular symlink and writes go through to `CLAUDE.md`.
- **Policy enforcement rebalance** moves ~140 policies from `hard` to `soft`. Soft-enforcement policies note deviations rather than blocking. If your workflows depended on a specific policy blocking on violation, check `.claude/policies/_digest.md` and re-promote any that you want to remain hard via `/learn --hard`.

### Optional: pick up the new commands

Three new slash commands ship with v12.3.0. They auto-register on next session start. If you want a quick tour:

- `/discover <repo-url-or-path>` — pull a repo into HQ and synthesize knowledge
- `/land-batch` — triage and merge multiple open PRs
- `/sync-registry [company]` — regenerate a company's resource-registry index

### Optional: enable Codex bridges

If you use OpenAI Codex alongside Claude Code:

```bash
bash scripts/codex-skill-bridge.sh install            # symlinks .claude/skills → .codex/, .agents/
bash scripts/codex-skill-bridge.sh install-policies   # NEW in v12.3.0 — symlinks .claude/policies/
```

The hook bridge (`.codex/hooks/hq-codex-hook-adapter.sh`) is install-time only — no runtime opt-in needed once the file is present. Codex sessions automatically route hooks through the existing `hook-gate.sh`.

## Migrating to v12.2.0 — 2026-04-30

### Headline

Codex parity. Existing Claude Code users on v12.1.x can stay where they are — nothing breaks. Operators who also want to invoke HQ from OpenAI Codex run one command and gain a parallel Codex entrypoint tree.

Fully additive. No breaking changes. No file deletions. No policy enforcement weakened.

### New Files (added at HQ root)

- `AGENTS.md` — Codex orientation doc (mirrors `CLAUDE.md` for Claude Code).
- `.codex/config.toml` — Codex sandbox + model settings.
- `.codex/claude` — symlink to `.claude/`.
- `.codex/prompts` — symlink to `.claude/commands/`.
- `.agents/skills` — symlink to `.claude/skills/`.

### New Commands

- `/convert-codex` — One-command repair for older Claude-first HQ roots. Dry-run by default. Adds the new entrypoints listed above plus missing `agents/openai.yaml` metadata for shipped skills.

### New Skills (Codex adapters)

18 new `SKILL.md` adapters in `.claude/skills/{name}/`, each pointing back to its sibling `.claude/commands/{name}.md` as source of truth. Plus 30 new `agents/openai.yaml` metadata files. No duplication of command bodies — adapters delegate.

### Changed Files

- 4 policy files have path renames (`repos/public/hq/template/` → `repos/private/hq-core-staging/`). Enforcement unchanged.
- `_digest.md` regenerated.
- `core.yaml` version + checksums updated.

### Migration Steps

**For Claude Code-only users:** No action required. Update HQ via `hq update` (or your usual flow) when convenient. Nothing in your day-to-day Claude Code workflow changes.

**For users who also want Codex:**
```bash
cd <your HQ root>
bash scripts/convert-codex.sh --dry-run   # preview
bash scripts/convert-codex.sh --apply     # add Codex entrypoints
```

The script is create-only. It will skip any path that already exists and report blocked items so you can review before approving more invasive changes.

### Companion package upgrades

None. `@indigoai-us/hq-cli` and `@indigoai-us/hq-cloud` are unaffected.

---

## Migrating to v12.1.1 — 2026-04-29

### Headline

Hotfix that finishes the dev→prod Cognito cutover. Two file-level changes to existing operators' HQ trees, plus one new global policy. Fully additive on top of v12.1.0 — no breaking changes.

### Changed Commands

- `.claude/commands/designate-team.md` — env-echo default flipped from `hq-vault-dev` to `vault-indigo-hq-prod` (single-line change, line 119). Behavior of `hq cloud provision company` is unchanged; only the on-screen sanity-check banner now reflects the canonical post-cutover pool.

### New Policies

- `.claude/policies/prefer-systemic-fix-over-user-bandaid.md` — hard, global. New rule: bug fixes ship as systemic patches, not per-user env exports. See CHANGELOG for the banned/required framings.

### Companion package upgrades (recommended same-day)

- `@indigoai-us/hq-cloud@5.9.0` — adds stale-pool detection so pre-cutover dev tokens stop producing 401s against the prod vault API. No action required from operators; cached tokens with mismatched `client_id` claim are silently re-authed on next CLI invocation.
- `@indigoai-us/hq-cli@5.7.1` — `bun install -g @indigoai-us/hq-cli@5.7.1` to pick up hq-cloud@5.9.0.
- `create-hq@10.12.0` — only matters for new HQs created after 2026-04-29; existing HQs are unaffected.

### Verification

- `cat .claude/commands/designate-team.md | grep "Cognito domain"` should print no `hq-vault-dev` substring.
- `ls .claude/policies/prefer-systemic-fix-over-user-bandaid.md` should exist after `/update-hq`.
- `bash scripts/build-policy-digest.sh` regenerates `.claude/policies/_digest.md` with 105+ policies, hard-enforcement section now contains a `prefer-systemic-fix-over-user-bandaid` line.

---

## Migrating to v12.1.0 — 2026-04-28

### Headline

Iteration release on top of the v12.0.0 hq-core split. All changes are additive — new commands, a new skill, a `/plan` refactor that splits the heavy interview path into a separate `/deep-plan`, and a batch of new policies that consolidate scattered git/bash/vercel rules into discipline-pack policies. No locked-file structural changes; existing HQ instances upgrade cleanly with no breaking changes.

### New Commands

- `.claude/commands/deep-plan.md`
- `.claude/commands/designate-team.md`
- `.claude/commands/hq-login.md`
- `.claude/commands/hq-logout.md`
- `.claude/commands/hq-sync.md`
- `.claude/commands/hq-whoami.md`
- `.claude/commands/import-claude.md`
- `.claude/commands/resolve-conflicts.md`

### New Skills

- `.claude/skills/deep-plan/`
- `.claude/skills/designate-team/`
- `.claude/skills/hq-login/`
- `.claude/skills/hq-logout/`
- `.claude/skills/hq-secrets/`
- `.claude/skills/hq-whoami/`
- `.claude/skills/import-claude/`

### New File

- `.claude/stack.yaml`
- `.claude/policies/hq-bash-discipline.md`
- `.claude/policies/hq-bash-no-gnu-coreutils-date-timeout.md`
- `.claude/policies/hq-classifier-own-labels-single-source.md`
- `.claude/policies/hq-cli-version-read-from-package-json.md`
- `.claude/policies/hq-cmd-handoff-no-discovery-rerun.md`
- `.claude/policies/hq-cmd-publish-kit-python-yaml-free.md`
- `.claude/policies/hq-cmd-publish-kit-rerun-diff-on-scope-narrow.md`
- `.claude/policies/hq-cmd-run-project-ralph-hard-pause-procedure.md`
- `.claude/policies/hq-cmd-stage-kit-settings-json-direct-edit.md`
- `.claude/policies/hq-compiled-ts-rebuild-after-src-edits.md`
- `.claude/policies/hq-cross-repo-privilege-tier-surface-scope.md`
- `.claude/policies/hq-destructive-scripts-default-dry-run.md`
- `.claude/policies/hq-git-diff-three-dot-for-pr-review.md`
- `.claude/policies/hq-git-discipline.md`
- `.claude/policies/hq-git-large-diff-audit-before-panic.md`
- `.claude/policies/hq-git-merge-ff-only-trunk.md`
- `.claude/policies/hq-git-squash-merge-branch-ahead-expected.md`
- `.claude/policies/hq-git-staged-deletion-verify-blob-before-reset.md`
- `.claude/policies/hq-github-app-over-pat-for-bot-repo-creation.md`
- `.claude/policies/hq-migration-independent-grep-verify.md`
- `.claude/policies/hq-nextjs-host-redirect-requires-domain-attachment.md`
- `.claude/policies/hq-no-parent-import-from-child-component.md`
- `.claude/policies/hq-nodejs-promisify-scrypt-options-wrap-manual.md`
- `.claude/policies/hq-oidc-access-denied-diagnose-via-cloudtrail.md`
- `.claude/policies/hq-oidc-migration-plan-both-subject-shapes.md`
- `.claude/policies/hq-orthogonal-filters-over-overlapping-presets.md`
- `.claude/policies/hq-plan-combined-story-edit-locality.md`
- `.claude/policies/hq-prd-verify-passes-vs-artifact-registry.md`
- `.claude/policies/hq-pre-push-gate-probes-prod-not-localhost.md`
- `.claude/policies/hq-publish-pipeline-two-stop.md`
- `.claude/policies/hq-session-resume-git-status-reverify.md`
- `.claude/policies/hq-settings-local-for-personal-allows.md`
- `.claude/policies/hq-slack-verify-scopes-beyond-auth-test.md`
- `.claude/policies/hq-static-regression-anchor-forbidden-pattern.md`
- `.claude/policies/hq-vercel-discipline.md`
- `.claude/policies/hq-vercel-wildcard-single-subdomain-level.md`
- `.claude/policies/hq-zsh-status-readonly-loop-var.md`
- `.claude/policies/no-headless-browser-in-vercel-lambda.md`
- `.claude/policies/no-relative-symlinks-from-worktree.md`
- `.claude/policies/no-shared-skill-extraction-touching-5-files.md`
- `.claude/policies/publish-kit-source-is-strict-allowlist.md`

### Updated Files

- `.claude/CLAUDE.md`
- `.claude/commands/plan.md`
- `.claude/commands/update-hq.md`
- `.claude/hooks/load-policies-for-session.sh`
- `.claude/policies/_digest.md`
- `.claude/policies/ascii-art-character-verify.md`
- `.claude/policies/blog-post-x-draft.md`
- `.claude/policies/deconflict-postbridge-schedule.md`
- `.claude/policies/distributed-join-partial-failure-diagnosis.md`
- `.claude/policies/dual-codex-review-pattern.md`
- `.claude/policies/dual-repo-prd-routing.md`
- `.claude/policies/email-humanize.md`
- `.claude/policies/git-stash-build-artifacts-conflict.md`
- `.claude/policies/hq-cmd-handoff-must-complete.md`
- `.claude/policies/hq-cmd-run-project-pid-tracking.md`
- `.claude/policies/hq-cmd-run-project-process-cleanup.md`
- `.claude/policies/hq-figma-token-account-scope.md`
- `.claude/policies/hq-nested-repo-git-status-check.md`
- `.claude/policies/hq-permissions-fan-out-edit-write-multiedit.md`
- `.claude/policies/hq-swarm-pr-branch.md`
- `.claude/policies/hq-swarm-rust-hub-files.md`
- `.claude/policies/hq-tmux-plan-approval-dance.md`
- `.claude/policies/idb-install.md`
- `.claude/policies/linear-scan-check-existing-prds.md`
- `.claude/policies/no-threaded-posts.md`
- `.claude/policies/npm-subpackage-hydration.md`
- `.claude/policies/og-image-twitter-cache.md`
- `.claude/policies/orchestrator-competing-processes.md`
- `.claude/policies/orchestrator-lockfile-sync.md`
- `.claude/policies/post-bridge-media-upload.md`
- `.claude/policies/post-bridge-media-workflow.md`
- `.claude/policies/post-bridge-unicode-payload.md`
- `.claude/policies/prd-content-sources.md`
- `.claude/policies/prd-files-match-acs-for-swarm.md`
- `.claude/policies/prd-json-schema.md`
- `.claude/policies/prd-json-validation-post-task.md`
- `.claude/policies/prd-no-execute.md`
- `.claude/policies/prd-no-implement.md`
- `.claude/policies/prd-story-sizing.md`
- `.claude/policies/prd-userstories-key.md`
- `.claude/policies/preview-start-launch-registry-is-global.md`
- `.claude/policies/regression-gate-lint-fix.md`
- `.claude/policies/reskin-separate-orchestration-from-visual.md`
- `.claude/policies/run-project-conflict-marker-guard.md`
- `.claude/policies/run-project-dry-run-branch-leak.md`
- `.claude/policies/run-project-file-locks-stale.md`
- `.claude/policies/run-project-local-keyword.md`
- `.claude/policies/run-project-monitor-spawn-keystroke-race.md`
- `.claude/policies/run-project-name-matches-dir.md`
- `.claude/policies/run-project-no-permissions-required.md`
- `.claude/policies/run-project-progress-txt-no-commit-misleading.md`
- `.claude/policies/run-project-repo-bootstrap.md`
- `.claude/policies/run-project-sigkill-retry.md`
- `.claude/policies/run-project-swarm-branch-validation.md`
- `.claude/policies/run-project-swarm-merge-conflict-tombstone.md`
- `.claude/policies/run-project-verification-story-false-negative.md`
- `.claude/policies/run-project-worktree-heal-orphan.md`
- `.claude/policies/session-data-for-product-accuracy.md`
- `.claude/policies/swarm-orphan-recovery.md`
- `.claude/policies/swarm-post-execution-review.md`
- `.claude/policies/vercel-domain-transfer-reissues-verification.md`
- `.claude/policies/verify-routes-after-parallel-execution.md`
- `.claude/skills/plan/SKILL.md`
- `CHANGELOG.md`
- `MIGRATION.md`
- `README.md`
- `core.yaml`

### Removed

- `.claude/policies/git-add-explicit-paths-no-drift.md`
- `.claude/policies/git-branch-verify.md`

_Both removed policies had their rules consolidated into `.claude/policies/hq-git-discipline.md` (in the New File list above)._

### Migration Steps

After update, the new commands become available immediately:

- **Identity:** `/hq-login`, `/hq-logout`, `/hq-whoami`
- **Sync:** `/hq-sync`, `/resolve-conflicts`
- **Onboarding / planning:** `/import-claude`, `/deep-plan`
- **Team provisioning:** `/designate-team`

The `hq-secrets` skill auto-loads on next session start; the new `## Secrets` block in `.claude/CLAUDE.md` is offered via section-level merge.

`/plan` is now lightweight; the previous heavy interview + research path moved to `/deep-plan`. Existing call sites continue to work — choose the depth that fits.

### Optional `hq` CLI dependency

`/designate-team` and `/hq-sync` delegate to the `@indigoai-us/hq-cli` binary (`hq …`). If you don't already have it on `PATH`:

```bash
npm install -g @indigoai-us/hq-cli
hq whoami    # verify
```

If the binary is missing, both commands surface a clear error pointing at install instructions — no silent fallback.

### Breaking Changes

None.

---

# Migration — v11.x → v12.0.0

## What changed

The HQ scaffold seed split off into its own repository: `indigoai-us/hq-core`. The monorepo at `indigoai-us/hq` stays alive as the home of the publish pipeline, `create-hq`, `hq-cli`, and `hq-pack-*` package sources. `indigoai-us/hq-core` is the canonical scaffold source-of-truth starting with v12.0.0.

Rich content that previously shipped inline with the template moved to four opt-in npm packages:

| Removed from hq-core | New home |
|---|---|
| `knowledge/public/design-styles/` | `@indigoai-us/hq-pack-design-styles` |
| `knowledge/public/design-quality/` | `@indigoai-us/hq-pack-design-quality` |
| `knowledge/public/gemini-cli/` + 6 `workers/public/gemini-*/` | `@indigoai-us/hq-pack-gemini` |
| `workers/public/gstack-team/` + `scripts/gstack-bridge.sh` | `@indigoai-us/hq-pack-gstack` |
| `workers/public/impeccable-designer/` (deprecated) | — use `dev-team/frontend-dev` + `hq-pack-design-styles` |
| `workers/public/sample-worker/`, `knowledge/public/impeccable/` | — deleted |

## Upgrading an existing HQ instance

### Fresh install
```bash
npx create-hq my-hq          # prompts to install recommended packs
npx create-hq my-hq --full   # installs all recommended packs unconditionally
npx create-hq my-hq --minimal # skip the pack prompt
```

### Existing v11.x instance
```bash
cd ~/Documents/HQ    # or wherever your HQ lives
/update-hq           # pulls latest hq-core; upgrades packs; prompts for any newly-recommended packs
```

`/update-hq` is non-destructive: pack install failures surface as warnings, not fatal errors. Re-run `/setup --resume` to retry.

### Manual reinstall of a specific pack
```bash
hq install @indigoai-us/hq-pack-gstack                      # npm
hq install https://github.com/{org}/pack-foo#{commit-sha}   # git (pins to SHA)
hq install ./local-pack                                     # local path
```

## Compatibility notes

- **`modules/modules.yaml` entries with `strategy: link`, `strategy: merge`, `strategy: embedded`** continue to resolve unchanged. `strategy: package` is additive.
- **`hq install` writes** a `strategy: package` entry automatically — you do not hand-edit `modules.yaml` for packs.
- **Hooks shipped by a pack** (`contributes.hooks`) auto-run on tool events. `hq install` surfaces this and prompts for confirmation — or pass `--allow-hooks` for non-interactive installs.
- **Publish pipeline** (`/publish-kit`, `/stage-kit`) retargeted from `repos/public/hq/template/` to `repos/public/hq-core/` as part of the split. Same commands, new target.

## Provenance

v12.0.0 starts with a fresh git history in `indigoai-us/hq-core`. Pre-v12 history lives at `indigoai-us/hq@pre-split` (the `hq/template/` tree in the monorepo). Git log for scaffold changes before v12.0.0 lives there — not here.

---

## Migrating to 11.2.0 — 2026-04-18

**Non-breaking for HQ consumers.** The only behavior changes land in publish-kit itself: the release walker is now a strict allowlist, and the publish target is rebuilt from scratch on every full release. No action required for anyone consuming the template.

If you maintain a downstream publish-kit or a fork that mirrors HQ, read below.

### Step 1 — Review the new allowlist

The walker now refuses to emit anything outside `.claude/policies/publish-kit-source-is-strict-allowlist.md` (ALLOW_ROOTS, REMAPS, STARTER_SCAFFOLDS, NEVER_TRAVERSE). If your fork publishes paths that aren't on the allowlist, add them to the policy and the walker explicitly — silent drift is no longer possible.

### Step 2 — Expect deletions on first 11.2.0 publish

Because the target is now rebuilt from scratch (Stage R = `rm -rf template/`), the first 11.2.0 publish will register as a very large diff against the prior release: every file that was leaked by earlier permissive walks (owner-private commands, deprecated skills, company-scoped policies, private knowledge) is removed. This is expected and not a regression — it is the root-cause fix for the leak class.

### Step 3 — `Stage R` semantics

On every full release:
1. **Stage R — Rebuild Target:** `rm -rf template/` then `mkdir -p template/`.
2. **Stage E — Emit:** walk the allowlist and write each file into the empty `template/`.

Incremental publishes (single-file corrections) still bypass Stage R. The assertion in Step 0.5 of `.claude/commands/publish-kit.md` is the gate.

### Step 4 — `/prd` is now `/plan`

The `prd/` skill was renamed to `plan/`, and the command `/prd` was removed. Update any muscle memory, CI hooks, or prompt templates: use `/plan`.

---

# Migration Guide

Instructions for updating existing HQ installations to new versions.

---

## Migrating to v11.1.0 (from v11.0.0)

### Headline

qmd sub-collection refactor + design system knowledge sync. Non-breaking — run `setup.sh` to create new collections.

### Step 1 — Re-run setup.sh for qmd sub-collections

The monolithic `hq` qmd collection is now split into 4 focused collections. Re-run setup to create them:

```bash
bash setup.sh
```

This creates `hq-infra`, `hq-workers`, `hq-knowledge`, and `hq-projects` collections with scoped include paths. Your existing `hq` collection is not removed — you can delete it manually with `qmd collection remove hq` if desired.

### Step 2 — Rename `.impeccable.md` → `design.md` (if applicable)

If any of your repos have an `.impeccable.md` file, rename it:

```bash
# In each repo that has one:
mv .impeccable.md design.md
```

The `style:` field is now `style-pack:` in the Design Direction section. Workers auto-resolve via `knowledge/design-styles/registry.yaml`.

### Step 3 — Verify knowledge bases synced

New knowledge bases were added. Verify they exist:

```bash
ls knowledge/design-styles/registry.yaml
ls knowledge/design-quality/
ls knowledge/hq-core/design-md-spec.md
ls knowledge/hq-core/insights-spec.md
```

### Step 4 — (Optional) Clean removed policies

Seven company-specific policies were removed. If you added custom rules to any of these files, back them up first. Otherwise they should already be gone from the update:

- `hq-paper-mcp-sequential-agents.md`
- `hq-slack-channel-indigo-workspace.md`
- `indigo-hq-app-release.md`
- `indigo-signals-mcp-queries.md`
- `paper-flex-column-reorder.md`
- `paper-text-width.md`
- `paper-text-wrapping.md`

---

## Migrating to v10.8.0 (from v10.7.1)

### Headline

Design worker consolidation: 6 design workers → 2 (`frontend-designer` + `ux-auditor`). Style pack system. Configurable models.

### Step 1 — Create ux-auditor and move audit skills

```bash
mkdir -p workers/ux-auditor/skills
# From impeccable-designer (directory-based)
for skill in audit critique harden normalize; do
  mv "workers/impeccable-designer/skills/$skill" "workers/ux-auditor/skills/$skill"
done
# From gemini-ux-auditor (flat files)
for skill in ux-audit.md flow-review.md copy-review.md competitive-scan.md; do
  mv "workers/gemini-ux-auditor/skills/$skill" "workers/ux-auditor/skills/$skill"
done
# From gemini-designer (flat files)
for skill in design-audit.md design-system-check.md visual-diff.md; do
  mv "workers/gemini-designer/skills/$skill" "workers/ux-auditor/skills/$skill"
done
```

### Step 2 — Move build/refine skills to frontend-designer

```bash
mkdir -p workers/frontend-designer/skills
# From impeccable-designer (18 directory-based skills)
for skill in adapt animate arrange bolder clarify colorize consolidate delight distill extract frontend-design onboard optimize overdrive polish quieter teach-impeccable typeset; do
  mv "workers/impeccable-designer/skills/$skill" "workers/frontend-designer/skills/$skill"
done
# From gemini-stylist (4 flat files)
for skill in add-animation.md responsive-polish.md dark-mode.md css-refactor.md; do
  mv "workers/gemini-stylist/skills/$skill" "workers/frontend-designer/skills/$skill"
done
# From gemini-frontend (4 flat files)
for skill in build-component.md style-component.md responsive-check.md a11y-audit.md; do
  mv "workers/gemini-frontend/skills/$skill" "workers/frontend-designer/skills/$skill"
done
# From gemini-designer (1 flat file)
mv "workers/gemini-designer/skills/design-tokens.md" "workers/frontend-designer/skills/design-tokens.md"
```

### Step 3 — Copy new worker.yamls

Copy `workers/frontend-designer/worker.yaml` and `workers/ux-auditor/worker.yaml` from the release. These contain the merged skill blocks, instructions, and model configuration.

### Step 4 — Delete absorbed workers

```bash
rm -rf workers/impeccable-designer/
rm -rf workers/gemini-designer/
rm -rf workers/gemini-stylist/
rm -rf workers/gemini-frontend/
rm -rf workers/gemini-ux-auditor/
```

### Step 5 — Update registry.yaml

- Remove entries for: impeccable-designer, gemini-designer, gemini-stylist, gemini-frontend, gemini-ux-auditor
- Add entry for: ux-auditor
- Update frontend-designer description
- Update Standalone Workers count (11→9) and Gemini Team count (6→2)
- Bump version to 10.8.0

### Step 6 — Update invocations

Old commands → new equivalents:

| Old | New |
|-----|-----|
| `/run impeccable-designer audit` | `/run ux-auditor audit` |
| `/run impeccable-designer critique` | `/run ux-auditor critique` |
| `/run impeccable-designer harden` | `/run ux-auditor harden` |
| `/run impeccable-designer normalize` | `/run ux-auditor normalize` |
| `/run impeccable-designer {any other skill}` | `/run frontend-designer {skill}` |
| `/run gemini-stylist {skill}` | `/run frontend-designer {skill}` |
| `/run gemini-frontend {skill}` | `/run frontend-designer {skill}` |
| `/run gemini-designer design-tokens` | `/run frontend-designer design-tokens` |
| `/run gemini-designer {audit skills}` | `/run ux-auditor {skill}` |
| `/run gemini-ux-auditor {skill}` | `/run ux-auditor {skill}` |

### Step 7 — (Optional) Add style to .impeccable.md

If your project has an `.impeccable.md`, add a `style:` field to enable automatic style pack loading:

```markdown
## Style
style: american-industrial
```

Or re-run `teach-impeccable` to go through the style selection flow.

### Step 8 — Verify

```bash
ls workers/frontend-designer/skills/ | wc -l  # 27
ls workers/ux-auditor/skills/ | wc -l          # 11
# Ensure no stale references
grep -r "impeccable-designer\|gemini-designer\|gemini-stylist\|gemini-frontend\|gemini-ux-auditor" workers/ --include="*.yaml" | grep -v CHANGELOG
```

---

## Migrating to v10.7.1 (from v10.7.0)

### Headline

Core cleanup — 22 design skills moved from `.claude/skills/` to `workers/impeccable-designer/skills/`, 2 niche commands removed, `social-graphic` moved to `social-strategist`.

### Step 1 — Remove deleted commands

```bash
rm -f .claude/commands/pr.md .claude/commands/hq-growth-dashboard.md
```

### Step 2 — Move design skills to impeccable-designer

```bash
mkdir -p workers/impeccable-designer/skills
for skill in adapt animate arrange audit bolder clarify colorize consolidate critique delight distill extract frontend-design harden normalize onboard optimize overdrive polish quieter teach-impeccable typeset; do
  mv ".claude/skills/$skill" "workers/impeccable-designer/skills/$skill"
done
```

### Step 3 — Move social-graphic to social-strategist

```bash
mkdir -p workers/social-strategist/skills
mv .claude/skills/social-graphic workers/social-strategist/skills/social-graphic
```

### Step 4 — Update worker.yamls

Copy the updated `workers/impeccable-designer/worker.yaml` and `workers/social-strategist/worker.yaml` from the release, or manually add the new `skills:` blocks.

### Step 5 — Verify

```bash
ls .claude/commands/*.md | wc -l    # Should be 36
ls .claude/skills/ | wc -l          # Should be ~18 (core skills only)
ls workers/impeccable-designer/skills/ | wc -l  # Should be 22
```

---

## Migrating to v10.7.0 (from v10.6.0)

### Headline

This release ships the **HQ Performance Audit** — a ~50% reduction in session-start
context burn via pre-built policy digests, plus 8 commands consolidated to the new
**Archetype A** shape (thin delegator stub + canonical `SKILL.md`).

### Step 1 — Pull and verify scaffolding

```bash
git pull
ls .claude/hooks/load-policies-for-session.sh
ls .claude/policies/_digest.md
ls scripts/build-policy-digest.sh scripts/git-hooks/pre-commit
```

If any of those four are missing, your pull is incomplete — re-run.

### Step 2 — Wire the auto-rebuild pre-commit hook

The new `scripts/git-hooks/pre-commit` rebuilds `_digest.md` whenever you commit
policy changes. Install it:

```bash
chmod +x scripts/git-hooks/pre-commit
ln -sf ../../scripts/git-hooks/pre-commit .git/hooks/pre-commit
```

If you already have a `.git/hooks/pre-commit` wrapper, append a call to
`scripts/git-hooks/pre-commit` rather than overwriting.

### Step 3 — Verify the SessionStart hook fires

Start a fresh Claude Code session in the repo. Look for a `<policy-digest>` block
in the first system reminder. If you don't see it:

```bash
grep -A1 SessionStart .claude/settings.json
```

You should see the `load-policies-for-session.sh` entry. If missing, your
`settings.json` needs the SessionStart block — copy from `template/.claude/settings.json`.

### Step 4 — Port any local edits to the 7 consolidated commands

These commands now delegate to `SKILL.md`. If you had local customizations in any
of them, your edits will be **overwritten** when you sync the template:

| Command | Canonical home |
|---|---|
| `prd` | `.claude/skills/prd/SKILL.md` |
| `handoff` | `.claude/skills/handoff/SKILL.md` |
| `learn` | `.claude/skills/learn/SKILL.md` |
| `execute-task` | `.claude/skills/execute-task/SKILL.md` |
| `search` | `.claude/skills/search/SKILL.md` |
| `startwork` | `.claude/skills/startwork/SKILL.md` |
| `brainstorm` | `.claude/skills/brainstorm/SKILL.md` |

For each, diff the old `.md` against the new SKILL.md, port your customizations
into the SKILL, and let the stub remain as a thin delegator.

### Step 5 — Optional: rebuild your digests

If you've modified policies locally, regenerate `_digest.md`:

```bash
bash scripts/build-policy-digest.sh
```

The pre-commit hook from Step 2 will keep this in sync going forward.

### What you get after migrating

- **−50% session-start context** on most cwds (HQ root, personal, vyg-class)
- **Faster orientation** — the policy digest lands in the first turn instead of
  burning a tool round-trip
- **Auto-maintained digests** — no manual rebuild required after the pre-commit
  hook is installed

---

## Migrating to v10.6.0 (from v10.5.0)

### Updated Commands (21)

Diff and merge updated commands:
```bash
diff -rq template/.claude/commands/ your-hq/.claude/commands/
```

Key commands to review: `audit`, `checkpoint`, `cleanup`, `garden`, `handoff`, `harness-audit`, `hq-growth-dashboard`, `learn`, `newworker`, `pr`, `prd`, `reanchor`, `recover-session`, `remember`, `run-pipeline`, `run-project`, `run`, `search-reindex`, `search`, `startwork`, `understand-project`

### Updated Skills (11)

Diff and merge updated skills:
```bash
diff -rq template/.claude/skills/ your-hq/.claude/skills/
```

Updated: `ascii-graphic`, `colorize`, `consolidate`, `execute-task`, `handoff`, `land`, `prd`, `run-project`, `run`, `search`, `social-graphic`

### New Hook

Copy the new MCP cleanup hook:
```bash
cp template/.claude/hooks/cleanup-mcp-processes.sh your-hq/.claude/hooks/
chmod +x your-hq/.claude/hooks/cleanup-mcp-processes.sh
```

Then add the Stop hook entry to your `.claude/settings.json` hooks section:
```json
{
  "type": "command",
  "command": ".claude/hooks/hook-gate.sh cleanup-mcp-processes .claude/hooks/cleanup-mcp-processes.sh",
  "timeout": 5
}
```

### Updated Policies

Sync 154 scope-filtered policies:
```bash
diff -rq template/.claude/policies/ your-hq/.claude/policies/
```

### Breaking Changes
- (none this release)

---

## Migrating to v10.5.0 (from v10.4.0)

### New Command

Copy the new command:
```bash
cp template/.claude/commands/run-pipeline.md your-hq/.claude/commands/
```

### New Skill

Copy the new skill directory:
```bash
cp -r template/.claude/skills/land-batch/ your-hq/.claude/skills/land-batch/
```

### Updated Commands (18)

Diff and merge updated commands:
```bash
diff -rq template/.claude/commands/ your-hq/.claude/commands/
```

### Updated Skills (13)

Diff and merge updated skills:
```bash
diff -rq template/.claude/skills/ your-hq/.claude/skills/
```

### New Policies (8)

Copy new policies:
```bash
for p in hq-bugfix-requires-tests hq-data-collection-isolation hq-github-review-thread-resolution hq-no-test-shortcuts hq-no-worktree-for-repo-work paper-text-wrapping; do
  cp template/.claude/policies/${p}.md your-hq/.claude/policies/
done
```

### Updated Hooks (11)

```bash
cp template/.claude/hooks/*.sh your-hq/.claude/hooks/
chmod +x your-hq/.claude/hooks/*.sh
```

### Updated Settings

Add `PATH` to your `.claude/settings.json` env block:
```json
"PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
```

### Updated modules.yaml

The `hq-core` module now points to `indigoai-us/hq` instead of the archived `hq-starter-kit`. Update your `modules/modules.yaml` accordingly.

### Knowledge Bases

Rsync updated knowledge:
```bash
rsync -av template/knowledge/ your-hq/knowledge/ --exclude='.git/'
```

### Breaking Changes
- (none)

---

## Migrating to v10.4.0 (from v10.3.0)

### New Skills (9 Codex-ready skills)

Copy these skill directories:

```bash
for s in brainstorm execute-task handoff learn prd run run-project search startwork; do
  cp -r template/.claude/skills/$s/ your-hq/.claude/skills/$s/
done
```

Each includes `SKILL.md` + `agents/openai.yaml` for dual Claude Code / Codex discovery.

### Updated Scripts

```bash
cp template/scripts/codex-skill-bridge.sh your-hq/scripts/codex-skill-bridge.sh
chmod +x your-hq/scripts/codex-skill-bridge.sh
```

### Updated CLAUDE.md

The Skills section now includes Codex dual-format documentation. Merge the new section from `template/.claude/CLAUDE.md` into your CLAUDE.md.

### Updated Denylist

If you use `/publish-kit`, update your `scrub-denylist.yaml` with the new `exceptions` section:

```yaml
exceptions:
  "indigoai-us": "indigoai-us"
  "@indigoai-us": "@indigoai-us"
  "indigoai-us/hq": "indigoai-us/hq"
```

### Updated Policies

154 policies synced. Run a diff to merge new/changed policies:
```bash
diff -rq template/.claude/policies/ your-hq/.claude/policies/
```

### Breaking Changes
- (none)

---

## Migrating to v10.3.0 (from v10.2.0)

Minor release. No breaking changes.

### New Skill

Copy the `land` skill directory:

```bash
cp -r template/.claude/skills/land/ your-hq/.claude/skills/land/
```

### New Policies

Copy these 12 policies from `template/.claude/policies/`:

```bash
for p in hq-alert-baseline-calibration hq-announce-before-irreversible hq-confirm-creative-direction hq-fix-root-cause-not-symptoms hq-never-swallow-errors hq-no-production-testing hq-post-parallel-build-verify hq-pr-single-concern prd-files-match-acs-for-swarm run-project-name-matches-dir run-project-sigkill-retry scrub-hook-no-denylist-in-template; do
  cp "template/.claude/policies/${p}.md" "your-hq/.claude/policies/${p}.md"
done
```

### Updated Commands

Review and merge changes to:
- `.claude/commands/run-project.md` (new `--inline` execution mode)
- `.claude/commands/update-hq.md` (rewritten for indigoai-us/hq)
- `.claude/commands/hq-growth-dashboard.md` (updated repo references)

### Breaking Changes
- (none this release)

---

## Migrating to v10.2.0 (from v10.1.0)

Minor release. No breaking changes.

### New: Codex App Skill Discovery

All 30 HQ skills now include `agents/openai.yaml` for Codex UI rendering. To add them:

```bash
# Copy agents/openai.yaml into each skill dir
for d in starter-kit/.claude/skills/*/agents/; do
  skill=$(basename "$(dirname "$d")")
  mkdir -p "your-hq/.claude/skills/${skill}/agents"
  cp "${d}openai.yaml" "your-hq/.claude/skills/${skill}/agents/openai.yaml"
done
```

Or regenerate from your own SKILL.md files:

```bash
cp starter-kit/scripts/generate-openai-yaml.sh your-hq/scripts/
bash your-hq/scripts/generate-openai-yaml.sh
```

### Updated: Codex Skill Bridge

Copy the updated bridge script:

```bash
cp starter-kit/scripts/codex-skill-bridge.sh your-hq/scripts/codex-skill-bridge.sh
chmod +x your-hq/scripts/codex-skill-bridge.sh
bash your-hq/scripts/codex-skill-bridge.sh install
```

This adds the `.agents/skills/` discovery paths that Codex now prefers over `.codex/skills/`.

### Updated Files

Run `/update-hq` or manually merge changes to:
- Multiple commands, policies, hooks, and knowledge bases
- `CLAUDE.md`, `USER-GUIDE.md`

---

## Migrating to v10.1.0 (from v10.0.0)

Minor release. No breaking changes.

### New: Getting Started Education Kit

Copy the new knowledge directory to your HQ:

```bash
cp -R starter-kit/knowledge/public/getting-started/ your-hq/knowledge/public/getting-started/
```

This adds 3 onboarding guides (quick-start-guide, cheatsheet, learning-path) that `/setup` now references.

### Updated: `/setup` Command

Copy the updated setup command:

```bash
cp starter-kit/.claude/commands/setup.md your-hq/.claude/commands/setup.md
```

The setup flow now includes a welcome phase, educational bridges, and auto-opens the quick-start-guide after completion.

### New Policies

Copy these 4 new policies:

```bash
for p in bun-overrides chunked-reads clipboard-file-protocol deconflict-postbridge-schedule; do
  cp "starter-kit/.claude/policies/${p}.md" "your-hq/.claude/policies/${p}.md"
done
```

### Updated Files

Run `/update-hq` or manually merge changes to:
- Multiple commands, policies, workers, and knowledge bases
- `CLAUDE.md`, `USER-GUIDE.md`, `modules.yaml`

---

## Migrating to v10.0.0 (from v9.0.0)

Minor release. No breaking changes.

### New: Obsidian Vault
Copy `.obsidian/` to your HQ root. Open in Obsidian — works out of the box. See `knowledge/public/hq-core/obsidian-setup.md` for details.

Add to your `.gitignore`:
```
.obsidian/workspace.json
.obsidian/workspace-mobile.json
.obsidian/plugins/
.obsidian/themes/
.obsidian/community-plugins.json
```

### New Command
- `/hq-growth-dashboard` — copy `.claude/commands/hq-growth-dashboard.md`

### New Hook
- `protect-core.sh` — copy `.claude/hooks/protect-core.sh`, `chmod +x`

### Updated Files
Run `/update-hq` or manually merge changes to:
- 16 commands, 4 skills, 30+ policies, 4 hooks, 5 workers
- `CLAUDE.md`, `USER-GUIDE.md`, `modules.yaml`

### Removed
- Delete `.claude/policies/qa-screenshot-isolation.md` (replaced by `image-context-isolation.md`)

---

## Migrating to v9.0.0 (from v8.x)

This is a major release. Three new directories are introduced.

### New: Skills (`.claude/skills/`)

Copy the entire `.claude/skills/` directory from the starter-kit. This adds 30 design, code quality, and workflow skills that power commands like `/polish`, `/investigate`, `/audit`, etc.

```bash
cp -R starter-kit/.claude/skills/ your-hq/.claude/skills/
```

### New: Policies (`.claude/policies/`)

Copy the entire `.claude/policies/` directory. These are 89 structured workflow rules covering git safety, Vercel gotchas, Supabase patterns, orchestrator guardrails, and more.

```bash
cp -R starter-kit/.claude/policies/ your-hq/.claude/policies/
```

### New: Infrastructure Files

Copy these files to your HQ root:

| File | Purpose |
|------|---------|
| `.ignore` | Ripgrep config — blocks `repos/`, `node_modules/` from Grep |
| `settings/orchestrator.yaml` | Swarm/file-locking config for `/run-project` |
| `USER-GUIDE.md` | Command reference + worker guide |
| `modules/modules.yaml` | Knowledge module registry |
| `scripts/codex-skill-bridge.sh` | Codex ↔ Claude skill bridge |
| `scripts/audit-log.sh` | Structured audit log utility |
| `scripts/resize-screenshot.sh` | Screenshot resize (used by hook) |

### Updated Files

Review and merge changes to all existing commands, workers, and knowledge. The easiest approach:

```bash
# From your HQ root, with starter-kit cloned alongside:
rsync -avL --ignore-existing starter-kit/.claude/commands/ .claude/commands/
rsync -avL --ignore-existing starter-kit/workers/public/ workers/public/
rsync -avL --ignore-existing starter-kit/knowledge/ knowledge/public/
```

### Breaking Changes
- None — all additions are backward-compatible

---

## Migrating to v8.2.0 (from v8.1.x)

### New Commands
Copy these files from starter-kit to your HQ:
- `.claude/commands/document-release.md`
- `.claude/commands/investigate.md`
- `.claude/commands/retro.md`

### New Hook
Copy to your HQ:
- `.claude/hooks/block-inline-story-impl.sh` — run `chmod +x` after copying

### Updated Commands
Review and merge changes to these 19 commands:
- `audit.md`, `brainstorm.md`, `cleanup.md`, `execute-task.md`, `garden.md`
- `harness-audit.md`, `model-route.md`, `prd.md`, `reanchor.md`, `recover-session.md`
- `remember.md`, `review-plan.md`, `run-project.md`, `run.md`, `search-reindex.md`
- `search.md`, `startwork.md`, `update-hq.md`, `review.md`, `understand-project.md`

### Updated Hooks
Replace these hooks (run `chmod +x` after copying):
- `.claude/hooks/auto-checkpoint-trigger.sh`
- `.claude/hooks/hook-gate.sh`
- `.claude/hooks/observe-patterns.sh`

### Updated Scripts
Replace:
- `.claude/scripts/run-project.sh` — adds story test runner + codex model hints

### New Workers
Copy these directories to `workers/`:
- `workers/impeccable-designer/`
- `workers/paper-designer/`

Update `workers/registry.yaml` — version bumped to v10.0 with 45 public workers.

### New Knowledge
Copy these to `knowledge/`:
- `knowledge/impeccable/` (new knowledge base)
- `knowledge/design-styles/formulas/` (new subtree)
- `knowledge/agent-browser/tauri-testing.md`
- `knowledge/hq/handoff-templates.md`
- `knowledge/hq/knowledge-taxonomy.md`

### Removed
- Delete `.claude/commands/imessage.md` if present (personal command, removed from starter-kit)

### PII Scrub
This release scrubbed all company-specific references. If you forked from an earlier version, review your files for any {PRODUCT}/{Product}/{company} references and replace with generic placeholders.

### Breaking Changes
- None

---

## Migrating to v8.1.1 (from v8.1.0)

### New directories (create manually)
Existing installs need to create these directories:
```bash
mkdir -p repos/public repos/private
mkdir -p companies/_template/policies
mkdir -p settings data modules scripts
mkdir -p workspace/learnings workspace/reports
```

### New files
Copy from starter-kit to your HQ:
- `companies/_template/policies/example-policy.md`
- `companies/manifest.yaml` (if you don't already have one)
- `.ignore` (ripgrep ignore — prevents Grep from scanning repos/)
- `.claude/commands/review.md`
- `.claude/commands/review-plan.md`
- `.claude/skills/review/` (entire directory)
- `.claude/skills/review-plan/` (entire directory)

### Updated hooks
Replace these files:
- `.claude/hooks/auto-checkpoint-trigger.sh`

### No breaking changes

---

## Migrating to v8.1.0 (from v8.0.x)

### Updated run-project.sh (full replace)
Major upgrade: 3-layer passes detection, swarm retry tracking, per-story branch isolation, project reanchor, codex autofix, macOS timeout fallback.
```bash
cp starter-kit/.claude/scripts/run-project.sh .claude/scripts/run-project.sh
# or if you keep it at scripts/run-project.sh:
cp starter-kit/.claude/scripts/run-project.sh scripts/run-project.sh
chmod +x .claude/scripts/run-project.sh  # or scripts/run-project.sh
```

### Updated Commands (15 files)
```bash
for f in run-project prd audit cleanup garden model-route reanchor recover-session remember run search search-reindex startwork update-hq; do
  cp starter-kit/.claude/commands/$f.md .claude/commands/
done
```

### Updated CLAUDE.md
Three changes to merge:
1. **Token table** — `MAX_THINKING_TOKENS` → `31999`, new `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING` row
2. **Linear rules 11 & 12** — Default assignee by team + no-orphan-issues
```bash
diff .claude/CLAUDE.md starter-kit/.claude/CLAUDE.md
```

### `/prd` — Behavioral Change
`/prd` now uses a 7-batch question flow (was 4-batch). The interview is more thorough with separate batches for Users/Current State, Data/Architecture, Integrations, and Quality/Shipping. No schema changes — existing prd.json files are fully compatible.

### Migration Steps
1. Replace `run-project.sh` and `chmod +x`
2. Copy 15 updated commands
3. Merge 3 CLAUDE.md changes (token table, Linear rules)
4. Run `/search-reindex`

### Breaking Changes
- (none)

---

## Migrating to v8.0.0 (from v7.0.0)

### Updated Commands (9 files)
These commands now include policy loading. Copy from starter-kit to your HQ:
```bash
for f in audit handoff harness-audit learn model-route prd run-project run startwork; do
  cp starter-kit/.claude/commands/$f.md .claude/commands/
done
```

### New Command (1 file)
```bash
cp starter-kit/.claude/commands/strategize.md .claude/commands/
```

### Updated CLAUDE.md
The Policies section now includes a **Standard Policy Loading Protocol**. Review and merge:
```bash
diff .claude/CLAUDE.md starter-kit/.claude/CLAUDE.md
```
Key addition: 5-step protocol for commands to load company → repo → global policies, plus list of implementing commands.

### Updated run-project.sh
Major upgrade: swarm mode (parallel story execution), worktree isolation, signal trapping, headless doc sweep, budget caps removed. Copy:
```bash
cp starter-kit/.claude/scripts/run-project.sh .claude/scripts/run-project.sh
# or if you keep it at scripts/run-project.sh:
cp starter-kit/.claude/scripts/run-project.sh scripts/run-project.sh
chmod +x scripts/run-project.sh
```

### Updated execute-task.md
Self-owned lock skip for swarm mode + single-writer pattern (orchestrator writes `passes`). Already included in the 9-file copy above.

### New: orchestrator.yaml
Swarm configuration. Copy to your settings dir:
```bash
cp starter-kit/settings/orchestrator.yaml settings/orchestrator.yaml
```

### `/learn` — Breaking Behavioral Change
`/learn` now creates **policy files** (structured markdown with YAML frontmatter) as its primary output instead of injecting rules into `worker.yaml` or `CLAUDE.md`. Existing learned rules in worker.yaml files still work but new learnings will be written as policy files in:
- `companies/{co}/policies/` (company scope)
- `repos/{repo}/.claude/policies/` (repo scope)
- `.claude/policies/` (global/command scope)

No action needed — old rules remain valid. New rules will be policy files.

---

## Migrating to v7.0.0 (from v6.5.1)

### New Hooks (3 files)
Copy to `.claude/hooks/` and make executable:
```bash
cp starter-kit/.claude/hooks/hook-gate.sh .claude/hooks/
cp starter-kit/.claude/hooks/detect-secrets.sh .claude/hooks/
cp starter-kit/.claude/hooks/observe-patterns.sh .claude/hooks/
chmod +x .claude/hooks/hook-gate.sh .claude/hooks/detect-secrets.sh .claude/hooks/observe-patterns.sh
```

### Settings.json — Hook Rewiring (BREAKING)
Your `.claude/settings.json` hooks are rewired through `hook-gate.sh`. This is a **breaking change** if you have custom hooks.

**Before (v6.5.1):**
```json
{ "matcher": "Glob", "hooks": [{ "type": "command", "command": ".claude/hooks/block-hq-glob.sh" }] }
```

**After (v7.0.0):**
```json
{ "matcher": "Glob", "hooks": [{ "type": "command", "command": ".claude/hooks/hook-gate.sh block-hq-glob .claude/hooks/block-hq-glob.sh" }] }
```

Copy the full `settings.json` from starter-kit, or manually rewire each hook through `hook-gate.sh`. Two new hooks added:
- PreToolUse Bash → `hook-gate.sh detect-secrets .claude/hooks/detect-secrets.sh`
- Stop → `hook-gate.sh observe-patterns .claude/hooks/observe-patterns.sh`

### New Script
```bash
mkdir -p scripts/
cp starter-kit/scripts/audit-log.sh scripts/
chmod +x scripts/audit-log.sh
```

### Updated Script
Replace `.claude/scripts/run-project.sh` with the full v7.0.0 version (1390 lines). Includes audit log integration and `--tmux` mode.

### New Commands (9 files)
Copy to `.claude/commands/`:
- `audit.md`, `brainstorm.md`, `dashboard.md`, `goals.md`, `harness-audit.md`, `idea.md`, `model-route.md`, `quality-gate.md`, `tdd.md`

### Updated Commands (3 files)
Review and merge:
- `execute-task.md` — Checkout guard (section 2.6) prevents concurrent story execution
- `prd.md` — Brainstorm detection (steps 3.5 + 5.5)
- `run-project.md` — Worked example, `--tmux` flag

### New Workers (4 dirs)
Copy to `workers/`:
- `accessibility-auditor/` — WCAG 2.2 AA auditing
- `exec-summary/` — McKinsey SCQA executive summaries
- `performance-benchmarker/` — Core Web Vitals + k6 load testing
- `dev-team/reality-checker/` — Final quality gate

### Registry Update
Replace `workers/registry.yaml`. Version 8.0 → 9.0. If you have custom workers, merge them into the `# Add your workers below` section.

### Removed Workers
Delete these directories if present (were private/company-specific, leaked in v6.0.0):
- `workers/pr-shared/`, `pr-strategist/`, `pr-writer/`, `pr-outreach/`, `pr-monitor/`, `pr-coordinator/`

### Knowledge Cleanup
- Delete `knowledge/hq/` if present (duplicate of `knowledge/hq-core/`)
- Copy `knowledge/hq-core/handoff-templates.md` from starter-kit

### CLAUDE.md Updates

**New sections to add:**
1. **Token Optimization** (after Context Diet) — Env var cost controls
2. **Hook Profiles** (after Token Optimization) — Runtime hook configuration

**Sections to update:**
- **Workers** — Add accessibility-auditor, exec-summary, performance-benchmarker, reality-checker. Remove pr-team. Dev Team 16→17
- **Commands count** — Update to 35+

### Migration Steps
1. Copy 3 new hooks and `chmod +x`
2. Update `settings.json` (hook-gate rewiring)
3. Copy `scripts/audit-log.sh` and `chmod +x`
4. Replace `.claude/scripts/run-project.sh`
5. Copy 9 new commands
6. Merge 3 updated commands
7. Copy 4 new worker directories
8. Delete 6 PR team worker directories
9. Update `workers/registry.yaml` (merge custom workers)
10. Delete `knowledge/hq/` duplicate
11. Merge CLAUDE.md sections (Token Optimization, Hook Profiles)
12. Run `/search-reindex`

### Breaking Changes
- `settings.json` hooks now route through `hook-gate.sh` — direct hook commands no longer work without the gate
- PR team workers removed — if you use them, keep your local copies
- `knowledge/hq/` deleted — use `knowledge/hq-core/` instead

---

## Migrating to v6.5.1 (from v6.5.0)

### New Files
- `.claude/hooks/block-hq-grep.sh` — Grep safety hook
- `.claude/hooks/warn-cross-company-settings.sh` — Cross-company settings warning
- `workers/dev-team/context-manager/` — Context management worker (4 skills)

### Updated Files
- `.claude/CLAUDE.md` — New LSP section
- `.claude/settings.json` — Added Grep and Read PreToolUse hooks
- `README.md` — LSP setup in prerequisites

### CLAUDE.md Updates

**New section to add (after Search):**
- **LSP** — When `ENABLE_LSP_TOOL=1` is set, prefer LSP tools over Grep for code navigation

### Settings.json Updates
Add these to your `PreToolUse` hooks array:
```json
{
  "matcher": "Grep",
  "hooks": [{ "type": "command", "command": ".claude/hooks/block-hq-grep.sh", "timeout": 5 }]
},
{
  "matcher": "Read",
  "hooks": [{ "type": "command", "command": ".claude/hooks/warn-cross-company-settings.sh", "timeout": 5 }]
}
```

### Removed Commands
- `/checkemail` — Moved to private (requires personal Gmail config)
- `/email` — Moved to private (requires personal Gmail config)

If you use these commands, keep your local copies. They are no longer part of the public starter kit.

### Breaking Changes
- (none)

---

## Migrating to v6.5.0 (from v6.4.0)

### New Workers
Copy these directories from starter-kit to your HQ `workers/public/`:
- `workers/gemini-coder/` — Gemini CLI code generation
- `workers/gemini-reviewer/` — Gemini CLI code review
- `workers/gemini-frontend/` — Gemini CLI frontend generation
- `workers/knowledge-tagger/` — Knowledge document classification
- `workers/site-builder/` — Local business website builder

Update `workers/registry.yaml` to include the new entries.

### New Knowledge Bases
Copy from starter-kit to your HQ `knowledge/public/`:
- `knowledge/gemini-cli/` — Gemini CLI integration docs

### Updated Commands
Review and merge changes to:
- `.claude/commands/execute-task.md` — Refined codex-reviewer, back-pressure handling
- `.claude/commands/prd.md` — Company Anchor (Step 0), Beads sync (Step 7)
- `.claude/commands/run-project.md` — Externalized to bash script, CLI flags
- `.claude/commands/handoff.md` — Knowledge update step (0b)
- `.claude/commands/learn.md` — Target-file injection, cap enforcement, global promotion
- `.claude/commands/startwork.md` — Company knowledge loading, Vercel context
- `.claude/commands/checkemail.md` — Email-triage app integration
- `.claude/commands/email.md` — 4-phase triage, Linear/PRD creation


### CLAUDE.md Updates

**New sections to add:**
1. **Skills** (after Company Isolation) — `.claude/skills/` tree with Codex bridge
2. **Policies (Learned Rules)** (before Core Principles) — Policy file directories and precedence

**Sections to update:**
- **Company Isolation** — Add manifest infrastructure routing fields, 3-step operation protocol, credential access reference
- **Workers** — Update counts for social-team (5), pr-team (6), gardener-team (3), gemini-team (3), knowledge-tagger, site-builder
- **Search rules** — Add PRD/worker/company discovery rows, Glob blocking rule
- **Knowledge Repos** — Add embedded git repo pattern, `Reading/searching` note
- **Knowledge Bases** — Add: agent-browser, curious-minds, gemini-cli, pr, context-needs, project-context
- **Infrastructure-First** — Update `/prd` path to company-scoped
- **Commands count** — Update to 35+

### Breaking Changes
- `/run-project` now delegates to `scripts/run-project.sh`. If you don't have this script, the command falls back to in-session execution.

---

## Migrating to v6.4.0 (from v6.3.0)

### New Commands
Copy these files from starter-kit to your HQ:
- `.claude/commands/imessage.md` — Send iMessage to contacts

### Updated Commands
Review and merge changes to:
- `.claude/commands/execute-task.md` — File lock acquisition (5.5), policy loading (5.6), dynamic lock expansion (6d.5), lock release on failure (8.0), iMessage notify (7c.5), Linear comments (7a.6), company-scoped project resolution
- `.claude/commands/prd.md` — Company-scoped projects (`companies/{co}/projects/`), `files` field in story schema, board sync (5.5), mandatory creation rule, STOP after creation
- `.claude/commands/run-project.md` — Company-scoped resolution, board sync (4.5), file lock conflict check (5a.1), Linear comments (5a.6), policy re-read in auto-reanchor
- `.claude/commands/newworker.md` — Company-scoped worker paths
- `.claude/commands/checkpoint.md` — Embedded repo support in knowledge state capture

### CLAUDE.md Updates

**Policies section** — Replace with three-directory structure:
```
Before executing tasks, load applicable policies from all three directories:
1. companies/{co}/policies/ — company-scoped rules
2. repos/{repo}/.claude/policies/ — repo-scoped rules
3. .claude/policies/ — cross-cutting + command-scoped rules
Precedence: company > repo > command > global
```

**Learning System section** — Update to reflect policy-file-based approach (learnings → policy files, not inline injection).

**Knowledge Repos section** — Distinguish embedded company repos from symlinked shared repos.

**Commands count** — Update "23 commands" → "24 commands".

### Breaking Changes
- `/prd` now creates projects at `companies/{co}/projects/{name}/` instead of `projects/{name}/`. Root `projects/` is fallback for personal/HQ-only projects.
- `/prd` now requires `/handoff` after creation — no implementation in same session.

---

## Migrating to v6.3.0 (from v6.2.0)

### New Files
- `.claude/hooks/block-hq-glob.sh` — Glob safety hook (blocks Glob from HQ root to prevent timeouts)
- `companies/_template/policies/example-policy.md` — Policy template for `/newcompany` scaffolding

### Updated Files
- `.claude/CLAUDE.md` — 2 new sections (Policies, File Locking) + expanded Company Isolation + 4 new learned rules
- `.claude/settings.json` — New PreToolUse hook for Glob safety
- `.claude/commands/update-hq.md` — settings.json merge logic (5b-SETTINGS), template directory handling

### New CLAUDE.md Sections
Add these sections to your `.claude/CLAUDE.md`:

1. **Policies** (after Company Isolation) — Company-scoped standing rules with hard/soft enforcement
2. **File Locking** (after Sub-Agent Rules) — Concurrent edit prevention for multi-agent projects

### New Company Isolation Rules
Add to your `## Company Isolation` section:
- `NEVER use Linear credentials from a different company's settings`
- `Before any Linear API call, validate: config.json workspace field matches expected company`

### New Learned Rules
Add to your `## Learned Rules` section:
- `pre-deploy domain check` — Always check live URL and domain ownership before deploying to custom domains
- `EAS build env vars` — EAS production builds don't inherit local .env; set EXPO_PUBLIC_* via CLI
- `Vercel env var trailing newlines` — Use printf not echo when piping to vercel env add
- `model routing` — Workers declare execution.model in worker.yaml; stories can override via model_hint

### Glob Safety Hook
1. Copy `.claude/hooks/block-hq-glob.sh` to your HQ
2. Make executable: `chmod +x .claude/hooks/block-hq-glob.sh`
3. Add to your `.claude/settings.json` under `hooks`:
   ```json
   "PreToolUse": [
     {
       "matcher": "Glob",
       "hooks": [
         {
           "type": "command",
           "command": ".claude/hooks/block-hq-glob.sh",
           "timeout": 5
         }
       ]
     }
   ]
   ```

### Migration Steps
1. Copy `.claude/hooks/block-hq-glob.sh` and make executable
2. Merge PreToolUse section into your `.claude/settings.json` (or let `/update-hq` handle it — v6.3.0 adds JSON-aware settings merge)
3. Merge 2 new CLAUDE.md sections: Policies, File Locking
4. Add 2 new Company Isolation rules
5. Add 4 new learned rules to your Learned Rules section
6. Copy `companies/_template/policies/example-policy.md` for policy scaffolding
7. Update `.claude/commands/update-hq.md` for safe settings.json migration in future upgrades
8. Run `/search-reindex`

### Breaking Changes
- (none)

---

## Migrating to v6.2.0 (from v6.1.0)

### Updated Files
Merge changes to:
- `.claude/CLAUDE.md` — 5 new behavioral sections + 6 new learned rules

### New CLAUDE.md Sections
Add these sections to your `.claude/CLAUDE.md`:

1. **Session Handoffs** (after Context Diet) — Handoff workflow rules
2. **Corrections & Accuracy** (after Session Handoffs) — User correction handling
3. **Sub-Agent Rules** (after Workers) — Multi-agent commit coordination
4. **Git Workflow Rules** (before Project Repos - Commit Rules) — Git hygiene
5. **Vercel Deployments** (after Project Repos - Commit Rules) — Deploy safety

### New Learned Rules
Add to your `## Learned Rules` section:
- `vercel custom domain deploy safety` — Never deploy to production custom domains without confirmation
- `Task() sub-agents lack MCP` — Sub-agents can't use MCP tools, use CLI instead
- `Shopify 2026 auth` — Ephemeral tokens via client_credentials grant
- `vercel preview SSO` — `--public` doesn't bypass SSO; use local testing
- `Vercel domain team move` — API for moving domains between Vercel teams
- `Vercel framework detection` — `framework: null` causes 404s on all routes

### Migration Steps
1. Merge 5 new sections from starter-kit `.claude/CLAUDE.md` into yours
2. Add 6 new learned rules to your `## Learned Rules` section
3. Update `<!-- Max -->` comment to 25
4. Run `/search-reindex`

### Breaking Changes
- (none)

---

## Migrating to v6.1.0 (from v6.0.0)

### Prerequisites
- Codex CLI installed: `npm install -g @openai/codex` (or `brew install codex`)
- Codex authenticated: `codex login`
- If Codex CLI is not available, the pipeline degrades gracefully (warns and skips Codex phases)

### Updated Commands
Replace in `.claude/commands/`:
- `execute-task.md` — New inline Codex review step + pre-flight check

### Updated Workers
Replace these directories in `workers/dev-team/`:
- `codex-reviewer/` — Skills rewritten from MCP to CLI
- `codex-coder/` — Skills rewritten from MCP to CLI
- `codex-debugger/` — Skills rewritten from MCP to CLI
- `codex-engine/package.json` — Updated description only

### Breaking Changes
- **MCP server no longer used by pipeline** — If you had custom integrations calling the codex-engine MCP server from within worker phases, those will need to switch to `codex review` / `codex exec` CLI calls. The MCP server still works for standalone use via `/run`.

---

## Migrating to v6.0.0 (from v5.5.x)

### New Commands
Copy to `.claude/commands/`:
- `garden.md` — Multi-worker HQ content audit & cleanup
- `startwork.md` — Lightweight session entry
- `newcompany.md` — Scaffold new company infrastructure
- `{custom-command}.md` — Student onboarding pipeline

### Updated Commands
Review and merge changes to all existing commands — 22 commands were refreshed. Key ones:
- `execute-task.md` — Worker pipeline updates
- `run-project.md` — Orchestration improvements
- `cleanup.md` — New audit checks
- `prd.md` — Enhanced discovery flow

### New Worker Teams
Copy these directories to `workers/`:
- `workers/dev-team/` — Full 16-worker development team (architect, backend-dev, frontend-dev, database-dev, QA, etc.)
- `workers/content-brand/`, `content-sales/`, `content-product/`, `content-legal/`, `content-shared/` — Content pipeline
- `workers/social-shared/`, `social-strategist/`, `social-reviewer/`, `social-publisher/`, `social-verifier/` — Social pipeline
- `workers/pr-shared/`, `pr-strategist/`, `pr-writer/`, `pr-outreach/`, `pr-monitor/`, `pr-coordinator/` — PR pipeline
- `workers/gardener-team/` — Content audit team (garden-scout, garden-auditor, garden-curator)
- `workers/frontend-designer/`, `qa-tester/`, `security-scanner/`, `pretty-mermaid/` — Standalone workers

### Registry Update
Replace `workers/registry.yaml` with the new v7.0 version. If you have custom workers, merge them into the `# Add your workers below` section at the bottom.

### Knowledge Updates
Copy updated knowledge directories:
- `knowledge/agent-browser/` (new)
- `knowledge/pr/` (new)
- `knowledge/curious-minds/` (new)
- All existing knowledge dirs refreshed

### CLAUDE.md Update
Review and merge `.claude/CLAUDE.md` — significant additions including gardener team, learned rules system, company isolation rules.

### Breaking Changes
- Registry version 6.0 → 7.0. Worker paths restructured. Custom workers need manual merge.
- Dev team workers re-included (were removed in v5.0.0). If you built custom equivalents, check for conflicts.

---

## Migrating to v5.5.1 (from v5.5.0)

### Updated Commands
Review and merge changes to:
- `.claude/commands/setup.md` — repos directory now created as first step in Phase 2
- `.claude/commands/update-hq.md` — repos validation added to pre-flight checks

### New Directories
If missing, create:
```bash
mkdir -p repos/public repos/private
```
These are required for all code, knowledge, and project repos.

### Breaking Changes
- (none)

---

## Migrating to v5.5.0 (from v5.4.0)

### New Command
Copy to `.claude/commands/`:
- `recover-session.md` — Recover dead sessions that hit context limits

### Renamed Command
- `.claude/commands/migrate.md` → `.claude/commands/update-hq.md` — Same functionality, friendlier name

### Updated Files
- `.claude/CLAUDE.md` — Merge the new "Communication" commands section, add `/recover-session` to Session Management, replace `/migrate` with `/update-hq` in System table

### Migration Steps
1. Copy `.claude/commands/recover-session.md`
2. Rename `.claude/commands/migrate.md` to `.claude/commands/update-hq.md` (or copy fresh from starter-kit)
3. Update your `.claude/CLAUDE.md` command count and tables
4. Run `/search-reindex`

### Breaking Changes
- `/migrate` renamed to `/update-hq` — if you have scripts or docs referencing `/migrate`, update them

---

## Migrating to v5.4.0 (from v5.3.0)

### New Commands
Copy these files from starter-kit to your HQ:
- `.claude/commands/checkemail.md` — Inbox cleanup with auto-archive + triage
- `.claude/commands/decide.md` — Batch decision UI for human-in-the-loop workflows
- `.claude/commands/email.md` — Multi-account Gmail management

### Updated Commands
Review and merge changes to these 12 commands:
- `.claude/commands/run-project.md` — **Important:** Anti-plan directive added to sub-agent prompt
- `.claude/commands/execute-task.md` — **Important:** Anti-plan rule added to Rules section
- `.claude/commands/checkpoint.md`, `cleanup.md`, `handoff.md`, `metrics.md`, `newworker.md`, `reanchor.md`, `remember.md`, `run.md`, `search.md`, `search-reindex.md`

### New Knowledge
Copy the new knowledge files:
- `knowledge/hq-core/quick-reference.md`
- `knowledge/hq-core/starter-kit-compatibility-contract.md`
- `knowledge/hq-core/desktop-claude-code-integration.md`
- `knowledge/hq-core/desktop-company-isolation.md`
- `knowledge/hq-core/hq-structure-detection.md`
- `knowledge/hq-core/hq-desktop/` (entire directory — 12 spec files for HQ Desktop)

### Updated Knowledge
Review and merge:
- `knowledge/hq-core/index-md-spec.md`
- `knowledge/hq-core/thread-schema.md`
- `knowledge/workers/skill-schema.md`
- `knowledge/workers/state-machine.md`
- `knowledge/workers/README.md`
- `knowledge/projects/README.md`

### Updated Workers
- `workers/dev-team/codex-coder/worker.yaml`
- `workers/dev-team/codex-debugger/worker.yaml` + `skills/debug-issue.md`
- `workers/dev-team/codex-reviewer/worker.yaml` + `skills/apply-best-practices.md` + `skills/improve-code.md`

### Breaking Changes
- (none this release)

---

## Migrating to v5.2.0 (from v5.1.0)

### What Changed
`/setup` now checks for GitHub CLI and Vercel CLI, and scaffolds knowledge as symlinked git repos instead of plain directories. README expanded with prerequisites and knowledge repo guide.

### Updated Files
Copy from starter kit:
- `.claude/commands/setup.md` — Rewritten with CLI checks (gh, vercel) and knowledge repo scaffolding
- `.claude/CLAUDE.md` — Knowledge Repos section expanded with step-by-step commands
- `README.md` — Prerequisites table, Knowledge Repos section, updated directory tree

### For Existing HQ Users
If your knowledge is already in plain directories (not symlinked repos), no action needed — everything still works. To adopt the repo pattern for an existing knowledge base:

1. Move: `mv knowledge/{name} repos/public/knowledge-{name}`
2. Init: `cd repos/public/knowledge-{name} && git init && git add . && git commit -m "init" && cd -`
3. Symlink: `ln -s ../../repos/public/knowledge-{name} knowledge/{name}`

### CLI Tools
If you don't have them yet:
- `brew install gh && gh auth login` (GitHub CLI — for PRs, repo management)
- `npm install -g vercel && vercel login` (Vercel — for deployments, optional)

### Migration Steps
1. Copy updated `setup.md`, `CLAUDE.md`, `README.md`
2. Optionally install `gh` and `vercel` CLIs
3. Optionally convert knowledge directories to symlinked repos (instructions above)
4. Run `/search-reindex`

### Breaking Changes
- (none — all changes are additive)

---

## Migrating to v5.1.0 (from v5.0.0)

### What Changed
Context Diet: lazy-loading rules reduce context burn at session start. Commands updated to write recent threads to a dedicated file instead of bloating INDEX.md.

### Updated Files
Copy from starter kit:
- `.claude/CLAUDE.md` — Merge the new "Context Diet" section (after Key Files) into yours
- `.claude/commands/checkpoint.md` — Step 7 now writes to `workspace/threads/recent.md`
- `.claude/commands/handoff.md` — Step 4 now writes to `workspace/threads/recent.md`
- `.claude/commands/reanchor.md` — New "When to Use" section

Updated knowledge:
- `knowledge/Ralph/11-team-training-guide.md`
- `knowledge/hq-core/index-md-spec.md`
- `knowledge/hq-core/thread-schema.md`
- `knowledge/workers/README.md`, `skill-schema.md`, `state-machine.md`, `templates/base-worker.yaml`
- `knowledge/projects/README.md`

### New File
Create `workspace/threads/recent.md` — this is where `/checkpoint` and `/handoff` now write the recent threads table.

### Optional: Slim INDEX.md
If your INDEX.md is large (200+ lines), consider trimming it to just the directory map and navigation table. Move workers, commands, companies tables out (they're already in CLAUDE.md). Move recent threads list to `workspace/threads/recent.md`.

### Migration Steps
1. Merge Context Diet section from starter kit's `.claude/CLAUDE.md` into yours
2. Copy updated `checkpoint.md`, `handoff.md`, `reanchor.md`
3. Create `workspace/threads/recent.md` (can be empty — next checkpoint/handoff populates it)
4. Copy updated knowledge files
5. Run `/search-reindex`

### Breaking Changes
- (none — all changes are additive)

---

## Migrating to v5.0.0 (from v4.0.0)

### What Changed
Major restructure: bundled workers removed (build your own), simplified setup, new `/personal-interview` command. Commands updated with Linear integration, enhanced search, and codebase exploration.

### New Command
Copy to `.claude/commands/`:
- `personal-interview.md` — Deep interview to populate profile + voice style

### New Worker Structure
- `workers/sample-worker/` — Example worker to copy and customize
- `workers/registry.yaml` — Now contains only the sample worker + commented template

### Removed (from starter kit)
These directories are deleted in v5.0.0. **If you use them, keep your existing copies**:
- `workers/dev-team/` (12 workers)
- `workers/content-brand/`, `content-sales/`, `content-product/`, `content-legal/`, `content-shared/`
- `workers/security-scanner/`
- `starter-projects/` (personal-assistant, social-media, code-worker)

### Updated Files
Copy from starter kit:
- `.claude/commands/setup.md` — Rewritten (simplified to 3 phases)
- `.claude/commands/execute-task.md` — Linear sync, qmd codebase exploration
- `.claude/commands/handoff.md` — Auto-commit HQ changes
- `.claude/commands/prd.md` — Target repo scanning
- `.claude/commands/run-project.md` — Linear sync
- `.claude/commands/search.md` — Company auto-detection
- `.claude/commands/search-reindex.md` — Multi-collection docs
- `.claude/commands/cleanup.md` — Genericized INDEX paths
- `.claude/commands/reanchor.md` — Genericized company paths
- `.claude/CLAUDE.md` — Merge carefully: new structure, 18 commands, sample-worker
- `workers/registry.yaml` — v5.0

Updated knowledge:
- `knowledge/Ralph/11-team-training-guide.md`
- `knowledge/hq-core/index-md-spec.md`
- `knowledge/projects/README.md`
- `knowledge/workers/README.md`, `skill-schema.md`

### Migration Steps
1. Copy `.claude/commands/personal-interview.md` (new)
2. Copy updated commands (setup, execute-task, handoff, prd, run-project, search, search-reindex, cleanup, reanchor)
3. Copy `workers/sample-worker/` directory (new example worker)
4. Merge `.claude/CLAUDE.md` — update structure tree, commands table, workers section
5. **If using bundled workers**: keep your existing `workers/dev-team/`, `workers/content-*/` directories — they still work
6. **If NOT using bundled workers**: delete old worker directories, copy new `workers/registry.yaml`
7. Copy updated knowledge files
8. Delete `starter-projects/` if present
9. Run `/search-reindex`

### Breaking Changes
- All bundled workers removed from starter kit. Existing copies in your HQ still work.
- `/setup` no longer offers starter project selection. Use `/prd` + `/newworker`.
- `workers/registry.yaml` format unchanged but contents stripped to sample-worker only.

---

## Migrating to v4.0.0 (from v3.3.0)

### What Changed
Major architecture upgrade: INDEX.md navigation system, knowledge repos (independent git repos), automated learning pipeline (`/learn`), and significant command updates.

### New Command
Copy to `.claude/commands/`:
- `learn.md` — Automated learning pipeline (captures learnings, injects rules into source files, deduplicates)

### New Knowledge Files
Copy to `knowledge/`:
- `Ralph/11-team-training-guide.md` — Team training guide
- `hq-core/checkpoint-schema.json` — Checkpoint data format
- `hq-core/index-md-spec.md` — INDEX.md specification

### Updated Files
All 13 existing public commands have been refreshed. Copy from starter kit:
- `.claude/commands/*.md` (all public commands)
- `.claude/CLAUDE.md` (major rewrite — merge carefully with your customizations)
- `workers/registry.yaml` (v4.0)

Updated workers:
- `workers/dev-team/code-reviewer/skills/review-pr.md`
- `workers/dev-team/frontend-dev/worker.yaml`
- `workers/dev-team/qa-tester/worker.yaml`
- `workers/dev-team/task-executor/skills/validate-completion.md`

Updated knowledge:
- `knowledge/hq-core/thread-schema.md`
- `knowledge/workers/README.md`
- `knowledge/workers/skill-schema.md`
- `knowledge/workers/state-machine.md`
- `knowledge/projects/README.md`

### Removed
- `knowledge/pure-ralph/` — Delete this directory. Pure Ralph patterns have been merged into the Ralph methodology core.

### New Features to Adopt

**INDEX.md System:** Create INDEX.md files at key directories. See `knowledge/hq-core/index-md-spec.md` for spec. Commands like `/checkpoint`, `/handoff`, `/prd` auto-update them.

**Knowledge Repos (Optional):** Knowledge folders can be independent git repos symlinked into HQ. See "Knowledge Repos" section in CLAUDE.md.

**Learning System:** `/learn` and `/remember` now inject rules directly into source files. Add a `## Learned Rules` section to your CLAUDE.md and `## Rules` sections to your commands.

### Migration Steps
1. Copy `.claude/commands/learn.md` (new command)
2. Copy all updated `.claude/commands/*.md`
3. Merge `.claude/CLAUDE.md` — add INDEX.md System, Knowledge Repos, Learning System, Auto-Learn, and Search rules sections
4. Copy `workers/registry.yaml`
5. Copy new knowledge files (`Ralph/11-team-training-guide.md`, `hq-core/checkpoint-schema.json`, `hq-core/index-md-spec.md`)
6. Copy updated knowledge and worker files
7. Delete `knowledge/pure-ralph/`
8. Run `/search-reindex`
9. Run `/cleanup --reindex` to generate INDEX.md files

### Breaking Changes
- `knowledge/pure-ralph/` removed — if you reference it, update to `knowledge/Ralph/`

---

## Migrating to v3.3.0 (from v3.2.0)

### What Changed
Commands split into public (16) and private (15). Only generic, reusable commands ship in the starter kit now. Content, design, and company-specific commands are private.

### New Feature: Auto-Handoff
Claude auto-runs `/handoff` at 70% context usage. This is in `.claude/CLAUDE.md` — copy the "Auto-Handoff (Context Limit)" section to yours.

### Removed Commands (now private)
If you use any of these, keep your existing copies — they just won't be in future starter kit releases:
- Content: `contentidea`, `suggestposts`, `scheduleposts`, `preview-post`, `post-now`, `humanize`
- Design: `generateimage`, `svg`, `style-american-industrial`, `design-iterate`
- System: `publish-kit`, `pure-ralph`, `hq-sync`

### Migration Steps
1. Copy `.claude/CLAUDE.md` from starter kit (or merge the Auto-Handoff section into yours)
2. Copy refreshed `.claude/commands/*.md` for the 16 public commands
3. Copy `workers/registry.yaml`
4. Run `/search-reindex`

### Breaking Changes
- (none — removed commands still work if you keep your local copies)

---

## Migrating to v3.2.0 (from v3.1.0)

### New Skills
Copy this file to `.claude/commands/`:
- `remember.md` — Capture learnings when things don't work right

### Updated Files
All 28 existing commands have been refreshed. Copy from starter kit to your HQ:
- `.claude/commands/*.md` (all public commands)
- `.claude/CLAUDE.md`
- `workers/registry.yaml`

### Breaking Changes
- (none)

### Migration Steps
1. Copy `.claude/commands/remember.md` to your HQ
2. Optionally update other commands by copying from starter kit
3. Run `/search-reindex` to include new command in search

---

## Migrating to v3.1.0 (from v3.0.0)

### Breaking Changes
- **`/newproject` removed** -- Merged into `/prd`. Delete `.claude/commands/newproject.md` from your HQ.
- **prd.json now required** -- `/run-project` and `/execute-task` require `projects/{name}/prd.json` with a `userStories` array. README.md is no longer accepted as a fallback.
- **`features` key deprecated** -- If your prd.json files use `"features"` instead of `"userStories"`, rename the key. Also rename `"acceptance_criteria"` to `"acceptanceCriteria"` (camelCase).

### Updated Skills
Replace these files in `.claude/commands/`:
- `prd.md` -- **Major rewrite.** Now outputs both `prd.json` (source of truth) and `README.md` (derived). Includes orchestrator registration, beads sync, and execution choice.
- `run-project.md` -- Strict prd.json validation on load. Hard stop if missing.
- `execute-task.md` -- Same strict validation.
- `newworker.md` -- `/newproject` references updated to `/prd`
- `nexttask.md` -- `/newproject` reference updated to `/prd`

### Migration Steps
1. Delete `.claude/commands/newproject.md`
2. Copy updated `prd.md`, `run-project.md`, `execute-task.md`, `newworker.md`, `nexttask.md`
3. If you have prd.json files using `"features"`, rename to `"userStories"` and `"acceptance_criteria"` to `"acceptanceCriteria"`
4. If you have projects with only README.md (no prd.json), run `/prd {project}` to generate the JSON

---

## Migrating to v3.0.0 (from v2.1.0)

### New Skills
Copy these files to your `.claude/commands/`:
- `humanize.md` - Remove AI writing patterns from drafts
- `pure-ralph.md` - External terminal orchestrator for autonomous PRD execution
- `svg.md` - Generate minimalist abstract white line SVG graphics
- `search-reindex.md` - Reindex and re-embed HQ for qmd search

### Updated Skills
The following skills have significant updates. Review and merge:
- `search.md` - **Breaking:** Complete rewrite to qmd-powered search (BM25, semantic, hybrid). Includes grep fallback if qmd is not installed.
- `handoff.md` - Added step 4: search index update (`qmd update && qmd embed`)
- `run-project.md` - Updated orchestration pattern with inline worker pipeline execution
- `execute-task.md` - Worker names aligned with dev-team IDs (`backend-dev`, `frontend-dev`, `dev-qa-tester`, etc.); added `content` task type

### New Knowledge
Copy these directories to your `knowledge/`:
- `pure-ralph/` - Branch workflow, learnings
- `hq/` - Checkpoint schema
- `projects/` - Project creation guidelines and templates
- `design-styles/ethereal-abstract.md` - Ethereal abstract style guide
- `design-styles/liminal-portal.md` - Liminal portal style guide

### Install qmd (Optional)
[qmd](https://github.com/tobi/qmd) powers the new `/search` command with semantic + full-text search.

```bash
# Install qmd (requires Go)
go install github.com/tobi/qmd@latest

# Index your HQ
cd ~/HQ
qmd update && qmd embed
```

If qmd is not installed, `/search` falls back to grep-based search.

### Breaking Changes
- `/search` syntax changed from grep-based to qmd queries. Install qmd or use the built-in fallback.

---

## Migrating to v2.1.0 (from v2.0.0)

### New Skills
Copy these files to your `.claude/commands/`:
- `generateimage.md` - Generate images via Gemini Nano Banana
- `post-now.md` - Post to X/LinkedIn immediately
- `preview-post.md` - Preview drafts, select images, approve posting
- `publish-kit.md` - Sync your HQ to hq-starter-kit

### Updated Skills
The following skills have significant updates. Review and merge:
- `contentidea.md` - Enhanced multi-platform workflow with:
  - Image generation per approved style (7 styles)
  - Visual prompt patterns organized by theme
  - Anti-AI slop rules (humanizer section)
  - Preview site sync workflow
- `scheduleposts.md` - Improved queue management
- `style-american-industrial.md` - Expanded monochrome variant with CSS variables
- `metrics.md`, `run.md`, `search.md`, `suggestposts.md` - Generalized examples

### New Directories (if using image generation)
```
workspace/social-drafts/images/   # Generated images for posts
repos/private/social-drafts/      # Preview site (optional)
```

### Breaking Changes
None in this release.

---

## Migrating to v2.0.0 (from v1.x)

### Major Changes
v2.0.0 is a significant upgrade with new project orchestration and 18 workers.

### New Directories
Create these if missing:
```
workspace/
  threads/          # Auto-saved sessions
  orchestrator/     # Project state
  learnings/        # Captured insights
  content-ideas/    # Idea inbox
social-content/
  drafts/
    x/              # X/Twitter drafts
    linkedin/       # LinkedIn drafts
```

### New Skills
Copy all files from `.claude/commands/`.

### New Workers
Copy `workers/dev-team/` and `workers/content-*/` directories.

### Knowledge Bases
Copy new knowledge directories:
- `knowledge/hq-core/`
- `knowledge/ai-security-framework/`
- `knowledge/design-styles/`
- `knowledge/dev-team/`

### Registry Update
Replace `workers/registry.yaml` with the new v2.0 format.

### Breaking Changes
- Registry format changed (version: "2.0")
- Thread format changed (see `knowledge/hq-core/thread-schema.md`)
- `/ralph-loop` renamed to `/run-project`

---

## General Update Process

1. **Backup your HQ** before updating
2. **Diff files** before overwriting - preserve your customizations
3. **Merge knowledge** - don't overwrite, combine with your additions
4. **Test skills** after copying to ensure they work with your setup
