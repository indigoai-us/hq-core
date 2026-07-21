---
name: hq-sync
description: Run a full bidirectional sync for cloud-backed HQ companies.
allowed-tools: Bash, Read
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

Confirm `~/.hq/cognito-tokens.json` exists and isn't expired. If absent or
expired, tell the user "Not signed in — run /hq-login first" and stop.

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
- `{"type":"all-complete", companiesAttempted, conflictPaths, errors}` → final summary
- `{"type":"setup-needed", reason, pendingInviteCount?}` → the run could not
  proceed. NOT a silent success — see Step 5b.

### Step 4 — Final summary

Print:

```
Synced N companies. M files transferred. K conflicts.

Conflicts:
  - companies/foo/bar.md (pull)
  - ...

Run /resolve-conflicts to walk pending conflicts.
```

If `K === 0`, omit the conflicts list and `/resolve-conflicts` suggestion.

If `errors[]` is non-empty, surface them in red.

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

# Step 2: auth check
if [ ! -f "$HOME/.hq/cognito-tokens.json" ]; then
  echo "ERROR: not signed in — run /hq-login first" >&2
  exit 2
fi
expires_ms="$(jq -r '.expiresAt // 0' "$HOME/.hq/cognito-tokens.json")"
now_ms=$(($(date +%s) * 1000))
if [ "$expires_ms" -le "$now_ms" ]; then
  echo "ERROR: HQ session expired — run /hq-login to refresh" >&2
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

# Step 5: parse final all-complete event for summary
final_event="$(grep -E '^\{"type":"all-complete"' "$output_file" | tail -1 || true)"
if [ -n "$final_event" ]; then
  companies=$(printf '%s' "$final_event" | jq -r '.companiesAttempted // 0')
  files_d=$(printf '%s' "$final_event" | jq -r '.filesDownloaded // 0')
  files_u=$(printf '%s' "$final_event" | jq -r '.filesUploaded // 0')
  conflicts=$(printf '%s' "$final_event" | jq -r '.conflictPaths | length')
  errors=$(printf '%s' "$final_event" | jq -r '.errors | length')

  echo ""
  echo "=== Summary ==="
  echo "Companies synced: $companies"
  echo "Files: $files_d ↓ / $files_u ↑"
  echo "Conflicts: $conflicts"
  echo "Errors: $errors"

  if [ "$conflicts" -gt 0 ]; then
    echo ""
    echo "Conflicts:"
    printf '%s' "$final_event" | jq -r '.conflictPaths[] | "  - \(.company)/\(.path) (\(.direction))"'
    echo ""
    echo "Run /resolve-conflicts to walk them interactively."
  fi
fi

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

# Step 6: reindex qmd so freshly-synced knowledge is searchable immediately.
# Lexical update is fast (mtime-incremental) and auto-registers any new
# company knowledge collection — kills the "I forgot to re-index after sync"
# divergence between teammates. Embeddings are deferred (no --embed) to keep
# sync snappy. Best-effort: never let reindex mask the sync exit code.
if [ -z "${final_event:-}" ] || [ "${files_d:-0}" != "0" ]; then
  bash "$hq_root/core/scripts/qmd-reindex-after-sync.sh" "$hq_root" >/dev/null 2>&1 || true
fi

rm -f "$output_file"
exit "$cli_status"
```

## Notes

- Uses the **same `hq-sync-runner` invocation pattern** as the HQ Desktop App (`commands/sync.rs::HQ_CLOUD_VERSION`). The npx pin to `@latest` matches the HQ Desktop App's runtime spawn so behavior stays consistent across the two surfaces.
- `--on-conflict keep` is the default — local wins on divergence, cloud version mirrored to a `.conflict-*` sidecar so `/resolve-conflicts` can walk it later. Same default the HQ Desktop App uses.
- Auth is shared with `/deploy`, `/designate-team`, `/hq-login`, and the HQ Desktop App — single Cognito token at `~/.hq/cognito-tokens.json`.
- For a single-company sync, use `hq sync push <company>` (already in hq-cli) — this command is the "all companies, both directions" full sync that the HQ Desktop App runs.
- **Post-sync qmd reindex (Step 6):** after a sync that pulled files, the skill runs `core/scripts/qmd-reindex-after-sync.sh`, which auto-registers any new company knowledge collection and runs an incremental lexical `qmd update`. This is what makes freshly-synced knowledge searchable without a manual re-index, and keeps teammates' personal indexes converged. Embeddings are intentionally deferred (run `qmd embed`, or the reindex script with `--embed`, on an idle pass) so sync stays fast. The qmd index is per-machine (large binary, absolute local paths) and is **not** itself synced — only its freshness is automated. The HQ Desktop App sync gets the same behavior via the `hq-sync-runner` seam.

- **Selective download (`syncMode`) — access ≠ download.** What a sync *downloads* is governed per-membership by `syncMode`: `all` (full bucket — the default, and what owners get on upgrade), `shared` (only your explicit ACL grants), or `custom` (an explicit prefix list). Set it with `hq sync mode <all|shared|custom>` and narrow an existing local tree with `hq sync narrow`. This is purely about local footprint — it does **not** change your *access*. Owners/admins keep full role-bypass access regardless of mode; `shared`/`custom` just stop a sync from materializing the whole vault locally. The scope is resolved per company in `sync-runner.ts::resolvePullScope` (degrades to `all` on any error so a transient failure never prunes the tree). To reach a file you have access to but didn't download, use `hq files browse`/`cat`/`search`/`get` (see the `hq-files` skill) — no full sync required.

- **Pins keep an on-demand `get` from being pruned.** `hq files get <path>` materializes a path and records it in `<hqRoot>/.hq/pins.json`; `resolvePullScope` unions a company's pins into its `shared`/`custom` pull scope, so a got-file survives subsequent scoped syncs instead of being deleted as an out-of-scope orphan.
