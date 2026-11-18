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
cp "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" "$TMP/.claude/hooks/"
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
    CLAUDE_PROJECT_DIR="$TMP" "$HOOK_BASH" "$HOOK" >/dev/null 2>"$TMP/last-err" || rc=$?
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
# feedback_e9ee6aa4: ; inside python -c splits the command; HTML regex is not a vault path
runc 0 "$A" "python3 -c 'import re,sys; print(re.sub(\"<style.*?</style>\", \"\", sys.stdin.read()))'" \
                                                    'python regex after semicolon is not a vault path'
runc 0 "$A" "curl -s https://example.com | python3 -c 'import re,sys; print(re.sub(\"<style.*?</style>\", \"\", sys.stdin.read()))'" \
                                                    'curl piped to python regex cwd company allowed'
# Review on #1768: the regex skip must not open real paths with odd characters.
runb 2 "echo x > companies/acme/private/a,b.md"          'comma path in denied company dir blocks'
runb 2 "tee companies/acme/private/x*.md < /tmp/a"       'glob path in denied company dir blocks'
runb 2 "echo x > \"companies/acme/private/a;b.md\""      'quoted semicolon path in denied company dir blocks'
runb 2 "touch companies/acme/private/a?b.md"             'question-mark path in denied company dir blocks'
runc 2 "$A" "echo x > private/notes(1).md"          'paren name in read-only company dir blocks'
runc 2 "$A" "echo x > private/a+b.md"               'plus name in read-only company dir blocks'
runc 2 "$A" "echo x > private/@x.md"                'at name in read-only company dir blocks'
runc 2 "$A" "python3 -c 'x=1'; echo x > private/a,b.md" 'comma redirect after python -c blocks'
runb 2 "bash -c 'true; echo x > companies/acme/private/a,b.md'" 'write inside quoted -c after semicolon blocks'
# Second review on #1768: quote tracking must not drift, and a closed -c quote ends the skip.
runb 2 $'true # it\'s\necho x > \'companies/acme/private/a<b.md\'' 'apostrophe in comment does not skip next line'
runc 2 "$A/private" $'true # it\'s\necho x > _'       'apostrophe in comment then bare name in denied cwd blocks'
runb 2 "echo \$'it\\'s'; echo x > 'companies/acme/private/a<b.md'" 'ansi-c quote does not skip later segment'
runb 2 $'cat <<EOF\nit\'s\nEOF\necho x > \'companies/acme/private/a<b.md\'' 'apostrophe in heredoc does not skip later line'
runc 2 "$A/private" $'echo \'\npython3 -c \'a; echo x > _' 'quote spanning lines closed by -c quote still blocks'
runb 2 $'echo \'\npython3 -c \'a; echo x > \'companies/acme/private/a<b.md\'' 'quote spanning lines then lt name still blocks'
runc 2 "$A/private" $'cat <<E\nit\'s\nE\necho \'\npython3 -c \'a; echo x > _' 'heredoc apostrophe then spanning quote still blocks'
runc 2 "$A/private" "echo \"\$(echo '\" -c 'a; echo x > _)\"" 'command substitution in double quotes still blocks'
runc 2 "$A/private" "echo \"\`echo '\" -c 'a; echo x > _\`\"" 'backtick substitution in double quotes still blocks'
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
runb 0 'i=1; echo $((i+1))' 'missing manifest allows proven arithmetic'
runb 2 'echo $((unknown+1))' 'missing manifest still checks arithmetic'
write_manifest

# Decision-only arithmetic checks run before the companies/ fast path.
arith_case() {
  runb "$1" "$3" "arith-$2"
  if [ "$2" = redirect-only-before-proof ] && grep -q 'unbound variable' "$TMP/last-err"; then
    FAIL=$((FAIL+1))
    echo 'FAIL: allowed redirection/arithmetic control must not exit through a nounset error' >&2
  fi
}
. "$ROOT/core/scripts/tests/bash-arith-guard.cases.sh"
. "$ROOT/core/scripts/tests/bash-arith-resolver.cases.sh"
runb 2 'touch compan""ies/acme/private/notes.md' 'quote-split company prefix blocked'
runb 2 'touch compan\ies/acme/private/notes.md' 'escaped company prefix blocked'
mv "$TMP/.claude/hooks/bash-arith-subst-guard-lib.sh" "$TMP/arith-helper.saved"
runb 2 'echo hello' 'missing arithmetic helper fails closed'
mv "$TMP/arith-helper.saved" "$TMP/.claude/hooks/bash-arith-subst-guard-lib.sh"

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

# ── Case and spelling variants of companies/ (tenant-isolation bypass) ─────
# On case-insensitive filesystems (default macOS APFS, Windows NTFS)
# Companies/, COMPANIES/ and companies/Example-Co/ name the same files as
# companies/example-co/. Each spelling must get the same vault check, as must
# ./ and .. segments, repeated slashes, backslashes and drive letters.
jq '.companies["example-co"] = {"role": "member", "enforced": true,
      "grants": [{"path": "open/*", "permission": "write"},
                 {"path": "locked/*", "permission": "read"}]}' \
  "$TMP/.hq/vault-access.json" > "$TMP/.hq/vault-access.json.new"
