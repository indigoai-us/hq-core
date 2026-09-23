#!/usr/bin/env bash
# knowledge-prefs.sh — resolve a company's knowledge-store preference.
#
# Usage: knowledge-prefs.sh get <company> <field>
#
# Resolution, per field, first match wins:
#   1. companies/<company>/settings/knowledge/preferences.yaml
#   2. personal/settings/knowledge-preferences.yaml
#   3. built-in default (below)
#
# Built-in defaults:
#   signals_enabled   true    readers (/signals) look for signals
#   ontology_enabled  true    readers (/ontology) look for ontology
#   signals_capture   false   session-close skills write signal candidates
#   ontology_capture  false   session-close skills write entity candidates
#   meeting_notes_source hq-native
#   notetaker         recall
#
# Capture is opt-in per company, so installs that never set it see no change.
# Only top-level scalar keys are read; a commented-out line does not count.
# Exits 2 on bad usage, unknown field, or missing company directory.
set -euo pipefail

usage() { echo "usage: knowledge-prefs.sh get <company> <field>" >&2; exit 2; }
[ "${1:-}" = "get" ] || usage
co="${2:-}"; field="${3:-}"
[ -n "$co" ] && [ -n "$field" ] || usage

root="${HQ_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"

case "$field" in
  signals_enabled|ontology_enabled) default=true ;;
  signals_capture|ontology_capture) default=false ;;
  meeting_notes_source) default=hq-native ;;
  notetaker) default=recall ;;
  *) echo "knowledge-prefs: unknown field '$field'" >&2; exit 2 ;;
esac

[ -d "$root/companies/$co" ] || { echo "knowledge-prefs: no company '$co'" >&2; exit 2; }

read_field() {
  local file="$1"
  [ -f "$file" ] || return 1
  awk -v k="$field" '
    $0 ~ "^"k":" {
      sub("^"k":[[:space:]]*", ""); sub("[[:space:]]+#.*$", ""); gsub(/^["\x27]|["\x27]$/, "")
      if (length($0)) { print; found=1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

read_field "$root/companies/$co/settings/knowledge/preferences.yaml" \
  || read_field "$root/personal/settings/knowledge-preferences.yaml" \
  || echo "$default"
