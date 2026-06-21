#!/bin/bash
# derive-trigger-facts.sh — build the fact set a policy `when:` expression is
# evaluated against, for a given hook event.
#
# Usage:
#   <hook-json on stdin> | derive-trigger-facts.sh <EVENT>
#     EVENT in {PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent}
#   -> prints a space-separated, de-duplicated fact set to stdout.
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
STDIN_JSON="$(cat 2>/dev/null || echo '{}')"
JQ="$(command -v jq || true)"

# jget <jq-filter> — extract a field, empty string on miss / no jq.
jget() {
  [ -n "$JQ" ] || { printf ''; return 0; }
  printf '%s' "$STDIN_JSON" | "$JQ" -r "$1 // empty" 2>/dev/null || printf ''
}

# match_keywords <text> — emit (newline-separated) the OPEN fact set for <text>:
# every word token present (case-insensitive), plus the non-literal derived
# tokens (secret / shared_branch) and structured filename / slash-command tokens.
match_keywords() {
  awk -v text="$1" '
    BEGIN {
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

FACTS=""
add() { FACTS="$FACTS $*"; }

# `always` is present in every fact set so `when: always` is the canonical
# "no condition" expression (used by SessionStart-introduced advisory policies).
add always

case "$EVENT" in
  PreToolUse|PostToolUse)
    TOOL="$(jget '.tool_name')"
    case "$TOOL" in
      Bash)
        CMD="$(jget '.tool_input.command')"
        if [ "$EVENT" = "PreToolUse" ]; then
          add "$(match_keywords "$CMD")"
        else
          # PostToolUse: derive from the tool OUTPUT, not the input command.
          OUT="$(jget '.tool_response | if type=="string" then . else tostring end')"
          add "$(match_keywords "$OUT")"
        fi
        ;;
      "" ) : ;;
      * )
        # non-Bash tool -> lowercased tool name token (PreToolUse mainly)
        if [ "$EVENT" = "PreToolUse" ]; then
          add "$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]')"
        else
          OUT="$(jget '.tool_response | if type=="string" then . else tostring end')"
          add "$(match_keywords "$OUT")"
        fi
        ;;
    esac
    ;;
  UserPromptSubmit)
    PROMPT="$(jget '.prompt')"
    add "$(match_keywords "$PROMPT")"
    ;;
esac

# --- AssistantIntent: facts come ONLY from the AI-message look-back ---
# The dedicated channel for "what the assistant said it would do" — assistant
# text emitted since the last user turn in transcript_path. No command/prompt
# tokens and no static facts are mixed in; the raw PreToolUse/UserPromptSubmit
# fact sets deliberately exclude this look-back so the two channels stay crisp.
if [ "$EVENT" = "AssistantIntent" ]; then
  TRANSCRIPT="$(jget '.transcript_path')"
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && [ -n "$JQ" ]; then
    LOOKBACK_TEXT="$("$JQ" -r '
      # Real Claude Code transcript: each line is {type, message:{role,content}}
      # where assistant text lives at .message.content[] | select(.type=="text")
      # | .text. Fall back to a flat top-level .content (string) for simple
      # fixtures. (Mirrors enforce-capability-link-render.sh / capture-estimates.sh.)
      . as $e
      | ($e.type // "") as $ty
      | (($e.message.content // $e.content) as $c
         | if   ($c|type)=="array"  then ([$c[]? | select(.type=="text") | .text] | join(" "))
           elif ($c|type)=="string" then $c
           else "" end) as $txt
      | if $ty == "assistant" then $txt else "" end
      | "\($ty)\t\(.)"
    ' "$TRANSCRIPT" 2>/dev/null | awk -F'\t' '
      { type[NR] = $1; text[NR] = $2; last = NR; if ($1 == "user") lastuser = NR }
      END { for (i = lastuser + 1; i <= last; i++) if (type[i] == "assistant") printf "%s ", text[i] }
    ')"
    [ -n "$LOOKBACK_TEXT" ] && add "$(match_keywords "$LOOKBACK_TEXT")"
  fi
else
  # --- Best-effort static session facts (company / repo / shared_branch) ---
  # Real events only — AssistantIntent is intentionally facts-from-AI-only.
  CWD="$(jget '.cwd')"; [ -z "$CWD" ] && CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
  case "$CWD" in
    *companies/*) add company ;;
  esac
  case "$CWD" in
    *repos/public/*|*repos/private/*) add repo ;;
  esac
  # current branch (best-effort; ignore errors / non-repos)
  BR="$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  case "$BR" in
    main|master|staging|production|release/*) add shared_branch ;;
  esac
fi

# --- De-duplicate, normalize whitespace ---
printf '%s\n' $FACTS | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/[[:space:]]*$//'
echo
