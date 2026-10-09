#!/bin/bash
# check-hq-update.sh — SessionStart hook
#
# Responsibilities:
#   0. Remove matcher-less hook-gate registrations an old doctor wrote.
#   1. hq CLI floor: if the installed `hq` binary is below 5.117.3 (the first
#      release whose doctor no longer writes those registrations),
#      auto-update it in the background via the available package manager.
#      Detached so it never blocks session start; 6h cooldown stamp so it
#      doesn't relaunch every session.
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

version_at_least() {
  [ "$1" = "$2" ] && return 0
  version_gt "$1" "$2"
}

# A slow CLI probe is not evidence that the binary is broken. Bound it and
# report timeout distinctly so the floor updater can leave the install alone.
HQ_CLI_VERSION_TIMEOUT="${HQ_CLI_VERSION_TIMEOUT:-1}"
HQ_NPM_PREFIX_TIMEOUT="${HQ_NPM_PREFIX_TIMEOUT:-1}"
HQ_CLI_SHADOW_SCAN_TIMEOUT="${HQ_CLI_SHADOW_SCAN_TIMEOUT:-4}"
HQ_SETTINGS_HEAL_TIMEOUT="${HQ_SETTINGS_HEAL_TIMEOUT:-1}"
CLI_STATE_DIR="${HQ_UPDATE_CHECK_STATE_DIR:-${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/hq-update-check}"
stop_cli_watchdog() {
  local watchdog_pid="$1"
  if command -v pkill >/dev/null 2>&1; then pkill -P "$watchdog_pid" 2>/dev/null || true; fi
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
}

# Use Bash's fractional epoch clock where available, then Perl's high-resolution
# clock, and finally Bash's coarse SECONDS counter. The timer is only written
# when the regression test explicitly supplies HQ_TEST_TIMING_FILE.
update_hook_now_ms() {
  local epoch seconds fraction padded perl_ms
  epoch="${EPOCHREALTIME:-}"
  if [ -n "$epoch" ]; then
    seconds="${epoch%%.*}"
    fraction="${epoch#*.}"
    padded="${fraction}000"
    printf '%s\n' "$((10#$seconds * 1000 + 10#${padded:0:3}))"
  elif command -v perl >/dev/null 2>&1 \
    && perl_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000' 2>/dev/null)" \
    && [ -n "$perl_ms" ]; then
    printf '%s\n' "$perl_ms"
  else
    printf '%s000\n' "$SECONDS"
  fi
}

record_update_probe_timing() {
  local probe="$1" budget_ms="$2" start_ms="$3" end_ms elapsed_ms
  [ -n "${HQ_TEST_TIMING_FILE:-}" ] || return 0
  end_ms="$(update_hook_now_ms)" || return 0
  elapsed_ms=$((end_ms - start_ms))
  printf 'probe=%s budget_ms=%s elapsed_ms=%s\n' "$probe" "$budget_ms" "$elapsed_ms" \
    >> "$HQ_TEST_TIMING_FILE" 2>/dev/null || true
}

capture_command_descendants() {
  local root_pid="$1" process_table queue descendants parent pid ppid
  process_table="$(ps -A -o pid= -o ppid= 2>/dev/null)" || return 0
  queue="$root_pid"
  descendants=""
  while [ -n "$queue" ]; do
    parent="${queue%% *}"
    if [ "$queue" = "$parent" ]; then queue=""; else queue="${queue#* }"; fi
    while read -r pid ppid; do
      if [ "$ppid" = "$parent" ] && [ "$pid" != "$root_pid" ]; then
        queue="${queue:+$queue }$pid"
        descendants="${descendants:+$descendants }$pid"
      fi
    done <<EOF
$process_table
EOF
  done
  for pid in $descendants; do printf '%s\n' "$pid"; done
}

