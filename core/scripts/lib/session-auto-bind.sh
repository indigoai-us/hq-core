#!/usr/bin/env bash
# hq-core: public
# session-auto-bind.sh — bind company_slug + scope-capability for a session.
#
# Trusted sources (first hit wins): existing session state, parent session,
# explicit HQ_SPAWN_COMPANY, a sole real company in the manifest, then the human
# device default. Fleet/agent boxes never use manifest or device defaults: their
# dispatch context is the only safe source.
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

session_auto_bind_has_exact_company_dir() {
  local root="${1:-}" slug="${2:-}" company_dir
  [ -n "$root" ] && [ -n "$slug" ] || return 1
  # Compare against directory entries instead of testing the requested path:
  # on case-insensitive filesystems, -d companies/acme can resolve companies/Acme.
  # Company directories are not supported as symlinks (session-authz rejects them).
  for company_dir in "$root"/companies/*; do
    [ -d "$company_dir" ] || continue
    [ -L "$company_dir" ] && continue
    [ "${company_dir##*/}" = "$slug" ] && return 0
  done
  return 1
}

session_auto_bind_is_known_slug() {
  local root="${1:-}" slug="${2:-}"
  [ -n "$root" ] && [ -n "$slug" ] || return 1
  case "$slug" in
    ''|*[!a-zA-Z0-9_-]*) return 1 ;;
  esac
  [ "$slug" = "personal" ] && return 0
  session_auto_bind_has_exact_company_dir "$root" "$slug"
}

# Reject a non-canonical spelling when it case-folds to a real company entry.
# Manual session binding uses this to preserve unknown-slug behavior without
# accepting a case alias on case-insensitive filesystems.
session_auto_bind_has_case_alias() {
  local root="${1:-}" slug="${2:-}" company_dir company_slug slug_fold company_fold
  [ -n "$root" ] && [ -n "$slug" ] || return 1

  # SessionStart most often sees the exact bound name. Prove that with shell
  # builtins before paying for any case-fold subprocesses.
  for company_dir in "$root"/companies/*; do
    [ -d "$company_dir" ] || continue
    company_slug="${company_dir##*/}"
    [ "$company_slug" = "$slug" ] && [ ! -L "$company_dir" ] && return 1
  done

  slug_fold="$(printf '%s' "$slug" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  for company_dir in "$root"/companies/*; do
    [ -d "$company_dir" ] || continue
    company_slug="${company_dir##*/}"
    [ "$company_slug" = "$slug" ] && continue
    company_fold="$(printf '%s' "$company_slug" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    [ "$company_fold" = "$slug_fold" ] && return 0
  done
  return 1
}

session_auto_bind_write_binding_meta() {
  local meta="${1:-}" slug="${2:-}" source="${3:-}" meta_dir tmp
  [ -n "$meta" ] && [ -n "$slug" ] && [ -n "$source" ] || return 1
  meta_dir="$(dirname "$meta")"
  tmp="$(mktemp "$meta_dir/.meta.XXXXXX")" || return 1
  awk -v slug="$slug" -v source="$source" '
    BEGIN { slug_found = 0; source_found = 0 }
    /^[[:space:]]*company_slug:/ { print "company_slug: " slug; slug_found = 1; next }
    /^[[:space:]]*company_source:/ { print "company_source: " source; source_found = 1; next }
    { print }
    END {
      if (!slug_found) print "company_slug: " slug
      if (!source_found) print "company_source: " source
    }
  ' "$meta" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$meta"
}

