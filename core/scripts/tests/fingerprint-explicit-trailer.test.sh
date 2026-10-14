#!/usr/bin/env bash
# hq-core: public
# fingerprint-explicit-trailer.test.sh - HQ scripts that commit outside the
# commit-msg hook pass the HQ-Fingerprint trailer themselves.
#
# Covers core/scripts/lib/fingerprint.sh with a stub hq (value, null, missing,
# hang past the timeout, malformed, setting off), the per-session cache
# (positive, negative held for the session, no session id), the hq-cli version
# floor and the HQ_FINGERPRINT_BIN bypass, the per-binary capability probe
# cache (one probe per install across sessions, re-probe on a new mtime or
# after the TTL, timing of the first and second call), end-to-end autosave
# commits through .claude/hooks/hq-autocommit.sh, and the handoff-finalize
# commit with the git-hooks dispatcher absent and present.

set -euo pipefail

# Never let a caller's git location leak into the throwaway repos below.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
LIB="$SRC_ROOT/core/scripts/lib/fingerprint.sh"

TMP_PARENT="$(mktemp -d)"
trap 'rm -rf "$TMP_PARENT"' EXIT
export HOME="$TMP_PARENT/home"
export TMPDIR="$TMP_PARENT/tmp"
export XDG_CONFIG_HOME="$HOME/.config"
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$TMPDIR"
unset HQ_FINGERPRINT_BIN HQ_FINGERPRINT_TIMEOUT_SECS HQ_FINGERPRINT_CAPABILITY_TTL_SECS CLAUDE_PROJECT_DIR HQ_ROOT HQ_ACTIVE_COMPANY
unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
not_ok() { FAIL=$((FAIL + 1)); echo "not ok - $1" >&2; }
check_eq() { # label actual expected
  if [[ "$2" == "$3" ]]; then ok "$1"; else not_ok "$1: expected '$3', got '$2'"; fi
}

