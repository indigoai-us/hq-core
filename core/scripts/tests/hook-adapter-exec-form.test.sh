#!/usr/bin/env bash
# hq-core: public
# hook-adapter-exec-form.test.sh — Codex and Grok keep the master-hook.sh
# fan-out when .claude/settings.json registers the pinned native engine in
# exec form (US-015, hook-engine-launcher flag on).
#
# With the flag on, the update healer (restore-hook-settings.sh) and hq-cli's
# `hq reindex` reconcile (hq-cli PR 1992) replace each master-hook.sh line with
#   {command: $HOME/.hq/bin/hq-hook/<semver>/<binary>,
#    args: [<Event>, "--hq-root", <root>, "--runtime", "claude"]}
# The adapters must still run master-hook.sh for those entries, so the core,
# personal, pack and company hooks, including PreToolUse deny guards, keep
# running under Codex and Grok. This test:
#   1. runs both adapters against the healer's real flag-on output and against
#      1992's in-place reconcile shape, and proves every master event fans out
#      and a PreToolUse deny hook behind master-hook.sh still blocks, also
#      when the adapters run under a different HOME than the engine's;
#   2. proves exec entries that are not a pinned engine for this HQ root are
#      never treated as master-hook.sh (bypass cases);
#   3. proves an HQ root containing $(...) or backticks is not re-parsed as
#      shell text by the settings classifier.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
FAIL=0
pass() { echo "  ok: $1"; }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }

TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_TMP="$(cd "$TASK_TMP" && pwd -P)"
export HOME="$TASK_TMP/home" USERPROFILE="$TASK_TMP/home"
mkdir -p "$HOME" "$TASK_TMP/bin"

native() { # Windows: the CLI writes native paths.
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# The binary location hq-cli's resolve.ts pins for this platform.
case "$(uname -s)" in
  Darwin) PIN_BIN="hq-hook.app/Contents/MacOS/hq-hook" ;;
  MINGW* | MSYS* | CYGWIN*) PIN_BIN="hq-hook.exe" ;;
  *) PIN_BIN="hq-hook" ;;
esac
PIN="$HOME/.hq/bin/hq-hook/9.9.9/$PIN_BIN"
mkdir -p "$(dirname "$PIN")"
printf '#!/bin/sh\nexit 0\n' > "$PIN"
chmod +x "$PIN"
export HQ_TEST_PIN_NATIVE
HQ_TEST_PIN_NATIVE="$(native "$PIN")"

cat > "$TASK_TMP/bin/hq" <<'STUB'
#!/usr/bin/env bash
[ "$*" = 'core hook-engine-path --for-registration' ] || exit 3
printf '%s\n' "$HQ_TEST_PIN_NATIVE"
STUB
chmod +x "$TASK_TMP/bin/hq"
export PATH="$TASK_TMP/bin:$PATH"

# A fixture HQ root with the release settings, registry, adapters and core
# library. Hook scripts are stubs that log to $HQAD_TEST_LOG; master-hook.sh
# denies a PreToolUse Bash call whose command is `deny-probe`, the way a
# company PreToolUse guard behind the fan-out would.
make_fixture() {
  local fix="$1"
  mkdir -p "$fix/.claude/hooks" "$fix/.codex/hooks" "$fix/.grok/hooks" "$fix/core/scripts/lib"
  cp "$ROOT/.claude/settings.json" "$fix/.claude/settings.json"
  cp "$ROOT/.claude/hooks/hook-registry.json" "$fix/.claude/hooks/hook-registry.json"
  cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$fix/core/scripts/lib/hook-adapter-core.sh"
  cp "$ROOT/core/scripts/hook-lib.sh" "$fix/core/scripts/hook-lib.sh"
  cp "$ROOT/core/scripts/restore-hook-settings.sh" "$fix/core/scripts/restore-hook-settings.sh"
  cp "$ROOT/.codex/hooks/hq-codex-hook-adapter.sh" "$fix/.codex/hooks/hq-codex-hook-adapter.sh"
  cp "$ROOT/.grok/hooks/hq-grok-hook-adapter.sh" "$fix/.grok/hooks/hq-grok-hook-adapter.sh"
  : > "$fix/core/scripts/migrate-policy-triggers.sh"
  cat > "$fix/.claude/hooks/hook-gate.sh" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "--lib" ]; then
  return 0 2>/dev/null || exit 0
