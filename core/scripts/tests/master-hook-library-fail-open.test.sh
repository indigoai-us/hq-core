#!/usr/bin/env bash
# master-hook must run every eligible registry hook when its shared prefilter
# library is unavailable, and report that the optimization has been disabled.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SOURCE_ROOT="${HQ_TEST_SOURCE_ROOT:-$ROOT}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
pass() { printf 'PASS: %s\n' "$*"; }

run_case() {
  local mode="$1" root="$TMP/root-$1" rel id script payload status=0
  mkdir -p "$root/.claude/hooks" "$root/core/scripts/lib" "$root/core/policies" \
    "$root/personal/policies" "$root/workspace"
  for rel in \
    .claude/hooks/master-hook.sh \
    .claude/hooks/hook-gate.sh \
    .claude/hooks/hook-timeout-probe.sh \
    .claude/hooks/hook-timeout-watchdog.sh \
    core/scripts/lib/hook-adapter-core.sh; do
    mkdir -p "$root/${rel%/*}"
    cp "$SOURCE_ROOT/$rel" "$root/$rel"
  done

  case "$mode" in
    missing) rm -f "$root/core/scripts/lib/hook-adapter-core.sh" ;;
    load-error) printf 'return 1\n' > "$root/core/scripts/lib/hook-adapter-core.sh" ;;
  esac

  for id in regex-prefilter env-prefilter file-prefilter policy-vocab unfiltered; do
    script="$root/.claude/hooks/$id.sh"
    cat > "$script" <<HOOK
#!/usr/bin/env bash
cat >/dev/null
printf '%s\\n' '$id' >> "\${HQ_TEST_HOOK_LOG:?}"
HOOK
    chmod +x "$script"
  done

  jq -cn '
    {hooks:{PreToolUse:[{matcher:"Bash",hooks:[
      {id:"regex-prefilter",script:".claude/hooks/regex-prefilter.sh",gated:false,prefilter:{re:"NO_MATCH_TOKEN"}},
      {id:"env-prefilter",script:".claude/hooks/env-prefilter.sh",gated:false,prefilter:{env:"HQ_TEST_PREFILTER_UNSET"}},
      {id:"file-prefilter",script:".claude/hooks/file-prefilter.sh",gated:false,prefilter:{file:"workspace/no-such-prefilter-file"}},
      {id:"policy-vocab",script:".claude/hooks/policy-vocab.sh",gated:false,prefilter:{policy_vocab:true}},
      {id:"unfiltered",script:".claude/hooks/unfiltered.sh",gated:false}
    ]}]}}
  ' > "$root/.claude/hooks/hook-registry.json"

  payload="$(jq -cn --arg cwd "$root" \
    '{session_id:"fail-open-test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:"printf benign"}}')"
  : > "$TMP/$mode.hooks"
  : > "$TMP/$mode.out"
  : > "$TMP/$mode.err"
  unset HQ_HARNESS || true
  if printf '%s' "$payload" | env \
    HQ_TEST_HOOK_LOG="$TMP/$mode.hooks" \
    HQ_HOOK_PROFILE=standard \
    HQ_DISABLED_HOOKS= \
    HQ_HOOK_TIMEOUT_SENTRY=0 \
    BASH_ENV=/dev/null \
    bash "$root/.claude/hooks/master-hook.sh" PreToolUse \
      > "$TMP/$mode.out" 2> "$TMP/$mode.err"; then
    status=0
  else
    status=$?
  fi

  if [ "$status" -eq 0 ]; then pass "$mode: master-hook exits successfully"; else fail "$mode: master-hook exited $status"; fi
  local expected actual
  expected="$(printf '%s\n' regex-prefilter env-prefilter file-prefilter policy-vocab unfiltered)"
  actual="$(cat "$TMP/$mode.hooks")"
  if [ "$actual" = "$expected" ]; then pass "$mode: every registry hook ran exactly once"; else fail "$mode: registry hook run list was incomplete or reordered"; fi

  local warning_count stderr_lines
  warning_count="$(grep -Fxc 'master-hook: WARNING hook-adapter-core.sh did not load; registry prefilters are disabled' "$TMP/$mode.err" || true)"
  stderr_lines="$(awk 'END { print NR + 0 }' "$TMP/$mode.err")"
  if [ "$warning_count" -eq 1 ] && [ "$stderr_lines" -eq 1 ]; then
    pass "$mode: one clear fail-open warning was written to stderr"
  else
    fail "$mode: expected exactly one fail-open warning line; got $stderr_lines stderr lines"
  fi
}

run_case missing
run_case load-error

if [ "$FAIL" -eq 0 ]; then
  echo "master-hook-library-fail-open: all checks passed"
  exit 0
fi
echo "master-hook-library-fail-open: $FAIL failure(s)" >&2
exit 1