FP="hqfp1:acme:-:laptop.e3ef5a5a:1234abcd"
STUBS="$TMP_PARENT/stubs"
mkdir -p "$STUBS"
make_stub() { # name body
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}
make_stub hq-value "printf '%s\n' '{\"fingerprint\":\"$FP\",\"company\":\"acme\",\"source\":\"none\"}'"
make_stub hq-null "printf '%s\n' '{\"fingerprint\":null,\"company\":null,\"source\":\"none\"}'"
make_stub hq-hang "sleep 10; printf '%s\n' '{\"fingerprint\":\"$FP\"}'"
make_stub hq-unknown "echo \"error: unknown command 'fingerprint'\" >&2; exit 1"
make_stub hq-bad "printf '%s\n' '{\"fingerprint\":\"not a fingerprint\"}'"
# Ignores TERM (and so does its sleep child), so only the KILL step stops it.
make_stub hq-stubborn "trap '' TERM; sleep 10; printf '%s\n' '{\"fingerprint\":\"$FP\"}'"
# Counting stubs: each run appends a line to $COUNT_FILE.
COUNT_FILE="$TMP_PARENT/builder-runs"
make_stub hq-count "echo run >>'$COUNT_FILE'; printf '%s\n' '{\"fingerprint\":\"$FP\"}'"
make_stub hq-count-null "echo run >>'$COUNT_FILE'; printf '%s\n' '{\"fingerprint\":null}'"
runs() { if [[ -f "$COUNT_FILE" ]]; then wc -l <"$COUNT_FILE" | tr -d ' '; else echo 0; fi; }
# Milliseconds since the epoch. bash 3.2 has no EPOCHREALTIME, so fall back to perl.
now_ms() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    local t="${EPOCHREALTIME/[.,]/}"
    echo $((10#$t / 1000))
  else
    perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'
  fi
}

# An empty HQ-shaped root for the setting lookup.
EMPTY_ROOT="$TMP_PARENT/empty-root"
mkdir -p "$EMPTY_ROOT/core/settings" "$EMPTY_ROOT/personal/settings"

# Each helper call starts from an empty session cache, so these cases test the
# builder result itself. The cache has its own section below.
helper() { # bin [root]
  rm -rf "${2:-$EMPTY_ROOT}/workspace/sessions"
  HQ_SESSION_ID="fp-helper" HQ_FINGERPRINT_BIN="$1" bash -c '. "$1"; hq_fingerprint_trailer_args "$2"' _ "$LIB" "${2:-$EMPTY_ROOT}"
}

# 1. Value present: two lines, --trailer then the trailer itself.
check_eq "value present prints --trailer and the trailer" \
  "$(helper "$STUBS/hq-value")" "$(printf '%s\n%s' --trailer "HQ-Fingerprint: $FP")"

# 2. Null fingerprint, unknown command, malformed value, hq missing: nothing.
check_eq "null fingerprint prints nothing" "$(helper "$STUBS/hq-null")" ""
check_eq "unknown command prints nothing" "$(helper "$STUBS/hq-unknown")" ""
check_eq "malformed fingerprint prints nothing" "$(helper "$STUBS/hq-bad")" ""
check_eq "hq missing prints nothing" "$(helper "$TMP_PARENT/no-such-hq")" ""
check_eq "hq missing from PATH prints nothing" \
  "$(PATH="/usr/bin:/bin" HQ_SESSION_ID="fp-no-hq" bash -c 'unset HQ_FINGERPRINT_BIN; . "$1"; hq_fingerprint_trailer_args "$2"' _ "$LIB" "$EMPTY_ROOT")" ""

# 3. hq hangs for 10 s: back within 3 s, nothing printed.
start=$(date +%s)
out="$(helper "$STUBS/hq-hang")"
elapsed=$(( $(date +%s) - start ))
check_eq "hung hq prints nothing" "$out" ""
if [[ $elapsed -le 3 ]]; then ok "hung hq returns within 3 s (${elapsed}s)"; else not_ok "hung hq took ${elapsed}s"; fi

# A builder that ignores TERM is stopped by the KILL that follows it.
start=$(date +%s)
out="$(HQ_FINGERPRINT_TIMEOUT_SECS=1 helper "$STUBS/hq-stubborn")"
elapsed=$(( $(date +%s) - start ))
check_eq "TERM-ignoring hq prints nothing" "$out" ""
if [[ $elapsed -le 3 ]]; then ok "TERM-ignoring hq is killed within 3 s (${elapsed}s)"; else not_ok "TERM-ignoring hq took ${elapsed}s"; fi

# 4. Setting off: personal wins, then core; a missing file means on.
printf 'enabled: false\n' >"$EMPTY_ROOT/core/settings/fingerprint.yaml"
check_eq "core enabled: false prints nothing" "$(helper "$STUBS/hq-value")" ""
printf 'enabled: true\n' >"$EMPTY_ROOT/personal/settings/fingerprint.yaml"
check_eq "personal enabled: true overrides core" "$(helper "$STUBS/hq-value" | tail -n 1)" "HQ-Fingerprint: $FP"
printf 'enabled: false  # off\n' >"$EMPTY_ROOT/personal/settings/fingerprint.yaml"
rm -f "$EMPTY_ROOT/core/settings/fingerprint.yaml"
check_eq "personal enabled: false prints nothing" "$(helper "$STUBS/hq-value")" ""
rm -f "$EMPTY_ROOT/personal/settings/fingerprint.yaml"

# 5. The loader keeps the value as one argv word and is set -u safe when empty.
rm -rf "$EMPTY_ROOT/workspace/sessions"
loaded="$(HQ_SESSION_ID="fp-load" HQ_FINGERPRINT_BIN="$STUBS/hq-value" bash -c 'set -euo pipefail; . "$1"; hq_fingerprint_trailer_load "$2"; printf "%s|" "${#HQ_FINGERPRINT_TRAILER_ARGS[@]}" ${HQ_FINGERPRINT_TRAILER_ARGS[@]+"${HQ_FINGERPRINT_TRAILER_ARGS[@]}"}' _ "$LIB" "$EMPTY_ROOT")"
check_eq "loader fills a two-word array" "$loaded" "2|--trailer|HQ-Fingerprint: $FP|"
loaded="$(HQ_SESSION_ID="fp-load-null" HQ_FINGERPRINT_BIN="$STUBS/hq-null" bash -c 'set -euo pipefail; . "$1"; hq_fingerprint_trailer_load "$2"; printf "%s|" "${#HQ_FINGERPRINT_TRAILER_ARGS[@]}" ${HQ_FINGERPRINT_TRAILER_ARGS[@]+"${HQ_FINGERPRINT_TRAILER_ARGS[@]}"}' _ "$LIB" "$EMPTY_ROOT")"
check_eq "loader leaves an empty array under set -u" "$loaded" "0|"

# 6. Per-session cache: the builder runs at most once per session.
cached() { # sid bin
  HQ_SESSION_ID="$1" HQ_FINGERPRINT_BIN="$2" bash -c '. "$1"; hq_fingerprint_trailer_args "$2"' _ "$LIB" "$EMPTY_ROOT"
}
rm -rf "$EMPTY_ROOT/workspace/sessions"; rm -f "$COUNT_FILE"
first="$(cached fp-cache "$STUBS/hq-count")"
second="$(cached fp-cache "$STUBS/hq-count")"
check_eq "first call in a session prints the trailer" "$first" "$(printf '%s\n%s' --trailer "HQ-Fingerprint: $FP")"
check_eq "second call in the same session prints the cached trailer" "$second" "$first"
check_eq "second call in the same session does not run the builder" "$(runs)" "1"
check_eq "cache file lives under workspace/sessions/<sid>" \
  "$(test -f "$EMPTY_ROOT/workspace/sessions/fp-cache/fingerprint-trailer.cache" && echo yes)" "yes"
cached fp-cache-other "$STUBS/hq-count" >/dev/null
check_eq "a different session runs the builder again" "$(runs)" "2"
cached fp-cache "$STUBS/hq-value" >/dev/null
check_eq "a different builder (cache key) is not served the old entry" \
  "$(sed -n 2p "$EMPTY_ROOT/workspace/sessions/fp-cache/fingerprint-trailer.cache")" "bin:$STUBS/hq-value"

# Session id precedence: CLAUDE_CODE_SESSION_ID is used when HQ_SESSION_ID is unset.
CLAUDE_CODE_SESSION_ID="fp-claude" HQ_FINGERPRINT_BIN="$STUBS/hq-count" bash -c '. "$1"; hq_fingerprint_trailer_args "$2"' _ "$LIB" "$EMPTY_ROOT" >/dev/null
check_eq "CLAUDE_CODE_SESSION_ID keys the cache" \
  "$(test -f "$EMPTY_ROOT/workspace/sessions/fp-claude/fingerprint-trailer.cache" && echo yes)" "yes"

# No session id: nothing printed and the builder never runs.
rm -f "$COUNT_FILE"
out="$(HQ_FINGERPRINT_BIN="$STUBS/hq-count" bash -c '. "$1"; hq_fingerprint_trailer_args "$2"' _ "$LIB" "$EMPTY_ROOT")"
check_eq "no session id prints nothing" "$out" ""
check_eq "no session id never runs the builder" "$(runs)" "0"
out="$(HQ_SESSION_ID="../escape" HQ_FINGERPRINT_BIN="$STUBS/hq-count" bash -c '. "$1"; hq_fingerprint_trailer_args "$2"' _ "$LIB" "$EMPTY_ROOT")"
check_eq "an invalid session id is treated as none" "$out|$(runs)" "|0"

# Negative marker: a null result is cached for the rest of the session, so a
# later `hq login` takes effect in the next session.
rm -f "$COUNT_FILE"
check_eq "null result prints nothing" "$(cached fp-neg "$STUBS/hq-count-null")" ""
check_eq "cached negative marker prints nothing" "$(cached fp-neg "$STUBS/hq-count-null")" ""
check_eq "cached negative marker does not run the builder" "$(runs)" "1"
NEG_CACHE="$EMPTY_ROOT/workspace/sessions/fp-neg/fingerprint-trailer.cache"
check_eq "negative marker has no expiry stamp" "$(sed -n 3p "$NEG_CACHE")" "none"
cached fp-neg "$STUBS/hq-count-null" >/dev/null
check_eq "negative marker still holds later in the session" "$(runs)" "1"
# A marker from the old schema, with a time-based expiry, is not trusted.
printf '%s\n' hq-fingerprint-trailer.v1 "bin:$STUBS/hq-count-null" "none:$(date +%s)" >"$NEG_CACHE"
cached fp-neg "$STUBS/hq-count-null" >/dev/null
check_eq "an old-schema marker is replaced" "$(runs)|$(sed -n 1p "$NEG_CACHE")" "2|hq-fingerprint-trailer.v2"
# A new session tries again, and a positive result there is cached.
rm -f "$COUNT_FILE"
check_eq "a new session after a negative prints the trailer" \
  "$(cached fp-neg-next "$STUBS/hq-count" | tail -n 1)" "HQ-Fingerprint: $FP"
check_eq "positive entry is then served from the cache" \
  "$(cached fp-neg-next "$STUBS/hq-count" | tail -n 1)|$(runs)" "HQ-Fingerprint: $FP|1"

# 7. hq-cli version floor: an install below the floor is skipped without
# running anything; HQ_FINGERPRINT_BIN bypasses the floor.
FAKE="$TMP_PARENT/fake-npm"
PKG="$FAKE/lib/node_modules/@indigoai-us/hq-cli"
mkdir -p "$PKG/dist" "$FAKE/bin"
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo run >>%q\n' "$COUNT_FILE"
  printf 'printf %%s %q\n' "{\"fingerprint\":\"$FP\"}"
} >"$PKG/dist/index.js"
chmod +x "$PKG/dist/index.js"
ln -s ../lib/node_modules/@indigoai-us/hq-cli/dist/index.js "$FAKE/bin/hq"
fake_version() { printf '{\n  "name": "@indigoai-us/hq-cli",\n  "version": "%s",\n  "bin": {"hq": "dist/index.js"}\n}\n' "$1" >"$PKG/package.json"; }
floor_call() { # sid [bin]
  PATH="$FAKE/bin:$PATH" HQ_SESSION_ID="$1" HQ_FINGERPRINT_BIN="${2:-}" bash -c \
    '[ -n "$HQ_FINGERPRINT_BIN" ] || unset HQ_FINGERPRINT_BIN; . "$1"; hq_fingerprint_trailer_args "$2"' _ "$LIB" "$EMPTY_ROOT"
}
FLOOR="$(bash -c '. "$1"; printf "%s" "$HQ_FINGERPRINT_MIN_HQ_CLI"' _ "$LIB")"
check_eq "floor constant is a semver" "$(printf '%s' "$FLOOR" | sed -n -E 's/^[0-9]+\.[0-9]+\.[0-9]+$/ok/p')" "ok"

rm -rf "$EMPTY_ROOT/workspace/sessions"; rm -f "$COUNT_FILE"
fake_version "5.345.93"
check_eq "hq-cli 5.345.93 (below the floor) prints nothing" "$(floor_call fp-floor-low)" ""
check_eq "hq-cli below the floor is never run" "$(runs)" "0"
check_eq "hq-cli below the floor writes no cache entry" \
  "$(test -e "$EMPTY_ROOT/workspace/sessions/fp-floor-low" && echo present || echo absent)" "absent"

fake_version "0.0.1"
check_eq "hq-cli 0.0.1 is skipped" "$(floor_call fp-floor-low2)|$(runs)" "|0"

fake_version "$FLOOR"
check_eq "hq-cli at the floor prints the trailer" "$(floor_call fp-floor-at | tail -n 1)" "HQ-Fingerprint: $FP"
check_eq "hq-cli at the floor ran once" "$(runs)" "1"
check_eq "cache key records the hq-cli version" \
  "$(sed -n 2p "$EMPTY_ROOT/workspace/sessions/fp-floor-at/fingerprint-trailer.cache")" "hq-cli:$FLOOR"

# An upgrade mid-session changes the key, so the builder runs again.
fake_version "999.0.0"
floor_call fp-floor-at >/dev/null
check_eq "an hq-cli upgrade in the same session runs the builder again" "$(runs)" "2"

# HQ_FINGERPRINT_BIN bypasses the floor, even pointing at the old install.
rm -f "$COUNT_FILE"
fake_version "5.345.93"
check_eq "HQ_FINGERPRINT_BIN bypasses the version floor" \
  "$(floor_call fp-floor-bypass "$FAKE/bin/hq" | tail -n 1)|$(runs)" "HQ-Fingerprint: $FP|1"

# 7b. Capability probe: an install at or above the floor is probed once per
# binary (path, mtime, version) and the answer is shared across sessions in
# ~/.hq/cache. The stub has the real CLI's shape when it lacks the command: a
# slow node boot, then `unknown command` on stderr and exit 1.
CAP_CACHE_DIR="$HOME/.hq/cache"
SLOW="$TMP_PARENT/slow-npm"
SPKG="$SLOW/lib/node_modules/@indigoai-us/hq-cli"
mkdir -p "$SPKG/dist" "$SLOW/bin"
printf '{\n  "name": "@indigoai-us/hq-cli",\n  "version": "6.0.0",\n  "bin": {"hq": "dist/index.js"}\n}\n' >"$SPKG/package.json"
ln -s ../lib/node_modules/@indigoai-us/hq-cli/dist/index.js "$SLOW/bin/hq"
slow_unknown() {
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo run >>%q\n' "$COUNT_FILE"
    printf 'sleep 1\n'
    printf 'echo "error: unknown command '"'"'fingerprint'"'"'" >&2\n'
    printf 'exit 1\n'
  } >"$SPKG/dist/index.js"
  chmod +x "$SPKG/dist/index.js"
  touch -t "$1" "$SPKG/dist/index.js"
}
slow_capable() {
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo run >>%q\n' "$COUNT_FILE"
    printf 'sleep 1\n'
    printf 'printf %%s %q\n' "{\"fingerprint\":\"$FP\"}"
  } >"$SPKG/dist/index.js"
  chmod +x "$SPKG/dist/index.js"
  touch -t "$1" "$SPKG/dist/index.js"
}
slow_call() { # sid
  PATH="$SLOW/bin:$PATH" HQ_SESSION_ID="$1" bash -c \
    'unset HQ_FINGERPRINT_BIN; . "$1"; hq_fingerprint_trailer_args "$2"' _ "$LIB" "$EMPTY_ROOT"
}
# Two calls in one shell, timed in ms with the library already sourced, so the
# numbers are the fingerprint cost an autosave pays. Prints out1|out2|ms1|ms2.
slow_timed() { # sid
  PATH="$SLOW/bin:$PATH" HQ_SESSION_ID="$1" bash -c '
    unset HQ_FINGERPRINT_BIN
    . "$1"; . "$3"
    t0=$(now_ms); o1="$(hq_fingerprint_trailer_args "$2")"
    t1=$(now_ms); o2="$(hq_fingerprint_trailer_args "$2")"
    t2=$(now_ms)
    printf "%s|%s|%s|%s" "$o1" "$o2" $((t1 - t0)) $((t2 - t1))' _ "$LIB" "$EMPTY_ROOT" "$TMP_PARENT/now-ms.sh"
}
declare -f now_ms >"$TMP_PARENT/now-ms.sh"
cap_files() { find "$CAP_CACHE_DIR" -name 'fingerprint-cli-*.cache' 2>/dev/null | wc -l | tr -d ' '; }

