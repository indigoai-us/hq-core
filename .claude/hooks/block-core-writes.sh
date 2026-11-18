#!/bin/bash
# block-core-writes.sh — PreToolUse hook for Edit, Write, MultiEdit.
#
# Blocks any write inside core/ or .claude/. Authoring belongs in personal/,
# which is read DIRECTLY from personal/<type>/<entry> (the reindex symlink
# mirror into core/ was retired). A write that still resolves through a leftover
# personal→core mirror symlink is allowed (it lands in personal/).
#
# Exceptions: .claude/settings.local.json and .claude/personal-context.md are
# always allowed. The latter is the update-preserved native personal-context
# import, so it must remain editable even in hook-enabled CLI sessions.
#
# Bypass: HQ_BYPASS_CORE_PROTECT="1" under "env" in .claude/settings.local.json.
# Enabling it disables protection for every later write, so an agent must NEVER
# set it autonomously — the block message tells it to ask the user first.
# Inline env-var prefixes are NOT accepted.
#
# Exit codes: 0 = allow, 2 = block.

set -uo pipefail

INPUT=$(cat)

# jq may emit a completed value before a malformed tail fails. Never use
# partial output from a failed parse, including jq version-specific literals.
if ! FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null); then
  printf '%s\n' 'BLOCKED: hook input is not cleanly parseable JSON.' >&2
  exit 2
fi
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"

if ! hq_path_is_absolute "$FILE_PATH"; then
  FILE_PATH="$PROJECT_DIR/$FILE_PATH"
fi

FILE_PATH="$(hq_canonical_path "$FILE_PATH")"
PROJECT_DIR="$(hq_canonical_path "$PROJECT_DIR")"

# On Windows a folder can be named by its long name or its 8.3 short name
# (C:/Users/RUNNER~1 and C:/Users/runneradmin). Each path that holds a short
# name ("~") is rewritten in long form, so the protected-path checks below
# compare like with like (US-022); a path with no "~" is already long. The
# longest existing prefix is expanded and a not-yet-existing tail is kept as
# written. If the lookup fails for a "~" path, the write is refused: its
# spelling cannot be matched safely. Only Git Bash has cygpath; no other
# platform runs this.
bcw_long() {
  local head="$1" tail="" parent q
  while [[ -n "$head" && ! -e "$head" ]]; do
    parent="${head%/*}"
    if [[ -z "$parent" || "$parent" == "$head" ]]; then
      return 1
    fi
    tail="/${head##*/}$tail"
    head="$parent"
  done
  q="$(cygpath -m -l "$head" 2>/dev/null)" || return 1
  [[ -n "$q" ]] || return 1
  printf '%s%s' "$q" "$tail"
}
bcw_refuse_unresolved() {
  printf 'BLOCKED: could not resolve the Windows short (8.3) name in %s, so the protected-path check cannot be trusted.\n' "$1" >&2
  exit 2
}
if command -v cygpath >/dev/null 2>&1; then
  if [[ "$FILE_PATH" == *"~"* ]]; then
    bcw_long_value="$(bcw_long "$FILE_PATH")" || bcw_refuse_unresolved "$FILE_PATH"
    FILE_PATH="$bcw_long_value"
  fi
  if [[ "$PROJECT_DIR" == *"~"* ]]; then
    bcw_long_value="$(bcw_long "$PROJECT_DIR")" || bcw_refuse_unresolved "$PROJECT_DIR"
    PROJECT_DIR="$bcw_long_value"
  fi
  # Windows file systems ignore letter case (C:/HQ/CORE is C:/hq/core), so on
  # Git Bash every path comparison below is case-insensitive (US-022).
  shopt -s nocasematch
fi

CORE_DIR="$PROJECT_DIR/core"
CLAUDE_DIR="$PROJECT_DIR/.claude"
AGENTS_DIR="$PROJECT_DIR/.agents"
CODEX_DIR="$PROJECT_DIR/.codex"
OBSIDIAN_DIR="$PROJECT_DIR/.obsidian"
AGENTS_MD="$PROJECT_DIR/AGENTS.md"
SETTINGS_LOCAL="$(hq_canonical_path "$PROJECT_DIR/.claude/settings.local.json")"
PERSONAL_CONTEXT="$(hq_canonical_path "$PROJECT_DIR/.claude/personal-context.md")"

