#!/usr/bin/env bash
# hq-core: public
# session-scope-capability.sh — mint/read workspace/sessions/<id>/scope-capability.json
#
# Sourced by core/scripts/hq-session.sh and .claude/hooks/mandatory-scope-authorizer.sh.
# Never execute directly.

session_scope_multi_company_enabled() {
  local root="${1:-}" primary="${2:-}" flag_script
  flag_script="$root/.codex/hooks/codex-explicit-path-flag.cjs"
  # This flag is a kill switch: absent local state is not an explicit false.
  # Keep this default-on branch local and cheap on the event path.
  [ -n "$root" ] && [ -n "$primary" ] && [ -n "${HOME:-}" ] \
    && [ -f "$root/core/scripts/hqd-hook-flag-cache-lib.sh" ] && [ -f "$flag_script" ] \
    || return 0
  if ! command -v hqd_hook_flag_state_for >/dev/null 2>&1 && [ -f "$root/core/scripts/hqd-hook-flag-cache-lib.sh" ]; then
    # shellcheck source=../hqd-hook-flag-cache-lib.sh
    . "$root/core/scripts/hqd-hook-flag-cache-lib.sh"
  fi
  if command -v hqd_hook_flag_state_for >/dev/null 2>&1; then
    hqd_hook_flag_state_for multi-company-session-lock hooks.multi-company-session-lock \
      "$flag_script" "$root" "$primary" "$primary"
    [ "${HQD_FLAG_STATE:-unknown}" != false ]
    return $?
  fi
  # The cache library is part of the live HQ tree. Missing it is a lookup error,
  # so keep the gate off instead of introducing uncached Node work on a hook.
  return 1
}

