#!/usr/bin/env bash
# Tests for core/scripts/lib/hq-core-source.sh and its use in the update path
# (.claude/hooks/check-hq-update.sh and the /update-hq metadata read).
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
LIB="$ROOT/core/scripts/lib/hq-core-source.sh"
HOOK="$ROOT/.claude/hooks/check-hq-update.sh"
BASH_BIN="$(type -P bash)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf '  ok: %s\n' "$*"; }

DEFAULTS='repo=indigoai-us/hq-core
stagingRepo=indigoai-us/hq-core-staging
apiBase=https://api.github.com
codeloadBase=https://codeload.github.com
webBase=https://github.com'

mkdir -p "$TMP/home" "$TMP/bin"

# Run the resolver CLI with a clean environment. Extra env assignments come
# first as NAME=value arguments; the rest are CLI arguments after "--".
resolve() {
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -eq 0 ] || shift
  env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" ${envs[@]+"${envs[@]}"} \
    "$BASH_BIN" "$LIB" "$@"
}

engines="jq node"
command -v jq >/dev/null 2>&1 || engines="${engines/jq/}"
command -v node >/dev/null 2>&1 || engines="${engines/node/}"
[ -n "${engines// /}" ] || fail 'neither jq nor node is available to exercise the parser'

for engine in $engines; do
  E="HQ_CORE_SOURCE_ENGINE=$engine"

  # 1. Defaults.
  out="$(resolve "$E" -- print 2>"$TMP/err")"
  [ "$out" = "$DEFAULTS" ] || fail "[$engine] defaults: got $out"
  [ ! -s "$TMP/err" ] || fail "[$engine] defaults wrote to stderr"
  pass "[$engine] no override resolves to the GitHub defaults"

  # 2. Full env override; trailing slashes stripped.
  full='{"repo":"acme/hq-core","stagingRepo":"acme/hq-core-next","apiBase":"https://git.example.test/api/v3/","codeloadBase":"https://git.example.test/codeload//","webBase":"https://git.example.test/"}'
  out="$(resolve "$E" "HQ_CORE_SOURCE=$full" -- print 2>"$TMP/err")"
  expected='repo=acme/hq-core
stagingRepo=acme/hq-core-next
apiBase=https://git.example.test/api/v3
codeloadBase=https://git.example.test/codeload
webBase=https://git.example.test'
  [ "$out" = "$expected" ] || fail "[$engine] full override: got $out"
  [ ! -s "$TMP/err" ] || fail "[$engine] valid override wrote a warning"
  pass "[$engine] env override changes every field and strips trailing slashes"

  # 3. Partial override keeps the other defaults.
  out="$(resolve "$E" 'HQ_CORE_SOURCE={"repo":"acme/hq-core"}' -- print 2>"$TMP/err")"
  [ "$out" = "${DEFAULTS/repo=indigoai-us\/hq-core$'\n'/repo=acme/hq-core$'\n'}" ] \
    || fail "[$engine] partial override: got $out"
  [ ! -s "$TMP/err" ] || fail "[$engine] partial override wrote a warning"
  pass "[$engine] partial override keeps the other defaults"

  # 4. Invalid JSON falls back with one warning naming HQ_CORE_SOURCE.
  for bad in '{"repo":' 'not json' '["acme/hq-core"]' '"acme/hq-core"'; do
    out="$(resolve "$E" "HQ_CORE_SOURCE=$bad" -- print 2>"$TMP/err")"
    [ "$out" = "$DEFAULTS" ] || fail "[$engine] invalid JSON '$bad' did not fall back: $out"
    [ "$(wc -l < "$TMP/err" | tr -d ' ')" = 1 ] || fail "[$engine] invalid JSON '$bad' did not print exactly one warning"
    grep -q 'HQ_CORE_SOURCE' "$TMP/err" || fail "[$engine] warning does not name HQ_CORE_SOURCE"
  done
  pass "[$engine] invalid JSON falls back to the defaults with one warning"

  # 5. Invalid fields fall back one by one; valid fields stay.
  mixed='{"repo":"not-a-repo","stagingRepo":"acme/next","apiBase":"ftp://git.example.test","codeloadBase":"http://git.example.test","webBase":123}'
  out="$(resolve "$E" "HQ_CORE_SOURCE=$mixed" -- print 2>"$TMP/err")"
  expected='repo=indigoai-us/hq-core
