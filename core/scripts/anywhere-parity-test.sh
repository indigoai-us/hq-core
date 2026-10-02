#!/usr/bin/env bash
# anywhere-parity-test.sh — prove HQ works from a given repo in a headless runtime.
#
# Runs one headless session (claude -p or codex exec) with --repo as its cwd
# and asserts four outcomes:
#   startwork  /startwork resolves the company mapped for that repo
#   policy     writing a cross-company path in HQ is blocked
#   run        /run dispatches a worker and the worker reports back
#   journal    a journal entry for the session lands under the mapped
#              company's project journal in HQ
#
# Usage:
#   bash core/scripts/anywhere-parity-test.sh --runtime claude|codex --repo PATH
#        [--company SLUG] [--worker ID] [--hq-root PATH] [--json]
#
# Company mapping: --company wins; otherwise the repo is looked up in the
# repos: lists of companies/manifest.yaml. The HQ root maps to the device
# default company when resolve-company.sh reports one for a fresh session,
# else "personal". An unmapped repo fails every assertion.
#
# The runtime starts with every session-identity variable (HQ_SESSION_ID,
# CLAUDE_CODE_SESSION_ID, HQ_PARENT_SESSION_ID, HQ_SPAWN_COMPANY, ...) removed, so it gets its own session instead of
# inheriting the caller's company binding. The policy probe targets a company
# other than the expected one; a probe that lands is deleted, and its path is
# reported if deletion fails. The journal check looks under the company the
# session reported binding.
#
# PARITY_RUNNER (tests only): a command run instead of the real runtime as
#   $PARITY_RUNNER <runtime> <prompt>  with cwd = --repo.
#
# Output: one "PASS|FAIL <name> — <detail>" line per assertion, or one JSON
# object per line with --json. Exit 0 if all pass, 1 if any fail, 2 usage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANCHOR="$(cd "$SCRIPT_DIR/../.." && pwd)"

RUNTIME="" REPO="" COMPANY="" WORKER="" HQ="" JSON=0
usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --runtime) RUNTIME="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --company) COMPANY="${2:-}"; shift 2 ;;
    --worker) WORKER="${2:-}"; shift 2 ;;
    --hq-root) HQ="${2:-}"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

case "$RUNTIME" in claude|codex) ;; *) printf 'need --runtime claude|codex\n' >&2; usage ;; esac
[ -n "$REPO" ] && [ -d "$REPO" ] || { printf 'need --repo <existing dir>\n' >&2; usage; }
REPO="$(cd "$REPO" && pwd -P)"

if [ -z "$HQ" ]; then
  if [ -n "${HQ_ROOT:-}" ]; then
    HQ="$HQ_ROOT"
  else
    HQ="$(bash "$SCRIPT_DIR/resolve-hq-root.sh" --anchor "$ANCHOR" 2>/dev/null)" || HQ=""
  fi
fi
[ -n "$HQ" ] && [ -d "$HQ" ] && HQ="$(cd "$HQ" && pwd -P)"

FAILED=0
emit() { # emit PASS|FAIL name detail
  local verdict="$1" name="$2" detail="$3" esc
  [ "$verdict" = PASS ] || FAILED=1
  if [ "$JSON" = 1 ]; then
    esc="$(printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\t' '  ')"
    printf '{"assertion":"%s","result":"%s","runtime":"%s","repo":"%s","detail":"%s"}\n' \
      "$name" "$verdict" "$RUNTIME" "$REPO" "$esc"
  else
    printf '%s %s — %s\n' "$verdict" "$name" "$detail"
  fi
}

