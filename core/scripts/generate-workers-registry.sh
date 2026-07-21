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

# Detect yq once. The per-worker field read is the hot path of this script —
# resolving yq on every field of every worker (6 x N spawns of `command -v`)
# is itself measurable on a cold reindex, which fires on every Stop / Write.
if command -v yq >/dev/null 2>&1; then YQ_BIN="$(command -v yq)"; else YQ_BIN=""; fi

# US — the \x1f unit separator used as this script's internal field delimiter,
# both for read_worker_fields output and the serialized $TMP_ENTRIES rows.
US=$'\x1f'

# read_worker_fields <file> — emit the six worker fields (id, type, description,
# status, company, team), \x1f-delimited, on ONE line, in that fixed order.
#
# With yq present this is a SINGLE yq invocation per worker; the previous code
# spawned yq six times per worker (once per field), and process-spawn overhead
# dominated reindex wall time (~2.4s -> ~0.7s across ~50 workers here). Newlines
# and the \x1f delimiter are scrubbed to spaces INSIDE yq so a multi-line
# `description: |` block can never split the single-record round-trip (yq's
# `sub` is global). Batching ALL files into one yq call is deliberately avoided:
# yq aborts the whole batch at the first malformed file, which would silently
# drop every worker sorted after it — breaking the per-worker fail-closed
# quarantine guarantee (DEV-1718). One call per file keeps that isolation.
#
# Without yq it falls back to the awk reader, one yq_get (awk) call per field.
read_worker_fields() {
  local file="$1"
  if [[ -n "$YQ_BIN" ]]; then
    "$YQ_BIN" -r "[.worker.id, .worker.type, .worker.description, .worker.status, .worker.company, .worker.team] | map((. // \"\") | tostring | sub(\"\n+$\";\"\") | sub(\"\n\";\" \") | sub(\"${US}\";\" \")) | join(\"${US}\")" "$file" 2>/dev/null
  else
    printf '%s\n' "$(yq_get id "$file")${US}$(yq_get type "$file")${US}$(yq_get description "$file")${US}$(yq_get status "$file")${US}$(yq_get company "$file")${US}$(yq_get team "$file")"
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

  # All six fields in ONE read (single yq spawn per worker — see
  # read_worker_fields). IFS scoped to this read so only \x1f splits fields.
  IFS="$US" read -r id type desc status company team < <(read_worker_fields "$yaml")

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
# personal/workers is walked DIRECTLY: personal is now the sole read source for
# the personal overlay (the old reindex symlink mirror into core/workers is
# retired). `derive_visibility` already classifies personal/workers/* as public.
done < <(find -L core/workers companies personal/workers -name worker.yaml -type f 2>/dev/null | sort)

# Sort by id, then by path — the secondary path key makes duplicate-id
# resolution deterministic (the lexicographically-first path wins; see below).
sort -t$'\x1f' -k1,1 -k2,2 "$TMP_ENTRIES" -o "$TMP_ENTRIES"

# Duplicate-id graceful degradation (DEV-1845) — a duplicated id is ambiguous,
# but it must NEVER hard-fail the generator or drop the id entirely. The old
# behavior (exclude EVERY copy + non-zero exit, DEV-1718) permanently staled
# registry.yaml on any single duplicate: the id vanished AND the non-zero exit
# read as "registry generation failed", so new company workers stopped
# appearing until a human hand-resolved the clash. Instead: KEEP one copy
# deterministically (the lexicographically-first path — the entries are now
# sorted by id then path, so the first row per id is stable and reproducible),
# SKIP the rest, emit a LOUD stderr warning naming what was kept vs skipped, and
# stay NON-FATAL (a duplicate never increments `quarantined`, so the exit code is
# unaffected). registry.yaml keeps regenerating; the operator resolves the clash
# at leisure and the shadowed copy reappears once its id is made unique.
dup_ids=$(cut -f1 -d$'\x1f' "$TMP_ENTRIES" | sort | uniq -d)
if [[ -n "$dup_ids" ]]; then
  echo "generate-workers-registry: WARNING duplicate worker id(s) detected — keeping the first copy of each and skipping the rest (registry still generated; resolve the clash to silence this):" >&2
  while IFS= read -r dup_id; do
    [[ -z "$dup_id" ]] && continue
    kept=1
    while IFS= read -r dpath; do
      if [[ $kept -eq 1 ]]; then
        echo "  duplicate id '$dup_id' — KEEPING ${dpath}$(attribute_pack "$dpath")" >&2
        kept=0
      else
        echo "  duplicate id '$dup_id' — SKIPPING ${dpath}$(attribute_pack "$dpath")" >&2
      fi
    done < <(grep -F "${dup_id}"$'\x1f' "$TMP_ENTRIES" | cut -f2 -d$'\x1f')
  done <<< "$dup_ids"
  echo "  Fix: change worker.id in one of the colliding worker.yaml files (or namespace the pack's id) to make it unique." >&2
  # Keep only the FIRST row per id (stable: TMP_ENTRIES is sorted by id then
  # path, so the first row of each id group is the smallest-path winner above).
  awk -F$'\x1f' '!seen[$1]++' "$TMP_ENTRIES" > "${TMP_ENTRIES}.f"
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
