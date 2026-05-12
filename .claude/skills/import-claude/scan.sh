#!/usr/bin/env bash
# /import-claude scanner — read-only discovery of Claude artifacts on disk.
# Emits JSON to stdout (or --output path). Safe to run anytime; never writes state.

set -euo pipefail

# ──────────────────────── args ────────────────────────
HQ_ROOT=""
OUTPUT=""
SCOPES=()
NO_DEFAULT_SCOPES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hq-root=*) HQ_ROOT="${1#*=}" ;;
    --output=*) OUTPUT="${1#*=}" ;;
    --scope=*) SCOPES+=("${1#*=}") ;;
    --no-default-scopes) NO_DEFAULT_SCOPES=true ;;
    -h|--help)
      cat <<'EOF'
Usage: scan.sh --hq-root=<path> [--output=<json>] [--scope=<dir>]...

Emits a JSON catalog of Claude artifacts discovered across allowlisted parents
plus any --scope dirs. HQ root is self-excluded.
EOF
      exit 0
      ;;
    *) echo "scan.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -z "$HQ_ROOT" ]]; then
  echo "scan.sh: --hq-root is required" >&2; exit 2
fi
HQ_ROOT="$(cd "$HQ_ROOT" && pwd)"

command -v jq >/dev/null 2>&1 || { echo "scan.sh: jq is required" >&2; exit 2; }
SHASUM="shasum -a 256"
command -v shasum >/dev/null 2>&1 || SHASUM="sha256sum"

# ──────────────────────── allowlist + scopes ────────────────────────
DEFAULT_PARENTS=(
  "$HOME/.claude"
  "$HOME/Documents"
  "$HOME/code"
  "$HOME/dev"
  "$HOME/Projects"
  "$HOME/src"
  "$HOME/work"
  "$HOME/github"
  "$HOME/repos"
)

declare -a PARENTS=()
if ! $NO_DEFAULT_SCOPES; then
  for p in "${DEFAULT_PARENTS[@]}"; do
    [[ -d "$p" ]] && PARENTS+=("$p")
  done
fi
for s in "${SCOPES[@]:-}"; do
  [[ -d "$s" ]] && PARENTS+=("$(cd "$s" && pwd)")
done

