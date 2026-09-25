#!/usr/bin/env bash
# hq-core: public
# Regression for registry prefilters and adapter-level timeout watchdogs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SOURCE_ROOT="${HQ_TEST_SOURCE_ROOT:-$ROOT}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  FAIL=$((FAIL + 1))
}

copy_from_source() {
  local relative="$1"
  mkdir -p "$TMP/root/${relative%/*}"
  cp "$SOURCE_ROOT/$relative" "$TMP/root/$relative"
}

make_fixture() {
  local provider="$1" root id script
  root="$TMP/root-$provider"
  mkdir -p "$root/.claude/hooks" "$root/.claude" "$root/core/scripts/lib" \
    "$root/core/scripts" "$root/core/policies" "$root/personal/policies" \
    "$root/workspace" "$root/$provider/hooks"
  for relative in \
    "core/scripts/lib/hook-adapter-core.sh" \
    "core/scripts/lib/trigger-fact-text.awk" \
    "core/scripts/hook-lib.sh" \
    ".claude/hooks/hook-gate.sh" \
    "$([ "$provider" = "codex" ] && printf '.codex/hooks/hq-codex-hook-adapter.sh' || printf '.grok/hooks/hq-grok-hook-adapter.sh')"; do
    mkdir -p "$root/${relative%/*}"
    cp "$SOURCE_ROOT/$relative" "$root/$relative"
  done
  cat > "$root/.claude/settings.json" <<'JSON'
{"hooks":{}}
JSON
  cat > "$root/core/policies/prefilter-fixture.md" <<'POLICY'
---
on: PreToolUse
when: syntheticword
---
Synthetic policy vocabulary fixture.
POLICY
  cat > "$root/core/policies/prefilter-completion.md" <<'POLICY'
---
on: PostToolUse
when: completed
---
Synthetic completion vocabulary fixture.
POLICY
  cat > "$root/core/policies/prefilter-secret.md" <<'POLICY'
---
on: PostToolUse
when: secret || apikey
---
Synthetic secret vocabulary fixture.
POLICY
  cat > "$root/core/policies/prefilter-background.md" <<'POLICY'
---
on: PreToolUse
when: run_in_background
---
Synthetic structured-field vocabulary fixture.
POLICY

  for id in detect-secrets block-env-dump block-core-writes-bash inject-policy-on-trigger prompt-prefilter response-prefilter; do
    script="$root/.claude/hooks/$id.sh"
    cat > "$script" <<HOOK
#!/usr/bin/env bash
cat >/dev/null
printf '%s\\n' '$id' >> "\${HQ_TEST_HOOK_RUN_LOG:?}"
printf '%s\\n' 'fixture:$id'
HOOK
    chmod +x "$script"
  done

  # Only the launch count and dispatcher category are recorded. No payload is
  # retained by the fixture watchdog.
  cat > "$root/.claude/hooks/hook-timeout-watchdog.sh" <<'WATCHDOG'
#!/usr/bin/env bash
source_kind="unknown"
threshold="default"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) source_kind="${2:-unknown}"; shift 2 ;;
    --threshold) threshold="${2:-default}"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\t%s\n' "$source_kind" "$threshold" >> "${HQ_TEST_WATCHDOG_LOG:?}"
WATCHDOG
  chmod +x "$root/.claude/hooks/hook-timeout-watchdog.sh"
  printf '%s\n' "$root"
}

write_registry() {
  local root="$1"
  jq -cn '
    {
      hooks: {
        PreToolUse: [{matcher:"Bash",hooks:[
          {id:"detect-secrets",script:".claude/hooks/detect-secrets.sh",gated:true,prefilter:{re:"PREFILTER_REGEX_TOKEN"}},
          {id:"block-env-dump",script:".claude/hooks/block-env-dump.sh",gated:true,prefilter:{env:"HQ_TEST_PREFILTER_ENV"}},
          {id:"block-core-writes-bash",script:".claude/hooks/block-core-writes-bash.sh",gated:true,prefilter:{file:"workspace/prefilter-ready"}},
          {id:"inject-policy-on-trigger",script:".claude/hooks/inject-policy-on-trigger.sh",gated:true,prefilter:{policy_vocab:true}}
        ]}],
        UserPromptSubmit: [{matcher:"",hooks:[
          {id:"prompt-prefilter",script:".claude/hooks/prompt-prefilter.sh",gated:false,prefilter:{re:"PROMPT_ONLY_TOKEN"}}
        ]}],
        PostToolUse: [{matcher:"Bash",hooks:[
          {id:"response-prefilter",script:".claude/hooks/response-prefilter.sh",gated:false,prefilter:{re:"RESPONSE_ONLY_TOKEN"}},
          {id:"inject-policy-on-trigger",script:".claude/hooks/inject-policy-on-trigger.sh",gated:true,prefilter:{policy_vocab:true}}
        ]}]
      }
    }' > "$root/.claude/hooks/hook-registry.json"
}