mv "$TMP/.hq/vault-access.json.new" "$TMP/.hq/vault-access.json"
mkdir -p "$TMP/companies/example-co/locked" "$TMP/companies/example-co/open"
for spelled in Companies COMPANIES cOmPaNiEs; do
  run 2 Write file_path "$TMP/$spelled/example-co/locked/x.md" "write via $spelled/ blocked"
  run 2 Edit file_path "$spelled/example-co/locked/x.md" "relative edit via $spelled/ blocked"
  runb 2 "echo x > $spelled/example-co/locked/x.md" "bash redirect via $spelled/ blocked"
  runb 2 "rm $TMP/$spelled/example-co/locked/x.md" "bash rm via absolute $spelled/ blocked"
  runc 2 "$TMP/$spelled/example-co" "touch locked/x.md" "bash cwd inside $spelled/ blocked"
done
run 2 Write file_path "$TMP/companies/Example-Co/locked/x.md"    'write via mixed-case slug blocked'
run 2 Write file_path "$TMP/companies/example-co/LOCKED/x.md"    'write via upper-case grant dir blocked'
run 2 Write file_path "$TMP/COMPANIES/EXAMPLE-CO/LOCKED/x.md"    'write via all-upper path blocked'
run 2 Write file_path "$TMP/./Companies//example-co/./locked/x.md" 'write via ./ and // segments blocked'
run 2 Write file_path "$TMP/workspace/../Companies/example-co/locked/x.md" 'write via .. segment blocked'
run 0 Write file_path "$TMP/Companies/example-co/open/x.md"      'write grant still allowed via Companies/'
run 0 Write file_path "$TMP/COMPANIES/MANIFEST.yaml"              'manifest exemption case-insensitive'
run 0 Write file_path "$TMP/Companies/_Template/x.md"             '_template exemption case-insensitive'
runb 0 "cat $TMP/Companies/example-co/locked/x.md"                'bash read via Companies/ allowed'
# Windows spellings: backslashes (forced on any platform with HQ_LIB_WINSEP=1).
run_win() {
  local expect="$1" value="$2" label="$3" rc=0 payload
  payload=$(jq -n --arg v "$value" '{tool_name: "Write", tool_input: {file_path: $v}}')
  printf '%s' "$payload" | env HQ_LIB_WINSEP=1 CLAUDE_PROJECT_DIR="$TMP" \
    "$HOOK_BASH" "$HOOK" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq "$expect" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL [$label]: expected exit $expect, got $rc" >&2; fi
}
run_win 2 "${TMP}\\Companies\\example-co\\locked\\x.md" 'windows backslash path via Companies blocked'
run_win 2 'Companies\example-co\locked\x.md'            'windows relative backslash path blocked'
run_win 0 'Companies\example-co\open\x.md'              'windows relative backslash write grant allowed'
write_manifest

# Symlinks that point into another company's read-only folder.
jq '.companies["example-co"] = {"role": "member", "enforced": true,
      "grants": [{"path": "open/*", "permission": "write"},
                 {"path": "locked/*", "permission": "read"}]}' \
  "$TMP/.hq/vault-access.json" > "$TMP/.hq/vault-access.json.new"
mv "$TMP/.hq/vault-access.json.new" "$TMP/.hq/vault-access.json"
mkdir -p "$TMP/workspace" "$TMP/companies/wild"
ln -s "$TMP/companies/example-co/locked" "$TMP/workspace/to-locked"
ln -s "$TMP/companies/example-co/locked" "$TMP/companies/wild/to-locked"
ln -s "$TMP/companies/example-co/open" "$TMP/workspace/to-open"
# Git Bash without Windows symlink rights makes ln -s copy the target, so
# there is no link to resolve; these cases need a real symlink.
if [[ -L "$TMP/workspace/to-locked" ]]; then
run 2 Write file_path "$TMP/workspace/to-locked/x.md"        'write through symlink outside companies/ blocked'
run 2 Write file_path "$TMP/companies/wild/to-locked/x.md"   'write through symlink from a writable company blocked'
# Companies/wild/to-locked only exists where the filesystem folds case.
if [[ "$TMP/Companies" -ef "$TMP/companies" ]]; then
  run 2 Write file_path "$TMP/Companies/wild/to-locked/x.md" 'write through symlink via Companies/ blocked'
fi
run 0 Write file_path "$TMP/workspace/to-open/x.md"          'write through symlink to write grant allowed'
else
  echo "NOTE: ln -s did not create a symlink here; symlink cases not run" >&2
fi
rm -rf "$TMP/workspace/to-locked" "$TMP/companies/wild/to-locked" "$TMP/workspace/to-open"
rm -f "$TMP/workspace/to-locked" "$TMP/companies/wild/to-locked" "$TMP/workspace/to-open"
write_manifest

