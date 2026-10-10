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
  mkdir -p "$TMP/.claude/hooks" "$TMP/core/scripts/lib" "$TMP/core/scripts" \
    "$TMP/companies/indigo/settings" "$TMP/companies/otherco/settings" \
    "$TMP/companies/cmp_FIXTURE/settings" "$TMP/companies/cmp_OTHER/settings" \
    "$TMP/companies/_template" "$TMP/core/docs" "$TMP/personal" \
    "$TMP/workspace/sessions/sess-bound" "$TMP/home/.hq"
  cp "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" "$TMP/.claude/hooks/"
  cp "$ROOT/core/scripts/lib/session-authz.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-id.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$TMP/core/scripts/"
  mkdir -p "$TMP/.codex/hooks"
  cp "$ROOT/.codex/hooks/codex-explicit-path-flag.cjs" "$TMP/.codex/hooks/"
  cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/"
  chmod +x "$TMP/.claude/hooks/mandatory-scope-authorizer.sh"

  printf 'companies:\n  indigo:\n    name: Indigo\n  otherco:\n    name: otherco\n' \
    > "$TMP/companies/manifest.yaml"
  touch "$TMP/companies/indigo/settings/.keep" "$TMP/companies/otherco/settings/.keep"
  touch "$TMP/core/docs/readme.md" "$TMP/personal/note.md" "$TMP/companies/_template/readme.md"
  printf 'sess-bound\n' > "$TMP/workspace/sessions/.current"
  export HOME="$TMP/home"

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
  printf '%s' "$payload" | "${BASH_BIN:-bash}" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" 2>"$TMP/err.txt" || rc=$?
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
grep -Fq 'hq-session.sh set company_slug' "$TMP/err.txt" || fail "unbound session denial should explain how to bind a company"
grep -qi 'Write tool' "$TMP/err.txt" || fail "unbound session denial should direct data-file writes to the Write tool"

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
grep -qi 'Write tool' "$TMP/err.txt" || fail "bound wrong-company denial should direct data-file writes to the Write tool"

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
grep -qi 'Write tool' "$TMP/err.txt" || fail "shell-expanded company path denial should direct data-file writes to the Write tool"

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
if grep -Fq 'hq-session.sh set company_slug' "$TMP/err.txt"; then
  fail "unidentifiable session denial must not suggest binding a company"
fi

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

echo "[19] opaque case-sensitive company IDs bind exactly and keep cross-company blocking"
install_fixture "cmp_FIXTURE"
payload='{"tool_name":"Read","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/cmp_FIXTURE/settings/foo.yaml"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "0" ] || fail "expected allow for the exact opaque company ID, got $rc"
payload='{"tool_name":"Read","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/cmp_OTHER/settings/foo.yaml"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected block for a different opaque company ID, got $rc"


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
grep -qi 'Write tool' "$TMP/err.txt" || fail "heredoc company path denial should direct data-file writes to the Write tool"

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

echo "[52] Bash allows a glob after the literal bound-company prefix"
install_fixture "indigo"
touch "$TMP/companies/indigo/settings/report-a.yaml" "$TMP/companies/indigo/settings/report-b.yaml"
command='cat companies/indigo/settings/report-*.yaml'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 0 "$rc" "glob after the literal bound-company prefix is allowed"

echo "[52a] Bash 3.2-compatible glob matching tolerates missing globstar"
cat > "$TMP/bash-32-shopt.sh" <<'EOF'
shopt() {
  case " $* " in
    *" globstar "*) return 1 ;;
  esac
  builtin shopt "$@"
}
EOF
command='cat companies/indigo/settings/report-*.yaml'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc=0
printf '%s' "$payload" | BASH_ENV="$TMP/bash-32-shopt.sh" "${BASH_BIN:-bash}" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" 2>"$TMP/err.txt" || rc=$?
expect_exit 0 "$rc" "contained glob works when globstar is unavailable"

