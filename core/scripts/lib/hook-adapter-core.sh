# shellcheck shell=bash
# hq-core: public
# hook-adapter-core.sh — single-source hook dispatch for the Codex and Grok
# adapters.
#
# WHY THIS EXISTS. The event->hook dispatch table used to be hand-transcribed in
# three places: .claude/settings.json (Claude, native), the Codex adapter, and
# the Grok adapter. They drifted (Grok lost checkpoint-stop-gate; Codex lost
# warn-cross-company-settings; etc.). This library makes .claude/settings.json
# the ONE authoritative table: the Codex and Grok adapters read it live and
# dispatch exactly what Claude dispatches, so the three can no longer diverge.
#
# Governing rule: personal/policies/hq-classifier-own-labels-single-source.md —
# keep one authoritative source and derive the copies from it.
#
# What this library provides:
#   hqad_iter_settings <event> <canonical_tool>
#       Emits, one per line, every settings.json command registered for that
#       event whose matcher matches <canonical_tool>, classified as:
#           gate<TAB><hook-id><TAB><script-abs>[<TAB>extra-arg...]
#           master<TAB><event-arg>
#           script<TAB><script-abs>
#       Tabs separate fields; callers read with IFS=$'\t'.
#   hqad_mode_for <event> <script-abs>
#       Prints "blocking" or "advisory". Default: blocking for PreToolUse,
#       advisory for every other event. A hook may override with a
#       "# hq-hook-mode: advisory" (or blocking) frontmatter line — this is how
#       context-injecting PreToolUse hooks (inject-policy-on-trigger,
#       warn-cross-company-settings, surface-company-infra-policy) stay advisory
#       so a non-zero exit never blocks a tool. Grok can only block PreToolUse,
#       so non-PreToolUse always resolves advisory regardless.
#
# Requires: HQ_ROOT exported by the caller, and jq on PATH. Reads
# $HQ_ROOT/.claude/settings.json. Emits nothing (returns 0) if either is absent,
# so the adapter's own minimal safety net still applies.

# Match a settings.json matcher against a canonical (Claude) tool name.
#   - Empty matcher or "*"            -> always matches.
#   - Non-tool events                 -> matcher is decorative; always matches.
#   - Tool events (Pre/PostToolUse)   -> regex match ("*"->".*", ","->"|"),
#                                        anchored ^(...)$, same as master-hook.sh.
hqad_matcher_matches() {
  local matcher="$1" tool="$2" event="$3"
  local status
  [ -z "$matcher" ] && return 0
  [ "$matcher" = "*" ] && return 0
  case "$event" in
    PreToolUse|PostToolUse) ;;
    *) return 0 ;;
  esac
  [ -z "$tool" ] && return 1
  local re="${matcher//\*/.*}"
  re="${re//,/|}"
  if [[ "$tool" =~ ^(${re})$ ]]; then
    return 0
  else
    # Preserve Bash's regex compile-failure status (2) for fail-closed input.
    # shellcheck disable=SC2319
    status=$?
    if [ "$status" -eq 2 ]; then
      printf 'ERROR: hqad: malformed settings matcher; dispatching fail-closed.\n' >&2
      return 0
    fi
    return 1
  fi
}

