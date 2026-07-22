---
type: reference
domain: [engineering, operations]
status: canonical
tags: [agents, session, providers, system-prompt, resume]
relates_to:
  - core/scripts/lib/provider-adapter.sh
  - core/scripts/lib/provider-adapter-claude.sh
  - core/scripts/lib/provider-adapter-codex.sh
  - core/scripts/lib/provider-adapter-grok.sh
  - core/scripts/lib/session-resume.sh
  - core/knowledge/public/hq-core/agent-session-contract.md
---

# Agent Session Provider Matrix

Records how each on-box provider CLI receives `system.txt` for the HQ Agent
Session entrypoint, and how (if at all) a prior native session id is resumed.
Later stories (behavioral canaries, ambient chime-in) read this file rather
than re-probing.

## System-prompt delivery

| Provider | Mechanism | systemPromptMode | CLI version probed | Determination command | Notes |
|----------|-----------|------------------|--------------------|-----------------------|-------|
| claude | CLI flag `--append-system-prompt <text>` | `native` | `2.1.198 (Claude Code)` | `claude --help` (lists `--append-system-prompt` and `--append-system-prompt-file`) | Also supports `--system-prompt`. Adapter uses append so default Claude Code framing is preserved. Does **not** use `-p`/`--print` (interactive / pty path per claude-runtime). Flags retained: `--settings`, `--dangerously-skip-permissions`, `--permission-mode bypassPermissions`. |
| codex | **none** | `prepended` | `codex-cli 0.144.6` | `codex exec --help` | No system-prompt flag, instructions-file flag, or config key for a per-turn system block appears in `codex exec --help`. Positional `[PROMPT]` is "initial instructions". Adapter **prepends** `system.txt` to the user payload with a blank-line separator and sets `systemPromptMode=prepended` so the fallback is never silent. Base argv: `codex exec --skip-git-repo-check --dangerously-bypass-hook-trust -- <prompt>` (parity with `resolveRunAgentInner`). |
| grok | CLI flag `--system-prompt-override <text>` (alias `--system-prompt`) | `native` | `grok 0.2.106` | `grok --help` | Also exposes `--rules` ("extra rules to append to the system prompt"). Adapter uses override for the full assembled system text. Retains fleet flags `--yolo` and `--no-auto-update` from user-data dispatch; user text via `-p` / single-turn. System text is **not** concatenated into the positional prompt. |

## Session resume (US-408)

| Provider | resumeSupported | Resume mechanism | CLI version probed | Determination command | Session-id source | Notes |
|----------|-----------------|------------------|--------------------|-----------------------|-------------------|-------|
| claude | `true` | CLI flag `--resume <sessionId>` (also `-r`) | `2.1.198 (Claude Code)` | `claude --help` | Basename (no `.jsonl`) of the path written into `HQ_AGENT_CLAUDE_TRANSCRIPT_PATH_FILE` after the turn (parity with `claude-transcript-reporter.ts`) | Adapter appends `--resume <id>` before the `--` separator when a resume record exists for the convKey. Rejected resume → fresh argv without `--resume` and `resumeFallback: true`. |
| codex | `true` | Subcommand `codex exec resume [OPTIONS] <SESSION_ID> [PROMPT]` | `codex-cli 0.144.6` | `codex exec resume --help` | Provider-native conversation/session UUID from a prior successful turn (recorded by the entrypoint when available) | Resume argv: `codex exec resume --skip-git-repo-check --dangerously-bypass-hook-trust <SESSION_ID> -- <prompt>`. System text still prepended into the prompt (mechanism remains `none` for system prompt). |
| grok | `true` | CLI flag `--resume [<SESSION_ID>]` (also `-r`) | `grok 0.2.106` | `grok --help` | Provider-native session id from a prior successful turn | Adapter appends `--resume <id>` when a resume record exists. Also exposes `--continue` for most-recent-in-cwd; HQ uses explicit id only. |

### Resume store

- Path: `$HOME/.hq/agent-session/resume/<sha256(convKey)>.json`
- Body: `{ "provider", "sessionId", "updatedAt" }` mode `600`
- TTL: `CONVERSATION_TTL_DAYS` = 30 (mirrors hq-pro `conversation-store.ts`)
- Cross-provider: a record whose `provider` differs from the current turn is
  **discarded** (file deleted) and no session id is returned
- Malformed / missing required fields → delete and treat as absent (never fatal)
- Provider with `resumeSupported: false` would omit resume flags and set
  `resumeSupported: false` on the envelope; continuity then relies on the
  request `rehydration` block only

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
5. Resume flags are only rendered when `HQ_AGENT_SESSION_RESUME_ID` is non-empty
   and the matrix marks `resumeSupported: true`. Never invent a resume flag for
   a provider whose matrix entry is `none` / `false`.
6. A provider-rejected resume must fall back to a fresh session in the same
   turn and stamp `resumeFallback: true` on the response envelope.

## Probe log (US-402)

- Date: 2026-07-21
- Host: developer workstation (macOS) with fleet-equivalent binaries on PATH
- `claude --help` → documents `--append-system-prompt`
- `codex exec --help` → no system-prompt mechanism found
- `grok --help` → documents `--system-prompt-override` / `--system-prompt`

## Probe log (US-408 resume)

- Date: 2026-07-22
- Host: developer workstation (macOS) with fleet-equivalent binaries on PATH
- `claude --help` → documents `-r, --resume [value]` (resume by session ID)
- `codex exec resume --help` → `codex exec resume [OPTIONS] [SESSION_ID] [PROMPT]`
- `grok --help` → documents `-r, --resume [<SESSION_ID>]`
- CLI versions: claude `2.1.198`, codex-cli `0.144.6`, grok `0.2.106`