echo "[53] Bash refuses a glob in the company segment"
install_fixture "indigo"
command='cat companies/ind*/settings/*.yaml'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "glob in the company segment is refused"
grep -Fq "companies/ind*/settings/*.yaml" "$TMP/err.txt" || fail "company-segment glob block names the glob"
command='cat companies/[io]therco/settings/*.yaml'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "character class selecting another company is refused"

echo "[54] Bash refuses a glob under another company"
install_fixture "indigo"
command='cat companies/otherco/settings/*.yaml'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "glob under another company is refused"
grep -Fq "the literal prefix before the glob does not resolve inside companies/indigo" "$TMP/err.txt" || fail "other-company glob is refused by its out-of-scope prefix"

echo "[55] Bash refuses a glob that escapes the bound company with parent segments"
install_fixture "indigo"
command='cat companies/indigo/settings/../../otherco/settings/*.yaml'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "parent traversal glob escape is refused"
grep -Fq "the literal prefix before the glob does not resolve inside companies/indigo" "$TMP/err.txt" || fail "parent traversal glob is refused by its normalized prefix"

echo "[56] Bash refuses a glob through a symlink into another company"
install_fixture "indigo"
ln -s "$TMP/companies/otherco/settings" "$TMP/companies/indigo/settings/foreign-link"
touch "$TMP/companies/otherco/settings/escape.yaml"
command='cat companies/indigo/settings/foreign-link/*.yaml'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "symlink glob escape is refused"
grep -Fq "the literal prefix before the glob does not resolve inside companies/indigo" "$TMP/err.txt" || fail "symlink glob is refused by its resolved out-of-scope prefix"

echo "[57] Bash refuses brace expansion that reaches another company"
install_fixture "indigo"
command='cat companies/{indigo,otherco}/settings/.keep'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "brace expansion reaching another company is refused"
grep -Fq "companies/{indigo,otherco}/settings/.keep" "$TMP/err.txt" || fail "brace glob block names the glob"

echo "[58] Bash refuses a glob when no company is bound"
install_fixture ""
command='cat companies/indigo/settings/*.yaml'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "unbound session glob is refused"

echo "[59] Bash refuses a glob match that escapes after a literal bound-company prefix"
install_fixture "indigo"
touch "$TMP/companies/otherco/settings/leak.yaml"
command='cat companies/indigo/set*/../../otherco/settings/*.yaml'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "per-match realpath escape after glob is refused"
grep -Fq "a glob match resolves outside companies/indigo" "$TMP/err.txt" || fail "post-glob traversal is refused by per-match realpath check"

echo "[60] Bash allows an absolute glob below the bound-company prefix"
install_fixture "indigo"
touch "$TMP/companies/indigo/settings/report-absolute.yaml"
command="cat $TMP/companies/indigo/settings/report-*.yaml"
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 0 "$rc" "absolute bound-company glob is allowed"

echo "[61] Bash refuses an absolute glob below another company"
install_fixture "indigo"
touch "$TMP/companies/otherco/settings/report-absolute.yaml"
command="cat $TMP/companies/otherco/settings/report-*.yaml"
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "absolute other-company glob is refused"
grep -Fq "the literal prefix before the glob does not resolve inside companies/indigo" "$TMP/err.txt" || fail "absolute other-company glob is refused by its out-of-scope prefix"

echo "[62] Bash refuses brace expansion under the bound company"
install_fixture "indigo"
command='mkdir -p companies/indigo/settings/{a,b}'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "brace expansion under bound company remains refused"
grep -Fq "brace expansion cannot be checked safely" "$TMP/err.txt" || fail "bound-company brace refusal gives the brace reason"

