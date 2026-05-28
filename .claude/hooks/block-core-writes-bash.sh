#!/bin/bash
# block-core-writes-bash.sh — PreToolUse hook for Bash.
#
# Companion to block-core-writes.sh. Scans Bash command text and rejects
# high-confidence direct writes into core/ or .claude/ (except
# .claude/settings.local.json).
#
# Bypass: HQ_BYPASS_CORE_PROTECT must be set to "1" under "env" in
# .claude/settings.local.json. Inline env-var prefixes are NOT accepted.
#
# This is best-effort — exhaustive shell-command analysis is intractable.
# Exit codes: 0 = allow, 2 = block.

set -uo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || true
[[ -z "$CMD" ]] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
if command -v python3 >/dev/null 2>&1; then
  PROJECT_DIR="$(python3 -c 'import os.path,sys; sys.stdout.write(os.path.normpath(sys.argv[1]))' "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")"
fi

SETTINGS_LOCAL="$PROJECT_DIR/.claude/settings.local.json"

# Bypass: must be declared in .claude/settings.local.json env section.
is_bypass_authorized() {
  [[ -f "$SETTINGS_LOCAL" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local val
  val=$(jq -r '.env.HQ_BYPASS_CORE_PROTECT // empty' "$SETTINGS_LOCAL" 2>/dev/null) || return 1
  [[ "$val" == "1" || "$val" == "true" ]] && return 0
  return 1
}

if is_bypass_authorized; then
  exit 0
fi

# Build absolute path prefixes.
CORE_ABS="$PROJECT_DIR/core/"
CLAUDE_ABS="$PROJECT_DIR/.claude/"
AGENTS_ABS="$PROJECT_DIR/.agents/"
CODEX_ABS="$PROJECT_DIR/.codex/"
OBSIDIAN_ABS="$PROJECT_DIR/.obsidian/"

esc() { printf '%s' "$1" | sed 's/[][\\.*^$(){}?+|/]/\\&/g'; }
CORE_ABS_ESC="$(esc "$CORE_ABS")"
CLAUDE_ABS_ESC="$(esc "$CLAUDE_ABS")"
AGENTS_ABS_ESC="$(esc "$AGENTS_ABS")"
CODEX_ABS_ESC="$(esc "$CODEX_ABS")"
OBSIDIAN_ABS_ESC="$(esc "$OBSIDIAN_ABS")"

# Per-dir path alternation patterns (relative + env-var + absolute).
CORE_PATH_ALTS='((\./)?core/|\$\{?CLAUDE_PROJECT_DIR\}?/core/|\$\{?REPO_ROOT\}?/core/|\$\{?HQ_ROOT\}?/core/|'"$CORE_ABS_ESC"')'
CLAUDE_PATH_ALTS='((\./)?\.claude/|\$\{?CLAUDE_PROJECT_DIR\}?/\.claude/|\$\{?REPO_ROOT\}?/\.claude/|\$\{?HQ_ROOT\}?/\.claude/|'"$CLAUDE_ABS_ESC"')'
AGENTS_PATH_ALTS='((\./)?\.agents/|\$\{?CLAUDE_PROJECT_DIR\}?/\.agents/|\$\{?REPO_ROOT\}?/\.agents/|\$\{?HQ_ROOT\}?/\.agents/|'"$AGENTS_ABS_ESC"')'
CODEX_PATH_ALTS='((\./)?\.codex/|\$\{?CLAUDE_PROJECT_DIR\}?/\.codex/|\$\{?REPO_ROOT\}?/\.codex/|\$\{?HQ_ROOT\}?/\.codex/|'"$CODEX_ABS_ESC"')'
OBSIDIAN_PATH_ALTS='((\./)?\.obsidian/|\$\{?CLAUDE_PROJECT_DIR\}?/\.obsidian/|\$\{?REPO_ROOT\}?/\.obsidian/|\$\{?HQ_ROOT\}?/\.obsidian/|'"$OBSIDIAN_ABS_ESC"')'

PROTECTED_PATH_ALTS="($CORE_PATH_ALTS|$CLAUDE_PATH_ALTS|$AGENTS_PATH_ALTS|$CODEX_PATH_ALTS|$OBSIDIAN_PATH_ALTS)"
PROTECTED_TOKEN_RE='(^|[[:space:]]|[;|&(]|["'\''])'"$PROTECTED_PATH_ALTS"
AGENTS_MD_TOKEN_RE='(^|[[:space:]]|[;|&(]|["'\''])AGENTS\.md'

WRITE_OPS='(^|[[:space:]])(rm|rmdir|cp|mv|mkdir|touch|chmod|chown|chgrp|tee|dd|rsync|sed[[:space:]]+-i|sed[[:space:]]+--in-place|awk[[:space:]]+-i[[:space:]]+inplace|ln)([[:space:]]|$)'

writes_to_protected() {
  local cmd="$1"
  # Strip settings.local.json refs — that file is the allowed exception inside .claude/.
  local stripped
  stripped=$(echo "$cmd" | sed 's|[^[:space:]]*settings\.local\.json[^[:space:]]*||g; s|settings\.local\.json||g')
  # Redirect (>) or append (>>) into any protected dir.
  if echo "$stripped" | grep -Eq '(^|[[:space:]])>{1,2}[[:space:]]*["'\'']?'"$PROTECTED_PATH_ALTS"; then
    return 0
  fi
  # Write-op tool + protected path token.
  if echo "$stripped" | grep -Eq "$WRITE_OPS" && echo "$stripped" | grep -Eq "$PROTECTED_TOKEN_RE"; then
    return 0
  fi
  # AGENTS.md (single file — no settings.local.json stripping needed).
  if echo "$cmd" | grep -Eq '(^|[[:space:]])>{1,2}[[:space:]]*["'\'']?AGENTS\.md'; then
    return 0
  fi
  if echo "$cmd" | grep -Eq "$WRITE_OPS" && echo "$cmd" | grep -Eq "$AGENTS_MD_TOKEN_RE"; then
    return 0
  fi
  return 1
}

if writes_to_protected "$CMD"; then
  cat >&2 <<EOF
BLOCKED: Bash command appears to write into protected scaffold paths.
  Command: $CMD

Protected: core/, .claude/, .agents/, .codex/, .obsidian/, AGENTS.md
Exception: .claude/settings.local.json is always writable.

To bypass: set "HQ_BYPASS_CORE_PROTECT": "1" under "env" in .claude/settings.local.json
(inline env-var prefixes are not accepted).

If this block is wrong or surprising, report it with /hq-bug.
EOF
  exit 2
fi

exit 0