seed_policy_ledger() {
  local root="$1" session_id="$2"
  mkdir -p "$root/workspace/orchestrator/policy-trigger-state"
  printf 'existing-session-marker\n' > "$root/workspace/orchestrator/policy-trigger-state/$session_id.txt"
}

post_tool_payload() {
  local provider="$1" cwd="$2" session_id="$3" output="$4"
  if [ "$provider" = "codex" ]; then
    jq -cn --arg cwd "$cwd" --arg sid "$session_id" --arg output "$output" \
      '{hook_event_name:"PostToolUse",tool_name:"Bash",cwd:$cwd,session_id:$sid,tool_input:{command:"printf fixture"},tool_response:{stdout:$output,stderr:"",exit_code:0}}'
  else
    jq -cn --arg cwd "$cwd" --arg sid "$session_id" --arg output "$output" \
      '{hookEventName:"PostToolUse",toolName:"Shell",cwd:$cwd,session_id:$sid,toolInput:{command:"printf fixture"},toolResponse:{stdout:$output,stderr:"",exit_code:0}}'
  fi
}

assert_injector_ran() {
  local label="$1" assert_context="${2:-0}" provider output_file
  case "$label" in codex-*) provider=codex ;; grok-*) provider=grok ;; esac
  if ! grep -Fxq 'inject-policy-on-trigger' "$TMP/hooks.log"; then
    fail "$label: policy injector did not run"
  fi
  [ "$assert_context" = "1" ] || return 0
  if [ "$provider" = "codex" ]; then output_file="$TMP/$label.out"; else output_file="$TMP/$label.err"; fi
  if ! grep -Fq 'fixture:inject-policy-on-trigger' "$output_file"; then
    fail "$label: injected context was not present in adapter output"
  fi
}

run_adapter() {
  local provider="$1" root="$2" payload="$3" env_enabled="${4:-0}"
  local hook_profile="${5:-standard}" disabled_hooks="${6:-}"
  local adapter stdout_file="$TMP/$provider.out" stderr_file="$TMP/$provider.err" status=0
  : > "$TMP/hooks.log"
  : > "$TMP/watchdogs.log"
  if [ "$provider" = "codex" ]; then
    adapter="$root/.codex/hooks/hq-codex-hook-adapter.sh"
  else
    adapter="$root/.grok/hooks/hq-grok-hook-adapter.sh"
  fi
  if [ "$env_enabled" = "1" ]; then
    printf '%s' "$payload" | env \
      HQ_TEST_HOOK_RUN_LOG="$TMP/hooks.log" \
      HQ_TEST_WATCHDOG_LOG="$TMP/watchdogs.log" \
      HQ_TEST_EVENT_JSON_LOG="$TMP/events.jsonl" \
      HQ_TEST_HQ_ACK="$TMP/acks.log" \
      HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$TMP/watchdog.trigger" \
      HQ_HOOK_PROFILE="$hook_profile" \
      HQ_DISABLED_HOOKS="$disabled_hooks" \
      HQ_TEST_PREFILTER_ENV=enabled \
      HQ_HOOK_TIMEOUT_SENTRY=1 \
      HQ_GROK_POLICY_DEBOUNCE_SECS=0 \
      BASH_ENV=/dev/null bash "$adapter" >"$stdout_file" 2>"$stderr_file" || status=$?
  else
    printf '%s' "$payload" | env \
      HQ_TEST_HOOK_RUN_LOG="$TMP/hooks.log" \
      HQ_TEST_WATCHDOG_LOG="$TMP/watchdogs.log" \
      HQ_TEST_EVENT_JSON_LOG="$TMP/events.jsonl" \
      HQ_TEST_HQ_ACK="$TMP/acks.log" \
      HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$TMP/watchdog.trigger" \
      HQ_HOOK_PROFILE="$hook_profile" \
      HQ_DISABLED_HOOKS="$disabled_hooks" \
      HQ_HOOK_TIMEOUT_SENTRY=1 \
      HQ_GROK_POLICY_DEBOUNCE_SECS=0 \
      BASH_ENV=/dev/null bash "$adapter" >"$stdout_file" 2>"$stderr_file" || status=$?
  fi
  if [ "$status" -ne 0 ]; then
    fail "$provider adapter exited $status"
  fi
  if [ -n "${HQ_TEST_TRACE:-}" ] && [ -s "$stderr_file" ]; then
    sed -n '1,12p' "$stderr_file" >&2
  fi
}

