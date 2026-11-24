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

# True when `hq sync-core status --json` lists <company> in full mode and not
# in `held` (the CLI's own ownership rule). A CLI without the command, or any
# read error, counts as not engine-owned, which keeps the `hq sync push` path.
hq_delegate_engine_owns_vault() {
  local status
  status="$(hq sync-core status --json 2>/dev/null)" || return 1
  printf '%s' "$status" | jq -e --arg co "$1" \
    '[(.held // [])[] | .uid | ascii_downcase] as $held
     | any(.vaults[]? | select(. != null);
         .kind == "company" and .phase == "full"
         and ((.slug // "") | ascii_downcase) == ($co | ascii_downcase)
         and ((.uid | ascii_downcase) as $uid | $held | index([$uid]) | not))' >/dev/null 2>&1
}

# HQ_DELEGATE_ENGINE_WAIT_SECONDS as whole seconds; 180 when unset or not a
# whole number.
hq_delegate_engine_wait_seconds() {
  case "${HQ_DELEGATE_ENGINE_WAIT_SECONDS:-}" in
    ''|*[!0-9]*) echo 180 ;;
    *) echo "$((10#$HQ_DELEGATE_ENGINE_WAIT_SECONDS))" ;;
  esac
}

# Why the engine may never upload a file, for the wait-failure messages.
HQ_DELEGATE_ENGINE_WAIT_CAUSES='the engine skips a file an ignore rule matches, a symlink, or a path this machine is not granted'

# hq_delegate_wait_for_cloud <company> <company-relative vault path> <sha256>
# Polls `hq files cat` until it succeeds and the vault holds exactly those
# bytes. A failed read never matches, even the hash of an empty file.
hq_delegate_wait_for_cloud() {
  local company="$1" path="$2" expected="$3" got deadline tmp
  deadline=$((SECONDS + $(hq_delegate_engine_wait_seconds)))
  tmp="$(mktemp "${TMPDIR:-/tmp}/hq-delegate-cat.XXXXXX")" || return 1
  while :; do
    if hq files cat "$path" --company "$company" > "$tmp" 2>/dev/null; then
      got="$(hq_delegate_sha256 < "$tmp")"
      if [ "$got" = "$expected" ]; then rm -f "$tmp"; return 0; fi
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then rm -f "$tmp"; return 1; fi
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
