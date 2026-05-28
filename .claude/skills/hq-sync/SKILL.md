---
name: hq-sync
description: Run a full HQ sync (all cloud-backed companies, bidirectional) — same engine as AppBar HQ Sync
allowed-tools: Bash, Read
---

# /hq-sync — Full HQ sync from the CLI

Runs the same sync engine the AppBar HQ Sync menubar app uses, from the
terminal. Walks every cloud-backed company in your local HQ, syncs in
both directions against the vault, and writes conflict mirror files +
`<hqRoot>/.hq-conflicts/index.json` when divergence is detected so
`/resolve-conflicts` can walk them.

**Args:** `$ARGUMENTS` — optional flags. Defaults: `--direction both --on-conflict keep`.

## What you do

### Step 1 — Resolve HQ root

The same 4-tier resolver AppBar uses:

1. `~/.hq/menubar.json` `hqPath` (canonical, written by hq-installer ≥0.1.28)
2. `~/.hq/config.json` `hqFolderPath` (legacy installer path)
3. Discovery via `core/core.yaml` signature in `~/HQ`, `~/hq`, `~/Documents/HQ`, `~/Documents/hq`, `~/Desktop/HQ`, `~/Desktop/hq` (first match wins)
4. `~/HQ` (last-resort default)

Fast path: if cwd contains a `core/core.yaml`, use cwd. Otherwise read `~/.hq/menubar.json`.

### Step 2 — Auth check

Confirm `~/.hq/cognito-tokens.json` exists and isn't expired. If absent or
expired, tell the user "Not signed in — run /hq-login first" and stop.

### Step 3 — Spawn the runner

Same invocation as AppBar's `commands/sync.rs::HQ_CLOUD_VERSION`:

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

# Step 3: parse user args (defaults match AppBar). We expand $ARGUMENTS into
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
echo "Spawning hq-sync-runner (this is the same engine AppBar uses)..."
output_file="$(mktemp)"
set +e
set -o pipefail 2>/dev/null || true
npx -y --package=@indigoai-us/hq-cloud@latest hq-sync-runner \
  --companies \
  --direction "$direction" \
  --on-conflict "$on_conflict" \
  --hq-root "$hq_root" 2>&1 | tee "$output_file"
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

- Uses the **same `hq-sync-runner` invocation pattern** as AppBar HQ Sync (`commands/sync.rs::HQ_CLOUD_VERSION`). The npx pin to `@latest` matches AppBar's runtime spawn so behavior stays consistent across the two surfaces.
- `--on-conflict keep` is the default — local wins on divergence, cloud version mirrored to a `.conflict-*` sidecar so `/resolve-conflicts` can walk it later. Same default AppBar uses.
- Auth is shared with `/deploy`, `/designate-team`, `/hq-login`, AppBar — single Cognito token at `~/.hq/cognito-tokens.json`.
- For a single-company sync, use `hq sync push <company>` (already in hq-cli) — this command is the "all companies, both directions" full sync that AppBar runs.
- **Post-sync qmd reindex (Step 6):** after a sync that pulled files, the skill runs `core/scripts/qmd-reindex-after-sync.sh`, which auto-registers any new company knowledge collection and runs an incremental lexical `qmd update`. This is what makes freshly-synced knowledge searchable without a manual re-index, and keeps teammates' personal indexes converged. Embeddings are intentionally deferred (run `qmd embed`, or the reindex script with `--embed`, on an idle pass) so sync stays fast. The qmd index is per-machine (large binary, absolute local paths) and is **not** itself synced — only its freshness is automated. The AppBar menubar sync gets the same behavior via the `hq-sync-runner` seam (see `repos/private/hq-cloud/src/bin/sync-runner.ts`).