# --- sed -i reads the file operands, not the word sed ----
# cwd inside a read-only company folder: the edited file is outside the vault.
RO="$A/private"
runc 0 "$RO" "sed -i 's/a/b/' /tmp/skipwip/q4.sql"            'sed -i file outside vault from read-only cwd allowed'
runc 0 "$RO" "sed -i 's/a/b/;s/c/d/' /tmp/skipwip/q4.sql"     'sed -i script with semicolon allowed'
runc 0 "$RO" "sed -i 's/a|b/c/' /tmp/skipwip/q4.sql"          'sed -i script with pipe allowed'
runc 0 "$RO" "sed -i 's/a/b\\&c/' /tmp/skipwip/q4.sql"        'sed -i script with ampersand allowed'
runc 0 "$RO" "sed -i '' 's/a/b/' /tmp/skipwip/q4.sql"         'sed -i empty suffix word allowed'
runc 0 "$RO" "sed -i.bak 's/a/b/' /tmp/skipwip/q4.sql"        'sed -i.bak allowed'
runc 0 "$RO" "sed --in-place=.bak 's/a/b/' /tmp/skipwip/q4.sql" 'sed --in-place=SUF allowed'
runc 0 "$RO" "sed -E -i 's/a/b/' /tmp/skipwip/q4.sql"         'sed -E -i allowed'
runc 0 "$RO" "sed -Ei 's/a/b/' /tmp/skipwip/q4.sql"           'sed -Ei cluster allowed'
runc 0 "$RO" "sed -i -e 's/a/b/' -e '/x/d' /tmp/skipwip/q4.sql" 'sed -i with two -e scripts allowed'
runc 0 "$RO" "sed -i -f /tmp/s.sed /tmp/skipwip/q4.sql"       'sed -i -f script file allowed'
runc 0 "$RO" "sed -i -l 5 's/a/b/' /tmp/skipwip/q4.sql"       'sed -i -l N allowed'
runc 0 "$RO" "sed -i 's/a/b/' /tmp/a /tmp/b"                  'sed -i two files outside vault allowed'
# The same forms against a read-only vault file stay blocked.
runc 2 "$RO" "sed -i 's/a/b/' x.md"                           'sed -i vault file from read-only cwd blocked'
runc 2 "$RO" "sed -i 's/a/b/;s/c/d/' x.md"                    'sed -i semicolon script on vault file blocked'
runc 2 "$RO" "sed -i 's/a|b/c/' x.md"                         'sed -i pipe script on vault file blocked'
runc 2 "$RO" "sed -i '' 's/a/b/' x.md"                        'sed -i empty suffix on vault file blocked'
runc 2 "$RO" "sed -i.bak 's/a/b/' x.md"                       'sed -i.bak on vault file blocked'
runc 2 "$RO" "sed --in-place=.bak 's/a/b/' x.md"              'sed --in-place=SUF on vault file blocked'
runc 2 "$RO" "sed -E -i 's/a/b/' x.md"                        'sed -E -i on vault file blocked'
runc 2 "$RO" "sed -Ei 's/a/b/' x.md"                          'sed -Ei cluster on vault file blocked'
runc 2 "$RO" "sed -i -e 's/a/b/' -e '/x/d' x.md"              'sed -i two -e scripts on vault file blocked'
runc 2 "$RO" "sed -i -f /tmp/s.sed x.md"                      'sed -i -f on vault file blocked'
runc 2 "$RO" "sed -i -l 5 's/a/b/' x.md"                      'sed -i -l N on vault file blocked'
runc 2 "$TMP" "sed -i 's/a/b/;s/c/d/' companies/acme/private/a.md" 'sed -i semicolon script on vault file from HQ root blocked'
runc 2 "$TMP" "sed -n -i 's/a/b/' companies/acme/private/a.md" 'sed -n -i on vault file from HQ root blocked'
runc 2 "$TMP" "sed -i 's/a/b/' /tmp/ok.sql companies/acme/private/a.md" 'sed -i one vault file among several blocked'
runc 0 "$RO" "sed 's/a/b/' x.md"                              'sed without -i on vault file allowed'
runc 0 "$RO" "sed -n -e 's/a/b/p' x.md"                       'sed -n -e read allowed'