# Build the policy scan roots and cache using the same inputs and compiler as
# master-hook.sh. The callers intentionally pass these values instead of
# relying on adapter-specific environment fields.
hqad_policy_prefilter_dirs() {
  local root="$1" cwd="$2" active_company="$3" company_override="${HQ_POLICY_COMPANY:-}"
  local co="" rscope rname rest
  if [ -n "$company_override" ]; then
    co="$company_override"
  else
    case "$cwd" in
      *companies/*) rest="${cwd#*companies/}"; co="${rest%%/*}" ;;
    esac
    [ -n "$co" ] || co="$active_company"
  fi
  case "$co" in *[!A-Za-z0-9_-]*|.|..) co="" ;; esac
  [ -n "$co" ] && printf '%s\n' "$root/companies/$co/policies"
  case "$cwd" in
    *repos/public/*|*repos/private/*)
      rest="${cwd#*repos/}"; rscope="${rest%%/*}"; rest="${rest#*/}"; rname="${rest%%/*}"
      case "$rname" in *[!A-Za-z0-9._-]*|.|..) rname="" ;; esac
      [ -n "$rscope" ] && [ -n "$rname" ] && printf '%s\n' "$root/repos/$rscope/$rname/.claude/policies" ;;
  esac
  printf '%s\n%s\n' "$root/personal/policies" "$root/core/policies"
}

hqad_policy_prefilter_now() {
  if [ -n "${EPOCHSECONDS:-}" ]; then printf '%s' "$EPOCHSECONDS"; else date +%s 2>/dev/null || printf '0'; fi
}

# hqad_policy_prefilter_check <root> <event> <active-company> <cwd> <session-id> <text>
# Returns 0 when the injector must run, 1 when its compiled vocabulary proves
# that no tool-event policy can match. Unknown policy syntax always runs it.
hqad_policy_prefilter_check() {
  local root="$1" ev="$2" active_company="$3" cwd="$4" session_id="$5" text="$6"
  local dir dirs=() key="" cache stale=0 now line rest company repo f
  local ledger_session ledger_path ledger="" derived_facts="" branch=""
  case "$ev" in PreToolUse|PostToolUse) ;; *) return 0 ;; esac
  case "${HQ_POLICY_COMPANY:-}" in *[!A-Za-z0-9_-]*|.|..) return 0 ;; esac
  case "$cwd" in
    *companies/*)
      rest="${cwd#*companies/}"; company="${rest%%/*}"
      case "$company" in *[!A-Za-z0-9_-]*|.|..) return 0 ;; esac
      ;;
  esac
  case "$cwd" in
    *repos/public/*|*repos/private/*)
      rest="${cwd#*repos/}"; rest="${rest#*/}"; repo="${rest%%/*}"
      case "$repo" in *[!A-Za-z0-9._-]*|.|..) return 0 ;; esac
      ;;
  esac
  case "$session_id" in *[!A-Za-z0-9._-]*|.|..) return 0 ;; esac
  ledger_session="$session_id"
  [ -n "$ledger_session" ] || ledger_session="default"
  ledger_path="$root/workspace/orchestrator/policy-trigger-state/$ledger_session.txt"
  # The real injector has session-wide policies that run on the first event.
  # Until its dedupe ledger exists, the vocabulary cannot prove those policies
  # have already fired, so keep the injector in the dispatch set.
  [ -f "$ledger_path" ] || return 0
  ledger="$(<"$ledger_path")"
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    dirs+=("$dir")
    key="$key${dir#"$root"/}|"
  done < <(hqad_policy_prefilter_dirs "$root" "$cwd" "$active_company")
  key="${key//\//_}"; key="${key//|/+}"
  case "$key" in *[!A-Za-z0-9_.+-]*) return 0 ;; esac
  cache="$root/workspace/orchestrator/hook-state/policy-prefilter/${key}${ev}.v1"
  now="$(hqad_policy_prefilter_now)"
  if [ -f "$cache" ]; then
    for dir in "${dirs[@]}"; do
      [ -d "$dir" ] || continue
      [ "$cache" -nt "$dir" ] || stale=1
      for f in "$dir"/*.md; do
        [ -f "$f" ] || continue
        case "${f##*/}" in
          example-policy.md|README.md|*" "*|*.sync-conflict-*.md|*.conflict-*) continue ;;
        esac
        [ "$cache" -nt "$f" ] || stale=1
      done
    done
    if [ "$stale" -eq 0 ]; then
      IFS= read -r line < "$cache" || line=""
      case "$line" in
        built=*) [ $(( now - ${line#built=} )) -lt "${HQ_POLICY_PREFILTER_TTL:-300}" ] || stale=1 ;;
        *) stale=1 ;;
      esac
    fi
  else
    stale=1
  fi
  if [ "$stale" -eq 1 ]; then
    mkdir -p "${cache%/*}" 2>/dev/null || return 0
    local files=() f
    for dir in "${dirs[@]}"; do
      [ -d "$dir" ] || continue
      for f in "$dir"/*.md; do
        [ -f "$f" ] || continue
        case "${f##*/}" in
          example-policy.md|README.md|*" "*|*.sync-conflict-*.md|*.conflict-*) continue ;;
        esac
        files+=("$f")
      done
    done
    if ! awk -v ev="$ev" -v now="$now" '
      function tokenize(s,    n, m) {
        split("", tok); ntok = 0
        while (length(s) > 0) {
          if (match(s, /^[[:space:]]+/)) { s = substr(s, RLENGTH + 1); continue }
          if (substr(s, 1, 2) == "&&" || substr(s, 1, 2) == "||") { tok[++ntok] = substr(s, 1, 2); s = substr(s, 3); continue }
          if (substr(s, 1, 1) == "(" || substr(s, 1, 1) == ")" || substr(s, 1, 1) == "!") { tok[++ntok] = substr(s, 1, 1); s = substr(s, 2); continue }
          if (match(s, /^[A-Za-z0-9_.\/][A-Za-z0-9_.\/-]*/)) { tok[++ntok] = tolower(substr(s, 1, RLENGTH)); s = substr(s, RLENGTH + 1); continue }
          tok[++ntok] = "?"; s = substr(s, 2)
        }
      }
      function leaf(t) {
        if (t == "company" || t == "repo") { structural = structural " " t; return "NONE" }
        if (t == "always" || t == "?") { bad = 1; return "NONE" }
        return t
      }
      function pf(    t, r) {
        t = tok[pos]
        if (t == "!") { pos++; pf(); return "NONE" }
        if (t == "(") { pos++; r = pe(); if (tok[pos] == ")") pos++; else bad = 1; return r }
        if (t == "" ) { bad = 1; return "NONE" }
        pos++; return leaf(t)
      }
      function pt(    l, r) {
        l = pf()
        while (tok[pos] == "&&") {
          pos++; r = pf()
          if (l == "NONE") l = r
          else if (r != "NONE" && split(r, ra, " ") < split(l, la, " ")) l = r
        }
        return l
      }
      function pe(    l, r) {
        l = pt()
        while (tok[pos] == "||") {
          pos++; r = pt()
          if (l == "NONE" || r == "NONE") l = "NONE"; else l = l " " r
        }
        return l
      }
      function esc(t,    o, i, c) {
        o = ""
        for (i = 1; i <= length(t); i++) { c = substr(t, i, 1); if (c ~ /[.\/]/) o = o "\\" c; else o = o c }
        return o
      }
      BEGIN { print "built=" now }
      FNR == 1 { infm = 0; onl = ""; whenl = ""; fm_done = 0 }
      FNR == 1 && $0 == "---" { infm = 1; next }
      infm && $0 == "---" { infm = 0; fm_done = 1 }
      infm && /^on:/ { onl = $0 }
      infm && /^when:/ { whenl = $0; sub(/^when:[[:space:]]*/, "", whenl); sub(/[[:space:]]+$/, "", whenl) }
      fm_done && !seen[FILENAME]++ {
        slug = FILENAME; sub(/.*\//, "", slug); sub(/\.md$/, "", slug)
        if (index(onl, ev) == 0) next
        if (whenl == "") { print "unsafe=" slug; next }
        gsub(/^"|"$/, "", whenl)
        tokenize(whenl); pos = 1; bad = 0; structural = ""
        res = pe()
        if (pos <= ntok) bad = 1
        if (bad) { print "unsafe=" slug; next }
        if (res == "NONE") {
          n = split(structural, st, " ")
          if (n == 0) { print "unsafe=" slug; next }
          for (i = 1; i <= n; i++) print "struct=" slug ":" st[i]
          next
        }
        n = split(res, rt, " ")
        for (i = 1; i <= n; i++) {
          t = rt[i]
          if (t == "secret" || t == "shared_branch") vocab[t] = 1
          else vocab[esc(t)] = 1
        }
      }
      END {
        re = ""
        for (t in vocab) re = (re == "" ? t : re "|" t)
        if (re != "") print "re=" re
      }
    ' ${files[@]+"${files[@]}"} > "$cache.tmp.$$" 2>/dev/null; then
      rm -f "$cache.tmp.$$" 2>/dev/null; return 0
    fi
    mv -f "$cache.tmp.$$" "$cache" 2>/dev/null || { rm -f "$cache.tmp.$$" 2>/dev/null; return 0; }
  fi
  local re="" slug tokn bound=0
  [ -n "$active_company" ] && bound=1
  case "$cwd" in *companies/*) bound=1 ;; esac
  [ -n "${HQ_POLICY_COMPANY:-}" ] && bound=1
  while IFS= read -r line; do
    case "$line" in
      unsafe=*) return 0 ;;
      re=*) re="${line#re=}" ;;
      struct=*)
        slug="${line#struct=}"; tokn="${slug##*:}"; slug="${slug%:*}"
        case "$tokn" in
          company) [ "$bound" -eq 1 ] || continue ;;
          repo) case "$cwd" in *repos/public/*|*repos/private/*) ;; *) continue ;; esac ;;
        esac
        case "$ledger" in *"$slug"*) continue ;; esac
        return 0
        ;;
    esac
  done < "$cache"
  [ -n "$re" ] || return 1
  case "|$re|" in
    *"|shared_branch|"*) branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)" ;;
  esac
  if ! derived_facts="$(printf '%s\n' "$text" | awk -v mode=derived -v branch="$branch" -f "$root/core/scripts/lib/trigger-fact-text.awk")"; then
    # Missing or unreadable shared fact source cannot justify a prefilter skip.
    return 0
  fi
  shopt -s nocasematch
  if [[ "$text" =~ $re ]] || [[ " $derived_facts " =~ [[:space:]]($re)[[:space:]] ]]; then
    shopt -u nocasematch
    return 0
  fi
  shopt -u nocasematch
  return 1
}

# hqad_registry_prefilter_match sets HQAD_PREFILTER_REASON and returns 1 only
# when a valid prefilter proves that a hook cannot match this event. Invalid
# regex syntax reports a named error and keeps the guard in the dispatch set.
hqad_registry_prefilter_match() {
  local event="$1" root="$2" active_company="$3" cwd="$4" session_id="$5" text="$6"
  local re="$7" env_name="$8" file="$9" vocab="${10}" hook_id="${11}"
  local status nocasematch_was_on=0 invalid_prefilter=0 skip_reason=""
  HQAD_PREFILTER_REASON=""
  if [ -n "$env_name" ]; then
    if ! [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      printf "ERROR: hqad: malformed env prefilter for hook '%s'; running hook fail-closed.\n" "$hook_id" >&2
      invalid_prefilter=1
    elif [ -z "${!env_name:-}" ]; then
      skip_reason="env"
    fi
  fi
  if [ -n "$file" ]; then
    case "$file" in
      /*|../*|*/../*|*/..)
        printf "ERROR: hqad: unsafe file prefilter for hook '%s'; running hook fail-closed.\n" "$hook_id" >&2
        invalid_prefilter=1
        ;;
      *)
        if [ ! -e "$root/$file" ]; then
          [ -n "$skip_reason" ] || skip_reason="file"
        fi
        ;;
    esac
  fi
  if [ -n "$re" ]; then
    shopt -q nocasematch && nocasematch_was_on=1
    shopt -s nocasematch
    if [[ "$text" =~ $re ]]; then
      status=0
    else
      # Preserve Bash's regex compile-failure status (2) for fail-closed input.
      # shellcheck disable=SC2319
      status=$?
    fi
    if [ "$nocasematch_was_on" -eq 0 ]; then shopt -u nocasematch; fi
    if [ "$status" -eq 1 ]; then
      [ -n "$skip_reason" ] || skip_reason="prefilter"
    elif [ "$status" -gt 1 ]; then
      printf "ERROR: hqad: malformed regex prefilter for hook '%s'; running hook fail-closed.\n" "$hook_id" >&2
      invalid_prefilter=1
    fi
  fi
  # A malformed condition cannot prove that the hook is irrelevant. Defer all
  # valid non-match results until every prefilter has been checked so malformed
  # input always keeps the guard in the dispatch set.
  [ "$invalid_prefilter" -eq 0 ] || return 0
  if [ -n "$skip_reason" ]; then
    HQAD_PREFILTER_REASON="$skip_reason"
    return 1
  fi
  if [ "$vocab" = "1" ] && ! hqad_policy_prefilter_check "$root" "$event" "$active_company" "$cwd" "$session_id" "$text"; then
    HQAD_PREFILTER_REASON="policy-vocab"
    return 1
  fi
  return 0
}

