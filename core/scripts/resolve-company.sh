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
#
# Folder mode (--path <dir>): ask the repo-to-company registry through
# `$HQ_CLI_BIN resolve-company --path <dir> --json` (HQ_CLI_BIN defaults to
# `hq`). Sources: registry (linked folder), registry_miss (not linked), or
# unavailable (CLI missing, failed, timed out, or returned bad output). A
# registry answer is accepted only when it names a real companies/<slug>
# directory. Folder mode never falls back to prompt, session, or device default.

set -uo pipefail

ROOT=""
PROMPT=""
HAVE_PROMPT=0
FOLDER=""
HAVE_FOLDER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 || shift ;;
    --prompt) PROMPT="${2:-}"; HAVE_PROMPT=1; shift 2 || shift ;;
    --path) FOLDER="${2:-}"; HAVE_FOLDER=1; shift 2 || shift ;;
    --help|-h)
      sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) shift ;;
  esac
done

if [ "$HAVE_PROMPT" -eq 0 ] && [ "$HAVE_FOLDER" -eq 0 ] && [ ! -t 0 ]; then
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

# Runs a command with a hard deadline (HQ_RESOLVE_TIMEOUT_MS, default 2000).
run_with_timeout() {
  command -v node >/dev/null 2>&1 || return 127
  node -e '
const { spawn } = require("child_process");
const command = process.argv[1];
const args = process.argv.slice(2);
const timeoutMs = Number(process.env.HQ_RESOLVE_TIMEOUT_MS) || 2000;
if (!command) process.exitCode = 127;
else {
  let child;
  try {
    child = spawn(command, args, { detached: true, stdio: ["ignore", "pipe", "ignore"] });
  } catch {
    process.exitCode = 127;
  }
  if (child) {
    let exited = false;
    let exitStatus = 1;
    let timedOut = false;
    let drainExpired = false;
    let pendingWrites = 0;
    let finished = false;
    let drainTimer;
    let timeoutKillTimer;
    let timeoutFinalTimer;
    let deadlineTimer;
    const signalGroup = (signal) => {
      if (!child.pid) return;
      try {
        if (process.platform === "win32") child.kill(signal);
        else process.kill(-child.pid, signal);
      } catch {}
    };
    const maybeFinish = () => {
      if (finished || !exited || pendingWrites !== 0 || (!drainExpired && !child.stdout.readableEnded)) return;
      finished = true;
      clearTimeout(deadlineTimer);
      clearTimeout(drainTimer);
      clearTimeout(timeoutKillTimer);
      clearTimeout(timeoutFinalTimer);
      signalGroup("SIGTERM");
      process.exitCode = timedOut ? 124 : exitStatus;
      process.exit();
    };
    const writeChunk = (chunk) => {
      pendingWrites += 1;
      process.stdout.write(chunk, () => {
        pendingWrites -= 1;
        maybeFinish();
      });
    };
    child.stdout.on("data", writeChunk);
    child.stdout.once("end", () => {
      drainExpired = true;
      maybeFinish();
    });
    child.once("error", () => {
      exited = true;
      exitStatus = 127;
      drainExpired = true;
      maybeFinish();
    });
    child.once("exit", (code) => {
      exited = true;
      exitStatus = typeof code === "number" ? code : 1;
      signalGroup("SIGTERM");
      if (!child.stdout.readableEnded) {
        drainTimer = setTimeout(() => {
          child.stdout.pause();
          let chunk;
          while ((chunk = child.stdout.read()) !== null) writeChunk(chunk);
          process.stdout.write("", () => {
            drainExpired = true;
            maybeFinish();
          });
        }, 100);
      } else {
        drainExpired = true;
      }
      maybeFinish();
    });
    deadlineTimer = setTimeout(() => {
      timedOut = true;
      signalGroup("SIGTERM");
      timeoutKillTimer = setTimeout(() => signalGroup("SIGKILL"), 100);
      timeoutFinalTimer = setTimeout(() => {
        if (!exited) {
          exited = true;
          exitStatus = 124;
          child.stdout.destroy();
          drainExpired = true;
          maybeFinish();
        }
      }, 1000);
    }, timeoutMs);
  }
}
' "$@"
}

unavailable() {
  printf 'resolve-company: WARNING company registry unavailable (%s); binding personal, not guessing a company\n' "$1" >&2
  emit "" "unavailable"
}

