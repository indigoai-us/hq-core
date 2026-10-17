#!/usr/bin/env bash
# hq-core: public
# A failing sign-in restart helper must not abort company-jobs-install.sh
# before the watcher unit is enabled. set -e stays on for the other steps.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
install_sh="$script_dir/../company-jobs-install.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

awk '
  /systemctl enable --now hq-company-signin-restart.timer/ {capture=1}
  capture {print}
  /systemctl enable --now hq-company-signin.service/ {exit}
' "$install_sh" >"$tmp/snippet.sh"
grep -F 'systemctl enable --now hq-company-signin.service' "$tmp/snippet.sh" >/dev/null

cat >"$tmp/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
if [ "$1" = start ] && [ "$2" = hq-company-signin-restart.service ]; then
  echo 'helper unit failed' >&2
  exit 1
fi
exit 0
EOF
chmod 755 "$tmp/systemctl"

set +e
SYSTEMCTL_LOG="$tmp/log" PATH="$tmp:/usr/bin:/bin" /bin/bash -euo pipefail "$tmp/snippet.sh" >"$tmp/out" 2>"$tmp/err"
status=$?
set -e

if [ "$status" -ne 0 ]; then
  echo "installer aborted with status $status" >&2
  cat "$tmp/err" >&2
  exit 1
fi
grep -F 'enable --now hq-company-signin.service' "$tmp/log" >/dev/null || {
  echo 'watcher was not enabled' >&2
  cat "$tmp/log" >&2
  exit 1
}
grep -F 'enable --now hq-company-signin-restart.timer' "$tmp/log" >/dev/null || {
  echo 'retry timer was not enabled' >&2
  cat "$tmp/log" >&2
  exit 1
}
grep -F 'company-signin restart helper failed; timer will retry' "$tmp/err" >/dev/null || {
  echo 'helper failure was not logged' >&2
  cat "$tmp/err" >&2
  exit 1
}
if grep -E 'https?://|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+|sk-|xox[baprs]-' "$tmp/err" >/dev/null; then
  echo 'helper failure log matched secret-shaped text' >&2
  exit 1
fi
echo 'PASS: failing helper does not abort the installer and the watcher is still enabled'