echo "[63] same-session Task subagents use distinct bindings and never fall back"
install_fixture "indigo"
. "$ROOT/core/scripts/lib/session-scope-capability.sh"
session_scope_mint "$TMP" "sess-bound" "indigo" "agent-A"
session_scope_mint "$TMP" "sess-bound" "otherco" "agent-B"
caller_payload() {
  local aid="$1" atype="$2" company="$3" sid="${4:-sess-bound}"
  jq -cn --arg cwd "$TMP" --arg aid "$aid" --arg atype "$atype" --arg company "$company" --arg sid "$sid" \
    '{tool_name:"Write",session_id:$sid,cwd:$cwd,
      agent_id:$aid,agent_type:$atype,
      tool_input:{file_path:($cwd + "/companies/" + $company + "/settings/foo.yaml")}}'
}
rc="$(run_hook "$(caller_payload agent-A general-purpose indigo)")"
expect_exit 0 "$rc" "agent A writes within A"
rc="$(run_hook "$(caller_payload agent-A general-purpose otherco)")"
expect_exit 2 "$rc" "agent A cannot write within B"
rc="$(run_hook "$(caller_payload agent-B general-purpose otherco)")"
expect_exit 0 "$rc" "agent B writes within B"
rc="$(run_hook "$(caller_payload agent-B general-purpose indigo)")"
expect_exit 2 "$rc" "agent B cannot write within A"

echo "[64] unbound and malformed subagent identities fail closed"
mkdir -p "$TMP/workspace/sessions/sess-nocap"
rc="$(run_hook "$(caller_payload agent-unbound general-purpose indigo sess-nocap)")"
expect_exit 2 "$rc" "unbound subagent tuple with no parent capability is denied"
grep -qi 'restart or respawn the subagent' "$TMP/err.txt" || fail "valid but unbound subagent denial tells the caller to restart or respawn"
rc="$(run_hook "$(caller_payload '../agent-A' general-purpose indigo)")"
expect_exit 2 "$rc" "malformed agent_id is denied"
payload="$(jq -cn --arg cwd "$TMP" \
  '{tool_name:"Write",session_id:"sess-bound",cwd:$cwd,agent_id:7,agent_type:"general-purpose",
    tool_input:{file_path:($cwd + "/companies/indigo/settings/foo.yaml")}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "non-string agent_id is denied"
grep -qi 'invalid agent_id' "$TMP/err.txt" || fail "non-string agent_id is not coerced into a caller identity"
rc="$(run_hook "$(caller_payload agent-A '' indigo '../sess-bound')")"
expect_exit 2 "$rc" "malformed session_id is denied"
grep -qi 'invalid session_id' "$TMP/err.txt" || fail "malformed session denial identifies the invalid caller identity"
rc="$(run_hook "$(caller_payload '' general-purpose indigo)")"
expect_exit 2 "$rc" "agent_type without agent_id is denied"
grep -qi 'restart the session' "$TMP/err.txt" || fail "missing-id subagent denial tells the caller to restart"
rc="$(run_hook "$(caller_payload agent-A '' indigo)")"
expect_exit 0 "$rc" "valid agent_id selects tuple even when agent_type is absent"

echo "[65] main thread keeps its legacy session binding"
rc="$(run_hook "$(caller_payload '' '' indigo)")"
expect_exit 0 "$rc" "main thread without agent identity uses session binding"

