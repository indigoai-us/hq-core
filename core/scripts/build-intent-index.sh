#!/usr/bin/env bash
# build-intent-index.sh — generate the always-on HQ intent index.
#
# One line per capability so a session can route a plain-language ask to the
# right skill, integration, or built-in tool on turn one without reading the
# skill bodies. Generated, never hand-edited.
#
# Usage:
#   core/scripts/build-intent-index.sh [--root <hq-root>] [--out <file>]
#                                      [--scope shipped|local] [--company <slug>]
#                                      [--check]
#
#   --scope shipped  (default) release-safe: only skills that are real
#                    directories under .claude/skills (no personal symlinks,
#                    no company bridge skills). No company slugs in the output.
#                    Default out: core/settings/intent-index.yaml
#   --scope local    this machine: every skill including personal and company
#                    bridges, plus the usable integrations and workers of
#                    --company when given. Default out:
#                    workspace/orchestrator/intent-index.yaml
#   --check          exit 1 when the current --out differs from a fresh build.
#
# Python-free (bash + awk + sort). Idempotent: identical inputs give a
# byte-identical file, so a regenerate is a no-op commit.
set -euo pipefail

# Byte semantics everywhere (awk substr, glob order) so macOS and Linux CI
# produce the same file from the same inputs.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
OUT=""
SCOPE="shipped"
COMPANY=""
CHECK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --scope) SCOPE="$2"; shift 2 ;;
    --company) COMPANY="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "build-intent-index: unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$SCOPE" in shipped|local) ;; *) echo "build-intent-index: --scope must be shipped or local" >&2; exit 2 ;; esac

SKILLS_DIR="$ROOT/.claude/skills"
[ -d "$SKILLS_DIR" ] || { echo "build-intent-index: no skills dir at $SKILLS_DIR" >&2; exit 1; }

if [ -z "$OUT" ]; then
  if [ "$SCOPE" = "shipped" ]; then OUT="$ROOT/core/settings/intent-index.yaml"
  else OUT="$ROOT/workspace/orchestrator/intent-index.yaml"; fi
fi

# yaml_q: double-quote a scalar for YAML (escape backslash and double quote).
yaml_q() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"; }

# skill_lines: one awk pass over every SKILL.md. Reads the leading --- block,
# emits one entry per skill with name, use (description, 160 chars), args
# (argument-hint) and triggers when present. Values are YAML double-quoted.
skill_lines() {
  local files=() d name
  for d in "$SKILLS_DIR"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    case "$name" in _*) continue ;; esac
    [ -f "$d/SKILL.md" ] || continue
    if [ "$SCOPE" = "shipped" ]; then
      [ -L "${d%/}" ] && continue
      case "$name" in *:*) continue ;; esac
    fi
    files+=("${d%/}/SKILL.md")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  awk '
    function q(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\"" }
    function unq(v) {
      sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      gsub(/\\"/, "\"", v)
      return v
    }
    function flush() {
      if (name == "") return
      if (desc == "") desc = "(no description)"
      gsub(/[\r\n]+/, " ", desc)
      if (length(desc) > 160) desc = substr(desc, 1, 160)
      printf "  - name: %s\n    use: %s\n", q("/" name), q(desc)
      if (hint != "") printf "    args: %s\n", q(hint)
      if (trig != "") printf "    triggers: %s\n", q(trig)
      name = ""; desc = ""; hint = ""; trig = ""
    }
    FNR == 1 {
      flush()
      n = split(FILENAME, parts, "/"); name = parts[n - 1]
      infm = ($0 == "---"); done = !infm
      next
    }
    done { next }
    $0 == "---" { done = 1; next }
    infm && index($0, "description:") == 1 { desc = unq(substr($0, 13)); next }
    infm && index($0, "argument-hint:") == 1 { hint = unq(substr($0, 15)); next }
    infm && index($0, "triggers:") == 1 { trig = unq(substr($0, 10)); next }
    END { flush() }
  ' "${files[@]}"
}

