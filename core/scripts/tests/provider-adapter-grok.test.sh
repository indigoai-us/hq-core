#!/usr/bin/env bash
# hq-core: public
# provider-adapter-grok.test.sh — US-501/US-502 grok adapter (stub grok only).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$ROOT/core/scripts/lib"
ADAPTER_SH="$LIB/provider-adapter.sh"
PROBE="$ROOT/core/scripts/tests/probes/grok-capabilities.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# shellcheck disable=SC1090
. "$ADAPTER_SH"

if hq_adapter_load grok; then
  pass "hq_adapter_load grok exits 0"
else
  fail "hq_adapter_load grok failed"
fi

id="$(hq_adapter_id)"
if [[ "$id" == "grok" ]]; then
  pass "hq_adapter_id prints grok"
else
  fail "hq_adapter_id got '$id'"
fi

task="/tmp/t.txt"
preflight_wd='"${HQ_AGENT_COMPANY_DIR:?session preflight company missing}"'
off_wd="/home/ec2-user/hq"

on_cmd="$(hq_adapter_build_invocation "$task" "$preflight_wd" on)"
off_cmd="$(hq_adapter_build_invocation "$task" "$off_wd" off)"

_assert_grok_render() {
  local r="$1" label="$2" expected_wd="$3"
  local ok=1
  [[ "$r" == *"cd ${expected_wd}"* ]] || ok=0
  [[ "$r" == *'K="$(cat /home/ec2-user/.grok/key 2>/dev/null || true)"'* ]] || ok=0
  [[ "$r" == *'export XAI_API_KEY="$K"'* ]] || ok=0
  [[ "$r" == *"/home/ec2-user/.grok/bin/grok -p"* ]] || ok=0
  [[ "$r" == *"--yolo"* ]] || ok=0
  [[ "$r" == *"--no-auto-update"* ]] || ok=0
  [[ "$r" == *"$task"* ]] || ok=0
  if [[ "$ok" -eq 1 ]]; then
    pass "grok render ($label)"
  else
    fail "grok render ($label): $r"
  fi
}

_assert_grok_render "$on_cmd" "preflight-on" "$preflight_wd"
_assert_grok_render "$off_cmd" "preflight-off" "$off_wd"

# Prompt-by-file: no $(cat after grok -p; key-file $(cat retained
meta_task='/tmp/t-`$(evil).txt'
for mode_wd in "$preflight_wd" "$off_wd"; do
  r="$(hq_adapter_build_invocation "$meta_task" "$mode_wd" off)"
  after_p="${r#*grok -p }"
  if [[ "$r" == *"$meta_task"* ]] \
    && [[ "$after_p" != *'$(cat'* ]] \
    && [[ "$r" == *'K="$(cat /home/ec2-user/.grok/key 2>/dev/null || true)"'* ]]; then
    pass "prompt-by-file keeps key preamble, no task \$(cat)"
  else
    fail "prompt-by-file: $r"
  fi
done

# Subscription-mode regression: key ABSENT must still reach grok
mkdir -p "$TMP/bin"
cat > "$TMP/bin/grok-reached" <<'STUB'
#!/usr/bin/env bash
echo REACHED_GROK
exit 0
STUB
chmod +x "$TMP/bin/grok-reached"
# Rewrite full-path binary + key path to temp (key path intentionally missing)
snippet="$(hq_adapter_build_invocation "$task" "$TMP" off)"
snippet="${snippet//\/home\/ec2-user\/.grok\/bin\/grok/$TMP\/bin\/grok-reached}"
snippet="${snippet//\/home\/ec2-user\/.grok\/key/$TMP\/absent-key-on-purpose}"
# Drop the task-file argv requirement for reachability (stub ignores args)
set +e
out="$(bash -c "$snippet" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && [[ "$out" == *"REACHED_GROK"* ]]; then
  pass "subscription-mode: missing key still reaches grok"
