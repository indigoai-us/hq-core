#!/bin/bash
# load-policies-for-session.sh — SessionStart hook that injects applicable
# policy digests into session context.
#
# Detects cwd → active company (companies/{co}) and/or active repo
# (repos/{scope}/{name}). Emits a <policy-digest> block containing:
#   1. Hard-enforcement global policies (.claude/policies/_digest.md hard section)
#   2. Full company digest if in company context
#   3. Full repo digest if in repo context
#
# Soft-enforcement globals are NOT auto-loaded (budget reasons). Read
# `.claude/policies/_digest.md` manually if you need them.
#
# Usage: invoked by hook-gate.sh from settings.json SessionStart hook entry.
#
# Exit codes:
#   0 — success (always, even if no digest files exist)

set -euo pipefail

# Read stdin — Claude Code passes JSON with a "source" field
# (startup|resume|clear|compact). Slim the digest on resume/compact because the
# model already has the prior conversation in context and a 17KB policy wall
# creates signal-to-noise collapse that triggers the "No response requested"
# failure mode. See .claude/plans/mighty-noodling-parasol.md
STDIN_JSON="$(cat 2>/dev/null || echo '{}')"
SOURCE="$(printf '%s' "$STDIN_JSON" | sed -nE 's/.*"source"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
[ -z "$SOURCE" ] && SOURCE="startup"

# Determine HQ_ROOT by walking up until we find .claude/policies + companies/
# with at least one real company (not just the _template scaffold — that would
# catch hq-starter-kit and treat it as an independent HQ).
HQ_ROOT=""
CWD="$(pwd)"
search="$CWD"
while [ "$search" != "/" ]; do
  if [ -d "$search/.claude/policies" ] && [ -d "$search/companies" ]; then
    # Count real company dirs (exclude _template, manifest.yaml, etc.)
    real_count=$(find "$search/companies" -mindepth 1 -maxdepth 1 -type d ! -name '_template' 2>/dev/null | head -1 | wc -l)
    if [ "$real_count" -gt 0 ]; then
      HQ_ROOT="$search"
      break
    fi
  fi
  search="$(dirname "$search")"
done

# Fall back to canonical path if not found via walk-up
[ -z "$HQ_ROOT" ] && HQ_ROOT="${HOME}/Documents/HQ"

GLOBAL_DIGEST="$HQ_ROOT/.claude/policies/_digest.md"

# Detect active company from cwd (regex pattern from warn-cross-company-settings.sh)
# Note: BSD sed (macOS) needs -E + non-pipe delimiter for alternation to work.
ACTIVE_CO=""
if echo "$CWD" | grep -qE 'companies/[^/]+'; then
  ACTIVE_CO=$(echo "$CWD" | sed -nE 's#.*companies/([^/]+).*#\1#p')
fi

