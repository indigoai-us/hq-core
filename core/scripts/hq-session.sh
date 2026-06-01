#!/usr/bin/env bash
# hq-core: public
# hq-session.sh — read/write the current session's metadata.
#
# Usage:
#   core/scripts/hq-session.sh current               # print current session_id (or empty)
#   core/scripts/hq-session.sh path                  # print path to current meta.yaml
#   core/scripts/hq-session.sh get <key>             # read a key from meta.yaml
#   core/scripts/hq-session.sh set <key> <value>     # set/replace a top-level key
#
# Session bootstrapping is owned by .claude/hooks/master-hook.sh, which
# writes workspace/sessions/.current and ensures
# workspace/sessions/<session_id>/meta.yaml exists on every hook event.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SESSIONS_DIR="$REPO_ROOT/workspace/sessions"
CURRENT_FILE="$SESSIONS_DIR/.current"

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

current_id() {
  [ -f "$CURRENT_FILE" ] || return 0
  tr -d '[:space:]' < "$CURRENT_FILE"
}

current_meta() {
  local id
  id="$(current_id)"
  [ -n "$id" ] || return 0
  printf '%s/%s/meta.yaml' "$SESSIONS_DIR" "$id"
}

cmd_current() {
  current_id
}

cmd_path() {
  current_meta
}

cmd_get() {
  local key="${1:-}"
  [ -n "$key" ] || { echo "usage: hq-session.sh get <key>" >&2; exit 1; }
  local meta
  meta="$(current_meta)"
  [ -n "$meta" ] && [ -f "$meta" ] || return 0
  awk -v k="$key" '
    $1 == k":" {
      sub(/^[^:]+:[[:space:]]*/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$meta"
}

cmd_set() {
  local key="${1:-}" value="${2:-}"
  [ -n "$key" ] && [ $# -ge 2 ] || { echo "usage: hq-session.sh set <key> <value>" >&2; exit 1; }

  local id meta
  id="$(current_id)"
  if [ -z "$id" ]; then
    echo "hq-session: no current session (workspace/sessions/.current missing); is master-hook installed?" >&2
    exit 1
  fi
  meta="$SESSIONS_DIR/$id/meta.yaml"
  mkdir -p "$(dirname "$meta")"
  [ -f "$meta" ] || : > "$meta"

  # Capture the prior value so we only surface policies when it actually changes.
  local prev=""
  prev="$(cmd_get "$key" 2>/dev/null || true)"

  local tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN { found = 0 }
    $1 == k":" { print k": " v; found = 1; next }
    { print }
    END { if (!found) print k": " v }
  ' "$meta" > "$tmp"
  mv "$tmp" "$meta"

  # When a company is bound (or rebound) mid-session, surface that company's
  # hard-enforcement policies into this Bash tool result. SessionStart only
  # injects company policies for the company known *at start*; binding a
  # company afterward (this path) otherwise surfaces nothing, so an agent can
  # do company infra/deploy/credential work blind to hard rules. This closes
  # that gap. Emits policy text only — never secrets.
  if [ "$key" = "company_slug" ] && [ -n "$value" ] && [ "$value" != "$prev" ]; then
    emit_company_hard_policies "$value"
  fi
}

# Print the hard-enforcement section of a company's policy digest, if present.
# Reuses the digest shape produced by core/scripts/build-policy-digest.sh and
# emitted by .claude/hooks/load-policies-for-session.sh.
emit_company_hard_policies() {
  local co="$1"
  local digest="$REPO_ROOT/companies/$co/policies/_digest.md"
  [ -f "$digest" ] || return 0
  printf '\n<company-policy-digest co="%s">\n' "$co"
  printf '# %s hard-enforcement policies (auto-surfaced on company bind)\n' "$co"
  printf '> Company context just bound mid-session. These HARD rules now apply.\n'
  printf '> Full text: `companies/%s/policies/{slug}.md` (or `qmd get -c %s {slug}`).\n\n' "$co" "$co"
  awk '
    /^## Hard-enforcement/ { in_body = 1; next }
    /^## Soft-enforcement/ { in_body = 0 }
    in_body { print }
  ' "$digest"
  printf '</company-policy-digest>\n'
}

sub="${1:-}"
shift || true
case "$sub" in
  current) cmd_current "$@" ;;
  path)    cmd_path "$@" ;;
  get)     cmd_get "$@" ;;
  set)     cmd_set "$@" ;;
  ""|-h|--help|help) usage ;;
  *) echo "hq-session: unknown subcommand '$sub'" >&2; usage >&2; exit 1 ;;
esac
