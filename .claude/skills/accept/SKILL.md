---
name: accept
description: Accept a vault-backed HQ membership invite from a magic link or raw token.
allowed-tools: Bash, Read
---

# Accept HQ Invite

Codex adapter for `/accept`.

**Arguments:** `<token-or-magic-link>`

## Source Of Truth

Read `.claude/commands/accept.md` first. That command owns the invite-token parsing, auth expectations, service call shape, errors, and output format. This skill exists so Codex can discover and execute the same HQ capability without duplicating the workflow.

## Codex Adaptation

- Execute the command workflow inline from the HQ root with the user's token or magic link.
- Use existing HQ CLI/package entry points when available; do not hand-roll service calls if a local command already wraps them.
- Treat Claude Code specific tool names as intent, then use the equivalent Codex workflow available in the current session.
- If auth is missing or expired, stop and direct the user to `/hq-login`; do not try alternate company credentials.
- Preserve the source command's success and error wording where practical.

## Completion

End with the invite result, company slug, role, and the next sync command when acceptance succeeds. If blocked, state the precise missing prerequisite.
