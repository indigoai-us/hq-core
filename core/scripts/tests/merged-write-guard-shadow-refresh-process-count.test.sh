#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
HOOK="$ROOT/.claude/hooks/merged-write-guard-shadow-refresh.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/merged-write-refresh-count.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"
fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$BIN/dirname" <<'SH'
#!/usr/bin/env bash
printf 'dirname\n' >> "$HQ_TEST_PROCESS_LOG"
exec /usr/bin/dirname "$@"
SH
cat > "$BIN/node" <<'SH'
#!/usr/bin/env bash
printf 'node %s\n' "$*" >> "$HQ_TEST_PROCESS_LOG"
cat > "$HQ_TEST_INPUT"
SH
chmod +x "$BIN/dirname" "$BIN/node"

export HQ_TEST_PROCESS_LOG="$TMP/processes.log" HQ_TEST_INPUT="$TMP/node-input.json"
export PATH="$BIN:/usr/bin:/bin"
payload='{"session_id":"hp31-process-count","value":"same payload"}'
if ! printf '%s\n' "$payload" | bash "$HOOK" > "$TMP/stdout" 2> "$TMP/stderr"; then
  fail 'refresh hook changed its exit status'
fi
[ ! -s "$TMP/stdout" ] || fail 'refresh hook wrote stdout'
[ "$(cat "$TMP/stderr")" = "" ] || fail 'refresh hook wrote unexpected stderr'
[ "$(wc -l < "$HQ_TEST_PROCESS_LOG" | tr -d ' ')" = 1 ] || fail 'refresh hook must invoke one external command'
[ "$(cat "$HQ_TEST_PROCESS_LOG")" = "node $ROOT/.claude/hooks/merged-write-guard-shadow.cjs --refresh" ] || fail 'refresh hook launched an unexpected command'
[ "$(cat "$TMP/node-input.json")" = "$payload" ] || fail 'refresh hook changed the input payload'

# The PATH shims only see external commands. A pipeline such as
# `printf ... | node` forks a helper shell for the printf builtin, which no
# shim can observe. Trace the hook with the PID of the shell that runs each
# command: only the HOOK_ROOT command substitution (cd + pwd -P) may run outside
# the hook's own shell. macOS bash 3.2 has no BASHPID, so PS4 asks a child sh
# for its parent PID instead.
cat > "$TMP/trace-driver.sh" <<'SH'
exec 2>"$1"
PS4='+$(exec sh -c "echo \$PPID")|'
set -x
. "$2"
SH
printf '%s\n' "$payload" | bash "$TMP/trace-driver.sh" "$TMP/trace.log" "$HOOK" > /dev/null || :
sed -n 's/^+*\([0-9][0-9]*\)|\(.*\)$/\1 \2/p' "$TMP/trace.log" > "$TMP/trace.pids"
[ -s "$TMP/trace.pids" ] || fail 'trace driver recorded no commands'
hook_pid="$(head -n 1 "$TMP/trace.pids" | cut -d' ' -f1)"
grep -q "^$hook_pid node .*merged-write-guard-shadow.cjs --refresh\$" "$TMP/trace.pids" \
  || fail 'refresh hook must start node from its own shell, not a pipeline subshell'
forked="$(awk -v pid="$hook_pid" '$1 != pid' "$TMP/trace.pids")"
unexpected="$(printf '%s\n' "$forked" | awk 'NF && $2 != "cd" && !($2 == "pwd" && $3 == "-P")')"
[ -z "$unexpected" ] || fail "refresh hook ran commands in a forked shell: $unexpected"
[ "$(printf '%s\n' "$forked" | awk 'NF { print $1 }' | sort -u | wc -l | tr -d ' ')" -le 1 ] \
  || fail 'refresh hook forked more than the HOOK_ROOT command substitution'

# Source-shape backup in case a future shell traces differently.
code="$(grep -v '^[[:space:]]*#' "$HOOK")"
if printf '%s\n' "$code" | grep >/dev/null -E '\|[[:space:]]*node([[:space:]]|$)'; then
  fail 'refresh hook pipes into node'
fi
if printf '%s\n' "$code" | grep >/dev/null -E '(^|[^[:alnum:]_])dirname([[:space:]]|$)'; then
  fail 'refresh hook calls external dirname'
fi
echo 'ALL PASS: merged-write-guard-shadow-refresh-process-count'
