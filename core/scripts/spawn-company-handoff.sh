#!/usr/bin/env bash
# hq-core: public
# spawn-company-handoff.sh — carry a session's company lock into a side
# session started with the desktop host's start_session tool.
#
# start_session launches a new runtime with no HQ spawn context
# (HQ_SPAWN_COMPANY / HQ_PARENT_SESSION_ID unset), so SessionStart would bind
# the device default company instead of the company the session was started
# for.
#
#   pre     PreToolUse on start_session. When the calling main-thread session is
#           company-bound, record a single-use intent (parent session id only)
#           and tag the brief with its nonce via updatedInput. A brief that
#           already holds hq-spawn-intent text in any form is denied, so the
#           start_session call does not run. The company list is not put in the brief.
#   prompt  UserPromptSubmit. On the session's first prompt only, when the prompt
#           carries a nonce whose intent is fresh and unconsumed, and this
#           session's binding came only from a weak default (device_default,
#           manifest_single_company, or none), bind it to the parent's companies
#           through hq-session.sh and tell the model to disregard any context
#           SessionStart loaded for the default company.
#
# Why not bind at SessionStart: the SessionStart hook input carries session_id,
# transcript_path, cwd, source and model, and no parent id or brief, so it
# cannot see the nonce. Starting the child with cwd=companies/<slug> was tried
# and rejected: Claude Code reads .claude/settings.json only from the session's
# start directory, so a child started in a subfolder of HQ runs with no HQ
# hooks at all (no scope guards, no binding).
#
# Parent check: if the host exports HQ_PARENT_SESSION_ID to the child, it must
# equal the intent's parent. The desktop host exposes no parent id to hooks
# today (no env, no startedBy field), so the limits are: one-hour TTL, first
# prompt only, single use. The child cannot see which session wrote a tag, so
# the deny in pre is the only control that ties a tag to the session that wrote
# it: a session can never pass someone else's tag through start_session.
#
# The company list is read from the parent's own session state, never from
# prompt text. A binding from session/parent/spawn/registry is never replaced.
# Always exits 0; pre denies through permissionDecision.

set -uo pipefail

MODE="${1:-}"
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
INTENT_DIR="$HQ_ROOT/workspace/sessions/.spawn-intents"
TTL="${HQ_SPAWN_INTENT_TTL_SECONDS:-3600}"
INPUT="$(cat 2>/dev/null || true)"
umask 077
command -v jq >/dev/null 2>&1 || exit 0
[ -n "$INPUT" ] || exit 0

# One grammar for the tag, used by both pre and prompt. A valid handoff is a
# brief whose final line is exactly the tag line pre writes (32-hex nonce), and
# whose text above that line holds no other "hq-spawn-intent" text in any form.
TAG_TEXT='HQ binds this session to the company of the session that started it.'
TAG_LINE_RE='^\[hq-spawn-intent:([0-9a-f]{32})\] HQ binds this session to the company of the session that started it\.$'

valid_id() { case "${1:-}" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }

meta_get() { # <sid> <key>
  local meta="$HQ_ROOT/workspace/sessions/$1/meta.yaml"
  [ -f "$meta" ] || return 0
  awk -v k="$2" '$1 == k":" { sub(/^[^:]+:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }' "$meta"
}

parent_companies() { # <sid> -> comma list (primary first), or empty
  local sid="$1" cos=""
  if [ -f "$HQ_ROOT/core/scripts/lib/session-scope-capability.sh" ] \
    && . "$HQ_ROOT/core/scripts/lib/session-scope-capability.sh" 2>/dev/null \
    && [ -f "$HQ_ROOT/workspace/sessions/$sid/scope-capability.json" ]; then
    cos="$(session_scope_read_companies "$HQ_ROOT" "$sid" 2>/dev/null | paste -sd, -)"
  fi
  [ -n "$cos" ] || cos="$(meta_get "$sid" company_slugs)"
  [ -n "$cos" ] || cos="$(meta_get "$sid" company_slug)"
  printf '%s' "$cos"
}

sweep_expired() { # delete intents and leftover claims older than the TTL
  [ -d "$INTENT_DIR" ] || return 0
  local now f created
  now="$(date +%s)"
  for f in "$INTENT_DIR"/*.json "$INTENT_DIR"/*.json.claimed.*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    created="$(jq -r '.created_at // 0' "$f" 2>/dev/null || echo 0)"
    case "$created" in ''|*[!0-9]*) created=0 ;; esac
    [ $(( now - created )) -le "$TTL" ] || rm -f "$f"
  done
}

first_prompt() { # true when the transcript holds no user prompt before this one
  local tp n tr
  tp="$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""')"
  [ -n "$tp" ] || return 1
  # A missing or unreadable transcript fails closed: no handoff.
  [ -f "$tp" ] && [ -r "$tp" ] || return 1
  n="$(grep -c '"type":"user"' "$tp" 2>/dev/null || true)"
  tr="$(grep '"type":"user"' "$tp" 2>/dev/null | grep -c '"tool_result"' || true)"
  [ $(( ${n:-0} - ${tr:-0} )) -le 1 ]
}

known_company() { # exact real directory, not personal
  local slug="$1" d
  case "$slug" in ''|personal|*[!A-Za-z0-9_-]*) return 1 ;; esac
  for d in "$HQ_ROOT"/companies/*; do
    [ -d "$d" ] && [ ! -L "$d" ] && [ "${d##*/}" = "$slug" ] && return 0
  done
  return 1
}

