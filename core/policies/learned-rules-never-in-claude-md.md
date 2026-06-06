---
id: learned-rules-never-in-claude-md
title: Learned rules never go in CLAUDE.md — they live in policy files
scope: global
trigger: capturing a learned rule or user correction, or running /learn (especially /learn --hard)
when: learn || policies || charter
on: [PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]
enforcement: hard
public: true
vendor_public_ok: true
version: 1
created: 2026-06-01
updated: 2026-06-01
source: user-correction
tags: [hq-core, learn, policies, charter, claude-md]
---

## Rule

NEVER write a learned rule or user correction into `.claude/CLAUDE.md` (or its `AGENTS.md` symlink). The charter is release-shipped scaffold — replaced wholesale by `/update-hq` — and must not accumulate per-instance learnings. Every learned rule lives in a **policy file**:

- Personal / owner learnings → `personal/policies/{slug}.md` (reindex symlinks it into `core/policies/`, so it rides global scope and survives upgrades).
- Release-shipped, all-users learnings → `core/policies/{slug}.md` (promoted to hq-core via `hq-pack-admin`).

"Global promotion" of a critical or user-correction rule means **raising its enforcement to `hard` in its policy file**, not copying it into the charter — hard-enforcement policies already surface for every session through the policy trigger hook (`inject-policy-on-trigger.sh`), so the charter copy is redundant and harmful (it creates locked-scope drift and re-ships one instance's learnings to everyone).

This applies to `/learn` and `/learn --hard`, to manual edits, and to any tool or agent capturing a learning.

## Rationale

The charter is the locked, release-shipped contract every HQ install shares. Learned rules are per-instance, time-stamped, and accrete without bound — exactly the wrong content for a file that `/update-hq` replaces wholesale and that the Core Drift panel compares byte-for-byte against the release. Routing them to policy files keeps the charter stable, keeps personal learnings upgrade-safe under `personal/`, and lets genuinely-global rules ship deliberately through the promote pipeline instead of leaking in via a `/learn` side effect.

## Enforcement

- `/learn` (`.claude/skills/learn/SKILL.md`) has no CLAUDE.md-injection path — Step 6 "global promotion" raises enforcement in a policy file only.
- `protect-core.sh` rejects any Write/Edit to `CLAUDE.md` / `AGENTS.md` whose added content matches a learned-rule signature (`<!-- user-correction`, `<!-- back-pressure-failure`, or an insertion under a `## Learned Rules` heading), even under the `HQ_ALLOW_CORE_POLICY_WRITE` / `HQ_BYPASS_CORE_PROTECT` hatches. The wholesale `/update-hq` release path is unaffected.
