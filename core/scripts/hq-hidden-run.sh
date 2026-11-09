#!/usr/bin/env bash
# hq-core: public
# Run a command without a visible Windows console.
#
#   hq-hidden-run.sh [--wait] [--logfile PATH] -- <command>...
#
# On macOS and Linux this execs the command (--wait) or detaches it with
# hq-detach.sh. On Windows (Git Bash, MSYS, Cygwin) it writes the command into
# a temporary .cmd file and starts that file through windows/hidden-run.vbs
# with wscript.exe, a GUI-subsystem host, so no console window is created.
#
# Windows construction rules:
#   - Every path handed to wscript or cmd.exe is converted with cygpath -w:
#     the .vbs, the .cmd file, the program, the log file and the
#     stdin/stdout/stderr/status files. Arguments to the program are passed
#     through unchanged.
#   - wscript receives two plain arguments (the .cmd path and "wait" or
#     "nowait"). The command line lives in the .cmd file, so no argument
#     carries embedded double quotes across a process boundary.
#   - Each argument is double-quoted inside the .cmd file. Arguments cmd.exe
#     cannot carry literally inside quotes (" % ^ CR LF) are refused with
#     status 2 rather than escaped.
#   - A .cmd file is read in the console code page, not UTF-8. When anything
#     in it is non-ASCII it starts by switching to code page 65001. The first
#     real line checks that the program path resolves; if the path was misread
#     anyway, the run ends without reporting a status or a start marker.
#   - A detached run writes a start marker. If that file does not appear within
#     HQ_HIDDEN_START_TIMEOUT seconds (default 5) the launcher exits 1 with an
#     error on stderr, so wscript's own status 0 is never read as "it ran".
#   - --wait copies this process's stdin to a file and redirects it into the
#     command, then replays the command's stdout and stderr and returns its
#     exit status. A run that reports no status fails (status 1), it never
#     reads as a silent success.
#
# --direct-on-error (with --wait): when the launcher itself cannot run the
# command hidden (no cygpath or wscript, a path cmd.exe cannot quote, no
# status reported), run the command directly instead, with the same stdin.
# A visible console is better than a lost result. Callers whose exit status
# decides something (the checkpoint Stop gate) use this, so a launcher error
# never surfaces as the command's status.
#
# Test knobs for non-Windows hosts:
#   HQ_HIDDEN_WINDOWS_DRY_RUN=1  build the .cmd file with an identity path
#                                conversion, print it, and do not launch.
#   HQ_HIDDEN_FORCE_WINDOWS=1    take the real Windows path (cygpath and
#                                wscript come from PATH / HQ_HIDDEN_WSCRIPT).

set -uo pipefail

WAIT=0
LOGFILE=""
DIRECT_ON_ERROR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --wait) WAIT=1; shift ;;
    --direct-on-error) DIRECT_ON_ERROR=1; shift ;;
    --logfile) LOGFILE="${2:-}"; shift 2 ;;
    --) shift; break ;;
    *) echo "hq-hidden-run: unexpected argument: $1" >&2; exit 2 ;;
  esac
done
[ "$#" -gt 0 ] || { echo "hq-hidden-run: missing command" >&2; exit 2; }

# No subprocess before the POSIX --wait exec: the checkpoint gate counts spawns.
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR=.
WINDOWS=0
case "${OSTYPE:-}" in
  msys*|cygwin*|win32*) WINDOWS=1 ;;
esac
[ "${HQ_HIDDEN_FORCE_WINDOWS:-}" = "1" ] && WINDOWS=1
DRY_RUN=0
if [ "${HQ_HIDDEN_WINDOWS_DRY_RUN:-}" = "1" ]; then
  WINDOWS=1
  DRY_RUN=1
fi

if [ "$WINDOWS" != "1" ]; then
  if [ "$WAIT" = "1" ]; then
    if [ -n "$LOGFILE" ]; then
      "$@" >>"$LOGFILE" 2>&1
    else
      "$@"
    fi
    exit $?
  fi
  DETACH="$SCRIPT_DIR/hq-detach.sh"
  if [ -n "$LOGFILE" ]; then
    bash "$DETACH" --logfile "$LOGFILE" -- "$@"
  else
    bash "$DETACH" -- "$@"
  fi
  exit $?
fi

# ---- Windows ---------------------------------------------------------------

