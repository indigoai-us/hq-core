#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/check-hq-update.sh"
BASH_BIN="$(type -P bash)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf '  ok: %s\n' "$*"; }

mkdir -p "$TMP/bin" "$TMP/core/scripts" "$TMP/workspace"
if ! command -v timeout >/dev/null 2>&1; then
  command -v perl >/dev/null 2>&1 || fail 'neither timeout nor Perl is available for bounded hook tests'
  cat > "$TMP/bin/timeout" <<'EOF'
#!/usr/bin/env bash
seconds="${1%s}"
shift
  exec perl -e 'alarm shift; exec @ARGV or exit 127' "$seconds" "$@"
EOF
  chmod +x "$TMP/bin/timeout"
  PATH="$TMP/bin:$PATH"
  export PATH
fi
printf 'hqVersion: "15.0.131"\n' > "$TMP/core/core.yaml"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TMP/core/scripts/remove-stray-gate-hooks.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "${1:-}" = "--version" ]; then printf "hq 5.200.0\\n"; fi' \
  > "$TMP/bin/hq"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s:%s %s\\n" "${HQ_TEST_GH_MODE:-}" "${1:-}" "${2:-}" >> "${HQ_TEST_GH_CALLS:?}"' \
  'case "${HQ_TEST_GH_MODE:-}:${1:-} ${2:-}" in' \
  '  hang-auth:auth\ status|hang-release:release\ view) exec sleep 30 ;;' \
  '  trap-term:auth\ status) trap "" TERM; sleep 9 ;;' \
  '  hang-release:auth\ status|ok:auth\ status) exit 0 ;;' \
  '  ok:release\ view) printf "v15.0.200\\n" ;;' \
  '  *) exit 1 ;;' \
  'esac' > "$TMP/bin/gh"
chmod +x "$TMP/bin/hq" "$TMP/bin/gh" "$TMP/core/scripts/remove-stray-gate-hooks.sh"

mkdir -p "$TMP/non-gnu-bin"
cat > "$TMP/non-gnu-bin/timeout" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  printf 'timeout test fixture (non-GNU)\n'
  exit 0
fi
exit 127
EOF
chmod +x "$TMP/non-gnu-bin/timeout"

run_hook() {
  local mode="$1" label="$2" extra_path="${3:-}" rc=0 hook_path
  hook_path="$TMP/bin:$PATH"
  [ -z "$extra_path" ] || hook_path="$extra_path:$hook_path"
  set +e
  timeout 8s env \
    BASH_ENV= \
    CLAUDE_PROJECT_DIR="$TMP" \
    HQ_TEST_GH_MODE="$mode" \
    HQ_TEST_GH_CALLS="$TMP/$label.gh.calls" \
    PATH="$hook_path" \
    bash "$HOOK" > "$TMP/$label.out" 2> "$TMP/$label.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "$label check returned $rc instead of completing within eight seconds"
  [ ! -s "$TMP/$label.err" ] || fail "$label advisory check wrote to stderr"
}

run_hook hang-auth auth-timeout
[ ! -e "$TMP/workspace/.hq-update-check/last-check.json" ] \
  || fail 'auth timeout wrote a false release cache entry'
pass 'hung gh auth status is bounded and does not cache a release'

non_gnu_timeout_version="$("$TMP/non-gnu-bin/timeout" --version)"
[ "$non_gnu_timeout_version" = 'timeout test fixture (non-GNU)' ] \
  || fail 'Perl fallback fixture unexpectedly reports GNU timeout'
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    run_hook hang-auth perl-fallback "$TMP/non-gnu-bin"
    [ ! -s "$TMP/perl-fallback.gh.calls" ] \
      || fail 'Windows Git Bash ran gh under the unsupported Perl alarm fallback'
    pass 'Windows Git Bash skips the network check when GNU timeout is unavailable'
    ;;
  *)
    SECONDS=0
    run_hook hang-auth perl-fallback "$TMP/non-gnu-bin"
    perl_fallback_seconds="$SECONDS"
    [ "$perl_fallback_seconds" -lt 8 ] \
      || fail "non-GNU timeout did not bound the stalled gh call (${perl_fallback_seconds}s)"
    grep -Fqx 'hang-auth:auth status' "$TMP/perl-fallback.gh.calls" \
      || fail 'Perl fallback fixture did not reach the stalled gh stub'
    [ ! -e "$TMP/workspace/.hq-update-check/last-check.json" ] \
      || fail 'Perl-fallback auth timeout wrote a false release cache entry'
    pass "stalled gh auth status is bounded by Perl when timeout is non-GNU (${perl_fallback_seconds}s)"
    ;;
