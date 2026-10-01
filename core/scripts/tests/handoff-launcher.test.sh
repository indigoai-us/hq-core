#!/usr/bin/env bash
set -euo pipefail

ROOT="${HQ_TEST_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
DETACH="$ROOT/core/scripts/hq-detach.sh"
SKILL="$ROOT/.claude/skills/handoff/SKILL.md"
POST="$ROOT/core/scripts/handoff-post.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/uname" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$HQ_TEST_UNAME"
STUB
cat > "$TMP/bin/node" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "-e" ] || exit 71
script="$2"
shift 2
[ "${1:-}" = "--" ] || exit 72
shift
printf '%s' "$script" > "$HQ_TEST_NODE_SCRIPT"
printf '%s\n' "$@" > "$HQ_TEST_NODE_ARGS"
printf '%s\n' "${HQ_DETACH_LOGFILE:-}" > "$HQ_TEST_NODE_ARGS.logfile"
printf '54321\n'
STUB
cat > "$TMP/bin/nohup" <<'STUB'
#!/usr/bin/env bash
# Delay the detached side effect so the parent must wait for its observable file.
sleep 1
printf '%s\n' "$@" > "$HQ_TEST_NOHUP_ARGS"
if IFS= read -r unexpected; then
  printf 'stdin was not detached: %s\n' "$unexpected" >&2
  exit 73
fi
STUB
cat > "$TMP/bin/cygpath" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "-m" ] || exit 74
printf 'C:/msys64%s\n' "$2"
STUB
chmod +x "$TMP/bin/uname" "$TMP/bin/node" "$TMP/bin/nohup" "$TMP/bin/cygpath"

if printf 'should not reach detached child\n' | env \
  PATH="$TMP/bin:$PATH" \
  HQ_TEST_UNAME='MINGW64_NT-10.0' \
  HQ_TEST_NODE_SCRIPT="$TMP/node-script" \
  HQ_TEST_NODE_ARGS="$TMP/node-args" \
  bash "$DETACH" --handoff --pidfile "$TMP/windows.pid" --logfile "$TMP/windows.log" -- printf windows-arg; then
  :
else
  fail "MINGW did not launch the hidden detached child"
fi

[ "$(cat "$TMP/windows.pid")" = "54321" ] || fail "Windows hidden launcher did not report child pid"
grep -q 'windowsHide:' "$TMP/node-script" && grep -q 'HQ_DETACH_WINDOWS_SHELL' "$TMP/node-script" || fail "Windows launcher did not request a hidden window"
grep -q 'stdio:.*ignore' "$TMP/node-script" || fail "Windows launcher did not detach child stdin"
grep -qx 'printf' "$TMP/node-args" || fail "Windows launcher lost the command argument"
grep -qx 'windows-arg' "$TMP/node-args" || fail "Windows launcher lost the command payload"
[ ! -e "$TMP/nohup-args" ] || fail "Windows used nohup instead of the hidden launcher"
pass "MINGW selects hidden launcher with detached stdin and preserved argv"
[ "$(cat "$TMP/node-args.logfile")" = "C:/msys64$TMP/windows.log" ] || fail "Windows launcher passed an MSYS log path to native Node: $(cat "$TMP/node-args.logfile")"
pass "MINGW converts the log path to native form for Node"

rm -f "$TMP/node-script" "$TMP/node-args"
for platform in Linux Darwin; do
  rm -f "$TMP/nohup-args" "$TMP/$platform.pid"
  printf 'should not reach detached child\n' | env \
    PATH="$TMP/bin:$PATH" \
    HQ_TEST_UNAME="$platform" \
    HQ_TEST_NOHUP_ARGS="$TMP/nohup-args" \
    bash "$DETACH" --handoff --pidfile "$TMP/$platform.pid" --logfile "$TMP/$platform.log" -- printf "$platform-arg"
  [ -s "$TMP/$platform.pid" ] || fail "$platform nohup launcher did not report child pid"
  waited=0
  while [ ! -s "$TMP/nohup-args" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$TMP/nohup-args" ] || fail "timed out waiting for $platform nohup arguments"
  grep -qx 'printf' "$TMP/nohup-args" || fail "$platform nohup lost the command argument"
  grep -qx "$platform-arg" "$TMP/nohup-args" || fail "$platform nohup lost the command payload"
done
[ ! -e "$TMP/node-script" ] || fail "Linux/Darwin used the Windows hidden launcher"
pass "Linux and Darwin retain nohup with stdin detached and argv preserved"

for source in "$SKILL" "$POST"; do
  grep -q -- '--handoff' "$source" || fail "$source does not use the platform-aware handoff launcher"
done
pass "handoff skill and post script use the shared platform-aware launcher"

echo "handoff launcher: all passed"
