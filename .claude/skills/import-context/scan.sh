#!/usr/bin/env bash
# /import-context scanner — read-only discovery of AI artifacts + conversation stores on disk.
# Emits JSON to stdout (or --output path). Safe to run anytime; never writes state.

set -euo pipefail

# ──────────────────────── args ────────────────────────
HQ_ROOT=""
OUTPUT=""
SCOPES=()
CLAUDE_EXPORT=""
NO_DEFAULT_SCOPES=false
PROGRESS_JSON=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hq-root=*) HQ_ROOT="${1#*=}" ;;
    --output=*) OUTPUT="${1#*=}" ;;
    --scope=*) SCOPES+=("${1#*=}") ;;
    --claude-export=*) CLAUDE_EXPORT="${1#*=}" ;;
    --no-default-scopes) NO_DEFAULT_SCOPES=true ;;
    --progress-json) PROGRESS_JSON=true ;;
    -h|--help)
      cat <<'EOF'
Usage: scan.sh --hq-root=<path> [--output=<json>] [--scope=<dir>]... [--claude-export=<path>]
               [--progress-json]

Emits a JSON catalog of AI artifacts discovered across allowlisted parents
plus any --scope dirs, and store-level entries for conversation history
(Claude Code, Codex, Grok, and an optional claude.ai data export).
HQ root is self-excluded.

--progress-json  Print JSON Lines progress events on stdout while scanning
                 (sources, counts, companies, projects, then a final "done"
                 event naming the report). Requires --output; the report file
                 is byte-identical to a run without the flag. Contract:
                 progress-json.md next to this script.
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
if $PROGRESS_JSON && [[ -z "$OUTPUT" ]]; then
  echo "scan.sh: --progress-json requires --output=<report.json> (stdout carries the event stream)" >&2; exit 2
fi
HQ_ROOT="$(cd "$HQ_ROOT" && pwd)"

# Prefer portable require_jq when available (multi-OS install guidance).
if [ -f "$HQ_ROOT/core/scripts/lib/portable.sh" ]; then
  # shellcheck source=core/scripts/lib/portable.sh
  . "$HQ_ROOT/core/scripts/lib/portable.sh"
  require_jq || { echo "scan.sh: jq is required" >&2; exit 2; }
else
  command -v jq >/dev/null 2>&1 || { echo "scan.sh: jq is required" >&2; exit 2; }
fi
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

