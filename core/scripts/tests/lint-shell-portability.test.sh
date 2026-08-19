#!/usr/bin/env bash
# lint-shell-portability.test.sh — smoke for the portability lint
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
LINT="$ROOT/core/scripts/lint-shell-portability.sh"
[ -x "$LINT" ] || chmod +x "$LINT"

# Live tree should pass (post US-003 allowlist).
if ! bash "$LINT"; then
  echo "FAIL: lint-shell-portability dirty on current tree" >&2
  exit 1
fi
echo "  ok   live tree clean"

# Fixture: BSD sed -i '' should be flagged.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lint-port.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/core/scripts"
printf '#!/bin/bash\nsed -i '\'''\'' "s/a/b/" file\n' > "$TMP/core/scripts/bad-sed.sh"
# Run lint from a fake root by temporarily adding the file via a subshell that
# only greps the fixture — exercise the detection regex directly.
if grep -nE "sed[[:space:]]+-i[[:space:]]+''" "$TMP/core/scripts/bad-sed.sh" >/dev/null; then
  echo "  ok   detects BSD sed -i ''"
else
  echo "FAIL: detector missed sed -i ''" >&2
  exit 1
fi

# Fixture: a bare `flock` command word (Linux-only) must be flagged — this is
# the exact macOS failure ("flock: command not found") from the team harness
# analysis. A `command -v flock` probe must NOT be flagged. Mirror the linter's
# real detection: the regex catches the command word, then probe lines are
# excluded, exactly as lint-shell-portability.sh does.
FLOCK_RE='(^|[^[:alnum:]_.-])flock[[:space:]]'
flock_flags() {
  # Returns 0 (flagged) only when a flock command survives the probe exclusion.
  local file="$1" hit body
  while IFS= read -r hit || [ -n "$hit" ]; do
    [ -z "$hit" ] && continue
    body="${hit#*:}"
    case "$body" in
      *"command -v flock"*|*"which flock"*|*"type flock"*|*"hash flock"*) continue ;;
    esac
    return 0
  done < <(grep -nE "$FLOCK_RE" "$file" 2>/dev/null || true)
  return 1
}

printf '#!/bin/bash\nflock -n /tmp/x.lock echo hi\n' > "$TMP/core/scripts/bad-flock.sh"
if flock_flags "$TMP/core/scripts/bad-flock.sh"; then
  echo "  ok   detects bare flock command"
else
  echo "FAIL: detector missed a bare flock command" >&2
  exit 1
fi
printf '#!/bin/bash\nif command -v flock >/dev/null 2>&1; then flock -n 9 || true; fi\n' > "$TMP/core/scripts/probe-flock.sh"
if flock_flags "$TMP/core/scripts/probe-flock.sh"; then
  echo "NOTE: guarded flock call site still flags (expected — belongs in allow file)"
fi
printf '#!/bin/bash\nif command -v flock >/dev/null 2>&1; then :; fi\n' > "$TMP/core/scripts/probe-only-flock.sh"
if flock_flags "$TMP/core/scripts/probe-only-flock.sh"; then
  echo "FAIL: detector false-flagged a bare 'command -v flock' probe" >&2
  exit 1
else
  echo "  ok   ignores a 'command -v flock' probe"
fi


# ---- ANSI-C substitution patterns (bash 3.2) --------------------------------
# This case runs the REAL linter against a throwaway repo rather than
# re-implementing its regex here. The rest of this suite copies each detector's
# expression locally, which cannot catch the failure mode that matters most for
# this rule: the expression surviving shell quoting intact all the way to grep.
# Review of the change that added the rule asserted it could never match; only
# an end-to-end run settles that either way.
ANSI_REPO="$TMP/ansi-c-repo"
mkdir -p "$ANSI_REPO/core/scripts"
git -C "$ANSI_REPO" init -q
git -C "$ANSI_REPO" config user.email [EMAIL]
git -C "$ANSI_REPO" config user.name t
cp "$ROOT/core/scripts/lint-shell-portability.sh" "$ANSI_REPO/core/scripts/"

# line 3 is the broken idiom; lines 4-7 are forms that must NOT be flagged.
{
  printf '#!/usr/bin/env bash\n'
  printf 'cmd="$1"\n'
  printf 'broken="${cmd//$%s\\\\\\n%s/}"\n' "'" "'"
  printf 'safe_unit="${cmd//$%s\\037%s/ }"\n' "'" "'"
  printf 'safe_tab="${cmd//$%s\\t%s/ }"\n' "'" "'"
  printf 'p=$%s\\\\\\n%s\n' "'" "'"
  printf 'safe_quoted="${cmd//"$p"/}"\n'
  printf '# ${cmd//$%s\\\\\\n%s/} named in prose, not code\n' "'" "'"
} > "$ANSI_REPO/core/scripts/probe.sh"
git -C "$ANSI_REPO" add -A

ansi_out="$(cd "$ANSI_REPO" && bash core/scripts/lint-shell-portability.sh 2>&1 || true)"

if printf '%s' "$ansi_out" | grep -q 'probe.sh:3:'; then
  echo "  ok   real linter flags the unquoted backslash-bearing pattern"
else
  echo "FAIL: linter did not flag the broken ANSI-C substitution pattern" >&2
  printf '%s\n' "$ansi_out" >&2
  exit 1
fi

for safe_line in 4 5 7 8; do
  if printf '%s' "$ansi_out" | grep -q "probe.sh:$safe_line:"; then
    echo "FAIL: linter false-flagged probe.sh line $safe_line" >&2
    printf '%s\n' "$ansi_out" >&2
    exit 1
  fi
done
echo "  ok   single-escape, quoted-variable and prose forms are not flagged"

echo "ALL PASS: lint-shell-portability"
exit 0
