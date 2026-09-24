#!/usr/bin/env bash
# Bare Monitor-expiry notifications skip notification-irrelevant enrichers.
set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
MASTER="$HQ_SRC/.claude/hooks/master-hook.sh"
GATE="$HQ_SRC/.claude/hooks/hook-gate.sh"
[ -f "$MASTER" ] || fail "master hook is missing"
[ -f "$GATE" ] || fail "hook gate is missing"
command -v jq >/dev/null 2>&1 || fail "jq is required"

ROOT="$TMP/hq"
mkdir -p "$ROOT/.claude/hooks" "$ROOT/core/hooks/UserPromptSubmit" \
  "$ROOT/personal/hooks/UserPromptSubmit" "$ROOT/workspace/sessions" "$TMP/bin"
cp "$MASTER" "$ROOT/.claude/hooks/master-hook.sh"
cp "$GATE" "$ROOT/.claude/hooks/hook-gate.sh"
chmod +x "$ROOT/.claude/hooks/master-hook.sh" "$ROOT/.claude/hooks/hook-gate.sh"

cat > "$ROOT/.claude/hooks/rewrite-resume-sentinel.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'rewrite\n' >> "$HQ_TEST_MARKER"
SH
cat > "$ROOT/.claude/hooks/session-title.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'title\n' >> "$HQ_TEST_MARKER"
SH
for hook in route-deep-plan-to-skill auto-session-project natural-language-router; do
  cat > "$ROOT/.claude/hooks/$hook.sh" <<SH
#!/usr/bin/env bash
cat >/dev/null
printf '%s\\n' '$hook' >> "\$HQ_TEST_MARKER"
SH
done
cat > "$ROOT/.claude/hooks/inject-policy-on-trigger.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'inject\n' >> "$HQ_TEST_MARKER"
SH
cat > "$TMP/bin/hq_hook_profile_allows" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/bin/hq_hook_profile_allows"
cat > "$ROOT/.claude/hooks/hook-registry.json" <<'JSON'
{"hooks":{"UserPromptSubmit":[{"matcher":"","hooks":[
  {"id":"rewrite-resume-sentinel","script":".claude/hooks/rewrite-resume-sentinel.sh","timeout":30,"gated":false},
  {"id":"route-deep-plan-to-skill","script":".claude/hooks/route-deep-plan-to-skill.sh","timeout":30,"gated":false},
  {"id":"auto-session-project","script":".claude/hooks/auto-session-project.sh","timeout":30,"gated":false},
  {"id":"natural-language-router","script":".claude/hooks/natural-language-router.sh","timeout":30,"gated":false},
  {"id":"session-title","script":".claude/hooks/session-title.sh","timeout":30,"gated":false},
  {"id":"inject-policy-on-trigger","script":".claude/hooks/inject-policy-on-trigger.sh","timeout":60,"gated":false}
]}]}}
JSON
for hook in 30-ensure-hq-cli 31-ensure-hq-desktop 35-work-mesh-turn-start 40-skill-command-script; do
  case "$hook" in
    30-*) marker=cli ;;
    31-*) marker=desktop ;;
    35-*) marker=turn-start ;;
    40-*) marker=core-skill ;;
  esac
  cat > "$ROOT/core/hooks/UserPromptSubmit/$hook.sh" <<SH
#!/usr/bin/env bash
cat >/dev/null
printf '%s\\n' '$marker' >> "\$HQ_TEST_MARKER"
SH
done
cat > "$ROOT/core/hooks/UserPromptSubmit/45-lanes-senior-monitor.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'monitor\n' >> "$HQ_TEST_MARKER"
SH
cat > "$ROOT/core/hooks/UserPromptSubmit/70-work-mesh-ground.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'ground\n' >> "$HQ_TEST_MARKER"
SH
cat > "$ROOT/personal/hooks/UserPromptSubmit/repos-sync.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'sync\n' >> "$HQ_TEST_MARKER"
SH
cat > "$ROOT/personal/hooks/UserPromptSubmit/40-skill-command-script.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'personal-skill\n' >> "$HQ_TEST_MARKER"
SH
chmod +x "$ROOT/core/hooks/UserPromptSubmit/45-lanes-senior-monitor.sh" \
  "$ROOT/core/hooks/UserPromptSubmit/70-work-mesh-ground.sh" \
  "$ROOT/core/hooks/UserPromptSubmit/30-ensure-hq-cli.sh" \
  "$ROOT/core/hooks/UserPromptSubmit/31-ensure-hq-desktop.sh" \
  "$ROOT/core/hooks/UserPromptSubmit/35-work-mesh-turn-start.sh" \
  "$ROOT/core/hooks/UserPromptSubmit/40-skill-command-script.sh" \
  "$ROOT/.claude/hooks/rewrite-resume-sentinel.sh" \
  "$ROOT/.claude/hooks/route-deep-plan-to-skill.sh" \
  "$ROOT/.claude/hooks/auto-session-project.sh" \
  "$ROOT/.claude/hooks/natural-language-router.sh" \
  "$ROOT/.claude/hooks/session-title.sh" \
  "$ROOT/.claude/hooks/inject-policy-on-trigger.sh" \
  "$ROOT/personal/hooks/UserPromptSubmit/repos-sync.sh" \
  "$ROOT/personal/hooks/UserPromptSubmit/40-skill-command-script.sh"

