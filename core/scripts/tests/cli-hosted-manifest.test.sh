#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPTS="$ROOT/core/scripts"
FIXTURE="$SCRIPTS/tests/fixtures/cli-hosted"
GENERATOR="$SCRIPTS/generate-forwarders.sh"
GUARD="$SCRIPTS/check-cli-hosted.sh"
FLOOR_LIBRARY="$SCRIPTS/lib/hq-cli-floor.sh"
NODE_BIN="$(command -v node)"
TMP="$(mktemp -d /tmp/cli-hosted-manifest.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
CATALOG_TEST_BIN="$TMP/catalog-old-cli/bin"
CATALOG_TEST_NPM_ROOT="$TMP/catalog-old-cli/lib/node_modules"
mkdir -p "$CATALOG_TEST_BIN" "$CATALOG_TEST_NPM_ROOT/@indigoai-us/hq-cli"
cat > "$CATALOG_TEST_BIN/hq" <<'EOF'
#!/usr/bin/env bash
if [ "${1-}" = "--version" ]; then printf '5.276.0\n'; exit 0; fi
if [ "${1-}" = "core" ] && [ "${2-}" = "--help" ]; then exit 0; fi
if [ "${1-}" = "core" ] && [ "${2-}" = "commands" ]; then
  printf 'unknown command\n' >&2
  exit 1
fi
exit 64
EOF
cat > "$CATALOG_TEST_BIN/npm" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = "root -g" ]; then printf '%s\n' "$CATALOG_TEST_NPM_ROOT"; exit 0; fi
exit 64
EOF
chmod +x "$CATALOG_TEST_BIN/hq" "$CATALOG_TEST_BIN/npm"
printf '# Changelog\n\n## [5.276.0]\n\n- Existing CLI release.\n' \
  > "$CATALOG_TEST_NPM_ROOT/@indigoai-us/hq-cli/CHANGELOG.md"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "$3: expected [$2], got [$1]"
}

assert_file_eq() {
  if ! cmp -s "$1" "$2"; then
    printf 'FAIL: %s differs\n' "$3" >&2
    diff -u "$2" "$1" >&2 || true
    exit 1
  fi
}

make_tree() {
  local tree="$1" with_floor="$2"
  mkdir -p "$tree"
  bash "$GENERATOR" --manifest "$FIXTURE/manifest.yaml" --output-root "$tree"
  if [ "$with_floor" = yes ]; then
    mkdir -p "$tree/core/scripts/lib"
    cp "$FLOOR_LIBRARY" "$tree/core/scripts/lib/hq-cli-floor.sh"
  fi
}

make_hq_stub() {
  local bin="$1" version="$2" version_log="$3"
  mkdir -p "$bin"
  cat > "$bin/hq" <<EOF
#!/usr/bin/env bash
if [ "\${1-}" = "--version" ]; then
  printf '%s\\n' '$version'
  if [ -n '$version_log' ]; then printf 'checked\\n' >> '$version_log'; fi
  exit 0
fi
last_argument=""
for argument do last_argument="\$argument"; done
if [ "\$last_argument" = "--signal" ]; then kill -TERM "\$\$"; fi
printf 'cwd=%s\\n' "\$PWD"
printf 'stdout:start\\n'
for argument do printf '<%s>\\n' "\$argument"; done
cat
printf 'stdout:end\\n'
printf 'stderr:from hq\\n' >&2
exit 7
EOF
  chmod +x "$bin/hq"
}

make_guard_root() {
  local tree="$1"
  make_tree "$tree" no
  cp "$FIXTURE/manifest.yaml" "$tree/core/scripts/cli-hosted.yaml"
  mkdir -p "$tree/core/scripts"
  cat > "$tree/core/scripts/fixture-hybrid.sh" <<'EOF'
#!/usr/bin/env bash
# hq core fixture-hybrid is the delegated command.
exec hq core --hq-root "$PWD" fixture-hybrid "$@"
EOF
  chmod +x "$tree/core/scripts/fixture-hybrid.sh"
  git -C "$tree" init -q
  git -C "$tree" add -A
}

expect_guard_failure() {
  local tree="$1" needle="$2" label="$3"
  if CATALOG_TEST_NPM_ROOT="$CATALOG_TEST_NPM_ROOT" PATH="$CATALOG_TEST_BIN:$PATH" \
    bash "$GUARD" --root "$tree" --manifest "$tree/core/scripts/cli-hosted.yaml" > "$TMP/guard.out" 2> "$TMP/guard.err"; then
    fail "$label: guard accepted invalid fixture"
  fi
  if ! grep -F -q -- "$needle" "$TMP/guard.err"; then
    cat "$TMP/guard.err" >&2
    fail "$label: guard output did not include [$needle]"
  fi
  printf 'ok: %s\n' "$label"
}

