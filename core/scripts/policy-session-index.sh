# Session-pinned policy index. Sourced by inject-policy-on-trigger.sh only
# when the per-person flag is on (and on SessionEnd for cleanup). Default-off
# callers never source this file for an emit.
#
# The index lives at
# workspace/orchestrator/policy-session-index/<session>--<company>.json
# so one session cannot mix two companies' rules. SessionEnd removes that
# session's files, and an age sweep removes files a crashed session left.
# Full text is not stored; each entry is a slug, a weight, a topic, and one
# line. The model pulls the rule with hq-policy get <slug>.
#
# Cost: one awk over the matched policy files (must-fire and topic metadata),
# one jq for the merge and render, one awk for must-fire bodies, and one jq
# to wrap PostToolUse output. No per-row process.

policy_session_index_int() {
  local raw="$1" fallback="$2"
  case "$raw" in
    ''|*[!0-9]*) printf '%s' "$fallback" ;;
    *) printf '%s' "$raw" ;;
  esac
}

# Reads every_turns, cap, recent_turns and sweep_days in one pass over the
# core file, then the personal file, so a personal value wins. Sets PSI_*.
policy_session_index_settings() {
  local file line key value
  PSI_EVERY=""
  PSI_CAP=""
  PSI_RECENT=""
  PSI_SWEEP_DAYS=""
  for file in \
    "$HQ_ROOT/core/settings/policy-session-index.yaml" \
    "$HQ_ROOT/personal/settings/policy-session-index.yaml"
  do
    [ -f "$file" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      line="${line%$'\r'}"
      case "$line" in
        *:*) ;;
        *) continue ;;
      esac
      key="${line%%:*}"
      value="${line#*:}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      case "$value" in ''|*[!0-9]*) continue ;; esac
      case "$key" in
        every_turns) PSI_EVERY="$value" ;;
        cap) PSI_CAP="$value" ;;
        recent_turns) PSI_RECENT="$value" ;;
        sweep_days) PSI_SWEEP_DAYS="$value" ;;
      esac
    done < "$file"
  done
  case "${HQ_POLICY_SESSION_INDEX_EVERY:-}" in ''|*[!0-9]*) ;; *) PSI_EVERY="$HQ_POLICY_SESSION_INDEX_EVERY" ;; esac
  case "${HQ_POLICY_SESSION_INDEX_CAP:-}" in ''|*[!0-9]*) ;; *) PSI_CAP="$HQ_POLICY_SESSION_INDEX_CAP" ;; esac
  case "${HQ_POLICY_SESSION_INDEX_RECENT:-}" in ''|*[!0-9]*) ;; *) PSI_RECENT="$HQ_POLICY_SESSION_INDEX_RECENT" ;; esac
  case "${HQ_POLICY_SESSION_INDEX_SWEEP_DAYS:-}" in ''|*[!0-9]*) ;; *) PSI_SWEEP_DAYS="$HQ_POLICY_SESSION_INDEX_SWEEP_DAYS" ;; esac
  [ -n "$PSI_EVERY" ] || PSI_EVERY=25
  [ -n "$PSI_CAP" ] || PSI_CAP=40
  [ -n "$PSI_RECENT" ] || PSI_RECENT=25
  [ -n "$PSI_SWEEP_DAYS" ] || PSI_SWEEP_DAYS=7
  [ "$PSI_CAP" -ge 1 ] || PSI_CAP=40
  [ "$PSI_SWEEP_DAYS" -ge 1 ] || PSI_SWEEP_DAYS=7
}

# Sets PSI_DIR and PSI_SID. A missing session id returns 1: the caller then
# keeps today's reminder, so sessions without an id never share one file.
# An id with unsafe characters maps to a checksum of itself.
policy_session_index_paths() {
  local raw="${SESSION_ID:-}" sum
  PSI_DIR="$HQ_ROOT/workspace/orchestrator/policy-session-index"
  [ -n "$raw" ] || return 1
  case "$raw" in
    *[!A-Za-z0-9._-]*|*..*|.*)
      sum="$(printf '%s' "$raw" | cksum 2>/dev/null)" || return 1
      sum="${sum%% *}"
      [ -n "$sum" ] || return 1
      PSI_SID="h$sum"
      ;;
    *) PSI_SID="$raw" ;;
  esac
  return 0
}

policy_session_index_company() {
  PSI_COMPANY="${co_scope:-${HQ_POLICY_COMPANY:-}}"
  case "$PSI_COMPANY" in
    ""|*[!A-Za-z0-9._-]*|*..*|.*) PSI_COMPANY="unscoped" ;;
  esac
}

policy_session_index_release_lock() {
  local lock="$1" holder=""
  holder="$(cat "$lock/pid" 2>/dev/null || true)"
  # A lock reclaimed by another process while this one was slow is theirs.
  [ -z "$holder" ] || [ "$holder" = "$$" ] || return 0
  rm -f "$lock/pid" "$lock/time" "$lock/token" 2>/dev/null || true
  rmdir "$lock" 2>/dev/null || true
}