# session_scope_identity_is_valid <identity>
#   Identities become path segments; accept only a conservative portable set.
session_scope_identity_is_valid() {
  local identity="${1:-}"
  [ -n "$identity" ] || return 1
  case "$identity" in
    .|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# session_scope_capability_path <root> <session_id> [agent_id]
#   Main thread retains the legacy path. A Task subagent gets a distinct path.
session_scope_capability_path() {
  local root="${1:-}" sid="${2:-}" aid="${3:-}"
  [ -n "$root" ] && session_scope_identity_is_valid "$sid" || return 1
  if [ -n "$aid" ]; then
    session_scope_identity_is_valid "$aid" || return 1
    printf '%s/workspace/sessions/%s/agents/%s/scope-capability.json' "$root" "$sid" "$aid"
  else
    printf '%s/workspace/sessions/%s/scope-capability.json' "$root" "$sid"
  fi
}

# session_scope_read <root> <session_id> [agent_id]
#   Print company_slug from the exact caller's capability, or empty if invalid.
session_scope_read() {
  local root="${1:-}" sid="${2:-}" aid="${3:-}" cap
  cap="$(session_scope_capability_path "$root" "$sid" "$aid")" || return 0
  [ -f "$cap" ] || return 0
  jq -r --arg sid "$sid" --arg aid "$aid" \
    'select(.session_id == $sid and (.agent_id // "") == $aid) | .company_slug // empty' \
    "$cap" 2>/dev/null || true
}

# session_scope_read_companies <root> <session_id> [agent_id]
# Print the ordered, validated lock set. Legacy capabilities remain singleton
# locks; malformed company_slugs fail closed instead of falling back to primary.
session_scope_read_companies() {
  local root="${1:-}" sid="${2:-}" aid="${3:-}" cap lock_info primary has_set result slug out=""
  local -a slugs
  cap="$(session_scope_capability_path "$root" "$sid" "$aid")" || return 0
  [ -f "$cap" ] || return 0
  lock_info="$(jq -er --arg sid "$sid" --arg aid "$aid" '
    select(.session_id == $sid and (.agent_id // "") == $aid)
    | if (.company_slug | type) != "string" or (.company_slug | test("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$") | not) then error("invalid primary")
      elif has("company_slugs") then
        if (.company_slugs | type) == "array" and all(.company_slugs[]; type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"))
          and (.company_slugs | length) > 0 and .company_slugs[0] == .company_slug
          and ((.company_slugs | unique | length) == (.company_slugs | length))
          and ((.company_slug == "personal" and (.company_slugs | length) == 1)
            or (.company_slugs | all(. != "personal"))) then
          [.company_slug, "true", (.company_slugs | join(","))] | @tsv
        else error("invalid company_slugs") end
      else [.company_slug, "false", .company_slug] | @tsv end
  ' "$cap" 2>/dev/null)" || return 0
  IFS="$(printf '\t')" read -r primary has_set result <<EOF
$lock_info
EOF
  case "$primary" in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
  IFS=, read -r -a slugs <<< "$result"
  # A singleton is identical whether the gate is on or off; skip the flag
  # client on the session-start hot path.
  if [ "${#slugs[@]}" -le 1 ]; then
    if [ "$primary" = personal ] || { [ -d "$root/companies/$primary" ] && [ ! -L "$root/companies/$primary" ]; }; then
      printf '%s\n' "$primary"
    fi
    return 0
  fi
  if [ "$has_set" != true ] || ! session_scope_multi_company_enabled "$root" "$primary"; then
    if [ "$primary" = personal ] || { [ -d "$root/companies/$primary" ] && [ ! -L "$root/companies/$primary" ]; }; then
      printf '%s\n' "$primary"
    fi
    return 0
  fi
  for slug in "${slugs[@]}"; do
    case "$slug" in ''|*[!a-zA-Z0-9_-]*) return 0 ;; esac
    if [ "$slug" = personal ] || { [ -d "$root/companies/$slug" ] && [ ! -L "$root/companies/$slug" ]; }; then
      case ",$out," in *",$slug,"*) ;; *) out="${out:+$out,}$slug" ;; esac
    fi
  done
  [ -n "$out" ] && printf '%s\n' "$out" | tr ',' '\n'
}

# session_scope_resolve_agent_company <root> <session_id> <agent_id> <session_company> <event>
#   Existing tuple bindings always win. Session metadata may bind a caller only
#   on SessionStart, when that agent has not been bound before.
session_scope_resolve_agent_company() {
  local root="${1:-}" sid="${2:-}" aid="${3:-}" session_company="${4:-}" event="${5:-}" bound_company=""
  bound_company="$(session_scope_read "$root" "$sid" "$aid")"
  if [ -n "$bound_company" ]; then
    printf '%s' "$bound_company"
  elif [ "$event" = "SessionStart" ]; then
    printf '%s' "$session_company"
  fi
}

session_scope_resolve_agent_companies() {
  local root="${1:-}" sid="${2:-}" aid="${3:-}" session_companies="${4:-}" event="${5:-}" bound=""
  bound="$(session_scope_read_companies "$root" "$sid" "$aid" 2>/dev/null || true)"
  if [ -n "$bound" ]; then
    printf '%s\n' "$bound"
  elif [ "$event" = "SessionStart" ] && [ -n "$session_companies" ]; then
    printf '%s\n' "$session_companies" | tr ',' '\n' | awk 'NF && !seen[$0]++'
  fi
}

# session_scope_mint <root> <session_id> <company_slug> [agent_id]
#   Write scope-capability.json for the exact caller. Main-thread writes retain
#   the legacy shape/path for one-restart compatibility.
session_scope_mint() {
  local root="${1:-}" sid="${2:-}" slug="${3:-}" aid="${4:-}"
  [ -n "$root" ] && session_scope_identity_is_valid "$sid" && [ -n "$slug" ] || return 1
  if [ -n "$aid" ]; then
    session_scope_identity_is_valid "$aid" || {
      echo "session-scope-capability: invalid agent_id" >&2
      return 1
    }
  fi

  case "$slug" in
    ''|*[!a-zA-Z0-9_-]*)
      echo "session-scope-capability: invalid company_slug: $slug" >&2
      return 1
      ;;
  esac

  local cap dir tmp minted_at
  cap="$(session_scope_capability_path "$root" "$sid" "$aid")" || return 1
  dir="$(dirname "$cap")"
  mkdir -p "$dir" || return 1

  minted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S'Z')"
  tmp="$(mktemp)"
  jq -n \
    --arg sid "$sid" \
    --arg aid "$aid" \
    --arg slug "$slug" \
    --arg minted_at "$minted_at" \
    '{session_id: $sid, company_slug: $slug, minted_at: $minted_at} + (if $aid == "" then {} else {agent_id: $aid} end)' >"$tmp" \
    || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$cap"
}

# session_scope_mint_set <root> <session_id> <comma-separated-slugs> [agent_id]
session_scope_mint_set() {
  local root="${1:-}" sid="${2:-}" slugs="${3:-}" aid="${4:-}" first rest slug json
  [ -n "$slugs" ] || return 1
  first="${slugs%%,*}"
  case "$first" in ''|*[!a-zA-Z0-9_-]*) return 1 ;; esac
  rest="${slugs#"$first"}"
  while [ -n "$rest" ]; do
    case "$rest" in ,*) rest="${rest#,}" ;; *) return 1 ;; esac
    slug="${rest%%,*}"
    case "$slug" in ''|*[!a-zA-Z0-9_-]*) return 1 ;; esac
    rest="${rest#"$slug"}"
    [ "$rest" = "$slug" ] && break
  done
  json="$(jq -nc --arg slugs "$slugs" '$slugs | split(",") | reduce .[] as $slug ([]; if index($slug) == null then . + [$slug] else . end)')" || return 1
  session_scope_mint "$root" "$sid" "$first" "$aid" || return 1
  local cap tmp minted_at
  cap="$(session_scope_capability_path "$root" "$sid" "$aid")" || return 1
  minted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$(mktemp)"
  jq --argjson slugs "$json" --arg minted_at "$minted_at" '.company_slugs=$slugs | .minted_at=$minted_at' "$cap" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$cap"
}
