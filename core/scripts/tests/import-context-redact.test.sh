#!/usr/bin/env bash
# Regression coverage for the /import-context redactor and synthetic scan output.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BASH_BIN="${BASH_BIN:-bash}"
BASH_BIN_PATH="$(command -v "$BASH_BIN")" || { echo "BASH_BIN is not executable: $BASH_BIN" >&2; exit 2; }
REDACTOR="$SRC_ROOT/.claude/skills/import-context/redact.sh"
SCAN="$SRC_ROOT/.claude/skills/import-context/scan.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/bash-bin"
ln -s "$BASH_BIN_PATH" "$TMP_ROOT/bash-bin/bash"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok - %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'not ok - %s\n' "$*" >&2; }

command -v jq >/dev/null 2>&1 || { echo 'jq is required' >&2; exit 2; }
[[ -f "$REDACTOR" && -f "$SCAN" ]] || { echo 'import-context scripts are missing' >&2; exit 2; }
if grep -Fq '${char,,}' "$REDACTOR" || grep -Fq '${char^^}' "$REDACTOR"; then
  bad 'redactor avoids Bash 4-only case-conversion expansions'
else
  ok 'redactor avoids Bash 4-only case-conversion expansions'
fi

assert_both_redacted() { # label text-input json-input leaked-marker [retained-text]
  local label="$1" text_input="$2" json_input="$3" leak="$4" retain="${5:-}"
  local text_file="$TMP_ROOT/text.input" json_file="$TMP_ROOT/json.input"
  local text_out="$TMP_ROOT/text.output" json_out="$TMP_ROOT/json.output" err="$TMP_ROOT/redact.err" rc

  printf '%s' "$text_input" > "$text_file"
  if "$BASH_BIN" "$REDACTOR" "$text_file" > "$text_out" 2>"$err"; then rc=0; else rc=$?; fi
  if [[ $rc -ne 0 ]]; then
    bad "$label: text mode exited $rc ($(sed -n '1p' "$err"))"
  elif grep -Fq -- "$leak" "$text_out"; then
    bad "$label: text mode retained sensitive value"
  elif ! grep -Fq '<REDACTED:' "$text_out"; then
    bad "$label: text mode emitted no redaction marker"
  elif [[ -n "$retain" ]] && ! grep -Fq -- "$retain" "$text_out"; then
    bad "$label: text mode removed non-sensitive context $retain"
  else
    ok "$label: text mode"
  fi

  printf '%s' "$json_input" > "$json_file"
  if "$BASH_BIN" "$REDACTOR" --json-fields "$json_file" > "$json_out" 2>"$err"; then rc=0; else rc=$?; fi
  if [[ $rc -ne 0 ]]; then
    bad "$label: --json-fields exited $rc ($(sed -n '1p' "$err"))"
  elif ! jq empty "$json_out" >/dev/null 2>&1; then
    bad "$label: --json-fields emitted invalid JSON"
  elif grep -Fq -- "$leak" "$json_out"; then
    bad "$label: --json-fields retained sensitive value"
  elif ! grep -Fq '<REDACTED:' "$json_out"; then
    bad "$label: --json-fields emitted no redaction marker"
  elif [[ -n "$retain" ]] && ! grep -Fq -- "$retain" "$json_out"; then
    bad "$label: --json-fields removed non-sensitive context $retain"
  else
    ok "$label: --json-fields"
  fi
}

# Database URLs keep their scheme/host while removing userinfo.
urls=$'postgres://reporter:synthetic-pass@db.invalid/app\nmongodb+srv://reporter:synthetic-pass@cluster.invalid/app\nredis://reporter:synthetic-pass@cache.invalid/0\n'
urls_json="$(jq -cn --arg value "$urls" '{connection_strings:$value}')"
assert_both_redacted 'credentialed database URLs' "$urls" "$urls_json" 'reporter:synthetic-pass@' 'db.invalid'

# A large tail makes early-exit grep pipelines return the producer's SIGPIPE
# under pipefail; the text-mode detector must still register the match.
{
  printf '%s\n' 'postgres://reporter:synthetic-pass@db.invalid/app'
  awk 'BEGIN { for (i = 0; i < 8192; i++) print "ordinary synthetic trailing text" }'
} > "$TMP_ROOT/large-url.input"
if "$BASH_BIN" "$REDACTOR" "$TMP_ROOT/large-url.input" > "$TMP_ROOT/large-url.output" 2>"$TMP_ROOT/large-url.err"; then rc=0; else rc=$?; fi
if [[ $rc -eq 0 ]] && ! grep -Fq 'reporter:synthetic-pass@' "$TMP_ROOT/large-url.output" \
  && grep -Fq '<REDACTED:connection_credentials>' "$TMP_ROOT/large-url.output"; then
  ok 'text detection survives a large tail after an early match'
