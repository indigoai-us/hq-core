---
name: hq-cowork-files
description: Read and inspect HQ vault objects from a sandboxed Claude Code plugin host (Cowork) without a full sync, via the host-side `mcp__hq__hq_files` tool. Actions — browse (list), cat (read one object), acl (show access list), search (match object keys), shared-with-me (grants to you), get (materialize into local HQ). Same capability as `/hq-files`, routed through hq-pack-cowork's MCP server.
allowed-tools: mcp__hq__hq_files
---

# /hq-cowork-files — Inspect HQ vault objects from a sandboxed agent

Reads vault objects on demand from inside Cowork, where the `hq` CLI and the
local sync index aren't reachable. Routes through the host-side MCP server.

**Args:** `$ARGUMENTS` — an action plus its target. Infer the action from
intent if not explicit.

| Action | Purpose | Needs |
|---|---|---|
| `browse` | List objects under a vault path | `path` optional (defaults to root) |
| `cat` | Stream one object to text | `path` required |
| `acl` | Show the access-control list for a prefix | `path` required |
| `search` | Match vault object keys by path/name (NOT content) | `query` (or `path`) required |
| `shared-with-me` | List grants made to you | — |
| `get` | Materialize a file/prefix into local HQ on the host | `path` required; `into` optional |

## Call the tool

```json
{
  "action": "cat",
  "path": "companies/foo/knowledge/x.md",
  "company": "<slug>",     // omit to parse from path
  "personal": false,
  "into": "<dir>"          // action=get only
}
```

Call `mcp__hq__hq_files`. For `search`, pass the query as `query` (or `path`).

## Notes

- **`search` matches keys, not content.** It's a path/name match over vault
  object keys — not full-text search. For content search use `/hq-cowork-search`
  (qmd), which is a different index.
- **`get` writes to the host's local HQ**, not into the sandbox. The
  sandboxed agent won't see the materialized files unless the mounted HQ
  folder is shared. Prefer `cat` to read content directly into the session.
- **Cross-company isolation.** `company` defaults to the slug parsed from the
  path; pass it explicitly when that's ambiguous. Never operate across a
  company boundary you weren't asked to.

## When to use this instead of `/hq-files`

Only inside Cowork or another sandboxed plugin host. On a host-side session,
prefer the unprefixed `/hq-files` (or `hq files`).

## Why this skill exists

`hq files` authenticates with the user's Cognito session under `~/.hq` and
reads the cloud vault — neither is visible from Cowork's Linux VM. The
host-side MCP server runs the real `hq files <action>` and returns output to
the sandboxed agent.
