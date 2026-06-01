# hq-pack-cowork

Native HQ inside Cowork (and any Claude Code plugin host whose bash runs in a
sandbox).

This pack is one directory wearing two hats:

1. **HQ pack** (`package.yaml`) — installs via `hq install` like any other
   `hq-pack-*`, drops the `hq-cowork*` skills into `.claude/skills/`
   (`/hq-cowork`, `/hq-cowork-install`, `/hq-cowork-sync`,
   `/hq-cowork-share`, `/hq-cowork-search`, `/hq-cowork-secrets`, `/hq-cowork-dm`,
   `/hq-cowork-files`, `/hq-cowork-meetings`, `/hq-cowork-cli`) via
   `core/scripts/scan-packages.sh`.
2. **Claude Code plugin** (`.claude-plugin/plugin.json` + `.mcp.json`) — when
   installed as a plugin in Cowork or any Claude Code instance, registers a
   host-launched stdio MCP server that wraps the real `hq` CLI + `qmd` and
   exposes them as tool calls.

The MCP server is the keystone. Cowork's bash runs in an isolated Linux VM
that cannot see `~/.hq/cognito-tokens.json` (auth) and cannot reach the
host's `hq` or `qmd` binaries. Every HQ capability that is "run the `hq`
CLI on the host with real auth" — sync, share, secrets-exec, qmd search —
structurally cannot run from the sandbox. The MCP server fixes that by
running on the host (full auth + binaries) and exposing those capabilities
as MCP tool calls the sandboxed agent *can* make.

## What's in the box

```
hq-pack-cowork/
  package.yaml                  # HQ pack manifest
  .claude-plugin/plugin.json    # Claude Code / Cowork plugin manifest
  .claude-plugin/marketplace.json # local Claude marketplace entry
  .mcp.json                     # registers the host-side MCP server
  mcp-server/
    package.json                # @indigoai-us/hq-cowork-mcp
    index.mjs                   # stdio MCP server (Node 18+)
    README.md
  scripts/
    build-plugin.sh             # creates a bundled .plugin upload artifact
    install-cowork-plugin.sh    # checks prereqs, builds/installs plugin
  skills/
    hq-cowork/SKILL.md          # → /hq-cowork (discovery + dispatch)
    hq-cowork-install/SKILL.md  # → /hq-cowork-install
    hq-cowork-sync/SKILL.md     # → /hq-cowork-sync
    hq-cowork-share/SKILL.md    # → /hq-cowork-share
    hq-cowork-search/SKILL.md   # → /hq-cowork-search
    hq-cowork-secrets/SKILL.md  # → /hq-cowork-secrets
    hq-cowork-dm/SKILL.md       # → /hq-cowork-dm
    hq-cowork-files/SKILL.md    # → /hq-cowork-files
    hq-cowork-meetings/SKILL.md # → /hq-cowork-meetings
    hq-cowork-cli/SKILL.md      # → /hq-cowork-cli
  README.md                     # this file
```

## MCP tools exposed

20 tools. Grouped tools take an `action` discriminator mapping to the matching
`hq` subcommand.

| Tool | Wraps | Purpose |
|---|---|---|
| `hq_whoami` | `hq whoami` | Identity + session expiry check. |
| `hq_sync` | `hq sync now` | Bidirectional sync. Defaults to all memberships + personal. |
| `hq_team_sync` | `hq team-sync` | One-way down-sync of joined-team content. |
| `hq_search` | `qmd query` | Hybrid full-text + semantic search across HQ content. |
| `hq_qmd` | `qmd collection/list/get/multi-get/search/vsearch/query/ask/update` | Default qmd-first HQ search/read workflow through host transport. |
| `hq_secrets_exec` | `hq secrets exec --only` | Inject named secrets as env vars and run a command. Values never returned. |
| `hq_secrets_list` | `hq secrets list` | List secret NAMES / metadata only. |
| `hq_share` | `hq files share` | Mint share-session URL or grant direct ACL. |
| `hq_files` | `hq files <action>` | browse / cat / acl / search / shared-with-me / get. |
| `hq_members` | `hq members <action>` | list / invite / revoke memberships. |
| `hq_groups` | `hq groups <action>` | list / members / create / delete / add / remove. |
| `hq_dm` | `hq dm` | Send a direct message (menubar notification). |
| `hq_packages` | `hq packages` / `install` / `remove` | list / install / remove / update packages. |
| `hq_modules` | `hq modules <action>` | list / add / sync / update knowledge modules. |
| `hq_meetings` | `hq meetings <action>` | list / get / search / transcript / notes. |
| `hq_sources` | `hq sources <action>` | list / get / channels / entities. |
| `hq_signals` | `hq signals <action>` | list / get / types / entities. |
| `hq_feedback` | `hq feedback <action>` | File a bug report or feature request. |
| `hq_run` | `hq run` | Resolve `.env.schema`, inject secrets, and run host commands. |
| `hq_cli` | `hq <args...>` | Guarded escape hatch for long-tail HQ CLI capabilities. |

See [`mcp-server/README.md`](mcp-server/README.md) for input schemas and
security notes.

## Host prerequisites

The MCP server runs on the host machine, not in the sandbox. The host needs:

- Node.js 18+
- `hq` CLI on PATH — `npm i -g @indigoai-us/hq-cli`
- `qmd` CLI on PATH — `cargo install qmd`
- A logged-in HQ session — `hq login` (one-time, opens a browser)