# Index files older than sweep_days belong to sessions that ended without a
# SessionEnd (crash, killed host). Lock dirs older than an hour are dead.
policy_session_index_sweep() {
  [ -d "$PSI_DIR" ] || return 0
  find "$PSI_DIR" -maxdepth 1 -type f \( -name '*.json' -o -name '*.json.tmp.*' -o -name '*.json.bad.*' \) \
    -mtime +"$PSI_SWEEP_DAYS" -exec rm -f {} + 2>/dev/null || true
  find "$PSI_DIR" -maxdepth 1 -type d -name '*.json.lock' -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true
}

policy_session_index_cleanup() {
  local end_file
  [ -n "${PSI_SWEEP_DAYS:-}" ] || policy_session_index_settings
  PSI_DIR="$HQ_ROOT/workspace/orchestrator/policy-session-index"
  [ -d "$PSI_DIR" ] || return 0
  if policy_session_index_paths; then
    for end_file in "$PSI_DIR/${PSI_SID}--"*.json; do
      [ -f "$end_file" ] || continue
      rm -f "$end_file" 2>/dev/null || true
      rm -rf "${end_file}.lock" 2>/dev/null || true
    done
  fi
  policy_session_index_sweep
  return 0
}

policy_session_index_stat() {
  local kind="$1" bytes="$2" named="$3"
  [ -n "${STATS_DIR:-}" ] || return 0
  { [ -d "$STATS_DIR" ] || mkdir -p "$STATS_DIR"; } 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" \
    "${EVENT:-unknown}" "$bytes" "$named" "$kind" \
    >> "$STATS_DIR/${SESSION_ID:-unknown}.txt" 2>/dev/null || true
}

