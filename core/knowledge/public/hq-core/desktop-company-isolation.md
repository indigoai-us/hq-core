---
type: reference
domain: [engineering, operations]
status: canonical
tags: [desktop-app, company-isolation, scope-gate, company-home-channel, secrets]
relates_to: [knowledge/public/hq-core/hq-desktop-app.md]
verified_against:
  - repo: hq-desktop-app
    ref: origin/main@c621a6a1
    app_version: 0.10.347
    date: 2026-09-27
---

# Company Isolation in HQ Desktop

How HQ Desktop keeps one company's files, channels and credentials apart from
another's. This replaces an earlier version of this page that described a
React `CompanyContext` design and stated that Desktop had no isolation
enforcement. That React app was not shipped; enforcement has existed since
2026-07-31 (hq-desktop-app PR #309).

## Company scope gate

`crates/hq-desktop-core/src/scope_gate.rs` exposes
`enforce_read_scope(rel_path, active_company)`. It mirrors the CLI's
mandatory-scope-authorizer hook.

Rules, applied to an HQ-relative path after normalising `\` to `/` and
resolving `.` and `..` segments:

| Path | No company bound | Company `A` bound |
|---|---|---|
| Outside `companies/` (for example `core/`, `personal/`, `repos/`) | allowed | allowed |
| `companies/manifest.yaml` (also `.yml`, `.json`) | allowed | allowed |
| `companies/_template/…` | allowed | allowed |
| `companies/A/…` | refused: "company scope not bound" | allowed |
| `companies/B/…` (any other slug, including `_`-prefixed ones like `_archive`) | refused | refused: "cross-company read blocked" |

### Where the active company comes from

The desktop keeps one active company per app session
(`DesktopSessionScope` in `apps/sync/src-tauri/src/commands/desktop_alt.rs`).
The Files explorer sets it through `set_desktop_active_company` when the user
opens a company vault. Slugs must be lowercase letters, digits, `-` or `_`.
Opening the personal vault does not bind a company.

### Commands that pass through the gate

In `desktop_alt.rs`: `get_company_file_tree`, `get_company_file_content`,
`get_authorized_file_preview`, `reveal_authorized_file`, `reveal_hq_root`,
`open_authorized_file_in_claude`, `list_hq_dir`.
In `vault_explorer.rs`: directory listing and `read_vault_note`.

### Checks that run alongside the gate

- **Membership.** `require_company_file_read_access` refuses a
  `companies/<slug>/` path unless the signed-in user's resolved workspaces
  grant that company ("company files are not authorized").
- **Symlinks.** `require_matching_company_scope` compares the path as written
  with its canonical (symlink-resolved) form and refuses the read if they
  point into different companies ("file path resolves across HQ company
  boundaries").
- **Open in Claude Code.** File hand-off to Claude Code accepts only an
  HQ-relative path, runs the checks above, and builds the prompt and deep link
  itself.

### Limits

- The gate covers desktop file reads. It does not restrict what a coding tool
  or a local bot reads on disk; those are governed by the HQ hooks and
  policies in the tool's own session and by the bot's kind.
- Company bots (`hq bot create --kind company --company <slug>`) act as
  themselves and only reach their companies' files. Personal bots act as the
  owner and reach everything the owner can.

## Company home channels

- Each company has exactly one home channel (company settings, wallpaper).
  Other channels created inside a company are ordinary team channels.
- The app opens the channel the server names as the company's
  `homeChannelId`. If there is none, the row says "No company channel yet."
- The sidebar's Companies section lists home channels: the three most active
  companies by default, or only the pinned ones once any are pinned.
- A company home channel has a Projects tab that shows that company's board.

## Sync scope

- Auto-sync skips companies whose sync is paused on this machine (passed to
  the runner as `HQ_SYNC_SKIP_COMPANIES`) and skips the personal vault when
  personal sync is off (`--skip-personal`).
- A company the user has just joined is pulled automatically, scoped to that
  company.

## Secrets

- The desktop never shows or stores secret values in its UI state or logs.
  Local bots get credentials through the `hq` CLI, which does not print them.
- There is no secret-entry field in the current desktop shell. A company
  Secrets panel (`packages/ui/src/company/SecretsPanel.svelte`) exists in the
  source but is not mounted by the live shell; its actions only open Claude
  Code with a prompt to use the HQ secrets workflow.
- The Tauri command `setup_store_secret` pipes a value into
  `hq secrets set <NAME> --from-stdin [--personal | --company <slug>]`, so the
  value goes field → app → CLI stdin → vault. Its only caller is the secret
  card of the scripted `/setup --guided` run, which the shipped host no longer
  starts.
- In practice, secrets are entered through the HQ secret flows: `/hq-secrets`,
  `hq secrets`, or a one-time entry link from `hq secrets generate-link`. The
  Setup bot follows the same rule and refers to secrets by name only.

## Sources

hq-desktop-app `origin/main@c621a6a1`:

- `crates/hq-desktop-core/src/scope_gate.rs` (and its tests)
- `crates/hq-desktop-core/src/desktop_alt.rs` (`workspace_grants_company_file_read_access`)
- `crates/hq-desktop-core/src/daemon.rs` (`build_watch_runner_args_for_target`)
- `apps/sync/src-tauri/src/commands/desktop_alt.rs` (`DesktopSessionScope`, gated commands)
- `apps/sync/src-tauri/src/commands/vault_explorer.rs`
- `apps/sync/src-tauri/src/commands/setup_secret.rs`
- `packages/ui/src/files/explorer/VaultExplorer.svelte` (`ensureScope`)
- `packages/ui/src/company/SecretsPanel.svelte`, `CompanyOperationsPanel.svelte`
- `CHANGELOG.md` (0.10.322, 0.10.327, 0.10.346)
- `git log -- crates/hq-desktop-core/src/scope_gate.rs` (a321617d, 2026-07-31)
