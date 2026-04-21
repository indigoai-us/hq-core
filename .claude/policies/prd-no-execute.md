---
id: prd-no-execute
title: PRD sessions must not execute
scope: command
trigger: /prd
enforcement: hard
version: 1
created: 2026-02-22
updated: 2026-02-22
source: user-correction
command: prd
---

## Rule

1. After `/prd` creates project files (`prd.json` + `README.md`), run `/handoff` and end the session
2. NEVER start executing stories, running workers, editing target repo files, or writing implementation code in the same session as `/prd`
3. No exceptions — regardless of project size, story count, or user request to "just start"
4. If user asks to execute immediately, explain: "Execution requires a fresh session for context isolation (Ralph pattern). Run `/run-project {name}` or `/execute-task {name}/US-001` in a new session"

## Examples

**Correct:**
- `/prd` creates files → shows confirmation → runs `/handoff` → session ends
- User says "can you just do it now?" → agent explains Ralph pattern → runs `/handoff`

**Incorrect:**
- `/prd` creates files → agent starts editing repo files in the same session
- `/prd` creates a 1-story PRD → agent says "since it's simple, let me just do it"
- `/prd` creates files → agent runs `/execute-task` or `/run-project` in the same session