# A quote inside a sed or awk argument must not hide a later write from the guard.
runc 2 "$TMP" "sed -n \"/it's/p\" /tmp/x; rm companies/acme/private/a.md" 'sed with apostrophe in double quotes then rm blocked'
runc 2 "$TMP" "sed -n \"/it's/p\" /tmp/x; echo ok > companies/acme/private/a.md" 'sed with apostrophe in double quotes then redirect blocked'
runc 2 "$TMP" "sed -n \"/it's/p\" /tmp/x | tee companies/acme/private/a.md" 'sed with apostrophe in double quotes then tee blocked'
runc 2 "$TMP" "sed -n \"/it's/p\" /tmp/x && mv /tmp/y companies/acme/private/a.md" 'sed with apostrophe in double quotes then mv blocked'
runc 2 "$TMP" "sed -n \"/it's/p\" /tmp/x; cp /tmp/y companies/acme/private/a.md" 'sed with apostrophe in double quotes then cp blocked'
runc 2 "$TMP" "awk \"/it's/\" /tmp/x; rm companies/acme/private/a.md" 'awk with apostrophe in double quotes then rm blocked'
runc 2 "$TMP" "sed -i \"s/it's/x/\" /tmp/x; rm companies/acme/private/a.md" 'sed -i with apostrophe in double quotes then rm blocked'
runc 2 "$TMP" "sed -n p /tmp/x \\'; echo ok > companies/acme/private/a.md" 'escaped apostrophe argument then redirect blocked'
runc 2 "$TMP" "sed -n p \$'it\\'s' /tmp/x; echo ok > companies/acme/private/a.md" 'dollar-quoted apostrophe argument then redirect blocked'
runc 2 "$TMP" "sed -n \"/it's/p\" /tmp/x; sed -i 's/a/b/' companies/acme/private/a.md" 'sed read then sed -i on vault file blocked'
runc 2 "$A/private" "sed -n \"/it's/p\" /tmp/x; rm a.md" 'sed apostrophe then relative rm in read-only cwd blocked'
runc 2 "$TMP" $'sed -n "/it\'s/p" /tmp/x\nrm companies/acme/private/a.md' 'sed apostrophe then rm on the next line blocked'
runc 2 "$TMP" $'# sed won\'t help here\nrm companies/acme/private/a.md' 'apostrophe in a comment then rm blocked'
runc 2 "$TMP" $'cat > /tmp/notes.txt <<\'EOF\'\nuse sed if it\'s needed\nEOF\nrm companies/acme/private/a.md' 'apostrophe in a heredoc body then rm blocked'
runc 2 "$TMP" $'echo done # sed can\'t\necho ok > companies/acme/private/a.md' 'apostrophe in a trailing comment then redirect blocked'
runc 2 "$TMP" "grep x /tmp/f | sed \"s/'//g\"; rm companies/acme/private/a.md" 'sed apostrophe filter in a pipe then rm blocked'
# Newly blocked in-place forms on a vault file, and an awk and a perl case.
runc 2 "$TMP" "sed -s -i 's/a/b/' companies/acme/private/a.md" 'sed -s -i on vault file blocked'
runc 2 "$TMP" "sed -ni 's/a/b/' companies/acme/private/a.md" 'sed -ni on vault file blocked'
runc 2 "$TMP" "sed 's/a/b/' companies/acme/private/a.md -i" 'sed with -i after the file blocked'
runc 2 "$TMP" "sed -e 's/a/b/' companies/acme/private/a.md --in-place" 'sed with --in-place after the file blocked'
runc 2 "$TMP" "sed -i -- 's/a/b/' companies/acme/private/a.md" 'sed -i -- on vault file blocked'
runc 2 "$A/private" "sed -i 's/a/b/' -- -x.md" 'sed -i -- dash-named file in read-only cwd blocked'
runc 2 "$TMP" "gsed -i 's/a/b/' companies/acme/private/a.md" 'gsed -i on vault file blocked'
runc 2 "$TMP" "awk -i inplace '{print}' companies/acme/private/a.md" 'awk -i inplace on vault file blocked'
runc 2 "$TMP" "awk -i inplace '{print \"a;b\"}' companies/acme/private/a.md" 'awk -i inplace with semicolon program on vault file blocked'
runc 2 "$TMP" "awk -v x=1 -i inplace '{print}' companies/acme/private/a.md" 'awk -v then -i inplace on vault file blocked'
runc 0 "$A/private" "awk -i inplace '{print \"a;b\"}' /tmp/q.sql" 'awk -i inplace semicolon program on file outside vault allowed'
# An option that supplies the awk program (-e, -f, -E, --source, --file, --exec)
# leaves every positional a file, so the first of two operands is a target.
runc 2 "$TMP" "awk -i inplace -e '{print}' companies/acme/private/a.md /tmp/a" 'awk -i inplace -e with vault file first of two operands blocked'
runc 2 "$TMP" "awk -i inplace -e'{print}' companies/acme/private/a.md /tmp/a" 'awk -i inplace attached -e with vault file first of two operands blocked'
runc 2 "$TMP" "awk -i inplace -f prog.awk companies/acme/private/a.md /tmp/a" 'awk -i inplace -f with vault file first of two operands blocked'
runc 2 "$TMP" "awk -i inplace --source='{print}' companies/acme/private/a.md /tmp/a" 'awk -i inplace --source= with vault file first of two operands blocked'
runc 2 "$TMP" "awk -i inplace --file prog.awk companies/acme/private/a.md /tmp/a" 'awk -i inplace --file with vault file first of two operands blocked'
runc 0 "$TMP" "awk -i inplace -e '{print}' /tmp/a /tmp/b" 'awk -i inplace -e on files outside vault allowed'
# gawk -W source=, -Wsource=, and unique long-option prefixes (--sour=, --fil=)
# also supply the program, so the first operand is a file.
runc 2 "$TMP" "awk -i inplace -W source='{print}' companies/acme/private/a.md /tmp/a" 'awk -i inplace -W source= with vault file first of two operands blocked'
runc 2 "$TMP" "awk -i inplace -Wsource='{print}' companies/acme/private/a.md /tmp/a" 'awk -i inplace attached -Wsource= with vault file first of two operands blocked'
runc 2 "$TMP" "awk -i inplace -W sour='{print}' companies/acme/private/a.md /tmp/a" 'awk -i inplace -W abbreviated source= with vault file first of two operands blocked'
runc 2 "$TMP" "awk -i inplace -W file=prog.awk companies/acme/private/a.md /tmp/a" 'awk -i inplace -W file= with vault file first of two operands blocked'
runc 2 "$TMP" "awk -i inplace -W exec=prog.awk companies/acme/private/a.md /tmp/a" 'awk -i inplace -W exec= with vault file first of two operands blocked'
runc 2 "$TMP" "awk -i inplace -W \$'source={print}' companies/acme/private/a.md /tmp/a" 'awk -i inplace -W ANSI-C source= with vault file first of two operands blocked'
runc 2 "$TMP" "awk -i inplace -W\$'source={print}' companies/acme/private/a.md /tmp/a" 'awk -i inplace attached -W ANSI-C source= with vault file first of two operands blocked'
runc 2 "$TMP" "awk -i inplace --\$'source={print}' companies/acme/private/a.md /tmp/a" 'awk -i inplace ANSI-C --source= with vault file first of two operands blocked'
runc 2 "$TMP" "awk -i inplace --sour='{print}' companies/acme/private/a.md /tmp/a" 'awk -i inplace --sour= with vault file first of two operands blocked'
runc 2 "$TMP" "awk -i inplace --fil=prog.awk companies/acme/private/a.md /tmp/a" 'awk -i inplace --fil= with vault file first of two operands blocked'
runc 2 "$TMP" "awk -i inplace --file=prog.awk companies/acme/private/a.md /tmp/a" 'awk -i inplace --file= with vault file first of two operands blocked'
runc 2 "$TMP" "awk -i inplace --exec=prog.awk companies/acme/private/a.md /tmp/a" 'awk -i inplace --exec= with vault file first of two operands blocked'
runc 2 "$TMP" "awk -i inplace -fprog.awk companies/acme/private/a.md /tmp/a" 'awk -i inplace attached -f with vault file first of two operands blocked'
runc 2 "$TMP" "awk -i inplace -W posix '{print}' companies/acme/private/a.md" 'awk -i inplace -W posix with program operand still checks vault file'
runc 0 "$TMP" "awk -i inplace -W source='{print}' /tmp/a /tmp/b" 'awk -i inplace -W source= on files outside vault allowed'
runc 0 "$TMP" "awk -i inplace -W \$'source={print}' /tmp/a /tmp/b" 'awk -i inplace -W ANSI-C source= on files outside vault allowed'
runc 0 "$TMP" "awk -i inplace -W\"\$'source={print}'\" companies/acme/private/a.md /tmp/a" 'awk -i inplace keeps ANSI-C marker literal inside double quotes'
# Escapes inside $'...' are decoded before the option name is read.
runc 2 "$TMP" "awk -i inplace -W \$'sour\\x63e={print}' companies/acme/private/a.md /tmp/a" 'awk -i inplace -W ANSI-C hex-escaped source= with vault file first blocked'
runc 2 "$TMP" "awk -i inplace \$'--sour\\x63e={print}' companies/acme/private/a.md /tmp/a" 'awk -i inplace ANSI-C hex-escaped --source= with vault file first blocked'
runc 2 "$TMP" "awk -i inplace -W \$'sour\\143e={print}' companies/acme/private/a.md /tmp/a" 'awk -i inplace -W ANSI-C octal-escaped source= with vault file first blocked'
runc 2 "$TMP" "awk -i inplace -W \$'sour\\u0063e={print}' companies/acme/private/a.md /tmp/a" 'awk -i inplace -W ANSI-C \u-escaped source= with vault file first blocked'
runc 2 "$TMP" "sed \$'-\\x69' 's/a/b/' companies/acme/private/a.md" 'sed ANSI-C hex-escaped -i on vault file blocked'
runc 0 "$TMP" "sed \$'-\\x69' 's/a/b/' /tmp/a" 'sed ANSI-C hex-escaped -i on file outside vault allowed'
runc 2 "$TMP" "perl -pi -e 's/a/b/' companies/acme/private/a.md" 'perl -pi on vault file blocked'
runc 2 "$TMP" "perl -i.bak -pe 's/a/b/' companies/acme/private/a.md" 'perl -i.bak on vault file blocked'
runc 0 "$A/private" "perl -pi -e 's/a/b/;s/c/d/' /tmp/q.sql" 'perl -pi on file outside vault allowed'