# Resolve the active company without creating session state. Invalid session
# identifiers cannot escape workspace/sessions and disable only the skip
# optimization (the policy injector still runs).
hqad_active_company() {
  local root="$1" session_id="$2" metadata
  case "$session_id" in ''|*[!A-Za-z0-9._-]*|.|..) return 0 ;; esac
  metadata="$root/workspace/sessions/$session_id/meta.yaml"
  [ -r "$metadata" ] || return 0
  local company
  company="$(awk '$1 == "company_slug:" { sub(/^[^:]+:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }' "$metadata" 2>/dev/null)"
  case "$company" in *[!A-Za-z0-9_-]*|.|..) return 0 ;; esac
  printf '%s' "$company"
}

HQAD_EVENT_WATCHDOG_STARTED="${HQAD_EVENT_WATCHDOG_STARTED:-0}"
HQAD_EVENT_WATCHDOG_PIDS=()
HQAD_EVENT_WATCHDOG_SESSIONS=()
HQAD_EVENT_WATCHDOG_ACTIVE_FILE=""
HQAD_EVENT_WATCHDOG_INVOCATION_ID=""
HQAD_PATH_AUGMENTED="${HQAD_PATH_AUGMENTED:-0}"

hqad_event_watchdog_disabled() {
  local entry remaining="${HQ_DISABLED_HOOKS:-}"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      *,*) entry="${remaining%%,*}"; remaining="${remaining#*,}" ;;
      *) entry="$remaining"; remaining="" ;;
    esac
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ "$entry" = "hook-timeout-sentry" ] && return 0
  done
  return 1
}

