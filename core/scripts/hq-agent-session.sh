#!/usr/bin/env bash
# hq-core: public
# hq-agent-session.sh — on-box HQ Agent Session entrypoint (contract owner).
#
# Reads one JSON request from stdin (agent-session-request.schema.json),
# validates, admits contract version, resolves root/company fail-closed,
# assembles system.txt / user.txt, bootstraps session hooks, dispatches the
# provider adapter, and emits one JSON response on stdout
# (agent-session-response.schema.json) on EVERY exit path.
#
# Exit codes:
#   0  success
#   2  invalid request (schema)
#   3  HQ root rejected (symlink / invalid)
#   4  unsupported provider
#   5  contract version too new (CONTRACT_VERSION_TOO_NEW)
#   6  company authorization failure
#   1  other runtime failure
#
# Usage:
#   core/scripts/hq-agent-session.sh < request.json > response.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck source=lib/session-authz.sh
. "$LIB_DIR/session-authz.sh"
# shellcheck source=lib/session-version.sh
. "$LIB_DIR/session-version.sh"
# shellcheck source=lib/session-system-prompt.sh
. "$LIB_DIR/session-system-prompt.sh"
# shellcheck source=lib/session-brief-constants.sh
. "$LIB_DIR/session-brief-constants.sh"
# shellcheck source=lib/session-policy-inject.sh
. "$LIB_DIR/session-policy-inject.sh"
# shellcheck source=lib/session-skill-catalog.sh
. "$LIB_DIR/session-skill-catalog.sh"
# shellcheck source=lib/session-skill-dispatch.sh
. "$LIB_DIR/session-skill-dispatch.sh"
# shellcheck source=lib/session-hooks.sh
. "$LIB_DIR/session-hooks.sh"
# shellcheck source=lib/session-resume.sh
. "$LIB_DIR/session-resume.sh"
# shellcheck source=lib/session-durable-writes.sh
. "$LIB_DIR/session-durable-writes.sh"
# shellcheck source=lib/session-timing.sh
. "$LIB_DIR/session-timing.sh"
# shellcheck source=lib/provider-adapter.sh
. "$LIB_DIR/provider-adapter.sh"

# --- response emission (every path) ------------------------------------------

SESSION_EXIT_CODE=1
SESSION_DISPOSITION="error"
SESSION_TEXT=""
SESSION_ARTIFACTS_JSON='[]'
SESSION_RUN_DIR=""
SESSION_SYSTEM_PROMPT_BYTES=""
SESSION_SYSTEM_PROMPT_MODE=""
SESSION_CONTRACT_VERSION=1
SESSION_CONTRACT_DOWNGRADE=0
SESSION_BLOCKED_BY=""
SESSION_PROVIDER_TEXT=""
SESSION_HQ_ROOT=""
SESSION_COMPANY_DIR=""
SESSION_REQ_JSON=""
SESSION_RUN_ID=""
# US-406 policy / skill envelope diagnostics
SESSION_POLICY_OVERRIDES_JSON='[]'
SESSION_POLICIES_TRUNCATED=0
SESSION_POLICIES_INJECTED=0
SESSION_SKILLS_AVAILABLE=0
SESSION_SKILL_BODY_TRUNCATED=0
SESSION_SKILL_CLARIFY=0
SESSION_SKILL_SUGGESTIONS=""
SESSION_SKILL_DISPATCHED=0
# US-408 resume + durable writes
SESSION_RESUME_FALLBACK=0
SESSION_RESUME_SUPPORTED=""
SESSION_NON_DURABLE_JSON='[]'
SESSION_PROJECT_DIR=""
SESSION_RUN_START_EPOCH=""
# US-411 assembly timing
SESSION_ASSEMBLY_MS_JSON="{}"
SESSION_ASSEMBLY_BUDGET_EXCEEDED=0

