---
type: reference
domain: [engineering, operations]
status: canonical
tags: [agents, session, providers, system-prompt]
relates_to:
  - core/scripts/lib/provider-adapter.sh
  - core/scripts/lib/provider-adapter-claude.sh
  - core/scripts/lib/provider-adapter-codex.sh
  - core/scripts/lib/provider-adapter-grok.sh
  - core/knowledge/public/hq-core/agent-session-contract.md
---

# Agent Session Provider Matrix

Records how each on-box provider CLI receives `system.txt` for the HQ Agent
Session entrypoint. Later stories (resume, behavioral canaries) read this
file rather than re-probing.

| Provider | Mechanism | systemPromptMode | CLI version probed | Determination command | Notes |
|----------|-----------|------------------|--------------------|-----------------------|-------|
| claude | CLI flag `--append-system-prompt <text>` | `native` | `2.1.198 (Claude Code)` | `claude --help` (lists `--append-system-prompt` and `--append-system-prompt-file`) | Also supports `--system-prompt`. Adapter uses append so default Claude Code framing is preserved. Does **not** use `-p`/`--print` (interactive / pty path per claude-runtime). Flags retained: `--settings`, `--dangerously-skip-permissions`, `--permission-mode bypassPermissions`. |
| codex | **none** | `prepended` | `codex-cli 0.144.6` | `codex exec --help` | No system-prompt flag, instructions-file flag, or config key for a per-turn system block appears in `codex exec --help`. Positional `[PROMPT]` is "initial instructions". Adapter **prepends** `system.txt` to the user payload with a blank-line separator and sets `systemPromptMode=prepended` so the fallback is never silent. Base argv: `codex exec --skip-git-repo-check --dangerously-bypass-hook-trust -- <prompt>` (parity with `resolveRunAgentInner`). |
| grok | CLI flag `--system-prompt-override <text>` (alias `--system-prompt`) | `native` | `grok 0.2.106` | `grok --help` | Also exposes `--rules` ("extra rules to append to the system prompt"). Adapter uses override for the full assembled system text. Retains fleet flags `--yolo` and `--no-auto-update` from user-data dispatch; user text via `-p` / single-turn. System text is **not** concatenated into the positional prompt. |

## Rules

1. An adapter whose matrix mechanism is a real flag/config must set
   `systemPromptMode` to `"native"` and must not place system text in the
   positional user prompt.
2. An adapter whose mechanism is `none` must prepend and set
   `systemPromptMode` to `"prepended"`. Omitting the field is forbidden.
3. Behavioral canary (optional in CI): embed `HQ-SYSPROMPT-CANARY-<runId>` in
   `system.txt` and ask the model to echo any canary it can see. If a claimed
   native mechanism fails the canary, escalate — do not silently downgrade.
4. When re-probing a new CLI major version, update the version column and the
   determination command output date in the PR that changes the adapter.

## Probe log (US-402)

- Date: 2026-07-21
- Host: developer workstation (macOS) with fleet-equivalent binaries on PATH
- `claude --help` → documents `--append-system-prompt`
- `codex exec --help` → no system-prompt mechanism found
- `grok --help` → documents `--system-prompt-override` / `--system-prompt`