hqad_event_watchdog_enabled() {
  case "${HQ_HOOK_TIMEOUT_SENTRY:-1}" in
    0|false|FALSE|no|NO|off|OFF) return 1 ;;
  esac
  hqad_event_watchdog_disabled && return 1
  [ -f "${HQ_ROOT:-}/.claude/hooks/hook-timeout-watchdog.sh" ]
}

hqad_event_watchdog_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s\0' "$@" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s\0' "$@" | sha256sum 2>/dev/null | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s\0' "$@" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
  fi
}

hqad_event_watchdog_now_ms() {
  local realtime seconds fraction now
  realtime="${EPOCHREALTIME:-}"
  if [ -n "$realtime" ]; then
    seconds="${realtime%%.*}"
    fraction="${realtime#*.}"
    fraction="${fraction}000"
    fraction="${fraction:0:3}"
    if [[ "$seconds" =~ ^[0-9]+$ ]] && [[ "$fraction" =~ ^[0-9]{3}$ ]]; then
      printf '%s%s' "$seconds" "$fraction"
      return 0
    fi
  fi
  now="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$now" =~ ^[0-9]+$ ]] && [ "${#now}" -gt 10 ]; then
    printf '%s' "$now"
    return 0
  fi
  if command -v perl >/dev/null 2>&1; then
    now="$(perl -MTime::HiRes=time -e 'printf "%.0f", time() * 1000' 2>/dev/null || true)"
    if [[ "$now" =~ ^[0-9]+$ ]]; then
      printf '%s' "$now"
      return 0
    fi
  fi
  now="$(date +%s 2>/dev/null || printf '0')"
  [[ "$now" =~ ^[0-9]+$ ]] || now=0
  printf '%s000' "$now"
}