if [ "$HAVE_FOLDER" -eq 1 ]; then
  [ -n "$FOLDER" ] || unavailable "empty --path"
  case "$FOLDER" in
    /*|[A-Za-z]:/*|[A-Za-z]:\\*|\\\\*) ;;
    *)
      caller_cwd="${HQ_CALLER_CWD:-$PWD}"
      caller_cwd="$(cd "$caller_cwd" 2>/dev/null && pwd -P)" || unavailable "caller working directory unavailable"
      if [ "$FOLDER" = "." ]; then FOLDER="$caller_cwd"; else FOLDER="$caller_cwd/$FOLDER"; fi
      ;;
  esac
  cli="${HQ_CLI_BIN:-hq}"
  command -v "$cli" >/dev/null 2>&1 || unavailable "'$cli' not found"
  command -v jq >/dev/null 2>&1 || unavailable "jq not found"
  status=0
  if command -v node >/dev/null 2>&1; then
    out="$(HQ_NO_UPDATE_CHECK=1 HQ_RESOLVE_TIMEOUT_MS="${HQ_RESOLVE_TIMEOUT_MS:-5000}" run_with_timeout "$cli" resolve-company --path "$FOLDER" --json)" || status=$?
  else
    out="$("$cli" resolve-company --path "$FOLDER" --json 2>/dev/null)" || status=$?
  fi
  kind="$(printf '%s' "$out" | jq -r 'if type != "object" then "bad" elif .company == null then "miss" elif (.company | type) == "string" then "hit" else "bad" end' 2>/dev/null | sed 's/\r$//' || printf 'bad')"
  if [ "$status" -ne 0 ] && ! { [ "$status" -eq 1 ] && [ "$kind" = "miss" ]; }; then
    unavailable "'$cli resolve-company' exited $status"
  fi
  case "$kind" in
    miss) emit "" "registry_miss" ;;
    hit) ;;
    *) unavailable "'$cli resolve-company' returned unreadable output" ;;
  esac
  slug="$(printf '%s' "$out" | jq -r '.company' | sed 's/\r$//')"
  case "$slug" in
    ''|personal|_*|*[!A-Za-z0-9_-]*) unavailable "registry returned invalid company '$slug'" ;;
  esac
  if [ ! -d "$ROOT/companies/$slug" ] || [ -L "$ROOT/companies/$slug" ]; then
    unavailable "registry company '$slug' has no companies/$slug directory in $ROOT"
  fi
  emit "$slug" "registry"
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
    wrapped && /^  [A-Za-z][A-Za-z0-9_-]*:/ {
      line = $0; sub(/^[[:space:]]+/, "", line); sub(/:.*/, "", line)
      if (keep(line)) print line
      next
    }
    !wrapped && /^[A-Za-z][A-Za-z0-9_-]*:/ {
      line = $0; sub(/:.*/, "", line)
      if (keep(line)) print line
    }
  ' "$MANIFEST" | sort -u
)"
[ -n "$SLUGS" ] || emit "" "none"

is_known_slug() {
  printf '%s\n' "$SLUGS" | grep -Fx "$1" >/dev/null
}

prompt_slug() {
  local normalized="" match=""
  [ -n "$PROMPT" ] || return 0
  normalized="$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' ' ')"
  match="$(
    # Prompt normalization is case-insensitive, but company IDs are not.
    # Keep a folded match only when exactly one registered ID has that key.
    # If IDs differ only by case, do not guess which tenant the prompt means.
    printf '%s\n' "$SLUGS" | awk -v line="$normalized" '
      BEGIN {
        n = split(line, tok, /[ \t]+/)
        for (i = 1; i <= n; i++) if (tok[i] != "" && !(tok[i] in pos)) pos[tok[i]] = i
        bestSlug = ""; bestLen = 0; bestPos = 0
      }
      {
        slug = $0
        key = tolower(slug)
        if (key in pos) {
          matches[key]++
          candidate[key] = slug
        }
      }
      END {
        for (key in matches) {
          if (matches[key] != 1) continue
          slug = candidate[key]
          len = length(slug); p = pos[key]
          if (len > bestLen || (len == bestLen && p < bestPos)) {
            bestSlug = slug; bestLen = len; bestPos = p
          }
        }
        if (bestSlug != "") print bestSlug
      }
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
