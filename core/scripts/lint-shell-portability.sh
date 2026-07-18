#!/usr/bin/env bash
# lint-shell-portability.sh — fail on high-signal non-portable shell patterns.
#
# Flags (v1 — ship-blocking):
#   - BSD-only sed -i ''
#   - brew-only jq install messages
#   - readlink -f (GNU-only)
#
# Allowlist: core/scripts/lint-shell-portability.allow (path substring per line).
# /tmp and bare $USER are documented contributor rules; full auto-lint for those
# lands after a burn-down of existing call sites (see cross-platform-support.md).
#
# Exit: 0 clean, 1 findings, 2 error.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

ALLOW="core/scripts/lint-shell-portability.allow"
FINDINGS=0
LIST="$(mktemp "${TMPDIR:-/tmp}/port-lint-files.XXXXXX")"
HITS="$(mktemp "${TMPDIR:-/tmp}/port-lint-hits.XXXXXX")"
trap 'rm -f "$LIST" "$HITS"' EXIT

is_allowed() {
  local file="$1"
  [ -f "$ALLOW" ] || return 1
  while IFS= read -r pat || [ -n "$pat" ]; do
    pat="${pat%$'\r'}"
    [ -z "$pat" ] && continue
    case "$pat" in \#*) continue ;; esac
    case "$file" in *"$pat"*) return 0 ;; esac
  done < "$ALLOW"
  return 1
}

report() {
  local file="$1" line="$2" msg="$3"
  if is_allowed "$file"; then return 0; fi
  printf 'portability: %s:%s: %s\n' "$file" "$line" "$msg" >&2
  FINDINGS=$((FINDINGS + 1))
}

scan_file() {
  local f="$1" pattern="$2" msg="$3"
  : > "$HITS"
  # -E extended regex; ignore missing matches
  grep -nE "$pattern" "$f" > "$HITS" 2>/dev/null || true
  while IFS= read -r hit || [ -n "$hit" ]; do
    [ -z "$hit" ] && continue
    report "$f" "${hit%%:*}" "$msg"
  done < "$HITS"
}

git ls-files -- '*.sh' > "$LIST"

while IFS= read -r f || [ -n "$f" ]; do
  [ -z "$f" ] && continue
  [ -f "$f" ] || continue
  case "$f" in
    *lint-shell-portability*) continue ;;
    *portable-lib.test.sh) continue ;;
  esac
  # Prefix allow-list (string prefix, not nested globs — shellcheck SC2221).
  keep=0
  case "$f" in
    .claude/hooks/*) keep=1 ;;
    .claude/scripts/*) keep=1 ;;
    core/scripts/*) keep=1 ;;
    core/hooks/*) keep=1 ;;
  esac
  case "$f" in
    .claude/skills/*/scripts/*) keep=1 ;;
  esac
  # Nested skill scripts (depth 2)
  case "$f" in
    .claude/skills/*/*/scripts/*) keep=1 ;;
  esac
  [ "$keep" -eq 1 ] || continue

  scan_file "$f" "sed[[:space:]]+-i[[:space:]]+''" "BSD-only sed -i '' (use portable_sed_inplace)"
  # brew-ONLY messages: line mentions brew install jq but not winget/choco/apt/dnf.
  : > "$HITS"
  grep -nE 'brew install jq' "$f" > "$HITS" 2>/dev/null || true
  while IFS= read -r hit || [ -n "$hit" ]; do
    [ -z "$hit" ] && continue
    body="${hit#*:}"
    case "$body" in
      *winget*|*choco*|*scoop*|*apt*|*dnf*) continue ;;
    esac
    report "$f" "${hit%%:*}" "brew-only jq install message (use require_jq / multi-OS guidance)"
  done < "$HITS"
  scan_file "$f" "readlink[[:space:]]+-f" "readlink -f is GNU-only"
done < "$LIST"

if [ "$FINDINGS" -gt 0 ]; then
  echo "lint-shell-portability: $FINDINGS finding(s)" >&2
  exit 1
fi
echo "lint-shell-portability: clean"
exit 0
