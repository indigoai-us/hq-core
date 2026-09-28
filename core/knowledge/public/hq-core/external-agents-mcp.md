---
type: reference
domain: [engineering, operations]
status: canonical
tags: [agents, external-agents, mcp, hq-mcp, connectors, cowork, hq-cli]
relates_to:
  - core/knowledge/public/hq-core/agents-and-bots.md
  - core/packages/hq-pack-cowork/README.md
verified_against:
  - hq-mcp@ccf910a (2026-09-27)
  - hq-cli@dfe49a48 (2026-09-27)
  - hq-pro@563bf1f39 (2026-09-27)
  - hq-console@a227a042 (2026-09-27)
---

# Connecting outside agents to HQ

Three ways an agent HQ does not host can read and act on HQ:

| Path | Who it is for | Transport | Identity |
|---|---|---|---|
| Cloud connector (hq-mcp) | A person's Claude, ChatGPT, Claude Code, Codex, or Grok | Streamable HTTP at the connector URL shown in the console (Integrations → Connect an agent), e.g. `https://hq-mcp.hq.computer/mcp` | The person's HQ login via OAuth |
| External bot (`hq agent mcp`) | A bot running on its own host (OpenClaw, grokbot, Muse, any MCP-capable agent) | stdio MCP server started by the bot framework | The bot's own `agt_` machine identity |
| Cowork plugin | Claude Code / Cowork sessions whose shell is sandboxed | stdio MCP server on the host | The person's local HQ login |

For the full list of agent kinds, see [agents-and-bots.md](agents-and-bots.md).

## Cloud connector (hq-mcp)

Setup lives in the console: Integrations → Connect an agent → A person. The
modal has tabs for Claude, ChatGPT, Claude Code, Codex, and Grok, each with
per-client steps. Cursor is not a tab, although the OAuth code has a
loopback fix for Cursor clients.

- Claude (desktop and claude.ai): Settings → Connectors → Add custom
  connector, name it, paste the URL.
- ChatGPT: custom connectors; on some plans this is behind Developer mode.
- Codex: `[mcp_servers.indigo]` with the URL in `~/.codex/config.toml`, then
  `codex mcp login indigo`.
- Grok CLI: `grok mcp add --transport http indigo <url>`, then authorize in
  `/mcps`.

The console may hand out a different hostname for the same server. Copy the
URL from the console when connecting.

Auth: Cognito OAuth. Clients that need Dynamic Client Registration (Claude
Code and the MCP TypeScript SDK) register through the server's
`/oauth/register` proxy, which issues a synthetic `dcr_…` client id in front
of one real Cognito app client.

The "An agent" view in the same modal toggles whether an existing hosted
agent can use the connector. Only owners and admins can change it.

### Cloud tool list

Registered by `createServer()` in `src/server.ts` with the cloud defaults
(`includeLocalExec: false`, content, search, and skill services bound):