rm -rf "$EMPTY_ROOT/workspace/sessions" "$CAP_CACHE_DIR"; rm -f "$COUNT_FILE"
slow_unknown 202601010000
IFS='|' read -r t_out1 t_out2 T_FIRST_MS T_SECOND_MS <<<"$(slow_timed fp-cap-a)"
echo "# timing: first call ${T_FIRST_MS} ms, second call ${T_SECOND_MS} ms (unknown-command hq, session fp-cap-a)"
check_eq "unknown-command hq prints nothing (first call)" "$t_out1" ""
check_eq "unknown-command hq prints nothing (second call)" "$t_out2" ""
if [[ "$T_SECOND_MS" -lt 100 ]]; then ok "second call is under 100 ms (${T_SECOND_MS} ms)"; else not_ok "second call took ${T_SECOND_MS} ms"; fi
check_eq "one session boots the unknown-command hq once" "$(runs)" "1"
check_eq "the probe result is cached once per machine" "$(cap_files)" "1"
CAP_FILE="$(find "$CAP_CACHE_DIR" -name 'fingerprint-cli-*.cache' | head -n 1)"
check_eq "the cached capability is incapable" "$(sed -n 3p "$CAP_FILE")" "incapable"
case "$(sed -n 2p "$CAP_FILE")" in
  # The path is resolved, so a symlinked TMPDIR (macOS /var) shows its real path.
  */slow-npm/lib/node_modules/@indigoai-us/hq-cli/dist/index.js\|[0-9]*\|6.0.0) ok "capability key is path, mtime and version" ;;
  *) not_ok "unexpected capability key: $(sed -n 2p "$CAP_FILE")" ;;
