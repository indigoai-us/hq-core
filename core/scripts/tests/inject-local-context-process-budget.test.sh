#!/usr/bin/env bash
# Keep SessionStart local-context rendering byte-identical with bounded process fanout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/inject-local-context.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

FIXTURE="$TMP/hq"
SHIMS="$TMP/shims"
TRACE="$TMP/external-commands.log"
mkdir -p "$FIXTURE/companies" "$FIXTURE/core/workers" "$FIXTURE/companies/acme/workers/a" "$FIXTURE/companies/acme/workers/b" "$SHIMS"
cat > "$FIXTURE/agents-profile.md" <<'PROFILE'
# Asha Rao - Profile
## Challenges
Challenge one
Challenge two
Challenge three
Challenge four
Challenge five
Challenge six must be bounded away
## Other
Not a challenge
PROFILE
cat > "$FIXTURE/companies/manifest.yaml" <<'YAML'
companies:
  _template:
    name: Template
  indigo:
    name: Indigo
  acme:
    name: Acme
metadata:
  owner: ignored
YAML
cat > "$FIXTURE/core/workers/registry.yaml" <<'YAML'
workers:
  - id: acme-a
    path: companies/acme/workers/a/
    company: acme
    status: active
  - id: acme-b
    path: companies/acme/workers/b/
    company: acme
    status: active
  - id: indigo-ghost
    path: companies/indigo/workers/ghost/
    company: indigo
    status: active
YAML
printf 'worker:\n  id: a\n' > "$FIXTURE/companies/acme/workers/a/worker.yaml"
printf 'worker:\n  id: b\n' > "$FIXTURE/companies/acme/workers/b/worker.yaml"

# Log legacy utility launches without changing their behavior. The baseline
# hook launches these repeatedly while building the same local-context block.
for utility in awk dirname grep head paste sed sort uniq; do
  real="$(command -v "$utility" || true)"
  [ -n "$real" ] || fail "required utility missing: $utility"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "$HP29_EXEC_TRACE"\nexec "%s" "$@"\n' "$utility" "$real" > "$SHIMS/$utility"
  chmod +x "$SHIMS/$utility"
done

EXPECTED="$TMP/expected.txt"
ACTUAL="$TMP/actual.txt"
cat > "$EXPECTED" <<'OUTPUT'
<local-context>
Owner: Asha Rao
Challenges: Challenge one; Challenge two; Challenge three; Challenge four; Challenge five
Companies (2): indigo, acme
Company workers: acme (2), indigo (1)
Missing workers (registry path absent): indigo-ghost → companies/indigo/workers/ghost
Do not treat missing workers as available and do not fall back to a raw ingest script. Run hq sync to fetch the directories, or hq reindex to drop stale registry rows.
QMD collections: hq, indigo, acme
</local-context>
OUTPUT

rc=0
mkdir -p "$TMP/home"
HOME="$TMP/home" PATH="$SHIMS:$PATH" HP29_EXEC_TRACE="$TRACE" CLAUDE_PROJECT_DIR="$FIXTURE" bash "$HOOK" > "$ACTUAL" 2>"$TMP/stderr" || rc=$?
[ "$rc" -eq 0 ] || fail "hook exited $rc"
cmp -s "$EXPECTED" "$ACTUAL" || { diff -u "$EXPECTED" "$ACTUAL" >&2 || true; fail "local-context output changed"; }
pass "local-context output matches the synchronous contract byte-for-byte"

count="$(wc -l < "$TRACE" | tr -d '[:space:]')"
[ "$count" -le 7 ] || fail "hook launched $count measured utility processes; expected at most 7"
for utility in dirname grep head paste sed uniq; do
  if grep -Fxq "$utility" "$TRACE"; then fail "hook still launches $utility"; fi
done
pass "hook launches at most 7 measured utility processes and avoids repeated text-pipeline utilities"

# vyg MCP registered for the user -> one extra Data platform line, nothing else changes.
printf '{"mcpServers":{"vyg-internal-mcp":{"type":"http","url":"https://example.invalid"}}}\n' > "$TMP/home/.claude.json"
HOME="$TMP/home" CLAUDE_PROJECT_DIR="$FIXTURE" bash "$HOOK" > "$TMP/with-vyg.txt" 2>/dev/null || fail "hook failed with vyg registered"
grep -q '^Data platform: vyg MCP connected' "$TMP/with-vyg.txt" || fail "vyg Data platform line missing when a vyg MCP is registered"
grep -v '^Data platform:' "$TMP/with-vyg.txt" | cmp -s "$EXPECTED" - || fail "vyg line changed the rest of the banner"
pass "vyg MCP registration adds exactly one Data platform line"
echo "inject-local-context-process-budget: ok"