MARKER="$TMP/ran"
run_prompt() {
  local prompt="$1" sid="$2" payload
  payload="$(jq -cn --arg prompt "$prompt" --arg sid "$sid" --arg cwd "$ROOT" \
    '{session_id:$sid,cwd:$cwd,prompt:$prompt}')"
  printf '%s' "$payload" | env PATH="$TMP/bin:$PATH" HQ_TEST_MARKER="$MARKER" HOME="$TMP/home" \
    HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_TRACE=1 \
    bash "$ROOT/.claude/hooks/master-hook.sh" UserPromptSubmit \
    > "$TMP/out" 2> "$TMP/err"
}

: > "$MARKER"
run_prompt '[Monitor timed out — re-arm if needed.]' monitor-expiry-exact
[ "$(cat "$MARKER")" = $'inject\nturn-start' ] \
  || fail "bare expiry notification did not retain injection and turn-start: $(cat "$MARKER")"
grep -Fq 'skip rewrite-resume-sentinel (monitor-expiry-notification)' "$TMP/err" \
  || fail "trace did not identify skipped resume-rewrite hook: $(cat "$TMP/err")"
grep -Fq 'skip route-deep-plan-to-skill (monitor-expiry-notification)' "$TMP/err" \
  || fail "trace did not identify skipped deep-plan route hook: $(cat "$TMP/err")"
grep -Fq 'skip auto-session-project (monitor-expiry-notification)' "$TMP/err" \
  || fail "trace did not identify skipped session-project hook: $(cat "$TMP/err")"
grep -Fq 'skip natural-language-router (monitor-expiry-notification)' "$TMP/err" \
  || fail "trace did not identify skipped natural-language route hook: $(cat "$TMP/err")"
grep -Fq 'skip session-title (monitor-expiry-notification)' "$TMP/err" \
  || fail "trace did not identify skipped session-title hook: $(cat "$TMP/err")"
grep -Fq 'skip 30-ensure-hq-cli.sh (monitor-expiry-notification)' "$TMP/err" \
  || fail "trace did not identify skipped HQ CLI update hook"
grep -Fq 'skip 31-ensure-hq-desktop.sh (monitor-expiry-notification)' "$TMP/err" \
  || fail "trace did not identify skipped HQ Desktop update hook"
grep -Fq 'skip 40-skill-command-script.sh (monitor-expiry-notification)' "$TMP/err" \
  || fail "trace did not identify skipped skill-command hook"
grep -Fq 'skip repos-sync.sh (monitor-expiry-notification)' "$TMP/err" \
  || fail "trace did not identify skipped repos-sync hook"
grep -Fq 'skip 45-lanes-senior-monitor.sh (monitor-expiry-notification)' "$TMP/err" \
  || fail "trace did not identify skipped lane-monitor hook"
grep -Fq 'skip 70-work-mesh-ground.sh (monitor-expiry-notification)' "$TMP/err" \
  || fail "trace did not identify skipped work-mesh hook"

: > "$MARKER"
run_prompt '[Monitor timed out — re-arm if needed.] Then check why the deploy stopped.' monitor-expiry-action
[ "$(cat "$MARKER")" = $'rewrite\nroute-deep-plan-to-skill\nauto-session-project\nnatural-language-router\ntitle\ninject\ncli\ndesktop\nturn-start\ncore-skill\nmonitor\nground\npersonal-skill\nsync' ] \
  || fail "actionable prompt failed to preserve normal dispatch: $(cat "$MARKER")"
printf 'PASS: bare Monitor notification retained policy injection and skipped irrelevant enrichers; actionable prompt dispatched normally\n'

# The always-on directory dispatcher must keep the same fast path when the
# project hook registry is absent. Put a session-title hook in the directory
# population so the V6 mutation is observable through this public dispatch path.
cat > "$ROOT/core/hooks/UserPromptSubmit/inject-policy-on-trigger.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'inject\n' >> "$HQ_TEST_MARKER"
SH
cat > "$ROOT/core/hooks/UserPromptSubmit/session-title.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'title\n' >> "$HQ_TEST_MARKER"
SH
chmod +x "$ROOT/core/hooks/UserPromptSubmit/inject-policy-on-trigger.sh" \
  "$ROOT/core/hooks/UserPromptSubmit/session-title.sh" \
  "$ROOT/core/hooks/UserPromptSubmit/35-work-mesh-turn-start.sh"
rm "$ROOT/.claude/hooks/hook-registry.json"

: > "$MARKER"
run_prompt '[Monitor timed out — re-arm if needed.]' monitor-expiry-directory-loop
directory_counts="$(awk '
  $0 == "inject" { inject++ }
  $0 == "turn-start" { turn_start++ }
  END { printf "%d %d %d\n", NR, inject, turn_start }
' "$MARKER")"
[ "$directory_counts" = "2 1 1" ] \
  || fail "non-registry expiry dispatch must run only policy injection and turn-start; counts=$directory_counts markers=$(cat "$MARKER")"
for skipped_hook in session-title.sh 30-ensure-hq-cli.sh 31-ensure-hq-desktop.sh \
  40-skill-command-script.sh repos-sync.sh 45-lanes-senior-monitor.sh \
  70-work-mesh-ground.sh; do
  grep -Fq "skip $skipped_hook (monitor-expiry-notification)" "$TMP/err" \
    || fail "non-registry trace did not identify skipped $skipped_hook: $(cat "$TMP/err")"
done
printf 'PASS: non-registry Monitor dispatch skipped irrelevant directory hooks and retained policy injection plus turn-start\n'