# Only concerned with protected paths.
case "$FILE_PATH" in
  "$CORE_DIR"|"$CORE_DIR"/*|\
  "$CLAUDE_DIR"|"$CLAUDE_DIR"/*|\
  "$AGENTS_DIR"|"$AGENTS_DIR"/*|\
  "$CODEX_DIR"|"$CODEX_DIR"/*|\
  "$OBSIDIAN_DIR"|"$OBSIDIAN_DIR"/*|\
  "$AGENTS_MD") ;;
  *) exit 0 ;;
esac

# Exceptions: machine-local settings and durable personal context are writable.
if [[ "$FILE_PATH" == "$SETTINGS_LOCAL" || "$FILE_PATH" == "$PERSONAL_CONTEXT" ]]; then
  exit 0
fi

# Bypass: must be declared in .claude/settings.local.json env section.
# NOTE: agents must ask the user before enabling this (see block message).
is_bypass_authorized() {
  [[ -f "$SETTINGS_LOCAL" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local val
  val=$(jq -r '.env.HQ_BYPASS_CORE_PROTECT // empty' "$SETTINGS_LOCAL" 2>/dev/null) || return 1
  # The flag value is matched exactly on every platform (nocasematch is for paths).
  local restore_nocase=no ok=1
  if shopt -q nocasematch; then restore_nocase=yes; shopt -u nocasematch; fi
  [[ "$val" == "1" || "$val" == "true" ]] && ok=0
  if [[ "$restore_nocase" == yes ]]; then shopt -s nocasematch; fi
  return "$ok"
}

if is_bypass_authorized; then
  exit 0
fi

# core/core.yaml rules.exclude — machine-local paths are always writable.
CORE_YAML="$PROJECT_DIR/core/core.yaml"
if hq_path_matches_core_yaml_exclude "$PROJECT_DIR" "$FILE_PATH" "$CORE_YAML"; then
  exit 0
fi

# Specific file redirects — give a helpful pointer before the generic block.
if [[ "$FILE_PATH" == "$(hq_canonical_path "$PROJECT_DIR/.claude/CLAUDE.md")" ]]; then
  cat >&2 <<MSG
BLOCKED: .claude/CLAUDE.md is the locked HQ charter.
  Edit personal/CLAUDE.md for your personal additions instead.
MSG
  exit 2
fi
if [[ "$FILE_PATH" == "$(hq_canonical_path "$PROJECT_DIR/.claude/settings.json")" ]]; then
  cat >&2 <<MSG
BLOCKED: .claude/settings.json is locked.
  Edit .claude/settings.local.json for local overrides instead.
MSG
  exit 2
fi

# Walk upward from target. If any existing component is a symlink, the write
# usually resolves OUT of the protected tree (e.g. an invalid legacy knowledge
# symlink, or a leftover personal→core mirror symlink from before that mirror
# was retired) — it lands outside core/, so allow it. The exception is a
# package contribution link (core/knowledge/* → core/packages/*/knowledge/*):
# that resolves back INTO core/, and installed pack content is immutable, so
# the write stays blocked.
#
# On Windows the same folder can be spelled with its long name or its 8.3 short
# name (C:/Users/RUNNER~1 and C:/Users/runneradmin). An absolute link target and
# the HQ root may use different spellings, so the "back into core/" test also
# compares both in long form, case-insensitively (US-022). Only Git Bash has
# cygpath, so this costs nothing elsewhere.
bcw_long_lower() {
  local q
  q="$(cygpath -m -l "$1" 2>/dev/null)" || q=""
  [[ -n "$q" ]] || q="$1"
  printf '%s' "$q" | tr '[:upper:]' '[:lower:]'
}
bcw_into_core() {
  [[ "$1" == "$CORE_DIR"/* ]] && return 0
  command -v cygpath >/dev/null 2>&1 || return 1
  local r c
  r="$(bcw_long_lower "$1")"
  c="$(bcw_long_lower "$CORE_DIR")"
  [[ "$r" == "$c"/* ]]
}
probe="$FILE_PATH"
while [[ "$probe" == "$CORE_DIR"/* || "$probe" == "$CLAUDE_DIR"/* || \
         "$probe" == "$AGENTS_DIR"/* || "$probe" == "$CODEX_DIR"/* || \
         "$probe" == "$OBSIDIAN_DIR"/* ]]; do
  if [[ -L "$probe" ]]; then
    # One-level readlink + lexical normalization (portable — macOS readlink
    # has no -f). Pack mounts are single links, so one level is sufficient.
    resolved="$(readlink "$probe" 2>/dev/null || true)"
    if [[ -n "$resolved" && "$resolved" != /* ]]; then
      resolved="$(dirname "$probe")/$resolved"
    fi
    resolved="$(hq_canonical_path "$resolved")"
    if [[ -n "$resolved" ]] && bcw_into_core "$resolved"; then
      break # resolves back into core/ (package mount) — keep blocking
    fi
    exit 0
  fi
  parent="$(dirname "$probe")"
  if [[ "$parent" == "$probe" ]]; then
    break
  fi
  probe="$parent"
done

REL="${FILE_PATH#$PROJECT_DIR/}"

cat >&2 <<EOF
BLOCKED: direct writes to protected scaffold paths are not allowed.
  File: $REL

Protected: core/, .claude/, .agents/, .codex/, .obsidian/, AGENTS.md
Exceptions: .claude/settings.local.json and .claude/personal-context.md are
always writable. Put durable personal voice and preferences in
.claude/personal-context.md.

Preferred fix: author the content under personal/. The personal overlay is read
directly from personal/ — there is no mirror into core/ — so no bypass is needed.

A bypass exists, but DO NOT enable it on your own. Setting
"HQ_BYPASS_CORE_PROTECT": "1" under "env" in .claude/settings.local.json turns
OFF this protection for EVERY later write, so it requires the user's explicit
approval. Ask the user to confirm first; only with their go-ahead set the flag
(and offer to turn it back off when done). Inline env-var prefixes are not
accepted.

If this block is wrong or surprising, report it with /hq-bug.
EOF
exit 2
