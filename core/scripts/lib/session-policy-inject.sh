#!/usr/bin/env bash
# hq-core: public
# session-policy-inject.sh — materialize triggered policies into system.txt.
#
# Invokes .claude/hooks/inject-policy-on-trigger.sh with HQ_POLICY_EMIT=tsv and
# HQ_POLICY_COMPANY=<companySlug>, parses machine-readable records, applies
# hard-before-soft ordering and configurable budgets, appends rule text under
# <!-- hq-section: policies -->, and exports envelope diagnostics:
#   SESSION_POLICY_OVERRIDES_JSON  — policyOverrides[] (id + both paths)
#   SESSION_POLICIES_TRUNCATED     — integer count of dropped policies
#   SESSION_POLICIES_INJECTED      — integer count of injected policies
#
# Budgets (US-406):
#   HQ_SESSION_POLICY_MAX_POLICIES  default 32
#   HQ_SESSION_POLICY_MAX_BYTES     default 131072
#
# Truncation is never silent and never exits non-zero.

# session_policy_inject <root> <companySlug> <runDir> [messageText]
#   Appends policy rules into runDir/system.txt under the policies delimiter.
#   Prints injected count on stdout. Always returns 0.
session_policy_inject() {
  local root="${1:-}" company="${2:-}" run_dir="${3:-}" message_text="${4-}"
  local system_txt hook company_cwd payload
  local max_policies max_bytes
  local slug scope path enf rule
  local injected=0 dropped=0 bytes_used=0
  local tmp_tsv tmp_sorted body_file ov_file rebuilt
  local core_path rule_text extracted block line_bytes

  SESSION_POLICY_OVERRIDES_JSON='[]'
  SESSION_POLICIES_TRUNCATED=0
  SESSION_POLICIES_INJECTED=0

  [ -n "$root" ] && [ -n "$company" ] && [ -n "$run_dir" ] || {
    echo 0
    return 0
  }
  system_txt="$run_dir/system.txt"
  [ -f "$system_txt" ] || {
    echo 0
    return 0
  }

  hook="$root/.claude/hooks/inject-policy-on-trigger.sh"
  if [ ! -f "$hook" ]; then
    echo "[hq-agent-session] policy inject: hook missing at $hook" >&2
    echo 0
    return 0
  fi

  max_policies="${HQ_SESSION_POLICY_MAX_POLICIES:-32}"
  max_bytes="${HQ_SESSION_POLICY_MAX_BYTES:-131072}"
  case "$max_policies" in ''|*[!0-9]*) max_policies=32 ;; esac
  case "$max_bytes" in ''|*[!0-9]*) max_bytes=131072 ;; esac

  company_cwd="$root/companies/$company"
  mkdir -p "$company_cwd" 2>/dev/null || true

  payload="$(jq -nc \
    --arg sid "hq-agent-session-${SESSION_RUN_ID:-$$}" \
    --arg cwd "$company_cwd" \
    --arg prompt "${message_text-}" \
    '{
      hook_event_name: "UserPromptSubmit",
      session_id: $sid,
      cwd: $cwd,
      prompt: $prompt,
      source: "hq-agent-session"
    }')" || payload="{}"

  tmp_tsv="$(mktemp)"
  ov_file="$(mktemp)"
  : > "$ov_file"

  # CWD pin + HQ_POLICY_COMPANY + HQ_POLICY_EMIT=tsv (US-406 AC-5/AC-6).
  (
    cd "$company_cwd" || cd "$root" || true
    printf '%s' "$payload" | \
      HQ_ROOT="$root" \
      CLAUDE_PROJECT_DIR="$root" \
      HQ_POLICY_EMIT=tsv \
      HQ_POLICY_COMPANY="$company" \
      bash "$hook" 2>/dev/null || true
  ) > "$tmp_tsv" || true

  # Collect overrides: company scope wins and a core sibling file exists.
  while IFS=$'\t' read -r slug scope path enf rule || [ -n "${slug:-}" ]; do
    [ -z "${slug:-}" ] && continue
    if [ "$scope" = "company" ]; then
      core_path="$root/core/policies/${slug}.md"
      if [ -f "$core_path" ]; then
        # One JSON object per line for jq -s slurp.
        jq -nc \
          --arg id "$slug" \
          --arg companyPath "$path" \
          --arg corePath "$core_path" \
          '{id: $id, companyPath: $companyPath, corePath: $corePath}' \
          >> "$ov_file" 2>/dev/null || true
      fi
    fi
  done < "$tmp_tsv"

  if [ -s "$ov_file" ]; then
    SESSION_POLICY_OVERRIDES_JSON="$(jq -s -c '.' "$ov_file" 2>/dev/null || echo '[]')"
  else
    SESSION_POLICY_OVERRIDES_JSON='[]'
  fi
  [ -n "$SESSION_POLICY_OVERRIDES_JSON" ] || SESSION_POLICY_OVERRIDES_JSON='[]'

  # Sort: hard first, then everything else (soft/unset), preserving relative order.
  tmp_sorted="$(mktemp)"
  {
    while IFS=$'\t' read -r slug scope path enf rule || [ -n "${slug:-}" ]; do
      [ -z "${slug:-}" ] && continue
      [ "$enf" = "hard" ] && printf '%s\t%s\t%s\t%s\t%s\n' "$slug" "$scope" "$path" "$enf" "$rule"
    done < "$tmp_tsv"
    while IFS=$'\t' read -r slug scope path enf rule || [ -n "${slug:-}" ]; do
      [ -z "${slug:-}" ] && continue
      [ "$enf" != "hard" ] && printf '%s\t%s\t%s\t%s\t%s\n' "$slug" "$scope" "$path" "$enf" "$rule"
    done < "$tmp_tsv"
  } > "$tmp_sorted"

  body_file="$(mktemp)"
  : > "$body_file"
  bytes_used=0
  injected=0
  dropped=0

  while IFS=$'\t' read -r slug scope path enf rule || [ -n "${slug:-}" ]; do
    [ -z "${slug:-}" ] && continue
    rule_text="$rule"
    if [ -n "$path" ] && [ -f "$path" ]; then
      extracted="$(awk '
        /^## Rule[ \t]*$/ { r=1; next }
        r && /^## / { exit }
        r && NF { print; if (++n >= 20) exit }
      ' "$path" 2>/dev/null | head -c 4096 || true)"
      if [ -n "$extracted" ]; then
        rule_text="$extracted"
      fi
    fi
    rule_text="$(printf '%s' "$rule_text" | tr '\n' ' ' | sed 's/[[:space:]]\{1,\}/ /g')"
    block="$(printf '> Policy `%s` [%s/%s]: %s\n' "$slug" "$scope" "$enf" "$rule_text")"
    line_bytes="$(printf '%s' "$block" | wc -c | tr -d '[:space:]')"
    case "$line_bytes" in ''|*[!0-9]*) line_bytes=0 ;; esac

    if [ "$injected" -ge "$max_policies" ] || \
       [ $((bytes_used + line_bytes)) -gt "$max_bytes" ]; then
      dropped=$((dropped + 1))
      continue
    fi
    printf '%s' "$block" >> "$body_file"
    bytes_used=$((bytes_used + line_bytes))
    injected=$((injected + 1))
  done < "$tmp_sorted"

  if [ "$dropped" -gt 0 ]; then
    printf '> Policy budget truncated: %s additional policies withheld (max_policies=%s max_bytes=%s).\n' \
      "$dropped" "$max_policies" "$max_bytes" >> "$body_file"
  fi

  if grep -q '<!-- hq-section: policies -->' "$system_txt"; then
    rebuilt="$(mktemp)"
    awk -v body_file="$body_file" '
      BEGIN {
        while ((getline line < body_file) > 0) body = body line "\n"
        close(body_file)
      }
      /<!-- hq-section: policies -->/ {
        print
        printf "%s", body
        skip=1
        next
      }
      skip && /<!-- hq-section:/ { skip=0 }
      skip { next }
      { print }
    ' "$system_txt" > "$rebuilt"
    mv "$rebuilt" "$system_txt"
  else
    {
      printf '<!-- hq-section: policies -->\n'
      cat "$body_file"
    } >> "$system_txt"
  fi

  SESSION_POLICIES_TRUNCATED="$dropped"
  SESSION_POLICIES_INJECTED="$injected"

  rm -f "$tmp_tsv" "$tmp_sorted" "$body_file" "$ov_file"
  echo "$injected"
  return 0
}
