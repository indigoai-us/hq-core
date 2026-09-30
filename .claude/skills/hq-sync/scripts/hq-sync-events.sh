#!/usr/bin/env bash
# hq-core: public
# Event-handling helpers for the /hq-sync skill.
#
# The skill's implementation block sources this file so the same logic can be
# exercised by `.claude/skills/hq-sync/tests/hq-sync-events.test.sh` against
# recorded ndjson fixtures, without spawning a runner or touching the vault.
#
# Runner event contract: repos/private/hq-cloud/src/bin/sync-runner.ts.
#   stdout: setup-needed, fanout-plan, plan, progress, complete, all-complete,
#           conflicts-remaining
#   stderr: error, auth-error
#
# Runner exit codes: 0 protocol completed, 1 argv/pre-sync failure,
# 2 deterministic partial failure, 75 retryable network failure.
#
# Skill exit codes:
#   0  sync completed, every company reached "complete"
#   2  not signed in (token file absent, or the runner emitted auth-error)
#   3  the run was partial — at least one company did not complete
#   1  the runner failed for another reason (its exit code is passed through
#      when it is not one of the cases above)

# Exit code the skill uses when the runner reports partial: true.
HQ_SYNC_PARTIAL_EXIT=3

# hq_sync_has_auth_error <err_file>
# Returns 0 when the runner emitted an auth-error event on stderr.
hq_sync_has_auth_error() {
  local err_file="${1:-}"
  [ -n "$err_file" ] && [ -f "$err_file" ] || return 1
  grep -q '"type":"auth-error"' "$err_file" 2>/dev/null
}

# hq_sync_print_auth_error
# The one message a signed-out user needs.
hq_sync_print_auth_error() {
  echo "Not signed in — run /hq-login" >&2
}

# hq_sync_exit_note <runner_exit_code>
# Prints a plain explanation for the runner exit codes a user can act on.
hq_sync_exit_note() {
  local code="${1:-0}"
  case "$code" in
    75)
      echo ""
      echo "The network interrupted the sync. Nothing is corrupt. Run /hq-sync again."
      ;;
  esac
}