esac
s2_start=$(now_ms)
check_eq "a second session prints nothing" "$(slow_call fp-cap-b)" ""
T_SESSION2_MS=$(( $(now_ms) - s2_start ))
echo "# timing: second session first call ${T_SESSION2_MS} ms, including bash startup"
check_eq "a second session does not boot the same hq again" "$(runs)" "1"

# The public functions: version from package.json, capability from the cache.
check_eq "hq_fp_cli_version prints the installed version" \
  "$(PATH="$SLOW/bin:$PATH" bash -c '. "$1"; hq_fp_cli_version' _ "$LIB")" "6.0.0"
check_eq "hq_fp_cli_version fails when hq is missing" \
  "$(PATH="/usr/bin:/bin" bash -c '. "$1"; hq_fp_cli_version || echo missing' _ "$LIB")" "missing"
check_eq "hq_fp_cli_capable is false from the cache, prints nothing, runs nothing" \
  "$(PATH="$SLOW/bin:$PATH" bash -c '. "$1"; hq_fp_cli_capable || echo no' _ "$LIB")|$(runs)" "no|1"

# A reinstall changes the binary mtime, so the next session probes again.
slow_unknown 202602010000
check_eq "a changed mtime prints nothing" "$(slow_call fp-cap-c)" ""
check_eq "a changed binary mtime triggers a re-probe" "$(runs)" "2"
check_eq "the new binary has its own capability entry" "$(cap_files)" "2"

