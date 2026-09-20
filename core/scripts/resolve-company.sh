#!/usr/bin/env bash
# hq-core: public
# resolve-company.sh — resolve the active company for skills and routing.
#
# Resolution order (first hit wins): explicit manifest slug in the prompt,
# session company_slug, enabled device default, then none. Prompt matching is
# whole-token only; free text never guesses a company.
#
# Output: {"company":"<slug>","source":"prompt|session|device_default|none"}
# Always exits 0 and never writes state.

set -uo pipefail

ROOT=""
PROMPT=""
HAVE_PROMPT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 || shift ;;
    --prompt) PROMPT="${2:-}"; HAVE_PROMPT=1; shift 2 || shift ;;
    --help|-h)
      sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) shift ;;
  esac
done

if [ "$HAVE_PROMPT" -eq 0 ] && [ ! -t 0 ]; then
  PROMPT="$(cat 2>/dev/null || true)"
fi
: "${PROMPT:=}"

emit() {
  printf '{"company":"%s","source":"%s"}\n' "$1" "$2"
  exit 0
}

if [ -z "$ROOT" ]; then
  ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)}}"
fi

MANIFEST="$ROOT/companies/manifest.yaml"
[ -f "$MANIFEST" ] || emit "" "none"

SLUGS="$(
  awk '
    function keep(slug) {
      return slug != "" && slug != "_template" && slug != "companies" && slug != "unaffiliated_repos"
    }
    /^companies:[[:space:]]*$/ { wrapped = 1; next }
    wrapped && /^[^[:space:]][^:]*:[[:space:]]*$/ { wrapped = 0 }
    wrapped && /^  [a-z][a-z0-9_-]*:/ {
      line = $0; sub(/^[[:space:]]+/, "", line); sub(/:.*/, "", line)
      if (keep(line)) print line
      next
    }
    !wrapped && /^[a-z][a-z0-9_-]*:/ {
      line = $0; sub(/:.*/, "", line)
      if (keep(line)) print line
    }
  ' "$MANIFEST" | sort -u
)"
[ -n "$SLUGS" ] || emit "" "none"

is_known_slug() {
  printf '%s\n' "$SLUGS" | grep -Fxq "$1"
}

prompt_slug() {
  local normalized="" match=""
  [ -n "$PROMPT" ] || return 0
  normalized="$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' ' ')"
  match="$(
    printf '%s\n' "$SLUGS" | awk -v line="$normalized" '
      BEGIN {
        n = split(line, tok, /[ \t]+/)
        for (i = 1; i <= n; i++) if (tok[i] != "" && !(tok[i] in pos)) pos[tok[i]] = i
        bestSlug = ""; bestLen = 0; bestPos = 0
      }
      {
        slug = $0
        if (slug in pos) {
          len = length(slug); p = pos[slug]
          if (len > bestLen || (len == bestLen && p < bestPos)) {
            bestSlug = slug; bestLen = len; bestPos = p
          }
        }
      }
      END { if (bestSlug != "") print bestSlug }
    '
  )"
  printf '%s' "$match"
}

MATCH="$(prompt_slug)"
[ -n "$MATCH" ] && emit "$MATCH" "prompt"

SESSION_CO=""
if [ -x "$ROOT/core/scripts/hq-session.sh" ]; then
  SESSION_CO="$(bash "$ROOT/core/scripts/hq-session.sh" get company_slug 2>/dev/null || true)"
  SESSION_CO="$(printf '%s' "$SESSION_CO" | tr -d '[:space:]\"')"
fi
if [ -n "$SESSION_CO" ] && is_known_slug "$SESSION_CO"; then
  emit "$SESSION_CO" "session"
fi