stagingRepo=acme/next
apiBase=https://api.github.com
codeloadBase=https://codeload.github.com
webBase=https://github.com'
  [ "$out" = "$expected" ] || fail "[$engine] invalid fields: got $out"
  [ "$(wc -l < "$TMP/err" | tr -d ' ')" = 1 ] || fail "[$engine] invalid fields did not print exactly one warning"
  for field in repo apiBase codeloadBase webBase; do
    grep -q " $field" "$TMP/err" || fail "[$engine] warning does not name $field"
  done
  grep -q 'stagingRepo' "$TMP/err" && fail "[$engine] warning names the valid stagingRepo field"
  pass "[$engine] invalid fields use their defaults; valid fields are kept"

  # 6. http:// only for localhost / 127.0.0.1.
  out="$(resolve "$E" 'HQ_CORE_SOURCE={"apiBase":"http://localhost:8080/api","webBase":"http://127.0.0.1:9000"}' -- print 2>"$TMP/err")"
  case $'\n'"$out"$'\n' in
    *$'\napiBase=http://localhost:8080/api\n'*) ;;
    *) fail "[$engine] http localhost rejected" ;;
  esac
  case $'\n'"$out"$'\n' in
    *$'\nwebBase=http://127.0.0.1:9000\n'*) ;;
    *) fail "[$engine] http 127.0.0.1 rejected" ;;
  esac
  [ ! -s "$TMP/err" ] || fail "[$engine] http localhost wrote a warning"
  pass "[$engine] http:// is accepted for localhost and 127.0.0.1"

  # 7. File fallback; env wins over the file; empty file is no override.
  printf '%s\n' '{"repo":"acme/from-file","webBase":"https://git.example.test"}' > "$TMP/home/core-source.json"
  mkdir -p "$TMP/home/.hq"
  cp "$TMP/home/core-source.json" "$TMP/home/.hq/core-source.json"
  out="$(resolve "$E" -- get repo 2>"$TMP/err")"
  [ "$out" = "acme/from-file" ] || fail "[$engine] ~/.hq/core-source.json not read: $out"
  out="$(resolve "$E" -- get webBase 2>/dev/null)"
  [ "$out" = "https://git.example.test" ] || fail "[$engine] file webBase not read: $out"
  out="$(resolve "$E" 'HQ_CORE_SOURCE={"repo":"acme/from-env"}' -- get repo 2>/dev/null)"
  [ "$out" = "acme/from-env" ] || fail "[$engine] env did not take precedence over the file: $out"
  printf 'not json' > "$TMP/home/.hq/core-source.json"
  out="$(resolve "$E" -- get repo 2>"$TMP/err")"
  [ "$out" = "indigoai-us/hq-core" ] || fail "[$engine] invalid file did not fall back: $out"
  grep -q 'HQ_CORE_SOURCE' "$TMP/err" || fail "[$engine] invalid file warning does not name HQ_CORE_SOURCE"
  : > "$TMP/home/.hq/core-source.json"
  out="$(resolve "$E" -- get repo 2>"$TMP/err")"
  [ "$out" = "indigoai-us/hq-core" ] && [ ! -s "$TMP/err" ] || fail "[$engine] empty file is not a silent no-op"
  rm -rf "$TMP/home/.hq" "$TMP/home/core-source.json"
  pass "[$engine] ~/.hq/core-source.json is read when the env var is unset; env wins"
done

