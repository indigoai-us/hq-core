#!/usr/bin/env bash
# On a Windows npm global install, `hq` on PATH is a shell shim script, not a
# symlink. The policy injector must still resolve the packaged
# derive-trigger-facts.sh companion from that layout and run it directly, so a
# PostToolUse event starts no `node` process (windows-hook-parity US-001).
#
# Windows npm layout (cmd-shim), mirrored here with plain files:
#   <prefix>/hq                                  sh shim: exec node <prefix>/node_modules/@indigoai-us/hq-cli/dist/index.js
#   <prefix>/hq.cmd, <prefix>/hq.ps1             cmd and PowerShell shims
#   <prefix>/node_modules/@indigoai-us/hq-cli/   the package
#
# Before the fix the resolver only followed symlinks. A shim is a regular file,
# so the resolver found nothing, fell through to the forwarder, and the
# forwarder ran `hq core derive-trigger-facts`, which execs node through the
# shim: about 2 s per call on Windows Git Bash.
#
# The fixture puts a `node` on PATH that records every invocation, so "no node
# process started" is observed directly. The CLI version floor must still hold
# on the shim path, and a lookalike `hq` script that is not an npm shim for
# this package must keep the forwarder path.
set -euo pipefail
# This suite exercises the pre-call fact path behind the rollback switch, the
# same path inject-policy-fact-helper-no-cli-boot.test.sh covers for symlinks,
# and then the default PostToolUse path.
TEST_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
HOOK_SOURCE="${HQ_INJECT_POLICY_TEST_HOOK:-$ROOT/.claude/hooks/inject-policy-on-trigger.sh}"
[ -f "$HOOK_SOURCE" ] || { echo "FAIL: hook source is missing: $HOOK_SOURCE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required for inject-policy-fact-helper-windows-shim" >&2; exit 1; }

REAL_BASH="$(command -v bash)"
# cd + pwd normalises a TMPDIR with a trailing slash, so the paths the hook
# logs match the fixture paths this test greps for.
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/inject-policy-windows-shim.XXXXXX")" && pwd)"
trap 'rm -rf "$WORK"' EXIT

TMP=""
PREFIX=""
PKG=""
NODE_LOG=""
COMPANION_LOG=""
BASH_LOG=""

# build_fixture <label> <package-version> <shim-kind>
#   shim-kind: npm   — the cmd-shim sh script for @indigoai-us/hq-cli
#              npm-crlf — the same shim with CRLF line endings
#              other — a regular `hq` script beside the package that is not
#                      an npm shim for it
build_fixture() {
  local label="$1" version="$2" kind="$3"
  TMP="$WORK/$label"
  PREFIX="$TMP/npm-prefix"
  PKG="$PREFIX/node_modules/@indigoai-us/hq-cli"
  mkdir -p "$TMP/.claude/hooks" "$TMP/core" "$TMP/bin" "$TMP/home" \
    "$PKG/dist" "$PKG/assets/scaffold/core/scripts/lib"
  cp "$HOOK_SOURCE" "$TMP/.claude/hooks/inject-policy-on-trigger.sh"
  ln -s "$ROOT/core/scripts" "$TMP/core/scripts"
  ln -s "$ROOT/core/policies" "$TMP/core/policies"

  NODE_LOG="$TMP/node-invocations.log"
  COMPANION_LOG="$TMP/companion-invocations.log"
  BASH_LOG="$TMP/bash-invocations.log"
  : > "$NODE_LOG"
  : > "$COMPANION_LOG"
  : > "$BASH_LOG"

  # `node` records each start and answers like the CLI would for the two
  # commands the forwarder path issues: the floor check and the fact helper.
  cat > "$TMP/bin/node" <<NODE
#!/bin/bash
printf '%s\n' "\$*" >> "$NODE_LOG"
case " \$* " in
  *" --version "*) printf '%s\n' "$version" ;;
  *) printf '%s\n' "always" ;;
esac
NODE
  chmod +x "$TMP/bin/node"

  cat > "$TMP/bin/bash" <<SHIM
#!/bin/bash
printf '%s\n' "\$*" >> "$BASH_LOG"
exec "$REAL_BASH" "\$@"
SHIM
  chmod +x "$TMP/bin/bash"

  printf '%s\n' '// entry point; never run in this test without node' > "$PKG/dist/index.js"
  printf '{\n  "name": "@indigoai-us/hq-cli",\n  "version": "%s",\n  "bin": {\n    "hq": "dist/index.js"\n  }\n}\n' \
    "$version" > "$PKG/package.json"

  cat > "$PKG/assets/scaffold/core/scripts/derive-trigger-facts.sh" <<COMPANION
#!/bin/bash
printf '%s\n' "\$* hq_root=\${HQ_ROOT:-unset}" >> "$COMPANION_LOG"
if [ "\${2:-}" = "--with-assistant-intent" ]; then
  printf '%s\n%s\n' "always company" "always company"
else
  printf '%s\n' "always company"
