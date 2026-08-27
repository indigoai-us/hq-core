#!/usr/bin/env bash
# hq-core: public
# 30-ensure-hq-cli.sh — UserPromptSubmit hook.
#
# Ensures the `hq` CLI is installed AND reachable on the PATH that Claude Code
# actually runs under — i.e. `env.PATH` in .claude/settings.local.json (falling
# back to .claude/settings.json). Reading that same value (rather than the
# ambient shell PATH) is what keeps the check honest: a binary on the login
# shell's PATH is useless if it is not on the PATH the harness injects.
#
# On every prompt:
#   * a current, working hq resolves on PATH   -> fully silent no-op (common case).
#   * hq resolves but is broken or too old     -> treat it as missing and repair.
#   * hq is installed but NOT on that PATH     -> append its dir to env.PATH in
#                                                 settings.local.json (auto-fix).
#   * hq is missing entirely                   -> bounded, once-per-cooldown
#                                                 `npm install -g @indigoai-us/hq-cli`,
#                                                 then auto-fix the PATH as above.
#   * cannot install / cannot write settings   -> inject a context line telling
#                                                 the user how to install it and/or
#                                                 add it to env.PATH themselves.
#
# The auto-fix only ever writes settings.local.json (machine-local, gitignored).
# settings.json is a GENERATED file and is never modified.
#
# Contract:
#   * Advisory only — ALWAYS exits 0 (fail-soft); never blocks the prompt.
#   * The npm install is bounded by `timeout` and gated by a cooldown stamp so a
#     persistently-broken environment never re-runs npm on every prompt. The
#     cheap auto-fix (a JSON edit) is NOT cooldown-gated — it self-heals to
#     silence on the next prompt once the settings PATH includes hq.
#   * stdout is added to the model's context by Claude Code, so anything printed
#     is deliberate, tagged context. Silence = print nothing.
#
# bash-3.2 compatible.
#
# Kill switches: HQ_NO_ENSURE_HQ_CLI=1, or HQ_DISABLED_HOOKS=...,ensure-hq-cli,...
# Test seams: HQ_ROOT, HQ_ENSURE_CLI_INSTALL_CMD, HQ_ENSURE_CLI_COOLDOWN,
#             HQ_ENSURE_CLI_TIMEOUT.

set -uo pipefail
trap 'exit 0' EXIT

# Consume stdin (master-hook always pipes the event JSON, even if unused).
cat >/dev/null 2>&1 || true

# --- kill switches --------------------------------------------------------
case "${HQ_NO_ENSURE_HQ_CLI:-}" in
  1|true|TRUE|yes|YES|on|ON) exit 0 ;;
esac
case ",${HQ_DISABLED_HOOKS:-}," in
  *,ensure-hq-cli,*) exit 0 ;;
esac

# --- root + settings bootstrap -------------------------------------------
# This file lives at <HQ>/core/hooks/UserPromptSubmit/, so the HQ root is THREE
# parents up — not two. Prefer an explicit HQ_ROOT, then CLAUDE_PROJECT_DIR
# (which Claude Code sets to the HQ root), then the path walk. Getting this wrong
# points every path below (settings files, cooldown stamp) at <HQ>/core, which
# is release-managed scaffold and has no .claude settings — silently breaking
# the whole feature.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$HOOK_DIR/../../.." 2>/dev/null && pwd)}}"
[ -n "$HQ_ROOT" ] || exit 0

CLAUDE_DIR="$HQ_ROOT/.claude"
LOCAL_SETTINGS="$CLAUDE_DIR/settings.local.json"
BASE_SETTINGS="$CLAUDE_DIR/settings.json"

STAMP_DIR="$HQ_ROOT/workspace/.hq-cli-ensure"
STAMP="$STAMP_DIR/last-attempt.stamp"

INSTALL_CMD="${HQ_ENSURE_CLI_INSTALL_CMD:-npm install -g @indigoai-us/hq-cli@latest}"
COOLDOWN="${HQ_ENSURE_CLI_COOLDOWN:-21600}"   # 6h between install attempts
INSTALL_TIMEOUT="${HQ_ENSURE_CLI_TIMEOUT:-120}"
VERSION_TIMEOUT="${HQ_ENSURE_CLI_VERSION_TIMEOUT:-3}"
MIN_VERSION="${HQ_ENSURE_CLI_MIN_VERSION:-5.103.26}"

