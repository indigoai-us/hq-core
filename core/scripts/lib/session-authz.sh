#!/usr/bin/env bash
# hq-core: public
# session-authz.sh — fail-closed HQ root + company resolution for hq-agent-session.
#
# Sourced by core/scripts/hq-agent-session.sh. Never execute directly.
# Semantics parity with hq-pro resolve_preflight_company_dir
# (src/agents/inbox-watcher-cli.ts preflight): reject symlink roots, reject
# company dirs that are symlinks or escape <root>/companies, and require the
# slug to be among companies actually present on the box (settings or manifest
# marker). sender.verified never widens the resolved company set.

# hq_realpath <path>
#   Canonical absolute path via cd -P / pwd -P (portable; avoids the GNU-only flag).
#   Returns 1 if the path does not exist.
hq_realpath() {
  local target="${1:-}"
  [ -n "$target" ] || return 1
  if [ -d "$target" ]; then
    (cd -P "$target" 2>/dev/null && pwd -P) || return 1
  elif [ -e "$target" ]; then
    local dir base
    dir="$(cd -P "$(dirname "$target")" 2>/dev/null && pwd -P)" || return 1
    base="$(basename "$target")"
    printf '%s/%s' "$dir" "$base"
  else
    return 1
  fi
}

# hq_is_symlink <path> — true when the path itself is a symlink (not a parent).
hq_is_symlink() {
  [ -L "${1:-}" ]
}

# session_resolve_root
#   Resolve HQ root from HQ_AGENT_WORKDIR (when set) else SCRIPT_DIR/../..
#   Rejects a symlinked root (exit caller with 3).
#   Prints the canonical root on success. Sets SESSION_HQ_ROOT.
session_resolve_root() {
  local raw script_dir
  if [ -n "${HQ_AGENT_WORKDIR:-}" ]; then
    raw="$HQ_AGENT_WORKDIR"
  else
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # lib/ → scripts/ → core/ → root
    raw="$(cd "$script_dir/../.." && pwd)"
  fi

  if hq_is_symlink "$raw"; then
    echo "hq-agent-session: HQ root symlink rejected: $raw" >&2
    return 3
  fi

  local root
  root="$(hq_realpath "$raw")" || {
    echo "hq-agent-session: invalid HQ root: $raw" >&2
    return 3
  }
  [ -d "$root" ] || {
    echo "hq-agent-session: invalid HQ root: $raw" >&2
    return 3
  }
  # Companies tree must exist and not be a symlink escape of the root.
  local companies_root
  companies_root="$(hq_realpath "$root/companies" 2>/dev/null)" || {
    echo "hq-agent-session: invalid companies root under $root" >&2
    return 3
  }
  [ "$companies_root" = "$root/companies" ] || {
    echo "hq-agent-session: companies root is not <root>/companies" >&2
    return 3
  }

  SESSION_HQ_ROOT="$root"
  printf '%s' "$root"
}

# session_company_has_marker <dir>
#   True when the company directory carries a settings or manifest marker
#   (present-on-box proof for authorization).
session_company_has_marker() {
  local dir="${1:-}"
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  [ -e "$dir/settings" ] || [ -e "$dir/settings.yaml" ] || [ -e "$dir/settings.json" ] \
    || [ -e "$dir/manifest.yaml" ] || [ -e "$dir/manifest.yml" ] || [ -e "$dir/manifest.json" ]
}

