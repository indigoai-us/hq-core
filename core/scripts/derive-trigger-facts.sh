#!/bin/bash
# derive-trigger-facts.sh — build the fact set a policy `when:` expression is
# evaluated against, for a given hook event.
#
# Usage:
#   <hook-json on stdin> | derive-trigger-facts.sh <EVENT> [--with-assistant-intent]
#     EVENT in {PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent}
#   -> prints a space-separated, de-duplicated fact set to stdout.
#   With --with-assistant-intent (PreToolUse and UserPromptSubmit only), prints
#   the primary and AssistantIntent fact sets as two newline-delimited records.
#
# Facts = event tokens + best-effort static facts (company / repo / shared_branch),
# EXCEPT AssistantIntent, which is AI-message tokens only (no static facts).
#
# Tokens are OPEN — there is NO curated vocabulary. The fact set for a text
# event is EVERY word token in that text (lowercased, letter-led, length >= 2),
# so a policy `when:` can key on any word that naturally appears when it is
# relevant (`refactor`, `monitor`, `docker`, `linear`, ...) without the engine
# having to know it in advance. On top of the literal words, a few NON-LITERAL
# / structured facts are derived (a word that is not itself present in the text):
#   secret         <- op:// | AWS_PROFILE | a .env path
#   shared_branch  <- a shared branch name (main/master/staging/production/release/)
#   <basename>+.ext <- a file reference (see Filename tokens below)
#   /command       <- a slash-command mention (see Slash-command tokens below)
#   run_in_background <- PreToolUse Bash with tool_input.run_in_background: true
# Per-event source text:
#   PreToolUse  Bash  -> the command. (`gh pr create` -> the word `pr`, etc.)
#   PreToolUse  other -> lowercased tool name (Glob->glob, Grep->grep, ...).
#   UserPromptSubmit  -> the prompt text.
#   PostToolUse       -> the tool OUTPUT (tool_response) text.
#   AssistantIntent   -> assistant message text emitted since the last user turn
#                        in transcript_path, AND NOTHING ELSE (no command/prompt
#                        tokens, no static facts). The dedicated AI-message
#                        channel; raw PreToolUse / UserPromptSubmit fact sets do
#                        NOT include look-back.
#
# Filename tokens: any file reference in the text emits a literal basename token
# and a `.ext` token (the eval-trigger grammar allows dots and slashes). So a
# policy keys on the file directly. `.claude/settings.json` -> `settings.json` +
# `.json`; `.mcp.json` -> `.mcp.json` + `.json`; `shot.png` -> `shot.png` + `.png`.
# This is what lets file-scoped policies fire from AssistantIntent (the AI naming
# the file it is about to edit/read) without the hook seeing the non-Bash
# Edit/Read tool call itself.
#
# Slash-command tokens: a `/command` mentioned in the text emits a `/command`
# token (`/brainstorm`, `/deep-plan`), so a slash-command-scoped policy fires
# when the command is invoked or referenced in a prompt.
#
# Pure read-only. Requires jq for JSON parsing (falls back to best-effort sed).

set -euo pipefail

EVENT="${1:-}"
WITH_ASSISTANT_INTENT=0
[ "${2:-}" = "--with-assistant-intent" ] && WITH_ASSISTANT_INTENT=1

# Bash can read the hook pipe directly without the separate `cat` process. An
# empty pipe retains the old best-effort empty-object behavior.
STDIN_JSON="$(</dev/stdin)" || STDIN_JSON='{}'
[ -n "$STDIN_JSON" ] || STDIN_JSON='{}'
JQ="$(command -v jq || true)"

