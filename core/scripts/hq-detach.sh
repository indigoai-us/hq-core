#!/usr/bin/env bash
# hq-core: public
# hq-detach.sh — start a command in a new POSIX session so a parent turn
# sweep cannot reap it. Linux has setsid(1); stock macOS does not.
#
# Usage:
#   bash core/scripts/hq-detach.sh [--pidfile PATH] [--logfile PATH] -- <command>...
#
# The child leads its own session (sid == pgid == pid of the session leader).
# stdin is /dev/null. stdout/stderr go to --logfile or /dev/null.
# Runtime: setsid(1) or node child.detached.

set -euo pipefail

PIDFILE=""
LOGFILE="/dev/null"
CMD=()

while [ $# -gt 0 ]; do
  case "$1" in
    --pidfile) PIDFILE="${2:-}"; shift 2 ;;
    --logfile) LOGFILE="${2:-}"; shift 2 ;;
    --) shift; CMD=("$@"); break ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "hq-detach: unexpected argument: $1 (use -- before the command)" >&2
      exit 2
      ;;
  esac
done

if [ ${#CMD[@]} -eq 0 ]; then
  echo "hq-detach: missing command after --" >&2
  exit 2
fi

write_pid() {
  local pid="$1"
  [ -n "$PIDFILE" ] || return 0
  mkdir -p "$(dirname "$PIDFILE")" 2>/dev/null || true
  printf '%s\n' "$pid" > "$PIDFILE"
}

if [ "${HQ_DETACH_FORCE_NODE:-}" != "1" ] && command -v setsid >/dev/null 2>&1; then
  setsid "${CMD[@]}" </dev/null >>"$LOGFILE" 2>&1 &
  write_pid "$!"
  disown "$!" 2>/dev/null || true
  exit 0
fi

NODE="${HQ_DETACH_NODE:-node}"
if ! command -v "$NODE" >/dev/null 2>&1; then
  echo "hq-detach: neither setsid(1) nor $NODE is available" >&2
  exit 1
fi

# argv: node -e <script> -- <cmd...>
export HQ_DETACH_LOGFILE="$LOGFILE"
CHILD_PID="$("$NODE" -e '
const {spawn} = require("child_process");
const fs = require("fs");
const cmd = process.argv.slice(1);
if (!cmd.length) process.exit(2);
const logfile = process.env.HQ_DETACH_LOGFILE || "/dev/null";
const out = fs.openSync(logfile, "a");
const child = spawn(cmd[0], cmd.slice(1), {
  detached: true,
  stdio: ["ignore", out, out],
});
fs.closeSync(out);
child.unref();
process.stdout.write(String(child.pid));
' -- "${CMD[@]}")"
write_pid "$CHILD_PID"
exit 0