| Group | Tools |
|---|---|
| Health | `hq_ping`, `hq_version`, `hq_exec_check` |
| Identity | `hq_whoami`, `hq_companies_list`, `hq_company_ping` |
| Search and content | `search`, `fetch`, `hq_content_get`, `hq_context_grounding` |
| Knowledge | `hq_knowledge_list`, `hq_knowledge_get` |
| Projects | `hq_projects_list`, `hq_project_get`, `hq_project_status` |
| Files | `hq_files_list`, `hq_files_read`, `hq_files_stat`, `hq_files_create`, `hq_files_update`, `hq_files_delete`, `hq_files_restore`, `hq_files_share` |
| Writes | `hq_files_write`, `hq_project_journal_append`, `hq_knowledge_capture`, `hq_personal_capture` |
| Feedback and deploy | `hq_feedback`, `hq_deploy_site` |
| Secrets | `hq_secrets_list`, `hq_secrets_schema`, `hq_secrets_generate_link` |
| Hosted sandbox | `hq_secrets_sandbox`, `hq_secrets_sandbox_status`, `hq_skill_run`, `hq_skill_status` (registered only when the client's capability plan marks sandbox tools as exposed) |
| Integrations | `hq_integrations_read`, `hq_integrations_list`, `hq_integrations_call`, `hq_integrations_catalog`, `hq_integrations_discover`, `hq_integrations_connect`, `hq_integrations_status` |
| Messages | `hq_messages_contacts`, `hq_messages_inbox`, `hq_messages_thread`, `hq_messages_send`, `hq_messages_channels`, `hq_messages_channel_read`, `hq_messages_channel_send` |
| Work Mesh | `hq_work_mesh_list`, `hq_work_mesh_get`, `hq_work_mesh_unclaimed` |
| Hosted agents | `hq_agents_list`, `hq_agent_run`, `hq_agent_result` |
| Policies | `hq_policies_list`, `hq_policy_get` |
| Skills | `hq_skill_list`, `hq_skill_get`, `hq_skill_create`, `hq_skill_update`, `hq_skill_set_state`, `hq_skill_tags_set`, `hq_skill_access_get`, `hq_skill_access_set`, `hq_skill_access_grant`, `hq_skill_access_revoke`, `hq_skill_improvements_list`, `hq_skill_improvement_post`, `hq_skill_improvement_resolve`, `hq_skill_improvement_withdraw` |

Skills are also exposed as `hq-skill://skill/{id}` resources and an
`hq_skill_apply` prompt for clients that support resources and prompts.

The hq-mcp README still lists an `hq_skill_review` tool; it is not in the
registry at the verified SHA.

### One search surface

hq-mcp PR #46 (`c713ef5`) removed `hq_content_search` and the cloud
`hq_knowledge_search`. The cloud connector has one search surface:
`search` / `fetch`, the OpenAI-compatible pair ChatGPT connectors require
and Claude also uses. Results are filtered by the caller's per-path file ACL.
The local stdio bridge has no content service, so it keeps the qmd-backed
`hq_knowledge_search`.

### Write authority

hq-mcp PR #45 (`750b759`) made the vault file ACL the only write authority.
The bridge no longer keeps a writable-folder allowlist. It forwards any
well-formed, non-private path and the vault answers with the caller's
effective permission on that path (the same answer `hq files acl` gives). A
vault 403 surfaces as `[Refused]` with the vault's reason. The bridge still
refuses, locally, malformed or traversal paths and the privacy boundary
(settings, secrets, workers).

### Local stdio bridge (hq-mcp Phase 1)

The same `createServer()` runs over stdio (`dist/index.js`, or the `.mcpb`
Desktop Extension) for Claude Desktop with a local `hq` CLI. Differences from
cloud: it adds `hq_run` and `hq_run_list` and `hq_knowledge_search`, and it
does not register `search`, `fetch`, `hq_content_get`,
`hq_context_grounding`, or the `hq_skill_*` management tools (those need the
cloud services).

## External bots (`hq agent …`)

An external bot is an `agt_` agent whose runtime is on hardware HQ does not
own. The server records `runtime: "external"`.

Plan: blocked on the free plan with the shared 402 envelope; free and
unlimited on paid plans. No Stripe item, no seat, no box. Pricing detail:
[plans-and-pricing.md](plans-and-pricing.md).

### Enroll flow

1. Admin, in the console: Bots page → Add bot → name → External bot →
   framework (grokbot, OpenClaw, Muse, or Other MCP-capable agent) →
   Create and get code. `hq agents rotate <agentUid>` issues a new code for
   an existing or expired enrollment.
2. The code is 24 Crockford base32 characters, single use, and expires 15
   minutes after creation. It goes into the bot's host, not into chat.
3. On the host: `hq agent enroll <code> [--company <slug>] [--replace]`. This
   generates an Ed25519 host key in `~/.hq-agent/` and writes
   `machine-creds.json` (0600). Later token mints are signed with the host key
   (`mint-challenge`, then `mint`), so a copied creds file alone cannot mint.
4. `hq agent kit install` installs user-level services (LaunchAgent on
   macOS, `systemd --user` on Linux) labelled `ai.getindigo.hq-agent.<service>`
   and writes the skills directory.
5. Register the MCP server in the bot framework:
   `{ command: "hq", args: ["agent", "mcp"], env: { HQ_MACHINE_CREDS_FILE: "<path>" } }`.
6. `hq agent probe` runs the checks `whoami`, `company`, `files` (vault
   pulled when `--sync-files` is on, otherwise `hq files browse`),
   `presence`, `dm`, and `secrets`, then posts the result (`report`); the
   console shows Enrolled once the probe passes. hq-cli's doc lists older
   check names (`team-sync`, `work-mesh`).

Admin lifecycle: `hq agents rotate <agentUid>` (old secret and host key stop
minting; the host re-enrolls with `--replace`) and
`hq agents revoke <agentUid> --yes [--remove]`.

### Kit services

At the verified SHA, `KIT_SERVICES` is `sync`, `inbox`, `heartbeat`.

| Service | Installed | What it does |
|---|---|---|
| `inbox` | Always | Polls the agent inbox and mirrors items to `~/.hq-agent/inbox/`. Acks on the server only with `--inbox-ack` |
| `heartbeat` | Always | Reports component state to the control plane |
| `sync` | Only with `--sync-files` | Mirrors the company vault to disk. Off by default; the bot reads files on demand through `hq agent mcp` |

`hq agent kit run all` supervises every service in one process (used by the
Docker image in `docker/hq-agent-kit/`). Shipped skills: `dm`, `search`,
`files`, `secrets-exec`.

hq-cli's own `docs/external-agents-cli.md` still describes four services
(including `mesh`) and a `work-mesh-status` skill; the code at the verified
SHA does not install either.

### `hq agent mcp` tool list

Server name `hq-agent`, backed by `machine-creds.json`:

`hq_whoami`, `hq_search`, `hq_files_list`, `hq_files_read`,
`hq_secrets_list` (names only), `hq_secrets_exec` (values never returned),
`hq_dm_send`, `hq_inbox_read`, `hq_attachment_fetch`, `hq_inbox_done`,
`hq_work_mesh_status`.

`hq_attachment_fetch` downloads a file attached to an HQ chat message to a
private local path. It is missing from hq-cli's doc but present in
`src/lib/agent-kit/mcp/tools.ts`.

### Inbox and wake

- `hq agent inbox` lists pending mirrored items; `hq agent inbox done <id…>`
  marks them handled and acks them.
- `hq agent kit wake` pokes the bot's own framework when mail is pending, so
  replies do not wait for the bot's polling schedule:
  - `set-url --stdin [--retry-minutes <n>]`: POST a JSON notice to a webhook
    (https, or http only for localhost). The URL is stored in
    `~/.hq-agent/wake.json` (0600) and treated as a secret.
  - `set-command [--timeout-minutes <n>] -- <argv…>`: run a local command
    with the notice on stdin. One run at a time.
  - `show`, `test`, `clear`.
- The notice carries message ids and a pending count, never message text.
  The poller re-wakes every `--retry-minutes` (default 10) while items stay
  pending.

## Cowork plugin

`core/packages/hq-pack-cowork` installs as an HQ pack and as a Claude Code
plugin. The plugin registers a host-launched stdio MCP server that wraps the
real `hq` CLI and `qmd`, so a Cowork session whose shell runs in a sandbox VM
can still sync, search, share, run secrets, and DM with the host's auth.
Install with `/hq-cowork-install`. Tool list and install steps:
[hq-pack-cowork README](../../../packages/hq-pack-cowork/README.md).

## Sources

- hq-mcp@ccf910a: `src/server.ts`, `src/tools/*.ts`,
  `src/cloud/index.ts`, `src/cloud/lambda.ts`, `src/cloud/oauth/dcr.ts`,
  `src/cloud/resources.ts`, `src/cloud/client-capabilities.ts`,
  `src/scope/write-acl.ts`, `README.md`; commits `c713ef5` (#46),
  `750b759` (#45)
- hq-cli@dfe49a48: `docs/external-agents-cli.md`,
  `src/commands/agent*.ts`, `src/lib/agent-kit/services.ts`,
  `src/lib/agent-kit/skills.ts`, `src/lib/agent-kit/mcp/tools.ts`
- hq-pro@563bf1f39: `src/agents/external/handlers.ts`,
  `src/agents/external/plan-gate.ts`
- hq-console@a227a042:
  `src/app/(shell)/companies/[slug]/integrations/_connect-agent-modal.tsx`,
  `_agents-mcp-section.tsx`, `src/lib/claude-code-link.ts`,
  `src/components/agents/external-agent.ts`, `ExternalBotFlow.tsx`
- `core/packages/hq-pack-cowork/README.md`
