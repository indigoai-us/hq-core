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
#   - Bash coverage: rm/mv/cp/mkdir/install/sed -i/tee/redirects into denied
#     paths blocked, including quoted paths, ~/ and $HOME forms, subshells,
#     line continuations, and targets relative to the cwd or a cd;
#     reads and cp FROM a read-only path allowed; bare-relative companies/
#     tokens exempt inside a repos/ checkout context;
#   - companies/manifest.yaml and companies/_template/ exemptions;
#   - the settings.local.json HQ_BYPASS_VAULT_WRITE_PROTECT escape hatch.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
# The shell that runs the hook. On macOS the suite re-runs itself under
# /bin/bash (3.2), the shell hooks get there, so bash 3.2-only failures show.
HOOK_BASH="${HOOK_BASH:-bash}"
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
        { "path": "reports/peek/", "permission": "read" },
        { "path": "bare", "permission": "write" }
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
    CLAUDE_PROJECT_DIR="$TMP" "$HOOK_BASH" "$HOOK" >/dev/null 2>&1 || rc=$?
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
    CLAUDE_PROJECT_DIR="$TMP" "$HOOK_BASH" "$HOOK" 2>&1 >/dev/null) || rc=$?
  if [[ "$rc" -eq "$expect" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [$label]: expected exit $expect, got $rc; stderr=$output" >&2
  fi
}
# An exact-key grant ("bare", no trailing "/" or "/*") above the denied path is
# named in the block message with the folder-glob share command (feedback
# DEV-5173: an admin shared "knowledge" and members were blocked under it).
run_near_miss_message() {
  local payload output rc=0
  payload=$(jq -n --arg p "$TMP/companies/acme/bare/new.md" \
    '{tool_name: "Write", tool_input: {file_path: $p}}')
  output=$(printf '%s' "$payload" | env PATH="$TMP/bin:$PATH" HQ_FLAGS_API_URL=https://flags.invalid \
    HQ_COMPANY_UID=cmp_test123 HQ_COMPANY_SLUG=indigo \
    CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>&1 >/dev/null) || rc=$?
  if [[ "$rc" -eq 2 && "$output" == *"exact-key grant"* && "$output" == *"  bare (write)"* \
        && "$output" == *"hq files share 'bare/*' --with <you> --permission write"* ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [exact-key near-miss guidance]: expected exit 2 with the folder-glob share hint, got exit $rc; stderr=$output" >&2
  fi
}
run_no_near_miss_message() {
  local payload output rc=0
  payload=$(jq -n --arg p "$TMP/companies/acme/ungrant/x.md" \
    '{tool_name: "Write", tool_input: {file_path: $p}}')
  output=$(printf '%s' "$payload" | env PATH="$TMP/bin:$PATH" HQ_FLAGS_API_URL=https://flags.invalid \
    HQ_COMPANY_UID=cmp_test123 HQ_COMPANY_SLUG=indigo \
    CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>&1 >/dev/null) || rc=$?
  if [[ "$rc" -eq 2 && "$output" != *"Near miss"* ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [no near-miss hint without an exact-key grant above]: got exit $rc; stderr=$output" >&2
  fi
}
run_unknown_message() {
  local payload output rc=0
  payload=$(jq -n --arg p "$TMP/companies/delta/x.md" \
    '{tool_name: "Edit", tool_input: {file_path: $p}}')
  output=$(printf '%s' "$payload" | env PATH="$TMP/bin:$PATH" HQ_FLAGS_API_URL=https://flags.invalid \
    HQ_COMPANY_UID=cmp_test123 HQ_COMPANY_SLUG=indigo HQ_TEST_FLAG_ENABLED=true \
    CLAUDE_PROJECT_DIR="$TMP" "$HOOK_BASH" "$HOOK" 2>&1 >/dev/null) || rc=$?
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
# Exact-key rows ("bare") cover the named object only, never the subtree.
run 0 Edit  file_path "$A/bare"                     'exact-key write grant allows the object itself'
run 2 Write file_path "$A/bare/new.md"              'exact-key write grant does not cover the subtree'
run_near_miss_message
run_no_near_miss_message

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

# --- Bash: copy/create forms that used to slip past (feedback acbf130d) -----
# runc <expected_exit> <cwd> <command> <label> — Bash payload with a cwd field.
runc() {
  local expect="$1" cwd="$2" cmd="$3" label="$4" rc=0 payload
  payload=$(jq -n --arg c "$cmd" --arg d "$cwd" \
    '{tool_name: "Bash", cwd: $d, tool_input: {command: $c}}')
  printf '%s' "$payload" | env PATH="$TMP/bin:$PATH" HOME="$(dirname "$TMP")" \
    CLAUDE_PROJECT_DIR="$TMP" "$HOOK_BASH" "$HOOK" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq "$expect" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [$label]: expected exit $expect, got $rc" >&2
  fi
}
HB="$(basename "$TMP")"
runb 2 "cp /tmp/a.md \"$A/private/a b.md\""         'bash cp into quoted path with a space blocked'
runb 2 "cd $A && cp /tmp/a.md private/a.md"         'bash cd into company then relative cp blocked'
runb 2 "cd companies/acme && cp /tmp/a.md private/a.md" 'bash cd relative company then cp blocked'
runb 2 "cd companies/acme && mkdir private/new"     'bash cd company then mkdir blocked'
runc 2 "$TMP" "cp /tmp/a.md ~/$HB/companies/acme/private/a.md" 'bash cp into ~/ form blocked'
runc 2 "$TMP" "cp /tmp/a.md \$HOME/$HB/companies/acme/private/a.md" 'bash cp into $HOME form blocked'
runc 2 "$TMP" "cp /tmp/a.md \${HOME}/$HB/companies/acme/private/a.md" 'bash cp into ${HOME} form blocked'
runb 2 "(cp /tmp/a.md $A/private/a.md)"             'bash cp inside subshell blocked'
runb 2 "/bin/cp /tmp/a.md $A/private/a.md"          'bash absolute /bin/cp blocked'
runb 2 "install -m 644 /tmp/a.md $A/private/a.md"   'bash install into denied path blocked'
runb 2 "cp /tmp/a.md \\
  $A/private/a.md"                                  'bash cp with line continuation blocked'
runc 2 "$A" "cp /tmp/a.md private/a.md"             'bash cp relative to cwd inside company blocked'
runc 2 "$A/private" "echo x > note.md"              'bash redirect relative to cwd inside read-only dir blocked'
runc 0 "$A" "cp /tmp/a.md reports/a.md"             'bash cp relative to cwd into write grant allowed'
runc 0 "$A" "cat private/a.md"                      'bash read relative to cwd allowed'
runc 0 "$TMP" "cp /tmp/a.md notes.md"               'bash relative cp at HQ root ignored'
runc 0 "$A" "echo \"a>private/x\""                  'bash quoted > is not a redirect'
runb 0 "cd /tmp && cp a.md companies/acme/private/a.md" 'bash cd elsewhere then relative companies/ ignored'
runb 0 "cp $A/private/a.md \"/tmp/a b.md\""         'bash cp FROM read-only to quoted path allowed'
# Review on #1506: ../ climbs, grouped/glued -t, >| and long commands.
runc 2 "$TMP/workspace" "cp /tmp/a.md ../companies/acme/private/a.md" 'bash ../ climb into read-only path blocked'
runc 0 "$TMP/workspace" "cp /tmp/a.md ../notes.md" 'bash ../ climb outside companies allowed'
runb 2 "cp -rt $A/private /tmp/a /tmp/b"            'bash cp grouped -rt target blocked'
runb 2 "cp -t$A/private /tmp/a"                     'bash cp glued -tDIR target blocked'
runb 0 "rsync -rt $A/private/a.md /tmp/a.md"        'bash rsync -rt is --times, source not a target'
runb 2 "echo x >| $A/private/a.md"                  'bash >| noclobber redirect blocked'
runc 0 "$A/private" "echo x 2>/dev/null"            'bash 2>/dev/null inside read-only dir allowed'
runc 0 "$A/private" "echo x >&2"                    'bash >&2 inside read-only dir allowed'
LONG="$(printf 'x%.0s' $(seq 1 6000))"
runb 2 "echo $LONG && cp /tmp/a.md $A/private/a.md" 'bash write after a long segment blocked'
runb 2 "echo $LONG > $A/private/a.md"               'bash long segment redirect blocked'
runb 0 "echo $LONG > /tmp/long.txt"                 'bash long segment outside vault allowed'
# Bounded time: a 40,000-character one-line command with a companies/ token
# must finish well inside the hook timeout (was ~22 s under bash 3.2).
BIG="$(printf 'ab\"c d é %.0s' $(seq 1 4000))"
start=$SECONDS
runb 0 "python3 -c 'print(1)' $BIG companies/acme/reports/x" 'bash 40k-char command allowed'
runb 0 "echo \"$(printf 'é%.0s' $(seq 1 2000))\" > $A/reports/x.md" 'bash 2k multibyte quoted segment parsed'
elapsed=$((SECONDS - start))
if [[ "$elapsed" -le 5 ]]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "FAIL [bash long command bounded time]: took ${elapsed}s" >&2
fi

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

echo "PASS=$PASS FAIL=$FAIL (hook shell: $HOOK_BASH)"
[[ "$FAIL" -eq 0 ]] || exit 1
if [[ "$HOOK_BASH" == "bash" && -x /bin/bash && "$(uname -s)" == "Darwin" ]]; then
  HOOK_BASH=/bin/bash bash "${BASH_SOURCE[0]}"
fi
exit 0
