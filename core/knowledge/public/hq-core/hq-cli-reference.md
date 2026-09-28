---
type: reference
domain: [engineering, operations]
status: canonical
tags: [hq-cli, commands, reference, generated]
relates_to: [knowledge/public/hq-core/hq-sync-model.md, knowledge/public/hq-core/work-mesh-live.md, knowledge/public/hq-core/quick-reference.md]
verified_against:
  - indigoai-us/hq-cli@dfe49a4872b94a82c84842e5272d3a859044a8a0 (2026-09-27)
---

# hq CLI command reference

Generated from `src/command-catalog.generated.ts` in `@indigoai-us/hq-cli`
**5.247.0** (origin/main `dfe49a4`, 2026-09-27). The catalog is itself generated
from the live commander tree by `scripts/generate-command-catalog.mjs`, and the
registration order lives in `src/command-registration-plan.ts`.

- 55 top-level commands are registered. 52 are public; 3 are hidden
  (`hq core`, `hq lanes`, `hq daemon`) and are listed only at the end.
- Hidden subcommands of public roots are omitted (for example the hidden
  `hq dm send`; the normal form is `hq dm <recipient-or-channel> "message"`).
- Descriptions are the first sentence of each catalog entry. Run
  `hq <command> --help` for full options.
- There is no `hq deploy` command. Artifact deploys go through the `/deploy`
  skill; `hq api-keys create --deploy-app` mints a deploy-scoped key.

## Notes that the one-line descriptions do not show

- **Login providers.** `hq login` and `hq auth login` accept
  `--provider google|microsoft|picker`. `google` maps to the Cognito `Google`
  IdP, `microsoft` to `MicrosoftPersonal`, and `picker` opens the Cognito
  Hosted UI chooser (which also covers email and password accounts).
  Without the flag the CLI resolves an environment, remembered, or first-login
  choice (`src/utils/login-provider.ts`).
- **API keys.** `hq api-keys create` prints an `HQ_API_KEY` value for CI and
  automation. Only some commands accept it: `hq bot` refuses it, and several
  `hq files` paths (`--personal`, cross-company roll-up) require a Cognito
  session or a `cmp_…` company uid. `hq api-keys create` prints the supported
  list for the key it mints.
- **Search.** `hq search` and `hq index` operate on the local qmd index.
- **Runtimes.** `hq reindex` converges hook trust for Claude Code, Codex, and
  Grok; `hq mcp status` reports MCP packs across Claude and Codex.

## Regenerating this file

Run from the HQ root. It reads origin/main without touching the checkout.

```bash
git -C repos/private/hq-cli fetch origin
git -C repos/private/hq-cli show origin/main:src/command-catalog.generated.ts \
  | sed -e '/^export type/,/^};/d' \
        -e 's/^export const COMMAND_CATALOG = /module.exports = /' \
        -e 's/^] as const satisfies.*$/];/' > /tmp/hq-catalog.js
```

Then walk `module.exports` in Node: for each entry print `name`, `aliases`,
`hidden`, and the first sentence of `description`, recursing into
`subcommands`. Group roots under the section headings below, update the version, SHA, and
date in the header, and update `verified_against`.

## Identity and session

| Command | Description |
|---|---|
| `hq login` | Authenticate with HQ via Cognito |
| `hq logout` | Log out and clear cached credentials |
| `hq whoami` | Show the currently authenticated user |
| `hq auth` | Manage the local HQ Cognito session |
| `hq auth login` | Sign in to HQ — opens the Cognito Hosted UI and caches tokens locally |
| `hq auth logout` | Clear the cached HQ Cognito session |
| `hq auth refresh` | Ensure a valid cached Cognito session (refresh only if expiring; no-op if already valid) |
| `hq auth status` | Show whether a valid HQ session is cached |

## Companies, membership, and cloud