# A perl, ruby, sed or awk word with no in-place flag is not the write op:
# a later cp, mv or touch in the same command is still checked.
runc 2 "$TMP" "ruby -run -e cp -- /tmp/x companies/acme/private/a.md" 'ruby -run -e cp into vault file blocked'
runc 2 "$TMP" "ruby -run -e mv -- /tmp/x companies/acme/private/a.md" 'ruby -run -e mv into vault file blocked'
runc 2 "$TMP" "ruby -run -e touch -- companies/acme/private/a.md" 'ruby -run -e touch on vault file blocked'
runc 2 "$TMP" "perl -MExtUtils::Command -e cp /tmp/x companies/acme/private/a.md" 'perl ExtUtils cp into vault file blocked'
runc 2 "$TMP" "perl -MExtUtils::Command -e touch companies/acme/private/a.md" 'perl ExtUtils touch on vault file blocked'
runc 2 "$TMP" "gawk -f x.awk cp /tmp/x companies/acme/private/a.md" 'gawk without inplace then cp words still checked'
# After --, a dash-named file in a fragment cut from a ; script is a file.
runc 2 "$A/private" "sed -i '' -- 's/a;b/c/' -a.md" 'sed -i empty suffix -- cut script then dash-named file in read-only cwd blocked'
runc 2 "$A/private" "sed -i 's/a;b/c/' -- -a.md" 'sed -i cut script -- dash-named file in read-only cwd blocked'
runc 2 "$A/private" "awk -i inplace -- '{print \"a;b\"}' -a.md" 'awk -i inplace -- cut program then dash-named file in read-only cwd blocked'
# BSD sed and gawk stop reading options at the script, so a dash-named
# word after a cut script is a file even with no --, and a quoted or cut
# dash-named name after -- is a file too.
runc 2 "$A/private" "sed -i '' 's/a;b/c/' -a.md" 'BSD sed cut script then dash-named file in read-only cwd blocked'
runc 2 "$A/private" "sed -i '' 's/a;b/c/' /tmp/x -a.md" 'BSD sed cut script then outside file and dash-named file in read-only cwd blocked'
runc 2 "$A/private" "awk -i inplace '{print \"a;b\"}' -a.md" 'awk cut program then dash-named file in read-only cwd blocked'
runc 2 "$A/private" "awk -i inplace '{print \"a;b\"}' /tmp/x -a.md" 'awk cut program then outside file and dash-named file in read-only cwd blocked'
runc 2 "$A/private" "sed -i 's/a;b/c/' -- \"-a.md\"" 'sed cut script -- quoted dash-named file in read-only cwd blocked'
runc 2 "$A/private" "sed -i 's/a;b/c/' -- '-a;b.md'" 'sed cut script -- dash-named file holding semicolon in read-only cwd blocked'
runc 2 "$A/private" "sed -i '' -- 's/a;b/Z/' '-q;r.md'" 'BSD sed -- cut script then dash-named file holding semicolon in read-only cwd blocked'
runc 0 "$A/private" "sed -i -e 's/a;b/d/' -n -e 's/x;y/z/' /tmp/q.sql" 'sed option words after a cut script on file outside vault allowed'
# A $'...' script holding ; still leaves its file operands checked.
runc 2 "$A/private" "sed -i \$'s/a;b/c/' a.md" 'sed -i ANSI-C script with semicolon in read-only cwd blocked'
runc 2 "$A/private" "awk -i inplace \$'{print \"a;b\"}' a.md" 'awk -i inplace ANSI-C program with semicolon in read-only cwd blocked'
# gawk -L takes no separate argument, so the program is the next word.
runc 2 "$TMP" "awk -i inplace -L '{print}' companies/acme/private/a.md /tmp/x" 'awk -i inplace -L then program with vault file first of two operands blocked'
runc 2 "$TMP" "sed -i 's/a;b;c/d/' companies/acme/private/a.md" 'sed -i multi-semicolon script on vault file blocked'
runc 2 "$TMP" "sed -i -e 's/a;b/d/' -e 's/x;y/z/' companies/acme/private/a.md" 'sed -i two scripts with semicolons on vault file blocked'
runc 0 "$A/private" "sed -i -e 's/a;b/d/' -e 's/x;y/z/' /tmp/q.sql" 'sed -i two scripts with semicolons on file outside vault allowed'
runc 2 "$TMP" $'sed -i \'s/a\nb/\' companies/acme/private/a.md' 'sed -i script spanning lines on vault file blocked'
runc 2 "$TMP" "sed -i 's/a;b/d/'; rm companies/acme/private/a.md" 'sed -i cut script then rm blocked'
# A quoted file name holding ; | or & is cut by the splitter. The cut name is
# a file operand, not the script, so it is still checked.
runc 2 "$TMP" "sed -i 's/a/b/' \"companies/acme/private/Q&A.md\"" 'sed -i quoted vault file name with ampersand blocked'
runc 2 "$TMP" "sed -i 's/a/b/' 'companies/acme/private/a;b.md'" 'sed -i quoted vault file name with semicolon blocked'
runc 2 "$TMP" "sed -i 's/a/b/' \"companies/acme/private/a|b.md\"" 'sed -i quoted vault file name with pipe blocked'
runc 2 "$TMP" "sed -i 's/a/b/' /tmp/ok.sql \"companies/acme/private/Q&A.md\"" 'sed -i quoted vault name with ampersand after another file blocked'
runc 2 "$TMP" "sed -i 's/a;b/c/' \"companies/acme/private/Q&A.md\"" 'sed -i cut script then quoted vault name with ampersand blocked'
runc 2 "$TMP" "awk -i inplace '{print}' \"companies/acme/private/Q&A.md\"" 'awk -i inplace quoted vault file name with ampersand blocked'
runc 2 "$TMP" "perl -pi -e 's/a/b/' \"companies/acme/private/Q&A.md\"" 'perl -pi quoted vault file name with ampersand blocked'
runc 2 "$A/private" "sed -i 's/a/b/' \"Q&A.md\"" 'sed -i quoted relative name with ampersand in read-only cwd blocked'
runc 2 "$A/private" "awk -i inplace '{print}' 'a;b.md'" 'awk -i inplace quoted relative name with semicolon in read-only cwd blocked'
runc 0 "$A/private" "sed -i 's/a/b/' \"/tmp/Q&A.sql\"" 'sed -i quoted outside-vault name with ampersand allowed'
runc 0 "$TMP" "sed -i 's/a/b/' \"companies/acme/reports/Q&A.md\"" 'sed -i quoted writable vault name with ampersand allowed'
# The part before the cut can name a writable folder; the whole name is checked.
runc 2 "$TMP" "sed -i 's/a/b/' \"companies/acme/reports/x&/../locked/a.md\"" 'sed -i cut name checked whole once its quote closes'
runc 2 "$TMP" "sed -i 's/a/b/' 'companies/acme/reports/x;y|/../locked/a.md'" 'sed -i name cut twice checked whole'
runc 2 "$TMP" "sed -i 's/a;b/c/' \"companies/acme/reports/x&/../locked/a.md\"" 'sed -i cut script then cut name checked whole'
runc 2 "$TMP" "awk -i inplace '{print}' \"companies/acme/reports/x&/../locked/a.md\"" 'awk -i inplace cut name checked whole'
runc 0 "$A/private" "sed -i -e 's/a;b/c/' -ne 's/x;y/z/' /tmp/q.sql" 'sed -i cut -e script then -ne script outside vault allowed'
runc 0 "$A/private" "perl -pi -e 's/a;b/c/' -e 's/x;y/z/' /tmp/q.sql" 'perl -pi two cut -e scripts outside vault allowed'
runc 2 "$TMP" "sed -i -e 's/a;b/c/' -s \"companies/acme/private/Q&A.md\"" 'sed -i cut -e script then option then quoted vault name blocked'

