#!/usr/bin/env bash
# hq-agent-session reply contract (dispatch-path parity).
#
# The hq-pro DIRECT path prompts for {"action":"reply","text":…} and validates
# it fail-closed. The hq-session path used to set disposition=reply and ship the
# provider's ENTIRE stdout, so a provider that narrated while working posted
# that narration into the channel (observed live 2026-07-26).
#
# These tests pin the contract for an enforced provider, and pin byte-identical
# legacy behaviour for a provider that is NOT under enforcement.
set -u

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
LIB_SH="$SCRIPT_DIR/../lib/session-reply-contract.sh"
[ -f "$LIB_SH" ] || { echo "FAIL: cannot find session-reply-contract.sh"; exit 1; }

FAILED=0
pass() { printf '  ok  — %s\n' "$1"; }
fail() { printf '  FAIL — %s\n' "$1"; FAILED=1; }

# The helpers live in their own lib precisely so they can be sourced without
# executing the session entrypoint.
load_helpers() {
  # shellcheck disable=SC1090
  . "$LIB_SH"
}

# ── session_reply_contract_required ─────────────────────────────────────────
(
  load_helpers
  if session_reply_contract_required grok; then pass "grok is enforced by default"; else fail "grok should be enforced by default"; fi
  if session_reply_contract_required codex; then fail "codex must NOT be enforced (would break every codex agent)"; else pass "codex is not enforced"; fi
  if session_reply_contract_required claude; then fail "claude must NOT be enforced"; else pass "claude is not enforced"; fi
  HQ_AGENT_SESSION_REPLY_CONTRACT_PROVIDERS="" \
    session_reply_contract_required grok && fail "empty override should disable enforcement" || pass "empty override disables enforcement"
  exit "$FAILED"
) || FAILED=1

