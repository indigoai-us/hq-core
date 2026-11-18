# shellcheck shell=bash
# hq-core: public
# delegate-engine.sh — /delegate helpers for a company vault that the new sync
# engine (hq-syncd) owns on this machine. The CLI refuses `hq sync push` for
# such a vault, so the helpers share the folder and wait for the engine to
# upload the files instead of pushing them.
#
# Env: HQ_DELEGATE_ENGINE_WAIT_SECONDS (default 180) bounds each wait;
#      HQ_DELEGATE_ENGINE_POLL_SECONDS (default 5) is the read-back interval.

hq_delegate_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d ' ' -f1; else shasum -a 256 | cut -d ' ' -f1; fi
}

# True when `hq sync-core status --json` lists <company> in full mode. A CLI
# without the command, or any read error, counts as not engine-owned, which
# keeps the `hq sync push` path.
hq_delegate_engine_owns_vault() {
  local status
  status="$(hq sync-core status --json 2>/dev/null)" || return 1
  printf '%s' "$status" | jq -e --arg co "$1" \
    'any(.vaults[]?; .kind == "company" and .slug == $co and .phase == "full")' >/dev/null 2>&1
}

# hq_delegate_wait_for_cloud <company> <company-relative vault path> <sha256>
# Polls `hq files cat` until the vault holds exactly those bytes.
hq_delegate_wait_for_cloud() {
  local company="$1" path="$2" expected="$3" got deadline
  deadline=$((SECONDS + ${HQ_DELEGATE_ENGINE_WAIT_SECONDS:-180}))
  while :; do
    got="$( { hq files cat "$path" --company "$company" 2>/dev/null || true; } | hq_delegate_sha256)"
    [ "$got" = "$expected" ] && return 0
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep "${HQ_DELEGATE_ENGINE_POLL_SECONDS:-5}"
  done
}

# hq_delegate_engine_pin <hq root> <company> <company-relative path>...
# Adds the paths to <hq root>/.hq/pins.json. A member in `shared` or `custom`
# sync mode has a pull scope of explicit grants plus these pins, and the engine
# never uploads a local file outside that scope. The engine re-reads the pins
# on every cycle.
hq_delegate_engine_pin() {
  local root="$1" company="$2" file tmp
  shift 2
  file="$root/.hq/pins.json"
  mkdir -p "$root/.hq" || return 1
  [ -s "$file" ] || printf '{"version":1,"pins":{}}\n' > "$file" || return 1
  tmp="$(mktemp "$file.tmp.XXXXXX")" || return 1
  if jq --arg co "$company" \
    '.pins[$co] = (((.pins[$co] // []) + $ARGS.positional) | unique)' "$file" --args "$@" > "$tmp"; then
    mv -f "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}
