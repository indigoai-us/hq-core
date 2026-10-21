#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID
export HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" HQ_HQ_SESSION_NO_CLI=1
mkdir -p "$TMP/workspace/sessions/foreign" "$TMP/companies/acme" "$TMP/bin"
printf 'foreign\n' > "$TMP/workspace/sessions/.current"
printf 'session_id: foreign\ncompany_slug: acme\nsenior: user\n' > "$TMP/workspace/sessions/foreign/meta.yaml"
cp "$TMP/workspace/sessions/foreign/meta.yaml" "$TMP/before"
HS="$ROOT/core/scripts/hq-session.sh"
# Legacy current remains useful for read-only diagnostics, never writes.
[ "$(bash "$HS" current)" = foreign ]
for args in 'set senior user' 'set company_slug acme' 'add company acme' 'remove company acme'; do
 if bash "$HS" $args >"$TMP/out" 2>"$TMP/err"; then echo "FAIL: missing identity permitted $args" >&2; exit 1; fi
 grep -q -- '--session-id' "$TMP/err"
 cmp "$TMP/before" "$TMP/workspace/sessions/foreign/meta.yaml"
done
# Authoritative identity of every supported harness targets its own record.
for var in HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID; do
 env "$var=own-$var" bash "$HS" set senior user
 test -f "$TMP/workspace/sessions/own-$var/meta.yaml"
 cmp "$TMP/before" "$TMP/workspace/sessions/foreign/meta.yaml"
done
bash "$HS" --session-id explicit set senior user
test -f "$TMP/workspace/sessions/explicit/meta.yaml"
if CLAUDE_CODE_SESSION_ID=../escape bash "$HS" set senior user >/dev/null 2>&1; then echo 'FAIL: invalid identity fell back' >&2; exit 1; fi
# CLI forwarding must not bypass the same preflight, even with a cached capability.
printf '#!/usr/bin/env bash\nprintf "called\\n" >> "$HQ_TEST_CLI_CALLS"\n' > "$TMP/bin/hq"
chmod +x "$TMP/bin/hq"
printf 'hq-session exact-company-directory-match-v1\n' > "$TMP/caps"
export HQ_TEST_CLI_CALLS="$TMP/cli-calls"
if PATH="$TMP/bin:$PATH" HQ_HQ_SESSION_NO_CLI=0 HQ_CLI_CAPS_CACHE="$TMP/caps" bash "$HS" set senior user >/dev/null 2>&1; then echo 'FAIL: CLI forwarding bypassed identity' >&2; exit 1; fi
test ! -e "$TMP/cli-calls"
echo 'PASS: untrusted pointer cannot mutate any session; six harness identities and explicit targeting preserved'
