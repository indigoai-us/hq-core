#!/usr/bin/env bash
# hq-core: public
# Regression tests for enforce-vault-write-access.sh.
#
# Covers:
#   - Edit/Write/NotebookEdit/MultiEdit mutations under companies/<slug>/ are
#     blocked when the .hq/vault-access.json manifest gives the caller only
#     read (or no) permission on that vault path, and allowed on write grants;
#   - grant matching semantics: "*", "prefix/*" (including the bare prefix
#     dir itself), "prefix/" private folders (write covers direct children
#     only; read covers none), exact keys, and most-specific-wins (a specific read grant
#     carves a broader write grant down, and vice versa);
#   - fail-open behavior: missing manifest and known owner/admin roles;
#     unknown roles, absent companies, and malformed manifests preserve the
#     default-off behavior and are denied only when the hq-flags gate is on;
#   - Bash coverage: rm/mv/sed -i/tee/redirects into denied paths blocked;
#     reads and cp FROM a read-only path allowed; bare-relative companies/
#     tokens exempt inside a repos/ checkout context;
#   - companies/manifest.yaml and companies/_template/ exemptions;
#   - the settings.local.json HQ_BYPASS_VAULT_WRITE_PROTECT escape hatch.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/enforce-vault-write-access.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

mkdir -p "$TMP/.claude" "$TMP/.hq" "$TMP/core/scripts" \
  "$TMP/companies/acme/reports" "$TMP/companies/acme/private" \
  "$TMP/companies/beta" "$TMP/companies/_template"
cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/hook-lib.sh"
mkdir -p "$TMP/.claude/hooks"
cp "$HOOK" "$TMP/.claude/hooks/enforce-vault-write-access.sh"
cp "$ROOT/.claude/hooks/enforce-vault-write-access-flag.cjs" "$TMP/.claude/hooks/"
HOOK="$TMP/.claude/hooks/enforce-vault-write-access.sh"
CLI="$TMP/npm-global/lib/node_modules/@indigoai-us/hq-cli"
mkdir -p "$CLI/bin" "$CLI/node_modules/@indigoai-us/hq-flags-client" \
  "$CLI/node_modules/@indigoai-us/hq-cloud" "$TMP/bin"
printf '%s\n' '{"name":"@indigoai-us/hq-cli","bin":{"hq":"bin/hq"}}' > "$CLI/package.json"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$CLI/bin/hq"
chmod +x "$CLI/bin/hq"
ln -s "$CLI/bin/hq" "$TMP/bin/hq"
printf '%s\n' '{"type":"module","exports":{".":{"import":"./index.js"}}}' \
  > "$CLI/node_modules/@indigoai-us/hq-flags-client/package.json"
cat > "$CLI/node_modules/@indigoai-us/hq-flags-client/index.js" <<'JS'
export const createFlagClient = () => ({
  ready: async () => {
    if (process.env.HQ_TEST_FLAG_ERROR === "true") throw new Error("test registry unavailable");
  },
  snapshot: () => ({flags: process.env.HQ_TEST_FLAG_MISSING === "true" ? {} : {
    "hooks.vault-write-deny-unknown-access": process.env.HQ_TEST_FLAG_ENABLED === "true",
  }}),
  close: () => {},
});
JS
printf '%s\n' '{"type":"module","exports":{".":{"import":"./index.js"}}}' \
  > "$CLI/node_modules/@indigoai-us/hq-cloud/package.json"
printf '%s\n' 'export const loadCachedTokens = () => ({idToken:"test-token"});' \
  > "$CLI/node_modules/@indigoai-us/hq-cloud/index.js"
printf '{}' > "$TMP/.claude/settings.local.json"   # no bypass by default

write_manifest() {
  cat > "$TMP/.hq/vault-access.json" <<'EOF'
{
  "version": 1,
  "companies": {
    "acme": {
      "role": "member",
      "enforced": true,
      "grants": [
        { "path": "reports/*", "permission": "write" },
        { "path": "reports/locked/*", "permission": "read" },
        { "path": "docs/plan.md", "permission": "read" },
        { "path": "docs/open.md", "permission": "write" },
        { "path": "private/*", "permission": "read" },
        { "path": "dropbox/", "permission": "write" },
        { "path": "reports/peek/", "permission": "read" }
      ]
    },
    "beta": { "role": "owner", "grants": [] },
    "gamma": { "role": "member", "enforced": false, "grants": [] },
    "delta": { "role": "unknown", "grants": [] },
    "epsilon": { "role": "unknown", "enforced": false, "grants": [] },
    "wild": {
      "role": "member",
      "grants": [
        { "path": "*", "permission": "write" },
        { "path": "frozen/*", "permission": "read" }
      ]
    }
  }
}
EOF
}
write_manifest