echo "[66] Task subagent inherits its parent's capability on first use"
# Claude Code fires no SessionStart for a Task subagent (feedback_284bc210), so
# the child tuple is pinned from the parent's main-thread capability.
FX_SUBAGENT="$ROOT/core/scripts/tests/fixtures/scope-authorizer/pretooluse-task-subagent.json"
FX_SID="$(jq -r '.session_id' "$FX_SUBAGENT")"
FX_AID="$(jq -r '.agent_id' "$FX_SUBAGENT")"
FX_TUPLE="$TMP/workspace/sessions/$FX_SID/agents/$FX_AID/scope-capability.json"
fixture_payload() {
  local company="$1"
  sed -e "s#__HQ_ROOT__#$TMP#g" -e "s#__COMPANY__#$company#g" "$FX_SUBAGENT" | jq -c .
}
install_fixture ""
. "$ROOT/core/scripts/lib/session-scope-capability.sh"
mkdir -p "$TMP/workspace/sessions/$FX_SID"
session_scope_mint "$TMP" "$FX_SID" "indigo"
[ ! -e "$FX_TUPLE" ] || fail "fixture tuple must not exist before the first call"
rc="$(run_hook "$(fixture_payload indigo)")"
expect_exit 0 "$rc" "new subagent reads its parent's company"
[ "$(jq -r '.company_slug' "$FX_TUPLE" 2>/dev/null)" = "indigo" ] || fail "child tuple should record the parent's company"
[ "$(jq -r '.agent_id' "$FX_TUPLE" 2>/dev/null)" = "$FX_AID" ] || fail "child tuple should name the subagent"
rc="$(run_hook "$(fixture_payload otherco)")"
expect_exit 2 "$rc" "new subagent cannot read outside its parent's company"
[ "$(jq -r '.company_slug' "$FX_TUPLE")" = "indigo" ] || fail "denied call must not change the child tuple"

echo "[66a] meta.yaml without a parent capability never binds a subagent"
install_fixture ""
mkdir -p "$TMP/workspace/sessions/$FX_SID"
printf 'company_slug: indigo\n' > "$TMP/workspace/sessions/$FX_SID/meta.yaml"
rc="$(run_hook "$(fixture_payload indigo)")"
expect_exit 2 "$rc" "subagent with only parent meta.yaml is denied"
grep -qi 'restart or respawn the subagent' "$TMP/err.txt" || fail "unbound subagent denial tells the caller to respawn"
[ ! -e "$FX_TUPLE" ] || fail "no child tuple may be minted from meta.yaml"

echo "[66b] parent rebind after the child's first call does not move the child"
install_fixture ""
mkdir -p "$TMP/workspace/sessions/$FX_SID"
session_scope_mint "$TMP" "$FX_SID" "indigo"
rc="$(run_hook "$(fixture_payload indigo)")"
expect_exit 0 "$rc" "child first call pins the parent's company"
session_scope_mint_set "$TMP" "$FX_SID" "otherco"
rc="$(run_hook "$(fixture_payload otherco)")"
expect_exit 2 "$rc" "child cannot follow the parent's rebind"
rc="$(run_hook "$(fixture_payload indigo)")"
expect_exit 0 "$rc" "child keeps its original company"
[ "$(jq -r '.company_slug' "$FX_TUPLE")" = "indigo" ] || fail "child tuple must not be rewritten after a parent rebind"
main_payload="$(fixture_payload otherco | jq -c 'del(.agent_id, .agent_type)')"
rc="$(run_hook "$main_payload")"
expect_exit 0 "$rc" "parent main thread uses its new binding"

echo "[66c] an existing malformed child tuple is never overwritten"
install_fixture ""
mkdir -p "$TMP/workspace/sessions/$FX_SID/agents/$FX_AID"
session_scope_mint "$TMP" "$FX_SID" "indigo"
printf '{"session_id":"%s","agent_id":"%s","company_slug":"../x"}\n' "$FX_SID" "$FX_AID" > "$FX_TUPLE"
rc="$(run_hook "$(fixture_payload indigo)")"
expect_exit 2 "$rc" "malformed child tuple fails closed"
[ "$(jq -r '.company_slug' "$FX_TUPLE")" = "../x" ] || fail "malformed child tuple must not be replaced by inheritance"

echo "[66d] legacy session-only capability still authorizes the main thread"
install_fixture ""
mkdir -p "$TMP/workspace/sessions/legacy-sid"
jq -n '{session_id:"legacy-sid",company_slug:"indigo",minted_at:"2026-10-05T00:00:00Z"}' \
  > "$TMP/workspace/sessions/legacy-sid/scope-capability.json"
payload="$(jq -cn --arg cwd "$TMP" \
  '{tool_name:"Write",session_id:"legacy-sid",cwd:$cwd,tool_input:{file_path:($cwd + "/companies/indigo/settings/foo.yaml")}}')"