else
  fail "subscription-mode short-circuit: rc=$rc out=$out snippet=$snippet"
fi

# capabilities: plan_mode=absent usage_source=unavailable
caps="$(hq_adapter_capabilities)"
plan="$(printf '%s\n' "$caps" | sed -n 's/^plan_mode=//p')"
usage="$(printf '%s\n' "$caps" | sed -n 's/^usage_source=//p')"
if [[ "$plan" == "absent" && "$usage" == "unavailable" ]]; then
  pass "plan_mode=absent usage_source=unavailable"
else
  fail "caps plan_mode=$plan usage_source=$usage"
fi

# extract_reply
known="final assistant message from grok"
got="$(printf '%s' "$known" | hq_adapter_extract_reply)"
if [[ "$got" == "$known" ]]; then
  pass "extract_reply returns final message"
else
  fail "extract_reply got '$got'"
fi
set +e
empty_out="$(printf '' | hq_adapter_extract_reply 2>/dev/null)"
empty_rc=$?
set -e
if [[ "$empty_rc" -eq 1 ]]; then
  pass "extract_reply empty exits 1"
else
  fail "extract_reply empty: rc=$empty_rc out='$empty_out'"
fi

# Probe exit 2 when neither PATH grok nor default path present
set +e
probe_err="$(PATH="/usr/bin:/bin" bash "$PROBE" 2>&1)"
probe_rc=$?
set -e
if [[ "$probe_rc" -eq 2 ]]; then
  pass "probe exits 2 without grok"
else
  # If /home/ec2-user/.grok/bin/grok happens to exist on this host, skip soft
  if [[ -x /home/ec2-user/.grok/bin/grok ]]; then
    pass "probe not skip (real grok path present on host)"
  else
    fail "probe without grok: rc=$probe_rc err=$probe_err"
  fi
fi

# Stub on PATH — full suite path for green CI
cat > "$TMP/bin/grok" <<'STUB'
#!/usr/bin/env bash
echo "stub-grok-output"
exit 0
STUB
chmod +x "$TMP/bin/grok"
export PATH="$TMP/bin:$PATH"

# ── output extraction: only the answer may reach the channel ────────────────
# Regression: in `plain` mode a multi-step run interleaves per-step narration
# with the answer on one stdout stream, and the session captures that stream
# verbatim as the reply — that is how a full transcript plus a literal
# NO_REPLY sentinel shipped into #hq-dev. The adapter now asks for the json
# envelope and emits ONLY `.text`; `.thought` must never appear.
# shellcheck disable=SC1091
. "$LIB/provider-adapter-grok.sh"
RUN="$TMP/run-extract"; CO="$TMP/co-extract"
mkdir -p "$RUN" "$CO"
printf 'sys\n' > "$RUN/system.txt"
printf 'usr\n' > "$RUN/user.txt"

cat > "$TMP/bin/grok" <<'STUBJSON'
#!/usr/bin/env bash
printf '%s\n' '{"text":"Deploy is live.","stopReason":"EndTurn","sessionId":"019f-abc","thought":"Fetching the thread.NO_REPLY"}'
STUBJSON
chmod +x "$TMP/bin/grok"
OUT="$(provider_adapter_grok "$RUN" "$CO" 2>/dev/null)"
[ "$OUT" = "Deploy is live." ] \
  && pass "json envelope: emits only .text" \
  || fail "json envelope: expected only .text, got [$OUT]"
case "$OUT" in
  *Fetching*|*NO_REPLY*) fail "reasoning/sentinel leaked into reply: [$OUT]" ;;
  *) pass "json envelope: .thought and NO_REPLY never reach stdout" ;;
esac
[ "$(cat "$RUN/provider.sessionId" 2>/dev/null)" = "019f-abc" ] \
  && pass "json envelope: sessionId captured for resume" \
  || fail "json envelope: sessionId not captured"

