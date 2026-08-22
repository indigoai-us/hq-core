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
  [ -z "$matcher" ] && return 0
  [ "$matcher" = "*" ] && return 0
  case "$event" in
    PreToolUse|PostToolUse) ;;
    *) return 0 ;;
  esac
  [ -z "$tool" ] && return 1
  local re="${matcher//\*/.*}"
  re="${re//,/|}"
  [[ "$tool" =~ ^(${re})$ ]]
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
    Bash) ids="mandatory-scope-authorizer detect-secrets block-core-writes-bash block-hq-root-git-mutation block-unsafe-package-install" ;;
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

# Emit the classified dispatch records for (event, canonical_tool) from
# settings.json, in registration order (settings.json array order == Claude's
# dispatch order), which this preserves.
hqad_iter_settings() {
  local event="$1" tool="$2"
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
