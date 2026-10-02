# Source this from a shell test to provide a synthetic, default-off-capable hq-flags client.
hq_anywhere_flag_fixture() {
  local dir="$1"
  mkdir -p "$dir/bin" "$dir/node_modules/@indigoai-us/hq-flags-client" "$dir/node_modules/@indigoai-us/hq-cloud"
  printf '%s\n' '{"name":"@indigoai-us/hq-cli","version":"0.0.0"}' > "$dir/package.json"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$dir/bin/hq"
  chmod +x "$dir/bin/hq"
  printf '%s\n' '{"type":"module","exports":"./index.js"}' > "$dir/node_modules/@indigoai-us/hq-flags-client/package.json"
  cat > "$dir/node_modules/@indigoai-us/hq-flags-client/index.js" <<'JS'
export function createFlagClient() {
  return { ready: async () => {}, snapshot: () => ({ flags: { "hq-anywhere-runtime": process.env.HQ_TEST_FLAG === "true" } }), close() {} };
}
JS
  printf '%s\n' '{"type":"module","exports":"./index.js"}' > "$dir/node_modules/@indigoai-us/hq-cloud/package.json"
  printf '%s\n' 'export function loadCachedTokens() { return {}; }' > "$dir/node_modules/@indigoai-us/hq-cloud/index.js"
}
hq_anywhere_flag_env() {
  HQ_CLI_BIN="$1/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 HQ_TEST_FLAG="${2:-true}"
  export HQ_CLI_BIN HQ_FLAGS_API_URL HQ_COMPANY_UID HQ_TEST_FLAG
}
