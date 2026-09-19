#!/bin/bash
# PreToolUse hook: Block commands that dump process environment variables.
# These commands return secrets in their OUTPUT, which bypasses detect-secrets
# (which only scans the command itself).
#
# BLOCKED:
#   docker inspect <container>                        — dumps full config including env vars
#   docker inspect --format '{{json .Config.Env}}'    — explicitly requests env vars
#   docker exec <container> printenv                   — dumps all env vars
#   docker exec <container> env                        — dumps all env vars
#   printenv / env (bare)                              — dumps host env vars
#   env | grep -c / printenv | wc -l                   — dump piped into another command
#   set (no args) / export -p / declare -x             — dump exported/shell vars
#   cat /proc/self/environ                             — dumps process environ
#   cat .env / cat *.env                               — dumps env files with secrets
#   docker exec <container> cat .env                   — dumps env file from container
#
# SAFE (allowed):
#   docker inspect --format '{{.State.Status}}'        — status only
#   printenv PATH                                      — single non-secret var
#   env VAR=x cmd                                      — run with an assignment, not a dump
#   cat somefile.txt                                   — non-env files
#
# Registration: PreToolUse matcher Bash. The body still asserts Bash so a
# misrouted dispatcher cannot apply this guard to other tools.
#
# Exit 2 + short plain stderr. Do not emit JSON via an unquoted heredoc.

set -euo pipefail

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')

if [ "$TOOL" != "Bash" ]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

block() {
  cat >&2 <<'EOF'
BLOCKED: environment dump

Dumping process environment variables leaks secrets into chat output.

Safe alternatives:
  printenv PATH
  env VAR=x cmd
EOF
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "BLOCKED: environment dump" '{decision:"block",reason:$m}' || true
  fi
  exit 2
}

# Flatten newlines so a wrapped dump still matches as one command line.
FLAT=$(printf '%s' "$COMMAND" | tr '\n' ' ')

# --- docker inspect ---
if echo "$FLAT" | grep -qE 'docker inspect'; then
  if echo "$FLAT" | grep -qE -- '--format'; then
    FORMAT_VAL=$(echo "$FLAT" | sed -n 's/.*\(--format[[:space:]]*['"'"'"]*[^'"'"'"]*['"'"'"]*\).*/\1/p' | head -1)
    if echo "$FORMAT_VAL" | grep -qiE '(\.Config\.Env|\.Env|json \.(Config|config))'; then
      cat >&2 <<'EOF'
BLOCKED: docker inspect requesting environment variables

Container env vars contain API keys and secrets that will leak into chat output.

Safe alternatives:
  docker inspect <c> --format '{{.Config.Image}}'
  docker inspect <c> --format '{{.State.Status}}'
EOF
      if command -v jq >/dev/null 2>&1; then
        jq -nc --arg m "BLOCKED: docker inspect requesting environment variables" '{decision:"block",reason:$m}' || true
      fi
      exit 2
    fi
    exit 0
  fi

  cat >&2 <<'EOF'
BLOCKED: docker inspect without --format

Full docker inspect dumps ALL environment variables including API keys.

Always use --format to request specific fields:
  docker inspect <c> --format '{{.Config.Image}}'
  docker inspect <c> --format '{{.State.Status}}'
EOF
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "BLOCKED: docker inspect without --format" '{decision:"block",reason:$m}' || true
  fi
  exit 2
fi

# --- docker exec printenv / env ---
if echo "$FLAT" | grep -qE 'docker exec[[:space:]]+[^[:space:]]+[[:space:]]+(printenv|env)[[:space:]]*$'; then
  cat >&2 <<'EOF'
BLOCKED: docker exec printenv/env (bare)

Dumping all environment variables will leak API keys into chat output.

Safe alternatives:
  docker exec <c> printenv NODE_ENV
  docker exec <c> env | cut -d= -f1
EOF
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "BLOCKED: docker exec printenv/env (bare)" '{decision:"block",reason:$m}' || true
  fi
  exit 2
fi

# --- docker exec cat .env ---
if echo "$FLAT" | grep -qE 'docker exec[[:space:]]+[^[:space:]]+[[:space:]]+cat[[:space:]]+.*\.env'; then
  cat >&2 <<'EOF'
BLOCKED: docker exec cat .env

Dumping .env files from containers will leak secrets into chat output.

Safe alternatives:
  docker exec <c> test -f .env && echo exists
  docker exec <c> wc -l .env
EOF
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "BLOCKED: docker exec cat .env" '{decision:"block",reason:$m}' || true
  fi
  exit 2
fi

# Host dumps: printenv / env with no operand (or only dump flags), including
# when piped into another command. env VAR=x cmd and printenv VAR are allowed.
# A leading path or `command` prefix still counts as the same dump.
DUMP_PREFIX='(^|[[:space:];&|])(command[[:space:]]+)?'

if echo "$FLAT" | grep -qE "${DUMP_PREFIX}(/usr/bin/|/bin/)?printenv([[:space:]]+-[-a-zA-Z0-9]+)*[[:space:]]*($|[;&]|&&|\|\||\|)"; then
  block
fi

if echo "$FLAT" | grep -qE "${DUMP_PREFIX}(/usr/bin/|/bin/)?env([[:space:]]+-[-a-zA-Z0-9]+)*[[:space:]]*($|[;&]|&&|\|\||\|)"; then
  block
fi

# `set` with no args dumps the shell environment.
if echo "$FLAT" | grep -qE "${DUMP_PREFIX}(builtin[[:space:]]+)?set[[:space:]]*($|[;&]|&&|\|\||\|)"; then
  block
fi

# `export -p` dumps exported variables.
if echo "$FLAT" | grep -qE "${DUMP_PREFIX}export[[:space:]]+-p([[:space:]]|$|[;&]|&&|\|\||\|)"; then
  block
fi

# `declare -x` with no assignment dumps exported variables.
if echo "$FLAT" | grep -qE "${DUMP_PREFIX}declare[[:space:]]+-x[[:space:]]*($|[;&]|&&|\|\||\|)"; then
  block
fi

# Linux process environ file.
if echo "$FLAT" | grep -qE '(^|[[:space:];&|])cat[[:space:]]+/proc/(self|[0-9]+)/environ([[:space:]]|$|[;&]|&&|\|\||\|)'; then
  block
fi

# --- cat .env files ---
if echo "$FLAT" | grep -qE '(^|[[:space:];&|])cat[[:space:]]+[^|&;]*\.env\b'; then
  if echo "$FLAT" | grep -qE 'cat[[:space:]]+[^|&;]*\.env.*[|>]'; then
    exit 0
  fi
  cat >&2 <<'EOF'
BLOCKED: cat .env (bare)

Displaying .env files will leak secrets into chat output.

Safe alternatives:
  cat .env | cut -d= -f1
  grep -v 'KEY\|SECRET\|TOKEN\|PASSWORD' .env
EOF
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "BLOCKED: cat .env (bare)" '{decision:"block",reason:$m}' || true
  fi
  exit 2
fi

exit 0
