# shellcheck shell=bash
# portable.sh — shared OS-portability helpers for hq-core shell scripts.
#
# SOURCED, never executed:  . "$ROOT/core/scripts/lib/portable.sh"
# bash 3.2 safe; works under Linux, macOS, and Windows Git Bash with set -u.
#
# Canonicalizes good in-repo dual-implementation patterns:
#   - work-mesh-lib.sh wm_file_mtime (numeric-probe dual stat)
#   - archive-old-threads.sh dual stat / date -d | date -v
#   - compute-checksums.sh Git Bash awareness
#
# JSON engines are NOT here — source core/scripts/hook-lib.sh (hq_json_get /
# hq_json_encode: jq first, then node). This file owns OS primitives + hard-fail
# jq install messaging only.

# portable_stat_mtime <path>
#   Print mtime as epoch seconds. Uses BSD-form stat -f first, accepts only a
#   strictly numeric result (GNU stat -f is filesystem mode and may print text),
#   then falls through to GNU stat -c. Mirrors work-mesh-lib.sh:215-230.
#   Returns 1 when both forms fail.
portable_stat_mtime() {
  local f="${1:-}" value
  [ -n "$f" ] || return 1
  value="$(stat -f %m "$f" 2>/dev/null)" || value=""
  case "$value" in
    ''|*[!0-9]*) ;;
    *) printf '%s' "$value"; return 0 ;;
  esac
  value="$(stat -c %Y "$f" 2>/dev/null)" || value=""
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s' "$value"; return 0 ;;
  esac
}

# portable_sed_inplace <sed-script> <file> [extra sed args...]
#   In-place sed that works on both GNU sed (sed -i) and BSD sed (sed -i '').
portable_sed_inplace() {
  local script="${1:-}"
  local file="${2:-}"
  shift 2 2>/dev/null || true
  [ -n "$script" ] && [ -n "$file" ] || return 1
  [ -f "$file" ] || return 1
  # Prefer GNU form; fall back to BSD empty-suffix form.
  if sed --version >/dev/null 2>&1; then
    sed -i "$@" -e "$script" "$file"
  else
    sed -i '' "$@" -e "$script" "$file"
  fi
}

# portable_tmpdir
#   Print a writable temp directory (no trailing slash). Prefer TMPDIR, else /tmp.
portable_tmpdir() {
  local d="${TMPDIR:-/tmp}"
  # Strip trailing slash except for root.
  case "$d" in
    /) printf '%s' "$d" ;;
    */) printf '%s' "${d%/}" ;;
    *) printf '%s' "$d" ;;
  esac
}

# portable_date_epoch_to_iso <epoch_seconds>
#   Convert epoch seconds to UTC ISO-8601 (YYYY-MM-DDTHH:MM:SSZ).
#   Dual: GNU date -d @N / BSD date -r N.
portable_date_epoch_to_iso() {
  local epoch="${1:-}"
  case "$epoch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  date -u -d "@${epoch}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || return 1
}

# portable_user
#   Print a filename-safe user key from USER or USERNAME (Git Bash often lacks USER).
portable_user() {
  local u="${USER:-${USERNAME:-unknown}}"
  # shellcheck disable=SC2001
  u="$(printf '%s' "$u" | sed 's/[^[:alnum:]_.-]/_/g')"
  [ -n "$u" ] || u="unknown"
  printf '%s' "$u"
}

# portable_jq_install_hint
#   Print multi-line per-OS jq install guidance to stdout.
portable_jq_install_hint() {
  # Single multi-OS line so portability lint does not flag brew-only messages.
  printf '%s\n' "Install jq: Windows: winget install jqlang.jq | choco install jq | scoop install jq; Linux: sudo apt install jq | sudo dnf install jq; macOS: brew install jq"
}

# require_jq
#   Return 0 if jq is on PATH. Otherwise print install guidance to stderr and
#   return 1. Caller decides whether to die. Does not implement JSON parse.
require_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  printf 'jq is required but not installed.\n' >&2
  portable_jq_install_hint >&2
  return 1
}

