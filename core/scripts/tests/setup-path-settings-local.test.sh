#!/usr/bin/env bash
# Regression for US-166: PATH is isolated from locked settings when enabled,
# and flag lookup works from a locally bound company without session env vars.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
SETUP="$ROOT/core/scripts/setup.sh"
HELPER="$ROOT/core/scripts/configure-settings-path.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/setup-path-settings-local.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

for tool in bash cmp jq node grep; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: required test tool missing: $tool" >&2; exit 1; }
done

if grep -Fq 'configure-settings-path.sh' "$SETUP"; then
  ok 'setup.sh delegates PATH setup to the tested helper'
else
  bad 'setup.sh delegates PATH setup to the tested helper'
fi
if grep -Fq 'PATH_TARGET" == *"PATH not configured"*' "$SETUP" \
  && grep -Fq 'skip "$PATH_TARGET"' "$SETUP"; then
  ok 'setup.sh reports malformed local settings as a skip'
else
  bad 'setup.sh reports malformed local settings as a skip'
fi

if [[ -f "$HELPER" ]]; then
  ok 'PATH helper exists'
else
  bad 'PATH helper exists'
  printf '1..%s\n' "$((pass + fail))"
  exit 1
fi

CLI="$TMP/npm-global/lib/node_modules/@indigoai-us/hq-cli"
mkdir -p "$CLI/bin" "$CLI/dist/lib" \
  "$CLI/node_modules/@indigoai-us/hq-flags-client" \
  "$CLI/node_modules/@indigoai-us/hq-cloud" "$TMP/bin"
cat > "$CLI/package.json" <<'JSON'
{"name":"@indigoai-us/hq-cli","bin":{"hq":"bin/hq"},"type":"module"}
JSON
cat > "$CLI/bin/hq" <<'SH'
#!/usr/bin/env sh
exit 0
SH
chmod +x "$CLI/bin/hq"
ln -s "$CLI/bin/hq" "$TMP/bin/hq"
cat > "$CLI/dist/lib/flag-registry-endpoint.js" <<'JS'
export const FLAG_REGISTRY_DEFAULT_ENDPOINT = "https://flags.invalid/default";
JS
cat > "$CLI/node_modules/@indigoai-us/hq-flags-client/package.json" <<'JSON'
{"type":"module","exports":{".":{"import":"./index.js"}}}
JSON
cat > "$CLI/node_modules/@indigoai-us/hq-flags-client/index.js" <<'JS'
export const createFlagClient = (options) => ({
  ready: async () => {
    const fs = await import("node:fs");
    fs.writeFileSync(process.env.HQ_TEST_FLAG_MARKER, JSON.stringify({
      endpoint: options.endpoint,
      companyUid: options.companyUid,
      companyIdentifiers: options.companyIdentifiers,
      enabled: process.env.HQ_TEST_SETUP_PATH_FLAG === "true",
    }));
  },
  snapshot: () => ({ flags: { "core.setup-path-settings-local": process.env.HQ_TEST_SETUP_PATH_FLAG === "true" } }),
  close: () => {},
});
JS
cat > "$CLI/node_modules/@indigoai-us/hq-cloud/package.json" <<'JSON'
{"type":"module","exports":{".":{"default":"./index.js"}}}
JSON
cat > "$CLI/node_modules/@indigoai-us/hq-cloud/index.js" <<'JS'
export const loadCachedTokens = () => ({ idToken: "test-only-token" });
JS

make_fixture() {
  local name="$1" dir="$TMP/$1"
  mkdir -p "$dir/.claude" "$dir/core/scripts/lib" "$dir/companies"
  cp "$ROOT/.claude/settings.json" "$dir/.claude/settings.json"
  cp "$ROOT/core/scripts/compose-settings-path.sh" "$dir/core/scripts/compose-settings-path.sh"
  cp "$ROOT/core/scripts/setup-path-flag.cjs" "$dir/core/scripts/setup-path-flag.cjs"
  cp "$ROOT/core/scripts/hq-session.sh" "$dir/core/scripts/hq-session.sh"
  cp "$ROOT/core/scripts/lib/session-id.sh" "$dir/core/scripts/lib/session-id.sh"
  cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$dir/core/scripts/lib/session-scope-capability.sh"
  printf '{"env":{"LOCAL_ONLY":"preserved"},"other":true}\n' > "$dir/.claude/settings.local.json"
  printf '%s' "$dir"
}

bind_indigo() {
  local dir="$1"
  mkdir -p "$dir/companies/indigo" "$dir/workspace/sessions/test-session"
  printf 'cmp_test123\n' > "$dir/companies/indigo/.company-uid"
  printf 'test-session\n' > "$dir/workspace/sessions/.current"
  printf 'company_slug: indigo\n' > "$dir/workspace/sessions/test-session/meta.yaml"
}

