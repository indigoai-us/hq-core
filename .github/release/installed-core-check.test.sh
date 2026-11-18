#!/usr/bin/env bash
# Regression test for installed-core-check.sh: a staged release tree passes the
# hq-cli installed-core check, and a leaked test or tooling file fails it.
# Uses the published checker (npm pack), as release.yml does.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
check="$root/.github/release/installed-core-check.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stage="$tmp/stage"
mkdir -p "$stage"
rsync -a --exclude=.git --exclude=.github --exclude=.leak-scan \
  --exclude-from="$root/.github/release/install-excludes.rsync" "$root/" "$stage/"

# Default path: the checker is fetched with npm pack.
bash "$check" "$stage"

# Later cases reuse one packed checker.
version=$(sed -n 's/^CHECKER_CLI_VERSION="\(.*\)"$/\1/p' "$check")
npm pack "@indigoai-us/hq-cli@$version" --silent --pack-destination "$tmp" > "$tmp/pack.out"
tar -xzf "$tmp/$(tail -n 1 "$tmp/pack.out")" -C "$tmp"
checker="$tmp/package/scripts/check-function-manifest.mjs"

# A kept test-named file must stay accepted.
[ -f "$stage/core/scripts/tests/skill-script-refs.test.sh" ] || { echo 'kept test file missing from stage' >&2; exit 1; }

expect_fail() {
  local label=$1 rel=$2
  mkdir -p "$(dirname "$stage/$rel")"
  printf '#!/bin/sh\n' > "$stage/$rel"
  set +e
  bash "$check" "$stage" --checker "$checker" > "$tmp/out.log" 2>&1
  status=$?
  set -e
  rm -f "$stage/$rel"
  if [ "$status" -ne 1 ] || ! grep -Fq "$rel" "$tmp/out.log"; then
    echo "installed-core-check accepted $label: $rel (exit $status)" >&2
    cat "$tmp/out.log" >&2
    exit 1
  fi
}
expect_fail 'a leaked test file' core/scripts/leaked.test.sh
expect_fail 'a leaked tests folder file' core/workers/public/content-shared/tests/a.md
expect_fail 'leaked CI tooling' core/scripts/ci/leaked.sh
expect_fail 'a leaked release script' core/scripts/parse-release-tag.sh
# Unanchored rules the checker's built-in test names leave out.
expect_fail 'a leaked PowerShell test' core/hooks/leaked.test.ps1
expect_fail 'a leaked tsx spec' core/scripts/leaked.spec.tsx

# Invalid arguments are setup errors, never a pass.
set +e
bash "$check" "$tmp/missing" --checker "$checker" > /dev/null 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || { echo "missing tree exited $status, expected 2" >&2; exit 1; }

# A checker crash, a failed npm pack or a tarball that does not match the
# pinned integrity is a setup error, never a pass.
expect_setup_error() {
  local label=$1
  shift
  set +e
  "$@" > "$tmp/out.log" 2>&1
  status=$?
  set -e
  if [ "$status" -ne 2 ]; then
    echo "installed-core-check: $label exited $status, expected 2" >&2
    cat "$tmp/out.log" >&2
    exit 1
  fi
}
printf 'throw new Error("boom");\n' > "$tmp/crash.mjs"
expect_setup_error 'a crashing checker' bash "$check" "$stage" --checker "$tmp/crash.mjs"
printf 'process.exit(3);\n' > "$tmp/exit3.mjs"
expect_setup_error 'a checker exiting 3' bash "$check" "$stage" --checker "$tmp/exit3.mjs"
expect_setup_error 'a missing checker' bash "$check" "$stage" --checker "$tmp/none.mjs"
fake="$tmp/fake-npm"
mkdir -p "$fake"
printf '#!/bin/sh\nexit 1\n' > "$fake/npm"
chmod +x "$fake/npm"
expect_setup_error 'a failed npm pack' env PATH="$fake:$PATH" bash "$check" "$stage"
# A different tarball under the expected name: the integrity check refuses it.
mkdir -p "$tmp/other/package/scripts"
printf 'process.exit(0);\n' > "$tmp/other/package/scripts/check-function-manifest.mjs"
tar -czf "$tmp/other.tgz" -C "$tmp/other" package
cat > "$fake/npm" <<EOF_NPM
#!/bin/sh
while [ "\$#" -gt 0 ]; do
  [ "\$1" = --pack-destination ] && dest=\$2
  shift
done
cp "$tmp/other.tgz" "\$dest/indigoai-us-hq-cli-$version.tgz"
echo "indigoai-us-hq-cli-$version.tgz"
EOF_NPM
expect_setup_error 'a tarball that fails the integrity check' env PATH="$fake:$PATH" bash "$check" "$stage"
grep -Fq 'does not match' "$tmp/out.log" || { echo 'integrity failure not reported' >&2; cat "$tmp/out.log" >&2; exit 1; }

# release.yml runs the check on the tarball, before the release is created,
# and nothing lets a failure through.
release="$root/.github/workflows/release.yml"
step=$(awk '/- name: Installed-core check on the release tarball/{on=1} on&&/- name: Resolve release notes body/{exit} on' "$release")
# shellcheck disable=SC2016 # the literal workflow line
printf '%s\n' "$step" | grep -Fq 'bash .github/release/installed-core-check.sh "$CHECK_DIR/${NAME}"' \
  || { echo 'release.yml does not run installed-core-check.sh on the tarball' >&2; exit 1; }
if printf '%s\n' "$step" | grep -Eq 'continue-on-error|\|\| *true|^ *if:'; then
  echo 'release.yml lets an installed-core-check failure through' >&2
  exit 1
fi
check_line=$(grep -n 'name: Installed-core check on the release tarball' "$release" | cut -d: -f1)
create_line=$(grep -n 'name: Create GitHub release$' "$release" | cut -d: -f1)
tarball_line=$(grep -n 'name: Create tarball and checksum' "$release" | cut -d: -f1)
[ -n "$check_line" ] && [ -n "$create_line" ] && [ -n "$tarball_line" ] \
  && [ "$tarball_line" -lt "$check_line" ] && [ "$check_line" -lt "$create_line" ] \
  || { echo 'release.yml must run the check after the tarball and before the release' >&2; exit 1; }

echo 'installed-core-check regression: PASS'
