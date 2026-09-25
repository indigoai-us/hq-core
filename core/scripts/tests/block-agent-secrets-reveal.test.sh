#!/usr/bin/env bash
# Regression for US-015: secret reveal is human-only when its default-off
# hq-flags gate is explicitly enabled for an agent PreToolUse command.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
HOOK="$ROOT/.claude/hooks/block-agent-secrets-reveal.sh"
REGISTRY="$ROOT/.claude/hooks/hook-registry.json"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
MASTER="$ROOT/.claude/hooks/master-hook.sh"
CODEX_ADAPTER="$ROOT/.codex/hooks/hq-codex-hook-adapter.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-secret-reveal.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

for tool in jq node; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: required test tool missing: $tool" >&2; exit 1; }
done
[ -f "$HOOK" ] || { echo "FAIL: missing hook $HOOK" >&2; exit 1; }

# The fake global CLI package gives the hook a deterministic hq-flags client
# and cached token without a network call or a real credential.
CLI="$TMP/npm-global/lib/node_modules/@indigoai-us/hq-cli"
mkdir -p "$CLI/bin" "$CLI/dist" \
  "$CLI/node_modules/@indigoai-us/hq-flags-client" \
  "$CLI/node_modules/@indigoai-us/hq-cloud" "$TMP/bin"
cat > "$CLI/package.json" <<'JSON'
{"name":"@indigoai-us/hq-cli","bin":{"hq":"bin/hq"}}
JSON
cat > "$CLI/bin/hq" <<'SH'
#!/usr/bin/env sh
exit 0
SH
chmod +x "$CLI/bin/hq"
ln -s "$CLI/bin/hq" "$TMP/bin/hq"
cat > "$CLI/node_modules/@indigoai-us/hq-flags-client/package.json" <<'JSON'
{"type":"module","exports":{".":{"types":"./index.d.ts","import":"./index.js"}}}
JSON
cat > "$CLI/node_modules/@indigoai-us/hq-flags-client/index.js" <<'JS'
import { appendFileSync } from "node:fs";

export const createFlagClient = (options) => {
  if (process.env.HQ_TEST_FLAG_CALL_MARKER) {
    appendFileSync(process.env.HQ_TEST_FLAG_CALL_MARKER, "called\n");
  }
  return {
    ready: async () => {
      if (process.env.HQ_TEST_FLAG_ERROR === "true") throw new Error("FLAG_VALUE_SENTINEL");
    },
    snapshot: () => ({
      version: 1,
      flags: process.env.HQ_TEST_FLAG_MISSING === "true"
        ? {}
        : { "secrets.agent-reveal-block": process.env.HQ_TEST_FLAG_ENABLED === "true" },
    }),
    isEnabled: (key, lookup) => {
      if (key !== "secrets.agent-reveal-block") throw new Error("unexpected flag key");
      if (lookup.fallback !== false) throw new Error("unexpected fallback");
      if (options.env == null || Object.keys(options.env).length !== 0) {
        throw new Error("the flag reader must not accept shell-local overrides");
      }
      return process.env.HQ_TEST_IS_ENABLED === "true"
        || process.env.HQ_TEST_FLAG_ENABLED === "true";
    },
    close: () => {},
  };
};
JS
cat > "$CLI/node_modules/@indigoai-us/hq-cloud/package.json" <<'JSON'
{"type":"module","exports":{".":{"default":"./index.js"}}}
JSON
cat > "$CLI/node_modules/@indigoai-us/hq-cloud/index.js" <<'JS'
export const loadCachedTokens = () => ({ idToken: "test-only-token" });
JS
payload() {
  jq -nc --arg cmd "$1" --arg root "$ROOT" \
    '{session_id:"agent-secret-reveal-test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$root,tool_input:{command:$cmd}}'
}