# emit_response then exit with SESSION_EXIT_CODE
emit_and_exit() {
  local resp opt_json
  local bytes_json="null"
  local cv_json="1"
  local downgrade_json="false"
  local trunc_json="0"
  local skills_json="0"
  local skill_trunc_json="false"
  local overrides_json='[]'
  local resume_fallback_json="false"
  local resume_supported_json="null"
  local non_durable_json='[]'
  local assembly_ms_json='{}'
  local assembly_budget_json="false"

  case "${SESSION_SYSTEM_PROMPT_BYTES:-}" in
    ''|*[!0-9]*) bytes_json="null" ;;
    *) bytes_json="${SESSION_SYSTEM_PROMPT_BYTES}" ;;
  esac
  case "${SESSION_CONTRACT_VERSION:-}" in
    ''|*[!0-9]*) cv_json="1" ;;
    *) cv_json="${SESSION_CONTRACT_VERSION}" ;;
  esac
  if [ "${SESSION_CONTRACT_DOWNGRADE:-0}" = "1" ]; then
    downgrade_json="true"
  fi
  case "${SESSION_POLICIES_TRUNCATED:-0}" in
    ''|*[!0-9]*) trunc_json="0" ;;
    *) trunc_json="${SESSION_POLICIES_TRUNCATED}" ;;
  esac
  case "${SESSION_SKILLS_AVAILABLE:-0}" in
    ''|*[!0-9]*) skills_json="0" ;;
    *) skills_json="${SESSION_SKILLS_AVAILABLE}" ;;
  esac
  if [ "${SESSION_SKILL_BODY_TRUNCATED:-0}" = "1" ]; then
    skill_trunc_json="true"
  fi
  overrides_json="${SESSION_POLICY_OVERRIDES_JSON:-[]}"
  if ! printf '%s' "$overrides_json" | jq -e . >/dev/null 2>&1; then
    overrides_json='[]'
  fi
  if [ "${SESSION_RESUME_FALLBACK:-0}" = "1" ]; then
    resume_fallback_json="true"
  fi
  case "${SESSION_RESUME_SUPPORTED:-}" in
    true|false) resume_supported_json="${SESSION_RESUME_SUPPORTED}" ;;
    *) resume_supported_json="null" ;;
  esac
  non_durable_json="${SESSION_NON_DURABLE_JSON:-[]}"
  if ! printf '%s' "$non_durable_json" | jq -e . >/dev/null 2>&1; then
    non_durable_json='[]'
  fi
  # NOTE: never use ${SESSION_ASSEMBLY_MS_JSON:-{}} — bash parses the closing
  # } of {} as end of parameter expansion and appends a stray brace.
  assembly_ms_json="${SESSION_ASSEMBLY_MS_JSON:-}"
  if [ -z "$assembly_ms_json" ]; then
    assembly_ms_json='{}'
  fi
  if ! printf '%s' "$assembly_ms_json" | jq -e . >/dev/null 2>&1; then
    assembly_ms_json='{}'
  fi
  if [ "${SESSION_ASSEMBLY_BUDGET_EXCEEDED:-0}" = "1" ]; then
    assembly_budget_json="true"
  fi

  # Build optional fields (null bytes → omit systemPromptBytes)
  opt_json="$(jq -nc \
    --arg runDir "${SESSION_RUN_DIR:-}" \
    --argjson bytes "$bytes_json" \
    --arg mode "${SESSION_SYSTEM_PROMPT_MODE:-}" \
    --argjson downgrade "$downgrade_json" \
    --arg blockedBy "${SESSION_BLOCKED_BY:-}" \
    --argjson policiesTruncated "$trunc_json" \
    --argjson policyOverrides "$overrides_json" \
    --argjson skillsAvailable "$skills_json" \
    --argjson skillBodyTruncated "$skill_trunc_json" \
    --argjson resumeFallback "$resume_fallback_json" \
    --argjson resumeSupported "$resume_supported_json" \
    --argjson nonDurableWrites "$non_durable_json" \
    --arg projectDir "${SESSION_PROJECT_DIR:-}" \
    --argjson assemblyMs "$assembly_ms_json" \
    --argjson assemblyBudgetExceeded "$assembly_budget_json" \
    '
      {}
      | if $runDir != "" then .runDir = $runDir else . end
      | if $bytes != null then .systemPromptBytes = $bytes else . end
      | if $mode != "" then .systemPromptMode = $mode else . end
      | if $downgrade == true then .contractVersionDowngrade = true else . end
      | if $blockedBy != "" then .blockedBy = $blockedBy else . end
      | .policiesTruncated = $policiesTruncated
      | if ($policyOverrides | length) > 0 then .policyOverrides = $policyOverrides else . end
      | .skillsAvailable = $skillsAvailable
      | if $skillBodyTruncated == true then .skillBodyTruncated = true else . end
      | if $resumeFallback == true then .resumeFallback = true else . end
      | if $resumeSupported != null then .resumeSupported = $resumeSupported else . end
      | if ($nonDurableWrites | length) > 0 then .nonDurableWrites = $nonDurableWrites else . end
      | if $projectDir != "" then .projectDir = $projectDir else . end
      | if ($assemblyMs | type) == "object" and ($assemblyMs | length) > 0 then .assemblyMs = $assemblyMs else . end
      | if $assemblyBudgetExceeded == true then .assemblyBudgetExceeded = true else . end
    ')" || opt_json="{}"

  # NOTE: do not use ${opt_json:-{}} — bash parses the closing } of {} as end of
  # parameter expansion and appends a stray brace to a non-empty value.
  if [ -z "${opt_json:-}" ]; then
    opt_json='{}'
  fi
  if [ -z "${SESSION_ARTIFACTS_JSON:-}" ]; then
    SESSION_ARTIFACTS_JSON='[]'
  fi
  resp="$(jq -nc \
    --argjson cv "$cv_json" \
    --arg disposition "${SESSION_DISPOSITION:-error}" \
    --arg text "${SESSION_TEXT:-}" \
    --argjson artifacts "$SESSION_ARTIFACTS_JSON" \
    --argjson extra "$opt_json" \
    '{
      contractVersion: $cv,
      disposition: $disposition,
      text: $text,
      artifacts: $artifacts
    } + $extra')" || resp='{"contractVersion":1,"disposition":"error","text":"hq-agent-session: envelope encode failed","artifacts":[]}'

  printf '%s\n' "$resp"
  exit "${SESSION_EXIT_CODE:-1}"
}

