---
name: hq-cowork
description: Discover and dispatch HQ capabilities from a sandboxed Cowork plugin host.
allowed-tools: mcp__hq__hq_whoami, mcp__hq__hq_sync, mcp__hq__hq_team_sync, mcp__hq__hq_search, mcp__hq__hq_qmd, mcp__hq__hq_secrets_exec, mcp__hq__hq_secrets_list, mcp__hq__hq_share, mcp__hq__hq_files, mcp__hq__hq_members, mcp__hq__hq_groups, mcp__hq__hq_dm, mcp__hq__hq_packages, mcp__hq__hq_modules, mcp__hq__hq_meetings, mcp__hq__hq_sources, mcp__hq__hq_signals, mcp__hq__hq_feedback, mcp__hq__hq_run, mcp__hq__hq_cli
---

# /hq-cowork — Native HQ from a sandboxed agent

Cowork's bash runs in an isolated Linux VM that cannot see `~/.hq` (Cognito
auth) or reach the host's `hq` / `qmd` binaries. `hq-pack-cowork` ships a
host-side stdio MCP server that runs those binaries with full auth and
exposes them as `mcp__hq__*` tool calls. This skill is the map: it tells you
which tool covers which HQ capability and how to call it.

**Args:** `$ARGUMENTS` — optional. A capability keyword (e.g. `sync`,
`secrets`, `meetings`) jumps straight to that section's guidance. No arg =
print the full capability map below and ask what the user wants.

## Capability map

| Need | Tool | Notes |
|---|---|---|
| Confirm identity / session | `mcp__hq__hq_whoami` | email + session expiry. First call to sanity-check wiring. |
| Bidirectional sync | `mcp__hq__hq_sync` | `company` to scope, `personal: true` for personal vault, else all. |
| Pull team content | `mcp__hq__hq_team_sync` | one-way down-sync; `team` to scope, `dryRun` to preview. |
| Search HQ content | `mcp__hq__hq_search` | qmd hybrid. See `/hq-cowork-search`. |
| qmd read/list/ask/index | `mcp__hq__hq_qmd` | Same qmd-first workflow as default HQ sessions: collections/status/list/get/multi_get/search/ask/update. |
| Run cmd with a secret | `mcp__hq__hq_secrets_exec` | values injected as env, NEVER returned. See `/hq-cowork-secrets`. |
| List secret names | `mcp__hq__hq_secrets_list` | names/metadata only — no values. |
| Share a vault path | `mcp__hq__hq_share` | mint URL or grant ACL. See `/hq-cowork-share`. |
| Read vault objects | `mcp__hq__hq_files` | browse / cat / acl / search / shared-with-me / get. See `/hq-cowork-files`. |
| Memberships | `mcp__hq__hq_members` | list / invite / revoke. |
| Permission groups | `mcp__hq__hq_groups` | list / members / create / delete / add / remove. |
| DM a teammate | `mcp__hq__hq_dm` | HQ Desktop App notification. See `/hq-cowork-dm`. |
| HQ packages | `mcp__hq__hq_packages` | list / install / remove / update. |
| Knowledge modules | `mcp__hq__hq_modules` | list / add / sync / update. |
| Meetings | `mcp__hq__hq_meetings` | list / get / search / transcript / notes. See `/hq-cowork-meetings`. |
| Sources | `mcp__hq__hq_sources` | meeting/email/slack/linear/notion attached to an entity. |
| Signals | `mcp__hq__hq_signals` | action_item / commitment / decision / key_point / risk / summary. |
| File a bug / feature | `mcp__hq__hq_feedback` | `action: bug\|feature`, `title`, `body`. |
| Run with `.env.schema` secrets | `mcp__hq__hq_run` | validates cwd, injects env, returns child output only. |
| Long-tail HQ CLI | `mcp__hq__hq_cli` | guarded escape hatch for commands not yet wrapped. See `/hq-cowork-cli`. |

## Security envelope (carries over from HQ core policies)

- **Secret values never cross the MCP boundary.** `hq_secrets_exec` injects
  them into a child process env; `hq_secrets_list` shows names only. There is
  no value-revealing tool. Never try to echo a secret to capture its value.
- **Cross-company isolation.** Always pass `company` explicitly when crossing
  contexts. Never let the server fall back to another company's scope. If the
  scoped creds fail, stop and ask — don't retry against a different company.
- **Share-session URLs are single-use capabilities.** `hq_share` returns the
  minted URL once. Print it that turn, then redact as
  `https://hq.{co}.com/share-session/<TOKEN_REDACTED>` everywhere after.
- **Escape hatch stays guarded.** `hq_cli` blocks login/logout/onboard,
  secret-value output, raw `hq secrets set|exec`, and `hq run` (use
  `hq_run` instead).

## When to use this instead of the unprefixed skills

Use the `hq-cowork-*` family (and direct `mcp__hq__*` calls) **only** inside
Cowork or another sandboxed plugin host. On a normal host-side Claude Code
session prefer the unprefixed `/hq-sync`, `/hq-share`, `/search`,
`/hq-secrets`, `/dm`, etc. — fewer hops, same result.

## What you do

1. If `$ARGUMENTS` names a capability, skip to that tool and call it with the
   user's parameters. If ambiguous or empty, show the capability map and ask.
2. Prefer the dedicated `hq-cowork-*` skill when one exists (search, share,
   secrets, files, dm, meetings) — it carries the per-capability nuance.
3. Always start a fresh wiring with `mcp__hq__hq_whoami` if a tool errors with
   an auth/ENOENT message — that confirms whether the host server is logged in
   and has `hq`/`qmd` on PATH.
