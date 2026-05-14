---
name: onboard
description: Run the HQ company onboarding flow for creating or joining a company.
allowed-tools: Bash, Read
---

# HQ Onboarding

Codex adapter for `/onboard`.

**Arguments:** `[create|join|resume] [flags]`

## Source Of Truth

Read `.claude/commands/onboard.md` first. That command owns the create/join/resume modes, prompts, service calls, progress output, and completion format.

## Codex Adaptation

- Execute the command workflow inline from the HQ root.
- Ask for missing onboarding inputs one at a time unless the user already supplied them.
- Use existing HQ onboarding package or CLI entry points when available.
- Validate company slug and invite token shape before attempting remote calls.
- Keep company isolation strict: never reuse credentials from another company as a fallback.

## Completion

End with the created or joined company slug, role, important ids, and next sync/invite action. If blocked, state the missing auth, token, or package prerequisite.