# An entry older than the 24 h TTL is probed again.
# The newest entry is the one the re-probe just wrote, at least a second after
# the first because the stub sleeps for one.
CAP_FILE=""
for f in "$CAP_CACHE_DIR"/fingerprint-cli-*.cache; do
  if [ -z "$CAP_FILE" ] || [ "$f" -nt "$CAP_FILE" ]; then CAP_FILE="$f"; fi
done
sed -e "4s/.*/$(( $(date +%s) - 86401 ))/" "$CAP_FILE" >"$CAP_FILE.new" && mv "$CAP_FILE.new" "$CAP_FILE"
slow_call fp-cap-d >/dev/null
check_eq "a capability entry past the 24 h TTL is probed again" "$(runs)" "3"
slow_call fp-cap-e >/dev/null
check_eq "the refreshed entry holds for the next session" "$(runs)" "3"

# A builder that times out is cached as incapable too.
rm -f "$COUNT_FILE"
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo run >>%q\n' "$COUNT_FILE"
  printf 'sleep 10\n'
} >"$SPKG/dist/index.js"
touch -t 202603010000 "$SPKG/dist/index.js"
check_eq "a timed-out probe prints nothing" "$(HQ_FINGERPRINT_TIMEOUT_SECS=1 slow_call fp-cap-hang-a)" ""
check_eq "a timed-out probe is not repeated in the next session" \
  "$(HQ_FINGERPRINT_TIMEOUT_SECS=1 slow_call fp-cap-hang-b)|$(runs)" "|1"