run_helper() {
  local root="$1" enabled="$2" output_var="$3" rc_var="$4" context="${5:-default}"
  local captured_output exit_code
  local -a env_args=(env -u HQ_ROOT -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID -u HQ_COMPANY_SLUG
    -u HQ_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID
    -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID)
  if [[ "$context" == explicit ]]; then
    env_args+=(HQ_FLAGS_API_URL=https://flags.invalid HQ_COMPANY_UID=cmp_test123)
  fi
  rm -f "$TMP/flag-marker.json"
  if captured_output="$("${env_args[@]}" \
    HOME="$TMP/home" HQ_ROOT="$root" HQ_HQ_SESSION_NO_CLI=1 \
    HQ_TOOLCHAIN_DIR="$TMP/no-toolchain" PATH="$TMP/bin:$PATH" HQ_CLI_BIN="$TMP/bin/hq" \
    HQ_TEST_FLAG_MARKER="$TMP/flag-marker.json" HQ_TEST_SETUP_PATH_FLAG="$enabled" \
    bash "$HELPER" "$root" "$PATH" 2>&1)"; then
    exit_code=0
  else
    exit_code=$?
  fi
  printf -v "$output_var" '%s' "$captured_output"
  printf -v "$rc_var" '%s' "$exit_code"
}

RUN_PATH="$PATH"
EXPECTED_PATH="$(env HOME="$TMP/home" HQ_TOOLCHAIN_DIR="$TMP/no-toolchain" \
  bash "$ROOT/core/scripts/compose-settings-path.sh" "$RUN_PATH")"

ON_ROOT="$(make_fixture enabled)"
bind_indigo "$ON_ROOT"
cp "$ON_ROOT/.claude/settings.json" "$TMP/settings.before"
run_helper "$ON_ROOT" true output rc
if [[ "$rc" == 0 && "$(jq -r '.env.PATH' "$ON_ROOT/.claude/settings.local.json")" == "$EXPECTED_PATH" \
  && "$(jq -r '.env.LOCAL_ONLY' "$ON_ROOT/.claude/settings.local.json")" == 'preserved' \
  && "$(jq -r '.other' "$ON_ROOT/.claude/settings.local.json")" == 'true' ]]; then
  ok 'default endpoint plus bound company enables local settings and preserves unrelated keys'
else
  bad 'default endpoint plus bound company enables local settings and preserves unrelated keys'
fi
if [[ -f "$TMP/flag-marker.json" ]] \
  && [[ "$(jq -r '.endpoint' "$TMP/flag-marker.json")" == 'https://flags.invalid/default' ]] \
  && [[ "$(jq -r '.companyUid' "$TMP/flag-marker.json")" == 'cmp_test123' ]]; then
  ok 'reader resolves installed CLI endpoint and bound company uid'
else
  bad 'reader resolves installed CLI endpoint and bound company uid'
fi
if cmp -s "$TMP/settings.before" "$ON_ROOT/.claude/settings.json"; then
  ok 'flag on leaves locked settings.json byte-identical'
else
  bad 'flag on leaves locked settings.json byte-identical'
fi

OFF_ROOT="$(make_fixture disabled)"
bind_indigo "$OFF_ROOT"
run_helper "$OFF_ROOT" false output rc
if [[ "$rc" == 0 && "$(jq -r '.env.PATH' "$OFF_ROOT/.claude/settings.json")" == "$EXPECTED_PATH" ]]; then
  ok 'registry false keeps the legacy settings.json PATH behavior'
else
  bad 'registry false keeps the legacy settings.json PATH behavior'
fi
if [[ -f "$TMP/flag-marker.json" ]] \
  && [[ "$(jq -r '.enabled' "$TMP/flag-marker.json")" == 'false' ]] \
  && [[ "$(jq -r '.companyUid' "$TMP/flag-marker.json")" == 'cmp_test123' ]]; then
  ok 'registry false was evaluated for the locally bound company'
else
  bad 'registry false was evaluated for the locally bound company'
fi

PERSONAL_ROOT="$(make_fixture personal)"
run_helper "$PERSONAL_ROOT" true output rc
if [[ "$rc" == 0 && "$(jq -r '.env.PATH' "$PERSONAL_ROOT/.claude/settings.local.json")" == "$EXPECTED_PATH" ]]; then
  ok 'companyless registry response can enable the local settings path'
else
  bad 'companyless registry response can enable the local settings path'
fi
if [[ -f "$TMP/flag-marker.json" ]] \
  && [[ "$(jq -r '.endpoint' "$TMP/flag-marker.json")" == 'https://flags.invalid/default' ]] \
  && [[ "$(jq -r '.companyUid // "missing"' "$TMP/flag-marker.json")" == 'missing' ]]; then
  ok 'companyless client uses default endpoint without a company uid'
else
  bad 'companyless client uses default endpoint without a company uid'
fi

INVALID_ROOT="$(make_fixture invalid-local-settings)"
printf '{ this is not valid JSON\n' > "$INVALID_ROOT/.claude/settings.local.json"
cp "$INVALID_ROOT/.claude/settings.local.json" "$TMP/invalid.before"
bind_indigo "$INVALID_ROOT"
run_helper "$INVALID_ROOT" true output rc explicit
if [[ "$rc" == 0 && "$output" == *'not configured'* ]]; then
  ok 'invalid settings.local.json prints a not-configured skip and exits successfully'
else
  bad 'invalid settings.local.json prints a not-configured skip and exits successfully'
fi
if cmp -s "$TMP/invalid.before" "$INVALID_ROOT/.claude/settings.local.json"; then
  ok 'invalid settings.local.json remains byte-identical'
else
  bad 'invalid settings.local.json remains byte-identical'
fi

printf '1..%s\n' "$((pass + fail))"
printf '# %s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
