#!/usr/bin/env bash
# qmd-reindex-bg.sh converts --log and the HQ root with `cygpath -m` only on a
# Windows Bash (Git Bash, MSYS2, Cygwin), never merely because a `cygpath` is
# on PATH.
#
# Regression: handoff-finalize-smoke.sh put a fake cygpath (`printf 'C:%s'`) on
# PATH on macOS. The forwarder applied it and handed the real CLI
# `--log C:/tmp/qmd-handoff.log`, a RELATIVE path on POSIX. The detached worker
# inherited the test's temp cwd, the test deleted it, and Node's recursive
# mkdir of that relative path never returned: nine workers spun at ~96% CPU
# for 3-4 days.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FORWARDER="$ROOT/core/scripts/qmd-reindex-bg.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hq-qmd-bg-gate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { PASS=$((PASS + 1)); printf 'ok - %s\n' "$1"; }

mkdir -p "$TMP/bin" "$TMP/hq-root"
# The hq stub records argv and never launches anything.
cat > "$TMP/bin/hq" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$QMD_GATE_RECORD"
echo 4242
SH
cat > "$TMP/bin/cygpath" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "-m" ] || exit 64
printf 'C:%s\n' "$2"
SH
chmod +x "$TMP/bin/hq" "$TMP/bin/cygpath"

host_is_windows_bash=0
case "${OSTYPE:-}" in msys* | cygwin*) host_is_windows_bash=1 ;; esac

# run <uname -s value> <args...>: prints the argv the forwarder handed to hq.
run() {
  local uname_value="$1"
  shift
  cat > "$TMP/bin/uname" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "-s" ]; then printf '%s\n' '$uname_value'; else exec /usr/bin/uname "\$@"; fi
SH
  chmod +x "$TMP/bin/uname"
  rm -f "$TMP/record"
  QMD_GATE_RECORD="$TMP/record" HQ_ROOT="$TMP/hq-root" PATH="$TMP/bin:$PATH" \
    bash "$FORWARDER" "$@" > "$TMP/stdout" 2> "$TMP/stderr" \
    || { cat "$TMP/stderr" >&2; fail "forwarder exited non-zero under uname $uname_value"; }
  [ "$(cat "$TMP/stdout")" = "4242" ] || fail "forwarder did not pass through hq stdout"
  cat "$TMP/record"
}

for posix in Darwin Linux; do
  argv="$(run "$posix" --log /tmp/qmd-handoff.log)"
  if [ "$host_is_windows_bash" -eq 1 ]; then
    # OSTYPE identifies a real Windows Bash even if uname is stubbed.
    [ "$argv" = "index background --hq-root C:$TMP/hq-root --log C:/tmp/qmd-handoff.log" ] \
      || fail "Windows Bash host must still convert: $argv"
    pass "$posix uname stub on a Windows Bash host still converts"
    continue
  fi
  [ "$argv" = "index background --hq-root $TMP/hq-root --log /tmp/qmd-handoff.log" ] \
    || fail "$posix with cygpath on PATH must not convert paths: $argv"
  pass "$posix: fake cygpath on PATH leaves --log and --hq-root untouched"

  argv="$(run "$posix" --log=/tmp/qmd-handoff.log)"
  [ "$argv" = "index background --hq-root $TMP/hq-root --log=/tmp/qmd-handoff.log" ] \
    || fail "$posix --log= form must not convert: $argv"
  pass "$posix: --log= form untouched"
done

for windows in MINGW64_NT-10.0-19045 MSYS_NT-10.0 CYGWIN_NT-10.0; do
  argv="$(run "$windows" --log /tmp/qmd-handoff.log)"
  [ "$argv" = "index background --hq-root C:$TMP/hq-root --log C:/tmp/qmd-handoff.log" ] \
    || fail "$windows must convert --log and the root: $argv"
  pass "$windows: --log and --hq-root converted with cygpath -m"

  argv="$(run "$windows" --log=/tmp/qmd-handoff.log)"
  [ "$argv" = "index background --hq-root C:$TMP/hq-root --log=C:/tmp/qmd-handoff.log" ] \
    || fail "$windows must convert the --log= form: $argv"
  pass "$windows: --log= form converted"
done

# A Windows Bash without cygpath forwards unchanged instead of failing.
rm -f "$TMP/bin/cygpath"
if [ "$host_is_windows_bash" -eq 0 ]; then
  argv="$(run MINGW64_NT-10.0 --log /tmp/qmd-handoff.log)"
  [ "$argv" = "index background --hq-root $TMP/hq-root --log /tmp/qmd-handoff.log" ] \
    || fail "Windows uname without cygpath must forward unchanged: $argv"
  pass "Windows uname without cygpath forwards unchanged"
fi

printf 'qmd-reindex-bg cygpath gate: %d passed\n' "$PASS"
