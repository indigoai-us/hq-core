---
name: hq-cowork-cli
description: Use long-tail HQ CLI functionality from Cowork via the host-side guarded `mcp__hq__hq_cli` tool and schema-driven `mcp__hq__hq_run` tool. Covers HQ commands not yet modeled as dedicated MCP tools while blocking browser/session flows and secret-value output.
allowed-tools: mcp__hq__hq_cli, mcp__hq__hq_run, mcp__hq__hq_whoami
---

# /hq-cowork-cli — Long-tail HQ from Cowork

Use this when Cowork needs an HQ capability that does not have a dedicated
`hq-cowork-*` skill yet.

Prefer dedicated tools first:

- Search: `/hq-cowork-search`
- Sync: `/hq-cowork-sync`
- Files/share: `/hq-cowork-files`, `/hq-cowork-share`
- Secrets: `/hq-cowork-secrets`
- Meetings/sources/signals: `/hq-cowork-meetings`

## `mcp__hq__hq_cli`

Runs `hq <args...>` on the host. Pass argv, not a shell string.

```json
{
  "args": ["sync", "status"],
  "cwd": ".",
  "timeoutMs": 60000
}
```

The tool blocks:

- `hq login`, `hq logout`, `hq onboard`
- browser/session auth flows other than `hq auth status` and `hq auth refresh`
- secret-value output (`hq secrets env`, `hq secrets get --reveal`)
- raw `hq secrets set|exec` and `hq run` through the escape hatch

Use `mcp__hq__hq_run` for `hq run`.

## `mcp__hq__hq_run`

Runs schema-driven commands with HQ secrets injected via `.env.schema`.
Secret values stay in the child process env; only command output returns.

```json
{
  "cwd": "repos/private/example-app",
  "company": "indigo",
  "schema": ".env.schema",
  "cmd": ["npm", "test"],
  "timeoutMs": 120000
}
```

For validation only:

```json
{
  "cwd": "repos/private/example-app",
  "check": true
}
```

## Rules

- Never ask the user to paste secrets inline.
- Never use the escape hatch for secret-value retrieval.
- Keep `cwd` inside the HQ root. The MCP server enforces this.
- For destructive or cloud-provisioning commands, explain the concrete effect before calling the tool.
