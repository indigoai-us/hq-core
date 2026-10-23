---
id: hq-unenforced-core-policy-is-a-defect
title: A core policy with no wired control is a defect, not a rule
when: policy || enforcement || hook
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
tier: 1
version: 1
created: 2026-10-12
updated: 2026-10-12
source: user-correction
learned_from: image-context-isolation count cap with no PreToolUse guard
public: true
tags: [infrastructure, safety, knowledge]
---

## Rule

A release-shipped `core/policies/` rule that claims a control — a cap, a deny, a "must" — and has no wired hook (or equivalent mechanical check) is a defect. File it. Do not treat prompt text as enforcement.

Before shipping or trusting a core policy as a control:

1. Name the hook (or other check) that actually stops the violation.
2. Confirm it is registered in `.claude/hooks/hook-registry.json` and listed in all three `hook-gate.sh` profiles (`hq-hook-gate-three-profile-lists`).
3. Confirm a regression test drives a known-bad payload through the gate and gets a deny.
4. If there is no hook, say so in the policy (`enforcement: soft`, advisory only) and do not write "hard rule" / "never" language that nothing can stop.

Related: `hq-policy-enforcement-claims-verify-wiring` (do not claim wiring you did not check). A guardrail that lives only in the prompt is not a guardrail.

## Rationale
A policy only a well-behaved agent can violate is not a control. Unenforced core policies are their own defect class: they suppress the instinct to add a real hook.