have_jq() { command -v jq >/dev/null 2>&1; }

# --- read the PATH Claude Code runs under (settings.local wins) -----------
settings_path() {
  local p=""
  if have_jq && [ -f "$LOCAL_SETTINGS" ]; then
    p="$(jq -r '.env.PATH // empty' "$LOCAL_SETTINGS" 2>/dev/null)" || p=""
  fi
  if [ -z "$p" ] && have_jq && [ -f "$BASE_SETTINGS" ]; then
    p="$(jq -r '.env.PATH // empty' "$BASE_SETTINGS" 2>/dev/null)" || p=""
  fi
  printf '%s' "$p"
}

settings_path_is_local() {
  have_jq && [ -f "$LOCAL_SETTINGS" ] &&
    [ -n "$(jq -r '.env.PATH // empty' "$LOCAL_SETTINGS" 2>/dev/null)" ]
}

version_at_least() {
  local actual="$1" required="$2" a1 a2 a3 r1 r2 r3 oldifs
  oldifs="$IFS"; IFS='.'
  set -- $actual; a1="${1:-0}"; a2="${2:-0}"; a3="${3:-0}"
  set -- $required; r1="${1:-0}"; r2="${2:-0}"; r3="${3:-0}"
  IFS="$oldifs"
  [ "$a1" -gt "$r1" ] && return 0
  [ "$a1" -lt "$r1" ] && return 1
  [ "$a2" -gt "$r2" ] && return 0
  [ "$a2" -lt "$r2" ] && return 1
  [ "$a3" -ge "$r3" ]
}

stop_watchdog() {
  local watchdog_pid="$1"
  if command -v pkill >/dev/null 2>&1; then
    pkill -P "$watchdog_pid" 2>/dev/null || true
  fi
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
}

