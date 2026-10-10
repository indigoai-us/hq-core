#!/usr/bin/env bash
set -euo pipefail

ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/hq" <<'FAKE_HQ'
#!/usr/bin/env bash
set -euo pipefail
printf '<%s>' "$@" >> "$HQ_CALL_LOG"
printf '\n' >> "$HQ_CALL_LOG"
case " $* " in
  ' lanes link open '*)
    printf '%s\n' '{"link":"cl-test","join":"/conduct-join cl-test"}' ;;
  ' lanes link join '*)
    printf '%s\n' '{"link":"cl-test","name":"worker","conductor_host_session":"desktop-1"}' ;;
  ' lanes link send '*)
    printf '%s\n' '{"queued":true,"children":1}' ;;
  ' lanes link report '*)
    printf '%s\n' '{"queued":true,"conductor_host_session":"desktop-1"}' ;;
  ' lanes link list '*)
    printf '%s\n' '{"link":"cl-test","unread_reports":1,"children":[{"name":"worker","state":"working","undelivered":0}]}' ;;
  ' lanes link read '*)
    printf '%s\n' '{"messages":"[from worker] done"}' ;;
  ' lanes link inbox '*)
    printf '%s\n' '{"messages":"new instruction"}' ;;
  ' lanes link wait '* )
    if [[ "${HQ_FAKE_WAIT:-pending}" == timeout ]]; then
      printf '%s\n' '{"pending":false,"timeout":true}'
      exit 3
    fi
    printf '%s\n' '{"pending":true}' ;;
  ' lanes link _deliver '*)
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"new instruction"}}' ;;
  *)
    printf 'unexpected fake hq argv: %s\n' "$*" >&2
    exit 90 ;;
esac
FAKE_HQ
chmod +x "$TMP/bin/hq"
export PATH="$TMP/bin:$PATH"
export HQ_CALL_LOG="$TMP/calls.log"
: > "$HQ_CALL_LOG"

skills=(
  "$ROOT/.claude/skills/conduct/adopt.md"
  "$ROOT/.claude/skills/conduct-join/SKILL.md"
  "$ROOT/.claude/skills/super-conductor/SKILL.md"
  "$ROOT/.claude/skills/overnight/SKILL.md"
)
for skill in "${skills[@]}"; do
  grep -Eq 'hq lanes link' "$skill" || {
    echo "session-link skill does not use hq lanes link: $skill" >&2
    exit 1
  }
done
if grep -En 'conduct-pool\.sh|conduct-inbox\.sh|conduct-link\.sh|conduct-reap\.sh|conduct-lane-status\.sh|conduct-lane-launch\.sh|conduct-lane-wait\.sh|conduct-lane-inbox\.sh|workspace/conduct-links/' "${skills[@]}"; then
  echo 'session-link skill still refers to a removed conduct script or storage path' >&2
  exit 1
fi

open_json="$(hq lanes link open --engine codex)"
[[ "$(jq -r '.link' <<<"$open_json")" == cl-test ]]
[[ "$(jq -r '.join' <<<"$open_json")" == '/conduct-join cl-test' ]]

join_json="$(hq lanes link join --link cl-test --name worker --engine codex)"
[[ "$(jq -r '.conductor_host_session' <<<"$join_json")" == desktop-1 ]]

send_json="$(hq lanes link send --child worker --text instruction)"
[[ "$(jq -r '.queued' <<<"$send_json")" == true ]]
report_json="$(hq lanes link report --state done --text result)"
[[ "$(jq -r '.queued' <<<"$report_json")" == true ]]

list_json="$(hq lanes link list)"
[[ "$(jq -r '.children[0].state' <<<"$list_json")" == working ]]
[[ "$(jq -r '.unread_reports' <<<"$list_json")" == 1 ]]
read_json="$(hq lanes link read)"
[[ "$(jq -r '.messages' <<<"$read_json")" == '[from worker] done' ]]

pending_json="$(hq lanes link wait --timeout 1)"
[[ "$(jq -r '.pending' <<<"$pending_json")" == true ]]
set +e
timeout_json="$(HQ_FAKE_WAIT=timeout hq lanes link wait --timeout 0)"
timeout_code=$?
set -e
[[ "$timeout_code" == 3 ]]
[[ "$(jq -r '.timeout' <<<"$timeout_json")" == true ]]

hq lanes link inbox >/dev/null
hq lanes link _deliver --event PostToolUse >/dev/null
grep -Eq '^<lanes><link><open><--engine><codex>$' "$HQ_CALL_LOG"
grep -Eq '^<lanes><link><_deliver><--event><PostToolUse>$' "$HQ_CALL_LOG"

echo 'conduct-session-links-use-hq-lanes: passed'
