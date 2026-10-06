#!/usr/bin/env bash
# Build-only Tart harness for US-016. The real VM run is a manual Mac action.
set -uo pipefail
ORIGINAL_ARGS=("$@")

TART_BIN="tart" BASE_IMAGE="macos-sequoia-base" CLI_PACKAGE="" CORE_BUNDLE=""
FIXTURE_REPO="" FIXTURE_REF="" COMPANY="" HQ_API_URL="" RESULTS_DIR=""
APPROVED_FIXTURE_REPO="${HQ_US016_FIXTURE_REPO:-}"
APPROVED_FIXTURE_REF="${HQ_US016_FIXTURE_REF:-}"
APPROVED_TEST_COMPANY="${HQ_US016_TEST_COMPANY:-}"
SECRET_NAMES="" TIMEOUT_SECONDS=1200 SECRETS_READY=0

usage() {
  cat <<'USAGE'
Usage: anywhere-vm-test.sh --cli-package FILE.tgz --core-bundle FILE.tar.gz
       --fixture-repo URL --fixture-ref SHA --company SLUG --hq-api-url NONPROD_URL
       --secret-names NAME[=ENV][,NAME[=ENV]...] [--base-image NAME]
       [--results-dir DIR] [--tart-bin FILE] [--timeout-seconds N]

The script obtains each named credential with `hq secrets exec`; slash-namespaced
records must map to an explicit environment name. Credentials travel to the VM over
stdin and are never included in command arguments or image files.
USAGE
}

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cli-package) CLI_PACKAGE="${2:-}"; shift 2 ;;
    --core-bundle) CORE_BUNDLE="${2:-}"; shift 2 ;;
    --fixture-repo) FIXTURE_REPO="${2:-}"; shift 2 ;;
    --fixture-ref) FIXTURE_REF="${2:-}"; shift 2 ;;
    --company) COMPANY="${2:-}"; shift 2 ;;
    --hq-api-url) HQ_API_URL="${2:-}"; shift 2 ;;
    --secret-names) SECRET_NAMES="${2:-}"; shift 2 ;;
    --base-image) BASE_IMAGE="${2:-}"; shift 2 ;;
    --results-dir) RESULTS_DIR="${2:-}"; shift 2 ;;
    --tart-bin) TART_BIN="${2:-}"; shift 2 ;;
    --timeout-seconds) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    --secrets-ready) SECRETS_READY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$CLI_PACKAGE" ] && [ -f "$CLI_PACKAGE" ] || fail "--cli-package must name an existing npm tarball"
[ -n "$CORE_BUNDLE" ] && [ -f "$CORE_BUNDLE" ] || fail "--core-bundle must name an existing source archive"
[ -n "$FIXTURE_REPO" ] || fail "--fixture-repo is required"
[ -n "$FIXTURE_REF" ] || fail "--fixture-ref must pin the reviewed fixture commit"
[ -n "$COMPANY" ] || fail "--company is required"
[ -n "$HQ_API_URL" ] || fail "--hq-api-url is required and must name the approved non-production HQ API"
[ -n "$APPROVED_FIXTURE_REPO" ] || fail "HQ_US016_FIXTURE_REPO must be configured to the approved disposable fixture repository"
[ "$FIXTURE_REPO" = "$APPROVED_FIXTURE_REPO" ] || fail "--fixture-repo must exactly match HQ_US016_FIXTURE_REPO"
[ -n "$APPROVED_FIXTURE_REF" ] || fail "HQ_US016_FIXTURE_REF must be configured to the reviewed fixture commit"
[ "$FIXTURE_REF" = "$APPROVED_FIXTURE_REF" ] || fail "--fixture-ref must exactly match HQ_US016_FIXTURE_REF"
[ -n "$APPROVED_TEST_COMPANY" ] || fail "HQ_US016_TEST_COMPANY must be configured to the approved disposable company"
[ "$COMPANY" = "$APPROVED_TEST_COMPANY" ] || fail "--company must exactly match HQ_US016_TEST_COMPANY"
case "$FIXTURE_REF" in *[!a-fA-F0-9]*|'') fail "--fixture-ref must be a 40-character commit SHA" ;; esac
[ "${#FIXTURE_REF}" -eq 40 ] || fail "--fixture-ref must be a 40-character commit SHA"
command -v node >/dev/null 2>&1 || fail "Node.js is required to validate the HQ API URL"
if ! node - "$HQ_API_URL" <<'NODE'
const raw = process.argv[2];
let url;
try { url = new URL(raw); } catch { process.exit(1); }
if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) process.exit(1);
const host = url.hostname.toLowerCase();
if (/(^|[.-])(prod|production)([.-]|$)/.test(host)) process.exit(1);
if (host === 'localhost' || host === '127.0.0.1' || host.endsWith('.test') ||
    /(^|[.-])(staging|sandbox|dev)([.-]|$)/.test(host)) process.exit(0);