capture_hq_version_bounded() {
  local binary="$1" output_file cmd_pid watchdog_pid rc=0
  output_file="${TMPDIR:-/tmp}/hq-cli-version.$$.out"
  rm -f "$output_file" 2>/dev/null || true
  HQ_NO_UPDATE_CHECK=1 "$binary" --version >"$output_file" 2>/dev/null &
  cmd_pid=$!
  ( sleep "$VERSION_TIMEOUT" 2>/dev/null; kill "$cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
  watchdog_pid=$!
  wait "$cmd_pid" 2>/dev/null || rc=$?
  stop_watchdog "$watchdog_pid"
  if [ "$rc" -eq 0 ]; then
    cat "$output_file" 2>/dev/null || rc=1
  fi
  rm -f "$output_file" 2>/dev/null || true
  return "$rc"
}

hq_binary_usable() {
  local binary="$1" output version
  [ -x "$binary" ] || return 1
  output="$(capture_hq_version_bounded "$binary")" || return 1
  version="$(printf '%s' "$output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [ -n "$version" ] || return 1
  version_at_least "$version" "$MIN_VERSION"
}

# Is the independently discovered, sufficiently-current `hq` on the settings
# PATH? Never execute a binary merely because a repo-controlled settings file
# names its directory.
hq_in_path() {
  local sp="$1" allow_configured="${2:-0}" d oldifs trusted_dir=""
  [ -n "$sp" ] || return 1
  if [ "$allow_configured" != "1" ]; then
    trusted_dir="$(locate_hq_dir)" || return 1
  fi
  oldifs="$IFS"; IFS=':'
  for d in $sp; do
    IFS="$oldifs"
    if [ -n "$d" ]; then
      if [ "$allow_configured" = "1" ] && hq_binary_usable "$d/hq"; then
        return 0
      fi
      if [ -n "$trusted_dir" ] && [ "$d" = "$trusted_dir" ]; then return 0; fi
    fi
    IFS=':'
  done
  IFS="$oldifs"
  return 1
}

# npm's global bin dir (where `npm i -g` lands binaries), without assuming PATH.
npm_global_bin() {
  command -v npm >/dev/null 2>&1 || return 1
  local prefix
  prefix="$(npm config get prefix 2>/dev/null)" || return 1
  [ -n "$prefix" ] && [ "$prefix" != "undefined" ] || return 1
  if [ -d "$prefix/bin" ]; then printf '%s\n' "$prefix/bin"; else printf '%s\n' "$prefix"; fi
}

# Locate a dir that actually contains an `hq` binary: ambient PATH first, then
# npm's global bin. Prints the dir (no trailing binary) or nothing.
locate_hq_dir() {
  local hqpath bin candidate
  hqpath="$(command -v hq 2>/dev/null)" || hqpath=""
  if [ -n "$hqpath" ] && hq_binary_usable "$hqpath"; then dirname "$hqpath"; return 0; fi
  bin="$(npm_global_bin)" || bin=""
  if [ -n "$bin" ] && hq_binary_usable "$bin/hq"; then printf '%s\n' "$bin"; return 0; fi
  candidate="${HOME:-}/.local/bin/hq"
  if [ -n "${HOME:-}" ] && hq_binary_usable "$candidate"; then
    printf '%s\n' "${HOME}/.local/bin"
    return 0
  fi
  return 1
}

# Append $1 to env.PATH in settings.local.json (never settings.json). Seeds the
# local PATH from the resolved settings PATH (arg $2), then the ambient PATH.
# Returns 0 on a successful (or already-present) write, 1 if it could not write.
add_dir_to_settings_path() {
  local dir="$1" sp="$2" basep tmp
  have_jq || return 1
  [ -n "$dir" ] || return 1
  mkdir -p "$CLAUDE_DIR" 2>/dev/null || true
  [ -d "$CLAUDE_DIR" ] && [ -w "$CLAUDE_DIR" ] || return 1
  if [ ! -f "$LOCAL_SETTINGS" ]; then
    ( printf '{}\n' > "$LOCAL_SETTINGS" ) 2>/dev/null || return 1
  fi
  basep="$(jq -r '.env.PATH // empty' "$LOCAL_SETTINGS" 2>/dev/null)" || basep=""
  [ -n "$basep" ] || basep="$sp"
  [ -n "$basep" ] || basep="${PATH:-}"
  # Already present -> nothing to do (idempotent success).
  case ":$basep:" in
    *":$dir:"*) return 0 ;;
  esac
  local newp
  if [ -n "$basep" ]; then newp="$dir:$basep"; else newp="$dir"; fi
  tmp="$LOCAL_SETTINGS.tmp.$$"
  if ( jq --arg p "$newp" '.env = ((.env // {}) + {PATH: $p})' "$LOCAL_SETTINGS" > "$tmp" ) 2>/dev/null; then
    mv "$tmp" "$LOCAL_SETTINGS" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

emit_path_updated() { # $1=dir  $2=installed(1/0)
  local dir="$1" installed="$2" lead
  if [ "$installed" = "1" ]; then
    lead="The \`hq\` CLI was not found, so HQ installed it (npm install -g @indigoai-us/hq-cli) at \`$dir/hq\`."
  else
    lead="The \`hq\` CLI at \`$dir/hq\` was not on the PATH Claude Code uses."
  fi
  cat <<EOF
<hq-cli-path-updated>
$lead
HQ added \`$dir\` to \`env.PATH\` in .claude/settings.local.json, so it will
resolve automatically in new sessions. To use it in THIS session immediately:

  export PATH="$dir:\$PATH"
</hq-cli-path-updated>
EOF
}

emit_needs_path() { # $1=dir
  local dir="$1"
  cat <<EOF
<hq-cli-not-on-path>
The \`hq\` CLI is installed at \`$dir/hq\` but is not on the PATH Claude Code
uses, and HQ could not update the settings automatically. Add \`$dir\` to
\`env.PATH\` in .claude/settings.local.json, and for this shell run:

  export PATH="$dir:\$PATH"
</hq-cli-not-on-path>
EOF
}

emit_manual_install() {
  cat <<'EOF'
<hq-cli-missing>
The `hq` CLI is not installed and HQ could not install it automatically.
Install it manually:

  npm install -g @indigoai-us/hq-cli@latest

Then make sure it is reachable by Claude Code: add npm's global bin directory
(find it with `npm config get prefix` — the binary lives in `<prefix>/bin`) to
`env.PATH` in .claude/settings.local.json, and to your shell for this session:

  export PATH="$(npm config get prefix)/bin:$PATH"

HQ CLI-backed features stay unavailable until `hq` resolves on that PATH.
</hq-cli-missing>
EOF
}

# Run shell command string $2 bounded to $1 seconds. Portable stand-in for
# `timeout`, which is NOT installed by default on macOS — without this the
# no-`timeout` branch would run npm unbounded and could hang the prompt until
# the master hook's own (much longer) ceiling. Backgrounds the command and a
# killer; whichever finishes first wins and the other is reaped. Always 0.
run_bounded() {
  local secs="$1" cmd="$2" cmd_pid killer_pid
  sh -c "$cmd" >/dev/null 2>&1 &
  cmd_pid=$!
  ( sleep "$secs" 2>/dev/null; kill "$cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
  killer_pid=$!
  wait "$cmd_pid" 2>/dev/null
  stop_watchdog "$killer_pid"
  return 0
}

# --- 1. already reachable on the settings PATH -> silent -----------------
SP="$(settings_path)"
if [ -n "$SP" ]; then
  SP_LOCAL=0
  settings_path_is_local && SP_LOCAL=1
  if hq_in_path "$SP" "$SP_LOCAL"; then
    [ -f "$STAMP" ] && rm -f "$STAMP" 2>/dev/null || true
    exit 0
  fi
else
  # No configured PATH to read — fall back to the ambient one.
  AMBIENT_HQ="$(command -v hq 2>/dev/null || true)"
  if [ -n "$AMBIENT_HQ" ] && hq_binary_usable "$AMBIENT_HQ"; then
    [ -f "$STAMP" ] && rm -f "$STAMP" 2>/dev/null || true
    exit 0
  fi
fi

# --- 2. hq exists somewhere, just not on the settings PATH -> auto-fix ----
HQ_DIR="$(locate_hq_dir)" || HQ_DIR=""
if [ -n "$HQ_DIR" ]; then
  if add_dir_to_settings_path "$HQ_DIR" "$SP"; then
    rm -f "$STAMP" 2>/dev/null || true
    emit_path_updated "$HQ_DIR" 0
  else
    emit_needs_path "$HQ_DIR"
  fi
  exit 0
fi

# --- 3. hq missing entirely -> bounded, once-per-cooldown install ---------
if [ -f "$STAMP" ]; then
  STAMP_MTIME="$(stat -c %Y "$STAMP" 2>/dev/null || stat -f %m "$STAMP" 2>/dev/null || echo 0)"
  NOW="$(date +%s 2>/dev/null || echo 0)"
  if [ "$NOW" -gt 0 ] && [ "$((NOW - STAMP_MTIME))" -lt "$COOLDOWN" ]; then
    # Still missing, but do not hammer npm — keep surfacing the remedy.
    emit_manual_install
    exit 0
  fi
fi

mkdir -p "$STAMP_DIR" 2>/dev/null || true

# Atomic claim (mkdir is atomic): only one concurrent session runs the global
# install; a loser — two first-prompts racing while hq is absent — takes the
# remedy path instead of contending over the shared global npm prefix. The lock
# is released on ANY exit via the trap below, so a crashed installer cannot
# deadlock later attempts (which a bare timestamp stamp could not guarantee).
LOCK_DIR="$STAMP_DIR/installing.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  emit_manual_install
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null; exit 0' EXIT
: > "$STAMP" 2>/dev/null || true

if ! command -v npm >/dev/null 2>&1; then
  emit_manual_install
  exit 0
fi

# Bound the install so a stalled npm cannot hang the prompt. `timeout` is absent
# on stock macOS, so fall back to the portable watchdog above.
if command -v timeout >/dev/null 2>&1; then
  timeout "$INSTALL_TIMEOUT" sh -c "$INSTALL_CMD" >/dev/null 2>&1 || true
else
  run_bounded "$INSTALL_TIMEOUT" "$INSTALL_CMD" || true
fi

# PATH may cache the old lookup within this shell.
hash -r 2>/dev/null || true

HQ_DIR="$(locate_hq_dir)" || HQ_DIR=""
if [ -n "$HQ_DIR" ]; then
  rm -f "$STAMP" 2>/dev/null || true
  if add_dir_to_settings_path "$HQ_DIR" "$SP"; then
    emit_path_updated "$HQ_DIR" 1
  else
    emit_needs_path "$HQ_DIR"
  fi
  exit 0
fi

# Install command ran but hq is still nowhere to be found.
emit_manual_install
exit 0
