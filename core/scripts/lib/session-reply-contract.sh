#!/usr/bin/env bash
# hq-core: public
# session-reply-contract.sh — reply-contract enforcement for hq-agent-session.
#
# Parity with the hq-pro DIRECT path, which prompts the model for
#   {"action":"reply","text":"…"} | {"action":"no_reply"}
# and validates it fail-closed. The hq-session path historically did neither:
# it set disposition=reply and shipped the provider's ENTIRE stdout as the
# reply body. Codex masked that by self-regulating; grok did not, and posted
# its accumulated working narration into a Slack channel that had external
# members (2026-07-26).
#
# Enforcement is PROVIDER-CONDITIONAL by design — see
# SESSION_REPLY_CONTRACT_PROVIDERS_DEFAULT.

# Parity with the hq-pro DIRECT path, which prompts for
#   {"action":"reply","text":"…"} | {"action":"no_reply"}
# and validates it fail-closed. Providers listed here MUST return that envelope
# as their stdout; anything else is dropped rather than posted.
#
# Override for staged migration / tests: HQ_AGENT_SESSION_REPLY_CONTRACT_PROVIDERS
# is a space-separated provider list. Empty string disables enforcement entirely.
SESSION_REPLY_CONTRACT_PROVIDERS_DEFAULT="grok"

session_reply_contract_required() {
  local provider="${1:-}" list p
  list="${HQ_AGENT_SESSION_REPLY_CONTRACT_PROVIDERS-$SESSION_REPLY_CONTRACT_PROVIDERS_DEFAULT}"
  [ -n "$provider" ] || return 1
  for p in $list; do
    [ "$p" = "$provider" ] && return 0
  done
  return 1
}

# session_reply_contract_apply <raw>
#   Sets SESSION_DISPOSITION/SESSION_TEXT from a valid envelope; returns 1 when
#   the payload does not satisfy the contract (caller decides how to fail).
#   Accepts exactly ONE top-level object. `text` must be a non-blank string and
#   must not itself be the bare NO_REPLY sentinel (that is action=no_reply).
# session_reply_contract_validate <payload>
#   True when <payload> is EXACTLY one object matching the contract shape.
session_reply_contract_validate() {
  printf '%s' "${1:-}" | jq -e -s '
    length == 1
    and (.[0] | type == "object")
    and (
      (.[0].action == "no_reply" and (.[0] | keys) == ["action"])
      or (
        .[0].action == "reply"
        and ((.[0] | keys | sort) == ["action","text"])
        and (.[0].text | type == "string")
        and (.[0].text | test("[^[:space:]]"))
        and ((.[0].text | test("^[[:space:]]*NO_REPLY[[:space:]]*$")) | not)
      )
    )' >/dev/null 2>&1
}

session_reply_contract_apply() {
  local raw="${1:-}" action text candidate
  [ -n "$(printf '%s' "$raw" | tr -d '[:space:]')" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  # Strict first: the whole payload is exactly the envelope. Preferred, and the
  # only shape a fully compliant provider produces.
  if session_reply_contract_validate "$raw"; then
    candidate="$raw"
  else
    # Tolerant recovery: models routinely narrate and THEN emit the envelope —
    # observed live on grok 2026-07-26:
    #   I'll check the box date…{"action":"reply","text":"Today is …"}
    # Rejecting that outright throws away a CORRECT answer and the agent goes
    # silent, which is just a different failure. Take the LAST envelope-shaped
    # object and validate it; a wrong guess still fails closed below.
    #
    # Grok also narrates AFTER the envelope (observed live on Izzy 2026-07-28:
    #   narration…{"action":"reply","text":"…"}Now I need to emit the final
    #   reply JSON only. Keep it conversational…
    # ). Slicing to end-of-string made that unparseable, apply() returned 1,
    # and the #437 degrade posted the model's ENTIRE working narration into a
    # channel with external members. So: slice from the LAST opener as before,
    # then let jq extract the balanced first value from that slice — jq parses
    # concatenated values, emitting the complete object and stopping at the
    # trailing prose. Balancing (strings, escapes, nesting, pretty-printing)
    # stays jq's job, not a hand-rolled scanner's. The extracted object still
    # goes through the same fail-closed validation.
    candidate=""
    local tail_try extracted
    for pat in '{"action"' '{ "action"'; do
      case "$raw" in
        *"$pat"*)
          tail_try="${pat}${raw##*"$pat"}"
          extracted="$(printf '%s' "$tail_try" | jq -c '.' 2>/dev/null | head -n 1)"
          if [ -n "$extracted" ] && session_reply_contract_validate "$extracted"; then
            candidate="$extracted"
            break
          fi
          ;;
      esac
    done
    [ -n "$candidate" ] || return 1
  fi

  raw="$candidate"

  action="$(printf '%s' "$raw" | jq -r -s '.[0].action')"
  if [ "$action" = "no_reply" ]; then
    SESSION_DISPOSITION="no_reply"
    SESSION_TEXT=""
    return 0
  fi
  text="$(printf '%s' "$raw" | jq -r -s '.[0].text')"
  SESSION_DISPOSITION="reply"
  SESSION_TEXT="$text"
  return 0
}