GENERATED="$TMP/generated"
make_tree "$GENERATED" no
for name in fixture-live.sh fixture-cwd.sh fixture-node.mjs; do
  assert_file_eq "$GENERATED/core/scripts/$name" "$FIXTURE/$name.expected.txt" "generator golden $name"
done
bash -n "$GENERATED/core/scripts/fixture-live.sh" "$GENERATED/core/scripts/fixture-cwd.sh"
"$NODE_BIN" --check "$GENERATED/core/scripts/fixture-node.mjs"
printf 'ok: live, cwd and Node templates match synthetic goldens\n'

TREE="$TMP/run-tree"
make_tree "$TREE" yes
CALLER="$TMP/caller"
mkdir -p "$CALLER"
printf 'stdin line one\nstdin line two\n' > "$TMP/stdin"
make_hq_stub "$TMP/hq-new" 99.0.0 "$TMP/version-new.log"

run_status=0
if (cd "$CALLER"; unset HQ_ROOT; PATH="$TMP/hq-new:/usr/bin:/bin" /bin/bash "$TREE/core/scripts/fixture-live.sh" 'one word' '' --flag < "$TMP/stdin" > "$TMP/live.out" 2> "$TMP/live.err"); then
  run_status=0
else
  run_status=$?
fi
assert_eq "$run_status" 7 'live forwarder exit status'
{
  printf 'cwd=%s\nstdout:start\n<core>\n<--hq-root>\n<%s>\n<fixture-live>\n<one word>\n<>\n<--flag>\n' "$CALLER" "$TREE"
  cat "$TMP/stdin"
  printf 'stdout:end\n'
} > "$TMP/live.expected"
printf 'stderr:from hq\n' > "$TMP/live.stderr.expected"
assert_file_eq "$TMP/live.out" "$TMP/live.expected" 'live argv, cwd, stdin and stdout'
assert_file_eq "$TMP/live.err" "$TMP/live.stderr.expected" 'live stderr'
[ -s "$TMP/version-new.log" ] || fail 'CLI floor pass did not query the installed version'

make_hq_stub "$TMP/hq-no-home" 99.0.0 "$TMP/version-no-home.log"
run_status=0
if (cd "$CALLER"; unset HQ_ROOT HOME XDG_CACHE_HOME; PATH="$TMP/hq-no-home:/usr/bin:/bin" /bin/bash "$TREE/core/scripts/fixture-live.sh" 'one word' '' --flag < "$TMP/stdin" > "$TMP/no-home.out" 2> "$TMP/no-home.err"); then
  run_status=0
else
  run_status=$?
fi
assert_eq "$run_status" 7 'forwarder exit status without HOME or XDG_CACHE_HOME'
assert_file_eq "$TMP/no-home.out" "$TMP/live.expected" 'forwarder argv and stdout without HOME or XDG_CACHE_HOME'
assert_file_eq "$TMP/no-home.err" "$TMP/live.stderr.expected" 'forwarder stderr without HOME or XDG_CACHE_HOME'
[ -s "$TMP/version-no-home.log" ] || fail 'CLI floor without HOME or XDG_CACHE_HOME did not query the installed version'

run_status=0
if (cd "$CALLER"; unset HQ_ROOT; PATH="$TMP/hq-new:/usr/bin:/bin" /bin/bash "$TREE/core/scripts/fixture-cwd.sh" 'one word' '' --flag < "$TMP/stdin" > "$TMP/cwd.out" 2> "$TMP/cwd.err"); then
  run_status=0
else
  run_status=$?
fi
assert_eq "$run_status" 7 'cwd forwarder exit status'
{
  printf 'cwd=%s\nstdout:start\n<core>\n<fixture-cwd>\n<one word>\n<>\n<--flag>\n' "$CALLER"
  cat "$TMP/stdin"
  printf 'stdout:end\n'
} > "$TMP/cwd.expected"
assert_file_eq "$TMP/cwd.out" "$TMP/cwd.expected" 'cwd argv, cwd, stdin and stdout'
assert_file_eq "$TMP/cwd.err" "$TMP/live.stderr.expected" 'cwd stderr'

run_status=0
if (cd "$CALLER"; unset HQ_ROOT; PATH="$TMP/hq-new:/usr/bin:/bin" "$NODE_BIN" "$TREE/core/scripts/fixture-node.mjs" 'one word' '' --flag < "$TMP/stdin" > "$TMP/node.out" 2> "$TMP/node.err"); then
  run_status=0
