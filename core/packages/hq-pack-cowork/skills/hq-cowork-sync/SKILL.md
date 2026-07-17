---
name: hq-cowork-sync
description: Run bidirectional HQ Sync from Cowork.
allowed-tools: mcp__hq__hq_sync, mcp__hq__hq_whoami
---

# /hq-cowork-sync — Sync HQ from a sandboxed agent

Runs the same sync engine the HQ Desktop App uses, but from
inside a sandboxed Claude Code plugin host (Cowork, in particular). Walks
every cloud-backed company in your local HQ, syncs in both directions
against the vault, and writes conflict mirror files when divergence is
detected.

**Args:** `$ARGUMENTS` — optional flags. Accepted shapes (parse free-text):

- `--company <slug>` → scope to one company
- `--personal` → sync only the caller's personal vault
- `--on-conflict overwrite|keep|abort` → conflict strategy (default `keep`)
- `--message "<msg>"` → optional journal message attached to push leg

Without args, syncs every membership + personal vault with `--on-conflict keep`.

## When to use this instead of `/hq-sync`

- **You're in Cowork or another sandboxed plugin host.** The sandbox can't see
  `~/.hq/cognito-tokens.json` and `hq` isn't on PATH inside it, so the regular
  `/hq-sync` skill (which spawns `npx ... hq-sync-runner`) cannot run.
- **You want native MCP tool-call ergonomics** — observable in the host's tool
  log, not just shell output.

In a regular Claude Code session running on the host directly, prefer the
unprefixed `/hq-sync` skill — same engine, fewer hops.

## What you do

### Step 1 — Confirm the host MCP is wired

Before the first sync of a session, call `mcp__hq__hq_whoami`. If it returns
your identity + session expiry, the host MCP is live and authenticated. If
it errors with "not signed in" or "tokens expired", tell the user to run
`hq login` on the host machine (the sandboxed agent cannot do this itself
— `hq login` opens a browser on the host).

### Step 2 — Call the sync tool

Parse `$ARGUMENTS` into the `hq_sync` tool's input schema:

| Arg pattern | Tool input |
|---|---|
| `--company <slug>` | `{ "company": "<slug>" }` |
| `--personal` | `{ "personal": true }` |
| (neither) | `{}` — server defaults to `--all` |
| `--on-conflict <strategy>` | `{ "onConflict": "<strategy>" }` |
| `--message "<msg>"` | `{ "message": "<msg>" }` |

Call `mcp__hq__hq_sync` with the assembled input. Sync output can be chunky
(per-company push + pull legs) — surface a terse summary, not the full log,
unless the user asked for verbose detail.

### Step 3 — Report

Quiet by default. Surface:
- Companies synced (count + names)
- Conflicts written (count + the path to `<hqRoot>/.hq-conflicts/index.json`
  if any — the user can run `/resolve-conflicts` next)
- Errors from any individual company leg (don't swallow them)

If conflicts were written, mention `/resolve-conflicts` as the next step.

## Why this skill exists

The unprefixed `/hq-sync` skill resolves HQ root via four config tiers and
then `exec`s the cloud-runner binary directly with the host's Cognito
session. None of that works from Cowork's sandbox, where `~/.hq` is not
mounted and the host's Node binary isn't reachable. The
`hq-pack-cowork` MCP server fixes that by running on the host (with full
auth + binaries) and exposing `hq_sync` as a tool call the sandboxed agent
*can* make. This skill is the thin in-session adapter for that tool.
