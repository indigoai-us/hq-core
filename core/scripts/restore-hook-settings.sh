#!/bin/bash
# hq-core: public
# restore-hook-settings.sh — put release hook wiring back in settings.json.
#
# `hq rescue` three-way-merges .claude/settings.json and relocates "drift"
# into .claude/settings.local.json. When the pre-rescue hook objects are not
# byte-identical to the floor (timeout, extra doctor registrations, key
# order), that relocate:
#   1. treats the shipped master-hook.sh lines as user deletions and writes
#      empty event arrays into settings.json, and
#   2. copies those lines (plus any stray hook-gate entries) into
#      settings.local.json.
# Deleting the local hooks key then silently disables every hook.
# (feedback 2282 / update-hq v15.0.117 → v15.0.137)
#
# This healer:
#   - writes the ten canonical master-hook.sh registrations into
#     settings.json, plus the shipped Stop waiter
#     hq-monitor-session-hook.sh wait (asyncRewake, timeout 86400)
#     (other keys, including env.PATH, are preserved)
#   - deletes the hooks key from settings.local.json (permissions/env stay)
# Idempotent. python-free. Always exits 0 unless a rewrite could not be saved.
#
# Usage: restore-hook-settings.sh [HQ_ROOT]

HQ_ROOT="${1:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
CLAUDE_DIR="$HQ_ROOT/.claude"
BASE="$CLAUDE_DIR/settings.json"
LOCAL="$CLAUDE_DIR/settings.local.json"

[ -f "$BASE" ] || exit 0

if [ -f "$HQ_ROOT/core/scripts/hook-lib.sh" ]; then
  . "$HQ_ROOT/core/scripts/hook-lib.sh" 2>/dev/null
else
  HQ_LIB_JQ="$(command -v jq 2>/dev/null || true)"
  HQ_LIB_NODE="$(command -v node 2>/dev/null || true)"
fi

EVENTS='["PreToolUse","PostToolUse","PreCompact","Stop","SessionStart","UserPromptSubmit","Notification","SubagentStart","SubagentStop","SessionEnd"]'

# The CLI resolves the scoped, fresh, default-off flag and pins the installed
# engine offline. Old CLIs, a disabled flag or missing package retain bash.
# The probe runs under a time limit so a hung hq cannot stall /update-hq; a
# probe that times out also keeps bash. It runs from the HQ root so the CLI
# reads that root's scoped flag, and as its own process group (set -m) so a
# timeout also stops anything hq started. The function body is a subshell, so
# set -m does not leak into the healer.
probe_engine() (
  out="" pid="" ticks=0 limit="${HQ_HOOK_ENGINE_PROBE_TIMEOUT:-15}"
  case "$limit" in '' | *[!0-9]*) limit=15 ;; esac
  out="$(mktemp "${TMPDIR:-/tmp}/hq-engine-probe.XXXXXX" 2>/dev/null)" || return 1
  # Job-control notices ("[1]+ Done") go to stderr; keep them out of the heal output.
  exec 2>/dev/null
  set -m
  (cd "$HQ_ROOT" 2>/dev/null && exec hq core hook-engine-path --for-registration) >"$out" 2>/dev/null </dev/null &
  pid=$!
  # The probe's group no longer gets the terminal's Ctrl-C; pass it on.
  # (Best effort on Windows, where native children may outlive the group kill.)
  trap 'kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; rm -f "$out"; exit 130' INT TERM HUP
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge $((limit * 10)) ]; then
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      sleep 0.2
      kill -KILL -- "-$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rm -f "$out"
      return 1
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  if wait "$pid"; then cat "$out"; rm -f "$out"; return 0; fi
  rm -f "$out"
  return 1
)