capture_bounded_output() {
  local seconds="$1" probe="$2" output_file timeout_file cmd_pid watchdog_pid rc=0 start_ms
  shift 2
  output_file="$(mktemp "${TMPDIR:-/tmp}/hq-cli-update-command.XXXXXX" 2>/dev/null)" || return 1
  timeout_file="${output_file}.timeout"
  start_ms=""
  if [ -n "${HQ_TEST_TIMING_FILE:-}" ]; then
    start_ms="$(update_hook_now_ms)" || start_ms=0
  fi
  "$@" >"$output_file" 2>/dev/null &
  cmd_pid=$!
  (
    if sleep "$seconds" 2>/dev/null; then
      : > "$timeout_file" 2>/dev/null
      record_update_probe_timing "$probe" "$((seconds * 1000))" "$start_ms"
      descendants="$(capture_command_descendants "$cmd_pid")"
      if [ -n "$descendants" ]; then
        for descendant in $descendants; do kill -TERM "$descendant" 2>/dev/null || true; done
        sleep 0.1 2>/dev/null || true
        for descendant in $descendants; do kill -KILL "$descendant" 2>/dev/null || true; done
      elif command -v pkill >/dev/null 2>&1; then
        pkill -TERM -P "$cmd_pid" 2>/dev/null || true
        sleep 0.1 2>/dev/null || true
        pkill -KILL -P "$cmd_pid" 2>/dev/null || true
      fi
      kill -TERM "$cmd_pid" 2>/dev/null || true
      sleep 0.1 2>/dev/null || true
      kill -KILL "$cmd_pid" 2>/dev/null || true
    fi
  ) >/dev/null 2>&1 &
  watchdog_pid=$!
  wait "$cmd_pid" 2>/dev/null || rc=$?
  stop_cli_watchdog "$watchdog_pid"
  if [ -f "$timeout_file" ]; then
    rm -f "$output_file" "$timeout_file" 2>/dev/null || true
    return 124
  fi
  [ "$rc" -eq 0 ] && cat "$output_file" || true
  rm -f "$output_file" "$timeout_file" 2>/dev/null || true
  return "$rc"
}

capture_cli_version() {
  local binary="$1" output version
  output="$(HQ_NO_UPDATE_CHECK=1 capture_bounded_output "$HQ_CLI_VERSION_TIMEOUT" cli-version "$binary" --version)" || return $?
  version="$(printf '%s' "$output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [ -n "$version" ] || return 1
  printf '%s\n' "$version"
}

npm_global_bin() {
  command -v npm >/dev/null 2>&1 || return 1
  local prefix
  prefix="$(capture_bounded_output "$HQ_NPM_PREFIX_TIMEOUT" npm-prefix npm config get prefix)" || return $?
  [ -n "$prefix" ] && [ "$prefix" != "undefined" ] || return 1
  if [ -d "$prefix/bin" ]; then printf '%s\n' "$prefix/bin"; else printf '%s\n' "$prefix"; fi
}

# Return 0 when another PATH or npm-global hq is at least as new as the active
# one, 1 when none is, and 2 when an alternate candidate's version timed out.
# Both non-zero outcomes are conservative for the auto-updater: it must not
# replace a PATH winner when an equal/newer install may already exist.
has_equal_or_newer_hq() {
  local active_binary="$1" active_version="$2" dir binary candidate_version probe_rc npm_bin
  local deadline=$((SECONDS + HQ_CLI_SHADOW_SCAN_TIMEOUT))
  local oldifs="$IFS"
  local -a path_dirs=()
  IFS=':' read -r -a path_dirs <<< "${PATH:-}"
  IFS="$oldifs"
  npm_bin="$(npm_global_bin 2>/dev/null)" || {
    probe_rc=$?
    [ "$probe_rc" -eq 124 ] && return 2
    npm_bin=""
  }
  [ -z "$npm_bin" ] || path_dirs+=("$npm_bin")
  for dir in "${path_dirs[@]}"; do
    [ -n "$dir" ] || continue
    [ "$SECONDS" -lt "$deadline" ] || return 2
    binary="$dir/hq"
    [ -x "$binary" ] || continue
    [ "$binary" = "$active_binary" ] && continue
    if candidate_version="$(capture_cli_version "$binary")"; then
      if version_at_least "$candidate_version" "$active_version"; then return 0; fi
    else
      probe_rc=$?
      [ "$probe_rc" -eq 124 ] && return 2
    fi
  done
  return 1
}

