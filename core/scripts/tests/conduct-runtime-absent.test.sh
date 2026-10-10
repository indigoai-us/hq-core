#!/usr/bin/env bash
set -euo pipefail

deleted_paths=(
  core/scripts/conduct-inbox.sh
  core/scripts/conduct-lane-launch.sh
  core/scripts/conduct-lane-notify.sh
  core/scripts/conduct-lane-status.sh
  core/scripts/conduct-lane-wait.sh
  core/scripts/conduct-link.sh
  core/scripts/conduct-pool.sh
  core/scripts/conduct-reap.sh
  core/scripts/conduct-workers.sh
  .claude/hooks/auto-conduct.sh
  .claude/hooks/conduct-lane-inbox.sh
  core/hooks/SessionStart/40-conduct-reap.sh
)

deleted_hook_scripts=(
  .claude/hooks/auto-conduct.sh
  .claude/hooks/conduct-lane-inbox.sh
  core/hooks/SessionStart/40-conduct-reap.sh
)

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
report() { printf 'conduct-runtime-absent: %s\n' "$*" >&2; }

check_root() {
  local root="$1" path script ids matches status=0 registry
  for path in "${deleted_paths[@]}"; do
    if [ -e "$root/$path" ] || [ -L "$root/$path" ]; then
      report "deleted path exists: $path"
      status=1
    fi
  done

  registry="$root/.claude/hooks/hook-registry.json"
  if [ -f "$registry" ]; then
    if ! jq -e . "$registry" >/dev/null 2>&1; then
      report 'hook-registry.json is not valid JSON'
      status=1
    else
      ids="$(jq -r '[.. | objects | select(.id? == "conduct-lane-inbox" or .id? == "auto-conduct")] | .[] | .id' "$registry")"
      if [ -n "$ids" ]; then
        while IFS= read -r path; do report "forbidden registry id: $path"; done <<< "$ids"
        status=1
      fi
      for script in "${deleted_hook_scripts[@]}"; do
        if jq -e --arg script "$script" '[.. | objects | select(.script? == $script)] | length > 0' "$registry" >/dev/null; then
          report "forbidden registry script: $script"
          status=1
        fi
      done
    fi
  fi

  local scan_dirs=() dir
  for dir in .claude/skills .claude/hooks core/hooks core/settings core/workers .github/workflows; do
    [ ! -d "$root/$dir" ] || scan_dirs+=("$root/$dir")
  done
  [ ! -d "$root/core/scripts" ] || scan_dirs+=("$root/core/scripts")
  if [ "${#scan_dirs[@]}" -gt 0 ]; then
    local pattern='(bash|sh)[[:space:]]+[^[:cntrl:]]*(conduct-inbox|conduct-lane-launch|conduct-lane-notify|conduct-lane-status|conduct-lane-wait|conduct-link|conduct-pool|conduct-reap|conduct-workers|auto-conduct|conduct-lane-inbox)\.sh([[:space:]"'"'"'`]|$)'
    while IFS= read -r -d '' path; do
      if matches="$(grep -nE "$pattern" "$path" 2>&1)"; then
        report "deleted script invocation: $matches"
        status=1
      else
        local rc=$?
        if [ "$rc" -ne 1 ]; then
          report "invocation scan failed (grep exit $rc): $matches"
          status=1
        fi
      fi
    done < <(find "${scan_dirs[@]}" -type f ! -path '*/tests/*' ! -name '*.test.*' ! -name 'conduct-runtime-absent.test.sh' -print0)
  fi
  return "$status"
}

if [ "${1:-}" = '--check-root' ]; then
  [ "$#" -eq 2 ] || fail 'usage: conduct-runtime-absent.test.sh --check-root <root>'
  check_root "$2"
  exit $?
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
check_root "$ROOT" || fail 'legacy conduct runtime remains in the repository'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
GUARD_COPY="$TMP/guard-root/core/scripts/tests/conduct-runtime-absent.test.sh"
prepare_case() {
  local root="$1"
  mkdir -p "$(dirname "$root/core/scripts/tests/conduct-runtime-absent.test.sh")"
  cp "${BASH_SOURCE[0]}" "$root/core/scripts/tests/conduct-runtime-absent.test.sh"
}
expect_red() {
  local name="$1" expected="$2" root="$TMP/$1" output rc
  prepare_case "$root"
  shift 2
  "$@" "$root"
  set +e
  output="$(bash "$root/core/scripts/tests/conduct-runtime-absent.test.sh" --check-root "$root" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$name: guard passed after restoring forbidden content"
  printf '%s\n' "$output" | grep -Fq "$expected" || fail "$name: guard did not name '$expected': $output"
  printf 'red/green probe: %s rejected (%s)\n' "$name" "$expected"
}

make_pool() { touch "$1/core/scripts/conduct-pool.sh"; }
make_hook_and_registry() {
  mkdir -p "$1/.claude/hooks"
  touch "$1/.claude/hooks/conduct-lane-inbox.sh"
  cat > "$1/.claude/hooks/hook-registry.json" <<'JSON'
{"hooks":{"Stop":[{"hooks":[{"id":"conduct-lane-inbox","script":".claude/hooks/conduct-lane-inbox.sh"}]}]}}
JSON
}
make_registry_only() {
  mkdir -p "$1/.claude/hooks"
  cat > "$1/.claude/hooks/hook-registry.json" <<'JSON'
{"hooks":{"PostToolUse":[{"hooks":[{"id":"conduct-lane-inbox","script":".claude/hooks/conduct-lane-inbox.sh"}]}]}}
JSON
}
make_reaper() {
  mkdir -p "$1/core/hooks/SessionStart"
  touch "$1/core/hooks/SessionStart/40-conduct-reap.sh"
}
make_skill_call() {
  mkdir -p "$1/.claude/skills/conduct"
  printf '%s\n' 'bash core/scripts/conduct-link.sh close' > "$1/.claude/skills/conduct/example.md"
}

expect_red 'restored pool script' 'deleted path exists: core/scripts/conduct-pool.sh' make_pool
expect_red 'restored hook and registry entry' 'deleted path exists: .claude/hooks/conduct-lane-inbox.sh' make_hook_and_registry
expect_red 'restored registry entry without its script' 'forbidden registry id: conduct-lane-inbox' make_registry_only
expect_red 'restored SessionStart reaper' 'deleted path exists: core/hooks/SessionStart/40-conduct-reap.sh' make_reaper
expect_red 'skill invocation' 'deleted script invocation:' make_skill_call

printf 'conduct-runtime-absent.test.sh: current tree clean; 5 discriminating red cases passed\n'
