# Source this from a shell test to provide a synthetic, default-off-capable hq-flags client.
hq_anywhere_flag_fixture() {
  local dir="$1"
  mkdir -p "$dir/bin" "$dir/node_modules/@indigoai-us/hq-flags-client" "$dir/node_modules/@indigoai-us/hq-cloud"
  printf '%s\n' '{"name":"@indigoai-us/hq-cli","version":"0.0.0"}' > "$dir/package.json"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$dir/bin/hq"
  chmod +x "$dir/bin/hq"
  printf '%s\n' '{"type":"module","exports":"./index.js"}' > "$dir/node_modules/@indigoai-us/hq-flags-client/package.json"
  cat > "$dir/node_modules/@indigoai-us/hq-flags-client/index.js" <<'JS'
export function createFlagClient(options) {
  return {
    ready: async () => {
      if (process.env.HQ_TEST_FLAG === "unreadable") throw new Error("offline");
      if (process.env.HQ_TEST_FLAG === "stale-false-throw") throw new Error("offline");
      if (process.env.HQ_TEST_FLAG === "stale-false") options.onError?.(new Error("offline"));
      if (process.env.HQ_TEST_FLAG === "timeout") await new Promise((resolve) => setTimeout(resolve, 200));
    },
    snapshot: () => {
      const value = process.env.HQ_TEST_FLAG;
      if (value === "absent" || value === "unreadable" || value === "timeout") return { flags: {} };
      if (value === "archived") return { flags: { "hq-anywhere-runtime": { archived: true } } };
      return { flags: { "hq-anywhere-runtime": value !== "false" && value !== "stale-false" && value !== "stale-false-throw" } };
    },
    close() {},
  };
}
JS
  printf '%s\n' '{"type":"module","exports":"./index.js"}' > "$dir/node_modules/@indigoai-us/hq-cloud/package.json"
  printf '%s\n' 'export function loadCachedTokens() { return {}; }' > "$dir/node_modules/@indigoai-us/hq-cloud/index.js"
}
hq_anywhere_flag_env() {
  HQ_CLI_BIN="$1/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 HQ_TEST_FLAG="${2:-true}"
  export HQ_CLI_BIN HQ_FLAGS_API_URL HQ_COMPANY_UID HQ_TEST_FLAG
}
