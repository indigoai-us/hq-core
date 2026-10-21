#!/bin/bash
# hq-core: public
# PostToolUse hook (Read, Bash): redact credential values from tool output
# before the model sees it.
#
# The guard block-credential-file-read.sh stops reads of known credential
# files. This hook is the backstop for output that still carries a credential
# line, for example a filtered dump such as `grep -v token ~/.npmrc` (case
# sensitive, so `_authToken` survived) or a credential copied into another file.
#
# Shapes redacted (value replaced with [REDACTED], key kept):
#   npm/yarn   //host/:_authToken=, _auth=, _password=, _authIdent=,
#              always-auth=, npmAuthToken:, npmAuthIdent:, yarn v1 `_auth "x"`
#   netrc      `password X` (inline after machine/default, or on its own line)
#   pypirc     `password = X` / `password: X` at line start
#   docker     "auth": "X", "identitytoken": "X", "registrytoken": "X"
#   keys       any key name that marks a secret (see KEYNAME below: gh
#              oauth_token, JSON "password", YAML client_secret,
#              STRIPE_SECRET_KEY, secret_key_base, quoted rubygems_api_key,
#              pass, pwd), followed by `:` or `=` and a quoted or bare value
#   .env       KEY=value at line start (optionally `export` or a compose
#              `- ` list item) when KEY is such a key name
#   http       Authorization: <scheme> X, Bearer X, X-Api-Key: X
#
# Values that are source code are not redacted by the key rules, so a Read
# of auth or config code shows the real code (see GVAL below).
#   URLs       scheme://user:PASSWORD@host, and scheme://TOKEN@host when the
#              user part is 16 or more characters (a token, not a login name)
#   aws        aws_access_key_id, aws_secret_access_key, aws_session_token
#   PEM        the body of any -----BEGIN ... PRIVATE KEY----- block
#
# Values on the line after a `key=` or `"auth":`, JSON-escaped quotes
# (\"auth\":\"X\") and quoted values are covered. A value counts as already
# redacted only when it is exactly [REDACTED] (followed by a quote, or the end
# of the line). "[REDACTED] more" or "[REDACTED]more" is redacted again up to
# the end of the line.
#
# Base64 or otherwise encoded output is not recognised; that is a limit of any
# pattern-based redactor.
#
# Claude Code applies hookSpecificOutput.updatedToolOutput only on exit 0, so
# a redaction exits 0. If redaction is needed but jq fails, exit 2 with a
# message so the failure is visible instead of silent.
set -o pipefail

INPUT=$(cat)

# Cheap precheck on the raw payload. Every shape below contains one of these
# words (JSON escaping does not touch them), or a URL with userinfo.
if ! printf '%s' "$INPUT" | LC_ALL=C grep -qiE 'auth|pass|pwd|secret|token|key|credential|bearer|://[^/[:space:]"]+@'; then
  exit 0
fi

command -v jq >/dev/null 2>&1 || {
  echo "BLOCKED: redact-credential-output needs jq to redact a possible credential in this output." >&2
  exit 2
}