process.exit(1);
NODE
then
  fail "--hq-api-url must be a credential-free HTTP(S) URL on an explicitly non-production hostname"
fi
if ! node - "$FIXTURE_REPO" <<'NODE'
const raw = process.argv[2];
let url;
try { url = new URL(raw); } catch { process.exit(1); }
if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash ||
    url.hostname.toLowerCase() !== 'github.com' || !/^\/indigoai-us\/[A-Za-z0-9_.-]+(?:\.git)?$/.test(url.pathname)) {
  process.exit(1);
}
NODE
then
  fail "--fixture-repo must be a canonical HTTPS repository under indigoai-us"
fi
COMPANY_LOWER="$(printf '%s' "$COMPANY" | tr '[:upper:]' '[:lower:]')"
case "$COMPANY_LOWER" in *prod*|*production*) fail "refusing a production company slug" ;; esac
[ -n "$SECRET_NAMES" ] || fail "--secret-names is required"
case "$TIMEOUT_SECONDS" in ''|*[!0-9]*) fail "--timeout-seconds must be a positive integer" ;; esac
[ "$TIMEOUT_SECONDS" -gt 0 ] && [ "$TIMEOUT_SECONDS" -le 1200 ] || fail "--timeout-seconds must be between 1 and 1200"
case "$COMPANY" in *[!A-Za-z0-9_.-]*|'') fail "--company must be a company slug" ;; esac
case "$COMPANY" in *test*) ;; *) fail "--company must name a disposable test company" ;; esac
case "$COMPANY" in *prod*|*indigo*) fail "refusing a production company slug" ;; esac
case "$BASE_IMAGE" in *[!A-Za-z0-9_.:/@-]*|'') fail "--base-image contains unsupported characters" ;; esac

IFS=',' read -r -a SECRET_SPEC_LIST <<< "$SECRET_NAMES"
[ "${#SECRET_SPEC_LIST[@]}" -gt 0 ] || fail "--secret-names must not be empty"
SECRET_SOURCE_LIST=() SECRET_ENV_LIST=() SECRET_SOURCE_NAMES="" SECRET_ENV_MAP=""
declare -A SECRET_SOURCES_SEEN=() SECRET_ENVS_SEEN=()
for secret_spec in "${SECRET_SPEC_LIST[@]}"; do
  case "$secret_spec" in
    *=*) secret_source="${secret_spec%%=*}"; secret_env="${secret_spec#*=}" ;;
    *) secret_source="$secret_spec"; secret_env="$secret_spec" ;;
  esac
  case "$secret_source" in
    [A-Za-z_]* ) ;;
    *) fail "secret names must begin with a letter or underscore" ;;
  esac
  [[ "$secret_source" =~ ^[A-Za-z_][A-Za-z_0-9.-]*(/[A-Za-z_][A-Za-z_0-9.-]*)*$ ]] || fail "secret names must be environment identifiers or slash-namespaced names"
  [[ "$secret_env" =~ ^[A-Za-z_][A-Za-z_0-9]*$ ]] || fail "secret mappings must end with an environment-variable name"
  [[ -z "${SECRET_SOURCES_SEEN[$secret_source]:-}" ]] || fail "secret names must not be repeated"
  [[ -z "${SECRET_ENVS_SEEN[$secret_env]:-}" ]] || fail "secret environment names must not be repeated"
  SECRET_SOURCES_SEEN[$secret_source]=1
  SECRET_ENVS_SEEN[$secret_env]=1
  SECRET_SOURCE_LIST+=("$secret_source")
  SECRET_ENV_LIST+=("$secret_env")
  [ -z "$SECRET_SOURCE_NAMES" ] || SECRET_SOURCE_NAMES+=,
  SECRET_SOURCE_NAMES="${SECRET_SOURCE_NAMES}${secret_source}"
  [ -z "$SECRET_ENV_MAP" ] || SECRET_ENV_MAP+=,
  SECRET_ENV_MAP="${SECRET_ENV_MAP}${secret_source}=${secret_env}"
  case "${!secret_env:-}" in *$'\n'*|*$'\r'*) fail "credential values must be single-line for secure stdin transport" ;; esac
