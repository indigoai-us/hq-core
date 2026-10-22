#!/usr/bin/env bash
# hq-core: public
# Machine PATH is local data regardless of a registry default or lookup failure.
# Actual setup helper only; all files and flag responses are synthetic.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home"
pass=0; fail=0
check() { if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $*"; fi; }
fixture() {
  local d="$TMP/$1"
  mkdir -p "$d/.claude" "$d/core/scripts"
  printf '{ "hooks": {}, "env": {"PATH":"/project/bin:/shared", "PROJECT":"kept"} }\n' > "$d/.claude/settings.json"
  printf '{"env":{"PATH":"/local/bin:/shared","LOCAL":"kept"},"permissions":{"allow":["Read"]}}\n' > "$d/.claude/settings.local.json"
  cp "$ROOT/core/scripts/compose-settings-path.sh" "$d/core/scripts/"
  cp "$d/.claude/settings.json" "$d/base.before"
  printf '%s' "$d"
}
run_helper() {
  HOME="$TMP/home" HQ_TOOLCHAIN_DIR="$TMP/no-toolchain" HQ_CLI_BIN="$TMP/missing-cli" \
    "$BASH" "$ROOT/core/scripts/configure-settings-path.sh" "$1" /process/bin:/shared:/usr/bin:/bin
}
expected="$(HQ_TOOLCHAIN_DIR="$TMP/no-toolchain" "$BASH" "$ROOT/core/scripts/compose-settings-path.sh" /local/bin:/shared:/project/bin:/shared:/process/bin:/shared:/usr/bin:/bin)"
for response in true false invalid failure missing actual-reader-failure; do
  d="$(fixture "$response")"
  case "$response" in
    true|false) printf 'process.stdout.write("%s\\n");\n' "$response" > "$d/core/scripts/setup-path-flag.cjs" ;;
    invalid) printf 'process.stdout.write("not-a-boolean\\n");\n' > "$d/core/scripts/setup-path-flag.cjs" ;;
    failure) printf 'process.stderr.write("TimeoutError\\n");process.exit(1);\n' > "$d/core/scripts/setup-path-flag.cjs" ;;
    actual-reader-failure) cp "$ROOT/core/scripts/setup-path-flag.cjs" "$d/core/scripts/" ;;
  esac
  run_helper "$d" > "$d/output"
  check cmp -s "$d/base.before" "$d/.claude/settings.json"
  check test "$(jq -r '.env.PATH' "$d/.claude/settings.local.json")" = "$expected"
  check test "$(jq -r '.env.LOCAL' "$d/.claude/settings.local.json")" = kept
  check test "$(jq -r '.permissions.allow[0]' "$d/.claude/settings.local.json")" = Read
  echo "checked $response"
done
for shape in malformed array env-scalar directory readonly-file; do
  d="$(fixture "$shape")"
  case "$shape" in
    malformed) printf '{bad\n' > "$d/.claude/settings.local.json" ;;
    array) printf '[1,2]\n' > "$d/.claude/settings.local.json" ;;
    env-scalar) printf '{"env":"bad"}\n' > "$d/.claude/settings.local.json" ;;
    directory) rm "$d/.claude/settings.local.json"; mkdir "$d/.claude/settings.local.json" ;;
    readonly-file) chmod 400 "$d/.claude/settings.local.json" ;;
  esac
  if [[ -f "$d/.claude/settings.local.json" ]]; then cp "$d/.claude/settings.local.json" "$d/local.before"; fi
  if [[ "$shape" == readonly-file && "$(id -u)" == 0 ]]; then
    echo 'SKIP actual permission failure as root'; continue
  fi
  run_helper "$d" > "$d/output" 2>&1 || true
  check cmp -s "$d/base.before" "$d/.claude/settings.json"
  if [[ -f "$d/local.before" ]]; then check cmp -s "$d/local.before" "$d/.claude/settings.local.json"; else check test -d "$d/.claude/settings.local.json"; fi
  check grep -q 'PATH not configured' "$d/output"
  echo "checked invalid-local $shape"
done
d="$(fixture first-local)"; rm "$d/.claude/settings.local.json"
run_helper "$d" > "$d/output"
check cmp -s "$d/base.before" "$d/.claude/settings.json"
check test "$(jq -r '.env.PATH' "$d/.claude/settings.local.json")" = "$(HQ_TOOLCHAIN_DIR="$TMP/no-toolchain" "$BASH" "$ROOT/core/scripts/compose-settings-path.sh" /project/bin:/shared:/process/bin:/shared:/usr/bin:/bin)"
check grep -Fq configure-settings-path.sh "$ROOT/core/scripts/setup.sh"
# Real kernel file-size failures: zero bytes reproduces the maintainer case;
# one block lets the old local file fit but the larger new PATH write fail.
for limit in 0 1; do
  d="$(fixture "file-limit-$limit")"
  cp "$d/.claude/settings.local.json" "$d/local.before"
  large_path="/long/$(printf '%12000s' '' | tr ' ' a)"
  (ulimit -c 0; ulimit -f "$limit"; HOME="$TMP/home" HQ_TOOLCHAIN_DIR="$TMP/no-toolchain" \
    "$BASH" "$ROOT/core/scripts/configure-settings-path.sh" "$d" "$large_path:/usr/bin:/bin") >/dev/null 2>&1 || true
  check cmp -s "$d/local.before" "$d/.claude/settings.local.json"
  check cmp -s "$d/base.before" "$d/.claude/settings.json"
  check test -z "$(find "$d/.claude" -name '.hq-settings.local.json.tmp.*' -print)"
  echo "checked actual kernel file-size limit $limit"
