#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "${BASH_SOURCE[0]%/*}/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/session-title-project-resolution.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

HQ="$TMP/hq"
HOME_FIXTURE="$TMP/home"
BIN="$TMP/bin"
mkdir -p "$HQ/.claude/hooks" "$HQ/.claude/state" "$HQ/core/scripts" \
  "$HQ/companies/alpha" "$HOME_FIXTURE/.hq/work-context/sessions" "$BIN"
cp "$ROOT/.claude/hooks/auto-session-project.sh" "$HQ/.claude/hooks/auto-session-project.sh"
cp "$ROOT/.claude/hooks/session-title.sh" "$HQ/.claude/hooks/session-title.sh"
cp "$ROOT/core/scripts/hook-lib.sh" "$HQ/core/scripts/hook-lib.sh"
cp "$ROOT/core/scripts/session-title.sh" "$HQ/core/scripts/session-title.sh"
cp "$ROOT/core/scripts/session-title-config.sh" "$HQ/core/scripts/session-title-config.sh"
chmod +x "$HQ/core/scripts/session-title.sh"
printf 'companies:\n  alpha:\n' > "$HQ/companies/manifest.yaml"
printf '%s\n' '#!/usr/bin/env bash' 'printf called >> "${HQ_TEST_SLEEP_LOG:?}"' > "$BIN/sleep"
chmod +x "$BIN/sleep"

run_project_hook() {
  local sid="$1" payload
  payload="$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"hello","session_id":"%s"}' "$sid")"
  printf '%s' "$payload" | env HQ_ROOT="$HQ" CLAUDE_PROJECT_DIR="$HQ" \
    HOME="$HOME_FIXTURE" WORK_MESH_HOME="$HOME_FIXTURE" \
    bash "$HQ/.claude/hooks/auto-session-project.sh" >/dev/null
}

run_title_hook() {
  local sid="$1" payload
  payload="$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"hello","session_id":"%s"}' "$sid")"
  printf '%s' "$payload" | env HQ_ROOT="$HQ" CLAUDE_PROJECT_DIR="$HQ" \
    HOME="$HOME_FIXTURE" WORK_MESH_HOME="$HOME_FIXTURE" PATH="$BIN:$PATH" \
    HQ_TEST_SLEEP_LOG="$TMP/sleep.log" HQ_SESSION_TITLE=auto \
    bash "$HQ/.claude/hooks/session-title.sh" >/dev/null
}

NO_PROJECT_SID=no-project
run_project_hook "$NO_PROJECT_SID"
NO_PROJECT_MARKER="$HQ/.claude/state/auto-session-project-$NO_PROJECT_SID"
run_title_hook "$NO_PROJECT_SID"
[ ! -s "$TMP/sleep.log" ] || fail 'title hook waited after no-project resolution completed'
[ -f "$NO_PROJECT_MARKER" ] || fail 'no-project resolution did not publish its completion marker'
[ ! -s "$NO_PROJECT_MARKER" ] || fail 'no-project completion marker must stay empty'
pass 'resolved no-project state skips the first-prompt wait'

BOUND_SID=bound-project
mkdir -p "$HOME_FIXTURE/.hq/work-context/sessions"
printf '%s\n' '{"contextStatus":"bound","companySlug":"alpha","projectId":"demo","companyUid":"cmp_test"}' \
  > "$HOME_FIXTURE/.hq/work-context/sessions/$BOUND_SID.json"
run_project_hook "$BOUND_SID"
BOUND_MARKER="$HQ/.claude/state/auto-session-project-$BOUND_SID"
run_title_hook "$BOUND_SID"
[ ! -s "$TMP/sleep.log" ] || fail 'title hook waited after bound-project resolution completed'
EXPECTED_PROJECT="$HQ/companies/alpha/projects/demo"
[ "$(cat "$BOUND_MARKER")" = "$EXPECTED_PROJECT" ] || fail 'bound project path was not preserved in the completion marker'
pass 'bound project path remains available without the first-prompt wait'
