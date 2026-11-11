#!/bin/bash
# hq-core: public
# Block Glob calls that should use qmd or direct Read instead
# 1. Block ALL Glob for prd.json / worker.yaml (use qmd search or Read)
# 2. Block unscoped Glob from HQ root (causes 20s timeouts)

# Replay jq diagnostics after the input pipeline completes. Keep NUL-separated
# segments in an array so every byte, including trailing NULs/newlines, survives.
_hq_glob_query() {
  local mode=$1 input=$2 query=$3 part status index
  local -a diagnostics=()
  {
    while IFS= read -r -d '' part; do
      diagnostics[${#diagnostics[@]}]=$part
    done < <(
      if [ "$mode" = cat ]; then
        cat 2>&1
      elif [ "$mode" = printf ]; then
        printf '%s' "$input" | jq -r "$query" 2>&1 >&3
      else
        echo "$input" | jq -r "$query" 2>&1 >&3
      fi
      status=$?
      builtin printf '\0%d' "$status"
    )
    status=$part
    for ((index=0; index+1<${#diagnostics[@]}; index++)); do
      builtin printf '%s\0' "${diagnostics[index]}" >&2
    done
    builtin printf '%s' "${diagnostics[${#diagnostics[@]}-1]}" >&2
    return "$status"
  } 3>&1
}

INPUT=$(cat)
# master-hook exports HQ_HOOK_TOOL_NAME for every child, even when it is empty.
# Prefer it when present so non-Glob calls avoid a jq fork (notably on Windows).
if [ "${HQ_HOOK_TOOL_NAME+set}" = "set" ]; then
  TOOL="$HQ_HOOK_TOOL_NAME"
else
  TOOL=$(_hq_glob_query printf "$INPUT" '.tool_name // .toolName // empty')
fi

# list_dir / ListDir is a shallow readdir — never subject to the recursive Glob guard.
case "$TOOL" in
  list_dir|ListDir|LS|list)
    exit 0
    ;;
esac

# This is a performance/hygiene guard, not a security control. A dispatcher
# mismatch or payload with no tool name must fail open: an unscoped search is
# recoverable, but blocking an unrelated tool makes the session unusable.
[ "$TOOL" = "Glob" ] || exit 0

HQ="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
# Prefer HQ_ROOT from the Grok adapter when git toplevel is a nested repo.
if [ -n "${HQ_ROOT:-}" ] && [ -d "$HQ_ROOT" ]; then
  HQ="$HQ_ROOT"
fi

# Accept Claude + Grok field names (path / target_directory / file_path).
PATH_PARAM=$(_hq_glob_query echo "$INPUT" '
  .tool_input.path
  // .tool_input.target_directory
  // .tool_input.file_path
  // .toolInput.path
  // .toolInput.target_directory
  // empty
')
PATTERN=$(_hq_glob_query echo "$INPUT" '
  .tool_input.pattern // .tool_input.glob // .toolInput.pattern // empty
')
CWD=$(_hq_glob_query echo "$INPUT" '.cwd // empty')

# Block prd.json and worker.yaml discovery — always use qmd or direct Read
if echo "$PATTERN" | grep -qE 'prd\.json|worker\.yaml'; then
  _hq_glob_query cat '' '' <<EOF
BLOCKED: Never use Glob for prd.json or worker.yaml.

For discovery:  qmd search "{name} prd.json" --json -n 5
For known path: Read companies/{co}/projects/{name}/prd.json
For workers:    Read core/workers/registry.yaml → find path → Read worker.yaml
EOF
  exit 2
fi

if [ -z "$PATH_PARAM" ] || [ "$PATH_PARAM" = "null" ]; then
  _hq_glob_query cat '' '' <<EOF
BLOCKED: Glob needs a path. Pass path scoped to a subdirectory (not HQ root).
  Glob pattern="<pattern>" path="core/"
  Glob pattern="<pattern>" path="workspace/"
  Glob pattern="<pattern>" path="companies/"
Or use: qmd search "query" --json -n 10
EOF
  exit 2
fi

# Resolve effective search path
if [ -z "$PATH_PARAM" ]; then
  SEARCH_PATH="$CWD"
else
  SEARCH_PATH="$PATH_PARAM"
fi

# Spell a path without ".", "..", repeated or trailing slashes, and set
# _hq_glob_norm to the result. Lexical only: symlinks are not resolved, and
# only "/" separates names. ".." above "/" stays at "/"; a relative path keeps
# leading ".." and becomes "." when nothing is left. An empty path stays empty.
# Builtins only, so the hot path starts no process.
_hq_glob_normalize() {
  local p=$1 IFS=/ part n=0 abs= noglob=
  local -a parts kept
  _hq_glob_norm=
  [ -n "$p" ] || return 0
  case $p in /*) abs=/ ;; esac
  case $- in *f*) noglob=1 ;; esac
  set -f
  # Split on IFS=/ with globbing off. read -a would need a here-string, which
  # bash 3.2-5.0 writes to a temporary file.
  # shellcheck disable=SC2206
  parts=($p)
  [ -n "$noglob" ] || set +f
  for part in "${parts[@]}"; do
    case $part in
      ''|.) ;;
      ..)
        if [ "$n" -gt 0 ]; then
          case ${kept[n-1]} in
            ..) kept[n]=..; n=$((n+1)) ;;
            *) n=$((n-1)); unset "kept[n]" ;;
          esac
        elif [ -z "$abs" ]; then
          kept[n]=..; n=$((n+1))
        fi
        ;;
      *) kept[n]=$part; n=$((n+1)) ;;
    esac
  done
  # Quoted: bash 3.2 joins an unquoted ${kept[*]} with spaces here.
  _hq_glob_norm="$abs${kept[*]}"
  [ -n "$_hq_glob_norm" ] || _hq_glob_norm=.
}

# Block if searching the HQ root (recursive Glob only — not a single-dir list),
# however the path spells it: "$HQ/./", "$HQ//" or "$HQ/core/.." all count.
_hq_glob_normalize "$SEARCH_PATH"
_hq_glob_search=$_hq_glob_norm
_hq_glob_normalize "$HQ"
if [ "$SEARCH_PATH" = "$HQ" ] || [ "$SEARCH_PATH" = "$HQ/" ] ||
  [ "$_hq_glob_search" = "$_hq_glob_norm" ]; then
  _hq_glob_query cat '' '' <<EOF
BLOCKED: Glob from HQ root causes timeouts (1.38M files via symlinked repos).

Fix: Add path: scoped to a subdirectory:
  Glob pattern="$PATTERN" path="companies/"
  Glob pattern="$PATTERN" path="core/workers/"
  Glob pattern="$PATTERN" path="workspace/"

Or use: qmd search "query" --json -n 10
EOF
  exit 2
fi

exit 0