else
  run_status=$?
fi
assert_eq "$run_status" 7 'Node forwarder exit status'
{
  printf 'cwd=%s\nstdout:start\n<core>\n<--hq-root>\n<%s>\n<fixture-node>\n<one word>\n<>\n<--flag>\n' "$CALLER" "$TREE"
  cat "$TMP/stdin"
  printf 'stdout:end\n'
} > "$TMP/node.expected"
assert_file_eq "$TMP/node.out" "$TMP/node.expected" 'Node argv, cwd, stdin and stdout'
assert_file_eq "$TMP/node.err" "$TMP/live.stderr.expected" 'Node stderr'
printf 'ok: Bash and Node forwarding preserve argv, stdin, stdout, stderr, cwd and exit code\n'

for name in fixture-live.sh fixture-cwd.sh fixture-node.mjs; do
  if [ "$name" = fixture-node.mjs ]; then
    runner=("$NODE_BIN" "$TREE/core/scripts/$name")
  else
    runner=(/bin/bash "$TREE/core/scripts/$name")
  fi
  run_status=0
  if (cd "$CALLER"; unset HQ_ROOT; PATH="$TMP/hq-new:/usr/bin:/bin" "${runner[@]}" --signal > "$TMP/signal.out" 2> "$TMP/signal.err"); then
    run_status=0
  else
    run_status=$?
  fi
  assert_eq "$run_status" 143 "$name signal forwarding"
done
printf 'ok: Bash and Node forward child signals\n'

make_hq_stub "$TMP/hq-old" 5.10.0 "$TMP/version-old.log"
for name in fixture-live.sh fixture-node.mjs; do
  if [ "$name" = fixture-node.mjs ]; then
    runner=("$NODE_BIN" "$TREE/core/scripts/$name")
  else
    runner=(/bin/bash "$TREE/core/scripts/$name")
  fi
  run_status=0
  if (cd "$CALLER"; unset HQ_ROOT; PATH="$TMP/hq-old:/usr/bin:/bin" "${runner[@]}" > "$TMP/floor.out" 2> "$TMP/floor.err"); then
    run_status=0
  else
    run_status=$?
  fi
  if [ "$name" = fixture-node.mjs ]; then minimum=5.33.0; else minimum=5.11.0; fi
  assert_eq "$run_status" 127 "$name old CLI floor status"
  [ ! -s "$TMP/floor.out" ] || fail "$name old CLI floor wrote stdout"
  printf '%s: this script needs hq-cli >= %s (found 5.10.0); upgrade with: npm install -g @indigoai-us/hq-cli@latest\n' "$name" "$minimum" > "$TMP/floor.expected"
  assert_file_eq "$TMP/floor.err" "$TMP/floor.expected" "$name exact old CLI floor message"
done
printf 'ok: Bash and Node per-command floors pass and reject old CLI versions exactly\n'

NO_FLOOR="$TMP/no-floor-tree"
make_tree "$NO_FLOOR" no
make_hq_stub "$TMP/hq-no-floor" 99.0.0 "$TMP/version-no-floor.log"
run_status=0
if (cd "$CALLER"; unset HQ_ROOT; PATH="$TMP/hq-no-floor:/usr/bin:/bin" /bin/bash "$NO_FLOOR/core/scripts/fixture-live.sh" > "$TMP/no-floor.out" 2> "$TMP/no-floor.err"); then
  run_status=0
else
  run_status=$?
fi
assert_eq "$run_status" 7 'missing floor library fail-open status'
[ ! -e "$TMP/version-no-floor.log" ] || fail 'missing floor library still probed hq --version'
grep -F -q 'stdout:start' "$TMP/no-floor.out" || fail 'missing floor library did not invoke hq'
run_status=0
if (cd "$CALLER"; unset HQ_ROOT; PATH="$TMP/hq-no-floor:/usr/bin:/bin" "$NODE_BIN" "$NO_FLOOR/core/scripts/fixture-node.mjs" > "$TMP/no-floor-node.out" 2> "$TMP/no-floor-node.err"); then
  run_status=0
else
  run_status=$?
fi
assert_eq "$run_status" 7 'Node missing floor library fail-open status'
[ ! -e "$TMP/version-no-floor.log" ] || fail 'Node missing floor library still probed hq --version'
grep -F -q 'stdout:start' "$TMP/no-floor-node.out" || fail 'Node missing floor library did not invoke hq'
printf 'ok: missing floor library skips the check and invokes hq\n'

