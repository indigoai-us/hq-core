#!/usr/bin/env bash
# resolve-hq-root.sh — print the HQ root directory from any cwd.
#
# Resolution order:
#   0. --anchor DIR (optional): a script that lives inside HQ passes its own
#      root; it wins when DIR contains core/.
#   1. HQ_ROOT environment variable
#   2. ~/.hq/root pointer file (first line is an absolute path)
#   3. walk up from the cwd looking for an HQ marker (core/core.yaml)
#   4. otherwise exit 3 with one reason line on stderr
#
# CLAUDE_PROJECT_DIR is deliberately not consulted: when Claude Code runs in a
# foreign repo it names that repo, not HQ.
#
# Usage:
#   bash core/scripts/resolve-hq-root.sh [--anchor DIR] [--cwd DIR]
#   . core/scripts/resolve-hq-root.sh --lib   # defines hq_resolve_root only
#
# Exit codes: 0 resolved (path on stdout), 2 usage error, 3 unresolved.

hq_root_is_hq() {
  [ -n "${1:-}" ] && [ -f "$1/core/core.yaml" ]
}

# hq_resolve_root [anchor] [cwd] — sets HQ_ROOT_RESULT or HQ_ROOT_REASON.
hq_resolve_root() {
  local anchor="${1:-}" start="${2:-$PWD}" pointer_file dir line
  HQ_ROOT_RESULT=""
  HQ_ROOT_REASON=""

  if [ -n "$anchor" ] && [ -d "$anchor/core" ]; then
    HQ_ROOT_RESULT="$(cd "$anchor" 2>/dev/null && pwd)" && [ -n "$HQ_ROOT_RESULT" ] && return 0
    HQ_ROOT_RESULT=""
  fi

  if [ -n "${HQ_ROOT:-}" ]; then
    if [ -d "$HQ_ROOT" ]; then
      HQ_ROOT_RESULT="$(cd "$HQ_ROOT" && pwd)"
      return 0
    fi
    HQ_ROOT_REASON="HQ_ROOT is set to '$HQ_ROOT' but that directory does not exist"
    return 3
  fi

  pointer_file="${HOME:-}/.hq/root"
  if [ -n "${HOME:-}" ] && [ -f "$pointer_file" ]; then
    IFS= read -r line < "$pointer_file" || true
    line="${line%$'\r'}"
    if hq_root_is_hq "$line"; then
      HQ_ROOT_RESULT="$(cd "$line" && pwd)"
      return 0
    fi
  fi

  dir="$(cd "$start" 2>/dev/null && pwd)" || dir=""
  while [ -n "$dir" ]; do
    if hq_root_is_hq "$dir"; then
      HQ_ROOT_RESULT="$dir"
      return 0
    fi
    [ "$dir" = "/" ] && break
    dir="${dir%/*}"
    [ -z "$dir" ] && dir="/"
  done

  HQ_ROOT_REASON="resolve-hq-root: no HQ root found (HQ_ROOT unset, no valid ~/.hq/root, no core/core.yaml above $start)"
  return 3
}

if [ "${HQ_RESOLVE_HQ_ROOT_LIBRARY:-0}" = "1" ] || [ "${1:-}" = "--lib" ]; then
  # shellcheck disable=SC2317 # return works when sourced; exit covers direct runs.
  return 0 2>/dev/null || exit 0
fi

hq_resolve_root_main() {
  local anchor="" cwd="$PWD"
  while [ $# -gt 0 ]; do
    case "$1" in
      --anchor) anchor="${2:-}"; shift 2 ;;
      --cwd) cwd="${2:-}"; shift 2 ;;
      -h|--help) sed -n '2,20p' "$0"; return 0 ;;
      *) printf 'resolve-hq-root: unknown argument: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  if hq_resolve_root "$anchor" "$cwd"; then
    printf '%s\n' "$HQ_ROOT_RESULT"
    return 0
  fi
  printf '%s\n' "$HQ_ROOT_REASON" >&2
  return 3
}

hq_resolve_root_main "$@"
exit $?
