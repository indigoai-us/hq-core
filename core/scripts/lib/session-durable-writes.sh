#!/usr/bin/env bash
# hq-core: public
# session-durable-writes.sh — resolve company project dir + detect residual
# workspace writes for hq-agent-session (US-407 absorbed into US-408).
#
# Durable home: <root>/companies/<companySlug>/projects/<projectSlug>
# Residual workspace writes (except sessions/** and locks/**) surface as
# nonDurableWrites[]; files under the project dir surface as artifacts[].

# Upper bound on paths serialised into a finalize array.
#
# These arrays are DIAGNOSTIC METADATA describing what a turn touched, not a
# durable record of it. A turn that touched tens of thousands of files is
# already pathological, and serialising every one of them is what killed the
# turn rather than what reported it. Truncate and say so on stderr.
: "${SESSION_PATHS_MAX:=1000}"

# session_validate_project_slug <slug>
#   Accepts only [a-z0-9-]{1,64}. Rejects empty, '/', '..', uppercase, etc.
#   Exit 0 if valid, 1 otherwise (no directory created).
session_validate_project_slug() {
  local slug="${1-}"
  case "$slug" in
    ''|*'/'*|*'..'*) return 1 ;;
  esac
  grep -Eq '^[a-z0-9-]{1,64}$' <<< "$slug" || return 1
  return 0
}

# session_project_slug_from_convkey <convKey>
#   Deterministic project slug for threads that omit request.project.
#   Output always matches ^[a-z0-9-]{1,64}$.
session_project_slug_from_convkey() {
  local conv_key="${1-}"
  local hash
  [ -n "$conv_key" ] || { printf 'conv-unknown'; return 0; }
  if command -v shasum >/dev/null 2>&1; then
    hash="$(printf '%s' "$conv_key" | shasum -a 256 2>/dev/null | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$conv_key" | sha256sum 2>/dev/null | awk '{print $1}')"
  else
    hash="$(printf '%s' "$conv_key" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
  fi
  # p- + 32 hex = 34 chars, well under 64
  if [ -n "$hash" ]; then
    printf 'p-%s' "$(printf '%s' "$hash" | cut -c1-32)"
  else
    printf 'p-%s' "$(printf '%s' "$conv_key" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | cut -c1-32)"
  fi
}

# session_resolve_project_dir <root> <companySlug> <project_or_empty> <convKey>
#   Resolves slug (request.project or derived), validates, creates
#   companies/<co>/projects/<slug>, exports HQ_SESSION_PROJECT_DIR, prints it.
#   Exit non-zero on invalid slug (no directory created).
session_resolve_project_dir() {
  local root="${1:-}" company="${2:-}" project="${3-}" conv_key="${4-}"
  local slug dir
  [ -n "$root" ] && [ -n "$company" ] || return 1

  if [ -n "$project" ] && [ "$project" != "null" ]; then
    slug="$project"
  else
    slug="$(session_project_slug_from_convkey "$conv_key")"
  fi

  if ! session_validate_project_slug "$slug"; then
    echo "hq-agent-session: invalid project slug: ${slug}" >&2
    return 1
  fi

  dir="$root/companies/$company/projects/$slug"
  mkdir -p "$dir" || return 1
  export HQ_SESSION_PROJECT_DIR="$dir"
  printf '%s' "$dir"
  return 0
}

# session_append_durable_guidance <system_file>
#   Appends a durable-writes section instructing the model to write plans /
#   brainstorms / research under $HQ_SESSION_PROJECT_DIR (literal dollar form).
session_append_durable_guidance() {
  local system_file="${1:-}"
  [ -n "$system_file" ] && [ -f "$system_file" ] || return 0
  {
    printf '\n<!-- hq-section: durable-writes -->\n'
    printf 'Durable session writes: plans, brainstorms, and research files MUST be written under $HQ_SESSION_PROJECT_DIR.\n'
    if [ -n "${HQ_SESSION_PROJECT_DIR:-}" ]; then
      printf 'Resolved project directory: %s\n' "$HQ_SESSION_PROJECT_DIR"
    fi
    printf 'Do not rely on workspace/ for durable artifacts — workspace is not synced.\n'
  } >> "$system_file"
}

