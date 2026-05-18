#!/bin/bash
# check-hq-update.sh — SessionStart hook
# Compares local hqVersion (core/core.yaml) to the latest GitHub release of
# indigoai-us/hq-core. If a newer release is available, emits a banner
# instructing Claude to spawn a sub-agent task running /update-hq in a
# fresh session.
#
# Cached for 24h in workspace/.hq-update-check/last-check.json to avoid
# hammering GitHub on every session start. Delete the cache file to force
# a re-check.
#
# Always exits 0 — advisory, never a blocker.
#
# Wired in .claude/settings.json SessionStart and gated by hook-gate.sh under "check-hq-update" (standard profile).

# Fail silently on ANY error — this hook is purely advisory and must never
# surface noise, crash the session start, or block other hooks. No `set -e`,
# no `set -u`. Belt-and-suspenders EXIT trap forces a clean exit code; the
# main body runs inside a guarded block that swallows stderr and treats any
# command failure as "skip the banner".
trap 'exit 0' EXIT

# Consume stdin (master-hook passes it even if empty)
cat >/dev/null 2>&1 || true

{

HQ_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)}"
CORE_YAML="$HQ_ROOT/core/core.yaml"
CACHE_DIR="$HQ_ROOT/workspace/.hq-update-check"
CACHE_FILE="$CACHE_DIR/last-check.json"
CACHE_TTL_SECONDS=86400  # 24h

# Skip if core.yaml missing (fresh install or pre-v12)
[ -f "$CORE_YAML" ] || exit 0

# --- Local version ---
LOCAL_VERSION=$(grep -E '^hqVersion:' "$CORE_YAML" 2>/dev/null \
  | head -1 \
  | sed -E 's/^hqVersion:[[:space:]]*["'"'"']?([0-9]+\.[0-9]+\.[0-9]+)["'"'"']?.*/\1/')
[ -n "$LOCAL_VERSION" ] || exit 0

# --- Latest release (cached) ---
LATEST_VERSION=""
USE_CACHE=0

if [ -f "$CACHE_FILE" ]; then
  CACHE_MTIME=$(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  AGE=$((NOW - CACHE_MTIME))
  if [ "$AGE" -lt "$CACHE_TTL_SECONDS" ]; then
    USE_CACHE=1
    LATEST_VERSION=$(grep -oE '"latest":[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$CACHE_FILE" 2>/dev/null \
      | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/' | head -1)
  fi
fi

if [ "$USE_CACHE" -eq 0 ]; then
  command -v gh >/dev/null 2>&1 || exit 0
  gh auth status >/dev/null 2>&1 || exit 0

  RAW_TAG=$(gh release view -R indigoai-us/hq-core --json tagName -q .tagName 2>/dev/null || true)
  [ -n "$RAW_TAG" ] || exit 0

  LATEST_VERSION=$(echo "$RAW_TAG" | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
  [ -n "$LATEST_VERSION" ] || exit 0

  mkdir -p "$CACHE_DIR"
  printf '{"latest":"%s","checkedAt":"%s"}\n' \
    "$LATEST_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CACHE_FILE"
fi

# --- Compare semver (X.Y.Z) ---
version_gt() {
  [ "$1" = "$2" ] && return 1
  local a b
  a=$(printf '%s' "$1" | awk -F. '{ printf("%03d%03d%03d\n", $1, $2, $3) }')
  b=$(printf '%s' "$2" | awk -F. '{ printf("%03d%03d%03d\n", $1, $2, $3) }')
  [ "$a" \> "$b" ]
}

if ! version_gt "$LATEST_VERSION" "$LOCAL_VERSION"; then
  exit 0
fi

# --- Emit banner ---
cat <<EOF
<hq-update-available>
A newer hq-core release is available.
  current: v$LOCAL_VERSION
  latest:  v$LATEST_VERSION

Spawn a sub-agent task in a new session to run \`/update-hq\` so the upgrade
runs in isolation and does not consume context here. Suggested Agent prompt:

  Run the /update-hq slash command to upgrade HQ from v$LOCAL_VERSION to
  v$LATEST_VERSION. Use smart-merge defaults; do not overwrite local
  customizations without approval. Report a one-paragraph summary of what
  changed when finished.

Cache: $CACHE_FILE (24h TTL — delete to force re-check).
</hq-update-available>
EOF

} 2>/dev/null || true

exit 0
