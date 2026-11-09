#!/usr/bin/env bash
# Commit only knowledge-repo files explicitly named by the handoff changeset.
set -euo pipefail

usage() {
  echo "Usage: $0 --files-touched-json-file <path> [--root <hq-root>]" >&2
  exit 2
}

changeset=""
root="$(pwd -P)"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --files-touched-json-file) [ "$#" -ge 2 ] || usage; changeset="$2"; shift 2 ;;
    --root) [ "$#" -ge 2 ] || usage; root="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$changeset" ] && [ -f "$changeset" ] || usage
root="$(cd "$root" && pwd -P)"
tmp_parent="$root/workspace/threads/.handoff-tmp"

# These commits run hooks. When the HQ git-hooks dispatcher is installed (a
# global core.hooksPath), its commit-msg hook stamps HQ-Fingerprint, so an
# explicit trailer here would be a second copy. Pass it only when no global
# hooks path is set, i.e. the dispatcher is absent. The trailer is loaded
# lazily, once, before the first commit, so a handoff with nothing to commit
# never pays for it. A failing lib leaves the array empty and never blocks the
# commit.
HQ_FINGERPRINT_TRAILER_ARGS=()
fingerprint_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fingerprint.sh"
fingerprint_loaded=0
load_fingerprint_trailer_once() {
  [ "$fingerprint_loaded" -eq 0 ] || return 0
  fingerprint_loaded=1
  if [ -z "$(git config --global --get core.hooksPath 2>/dev/null || true)" ] && [ -f "$fingerprint_lib" ]; then
    # shellcheck source=lib/fingerprint.sh
    { . "$fingerprint_lib" 2>/dev/null && hq_fingerprint_trailer_load "$root"; } || HQ_FINGERPRINT_TRAILER_ARGS=()
  fi
  return 0
}
mkdir -p "$tmp_parent"
tmp_dir="$(mktemp -d "$tmp_parent/handoff-knowledge-commit.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
handled_paths="$tmp_dir/handled-paths"
: > "$handled_paths"

jq -e 'def safe_path: type == "string" and length > 0 and (startswith("/") | not) and (split("/") | all(.[]; . != "" and . != "." and . != "..")) and (contains("\n") | not) and (contains("\r") | not); type == "array" and all(.[]; if type == "string" then safe_path else type == "object" and (.path | safe_path) end)' "$changeset" >/dev/null || {
  echo "handoff knowledge commit: changeset must be an array of safe relative file paths (files, not folders: no trailing slash, no absolute paths, no .. segments)" >&2
  jq -r 'def safe_path: type == "string" and length > 0 and (startswith("/") | not) and (split("/") | all(.[]; . != "" and . != "." and . != "..")) and (contains("\n") | not) and (contains("\r") | not); if type == "array" then (.[] | select((if type == "string" then . elif type == "object" then .path else null end) | safe_path | not) | "  offending entry: " + tojson) else "  the changeset is not a JSON array" end' "$changeset" 2>/dev/null | head -5 >&2 || true
  exit 1
}

# Company scope: only the session's bound (primary) company is considered.
# Other companies' knowledge is never read or committed, including the other
# members of a multi-company lock (company_slugs). The bound company is
# HQ_ACTIVE_COMPANY; when that is empty (a company bound mid-session writes the
# session lock but cannot change the env of the running process) it is the
# lock's primary company_slug, read ONLY for a session id taken from the
# environment (session_id_from_env) and passed to hq-session.sh explicitly.
# workspace/sessions/.current is a global last-writer-wins pointer that can name
# another live session, so it is never used here. The reserved value "personal"
# means no company. A resolved slug must be a real directory under companies/
# and appear with exact case in companies/manifest.yaml, otherwise it is treated
# as unbound. With no bound company, company knowledge is skipped and the skip
# is reported with its reason.
skip_reason="no bound company"

# run_with_timeout <seconds> <cmd...>: timeout/gtimeout when present, else a
# background job with a bounded poll (portable to stock macOS).
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
  # Fallback. Call this only from a background subshell (see the lock read
  # below): the TERM/INT/HUP trap set here then never replaces the main shell's
  # traps. The output file lives in $tmp_dir, which the main EXIT trap removes.
  {
    out="$(mktemp "$tmp_dir/hkc-timeout.XXXXXX")" || exit 1
    pid=""
    kill_tree() {
      local parent="$1" child
      for child in $(pgrep -P "$parent" 2>/dev/null); do kill_tree "$child"; done
      kill "$parent" 2>/dev/null || true
    }
    cleanup_job() {
      [ -z "$pid" ] || { kill_tree "$pid"; wait "$pid" 2>/dev/null || true; }
      rm -f "$out"
    }
    trap 'cleanup_job; exit 143' TERM INT HUP
    "$@" >"$out" 2>/dev/null &
    pid=$!
    i=0
    while [ "$i" -lt $((secs * 10)) ]; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
      i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      cleanup_job
      exit 124
    fi
    rc=0
    wait "$pid" || rc=$?
    cat "$out"; rm -f "$out"
    exit "$rc"
  }
}