fi
cat >/dev/null 2>&1 || true
{ printf 'gate:%s\n' "$1" >> "${HQAD_TEST_LOG:-/dev/null}"; } 2>/dev/null || true
exit 0
STUB
  cat > "$fix/.claude/hooks/master-hook.sh" <<'STUB'
#!/bin/bash
payload="$(cat 2>/dev/null || true)"
{ printf 'master:%s\n' "$1" >> "${HQAD_TEST_LOG:-/dev/null}"; } 2>/dev/null || true
cmd="$(printf '%s' "$payload" | jq -r '(.tool_input // .toolInput // {}).command // empty' 2>/dev/null)"
if [ "$1" = "PreToolUse" ] && [ "$cmd" = "deny-probe" ]; then
  echo "BLOCKED: deny-probe company guard" >&2
  exit 2
fi
exit 0
STUB
  local id f
  # Files go to jq on stdin: Git Bash does not convert a path with a backtick
  # for native jq.exe.
  for id in $( { jq -r '.hooks[][]?.hooks[]?.command' < "$fix/.claude/settings.json" \
                | grep -oE '/[a-z0-9-]+\.sh"' | tr -d '/"';
                jq -r '.hooks[][]?.hooks[]?.script' < "$fix/.claude/hooks/hook-registry.json" \
                | sed 's#.*/##'; } | sort -u); do
    f="$fix/.claude/hooks/$id"
    [ -e "$f" ] || printf '#!/bin/bash\ncat >/dev/null 2>&1\nexit 0\n' > "$f"
  done
  chmod +x "$fix/.claude/hooks/"*.sh 2>/dev/null || true
}

MASTER_EVENTS="$(jq -r '.hooks | to_entries[] | select([.value[]?.hooks[]?.command | strings | test("master-hook\\.sh")] | length > 0) | .key' < "$ROOT/.claude/settings.json" | tr -d '\r')"
[ -n "$MASTER_EVENTS" ] || { echo "FAIL: release settings register no master-hook.sh events" >&2; exit 1; }

run_recorded() { # <fixture> <adapter> <payload> -> record log
  local log; log="$(mktemp)"
  HQAD_TEST_LOG="$log" HQ_ROOT="$1" HQ_ALLOW_HQ_WORKTREE=1 \
    bash "$2" >/dev/null 2>&1 <<<"$3" || true
  cat "$log" 2>/dev/null
  rm -f "$log"
}

codex_payload() { # <fixture> <event> [command]
  if [ -n "${3:-}" ]; then
    jq -cn --arg ev "$2" --arg cwd "$1" --arg c "$3" '{hook_event_name:$ev,tool_name:"Bash",cwd:$cwd,session_id:"t",tool_input:{command:$c}}'
  else
    jq -cn --arg ev "$2" --arg cwd "$1" '{hook_event_name:$ev,cwd:$cwd,session_id:"t"}'
  fi
}
grok_payload() { # <fixture> <event> [command]
  if [ -n "${3:-}" ]; then
    jq -cn --arg ev "$2" --arg cwd "$1" --arg c "$3" '{hookEventName:$ev,toolName:"Shell",cwd:$cwd,sessionId:"t",toolInput:{command:$c}}'
  else
    jq -cn --arg ev "$2" --arg cwd "$1" '{hookEventName:$ev,cwd:$cwd,sessionId:"t"}'
  fi
}

