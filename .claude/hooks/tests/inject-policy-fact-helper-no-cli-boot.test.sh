#!/usr/bin/env bash
# Deriving trigger facts must not boot the hq CLI on a per-tool-call hook event,
# and must not bypass the forwarder's CLI version floor.
#
# HQ-HOOK-COST-001: core/scripts/derive-trigger-facts.sh is a forwarder that
# execs `hq core derive-trigger-facts`. That boots Node — about 229 MB RSS on
# the operator's Mac — once or twice for EVERY tool call. The program the CLI
# then runs on this path is a shell script shipped inside the CLI package, so
# the injector can run it directly.
#
# The forwarder also enforces a CLI version floor (lib/hq-cli-floor.sh, 5.342.5).
# Running the packaged companion directly must keep that check: an older
# package's companion answers with an older fact ABI, and a wrong fact set
# silently changes which policies fire.
#
# Each scenario stands up a fake CLI install with the real package layout, puts
# an `hq` entry on PATH that records every invocation of itself, and a `bash`
# entry that records every script it is asked to run so the forwarder's own
# launch is directly observable.
set -euo pipefail

TEST_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
HOOK_SOURCE="${HQ_INJECT_POLICY_TEST_HOOK:-$ROOT/.claude/hooks/inject-policy-on-trigger.sh}"
[ -f "$HOOK_SOURCE" ] || { echo "FAIL: hook source is missing: $HOOK_SOURCE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "inject-policy-fact-helper-no-cli-boot: skipped (jq missing)"; exit 0; }

REAL_BASH="$(command -v bash)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/inject-policy-fact-helper.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

TMP=""
CLI_LOG=""
COMPANION_LOG=""
BASH_LOG=""
HOOK_RC=0

# build_and_run <label> <package-version|none> — stand up the fixture and run
# one PreToolUse event through the hook. Sets TMP and the three log paths.
build_and_run() {
  local label="$1" version="$2"
  TMP="$WORK/$label"
  mkdir -p "$TMP/.claude/hooks" "$TMP/core" "$TMP/bin" \
    "$TMP/cli/dist" "$TMP/cli/assets/scaffold/core/scripts/lib"
  cp "$HOOK_SOURCE" "$TMP/.claude/hooks/inject-policy-on-trigger.sh"
  ln -s "$ROOT/core/scripts" "$TMP/core/scripts"
  ln -s "$ROOT/core/policies" "$TMP/core/policies"

  CLI_LOG="$TMP/cli-invocations.log"
  COMPANION_LOG="$TMP/companion-invocations.log"
  BASH_LOG="$TMP/bash-invocations.log"
  : > "$CLI_LOG"
  : > "$COMPANION_LOG"
  : > "$BASH_LOG"

  # The CLI entry point. `hq` on PATH is a symlink to it, the way a global npm
  # install links its bin.
  cat > "$TMP/cli/dist/index.js" <<CLI
#!/bin/bash
printf '%s\n' "\$*" >> "$CLI_LOG"
printf '%s\n' "always"
CLI
  chmod +x "$TMP/cli/dist/index.js"
  ln -s "$TMP/cli/dist/index.js" "$TMP/bin/hq"

  # Records which script the hook hands to bash, so "the forwarder ran" is an
  # observation rather than an inference from the companion's silence.
  cat > "$TMP/bin/bash" <<SHIM
#!/bin/bash
printf '%s\n' "\$*" >> "$BASH_LOG"
exec "$REAL_BASH" "\$@"
SHIM
  chmod +x "$TMP/bin/bash"

  # The bundled shell companion and the two helpers the injector requires
  # before it will use it.
  cat > "$TMP/cli/assets/scaffold/core/scripts/derive-trigger-facts.sh" <<COMPANION
#!/bin/bash
printf '%s\n' "\$* hq_root=\${HQ_ROOT:-unset}" >> "$COMPANION_LOG"
# The real companion answers a paired request with two fact lines: the event's
# facts and the assistant-intent facts. A one-line answer would make the hook
# launch a second helper for the missing set, which is not what is under test.
if [ "\${2:-}" = "--with-assistant-intent" ]; then
  printf '%s\n%s\n' "always company" "always company"
else
  printf '%s\n' "always company"
fi
COMPANION
  chmod +x "$TMP/cli/assets/scaffold/core/scripts/derive-trigger-facts.sh"
  printf '%s\n' '{ print }' > "$TMP/cli/assets/scaffold/core/scripts/lib/trigger-fact-text.awk"
  printf '%s\n' '# stub' > "$TMP/cli/assets/scaffold/core/scripts/lib/transcript-tail.sh"

  if [ "$version" != "none" ]; then
    printf '{\n  "name": "@indigoai-us/hq-cli",\n  "version": "%s"\n}\n' "$version" \
      > "$TMP/cli/package.json"
  fi

  run_hook "$label"
}

# run_hook <label> — one PreToolUse event through the hook in the current $TMP.
# Separate from the fixture build so a scenario can run the same tree twice,
# which is how the memo cache becomes observable.
run_hook() {
  local label="$1" payload
  payload="$(jq -cn --arg cwd "$TMP" '{hook_event_name:"PreToolUse",session_id:"fact-helper-boot",tool_name:"Bash",cwd:$cwd,tool_input:{command:"true"}}')"
  unset BASH_ENV ENV HQ_POLICY_WORKER_DIR
  set +e
  PATH="$TMP/bin:$PATH" HOME="$TMP/home" \
    XDG_STATE_HOME="$TMP/home/.local/state" HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
    HQ_HOOK_PROFILE=standard HQ_HOOK_TIMEOUT_SENTRY=0 \
    bash "$TMP/.claude/hooks/inject-policy-on-trigger.sh" \
    <<<"$payload" >"$TMP/hook.out" 2>"$TMP/hook.err"
  HOOK_RC=$?
  set -e
  [ "$HOOK_RC" -eq 0 ] || {
    echo "FAIL [$label]: hook exited $HOOK_RC" >&2
    tail -200 "$TMP/hook.err" >&2
    exit 1
  }
}

count_lines() { wc -l < "$1" | tr -d ' '; }

# ---------------------------------------------------------------------------
# 1. A package at the floor: the companion runs, the CLI never boots.
# ---------------------------------------------------------------------------
build_and_run at-floor 5.342.5
COMPANION_CALLS="$(count_lines "$COMPANION_LOG")"
CLI_CALLS="$(count_lines "$CLI_LOG")"

[ "$COMPANION_CALLS" -ge 1 ] || {
  echo "FAIL: the bundled shell companion never ran; fact derivation did not reach it" >&2
  echo "      cli invocations: $CLI_CALLS" >&2
  tail -20 "$TMP/hook.err" >&2
  exit 1
}

[ "$CLI_CALLS" -eq 0 ] || {
  echo "FAIL: the hq CLI was booted $CLI_CALLS time(s) for one hook event" >&2
  head -5 "$CLI_LOG" >&2
  exit 1
}

# The companion resolves HQ_ROOT from its own location, which inside the CLI
# package is not an HQ root. The injector must pass the real one.
while IFS= read -r line; do
  case "$line" in
    *"hq_root=$TMP") ;;
    *)
      echo "FAIL: companion received the wrong HQ root: $line (expected hq_root=$TMP)" >&2
      exit 1
      ;;
  esac