# GitHub's network-backed checks are advisory. Bound each call independently so
# a stalled DNS, auth, or API request cannot consume the SessionStart budget.
# On hosts without either timeout mechanism, skip the network check entirely.
bounded_gh_command() {
  local seconds="$1" timeout_version="" os_name=""
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout_version="$(timeout --version 2>/dev/null || true)"
    case "$timeout_version" in
      *"GNU coreutils"*) timeout -k 0.1s "${seconds}s" "$@"; return $? ;;
    esac
  fi
  if command -v perl >/dev/null 2>&1; then
    # Perl's alarm does not reliably interrupt exec'd children under Git Bash.
    os_name="$(uname -s 2>/dev/null)" || return 125
    case "$os_name" in
      MINGW*|MSYS*|CYGWIN*) return 125 ;;
    esac
    perl -e 'alarm shift; exec { $ARGV[0] } @ARGV' "$seconds" "$@"
    return $?
  fi
  return 125
}

# --- (0) Heal settings broken by an old `hq doctor --fix` ---
# hq-cli 5.99.0 through 5.117.2 wrote matcher-less hook-gate.sh registrations
# that run every guard on every tool call and block Bash, Skill and Read.
# Remove exactly those, with a backup. Runs first so the next session starts
# healed. See core/scripts/remove-stray-gate-hooks.sh.
settings_heal_identity() {
  local path
  local -a paths=()
  for path in "$HQ_ROOT/.claude/settings.json" "$HQ_ROOT/.claude/settings.local.json" "$HQ_ROOT/.claude/hooks/hook-registry.json" "$HQ_ROOT/core/scripts/remove-stray-gate-hooks.sh" "$HQ_ROOT/core/scripts/hook-lib.sh"; do
    if [ -f "$path" ]; then paths+=("$path"); else printf '%s:missing\n' "$path"; fi
  done
  [ "${#paths[@]}" -gt 0 ] || return 0
  stat -c '%n:%Y:%s:%i' "${paths[@]}" 2>/dev/null || stat -f '%N:%m:%z:%i' "${paths[@]}" 2>/dev/null || return 1
}
SETTINGS_HEAL_STAMP="$CLI_STATE_DIR/settings-heal-check.tsv"
SETTINGS_HEAL_IDENTITY="$(settings_heal_identity)"
LAST_SETTINGS_HEAL_IDENTITY=""
if [ -f "$SETTINGS_HEAL_STAMP" ]; then LAST_SETTINGS_HEAL_IDENTITY="$(< "$SETTINGS_HEAL_STAMP")"; fi
STRAY_OUT=""
if [ "$SETTINGS_HEAL_IDENTITY" != "$LAST_SETTINGS_HEAL_IDENTITY" ]; then
  SETTINGS_HEAL_RC=0
  STRAY_OUT="$(capture_bounded_output "$HQ_SETTINGS_HEAL_TIMEOUT" settings-heal bash "$HQ_ROOT/core/scripts/remove-stray-gate-hooks.sh" "$HQ_ROOT")" || SETTINGS_HEAL_RC=$?
  if [ "$SETTINGS_HEAL_RC" -eq 0 ]; then
    SETTINGS_HEAL_IDENTITY="$(settings_heal_identity)"
    mkdir -p "$CLI_STATE_DIR" 2>/dev/null || true
    printf '%s\n' "$SETTINGS_HEAL_IDENTITY" > "$SETTINGS_HEAL_STAMP" 2>/dev/null || true
  fi
