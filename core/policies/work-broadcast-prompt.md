---
id: work-broadcast-prompt
title: Prompt to broadcast completed work
scope: command
trigger: "/land, /execute-task, /run-project, gh pr create"
when: pr
on: [AssistantIntent, PreToolUse]
enforcement: soft
public: true
version: 1
created: 2026-05-10
updated: 2026-05-27
---

## Rule

After any of the following events complete successfully, ask the user once:

> Want to share this with the team?

**Trigger events:**
- `/land` — PR merged or work landed
- `/execute-task` — story marked complete
- `/run-project` — all stories finished
- `gh pr create` — PR opened (only if the PR represents a shippable change, not a draft or WIP)

**Behavior:**
- Ask exactly once per completed unit of work
- If user says yes — invoke `/work-broadcast` with the current context
- If user says no or ignores — move on, no follow-up
- Never auto-send — the skill always confirms the draft message before sending
- Never prompt during intermediate steps (e.g. mid-project between stories)

## Rationale

Completed work has no value if the team doesn't know about it. A single low-friction prompt catches the moment when context is freshest and the announcement is easiest to compose. The skill handles audience routing, message composition, and optional marketing page generation — the user just says yes or no.
