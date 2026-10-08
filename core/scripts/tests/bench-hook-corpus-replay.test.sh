#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/root"
mkdir -p "$FIXTURE/.claude/hooks" "$FIXTURE/core/scripts" "$FIXTURE/workspace"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

cat > "$FIXTURE/.claude/hooks/master-hook.sh" <<'HOOK'
#!/usr/bin/env bash
request="$(cat)"
event="$(jq -r '.hook_event_name' <<<"$request")"
sid="$(jq -r '.session_id' <<<"$request")"
cwd="$(jq -r '.cwd' <<<"$request")"
prompt="$(jq -r '.prompt // empty' <<<"$request")"
last="$HQ_ROOT/workspace/last-hook-request.json"
if [ -n "${HQ_FLAGS_API_URL:-}" ] && [ -n "${HQ_COMPANY_UID:-}" ] &&
  [ "${HQ_HOOK_DEDUPE:-1}" != 0 ] && [ -f "$last" ] && cmp -s "$last" <(printf '%s' "$request"); then exit 0; fi
printf '%s' "$request" > "$last"
printf '%s\t%s\t%s\t%s\t%s\n' "$event" "$sid" "$cwd" "$prompt" "${HQ_HOOK_DEDUPE:-1}" >> "$BENCH_REPLAY_CAPTURE"
if [ "$event" = SessionStart ]; then
  jq -n --arg ctx 'session warm-up context' '{hookSpecificOutput:{additionalContext:$ctx}}'
  exit 0
fi
marker="$HQ_ROOT/workspace/replay-markers/$prompt"
mkdir -p "$(dirname "$marker")"
if [ -e "$marker" ]; then
  context="cached $prompt"
else
  : > "$marker"
  context="first pass context for $prompt"
fi
jq -n --arg ctx "$context" '{hookSpecificOutput:{additionalContext:$ctx}}'
HOOK
chmod +x "$FIXTURE/.claude/hooks/master-hook.sh"
cat > "$TMP/corpus.json" <<'JSON'
{"version":1,"prompts":[{"id":"p1","prompt":"alpha"},{"id":"p2","prompt":"beta"}],"commands":[]}
JSON

BENCH_REPLAY_CAPTURE="$TMP/calls.tsv" HQ_FLAGS_API_URL="https://flags.example.invalid" \
  HQ_COMPANY_UID="co_fixture" HQ_ROOT="$FIXTURE" \
  bash "$ROOT/core/scripts/bench-hook-corpus.sh" replay \
    "$TMP/corpus.json" "$TMP/replay.json" p1 p2 > "$TMP/replay.out"

[ "$(wc -l < "$TMP/calls.tsv" | tr -d ' ')" = 5 ] || fail "replay did not warm the session and dispatch selected prompts twice"
awk -F '\t' 'NR == 1 { sid=$2; cwd=$3 } $2 != sid || $3 != cwd || $5 != 0 { exit 1 } END { if (NR != 5) exit 1 }' "$TMP/calls.tsv" \
  || fail "replay calls did not share one session id and workspace with dedupe disabled"
awk -F '\t' '
  NR == 1 && ($1 != "SessionStart" || $4 != "") { exit 1 }
  NR == 2 && ($1 != "UserPromptSubmit" || $4 != "alpha") { exit 1 }
  NR == 3 && ($1 != "UserPromptSubmit" || $4 != "beta") { exit 1 }
  NR == 4 && ($1 != "UserPromptSubmit" || $4 != "alpha") { exit 1 }
  NR == 5 && ($1 != "UserPromptSubmit" || $4 != "beta") { exit 1 }
  END { if (NR != 5) exit 1 }
' "$TMP/calls.tsv" \
  || fail "replay did not warm once and retain selected item order across both passes"
jq -e --arg workspace "$FIXTURE" '
  .session_id as $sid |
  .mode == "same-session-replay" and .workspace == $workspace and
  ($sid | length > 0) and (.items | length == 2) and
  all(.items[]; .session_id == $sid and .workspace == $workspace and
    .first_run.bytes > .repeat_run.bytes and
    (.first_run.wall_seconds | type == "number") and
    (.repeat_run.wall_seconds | type == "number") and
    .first_run.exit_code == 0 and .repeat_run.exit_code == 0)
' "$TMP/replay.json" >/dev/null || fail "report omitted per-event first and repeat measurements"
jq -e '.items[0].id == "p1" and .items[1].id == "p2" and
  .items[0].first_run.bytes == ("first pass context for alpha" | length) and
  .items[0].repeat_run.bytes == ("cached alpha" | length) and
  .items[1].first_run.bytes == ("first pass context for beta" | length) and
  .items[1].repeat_run.bytes == ("cached beta" | length) and
  .totals.first_run.bytes > .totals.repeat_run.bytes' "$TMP/replay.json" >/dev/null \
  || fail "report did not preserve the requested item set"
grep -Fq 'first bytes' "$TMP/replay.out" || fail "stdout omitted first-run measurements"
grep -Fq 'repeat bytes' "$TMP/replay.out" || fail "stdout omitted repeat-run measurements"
pass "same-session replay keeps the selected item set, session, and workspace and reports both measurements"

# Pin the legacy default-mode console output against the main golden.
DEFAULT_ROOT="$TMP/default-root"
FIXED_BIN="$TMP/fixed-bin"
mkdir -p "$DEFAULT_ROOT/.claude/hooks" "$DEFAULT_ROOT/workspace" "$FIXED_BIN"
cat > "$DEFAULT_ROOT/.claude/hooks/master-hook.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf 'stable context\n'
HOOK
chmod +x "$DEFAULT_ROOT/.claude/hooks/master-hook.sh"
printf '%s\n' '{"version":1,"prompts":[{"id":"p1","prompt":"stable prompt"}],"commands":[]}' > "$TMP/default-corpus.json"
cat > "$FIXED_BIN/perl" <<'PERL'
#!/usr/bin/env bash
if [ "${1:-}" = "-MTime::HiRes=time" ]; then printf '1000000\n'; else exec /usr/bin/perl "$@"; fi
PERL
chmod +x "$FIXED_BIN/perl"
PATH="$FIXED_BIN:$PATH" HQ_ROOT="$DEFAULT_ROOT" bash "$ROOT/core/scripts/bench-hook-corpus.sh" run \
  --corpus "$TMP/default-corpus.json" --out "$DEFAULT_ROOT/report.json" > "$TMP/default.out"
sed -E 's@report: .*@report: <report>@' "$TMP/default.out" > "$TMP/default.normalized.out"
cat > "$TMP/default.expected.out" <<'EXPECTED'
item                         event              secs   bytes  pol  hints hit/missed · unwanted
session-start                SessionStart       0.00      15    0  - / - · -
p1                           UserPromptSubmit   0.00      15    0  - / - · -

TOTAL secs 0  bytes 30  policy lines 0
report: <report>
EXPECTED
cmp "$TMP/default.expected.out" "$TMP/default.normalized.out" || fail "default run console output changed from its main golden"
pass "default run console output remains byte-identical to the main golden"