# A capable install: the probe's own output is the first trailer, so the first
# session boots hq once; later sessions skip the probe and run the builder.
rm -f "$COUNT_FILE"
slow_capable 202604010000
check_eq "a capable hq prints the trailer" "$(slow_call fp-cap-ok-a | tail -n 1)" "HQ-Fingerprint: $FP"
check_eq "the capable probe doubles as the first build" "$(runs)" "1"
check_eq "hq_fp_cli_capable is true from the cache and runs nothing" \
  "$(PATH="$SLOW/bin:$PATH" bash -c '. "$1"; hq_fp_cli_capable && echo yes' _ "$LIB")|$(runs)" "yes|1"
check_eq "a capable hq prints the trailer in the next session" "$(slow_call fp-cap-ok-b | tail -n 1)" "HQ-Fingerprint: $FP"
check_eq "the next session builds once and skips the probe" "$(runs)" "2"

# hq_fp_cli_capable with no cache entry probes once and caches the answer.
rm -rf "$CAP_CACHE_DIR"; rm -f "$COUNT_FILE"
check_eq "hq_fp_cli_capable probes when nothing is cached and prints nothing" \
  "$(PATH="$SLOW/bin:$PATH" bash -c '. "$1"; hq_fp_cli_capable && echo yes' _ "$LIB")|$(runs)" "yes|1"
check_eq "hq_fp_cli_capable then answers from the cache" \
  "$(PATH="$SLOW/bin:$PATH" bash -c '. "$1"; hq_fp_cli_capable && echo yes' _ "$LIB")|$(runs)" "yes|1"

# Kill switch: nothing printed, nothing spawned, no capability cache written.
rm -rf "$EMPTY_ROOT/workspace/sessions" "$CAP_CACHE_DIR"; rm -f "$COUNT_FILE"
printf 'enabled: false\n' >"$EMPTY_ROOT/personal/settings/fingerprint.yaml"
check_eq "kill switch prints nothing" "$(slow_call fp-cap-off)" ""
check_eq "kill switch spawns nothing" "$(runs)" "0"
check_eq "kill switch writes no capability cache" "$(cap_files)" "0"
rm -f "$EMPTY_ROOT/personal/settings/fingerprint.yaml"

