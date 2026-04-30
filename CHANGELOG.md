## [12.2.0] — 2026-04-30

### Headline
**Codex parity** — HQ becomes a first-class environment for both Claude Code and OpenAI Codex. Adds `AGENTS.md`, the `.codex/` entrypoint tree, an `.agents/skills` exposure for Codex skill discovery, the `/convert-codex` repair command, and `agents/openai.yaml` metadata for every shipped skill — bringing Codex skill metadata coverage to 48/48 and command-skill coverage to 39/39.

Fully additive. No Claude Code behavior changes. Existing operators on v12.1.x can stay on Claude Code without doing anything; users wanting to invoke HQ from Codex run `/convert-codex --apply` once and gain the new entrypoints.

### Added — Commands
- **`/convert-codex`** — Additive conversion for older Claude-first HQ roots. Dry-run by default. Adds missing `AGENTS.md`, `.codex/config.toml`, `.codex/claude` and `.codex/prompts` bridges, `.agents/skills` exposure, and missing `agents/openai.yaml` metadata. Never overwrites existing files; refuses to replace a real `.agents/skills` directory with a symlink.

### Added — Codex Entrypoints
- **`AGENTS.md`** at HQ root — 20-line orientation doc that points Codex at `.claude/`, `.agents/skills`, and `.codex/`. Mirrors the role `CLAUDE.md` plays for Claude Code.
- **`.codex/config.toml`** — Codex sandbox + model settings (`workspace-write`, `network_access = true` for HQ workflows that need outbound calls).
- **`.codex/claude`** → symlink to `.claude/` (Codex sees the same instructions Claude does).
- **`.codex/prompts`** → symlink to `.claude/commands/` (Codex prompt library mirrors Claude commands).
- **`.agents/skills`** → symlink to `.claude/skills/` (Codex skill discovery without duplication).

### Added — Codex-Adapter Skills (18 new SKILL.md files + 30 new openai.yaml files)
- New SKILL.md adapters: `checkpoint`, `cleanup`, `convert-codex`, `garden`, `goals`, `harness-audit`, `hq-sync`, `idea`, `newcompany`, `newworker`, `personal-interview`, `quality-gate`, `recover-session`, `resolve-conflicts`, `run-pipeline`, `setup`, `strategize`, `sync-registry`, `tdd`, `update-hq`.
- Each adapter delegates to its source `.claude/commands/{name}.md` for the canonical workflow — single source of truth, no duplicate maintenance.
- Adds `agents/openai.yaml` metadata (`display_name` + `short_description`) for skill discovery: now 48/48 covered.
- Bumps Codex command coverage to 39/39 commands with paired adapters.

### Added — Tooling
- **`scripts/convert-codex.sh`** (446 lines) — set-euo-pipefail, dry-run-first, create-only repair script. Validates symlink targets before touching them, refuses to overwrite, and prints a compact parity audit on exit.
- **`scripts/codex-preflight.sh`** (216 lines) — explicit Codex-side preflight checks for `search`, `bash`, and `edit` operations. Routes through hardcoded hook filenames; pipes sanitized JSON via `jq --arg` (no injection vectors).
- **`docs/codex-hook-porting.md`** — 70-line decision record mapping each of HQ's 20 Claude hooks to a Codex strategy.

### Changed — Policies
Path renames in 4 policy files to reflect the staging-to-public model — `repos/public/hq/template/` is no longer the contributor target, `repos/private/hq-core-staging/` is. Enforcement levels unchanged.

- `hq-cmd-stage-kit-settings-json-direct-edit.md`
- `hq-nested-repo-git-status-check.md`
- `hq-settings-local-for-personal-allows.md`
- `run-project-conflict-marker-guard.md` (propagation list updated)
- `_digest.md` regenerated.

