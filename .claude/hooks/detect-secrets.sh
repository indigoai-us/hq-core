#!/bin/bash
# Detect and block secrets in Bash commands (API keys, tokens, private keys).
# PreToolUse hook for Bash tool — blocks execution if secrets found.

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')

# Only check Bash tool
if [ "$TOOL" != "Bash" ]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

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
          # Real secret detected
          FIRST_8="${MATCHED:0:8}"
          LAST_4="${MATCHED: -4}"

          cat >&2 <<EOF
🚨 SECRET DETECTED — Blocking Bash command
Pattern matched: $PATTERN_NAME
Matched value: $FIRST_8...$LAST_4

Remove the secret from the command and use environment variables or config files instead.
EOF
          exit 2
        fi
      fi
    done <<<"$COMMAND"
  fi
done

# No secrets detected
exit 0