EMPTY_PATH="$TMP/no-hq"
mkdir -p "$EMPTY_PATH"
ln -s "$(command -v dirname)" "$EMPTY_PATH/dirname"
for name in fixture-live.sh fixture-node.mjs; do
  if [ "$name" = fixture-node.mjs ]; then
    runner=("$NODE_BIN" "$TREE/core/scripts/$name")
  else
    runner=(/bin/bash "$TREE/core/scripts/$name")
  fi
  run_status=0
  if (cd "$CALLER"; unset HQ_ROOT; PATH="$EMPTY_PATH" "${runner[@]}" > "$TMP/missing.out" 2> "$TMP/missing.err"); then
    run_status=0
  else
    run_status=$?
  fi
  assert_eq "$run_status" 127 "$name missing CLI status"
  {
    printf '%s: requires the hq CLI — this script\047s implementation now ships with it.\n' "$name"
    printf 'Install it with: npm install -g @indigoai-us/hq-cli\n'
  } > "$TMP/missing.expected"
  assert_file_eq "$TMP/missing.err" "$TMP/missing.expected" "$name unchanged missing CLI text"
done
printf 'ok: missing CLI message and exit code are unchanged\n'

GUARD_ROOT="$TMP/guard-clean"
make_guard_root "$GUARD_ROOT"
CATALOG_TEST_NPM_ROOT="$CATALOG_TEST_NPM_ROOT" PATH="$CATALOG_TEST_BIN:$PATH" \
  bash "$GUARD" --root "$GUARD_ROOT" --manifest "$GUARD_ROOT/core/scripts/cli-hosted.yaml" > "$TMP/guard-clean.out" 2> "$TMP/guard-clean.err" || fail 'guard rejected a clean synthetic tree'
grep -F -q 'cli-hosted manifest and backmerge checks passed' "$TMP/guard-clean.out" || fail 'guard clean success line missing'
printf 'ok: guard accepts a clean synthetic tree\n'

GUARD_ROOT="$TMP/guard-js-diagnostic"
make_guard_root "$GUARD_ROOT"
cat > "$GUARD_ROOT/core/scripts/diagnostic-only.mjs" <<'EOF'
throw new Error("hq core commands --json must return an array");
EOF
git -C "$GUARD_ROOT" add -A
if CATALOG_TEST_NPM_ROOT="$CATALOG_TEST_NPM_ROOT" PATH="$CATALOG_TEST_BIN:$PATH" \
  bash "$GUARD" --root "$GUARD_ROOT" --manifest "$GUARD_ROOT/core/scripts/cli-hosted.yaml" > "$TMP/guard-js-diagnostic.out" 2> "$TMP/guard-js-diagnostic.err"; then
  printf 'ok: JavaScript diagnostic text is not an executable CLI call\n'
else
  cat "$TMP/guard-js-diagnostic.err" >&2
  fail 'guard treated JavaScript diagnostic text as an executable CLI call'
fi

GUARD_ROOT="$TMP/guard-js-real-call"
make_guard_root "$GUARD_ROOT"
{
  printf 'execSync("hq core stray");\n'
  awk 'BEGIN { for (i = 0; i < 20000; i++) print "const filler" i " = true;" }'
} > "$GUARD_ROOT/core/scripts/large-unmanifested.mjs"
git -C "$GUARD_ROOT" add -A
expect_guard_failure "$GUARD_ROOT" 'core/scripts/large-unmanifested.mjs: unmanifested executable hq core call lacks a manifest row or explicit allow-list entry' 'guard detects an early JavaScript CLI call in a large source file'

GUARD_ROOT="$TMP/guard-drift"
make_guard_root "$GUARD_ROOT"
printf '# drift\n' >> "$GUARD_ROOT/core/scripts/fixture-live.sh"
git -C "$GUARD_ROOT" add -A
expect_guard_failure "$GUARD_ROOT" 'core/scripts/fixture-live.sh: generated forwarder differs from manifest' 'guard detects generated drift'

GUARD_ROOT="$TMP/guard-retired"
make_guard_root "$GUARD_ROOT"
printf 'fixture\n' > "$GUARD_ROOT/core/scripts/fixture-retired.sh"
git -C "$GUARD_ROOT" add -A
expect_guard_failure "$GUARD_ROOT" 'core/scripts/fixture-retired.sh: retired path exists in tree' 'guard rejects a re-added retired path'

GUARD_ROOT="$TMP/guard-deleted"
make_guard_root "$GUARD_ROOT"
printf 'fixture\n' > "$GUARD_ROOT/core/scripts/fixture-deleted.sh"
git -C "$GUARD_ROOT" add -A
expect_guard_failure "$GUARD_ROOT" 'core/scripts/fixture-deleted.sh: deleted path exists in tree' 'guard rejects a re-added deleted path'