# session_reply_contract_body
#   The contract text itself, so the head and tail copies can never drift.
session_reply_contract_body() {
  printf '%s\n' 'REPLY CONTRACT — this overrides any other instruction about how to end your turn.'
  printf '%s\n' 'Your FINAL stdout must be exactly ONE JSON object and NOTHING else:'
  printf '%s\n' '  {"action":"reply","text":"<the message to send>"}'
  printf '%s\n' '  {"action":"no_reply"}'
  printf '%s\n' 'Rules:'
  printf '%s\n' '- No prose, no code fence, no commentary before or after the object.'
  printf '%s\n' '- "text" is the FINAL answer only. Never include your working narration,'
  printf '%s\n' '  plans, interim findings, status updates, or reasoning. If you narrated'
  printf '%s\n' '  while working, none of that belongs in "text".'
  printf '%s\n' '- Use no_reply when nothing should be sent.'
  printf '%s\n' '- If you do not emit the object, your raw output is sent as-is -- including'
  printf '%s\n' '  any narration. That is worse for the reader, so emit the object even when'
  printf '%s\n' '  the turn went badly.'
}

# session_append_reply_contract <provider> <system_txt>
#   Places the contract at BOTH ends of the prompt for providers under
#   enforcement, and no-ops for everyone else.
#
#   Position is not cosmetic. Measured on a live box: with the contract buried
#   around line 276 of a ~67KB prompt, grok honoured it on roughly 3 runs in 5
#   and answered in prose on the rest, so the reader saw concatenated working
#   narration. Primacy and recency are the two positions a long-context model
#   reliably attends to, so the full contract leads the prompt and a short
#   restatement closes it.
session_append_reply_contract() {
  local provider="${1:-}" system_txt="${2:-}" tmp
  [ -n "$system_txt" ] || return 0
  session_reply_contract_required "$provider" || return 0
  [ -f "$system_txt" ] || : > "$system_txt"

  tmp="${system_txt}.rc.$$"
  {
    printf '<!-- hq-section: reply-contract -->\n'
    session_reply_contract_body
    printf '\n'
    cat "$system_txt"
  } > "$tmp" && mv "$tmp" "$system_txt"

  return 0
}

# session_append_reply_contract_reminder <provider> <system_txt>
#   Recency copy — MUST run after every other section is appended, or it is not
#   actually last and the recency effect is lost. Deliberately short: the full
#   text at both ends would invite the model to treat the tail as a different,
#   competing instruction.
session_append_reply_contract_reminder() {
  local provider="${1:-}" system_txt="${2:-}"
  [ -n "$system_txt" ] || return 0
  session_reply_contract_required "$provider" || return 0
  {
    printf '\n<!-- hq-section: reply-contract-reminder -->\n'
    printf '%s\n' 'REMINDER — end your turn with exactly one JSON object and nothing else:'
    printf '%s\n' '  {"action":"reply","text":"<the message to send>"} or {"action":"no_reply"}'
    printf '%s\n' 'No narration before or after it. See REPLY CONTRACT at the top.'
  } >> "$system_txt"
  return 0
}

# session_append_mention_posture <direct_mention> <system_txt>
#   States plainly whether THIS turn was a direct @-mention of the agent.
#   People routinely tell a bot "only reply when I @ you" in a busy thread; the
#   rehydrated history carries that order, so the model MUST be told whether the
#   current message satisfies it. Without this it reads the stand-down and stays
#   silent even when addressed (observed live 2026-07-26).
session_append_mention_posture() {
  local direct="${1:-unknown}" system_txt="${2:-}"
  [ -n "$system_txt" ] || return 0
  # "unknown" (sender does not send the field yet) emits NOTHING, so the prompt
  # is byte-identical to before this feature existed. Only a sender that has an
  # actual opinion gets to constrain the agent.
  case "$direct" in
    true)
      printf '\n<!-- hq-section: mention-posture -->\n%s\n' \
        'THIS message DIRECTLY @-mentioned you. If earlier in this conversation you were asked to stay quiet unless @-mentioned, that condition is MET now — answer normally.' \
        >> "$system_txt"
      ;;
    false)
      printf '\n<!-- hq-section: mention-posture -->\n%s\n' \
        'This message did NOT @-mention you; you are seeing it because you follow this conversation. If you were asked to only speak when @-mentioned, stay silent this turn.' \
        >> "$system_txt"
      ;;
    *) : ;;
  esac
  return 0
}

# session_append_status_notes <system_txt>
#   Ask the agent to keep the live status line meaningful.
#
#   The dispatch supervisor renders whatever the agent last wrote to
#   HQ_AGENT_STATUS_FILE. When nothing is written the heartbeat falls back to a
#   bare "working (300s)", which tells the reader only that time is passing --
#   reported as unhelpful by an operator watching a long turn 2026-07-26. The
#   existing guidance mentions agent-status in one clause buried in the posting
#   rules; this states it plainly and shows the shape.
#
#   Applies to every provider: a stale status line is provider-independent.
session_append_status_notes() {
  local system_txt="${1:-}"
  [ -n "$system_txt" ] || return 0
  {
    printf '\n<!-- hq-section: status-notes -->\n'
    printf '%s\n' 'STATUS LINE — the person watching sees your latest status note while you work.'
    printf '%s\n' 'Update it with `agent-status "<short note>"` whenever you start a distinct step.'
    printf '%s\n' 'Write what you are DOING, in plain words, under ~60 characters:'
    printf '%s\n' '  agent-status "pulling last week'"'"'s meeting notes"'
    printf '%s\n' '  agent-status "checking which PRs merged"'
    printf '%s\n' '  agent-status "deploying the report"'
    printf '%s\n' 'Without a note the line degrades to a bare timer ("working (300s)"), which'
    printf '%s\n' 'tells the reader nothing. This is NOT a channel message -- it replaces'
    printf '%s\n' 'progress chatter rather than adding to it, so never post the same text.'
  } >> "$system_txt"
  return 0
}