else
  bad "text detection failed with large trailing input (exit $rc)"
fi

# Construct all PEM markers from fragments so no complete private-key header
# appears in this test source. The values below are synthetic, not key material.
PEM_BEGIN='-----BEGIN '
PEM_END='-----END '
PEM_SUFFIX=' KEY-----'
make_pem() {
  local label="$1"
  printf '%s%s%s\nSYNTHETIC-KEY-BODY-ONE\nSYNTHETIC-KEY-BODY-TWO\n%s%s%s' \
    "$PEM_BEGIN" "$label" "$PEM_SUFFIX" "$PEM_END" "$label" "$PEM_SUFFIX"
}
pem_bundle=''
pem_json='{}'
for label in 'RSA PRIVATE' 'PRIVATE' 'OPENSSH PRIVATE'; do
  pem_value="$(make_pem "$label")"
  pem_bundle+="$pem_value"$'\n'
  pem_json="$(jq -cn --argjson object "$pem_json" --arg value "$pem_value" --arg key "$label" \
    '$object + {($key):$value}')"
done
assert_both_redacted 'RSA, PKCS#8, and OpenSSH PEM blocks' "$pem_bundle" "$pem_json" 'SYNTHETIC-KEY-BODY' '<REDACTED:private_key>'

# Include the exact reported spellings and alternate casing. Some exact lower-
# camel spellings were already recognized on main; every variant must now pass.
key_names=(API_KEY ApiKey apiKey api_key SECRET Password token ApI_KeY aPiKeY SeCrEt pAssWoRd Token)
key_values=()
key_json='{}'
index=0
for key in "${key_names[@]}"; do
  value="US103-SYNTHETIC-JSON-$index"
  key_values+=("$value")
  key_json="$(jq -cn --argjson object "$key_json" --arg key "$key" --arg value "$value" \
    '$object + {($key):$value}')"
  index=$((index + 1))
done
check_key_matrix() { # text | json-fields
  local mode="$1" file="$TMP_ROOT/key-matrix.input" out="$TMP_ROOT/key-matrix.output" err="$TMP_ROOT/key-matrix.err" rc
  printf '%s' "$key_json" > "$file"
  if [[ "$mode" == text ]]; then
    if "$BASH_BIN" "$REDACTOR" "$file" > "$out" 2>"$err"; then rc=0; else rc=$?; fi
  else
    if "$BASH_BIN" "$REDACTOR" --json-fields "$file" > "$out" 2>"$err"; then rc=0; else rc=$?; fi
  fi
  if [[ $rc -ne 0 ]]; then bad "JSON key case matrix ($mode): exited $rc"; return; fi
  if ! jq empty "$out" >/dev/null 2>&1; then bad "JSON key case matrix ($mode): invalid JSON"; return; fi
  local i leaked=''
  for i in "${!key_names[@]}"; do
    if [[ "$(jq -r --arg key "${key_names[$i]}" '.[$key] // ""' "$out")" == "${key_values[$i]}" ]]; then
      leaked+=" ${key_names[$i]}"
    fi
  done
  if [[ -n "$leaked" ]]; then bad "JSON key case matrix ($mode): values remained under$leaked"; else ok "JSON key case matrix ($mode)"; fi
}
check_key_matrix text
check_key_matrix json-fields

# Export prefixes, indentation, and a tab after export are accepted. The bare
# assignment remains covered to prevent regression of the existing rule.
env_lines=$'export MY_API_KEY=US103-ENV-EXPORT\n  INDENTED_SECRET=US103-ENV-INDENTED\nexport\tTAB_API_TOKEN=US103-ENV-TAB\nPLAIN_TOKEN=US103-ENV-BARE\n'
env_json="$(jq -cn --arg value "$env_lines" '{body:$value}')"
assert_both_redacted 'credential environment assignments' "$env_lines" "$env_json" 'US103-ENV-' '<REDACTED:env'

