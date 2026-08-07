# shellcheck shell=bash
# hq-core: public
# secret-patterns.sh — shared secret-detection patterns for hq-core shell scripts.
#
# SOURCED, never executed:  . "$ROOT/core/scripts/lib/secret-patterns.sh"
# bash 3.2 safe; no associative arrays.
#
# Single source of truth for the secret-shaped patterns that generated
# artifacts (delegation manifests, briefs, pickup prompts, DM payloads) are
# scanned against before they are written to disk or transmitted. Mirrors the
# runtime PreToolUse hook at .claude/hooks/detect-secrets.sh — a regression
# test (core/scripts/tests/hq-delegate-bundle.test.sh) asserts this list stays
# a superset of the hook's, so the two cannot silently drift.
#
# Entries are "<extended-regex>:<human name>". The regex part may not contain
# a colon; the name may.

SECRET_PATTERNS=(
  "sk-[a-zA-Z0-9._-]{20,}:OpenAI/Stripe key"
  "ghp_[a-zA-Z0-9]{36,}:GitHub PAT"
  "AKIA[0-9A-Z]{16}:AWS access key"
  "xox[bpsa]-[a-zA-Z0-9-]+:Slack token"
  "Bearer [a-zA-Z0-9._-]{20,}:Bearer token"
  "-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----:Private key"
  "glpat-[a-zA-Z0-9_-]{20,}:GitLab PAT"
  "gho_[a-zA-Z0-9]{36,}:GitHub OAuth token"
  "github_pat_[a-zA-Z0-9_]{22,}:Fine-grained GitHub PAT"
  "eyJ[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{10,}:JWT"
)

# hq_scan_secrets <file>...
#   Scan files for secret-shaped content. Prints "pattern: <name> in <file>"
#   to stderr for every hit (never the matched value itself) and returns 1 if
#   anything matched, 0 when all files are clean. Missing files are skipped.
hq_scan_secrets() {
  local hit=0 f entry pattern name
  for f in "$@"; do
    [ -f "$f" ] || continue
    for entry in "${SECRET_PATTERNS[@]}"; do
      pattern="${entry%%:*}"
      name="${entry#*:}"
      if grep -Eq "$pattern" "$f" 2>/dev/null; then
        echo "secret-scan: pattern '$name' matched in $f" >&2
        hit=1
      fi
    done
  done
  return "$hit"
}
