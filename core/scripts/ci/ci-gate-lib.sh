#!/usr/bin/env bash
# Shared helpers for the pr-checks path gates (should-run-*.sh).
# Source this file; it defines functions only.

# ci_gate_forced MODE
# Succeeds when the event mode always runs the full suite: the nightly
# schedule, a manual workflow_dispatch, or a forced full run (the `full-ci`
# PR label or the workflow_dispatch full_run input).
ci_gate_forced() {
  case "${1:-}" in
    schedule|workflow_dispatch|forced) return 0 ;;
    *) return 1 ;;
  esac
}

# ci_gate_core_yaml_stamp_only BASE HEAD ROOT
# Succeeds when core/core.yaml changed between BASE and HEAD and every changed
# line is a release stamp (hqVersion or updatedAt). Release-stamp commits are
# about half of the pushes to main and change no shell behavior, so they do
# not select the platform shell smoke jobs on their own.
ci_gate_core_yaml_stamp_only() {
  local base="$1" head="$2" root="$3" diff line saw_change=0
  diff="$(git -C "$root" diff --unified=0 --no-color "$base" "$head" -- core/core.yaml)" || return 1
  [[ -n "$diff" ]] || return 1
  while IFS= read -r line; do
    case "$line" in
      'diff --git '*|'index '*|'--- '*|'+++ '*|'@@ '*) continue ;;
      '+hqVersion: '*|'-hqVersion: '*|'+updatedAt: '*|'-updatedAt: '*) saw_change=1 ;;
      *) return 1 ;;
    esac
  done <<< "$diff"
  [[ "$saw_change" -eq 1 ]]
}
