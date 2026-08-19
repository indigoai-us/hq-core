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

install_fixture() {
  local bound="${1:-}"
  rm -rf "$TMP"/*
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

echo "[6] Bash allows an unresolved company segment"
install_fixture "indigo"
payload='{"tool_name":"Bash","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"command":"co=otherco; cat companies/$co/settings/x"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "0" ] || fail "expected allow for unresolved company segment, got $rc"

echo "[7] Bash blocks expansion in the remainder of a company path"
install_fixture "indigo"
payload='{"tool_name":"Bash","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"command":"p=../../otherco/settings/secret.yaml; cat companies/indigo/$p"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected block for an expansion in a company path, got $rc"

echo "[8] Bash allows a line-continued unresolved company segment"
install_fixture "indigo"
command=$'co=otherco; cat companies/\\\n$co/settings/x'
payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
  '{tool_name: "Bash", session_id: "sess-bound", cwd: $cwd, tool_input: {command: $command}}')"
rc="$(run_hook "$payload")"
[ "$rc" = "0" ] || fail "expected allow for line-continued unresolved company segment, got $rc"

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

echo "PASS: mandatory-scope-authorizer.test.sh"