ORIG_ARGV=("$@")
IN=""
# A launcher failure. With --wait --direct-on-error, run the command directly
# (stdin is the caller's, or the copy already taken into $IN).
die() {
  if [ "$WAIT" = "1" ] && [ "$DIRECT_ON_ERROR" = "1" ] && [ "$DRY_RUN" != "1" ]; then
    echo "hq-hidden-run: $2; running it directly" >&2
    if [ -n "$IN" ] && [ -f "$IN" ]; then
      "${ORIG_ARGV[@]}" <"$IN"
      local rc=$?
      [ -z "${RUN_DIR:-}" ] || rm -rf "$RUN_DIR"
      exit "$rc"
    fi
    exec "${ORIG_ARGV[@]}"
  fi
  echo "hq-hidden-run: $2" >&2
  exit "$1"
}

if [ "$DRY_RUN" = "1" ]; then
  winpath() { printf '%s' "$1"; }
else
  command -v cygpath >/dev/null 2>&1 || die 1 "cygpath is required on Windows"
  winpath() { cygpath -w -- "$1"; }
fi

WSCRIPT="${HQ_HIDDEN_WSCRIPT:-}"
if [ -z "$WSCRIPT" ] && [ "$DRY_RUN" != "1" ]; then
  WSCRIPT="$(command -v wscript.exe 2>/dev/null || command -v wscript 2>/dev/null || true)"
  # A trimmed hook PATH can omit System32.
  if [ -z "$WSCRIPT" ] && [ -n "${SYSTEMROOT:-${SystemRoot:-}}" ]; then
    WSCRIPT="$(cygpath -u "${SYSTEMROOT:-${SystemRoot:-}}")/System32/wscript.exe"
    [ -f "$WSCRIPT" ] || WSCRIPT=""
  fi
  [ -n "$WSCRIPT" ] || die 1 "wscript.exe is required on Windows"
fi

