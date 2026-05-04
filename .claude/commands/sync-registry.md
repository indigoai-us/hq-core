---
description: Regenerate a company's resource-registry index (registry.yaml) from its resources/*.yaml files
allowed-tools: Bash, Read
argument-hint: "[company-slug]"
visibility: public
public: true
---

# /sync-registry

Read `.claude/skills/sync-registry/SKILL.md` and execute that workflow.

Use `$ARGUMENTS` as the optional company slug (resolved from cwd / handoff if omitted).
