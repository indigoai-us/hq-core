#!/usr/bin/env bash
# US-029: verify /handoff and sibling skills call the native `hq core handoff*`
# commands directly, that the retired `handoff-*.sh` scripts are deleted, and
# that older or missing hq-cli installs get a clear upgrade error before running
# `hq core handoff run`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
SKILL="$ROOT/.claude/skills/handoff/SKILL.md"
FLOOR_LIB="$ROOT/core/scripts/lib/hq-cli-floor.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/handoff-run-compat.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ -f "$SKILL" ] || fail "missing handoff skill: $SKILL"

# 1. All 11 retired handoff-*.sh scripts are absent.
for script in \
  handoff-archive-decision.sh \
  handoff-autofile.sh \
  handoff-builder-route.sh \
  handoff-finalize.sh \
  handoff-knowledge-commit.sh \
  handoff-open-steps.sh \
  handoff-pointer-company.sh \
  handoff-post.sh \
  handoff-run.sh \
  handoff-sync-prefetch.sh \
  handoff-sync-publish.sh; do
  [ ! -e "$ROOT/core/scripts/$script" ] || fail "retired script still present: core/scripts/$script"
done
pass "all 11 retired handoff-*.sh scripts are deleted"

# 2. core/core.yaml requires >=5.345.263 and /handoff checks the 5.345.263 CLI floor at the top of Process (before Step 1 and handoff run).
# shellcheck source=../lib/hq-cli-floor.sh
. "$FLOOR_LIB"
required_floor="$(hq_cli_floor_required "$ROOT")" || fail "core/core.yaml must declare requiresHqCli"
case "$required_floor" in
  '>='*) hq_cli_version_ge "${required_floor#>=}" 5.345.263 \
    || fail "core/core.yaml requiresHqCli must be >=5.345.263 (got $required_floor)" ;;
  *) fail "core/core.yaml requiresHqCli must use >=X.Y.Z (got $required_floor)" ;;
esac
grep -Fq 'hq_cli_floor_check handoff 5.345.263' "$SKILL" \
  || fail "/handoff must check the 5.345.263 CLI floor before Step 1"
grep -Fq 'Upgrade hq-cli to 5.345.263 or newer' "$SKILL" \
  || fail "/handoff must carry an upgrade message for older installs"
grep -Fq 'hq core handoff run \' "$SKILL" \
  || fail "/handoff must invoke hq core handoff run directly"
FLOOR_LINE="$(grep -nF 'hq_cli_floor_check handoff 5.345.263' "$SKILL" | head -n1 | cut -d: -f1)"
STEP1_LINE="$(grep -n '^### 1\.' "$SKILL" | head -n1 | cut -d: -f1)"
RUN_LINE="$(grep -nF 'hq core handoff run \' "$SKILL" | head -n1 | cut -d: -f1)"
[ "$FLOOR_LINE" -lt "$STEP1_LINE" ] || fail "CLI floor check must precede Step 1 so older CLIs stop before writing temp files or closing the journal"
[ "$FLOOR_LINE" -lt "$RUN_LINE" ] || fail "CLI floor check must precede hq core handoff run"
if grep -Eq 'core/scripts/handoff-[a-z-]+\.sh' "$SKILL"; then
  fail "/handoff must not reference deleted handoff-*.sh scripts"
fi
pass "/handoff checks the 5.345.263 floor before Step 1 and calls hq core handoff run directly"

# 3. Sibling skills call native commands, check the 5.345.263 floor before invoking them, and reference no deleted handoff-*.sh scripts.
grep -Fq 'hq core handoff archive-decision' "$ROOT/.claude/skills/handoff-and-archive/SKILL.md" \
  || fail "handoff-and-archive must reference hq core handoff archive-decision"
grep -Fq 'hq core handoff pointer-company' "$ROOT/.claude/skills/discover/SKILL.md" \
  || fail "discover must reference hq core handoff pointer-company"
grep -Fq 'hq_cli_floor_check discover 5.345.263' "$ROOT/.claude/skills/discover/SKILL.md" \
  || fail "discover must check the 5.345.263 CLI floor before pointer-company"
grep -Fq 'hq core handoff post' "$ROOT/.claude/skills/document-release/SKILL.md" \
  || fail "document-release must reference hq core handoff post"
grep -Fq 'hq core handoff-sync-prefetch' "$ROOT/.claude/skills/resumework/SKILL.md" \
  || fail "resumework must call hq core handoff-sync-prefetch"
grep -Fq 'hq_cli_floor_check resumework 5.345.263' "$ROOT/.claude/skills/resumework/SKILL.md" \
  || fail "resumework must check the 5.345.263 CLI floor before prefetch"
