#!/usr/bin/env bash
# Tests for resolve-company.sh — session bind only (US-011 removed prompt-slug).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

mkdir -p "$TMP/core/scripts" "$TMP/companies" "$TMP/workspace/sessions"
cp "$ROOT/core/scripts/resolve-company.sh" "$TMP/core/scripts/resolve-company.sh"
cp "$ROOT/core/scripts/hq-session.sh" "$TMP/core/scripts/hq-session.sh"
cp -R "$ROOT/core/scripts/lib" "$TMP/core/scripts/lib"
chmod +x "$TMP/core/scripts/resolve-company.sh" "$TMP/core/scripts/hq-session.sh"

cat > "$TMP/companies/manifest.yaml" <<'YAML'
companies:
  _template:
    name: Template
  acme:
    name: Acme Corp
  globex:
    name: Globex
YAML

unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID
export HQ_HQ_SESSION_NO_CLI=1

resolve() {
  bash "$TMP/core/scripts/resolve-company.sh" --root "$TMP" --prompt "$1" </dev/null
}

company_of() { printf '%s' "$1" | sed -E 's/.*"company":"([^"]*)".*/\1/'; }
source_of()  { printf '%s' "$1" | sed -E 's/.*"source":"([^"]*)".*/\1/'; }

# --- Prompt slug path REMOVED: free text never selects a company ---
out="$(resolve 'fix the globex morning flash renderer bug')"
assert_eq "$(company_of "$out")" "" "prompt slug globex ignored"
assert_eq "$(source_of "$out")" "none" "prompt source is none"

out="$(resolve 'acme fix the standup brief links')"
assert_eq "$(company_of "$out")" "" "first-word slug ignored"

out="$(resolve 'ok really will fix sync try now please')"
assert_eq "$(company_of "$out")" "" "misfile ok prompt chooses no company"

out="$(resolve 'walk through how the work mesh is set up')"
assert_eq "$(company_of "$out")" "" "misfile walkthrough chooses no company"

out="$(resolve 'version')"
assert_eq "$(company_of "$out")" "" "version prompt chooses no company"

# Ghost dir still irrelevant
mkdir -p "$TMP/companies/ok/projects/junk"
out="$(resolve 'ok really will fix sync try now please')"
assert_eq "$(company_of "$out")" "" "ghost companies/ok ignored"
rm -rf "$TMP/companies/ok"

# Empty / missing safe
out="$(resolve '')"
assert_eq "$(company_of "$out")" "" "empty prompt"
assert_eq "$(source_of "$out")" "none" "empty source"
set +e
bash "$TMP/core/scripts/resolve-company.sh" --root "$TMP" --prompt "" </dev/null >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" "0" "empty exits 0"

# --- Session bind still wins ---
printf 'sess-1\n' > "$TMP/workspace/sessions/.current"
mkdir -p "$TMP/workspace/sessions/sess-1"
printf 'company_slug: acme\n' > "$TMP/workspace/sessions/sess-1/meta.yaml"

out="$(resolve 'fix the globex morning flash renderer bug')"
assert_eq "$(company_of "$out")" "acme" "session bind applies"
assert_eq "$(source_of "$out")" "session" "session source"

out="$(resolve 'no company named here at all')"
assert_eq "$(company_of "$out")" "acme" "session bind with no prompt slug"

# Unknown session slug falls through to none (no prompt fallback)
printf 'company_slug: ghostco\n' > "$TMP/workspace/sessions/sess-1/meta.yaml"
out="$(resolve 'fix the globex renderer')"
assert_eq "$(company_of "$out")" "" "unknown session slug → none"
assert_eq "$(source_of "$out")" "none" "unknown session source none"

printf '' > "$TMP/workspace/sessions/sess-1/meta.yaml"
out="$(resolve 'fix the globex renderer')"
assert_eq "$(company_of "$out")" "" "empty meta → none"

echo "resolve-company: ok"
