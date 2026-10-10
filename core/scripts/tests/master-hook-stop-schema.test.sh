#!/usr/bin/env bash
# Regression coverage for Claude Code Stop and SubagentStop block output.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/hooks" "$FIX/core/scripts/lib" "$FIX/workspace/sessions"
cp "$ROOT/.claude/hooks/master-hook.sh" "$FIX/.claude/hooks/"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$FIX/.claude/hooks/"
cp "$ROOT/core/scripts/resolve-hq-root.sh" "$FIX/core/scripts/"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIX/core/scripts/lib/"
cp "$ROOT/core/scripts/lib/session-hooks.sh" "$FIX/core/scripts/lib/"
chmod +x "$FIX/.claude/hooks/master-hook.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
failures=0

# Use session-hooks.sh's real reader to prove provenance survives the hook output.
. "$FIX/core/scripts/lib/session-hooks.sh"
export HQ_ROOT="$FIX" HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_DEDUPE=0

run_case() {
  local event="$1" shape="$2" event_dir out rc=0 sid
  event_dir="$FIX/core/hooks/$event"
  out="$TMP/$event-$shape.out"
  sid="cl10-$event-$shape"
  mkdir -p "$event_dir"
  rm -f "$event_dir/"*.sh
  if [ "$shape" = bounded ]; then
    cat > "$event_dir/10-block.sh" <<'EOF'
#!/usr/bin/env bash
pad="$(head -c 70000 /dev/zero | tr '\0' x)"
jq -cn --arg pad "$pad" '{decision:"block",reason:$pad}'
EOF
  else
    cat > "$event_dir/10-block.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"decision":"block","reason":"CL10 fixture block"}'
EOF
  fi
  chmod +x "$event_dir/10-block.sh"
  if [ "$shape" = multi ]; then
    multi_log="$TMP/$event.multi.log"
    cat > "$event_dir/20-context.sh" <<EOF
#!/usr/bin/env bash
printf 'ran\n' >> "$multi_log"
printf '%s\\n' '{"hookSpecificOutput":{"hookEventName":"$event","additionalContext":"sibling output"}}'
EOF
    chmod +x "$event_dir/20-context.sh"
  fi
  mkdir -p "$FIX/workspace/sessions/$sid"
  printf 'session_id: %s\n' "$sid" > "$FIX/workspace/sessions/$sid/meta.yaml"
  printf '%s\n' "$sid" > "$FIX/workspace/sessions/.current"
  SESSION_HOOK_BLOCKED_BY=""
  SESSION_HOOK_BLOCK_JSON=""
  SESSION_HOOK_ERR="$TMP/$event-$shape.err"
  session_run_hook "$FIX" "$event" "$sid" > "$out" || rc=$?
  [ "$rc" -eq 2 ] || fail "$event/$shape expected block status 2, got $rc; stderr=$(cat "$SESSION_HOOK_ERR")"
  if [ "$shape" = multi ] && [ ! -s "$multi_log" ]; then
    fail "$event/$shape did not execute the sibling JSON output hook"
  fi
  if ! jq -e --arg event "$event" --arg hook "10-block.sh" \
    '.decision == "block" and .hookSpecificOutput.hookEventName == $event and (.hookSpecificOutput.hqSessionBlockedBy | endswith($hook))' \
    "$out" >/dev/null; then
    echo "FAIL: $event/$shape invalid block JSON or missing provenance: $(head -c 500 "$out")" >&2
    failures=$((failures + 1))
  fi
  [[ "$SESSION_HOOK_BLOCKED_BY" == *"10-block.sh" ]] || fail "$event/$shape session-hooks reader lost provenance: $SESSION_HOOK_BLOCKED_BY"
  [ "$SESSION_HOOK_BLOCK_JSON" = "$(cat "$out")" ] || fail "$event/$shape session-hooks did not retain block JSON"
  if jq -e --arg event "$event" '.hookSpecificOutput.hookEventName == $event' "$out" >/dev/null; then
    pass "$event/$shape has event schema and session-hooks provenance"
  else
    echo "  observed provenance reader: $SESSION_HOOK_BLOCKED_BY"
  fi
}

for event in Stop SubagentStop; do
  run_case "$event" single
  run_case "$event" multi
  run_case "$event" bounded
done

if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures Stop/SubagentStop schema assertions failed" >&2
  exit 1
fi
echo "PASS: master-hook-stop-schema.test.sh"