PASS=0
FAIL=0

# run <expected_exit> <tool> <key> <value> <label>
run() {
  local expect="$1" tool="$2" key="$3" value="$4" label="$5" rc=0 payload
  payload=$(jq -n --arg t "$tool" --arg k "$key" --arg v "$value" \
    '{tool_name: $t, tool_input: {($k): $v}}')
  printf '%s' "$payload" | env PATH="$TMP/bin:$PATH" HQ_FLAGS_API_URL=https://flags.invalid \
    HQ_COMPANY_UID=cmp_test123 HQ_COMPANY_SLUG=indigo \
    CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq "$expect" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [$label]: expected exit $expect, got $rc" >&2
  fi
}
run_flag() {
  local expect="$1" enabled="$2" slug="$3" label="$4" registry_error="${5:-false}" rc=0 payload output
  payload=$(jq -n --arg p "$TMP/companies/$slug/x.md" \
    '{tool_name: "Edit", tool_input: {file_path: $p}}')
  output=$(printf '%s' "$payload" | env PATH="$TMP/bin:$PATH" HQ_FLAGS_API_URL=https://flags.invalid \
    HQ_COMPANY_UID=cmp_test123 HQ_COMPANY_SLUG=indigo HQ_TEST_FLAG_ENABLED="$enabled" \
    HQ_TEST_FLAG_ERROR="$registry_error" \
    CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>&1 >/dev/null) || rc=$?
  if [[ "$rc" -eq "$expect" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [$label]: expected exit $expect, got $rc; stderr=$output" >&2
  fi
}
run_unknown_message() {
  local payload output rc=0
  payload=$(jq -n --arg p "$TMP/companies/delta/x.md" \
    '{tool_name: "Edit", tool_input: {file_path: $p}}')
  output=$(printf '%s' "$payload" | env PATH="$TMP/bin:$PATH" HQ_FLAGS_API_URL=https://flags.invalid \
    HQ_COMPANY_UID=cmp_test123 HQ_COMPANY_SLUG=indigo HQ_TEST_FLAG_ENABLED=true \
    CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>&1 >/dev/null) || rc=$?
  if [[ "$rc" -eq 2 && "$output" == *"Run HQ sync or"* && "$output" == *"sign in again"* ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [unknown role recovery guidance]: expected exit 2 and sync/sign-in guidance, got exit $rc" >&2
  fi
}

A="$TMP/companies/acme"
W="$TMP/companies/wild"

# --- Edit/Write/NotebookEdit: grant matrix --------------------------------
run 0 Edit  file_path "$A/reports/q3.md"            'edit write-granted subtree allowed'
run 2 Edit  file_path "$A/reports/locked/x.md"      'specific read grant carves broader write (blocked)'
run 2 Edit  file_path "$A/private/notes.md"         'edit read-only subtree blocked'
run 2 Edit  file_path "$A/docs/plan.md"             'edit exact read-only key blocked'
run 0 Edit  file_path "$A/docs/open.md"             'edit exact write key allowed'
run 2 Write file_path "$A/ungrant/x.md"             'write to ungranted path blocked'
run 2 NotebookEdit notebook_path "$A/private/n.ipynb" 'notebook edit read-only blocked'
run 2 MultiEdit file_path "$A/private/multi.md"     'multiedit read-only blocked'
run 0 Edit  file_path "$W/anything/x.md"            'star write grant allows anywhere'
run 2 Edit  file_path "$W/frozen/x.md"              'specific read carve under star write blocked'
# Private create-only folder rows ("foo/", hq-pro #3662)
run 0 Write file_path "$A/dropbox/new.md"           'private-folder write allows direct child'
run 2 Write file_path "$A/dropbox/sub/new.md"       'private-folder write does not cover nested path'
run 0 Edit  file_path "$A/reports/peek/x.md"        'private-folder read does not carve broader write'

# --- Known bypass and unknown-role paths --------------------------------
run 0 Edit file_path "$TMP/companies/beta/x.md"     'owner role fail-open'
run 0 Edit file_path "$TMP/companies/gamma/x.md"    'enforced=false fail-open'
run_flag 0 false delta 'unknown role allowed with default-off flag'
run_flag 0 false ghost 'absent company allowed with default-off flag'
run_flag 2 true delta 'unknown role denied with flag on'
run_flag 2 true ghost 'absent company denied with flag on'
run_flag 0 true epsilon 'enforced=false unknown role bypasses when flag on'
run_unknown_message
run 0 Edit file_path "$TMP/workspace/n.md"          'path outside companies/ ignored'
run 0 Edit file_path "$TMP/companies/manifest.yaml" 'companies/manifest.yaml exempt'
run 0 Edit file_path "$TMP/companies/_template/k.md" 'companies/_template exempt'
run 0 Grep file_path "$A/private/notes.md"          'non-mutating tool ignored'

# --- Bash: denied mutations ----------------------------------------------
runb() { run "$1" Bash command "$2" "$3"; }
runb 2 "rm -rf $A/private/notes.md"                 'bash rm denied file blocked'
runb 2 "rm -rf $A/private"                          'bash rm denied dir (bare prefix) blocked'
runb 2 "echo hi > $A/private/new.md"                'bash redirect into denied path blocked'
runb 2 "printf x >> $A/private/log.md"              'bash append into denied path blocked'
runb 2 "mv $A/private/a.md /tmp/a.md"               'bash mv out of denied path blocked'
runb 2 "cp /tmp/a.md $A/private/a.md"               'bash cp into denied path blocked'
runb 2 "sed -i s/a/b/ $A/private/a.md"              'bash sed -i denied path blocked'
runb 2 "echo x | tee $A/private/a.md"               'bash tee denied path blocked'
runb 2 "touch $A/private/new.md"                    'bash touch denied path blocked'
runb 2 "rm companies/acme/private/a.md"             'bash bare-relative denied path blocked'
runb 2 'rm $CLAUDE_PROJECT_DIR/companies/acme/private/a.md' 'bash $CLAUDE_PROJECT_DIR form blocked'
runb 2 "true && rm $A/private/a.md"                 'bash chained segment blocked'
runb 2 "rm -rf $A"                                  'bash rm whole company dir blocked'

# --- Bash: allowed --------------------------------------------------------
runb 0 "rm $A/reports/old.md"                       'bash rm write-granted allowed'
runb 0 "echo hi >> $A/reports/log.md"               'bash append write-granted allowed'
runb 0 "cat $A/private/a.md"                        'bash read of read-only path allowed'
runb 0 "cp $A/private/a.md /tmp/a.md"               'bash cp FROM read-only path allowed'
runb 0 "grep -r pattern $A/private/"                'bash grep read-only path allowed'
runb 0 "cd repos/private/hq-core-staging && rm companies/acme/private/a.md" \
                                                    'bash bare-relative inside repo checkout allowed'
runb 0 "rm $TMP/companies/beta/x.md"                'bash rm owner company allowed'
runb 0 "rm /tmp/companies/acme/private/a.md"        'bash foreign absolute companies path ignored'
runb 0 "ls $A/private"                              'bash non-write op allowed'

# --- Manifest edge cases --------------------------------------------------
printf 'not json' > "$TMP/.hq/vault-access.json"
run_flag 0 false acme 'malformed manifest allowed with default-off flag'
run_flag 2 true acme 'malformed manifest denied with flag on'
run_flag 0 true delta 'registry outage falls back to default off' true
rm -f "$TMP/.hq/vault-access.json"
run 0 Edit file_path "$A/private/notes.md"          'missing manifest allowed for fresh install'
write_manifest

# --- Bypass escape hatch --------------------------------------------------
printf '{"env":{"HQ_BYPASS_VAULT_WRITE_PROTECT":"1"}}' > "$TMP/.claude/settings.local.json"
run 0 Edit file_path "$A/private/notes.md"          'settings.local.json bypass honored'
runb 0 "rm -rf $A/private"                          'bypass honored for bash too'
printf '{}' > "$TMP/.claude/settings.local.json"
run 2 Edit file_path "$A/private/notes.md"          'protection restored after bypass removed'

# --- hook-gate routing: the hook must fire under ALL THREE profiles --------
# (policy hq-hook-gate-three-profile-lists: a safety hook present in only one
# profile list silently no-ops under the others.)
GATE="$ROOT/.claude/hooks/hook-gate.sh"
DENY_PAYLOAD=$(jq -n --arg p "$A/private/notes.md" \
  '{tool_name: "Edit", tool_input: {file_path: $p}}')
for profile in minimal standard strict; do
  rc=0
  printf '%s' "$DENY_PAYLOAD" \
    | HQ_HOOK_PROFILE="$profile" CLAUDE_PROJECT_DIR="$TMP" \
      bash "$GATE" enforce-vault-write-access "$HOOK" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [gate profile $profile]: expected exit 2 through hook-gate, got $rc" >&2
  fi
done
# And HQ_DISABLED_HOOKS must still disable it cleanly.
rc=0
printf '%s' "$DENY_PAYLOAD" \
  | HQ_HOOK_PROFILE=standard HQ_DISABLED_HOOKS=enforce-vault-write-access \
    CLAUDE_PROJECT_DIR="$TMP" \
    bash "$GATE" enforce-vault-write-access "$HOOK" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "FAIL [gate disabled-hooks passthrough]: expected exit 0, got $rc" >&2
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
