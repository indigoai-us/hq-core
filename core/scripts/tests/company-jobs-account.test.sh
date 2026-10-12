#!/bin/bash
# hq-core: public
# The installer refuses an existing hq-jobs account with the wrong shell or groups.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
install_sh="$script_dir/../company-jobs-install.sh"
fn=$(sed -n '/^ensure_system_account()/,/^}/p' "$install_sh")
[ -n "$fn" ] || { echo 'ensure_system_account not found' >&2; exit 1; }
grep -F 'loginctl disable-linger hq-jobs' "$install_sh" >/dev/null
if grep -F 'enable-linger' "$install_sh" >/dev/null; then
  echo 'job account lingering must stay disabled' >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/getent" <<'EOF'
#!/bin/bash
if [ "$1" = passwd ] && [ "$2" = hq-jobs ]; then
  case "$ACCOUNT_MODE" in
    missing) exit 2 ;;
    bad-shell) printf '%s\n' 'hq-jobs:x:499:499::/var/lib/hq-company-jobs:/bin/bash'; exit 0 ;;
    bad-group) printf '%s\n' 'hq-jobs:x:499:20::/var/lib/hq-company-jobs:/usr/sbin/nologin'; exit 0 ;;
    extra-group) printf '%s\n' 'hq-jobs:x:499:499::/var/lib/hq-company-jobs:/usr/sbin/nologin'; exit 0 ;;
    root-uid) printf '%s\n' 'hq-jobs:x:0:0::/var/lib/hq-company-jobs:/usr/sbin/nologin'; exit 0 ;;
    ok) printf '%s\n' 'hq-jobs:x:499:499::/var/lib/hq-company-jobs:/usr/sbin/nologin'; exit 0 ;;
  esac
fi
exit 2
EOF
cat >"$tmp/id" <<'EOF'
#!/bin/bash
case "$1" in
  -gn)
    if [ "$ACCOUNT_MODE" = bad-group ]; then echo staff; else echo hq-jobs; fi
    ;;
  -nG)
    if [ "$ACCOUNT_MODE" = extra-group ]; then echo "hq-jobs wheel"; else echo hq-jobs; fi
    ;;
  -u)
    if [ "$ACCOUNT_MODE" = root-uid ]; then echo 0; else echo 499; fi
    ;;
  *) exit 1 ;;
esac
EOF
cat >"$tmp/useradd" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"$USERADD_LOG"
EOF
chmod 755 "$tmp/getent" "$tmp/id" "$tmp/useradd"
{
  printf '%s\n' "$fn"
  printf '%s\n' 'ensure_system_account hq-jobs /var/lib/hq-company-jobs'
} >"$tmp/case.sh"

run_case() {
  mode=$1
  err="$tmp/err-$mode"
  log="$tmp/useradd-$mode"
  : >"$log"
  set +e
  ACCOUNT_MODE="$mode" USERADD_LOG="$log" PATH="$tmp:/usr/bin:/bin" /bin/bash "$tmp/case.sh" >"$tmp/out-$mode" 2>"$err"
  status=$?
  set -e
}

expect_refuse() {
  mode=$1
  needle=$2
  run_case "$mode"
  [ "$status" -eq 2 ] || { echo "$mode exited $status" >&2; cat "$err" >&2; exit 1; }
  grep -F "$needle" "$err" >/dev/null || { echo "$mode did not report $needle" >&2; cat "$err" >&2; exit 1; }
  [ ! -s "$log" ] || { echo "$mode called useradd" >&2; exit 1; }
}

expect_refuse bad-shell 'hq-jobs shell is not nologin'
expect_refuse bad-group 'hq-jobs primary group is not hq-jobs'
expect_refuse extra-group 'hq-jobs has unexpected groups'
run_case root-uid
[ "$status" -eq 2 ] || { echo "root-uid exited $status" >&2; exit 1; }
[ ! -s "$log" ] || { echo 'root-uid called useradd' >&2; exit 1; }

run_case ok
[ "$status" -eq 0 ] || { echo "ok exited $status" >&2; cat "$err" >&2; exit 1; }
[ ! -s "$log" ] || { echo 'existing locked account called useradd' >&2; exit 1; }

run_case missing
[ "$status" -eq 0 ] || { echo "missing exited $status" >&2; cat "$err" >&2; exit 1; }
grep -F -- '--shell /usr/sbin/nologin hq-jobs' "$log" >/dev/null || { echo 'missing account was not created nologin' >&2; cat "$log" >&2; exit 1; }
echo 'PASS: existing hq-jobs shell and groups are refused; a missing account is created nologin'
