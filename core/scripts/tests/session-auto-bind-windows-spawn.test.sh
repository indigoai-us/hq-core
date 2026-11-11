#!/usr/bin/env bash
# hq-core: public
# session_auto_bind_run_with_timeout starts hq on Windows.
#
# Node spawn() without a shell cannot start the npm hq shims on Windows: the
# extensionless sh shim gives ENOENT and hq.cmd gives EINVAL. The wrapper now
# resolves the launcher and runs the JS entry it names with the same node.
# HQ_SESSION_AUTO_BIND_TEST_PLATFORM=win32 runs that resolution here against a
# fake npm layout. Without it, macOS and Linux keep the plain spawn.
#
# Hermetic: temp bin dirs holding only node (never a real hq), and a fresh temp
# HOME per case.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$ROOT/core/scripts/lib/session-auto-bind.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

FAILS=0
fail() { echo "  FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "  PASS: $*"; }

NODE_BIN="$(command -v node)" || { echo "node is required" >&2; exit 1; }
REAL_WINDOWS=0
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) REAL_WINDOWS=1 ;; esac
NODE_ONLY_DIR="$TMP/node-bin"
mkdir -p "$NODE_ONLY_DIR"
if [ "$REAL_WINDOWS" = 1 ]; then
  # A standard user's Git Bash ln -s makes a copy named "node" with no .exe,
  # which CreateProcess cannot start when the wrapper spawns process.execPath.
  cp "$NODE_BIN" "$NODE_ONLY_DIR/node.exe"
else
  ln -s "$NODE_BIN" "$NODE_ONLY_DIR/node"
fi
BASE_PATH="$NODE_ONLY_DIR:/usr/bin:/bin"
# The node the wrapper runs under is the one on the test PATH. On a standard
# Windows user Git Bash ln -s makes a copy, so ask that node, not the system one.
NODE_EXEC="$(PATH="$BASE_PATH" node -p 'process.execPath')"
# The bash that runs the wrapper (and so the one a shebang stub must use).
TEST_BASH="$BASH"
# On a real Windows host (Git Bash) the resolution is always on. Cases 4 and 7
# need a POSIX host: case 4 fakes powershell.exe with a shell script and case 7
# checks the unchanged macOS/Linux path (REAL_WINDOWS is set above).

# Stop if any hq other than the fixture's is reachable on a PATH value.
assert_only_fixture_hq() {
  local value="$1" fixture="${2:-}" rest="$1" dir
  while [ -n "$rest" ]; do
    dir="${rest%%:*}"
    if [ "$rest" = "$dir" ]; then rest=""; else rest="${rest#*:}"; fi
    [ -n "$dir" ] && [ "$dir" != "$fixture" ] || continue
    if [ -e "$dir/hq" ] || [ -e "$dir/hq.cmd" ]; then
      echo "FATAL: PATH $value reaches $dir/hq" >&2
      exit 1
    fi
  done
}

HOME_SEQ=0
fresh_home() {
  HOME_SEQ=$((HOME_SEQ + 1))
  HOME_DIR="$TMP/home-$HOME_SEQ"
  mkdir -p "$HOME_DIR"
}

# The CLI entry: logs execPath and argv as JSON lines, prints a marker on
# stdout, and exits with ENTRY_EXIT.
write_entry() {
  mkdir -p "$(dirname "$1")"
  cat >"$1" <<'JS'
const fs = require("fs");
fs.appendFileSync(process.env.TEST_LOG, JSON.stringify({ via: "entry", execPath: process.execPath, argv: process.argv.slice(2) }) + "\n");
process.stdout.write("entry-stdout\n");
process.exit(Number(process.env.ENTRY_EXIT || 0));
JS
}

