#!/usr/bin/env bash
# hq-core: public
# Regression coverage for prompt, session, and device-default company routing.
# Kept compatible with macOS /bin/bash 3.2.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_eq() {
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

mkdir -p "$TMP/core/scripts/lib" "$TMP/companies" "$TMP/workspace/sessions" "$TMP/bin"
cp "$ROOT/core/scripts/resolve-company.sh" "$TMP/core/scripts/"
cp "$ROOT/core/scripts/hq-session.sh" "$TMP/core/scripts/"
cp -R "$ROOT/core/scripts/lib/." "$TMP/core/scripts/lib/"
chmod +x "$TMP/core/scripts/resolve-company.sh" "$TMP/core/scripts/hq-session.sh"

cat > "$TMP/companies/manifest.yaml" <<'YAML'
companies:
  _template:
    name: Template
  acme:
    name: Acme Corp
  globex:
    name: Globex
  holler:
    name: Holler
  cmp_FIXTURE:
    name: Synthetic cloud company ID
  zeta:
    name: Zeta
  zeta-labs:
    name: Zeta Labs
YAML

cat > "$TMP/bin/hq-held.cjs" <<'NODE'
const fs = require("node:fs");
const { spawn } = require("node:child_process");
const args = process.argv.slice(2);
if (args[0] === "mesh" && args[2] === "reconcile") {
  const observation = JSON.parse(args[4]);
  const output = process.env.HQ_DEFAULT_PREFLIGHT_JSON
    .replace("__SID__", observation.identity.sessionId)
    .replace("__OP__", observation.clientOperationId);
  process.stdout.write(`${output}\n`, () => process.exit(0));
} else {
  const output = args[0] === "resolve-company"
  ? '{"company":"acme"}\n'
  : args[0] === "mesh" && args[2] === "default"
    ? `${process.env.HQ_DEFAULT_COMPANY_JSON}\n`
    : "";
if (!output) process.exit(7);
const holder = spawn(process.execPath, [
  "-e",
  'const fs=require("node:fs"); const timer=setInterval(()=>{if(fs.existsSync(process.env.HQ_GRANDCHILD_RELEASE)){clearInterval(timer);process.exit(0)}},25);',
], { detached: true, stdio: ["ignore", process.stdout, "ignore"] });
holder.once("spawn", () => {
  fs.writeFileSync(process.env.HQ_GRANDCHILD_READY, "");
  fs.writeFileSync(process.env.HQ_GRANDCHILD_PID, String(holder.pid));
  process.stdout.write(output, () => {
    fs.writeFileSync(process.env.HQ_HQ_EXIT_AT, String(process.hrtime.bigint()));
    process.exit(0);
  });
});
holder.once("error", () => process.exit(97));
}
NODE

cat > "$TMP/bin/hq" <<'HQ'
#!/usr/bin/env bash
if [ "${HQ_HOLD_STDOUT_OPEN:-}" = "1" ]; then
  exec node "$HQ_HQ_HELD_STUB" "$@"
fi
hold_stdout_open() {
  (
    : > "$HQ_GRANDCHILD_READY"
    while [ ! -e "$HQ_GRANDCHILD_RELEASE" ]; do sleep 0.05; done
  ) &
  printf '%s\n' "$!" > "$HQ_GRANDCHILD_PID"
}
if [ "$1" = "resolve-company" ] && [ "$2" = "--path" ]; then
  printf '%s\n' "${HQ_NO_UPDATE_CHECK:-unset}" > "$HQ_RESOLVE_NO_UPDATE_LOG"
  printf '%s\n' "$3" > "$HQ_RESOLVE_PATH_LOG"
  if [ -n "${HQ_REGISTRY_OUTPUT:-}" ]; then
    printf '%s\n' "$HQ_REGISTRY_OUTPUT"
    exit "${HQ_REGISTRY_EXIT:-0}"
  fi
  exit 7
elif [ "$1" = "mesh" ] && [ "$2" = "context" ] && [ "$3" = "default" ] && [ "$4" = "get" ] && [ "$5" = "--json" ]; then
  if [ "${HQ_SLOW_DEFAULT:-}" = "1" ]; then
    sleep 8
  fi
  if [ "${HQ_LARGE_DEFAULT:-}" = "1" ]; then
    printf '%s' '{"defaultCompany":{"slug":"acme","enabled":true,"needsChoice":false,"source":"configured"},"padding":"'
    awk 'BEGIN { for (i = 0; i < 262144; i++) printf "x" }'
    printf '%s\n' '"}'
  else
    printf '%s\n' "${HQ_DEFAULT_COMPANY_JSON:-}"
  fi