builtin_lines() {
  cat <<'YAML'
  - name: "search"
    use: "Find anything already in HQ: qmd query (hybrid), qmd search (keyword), qmd vsearch (semantic), scoped with -c <collection>."
    keywords: "find, search, where, what happened, history, remember, lookup, policy, project, knowledge, notes, sources, source, transcript, meeting, meetings"
  - name: "web"
    use: "Facts outside HQ: WebSearch and WebFetch, or the built-in browser for pages that need a real session."
    keywords: "web, online, internet, x, twitter, tweet, tweets, posts, linkedin, reddit, news, article, url, link, links, website, google, competitor"
  - name: "integrations"
    use: "Read, search, create, or update in a connected app (Slack, Linear, Notion, GitHub, Gmail, Drive, HubSpot and more) through the HQ gateway: hq integrations list --company <slug>, then the flag it prints. Never a separate MCP when HQ has the app."
    keywords: "slack, linear, notion, jira, github, sentry, gmail, email, drive, asana, clickup, figma, hubspot, salesforce, calendar, ticket, tickets, issue, issues, channel, connector, integration, integrations"
  - name: "secrets"
    use: "Use a credential without seeing it: hq run, hq secrets exec, /hq-secrets. Never paste a secret."
    keywords: "secret, secrets, credential, credentials, token, api key, password, env, key"
  - name: "files"
    use: "Vault files and sharing: /hq-files, /hq-share <path>, hq files acl."
    keywords: "file, files, vault, share, upload, download, acl, folder"
  - name: "messages"
    use: "Direct messages, channel history, reminders to teammates: /dm, hq dm."
    keywords: "dm, message, messages, remind, reminder, tell, ping, inbox, teammate"
  - name: "board"
    use: "Project board and story state: the work mesh cache under ~/.hq/work-mesh/cache/projects/, hq mesh story --story <id> --status <status>; never local prd.json status."
    keywords: "board, story, stories, backlog, queued, in progress, blocked, sprint, status of the project, what is left"
  - name: "workers"
    use: "Who does specialised work: the company's workers in the startwork capability block or core/workers/registry.yaml, run with /run <worker> <skill> or /execute-task."
    keywords: "worker, workers, who can, pipeline, run a worker, specialist, agent for"
YAML
}

integration_lines() {
  # Local scope only. Reads the per-company cache that usable-integrations.sh
  # maintains; never touches the network so a build stays under a second.
  [ "$SCOPE" = "local" ] && [ -n "$COMPANY" ] || return 0
  local cache="$ROOT/.hq/usable-integrations/$COMPANY.json"
  if [ ! -f "$cache" ] || ! command -v jq >/dev/null 2>&1; then
    printf '  - company: %s\n    note: "no cached list; run core/scripts/usable-integrations.sh show --company %s"\n' "$(yaml_q "$COMPANY")" "$COMPANY"
    return 0
  fi
  jq -r --arg co "$COMPANY" '
    select(.company == $co) | .apps[]? |
    "  - name: \(.name | tojson)\n    use: \(("usable in " + $co + ": pass " + .selector) | tojson)"' "$cache" 2>/dev/null \
    || printf '  - company: %s\n    note: "cache unreadable"\n' "$(yaml_q "$COMPANY")"
}

build() {
  printf '# HQ intent index. Generated by core/scripts/build-intent-index.sh; do not edit.\n'
  printf '# One line per capability. Route plain-language asks here before reading any skill body.\n'
  printf 'version: 1\nscope: %s\n' "$SCOPE"
  printf 'builtins:\n'; builtin_lines
  printf 'skills:\n'; skill_lines
  if [ "$SCOPE" = "local" ] && [ -n "$COMPANY" ]; then
    printf 'integrations:\n'; integration_lines
  fi
}

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
build > "$tmp"

if [ "$CHECK" -eq 1 ]; then
  if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
    echo "build-intent-index: $OUT is current"; exit 0
  fi
  echo "build-intent-index: $OUT is stale; run core/scripts/build-intent-index.sh --scope $SCOPE" >&2
  if [ -f "$OUT" ]; then diff "$OUT" "$tmp" >&2 || true; else echo "build-intent-index: $OUT does not exist" >&2; fi
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
  echo "build-intent-index: unchanged ($(grep -c '^  - name:' "$OUT") entries) -> $OUT"
else
  mv "$tmp" "$OUT"; trap - EXIT
  echo "build-intent-index: wrote $(grep -c '^  - name:' "$OUT") entries ($(wc -c < "$OUT" | tr -d ' ') bytes) -> $OUT"
fi
