---
id: hq-permissions-fan-out-edit-write-multiedit
title: Fan out permission patterns across Edit, Write, and MultiEdit
scope: global
trigger: When adding entries to `permissions.allow` or `permissions.deny` in any `.claude/settings.json` or `.claude/settings.local.json`
enforcement: hard
public: true
version: 1
created: 2026-04-17
updated: 2026-04-17
source: user-correction
---

## Rule

Claude Code evaluates `(tool, pattern)` tuples independently. An entry like `Edit(workspace/threads/**)` authorizes Edit only — it does NOT authorize Write or MultiEdit against the same pattern. When pre-approving a path, always emit the pattern three times (once per edit tool) so every write path the assistant might take is covered.

```
Edit(<pattern>)
Write(<pattern>)
MultiEdit(<pattern>)
```

If you only add `Edit(...)`, a session that uses Write for the first touch of a file still fires a permission prompt — silently undoing the intent of the allowlist.