# trap: always emit a valid envelope even on unexpected failure
_cleanup_trap() {
  local ec=$?
  # If we already emitted via emit_and_exit, don't double-print.
  [ "${SESSION_EMITTED:-0}" = "1" ] && exit "$ec"
  if [ -z "${SESSION_TEXT:-}" ]; then
    SESSION_TEXT="hq-agent-session: unexpected failure (exit $ec)"
  fi
  SESSION_DISPOSITION="${SESSION_DISPOSITION:-error}"
  SESSION_EXIT_CODE="${SESSION_EXIT_CODE:-$ec}"
  [ "$SESSION_EXIT_CODE" -eq 0 ] && SESSION_EXIT_CODE=1
  SESSION_EMITTED=1
  emit_and_exit
}
# Only use EXIT trap for unexpected paths; emit_and_exit sets SESSION_EMITTED.
trap '_cleanup_trap' EXIT

fail() {
  # fail <exit_code> <disposition> <text>
  SESSION_EXIT_CODE="${1:-1}"
  SESSION_DISPOSITION="${2:-error}"
  SESSION_TEXT="${3:-hq-agent-session: error}"
  SESSION_EMITTED=1
  emit_and_exit
}

# --- schema validation (request) ---------------------------------------------

validate_request_json() {
  local file="${1:-}"
  # Hand-rolled validation matching agent-session-request.schema.json so the
  # entrypoint has no runtime dependency on ajv/jsonschema.
  if ! jq -e . "$file" >/dev/null 2>&1; then
    return 1
  fi
  jq -e '
    def is_int: type == "number" and floor == .;
    (type == "object")
    and has("contractVersion") and has("agentUid") and has("companySlug")
    and has("channel") and has("convKey") and has("messageText")
    and has("provider") and has("sender")
    and (.contractVersion | is_int)
    and (.agentUid | type == "string" and length >= 1)
    and (.companySlug | type == "string" and length >= 1)
    and (.channel | type == "string"
        and (["slack","telegram","email","dm","job","task"] | index(.)) != null)
    and (.convKey | type == "string" and length >= 1)
    and (.messageText | type == "string")
    and (.provider | type == "string"
        and (["claude","codex","grok"] | index(.)) != null)
    and (.sender | type == "object" and (.verified | type == "boolean"))
    and (
      (keys - [
        "contractVersion","agentUid","companySlug","channel","convKey",
        "messageText","provider","sender","rehydration",
        "rehydrationTurnCount","project"
      ] | length) == 0
    )
    and (
      (has("rehydration") | not)
      or (.rehydration == null)
      or (.rehydration | type == "string")
    )
    and (
      (has("rehydrationTurnCount") | not)
      or (.rehydrationTurnCount | is_int and . >= 0)
    )
    and (
      (has("project") | not)
      or (.project | type == "string" and test("^[a-z0-9-]{1,64}$"))
    )
  ' "$file" >/dev/null 2>&1
}

