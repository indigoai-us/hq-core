## Migrating to v15.0.10 -- generated migration summary

Generated from the release diff against `origin/main` so `/update-hq` has concrete migration data at the target tag.

### New Files

- `core/docs/hq/MIGRATION.md`
- `core/scripts/ensure-release-migration.sh`
- `core/scripts/tests/ensure-release-migration.test.sh`

### Updated Files

- `.github/workflows/auto-tag-release.yml`
- `.github/workflows/promote-to-hq-core.yml`
- `.github/workflows/release.yml`
- `core/core.yaml`
- `core/docs/hq/CHANGELOG.md`

### Removed

- None.

### Breaking Changes

- None declared automatically. Review hook, settings, and updater changes before merging if this release changes session startup or upgrade behavior.

### Migration Steps

1. Run `/update-hq` to apply this release.
2. Restart Claude Code or Codex after the update if this release changes `.claude/hooks/`, `.claude/settings.json`, `.codex/`, `.agents/`, or `core/scripts/`.
3. Review any local drift that `/update-hq` reports before continuing normal work.

## Migrating to v15.0.9 -- generated migration summary

Generated from the release diff against `v15.0.8` so `/update-hq` has concrete migration data at the target tag.

### New Files

- `.claude/hooks/reindex.sh`
- `core/scripts/derive-trigger-facts.sh`
- `core/scripts/eval-trigger.sh`
- `core/scripts/migrate-policy-triggers.sh`
- `core/scripts/tests/derive-trigger-facts.test.sh`
- `core/scripts/tests/eval-trigger.test.sh`
- `core/scripts/tests/eval-triggers-hooks.test.sh`
- `core/scripts/tests/inject-policy-e2e.test.sh`

### Updated Files

