#!/usr/bin/env bash
# list-apps.sh — read EVERY page of GET /api/apps.
#
# GET /api/apps is paginated: each response is {apps:[...], nextCursor} and a
# page holds at most 100 apps (fewer when no limit is sent). An org with more
# apps than one page — Indigo has 1,300+ — puts most of its apps on later
# pages, in UUID order, so a brand-new app lands on a random page. Reading only
# the first page made `select(.name == $n)` miss apps that exist. In
# project-summary that left two internal pages PUBLIC on 2026-10-18: the
# tarball went live, the post-upload APP_ID lookup missed, and the script
# exited before applying the access gate.
#
# Usage:
#   list-apps.sh --api <base> [--name <app-name>] [deploy-api-request args...]
#
#   --api <base>     hq-deploy API base, e.g. https://api.indigo-hq.com
#   --name <name>    stop at the first app whose .name matches and print that
#                    app object; print nothing (exit 0) when no page has it
#   anything else    passed through to deploy-api-request.sh on every page
#                    (--org, --scope, --header "X-Org-Slug: ..." and so on)
#
# Without --name, prints {"apps":[...every page...]} so existing callers that
# read `.apps[]` keep working.
#
# Needs HQ_DEPLOY_JWT in the environment (same as deploy-api-request.sh).
# Fails closed: any non-2xx page, malformed page, repeated cursor, or more than
# HQ_DEPLOY_APP_LIST_MAX_PAGES pages exits non-zero. A failed list must never
# read as "app not found", because callers create a new app on "not found".
set -o pipefail

_src="${BASH_SOURCE[0]}"
_dir="${_src%/*}"
[ "$_dir" = "$_src" ] && _dir="."
SCRIPT_DIR="$(cd "$_dir" && pwd)"
REQUEST="${HQ_DEPLOY_REQUEST_SCRIPT:-$SCRIPT_DIR/deploy-api-request.sh}"

usage() {
  echo "usage: $0 --api <base> [--name <app-name>] [deploy-api-request args...]" >&2
  exit 64
}

API=""
NAME=""
HAVE_NAME=0
PASS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --api) API="${2:-}"; shift 2 ;;
    --name) NAME="${2:-}"; HAVE_NAME=1; shift 2 ;;
    --stage|--method|--url|--expect|--data|--upload-file) usage ;;
    *) PASS+=("$1"); shift ;;
  esac
done
[ -n "$API" ] || usage
[ "$HAVE_NAME" -eq 0 ] || [ -n "$NAME" ] || usage

MAX_PAGES="${HQ_DEPLOY_APP_LIST_MAX_PAGES:-500}"
[[ "$MAX_PAGES" =~ ^[0-9]+$ ]] && [ "$MAX_PAGES" -ge 1 ] || MAX_PAGES=500

EXPECT='(.apps | type == "array") and ((.nextCursor == null) or (.nextCursor | type == "string" and length > 0))'
ALL="$(mktemp -t hq-deploy-apps.XXXXXX)"
trap 'rm -f "$ALL"' EXIT
: > "$ALL"

CURSOR=""
SEEN=" "
PAGE=0
while :; do
  PAGE=$((PAGE + 1))
  if [ "$PAGE" -gt "$MAX_PAGES" ]; then
    echo "[deploy] stage=app-list more than $MAX_PAGES pages of apps; refusing to guess" >&2
    exit 1
  fi
  URL="${API%/}/api/apps?limit=100"
  [ -z "$CURSOR" ] || URL="$URL&cursor=$CURSOR"
  BODY="$("$REQUEST" --stage app-list --method GET --url "$URL" --expect "$EXPECT" \
    ${PASS[@]+"${PASS[@]}"})" || exit 1

  if [ "$HAVE_NAME" -eq 1 ]; then
    MATCH="$(printf '%s' "$BODY" | jq -c --arg n "$NAME" '[.apps[] | select(.name == $n)][0] // empty')" || exit 1
    if [ -n "$MATCH" ]; then
      printf '%s\n' "$MATCH"
      exit 0
    fi
  else
    printf '%s' "$BODY" | jq -c '.apps[]' >> "$ALL" || exit 1
  fi

  NEXT="$(printf '%s' "$BODY" | jq -r '.nextCursor // empty')" || exit 1
  [ -n "$NEXT" ] || break
  # The API emits base64url cursors; anything else would need URL encoding
  # and points at a contract change, so stop instead of sending it.
  if ! [[ "$NEXT" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "[deploy] stage=app-list unexpected cursor format; refusing to continue" >&2
    exit 1
  fi
  case "$SEEN" in
    *" $NEXT "*)
      echo "[deploy] stage=app-list cursor repeated; refusing to loop" >&2
      exit 1 ;;
  esac
  SEEN="$SEEN$NEXT "
  CURSOR="$NEXT"
done

[ "$HAVE_NAME" -eq 1 ] && exit 0
jq -s -c '{apps: .}' "$ALL"