elif [ "$1" = "mesh" ] && [ "$2" = "context" ] && [ "$3" = "reconcile" ] && [ "$4" = "--observation-json" ] && [ "$6" = "--machine" ] && [ "$7" = "--offline" ]; then
  if [ "${HQ_SLOW_VALIDATOR:-}" = "1" ]; then
    sleep 8
  fi
  [ "${HQ_FAIL_VALIDATOR:-}" = "1" ] && exit 1
  session_id="$(printf '%s' "$5" | sed -nE 's/.*"sessionId":"([^"]+)".*/\1/p')"
  operation_id="$(printf '%s' "$5" | sed -nE 's/.*"clientOperationId":"([^"]+)".*/\1/p')"
  output="${HQ_DEFAULT_PREFLIGHT_JSON:-}"
  output="${output//__SID__/$session_id}"
  output="${output//__OP__/$operation_id}"
  printf '%s\n' "$output"
fi
HQ
chmod +x "$TMP/bin/hq"

mkdir -p "$TMP/repo"
HQ_RESOLVE_NO_UPDATE_LOG="$TMP/resolve-no-update-check.txt"
HQ_RESOLVE_PATH_LOG="$TMP/resolve-path.txt"
export HQ_RESOLVE_NO_UPDATE_LOG HQ_RESOLVE_PATH_LOG
folder_out="$(PATH="$TMP/bin:$PATH" HQ_NO_UPDATE_CHECK=0 bash "$TMP/core/scripts/resolve-company.sh" --root "$TMP" --path "$TMP/repo" 2>"$TMP/resolve-company-path.stderr")"
assert_eq "$folder_out" '{"company":"","source":"unavailable"}' "failed folder registry emits unavailable"
assert_eq "$(cat "$HQ_RESOLVE_NO_UPDATE_LOG")" "1" "timed folder registry disables hq self-update"
grep -Fq "'hq resolve-company' exited 7" "$TMP/resolve-company-path.stderr" || fail "failed folder registry warning missing"
pass "timed folder registry disables hq self-update"

HQ_REGISTRY_OUTPUT='{"company":null}' HQ_REGISTRY_EXIT=1
export HQ_REGISTRY_OUTPUT HQ_REGISTRY_EXIT
miss_out="$(PATH="$TMP/bin:$PATH" bash "$TMP/core/scripts/resolve-company.sh" --root "$TMP" --path "$TMP/repo" 2>"$TMP/registry-miss.stderr")"
assert_eq "$miss_out" '{"company":"","source":"registry_miss"}' "exit-1 registry miss is parsed before failure status"
assert_eq "$(cat "$TMP/registry-miss.stderr")" "" "exit-1 registry miss has no unavailable warning"
pass "exit-1 registry miss JSON is accepted"

mkdir -p "$TMP/companies/acme/projects/demo"
HQ_REGISTRY_OUTPUT='{"company":"acme"}' HQ_REGISTRY_EXIT=0
export HQ_REGISTRY_OUTPUT HQ_REGISTRY_EXIT
(cd "$TMP/companies/acme/projects/demo" && PATH="$TMP/bin:$PATH" HQ_CALLER_CWD="$PWD" bash "$TMP/core/scripts/resolve-company.sh" --root "$TMP" --path . >/dev/null)
assert_eq "$(cat "$HQ_RESOLVE_PATH_LOG")" "$TMP/companies/acme/projects/demo" "relative folder uses caller cwd"
pass "relative folder path stays anchored to caller cwd"
unset HQ_REGISTRY_OUTPUT HQ_REGISTRY_EXIT

CRLF_JQ_BIN="$TMP/crlf-jq-bin"
mkdir -p "$CRLF_JQ_BIN"
REAL_JQ="$(command -v jq)"
cat > "$CRLF_JQ_BIN/jq" <<EOF
#!/usr/bin/env bash
"$REAL_JQ" "\$@" | awk '{ printf "%s\\r\\n", \$0 }'
EOF
chmod +x "$CRLF_JQ_BIN/jq"
HQ_REGISTRY_OUTPUT='{"company":"acme"}' HQ_REGISTRY_EXIT=0
export HQ_REGISTRY_OUTPUT HQ_REGISTRY_EXIT
crlf_jq_out="$(PATH="$CRLF_JQ_BIN:$TMP/bin:$PATH" bash "$TMP/core/scripts/resolve-company.sh" --root "$TMP" --path "$TMP/repo" 2>"$TMP/crlf-jq.stderr")"
assert_eq "$crlf_jq_out" '{"company":"acme","source":"registry"}' "CRLF jq output retains registry hit"
assert_eq "$(cat "$TMP/crlf-jq.stderr")" "" "CRLF jq output has no warning"
pass "registry parsing strips CR from jq output"
unset HQ_REGISTRY_OUTPUT HQ_REGISTRY_EXIT

unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID
export HQ_HQ_SESSION_NO_CLI=1

resolve() {
  PATH="$TMP/bin:$PATH" bash "$TMP/core/scripts/resolve-company.sh" --root "$TMP" --prompt "$1" </dev/null
}
company_of() { printf '%s' "$1" | sed -E 's/.*"company":"([^"]*)".*/\1/'; }
source_of() { printf '%s' "$1" | sed -E 's/.*"source":"([^"]*)".*/\1/'; }

unset HQ_DEFAULT_COMPANY_JSON HQ_AGENT_WORKDIR HQ_AGENT_COMPANY_DIR HQ_AGENT_IDENTITY_FILE HQ_AGENT_ROOT_PREFIX || true

out="$(resolve 'fix the globex morning flash renderer bug')"
assert_eq "$(company_of "$out")" "globex" "whole-token prompt slug"
assert_eq "$(source_of "$out")" "prompt" "prompt source"
pass "explicit prompt company resolves"

out="$(resolve 'rewrite the globexes page')"
assert_eq "$(company_of "$out")" "" "substring does not resolve"
assert_eq "$(source_of "$out")" "none" "substring source"
pass "prompt matching stays whole-token only"

out="$(resolve 'compare zeta and zeta-labs numbers')"
assert_eq "$(company_of "$out")" "zeta-labs" "longest prompt slug wins"
pass "longest explicit prompt slug wins"

printf 'sess-1\n' > "$TMP/workspace/sessions/.current"
mkdir -p "$TMP/workspace/sessions/sess-1"
printf 'company_slug: holler\n' > "$TMP/workspace/sessions/sess-1/meta.yaml"
HQ_DEFAULT_COMPANY_JSON='{"ok":true,"slug":"acme","enabled":true,"needsChoice":false,"source":"configured"}'
export HQ_DEFAULT_COMPANY_JSON

out="$(resolve 'no explicit company in this request')"
assert_eq "$(company_of "$out")" "holler" "bound session beats device default"
assert_eq "$(source_of "$out")" "session" "session source"
pass "bound session company beats device default"

printf 'company_slug: cmp_FIXTURE\n' > "$TMP/workspace/sessions/sess-1/meta.yaml"
out="$(resolve 'no explicit company in this request')"
assert_eq "$(company_of "$out")" "cmp_FIXTURE" "case-sensitive session company resolves"
assert_eq "$(source_of "$out")" "session" "case-sensitive session source"
pass "manifest and session resolution preserve opaque company ID casing"

out="$(resolve 'please check the cmp_FIXTURE workspace')"
assert_eq "$(company_of "$out")" "cmp_FIXTURE" "case-sensitive prompt company resolves"
assert_eq "$(source_of "$out")" "prompt" "case-sensitive prompt source"
pass "prompt resolution preserves opaque company ID casing"

cat >> "$TMP/companies/manifest.yaml" <<'YAML'
  cmp_fixture:
    name: Case-colliding synthetic cloud company ID
YAML
printf '' > "$TMP/workspace/sessions/sess-1/meta.yaml"
unset HQ_DEFAULT_COMPANY_JSON HQ_DEFAULT_PREFLIGHT_JSON || true
out="$(resolve 'please check the cmp_FIXTURE workspace')"
assert_eq "$(company_of "$out")" "" "ambiguous case-folded prompt does not pick a company"
assert_eq "$(source_of "$out")" "none" "ambiguous case-folded prompt source"
pass "case-folded prompt matching refuses case-distinct company IDs"

HQ_DEFAULT_COMPANY_JSON='{"ok":true,"slug":"acme","enabled":true,"needsChoice":false,"source":"configured"}'
export HQ_DEFAULT_COMPANY_JSON
out="$(resolve 'please plan the globex migration')"
assert_eq "$(company_of "$out")" "globex" "explicit prompt beats session"
assert_eq "$(source_of "$out")" "prompt" "explicit prompt source"
pass "explicit prompt company beats ambient session"

printf '' > "$TMP/workspace/sessions/sess-1/meta.yaml"
HQ_DEFAULT_PREFLIGHT_JSON='{"contractVersion":1,"kind":"queued","classification":"needs_project","delivery":"queued","lifecycle":"open","sessionId":"__SID__","clientOperationId":"__OP__","companySlug":"acme","companyUid":"cmp_acme"}'
export HQ_DEFAULT_PREFLIGHT_JSON
out="$(resolve 'plan the default-backed migration')"
assert_eq "$(company_of "$out")" "acme" "enabled default resolves"
assert_eq "$(source_of "$out")" "device_default" "default source"
pass "active device-default membership resolves"

HQ_DEFAULT_PREFLIGHT_JSON='{"contractVersion":1,"kind":"queued","classification":"needs_project","delivery":"queued","lifecycle":"open","sessionId":"__SID__","clientOperationId":"__OP__","companySlug":"acme","companyUid":"cmp_acme"}'
HQ_LARGE_DEFAULT=1
export HQ_DEFAULT_PREFLIGHT_JSON HQ_LARGE_DEFAULT
out="$(resolve 'plan the large default-backed migration')"
assert_eq "$(company_of "$out")" "acme" "large default output is fully drained"
assert_eq "$(source_of "$out")" "device_default" "large default source"
pass "timed runner drains large child stdout before parsing"
unset HQ_LARGE_DEFAULT

HQ_DEFAULT_PREFLIGHT_JSON='{"contractVersion":1,"kind":"needs_company","classification":"needs_company","delivery":"clean","lifecycle":"open","sessionId":"__SID__","clientOperationId":"__OP__"}'
out="$(resolve 'plan the default-backed migration')"
assert_eq "$(company_of "$out")" "" "revoked default does not resolve"
assert_eq "$(source_of "$out")" "none" "revoked default source is none"
pass "revoked device-default membership fails closed"

HQ_DEFAULT_PREFLIGHT_JSON='not-json'
out="$(resolve 'plan the default-backed migration')"
assert_eq "$(company_of "$out")" "" "malformed validation does not resolve"
assert_eq "$(source_of "$out")" "none" "malformed validation source is none"
pass "malformed device-default validation fails closed"

HQ_DEFAULT_PREFLIGHT_JSON='{"contractVersion":1,"kind":"queued","classification":"needs_project","delivery":"queued","lifecycle":"open","sessionId":"__SID__","clientOperationId":"__OP__","companySlug":"acme","companyUid":"cmp_acme"}'
started_ms="$(node -e 'process.stdout.write(String(Date.now()))')"
out="$(HQ_SLOW_VALIDATOR=1 resolve 'plan the default-backed migration')"
finished_ms="$(node -e 'process.stdout.write(String(Date.now()))')"
elapsed_ms=$((finished_ms - started_ms))
[ "$elapsed_ms" -lt 4500 ] || fail "resolver membership validation did not stop before the delayed validator (${elapsed_ms}ms)"
assert_eq "$(company_of "$out")" "" "timed-out validation does not resolve"
assert_eq "$(source_of "$out")" "none" "timed-out validation source is none"
pass "membership validation watchdog fails closed"

out="$(HQ_FAIL_VALIDATOR=1 resolve 'plan the default-backed migration')"
assert_eq "$(company_of "$out")" "" "unavailable validation does not resolve"
assert_eq "$(source_of "$out")" "none" "unavailable validation source is none"
pass "unavailable device-default validation fails closed"

HQ_DEFAULT_COMPANY_JSON='{"ok":true,"slug":"acme","enabled":false,"needsChoice":false,"source":"disabled"}'
out="$(resolve 'plan the default-backed migration')"
assert_eq "$(company_of "$out")" "" "disabled default does not resolve"
assert_eq "$(source_of "$out")" "none" "disabled source is none"
pass "disabled device default falls through to picker"

HQ_DEFAULT_COMPANY_JSON='{"ok":true,"slug":"acme","enabled":true,"needsChoice":true,"source":"configured"}'
out="$(resolve 'plan the default-backed migration')"
assert_eq "$(company_of "$out")" "" "needsChoice does not resolve"
pass "needsChoice falls through to picker"

HQ_DEFAULT_COMPANY_JSON='{"ok":true,"slug":"acme","enabled":true,"needsChoice":false,"source":"configured"}'
HQ_AGENT_IDENTITY_FILE="$TMP/fleet-identity.json"
export HQ_AGENT_IDENTITY_FILE
out="$(resolve 'plan the default-backed migration')"
assert_eq "$(company_of "$out")" "" "fleet identity cannot use device default"
pass "fleet identity cannot resolve a device default"

unset HQ_AGENT_IDENTITY_FILE
mkdir -p "$TMP/fake-root/var/lib/hq-agent"
printf '{}\n' > "$TMP/fake-root/var/lib/hq-agent/identity.json"
HQ_AGENT_ROOT_PREFIX="$TMP/fake-root"
export HQ_AGENT_ROOT_PREFIX
out="$(resolve 'plan the default-backed migration')"
assert_eq "$(company_of "$out")" "" "canonical fleet identity path blocks device default"
assert_eq "$(source_of "$out")" "none" "canonical fleet identity source"
pass "canonical /var/lib/hq-agent/identity.json blocks resolver default"
unset HQ_AGENT_ROOT_PREFIX

# A known session slug must still be recognized when the manifest has a large
# tail. The 5 MB slug guarantees `printf` has data left after `grep -q` finds
# the first line, so pipefail exposes the early-close SIGPIPE deterministically.
awk 'BEGIN {
  print "companies:\n  acme:"
  printf "  tail"
  for (i = 0; i < 5000000; i++) printf "x"
  print ":"
}' > "$TMP/companies/manifest.yaml"
printf 'company_slug: acme\n' > "$TMP/workspace/sessions/sess-1/meta.yaml"
unset HQ_DEFAULT_COMPANY_JSON HQ_DEFAULT_PREFLIGHT_JSON || true
out="$(resolve 'no explicit company in this request')"
assert_eq "$(company_of "$out")" "acme" "known session slug survives a large manifest tail"
assert_eq "$(source_of "$out")" "session" "large manifest tail keeps session source"
pass "session slug is recognized before a large manifest tail"

run_held_stdout_case() {
  local label="$1" expected="$2" measure_drain="${3:-1}"
  shift 3
  local output="$TMP/$label.stdout" error="$TMP/$label.stderr" hq_exit_at="$TMP/$label.hq-exit-at" shell_finished_at="$TMP/$label.shell-finished-at"
  local ready="$TMP/$label.ready" release="$TMP/$label.release" holder="$TMP/$label.holder" done="$TMP/$label.done"
  rm -f "$ready" "$release" "$holder" "$done" "$output" "$error"
  (
    export HQ_HOLD_STDOUT_OPEN=1 HQ_GRANDCHILD_READY="$ready" HQ_GRANDCHILD_RELEASE="$release" HQ_GRANDCHILD_PID="$holder" HQ_RESOLVE_TIMEOUT_MS=4000 HQ_HQ_EXIT_AT="$hq_exit_at" HQ_HQ_HELD_STUB="$TMP/bin/hq-held.cjs"
    export PATH="$TMP/bin:$PATH"
    set +e
    "$@"
    code=$?
    node -e 'require("fs").writeFileSync(process.argv[1], String(process.hrtime.bigint()))' "$shell_finished_at"
    printf '%s\n' "$code" > "$done"
    exit "$code"
  ) >"$output" 2>"$error" &
  local runner="$!" attempt ready_seen=0
  for attempt in $(seq 1 100); do
    if [ -f "$ready" ]; then ready_seen=1; break; fi
    sleep 0.05
  done
  if [ "$ready_seen" -ne 1 ]; then
    printf "DEBUG output=%s\n" "$(cat "$output" 2>/dev/null || true)" >&2
    printf "DEBUG stderr=%s\n" "$(cat "$error" 2>/dev/null || true)" >&2
    printf "DEBUG hqlog=%s\n" "$(cat "$HQ_RESOLVE_NO_UPDATE_LOG" 2>/dev/null || true)" >&2
    touch "$release"
    wait "$runner" || true
    fail "$label: detached stdout holder did not start"
  fi
  local completed=0
  for attempt in $(seq 1 100); do
    if [ -f "$done" ]; then completed=1; break; fi
    sleep 0.05
  done
  if [ "$completed" -ne 1 ]; then
    touch "$release"
    wait "$runner" || true
    fail "$label: resolver waited for the detached descendant instead of settling on hq exit"
  fi
  local status=0
  wait "$runner" || status=$?
  local drain_ns drain_ms hq_exit_ms shell_finished_ms
  hq_exit_ms="$(cat "$hq_exit_at")"
  shell_finished_ms="$(cat "$shell_finished_at")"
  drain_ns=$((shell_finished_ms - hq_exit_ms))
  if [ "$measure_drain" = "1" ]; then
    # The resolver's post-exit drain is scheduled for 100 ms. The 1000 ms
    # ceiling leaves 900 ms for runner scheduling and stdout callback delay,
    # while rejecting a wait for this deliberately held pipe or the 4000 ms
    # command timeout. The folder-only path has no later hq calls, so this
    # measures exactly hq-exit through wrapper completion.
    [ "$drain_ns" -ge 0 ] || fail "$label: shell completion timestamp precedes hq exit ($drain_ns ns)"
    [ "$drain_ns" -lt 1000000000 ] || fail "$label: post-exit stdout drain exceeded 1000 ms ($drain_ns ns)"
    drain_ms="$(node -e 'process.stdout.write((Number(process.argv[1]) / 1e6).toFixed(1))' "$drain_ns")"
    echo "MEASURE: resolve-company drain ${OSTYPE:-unknown} $label ${drain_ms}ms"
  fi
  [ ! -e "$release" ] || fail "$label: test released stdout holder before resolver returned"
  touch "$release"
  if [ -f "$holder" ]; then
    local holder_pid
    holder_pid="$(cat "$holder")"
    for attempt in $(seq 1 100); do
      kill -0 "$holder_pid" 2>/dev/null || break
      sleep 0.05
    done
    if kill -0 "$holder_pid" 2>/dev/null; then kill "$holder_pid" 2>/dev/null || true; fi
  fi
  assert_eq "$status" "0" "$label exits successfully before timeout"
  assert_eq "$(cat "$output")" "$expected" "$label result survives descendant-held stdout"
  assert_eq "$(cat "$error")" "" "$label stderr"
}

mkdir -p "$TMP/companies/acme"
for sample in $(seq 1 10); do
  run_held_stdout_case "folder-registry-grandchild-$sample" '{"company":"acme","source":"registry"}' 1 bash "$TMP/core/scripts/resolve-company.sh" --root "$TMP" --path "$TMP/repo"
done
pass "folder registry settles after hq exits while detached stdout stays open"
printf '' > "$TMP/workspace/sessions/sess-1/meta.yaml"
HQ_DEFAULT_COMPANY_JSON='{"defaultCompany":{"slug":"acme","enabled":true,"needsChoice":false,"source":"configured"}}'
HQ_DEFAULT_PREFLIGHT_JSON='{"contractVersion":1,"kind":"queued","classification":"needs_project","delivery":"queued","lifecycle":"open","sessionId":"__SID__","clientOperationId":"__OP__","companySlug":"acme","companyUid":"cmp_acme"}'
export HQ_DEFAULT_COMPANY_JSON HQ_DEFAULT_PREFLIGHT_JSON
run_held_stdout_case default-company-grandchild '{"company":"acme","source":"device_default"}' 0 bash "$TMP/core/scripts/resolve-company.sh" --root "$TMP"
pass "default company settles after hq exits while detached stdout stays open"
unset HQ_DEFAULT_COMPANY_JSON HQ_DEFAULT_PREFLIGHT_JSON

started_ms="$(node -e 'process.stdout.write(String(Date.now()))')"
HQ_SLOW_DEFAULT=1 resolve 'plan the default-backed migration' >/dev/null
finished_ms="$(node -e 'process.stdout.write(String(Date.now()))')"
elapsed_ms=$((finished_ms - started_ms))
[ "$elapsed_ms" -lt 4500 ] || fail "resolver default lookup did not stop before the delayed command (${elapsed_ms}ms)"
pass "resolver default watchdog enforces a wall-clock ceiling"

unset HQ_AGENT_IDENTITY_FILE HQ_DEFAULT_COMPANY_JSON
echo "resolve-company: all passed"