# Post-turn: collect artifacts + residual workspace writes into SESSION_* fields
session_finalize_writes() {
  local root="${1:-}" project_dir="${2:-}" start="${3:-}"
  [ -n "$root" ] || return 0
  case "$start" in ''|*[!0-9]*) start="$(date +%s 2>/dev/null || echo 0)" ;; esac
  SESSION_NON_DURABLE_JSON="$(session_collect_non_durable_writes "$root" "$start" 2>/dev/null || echo '[]')"
  if ! printf '%s' "${SESSION_NON_DURABLE_JSON}" | jq -e . >/dev/null 2>&1; then
    SESSION_NON_DURABLE_JSON='[]'
  fi
  if [ -n "$project_dir" ]; then
    SESSION_ARTIFACTS_JSON="$(session_collect_project_artifacts "$root" "$project_dir" "$start" 2>/dev/null || echo '[]')"
    if ! printf '%s' "${SESSION_ARTIFACTS_JSON}" | jq -e . >/dev/null 2>&1; then
      SESSION_ARTIFACTS_JSON='[]'
    fi
  fi
}

# --- main --------------------------------------------------------------------

main() {
  command -v jq >/dev/null 2>&1 || fail 1 error "hq-agent-session: jq is required"

  local req_file
  req_file="$(mktemp)"
  cat > "$req_file"
  SESSION_REQ_JSON="$req_file"

  if ! validate_request_json "$req_file"; then
    echo "hq-agent-session: invalid request" >&2
    fail 2 error "hq-agent-session: invalid request"
  fi

  # Extract fields
  local contract_version agent_uid company_slug channel conv_key message_text provider
  local project_field="" sender_verified="false" rehydration_block=""
  contract_version="$(jq -r '.contractVersion' "$req_file")"
  agent_uid="$(jq -r '.agentUid' "$req_file")"
  company_slug="$(jq -r '.companySlug' "$req_file")"
  channel="$(jq -r '.channel' "$req_file")"
  conv_key="$(jq -r '.convKey' "$req_file")"
  message_text="$(jq -r '.messageText' "$req_file")"
  provider="$(jq -r '.provider' "$req_file")"
  project_field="$(jq -r '.project // empty' "$req_file")"
  if [ "$(jq -r '.sender.verified' "$req_file")" = "true" ]; then
    sender_verified="true"
  else
    sender_verified="false"
  fi
  rehydration_block="$(jq -r '.rehydration // empty' "$req_file")"
  SESSION_CONTRACT_VERSION="$contract_version"

  # US-411: assembly phase timing (default budget 20000ms)
  session_timing_init

  # Resolve HQ root (exit 3). Capture rc before `if !` inverts status.
  local root rc=0
  root="$(session_resolve_root)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "$rc" error "hq-agent-session: HQ root resolution failed"
  fi
  SESSION_HQ_ROOT="$root"

  # Contract version admission (exit 5) — before hooks/provider
  rc=0
  session_admit_contract_version "$root" "$contract_version" || rc=$?
  if [ "$rc" -ne 0 ]; then
    local supported="${SESSION_SUPPORTED_VERSION:-1}"
    fail 5 error "CONTRACT_VERSION_TOO_NEW: request contractVersion=$contract_version exceeds supported=$supported on this box"
  fi
  # Response contractVersion is the request's (or supported — schema says integer; use request)
  SESSION_CONTRACT_VERSION="$contract_version"

  # Company resolution (exit 6) — exact slug only; sender.verified ignored for scope
  local company_dir
  rc=0
  company_dir="$(session_resolve_company_dir "$root" "$company_slug")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail 6 error "hq-agent-session: company refused: $company_slug"
  fi
  SESSION_COMPANY_DIR="$company_dir"

  # US-408 / US-407: resolve project dir (fail closed on invalid slug)
  local project_dir
  rc=0
  project_dir="$(session_resolve_project_dir "$root" "$company_slug" "$project_field" "$conv_key")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail 1 error "hq-agent-session: project resolution failed for company=$company_slug"
  fi
  SESSION_PROJECT_DIR="$project_dir"
  export HQ_SESSION_PROJECT_DIR="$project_dir"

  # runId + runDir
  local run_id run_dir
  run_id="run-$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ -n "$run_id" ] || run_id="run-$$-$RANDOM"
  SESSION_RUN_ID="$run_id"
  run_dir="${HOME}/.hq/agent-session/${run_id}"
  mkdir -p "$run_dir"
  chmod 700 "$run_dir"
  SESSION_RUN_DIR="$run_dir"

  # Epoch for residual-write detection (before any turn-side effects)
  SESSION_RUN_START_EPOCH="$(date +%s 2>/dev/null || echo 0)"
  # Subtract 1s so files written in the same second as start are still "newer"
  # on filesystems with 1s mtime resolution (common on macOS).
  case "${SESSION_RUN_START_EPOCH}" in
    ''|*[!0-9]*) SESSION_RUN_START_EPOCH=0 ;;
    *) SESSION_RUN_START_EPOCH=$((SESSION_RUN_START_EPOCH - 1)) ;;
  esac

  # Export the three watcher-parity variables
  export HQ_ROOT="$root"
  export HQ_AGENT_COMPANY_DIR="$company_dir"
  export CLAUDE_PROJECT_DIR="$root"

  # Persist request for adapters/hooks
  cp "$req_file" "$run_dir/request.json"

  # ── US-411 phases: system-prompt ──────────────────────────────────────────
  session_timing_begin system-prompt
  local bytes
  bytes="$(session_assemble_system_prompt "$root" "$company_slug" "$channel" "$run_dir/system.txt")"
  SESSION_SYSTEM_PROMPT_BYTES="$bytes"
  # user.txt: untrusted channel payload only (contract destination rule)
  session_write_user_txt "$message_text" "$run_dir/user.txt"
  # US-412: all brief constants (preambles, posture, voice, formatting) → system.txt
  session_append_brief_posture "$root" "$channel" "$sender_verified" "$run_dir/system.txt" || true
  session_timing_end

  # ── policy ────────────────────────────────────────────────────────────────
  session_timing_begin policy
  session_policy_inject "$root" "$company_slug" "$run_dir" "$message_text" >/dev/null || true
  session_timing_end

  # ── skill-catalog ─────────────────────────────────────────────────────────
  session_timing_begin skill-catalog
  session_skill_catalog_build "$root" "$company_slug" >/dev/null || true
  session_skill_catalog_append "$run_dir" || true
  session_skill_dispatch "$run_dir" "$message_text" || true
  session_timing_end

  # ── worker-catalog (placeholder until worker materialization lands) ───────
  session_timing_begin worker-catalog
  : # no-op: worker catalog not yet assembled in-process
  session_timing_end

  # ── rehydrate ─────────────────────────────────────────────────────────────
  session_timing_begin rehydrate
  session_append_rehydration "$run_dir/user.txt" "$rehydration_block" || true
  session_timing_end

  # US-408: durable-write guidance after skill-catalog (preserves section order)
  session_append_durable_guidance "$run_dir/system.txt" || true

  # Refresh system prompt byte count after all system.txt appends
  if [ -f "$run_dir/system.txt" ]; then
    SESSION_SYSTEM_PROMPT_BYTES="$(wc -c < "$run_dir/system.txt" | tr -d '[:space:]')"
  fi

  # Unresolved /skill → clarify disposition (no provider call)
  if [ "${SESSION_SKILL_CLARIFY:-0}" = "1" ]; then
    local suggestions="${SESSION_SKILL_SUGGESTIONS:-}"
    local clarify_text
    if [ -n "$suggestions" ]; then
      clarify_text="Unknown skill /${SESSION_SKILL_NAME:-}. Did you mean: ${suggestions}?"
    else
      clarify_text="Unknown skill /${SESSION_SKILL_NAME:-}. No catalog matches."
    fi
    session_timing_finalize
    session_finalize_writes "$root" "$project_dir" "$SESSION_RUN_START_EPOCH"
    SESSION_DISPOSITION="clarify"
    SESSION_TEXT="$clarify_text"
    SESSION_EXIT_CODE=0
    SESSION_EMITTED=1
    emit_and_exit
  fi

  # Session meta bootstrap + verify before hooks
  session_bootstrap_meta "$root" "$run_id" "$company_slug"
  # Ensure `hq-session.sh get company` works (AC18): write company: key
  local meta_file="$root/workspace/sessions/$run_id/meta.yaml"
  if [ -f "$meta_file" ] && ! grep -q '^company:' "$meta_file"; then
    printf 'company: %s\n' "$company_slug" >> "$meta_file"
  fi
  session_verify_company "$root" "$company_slug" >/dev/null

  # ── hooks ─────────────────────────────────────────────────────────────────
  session_timing_begin hooks
  local hook_rc=0
  SESSION_HOOK_BLOCKED_BY=""
  set +e
  session_run_hook "$root" "SessionStart" "$run_id" "" >/dev/null
  hook_rc=$?
  set -e
  if [ "$hook_rc" -eq 2 ]; then
    SESSION_BLOCKED_BY="${SESSION_HOOK_BLOCKED_BY:-SessionStart}"
    session_timing_end
    session_timing_finalize
    session_finalize_writes "$root" "$project_dir" "$SESSION_RUN_START_EPOCH"
    fail 0 no_reply "blocked by hook: ${SESSION_BLOCKED_BY}"
  elif [ "$hook_rc" -ne 0 ]; then
    echo "hq-agent-session: SessionStart hook exit $hook_rc (continuing)" >&2
  fi

  set +e
  session_run_hook "$root" "UserPromptSubmit" "$run_id" "$message_text" >/dev/null
  hook_rc=$?
  set -e
  if [ "$hook_rc" -eq 2 ]; then
    SESSION_BLOCKED_BY="${SESSION_HOOK_BLOCKED_BY:-UserPromptSubmit}"
    session_timing_end
    session_timing_finalize
    session_finalize_writes "$root" "$project_dir" "$SESSION_RUN_START_EPOCH"
    fail 0 no_reply "blocked by hook: ${SESSION_BLOCKED_BY}"
  elif [ "$hook_rc" -ne 0 ]; then
    echo "hq-agent-session: UserPromptSubmit hook exit $hook_rc (continuing)" >&2
  fi
  # updatedInput replaces user.txt
  if [ -n "${SESSION_HOOK_UPDATED_INPUT:-}" ]; then
    printf '%s' "$SESSION_HOOK_UPDATED_INPUT" > "$run_dir/user.txt"
  fi
  session_timing_end

  # Finalize assembly timing before provider dispatch (report-and-continue)
  session_timing_finalize

  # US-408: resume support flag (matrix-aligned) even on skip-provider path
  SESSION_RESUME_SUPPORTED="$(session_resume_supported "$provider")"

  # Provider dispatch (skip when requested by tests)
  if [ "${HQ_AGENT_SESSION_SKIP_PROVIDER:-0}" = "1" ]; then
    SESSION_SYSTEM_PROMPT_MODE="${SESSION_SYSTEM_PROMPT_MODE:-}"
    SESSION_PROVIDER_TEXT="(provider skipped)"
    session_finalize_writes "$root" "$project_dir" "$SESSION_RUN_START_EPOCH"
    SESSION_DISPOSITION="reply"
    SESSION_TEXT="$SESSION_PROVIDER_TEXT"
    SESSION_EXIT_CODE=0
    SESSION_EMITTED=1
    emit_and_exit
  fi

  # US-408: load prior session id for this convKey+provider (if any)
  local resume_id=""
  resume_id="$(session_resume_read "$conv_key" "$provider" 2>/dev/null || true)"
  export HQ_AGENT_SESSION_RESUME_ID="${resume_id:-}"

  # Claude: plumb transcript path capture file for session-id harvest
  local transcript_path_file=""
  if [ "$provider" = "claude" ]; then
    transcript_path_file="$run_dir/claude-transcript.path"
    : > "$transcript_path_file"
    export HQ_AGENT_CLAUDE_TRANSCRIPT_PATH_FILE="$transcript_path_file"
  fi

  local prov_out prov_rc=0
  set +e
  prov_out="$(session_provider_dispatch "$provider" "$run_dir" "$company_dir" 2>"$run_dir/provider.stderr")"
  prov_rc=$?
  set -e

  if [ "$prov_rc" -eq 4 ]; then
    session_finalize_writes "$root" "$project_dir" "$SESSION_RUN_START_EPOCH"
    fail 4 error "hq-agent-session: unsupported provider: $provider"
  fi

  # Resume rejected → fresh session same turn + resumeFallback true
  if [ "$prov_rc" -ne 0 ] && [ -n "${resume_id:-}" ] && [ "${HQ_AGENT_SESSION_RENDER_ONLY:-0}" != "1" ]; then
    echo "hq-agent-session: resume rejected (exit $prov_rc); falling back to fresh session" >&2
    SESSION_RESUME_FALLBACK=1
    export HQ_AGENT_SESSION_RESUME_ID=""
    # Clear failed resume record so we do not thrash
    session_resume_delete "$(session_resume_path "$conv_key" 2>/dev/null || true)" 2>/dev/null || true
    if [ -n "$transcript_path_file" ]; then
      : > "$transcript_path_file"
    fi
    set +e
    prov_out="$(session_provider_dispatch "$provider" "$run_dir" "$company_dir" 2>"$run_dir/provider.stderr")"
    prov_rc=$?
    set -e
  fi

  SESSION_SYSTEM_PROMPT_MODE="${SESSION_SYSTEM_PROMPT_MODE:-}"

  if [ "$prov_rc" -ne 0 ] && [ "${HQ_AGENT_SESSION_RENDER_ONLY:-0}" != "1" ]; then
    session_finalize_writes "$root" "$project_dir" "$SESSION_RUN_START_EPOCH"
    SESSION_TEXT="hq-agent-session: provider failed (exit $prov_rc)"
    [ -s "$run_dir/provider.stderr" ] && SESSION_TEXT="$SESSION_TEXT: $(head -c 500 "$run_dir/provider.stderr" | tr '\n' ' ')"
    fail 1 error "$SESSION_TEXT"
  fi

  # Capture + persist session id for next turn (best-effort; never fail the turn)
  local new_sid=""
  if [ "$provider" = "claude" ] && [ -n "$transcript_path_file" ]; then
    new_sid="$(session_resume_capture_claude_session_id "$transcript_path_file" 2>/dev/null || true)"
  elif [ -n "${HQ_AGENT_SESSION_CAPTURED_ID:-}" ]; then
    # Test / adapter hook for non-claude providers
    new_sid="${HQ_AGENT_SESSION_CAPTURED_ID}"
  fi
  if [ -n "$new_sid" ]; then
    session_resume_write "$conv_key" "$provider" "$new_sid" 2>/dev/null || true
  fi

  session_finalize_writes "$root" "$project_dir" "$SESSION_RUN_START_EPOCH"

  SESSION_DISPOSITION="reply"
  SESSION_TEXT="${prov_out:-}"
  SESSION_EXIT_CODE=0
  SESSION_EMITTED=1
  emit_and_exit
}

main "$@"