# Each gsub keeps the key in group k and replaces only the value.
#   Q     optional quote, possibly JSON-escaped (\")
#   SEP   = or : with spacing
#   NL    line break between a key and its value
#   VAL   bare value; "[REDACTED] x" is redacted to the end of the line
#   VALQ  value inside quotes
# Where SEP competes with a bare-space separator the choice is atomic (?>...),
# so "key = [REDACTED]" cannot re-match with "=" as the value.
#
# jq's gsub costs about (matches x string length), so one pass over a large
# output with many hits takes minutes, and a PostToolUse timeout would let
# the output through unredacted. redact_multiline runs on the whole string
# and only matches the rare forms that span lines (PEM blocks, a value on the
# line after its key). redact_line runs on blocks of 32 lines that pass a
# cheap test; none of its patterns cross a line break, so block edges are
# safe. A single line over 4096 bytes is cut into pieces (see redact_long).
# `^` is string start in jq, so line starts are written (?:^|\n).
#
# The program is read from a quoted heredoc at top level so its regexes can
# hold single quotes. A heredoc inside $(...) is banned (bash 3.2 mis-parses
# it; hooks-heredoc-syntax.test.sh), so `read -d ''` slurps it instead.
#
# KEYNAME (any position) is a key whose name ends in secret, token,
# password, passwd or credential(s), or in KEYPFX + key (api_key, X-Api-Key,
# STRIPE_SECRET_KEY, apiKey), optionally followed by a SUFFIX word
# (secret_key_base, TOKEN_V2). "monkey", "audience_key" and "secret-scan"
# are not key names.
# ENVKEY (a KEY=value line) is any key with a segment that is such a word, a
# word ending in auth (NEXTAUTH), or pass, pwd, or key after another segment
# (DB_PASS, STRIPE_KEY). A line-start `pass:`, `pwd:` or `auth:` YAML key is
# also covered. In prose these words are not keys ("CLI auth: x").
#
# GVAL is the value for the generic key rules (any KEYNAME, the .env rule and
# the pypirc password line). Those rules also see source code on Read, so a
# value that is code is left alone: a substitution or expression start
# ($( ( [ { < = ! & | `), a literal or type word (None, null, true, string,
# read, write, ...), a call or index (z.string(), os.environ[), a dotted name
# with no digits (process.env.API_KEY), or a bare word that ends a statement
# (getToken;), a printf format (%s), or a number of up to 6 digits (ttl: 60). A quoted value or an
# Authorization value that starts with $( ${ or $NAME is a shell reference.
# GSEP does not take the = of ==, ===, =~ or =>, or the : of ::
# or :=, or the : of a shell ${X:-y} expansion. GVAL stops at & when a
# query parameter follows (?a=V&b=1).
JQ_PROG=""
IFS= read -r -d '' JQ_PROG <<'JQ' || true
  def Q: "(?:\\\\?[\"'])?";
  def SEP: "[ \\t]*[=:][ \\t]*";
  def GSEP: "[ \\t]*(?:=(?![=~>])|:(?![:=+?-]))[ \\t]*";
  def NL: "[ \\t]*\\r?\\n[ \\t]*";
  def TAIL: "\\[REDACTED\\][ \\t]*[^\\s\"'\\\\,;}\\]][^\\n]*";
  def VAL: "(?:" + TAIL + "|(?!\\[REDACTED\\])[^\\s\"'\\\\]+)";
  def CODE: "(?:[$(\\[{<=!&|`]|\\.\\.\\.|%[-0-9.]*[sdqvx](?![A-Za-z0-9])|[0-9]{1,6}(?=[\\s,;)}\\]'\"]|$)|(?:none|null|nil|true|false|undefined|string|number|boolean|bool|str|int|float|bytes|any|unknown|object|void|never|required|optional|read|write|self|this|new|await|function|lambda)(?![A-Za-z0-9_])|[A-Za-z_$][A-Za-z0-9_$]*(?:\\.[A-Za-z_$][A-Za-z0-9_$]*)*[(\\[]|[A-Za-z_$][A-Za-z_$]*(?:\\.[A-Za-z_$][A-Za-z_$]*)+(?![A-Za-z0-9_$.\\-/+=:@])|[A-Za-z_$][A-Za-z_$]*[;,)](?:\\s|$))";
  def BARE: "(?:[^\\s\"'\\\\&]|&(?![A-Za-z0-9_.\\-]+=)|\"(?=[A-Za-z0-9]))+";
  def GVAL: "(?:" + TAIL + "|(?!\\[REDACTED\\])(?!" + CODE + ")(?!\")" + BARE + ")";
  def BEARERVAL: "(?:" + TAIL + "|(?!\\[REDACTED\\])[A-Za-z0-9._~+/=-]{8,})";
  def VALQ: "(?:\\[REDACTED\\][^\"\\\\\\n]+|(?!\\[REDACTED\\])[^\"\\\\\\n]+)";
  def VALQP: "(?!\\$[({A-Za-z_]|[(\\\\]|\\.\\.\\.)(?:\\[REDACTED\\](?:[^\"\\\\\\n]|\\\\.)+|(?!\\[REDACTED\\])(?:[^\"\\\\\\n]|\\\\.)+)";
  def NPMKEY: "(?<![A-Za-z0-9])(?:_authToken|_authIdent|_auth|_password|always-auth|npmAuthToken|npmAuthIdent)";
  def KEYPFX: "(?:api|access|private|secret|session|client|master|signing|encryption|license|app|service|account|auth|admin|deploy|ssh|gpg|pgp|aes|hmac|jwt|webhook|consumer|publishable|stripe|sk|pk)";
  def SUFFIX: "(?:[_-](?:key|keys|base|value|id|data|b64|base64|hash|str|string|text|raw|enc|encrypted|plain|prod|production|dev|staging|test|live|old|new|v[0-9]+|[0-9]+))";
  def KEYNAME: "(?:[A-Za-z0-9]*(?:secret|token|password|passwd|credentials?)|" + KEYPFX + "[_-]?key)" + SUFFIX + "*(?![A-Za-z0-9])";
  def ENVKEY: "(?:[A-Za-z0-9]+[_.-])*?(?:[A-Za-z0-9]*(?:secret|token|password|passwd|credentials?|auth)|pass|pwd|apikey|(?<=[_.-])key)(?=[_.-]|[ \\t]*=)(?:[_.-][A-Za-z0-9]+)*";
  def LIMIT: 4096;
  def hot: test("auth|pass|pwd|secret|token|key|credential|bearer|://"; "i");
  def redact_multiline:
    gsub("(?<k>-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----)[\\s\\S]*?(?=-----END [A-Z0-9 ]*PRIVATE KEY-----|\\z)"; "\(.k)\n[REDACTED]\n"; "i")
    | gsub("(?<k>" + NPMKEY + Q + "[ \\t]*[=:]" + NL + Q + ")" + VAL; "\(.k)[REDACTED]"; "i")
    | gsub("(?<k>(?:^|\\n)[ \\t]*(?:password|passwd)" + Q + "[ \\t]*[=:]" + NL + Q + ")" + GVAL; "\(.k)[REDACTED]"; "i")
    | gsub("(?<k>\\\\?\"(?:auth|identitytoken|registrytoken)\\\\?\"[ \\t]*:" + NL + "\\\\?\")" + VALQ; "\(.k)[REDACTED]"; "i")
    | gsub("(?<k>" + KEYNAME + "\\\\?[\"']?[ \\t]*[:=]" + NL + "\\\\?[\"'])" + VALQ; "\(.k)[REDACTED]"; "i");
  # Rules whose value is a bare token ($v), a bearer token ($b) or a value
  # that may sit in source code ($g).
  def val_rules($v; $b; $g):
    gsub("(?<k>" + NPMKEY + Q + "(?>" + SEP + "|[ \\t]+)" + Q + ")" + $v; "\(.k)[REDACTED]"; "i")
    | gsub("(?<k>\\b(?:machine|default)\\b[^\\n]*?\\bpassword[ \\t]+)" + $v; "\(.k)[REDACTED]"; "i")
    | gsub("(?<k>(?:^|\\n)[ \\t]*(?:password|passwd)" + Q + "(?>" + GSEP + "|[ \\t]+)" + Q + ")" + $g; "\(.k)[REDACTED]"; "i")
    | gsub("(?<k>\\bauthorization" + Q + SEP + Q + "(?>(?:(?:bearer|basic|token|digest)[ \\t]+)?))(?!\\$[({A-Za-z_])" + $v; "\(.k)[REDACTED]"; "i")
    | gsub("(?<k>\\bbearer[ \\t]+)" + $b; "\(.k)[REDACTED]"; "i")
    | gsub("(?<k>\\baws_(?:access_key_id|secret_access_key|session_token)" + Q + SEP + Q + ")" + $v; "\(.k)[REDACTED]"; "i")
    | gsub("(?<k>(?:^|\\n)[ \\t]*(?:-[ \\t]+)?(?:export[ \\t]+)?" + ENVKEY + "[ \\t]*=(?![=~>])[ \\t]*" + Q + ")" + $g; "\(.k)[REDACTED]"; "i")
    | gsub("(?<k>(?:^|\\n)[ \\t]*(?:-[ \\t]+)?[\"']?(?:pass|pwd|auth)[\"']?[ \\t]*:(?![:=+?-])[ \\t]*" + Q + ")" + $g; "\(.k)[REDACTED]"; "i")
    | gsub("(?<k>" + KEYNAME + GSEP + ")" + $g; "\(.k)[REDACTED]"; "i");
  def redact_line:
    val_rules(VAL; BEARERVAL; GVAL)
    | gsub("(?<k>\\\\?\"(?:auth|identitytoken|registrytoken)\\\\?\"[ \\t]*:[ \\t]*\\\\?\")" + VALQ; "\(.k)[REDACTED]"; "i")
    | gsub("(?<k>" + KEYNAME + "[\"']?" + GSEP + "(?<!\\\\)[\"'])" + VALQP; "\(.k)[REDACTED]"; "i")
    | gsub("(?<k>" + KEYNAME + "\\\\[\"']" + GSEP + "\\\\[\"'])" + VALQ; "\(.k)[REDACTED]"; "i")
    | gsub("(?<k>[a-z][a-z0-9+.-]*://[^/\\s:@\"']+:)(?!\\$[({A-Za-z_])[^@\\s/\"']+(?=@)"; "\(.k)[REDACTED]"; "i")
    | gsub("(?<k>[a-z][a-z0-9+.-]*://)(?!\\[REDACTED\\])[^/\\s:@\"'\\\\]{16,}(?=@)"; "\(.k)[REDACTED]"; "i");
  # A line over LIMIT bytes (minified JSON) is cut into pieces of about LIMIT
  # bytes at `,"` (plain, or the `,` before an escaped `\"`). No line-rule key
  # or quoted value contains `,"`. The values that can span it are the
  # "[REDACTED] more" tails, and each runs to the end of the line, so they are
  # redacted on the whole line first (at most one match per rule). Every later
  # piece starts with a quote, so line-start rules cannot fire mid-line.
  # Known limit: a netrc `machine X ... password Y` pair split by `,"` in a line
  # over LIMIT bytes is not matched; netrc lines carry no `,"`.
  def redact_long:
    (if contains("[REDACTED]") then val_rules(TAIL; TAIL; TAIL) else . end)
    | [split(",\"") | (.[0], (.[1:][] | ",\"" + .))
       | split(",\\\"") | (.[0], (.[1:][] | ",\\\"" + .))] as $t
    | reduce range(1; $t | length) as $i ({out: [], cur: $t[0]};
        if (.cur | utf8bytelength) >= LIMIT then .out += [.cur + ","] | .cur = $t[$i][1:]
        else .cur += $t[$i] end)
    | .out + [.cur]
    | map(if hot then redact_line else . end)
    | join("");
  # Short lines go through redact_line in blocks of 32; long lines one by one.
  def redact:
    redact_multiline
    | split("\n")
    | reduce (.[], null) as $line ({out: [], blk: []};
        if $line == null or ($line | utf8bytelength) > LIMIT or (.blk | length) >= 32 then
          (if (.blk | length) > 0
           then .out += [.blk | join("\n") | if hot then redact_line else . end] | .blk = []
           else . end)
          | if $line == null then .
            elif ($line | utf8bytelength) > LIMIT then .out += [$line | redact_long]
            else .blk = [$line] end
        else .blk += [$line] end)
    | .out
    | join("\n");
  (.tool_response // null) as $orig
  | ($orig | walk(if type == "string" then redact else . end)) as $new
  | if $new == $orig then empty
    else {
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        updatedToolOutput: $new,
        additionalContext: "Credential values in this tool output were replaced with [REDACTED] by redact-credential-output. Do not try to recover them; use hq secrets exec to pass credentials to a command."
      }
    }
    end
JQ
OUT=$(printf '%s' "$INPUT" | jq -c "$JQ_PROG" 2>/dev/null)
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "BLOCKED: redact-credential-output could not parse this tool output to check it for credentials (jq exit $rc)." >&2
  exit 2
fi
[ -n "$OUT" ] && printf '%s\n' "$OUT"
exit 0