# One pair of existing master-dispatch watchdogs covers all gated hooks in an
# adapter event. The active-child receipt lets the existing reporter attribute
# a warning to the hook body that was running when the threshold elapsed.
hqad_event_watchdog_start() {
  local root="$1" event="$2" payload="$3" session_id="$4"
  local watchdog started_at threshold session invocation
  [ "$HQAD_EVENT_WATCHDOG_STARTED" = "0" ] || return 0
  HQAD_EVENT_WATCHDOG_STARTED=1
  hqad_event_watchdog_enabled || return 0
  watchdog="$root/.claude/hooks/hook-timeout-watchdog.sh"
  started_at="${EPOCHSECONDS:-$(date +%s 2>/dev/null || printf '0')}"
  invocation="$(hqad_event_watchdog_sha256 "$$" "$started_at" "$event" "${session_id:-unknown}")"
  [ -n "$invocation" ] || invocation="$$-$started_at"
  case "$invocation" in *[!A-Za-z0-9._-]*) invocation="$$-$started_at" ;; esac
  HQAD_EVENT_WATCHDOG_INVOCATION_ID="$invocation"
  if [ -n "$session_id" ]; then
    local session_hash journal_file
    session_hash="$(hqad_event_watchdog_sha256 "$session_id")"
    if [ -n "$session_hash" ]; then
      journal_file="$root/workspace/.hook-timeout-journal/$session_hash.tsv"
      mkdir -p "${journal_file%/*}" >/dev/null 2>&1 || journal_file=""
      [ -z "$journal_file" ] || HQAD_EVENT_WATCHDOG_ACTIVE_FILE="$journal_file.$invocation.active"
    fi
  fi
  for threshold in absolute relative; do
    session=0
    if command -v setsid >/dev/null 2>&1; then
      setsid bash "$watchdog" \
        --root "$root" \
        --source master-dispatch \
        --hook-path "$root/.claude/hooks/master-hook.sh" \
        --event "$event" \
        --threshold "$threshold" \
        --started-at "$started_at" \
        --invocation-id "$invocation" \
        --parent-pid "$$" \
        >/dev/null 2>&1 <<<"$payload" &
      session=1
    else
      bash "$watchdog" \
        --root "$root" \
        --source master-dispatch \
        --hook-path "$root/.claude/hooks/master-hook.sh" \
        --event "$event" \
        --threshold "$threshold" \
        --started-at "$started_at" \
        --invocation-id "$invocation" \
        --parent-pid "$$" \
        >/dev/null 2>&1 <<<"$payload" &
    fi
    HQAD_EVENT_WATCHDOG_PIDS+=("$!")
    HQAD_EVENT_WATCHDOG_SESSIONS+=("$session")
  done
  trap hqad_event_watchdog_stop EXIT
}

hqad_event_watchdog_child_start() {
  local script="$1" event="$2" started_ms
  [ -n "$HQAD_EVENT_WATCHDOG_ACTIVE_FILE" ] || return 0
  script="${script##*/}"
  case "$script" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$event" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$HQAD_EVENT_WATCHDOG_INVOCATION_ID" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  started_ms="$(hqad_event_watchdog_now_ms)"
  [[ "$started_ms" =~ ^[0-9]+$ ]] || return 0
  printf '%s\t%s\t%s\n' "$script" "$event" "$started_ms" > "$HQAD_EVENT_WATCHDOG_ACTIVE_FILE" 2>/dev/null || true
}

hqad_event_watchdog_child_end() {
  [ -n "$HQAD_EVENT_WATCHDOG_ACTIVE_FILE" ] || return 0
  : > "$HQAD_EVENT_WATCHDOG_ACTIVE_FILE" 2>/dev/null || true
}

# shellcheck disable=SC2329 # Called from an EXIT trap installed by start.
hqad_event_watchdog_stop() {
  local i pid session
  for i in "${!HQAD_EVENT_WATCHDOG_PIDS[@]}"; do
    pid="${HQAD_EVENT_WATCHDOG_PIDS[$i]}"
    session="${HQAD_EVENT_WATCHDOG_SESSIONS[$i]}"
    if [ "$session" -eq 1 ]; then
      kill -TERM "$pid" >/dev/null 2>&1 || true
      kill -TERM -- "-$pid" >/dev/null 2>&1 || true
    else
      kill "$pid" >/dev/null 2>&1 || true
    fi
    wait "$pid" >/dev/null 2>&1 || true
  done
  HQAD_EVENT_WATCHDOG_PIDS=()
  HQAD_EVENT_WATCHDOG_SESSIONS=()
  if [ -n "$HQAD_EVENT_WATCHDOG_ACTIVE_FILE" ]; then
    rm -f "$HQAD_EVENT_WATCHDOG_ACTIVE_FILE" >/dev/null 2>&1 || true
  fi
}

# Dispatch one gated hook body without starting hook-gate.sh. Profile membership
# and disabled ids are still evaluated through hook-gate.sh --lib, and a missing
# profile library falls back to the original gate path.
hqad_launch_registered_hook() {
  local root="$1" event="$2" payload="$3" hook_id="$4" script="$5" profile_status status=0
  shift 5
  if ! command -v hq_hook_profile_allows >/dev/null 2>&1 \
    || ! command -v hq_launch_shell_path >/dev/null 2>&1; then
    if command -v hq_launch_shell_path >/dev/null 2>&1; then
      hq_launch_shell_path "$root" "$root/.claude/hooks/hook-gate.sh" "$payload" "$hook_id" "$script" "$@"
      return $?
    fi
    printf '%s' "$payload" | bash "$root/.claude/hooks/hook-gate.sh" "$hook_id" "$script" "$@"
    return "${PIPESTATUS[1]}"
  fi
  hq_hook_profile_allows "$hook_id"
  profile_status=$?
  case "$profile_status" in
    0) ;;
    1) return 0 ;;
    2) printf "ERROR: Unknown profile '%s'. Use minimal|standard|strict\n" "${HQ_HOOK_PROFILE:-}" >&2; return 1 ;;
    *) printf "ERROR: hqad: profile gate failed for hook '%s' (status %s).\n" "$hook_id" "$profile_status" >&2; return 1 ;;
  esac
  if [ "$HQAD_PATH_AUGMENTED" = "0" ] && command -v hq_augment_path >/dev/null 2>&1; then
    hq_augment_path
    HQAD_PATH_AUGMENTED=1
  fi
  hqad_event_watchdog_start "$root" "$event" "$payload" "${HQAD_EVENT_SESSION_ID:-}"
  hqad_event_watchdog_child_start "$script" "$event"
  hq_launch_shell_path "$root" "$script" "$payload" "$@" || status=$?
  hqad_event_watchdog_child_end
  return "$status"
}

