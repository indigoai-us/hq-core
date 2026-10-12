#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s [--root <git-repository>]\n' "${0##*/}" >&2
}

ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel)"
if [ "$#" -gt 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != "--root" ] || [ -z "$2" ]; then
    usage
    exit 64
  fi
  ROOT="$2"
fi

ROOT="$(cd "$ROOT" && pwd)"
LIST_RELATIVE='core/scripts/deleted-script-paths.txt'
LIST="$ROOT/$LIST_RELATIVE"
if [ ! -r "$LIST" ]; then
  printf 'deleted-script path list is not readable: %s\n' "$LIST" >&2
  exit 1
fi
if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'not a Git worktree: %s\n' "$ROOT" >&2
  exit 1
fi

failed=0
while IFS= read -r deleted_path || [ -n "$deleted_path" ]; do
  case "$deleted_path" in
    ''|'#'*) continue ;;
    /*|../*|*/../*|*/..)
      printf 'invalid deleted script path in %s: %s\n' "$LIST_RELATIVE" "$deleted_path" >&2
      exit 1
      ;;
    *.sh|*.mjs|*.cjs) ;;
    *)
      printf 'invalid deleted script path in %s: %s\n' "$LIST_RELATIVE" "$deleted_path" >&2
      exit 1
      ;;
  esac
  case "$deleted_path" in
    *'*'*|*'?'*|*'['*|*']'*)
      printf 'invalid deleted script path in %s: %s\n' "$LIST_RELATIVE" "$deleted_path" >&2
      exit 1
      ;;
  esac

  if git -C "$ROOT" ls-files --error-unmatch -- ":(literal)$deleted_path" >/dev/null 2>&1 \
    || [ -e "$ROOT/$deleted_path" ] \
    || [ -L "$ROOT/$deleted_path" ]; then
    printf 'listed script still exists in worktree or index: %s\n' "$deleted_path" >&2
    failed=1
  fi

  # Callers may refer to a script relative to their own directory (for example
  # "$SCRIPT_DIR/name.sh"), so checking only the repository-root path misses them.
  if matches="$(git -C "$ROOT" grep -n -I -F \
    -e "$deleted_path" \
    -e "${deleted_path##*/}" \
    -- . ":(exclude)$LIST_RELATIVE" 2>&1)"; then
    printf 'tracked files still reference deleted script path: %s\n%s\n' "$deleted_path" "$matches" >&2
    failed=1
  else
    grep_status=$?
    if [ "$grep_status" -gt 1 ]; then
      printf 'git grep failed while checking %s (exit %s): %s\n' "$deleted_path" "$grep_status" "$matches" >&2
      exit "$grep_status"
    fi
  fi
done < "$LIST"

if [ "$failed" -ne 0 ]; then
  exit 1
fi
