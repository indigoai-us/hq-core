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
# Nearest root wins: when the cwd is inside an HQ root (step 3), that root
# beats the ~/.hq/root pointer, and it beats HQ_ROOT when HQ_ROOT names a
# directory that contains it. A nested install (a second HQ, or a test
# fixture under another HQ's tree) resolves to itself, never to its parent.
#
# CLAUDE_PROJECT_DIR is deliberately not consulted: when Claude Code runs in a
# foreign repo it names that repo, not HQ.
#
# Usage:
#   bash core/scripts/resolve-hq-root.sh [--anchor DIR] [--cwd DIR]
#   . core/scripts/resolve-hq-root.sh --lib   # defines the hq_root_* helpers only
#
# Exit codes: 0 resolved (path on stdout), 2 usage error, 3 unresolved.

hq_root_is_hq() {
  [ -n "${1:-}" ] && [ -f "$1/core/core.yaml" ]
}

# hq_root_is_strictly_inside <ancestor> <path>: true when path is below
# ancestor. Both are absolute; builtins only.
hq_root_is_strictly_inside() {
  local ancestor="${1%/}" path="${2%/}"
  [ -n "$path" ] && [ "$ancestor" != "$path" ] || return 1
  case "$path/" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

# hq_root_walk_up <dir>: sets HQ_ROOT_WALK to the closest directory at or
# above dir that holds core/core.yaml, or "" when there is none.
hq_root_walk_up() {
  local dir="${1:-}"
  HQ_ROOT_WALK=""
  while [ -n "$dir" ]; do
    if hq_root_is_hq "$dir"; then
      HQ_ROOT_WALK="$dir"
      return 0
    fi
    [ "$dir" = "/" ] && break
    dir="${dir%/*}"
    [ -z "$dir" ] && dir="/"
  done
  return 1
}

# hq_root_enclosing <root>: sets HQ_ROOT_PARENT to the closest HQ root
# strictly above root (root is then a nested install), or "".
hq_root_enclosing() {
  local dir="${1%/}"
  HQ_ROOT_PARENT=""
  [ -n "$dir" ] || return 1
  dir="${dir%/*}"
  [ -z "$dir" ] && dir="/"
  hq_root_walk_up "$dir" || return 1
  HQ_ROOT_PARENT="$HQ_ROOT_WALK"
  return 0
}

# hq_root_nested_report <root>: when root is nested inside another HQ root
# and Claude Code still reads files from above it (HQ hooks cannot change
# that), sets HQ_NESTED_REPORT to one paragraph naming them and returns 0.
# Otherwise HQ_NESTED_REPORT is "" and it returns 1. Builtins only. It names
# only files that exist, and only inside the outer HQ root: files above that
# root (such as the user's global ~/.claude/CLAUDE.md) load for every
# session, nested or not, so they are not a nesting leak.
hq_root_nested_report() {
  local root="${1%/}" dir git_root="" files="" git_files="" name
  HQ_NESTED_REPORT=""
  hq_root_enclosing "$root" || return 1
  # Claude Code reads .claude/settings.local.json and .claude/skills at the
  # git repository root when a session starts in a subdirectory of it.
  dir="$root"
  while [ -n "$dir" ]; do
    if [ -e "$dir/.git" ]; then
      git_root="$dir"
      break
    fi
    [ "$dir" = "/" ] && break
    dir="${dir%/*}"
    [ -z "$dir" ] && dir="/"
  done
  # A git root above the outer HQ root is outside HQ; leave it out.
  if [ -n "$git_root" ] && [ "$git_root" != "$root" ] \
    && { [ "$git_root" = "$HQ_ROOT_PARENT" ] || hq_root_is_strictly_inside "$HQ_ROOT_PARENT" "$git_root"; }; then
    [ -f "$git_root/.claude/settings.local.json" ] \
      && git_files="$git_root/.claude/settings.local.json (env such as PATH, and permissions)"
    [ -d "$git_root/.claude/skills" ] \
      && git_files="${git_files:+$git_files and }$git_root/.claude/skills"
  fi
  # Claude Code loads CLAUDE.md files from every directory above the cwd.
  # Walk from root's parent up to the outer HQ root and stop there.
  dir="${root%/*}"
  [ -z "$dir" ] && dir="/"
  while [ -n "$dir" ]; do
    for name in CLAUDE.md CLAUDE.local.md .claude/CLAUDE.md; do
      [ -f "${dir%/}/$name" ] && files="${files:+$files, }${dir%/}/$name"
    done
    [ "$dir" = "$HQ_ROOT_PARENT" ] && break
    [ "$dir" = "/" ] && break
    dir="${dir%/*}"
    [ -z "$dir" ] && dir="/"
  done
  # Nothing from the outer install leaks in.
  if [ -z "$files" ] && [ -z "$git_files" ]; then
    return 1
  fi
  HQ_NESTED_REPORT="This HQ install ($root) is inside another HQ install ($HQ_ROOT_PARENT). HQ hooks here use this install's own root, session state and company scope."
  if [ -n "$git_files" ]; then
    HQ_NESTED_REPORT="$HQ_NESTED_REPORT Claude Code itself still reads $git_files, because this folder is not its own git repository. Run git init in $root, or move it outside $HQ_ROOT_PARENT, to stop that."
  fi
  if [ -n "$files" ]; then
    HQ_NESTED_REPORT="$HQ_NESTED_REPORT Claude Code also loads CLAUDE.md files from folders above this one ($files). List them under claudeMdExcludes in $root/.claude/settings.json to skip them."
  fi
  return 0
}

# hq_resolve_root [anchor] [cwd] — sets HQ_ROOT_RESULT or HQ_ROOT_REASON.
hq_resolve_root() {
  local anchor="${1:-}" start="${2:-$PWD}" pointer_file dir line nearest
  HQ_ROOT_RESULT=""
  HQ_ROOT_REASON=""

  if [ -n "$anchor" ] && [ -d "$anchor/core" ]; then
    HQ_ROOT_RESULT="$(cd "$anchor" 2>/dev/null && pwd)" && [ -n "$HQ_ROOT_RESULT" ] && return 0
    HQ_ROOT_RESULT=""
  fi

  dir="$(cd "$start" 2>/dev/null && pwd)" || dir=""
  nearest=""
  if hq_root_walk_up "$dir"; then
    nearest="$HQ_ROOT_WALK"
  fi

  if [ -n "${HQ_ROOT:-}" ]; then
    if [ -d "$HQ_ROOT" ]; then
      HQ_ROOT_RESULT="$(cd "$HQ_ROOT" && pwd)"
      # A nested install under HQ_ROOT is its own root, not the parent's.
      if [ -n "$nearest" ] && hq_root_is_strictly_inside "$HQ_ROOT_RESULT" "$nearest"; then
        HQ_ROOT_RESULT="$nearest"
      fi
      return 0
    fi
    HQ_ROOT_REASON="HQ_ROOT is set to '$HQ_ROOT' but that directory does not exist"
    return 3
  fi

  # A cwd inside an HQ root names that root. The pointer is the fallback for a
  # cwd outside every HQ tree.
  if [ -n "$nearest" ]; then
    HQ_ROOT_RESULT="$nearest"
    return 0
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