# Bytes the PostToolUse JSON envelope adds around a context string. jq -c
# keeps UTF-8 as is, so only escapes and the fixed wrapper add bytes.
policy_session_index_json_bytes() {
  local s="$1" esc pat nl=$'\n' tab=$'\t' cr=$'\r'
  policy_value_bytes "$s"
  PSI_JSON_BYTES=$((POLICY_VALUE_BYTES + 77))
  pat="[^\\\\\"${nl}${tab}${cr}]"
  esc="${s//$pat/}"
  PSI_JSON_BYTES=$((PSI_JSON_BYTES + ${#esc}))
}

# Bytes this context costs on stdout for the current event, with the final
# newline.
policy_session_index_out_bytes() {
  if [ "$EVENT" = "PostToolUse" ]; then
    policy_session_index_json_bytes "$1"
    PSI_OUT_BYTES=$((PSI_JSON_BYTES + 1))
  else
    policy_value_bytes "$1"
    PSI_OUT_BYTES=$((POLICY_VALUE_BYTES + 1))
  fi
}

policy_session_index_quote_line() {
  local line="$1"
  line="${line//<\/policy-reminder>/[/policy-reminder]}"
  line="${line//<policy-reminder>/[policy-reminder]}"
  line="${line//<\/policy-index>/[/policy-index]}"
  line="${line//<policy-index>/[policy-index]}"
  case "$line" in
    'Policy `'*) line="Policy: ${line#Policy }" ;;
  esac
  if [ -z "$line" ]; then
    PSI_QUOTED+=">"$'\n'
  else
    PSI_QUOTED+="> $line"$'\n'
  fi
}

# Must-fire block. Same budget as the base reminder: full text up to
# HQ_POLICY_HARD_BUDGET_BYTES (5120), never more than the ceiling minus a
# 1400-byte reserve for the index lines; a body over HQ_POLICY_HARD_MAX_BYTES
# falls back to its Rule section, then is cut. A body that does not fit is
# withheld by name, never silently.
# A rule whose full text was already shown in this epoch is listed on one
# "still binding" line instead.
#   $1 newline list of "full|ref<TAB>slug<TAB>path<TAB>line", $2 budget,
#   $3 hard_max, $4 how many bodies to keep at most (-1 = no limit).
policy_session_index_mustfire_block() {
  local list="$1" budget="$2" hard_max="$3" keep_max="$4"
  local kind slug path line paths="" body used=0 kept=0 withheld="" rec refs=""
  local -a mf_slugs=() mf_paths=() mf_lines=()
  PSI_MF_BLOCK=""
  [ -n "$list" ] || return 0
  while IFS=$'\t' read -r kind slug path line; do
    [ -n "$slug" ] || continue
    if [ "$kind" = "ref" ]; then
      refs+="${refs:+, }\`$slug\`"
      continue
    fi
    mf_slugs+=("$slug")
    mf_paths+=("$path")
    mf_lines+=("$line")
  done <<< "$list"
  if [ "${#mf_slugs[@]}" -eq 0 ]; then
    [ -n "$refs" ] || return 0
    PSI_MF_BLOCK="<policy-reminder>"$'\n'"> Still binding, shown earlier: ${refs}."$'\n'"</policy-reminder>"
    return 0
  fi

  # One awk for every body. Output: path US body RS, per readable file.
  local bodies="" i
  local -a readable=()
  for i in "${!mf_paths[@]}"; do
    [ -n "${mf_paths[$i]}" ] && [ -r "${mf_paths[$i]}" ] && readable+=("${mf_paths[$i]}")
  done
  if [ "${#readable[@]}" -gt 0 ]; then
    bodies="$(LC_ALL=C awk -v limit="$hard_max" '
      function flush(   n, i, all, rule, keep, out) {
        if (cur == "") return
        all = ""; rule = ""; keep = 0
        for (i = 1; i <= nl; i++) {
          all = all (i > 1 ? "\n" : "") L[i]
          if (L[i] ~ /^## Rule[ \t]*$/) keep = 1
          else if (L[i] ~ /^## / && keep == 1) keep = 2
          if (keep == 1) rule = rule (rule == "" ? "" : "\n") L[i]
        }
        if (length(all) <= limit) out = all
        else if (rule != "" && length(rule) <= limit) out = rule
        else out = substr(all, 1, limit)
        printf "%s\037%s\036", cur, out
        cur = ""; nl = 0
      }
      FNR == 1 { flush(); cur = FILENAME; depth = 0; started = 0; stop = 0; sub(/^\357\273\277/, "") }
      {
        sub(/\r$/, "")
        if (stop) next
        if ($0 ~ /^---[ \t]*$/ && depth < 2) { depth++; next }
        if (depth < 2) next
        if (!started && $0 ~ /^[ \t]*$/) next
        if (tolower($0) ~ /^#+[ \t]*(rationale|background|examples?|references?|related|see also|sources?|provenance)[ \t]*$/) { stop = 1; next }
        started = 1
        L[++nl] = $0
      }
      END { flush() }
    ' "${readable[@]}" 2>/dev/null || true)"
  fi

  for i in "${!mf_slugs[@]}"; do
    slug="${mf_slugs[$i]}"
    path="${mf_paths[$i]}"
    line="${mf_lines[$i]}"
    body=""
    if [ -n "$path" ]; then
      case "$bodies" in
        *"$path"$'\037'*)
          rec="${bodies#*"$path"$'\037'}"
          body="${rec%%$'\036'*}"
          ;;
      esac
    fi
    PSI_MF_BLOCK+="> Policy \`$slug\` (HARD — binding rule, pull full text before acting): $line"$'\n'
    if [ -n "$body" ]; then
      PSI_QUOTED=""
      while IFS= read -r rec || [ -n "$rec" ]; do
        policy_session_index_quote_line "$rec"
      done <<< "$body"
      policy_value_bytes "$PSI_QUOTED"
      if [ "$keep_max" -ge 0 ] && [ "$kept" -ge "$keep_max" ]; then
        withheld+="${withheld:+, }\`$slug\`"
      elif [ $((used + POLICY_VALUE_BYTES)) -le "$budget" ]; then
        PSI_MF_BLOCK+="$PSI_QUOTED"
        used=$((used + POLICY_VALUE_BYTES))
        kept=$((kept + 1))
      else
        withheld+="${withheld:+, }\`$slug\`"
      fi
    fi
  done
  if [ -n "$withheld" ]; then
    PSI_MF_BLOCK+="> Output budget: full text withheld for ${withheld}. Pull it with hq-policy get <slug> before acting."$'\n'
  fi
  if [ -n "$refs" ]; then
    PSI_MF_BLOCK+="> Still binding, shown earlier: ${refs}."$'\n'
  fi
  PSI_MF_BLOCK="<policy-reminder>"$'\n'"$PSI_MF_BLOCK""</policy-reminder>"
}

# Assemble context from index lines (already chosen), the must-fire block,
# and the enforcement-gate block. Sets PSI_CONTEXT.
policy_session_index_join() {
  local idx="$1" mf="$2" enf="$3"
  PSI_CONTEXT="$mf"
  if [ -n "$enf" ]; then
    PSI_CONTEXT="${PSI_CONTEXT:+$PSI_CONTEXT$'\n'}<policy-enforcement>"$'\n'"$enf"$'\n'"</policy-enforcement>"
  fi
  if [ -n "$idx" ]; then
    PSI_CONTEXT="${PSI_CONTEXT:+$PSI_CONTEXT$'\n'}$idx"
  fi
}

# Index lines. HARD lines are never dropped: level 2 shortens each to its
# slug, level 3 folds them into one line with a byte-capped slug list. Soft
# lines past soft_keep are cut and counted. Sets PSI_INDEX.
#   $1 level (0 full, 1 soft cut, 2 HARD compact, 3 HARD folded), $2 soft_keep
policy_session_index_render_index() {
  local level="$1" soft_keep="$2" kind text slug n_soft=0 cut=0 body="" head="" tail=""
  local rec folded=0 fold_list="" fold_more=0 LC_ALL=C
  PSI_INDEX=""
  [ -n "$PSI_LINES" ] || return 0
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    kind="${rec%%$'\t'*}"
    text="${rec#*$'\t'}"
    case "$kind" in
      o) head="$text" ;;
      c) tail="$text" ;;
      h)
        slug="${text%%$'\t'*}"
        text="${text#*$'\t'}"
        if [ "$level" -ge 3 ]; then
          folded=$((folded + 1))
          if [ $(( ${#fold_list} + ${#slug} )) -le 600 ]; then
            fold_list+="${fold_list:+, }\`$slug\`"
          else
            fold_more=$((fold_more + 1))
          fi
        elif [ "$level" -ge 2 ]; then
          body+="> \`$slug\` [HARD]"$'\n'
        else
          body+="$text"$'\n'
        fi
        ;;
      s|z)
        if [ "$level" -ge 1 ] && [ "$n_soft" -ge "$soft_keep" ]; then
          cut=$((cut + 1))
        else
          body+="$text"$'\n'
          n_soft=$((n_soft + 1))
        fi
        ;;
      *) body+="$text"$'\n' ;;
    esac
  done <<< "$PSI_LINES"
  if [ "$folded" -gt 0 ]; then
    body+="> +${folded} HARD rules pinned: ${fold_list}"
    [ "$fold_more" -eq 0 ] || body+=" and ${fold_more} more"
    body+=". Pull with hq-policy get <slug> before acting."$'\n'
  fi
  if [ "$cut" -gt 0 ]; then
    body+="> +${cut} rules withheld by the ${PSI_CEILING}-byte output budget. Pull any with hq-policy get <slug>."$'\n'
  fi
  [ -n "$body" ] || return 0
  PSI_INDEX="${head:+$head$'\n'}$body${tail}"
  PSI_INDEX="${PSI_INDEX%$'\n'}"
}

# Cut PSI_CONTEXT so stdout fits PSI_CEILING. The note's bytes are reserved
# up front; the cut point only goes down and the slice is always taken from
# the text before the note, so each pass makes progress. Fallback: the
# must-fire summary lines alone, then nothing.
policy_session_index_tail_cut() {
  local LC_ALL=C base="$PSI_CONTEXT" note limit piece pass=0 over summary
  note="> Output budget of ${PSI_CEILING} bytes reached; the rest of the policy index was cut. Pull rules with hq-policy get <slug>."
  policy_session_index_out_bytes "$note"
  limit=$(( PSI_CEILING - PSI_OUT_BYTES - 1 ))
  while [ "$limit" -gt 0 ] && [ "$pass" -lt 64 ]; do
    pass=$((pass + 1))
    piece="${base:0:$limit}"
    piece="${piece%$'\n'*}"
    [ -n "$piece" ] || break
    case "$piece" in
      *'<policy-index>'*) case "${piece##*<policy-index>}" in *'</policy-index>'*) ;; *) piece+=$'\n''</policy-index>' ;; esac ;;
    esac
    case "$piece" in
      *'<policy-reminder>'*) case "${piece##*<policy-reminder>}" in *'</policy-reminder>'*) ;; *) piece+=$'\n''</policy-reminder>' ;; esac ;;
    esac
    PSI_CONTEXT="$piece"$'\n'"$note"
    policy_session_index_out_bytes "$PSI_CONTEXT"
    [ "$PSI_OUT_BYTES" -gt "$PSI_CEILING" ] || return 0
    over=$(( PSI_OUT_BYTES - PSI_CEILING ))
    limit=$(( limit - over - 1 ))
  done
  # Fallback: must-fire summary lines only.
  summary=""
  while IFS= read -r piece; do
    case "$piece" in
      '> Policy `'*|'> Still binding'*|'> Output budget: full text withheld'*) summary+="$piece"$'\n' ;;
    esac
  done <<< "$base"
  while [ -n "$summary" ]; do
    PSI_CONTEXT="<policy-reminder>"$'\n'"$summary""</policy-reminder>"
    policy_session_index_out_bytes "$PSI_CONTEXT"
    [ "$PSI_OUT_BYTES" -gt "$PSI_CEILING" ] || return 0
    summary="${summary%$'\n'}"
    case "$summary" in *$'\n'*) summary="${summary%$'\n'*}"$'\n' ;; *) summary="" ;; esac
  done
  PSI_CONTEXT=""
  PSI_OUT_BYTES=0
}