# ── session_reply_contract_apply ────────────────────────────────────────────
(
  load_helpers

  SESSION_DISPOSITION=""; SESSION_TEXT=""
  if session_reply_contract_apply '{"action":"reply","text":"all set"}' \
     && [ "$SESSION_DISPOSITION" = "reply" ] && [ "$SESSION_TEXT" = "all set" ]; then
    pass "valid reply envelope maps to disposition=reply + text"
  else
    fail "valid reply envelope rejected (disp=$SESSION_DISPOSITION text=$SESSION_TEXT)"
  fi

  SESSION_DISPOSITION=""; SESSION_TEXT="stale"
  if session_reply_contract_apply '{"action":"no_reply"}' \
     && [ "$SESSION_DISPOSITION" = "no_reply" ] && [ -z "$SESSION_TEXT" ]; then
    pass "no_reply envelope maps to disposition=no_reply + empty text"
  else
    fail "no_reply envelope mishandled (disp=$SESSION_DISPOSITION text=$SESSION_TEXT)"
  fi

  # THE REGRESSION: the exact shape that leaked into Slack — narration, no envelope.
  narration="I'll build a Monday kickoff report, then deploy it. Gathering sources now.There's already a Monday-focus folder — I'll check it."
  if session_reply_contract_apply "$narration"; then
    fail "REGRESSION: raw narration accepted as a reply"
  else
    pass "raw narration is rejected (the 2026-07-26 leak)"
  fi

  for bad in \
    '' \
    '   ' \
    'not json at all' \
    '{"action":"reply"}' \
    '{"action":"reply","text":""}' \
    '{"action":"reply","text":"   "}' \
    '{"action":"reply","text":"NO_REPLY"}' \
    '{"action":"reply","text":123}' \
    '{"action":"no_reply","text":"but also this"}' \
    '{"action":"bogus","text":"hi"}' \
    '{"action":"reply","text":"hi","extra":1}' ; do
    if session_reply_contract_apply "$bad"; then
      fail "accepted invalid payload: $(printf '%s' "$bad" | head -c 60)"
    fi
  done
  pass "all malformed payloads rejected"

  # OBSERVED LIVE 2026-07-26 on Izzy's box: grok narrates one line, THEN emits a
  # correct envelope. Strict-only parsing threw away a CORRECT answer and the
  # agent went silent -- a different failure, not a fix.
  SESSION_DISPOSITION=""; SESSION_TEXT=""
  live='I'"'"'ll check the box date and confirm the active company, then reply in one short sentence.{"action":"reply","text":"Today is 2026-07-26, and I am operating for Indigo."}'
  if session_reply_contract_apply "$live" \
     && [ "$SESSION_DISPOSITION" = "reply" ] \
     && [ "$SESSION_TEXT" = "Today is 2026-07-26, and I am operating for Indigo." ]; then
    pass "narration-then-envelope recovers the answer and drops the narration"
  else
    fail "narration-then-envelope mishandled (disp=$SESSION_DISPOSITION text=$SESSION_TEXT)"
  fi

  # The recovered text must be ONLY the envelope's text -- never the prefix.
  case "$SESSION_TEXT" in
    *"check the box date"*) fail "narration leaked into the recovered reply text" ;;
    *) pass "narration prefix is not present in the recovered text" ;;
  esac

  # Whitespace variant of the envelope opener.
  SESSION_DISPOSITION=""; SESSION_TEXT=""
  if session_reply_contract_apply 'working...{ "action":"reply","text":"done" }' \
     && [ "$SESSION_TEXT" = "done" ]; then
    pass "spaced envelope opener is recovered"
  else
    fail "spaced envelope opener not recovered (text=$SESSION_TEXT)"
  fi

  # Last envelope wins when the model emits a draft then a final.
  SESSION_DISPOSITION=""; SESSION_TEXT=""
  if session_reply_contract_apply 'draft {"action":"reply","text":"first"} final {"action":"reply","text":"second"}' \
     && [ "$SESSION_TEXT" = "second" ]; then
    pass "last envelope wins over an earlier draft"
  else
    fail "expected the LAST envelope, got: $SESSION_TEXT"
  fi

  # Narration with NO envelope anywhere still fails closed (the original leak).
  if session_reply_contract_apply 'I will do the thing. Now doing it. Done.'; then
    fail "narration with no envelope was accepted"
  else
    pass "narration with no envelope still fails closed"
  fi

  # ── narration AFTER the envelope ──────────────────────────────────────────
  #
  # OBSERVED LIVE 2026-07-28 on Izzy's box (Corey's report: "all of the
  # reasoning output is coming throuhg"): grok narrates, emits a correct
  # envelope, then KEEPS narrating. Slicing from the last opener to
  # end-of-string made the candidate unparseable, apply() returned 1, and the
  # #437 degrade posted the model's entire working narration into a channel
  # with external members. Balanced extraction must recover the envelope and
  # drop BOTH sides of the narration. Fixture abridged from the live run
  # (run-20260727T164919Z-636ed2bb).
  SESSION_DISPOSITION=""; SESSION_TEXT=""
  live_after='I'"'"'ll dig into why the earlier failure happened. I have the root cause confirmed. Writing a short durable note, then posting the update.{"action":"reply","text":"*Update - root cause found.* Delivery died after Grok returned."}Now I need to emit the final reply JSON only. Keep it conversational, outcome first, Slack mrkdwn.'
  if session_reply_contract_apply "$live_after" \
     && [ "$SESSION_DISPOSITION" = "reply" ] \
     && [ "$SESSION_TEXT" = "*Update - root cause found.* Delivery died after Grok returned." ]; then
    pass "narration-envelope-narration recovers the answer (the 2026-07-28 leak)"
  else
    fail "trailing narration broke recovery (disp=$SESSION_DISPOSITION text=$SESSION_TEXT)"
  fi
  case "$SESSION_TEXT" in
    *"root cause confirmed"*|*"emit the final reply JSON"*)
      fail "narration leaked into the recovered text" ;;
    *) pass "neither leading nor trailing narration survives into the text" ;;
  esac

  # no_reply with trailing narration must still suppress the reply.
  SESSION_DISPOSITION=""; SESSION_TEXT="stale"
  if session_reply_contract_apply 'Checking whether this needs me...{"action":"no_reply"}It was addressed to someone else, so I stayed quiet.' \
     && [ "$SESSION_DISPOSITION" = "no_reply" ] && [ -z "$SESSION_TEXT" ]; then
    pass "no_reply with trailing narration still suppresses"
  else
    fail "no_reply with trailing narration mishandled (disp=$SESSION_DISPOSITION)"
  fi

  # Pretty-printed envelope with trailing prose — balancing is jq's job, so
  # newlines between tokens must not defeat recovery.
  SESSION_DISPOSITION=""; SESSION_TEXT=""
  pretty='thinking...{ "action": "reply",
  "text": "pretty but valid" }