done

if [ "$SECRETS_READY" -eq 0 ]; then
  command -v hq >/dev/null 2>&1 || fail "hq is required on the Mac host to inject credentials"
  export HQ_VAULT_API_URL="$HQ_API_URL"
  export HQ_VM_SECRET_ENV_MAP="$SECRET_ENV_MAP"
  exec hq secrets --company "$COMPANY" exec --only "$SECRET_SOURCE_NAMES" -- node -e '
const { spawnSync } = require("node:child_process");
const [script, ...args] = process.argv.slice(1);
const env = { ...process.env };
for (const entry of (env.HQ_VM_SECRET_ENV_MAP || "").split(",").filter(Boolean)) {
  const separator = entry.lastIndexOf("=");
  const source = entry.slice(0, separator);
  const target = entry.slice(separator + 1);
  const value = env[source];
  if (value === undefined || value.length === 0) {
    console.error(`a requested credential is not available in the hq secrets exec environment (${source}: ${value === undefined ? "unset" : "empty"})`);
    process.exit(2);
  }
  if (/[\r\n]/.test(value)) {
    console.error("credential values must be single-line for secure stdin transport");
    process.exit(2);
  }
  env[target] = value;
  if (source !== target) delete env[source];
}
delete env.HQ_VM_SECRET_ENV_MAP;
const child = spawnSync("/bin/bash", [script, "--secrets-ready", ...args], { env, stdio: "inherit" });
if (child.error) {
  console.error("failed to start the harness with injected credentials");
  process.exit(2);
}
process.exit(child.status ?? 1);
' "$0" "${ORIGINAL_ARGS[@]}"
fi

for secret_env in "${SECRET_ENV_LIST[@]}"; do
  [ -n "${!secret_env:-}" ] || fail "requested credential target is unavailable: $secret_env"
done

command -v "$TART_BIN" >/dev/null 2>&1 || [ -x "$TART_BIN" ] || fail "Tart is required on the Mac host"
command -v perl >/dev/null 2>&1 || fail "Perl is required to bound individual host commands"
command -v tar >/dev/null 2>&1 || fail "tar is required on the Mac host"

if [ -z "$RESULTS_DIR" ]; then
  RESULTS_DIR="$PWD/anywhere-vm-results-$(date +%Y%m%d%H%M%S)-$$-${RANDOM:-0}"
fi
mkdir -p "$RESULTS_DIR" || fail "could not create the results directory"

VM_NAME="hq-us016-$$-${RANDOM:-0}"
VM_CREATED=0 TART_RUN_PID="" EXIT_STATUS=0
START_SECONDS=$SECONDS
CLEANUP_RESERVE=24
if [ "$TIMEOUT_SECONDS" -lt 30 ]; then CLEANUP_RESERVE=1; fi
WORK_BUDGET=$((TIMEOUT_SECONDS - CLEANUP_RESERVE - 2))
[ "$WORK_BUDGET" -gt 0 ] || WORK_BUDGET=1
WORK_DEADLINE=$((START_SECONDS + WORK_BUDGET))

remaining_seconds() {
  local left=$((WORK_DEADLINE - SECONDS))
  [ "$left" -gt 0 ] || return 1
  printf '%s\n' "$left"
}

run_bounded() {
  local seconds="$1"
  shift
  # alarm(2) survives exec, so this also works on stock macOS without GNU timeout.
  perl -e 'my $n=shift; $SIG{ALRM}=sub { exit 124 }; alarm $n; exec @ARGV or die "exec failed\n"' "$seconds" "$@"
}

redact_output() {
  local value="$1" secret_name secret_value
  for secret_name in "${SECRET_ENV_LIST[@]}"; do
    secret_value="${!secret_name}"
    value="${value//"$secret_value"/[REDACTED]}"
  done
  printf '%s' "$value"
}

