#!/usr/bin/env bash
# hq-core: public
# Regression test for core/scripts/notion-upload-file.sh and its interaction
# with the detect-secrets guard (feedback_c04ab5da).
#
# Covers:
#   1. The approved command shape (hq secrets exec ... notion-upload-file.sh)
#      and env-var / header-file curl forms pass detect-secrets.
#   2. A literal bearer token on the command line is still blocked.
#   3. The helper creates the upload, sends the file, attaches an image block,
#      and never puts the token in curl's argv or its own output.
#   4. A missing token fails with a pointer to hq secrets exec.

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "notion-upload-file: skipped (jq missing)"; exit 0; }

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/detect-secrets.sh"
HELPER="$ROOT/core/scripts/notion-upload-file.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "  ok - $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL - $1" >&2; }

# Token assembled from fragments: no token-shaped literal in this file.
TOKEN="ntn_""$(printf 'a1b2c3d4e5%.0s' 1 2 3 4)"

guard_rc() {
  local rc=0
  jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' \
    | bash "$HOOK" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

echo "[1] detect-secrets: approved shapes pass, literal tokens block"
cmd='hq secrets exec --only NOTION_TOKEN -- bash core/scripts/notion-upload-file.sh chart.png --attach-to 0f1e2d3c'
[ "$(guard_rc "$cmd")" = 0 ] && ok "helper via hq secrets exec allowed" || bad "helper via hq secrets exec blocked"
cmd='curl -sS -X POST -H "Authorization: Bearer $NOTION_TOKEN" -F file=@chart.png https://api.notion.com/v1/file_uploads/x/send'
[ "$(guard_rc "$cmd")" = 0 ] && ok "curl with env-var bearer allowed" || bad "curl with env-var bearer blocked"
cmd='curl -sS -H @/tmp/notion-headers -F file=@chart.png https://api.notion.com/v1/file_uploads/x/send'
[ "$(guard_rc "$cmd")" = 0 ] && ok "curl with header file allowed" || bad "curl with header file blocked"
cmd="curl -sS -H \"Authorization: Bearer $TOKEN\" -F file=@chart.png https://api.notion.com/v1/file_uploads/x/send"
[ "$(guard_rc "$cmd")" = 2 ] && ok "curl with literal bearer token still blocked" || bad "literal bearer token not blocked"

echo "[2] helper: create, send, attach; token stays off argv"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Fake curl: logs argv, copies the header file, answers per endpoint.
printf '%s\n' "$*" >> "$FAKE_LOG"
out=""; url=""; hdr=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -H) case "$2" in @*) hdr="${2#@}" ;; esac; shift 2 ;;
    -w|-X|-F|--data) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
[ -n "$hdr" ] && cat "$hdr" >> "$FAKE_HDR_LOG"
case "$url" in
  */v1/file_uploads) body='{"id":"fu-123","status":"pending"}' ;;
  */v1/file_uploads/fu-123/send) body='{"id":"fu-123","status":"uploaded"}' ;;
  */v1/blocks/*/children) body='{"results":[{"id":"blk-9"}]}' ;;
  *) body='{"message":"unexpected"}'; printf '%s' "$body" > "$out"; printf '404'; exit 0 ;;
esac
printf '%s' "$body" > "$out"
printf '200'
FAKE
chmod +x "$TMP/bin/curl"
printf 'PNGDATA' > "$TMP/chart.png"
export FAKE_LOG="$TMP/argv.log" FAKE_HDR_LOG="$TMP/hdr.log"

rc=0
out=$(PATH="$TMP/bin:$PATH" NOTION_TOKEN="$TOKEN" NOTION_API_BASE="https://notion.test" \
  bash "$HELPER" "$TMP/chart.png" --attach-to 0f1e2d3c --caption "Weekly chart" 2>"$TMP/err") || rc=$?
[ "$rc" = 0 ] && ok "helper exits 0" || bad "helper exit $rc: $(cat "$TMP/err")"
[ "$(jq -r '.file_upload_id' <<<"$out")" = "fu-123" ] && ok "prints file upload id" || bad "bad output: $out"
[ "$(jq -r '.attached_block_id' <<<"$out")" = "blk-9" ] && ok "prints attached block id" || bad "bad attach output: $out"
[ "$(wc -l < "$FAKE_LOG" | tr -d ' ')" = 3 ] && ok "three API calls (create, send, attach)" || bad "call count: $(cat "$FAKE_LOG")"
grep -q 'type=image/png' "$FAKE_LOG" && ok "sends with image/png content type" || bad "content type missing"
grep -q '"type":"image"' "$FAKE_LOG" && ok "attaches an image block" || bad "no image block in attach call"
grep -q 'Weekly chart' "$FAKE_LOG" && ok "caption passed" || bad "caption missing"
if grep -qF "$TOKEN" "$FAKE_LOG"; then bad "token appeared in curl argv"; else ok "token absent from curl argv"; fi
if grep -qF "$TOKEN" <<<"$out$(cat "$TMP/err")"; then bad "token printed"; else ok "token absent from helper output"; fi
grep -qF "Authorization: Bearer $TOKEN" "$FAKE_HDR_LOG" && ok "token delivered via header file" || bad "header file lacked token"
grep -q 'Notion-Version: ' "$FAKE_HDR_LOG" && ok "Notion-Version header sent" || bad "Notion-Version header missing"

echo "[3] helper: header-file input, missing token"
: > "$FAKE_LOG"; : > "$FAKE_HDR_LOG"
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$TMP/hdr-in"
rc=0
out=$(PATH="$TMP/bin:$PATH" NOTION_API_BASE="https://notion.test" \
  bash "$HELPER" "$TMP/chart.png" --header-file "$TMP/hdr-in" 2>"$TMP/err") || rc=$?
[ "$rc" = 0 ] && [ "$(jq -r '.attached_block_id' <<<"$out")" = "null" ] && ok "header-file upload without attach" || bad "header-file run rc=$rc out=$out"
if grep -qF "$TOKEN" "$FAKE_LOG"; then bad "token in argv (header-file mode)"; else ok "token absent from argv (header-file mode)"; fi

rc=0
env -u NOTION_TOKEN -u NOTION_API_KEY PATH="$TMP/bin:$PATH" bash "$HELPER" "$TMP/chart.png" >/dev/null 2>"$TMP/err" || rc=$?
[ "$rc" != 0 ] && grep -q 'hq secrets exec' "$TMP/err" && ok "missing token fails with hq secrets exec hint" || bad "missing token rc=$rc err=$(cat "$TMP/err")"

echo "notion-upload-file: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
