#!/usr/bin/env bash
# FORWARDER — the implementation of this script now lives in the hq CLI.
#
# It ships at assets/scaffold/core/scripts/worktree.sh inside @indigoai-us/hq-cli and
# runs as the hidden command `hq core worktree`. This file stays behind so every
# existing caller — skills, other scripts, CI, and muscle memory — keeps working
# against the path it already knows.
#
# Why the implementation moved: it is a cold, explicitly-invoked operation where
# process startup is immaterial, so hosting it in the CLI costs nothing and
# keeps the scaffold to configuration rather than code.
#
# The ABI is preserved: arguments are forwarded unchanged, stdin is never read by
# this file, stderr streams through untouched, stdout carries the same bytes, and
# the child's exit code becomes the caller's. The one deliberate change from a
# bare `exec` is that stdout is buffered until the child completes so this
# forwarder can read the created worktree's path and drop a creation stamp for
# worktree-gc.sh (see below). Worktree creation is a fast cold operation, so
# buffering its stdout is immaterial and keeps stdout/stderr cleanly separated.
#
# The stamp records createdAt so the GC ages worktrees accurately instead of
# leaning on directory mtime (which drifts as files change). It is written to a
# sidecar registry OUTSIDE the worktree's tracked tree
# (workspace/worktrees/.gc-meta/<key>.json, itself gitignored) so it can never
# make the new worktree read as dirty — which would make the GC skip it forever.
# Stamp failures are swallowed: they must never break worktree creation.

set -euo pipefail

# This forwarder sits in the tree it targets, so its own location IS the root.
HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

if ! command -v hq >/dev/null 2>&1; then
  echo "worktree.sh: requires the hq CLI — this script's implementation now ships with it." >&2
  echo "Install it with: npm install -g @indigoai-us/hq-cli" >&2
  exit 127
fi

# stamp_worktree <cli-stdout-file> — parse the CLI's "path:/branch:/source:" report
# and write a GC creation stamp. Best-effort; any failure is swallowed by callers.
stamp_worktree() {
  local out_file="$1" wt="" branch="" source_repo=""
  wt=$(sed -n 's/^[[:space:]]*path:[[:space:]]*//p' "$out_file" | head -1)
  branch=$(sed -n 's/^[[:space:]]*branch:[[:space:]]*//p' "$out_file" | head -1)
  source_repo=$(sed -n 's/^[[:space:]]*source:[[:space:]]*//p' "$out_file" | head -1)
  [[ -n "$wt" && -d "$wt" ]] || return 0
  wt=$(cd "$wt" && pwd -P) || return 0
  local meta_dir="$HQ_ROOT/workspace/worktrees/.gc-meta"
  mkdir -p "$meta_dir" || return 0
  # Key MUST match path_key() in worktree-gc.sh: cksum of the absolute path.
  local key epoch iso
  key=$(printf '%s' "$wt" | cksum | cut -d' ' -f1)
  epoch=$(date -u +%s)
  iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -nc \
    --arg path "$wt" --arg branch "$branch" --arg source "$source_repo" \
    --arg createdAt "$iso" --argjson createdAtEpoch "$epoch" \
    '{path:$path,branch:$branch,source:$source,createdAt:$createdAt,createdAtEpoch:$createdAtEpoch}' \
    > "$meta_dir/$key.json" 2>/dev/null || return 0
}

# Run the CLI with stdout captured (for the stamp) and stderr flowing live.
_wt_out=$(mktemp 2>/dev/null || echo "/tmp/hq-worktree-out.$$")
_wt_rc=0
hq core --hq-root "$HQ_ROOT" worktree "$@" >"$_wt_out" || _wt_rc=$?
cat "$_wt_out"
if [[ "$_wt_rc" -eq 0 ]] && command -v jq >/dev/null 2>&1; then
  stamp_worktree "$_wt_out" || true
fi
rm -f "$_wt_out" 2>/dev/null || true
exit "$_wt_rc"