done
# The final publication may fail after a successful staging write.
d="$(fixture rename-failure)"
cp "$d/.claude/settings.local.json" "$d/local.before"
mkdir -p "$TMP/fail-mv"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$HQ_TEST_MV_LOG"\nexit 1\n' > "$TMP/fail-mv/mv"
chmod +x "$TMP/fail-mv/mv"
PATH="$TMP/fail-mv:$PATH" HQ_TEST_MV_LOG="$d/mv-args" run_helper "$d" > "$d/output" 2>&1 || true
check cmp -s "$d/local.before" "$d/.claude/settings.local.json"
check cmp -s "$d/base.before" "$d/.claude/settings.json"
check test -z "$(find "$d/.claude" -name '.hq-settings.local.json.tmp.*' -print)"
check grep -q 'PATH not configured' "$d/output"
check grep -Eq '/\.hq-settings\.local\.json\.tmp\.[A-Za-z0-9]{6}$' "$d/mv-args"
# Existing mode survives replacement; new local settings remain private.
d="$(fixture preserve-mode)"; chmod 640 "$d/.claude/settings.local.json"
run_helper "$d" > "$d/output"
check node -e 'const fs=require("fs"); process.exit((fs.statSync(process.argv[1]).mode&511)===416?0:1)' "$d/.claude/settings.local.json"
d="$(fixture private-mode)"; rm "$d/.claude/settings.local.json"
run_helper "$d" > "$d/output"
check node -e 'const fs=require("fs"); process.exit((fs.statSync(process.argv[1]).mode&511)===384?0:1)' "$d/.claude/settings.local.json"
# Refuse every local symlink before parsing it, even if its target is inside HQ.
real_jq="$(command -v jq)"
mkdir -p "$TMP/observe-jq"
cat > "$TMP/observe-jq/jq" <<'JQ_SHIM'
#!/bin/sh
for arg do
  if [ "$arg" = "$HQ_TEST_LOCAL" ]; then printf 'read\n' >> "$HQ_TEST_READ_LOG"; fi
done
exec "$HQ_TEST_REAL_JQ" "$@"
JQ_SHIM
chmod +x "$TMP/observe-jq/jq"
for target_scope in inside outside; do
  d="$(fixture "symlink-$target_scope")"
  if [[ "$target_scope" == inside ]]; then target="$d/local-target.json"; else target="$TMP/outside-target.json"; fi
  mv "$d/.claude/settings.local.json" "$target"
  cp "$target" "$d/target.before"
  ln -s "$target" "$d/.claude/settings.local.json"
  PATH="$TMP/observe-jq:$PATH" HQ_TEST_REAL_JQ="$real_jq" HQ_TEST_LOCAL="$d/.claude/settings.local.json" \
    HQ_TEST_READ_LOG="$d/reads" run_helper "$d" > "$d/output" 2>&1 || true
  check test -L "$d/.claude/settings.local.json"
  check cmp -s "$d/target.before" "$target"
  check cmp -s "$d/base.before" "$d/.claude/settings.json"
  check test ! -e "$d/reads"
  check grep -q 'PATH not configured' "$d/output"
done
# Refuse a linked parent too: otherwise staging itself escapes the root.
d="$(fixture symlink-parent)"
target="$TMP/outside-claude"
mv "$d/.claude" "$target"
cp "$target/settings.local.json" "$d/local.before"
ln -s "$target" "$d/.claude"
PATH="$TMP/observe-jq:$PATH" HQ_TEST_REAL_JQ="$real_jq" HQ_TEST_LOCAL="$d/.claude/settings.local.json" \
  HQ_TEST_READ_LOG="$d/reads" run_helper "$d" > "$d/output" 2>&1 || true
check test -L "$d/.claude"
check cmp -s "$d/local.before" "$target/settings.local.json"
check cmp -s "$d/base.before" "$target/settings.json"
check test ! -e "$d/reads"
check grep -q 'PATH not configured' "$d/output"
# BOM is unsupported local JSON: preserve it rather than silently normalize it.
d="$(fixture bom-local)"
printf '\357\273\277{"env":{"LOCAL":"kept"}}\n' > "$d/.claude/settings.local.json"
cp "$d/.claude/settings.local.json" "$d/local.before"
run_helper "$d" > "$d/output" 2>&1 || true
check cmp -s "$d/local.before" "$d/.claude/settings.local.json"
check cmp -s "$d/base.before" "$d/.claude/settings.json"
check grep -q 'PATH not configured' "$d/output"
echo "PASS=$pass FAIL=$fail"
[[ "$fail" -eq 0 ]]