# 8. End-to-end autosave commit in a throwaway HQ root.
HQ="$TMP_PARENT/hq"
mkdir -p "$HQ/.claude/hooks" "$HQ/core/scripts/lib"
cp "$SRC_ROOT/.claude/hooks/hq-autocommit.sh" "$HQ/.claude/hooks/hq-autocommit.sh"
cp "$LIB" "$HQ/core/scripts/lib/fingerprint.sh"
cp "$SRC_ROOT/core/scripts/lib/hq-cli-floor.sh" "$HQ/core/scripts/lib/hq-cli-floor.sh"
printf '/workspace/sessions/\n' >"$HQ/.gitignore"
printf 'hqVersion: "test"\n' >"$HQ/core/core.yaml"
git -C "$HQ" init -q
git -C "$HQ" config user.email "fingerprint-test@example.com"
git -C "$HQ" config user.name "Fingerprint Test"
git -C "$HQ" add -A
git -C "$HQ" commit -q -m init

autosave() { # bin file sid
  local payload
  printf '%s\n' "$RANDOM" >"$HQ/$2"
  payload="$(jq -cn --arg path "$HQ/$2" '{tool_name:"Edit",tool_input:{file_path:$path},session_id:"fp-test"}')"
  printf '%s' "$payload" | (cd "$HQ" && HQ_AUTOCOMMIT_STRICT=1 HQ_SESSION_ID="$3" HQ_FINGERPRINT_BIN="$1" CLAUDE_PROJECT_DIR="$HQ" bash .claude/hooks/hq-autocommit.sh)
}

autosave "$STUBS/hq-value" notes.md fp-autosave
check_eq "autosave commit message is the autosave subject" "$(git -C "$HQ" log -1 --format=%s)" "autosave(hq): notes.md"
check_eq "autosave commit carries one HQ-Fingerprint trailer" \
  "$(git -C "$HQ" log -1 --format='%(trailers:key=HQ-Fingerprint,valueonly)' | sed '/^$/d')" "$FP"

autosave "$STUBS/hq-null" notes-null.md fp-autosave-null
check_eq "autosave with null fingerprint keeps the old message byte for byte" \
  "$(git -C "$HQ" log -1 --format=%B)" "autosave(hq): notes-null.md"

# Repeated autosaves in one session run the builder once and all carry the trailer.
rm -f "$COUNT_FILE"
autosave "$STUBS/hq-count" notes-a.md fp-autosave-repeat
autosave "$STUBS/hq-count" notes-b.md fp-autosave-repeat
autosave "$STUBS/hq-count" notes-c.md fp-autosave-repeat
check_eq "three autosaves in one session run the builder once" "$(runs)" "1"
check_eq "a cached autosave commit still carries the trailer" \
  "$(git -C "$HQ" log -1 --format='%(trailers:key=HQ-Fingerprint,valueonly)' | sed '/^$/d')" "$FP"

# Real-CLI-shape autosaves: hq on PATH (no HQ_FINGERPRINT_BIN) that boots
# slowly and lacks the command. The first autosave pays one boot, the second
# pays nothing, and an autosave in another session pays nothing either.
rm -rf "$CAP_CACHE_DIR"; rm -f "$COUNT_FILE"
slow_unknown 202605010000
a_start=$(now_ms)
PATH="$SLOW/bin:$PATH" autosave "" notes-slow-1.md fp-autosave-slow
A_FIRST_MS=$(( $(now_ms) - a_start ))
a_start=$(now_ms)
PATH="$SLOW/bin:$PATH" autosave "" notes-slow-2.md fp-autosave-slow
A_SECOND_MS=$(( $(now_ms) - a_start ))
PATH="$SLOW/bin:$PATH" autosave "" notes-slow-3.md fp-autosave-slow-next
echo "# timing: autosave hook first ${A_FIRST_MS} ms, second ${A_SECOND_MS} ms (whole hook, including git commit)"
check_eq "slow unknown-command hq boots once across two autosave sessions" "$(runs)" "1"
check_eq "autosave with an unknown-command hq keeps the old message" \
  "$(git -C "$HQ" log -1 --format=%B)" "autosave(hq): notes-slow-3.md"