# Ordinary text and an unauthenticated URL must remain byte-for-byte unchanged
# in text mode and semantically unchanged in JSON mode.
plain='ordinary project notes and postgres://db.invalid/app with no credentials'
printf '%s' "$plain" > "$TMP_ROOT/plain.input"
if "$BASH_BIN" "$REDACTOR" "$TMP_ROOT/plain.input" > "$TMP_ROOT/plain.output" 2>"$TMP_ROOT/plain.err" && cmp -s "$TMP_ROOT/plain.input" "$TMP_ROOT/plain.output"; then
  ok 'ordinary text and unauthenticated URL unchanged in text mode'
else
  bad 'ordinary text or unauthenticated URL changed in text mode'
fi
plain_json="$(jq -cn --arg value "$plain" '{text:$value}')"
printf '%s' "$plain_json" > "$TMP_ROOT/plain-json.input"
if "$BASH_BIN" "$REDACTOR" --json-fields "$TMP_ROOT/plain-json.input" > "$TMP_ROOT/plain-json.output" 2>"$TMP_ROOT/plain-json.err" \
  && jq -e --arg value "$plain" '.text == $value' "$TMP_ROOT/plain-json.output" >/dev/null; then
  ok 'ordinary text and unauthenticated URL unchanged in --json-fields mode'
else
  bad 'ordinary text or unauthenticated URL changed in --json-fields mode'
fi

# stdin may be implicit or selected with '-'; JSON mode also accepts '-'.
for input_mode in implicit explicit-dash; do
  stdin_out="$TMP_ROOT/stdin-$input_mode.output"
  if [[ "$input_mode" == implicit ]]; then
    if printf '%s\n' 'PLAIN_TOKEN=US103-STDIN-PIPE' | "$BASH_BIN" "$REDACTOR" > "$stdin_out" 2>"$TMP_ROOT/stdin.err"; then rc=0; else rc=$?; fi
  else
    if printf '%s\n' 'PLAIN_TOKEN=US103-STDIN-DASH' | "$BASH_BIN" "$REDACTOR" - > "$stdin_out" 2>"$TMP_ROOT/stdin.err"; then rc=0; else rc=$?; fi
  fi
  leak="US103-STDIN-$( [[ "$input_mode" == implicit ]] && printf PIPE || printf DASH )"
  if [[ $rc -eq 0 ]] && ! grep -Fq -- "$leak" "$stdin_out" && grep -Fq '<REDACTED:' "$stdin_out"; then
    ok "stdin redaction ($input_mode)"
  else
    bad "stdin redaction ($input_mode) exited $rc or retained the sample value"
  fi
done
stdin_json="$(jq -cn --arg value 'US103-STDIN-JSON' '{token:$value}')"
if printf '%s\n' "$stdin_json" | "$BASH_BIN" "$REDACTOR" --json-fields - > "$TMP_ROOT/stdin-json.output" 2>"$TMP_ROOT/stdin-json.err"; then rc=0; else rc=$?; fi
if [[ $rc -eq 0 ]] && ! grep -Fq 'US103-STDIN-JSON' "$TMP_ROOT/stdin-json.output"; then
  ok 'JSON stdin redaction with explicit dash'
else
  bad "JSON stdin redaction with explicit dash exited $rc or retained the sample value"
fi

if "$BASH_BIN" "$REDACTOR" "$TMP_ROOT/missing-input" > "$TMP_ROOT/missing.output" 2>"$TMP_ROOT/missing.err"; then rc=0; else rc=$?; fi
if [[ $rc -eq 2 ]]; then ok 'missing input path exits 2'; else bad "missing input path exited $rc, expected 2"; fi

# Deliberate contract: --list-fields is text-only and rejects --json-fields.
printf '%s' '{"apiKey":"US103-LIST-FIELDS"}' > "$TMP_ROOT/list-fields.input"
if "$BASH_BIN" "$REDACTOR" --list-fields --json-fields "$TMP_ROOT/list-fields.input" > "$TMP_ROOT/list-fields.output" 2>"$TMP_ROOT/list-fields.err"; then rc=0; else rc=$?; fi
if [[ $rc -eq 2 ]] && grep -qi 'cannot be combined' "$TMP_ROOT/list-fields.err"; then
  ok '--list-fields with --json-fields fails loudly'
else
  bad "--list-fields with --json-fields exited $rc without the expected diagnostic"
fi

