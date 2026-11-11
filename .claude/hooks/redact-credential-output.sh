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
#
# Size cap. The redaction passes cost about 2.7 s per MB of text that has a
# key word on most lines (measured on an Apple silicon Mac), so
# a 5 MB output took 14 s and a 50 MB output about 3 minutes, past the 30 s
# hook timeout. The strings in tool_response share a scan window of WINDOW
# characters (160 KiB, about 0.45 s of worst-case scanning). An output that
# fits is scanned in full exactly as before. In a larger output, strings are
# taken smallest first and each gets an equal share of what is left; a string
# longer than its share is scanned in its first 4/5 and last 1/5, and the
# middle is passed through unchanged. The cuts are placed so that a key,
# value or PEM block split by a cut is either redacted or inside the gap
# (see redact_window). additionalContext then names each gap by characters
# and lines, says a credential there may be shown as-is, and says how to read
# that part in smaller, fully checked pieces. The hook never reports a partly
# scanned output as clean. The precheck still runs over the whole payload, so
# an output with no key word anywhere still exits early with no notice.
#
# Time budget: jq runs under BUDGET seconds (10) with coreutils timeout or a
# perl alarm. If it runs out, the hook exits 2 with a message that the output
# was not checked, well before the 30 s registry timeout. Tests may lower
# both through HQ_REDACT_OUTPUT_WINDOW and HQ_REDACT_OUTPUT_BUDGET (positive
# integers; anything else is ignored).
set -o pipefail

