#!/usr/bin/env bash
# generate-workers-registry.sh — regenerate core/workers/registry.yaml from
# the union of all worker.yaml files under core/workers/ and companies/*/workers/.
#
# Source of truth: each worker's worker.yaml. This file is a DERIVED index.
# Triggered automatically by .claude/hooks/reindex.sh on every Stop and
# PostToolUse-Write event. Idempotent — writes the registry only when the
# generated content differs from the existing file (no spurious git churn).

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$HQ_ROOT"

REGISTRY_PATH="core/workers/registry.yaml"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

yq_get() {
  local field="$1" file="$2"
  if command -v yq >/dev/null 2>&1; then
    yq -r ".worker.${field} // \"\"" "$file" 2>/dev/null || echo ""
  else
    awk -v key="$field" '
      $0 ~ /^worker:[[:space:]]*$/ { in_w=1; next }
      in_w && /^[^[:space:]]/ { in_w=0 }
      in_w && $0 ~ "^[[:space:]]+"key":" {
        sub(/^[^:]+:[[:space:]]*/, "")
        gsub(/^["\x27]|["\x27]$/, "")
        sub(/[[:space:]]+#.*$/, "")
        print; exit
      }
    ' "$file"
  fi
}

derive_visibility() {
  local path="$1"
  case "$path" in
    core/workers/public/*) echo "public" ;;
    companies/*/workers/*) echo "private" ;;
    personal/workers/*)    echo "public" ;;
    *)                     echo "public" ;;
  esac
}

# attribute_pack <worker-dir>
#   When a worker.yaml is wired in from an installed hq-pack (its real path
#   resolves under core/packages/<pkg>/), echo " [source: pack <pkg>]" so a
#   quarantine message names the culprit pack rather than just the opaque
#   symlinked path. Empty string for first-party workers. Uses `pwd -P` to follow
#   the symlink (BSD/macOS-safe — no GNU realpath / readlink -f).
attribute_pack() {
  local dir="$1" phys pk
  phys="$(cd "$dir" 2>/dev/null && pwd -P)" || return 0
  case "$phys" in
    */core/packages/*)
      pk="${phys##*/core/packages/}"; pk="${pk%%/*}"
      [[ -n "$pk" ]] && printf ' [source: pack %s]' "$pk"
      ;;
  esac
}

TMP_OUT="$(mktemp -t workers-registry.XXXXXX)"
TMP_ENTRIES="$(mktemp -t workers-entries.XXXXXX)"
trap 'rm -f "$TMP_OUT" "$TMP_ENTRIES"' EXIT

# Quarantine accounting: a single bad/duplicate worker must never block ALL
# registration. Offending entries are excluded (fail-closed on them) and reported
# loudly, but the registry is still written for every VALID worker. See DEV-1718.
quarantined=0

while IFS= read -r yaml; do
  case "$yaml" in
    companies/_template/*) continue ;;
    # Skip any underscore-prefixed pseudo-dir (e.g. an _overrides/ snapshot
    # mirrored in via personal/workers/). These are not registry sources;
    # treating them as such produces spurious duplicate-id aborts. `find -L`
    # follows symlinked dirs, so this also covers core/workers/_overrides
    # -> personal/workers/_overrides.
    */_overrides/*|_overrides/*) continue ;;
  esac

  id=$(yq_get id "$yaml")
  type=$(yq_get type "$yaml")
  desc=$(yq_get description "$yaml")
  status=$(yq_get status "$yaml")
  company=$(yq_get company "$yaml")
  team=$(yq_get team "$yaml")

  # Flatten embedded newlines + the field delimiter out of every extracted value
  # to single spaces BEFORE serialization. A multi-line `description: |` block
  # otherwise keeps its newlines through the printf→`read` round-trip below, and
  # the newline-delimited reader splits each extra line into a bogus worker row —
  # corrupting the whole registry into invalid YAML. (DEV: registry-0-workers.)
  for __f in id type desc status company team; do
    printf -v "$__f" '%s' "${!__f//$'\n'/ }"
    printf -v "$__f" '%s' "${!__f//$'\x1f'/ }"
  done

  if [[ -z "$id" || -z "$type" || -z "$desc" ]]; then
    missing=""
    [[ -z "$id" ]]   && missing="${missing:+$missing, }id"
    [[ -z "$type" ]] && missing="${missing:+$missing, }type"
    [[ -z "$desc" ]] && missing="${missing:+$missing, }description"
    pack_attr="$(attribute_pack "$(dirname "$yaml")")"
    if [[ -n "$pack_attr" ]]; then
      # Pack-sourced worker: the file lives under protected core/ (a symlink into
      # an installed pack), so the user cannot edit it locally. The real remedy is
      # to refresh a stale installed pack — `hq install` / `/update-hq` SKIP
      # already-installed packs, so a fix landed upstream does not reach an
      # existing install until `hq packs update <pack>` re-pulls it. The NAMED
      # form forces a re-sync even when no update is auto-detected. (DEV-1796.)
      pack_name="${pack_attr##*pack }"; pack_name="${pack_name%]}"
      remedy="this worker ships from an installed pack — its on-disk copy is likely stale; run 'hq packs update ${pack_name}' to refresh it (you cannot edit the protected core/ copy directly). If it persists after refreshing, the pack's worker.yaml needs the field(s) added upstream"
    else
      remedy="fix the worker.yaml and re-run"
    fi
    echo "generate-workers-registry: QUARANTINED $yaml — missing required field(s): ${missing}${pack_attr} (excluded from registry; ${remedy})" >&2
    quarantined=$((quarantined+1))
    continue
  fi

  [[ "$company" == "null" ]] && company=""
  [[ "$team" == "null" ]] && team=""
  [[ "$status" == "null" || -z "$status" ]] && status="active"

  path="$(dirname "$yaml")/"
  visibility="$(derive_visibility "$path")"

  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
    "$id" "$path" "$type" "$visibility" "$team" "$company" "$status" "$desc" \
    >> "$TMP_ENTRIES"
done < <(find -L core/workers companies -name worker.yaml -type f 2>/dev/null | sort)

sort -t$'\x1f' -k1,1 "$TMP_ENTRIES" -o "$TMP_ENTRIES"

# Duplicate-id quarantine — a duplicated id is ambiguous: writing one copy would
# silently shadow the other(s). So we EXCLUDE every copy of any id that appears
# more than once (never pick a winner) and report all paths loudly. Valid, uniquely
# named workers still register — one pack's id collision no longer blocks the whole
# registry (DEV-1718). The duplicated workers reappear automatically once the id
# clash is resolved.
dup_ids=$(cut -f1 -d$'\x1f' "$TMP_ENTRIES" | sort | uniq -d)
if [[ -n "$dup_ids" ]]; then
  echo "generate-workers-registry: duplicate worker id(s) detected — quarantining all copies (excluded from registry to avoid silently shadowing a worker):" >&2
  while IFS= read -r dup_id; do
    [[ -z "$dup_id" ]] && continue
    echo "  duplicate id '$dup_id' — none of these are registered until the clash is resolved:" >&2
    while IFS= read -r dpath; do
      echo "    path: ${dpath}$(attribute_pack "$dpath")" >&2
    done < <(grep -F "${dup_id}"$'\x1f' "$TMP_ENTRIES" | cut -f2 -d$'\x1f')
    quarantined=$((quarantined+1))
  done <<< "$dup_ids"
  echo "  Fix: change worker.id in one of the colliding worker.yaml files (or namespace the pack's id) to make it unique." >&2
  # Strip every row whose id is duplicated, keep the rest.
  awk -v FS=$'\x1f' 'NR==FNR { dup[$1]=1; next } !($1 in dup)' \
    <(printf '%s\n' "$dup_ids") "$TMP_ENTRIES" > "${TMP_ENTRIES}.f"
  mv "${TMP_ENTRIES}.f" "$TMP_ENTRIES"
fi

{
  echo "# Workers Registry — AUTO-GENERATED by core/scripts/generate-workers-registry.sh"
  echo "# DO NOT EDIT. Source of truth: worker.yaml in each worker's directory."
  echo "# Triggered by .claude/hooks/reindex.sh on Stop / PostToolUse-Write."
  echo "# To register a new worker: create its worker.yaml. Registry regenerates."
  echo ""
  echo "version: \"5.0\""
  echo "generated_at: \"${GENERATED_AT}\""
  echo ""
  echo "workers:"
  while IFS=$'\x1f' read -r id path type visibility team company status desc; do
    [[ -z "$id" ]] && continue
    # Double-quote every scalar so a value containing `: ` (or other YAML
    # metacharacters) can never break the block mapping.
    echo "  - id: \"${id//\"/\\\"}\""
    echo "    path: \"${path//\"/\\\"}\""
    echo "    type: \"${type//\"/\\\"}\""
    echo "    visibility: \"${visibility//\"/\\\"}\""
    [[ -n "$team" ]]    && echo "    team: \"${team//\"/\\\"}\""
    [[ -n "$company" ]] && echo "    company: \"${company//\"/\\\"}\""
    echo "    status: \"${status//\"/\\\"}\""
    echo "    description: \"${desc//\"/\\\"}\""
  done < "$TMP_ENTRIES"
} > "$TMP_OUT"

strip_timestamp() { sed '/^generated_at:/d' "$1"; }

needs_write=1
if [[ -f "$REGISTRY_PATH" ]]; then
  if diff -q <(strip_timestamp "$REGISTRY_PATH") <(strip_timestamp "$TMP_OUT") >/dev/null 2>&1; then
    needs_write=0
  fi
fi

if [[ $needs_write -eq 1 ]]; then
  mkdir -p "$(dirname "$REGISTRY_PATH")"
  cp "$TMP_OUT" "$REGISTRY_PATH"
  echo "generate-workers-registry: wrote $REGISTRY_PATH" >&2
else
  echo "generate-workers-registry: $REGISTRY_PATH unchanged" >&2
fi

if [[ $quarantined -gt 0 ]]; then
  echo "generate-workers-registry: wrote registry for all VALID workers; quarantined $quarantined problem(s) above (loud + partial, never a silent total block). Fix the reported worker.yaml file(s) and re-run to register them." >&2
  exit 1
fi

exit 0