# A temporary home is the only input to this scanner fixture. It checks the
# policy destination, empty legacy category compatibility, knowledge-repo
# signal, Grok parity, and redaction before previews enter report.json.
FIX_HOME="$TMP_ROOT/home"
mkdir -p "$FIX_HOME/.claude/policies" "$FIX_HOME/.grok/sessions" "$FIX_HOME/knowledge"
printf '%s\n' '# synthetic policy' 'export MY_API_KEY=US103-SCAN-PREVIEW-LEAK' > "$FIX_HOME/.claude/policies/example.md"
printf '%s\n' "$(jq -cn --arg value "$pem_value" '{payload:$value}')" > "$FIX_HOME/.claude/policies/pem-example.md"
if HOME="$FIX_HOME" PATH="$TMP_ROOT/bash-bin:$PATH" "$BASH_BIN" "$SCAN" --hq-root="$SRC_ROOT" --no-default-scopes --scope="$FIX_HOME" \
  > "$TMP_ROOT/scan.json" 2> "$TMP_ROOT/scan.err"; then rc=0; else rc=$?; fi
if [[ $rc -ne 0 ]] || ! jq empty "$TMP_ROOT/scan.json" >/dev/null 2>&1; then
  bad "synthetic scan exited $rc or emitted invalid JSON"
else
  ok 'synthetic-home scan emits JSON'
  if jq -e '.categories.policies | any(.suggested_destination == "personal/policies/example.md")' "$TMP_ROOT/scan.json" >/dev/null; then
    ok 'scan suggests personal/policies when company is not bound'
  else
    bad 'scan policy destination was not personal/policies/example.md'
  fi
  if jq -e '.categories.knowledge_dirs == []' "$TMP_ROOT/scan.json" >/dev/null; then
    ok 'scan keeps the empty knowledge_dirs compatibility field'
  else
    bad 'scan knowledge_dirs compatibility field changed from empty'
  fi
  if jq -e '.categories.claude_repos | any(.is_knowledge == true)' "$TMP_ROOT/scan.json" >/dev/null; then
    ok 'scan exposes the knowledge-repo signal on claude_repos'
  else
    bad 'scan omitted claude_repos[].is_knowledge for the fixture'
  fi
  if jq -e '.categories.conversations | any(.source == "grok" and .sessions == 0)' "$TMP_ROOT/scan.json" >/dev/null; then
    ok 'empty Grok store is reported consistently with other existing stores'
  else
    bad 'empty Grok store was omitted'
  fi
  preview="$(jq -r '.categories.policies[] | select(.source_path | endswith("example.md")) | .preview' "$TMP_ROOT/scan.json")"
  if [[ "$preview" != *'US103-SCAN-PREVIEW-LEAK'* ]] && [[ "$preview" == *'<REDACTED:'* ]]; then
    ok 'scan preview redacts before report.json output'
  else
    bad 'scan preview leaked the synthetic credential or lacked a redaction marker'
  fi
  pem_preview="$(jq -r '.categories.policies[] | select(.source_path | endswith("pem-example.md")) | .preview' "$TMP_ROOT/scan.json")"
  if [[ "$pem_preview" != *'SYNTHETIC-KEY-BODY'* ]] && [[ "$pem_preview" == *'<REDACTED:private_key>'* ]]; then
    ok 'scan text preview redacts a JSON-escaped PEM block'
  else
    bad 'scan text preview leaked a JSON-escaped PEM block'
  fi
fi

SKILL="$SRC_ROOT/.claude/skills/import-context/SKILL.md"
if ! grep -Fq 'claude_repos[].is_knowledge == true' "$SKILL" || grep -Fq 'knowledge_dirs' "$SKILL"; then
  bad 'skill uses claude_repos[].is_knowledge without a knowledge_dirs category'
else
  ok 'skill uses claude_repos[].is_knowledge as its knowledge source'
fi
if grep -Fq 'companies/{co}/policies/' "$SKILL" && grep -Fq 'otherwise `personal/policies/`' "$SKILL" \
  && grep -Fq 'Never write imported policies to `core/policies/`' "$SKILL"; then
  ok 'skill documents company or personal policy destinations and excludes core/policies'
else
  bad 'skill policy destination does not match the company/personal rule'
fi
if grep -Fq 'If it is missing, treat the repo as unclaimed.' "$SKILL"; then
  ok 'skill treats a missing active-runs file as unclaimed'
else
  bad 'skill does not define missing active-runs behavior'
fi
if grep -Fq 'Preflight step 3 resolves scope paths' "$SKILL" && ! grep -Fq 'Verified via `realpath` in scan.sh' "$SKILL"; then
  ok 'skill attributes the realpath self-exclusion to Preflight'
else
  bad 'skill self-exclusion wording still assigns the realpath abort to scan.sh'
fi

printf '\nResult: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then exit 1; fi
