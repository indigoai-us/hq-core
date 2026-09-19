---
name: hq-sync
description: Run a full bidirectional sync for cloud-backed HQ companies.
allowed-tools: Bash, Read, Bash(. .claude/skills/hq-sync/scripts/hq-sync-events.sh:*)
---

# /hq-sync — Full HQ sync from the CLI

Runs the same sync engine the HQ Desktop App uses, from the
terminal. Walks every cloud-backed company in your local HQ, syncs in
both directions against the vault, and writes conflict mirror files +
`<hqRoot>/.hq-conflicts/index.json` when divergence is detected so
`/resolve-conflicts` can walk them.

**Args:** `$ARGUMENTS` — optional flags. Defaults: `--direction both --on-conflict keep`.

## What you do

### Step 1 — Resolve HQ root

The same 4-tier resolver the HQ Desktop App uses:

1. `~/.hq/menubar.json` `hqPath` (canonical, written by hq-installer ≥0.1.28)
2. `~/.hq/config.json` `hqFolderPath` (legacy installer path)
3. Discovery via `core/core.yaml` signature in `~/HQ`, `~/hq`, `~/Documents/HQ`, `~/Documents/hq`, `~/Desktop/HQ`, `~/Desktop/hq` (first match wins)
4. `~/HQ` (last-resort default)

Fast path: if cwd contains a `core/core.yaml`, use cwd. Otherwise read `~/.hq/menubar.json`.

### Step 2 — Auth check

Confirm `~/.hq/cognito-tokens.json` exists. If it is absent, tell the user
"Not signed in — run /hq-login" and exit 2.

Do not inspect the token's contents or judge whether it is expired. The runner
owns token validity: it refreshes an expired access token from the stored
refresh token on its own, and `expiresAt` is typed `string | number`, so any
arithmetic here is both redundant and liable to fail on the ISO-string form.
When the runner cannot get a valid token it emits an `auth-error` event on
stderr — that event, not a local clock comparison, is the signal to send the
user to `/hq-login`.

### Step 3 — Spawn the runner

Same invocation as the HQ Desktop App's `commands/sync.rs::HQ_CLOUD_VERSION`:

```bash
npx -y --package=@indigoai-us/hq-cloud@latest hq-sync-runner \
  --companies \
  --direction both \
  --on-conflict keep \
  --hq-root <hqRoot>
```

Apply user-supplied overrides for `--direction` and `--on-conflict` if
present in `$ARGUMENTS`.

Stream stdout (ndjson — one event per line). Show meaningful events to
the user:
- `{"type":"plan", company, direction, filesToDownload, ...}` → "Planning sync for {company} {direction}: {N} files / {M} bytes"
- `{"type":"progress", path, bytes, message?}` → quiet (just count)
- `{"type":"conflict", path, direction, resolution}` → "⚠️ Conflict: {path} ({direction}) — {resolution}"
- `{"type":"complete", company, filesDownloaded, filesUploaded, conflicts, ...}` → "✓ {company}: {filesDownloaded}↓ {filesUploaded}↑ {conflicts}⚠"
- `{"type":"all-complete", companiesAttempted, conflictPaths, errors, partial, transient, companies}` → final summary. `partial` and `companies[].status` are the canonical completeness signals — see Step 4.
- `{"type":"conflicts-remaining", count, samplePaths}` → emitted once after
  `all-complete` when the post-sync ledger prune preserved conflict rows a
  human still has to resolve. See Step 4.
- `{"type":"setup-needed", reason, pendingInviteCount?}` → the run could not
  proceed. NOT a silent success — see Step 5b.

On stderr:
- `{"type":"auth-error", message}` → no valid token. Print
  "Not signed in — run /hq-login" and exit 2.
- `{"type":"error", ...}` → per-file or per-company diagnostics, surfaced at
  Step 5d.

### Step 4 — Final summary

Print the totals from `all-complete`:

```
=== Summary ===
Companies synced: N
Files: D ↓ / U ↑
Conflicts: K
Errors: E
```

If `K === 0`, omit the conflicts list and the `/resolve-conflicts` suggestion.
If `errors[]` is non-empty, list each entry.

Then report completeness honestly. `errors.length > 0` is not sufficient: a
company that cleanly conflict-aborted never lands in `errors`. Read `partial`
and `companies[].status`. When `partial` is true, list every company whose
status is not `complete` with that status (`aborted`, `errored`, or
`transient-network`), list the `transient[]` diagnostics, and exit 3.

Map the runner's exit codes to plain language:

| Runner exit | What it means | What the skill prints |
|---|---|---|
| 0 | the protocol finished | the summary above |
| 1 | bad arguments, or a failure before the sync started | the runner's diagnostics |
| 2 | at least one company failed deterministically | the partial block |
| 75 | a retryable network failure interrupted the run | "The network interrupted the sync. Nothing is corrupt. Run /hq-sync again." |