| Command | Description |
|---|---|
| `hq onboard` | Provision an HQ vault: sign in, create company, S3 bucket, STS, sync |
| `hq onboard create-company` | Sign in and provision a brand NEW HQ vault for a company. |
| `hq onboard join` | Accept an invite and join an existing company |
| `hq onboard resume` | Resume a partially-completed onboarding flow from local checkpoint |
| `hq onboard dry-run` | Show what create-company would do, without provisioning anything |
| `hq cloud` | Cloud commands — provision entities and manage cloud-backed companies |
| `hq cloud provision` | Provision a cloud-backed entity (entity + bucket + initial sync) |
| `hq cloud provision company` | Promote a local company to a cloud-backed entity (idempotent). |
| `hq cloud retire` | Soft-tombstone a cloud-backed company (owner only) |
| `hq cloud retire company` | Soft-tombstone a cloud company so `hq cloud demote company` can run. |
| `hq cloud demote` | Demote a cloud-backed entity back to local-only |
| `hq cloud demote company` | Demote a cloud-backed company to local-only after the cloud entity has been soft-tombstoned (`hq cloud retire company` or hq-console). |
| `hq company` | Company-level settings |
| `hq company transfer` | Transfer company ownership. |
| `hq company transfer initiate` | Nominate an active member as the new owner. |
| `hq company transfer accept` | Accept a pending nomination and become the owner. |
| `hq company transfer decline` | Decline a pending nomination (nominee only). |
| `hq company transfer cancel` | Cancel a nomination you initiated (initiating owner only). |
| `hq company transfer status` | Show the current nomination and the company's transfer history. |
| `hq company settings` | Per-company settings (owner-only) |
| `hq company settings set` | Set per-company settings (PUT /company-settings). |
| `hq members` | Manage company memberships and invites |
| `hq members promote` (alias: `set-role`) | Change a member's role (owner\|admin\|member\|guest) — promotes OR demotes. &lt;target&gt; may be an email, a prs_ personUid, or a full membership key. |
| `hq members invite` | Invite a person or fleet agent to the company. |
| `hq members list` | List the company's active members (use --pending for pending invites) |
| `hq members revoke` | Revoke a pending invite. |
| `hq people` | List, search, and resolve a company's people (from companies/&lt;co&gt;/people) |
| `hq people list` | List all people recorded for the company |
| `hq people search` | Keyword search over people names and emails |
| `hq people resolve` | Resolve a person name to their email address |
| `hq groups` | Manage groups in HQ vault |
| `hq groups create` | Create a new group |
| `hq groups delete` | Delete a group |
| `hq groups add` | Add a person or agent to a group (principal: email, personUid, or agentUid) |
| `hq groups remove` | Remove a person or agent from a group (principal: email, personUid, or agentUid) |
| `hq groups list` | List all groups in the company |
| `hq groups members` | List members of a group |
| `hq group-grants` | Grant a group's access to another company (cross-company), and revoke or inspect those grants |
| `hq group-grants grant` | Grant a group (from the source company) access to &lt;targetCompany&gt; at a role |
| `hq group-grants revoke` | Revoke a group's grant on &lt;targetCompany&gt; |
| `hq group-grants outbound` | List grants a source-company group holds on other companies |
| `hq group-grants inbound` | List grants other companies' groups hold on this company |
| `hq workers` | Discover and share HQ workers |
| `hq workers list` | List workers you can access (public + your active company's) |
| `hq workers share` | Grant a teammate, group, or @all access to a company worker |

## Sync

| Command | Description |
|---|---|
| `hq sync` | Cloud sync commands — sync HQ to S3 for mobile access |
| `hq sync push` | Push local file(s) to the company vault on S3 |
| `hq sync pull` | Pull permitted files from the company vault to local HQ |
| `hq sync status` | Show local sync journal summary |
| `hq sync now` | Bidirectional sync: push local changes, then pull remote updates (mirrors AppBar HQ Sync's "Sync Now" button) |
| `hq sync doctor` | Repair the local HQ tree. |
| `hq sync mode` | Flip a membership's sync-mode (shared\|all\|custom), or --show every membership's current mode |
| `hq sync narrow` | Migrate a company's membership from syncMode='all' to 'shared' — dry-run previews diff, --apply performs the prune + flip |
| `hq sync manifest` | Upload a file manifest for the sync reconciliation audit (personal or a company scope) |
| `hq team-sync` | Pull latest team content for all joined teams |
| `hq rescue` | Re-sync your HQ core to the latest release, preserving your local edits (drift) |
| `hq reindex` (alias: `master-sync`) | Surface namespaced skills, materialize legacy knowledge repos, regenerate the workers registry, and trust HQ hooks for Codex, Grok, and Claude Code |

## Files and vault

| Command | Description |
|---|---|
| `hq files` | Manage file access controls in HQ vault. |
| `hq files share` | Share file paths. foo/ is a private folder (children stay creator-only); quote the shared-folder glob 'foo/*' so the shell passes it literally. |
| `hq files unshare` | Remove a file access grant. |
| `hq files acl` | Show the ACL (access control list) for a file prefix. foo/ is a private folder whose children are creator-only; the quoted glob 'foo/*' is shared. |
| `hq files delete` | Delete vault objects under a prefix (bounded + scoped). |
| `hq files versions` | List prior content versions and delete markers for one exact vault key. |
| `hq files restore` | Restore a prior version with --version-id or undelete an exact vault key. |
| `hq files trash` | List deleted vault keys retained as tombstones. |
| `hq files browse` | List vault objects under [path] without syncing them locally. |
| `hq files cat` | Stream a single vault object to stdout (or --out &lt;file&gt;) without syncing it. |
| `hq files shared-with-me` | List the files/prefixes explicitly shared with you. |
| `hq files search` | Search vault object keys (case-insensitive path/name match) under a company without downloading. |
| `hq files get` | Download (materialize) a vault file or prefix into local HQ on demand. |
| `hq access` | Tell whether a vault file exists and whether you can read it. |
| `hq db` | Vault databases — local SQLite per company and HQ-managed remote Postgres-class DBs |
| `hq db status` | Show local (and remote when bound) vault DB status; auto-creates local SQLite if missing |
| `hq db sql` | Run SQL against the company vault DB (local default; --remote for secrets-injected remote; read-only by default) |
| `hq db migrate` | Apply pending vault text migrations (companies/{co}/db/migrations/*.sql) to the local DB |
| `hq db provision` | Provision (or re-bind) the company remote vault DB via HQ control plane (HQ Workforce plan) |
| `hq skill` | Create, stage, promote, and discuss company skills |
| `hq skill create` | Register, stamp, surface, and sync a company skill |
| `hq skill register` | Register a company skill to a proposal-lane stamped file without writing the canonical tree |
| `hq skill promote` | Copy independently-cleared stamped bytes into the canonical skill path after SHA-256 and skill_uid checks |
| `hq skill propose` | Post a comment-only improvement for a skill |
| `hq skill delete` | Delete a company skill and all of its files for everyone (skl_… uid, SKILL.md path, or skill slug). |

## Secrets and API keys

| Command | Description |
|---|---|
| `hq secrets` | Manage secrets in HQ vault (SSM Parameter Store) |
| `hq secrets set` | Create or update a secret |
| `hq secrets get` | Get a secret's metadata (use --reveal for value) |
| `hq secrets exists` | Check whether a secret exists (HEAD; exit 0=present, 1=absent, 2=error) |
| `hq secrets list` | List all secrets for the company (including nested path-based names) |
| `hq secrets policy` | View or update secret access policy |
| `hq secrets policy get` | Show the policy for a secret path |
| `hq secrets policy set` | Set the policy for a secret path |
| `hq secrets script` | Manage approved scripts for script-locked secrets |
| `hq secrets script approve` | Approve a script for a secret path |
| `hq secrets script revoke` | Revoke an approved script from a secret path |
| `hq secrets script list` | List approved scripts for a secret path |
| `hq secrets delete` | Delete a secret |
| `hq secrets sandbox` | Run a command in the hosted sandbox with named secrets injected as env vars; open egress, secrets never touch this machine |
| `hq secrets exec` | Run a command with secrets injected as env vars |
| `hq secrets env` | Print 'export KEY=VALUE' lines suitable for: source &lt;(hq secrets env --only K1,K2) |
| `hq secrets generate-link` | Generate a one-time link for someone to submit a secret value |
| `hq secrets share` | Share a secret with an email address, group, or the entire company (@all) |
| `hq secrets unshare` | Remove a grant from a secret |
| `hq secrets acl` | Show the ACL (access control list) for a secret path |
| `hq secrets cache` | Manage the local secrets cache |
| `hq secrets cache clear` | Clear all cached secrets |
| `hq run` | Load secrets from .env.schema and run a command with them injected |
| `hq api-keys` | Manage vault API keys for CI and automation |
| `hq api-keys create` | Create a new API key (vault secrets and/or scoped deploy via --deploy-app) |
| `hq api-keys list` | List API keys for a company |
| `hq api-keys revoke` | Revoke an API key |

## Messaging

| Command | Description |
|---|---|
| `hq dm` | Send and read direct messages, and manage connection requests. |
| `hq dm inbox` | List your recent incoming direct messages. |
| `hq dm thread` (alias: `read`) | Show your two-way conversation with a person (email, personUid, or agentUid). |
| `hq dm channel` (alias: `history`) | Show recent messages in a DM channel or group DM — by name, #name, or a channel id from `hq channels`. |
| `hq dm requests` | List your pending incoming connection requests. |
| `hq dm accept` | Accept a pending connection request (by requester email, personUid, or pairKey from `hq dm requests`). |
| `hq dm decline` | Decline a pending connection request (by requester email, personUid, or pairKey from `hq dm requests`). |
| `hq dm block` | Block a person so they can't send you further requests (by requester email, personUid, or pairKey from `hq dm requests`). |
| `hq channels` | List the DM channels you're in (name them with `hq dm <name> "…"`). |
| `hq channels list` | List your DM channels — named channels and group DMs. |
| `hq channels members` | Print the members of one of your DM channels. |

## Meetings, sources, signals, CRM

| Command | Description |
|---|---|
| `hq meetings` | View and search meeting recordings, transcripts, and notes |
| `hq meetings list` | List recorded meetings (newest first) |
| `hq meetings import` | Import a normalized historical transcript JSON file |
| `hq meetings invite` | Invite the meeting bot to a Google Meet, Zoom, or Teams URL |
| `hq meetings get` | Show meeting details |
| `hq meetings set-company` | Set or change the company a meeting is attributed to (use 'unknown' to clear) |
| `hq meetings search` | Search meetings by title or participant name |
| `hq meetings transcript` | Print the meeting transcript |
| `hq meetings notes` | Print AI-generated meeting notes |
| `hq sources` | Read sources (meetings, emails, etc.) from a vault entity |
| `hq sources list` | List sources of a given channel for an entity |
| `hq sources get` | Fetch a single source by id |
| `hq sources channels` | Print the canonical source channels (one per line) |
| `hq sources entities` | List entities (companies/personal) your account has access to |
| `hq signals` | Read signals (action_items, decisions, etc.) from a vault entity |
| `hq signals list` | List signals of a given type for an entity |
| `hq signals get` | Fetch a single signal by id |
| `hq signals types` | Print the canonical signal types (one per line) |
| `hq signals entities` | List entities (companies/personal) your account has access to |
| `hq crm` | Native CRM — upsert canonical entities into a company vault |
| `hq crm entity` | CRM entity operations |
| `hq crm entity upsert` | Create or update a canonical CRM entity (POST /crm/entities). |

## Search

| Command | Description |
|---|---|
| `hq search` | Search the local HQ qmd index |
| `hq search get` | Retrieve a qmd document by path or document id |
| `hq index` | Manage the local HQ search index |
| `hq index sync` | Reconcile collections and incrementally update the qmd index |
| `hq index collections` | Show expected and registered qmd collections |
| `hq index background` | Run a detached, single-flight qmd cleanup and reindex |
| `hq index status` | Show qmd binary, collection, and index status |

## Bots, agents, and Outposts

| Command | Description |
|---|---|
| `hq bot` | Personal local bots that run on this computer with your own model login |
| `hq bot continuity-import` | Import verified private bot context before cloud activation (promotion coordinator) |
| `hq bot jobs` | Show, schedule, or remove a bot's recurring jobs (the schedule runs in the cloud, not on this computer) |
| `hq bot promote` | Move this local bot to cloud compute, preserving its identity and private context |
| `hq bot create` | Provision a local bot identity, scaffold its worker folder, install its launchd agent, and start it |
| `hq bot companies` | Show or change which companies a company bot is a member of (you invite or remove it; a personal bot has no list of its own) |
| `hq bot workers` | List the workers (templates) a bot can be created from (hq bot create &lt;name&gt; --worker &lt;id&gt;) |
| `hq bot list` | List local bots with runtime, online state, and pid |
| `hq bot adopt` | Bring a bot you already own back to this computer: new machine credentials, its saved settings, worker folder, and startup agent |
| `hq bot restore` | Bring back every local bot your HQ account owns that is not set up on this computer (after a reinstall, or on a new Mac) |
| `hq bot start` | Start the bot (via launchd when installed, else a detached process) |
| `hq bot stop` | Stop the bot process (it starts again at next login while its launchd agent is installed) |
| `hq bot restart` | Stop then start the bot |
| `hq bot status` | Show the bot's process, heartbeat, launchd, and credential state |
| `hq bot logs` | Show the bot's log |
| `hq bot run` | Run the bot in the foreground (this is what launchd runs) |
| `hq bot rm` | Stop the bot, remove its launchd agent, delete its cloud identity and local state |
| `hq bot set` | Change the model and thinking level a bot uses (applies from its next message) |
| `hq bot intro` | Have the bot re-send its introduction DM to you |
| `hq bot daemon` | Manage the bot's launchd user agent (macOS) |
| `hq bot daemon install` | Install and load the LaunchAgent so the bot starts at login and restarts on crash |
| `hq bot daemon uninstall` | Unload and remove the LaunchAgent |
| `hq bot daemon status` | Show whether the LaunchAgent is installed and loaded |
| `hq agents` | Manage a company's cloud (fleet) agents |
| `hq agents models` | List the model catalog available to cloud agents |
| `hq agents message` (alias: `msg`) | Send a message to an agent and wait for its reply |
| `hq agents thread` (alias: `history`) | Show your recent conversation with an agent |
| `hq agents terminal` | Open an interactive terminal on an agent's box — a real TTY over SSM Session Manager (no SSH, no local AWS credentials). |
| `hq agents provision` (alias: `new`, `create`) | Provision a new cloud agent (company-specific monthly price shown before creation) |
| `hq agents login-code` | Submit a Claude subscription sign-in code for an agent |
| `hq agents list` | List the company's agents |
| `hq agents status` | Show an agent's setup state and runtime detail |
| `hq agents rename` | Set an agent's display name |
| `hq agents set` | Update an agent's profile (name / title / description) |
| `hq agents config` (alias: `update`) | Update an agent's runtime config (model / reasoning effort / service tier), or migrate its brain/runtime provider with --provider (DESTRUCTIVE: terminates + reprovisions the box) |
| `hq agents start` | Start an agent's box |
| `hq agents stop` | Stop an agent's box |
| `hq agents retry` | Resume an agent's setup from the first non-done step |
| `hq agents rm` (alias: `delete`) | Deprovision (permanently tear down) an agent |
| `hq agents rotate` | Issue a fresh enrollment code for an external agent (old secret + host key stop minting) |
| `hq agents revoke` | Revoke an external agent: disable its login and drop it from the team |
| `hq agents jobs` | List, pause, or cancel an agent's scheduled jobs |
| `hq agents jobs list` | List an agent's scheduled jobs |
| `hq agents jobs pause` | Pause a job's schedule (reversible) |
| `hq agents jobs cancel` | Cancel a job and delete its schedule |
| `hq agent` | Enroll and run this host as an external HQ agent |
| `hq agent enroll` | Enroll this host as an external HQ agent using a one-time code |
| `hq agent kit` | Install, inspect, or run the external-agent background services |
| `hq agent kit install` | Install the inbox and heartbeat services plus the skills directory |
| `hq agent kit status` | Show whether each kit service is installed and running |
| `hq agent kit uninstall` | Stop and remove the kit services (credentials and skills are kept) |
| `hq agent kit wake` | Wake this bot's own framework when HQ messages arrive (webhook URL or local command) |
| `hq agent kit wake set-url` | POST a notice to a webhook URL (e.g. a Grok Bot routine webhook) when mail is pending. |
| `hq agent kit wake set-command` | Run a local command (no shell) when mail is pending; the notice JSON arrives on stdin. |
| `hq agent kit wake show` | Show the configured wake (the URL is masked) |
| `hq agent kit wake clear` | Remove the wake configuration |
| `hq agent kit wake test` | Fire the wake once now with the current pending count |
| `hq agent kit run` | Run one kit service in the foreground (sync\|inbox\|heartbeat), or `all` to supervise every service in one process |
| `hq agent probe` | Verify identity, vault access, presence, DMs and secrets; report to the console |
| `hq agent mcp` | Serve HQ as a stdio MCP server for the bot framework (whoami, search, files, secrets-exec, dm, inbox, work-mesh) |
| `hq agent inbox` | List this agent's pending HQ messages (mirrored by the kit), or mark them handled |
| `hq agent inbox done` | Mark inbox items handled and ack them on the server |
| `hq outposts` | Manage your personal HQ Outposts (EC2 boxes) |
| `hq outposts provision` (alias: `create`) | Provision a new Outpost ($80/month — requires --yes) |
| `hq outposts list` | List every Outpost you own |
| `hq outposts status` | Show live detail for one Outpost |
| `hq outposts exec` | Run a shell command on an Outpost and print its output (use -- before flags meant for the remote command). |
| `hq outposts exec-stage` | Stage a file for an asynchronous Outpost command |
| `hq outposts exec-submit` | Submit an asynchronous shell command to an Outpost (returns immediately with commandId; shell budget defaults to 48h) |
| `hq outposts exec-result` | Fetch the result of an asynchronous Outpost command |
| `hq outposts terminal` | Open an interactive terminal on an Outpost — a real TTY over SSM Session Manager (no SSH, no local AWS credentials). |
| `hq outposts codex-enable` | Enable (or retry) |
| `hq outposts login` | Request a fresh login URL for an Outpost |
| `hq outposts login-code` | Submit the Claude sign-in code for an Outpost that is awaiting login |
| `hq outposts destroy` | Tear down (permanently destroy) an Outpost |
| `hq report` | Publish and manage a channel report owned by this bot. |
| `hq report get` | (no description in catalog) |
| `hq report publish` | (no description in catalog) |
| `hq report promote` | (no description in catalog) |
| `hq report discard-draft` | (no description in catalog) |
| `hq report access` | (no description in catalog) |
| `hq report decommission` | (no description in catalog) |
| `hq report adopt` | (no description in catalog) |
| `hq report templates` | (no description in catalog) |

## Work mesh and monitors

| Command | Description |
|---|---|
| `hq mesh` | Work mesh — register project work, report progress, and warm ~/.hq/work-mesh/cache |
| `hq mesh check` (alias: `status`, `projects`) | Show active work-mesh threads for a company/project |
| `hq mesh start` | Ensure a project thread exists and claim/report start |
| `hq mesh progress` | Append a progress event to the project thread |
| `hq mesh blocked` | Append a blocked event to the project thread |
| `hq mesh done` | Mark the project thread done |
| `hq mesh note` | Append a note with no status change |
| `hq mesh story` | PATCH one Board story status and/or assignee |
| `hq mesh project` | Set a project Board view or register its project channel |
| `hq mesh project set` | PUT the project Board view from flags or a PRD JSON file |
| `hq mesh project ensure` | Idempotently register a PRD on the Board and verify the view |
| `hq mesh project register` | Register an existing Board and bind its project channel; use project ensure to create or repair a Board |
| `hq mesh doctor` | Warm ~/.hq/work-mesh/cache from hq-pro (directory, inbox, pair DMs). |
| `hq mesh context` | Work context reconcile, organize, correct, device default, and untracked consent |
| `hq mesh context reconcile` | Resolve session identity and company; durable local accept before network |
| `hq mesh context resolve` | Interactively ask (once per repo) which company this repo's work is filed under, and remember it (gap 4). |
| `hq mesh context backfill-held` | Reconcile ENDED sessions whose held events lack a company so the daemon re-attributes the backlog (explicit, opt-in; no fleet fan-out) |
| `hq mesh context bind-project` | Bind this session to a project id, a numbered candidate, or new &lt;slug&gt; |
| `hq mesh context prd-sync` | Emit task_status for PRD story passes/status changes on a bound session |
| `hq mesh context organize` | List or submit one-time project/task decisions (US-007B / US-005B) |
| `hq mesh context correct` | Explicit cross-company session correction via server migrate (US-017B) |
| `hq mesh context requeue` | Requeue quarantined outbox operations (default: only AUTH_DENIED — work-mesh-live gap 10 recovery) |
| `hq mesh context default` | Manage the device-local default company preference |
| `hq mesh context default get` | Show the device default company (never activeCompany) |
| `hq mesh context default set` | Set the device default company slug after verifying membership |
| `hq mesh context default clear` | Clear the device default company |
| `hq mesh context untracked` | Record an explicit user-origin untracked consent receipt (local only) |
| `hq mesh contract` | Print versioned work-mesh contracts for other repositories |
| `hq mesh contract preflight` | Offline preflight ContextResult contract (contracts/preflight/v1) |
| `hq mesh session` | Local session-event spool: enqueue (printf-compatible), flush, and live status |
| `hq mesh session start` | Enqueue session_start |
| `hq mesh session turn-start` | Enqueue turn_start |
| `hq mesh session turn-end` | Enqueue turn_end |
| `hq mesh session end` | Enqueue session_end |
| `hq mesh session task-status` | Enqueue task_status |
| `hq mesh session blocked` | Enqueue blocked |
| `hq mesh session note` | Enqueue note |
| `hq mesh session flush` | Claim spool/held by rename, hold or drop by context state, POST batches of ≤100 |
| `hq mesh session status` | Print the company-wide live read (US-004) as a table or --json |
| `hq mesh mode` | Get/set the daemon emit mode (legacy = spool/flush; direct = receive-only). |
| `hq mesh emit` | Direct-emit drain: POST any deferred events (retry file) to /v1/mesh/events; --replay-legacy also replays the legacy spool/held backlog through the new endpoint |
| `hq mesh daemon` | Resident spool drainer + MQTT presence (install as a user service) |
| `hq mesh daemon run` | Start the single-instance daemon (pid lock, spool watch, presence) |
| `hq mesh daemon install` | Install LaunchAgent (macOS), systemd user unit (Linux), or Scheduled Task (Windows) |
| `hq mesh daemon uninstall` | Remove the installed user-level daemon service |
| `hq mesh daemon status` | Show whether the daemon service is installed/loaded |
| `hq mesh daemon doctor` | Report daemon running/MQTT/spool/held/dead-letter/outbox/flush health |
| `hq monitor` | Run detached monitors and deliver their output into agent context |
| `hq monitor start` | Start a detached monitor script |
| `hq monitor list` | List active monitors |
| `hq monitor show` | Show monitor metadata, state and events |
| `hq monitor stop` | Stop a running monitor |
| `hq monitor logs` | Read monitor events or stderr |

## Integrations and MCP

| Command | Description |
|---|---|
| `hq integrations` | Connect, govern, and use company apps (Linear, Notion, …) through HQ's governed integration gateway |
| `hq integrations list` | List the company's connected apps |
| `hq integrations import` | Import Claude Desktop connectors into company Integrations |
| `hq integrations install-local` | Register a company-shared local connector in this machine's Claude/Codex MCP config |
| `hq integrations tools` | List what a connected app can do |
| `hq integrations call` | Call one of a connected app's tools (approval-gated when it changes things) |
| `hq integrations approve` | Approve a queued call — it executes exactly once (owner only) |
| `hq integrations reject` | Reject a queued call (owner only) |
| `hq integrations catalog` (alias: `search`) | Browse or search apps you can connect |
| `hq integrations inspect` | Show what an app exposes before you connect it |
| `hq integrations discover` | Find a connectable server from an app's documentation page |
| `hq integrations connect` (alias: `add`) | Connect an app — by domain, catalog entry, docs page, or MCP URL |
| `hq integrations reconnect` | Re-authenticate a connected app; use --connect to re-add a revoked app |
| `hq integrations show` | Show one connected app in full |
| `hq integrations policy` | Show or change whether an app's changes need approval |
| `hq integrations read-safe` | Mark a read-only tool as safe to run without approval (owner only) |
| `hq integrations grants` | Show who is authorized to run an app's change-making tools |
| `hq integrations grant` | Authorize someone to run one of an app's change-making tools |
| `hq integrations ungrant` | Remove a per-tool authorization, leaving only the app's default access |
| `hq integrations access` | Show who in the company can use a connected app |
| `hq integrations share` | Let someone in the company use a connected app |
| `hq integrations unshare` | Stop someone from using a connected app |
| `hq integrations audit` | Recent activity across the company's connected apps |
| `hq integrations pending` | Calls that were queued for an owner's approval |
| `hq integrations disconnect` (alias: `remove`) | Disconnect an app and delete its stored credentials |
| `hq integrations purge` | Permanently remove a revoked connection from the list (owner only) |
| `hq mcp` | MCP pack observability (read-only) across Claude + Codex |
| `hq mcp status` | Show installed MCP packs/servers and their health in BOTH Claude and Codex (PARTIAL/DRIFT flagged; secrets redacted) |
| `hq mcp capabilities` | Advertise that this hq-cli supports contributes.mcp (dual-runtime Claude+Codex registration) |

## Packs, marketplace, and modules

| Command | Description |
|---|---|
| `hq install` | Install a package. |
| `hq remove` | Remove an installed package (archives it first) |
| `hq packs` | Content-pack lifecycle (install via `hq install`) |
| `hq packs list` (alias: `ls`) | List installed content packs and the curated catalog |
| `hq packs update` | Update an installed content pack (re-install latest) |
| `hq packs uninstall` (alias: `remove`) | Un-wire and archive an installed content pack |
| `hq packages` | Package management commands |
| `hq packages install` | Install a package. |
| `hq packages remove` | Remove an installed package (archives it first) |
| `hq packages update` | Check for and apply package updates |
| `hq packages list` (alias: `ls`) | List installed content packs and the curated catalog |
| `hq packages packs` | Content-pack lifecycle (install via `hq install`) |
| `hq packages packs list` (alias: `ls`) | List installed content packs and the curated catalog |
| `hq packages packs update` | Update an installed content pack (re-install latest) |
| `hq packages packs uninstall` (alias: `remove`) | Un-wire and archive an installed content pack |
| `hq publish` | Package a skill/worker pack and submit it to the HQ marketplace (POST /v1/listings). |
| `hq creators` | Creator marketplace account |
| `hq creators apply` | Apply for verified-creator access (required to publish packs) |
| `hq modules` | Module management commands |
| `hq modules add` | Add a module to the manifest |
| `hq modules sync` | Sync all modules from manifest |
| `hq modules list` (alias: `ls`) | List all modules and their status |
| `hq modules update` | Update lock for a specific module (or all if no name given) |

## Billing

| Command | Description |
|---|---|
| `hq billing` | Inspect billing and mint a card-capture link |
| `hq billing status` | Show subscription status and whether a card is on file |
| `hq billing checkout` | Mint a Stripe card-capture link (shareable) to add a card |
| `hq billing upgrade` | Open Stripe Checkout to upgrade this company to HQ Workforce ($500/mo) |
| `hq billing sponsor` | Ask a company to cover your $50 plan, or answer a request |
| `hq billing sponsor request` | Ask a company to cover your $50 HQ plan |
| `hq billing sponsor list` | Show sponsorship requests — the company's queue, or your own |
| `hq billing sponsor approve` | Say yes — put someone's $50 plan on the company bill |
| `hq billing sponsor decline` | Say no to a plan sponsorship request |
| `hq billing sponsor revoke` | End a sponsorship the company is currently paying for |
| `hq billing sponsor withdraw` | Take back a sponsorship request you made |

## Diagnostics, version, feedback

| Command | Description |
|---|---|
| `hq doctor` | Verify HQ hook wiring, runtimes, and connection health (read-only; integrations uses one control-plane inventory read). |
| `hq version` | Show HQ, CLI, and latest hq-core versions |
| `hq feedback` | Submit a bug report or feature request to HQ |
| `hq feedback bug` | Report a bug |
| `hq feedback feature` | Request a feature |

## Staff (super-admin only)

| Command | Description |
|---|---|
| `hq staff` | Staff-only commands (super-admin required) |
| `hq staff reset-test-account` | Reset a designated real-email test account (dry-run by default). |
| `hq staff test-account` | Manage the designated test-account registry (super-admin only). |
| `hq staff test-account add` | Add an email to the registry so `hq staff reset-test-account` will sweep it. |
| `hq staff test-account remove` | Soft-delete a registry entry (row stays with active: false). |
| `hq staff test-account list` | List active registry entries. |

## Hidden commands (internal)

These roots are registered with `hidden: true` and are not a stable public surface. `hq daemon` is listed in full because the sync model refers to it.

| Command | Description |
|---|---|
| `hq core` | HQ scaffold scripts hosted by the CLI (core; not a stable surface) (subcommands omitted) |
| `hq lanes` | Create, supervise, and steer worker lanes; routed decision queue (subcommands omitted) |
| `hq daemon` | Run all of this machine's HQ background services under one supervisor |
| `hq daemon install` | Detect this machine's type, install the daemon, and start its default services |
| `hq daemon uninstall` | Stop the daemon and remove its OS unit |
| `hq daemon run` | Run the supervisor (this is what the OS unit starts) |
| `hq daemon status` | Show the machine type and each service's state |
| `hq daemon logs` | Print the supervisor log, or one service's log |
| `hq daemon restart` | Restart one service, or every running service |
| `hq daemon trigger` | Run a scheduled service now (for example search-index) |
| `hq daemon enable` | Turn services on for this machine, beyond its defaults |
| `hq daemon disable` | Turn default services off for this machine |
| `hq daemon pin-hq-cloud` | Pin hq-cloud to an exact version, or clear the pin |
| `hq daemon migrate` | List the older HQ background units the daemon would take over; --apply takes them over |
## Sources

- `indigoai-us/hq-cli@dfe49a4` — `src/command-catalog.generated.ts`,
  `src/command-registration-plan.ts`, `scripts/generate-command-catalog.mjs`,
  `src/commands/login.ts`, `src/utils/login-provider.ts`,
  `src/commands/api-keys.ts`, `src/commands/bot.ts`,
  `src/commands/files-browse.ts`, `package.json` (version 5.247.0),
  `CHANGELOG.md`.