esac

mkdir -p "$TMP/mingw-bin"
ln -s "$TMP/non-gnu-bin/timeout" "$TMP/mingw-bin/timeout"
cat > "$TMP/mingw-bin/uname" <<'EOF'
#!/bin/sh
printf 'MINGW64_NT-10.0\n'
EOF
chmod +x "$TMP/mingw-bin/uname"
run_hook hang-auth mingw-perl-skip "$TMP/mingw-bin"
[ ! -s "$TMP/mingw-perl-skip.gh.calls" ] \
  || fail 'MINGW64 fixture ran gh under the unsupported Perl alarm fallback'
pass 'MINGW64 with Perl but without GNU timeout skips the network check'

mkdir -p "$TMP/no-bounds-bin"
for utility in bash cat grep head sed sleep; do
  utility_path="$(command -v "$utility")"
  [ -n "$utility_path" ] || fail "cannot locate $utility for the no-bounds fixture"
  ln -s "$utility_path" "$TMP/no-bounds-bin/$utility"
done
cat > "$TMP/no-bounds-bin/timeout" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  printf 'timeout test fixture (non-GNU)\n'
  exit 0
fi
exit 127
EOF
cat > "$TMP/no-bounds-bin/gh" <<'EOF'
#!/bin/sh
printf '%s %s\n' "${1:-}" "${2:-}" >> "${HQ_TEST_GH_CALLS:?}"
exec sleep 30
EOF
chmod +x "$TMP/no-bounds-bin/timeout" "$TMP/no-bounds-bin/gh"
: > "$TMP/no-bounds.gh.calls"
no_bounds_rc=0
timeout 8s env \
  BASH_ENV= \
  CLAUDE_PROJECT_DIR="$TMP" \
  HQ_TEST_GH_CALLS="$TMP/no-bounds.gh.calls" \
  PATH="$TMP/no-bounds-bin" \
  "$BASH_BIN" "$HOOK" > "$TMP/no-bounds.out" 2> "$TMP/no-bounds.err" || no_bounds_rc=$?
[ ! -s "$TMP/no-bounds.gh.calls" ] \
  || fail 'hook ran gh despite having neither GNU timeout nor Perl'
if [ "$no_bounds_rc" -ne 0 ]; then
  no_bounds_error="$(tr '\n' ' ' < "$TMP/no-bounds.err")"
  no_bounds_output="$(tr '\n' ' ' < "$TMP/no-bounds.out")"
  fail "hook did not skip the network check cleanly (exit $no_bounds_rc; stderr=$no_bounds_error; stdout=$no_bounds_output)"
fi
[ ! -e "$TMP/workspace/.hq-update-check/last-check.json" ] \
  || fail 'skipped network check wrote a release cache entry'
pass 'network check is skipped without GNU timeout or Perl; gh is not run'

run_hook hang-release release-timeout
[ ! -e "$TMP/workspace/.hq-update-check/last-check.json" ] \
  || fail 'release-view timeout wrote a false release cache entry'
grep -Fqx 'hang-release:auth status' "$TMP/release-timeout.gh.calls" \
  || fail 'release-timeout fixture did not pass the authentication check'
grep -Fqx 'hang-release:release view' "$TMP/release-timeout.gh.calls" \
  || fail 'release-timeout fixture did not invoke the bounded release lookup'
pass 'hung gh release view is bounded and does not cache a release'

run_hook trap-term term-resistant-timeout
[ ! -e "$TMP/workspace/.hq-update-check/last-check.json" ] \
  || fail 'TERM-resistant gh command wrote a false release cache entry'
grep -Fqx 'trap-term:auth status' "$TMP/term-resistant-timeout.gh.calls" \
  || fail 'TERM-resistant fixture did not invoke the bounded auth check'
pass 'TERM-resistant gh auth status is killed after its timeout grace period'

run_hook ok success
jq -e '.latest == "15.0.200"' "$TMP/workspace/.hq-update-check/last-check.json" >/dev/null \
  || fail 'successful release lookup was not cached'
grep -Fq '<hq-update-available>' "$TMP/success.out" \
  || fail 'successful release lookup did not preserve the update banner'
pass 'successful release lookup retains the existing banner and cache behavior'