GUARD_ROOT="$TMP/guard-retired-reference"
make_guard_root "$GUARD_ROOT"
printf 'Backmerge reference: core/scripts/fixture-retired.sh\n' > "$GUARD_ROOT/README.txt"
git -C "$GUARD_ROOT" add -A
expect_guard_failure "$GUARD_ROOT" 'tracked file README.txt references retired path' 'guard rejects tracked references to retired paths'

GUARD_ROOT="$TMP/guard-deleted-reference"
make_guard_root "$GUARD_ROOT"
printf 'Backmerge reference: core/scripts/fixture-deleted.sh\n' > "$GUARD_ROOT/README.txt"
git -C "$GUARD_ROOT" add -A
expect_guard_failure "$GUARD_ROOT" 'tracked file README.txt references deleted path' 'guard rejects tracked references to deleted paths'

GUARD_ROOT="$TMP/guard-hybrid"
make_guard_root "$GUARD_ROOT"
printf '#!/usr/bin/env bash\necho stale\n' > "$GUARD_ROOT/core/scripts/fixture-hybrid.sh"
git -C "$GUARD_ROOT" add -A
expect_guard_failure "$GUARD_ROOT" 'core/scripts/fixture-hybrid.sh: hybrid row has no executable hq core fixture-hybrid invocation' 'guard validates hybrid commands and permits global root options'

GUARD_ROOT="$TMP/guard-hybrid-comment"
make_guard_root "$GUARD_ROOT"
cat > "$GUARD_ROOT/core/scripts/fixture-hybrid.sh" <<'EOF'
#!/usr/bin/env bash
# exec hq core fixture-hybrid "$@"
EOF
git -C "$GUARD_ROOT" add -A
expect_guard_failure "$GUARD_ROOT" 'core/scripts/fixture-hybrid.sh: hybrid row has no executable hq core fixture-hybrid invocation' 'guard ignores a hybrid invocation in comments'

GUARD_ROOT="$TMP/guard-hybrid-heredoc"
make_guard_root "$GUARD_ROOT"
cat > "$GUARD_ROOT/core/scripts/fixture-hybrid.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'FIXTURE_BODY'
exec hq core fixture-hybrid "$@"
FIXTURE_BODY
EOF
git -C "$GUARD_ROOT" add -A
expect_guard_failure "$GUARD_ROOT" 'core/scripts/fixture-hybrid.sh: hybrid row has no executable hq core fixture-hybrid invocation' 'guard ignores a hybrid invocation in heredoc bodies'

GUARD_ROOT="$TMP/guard-unmanifested"
make_guard_root "$GUARD_ROOT"
mkdir -p "$GUARD_ROOT/core/scripts"
printf '#!/usr/bin/env bash\n%s %s %s stray "$@"\n' exec hq core > "$GUARD_ROOT/core/scripts/stray.sh"
git -C "$GUARD_ROOT" add -A
expect_guard_failure "$GUARD_ROOT" 'core/scripts/stray.sh: unmanifested executable hq core call lacks a manifest row or explicit allow-list entry' 'guard finds unmanifested forwarders'

GUARD_ROOT="$TMP/guard-unmanifested-plain"
make_guard_root "$GUARD_ROOT"
printf '#!/usr/bin/env bash\nhq core stray || true\n' > "$GUARD_ROOT/core/scripts/plain-call.sh"
git -C "$GUARD_ROOT" add -A
expect_guard_failure "$GUARD_ROOT" 'core/scripts/plain-call.sh: unmanifested executable hq core call lacks a manifest row or explicit allow-list entry' 'guard finds plain unmanifested CLI calls'

GUARD_ROOT="$TMP/guard-unmanifested-substitution"
make_guard_root "$GUARD_ROOT"
cat > "$GUARD_ROOT/core/scripts/substitution-call.sh" <<'EOF'
#!/usr/bin/env bash
result="$(hq core stray)"
EOF
git -C "$GUARD_ROOT" add -A
expect_guard_failure "$GUARD_ROOT" 'core/scripts/substitution-call.sh: unmanifested executable hq core call lacks a manifest row or explicit allow-list entry' 'guard finds command-substitution CLI calls'

GUARD_ROOT="$TMP/guard-generated-mode"
make_guard_root "$GUARD_ROOT"
chmod -x "$GUARD_ROOT/core/scripts/fixture-live.sh"
git -C "$GUARD_ROOT" add -A
expect_guard_failure "$GUARD_ROOT" 'core/scripts/fixture-live.sh: generated forwarder index mode is 100644, expected 100755' 'guard rejects generated forwarders without executable mode'

printf 'cli-hosted manifest tests passed\n'
