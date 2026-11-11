#!/usr/bin/env bash
# hq-core: public
# Regression: the SessionStart Work Mesh preflight walks up from the session's
# cwd looking for a .git entry. Claude Code on Windows can hand it a drive path
# (C:\work\x\root). "${dir%/*}" never reaches "" or "/" for those values, so
# the walk spun at full CPU until the parent hook runner's child timeout ended
# SessionStart with rc 124.
#
# Runs the production hook under the shell running this test ("$BASH", so
# /bin/bash 3.2 on macOS really exercises 3.2) with a stubbed hq CLI, each run under a watchdog,
# and reads the walk's steps from xtrace so a found .git is proven too.
#
# bash-3.2 compatible; hermetic (temp HQ_ROOT, HOME and TMPDIR; no network).

set -uo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC_HOOK="$SOURCE_ROOT/core/hooks/SessionStart/35-work-mesh-session-start.sh"
[ -f "$SRC_HOOK" ] || { echo "FATAL: missing $SRC_HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required: the walk only runs when jq is present" >&2; exit 1; }

# A fixed run takes well under a second. A short bound keeps a regressed run
# (which spins under xtrace) from filling the runner's disk.
BOUND_SECONDS=10
FAILURES=0
TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FATAL: mktemp gave no folder" >&2; exit 1; }
TMP="$(cd "$TMP" && pwd -P)" || { echo "FATAL: cannot enter the temp folder" >&2; exit 1; }
[ -n "$TMP" ] && [ "$TMP" != / ] || { echo "FATAL: unusable temp folder" >&2; exit 1; }
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

FIX="$TMP/hq"
mkdir -p "$FIX/core/hooks/SessionStart" "$FIX/core/scripts" "$TMP/home/.hq" "$TMP/tmp" "$TMP/bin"
cp -R "$SOURCE_ROOT/core/scripts/lib" "$FIX/core/scripts/lib"
cp "$SRC_HOOK" "$FIX/core/hooks/SessionStart/"
if [ -f "$SOURCE_ROOT/core/hooks/SessionStart/preflight-fixtures.json" ]; then
  cp "$SOURCE_ROOT/core/hooks/SessionStart/preflight-fixtures.json" "$FIX/core/hooks/SessionStart/"
fi

# An hq CLI that answers nothing leaves the session unbound, which is the state
# the walk runs in.
cat >"$TMP/bin/hq" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/bin/hq"

# Relative Windows-shaped paths resolve inside this folder on Linux and macOS.
# Git Bash on Windows cannot run this test: ":" is not allowed in a folder name.
RUN_DIR="$TMP/run"
mkdir -p "$RUN_DIR/C:/work/x/.git"
: >"$RUN_DIR/C:/work/x/.git/config"

SEQ=0
LAST_RC=0
LAST_TRACE=""

# run_hook <cwd value exactly as it appears inside the JSON string>
run_hook() {
  local json_cwd="$1" sid pid watchdog
  SEQ=$((SEQ + 1))
  sid="wm-preflight-path-$SEQ"
  LAST_TRACE="$TMP/trace-$SEQ.txt"
  printf '{"session_id":"%s","cwd":"%s"}' "$sid" "$json_cwd" >"$TMP/payload-$SEQ.json"
  (
    cd "$RUN_DIR" || exit 99
    env -u HQ_WORK_MESH_DISABLED -u HQ_DISABLED_HOOKS -u HQ_WORK_MESH_RECONCILE_STUB -u HQ_COMPANY \
      -u HQ_SPAWN_COMPANY -u HQ_ACTIVE_COMPANY -u HQ_WORK_CONTEXT_ROOT \
      HQ_ROOT="$FIX" HOME="$TMP/home" TMPDIR="$TMP/tmp" PATH="$TMP/bin:$PATH" \
      HQ_SESSION_ID="$sid" CLAUDE_CODE_SESSION_ID="$sid" WORK_MESH_SEQ_DIR="$TMP/mesh-seq" \
      "$BASH" -x "$FIX/core/hooks/SessionStart/35-work-mesh-session-start.sh" SessionStart \
      <"$TMP/payload-$SEQ.json" >/dev/null 2>"$LAST_TRACE"
  ) &
  pid=$!
  # Polls in one-second sleeps so no long sleeper outlives a finished run. The hook
  # is stopped before the wrapper, because stopping the wrapper releases the wait
  # below. Only this user's processes running this temp copy of the hook match.
  (
    waited=0
    while [ "$waited" -lt "$BOUND_SECONDS" ]; do
      sleep 1
      kill -0 "$pid" 2>/dev/null || exit 0
      waited=$((waited + 1))
    done
    pkill -9 -u "$(id -u)" -f "$FIX/core/hooks/SessionStart/35-work-mesh-session-start.sh" 2>/dev/null
    kill -9 "$pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  watchdog=$!
  wait "$pid" 2>/dev/null
  LAST_RC=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  return 0
}

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

expect_stops() {
  if [ "$LAST_RC" -eq 0 ]; then pass "$1: hook stops, rc 0"; else fail "$1: expected rc 0 within ${BOUND_SECONDS}s, got rc $LAST_RC"; fi
}

expect_walk_ran() {
  if grep -q 'git_entry=' "$LAST_TRACE"; then pass "$1: the walk ran"; else fail "$1: the walk never ran, so this case proves nothing"; fi
}

expect_visits() {
  if grep -qF "git_entry=$2" "$LAST_TRACE" || grep -qF "git_entry='$2" "$LAST_TRACE"; then
    pass "$1: visits $2"
  else
    fail "$1: expected a visit to $2; visited: $(grep -F 'git_entry=' "$LAST_TRACE" | head -8 | tr '\n' ' ')"
  fi
}

expect_stops_at() {
  # The walk stops at the first folder that holds .git, so its last visit names it.
  local last
  last="$(grep -F 'git_entry=' "$LAST_TRACE" | tail -n 1)"
  case "$last" in
    *"$2"*) pass "$1: stops at $2" ;;
    *) fail "$1: expected the last visit to be $2, got: $last" ;;
  esac
}

