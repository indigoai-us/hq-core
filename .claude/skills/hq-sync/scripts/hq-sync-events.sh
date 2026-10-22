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
# 2 deterministic partial failure, 17 another sync holds the per-root operation
# lock (Auto-sync or the desktop app is mid-pass), 75 retryable network failure.
#
# Skill exit codes:
#   0  sync completed, every company reached "complete", or another sync was
#      already running (runner exit 17) and this run stepped aside
#   2  not signed in (token file absent, or the runner emitted auth-error)
#   3  the run was partial — at least one company did not complete
#   1  the runner failed for another reason (its exit code is passed through
#      when it is not one of the cases above)

# Exit code the skill uses when the runner reports partial: true.
HQ_SYNC_PARTIAL_EXIT=3

# Runner exit code when another sync holds the per-root operation lock
# (hq-cloud OPERATION_LOCKED_EXIT). Not a failure: the other pass does the work.
HQ_SYNC_RUNNER_LOCKED_EXIT=17

# hq_sync_skill_exit_code <runner_exit_code>
# Maps the runner's exit code to the skill's. A lock collision with Auto-sync
# or the desktop app is a benign skip, so it exits 0 instead of reading as a
# failed sync (feedback_a91e5a77). Every other code passes through.
hq_sync_skill_exit_code() {
  local code="${1:-0}"
  if [ "$code" = "$HQ_SYNC_RUNNER_LOCKED_EXIT" ]; then
    echo 0
  else
    echo "$code"
  fi
}

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
    17)
      echo ""
      echo "Another sync was already running (Auto-sync or the HQ Desktop App),"
      echo "so this run stepped aside and did not sync. Nothing failed."
      echo "Run /hq-sync again after it finishes for a fresh result."
      ;;
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

# hq_sync_post_pull_reindex <hq_root> <files_downloaded> <files_tombstoned>
# The --companies runner skips reindex per company to avoid repeated work, so
# /hq-sync runs one `hq reindex` after a pull that downloaded or tombstoned
# files. That builds per-machine company skill wrappers. Best-effort: never
# replace sync's status. HQ_NO_UPDATE_CHECK keeps this from kicking a CLI
# self-update in the middle of a finished sync.
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

  HQ_NO_UPDATE_CHECK=1 hq reindex --repo-root "$hq_root" || reindex_status=$?
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

# hq_sync_report_scope_gaps <output_file>
# Surfaces each `scope-materialization-gap` event the runner emitted: files the
# cloud holds for a company that this sync's plan marked `skip-out-of-scope`
# because the membership's sync mode is `shared` or `custom`. It only renders
# events the runner supplies. A prefix-scoped pull (for example a teammate
# granted only `knowledge/`) never lists root-level files such as board.json,
# so the runner emits no event for them and this prints nothing
# (feedback_a91e5a77 follow-up). Prints the count, sample paths, and the two
# ways to get the files.
hq_sync_report_scope_gaps() {
  local output_file="${1:-}"
  [ -n "$output_file" ] && [ -f "$output_file" ] || return 0
  local events
  events="$(grep -E '^\{"type":"scope-materialization-gap"' "$output_file" 2>/dev/null || true)"
  [ -n "$events" ] || return 0

  local line company count mode printed=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    company=$(printf '%s' "$line" | jq -r '.company // "unknown"' 2>/dev/null || echo unknown)
    count=$(printf '%s' "$line" | jq -r '.count // 0' 2>/dev/null || echo 0)
    mode=$(printf '%s' "$line" | jq -r '.syncMode // "shared"' 2>/dev/null || echo shared)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    [ "$count" != "0" ] || continue
    if [ "$printed" = "0" ]; then
      echo ""
      echo "=== Files this sync did not download ==="
      printed=1
    fi
    echo "$company: $count file(s) in the cloud were not downloaded because this"
    echo "membership syncs in '$mode' mode (only the paths shared with you)."
    printf '%s' "$line" | jq -r '(.samplePaths // [])[] | "  - \(.)"' 2>/dev/null || true
    echo "To download everything you have access to: hq sync mode all --company $company"
    echo "To fetch one file and keep it synced: hq files get companies/$company/<path>"
  done <<EOF
$events
EOF
  return 0
}
