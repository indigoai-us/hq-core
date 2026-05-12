---
id: prd-verify-source-files
title: Never invent copy, URLs, or product details when drafting a PRD — read the source
scope: global
trigger: /plan, PRD drafting, acceptance criteria writing
enforcement: soft
public: true
version: 1
created: 2026-04-16
updated: 2026-04-16
source: user-correction
---

## Rule

When a PRD story references concrete product strings (button labels, URLs, route paths, success copy, env var names, API field names), open the actual source file and quote the live value before writing the acceptance criteria. Do not infer from plan-mode notes, prior conversation, or pattern-match from sibling projects. If the detail is ambiguous in the source, pause and ask the user rather than invent a plausible value.

Applies in both `/plan` interview and finalization phases, and to any AC that a worker would later treat as a literal contract.

## Rationale

User pushed back: "is there really a workspace link? follow what is in the hq-onboarding repo". Reading `provision-step.tsx:205` revealed the real CTA is `Download HQ Installer` — no workspace URL exists. A fabricated AC would have surfaced downstream as a swarm worker trying to implement a non-existent route, wasting a full story cycle. Reading the source file takes seconds; unwinding an invented spec takes hours.