The skill's own exit codes: 0 clean, 2 not signed in, 3 partial (at least one
company did not complete), and the runner's code passed through otherwise.

Finally, report conflict residue from both places it lives:

- The `conflicts-remaining` event carries the ledger rows the post-sync prune
  preserved. Print `count`, the sample paths, and the `/resolve-conflicts`
  pointer.
- Legacy `.conflict-<timestamp>-<machine>` twins sit on disk outside the
  ledger, so `/resolve-conflicts` cannot see them. Count them under the HQ root
  (skipping `node_modules`, `.git`, and `workspace/tmp`) and, when the count is
  nonzero, print it with the command that previews folding them back:

```
hq sync doctor --reconcile-conflicts --hq-root <hqRoot>
```

That form is a dry run; it reports what it would do and changes nothing.
Adding `--yes` is what applies it.

## Implementation

```bash
set -euo pipefail

# Step 1: resolve HQ root
hq_root=""
if [ -f "$PWD/core/core.yaml" ]; then
  hq_root="$PWD"
elif [ -f "$HOME/.hq/menubar.json" ]; then
  hq_root="$(jq -r '.hqPath // empty' "$HOME/.hq/menubar.json" 2>/dev/null || true)"
fi
if [ -z "$hq_root" ] && [ -f "$HOME/.hq/config.json" ]; then
  hq_root="$(jq -r '.hqFolderPath // empty' "$HOME/.hq/config.json" 2>/dev/null || true)"
fi
if [ -z "$hq_root" ]; then
  for d in "$HOME/HQ" "$HOME/hq" "$HOME/Documents/HQ" "$HOME/Documents/hq" "$HOME/Desktop/HQ" "$HOME/Desktop/hq"; do
    if [ -f "$d/core/core.yaml" ]; then hq_root="$d"; break; fi
  done
fi
if [ -z "$hq_root" ]; then
  echo "ERROR: no HQ folder found — run from inside an HQ tree, or set ~/.hq/menubar.json hqPath" >&2
  exit 1
fi
echo "HQ root: $hq_root"

# Event handling lives in a sibling script so the code path a user gets is the
# one the test suite exercises against recorded ndjson fixtures
# (the tests folder beside this skill). The skill body runs pasted into a shell,
# so BASH_SOURCE may not point at the skill folder — the resolved HQ root is the
# reliable anchor, with the per-user skills tree as the fallback. Source it with
# one plain command, run from the directory that holds it, so allowed-tools can
# name that exact command instead of a shell construct.
events_home="$hq_root"
test -f "$hq_root/.claude/skills/hq-sync/scripts/hq-sync-events.sh" || events_home="$HOME"
cd "$events_home"
# shellcheck source=/dev/null
. .claude/skills/hq-sync/scripts/hq-sync-events.sh || true
cd "$hq_root"
if ! command -v hq_sync_report_summary >/dev/null 2>&1; then
  echo "ERROR: hq-sync-events.sh not found — reinstall the hq-sync skill" >&2
  exit 1
fi

# Step 2: auth check. File presence only — the runner owns token validity. It
# refreshes an expired access token from the stored refresh token, and the
# expiresAt field is typed `string | number`, so comparing it here both
# duplicated that logic and died under `set -e` on the ISO-string form. An
# actually-unusable token arrives as an `auth-error` event, handled at Step 4b.
if [ ! -f "$HOME/.hq/cognito-tokens.json" ]; then
  hq_sync_print_auth_error
  exit 2
fi

# Step 3: parse user args (defaults match the HQ Desktop App). We expand $ARGUMENTS into
# positional args so the standard while-case parser works under both bash and zsh.
direction="both"
on_conflict="keep"
if [ -n "${ARGUMENTS:-}" ]; then
  # shellcheck disable=SC2086 — intentional word-split of ARGUMENTS
  set -- $ARGUMENTS
  while [ $# -gt 0 ]; do
    case "$1" in
      --direction) direction="${2:-both}"; shift 2 ;;
      --on-conflict) on_conflict="${2:-keep}"; shift 2 ;;
      *) shift ;;
    esac
  done
fi

# Step 4: spawn the runner. `set -o pipefail` is the portable way to capture
# the exit status of the LEFT side of `| tee` under both bash and zsh —
# avoids ${PIPESTATUS[0]} (bash-only) and ${pipestatus[1]} (zsh-only, 1-based).
echo "Spawning hq-sync-runner (this is the same engine the HQ Desktop App uses)..."
output_file="$(mktemp)"
# Keep stderr in its own file. Folding it into stdout with `2>&1` left the
# runner's diagnostics (claim-dance skips, manifest reconciliation) buried in
# the ndjson stream where nobody read them — the failures that make a joiner
# look solo were being reported and then lost.
err_file="$(mktemp)"
set +e
set -o pipefail 2>/dev/null || true
npx -y --package=@indigoai-us/hq-cloud@latest hq-sync-runner \
  --companies \
  --direction "$direction" \
  --on-conflict "$on_conflict" \
  --hq-root "$hq_root" 2>"$err_file" | tee "$output_file"
# zsh reserves $status (mirrors $?), so we use cli_status to avoid
# `read-only variable: status` errors when the slash command runs under zsh.
cli_status=$?
set +o pipefail 2>/dev/null || true
set -e

# Step 4b: auth-error. The runner routes it to stderr, so it never reaches the
# ndjson stream on stdout. This is the only expired/absent-token signal the
# skill trusts.
if hq_sync_has_auth_error "$err_file"; then
  hq_sync_print_auth_error
  rm -f "$output_file" "$err_file"
  exit 2
fi

# Step 5: summary + honest completeness read. hq_sync_report_summary returns
# HQ_SYNC_PARTIAL_EXIT when the runner reported partial: true, so the `||`
# keeps `set -e` from killing the script on that expected status.
final_event="$(grep -E '^\{"type":"all-complete"' "$output_file" | tail -1 || true)"
files_d=0
if [ -n "$final_event" ]; then
  files_d=$(printf '%s' "$final_event" | jq -r '.filesDownloaded // 0' 2>/dev/null || echo 0)
fi
summary_status=0
hq_sync_report_summary "$output_file" || summary_status=$?

# Step 5b: setup-needed. The runner exits 0 here on purpose (a non-zero exit
# would make the watch loop report spurious crashes), so without this branch a
# user who is blocked sees a silent, successful-looking run.
setup_event="$(grep -E '^\{"type":"setup-needed"' "$output_file" | tail -1 || true)"
if [ -n "$setup_event" ]; then
  # This whole script runs under `set -euo pipefail`. The grep above matches on
  # a PREFIX, so a line truncated mid-write still reaches jq — and then jq exits
  # non-zero, the command substitution inherits that status, and `set -e` kills
  # the script. That would take out the one branch whose entire job is to stop a
  # blocked user from seeing a silent, successful-looking run. Never let parsing
  # the diagnostic be the thing that suppresses the diagnostic.
  reason=$(printf '%s' "$setup_event" | jq -r '.reason // "unknown"' 2>/dev/null || echo "unknown")
  pending=$(printf '%s' "$setup_event" | jq -r '.pendingInviteCount // 0' 2>/dev/null || echo 0)
  # `[ "$pending" -gt 0 ]` needs an integer. jq yields a non-numeric if the field
  # is ever sent as a string, and an empty string if the parse failed above.
  case "$pending" in ''|*[!0-9]*) pending=0 ;; esac

  echo ""
  echo "=== Sync could not complete ==="
  if [ "$pending" -gt 0 ]; then
    echo "You have $pending invite(s) waiting to be accepted — that is why no"
    echo "company synced. You are NOT solo."
    echo ""
    echo "Run: /accept <link-or-token>"
    echo "Then re-run /hq-sync."
  else
    case "$reason" in
      no-memberships)
        echo "You are signed in, but you do not belong to any cloud company yet."
        echo "If you were expecting an invite, ask whoever invited you to re-send"
        echo "it, then run /accept <link-or-token>."
        ;;
      no-person-entity)
        echo "You are signed in, but you have no personal entity to sync into."
        echo "This usually means a legacy magic-link invite that still needs"
        echo "redeeming: /accept <link-or-token>"
        ;;
      *)
        echo "The runner reported it could not proceed, without a reason"
        echo "(reason: $reason). This is usually an older runner. Try"
        echo "/accept <link-or-token> if you are expecting an invite."
        ;;
    esac
  fi
fi

# Step 5c: neither event. Say so — a run that reports nothing is not a success,
# and silently treating it as one is how a broken sync passes for a clean one.
if [ -z "${final_event:-}" ] && [ -z "${setup_event:-}" ]; then
  echo ""
  echo "=== Sync finished without a final status ==="
  echo "The runner emitted neither all-complete nor setup-needed (exit"
  echo "$cli_status). Treat this as an incomplete sync, not a clean one."
fi

# Step 5d: surface the runner's diagnostics. These are the breadcrumbs for
# "why did nothing land" — claim-dance skips, manifest reconciliation, and
# activeCompany seeding all report here.
if [ -s "$err_file" ]; then
  echo ""
  echo "=== Runner diagnostics ==="
  cat "$err_file"
fi

# Step 5e: conflict residue. Two sources, because they disagree: the runner's
# conflicts-remaining event covers ledger rows the post-sync prune preserved,
# while legacy `.conflict-*` twins sit on disk outside the ledger where
# /resolve-conflicts cannot reach them.
hq_sync_report_conflicts_remaining "$output_file" "$hq_root" || true

# Step 6: reindex qmd so freshly-synced knowledge is searchable immediately.
# Lexical update is fast (mtime-incremental) and auto-registers any new
# company knowledge collection — kills the "I forgot to re-index after sync"
# divergence between teammates. Embeddings are deferred (no --embed) to keep
# sync snappy. Best-effort: never let reindex mask the sync exit code.
if [ -z "${final_event:-}" ] || [ "${files_d:-0}" != "0" ]; then
  hq core qmd-reindex-after-sync "$hq_root" >/dev/null 2>&1 || true
fi

# Step 6b: regenerate the workers registry after a completed sync.
# `hq reindex` is path-gated on in-session Write/Edit/rm and does not run
# after an out-of-band pull, so a stale core/workers/registry.yaml can list
# active workers whose directories were never downloaded (or were pruned).
# The generator is derived from worker.yaml files on disk: new workers appear,
# missing directories drop. Best-effort; never mask sync.
hq core --hq-root "$hq_root" generate-workers-registry >/dev/null 2>&1 || true

# Step 7: exit. A partial run is not a clean one, so exit 3 (documented in
# scripts/hq-sync-events.sh) even when the runner itself exited 0 after a clean
# conflict-abort. Exit 75 is retryable and gets a plain explanation before the
# code is passed through.
hq_sync_exit_note "$cli_status"
rm -f "$output_file" "$err_file"
if [ "$summary_status" != "0" ]; then
  exit "$summary_status"
fi
exit "$cli_status"
```