# company_is_registered <slug>: real (non-symlink) company directory and an
# exact-case key under companies: in companies/manifest.yaml.
company_is_registered() {
  local slug="$1" manifest="$root/companies/manifest.yaml" company_dir="$root/companies/$1"
  [ -d "$company_dir" ] && [ ! -L "$company_dir" ] || return 1
  [ -f "$manifest" ] || return 1
  awk -v want="$slug" '
    /^companies:[[:space:]]*$/ { inco = 1; next }
    inco && /^[^[:space:]#]/ { inco = 0 }
    inco && match($0, /^  [^[:space:]#][^:]*:/) {
      key = substr($0, 3, RLENGTH - 3)
      if (key == want) { found = 1; exit }
    }
    END { exit found ? 0 : 1 }' "$manifest" 2>/dev/null
}

bound_company="${HQ_ACTIVE_COMPANY:-}"
# The reserved value "personal" means no company, same as the lock route; do not
# fall through to the session lock.
if [ "$bound_company" = personal ]; then
  bound_company=""
elif [ -z "$bound_company" ]; then
  lock_session_id=""
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$lib_dir/lib/session-id.sh" ]; then
    # shellcheck source=lib/session-id.sh
    . "$lib_dir/lib/session-id.sh" 2>/dev/null || true
    if declare -F session_id_from_env >/dev/null 2>&1; then
      lock_session_id="$(session_id_from_env)"
    fi
  fi
  if [ -z "$lock_session_id" ]; then
    skip_reason="no bound company (no session id in the environment, session lock not read)"
  elif [ ! -f "$lib_dir/hq-session.sh" ]; then
    skip_reason="session lock unreadable"
  else
    lock_meta="$root/workspace/sessions/$lock_session_id/meta.yaml"
    if [ -e "$lock_meta" ] && [ ! -r "$lock_meta" ]; then
      skip_reason="session lock unreadable"
    else
      # Run the read as a background job and wait, so a TERM to this helper is
      # handled at once and takes the job (and its children) down with it.
      lock_out_file="$tmp_dir/lock-out"
      HQ_ROOT="$root" HQ_HQ_SESSION_NO_CLI=1 \
        run_with_timeout "${HQ_HANDOFF_LOCK_TIMEOUT:-5}" bash "$lib_dir/hq-session.sh" --session-id "$lock_session_id" get company_slug \
        >"$lock_out_file" &
      lock_job=$!
      trap 'kill -TERM "$lock_job" 2>/dev/null || true; wait "$lock_job" 2>/dev/null || true; exit 143' TERM INT HUP
      lock_rc=0
      wait "$lock_job" || lock_rc=$?
      trap - TERM INT HUP
      if [ "$lock_rc" -eq 0 ]; then
        lock_out="$(cat "$lock_out_file")"
        bound_company="$(printf '%s' "$lock_out" | tr -d '[:space:]')"
        [ "$bound_company" != personal ] || bound_company=""
      else
        skip_reason="session lock unreadable"
      fi
    fi
  fi
fi
company_knowledge=()
if [ -n "$bound_company" ]; then
  if [[ "$bound_company" =~ ^[A-Za-z0-9_-]+$ ]] && company_is_registered "$bound_company"; then
    company_knowledge=("$root/companies/$bound_company/knowledge")
  else
    skip_reason="company '$bound_company' is not a registered company"
    bound_company=""
  fi
fi
if [ -z "$bound_company" ]; then
  echo "SKIPPED-COMPANY-KNOWLEDGE: $skip_reason; company knowledge repositories were not processed"
fi

for knowledge_path in "$root"/core/knowledge/public/* "$root"/core/knowledge/private/* "$root"/personal/knowledge/* ${company_knowledge[@]+"${company_knowledge[@]}"}; do
  [ -e "$knowledge_path" ] || [ -L "$knowledge_path" ] || continue
  knowledge_rel="${knowledge_path#"$root"/}"
  if [ -L "$knowledge_path" ]; then
    case "$knowledge_path" in
      "$root"/companies/*/knowledge)
        echo "INVALID-LINK: $knowledge_rel is a symlink; company knowledge must be a plain directory synced through the company vault"
        ;;
      *)
        repo_dir="$(git -C "$knowledge_path" rev-parse --show-toplevel 2>/dev/null)" || continue
        repo_real="$(cd "$repo_dir" && pwd -P)"
        hq_repo="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || hq_repo=""
        hq_repo_real=""
        [ -z "$hq_repo" ] || hq_repo_real="$(cd "$hq_repo" && pwd -P)"
        [ "$repo_real" = "$hq_repo_real" ] && continue
        dirty="$(git -C "$repo_dir" status --porcelain)"
        [ -n "$dirty" ] || continue
        echo "INVALID-DIRTY: $knowledge_rel is a legacy knowledge symlink to $repo_dir with uncommitted changes — NOT auto-committed; run hq reindex to materialize it, then commit, before archiving this session"
        ;;
    esac
    continue
  fi
  # A plain company knowledge directory syncs through its vault; only a bound
  # company's knowledge that is its own git repository is committed here.
  [ -e "$knowledge_path/.git" ] || continue
  repo_dir="$(git -C "$knowledge_path" rev-parse --show-toplevel 2>/dev/null)" || continue
  knowledge_real="$(cd "$knowledge_path" && pwd -P)"
  repo_real="$(cd "$repo_dir" && pwd -P)"
  [ "$knowledge_real" = "$repo_real" ] || continue
  knowledge_rel="${knowledge_path#"$root"/}"
  repo_paths=()
  while IFS= read -r touched_path; do
    case "$touched_path" in
      "$knowledge_rel"/*) relative_path="${touched_path#"$knowledge_rel"/}" ;;
      *) continue ;;
    esac
    case "/$relative_path/" in */../*|*/./*)
      echo "handoff knowledge commit: unsafe path in changeset: $touched_path" >&2
      exit 1
      ;;
    esac
    [ -n "$relative_path" ] || continue
    if [ -d "$repo_dir/$relative_path" ]; then
      printf '%s\n' "$touched_path" >> "$handled_paths"
      while IFS= read -r -d '' status_entry; do
        status_code="${status_entry:0:2}"
        status_path="${status_entry:3}"
        case "$status_code" in *R*|*C*) IFS= read -r -d '' original_path || original_path="" ;; esac
        case "$status_path" in
          "$relative_path"/*)
            repo_paths+=("$status_path")
            printf '%s/%s\n' "$knowledge_rel" "$status_path" >> "$handled_paths"
            ;;
        esac
        case "$status_code" in *R*|*C*)
          case "$original_path" in
            "$relative_path"/*)
              repo_paths+=("$original_path")
              printf '%s/%s\n' "$knowledge_rel" "$original_path" >> "$handled_paths"
              ;;
          esac
          ;;
        esac
      done < <(git -C "$repo_dir" status --porcelain=v1 -z --untracked-files=all -- "$relative_path")
      continue
    fi
    if [ ! -e "$repo_dir/$relative_path" ] && ! git -C "$repo_dir" ls-files --error-unmatch -- "$relative_path" >/dev/null 2>&1; then
      continue
    fi
    repo_paths+=("$relative_path")
    printf '%s\n' "$touched_path" >> "$handled_paths"
  done < <(jq -r '.[] | if type == "string" then . else .path end' "$changeset")

  [ "${#repo_paths[@]}" -gt 0 ] || continue
  changed="$(git -C "$repo_dir" status --porcelain -- "${repo_paths[@]}")"
  [ -n "$changed" ] || continue
  git -C "$repo_dir" add -- "${repo_paths[@]}"
  load_fingerprint_trailer_once
  git -C "$repo_dir" commit --only -m "checkpoint: save session knowledge changes" ${HQ_FINGERPRINT_TRAILER_ARGS[@]+"${HQ_FINGERPRINT_TRAILER_ARGS[@]}"} -- "${repo_paths[@]}"
done

while IFS= read -r touched_path; do
  case "$touched_path" in
    core/knowledge/public/*|core/knowledge/private/*|personal/knowledge/*)
      if ! grep -Fqx -- "$touched_path" "$handled_paths"; then
        echo "NOT-COMMITTED: $touched_path is listed in the handoff changeset but no knowledge repository committed it"
      fi
      ;;
    companies/*/knowledge/*)
      [ -n "$bound_company" ] || continue
      case "$touched_path" in "companies/$bound_company/knowledge/"*) ;; *) continue ;; esac
      [ -e "$root/companies/$bound_company/knowledge/.git" ] || continue
      if ! grep -Fqx -- "$touched_path" "$handled_paths"; then
        echo "NOT-COMMITTED: $touched_path is listed in the handoff changeset but no knowledge repository committed it"
      fi
      ;;
  esac
done < <(jq -r '.[] | if type == "string" then . else .path end' "$changeset")
