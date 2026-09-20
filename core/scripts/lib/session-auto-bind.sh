#!/usr/bin/env bash
# hq-core: public
# session-auto-bind.sh — bind company_slug + scope-capability for a session.
#
# Trusted sources (first hit wins): existing session state, parent session,
# explicit HQ_SPAWN_COMPANY, then the human device default. Fleet/agent boxes
# never use the device default: their dispatch context is the only safe source.
#
# Sourced; never execute directly.

session_auto_bind_meta_slug() {
  local root="${1:-}" sid="${2:-}" meta
  [ -n "$root" ] && [ -n "$sid" ] || return 0
  meta="$root/workspace/sessions/$sid/meta.yaml"
  [ -f "$meta" ] || return 0
  awk '
    $1 == "company_slug:" {
      sub(/^[^:]+:[[:space:]]*/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$meta" 2>/dev/null || true
}

session_auto_bind_is_known_slug() {
  local root="${1:-}" slug="${2:-}"
  [ -n "$root" ] && [ -n "$slug" ] || return 1
  case "$slug" in
    ''|*[!a-z0-9_-]*) return 1 ;;
  esac
  [ "$slug" = "personal" ] && return 0
  [ -d "$root/companies/$slug" ] && return 0
  return 1
}

# A human workstation may have ordinary hq CLI state. These markers identify
# a fleet runtime, for which a local preference must never replace dispatch.
session_auto_bind_is_fleet_identity() {
  [ -n "${HQ_AGENT_WORKDIR:-}" ] && return 0
  [ -n "${HQ_AGENT_COMPANY_DIR:-}" ] && return 0
  [ -n "${HQ_AGENT_IDENTITY_FILE:-}" ] && return 0
  [ -f /etc/hq-agent/identity.json ] && return 0
  [ -f /etc/hq-agent/machine-creds.json ] && return 0
  # HQ's canonical agent identity is here. HQ_AGENT_ROOT_PREFIX is a
  # test-only chroot prefix so the regression suite can exercise that exact
  # absolute-path contract without touching /var/lib on the host.
  local agent_root="${HQ_AGENT_ROOT_PREFIX:-}"
  if [ -n "$agent_root" ]; then
    [ -f "${agent_root%/}/var/lib/hq-agent/identity.json" ] && return 0
  else
    [ -f /var/lib/hq-agent/identity.json ] && return 0
  fi
  [ -f /var/lib/hq-agent/machine-creds.json ] && return 0
  return 1
}

# Run a command in a detached process group with a real wall-clock ceiling.
# A plain Perl alarm is replaced by exec(), so it cannot kill descendants which
# keep the command-substitution pipe open. Node is already required to run hq.
session_auto_bind_run_with_timeout() {
  command -v node >/dev/null 2>&1 || return 127
  node -e '
const { spawn } = require("child_process");
const command = process.argv[1];
if (!command) process.exit(127);
const child = spawn(command, process.argv.slice(2), {
  detached: true,
  stdio: ["ignore", "pipe", "ignore"],
});
let finished = false;
const finish = (status) => {
  if (finished) return;
  finished = true;
  clearTimeout(timer);
  try { process.kill(-child.pid, "SIGTERM"); } catch (_) {}
  process.exit(status);
};
child.stdout.on("data", (chunk) => process.stdout.write(chunk));
child.once("error", () => finish(127));
child.once("exit", (code) => finish(typeof code === "number" ? code : 1));
const timer = setTimeout(() => finish(124), 2000);
' "$@"
}

# Emits a known default-company slug and repair flag as tab-separated fields, or
# empty. Accept both the original compact payload and the current config shape.
session_auto_bind_device_default() {
  local root="${1:-}" json="" slug="" repair="false"
  [ -n "$root" ] || return 0
  [ -z "${HQ_SPAWN_COMPANY:-}" ] || return 0
  session_auto_bind_is_fleet_identity && return 0
  command -v hq >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0

  json="$(session_auto_bind_run_with_timeout hq mesh context default get --json 2>/dev/null || true)"
  [ -n "$json" ] || return 0
  slug="$(printf '%s' "$json" | jq -er '
    (.defaultCompany // .) as $default |
    if $default.enabled == true
      and ($default.source // "") != "disabled"
      and ($default.needsChoice // false) == false
      and ($default.slug | type == "string")
    then $default.slug else empty end
  ' 2>/dev/null || true)"
  repair="$(printf '%s' "$json" | jq -er '
    (.defaultCompany // .) as $default |
    if ($default.repairHeldWithDefault // .repairHeldWithDefault // false) == true
    then "true" else "false" end
  ' 2>/dev/null || true)"
  slug="$(printf '%s' "$slug" | tr -d '[:space:]\"')"
  case "$repair" in true) ;; *) repair=false ;; esac
  if session_auto_bind_is_known_slug "$root" "$slug"; then
    printf '%s\t%s' "$slug" "$repair"
  fi
}

# Prints slug and source as a tab-separated pair.
session_auto_bind_resolve_source() {
  local root="${1:-}" sid="${2:-}" parent="${3:-}" slug="" spawn="" parent_slug="" default_info="" repair="false"
  [ -n "$root" ] && [ -n "$sid" ] || return 0

  if command -v session_scope_read >/dev/null 2>&1; then
    slug="$(session_scope_read "$root" "$sid" 2>/dev/null || true)"
  fi
  [ -z "$slug" ] && slug="$(session_auto_bind_meta_slug "$root" "$sid")"
  if session_auto_bind_is_known_slug "$root" "$slug"; then
    printf '%s\tsession' "$slug"
    return 0
  fi

  [ -z "$parent" ] && parent="${HQ_PARENT_SESSION_ID:-}"
  parent="$(printf '%s' "$parent" | tr -d '[:space:]')"
  if [ -n "$parent" ] && [ "$parent" != "$sid" ]; then
    if command -v session_scope_read >/dev/null 2>&1; then
      parent_slug="$(session_scope_read "$root" "$parent" 2>/dev/null || true)"
    fi
    [ -z "$parent_slug" ] && parent_slug="$(session_auto_bind_meta_slug "$root" "$parent")"
    if session_auto_bind_is_known_slug "$root" "$parent_slug"; then
      spawn="$(printf '%s' "${HQ_SPAWN_COMPANY:-}" | tr -d '[:space:]\"')"
      if [ -n "$spawn" ] && [ "$spawn" != "$parent_slug" ]; then
        printf '%s\n' "session-auto-bind: ignoring HQ_SPAWN_COMPANY=$spawn because it mismatches parent company_slug=$parent_slug" >&2
      fi
      printf '%s\tparent' "$parent_slug"
      return 0
    fi
  fi

  slug="$(printf '%s' "${HQ_SPAWN_COMPANY:-}" | tr -d '[:space:]\"')"
  if session_auto_bind_is_known_slug "$root" "$slug"; then
    printf '%s\tspawn' "$slug"
    return 0
  fi

  # SessionStart defers device defaults to the shared CLI resolver so cwd and
  # repository evidence can challenge the preference before any scope is minted.
  [ -n "${HQ_SESSION_AUTO_BIND_SKIP_DEVICE_DEFAULT:-}" ] && return 0
  default_info="$(session_auto_bind_device_default "$root")"
  slug="${default_info%%$'\t'*}"
  repair="${default_info#*$'\t'}"
  [ "$repair" = "$default_info" ] && repair=false
  if session_auto_bind_is_known_slug "$root" "$slug"; then
    printf '%s\tdevice_default\t%s' "$slug" "$repair"
  fi
  return 0
}

# Historical slug-only contract retained for existing callers.
session_auto_bind_resolve() {
  local resolved="" slug=""
  resolved="$(session_auto_bind_resolve_source "$@")"
  slug="${resolved%%$'\t'*}"
  [ "$slug" = "$resolved" ] && return 0
  printf '%s' "$slug"
}

session_auto_bind_apply() {
  local root="${1:-}" sid="${2:-}" parent="${3:-}" state_existed_before_preflight="${4:-}" resolved="" slug="" source="" source_tail="" repair="false"
  [ -n "$root" ] && [ -n "$sid" ] || return 0
  case "$sid" in
    .|..|*/*|*[!A-Za-z0-9._-]*) return 0 ;;
  esac

  resolved="$(session_auto_bind_resolve_source "$root" "$sid" "$parent")"
  slug="${resolved%%$'\t'*}"
  source_tail="${resolved#*$'\t'}"
  source="${source_tail%%$'\t'*}"
  repair="${source_tail#*$'\t'}"
  [ "$repair" = "$source_tail" ] && repair=false
  [ "$slug" = "$resolved" ] && return 0
  [ -n "$slug" ] || return 0

  local meta_dir meta
  meta_dir="$root/workspace/sessions/$sid"
  meta="$meta_dir/meta.yaml"
  # Held sessions already have durable Work Mesh state. Repairing one with a
  # device preference is opt-in; a genuinely new session can use the default.
  if [ "$source" = "device_default" ] && [ "$repair" != "true" ]; then
    local work_context_root
    work_context_root="${HQ_WORK_CONTEXT_ROOT:-${HOME:-}/.hq/work-context}"
    # SessionStart records this before its resolver preflight. The preflight
    # itself writes local state, which must not relabel a new session as held.
    [ "$state_existed_before_preflight" = "0" ] || [ ! -f "$work_context_root/sessions/$sid.json" ] || return 0
  fi
  mkdir -p "$meta_dir" 2>/dev/null || return 0

  if [ ! -f "$meta" ]; then
    printf 'session_id: %s\ncompany_slug: %s\ncompany_source: %s\nstarted_at: "%s"\n' \
      "$sid" "$slug" "$source" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" \
      > "$meta" || return 0
  elif ! grep -q '^company_slug:' "$meta" 2>/dev/null; then
    printf 'company_slug: %s\ncompany_source: %s\n' "$slug" "$source" >> "$meta" || return 0
  elif ! grep -q '^company_source:' "$meta" 2>/dev/null; then
    printf 'company_source: %s\n' "$source" >> "$meta" || return 0
  fi

  if command -v session_scope_mint >/dev/null 2>&1; then
    session_scope_mint "$root" "$sid" "$slug" || true
  fi
  return 0
}

# Bind exactly the company accepted by the authoritative reconciliation result.
# Unlike session_auto_bind_apply this deliberately never reads device-default
# configuration again, so SessionStart has one reader and no TOCTOU window.
session_auto_bind_apply_validated_default() {
  local root="${1:-}" sid="${2:-}" slug="${3:-}" uid="${4:-}" state_existed="${5:-1}" repair="${6:-false}" meta_dir meta
  [ -n "$root" ] && [ -n "$sid" ] && [ -n "$slug" ] && [ -n "$uid" ] || return 0
  case "$sid" in .|..|*/*|*[!A-Za-z0-9._-]*) return 0 ;; esac
  session_auto_bind_is_known_slug "$root" "$slug" || return 0
  # A historical held state predates this SessionStart. Device defaults are weak
  # evidence, so never relabel it unless this device explicitly opted in.
  [ "$state_existed" = "0" ] || [ "$repair" = "true" ] || return 0
  meta_dir="$root/workspace/sessions/$sid"
  meta="$meta_dir/meta.yaml"
  mkdir -p "$meta_dir" 2>/dev/null || return 0
  if [ ! -f "$meta" ]; then
    printf 'session_id: %s\ncompany_slug: %s\ncompany_source: device_default\n' "$sid" "$slug" > "$meta" || return 0
    [ "$state_existed" = "0" ] || printf 'company_confidence: device_default_repair\n' >> "$meta" || return 0
    printf 'started_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$meta" || return 0
  elif ! grep -q '^company_slug:' "$meta" 2>/dev/null; then
    printf 'company_slug: %s\ncompany_source: device_default\n' "$slug" >> "$meta" || return 0
  fi
  if command -v session_scope_mint >/dev/null 2>&1; then
    session_scope_mint "$root" "$sid" "$slug" || true
  fi
}
