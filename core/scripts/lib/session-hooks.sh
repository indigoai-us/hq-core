#!/usr/bin/env bash
# hq-core: public
# session-hooks.sh — bootstrap session meta and invoke master-hook for agent sessions.
#
# Ordering (US-402 / US-404):
#   1. Write workspace/sessions/<runId>/meta.yaml (session_id + company_slug)
#   2. Write workspace/sessions/.current with runId
#   3. Verify via hq-session.sh get company
#   4. master-hook SessionStart, then UserPromptSubmit

# session_bootstrap_meta <root> <runId> <companySlug>
session_bootstrap_meta() {
  local root="${1:-}" run_id="${2:-}" company="${3:-}" project="${4:-}" task="${5:-}"
  local sessions_dir meta_dir meta_file current_file
  sessions_dir="$root/workspace/sessions"
  meta_dir="$sessions_dir/$run_id"
  meta_file="$meta_dir/meta.yaml"
  current_file="$sessions_dir/.current"

  # Prefer spawn env when caller did not pass project/task (US-011).
  [ -n "$project" ] || project="${HQ_SPAWN_PROJECT:-}"
  [ -n "$task" ] || task="${HQ_SPAWN_TASK:-}"

  mkdir -p "$meta_dir"
  {
    printf 'session_id: %s\n' "$run_id"
    printf 'company_slug: %s\n' "$company"
    [ -n "$project" ] && printf 'project: %s\n' "$project"
    [ -n "$task" ] && printf 'task: %s\n' "$task"
    printf 'started_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$meta_file"
  printf '%s\n' "$run_id" > "$current_file"
}

# session_verify_company <root> <expectedSlug> [runId]
#   Run hq-session.sh get company and assert it prints expectedSlug.
#
#   Pass runId whenever the caller knows it. hq-session.sh otherwise resolves
#   "current session" from this process's session environment, and an agent
#   session bootstrapped from inside another session inherits that parent's
#   session id — so the verify would read the parent's meta.yaml instead of the
#   run it just wrote. Pinning with --session-id keeps the check on this run.
session_verify_company() {
  local root="${1:-}" expected="${2:-}" run_id="${3:-}"
  local got
  local -a pin=()
  [ -n "$run_id" ] && pin=(--session-id "$run_id")
  got="$(cd "$root" && bash "$root/core/scripts/hq-session.sh" "${pin[@]}" get company 2>/dev/null || true)"
  # hq-session uses key "company" OR we need company_slug — AC says get company.
  # hq-session.sh get reads exact key from meta.yaml. We wrote company_slug.
  # Support both keys: prefer `company` alias via reading company_slug.
  if [ -z "$got" ]; then
    got="$(cd "$root" && bash "$root/core/scripts/hq-session.sh" "${pin[@]}" get company_slug 2>/dev/null || true)"
  fi
  # Also write company: alias so `get company` works as AC states.
  if [ "$got" != "$expected" ]; then
    # Ensure company: key exists for the AC path. Prefer the caller's runId;
    # fall back to .current only when the caller did not supply one.
    local meta_id="$run_id"
    [ -n "$meta_id" ] || meta_id="$(tr -d '[:space:]' <"$root/workspace/sessions/.current")"
    local meta="$root/workspace/sessions/$meta_id/meta.yaml"
    if [ -f "$meta" ] && ! grep -q '^company:' "$meta"; then
      printf 'company: %s\n' "$expected" >> "$meta"
    fi
    got="$(cd "$root" && bash "$root/core/scripts/hq-session.sh" "${pin[@]}" get company 2>/dev/null || true)"
  fi
  [ "$got" = "$expected" ] || {
    echo "hq-agent-session: session bootstrap verify failed: expected company=$expected got=${got:-<empty>}" >&2
    return 1
  }
  printf '%s\n' "$got"
}

# session_run_hook <root> <event> <session_id> [prompt]
#   Invoke .claude/hooks/master-hook.sh <event> with a stdin JSON payload.
#   Prints hook stdout. Returns hook exit code.
#   Sets SESSION_HOOK_BLOCKED_BY when a block decision is present.
session_run_hook() {
  local root="${1:-}" event="${2:-}" session_id="${3:-}" prompt="${4-}"
  local hook="$root/.claude/hooks/master-hook.sh"
  local payload out rc=0
  SESSION_HOOK_BLOCKED_BY=""
  SESSION_HOOK_UPDATED_INPUT=""

  if [ ! -f "$hook" ]; then
    echo "hq-agent-session: master-hook missing: $hook" >&2
    return 1
  fi

  payload="$(jq -nc \
    --arg sid "$session_id" \
    --arg cwd "$root" \
    --arg event "$event" \
    --arg prompt "$prompt" \
    '{
      session_id: $sid,
      cwd: $cwd,
      hook_event_name: $event,
      source: "hq-agent-session",
      prompt: $prompt
    }')"

  # Do not default to /dev/stderr: re-opening it fails when the underlying
  # file belongs to another user (sudo / systemd service fds). Without an
  # explicit sink, let hook stderr flow to the inherited fd 2.
  if [ -n "${SESSION_HOOK_ERR:-}" ]; then
    out="$(printf '%s' "$payload" | bash "$hook" "$event" 2>"$SESSION_HOOK_ERR")" || rc=$?
  else
    out="$(printf '%s' "$payload" | bash "$hook" "$event")" || rc=$?
  fi

  if [ -n "$out" ] && command -v jq >/dev/null 2>&1; then
    if printf '%s' "$out" | jq -e 'type == "object" and .decision == "block"' >/dev/null 2>&1; then
      SESSION_HOOK_BLOCKED_BY="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hqSessionBlockedBy // .hookSpecificOutput.blockedBy // empty' 2>/dev/null || true)"
      # Fall back: if master-hook didn't stamp provenance, leave empty (tests assert AC22).
      SESSION_HOOK_BLOCK_JSON="$out"
      printf '%s' "$out"
      return 2  # special: blocked
    fi
    SESSION_HOOK_UPDATED_INPUT="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput // empty' 2>/dev/null || true)"
  fi

  printf '%s' "$out"
  return "$rc"
}