# Parse the same prefilter input text as master-hook: object tool_input JSON,
# otherwise the prompt, plus PostToolUse tool_response JSON; flatten record
# separators and newlines before regex matching.
hqad_prefilter_payload_fields() {
  local event="$1" payload="$2" encoded
  encoded="$(printf '%s' "$payload" | jq -r --arg ev "$event" '
    [
      (if (.cwd | type) == "string" then .cwd else "" end),
      (if (.session_id | type) == "string" then .session_id else "" end),
      ((if $ev == "UserPromptSubmit" then (.prompt // "")
        elif (.tool_input | type) == "object" then (.tool_input | tojson)
        else (.prompt // "") end)
       + (if $ev == "PostToolUse" and .tool_response != null then " " + (.tool_response | tojson) else "" end))
    ]
    | map(if type == "string" then gsub("\\u001f|\\n"; " ") else "" end)
    | @sh
  ' 2>/dev/null)" || return 1
  printf '%s' "$encoded"
}

# Classify a single (already $CLAUDE_PROJECT_DIR-expanded) settings.json command
# string into a tab-separated dispatch record. settings.json commands are
# release-owned and are the exact strings Claude executes verbatim, so splitting
# them with the shell's own quoting rules (via eval) is safe and, unlike a naive
# word-split, correctly preserves an install path that contains spaces
# (tested: hook-path-resolution.test.sh). We still guard the shape first.
hqad_classify_command() {
  local command="$1"
  # Only ever eval a command of the expected shape: `bash "<abs>/…/*.sh" …`.
  case "$command" in
    bash\ *) ;;
    *) return 0 ;;
  esac
  local rest="${command#bash }"
  local -a toks=()
  eval "toks=( $rest )" 2>/dev/null || return 0
  [ "${#toks[@]}" -ge 1 ] || return 0
  local script="${toks[0]}"
  case "$script" in
    */hook-gate.sh)
      # toks: [gate.sh] [hook-id] [script] [extra-args...]
      [ "${#toks[@]}" -ge 3 ] || return 0
      # Skip records whose hook script is absent: in real installs every hook is
      # present, but a partial tree (or a renamed hook) must not turn into a
      # spurious deny when the gate runs a missing file.
      [ -f "${toks[2]}" ] || return 0
      printf 'gate\t%s\t%s' "${toks[1]}" "${toks[2]}"
      local i
      for ((i = 3; i < ${#toks[@]}; i++)); do
        printf '\t%s' "${toks[i]}"
      done
      printf '\n'
      ;;
    */master-hook.sh)
      # toks: [master-hook.sh] [event]
      printf 'master\t%s\n' "${toks[1]:-}"
      ;;
    *)
      # Bare script (e.g. reindex.sh), no gate wrapper.
      [ -f "$script" ] || return 0
      printf 'script\t%s\n' "$script"
      ;;
  esac
}

# Fail-closed safety net. If settings.json is missing or unparseable, the
# adapters must NOT silently run zero guards (that would fail OPEN — worse than
# the drift this design removes). Emit the critical PreToolUse guards directly
# so protection survives a corrupt/absent settings.json. Non-PreToolUse events
# degrade to no-ops (they carry no hard guards). Missing scripts are skipped.
hqad_fallback_records() {
  local event="$1" tool="$2" ids="" id script
  [ "$event" = "PreToolUse" ] || return 0
  case "$tool" in
    Bash) ids="mandatory-scope-authorizer detect-secrets block-env-dump block-core-writes-bash block-policy-writes-bash block-hq-root-git-mutation block-unsafe-package-install block-qmd-model-download" ;;
    Read) ids="mandatory-scope-authorizer warn-cross-company-settings" ;;
    Grep) ids="mandatory-scope-authorizer block-hq-grep" ;;
    Glob) ids="mandatory-scope-authorizer block-hq-glob" ;;
    Edit|Write) ids="protect-core block-core-writes block-inline-story-impl env-file-no-trailing-newline" ;;
    *) return 0 ;;
  esac
  for id in $ids; do
    script="$HQ_ROOT/.claude/hooks/$id.sh"
    [ -f "$script" ] || continue
    printf 'gate\t%s\t%s\n' "$id" "$script"
  done
}

