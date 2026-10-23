#!/usr/bin/env bash
# Regression: feedback_0f2e34bf-ea34-48b9-9aa0-b94877a72f74. On Git Bash the
# "@<path>" curl argument is not path-converted, so mingw curl got an MSYS
# /tmp path it cannot open. The script must pass a cygpath -w path instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
REQUEST="$ROOT/.claude/skills/deploy/scripts/deploy-api-request.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/bin"

cat > "$TMP_ROOT/bin/uname" <<'STUB'
#!/usr/bin/env bash
echo "${FAKE_UNAME:-Darwin}"
STUB
cat > "$TMP_ROOT/bin/cygpath" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -w ] || exit 2
[ "$2" = -- ] && shift
printf 'C:\\fake%s' "$(printf '%s' "$2" | tr '/' '\\')"
STUB
cat > "$TMP_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -u
out=''
for a in "$@"; do printf '%s\n' "$a" >> "$CURL_ARGS_LOG"; done
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-o' ]; then out="$2"; shift 2; else shift; fi
done
printf '{}' > "$out"
printf '200'
STUB
chmod +x "$TMP_ROOT/bin/"*

payload="$TMP_ROOT/site.tar.gz"
printf 'x' > "$payload"

run() {
  local uname_value="$1" log="$2"; shift 2
  : > "$log"
  FAKE_UNAME="$uname_value" CURL_ARGS_LOG="$log" PATH="$TMP_ROOT/bin:$PATH" HQ_DEPLOY_JWT=test-jwt \
    "$REQUEST" --stage s3-upload --method PUT --url https://upload.example.test/x "$@" >/dev/null
}

win_payload="C:\\fake$(printf '%s' "$payload" | tr '/' '\\')"

run MINGW64_NT-10.0-26200 "$TMP_ROOT/upload.log" --upload-file "$payload"
grep -qxF -- "@$win_payload" "$TMP_ROOT/upload.log" \
  || { echo "FAIL: MSYS --upload-file not converted: $(cat "$TMP_ROOT/upload.log")" >&2; exit 1; }

run MSYS_NT-10.0 "$TMP_ROOT/form.log" --form-file "file=$payload"
grep -qF -- "file=@$win_payload;type=application/gzip" "$TMP_ROOT/form.log" \
  || { echo "FAIL: MSYS --form-file not converted: $(cat "$TMP_ROOT/form.log")" >&2; exit 1; }

run Darwin "$TMP_ROOT/posix.log" --upload-file "$payload"
grep -qxF -- "@$payload" "$TMP_ROOT/posix.log" \
  || { echo "FAIL: POSIX path changed: $(cat "$TMP_ROOT/posix.log")" >&2; exit 1; }

echo 'deploy-api-request msys upload path: ok'