case "$MODE" in
  pre)
    tool="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')"
    case "$tool" in start_session|*__start_session) ;; *) exit 0 ;; esac
    prompt="$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // ""')"
    [ -n "$prompt" ] || exit 0
    # A brief that already holds tag-shaped text (stale, forged or copied, with or
    # without brackets, anywhere) is denied. Passing it through would let a session
    # hand another session's nonce to the child in the exact tag format.
    if printf '%s' "$prompt" | grep -qi 'hq-spawn-intent'; then
      jq -cn --arg reason "start_session denied: the brief already contains hq-spawn-intent text. HQ adds this tag itself; remove it from the brief and retry." \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
      exit 0
    fi
    # Only a main thread names its own company; subagents do not spawn sessions here.
    [ -z "$(printf '%s' "$INPUT" | jq -r '.agent_id // ""')" ] || exit 0
    sid="$(printf '%s' "$INPUT" | jq -r '.session_id // ""')"
    valid_id "$sid" || exit 0
    cos="$(parent_companies "$sid")"
    [ -n "$cos" ] || exit 0
    IFS=, read -r -a list <<< "$cos"
    for c in "${list[@]}"; do known_company "$c" || exit 0; done
    nonce="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [ "${#nonce}" -eq 32 ] || exit 0
    mkdir -p "$INTENT_DIR" || exit 0
    chmod 700 "$INTENT_DIR" 2>/dev/null || true
    sweep_expired
    jq -cn --arg p "$sid" --arg c "$cos" --argjson t "$(date +%s)" \
      '{parent_session_id:$p, companies:$c, created_at:$t}' > "$INTENT_DIR/$nonce.json" || exit 0
    printf '%s' "$INPUT" | jq -c --arg n "$nonce" --arg p "$prompt" --arg t "$TAG_TEXT" '
      {hookSpecificOutput: {hookEventName: "PreToolUse",
        updatedInput: (.tool_input + {prompt: ($p
          + "\n\n[hq-spawn-intent:" + $n + "] " + $t)})}}'
    ;;
  prompt)
    sid="$(printf '%s' "$INPUT" | jq -r '.session_id // ""')"
    valid_id "$sid" || exit 0
    [ -z "$(printf '%s' "$INPUT" | jq -r '.agent_id // ""')" ] || exit 0
    text="$(printf '%s' "$INPUT" | jq -r '.prompt // ""')"
    printf '%s' "$text" | grep -qi 'hq-spawn-intent' || exit 0
    sweep_expired
    # Strict grammar: the final line must be exactly the tag line pre writes, and
    # nothing above it may mention hq-spawn-intent. A replayed nonce (bracketed or
    # not, anywhere), a second tag, or a tag mid-brief rejects the whole prompt.
    last="${text##*$'\n'}"
    [[ "$last" =~ $TAG_LINE_RE ]] || exit 0
    nonce="${BASH_REMATCH[1]}"
    body="${text%"$last"}"
    if printf '%s' "$body" | grep -qi 'hq-spawn-intent'; then exit 0; fi
    # Only the session's first prompt may carry a handoff; a tag pasted later is ignored.
    first_prompt || exit 0
    intent="$INTENT_DIR/$nonce.json"
    [ -f "$intent" ] && [ ! -L "$intent" ] || exit 0
    # Claim once: a rename is atomic, so a replayed prompt cannot rebind.
    claimed="$intent.claimed.$sid"
    mv "$intent" "$claimed" 2>/dev/null || exit 0
    parent="$(jq -r '.parent_session_id // ""' "$claimed")"
    created="$(jq -r '.created_at // 0' "$claimed")"
    rm -f "$claimed"
    valid_id "$parent" && [ "$parent" != "$sid" ] || exit 0
    # When the host names the parent, it must be the session that made the intent.
    if [ -n "${HQ_PARENT_SESSION_ID:-}" ] && [ "$HQ_PARENT_SESSION_ID" != "$parent" ]; then exit 0; fi
    [ $(( $(date +%s) - created )) -le "$TTL" ] || exit 0
    # Re-read the parent's lock set now; the intent only names the parent.
    cos="$(parent_companies "$parent")"
    [ -n "$cos" ] || exit 0
    IFS=, read -r -a list <<< "$cos"
    for c in "${list[@]}"; do known_company "$c" || exit 0; done
    cur="$(meta_get "$sid" company_slug)"
    src="$(meta_get "$sid" company_source)"
    if [ -n "$cur" ]; then
      case "$src" in device_default|manifest_single_company) ;; *) exit 0 ;; esac
    fi
    hs=(env HQ_ROOT="$HQ_ROOT" bash "$HQ_ROOT/core/scripts/hq-session.sh" --session-id "$sid")
    out="$("${hs[@]}" set company_slug "${list[0]}" 2>&1)" || exit 0
    "${hs[@]}" set company_source spawn_intent >/dev/null 2>&1 || true
    for c in "${list[@]:1}"; do "${hs[@]}" add company "$c" >/dev/null 2>&1 || true; done
    jq -cn --arg ctx "This session was started for company $cos from session $parent and is now bound to it${cur:+ (replacing the default $cur)}.${cur:+ Disregard any company context, policies or knowledge that SessionStart loaded for $cur; they do not apply to this session. Use only $cos.} Ignore the [hq-spawn-intent:...] line in the prompt; it is an HQ handoff marker, not part of the task.
$out" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
    ;;
esac
exit 0