run_direct() {
  local command="$1" rc=0
  payload "$command" \
    | env PATH="$TMP/bin:$PATH" HQ_TEST_FLAG_ENABLED=true \
        HQ_FLAGS_API_URL=https://flags.invalid HQ_COMPANY_UID=cmp_test123 \
        HQ_COMPANY_SLUG=indigo CLAUDE_PROJECT_DIR="$ROOT" \
        bash "$HOOK" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
  printf '%s' "$rc"
}

expect_blocked() {
  local label="$1" command="$2" rc
  rc="$(run_direct "$command")"
  if [ "$rc" = 0 ] \
    && jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("reveal is for humans")) and (.hookSpecificOutput.permissionDecisionReason | contains("hq secrets exec")) and (.hookSpecificOutput.permissionDecisionReason | contains("hq run"))' "$TMP/stdout" >/dev/null; then
    ok "$label"
  else
    bad "$label (want structured deny; got exit $rc; stdout=$(cat "$TMP/stdout"); stderr=$(tr '\n' ' ' < "$TMP/stderr"))"
  fi
}

expect_allowed() {
  local label="$1" command="$2" rc
  rc="$(run_direct "$command")"
  if [ "$rc" = 0 ]; then
    ok "$label"
  else
    bad "$label (want exit 0 got $rc; stderr=$(tr '\n' ' ' < "$TMP/stderr"))"
  fi
}

expect_non_reveal_skips_flag_reader() {
  local label="$1" command="$2" marker="$TMP/flag-reader-$RANDOM.marker" rc=0
  payload "$command" \
    | env PATH="$TMP/bin:$PATH" HQ_TEST_FLAG_ENABLED=false HQ_TEST_FLAG_ERROR=true \
        HQ_TEST_FLAG_CALL_MARKER="$marker" \
        HQ_FLAGS_API_URL=https://flags.invalid HQ_COMPANY_UID=cmp_test123 \
        HQ_COMPANY_SLUG=indigo CLAUDE_PROJECT_DIR="$ROOT" \
        bash "$HOOK" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
  if [ "$rc" = 0 ] && [ ! -s "$TMP/stdout" ] && [ ! -s "$TMP/stderr" ] && [ ! -e "$marker" ]; then
    ok "$label skips flag lookup and emits no output"
  else
    bad "$label skips flag lookup and emits no output (got $rc; stdout=$(cat "$TMP/stdout"); stderr=$(tr '\n' ' ' < "$TMP/stderr"); marker=$(cat "$marker" 2>/dev/null))"
  fi
}

echo '[1] reveal is blocked through the listed Bash and CLI routes'
expect_blocked 'direct get --reveal' 'hq secrets get TEST_SECRET --reveal'
expect_blocked 'reveal option before secret name' 'hq secrets get --reveal TEST_SECRET'
expect_blocked 'personal scope before subcommand' 'hq secrets --personal get TEST_SECRET --reveal'
expect_blocked 'secrets reveal alias form is guarded' 'hq secrets reveal TEST_SECRET'
expect_blocked 'bash -c wrapper' "bash -c 'hq secrets get TEST_SECRET --reveal'"
expect_blocked 'sh -c wrapper' "sh -c 'hq secrets get TEST_SECRET --reveal'"
expect_blocked 'eval wrapper' "eval 'hq secrets get TEST_SECRET --reveal'"
expect_blocked 'subshell wrapper' '(hq secrets get TEST_SECRET --reveal)'
expect_blocked 'pipeline command' 'printf x | hq secrets get TEST_SECRET --reveal'
expect_blocked 'env wrapper' 'env hq secrets get TEST_SECRET --reveal'
expect_blocked 'leading assignment before hq CLI' 'MODE=agent hq secrets get TEST_SECRET --reveal'
expect_blocked 'assignment before env wrapper' 'MODE=agent env MODE2=yes hq secrets get TEST_SECRET --reveal'
expect_blocked 'hq run child command' 'hq run -- hq secrets get TEST_SECRET --reveal'
expect_blocked 'secrets exec child command' 'hq secrets exec --only X -- hq secrets get TEST_SECRET --reveal'
expect_blocked 'npx hq wrapper' 'npx --yes hq secrets get TEST_SECRET --reveal'
expect_blocked 'npx scoped CLI package wrapper' 'npx --yes @indigoai-us/hq-cli secrets get TEST_SECRET --reveal'
expect_blocked 'absolute hq binary path' '/opt/hq/bin/hq secrets get TEST_SECRET --reveal'
expect_blocked 'env plus absolute hq binary path' 'env MODE=agent /opt/hq/bin/hq secrets get TEST_SECRET --reveal'
expect_blocked 'nested shells' "bash -c 'sh -c \"hq secrets get TEST_SECRET --reveal\"'"
expect_blocked 'command substitution' 'printf "%s" "$(hq secrets get TEST_SECRET --reveal)"'
expect_blocked 'backtick substitution' 'printf "%s" `hq secrets get TEST_SECRET --reveal`'
expect_blocked 'timeout positional duration wrapper' 'timeout 5 hq secrets get TEST_SECRET --reveal'
expect_blocked 'timeout option operands wrapper' 'timeout --kill-after 1s --signal TERM 5s hq secrets get TEST_SECRET --reveal'
expect_blocked 'sudo user option operand wrapper' 'sudo -u root hq secrets get TEST_SECRET --reveal'
expect_blocked 'sudo long user option and separator' 'sudo --user=root -- hq secrets get TEST_SECRET --reveal'

