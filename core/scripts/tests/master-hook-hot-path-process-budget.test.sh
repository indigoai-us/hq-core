#!/usr/bin/env bash
# Linux process-budget regression for master-hook's successful PreToolUse path.
set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SOURCE_ROOT="${HQ_HOOK_PERF_SOURCE_ROOT:-$ROOT}"
BASE_SHA="${HQ_HOOK_PERF_BASE_SHA:-}"
STRACE="$(type -P strace || true)"
BASH_BIN="$(type -P bash || true)"
[ -n "$STRACE" ] || { echo 'FAIL: strace is required for this Linux process-budget test' >&2; exit 1; }
[ -n "$BASH_BIN" ] || { echo 'FAIL: bash is required' >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BASE_SOURCE="$TMP/base-source"
CANDIDATE_SOURCE="$TMP/candidate-source"
BASE_FIXTURE="$TMP/fixture-base"
CANDIDATE_FIXTURE="$TMP/fixture-candidate"
TOOLS="$TMP/tools"
HOME_BASE="$TMP/home-base"
HOME_CANDIDATE="$TMP/home-candidate"
mkdir -p "$BASE_SOURCE" "$CANDIDATE_SOURCE" "$TOOLS" "$HOME_BASE" "$HOME_CANDIDATE"

if [ -z "$BASE_SHA" ]; then
  BASE_SHA="$(git -C "$ROOT" merge-base HEAD origin/main 2>/dev/null || true)"
fi
[[ "$BASE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail 'HQ_HOOK_PERF_BASE_SHA or origin/main merge base is required'
timeout 20s git -C "$ROOT" cat-file -e "$BASE_SHA^{commit}" \
  || fail "base commit is unavailable locally: $BASE_SHA"

for relative in \
  .claude/hooks/master-hook.sh \
  .claude/hooks/hook-timeout-probe.sh \
  .claude/hooks/hook-timeout-watchdog.sh \
  .claude/hooks/hook-gate.sh; do
  [ -f "$SOURCE_ROOT/$relative" ] || fail "missing candidate source file: $SOURCE_ROOT/$relative"
  mkdir -p "$BASE_SOURCE/${relative%/*}" "$CANDIDATE_SOURCE/${relative%/*}"
  timeout 20s git -C "$ROOT" show "$BASE_SHA:$relative" > "$BASE_SOURCE/$relative" \
    || fail "base is missing $relative at $BASE_SHA"
  cp "$SOURCE_ROOT/$relative" "$CANDIDATE_SOURCE/$relative"
done

make_fixture() {
  local root="$1" source="$2"
  mkdir -p "$root/.claude/hooks" "$root/.codex" "$root/.grok/hooks" \
    "$root/core/hooks/PreToolUse" "$root/core/scripts" \
    "$root/personal/hooks/PreToolUse" "$root/workspace"
  for relative in \
    .claude/hooks/master-hook.sh \
    .claude/hooks/hook-timeout-probe.sh \
    .claude/hooks/hook-timeout-watchdog.sh \
    .claude/hooks/hook-gate.sh; do
    cp "$source/$relative" "$root/$relative"
  done
  chmod +x "$root/.claude/hooks/master-hook.sh" \
    "$root/.claude/hooks/hook-gate.sh" "$root/.claude/hooks/hook-timeout-watchdog.sh"
  cat > "$root/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash .claude/hooks/master-hook.sh PreToolUse","timeout":30}]}]}}
JSON
  cat > "$root/.claude/hooks/hook-registry.json" <<'JSON'
{"hooks":{}}
JSON
  printf 'hqVersion: "15.0.131"\n' > "$root/core/core.yaml"
  : > "$root/core/scripts/hook-lib.sh"
}

make_fixture "$BASE_FIXTURE" "$BASE_SOURCE"
make_fixture "$CANDIDATE_FIXTURE" "$CANDIDATE_SOURCE"

# Keep the executable search path deterministic and exclude shasum.
for tool in awk bash cat date grep head jq mkdir mv rm rmdir sed sha256sum sleep sort timeout tr uname wc tail setsid; do
  resolved="$(type -P "$tool" || true)"
  [ -n "$resolved" ] || fail "required tool not found: $tool"
  ln -s "$resolved" "$TOOLS/$tool"
done

run_hook() {
  local root="$1" home="$2" trace="$3" payload rc
  payload="$(printf '{"session_id":"process-budget-session","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"true"}}' "$root")"
  set +e
  env -u BASH_ENV -u ENV PATH="$TOOLS" HOME="$home" HQ_HOOK_TIMEOUT_SENTRY=1 \
    HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=0 \
    HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS=600 \
    timeout 10s "$STRACE" -f -qq -e trace=execve,clone,clone3,fork,vfork \
      -o "$trace" "$BASH_BIN" "$root/.claude/hooks/master-hook.sh" PreToolUse \
      <<<"$payload" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "master-hook fixture exited $rc"
}

exec_inventory() {
  awk '
    /execve\("/ {
      path = $0
      sub(/^.*execve\("/, "", path)
      sub(/".*/, "", path)
      sub(/^.*\//, "", path)
      print path
    }
  ' "$1" | sort | uniq -c | awk '{ printf "%s:%s ", $2, $1 }' | sed 's/ $//'
}

exec_inventory_has_no_growth() {
  local base="$1" candidate="$2" candidate_entry base_entry command count base_count
  local -a base_entries=() candidate_entries=()
  read -r -a base_entries <<< "$base"
  read -r -a candidate_entries <<< "$candidate"
  for candidate_entry in "${candidate_entries[@]}"; do
    command="${candidate_entry%%:*}"
    count="${candidate_entry#*:}"
    base_count=0
    for base_entry in "${base_entries[@]}"; do
      [ "${base_entry%%:*}" = "$command" ] || continue
      base_count="${base_entry#*:}"
      break
    done
    [ "$count" -le "$base_count" ] || return 1
  done
}

BASE_TRACE="$TMP/master-hook-base.trace"
CANDIDATE_TRACE="$TMP/master-hook-candidate.trace"
run_hook "$BASE_FIXTURE" "$HOME_BASE" "$BASE_TRACE"
run_hook "$CANDIDATE_FIXTURE" "$HOME_CANDIDATE" "$CANDIDATE_TRACE"
[ -s "$BASE_TRACE" ] && [ -s "$CANDIDATE_TRACE" ] || fail 'strace produced no trace data'

base_execs="$(exec_inventory "$BASE_TRACE")"
candidate_execs="$(exec_inventory "$CANDIDATE_TRACE")"
base_exec_count="$(awk '/execve\(/ { count++ } END { print count + 0 }' "$BASE_TRACE")"
candidate_exec_count="$(awk '/execve\(/ { count++ } END { print count + 0 }' "$CANDIDATE_TRACE")"
if ! exec_inventory_has_no_growth "$base_execs" "$candidate_execs"; then
  printf 'Base exec inventory:      %s\nCandidate exec inventory: %s\n' \
    "$base_execs" "$candidate_execs" >&2
  fail 'successful master-hook path added an external command over the base'
fi

printf 'PASS: PreToolUse adds no external commands (base/candidate: %s/%s execs)\n' \
  "$base_exec_count" "$candidate_exec_count"
