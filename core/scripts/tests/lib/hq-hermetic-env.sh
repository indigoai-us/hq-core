#!/usr/bin/env bash

# Run a command in a clean environment while carrying the pinned CLI opt-out
# through CI hermetic tests when the caller has set it.
hq_test_clean_env() {
  if [ "${HQ_NO_UPDATE_CHECK+x}" = x ]; then
    env -i "HQ_NO_UPDATE_CHECK=$HQ_NO_UPDATE_CHECK" "$@"
  else
    env -i "$@"
  fi
}

# Background fixtures that signal or inspect the command PID use this variant
# so the helper shell is replaced by env and preserves the child PID contract.
hq_test_clean_env_exec() {
  if [ "${HQ_NO_UPDATE_CHECK+x}" = x ]; then
    exec env -i "HQ_NO_UPDATE_CHECK=$HQ_NO_UPDATE_CHECK" "$@"
  else
    exec env -i "$@"
  fi
}