TART_ARGS=("$TART_BIN")
guest_exec() {
  local seconds
  seconds="$(remaining_seconds)" || { printf 'overall 20-minute work deadline reached\n' >&2; return 124; }
  local -a guest_command=("$@")
  local guest_bootstrap='while IFS= read -r secret_assignment; do [ -n "$secret_assignment" ] || continue; export "$secret_assignment"; done; exec "$@"'
  {
    local secret_name
  for secret_name in "${SECRET_ENV_LIST[@]}"; do printf '%s=%s\n' "$secret_name" "${!secret_name}"; done
  } | run_bounded "$seconds" "${TART_ARGS[@]}" exec -i "$VM_NAME" /usr/bin/env "HQ_VAULT_API_URL=$HQ_API_URL" \
    /bin/bash -c "$guest_bootstrap" anywhere-vm-guest "${guest_command[@]}"
}

capture_guest() {
  local label="$1" status=0 clean
  shift
  local output
  if output="$(guest_exec "$@" 2>&1)"; then status=0; else status=$?; fi
  clean="$(redact_output "$output")"
  printf '%s\n' "$clean" > "$RESULTS_DIR/$label.log"
  [ -z "$clean" ] || printf '%s\n' "$clean"
  return "$status"
}

cleanup() {
  local old_status=$?
  trap - EXIT INT TERM
  set +e
  if [ "$VM_CREATED" -eq 1 ]; then
    if [ -n "$TART_RUN_PID" ]; then
      kill "$TART_RUN_PID" >/dev/null 2>&1
      wait "$TART_RUN_PID" >/dev/null 2>&1
      TART_RUN_PID=""
    fi
    local cleanup_step=$((CLEANUP_RESERVE / 2))
    [ "$cleanup_step" -gt 0 ] || cleanup_step=1
    run_bounded "$cleanup_step" "${TART_ARGS[@]}" stop "$VM_NAME" --timeout 10 >/dev/null 2>&1
    if ! run_bounded "$cleanup_step" "${TART_ARGS[@]}" delete "$VM_NAME" >/dev/null 2>&1; then
      printf 'FAIL Tart VM deletion failed for %s\n' "$VM_NAME" >&2
      [ "$EXIT_STATUS" -ne 0 ] || EXIT_STATUS=1
    fi
  fi
  if [ "$old_status" -ne 0 ]; then EXIT_STATUS="$old_status"; fi
  exit "$EXIT_STATUS"
}
trap cleanup EXIT
trap 'EXIT_STATUS=130; exit 130' INT TERM

printf 'VM test artifacts: %s\n' "$RESULTS_DIR"
VM_CREATED=1
run_bounded "$(remaining_seconds)" "${TART_ARGS[@]}" clone "$BASE_IMAGE" "$VM_NAME" || { EXIT_STATUS=$?; printf 'FAIL VM clone\n' >&2; exit "$EXIT_STATUS"; }

CLI_DIR="$(cd "$(dirname "$CLI_PACKAGE")" && pwd -P)"
CORE_DIR="$(cd "$(dirname "$CORE_BUNDLE")" && pwd -P)"
CLI_BASENAME="$(basename "$CLI_PACKAGE")"
CORE_BASENAME="$(basename "$CORE_BUNDLE")"
run_bounded "$(remaining_seconds)" "${TART_ARGS[@]}" run --no-graphics \
  --dir="hq-cli:$CLI_DIR:ro" --dir="hq-core:$CORE_DIR:ro" "$VM_NAME" \
  >"$RESULTS_DIR/tart-run.log" 2>&1 &
TART_RUN_PID=$!
sleep 1

READY=0
while [ "$SECONDS" -lt "$WORK_DEADLINE" ]; do
  if guest_exec /usr/bin/true >/dev/null 2>&1; then READY=1; break; fi
  sleep 2
done
if [ "$READY" -ne 1 ]; then
  printf 'FAIL VM boot did not become ready before the deadline\n' >&2
  EXIT_STATUS=1
  exit 1
fi