# Every master event fans out through master-hook.sh, and a PreToolUse deny
# behind master-hook.sh blocks the tool, in both adapters.
assert_fanout_and_deny() { # <label> <fixture>
  local label="$1" fix="$2" ev recorded out status codex_checked=0
  local codex="$fix/.codex/hooks/hq-codex-hook-adapter.sh" grok="$fix/.grok/hooks/hq-grok-hook-adapter.sh"
  for ev in $MASTER_EVENTS; do
    # Codex has no Notification or SubagentStart event; check only the events
    # its adapter dispatches.
    ! grep -qE "^  $ev\)" "$codex" || {
      codex_checked=$((codex_checked + 1))
      if [ "$ev" = PreToolUse ] || [ "$ev" = PostToolUse ]; then
        recorded="$(run_recorded "$fix" "$codex" "$(codex_payload "$fix" "$ev" "echo hi")")"
      else
        recorded="$(run_recorded "$fix" "$codex" "$(codex_payload "$fix" "$ev")")"
      fi
      printf '%s\n' "$recorded" | grep >/dev/null -x "master:$ev" \
        && pass "$label codex $ev runs master-hook.sh" \
        || fail "$label codex $ev dropped the master-hook.sh fan-out"
    }
    if [ "$ev" = PreToolUse ] || [ "$ev" = PostToolUse ]; then
      recorded="$(run_recorded "$fix" "$grok" "$(grok_payload "$fix" "$ev" "echo hi")")"
    else
      recorded="$(run_recorded "$fix" "$grok" "$(grok_payload "$fix" "$ev")")"
    fi
    printf '%s\n' "$recorded" | grep >/dev/null -x "master:$ev" \
      && pass "$label grok $ev runs master-hook.sh" \
      || fail "$label grok $ev dropped the master-hook.sh fan-out (log: $(printf '%q' "$recorded"); adapter: $(HQ_ROOT="$fix" HQ_ALLOW_HQ_WORKTREE=1 bash "$grok" 2>&1 <<<"$(grok_payload "$fix" "$ev")" | tail -c 600))"
  done
  # A malformed event list (e.g. CRLF from jq.exe) would skip every Codex check.
  [ "$codex_checked" -ge 8 ] \
    && pass "$label codex fan-out checked $codex_checked events" \
    || fail "$label codex fan-out checked only $codex_checked events"

  status=0
  out="$(HQ_ROOT="$fix" HQ_ALLOW_HQ_WORKTREE=1 bash "$codex" 2>&1 <<<"$(codex_payload "$fix" PreToolUse deny-probe)")" || status=$?
  if [ "$status" -ne 0 ] && printf '%s' "$out" | grep >/dev/null 'deny-probe company guard'; then
    pass "$label codex PreToolUse deny hook behind master-hook.sh blocks (exit $status)"
  else
    fail "$label codex PreToolUse deny hook did not block (exit $status): $out"
  fi
  out="$(HQ_ROOT="$fix" bash "$grok" 2>/dev/null <<<"$(grok_payload "$fix" PreToolUse deny-probe)" || true)"
  if printf '%s' "$out" | jq -e '.decision == "deny" and (.reason | contains("deny-probe company guard"))' >/dev/null 2>&1; then
    pass "$label grok PreToolUse deny hook behind master-hook.sh blocks"
  else
    fail "$label grok PreToolUse deny hook did not block: $out"
  fi
}

no_master_hook_lines() { # <fixture>: only the Stop waiter may remain bash
  jq -e '[.hooks[][] .hooks[] | .command | strings | select(test("master-hook\\.sh"))] | length == 0' "$1/.claude/settings.json" >/dev/null
}

# --------------------------------------------------------------------------
# 1a. The healer's own flag-on output.
# --------------------------------------------------------------------------
echo "[healer flag-on output]"
HEALED="$TASK_TMP/healed root"
make_fixture "$HEALED"
bash "$HEALED/core/scripts/restore-hook-settings.sh" "$HEALED" >/dev/null
if no_master_hook_lines "$HEALED" \
  && jq -e --arg e "$HQ_TEST_PIN_NATIVE" '[.hooks[][] .hooks[] | select(.command == $e and (.args | type == "array"))] | length == 10' "$HEALED/.claude/settings.json" >/dev/null; then
  pass "healer wrote ten pinned engine entries and no master-hook.sh lines"
else
  fail "healer did not write the flag-on exec form: $(jq -c '.hooks.PreToolUse' "$HEALED/.claude/settings.json")"
