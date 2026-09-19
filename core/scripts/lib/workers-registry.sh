#!/usr/bin/env bash
# workers-registry.sh — parse core/workers/registry.yaml without yq.
#
# A stale registry that lists workers whose directories are gone is worse
# than no entry: agents discover the capability via the index, then fall
# back to a raw script. Callers (SessionStart, tests) use this to detect
# that drift cheaply — no hq CLI, no python.
#
# hq_workers_registry_missing <hq-root>
#   Prints one "id<TAB>path" line per status:active (or omitted status)
#   worker whose path is not a directory containing worker.yaml.
#   Missing registry file → no output, exit 0.

hq_workers_registry_missing() {
  local root="${1:-}"
  local registry
  [ -n "$root" ] || return 0
  registry="$root/core/workers/registry.yaml"
  [ -f "$registry" ] || return 0

  awk '
    function strip(s) {
      gsub(/["'\'']/, "", s)
      gsub(/^[[:space:]]+/, "", s)
      gsub(/[[:space:]]+$/, "", s)
      return s
    }
    function flush() {
      if (id != "" && path != "" && status == "active") {
        print id "\t" path
      }
      id = ""
      path = ""
      status = "active"
    }
    /^[[:space:]]*-[[:space:]]+id:/ {
      flush()
      line = $0
      sub(/^[[:space:]]*-[[:space:]]+id:[[:space:]]*/, "", line)
      id = strip(line)
      next
    }
    /^[[:space:]]*path:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*path:[[:space:]]*/, "", line)
      path = strip(line)
      next
    }
    /^[[:space:]]*status:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*status:[[:space:]]*/, "", line)
      status = strip(line)
      next
    }
    END { flush() }
  ' "$registry" | while IFS="$(printf '\t')" read -r id path; do
    [ -n "$id" ] && [ -n "$path" ] || continue
    rel="${path%/}"
    if [ ! -d "$root/$rel" ] || [ ! -f "$root/$rel/worker.yaml" ]; then
      printf '%s\t%s\n' "$id" "$rel"
    fi
  done || true
  return 0
}