GUEST_SETUP='set -euo pipefail
command -v brew >/dev/null
brew install node@22
export PATH="/opt/homebrew/opt/node@22/bin:$PATH"
npm install --global "/Volumes/My Shared Files/hq-cli/$HQ_VM_CLI_PACKAGE"
mkdir -p "$HOME/hq-root" "$HOME/.hq"
tar -xzf "/Volumes/My Shared Files/hq-core/$HQ_VM_CORE_BUNDLE" -C "$HOME/hq-root"
mkdir -p "$HOME/hq-us016-fixture"
git -C "$HOME/hq-us016-fixture" init
git -C "$HOME/hq-us016-fixture" remote add origin "$HQ_VM_FIXTURE_REPO"
git -C "$HOME/hq-us016-fixture" fetch --depth 1 origin "$HQ_VM_FIXTURE_REF"
git -C "$HOME/hq-us016-fixture" checkout --detach FETCH_HEAD
node - "$HOME/hq-us016-fixture" "$HQ_VM_COMPANY" <<"NODE"
const fs = require("node:fs");
const path = require("node:path");
const repo = fs.realpathSync(process.argv[2]);
const company = process.argv[3];
const dir = path.join(process.env.HOME, ".hq");
const file = path.join(dir, "registry.json");
fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
let registry = { version: 1, entries: {} };
try { registry = JSON.parse(fs.readFileSync(file, "utf8")); } catch (error) {
  if (error.code !== "ENOENT") throw error;
}
registry.entries[`path:${repo}`] = { company, source: "link", linkedAt: new Date().toISOString() };
fs.writeFileSync(file, JSON.stringify(registry, null, 2), { mode: 0o600 });
NODE
test "$(hq resolve-company --path "$HOME/hq-us016-fixture" --json | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const r=JSON.parse(s);process.stdout.write(r.company||\"\")})")" = "$HQ_VM_COMPANY"
hq install --global --runtime claude --hq-root "$HOME/hq-root"
hq install --global --runtime codex --hq-root "$HOME/hq-root"
hq daemon install --hq-root "$HOME/hq-root"
node -e "const username=process.env.HQ_MACHINE_USERNAME; const secret=process.env.HQ_MACHINE_SECRET; if (!username || !secret) process.exit(2); process.stdout.write(JSON.stringify({username,secret}));" | hq daemon login --stdin
hq daemon login --status | grep -q "hqd signed in: yes (memory only)"
test ! -e "$HOME/.hq/daemon/cognito-tokens.json"
test ! -e "$HOME/.hq/cognito-tokens.json"
'
if capture_guest setup env "HQ_VM_CLI_PACKAGE=$CLI_BASENAME" "HQ_VM_CORE_BUNDLE=$CORE_BASENAME" \
  "HQ_VM_FIXTURE_REPO=$FIXTURE_REPO" "HQ_VM_FIXTURE_REF=$FIXTURE_REF" "HQ_VM_COMPANY=$COMPANY" /bin/zsh -lc "$GUEST_SETUP"; then
  :
else
  EXIT_STATUS=$?
  printf 'FAIL VM setup\n' >&2
  exit 1
fi

PARITY_FAILED=0
for runtime in claude codex; do
  PARITY_COMMAND='bash "$HOME/hq-root/core/scripts/anywhere-parity-test.sh" --runtime "$HQ_VM_RUNTIME" --repo "$HOME/hq-us016-fixture" --company "$HQ_VM_COMPANY" --hq-root "$HOME/hq-root" --json'
  if capture_guest "parity-$runtime" env "HQ_VM_RUNTIME=$runtime" "HQ_VM_COMPANY=$COMPANY" /bin/zsh -lc "$PARITY_COMMAND"; then :; else PARITY_FAILED=1; fi
  RESULT_FILE="$RESULTS_DIR/parity-$runtime.log"
  if ! node - "$RESULT_FILE" <<'NODE'
const fs = require("node:fs");
const lines = fs.readFileSync(process.argv[2], "utf8").split(/\r?\n/).filter(Boolean);
if (lines.length !== 4) process.exit(2);
for (const line of lines) {
  const row = JSON.parse(line);
  if (row.result === "FAIL") process.exitCode = 1;
  else if (row.result !== "PASS") process.exit(2);
}
NODE
  then
    PARITY_FAILED=1
  fi
  node - "$RESULT_FILE" <<'NODE'
const fs = require("node:fs");
for (const line of fs.readFileSync(process.argv[2], "utf8").split(/\r?\n/).filter(Boolean)) {
  try {
    const row = JSON.parse(line);
    if (row.result === "FAIL") console.log(`FAIL ${row.assertion} — ${row.detail}`);
  } catch {}
}
NODE
done

if ! capture_guest doctor hq doctor --json; then
  printf 'WARN hq doctor exited non-zero; see %s/doctor.log\n' "$RESULTS_DIR" >&2
fi

if [ "$PARITY_FAILED" -ne 0 ]; then
  printf 'FAIL US-016 parity; see the recorded FAIL assertion lines and JSON logs in %s\n' "$RESULTS_DIR" >&2
  EXIT_STATUS=1
else
  printf 'PASS US-016 parity for claude and codex; VM teardown follows\n'
fi
exit "$EXIT_STATUS"
