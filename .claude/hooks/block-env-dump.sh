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
#   env > file / printenv >> file / env 2>/dev/null    — dump redirected to disk
#   env | tee file / $(env) / `env` / (env)            — dump captured or tee'd
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

# Host dumps: printenv / env with no operand (or only dump flags). The dump is
# blocked regardless of what follows it: end of command, `;`, `&`, a pipe, a
# redirect into a file (`>`, `>>`, `2>`, `&>`), a closing `)` of a
# subshell or `$(...)`, or a closing backtick. Writing the dump to disk is worse
# than printing it (the file can be read back in pieces through paths this
# hook never inspects), so redirects are dumps too (feedback_ca842a26).
# env VAR=x cmd and printenv VAR are allowed. A leading path, `command`
# prefix, `$(`, `(`, or backtick still counts as the same dump.
DUMP_PREFIX='(^|[[:space:];&|])(command[[:space:]]+)?'
# What may follow the dump command for it to still be a dump. A closing `)`
# or backtick is NOT in this list: prose such as "(dev env)" or "identity set)"
# inside a commit message or heredoc must not trip the guard. Captures are
# matched separately below, where the opener must sit directly before the
# dump word.
DUMP_END='($|[;&|]|&&|\|\||[0-9]?>>?|&>)'
# Capture shapes: `$(env)`, `` `env` ``, `(env)` at command position. The
# opener is immediately followed by the dump word (spaces allowed), so
# "(dev env)" and "(identity set)" are not matched.
CAPTURE_OPEN='(\$\(|`|(^|[[:space:];&|])\()[[:space:]]*(command[[:space:]]+)?(/usr/bin/|/bin/)?'
CAPTURE_CLOSE='([[:space:]]+-[-a-zA-Z0-9]+)*[[:space:]]*(\)|`)'

# Operands of a text-search command are patterns or file names, not commands.
# `ads create:preview | grep env` or `... | grep -i set` searches for a word
# and dumps nothing (feedback_2a6a39c7). Drop each search command and its plain
# operands from the text the env/printenv/set checks read. The operand run stops
# at `;`, `&`, `|`, a parenthesis, a backtick or `$`, so a dump elsewhere in the
# same line (a later `; env`, or a `$(env)` / backtick capture used as a grep
# operand) is still seen. A quoted operand is one word whatever it holds, so a
# pattern like "stripe|env|secret" or 'token|set' is dropped whole instead of
# being cut at its `|` (feedback a6435e4f). A double-quoted operand that holds
# `$` or a backtick is not dropped, so "$(env)" stays visible. A backslash
# takes the next character with it, unquoted or inside double quotes, so an
# escaped quote (`grep a\"b; env; echo \"`) cannot open a fake quoted operand
# that would swallow the `; env;` between it and a later quote.
SEARCH_OPERAND="([^;&|()\`\$'\"\\\\]|\\\\.|'[^']*'|\"([^\"\`\$\\\\]|\\\\.)*\")"
SEARCH_CMD='(^|[;&|(]|\$\()[[:space:]]*(command[[:space:]]+)?([^[:space:];&|()`$]*/)?(grep|egrep|fgrep|zgrep|rg|ag|ack)([[:space:]]+'"${SEARCH_OPERAND}"'*)?'
SCAN=$(printf '%s' "$FLAT" | sed -E "s#${SEARCH_CMD}#\\1 #g")

if echo "$SCAN" | grep -qE "${CAPTURE_OPEN}(printenv|env|set)${CAPTURE_CLOSE}"; then
  block
fi

if echo "$SCAN" | grep -qE "${DUMP_PREFIX}(/usr/bin/|/bin/)?printenv([[:space:]]+-[-a-zA-Z0-9]+)*[[:space:]]*${DUMP_END}"; then
  block
fi

if echo "$SCAN" | grep -qE "${DUMP_PREFIX}(/usr/bin/|/bin/)?env([[:space:]]+-[-a-zA-Z0-9]+)*[[:space:]]*${DUMP_END}"; then
  block
fi

# `set` with no args dumps the shell environment.
if echo "$SCAN" | grep -qE "${DUMP_PREFIX}(builtin[[:space:]]+)?set[[:space:]]*${DUMP_END}"; then
  block
fi

# `export -p` dumps exported variables.
if echo "$FLAT" | grep -qE "${DUMP_PREFIX}export[[:space:]]+-p([[:space:]]*${DUMP_END}|[[:space:]])"; then
  block
fi

# `declare -x` with no assignment dumps exported variables.
if echo "$FLAT" | grep -qE "${DUMP_PREFIX}declare[[:space:]]+-x[[:space:]]*${DUMP_END}"; then
  block
fi

# Linux process environ file.
if echo "$FLAT" | grep -qE "${DUMP_PREFIX}cat[[:space:]]+/proc/(self|[0-9]+)/environ([[:space:]]*${DUMP_END}|[[:space:]])"; then
  block
fi

# --- cat .env files ---
# A document whose name only contains `.env` (a policy such as aws.env.md, a
# notes.env.txt) is prose, not an env file (feedback a6435e4f). Drop words that
# end in a document extension after `.env` before the check. `.env`,
# `.env.local`, `prod.env` and the like are still matched. Only a whole word
# of plain file-name characters is dropped: `.env$IFS.md` expands to `.env`
# plus another word, so a word with `$`, a quote or a backslash is kept.
CAT_SCAN=$(printf '%s' "$FLAT" | sed -E 's#(^|[[:space:];&|<>(])[A-Za-z0-9_./@+-]*\.env[A-Za-z0-9_./@+-]*\.(md|mdx|markdown|txt|rst)([[:space:];&|)<>]|$)#\1\3#g')
if echo "$CAT_SCAN" | grep -qE '(^|[[:space:];&|])cat[[:space:]]+[^|&;]*\.env\b'; then
  if echo "$CAT_SCAN" | grep -qE 'cat[[:space:]]+[^|&;]*\.env.*[|>]'; then
    exit 0
  fi
  cat >&2 <<'EOF'
BLOCKED: cat .env (bare)

Displaying .env files will leak secrets into chat output.

Safe alternatives (key names or counts only, never values):
  cut -d= -f1 .env
  grep -c . .env
Filtering values out with grep -v is not safe: it is case-sensitive and
misses key shapes such as _authToken.
EOF
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "BLOCKED: cat .env (bare)" '{decision:"block",reason:$m}' || true
  fi
  exit 2
fi

exit 0
