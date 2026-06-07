---
id: hq-core-never-recut-shipped-tag-for-docs
title: Never re-cut or rewrite a shipped hq-core tag just to add a CHANGELOG line
scope: global
trigger: discovering a missing CHANGELOG entry for an already-shipped hq-core version
when: changelog || /release-hq-core
on: [UserPromptSubmit]
enforcement: hard
public: true
vendor_public_ok: true
version: 1
created: 2026-05-28
updated: 2026-05-28
source: user-correction
applies_to: [github]
tags: [hq-core, promotion, release, changelog]
---

## Rule

NEVER: re-cut or rewrite a shipped hq-core tag just to add a CHANGELOG line. Record the version in the source CHANGELOG (core/docs/hq/CHANGELOG.md) so it flows on the next promotion; don't force a patch release for docs-only.

## Rationale

Once an hq-core tag is shipped, downstream consumers (kit installers, `/update-hq`, anyone pinning a specific version) may already have pulled it. Force-pushing a tag to add a CHANGELOG entry rewrites release history, breaks reproducibility, and risks corrupting any cache or mirror that resolved the old tag SHA. The cost of a docs-only patch release (extra promote PR, CI cycle, two-party review, downstream churn) is also wildly disproportionate to the value of an after-the-fact changelog edit.

The correct path when you notice a missing CHANGELOG line for a shipped version: update the source CHANGELOG at `core/docs/hq/CHANGELOG.md` in the HQ working tree (or in hq-core-staging via the normal promotion flow). The entry rides the next legitimate promotion into hq-core as part of its diff, and downstream readers see the historical entry alongside whatever new content shipped — no tag rewrite, no forced patch, no cache invalidation.

Reserve patch releases for substantive content changes (skill updates, policy updates, script fixes). Docs-only changelog backfill is not a release event.