# hq_sync_count_tombstoned_files <events_file>
# Tombstone counts are emitted on per-company `complete` events. The final
# `all-complete` event has the download total but no tombstone aggregate.
hq_sync_count_tombstoned_files() {
  local events_file="${1:-}"
  local files_tombstoned
  [ -n "$events_file" ] && [ -f "$events_file" ] || { echo 0; return 0; }
  if ! files_tombstoned="$(jq -sr '
    [ .[] | select(.type == "complete") | (.filesTombstoned // 0) ]
    | if all(.[]; type == "number" and . >= 0 and floor == .)
      then (add // 0)
      else "invalid"
      end
  ' "$events_file" 2>/dev/null)"; then
    files_tombstoned=invalid
  fi
  printf '%s\n' "$files_tombstoned"
}

# hq_sync_post_pull_reindex_flag_enabled
# Avoid starting Node when the hq-flags endpoint or company identity is absent
# or malformed. The CJS reader uses the same default-off flag-client pattern as
# hq-autocommit-failure-context-flag.cjs.
hq_sync_post_pull_reindex_flag_enabled() {
  local endpoint="${HQ_FLAGS_API_URL:-}"
  local company_uid="${HQ_COMPANY_UID:-}"
  local cli_bin="${HQ_CLI_BIN:-}"
  local reader_dir reader enabled

  [[ "$endpoint" =~ ^https?://[^/[:space:]]+(/[^[:space:]]*)?$ ]] || return 1
  [[ "$company_uid" =~ ^cmp_[A-Za-z0-9]{3,128}$ ]] || return 1
  if [ -z "$cli_bin" ]; then cli_bin="$(command -v hq 2>/dev/null || true)"; fi
  [ -n "$cli_bin" ] && [ -x "$cli_bin" ] || return 1
  command -v node >/dev/null 2>&1 || return 1

  reader_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  reader="$reader_dir/hq-sync-post-pull-reindex-flag.cjs"
  [ -f "$reader" ] || return 1
  enabled="$(HQ_CLI_BIN="$cli_bin" node "$reader" 2>/dev/null)" || return 1
  [ "$enabled" = true ]
}

# hq_sync_post_pull_reindex <hq_root> <files_downloaded> <files_tombstoned>
# The --companies runner skips reindex per company to avoid repeated work.
# Refresh namespaced wrappers only when the default-off hq-flags gate is enabled
# and the pull changed files. This is best-effort; never replace sync's status.
hq_sync_post_pull_reindex() {
  local hq_root="${1:-}"
  local files_downloaded="${2:-0}"
  local files_tombstoned="${3:-0}"
  local reindex_status=0

  for count in "$files_downloaded" "$files_tombstoned"; do
    case "$count" in
      ''|*[!0-9]*)
        echo "Warning: company-skill reindex skipped because a file-change count was invalid." >&2
        return 0
        ;;
    esac
  done
  [ "$files_downloaded" -gt 0 ] || [ "$files_tombstoned" -gt 0 ] || return 0
  if [ -z "$hq_root" ]; then
    echo "Warning: company-skill reindex skipped because the HQ root is empty." >&2
    return 0
  fi
  hq_sync_post_pull_reindex_flag_enabled || return 0

  hq reindex --repo-root "$hq_root" || reindex_status=$?
  if [ "$reindex_status" -ne 0 ]; then
    echo "Warning: company-skill reindex failed (exit $reindex_status); sync result is unchanged. Run 'hq reindex --repo-root <hqRoot>' to retry." >&2
  fi
  return 0
}

# hq_sync_count_conflict_twins <hq_root>
# Counts on-disk `.conflict-*` twin files under the HQ root. node_modules,
# .git, and workspace/tmp are excluded: they hold generated or scratch content
# that no one resolves by hand.
hq_sync_count_conflict_twins() {
  local hq_root="${1:-}"
  if [ -z "$hq_root" ] || [ ! -d "$hq_root" ]; then
    echo 0
    return 0
  fi
  find "$hq_root" \
    \( -type d \( -name node_modules -o -name .git \) -prune \) -o \
    \( -path "$hq_root/workspace/tmp" -prune \) -o \
    \( -type f -name '*.conflict-*' -print \) 2>/dev/null | wc -l | tr -d ' '
}

# hq_sync_report_summary <output_file>
# Prints the `=== Summary ===` block from the last all-complete event, then the
# honest completeness read: every company whose status is not "complete", and
# the retryable transport failures the runner kept out of `errors`.
# Returns $HQ_SYNC_PARTIAL_EXIT when the run was partial, 0 otherwise.
# Returns 0 when there is no all-complete event (Step 5c handles that case).
hq_sync_report_summary() {
  local output_file="${1:-}"
  local final_event
  final_event="$(grep -E '^\{"type":"all-complete"' "$output_file" 2>/dev/null | tail -1 || true)"
  [ -n "$final_event" ] || return 0

  local companies files_d files_u conflicts errors partial
  companies=$(printf '%s' "$final_event" | jq -r '.companiesAttempted // 0' 2>/dev/null || echo 0)
  files_d=$(printf '%s' "$final_event" | jq -r '.filesDownloaded // 0' 2>/dev/null || echo 0)
  files_u=$(printf '%s' "$final_event" | jq -r '.filesUploaded // 0' 2>/dev/null || echo 0)
  conflicts=$(printf '%s' "$final_event" | jq -r '(.conflictPaths // []) | length' 2>/dev/null || echo 0)
  errors=$(printf '%s' "$final_event" | jq -r '(.errors // []) | length' 2>/dev/null || echo 0)
  partial=$(printf '%s' "$final_event" | jq -r 'if .partial == true then "true" else "false" end' 2>/dev/null || echo false)

  echo ""
  echo "=== Summary ==="
  echo "Companies synced: $companies"
  echo "Files: $files_d ↓ / $files_u ↑"
  echo "Conflicts: $conflicts"
  echo "Errors: $errors"

  if [ "$conflicts" != "0" ]; then
    echo ""
    echo "Conflicts:"
    printf '%s' "$final_event" | jq -r '(.conflictPaths // [])[] | "  - \(.company)/\(.path) (\(.direction))"' 2>/dev/null || true
    echo ""
    echo "Run /resolve-conflicts to walk them interactively."
  fi

  if [ "$errors" != "0" ]; then
    echo ""
    echo "Errors:"
    printf '%s' "$final_event" | jq -r '(.errors // [])[] | "  - \(.company): \(.message)"' 2>/dev/null || true
  fi

  [ "$partial" = "true" ] || return 0

  # `errors.length > 0` is not enough: a company that cleanly conflict-aborted
  # never lands in `errors`. `companies[].status` is the canonical signal.
  echo ""
  echo "=== This sync did not finish ==="
  echo "Some companies did not complete. The totals above count only what"
  echo "transferred before they stopped."
  echo ""
  printf '%s' "$final_event" \
    | jq -r '(.companies // [])[] | select(.status != "complete") | "  - \(.company): \(.status)"' 2>/dev/null || true

  local transient_count
  transient_count=$(printf '%s' "$final_event" | jq -r '(.transient // []) | length' 2>/dev/null || echo 0)
  if [ "$transient_count" != "0" ]; then
    echo ""
    echo "Retryable network failures:"
    printf '%s' "$final_event" | jq -r '(.transient // [])[] | "  - \(.company): \(.message)"' 2>/dev/null || true
  fi

  return "$HQ_SYNC_PARTIAL_EXIT"
}

# hq_sync_report_conflicts_remaining <output_file> <hq_root>
# Surfaces conflict residue from two sources: the runner's conflicts-remaining
# event (ledger rows preserved by the post-sync prune) and a direct count of
# `.conflict-*` twins on disk. The two disagree in practice — legacy twins sit
# outside the ledger, so `/resolve-conflicts` alone can show a clean slate over
# hundreds of unresolved files. Print both, and the doctor command that reaches
# the twins.
hq_sync_report_conflicts_remaining() {
  local output_file="${1:-}"
  local hq_root="${2:-}"

  local event count sample_shown=0
  event="$(grep -E '^\{"type":"conflicts-remaining"' "$output_file" 2>/dev/null | tail -1 || true)"
  if [ -n "$event" ]; then
    count=$(printf '%s' "$event" | jq -r '.count // 0' 2>/dev/null || echo 0)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    if [ "$count" != "0" ]; then
      echo ""
      echo "=== Conflicts still awaiting resolution ==="
      echo "$count conflict entr(ies) remain in the ledger."
      printf '%s' "$event" | jq -r '(.samplePaths // [])[] | "  - \(.)"' 2>/dev/null || true
      echo "Run /resolve-conflicts to walk them interactively."
      sample_shown=1
    fi
  fi

  local twins
  twins="$(hq_sync_count_conflict_twins "$hq_root")"
  if [ "$twins" != "0" ]; then
    if [ "$sample_shown" = "0" ]; then
      echo ""
      echo "=== Conflicts still awaiting resolution ==="
    fi
    echo ""
    echo "$twins .conflict-* twin file(s) are on disk. Legacy twins live outside"
    echo "the conflict ledger, so /resolve-conflicts does not see them."
    echo "Preview what would be folded back (this does not change anything):"
    echo "  hq sync doctor --reconcile-conflicts --hq-root $hq_root"
  fi

  return 0
}
