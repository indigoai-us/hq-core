#!/usr/bin/env bash
# Linux process budget across representative PreToolUse and SessionStart fires.
# The fixture carries realistic hook payloads and registry IDs while isolating
# all filesystem state from the running HQ checkout.
set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SOURCE_ROOT="${HQ_HOOK_PERF_SOURCE_ROOT:-$ROOT}"
BASE_SHA="${HQ_HOOK_PERF_BASE_SHA:-}"
BASE_SOURCE_ROOT="${HQ_HOOK_PERF_BASE_SOURCE_ROOT:-}"
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
mkdir -p "$BASE_SOURCE" "$CANDIDATE_SOURCE" "$TOOLS"

if [ -z "$BASE_SHA" ]; then
  BASE_SHA="$(git -C "$ROOT" merge-base HEAD origin/main 2>/dev/null || true)"
fi
[[ "$BASE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail 'HQ_HOOK_PERF_BASE_SHA or origin/main merge base is required'
if [ -z "$BASE_SOURCE_ROOT" ]; then
  timeout 20s git -C "$ROOT" cat-file -e "$BASE_SHA^{commit}" \
    || fail "base commit is unavailable locally: $BASE_SHA"
fi

for relative in \
  .claude/hooks/master-hook.sh \
  .claude/hooks/hook-timeout-probe.sh \
  .claude/hooks/hook-timeout-watchdog.sh \
  .claude/hooks/hook-gate.sh \
  core/scripts/lib/hook-adapter-core.sh; do
  [ -f "$SOURCE_ROOT/$relative" ] || fail "missing candidate source file: $SOURCE_ROOT/$relative"
  mkdir -p "$BASE_SOURCE/${relative%/*}" "$CANDIDATE_SOURCE/${relative%/*}"
  if [ -n "$BASE_SOURCE_ROOT" ]; then
    [ -f "$BASE_SOURCE_ROOT/$relative" ] \
      || fail "fixture base is missing $relative at $BASE_SOURCE_ROOT"
    cp "$BASE_SOURCE_ROOT/$relative" "$BASE_SOURCE/$relative"
  else
    timeout 20s git -C "$ROOT" show "$BASE_SHA:$relative" > "$BASE_SOURCE/$relative" \
      || fail "base is missing $relative at $BASE_SHA"
  fi
  cp "$SOURCE_ROOT/$relative" "$CANDIDATE_SOURCE/$relative"
done

# Hook-source changes may be unrelated to process cost. Keep the same
# no-regression budget whether the measured sources changed or stayed equal.
SOURCES_CHANGED=0
for relative in \
  .claude/hooks/master-hook.sh \
  .claude/hooks/hook-timeout-probe.sh \
  .claude/hooks/hook-timeout-watchdog.sh \
  .claude/hooks/hook-gate.sh \
  core/scripts/lib/hook-adapter-core.sh; do
  cmp -s "$BASE_SOURCE/$relative" "$CANDIDATE_SOURCE/$relative" || SOURCES_CHANGED=1
done

make_fixture() {
  local root="$1" source="$2"
  mkdir -p "$root/.claude/hooks/children" "$root/.codex" "$root/.grok/hooks" \
    "$root/core/hooks/PreToolUse" "$root/core/scripts/lib" "$root/personal/hooks/PreToolUse" \
    "$root/workspace"
  for relative in \
    .claude/hooks/master-hook.sh \
    .claude/hooks/hook-timeout-probe.sh \
    .claude/hooks/hook-timeout-watchdog.sh \
    .claude/hooks/hook-gate.sh \
    core/scripts/lib/hook-adapter-core.sh; do
    cp "$source/$relative" "$root/$relative"
  done
  chmod +x "$root/.claude/hooks/master-hook.sh" "$root/.claude/hooks/hook-gate.sh"
  printf 'hqVersion: "15.0.131"\n' > "$root/core/core.yaml"
  cat > "$root/.claude/hooks/hook-registry.json" <<'JSON'
{"hooks":{
  "PreToolUse":[{"matcher":"Bash","hooks":[
    {"id":"block-hq-worktree-session","script":".claude/hooks/children/pre-worktree.sh","timeout":30,"gated":false,"args":["PreToolUse"],"runner":"source"},
    {"id":"mandatory-scope-authorizer","script":".claude/hooks/children/pre-scope.sh","timeout":30,"gated":false,"args":["PreToolUse"],"runner":"source"},
    {"id":"detect-secrets","script":".claude/hooks/children/pre-secrets.sh","timeout":30,"gated":false,"args":["PreToolUse"],"runner":"source"},
    {"id":"block-core-writes-bash","script":".claude/hooks/children/pre-core-write.sh","timeout":30,"gated":false,"args":["PreToolUse"],"runner":"source"},
    {"id":"block-unsafe-package-install","script":".claude/hooks/children/pre-install.sh","timeout":30,"gated":false,"args":["PreToolUse"],"runner":"source"}
  ]}],
  "SessionStart":[{"matcher":"","hooks":[
    {"id":"block-hq-worktree-session","script":".claude/hooks/children/start-worktree.sh","timeout":30,"gated":false,"args":["SessionStart"],"runner":"source"},
    {"id":"inject-local-context","script":".claude/hooks/children/start-context.sh","timeout":30,"gated":false,"args":["SessionStart"],"runner":"source"},
    {"id":"check-hq-update","script":".claude/hooks/children/start-update.sh","timeout":30,"gated":false,"args":["SessionStart"],"runner":"source"},
    {"id":"session-title","script":".claude/hooks/children/start-title.sh","timeout":30,"gated":false,"args":["SessionStart"],"runner":"source"}
  ]}]
}}
JSON
  for name in pre-worktree pre-scope pre-secrets pre-core-write pre-install start-worktree start-context start-update start-title; do
    cat > "$root/.claude/hooks/children/$name.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
case "${BASH_SOURCE[0]##*/}" in
  pre-*) parsed="$(jq -r '.tool_input.command // ""' 2>/dev/null)" ;;
  start-*) parsed="$(jq -r '.source // ""' 2>/dev/null)" ;;
esac
case "$parsed" in
  "git status --short"|startup) : ;;
  *) exit 0 ;;