fi
assert_fanout_and_deny "healer" "$HEALED"

# --------------------------------------------------------------------------
# 1b. hq-cli 1992's reconcile shape: each shipped master-hook.sh entry is
#     converted in place (other entries, group order and extra fields kept),
#     with --hq-root = launcherRoot(fs.realpathSync(root)).
# --------------------------------------------------------------------------
echo "[hq reindex reconcile output]"
RECONCILED="$TASK_TMP/reconciled root"
make_fixture "$RECONCILED"
RECONCILED_ROOT="$(native "$(cd "$RECONCILED" && pwd -P)")"
jq --arg engine "$HQ_TEST_PIN_NATIVE" --arg root "$RECONCILED_ROOT" '
  .hooks |= with_entries(.key as $ev | .value |= map(
    if (.hooks | type) == "array" then .hooks |= map(
      if (.command | type) == "string"
         and .command == ("env BASH_ENV=/dev/null bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/master-hook.sh\" " + $ev)
      then .command = $engine | .args = [$ev, "--hq-root", $root, "--runtime", "claude"]
      else . end)
    else . end))
' "$RECONCILED/.claude/settings.json" > "$RECONCILED/.claude/settings.json.next" \
  && mv "$RECONCILED/.claude/settings.json.next" "$RECONCILED/.claude/settings.json"
if no_master_hook_lines "$RECONCILED"; then
  pass "reconcile fixture converted every master-hook.sh entry"
else
  fail "reconcile fixture still has master-hook.sh lines; the release bash line changed"
fi
assert_fanout_and_deny "reindex" "$RECONCILED"