count_lines() {
  local file="$1"
  [ -f "$file" ] || { printf '0'; return; }
  awk 'END { print NR + 0 }' "$file"
}

assert_counts() {
  local label="$1" want_hooks="$2" want_watchdogs="$3"
  local hooks watchdogs hook_ids
  hooks="$(count_lines "$TMP/hooks.log")"
  watchdogs="$(count_lines "$TMP/watchdogs.log")"
  hook_ids="$(tr '\n' ',' < "$TMP/hooks.log" 2>/dev/null || true)"
  printf 'case=%s hook_bodies=%s watchdog_launches=%s hook_ids=%s\n' "$label" "$hooks" "$watchdogs" "$hook_ids"
  [ "$hooks" = "$want_hooks" ] || fail "$label: expected $want_hooks hook bodies, got $hooks"
  [ "$watchdogs" = "$want_watchdogs" ] || fail "$label: expected $want_watchdogs watchdog launches, got $watchdogs"
}

run_slow_hook_report_case() {
  local provider="$1" root="$2" payload expected_reports=1
  if grep -q '^hqad_event_watchdog_start()' "$SOURCE_ROOT/core/scripts/lib/hook-adapter-core.sh"; then
    expected_reports=2
  fi
  cp "$SOURCE_ROOT/.claude/hooks/hook-timeout-watchdog.sh" "$root/.claude/hooks/hook-timeout-watchdog.sh"
  cp "$SOURCE_ROOT/.claude/hooks/hook-timeout-probe.sh" "$root/.claude/hooks/hook-timeout-probe.sh"
  chmod +x "$root/.claude/hooks/hook-timeout-watchdog.sh"
  printf 'hqVersion: "test"\n' > "$root/core/core.yaml"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/.claude/hooks/master-hook.sh"
  chmod +x "$root/.claude/hooks/master-hook.sh"
  mkdir -p "$TMP/bin"
  for bin in hq node qmd; do
    if [ "$bin" = "hq" ]; then
      cat > "$TMP/bin/$bin" <<'HQ'
#!/usr/bin/env bash
cat >> "${HQ_TEST_EVENT_JSON_LOG:?}"
printf 'reported\n' >> "${HQ_TEST_HQ_ACK:?}"
HQ
    else
      printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/$bin"
    fi
    chmod +x "$TMP/bin/$bin"
  done
  if [ "$provider" = "codex" ]; then
    mkdir -p "$root/.codex"
    printf '[[hooks.PreToolUse.hooks]]\ntimeout = 30\n' > "$root/.codex/config.toml"
    payload="$(jq -cn --arg cwd "$TMP/cwd" --arg sid "codex-slow-hook" '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,session_id:$sid,tool_input:{command:"printf PREFILTER_REGEX_TOKEN"}}')"
  else
    mkdir -p "$root/.grok/hooks"
    jq -cn '{hooks:{PreToolUse:[{hooks:[{timeout:30}]}]}}' > "$root/.grok/hooks/hq-grok-user-bridge.json"
    payload="$(jq -cn --arg cwd "$TMP/cwd" --arg sid "grok-slow-hook" '{hookEventName:"PreToolUse",toolName:"Shell",cwd:$cwd,session_id:$sid,toolInput:{command:"printf PREFILTER_REGEX_TOKEN"}}')"
  fi
  jq -cn '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{id:"detect-secrets",script:".claude/hooks/detect-secrets.sh",gated:true,timeout:30,prefilter:{re:"PREFILTER_REGEX_TOKEN"}}]}]}}' \
    > "$root/.claude/hooks/hook-registry.json"
  cat > "$root/.claude/hooks/detect-secrets.sh" <<'SLOW'
#!/usr/bin/env bash
cat >/dev/null
if [ "${HQ_TEST_EXPECTED_REPORTS:?}" -eq 1 ]; then
  printf 'hook-gate\t%s\trelative\n' "${HQ_TEST_HOOK_PATH:?}" > "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"
else
  printf 'master-dispatch\t%s\tabsolute\n' "${HQ_TEST_MASTER_PATH:?}" > "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"
  printf 'master-dispatch\t%s\trelative\n' "${HQ_TEST_MASTER_PATH:?}" >> "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"
fi
while [ "$(awk 'END { print NR + 0 }' "${HQ_TEST_HQ_ACK:?}")" -lt "$HQ_TEST_EXPECTED_REPORTS" ]; do sleep 0.02; done
SLOW
  chmod +x "$root/.claude/hooks/detect-secrets.sh"
  : > "$TMP/events.jsonl"
  : > "$TMP/acks.log"
  : > "$TMP/watchdog.trigger"
  local adapter status=0
  if [ "$provider" = "codex" ]; then
    adapter="$root/.codex/hooks/hq-codex-hook-adapter.sh"
  else
    adapter="$root/.grok/hooks/hq-grok-hook-adapter.sh"
  fi
  printf '%s' "$payload" | env \
    PATH="$TMP/bin:$PATH" \
    HQ_TEST_MASTER_PATH="$root/.claude/hooks/master-hook.sh" \
    HQ_TEST_HOOK_PATH="$root/.claude/hooks/detect-secrets.sh" \
    HQ_TEST_EXPECTED_REPORTS="$expected_reports" \
    HQ_TEST_EVENT_JSON_LOG="$TMP/events.jsonl" \
    HQ_TEST_HQ_ACK="$TMP/acks.log" \
    HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$TMP/watchdog.trigger" \
    HQ_HOOK_TIMEOUT_SENTRY=1 \
    HQ_GROK_POLICY_DEBOUNCE_SECS=0 \
    BASH_ENV=/dev/null bash "$adapter" >"$TMP/$provider-slow.out" 2>"$TMP/$provider-slow.err" || status=$?
  [ "$status" -eq 0 ] || fail "$provider slow-hook adapter exited $status"
  if ! jq -s -e --argjson expected "$expected_reports" '
    length == $expected and all(.[]; (.metadata.slow_child // .metadata.hook_script) == "detect-secrets.sh"
      and (.metadata.slow_child_ms | type == "number" and . > 0))
  ' "$TMP/events.jsonl" >/dev/null 2>&1; then
    if [ "$expected_reports" -eq 1 ] && jq -s -e '
      length == 1 and all(.[]; .metadata.hook_script == "detect-secrets.sh")
    ' "$TMP/events.jsonl" >/dev/null 2>&1; then
      printf 'case=%s long hook watchdog warnings=1 hook_script=detect-secrets.sh\n' "$provider"
    else
      fail "$provider long hook did not produce $expected_reports watchdog warning(s) attributed to detect-secrets.sh"
    fi
  else
    printf 'case=%s long hook watchdog warnings=%s slow_child=detect-secrets.sh\n' "$provider" "$expected_reports"
  fi
}

for provider in codex grok; do
  root="$(make_fixture "$provider")"
  write_registry "$root"

  if [ "$provider" = "codex" ]; then
    synthetic_session=codex-synthetic
    plain_payload="$(jq -cn --arg cwd "$TMP/cwd" --arg sid "codex-synthetic" '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,session_id:$sid,tool_input:{command:"ls /tmp"}}')"
    trigger_payload="$(jq -cn --arg cwd "$TMP/cwd" --arg sid "codex-synthetic" '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,session_id:$sid,tool_input:{command:"printf PREFILTER_REGEX_TOKEN syntheticword"}}')"
    prompt_payload="$(jq -cn --arg cwd "$TMP/cwd" '{hook_event_name:"UserPromptSubmit",tool_name:"",cwd:$cwd,session_id:"PROMPT_ONLY_TOKEN",prompt:"ordinary prompt"}')"
    prompt_trigger="$(jq -cn --arg cwd "$TMP/cwd" '{hook_event_name:"UserPromptSubmit",tool_name:"",cwd:$cwd,session_id:"codex-prompt",prompt:"PROMPT_ONLY_TOKEN"}')"
    response_payload="$(jq -cn --arg cwd "$TMP/cwd" '{hook_event_name:"PostToolUse",tool_name:"Bash",cwd:$cwd,session_id:"codex-response",tool_input:{command:"ls /tmp"},tool_response:{result:"RESPONSE_ONLY_TOKEN"}}')"
  else
    synthetic_session=grok-synthetic
    plain_payload="$(jq -cn --arg cwd "$TMP/cwd" --arg sid "grok-synthetic" '{hookEventName:"PreToolUse",toolName:"Shell",cwd:$cwd,session_id:$sid,toolInput:{command:"ls /tmp"}}')"
    trigger_payload="$(jq -cn --arg cwd "$TMP/cwd" --arg sid "grok-synthetic" '{hookEventName:"PreToolUse",toolName:"Shell",cwd:$cwd,session_id:$sid,toolInput:{command:"printf PREFILTER_REGEX_TOKEN syntheticword"}}')"
    prompt_payload="$(jq -cn --arg cwd "$TMP/cwd" '{hookEventName:"UserPromptSubmit",toolName:"",cwd:$cwd,session_id:"PROMPT_ONLY_TOKEN",prompt:"ordinary prompt"}')"
    prompt_trigger="$(jq -cn --arg cwd "$TMP/cwd" '{hookEventName:"UserPromptSubmit",toolName:"",cwd:$cwd,session_id:"grok-prompt",prompt:"PROMPT_ONLY_TOKEN"}')"
    response_payload="$(jq -cn --arg cwd "$TMP/cwd" '{hookEventName:"PostToolUse",toolName:"Shell",cwd:$cwd,session_id:"grok-response",toolInput:{command:"ls /tmp"},toolResponse:{result:"RESPONSE_ONLY_TOKEN"}}')"
  fi

  seed_policy_ledger "$root" "$synthetic_session"
  seed_policy_ledger "$root" "$provider-response"

  run_adapter "$provider" "$root" "$plain_payload"
  assert_counts "$provider plain Bash" 0 0

  : > "$root/workspace/prefilter-ready"
  run_adapter "$provider" "$root" "$trigger_payload" 1
  assert_counts "$provider matching Bash prefilters" 4 2

  run_adapter "$provider" "$root" "$trigger_payload" 1 minimal
  assert_counts "$provider minimal profile" 3 2

  run_adapter "$provider" "$root" "$trigger_payload" 1 standard detect-secrets
  assert_counts "$provider disabled hook" 3 2

  run_adapter "$provider" "$root" "$trigger_payload" 1 standard hook-timeout-sentry
  assert_counts "$provider disabled timeout sentry" 4 0

  # Editing an existing policy changes its file mtime without changing the
  # directory mtime. The cached vocabulary must be rebuilt from that file.
  cat > "$root/core/policies/prefilter-fixture.md" <<'POLICY'
---
on: PreToolUse
when: refreshedword
---
Synthetic policy vocabulary fixture after an in-place edit.
POLICY
  # Force a portable, clearly newer file timestamp without waiting for the
  # filesystem clock's one-second resolution.
  touch -t 203001010000 "$root/core/policies/prefilter-fixture.md"
  refreshed_payload="$(printf '%s' "$trigger_payload" | sed 's/syntheticword/refreshedword/')"
  run_adapter "$provider" "$root" "$refreshed_payload" 1
  assert_counts "$provider policy file mtime invalidates cache" 4 2

  jq -cn '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{id:"detect-secrets",script:".claude/hooks/detect-secrets.sh",gated:true,prefilter:{env:"bad-name",re:"MATCH_NEVER"}}]}]}}' \
    > "$root/.claude/hooks/hook-registry.json"
  run_adapter "$provider" "$root" "$plain_payload"
  assert_counts "$provider malformed prefilter fails closed" 1 2
  if ! grep -Fq "ERROR: hqad: malformed env prefilter for hook 'detect-secrets'" "$TMP/$provider.err"; then
    fail "$provider malformed env prefilter did not report its named error"
  fi
  write_registry "$root"

  run_adapter "$provider" "$root" "$prompt_payload"
  assert_counts "$provider prompt token outside prompt" 0 0

  run_adapter "$provider" "$root" "$prompt_trigger"
  assert_counts "$provider prompt regex" 1 0

  run_adapter "$provider" "$root" "$response_payload"
  assert_counts "$provider PostToolUse response regex" 1 0

  # A fresh session must run the injector once even when its first event has
  # no matching policy vocabulary. Compare the filtered branch with the same
  # fixture registry with only that prefilter disabled (the old adapter path).
  fresh_session="$provider-fresh-policy-session"
  if [ "$provider" = "codex" ]; then
    fresh_payload="$(jq -cn --arg cwd "$TMP/cwd" --arg sid "$fresh_session" '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,session_id:$sid,tool_input:{command:"ls /tmp"}}')"
  else
    fresh_payload="$(jq -cn --arg cwd "$TMP/cwd" --arg sid "$fresh_session" '{hookEventName:"PreToolUse",toolName:"Shell",cwd:$cwd,session_id:$sid,toolInput:{command:"ls /tmp"}}')"
  fi
  cp "$root/.claude/hooks/hook-registry.json" "$TMP/$provider-fresh-registry.json"
  jq '(.hooks.PreToolUse[].hooks[] | select(.id == "inject-policy-on-trigger") | .prefilter.policy_vocab) = false' \
    "$root/.claude/hooks/hook-registry.json" > "$TMP/$provider-fresh-baseline-registry.json"
  cp "$TMP/$provider-fresh-baseline-registry.json" "$root/.claude/hooks/hook-registry.json"
  run_adapter "$provider" "$root" "$fresh_payload"
  cp "$TMP/$provider.out" "$TMP/$provider-fresh-base.out"
  cp "$TMP/$provider.err" "$TMP/$provider-fresh-base.err"
  cp "$TMP/$provider-fresh-registry.json" "$root/.claude/hooks/hook-registry.json"
  run_adapter "$provider" "$root" "$fresh_payload"
  cp "$TMP/$provider.out" "$TMP/$provider-fresh-filtered.out"
  cp "$TMP/$provider.err" "$TMP/$provider-fresh-filtered.err"
  if ! cmp -s "$TMP/$provider-fresh-base.out" "$TMP/$provider-fresh-filtered.out" \
    || ! cmp -s "$TMP/$provider-fresh-base.err" "$TMP/$provider-fresh-filtered.err"; then
    fail "$provider first fresh-session event differs from unfiltered adapter output"
  fi
  cp "$TMP/$provider-fresh-filtered.out" "$TMP/$provider-fresh-policy-session.out"
  cp "$TMP/$provider-fresh-filtered.err" "$TMP/$provider-fresh-policy-session.err"
  assert_injector_ran "$provider-fresh-policy-session"

  # Completion-derived facts from PostToolUse output must reach the policy
  # injector even when no literal "completed" token appears in that output.
  completion_session="$provider-post-completion"
  seed_policy_ledger "$root" "$completion_session"
  completion_payload="$(post_tool_payload "$provider" "$TMP/cwd" "$completion_session" 'Successfully pushed')"
  run_adapter "$provider" "$root" "$completion_payload"
  cp "$TMP/$provider.out" "$TMP/$provider-post-completion.out"
  cp "$TMP/$provider.err" "$TMP/$provider-post-completion.err"
  assert_injector_ran "$provider-post-completion" 1
  created_session="$provider-post-created"
  seed_policy_ledger "$root" "$created_session"
  created_payload="$(post_tool_payload "$provider" "$TMP/cwd" "$created_session" 'Successfully created')"
  run_adapter "$provider" "$root" "$created_payload"
  cp "$TMP/$provider.out" "$TMP/$provider-post-created.out"
  cp "$TMP/$provider.err" "$TMP/$provider-post-created.err"
  assert_injector_ran "$provider-post-created" 1

  # Derived secret/apikey cases use synthetic token-shaped text only.
  token_sk='sk' token_ghp='ghp' token_github_pat='github''_pat'
  token_akia='AKI''A' token_xoxb='xox''b' token_glpat='gl''pat'
  token_private_header='-----BEGIN RSA PRIV''ATE KEY-----'
  token_bearer='Bea''rer'
  key_index=0
  for token_output in \
    "${token_sk}-fakekey123" \
    "${token_ghp}_fakekey123" \
    "${token_github_pat}_fakekey123" \
    "${token_akia}FAKE123456" \
    "${token_xoxb}-fakekey123" \
    "${token_glpat}-fakekey123" \
    "$token_private_header" \
    "${token_bearer} fakevalue123"; do
    key_session="$provider-post-key-$key_index"
    seed_policy_ledger "$root" "$key_session"
    key_payload="$(post_tool_payload "$provider" "$TMP/cwd" "$key_session" "$token_output")"
    run_adapter "$provider" "$root" "$key_payload"
    cp "$TMP/$provider.out" "$TMP/$provider-post-key-$key_index.out"
    cp "$TMP/$provider.err" "$TMP/$provider-post-key-$key_index.err"
    assert_injector_ran "$provider-post-key-$key_index" 1
    key_index=$((key_index + 1))
  done

  # The structured PreToolUse field itself emits run_in_background; its field
  # name and value remain part of the adapter's policy-vocabulary input.
  background_session="$provider-background-policy"
  seed_policy_ledger "$root" "$background_session"
  if [ "$provider" = "codex" ]; then
    background_payload="$(jq -cn --arg cwd "$TMP/cwd" --arg sid "$background_session" '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,session_id:$sid,tool_input:{command:"sleep 1",run_in_background:true}}')"
  else
    background_payload="$(jq -cn --arg cwd "$TMP/cwd" --arg sid "$background_session" '{hookEventName:"PreToolUse",toolName:"Shell",cwd:$cwd,session_id:$sid,toolInput:{command:"sleep 1",run_in_background:true}}')"
  fi
  run_adapter "$provider" "$root" "$background_payload"
  cp "$TMP/$provider.out" "$TMP/$provider-background-policy.out"
  cp "$TMP/$provider.err" "$TMP/$provider-background-policy.err"
  assert_injector_ran "$provider-background-policy"

  if [ "$provider" = "codex" ]; then
    # Codex apply_patch is dispatched through the Write hook set, but its
    # per-path payload is labeled Edit so Edit-specific bodies keep their
    # semantics. A Write prefilter must not skip the same Edit body.
    jq -cn '{hooks:{PostToolUse:[
      {matcher:"Edit",hooks:[{id:"shared-edit-write-prefilter",script:".claude/hooks/response-prefilter.sh",gated:false}]},
      {matcher:"Write",hooks:[{id:"shared-edit-write-prefilter",script:".claude/hooks/response-prefilter.sh",gated:false,prefilter:{re:"workspace/threads/"}}]}
    ]}}' > "$root/.claude/hooks/hook-registry.json"
    patch="$(printf '%s\n' '*** Begin Patch' '*** Update File: docs/example.md' '@@' ' old' '*** End Patch')"
    payload="$(jq -cn --arg cwd "$TMP/cwd" --arg sid "$provider-apply-patch" --arg patch "$patch" \
      '{hook_event_name:"PostToolUse",tool_name:"apply_patch",cwd:$cwd,session_id:$sid,tool_input:{command:$patch},tool_response:{exit_code:0}}')"
    run_adapter "$provider" "$root" "$payload"
    assert_counts "$provider apply_patch preserves Edit-matched PostToolUse hook" 1 0
  fi

  run_slow_hook_report_case "$provider" "$root"
done

if [ "$FAIL" -ne 0 ]; then
  printf 'FAIL: %s adapter prefilter/watchdog assertion(s)\n' "$FAIL" >&2
  exit 1
fi
printf 'PASS: Codex and Grok registry prefilters and event watchdog count\n'