## Notes

- Uses the **same `hq-sync-runner` invocation pattern** as the HQ Desktop App (`commands/sync.rs::HQ_CLOUD_VERSION`). The npx pin to `@latest` matches the HQ Desktop App's runtime spawn so behavior stays consistent across the two surfaces.
- `--on-conflict keep` is the default — local wins on divergence, cloud version mirrored to a `.conflict-*` sidecar so `/resolve-conflicts` can walk it later. Same default the HQ Desktop App uses.
- Auth is shared with `/deploy`, `/designate-team`, `/hq-login`, and the HQ Desktop App — single Cognito token at `~/.hq/cognito-tokens.json`.
- For a single-company sync, use `hq sync push <company>` (already in hq-cli) — this command is the "all companies, both directions" full sync that the HQ Desktop App runs.
- **Post-sync qmd reindex (Step 6):** after a sync that pulled files, the skill runs `hq core qmd-reindex-after-sync`, which auto-registers any new company knowledge collection and runs an incremental lexical `qmd update`. This is what makes freshly-synced knowledge searchable without a manual re-index, and keeps teammates' personal indexes converged. Embeddings are intentionally deferred (run `qmd embed`, or the reindex script with `--embed`, on an idle pass) so sync stays fast. The qmd index is per-machine (large binary, absolute local paths) and is **not** itself synced — only its freshness is automated. The HQ Desktop App sync gets the same behavior via the `hq-sync-runner` seam.
- **Post-sync workers registry (Step 6b):** after a completed sync, regenerate `core/workers/registry.yaml` from on-disk `worker.yaml` files. A pulled worker must become listable, and a registry row whose directory was not downloaded must not stay discoverable. SessionStart also warns if any `status: active` path is still absent.