# npm layout: <dir>/hq (sh shim), <dir>/hq.cmd, <dir>/node_modules/.../hq.js.
# The sh shim logs that it ran, so a direct entry start is distinguishable.
make_npm_dir() {
  local dir="$1"
  mkdir -p "$dir"
  write_entry "$dir/node_modules/@indigoai-us/hq-cli/bin/hq.js"
  cat >"$dir/hq" <<'SH'
#!/bin/sh
basedir=$(dirname "$(echo "$0" | sed -e 's,\\,/,g')")
printf '{"via":"sh-shim"}\n' >>"$TEST_LOG"
if [ -x "$basedir/node" ]; then
  exec "$basedir/node"  "$basedir/node_modules/@indigoai-us/hq-cli/bin/hq.js" "$@"
else
  exec node  "$basedir/node_modules/@indigoai-us/hq-cli/bin/hq.js" "$@"
fi
SH
  chmod +x "$dir/hq"
  cat >"$dir/hq.cmd" <<'CMD'
@ECHO off
GOTO start
:find_dp0
SET dp0=%~dp0
EXIT /b
:start
SETLOCAL
CALL :find_dp0

IF EXIST "%dp0%\node.exe" (
  SET "_prog=%dp0%\node.exe"
) ELSE (
  SET "_prog=node"
  SET PATHEXT=%PATHEXT:;.JS;=;%
)

endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\node_modules\@indigoai-us\hq-cli\bin\hq.js" %*
CMD
}

# run_wrapper <path> <log> [VAR=value ...] -- <wrapper args...>
# Sources the lib in a clean bash and runs the wrapper. Sets RC and OUT.
run_wrapper() {
  local path_value="$1" log="$2"; shift 2
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  fresh_home
  : >"$log"
  RC=0
  OUT="$(env -i HOME="$HOME_DIR" PATH="$path_value" TEST_LOG="$log" ${envs[@]+"${envs[@]}"} \
    "$TEST_BASH" -c '. "$1"; shift; session_auto_bind_run_with_timeout "$@"' _ "$LIB" "$@" 2>"$TMP/stderr")" || RC=$?
}

# Args with spaces and shell metacharacters must arrive unchanged.
ARGS=(mesh context reconcile --observation-file "C:\\a b\\obs;&|x.json" --machine '%PATH%' '$(id)' '')
EXPECT_ARGV="$(node -e 'console.log(JSON.stringify(process.argv.slice(1)))' -- "${ARGS[@]}")"

