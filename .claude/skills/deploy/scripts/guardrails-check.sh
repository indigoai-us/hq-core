#!/usr/bin/env bash
# guardrails-check.sh — apply caps + build tarball for hq-deploy.
# Inlined replacement for the former Guardrails sub-agent.
#
# Args:
#   $1 — output directory (the build artifact root)
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
if [ "$FILE_COUNT" -gt 100 ]; then
  emit_fail "file_count_exceeded:$FILE_COUNT"
fi

# 3. Build tarball
TARBALL=$(mktemp -t hq-deploy-tar.XXXXXX).tar.gz
tar -czf "$TARBALL" -C "$OUT_DIR" . 2>/dev/null

if [ ! -f "$TARBALL" ]; then
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
