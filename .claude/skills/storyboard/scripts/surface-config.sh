#!/usr/bin/env bash
# surface-config.sh — resolve & persist the /storyboard design-surface preference.
#
# The surface preference is "set once, forget forever": asked on first run,
# persisted, never asked again. Resolution is COMPANY-over-GLOBAL, mirroring
# personal/settings/knowledge-preferences.yaml:
#   1. --surface flag (per-run override; does NOT persist)
#   2. companies/{co}/settings/storyboard.yaml   (per-company override)
#   3. personal/settings/storyboard.yaml         (global default)
#   4. UNSET  → caller runs the first-run AskUserQuestion, then `save`
#
# Surfaces are an ordered, comma-separated list drawn from: paper, html, figma.
#
# Usage:
#   surface-config.sh resolve [--company <co>] [--surface <override>]
#   surface-config.sh save --surface <list> [--company <co>] [--figma true|false]
#
# `resolve` prints two lines to stdout:
#   surface=<comma-list|UNSET>
#   figma=<true|false>
# plus an `origin=<flag|company|global|unset>` line so the caller can tell the
# user where the value came from (and whether to offer to persist it).

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(pwd)}"
GLOBAL_FILE="$HQ_ROOT/personal/settings/storyboard.yaml"

read_field() { # <file> <key> -> value or empty
  [ -f "$1" ] || return 0
  grep -E "^[[:space:]]*$2:" "$1" 2>/dev/null | head -1 | sed -E "s/^[[:space:]]*$2:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^['\"]//; s/['\"]$//" || true
}

cmd="${1:-}"; shift || true
company=""; surface=""; figma=""
while [ $# -gt 0 ]; do
  case "$1" in
    --company) company="${2:-}"; shift 2 ;;
    --surface) surface="${2:-}"; shift 2 ;;
    --figma)   figma="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

company_file() { [ -n "$company" ] && echo "$HQ_ROOT/companies/$company/settings/storyboard.yaml" || echo ""; }

case "$cmd" in
  resolve)
    if [ -n "$surface" ]; then
      echo "surface=$surface"; echo "figma=${figma:-true}"; echo "origin=flag"; exit 0
    fi
    cf="$(company_file)"
    if [ -n "$cf" ] && [ -f "$cf" ]; then
      v="$(read_field "$cf" defaultSurface)"
      if [ -n "$v" ]; then
        echo "surface=$v"; echo "figma=$(read_field "$cf" figmaReferences | grep -qi true && echo true || echo false)"; echo "origin=company"; exit 0
      fi
    fi
    if [ -f "$GLOBAL_FILE" ]; then
      v="$(read_field "$GLOBAL_FILE" defaultSurface)"
      if [ -n "$v" ]; then
        echo "surface=$v"; echo "figma=$(read_field "$GLOBAL_FILE" figmaReferences | grep -qi true && echo true || echo false)"; echo "origin=global"; exit 0
      fi
    fi
    echo "surface=UNSET"; echo "figma=false"; echo "origin=unset"; exit 0
    ;;

  save)
    [ -n "$surface" ] || { echo "save: --surface required" >&2; exit 2; }
    fig="${figma:-true}"
    cf="$(company_file)"
    target="$GLOBAL_FILE"; scope="global default"
    if [ -n "$cf" ]; then target="$cf"; scope="company override ($company)"; fi
    mkdir -p "$(dirname "$target")"
    cat > "$target" <<YAML
# HQ /storyboard design-surface preference — $scope
#
# Set once, forgotten forever: /storyboard asks on first run, writes this file,
# and never asks again. Override a single run with: /storyboard --surface <s>
# Resolution is COMPANY-over-GLOBAL (see personal/settings/knowledge-preferences.yaml).
#
# defaultSurface: ordered, comma-separated. Any of: paper, html, figma.
#   paper = Paper MCP canvas (multi-screen flows, storyboards)
#   html  = designed HTML previewed via /deploy (web mockups, shareable link)
#   figma = Figma references / export specs
version: 1
defaultSurface: $surface
figmaReferences: $fig
YAML
    echo "saved=$target"
    ;;

  *)
    echo "usage: surface-config.sh resolve|save [--company <co>] [--surface <list>] [--figma true|false]" >&2
    exit 2
    ;;
esac