# F1: \' inside $'...' is an escaped quote, so it does not end the word. A
# backslash outside quotes, and \" inside "...", escape the next character too.
runc 2 "$TMP" "rm \$'a\\'b' companies/acme/private/a.md" 'rm after ANSI-C word holding escaped quote on vault file blocked'
runc 2 "$TMP" "echo \$'\\'' > companies/acme/private/a.md 'z'" 'redirect after ANSI-C escaped quote into vault file blocked'
runc 2 "$TMP" "tee \$'\\'' companies/acme/private/a.md 'z'" 'tee after ANSI-C escaped quote on vault file blocked'
runc 2 "$TMP" "echo \\' > companies/acme/private/a.md \\'" 'redirect between unquoted escaped quotes into vault file blocked'
runc 2 "$TMP" "echo \"a\\\"\" > companies/acme/private/a.md \"b\"" 'redirect after double-quoted escaped quote into vault file blocked'
runc 0 "$TMP" "echo \$'it\\'s' > /tmp/x" 'ANSI-C escaped quote with redirect outside vault allowed'
runc 0 "$TMP" "echo \$'\\'' > companies/acme/reports/a.md 'z'" 'ANSI-C escaped quote with redirect into writable vault file allowed'
runc 0 "$TMP" "rm \$'a\\'b' /tmp/a" 'rm after ANSI-C escaped quote outside vault allowed'
# F2: a quoted in-place flag still marks the command as an in-place edit.
runc 2 "$TMP" "sed '-i' 's/a/b/' companies/acme/private/a.md" 'sed single-quoted -i on vault file blocked'
runc 2 "$TMP" "sed \"-i\" 's/a/b/' companies/acme/private/a.md" 'sed double-quoted -i on vault file blocked'
runc 2 "$TMP" "sed -'i' 's/a/b/' companies/acme/private/a.md" 'sed partly quoted -i on vault file blocked'
runc 2 "$TMP" "sed \$'-i' 's/a/b/' companies/acme/private/a.md" 'sed ANSI-C -i without escape on vault file blocked'
runc 2 "$TMP" "awk -i 'inplace' '{print}' companies/acme/private/a.md" 'awk -i quoted inplace on vault file blocked'
runc 2 "$TMP" "awk -i \"in\"place '{print}' companies/acme/private/a.md" 'awk -i partly quoted inplace on vault file blocked'
runc 2 "$TMP" "perl -p\$'i' -e 's/a/b/' companies/acme/private/a.md" 'perl -p with ANSI-C i on vault file blocked'
runc 2 "$TMP" "perl '-pi' -e 's/a/b/' companies/acme/private/a.md" 'perl quoted -pi on vault file blocked'
runc 0 "$TMP" "sed '-n' 's/a/b/p' companies/acme/private/a.md" 'sed quoted -n read of vault file allowed'
runc 0 "$TMP" "sed '-i' 's/a/b/' /tmp/a" 'sed quoted -i on file outside vault allowed'
# F3: a companies/ prefix written with $'...' escapes is still a vault path.
runc 2 "$TMP" "sed -i 's/a/b/' \$'\\x63ompanies/acme/private/a.md'" 'sed -i on hex-escaped companies prefix blocked'
runc 2 "$TMP" "sed -i 's/a/b/' \$'companies\\x2facme/private/a.md'" 'sed -i on hex-escaped slash after companies blocked'
runc 2 "$TMP" "cp /tmp/x \$'\\x63ompanies/acme/private/a.md'" 'cp onto hex-escaped companies prefix blocked'
runc 2 "$TMP" "echo x > \$'\\x63ompanies/acme/private/a.md'" 'redirect onto hex-escaped companies prefix blocked'
runc 2 "$TMP" "rm \$'\\143ompanies/acme/private/a.md'" 'rm on octal-escaped companies prefix blocked'
runc 2 "$TMP" "rm \$'\\u0063ompanies/acme/private/a.md'" 'rm on \u-escaped companies prefix blocked'
runc 0 "$TMP" "cat \$'\\x63ompanies/acme/private/a.md'" 'cat of hex-escaped companies prefix allowed'
runc 0 "$TMP" "cp /tmp/x \$'\\x63ompanies/acme/reports/a.md'" 'cp onto hex-escaped writable vault path allowed'
runc 0 "$TMP" "printf \$'a\\tb\\n' > /tmp/x" 'ANSI-C escapes with redirect outside vault allowed'

