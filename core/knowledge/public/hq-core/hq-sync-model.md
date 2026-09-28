---
type: reference
domain: [engineering, operations]
status: canonical
tags: [sync, hq-cloud, hq-cli, vault, daemon, desktop]
relates_to: [knowledge/public/hq-core/hq-cli-reference.md, knowledge/public/hq-core/work-mesh-live.md]
verified_against:
  - indigoai-us/hq-cli@dfe49a4872b94a82c84842e5272d3a859044a8a0 (2026-09-27, CLI 5.247.0)
  - indigoai-us/hq-cloud@e486a796bbbc0a2dbdba5529325d73ba29b2e5e4 (2026-09-27, 6.18.10)
  - indigoai-us/hq-desktop-app@c621a6a18dcee6d9ab62b03067b8a3d1c4f1cea2 (2026-09-27)
---

# HQ sync model

How local HQ content reaches the cloud vault and comes back. The sync engine
is the `@indigoai-us/hq-cloud` package. The `hq` CLI bundles it, and the
desktop app runs its `hq-sync-runner` bin. Command details are in
`hq-cli-reference.md`.

## Two kinds of vault

- **Company vault.** One per cloud-backed company. Syncs
  `<hqRoot>/companies/<slug>/`.
- **Personal vault.** One per person. Syncs the HQ root itself, minus the
  top-level `.git`, `companies`, `repos`, and `workspace` entries. Local
  (non-cloud) companies under `companies/` are included by default: a company
  goes to the personal vault unless it is cloud-backed (a `cloud_uid: cmp_…`
  in `companies/manifest.yaml`, `cloud: true` in its `company.yaml`, or a team
  membership). `companies/manifest.yaml` itself is also carried.
  Inside `workspace/`, only these carve-outs sync: `workspace/threads/handoff.json`
  plus the one thread file it points to, `workspace/agency/`, and
  `workspace/.session-logs/`.

## Company lifecycle

| Stage | How to get there | What changes |
|---|---|---|
| Local-only | Create the company folder (for example with `/newcompany`) | Content rides in the personal vault. |
| New cloud company | `hq onboard create-company` | Creates a new vault entity, bucket, and STS setup. Use `hq onboard join` to join an existing one instead. |
| Promote local to cloud | `hq cloud provision company <slug>` | Provisions the vault entity if missing, patches `companies/manifest.yaml`, writes `.hq/config.json`, runs an initial sync (`--skip-initial-sync` to skip). Idempotent. |
| Retire | `hq cloud retire company <slug>` (owner only), or hq-console | Soft-tombstones the cloud entity. Does not delete vault files or local folders. Prompts unless `--yes`. |
| Demote | `hq cloud demote company <slug>` | Requires the entity to be soft-tombstoned first (`--force` skips that check). Removes `.hq/config.json`, sets `cloud: false` in `company.yaml`, strips manifest cloud refs. |

## What gets downloaded: sync modes

Access and download are separate. Each company membership has a `syncMode`
that controls what a pull materializes locally. It does not change what you
can read.

| Mode | Pull scope |
|---|---|
| `all` | Whole company vault. |
| `shared` | Only paths explicitly granted to you, coalesced into prefixes. |
| `custom` | The prefix list stored with `--paths`. |

Rules from `src/sync/pull-scope.ts`:

- Owners always resolve to `all` for sync, whatever mode is stored. Agent
  memberships (`agt_…`) also resolve to `all`. Admins stay grant-scoped.
- Any failure resolving scope (network, missing membership, grant fetch error)
  falls back to `all`, so a transient error never prunes the local tree.
- A wildcard grant or custom path that means "everything" is treated as `all`.
- Paths fetched with `hq files get` are pinned in `<hqRoot>/.hq/pins.json`
  and added to `shared`/`custom` scope, so a later scoped pull does not prune
  them.

Commands:

- `hq sync mode <shared|all|custom> [--paths <csv>]` sets the mode;
  `hq sync mode --show` lists every membership's mode.
- `hq sync narrow` moves a membership from `all` to `shared`. Dry-run by
  default; `--apply` deletes clean files now out of scope and flips the mode;
  `--force` also removes locally modified files (no undo).
- When a pull would shrink scope over locally modified files it stops.
  `--force-scope-shrink` on `hq sync pull|now` proceeds: modified files stay on
  disk and are only un-tracked; clean out-of-scope files are moved to
  `.hq/scope-quarantine/`.

To read a file you can access but did not download, use `hq files browse`,
`cat`, `search`, or `get`, or `hq access <path>`.

## What gets uploaded: ignore rules

Sync does not read `.gitignore`. `.gitignore` only governs git. The push walk
uses these layers, in order (`src/ignore.ts`):