### Provenance
Codex-authored PR (#30) — reviewed and merged 2026-04-30. Full review notes in PR body. No companion package releases required; `hq-cli` and `hq-cloud` are unaffected.

---

## [12.1.1] — 2026-04-29

### Headline
**Hotfix on top of v12.1.0** — finishes the dev→prod Cognito cutover by flipping the last user-visible dev-pool reference and codifies the no-bandaid principle that drove the cleanup.

### Fixed
- **`/designate-team`** — the env-echo block (`HQ environment for designation:`) printed `Cognito domain: hq-vault-dev` whenever the operator hadn't set `HQ_COGNITO_DOMAIN`. Misleading post-2026-04-25 cutover, since the running CLI defaults to `vault-indigo-hq-prod`. Now the displayed default mirrors the canonical pool, so operators can sanity-check at a glance.

### Added — Policies
- **`prefer-systemic-fix-over-user-bandaid`** (hard, global) — codifies the rule that bug fixes ship as systemic patches (default change + version bump + release), not as per-operator env exports. Banned framings: "Layer A: unblock <user> today", "tell <user> to set HQ_FOO=…", "quick fix vs proper fix". Compounds with `hq-fix-root-cause-not-symptoms`. Source: 2026-04-29 user correction during the create-hq cognito cutover.

### Provenance
Single-issue hotfix. Companion releases:
- `@indigoai-us/hq-cloud@5.9.0` — adds `decodeAccessTokenClientId` + stale-pool self-evict in `getValidAccessToken` so cached pre-cutover dev tokens stop wedging users.
- `@indigoai-us/hq-cli@5.7.1` — picks up hq-cloud@5.9.0 via `^5.x`.
- `create-hq@10.12.0` — `DEFAULT_COGNITO` flipped to `vault-indigo-hq-prod` / `7acei2c8v870enheptb1j5foln`.

---

## [12.1.0] — 2026-04-28

### Headline
**Iteration release on top of v12.0.0's hq-core split.** Adds the auth/identity command set (`/hq-login`, `/hq-logout`, `/hq-whoami`), the `/hq-sync` CLI-driven full-sync command, an interactive `/resolve-conflicts` flow for HQ Sync conflicts, a heavy-duty `/deep-plan` separated from the now-lightweight `/plan`, the `/import-claude` migration command for hydrating an existing machine into HQ, and the `hq-secrets` skill that codifies the secret-injection playbook (`hq secrets exec --only … -- <command>`). `/designate-team` is now shipped publicly and gains an end-to-end self-check via `/membership/me`. Background: trimming session cold-start to ~36KB (was ~93KB) and a policy-rationale leak-scan word-boundary fix.

### Added — Commands
- **`/hq-login`, `/hq-logout`, `/hq-whoami`** — Cognito identity flow (status → refresh → browser fallback).
- **`/hq-sync`** — Full HQ sync from CLI (same engine as the AppBar HQ Sync button).
- **`/resolve-conflicts`** — Interactive walk-through of HQ Sync conflicts (keep local | take cloud | discard).
- **`/import-claude`** — Scan the machine for Claude artifacts (sessions, MCPs, commands, skills, hooks, policies, knowledge, repos, plans) and guide a selective import into HQ.
- **`/deep-plan`** — Heavy planning split from `/plan`: research subagents (codebase / HQ / repo) + a 3-tier 15-question interview (Strategic / Architecture / Quality), with smart-skip and pushback. Use for large or strategically important PRDs; `/plan` remains lightweight for everyday work.
- **`/designate-team`** — Mark an HQ company directory as cloud-backed and run company sync. Now public; delegates to `hq cloud provision company` under the hood.

### Added — Skills
- **`hq-secrets`** — Playbook for the `hq secrets` CLI: inject via `exec --only … -- <cmd>` so values become env vars in the child process and never reach stdout; `get` redacts by default; `--reveal` is the only escape hatch; never wrap `exec` in `$(…)`. New `## Secrets` section in `.claude/CLAUDE.md` summarises the core rules.

### Changed
- **`/plan`** — Reverted to lightweight scope. Heavy interview + research moved to new `/deep-plan`. Existing call sites unchanged; choose the depth that fits.
- **`/designate-team`** — Now delegates to `hq cloud provision company`. Adds an env echo (vault URL, Cognito pool domain, `hq whoami`) before provisioning and a post-provision `/membership/me` self-check (audit JSONL gains a `membership_visible` field; new exit code `4` = entity created but operator can't see it — usually a userpool/token mismatch).
- **Session cold-start trim** — Default cold-start size dropped from ~93KB to ~36KB by trimming session-context defaults (still expandable on demand).
- **Public-policy gate** — Backfilled `public: true` on all 64 existing policies that should ship with hq-core; replayed the post-hardening promotion sweep.

### Fixed
- **`/hq-sync`** — Portable bash + arg parsing (was bash-4.x-only); renamed `status` → `cli_status` to avoid zsh's reserved-word collision.
- **leak-scan** — Word-boundary regex on policy-rationale scan (was matching substrings inside larger tokens).

### Provenance
14 PRs merged onto `indigoai-us/hq-core-staging` since the v12.0.0 seed (`b616522`). Promoted to public `indigoai-us/hq-core` from staging `main`. Internal staging-repo CI (`.github/workflows/leak-scan.yml`, `.leak-scan/`) is intentionally not promoted.

---

## [12.0.0] — 2026-04-21

### Headline
**hq-core split.** `hq-core` is now a standalone repository (`indigoai-us/hq-core`) carrying the minimal scaffold seed — the lean monorepo template that `npx create-hq` clones to bootstrap a new personal OS. Rich add-ons (design style packs, design quality references, Gemini CLI workers, gstack-team) are extracted into four `@indigoai-us/hq-pack-*` npm packages (published separately) and install into `packages/` via `hq install`. Batteries-included UX preserved: a default `create-hq` run prompts to install everything in `core.yaml:recommended_packages`.

### Added
- `packages/` directory + `packages/README.md` — documents the pack convention, install flow, schema pointer, and the four recommended packs.
- `core.yaml:recommended_packages` — declarative list consumed by `create-hq`, `setup.sh`, and `update-hq.md`. Supports a `conditional` bash predicate per entry (gemini pack skips when `gemini` is not on `PATH`).
- `.gitignore` additions: `.vercel/`, `.next/`, `packages/*/node_modules/`.

### Removed (extracted to packages)
- `knowledge/public/design-styles/` → `@indigoai-us/hq-pack-design-styles`
- `knowledge/public/design-quality/` → `@indigoai-us/hq-pack-design-quality`
- `knowledge/public/gemini-cli/` → `@indigoai-us/hq-pack-gemini`
- `workers/public/gemini-{coder,designer,frontend,reviewer,stylist,ux-auditor}/` → `@indigoai-us/hq-pack-gemini`
- `workers/public/gstack-team/` → `@indigoai-us/hq-pack-gstack` (plus `scripts/gstack-bridge.sh` which ships with the gstack pack, not the seed)

### Removed (deprecated)
- `workers/public/impeccable-designer/` — superseded by `dev-team/frontend-dev` + `design-styles` pack (2026-04-15).
- `workers/public/sample-worker/` — template-only, not useful at runtime.
- `knowledge/public/impeccable/` — empty stub.

### Changed
- `hqVersion: "12.0.0"` (was `11.2.0`).
- `workers/registry.yaml` — trimmed entries for removed/extracted workers.
- `modules/modules.yaml` — trimmed entries for extracted knowledge bases.
- `workers/public/INDEX.md` / `knowledge/public/INDEX.md` — rebuilt to reflect the trimmed set.

### Provenance
Shallow snapshot from `indigoai-us/hq@main` → `template/` at commit `f3022a887` (2026-04-21). Not a filter-repo split — no pre-v12 git history is carried. See `MIGRATION.md` for upgrade steps.

---

## [11.2.0] — 2026-04-18

### Headline
publish-kit scope discipline — the release walker is now a **strict allowlist** that never traverses owner-private directories, and the publish target `template/` is **rebuilt from scratch** on every full release. Root-cause fix for the class of leaks that put owner content (company folders, project PRDs, workspace threads, `.obsidian/` vault state, owner-local settings) into prior publishes. PII-at-source scanning for publish-kit becomes structurally unnecessary: paths outside the allowlist cannot be reached by the walker, and anything no longer emitted is deleted naturally by the Stage R rebuild.

### Added — Policy
- **`.claude/policies/publish-kit-source-is-strict-allowlist.md`** (`scope: command`, `enforcement: hard`, `public: true`) — hard allowlist, starter-scaffold carve-outs, never-traverse denylist.

### Changed — Commands
- **`.claude/commands/publish-kit.md`** — Step 0.5 Source Allowlist Assertion (ALLOW_ROOTS / REMAPS / STARTER_SCAFFOLDS / NEVER_TRAVERSE); Step 4 renamed "Rebuild Target + Copy Files" with Stage R (`rm -rf template/`) + Stage E (emit); What-to-Sync table expanded with starter-scaffold rows and never-sync patterns.

### Added — Content (this release)
- **New commands (1):** `tutorial.md` — interactive HQ tutorial skill.
- **New policies (13):** `publish-kit-source-is-strict-allowlist`, `hq-cmd-publish-kit-python-yaml-free`, `hq-cmd-publish-kit-rerun-diff-on-scope-narrow`, `hq-cmd-stage-kit-settings-json-direct-edit`, `hq-publish-target-is-hq-template`, `hq-nested-repo-git-status-check`, `hq-permissions-fan-out-edit-write-multiedit`, `hq-settings-local-for-personal-allows`, `hq-figma-token-account-scope`, `preview-start-launch-registry-is-global`, `distributed-join-partial-failure-diagnosis`, `git-stash-build-artifacts-conflict`, `npm-subpackage-hydration`.
- **New skills (2 dirs):** `tutorial/` (full skill), plus `knowledge-pulse/agents/openai.yaml` + `tutorial/agents/openai.yaml` (Codex dual-format).
- **New worker scaffolds (44 files):** `dev-team/context-manager/` (audit/discover/learn/update skills), `dev-team/motion-designer/` (add-animation/add-transition/generateimage skills), `dev-team/reality-checker/` (cross-validate/final-gate), `dev-team/backend-dev/skills/e2e-testing.md`, `dev-team/frontend-dev/skills/{audit,polish,typeset,harden}/command.md` + `e2e-testing.md`, `dev-team/qa-tester/skills/electron-e2e.md`, `dev-team/gemini-coder/skills/{implement-feature,scaffold-component}.md`, `dev-team/gemini-reviewer/skills/{apply-best-practices,improve-code,review-code}.md`, `workers/public/INDEX.md`, `gemini-frontend/skills/{design-to-code,refactor-component}.md`, `pretty-mermaid/{assets,references,scripts,package.json}`, `social-publisher/skills/post.md`, `social-verifier/skills/post-results.md`, worker.yaml updates for `ascii-artist`, `frontend-designer`, `gstack-team`.
- **New knowledge (29 files):** Three new design-styles packs — `hq-cinematic/` (cinematic navy-void motion pack), `goclaw-admin/` (admin console reference), `moonflow-editorial-v2/` (warm editorial brand). Plus `getting-started/tutorials/INDEX.md` and `impeccable/README.md`.

### Changed — Content (this release)
- **Commands modified (14):** `.claude/CLAUDE.md`, `brainstorm`, `cleanup`, `garden`, `harness-audit`, `idea`, `newworker`, `personal-interview`, `plan`, `run-project`, `run`, `setup`, `strategize`, `update-hq`.
- **Hooks modified (2):** `inject-local-context.sh`, `load-policies-for-session.sh`.
- **Policies modified (46):** context-stripped + denylist re-scrubbed under the new allowlist discipline. Includes `blog-post-x-draft`, `company-archive-cleanup`, `deconflict-postbridge-schedule`, `feature-flag-first`, `git-add-explicit-paths-no-drift`, `git-workflow`, `publish-kit-indigo-sed-ordering`, `publish-kit-denylist-*`, `hq-cmd-*`, and others.
- **Skills modified (3):** `plan/` (renamed from `prd/` — `/prd` → `/plan` throughout), publish-kit related skill files normalized.
- **Infra modified (1):** `.claude/CLAUDE.md` re-scrubbed + reformatted.

### Removed — Content (this release)
- **Skills removed (2):** `prd/` (renamed to `plan/`), `deploy/` (demoted to worker scope), `agent-browser/` (moved to `workers/public/qa-tester/skills/agent-browser/`).
- **Commands removed (20):** Private/company-scoped commands that should never have shipped — `approve-submission`, `assign-pack`, `audit-log`, `audit`, `dashboard`, `list-shared`, `list-submissions`, `model-route`, `prd` (renamed), `reanchor`, `remember` (now `/learn --hard`), `review-plan`, `review-submission`, `review`, `search-reindex`, `search`, `share`, `submit`, `sync-team`, `understand-project`. Most were owner/team workflow commands surfaced from earlier permissive walks.
- **Hooks removed (2):** `auto-handoff-trigger.sh`, `context-meter.sh` (neither is part of the public hook set).
- **Policies removed (123):** Policies that fail the new opt-in gate — either `public: false`, `scope: global` without `public: true`, or otherwise owner-workflow-specific (incident-narrative, company-name prefixes). Notable removals include pricing/vendor-verify rules, company-context verification, debugging session policies, editor/IDE policies, repo-specific rules, and SOC-specific guardrails.
- **Workers removed (394 files, from prior over-publish):** Large portions of `dev-team/` internal skills, `frontend-designer/` design-system refs, `impeccable-designer/` (deprecated worker), `content-shared/` team workflows, `ux-auditor/`, `gemini-ux-auditor/` — all filtered back out by the allowlist + per-worker `worker.yaml` public surface.
- **Knowledge removed (304 files):** `curious-minds/` book drafts (110 files — owner-only reading list), `design-styles/` internal pack variants (92), `hq-core/` owner runbooks (30), `Ralph/` team-training internals (12), `loom/` internal ops notes (9), etc. The public-eligible subset of each knowledge repo survives.
- **Other (8 files):** Owner-local `settings/` overrides, private `tools/` utilities, owner `data/` scaffolds, private `contacts/` sample data — all now blocked at the walker level.

### Migrating to v11.2.0
Non-breaking for HQ consumers. Downstream publish-kit authors should re-read the new allowlist policy — the walker now refuses to emit outside the allowlist, which may surface previously-silent bad paths. See `MIGRATION.md` for details.

---

# Changelog

## [11.1.1] — 2026-04-16

### Headline
Orchestrator + core-command patch. `/run-project` inline mode hardened around context preservation — each story now executes in a single per-story `Task` sub-agent with a strict JSON return contract, keeping raw worker output out of the parent session (gains ~300-500 tokens/story vs. several thousand under the old per-worker-inline model). `run-project.sh` hardened with worktree auto-create, builder phase-state heartbeats, cross-PRD deps, monitor-window keystroke-race fix, and a `validate_git_state()` conflict-marker guard that refuses to auto-commit unresolved merge artifacts. `/prd` renamed to `/plan` (compat alias keeps `/prd` working as a deprecation stub). Default model pinned to `claude-opus-4-7` (Opus 4.7 standard 200K — not the 1M variant).

### Changed
- `/run-project` (`.claude/commands/run-project.md`) — inline mode switched to a **per-story Task sub-agent** isolation model. Added `Task` to `allowed-tools`. The parent session performs only lightweight orchestration (announce, branch setup, Linear sync) and delegates the full worker pipeline to a fresh `general-purpose` Task sub-agent per story; the sub-agent runs `/execute-task` internally (which spawns the usual nested per-worker sub-agents) and returns a compact JSON summary. Regression gates now run in a one-shot Task sub-agent so raw test output never enters the parent context. Documentation references updated from `/prd` to `/plan`.
- Default model pinned to `claude-opus-4-7` in `.claude/settings.json` (top-level `"model"` key). `CLAUDE_CODE_SUBAGENT_MODEL=opus` alias unchanged.

### Fixed — Orchestrator (`scripts/run-project.sh` + `.claude/scripts/run-project.sh`)
- Auto-create worktree directory and `cd` into it before invoking the builder (previously failed when target dir didn't exist or session started outside it).
- Codex builder phase-state heartbeats — surface progress to the monitor instead of silent multi-minute gaps.
- Cross-PRD dependency resolution + worktree anchoring — sibling PRDs in the same repo now share a single worktree instead of fighting for the lockfile.
- Audit vocabulary normalized across log lines.
- **Conflict-marker guard in `validate_git_state()`** — refuses auto-commit when staged files contain unresolved merge markers (`^(<{7}|={7}|>{7})([^<=>]|$)`), resets the index, and pauses the run for manual cleanup. Prevents the failure mode where a sub-agent's surgical edit triggers a `git add -A` sweep that ingests pre-existing conflict garbage into the branch.

### Added
- **`/plan`** (`.claude/commands/plan.md`) — renamed from `/prd`. Both invocations work in 11.1.1; `/prd` is now a thin redirect stub.
- **3 orchestrator policies** (all `scope: command`, `enforcement: hard`):
  - `run-project-conflict-marker-guard.md` — codifies the guard above
  - `run-project-monitor-spawn-keystroke-race.md` — monitor window must spawn via `.command` file (not AppleScript `do script`) to dodge keystroke races
  - `run-project-worktree-heal-orphan.md` — `ensure_worktree` must heal orphan target directories (regenerable artifacts only) before `git worktree add`
- **3 cross-cutting policies** (`scope: global`/`command`, `public: true`):
  - `hq-cmd-handoff-must-complete.md` — `/handoff` must complete its full sequence (commit → write thread → update INDEX) before returning
  - `git-add-explicit-paths-no-drift.md` — never `git add -A`/`.` for orchestrated work; stage explicit paths
  - `reskin-separate-orchestration-from-visual.md` — reskin work must split orchestration changes from pure visual changes
- **Auto-deploy skill + directive** (merged from `main` via PR #76) — `skills/deploy/`, `policies/auto-deploy-on-create.md`, and `CLAUDE.md` Auto-Deploy section. When a web-servable artifact is created, it is deployed to `hq-deploy` and the link is presented — non-blocking, skipped for Vercel-managed projects, backend services, broken builds, or projects with `deploy: false` in prd.json.

### Migrating to v11.1.1
The `/prd → /plan` rename is **backward-compatible**. The shipped `/prd` is now a redirect stub that prints a deprecation notice and points consumers at `/plan`. Update any scripts, docs, or muscle memory that invoke `/prd` to use `/plan` instead. The stub will be removed in a future minor release.

The default model bump pins both Claude Code's main loop and `CLAUDE_CODE_SUBAGENT_MODEL` alias resolution to `claude-opus-4-7` (the standard 200K-context Opus 4.7 — explicitly NOT the 1M-context variant). If your project requires the 1M-context model, override at the project level via `.claude/settings.json`.

## [11.1.0] — 2026-04-16

### Headline
qmd sub-collection refactor — the monolithic `hq` collection is split into 4 focused collections (`hq-infra`, `hq-workers`, `hq-knowledge`, `hq-projects`), cutting indexed files from ~16K to ~1K per collection. Also: `design.md` replaces `.impeccable.md` as the per-repo design context file, 54 policies refreshed, 23 commands updated, `knowledge-pulse` skill added, and design-styles/design-quality knowledge bases synced.

### Added — Knowledge
- **`knowledge/design-styles/`** — full style pack system with 9 packs, foundations references, `_template/` scaffold, and `registry.yaml`. 52 new files including `PACK-SCHEMA.md`.
- **`knowledge/design-quality/`** — design quality references (typography, color, spatial, etc.)
- **`knowledge/hq-core/design-md-spec.md`** — spec for the new `design.md` repo context file
- **`knowledge/hq-core/insights-spec.md`** — spec for the `workspace/insights/` educational insights system
- **`knowledge/Ralph/11-team-training-guide.md`** — training guide for the Ralph orchestration pattern

### Added — Skills
- **`knowledge-pulse`** — lightweight background gardening pass for a company's knowledge base and policies

### Added — Policies (3 new)
- `run-project-swarm-branch-validation.md` — branch validation for swarm mode
- `run-project-swarm-merge-conflict-tombstone.md` — merge conflict tombstone handling
- `vercel-domain-transfer-reissues-verification.md` — domain transfer verification checks

### Removed — Policies (7)
- `hq-paper-mcp-sequential-agents.md` — company-specific (Paper MCP)
- `hq-slack-channel-indigo-workspace.md` — company-specific (Indigo workspace)
- `indigo-hq-app-release.md` — company-specific (Indigo releases)
- `indigo-signals-mcp-queries.md` — company-specific (Indigo Signals)
- `paper-flex-column-reorder.md` — product-specific (Paper)
- `paper-text-width.md` — product-specific (Paper)
- `paper-text-wrapping.md` — product-specific (Paper)

### Changed
- **qmd collections** — `setup.sh` now creates 4 sub-collections (`hq-infra`, `hq-workers`, `hq-knowledge`, `hq-projects`) instead of one monolithic `hq` collection. Dramatically reduces noise in semantic search.
- **`design.md` replaces `.impeccable.md`** — per-repo design context file renamed. Workers resolve style packs via `knowledge/design-styles/registry.yaml`.
- **54 policies refreshed** — context-stripped, narrative-cleaned, and re-digested
- **23 commands updated** — synced from upstream with latest improvements
- **9 skills updated** — brainstorm, execute-task, handoff, investigate, land, learn, prd, run, startwork
- **8 hooks refreshed** — all `.sh` files synced from upstream
- **CLAUDE.md** — updated with qmd sub-collection docs, `design.md` references, new workers section, insights system
- **USER-GUIDE.md** — refreshed with current command catalog and workflow examples
- **`modules/modules.yaml`** — updated collection references
- **`workers/registry.yaml`** — refreshed worker descriptions
- **Policy digest** — regenerated with current 187 policies

### Migration
See migration steps below in `MIGRATION.md` — non-breaking, but `setup.sh` should be re-run to create the new qmd sub-collections.

## [11.0.0] — 2026-04-15

### Headline
**BREAKING:** Orchestrator externalized. `/run-project` is now a thin router around `scripts/run-project.sh`. Kits pulling this release must ensure the script exists and is executable — inline-run kits will stop working until the script is present. Also: cross-session repo-level active-run coordination, PII-free SessionStart context injection via `inject-local-context.sh`, two-stage context advisories (60% Stop + 75% PreCompact), hook profile system via `HQ_HOOK_PROFILE`, and a desktop bridge health check for the 260 GB leak class.

### Breaking
- **`/run-project` is a router.** The Ralph loop now lives in `scripts/run-project.sh` (worktree auto-create, per-story heartbeats, cmux monitor, stale PID detection). See `MIGRATION-v11.md` for the exact upgrade steps.
- **Repo-level active-run coordination.** A second session attempting to Edit/Write/destructive-Bash against a repo that another session's `/run-project` currently owns will be blocked with exit code 2. Emergency bypass: `HQ_IGNORE_ACTIVE_RUNS=1` (audited to `workspace/learnings/active-run-bypasses.jsonl`). Read/Grep/Glob/`git status` always allowed. Composes above the existing story-level `.file-locks.json` without regression.

### Added — Scripts
- **`scripts/run-project.sh`** — externalized Ralph loop. Worktree auto-create, per-story heartbeats, cmux monitor, stale PID detection.
- **`scripts/repo-run-registry.sh`** — cross-session repo lock registry at `workspace/orchestrator/active-runs.json`.
- **`.claude/scripts/monitor-project.sh`** — 552-line TUI refresh with 24-bit color palette, Unicode glyphs, ANSI Shadow banner. Walk-up root resolution is portable across kits.

### Added — Commands
- **`/land`** — PR → CI → review → merge → prod-monitor pipeline. Promoted from skill-only in v10.10.0.

### Added — Hooks
- **`check-claude-desktop-bridge-health.sh`** (SessionStart) — dual-signal detector for the 260 GB desktop-bridge memory leak pattern (bridge-state.json zombie entry + main.log leak signature). Advisory-only, always exits 0.
- **`rewrite-resume-sentinel.sh`** (UserPromptSubmit) — fixes the "No response requested" failure mode that can occur when resuming compacted sessions.
- **Settings**: new `UserPromptSubmit` event block wired to `rewrite-resume-sentinel.sh`; `check-claude-desktop-bridge-health.sh` added to `SessionStart`.

### Added — Policies
- `credential-access-protocol.md` — frontmatter audit trail (`learned_from` + `source`).
- `claude-desktop-bridge-state-zombie.md` — full policy for the 260 GB leak class. Pairs with the new `check-claude-desktop-bridge-health.sh` hook.

### Changed
- **`context-warning-60.sh`** moved from `SessionStart` → `Stop` in `settings.json`. The advisory fires after assistant turns when transcript crosses ~60% of the window — it's a Stop-event signal, not a session-start signal. Previously latent bug: it never fired on Stop.
- **`load-policies-for-session.sh`** — `HQ_ROOT` fallback now uses `${CLAUDE_PROJECT_DIR:-$HOME/HQ}` instead of a hardcoded tilde path. Works correctly in any Claude Code kit, not just the author's machine.
- **`inject-local-context.sh`** — 4-line filter that strips `{company}`/`{product}` placeholder noise from the worker count so a fresh kit with template-only companies displays a clean SessionStart banner.
- **`hook-gate.sh`** — 2-line add: `rewrite-resume-sentinel` recognized in `standard` + `strict` profiles.
- **`run-pipeline.sh`** — product-specific PR-creation branch stripped. All repos now use the standard `gh pr create` path.
- **15 commands refreshed**: `brainstorm`, `document-release`, `execute-task`, `harness-audit`, `land`, `learn`, `personal-interview`, `prd`, `quality-gate`, `retro`, `review`, `setup`, `strategize`, `tdd`, `update-hq`.
- **`prd/SKILL.md`** — **PRD v2 deep interview.** Three-phase upgrade: Phase 1 adds research subagents (codebase scan, HQ context scan, repo deep-read → `research/` directory). Phase 2 replaces 7-batch shorthand with one-at-a-time sequential questioning via `AskUserQuestion` (15-question bank across Strategic/Architecture/Quality tiers, pushback on vague answers, anti-sycophancy, smart-skip from research). Phase 3 adds adversarial spec review subagent (5 dimensions, max 3 fix-review iterations). Also includes Step 8.5 "Resolve Open Questions (Decision Mode)."
- **`prd-minimum-questions.md`** (new policy) — hard enforcement: minimum 10 questions spanning ≥2 tiers before PRD generation.
- **`learn/SKILL.md`** — `/remember` → `/learn --hard` refresh, new `public:` policy frontmatter, workflow self-check step.

### Migration
See `MIGRATION-v11.md` at the template root for the step-by-step upgrade (pull scripts, `chmod +x`, install required hooks, verify `run-project.sh --help`).

## [10.10.0] — 2026-04-13

### Headline
Command/skill cleanup: 38 → 30 commands, 18 → 16 skills. Pack frontmatter tags for organizational grouping. `/remember` merged into `/learn --hard`. `/land` promoted to core command.

### Removed — Commands (7)
- `dashboard` — Goals command is sufficient
- `model-route` — Moot with Opus 4.6 universal default
- `recover-session` — Handoff is reliable enough
- `remember` — Merged into `/learn --hard`
- `search` — Agents call qmd directly
- `search-reindex` — Triggered by hooks/scripts, not user-facing
- `understand-project` — Redundant with brainstorm

### Removed — Skills (2)
- `search` — Agents use qmd directly
- `agent-browser` — Relocated to qa-tester worker

### Added
- **`/land` command** — promoted from skill-only; lands PRs through CI → review → merge → production pipeline
- **Pack frontmatter tags** — `pack: dev` on quality-gate, review, retro, document-release, tdd; `pack: maintenance` on harness-audit
- **`ascii-artist` worker** — dedicated worker for ASCII block-art banner generation
- **14 new policies** synced from upstream

### Changed
- **`/learn`** absorbs `/remember` — use `--hard` or `--enforce` flag for hard-enforcement rules
- **10 skills updated** — ascii-graphic, brainstorm, execute-task, handoff, land, learn, prd, run, run-project, startwork
- **183 policies synced** (up from 162) — scope-filtered, context-stripped
- **CLAUDE.md** — updated command count (30), removed stale `/remember` references
- **Registry** — added ascii-artist worker entry

### Migration
- Replace `/remember` with `/learn --hard` in any custom scripts or workflows
- Removed commands will show "command not found" — no action needed unless referenced in custom automation

## [10.9.0] — 2026-04-13

### Changed
- Version bump (infrastructure release)

## [10.8.0] — 2026-04-11

### Headline
Design worker consolidation: 6 design workers → 2. Style pack system via `.impeccable.md`. Configurable models (gemini default, opus for creative skills).

### Breaking — Workers Removed (5)
- `impeccable-designer` — skills split between frontend-designer (18) and ux-auditor (4)
- `gemini-designer` — skills split between frontend-designer (1) and ux-auditor (3)
- `gemini-stylist` — 4 skills absorbed into frontend-designer
- `gemini-frontend` — 4 skills absorbed into frontend-designer
- `gemini-ux-auditor` — 4 skills absorbed into ux-auditor

### Added
- **`ux-auditor`** — new worker (11 skills). Design review & quality gate. Read-only, never writes code. Consolidates audit/critique/harden/normalize from impeccable-designer + 4 gemini-ux-auditor skills + 3 gemini-designer skills.
- **Style pack system** — `.impeccable.md` gains `style:` field. Workers auto-load design style specs + swipes. 9 styles: american-industrial, brutalist-raw, corporate-clean, dark-luxury, editorial-magazine, ethereal-abstract, liminal-portal, minimalist-swiss, retro-analog.
- `teach-impeccable` now presents style catalog during setup (Step 3)

### Changed
- **`frontend-designer`** — expanded from 0 to 27 skills. Now the single build+refine worker. Model: gemini (opus for frontend-design/overdrive/bolder/delight). MCP server preserved.
- `workers/registry.yaml` — version 10.8.0, Standalone Workers 11→9, Gemini Team 6→2
- `.claude/CLAUDE.md` — workers section updated
- `core.yaml` — version bump to 10.8.0

### Migration
See MIGRATION.md for step-by-step upgrade instructions.

## [10.7.1] — 2026-04-11

### Headline
Core cleanup: design skills moved to impeccable-designer worker, niche commands removed from core. Template ships a leaner, generic baseline.

### Breaking — Commands Removed from Core
- `/pr` — company-scoped (PR coordinator workflow)
- `/hq-growth-dashboard` — personal/niche metrics

### Breaking — Skills Moved to Workers
- **22 design skills** moved from `.claude/skills/` to `workers/impeccable-designer/skills/`. Invoke via `/run impeccable-designer {skill}`.
  - adapt, animate, arrange, audit, bolder, clarify, colorize, consolidate, critique, delight, distill, extract, frontend-design, harden, normalize, onboard, optimize, overdrive, polish, quieter, teach-impeccable, typeset
- **social-graphic** moved from `.claude/skills/` to `workers/social-strategist/skills/`.

### Changed
- `workers/impeccable-designer/worker.yaml` — added full `skills:` block (22 entries)
- `workers/social-strategist/worker.yaml` — added `social-graphic` skill entry
- `.claude/CLAUDE.md` — command count updated (44→36), workers section updated
- `workers/registry.yaml` — version bump to 10.7.1

## [10.7.0] — 2026-04-09

### Headline
Performance Audit Complete — ~50% session-start context reduction via pre-built policy digests. 8 commands consolidated to Archetype A (stub + SKILL).

### Added
- `.claude/hooks/load-policies-for-session.sh` — SessionStart digest loader
- `scripts/build-policy-digest.sh` — builds `_digest.md` from policy frontmatter
- `scripts/read-policy-frontmatter.sh` — YAML frontmatter parser helper
- `scripts/git-hooks/pre-commit` — auto-rebuilds digests on policy commits
- `.claude/policies/_digest.md` — pre-built global digest (94 hard + 78 soft)
- `.claude/policies/qmd-collection-masks.md` — qmd collection scoping policy
- `.claude/commands/audit-log.md` — renamed from `audit.md`, expanded to 208 lines
- `knowledge/hq-core/quick-reference.md` — new `## Command ↔ Skill Shapes` section (Archetype A/C docs)
- `workspace/orchestrator/monitor-project.sh` — single-project TUI dashboard (state.json
  + executions + progress.txt) now shipped with the template so `run-project.sh`'s
  auto-spawned monitor window has something to run

### Changed
- **7 commands flipped to Archetype A** (~20-line delegator stubs):
  `prd`, `handoff`, `learn`, `execute-task`, `search`, `startwork`, `brainstorm`
  → Canonical implementations now live in `.claude/skills/{name}/SKILL.md`
- `run-project.md` gained thin-router HTML comment (Archetype C marker)
- `.claude/settings.json` — `SessionStart` hook entry wired for digest loader
- `.claude/settings.json` — `cleanup-mcp-processes` Stop-hook timeout bumped 5 → 10s
- `.claude/scripts/run-project.sh` — `spawn_cmux_monitor()` rewritten to use
  Terminal.app via `osascript` instead of the cmux CLI. The cmux path failed
  silently under Claude.app (socket-ancestry auth + macos-applescript gate);
  Terminal.app is always scriptable so the monitor window actually opens.
- `.claude/settings.json` — added 5 rc-file deny rules (`~/.zshrc`, `~/.zprofile`,
  `~/.zshenv`, `~/.bashrc`, `~/.bash_profile`)
- 4 hooks refreshed — `auto-checkpoint-trigger`, `hook-gate`, `observe-patterns`,
  `screenshot-resize-trigger`
- 14 commands refreshed (non-Archetype-A bug fixes & polish)
- 8 net-new policies synced (now 171 total, up from 163)

### Performance
- HQ root session start: **−53% context** (37.2 KB → 17.3 KB)
- personal cwd: **−58% context** (45.5 KB → 19.1 KB)
- {company}-class cwd: **−61% context** (58.7 KB → 22.8 KB)
- vyg-class cwd: **−62% context** (67.1 KB → 25.5 KB)

### Removed
- `.claude/commands/audit.md` — orphan (renamed to `audit-log.md`)

### Breaking Changes
- The 7 commands listed under "Changed" above now delegate to `SKILL.md`. Any local
  edits to those `.md` files will be overwritten on upgrade — move edits into
  `.claude/skills/{name}/SKILL.md` instead, or fork the stub.

### Migration (v10.6.0 → v10.7.0)
1. Pull latest kit
2. `chmod +x scripts/git-hooks/pre-commit`
3. `ln -sf ../../scripts/git-hooks/pre-commit .git/hooks/pre-commit`
   (or merge into existing pre-commit wrapper)
4. Verify SessionStart hook fires: start a new Claude Code session in the project
   dir; look for `<policy-digest>` banner in the first turn
5. If any of the 7 consolidated commands had local edits, port them to the
   corresponding `.claude/skills/{name}/SKILL.md`

## [10.6.0] — 2026-04-07

### Added
- **`cleanup-mcp-processes` hook** — kills orphan MCP server processes on session Stop

### Changed
- **21 commands updated** — audit, checkpoint, cleanup, garden, handoff, harness-audit, hq-growth-dashboard, learn, newworker, pr, prd, reanchor, recover-session, remember, run-pipeline, run-project, run, search-reindex, search, startwork, understand-project
- **11 skills updated** — ascii-graphic, colorize, consolidate, execute-task, handoff, land, prd, run-project, run, search, social-graphic
- **154 policies synced** — scope-filtered (global + command); removed cross-cutting scope from sync
- **5 hooks updated** — auto-checkpoint-trigger, hook-gate, observe-patterns, screenshot-resize-trigger, cleanup-mcp-processes (new)
- **CLAUDE.md** — refreshed all sections, removed stale references
- **USER-GUIDE.md** — cleaned private command references, updated examples
- **modules.yaml** — removed company-specific module entries
- **settings.json** — added cleanup-mcp-processes Stop hook, synced env keys
- **Workers** — codex-coder, codex-debugger, codex-engine, sample-worker updated
- **Registry** — bumped to v10.6.0

### Removed
- (none)

## [10.5.0] — 2026-04-04

### Added
- **`/run-pipeline` command** — orchestrate multi-step pipelines with parallel execution, retry logic, and checkpoint recovery
- **`land-batch` skill** — batch-land multiple PRs in dependency order with CI monitoring
- **8 new policies** — `hq-bugfix-requires-tests`, `hq-data-collection-isolation`, `hq-github-review-thread-resolution`, `hq-no-test-shortcuts`, `hq-no-worktree-for-repo-work`, `paper-text-wrapping`, plus 2 tool-scoped policies
- **`context-manager` worker** (dev-team) — discover, maintain, and audit project context

### Changed
- **18 commands updated** — refreshed with latest workflow improvements, policy references, and Codex compatibility
- **13 skills updated** — enhanced instructions, better error handling, updated checklists
- **161 policies synced** (up from 154) — scope-filtered: global, command, cross-cutting, tool only
- **11 hooks** — updated hook-gate routing, screenshot-resize-trigger, observe-patterns
- **Knowledge bases refreshed** — 294 files synced across Ralph, hq-core, dev-team, design-styles, workers, projects, and more
- **CLAUDE.md** — updated content counts, refreshed sections, removed legacy references
- **USER-GUIDE.md** — cleaner company section, updated command tables
- **modules.yaml** — cleaned up, hq-core now points to `indigoai-us/hq` (was `hq-starter-kit`)
- **settings.json** — added `PATH` env var for consistent tool resolution
- **Workers** — codex workers updated with latest model references (opus/gpt-5.4)
- **41 skills** — all Codex-ready with `agents/openai.yaml` (100% coverage)

### Removed
- `knowledge/Ralph/11-team-training-guide.md` (private content)
- `workers/dev-team/qa-tester/skills/electron-e2e.md` (deprecated)

## [10.4.0] — 2026-04-03

### Added
- **9 new Codex-ready skills** — `brainstorm`, `execute-task`, `handoff`, `learn`, `prd`, `run`, `run-project`, `search`, `startwork` — each with `SKILL.md` + `agents/openai.yaml` for dual Claude Code / Codex discovery
- **Codex dual-format documentation** — CLAUDE.md now documents the skill structure, adaptation rules, and `codex-skill-bridge.sh status` coverage tool
- **Denylist exceptions mechanism** — `scrub-denylist.yaml` now supports an `exceptions` section for terms that must survive scrubbing (e.g. `indigoai-us`)
- **Codex conversion step** in `/publish-kit` — Step 4.5 verifies all synced skills have `agents/openai.yaml`

### Changed
- `scripts/codex-skill-bridge.sh` — enhanced with `commands_with_skills_count()`, `print_coverage_report()`, and symlink support in `openai_yaml_count()`
- `scripts/run-project.sh` — refreshed with latest orchestrator improvements
- 154 policies synced (scope-filtered: global, command, cross-cutting only)
- Skill coverage: 39/40 skills now Codex-ready (97%)

## [10.3.0] — 2026-04-02

### Added
- **`land` skill** — land a PR: monitor CI, resolve review issues, merge, verify production
- **12 new policies** — frustration-prevention rules (announce before irreversible, confirm creative direction, fix root cause not symptoms, never swallow errors, no production testing, post-parallel build verify, PR single concern, alert baseline calibration), plus orchestrator improvements (prd-files-match-acs-for-swarm, run-project-name-matches-dir, run-project-sigkill-retry, scrub-hook-no-denylist-in-template)

### Changed
- `/run-project` — added `--inline` execution mode for plan-first, in-session sequential story execution
- `/update-hq` — rewritten to pull from indigoai-us/hq (replaces starter-kit references)
- `/hq-growth-dashboard` — updated for indigoai-us/hq repo references
- All commands, policies, and hooks refreshed with latest content

## [10.2.0] — 2026-04-02

### Added
- 17 missing workers copied from hq-starter-kit: accessibility-auditor, exec-summary, frontend-designer, gemini-designer, gemini-stylist, gemini-ux-auditor, gstack-sprint, impeccable-designer, paper-designer, performance-benchmarker, pretty-mermaid, qa-tester, social-publisher, social-reviewer, social-shared, social-strategist, social-verifier

### Changed
- template/ canonicalized as single source of truth for HQ content (hq-starter-kit archived)
- core.yaml version bumped to 10.2.0

## v10.2.0 (2026-04-01)

Codex app compatibility — all 30 HQ skills now discoverable from OpenAI Codex via `agents/openai.yaml` metadata and modernized `.agents/skills/` bridge paths.

### Added
- **`agents/openai.yaml` for all 30 skills** — Codex app can now render skill names and descriptions in its UI. Each file contains `display_name` + `short_description` extracted from SKILL.md frontmatter
- **`scripts/generate-openai-yaml.sh`** — batch generator to create `agents/openai.yaml` from SKILL.md for any new skills. Supports `--dry-run` and `--force` flags
- **`.agents/skills/` bridge path** — Codex's primary discovery path (`~/.agents/skills/hq`) now supported alongside legacy `~/.codex/skills/hq`
- **Repo-level `.agents/skills/` bridge** — skills discoverable when running Codex from within HQ directory

### Changed
- **`scripts/codex-skill-bridge.sh`** — now manages 5 bridges (added global `.agents/skills/`, repo `.agents/skills/`). Status output shows openai.yaml coverage count
- Updated commands, policies, hooks, knowledge bases, and CLAUDE.md
- Worker configs refreshed

### Removed
- (none)

## v10.1.0 (2026-04-01)

Onboarding education kit + setup command overhaul. New users now get training materials and a guided first week.

### Added
- **Getting Started education kit** (`knowledge/public/getting-started/`) — 3 guides that ship with every HQ install:
  - `quick-start-guide.md` — What HQ is, the Core Loop, daily workflow, key concepts, rules of thumb
  - `cheatsheet.md` — One-page daily reference card (commands, cadence, troubleshooting)
  - `learning-path.md` — 11-module self-paced progression from beginner to advanced
- **4 new policies**: `bun-overrides`, `chunked-reads`, `clipboard-file-protocol`, `deconflict-postbridge-schedule`

### Changed
- **`/setup` command overhauled** — now an educational onboarding experience:
  - Phase 0: Welcome block explaining the 1000-employee analogy
  - Toolkit bridge after dependency checks (what each tool does)
  - Context bridge after identity collection (why HQ learns who you are)
  - Phase 4: Education Kit section with auto-open of quick-start-guide
  - "Your First Week" roadmap (Day 1 + Week 1 tasks)
- **Multiple commands updated**: `/audit`, `/cleanup`, `/garden`, `/prd`, `/quality-gate`, `/reanchor`, `/run-project`, `/startwork`, and others
- CLAUDE.md, USER-GUIDE.md, modules.yaml refreshed
- Knowledge bases updated (agent-browser, hq-core, hq-desktop specs)
- Worker configs updated

### Removed
- (none)

## v10.0.0 (2026-03-31)

Obsidian vault integration, new policies, command updates, and scrub hardening.

### Added
- **Obsidian vault config** (`.obsidian/`) — pre-configured doc viewer with graph colors, CSS snippet, folder exclusions, bookmarks. Open HQ in Obsidian for instant browsing
- `/hq-growth-dashboard` — pull HQ growth metrics (npm downloads, GitHub stars)
- `protect-core.sh` hook — prevents edits to core infrastructure files
- **15 new policies**: `agent-browser-react-false-positives`, `articles-blog-first`, `bulk-sed-exception-ordering`, `cio-browser-navigation`, `dual-codex-review-pattern`, `git-filter-repo-case-variants`, `hq-docker-build-platform-amd64`, `hq-docker-in-docker-path-translation`, `hq-nextjs-clean-types-after-page-delete`, `hq-swarm-rust-hub-files`, `hq-telegram-single-poller`, `hq-tmux-plan-approval-dance`, `hq-use-neon-not-vercel-postgres`, `hq-verify-shared-files-after-parallel-agents`, `image-context-isolation`
- `obsidian-setup.md` knowledge doc in hq-core

### Changed
- **16 commands** updated: `/audit`, `/cleanup`, `/garden`, `/harness-audit`, `/model-route`, `/prd`, `/reanchor`, `/recover-session`, `/remember`, `/run-project`, `/run`, `/search-reindex`, `/search`, `/startwork`, `/understand-project`, `/update-hq`
- **4 skills** updated: `ascii-graphic`, `colorize`, `consolidate`, `social-graphic`
- **30+ policies** updated with latest learned rules
- **5 workers** updated: `accessibility-auditor`, `content-brand`, `content-legal`, `content-product`, `content-sales`
- **4 hooks** updated: `auto-checkpoint-trigger`, `hook-gate`, `observe-patterns`, `screenshot-resize-trigger`
- `CLAUDE.md`, `USER-GUIDE.md`, `modules.yaml`, `audit-log.sh` refreshed
- Scrub denylist expanded with `{company}` and `{company}`

### Removed
- `qa-screenshot-isolation.md` policy (replaced by `image-context-isolation`)

## v9.0.0 (2026-03-25)

Major expansion: skills, policies, and infrastructure blueprints now included in the kit.

### Added
- **30 skills** in `.claude/skills/` — `adapt`, `agent-browser`, `animate`, `arrange`, `ascii-graphic`, `audit`, `bolder`, `clarify`, `colorize`, `consolidate`, `critique`, `delight`, `distill`, `document-release`, `extract`, `frontend-design`, `harden`, `investigate`, `normalize`, `onboard`, `optimize`, `overdrive`, `polish`, `quieter`, `retro`, `review`, `review-plan`, `social-graphic`, `teach-impeccable`, `typeset`
- **26 gstack skills** — `g-autoplan`, `g-benchmark`, `g-canary`, `g-careful`, `g-codex`, `g-cso`, `g-design-consultation`, `g-design-review`, `g-document-release`, `g-freeze`, `g-gstack-upgrade`, `g-guard`, `g-investigate`, `g-land-and-deploy`, `g-office-hours`, `g-plan-ceo-review`, `g-plan-design-review`, `g-plan-eng-review`, `g-qa`, `g-qa-only`, `g-retro`, `g-review`, `g-setup-browser-cookies`, `g-setup-deploy`, `g-ship`, `g-unfreeze`. Credit: [Garry Tan](https://github.com/garrytan/gstack) (Y Combinator)
- **89 policies** in `.claude/policies/` — workflow rules, safety guards, tool-specific gotchas (git, Vercel, Supabase, Linear, Clerk, Expo, orchestrator, and more)
- `.ignore` — ripgrep ignore config, critical for Grep hygiene in HQ
- `settings/orchestrator.yaml` — swarm/file-locking/state-machine config for `/run-project`
- `USER-GUIDE.md` — command reference, worker guide, and typical session walkthrough
- `modules/modules.yaml` — knowledge module registry for `qmd` search integration
- `scripts/codex-skill-bridge.sh` — Codex ↔ Claude skill bridge installer
- `scripts/audit-log.sh` — structured audit log utility
- `scripts/resize-screenshot.sh` — screenshot resize utility (used by `screenshot-resize-trigger.sh` hook)

### Changed
- Updated all existing commands, workers, knowledge, hooks to latest HQ state
- CLAUDE.md refreshed with current structure and guidance

## v8.2.0 (2026-03-23)

New commands, workers, knowledge, and a comprehensive PII/company scrub across all files.

### Added
- `/document-release` — Post-ship documentation sync for README, CLAUDE.md, architecture docs
- `/investigate` — Iron Law debugging with structured root cause analysis
- `/retro` — Project/session retrospective with pattern surfacing
- `block-inline-story-impl.sh` hook — prevents inline story implementation outside `/execute-task`
- `impeccable-designer` worker — quality-obsessed design with full Impeccable skill chain
- `paper-designer` worker — bidirectional Paper Desktop design bridge via MCP
- `knowledge/impeccable/` — Impeccable design system knowledge base
- `knowledge/design-styles/formulas/` — design formula templates (app, print, slides, social)
- `knowledge/hq/handoff-templates.md` + `knowledge-taxonomy.md`
- `knowledge/agent-browser/tauri-testing.md` — Tauri app testing guide
- Story test runner in `run-project.sh` — cumulative regression guard after each story

### Changed
- 19 commands updated with latest improvements
- `review.md` + `understand-project.md` synced from upstream
- `auto-checkpoint-trigger.sh`, `hook-gate.sh`, `observe-patterns.sh` updated
- `run-project.sh` — codex model hints, story test runner, HQ_EXECUTING_STORY env var
- All Ralph, ai-security-framework, agent-browser, design-styles, dev-team, gemini-cli, loom knowledge updated
- Registry bumped to v10.0 with 45 public workers

### Removed
- `/imessage` command (personal, not generic)
- All {PRODUCT}/{Product}/{Product} references scrubbed from CLAUDE.md, commands, workers, knowledge
- {Product} Linear Integration section removed from CLAUDE.md
- {PRODUCT} Project Repos commit rules section removed from CLAUDE.md
- All company-specific examples replaced with generic placeholders

### Security
- Full PII scrub pass across 753 files
- ggshield secret scan — zero findings

## v8.1.1 (2026-03-12)

Fix missing scaffold directories — new installs now get the full canonical HQ folder structure.

### Fixed

- **Installer template** — Added missing directories: `repos/{public,private}`, `companies/`, `settings/`, `data/`, `modules/`, `scripts/`, `workspace/{learnings,reports}`
- **macOS .pkg builder** — `prepare_payload()` now creates all canonical directories (was missing 9)
- **`.ignore` file** — New installs now include ripgrep ignore for `repos/`, `node_modules/`, `**/.git/` (prevents Grep slowdowns)

### Added

- **`/review`** — Paranoid pre-landing code review with two-pass analysis (CRITICAL/INFORMATIONAL)
- **`/review-plan`** — Structured plan review with scope modes (EXPANSION / HOLD / REDUCTION)
- **`companies/_template/`** — Policy template and starter `manifest.yaml` included in new installs
- **`repos/{public,private}/`** — Added to starter-kit repo root

### Changed

- **Template CLAUDE.md** — Structure section updated to show full directory tree (13 dirs, was 7)
- **`auto-checkpoint-trigger.sh`** — Updated hook logic

## v8.1.0 (2026-03-12)

Ralph loop reliability — in-session mode default, 3-layer passes detection, swarm retry tracking, per-story branch isolation, project reanchor, and 10+ reliability fixes.

### Added

- **`/run-project` — In-session mode default** — Stories run as Task() sub-agents within the current Claude session (faster, no process overhead). Headless bash mode via `--bash` flag.
- **`/run-project` — `--codex-autofix` flag** — Auto-fix P1/P2 codex review findings via targeted `claude -p` agent with 300s timeout.
- **`/run-project` — Context safety limits** — Auto-handoff after 6 stories or 70% context ceiling.
- **`/run-project` — Project Reanchor** — Every 3 completed stories, evaluates remaining stories for spec drift. Writes reanchor report.
- **`run-project.sh` — 3-layer passes detection** — Layer 1 (JSON parse) → Layer 2 (full-file scan for task_id+status pairs) → Layer 3 (git heuristic: commits after checkout + declared files touched). Replaces simple grep fallback.
- **`run-project.sh` — Swarm retry tracking** — `_swarm_retry_get()`/`_swarm_retry_inc()` with max 2 retries per story. Exhausted stories filtered from new batch selection.
- **`run-project.sh` — Per-story branch isolation** — `project-branch--story-slug` naming avoids "already checked out" conflicts in swarm mode.
- **`run-project.sh` — Full commit-range cherry-pick** — Uses `merge-base` to capture all worktree commits, not just HEAD.
- **`run-project.sh` — Stale PID cleanup** — Dead PIDs from crashed processes cleaned from `current_tasks` on startup.
- **`run-project.sh` — macOS timeout fallback** — `gtimeout` → `perl -e alarm` chain for bash 3.2 compatibility.
- **`run-project.sh` — Mandatory termination protocol** — Stricter sub-agent JSON output enforcement ("LAST output must be JSON only").

### Changed

- **`/prd` — 7-batch interview** — Expanded from 4 to 7 question batches (Users/Current State, Data/Architecture, Integrations, Quality/Shipping as separate batches). Dynamic question enrichment from company policies and repo scan.
- **CLAUDE.md — Token optimization** — `MAX_THINKING_TOKENS` bumped to 31999. Added `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING` env var.
- **CLAUDE.md — Linear rules 11 & 12** — Default assignee by team + no-orphan-issues enforcement.
- **13 commands PII-scrubbed** — audit, cleanup, garden, model-route, reanchor, recover-session, remember, run, search, search-reindex, startwork, update-hq refreshed.

### Fixed

- `run-project.sh` — `files_changed` JSON validation in `update_state_completed()`
- `run-project.sh` — Empty PID → null (was crash on empty string)
- `run-project.sh` — `date -u` flag for BSD date UTC correctness
- `run-project.sh` — Per-story branch cleanup after worktree merge (was leaking branches)
- `run-project.sh` — `process_swarm_completion()` receives `start_epoch` for Layer 3 git heuristic

---

## v8.0.1 (2026-03-10)

### Fixed

- **`run-project.sh` — bash 3.2 crash** — 8 `local` declarations outside functions caused `set -e` to exit the script on macOS (bash 3.2). Affected swarm dispatch, sequential retry-skip, and project completion code paths. Replaced with plain variable assignments.
- **`run-project.sh` — worktree self-removal** — When `branchName` matches the repo's current checkout (e.g., both are `main`), `ensure_worktree()` now detects this and skips worktree setup instead of "reusing" the main repo as a worktree. Prevents `cleanup_worktree()` from attempting to `git worktree remove` the main working directory on exit.

## v8.0.0 (2026-03-10)

Policy-first system — all major commands now scan and enforce policies. `/learn` rewrite creates policy files as primary output. 1 new command (`/strategize`), smarter regression gates.

### Added

- **Standard Policy Loading Protocol** (CLAUDE.md) — 5-step protocol for all commands to load company → repo → global policies. Documents which commands implement it.
- **`/startwork` — Policy scan** (Step 2.5) — Sessions now load applicable policies on startup. Displays policy counts + hard-enforcement rule titles in orientation block.
- **`/run-project` — Pre-Loop policy loading** — Orchestrator loads company + repo + global policies before entering the Ralph loop. Hard-enforcement policies block the loop if violated.
- **`/prd` — Repo policy loading** — PRD creation now checks `{repoPath}/.claude/policies/` for repo-scoped constraints (commit hooks, deploy procedures, code location rules).
- **`/run` — Policy loading** (Step 1b) — Worker execution loads company policies from worker path context and repo policies if applicable.
- **`/learn` — Scan existing policies** (Step 4.5) — Before creating new rules, scans existing policy files for updates. Prevents duplicate policies.
- **`/learn` — Policy file output** — Primary output is now structured policy files (YAML frontmatter + Rule + Rationale) in scope-appropriate directories. Worker.yaml injection retained as fallback for worker-specific learnings only.
- **`run-project.sh` — Regression baseline** — Captures pre-existing error counts on first gate run. Only flags errors above baseline as regressions, preventing false positives in repos with pre-existing issues.
- **`run-project.sh` — Headless doc sweep** — `run_doc_sweep()` runs `claude -p` to update 4 documentation layers (internal docs, external docs, repo knowledge, company knowledge) after project completion. Replaces interactive doc-sweep-flag.json.
- **`run-project.sh` — Swarm mode** (`--swarm [N]`) — Parallel story execution via git worktrees. Pre-acquires file locks, dispatches eligible stories as background `claude -p` processes, monitors PIDs with periodic check-ins, cherry-picks commits sequentially. Stories without `files[]` are never swarmed.
- **`run-project.sh` — Signal trapping** — `cleanup_on_signal()` catches SIGINT/SIGTERM, kills swarm children, releases locks/checkouts, sets state to "paused".
- **`run-project.sh` — Worktree isolation** — Each project gets its own git worktree for branch isolation. `check_repo_conflict()` detects concurrent orchestrators on the same repo. `ensure_worktree()` / `cleanup_worktree()` manage lifecycle.
- **`settings/orchestrator.yaml` — Swarm config** — New `swarm:` section with `max_concurrency`, `checkin_interval_seconds`, `require_files_declared`.
- **New command** — `/strategize` for strategic prioritization with optional deep review.

### Changed

- **`/learn`** — Major rewrite: policy files are now primary output (was worker.yaml/CLAUDE.md injection). Step 3 scope resolution targets policy directories. Step 5 creates structured policy files per `policies-spec.md`. CLAUDE.md `## Learned Rules` reserved for global promotion of critical rules only.
- **`/startwork`** — Now policy-aware: loads company, repo, and global policies during session startup.
- **`/run-project`** — Now policy-aware: loads policies before first task, passes to sub-agents.
- **`/prd`** — Now loads repo policies in addition to company policies during PRD creation.
- **`/run`** — Now policy-aware: determines company from worker path and loads applicable policies.
- **`/audit`**, **`/handoff`**, **`/harness-audit`**, **`/model-route`** — Various improvements.
- **`run-project.sh`** — Regression gates upgraded with baseline comparison. Headless doc sweep. Swarm mode (+716 lines). Signal trapping. Worktree isolation. Budget caps removed.
- **`/execute-task`** — Self-owned lock skip (orchestrator pre-acquires for swarm). Orchestrator writes `passes` (single-writer pattern).
- **CLAUDE.md** — Added Standard Policy Loading Protocol to Policies section. Updated command count to 44+.

---

## v7.0.0 (2026-03-09)

Hook profiles, audit logging, 9 new commands, 4 new workers, full Ralph orchestrator.

### Added

- **Hook Profiles** — Runtime-configurable hook system via `HQ_HOOK_PROFILE` env var (minimal/standard/strict). All hooks route through `hook-gate.sh`. Disable individual hooks via `HQ_DISABLED_HOOKS`.
- **Token Optimization** (CLAUDE.md) — `MAX_THINKING_TOKENS`, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`, `CLAUDE_CODE_SUBAGENT_MODEL` env var documentation.
- **`hook-gate.sh`** — Profile routing hub for all hooks. Reads `HQ_HOOK_PROFILE` and `HQ_DISABLED_HOOKS` before delegating.
- **`detect-secrets.sh`** — PreToolUse hook blocks API keys, tokens, and credentials in bash commands.
- **`observe-patterns.sh`** — Stop hook captures session pattern analysis on conversation end.
- **`scripts/audit-log.sh`** — Audit log engine: append, query, summary. JSONL storage at `workspace/metrics/audit-log.jsonl`.
- **9 new commands** — `/audit`, `/brainstorm`, `/dashboard`, `/goals`, `/harness-audit`, `/idea`, `/model-route`, `/quality-gate`, `/tdd`.
- **4 new workers** — `accessibility-auditor` (WCAG 2.2 AA), `exec-summary` (McKinsey SCQA), `performance-benchmarker` (Core Web Vitals + k6), `reality-checker` (final quality gate).

### Changed

- **`settings.json`** — All hooks rewired through `hook-gate.sh`. Added PreToolUse Bash → `detect-secrets`, Stop → `observe-patterns`.
- **`run-project.sh`** — Full Ralph orchestrator (1390 lines). Audit log integration, `--tmux` mode, session ID tracking.
- **`/execute-task`** — Checkout guard prevents concurrent story execution.
- **`/prd`** — Brainstorm detection (steps 3.5 + 5.5) redirects to `/brainstorm` when appropriate.
- **`/run-project`** — Worked example, `--tmux` flag documentation.
- **CLAUDE.md** — Added Token Optimization + Hook Profiles sections. Updated workers section (+4 workers). Updated command count to 35+.
- **`workers/registry.yaml`** — Version 8.0 → 9.0. Added 4 new workers. Updated counts: Standalone 6→9, Dev Team 16→17.
- **README.md** — Updated What's New to v7.0.0, command count 18→35+, new directory structure with hooks/.

### Removed

- **PR team workers (6)** — `pr-shared`, `pr-strategist`, `pr-writer`, `pr-outreach`, `pr-monitor`, `pr-coordinator` removed (private/company-specific).
- **`knowledge/hq/`** — Duplicate of `knowledge/hq-core/`, deleted.

---

## v6.5.1 (2026-03-07)

LSP support, hook improvements, and command cleanup.

### Added
- **LSP section** (CLAUDE.md) — Guidance for using LSP tools (go-to-definition, find-references, type info) over grep when `ENABLE_LSP_TOOL=1` is set
- **LSP setup** (README) — Prerequisites section with setup instructions for enabling LSP
- **Grep safety hook** — PreToolUse hook (`block-hq-grep.sh`) for HQ root grep protection
- **Cross-company settings hook** — PreToolUse hook (`warn-cross-company-settings.sh`) warns when reading settings from wrong company context
- **context-manager worker** — Discover, maintain, and audit project context (4 skills: audit, discover, learn, update)

### Removed
- `/checkemail` — Moved to private (requires personal Gmail config)
- `/email` — Moved to private (requires personal Gmail config)

---

## v6.5.0 (2026-03-06)

Enhanced company isolation, new worker teams, expanded knowledge, and command updates.

### Added

- **Skills section** (CLAUDE.md) — `.claude/skills/` tree with Codex symlink bridge for cross-tool skill sharing.
- **Policies (Learned Rules) section** (CLAUDE.md) — Standalone section documenting policy file directories and precedence for programmatic rule storage.
- **Gemini workers** (3) — `gemini-coder`, `gemini-reviewer`, `gemini-frontend` for Gemini CLI-based code generation, review, and frontend work.
- **knowledge-tagger worker** — Auto-classify and tag knowledge documents.
- **site-builder worker** — Local business website builder.
- **gemini-cli knowledge base** — Gemini CLI integration docs.
- **New knowledge bases indexed** — agent-browser, curious-minds, pr, context-needs, project-context added to CLAUDE.md knowledge list.

### Changed

- **Company Isolation** (CLAUDE.md) — Expanded with manifest infrastructure routing fields (`services`, `vercel_team`, `aws_profile`, `dns_zones`), 3-step operation protocol, credential access policy reference, and stricter hard rules.
- **Workers** (CLAUDE.md) — Updated counts to include social-team (5), pr-team (6), gardener-team (3), gemini-team (3), knowledge-tagger, site-builder.
- **Knowledge Repos** (CLAUDE.md) — Clarified embedded git repo pattern for company knowledge. Added `Reading/searching` note.
- **Search rules** (CLAUDE.md) — Added rows for PRD discovery, worker yaml lookup, and company manifest lookup. Added Glob blocking rule for `prd.json`/`worker.yaml` patterns.
- **Infrastructure-First** (CLAUDE.md) — Updated `/prd` to reference company-scoped project paths.
- **Commands count** (CLAUDE.md) — Updated from 24 to 35+.
- **/execute-task** — Refined codex-reviewer inline pattern, improved back-pressure error handling.
- **/prd** — Company Anchor (Step 0) for automatic company scoping from arguments. Beads sync (Step 7).
- **/run-project** — Externalized to `scripts/run-project.sh` bash orchestrator with CLI flags (--max-budget, --model, --timeout, --retry-failed, --verbose). Process-level isolation via `claude -p`.
- **/handoff** — Added knowledge update step (0b) for documenting domain knowledge in company knowledge bases.
- **/learn** — Updated to inject rules into target files (worker.yaml, command .md, knowledge files, CLAUDE.md) with cap enforcement and global promotion.
- **/startwork** — Enhanced with company knowledge loading and Vercel project context.
- **/checkemail** — Email-triage app integration with queue/response JSON schema and Tauri desktop UI.
- **/email** — Expanded cleanup workflow with 4-phase triage, Linear ticket creation, and PRD creation for deferred items.
---

## v6.4.0 (2026-02-23)

Company-scoped projects, file lock acquisition, policy loading, and new commands.

### Added

- **/imessage** — Send iMessage to saved contacts via Messages.app.
- **/execute-task — File lock acquisition** (step 5.5) — Acquires file locks on start, releases on completion/failure. Conflict modes: `hard_block`, `soft_block`, `read_only_fallback`.
- **/execute-task — Policy loading** (step 5.6) — Loads applicable policies from company, repo, and global directories before worker execution.
- **/execute-task — Dynamic file lock expansion** (step 6d.5) — Workers can touch more files than predicted; locks expand dynamically.
- **/execute-task — File lock release on failure** (step 8.0) — Locks released even on task failure to prevent orphaned locks.
- **/execute-task — iMessage notify** (step 7c.5) — Optional completion notifications to contacts whose `context` includes the project.
- **/execute-task — Linear comments** (step 7a.6) — Comment on Linear issues with @mentions on state changes.
- **/run-project — Board sync** (step 4.5) — Sync project status to `board.json` on start and completion.
- **/run-project — File lock conflict check** (step 5a.1) — Skip stories with file conflicts during task selection.
- **/run-project — Linear comments** (step 5a.6) — Comment on issues during state transitions.
- **/prd — Board sync** (step 5.5) — Upsert project entry in `board.json` after PRD creation.
- **/prd — `files` field** — Story schema now includes `files: []` for file lock tracking.

### Changed

- **/execute-task** — Company-scoped project resolution: searches `companies/*/projects/` first, then `projects/` fallback.
- **/prd** — Company-scoped project creation at `companies/{co}/projects/{name}/`. Infrastructure pre-check now creates embedded repos (`git init` in `companies/{co}/knowledge/`).
- **/prd** — STOP after creation + handoff. Hard block on implementation in same session. MANDATORY file creation rule added.
- **/run-project** — Company-scoped project resolution. Auto-reanchor now re-reads policies (not learned rules). Board sync on completion.
- **/newworker** — Updated paths for company-scoped workers (`companies/{co}/workers/{id}/`).
- **/checkpoint** — Knowledge repo git state check now supports embedded repos (not just symlinks).
- **CLAUDE.md — Policies** — Three-directory structure (company > repo > global) with precedence and spec reference.
- **CLAUDE.md — Learning System** — Migrated from inline injection to policy file creation.
- **CLAUDE.md — Knowledge Repos** — Clarified embedded vs symlinked repos.

---

## v6.3.0 (2026-02-21)

Policies, file locking, Glob safety hook, and safe settings.json migration.

### Added

- **CLAUDE.md — Policies** — Company-scoped standing rules (`companies/{co}/policies/`) with hard/soft enforcement. Proactive directives that override default behavior. Template at `companies/_template/policies/example-policy.md`.
- **CLAUDE.md — File Locking** — Story-scoped file flags prevent concurrent edit conflicts in multi-agent projects. Config via `settings/orchestrator.yaml`, locks in `.file-locks.json`.
- **Glob safety hook** — PreToolUse hook (`block-hq-glob.sh`) blocks Glob from HQ root, preventing 20s+ timeouts from symlinked repos. Suggests scoped paths instead.
- **companies/_template/policies/** — Policy template for `/newcompany` scaffolding. YAML frontmatter (id, title, scope, trigger, enforcement) + markdown body.
- **/update-hq — settings.json merge** — New 5b-SETTINGS section with JSON-aware hook merging. Preserves user permissions and custom hooks, adds new hook entries from upstream without overwriting.

### Changed

- **CLAUDE.md — Company Isolation** — Added Linear credentials cross-posting guard: validate `workspace` field matches expected company before any Linear API call.
- **CLAUDE.md — Learned Rules** — 4 new rules: pre-deploy domain check, EAS build env vars, Vercel env var trailing newlines, model routing.
- **`.claude/settings.json`** — Added PreToolUse hook entry for Glob safety.
- **/update-hq** — Added settings.json special handling (5b-SETTINGS section), template directory handling, updated step numbering.

---

## v6.2.0 (2026-02-20)

New CLAUDE.md behavioral sections and expanded learned rules.

### Added

- **CLAUDE.md — Session Handoffs** — Explicit handoff workflow: commit first, write handoff.json, update INDEX, create thread. Never plan mode during handoff.
- **CLAUDE.md — Corrections & Accuracy** — Apply user corrections exactly as stated. No re-interpretation or paraphrasing.
- **CLAUDE.md — Sub-Agent Rules** — Sub-agents must commit own work before completing. Orchestrator verifies uncommitted changes.
- **CLAUDE.md — Git Workflow Rules** — Branch verification, merge-over-rebase for diverged branches, hook bypass during merge/rebase, no accidental main commits.
- **CLAUDE.md — Vercel Deployments** — Org/team verification, framework detection checks, SSO fallback to local testing.

### Changed

- **CLAUDE.md — Learned Rules** — 6 new rules: Vercel custom domain deploy safety, Task() sub-agents lack MCP, Shopify 2026 auth, Vercel preview SSO, Vercel domain team move, Vercel framework detection. Max cap raised 10 → 25.

---

## v6.1.0 (2026-02-20)

Codex CLI integration — fixes codex workers not actually calling OpenAI Codex in the pipeline.

### Changed

- **`/execute-task`** — Added inline Codex review step (6c.5) that runs `codex review --uncommitted` directly via Bash instead of spawning a sub-agent. Deterministic — cannot be skipped. Added pre-flight `which codex` check (step 2.5) with graceful degradation. Codex debugger auto-recovery now uses CLI when available.
- **codex-reviewer** — All 3 skills (review-code, improve-code, apply-best-practices) rewritten from MCP tool calls to Codex CLI (`codex review`, `codex exec --full-auto`). Worker YAML updated: MCP section replaced with CLI config.
- **codex-coder** — All 3 skills (generate-code, implement-feature, scaffold-component) rewritten from MCP to `codex exec --full-auto` via Bash.
- **codex-debugger** — All 3 skills (debug-issue, root-cause-analysis, fix-bug) rewritten from MCP to Codex CLI. Root-cause-analysis uses `codex exec --sandbox read-only` for analysis-only mode.
- **codex-engine** — Description updated. MCP server kept for standalone use but no longer required for pipeline execution.

### Fixed

- **Codex workers actually call Codex now** — Previously, Task() sub-agents didn't inherit MCP server connections, so codex-reviewer/coder/debugger could never access their MCP tools. They either skipped the phase or ran as Claude-only reviews. CLI-based approach works because Bash is always available to sub-agents.

## v6.0.0 (2026-02-19)

Major release: 5 worker teams (39 workers), gardener audit system, new commands.

### Added — Worker Teams

- **Dev Team (16 workers)** — Full development team now included (was removed in v5.0.0). Project manager, task executor, architect, backend/frontend/database devs, QA, motion designer, infra dev, code reviewer, knowledge curator, product planner, plus codex workers (coder, reviewer, debugger, engine).
- **Content Team (5 workers)** — Content analysis pipeline: brand voice, sales copy, product accuracy, legal compliance, shared utilities.
- **Social Team (5 workers)** — Social media pipeline: strategist, reviewer, publisher, verifier, shared utilities.
- **PR Team (6 workers)** — Public relations pipeline: strategist, writer, outreach, monitor, coordinator, shared utilities.
- **Gardener Team (3 workers)** — HQ content audit & cleanup: garden-scout (fast scan), garden-auditor (deep validation), garden-curator (execute actions). See `/garden` command.

### Added — Standalone Workers

- **frontend-designer** — Bold UI generation using Anthropic skill
- **qa-tester** — Automated website testing with Playwright + agent-browser
- **security-scanner** — Security scanning and vulnerability detection
- **pretty-mermaid** — Mermaid diagram rendering with 14 themes

### Added — Commands

- **`/garden`** — Multi-worker audit pipeline for detecting stale content, duplicates, orphans, INDEX drift, and conflicts. Three-phase (scout→audit→curate) with human approval gates. Scope by company, directory, or full HQ sweep.
- **`/startwork`** — Lightweight session entry point: pick company or project, gather minimal context.
- **`/newcompany`** — Scaffold a new company with full infrastructure (dirs, manifest, knowledge repo, qmd collection).
- **`/{custom-command}`** — Onboard new students with full pipeline (DB, PRD, deck).

### Changed

- **`workers/registry.yaml`** — Version 7.0. Now includes all 39 public workers across 5 teams plus 4 standalone workers.
- **`.claude/CLAUDE.md`** — Updated with gardener-team, company manifest, knowledge repo patterns, learned rules system, auto-checkpoint/handoff hooks.
- **22 existing commands refreshed** — Various improvements to `/checkemail`, `/checkpoint`, `/cleanup`, `/decide`, `/email`, `/execute-task`, `/handoff`, `/learn`, `/metrics`, `/newworker`, `/nexttask`, `/prd`, `/reanchor`, `/recover-session`, `/remember`, `/run`, `/run-project`, `/search`, `/search-reindex`.
- **Knowledge bases expanded** — New: agent-browser specs, PR knowledge, curious-minds. Updated: Ralph, hq-core, dev-team, design-styles, loom, workers, projects.

### Breaking

- Registry version 6.0 → 7.0 with restructured worker paths and team groupings. If you have custom workers, merge carefully.
- Dev team workers re-added (removed in v5.0.0). If you built custom equivalents, review for conflicts.

---

## v5.5.2 (2026-02-17)

### Added
- **Auto-checkpoint hooks** — PostToolUse hooks detect git commits and report/draft generation, nudge Claude to write lightweight thread files automatically. No more manual `/checkpoint` after every commit.
- **Auto-handoff hook** — PreCompact hook fires when context window fills, nudges Claude to run `/handoff` before state is lost.
- `.claude/hooks/auto-checkpoint-trigger.sh` — PostToolUse detection script
- `.claude/hooks/auto-handoff-trigger.sh` — PreCompact detection script
- `.claude/settings.json` — Hook registration (PostToolUse + PreCompact)

### Changed
- `/checkpoint` — New step 1: checks for recent auto-checkpoint (<5 min) and upgrades it to full checkpoint instead of duplicating
- `/cleanup` — Added 14-day auto-checkpoint purge (separate from 30-day manual thread archival)
- `CLAUDE.md` — Replaced aspirational Auto-Checkpoint/Auto-Handoff sections with concrete hook-backed procedures
- `knowledge/hq-core/thread-schema.md` — Added `type` field (`checkpoint` | `auto-checkpoint` | `handoff`) and lightweight auto-checkpoint schema variant

---

## v5.5.1 (2026-02-17)

### Changed
- `/setup` — `repos/public/` and `repos/private/` creation promoted to strict, first step in Phase 2. Removed duplicate `mkdir` calls.
- `/update-hq` — Added repos directory validation to Phase 4 pre-flight. Creates missing `repos/public/` and `repos/private/` during migration.

---

## v5.5.0 (2026-02-16)

### Added
- `/recover-session` — Recover dead Claude Code sessions that hit context limits without running `/handoff`. Reconstructs thread JSON from JSONL session data.
- `/update-hq` — Renamed from `/migrate`. Upgrade HQ from latest starter-kit release (friendlier command name).

### Changed
- `.claude/CLAUDE.md` — Updated command count (19→23), added Communication section with `/email`, `/checkemail`, `/decide`, added `/recover-session` to Session Management

### Fixed
- Scrubbed remaining company-specific reference from v5.4.0 changelog

### Renamed
- `/migrate` → `/update-hq` — Same functionality, more intuitive name

---

## v5.4.0 (2026-02-12)

### Added
- `/checkemail` — Quick inbox cleanup: auto-archive junk, then triage what matters one at a time
- `/decide` — Human-in-the-loop batch decision UI for classifying, reviewing, or triaging 5+ items
- `/email` — Multi-account Gmail management via gmail-local MCP
- **HQ Desktop knowledge** — 12 spec files for the upcoming HQ Desktop app (terminal sessions, knowledge browser, worker management, project views, notifications, event sources)
- `hq-core/quick-reference.md` — Lookup tables for workers, commands, repos
- `hq-core/starter-kit-compatibility-contract.md` — Contract between HQ and starter-kit
- `hq-core/desktop-claude-code-integration.md` — Claude Code integration specs
- `hq-core/desktop-company-isolation.md` — Company isolation for desktop
- `hq-core/hq-structure-detection.md` — HQ structure detection logic

### Changed
- `/run-project` — Sub-agents now explicitly forbidden from using EnterPlanMode/TodoWrite (prevents Claude from overriding the PRD orchestrator with its own plan)
- `/execute-task` — Added anti-plan rule to Rules section (defense-in-depth)
- `/checkpoint`, `/cleanup`, `/handoff`, `/metrics`, `/newworker`, `/reanchor`, `/remember`, `/run`, `/search`, `/search-reindex` — Various improvements and refinements
- Codex workers (codex-coder, codex-reviewer, codex-debugger) — Updated worker configs and skills
- Knowledge files updated: `index-md-spec.md`, `thread-schema.md`, `skill-schema.md`, `state-machine.md`, `projects/README.md`, `workers/README.md`

### Fixed
- Scrubbed remaining PII from prior releases (company names in examples, absolute paths)
- Removed company-specific command references from changelog and migration guide

## v5.3.0 (2026-02-11)

### Added
- **Codex Workers (3)** — Production-ready AI workers powered by OpenAI Codex SDK via MCP:
  - `codex-coder` — Code generation, feature implementation, component scaffolding (3 skills)
  - `codex-reviewer` — Code review, targeted improvements, best-practices pass (3 skills)
  - `codex-debugger` — Error diagnosis, root-cause analysis, bug fixing with back-pressure loop (3 skills)
- **MCP Integration Pattern** — Workers can now connect to external AI tools via Model Context Protocol. Codex workers demonstrate the shared MCP server pattern (codex-engine wraps the Codex SDK, three workers share it).
- **9 skill files** — Full markdown skill definitions with process steps, arguments, output schemas, and human checkpoints for all codex workers.
- **README — Codex Workers section** — Complete documentation with usage examples, prerequisites, and architecture overview.
- **README — OpenAI Codex** added to prerequisites table (optional).

### Changed
- **`workers/sample-worker/worker.yaml`** — Enhanced with modern patterns: MCP integration (commented-out template), reporting section, spawn_method, retry_attempts, dynamic context loading, verification with back-pressure commands, human checkpoints.
- **`workers/registry.yaml`** — Version 5.0 → 6.0. Added dev-team section with 3 codex workers.
- **`.claude/CLAUDE.md`** — Added MCP Integration section, updated Workers section with bundled worker listings, updated structure tree with dev-team directory.
- **README** — Updated "What's New" to lead with Codex Workers + MCP (v5.3). Worker YAML example updated to show modern patterns (execution, verification, MCP, state_machine). Updated worker type examples.

---

## v5.2.0 (2026-02-11)

### Added
- **`/setup` — CLI dependency checks**: Now checks for GitHub CLI (`gh`) and Vercel CLI (`vercel`) during setup, with install + auth instructions. Non-blocking (recommended, not required except `claude` itself).
- **`/setup` — Knowledge repo scaffolding**: Setup now creates a personal knowledge repo (`repos/private/knowledge-personal/`) as a proper git repo and symlinks it into `companies/personal/knowledge/`. Explains the symlink pattern and how to convert bundled knowledge later.
- **README — Prerequisites table**: New section listing all CLI tools (claude, gh, qmd, vercel) with install commands.
- **README — Knowledge Repos guide**: Full walkthrough: how symlinks work, creating repos, committing changes, converting bundled knowledge.
- **README — `repos/` in directory tree**: Directory structure now shows `repos/public/` and `repos/private/`.

### Changed
- **`.claude/CLAUDE.md`** — Knowledge Repos "Adding new knowledge" expanded from one-liner to step-by-step with commands for HQ-level and company-scoped knowledge.
- **`/setup`** — Phase 0 expanded (2 checks → 4), Phase 2 now includes knowledge repo creation + symlinks + `.gitignore` updates. Time estimate 2min → 5min.

---

## v5.1.0 (2026-02-08)

### Added
- **Context Diet** — New section in `.claude/CLAUDE.md` with lazy-loading rules to minimize context burn on session start. Sessions no longer pre-load INDEX.md or agents.md unless the task requires it.

### Changed
- **`.claude/CLAUDE.md`** — Added Context Diet section, updated Key Files to discourage eager loading
- **`/checkpoint`** — Recent threads now written to `workspace/threads/recent.md` (not embedded in INDEX.md). INDEX.md gets timestamp-only updates.
- **`/handoff`** — Same change: threads to `recent.md`, slim INDEX.md updates
- **`/reanchor`** — Added "When to Use" guidance: only run when explicitly called or disoriented, never auto-trigger
- Knowledge files refreshed: `Ralph/11-team-training-guide.md`, `hq-core/index-md-spec.md`, `hq-core/thread-schema.md`, `workers/README.md`, `workers/skill-schema.md`, `workers/state-machine.md`, `workers/templates/base-worker.yaml`, `projects/README.md`

---

## v5.0.0 (2026-02-07)

### Added
- **`/personal-interview`** — Deep conversational interview to build your profile and social voice. Populates `profile.md`, `voice-style.md`, and `agents.md` from ~18 thoughtful questions.
- **`workers/sample-worker/`** — Example worker with `worker.yaml` and `skills/example.md`. Copy and customize to build your own.

### Changed
- **`/setup`** — Simplified from 5 phases to 3. Now asks just name, work, and goals. Recommends `/personal-interview` for deeper profile building.
- **`.claude/CLAUDE.md`** — Updated structure (18 commands, sample-worker), added `/personal-interview` to commands table. Removed bundled worker listings.
- **`/execute-task`** — Added codebase exploration guidance (qmd collection search for workers), Linear sync integration for completed tasks
- **`/handoff`** — Added auto-commit of HQ changes before handoff (not just knowledge repos)
- **`/prd`** — Added target repo scanning via qmd collections during PRD creation
- **`/run-project`** — Added Linear sync integration (sets tasks to "In Progress" on execution start)
- **`/search`** — Added company auto-detection from context (cwd, active worker, recent files), enhanced collection scoping
- **`/search-reindex`** — Multi-collection architecture docs, instructions for adding new repo collections
- **`/cleanup`**, **`/reanchor`** — Genericized company INDEX paths
- `workers/registry.yaml` — Version 5.0, sample-worker only
- `knowledge/Ralph/11-team-training-guide.md` — Expanded with week-by-week team training insights
- `knowledge/hq-core/index-md-spec.md` — Genericized company references
- `knowledge/workers/README.md`, `skill-schema.md` — Updated examples
- `knowledge/projects/README.md` — Updated project examples

### Removed
- **All bundled workers** — `workers/dev-team/` (12 workers), `workers/content-*/` (5 workers), `workers/security-scanner/` removed. Build your own with `/newworker` using `sample-worker/` as reference.
- **`starter-projects/`** — Removed. Use `/prd` to create projects.

### Breaking
- Workers directory restructured: all pre-built workers removed. If you use dev-team or content workers, keep your existing copies.
- `/setup` no longer offers starter project selection. Use `/prd` + `/newworker` instead.

---

## v4.0.0 (2026-01-31)

### Added
- **`/learn`** — Automated learning pipeline: captures learnings from task execution/failure and injects rules directly into the files they govern (worker.yaml, command .md, knowledge files, or CLAUDE.md). Deduplicates via qmd, supports global promotion, event logging.
- **INDEX.md System** — Hierarchical INDEX.md files provide navigable maps of HQ. Auto-updated by `/checkpoint`, `/handoff`, `/reanchor`, `/prd`, `/run-project`, `/newworker`. Spec at `knowledge/hq-core/index-md-spec.md`
- **Knowledge Repos** — Knowledge folders can now be independent git repos, symlinked into HQ for versioning and sharing
- **Learning System** — Rules injected directly into source files (worker.yaml, commands, knowledge, CLAUDE.md). `/learn` + `/remember` pipeline with dedup, event logging, and global cap (20 rules)
- **Auto-Learn (Build Activities)** — `/newworker`, `/prd`, new knowledge/commands auto-register themselves via `/learn`
- **Search rules** — Formal policy: use qmd for HQ content search, never Grep/Glob for topic search
- `knowledge/Ralph/11-team-training-guide.md` — Team training guide for Ralph methodology
- `knowledge/hq-core/checkpoint-schema.json` — Checkpoint data format
- `knowledge/hq-core/index-md-spec.md` — INDEX.md specification

### Changed
- **`.claude/CLAUDE.md`** — Major rewrite: added INDEX.md System, Knowledge Repos, Learning System, Auto-Learn, Search rules sections. Command count 16 → 17
- **All 14 public commands refreshed** — `/checkpoint` (knowledge repo state), `/cleanup` (INDEX.md audit + knowledge repo checks), `/execute-task` (learnings integration, orchestrator output), `/handoff` (knowledge repo commits, INDEX.md regen), `/metrics`, `/newworker` (auto-learn + INDEX updates), `/prd` (auto-learn + INDEX updates), `/reanchor` (INDEX-based context loading), `/remember` (delegates to /learn), `/run-project` (fresh-context sub-agent pattern, auto-reanchor between tasks), `/run` (learnings loading), `/search-reindex`, `/search`
- `workers/registry.yaml` — Version 3.0 → 4.0, dev team count 13 → 12
- `knowledge/hq-core/thread-schema.md` — Added knowledge repo tracking
- `knowledge/workers/README.md`, `skill-schema.md`, `state-machine.md` — Updated
- `knowledge/projects/README.md` — Updated
- `workers/dev-team/code-reviewer/skills/review-pr.md` — Generalized E2E checks
- `workers/dev-team/frontend-dev/worker.yaml` — Generalized E2E requirements
- `workers/dev-team/qa-tester/worker.yaml` — Generalized E2E testing
- `workers/dev-team/task-executor/skills/validate-completion.md` — Added E2E manifest validation

### Removed
- `knowledge/pure-ralph/` — Removed (pure-ralph patterns merged into Ralph methodology core)

---

## v3.3.0 (2026-01-28)

### Added
- **Auto-Handoff** — Claude now auto-runs `/handoff` when context usage hits 70%, preserving session continuity without manual intervention
- `/setup` and `/exit-plan` now included in starter kit

### Changed
- **Command visibility overhaul** — 16 public commands (down from 29). Content, design, and company-specific commands moved to private
- All 16 public commands refreshed with latest improvements
- `.claude/CLAUDE.md` — Updated command tables, added Auto-Handoff section, count 29 → 16
- `workers/registry.yaml` — Paths updated to flat structure (`workers/` not `workers/public/`)
- Knowledge files PII-scrubbed

### Removed
- `/contentidea`, `/suggestposts`, `/scheduleposts`, `/preview-post`, `/post-now` — moved to private (content pipeline)
- `/humanize` — moved to private (content polish)
- `/generateimage`, `/svg`, `/style-american-industrial`, `/design-iterate` — moved to private (design tools)
- `/publish-kit`, `/pure-ralph` — moved to private
- `/hq-sync` — moved to private

---

## v3.2.0 (2026-01-28)

### Added
- **`/remember`** - Capture learnings when things don't work right. Injects rules directly into relevant files (worker.yaml, commands, CLAUDE.md, skills) instead of a separate database. Supports deduplication via qmd search and Ralph integration for auto-capture on back-pressure failures.
- `workers/registry.yaml` - Added `frontend-designer` and `qa-tester` standalone workers

### Changed
- All 28 existing public commands refreshed with latest improvements
- `.claude/CLAUDE.md` - Command count 28 → 29, added `/remember` to session management
- `workers/registry.yaml` - Version 2.0 → 3.0

---

## v3.1.0 (2026-01-28)

### Changed
- **`/prd`** - Merged `/newproject` into `/prd`. Single command now handles discovery, PRD generation (prd.json + README.md), orchestrator registration, beads sync, and execution choice
- **`/run-project`** - Strict prd.json validation: hard stop if missing, field validation on load, no README.md fallback
- **`/execute-task`** - Same strict prd.json validation as `/run-project`
- **`/newworker`** - Updated `/newproject` references to `/prd`
- **`/nexttask`** - Updated `/newproject` reference to `/prd`
- **`.claude/CLAUDE.md`** - Command count 29 → 28, removed `/newproject` from project commands

### Removed
- **`/newproject`** - Merged into `/prd`. Use `/prd` for all project planning

### Breaking
- `/newproject` no longer exists. Use `/prd` instead (same discovery flow + now outputs prd.json)
- `/run-project` and `/execute-task` require `prd.json` with `userStories` array (not `features`). Legacy PRDs must be migrated.

---

## v3.0.0 (2026-01-27)

### Added
- **`/humanize`** - Remove AI writing patterns from drafts
- **`/pure-ralph`** - External terminal orchestrator for autonomous PRD execution
- **`/svg`** - Generate minimalist abstract white line SVG graphics
- **`/search-reindex`** - Reindex and re-embed HQ for qmd search
- `knowledge/pure-ralph/` - Pure Ralph loop patterns, branch workflow, and learnings
- `knowledge/design-styles/ethereal-abstract.md` - Ethereal abstract style guide
- `knowledge/design-styles/liminal-portal.md` - Liminal portal style guide
- `knowledge/hq/checkpoint-schema.json` - Checkpoint data format
- `knowledge/projects/` - Project creation guidelines and templates

### Changed
- **`/search`** - Upgraded to qmd-powered semantic + full-text search (BM25, vector, hybrid modes)
- **`/handoff`** - Added search index update step (`qmd update && qmd embed`)
- **`/run-project`** - Updated orchestration pattern with inline worker pipeline execution
- **`/execute-task`** - Worker names aligned with actual dev-team worker IDs; added `content` task type
- **`.claude/CLAUDE.md`** - Updated command count (22 → 29), added Design section, qmd Search section, new knowledge refs

### Breaking
- `/search` syntax changed to qmd-based queries. Install [qmd](https://github.com/tobi/qmd) or use the built-in grep fallback.

---

## v2.1.0 (2026-01-26)

### Added
- **`/generateimage`** - Generate images via Gemini Nano Banana (gnb)
- **`/post-now`** - Post approved content to X or LinkedIn immediately
- **`/preview-post`** - Preview social drafts, select images, approve for posting
- **`/publish-kit`** - Sync HQ → hq-starter-kit with PII scrubbing

### Changed
- **`/contentidea`** - Enhanced multi-platform workflow with:
  - Image generation per approved style (7 styles)
  - Visual prompt patterns by theme
  - Anti-AI slop rules (humanizer)
  - Preview site sync
- **`/scheduleposts`** - Improved queue management and image generation workflow
- **`/style-american-industrial`** - Expanded monochrome variant with CSS variables
- **`/metrics`** - Updated example worker names
- **`/run`** - Updated example worker names
- **`/search`** - Updated example worker names
- **`/suggestposts`** - Generalized for any user

### Fixed
- Consistent PII scrubbing across all skills

---

## v2.0.0 (2026-01-25)

Major release: Project orchestration, content pipeline, and 18 production workers.

### Project Orchestration
- **`/run-project`** - Execute entire projects via Ralph loop
- **`/execute-task`** - Worker-coordinated task execution
- **`/prd`** - Enhanced PRD generation with HQ context awareness
- `workspace/orchestrator/` - Project state tracking
- `workspace/learnings/` - Captured insights from executions

### Content Pipeline
- **`/contentidea`** - Build raw idea into full content suite (one-liner → post → article)
- **`/suggestposts`** - Research-driven post suggestions aligned with goals
- **`/scheduleposts`** - Smart timing for posting based on content inventory
- `social-content/drafts/` - Platform-specific draft storage (x/, linkedin/)
- `workspace/content-ideas/inbox.jsonl` - Idea capture

### Dev Team (13 workers)
Complete development team for autonomous coding:
- `project-manager` - PRD lifecycle, issue selection
- `task-executor` - Analyze & route to workers
- `architect` - System design, API design
- `backend-dev` - API endpoints, business logic
- `frontend-dev` - React/Next components
- `database-dev` - Schema, migrations
- `qa-tester` - Testing, validation
- `motion-designer` - Animations, polish
- `infra-dev` - CI/CD, deployment
- `code-reviewer` - PR review, quality gates
- `knowledge-curator` - Update knowledge bases
- `product-planner` - Technical specs

### Content Team (5 workers)
Specialized content analysis workers:
- `content-brand` - Voice, messaging, tone
- `content-sales` - Conversion copy, CTAs
- `content-product` - Technical accuracy
- `content-legal` - Compliance, claims
- `content-shared` - Shared utilities (library)

### New Commands
- **`/search`** - Full-text search across threads, checkpoints, PRDs, workers
- **`/design-iterate`** - Design A/B testing with git branches
- **`/metrics`** - Worker execution metrics
- **`/cleanup`** - Audit and clean HQ
- **`/exit-plan`** - Force exit from plan mode

### Auto-Checkpoint
- Sessions auto-save to `workspace/threads/`
- Format: `T-{timestamp}-{slug}.json`
- Triggers: worker completion, git commit, file generation
- Never lose work to context limits

### Knowledge Bases
- `knowledge/hq-core/` - Thread schema, workspace patterns
- `knowledge/ai-security-framework/` - Security best practices
- `knowledge/design-styles/` - Design guidelines + swipes
- `knowledge/dev-team/` - Development patterns
- `knowledge/loom/` - Agent patterns reference
- Updated `knowledge/workers/` with templates

### Registry
- Upgraded to version 2.0 format
- Added team grouping
- Worker type taxonomy (CodeWorker, ContentWorker, SocialWorker, ResearchWorker, OpsWorker, Library)

---

## 2026-01-21

### PRD-First Planning
Added rules to redirect Claude's built-in planning to HQ's PRD system.

**Problem:** Claude Code triggers session-local plan mode for "complex" tasks. These plans live in `.claude/plans/`, are ephemeral, and compete with HQ's persistent PRD workflow.

**Solution:** Skills now redirect to `/newproject` when complex planning is needed. Plans belong in `prd.json` files that persist across sessions and integrate with `/ralph-loop`.

**Changes:**
- All skills: Redirect `EnterPlanMode` → suggest `/newproject` instead
- All skills: Redirect `TodoWrite` → PRD features track tasks

**Result:** Planning happens in the right place (PRD), not session-local files.
