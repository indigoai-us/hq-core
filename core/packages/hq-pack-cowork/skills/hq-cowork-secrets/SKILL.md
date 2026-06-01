---
name: hq-cowork-secrets
description: Use HQ secrets from a sandboxed Claude Code plugin host (Cowork). The host-side MCP server never returns a secret value itself: `mcp__hq__hq_secrets_exec` runs a command on the host with named secrets injected as env vars (only the command's output returns), and refuses to launch a shell or value-printing binary; `mcp__hq__hq_secrets_list` lists secret NAMES/metadata only. These tools run host commands with the user's privileges, so treat them as host-trusted, not a cryptographic boundary. Same capability as `/hq-secrets`, routed through hq-pack-cowork's host-side MCP server. The value-revealing path is deliberately unavailable.
allowed-tools: mcp__hq__hq_secrets_exec, mcp__hq__hq_secrets_list
---

# /hq-cowork-secrets — Use HQ secrets from a sandboxed agent

Runs commands with HQ secrets injected, and lists secret names, from inside
Cowork — where the `hq` CLI and `~/.hq` vault are unreachable. Routes through
the host-side MCP server. **The server never returns a secret value itself,
and the secret-injecting tool refuses to run a shell or value-printing binary
— but these tools run host commands with your privileges, so treat them as
host-trusted, not an airtight boundary.**

**Args:** `$ARGUMENTS` — `list` (+ optional company/prefix) or `exec` (keys +
command). Infer from intent if not explicit.

## Two modes

### List names — `mcp__hq__hq_secrets_list`

Shows secret NAMES and path-based nested names. Values are never returned.

```json
{ "company": "<slug>", "personal": false, "prefix": "DEV" }
```

Omit `company` to use the active company; set `personal: true` for the
caller's personal vault; `prefix` filters by path segment.

### Run with secrets — `mcp__hq__hq_secrets_exec`

Injects named secrets as env vars of the same name into a child process and
returns only the command's stdout/stderr.

```json
{
  "keys": ["STRIPE_KEY", "DB_URL"],
  "cmd": ["./scripts/migrate.sh"],
  "company": "<slug>",
  "personal": false
}
```

`cmd` is argv (argv0 + args), NOT a shell string. The tool REFUSES to launch a
shell or a raw value-printing binary as `cmd[0]` (sh/bash/zsh, printenv, env,
echo, printf, cat, tee, node/python/perl/ruby, base64, xxd, strings, …) — this
is defense-in-depth so an injected one-liner can't echo an injected secret back
through the tool result. Invoke the actual consumer binary directly (e.g.
`vercel`, `aws`, `gh`, or a deploy script). This is not airtight: a custom
binary you control could still observe a secret it was given, so treat the tool
as host-trusted.

## Security rules (hard — from HQ core)

- **No value-revealing path exists by design.** `hq secrets get --reveal` is
  NOT wrapped. Do not attempt to capture a value by echoing the env var.
- **Cross-company isolation.** Pass `company` explicitly when crossing
  contexts. If the scoped secret is missing or the command fails on auth,
  STOP and ask — never retry against a different company's vault.
- **Never paste secrets inline.** Always consume via `hq_secrets_exec`
  injection; never ask the user to paste a value into chat.

## When to use this instead of `/hq-secrets`

Only inside Cowork or another sandboxed plugin host. On a host-side session,
prefer the unprefixed `/hq-secrets` (or `hq run` / `hq secrets exec`).

## Why this skill exists

`hq secrets exec` reads the encrypted vault under `~/.hq` with the user's
Cognito session — neither is visible from Cowork's Linux VM. The host-side
MCP server runs the real command on the host and returns only the child's
output. The server never returns a secret value itself, and refuses to run a
shell / value-printing binary — but it runs host commands with your privileges,
so it is host-trusted, not a cryptographic boundary.
