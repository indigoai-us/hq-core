#!/usr/bin/env bash
# pack-installed.sh — canonical check: is an hq content pack installed on this HQ?
#
# Usage: pack-installed.sh <pack-name> [--explain]
#   bash core/scripts/pack-installed.sh hq-pack-engineering && echo installed
#
# A pack is "installed" when core/packages/<pack-name>/package.yaml exists —
# the exact marker scan-packages.sh keys on before wiring a pack's
# contributions. Skills use this to keep completion output pack-aware: e.g.
# /plan Step 9 only presents /run-project + /execute-task as runnable when
# hq-pack-engineering is present, and leads with the pack's install line when
# it is not (the DEV-1716 "Unknown command: /run-project" dead-end).
#
# CONTRACT:
#   exit 0 — pack installed (manifest present)
#   exit 1 — pack not installed
#   exit 2 — usage error
#
# HQ_ROOT overrides the instance root; defaults to cwd (same as scan-packages.sh).

set -euo pipefail

PACK=""
EXPLAIN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --explain) EXPLAIN=1; shift ;;
    -h|--help)
      echo "usage: pack-installed.sh <pack-name> [--explain]"
      echo "exit 0 iff core/packages/<pack-name>/package.yaml exists."
      exit 0 ;;
    -*)
      echo "pack-installed: unknown flag '$1' (usage: pack-installed.sh <pack-name> [--explain])" >&2
      exit 2 ;;
    *)
      if [[ -n "$PACK" ]]; then
        echo "pack-installed: expected exactly one pack name (usage: pack-installed.sh <pack-name> [--explain])" >&2
        exit 2
      fi
      PACK="$1"; shift ;;
  esac
done

if [[ -z "$PACK" ]]; then
  echo "pack-installed: missing pack name (usage: pack-installed.sh <pack-name> [--explain])" >&2
  exit 2
fi

HQ_ROOT="${HQ_ROOT:-$(pwd)}"
MANIFEST="$HQ_ROOT/core/packages/$PACK/package.yaml"

if [[ -f "$MANIFEST" ]]; then
  if [[ "$EXPLAIN" == "1" ]]; then
    echo "installed: $PACK ($MANIFEST)"
  fi
  exit 0
fi

if [[ "$EXPLAIN" == "1" ]]; then
  echo "not installed: $PACK — no manifest at $MANIFEST"
  echo "install with: hq install github:indigoai-us/hq-packages#packages/$PACK"
fi
exit 1
