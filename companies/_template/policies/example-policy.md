---
id: {company}-example-policy
title: Example Policy Title
scope: company
trigger: before any task execution
enforcement: soft
version: 1
created: 2026-01-01
updated: 2026-01-01
# applies_to: [vercel, clerk]   # optional — tag only if policy is wrong/useless without the service; omit for cross-cutting
---

## Rule

State the rule clearly in imperative form. One rule per policy is ideal. If multiple rules are needed, use a numbered list.

1. Always do X before starting work
2. Never do Y without confirmation
3. After completing work, do Z

## Rationale

Explain why this policy exists. What problem does it prevent? What outcome does it ensure? This helps agents understand the intent, not just the letter of the rule.

## Examples

**Correct:**
- Agent checks the docs site after completing a feature and updates the relevant page

**Incorrect:**
- Agent completes a feature without updating documentation
