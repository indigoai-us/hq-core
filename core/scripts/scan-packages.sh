#!/usr/bin/env bash
# scan-packages.sh — wire installed hq-pack content into host-side well-known paths.
#
# Walks core/packages/*/package.yaml at session start (or on demand) and creates the
# symlinks declared by each pack's `contributes` block. Idempotent: re-running is
# a no-op when the symlinks already match. Warns and skips on collisions instead
# of clobbering.
#
# Mapping (see core/knowledge/public/hq-core/package-yaml-spec.md):
#   contributes.workers[name]    packages/{pkg}/workers/{name}/       -> core/workers/public/{name}
#   contributes.knowledge[name]  packages/{pkg}/knowledge/{name}/     -> core/knowledge/public/{name}
#   contributes.skills[name]     packages/{pkg}/skills/{name}/        -> .claude/skills/{name}
#   contributes.commands[name]   packages/{pkg}/commands/{name}.md    -> .claude/commands/{name}.md
#   contributes.hooks[name]      packages/{pkg}/hooks/{name}.sh       -> .claude/hooks/{name}.sh
#   contributes.policies[name]   packages/{pkg}/policies/{name}.md    -> core/policies/{name}.md
#   contributes.scripts[name]    packages/{pkg}/scripts/{name}        -> core/scripts/{name}
#
# Run from the HQ instance root. Exits 0 on success (even with warnings), >0 on
# hard error (unreadable manifest, write failure).

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(pwd)}"
PACKAGES_DIR="$HQ_ROOT/core/packages"

warn() { printf '  [warn] %s\n' "$*" >&2; }
info() { [[ "${HQ_SCAN_QUIET:-0}" == "1" ]] || printf '  %s\n' "$*"; }
die()  { printf '[scan-packages] error: %s\n' "$*" >&2; exit 1; }

[[ -d "$PACKAGES_DIR" ]] || { info "[scan-packages] no core/packages/ dir; nothing to wire"; exit 0; }

# parse_contributes <package.yaml>
#   Emits lines of the form "<key>\t<item>" for every entry under contributes.*.
#   Supports shallow YAML only: "contributes:" block header, then "  <key>:"
#   subheaders, then "    - item" list items. Comments (#...) and blank lines
#   are ignored. List items may be bare or quoted (' or ").
parse_contributes() {
  local manifest="$1"
  awk '
    function strip(s) {
      sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s);
      sub(/[[:space:]]*#.*$/, "", s);
      # unquote
      if (s ~ /^".*"$/ || s ~ /^'\''.*'\''$/) s = substr(s, 2, length(s)-2);
      return s;
    }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^contributes:[[:space:]]*$/ { in_c = 1; key = ""; next }
    in_c && /^[^[:space:]]/ { in_c = 0; key = ""; next }      # left the block
    in_c && /^  [a-zA-Z_][a-zA-Z0-9_-]*:[[:space:]]*\[[[:space:]]*\][[:space:]]*$/ {
      # empty inline list: "  workers: []"
      key = ""; next
    }
    in_c && /^  [a-zA-Z_][a-zA-Z0-9_-]*:[[:space:]]*$/ {
      k = $0; sub(/^  /, "", k); sub(/:[[:space:]]*$/, "", k); key = k; next
    }
    in_c && key != "" && /^    -[[:space:]]+.+$/ {
      item = $0; sub(/^    -[[:space:]]+/, "", item); item = strip(item);
      if (item != "") printf "%s\t%s\n", key, item;
      next
    }
  ' "$manifest"
}

# ensure_symlink <src_abs> <dst_abs>
#   Creates a symlink dst -> src. Idempotent. Warns on collision.
ensure_symlink() {
  local src="$1" dst="$2"
  if [[ ! -e "$src" && ! -L "$src" ]]; then
    warn "payload missing: $src (declared but not shipped)"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  if [[ -L "$dst" ]]; then
    local existing
    existing="$(readlink "$dst")"
    if [[ "$existing" == "$src" ]]; then
      return 0  # already correct, no-op
    fi
    warn "collision: $dst already points at $existing (wanted $src) — skipping"
    return 0
  fi
  if [[ -e "$dst" ]]; then
    warn "collision: $dst exists as regular file/dir — host content wins, skipping"
    return 0
  fi
  ln -s "$src" "$dst"
  info "linked $dst -> $src"
}

# worker_id_of <worker.yaml>
#   Echo the worker.id field. Shallow YAML parse mirroring the registry generator
#   (yq if present, awk fallback). Empty when absent/unreadable.
worker_id_of() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  if command -v yq >/dev/null 2>&1; then
    yq -r '.worker.id // ""' "$file" 2>/dev/null || true
  else
    awk '
      $0 ~ /^worker:[[:space:]]*$/ { in_w=1; next }
      in_w && /^[^[:space:]]/ { in_w=0 }
      in_w && $0 ~ "^[[:space:]]+id:" {
        sub(/^[^:]+:[[:space:]]*/, ""); gsub(/^["\x27]|["\x27]$/, ""); sub(/[[:space:]]+#.*$/, ""); print; exit
      }
    ' "$file"
  fi
}