esac
printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}' \
  "${1:-unknown}" "${BASH_SOURCE[0]##*/}"
exit 0
SH
    chmod +x "$root/.claude/hooks/children/$name.sh"
  done
}

make_fixture "$BASE_FIXTURE" "$BASE_SOURCE"
make_fixture "$CANDIDATE_FIXTURE" "$CANDIDATE_SOURCE"

for tool in awk bash cat date grep head jq mkdir mv rm rmdir sed sha256sum sleep sort timeout tr uname wc tail setsid; do
  resolved="$(type -P "$tool" || true)"
  [ -n "$resolved" ] || fail "required tool not found: $tool"
  ln -s "$resolved" "$TOOLS/$tool"
done

payload_for() {
  local root="$1" event="$2"
  if [ "$event" = "PreToolUse" ]; then
    printf '{"session_id":"process-budget-session","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status --short"}}' "$root"
  else
    printf '{"session_id":"process-budget-session","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$root"
  fi
}

run_event() {
  local root="$1" event="$2" trace="$3" payload rc
  payload="$(payload_for "$root" "$event")"
  set +e
  env -u BASH_ENV -u ENV PATH="$TOOLS" HOME="$TMP/home-${root##*-}" HQ_HOOK_TIMEOUT_SENTRY=0 \
    timeout 30s "$STRACE" -f -qq -e trace=execve,clone,clone3,fork,vfork \
      -o "$trace" "$BASH_BIN" "$root/.claude/hooks/master-hook.sh" "$event" \
      <<<"$payload" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "$event fixture exited $rc"
  [ -s "$trace" ] || fail "$event strace produced no data"
}