# Only the engine hq-cli pins is accepted:
# <home>/.hq/bin/hq-hook/<semver>/{hq-hook,hq-hook.exe,hq-hook.app/Contents/MacOS/hq-hook}.
# Any other path the probe prints (/bin/sh, a script elsewhere) keeps bash.
# A <home> other than this shell's is accepted with a warning. This shell's
# home follows the CLI's os.homedir(): HOME, plus USERPROFILE on Windows,
# where Git Bash's HOME can differ. cygpath maps native paths to one form.
# HOME=/ gives an empty prefix. Same rules as hqad_classify_exec.
engine_is_pinned() {
  local p="$1" prefix rest ver bin cand home ok=1
  [ -n "$p" ] || return 1
  case "$p" in *$'\n'* | *$'\r'*) return 1 ;; esac
  if command -v cygpath >/dev/null 2>&1; then
    p="$(cygpath -u "$p" 2>/dev/null)" || return 1
  fi
  case "$p" in /*/.hq/bin/hq-hook/* | /.hq/bin/hq-hook/*) ;; *) return 1 ;; esac
  case "$p/" in */../* | */./* | *//*) return 1 ;; esac
  prefix="${p%%/.hq/bin/hq-hook/*}"
  for cand in "${HOME:-}" "$( { command -v cygpath >/dev/null 2>&1 && [ -n "${USERPROFILE:-}" ] && cygpath -u "$USERPROFILE"; } 2>/dev/null)"; do
    [ -n "$cand" ] || continue
    home="$cand"
    if command -v cygpath >/dev/null 2>&1; then home="$(cygpath -u "$home" 2>/dev/null)" || continue; fi
    while [ -n "$home" ] && [ "${home%/}" != "$home" ]; do home="${home%/}"; done
    if [ -z "$home" ]; then
      [ -z "$prefix" ] && ok=0
    elif [ -n "$prefix" ] && { [ "$prefix" = "$home" ] || [ "$prefix" -ef "$home" ]; }; then
      ok=0
    fi
    [ "$ok" -eq 0 ] && break
  done
  rest="${p#"$prefix"/.hq/bin/hq-hook/}"
  ver="${rest%%/*}"
  bin="${rest#*/}"
  [ "$ver" != "$rest" ] || return 1
  printf '%s\n' "$ver" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' || return 1
  case "$bin" in hq-hook | hq-hook.exe | hq-hook.app/Contents/MacOS/hq-hook) ;; *) return 1 ;; esac
  # The CLI printed its own pin, so a pinned layout under another home is
  # still the engine. The adapters accept it the same way; warn so the split
  # is visible.
  [ "$ok" -eq 0 ] || echo "WARN: hook engine $1 is not under this HOME; registering it anyway." >&2
  return 0
}
ENGINE=""
if command -v hq >/dev/null 2>&1; then
  ENGINE="$(probe_engine)" || ENGINE=""
fi
[ -n "$ENGINE" ] && [ -f "$ENGINE" ] && engine_is_pinned "$ENGINE" || ENGINE=""
# The root argument must be spelled the way hq reindex spells it:
# launcherRoot(fs.realpathSync(path.resolve(root))) in hq-cli. The CLI
# recognizes its own entries by that exact token, so any other spelling would
# stop a later flag-off reindex from restoring bash. When Node is present the
# same expression runs here, so drive-letter and directory case, 8.3 names and
# spaces come out exactly as the CLI spells them (Git Bash converts the
# argument the same way it does for hq). Without Node the shell fallback
# approximates it (HQ_HOOK_ROOT_RESOLVER=shell forces it for tests). The CLI
# prints native Windows paths; jq/Node keep them as JSON strings.
ENGINE_ROOT="$HQ_ROOT"
ROOT_NODE="$(command -v node 2>/dev/null || true)"
[ "${HQ_HOOK_ROOT_RESOLVER:-}" = shell ] && ROOT_NODE=""
if [ -n "$ENGINE" ]; then
  if [ -n "$ROOT_NODE" ]; then
    ENGINE_ROOT="$("$ROOT_NODE" -e '
      const fs = require("fs"), path = require("path");
      const real = fs.realpathSync(path.resolve(process.argv[1]));
      const trimmed = real.replace(/[\\/]+$/, "");
      process.stdout.write(trimmed === "" || /^[A-Za-z]:$/.test(trimmed) ? real : trimmed);
    ' "$HQ_ROOT" 2>/dev/null)" || ENGINE_ROOT=""
  else
    ENGINE_ROOT="$(cd "$HQ_ROOT" 2>/dev/null && pwd -P)" || ENGINE_ROOT=""
    if [ -n "$ENGINE_ROOT" ] && command -v cygpath >/dev/null 2>&1; then
      ENGINE_ROOT="$(cygpath -w "$ENGINE_ROOT")"
    fi
    while :; do
      case "$ENGINE_ROOT" in
        / | [A-Za-z]:[\\/]) break ;;
        */ | *\\) ENGINE_ROOT="${ENGINE_ROOT%?}" ;;
        *) break ;;
      esac
    done
  fi
  # A root we cannot resolve gets bash, never an engine entry with a bad root.
  [ -n "$ENGINE_ROOT" ] || ENGINE=""
fi

JQ_CANON='
def master_hook($e):
  {hooks: ([{
    type: "command",
    command: (
      "env BASH_ENV=/dev/null bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/master-hook.sh\" " + $e
    ),
    timeout: 300
  }] | if $engine != "" then .[0].command = $engine | .[0].args = [$e,"--hq-root",$root,"--runtime","claude"] else . end)};
def stop_waiter:
  {hooks:[{
    type: "command",
    command: "env BASH_ENV=/dev/null bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/hq-monitor-session-hook.sh\" wait",
    asyncRewake: true,
    timeout: 86400
  }]};
def canonical_hooks:
  reduce $events[] as $e ({};
    .[$e] = (if $e == "Stop" then [stop_waiter, master_hook($e)] else [master_hook($e)] end));
def restore:
  .hooks = canonical_hooks;
'