# Registry membership makes the same code active under every Claude hook profile.
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.id == "block-agent-secrets-reveal" and .gated == true)' "$REGISTRY" >/dev/null; then
  ok 'Bash PreToolUse registry points to the gated reveal hook'
else
  bad 'Bash PreToolUse registry points to the gated reveal hook'
fi
for profile in minimal standard strict; do
  rc=0
  payload 'hq secrets get TEST_SECRET --reveal' \
    | env PATH="$TMP/bin:$PATH" HQ_TEST_FLAG_ENABLED=true \
        HQ_FLAGS_API_URL=https://flags.invalid HQ_COMPANY_UID=cmp_test123 \
        HQ_COMPANY_SLUG=indigo CLAUDE_PROJECT_DIR="$ROOT" HQ_HOOK_TIMEOUT_SENTRY=0 \
        HQ_HOOK_PROFILE="$profile" \
        bash "$GATE" block-agent-secrets-reveal "$HOOK" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
  if [ "$rc" = 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/stdout" >/dev/null; then ok "hook-gate profile=$profile blocks reveal"; else bad "hook-gate profile=$profile blocks reveal (got $rc; stdout=$(cat "$TMP/stdout"))"; fi
done

# Exercise the active master hook and the real Codex adapter, not only the
# script body. Other hooks are disabled for this isolated payload.
OTHER_IDS="$(jq -r '.hooks.PreToolUse[].hooks[].id | select(. != "block-agent-secrets-reveal")' "$REGISTRY" | sort -u | paste -sd, -)"
rc=0
payload 'hq secrets get TEST_SECRET --reveal' \
  | env PATH="$TMP/bin:$PATH" HQ_TEST_FLAG_ENABLED=true \
      HQ_FLAGS_API_URL=https://flags.invalid HQ_COMPANY_UID=cmp_test123 \
      HQ_COMPANY_SLUG=indigo CLAUDE_PROJECT_DIR="$ROOT" HQ_ROOT="$ROOT" \
      HQ_ALLOW_HQ_WORKTREE=1 HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_PROFILE=minimal \
      HQ_DISABLED_HOOKS="$OTHER_IDS" bash "$MASTER" PreToolUse \
      >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
if [ "$rc" = 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("reveal is for humans"))' "$TMP/stdout" >/dev/null; then
  ok 'Claude master-hook dispatch blocks reveal'
else
  bad "Claude master-hook dispatch blocks reveal (got $rc; stdout=$(cat "$TMP/stdout"); stderr=$(tr '\n' ' ' < "$TMP/stderr"))"
fi

codex_payload="$(jq -nc --arg cmd 'hq secrets get TEST_SECRET --reveal' --arg root "$ROOT" \
  '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$root,tool_input:{command:$cmd}}')"
printf '%s' "$codex_payload" \
  | env PATH="$TMP/bin:$PATH" HQ_TEST_FLAG_ENABLED=true \
      HQ_FLAGS_API_URL=https://flags.invalid HQ_COMPANY_UID=cmp_test123 \
      HQ_COMPANY_SLUG=indigo CLAUDE_PROJECT_DIR="$ROOT" HQ_ROOT="$ROOT" \
      HQ_ALLOW_HQ_WORKTREE=1 HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_PROFILE=minimal \
      HQ_DISABLED_HOOKS="$OTHER_IDS" bash "$CODEX_ADAPTER" \
      >"$TMP/codex.json" 2>"$TMP/stderr"
if jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("reveal is for humans"))' "$TMP/codex.json" >/dev/null; then
  ok 'Codex PreToolUse adapter returns a deny for reveal'