fi
COMPANION
  chmod +x "$PKG/assets/scaffold/core/scripts/derive-trigger-facts.sh"
  printf '%s\n' '{ print }' > "$PKG/assets/scaffold/core/scripts/lib/trigger-fact-text.awk"
  printf '%s\n' '# stub' > "$PKG/assets/scaffold/core/scripts/lib/transcript-tail.sh"

  case "$kind" in
    npm|npm-crlf)
      # The shape cmd-shim writes for a global npm bin on Windows (cmd-shim
      # also leaves a trailing space after `else`, which does not affect the
      # match).
      cat > "$PREFIX/hq" <<'NPMSHIM'
#!/bin/sh
basedir=$(dirname "$(echo "$0" | sed -e 's,\\,/,g')")

case `uname` in
    *CYGWIN*|*MINGW*|*MSYS*)
        if command -v cygpath > /dev/null 2>&1; then
            basedir=`cygpath -w "$basedir"`
        fi
    ;;
esac

if [ -x "$basedir/node" ]; then
  exec "$basedir/node"  "$basedir/node_modules/@indigoai-us/hq-cli/dist/index.js" "$@"
else
  exec node  "$basedir/node_modules/@indigoai-us/hq-cli/dist/index.js" "$@"
fi
NPMSHIM
      printf '%s\r\n' '@ECHO off' 'node "%~dp0\node_modules\@indigoai-us\hq-cli\dist\index.js" %*' > "$PREFIX/hq.cmd"
      printf '%s\n' '#!/usr/bin/env pwsh' > "$PREFIX/hq.ps1"
      if [ "$kind" = "npm-crlf" ]; then
        # A shim checked out or copied with CRLF line endings.
        awk '{ printf "%s\r\n", $0 }' "$PREFIX/hq" > "$PREFIX/hq.crlf"
        mv "$PREFIX/hq.crlf" "$PREFIX/hq"
      fi
      ;;
    other)
      cat > "$PREFIX/hq" <<'OTHER'
#!/bin/sh
exec node "$HOME/some-other-cli/index.js" "$@"
OTHER
      ;;
  esac
  chmod +x "$PREFIX/hq"
}

# run_event <event> <legacy|default> — one event through the hook with the
# npm prefix ahead of everything else on PATH, the way Windows npm puts it.
run_event() {
  local event="$1" mode="$2" payload rc=0
  case "$event" in
    PostToolUse)
      payload="$(jq -cn --arg cwd "$TMP" '{hook_event_name:"PostToolUse",session_id:"windows-shim",tool_use_id:"toolu_windows_shim",tool_name:"Bash",cwd:$cwd,tool_input:{command:"git status"},tool_response:{stdout:"On branch main\nnothing to commit",stderr:"",interrupted:false}}')"
      ;;
    *)
      payload="$(jq -cn --arg cwd "$TMP" '{hook_event_name:"PreToolUse",session_id:"windows-shim",tool_name:"Bash",cwd:$cwd,tool_input:{command:"true"}}')"
      ;;
  esac
  unset BASH_ENV ENV HQ_POLICY_WORKER_DIR
  set +e
  if [ "$mode" = "legacy" ]; then
    PATH="$PREFIX:$TMP/bin:$PATH" HOME="$TMP/home" HQ_POLICY_TOOL_EVENTS=legacy \
      XDG_STATE_HOME="$TMP/home/.local/state" HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
      HQ_HOOK_PROFILE=standard HQ_HOOK_TIMEOUT_SENTRY=0 \
      bash "$TMP/.claude/hooks/inject-policy-on-trigger.sh" \
      <<<"$payload" >"$TMP/hook.out" 2>"$TMP/hook.err"
  else
    PATH="$PREFIX:$TMP/bin:$PATH" HOME="$TMP/home" \
      XDG_STATE_HOME="$TMP/home/.local/state" HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
      HQ_HOOK_PROFILE=standard HQ_HOOK_TIMEOUT_SENTRY=0 \
      bash "$TMP/.claude/hooks/inject-policy-on-trigger.sh" \
      <<<"$payload" >"$TMP/hook.out" 2>"$TMP/hook.err"
  fi
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || {
    echo "FAIL [$TMP]: hook exited $rc" >&2
    tail -50 "$TMP/hook.err" >&2
    exit 1
  }
}

count_lines() { wc -l < "$1" | tr -d ' '; }

# ---------------------------------------------------------------------------
# 1. PostToolUse with an npm shim at the floor: the companion runs and no node
#    process starts.
# ---------------------------------------------------------------------------
build_fixture shim-post 5.342.5 npm
[ ! -L "$PREFIX/hq" ] || { echo "FAIL: fixture hq must be a regular file, not a symlink" >&2; exit 1; }
run_event PostToolUse default
[ "$(count_lines "$COMPANION_LOG")" -ge 1 ] || {
  echo "FAIL: PostToolUse with a Windows npm hq shim never reached the packaged companion" >&2
  echo "      node starts: $(count_lines "$NODE_LOG")" >&2
  head -5 "$NODE_LOG" >&2
  exit 1
}
[ "$(count_lines "$NODE_LOG")" -eq 0 ] || {
  echo "FAIL: PostToolUse with a Windows npm hq shim started node $(count_lines "$NODE_LOG") time(s)" >&2
  head -5 "$NODE_LOG" >&2
  exit 1
}
while IFS= read -r line; do
  case "$line" in
    *"hq_root=$TMP") ;;
    *) echo "FAIL: companion received the wrong HQ root: $line" >&2; exit 1 ;;
  esac
