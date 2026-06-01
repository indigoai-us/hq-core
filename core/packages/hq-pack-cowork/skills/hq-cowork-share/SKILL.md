---
name: hq-cowork-share
description: Share an HQ vault path from a sandboxed Claude Code plugin host (Cowork) by calling the host-side `hq_share` MCP tool. Without `--with`, mints an encrypted single-use share-session URL (default 15-min expiry). With `--with`, grants direct ACL access to a person, group, or `@all`. Same capability as `/hq-share`, routed through hq-pack-cowork's MCP server so it works from a sandboxed agent.
allowed-tools: mcp__hq__hq_share
---

# /hq-cowork-share — Share an HQ vault path from a sandboxed agent

Mints share-session URLs and grants ACLs on HQ vault paths from inside
Cowork (or any sandboxed Claude Code plugin host). Equivalent to the
unprefixed `/hq-share` skill, but routed through the host-side MCP server
because the sandboxed agent cannot run the `hq` CLI directly.

**Args:** `$ARGUMENTS` — required path + optional flags.

| Arg | Meaning |
|---|---|
| `<path>` (positional) | Vault path or prefix to share (e.g. `companies/foo/knowledge/x.md`). Required. |
| `--with <principal>` | Email, group id, or `@all`. Omit to mint a share-session URL instead. |
| `--permission read\|write` | Permission level (only meaningful with `--with`). |
| `--expires 15m\|1h\|24h` | Token expiry for share-session URL (default 15m, max 24h). |

## When to use this instead of `/hq-share`

- **You're in Cowork or another sandboxed plugin host** — the regular
  `/hq-share` skill shells out to `hq files share` on the host, which isn't
  reachable from the sandbox.
- **You want the MCP tool-call surface** — observable in the host's tool log.

On a normal host-side Claude Code session, prefer the unprefixed `/hq-share`.

## What you do

### Step 1 — Parse args

Extract the positional `<path>` and any optional flags. Without a path,
ask the user which vault prefix to share.

### Step 2 — Call the tool

Call `mcp__hq__hq_share` with:

```json
{
  "path": "<path>",
  "with": "<principal>",          // omit if not set
  "permission": "read|write",     // omit if not set
  "expires": "15m|1h|24h"         // omit to use default 15m
}
```

### Step 3 — Surface output

The minting turn is the ONE surface where the unredacted share-session URL
is permitted in chat. Print it as a clickable markdown link so the user can
copy it.

**Hard rule (carried over from `core/policies/hq-share-session-urls-are-capabilities.md`):**
After this turn, NEVER paste the URL back into later turns, summaries,
journals, handoffs, commits, PRs, Slack/email, or any persisted context.
Refer to it as `https://hq.{co}.com/share-session/<TOKEN_REDACTED>` from
then on. The token IS a capability — anyone who holds it can use the share.

If `--with` was used (direct grant, not URL), there's no token to print —
just confirm the grant landed and surface any error from the tool.

## Why this skill exists

`hq files share` runs on the host with the user's Cognito session and the
local sync index — neither of which is visible from inside Cowork's Linux
VM. The host-side MCP server in `hq-pack-cowork` runs the real `hq files
share`, then returns its output back to the sandboxed agent. This skill is
the in-session adapter.
