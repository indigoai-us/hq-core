---
name: hq-cowork-meetings
description: Read HQ meeting notes and extracted signals from Cowork.
allowed-tools: mcp__hq__hq_meetings, mcp__hq__hq_sources, mcp__hq__hq_signals
---

# /hq-cowork-meetings — Read meeting intelligence from a sandboxed agent

Reads recorded meetings, their source material, and extracted signals from
inside Cowork, where the `hq` CLI is unreachable. Routes through the
host-side MCP server. All three tools are read-only.

**Args:** `$ARGUMENTS` — what to read (a meeting, a transcript, action items,
etc.). Pick the right tool below from intent.

## Meetings — `mcp__hq__hq_meetings`

| Action | Purpose | Needs |
|---|---|---|
| `list` | Recorded meetings, newest first | `limit` optional (default 20) |
| `get` | Details for one meeting | `meetingId` |
| `search` | Match by title / participant | `query` |
| `transcript` | Full transcript | `meetingId` |
| `notes` | AI-generated notes | `meetingId` |

```json
{ "action": "notes", "meetingId": "<id>", "company": "<slug>", "json": false }
```

## Sources — `mcp__hq__hq_sources`

Source material (meeting / email / slack / linear / notion) attached to a
vault entity.

| Action | Purpose | Needs |
|---|---|---|
| `channels` | Enumerate canonical channels | — |
| `entities` | Entities you can access | — |
| `list` | Sources for an entity, by channel | `entity` optional, `type` optional |
| `get` | One source by id | `id` (+ `entity`/`type`) |

## Signals — `mcp__hq__hq_signals`

Extracted signals for a vault entity.

| Action | Purpose | Needs |
|---|---|---|
| `types` | Enumerate canonical signal types | — |
| `entities` | Entities you can access | — |
| `list` | Signals for an entity, by type | `entity` optional, `type` optional |
| `get` | One signal by id | `id` (+ `entity`/`type`) |

Signal types: `action_item`, `commitment`, `decision`, `key_point`, `risk`,
`summary`.

## Notes

- **`entity` defaults to the active company.** Pass it explicitly for a
  multi-company user, and respect cross-company isolation.
- **`json: true`** (meetings) / `json: true` (sources/signals) returns raw
  JSON for programmatic use; omit for human-readable tables.

## When to use this instead of host-side calls

Only inside Cowork or another sandboxed plugin host. On a host-side session,
call `hq meetings` / `hq sources` / `hq signals` directly.

## Why this skill exists

These commands authenticate with the user's Cognito session under `~/.hq`
and read the cloud vault — neither is visible from Cowork's Linux VM. The
host-side MCP server runs the real commands and returns output to the
sandboxed agent.
