#!/usr/bin/env bash
# FORWARDER — the implementation of this script now lives in the hq CLI.
#
# It ships at assets/scaffold/core/scripts/rebuild-social-drafts-index.sh inside @indigoai-us/hq-cli and
# runs as the hidden command `hq core rebuild-index social-drafts`. This file stays behind so every
# existing caller — skills, other scripts, CI, and muscle memory — keeps working
# against the path it already knows.
#
# Why the implementation moved: it is a cold, explicitly-invoked operation where
# process startup is immaterial, so hosting it in the CLI costs nothing and
# keeps the scaffold to configuration rather than code.
#
# The ABI is preserved exactly: arguments are forwarded unchanged, stdin is never
# read by this file, stdout and stderr are inherited untouched, and the child
# replaces this process so its exit code and signal disposition become the
# caller's.

set -euo pipefail

# This forwarder sits in the tree it targets, so its own location IS the root.
HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

if ! command -v hq >/dev/null 2>&1; then
  echo "rebuild-social-drafts-index.sh: requires the hq CLI — this script's implementation now ships with it." >&2
  echo "Install it with: npm install -g @indigoai-us/hq-cli" >&2
  exit 127
fi

exec hq core --hq-root "$HQ_ROOT" rebuild-index social-drafts "$@"
