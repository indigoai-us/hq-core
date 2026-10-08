#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/core/hooks/SessionStart" "$TMP/core/scripts/lib" "$TMP/.codex/hooks" \
  "$TMP/workspace/sessions/sid-multi" "$TMP/companies/acme" "$TMP/companies/beta" "$TMP/home"
cp "$ROOT/core/hooks/SessionStart/35-work-mesh-session-start.sh" "$TMP/core/hooks/SessionStart/"
cp "$ROOT/core/scripts/lib/work-mesh-enqueue.sh" "$TMP/core/scripts/lib/"
cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$TMP/core/scripts/lib/"
cp "$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$TMP/core/scripts/"
printf '%s\n' 'process.stdout.write("true")' > "$TMP/.codex/hooks/codex-explicit-path-flag.cjs"
printf 'session_id: sid-multi\ncompany_slug: acme\ncompany_slugs: acme,beta\n' > "$TMP/workspace/sessions/sid-multi/meta.yaml"
printf '{"session_id":"sid-multi","company_slug":"acme","company_slugs":["acme","beta"]}\n' \
  > "$TMP/workspace/sessions/sid-multi/scope-capability.json"

printf '{"session_id":"sid-multi","cwd":"%s"}\n' "$TMP" | \
  env HOME="$TMP/home" HQ_ROOT="$TMP" CLAUDE_CODE_SESSION_ID=sid-multi \
    WORK_MESH_SPOOL="$TMP/spool/events.jsonl" WORK_MESH_SEQ_DIR="$TMP/seq" \
    HQ_WORK_MESH_RECONCILE_STUB=1 bash "$TMP/core/hooks/SessionStart/35-work-mesh-session-start.sh"

seqs="$(jq -r '.seq' "$TMP/spool/events.jsonl" | paste -sd, -)"
[ "$seqs" = "1,2" ] || { echo "FAIL: multi-company session_start sequence was $seqs, expected 1,2" >&2; exit 1; }
echo "PASS: work-mesh-multicompany-sequence.test.sh (session_start uses one monotonic per-session counter)"