# Remove only stale aliases. Other unrecognized or opaque identifiers retain
# their existing behavior and are not rewritten by this cleanup.
session_auto_bind_clear_case_alias() {
  local root="${1:-}" sid="${2:-}" meta meta_slug scope_slug tmp meta_dir cap
  [ -n "$root" ] && [ -n "$sid" ] || return 1
  meta="$root/workspace/sessions/$sid/meta.yaml"
  meta_slug="$(session_auto_bind_meta_slug "$root" "$sid")"
  if session_auto_bind_has_case_alias "$root" "$meta_slug"; then
    meta_dir="$(dirname "$meta")"
    tmp="$(mktemp "$meta_dir/.meta.XXXXXX")" || return 1
    awk '
      /^[[:space:]]*company_slug:/ { next }
      /^[[:space:]]*company_source:/ { next }
      { print }
    ' "$meta" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$meta" || return 1
  fi
  if command -v session_scope_read >/dev/null 2>&1; then
    scope_slug="$(session_scope_read "$root" "$sid" 2>/dev/null || true)"
    if session_auto_bind_has_case_alias "$root" "$scope_slug"; then
      cap="$(session_scope_capability_path "$root" "$sid" 2>/dev/null || true)"
      [ -n "$cap" ] && rm -f "$cap"
    fi
  fi
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
# The default remains two seconds; bounded SessionStart maintenance can request
# a longer explicit ceiling without changing the caller's process budget.
session_auto_bind_run_with_timeout() {
  command -v node >/dev/null 2>&1 || return 127
  local timeout_ms=2000 capture_stderr=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout-ms)
        [ "$#" -ge 2 ] || return 127
        timeout_ms="${2:-}"
        shift 2
        ;;
      --capture-stderr)
        capture_stderr=1
        shift
        ;;
      *) break ;;
    esac
  done
  case "$timeout_ms" in
    ''|*[!0-9]*) return 127 ;;
  esac
  [ "$timeout_ms" -ge 1 ] && [ "$timeout_ms" -le 10000 ] || return 127
  [ "$#" -gt 0 ] || return 127
  node -e '
const { spawn } = require("child_process");
const timeoutMs = Number(process.argv[1]);
const captureStderr = process.argv[2] === "1";
const command = process.argv[3];
if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 10000 || !command) process.exit(127);
const child = spawn(command, process.argv.slice(4), {
  detached: true,
  stdio: ["ignore", "pipe", captureStderr ? "pipe" : "ignore"],
});
let finished = false;
let stopStatus = null;
let timeoutTimer = null;
let killTimer = null;
const finish = (status) => {
  if (finished) return;
  finished = true;
  if (timeoutTimer) clearTimeout(timeoutTimer);
  if (killTimer) clearTimeout(killTimer);
  process.exitCode = status;
};
const signalGroup = (signal) => {
  if (!child.pid) return;
  try { process.kill(-child.pid, signal); } catch (_) {}
};
const requestStop = (status) => {
  if (stopStatus === null) stopStatus = status;
  signalGroup("SIGTERM");
  if (!killTimer) killTimer = setTimeout(() => signalGroup("SIGKILL"), 250);
};
child.stdout.on("data", (chunk) => process.stdout.write(chunk));
if (captureStderr) child.stderr.on("data", (chunk) => process.stderr.write(chunk));
process.once("SIGTERM", () => requestStop(143));
process.once("SIGINT", () => requestStop(130));
child.once("error", () => requestStop(127));
child.once("exit", (code, signal) => {
  if (stopStatus === null) {
    stopStatus = typeof code === "number" ? code : (signal ? 128 : 1);
  }
  // A child can leave descendants holding either output pipe open. Stop the
  // process group now, but let `close` drain the streams before returning.
  signalGroup("SIGTERM");
  if (!killTimer) killTimer = setTimeout(() => signalGroup("SIGKILL"), 250);
});
child.once("close", (code, signal) => {
  const status = stopStatus === null
    ? (typeof code === "number" ? code : (signal ? 128 : 1))
    : stopStatus;
  finish(status);
});
timeoutTimer = setTimeout(() => requestStop(124), timeoutMs);
' "$timeout_ms" "$capture_stderr" "$@"
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

  json="$(HQ_NO_UPDATE_CHECK=1 session_auto_bind_run_with_timeout hq mesh context default get --json 2>/dev/null || true)"
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

