#!/usr/bin/env bash
# hq-core: public
# Regression tests for refresh-vault-access.sh, using a stubbed `hq` CLI so no
# network or auth is needed. Verifies:
#   - shared-with-me table parsing → grants entries per company;
#   - role resolution from `hq members --company <slug> list` via the caller's
#     email (HQ_VAULT_ACCESS_EMAIL override);
#   - unknown role fallback when the email is not in the member table;
#   - manifest shape consumed by enforce-vault-write-access.sh.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$ROOT/core/scripts/refresh-vault-access.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

mkdir -p "$TMP/hqroot/core" "$TMP/hqroot/.claude" "$TMP/bin"

# Stubbed hq CLI: emits the real CLI's padded-table formats.
cat > "$TMP/bin/hq" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "whoami")
    echo "Signed in as tester@example.com (session expires later)"
    ;;
  "files shared-with-me")
    printf 'COMPANY  PATH             PERMISSION  SOURCE\n'
    printf '───────  ───────────────  ──────────  ──────\n'
    printf 'acme     reports/*        write       direct\n'
    printf 'acme     private/*        read        direct\n'
    printf 'other    docs/plan.md     read        group\n'
    ;;
  "members --company acme list")
    printf 'EMAIL                ROLE    NAME\n'
    printf 'tester@example.com   member  Tester\n'
    printf 'owner@example.com    owner   Owner\n'
    ;;
  "members --company other list")
    # tester's email absent -> role must resolve to unknown
    printf 'EMAIL              ROLE   NAME\n'
    printf 'owner@example.com  owner  Owner\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$TMP/bin/hq"

PATH="$TMP/bin:$PATH" HQ_VAULT_ACCESS_EMAIL="" \
  bash "$SCRIPT" --root "$TMP/hqroot" >/dev/null 2>&1

MANIFEST="$TMP/hqroot/.hq/vault-access.json"
PASS=0
FAIL=0
check() { # label jq-expr expected
  local label="$1" expr="$2" want="$3" got
  got="$(jq -r "$expr" "$MANIFEST" 2>/dev/null || echo '<jq-error>')"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [$label]: $expr → '$got', want '$want'" >&2
  fi
}

[[ -f "$MANIFEST" ]] || { echo "FAIL: manifest not written" >&2; exit 1; }

check "version"                 '.version'                                        '1'
check "acme role from members"  '.companies.acme.role'                            'member'
check "other role unknown"      '.companies.other.role'                           'unknown'
check "acme grant count"        '.companies.acme.grants | length'                 '2'
check "acme write grant"        '.companies.acme.grants[] | select(.path == "reports/*") | .permission' 'write'
check "acme read grant"         '.companies.acme.grants[] | select(.path == "private/*") | .permission' 'read'
check "other exact-key grant"   '.companies.other.grants[0].path'                 'docs/plan.md'

# The manifest must round-trip through the hook's own permission logic.
mkdir -p "$TMP/hqroot/.hq" "$TMP/hqroot/core/scripts" "$TMP/hqroot/.claude/hooks" \
  "$TMP/hqroot/companies/acme"
cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/hqroot/core/scripts/hook-lib.sh"
cp "$ROOT/.claude/hooks/enforce-vault-write-access.sh" "$TMP/hqroot/.claude/hooks/"
printf '{}' > "$TMP/hqroot/.claude/settings.local.json"
hook_rc() {
  local path="$1" rc=0
  jq -n --arg p "$path" '{tool_name: "Edit", tool_input: {file_path: $p}}' \
    | CLAUDE_PROJECT_DIR="$TMP/hqroot" bash "$TMP/hqroot/.claude/hooks/enforce-vault-write-access.sh" \
      >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
[[ "$(hook_rc "$TMP/hqroot/companies/acme/reports/q3.md")" == "0" ]] \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL [roundtrip write grant allows]" >&2; }
[[ "$(hook_rc "$TMP/hqroot/companies/acme/private/x.md")" == "2" ]] \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL [roundtrip read grant blocks]" >&2; }
[[ "$(hook_rc "$TMP/hqroot/companies/other/docs/plan.md")" == "0" ]] \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL [roundtrip unknown role fail-open]" >&2; }

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