if [[ "$A_SECOND_MS" -lt "$A_FIRST_MS" ]]; then ok "second autosave is faster than the first"; else not_ok "second autosave ${A_SECOND_MS} ms vs first ${A_FIRST_MS} ms"; fi

# No session id: the old message and no builder run.
rm -f "$COUNT_FILE"
autosave "$STUBS/hq-count" notes-nosid.md ""
check_eq "autosave without a session id keeps the old message" \
  "$(git -C "$HQ" log -1 --format=%B)|$(runs)" "autosave(hq): notes-nosid.md|0"

# 9. handoff-finalize commit: explicit trailer only when the dispatcher is absent.
scaffold_handoff_repo() { # dir
  local repo="$1"
  mkdir -p "$repo/core/scripts/lib" "$repo/workspace/baseline" "$repo/workspace/threads" "$repo/workspace/orchestrator"
  cp "$SRC_ROOT/core/scripts/handoff-finalize.sh" "$repo/core/scripts/handoff-finalize.sh"
  cp "$SRC_ROOT/core/scripts/hq-status-summary.sh" "$repo/core/scripts/hq-status-summary.sh"
  cp "$SRC_ROOT/core/scripts/lib/session-id.sh" "$SRC_ROOT/core/scripts/lib/forwarder.sh" \
    "$SRC_ROOT/core/scripts/lib/hq-cli-floor.sh" "$LIB" "$repo/core/scripts/lib/"
  printf '#!/usr/bin/env bash\nmkdir -p workspace/threads\necho "# Threads" > workspace/threads/INDEX.md\n' \
    >"$repo/core/scripts/rebuild-threads-index.sh"
  printf '#!/usr/bin/env bash\nmkdir -p workspace/orchestrator\necho "# Orchestrator" > workspace/orchestrator/INDEX.md\n' \
    >"$repo/core/scripts/rebuild-orchestrator-index.sh"
  chmod +x "$repo/core/scripts/"*.sh
  printf '%s\n' '{"categories":[{"name":"baseline","patterns":["companies/*","workspace/*","repos/*","core/settings/*",".hq/*"]}]}' \
    >"$repo/workspace/baseline/hq-local-baseline.json"
  git -C "$repo" init -q
  git -C "$repo" config user.email "fingerprint-test@example.com"
  git -C "$repo" config user.name "Fingerprint Test"
  echo base >"$repo/tracked.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
}

finalize() { # repo bin slug
  echo "$3" >"$1/tracked.txt"
  (cd "$1" && HQ_ROOT="$1" HQ_SESSION_ID="fp-handoff-$3" HQ_FINGERPRINT_BIN="$2" bash core/scripts/handoff-finalize.sh \
    --title "Handoff: $3" --summary "$3" --message "$3" \
    --files-touched-json '["tracked.txt"]' --slug "$3") >/dev/null
}

HO="$TMP_PARENT/handoff"
scaffold_handoff_repo "$HO"
finalize "$HO" "$STUBS/hq-value" no-dispatcher
check_eq "handoff commit without dispatcher carries the trailer" \
  "$(git -C "$HO" log -1 --format='%(trailers:key=HQ-Fingerprint,valueonly)' | sed '/^$/d')" "$FP"

finalize "$HO" "$STUBS/hq-null" null-fingerprint
check_eq "handoff commit with null fingerprint keeps the old subject" \
  "$(git -C "$HO" log -1 --format=%s)" "$(git -C "$HO" log -1 --format=%B | sed '/^$/d')"
case "$(git -C "$HO" log -1 --format=%B)" in
  "checkpoint: handoff "*) ok "handoff commit with null fingerprint is the pre-change format" ;;
  *) not_ok "unexpected handoff message: $(git -C "$HO" log -1 --format=%B)" ;;
esac

# A fake dispatcher: global core.hooksPath set, no commit-msg hook in it. The
# finalizer must not add the trailer itself, so the commit has none.
mkdir -p "$HOME/.hq/git-hooks"
git config --global core.hooksPath "$HOME/.hq/git-hooks"
finalize "$HO" "$STUBS/hq-value" with-dispatcher
check_eq "handoff commit with dispatcher present has no explicit trailer" \
  "$(git -C "$HO" log -1 --format='%(trailers:key=HQ-Fingerprint,valueonly)' | sed '/^$/d')" ""
git config --global --unset core.hooksPath

echo "fingerprint-explicit-trailer: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