# manifest_company_for <hq> <repo-abs> — print the company whose repos: list holds repo.
manifest_company_for() {
  local hq="$1" repo="$2" rel
  [ -f "$hq/companies/manifest.yaml" ] || return 1
  case "$repo" in "$hq"/*) rel="${repo#"$hq"/}" ;; *) rel="$repo" ;; esac
  awk -v rel="$rel" -v abs="$repo" '
    /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { co=$1; sub(":", "", co); inrepos=0; next }
    /^    repos:/ { inrepos=1; next }
    /^    [A-Za-z_]+:/ { inrepos=0 }
    inrepos && /^ +- / { r=$0; sub(/^ +- +/, "", r); gsub(/["'\''[:space:]]/, "", r)
      if (r == rel || r == abs) { print co; exit } }
  ' "$hq/companies/manifest.yaml"
}

# Session and dispatch variables a child runtime must not inherit. An inherited
# HQ_SESSION_ID (core/scripts/lib/session-id.sh) makes the child use the
# caller's session metadata; HQ_PARENT_SESSION_ID / HQ_SPAWN_COMPANY /
# HQ_AGENT_COMPANY_DIR (core/scripts/lib/session-auto-bind.sh) make it bind the
# caller's company as a spawned child. Either way the control would measure the
# caller, not what a fresh session in --repo binds.
SESSION_VARS="HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID HQ_PARENT_SESSION_ID HQ_SPAWN_COMPANY HQ_AGENT_COMPANY_DIR"
UNSET_ARGS=()
for v in $SESSION_VARS; do UNSET_ARGS+=(-u "$v"); done

NONCE="parity-$(date +%Y%m%d%H%M%S)-$$-$RANDOM"

# hq_root_company <hq> — the company a fresh session at the HQ root binds:
# the device default if resolve-company.sh reports one, else personal.
hq_root_company() {
  local hq="$1" json co
  if [ -f "$hq/core/scripts/resolve-company.sh" ]; then
    json="$(cd "$hq" && env "${UNSET_ARGS[@]}" HQ_SESSION_ID="parity-expect-$NONCE" \
      bash "$hq/core/scripts/resolve-company.sh" --root "$hq" --prompt "" 2>/dev/null </dev/null)" || json=""
    case "$json" in
      *'"source":"device_default"'*)
        co="$(printf '%s' "$json" | sed -n 's/.*"company":"\([A-Za-z0-9_.-]*\)".*/\1/p')"
        [ -n "$co" ] && { printf '%s\n' "$co"; return 0; } ;;
    esac
  fi
  printf 'personal\n'
}

# other_company <hq> <exclude> — first manifest company that is not <exclude>.
other_company() {
  awk -v ex="$2" '
    /^companies:/ { inco=1; next }
    inco && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { co=$1; sub(":", "", co); if (co != ex) { print co; exit } }
  ' "$1/companies/manifest.yaml" 2>/dev/null
}

EXPECTED="$COMPANY"
if [ -z "$EXPECTED" ] && [ -n "$HQ" ]; then
  if [ "$REPO" = "$HQ" ]; then EXPECTED="$(hq_root_company "$HQ")"; else EXPECTED="$(manifest_company_for "$HQ" "$REPO")"; fi
fi
OTHER=""; [ -n "$HQ" ] && OTHER="$(other_company "$HQ" "$EXPECTED")"
[ -n "$OTHER" ] || OTHER="parity-other"
PROBE_REL="companies/$OTHER/knowledge/$NONCE.txt"
# The probe path names the other company, and /startwork resolves a company from
# any slug in the prompt (resolve-company.sh --prompt). Keep the path out of the
# prompt so the probe cannot choose the session's company.
PROBE_PATH_FILE="$(mktemp -t anywhere-parity-probe.XXXXXX)"
printf '%s\n' "$PROBE_REL" >"$PROBE_PATH_FILE"
OUT="$(mktemp -t anywhere-parity-out.XXXXXX)"
trap 'rm -f "$OUT" "$PROBE_PATH_FILE"' EXIT

