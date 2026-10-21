#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="${1:-$ROOT/.claude/hooks/conduct-lanes-session-start.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cat > "$BIN/hq" <<'FAKE'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = --version ]; then
  printf '5.345.67\n'
  exit 0
fi
printf '%s\n' "$*" > "$FAKE_ARGS"
cat > "$FAKE_STDIN"
printf 'fixture conductor block\n'
FAKE
chmod +x "$BIN/hq"

export PATH="$BIN:/usr/bin:/bin"
export CLAUDE_PROJECT_DIR="$TMP/project"
export FAKE_ARGS="$TMP/args" FAKE_STDIN="$TMP/stdin"
payload='{"hookEventName":"SessionStart","session_id":"codex-session-1","model":"gpt-6.1-codex","reasoning_effort":"high"}'
printf '%s' "$payload" > "$TMP/payload"

"$HOOK" < "$TMP/payload" > "$TMP/out" 2> "$TMP/err"
grep -Fxq 'lanes session-start' "$FAKE_ARGS" || fail 'SessionStart did not invoke hq lanes session-start'
cmp -s "$TMP/payload" "$TMP/stdin" || fail 'full SessionStart payload, including model and reasoning_effort, did not reach hq'
grep -Fq '"model":"gpt-6.1-codex"' "$TMP/stdin" || fail 'Codex model was absent from the payload delivered to hq'
grep -Fq '"reasoning_effort":"high"' "$TMP/stdin" || fail 'Codex reasoning_effort was absent from the payload delivered to hq'
grep -Fxq 'fixture conductor block' "$TMP/out" || fail 'SessionStart hook output did not pass through'
[ ! -s "$TMP/err" ] || fail 'SessionStart hook emitted stderr'

for source in resume compact clear; do
  rm -f "$FAKE_ARGS" "$FAKE_STDIN"
  printf '{"hookEventName":"SessionStart","session_id":"s-%s","source":"%s"}' "$source" "$source" \
    | "$HOOK" > "$TMP/out" 2> "$TMP/err" || fail "source=$source hook exited non-zero"
  [ ! -e "$FAKE_ARGS" ] || fail "source=$source still started hq lanes session-start"
  [ ! -s "$TMP/out" ] || fail "source=$source produced output"
  [ ! -s "$TMP/err" ] || fail "source=$source emitted stderr"
done

rm -f "$FAKE_ARGS"
printf '%s' '{"session_id":"s-start","source":"startup"}' | "$HOOK" > "$TMP/out" 2> "$TMP/err"
grep -Fxq 'lanes session-start' "$FAKE_ARGS" || fail 'source=startup did not invoke hq lanes session-start'

rm -f "$FAKE_ARGS"
printf '%s' 'not json' | "$HOOK" > "$TMP/out" 2> "$TMP/err"
grep -Fxq 'lanes session-start' "$FAKE_ARGS" || fail 'malformed payload did not fall through to the CLI startup default'

rm -f "$FAKE_ARGS"
printf '%s' '{"session_id":"s-num","source":7}' | "$HOOK" > "$TMP/out" 2> "$TMP/err"
grep -Fxq 'lanes session-start' "$FAKE_ARGS" || fail 'non-string source did not fall through to the CLI'

printf 'conduct-session-start-payload: full Codex payload passed through; non-startup sources skip the CLI\n'