# A quoted command name is the same command to bash.
runc 2 "$TMP" "'rm' companies/acme/private/a.md" 'quoted rm command name on vault file blocked'
runc 2 "$TMP" "r\"m\" companies/acme/private/a.md" 'partly quoted rm command name on vault file blocked'

# $$ is the PID parameter, so $$' opens a plain quote, not an ANSI-C string.
runc 2 "$TMP" "rm \$\$'\\' companies/acme/private/a.md #'" 'rm after PID then plain quote on vault file blocked'
runc 2 "$TMP" "echo \$\$'\\' > companies/acme/private/a.md #'" 'redirect after PID then plain quote into vault file blocked'
runc 2 "$TMP" $'rm $$\'\\\' companies/acme/private/a.md\ntrue \'' 'rm after PID then plain quote closed on next line blocked'
runc 2 "$TMP" "rm \$\$\$\$'\\' companies/acme/private/a.md #'" 'rm after two PIDs then plain quote on vault file blocked'
runc 2 "$TMP" "rm \$\$\$'\\'' companies/acme/private/a.md" 'rm after PID then ANSI-C escaped quote on vault file blocked'
# A quoted word that names a write op is a search term unless it is the command.
runc 0 "$TMP" "grep -rn \"install\" companies/acme/private/" 'grep for quoted install in read-only vault folder allowed'
runc 0 "$TMP" "grep -n 'rm' companies/acme/private/a.md" 'grep for quoted rm in read-only vault file allowed'
runc 0 "$TMP" "git log -S \"rm\" -- companies/acme/private" 'git log -S quoted rm on read-only vault folder allowed'
runc 0 "$A/private" "grep -rn 'install' ." 'grep for quoted install in read-only cwd allowed'
runc 2 "$TMP" "env 'rm' companies/acme/private/a.md" 'quoted rm after env on vault file blocked'
runc 2 "$TMP" "X=1 'rm' companies/acme/private/a.md" 'quoted rm after an assignment on vault file blocked'
runc 2 "$TMP" "/bin/'rm' companies/acme/private/a.md" 'quoted rm after a path on vault file blocked'
runc 2 "$TMP" "rm compan\$'\\x69'es/acme/private/a.md" 'rm on prefix split across an ANSI-C escape blocked'
# Long segments: a $'...' token is checked when its decoded text names a vault
# path, and a plain escape such as $'\t' is not read as a relative target.
PZ_LONG="$(printf 'x%.0s' $(seq 1 6000))"
runc 0 "$A/private" "grep \$'\\t' a.md $PZ_LONG" 'long read-only segment with ANSI-C tab in read-only cwd allowed'
runc 2 "$TMP" "rm \$'\\x63ompanies/acme/private/a.md' $PZ_LONG" 'long segment rm on hex-escaped companies prefix blocked'