1. Built-in defaults: VCS and OS files, build output and dependency folders
   (`node_modules/`, `dist/`, `build/`, `.next/`, `target/`, `.venv/`, …),
   secrets (`.env`, `.env.*`, `credentials.json`, `*.credentials.json`,
   `*.secret.*`, `.netrc`, `.mcp.json`), caches (`.cache/`, `.qmd/`, `tmp/`),
   HQ state (`.hq/`, `.hq-*`, `*.pid`, `company.yaml`,
   `modules/modules.yaml`, root `INDEX.md`), worktrees
   (`**/.claude/worktrees/`, `/workspace/worktrees/`), `/workspace/locks/`, and
   client conflict copies (`*.conflict-[0-9]*-*`).
2. `<hqRoot>/.hqignore` (or the legacy `.hqsyncignore`). `!pattern`
   re-includes something an earlier layer excluded.

If `<hqRoot>/.hqinclude` exists, sync switches to allowlist mode: nothing
syncs unless it matches a `.hqinclude` pattern, and the exclusion layers still
apply on top.

The personal vault adds its own exclusions for machine-local state
(`.beads/`, `.obsidian/`, `.vercel/`), update scratch (`output/`,
`_legacy-*`), reindex-generated `.claude/skills/<ns>:<skill>/` wrappers, and
the root `bin/` (`src/personal-vault-exclusions.ts`).

Server-owned files always take the cloud copy on conflict and never get a
conflict copy: `company-brief.md`, `board.json`, `ontology/**`, `signals/**`,
`sources/**` (`src/lib/cloud-authoritative.ts`).

## Running a sync

| Command | Effect |
|---|---|
| `hq sync now` | Push, then pull. `--all` covers every membership plus the personal vault; `--personal` the personal vault only; `--no-personal` drops the personal leg of `--all`. |
| `hq sync push [paths...]` | Push to one company (`--company`), the personal vault, or `--all`. |
| `hq sync pull` | Pull permitted files. Same target flags. |
| `hq sync status` | Summary of the local sync journal. |
| `/hq-sync` skill | Runs `hq-sync-runner --companies --direction both --on-conflict keep` for every cloud-backed company. |

All sync operations, `hq rescue`, and `hq reindex` share one per-root
operation lock. `--lock-timeout <seconds>` bounds the wait (default 300 for
sync; `0` refuses immediately).

## Conflicts

`--on-conflict overwrite|keep|abort`. With no flag, a TTY gets an interactive
prompt; a non-TTY run uses the same version-aware rule as `keep`. The daemon, the desktop app, and
`/hq-sync` use `keep`.

`keep` picks a winner per file (`pickWinner` in `src/cli/conflict.ts`):

1. Identical bytes: no conflict.
2. Both sides carry a frontmatter `version:` and they differ: higher version
   wins.
3. Modification times differ beyond a small tolerance: newer wins.
4. Otherwise the cloud copy wins.

Conflicts are recorded in `<hqRoot>/.hq-conflicts/index.json` for the
`/resolve-conflicts` skill. The full-pass engine no longer writes a
`<file>.conflict-<ts>-<machine>` twin beside the live file: a losing local body
is moved to `.hq/conflict-backups/`, and the cloud side is covered by S3
versioning. Older engines did write twins. `hq sync doctor --reconcile-conflicts`
folds them back into the live files (higher frontmatter `version:` wins; losers
go to `.hq/conflict-backups/`). It is dry-run unless `--yes` and is purely
local.

Vault version history is available per key with `hq files versions`,
`hq files restore`, and `hq files trash`.

## Sync journal

The journal records each file's hash, size, remote ETag, and last sync so a
pull does not overwrite an unsynced local edit.

- Lives outside the HQ tree, under `~/.hq/` (or `HQ_STATE_DIR`), one scope per
  company slug plus the personal vault. `~/.hq/sync-journal.<slug>.json` files
  may be locators; the state itself is a snapshot-plus-WAL store under
  `~/.hq/sync-state-v3/`.
- Snapshots are written in the packed `HQSNAP4` format. A reader that does not
  recognise a snapshot's format reports it as unsupported and says to upgrade
  hq-cloud or the CLI. It does not treat the file as corrupt; do not delete
  `~/.hq/sync-state-v3` in that case.

## Sync manifest

A manifest is the client's list of the files it holds in one scope: path,
size, mtime, optional sha256, and journal state. It never includes file
contents. The server compares manifests with the vault nightly to find clients
that are wedged or half-synced (`docs/sync-manifest.md`).

- Uploaded after a sync pass by the desktop runner, and on demand by
  `hq sync manifest`.
- `hq sync manifest` options: `--scope personal|<company>`, `--full` (fresh
  baseline instead of a delta), `--print` (build and print, upload nothing),
  `--respect-throttle` (honour the 24-hour per-scope throttle).
- `HQ_SYNC_MANIFEST_DISABLED=1` (or `true`) turns uploads off on a machine.
- `hq doctor` reads when each scope last uploaded.

