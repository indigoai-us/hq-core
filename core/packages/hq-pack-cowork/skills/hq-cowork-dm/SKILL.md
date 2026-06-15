---
name: hq-cowork-dm
description: Send HQ Sync direct messages from Cowork through the host-side DM tool.
allowed-tools: mcp__hq__hq_dm
---

# /hq-cowork-dm — DM a teammate from a sandboxed agent

Sends person-to-person HQ DMs from inside Cowork, where the `hq` CLI is
unreachable. Routes through the host-side MCP server. The recipient gets it
as an HQ Sync menubar notification.

**Args:** `$ARGUMENTS` — recipient + message, plus optional flags.

| Arg | Meaning |
|---|---|
| `<recipient>` | Email address or personUid of the teammate. Required. |
| `<message>` | The message body. Required. |
| `--prompt <text>` | Agent-context prompt the recipient can one-click copy into their agent. |
| `--details <text>` | Longer detail shown in the recipient's DM detail window. |
| `--at <ISO8601>` | Schedule delivery at an absolute time (store-and-forward). |
| `--in <delay>` | Schedule after a relative delay: `30s`, `10m`, `2h`, `1d`. |

## Humanize before send

Before calling the tool, run the channel-aware humanize pass on the `message`
(and any `prompt` / `details` text) per
`core/knowledge/public/hq-core/humanize-before-send.md` — channel `cowork-dm`,
default intensity `light`: strip the obvious AI tells while keeping the message
terse and conversational. Never rewrite the recipient or scheduling fields.

## Call the tool

```json
{
  "recipient": "<email-or-personUid>",
  "message": "<body>",
  "prompt": "<optional agent prompt>",
  "details": "<optional detail body>",
  "in": "30m"
}
```

Call `mcp__hq__hq_dm`. Use `at` OR `in`, not both.

## Notes

- **Reach is scoped to shared companies.** You can only DM people you share
  an active company with. A delivery failure usually means no shared company.
- **DM yourself** for a note-to-self / reminder (use your own email).
- **Receive-only in the app** — the menubar app shows incoming DMs; sending
  happens from a session or the CLI (this tool).

## When to use this instead of `/dm`

Only inside Cowork or another sandboxed plugin host. On a host-side session,
prefer the unprefixed `/dm` (or `hq dm`).

## Why this skill exists

`hq dm` authenticates with the user's Cognito session under `~/.hq`, which
isn't visible from Cowork's Linux VM. The host-side MCP server runs the real
`hq dm` and returns its confirmation back to the sandboxed agent.
