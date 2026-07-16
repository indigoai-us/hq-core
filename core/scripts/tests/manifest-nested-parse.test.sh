#!/usr/bin/env bash
# Regression test for nested companies/manifest.yaml parsing.
set -euo pipefail
command -v python3 >/dev/null 2>&1 || { echo "manifest-nested-parse: skipped (python3 missing)"; exit 0; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/inject-local-context.sh"
TITLE="$ROOT/core/scripts/session-title.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

pass() {
  PASS=$((PASS+1))
}

fail() {
  FAIL=$((FAIL+1))
  echo "FAIL[$1]: $2" >&2
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass
  else
    fail "$label" "missing '$needle'"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "$label" "unexpected '$needle'"
  else
    pass
  fi
}

assert_equals() {
  local got="$1" want="$2" label="$3"
  if [ "$got" = "$want" ]; then
    pass
  else
    fail "$label" "got '$got', want '$want'"
  fi
}

make_root() {
  local root="$1"
  mkdir -p "$root/companies"
}

MULTI="$TMP/multi"
make_root "$MULTI"
cat > "$MULTI/companies/manifest.yaml" <<'YAML'
companies:
  # Empty by default in templates; real installs add children here.
  _template:
    name: Template
    prefix: tmpl
  indigo:
    name: Indigo
    prefix: ind
    knowledge: companies/indigo/knowledge/
    qmd_collections:
    - indigo
  acme:
    name: Acme
    prefix: acme
    knowledge: companies/acme/knowledge/
    qmd_collections:
    - acme
metadata:
  generated: test
YAML

hook_rc=0
multi_out="$(CLAUDE_PROJECT_DIR="$MULTI" bash "$HOOK" 2>&1)" || hook_rc=$?
multi_companies="$(printf '%s\n' "$multi_out" | awk '/^Companies \(/ { print; exit }')"

assert_equals "$hook_rc" "0" "inject-local-context exits cleanly"
assert_contains "$multi_out" "<local-context>" "inject-local-context emits local-context"
assert_equals "$multi_companies" "Companies (2): indigo, acme" "multiple nested companies listed"
assert_contains "$multi_companies" "indigo" "indigo listed"
assert_contains "$multi_companies" "acme" "acme listed"
assert_not_contains "$multi_companies" "companies" "top-level companies key not listed"
assert_not_contains "$multi_companies" "_template" "_template excluded from hook output"

SINGLE="$TMP/single"
make_root "$SINGLE"
cat > "$SINGLE/companies/manifest.yaml" <<'YAML'
companies:
  # Leading comments are ignored.
  _template:
    name: Template
  indigo:
    name: Indigo
    prefix: ind
    qmd_collections:
    - indigo
settings:
  owner: test
YAML

title_rc=0
single_title="$(HQ_ROOT="$SINGLE" bash "$TITLE" --session-id "manifest-nested-parse-$$-single" 2>&1)" || title_rc=$?

assert_equals "$title_rc" "0" "session-title exits cleanly"
assert_contains "$single_title" "indigo" "session title uses the real single-company slug"
assert_not_contains "$single_title" "companies" "session title does not use top-level companies key"
assert_not_contains "$single_title" "_template" "_template excluded from session title"

EMPTY="$TMP/empty"
make_root "$EMPTY"
cat > "$EMPTY/companies/manifest.yaml" <<'YAML'
companies:
  # No companies configured yet.
other:
  value: ignored
YAML

empty_hook_rc=0
empty_out="$(CLAUDE_PROJECT_DIR="$EMPTY" bash "$HOOK" 2>&1)" || empty_hook_rc=$?
empty_title_rc=0
empty_title="$(HQ_ROOT="$EMPTY" bash "$TITLE" --session-id "manifest-nested-parse-$$-empty" 2>&1)" || empty_title_rc=$?

assert_equals "$empty_hook_rc" "0" "empty manifest hook exits cleanly"
assert_not_contains "$empty_out" "Companies (" "empty manifest emits no company line"
assert_equals "$empty_title_rc" "0" "empty manifest session-title exits cleanly"
assert_equals "$empty_title" "chat" "empty manifest leaves company unset"

echo "manifest-nested-parse: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
