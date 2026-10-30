#!/usr/bin/env bash
# hqad_iter_settings must not run text from the HQ root path. It used to paste
# HQ_ROOT into each settings.json command and split the result with eval, so an
# install folder named like "hq $(cmd)" or "a`cmd`b" ran cmd every time the
# Codex or Grok adapter dispatched a hook, and a folder with a single quote
# dropped the guard record. (1403 review item 11.)
set -uo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR=.
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
LIB="$ROOT/core/scripts/lib/hook-adapter-core.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
mkdir -p "$BASE/cwd"

FAIL=0
pass() { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

make_root() {
  local root="$1"
  mkdir -p "$root/.claude/hooks"
  printf '#!/bin/bash\nexit 0\n' > "$root/.claude/hooks/hook-gate.sh"
  printf '#!/bin/bash\nexit 0\n' > "$root/.claude/hooks/guard-a.sh"
  cat > "$root/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh\" guard-a \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard-a.sh\""},
          {"type": "command", "command": "env BASH_ENV=/dev/null bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/master-hook.sh\" PreToolUse"}
        ]
      }
    ]
  }
}
JSON
}

check_root() {
  local label="$1" root="$2" out expected
  make_root "$root"
  rm -f "$BASE/cwd/"PWNED*
  out="$(cd "$BASE/cwd" && HQ_ROOT="$root" bash -c '. "$1"; hqad_iter_settings PreToolUse Bash "{}"' _ "$LIB" 2>/dev/null)"
  expected="$(printf 'gate\tguard-a\t%s/.claude/hooks/guard-a.sh' "$root")"
  if compgen -G "$BASE/cwd/PWNED*" >/dev/null; then
    fail "$label: text in the HQ root path ran as a command"
    return
  fi
  case "$out" in
    *"$expected"*) ;;
    *) fail "$label: guard record missing or wrong path: $(printf '%s' "$out" | head -3)"; return ;;
  esac
  case "$out" in
    *"$(printf 'master\tPreToolUse')"*) pass "$label" ;;
    *) fail "$label: master record missing" ;;
  esac
}

check_root 'plain root' "$BASE/plain hq"
check_root 'command substitution in root' "$BASE/hq \$(touch PWNED1) x"
check_root 'backticks in root' "$BASE/hq \`touch PWNED2\` x"
check_root 'semicolon in root' "$BASE/a;touch PWNED3;b"
check_root 'single quote in root' "$BASE/it's hq"
check_root 'ampersand in root' "$BASE/R&D hq"
check_root 'dollar variable in root' "$BASE/hq \$HOME x"

exit "$FAIL"
