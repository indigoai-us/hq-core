#!/usr/bin/env bash
# The policy-trigger cache fingerprint must never read policy FILE CONTENT.
#
# HQ-HOOK-COST-001: on macOS, `stat -Lc` is rejected, and the fingerprint fell
# through to hashing every selected policy file's content on EVERY hook event.
# With ~4,000 policies that is the bulk of the per-tool-call hook cost the
# operator measured. BSD stat answers `-f` with the same sub-second mtime and
# ctime resolution, so the metadata fingerprint is available on macOS too.
#
# This test puts a BSD-dialect `stat` on PATH — it rejects GNU `-c` exactly as
# macOS does and answers `-f` — then asserts no SHA-256 process ever received a
# policy path as an argument. PATH shims record arguments; no strace, no
# platform-specific tool, and it runs the same way under bash 3.2.
set -euo pipefail
# Keep this performance regression on the legacy pre-call path; the new
# default event contract is covered by inject-policy-tool-events.test.sh.
export HQ_POLICY_TOOL_EVENTS=legacy

TEST_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
HOOK_SOURCE="${HQ_INJECT_POLICY_TEST_HOOK:-$ROOT/.claude/hooks/inject-policy-on-trigger.sh}"
[ -f "$HOOK_SOURCE" ] || { echo "FAIL: hook source is missing: $HOOK_SOURCE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "inject-policy-fingerprint-no-content-hash: skipped (jq missing)"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/inject-policy-fingerprint.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
SHIM_DIR="$TMP/bin"
mkdir -p "$TMP/.claude/hooks" "$TMP/core" "$SHIM_DIR"
cp "$HOOK_SOURCE" "$TMP/.claude/hooks/inject-policy-on-trigger.sh"
ln -s "$ROOT/core/scripts" "$TMP/core/scripts"
ln -s "$ROOT/core/policies" "$TMP/core/policies"

POLICY_COUNT=0
for policy in "$TMP/core/policies"/*.md; do
  [ -f "$policy" ] || continue
  POLICY_COUNT=$((POLICY_COUNT + 1))
done
[ "$POLICY_COUNT" -ge 100 ] || {
  echo "FAIL: expected a realistic core policy set (at least 100 files), found $POLICY_COUNT" >&2
  exit 1
}

ARG_LOG="$TMP/args.log"
: > "$ARG_LOG"

# Argument-recording shims. One line per invocation: "<tool>\t<arg>..." so the
# assertion can look for a policy path among the arguments, not just the tool.
TOOLS="awk bash cat date dirname git grep iconv jq mkdir mktemp mv openssl readlink rm rmdir sha256sum shasum sleep sort touch uname wc"
for tool in $TOOLS; do
  real_tool="$(type -P "$tool" 2>/dev/null || true)"
  [ -n "$real_tool" ] || continue
  printf '#!/bin/bash\nprintf "%%s" %q >> "$HQ_ARG_TRACE_FILE"\nprintf "\\t%%s" "$@" >> "$HQ_ARG_TRACE_FILE"\nprintf "\\n" >> "$HQ_ARG_TRACE_FILE"\nexec %q "$@"\n' \
    "$tool" "$real_tool" > "$SHIM_DIR/$tool"
  chmod +x "$SHIM_DIR/$tool"
done

# BSD-dialect stat. Rejects GNU -c/-Lc the way macOS stat does, answers -f/-Lf,
# and translates only the BSD format tokens this hook uses onto the host's real
# stat so the branch under test is measured on its own behaviour.
REAL_STAT="$(type -P stat)"
cat > "$SHIM_DIR/stat" <<SHIM
#!/bin/bash
printf '%s' stat >> "\$HQ_ARG_TRACE_FILE"
printf '\t%s' "\$@" >> "\$HQ_ARG_TRACE_FILE"
printf '\n' >> "\$HQ_ARG_TRACE_FILE"
mode=""
fmt=""
follow=0
paths=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    -L) follow=1 ;;
    -Lc) follow=1; mode=gnu; fmt="\$2"; shift ;;
    -c|--format) mode=gnu; fmt="\$2"; shift ;;
    -Lf) follow=1; mode=bsd; fmt="\$2"; shift ;;
    -f) mode=bsd; fmt="\$2"; shift ;;
    --) shift; break ;;
    -*) ;;
    *) paths+=("\$1") ;;
  esac
  shift
done
while [ \$# -gt 0 ]; do paths+=("\$1"); shift; done
if [ "\$mode" = gnu ]; then
  echo "stat: illegal option -- c" >&2
  exit 1
fi
[ "\$mode" = bsd ] || exit 1
# BSD tokens -> GNU tokens, via placeholders so %z (BSD size) is not confused
# with %z (GNU ctime).
gnu_fmt="\$fmt"
gnu_fmt="\${gnu_fmt//%N/@NAME@}"
gnu_fmt="\${gnu_fmt//%Fm/@MTIME@}"
gnu_fmt="\${gnu_fmt//%Fc/@CTIME@}"
gnu_fmt="\${gnu_fmt//%z/@SIZE@}"
gnu_fmt="\${gnu_fmt//@NAME@/%n}"
gnu_fmt="\${gnu_fmt//@MTIME@/%y}"
gnu_fmt="\${gnu_fmt//@CTIME@/%z}"
gnu_fmt="\${gnu_fmt//@SIZE@/%s}"
if [ "\$follow" = 1 ]; then
  exec "$REAL_STAT" -Lc "\$gnu_fmt" "\${paths[@]}"
fi
exec "$REAL_STAT" -c "\$gnu_fmt" "\${paths[@]}"
SHIM
chmod +x "$SHIM_DIR/stat"

PAYLOAD="$(jq -cn --arg cwd "$TMP" '{hook_event_name:"PreToolUse",session_id:"policy-fingerprint",tool_name:"Bash",cwd:$cwd,tool_input:{command:"true"}}')"
unset BASH_ENV ENV HQ_POLICY_WORKER_DIR
set +e
PATH="$SHIM_DIR" HQ_ARG_TRACE_FILE="$ARG_LOG" HOME="$TMP/home" \
  XDG_STATE_HOME="$TMP/home/.local/state" HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
  HQ_HOOK_PROFILE=standard HQ_HOOK_TIMEOUT_SENTRY=0 \
  bash "$TMP/.claude/hooks/inject-policy-on-trigger.sh" \
  <<<"$PAYLOAD" >"$TMP/hook.out" 2>"$TMP/hook.err"
HOOK_RC=$?
set -e
[ "$HOOK_RC" -eq 0 ] || {
  echo "FAIL: hook exited $HOOK_RC" >&2
  tail -200 "$TMP/hook.err" >&2
  exit 1
}

# A SHA-256 invocation that names a policy file is content hashing. Hashing a
# metadata record arrives on stdin and carries no path argument, so it is not
# matched here.
CONTENT_HASH_CALLS=0
HASHED_EXAMPLE=""
while IFS= read -r line; do
  case "$line" in
    sha256sum*|shasum*) ;;
    *) continue ;;
  esac
  case "$line" in
    *"/core/policies/"*)
      CONTENT_HASH_CALLS=$((CONTENT_HASH_CALLS + 1))
      [ -n "$HASHED_EXAMPLE" ] || HASHED_EXAMPLE="${line:0:200}"
      ;;
  esac
done < "$ARG_LOG"

# The defect first: on a BSD-stat host the fingerprint must not read policy
# file content at all. The BSD-branch guard below then proves the zero count
# came from the metadata path actually running, not from the hook skipping the
# fingerprint altogether.
BSD_STAT_CALLS=0
while IFS= read -r line; do
  case "$line" in
    stat*-Lf*|stat*$'\t'-f*) BSD_STAT_CALLS=$((BSD_STAT_CALLS + 1)) ;;
  esac
done < "$ARG_LOG"

[ "$CONTENT_HASH_CALLS" -eq 0 ] || {
  echo "FAIL: the fingerprint hashed policy file CONTENT $CONTENT_HASH_CALLS time(s) on a BSD-stat host" >&2
  echo "      over $POLICY_COUNT policies; first call: $HASHED_EXAMPLE" >&2
  exit 1
}

[ "$BSD_STAT_CALLS" -ge 1 ] || {
  echo "FAIL: the BSD stat branch never ran, so this test proves nothing about macOS" >&2
  echo "      stat invocations recorded:" >&2
  grep '^stat' "$ARG_LOG" | head -5 >&2 || true
  exit 1
}

printf 'PASS: %s policies fingerprinted on a BSD-stat host with %s metadata stat call(s) and no content hashing\n' \
  "$POLICY_COUNT" "$BSD_STAT_CALLS"
