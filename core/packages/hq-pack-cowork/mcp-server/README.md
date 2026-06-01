# hq-cowork-mcp

Host-launched stdio MCP server that wraps the `hq` CLI and `qmd` so a
sandboxed agent (Cowork, or any Claude Code plugin host whose bash runs in an
isolated VM) can use HQ as native tool calls.

## Why this exists

Cowork's bash runs in an isolated Linux VM. From inside that sandbox:

- `~/.hq/cognito-tokens.json` (auth) is not visible.
- The `hq` binary is not on PATH and isn't installed.
- Only the mounted HQ folder is reachable — nothing else on the host.

So every HQ capability that is "run the `hq` CLI on the host with real auth"
— `hq sync`, `hq files share`, `hq secrets exec`, `qmd` search — structurally
cannot run from inside the sandbox.

This MCP server runs on the **host**, holds the Cognito session, and shells
out to the real `hq` / `qmd` binaries. The agent only sees command output
(or sanitized error text); tokens never cross the sandbox boundary.

## Tools

20 tools. Grouped tools take an `action` discriminator that maps to the
matching `hq` subcommand.

### Identity / sync / search

| Tool name | Wraps | Notes |
|---|---|---|
| `hq_whoami` | `hq whoami` | Identity + session expiry check. |
| `hq_sync` | `hq sync now` | Bidirectional sync. Defaults to `--all` (every membership + personal); `company` / `personal` to scope. |
| `hq_team_sync` | `hq team-sync` | One-way down-sync of joined-team content. `team` to scope, `dryRun` to preview. |
| `hq_search` | `qmd query` | Hybrid full-text + semantic search (expansion + RRF + rerank). |
| `hq_qmd` | `qmd ...` | qmd-first HQ search/read workflow: collections, status, ls, get, multi-get, search, vsearch, query, ask, update. |

### Secrets (values never returned)

| Tool name | Wraps | Notes |
|---|---|---|
| `hq_secrets_exec` | `hq secrets exec --only` | Runs a command with named secrets injected as env vars. Values never returned. |
| `hq_secrets_list` | `hq secrets list` | Lists secret NAMES / metadata only. No values. |

### Vault files

| Tool name | Wraps | Notes |
|---|---|---|
| `hq_share` | `hq files share` | Without `with`, mints a single-use share-session URL (printed inline). With `with`, grants direct ACL. Browser auto-open is suppressed. |
| `hq_files` | `hq files <action>` | `action`: browse / cat / acl / search / shared-with-me / get. |

### Team & membership

| Tool name | Wraps | Notes |
|---|---|---|
| `hq_members` | `hq members <action>` | `action`: list / invite / revoke. |
| `hq_groups` | `hq groups <action>` | `action`: list / members / create / delete / add / remove. |
| `hq_dm` | `hq dm` | Send a DM (menubar notification). Optional `prompt` / `details` / scheduled `at` / `in`. |

### Packages & modules

| Tool name | Wraps | Notes |
|---|---|---|
| `hq_packages` | `hq packages` / `hq install` / `hq remove` | `action`: list / install / remove / update. |
| `hq_modules` | `hq modules <action>` | `action`: list / add / sync / update. |

### Meeting intelligence (read-only)

| Tool name | Wraps | Notes |
|---|---|---|
| `hq_meetings` | `hq meetings <action>` | `action`: list / get / search / transcript / notes. |
| `hq_sources` | `hq sources <action>` | `action`: list / get / channels / entities. Channels: meeting/email/slack/linear/notion. |
| `hq_signals` | `hq signals <action>` | `action`: list / get / types / entities. Types: action_item/commitment/decision/key_point/risk/summary. |

### Feedback

| Tool name | Wraps | Notes |
|---|---|---|
| `hq_feedback` | `hq feedback <action>` | `action`: bug / feature. `title` + `body` (body piped via `--body-file -`). |

### Schema-driven runs and long-tail HQ CLI

| Tool name | Wraps | Notes |
|---|---|---|
| `hq_run` | `hq run` | Resolve `.env.schema`, inject HQ secrets into a host child process, and return only command output. |
| `hq_cli` | `hq <args...>` | Guarded escape hatch for commands not yet modeled as dedicated tools. Blocks browser/session flows and secret-value output. |

## Prerequisites (on the host)

- Node.js 18+
- `hq` CLI on PATH — `npm i -g @indigoai-us/hq-cli`
- `qmd` CLI on PATH — `cargo install qmd`
- A logged-in HQ session — `hq login`

## Install

```bash
cd <path-to-pack>/mcp-server
npm install
```

The server is launched by Claude Code via the sibling `.mcp.json` manifest:

```json
{
  "mcpServers": {
    "hq": {
      "command": "node",
      "args": ["${CLAUDE_PLUGIN_ROOT}/mcp-server/index.mjs"]
    }
  }
}
```

`${CLAUDE_PLUGIN_ROOT}` resolves to the installed plugin directory; the host
launches `node index.mjs` as a stdio transport child process.

## HQ root resolution

The server resolves the HQ root (where `core/core.yaml` lives) in this order:

1. `$HQ_ROOT` env var (override)
2. `~/.hq/menubar.json` `hqPath` (canonical, hq-installer ≥ 0.1.28)
3. `~/.hq/config.json` `hqFolderPath` (legacy)
4. Discovery — first of `~/Documents/HQ`, `~/Documents/hq`, `~/HQ`, `~/hq`,
   `~/Desktop/HQ`, `~/Desktop/hq` that contains `core/core.yaml`
5. `~/Documents/HQ` (last-resort default)

This matches the resolver used by `hq-sync` and the AppBar menubar app.

## Security notes

- Tokens (`~/.hq/cognito-tokens.json`) stay on the host. The MCP server never
  reads them — `hq` does.
- `hq_secrets_exec` injects secret values into the child process's env, not
  into the returned content. The model sees the command's output; it does
  not see the secret values.
- `hq_share` defaults to `--no-open` (suppresses browser launch) when minting
  a share-session URL, since the host-launched browser is meaningless to a
  sandboxed agent.
- Share-session URLs ARE capabilities. After the minting turn that prints
  them, treat them as redacted (`<TOKEN_REDACTED>`) in any persisted
  context — same rule as the `/hq-share` skill enforces.
- The value-revealing secrets path (`hq secrets get --reveal`) is
  deliberately NOT wrapped. `hq_cli` also blocks `hq secrets env`,
  `hq secrets get --reveal`, and raw `hq secrets set|exec`.
- Cross-company isolation: every tool passes `company` through verbatim when
  supplied and never falls back to another company's scope. Callers crossing
  contexts must pass `company` explicitly.
- Host-only browser flows (`hq login` / `logout` / `auth` / `onboard`) are
  intentionally not wrapped — `hq_whoami` covers session status. Auth is
  managed on the host with `hq login`.
  `hq_cli` only permits `hq auth status` and `hq auth refresh`.

## Testing

Syntax check:

```bash
node --check index.mjs
```

Smoke test (requires `hq` + `qmd` on PATH and a logged-in HQ session):

```bash
node index.mjs   # then send MCP protocol messages over stdio
```

End-to-end: register the plugin in Cowork and call `hq_whoami` from a
session — your email + session expiry should come back.