# Populate the global FIND_PRUNE array with a `find` pruning expression of the
# shape `( ( -name <base> -o ... ) -o ( -path <abs> -o ... ) ) -prune -o`.
#
# CRITICAL: this is built as an argv ARRAY, not a string that is later `eval`'d.
# The expression contains literal `(` / `)` tokens that `find` requires as its
# own arguments. If they are emitted into a string and run through `eval` (the
# previous implementation), the shell re-parses them as subshell syntax and the
# whole command dies with `syntax error near unexpected token '('` — find exits
# non-zero and returns nothing, so discovery silently finds zero artifacts.
# Passing the parens as separate, individually-quoted array elements hands them
# to find verbatim and sidesteps shell metacharacter interpretation entirely.
FIND_PRUNE=()
build_find_prune() {
  FIND_PRUNE=()
  local base_expr=()
  local n
  for n in "${PRUNE_BASENAMES[@]}"; do base_expr+=( -name "$n" -o ); done
  # Remove trailing -o
  if [[ ${#base_expr[@]} -gt 0 ]]; then unset 'base_expr[${#base_expr[@]}-1]'; fi

  local abs_expr=()
  local p
  for p in "${PRUNE_ABS_PATHS[@]}"; do abs_expr+=( -path "$p" -o ); done

  if [[ ${#abs_expr[@]} -gt 0 ]]; then
    unset 'abs_expr[${#abs_expr[@]}-1]'   # remove trailing -o
    FIND_PRUNE=( '(' '(' "${base_expr[@]}" ')' -o '(' "${abs_expr[@]}" ')' ')' -prune -o )
  else
    FIND_PRUNE=( '(' "${base_expr[@]}" ')' -prune -o )
  fi
}

# ──────────────────────── discovery status ────────────────────────
# Track whether discovery actually completed. A `find` that errors (bad
# expression, unreadable directory, …) must NEVER be silently collapsed into a
# confident "found nothing" — per the never-swallow-errors policy we record the
# failure, surface it loudly on stderr, and expose it in the report so callers
# can distinguish "found none" from "could not look".
# DISCOVERY_LOG is the authoritative, subshell-safe record of discovery
# failures: a temp file (one error per line) created in main() before any scan.
# Several emitters run inside `$(...)` command substitutions (subshells), where
# in-memory array/var mutations would be lost — appending to a shared file the
# subshell inherits the path to is what lets those errors reach the report.
DISCOVERY_LOG=""

# Run `find` capturing stdout (to $1), stderr, and exit code without tripping
# `set -e` or swallowing errors. Any non-zero exit OR non-empty stderr is
# recorded loudly (stderr banner + DISCOVERY_LOG). Never collapses an error
# into a silent empty result. Usage: find_capture <outfile> <label> <find-args...>
find_capture() {
  local outf="$1" label="$2"; shift 2
  local errf rc=0
  errf="$(scan_mktemp)"
  find "$@" >"$outf" 2>"$errf" || rc=$?
  if [[ $rc -ne 0 || -s "$errf" ]]; then
    local detail; detail="$(tr '\n' ' ' < "$errf")"
    [[ -n "${DISCOVERY_LOG:-}" ]] && \
      printf '%s\n' "${label} (find exit ${rc}): ${detail:-<no stderr>}" >> "$DISCOVERY_LOG"
    {
      echo "scan.sh: WARNING: incomplete scan — ${label} (find exit ${rc})"
      [[ -s "$errf" ]] && cat "$errf"
    } >&2
  fi
  rm -f "$errf"
  return 0
}

# ──────────────────────── helpers ────────────────────────
hash_file() { $SHASUM "$1" 2>/dev/null | awk '{print $1}'; }
bytes_of()  { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null; }
sub_home()  { printf "%s" "${1/#$HOME/\$HOME}"; }

# Read first N lines, redact them before display/persistence, and JSON-escape.
# Always emits a valid JSON string — never empty output.
preview_file() {
  local f="$1" n="${2:-40}"
  local out redactor
  redactor="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/redact.sh"
  if ! out="$(head -n "$n" "$f" 2>/dev/null | bash "$redactor" | jq -Rs . 2>/dev/null)"; then
    echo "scan.sh: preview redaction failed for $(sub_home "$f"); omitting preview" >&2
    printf '""'
    return 0
  fi
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
  build_find_prune

  CLAUDE_DIRS=()
  CLAUDE_MD_FILES=()
  MCP_JSON_FILES=()
  REPOS=()

  # No parents to scan → nothing to do (and "${PARENTS[@]}" under set -u with an
  # empty array would error / inject a phantom "" element).
  if [[ ${#PARENTS[@]} -eq 0 ]]; then
    return 0
  fi

  local outf; outf="$(scan_mktemp)"
  for parent in "${PARENTS[@]}"; do
    # .claude directories
    find_capture "$outf" "discover .claude dirs under $(sub_home "$parent")" \
      "$parent" -maxdepth 6 "${FIND_PRUNE[@]}" -type d -name .claude -print
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      # Skip if inside HQ (paranoid)
      case "$d" in "$HQ_ROOT"/*|"$HQ_ROOT") continue ;; esac
      CLAUDE_DIRS+=("$d")
    done < "$outf"

    # CLAUDE.md files
    find_capture "$outf" "discover CLAUDE.md under $(sub_home "$parent")" \
      "$parent" -maxdepth 6 "${FIND_PRUNE[@]}" -type f -name "CLAUDE.md" -print
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      case "$f" in "$HQ_ROOT"/*) continue ;; esac
      CLAUDE_MD_FILES+=("$f")
    done < "$outf"

    # .mcp.json files (Claude Code-compatible MCP configs at repo roots)
    find_capture "$outf" "discover .mcp.json under $(sub_home "$parent")" \
      "$parent" -maxdepth 6 "${FIND_PRUNE[@]}" -type f -name ".mcp.json" -print
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      case "$f" in "$HQ_ROOT"/*) continue ;; esac
      MCP_JSON_FILES+=("$f")
    done < "$outf"
  done
  rm -f "$outf"

  # Derive "claude repos" from .claude dir parents.
  if [[ ${#CLAUDE_DIRS[@]} -gt 0 ]]; then
    local d
    for d in "${CLAUDE_DIRS[@]}"; do
      local repo_root; repo_root="$(dirname "$d")"
      REPOS+=("$repo_root")
    done
  fi
}

# Emit entries for every file inside every discovered .claude directory.
emit_claude_tree_artifacts() { # <tree-json-output> <parts-dir>
  local tree_json="$1" parts_dir="$2"
  local d f cat dest
  local cmds=() skills_a=() hooks=() pols=() agents=() settings=()
  # No discovered .claude dirs → nothing to enumerate. Guarding the loop also
  # prevents "${CLAUDE_DIRS[@]}" from injecting a phantom "" element (which used
  # to flow through dirname → "." and produce mangled residue entries).
  if [[ ${#CLAUDE_DIRS[@]} -eq 0 ]]; then
    : # leave all arrays empty
  else
  local tf; tf="$(scan_mktemp)"
  for d in "${CLAUDE_DIRS[@]}"; do
    # commands
    if [[ -d "$d/commands" ]]; then
      find_capture "$tf" "enumerate commands in $(sub_home "$d/commands")" \
        "$d/commands" -maxdepth 2 -type f -name "*.md" -print0
      while IFS= read -r -d '' f; do
        cmds+=("$(entry_json commands "$f" ".claude/commands/$(basename "$f")")")
      done < "$tf"
    fi
    # skills
    if [[ -d "$d/skills" ]]; then
      # One entry per skill directory (pointing to SKILL.md or command.md)
      find_capture "$tf" "enumerate skills in $(sub_home "$d/skills")" \
        "$d/skills" -mindepth 1 -maxdepth 1 -type d -print0
      while IFS= read -r -d '' sd; do
        local anchor="$sd/SKILL.md"
        [[ -f "$anchor" ]] || anchor="$sd/command.md"
        [[ -f "$anchor" ]] || continue
        local name; name="$(basename "$sd")"
        skills_a+=("$(entry_json skills "$anchor" ".claude/skills/$name/$(basename "$anchor")")")
      done < "$tf"
    fi
    # hooks
    if [[ -d "$d/hooks" ]]; then
      find_capture "$tf" "enumerate hooks in $(sub_home "$d/hooks")" \
        "$d/hooks" -maxdepth 1 -type f \( -name "*.sh" -o -name "*.js" -o -name "*.ts" \) -print0
      while IFS= read -r -d '' f; do
        hooks+=("$(entry_json hooks "$f" ".claude/hooks/$(basename "$f")")")
      done < "$tf"
    fi
    # policies
    if [[ -d "$d/policies" ]]; then
      find_capture "$tf" "enumerate policies in $(sub_home "$d/policies")" \
        "$d/policies" -maxdepth 2 -type f -name "*.md" -print0
      while IFS= read -r -d '' f; do
        pols+=("$(entry_json policies "$f" "personal/policies/$(basename "$f")")")
      done < "$tf"
    fi
    # agents
    if [[ -d "$d/agents" ]]; then
      find_capture "$tf" "enumerate agents in $(sub_home "$d/agents")" \
        "$d/agents" -maxdepth 1 -type f -name "*.md" -print0
      while IFS= read -r -d '' f; do
        agents+=("$(entry_json agents "$f" ".claude/agents/$(basename "$f")")")
      done < "$tf"
    fi
    # settings (discovered per-.claude, not the global ones already emitted)
    if [[ -f "$d/settings.json" ]]; then
      settings+=("$(entry_json settings_fragments "$d/settings.json" ".claude/settings.json")")
    fi
    if [[ -f "$d/settings.local.json" ]]; then
      settings+=("$(entry_json settings_fragments "$d/settings.local.json" ".claude/settings.local.json")")
    fi
  done
  rm -f "$tf"
  fi

  # Write each category to a file before composing the tree object. Passing the
  # serialized arrays through --argjson puts every discovered entry in jq's
  # argv, which exceeds ARG_MAX on large Claude installations.
  printf "%s\n" "${cmds[@]:-}"     | jq -s '.' > "$parts_dir/commands.json"
  printf "%s\n" "${skills_a[@]:-}" | jq -s '.' > "$parts_dir/skills.json"
  printf "%s\n" "${hooks[@]:-}"    | jq -s '.' > "$parts_dir/hooks.json"
  printf "%s\n" "${pols[@]:-}"     | jq -s '.' > "$parts_dir/policies.json"
  printf "%s\n" "${agents[@]:-}"   | jq -s '.' > "$parts_dir/agents.json"
  printf "%s\n" "${settings[@]:-}" | jq -s '.' > "$parts_dir/settings.json"

  jq -n \
    --slurpfile commands "$parts_dir/commands.json" \
    --slurpfile skills "$parts_dir/skills.json" \
    --slurpfile hooks "$parts_dir/hooks.json" \
    --slurpfile policies "$parts_dir/policies.json" \
    --slurpfile agents "$parts_dir/agents.json" \
    --slurpfile settings "$parts_dir/settings.json" \
    '{commands:$commands[0], skills:$skills[0], hooks:$hooks[0], policies:$policies[0], agents:$agents[0], settings:$settings[0]}' \
    > "$tree_json"
}

emit_claude_md() {
  local arr=() f
  if [[ ${#CLAUDE_MD_FILES[@]} -gt 0 ]]; then
    for f in "${CLAUDE_MD_FILES[@]}"; do
      local parent; parent="$(dirname "$f")"
      arr+=("$(entry_json claude_md "$f" "$parent/CLAUDE.md")")
    done
  fi
  printf "%s" "$(printf "%s\n" "${arr[@]:-}" | jq -s '.')"
}

emit_repo_mcp_json() {
  local arr=() f
  if [[ ${#MCP_JSON_FILES[@]} -gt 0 ]]; then
    for f in "${MCP_JSON_FILES[@]}"; do
      arr+=("$(entry_json mcp_servers "$f" ".claude/settings.json#mcpServers")")
    done
  fi
  printf "%s" "$(printf "%s\n" "${arr[@]:-}" | jq -s '.')"
}

emit_claude_repos() {
  local arr=() r seen=""
  if [[ ${#REPOS[@]} -eq 0 ]]; then printf "[]"; return; fi
  for r in "${REPOS[@]}"; do
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

# ──────────────────────── conversation stores ────────────────────────
# Store-level discovery of prior AI conversation history. Emits one JSON entry
# per store — source, path, session count, no file contents. Transcripts are
# only ever read later by Phase 3.5 mining sub-agents under the skill's
# sampling + redaction rules. These stores live in $HOME dot-dirs outside every
# scan scope, so the artifact denylist (which prunes ~/.claude/projects from
# the file-artifact walk) intentionally does not apply to this count-only pass.
emit_conversation_stores() {
  local arr=() count d cj

  d="$HOME/.claude/projects"
  if [[ -d "$d" ]]; then
    count="$(find "$d" -type f -name '*.jsonl' 2>>"$DISCOVERY_LOG" | grep -c '' || true)"
    arr+=("$(jq -n --arg p "$(sub_home "$d")" --argjson n "${count:-0}" \
      '{source:"claude-code", path:$p, sessions:$n}')")
  fi

  d="$HOME/.codex/sessions"
  if [[ -d "$d" ]]; then
    count="$(find "$d" -type f -name '*.jsonl' 2>>"$DISCOVERY_LOG" | grep -c '' || true)"
    arr+=("$(jq -n --arg p "$(sub_home "$d")" --argjson n "${count:-0}" \
      '{source:"codex", path:$p, sessions:$n}')")
  fi

  # Grok CLI: ~/.grok/sessions/<url-encoded-cwd>/<session-id>/updates.jsonl
  d="$HOME/.grok/sessions"
  if [[ -d "$d" ]]; then
    count="$(find "$d" -type f -name 'updates.jsonl' 2>>"$DISCOVERY_LOG" | grep -c '' || true)"
    # Include an existing store with zero sessions, matching Claude Code/Codex.
    arr+=("$(jq -n --arg p "$(sub_home "$d")" --argjson n "${count:-0}" \
      '{source:"grok", path:$p, sessions:$n}')")
  fi

  if [[ -n "$CLAUDE_EXPORT" ]]; then
    cj="$CLAUDE_EXPORT"
    [[ -d "$cj" ]] && cj="$cj/conversations.json"
    if [[ -f "$cj" ]] && count="$(jq 'length' "$cj" 2>/dev/null)"; then
      arr+=("$(jq -n --arg p "$(sub_home "$cj")" --argjson n "$count" \
        '{source:"claude-ai", path:$p, sessions:$n}')")
    else
      echo "claude-export: no readable conversations.json at $(sub_home "$CLAUDE_EXPORT")" >> "$DISCOVERY_LOG"
    fi
  fi

  if [[ ${#arr[@]} -gt 0 ]]; then
    printf "%s\n" "${arr[@]}" | jq -s '.'
  else
    printf "[]"
  fi
}

# ──────────────────────── interruption ────────────────────────
# On TERM/INT: stop every descendant (find, awk, grep, process-substitution
# subshells), remove the temp dir (it holds file and session path lists), and
# exit 143 (TERM) or 130 (INT). Without this, a killed scan left orphaned
# children and its temp lists behind.
SCAN_TMPD=""
SCAN_PARTIAL=""
scan_descendants() { # <pid> -> descendant pids, one per line
  ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$1" '
    { par[$1] = $2; pids[++n] = $1 }
    END {
      d[root] = 1; changed = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= n; i++) { p = pids[i]; if (!(p in d) && (par[p] in d)) { d[p] = 1; changed = 1 } }
      }
      for (p in d) if (p != root) print p
    }'
}
# Helper temp file inside the scan's private dir. Always pass an explicit
# template: macOS mktemp ignores TMPDIR, so a bare "mktemp" would land in the
# per-user temp dir and survive a cancel.
scan_mktemp() { mktemp "$SCAN_TMPD/t/tmp.XXXXXX"; }
scan_cleanup() {
  if [[ -n "$SCAN_TMPD" ]]; then rm -rf "$SCAN_TMPD"; fi
  if [[ -n "$SCAN_PARTIAL" ]]; then rm -f "$SCAN_PARTIAL"; fi
  return 0
}
scan_abort() { # <exit code>
  trap - TERM INT
  # The trap can fire inside "while IFS= read", so do not rely on IFS.
  local p
  while read -r p; do
    [[ -n "$p" ]] && { kill -TERM "$p" 2>/dev/null || true; }
  done <<< "$(scan_descendants "$$")"
  [[ -n "$SCAN_TMPD" ]] && rm -rf "$SCAN_TMPD"
  [[ -n "$SCAN_PARTIAL" ]] && rm -f "$SCAN_PARTIAL"
  exit "$1"
}

# ──────────────────────── assemble report ────────────────────────
main() {
  local tmpd base="${TMPDIR:-/tmp}"
  base="${base%/}"
  # Explicit template: macOS mktemp ignores TMPDIR without one.
  tmpd="$(mktemp -d "$base/import-context.XXXXXX" 2>/dev/null || mktemp -d /tmp/import-context.XXXXXX)"
  SCAN_TMPD="$tmpd"
  # EXIT, not RETURN: bash runs a function's RETURN trap when a file sourced
  # inside that function finishes, which deleted the temp dir mid-scan.
  trap scan_cleanup EXIT
  trap 'scan_abort 143' TERM
  trap 'scan_abort 130' INT
  # Every helper temp file is created by scan_mktemp inside $tmpd/t, so an
  # interrupted scan cleans up all of them with one rm. TMPDIR points there
  # too, for tools such as sort that honor it.
  mkdir -p "$tmpd/t"
  export TMPDIR="$tmpd/t"

  # Authoritative discovery-error log — must exist BEFORE any find_capture call
  # so failures from subshell emitters (command substitutions) are recorded.
  DISCOVERY_LOG="$tmpd/discovery_errors.log"
  : > "$DISCOVERY_LOG"

  # Streaming progress (--progress-json). Runs its own read-only passes before
  # the report is built and never touches report state, so report.json stays
  # byte-identical with and without the flag.
  if $PROGRESS_JSON; then
    pj_begin "$tmpd/progress"
    pj_run_sources
  fi

  scan_trees

  local scan_id
  scan_id="$(date +%Y-%m-%dT%H-%M-%S)"

  # Build all category JSON, normalize empties to [], write to temp files
  # so `jq --slurpfile` can read them without blowing up the exec arg cap.
  if [[ ${#PARENTS[@]} -gt 0 ]]; then
    ensure_json_array "$(printf "%s\n" "${PARENTS[@]}" | jq -R . | jq -s '.')" > "$tmpd/scope.json"
  else
    printf "[]" > "$tmpd/scope.json"
  fi
  ensure_json_array "$(emit_plans)"                        > "$tmpd/plans.json"
  ensure_json_array "$(emit_claude_md)"                    > "$tmpd/claude_md.json"
  ensure_json_array "$(emit_claude_repos)"                 > "$tmpd/claude_repos.json"
  ensure_json_array "$(emit_conversation_stores)"          > "$tmpd/conversations.json"

  # Tree artifacts return an object, not an array — handle separately. Their
  # category payloads are file-backed so large scans never enter jq's argv.
  mkdir -p "$tmpd/tree-parts"
  emit_claude_tree_artifacts "$tmpd/tree.json" "$tmpd/tree-parts"
  if ! jq empty < "$tmpd/tree.json" 2>/dev/null; then
    printf '%s' '{"commands":[],"skills":[],"hooks":[],"policies":[],"agents":[],"settings":[]}' > "$tmpd/tree.json"
  fi

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

  # Discovery status — lets callers distinguish "found none" from "could not
  # look". Read from the subshell-safe DISCOVERY_LOG so failures from every
  # emitter (including those run in command substitutions) are counted. Never
  # let a failed scan masquerade as an empty one.
  local discovery_ok discovery_errors_json discovery_count
  discovery_count="$(grep -c '' "$DISCOVERY_LOG" 2>/dev/null || echo 0)"
  if [[ -s "$DISCOVERY_LOG" ]]; then
    discovery_ok=false
    discovery_errors_json="$(jq -R . < "$DISCOVERY_LOG" | jq -s '.')"
  else
    discovery_ok=true
    discovery_errors_json="[]"
  fi
  printf "%s" "$discovery_errors_json" > "$tmpd/discovery_errors.json"

  # Final report — composed via --slurpfile so argv stays tiny.
  jq -n \
    --arg scan_id "$scan_id" \
    --argjson discovery_ok "$discovery_ok" \
    --slurpfile scope        "$tmpd/scope.json" \
    --slurpfile derrs        "$tmpd/discovery_errors.json" \
    --slurpfile tree         "$tmpd/tree.json" \
    --slurpfile plans        "$tmpd/plans.json" \
    --slurpfile mcp          "$tmpd/mcp.json" \
    --slurpfile settings     "$tmpd/settings.json" \
    --slurpfile claude_md    "$tmpd/claude_md.json" \
    --slurpfile claude_repos "$tmpd/claude_repos.json" \
    --slurpfile conversations "$tmpd/conversations.json" \
    '{
      scan_id: $scan_id,
      scope: $scope[0],
      discovery: { ok: $discovery_ok, errors: $derrs[0] },
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
        claude_repos: $claude_repos[0],
        conversations: $conversations[0]
      }
    } | .counts = (.categories | map_values(length))' > "$tmpd/report.json"

  # Surface a loud, unmissable banner on stderr when discovery did not fully
  # complete — so a "0 found" report is never read as authoritative.
  if [[ "$discovery_ok" != "true" ]]; then
    {
      echo "scan.sh: ───────────────────────────────────────────────"
      echo "scan.sh: DISCOVERY INCOMPLETE — counts below may be UNDER-reported."
      echo "scan.sh: ${discovery_count} discovery error(s) occurred; see report .discovery.errors."
      echo "scan.sh: Treat any zero counts as 'could not look', NOT 'nothing to import'."
      echo "scan.sh: ───────────────────────────────────────────────"
    } >&2
  fi

  if [[ -n "$OUTPUT" ]]; then
    mkdir -p "$(dirname "$OUTPUT")"
    # Atomic publish: a reader never sees a half-written report.
    SCAN_PARTIAL="$(dirname "$OUTPUT")/.$(basename "$OUTPUT").tmp.$$"
    cp "$tmpd/report.json" "$SCAN_PARTIAL"
    mv -f "$SCAN_PARTIAL" "$OUTPUT"
    SCAN_PARTIAL=""
    if $PROGRESS_JSON; then
      pj_finish "$tmpd/report.json" "$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
    else
      echo "$OUTPUT"
    fi
  else
    cat "$tmpd/report.json"
  fi
}

# Source the progress emitters at top level, never inside a function (see the
# EXIT trap note in main).
if $PROGRESS_JSON; then
  # shellcheck source=.claude/skills/import-context/scan-progress.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scan-progress.sh"
fi

main