# Drive paths with no .git anywhere above them.
run_hook 'D:\\work\\x\\root'
expect_stops "JSON-escaped backslash drive path"
expect_walk_ran "JSON-escaped backslash drive path"
expect_visits "JSON-escaped backslash drive path" "D:/.git"

run_hook 'D:\work\x\root'
expect_stops "single backslash drive path"
expect_walk_ran "single backslash drive path"
expect_visits "single backslash drive path" "D:/.git"

run_hook 'D:/work/x/root'
expect_stops "forward slash drive path"
expect_walk_ran "forward slash drive path"
expect_visits "forward slash drive path" "D:/.git"

run_hook 'D:\\'
expect_stops "bare drive root"
expect_walk_ran "bare drive root"

run_hook '\\\\server\\share\\root'
expect_stops "UNC path"
expect_walk_ran "UNC path"
expect_visits "UNC path" "//server/share/.git"

run_hook '\\server\share\root'
expect_stops "single backslash UNC path"
expect_walk_ran "single backslash UNC path"
expect_visits "single backslash UNC path" "//server/share/.git"

run_hook 'no-slash-at-all'
expect_stops "value with no separator"
expect_walk_ran "value with no separator"

# A .git in a parent folder is still found from a backslash path.
run_hook 'C:\\work\\x\\root\\sub'
expect_stops "backslash path under a repository"
expect_stops_at "backslash path under a repository" "C:/work/x/.git"

run_hook 'C:/work/x/root/sub'
expect_stops "forward slash path under a repository"
expect_stops_at "forward slash path under a repository" "C:/work/x/.git"

# POSIX behaviour is unchanged.
mkdir -p "$TMP/repo/.git" "$TMP/repo/a/b"
: >"$TMP/repo/.git/config"
run_hook "$TMP/repo/a/b"
expect_stops "POSIX path under a repository"
expect_stops_at "POSIX path under a repository" "$TMP/repo/.git"

run_hook "$TMP/nothing-here/a"
expect_stops "POSIX path outside any repository"
expect_walk_ran "POSIX path outside any repository"

# One leading backslash is a legal POSIX relative folder name, not a UNC path.
mkdir -p "$RUN_DIR/\\repo/.git" "$RUN_DIR/\\repo/sub"
: >"$RUN_DIR/\\repo/.git/config"
run_hook '\repo/sub'
expect_stops "POSIX relative value opening with one backslash"
expect_stops_at "POSIX relative value opening with one backslash" '\repo/.git'

# Short values that reduce to separators alone still stop.
run_hook '\\\\'
expect_stops "two backslashes alone"
expect_walk_ran "two backslashes alone"

run_hook '//'
expect_stops "two forward slashes alone"

run_hook 'C:'
expect_stops "drive with no separator"
expect_walk_ran "drive with no separator"

# A backslash is a legal character in a POSIX folder name: leave it alone.
run_hook "$TMP/odd\\\\name/a"
expect_stops "POSIX path holding a backslash"
expect_walk_ran "POSIX path holding a backslash"
if grep -F 'git_entry=' "$LAST_TRACE" | grep -qF 'odd\\name/a/.git'; then
  pass "POSIX path holding a backslash: the name is not rewritten"
else
  fail "POSIX path holding a backslash: the name was rewritten: $(grep -F 'git_entry=' "$LAST_TRACE" | head -3 | tr '\n' ' ')"
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "work-mesh-preflight-windows-path: $FAILURES failure(s)" >&2
  exit 1
fi
echo "work-mesh-preflight-windows-path: all checks passed"
