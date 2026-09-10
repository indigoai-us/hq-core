#!/usr/bin/env bash
# hq-task.sh — add, list, and close tasks on a standing task-bucket project.
#
# A task bucket is an ordinary HQ project whose prd.json carries
# metadata.kind == "task_board". Its user stories are errands rather than
# software features, so they carry no branch, repo path, or test harness.
#
# Usage:
#   hq-task.sh list   [--company <slug>] [--project <name>] [--all]
#   hq-task.sh add    [--company <slug>] [--project <name>] \
#                     --title "<short title>" [--description "<context>"] \
#                     [--criteria "<one done-criterion>"]... \
#                     [--priority <n>] [--contact "Name <email>|role"]...
#   hq-task.sh done   [--company <slug>] [--project <name>] --id US-002
#   hq-task.sh reopen [--company <slug>] [--project <name>] --id US-002
#
# Defaults: --company personal --project life-admin.
#
# See core/knowledge/public/hq-core/goals-and-tasks-board.md for the concept.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
export HQ_ROOT

if ! command -v node >/dev/null 2>&1; then
  echo "hq-task: node is required but was not found on PATH." >&2
  exit 1
fi

exec node "$SCRIPT_DIR/hq-task.mjs" "$@"