NODE_PROG='
const fs = require("fs");
const [file, mode, engine, root] = process.argv.slice(1);
const EVENTS = ["PreToolUse","PostToolUse","PreCompact","Stop","SessionStart","UserPromptSubmit","Notification","SubagentStart","SubagentStop","SessionEnd"];
const masterHook = (e) => ({hooks:[{
  type: "command",
  command: "env BASH_ENV=/dev/null bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/master-hook.sh\" " + e,
  timeout: 300,
  ...(engine ? {command: engine, args: [e,"--hq-root",root,"--runtime","claude"]} : {})
}]});
const stopWaiter = {hooks:[{
  type: "command",
  command: "env BASH_ENV=/dev/null bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/hq-monitor-session-hook.sh\" wait",
  asyncRewake: true,
  timeout: 86400
}]};
const canonicalHooks = () => {
  const h = {};
  for (const e of EVENTS) {
    h[e] = e === "Stop" ? [stopWaiter, masterHook(e)] : [masterHook(e)];
  }
  return h;
};
let d; try { d = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) { process.exit(1); }
if (!d || typeof d !== "object" || Array.isArray(d)) process.exit(1);
if (mode === "local") {
  if (!Object.prototype.hasOwnProperty.call(d, "hooks")) { process.stdout.write("unchanged"); process.exit(0); }
  delete d.hooks;
  process.stdout.write(JSON.stringify(d, null, 2) + "\n");
  process.exit(0);
}
const before = JSON.stringify(d);
d.hooks = canonicalHooks();
if (JSON.stringify(d) === before) { process.stdout.write("unchanged"); process.exit(0); }
process.stdout.write(JSON.stringify(d, null, 2) + "\n");
'

rewrite_base() {
  if [ -n "${HQ_LIB_JQ:-}" ] && [ "${HQ_HOOK_ENGINE:-}" != "node" ]; then
    "$HQ_LIB_JQ" -r --argjson events "$EVENTS" --arg engine "$ENGINE" --arg root "$ENGINE_ROOT" "$JQ_CANON"'
      restore as $next
      | if . == $next then "unchanged" else $next end
    ' "$BASE" 2>/dev/null
  elif [ -n "${HQ_LIB_NODE:-}" ]; then
    "$HQ_LIB_NODE" -e "$NODE_PROG" "$BASE" base "$ENGINE" "$ENGINE_ROOT" 2>/dev/null
  fi
}

rewrite_local() {
  if [ -n "${HQ_LIB_JQ:-}" ] && [ "${HQ_HOOK_ENGINE:-}" != "node" ]; then
    "$HQ_LIB_JQ" -r '
      if has("hooks") then del(.hooks) else "unchanged" end
    ' "$LOCAL" 2>/dev/null
  elif [ -n "${HQ_LIB_NODE:-}" ]; then
    "$HQ_LIB_NODE" -e "$NODE_PROG" "$LOCAL" local 2>/dev/null
  fi
}

write_atomic() {
  local dest="$1" body="$2"
  local tmp="$dest.hq-restore-tmp.$$"
  if printf '%s\n' "$body" > "$tmp" 2>/dev/null && mv "$tmp" "$dest" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

CHANGED=0
# The PID suffix keeps two heals within the same second from sharing a backup dir.
STAMP="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo now)-$$"
BACKUP_DIR="$HQ_ROOT/workspace/.hq-update-check/settings-backups/$STAMP"

BASE_OUT="$(rewrite_base)"
[ -n "$BASE_OUT" ] || { echo "restore-hook-settings: could not parse .claude/settings.json" >&2; exit 1; }
if [ "$BASE_OUT" != "unchanged" ]; then
  mkdir -p "$BACKUP_DIR" 2>/dev/null || true
  cp -p "$BASE" "$BACKUP_DIR/settings.json" 2>/dev/null || true
  if write_atomic "$BASE" "$BASE_OUT"; then
    if [ -n "$ENGINE" ]; then
      echo "registered the pinned hook engine for the ten hook events in .claude/settings.json"
    else
      echo "restored canonical master-hook.sh registrations in .claude/settings.json"
    fi
    CHANGED=1
  else
    echo "restore-hook-settings: could not write .claude/settings.json" >&2
    exit 1
  fi
fi

if [ -f "$LOCAL" ]; then
  LOCAL_OUT="$(rewrite_local)"
  [ -n "$LOCAL_OUT" ] || { echo "restore-hook-settings: could not parse .claude/settings.local.json" >&2; exit 1; }
  if [ "$LOCAL_OUT" != "unchanged" ]; then
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    cp -p "$LOCAL" "$BACKUP_DIR/settings.local.json" 2>/dev/null || true
    if write_atomic "$LOCAL" "$LOCAL_OUT"; then
      echo "removed hooks key from .claude/settings.local.json (permissions and env preserved)"
      CHANGED=1
    else
      echo "restore-hook-settings: could not write .claude/settings.local.json" >&2
      exit 1
    fi
  fi
fi

[ "$CHANGED" -eq 1 ] || true
exit 0
