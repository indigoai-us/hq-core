#!/bin/bash
# block-core-writes-bash.sh — PreToolUse hook for Bash.
#
# Companion to block-core-writes.sh. The file-based hook only fires on
# Edit/Write/MultiEdit; Bash commands like `echo x > core/foo`, `sed -i`,
# `cp/mv/rm/mkdir/touch ... core/`, `tee core/`, or `ln -s ... core/` would
# otherwise bypass the rule. This hook scans the Bash command text and
# rejects high-confidence direct writes into `core/`.
#
# This is best-effort — exhaustive shell-command analysis is intractable.
# Writes that fall outside the detected patterns (e.g. Python/Node scripts,
# obscure tools) will not be caught here, but those paths are also less
# common in agent transcripts. The catch-all is `HQ_BYPASS_CORE_PROTECT=1`,
# either as a shell-prefix on the command itself or in the hook environment.
#
# Exit codes: 0 = allow, 2 = block.

set -uo pipefail

if [[ "${HQ_BYPASS_CORE_PROTECT:-}" == "1" ]]; then
  cat >/dev/null
  exit 0
fi

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || true
[[ -z "$CMD" ]] && exit 0

# Inline bypass: writers can prefix the command with HQ_BYPASS_CORE_PROTECT=1
# (e.g. for writes that ultimately land through a master-sync symlink).
if echo "$CMD" | grep -Eq '(^|[[:space:]])HQ_BYPASS_CORE_PROTECT=1\b'; then
  exit 0
fi

# Compute the absolute core/ prefix from CLAUDE_PROJECT_DIR so that fully
# expanded paths (e.g. `cat > /workspace/hq-core-staging/core/foo`) are
# caught alongside the literal `$CLAUDE_PROJECT_DIR/core/` form. Lexically
# normalized via python3 when available; ERE-escaped for safe interpolation.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
if command -v python3 >/dev/null 2>&1; then
  PROJECT_DIR="$(python3 -c 'import os.path,sys; sys.stdout.write(os.path.normpath(sys.argv[1]))' "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")"
fi
CORE_ABS="$PROJECT_DIR/core/"
CORE_ABS_ESC="$(printf '%s' "$CORE_ABS" | sed 's/[][\\.*^$(){}?+|/]/\\&/g')"

# Path alternation: relative `core/` and `./core/`, common $VAR forms agents
# write literally, and the absolute prefix derived from CLAUDE_PROJECT_DIR.
CORE_PATH_ALTS='((\./)?core/|\$\{?CLAUDE_PROJECT_DIR\}?/core/|\$\{?REPO_ROOT\}?/core/|\$\{?HQ_ROOT\}?/core/|'"$CORE_ABS_ESC"')'

# Match a CORE_PATH_ALTS occurrence preceded by a token boundary.
CORE_TOKEN_RE='(^|[[:space:]]|[;|&(]|["'\''])'"$CORE_PATH_ALTS"

writes_to_core() {
  local cmd="$1"

  # `> core/...` / `>> core/...` redirects (works for any preceding command).
  # Optional surrounding quote on the target is accepted.
  if echo "$cmd" | grep -Eq '(^|[[:space:]])>{1,2}[[:space:]]*["'\'']?'"$CORE_PATH_ALTS"; then
    return 0
  fi

  # Destructive-write tokens paired with a core/ argument anywhere.
  if echo "$cmd" \
       | grep -Eq '(^|[[:space:]])(rm|rmdir|cp|mv|mkdir|touch|chmod|chown|chgrp|tee|dd|rsync|sed[[:space:]]+-i|sed[[:space:]]+--in-place|awk[[:space:]]+-i[[:space:]]+inplace|ln)([[:space:]]|$)'; then
    if echo "$cmd" | grep -Eq "$CORE_TOKEN_RE"; then
      return 0
    fi
  fi

  return 1
}

if writes_to_core "$CMD"; then
  cat >&2 <<EOF
BLOCKED: Bash command appears to write into core/.
  Command: $CMD

core/ is a generated mirror. Edit the corresponding file under personal/ and
master-sync will symlink it into core/ automatically.

If you genuinely need to write into core/ (e.g. an authorized core update or
a write that lands through an existing master-sync symlink), either prefix
the command with HQ_BYPASS_CORE_PROTECT=1, or set HQ_BYPASS_CORE_PROTECT=1
in the hook environment.

If this block is wrong or surprising, report it with /hq-bug (wraps
\`hq feedback\`).
EOF
  exit 2
fi

exit 0