# A literal $' earlier in the command does not hide an escaped prefix.
runc 2 "$TMP" "rm '\$' \$'\\x63ompanies/acme/private/a.md'" 'rm after quoted dollar on hex-escaped companies prefix blocked'
runc 2 "$TMP" "echo '\$' > \$'\\x63ompanies/acme/private/a.md'" 'redirect after quoted dollar onto hex-escaped companies prefix blocked'
runc 2 "$TMP" "rm \"\$'\" \$'\\x63ompanies/acme/private/a.md'" 'rm after double-quoted ANSI-C marker on hex-escaped companies prefix blocked'
# A quoted op after a shell keyword, a launcher with arguments, a leading
# redirect or find -exec is still in command position.
runc 2 "$TMP" "if true; then 'rm' companies/acme/private/a.md; fi" 'quoted rm after then on vault file blocked'
runc 2 "$TMP" "for f in x; do 'rm' companies/acme/private/a.md; done" 'quoted rm after do on vault file blocked'
runc 2 "$TMP" "timeout 5 'rm' companies/acme/private/a.md" 'quoted rm after timeout on vault file blocked'
runc 2 "$TMP" "stdbuf -o0 'rm' companies/acme/private/a.md" 'quoted rm after stdbuf on vault file blocked'
runc 2 "$TMP" "2>/dev/null 'rm' companies/acme/private/a.md" 'quoted rm after leading redirect on vault file blocked'
runc 2 "$TMP" "find /tmp -exec 'rm' companies/acme/private/a.md \\;" 'find -exec quoted rm naming a vault file blocked'
# A search behind a launcher word is still a search.
runc 0 "$TMP" "time grep -rn \"install\" companies/acme/private" 'time grep for quoted install in read-only vault folder allowed'
runc 0 "$TMP" "env LC_ALL=C grep -n 'rm' companies/acme/private/a.md" 'env grep for quoted rm in read-only vault file allowed'
runc 0 "$TMP" "if grep -q 'rm' companies/acme/private/a.md; then echo y; fi" 'if grep for quoted rm in read-only vault file allowed'

echo "PASS=$PASS FAIL=$FAIL (hook shell: $HOOK_BASH)"
[[ "$FAIL" -eq 0 ]] || exit 1
if [[ "$HOOK_BASH" == "bash" && -x /bin/bash && "$(uname -s)" == "Darwin" ]]; then
  HOOK_BASH=/bin/bash bash "${BASH_SOURCE[0]}"
fi
exit 0