PROMPT="HQ parity probe $NONCE. Non-interactive: do not ask questions.
1. Run /startwork for this repo, then print exactly one line: HQ_COMPANY=<resolved company slug>, or HQ_COMPANY=personal if no company is bound. Do not bind or switch companies after this step.
2. The file $PROBE_PATH_FILE holds a path relative to the HQ root (the HQ root, not this repo). Without binding any company, try to create that file in HQ containing $NONCE. If HQ blocks it, print exactly: HQ_POLICY_BLOCKED=$NONCE
3. Run /run ${WORKER:-<any available worker for that company>} and ask the worker to reply with the token $NONCE; then print exactly: HQ_WORKER_REPORT=<the token the worker returned>
4. Write a session journal entry containing $NONCE under that company's project journal in HQ (companies/<company>/projects/<project>/journal/)."

if [ -n "$EXPECTED" ]; then
  if [ -n "${PARITY_RUNNER:-}" ]; then
    (cd "$REPO" && env "${UNSET_ARGS[@]}" CLAUDE_HEADLESS=1 HQ_PARITY_NONCE="$NONCE" "$PARITY_RUNNER" "$RUNTIME" "$PROMPT") >"$OUT" 2>&1
  elif [ "$RUNTIME" = claude ]; then
    (cd "$REPO" && env "${UNSET_ARGS[@]}" CLAUDE_HEADLESS=1 claude -p "$PROMPT" --permission-mode bypassPermissions) >"$OUT" 2>&1
  else
    (cd "$REPO" && env "${UNSET_ARGS[@]}" CLAUDE_HEADLESS=1 codex exec \
      --dangerously-bypass-hook-trust --sandbox danger-full-access -C "$REPO" "$PROMPT") >"$OUT" 2>&1
  fi
  RC=$?
else
  RC=-1
fi

if [ -z "$EXPECTED" ]; then
  why="repo is not mapped to any company in companies/manifest.yaml (HQ root: ${HQ:-unresolved})"
  for a in startwork policy run journal; do emit FAIL "$a" "$why"; done
  exit 1
fi

got="$(grep -o 'HQ_COMPANY=[A-Za-z0-9_.-]*' "$OUT" | tail -1 | cut -d= -f2)"
if [ "$got" = "$EXPECTED" ]; then emit PASS startwork "resolved $got"
else emit FAIL startwork "expected $EXPECTED, got '${got:-none}' (runtime exit $RC)"; fi

if [ -e "$HQ/$PROBE_REL" ]; then
  rm -f "$HQ/$PROBE_REL" 2>/dev/null
  if [ -e "$HQ/$PROBE_REL" ]; then
    emit FAIL policy "cross-company write landed at $PROBE_REL and could not be removed: $HQ/$PROBE_REL"
  else
    emit FAIL policy "cross-company write landed at $PROBE_REL (bound '${got:-none}'); probe removed"
  fi
elif [ -n "$got" ] && [ "$got" = "$OTHER" ]; then
  emit FAIL policy "session bound '$got', the probe's own target company, so no block was expected"
elif grep -q "HQ_POLICY_BLOCKED=$NONCE" "$OUT"; then emit PASS policy "write to $PROBE_REL blocked"
else emit FAIL policy "no block reported for $PROBE_REL"; fi

if grep -q "HQ_WORKER_REPORT=$NONCE" "$OUT"; then emit PASS run "worker returned $NONCE"
else emit FAIL run "no worker report carrying $NONCE"; fi

BOUND="${got:-$EXPECTED}"
JDIRS=("$HQ/companies/$BOUND/projects")
[ "$BOUND" = personal ] && JDIRS+=("$HQ/personal/projects")
hit="$(find "${JDIRS[@]}" -path '*/journal/*' -type f 2>/dev/null \
  | while IFS= read -r f; do grep -l "$NONCE" "$f" 2>/dev/null; done | head -1)"
if [ -n "$hit" ]; then emit PASS journal "${hit#"$HQ"/}"
else emit FAIL journal "no journal under companies/$BOUND/projects/*/journal mentions $NONCE"; fi

if [ "$FAILED" = 1 ]; then
  KEPT="$(mktemp -t anywhere-parity-transcript.XXXXXX)" && cp "$OUT" "$KEPT" \
    && printf 'anywhere-parity: runtime transcript kept at %s\n' "$KEPT" >&2
fi
exit "$FAILED"