# Emit a company slug only when the manifest contains exactly one real company.
# Both supported manifest layouts are accepted: a `companies:` mapping and the
# historical flat mapping. The scaffold/template and metadata sections are not
# company memberships.
session_auto_bind_manifest_single_company() {
  local root="${1:-}" manifest
  [ -n "$root" ] || return 0
  manifest="$root/companies/manifest.yaml"
  [ -f "$manifest" ] || return 0
  awk '
    function keep(slug) {
      return slug != "" && slug != "_template" && slug != "companies" && slug != "unaffiliated_repos"
    }
    function record(line) {
      sub(/^[[:space:]]+/, "", line)
      sub(/:.*/, "", line)
      if (keep(line) && !seen[line]++) {
        if (count == 0) only = line
        count++
      }
    }
    /^companies:[[:space:]]*$/ { wrapped = 1; in_companies = 1; next }
    wrapped && /^[^[:space:]][^:]*:[[:space:]]*$/ { in_companies = 0; next }
    in_companies && /^  [A-Za-z][A-Za-z0-9_-]*:/ { record($0); next }
    !wrapped && /^[A-Za-z][A-Za-z0-9_-]*:/ { record($0) }
    END { if (count == 1) print only }
  ' "$manifest"
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

  if ! session_auto_bind_is_fleet_identity; then
    slug="$(session_auto_bind_manifest_single_company "$root")"
    if session_auto_bind_is_known_slug "$root" "$slug"; then
      printf '%s\tmanifest_single_company' "$slug"
      return 0
    fi
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

session_auto_bind_spawn_company_set() {
  local root="${1:-}" sid="${2:-}" primary="${3:-}" companies="${HQ_SPAWN_COMPANIES:-}" item first="" meta tmp
  [ -n "$companies" ] || return 0
  meta="$root/workspace/sessions/$sid/meta.yaml"
  local -a validated=()
  IFS=, read -r -a validated <<< "$companies"
  for item in "${validated[@]}"; do
    session_auto_bind_is_known_slug "$root" "$item" || return 0
    [ -n "$first" ] || first="$item"
  done
  [ "$first" = "$primary" ] || return 0
  companies="$(printf '%s\n' "${validated[@]}" | awk 'NF && !seen[$0]++' | paste -sd, -)"
  [ -n "$companies" ] || return 0
  tmp="$(mktemp)"
  awk -v slugs="$companies" '
    BEGIN { found=0 }
    $1 == "company_slugs:" { if (!found) print "company_slugs: " slugs; found=1; next }
    { print }
    END { if (!found) print "company_slugs: " slugs }
  ' "$meta" >"$tmp" && mv "$tmp" "$meta" || { rm -f "$tmp"; return 0; }
  if command -v session_scope_mint_set >/dev/null 2>&1; then
    session_scope_mint_set "$root" "$sid" "$companies" || true
  fi
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
  local stale_alias=false existing_scope_slug="" existing_meta_slug=""
  [ -n "$root" ] && [ -n "$sid" ] || return 0
  case "$sid" in
    .|..|*/*|*[!A-Za-z0-9._-]*) return 0 ;;
  esac

  if command -v session_scope_read >/dev/null 2>&1; then
    existing_scope_slug="$(session_scope_read "$root" "$sid" 2>/dev/null || true)"
  fi
  existing_meta_slug="$(session_auto_bind_meta_slug "$root" "$sid")"
  if session_auto_bind_has_case_alias "$root" "$existing_scope_slug" || \
     session_auto_bind_has_case_alias "$root" "$existing_meta_slug"; then
    stale_alias=true
  fi

  resolved="$(session_auto_bind_resolve_source "$root" "$sid" "$parent")"
  slug="${resolved%%$'\t'*}"
  source_tail="${resolved#*$'\t'}"
  source="${source_tail%%$'\t'*}"
  repair="${source_tail#*$'\t'}"
  [ "$repair" = "$source_tail" ] && repair=false
  if [ "$slug" = "$resolved" ] || [ -z "$slug" ]; then
    [ "$stale_alias" = "true" ] && session_auto_bind_clear_case_alias "$root" "$sid" || true
    return 0
  fi

  local meta_dir meta
  meta_dir="$root/workspace/sessions/$sid"
  meta="$meta_dir/meta.yaml"
  # Held sessions already have durable Work Mesh state. Repairing one with a
  # device preference is opt-in, and a held session can use the manifest
  # fallback only when its durable Work Context is explicitly unresolved.
  if { [ "$source" = "device_default" ] && [ "$repair" != "true" ]; } || \
     [ "$source" = "manifest_single_company" ]; then
    local work_context_root context_status
    work_context_root="${HQ_WORK_CONTEXT_ROOT:-${HOME:-}/.hq/work-context}"
    # SessionStart records this before its resolver preflight. The preflight
    # itself writes local state, which must not relabel a new session as held.
    if [ "$state_existed_before_preflight" != "0" ] && [ -f "$work_context_root/sessions/$sid.json" ]; then
      if [ "$source" = "device_default" ]; then
        [ "$stale_alias" = "true" ] && session_auto_bind_clear_case_alias "$root" "$sid" || true
        return 0
      fi
      context_status="$(jq -er '
        if type == "object" and (.contextStatus | type == "string")
        then .contextStatus else empty end
      ' "$work_context_root/sessions/$sid.json" 2>/dev/null || true)"
      if [ "$context_status" != "unresolved" ]; then
        [ "$stale_alias" = "true" ] && session_auto_bind_clear_case_alias "$root" "$sid" || true
        return 0
      fi
    fi
  fi
  mkdir -p "$meta_dir" 2>/dev/null || return 0

  if [ "$stale_alias" = "true" ]; then
    [ -f "$meta" ] || : > "$meta" || return 0
    session_auto_bind_write_binding_meta "$meta" "$slug" "$source" || return 0
  elif [ ! -f "$meta" ]; then
    printf 'session_id: %s\ncompany_slug: %s\ncompany_source: %s\nstarted_at: "%s"\nsenior: user\n' \
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
  session_auto_bind_spawn_company_set "$root" "$sid" "$slug"
  return 0
}

# Bind exactly the company accepted by the authoritative reconciliation result.
# Unlike session_auto_bind_apply this deliberately never reads device-default
# configuration again, so SessionStart has one reader and no TOCTOU window.
session_auto_bind_apply_validated_default() {
  local root="${1:-}" sid="${2:-}" slug="${3:-}" uid="${4:-}" state_existed="${5:-1}" repair="${6:-false}" meta_dir meta
  local stale_alias=false existing_scope_slug="" existing_meta_slug=""
  [ -n "$root" ] && [ -n "$sid" ] && [ -n "$slug" ] && [ -n "$uid" ] || return 0
  case "$sid" in .|..|*/*|*[!A-Za-z0-9._-]*) return 0 ;; esac
  if command -v session_scope_read >/dev/null 2>&1; then
    existing_scope_slug="$(session_scope_read "$root" "$sid" 2>/dev/null || true)"
  fi
  existing_meta_slug="$(session_auto_bind_meta_slug "$root" "$sid")"
  if session_auto_bind_has_case_alias "$root" "$existing_scope_slug" || \
     session_auto_bind_has_case_alias "$root" "$existing_meta_slug"; then
    stale_alias=true
  fi
  if ! session_auto_bind_is_known_slug "$root" "$slug"; then
    [ "$stale_alias" = "true" ] && session_auto_bind_clear_case_alias "$root" "$sid" || true
    return 0
  fi
  # A historical held state predates this SessionStart. Device defaults are weak
  # evidence, so never relabel it unless this device explicitly opted in.
  if [ "$state_existed" != "0" ] && [ "$repair" != "true" ]; then
    [ "$stale_alias" = "true" ] && session_auto_bind_clear_case_alias "$root" "$sid" || true
    return 0
  fi
  meta_dir="$root/workspace/sessions/$sid"
  meta="$meta_dir/meta.yaml"
  mkdir -p "$meta_dir" 2>/dev/null || return 0
  if [ "$stale_alias" = "true" ]; then
    [ -f "$meta" ] || : > "$meta" || return 0
    session_auto_bind_write_binding_meta "$meta" "$slug" "device_default" || return 0
  elif [ ! -f "$meta" ]; then
    printf 'session_id: %s\ncompany_slug: %s\ncompany_source: device_default\nsenior: user\n' "$sid" "$slug" > "$meta" || return 0
    [ "$state_existed" = "0" ] || printf 'company_confidence: device_default_repair\n' >> "$meta" || return 0
    printf 'started_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$meta" || return 0
  elif ! grep -q '^company_slug:' "$meta" 2>/dev/null; then
    printf 'company_slug: %s\ncompany_source: device_default\n' "$slug" >> "$meta" || return 0
  fi
  if command -v session_scope_mint >/dev/null 2>&1; then
    session_scope_mint "$root" "$sid" "$slug" || true
  fi
  session_auto_bind_spawn_company_set "$root" "$sid" "$slug"
}
