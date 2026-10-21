#!/usr/bin/env bash
# deploy-record-step.sh — the /deploy skill's record step: after a successful
# upload, pick the record's folder and write the record, in one call.
#
# Runs deploy-record-home.sh (which folder, and whether to copy the source),
# then deploy-record.sh (the record itself). The skill calls this once, after
# the upload and route-host.sh record, and before it presents the link.
#
# Usage (prints exactly one JSON line on stdout):
#   deploy-record-step.sh --app-json <file> --source <dir> --description <text>
#                         --type <type> [--access-mode <mode>] [--company <slug>]
#                         [--deploy-id <id>] [--route </path/>]
#                         [--deploy-type static|app] [--hq-root <dir>]
#
#   --app-json     the app object read from hq-deploy after the upload.
#   --source       the directory that went live (the build output, or the
#                  route-host snapshot in route mode).
#   --description  one paragraph written by the deploying agent. Required for
#                  every deploy; an empty one fails with description_missing.
#   --route        route mode: the record belongs to the host app, gets a
#                  route-<slug> tag (route tags already on the host's record
#                  are kept), and the host's existing description is kept
#                  with an "Also at <route>: <text>" part for each route. A
#                  redeploy of a route replaces that route's part. Past 2000
#                  characters the oldest route parts are dropped first, so the
#                  newest route's text is always kept.
#   --deploy-type  app: when the source has no index.html, the record is made
#                  from a page generated from README.md and package.json, and
#                  source_path names the real source.
#
#   -> {"ok":true,"record":<path>,"home":<path>,"resolution":...,
#       "copied":bool,"access_mode":...,"words":N}
#   -> {"ok":false,"stage":"args|prepare|home|record","reason":...,"detail":...}
#
# Exit codes: 0 written, 1 not written. A failure never touches the live
# deploy; the skill reports the link first and then one plain line saying the
# record was not written and why.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 \
    && "$candidate" -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
    PY="$(command -v "$candidate")"
    break
  fi
done

if [ -z "$PY" ]; then
  printf '%s\n' '{"ok":false,"stage":"args","reason":"missing_dependency","dep":"python3"}'
  exit 1
fi

exec "$PY" -I "$SCRIPT_DIR/deploy-record-step.py" "$@"