# _session_mtime_epoch <path> → epoch seconds
_session_mtime_epoch() {
  local f="${1:-}" value
  [ -n "$f" ] && [ -e "$f" ] || return 1
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

# _session_find_newer <dir> <epoch> [mode] → absolute paths on stdout, one per line
#   Portable mtime compare (works where find -newermt @epoch is unavailable).
#   AC wording uses find -newermt @runStartEpoch; implementation is equivalent:
#   files whose mtime >= runStartEpoch. mode=workspace additionally prunes the
#   provider-owned top-level <dir>/.session-logs telemetry tree.
_session_find_newer() {
  local dir="${1:-}" start="${2:-}" mode="${3:-any}"
  local path mt provider_logs
  local -a prune_expr=(-name node_modules -o -name .git -o -name .pnpm)
  [ -d "$dir" ] || return 0
  case "$start" in ''|*[!0-9]*) start=0 ;; esac
  if [ "$mode" = "workspace" ]; then
    # find -path treats [, *, and ? in an HQ root as glob syntax. Compare the
    # rare candidate directory as an exact string instead, so unusual but valid
    # install paths cannot make the provider telemetry tree visible again.
    provider_logs="${dir%/}/.session-logs"
    prune_expr+=(-o \( -type d -name .session-logs -exec test '{}' = "$provider_logs" \; \))
  fi

  # Heavyweight dependency/VCS/provider-log trees are never durable artifacts;
  # scanning them per-file once cost 100k+ subprocesses (>400s) on a fleet box
  # with an abandoned node_modules under workspace/. A Grok session-log export
  # also refreshed 47k files under workspace/.session-logs after the provider
  # exited, making finalization outlive the inbox lane and discard a completed
  # reply. Prune all of these implementation-owned trees in both paths.
  # Fast path: GNU find (-newermt) — one process for the whole walk.
  if find "$dir" -maxdepth 0 -newermt "@0" >/dev/null 2>&1; then
    find "$dir" \( "${prune_expr[@]}" \) -prune \
      -o -type f -newermt "@$(( start - 1 ))" -print 2>/dev/null || true
    return 0
  fi
  # Portable fallback (BSD/macOS): per-file mtime compare, same pruning.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    mt="$(_session_mtime_epoch "$path" 2>/dev/null || echo 0)"
    case "$mt" in ''|*[!0-9]*) continue ;; esac
    if [ "$mt" -ge "$start" ]; then
      printf '%s\n' "$path"
    fi
  done < <(find "$dir" \( "${prune_expr[@]}" \) -prune \
    -o -type f -print 2>/dev/null || true)
}

# _session_paths_to_json_array <root> <mode>
#   mode=workspace → keep workspace/* excluding sessions/** locks/**
#   mode=any → keep any path under root
#   Reads absolute paths from stdin.
_session_paths_to_json_array() {
  local root="${1:-}" mode="${2:-any}"
  local path rel n=0
  # ONE jq for the whole stream, not one per path.
  #
  # This used to run `jq -nc --arg p "$rel" '$p'` INSIDE the loop -- a full
  # process spawn per file, whose only job was to JSON-escape one short string
  # -- and hand-assemble the brackets and commas around it. Post-turn
  # bookkeeping on a box whose turn touched ~47k workspace files therefore cost
  # ~47k process spawns, AFTER the model had already produced its answer. That
  # outran the dispatch lane's 900s absolute cap, the engine was killed before
  # it emitted, and the completed reply was discarded as
  # "unexpected failure (exit 0)".
  #
  # The escaping still has to happen (paths carry quotes and backslashes), so
  # jq stays -- it just runs once: -R reads raw lines instead of JSON, -s slurps
  # the stream, and jq emits the array delimiters itself.
  {
    while IFS= read -r path || [ -n "$path" ]; do
      [ -n "$path" ] || continue
      case "$path" in
        "$root"/*) rel="${path#"$root"/}" ;;
        *) continue ;;
      esac
      if [ "$mode" = "workspace" ]; then
        case "$rel" in
          workspace/sessions|workspace/sessions/*) continue ;;
          workspace/locks|workspace/locks/*) continue ;;
          workspace/*) ;;
          *) continue ;;
        esac
      fi
      n=$((n + 1))
      if [ "$n" -eq "$(( SESSION_PATHS_MAX + 1 ))" ]; then
        printf 'hq-agent-session: finalize path list truncated at %s entries (this turn touched more)\n' \
          "$SESSION_PATHS_MAX" >&2
      fi
      if [ "$n" -le "$SESSION_PATHS_MAX" ]; then
        printf '%s\n' "$rel"
      fi
    done
  } | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

# session_collect_non_durable_writes <root> <runStartEpoch>
#   JSON array of HQ-root-relative workspace paths with mtime >= runStartEpoch,
#   excluding workspace/sessions/** and workspace/locks/**.
session_collect_non_durable_writes() {
  local root="${1:-}" start="${2:-}"
  local ws
  [ -n "$root" ] || { printf '[]'; return 0; }
  ws="$root/workspace"
  [ -d "$ws" ] || { printf '[]'; return 0; }
  _session_find_newer "$ws" "$start" workspace | _session_paths_to_json_array "$root" workspace
}

# session_collect_project_artifacts <root> <projectDir> <runStartEpoch>
#   JSON array of HQ-root-relative paths under projectDir with mtime >= start.
session_collect_project_artifacts() {
  local root="${1:-}" project_dir="${2:-}" start="${3:-}"
  [ -n "$root" ] && [ -n "$project_dir" ] && [ -d "$project_dir" ] || { printf '[]'; return 0; }
  _session_find_newer "$project_dir" "$start" | _session_paths_to_json_array "$root" any
}
