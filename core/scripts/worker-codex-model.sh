#!/usr/bin/env bash
# worker-codex-model.sh — resolve the Codex model for a worker, honouring
# company and personal overrides of a core worker without editing core/.
#
# Usage:
#   worker-codex-model.sh [--hq-root <dir>] [--company <slug>] [--story-hint <model>] <worker-id>
#
# Prints two tab-separated fields on stdout: <model> <source>
#   source is one of: story-hint, company-override, personal-override, worker
# Exit 2 when the worker profile has no execution.codex_model and nothing
# overrides it (a configuration error), or on bad arguments.
#
# Precedence (first non-empty wins):
#   1. --story-hint (the prd story's codex_model_hint)
#   2. companies/<company>/workers/<id>/overrides.yaml, then .../worker.yaml
#   3. personal/workers/<id>/overrides.yaml, then .../worker.yaml
#   4. the core profile: core/workers/public/dev-team/<id>/worker.yaml,
#      then core/workers/public/<id>/worker.yaml
# Steps 2 and 3 apply only when a core profile exists. A worker that lives
# only under companies/ or personal/ is the user's own profile and is read
# directly (company first, then personal).
#
# Only execution.codex_model is overridden. execution.codex_flags always come
# from the selected profile; an override file's codex_flags are ignored.
# An override file holds just the fields it changes, e.g.
#   execution:
#     codex_model: gpt-6-astra
set -euo pipefail

die() { echo "worker-codex-model: $1" >&2; exit "${2:-2}"; }

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
COMPANY=""; HINT=""; WORKER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hq-root) [ $# -ge 2 ] || die "--hq-root needs a dir"; HQ_ROOT="$2"; shift 2 ;;
    --company) [ $# -ge 2 ] || die "--company needs a slug"; COMPANY="$2"; shift 2 ;;
    --story-hint) [ $# -ge 2 ] || die "--story-hint needs a model"; HINT="$2"; shift 2 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$WORKER" ] || die "only one worker id"; WORKER="$1"; shift ;;
  esac
done
[ -n "$WORKER" ] || die "usage: worker-codex-model.sh [--company <slug>] [--story-hint <model>] <worker-id>"
case "$WORKER" in */*|.*|*..*) die "invalid worker id: $WORKER" ;; esac
case "$COMPANY" in */*|.*|*..*) die "invalid company slug: $COMPANY" ;; esac

# exec_field <yaml> <key> -> execution.<key>, quotes and trailing comments stripped.
exec_field() {
  [ -f "$1" ] || return 0
  awk -v key="$2" '
    /^[^[:space:]#]/ { inexec = ($0 ~ /^execution:[[:space:]]*$/); next }
    inexec && $0 ~ "^[[:space:]]+" key ":" {
      v = $0; sub("^[[:space:]]+" key ":[[:space:]]*", "", v)
      sub(/[[:space:]]+#.*$/, "", v); sub(/[[:space:]]+$/, "", v)
      gsub(/^["'\'']|["'\'']$/, "", v); print v; exit
    }' "$1"
}

# scope_model <dir> -> codex_model from overrides.yaml, else worker.yaml
scope_model() {
  local m
  m="$(exec_field "$1/overrides.yaml" codex_model)"
  [ -n "$m" ] || m="$(exec_field "$1/worker.yaml" codex_model)"
  printf '%s' "$m"
}

if [ -n "$HINT" ]; then printf '%s\tstory-hint\n' "$HINT"; exit 0; fi

CORE=""
for c in "$HQ_ROOT/core/workers/public/dev-team/$WORKER/worker.yaml" "$HQ_ROOT/core/workers/public/$WORKER/worker.yaml"; do
  if [ -f "$c" ]; then CORE="$c"; break; fi
done

COMPANY_DIR=""
[ -z "$COMPANY" ] || COMPANY_DIR="$HQ_ROOT/companies/$COMPANY/workers/$WORKER"
PERSONAL_DIR="$HQ_ROOT/personal/workers/$WORKER"

if [ -n "$CORE" ]; then
  if [ -n "$COMPANY_DIR" ]; then
    m="$(scope_model "$COMPANY_DIR")"
    if [ -n "$m" ]; then printf '%s\tcompany-override\n' "$m"; exit 0; fi
  fi
  m="$(scope_model "$PERSONAL_DIR")"
  if [ -n "$m" ]; then printf '%s\tpersonal-override\n' "$m"; exit 0; fi
  m="$(exec_field "$CORE" codex_model)"
else
  m=""
  if [ -n "$COMPANY_DIR" ] && [ -f "$COMPANY_DIR/worker.yaml" ]; then
    m="$(exec_field "$COMPANY_DIR/worker.yaml" codex_model)"
  elif [ -f "$PERSONAL_DIR/worker.yaml" ]; then
    m="$(exec_field "$PERSONAL_DIR/worker.yaml" codex_model)"
  fi
fi
[ -n "$m" ] || die "worker $WORKER has no execution.codex_model (configuration error)"
printf '%s\tworker\n' "$m"
