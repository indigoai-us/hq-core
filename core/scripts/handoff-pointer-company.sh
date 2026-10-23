#!/usr/bin/env bash
# Print the single company slug recorded by the latest handoff, or nothing.
#
# Usage: handoff-pointer-company.sh [pointer-path]
#   pointer-path defaults to "$HQ_ROOT/workspace/threads/handoff.json".
#
# Accepted shapes, first match wins:
#   1. pointer .company as a string
#   2. pointer .company or .companies as an array with exactly one entry
#   3. the linked thread's .metadata.company (string or one-entry array),
#      for pointers written before the finalizer recorded company context
# Multiple companies, missing files, or invalid slugs print nothing. Exit 0
# in all of those cases so callers can fall through to the next tier.
set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(pwd)}"
POINTER="${1:-$HQ_ROOT/workspace/threads/handoff.json}"

command -v jq >/dev/null 2>&1 || exit 0
[[ -f "$POINTER" ]] || exit 0

# shellcheck disable=SC2016
single='if type == "string" then . elif type == "array" and length == 1 and (.[0] | type) == "string" then .[0] else empty end'

slug="$(jq -r "(.company // empty | $single), (.companies // empty | $single)" "$POINTER" 2>/dev/null | head -n1 || true)"

if [[ -z "$slug" ]]; then
  thread_path="$(jq -r '.thread_path // empty' "$POINTER" 2>/dev/null || true)"
  if [[ -n "$thread_path" ]]; then
    [[ "$thread_path" == /* ]] || thread_path="$HQ_ROOT/$thread_path"
    if [[ -f "$thread_path" ]]; then
      slug="$(jq -r ".metadata.company // empty | $single" "$thread_path" 2>/dev/null | head -n1 || true)"
    fi
  fi
fi

[[ "$slug" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || exit 0
printf '%s\n' "$slug"