# Resolve the program to something cmd.exe can start. npm installs a POSIX
# shim next to a .cmd one (hq and hq.cmd); cmd.exe runs only the .cmd or .exe.
# A #! script with neither companion runs under this bash, never a bash.exe
# found on the Windows PATH (that one can be WSL).
PROG=()
resolve_program() {
  local name="$1" found="" ext self_bash
  case "$name" in
    */*|*\\*) found="$name" ;;
    *) found="$(command -v -- "$name" 2>/dev/null || true)" ;;
  esac
  if [ -z "$found" ] || [ ! -f "$found" ]; then
    found=""
    for ext in .exe .cmd .bat; do
      found="$(command -v -- "$name$ext" 2>/dev/null || true)"
      [ -n "$found" ] && [ -f "$found" ] && break
      found=""
    done
  fi
  [ -n "$found" ] && [ -f "$found" ] || return 1
  case "$found" in
    *.exe|*.EXE|*.cmd|*.CMD|*.bat|*.BAT) PROG=("$(winpath "$found")"); return 0 ;;
  esac
  for ext in .exe .cmd .bat; do
    if [ -f "$found$ext" ]; then
      PROG=("$(winpath "$found$ext")")
      return 0
    fi
  done
  # Not a #! script: an executable cmd.exe can start by its full path.
  local magic=""
  IFS= read -r -n 2 magic <"$found" 2>/dev/null || true
  if [ "$magic" != '#!' ]; then
    PROG=("$(winpath "$found")")
    return 0
  fi
  self_bash="${BASH:-}"
  [ -n "$self_bash" ] && [ -f "$self_bash" ] || self_bash="$(command -v bash 2>/dev/null || true)"
  [ -n "$self_bash" ] || return 1
  [ -f "$self_bash.exe" ] && self_bash="$self_bash.exe"
  PROG=("$(winpath "$self_bash")" "$found")
  return 0
}
resolve_program "$1" || die 127 "command not found: $1"
shift

# Quote one argument for the .cmd file, or refuse it. "!" is safe: cmd.exe
# expands it only with delayed expansion, which /d and the file never enable. Runs in the main shell
# (no command substitution) so a refusal exits the launcher.
QUOTED=""
cmd_arg() {
  case "$1" in
    *'"'*|*%*|*'^'*|*$'\n'*|*$'\r'*)
      die 2 "argument not representable for cmd.exe: $1" ;;
  esac
  QUOTED="\"$1\""
}
LINE="call"
for part in "${PROG[@]}" "$@"; do
  cmd_arg "$part"
  LINE="$LINE $QUOTED"
done

has_non_ascii() {
  local LC_ALL=C
  case "$1" in *[![:ascii:]]*) return 0 ;; esac
  return 1
}

# Start of every .cmd file: UTF-8 when needed, then the program path check.
cmd_preamble() { # <everything the file will hold>
  printf '@echo off\r\n'
  if has_non_ascii "$1"; then
    # Full path: a trimmed hook PATH can omit System32.
    printf '%s\r\n' '"%SystemRoot%\System32\chcp.com" 65001 >NUL'
  fi
  printf 'if not exist %s exit /b 127\r\n' "$Q_PROG"
}

cmd_arg "${PROG[0]}"
Q_PROG="$QUOTED"

TMP_BASE="${TMPDIR:-/tmp}"
# Detached runs cannot delete their own .cmd while it runs; sweep old ones.
find "$TMP_BASE" -maxdepth 1 -type d -name 'hq-hidden.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
RUN_DIR=""
RUN_DIR="$(mktemp -d "$TMP_BASE/hq-hidden.XXXXXX")" || die 1 "cannot create a temporary directory"
CMD_FILE="$RUN_DIR/run.cmd"
IN_FILE="$RUN_DIR/in"
OUT="$RUN_DIR/out"
ERR="$RUN_DIR/err"
CODE="$RUN_DIR/code"

if [ "$WAIT" = "1" ]; then
  if [ -t 0 ]; then : >"$IN_FILE"; else cat >"$IN_FILE" 2>/dev/null || : >"$IN_FILE"; fi
  IN="$IN_FILE"
  : >"$OUT"
  : >"$ERR"
  cmd_arg "$(winpath "$IN")"; Q_IN="$QUOTED"
  cmd_arg "$(winpath "$OUT")"; Q_OUT="$QUOTED"
  cmd_arg "$(winpath "$ERR")"; Q_ERR="$QUOTED"
  cmd_arg "$(winpath "$CODE")"; Q_CODE="$QUOTED"
  {
    cmd_preamble "$LINE$Q_IN$Q_OUT$Q_ERR$Q_CODE"
    printf '%s < %s > %s 2> %s\r\n' "$LINE" "$Q_IN" "$Q_OUT" "$Q_ERR"
    printf '> %s echo %%ERRORLEVEL%%\r\n' "$Q_CODE"
  } >"$CMD_FILE"
else
  if [ -n "$LOGFILE" ]; then
    touch "$LOGFILE" 2>/dev/null || true
    cmd_arg "$(winpath "$LOGFILE")"
    REDIR=">> $QUOTED 2>&1"
  else
    REDIR="> NUL 2>&1"
  fi
  STARTED="$RUN_DIR/started"
  cmd_arg "$(winpath "$STARTED")"; Q_STARTED="$QUOTED"
  {
    cmd_preamble "$LINE$REDIR$Q_STARTED"
    printf '> %s echo 1\r\n' "$Q_STARTED"
    printf '%s < NUL %s\r\n' "$LINE" "$REDIR"
  } >"$CMD_FILE"
fi

MODE="nowait"
[ "$WAIT" = "1" ] && MODE="wait"
VBS_W="$(winpath "$SCRIPT_DIR/windows/hidden-run.vbs")"
CMD_W="$(winpath "$CMD_FILE")"

if [ "$DRY_RUN" = "1" ]; then
  printf 'wscript //B //Nologo %s %s %s\n' "$VBS_W" "$CMD_W" "$MODE"
  cat "$CMD_FILE"
  rm -rf "$RUN_DIR"
  exit 0
fi

# Every argument is already native. Stop MSYS from rewriting //B or a path.
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
  "$WSCRIPT" //B //Nologo "$VBS_W" "$CMD_W" "$MODE"
WS_STATUS=$?

if [ "$WAIT" != "1" ]; then
  [ "$WS_STATUS" -eq 0 ] || exit "$WS_STATUS"
  START_DEADLINE=$((SECONDS + ${HQ_HIDDEN_START_TIMEOUT:-5}))
  while [ ! -f "$STARTED" ]; do
    if [ "$SECONDS" -ge "$START_DEADLINE" ]; then
      echo "hq-hidden-run: the hidden command did not start (no start marker in $RUN_DIR)" >&2
      exit 1
    fi
    sleep 0.1
  done
  exit 0
fi

STATUS=""
if [ -s "$CODE" ]; then
  STATUS="$(tr -d '[:space:]' <"$CODE" 2>/dev/null || true)"
  case "$STATUS" in ''|*[!0-9-]*) STATUS="" ;; esac
fi
if [ -z "$STATUS" ]; then
  # Nothing reported: treat as a launcher failure, not as the command's result.
  [ "$WS_STATUS" -ne 0 ] || WS_STATUS=1
  die "$WS_STATUS" "the hidden command reported no status (wscript status $WS_STATUS)"
fi
[ ! -s "$OUT" ] || cat "$OUT"
[ ! -s "$ERR" ] || cat "$ERR" >&2
rm -rf "$RUN_DIR"
exit "$STATUS"