# Detect active repo from cwd (repos/{public|private}/{name})
ACTIVE_REPO=""
ACTIVE_REPO_SCOPE=""
if echo "$CWD" | grep -qE 'repos/(public|private)/'; then
  ACTIVE_REPO_SCOPE=$(echo "$CWD" | sed -nE 's#.*repos/(public|private)/.*#\1#p')
  ACTIVE_REPO=$(echo "$CWD" | sed -nE 's#.*repos/[^/]+/([^/]+).*#\1#p')

  # If no company detected yet, look up owning company via manifest
  if [ -z "$ACTIVE_CO" ] && [ -n "$ACTIVE_REPO" ]; then
    MANIFEST="$HQ_ROOT/companies/manifest.yaml"
    if [ -f "$MANIFEST" ]; then
      # Match any line containing the repo name, find preceding company key
      ACTIVE_CO=$(awk -v repo="$ACTIVE_REPO" '
        /^[a-z][a-z0-9_-]*:/ { company = $0; sub(/:.*/, "", company) }
        $0 ~ repo { print company; exit }
      ' "$MANIFEST" 2>/dev/null || true)
    fi
  fi
fi

# Resolve active service set (space-separated). Empty -> no filtering.
# Primary: companies/manifest.yaml block for $ACTIVE_CO (services + inferred
# vercel from vercel_team: + aws from aws_profile:).
# Fallback: .claude/stack.yaml services: array.
# Normalization: each service added verbatim AND its first `-`-segment, so
# manifest "shopify-partner" matches policy tags "shopify" or "shopify-partner".
HQ_ACTIVE_SERVICES=""
resolve_active_services() {
  local raw=""
  if [ -n "$ACTIVE_CO" ]; then
    local co_manifest="$HQ_ROOT/companies/manifest.yaml"
    if [ -f "$co_manifest" ]; then
      raw=$(awk -v co="$ACTIVE_CO" '
        $0 ~ "^" co ":" { in_co = 1; next }
        in_co && /^[a-z][a-z0-9_-]*:/ { exit }
        in_co && /^[[:space:]]*services:[[:space:]]*\[/ {
          line = $0
          sub(/.*services:[[:space:]]*\[/, "", line)
          sub(/\].*/, "", line)
          gsub(/,/, " ", line)
          print "SERVICES:" line
        }
        in_co && /^[[:space:]]*vercel_team:[[:space:]]*[^[:space:]#]/ { print "VERCEL:1" }
        in_co && /^[[:space:]]*aws_profile:[[:space:]]*[^[:space:]#]/ { print "AWS:1" }
      ' "$co_manifest" 2>/dev/null || true)
    fi
  fi
  if [ -z "$raw" ]; then
    local stack_yaml="$HQ_ROOT/.claude/stack.yaml"
    if [ -f "$stack_yaml" ]; then
      raw=$(awk '
        /^[[:space:]]*services:[[:space:]]*\[/ {
          line = $0
          sub(/.*services:[[:space:]]*\[/, "", line)
          sub(/\].*/, "", line)
          gsub(/,/, " ", line)
          print "SERVICES:" line
        }
      ' "$stack_yaml" 2>/dev/null || true)
    fi
  fi

  local services="" has_vercel=0 has_aws=0
  while IFS= read -r line; do
    case "$line" in
      SERVICES:*) services="${line#SERVICES:}" ;;
      VERCEL:1) has_vercel=1 ;;
      AWS:1) has_aws=1 ;;
    esac
  done <<< "$raw"

  local set=""
  local svc head
  for svc in $services; do
    [ -z "$svc" ] && continue
    set="$set $svc"
    head="${svc%%-*}"
    [ "$head" != "$svc" ] && set="$set $head"
  done
  [ "$has_vercel" = "1" ] && set="$set vercel"
  [ "$has_aws" = "1" ] && set="$set aws"

  HQ_ACTIVE_SERVICES=$(printf '%s\n' $set | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
}

# Filter digest lines by HQ_ACTIVE_SERVICES. Lines without an `<!-- applies_to: -->`
# suffix always pass. Lines with one pass only if at least one tag is in the
# active set. Empty active set -> fail-open (pass everything).
filter_by_stack() {
  if [ -z "$HQ_ACTIVE_SERVICES" ]; then
    cat
    return
  fi
  awk -v active="$HQ_ACTIVE_SERVICES" '
    BEGIN {
      n = split(active, parts, /[ ,]+/)
      for (i = 1; i <= n; i++) if (parts[i] != "") act[parts[i]] = 1
    }
    {
      line = $0
      if (match(line, /<!-- applies_to:[[:space:]]*[^>]*-->/)) {
        tagstr = substr(line, RSTART, RLENGTH)
        sub(/.*applies_to:[[:space:]]*/, "", tagstr)
        sub(/[[:space:]]*-->.*/, "", tagstr)
        gsub(/[[:space:]]/, "", tagstr)
        n2 = split(tagstr, tags, ",")
        keep = 0
        for (i = 1; i <= n2; i++) {
          if (tags[i] != "" && act[tags[i]]) { keep = 1; break }
        }
        if (!keep) next
      }
      print
    }
  '
}

# Extract only the ## Hard-enforcement section from a digest file.
extract_hard_section() {
  awk '
    /^## Hard-enforcement/ { in_hard = 1; print; next }
    /^## Soft-enforcement/ { in_hard = 0 }
    in_hard { print }
  ' "$1"
}

# Count hard policies in a digest file (for header metadata).
count_hard() {
  grep -c '^- \[hard\]' "$1" 2>/dev/null || echo 0
}

# Count total policies in a digest file.
count_total() {
  grep -c '^- \[' "$1" 2>/dev/null || echo 0
}

# Emit the policy digest block
emit_block() {
  printf '<policy-digest>\n'
  printf '# Applicable Policies (auto-loaded at session start)\n\n'
  printf '> Injected by `.claude/hooks/load-policies-for-session.sh` | Rebuild digests: `bash scripts/build-policy-digest.sh`\n'
  if [ -n "$HQ_ACTIVE_SERVICES" ]; then
    printf '> Active stack filter: `%s` — stack-specific policies outside this set are hidden\n' "$HQ_ACTIVE_SERVICES"
  fi

  # Global (hard-enforcement only)
  if [ -f "$GLOBAL_DIGEST" ]; then
    local hard_count total_count
    hard_count=$(count_hard "$GLOBAL_DIGEST")
    total_count=$(count_total "$GLOBAL_DIGEST")
    printf '\n## Global (hard-enforcement only — %d of %d policies)\n\n' "$hard_count" "$total_count"
    printf '> Full global digest (hard + soft): `.claude/policies/_digest.md`\n\n'
    extract_hard_section "$GLOBAL_DIGEST" | filter_by_stack
  fi

  # Company digest (full)
  if [ -n "$ACTIVE_CO" ]; then
    local co_digest="$HQ_ROOT/companies/$ACTIVE_CO/policies/_digest.md"
    if [ -f "$co_digest" ]; then
      printf '\n## Company: %s (full)\n\n' "$ACTIVE_CO"
      # Skip the file's own header, start from first policy section
      awk '/^## (Hard|Soft)-enforcement/ { in_body = 1 } in_body { print }' "$co_digest" | filter_by_stack
    fi
  fi

  # Repo digest (full)
  if [ -n "$ACTIVE_REPO" ] && [ -n "$ACTIVE_REPO_SCOPE" ]; then
    local repo_digest="$HQ_ROOT/repos/$ACTIVE_REPO_SCOPE/$ACTIVE_REPO/.claude/policies/_digest.md"
    if [ -f "$repo_digest" ]; then
      printf '\n## Repo: %s/%s (full)\n\n' "$ACTIVE_REPO_SCOPE" "$ACTIVE_REPO"
      awk '/^## (Hard|Soft)-enforcement/ { in_body = 1 } in_body { print }' "$repo_digest" | filter_by_stack
    fi
  fi

  printf '\n</policy-digest>\n'
}

# Emit a minimal stub on resume/compact — prior context already has policy state
emit_slim() {
  printf '<policy-digest>\n'
  printf '# Session resume — policies loaded via prior context\n\n'
  printf '> Full digest: `.claude/policies/_digest.md` | Rebuild: `bash scripts/build-policy-digest.sh`\n'
  if [ -n "$ACTIVE_CO" ]; then
    printf '> Active company: **%s** — policies at `companies/%s/policies/`\n' "$ACTIVE_CO" "$ACTIVE_CO"
  fi
  if [ -n "$ACTIVE_REPO" ] && [ -n "$ACTIVE_REPO_SCOPE" ]; then
    printf '> Active repo: **%s/%s** — policies at `repos/%s/%s/.claude/policies/`\n' "$ACTIVE_REPO_SCOPE" "$ACTIVE_REPO" "$ACTIVE_REPO_SCOPE" "$ACTIVE_REPO"
  fi
  printf '\n</policy-digest>\n'
}

# Resolve active service set once before dispatch so both emit paths see it.
resolve_active_services

# Dispatch: slim on resume/compact, full on startup (and any unknown source)
if [ "$SOURCE" = "resume" ] || [ "$SOURCE" = "compact" ]; then
  emit_slim
else
  emit_block
fi
exit 0
