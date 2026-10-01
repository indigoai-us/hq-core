#!/usr/bin/env bash
# hq-core: public
# hq-detach.sh — detach a command from the parent turn so its cleanup sweep
# cannot reap it. Linux has setsid(1); stock macOS does not.
#
# Usage:
#   bash core/scripts/hq-detach.sh [--handoff] [--pidfile PATH] [--owner-pidfile PATH] [--logfile PATH] -- <command>...
#
# The child leads its own session (sid == pgid == pid of the session leader).
# stdin is /dev/null. stdout/stderr go to --logfile or /dev/null.
# --handoff uses nohup on Linux/macOS and a hidden Node child on Git Bash/MSYS/Cygwin.

set -euo pipefail

PIDFILE=""
OWNER_PIDFILE=""
LOGFILE="/dev/null"
HANDOFF_MODE=0
CMD=()

while [ $# -gt 0 ]; do
  case "$1" in
    --handoff) HANDOFF_MODE=1; shift ;;
    --pidfile) PIDFILE="${2:-}"; shift 2 ;;
    --owner-pidfile) OWNER_PIDFILE="${2:-}"; shift 2 ;;
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

# A caller can ask us to capture the current session owner before the child is
# detached. PID plus process start time prevents a reused PID from making an
# orphan look supervised.
process_args() {
  local target="$1"
  # `ps -eww` avoids argument truncation; filter its complete listing back to
  # the exact PID because combining -e and -p selects all processes on Linux.
  ps -eww -o pid=,args= 2>/dev/null | awk -v target="$target" '$1 == target { $1=""; sub(/^[[:space:]]+/, ""); print; exit }'
}

is_session_command() {
  local cmd="$1" executable script third
  executable="$(printf '%s\n' "$cmd" | awk '{print $1}')"
  script="$(printf '%s\n' "$cmd" | awk '{print $2}')"
  third="$(printf '%s\n' "$cmd" | awk '{print $3}')"
  case "${executable##*/}" in
    claude|codex|codex-code-mode-host|grok|grok-cli) return 0 ;;
    bash|sh|zsh|dash|ksh|node)
      case "${script##*/}" in claude|codex|codex-code-mode-host|grok|grok-cli) return 0 ;; esac
      ;;
    env)
      case "${script##*/}" in
        claude|codex|codex-code-mode-host|grok|grok-cli) return 0 ;;
        bash|sh|zsh|dash|ksh)
          case "${third##*/}" in claude|codex|codex-code-mode-host|grok|grok-cli) return 0 ;; esac
          ;;
      esac
      ;;
  esac
  return 1
}

write_owner() {
  local candidate="$PPID" hops=0 args parent started=""
  [ -n "$OWNER_PIDFILE" ] || return 0
  while [ -n "$candidate" ] && [ "$candidate" != "0" ] && [ "$candidate" != "1" ] && [ "$hops" -lt 24 ]; do
    args="$(process_args "$candidate" || true)"
    if is_session_command "$args"; then
      started="$(ps -o lstart= -p "$candidate" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
      if [ -n "$started" ]; then
        mkdir -p "$(dirname "$OWNER_PIDFILE")" 2>/dev/null || true
        printf '%s\n%s\n' "$candidate" "$started" > "$OWNER_PIDFILE"
      fi
      return 0
    fi
    parent="$(ps -o ppid= -p "$candidate" 2>/dev/null | tr -d '[:space:]' || true)"
    candidate="$parent"
    hops=$((hops + 1))
  done
  return 0
}

write_owner
WINDOWS_SHELL=0
if [ "$HANDOFF_MODE" = "1" ]; then
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) WINDOWS_SHELL=1 ;;
  esac
  if [ "$WINDOWS_SHELL" = "0" ]; then
    nohup "${CMD[@]}" </dev/null >>"$LOGFILE" 2>&1 &
    write_pid "$!"
    disown "$!" 2>/dev/null || true
    exit 0
  fi
fi

# setsid(1) lookup. Linux has it on PATH. On macOS it arrives only via Homebrew
# util-linux, which is keg-only — not symlinked into the PATH — so probe the keg
# prefixes directly rather than assuming an interactive shell exported them.
SETSID_BIN=""
if [ "${HQ_DETACH_FORCE_NODE:-}" != "1" ] && [ "$WINDOWS_SHELL" = "0" ]; then
  for candidate in setsid /opt/homebrew/opt/util-linux/bin/setsid /usr/local/opt/util-linux/bin/setsid; do
    if command -v "$candidate" >/dev/null 2>&1; then
      SETSID_BIN="$candidate"
      break
    fi
  done
fi

if [ -n "$SETSID_BIN" ]; then
  "$SETSID_BIN" "${CMD[@]}" </dev/null >>"$LOGFILE" 2>&1 &
  write_pid "$!"
  disown "$!" 2>/dev/null || true
  exit 0
fi

NODE="${HQ_DETACH_NODE:-node}"
if ! command -v "$NODE" >/dev/null 2>&1; then
  echo "hq-detach: neither setsid(1) nor $NODE is available" >&2
  exit 1
fi

# Native Windows Node cannot open MSYS paths such as /tmp/x.log, so hand it a
# C:/... form (same conversion as portable_native_path in lib/portable.sh).
if [ "$WINDOWS_SHELL" = "1" ] && [ "$LOGFILE" != "/dev/null" ] && command -v cygpath >/dev/null 2>&1; then
  LOGFILE="$(cygpath -m "$LOGFILE" 2>/dev/null || printf '%s' "$LOGFILE")"
fi

# argv: node -e <script> -- <cmd...>
export HQ_DETACH_LOGFILE="$LOGFILE"
[ "$WINDOWS_SHELL" = "0" ] || export HQ_DETACH_WINDOWS_SHELL=1
CHILD_PID="$("$NODE" -e '
const {spawn} = require("child_process");
const fs = require("fs");
const cmd = process.argv.slice(1);
if (!cmd.length) process.exit(2);
const logfile = process.env.HQ_DETACH_LOGFILE || "/dev/null";
const out = logfile === "/dev/null" ? "ignore" : fs.openSync(logfile, "a");
const child = spawn(cmd[0], cmd.slice(1), {
  detached: true,
  windowsHide: process.platform === "win32" || process.env.HQ_DETACH_WINDOWS_SHELL === "1",
  stdio: ["ignore", out, out],
});
if (out !== "ignore") fs.closeSync(out);
child.unref();
process.stdout.write(String(child.pid));
' -- "${CMD[@]}")"
write_pid "$CHILD_PID"
exit 0