# session_list_present_companies <root>
#   Print newline-separated slugs of companies present under <root>/companies
#   that have a settings or manifest marker. Never follows company-dir symlinks.
session_list_present_companies() {
  local root="${1:-}"
  local companies_root d base
  companies_root="$root/companies"
  [ -d "$companies_root" ] || return 0
  for d in "$companies_root"/*/; do
    [ -d "$d" ] || continue
    # Skip the entry if the company path itself is a symlink.
    hq_is_symlink "${d%/}" && continue
    base="$(basename "${d%/}")"
    case "$base" in
      _template|_*) continue ;;
    esac
    if session_company_has_marker "${d%/}"; then
      printf '%s\n' "$base"
    fi
  done | LC_ALL=C sort -u
}

# session_resolve_company_dir <root> <companySlug>
#   Resolve companies/<slug> with fail-closed guards. Prints canonical path.
#   Exit 6 on any rejection. Logs requested + present slugs to stderr.
#   Sets SESSION_COMPANY_DIR.
session_resolve_company_dir() {
  local root="${1:-}" slug="${2:-}"
  local companies_root requested canonical present present_csv root_canon

  # Canonicalize root so macOS /var → /private/var (and similar) cannot make
  # dirname(canonical) disagree with a non-realpathed $root/companies string.
  root_canon="$(hq_realpath "$root" 2>/dev/null || printf '%s' "$root")"
  companies_root="$(hq_realpath "$root_canon/companies" 2>/dev/null || printf '%s' "$root_canon/companies")"
  present="$(session_list_present_companies "$root_canon")"
  present_csv="$(printf '%s' "$present" | paste -sd, - | sed 's/,/, /g')"
  [ -n "$present_csv" ] || present_csv="(none)"

  # Also accept present list from the caller's path form (pre-realpath).
  if [ "$root_canon" != "$root" ]; then
    local present2
    present2="$(session_list_present_companies "$root")"
    if [ -n "$present2" ]; then
      present="$(printf '%s\n%s\n' "$present" "$present2" | sed '/^$/d' | LC_ALL=C sort -u)"
      present_csv="$(printf '%s' "$present" | paste -sd, - | sed 's/,/, /g')"
    fi
  fi

  # Slug charset guard (parity with preflight: a-z0-9_-)
  case "$slug" in
    ''|*[!a-z0-9_-]*)
      echo "hq-agent-session: company refused: requested='$slug' present=[$present_csv]" >&2
      return 6
      ;;
  esac

  # Prefer the canonical companies root; fall back to caller path for -L checks.
  requested="$companies_root/$slug"
  if [ ! -d "$requested" ] && [ -d "$root/companies/$slug" ]; then
    requested="$root/companies/$slug"
  fi

  # Must exist as a real directory, not a symlink at the company path itself.
  if hq_is_symlink "$requested" || [ ! -d "$requested" ]; then
    # Re-check the non-canonical path form for the symlink guard.
    if hq_is_symlink "$root/companies/$slug" || [ ! -d "$root/companies/$slug" ]; then
      echo "hq-agent-session: company refused: requested='$slug' present=[$present_csv]" >&2
      return 6
    fi
    requested="$root/companies/$slug"
  fi
  if hq_is_symlink "$requested"; then
    echo "hq-agent-session: company refused: requested='$slug' present=[$present_csv]" >&2
    return 6
  fi

  canonical="$(hq_realpath "$requested")" || {
    echo "hq-agent-session: company refused: requested='$slug' present=[$present_csv]" >&2
    return 6
  }

  # Canonical dirname must equal canonical <root>/companies; basename must equal slug.
  # Do not require requested == canonical string equality (macOS /var vs /private/var).
  if [ "$(dirname "$canonical")" != "$companies_root" ] \
    || [ "$(basename "$canonical")" != "$slug" ]; then
    echo "hq-agent-session: company refused: requested='$slug' present=[$present_csv] (path escape or mismatch)" >&2
    return 6
  fi

  # Must be among companies actually present (marker check).
  if ! session_company_has_marker "$canonical"; then
    echo "hq-agent-session: company refused: requested='$slug' present=[$present_csv] (no settings/manifest marker)" >&2
    return 6
  fi

  # Explicit membership in the present list (no first-match fallback).
  if ! printf '%s\n' "$present" | grep -Fxq -- "$slug"; then
    echo "hq-agent-session: company refused: requested='$slug' present=[$present_csv]" >&2
    return 6
  fi

  SESSION_COMPANY_DIR="$canonical"
  printf '%s' "$canonical"
}