# --------------------------------------------------------------------------
# 1c. The adapters run under a different HOME than the one the engine was
#     pinned under (sudo, a sandbox or devcontainer, a fleet runtime, a
#     Windows HOME/USERPROFILE split). The release settings register
#     PreToolUse only through the engine entry, so dropping it would silently
#     drop every personal, pack and company guard. The adapters never run the
#     named binary, so the entry still counts as master-hook.sh, with a
#     warning on stderr.
# --------------------------------------------------------------------------
echo "[adapters under a different HOME]"
RUNTIME_HOME="$TASK_TMP/runtime-home"
mkdir -p "$RUNTIME_HOME"
HOME="$RUNTIME_HOME" USERPROFILE="$RUNTIME_HOME" assert_fanout_and_deny "other-HOME healer" "$HEALED"
HOME="$RUNTIME_HOME" USERPROFILE="$RUNTIME_HOME" assert_fanout_and_deny "other-HOME reindex" "$RECONCILED"
for adapter in .codex/hooks/hq-codex-hook-adapter.sh .grok/hooks/hq-grok-hook-adapter.sh; do
  case "$adapter" in
    .codex/*) payload="$(codex_payload "$HEALED" PreToolUse "echo hi")" ;;
    *) payload="$(grok_payload "$HEALED" PreToolUse "echo hi")" ;;
  esac
  warn="$(HOME="$RUNTIME_HOME" USERPROFILE="$RUNTIME_HOME" HQ_ROOT="$HEALED" HQ_ALLOW_HQ_WORKTREE=1 \
    bash "$HEALED/$adapter" 2>&1 >/dev/null <<<"$payload" || true)"
  if printf '%s' "$warn" | grep >/dev/null 'is not under this HOME'; then
    pass "other-HOME $adapter warns on stderr"
  else
    fail "other-HOME $adapter printed no warning: $warn"
  fi
done

# --------------------------------------------------------------------------
# 2. Bypass cases: only a pinned engine for this HQ root is master.
# --------------------------------------------------------------------------
echo "[exec entries that are not the pinned engine]"
BYPASS="$TASK_TMP/bypass root"
make_fixture "$BYPASS"
BYPASS_ROOT="$(native "$(cd "$BYPASS" && pwd -P)")"
OTHER_ROOT="$TASK_TMP/other root"
mkdir -p "$OTHER_ROOT/.claude" "$TASK_TMP/other-home/.hq/bin/hq-hook/9.9.9" "$TASK_TMP/evil"
ln -s "$BYPASS" "$TASK_TMP/bypass link" 2>/dev/null || true
cp "$BYPASS/.claude/settings.json" "$BYPASS/.claude/settings.release.json"

# Settings with one PreToolUse exec entry and nothing else, then the master
# records the shared iterator emits for PreToolUse/Bash.
# The command is JSON-encoded on stdin first: Git Bash would rewrite a
# path-like --arg for native jq.exe and collapse a ../ segment before the
# adapter ever saw it.
exec_master_records() { # <command> <args-json>
  # The command reaches jq through a file: Git Bash rewrites (and collapses
  # ../ in) path-like arguments to native jq.exe, even inside a JSON string.
  # Compare inside jq too: jq.exe -r output ends lines with CRLF.
  local cf="$TASK_TMP/bypass-command.txt"
  printf '%s' "$1" > "$cf"
  jq --rawfile c "$cf" --argjson a "$2" '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$c,timeout:300,args:$a}]}]}}' \
    < "$BYPASS/.claude/settings.release.json" > "$BYPASS/.claude/settings.json"
  jq -e --rawfile c "$cf" '.hooks.PreToolUse[0].hooks[0].command == $c' < "$BYPASS/.claude/settings.json" >/dev/null \
    || { printf 'fixture error: the command was rewritten before jq stored it\n'; return 1; }
  ( set +u; . "$BYPASS/core/scripts/lib/hook-adapter-core.sh"
    HQ_ROOT="$BYPASS" hqad_iter_settings PreToolUse Bash '{}' 2>/dev/null | grep '^master' )
}
args_for() { jq -cn --arg ev "${2:-PreToolUse}" --arg r "$1" '[$ev, "--hq-root", $r, "--runtime", "claude"]'; }

expect_master() { # <label> <command> <args-json>
  [ "$(exec_master_records "$2" "$3")" = "$(printf 'master\tPreToolUse')" ] \
    && pass "accepts $1" || fail "rejected $1"
}
expect_none() { # <label> <command> <args-json>
  local got; got="$(exec_master_records "$2" "$3")"
  [ -z "$got" ] && pass "rejects $1" || fail "treated $1 as master-hook.sh: $got"
}

expect_master "pinned engine for this root" "$HQ_TEST_PIN_NATIVE" "$(args_for "$BYPASS_ROOT")"
expect_master "pinned engine with POSIX path spelling" "$PIN" "$(args_for "$BYPASS")"
expect_master "linux binary name" "$HOME/.hq/bin/hq-hook/9.9.9/hq-hook" "$(args_for "$BYPASS_ROOT")"
expect_master "windows binary name" "$HOME/.hq/bin/hq-hook/9.9.9/hq-hook.exe" "$(args_for "$BYPASS_ROOT")"
expect_master "macOS app-bundle binary" "$HOME/.hq/bin/hq-hook/9.9.9/hq-hook.app/Contents/MacOS/hq-hook" "$(args_for "$BYPASS_ROOT")"
expect_master "pre-release semver directory" "$HOME/.hq/bin/hq-hook/9.9.9-beta.1/hq-hook" "$(args_for "$BYPASS_ROOT")"
expect_master "trailing slash on --hq-root" "$PIN" "$(args_for "$BYPASS/")"
if [ -L "$TASK_TMP/bypass link" ]; then
  expect_master "--hq-root through a symlink to this root" "$PIN" "$(args_for "$TASK_TMP/bypass link")"
else
  echo "SKIP: --hq-root through a symlink (ln -s unavailable)"
fi
# The CLI pins under os.homedir(); the adapter's HOME may spell it differently.
ln -s "$HOME" "$TASK_TMP/home link" 2>/dev/null || true
if [ -L "$TASK_TMP/home link" ]; then
  HOME="$TASK_TMP/home link" expect_master "pinned engine with HOME through a symlink" "$PIN" "$(args_for "$BYPASS_ROOT")"
else
  echo "SKIP: HOME through a symlink (ln -s unavailable)"
fi
HOME=/ expect_master "pinned engine when HOME is /" "/.hq/bin/hq-hook/9.9.9/hq-hook" "$(args_for "$BYPASS_ROOT")"
mkdir -p "$TASK_TMP/git-bash-home"
if command -v cygpath >/dev/null 2>&1; then
  # Windows: Git Bash's HOME can differ from USERPROFILE, which Node uses.
  HOME="$TASK_TMP/git-bash-home" expect_master "pinned engine under USERPROFILE when HOME differs" "$HQ_TEST_PIN_NATIVE" "$(args_for "$BYPASS_ROOT")"
fi

# The pinned layout under a home other than this process's still counts as
# master (the adapters never run the binary), and says so on stderr. Without
# a warning the dropped guards would be invisible; with no record at all they
# would be dropped.
expect_master_warned() { # <label> <command> <args-json>
  local errf="$TASK_TMP/exec-warn.txt" got
  got="$(exec_master_records "$2" "$3" 2>/dev/null)"
  ( set +u; . "$BYPASS/core/scripts/lib/hook-adapter-core.sh"
    HQ_ROOT="$BYPASS" hqad_iter_settings PreToolUse Bash '{}' >/dev/null 2>"$errf" )
  if [ "$got" = "$(printf 'master\tPreToolUse')" ] && grep -q 'is not under this HOME' "$errf"; then
    pass "accepts $1, with a warning"
  else
    fail "$1: records '$got', stderr '$(cat "$errf")'"
  fi
}
expect_master_warned "the pinned layout under another HOME" "$TASK_TMP/other-home/.hq/bin/hq-hook/9.9.9/hq-hook" "$(args_for "$BYPASS_ROOT")"
HOME=/ USERPROFILE="$TASK_TMP/other-home" expect_master_warned "a pinned engine outside / when HOME is /" "$PIN" "$(args_for "$BYPASS_ROOT")"
if ! command -v cygpath >/dev/null 2>&1; then
  # Off Windows Node uses HOME only, so USERPROFILE does not silence the warning.
  HOME="$TASK_TMP/git-bash-home" expect_master_warned "an engine under USERPROFILE off Windows" "$PIN" "$(args_for "$BYPASS_ROOT")"
fi
# A matching HOME prints nothing.
errf="$TASK_TMP/exec-quiet.txt"
exec_master_records "$PIN" "$(args_for "$BYPASS_ROOT")" >/dev/null
( set +u; . "$BYPASS/core/scripts/lib/hook-adapter-core.sh"
  HQ_ROOT="$BYPASS" hqad_iter_settings PreToolUse Bash '{}' >/dev/null 2>"$errf" )
grep -q 'is not under this HOME' "$errf" && fail "warned for the engine under this HOME" || pass "no warning for the engine under this HOME"
# Another HOME does not widen the root check.
expect_none "the pinned layout under another HOME for another root" "$TASK_TMP/other-home/.hq/bin/hq-hook/9.9.9/hq-hook" "$(args_for "$OTHER_ROOT")"

expect_none "a foreign exec entry outside the pinned path" "/usr/local/bin/hq-hook" "$(args_for "$BYPASS_ROOT")"
expect_none "a foreign script under the HQ root" "$BYPASS/.claude/hooks/master-hook.sh" "$(args_for "$BYPASS_ROOT")"
expect_none "a foreign binary under another HOME's .hq/bin" "$TASK_TMP/other-home/.hq/bin/evil" "$(args_for "$BYPASS_ROOT")"
expect_none "a non-semver directory under another HOME" "$TASK_TMP/other-home/.hq/bin/hq-hook/latest/hq-hook" "$(args_for "$BYPASS_ROOT")"
expect_none "a non-semver version directory" "$HOME/.hq/bin/hq-hook/latest/hq-hook" "$(args_for "$BYPASS_ROOT")"
expect_none "a binary name the CLI never pins" "$HOME/.hq/bin/hq-hook/9.9.9/evil" "$(args_for "$BYPASS_ROOT")"
expect_none "a nested path below the version directory" "$HOME/.hq/bin/hq-hook/9.9.9/x/hq-hook" "$(args_for "$BYPASS_ROOT")"
expect_none "../ traversal out of the pinned directory" "$HOME/.hq/bin/hq-hook/9.9.9/../../../../../evil/hq-hook" "$(args_for "$BYPASS_ROOT")"
expect_none "../ traversal into the pinned layout" "$TASK_TMP/evil/../home/.hq/bin/hq-hook/9.9.9/hq-hook" "$(args_for "$BYPASS_ROOT")"
expect_none "a relative engine path" ".hq/bin/hq-hook/9.9.9/hq-hook" "$(args_for "$BYPASS_ROOT")"
expect_none "a mismatched --hq-root" "$PIN" "$(args_for "$OTHER_ROOT")"
expect_none "a --hq-root that does not exist" "$PIN" "$(args_for "$TASK_TMP/missing root")"
expect_none "an empty --hq-root" "$PIN" "$(args_for "")"
expect_none "a missing --hq-root flag" "$PIN" "$(jq -cn --arg r "$BYPASS_ROOT" '["PreToolUse", "--root", $r]')"
expect_none "an event argument that names another slot" "$PIN" "$(args_for "$BYPASS_ROOT" Stop)"
expect_none "an event argument with shell characters" "$PIN" "$(args_for "$BYPASS_ROOT" 'PreToolUse;id')"
expect_none "an empty args array" "$PIN" '[]'
expect_none "non-string args" "$PIN" "$(jq -cn --arg r "$BYPASS_ROOT" '["PreToolUse", "--hq-root", $r, 5]')"

# A foreign exec entry must not knock out the other settings records (no
# frame failure, no fallback): the gates registered alongside still emit.
jq --arg r "$BYPASS_ROOT" '.hooks.PreToolUse += [{matcher:"Bash",hooks:[{type:"command",command:"/usr/local/bin/other",args:["x","--hq-root",$r]}]}]' \
  "$BYPASS/.claude/settings.release.json" > "$BYPASS/.claude/settings.json"
with_foreign="$( ( set +u; . "$BYPASS/core/scripts/lib/hook-adapter-core.sh"
  HQ_ROOT="$BYPASS" hqad_iter_settings PreToolUse Bash '{}' 2>/dev/null ) | LC_ALL=C sort)"
without_foreign="$( ( set +u; cp "$BYPASS/.claude/settings.release.json" "$BYPASS/.claude/settings.json"
  . "$BYPASS/core/scripts/lib/hook-adapter-core.sh"
  HQ_ROOT="$BYPASS" hqad_iter_settings PreToolUse Bash '{}' 2>/dev/null ) | LC_ALL=C sort)"
if [ -n "$without_foreign" ] && [ "$with_foreign" = "$without_foreign" ]; then
  pass "a foreign exec entry leaves the other PreToolUse records unchanged"
else
  fail "a foreign exec entry changed the PreToolUse records"
fi

# --------------------------------------------------------------------------
# 3. The HQ root is data, never shell text, in the settings classifier.
# --------------------------------------------------------------------------
echo "[HQ root with shell metacharacters]"
for name in 'meta $(touch PWNED-dollar) root' 'meta `touch PWNED-tick` root'; do
  META="$TASK_TMP/$name"
  make_fixture "$META"
  records="$( cd "$TASK_TMP" && ( set +u; . "$META/core/scripts/lib/hook-adapter-core.sh"
    HQ_ROOT="$META" hqad_iter_settings PreToolUse Bash '{}' 2>/dev/null ) )"
  if [ -n "$(find "$TASK_TMP" -name 'PWNED-*' 2>/dev/null)" ]; then
    fail "root '$name' was evaluated as shell text"
  elif printf '%s\n' "$records" | grep >/dev/null -F "$(printf 'master\tPreToolUse')" \
    && printf '%s\n' "$records" | grep -F "$META/.claude/hooks/" >/dev/null; then
    pass "root '$name' stays a literal path"
  else
    fail "root '$name' lost its records: $records"
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "hook-adapter-exec-form: $FAIL failure(s)" >&2
  exit 1
fi
echo "hook-adapter-exec-form: all checks passed"
