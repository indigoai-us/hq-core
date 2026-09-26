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

# Fixture: GNU-only version sort must be flagged in both spellings, and a plain
# `sort -u` must not be.
SORTV_RE="sort[[:space:]]+(-V|--version-sort)"
printf '#!/bin/bash\nprintf "%%s\\n" 1.2 1.10 | sort -V | head -1\n' > "$TMP/core/scripts/bad-sortv.sh"
printf '#!/bin/bash\nprintf "%%s\\n" b a | sort --version-sort\n' > "$TMP/core/scripts/bad-sortlong.sh"
printf '#!/bin/bash\nprintf "%%s\\n" b a | sort -u\n' > "$TMP/core/scripts/ok-sortu.sh"
for bad in bad-sortv bad-sortlong; do
  if grep -nE "$SORTV_RE" "$TMP/core/scripts/$bad.sh" >/dev/null; then
    echo "  ok   detects GNU-only version sort ($bad)"
  else
    echo "FAIL: detector missed GNU-only version sort in $bad" >&2
    exit 1
  fi
done
if grep -nE "$SORTV_RE" "$TMP/core/scripts/ok-sortu.sh" >/dev/null; then
  echo "FAIL: version-sort detector false-positives on sort -u" >&2
  exit 1
fi
echo "  ok   version-sort detector ignores plain sort -u"

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
git -C "$ANSI_REPO" config user.email t@example.com
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

# ---- Empty-array expansions under nounset (bash 3.2) ------------------------
# bash 3.2 treats a bare "${items[@]}" expansion as unbound when `set -u` is
# active and the array is empty. Linux CI's newer Bash does not, so exercise the
# real linter against both the broken and established guarded forms.
ARRAY_REPO="$TMP/array-repo"
mkdir -p "$ARRAY_REPO/core/scripts"
git -C "$ARRAY_REPO" init -q
git -C "$ARRAY_REPO" config user.email t@example.com
git -C "$ARRAY_REPO" config user.name t
cp "$ROOT/core/scripts/lint-shell-portability.sh" "$ARRAY_REPO/core/scripts/"

cat >"$ARRAY_REPO/core/scripts/check-hq-hooks.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
items=()
printf '%s\\n' "${items[@]}"
guarded_items=()
printf '%s\\n' "${guarded_items[@]+"${guarded_items[@]}"}"
SH
git -C "$ARRAY_REPO" add core/scripts

array_out="$(cd "$ARRAY_REPO" && bash core/scripts/lint-shell-portability.sh 2>&1 || true)"
if printf '%s' "$array_out" | grep -q 'check-hq-hooks.sh:4:'; then
  echo "  ok   real linter flags an unguarded array expansion in a nounset script"
else
  echo "FAIL: linter did not flag the nounset empty-array expansion" >&2
  printf '%s\\n' "$array_out" >&2
  exit 1
fi
if printf '%s' "$array_out" | grep -q 'check-hq-hooks.sh:6:'; then
  echo "FAIL: linter false-flagged the guarded empty-array expansion" >&2
  printf '%s\\n' "$array_out" >&2
  exit 1
fi
echo "  ok   established empty-array guard is accepted"

# ---- mktemp templates with suffixes after XXXXXX ----------------------------
# BSD/macOS mktemp replaces a trailing run of Xs. A suffix after that run is
# not portable: shell-script examples such as XXXXXX).tar.gz fail to expand.
MK_REPO="$TMP/mktemp-repo"
mkdir -p "$MK_REPO/core/scripts" "$MK_REPO/.claude/skills/deploy/scripts"
git -C "$MK_REPO" init -q
git -C "$MK_REPO" config user.email t@example.com
git -C "$MK_REPO" config user.name t
cp "$ROOT/core/scripts/lint-shell-portability.sh" "$MK_REPO/core/scripts/"
cat >"$MK_REPO/.claude/skills/deploy/scripts/mktemp-probe.sh" <<'SH'
#!/usr/bin/env bash
BAD_TARBALL="$(mktemp -t hq-deploy-tar.XXXXXX).tar.gz"
GOOD_TARBALL="$(mktemp -t hq-deploy-tar.XXXXXX)"
SH
git -C "$MK_REPO" add core/scripts .claude/skills

mktemp_out="$(cd "$MK_REPO" && bash core/scripts/lint-shell-portability.sh 2>&1 || true)"
if printf '%s' "$mktemp_out" | grep -q 'mktemp-probe.sh:2:.*suffix'; then
  echo "  ok   real linter flags a mktemp suffix after XXXXXX"
else
  echo "FAIL: linter did not flag a mktemp suffix after XXXXXX" >&2
  printf '%s\n' "$mktemp_out" >&2
  exit 1
fi
if printf '%s' "$mktemp_out" | grep -q 'mktemp-probe.sh:3:'; then
  echo "FAIL: linter false-flagged a trailing-X mktemp template" >&2
  printf '%s\n' "$mktemp_out" >&2
  exit 1
fi
echo "  ok   trailing-X mktemp template is accepted"

MK_TEMP_SUFFIX_RE='mktemp[[:space:]][^#]*X{6}[^[:space:]]*[.][[:alnum:]]'
for doc in \
  .claude/skills/handoff/SKILL.md \
  .claude/skills/journal/SKILL.md \
  .claude/skills/deploy/SKILL.md; do
  if grep -nE "$MK_TEMP_SUFFIX_RE" "$ROOT/$doc"; then
    echo "FAIL: documentation contains a mktemp suffix after XXXXXX: $doc" >&2
    exit 1
  fi
done
echo "  ok   shipped skill examples use portable mktemp templates"

echo "ALL PASS: lint-shell-portability"
exit 0
