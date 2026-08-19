#!/usr/bin/env bash
# lint-shell-portability.sh — fail on high-signal non-portable shell patterns.
#
# Flags (v1 — ship-blocking):
#   - BSD-only sed -i ''
#   - brew-only jq install messages
#   - readlink -f (GNU-only)
#   - flock (Linux-only; absent on macOS — the util-linux binary is not shipped)
#   - ${var//$'..\\\\..'/..}: an UNQUOTED ANSI-C substitution pattern carrying a
#     LITERAL backslash. bash 3.2 (stock macOS) reads it as a pattern escape and
#     the substitution silently matches nothing, while bash 5 matches it
#     literally — so the defect never appears in Linux CI. Assign the pattern to
#     a variable and quote it: p=$'\\\\\\n'; "${var//"$p"/}". Single-escape
#     patterns ($'\\t', $'\\037') expand to one character and are not flagged.
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
  # An unquoted ANSI-C pattern holding a LITERAL backslash silently no-ops on
  # bash 3.2 (stock macOS) while working on bash 5, so it fails only off-CI.
  # Shipped instance: the scope guard's line-continuation strip, which left a
  # split company path unreassembled and therefore unscanned.
  # Comment lines are skipped: the fixed call site documents the broken form it
  # replaced, and a rule that cannot tell prose from code punishes that.
  : > "$HITS"
  grep -nE "\\$\\{[A-Za-z_][A-Za-z0-9_]*//?\\$'[^']*\\\\\\\\[^']*'" "$f" > "$HITS" 2>/dev/null || true
  while IFS= read -r hit || [ -n "$hit" ]; do
    [ -z "$hit" ] && continue
    body="${hit#*:}"
    case "${body#"${body%%[![:space:]]*}"}" in \#*) continue ;; esac
    report "$f" "${hit%%:*}" "unquoted ANSI-C substitution pattern with a literal backslash (bash 3.2 matches nothing; assign it to a variable and quote it)"
  done < "$HITS"
  # flock as a command word (util-linux) is absent on macOS, where a shipped
  # hook that assumes it dies with "flock: command not found" — the exact
  # failure that hit macOS members. A `command -v flock` (or which/type/hash)
  # PROBE is how portable code guards the call, so those lines are exempt; a
  # deliberate guarded call site belongs in the allow file, not shipped bare.
  : > "$HITS"
  grep -nE '(^|[^[:alnum:]_.-])flock[[:space:]]' "$f" > "$HITS" 2>/dev/null || true
  while IFS= read -r hit || [ -n "$hit" ]; do
    [ -z "$hit" ] && continue
    body="${hit#*:}"
    case "$body" in
      *"command -v flock"*|*"which flock"*|*"type flock"*|*"hash flock"*) continue ;;
    esac
    report "$f" "${hit%%:*}" "flock is Linux-only (absent on macOS); guard on 'command -v flock' or use a portable lock"
  done < "$HITS"
done < "$LIST"

if [ "$FINDINGS" -gt 0 ]; then
  echo "lint-shell-portability: $FINDINGS finding(s)" >&2
  exit 1
fi
echo "lint-shell-portability: clean"
exit 0
