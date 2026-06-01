#!/bin/bash
# load-policies-for-session.sh — SessionStart hook that injects applicable
# policy digests into session context.
#
# Detects cwd → active company (companies/{co}) and/or active repo
# (repos/{scope}/{name}). Emits a <policy-digest> block containing:
#   1. Hard-enforcement global policies (core/policies/_digest.md hard section)
#   2. Full company digest if in company context
#   3. Full repo digest if in repo context
#
# Soft-enforcement globals are NOT auto-loaded (budget reasons). Read
# `core/policies/_digest.md` manually if you need them.
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

# Determine HQ_ROOT by walking up until we find core/policies + companies/
# with at least one real company (not just the _template scaffold — that would
# catch hq-starter-kit and treat it as an independent HQ).
HQ_ROOT=""
CWD="$(pwd)"
search="$CWD"
while [ "$search" != "/" ]; do
  if [ -d "$search/core/policies" ] && [ -d "$search/companies" ]; then
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
[ -z "$HQ_ROOT" ] && HQ_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

GLOBAL_DIGEST="$HQ_ROOT/core/policies/_digest.md"

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
      # Match any line containing the repo name, find preceding company key.
      # Company keys are 2-space-indented under the `companies:` wrapper.
      ACTIVE_CO=$(awk -v repo="$ACTIVE_REPO" '
        /^  [a-z][a-z0-9_-]*:/ { company = $0; sub(/:.*/, "", company); sub(/^[[:space:]]+/, "", company) }
        $0 ~ repo { print company; exit }
      ' "$MANIFEST" 2>/dev/null || true)
    fi
  fi
fi

# Lowest-precedence fallback: the company persisted to this session's meta by
# /startwork (core/scripts/hq-session.sh set company_slug ...). cwd and the
# repo→owner lookup above always win, so this only fires when the user ran
# /startwork {co} from a location that doesn't itself reveal the company
# (e.g. the HQ root). Without this, `/startwork {company}` from the root never
# loads that company's policy digest on the next SessionStart/resume/compact.
if [ -z "$ACTIVE_CO" ]; then
  CURRENT_FILE="$HQ_ROOT/workspace/sessions/.current"
  if [ -f "$CURRENT_FILE" ]; then
    SESSION_ID="$(head -1 "$CURRENT_FILE" 2>/dev/null | tr -d '[:space:]')"
    META="$HQ_ROOT/workspace/sessions/$SESSION_ID/meta.yaml"
    if [ -n "$SESSION_ID" ] && [ -f "$META" ]; then
      META_CO="$(sed -nE 's/^company_slug:[[:space:]]*"?([A-Za-z0-9_-]+)"?[[:space:]]*$/\1/p' "$META" | head -1)"
      # Validate the slug is a real top-level company key before accepting it,
      # mirroring the manifest guard used elsewhere (never trust an orphaned slug).
      if [ -n "$META_CO" ]; then
        MANIFEST="$HQ_ROOT/companies/manifest.yaml"
        if [ -f "$MANIFEST" ] && grep -qE "^  ${META_CO}:" "$MANIFEST" 2>/dev/null; then
          ACTIVE_CO="$META_CO"
        fi
      fi
    fi
  fi
fi

# Resolve active service set (space-separated) AND opt-in flag.
#
# Sources, in priority order:
#   1. companies/manifest.yaml block for $ACTIVE_CO — supports both
#      inline `services: [a, b]` and block `services:\n  - a\n  - b`
#      formats. Plus inferred vercel from `vercel_team:`, aws from
#      `aws_profile:`.
#   2. .claude/stack.yaml `services: [...]` (HQ-root or repo-root
#      fallback). Used when no active company.
#
# HQ_HAS_EXPLICIT_SERVICES=1 if ≥1 service was declared via an explicit
# `services:` key. Empty `services: []` and inferred-only
# (vercel_team/aws_profile) do NOT flip it — those are weaker / ambiguous
# signals. Companies that haven't audited their service list keep legacy
# fail-open behavior.
#
# Normalization: each service added verbatim AND its first `-`-segment, so
# manifest "shopify-partner" matches policy tags "shopify" or
# "shopify-partner".
HQ_ACTIVE_SERVICES=""
HQ_HAS_EXPLICIT_SERVICES=0
resolve_active_services() {
  local raw=""
  if [ -n "$ACTIVE_CO" ]; then
    local co_manifest="$HQ_ROOT/companies/manifest.yaml"
    if [ -f "$co_manifest" ]; then
      raw=$(awk -v co="$ACTIVE_CO" '
        $0 ~ "^  " co ":" { in_co = 1; in_block_svc = 0; next }
        in_co && /^  [a-z][a-z0-9_-]*:/ { exit }
        # Inline: services: [a, b, c]
        in_co && /^[[:space:]]*services:[[:space:]]*\[/ {
          line = $0
          sub(/.*services:[[:space:]]*\[/, "", line)
          sub(/\].*/, "", line)
          gsub(/,/, " ", line)
          print "SERVICES:" line
          in_block_svc = 0
          next
        }
        # Block opener: services:
        in_co && /^[[:space:]]*services:[[:space:]]*$/ {
          in_block_svc = 1
          next
        }
        # Block item: starts with `-` at deeper indent
        in_co && in_block_svc && /^[[:space:]]+-[[:space:]]+[^[:space:]#]/ {
          line = $0
          sub(/^[[:space:]]+-[[:space:]]+/, "", line)
          sub(/[[:space:]]+#.*/, "", line)
          gsub(/[[:space:]]/, "", line)
          if (line != "") print "SERVICES:" line
          next
        }
        # Block exits when we see a non-`-` line at field depth
        in_co && in_block_svc && /^[[:space:]]*[A-Za-z_]/ { in_block_svc = 0 }
        in_co && /^[[:space:]]*vercel_team:[[:space:]]*[^[:space:]#]/ { print "VERCEL:1" }
        in_co && /^[[:space:]]*aws_profile:[[:space:]]*[^[:space:]#]/ { print "AWS:1" }
      ' "$co_manifest" 2>/dev/null || true)
    fi
  fi
  if [ -z "$ACTIVE_CO" ]; then
    local stack_yaml="$HQ_ROOT/.claude/stack.yaml"
    if [ -f "$stack_yaml" ]; then
      local stack_raw
      stack_raw=$(awk '
        /^[[:space:]]*services:[[:space:]]*\[/ {
          line = $0
          sub(/.*services:[[:space:]]*\[/, "", line)
          sub(/\].*/, "", line)
          gsub(/,/, " ", line)
          print "SERVICES:" line
          in_block_svc = 0
          next
        }
        /^[[:space:]]*services:[[:space:]]*$/ { in_block_svc = 1; next }
        in_block_svc && /^[[:space:]]+-[[:space:]]+[^[:space:]#]/ {
          line = $0
          sub(/^[[:space:]]+-[[:space:]]+/, "", line)
          sub(/[[:space:]]+#.*/, "", line)
          gsub(/[[:space:]]/, "", line)
          if (line != "") print "SERVICES:" line
          next
        }
        in_block_svc && /^[[:space:]]*[A-Za-z_]/ { in_block_svc = 0 }
      ' "$stack_yaml" 2>/dev/null || true)
      raw="$stack_raw"
      # stack.yaml existence + services key declaration is itself the
      # explicit opt-in even if list is empty (HQ-root user wrote it on purpose)
      if grep -qE '^[[:space:]]*services:' "$stack_yaml" 2>/dev/null; then
        HQ_HAS_EXPLICIT_SERVICES=1
      fi
    fi
  fi

  local services="" has_vercel=0 has_aws=0
  while IFS= read -r line; do
    case "$line" in
      SERVICES:*) services="$services ${line#SERVICES:}" ;;
      VERCEL:1) has_vercel=1 ;;
      AWS:1) has_aws=1 ;;
    esac
  done <<< "$raw"

  # Manifest opt-in: at least one service from explicit `services:` key
  # (inline non-empty or block with items). vercel_team/aws_profile
  # inference doesn't count.
  local trimmed
  trimmed=$(echo "$services" | tr -s ' ' | sed 's/^ *//;s/ *$//')
  if [ -n "$trimmed" ] && [ -n "$ACTIVE_CO" ]; then
    HQ_HAS_EXPLICIT_SERVICES=1
  fi

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

# Filter digest lines by HQ_ACTIVE_SERVICES + flow-tag whitelist.
#
# Lines without an `<!-- applies_to: -->` HTML-comment suffix always pass
# (cross-cutting policies). Lines with one pass only if at least one tag
# matches HQ_ACTIVE_SERVICES or HQ_FLOW_TAGS.
#
# Strict mode (HQ_HAS_EXPLICIT_SERVICES=1) — drop tagged lines whose tags
# aren't in the active set (modulo flow-tag whitelist). Engaged when:
#   - HQ root has `.claude/stack.yaml` with a `services:` key, OR
#   - active company manifest has a non-empty `services:` array
#
# Legacy mode (HQ_HAS_EXPLICIT_SERVICES=0) — fail open. Companies that
# haven't audited their manifest don't lose policies they actually use.
#
# Indentation-aware: when a `- [hard] **slug**` header is dropped, its
# indented `*Rationale*`/`*Provenance*` continuation lines drop too. The
# skip flag resets on the next `- [` header or `## ` section boundary.
HQ_FLOW_TAGS="hq run-project execute-task task-execution social"
filter_by_stack() {
  if [ "$HQ_HAS_EXPLICIT_SERVICES" != "1" ]; then
    cat
    return
  fi
  awk -v active="$HQ_ACTIVE_SERVICES" -v flow="$HQ_FLOW_TAGS" '
    BEGIN {
      n = split(active, parts, /[ ,]+/)
      for (i = 1; i <= n; i++) if (parts[i] != "") act[parts[i]] = 1
      n = split(flow, parts, /[ ,]+/)
      for (i = 1; i <= n; i++) if (parts[i] != "") flowt[parts[i]] = 1
    }
    /^## / { skip = 0; print; next }
    /^- \[/ {
      skip = 0
      line = $0
      if (match(line, /<!-- applies_to:[[:space:]]*[^>]*-->/)) {
        tagstr = substr(line, RSTART, RLENGTH)
        sub(/.*applies_to:[[:space:]]*/, "", tagstr)
        sub(/[[:space:]]*-->.*/, "", tagstr)
        gsub(/[[:space:]]/, "", tagstr)
        n2 = split(tagstr, tags, ",")
        keep = 0
        for (i = 1; i <= n2; i++) {
          if (tags[i] != "" && (act[tags[i]] || flowt[tags[i]])) { keep = 1; break }
        }
        if (!keep) skip = 1
      }
      if (skip) next
      print
      next
    }
    skip { next }
    { print }
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

# Extract ## Hard-enforcement section, omitting command-scoped policies
# (slug prefix `hq-cmd-`). Used only for the global cold-start digest:
# command-scoped rules are loaded on-demand by their command's auto-loader,
# so they don't need to inject at every session start. Drops the policy
# header line plus its indented Rationale/Provenance continuations until
# the next policy or section. Saves ~9-10KB per cold-start.
extract_hard_section_global() {
  awk '
    /^## Hard-enforcement/ { in_hard = 1; skip_cmd = 0; print; next }
    /^## Soft-enforcement/ { in_hard = 0; skip_cmd = 0 }
    !in_hard { next }
    /^- \[hard\] \*\*hq-cmd-/ { skip_cmd = 1; next }
    /^- \[/ { skip_cmd = 0 }
    /^## / { skip_cmd = 0 }
    skip_cmd { next }
    { print }
  ' "$1"
}

# Slug + rule-summary global render (Change 5, Variant A). Same as
# extract_hard_section_global but additionally drops indented continuation
# lines (`*Rationale*`, `*Provenance*`). Each policy collapses to its
# `- [hard] **slug**: rule summary <!-- applies_to: tag -->` header line.
# Cuts global cold-start from ~70KB to ~36KB while preserving the slug
# and one-line rule summary that the model needs to know each rule
# exists and roughly what it requires. Full text remains at
# `core/policies/{slug}.md`. Override with HQ_GLOBAL_FULL=1.
extract_hard_section_global_slug() {
  awk '
    /^## Hard-enforcement/ { in_hard = 1; skip_cmd = 0; print; next }
    /^## Soft-enforcement/ { in_hard = 0; skip_cmd = 0 }
    !in_hard { next }
    /^- \[hard\] \*\*hq-cmd-/ { skip_cmd = 1; next }
    /^- \[/ { skip_cmd = 0; print; next }
    /^## / { skip_cmd = 0 }
    skip_cmd { next }
    /^[[:space:]]/ { next }
    { print }
  ' "$1"
}

# Count hard policies in a digest file (for header metadata).
count_hard() {
  grep -c '^- \[hard\]' "$1" 2>/dev/null || echo 0
}

# Count hard policies excluding command-scoped slugs (matches
# extract_hard_section_global's filter).
count_hard_global() {
  local total cmd
  total=$(grep -c '^- \[hard\]' "$1" 2>/dev/null || echo 0)
  cmd=$(grep -c '^- \[hard\] \*\*hq-cmd-' "$1" 2>/dev/null || echo 0)
  echo $((total - cmd))
}

# Count total policies in a digest file.
count_total() {
  grep -c '^- \[' "$1" 2>/dev/null || echo 0
}

# Emit the policy digest block
emit_block() {
  printf '<policy-digest>\n'
  printf '# Applicable Policies (auto-loaded at session start)\n\n'
  printf '> Injected by `.claude/hooks/load-policies-for-session.sh` | Rebuild digests: `bash core/scripts/build-policy-digest.sh`\n'
  if [ "$HQ_HAS_EXPLICIT_SERVICES" = "1" ]; then
    if [ -n "$HQ_ACTIVE_SERVICES" ]; then
      printf '> Active stack filter: `%s` — integration policies outside this set are hidden (flow tags always pass)\n' "$HQ_ACTIVE_SERVICES"
    else
      printf '> Active stack filter: `<empty>` — all integration-tagged policies hidden (flow tags always pass)\n'
    fi
  fi

  # Global (hard-enforcement only, excluding command-scoped policies)
  if [ -f "$GLOBAL_DIGEST" ]; then
    local hard_count total_count
    hard_count=$(count_hard_global "$GLOBAL_DIGEST")
    total_count=$(count_total "$GLOBAL_DIGEST")
    printf '\n## Global (hard-enforcement, non-command-scoped — %d of %d policies)\n\n' "$hard_count" "$total_count"
    if [ "${HQ_GLOBAL_FULL:-0}" = "1" ]; then
      printf '> Full global digest (hard + soft, includes command-scoped): `core/policies/_digest.md`\n'
      printf '> Render mode: **full** (HQ_GLOBAL_FULL=1) — rationale + provenance included\n\n'
      extract_hard_section_global "$GLOBAL_DIGEST" | filter_by_stack
    else
      printf '> Slug + rule-summary only — full text per policy: `core/policies/{slug}.md` (or `qmd get -c hq {slug}`). Override: `HQ_GLOBAL_FULL=1`\n\n'
      extract_hard_section_global_slug "$GLOBAL_DIGEST" | filter_by_stack
    fi
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
  printf '> Full digest: `core/policies/_digest.md` | Rebuild: `bash core/scripts/build-policy-digest.sh`\n'
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
