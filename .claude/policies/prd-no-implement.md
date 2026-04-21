---
id: hq-prd-no-implement
title: "/plan NEVER implements — only creates PRD files"
scope: command
trigger: when /plan command is invoked
enforcement: hard
version: 1
created: 2026-02-22
updated: 2026-02-22
source: user-correction
---

## Rule

When `/plan` is invoked, the ONLY outputs are:
1. `projects/{name}/prd.json` — source of truth with user stories
2. `projects/{name}/README.md` — human-readable view
3. Orchestrator state.json registration
4. Company board.json registration

NEVER edit, modify, or create any files outside the `projects/{name}/` directory during a `/plan` session. The `/plan` command is a PLANNING tool, not an EXECUTION tool.

Even if plan mode approval is given, the plan MUST describe the PRD structure, NOT the direct edits to target files. Plan mode approval during `/plan` means "approved to generate the PRD files" — NOT "approved to implement the changes."

Implementation happens via `/execute-task` or `/run-project` AFTER the PRD is created.