# 7b. Both parsers reject trailing documents and blank input the same way.
for engine in $engines; do
  for bad in '{} {"repo":"acme/hq-core"}' '   ' '{"repo":"acme/hq-core"} []'; do
    out="$(resolve "HQ_CORE_SOURCE_ENGINE=$engine" "HQ_CORE_SOURCE=$bad" -- get repo 2>"$TMP/err")"
    [ "$out" = "indigoai-us/hq-core" ] || fail "[$engine] '$bad' did not fall back: $out"
    grep -q 'HQ_CORE_SOURCE' "$TMP/err" || fail "[$engine] '$bad' fell back without a warning"
  done
done
pass 'jq and node both reject trailing JSON documents and blank input with a warning'

# 7c. Sourcing the lib and loading a partial override is safe under set -e.
for engine in $engines; do
  out="$(env -i PATH="$PATH" HOME="$TMP/home" HQ_CORE_SOURCE_ENGINE="$engine" \
    HQ_CORE_SOURCE='{"repo":"acme/hq-core"}' "$BASH_BIN" -c \
    'set -euo pipefail; . "$1"; hq_core_source_load; printf "%s %s\n" "$HQ_CORE_SOURCE_REPO" "$HQ_CORE_SOURCE_WEB_BASE"' _ "$LIB")" \
    || fail "[$engine] partial override aborted a set -e caller"
  [ "$out" = "acme/hq-core https://github.com" ] || fail "[$engine] set -e partial load: $out"
done
pass 'hq_core_source_load returns 0 for a partial override under set -euo pipefail'

# 8. No parser: an override is ignored with a warning.
out="$(resolve HQ_CORE_SOURCE_ENGINE=none 'HQ_CORE_SOURCE={"repo":"acme/hq-core"}' -- print 2>"$TMP/err")"
[ "$out" = "$DEFAULTS" ] || fail "no-parser case did not fall back: $out"
grep -q 'HQ_CORE_SOURCE' "$TMP/err" || fail 'no-parser warning does not name HQ_CORE_SOURCE'
pass 'without jq or node an override is ignored with a warning'

# Stubs for gh and curl that record how they were called.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HQ_TEST_CALLS:?}.gh"
case "$1 ${2:-}" in
  "auth status") exit 0 ;;
  "release view") printf 'v99.0.0\n' ;;
  "api "*) printf 'hqVersion: "99.0.0"\n' ;;
esac
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
{
  printf 'args:'; printf ' [%s]' "$@"; printf '\n'
  printf 'GH_TOKEN=%s GITHUB_TOKEN=%s\n' "${GH_TOKEN-unset}" "${GITHUB_TOKEN-unset}"
} >> "${HQ_TEST_CALLS:?}.curl"
for a in "$@"; do
  case "$a" in
    https://down.example.test/*) exit 22 ;;
    https://badtag.example.test/*/releases/latest) printf '{"tag_name": "99 injected banner text"}\n'; exit 0 ;;
    */releases/latest) printf '{"tag_name": "v99.0.0", "name": "x"}\n'; exit 0 ;;
    */contents/core/core.yaml*) printf 'hqVersion: "99.0.0"\n'; exit 0 ;;
  esac
done
exit 22
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/curl"

OVERRIDE='{"repo":"acme/hq-core","stagingRepo":"acme/hq-core-next","apiBase":"https://git.example.test/api/v3","codeloadBase":"https://git.example.test/codeload","webBase":"https://git.example.test"}'
FAKE_TOKEN="test-token-not-real"

# 9. /update-hq metadata read: default goes to gh; staging selects stagingRepo.
calls="$TMP/meta-default"
out="$(resolve "HQ_TEST_CALLS=$calls" -- core-yaml --ref v1.2.3)"
[ "$out" = 'hqVersion: "99.0.0"' ] || fail "core-yaml default output: $out"
grep -Fqx 'api -H Accept: application/vnd.github.raw+json repos/indigoai-us/hq-core/contents/core/core.yaml?ref=v1.2.3' "$calls.gh" \
  || fail "core-yaml default did not call gh api on the default repo: $(cat "$calls.gh")"