The sandboxed agent (Cowork) doesn't need any of those — it just needs to be
able to invoke MCP tools, which the plugin host (Claude Code) wires up
automatically once the plugin is registered.

## Install — as an HQ pack

From any HQ instance:

```bash
hq install https://github.com/indigoai-us/hq-pack-cowork.git
# or, once published to npm:
hq install @indigoai-us/hq-pack-cowork
```

`scan-packages.sh` symlinks the pack skills into `.claude/skills/` so they
surface as `/hq-cowork`, `/hq-cowork-install`, `/hq-cowork-sync`,
`/hq-cowork-share`, `/hq-cowork-search`, and the rest of the `hq-cowork-*`
helpers in any Claude Code session on that HQ.

> Note: `scan-packages.sh` does NOT wire the MCP server — HQ packs don't yet
> have a first-class `mcp` contribution key. The MCP half is wired by the
> plugin host (see below) and points at the installed pack via
> `${CLAUDE_PLUGIN_ROOT}`.

## Install — as a Claude Code plugin (for Cowork)

This is the path that actually lets a sandboxed agent use HQ. Five ways:

### Option A — HQ Sync app

Open the HQ Sync menubar app and click:

```text
Install Cowork plugin
```

The app runs the same installer as this pack, registers the local `hq`
marketplace, installs/enables `hq-cowork@hq`, writes the Cowork upload artifact
to `~/.hq/plugins/hq-pack-cowork.plugin`, and imports that artifact into
Cowork's local Personal plugins store. Start a new Cowork task after installing
so the new plugin tools and skills are loaded.

### Option B — HQ-native helper

From the HQ root after installing this pack:

```bash
core/packages/hq-pack-cowork/scripts/install-cowork-plugin.sh --install
```

or from Claude Code inside HQ:

```text
/hq-cowork-install
```

The helper checks host prerequisites, builds `~/Downloads/hq-pack-cowork.plugin`,
registers the local `hq` Claude marketplace, installs/enables
`hq-cowork@hq`, and prints the Cowork upload + smoke-test steps. Without
`--install`, it only builds the upload artifact and prints manual Cowork steps.

### Option C — build a `.plugin` file directly

Build the upload artifact:

```bash
core/packages/hq-pack-cowork/scripts/build-plugin.sh
```

By default this writes:

```
~/Downloads/hq-pack-cowork.plugin
```

Upload that file in Cowork's plugin UI. The artifact bundles
`mcp-server/index.mjs` into a standalone Node file and intentionally excludes
`node_modules`, so it avoids Cowork's zip path restrictions around pnpm's
virtual-store directory names.

For local Claude Code CLI smoke tests, use a `.zip` suffix:

```bash
core/packages/hq-pack-cowork/scripts/build-plugin.sh /tmp/hq-pack-cowork.zip
claude --plugin-dir /tmp/hq-pack-cowork.zip
```

Claude Code's `--plugin-dir` archive loader checks for `.zip`; Cowork's upload
UI accepts the `.plugin` suffix.

### Option D — local plugin directory

Point Claude Code's plugin loader at the installed pack directory:

```
~/Documents/HQ/core/packages/hq-pack-cowork/
```

Claude Code reads `.claude-plugin/plugin.json` + `.mcp.json` from there and
launches `node mcp-server/index.mjs` as a stdio child process on every
session that has the plugin enabled. For this install mode, run
`npm install` inside `mcp-server/` first so the SDK dependency exists.

### Option E — Cowork plugin directory

Drop or symlink the pack into Cowork's plugin search path (see Cowork's
own docs for the exact location). Cowork loads the same manifests and
launches the same MCP server. Because the MCP server runs on the host
(not in Cowork's sandbox), it can authenticate and shell out to the real
binaries.

After install, restart the Claude Code / Cowork session and confirm with:

```
/hq-cowork-search "anything"
```

or directly via the tool:

```
mcp__hq__hq_whoami
```

## Why "Cowork" in the name

Cowork is the immediate target — its sandbox is the reason this pack
needed to exist. But the same plugin works for any Claude Code instance
where it's preferable to access HQ via MCP tool calls instead of inline
shell invocations of `hq` (e.g. remote agents, web-based Claude Code
instances, multi-tenant deployments).

## Open questions / future work

- **Publish the MCP server to npm** (`@indigoai-us/hq-cowork-mcp`) and point
  `.mcp.json` at the published binary so the plugin works without a local
  pack checkout.
- **Wire MCP as a first-class HQ pack contribution** — add an `mcp` key to
  `scan-packages.sh` so HQ install can register the server with the host's
  Claude Code config in one step.
- **More tools** — `hq_files_browse`, `hq_modules_install`, `hq_dm`, etc.
  Start with the five most-used capabilities and grow on demand.

## Related

- `core/policies/hq-share-session-urls-are-capabilities.md` — share-session
  URL handling rule. Carries over to `hq_share` (the MCP tool returns the
  URL inline; later turns must redact it).
- `core/policies/cross-company-credential-isolation.md` — `hq_secrets_exec`
  must respect company scoping. Pass `company` explicitly when crossing
  contexts.
- `core/knowledge/public/hq-core/cowork-plugin-handoff.md` — design rationale
  and decision log (if you want the full "why this shape, not that one"
  story).
