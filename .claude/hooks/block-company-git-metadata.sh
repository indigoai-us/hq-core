#!/usr/bin/env bash
# Block direct file writes into Git metadata stored under companies/.

set -uo pipefail

INPUT="$(cat)"
FILE_PATHS="$(printf '%s' "$INPUT" | jq -r '
  .tool_input as $ti
  | [$ti.file_path?, $ti.path?, $ti.files[]?.file_path?, $ti.edits[]?.file_path?, $ti.edits[]?.path?]
  | .[] | select(type == "string" and . != "")
' 2>/dev/null || true)"
[[ -n "$FILE_PATHS" ]] || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
HOOK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$HOOK_ROOT/core/scripts/hook-lib.sh"

norm() {
  local path="$1" resolved
  case "$path" in
    "~") path="$HOME" ;;
    "~/"*) path="$HOME/${path#~/}" ;;
    /*) ;;
    *) path="$PROJECT_DIR/$path" ;;
  esac
  resolved="$(hq_realpath_lenient "$path" 2>/dev/null || hq_normpath "$path" 2>/dev/null || printf '%s' "$path")"
  hq_canonical_path "$resolved"
}

ROOT="$(norm "$PROJECT_DIR")"
COMPANIES_ROOT="$(norm "$ROOT/companies")"
LOWER_COMPANIES_ROOT="$(printf '%s' "$COMPANIES_ROOT" | tr '[:upper:]' '[:lower:]')"

while IFS= read -r raw_path; do
  [[ -n "$raw_path" ]] || continue
  resolved="$(norm "$raw_path")"
  lower="$(printf '%s' "$resolved" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    "$LOWER_COMPANIES_ROOT"/*) relative="${lower#"$LOWER_COMPANIES_ROOT"/}" ;;
    *) continue ;;
  esac
  case "$relative" in
    .git|*/.git|.git/*|*/.git/*)
      cat >&2 <<EOF
BLOCKED: direct writes to Git metadata under companies/ are not allowed.
Company folders sync to every member's devices, so keep Git repositories in repos/private/<name> or repos/public/<name>.
  Path: $resolved
EOF
      exit 2
      ;;
  esac
done <<< "$FILE_PATHS"

exit 0
