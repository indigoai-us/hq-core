---
name: promote
description: Change an HQ company member's role with optional guest path scoping.
allowed-tools: Bash, Read
---

# Promote HQ Member

Codex adapter for `/promote`.

**Arguments:** `<person-slug-or-uid> <owner|admin|member|guest> [--paths <docs/,shared/>] [--company <slug>]`

## Source Of Truth

Read `.claude/commands/promote.md` first. That command owns role validation, auth resolution, company resolution, service call shape, and error wording.

## Codex Adaptation

- Execute the command workflow inline from the HQ root.
- Validate that `--paths` is only used with `guest`.
- Resolve the active company from the explicit flag or the HQ config; do not guess across companies.
- Use existing HQ CLI/package entry points when available.
- Stop on missing auth, insufficient permissions, missing member, or last-owner protection.

## Completion

End with the target member, company, previous role if known, new role, path scope when relevant, and when the change takes effect.