- `.claude/CLAUDE.md`
- `.claude/hooks/block-core-writes.sh`
- `.claude/hooks/check-hq-update.sh`
- `.claude/hooks/hook-gate.sh`
- `.claude/hooks/inject-policy-on-trigger.sh`
- `.claude/hooks/natural-language-router.sh`
- `.claude/hooks/protect-core.sh`
- `.claude/hooks/surface-company-infra-policy.sh`
- `.claude/settings.json`
- `.claude/skills/brainstorm/SKILL.md`
- `.claude/skills/handoff/SKILL.md`
- `.claude/skills/hq-heal/SKILL.md`
- `.claude/skills/hq-secrets/SKILL.md`
- `.claude/skills/import-claude/SKILL.md`
- `.claude/skills/knowledge-pulse/SKILL.md`
- `.claude/skills/learn/SKILL.md`
- `.claude/skills/newworker/SKILL.md`
- `.claude/skills/plan/SKILL.md`
- `.claude/skills/run/SKILL.md`
- `.claude/skills/setup/SKILL.md`
- `.claude/skills/startwork/SKILL.md`
- `.claude/skills/update-hq/SKILL.md`
- `.codex/hooks/hq-codex-hook-adapter.sh`
- `.github/workflows/audit.yml`
- `.github/workflows/auto-beta-release.yml`
- `.github/workflows/pr-checks.yml`
- `.github/workflows/promote-to-hq-core.yml`
- `.leak-scan/scan.sh`
- `core/core.yaml`
- `core/docs/hq/README.md`
- `core/docs/hq/USER-GUIDE.md`
- `core/knowledge/public/INDEX.md`
- `core/knowledge/public/hq-core/hq-desktop/knowledge-system-mapping.md`
- `core/knowledge/public/hq-core/hq-desktop/worker-system-mapping.md`
- `core/knowledge/public/hq-core/hq-structure-detection.md`
- `core/knowledge/public/hq-core/native-knowledge-stores.md`
- `core/knowledge/public/hq-core/obsidian-setup.md`
- `core/knowledge/public/hq-core/policies-spec.md`
- `core/knowledge/public/hq-core/quick-reference.md`
- `core/knowledge/public/hq-core/starter-kit-compatibility-contract.md`
- `core/knowledge/public/workers/README.md`
- `core/policies/ai-velocity-time-sense.md`
- `core/policies/always-pr-shared-state-repos.md`
- `core/policies/auto-deploy-on-create.md`
- `core/policies/bulk-sed-exception-ordering.md`
- `core/policies/chunked-reads-large-files.md`
- `core/policies/company-archive-cleanup.md`
- `core/policies/credential-access-protocol.md`
- `core/policies/decision-queue-one-at-a-time.md`
- `core/policies/deep-plan-skill-routing.md`
- `core/policies/distributed-join-partial-failure-diagnosis.md`
- `core/policies/env-file-no-trailing-newline.md`
- `core/policies/git-add-explicit-paths-no-drift.md`
- `core/policies/git-branch-verify.md`
- `core/policies/git-checkout-not-a-probe.md`
- `core/policies/git-stash-build-artifacts-conflict.md`
- `core/policies/glob-scoped-path.md`
- `core/policies/hook-macos-case-paths.md`
- `core/policies/hq-alert-baseline-calibration.md`
- `core/policies/hq-announce-before-irreversible.md`
- `core/policies/hq-audience-mode.md`
- `core/policies/hq-auth-middleware-whitelist-password-flow.md`
- `core/policies/hq-bash-discipline.md`
- `core/policies/hq-bash-non-subshell-cd-cwd-leak-cross-repo.md`
- `core/policies/hq-check-dirty-tree-before-repo-edit.md`
- `core/policies/hq-classifier-own-labels-single-source.md`
- `core/policies/hq-claude-code-default-mode-plan-not-auto.md`
- `core/policies/hq-claude-path-string-trips-block-core-writes-bash.md`
- `core/policies/hq-cluster-test-failures-by-root-cause.md`
- `core/policies/hq-codex-decision-gate-fallback.md`
- `core/policies/hq-codex-sdk-config-vs-typed-fields.md`
- `core/policies/hq-company-scoped-writes-verify-company.md`
- `core/policies/hq-compiled-ts-rebuild-after-src-edits.md`
- `core/policies/hq-confirm-creative-direction.md`
- `core/policies/hq-confirm-session-scope-after-plan-approval.md`
- `core/policies/hq-core-main-gated-by-ruleset-not-classic-protection.md`
- `core/policies/hq-core-never-recut-shipped-tag-for-docs.md`
- `core/policies/hq-core-vs-personal-skill-location-and-rename.md`
- `core/policies/hq-cross-repo-privilege-tier-surface-scope.md`
- `core/policies/hq-customizations-live-in-personal-or-company.md`
- `core/policies/hq-data-collection-isolation.md`
- `core/policies/hq-db-query-probe-real-table.md`
- `core/policies/hq-debug-multi-hop-exhaust-all-layers.md`
- `core/policies/hq-deploy-reinforcement.md`
- `core/policies/hq-destructive-scripts-default-dry-run.md`
- `core/policies/hq-detect-secrets-echo-escape-testing.md`
- `core/policies/hq-docker-build-platform-amd64.md`
- `core/policies/hq-docker-in-docker-path-translation.md`
- `core/policies/hq-eslint-allow-default-project-for-root-configs.md`
- `core/policies/hq-fix-root-cause-not-symptoms.md`
- `core/policies/hq-ggshield-recursive-for-dirs.md`
- `core/policies/hq-git-diff-three-dot-for-pr-review.md`
- `core/policies/hq-git-discipline.md`
- `core/policies/hq-git-divergence-check-both-directions.md`
- `core/policies/hq-git-large-diff-audit-before-panic.md`
- `core/policies/hq-git-merge-ff-only-trunk.md`
- `core/policies/hq-git-push-refspec-chip-safe.md`
- `core/policies/hq-github.md`
- `core/policies/hq-gitignore-before-first-commit.md`
- `core/policies/hq-handoff-changeset-scope.md`
- `core/policies/hq-hook-gate-three-profile-lists.md`
- `core/policies/hq-hook-json-build-with-jq-not-unquoted-heredoc.md`
- `core/policies/hq-html-target-blank-noopener.md`
- `core/policies/hq-jq-atomic-edits-large-json-configs.md`
- `core/policies/hq-linear.md`
- `core/policies/hq-load-company-hard-policies-on-mid-session-bind.md`
- `core/policies/hq-local-autocommit.md`
- `core/policies/hq-mcp-absolute-paths.md`
- `core/policies/hq-migration-bidirectional-grep-verify.md`
- `core/policies/hq-migration-independent-grep-verify.md`
- `core/policies/hq-migration-phase-boundary-regression-gate.md`
- `core/policies/hq-never-fabricate-research-artifacts.md`
- `core/policies/hq-never-swallow-errors.md`
- `core/policies/hq-no-diff-q-in-parallel-bash.md`
- `core/policies/hq-no-force-push-diverged-release-branch.md`
- `core/policies/hq-no-limits-means-kill-switch.md`
- `core/policies/hq-no-parent-import-from-child-component.md`
- `core/policies/hq-no-production-testing.md`
- `core/policies/hq-no-screencapture-self-verify-gui.md`
- `core/policies/hq-no-worktree-for-repo-work.md`
- `core/policies/hq-octokit-commit-vs-pr-phases-distinct.md`
- `core/policies/hq-orthogonal-filters-over-overlapping-presets.md`
- `core/policies/hq-pack-hooks-auto-discover-from-packages-dir.md`
- `core/policies/hq-pack-policies-excluded-from-core-release.md`
- `core/policies/hq-parallel-batch-block-cancels-writes.md`
- `core/policies/hq-permission-rules-literal-subcommand-prefixes.md`
- `core/policies/hq-permission-simple-expansion-extract-to-script.md`
- `core/policies/hq-permissions-fan-out-edit-write-multiedit.md`
- `core/policies/hq-pnpm-min-release-age-supply-chain.md`
- `core/policies/hq-policy-enforcement-claims-verify-wiring.md`
- `core/policies/hq-post-parallel-build-verify.md`
- `core/policies/hq-pr-single-concern.md`
- `core/policies/hq-pre-push-gate-probes-prod-not-localhost.md`
- `core/policies/hq-prefer-agent-browser.md`
- `core/policies/hq-pull-before-work.md`
- `core/policies/hq-qmd-first-for-hq-search.md`
- `core/policies/hq-redact-structural-plus-regex-pass.md`
- `core/policies/hq-rm-permission-allow-scope-paths.md`
- `core/policies/hq-rust-helper-extension-audit-call-sites.md`
- `core/policies/hq-rust-string-byte-slice-char-boundary-panic.md`
- `core/policies/hq-scanner-no-default-scopes-test-flag.md`
- `core/policies/hq-secure-link-render-as-markdown.md`
- `core/policies/hq-session-resume-git-status-reverify.md`
- `core/policies/hq-share-session-urls-are-capabilities.md`
- `core/policies/hq-skill-plugin-pattern.md`
- `core/policies/hq-slack.md`
- `core/policies/hq-static-regression-anchor-forbidden-pattern.md`
- `core/policies/hq-sub-agent-summary-verify-via-grep.md`
- `core/policies/hq-subagent-granularity-ambiguity.md`
- `core/policies/hq-supabase.md`
- `core/policies/hq-sync-codex-validation-and-conflict-resolution.md`
- `core/policies/hq-task-chip-worktree-isolation.md`
- `core/policies/hq-toolsearch-load-deferred-schemas.md`
- `core/policies/hq-user-specified-tool-unavailable.md`
- `core/policies/hq-validator-and-schema-paired-in-pr.md`
- `core/policies/hq-vendor-cutover-runbook-default.md`
- `core/policies/hq-vercel.md`
- `core/policies/hq-verify-git-after-compact.md`
- `core/policies/hq-verify-shared-files-after-parallel-agents.md`
- `core/policies/humanize-generated-content.md`
- `core/policies/image-context-isolation.md`
- `core/policies/journal-project-scoped-writes.md`
- `core/policies/learn-auto-no-confirmation.md`
- `core/policies/learned-rules-never-in-claude-md.md`
- `core/policies/mcp-process-cleanup.md`
- `core/policies/mcp-transport-detection.md`
- `core/policies/model-context-window.md`
- `core/policies/native-knowledge-first.md`
- `core/policies/native-session-project-capture.md`
- `core/policies/natural-language-mode.md`
- `core/policies/never-echo-tokens-stdout.md`
- `core/policies/no-grep-discovery.md`
- `core/policies/no-headless-browser-in-vercel-lambda.md`
- `core/policies/no-relative-symlinks-from-worktree.md`
- `core/policies/no-shared-skill-extraction-touching-5-files.md`
- `core/policies/post-edit-verification.md`
- `core/policies/prd-content-sources.md`
- `core/policies/prd-story-sizing.md`
- `core/policies/prd-validation.md`
- `core/policies/pre-deploy-domain-check.md`
- `core/policies/pre-refactor-hygiene.md`
- `core/policies/prefer-systemic-fix-over-user-bandaid.md`
- `core/policies/quiet-by-default-narration.md`
- `core/policies/ralph-orchestrator-context-discipline.md`
- `core/policies/regression-gate-lint-fix.md`
- `core/policies/rename-safety-checklist.md`
- `core/policies/reread-before-edit-long-sessions.md`
- `core/policies/reskin-separate-orchestration-from-visual.md`
- `core/policies/slack-broadcasts-follow-tier-discipline.md`
- `core/policies/subagent-fanout-budget.md`
- `core/policies/subagent-no-mcp.md`
- `core/policies/verify-routes-after-parallel-execution.md`
- `core/policies/work-broadcast-jq-inline-recipe-fails-bash-harness.md`
- `core/policies/work-broadcast-prompt.md`
- `core/scripts/codex-preflight.sh`
- `core/scripts/generate-workers-registry.sh`
- `core/scripts/hq-session.sh`
- `core/scripts/rebuild-threads-index.sh`
- `core/scripts/test-codex-hook-adapter.sh`
- `core/workers/public/INDEX.md`

### Removed

- `.claude/hooks/load-policies-for-session.sh`
- `.claude/hooks/master-sync.sh`
- `.claude/stack.yaml`
- `core/policies/_digest.md`
- `core/scripts/build-policy-digest.sh`

### Breaking Changes

- None declared automatically. Review hook, settings, and updater changes before merging if this release changes session startup or upgrade behavior.

### Migration Steps

1. Run `/update-hq` to apply this release.
2. Restart Claude Code or Codex after the update if this release changes `.claude/hooks/`, `.claude/settings.json`, `.codex/`, `.agents/`, or `core/scripts/`.
3. Review any local drift that `/update-hq` reports before continuing normal work.