policy_session_index_emit() {
  local index_file lock result render named kind hook_output bytes
  local hard_max hard_budget full_budget attempts lock_held now
  local company rec mf_list="" record_rows="" state_line="" n_soft=0 n_mf=0
  local meta="" enforcement="${ENFORCEMENT_CONTEXT:-}" source=""

  policy_session_index_paths || return 1
  # A tool event with no match, no shown-again rule and no gate context has
  # nothing to say and does not move the turn counter: skip the state work.
  case "$EVENT" in
    SessionStart|UserPromptSubmit) ;;
    *)
      if [ -z "${MATCHES:-}" ] && [ -z "${SHOWN_AGAIN_SLUGS:-}${SEEN_HARD_SLUGS:-}" ] \
         && [ -z "${ENFORCEMENT_CONTEXT:-}" ]; then
        return 0
      fi
      ;;
  esac
  policy_session_index_settings
  policy_session_index_company
  company="$PSI_COMPANY"
  index_file="$PSI_DIR/${PSI_SID}--${company}.json"
  mkdir -p "$PSI_DIR" 2>/dev/null || true

  hard_max="${HQ_POLICY_HARD_MAX_BYTES:-2048}"
  case "$hard_max" in ''|*[!0-9]*) hard_max=2048 ;; esac
  hard_budget="${HQ_POLICY_HARD_BUDGET_BYTES:-5120}"
  case "$hard_budget" in ''|*[!0-9]*) hard_budget=5120 ;; esac
  PSI_CEILING="${HQ_POLICY_OUTPUT_CEILING_BYTES:-4000}"
  case "$PSI_CEILING" in ''|*[!0-9]*) PSI_CEILING=4000 ;; esac
  full_budget="$hard_budget"
  if [ $((PSI_CEILING - 1400)) -lt "$full_budget" ]; then
    full_budget=$((PSI_CEILING - 1400))
    [ "$full_budget" -ge 0 ] || full_budget=0
  fi

  # Must-fire and topic metadata from frontmatter, one awk over all matched
  # files: path, mustfire value, enforcement, comma-joined tags.
  if [ -n "${MATCHES:-}" ]; then
    local -a meta_paths=()
    while IFS= read -r rec; do
      [ -n "$rec" ] && [ -f "$rec" ] && meta_paths+=("$rec")
    done < <(printf '%s\n' "$MATCHES" | awk -F '\t' 'NF >= 3 && $3 != "" && !seen[$3]++ { print $3 }')
    if [ "${#meta_paths[@]}" -gt 0 ]; then
      meta="$(awk '
        function out() { if (cur != "") printf "%s\t%s\t%s\n", cur, mf, tags }
        FNR == 1 { out(); cur = FILENAME; fm = 0; mf = ""; tags = ""; inlist = 0 }
        { sub(/\r$/, "") }
        fm >= 2 { next }
        /^---[ \t]*$/ { fm++; next }
        fm == 1 && /^mustfire:/ {
          v = $0; sub(/^mustfire:[ \t]*/, "", v); sub(/[ \t]*$/, "", v)
          if (v ~ /^(true|yes|1)$/) mf = "true"; else if (v ~ /^(false|no|0)$/) mf = "false"
        }
        fm == 1 && inlist && /^[ \t]*-[ \t]*/ {
          v = $0; sub(/^[ \t]*-[ \t]*/, "", v); gsub(/[ \t"'"'"']/, "", v)
          if (v != "") tags = tags (tags == "" ? "" : ",") v
          next
        }
        fm == 1 { inlist = 0 }
        fm == 1 && /^tags:/ {
          v = $0; sub(/^tags:[ \t]*/, "", v); gsub(/[][ \t"'"'"']/, "", v); tags = v
          if (v == "") inlist = 1
        }
        END { out() }
      ' "${meta_paths[@]}" 2>/dev/null || true)"
    fi
  fi

  # SessionStart source without a process: the host writes it as a plain
  # JSON string, with or without a space after the colon.
  if [ "$EVENT" = "SessionStart" ]; then
    case "${STDIN_JSON:-}" in
      *'"source":"compact"'*|*'"source": "compact"'*) source="compact" ;;
      *'"source":"compaction"'*|*'"source": "compaction"'*) source="compact" ;;
      *'"source":"clear"'*|*'"source": "clear"'*) source="clear" ;;
    esac
  fi

  lock="${index_file}.lock"
  attempts=0
  lock_held=0
  while [ "$attempts" -lt 40 ]; do
    if mkdir "$lock" 2>/dev/null; then
      lock_held=1
      # pid only: the reclaim helper falls back to the lock dir mtime for age.
      printf '%s\n' "$$" > "$lock/pid" 2>/dev/null || true
      break
    fi
    # A holder that died (hook timeout kill) or is older than the lock TTL
    # is taken over with the injector's reclaim helper.
    if declare -F reclaim_stale_enforcement_lock >/dev/null 2>&1 \
       && reclaim_stale_enforcement_lock "$lock"; then
      # The helper also returns 0 when the lock is not a directory, which is
      # what an uncreatable lock looks like, so this pass counts too.
      attempts=$((attempts + 1))
      continue
    fi
    attempts=$((attempts + 1))
    sleep 0.02
  done

  local state_src="/dev/null"
  [ -f "$index_file" ] && state_src="$index_file"

  # Output lines:
  #   S<TAB>state json    K<TAB>render    N<TAB>named count
  #   M<TAB>slug<TAB>path<TAB>line    must-fire to push
  #   R<TAB>slug<TAB>inject           delivered-row bookkeeping
  #   L<TAB>kind<TAB>text             index or delta line
  #     kind o open, c close, h hard, s soft, z collapsed, x other
  result="$("$JQ" -r -s \
    --arg rows "${MATCHES:-}" \
    --arg meta "$meta" \
    --arg shown "${SHOWN_AGAIN_SLUGS:-}${SEEN_HARD_SLUGS:-}" \
    --arg source "$source" \
    --arg event "${EVENT:-}" \
    --argjson every "$PSI_EVERY" \
    --argjson cap "$PSI_CAP" \
    --argjson recent "$PSI_RECENT" \
    --arg session "$PSI_SID" \
    --arg company "$company" '
    def safety: test("secret|credential|apikey|api-key|password|security|destruct|irreversible|force-push|git-push|git-merge|production|prod-deploy|tenant|cross-company|company-isolation|company-scope"; "i");
    def category:
      if test("secret|credential|apikey|api-key|password"; "i") then "secrets"
      elif test("destruct|irreversible"; "i") then "destructive"
      elif test("force-push|git-push|git-merge"; "i") then "push-merge"
      elif test("production|prod-deploy"; "i") then "production"
      elif test("tenant|cross-company|company-isolation|company-scope"; "i") then "tenant-isolation"
      else null end;
    ($meta | split("\n") | map(select(length > 0) | split("\t")
       | {key: .[0], value: {mf: (.[1] // ""), tags: ((.[2] // "") | split(",") | map(select(length > 0)))}})
       | from_entries) as $m
    | ([ $rows | split("\n")[] | select(length > 0) | split("\t") | select(.[0] != null and .[0] != "") ]
       | map(
           (.[2] // "") as $p
           | ($m[$p] // {mf: "", tags: []}) as $md
           | (.[3] // "") as $enf
           | (if $md.mf == "true" then true
              elif $md.mf == "false" then false
              else ($enf == "hard" and (([$md.tags[] | safety] | any) or (.[0] | safety)))
              end) as $must
           | {
               slug: .[0],
               path: $p,
               inj: (.[6] // "once"),
               score: ((.[13] // "0") | tonumber? // 0),
               line: ((.[4] // "") | gsub("[\\t\\r\\n]+"; " ") | if length > 120 then .[0:120] else . end),
               topic: (($md.tags[0] // null) // (.[0] | category) // "general"),
               weight: (if $enf == "hard" or $must then "hard" else "soft" end),
               mustfire: $must
             })) as $matches
    | (if $event == "SessionStart" then
         (if $source == "compact" or $source == "compaction" then "rebuild" else "index" end)
       else "delta" end) as $mode
    | (if $event == "UserPromptSubmit" then 1 else 0 end) as $increment
    | ((.[0] // {}) | if type == "object" then . else {} end) as $raw
    | (($raw.session_id // "") as $s
       | if $s != "" and ($s != $session or ($raw.company // "") != $company) then
           {fresh: true, st: {}} else {fresh: false, st: $raw} end) as $chk
    | $chk.st as $state
    | ($state.turn // 0) as $turn0
    | ($turn0 + $increment) as $turn
    | ($state.last_index_turn // -1) as $last_index
    | (if $chk.fresh then "index"
       elif $mode == "delta" and $increment == 1 and $every > 0 and $turn > 0
            and ($turn % $every) == 0 and $last_index != $turn then "index"
       else $mode end) as $requested
    | ($matches | map({key: .slug, value: .}) | from_entries) as $by
    | (reduce (($state.entries // [])[]) as $e (
        {entries: [], collapsed: ($state.collapsed // []), new: []};
        if ($by[$e.slug] != null) then
          .entries += [ $e + ($by[$e.slug] | {weight, topic, line, score, mustfire, path}) + {last_trigger_turn: $turn} | del(.inj) ]
        elif ($e.weight == "hard" or $e.mustfire == true) then
          .entries += [$e]
        elif ($requested == "rebuild" and (($e.last_trigger_turn // 0) + $recent) < $turn) then
          .collapsed += [{topic: ($e.topic // "general"), count: 1, slugs: [$e.slug]}]
        else
          .entries += [$e]
        end
      )) as $kept
    | (reduce $matches[] as $mt (
        $kept;
        if any(.entries[]; .slug == $mt.slug) then .
        else
          .entries += [ ($mt | del(.inj)) + {last_trigger_turn: $turn, added_turn: $turn} ]
          | .new += [$mt.slug]
        end
      )) as $merged0
    | def collapse_one:
        if (.entries | length) <= $cap then .
        else
          ([ .entries[] | select(.weight != "hard" and .mustfire != true) ]
           | sort_by([.last_trigger_turn, .added_turn, .slug]) | .[0]) as $victim
          | if $victim == null then .
            else
              .collapsed += [{topic: ($victim.topic // "general"), count: 1, slugs: [$victim.slug]}]
              | .entries |= map(select(.slug != $victim.slug))
              | collapse_one
            end
        end;
      ($merged0 | collapse_one
        | .collapsed |= (
            reduce (. // [])[] as $c ({};
              .[$c.topic // "general"] |= {
                count: ((.count // 0) + ($c.count // 1)),
                slugs: (((.slugs // []) + ($c.slugs // [])) | unique)
              })
            | to_entries | map({topic: .key, count: .value.count, slugs: .value.slugs}) | sort_by(.topic))
        | .entries |= sort_by([(if .weight == "hard" or .mustfire == true then 0 else 1 end), (-(.score // 0)), .slug])
      ) as $merged
    | (if $requested == "index" or $requested == "rebuild" then "index"
       elif ($merged.new | length) > 0 then "delta"
       else "quiet" end) as $render
    | ($shown | split("\n") | map(select(length > 0))) as $again
    | ( [ $matches[] | select(.mustfire == true) | .slug ]
        + [ $again[] as $s | $merged.entries[] | select(.slug == $s and .mustfire == true) | .slug ]
      | reduce .[] as $s ([]; if index([$s]) then . else . + [$s] end)) as $mf
    # Full must-fire text once per epoch; compaction or clear starts a new
    # epoch so the text comes back. The next match after a full text gets
    # one short "still binding" reference per session; later matches stay
    # quiet, as the flag-off reminder does.
    | (($state.mf_epoch // 0) + (if $source == "compact" or $source == "compaction" or $source == "clear" then 1 else 0 end)) as $epoch
    | (if $chk.fresh then {} else ($state.mf_shown // {}) end) as $shown0
    | ([ $mf[] | select(($shown0[.] // -1) != $epoch) ]) as $mf_full
    | (if $chk.fresh then {} else ($state.mf_ref // {}) end) as $ref0
    | ([ $mf[] | . as $x | select(($mf_full | index([$x])) == null and ($ref0[$x] // false) != true) ]) as $mf_ref
    | {
        version: 1,
        session_id: $session,
        company: $company,
        turn: $turn,
        last_index_turn: (if $render == "index" then $turn else $last_index end),
        mf_epoch: $epoch,
        mf_shown: (reduce $mf_full[] as $s ($shown0; .[$s] = $epoch)),
        mf_ref: (reduce $mf_ref[] as $s ($ref0; .[$s] = true)),
        entries: $merged.entries,
        collapsed: $merged.collapsed
      } as $out
    | "S\t" + ($out | tojson),
      "K\t" + $render,
      "N\t" + (if $render == "index" then ($merged.entries | length)
               elif $render == "delta" then ($merged.new | length) else 0 end | tostring),
      (($mf_full + $mf_ref)[] as $s
        | (($by[$s] // ([$merged.entries[] | select(.slug == $s)][0]) // {}) ) as $r
        | "M\t\(if ($mf_full | index([$s])) != null then "full" else "ref" end)\t\($s)\t\($r.path // "")\t\($r.line // "")"),
      ($matches[] | "R\t\(.slug)\t\(.inj)"),
      (if $render == "index" then
         "L\to\t<policy-index>",
         "L\tx\t> Rules pinned for this session (\($merged.entries | length)). Pull full text with hq-policy get <slug>.",
         ($merged.entries[] |
           if .weight == "hard" or .mustfire == true then
             "L\th\t\(.slug)\t> `\(.slug)` [HARD · \(.topic)] \(.line). Pull full text before acting."
           else
             "L\ts\t> `\(.slug)` [soft · \(.topic)] \(.line)."
           end),
         ($merged.collapsed[] | select(.count > 0) |
           "L\tz\t> +\(.count) older rules (topic \(.topic)): \((.slugs // [])[0:8] | join(", "))\(if (.slugs // [] | length) > 8 then ", ..." else "" end). Pull with hq-policy get <slug>."),
         "L\tc\t</policy-index>"
       elif $render == "delta" then
         "L\to\t<policy-index>",
         ($merged.new[] as $slug | $by[$slug] as $mt
           | if $mt.weight == "hard" or $mt.mustfire == true then
               "L\th\t\($slug)\t> Added to this session'\''s rules: \($slug): \($mt.line). Pull full text before acting."
             else
               "L\ts\t> Added to this session'\''s rules: \($slug): \($mt.line)."
             end),
         "L\tc\t</policy-index>"
       else empty end)
  ' "$state_src" 2>/dev/null || true)"

  if [ -z "$result" ]; then
    # Unreadable state (corrupt file, jq failure). Move the file aside so the
    # next event starts clean, and let the caller run the reminder path.
    if [ "$state_src" != "/dev/null" ] && [ -f "$state_src" ]; then
      mv -f "$state_src" "${state_src}.bad.$$" 2>/dev/null || rm -f "$state_src" 2>/dev/null || true
    fi
    [ "$lock_held" -eq 1 ] && policy_session_index_release_lock "$lock"
    policy_session_index_stat fallback 0 0
    return 1
  fi

  render="quiet"
  named=0
  PSI_LINES=""
  while IFS= read -r rec; do
    case "$rec" in
      S$'\t'*) state_line="${rec#S$'\t'}" ;;
      K$'\t'*) render="${rec#K$'\t'}" ;;
      N$'\t'*) named="${rec#N$'\t'}" ;;
      M$'\t'full$'\t'*) mf_list+="${rec#M$'\t'}"$'\n'; n_mf=$((n_mf + 1)) ;;
      M$'\t'*) mf_list+="${rec#M$'\t'}"$'\n' ;;
      R$'\t'*) record_rows+="${rec#R$'\t'}"$'\n' ;;
      L$'\t'[sz]$'\t'*) PSI_LINES+="${rec#L$'\t'}"$'\n'; n_soft=$((n_soft + 1)) ;;
      L$'\t'*) PSI_LINES+="${rec#L$'\t'}"$'\n' ;;
    esac
  done <<< "$result"
  case "$named" in ''|*[!0-9]*) named=0 ;; esac

  if [ "$lock_held" -eq 1 ]; then
    if [ -n "$state_line" ] && printf '%s\n' "$state_line" > "${index_file}.tmp.$$" 2>/dev/null; then
      mv -f "${index_file}.tmp.$$" "$index_file" 2>/dev/null || rm -f "${index_file}.tmp.$$"
    else
      rm -f "${index_file}.tmp.$$" 2>/dev/null || true
    fi
    policy_session_index_release_lock "$lock"
  fi
  # Fit under the ceiling. Must-fire text and the enforcement block come
  # first. Steps, each tried once, in order: cut soft lines from the end;
  # shorten HARD lines to their slug; fold HARD lines into one line; only
  # then withhold must-fire bodies one at a time. Last resort: cut the tail.
  local level=0 soft_keep=0 mf_keep="$n_mf" guard=0
  policy_session_index_render_index 0 0
  policy_session_index_mustfire_block "$mf_list" "$full_budget" "$hard_max" -1
  policy_session_index_join "$PSI_INDEX" "$PSI_MF_BLOCK" "$enforcement"
  policy_session_index_out_bytes "$PSI_CONTEXT"
  if [ -n "$PSI_CONTEXT" ] && [ "$PSI_OUT_BYTES" -gt "$PSI_CEILING" ]; then
    soft_keep="$n_soft"
    while [ "$PSI_OUT_BYTES" -gt "$PSI_CEILING" ] && [ "$guard" -lt 400 ]; do
      guard=$((guard + 1))
      if [ "$soft_keep" -gt 0 ]; then
        [ "$level" -ge 1 ] || level=1
        soft_keep=$((soft_keep - 1))
      elif [ "$level" -lt 2 ]; then
        level=2
      elif [ "$level" -lt 3 ]; then
        level=3
      elif [ "$mf_keep" -gt 0 ]; then
        mf_keep=$((mf_keep - 1))
        policy_session_index_mustfire_block "$mf_list" "$full_budget" "$hard_max" "$mf_keep"
      else
        break
      fi
      policy_session_index_render_index "$level" "$soft_keep"
      policy_session_index_join "$PSI_INDEX" "$PSI_MF_BLOCK" "$enforcement"
      policy_session_index_out_bytes "$PSI_CONTEXT"
    done
    if [ "$PSI_OUT_BYTES" -gt "$PSI_CEILING" ]; then
      policy_session_index_tail_cut
    fi
  fi

  hook_output="$PSI_CONTEXT"
  if [ -n "$PSI_CONTEXT" ] && [ "$EVENT" = "PostToolUse" ]; then
    hook_output="$("$JQ" -cn --arg event "$EVENT" --arg c "$PSI_CONTEXT" \
      '{hookSpecificOutput:{hookEventName:$event,additionalContext:$c}}' 2>/dev/null || true)"
  fi

  if [ -n "$hook_output" ]; then
    policy_value_bytes "$hook_output"
    bytes=$((POLICY_VALUE_BYTES + 1))
  else
    bytes=0
  fi
  # An event with nothing matched and nothing shown again exits before the
  # stats line today. Stay quiet the same way so an off and on session can
  # be compared emit for emit.
  if [ "$bytes" -eq 0 ] && [ -z "${MATCHES:-}" ] && [ -z "${SHOWN_AGAIN_SLUGS:-}${SEEN_HARD_SLUGS:-}" ]; then
    return 0
  fi
  if [ "$bytes" -eq 0 ]; then
    kind="quiet"
  elif [ -n "$mf_list" ] && [ "$render" = "quiet" ]; then
    kind="mustfire"
  elif [ "$render" = "quiet" ]; then
    kind="enforcement"
  else
    kind="$render"
  fi
  policy_session_index_stat "$kind" "$bytes" "$named"
  policy_session_index_record "$hook_output" "$record_rows"
  if [ -n "$hook_output" ]; then
    printf '%s\n' "$hook_output"
  fi
  return 0
}

# Delivered slugs move into the cadence ledgers. The index is the reminder
# dedupe; the ledgers still stop a later event from filling the cap with
# rules that were already pinned. Must-fire re-triggers stay on the shown
# path, which emits binding text without a new index line.
#   $2 newline list of "slug<TAB>inject".
policy_session_index_record() {
  local output="$1" rows="$2" slug inj once_slugs="" always_slugs=""
  [ -n "$output" ] || return 0
  declare -F record_slugs >/dev/null 2>&1 || return 0
  while IFS=$'\t' read -r slug inj; do
    [ -n "$slug" ] || continue
    case "$output" in
      *\`"$slug"\`*) ;;
      *"Added to this session's rules: $slug:"*) ;;
      *) continue ;;
    esac
    if [ "$inj" = "always" ]; then
      always_slugs+="$slug"$'\n'
    else
      once_slugs+="$slug"$'\n'
    fi
  done <<< "$rows"
  if [ -n "$once_slugs" ] && [ -n "${DEDUPE_FILE:-}" ]; then
    record_slugs "$DEDUPE_FILE" "$once_slugs" || true
  fi
  if [ -n "$always_slugs" ] && [ -n "${TURN_FILE:-}" ]; then
    record_slugs "$TURN_FILE" "$always_slugs" || true
  fi
}
