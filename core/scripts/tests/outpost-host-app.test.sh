#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
source_skill="$repo_root/.claude/skills/outpost-host"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/skill" "$tmp/bin" "$tmp/etc/nginx/conf.d" "$tmp/usr/share/nginx/outpost-host" "$tmp/site"
cp "$source_skill/host-app.sh" "$tmp/skill/host-app.sh"
cat >"$tmp/skill/guard.sh" <<'SH'
#!/bin/sh
exit 0
SH
cat >"$tmp/bin/sudo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=()
for arg in "$@"; do
  case "$arg" in
    /etc/nginx/conf.d/*) arg="$OUTPOST_TEST_ROOT/etc/nginx/conf.d/${arg##*/}" ;;
    /usr/share/nginx/outpost-host/*) arg="$OUTPOST_TEST_ROOT/usr/share/nginx/outpost-host/${arg##*/}" ;;
    /usr/share/nginx/outpost-host) arg="$OUTPOST_TEST_ROOT/usr/share/nginx/outpost-host" ;;
  esac
  args+=("$arg")
done
printf '%s\n' "${args[*]}" >>"$OUTPOST_TEST_LOG"
exec "${args[@]}"
SH
cat >"$tmp/bin/nginx" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == -v ]]; then echo 'nginx test stub'; exit 0; fi
[[ "${OUTPOST_FAIL_NGINX_TEST:-0}" != 1 ]]
SH
cat >"$tmp/bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  reload) [[ "${OUTPOST_FAIL_RELOAD:-0}" != 1 ]] ;;
  restart) [[ "${OUTPOST_FAIL_RESTART:-0}" != 1 ]] ;;
  *) exit 0 ;;
esac
SH
cat >"$tmp/bin/cp" <<'SH'
#!/usr/bin/env bash
if [[ "${OUTPOST_FAIL_COPY:-0}" == 1 ]]; then exit 1; fi
exec /bin/cp "$@"
SH
cat >"$tmp/bin/curl" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:/usr/bin:/bin" OUTPOST_TEST_ROOT="$tmp" OUTPOST_TEST_LOG="$tmp/sudo.log"
export OUTPOST_FAIL_NGINX_TEST=0 OUTPOST_FAIL_RELOAD=0 OUTPOST_FAIL_RESTART=0 OUTPOST_FAIL_COPY=0
: >"$OUTPOST_TEST_LOG"

failures=0
check() { printf 'ok   %s\n' "$1"; }
bad() { printf 'not ok   %s\n' "$1" >&2; failures=$((failures + 1)); }

if output=$(bash "$tmp/skill/host-app.sh" remove --name '../../../nginx' 2>&1); then
  bad 'remove rejects a traversal slug before privileged removal'
elif [[ "$output" == *'--name must be a slug'* ]] && ! grep -q 'rm ' "$OUTPOST_TEST_LOG"; then
  check 'remove rejects a traversal slug before privileged removal'
else
  bad 'remove rejects a traversal slug before privileged removal'
fi

config="$tmp/etc/nginx/conf.d/outpost-site.conf"
printf 'previous nginx config\n' >"$config"
OUTPOST_FAIL_NGINX_TEST=1 bash "$tmp/skill/host-app.sh" deploy --name site --mode proxy --upstream 127.0.0.1:3000 >/dev/null 2>&1 && rc=0 || rc=$?
if [[ $rc -ne 0 && -f "$config" ]] && grep -q '^previous nginx config$' "$config"; then
  check 'failed nginx validation restores the previous config'
else
  bad 'failed nginx validation restores the previous config'
fi

OUTPOST_FAIL_NGINX_TEST=0 OUTPOST_FAIL_RELOAD=1 OUTPOST_FAIL_RESTART=1 \
  bash "$tmp/skill/host-app.sh" deploy --name site --mode proxy --upstream 127.0.0.1:3000 >"$tmp/service.out" 2>&1 && rc=0 || rc=$?
if [[ $rc -ne 0 ]] && ! grep -q '^DEPLOYED ' "$tmp/service.out"; then
  check 'deploy stops when nginx reload and restart fail'
else
  bad 'deploy stops when nginx reload and restart fail'
fi

# A pre-existing private parent combined with a restrictive umask must not
# leave nginx unable to traverse into the installed static site.
chmod 700 "$tmp/usr/share/nginx/outpost-host"
umask 077
OUTPOST_FAIL_COPY=0 bash "$tmp/skill/host-app.sh" deploy --name private-parent --mode static --root "$tmp/site" >"$tmp/parent.out" 2>&1 && rc=0 || rc=$?
umask 022
parent_mode=$(stat -c '%a' "$tmp/usr/share/nginx/outpost-host")
if [[ $rc -eq 0 && "$parent_mode" == 755 ]]; then
  check 'static deploy restores traversal on a restrictive webroot parent'
else
  bad 'static deploy restores traversal on a restrictive webroot parent'
fi

printf 'old static content\n' >"$tmp/usr/share/nginx/outpost-host/site.keep"
OUTPOST_FAIL_RELOAD=0 OUTPOST_FAIL_RESTART=0 OUTPOST_FAIL_COPY=1 \
  bash "$tmp/skill/host-app.sh" deploy --name site --mode static --root "$tmp/site" >"$tmp/copy.out" 2>&1 && rc=0 || rc=$?
if [[ $rc -ne 0 && -f "$tmp/usr/share/nginx/outpost-host/site.keep" ]] \
  && ! grep -q '^DEPLOYED ' "$tmp/copy.out"; then
  check 'static copy failure leaves old content and aborts deploy'
else
  bad 'static copy failure leaves old content and aborts deploy'
fi

if [[ $failures -eq 0 ]]; then echo 'outpost-host app regressions passed'; else echo "$failures outpost-host app regression(s) failed"; fi
exit "$failures"