# Fail closed if the provider does not return the promised json envelope. Raw
# output can contain private reasoning or a NO_REPLY sentinel and must never
# become reply stdout.
cat > "$TMP/bin/grok" <<'STUBPLAIN'
#!/usr/bin/env bash
echo "private reasoning NO_REPLY"
STUBPLAIN
chmod +x "$TMP/bin/grok"
RC=0
set +e
OUT="$(provider_adapter_grok "$RUN" "$CO" 2>"$TMP/extract.err")"
RC=$?
set -e
[ "$RC" -ne 0 ] \
  && pass "non-json: adapter fails closed" \
  || fail "non-json: adapter returned success"
[ -z "$OUT" ] \
  && pass "non-json: no raw bytes reach reply stdout" \
  || fail "non-json: leaked raw output [$OUT]"
grep -q 'not a valid json envelope' "$TMP/extract.err" \
  && pass "non-json: failure is visible on stderr" \
  || fail "non-json: failed without a diagnostic"

# A syntactically valid object is still invalid unless .text is a string.
cat > "$TMP/bin/grok" <<'STUBBADTYPE'
#!/usr/bin/env bash
printf '%s\n' '{"text":{"private":"NO_REPLY"},"thought":"secret reasoning"}'
STUBBADTYPE
chmod +x "$TMP/bin/grok"
RC=0
set +e
OUT="$(provider_adapter_grok "$RUN" "$CO" 2>"$TMP/extract-type.err")"
RC=$?
set -e
[ "$RC" -ne 0 ] \
  && pass "non-string text: adapter fails closed" \
  || fail "non-string text: adapter returned success"
[ -z "$OUT" ] \
  && pass "non-string text: no envelope bytes reach reply stdout" \
  || fail "non-string text: leaked envelope output [$OUT]"

# Missing .text must not expose another field as a best-effort answer.
cat > "$TMP/bin/grok" <<'STUBMISSING'
#!/usr/bin/env bash
printf '%s\n' '{"thought":"secret reasoning NO_REPLY"}'
STUBMISSING
chmod +x "$TMP/bin/grok"
RC=0
set +e
OUT="$(provider_adapter_grok "$RUN" "$CO" 2>"$TMP/extract-missing.err")"
RC=$?
set -e
[ "$RC" -ne 0 ] && [ -z "$OUT" ] \
  && pass "missing text: adapter fails closed without reply stdout" \
  || fail "missing text: rc=$RC out=[$OUT]"

# json mode promises one envelope. Multiple documents are not a valid envelope
# even when every document happens to contain a string .text.
cat > "$TMP/bin/grok" <<'STUBMULTI'
#!/usr/bin/env bash
printf '%s\n' '{"text":"private intermediate"}' '{"text":"final answer"}'
STUBMULTI
chmod +x "$TMP/bin/grok"
RC=0
set +e
OUT="$(provider_adapter_grok "$RUN" "$CO" 2>"$TMP/extract-multi.err")"
RC=$?
set -e
[ "$RC" -ne 0 ] && [ -z "$OUT" ] \
  && pass "multiple documents: adapter fails closed without reply stdout" \
  || fail "multiple documents: rc=$RC out=[$OUT]"

# Provider failure must still surface as a non-zero return.
printf '#!/usr/bin/env bash\necho x\nexit 7\n' > "$TMP/bin/grok"
chmod +x "$TMP/bin/grok"
RC=0
OUT="$(provider_adapter_grok "$RUN" "$CO" 2>/dev/null)" || RC=$?
[ "$RC" -eq 7 ] \
  && pass "provider exit code propagates" \
  || fail "provider exit code swallowed (got $RC, want 7)"
[ -z "$OUT" ] \
  && pass "provider failure: invalid raw output stays off reply stdout" \
  || fail "provider failure: leaked raw output [$OUT]"

if [[ "$FAIL" -eq 0 ]]; then
  echo "provider-adapter-grok: all passed"
  exit 0
fi
echo "provider-adapter-grok: $FAIL failed" >&2
exit 1
