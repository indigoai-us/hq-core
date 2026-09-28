#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/resolve-company-ambiguity.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() {
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

mkdir -p "$TMP/core/scripts" "$TMP/companies" "$TMP/bin"
cp "$ROOT/core/scripts/resolve-company.sh" "$TMP/core/scripts/"
chmod +x "$TMP/core/scripts/resolve-company.sh"
cat > "$TMP/companies/manifest.yaml" <<'YAML'
companies:
  cmp_FIXTURE:
    name: Uppercase synthetic ID
  cmp_fixture:
    name: Lowercase synthetic ID
YAML
cat > "$TMP/bin/hq" <<'HQ'
#!/usr/bin/env bash
exit 0
HQ
chmod +x "$TMP/bin/hq"

unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID
unset HQ_DEFAULT_COMPANY_JSON HQ_DEFAULT_PREFLIGHT_JSON
export HQ_HQ_SESSION_NO_CLI=1
out="$(PATH="$TMP/bin:$PATH" bash "$TMP/core/scripts/resolve-company.sh" --root "$TMP" --prompt 'open cmp_FIXTURE status' </dev/null)"
company="$(printf '%s' "$out" | sed -E 's/.*"company":"([^"]*)".*/\1/')"
source="$(printf '%s' "$out" | sed -E 's/.*"source":"([^"]*)".*/\1/')"
assert_eq "$company" "" "case-fold collision does not select a company"
assert_eq "$source" "none" "ambiguous prompt source"
echo "PASS: resolver refuses case-fold collisions between company IDs"