else
  bad "Codex PreToolUse adapter returns a deny (output=$(cat "$TMP/codex.json"); stderr=$(tr '\n' ' ' < "$TMP/stderr"))"
fi

# Safe commands and text that merely mentions reveal remain available.
expect_allowed 'secrets exec is allowed' 'hq secrets exec --only X -- cmd'
expect_allowed 'secrets list is allowed' 'hq secrets list'
expect_allowed 'hq run is allowed' 'hq run -- npm test'
expect_allowed 'a string containing reveal is allowed' "printf '%s\\n' 'reveal'"
expect_allowed 'a file name containing reveal is allowed' 'cat reveal-notes.txt'
expect_allowed 'a string containing the command text is allowed' "printf '%s\\n' 'hq secrets get TEST_SECRET --reveal'"
expect_non_reveal_skips_flag_reader 'ls' 'ls'
expect_non_reveal_skips_flag_reader 'hq secrets list' 'hq secrets list'

# The feature gate is default-off: missing configuration and an explicit false
# value leave the existing human reveal path unchanged.
rc=0
payload 'hq secrets get TEST_SECRET --reveal' \
  | env PATH="$TMP/bin:$PATH" HQ_TEST_FLAG_ENABLED=false \
      CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOK" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
if [ "$rc" = 0 ]; then ok 'missing config uses the default-off fallback'; else bad "missing config uses the default-off fallback (got $rc)"; fi
rc=0
payload 'hq secrets get TEST_SECRET --reveal' \
  | env PATH="$TMP/bin:$PATH" HQ_TEST_FLAG_ENABLED=false HQ_TEST_IS_ENABLED=true \
      HQ_FLAGS_API_URL=https://flags.invalid HQ_COMPANY_UID=cmp_test123 \
      HQ_COMPANY_SLUG=indigo CLAUDE_PROJECT_DIR="$ROOT" \
      bash "$HOOK" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
if [ "$rc" = 0 ] && ! jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/stdout" >/dev/null 2>&1 && [ ! -s "$TMP/stderr" ]; then
  ok 'only the loaded snapshot value controls reveal blocking'
else
  bad "only the loaded snapshot value controls reveal blocking (got $rc; stdout=$(cat "$TMP/stdout"); stderr=$(tr '\n' ' ' < "$TMP/stderr"))"
fi

expect_blocked 'explicit true from loaded snapshot denies reveal' 'hq secrets get TEST_SECRET --reveal'

run_lookup_failure_case() {
  local -a failure_env=("$@")
  local rc=0
  payload 'hq secrets get TEST_SECRET --reveal' \
    | env PATH="$TMP/bin:$PATH" HQ_TEST_FLAG_ENABLED=false \
        HQ_FLAGS_API_URL=https://flags.invalid HQ_COMPANY_UID=cmp_test123 \
        HQ_COMPANY_SLUG=indigo CLAUDE_PROJECT_DIR="$ROOT" \
        "${failure_env[@]}" bash "$HOOK" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
  printf '%s' "$rc"
}