- **Selective download (`syncMode`) — access ≠ download.** What a sync *downloads* is governed per-membership by `syncMode`: `all` (full bucket — the default, and what owners get on upgrade), `shared` (only your explicit ACL grants), or `custom` (an explicit prefix list). Set it with `hq sync mode <all|shared|custom>` and narrow an existing local tree with `hq sync narrow`. This is purely about local footprint — it does **not** change your *access*. Owners/admins keep full role-bypass access regardless of mode; `shared`/`custom` just stop a sync from materializing the whole vault locally. The scope is resolved per company in `sync-runner.ts::resolvePullScope` (degrades to `all` on any error so a transient failure never prunes the tree). To reach a file you have access to but didn't download, use `hq files browse`/`cat`/`search`/`get` (see the `hq-files` skill) — no full sync required.

- **Pins keep an on-demand `get` from being pruned.** `hq files get <path>` materializes a path and records it in `<hqRoot>/.hq/pins.json`; `resolvePullScope` unions a company's pins into its `shared`/`custom` pull scope, so a got-file survives subsequent scoped syncs instead of being deleted as an out-of-scope orphan.

- **A single missing or locked path is `/hq-access`, not a full sync.** When one path is absent or returns a 403, run `/hq-access <path>` (or `hq access <path>`): it distinguishes never-created from not-yet-downloaded from access-denied, fetches and pins the file when you have access, repairs sync when the fetch fails, and asks the prefix owner for a grant when it does not.