rc="$(run_hook "$payload")"
expect_exit 0 "$rc" "legacy capability still authorizes main thread"

echo "[67] quoted cat heredoc body is data written to an allowed workspace target"
install_fixture "indigo"
mkdir -p "$TMP/workspace/hq-core"
command=$'cat > workspace/hq-core/note.md <<\'EOF\'\nsee companies/indigo/projects/$p/prd.json\nEOF'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 0 "$rc" "quoted heredoc body mentioning a company path is literal data"

echo "[68] unquoted cat heredoc body allows plain variable text at an allowed target"
install_fixture "indigo"
mkdir -p "$TMP/workspace/hq-core"
command=$'cat > workspace/hq-core/note.md <<EOF\nsee companies/indigo/projects/$p/prd.json\nEOF'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 0 "$rc" "unquoted heredoc plain variable text is not a filesystem operand"

echo "[68a] tee heredoc body is data written to an allowed workspace target"
install_fixture "indigo"
mkdir -p "$TMP/workspace/hq-core"
command=$'tee > workspace/hq-core/note.md <<EOF\nsee companies/indigo/projects/$p/prd.json\nEOF'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 0 "$rc" "tee redirect keeps unquoted heredoc plain text out of path checks"

echo "[69] unresolved list-derived company paths stay blocked"
install_fixture "indigo"
command='for p in $(ls companies/*/projects); do cat companies/$p/prd.json; done'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "command-substitution loop with unresolved company path is refused"

echo "[70] heredoc redirect to another company stays blocked"
install_fixture "indigo"
command=$'cat > companies/otherco/settings/note.md <<EOF\nplain data\nEOF'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "heredoc output redirect to another company is refused"

echo "[71] heredoc fed to bash remains fully scanned"
install_fixture "indigo"
command=$'bash <<EOF\ncat companies/otherco/settings/secret.yaml\nEOF'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "interpreter heredoc body is fully scanned"

echo "[72] command substitution in an unquoted data heredoc remains checked"
install_fixture "indigo"
mkdir -p "$TMP/workspace/hq-core"
command=$'cat > workspace/hq-core/note.md <<EOF\n$(cat companies/otherco/settings/secret.yaml)\nEOF'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "unquoted heredoc command substitution is scanned"

# Expected exit 2: the path is unresolvable when the hook checks it, so the guard fails closed (IC-0019, #1135).
echo "[73] unresolved workspace positional path is denied without confinement proof"
install_fixture "indigo"
command='function read_brief() { cat companies/indigo/settings/.keep; cat --brief-file workspace/lane-briefs/hq-core/$2; }; read_brief --company indigo note.md'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
if [ "$rc" != "0" ]; then cat "$TMP/err.txt" >&2; fi
expect_exit 2 "$rc" "workspace positional expansion fails closed"

echo "[74] unresolved companies positional operand stays blocked with workspace path"
install_fixture "indigo"
command='function read_brief() { cat companies/$1/settings/.keep; cat --brief-file workspace/lane-briefs/hq-core/$2; }; read_brief otherco note.md'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "unresolved companies positional operand remains blocked"

echo "[75] quoted text option keeps a company-looking string out of path checks"
install_fixture "indigo"
command='hq dm send --text "See companies/indigo/projects/$p/prd.json and core/scripts/resumework.sh"'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 0 "$rc" "quoted --text content is data, not a path operand"

echo "[76] same quoted company string is blocked when cat opens it"
install_fixture "indigo"
command='cat "companies/indigo/projects/$p/prd.json"'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "quoted company path opened by cat remains blocked"

echo "[77] workspace heredoc prose names company and script paths with variable text"
install_fixture "indigo"
mkdir -p "$TMP/workspace/hq-core"
command=$'cat > workspace/hq-core/note.md <<EOF\nReview companies/indigo/projects/$p/prd.json and core/scripts/resumework.sh before shipping.\nEOF'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 0 "$rc" "heredoc prose paths and plain variable text remain data"