done < "$COMPANION_LOG"
POST_COMPANION="$(count_lines "$COMPANION_LOG")"

# ---------------------------------------------------------------------------
# 2. PreToolUse on the pre-call fact path with the same shim: no node either.
# ---------------------------------------------------------------------------
build_fixture shim-pre 5.342.5 npm
run_event PreToolUse legacy
[ "$(count_lines "$COMPANION_LOG")" -ge 1 ] || {
  echo "FAIL: PreToolUse with a Windows npm hq shim never reached the packaged companion" >&2
  exit 1
}
[ "$(count_lines "$NODE_LOG")" -eq 0 ] || {
  echo "FAIL: PreToolUse with a Windows npm hq shim started node $(count_lines "$NODE_LOG") time(s)" >&2
  head -5 "$NODE_LOG" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 3. The CLI floor still holds on the shim path: a below-floor package falls
#    through to the forwarder, which refuses or runs the CLI as it always has.
# ---------------------------------------------------------------------------
build_fixture shim-below-floor 5.342.4 npm
run_event PreToolUse legacy
[ "$(count_lines "$COMPANION_LOG")" -eq 0 ] || {
  echo "FAIL: the packaged companion ran from a below-floor CLI behind an npm shim (5.342.4 < 5.342.5)" >&2
  cat "$COMPANION_LOG" >&2
  exit 1
}
grep -q "$TMP/core/scripts/derive-trigger-facts.sh" "$BASH_LOG" || {
  echo "FAIL: a below-floor CLI behind an npm shim did not fall through to the forwarder" >&2
  cat "$BASH_LOG" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 4. A regular `hq` script beside an hq-cli package that is not the npm shim for
#    it keeps the forwarder path. Only a shim that execs this package's
#    dist/index.js counts.
# ---------------------------------------------------------------------------
build_fixture not-a-shim 5.342.5 other
run_event PreToolUse legacy
[ "$(count_lines "$COMPANION_LOG")" -eq 0 ] || {
  echo "FAIL: a non-shim hq script was treated as the npm shim for @indigoai-us/hq-cli" >&2
  cat "$COMPANION_LOG" >&2
  exit 1
}
grep -q "$TMP/core/scripts/derive-trigger-facts.sh" "$BASH_LOG" || {
  echo "FAIL: a non-shim hq script did not fall through to the forwarder" >&2
  cat "$BASH_LOG" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 5. A CRLF shim resolves the same way.
# ---------------------------------------------------------------------------
build_fixture shim-crlf 5.342.5 npm-crlf
# Check the raw bytes: Git Bash's grep drops CR before matching.
od -An -tx1 "$PREFIX/hq" | grep -q ' 0d' || { echo "FAIL: CRLF fixture shim has no CR line endings" >&2; exit 1; }
run_event PreToolUse legacy
[ "$(count_lines "$COMPANION_LOG")" -ge 1 ] && [ "$(count_lines "$NODE_LOG")" -eq 0 ] || {
  echo "FAIL: a CRLF npm hq shim did not resolve to the packaged companion (node starts: $(count_lines "$NODE_LOG"))" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 6. The memo does not outlive the package behind an unchanged shim. Resolve
#    once at the floor, then replace the package in place with a below-floor
#    version without touching the shim: the next event must resolve again and
#    fall through to the forwarder.
# ---------------------------------------------------------------------------
build_fixture shim-memo 5.342.5 npm
run_event PreToolUse legacy
[ "$(count_lines "$COMPANION_LOG")" -ge 1 ] || {
  echo "FAIL: memo case did not reach the companion on the first event" >&2
  exit 1
}
MEMO="$TMP/workspace/orchestrator/hook-state/fact-helper-path"
[ -r "$MEMO" ] || { echo "FAIL: memo case wrote no fact-helper memo at $MEMO" >&2; exit 1; }
# Keep the shim older than the memo, so only the package change can expire it.
touch -t 200001010000 "$PREFIX/hq"
sleep 1
printf '{\n  "name": "@indigoai-us/hq-cli",\n  "version": "5.342.4"\n}\n' > "$PKG/package.json"
: > "$COMPANION_LOG"
: > "$BASH_LOG"
run_event PreToolUse legacy
[ "$(count_lines "$COMPANION_LOG")" -eq 0 ] || {
  echo "FAIL: the memo kept the companion after the package behind the shim dropped below the floor" >&2
  exit 1
}
grep -q "$TMP/core/scripts/derive-trigger-facts.sh" "$BASH_LOG" || {
  echo "FAIL: memo case did not fall through to the forwarder after the package dropped below the floor" >&2
  cat "$BASH_LOG" >&2
  exit 1
}

printf 'PASS: npm shim PostToolUse reached the companion %s time(s) with 0 node starts; PreToolUse 0 node starts; CRLF shim resolved; below-floor, replaced-package and non-shim hq fell through to the forwarder\n' \
  "$POST_COMPANION"
