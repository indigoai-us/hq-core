#!/usr/bin/env bash
# Regression: large qmd collection candidates must not be mistaken for empty
# when pipefail observes find's SIGPIPE after a first-match reader exits.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/qmd-reindex-after-sync.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$SCRIPT" ] || fail "qmd-reindex-after-sync.sh not found at $SCRIPT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HQ_ROOT="$TMP/hq"
LOG="$TMP/qmd.log"
mkdir -p "$HQ_ROOT/core" "$TMP/bin"
: > "$HQ_ROOT/core/core.yaml"

# Shadow qmd so the test observes registrations without touching the real index.
cat > "$TMP/bin/qmd" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${QMD_LOG:?}"
exit 0
MOCK
chmod +x "$TMP/bin/qmd"

# Long names make each find produce well over a pipe buffer of output. With the
# old find | head | grep gate, find then exits 141 and pipefail skips the dir.
mkdir -p \
  "$HQ_ROOT/companies/populated/knowledge" \
  "$HQ_ROOT/companies/populated/projects" \
  "$HQ_ROOT/companies/empty/knowledge" \
  "$HQ_ROOT/companies/empty/projects" \
  "$HQ_ROOT/companies/index-only/knowledge"
: > "$HQ_ROOT/companies/index-only/knowledge/INDEX.md"

padding="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
i=0
while [ "$i" -lt 400 ]; do
  printf -v number '%04d' "$i"
  : > "$HQ_ROOT/companies/populated/knowledge/$number-$padding.md"
  : > "$HQ_ROOT/companies/populated/projects/$number-$padding.json"
  i=$((i + 1))
done

env -i PATH="$TMP/bin:/usr/bin:/bin" QMD_LOG="$LOG" \
  bash "$SCRIPT" "$HQ_ROOT"

knowledge_add="collection add $HQ_ROOT/companies/populated/knowledge --name populated --mask **/*.md"
projects_add="collection add $HQ_ROOT/companies/populated/projects --name populated-projects --mask **/*.{md,json}"
grep -Fqx "$knowledge_add" "$LOG" || fail "large knowledge collection was not registered"
pass "large knowledge collection registered"
grep -Fqx "$projects_add" "$LOG" || fail "large projects collection was not registered"
pass "large projects collection registered"

add_count="$(grep -c '^collection add ' "$LOG" || true)"
[ "$add_count" -eq 2 ] || fail "expected only 2 populated collections, got $add_count"
pass "empty and INDEX-only collections skipped"

echo "PASS: qmd-reindex-after-sync SIGPIPE regression"