is_fleet_identity() {
  [ -n "${HQ_AGENT_WORKDIR:-}" ] && return 0
  [ -n "${HQ_AGENT_COMPANY_DIR:-}" ] && return 0
  [ -n "${HQ_AGENT_IDENTITY_FILE:-}" ] && return 0
  [ -f /etc/hq-agent/identity.json ] && return 0
  [ -f /etc/hq-agent/machine-creds.json ] && return 0
  agent_root="${HQ_AGENT_ROOT_PREFIX:-}"
  if [ -n "$agent_root" ]; then
    [ -f "${agent_root%/}/var/lib/hq-agent/identity.json" ] && return 0
  else
    [ -f /var/lib/hq-agent/identity.json ] && return 0
  fi
  [ -f /var/lib/hq-agent/machine-creds.json ] && return 0
  return 1
}

run_with_timeout() {
  command -v node >/dev/null 2>&1 || return 127
  node -e '
const { spawn } = require("child_process");
const command = process.argv[1];
if (!command) process.exit(127);
const child = spawn(command, process.argv.slice(2), { detached: true, stdio: ["ignore", "pipe", "ignore"] });
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

if ! is_fleet_identity && command -v hq >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  DEFAULT_JSON="$(run_with_timeout hq mesh context default get --json 2>/dev/null || true)"
  DEFAULT_SLUG="$(printf '%s' "$DEFAULT_JSON" | jq -er '(.defaultCompany // .) as $default | if $default.enabled == true and ($default.source // "") != "disabled" and ($default.needsChoice // false) == false and ($default.slug | type == "string") then $default.slug else empty end' 2>/dev/null || true)"
  DEFAULT_SLUG="$(printf '%s' "$DEFAULT_SLUG" | tr -d '[:space:]\"')"
  if [ -n "$DEFAULT_SLUG" ] && is_known_slug "$DEFAULT_SLUG"; then
    # A device default is only a local preference. Reconcile performs the
    # token-backed active-membership check; never promote this fallback when
    # that preflight is unavailable, times out, or returns a noncanonical row.
    PREFLIGHT_SESSION_ID="resolve-default-$$-$RANDOM"
    PREFLIGHT_OPERATION_ID="resolve-default-op-$$-$RANDOM"
    PREFLIGHT_OBSERVATION="$(jq -cn \
      --arg session_id "$PREFLIGHT_SESSION_ID" \
      --arg operation_id "$PREFLIGHT_OPERATION_ID" \
      --arg root "$ROOT" \
      '{contractVersion:1,clientOperationId:$operation_id,identity:{sessionId:$session_id,harness:"hq-core",adapterVersion:"1"},cwd:$root,hqRoot:$root}')"
    PREFLIGHT_STATUS=0
    PREFLIGHT_RESULT="$(run_with_timeout hq mesh context reconcile --observation-json "$PREFLIGHT_OBSERVATION" --machine --offline 2>/dev/null)" || PREFLIGHT_STATUS=$?
    VALIDATED_SLUG=""
    if [ "$PREFLIGHT_STATUS" -eq 0 ]; then
      VALIDATED_SLUG="$(printf '%s' "$PREFLIGHT_RESULT" | jq -er \
        --arg slug "$DEFAULT_SLUG" \
        --arg session_id "$PREFLIGHT_SESSION_ID" \
        --arg operation_id "$PREFLIGHT_OPERATION_ID" '
          if type == "object"
            and .contractVersion == 1
            and (.sessionId | type == "string") and .sessionId == $session_id
            and (.clientOperationId | type == "string") and .clientOperationId == $operation_id
            and (.kind == "queued" or .kind == "needs_project" or .kind == "needs_task" or .kind == "bound")
            and (.classification == "needs_project" or .classification == "needs_task" or .classification == "bound")
            and (.delivery == "queued" or .delivery == "acked")
            and .lifecycle == "open"
            and .companySlug == $slug
            and (.companyUid | type == "string") and (.companyUid | length > 0)
          then .companySlug else empty end
        ' 2>/dev/null || true)"
    fi
    [ "$VALIDATED_SLUG" = "$DEFAULT_SLUG" ] && emit "$DEFAULT_SLUG" "device_default"
  fi
fi

emit "" "none"
