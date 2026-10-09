#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="${HQ_TEST_HOOK:-$ROOT/.claude/hooks/check-hq-update.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
pass() { printf 'PASS: %s\n' "$*"; }

make_root() {
  local name="$1"
  mkdir -p "$TMP/$name/core/scripts" "$TMP/$name/workspace/.hq-update-check" "$TMP/$name/.claude"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TMP/$name/core/scripts/remove-stray-gate-hooks.sh"
  chmod +x "$TMP/$name/core/scripts/remove-stray-gate-hooks.sh"
}

run_hook() {
  local name="$1" path="$2" rc=0
  env -u CI \
    BASH_ENV=/dev/null \
    CLAUDE_PROJECT_DIR="$TMP/$name" \
    HQ_ROOT="$TMP/$name" \
    HQ_UPDATE_CHECK_STATE_DIR="$TMP/$name/state" \
    PATH="$path:/usr/bin:/bin" \
    bash "$HOOK" > "$TMP/$name.out" 2> "$TMP/$name.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "$name returned $rc instead of 0"
  [ ! -s "$TMP/$name.err" ] || fail "$name wrote to stderr"
}

# core.yaml production versions include prerelease suffixes. The previous
# parser extracted their numeric prefix, so keep that comparison and banner.
make_root prerelease
printf 'hqVersion: "16.0.0-beta.37"\n' > "$TMP/prerelease/core/core.yaml"
printf '{"latest":"16.0.1","checkedAt":"recent"}\n' > "$TMP/prerelease/workspace/.hq-update-check/last-check.json"
touch "$TMP/prerelease/workspace/.hq-update-check/last-check.json"
run_hook prerelease "$TMP/empty-bin"
if grep -Fq '<hq-update-available>' "$TMP/prerelease.out" \
  && grep -Fq 'current: v16.0.0' "$TMP/prerelease.out"; then
  pass 'prerelease core.yaml versions retain the origin/main update notice'
else
  fail 'prerelease core.yaml value did not retain the origin/main update notice'
fi

# A newly created settings.local.json must invalidate the heal identity.
make_root heal-cache
printf 'hqVersion: "16.0.0"\n' > "$TMP/heal-cache/core/core.yaml"
printf '%s\n' '#!/usr/bin/env bash' 'printf "heal\n" >> "$HQ_TEST_HEAL_CALLS"' \
  > "$TMP/heal-cache/core/scripts/remove-stray-gate-hooks.sh"
chmod +x "$TMP/heal-cache/core/scripts/remove-stray-gate-hooks.sh"
printf '{}\n' > "$TMP/heal-cache/.claude/settings.json"
mkdir -p "$TMP/empty-bin"
env -u CI BASH_ENV=/dev/null CLAUDE_PROJECT_DIR="$TMP/heal-cache" HQ_ROOT="$TMP/heal-cache" \
  HQ_UPDATE_CHECK_STATE_DIR="$TMP/heal-cache/state" HQ_TEST_HEAL_CALLS="$TMP/heal-cache/heal.calls" \
  PATH="$TMP/empty-bin:/usr/bin:/bin" bash "$HOOK" > "$TMP/heal-first.out" 2> "$TMP/heal-first.err"
printf '{}\n' > "$TMP/heal-cache/.claude/settings.local.json"
env -u CI BASH_ENV=/dev/null CLAUDE_PROJECT_DIR="$TMP/heal-cache" HQ_ROOT="$TMP/heal-cache" \
  HQ_UPDATE_CHECK_STATE_DIR="$TMP/heal-cache/state" HQ_TEST_HEAL_CALLS="$TMP/heal-cache/heal.calls" \
  PATH="$TMP/empty-bin:/usr/bin:/bin" bash "$HOOK" > "$TMP/heal-second.out" 2> "$TMP/heal-second.err"
heal_calls="$(wc -l < "$TMP/heal-cache/heal.calls" | tr -d '[:space:]')"
if [ "$heal_calls" = 2 ] && cmp -s "$TMP/heal-first.out" "$TMP/heal-second.out" \
  && [ ! -s "$TMP/heal-first.err" ] && [ ! -s "$TMP/heal-second.err" ]; then
  pass 'settings.local.json creation invalidates the heal identity'
else
  fail "creating settings.local.json did not invalidate heal cache cleanly (calls=$heal_calls)"
fi

# Removing the release cache is the documented force-recheck control, even
# while a recent failed-attempt stamp exists.
make_root force-recheck
printf 'hqVersion: "15.0.131"\n' > "$TMP/force-recheck/core/core.yaml"
mkdir -p "$TMP/force-recheck/state" "$TMP/force-recheck-bin"
printf '{"latest":"15.0.200","checkedAt":"stale"}\n' > "$TMP/force-recheck/workspace/.hq-update-check/last-check.json"
touch -t 200001010000 "$TMP/force-recheck/workspace/.hq-update-check/last-check.json"
cat > "$TMP/force-recheck-bin/gh" <<'EOF_GH'
#!/usr/bin/env bash
printf '%s %s\n' "${1:-}" "${2:-}" >> "$HQ_TEST_GH_CALLS"
exit 1
EOF_GH
chmod +x "$TMP/force-recheck-bin/gh"
env -u CI BASH_ENV=/dev/null CLAUDE_PROJECT_DIR="$TMP/force-recheck" HQ_ROOT="$TMP/force-recheck" \
  HQ_UPDATE_CHECK_STATE_DIR="$TMP/force-recheck/state" HQ_TEST_GH_CALLS="$TMP/force-recheck/gh.calls" \
  PATH="$TMP/force-recheck-bin:/usr/bin:/bin" bash "$HOOK" > "$TMP/force-recheck.out" 2> "$TMP/force-recheck.err"
