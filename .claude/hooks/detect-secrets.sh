#!/bin/bash
# Detect and block secrets (API keys, tokens, private keys) before they land in
# a shell command OR in a file.
#
# PreToolUse hook for Bash, Write, Edit, MultiEdit, NotebookEdit — blocks the
# call if a secret-shaped value is found.
#
# History: from 2026-03 to 2026-09 this scanned only Bash commands. The threat
# model was "secrets in shell commands leak into transcripts, logs and process
# lists". Three policies then documented false positives and sanctioned "use
# the Write tool instead" as the recovery — which meant a secret written into a
# file under companies/ (synced to the vault and to teammates) was never
# scanned at all. As of 2026-09-07 the same patterns and the same
# false-positive escapes apply to file content. Example keys in docs and tests
# must look fake, or be assembled from fragments, which is what an example
# should be.

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')

case "$TOOL" in
  Bash)
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
    WHAT="Bash command" ;;
  Write)
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
    WHAT="file content (Write)" ;;
  Edit)
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
    WHAT="file content (Edit)" ;;
  MultiEdit)
    COMMAND=$(echo "$INPUT" | jq -r '[.tool_input.edits[]?.new_string // empty] | join("\n")')
    WHAT="file content (MultiEdit)" ;;
  NotebookEdit)
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.new_source // empty')
    WHAT="notebook cell (NotebookEdit)" ;;
  *) exit 0 ;;
esac

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Function to check if a match is in a comment or pattern reference
is_false_positive() {
  local line="$1"
  local match="$2"

  # Check if line is a comment (starts with # after optional whitespace)
  if [[ "$line" =~ ^[[:space:]]*# ]]; then
    return 0  # It's a comment, safe
  fi

  # Check if the line contains pattern-discussion keywords near the match
  if [[ "$line" =~ (echo|grep|sed|awk|regex|pattern)[[:space:]] ]]; then
    return 0  # Likely pattern reference, not a real secret
  fi

  # Check if match is inside quotes with wildcards (pattern reference like sk-*)
  if [[ "$line" =~ [\"\'](.*\*.*)[\"\'](.*)"$match" ]] || [[ "$line" =~ [\"\'](.*)"$match"(.*\*.*)[\"\'](.*) ]]; then
    return 0  # Pattern reference with wildcard
  fi

  return 1  # Real secret detected
}

# Array of patterns to check
declare -a PATTERNS=(
  "sk-[a-zA-Z0-9._-]{20,}:OpenAI/Stripe key"
  "ghp_[a-zA-Z0-9]{36,}:GitHub PAT"
  "AKIA[0-9A-Z]{16}:AWS access key"
  "xox[bpsa]-[a-zA-Z0-9-]+:Slack token"
  "Bearer [a-zA-Z0-9._-]{20,}:Bearer token"
  "-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----:Private key"
  "glpat-[a-zA-Z0-9_-]{20,}:GitLab PAT"
  "gho_[a-zA-Z0-9]{36,}:GitHub OAuth token"
  "github_pat_[a-zA-Z0-9_]{22,}:Fine-grained GitHub PAT"
)

# Check each pattern
for pattern_entry in "${PATTERNS[@]}"; do
  PATTERN="${pattern_entry%:*}"
  PATTERN_NAME="${pattern_entry#*:}"

  # Use grep with extended regex to find matches
  if echo "$COMMAND" | grep -E "$PATTERN" >/dev/null 2>&1; then
    # Found a match, but check if it's a false positive
    while IFS= read -r line; do
      if echo "$line" | grep -E "$PATTERN" >/dev/null 2>&1; then
        # Get the matched value
        MATCHED=$(echo "$line" | grep -oE "$PATTERN" | head -1)

        # Check if this is a false positive
        if ! is_false_positive "$line" "$MATCHED"; then
          # Real secret detected. Do NOT echo any portion of the matched value:
          # for short/low-entropy tokens a first8...last4 preview can reveal most
          # or all of the secret into the transcript. Report only the pattern name.
          cat >&2 <<EOF
🚨 SECRET DETECTED — Blocking $WHAT
Pattern matched: $PATTERN_NAME

Remove the secret. Put real credentials in the HQ vault (/hq-secrets, hq run,
hq secrets exec) and reference them by name; make example keys look fake.
EOF
          exit 2
        fi
      fi
    done <<<"$COMMAND"
  fi
done

# No secrets detected
exit 0
