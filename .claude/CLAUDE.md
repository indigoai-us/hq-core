# HQ Claude Charter

HQ is a team AI operating system: a shared context and capability layer over
Claude Code, Cursor, and Codex. You operate the orchestration layer that
scaffolds, supervises, and syncs work across repos and companies.

## Start Here

- Use HQ skills/commands for HQ-native work. Do not hand-roll raw AWS, GitHub,
  SCP, ACL, sync, deploy, invite, or secret flows when HQ has a command.
- For repo coding, go straight to the target repo. Load HQ docs or company
  context only when the task needs it.
- Keep company context isolated. Cross-company knowledge or credential use is a
  category-1 bug.
- Convert vague work into observable done criteria before executing.

## Preferred HQ Paths

- Share results: `/deploy` for artifacts or `/hq-share <path>...` for vault
  paths.
- Vault access: `/hq-files`.
- Secrets: `/hq-secrets`, `hq run`, or `hq secrets exec`; never paste secrets.
- Sync: `/hq-sync`.
- Company setup and membership: `/onboard`, `/accept`, `/designate-team`,
  `/promote`.
- Provision teammates and agents: `/new-hire` for people, `/new-agent` for
  fleet agents (identity → membership → vault → grants → verified probe).
- Direct messages and reminders: `/dm` or `hq dm`.
- Identity: `/hq-login`, `/hq-logout`, `/hq-whoami`.
- Bugs and feature requests: `/hq-bug`.
- Search: `/search` or `qmd`.
- Meetings, signals, and company context: `/meeting-notes`, `/signals`,
  `/ontology`.
- Specialized design, content, security, data, and deploy work: check
  `core/workers/registry.yaml` and use `/run {worker} {skill}`.

## Non-Negotiables

- Tenant boundaries: resolve the active company, read its policies, and use only
  its configured services, profiles, DNS zones, and credentials.
- Sensitive paths: do not read deny-listed rc, SSH, AWS, GPG, env, netrc, or
  shell profile files. Mutate rc files only by append or pattern delete.
- Tests: never skip, loosen, or fake tests. Bug fixes need regression coverage.
- E2E: deployable product work is incomplete until the user-facing path is
  verified.
- User corrections: apply factual corrections exactly, or quote back and ask.
- Decisions: use structured one-question-at-a-time prompts when available.
- Images: keep parent sessions under 10 images; delegate image inspection.
- Checkpoints: obey injected checkpoint and precompact requirements immediately.
- Learnings: route reusable rules through `/learn`, not inline charter edits.
- Customizations: put local changes in `personal/` or company scope, not `core/`
  unless they are intended for release.

## Communication

Default to quiet, plain-language status. Surface only completion, blockers,
human decisions, irreversible actions, security signals, and at most one
milestone per major phase. Technical operators can opt into fuller narration
with `/output-style hq-operator`.

## Git Discipline

- Every git or gh mutation must include an explicit repo anchor in the same
  command, such as `git -C /abs/path ...` or `gh ... -R owner/repo`.
- Never push the HQ root. HQ is local-only; use `/hq-sync` for cross-machine
  state.
- Only repos under `repos/` get pushed. Verify branch before committing, and do
  not commit to local `main` when work belongs on a feature branch.
- Local HQ non-repo edits autosave silently; do not ask users to manage them.

## Layout

- `companies/`: isolated tenants with their own knowledge, policies, settings,
  projects, workers, and registries. Source of truth: `companies/manifest.yaml`.
- `repos/`: code only, split into `repos/public/` and `repos/private/`.
- `personal/`: user overlay for policies, knowledge, skills, hooks, settings,
  projects, and workers. Not release-shipped.
- `core/`: release-shipped HQ scaffold. Replaced wholesale by `/update-hq`.
- `workspace/`: session, orchestration, locks, drafts, reports, and worktrees.

## Load On Demand

- Directory map: `core/docs/hq/INDEX.md`.
- User guide: `core/docs/hq/USER-GUIDE.md`.
- Owner and company routing: `personal/agents-profile.md`,
  `personal/agents-companies.md`.
- Quick reference: `core/knowledge/public/hq-core/quick-reference.md`.
- Policies: `core/policies/`, repo `.claude/policies/`, and
  `companies/{co}/policies/`.
- Knowledge-store details:
  `core/knowledge/public/hq-core/native-knowledge-stores.md`.
