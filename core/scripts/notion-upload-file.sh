#!/usr/bin/env bash
# hq-core: public
# notion-upload-file.sh — upload a local file (PNG, JPEG, PDF, ...) to Notion
# and optionally attach it to a page or block, without the token ever appearing
# on a command line.
#
# Why: a hand-written `curl -H "Authorization: Bearer <token>" ...` puts the
# token in the Bash command, which the detect-secrets PreToolUse guard blocks
# (correctly: a literal token in a command lands in the transcript, shell
# history and the process list). This helper is the approved path
# (feedback_c04ab5da): the token comes from the environment, injected by
# `hq secrets exec`, and reaches curl through a mode-600 header file.
#
# Usage:
#   hq secrets exec --only NOTION_TOKEN -- \
#     bash core/scripts/notion-upload-file.sh chart.png --attach-to <page-or-block-id>
#
# Options:
#   --attach-to <id>        Append the upload to this page/block as an image block
#                           (image/* content types) or a file block (others).
#   --caption <text>        Caption for the attached block.
#   --content-type <type>   Override the content type guessed from the extension.
#   --token-env <NAME>      Env var holding the Notion token (default: NOTION_TOKEN,
#                           then NOTION_API_KEY).
#   --header-file <path>    Read the Authorization header line from this file
#                           instead of the environment.
#
# Output: one JSON object on stdout:
#   {"file_upload_id":"...","status":"uploaded","attached_block_id":"..."|null}
# The token is never printed.
#
# Test seams: NOTION_API_BASE (default https://api.notion.com),
# NOTION_API_VERSION (default 2022-06-28).

set -euo pipefail

API_BASE="${NOTION_API_BASE:-https://api.notion.com}"
API_VERSION="${NOTION_API_VERSION:-2022-06-28}"
MAX_SINGLE_PART_BYTES=$((20 * 1024 * 1024))

die() { printf 'notion-upload-file: %s\n' "$*" >&2; exit 1; }

FILE=""; ATTACH_TO=""; CAPTION=""; CONTENT_TYPE=""; TOKEN_ENV=""; HEADER_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --attach-to) ATTACH_TO="${2:-}"; shift 2 ;;
    --caption) CAPTION="${2:-}"; shift 2 ;;
    --content-type) CONTENT_TYPE="${2:-}"; shift 2 ;;
    --token-env) TOKEN_ENV="${2:-}"; shift 2 ;;
    --header-file) HEADER_FILE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$FILE" ] || die "only one file per call"; FILE="$1"; shift ;;
  esac
done

[ -n "$FILE" ] || die "usage: notion-upload-file.sh <file> [--attach-to <id>] [--caption <text>]"
[ -f "$FILE" ] || die "file not found: $FILE"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

SIZE=$(wc -c < "$FILE" | tr -d '[:space:]')
[ "$SIZE" -le "$MAX_SINGLE_PART_BYTES" ] || die "file is over 20 MB; Notion needs a multi-part upload for it"

if [ -z "$CONTENT_TYPE" ]; then
  lower=$(printf '%s' "$FILE" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *.png) CONTENT_TYPE=image/png ;;
    *.jpg|*.jpeg) CONTENT_TYPE=image/jpeg ;;
    *.gif) CONTENT_TYPE=image/gif ;;
    *.webp) CONTENT_TYPE=image/webp ;;
    *.svg) CONTENT_TYPE=image/svg+xml ;;
    *.pdf) CONTENT_TYPE=application/pdf ;;
    *.txt|*.md) CONTENT_TYPE=text/plain ;;
    *.csv) CONTENT_TYPE=text/csv ;;
    *.json) CONTENT_TYPE=application/json ;;
    *) CONTENT_TYPE=application/octet-stream ;;
  esac
fi
FILENAME="${FILE##*/}"

# Header file: mode 600 in a private temp dir, removed on exit. curl reads it
# with `-H @file`, so the token is never in curl's argv either.
umask 077
WORK=$(mktemp -d "${TMPDIR:-/tmp}/notion-upload.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
HDR="$WORK/headers"

if [ -n "$HEADER_FILE" ]; then
  [ -r "$HEADER_FILE" ] || die "header file not readable: $HEADER_FILE"
  grep -iE '^Authorization:[[:space:]]*Bearer[[:space:]]+[^[:space:]]+' "$HEADER_FILE" | head -1 > "$HDR" || true
  [ -s "$HDR" ] || die "header file has no 'Authorization: Bearer ...' line"
else
  token=""
  if [ -n "$TOKEN_ENV" ]; then
    case "$TOKEN_ENV" in *[!A-Za-z0-9_]*|'') die "invalid --token-env name" ;; esac
    token="${!TOKEN_ENV:-}"
  else
    token="${NOTION_TOKEN:-${NOTION_API_KEY:-}}"
  fi
  [ -n "$token" ] || die "no Notion token in the environment. Run through: hq secrets exec --only NOTION_TOKEN -- bash core/scripts/notion-upload-file.sh ..."
  printf 'Authorization: Bearer %s\n' "$token" > "$HDR"
  unset token
fi
printf 'Notion-Version: %s\n' "$API_VERSION" >> "$HDR"

api() {
  # api <method> <path> [curl args...] — prints the body; fails on HTTP >= 400.
  local method="$1" path="$2"; shift 2
  local out="$WORK/body" code
  code=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" -H @"$HDR" "$@" "${API_BASE}${path}") \
    || die "request failed: $method $path"
  if [ "${code:-000}" -ge 400 ] 2>/dev/null || [ "${code:-000}" = "000" ]; then
    msg=$(jq -r '.message // empty' "$out" 2>/dev/null || true)
    die "Notion API $method $path returned HTTP $code${msg:+: $msg}"
  fi
  cat "$out"
}

create_body=$(jq -nc --arg f "$FILENAME" --arg t "$CONTENT_TYPE" '{mode:"single_part",filename:$f,content_type:$t}')
created=$(api POST /v1/file_uploads -H 'Content-Type: application/json' --data "$create_body")
UPLOAD_ID=$(printf '%s' "$created" | jq -r '.id // empty')
[ -n "$UPLOAD_ID" ] || die "Notion did not return a file upload id"

sent=$(api POST "/v1/file_uploads/${UPLOAD_ID}/send" -F "file=@${FILE};type=${CONTENT_TYPE};filename=${FILENAME}")
STATUS=$(printf '%s' "$sent" | jq -r '.status // "uploaded"')

ATTACHED=""
if [ -n "$ATTACH_TO" ]; then
  case "$ATTACH_TO" in *[!A-Za-z0-9-]*) die "invalid --attach-to id" ;; esac
  case "$CONTENT_TYPE" in image/*) block_type="image" ;; application/pdf) block_type="pdf" ;; *) block_type="file" ;; esac
  children=$(jq -nc --arg bt "$block_type" --arg id "$UPLOAD_ID" --arg cap "$CAPTION" '
    {children: [ {object:"block", type:$bt,
      ($bt): ({type:"file_upload", file_upload:{id:$id}}
              + (if $cap == "" then {} else {caption:[{type:"text", text:{content:$cap}}]} end))} ]}')
  appended=$(api PATCH "/v1/blocks/${ATTACH_TO}/children" -H 'Content-Type: application/json' --data "$children")
  ATTACHED=$(printf '%s' "$appended" | jq -r '.results[0].id // empty')
fi

jq -nc --arg id "$UPLOAD_ID" --arg st "$STATUS" --arg att "$ATTACHED" \
  '{file_upload_id:$id, status:$st, attached_block_id:(if $att == "" then null else $att end)}'