first_calls="$(wc -l < "$TMP/force-recheck/gh.calls" | tr -d '[:space:]')"
[ "$first_calls" = 1 ] || fail "first stale-cache attempt count was $first_calls, expected 1"
rm "$TMP/force-recheck/workspace/.hq-update-check/last-check.json"
env -u CI BASH_ENV=/dev/null CLAUDE_PROJECT_DIR="$TMP/force-recheck" HQ_ROOT="$TMP/force-recheck" \
  HQ_UPDATE_CHECK_STATE_DIR="$TMP/force-recheck/state" HQ_TEST_GH_CALLS="$TMP/force-recheck/gh.calls" \
  PATH="$TMP/force-recheck-bin:/usr/bin:/bin" bash "$HOOK" > "$TMP/force-recheck-again.out" 2> "$TMP/force-recheck-again.err"
retry_calls="$(wc -l < "$TMP/force-recheck/gh.calls" | tr -d '[:space:]')"
if [ "$retry_calls" = 2 ] && cmp -s "$TMP/force-recheck.out" "$TMP/force-recheck-again.out" \
  && [ ! -s "$TMP/force-recheck.err" ] && [ ! -s "$TMP/force-recheck-again.err" ]; then
  pass 'deleting last-check.json forces a network retry despite the failure stamp'
else
  fail 'recent failure stamp suppressed the documented forced network re-check'
fi

# Replacing the target behind an unchanged symlink must invalidate the CLI
# version probe cache. Check call counts; elapsed time is diagnostic only.
make_root resolved-target
printf 'hqVersion: "16.0.0"\n' > "$TMP/resolved-target/core/core.yaml"
mkdir -p "$TMP/resolved-target-bin" "$TMP/resolved-target/pkg"
cat > "$TMP/resolved-target/pkg/hq" <<'EOF_HQ'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'probe\n' >> "$HQ_TEST_VERSION_CALLS"
  printf 'hq 5.331.0\n'
fi
EOF_HQ
chmod +x "$TMP/resolved-target/pkg/hq"
ln -s "$TMP/resolved-target/pkg/hq" "$TMP/resolved-target-bin/hq"
for run in first second; do
  env -u CI BASH_ENV=/dev/null CLAUDE_PROJECT_DIR="$TMP/resolved-target" HQ_ROOT="$TMP/resolved-target" \
    HQ_UPDATE_CHECK_STATE_DIR="$TMP/resolved-target/state" HQ_TEST_VERSION_CALLS="$TMP/resolved-target/version.calls" \
    PATH="$TMP/resolved-target-bin:/usr/bin:/bin" bash "$HOOK" > "$TMP/target-$run.out" 2> "$TMP/target-$run.err"
done
cat > "$TMP/resolved-target/pkg/replacement" <<'EOF_HQ'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'probe\n' >> "$HQ_TEST_VERSION_CALLS"
  printf 'hq 5.332.0\n'
fi
EOF_HQ
chmod +x "$TMP/resolved-target/pkg/replacement"
mv "$TMP/resolved-target/pkg/replacement" "$TMP/resolved-target/pkg/hq.new"
mv "$TMP/resolved-target/pkg/hq.new" "$TMP/resolved-target/pkg/hq"
env -u CI BASH_ENV=/dev/null CLAUDE_PROJECT_DIR="$TMP/resolved-target" HQ_ROOT="$TMP/resolved-target" \
  HQ_UPDATE_CHECK_STATE_DIR="$TMP/resolved-target/state" HQ_TEST_VERSION_CALLS="$TMP/resolved-target/version.calls" \
  PATH="$TMP/resolved-target-bin:/usr/bin:/bin" bash "$HOOK" > "$TMP/target-replaced.out" 2> "$TMP/target-replaced.err"
version_calls="$(wc -l < "$TMP/resolved-target/version.calls" | tr -d '[:space:]')"
if [ "$version_calls" = 2 ] && cmp -s "$TMP/target-first.out" "$TMP/target-second.out" \
  && cmp -s "$TMP/target-second.out" "$TMP/target-replaced.out" && [ ! -s "$TMP/target-first.err" ] \
  && [ ! -s "$TMP/target-second.err" ] && [ ! -s "$TMP/target-replaced.err" ]; then
  pass 'replacing the hq symlink target refreshes the cached version probe'
else
  fail "replacing the symlink target did not refresh the version probe cleanly (calls=$version_calls)"
fi

[ "$failures" -eq 0 ] || exit 1