expect_lookup_failure_allows() {
  local label="$1" error_class="$2" rc lines
  shift 2
  rc="$(run_lookup_failure_case "$@")"
  lines="$(wc -l < "$TMP/stderr" | tr -d '[:space:]')"
  if [ "$rc" = 0 ] \
    && ! jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/stdout" >/dev/null 2>&1 \
    && [ "$lines" = 1 ] \
    && grep -Eq "^HQ agent secret-reveal flag lookup failed \\(${error_class}\\); using the default-off behavior\\.$" "$TMP/stderr" \
    && ! grep -Eq 'FLAG_VALUE_SENTINEL|test-only-token' "$TMP/stderr"; then
    ok "$label uses default-off behavior and emits one sanitized notice"
  else
    bad "$label default-off behavior (got $rc; stdout=$(cat "$TMP/stdout"); stderr=$(tr '\n' ' ' < "$TMP/stderr"))"
  fi
}

expect_lookup_failure_allows 'flag registry outage' Error HQ_TEST_FLAG_ERROR=true

missing_rc="$(run_lookup_failure_case HQ_TEST_FLAG_MISSING=true)"
if [ "$missing_rc" = 0 ] && [ ! -s "$TMP/stdout" ] && [ ! -s "$TMP/stderr" ]; then
  ok 'flag registry missing key silently uses default-off behavior'
else
  bad "flag registry missing key silently uses default-off behavior (got $missing_rc; stdout=$(cat "$TMP/stdout"); stderr=$(tr '\n' ' ' < "$TMP/stderr"))"
fi

# Drive the helper's real AbortSignal.timeout deadline through its injected
# fetch seam. This avoids shell or process watchdogs masking the lookup result.
timeout_result="$(node - "$ROOT/.claude/hooks/block-agent-secrets-reveal-flag.cjs" 2>&1 <<'JS'
const assert = require("node:assert/strict");
const { secretRevealFlagEnabled } = require(process.argv[2]);

(async () => {
  let diagnostic = "";
  const originalStderrWrite = process.stderr.write;
  process.stderr.write = (chunk) => {
    diagnostic += Buffer.isBuffer(chunk) ? chunk.toString() : chunk;
    return true;
  };
  let enabled;
  try {
    enabled = await secretRevealFlagEnabled({
      env: {
        HQ_FLAGS_API_URL: "https://flags.invalid",
        HQ_COMPANY_UID: "cmp_test123",
      },
      createClient: (options) => ({
        ready: async () => options.fetch("https://flags.invalid/timeout"),
        snapshot: () => ({ flags: { "secrets.agent-reveal-block": true } }),
        isEnabled: () => true,
        close: () => {},
      }),
      loadCachedTokens: () => ({ idToken: "test-only-token" }),
      fetch: (_input, init) => new Promise((_resolve, reject) => {
        const { signal } = init;
        const keepAlive = setTimeout(() => reject(new Error("timeout fixture did not abort")), 1000);
        const rejectOnAbort = () => {
          clearTimeout(keepAlive);
          reject(signal.reason);
        };
        if (signal.aborted) rejectOnAbort();
        else signal.addEventListener("abort", rejectOnAbort, { once: true });
      }),
    });
  } finally {
    process.stderr.write = originalStderrWrite;
  }
  assert.equal(enabled, false, "deadline expiry must preserve default-off");
  assert.equal(
    diagnostic,
    "HQ agent secret-reveal flag lookup failed (TimeoutError); using the default-off behavior.\n",
    "timeout should emit one sanitized notice with its error class",
  );
  process.stdout.write("ok\n");
})().catch((error) => {
  process.stderr.write(`${error.name}: ${error.message}\n`);
  process.exitCode = 1;
});
JS
)"
if [ "$timeout_result" = "ok" ]; then
  ok 'flag registry timeout uses default-off and reports TimeoutError'
else
  bad "flag registry timeout uses default-off and reports TimeoutError ($timeout_result)"
fi

printf 'block-agent-secrets-reveal: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
