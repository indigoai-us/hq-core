---
id: hq-pack-policies-excluded-from-core-release
title: Pack policies/knowledge are excluded from the hq-core release — place default-tooling/optional concerns in the pack, not core/policies
scope: global
trigger: deciding where a default-tooling preference, optional capability, or stack-specific policy/knowledge should live (core vs. a pack)
enforcement: soft
public: true
version: 1
created: 2026-05-27
updated: 2026-05-27
source: session-learning
tags: [infrastructure, hq-core, hq-packages]
---

## Rule

ALWAYS: HQ pack policies/knowledge are deliberately EXCLUDED from the core release (hq-core). When deciding where a default-tooling preference or capability policy belongs, default-tooling/optional concerns go in the relevant pack (e.g. `hq-pack-engineering` in the `hq-packages` repo), NOT `core/policies` promoted to hq-core. Verify by checking whether existing peer policies (e.g. `e2e-testing-standards`) are absent from `repos/public/hq-core` but present in the pack's `package.yaml` `contributes`.

## Rationale

hq-core is the lean release-shipped scaffold; opt-in tooling concerns belong in their pack so hosts that don't install the pack don't inherit irrelevant guardrails. Peer policies that ship with a pack (rather than core) are the precedent — checking their `package.yaml` `contributes` and confirming absence from `repos/public/hq-core` is the fastest way to verify the correct home before authoring a new policy.