done < "$COMPANION_LOG"

# Primary and AssistantIntent facts come from ONE paired launch, never from a
# second bare AssistantIntent launch. core/scripts/tests/inject-policy-cache.test.sh
# holds this contract for the forwarder path; this holds it for the direct path.
if grep -q -- '--with-assistant-intent' "$COMPANION_LOG"; then
  grep -q '^AssistantIntent ' "$COMPANION_LOG" && {
    echo "FAIL: the hook paired the facts AND launched a second AssistantIntent helper" >&2
    cat "$COMPANION_LOG" >&2
    exit 1
  }
fi

PASS_COMPANION="$COMPANION_CALLS"
PASS_CLI="$CLI_CALLS"

# ---------------------------------------------------------------------------
# 2. A package below the floor: the direct path must refuse and the forwarder
#    must run, because an older fact ABI changes which policies fire.
# ---------------------------------------------------------------------------
build_and_run below-floor 5.342.4
[ "$(count_lines "$COMPANION_LOG")" -eq 0 ] || {
  echo "FAIL: the packaged companion ran from a below-floor CLI (5.342.4 < 5.342.5)" >&2
  cat "$COMPANION_LOG" >&2
  exit 1
}
grep -q "$TMP/core/scripts/derive-trigger-facts.sh" "$BASH_LOG" || {
  echo "FAIL: a below-floor CLI did not fall through to the forwarder" >&2
  cat "$BASH_LOG" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 3. No package manifest at all: unreadable version is treated as below floor.
# ---------------------------------------------------------------------------
build_and_run no-manifest none
[ "$(count_lines "$COMPANION_LOG")" -eq 0 ] || {
  echo "FAIL: the packaged companion ran with no readable package version" >&2
  cat "$COMPANION_LOG" >&2
  exit 1
}
grep -q "$TMP/core/scripts/derive-trigger-facts.sh" "$BASH_LOG" || {
  echo "FAIL: an unreadable CLI version did not fall through to the forwarder" >&2
  cat "$BASH_LOG" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 4. An upgrade retargets a stable `hq` symlink at a different package. The
#    memo cache key is the `command -v hq` path, which does not change, so a
#    key-only check would keep running the old package's companion for as long
#    as it stayed readable — past the version floor, which is only evaluated at
#    resolution time. The memo must go stale when the entry it came from moves.
# ---------------------------------------------------------------------------
build_and_run retargeted 5.342.5
[ "$(count_lines "$COMPANION_LOG")" -ge 1 ] || {
  echo "FAIL: the at-floor warm-up did not reach the companion, so there is no memo to invalidate" >&2
  exit 1
}

# A second, below-floor package with its own companion, logging to the same file
# so running the wrong one is visible rather than silent.
mkdir -p "$TMP/cli-old/dist" "$TMP/cli-old/assets/scaffold/core/scripts/lib"
cat > "$TMP/cli-old/dist/index.js" <<CLI
#!/bin/bash
printf '%s\n' "\$*" >> "$CLI_LOG"
printf '%s\n' "always"
CLI
chmod +x "$TMP/cli-old/dist/index.js"
cat > "$TMP/cli-old/assets/scaffold/core/scripts/derive-trigger-facts.sh" <<COMPANION
#!/bin/bash
printf '%s\n' "OLD-PACKAGE \$*" >> "$COMPANION_LOG"
printf '%s\n' "always company"
COMPANION
chmod +x "$TMP/cli-old/assets/scaffold/core/scripts/derive-trigger-facts.sh"
printf '%s\n' '{ print }' > "$TMP/cli-old/assets/scaffold/core/scripts/lib/trigger-fact-text.awk"
printf '%s\n' '# stub' > "$TMP/cli-old/assets/scaffold/core/scripts/lib/transcript-tail.sh"
printf '{\n  "name": "@indigoai-us/hq-cli",\n  "version": "5.342.4"\n}\n' > "$TMP/cli-old/package.json"

ln -sfn "$TMP/cli-old/dist/index.js" "$TMP/bin/hq"
: > "$COMPANION_LOG"
: > "$CLI_LOG"
: > "$BASH_LOG"

run_hook retargeted-second-event
[ "$(count_lines "$COMPANION_LOG")" -eq 0 ] || {
  echo "FAIL: a retargeted hq symlink reused the memo and ran a packaged companion anyway" >&2
  cat "$COMPANION_LOG" >&2
  exit 1
}
grep -q "$TMP/core/scripts/derive-trigger-facts.sh" "$BASH_LOG" || {
  echo "FAIL: a retargeted hq symlink pointing below the floor did not fall through to the forwarder" >&2
  cat "$BASH_LOG" >&2
  exit 1
}

printf 'PASS: %s companion call(s), %s hq CLI boot(s) at the floor; below-floor, unversioned and retargeted CLIs all fell through to the forwarder\n' \
  "$PASS_COMPANION" "$PASS_CLI"
