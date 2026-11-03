# shellcheck shell=bash
# Start lib/fake-notify-api.mjs for a dm-bind test sandbox and point the
# sandbox's ~/.hq/config.json at it. Compatible with macOS Bash 3.2.
#   fake_notify_api_start <node> <sandbox-home> <roster-file> <sent-file>
# Sets FAKE_NOTIFY_API_PID. The caller's EXIT trap must kill that pid.
fake_notify_api_start() {
  local node_bin="$1" home="$2" roster_file="$3" sent_file="$4"
  local lib_dir port_file tries=0
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  port_file="$home/.fake-notify-api.port"
  rm -f "$port_file"
  "$node_bin" "$lib_dir/fake-notify-api.mjs" "$port_file" "$roster_file" "$sent_file" &
  FAKE_NOTIFY_API_PID=$!
  while [ ! -s "$port_file" ]; do
    tries=$((tries + 1))
    if [ "$tries" -gt 100 ] || ! kill -0 "$FAKE_NOTIFY_API_PID" 2>/dev/null; then
      echo "FAIL: fake notify API did not start" >&2
      return 1
    fi
    sleep 0.1
  done
  mkdir -p "$home/.hq"
  printf '{"vaultApiUrl":"http://127.0.0.1:%s"}\n' "$(cat "$port_file")" > "$home/.hq/config.json"
  printf '{"idToken":"test-human-token"}\n' > "$home/.hq/cognito-tokens.json"
}