WINDOW=163840
BUDGET=10
case "${HQ_REDACT_OUTPUT_WINDOW:-}" in ''|*[!0-9]*|0*) ;; *) WINDOW=$HQ_REDACT_OUTPUT_WINDOW ;; esac
case "${HQ_REDACT_OUTPUT_BUDGET:-}" in ''|*[!0-9]*|0*) ;; *) BUDGET=$HQ_REDACT_OUTPUT_BUDGET ;; esac

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
  # The (?<!...) makes the first branch start only at the start of a letter or
  # digit run. It matches the same text (a match inside a run is always also
  # a match from the run start, which comes first), but without it a long run
  # of letters and digits cost time that grows with the square of its length
  # in redact_multiline, which sees the whole string.
  def KEYNAME: "(?:(?<![A-Za-z0-9])[A-Za-z0-9]*(?:secret|token|password|passwd|credentials?)|" + KEYPFX + "[_-]?key)" + SUFFIX + "*(?![A-Za-z0-9])";
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
  # Offsets below are characters, found with match, split and length. jq's
  # index and rindex count bytes, which is wrong after any non-ASCII text.
  # Character offset of the first line break at or after $i, else length.
  def next_nl($i):
    ([.[$i:] | match("\n")] | .[0]) as $m
    | if $m == null then length else $i + $m.offset end;
  def PEMBEGIN: "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----";
  def PEMEND: "-----END [A-Z0-9 ]*PRIVATE KEY-----";
  # A string longer than its share $w. The scanned head is $s[:$h] and the
  # scanned tail $s[$c:]; the gap reported as not fully checked is [$h, $g).
  # Head: the first 4/5 of $w, cut after the last line break within LIMIT
  # before that point. With no line break there (one long line), the cut
  # moves back to the start of the token it splits (a run with no blank,
  # quote or backslash), or, when that token is over LIMIT characters, to the
  # start of the line, so no value prefix is left in the head. A key or PEM block cut at $h is redacted up to the cut
  # (PEM to the end of the piece) and the rest is in the gap.
  # Tail: starts at $t, the line start at or after the last 1/5 of $w (the
  # end of the string when there is none, so a long last line is all gap).
  # The rules that span lines need only the line before (a value on the line
  # after its key), so the tail is scanned from the start of that line ($c).
  # When that line is over LIMIT characters, or starts before $h, it is not
  # rescanned; the gap then runs to the end of the tail's first line instead. When a PEM BEGIN before
  # $t has no END before $t, the gap runs past the next END line (or to the
  # end). Text in [$c, $g) is redacted where a rule matches but is still
  # reported, so a missed shape there is flagged, not passed as checked.
  def redact_window($w):
    . as $s | length as $n
    | ($w - (($w / 5) | floor)) as $hi
    | ([$hi - LIMIT, 0] | max) as $a
    | ($s[$a:$hi] | split("\n")) as $hp
    | (if ($hp | length) >= 2 then $hi - ($hp[-1] | length)
       else ($hi - ($s[$a:$hi] | match("[^\\s\"'\\\\]*$") | .length)) as $k
         | (if $k == $a and $a > 0 then $a - ($s[:$a] | split("\n") | .[-1] | length)
            else $k end) end) as $h
    | ([$s | next_nl([$n - (($w / 5) | floor), $h] | max) + 1, $n] | min) as $t
    | ($s[([$t - LIMIT - 1, $h] | max):($t - 1)] | split("\n")) as $pp
    | (if $t >= $n then {c: $n, g: $n}
       elif ($pp | length) >= 2 then {c: ($t - 1 - ($pp[-1] | length)), g: $t}
       else {c: $t, g: ($s | next_nl($t))} end) as $cg
    | ([$s[:$t] | match(PEMBEGIN; "gi")] | last) as $b
    | ([$s[:$t] | match(PEMEND; "gi")] | last) as $e
    | (if $b != null and ($e == null or $e.offset < $b.offset) then
         ([$s[$t:] | match(PEMEND; "i")] | .[0]) as $ne
         | (if $ne == null then $n else $t + $ne.offset + $ne.length end)
       else $t end) as $pg
    | ([$cg.c, $h] | max) as $c
    | ([$cg.g, $pg, $h] | max) as $g
    | {text: (($s[:$h] | redact) + $s[$h:$c] + ($s[$c:] | redact)),
       from: $h, to: $g, len: $n};
  # 1-based line of character offset $i (the line that holds character $i + 1).
  def line_at($i): (.[:$i] | split("\n") | length);
  def notice($gaps):
    "redact-credential-output did not fully check this tool output for credentials, because it is over the "
    + ($window | tostring) + "-character scan limit. Not fully checked: "
    + ($gaps[:5] | map("characters " + ((.from + 1) | tostring) + " to " + (.to | tostring)
        + " (lines " + (.line_from | tostring) + " to " + (.line_to | tostring) + ") of " + .field
        + " (" + (.len | tostring) + " characters)") | join("; "))
    + (if ($gaps | length) > 5 then "; and " + (($gaps | length) - 5 | tostring) + " more fields" else "" end)
    + ". Character and line numbers count the output as the tool returned it, before redaction (for Read, the lines of the returned content). Any credential in those ranges may be shown as-is, not redacted; do not repeat or use it. To inspect a range, read it in smaller pieces (Read with offset and limit, or sed -n, head or tail on a file), which are checked in full.";
  (.tool_response // null) as $orig
  | [$orig | paths(type == "string")] as $paths
  | ([$paths[] as $p | {p: $p, n: ($orig | getpath($p) | length)}] | sort_by(.n)) as $items
  | if ([$items[].n] | add // 0) <= $window then
      {new: ($orig | walk(if type == "string" then redact else . end)), gaps: []}
    else
      # Smallest strings first; each takes an equal share of what is left.
      reduce $items[] as $it ({new: $orig, gaps: [], left: $window, rem: ($items | length)};
        ((.left / .rem) | floor) as $share
        | ($orig | getpath($it.p)) as $s
        | if $it.n <= $share then
            .new |= setpath($it.p; $s | redact) | .left -= $it.n
          else
            ($s | redact_window([$share, 1] | max)) as $r
            | .new |= setpath($it.p; $r.text) | .left -= $share
            | if $r.to > $r.from then
                .gaps += [{field: ($it.p | map(tostring) | join(".")), from: $r.from, to: $r.to, len: $r.len,
                           line_from: ($s | line_at($r.from)), line_to: ($s | line_at([$r.to - 1, $r.from] | max))}]
              else . end
          end
        | .rem -= 1)
    end
  | . as $res
  | ($res.new != $orig) as $changed
  | if ($changed | not) and ($res.gaps | length) == 0 then empty
    else {
      hookSpecificOutput: ({hookEventName: "PostToolUse"}
        + (if $changed then {updatedToolOutput: $res.new} else {} end)
        + {additionalContext: ([
            (if $changed then "Credential values in this tool output were replaced with [REDACTED] by redact-credential-output. Do not try to recover them; use hq secrets exec to pass credentials to a command." else empty end),
            (if ($res.gaps | length) > 0 then notice($res.gaps) else empty end)
          ] | join("\n\n"))})
    }
    end
JQ
# jq under the time budget: coreutils timeout (exit 124), else a perl alarm
# that survives exec and kills jq itself (exit 142). With neither, jq runs
# under the registry timeout alone.
if command -v timeout >/dev/null 2>&1; then
  OUT=$(printf '%s' "$INPUT" | timeout -s KILL "$BUDGET" jq -c --argjson window "$WINDOW" "$JQ_PROG" 2>/dev/null)
elif command -v perl >/dev/null 2>&1; then
  OUT=$(printf '%s' "$INPUT" | LC_ALL=C perl -e 'alarm shift; exec @ARGV or exit 127' "$BUDGET" jq -c --argjson window "$WINDOW" "$JQ_PROG" 2>/dev/null)
else
  OUT=$(printf '%s' "$INPUT" | jq -c --argjson window "$WINDOW" "$JQ_PROG" 2>/dev/null)
fi
rc=$?
case "$rc" in
  124|137|142)
    echo "BLOCKED: redact-credential-output did not finish checking this tool output for credentials within ${BUDGET}s (exit $rc), so none of it was checked or redacted. Do not repeat any credential value it shows; read the output again in smaller pieces, which are checked in full." >&2
    exit 2 ;;
esac
if [ "$rc" -ne 0 ]; then
  echo "BLOCKED: redact-credential-output could not parse this tool output to check it for credentials (jq exit $rc)." >&2
  exit 2
fi
[ -n "$OUT" ] && printf '%s\n' "$OUT"
exit 0
