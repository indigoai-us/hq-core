#!/usr/bin/env bash
# hq-core: public
# The dispatcher already parsed the tool name. An unmatched tool should not
# start cat or jq merely for this guard to allow it.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="${HOOK_UNDER_TEST:-$ROOT/.claude/hooks/enforce-vault-write-access.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REAL_CAT="$(type -P cat)"
REAL_JQ="$(type -P jq)"
SHIMS="$TMP/bin"
SPAWN_LOG="$TMP/spawns.log"
mkdir -p "$SHIMS"
: > "$SPAWN_LOG"

cat > "$SHIMS/cat" <<'SH'
#!/usr/bin/env bash
printf 'cat\n' >> "$SPAWN_LOG"
exec "$REAL_CAT" "$@"
SH
cat > "$SHIMS/jq" <<'SH'
#!/usr/bin/env bash
printf 'jq\n' >> "$SPAWN_LOG"
exec "$REAL_JQ" "$@"
SH
chmod +x "$SHIMS/cat" "$SHIMS/jq"

PAYLOAD='{"tool_name":"Read","tool_input":{"file_path":"README.md"}}'
rc=0
output="$(printf '%s' "$PAYLOAD" | env \
  PATH="$SHIMS:$PATH" \
  REAL_CAT="$REAL_CAT" REAL_JQ="$REAL_JQ" SPAWN_LOG="$SPAWN_LOG" \
  HQ_HOOK_TOOL_NAME=Read \
  bash "$HOOK" 2>&1)" || rc=$?

if [[ "$rc" -ne 0 || -n "$output" ]]; then
  printf 'FAIL: unmatched-tool behavior changed (exit=%s, output=%s)\n' "$rc" "$output" >&2
  exit 1
fi

cat_starts=0
jq_starts=0
while IFS= read -r command; do
  case "$command" in
    cat) cat_starts=$((cat_starts + 1)) ;;
    jq) jq_starts=$((jq_starts + 1)) ;;
  esac
done < "$SPAWN_LOG"

if [[ "$cat_starts" -ne 0 || "$jq_starts" -ne 0 ]]; then
  printf 'FAIL: unmatched-tool allow path started cat=%s jq=%s; expected cat=0 jq=0\n' \
    "$cat_starts" "$jq_starts" >&2
  exit 1
fi

printf 'PASS: unmatched-tool allow path preserved exit/output and started cat=0 jq=0\n'