# resolve_file <path>
#   Physical absolute path of a file, following symlinks in its directory chain
#   (BSD/macOS-safe — `cd` + `pwd -P`, no GNU realpath / readlink -f).
resolve_file() {
  ( cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")" )
}

# worker_id_clashes <pkg_name> <pack_worker_dir> <dst>
#   Return 0 (clash — caller must skip) and warn loudly if the pack worker's id is
#   already registered by a DIFFERENT worker.yaml in the host tree. Wiring such a
#   worker would hand the registry generator a duplicate id and (pre-DEV-1718) block
#   ALL worker registration. Detect + refuse BEFORE wiring the symlink so the bad
#   state is never minted. Return 1 when clear (no collision / nothing to compare).
worker_id_clashes() {
  local pkg="$1" pdir="$2" dst="$3"
  local src_yaml="$pdir/worker.yaml"
  [[ -f "$src_yaml" ]] || return 1   # no id to clash on; let ensure_symlink decide
  local pid; pid="$(worker_id_of "$src_yaml")"
  [[ -z "$pid" ]] && return 1
  local src_phys; src_phys="$(resolve_file "$src_yaml")"
  local wy clash=""
  while IFS= read -r wy; do
    case "$wy" in */_template/*|*/_overrides/*) continue ;; esac
    [[ "$(worker_id_of "$wy")" == "$pid" ]] || continue
    # Skip the pack's own already-wired symlink (resolves to the same file).
    [[ "$(resolve_file "$wy")" == "$src_phys" ]] && continue
    clash="$wy"; break
  done < <(find -L "$HQ_ROOT/core/workers" "$HQ_ROOT/companies" -name worker.yaml -type f 2>/dev/null)
  if [[ -n "$clash" ]]; then
    warn "worker-id collision: pack '$pkg' worker id '$pid' is already registered at ${clash#"$HQ_ROOT"/} — refusing to wire $dst (would hard-fail the worker registry on a duplicate id). Resolve the duplicate id (or namespace the pack worker), then re-run."
    return 0
  fi
  return 1
}

# wire_one_package <pkg_dir>
wire_one_package() {
  local pkg_dir="$1"
  local manifest="$pkg_dir/package.yaml"
  [[ -f "$manifest" ]] || return 0   # skip: not a pack dir

  local pkg_name
  pkg_name="$(basename "$pkg_dir")"
  info "[scan-packages] wiring $pkg_name"

  local key item src dst
  while IFS=$'\t' read -r key item; do
    [[ -z "$key" || -z "$item" ]] && continue
    case "$key" in
      workers)
        src="$pkg_dir/workers/$item"
        dst="$HQ_ROOT/core/workers/public/$item"
        # Refuse to wire a pack worker whose id already belongs to a different
        # host worker — a silent install-time clash would block ALL registration.
        if worker_id_clashes "$pkg_name" "$src" "$dst"; then
          continue
        fi
        ;;
      knowledge)
        src="$pkg_dir/knowledge/$item"
        dst="$HQ_ROOT/core/knowledge/public/$item"
        ;;
      skills)
        src="$pkg_dir/skills/$item"
        dst="$HQ_ROOT/.claude/skills/$item"
        ;;
      commands)
        src="$pkg_dir/commands/$item.md"
        dst="$HQ_ROOT/.claude/commands/$item.md"
        ;;
      hooks)
        src="$pkg_dir/hooks/$item.sh"
        dst="$HQ_ROOT/.claude/hooks/$item.sh"
        ;;
      policies)
        src="$pkg_dir/policies/$item.md"
        dst="$HQ_ROOT/core/policies/$item.md"
        ;;
      scripts)
        src="$pkg_dir/scripts/$item"
        dst="$HQ_ROOT/core/scripts/$item"
        ;;
      *)
        warn "unknown contributes key '$key' in $manifest — skipping"
        continue
        ;;
    esac
    ensure_symlink "$src" "$dst"
  done < <(parse_contributes "$manifest")
}

main() {
  shopt -s nullglob
  local any=0 pkg
  for pkg in "$PACKAGES_DIR"/*/; do
    pkg="${pkg%/}"
    [[ -f "$pkg/package.yaml" ]] || continue
    any=1
    wire_one_package "$pkg"
  done
  shopt -u nullglob
  [[ "$any" == "1" ]] || info "[scan-packages] no hq-pack manifests found in $PACKAGES_DIR"
}

main "$@"