# Emit gate/script records for (event, canonical_tool) from hook-registry.json.
hqad_iter_registry() {
  local event="$1" tool="$2" payload="${3:-}"
  [ -n "$payload" ] || payload='{}'
  local registry="$HQ_ROOT/.claude/hooks/hook-registry.json"
  [ -f "$registry" ] || return 0
  local fields="" payload_cwd="" session_id="" prefilter_text="" active_company=""
  local rows="" line decoded matcher id script gated args pf_re pf_env pf_file pf_vocab
  if ! fields="$(hqad_prefilter_payload_fields "$event" "$payload")"; then
    [ -z "${HQ_HOOK_TRACE:-}" ] || printf 'hook-adapter: prefilter payload parse failed event=%s bytes=%s\n' "$event" "${#payload}" >&2
    printf "ERROR: hqad: malformed payload for %s registry prefilters; using critical fallback guards.\n" "$event" >&2
    hqad_fallback_records "$event" "$tool"
    return 0
  fi
  eval "set -- $fields" 2>/dev/null || {
    printf "ERROR: hqad: malformed payload frame for %s registry prefilters; using critical fallback guards.\n" "$event" >&2
    hqad_fallback_records "$event" "$tool"
    return 0
  }
  if [ "$#" -ne 3 ]; then
    printf "ERROR: hqad: malformed payload fields for %s registry prefilters; using critical fallback guards.\n" "$event" >&2
    hqad_fallback_records "$event" "$tool"
    return 0
  fi
  payload_cwd="$1"; session_id="$2"; prefilter_text="$3"
  active_company="$(hqad_active_company "$HQ_ROOT" "$session_id")"

  rows="$(jq -r --arg ev "$event" '
    (.hooks[$ev] // []) as $entries
    | if ($entries | type) != "array" then error("event registrations must be an array") else $entries[] end
    | . as $entry
    | ($entry.matcher // "") as $matcher
    | if (($matcher | type) != "string") or (($entry.hooks // []) | type) != "array"
      then error("registration shape is invalid") else ($entry.hooks // [])[] end
    | . as $hook
    | ($hook.prefilter // {}) as $pf
    | ($hook.args // []) as $args
    | if (($hook.id | type) != "string") or (($hook.script | type) != "string")
        or (($hook.gated != null) and (($hook.gated | type) != "boolean"))
        or (($pf | type) != "object")
        or (($pf.re // "") | type) != "string"
        or (($pf.env // "") | type) != "string"
        or (($pf.file // "") | type) != "string"
        or (($pf.policy_vocab != null) and (($pf.policy_vocab | type) != "boolean"))
        or (($args | type) != "array")
        or ([$matcher, $hook.id, $hook.script, ($pf.re // ""), ($pf.env // ""), ($pf.file // "")] | any(contains("\u0000") or contains("\n") or contains("\u001f")))
        or ([$args[]?] | any(type != "string" or contains("\u0000") or contains("\n") or contains("\u001f")))
      then error("registry record is malformed")
      else "hqad-reg " + ([$matcher, $hook.id, $hook.script, (if $hook.gated == false then "0" else "1" end), (($args) | join(" ")), ($pf.re // ""), ($pf.env // ""), ($pf.file // ""), (if $pf.policy_vocab == true then "1" else "" end)] | @sh)
      end
  ' "$registry" 2>/dev/null)" || {
    printf "ERROR: hqad: malformed hook-registry.json event '%s'; using critical fallback guards.\n" "$event" >&2
    hqad_fallback_records "$event" "$tool"
    return 0
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "hqad-reg "*) decoded="${line#hqad-reg }" ;;
      *) continue ;;
    esac
    eval "set -- $decoded" 2>/dev/null || continue
    [ "$#" -eq 9 ] || {
      printf "ERROR: hqad: malformed registry frame for event '%s'; using critical fallback guards.\n" "$event" >&2
      hqad_fallback_records "$event" "$tool"
      return 0
    }
    matcher="$1"; id="$2"; script="$HQ_ROOT/$3"; gated="$4"; args="$5"
    pf_re="$6"; pf_env="$7"; pf_file="$8"; pf_vocab="$9"
    if [ -n "${HQ_HOOK_TRACE:-}" ]; then
      printf 'hook-adapter: prefilter %s re=%s env=%s file=%s policy_vocab=%s\n' \
        "$id" "$([ -n "$pf_re" ] && printf yes || printf no)" \
        "$([ -n "$pf_env" ] && printf yes || printf no)" \
        "$([ -n "$pf_file" ] && printf yes || printf no)" \
        "$([ "$pf_vocab" = "1" ] && printf yes || printf no)" >&2
    fi
    hqad_matcher_matches "$matcher" "$tool" "$event" || continue
    [ -f "$script" ] || continue
    if ! hqad_registry_prefilter_match "$event" "$HQ_ROOT" "$active_company" "$payload_cwd" "$session_id" "$prefilter_text" "$pf_re" "$pf_env" "$pf_file" "$pf_vocab" "$id"; then
      case "$HQAD_PREFILTER_REASON" in
        prefilter|policy-vocab)
          [ -z "${HQ_HOOK_TRACE:-}" ] || printf 'hook-adapter: skip %s (%s)\n' "$id" "$HQAD_PREFILTER_REASON" >&2
          ;;
      esac
      continue
    fi
    if [ "$gated" = "1" ]; then
      printf 'gate\t%s\t%s' "$id" "$script"
      if [ -n "$args" ]; then
        # shellcheck disable=SC2086 # registry args are space-separated literals.
        set -- $args
        printf '\t%s' "$@"
      fi
      printf '\n'
    else
      printf 'script\t%s\n' "$script"
    fi
  done <<HQAD_ROWS
$rows
HQAD_ROWS
}

# Emit the classified dispatch records for (event, canonical_tool) from
# settings.json, in registration order (settings.json array order == Claude's
# dispatch order), which this preserves.
hqad_iter_settings() {
  local event="$1" tool="$2" payload="${3:-}"
  [ -n "$payload" ] || payload='{}'
  local settings="$HQ_ROOT/.claude/settings.json"
  # Fail closed: an absent settings.json / missing jq must NOT disable guards
  # (that would fail open — worse than the drift this design removes).
  if [ -z "$HQ_ROOT" ] || [ ! -f "$settings" ] || ! command -v jq >/dev/null 2>&1; then
    hqad_fallback_records "$event" "$tool"
    return 0
  fi
  # A present-but-corrupt settings.json also degrades to the critical guard set.
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    hqad_fallback_records "$event" "$tool"
    return 0
  fi

  # Use jq's shell-escaped words with a plain-text record prefix. A literal
  # control-byte delimiter here is not portable to Bash 3.2 (stock macOS), and
  # a producer behind process substitution can fail without making the while
  # loop fail. Capture jq first so query and framing failures fail closed.
  local rows="" line decoded matcher command frame_failed=0
  if ! rows="$(jq -r --arg ev "$event" '
    (.hooks[$ev] // [])[]
    | (.matcher // "") as $m
    | (.hooks // [])[]
    | select(.type == "command" and (.command | type == "string"))
    | if (($m | type) != "string")
        or ([$m, .command] | any(contains("\u0000") or contains("\n")))
      then error("hook dispatch record contains an unsupported byte")
      else "hqad-record " + ([$m, .command] | @sh)
      end
  ' "$settings" 2>/dev/null)"; then
    hqad_fallback_records "$event" "$tool"
    return 0
  fi

  # Validate every frame before emitting anything. This prevents a malformed
  # later row from partially dispatching settings and then duplicating guards
  # through the fallback set.
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      "hqad-record "*) decoded="${line#hqad-record }" ;;
      *) frame_failed=1; break ;;
    esac
    # jq's @sh output is shell-escaped data, not executable settings content;
    # eval only restores the two original strings as positional parameters.
    eval "set -- $decoded" 2>/dev/null || {
      frame_failed=1
      break
    }
    if [ "$#" -ne 2 ]; then
      frame_failed=1
      break
    fi
  done <<EOF
$rows
EOF

  if [ "$frame_failed" -ne 0 ]; then
    hqad_fallback_records "$event" "$tool"
    return 0
  fi

  # Gated project hooks live in .claude/hooks/hook-registry.json and are
  # dispatched in-process by master-hook.sh for Claude Code. The adapters keep
  # dispatching them one by one through hook-gate.sh (their per-hook
  # blocking/advisory handling depends on that), so emit registry records
  # here in registry order, ahead of the settings records. master-hook.sh
  # skips the registry when HQ_HARNESS is codex or grok, so nothing double
  # fires. A missing or unreadable registry simply contributes no records.
  hqad_iter_registry "$event" "$tool" "$payload"

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    decoded="${line#hqad-record }"
    eval "set -- $decoded" 2>/dev/null
    matcher="$1"
    command="$2"
    [ -n "$command" ] || continue
    hqad_matcher_matches "$matcher" "$tool" "$event" || continue
    # Expand $CLAUDE_PROJECT_DIR (quoted and bare) to the resolved HQ root so
    # the classifier sees absolute script paths.
    command="${command//\"\$CLAUDE_PROJECT_DIR\"/\"$HQ_ROOT\"}"
    command="${command//\$CLAUDE_PROJECT_DIR/$HQ_ROOT}"
    hqad_classify_command "$command"
  done <<EOF
$rows
EOF
}

# blocking|advisory for a hook. Event default + optional per-hook frontmatter
# override. Never returns blocking for a non-PreToolUse event.
hqad_mode_for() {
  local event="$1" script="$2" id fm=""
  case "$event" in
    PreToolUse) : ;;
    *) printf 'advisory'; return 0 ;;
  esac
  # settings.json cannot express blocking-vs-advisory, so this is the single
  # source for it. These context/warn hooks are advisory on PreToolUse: they
  # only inject context or warn, so a non-zero exit must NEVER block a tool.
  # Keyed by hook id so a test stub (which lacks the real hook body) classifies
  # identically to production.
  id="$(basename "$script" 2>/dev/null)"
  id="${id%.sh}"
  case "$id" in
    inject-policy-on-trigger|warn-cross-company-settings|surface-company-infra-policy)
      printf 'advisory'; return 0 ;;
  esac
  # Extension point: any other hook may self-declare with a
  # "# hq-hook-mode: advisory" (or blocking) frontmatter line.
  if [ -n "$script" ] && [ -f "$script" ]; then
    fm="$(sed -n 's/^#[[:space:]]*hq-hook-mode:[[:space:]]*//p' "$script" 2>/dev/null | head -n1 | tr -d '[:space:]')"
  fi
  case "$fm" in
    advisory) printf 'advisory'; return 0 ;;
    blocking) printf 'blocking'; return 0 ;;
  esac
  printf 'blocking'
}
