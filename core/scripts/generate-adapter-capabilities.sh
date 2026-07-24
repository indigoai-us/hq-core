#!/usr/bin/env bash
# hq-core: public
# generate-adapter-capabilities.sh - US-504 capability snapshot generator.
#
# WHY THIS EXISTS. A capability descriptor otherwise lives only as bash on an
# agent box. hq-pro control-plane TypeScript cannot source a shell function, so
# without a checked-in artifact there is no mechanism by which the control plane
# can ever know that (say) grok declares plan_mode=absent. This script renders
# every adapter's descriptor into a durable JSON file that both sides can read.
#
# DETERMINISM IS A CONTRACT, NOT A NICETY. The snapshot is drift-checked in CI
# by regenerating it and diffing against the checked-in copy, so any nondeterminism
# here -- a timestamp, a hostname, an absolute path, unstable key order -- turns
# into a permanently red build that no one can fix by editing the file. Keys are
# emitted in a fixed order; nothing environment-derived is written.
#
# Usage:
#   bash core/scripts/generate-adapter-capabilities.sh            # write in place
#   bash core/scripts/generate-adapter-capabilities.sh --stdout   # print only
#   bash core/scripts/generate-adapter-capabilities.sh -o FILE    # write elsewhere

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/core/scripts/lib"
ADAPTER_SH="$LIB/provider-adapter.sh"
DEFAULT_OUT="$LIB/provider-adapters/capabilities.generated.json"

OUT="$DEFAULT_OUT"
TO_STDOUT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stdout) TO_STDOUT=1; shift ;;
    -o|--out) OUT="${2:?-o requires a path}"; shift 2 ;;
    -h|--help) sed -n '1,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "generate-adapter-capabilities: unknown argument: $1" >&2; exit 1 ;;
  esac
done

# shellcheck disable=SC1090
# Loaded by path; provider files are resolved by id at runtime.
. "$ADAPTER_SH"

# Fixed key order. NOT the order the adapter happens to echo them in -- an
# adapter reordering its own output must not churn the snapshot.
CAPABILITY_KEYS=(
  system_prompt
  resume
  hooks
  plan_mode
  durable_writes
  telegram_eligible
  usage_source
)

# _json_escape <string> - minimal escaper. Descriptor values are drawn from
# fixed enums (no quotes, no backslashes, no control characters), so this only
# has to be correct for that alphabet; it is here so a future enum extension
# cannot silently emit broken JSON.
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# _lookup <key> <descriptor-text> - value for key, empty when absent.
# Deliberately NOT an associative array: hq-core shell must run on bash 3.2
# (the macOS system bash), which has no `declare -A`. See
# core/scripts/lint-shell-portability.sh.
_lookup() {
  local key="$1" descriptor="$2" line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "${line%%=*}" == "$key" ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <<EOF
$descriptor
EOF
  return 0
}

_render() {
  local provider key value descriptor first_provider=1 first_key

  printf '{\n'
  printf '  "contractVersion": "%s",\n' "$(_json_escape "$HQ_ADAPTER_CONTRACT_VERSION")"
  printf '  "providers": {\n'

  for provider in $HQ_ADAPTER_PROVIDERS; do
    if ! hq_adapter_load "$provider" >/dev/null 2>&1; then
      echo "generate-adapter-capabilities: cannot load adapter: $provider" >&2
      return 1
    fi

    # Read the descriptor once; key ORDER below is OURS, not the adapter's, so
    # an adapter reordering its own echoes cannot churn the snapshot.
    descriptor="$(hq_adapter_capabilities)"

    [[ "$first_provider" -eq 1 ]] || printf ',\n'
    first_provider=0
    printf '    "%s": {\n' "$(_json_escape "$provider")"

    first_key=1
    for key in "${CAPABILITY_KEYS[@]}"; do
      value="$(_lookup "$key" "$descriptor")"
      if [[ -z "$value" ]]; then
        echo "generate-adapter-capabilities: $provider missing capability $key" >&2
        return 1
      fi
      [[ "$first_key" -eq 1 ]] || printf ',\n'
      first_key=0
      printf '      "%s": "%s"' "$(_json_escape "$key")" "$(_json_escape "$value")"
    done
    printf '\n    }'
  done

  printf '\n  }\n}\n'
}

if [[ "$TO_STDOUT" -eq 1 ]]; then
  _render
else
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  _render > "$tmp"
  mv "$tmp" "$OUT"
  trap - EXIT
  echo "generate-adapter-capabilities: wrote $OUT"
fi