and then some afterthought'
  if session_reply_contract_apply "$pretty" && [ "$SESSION_TEXT" = "pretty but valid" ]; then
    pass "pretty-printed envelope with trailing prose is recovered"
  else
    fail "pretty-printed envelope with trailing prose not recovered (text=$SESSION_TEXT)"
  fi

  # Envelope followed by a DIFFERENT json value: the balanced first value at
  # the last opener is the envelope; the stray value is trailing garbage.
  SESSION_DISPOSITION=""; SESSION_TEXT=""
  if session_reply_contract_apply '{"action":"reply","text":"real"}{"note":"scratch"}' \
     && [ "$SESSION_TEXT" = "real" ]; then
    pass "trailing non-envelope json value is dropped"
  else
    fail "trailing json value defeated recovery (text=$SESSION_TEXT)"
  fi

  # DELIBERATE BEHAVIOUR CHANGE, mirroring #435's must-reject relocations: a
  # code-fenced envelope was previously rejected (the trailing fence made the
  # slice unparseable) and therefore leaked RAW into the channel via the #437
  # degrade. Balanced extraction now recovers it — strictly better than
  # posting the fenced block verbatim. Safety is unchanged: the extracted
  # object still passes the same fail-closed validation.
  SESSION_DISPOSITION=""; SESSION_TEXT=""
  fenced='```json
{"action":"reply","text":"fenced"}
```'
  if session_reply_contract_apply "$fenced" && [ "$SESSION_TEXT" = "fenced" ]; then
    pass "code-fenced envelope is recovered (moved out of must-reject)"
  else
    fail "code-fenced envelope not recovered (text=$SESSION_TEXT)"
  fi

  # An opener inside prose with NO completable object anywhere still fails
  # closed — balanced extraction must not conjure a candidate.
  if session_reply_contract_apply 'I would normally send {"action":"reply","text":"like this but I never finished'; then
    fail "unbalanced opener in prose was accepted"
  else
    pass "unbalanced opener with no valid envelope still fails closed"
  fi

  # A reply whose text merely CONTAINS the sentinel is still a real reply.
  SESSION_DISPOSITION=""; SESSION_TEXT=""
  if session_reply_contract_apply '{"action":"reply","text":"I printed NO_REPLY earlier by mistake"}' \
     && [ "$SESSION_DISPOSITION" = "reply" ]; then
    pass "text containing NO_REPLY (not bare) is still a reply"
  else
    fail "text containing NO_REPLY was wrongly suppressed"
  fi
  exit "$FAILED"
) || FAILED=1

# ── session_append_reply_contract ───────────────────────────────────────────
(
  load_helpers
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

  : > "$TMP/sys-grok.txt"
  session_append_reply_contract grok "$TMP/sys-grok.txt"
  if grep -Fq '<!-- hq-section: reply-contract -->' "$TMP/sys-grok.txt" \
     && grep -Fq '{"action":"reply","text":"<the message to send>"}' "$TMP/sys-grok.txt"; then
    pass "enforced provider gets the reply-contract section"
  else
    fail "enforced provider missing the reply-contract section"
  fi
  if grep -Fqi 'narration' "$TMP/sys-grok.txt"; then
    pass "contract explicitly forbids narration in text"
  else
    fail "contract does not mention narration"
  fi

  : > "$TMP/sys-codex.txt"
  session_append_reply_contract codex "$TMP/sys-codex.txt"
  if [ -s "$TMP/sys-codex.txt" ]; then
    fail "non-enforced provider's system.txt was modified (must stay byte-identical)"
  else
    pass "non-enforced provider's system.txt is untouched"
  fi
  exit "$FAILED"
) || FAILED=1

# ── a missing envelope DEGRADES, it must never go silent ────────────────────
# Measured live: grok emits the envelope on ~3 runs in 5 and answers in prose on
# the rest. Suppressing those turned real answers into silence, and a turn that
# delivers nothing does not retire its inbound message -- so the agent loops on
# it (hq-pro#1589). The contract must be an improvement when honoured and a
# no-op when not.
(
  SESSION_SH="$SCRIPT_DIR/../hq-agent-session.sh"
  if grep -q 'SESSION_DISPOSITION="no_reply"' "$SESSION_SH" \
     && grep -q 'reply suppressed' "$SESSION_SH"; then
    fail "missing envelope still suppresses; a silent turn loops (hq-pro#1589)"
  else
    pass "missing envelope does not suppress"
  fi
  if grep -q 'falling back to raw provider output' "$SESSION_SH"; then
    pass "missing envelope falls back to the provider output and logs the fallback"
  else
    fail "missing envelope should fall back to raw provider output"
  fi
  # The fallback branch must set a REPLY, not an empty body.
  if grep -A3 'falling back to raw provider output' "$SESSION_SH" | grep -q 'SESSION_DISPOSITION="reply"'; then
    pass "fallback sets disposition=reply"
  else
    fail "fallback must set disposition=reply"
  fi
  exit "$FAILED"
) || FAILED=1

# ── degrade-path reformat salvage (grok only) ───────────────────────────────
# On the DEGRADE path a contract-gated provider is asked ONCE to reformat its
# own raw output into a clean envelope, BEFORE the raw fallback. Observed live
# (Telegram, 2026-08): grok glued a planning preamble to the answer
# ("I'll match the voice profile...Done — archived 5...") and the raw fallback
# shipped both. The reformat strips the preamble; on any failure it falls
# through to the exact raw behaviour, so an answer is never lost or truncated.
(
  load_helpers
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  RD="$TMP/run"; CO="$TMP/company"; mkdir -p "$RD" "$CO"
  DISPATCH_CALLS="$TMP/dispatch.calls"; : > "$DISPATCH_CALLS"
  STUB_MODE="reply"

  # Stub the provider dispatch + reader the reformat depends on. The real
  # session_provider_dispatch shells out to the grok CLI; here it is a
  # controllable seam so the salvage logic is exercised offline. It writes to
  # its own stdout, which session_reply_contract_reformat redirects into
  # $rdir/provider.stdout exactly as the live path does.
  session_provider_dispatch() {
    printf 'x' >> "$DISPATCH_CALLS"
    case "$STUB_MODE" in
      reply)   printf '%s' '{"action":"reply","text":"Done — archived 5 threads."}' ;;
      noreply) printf '%s' '{"action":"no_reply"}' ;;
      prose)   printf '%s' 'still just narrating; no envelope anywhere here' ;;
      empty)   : ;;
      fail)    return 3 ;;
    esac
    return 0
  }
  session_read_provider_out() { cat "$1/provider.stdout" 2>/dev/null || true; }
  dispatch_count() { wc -c < "$DISPATCH_CALLS" | tr -d ' '; }

  raw_leak="I'll match the voice profile, then write the follow-up from the triage results only.Done — archived 5 threads."

  # (a) grok degrade with a planning-preamble prose → reformat recovers clean answer.
  STUB_MODE="reply"; : > "$DISPATCH_CALLS"
  SESSION_DISPOSITION=""; SESSION_TEXT=""
  if session_reply_contract_reformat grok "$RD" "$CO" "$raw_leak" \
     && [ "$SESSION_DISPOSITION" = "reply" ] \
     && [ "$SESSION_TEXT" = "Done — archived 5 threads." ]; then
    pass "grok degrade: reformat recovers the clean answer, drops the preamble"
  else
    fail "grok degrade reformat did not recover (disp=$SESSION_DISPOSITION text=$SESSION_TEXT)"
  fi
  case "$SESSION_TEXT" in
    *"voice profile"*|*"triage results"*) fail "planning preamble leaked into the reformatted text" ;;
    *) pass "planning preamble is absent from the reformatted text" ;;
  esac
  [ "$(dispatch_count)" = "1" ] \
    && pass "reformat issues exactly ONE extra provider call" \
    || fail "reformat should issue exactly one call, made $(dispatch_count)"

  # reformat may legitimately conclude there is no answer to send.
  STUB_MODE="noreply"; : > "$DISPATCH_CALLS"
  SESSION_DISPOSITION=""; SESSION_TEXT="stale"
  if session_reply_contract_reformat grok "$RD" "$CO" "just planning out loud, never answered" \
     && [ "$SESSION_DISPOSITION" = "no_reply" ] && [ -z "$SESSION_TEXT" ]; then
    pass "grok degrade: reformat may resolve to no_reply when there is no answer"
  else
    fail "reformat no_reply mishandled (disp=$SESSION_DISPOSITION text=$SESSION_TEXT)"
  fi

  # (b) grok degrade where the reformat ALSO fails → returns 1, SESSION_* untouched,
  #     so the caller falls back to raw (unchanged behaviour).
  for mode in prose empty fail; do
    STUB_MODE="$mode"; : > "$DISPATCH_CALLS"
    SESSION_DISPOSITION="SENTINEL"; SESSION_TEXT="SENTINEL"
    if session_reply_contract_reformat grok "$RD" "$CO" "$raw_leak"; then
      fail "reformat ($mode) should fail closed, not report success"
    elif [ "$SESSION_DISPOSITION" = "SENTINEL" ] && [ "$SESSION_TEXT" = "SENTINEL" ]; then
      pass "reformat ($mode) fails closed and leaves SESSION_* untouched for raw fallback"
    else
      fail "reformat ($mode) mutated SESSION_* on failure (disp=$SESSION_DISPOSITION text=$SESSION_TEXT)"
    fi
  done

  # (c) compliant grok turn is structural: reformat is nested INSIDE the
  #     apply-failure branch, so a first-try envelope never reaches it → no
  #     extra call on the happy path.
  SESSION_SH="$SCRIPT_DIR/../hq-agent-session.sh"
  if awk '/if ! session_reply_contract_apply/{a=1} a && /session_reply_contract_reformat "\$provider"/{print; found=1} END{exit !found}' "$SESSION_SH" >/dev/null; then
    pass "reformat call is nested inside the apply-failure branch (no extra call when compliant)"
  else
    fail "reformat must be gated behind the apply failure, or compliant turns pay for a call"
  fi

  # (d) non-grok (not contract-gated) → reformat is a no-op: no call, no mutation.
  STUB_MODE="reply"; : > "$DISPATCH_CALLS"
  SESSION_DISPOSITION="SENTINEL"; SESSION_TEXT="SENTINEL"
  if session_reply_contract_reformat codex "$RD" "$CO" "$raw_leak"; then
    fail "reformat ran for a non-gated provider (codex)"
  elif [ "$(dispatch_count)" = "0" ] \
       && [ "$SESSION_DISPOSITION" = "SENTINEL" ] && [ "$SESSION_TEXT" = "SENTINEL" ]; then
    pass "non-gated provider: reformat is a no-op (no call, no mutation)"
  else
    fail "non-gated reformat should not call or mutate (calls=$(dispatch_count))"
  fi

  # render-only (fixture/CI) must never trigger a live provider call.
  STUB_MODE="reply"; : > "$DISPATCH_CALLS"
  if HQ_AGENT_SESSION_RENDER_ONLY=1 session_reply_contract_reformat grok "$RD" "$CO" "$raw_leak"; then
    fail "reformat ran under render-only mode"
  elif [ "$(dispatch_count)" = "0" ]; then
    pass "render-only mode makes reformat a no-op (no provider call)"
  else
    fail "render-only reformat issued a call (calls=$(dispatch_count))"
  fi

  # empty raw output → nothing to salvage, no call.
  STUB_MODE="reply"; : > "$DISPATCH_CALLS"
  if session_reply_contract_reformat grok "$RD" "$CO" "   "; then
    fail "reformat ran on blank raw input"
  elif [ "$(dispatch_count)" = "0" ]; then
    pass "blank raw input: reformat is a no-op"
  else
    fail "blank-raw reformat issued a call"
  fi
  exit "$FAILED"
) || FAILED=1

# The entrypoint must attempt the reformat BEFORE the raw fallback, and log a
# recovery breadcrumb, so live compliance/recovery is measurable.
(
  SESSION_SH="$SCRIPT_DIR/../hq-agent-session.sh"
  if grep -q 'session_reply_contract_reformat "\$provider" "\$run_dir" "\$company_dir"' "$SESSION_SH"; then
    pass "entrypoint attempts the reformat re-ask on the degrade path"
  else
    fail "entrypoint does not call the reformat salvage"
  fi
  if grep -q 'reply_contract_reformat_recovered' "$SESSION_SH"; then
    pass "entrypoint logs the reply_contract_reformat_recovered breadcrumb"
  else
    fail "entrypoint should log a recovery breadcrumb"
  fi
  # The reformat must be tried BEFORE the raw fallback, or salvage never runs.
  if awk '/session_reply_contract_reformat "\$provider"/{r=NR} /falling back to raw provider output/{f=NR} END{exit !(r>0 && f>0 && r<f)}' "$SESSION_SH"; then
    pass "reformat is attempted before the raw fallback"
  else
    fail "reformat must precede the raw fallback"
  fi
) || FAILED=1

# ── mention posture ─────────────────────────────────────────────────────────
# "only reply when I @ me" is unfollowable unless the model is told whether THIS
# turn satisfies it. Observed live 2026-07-26: operator told the agent to stand
# down unless @-mentioned, then @-mentioned it and got silence.
(
  load_helpers
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

  : > "$TMP/m1.txt"; session_append_mention_posture true "$TMP/m1.txt" slack true 'agt_test#slack:C1:T1'
  if grep -Fq '<!-- hq-section: mention-posture -->' "$TMP/m1.txt" \
     && grep -Fqi 'DIRECTLY @-mentioned you' "$TMP/m1.txt" \
     && grep -Fqi 'condition is MET' "$TMP/m1.txt"; then
    pass "direct mention tells the model the stand-down condition is met"
  else
    fail "direct-mention posture missing or does not release a stand-down"
  fi

  : > "$TMP/m2.txt"; session_append_mention_posture false "$TMP/m2.txt" slack true 'agt_test#slack:C1:T1'
  if grep -Fqi 'did NOT @-mention you' "$TMP/m2.txt" \
     && grep -Fqi 'stay silent' "$TMP/m2.txt"; then
    pass "unmentioned followed Slack turn keeps a stand-down in force"
  else
    fail "unmentioned followed Slack posture wrong"
  fi

  # A direct message is inherently addressed. Slack does not require users to
  # mention the recipient inside an already-private conversation, so the
  # producer legitimately sends directMention=false for this case.
  : > "$TMP/dm.txt"; session_append_mention_posture false "$TMP/dm.txt" slack true 'agt_test#slack:D1:T1'
  if grep -Fqi 'verified direct message addressed to you' "$TMP/dm.txt" \
     && grep -Fqi '@mention is not required' "$TMP/dm.txt" \
     && ! grep -Fqi 'stay silent' "$TMP/dm.txt" \
     && ! grep -Fqi 'you follow this conversation' "$TMP/dm.txt"; then
    pass "verified DM without a literal mention is treated as addressed"
  else
    fail "verified DM inherited mention-only stand-down posture"
  fi

  # A literal mention keeps its existing stronger posture even when the origin
  # is a DM; channel classification must not replace direct-mention behavior.
  : > "$TMP/dm-mentioned.txt"; session_append_mention_posture true "$TMP/dm-mentioned.txt" slack true 'agt_test#slack:D1:T1'
  if cmp -s "$TMP/m1.txt" "$TMP/dm-mentioned.txt"; then
    pass "direct mentions retain their existing posture across channels"
  else
    fail "DM classification changed direct-mention posture"
  fi

  # The two must never say the same thing.
  if cmp -s "$TMP/m1.txt" "$TMP/m2.txt"; then
    fail "mention and non-mention posture are identical"
  else
    pass "mention and non-mention posture differ"
  fi

  # ABSENT is not false. A sender that predates the field has no opinion, and an
  # absent opinion rendered as "stay silent" silences EVERY turn until the sender
  # catches up -- live regression 2026-07-26, caught between the hq-core release
  # and toolset delivery of the sender half.
  : > "$TMP/m3.txt"; session_append_mention_posture unknown "$TMP/m3.txt"
  if [ -s "$TMP/m3.txt" ]; then
    fail "unknown mention state emitted a posture; absent must add NO constraint"
  else
    pass "unknown mention state emits nothing (prompt byte-identical to pre-feature)"
  fi
  : > "$TMP/m4.txt"; session_append_mention_posture "" "$TMP/m4.txt"
  if [ -s "$TMP/m4.txt" ]; then
    fail "empty mention state emitted a posture"
  else
    pass "empty mention state emits nothing"
  fi
  # The entrypoint must distinguish absent from false, not coalesce with // false.
  if grep -q 'jq -r .directMention // false' "$SCRIPT_DIR/../hq-agent-session.sh"; then
    fail "entrypoint coalesces absent to false -- silences turns from older senders"
  else
    pass "entrypoint distinguishes absent from false"
  fi
  if grep -Fq 'session_append_mention_posture "$direct_mention" "$run_dir/system.txt" "$channel" "$sender_verified" "$conv_key"' \
      "$SCRIPT_DIR/../hq-agent-session.sh"; then
    pass "entrypoint passes channel and sender trust to mention posture"
  else
    fail "entrypoint omits DM addressing context from mention posture"
  fi
  exit "$FAILED"
) || FAILED=1

# The schema must ACCEPT directMention, or every hq-session turn fails validation.
(
  SCHEMA="$SCRIPT_DIR/../../schemas/agent-session-request.schema.json"
  if [ -f "$SCHEMA" ]; then
    if python3 -c "import json,sys; d=json.load(open('$SCHEMA')); sys.exit(0 if 'directMention' in d['properties'] else 1)"; then
      pass "request schema declares directMention (additionalProperties is false)"
    else
      fail "schema omits directMention -- envelope would fail validation on every turn"
    fi
  fi
  exit "$FAILED"
) || FAILED=1

# ── the ENFORCING validator must accept directMention ───────────────────────
# The JSON schema file is documentation; validate_request_json's hand-rolled jq
# key allowlist is the actual gate. Adding the property to the schema alone left
# every envelope carrying it rejected with "invalid request" (exit 2) -- i.e.
# the sender half would have failed EVERY hq-session turn fleet-wide.
(
  SESSION_SH="$SCRIPT_DIR/../hq-agent-session.sh"
  if awk '/^validate_request_json/,/^}/' "$SESSION_SH" | grep -q '"directMention"'; then
    pass "validate_request_json allowlists directMention"
  else
    fail "enforcing validator omits directMention -- every turn carrying it fails"
  fi
  if awk '/^validate_request_json/,/^}/' "$SESSION_SH" | grep -q 'directMention | type == "boolean"'; then
    pass "validate_request_json type-checks directMention"
  else
    fail "validate_request_json should type-check directMention"
  fi
  exit "$FAILED"
) || FAILED=1

# ── contract salience: head AND tail ────────────────────────────────────────
# Position is the fix, not wording. Buried ~line 276 of a 67KB prompt, grok
# honoured the contract on ~3 runs in 5. Primacy and recency are the positions a
# long-context model reliably attends to.
(
  load_helpers
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

  printf 'EXISTING PROMPT BODY\n' > "$TMP/s.txt"
  session_append_reply_contract grok "$TMP/s.txt"
  head -1 "$TMP/s.txt" | grep -Fq '<!-- hq-section: reply-contract -->' \
    && pass "contract is the FIRST line of the prompt" \
    || fail "contract is not at the head: $(head -1 "$TMP/s.txt")"
  grep -Fq 'EXISTING PROMPT BODY' "$TMP/s.txt" \
    && pass "prepend preserves the existing prompt body" \
    || fail "prepend destroyed the existing body"

  # more sections land after the contract, as they do in real assembly
  printf 'LATER SECTION\n' >> "$TMP/s.txt"
  session_append_reply_contract_reminder grok "$TMP/s.txt"
  tail -4 "$TMP/s.txt" | grep -Fq 'REMINDER' \
    && pass "reminder is at the TAIL, after later sections" \
    || fail "reminder is not last"
  [ "$(grep -c 'REPLY CONTRACT — this overrides' "$TMP/s.txt")" = "1" ] \
    && pass "full contract appears exactly once (tail is a short restatement)" \
    || fail "full contract duplicated; tail must not repeat it verbatim"

  # non-enforced providers get neither copy
  printf 'BODY\n' > "$TMP/c.txt"
  session_append_reply_contract codex "$TMP/c.txt"
  session_append_reply_contract_reminder codex "$TMP/c.txt"
  [ "$(cat "$TMP/c.txt")" = "BODY" ] \
    && pass "non-enforced provider prompt is untouched at both ends" \
    || fail "non-enforced provider prompt was modified"
  exit "$FAILED"
) || FAILED=1

# ── status notes ────────────────────────────────────────────────────────────
(
  load_helpers
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  : > "$TMP/n.txt"; session_append_status_notes "$TMP/n.txt"
  grep -Fq '<!-- hq-section: status-notes -->' "$TMP/n.txt" \
    && pass "status-notes section present" || fail "status-notes section missing"
  grep -Fq 'agent-status' "$TMP/n.txt" \
    && pass "names the agent-status command" || fail "does not name agent-status"
  grep -Fq 'working (300s)' "$TMP/n.txt" \
    && pass "explains the bare-timer degradation it prevents" \
    || fail "does not explain why a note matters"
  grep -Fqi 'never post the same text' "$TMP/n.txt" \
    && pass "status notes replace progress chatter rather than adding to it" \
    || fail "must not invite duplicate channel posts"
  exit "$FAILED"
) || FAILED=1

if [ "$FAILED" -eq 0 ]; then
  echo "hq-agent-session-reply-contract: PASS"
else
  echo "hq-agent-session-reply-contract: FAIL"
fi
exit "$FAILED"
