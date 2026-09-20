#!/bin/bash
# check-hq-update.sh — SessionStart hook
#
# Responsibilities:
#   0. Remove matcher-less hook-gate registrations an old doctor wrote.
#   1. hq CLI floor: if the installed `hq` binary is below 5.117.3 (the first
#      release whose doctor no longer writes those registrations),
#      auto-update it in the background via npm. Detached so it never blocks
#      session start; 6h cooldown stamp so it doesn't relaunch every session.
#   2. hq-core release: compares local hqVersion (core/core.yaml) to the latest
#      GitHub release of indigoai-us/hq-core. If a newer release is available,
#      emits a banner instructing Claude to spawn a sub-agent task running
#      /update-hq in a fresh session.
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

# --- Compare semver (X.Y.Z): version_gt A B → true when A > B ---
version_gt() {
  [ "$1" = "$2" ] && return 1
  local a b
  a=$(printf '%s' "$1" | awk -F. '{ printf("%03d%03d%03d\n", $1, $2, $3) }')
  b=$(printf '%s' "$2" | awk -F. '{ printf("%03d%03d%03d\n", $1, $2, $3) }')
  [ "$a" \> "$b" ]
}

# --- (0) Heal settings broken by an old `hq doctor --fix` ---
# hq-cli 5.99.0 through 5.117.2 wrote matcher-less hook-gate.sh registrations
# that run every guard on every tool call and block Bash, Skill and Read.
# Remove exactly those, with a backup. Runs first so the next session starts
# healed. See core/scripts/remove-stray-gate-hooks.sh.
STRAY_OUT=$(bash "$HQ_ROOT/core/scripts/remove-stray-gate-hooks.sh" "$HQ_ROOT" 2>/dev/null || true)
if [ -n "$STRAY_OUT" ]; then
  printf '<hq-settings-healed>\n%s\nThese entries were written by an older hq doctor --fix and blocked tools with "Glob needs a path" or "Edit to locked path". If tools were blocked in this session, restart it. Tell the user in one plain sentence.\n</hq-settings-healed>\n' "$STRAY_OUT"
fi

# --- (1) hq CLI auto-update floor ---
# Runs before the core.yaml gate below, so it fires even on a fresh install
# with no core.yaml. 5.117.3 is the first release whose `hq doctor --fix` no
# longer writes matcher-less hook registrations (and removes existing ones);
# older CLIs re-create the breakage whenever client-health runs the doctor.
# (It also covers the original 5.35 floor for `hq reindex`.) Fully detached +
# 6h cooldown so a slow npm/network never blocks session start and we don't
# relaunch on every SessionStart. All failures silent — advisory infra.
HQ_CLI_FLOOR="5.117.3"
CLI_STAMP="$CACHE_DIR/hq-cli-autoupdate.stamp"
if command -v hq >/dev/null 2>&1 && { command -v pnpm >/dev/null 2>&1 || command -v npm >/dev/null 2>&1; }; then
  CLI_VER=$(HQ_NO_UPDATE_CHECK=1 hq --version 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [ -n "$CLI_VER" ] && version_gt "$HQ_CLI_FLOOR" "$CLI_VER"; then
    # 6h cooldown between attempts.
    STAMP_OK=1
    if [ -f "$CLI_STAMP" ]; then
      STAMP_MTIME=$(stat -c %Y "$CLI_STAMP" 2>/dev/null || stat -f %m "$CLI_STAMP" 2>/dev/null || echo 0)
      NOW=$(date +%s)
      [ "$((NOW - STAMP_MTIME))" -lt 21600 ] && STAMP_OK=0
    fi
    if [ "$STAMP_OK" -eq 1 ]; then
      mkdir -p "$CACHE_DIR"
      : > "$CLI_STAMP"
      # Detach fully so the install outlives this hook process.
      if command -v pnpm >/dev/null 2>&1; then
        UPDATE_CMD='pnpm add -g @indigoai-us/hq-cli@latest --config.minimumReleaseAge=1440'
      else
        UPDATE_CMD='npm install -g @indigoai-us/hq-cli@latest'
      fi
      if command -v setsid >/dev/null 2>&1; then
        setsid sh -c "$UPDATE_CMD >/dev/null 2>&1" >/dev/null 2>&1 &
      else
        nohup sh -c "$UPDATE_CMD >/dev/null 2>&1" >/dev/null 2>&1 &
      fi
      cat <<EOF
<hq-cli-auto-update>
Your hq CLI ($CLI_VER) is below the required $HQ_CLI_FLOOR and is being updated in
the background ($UPDATE_CMD). The update is picked
up next session.
</hq-cli-auto-update>
EOF
    fi
  fi
fi

# --- (2) hq-core release check ---
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
  CACHE_MTIME=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
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
