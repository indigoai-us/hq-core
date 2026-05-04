---
id: hq-validator-and-schema-paired-in-pr
title: Ship Validator + Schema + Data In The Same PR
scope: global
trigger: when introducing a validator script that gates a migration of many sibling files
enforcement: soft
public: true
version: 1
created: 2026-04-26
updated: 2026-04-26
source: session-learning
---

## Rule

When introducing a validator script that gates a migration across many sibling files (worker manifests, PRD blocks, schema-conformant configs), the PR that adds the validator MUST also include:

1. The schema definition the validator enforces
2. The first wave of data being validated (or the bulk migration itself)
3. CI wiring (or an explicit one-shot invocation in the PR description) that runs the validator against the migrated diff

Do not land the validator alone "to add coverage for next time." A validator added later only catches *future* drift — it does not retroactively gate the migration that has already shipped, and individual errors in the migrated data will have escaped review at the diff level.

## Rationale

A validator's value comes from gating diffs, not from existing in the repo. If `validate-X.sh` lands in PR N and the bulk migration lands in PR N+1, every error in the migration data has to be caught manually before merge — the validator only earns its keep on the *N+2* drift. Bundling the validator + schema + first wave guarantees the validator earns its keep on day one and catches the long tail of typos that LLM-drafted bulk edits inevitably introduce.

The inverse failure (validator-less bulk migration) is even worse: a 70+ file change with no schema gate ships on reviewer eyes alone, and the first agent run that hits a malformed entry surfaces the error as a runtime crash instead of a CI failure.