## Session logs

Two separate mechanisms:

- **Harness transcripts.** `hq reindex` copies Claude Code, Codex, and Grok
  session logs for this HQ tree into `workspace/.session-logs/<harness>/`.
  That path is pushed to the personal vault and never auto-pulled, in any
  mode. After an upload is confirmed, the local copy is deleted after 7 days.
  `HQ_SESSION_LOG_LOCAL_RETENTION_DAYS=<n>` changes the window; `off` disables
  pruning.
- **Company `sessions/` prefix.** Session transcripts pushed into a company
  vault under `sessions/{personUid}/` are never auto-pulled onto other
  machines, including in `all` mode. Fetch one with `hq files get`, which pins
  it.

## Background services: `hq daemon` and `hq mesh daemon`

`hq mesh daemon` is the Work Mesh Live process: spool drainer plus MQTT
presence. It can be installed on its own (`hq mesh daemon install`) as a
LaunchAgent, systemd user unit, or Scheduled Task. See `work-mesh-live.md`.

`hq daemon` (added 2026-09-24, hidden from `hq --help`) is one supervisor for
all of a machine's HQ background services. Its `mesh` service runs
`hq mesh daemon run` as a child process, so the mesh daemon becomes one of its
units. Services (`src/lib/daemon/catalog.ts`):

| Service | Purpose |
|---|---|
| `sync` | Runs hq-cloud's sync runner with `--companies --direction both --on-conflict keep --watch --event-push` |
| `mesh` | Work Mesh Live presence (`hq mesh daemon run`) |
| `heartbeat` | Reports machine status (not yet available on desktop machines) |
| `inbox` | Agent inbox (agent machines) |
| `bots` | Local bots |
| `remote-control`, `codex-remote-control` | Keep Claude / Codex remote control running |
| `session-host` | Lets the desktop app open this machine's Claude sessions |
| `lanes-reconcile` | Cleans up stalled lanes |
| `search-index` | Keeps the local qmd index current |
| `jobs-reconcile` | Matches scheduled jobs to the cloud |
| `updater` | Updates the hq CLI, Claude, Codex, and Grok |
| `housekeeping` | Rotates daemon logs |

Defaults depend on machine type (`desktop`, `self-hosted`, `outpost`,
`agent-box`, `agent-kit`). A desktop gets `sync`, `mesh`, `heartbeat`, `bots`,
`lanes-reconcile`, `search-index`, `updater`, `housekeeping`. The `sync`
service stays blocked when the HQ desktop app is handling sync on that
machine, when no HQ folder is configured, or when not signed in.

Useful verbs: `install [--machine-type]`, `status`, `logs`, `enable`/`disable
<services>`, `trigger <unit>`, `migrate [--apply]` (takes over older
standalone units such as a separately installed mesh daemon),
`pin-hq-cloud [version|--clear]`.

The daemon runs sync from whichever hq-cloud is newer: the copy bundled in the
CLI or a same-major copy the updater keeps in the daemon directory, unless
`pin-hq-cloud` pins a version.

## Desktop app runner version

The desktop app does not run `@latest`. It launches
`npx --package=@indigoai-us/hq-cloud@~6.18.5 hq-sync-runner`, with the range
set by `HQ_CLOUD_VERSION` in
`crates/hq-desktop-core/src/hq_cloud.rs`. `~6.18.5` accepts 6.18.5 up to, but
not including, 6.19.0. npx caches by the literal spec string, so an install
keeps its cached resolution until that constant changes; raising the floor is
how a runner fix reaches existing desktops. The CLI at the same date depends on
hq-cloud `~6.18.10`.

## Sources

- `indigoai-us/hq-cloud@e486a79`: `src/ignore.ts`, `src/sync/pull-scope.ts`,
  `src/personal-vault.ts`, `src/personal-vault-exclusions.ts`,
  `src/lib/cloud-authoritative.ts`, `src/lib/conflict-file.ts`,
  `src/cli/conflict.ts`, `src/journal.ts`, `src/journal-snapshot-v4.ts`,
  `src/sync/state-store.ts`, `src/session-log-retention.ts`,
  `src/session-log-capture.ts`, `src/cli/reindex.ts`, `docs/sync-manifest.md`,
  `CHANGELOG.md`.
- `indigoai-us/hq-cli@dfe49a4`: `src/command-catalog.generated.ts` (sync,
  cloud, daemon, mesh, files options), `src/lib/daemon/catalog.ts`,
  `src/lib/daemon/hq-cloud.ts`, `package.json`, git log for
  `src/commands/daemon.ts` and `src/commands/cloud-retire.ts`.
- `indigoai-us/hq-desktop-app@c621a6a`:
  `crates/hq-desktop-core/src/hq_cloud.rs` (`HQ_CLOUD_VERSION`),
  `crates/hq-desktop-core/src/daemon.rs`.
