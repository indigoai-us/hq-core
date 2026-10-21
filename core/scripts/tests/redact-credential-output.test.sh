#!/usr/bin/env bash
# hq-core: public
# redact-credential-output.test.sh — the PostToolUse redactor replaces
# credential values in Read and Bash output with [REDACTED].
#
# Regression for the 2026-10-20 incident: `grep -v token` is case-sensitive,
# so an npm `_authToken` line reached the session, and no PostToolUse hook
# rewrote tool output at all.
#
# Every value is a fake canary built by this script. A test fails if the
# canary appears anywhere in the hook output.
#
# Sections:
#   [1] one case per token shape (Bash stdout)
#   [2] Read tool response shape
#   [3] controls: ordinary output is left unchanged (no hook output)
#   [4] fail closed: unparseable payload that looks like a credential
#   [5] profile matrix: hook-gate runs the redactor under minimal, standard, strict
#   [6] master-hook PostToolUse dispatch keeps the redacted output
#   [7] review round 2 leak shapes and new shapes (stdout and stderr)
#   [8] round 2 controls: idempotent on already-redacted values, no false hits
#   [9] large outputs finish well inside the hook timeout and stay redacted
#   [10] round 3: source code on Read is unchanged (code shapes, shell
#        references, prose), hyphenated headers, more key spellings,
#        query-string values, embedded and escaped quotes
#
# Sections [1], [3], [7] and [8] run every case twice, once with the text in
# stdout and once in stderr.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
HOOK="$ROOT/.claude/hooks/redact-credential-output.sh"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
MASTER="$ROOT/.claude/hooks/master-hook.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }
[ -f "$HOOK" ] || { echo "FAIL: missing $HOOK" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/redact-cred-out.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

CANARY="canary-FAKE-NOT-A-TOKEN-$$"

# payload_bash TEXT [STREAM] — STREAM is stdout (default) or stderr.
payload_bash() {
  local o="" e=""
  if [ "${2:-stdout}" = "stderr" ]; then e="$1"; else o="$1"; fi
  jq -nc --arg o "$o" --arg e "$e" --arg d "$ROOT" \
    '{hook_event_name:"PostToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:"cat x"},tool_response:{stdout:$o,stderr:$e,interrupted:false}}'
}

# redacts NAME TEXT EXPECT — TEXT contains $CANARY; the hook must exit 0, emit
# updatedToolOutput, drop the canary, and leave EXPECT (the kept key) in place.
redacts() {
  local name="$1" text="$2" expect="$3" rc stream out
  for stream in stdout stderr; do
    rc=0
    payload_bash "$text" "$stream" | bash "$HOOK" >"$TMP/out" 2>"$TMP/err" || rc=$?
    out="$(jq -r --arg s "$stream" '.hookSpecificOutput.updatedToolOutput[$s] // empty' "$TMP/out" 2>/dev/null)"
    if [ "$rc" != "0" ]; then
      bad "$name ($stream): want rc 0 got $rc err=$(head -c 200 "$TMP/err" | tr '\n' ' ')"
    elif grep -qF "$CANARY" "$TMP/out" "$TMP/err"; then
      bad "$name ($stream): canary leaked"
    elif [ -z "$out" ]; then
      bad "$name ($stream): no updatedToolOutput"
    elif ! printf '%s' "$out" | grep -qF -e "${expect}[REDACTED]"; then
      bad "$name ($stream): expected '${expect}[REDACTED]' in: $(printf '%s' "$out" | tr '\n' ' ')"
    else
      ok "$name ($stream)"
    fi
  done
}

# unchanged NAME TEXT — the hook exits 0 with no output.
unchanged() {
  local name="$1" text="$2" rc stream
  for stream in stdout stderr; do
    rc=0
    payload_bash "$text" "$stream" | bash "$HOOK" >"$TMP/out" 2>"$TMP/err" || rc=$?
    if [ "$rc" = "0" ] && [ ! -s "$TMP/out" ]; then
      ok "control: $name ($stream)"
    else
      bad "control: $name ($stream) rc=$rc out=$(head -c 200 "$TMP/out")"
    fi
  done
}

echo "[1] token shapes"
redacts "npm //host/:_authToken=" "//registry.example.invalid/:_authToken=$CANARY" "_authToken="
redacts "npm _authToken mixed case key" "//r.example.invalid/:_AUTHTOKEN=$CANARY" "_AUTHTOKEN="
redacts "npm _auth=" "_auth=$CANARY" "_auth="
redacts "npm _auth with spaces" "_auth = $CANARY" "_auth = "
redacts "npm _password=" "//r.example.invalid/:_password=$CANARY" "_password="
redacts "npm _password quoted" "//r.example.invalid/:_password=\"$CANARY\"" "_password=\""
redacts "npm _authIdent=" "_authIdent=$CANARY" "_authIdent="
redacts "npm always-auth" "always-auth=$CANARY" "always-auth="
redacts "yarn v1 _auth quoted" "_auth \"$CANARY\"" "_auth \""
redacts "yarn berry npmAuthToken" "npmAuthToken: $CANARY" "npmAuthToken: "
redacts "yarn berry npmAuthIdent" "npmAuthIdent: \"$CANARY\"" "npmAuthIdent: \""
redacts "npm line after grep -v token" "registry=https://registry.example.invalid/
//registry.example.invalid/:_authToken=$CANARY" "_authToken="
redacts "netrc inline password" "machine example.invalid login fake password $CANARY" "password "
redacts "netrc default inline" "default login fake password $CANARY" "password "
redacts "netrc multi-line password" "machine example.invalid
  login fake
  password $CANARY" "password "
redacts "pypirc password =" "[pypi]
username = fake
password = $CANARY" "password = "
redacts "pypirc password:" "password: $CANARY" "password: "
redacts "docker auth" "{\"auths\":{\"example.invalid\":{\"auth\":\"$CANARY\"}}}" "\"auth\":\""
redacts "docker auth spaced" "{ \"auth\" : \"$CANARY\" }" "\"auth\" : \""
redacts "docker identitytoken" "{\"identitytoken\":\"$CANARY\"}" "\"identitytoken\":\""
redacts "gh oauth_token" "github.com:
    oauth_token: $CANARY
    user: fake" "oauth_token: "
redacts "git-credentials https" "https://fake:$CANARY@example.invalid" "https://fake:"
redacts "git-credentials http in text" "remote: http://user:$CANARY@git.example.invalid/x.git" "http://user:"
redacts "aws secret key" "aws_secret_access_key = $CANARY" "aws_secret_access_key = "
redacts "aws session token" "aws_session_token=$CANARY" "aws_session_token="
redacts "rubygems api key" ":rubygems_api_key: $CANARY" ":rubygems_api_key: "

# Every value on a multi-shape dump is redacted, not just the first.
rc=0
payload_bash "_authToken=$CANARY
password $CANARY
https://u:$CANARY@h.example.invalid" | bash "$HOOK" >"$TMP/out" 2>&1 || rc=$?
if [ "$rc" = "0" ] && [ -s "$TMP/out" ] && ! grep -qF "$CANARY" "$TMP/out"; then
  ok "multi-shape dump fully redacted"
else
  bad "multi-shape dump rc=$rc"
fi

echo "[2] Read tool response"
rc=0
jq -nc --arg c "//registry.example.invalid/:_authToken=$CANARY" \
  '{hook_event_name:"PostToolUse",tool_name:"Read",tool_input:{file_path:"/x/notes.txt"},tool_response:{type:"text",file:{filePath:"/x/notes.txt",content:$c,numLines:1,startLine:1,totalLines:1}}}' \
  | bash "$HOOK" >"$TMP/out" 2>"$TMP/err" || rc=$?
if [ "$rc" = "0" ] && ! grep -qF "$CANARY" "$TMP/out" \
  && [ "$(jq -r '.hookSpecificOutput.updatedToolOutput.file.content' "$TMP/out")" = "//registry.example.invalid/:_authToken=[REDACTED]" ] \
  && [ "$(jq -r '.hookSpecificOutput.updatedToolOutput.file.numLines' "$TMP/out")" = "1" ]; then
  ok "Read response content redacted, other fields kept"
else
  bad "Read response rc=$rc out=$(head -c 300 "$TMP/out")"
fi

echo "[3] controls"
unchanged "plain text" "hello world"
unchanged "url without userinfo" "see https://github.com/example/repo and fake@example.invalid"
unchanged "prose about passwords" "the author wrote a password policy doc"
unchanged "already redacted" "_authToken=[REDACTED]"
unchanged "npm registry line" "registry=https://registry.example.invalid/"
unchanged "cut -d= -f1 key names" "API_KEY
_authToken
DATABASE_URL"
unchanged "empty output" ""

echo "[7] review round 2 shapes"
# PEM armour lines are assembled from parts so secret scanners do not flag
# this file. The block bodies are the fake canary.
PK="PRIVATE"
PEM_O="-----BEGIN OPENSSH $PK KEY-----"
PEM_O_END="-----END OPENSSH $PK KEY-----"
PEM_R="-----BEGIN RSA $PK KEY-----"
PEM_R_END="-----END RSA $PK KEY-----"
CR=$'\r'
# Leak shapes from the 1480 review.
redacts "value on the next line after _authToken=" "_authToken=
$CANARY" "_authToken=
"
redacts "value on the next line after _authToken = (CRLF)" "_authToken = $CR
  $CANARY" "_authToken = $CR
  "
redacts "JSON-escaped docker auth" "{\\\"auth\\\":\\\"$CANARY\\\"}" "{\\\"auth\\\":\\\""
redacts "docker auth value on the next line" "{\"auth\":
\"$CANARY\"}" "\"auth\":
\""
redacts "quoted YAML rubygems_api_key" "rubygems_api_key: \"$CANARY\"" "rubygems_api_key: \""
redacts "single-quoted YAML client_secret" "client_secret: '$CANARY'" "client_secret: '"
redacts "token as URL user, no password" "https://$CANARY@git.example.invalid/org/repo.git" "https://"
redacts "[REDACTED] followed by more text" "_authToken = [REDACTED] $CANARY" "_authToken = "
redacts "password [REDACTED] glued to more text" "password [REDACTED]$CANARY" "password "
redacts "JSON [REDACTED] glued to more text" "{\"auth\":\"[REDACTED]$CANARY\"}" "\"auth\":\""
# New shapes.
redacts ".env SECRET" "STRIPE_SECRET=$CANARY" "STRIPE_SECRET="
redacts ".env TOKEN" "GITHUB_TOKEN=$CANARY" "GITHUB_TOKEN="
redacts ".env KEY" "OPENAI_API_KEY=$CANARY" "OPENAI_API_KEY="
redacts ".env password lower case" "db_password=$CANARY" "db_password="
redacts ".env AUTH" "NEXTAUTH=$CANARY" "NEXTAUTH="
redacts ".env CREDENTIAL" "SERVICE_CREDENTIALS=$CANARY" "SERVICE_CREDENTIALS="
redacts ".env export double-quoted" "export SLACK_BOT_TOKEN=\"$CANARY\"" "export SLACK_BOT_TOKEN=\""
redacts ".env export single-quoted" "export SIGNING_KEY='$CANARY'" "export SIGNING_KEY='"
redacts ".env after other lines" "NODE_ENV=production
APP_SECRET=$CANARY" "APP_SECRET="
redacts "Authorization: Bearer" "Authorization: Bearer $CANARY" "Authorization: Bearer "
redacts "authorization: basic lower case" "authorization: basic $CANARY" "authorization: basic "
redacts "curl -v Authorization: token" "> Authorization: token $CANARY" "Authorization: token "
redacts "plain Bearer" "sent bearer $CANARY to the api" "bearer "
redacts "aws_access_key_id" "aws_access_key_id = $CANARY" "aws_access_key_id = "
redacts "AWS_SECRET_ACCESS_KEY env form" "AWS_SECRET_ACCESS_KEY=$CANARY" "AWS_SECRET_ACCESS_KEY="
redacts "JSON password" "{\"password\": \"$CANARY\"}" "\"password\": \""
redacts "JSON apiKey" "{\"apiKey\":\"$CANARY\"}" "\"apiKey\":\""
redacts "PEM private key block" "$PEM_O
$CANARY
$CANARY
$PEM_O_END" "$PEM_O
"
redacts "PEM private key with no END line" "$PEM_R
$CANARY" "$PEM_R
"

echo "[8] round 2 controls"
unchanged "already redacted, end of line" "_authToken = [REDACTED]
registry=https://registry.example.invalid/"
unchanged "already redacted, JSON" "{\"auth\":\"[REDACTED]\"}"
unchanged "already redacted, escaped JSON" "{\\\"auth\\\":\\\"[REDACTED]\\\"}"
unchanged "already redacted, Bearer" "Authorization: Bearer [REDACTED]"
unchanged "already redacted, URL user" "https://[REDACTED]@github.com/org/repo"
unchanged "already redacted, PEM" "$PEM_R
[REDACTED]
$PEM_R_END"
unchanged "short URL user" "git clone ssh://git@git.example.invalid/org/repo.git"
unchanged "public key block" "-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE
-----END PUBLIC KEY-----"
unchanged "env without secret keys" "NODE_ENV=production
PORT=3000"
unchanged "prose about tokens" "rotate the token before the release"

echo "[10] round 3: source code on Read is unchanged, new secret shapes"
# read_unchanged NAME TEXT — a Read of TEXT gets no hook output (the model
# sees the file as it is, so Edit old_string copied from it still matches).
read_unchanged() {
  local rc=0
  jq -nc --arg c "$2" \
    '{hook_event_name:"PostToolUse",tool_name:"Read",tool_input:{file_path:"/x/src/a.ts"},tool_response:{type:"text",file:{filePath:"/x/src/a.ts",content:$c,numLines:1,startLine:1,totalLines:1}}}' \
    | bash "$HOOK" >"$TMP/out" 2>"$TMP/err" || rc=$?
  if [ "$rc" = "0" ] && [ ! -s "$TMP/out" ]; then
    ok "Read control: $1"
  else
    bad "Read control: $1 rc=$rc out=$(head -c 300 "$TMP/out")"
  fi
}
# The three code shapes from the round 3 review (M1).
for t in "jq: (.providerSecret == null)" "AUTH_UID=\$(id -u)" "SECRET_ENV_MAP=\"\""; do
  read_unchanged "$t" "$t"
  unchanged "$t" "$t"
done
# Corey C3 code shapes and related source lines.
for t in \
  "export interface Session { token: string; userId: string }" \
  "const apiKey = process.env.API_KEY;" \
  "z.object({ password: z.string().min(8) })" \
  "if (password === \"\")" \
  "if (token != expected) throw new Error()" \
  "def check(password=None, token=None):" \
  "secret = os.environ[\"APP_SECRET\"]" \
  "monkey=banana" \
  "SECRET_SOURCE_LIST=(a b)" \
  "API_TOKEN=\${API_TOKEN:-}" \
  "const token = getToken();" \
  "self.token = token;" \
  "let password = \"\";" \
  "permissions: id-token: write" \
  "match password { Some(p) => p, None => \"\" }" \
  "Auto-password protection is on" \
  "  token=\"\$(curl -s -X PUT 'http://192.0.2.10/latest/api/token' \\" \
  "    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)\"" \
  "  -H \"Authorization: Bearer \${SLACK_TOKEN}\" \\" \
  "PUSH_URL=\"https://x-access-token:\${GH_PUSH_TOKEN}@github.com/o/r.git\"" \
  "printf 'x-outpost-instance-token: %s\\n' \"\$TOKEN\" > \"\$F\"" \
  "agent-browser fill @e1 \"\$INVOICE_PASSWORD\"   # from hq secrets" \
  "hq secrets exec --only APP_PASSWORD -- bash -c 'x'" \
  "printf '%s' \"\${HQ_JOB_PROBE_CODEX_AUTH:-\${HOME}/x.json}\"" \
  ": \"\${APP_AUTH:?Set APP_AUTH}\"" \
  "#   APP_AUTH - Login password" \
  "#   - Missing runtime CLI auth: classify auth, notify re-login" \
  "echo \"secret-scan: pattern '\$name' matched\"" \
  "SECRET_PATTERN_BOUNDARY='(^|[^a-zA-Z0-9])'" \
  "DEDUP_KEY=\"\\\"thread_id\\\":\\\"\$ID\\\"\"" \
  "audience_key: company   # or 16-hex key" \
  "\"path-key\": \"^3.1.1\"," \
  "After sign-off, run a Design Delta pass: what changed" \
  "ALL STORIES PASS:   done" \
  "export APP_USERNAME='...' APP_AUTH='...'"; do
  read_unchanged "$t" "$t"
done
redacts ".env DB_PASS" "DB_PASS=$CANARY" "DB_PASS="
redacts ".env STRIPE_KEY" "STRIPE_KEY=$CANARY" "STRIPE_KEY="
redacts "YAML auth at line start" "auth: $CANARY" "auth: "
redacts "URL password literal next to a variable form" "https://user:$CANARY@example.invalid" "https://user:"
# Real values in the same shapes are still redacted.
redacts "code: literal assigned to apiKey" "const apiKey = \"$CANARY\";" "const apiKey = \""
redacts "code: python default literal" "def check(password=\"$CANARY\"):" "password=\""
redacts ".env real value" "AUTH_SECRET=$CANARY" "AUTH_SECRET="
# M2 / Corey I2: hyphenated header names and other key spellings.
redacts "X-Api-Key header" "X-Api-Key: $CANARY" "X-Api-Key: "
redacts "x-api-key lower case" "x-api-key: $CANARY" "x-api-key: "
redacts "X-Auth-Token header" "X-Auth-Token: $CANARY" "X-Auth-Token: "
redacts "YAML STRIPE_SECRET_KEY" "STRIPE_SECRET_KEY: $CANARY" "STRIPE_SECRET_KEY: "
redacts "compose list item" "  - STRIPE_SECRET_KEY=$CANARY" "  - STRIPE_SECRET_KEY="
redacts "Rails secret_key_base" "secret_key_base: $CANARY" "secret_key_base: "
redacts "JSON SECRET_KEY" "{\"SECRET_KEY\": \"$CANARY\"}" "\"SECRET_KEY\": \""
redacts "pass:" "pass: $CANARY" "pass: "
redacts "pwd=" "pwd=$CANARY" "pwd="
# L1: a query-string token stops at &, and the next parameter is kept.
redacts "query-string token" "https://example.invalid/cb?access_token=$CANARY&state=xyz" "access_token="
rc=0
payload_bash "https://example.invalid/cb?access_token=$CANARY&state=xyz" | bash "$HOOK" >"$TMP/out" 2>"$TMP/err" || rc=$?
if [ "$(jq -r '.hookSpecificOutput.updatedToolOutput.stdout' "$TMP/out" 2>/dev/null)" = "https://example.invalid/cb?access_token=[REDACTED]&state=xyz" ]; then
  ok "query-string token: following parameters kept"
else
  bad "query-string token: got $(head -c 300 "$TMP/out")"
fi
redacts "query-string password with & inside" "pw?password=$CANARY&x" "password="
# Corey I1: partial leaks through embedded or JSON-escaped quotes.
redacts "bare value with an embedded quote" "password=abc\"$CANARY" "password="
redacts "JSON value with escaped quotes" "{\"password\":\"FAKE\\\"$CANARY\\\"inner\"}" "\"password\":\""

echo "[9] large outputs"
# A PostToolUse timeout lets output through unredacted, so size is a
# correctness case. jq's gsub costs about (matches x string length): before the
# 32-line blocks and the long-line pieces, the 20000-line case took about two
# minutes and the 1 MB single line about 45 seconds. The hook's timeout is 30 s.
# big_case NAME FILE EXPECTED — FILE is the raw stdout. The hook must finish in
# under 20 s, drop every canary, and (when EXPECTED is a file) produce exactly it.
big_case() {
  local name="$1" file="$2" expected="$3" rc=0 t0 secs
  jq -Rsc --arg d "$ROOT" \
    '{hook_event_name:"PostToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:"cat x"},tool_response:{stdout:.,stderr:"",interrupted:false}}' \
    "$file" >"$TMP/big.json"
  t0=$SECONDS
  bash "$HOOK" <"$TMP/big.json" >"$TMP/out" 2>"$TMP/err" || rc=$?
  secs=$((SECONDS - t0))
  if [ "$rc" != "0" ]; then
    bad "$name: want rc 0 got $rc"
  elif [ "$secs" -ge 20 ]; then
    bad "$name: took ${secs}s (limit 20s)"
  elif grep -qF "$CANARY" "$TMP/out" "$TMP/err"; then
    bad "$name: canary leaked"
  elif [ -n "$expected" ] && ! jq -j '.hookSpecificOutput.updatedToolOutput.stdout' "$TMP/out" | cmp -s - "$expected"; then
    bad "$name: output differs from the expected redaction"
  else
    ok "$name (${secs}s)"
  fi
}
awk -v c="$CANARY" 'BEGIN { for (i = 0; i < 20000; i++) printf "line %d password=%s-%d\n", i, c, i }' >"$TMP/lines.txt"
big_case "20000 lines, a password on every line" "$TMP/lines.txt" ""
# One minified JSON line of about 1 MB. Every record is redacted, so the values
# next to each internal cut are covered; the rest of the line is byte-identical.
awk -v c="$CANARY" 'BEGIN { printf "{"; for (i = 0; i < 20000; i++) printf "\"password\":\"%s-%d\",\"name\":\"n%d\",", c, i, i; printf "\"x\":1}" }' >"$TMP/line.txt"
awk 'BEGIN { printf "{"; for (i = 0; i < 20000; i++) printf "\"password\":\"[REDACTED]\",\"name\":\"n%d\",", i; printf "\"x\":1}" }' >"$TMP/line.want"
big_case "1 MB minified JSON line" "$TMP/line.txt" "$TMP/line.want"
# The same line JSON-escaped inside a string (cut at ,\").
awk -v c="$CANARY" 'BEGIN { printf "{\\\"log\\\":1"; for (i = 0; i < 20000; i++) printf ",\\\"apiKey\\\":\\\"%s-%d\\\",\\\"n\\\":%d", c, i, i; printf "}" }' >"$TMP/esc.txt"
big_case "1 MB JSON-escaped line" "$TMP/esc.txt" ""
# "[REDACTED] more" at the start of a long line: the tail runs past many cuts.
awk -v c="$CANARY" 'BEGIN { printf "password: [REDACTED] x"; for (i = 0; i < 20000; i++) printf ",\"k%d\":\"%s\"", i, c; printf "\n" }' >"$TMP/tail.txt"
printf 'password: [REDACTED]\n' >"$TMP/tail.want"
big_case "redacted-tail across a long line" "$TMP/tail.txt" "$TMP/tail.want"

echo "[4] fail closed"
rc=0
printf '{"tool_response":{"stdout":"_authToken=%s"' "$CANARY" | bash "$HOOK" >"$TMP/out" 2>"$TMP/err" || rc=$?
if [ "$rc" = "2" ] && ! grep -qF "$CANARY" "$TMP/out" "$TMP/err"; then
  ok "truncated JSON with a credential shape blocks (rc=2)"
else
  bad "truncated JSON want rc 2 got $rc"
fi
rc=0
printf 'not json at all' | bash "$HOOK" >"$TMP/out" 2>"$TMP/err" || rc=$?
[ "$rc" = "0" ] && [ ! -s "$TMP/out" ] && ok "garbage without a credential shape passes" \
  || bad "garbage without a credential shape rc=$rc"

echo "[5] profile matrix via hook-gate"
for p in minimal standard strict; do
  rc=0
  payload_bash "//registry.example.invalid/:_authToken=$CANARY" \
    | HQ_HOOK_PROFILE="$p" HQ_HOOK_TIMEOUT_SENTRY=0 CLAUDE_PROJECT_DIR="$ROOT" \
      bash "$GATE" redact-credential-output "$HOOK" >"$TMP/out" 2>"$TMP/err" || rc=$?
  if [ "$rc" = "0" ] && grep -q '"updatedToolOutput"' "$TMP/out" && ! grep -qF "$CANARY" "$TMP/out" "$TMP/err"; then
    ok "hook-gate profile=$p redacts"
  else
    bad "hook-gate profile=$p rc=$rc out=$(head -c 200 "$TMP/out") err=$(head -c 200 "$TMP/err" | tr '\n' ' ')"
  fi
done

echo "[6] master-hook PostToolUse dispatch"
export HQ_HOOK_DEDUPE=0 HQ_ALLOW_HQ_WORKTREE=1 HQ_HOOK_TIMEOUT_SENTRY=0
for p in minimal standard strict; do
  for tool in Bash Read; do
    if [ "$tool" = "Bash" ]; then
      pl="$(payload_bash "//registry.example.invalid/:_authToken=$CANARY")"
    else
      pl="$(jq -nc --arg c "_authToken=$CANARY" --arg d "$ROOT" \
        '{hook_event_name:"PostToolUse",tool_name:"Read",cwd:$d,tool_input:{file_path:"/x/notes.txt"},tool_response:{type:"text",file:{filePath:"/x/notes.txt",content:$c}}}')"
    fi
    rc=0
    printf '%s' "$pl" | HQ_HOOK_PROFILE="$p" CLAUDE_PROJECT_DIR="$ROOT" \
      bash "$MASTER" PostToolUse >"$TMP/out" 2>"$TMP/err" || rc=$?
    if [ "$rc" = "0" ] && grep -q '"updatedToolOutput"' "$TMP/out" && ! grep -qF "$CANARY" "$TMP/out"; then
      ok "master-hook profile=$p $tool redacted"
    else
      bad "master-hook profile=$p $tool rc=$rc out=$(head -c 300 "$TMP/out") err=$(head -c 300 "$TMP/err" | tr '\n' ' ')"
    fi
  done
done

if [ "$fail" -eq 0 ]; then
  echo "ALL PASS: redact-credential-output ($pass)"
  exit 0
fi
echo "FAILURES: redact-credential-output ($fail failed, $pass passed)" >&2
exit 1
