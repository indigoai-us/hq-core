#!/usr/bin/env bash
# hq-core: public
# Regression tests for .claude/hooks/mandatory-scope-authorizer.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Canonicalize. On macOS mktemp -d hands back /var/folders/... while /var is a
# symlink to /private/var, and the hook resolves its own root with `pwd -P`. The
# payload paths would then sit "outside" HQ_ROOT, every absolute-path case would
# normalize to empty, and the suite would report a pass-through as an allow —
# on this machine every case below [1] failed for that reason alone, against an
# untouched hook. CI runs on Linux, where /tmp is real, so it never showed there.
# Same treatment as core/scripts/tests/workflow-runner.test.sh.
TMP="$(cd "$TMP" && pwd -P)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REGRESSION_FAILURES=0

expect_exit() {
  local expected="$1" actual="$2" case_name="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $case_name"
  else
    echo "FAIL: $case_name (expected exit $expected, got $actual)" >&2
    REGRESSION_FAILURES=$((REGRESSION_FAILURES + 1))
  fi
}

install_fixture() {
  local bound="${1:-}"
  rm -rf "${TMP:?}"/*
  mkdir -p "$TMP/.claude/hooks" "$TMP/core/scripts/lib" \
    "$TMP/companies/indigo/settings" "$TMP/companies/otherco/settings" \
    "$TMP/companies/_template" "$TMP/core/docs" "$TMP/personal" \
    "$TMP/workspace/sessions/sess-bound"
  cp "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" "$TMP/.claude/hooks/"
  cp "$ROOT/core/scripts/lib/session-authz.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-id.sh" "$TMP/core/scripts/lib/"
  chmod +x "$TMP/.claude/hooks/mandatory-scope-authorizer.sh"

  printf 'companies:\n  indigo:\n    name: Indigo\n  otherco:\n    name: otherco\n' \
    > "$TMP/companies/manifest.yaml"
  touch "$TMP/companies/indigo/settings/.keep" "$TMP/companies/otherco/settings/.keep"
  touch "$TMP/core/docs/readme.md" "$TMP/personal/note.md" "$TMP/companies/_template/readme.md"
  printf 'sess-bound\n' > "$TMP/workspace/sessions/.current"

  if [ -n "$bound" ]; then
    printf 'company_slug: %s\n' "$bound" > "$TMP/workspace/sessions/sess-bound/meta.yaml"
    # shellcheck source=../lib/session-scope-capability.sh
    . "$ROOT/core/scripts/lib/session-scope-capability.sh"
    session_scope_mint "$TMP" "sess-bound" "$bound"
  fi
}

run_hook() {
  local payload="$1"
  local rc=0
  : > "$TMP/err.txt"
  printf '%s' "$payload" | bash "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" 2>"$TMP/err.txt" || rc=$?
  printf '%s' "$rc"
}

echo "[1] bound indigo blocks cross-company Read"
install_fixture "indigo"
payload='{"tool_name":"Read","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/otherco/settings/foo.yaml"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected exit 2 for cross-company read, got $rc"
grep -q "Cross-company scope violation" "$TMP/err.txt" || fail "missing block message"

echo "[2] bound indigo allows same-company, core, personal, manifest"
for rel in \
  "companies/indigo/settings/foo.yaml" \
  "core/docs/readme.md" \
  "personal/note.md" \
  "companies/manifest.yaml"; do
  payload='{"tool_name":"Read","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/'"$rel"'"}}'
  rc="$(run_hook "$payload")"
  [ "$rc" = "0" ] || fail "expected allow for $rel, got $rc"
done

echo "[3] unbound session blocks companies/* except manifest and _template"
install_fixture ""
payload='{"tool_name":"Read","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/indigo/settings/foo.yaml"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected exit 2 for unbound company read, got $rc"

payload='{"tool_name":"Read","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/_template/readme.md"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "0" ] || fail "expected allow for _template, got $rc"

payload='{"tool_name":"Read","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/manifest.yaml"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "0" ] || fail "expected allow for manifest, got $rc"

echo "[4] Bash blocks embedded cross-company path"
install_fixture "indigo"
payload='{"tool_name":"Bash","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"command":"cat companies/otherco/settings/secrets.yaml"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected exit 2 for bash cross-company, got $rc"

echo "[5] Bash allows a literal same-company path with an unrelated expansion"
install_fixture "indigo"
payload='{"tool_name":"Bash","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"command":"project_dir=/srv/hq; printf '%s\\n' \"$project_dir\"; cat companies/indigo/settings/x"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "0" ] || fail "expected allow for literal same-company path with unrelated expansion, got $rc"

echo "[6] Bash blocks an unresolved company variable fail-closed"
install_fixture "indigo"
payload='{"tool_name":"Bash","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"command":"co=otherco; cat companies/$co/settings/x"}}'
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "unresolved company variable fails closed"

echo "[7] Bash blocks expansion in the remainder of a company path"
install_fixture "indigo"
payload='{"tool_name":"Bash","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"command":"p=../../otherco/settings/secret.yaml; cat companies/indigo/$p"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected block for an expansion in a company path, got $rc"

echo "[8] Bash blocks a line-continued foreign company variable"
install_fixture "indigo"
command=$'co=otherco; cat companies/\\\n$co/settings/x'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name: "Bash", session_id: "sess-bound", cwd: $cwd, tool_input: {command: $command}}')"
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected block for line-continued foreign company variable, got $rc"

echo "[9] Bash blocks normalized company traversal"
install_fixture "indigo"
command=$'cat companies/in\\\ndigo/../otherco/secret.txt'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name: "Bash", session_id: "sess-bound", cwd: $cwd, tool_input: {command: $command}}')"
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected block for normalized traversal into another company, got $rc"

echo "[10] Bash blocks backtick expansion in a company path"
install_fixture "indigo"
command='cat companies/indigo/`printf ../otherco/secret.txt`'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name: "Bash", session_id: "sess-bound", cwd: $cwd, tool_input: {command: $command}}')"
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected block for backtick expansion in a company path, got $rc"

echo "[11] Bash allows an attached redirection after a literal company path"
install_fixture "indigo"
command='tmp=/tmp/hq-out; cat companies/indigo/settings/x>$tmp'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" '{tool_name: "Bash", session_id: "sess-bound", cwd: $cwd, tool_input: {command: $command}}')"
rc="$(run_hook "$payload")"
[ "$rc" = "0" ] || fail "expected allow for an attached redirection, got $rc"

echo "[12] Bash allows a literal dollar in a single-quoted company path"
install_fixture "indigo"
command="cat 'companies/indigo/settings/\$schema.json'"
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" '{tool_name: "Bash", session_id: "sess-bound", cwd: $cwd, tool_input: {command: $command}}')"
rc="$(run_hook "$payload")"
[ "$rc" = "0" ] || fail "expected allow for a literal dollar in a single-quoted company path, got $rc"

echo "[13] Bash allows an escaped literal dollar in a company path"
install_fixture "indigo"
command='cat companies/indigo/settings/\$schema.json'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" '{tool_name: "Bash", session_id: "sess-bound", cwd: $cwd, tool_input: {command: $command}}')"
rc="$(run_hook "$payload")"
[ "$rc" = "0" ] || fail "expected allow for an escaped literal dollar in a company path, got $rc"

echo "[14] Read follows symlink target for company scope"
install_fixture "indigo"
mkdir -p "$TMP/companies/indigo/settings"
touch "$TMP/companies/otherco/settings/foo.yaml"
ln -sfn "$TMP/companies/otherco/settings/foo.yaml" "$TMP/companies/indigo/settings/otherco-link.yaml"
payload='{"tool_name":"Read","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/indigo/settings/otherco-link.yaml"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected exit 2 for symlink into other company, got $rc"

echo "[15] binding the session that actually fired the hook unblocks it"
# End-to-end guard against the wrong-session bind: workspace/sessions/.current
# names a DIFFERENT session (sess-bound, e.g. one that fired a hook more
# recently), while the tool call under test comes from sess-live. Running
# `hq-session.sh set company_slug` from sess-live's process must bind sess-live
# — under the old .current-based resolution it bound sess-bound instead,
# reported success, and sess-live stayed blocked forever.
install_fixture ""
cp "$ROOT/core/scripts/hq-session.sh" "$TMP/core/scripts/"
chmod +x "$TMP/core/scripts/hq-session.sh"

read_payload='{"tool_name":"Read","session_id":"sess-live","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/indigo/settings/foo.yaml"}}'
rc="$(run_hook "$read_payload")"
[ "$rc" = "2" ] || fail "expected exit 2 before binding sess-live, got $rc"
grep -q "Session: sess-live" "$TMP/err.txt" || fail "block message must name the blocked session"

# Pin the fixture as the HQ root. hq-session.sh resolves it as
# ${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-<its own path>}}, and a developer running this
# suite from inside a Claude session inherits CLAUDE_PROJECT_DIR pointing at the
# REAL checkout — so the bind landed in the developer's own workspace/sessions/
# and this case failed with "bind did not mint a capability". CI sets neither
# variable and fell through to the script's path, which is why it only ever
# failed locally. Pinning both makes the fixture authoritative either way, and
# stops the suite writing a company binding into a real tree.
env -u HQ_SESSION_ID -u CLAUDE_SESSION_ID -u CODEX_SESSION_ID -u CODEX_THREAD_ID \
  HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
  CLAUDE_CODE_SESSION_ID=sess-live \
  bash "$TMP/core/scripts/hq-session.sh" set company_slug indigo >/dev/null

[ -f "$TMP/workspace/sessions/sess-live/scope-capability.json" ] \
  || fail "bind did not mint a capability for the live session"
if [ -f "$TMP/workspace/sessions/sess-bound/scope-capability.json" ]; then
  fail "bind leaked into the .current session"
fi

rc="$(run_hook "$read_payload")"
[ "$rc" = "0" ] || fail "expected allow after binding sess-live, got $rc"

# The .current session must still be unbound, and still blocked.
payload='{"tool_name":"Read","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/indigo/settings/foo.yaml"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected the unrelated .current session to stay unbound, got $rc"

echo "[16] Bash allows manifest mentions and placeholder company segments"
install_fixture "indigo"
for command in \
  'cat companies/manifest.yaml' \
  'printf %s companies/${co}/settings/x' \
  'cat companies/(shell-expanded)/settings/x'; do
  payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
    '{tool_name: "Bash", session_id: "sess-bound", cwd: $cwd, tool_input: {command: $command}}')"
  rc="$(run_hook "$payload")"
  [ "$rc" = "0" ] || fail "expected allow for $command, got $rc"
done

echo "[17] Bash still blocks a literal, existing cross-company target"
install_fixture "indigo"
payload='{"tool_name":"Bash","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"command":"cat companies/otherco/settings/secret.yaml"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected block for literal otherco path, got $rc"


echo "[18] a call with NO identifiable session is denied, not guessed"
# Fail closed. Test [15] guards the WRITE side of the .current problem (a bind
# landing on someone else's session); this guards the READ side. The hook used
# to fall back to workspace/sessions/.current to decide authorization, so an
# agent the host could not name inherited whatever binding that global pointer
# happened to hold.
install_fixture "indigo"
scoped_payload='{"tool_name":"Read","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/indigo/settings/foo.yaml"}}'
run_hook_env() { # run_hook_env <payload> [env assignments...]
  local pl="$1"; shift
  local rc=0
  : > "$TMP/err.txt"
  printf '%s' "$pl" | env -u HQ_SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
    -u CODEX_SESSION_ID -u CODEX_THREAD_ID "$@" \
    bash "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" 2>"$TMP/err.txt" || rc=$?
  printf '%s' "$rc"
}

rc="$(run_hook_env "$scoped_payload" HQ_TEST_MARKER=1)"
[ "$rc" = "2" ] || fail "expected exit 2 for an unidentifiable session, got '$rc'"
grep -q "NO session id" "$TMP/err.txt" || fail "message must say the call carries no session id"

echo "[19] .current is never consulted for an authorization decision"
# The fixture binds sess-bound AND points .current at it. A call carrying no
# session id must still be denied: .current names whichever session fired a hook
# most recently, which is not the caller. Before this fix the same call was
# ALLOWED, and an unbound spawned agent read another tenant's files that way
# (observed 2026-08-19 on HQ 15.0.98, reproduced 2/2).
grep -qx 'sess-bound' "$TMP/workspace/sessions/.current" \
  || fail "fixture precondition: .current must name the bound session"
[ -f "$TMP/workspace/sessions/sess-bound/scope-capability.json" ] \
  || fail "fixture precondition: the .current session must be bound"
rc="$(run_hook_env "$scoped_payload" HQ_TEST_MARKER=1)"
[ "$rc" = "2" ] || fail "expected exit 2 — .current must not authorize a call, got '$rc'"

echo "[20] an ambient session id in the environment does not authorize either"
# This assertion was inverted during review of this change. An earlier revision
# accepted the environment as a fallback identity, reasoning that the host
# exports it per process. It does — but a SPAWNED agent inherits its parent's
# value, which core/scripts/tests/hq-agent-session-hooks.test.sh case 7 documents
# and tests ("An agent session spawned from inside another session inherits that
# parent's session id"). Trusting it would authorize a payload-less child against
# its PARENT's tenant: the same cross-session failure this change closes, by a
# different route. Payload identity only.
rc="$(run_hook_env "$scoped_payload" HQ_SESSION_ID=sess-bound)"
[ "$rc" = "2" ] || fail "expected exit 2 — an ambient env id must not authorize, got '$rc'"
grep -q "NO session id" "$TMP/err.txt" || fail "message must still name the missing payload identity"

echo "[22] a child cannot inherit its parent's tenant through the environment"
# The reviewer's scenario, end to end: a payload-less child spawned from a bound
# parent inherits that parent's session id in every session variable the host
# sets. None of them may grant the child the parent's company.
for var in HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID; do
  rc="$(run_hook_env "$scoped_payload" "$var=sess-bound")"
  [ "$rc" = "2" ] || fail "expected exit 2 with inherited $var, got '$rc'"
done

echo "[21] an identified but unbound session is still denied (unchanged)"
unbound_payload='{"tool_name":"Read","session_id":"sess-live","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/indigo/settings/foo.yaml"}}'
rc="$(run_hook_env "$unbound_payload" HQ_TEST_MARKER=1)"
[ "$rc" = "2" ] || fail "expected exit 2 for an identified but unbound session, got '$rc'"
grep -q "no company_slug bound" "$TMP/err.txt" || fail "unbound session keeps its own message"


echo "[23] a continuation inside single quotes is stripped too — deliberately conservative"
# Raised in review of this change: bash does NOT treat a backslash-newline inside
# single quotes as a line continuation, it keeps both characters. The strip here
# is unconditional, so a quoted literal whose JOINED form looks like a
# cross-tenant path is denied even though the command touches no file.
#
# That is accepted, not overlooked. Making the strip quote-aware means a second
# quote-state walk of arbitrary shell text, and an error in THAT direction —
# failing to strip a real continuation — reopens the traversal this case exists
# to stop ([9]). The current error direction is a clear denial on an obscure
# input; the alternative risks a silent bypass. The three cases below pin all of
# it, so a future quote-aware rewrite has to keep [9] and the third case intact.
install_fixture "indigo"

quoted_cross='printf '"'"'companies/in\
digo/../otherco/x'"'"''
payload="$(jq -cn --arg cwd "$TMP" --arg command "$quoted_cross" \
  '{tool_name: "Bash", session_id: "sess-bound", cwd: $cwd, tool_input: {command: $command}}')"
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected the conservative block for a quoted cross-tenant literal, got $rc"

quoted_same='printf '"'"'companies/in\
digo/notes.txt'"'"''
payload="$(jq -cn --arg cwd "$TMP" --arg command "$quoted_same" \
  '{tool_name: "Bash", session_id: "sess-bound", cwd: $cwd, tool_input: {command: $command}}')"
rc="$(run_hook "$payload")"
[ "$rc" = "0" ] || fail "a quoted literal joining to an in-tenant path must stay allowed, got $rc"

echo "[24] bound indigo blocks cross-company Write / Edit / MultiEdit / NotebookEdit"
install_fixture "indigo"
for tool in Write Edit MultiEdit; do
  payload='{"tool_name":"'"$tool"'","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/otherco/settings/foo.yaml","content":"x","old_string":"a","new_string":"b","edits":[]}}'
  rc="$(run_hook "$payload")"
  [ "$rc" = "2" ] || fail "expected exit 2 for cross-company $tool, got $rc"
  grep -q "Cross-company scope violation" "$TMP/err.txt" || fail "missing block message for $tool"
done
payload='{"tool_name":"NotebookEdit","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"notebook_path":"'"$TMP"'/companies/otherco/settings/n.ipynb","new_source":"x"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected exit 2 for cross-company NotebookEdit, got $rc"

echo "[25] bound indigo allows same-company, core, personal writes"
for rel in "companies/indigo/settings/foo.yaml" "core/docs/readme.md" "personal/note.md"; do
  payload='{"tool_name":"Write","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/'"$rel"'","content":"x"}}'
  rc="$(run_hook "$payload")"
  [ "$rc" = "0" ] || fail "expected exit 0 for Write $rel, got $rc"
done

echo "[26] unbound session blocks Write under companies/*"
install_fixture ""
payload='{"tool_name":"Write","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/indigo/settings/foo.yaml","content":"x"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected exit 2 for unbound Write, got $rc"

echo "[27] a symlinked HQ root keeps absolute Read paths in tenant scope"
install_fixture "indigo"
ROOT_ALIAS="$TMP/logical-root"
ln -s "$TMP" "$ROOT_ALIAS"
run_hook_from_root_alias() {
  local payload="$1"
  local rc=0
  : > "$TMP/err.txt"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$ROOT_ALIAS" bash "$ROOT_ALIAS/.claude/hooks/mandatory-scope-authorizer.sh" 2>"$TMP/err.txt" || rc=$?
  printf '%s' "$rc"
}
payload="$(jq -cn --arg path "$ROOT_ALIAS/companies/otherco/settings/secret.yaml" --arg cwd "$ROOT_ALIAS" \
  '{tool_name:"Read",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:$path}}')"
rc="$(run_hook_from_root_alias "$payload")"
[ "$rc" = "2" ] || fail "expected cross-company Read through symlinked root to block, got $rc"
grep -q "Cross-company scope violation" "$TMP/err.txt" || fail "missing block message for symlinked root Read"

payload="$(jq -cn --arg path "$ROOT_ALIAS/companies/indigo/settings/foo.yaml" --arg cwd "$ROOT_ALIAS" \
  '{tool_name:"Read",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:$path}}')"
rc="$(run_hook_from_root_alias "$payload")"
[ "$rc" = "0" ] || fail "expected same-company Read through symlinked root to allow, got $rc"

ln -s "$TMP/companies/otherco/settings/.keep" "$TMP/companies/indigo/settings/cross-company-link"
payload="$(jq -cn --arg path "$ROOT_ALIAS/companies/indigo/settings/cross-company-link" --arg cwd "$ROOT_ALIAS" \
  '{tool_name:"Read",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:$path}}')"
rc="$(run_hook_from_root_alias "$payload")"
[ "$rc" = "2" ] || fail "expected symlink into another company through symlinked root to block, got $rc"

echo "[28] pwd -L root alias is honored when CLAUDE_PROJECT_DIR is unset"
(
  cd "$ROOT_ALIAS"
  logical_root="$(pwd -L)"
  payload="$(jq -cn --arg path "$logical_root/companies/otherco/settings/secret.yaml" --arg cwd "$logical_root" \
    '{tool_name:"Read",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:$path}}')"
  rc=0
  : > "$TMP/err.txt"
  printf '%s' "$payload" | env -u CLAUDE_PROJECT_DIR bash "$ROOT_ALIAS/.claude/hooks/mandatory-scope-authorizer.sh" 2>"$TMP/err.txt" || rc=$?
  [ "$rc" = "2" ] || fail "expected cross-company Read from pwd -L root alias to block, got $rc"
)

echo "[29] a parent segment after a symlink is resolved against the symlink target"
install_fixture "indigo"
ln -s "$TMP/companies/otherco/settings" "$TMP/companies/indigo/settings/link"
payload="$(jq -cn --arg path "companies/indigo/settings/link/../secret.yaml" --arg cwd "$TMP" \
  '{tool_name:"Read",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:$path}}')"
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected cross-company Read after symlink/.. to block, got $rc"

echo "[30] CLAUDE_PROJECT_DIR fallback accepts a logical HQ root"
install_fixture "indigo"
ROOT_ALIAS="$TMP/logical-root"
ln -s "$TMP" "$ROOT_ALIAS"
cp "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" "$TMP/hook-copy.sh"
payload="$(jq -cn --arg path "$ROOT_ALIAS/companies/otherco/settings/secret.yaml" --arg cwd "$ROOT_ALIAS" \
  '{tool_name:"Read",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:$path}}')"
rc=0
printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$ROOT_ALIAS" bash "$TMP/hook-copy.sh" 2>"$TMP/err.txt" || rc=$?
[ "$rc" = "2" ] || fail "expected CLAUDE_PROJECT_DIR root fallback to block cross-company read, got $rc"

echo "[31] pwd -L fallback accepts a logical HQ root"
(
  cd "$ROOT_ALIAS"
  logical_root="$(pwd -L)"
  payload="$(jq -cn --arg path "$logical_root/companies/otherco/settings/secret.yaml" --arg cwd "$logical_root" \
    '{tool_name:"Read",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:$path}}')"
  rc=0
  printf '%s' "$payload" | env -u CLAUDE_PROJECT_DIR bash "$TMP/hook-copy.sh" 2>"$TMP/err.txt" || rc=$?
  [ "$rc" = "2" ] || fail "expected pwd -L root fallback to block cross-company read, got $rc"
)

echo "[32] a bind that becomes visible after the initial reads is rechecked"
install_fixture ""
mkdir -p "$TMP/test-bin"
cat > "$TMP/test-bin/sleep" <<EOF
#!/usr/bin/env bash
/bin/sleep "\${1:-0}"
printf 'company_slug: indigo\\n' > "$TMP/workspace/sessions/sess-bound/meta.yaml"
EOF
chmod +x "$TMP/test-bin/sleep"
payload="$(jq -cn --arg cwd "$TMP" \
  '{tool_name:"Read",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:($cwd + "/companies/indigo/settings/foo.yaml")}}')"
rc="$(PATH="$TMP/test-bin:$PATH" run_hook "$payload")"
expect_exit 0 "$rc" "delayed bind is rechecked for the same session"
if [ ! -f "$TMP/workspace/sessions/sess-bound/meta.yaml" ]; then
  echo "FAIL: delayed bind became visible" >&2
  REGRESSION_FAILURES=$((REGRESSION_FAILURES + 1))
fi

echo "[33] Bash resolves a statically assigned same-company path variable"
install_fixture "indigo"
command='p=settings/x; cat companies/indigo/$p'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 0 "$rc" "statically assigned same-company variable is allowed"

echo "[34] Bash resolves each safe value from a bounded company-path loop"
install_fixture "indigo"
command='for p in settings/x settings/y; do cat companies/indigo/$p; done'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 0 "$rc" "safe company-path loop values are allowed"

echo "[35] Bash blocks a statically resolved other-company variable"
install_fixture "indigo"
command='co=otherco; cat companies/$co/settings/x'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "variable resolving to another company is blocked"

echo "[36] Bash blocks a loop value that traverses out of the bound company"
install_fixture "indigo"
command='for p in settings/x ../../otherco/settings/secret.yaml; do cat companies/indigo/$p; done'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "loop value traversing outside the bound company is blocked"

echo "[37] Bash ignores a foreign-company path in inert heredoc text"
install_fixture "indigo"
command=$'gh pr create --body "$(cat <<\'BODY\'\ncompanies/otherco/settings/secret.yaml\nBODY\n)"'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 0 "$rc" "foreign-company path in inert heredoc text is ignored"

echo "[38] Bash blocks a heredoc that redirects output into another company"
install_fixture "indigo"
command=$'cat <<\'BODY\' > companies/otherco/settings/generated.yaml\nconfig\nBODY'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "heredoc redirected into another company is blocked"

echo "[39] Bash scans a heredoc executed as a shell script"
install_fixture "indigo"
command=$'bash <<\'SCRIPT\'\ncat companies/otherco/settings/secret.yaml\nSCRIPT'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "foreign path in an executed heredoc remains blocked"

echo "[40] Bash blocks company-root globs that can span tenants"
install_fixture "indigo"
command='for repo in companies/*/knowledge; do printf %s "$repo"; done'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "company-root glob spanning tenants is blocked"

echo "[41] manifest is allowed beside a foreign company path, which remains blocked"
install_fixture "indigo"
command='cat companies/manifest.yaml companies/otherco/settings/x'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "foreign path beside the manifest remains blocked"

echo "[42] Bash ignores a foreign path in a direct GitHub body-file heredoc"
install_fixture "indigo"
command=$'gh pr create --body-file - <<\'BODY\'\ncompanies/otherco/settings/secret.yaml\nBODY'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 0 "$rc" "foreign-company path in a GitHub body-file heredoc is ignored"

echo "[43] Bash does not treat an echoed assignment as a shell variable value"
install_fixture "indigo"
command='echo "p=settings/x"; cat companies/indigo/$p'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "text that resembles an assignment does not resolve a variable"

echo "[44] Bash blocks a variable that is reassigned to a traversal"
install_fixture "indigo"
command='p=settings/x; p=../../otherco/settings/x; cat companies/indigo/$p'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "reassigned path variable fails closed"

echo "[45] Bash blocks a variable changed by eval before the company path"
install_fixture "indigo"
command="p=settings/x; eval 'p=../../otherco/settings/x'; cat companies/indigo/\$p"
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "variable mutation by eval fails closed"

echo "[46] Bash blocks a loop variable reassigned before the company path"
install_fixture "indigo"
command='for p in settings/x; do p=../../otherco/settings/x; cat companies/indigo/$p; done'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "reassigned loop variable fails closed"

echo "[47] Bash does not ignore a foreign path inside backtick command substitution"
install_fixture "indigo"
command='echo `cat companies/otherco/settings/secret.yaml`'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "backtick command substitution still checks the foreign path"

echo "[48] Bash does not ignore a foreign path inside dollar command substitution"
install_fixture "indigo"
command='printf "$(cat companies/otherco/settings/secret.yaml)"'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "dollar command substitution still checks the foreign path"

echo "[49] Bash scans unquoted GitHub body-file heredocs for shell expansion"
install_fixture "indigo"
command=$'gh pr create --body-file - <<BODY\n$(cat companies/otherco/settings/secret.yaml)\nBODY'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "command substitution in an unquoted GitHub body heredoc is blocked"

echo "[50] Bash blocks a foreign path echoed into a pipeline consumer"
install_fixture "indigo"
command='echo companies/otherco/settings/secret.yaml | xargs cat'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "piped echo path is checked against company scope"

echo "[51] Bash resolves repeated path occurrences from their own prefixes"
install_fixture "indigo"
command='p=settings/x; cat companies/indigo/$p; p=../../otherco/settings/secret.yaml; cat companies/indigo/$p'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "later repeated path with mutated variable is blocked"

[ "$REGRESSION_FAILURES" -eq 0 ] || fail "$REGRESSION_FAILURES mandatory scope regression cases failed"
echo "PASS: mandatory-scope-authorizer.test.sh"
