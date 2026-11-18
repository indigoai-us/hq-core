#!/usr/bin/env bash
# conduct-runner-default.test.sh — the shipped conduct.runner is `subagent`, and
# core/scripts/conduct-runner-resolve.sh applies the resolution order: --runner,
# the conduct_runner session pin, personal/settings/orchestrator.yaml,
# core/settings/orchestrator.yaml, then subagent. The legacy values `mixed` and
# `lane` are read as `runner` with one stderr warning line.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
eq() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }

RESOLVE="$ROOT/core/scripts/conduct-runner-resolve.sh"
[ -x "$RESOLVE" ] || fail 'core/scripts/conduct-runner-resolve.sh is missing or not executable'
head -n 2 "$RESOLVE" | grep >/dev/null '^# hq-core: public$' || fail 'resolver lacks the hq-core: public marker'

echo "shipped setting"
YAML="$ROOT/core/settings/orchestrator.yaml"
grep -Eq '^  runner: subagent$' "$YAML" || fail 'core/settings/orchestrator.yaml does not ship conduct.runner: subagent'
block="$(awk '/^conduct:/{on=1} on && /^[^ #]/ && !/^conduct:/{on=0} on' "$YAML")"
grep -q 'subagent (default)' <<<"$block" || fail 'runner comment does not document subagent as the default'
grep -qi 'resumable Agent' <<<"$block" || fail 'runner comment does not say lanes run on resumable Agent subagents'
grep -qi 'child desktop sessions' <<<"$block" || fail 'runner comment does not name child desktop sessions'
grep -qi 'zero runner' <<<"$block" || fail 'runner comment does not say the default writes zero runner records'
grep -q '/conduct-runners' <<<"$block" || fail 'runner comment does not route runner to /conduct-runners'
grep -qi 'admission' <<<"$block" || fail 'runner comment does not name admission'
grep -qi 'Outpost' <<<"$block" || fail 'runner comment does not name Outpost placement'
grep -qi 'non-Claude engines' <<<"$block" || fail 'runner comment does not name non-Claude engines'
grep -q '`mixed` and `lane` are read as `runner` for one release' <<<"$block" || fail 'runner comment lacks the legacy-value note'
grep -q 'read by hq runners session-start and by the five' <<<"$block" || fail 'runner comment does not name its readers'
grep -q 'execute-task' <<<"$block" || fail 'runner comment does not list the five skills'
if grep -q 'Enforced by hq-cli' "$YAML"; then fail 'orchestrator.yaml still says conduct is enforced by session-start'; fi
if grep -Eq '^  runner: (mixed|lane)$' "$YAML"; then fail 'orchestrator.yaml still ships a legacy runner'; fi

# A temp HQ root with only the resolver and the shipped settings.
mkdir -p "$T/core/scripts" "$T/core/settings" "$T/personal/settings"
cp "$RESOLVE" "$T/core/scripts/"
cp "$YAML" "$T/core/settings/"
unset HQ_ROOT CLAUDE_PROJECT_DIR
run() { sh "$T/core/scripts/conduct-runner-resolve.sh" --root "$T" "$@" 2>"$T/err"; }
nerr() { awk 'END{print NR}' "$T/err"; }

echo "no personal file: subagent"
eq "$(run)" subagent 'the release default resolves to subagent'
eq "$(nerr)" 0 'the default prints no warning'

echo "no settings at all: subagent"
mv "$T/core/settings/orchestrator.yaml" "$T/core-orchestrator.yaml"
eq "$(run)" subagent 'with no settings the built-in default is subagent'
mv "$T/core-orchestrator.yaml" "$T/core/settings/orchestrator.yaml"

echo "personal runner override wins"
printf 'conduct:\n  default_enabled: true\n  runner: runner\n' > "$T/personal/settings/orchestrator.yaml"
eq "$(run)" runner 'a personal runner override wins over the release default'
eq "$(nerr)" 0 'runner prints no warning'

echo "legacy personal values are read as runner with one warning line"
for legacy in mixed lane; do
  printf 'conduct:\n  runner: "%s"  # old value\n' "$legacy" > "$T/personal/settings/orchestrator.yaml"
  eq "$(run)" runner "personal $legacy is read as runner"
  eq "$(nerr)" 1 "personal $legacy prints exactly one stderr line"
  grep -q "\"$legacy\" from personal/settings/orchestrator.yaml is a legacy value" "$T/err" \
    || fail "the $legacy warning does not name the value and its source"
done

echo "a runner key outside the conduct block is ignored"
printf 'other:\n  runner: runner\nconduct:\n  default_enabled: true\n' > "$T/personal/settings/orchestrator.yaml"
eq "$(run)" subagent 'only conduct.runner is read'

echo "session pin beats personal, --runner beats both"
mkdir -p "$T/workspace"
cat > "$T/core/scripts/hq-session.sh" <<'FAKE'
#!/usr/bin/env bash
# Fake session helper: prints the pin stored in $T/pin.
[ "${*: -2}" = "get conduct_runner" ] || exit 1
cat "$(dirname "$0")/../../pin" 2>/dev/null || true
FAKE
printf 'conduct:\n  runner: runner\n' > "$T/personal/settings/orchestrator.yaml"
printf 'subagent\n' > "$T/pin"
eq "$(run --session-id s1)" subagent 'the session pin beats the personal setting'
printf 'lane\n' > "$T/pin"
eq "$(run --session-id s1)" runner 'a legacy session pin is read as runner'
eq "$(nerr)" 1 'a legacy session pin prints one warning line'
eq "$(run --session-id s1 --runner subagent)" subagent '--runner beats the session pin'
eq "$(run --runner mixed)" runner '--runner mixed is read as runner'
eq "$(nerr)" 1 '--runner mixed prints one warning line'
rm "$T/pin"
eq "$(run --session-id s1)" runner 'an empty pin falls through to the personal setting'

echo "unknown values exit 2"
set +e; run --runner pool >/dev/null; rc=$?; set -e
eq "$rc" 2 'an unknown --runner exits 2'
printf 'conduct:\n  runner: pool\n' > "$T/personal/settings/orchestrator.yaml"
set +e; run >/dev/null; rc=$?; set -e
eq "$rc" 2 'an unknown personal value exits 2'

echo "HQ_ROOT is honoured without --root"
rm "$T/personal/settings/orchestrator.yaml"
eq "$(HQ_ROOT="$T" sh "$T/core/scripts/conduct-runner-resolve.sh")" subagent 'HQ_ROOT locates the settings'

echo 'conduct-runner-default.test.sh: subagent default and resolution order passed'
