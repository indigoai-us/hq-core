#!/usr/bin/env bash
# hq-core: public
# Decision-only coverage: payload commands, browser exports and Python edits
# are never executed. Run with Bash3.2 and5; the inner hook uses that same Bash.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TEST_SHELL="${BASH}"
FIXTURE="$(mktemp -d)"
FIXTURE="$(cd "$FIXTURE" && pwd -P)"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/.claude/hooks" "$FIXTURE/core/scripts/lib" \
  "$FIXTURE/workspace/sessions/uri-fixture" "$FIXTURE/workspace/output" \
  "$FIXTURE/companies/indigo/settings" "$FIXTURE/companies/otherco/settings"
cp "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" "$FIXTURE/.claude/hooks/"
cp "$ROOT/core/scripts/hook-lib.sh" "$FIXTURE/core/scripts/"
for lib in session-authz session-scope-capability session-id hook-caller-lineage; do
  cp "$ROOT/core/scripts/lib/$lib.sh" "$FIXTURE/core/scripts/lib/"
done
printf 'companies:\n  indigo:\n    name: Indigo\n  otherco:\n    name: Other\n' > "$FIXTURE/companies/manifest.yaml"
printf 'company_slug: indigo\n' > "$FIXTURE/workspace/sessions/uri-fixture/meta.yaml"
printf '{"session_id":"uri-fixture","company_slug":"indigo","minted_at":"2026-10-22T00:00:00Z"}\n' > "$FIXTURE/workspace/sessions/uri-fixture/scope-capability.json"
printf 'original fixture\n' > "$FIXTURE/companies/indigo/settings/README.md"
printf 'foreign fixture\n' > "$FIXTURE/companies/otherco/settings/README.md"
mkdir -p "$FIXTURE/companies/indigo/settings/space dir"
printf 'space fixture\n' > "$FIXTURE/companies/indigo/settings/space dir/README.md"
ln -s "$FIXTURE/companies/otherco/settings" "$FIXTURE/companies/indigo/settings/foreign-link"
# Browser lexical normalization must not be confused with physical symlink resolution.
mkdir -p "$FIXTURE/companies/indigo/settings/deeper/a/b"
ln -s "$FIXTURE/companies/indigo/settings/deeper/a/b" "$FIXTURE/companies/indigo/settings/deep"
PASS=0 FAIL=0
case_decision() {
  local wanted="$1" name="$2" command="$3" payload rc=0
  payload="$(jq -nc --arg root "$FIXTURE" --arg command "$command" \
    '{tool_name:"Bash",session_id:"uri-fixture",cwd:$root,tool_input:{command:$command}}')"
  # Do not use `bash` here: that would silently test Bash5 when this suite is
  # running under stock macOS Bash3.2.
  HQ_ROOT="$FIXTURE" CLAUDE_PROJECT_DIR="$FIXTURE" HQ_CLI_BIN="$FIXTURE/missing-cli" \
    TMPDIR="$FIXTURE" "$TEST_SHELL" "$FIXTURE/.claude/hooks/mandatory-scope-authorizer.sh" \
    <<< "$payload" > "$FIXTURE/out" 2> "$FIXTURE/err" || rc=$?
  if [ "$rc" = "$wanted" ] && ! grep -q 'No such file or directory' "$FIXTURE/err"; then
    PASS=$((PASS + 1)); printf 'PASS %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL %s expected=%s actual=%s\n' "$name" "$wanted" "$rc"
    cat "$FIXTURE/err"
  fi
}
printf 'Inner hook shell: %s (%s)\n' "$TEST_SHELL" "$BASH_VERSION"
uri="file://$FIXTURE/companies/indigo/settings/README.md"
foreign="file://$FIXTURE/companies/otherco/settings/README.md"
case_decision 2 bare-bound-query "google-chrome --headless --print-to-pdf=workspace/output/export.pdf \"$uri?segment=all\""
case_decision 2 bare-bound-fragment "google-chrome --headless \"$uri#section\""
case_decision 2 bare-bound-query-fragment "chromium --headless --disable-gpu \"$uri?segment=all#section\""
case_decision 0 quoted-browser-binary "\"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome\" --headless --print-to-pdf=workspace/output/export.pdf \"$uri?segment=all\""
browser='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
case_decision 0 absolute-query-fragment "\"$browser\" --headless \"$uri?segment=all#section\""
case_decision 0 absolute-fragment "\"$browser\" --headless \"$uri#section\""
case_decision 0 absolute-simple-data "\"$browser\" --headless \"$uri?a=one&b=two-three_four#part2\""
case_decision 0 absolute-space-path "\"$browser\" --headless \"file://$FIXTURE/companies/indigo/settings/space dir/README.md?segment=all\""
case_decision 2 absolute-trailing-command "\"$browser\" --headless \"$uri?segment=all\"; true"
case_decision 2 absolute-leading-command "true; \"$browser\" --headless \"$uri?segment=all\""
case_decision 2 absolute-wrapper "env \"$browser\" --headless \"$uri?segment=all\""
# Preserve URI-path refusal independently of URL-data admission.
plain_dot="file://$FIXTURE/companies/indigo/settings/deep/../../../otherco/settings/README.md"
case_decision 2 bare-plain-dot-segment "google-chrome \"$plain_dot\""
case_decision 2 absolute-plain-dot-segment "\"$browser\" \"$plain_dot\""
case_decision 2 bare-query-dot-segment "google-chrome \"$plain_dot?segment=all\""
case_decision 2 bare-plain-foreign "google-chrome \"$foreign\""
case_decision 0 absolute-plain-own "\"$browser\" \"$uri\""
case_decision 2 setup-plain-dot-segment "hash -r; google-chrome \"$plain_dot\""
case_decision 2 absolute-nonascii-data "\"$browser\" --headless \"$uri?name=café\""
case_decision 2 absolute-rich-data "\"$browser\" --headless \"$uri?name=a.b\""
case_decision 2 absolute-slash-data "\"$browser\" --headless \"$uri?name=a/b\""
case_decision 2 absolute-second-uri "\"$browser\" --headless \"$uri?segment=all\" \"$uri#section\""
case_decision 2 absolute-output-foreign "\"$browser\" --headless --print-to-pdf=companies/otherco/settings/out.pdf \"$uri?segment=all\""
case_decision 2 absolute-foreign-uri "\"$browser\" --headless \"$foreign?segment=all\""
case_decision 0 bound-plain-uri "google-chrome --headless \"$uri\""
case_decision 2 bare-bound-space-path "google-chrome --headless \"file://$FIXTURE/companies/indigo/settings/space dir/README.md?segment=all\""
# Foreign-company URL data was a self-added positive, not feedback55ab.
# Withdraw it: a browser basename cannot prove the data stays inert.
case_decision 2 foreign-query-data-refused "google-chrome --headless \"$uri?next=companies/otherco/settings/README.md\""
case_decision 2 bound-company-query-data-refused "google-chrome \"$uri?next=companies/indigo/settings/README.md\""
case_decision 2 bound-company-fragment-data-refused "google-chrome \"$uri#companies/indigo/settings/README.md\""
case_decision 2 uppercase-company-query-data "google-chrome \"$uri?next=COMPANIES/otherco/settings/README.md\""
case_decision 2 mixedcase-company-fragment-data "google-chrome \"$uri#CoMpAnIeS/otherco/settings/README.md\""
case_decision 2 percent-company-component-data "google-chrome \"$uri?next=companies%2Fotherco%2Fsettings%2FREADME.md\""
case_decision 2 percent-foreign-slug-data "google-chrome \"$uri?next=companies/%6ftherco/settings/README.md\""
case_decision 2 variable-query-data "google-chrome \"$uri?next=\$UNKNOWN\""
case_decision 2 browser-function-query "google-chrome(){ cat \"\${1#*=}\"; }; google-chrome \"$uri?next=companies/otherco/settings/README.md\""
case_decision 2 browser-function-fragment "function chromium { cat \"\${1#*=}\"; }; chromium \"$uri#companies/otherco/settings/README.md\""
case_decision 2 browser-alias-query "alias google-chrome=cat; google-chrome \"$uri?next=companies/otherco/settings/README.md\""
case_decision 2 browser-alias-fragment "alias chromium='cat'; chromium \"$uri#companies/otherco/settings/README.md\""
case_decision 2 quoted-browser-alias "alias 'google-chrome'=cat; google-chrome \"$uri?next=companies/otherco/settings/README.md\""
case_decision 2 alias-double-dash "alias -- google-chrome=cat; google-chrome \"$uri?next=companies/otherco/settings/README.md\""
case_decision 2 builtin-alias "builtin alias google-chrome=cat; google-chrome \"$uri#companies/otherco/settings/README.md\""
case_decision 2 escaped-alias "\\alias google-chrome=cat; google-chrome \"$uri?next=companies/otherco/settings/README.md\""
case_decision 2 quoted-function-name "'google-chrome'(){ cat \"\${1#*=}\"; }; google-chrome \"$uri#companies/otherco/settings/README.md\""
case_decision 2 missing-command-handler-query "command_not_found_handle(){ cat \"\${2#*next=}\"; }; google-chrome \"$uri?next=companies/otherco/settings/README.md\""
case_decision 2 keyword-missing-command-handler "function command_not_found_handle { cat \"\${2#*next=}\"; }; google-chrome \"$uri?next=companies/otherco/settings/README.md\""
case_decision 2 quoted-missing-command-handler "'command_not_found_handle'(){ cat \"\${2#*next=}\"; }; google-chrome \"$uri?next=companies/otherco/settings/README.md\""
case_decision 2 hash-path-query "hash -p /bin/cat google-chrome; google-chrome \"$uri?next=companies/otherco/settings/README.md\""
case_decision 2 builtin-hash-path-query "builtin hash -p /bin/cat google-chrome; google-chrome \"$uri?next=companies/otherco/settings/README.md\""
case_decision 2 escaped-hash-path-query "\\hash -p /bin/cat google-chrome; google-chrome \"$uri?next=companies/otherco/settings/README.md\""
case_decision 2 clustered-hash-options-query "hash -rp /bin/cat google-chrome; google-chrome \"$uri?next=companies/otherco/settings/README.md\""
case_decision 2 hash-without-mapping "hash -r; google-chrome \"$uri?segment=all\""
# Reconstruct the review's reported dispatch shapes, without executing them.
# The review did not supply its local21-case file: these are20 named controls
# derived from its explicit allowed/denied spellings, not byte-identical probes.
# Its reconstructed child-shell case allows on base/head/proposal under both
# shells; retained separately in the known-gap evidence, not blessed here.
review_uri="$uri?next=companies/otherco/settings/README.md"
review_command='eval '"'"'command_not_found_handle(){ cat "${2#*next=}"; }'"'"'; google-chrome "@URI@"'
case_decision 2 review-eval-handler "${review_command//@URI@/$review_uri}"
review_command='eval '"'"'google-chrome(){ cat "${1#*next=}"; }'"'"'; google-chrome "@URI@"'
case_decision 2 review-eval-browser "${review_command//@URI@/$review_uri}"
review_command='eval '"'"'hash -p /tmp/x/h google-chrome'"'"'; google-chrome "@URI@"'
case_decision 2 review-eval-hash "${review_command//@URI@/$review_uri}"
review_command='source /tmp/x/defs.sh; google-chrome "@URI@"'
case_decision 2 review-source-definitions "${review_command//@URI@/$review_uri}"
review_command='. /tmp/x/defs.sh; google-chrome "@URI@"'
case_decision 2 review-dot-definitions "${review_command//@URI@/$review_uri}"
review_command='enable -f /tmp/x/b.so google-chrome; google-chrome "@URI@"'
case_decision 2 review-loadable-builtin "${review_command//@URI@/$review_uri}"
review_command='alias zz='"'"'hash -p /tmp/x/h google-chrome'"'"'; zz; google-chrome "@URI@"'
case_decision 2 review-indirect-alias "${review_command//@URI@/$review_uri}"
review_command='/tmp/x/google-chrome "@URI@"'
case_decision 2 review-arbitrary-browser-path "${review_command//@URI@/$review_uri}"
review_command='"/tmp/x/google-chrome" --headless "@URI@"'
case_decision 2 review-quoted-arbitrary-browser-path "${review_command//@URI@/$review_uri}"
review_command='PATH=/tmp/x:/usr/bin; google-chrome "@URI@"'
case_decision 2 review-path-assignment "${review_command//@URI@/$review_uri}"
review_command='export PATH=/tmp/x:/usr/bin && google-chrome "@URI@"'
case_decision 2 review-export-path "${review_command//@URI@/$review_uri}"
review_command='declare PATH=/tmp/x; google-chrome "@URI@"'
case_decision 2 review-declare-path "${review_command//@URI@/$review_uri}"
review_command='function google-chrome { cat "${1#*next=}"; }; google-chrome "@URI@"'
case_decision 2 review-keyword-function "${review_command//@URI@/$review_uri}"
review_command='google-chrome(){ cat "${1#*next=}"; }; google-chrome "@URI@"'
case_decision 2 review-paren-function "${review_command//@URI@/$review_uri}"
review_command='google-chrome () { cat "${1#*next=}"; }; google-chrome "@URI@"'
case_decision 2 review-spaced-paren-function "${review_command//@URI@/$review_uri}"
review_command='hash -p /tmp/x/h google-chrome; google-chrome "@URI@"'
case_decision 2 review-plain-hash "${review_command//@URI@/$review_uri}"
review_command='builtin hash -p /tmp/x/h google-chrome; google-chrome "@URI@"'
case_decision 2 review-builtin-hash "${review_command//@URI@/$review_uri}"
review_command='\hash -p /tmp/x/h google-chrome; google-chrome "@URI@"'
case_decision 2 review-escaped-hash "${review_command//@URI@/$review_uri}"
review_command='"hash" -p /tmp/x/h google-chrome; google-chrome "@URI@"'
case_decision 2 review-quoted-hash "${review_command//@URI@/$review_uri}"
review_command='command hash -p /tmp/x/h google-chrome; google-chrome "@URI@"'
case_decision 2 review-command-hash "${review_command//@URI@/$review_uri}"
case_decision 2 separate-browser-exports "google-chrome --headless \"$uri?segment=all\"; chromium --headless \"$uri#section\""
case_decision 2 lexical-dotdot-query "\"$browser\" \"file://$FIXTURE/companies/indigo/settings/deep/../../../otherco/settings/README.md?n=all\""
case_decision 2 lexical-dotdot-fragment "\"$browser\" \"file://$FIXTURE/companies/indigo/settings/deep/../../../otherco/settings/README.md#section\""
case_decision 2 lexical-dot-query "\"$browser\" \"file://$FIXTURE/companies/indigo/settings/./README.md?n=all\""
# Seven previously reconstructed review cases: payload strings only.
probe_command='eval '"'"'command_not_found_handle(){ cat "c${2#*n=}"; }'"'"'; google-chrome "@URI@?n=ompanies/otherco/settings/README.md"'
case_decision 2 eval-prefix "${probe_command//@URI@/$uri}"
probe_command='eval '"'"'command_not_found_handle(){ cat ${2#*n=}; }'"'"'; google-chrome "@URI@?n=compan?es/otherco/settings/README.md"'
case_decision 2 eval-handler-glob "${probe_command//@URI@/$uri}"
probe_command='eval '"'"'google-chrome(){ cat ${1#*n=}; }'"'"'; google-chrome "@URI@?n=c*s/otherco/settings/README.md"'
case_decision 2 eval-browser-glob "${probe_command//@URI@/$uri}"
probe_command='source /tmp/x/defs.sh; google-chrome "@URI@?n=compan?es/otherco/settings/README.md"'
case_decision 2 source-glob "${probe_command//@URI@/$uri}"
probe_command='/tmp/x/google-chrome "@URI@?n=ompanies/otherco/settings/README.md"'
case_decision 2 fake-path-prefix "${probe_command//@URI@/$uri}"
probe_command='/tmp/x/google-chrome "@URI@?n=compan?es/otherco/settings/README.md"'
case_decision 2 fake-path-glob "${probe_command//@URI@/$uri}"
probe_command='PATH=/tmp/x:/usr/bin; google-chrome "@URI@?n=ompanies/otherco/settings/README.md"'
case_decision 2 path-prefix "${probe_command//@URI@/$uri}"
case_decision 0 bound-python-readme-edit "python3 - <<'PYCODE'
from pathlib import Path
p = Path('companies/indigo/settings/README.md')
p.write_text(p.read_text().replace('original', 'updated'))
PYCODE"
case_decision 2 foreign-query "\"$browser\" --headless \"$foreign?segment=all\""
case_decision 2 foreign-plain-uri "\"$browser\" --headless \"$foreign\""
case_decision 2 foreign-python-readme-edit "python3 - <<'PYCODE'
from pathlib import Path
p = Path('companies/otherco/settings/README.md')
p.write_text('not allowed')
PYCODE"
case_decision 2 host-uri "\"$browser\" --headless \"file://remote-host$FIXTURE/companies/indigo/settings/README.md?segment=all\""
case_decision 2 encoded-uri "\"$browser\" --headless \"file://$FIXTURE/companies/indigo/%2e%2e/otherco/settings/README.md?segment=all\""
case_decision 2 unc-uri "\"$browser\" --headless \"file:////$FIXTURE/companies/indigo/settings/README.md?segment=all\""
case_decision 2 traversing-uri "\"$browser\" --headless \"file://$FIXTURE/companies/indigo/../otherco/settings/README.md?segment=all\""
case_decision 2 symlinked-uri "\"$browser\" --headless \"file://$FIXTURE/companies/indigo/settings/foreign-link/README.md?segment=all\""
case_decision 2 unsupported-browser-option "\"$browser\" --unverified-file-option \"$uri?segment=all\""
case_decision 2 unquoted-uri "\"$browser\" --headless $uri?segment=all"
case_decision 2 unknown-variable-uri '/usr/bin/google-chrome --headless "file://$UNKNOWN/companies/indigo/settings/README.md?segment=all"'
case_decision 2 foreign-pdf-output "\"$browser\" --headless --print-to-pdf=companies/otherco/settings/export.pdf \"$uri?segment=all\""
case_decision 2 uri-looking-pdf-output "\"$browser\" --headless --print-to-pdf=\"$foreign?segment=all\" \"$uri\""
case_decision 2 separate-pdf-output "\"$browser\" --headless --print-to-pdf \"$uri?segment=all\""
case_decision 2 filesystem-uri-text "cat \"$uri?segment=all\""
case_decision 2 redirect-does-not-change-program "cat < google-chrome --headless \"$uri?segment=all\""
case_decision 2 foreign-filesystem-glob 'cat companies/otherco/settings/*.md'
case_decision 2 unknown-file-variable 'cat "$UNKNOWN/private.md"'
case_decision 2 ssh-foreign-control 'ssh localhost "cat companies/otherco/settings/README.md"'
case_decision 0 bound-literal-read 'cat companies/indigo/settings/README.md'
# The README-edit payload is only inspected; it must not have run.
if [ "$(cat "$FIXTURE/companies/indigo/settings/README.md")" = 'original fixture' ]; then
  PASS=$((PASS + 1)); echo 'PASS payloads-never-executed'
else
  FAIL=$((FAIL + 1)); echo 'FAIL payloads-never-executed'
fi
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
