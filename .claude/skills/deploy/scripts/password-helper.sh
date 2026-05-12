#!/usr/bin/env bash
# password-helper.sh — generate, print, copy, and persist auto-passwords for hq-deploy
#
# Subcommands:
#   gen                       Generate a memorable 3-word password and print to stdout
#   announce <slug> <password> [trigger]  Print to stderr (once), copy to clipboard via pbcopy,
#                                          AND persist to ~/.hq/deploy-passwords.json (mode 0600).
#                                          This is the one-call wrapper SKILL.md C.4 expects.
#   persist <slug> <password> <trigger>   Standalone: append to ~/.hq/deploy-passwords.json (mode 0600)
#   lookup <slug>             Print persisted password for a slug (no echo to subsequent agent output)
#
# Used by .claude/skills/deploy/SKILL.md Step 4.5 (sensitivity & password) and Step 6 (post-upload).
# Reinforced by core/policies/hq-deploy-reinforcement.md.

set -euo pipefail

PASS_FILE="$HOME/.hq/deploy-passwords.json"

# Curated word list: avoids confusable letters, all lowercase, 4-7 chars.
# Three buckets so generated triples reliably read as "adjective-noun-NN".
ADJECTIVES=(
  amber azure blue brave brisk calm clear coral crimson dawn dusty eager electric
  fancy fast feral fiery foggy foxtrot frosty gentle giant golden grand happy hazy
  hidden humble icy iron ivory jade jolly kind lively lucky maple merry mighty misty
  mystic neat noble onyx orchid pearl plum proud quick quiet rapid raven royal rusty
  sable sage scarlet shy silent silken silver smooth solar steady stellar stoic
  sunny swift tame tangy tawny teal tidy topaz tranquil twilight ultra umber valiant
  vast velvet vibrant violet warm wild winter wise woven zesty
)
NOUNS=(
  alder anchor arrow ash badger banyan beacon bear birch bison brook canyon cedar
  cliff cloud comet coral crane creek crystal dawn deer delta drift eagle ember
  fern field finch fjord forest fox glade glen harbor hawk haven heron hill iris
  ivy jasper kestrel lagoon lake lark laurel ledge linden lupine maple marsh meadow
  meridian mesa mist moor moss oak ocean orbit orchid otter peak phoenix pine plain
  prairie quartz raven reed reef ridge river robin sage sail savanna shore sky
  slope solstice sparrow spring spruce starling stone stream summit swallow thicket
  tide topaz trail valley vine wave willow wolf woodland zenith
)

cmd_gen() {
  local adj noun num
  adj="${ADJECTIVES[$RANDOM % ${#ADJECTIVES[@]}]}"
  noun="${NOUNS[$RANDOM % ${#NOUNS[@]}]}"
  num=$(printf "%02d" $((RANDOM % 100)))
  printf "%s-%s-%s\n" "$adj" "$noun" "$num"
}

cmd_announce() {
  local slug="${1:?slug required}"
  local pw="${2:?password required}"
  local trigger="${3:-manual}"
  printf "Password for %s: %s\n" "$slug" "$pw" >&2
  if command -v pbcopy >/dev/null 2>&1; then
    printf "%s" "$pw" | pbcopy
    printf "(copied to clipboard)\n" >&2
  fi
  cmd_persist "$slug" "$pw" "$trigger"
}

cmd_persist() {
  local slug="${1:?slug required}"
  local pw="${2:?password required}"
  local trigger="${3:-manual}"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  mkdir -p "$HOME/.hq"
  if [ ! -f "$PASS_FILE" ]; then
    printf '{}\n' > "$PASS_FILE"
    chmod 0600 "$PASS_FILE"
  fi

  if ! command -v jq >/dev/null 2>&1; then
    printf "password-helper: jq not found, cannot persist\n" >&2
    return 1
  fi

  local tmp="${PASS_FILE}.tmp.$$"
  jq --arg slug "$slug" --arg pw "$pw" --arg t "$trigger" --arg ts "$now" \
     '.[$slug] = {password: $pw, created_at: $ts, trigger: $t}' \
     "$PASS_FILE" > "$tmp"
  mv "$tmp" "$PASS_FILE"
  chmod 0600 "$PASS_FILE"
}

cmd_lookup() {
  local slug="${1:?slug required}"
  if [ ! -f "$PASS_FILE" ]; then
    return 1
  fi
  jq -r --arg slug "$slug" '.[$slug].password // empty' "$PASS_FILE"
}

usage() {
  cat <<EOF
usage: password-helper.sh <gen|announce|persist|lookup> [args...]

  gen
      Print a fresh 3-word memorable password to stdout.

  announce <slug> <password>
      Print "Password for <slug>: <pw>" to stderr (once) and copy <pw>
      to clipboard via pbcopy on macOS.

  persist <slug> <password> [trigger]
      Append/replace entry in ~/.hq/deploy-passwords.json (mode 0600).
      <trigger> records which sensitivity rule fired (e.g.
      "companies-data-path", "private-repo", "pii-fields",
      "financial-filename", "user-explicit").

  lookup <slug>
      Print the persisted password for <slug> to stdout (no-op if absent).
EOF
  exit 64
}

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    gen)      cmd_gen "$@" ;;
    announce) cmd_announce "$@" ;;
    persist)  cmd_persist "$@" ;;
    lookup)   cmd_lookup "$@" ;;
    -h|--help|help|"") usage ;;
    *) printf "password-helper: unknown subcommand: %s\n" "$sub" >&2; usage ;;
  esac
}

main "$@"