entry_argv() { node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
const e = lines.find((l) => l.via === process.argv[2]);
console.log(e ? JSON.stringify(e.argv) : "none");' "$1" "${2:-entry}"; }
entry_exec() { node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
const e = lines.find((l) => l.via === "entry");
console.log(e ? e.execPath : "none");' "$1"; }
log_has() { grep -q "\"via\":\"$2\"" "$1"; }

echo "== 1. Windows: bare hq with npm hq + hq.cmd runs the JS entry with the same node =="
NPM="$TMP/npm"
make_npm_dir "$NPM"
P="$NPM:$BASE_PATH"; assert_only_fixture_hq "$P" "$NPM"
LOG="$TMP/log1"
run_wrapper "$P" "$LOG" HQ_SESSION_AUTO_BIND_TEST_PLATFORM=win32 -- hq "${ARGS[@]}"
[ "$RC" = 0 ] && pass "exit 0" || fail "exit $RC, stderr: $(cat "$TMP/stderr")"
log_has "$LOG" sh-shim && fail "the sh shim ran; the wrapper must run the entry itself" || pass "the sh shim did not run"
[ "$(entry_exec "$LOG")" = "$NODE_EXEC" ] && pass "entry ran under the same node" || fail "entry execPath: $(entry_exec "$LOG")"
[ "$(entry_argv "$LOG")" = "$EXPECT_ARGV" ] && pass "argv passed through unchanged" || fail "argv: $(entry_argv "$LOG") want $EXPECT_ARGV"
[ "$OUT" = "entry-stdout" ] && pass "stdout passed through" || fail "stdout: $OUT"

echo "== 2. Windows: an absolute hq path (the hook's HQ_BIN) resolves the same way =="
LOG="$TMP/log2"
run_wrapper "$P" "$LOG" HQ_SESSION_AUTO_BIND_TEST_PLATFORM=win32 ENTRY_EXIT=7 -- --timeout-ms 5000 "$NPM/hq" "${ARGS[@]}"
[ "$RC" = 7 ] && pass "entry exit code 7 passed through" || fail "exit $RC"
log_has "$LOG" sh-shim && fail "the sh shim ran" || pass "the sh shim did not run"
[ "$(entry_argv "$LOG")" = "$EXPECT_ARGV" ] && pass "argv passed through" || fail "argv: $(entry_argv "$LOG")"

echo "== 3. Windows: pnpm-style hq.cmd only, entry outside the bin dir =="
PN="$TMP/pnpm/bin"
mkdir -p "$PN"
write_entry "$TMP/pnpm/global/node_modules/@indigoai-us/hq-cli/bin/hq.js"
printf '@IF EXIST "%%~dp0\\node.exe" (\r\n  "%%~dp0\\node.exe"  "%%~dp0\\..\\global\\node_modules\\@indigoai-us\\hq-cli\\bin\\hq.js" %%*\r\n) ELSE (\r\n  node  "%%~dp0\\..\\global\\node_modules\\@indigoai-us\\hq-cli\\bin\\hq.js" %%*\r\n)\r\n' >"$PN/hq.cmd"
P="$PN:$BASE_PATH"; assert_only_fixture_hq "$P" "$PN"
LOG="$TMP/log3"
run_wrapper "$P" "$LOG" HQ_SESSION_AUTO_BIND_TEST_PLATFORM=win32 -- hq "${ARGS[@]}"
[ "$RC" = 0 ] && pass "exit 0" || fail "exit $RC, stderr: $(cat "$TMP/stderr")"
[ "$(entry_argv "$LOG")" = "$EXPECT_ARGV" ] && pass "pnpm entry ran with argv intact" || fail "argv: $(entry_argv "$LOG")"

echo "== 4. Windows: a .cmd that names no entry goes through the PowerShell adapter =="
SR="$TMP/sysroot"
if [ "$REAL_WINDOWS" = 1 ]; then
  echo "  NOT RUN on a Windows host: the fake powershell.exe is a shell script"
else
OD="$TMP/opaque"
mkdir -p "$OD"
printf '@ECHO off\r\nsomething-else.exe %%*\r\n' >"$OD/hq.cmd"
PS="$SR/System32/WindowsPowerShell/v1.0/powershell.exe"
mkdir -p "$(dirname "$PS")"
cat >"$PS" <<'PS1'
#!/usr/bin/env bash
node -e 'require("fs").appendFileSync(process.env.TEST_LOG, JSON.stringify({ via: "powershell", argv: process.argv.slice(1) }) + "\n")' -- "$@"
PS1
chmod +x "$PS"
P="$OD:$BASE_PATH"; assert_only_fixture_hq "$P" "$OD"
LOG="$TMP/log4"
run_wrapper "$P" "$LOG" HQ_SESSION_AUTO_BIND_TEST_PLATFORM=win32 SystemRoot="$SR" -- hq "${ARGS[@]}"
[ "$RC" = 0 ] && pass "exit 0" || fail "exit $RC, stderr: $(cat "$TMP/stderr")"
PS_CHECK="$(node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
const e = lines.find((l) => l.via === "powershell");
if (!e) { console.log("none"); process.exit(0); }
const i = e.argv.indexOf("-File");
const shim = e.argv[i + 1];
const decoded = e.argv.slice(i + 2).map((v) => Buffer.from(v, "base64").toString("utf8"));
console.log(JSON.stringify({ shim: require("path").basename(shim), cmd: decoded[0], args: decoded.slice(1) }));' "$LOG")"
WANT_PS="$(node -e 'console.log(JSON.stringify({ shim: "windows-command-shim.ps1", cmd: process.argv[1], args: process.argv.slice(2) }))' "$OD/hq.cmd" "${ARGS[@]}")"
[ "$PS_CHECK" = "$WANT_PS" ] && pass "adapter got the shim, the .cmd and base64 argv" || fail "adapter: $PS_CHECK want $WANT_PS"
fi

echo "== 5. Windows: a shebang stub (Git Bash test stub) runs through the running bash =="
SD="$TMP/stub"
mkdir -p "$SD"
cat >"$SD/hq" <<'STUB'
#!/bin/sh
node -e 'require("fs").appendFileSync(process.env.TEST_LOG, JSON.stringify({ via: "stub", argv: process.argv.slice(1) }) + "\n")' -- "$@"
STUB
chmod +x "$SD/hq"
# A decoy bash first on PATH stands in for WSL bash.exe in System32. The
# wrapper must use the bash that runs it, not a PATH lookup.
cat >"$SD/bash" <<'DECOY'
#!/bin/sh
printf '{"via":"decoy-bash"}\n' >>"$TEST_LOG"
exit 0
DECOY
chmod +x "$SD/bash"
P="$SD:$BASE_PATH"; assert_only_fixture_hq "$P" "$SD"
LOG="$TMP/log5"
run_wrapper "$P" "$LOG" HQ_SESSION_AUTO_BIND_TEST_PLATFORM=win32 -- hq "${ARGS[@]}"
[ "$RC" = 0 ] && pass "exit 0" || fail "exit $RC"
[ "$(entry_argv "$LOG" stub)" = "$EXPECT_ARGV" ] && pass "stub ran with argv intact" || fail "argv: $(entry_argv "$LOG" stub)"
log_has "$LOG" decoy-bash && fail "the stub ran through the bash found on PATH" || pass "the stub ran through the running bash, not PATH's"

echo "== 6. Windows: timeout still ends the run with 124 =="
SL="$TMP/slow"
mkdir -p "$SL/node_modules/x/bin"
printf 'setTimeout(() => {}, 5000);\n' >"$SL/node_modules/x/bin/hq.js"
printf '"%%dp0%%\\node_modules\\x\\bin\\hq.js" %%*\r\n' >"$SL/hq.cmd"
P="$SL:$BASE_PATH"; assert_only_fixture_hq "$P" "$SL"
START=$SECONDS
run_wrapper "$P" "$TMP/log6" HQ_SESSION_AUTO_BIND_TEST_PLATFORM=win32 -- --timeout-ms 300 hq
[ "$RC" = 124 ] && pass "exit 124" || fail "exit $RC"
[ $((SECONDS - START)) -lt 4 ] && pass "returned before the child finished" || fail "took $((SECONDS - START)) s"

echo "== 7. macOS/Linux (no override): the existing plain spawn runs the sh shim =="
if [ "$REAL_WINDOWS" = 1 ]; then
  echo "  NOT RUN on a Windows host: this case checks the macOS/Linux path"
else
P="$NPM:$BASE_PATH"
LOG="$TMP/log7"
run_wrapper "$P" "$LOG" -- hq "${ARGS[@]}"
[ "$RC" = 0 ] && pass "exit 0" || fail "exit $RC"
log_has "$LOG" sh-shim && pass "the sh shim ran (plain spawn, unchanged)" || fail "the sh shim did not run"
[ "$(entry_argv "$LOG")" = "$EXPECT_ARGV" ] && pass "argv passed through" || fail "argv: $(entry_argv "$LOG")"
LOG="$TMP/log7b"
run_wrapper "$TMP/opaque:$BASE_PATH" "$LOG" SystemRoot="$SR" -- hq
[ "$RC" = 127 ] && pass "no hq on PATH (only hq.cmd) still gives 127" || fail "exit $RC"
log_has "$LOG" powershell && fail "PowerShell adapter used off Windows" || pass "no PowerShell adapter off Windows"
fi

if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS check(s) in session-auto-bind-windows-spawn" >&2
  exit 1
fi
echo "ALL PASS: session-auto-bind-windows-spawn"
