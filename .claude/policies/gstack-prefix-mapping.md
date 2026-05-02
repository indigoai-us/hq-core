---
id: gstack-prefix-mapping
title: gstack cross-skill reference remapping
scope: global
trigger: executing any /g-* skill (gstack plugin)
enforcement: soft
version: 1
created: 2026-03-23
updated: 2026-03-23
public: true
---

## Rule

gstack skills are installed with a `g-` prefix. Their SKILL.md prose references sibling
skills without the prefix (e.g. "run /review", "run /retro"). When executing any `/g-*`
skill, interpret bare slash command references to gstack skills as their `g-` prefixed
equivalents.

Colliding names and their correct mapping:

| gstack says | Use instead |
|-------------|-------------|
| /review | /g-review |
| /retro | /g-retro |
| /investigate | /g-investigate |
| /document-release | /g-document-release |
| /qa | /g-qa |
| /ship | /g-ship |
| /autoplan | /g-autoplan |
| /freeze | /g-freeze |
| /unfreeze | /g-unfreeze |
| /guard | /g-guard |
| /careful | /g-careful |
| /canary | /g-canary |
| /codex | /g-codex |
| /plan-* | /g-plan-* |

HQ's own `/review`, `/retro`, `/investigate`, and `/document-release` remain unaffected
when invoked directly by the user or by HQ workers.

## Rationale

gstack was authored as a standalone skill set before the `g-` prefix was applied. Internal
cross-references use unprefixed names. Without remapping, `/g-ship` would invoke HQ's
`/review` instead of gstack's `/g-review` — wrong skill, different behavior.