echo "[78] heredoc's same company path is blocked when cat opens it"
install_fixture "indigo"
command='cat "companies/indigo/projects/$p/prd.json"'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "company path named in prose is blocked as a real cat operand"

# Expected exit 2: the path is unresolvable when the hook checks it, so the guard fails closed (IC-0019, #1135).
echo "[79] unknown positional and loop values under workspace fail closed"
install_fixture "indigo"
command='function write_brief() { hq docs create --text-file workspace/lane-briefs/hq-core/$2; for p in one two; do printf "%s\\n" "workspace/lane-briefs/hq-core/$p"; done; }; write_brief --company indigo brief.md'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
if [ "$rc" != "0" ]; then cat "$TMP/err.txt" >&2; fi
expect_exit 2 "$rc" "text-file workspace path with unresolved values fails closed"

# Expected exit 2: the path is unresolvable when the hook checks it, so the guard fails closed (IC-0019, #1135).
echo "[80] function positional workspace path fails closed beside a literal company path"
install_fixture "indigo"
command='mk(){ cat companies/indigo/projects/a/p; cat --brief-file workspace/lane-briefs/hq-core/$2; }; mk a b.md; mk c c.md'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
if [ "$rc" != "0" ]; then cat "$TMP/err.txt" >&2; fi
expect_exit 2 "$rc" "function positional workspace path lacks confinement proof"

echo "[81] function positional traversal into another company stays blocked"
install_fixture "indigo"
command='mk(){ cat --brief-file workspace/lane-briefs/hq-core/$2; }; mk a ../../companies/otherco/s'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "function positional traversal into another company is blocked"

echo "[82] unresolved workspace positional operand is denied without confinement proof"
install_fixture "indigo"
command='cat workspace/$1'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "unresolved workspace positional operand fails closed"
grep -Fq 'Path: workspace/$1' "$TMP/err.txt" || fail "unresolved workspace positional denial should print the literal operand"

# Expected exit 2: the path is unresolvable when the hook checks it, so the guard fails closed (IC-0019, #1135).
echo "[83] workspace loop values fail closed without confinement proof"
install_fixture "indigo"
command='for l in A B; do ls workspace/lanes-runs/${l}_x/; done'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "workspace loop values are not proven confined"

echo "[84] hq lanes message body is inert message text"
install_fixture "indigo"
command='hq lanes message lane-1 --text "Review companies/otherco/s"'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 0 "$rc" "hq lanes message text is not a file operand"

echo "[85] gh pr comment body is inert message text"
install_fixture "indigo"
command='gh pr comment 1132 --body "Review companies/otherco/s"'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 0 "$rc" "gh pr comment body is not a file operand"

echo "[86] python body text that names a company remains blocked"
install_fixture "indigo"
command='python3 tool.py --body "companies/otherco/s"'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "python body value is not covered by the text-only command exemption"

echo "[87] unresolved workspace path is denied beside a company operand"
install_fixture "indigo"
command='cat companies/indigo/projects/a/p; cat workspace/x/$2'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "unknown workspace positional operand fails closed beside a company path"
grep -Fq 'Path: workspace/x/$2' "$TMP/err.txt" || fail "workspace positional denial beside a company path should print the literal operand"

echo "[88] unresolved personal path is denied without confinement proof"
install_fixture "indigo"
command='cat personal/$x'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "unknown personal operand fails closed"
grep -Fq 'Path: personal/$x' "$TMP/err.txt" || fail "personal positional denial should print the literal operand"

echo "[89] unresolved function positional path under workspace fails closed"
install_fixture "indigo"
command='mk(){ cat --brief-file workspace/lane-briefs/hq-core/$2; }; mk a good.md; mk a "$target"'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "unknown workspace function argument fails closed"

