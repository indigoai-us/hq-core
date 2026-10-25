#!/usr/bin/env bash
# Persistent conductor owner-step queue. See decision-queue/SKILL.md.
set -euo pipefail
exec node "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/decision-queue.mjs" "$@"
