---
name: update-hq
description: Upgrade HQ from the latest hq-core release.
allowed-tools: Read, Bash, Bash(bash core/scripts/check-hq-hooks.sh:*), AskUserQuestion
---

# /update-hq — HQ Upgrade

Upgrade your HQ installation from the latest `indigoai-us/hq-core` release by delegating to **`hq rescue`**, the canonical drift-preserving updater. `hq rescue` re-syncs your HQ core to the target release using a three-way merge that preserves your local edits, takes a pre-op safety snapshot, and reports what changed.

**User's input:** $ARGUMENTS

## Why `hq rescue`

`/update-hq` used to hand-roll the upgrade: fetch `MIGRATION.md`, parse migration sections, then three-way-merge each file one at a time over `gh api`. `hq rescue` does all of that natively and more reliably — it classifies every core path (clean / drifted / locally-added), three-way merges drift against the release, force-takes infrastructure files that must not carry conflict markers, snapshots to `~/.hq/backups` first, and prints a single summary. This skill now just maps your arguments onto `hq rescue` flags, previews the plan, and surfaces the result.

## Argument parsing

Map `$ARGUMENTS` onto `hq rescue` flags:

| User input | `hq rescue` flag | Meaning |
|---|---|---|
| `--check` / `--dry-run` | `--check` | Plan only — classify and report, change nothing on disk |
| `v{X.Y.Z}` (bare version) | `--ref v{X.Y.Z}` | Upgrade to a specific release instead of latest |
| `--ref <ref>` | `--ref <ref>` | Target tag/branch (default: latest hq-core release) |
| `--staging` | `--staging` | Use the staging release channel |
| `--source <repo>` | `--source <repo>` | Override the source repo |
| `--paths <list>` | `--paths <list>` | Narrow the rescue to comma-separated top-level paths |
| `--floor-sha <sha>` | `--floor-sha <sha>` | Pin the three-way history floor to a 40-char commit SHA |
| `--no-backup` | `--no-backup` | Skip the pre-op snapshot (default: keep it) |
| `-y` / `--yes` | `-y` | Skip the confirmation prompt |
| `--hq-root <path>` | `--hq-root <path>` | Operate on a specific HQ root (defaults to auto-detected) |

The legacy `--from v{X.Y.Z}` flag is gone — `hq rescue` detects the three-way history floor automatically. Pin it manually with `--floor-sha` only if the user explicitly asks.

## Phase 1: Preflight

Verify the `hq` CLI is available:
```bash
command -v hq
```
If it is missing, hard stop and tell the user to install the HQ CLI (e.g. `npm i -g @indigoai-us/hq-cli`, or per their install method) before re-running `/update-hq`.

## Phase 2: Plan (always dry-run first)

Always preview before applying. Run rescue in check mode with the user's mapped flags:
```bash
hq rescue --check {mapped-flags}
```
Surface the plan in plain terms: the target release, how many paths are clean vs. carry local drift vs. are locally added, and anything rescue flags for manual review.

If the user passed `--check` / `--dry-run`, **stop here** — report the plan and write nothing.

## Phase 3: Confirm and apply

If this is not a dry run, confirm with `AskUserQuestion` (skip the prompt only if the user already passed `-y` / `--yes`):

1. Apply this upgrade (recommended)
2. Cancel

On confirm, apply — pass `-y` so rescue does not re-prompt, since the user just confirmed here:
```bash
hq rescue -y {mapped-flags}
```

Keep the pre-op backup: do **not** pass `--no-backup` unless the user explicitly asked for it. `hq rescue` writes a snapshot under `~/.hq/backups` before touching anything, which is the recovery path if a merge goes wrong.

## Phase 4: Verify project hooks, repair if needed, and report

`hq rescue` preserves user drift and replaces release-owned paths. The terminal
CLI can run HQ hooks only when the resulting project still has
`.claude/settings.json` and loads it as a project setting source. Check that
postcondition with the hook-independent checker:

```bash
bash core/scripts/check-hq-hooks.sh --root {hq-root}
```

If it reports a missing/invalid settings file or missing `SessionStart` or
`PreToolUse` hook, repair the released `.claude` tree and check again. Keep any
other mapped release flags such as `--ref` / `--staging`; omit a user-provided
`--paths` restriction because this repair must include `.claude`:

```bash
hq rescue -y --paths .claude {mapped release flags}
bash core/scripts/check-hq-hooks.sh --root {hq-root}
```

If the second check fails, stop and report its exact diagnostics; do not claim
the update completed successfully. See `core/docs/hq/HOOKS-NOT-FIRING.md` for
the Desktop/SDK cwd and `settingSources` recovery instructions.

After a real terminal CLI session, the user can additionally prove the
policy-trigger hook actually ran:

```bash
bash core/scripts/check-hq-hooks.sh --root {hq-root} --require-ledger
```

The affected Claude Code app/SDK runtime does not dispatch command-hook events,
even with valid project settings. `settingSources: ["project"]` can load native
project context but cannot make that runtime enforce shell hooks. The durable
`.claude/personal-context.md` import remains available there; use host-side
enforcement or terminal Claude Code for work that requires a mechanical block.

Then relay rescue's summary in plain language: what was updated, what kept
local edits, hook-health status, and anything that needs manual follow-up.
Refresh the search index so new/renamed content is findable:

```bash
qmd update 2>/dev/null || true
```

## Rules

- **Delegate to `hq rescue`** — never hand-roll the migration. No `gh api` fetch/parse/merge loop, no `MIGRATION.md` parsing. `hq rescue` is the single source of truth for upgrades.
- **Always dry-run first** — run `hq rescue --check` and show the plan before applying, unless the user passed `-y` / `--yes`.
- **Preserve drift** — `hq rescue` three-way merges local edits by default. Never pass `--no-backup` and never force an overwrite unless the user explicitly asks.
- **`hq` CLI required** — hard stop if `hq` is not installed.
- **Staging is opt-in** — only pass `--staging` when the user asks for the staging release; default is the latest stable hq-core release.
- **Idempotent** — rescue compares against the release; re-running when already current is a safe no-op.
- **Keep the backup** — the snapshot under `~/.hq/backups` is the only easy revert path; don't skip it on the user's behalf.

## See also

- `/sync-registry` — refresh skill/worker indexes
- `/promote` — publish your local changes