# Dedupe parents.
if [[ ${#PARENTS[@]} -gt 0 ]]; then
  IFS=$'\n' PARENTS=($(printf "%s\n" "${PARENTS[@]}" | awk '!seen[$0]++'))
  unset IFS
fi

# ──────────────────────── denylist ────────────────────────
# Prune expressions for `find`. Paths absolute; dirs basenames pruned globally.
PRUNE_BASENAMES=(
  node_modules .git dist build .next .venv __pycache__
  .cache .npm .pnpm .Trash pkg
)
PRUNE_ABS_PATHS=(
  "$HQ_ROOT"
  "$HOME/.claude/projects"
  "$HOME/.claude/cache"
  "$HOME/.claude/shell-snapshots"
  "$HOME/.claude/paste-cache"
  "$HOME/.claude/file-history"
  "$HOME/.claude/downloads"
  "$HOME/.claude/context-mode"
  "$HOME/Library/Logs"
  "$HOME/Library/Caches"
  "$HOME/go/pkg"
)

build_find_prune() {
  # Emit the `( -path X -o -path Y ... ) -prune -o` fragment.
  local frags=()
  for n in "${PRUNE_BASENAMES[@]}"; do frags+=( -name "$n" -o ); done
  # Remove trailing -o
  unset 'frags[${#frags[@]}-1]'
  # Combine with abs-path prunes
  local abs=()
  for p in "${PRUNE_ABS_PATHS[@]}"; do abs+=( -path "$p" -o ); done
  if [[ ${#abs[@]} -gt 0 ]]; then
    unset 'abs[${#abs[@]}-1]'
    printf "( ( %s ) -o ( %s ) ) -prune -o" \
      "${frags[*]}" "${abs[*]}"
  else
    printf "( %s ) -prune -o" "${frags[*]}"
  fi
}

# ──────────────────────── helpers ────────────────────────
hash_file() { $SHASUM "$1" 2>/dev/null | awk '{print $1}'; }
bytes_of()  { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null; }
sub_home()  { printf "%s" "${1/#$HOME/\$HOME}"; }

# Read first N lines of a file, HTML/JSON-escape unsafe chars via jq -Rs.
# Always emits a valid JSON string — never empty output.
preview_file() {
  local f="$1" n="${2:-40}"
  local out
  out="$(head -n "$n" "$f" 2>/dev/null | jq -Rs . 2>/dev/null)"
  if [[ -z "$out" ]]; then
    printf '""'
  else
    printf "%s" "$out"
  fi
}

# Normalize a JSON-string variable: if empty or unparseable, return "[]".
ensure_json_array() {
  local v="$1"
  if [[ -z "$v" ]]; then printf "[]"; return; fi
  if echo "$v" | jq empty 2>/dev/null; then
    printf "%s" "$v"
  else
    printf "[]"
  fi
}

entry_json() {
  # Args: category source_path suggested_destination
  local cat="$1" src="$2" dest="$3"
  local bytes sha prev sub
  bytes="$(bytes_of "$src")"
  sha="$(hash_file "$src")"
  prev="$(preview_file "$src" 40)"
  sub="$(sub_home "$src")"
  jq -n \
    --arg category "$cat" \
    --arg source_path "$sub" \
    --arg suggested_destination "$dest" \
    --argjson bytes "${bytes:-0}" \
    --arg sha256 "${sha:-}" \
    --argjson preview "$prev" \
    '{
      category: $category,
      source_path: $source_path,
      bytes: $bytes,
      sha256: $sha256,
      preview: $preview,
      suggested_destination: $suggested_destination,
      suggested_company: null,
      conflict: {exists: false, hash_match: false, dest_sha256: null},
      already_imported: false,
      redacted_fields: []
    }'
}

# ──────────────────────── category emitters ────────────────────────
emit_plans()       { local arr=(); local f;
  [[ -d "$HOME/.claude/plans" ]] || { echo "[]"; return; }
  while IFS= read -r -d '' f; do
    arr+=("$(entry_json plans "$f" "workspace/imports/ontology-input/$(basename "$f")")")
  done < <(find "$HOME/.claude/plans" -maxdepth 1 -type f -name "*.md" -print0 2>/dev/null)
  printf "%s" "$(printf "%s\n" "${arr[@]:-}" | jq -s '.')"
}

emit_mcp_servers() { local f="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
  local arr=()
  if [[ -f "$f" ]]; then
    arr+=("$(entry_json mcp_servers "$f" ".claude/settings.json#mcpServers")")
  fi
  # Also pick up repo-root .mcp.json files below
  printf "%s" "$(printf "%s\n" "${arr[@]:-}" | jq -s '.')"
}

emit_global_configs() {
  local arr=()
  [[ -f "$HOME/.claude.json" ]]            && arr+=("$(entry_json settings_fragments "$HOME/.claude.json" ".claude/settings.json")")
  [[ -f "$HOME/.claude/settings.json" ]]   && arr+=("$(entry_json settings_fragments "$HOME/.claude/settings.json" ".claude/settings.json")")
  [[ -f "$HOME/.claude/settings.local.json" ]] && arr+=("$(entry_json settings_fragments "$HOME/.claude/settings.local.json" ".claude/settings.local.json")")
  printf "%s" "$(printf "%s\n" "${arr[@]:-}" | jq -s '.')"
}

# Scan all allowlisted parents for .claude directories, CLAUDE.md files, and .mcp.json.
# Emits 4 named lists: CLAUDE_DIRS, CLAUDE_MD_FILES, MCP_JSON_FILES, REPOS.
scan_trees() {
  local parent
  local prune_frag
  prune_frag="$(build_find_prune)"

  CLAUDE_DIRS=()
  CLAUDE_MD_FILES=()
  MCP_JSON_FILES=()
  REPOS=()

  for parent in "${PARENTS[@]:-}"; do
    # .claude directories
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      # Skip if inside HQ (paranoid)
      case "$d" in "$HQ_ROOT"/*|"$HQ_ROOT") continue ;; esac
      CLAUDE_DIRS+=("$d")
    done < <(eval find "$parent" -maxdepth 6 "$prune_frag" -type d -name .claude -print 2>/dev/null)

    # CLAUDE.md files
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      case "$f" in "$HQ_ROOT"/*) continue ;; esac
      CLAUDE_MD_FILES+=("$f")
    done < <(eval find "$parent" -maxdepth 6 "$prune_frag" -type f -name "CLAUDE.md" -print 2>/dev/null)

    # .mcp.json files (Claude Code-compatible MCP configs at repo roots)
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      case "$f" in "$HQ_ROOT"/*) continue ;; esac
      MCP_JSON_FILES+=("$f")
    done < <(eval find "$parent" -maxdepth 6 "$prune_frag" -type f -name ".mcp.json" -print 2>/dev/null)
  done

  # Derive "claude repos" from .claude dir parents.
  local d
  for d in "${CLAUDE_DIRS[@]:-}"; do
    local repo_root; repo_root="$(dirname "$d")"
    REPOS+=("$repo_root")
  done
}

# Emit entries for every file inside every discovered .claude directory.
emit_claude_tree_artifacts() {
  local d f cat dest
  local cmds=() skills_a=() hooks=() pols=() agents=() settings=()
  for d in "${CLAUDE_DIRS[@]:-}"; do
    # commands
    if [[ -d "$d/commands" ]]; then
      while IFS= read -r -d '' f; do
        cmds+=("$(entry_json commands "$f" ".claude/commands/$(basename "$f")")")
      done < <(find "$d/commands" -maxdepth 2 -type f -name "*.md" -print0 2>/dev/null)
    fi
    # skills
    if [[ -d "$d/skills" ]]; then
      # One entry per skill directory (pointing to SKILL.md or command.md)
      while IFS= read -r -d '' sd; do
        local anchor="$sd/SKILL.md"
        [[ -f "$anchor" ]] || anchor="$sd/command.md"
        [[ -f "$anchor" ]] || continue
        local name; name="$(basename "$sd")"
        skills_a+=("$(entry_json skills "$anchor" ".claude/skills/$name/$(basename "$anchor")")")
      done < <(find "$d/skills" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi
    # hooks
    if [[ -d "$d/hooks" ]]; then
      while IFS= read -r -d '' f; do
        hooks+=("$(entry_json hooks "$f" ".claude/hooks/$(basename "$f")")")
      done < <(find "$d/hooks" -maxdepth 1 -type f \( -name "*.sh" -o -name "*.js" -o -name "*.ts" \) -print0 2>/dev/null)
    fi
    # policies
    if [[ -d "$d/policies" ]]; then
      while IFS= read -r -d '' f; do
        pols+=("$(entry_json policies "$f" "core/policies/$(basename "$f")")")
      done < <(find "$d/policies" -maxdepth 2 -type f -name "*.md" -print0 2>/dev/null)
    fi
    # agents
    if [[ -d "$d/agents" ]]; then
      while IFS= read -r -d '' f; do
        agents+=("$(entry_json agents "$f" ".claude/agents/$(basename "$f")")")
      done < <(find "$d/agents" -maxdepth 1 -type f -name "*.md" -print0 2>/dev/null)
    fi
    # settings (discovered per-.claude, not the global ones already emitted)
    if [[ -f "$d/settings.json" ]]; then
      settings+=("$(entry_json settings_fragments "$d/settings.json" ".claude/settings.json")")
    fi
    if [[ -f "$d/settings.local.json" ]]; then
      settings+=("$(entry_json settings_fragments "$d/settings.local.json" ".claude/settings.local.json")")
    fi
  done

  local cmds_json skills_json hooks_json pols_json agents_json settings_json
  cmds_json="$(printf "%s\n" "${cmds[@]:-}" | jq -s '.')"
  skills_json="$(printf "%s\n" "${skills_a[@]:-}" | jq -s '.')"
  hooks_json="$(printf "%s\n" "${hooks[@]:-}" | jq -s '.')"
  pols_json="$(printf "%s\n" "${pols[@]:-}" | jq -s '.')"
  agents_json="$(printf "%s\n" "${agents[@]:-}" | jq -s '.')"
  settings_json="$(printf "%s\n" "${settings[@]:-}" | jq -s '.')"

  jq -n \
    --argjson commands "$cmds_json" \
    --argjson skills "$skills_json" \
    --argjson hooks "$hooks_json" \
    --argjson policies "$pols_json" \
    --argjson agents "$agents_json" \
    --argjson settings "$settings_json" \
    '{commands:$commands, skills:$skills, hooks:$hooks, policies:$policies, agents:$agents, settings:$settings}'
}

emit_claude_md() {
  local arr=() f
  for f in "${CLAUDE_MD_FILES[@]:-}"; do
    local parent; parent="$(dirname "$f")"
    arr+=("$(entry_json claude_md "$f" "$parent/CLAUDE.md")")
  done
  printf "%s" "$(printf "%s\n" "${arr[@]:-}" | jq -s '.')"
}

emit_repo_mcp_json() {
  local arr=() f
  for f in "${MCP_JSON_FILES[@]:-}"; do
    arr+=("$(entry_json mcp_servers "$f" ".claude/settings.json#mcpServers")")
  done
  printf "%s" "$(printf "%s\n" "${arr[@]:-}" | jq -s '.')"
}

emit_claude_repos() {
  local arr=() r seen=""
  for r in "${REPOS[@]:-}"; do
    [[ ":$seen:" == *":$r:"* ]] && continue
    seen="$seen:$r"
    local sub; sub="$(sub_home "$r")"
    # Classify: knowledge-shaped? has git?
    local is_git=false is_knowledge=false
    [[ -d "$r/.git" ]] && is_git=true
    [[ -d "$r/knowledge" || "$(basename "$r")" == knowledge-* ]] && is_knowledge=true
    arr+=("$(jq -n \
      --arg category "claude_repos" \
      --arg source_path "$sub" \
      --arg suggested_destination "repos/private/$(basename "$r")" \
      --argjson is_git "$is_git" \
      --argjson is_knowledge "$is_knowledge" \
      '{
        category: $category,
        source_path: $source_path,
        suggested_destination: $suggested_destination,
        is_git: $is_git,
        is_knowledge: $is_knowledge,
        suggested_company: null,
        conflict: {exists: false, hash_match: false, dest_sha256: null},
        already_imported: false
      }')")
  done
  printf "%s" "$(printf "%s\n" "${arr[@]:-}" | jq -s '.')"
}

# ──────────────────────── assemble report ────────────────────────
main() {
  scan_trees

  local scan_id
  scan_id="$(date +%Y-%m-%dT%H-%M-%S)"

  local tmpd
  tmpd="$(mktemp -d 2>/dev/null || mktemp -d -t import-claude)"
  trap 'rm -rf "$tmpd"' RETURN

  # Build all category JSON, normalize empties to [], write to temp files
  # so `jq --slurpfile` can read them without blowing up the exec arg cap.
  ensure_json_array "$(printf "%s\n" "${PARENTS[@]:-}" | jq -R . | jq -s '.')" > "$tmpd/scope.json"
  ensure_json_array "$(emit_plans)"                        > "$tmpd/plans.json"
  ensure_json_array "$(emit_claude_md)"                    > "$tmpd/claude_md.json"
  ensure_json_array "$(emit_claude_repos)"                 > "$tmpd/claude_repos.json"

  # Tree artifacts return an object, not an array — handle separately.
  local tree_json
  tree_json="$(emit_claude_tree_artifacts)"
  if [[ -z "$tree_json" ]] || ! echo "$tree_json" | jq empty 2>/dev/null; then
    tree_json='{"commands":[],"skills":[],"hooks":[],"policies":[],"agents":[],"settings":[]}'
  fi
  printf "%s" "$tree_json" > "$tmpd/tree.json"

  # Merge MCP sources (desktop config + repo-root .mcp.json)
  local mcp_desktop mcp_repo
  mcp_desktop="$(ensure_json_array "$(emit_mcp_servers)")"
  mcp_repo="$(ensure_json_array "$(emit_repo_mcp_json)")"
  jq -n --argjson a "$mcp_desktop" --argjson b "$mcp_repo" '$a + $b' > "$tmpd/mcp.json"

  # Merge settings fragments (global files + per-.claude)
  local globals
  globals="$(ensure_json_array "$(emit_global_configs)")"
  printf "%s" "$globals" > "$tmpd/globals.json"
  jq -n \
    --slurpfile g "$tmpd/globals.json" \
    --slurpfile t "$tmpd/tree.json" \
    '$g[0] + $t[0].settings' > "$tmpd/settings.json"

  # Final report — composed via --slurpfile so argv stays tiny.
  jq -n \
    --arg scan_id "$scan_id" \
    --slurpfile scope        "$tmpd/scope.json" \
    --slurpfile tree         "$tmpd/tree.json" \
    --slurpfile plans        "$tmpd/plans.json" \
    --slurpfile mcp          "$tmpd/mcp.json" \
    --slurpfile settings     "$tmpd/settings.json" \
    --slurpfile claude_md    "$tmpd/claude_md.json" \
    --slurpfile claude_repos "$tmpd/claude_repos.json" \
    '{
      scan_id: $scan_id,
      scope: $scope[0],
      categories: {
        plans: $plans[0],
        commands: $tree[0].commands,
        skills: $tree[0].skills,
        hooks: $tree[0].hooks,
        policies: $tree[0].policies,
        agents: $tree[0].agents,
        claude_md: $claude_md[0],
        settings_fragments: $settings[0],
        mcp_servers: $mcp[0],
        knowledge_dirs: [],
        claude_repos: $claude_repos[0]
      }
    } | .counts = (.categories | map_values(length))' > "$tmpd/report.json"

  if [[ -n "$OUTPUT" ]]; then
    mkdir -p "$(dirname "$OUTPUT")"
    cp "$tmpd/report.json" "$OUTPUT"
    echo "$OUTPUT"
  else
    cat "$tmpd/report.json"
  fi
}

main
