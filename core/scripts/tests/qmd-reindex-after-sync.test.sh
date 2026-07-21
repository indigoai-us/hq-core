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

# --- personal/knowledge is registered as its own collection (read directly) ---
# personal is the sole read source now (no reindex mirror into core/knowledge),
# so a populated personal/knowledge must get its own qmd collection.
HQ2="$TMP/hq2"; LOG2="$TMP/qmd2.log"
mkdir -p "$HQ2/core" "$HQ2/personal/knowledge"
: > "$HQ2/core/core.yaml"
: > "$HQ2/personal/knowledge/note.md"
: > "$HQ2/personal/knowledge/INDEX.md"
env -i PATH="$TMP/bin:/usr/bin:/bin" QMD_LOG="$LOG2" bash "$SCRIPT" "$HQ2"
personal_add="collection add $HQ2/personal/knowledge --name personal-knowledge --mask **/*.md"
grep -Fqx "$personal_add" "$LOG2" || fail "personal/knowledge collection was not registered"
pass "personal/knowledge registered as its own collection"

# INDEX-only personal/knowledge must NOT register (mirrors the company rule).
HQ3="$TMP/hq3"; LOG3="$TMP/qmd3.log"
mkdir -p "$HQ3/core" "$HQ3/personal/knowledge"
: > "$HQ3/core/core.yaml"
: > "$HQ3/personal/knowledge/INDEX.md"
env -i PATH="$TMP/bin:/usr/bin:/bin" QMD_LOG="$LOG3" bash "$SCRIPT" "$HQ3"
grep -Fq 'name personal-knowledge' "$LOG3" && fail "INDEX-only personal/knowledge should not register"
pass "INDEX-only personal/knowledge skipped"

echo "PASS: qmd-reindex-after-sync SIGPIPE regression"
