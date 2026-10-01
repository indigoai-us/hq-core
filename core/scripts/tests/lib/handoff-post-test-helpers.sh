#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/hq-hermetic-env.sh"

# Run handoff-post with an explicit fixture root, regardless of the caller's
# exported HQ_ROOT. Remaining arguments are NAME=value child environment.
handoff_post_test_run() {
  local env_mode=inherit
  if [[ "${1:-}" == "--clean-env" ]]; then
    env_mode=clean
    shift
  fi
  local fixture_root="$1"
  local thread_path="$2"
  local learnings_path="$3"
  shift 3

  (
    cd "$fixture_root" || exit 1
    if [[ "$env_mode" == clean ]]; then
      hq_test_clean_env "$@" HQ_ROOT="$fixture_root" \
        bash core/scripts/handoff-post.sh "$thread_path" "$learnings_path"
    else
      env "$@" HQ_ROOT="$fixture_root" \
        bash core/scripts/handoff-post.sh "$thread_path" "$learnings_path"
    fi
  )
}
