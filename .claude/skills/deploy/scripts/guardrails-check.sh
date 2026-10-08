#!/usr/bin/env bash
# guardrails-check.sh — apply caps + build tarball for hq-deploy.
# Inlined replacement for the former Guardrails sub-agent.
#
# Args:
#   $1 — output directory (the build artifact root)
#   $2 — optional API handler directory to include at archive root
#
# Output (one JSON line on stdout):
#   {"pass":true,"reason":null,"tarball_path":"...","size_bytes":N,"sha256":"...","file_count":N}
#   {"pass":false,"reason":"disqualifier:<file>|file_count_exceeded:<n>|size_exceeded:<bytes>","tarball_path":"","size_bytes":0,"sha256":"","file_count":0}
#
# Caps:
#   - Project-root disqualifiers: Dockerfile, serverless.yml, sst.config.*, prisma/, migrations/, knex/drizzle configs
#   - File count > 100 (post-build)
#   - Tarball size > 10MB gzipped

set -u

OUT_DIR="${1:-}"
API_DIR="${2:-}"

emit_fail() {
  printf '{"pass":false,"reason":"%s","tarball_path":"","size_bytes":0,"sha256":"","file_count":0}\n' "$1"
  exit 0
}

emit_ok() {
  local tar="$1" size="$2" sha="$3" count="$4"
  printf '{"pass":true,"reason":null,"tarball_path":"%s","size_bytes":%d,"sha256":"%s","file_count":%d}\n' "$tar" "$size" "$sha" "$count"
  exit 0
}

if [ -z "$OUT_DIR" ] || [ ! -d "$OUT_DIR" ]; then
  emit_fail "missing_output_dir"
fi
if [ -n "$API_DIR" ] && [ ! -d "$API_DIR" ]; then
  emit_fail "missing_api_dir"
fi
if [ -n "$API_DIR" ] && [[ "$API_DIR" != /* ]]; then
  API_DIR="$PWD/$API_DIR"
fi

# 1. Project-root disqualifiers (in caller's CWD, not OUT_DIR)
DISQUALIFIERS=("Dockerfile" "serverless.yml" "serverless.yaml")
for f in "${DISQUALIFIERS[@]}"; do
  if [ -f "./$f" ]; then
    emit_fail "disqualifier:$f"
  fi
done

# Glob disqualifiers
for f in sst.config.* knexfile.* drizzle.config.*; do
  if [ -f "./$f" ]; then
    emit_fail "disqualifier:$f"
  fi
done

for d in prisma migrations; do
  if [ -d "./$d" ]; then
    emit_fail "disqualifier:$d/"
  fi
done

# 2. File count cap
FILE_COUNT=$(find "$OUT_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ -n "$API_DIR" ]; then
  API_FILE_COUNT=$(find "$API_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
  FILE_COUNT=$((FILE_COUNT + API_FILE_COUNT))
fi

# App database migrations live at the project root (db/migrations). When the
# output directory is a build dir (dist/, public/) they are not inside it, so
# add them to the archive root. Skipped when the output directory is the
# project root, where the migrations are already included.
MIGRATIONS_DIR=""
if [ -d "./db/migrations" ] && [ ! -e "$OUT_DIR/db/migrations" ]; then
  MIGRATIONS_DIR="$PWD/db/migrations"
  MIGRATIONS_FILE_COUNT=$(find "$MIGRATIONS_DIR" -type f -name '*.sql' 2>/dev/null | wc -l | tr -d ' ')
  FILE_COUNT=$((FILE_COUNT + MIGRATIONS_FILE_COUNT))
fi
if [ "$FILE_COUNT" -gt 100 ]; then
  emit_fail "file_count_exceeded:$FILE_COUNT"
fi

# 3. Build tarball
TARBALL=$(mktemp -t hq-deploy-tar.XXXXXX)
TAR_ARGS=(-czf "$TARBALL" -C "$OUT_DIR" .)
if [ -n "$API_DIR" ]; then
  TAR_ARGS+=(-C "$(dirname "$API_DIR")" "$(basename "$API_DIR")")
fi
if [ -n "$MIGRATIONS_DIR" ]; then
  TAR_ARGS+=(-C "$PWD" db/migrations)
fi
# COPYFILE_DISABLE stops macOS tar from adding ._ AppleDouble files.
if ! COPYFILE_DISABLE=1 tar "${TAR_ARGS[@]}" 2>/dev/null; then
  rm -f "$TARBALL"
  emit_fail "tar_create_failed"
fi

# 4. Size cap (10MB)
SIZE=$(stat -f%z "$TARBALL" 2>/dev/null || stat -c%s "$TARBALL" 2>/dev/null || echo 0)
if [ "$SIZE" -gt 10485760 ]; then
  rm -f "$TARBALL"
  emit_fail "size_exceeded:$SIZE"
fi

# 5. SHA256
if command -v sha256sum >/dev/null 2>&1; then
  SHA=$(sha256sum "$TARBALL" | awk '{print $1}')
else
  SHA=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
fi

emit_ok "$TARBALL" "$SIZE" "$SHA" "$FILE_COUNT"