[ ! -e "$calls.curl" ] || fail 'core-yaml default used curl'
resolve "HQ_TEST_CALLS=$calls" -- core-yaml --ref main --staging >/dev/null
grep -Fq 'repos/indigoai-us/hq-core-staging/contents/core/core.yaml?ref=main' "$calls.gh" \
  || fail 'core-yaml --staging did not use the staging repo'
resolve "HQ_TEST_CALLS=$calls" -- core-yaml --ref main --source acme/fork >/dev/null
grep -Fq 'repos/acme/fork/contents/core/core.yaml?ref=main' "$calls.gh" \
  || fail 'core-yaml --source did not use the given repo'
if resolve "HQ_TEST_CALLS=$calls" -- core-yaml --ref 'v1;rm' >/dev/null 2>&1; then fail 'core-yaml accepted an unsafe ref'; fi
pass '/update-hq metadata read uses gh on GitHub with the default, staging and --source repos'

# 10. Non-GitHub host: no gh, no credentials, tokens removed from curl's env.
calls="$TMP/meta-override"
out="$(resolve "HQ_TEST_CALLS=$calls" "HQ_CORE_SOURCE=$OVERRIDE" "GH_TOKEN=$FAKE_TOKEN" "GITHUB_TOKEN=$FAKE_TOKEN" -- core-yaml --ref v1.2.3 --staging)"
[ "$out" = 'hqVersion: "99.0.0"' ] || fail "core-yaml override output: $out"
[ ! -e "$calls.gh" ] || fail 'core-yaml called gh for a non-GitHub host'
grep -Fq '[https://git.example.test/api/v3/repos/acme/hq-core-next/contents/core/core.yaml?ref=v1.2.3]' "$calls.curl" \
  || fail "core-yaml override hit the wrong URL: $(cat "$calls.curl")"
grep -Fqx 'GH_TOKEN=unset GITHUB_TOKEN=unset' "$calls.curl" || fail 'GitHub token variables reached curl for a non-GitHub host'
grep -Fq "$FAKE_TOKEN" "$calls.curl" && fail 'GitHub token appeared in the curl call for a non-GitHub host'
grep -Fiq 'authorization' "$calls.curl" && fail 'curl got an Authorization header for a non-GitHub host'
pass 'non-GitHub source gets no gh call, no Authorization header and no GitHub token'

# 11. Host classification.
# shellcheck source=../lib/hq-core-source.sh
. "$LIB"
for u in https://github.com https://API.GitHub.com/x https://codeload.github.com:443/a; do
  hq_core_source_is_github_host "$u" || fail "$u not classified as GitHub"
done
for u in https://git.example.test https://github.com.example.test https://notgithub.com https://api.github.com.example.test/x; do
  if hq_core_source_is_github_host "$u"; then fail "$u classified as GitHub"; fi
done
shopt -q nocasematch && fail 'host check left nocasematch on'
pass 'only github.com, api.github.com and codeload.github.com count as GitHub hosts'

# 12. Update check hook.
mkdir -p "$TMP/hq/core/scripts" "$TMP/hq/workspace"
printf 'hqVersion: "1.0.0"\n' > "$TMP/hq/core/core.yaml"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TMP/hq/core/scripts/remove-stray-gate-hooks.sh"
printf '%s\n' '#!/usr/bin/env bash' 'if [ "${1:-}" = "--version" ]; then printf "hq 5.200.0\n"; fi' > "$TMP/bin/hq"
chmod +x "$TMP/bin/hq" "$TMP/hq/core/scripts/remove-stray-gate-hooks.sh"

run_hook() {
  local label="$1"; shift
  rm -rf "$TMP/hq/workspace/.hq-update-check"
  env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" BASH_ENV= \
    CLAUDE_PROJECT_DIR="$TMP/hq" HQ_ROOT="$TMP/hq" \
    HQ_UPDATE_CHECK_STATE_DIR="$TMP/$label.state" \
    HQ_TEST_CALLS="$TMP/$label" "$@" \
    "$BASH_BIN" "$HOOK" > "$TMP/$label.out" 2> "$TMP/$label.err" < /dev/null
}

