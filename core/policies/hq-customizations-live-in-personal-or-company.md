---
id: hq-customizations-live-in-personal-or-company
title: Customizations live in personal/ or companies/{co}/ — never edit core/ to personalize
when: policy || worker || skill || knowledge
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
public: true
version: 2
created: 2026-05-29
updated: 2026-07-24
source: user-correction
---

## Rule

The `core/` tree (and the release-shipped parts of `.claude/`, `.codex/`, `.agents/`) is **release-shipped scaffold and is replaced wholesale by `/update-hq`**. Any personalization or customization written directly into `core/` is silently overwritten or deleted on the next upgrade. Therefore, never edit `core/` to personalize or customize HQ. Route customizations by scope:

- **Personal customizations** (operator-only policies, knowledge, workers, skills, hooks, settings) go in `personal/{policies,knowledge,workers,skills,hooks,settings}/<entry>`. `personal/{policies,knowledge,workers,settings}` are read **directly** from `personal/` by the code that consumes each — the policy trigger hook, the workers-registry generator, and the session/knowledge/settings readers — so the customization surfaces just as it would from `core/` but survives `/update-hq`. (The old `core/<type>/` symlink mirror for these four was retired; reindex now prunes any leftover mirror symlinks. Personal skills are surfaced via the `.claude/skills/personal:<name>/` bridge, and personal hooks load as their own ordered layer — neither is affected.)
- **Company customizations** (tenant-specific policies, knowledge, workers, projects) go in `companies/{co}/{policies,knowledge,workers,projects}/<entry>`. These are the company's own, isolated, and — for cloud-backed HQ-Pro companies — synced to that tenant's vault.
- **Repo customizations** go in `repos/{repo}/.claude/policies/` (and the repo's own docs/knowledge).

Changes to the **shipped core scaffold itself** — i.e. content that genuinely should ship to every HQ install — are not made by hand-editing local `core/` either. They go through the staging → promotion pipeline: edit, then publish via the hq-core staging repo and `/promote-hq-core` (see `staging-promotion-required` and `hq-core-public-no-direct-pr`).

When in doubt about whether a learning, policy, or artifact is personal, company-specific, or genuinely core, **ask** rather than defaulting into `core/`.

## Rationale

`/update-hq` performs a wholesale replace of the release-shipped trees: whatever file ships in the upstream hq-core release is copied into the install as-is, replacing whatever sat at that path. Operator- or company-specific content placed in `core/` is therefore lost without warning at the next upgrade. The `personal/` overlay exists precisely so that operator content loads at runtime (read directly from `personal/`, not mirrored into `core/`) while living in an upgrade-safe location. Company content lives under `companies/{co}/` so it stays isolated per tenant and syncs to the correct vault.

This rule generalizes the older, skills-only `hq-core-vs-personal-skill-location-and-rename` (soft) to every overlay type — policies, knowledge, workers, hooks, and settings — and is the authoritative statement of where customizations belong. It is surfaced to every command via the SessionStart policy trigger hook (`inject-policy-on-trigger.sh`) and reinforced at edit time by an advisory reminder in the same hook. The existing `core/`-edit protection (`HQ_BYPASS_CORE_PROTECT`) remains the broad mechanical guard; this policy supplies the positive routing — *where the customization should go instead*. For the most common leak — `/learn` (or a hand-edit) creating a new policy in `core/policies/` — `protect-core.sh` adds a narrow, always-on block on creating a new `.md` under `core/policies/` (independent of the broad bypass, since that bypass is often left on; override with `HQ_ALLOW_CORE_POLICY_WRITE=1`). `/learn` itself now routes operator-global and command-scoped rules to `personal/policies/` by default.

## See also

- `core/policies/hq-core-vs-personal-skill-location-and-rename.md` (soft, skills-only precursor)
- `personal/policies/hq-update-hq-wholesale-replace-overwrites-operator-files.md` (the wholesale-replace hazard)
- `core/policies/hq-company-scoped-writes-verify-company.md` (sibling rule: company-scoped writes must reach the correct company)
- `core/knowledge/public/hq-core/quick-reference.md` (personal overlay semantics table)
- `.claude/skills/learn/SKILL.md` (routing: global/command → `personal/policies/`; never `core/policies/`)
- `.claude/hooks/protect-core.sh` (the targeted always-on guard against new `core/policies/` files)
- `core/knowledge/public/hq-core/policies-spec.md` (scope/precedence + personal-overlay default)
