#!/usr/bin/env bash
# Regression: a stable hq-core release PR must open on hold and never have
# GitHub auto-merge armed (owner decision 2026-10-21, feedback
# 2f573b2f-e948-4416-b23d-d21b501e6c02). Prerelease and fix PRs keep auto-merge.
# All GitHub data is synthetic; the gh stub never reaches GitHub.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
SCRIPT="$ROOT/core/scripts/release-pr-auto-merge.sh"
WF="$ROOT/.github/workflows/promote-to-hq-core.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$*"; }

[ -x "$SCRIPT" ] || fail "release-pr-auto-merge.sh is missing"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_STUB_LOG"
case "$*" in
  'pr view 7 '*) printf '{"labels":%s,"autoMergeRequest":%s}\n' "$GH_LABELS" "$GH_AUTO" ;;
  'pr edit 7 '*'--add-label hold-release'*) : ;;
  'pr merge 7 '*) : ;;
  *) printf 'unexpected gh invocation: %s\n' "$*" >&2; exit 90 ;;
esac
GH
chmod +x "$TMP/bin/gh"

REPO='indigoai-us/hq-core'
SHA='0123456789012345678901234567890123456789'
run() { # <labels-json> <auto-json> <args...>
  local labels="$1" auto="$2"; shift 2
  : > "$TMP/log"
  PATH="$TMP/bin:$PATH" GH_STUB_LOG="$TMP/log" GH_LABELS="$labels" GH_AUTO="$auto" \
    bash "$SCRIPT" "$@" > "$TMP/out" 2>&1 || fail "script failed for $*: $(cat "$TMP/out")"
}
armed_called() { grep -Eq '^pr merge 7 .*--auto( |$)' "$TMP/log"; }

# 1. Classification.
bash "$SCRIPT" is-stable release 15.0.5 || fail "15.0.5 release should be stable"
for v in 15.0.5-alpha.1 15.0.5-beta.2 15.0.5-rc.1; do
  ! bash "$SCRIPT" is-stable release "$v" || fail "$v should not be stable"
done
! bash "$SCRIPT" is-stable fix 15.0.5 || fail "fix PRs are not stable releases"
ok "stable vs prerelease/fix classification"

# 2. Stable release, freshly opened: label applied, auto-merge never armed.
run '[]' 'null' apply "$REPO" 7 release 15.0.5 "$SHA"
armed_called && fail "auto-merge was armed for a stable release"
grep -q -- '--add-label hold-release' "$TMP/log" || fail "stable release not labelled hold-release"
grep -q 'owner go' "$TMP/out" || fail "stable hold notice missing owner-go text"
ok "stable apply holds and does not arm"

# 3. Stable release that is somehow armed: disarmed, not re-armed.
run '[]' '{"mergeMethod":"SQUASH"}' apply "$REPO" 7 release 15.0.5 "$SHA"
armed_called && fail "auto-merge was armed for an armed stable release"
grep -q -- '--disable-auto' "$TMP/log" || fail "armed stable release not disarmed"
ok "stable apply disarms existing auto-merge"

# 4. Stable release whose owner removed the hold, then a new push: re-held.
run '[]' '{"mergeMethod":"SQUASH"}' prepare "$REPO" 7 release 15.0.5
grep -q -- '--add-label hold-release' "$TMP/log" || fail "stable release not re-held before update"
grep -q -- '--disable-auto' "$TMP/log" || fail "stable release not disarmed before update"
ok "stable prepare re-holds before a new head"

# 5. Prerelease and fix PRs keep auto-merge (unchanged behavior).
for v in 15.0.5-alpha.1 15.0.5-beta.1 15.0.5-rc.1; do
  run '[]' 'null' apply "$REPO" 7 release "$v" "$SHA"
  armed_called || fail "auto-merge not armed for prerelease $v"
  grep -q -- '--add-label' "$TMP/log" && fail "prerelease $v was labelled"
done
run '[]' 'null' apply "$REPO" 7 fix 15.0.5 "$SHA"
armed_called || fail "auto-merge not armed for fix PR"
ok "prerelease and fix PRs still arm auto-merge"

# 6. A person-held prerelease is not armed.
run '[{"name":"hold-release"}]' 'null' apply "$REPO" 7 release 15.0.5-rc.1 "$SHA"
armed_called && fail "held prerelease was armed"
ok "held prerelease not armed"

# 7. Workflow contract: no inline arm; script used at both sites; owner-go body.
if grep -Eq 'gh pr merge [^#]*--auto( |$)' "$WF"; then
  fail "promote-to-hq-core.yml arms auto-merge inline; route it through release-pr-auto-merge.sh"
fi
grep -q 'release-pr-auto-merge.sh apply ' "$WF" || fail "workflow does not call the script after opening the PR"
grep -q 'release-pr-auto-merge.sh prepare ' "$WF" || fail "workflow does not call the script before updating the PR"
grep -q 'owner go required' "$WF" || fail "workflow PR body lacks owner-go-required text"
script_re="$(grep -Eo '\^\[0-9\]\+\\\.\[0-9\]\+\\\.\[0-9\]\+\$' "$SCRIPT" | head -1)"
[ -n "$script_re" ] || fail "could not read the stable regex from the script"
grep -Fq "$script_re" "$WF" || fail "workflow stable regex differs from the script's"
ok "workflow routes auto-merge through the stable-release hold"

# 8. Create-time hold: the params step appends hold-release to LABELS for
# stable releases, so `gh pr create` opens the PR already held even if a later
# step (head-wait, apply) fails before release-pr-auto-merge.sh runs.
params="$(awk '/^      - name: Resolve parameters [(]auto vs manual[)]/{f=1} f&&/^      - name: /&&!/Resolve parameters [(]auto vs manual[)]/{exit} f' "$WF")"
[ -n "$params" ] || fail "could not find the params step in the workflow"
grep -Fq 'LABELS="${LABELS},hold-release"' <<< "$params" \
  || fail "params step does not add hold-release to LABELS for stable releases"
grep -Fq 'echo "stable=${STABLE}"' <<< "$params" \
  || fail "params step does not output stable from the same STABLE decision"
grep -Fq "$script_re" <<< "$params" || fail "params stable regex differs from the script's"
# Run the params label logic with synthetic inputs.
label_logic="$(awk '/STABLE="false"/{f=1} f{print} f&&/^          fi$/{exit}' <<< "$params")"
for c in 'release 1.2.3 yes' 'release 1.2.3-rc.1 no' 'fix 1.2.3 no'; do
  read -r t v want <<< "$c"
  got="$(PR_TYPE="$t" VERSION="$v" LABELS="version-bump" bash -c "set -euo pipefail; $label_logic"' ; printf "%s" "$LABELS"')"
  case "$want:$got" in
    yes:*hold-release*|no:version-bump) : ;;
    *) fail "create-time labels for $t $v: got '$got'" ;;
  esac
done
ok "stable release PRs are created with hold-release"

printf 'release-pr-auto-merge: %d checks passed\n' "$pass"