fi
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
  CLI_BIN="$(command -v hq 2>/dev/null)"
  CLI_VER=""
  CLI_PROBE_CACHE="$CLI_STATE_DIR/cli-version-probe.tsv"
  resolve_cli_target() {
    local target="$1" link dir hops=0
    case "$target" in
      /*|*/*) ;;
      *) target="$(type -P "$target" 2>/dev/null)" || return 1 ;;
    esac
    while [ -L "$target" ]; do
      hops=$((hops + 1))
      [ "$hops" -le 40 ] || return 1
      link="$(readlink "$target" 2>/dev/null)" || return 1
      case "$link" in
        /*) target="$link" ;;
        *)
          dir="$(cd -P "$(dirname "$target")" 2>/dev/null && pwd)" || return 1
          target="$dir/$link"
          ;;
      esac
    done
    dir="$(cd -P "$(dirname "$target")" 2>/dev/null && pwd)" || return 1
    printf '%s/%s\n' "$dir" "$(basename "$target")"
  }
  CLI_BIN_TARGET="$(resolve_cli_target "$CLI_BIN" 2>/dev/null || printf '%s' "$CLI_BIN")"
  CLI_BIN_STAT="$(stat -c '%Y:%s:%i' "$CLI_BIN_TARGET" 2>/dev/null || stat -f '%m:%z:%i' "$CLI_BIN_TARGET" 2>/dev/null || true)"
  if [ -n "$CLI_BIN_STAT" ] && [ -f "$CLI_PROBE_CACHE" ]; then
    IFS=$'\t' read -r CACHED_CLI_BIN CACHED_CLI_STAT CACHED_CLI_VER CACHED_CLI_TIME < "$CLI_PROBE_CACHE"
    CLI_CACHE_NOW="$(date +%s 2>/dev/null || echo 0)"
    if [ "$CACHED_CLI_BIN" = "$CLI_BIN" ] \
      && [ "$CACHED_CLI_STAT" = "$CLI_BIN_STAT" ] \
      && [[ "$CACHED_CLI_TIME" =~ ^[0-9]+$ ]] \
      && [[ "$CLI_CACHE_NOW" =~ ^[0-9]+$ ]] \
      && [ "$((CLI_CACHE_NOW - CACHED_CLI_TIME))" -ge 0 ] \
      && [ "$((CLI_CACHE_NOW - CACHED_CLI_TIME))" -lt "$CACHE_TTL_SECONDS" ] \
      && [[ "$CACHED_CLI_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      CLI_VER="$CACHED_CLI_VER"
    fi
  fi
  if [ -z "$CLI_VER" ]; then
    CLI_VER="$(capture_cli_version "$CLI_BIN")"
    if [ -n "$CLI_VER" ] && [ -n "$CLI_BIN_STAT" ]; then
      mkdir -p "$CLI_STATE_DIR" 2>/dev/null || true
      printf '%s\t%s\t%s\t%s\n' "$CLI_BIN" "$CLI_BIN_STAT" "$CLI_VER" "$(date +%s 2>/dev/null || echo 0)" \
        > "$CLI_PROBE_CACHE" 2>/dev/null || true
    fi
  fi
  if [ -n "$CLI_VER" ] && version_gt "$HQ_CLI_FLOOR" "$CLI_VER"; then
    SHADOW_RC=0
    has_equal_or_newer_hq "$CLI_BIN" "$CLI_VER" || SHADOW_RC=$?
    if [ "$SHADOW_RC" -eq 1 ]; then
      # 6h cooldown between attempts.
      STAMP_OK=1
      if [ -f "$CLI_STAMP" ]; then
        STAMP_MTIME=$(stat -c %Y "$CLI_STAMP" 2>/dev/null || stat -f %m "$CLI_STAMP" 2>/dev/null || echo 0)
        NOW=$(date +%s)
        [ "$((NOW - STAMP_MTIME))" -lt 21600 ] && STAMP_OK=0
      fi
      if [ "$STAMP_OK" -eq 1 ]; then
        if command -v pnpm >/dev/null 2>&1; then
          UPDATE_CMD='pnpm add -g @indigoai-us/hq-cli@latest --config.minimumReleaseAge=1440'
          mkdir -p "$CACHE_DIR"
          : > "$CLI_STAMP"
          # Detach fully so the age-gated install outlives this hook process.
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
        else
          cat <<EOF
<hq-cli-auto-update-skipped>
Your hq CLI ($CLI_VER) is below the required $HQ_CLI_FLOOR. Automatic update was
skipped because pnpm is unavailable; npm does not enforce the 24-hour minimum
release age or the package-install guard. Install pnpm, then run this guarded
command from a Bash tool call:
  pnpm add -g @indigoai-us/hq-cli@latest --config.minimumReleaseAge=1440
</hq-cli-auto-update-skipped>
EOF
        fi
      fi
    fi
  fi
fi

# --- (2) hq-core release check ---
# Skip if core.yaml missing (fresh install or pre-v12)
[ -f "$CORE_YAML" ] || exit 0

# --- Local version ---
LOCAL_VERSION=""
while IFS= read -r CORE_LINE; do
  case "$CORE_LINE" in
    hqVersion:*)
      LOCAL_VERSION="${CORE_LINE#hqVersion:}"
      LOCAL_VERSION="${LOCAL_VERSION//[[:space:]]/}"
      LOCAL_VERSION="${LOCAL_VERSION//\"/}"
      LOCAL_VERSION="${LOCAL_VERSION//\'/}"
      if [[ "$LOCAL_VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        LOCAL_VERSION="${BASH_REMATCH[1]}"
      else
        LOCAL_VERSION=""
      fi
      break
      ;;
  esac
done < "$CORE_YAML"
[ -n "$LOCAL_VERSION" ] || exit 0

# --- Latest release (cached) ---
LATEST_VERSION=""
USE_CACHE=0

if [ -f "$CACHE_FILE" ]; then
  CACHE_MTIME=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
  NOW="${EPOCHSECONDS:-$(date +%s)}"
  AGE=$((NOW - CACHE_MTIME))
  if [ "$AGE" -lt "$CACHE_TTL_SECONDS" ]; then
    USE_CACHE=1
    CACHE_JSON="$(< "$CACHE_FILE")"
    if [[ "$CACHE_JSON" =~ \"latest\":[[:space:]]*\"([0-9]+\.[0-9]+\.[0-9]+)\" ]]; then
      LATEST_VERSION="${BASH_REMATCH[1]}"
    fi
  fi
fi

network_attempt_stamp_path() {
  local state_home
  state_home="${HQ_UPDATE_CHECK_STATE_DIR:-${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/hq-update-check}"
  printf '%s/release-network-attempt.last\n' "$state_home"
}

network_attempt_stamp_is_fresh() {
  local stamp="$1" mtime now age
  [ -f "$stamp" ] || return 1
  mtime="$(stat -c %Y "$stamp" 2>/dev/null || stat -f %m "$stamp" 2>/dev/null || echo 0)"
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s 2>/dev/null || echo 0)"
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  age=$((now - mtime))
  [ "$age" -ge 0 ] && [ "$age" -lt "$CACHE_TTL_SECONDS" ]
}

network_cache_identity() {
  if [ -f "$CACHE_FILE" ]; then
    stat -c '%Y:%s:%i' "$CACHE_FILE" 2>/dev/null \
      || stat -f '%m:%z:%i' "$CACHE_FILE" 2>/dev/null \
      || printf 'present\n'
  else
    printf 'missing\n'
  fi
}

network_attempt_stamp_should_skip() {
  local stamp="$1" attempted_cache current_cache
  network_attempt_stamp_is_fresh "$stamp" || return 1
  IFS= read -r attempted_cache < "$stamp" || attempted_cache=""
  # Older empty stamps retain their cooldown behavior. New stamps record the
  # cache identity so removing last-check.json remains an explicit recheck.
  [ -n "$attempted_cache" ] || return 0
  current_cache="$(network_cache_identity)" || return 0
  [ "$attempted_cache" = "$current_cache" ]
}

write_network_attempt_stamp() {
  local stamp="$1"
  mkdir -p "${stamp%/*}" 2>/dev/null || return 0
  network_cache_identity > "$stamp" 2>/dev/null || : > "$stamp" 2>/dev/null || true
}

if [ "$USE_CACHE" -eq 0 ]; then
  command -v gh >/dev/null 2>&1 || exit 0
  NETWORK_ATTEMPT_STAMP="$(network_attempt_stamp_path)" || exit 0
  if network_attempt_stamp_should_skip "$NETWORK_ATTEMPT_STAMP"; then exit 0; fi
  bounded_gh_command 2 gh auth status >/dev/null 2>&1 || {
    write_network_attempt_stamp "$NETWORK_ATTEMPT_STAMP"
    exit 0
  }

  RAW_TAG=$(bounded_gh_command 2 gh release view -R indigoai-us/hq-core --json tagName -q .tagName 2>/dev/null) || {
    write_network_attempt_stamp "$NETWORK_ATTEMPT_STAMP"
    exit 0
  }
  [ -n "$RAW_TAG" ] || { write_network_attempt_stamp "$NETWORK_ATTEMPT_STAMP"; exit 0; }

  LATEST_VERSION=$(echo "$RAW_TAG" | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
  [ -n "$LATEST_VERSION" ] || { write_network_attempt_stamp "$NETWORK_ATTEMPT_STAMP"; exit 0; }

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