RW_FLOOR_LINE="$(grep -nF 'hq_cli_floor_check resumework 5.345.263' "$ROOT/.claude/skills/resumework/SKILL.md" | head -n1 | cut -d: -f1)"
RW_PREFETCH_LINE="$(grep -nF 'hq core handoff-sync-prefetch || true' "$ROOT/.claude/skills/resumework/SKILL.md" | head -n1 | cut -d: -f1)"
[ "$RW_FLOOR_LINE" -lt "$RW_PREFETCH_LINE" ] || fail "resumework CLI floor check must precede hq core handoff-sync-prefetch"
grep -Fq 'hq core handoff-sync-prefetch' "$ROOT/.claude/skills/startwork/SKILL.md" \
  || fail "startwork must call hq core handoff-sync-prefetch"
grep -Fq 'hq_cli_floor_check startwork 5.345.263' "$ROOT/.claude/skills/startwork/SKILL.md" \
  || fail "startwork must check the 5.345.263 CLI floor before prefetch"
SW_FLOOR_LINE="$(grep -nF 'hq_cli_floor_check startwork 5.345.263' "$ROOT/.claude/skills/startwork/SKILL.md" | head -n1 | cut -d: -f1)"
SW_PREFETCH_LINE="$(grep -nE '^[[:space:]]*hq core handoff-sync-prefetch[[:space:]]*$' "$ROOT/.claude/skills/startwork/SKILL.md" | head -n1 | cut -d: -f1)"
[ "$SW_FLOOR_LINE" -lt "$SW_PREFETCH_LINE" ] || fail "startwork CLI floor check must precede hq core handoff-sync-prefetch"
grep -Fq 'hq core handoff builder-route' "$ROOT/.claude/skills/retro/SKILL.md" \
  || fail "retro must call hq core handoff builder-route"
grep -Fq 'hq core handoff autofile' "$ROOT/.claude/skills/retro/SKILL.md" \
  || fail "retro must call hq core handoff autofile"
grep -Fq 'hq_cli_floor_check retro 5.345.263' "$ROOT/.claude/skills/retro/SKILL.md" \
  || fail "retro must check the 5.345.263 CLI floor before builder-route/autofile"
for skill in handoff handoff-and-archive discover document-release resumework startwork retro; do
  if grep -Eq 'handoff-(archive-decision|autofile|builder-route|finalize|knowledge-commit|open-steps|pointer-company|post|run|sync-prefetch|sync-publish)\.sh' "$ROOT/.claude/skills/$skill/SKILL.md"; then
    fail "$skill still references a deleted handoff-*.sh script"
  fi
done
pass "all sibling skills enforce 5.345.263 and call native hq core handoff* commands"

# 4. Floor check fails with a clear upgrade message on older or missing CLI, and passes on 5.345.263.
mkdir -p "$TMP/bin" "$TMP/empty"
cat > "$TMP/bin/hq" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$HQ_MOCK_VER"
SH
chmod +x "$TMP/bin/hq"

for old_ver in 5.345.231 5.345.257 5.345.259 5.345.262; do
  rc=0
  err="$(PATH="$TMP/bin:$PATH" XDG_CACHE_HOME="$TMP/cache-$old_ver" HQ_MOCK_VER="$old_ver" \
    bash -c 'source "$1" && hq_cli_floor_check handoff 5.345.263' _ "$FLOOR_LIB" 2>&1)" || rc=$?
  [ "$rc" -eq 127 ] || fail "expected exit 127 for $old_ver, got $rc"
  grep -Fq "handoff: this skill needs hq-cli >= 5.345.263 (found $old_ver)" <<<"$err" \
    || fail "missing version detail with skill label for $old_ver: $err"
  grep -Fq 'npm install -g @indigoai-us/hq-cli@latest' <<<"$err" \
    || fail "missing upgrade command for $old_ver: $err"
done

miss_rc=0
miss_err="$(PATH="$TMP/empty:/usr/bin:/bin" XDG_CACHE_HOME="$TMP/cache-miss" \
  bash -c 'source "$1" && hq_cli_floor_check handoff 5.345.263' _ "$FLOOR_LIB" 2>&1)" || miss_rc=$?
[ "$miss_rc" -eq 127 ] || fail "expected exit 127 when hq is missing, got $miss_rc"
grep -Fq "handoff: requires the hq CLI — this skill's implementation now ships with it." <<<"$miss_err" \
  || fail "missing install message with skill label when hq is absent: $miss_err"

PATH="$TMP/bin:$PATH" XDG_CACHE_HOME="$TMP/cache-ok" HQ_MOCK_VER=5.345.263 \
  bash -c 'source "$1" && hq_cli_floor_check handoff 5.345.263' _ "$FLOOR_LIB" \
  || fail "floor check must pass on 5.345.263"
pass "floor check rejects older/missing hq-cli with clear upgrade error and accepts 5.345.263"

echo "handoff-run-cli-compat: all passed"