# portable_native_path <path>
#   Print a path a native (non-MSYS) Windows binary can open. Git Bash mktemp
#   and $TMPDIR often yield /tmp/... which Node's hq.exe cannot read, so
#   --body-file looks empty. cygpath -m produces C:/... mixed paths. On
#   POSIX hosts this is identity. Empty input returns 1.
portable_native_path() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$p" 2>/dev/null || printf '%s' "$p"
    return 0
  fi
  printf '%s' "$p"
}

# portable_qmd_models_dir
#   Print qmd's GGUF cache directory (no trailing slash). Override with
#   QMD_MODELS_DIR. Otherwise XDG_CACHE_HOME/qmd/models, then
#   HOME/.cache/qmd/models, then USERPROFILE/.cache/qmd/models (Windows).
portable_qmd_models_dir() {
  local d
  if [ -n "${QMD_MODELS_DIR:-}" ]; then
    d="$QMD_MODELS_DIR"
  elif [ -n "${XDG_CACHE_HOME:-}" ]; then
    d="$XDG_CACHE_HOME/qmd/models"
  elif [ -n "${HOME:-}" ]; then
    d="$HOME/.cache/qmd/models"
  elif [ -n "${USERPROFILE:-}" ]; then
    d="$USERPROFILE/.cache/qmd/models"
    if command -v cygpath >/dev/null 2>&1; then
      d="$(cygpath -u "$d" 2>/dev/null || printf '%s' "$d")"
    fi
  else
    return 1
  fi
  case "$d" in
    */) d="${d%/}" ;;
  esac
  printf '%s' "$d"
}

# portable_qmd_embed_model_ready
#   Return 0 when a usable GGUF already sits in the qmd models dir so
#   vsearch/query/embed will not start a multi-hundred-MB download. A file
#   named by QMD_EMBED_MODEL (basename after the last /) counts; otherwise
#   any *.gguf of at least 1 MiB counts. Missing dir or tiny placeholders
#   return 1.
portable_qmd_embed_model_ready() {
  local dir want f sz
  dir="$(portable_qmd_models_dir)" || return 1
  [ -d "$dir" ] || return 1
  if [ -n "${QMD_EMBED_MODEL:-}" ]; then
    want="${QMD_EMBED_MODEL##*/}"
    if [ -n "$want" ] && [ -f "$dir/$want" ]; then
      sz="$(wc -c < "$dir/$want" | tr -d '[:space:]')"
      case "$sz" in
        ''|*[!0-9]*) ;;
        *) [ "$sz" -ge 1048576 ] && return 0 ;;
      esac
    fi
  fi
  for f in "$dir"/*.gguf; do
    [ -f "$f" ] || continue
    sz="$(wc -c < "$f" | tr -d '[:space:]')"
    case "$sz" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$sz" -ge 1048576 ] && return 0
  done
  return 1
}

# portable_qmd_cmd_would_download_model <command>
#   Return 0 when a shell command would invoke qmd vsearch, query, embed, or
#   pull — the subcommands that auto-download GGUF models on first use.
#   First non-flag argument after a qmd token is the subcommand, so
#   `qmd search "how to vsearch"` is NOT a match.
portable_qmd_cmd_would_download_model() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || return 1
  case "$cmd" in
    *qmd*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$cmd" | awk '
    BEGIN { found = 0 }
    {
      n = split($0, raw, /[[:space:];|&]+/)
      for (i = 1; i <= n; i++) {
        tok = raw[i]
        if (tok == "") continue
        base = tok
        sub(/^.*\//, "", base)
        if (base == "qmd" || base == "qmd.exe") {
          j = i + 1
          while (j <= n && raw[j] ~ /^-/) j++
          if (j <= n && raw[j] ~ /^(vsearch|query|embed|pull)$/) {
            found = 1
            exit
          }
        }
      }
    }
    END { exit found ? 0 : 1 }
  '
}
