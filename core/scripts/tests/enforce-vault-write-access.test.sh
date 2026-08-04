#!/usr/bin/env bash
# hq-core: public
# Regression tests for enforce-vault-write-access.sh.
#
# Covers:
#   - Edit/Write/NotebookEdit/MultiEdit mutations under companies/<slug>/ are
#     blocked when the .hq/vault-access.json manifest gives the caller only
#     read (or no) permission on that vault path, and allowed on write grants;
#   - grant matching semantics: "*", "prefix/*" (including the bare prefix
#     dir itself), exact keys, and most-specific-wins (a specific read grant
#     carves a broader write grant down, and vice versa);
#   - fail-open behavior: missing manifest, unparseable manifest, company not
#     in manifest, role owner/admin/unknown, enforced=false;
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
HOOK="$TMP/.claude/hooks/enforce-vault-write-access.sh"
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
        { "path": "private/*", "permission": "read" }
      ]
    },
    "beta": { "role": "owner", "grants": [] },
    "gamma": { "role": "member", "enforced": false, "grants": [] },
    "delta": { "role": "unknown", "grants": [] },
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
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq "$expect" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [$label]: expected exit $expect, got $rc" >&2
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

# --- Fail-open paths ------------------------------------------------------
run 0 Edit file_path "$TMP/companies/beta/x.md"     'owner role fail-open'
run 0 Edit file_path "$TMP/companies/gamma/x.md"    'enforced=false fail-open'
run 0 Edit file_path "$TMP/companies/delta/x.md"    'unknown role fail-open'
run 0 Edit file_path "$TMP/companies/ghost/x.md"    'company absent from manifest fail-open'
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
run 0 Edit file_path "$A/private/notes.md"          'unparseable manifest fail-open'
rm -f "$TMP/.hq/vault-access.json"
run 0 Edit file_path "$A/private/notes.md"          'missing manifest fail-open'
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
