#!/usr/bin/env bash
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
hook=${1:-"$root/.claude/hooks/block-hq-glob.sh"}
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
export GLOB_ORDER_MARKER="$test_root/consumer-wrote"
cat > "$test_root/runner.sh" <<'RUNNER'
set -u
umask "${2:-022}"
printf() {
  deadline=$((SECONDS + 20))
  while [ ! -f "$GLOB_ORDER_MARKER" ]; do
    if [ "$SECONDS" -ge "$deadline" ]; then return 90; fi
  done
  builtin printf 'producer diagnostic\n' >&2
  builtin printf "$@"
}
jq() {
  builtin printf 'consumer\0diagnostic\r\n\n\0' >&2
  : > "$GLOB_ORDER_MARKER"
  command cat >/dev/null
  return 4
}
unset HQ_HOOK_TOOL_NAME
source "$1"
RUNNER
printf 'not json' | bash "$test_root/runner.sh" "$hook" "${GLOB_TEST_UMASK:-022}" > "$test_root/stdout" 2> "$test_root/stderr"
printf 'producer diagnostic\nconsumer\0diagnostic\r\n\n\0' > "$test_root/expected"
test ! -s "$test_root/stdout"
if ! cmp "$test_root/expected" "$test_root/stderr"; then
  printf 'FAIL: jq diagnostics escaped before the input pipeline completed\n' >&2
  cat "$test_root/stderr" >&2
  exit 1
fi
printf 'PASS: exact diagnostic ordering and stdout\n'