echo "[90] workspace variable assigned literally in the command resolves"
install_fixture "indigo"
command='brief=b.md; cat workspace/lane-briefs/hq-core/$brief'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 0 "$rc" "literal workspace assignment resolves"

echo "[91] git -C resolves pwd forms against the command cwd"
install_fixture "indigo"
mkdir -p "$TMP/companies/indigo/projects/a" "$TMP/companies/otherco"
for command in \
  'git -C "$(pwd)/companies/indigo/projects/a" status' \
  'git -C "$PWD/companies/indigo/projects/a" status' \
  'git -C "$(pwd -P)/companies/indigo/projects/a" status'; do
  payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
    '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
  rc="$(run_hook "$payload")"
  if [ "$rc" != "0" ]; then cat "$TMP/err.txt" >&2; fi
  expect_exit 0 "$rc" "git -C resolves a safe pwd form to the bound company"
done

echo "[92] git -C pwd form still blocks another company"
install_fixture "indigo"
mkdir -p "$TMP/companies/otherco"
command='git -C "$(pwd)/companies/otherco" status'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "git -C pwd expansion to another company remains blocked"

echo "[93] enabled ordered lock permits A and B while C and malformed sets fail closed"
install_fixture "indigo"
mkdir -p "$TMP/flagbin"
cat >"$TMP/flagbin/node" <<'NODE'
#!/bin/sh
printf 'true\n'
NODE
chmod +x "$TMP/flagbin/node"
. "$ROOT/core/scripts/lib/session-scope-capability.sh"
session_scope_mint_set "$TMP" sess-bound indigo,otherco
ORIGINAL_PATH="$PATH"
export PATH="$TMP/flagbin:$PATH"
for co in indigo otherco; do
  payload="$(jq -cn --arg cwd "$TMP" --arg co "$co" \
    '{tool_name:"Write",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:($cwd + "/companies/" + $co + "/settings/new.yaml")}}')"
  rc="$(run_hook "$payload")"
  expect_exit 0 "$rc" "locked session writes within $co"
done
payload="$(jq -cn --arg cwd "$TMP" '{tool_name:"Read",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:($cwd + "/companies/cmp_FIXTURE/settings/x")}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "locked A+B session still blocks C"
mkdir -p "$TMP/workspace/sessions/sess-unbound"
payload="$(jq -cn --arg cwd "$TMP" '{tool_name:"Read",session_id:"sess-unbound",cwd:$cwd,tool_input:{file_path:($cwd + "/companies/indigo/settings/x")}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "multi-company flag does not bind an unbound session"
jq '.company_slugs = ["indigo", 3]' "$TMP/workspace/sessions/sess-bound/scope-capability.json" >"$TMP/malformed-cap.json"
cp "$TMP/malformed-cap.json" "$TMP/workspace/sessions/sess-bound/scope-capability.json"
payload="$(jq -cn --arg cwd "$TMP" '{tool_name:"Read",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:($cwd + "/companies/indigo/settings/x")}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "malformed company_slugs capability fails closed"
payload="$(jq -cn --arg cwd "$TMP" '{tool_name:"Read",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:($cwd + "/companies/indigo")}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "malformed company_slugs capability blocks primary company root"
cat >"$TMP/flagbin/node" <<'NODE'
#!/bin/sh
printf 'false\n'
NODE
chmod +x "$TMP/flagbin/node"
session_scope_mint_set "$TMP" sess-bound indigo,otherco
rm -f "$HOME/.hq/hook-flag.multi-company-session-lock.indigo"
payload="$(jq -cn --arg cwd "$TMP" '{tool_name:"Write",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:($cwd + "/companies/otherco/settings/blocked.yaml")}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "explicit multi-company false keeps authorizer on primary only"
export PATH="$ORIGINAL_PATH"

[ "$REGRESSION_FAILURES" -eq 0 ] || fail "$REGRESSION_FAILURES mandatory scope regression cases failed"
echo "PASS: mandatory-scope-authorizer.test.sh"
