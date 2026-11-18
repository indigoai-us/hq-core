#!/usr/bin/env bash
# hq-core: public
# Regression test: hq-checkup reads policy-retire's stderr instead of
# discarding it. A policy whose `when:` trigger is malformed is reported as
# needing the person (it can never load), a retire failure is reported, and a
# real retirement is still listed as worth knowing. Runs hq-checkup against a
# synthetic HQ root with a stubbed policy-retire and hq so nothing real runs.
set -euo pipefail
ROOT="${HQ_TEST_ROOT:-$(git rev-parse --show-toplevel)}"
CHECKUP="$ROOT/.claude/skills/hq-checkup/hq-checkup.sh"
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$FX/root/core/scripts/lib" "$FX/home" "$FX/bin"
cp "$ROOT/core/scripts/lib/hq-cli-floor.sh" "$FX/root/core/scripts/lib/"
# The stub hq replays the shape of `hq core policy retire --auto` for a
# scenario and records the arguments it was called with (US-043: hq-checkup
# calls hq core policy retire, not core/scripts/policy-retire.sh).
cat > "$FX/bin/hq" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && { echo "${STUB_HQ_VERSION:-9.9.9}"; exit 0; }
[ "${1:-}" = core ] && [ "${2:-}" = --hq-root ] && [ "${4:-}" = policy ] && [ "${5:-}" = retire ] || exit 1
[ "$3" = "$STUB_ROOT" ] || { echo "stub hq: wrong --hq-root $3" >&2; exit 64; }
shift 5
printf '%s\n' "$*" > "$STUB_ARGS"
case "$STUB_SCENARIO" in
  malformed)
    printf 'policy-retire: quoted-phrase (personal/policies/quoted.md) has a malformed when: trigger and was not retired; fix it: pull request\n' >&2
    printf 'policy-retire: two-words (personal/policies/two.md) has a malformed when: trigger and was not retired; fix it: git push\n' >&2
    echo 'policy-retire --auto: 0 retired, 0 failed, 2 need a fix; report workspace/reports/policy-retirement-2026-10-01.md'
    ;;
  failed)
    printf 'policy-retire: refusing to write personal/policies/bad.md; canonical policy validation failed:\nBLOCKED: missing trigger\n' >&2
    echo 'failed: bad (personal/policies/bad.md); policy was not retired' >&2
    echo 'policy-retire --auto: 0 retired, 1 failed, 0 need a fix; report workspace/reports/policy-retirement-2026-10-01.md'
    exit 1
    ;;
  retired)
    echo 'retired: old-one — never emitted in any session ledger over 400 days'
    echo 'policy-retire --auto: 1 retired, 0 failed, 0 need a fix; report workspace/reports/policy-retirement-2026-10-01.md'
    ;;
  clean)
    echo 'policy-retire --auto: nothing to retire'
    ;;
esac
EOF
chmod +x "$FX/bin/hq"

run_checkup() { # scenario mode-flag...
  local scenario="$1"; shift
  env -i PATH="$FX/bin:/usr/bin:/bin" HOME="$FX/home" TMPDIR="$FX" \
    CLAUDE_PROJECT_DIR="$FX/root" STUB_ROOT="$FX/root" STUB_SCENARIO="$scenario" STUB_ARGS="$FX/args" \
    STUB_HQ_VERSION="${STUB_HQ_VERSION:-9.9.9}" \
    bash "$CHECKUP" --quick --json "$@" 2>/dev/null || true
}

items() { # json status → headlines with that status, one per line
  python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
for item in data["items"]:
    if item["status"] == sys.argv[2]:
        print(item["headline"] + " | " + item["action"])
' "$1" "$2"
}

echo "[1] malformed triggers are reported as needing the person, not hidden"
run_checkup malformed > "$FX/out.json"
grep -qx -- '--auto' "$FX/args" || fail "fix mode should run policy-retire --auto, got: $(cat "$FX/args")"
items "$FX/out.json" YOU | grep -q '^2 policies have a broken trigger (when: line), so they never load | Run: bash core/scripts/lint-policy-triggers.sh' \
  || fail "malformed triggers not reported: $(cat "$FX/out.json")"
items "$FX/out.json" YOU | grep -q "Couldn't finish retiring" && fail "malformed triggers misreported as a retire failure"
items "$FX/out.json" INFO | grep -q 'Retired policies' && fail "nothing was retired but checkup said so"

echo "[2] --check runs a dry run and still reports malformed triggers"
run_checkup malformed --check > "$FX/out.json"
grep -qx -- '--auto --dry-run' "$FX/args" || fail "--check should dry-run, got: $(cat "$FX/args")"
items "$FX/out.json" YOU | grep -q '^2 policies have a broken trigger' || fail "--check hid malformed triggers"

echo "[3] a retire failure is reported with the first stderr line"
run_checkup failed > "$FX/out.json"
items "$FX/out.json" YOU | grep -q "^Couldn't finish retiring old policies: policy-retire: refusing to write personal/policies/bad.md" \
  || fail "retire failure hidden: $(cat "$FX/out.json")"

echo "[4] a real retirement is still listed as worth knowing"
run_checkup retired > "$FX/out.json"
items "$FX/out.json" INFO | grep -q '^Retired policies that aged out or point at things that no longer exist (1 retired, 0 failed, 0 need a fix' \
  || fail "retirement not listed: $(cat "$FX/out.json")"
items "$FX/out.json" YOU | grep -qi 'polic' && fail "clean retirement produced a needs-you item"

echo "[5] nothing to retire adds no policy items"
run_checkup clean > "$FX/out.json"
items "$FX/out.json" YOU | grep -qi 'polic' && fail "clean run produced a policy needs-you item"
items "$FX/out.json" INFO | grep -qi 'polic' && fail "clean run produced a policy info item"

echo "[6] an hq-cli below the 5.341.3 floor is reported, and policy retire does not run"
rm -f "$FX/args"
STUB_HQ_VERSION=5.341.2 run_checkup retired > "$FX/out.json"
[ ! -e "$FX/args" ] || fail "policy retire ran on an hq-cli below its floor"
items "$FX/out.json" YOU | grep -q "^Couldn't finish retiring old policies: policy-retire.sh: this script needs hq-cli >= 5.341.3 (found 5.341.2)" \
  || fail "old hq-cli not reported: $(cat "$FX/out.json")"

echo "PASS: hq-checkup reports malformed policy triggers and retire failures"