# HQ root — used only to resolve the session's meta.yaml for the company fact
# (US-004). Prefer an explicit HQ_ROOT / CLAUDE_PROJECT_DIR; otherwise walk up
# from this script (core/scripts/derive-trigger-facts.sh -> ../.. == HQ root).
SCRIPT_PATH="${BASH_SOURCE[0]}"
case "$SCRIPT_PATH" in
  */*) SCRIPT_DIR="${SCRIPT_PATH%/*}" ;;
  *) SCRIPT_DIR="." ;;
esac
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

# Parse the hook payload once. The old per-field jget() helper launched jq for
# every scalar, then the policy hook launched this script twice for a single
# PreToolUse/UserPromptSubmit fire. NUL-delimited records preserve embedded
# newlines in commands and prompts; JSON strings containing NUL were already
# unsupported by bash command substitution on the old path.
JSON_FIELDS=()
if [ -n "$JQ" ]; then
  while IFS= read -r -d '' json_field; do
    JSON_FIELDS+=("$json_field")
  done < <(
    printf '%s' "$STDIN_JSON" | "$JQ" -rj '
      def text:
        if . == null then ""
        elif type == "string" then .
        else tostring
        end;
      [
        (.tool_name // ""),
        (.tool_input.command // ""),
        (.tool_input.run_in_background // ""),
        (if .tool_response == null then ""
         elif (.tool_response | type) == "string" then .tool_response
         else (.tool_response | tostring)
         end),
        (.prompt // ""),
        (.cwd // ""),
        (.session_id // ""),
        (.transcript_path // "")
      ] | .[] | text + "\u0000"
    ' 2>/dev/null
  )
fi

TOOL="${JSON_FIELDS[0]:-}"
COMMAND="${JSON_FIELDS[1]:-}"
RUN_IN_BACKGROUND="${JSON_FIELDS[2]:-}"
TOOL_RESPONSE="${JSON_FIELDS[3]:-}"
PROMPT="${JSON_FIELDS[4]:-}"
PAYLOAD_CWD="${JSON_FIELDS[5]:-}"
PAYLOAD_SESSION_ID="${JSON_FIELDS[6]:-}"
TRANSCRIPT_PATH="${JSON_FIELDS[7]:-}"

# match_keywords <text> — emit (newline-separated) the OPEN fact set for <text>:
# every word token present (case-insensitive), plus the non-literal derived
# tokens (secret / shared_branch) and structured filename / slash-command tokens.
match_keywords() {
  # Feed text through stdin: BSD awk (including macOS /usr/bin/awk) rejects a
  # literal newline inside a `-v name=value` assignment before the program runs.
  printf '%s\n' "$1" | awk '
    {
      if (NR > 1) text = text "\n"
      text = text $0
    }
    END {
      t = tolower(text)

      # open tokenization: every word token in the text becomes a fact, so a
      # policy `when:` can key on ANY word that naturally appears when it is
      # relevant — no curated vocabulary to maintain. Letter-led and length >= 2
      # (regex needs >=2 chars), so single characters and pure numbers are
      # dropped. Underscores and internal hyphens are kept (`aws_profile`,
      # `deep-plan`). Filename/slash tokens are added separately below.
      tw = t
      while (match(tw, /[a-z][a-z0-9_-]+/)) {
        print substr(tw, RSTART, RLENGTH)
        tw = substr(tw, RSTART + RLENGTH)
      }

      # derived (non-literal) tokens — words NOT themselves present in the text
      if (t ~ /(^|[^a-z0-9_])aws_profile/ || t ~ /op:\/\// || t ~ /\.env([^a-z0-9]|$)/) print "secret"
      if (t ~ /(^|[^a-z0-9_])(main|master|staging|production)([^a-z0-9_]|$)/ || t ~ /release\//) print "shared_branch"

      # derived: API-key / token shaped strings -> `apikey` + `secret`, so a pasted
      # or named key trips the secrets policy even when the words secret/password/api
      # are absent (the key itself open-tokenizes to one meaningless word). Prefix
      # shapes only, interval-free for portable awk (BSD/onetrueawk/mawk).
      if (t ~ /(^|[^a-z0-9])sk-[a-z0-9]/ \
         || t ~ /(^|[^a-z0-9])(gh[opsur]_|github_pat_)[a-z0-9_]/ \
         || t ~ /(^|[^a-z0-9])akia[a-z0-9][a-z0-9]/ \
         || t ~ /(^|[^a-z0-9])xox[bpsa]-[a-z0-9]/ \
         || t ~ /(^|[^a-z0-9])glpat-[a-z0-9]/ \
         || t ~ /-----begin[a-z -]*private key/ \
         || t ~ /(^|[^a-z0-9])bearer[ ][a-z0-9._-][a-z0-9._-][a-z0-9._-]/) { print "apikey"; print "secret" }

      # derived: clear completion markers in an agent message or command output ->
      # `completed`, so the share-on-completion policy fires even when phrased
      # differently than the literal when: tokens.
      if (t ~ /successfully (merged|deployed|pushed|published|created)/ \
         || t ~ /(deployment|deploy|build|release) (complete|completed|succeeded|ready)/ \
         || t ~ /merged pull request/ \
         || t ~ /pull request #?[0-9]+ .* merged/) print "completed"

      # file references in the text -> literal basename + `.ext` tokens. The
      # eval-trigger grammar allows dots and slashes in identifiers, so a policy
      # keys on the file directly: `when: .mcp.json`, `when: settings.json`,
      # `when: .png || .jpg`. `.claude/settings.json` -> `settings.json` + `.json`
      # (the leading dot of the directory is dropped with the path); a dotfile
      # like `.mcp.json` keeps its leading dot. Extensions must be letter-led, so
      # dotted version numbers (`v1.5`, `3.13`) are not treated as files.
      tmp = t
      while (match(tmp, "\\.?[a-z0-9_][a-z0-9_./-]*\\.[a-z][a-z0-9]+")) {
        fn = substr(tmp, RSTART, RLENGTH); tmp = substr(tmp, RSTART + RLENGTH)
        bn = fn; sub(/.*\//, "", bn)            # strip directory -> basename
        ext = bn; sub(/.*\./, "", ext)          # extension (after last dot)
        print "." ext
        print bn
      }

      # slash-command mentions -> `/command` tokens (when: /brainstorm). Anchored
      # to a space/start boundary so path segments (`repos/public`) are excluded.
      tmp2 = " " t
      while (match(tmp2, " /[a-z][a-z0-9-]*")) {
        sc = substr(tmp2, RSTART + 1, RLENGTH - 1); tmp2 = substr(tmp2, RSTART + RLENGTH)
        print sc
      }
    }
  '
}

# --- company: a SESSION-IDENTITY fact, resolved once per payload (US-004) ---
# Company is not look-back content; it identifies the active tenant. It is
# derived with the SAME precedence as inject-policy-on-trigger.sh DIRS —
#   HQ_POLICY_COMPANY env override > cwd companies/<slug> > session-meta
#   company_slug (workspace/sessions/$session_id/meta.yaml).
# A paired primary/AssistantIntent derivation shares this resolution, but each
# resulting fact set still receives the same `company` token it would alone.
CWD="$PAYLOAD_CWD"; [ -z "$CWD" ] && CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
SESSION_ID="$PAYLOAD_SESSION_ID"
co_scope=""
if [ -n "${HQ_POLICY_COMPANY:-}" ]; then
  co_scope="$HQ_POLICY_COMPANY"
else
  case "$CWD" in
    *companies/*)
      co_path="${CWD##*companies/}"
      co_scope="${co_path%%/*}"
      ;;
  esac
  if [ -z "$co_scope" ] && [ -n "$SESSION_ID" ]; then
    # Read the session's own meta.yaml directly (awk idiom from
    # master-hook.sh:119); READ ONLY, never via hq-session.sh get.
    META="$HQ_ROOT/workspace/sessions/$SESSION_ID/meta.yaml"
    [ -f "$META" ] && co_scope="$(awk '$1 == "company_slug:" { sub(/^[^:]+:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }' "$META")"
  fi
fi
COMPANY_FACT=""
[ -n "$co_scope" ] && COMPANY_FACT="company"

FACTS=""
FACTS_OUTPUT=""
add() { FACTS="$FACTS $*"; }

# Preserve the existing splitting and first-seen ordering but do it in one awk
# process instead of awk | tr | sed. `FACTS` only contains space/newline token
# boundaries from the existing match_keywords contract.
normalize_facts() {
  FACTS_OUTPUT="$(printf '%s\n' $FACTS | awk '
    NF && !seen[$0]++ {
      if (out != "") out = out " "
      out = out $0
    }
    END { printf "%s", out }
  ')"
}

# derive_event <event> sets FACTS_OUTPUT. It does not write stdout so paired
# mode can run both channels in this one process without a second hook launch.
derive_event() {
  local event="$1" lookback_text branch
  FACTS=""

  # `always` is present in every fact set so `when: always` is the canonical
  # "no condition" expression (used by SessionStart-introduced advisory policies).
  add always

  case "$event" in
    PreToolUse|PostToolUse)
      case "$TOOL" in
        Bash)
          if [ "$event" = "PreToolUse" ]; then
            add "$(match_keywords "$COMMAND")"
            # structured: a harness-tracked background task (`run_in_background:
            # true`) -> `run_in_background`, so a policy can tell a backgrounded
            # poll loop from the same command run in the foreground.
            [ "$RUN_IN_BACKGROUND" = "true" ] && add run_in_background
          else
            # PostToolUse: derive from the tool OUTPUT, not the input command.
            add "$(match_keywords "$TOOL_RESPONSE")"
          fi
          ;;
        "" ) : ;;
        * )
          # non-Bash tool -> lowercased tool name token (PreToolUse mainly)
          if [ "$event" = "PreToolUse" ]; then
            add "$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]')"
          else
            add "$(match_keywords "$TOOL_RESPONSE")"
          fi
          ;;
      esac
      ;;
    UserPromptSubmit)
      add "$(match_keywords "$PROMPT")"
      ;;
  esac

  [ -n "$COMPANY_FACT" ] && add "$COMPANY_FACT"

  # The dedicated channel for "what the assistant said it would do" — assistant
  # text emitted since the last user turn in transcript_path. No command/prompt
  # tokens are mixed in; the raw PreToolUse/UserPromptSubmit fact sets deliberately
  # exclude this look-back so the two channels stay crisp. (Company, above, is the
  # one session-identity fact shared across channels.)
  if [ "$event" = "AssistantIntent" ]; then
    if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] && [ -n "$JQ" ]; then
      lookback_text="$("$JQ" -nr '
        # Real Claude Code transcript: each line is {type, message:{role,content}}
        # where assistant text lives at .message.content[] | select(.type=="text")
        # | .text. Fall back to a flat top-level .content (string) for simple
        # fixtures. (Mirrors enforce-capability-link-render.sh / capture-estimates.sh.)
        reduce inputs as $e ("";
          ($e.type // "") as $ty
          | (($e.message.content // $e.content) as $c
             | if   ($c|type)=="array"  then ([$c[]? | select(.type=="text") | .text] | join(" "))
               elif ($c|type)=="string" then $c
               else "" end) as $txt
          | if $ty == "user" then ""
            elif $ty == "assistant" then . + (if length > 0 then " " else "" end) + $txt
            else . end
        )
      ' "$TRANSCRIPT_PATH" 2>/dev/null)"
      [ -n "$lookback_text" ] && add "$(match_keywords "$lookback_text")"
    fi
  else
    # Best-effort static session facts (repo / shared_branch), primary events
    # only. AssistantIntent is facts-from-AI-only except for `company` above.
    case "$CWD" in
      *repos/public/*|*repos/private/*) add repo ;;
    esac
    branch="$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    case "$branch" in
      main|master|staging|production|release/*) add shared_branch ;;
    esac
  fi

  normalize_facts
}

derive_event "$EVENT"
PRIMARY_FACTS="$FACTS_OUTPUT"
if [ "$WITH_ASSISTANT_INTENT" = "1" ] \
  && { [ "$EVENT" = "PreToolUse" ] || [ "$EVENT" = "UserPromptSubmit" ]; }; then
  derive_event AssistantIntent
  printf '%s\n%s\n' "$PRIMARY_FACTS" "$FACTS_OUTPUT"
else
  printf '%s\n' "$PRIMARY_FACTS"
fi
