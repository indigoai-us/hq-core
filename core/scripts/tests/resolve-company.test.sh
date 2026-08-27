#!/usr/bin/env bash
# Tests for resolve-company.sh — the shared company resolver.
#
# Guards the defect class found 2026-07-26: company detection read only the
# first word of a prompt, and the company bound by /startwork was never read
# back at all.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

# --- sandbox HQ root ------------------------------------------------------
mkdir -p "$TMP/core/scripts" "$TMP/companies" "$TMP/workspace/sessions"
cp "$ROOT/core/scripts/resolve-company.sh" "$TMP/core/scripts/resolve-company.sh"
cp "$ROOT/core/scripts/hq-session.sh" "$TMP/core/scripts/hq-session.sh"
# hq-session.sh sources helpers from core/scripts/lib (e.g. session-id.sh,
# session-scope-capability.sh). Copy the whole lib dir so the sandbox does not
# rot the day hq-session.sh grows another dependency.
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
  initech:
    name: Initech
  harbor:
    name: Harbor
  umbrella:
    name: Umbrella
  zeta:
    name: Zeta
  zeta-labs:
    name: Zeta Labs
  acme_labs:
    name: Acme Labs
YAML

# Isolate from the caller's real HQ session: resolve-company delegates the
# session lookup to hq-session.sh, which reads an ambient session id from the
# environment before falling back to workspace/sessions/.current. Clearing
# those here makes the sandbox's .current the only session signal, so the test
# is identical whether it runs in CI or inside a live HQ session.
unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID
# Force the in-tree hq-session, not `hq core hq-session` which would read the
# live HQ session and ignore this sandbox's .current.
export HQ_HQ_SESSION_NO_CLI=1

resolve() {
  bash "$TMP/core/scripts/resolve-company.sh" --root "$TMP" --prompt "$1" </dev/null
}

company_of() { printf '%s' "$1" | sed -E 's/.*"company":"([^"]*)".*/\1/'; }
source_of()  { printf '%s' "$1" | sed -E 's/.*"source":"([^"]*)".*/\1/'; }

# --- prompt scan: anywhere in the sentence, not just the first word -------
# Each of these three resolved to "personal" before the fix.
out="$(resolve 'fix the globex morning flash renderer bug')"
assert_eq "$(company_of "$out")" "globex" "mid-sentence slug (globex)"
assert_eq "$(source_of "$out")" "prompt" "mid-sentence source"

out="$(resolve 'look at the acme standup brief and fix the missing links')"
assert_eq "$(company_of "$out")" "acme" "mid-sentence slug (acme)"

out="$(resolve 'work on the initech checkout flow')"
assert_eq "$(company_of "$out")" "initech" "mid-sentence slug (initech)"

# First-word matching must keep working.
out="$(resolve 'acme fix the standup brief links')"
assert_eq "$(company_of "$out")" "acme" "first-word slug still matches"

# Case-insensitive.
out="$(resolve 'Fix the GLOBEX renderer')"
assert_eq "$(company_of "$out")" "globex" "case-insensitive match"

# --- word-boundary safety -------------------------------------------------
# Several slugs are ordinary English words. A substring hit would misroute
# work into a tenant the user never named.
out="$(resolve 'update the harbor harbors page')"
assert_eq "$(company_of "$out")" "harbor" "harbor matches as a whole token"

out="$(resolve 'rewrite the harbors page')"
assert_eq "$(company_of "$out")" "" "harbor must not match inside harbors"

out="$(resolve 'umbrellas workshop notes')"
assert_eq "$(company_of "$out")" "" "umbrella must not match inside umbrellas"

# Underscores are legal in manifest slugs ([a-z0-9_-]); the tokenizer must
# preserve them so a free-text prompt naming an underscore slug still resolves.
out="$(resolve 'ship the acme_labs onboarding flow')"
assert_eq "$(company_of "$out")" "acme_labs" "underscore slug resolves from a prompt"
assert_eq "$(source_of "$out")" "prompt" "underscore slug source is prompt"

# --- longest slug wins, earliest breaks a tie -----------------------------
out="$(resolve 'compare zeta and zeta-labs numbers')"
assert_eq "$(company_of "$out")" "zeta-labs" "longest slug wins"

out="$(resolve 'zeta-labs versus zeta')"
assert_eq "$(company_of "$out")" "zeta-labs" "longest slug wins regardless of order"

# acme and zeta are both four characters — a genuine length tie.
out="$(resolve 'acme then zeta')"
assert_eq "$(company_of "$out")" "acme" "equal length ties break on earliest"

out="$(resolve 'zeta then acme')"
assert_eq "$(company_of "$out")" "zeta" "equal length ties break on earliest (reversed)"

# --- unknown and reserved slugs are rejected ------------------------------
out="$(resolve 'work on the acmecorp dashboard')"
assert_eq "$(company_of "$out")" "" "unknown slug rejected"

out="$(resolve '_template scaffolding pass')"
assert_eq "$(company_of "$out")" "" "_template is not a tenant"

# A leftover companies/<word> directory is not a tenant. "ok really…" used
# to misfile into companies/ok because auto-session-project stat'd that path.
mkdir -p "$TMP/companies/ok/projects/junk"
out="$(resolve 'ok really will fix sync try now please')"
assert_eq "$(company_of "$out")" "" "ghost companies/ok dir is not a tenant"
rmdir "$TMP/companies/ok/projects/junk" 2>/dev/null || true

out="$(resolve 'update unaffiliated_repos listing')"
assert_eq "$(company_of "$out")" "" "unaffiliated_repos is not a tenant"

# --- empty input is safe --------------------------------------------------
out="$(resolve '')"
assert_eq "$(company_of "$out")" "" "empty prompt resolves to none"
assert_eq "$(source_of "$out")" "none" "empty prompt source is none"

# Must never exit non-zero: hooks run under `set -e`.
set +e
bash "$TMP/core/scripts/resolve-company.sh" --root "$TMP" --prompt "" </dev/null >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" "0" "empty prompt exits 0"

set +e
bash "$TMP/core/scripts/resolve-company.sh" --root "$TMP/nonexistent" --prompt "acme" </dev/null >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" "0" "missing manifest exits 0"

# --- session bind beats the prompt ---------------------------------------
# The whole point of the fix: /startwork already told HQ where we are.
printf 'sess-1\n' > "$TMP/workspace/sessions/.current"
mkdir -p "$TMP/workspace/sessions/sess-1"
printf 'company_slug: acme\n' > "$TMP/workspace/sessions/sess-1/meta.yaml"

out="$(resolve 'fix the globex morning flash renderer bug')"
assert_eq "$(company_of "$out")" "acme" "session bind overrides a conflicting prompt slug"
assert_eq "$(source_of "$out")" "session" "session bind reports source=session"

out="$(resolve 'no company named here at all')"
assert_eq "$(company_of "$out")" "acme" "session bind applies with no prompt slug"

# A session bound to a slug that is not in the manifest is not trusted.
printf 'company_slug: ghostco\n' > "$TMP/workspace/sessions/sess-1/meta.yaml"
out="$(resolve 'fix the globex renderer')"
assert_eq "$(company_of "$out")" "globex" "unknown session slug falls through to prompt"
assert_eq "$(source_of "$out")" "prompt" "unknown session slug reports source=prompt"

# No bind at all falls through cleanly.
printf '' > "$TMP/workspace/sessions/sess-1/meta.yaml"
out="$(resolve 'fix the globex renderer')"
assert_eq "$(company_of "$out")" "globex" "empty meta falls through to prompt"

echo "resolve-company: ok"