syscall_count() {
  awk -v kind="$2" '
    kind == "execve" && /execve\(/ { count++ }
    kind == "forks" && / (clone|clone3|fork|vfork)\(/ { count++ }
    END { print count + 0 }
  ' "$1"
}

timestamp_substitution_count() {
  awk '
    index($0, "child_started_ms=\"$(master_now_ms)\"") { count++ }
    index($0, "child_ended_ms=\"$(master_now_ms)\"") { count++ }
    END { print count + 0 }
  ' "$1"
}

timestamp_global_count() {
  awk '
    index($0, "child_started_ms=\"$MASTER_NOW_MS\"") { count++ }
    index($0, "child_ended_ms=\"$MASTER_NOW_MS\"") { count++ }
    END { print count + 0 }
  ' "$1"
}

DIRECT_TIMESTAMP_CALLS="$(timestamp_global_count "$CANDIDATE_SOURCE/.claude/hooks/master-hook.sh")"
[ "$DIRECT_TIMESTAMP_CALLS" -eq 4 ] \
  || fail "expected four child timing reads from MASTER_NOW_MS at dispatch seam (found $DIRECT_TIMESTAMP_CALLS)"

measure_event() {
  local event="$1" expected_hooks expected_timestamp_forks
  local base_timestamp_subs candidate_timestamp_globals
  case "$event" in
    PreToolUse) expected_hooks=5 ;;
    SessionStart) expected_hooks=4 ;;
    *) fail "unexpected event in dispatch timestamp regression: $event" ;;
  esac
  expected_timestamp_forks="$((expected_hooks * 2))"
  local base_trace="$TMP/$event-base.trace" candidate_trace="$TMP/$event-candidate.trace"
  local base_started_ns base_finished_ns candidate_started_ns candidate_finished_ns
  base_started_ns="$(date +%s%N)"
  run_event "$BASE_FIXTURE" "$event" "$base_trace"
  base_finished_ns="$(date +%s%N)"
  candidate_started_ns="$(date +%s%N)"
  run_event "$CANDIDATE_FIXTURE" "$event" "$candidate_trace"
  candidate_finished_ns="$(date +%s%N)"
  local base_execs candidate_execs base_forks candidate_forks
  local base_wall_ms candidate_wall_ms
  base_execs="$(syscall_count "$base_trace" execve)"
  candidate_execs="$(syscall_count "$candidate_trace" execve)"
  base_forks="$(syscall_count "$base_trace" forks)"
  candidate_forks="$(syscall_count "$candidate_trace" forks)"
  base_wall_ms="$(((base_finished_ns - base_started_ns) / 1000000))"
  candidate_wall_ms="$(((candidate_finished_ns - candidate_started_ns) / 1000000))"
  printf '%s: execve base=%s candidate=%s; fork/clone base=%s candidate=%s; wall_ms base=%s candidate=%s\n' \
    "$event" "$base_execs" "$candidate_execs" "$base_forks" "$candidate_forks" "$base_wall_ms" "$candidate_wall_ms"
  if [ "$SOURCES_CHANGED" -eq 1 ]; then
    echo "$event: hook sources changed from base; requiring no regression (execve candidate=$candidate_execs base=$base_execs; fork/clone candidate=$candidate_forks base=$base_forks)"
  else
    echo "$event: hook sources unchanged from base; requiring no regression (execve candidate=$candidate_execs base=$base_execs; fork/clone candidate=$candidate_forks base=$base_forks)"
  fi
  [ "$candidate_execs" -le "$base_execs" ] \
    || fail "$event increased execve count (candidate=$candidate_execs base=$base_execs)"
  [ "$candidate_forks" -le "$base_forks" ] \
    || fail "$event increased fork/clone count (candidate=$candidate_forks base=$base_forks)"
  base_timestamp_subs="$(timestamp_substitution_count "$BASE_SOURCE/.claude/hooks/master-hook.sh")"
  candidate_timestamp_globals="$(timestamp_global_count "$CANDIDATE_SOURCE/.claude/hooks/master-hook.sh")"
  if [ "$base_timestamp_subs" -eq 4 ] && [ "$candidate_timestamp_globals" -eq 4 ]; then
    [ "$candidate_forks" -le "$((base_forks - expected_timestamp_forks))" ] \
      || fail "$event did not remove two timestamp command-substitution forks per hook (expected at least $expected_timestamp_forks fewer; candidate=$candidate_forks base=$base_forks)"
    echo "$event: removed at least $expected_timestamp_forks timestamp subshell forks across $expected_hooks hooks"
  fi
}

measure_event PreToolUse
measure_event SessionStart