run_hook hook-default
grep -Fqx 'release view -R indigoai-us/hq-core --json tagName -q .tagName' "$TMP/hook-default.gh" \
  || fail "hook default did not query indigoai-us/hq-core via gh: $(cat "$TMP/hook-default.gh" 2>/dev/null)"
[ ! -e "$TMP/hook-default.curl" ] || fail 'hook default used curl'
grep -q 'latest:  v99.0.0' "$TMP/hook-default.out" || fail 'hook default did not report the newer release'
pass 'update check uses gh release view on indigoai-us/hq-core by default'

run_hook hook-repo "HQ_CORE_SOURCE={\"repo\":\"acme/hq-core\"}"
grep -Fqx 'release view -R acme/hq-core --json tagName -q .tagName' "$TMP/hook-repo.gh" \
  || fail 'hook did not use the overridden repo on GitHub'
pass 'update check follows a repo override on GitHub'

run_hook hook-override "HQ_CORE_SOURCE=$OVERRIDE" "GH_TOKEN=$FAKE_TOKEN" "GITHUB_TOKEN=$FAKE_TOKEN"
[ ! -e "$TMP/hook-override.gh" ] || fail "hook called gh for a non-GitHub source: $(cat "$TMP/hook-override.gh")"
grep -Fq '[https://git.example.test/api/v3/repos/acme/hq-core/releases/latest]' "$TMP/hook-override.curl" \
  || fail "hook queried the wrong URL: $(cat "$TMP/hook-override.curl" 2>/dev/null)"
grep -Fqx 'GH_TOKEN=unset GITHUB_TOKEN=unset' "$TMP/hook-override.curl" || fail 'hook passed GitHub tokens to a non-GitHub host'
grep -Fiq 'authorization' "$TMP/hook-override.curl" && fail 'hook sent an Authorization header to a non-GitHub host'
grep -q 'latest:  v99.0.0' "$TMP/hook-override.out" || fail 'hook did not report the release from the overridden source'
pass 'update check queries the overridden host with curl and no GitHub credentials'

run_hook hook-invalid-json "HQ_CORE_SOURCE=not json"
grep -Fqx 'release view -R indigoai-us/hq-core --json tagName -q .tagName' "$TMP/hook-invalid-json.gh" \
  || fail 'hook did not fall back to the default source on invalid JSON'
[ ! -s "$TMP/hook-invalid-json.err" ] || fail 'hook wrote to stderr on invalid HQ_CORE_SOURCE'
pass 'update check falls back to the default source on invalid HQ_CORE_SOURCE and stays quiet'

run_hook hook-badtag 'HQ_CORE_SOURCE={"apiBase":"https://badtag.example.test/api/v3"}'
grep -Fq '[https://badtag.example.test/api/v3/repos/indigoai-us/hq-core/releases/latest]' "$TMP/hook-badtag.curl" \
  || fail 'bad-tag fixture was not queried'
[ ! -s "$TMP/hook-badtag.out" ] || fail "hook printed a banner for a non-X.Y.Z tag: $(cat "$TMP/hook-badtag.out")"
[ ! -e "$TMP/hq/workspace/.hq-update-check/last-check.json" ] || fail 'hook cached a non-X.Y.Z tag'
pass 'update check ignores a release tag that is not X.Y.Z from an overridden host'

run_hook hook-down 'HQ_CORE_SOURCE={"apiBase":"https://down.example.test/api/v3"}'
grep -Fq '[https://down.example.test/api/v3/repos/indigoai-us/hq-core/releases/latest]' "$TMP/hook-down.curl" \
  || fail 'down-host fixture was not queried'
[ ! -s "$TMP/hook-down.out" ] || fail 'hook printed output when the overridden host failed'
[ ! -e "$TMP/hq/workspace/.hq-update-check/last-check.json" ] || fail 'hook cached a release when the host failed'
[ -f "$TMP/hook-down.state/release-network-attempt.last" ] || fail 'hook did not record the failed network attempt'
pass 'update check stays silent and records the attempt when the overridden host fails'

printf 'all hq-core-source tests passed\n'
