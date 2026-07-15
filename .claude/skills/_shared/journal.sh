#!/bin/bash
# Session journal helper — open/append/close for the per-session thinking trail.
# Spec: core/knowledge/public/hq-core/journal-spec.md
#
# Usage:
#   journal.sh open <skill_name> <project_dir> [thread_id]
#     Creates journal file at <project_dir>/journal/<ts>-<skill>-<short>.md and
#     sets the caller's session-scoped active-journal pointer to its absolute
#     path. Prints the absolute path on stdout.
#
#   journal.sh append <project_dir> <section> <entry_text>
#     Appends one timestamped bullet to the active journal under the section header.
#     <section> ∈ {decisions, open, findings, rejected}
#     <entry_text> is wrapped: "- <ISO8601> <entry_text>"
#
#   journal.sh close <project_dir> <summary>
#     Sets status: closed in frontmatter, fills summary, clears the pointer.
#
#   journal.sh path
#     Prints the active journal path (or empty + exit 1 if none).
#
#   journal.sh attach <project_dir> <kind> [<source_path>] [--ext <ext>]
#     Persists reference material into the active journal's project tree.
#     <kind> ∈ {research, attachment}:
#       research    → {project_dir}/research/{ts}-research-{hash6}.{ext}
#                     cross-ref appended under '## Findings'
#       attachment  → {project_dir}/journal/attachments/{ts}-attachment-{hash6}.{ext}
#                     cross-ref appended under '## Auto-capture'
#     If <source_path> is omitted or '-', content is read from stdin.
#     If --ext is omitted, inferred from source extension (file) or 'txt' (stdin).
#     Caller project_dir must match the active journal's frontmatter. Prints
#     the absolute path of the written file.
#     Spec: core/knowledge/public/hq-core/journal-spec.md (## Reference material)
#
# All commands fail-soft: on any unexpected error, print a one-line warning to
# stderr and exit 0 — the journal must never block the calling skill.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)" || PROJECT_DIR="$(pwd -P)"
STATE_DIR="$PROJECT_DIR/.claude/state"
LEGACY_POINTER="$STATE_DIR/active-journal"
LOG_FILE="/tmp/hq-journal.log"

warn() {
  echo "journal: $*" >&2
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG_FILE" 2>/dev/null || true
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

normalize_project_dir() {
  local dir="${1:-}"
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  (cd "$dir" 2>/dev/null && pwd -P)
}

resolve_session_id() {
  local var value
  for var in HQ_JOURNAL_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID; do
    value="${!var:-}"
    case "$value" in
      ''|null) ;;
      *) printf '%s' "$value"; return 0 ;;
    esac
  done
  return 1
}

session_pointer_key() {
  local raw="$1" safe hash
  safe="$(printf '%s' "$raw" | tr -cs 'A-Za-z0-9._-' '_')"
  [ -n "$safe" ] || safe="session"
  if command -v shasum >/dev/null 2>&1; then
    hash="$(printf '%s' "$raw" | shasum -a 256 2>/dev/null | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$raw" | sha256sum 2>/dev/null | awk '{print $1}')"
  else
    hash="$(printf '%s' "$raw" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null)"
  fi
  [ -n "$hash" ] || { warn "session key hash failed"; return 1; }
  printf '%s-%s' "${safe:0:48}" "${hash:0:12}"
}

SESSION_ID="$(resolve_session_id 2>/dev/null || true)"
POINTER="$LEGACY_POINTER"
POINTER_IS_SCOPED=0
if [ -n "$SESSION_ID" ]; then
  SESSION_KEY="$(session_pointer_key "$SESSION_ID")" || { warn "session key resolution failed"; exit 0; }
  POINTER="$STATE_DIR/active-journal.d/$SESSION_KEY"
  POINTER_IS_SCOPED=1
fi

active_path() {
  [ -f "$POINTER" ] || return 1
  local p
  p=$(cat "$POINTER" 2>/dev/null | tr -d '\n')
  [ -z "$p" ] && return 1
  if [ ! -f "$p" ]; then
    [ "$POINTER_IS_SCOPED" -eq 1 ] && rm -f "$POINTER" 2>/dev/null || true
    return 1
  fi
  printf '%s' "$p"
}

journal_project_dir() {
  local journal="$1" project
  project=$(awk '/^project: / { sub(/^project: /, ""); print; exit }' "$journal" 2>/dev/null)
  normalize_project_dir "$project"
}

owned_journal() {
  local caller="$1" require_active="${2:-0}" journal journal_project status
  caller=$(normalize_project_dir "$caller") || { warn "project_dir required and must exist"; return 1; }
  journal=$(active_path) || { warn "no active journal"; return 1; }
  journal_project=$(journal_project_dir "$journal") || { warn "journal has no valid project frontmatter"; return 1; }
  if [ "$caller" != "$journal_project" ]; then
    warn "caller project does not own active journal"
    return 1
  fi
  if [ "$require_active" = "1" ]; then
    status=$(awk '/^status: / { sub(/^status: /, ""); print; exit }' "$journal" 2>/dev/null)
    if [ "$status" != "active" ]; then
      warn "journal is not active (status: ${status:-missing})"
      return 1
    fi
  fi
  printf '%s' "$journal"
}

cmd="${1:-}"
shift || true

case "$cmd" in
  open)
    skill="${1:-unknown}"
    proj="${2:-}"
    thread_id="${3:-}"
    [ -z "$proj" ] && { warn "open: project_dir required"; exit 0; }

    # Resolve thread short
    if [ -z "$thread_id" ]; then
      handoff="$PROJECT_DIR/workspace/threads/handoff.json"
      if [ -f "$handoff" ]; then
        thread_id=$(python3 -c "import json,sys; print(json.load(open('$handoff')).get('thread_id',''))" 2>/dev/null || echo "")
      fi
    fi
    if [ -n "$thread_id" ] && [ "$thread_id" != "null" ]; then
      thread_short="${thread_id: -6}"
    else
      thread_id="adhoc"
      thread_short="adhoc"
    fi

    ts_file=$(date -u +%Y-%m-%d-%H%M)
    journal_dir="$proj/journal"
    mkdir -p "$journal_dir" 2>/dev/null || { warn "open: mkdir failed: $journal_dir"; exit 0; }
    proj=$(normalize_project_dir "$proj") || { warn "open: invalid project_dir: $proj"; exit 0; }
    journal_dir="$proj/journal"
    journal_path="$journal_dir/${ts_file}-${skill}-${thread_short}.md"

    # If file already exists for this triple, reuse (rare — same skill re-invoked same minute)
    if [ ! -f "$journal_path" ]; then
      cat > "$journal_path" <<EOF
---
skill: $skill
started_at: $(now_iso)
thread_id: $thread_id
project: $proj
status: active
auto_capture: true
summary: ""
---

## Decisions
## Open threads
## Findings
## Rejected
## Auto-capture
EOF
    fi

    # Set pointer (absolute path)
    abs_path=$(cd "$(dirname "$journal_path")" && pwd)/$(basename "$journal_path")
    mkdir -p "$(dirname "$POINTER")" 2>/dev/null || true
    printf '%s' "$abs_path" > "$POINTER" 2>/dev/null || warn "open: pointer write failed"

    printf '%s\n' "$abs_path"
    ;;

  append)
    caller_project="${1:-}"
    section="${2:-}"
    entry="${3:-}"
    [ -z "$caller_project" ] || [ -z "$section" ] || [ -z "$entry" ] && { warn "append: project_dir, section and entry required"; exit 0; }

    journal=$(owned_journal "$caller_project" 1) || { warn "append: no owned active journal"; exit 0; }

    case "$section" in
      decisions) header='## Decisions' ;;
      open)      header='## Open threads' ;;
      findings)  header='## Findings' ;;
      rejected)  header='## Rejected' ;;
      *) warn "append: invalid section '$section' (use decisions|open|findings|rejected)"; exit 0 ;;
    esac

    line="- $(now_iso) $entry"

    # Insert <line> on the line AFTER <header>. If header isn't found, append at EOF
    # under a new section. awk is portable across BSD/GNU.
    if grep -qF "$header" "$journal" 2>/dev/null; then
      awk -v h="$header" -v l="$line" '
        BEGIN { inserted = 0 }
        { print }
        $0 == h && !inserted { print l; inserted = 1 }
      ' "$journal" > "$journal.tmp" && mv "$journal.tmp" "$journal" || warn "append: rewrite failed"
    else
      {
        printf '\n%s\n' "$header"
        printf '%s\n' "$line"
      } >> "$journal" 2>/dev/null || warn "append: header-add failed"
    fi
    ;;

  close)
    caller_project="${1:-}"
    summary="${2:-}"
    [ -z "$caller_project" ] && { warn "close: project_dir required"; exit 0; }
    journal=$(owned_journal "$caller_project") || { warn "close: no owned active journal"; exit 0; }

    # Update frontmatter: status: active -> closed, summary: "" -> "<summary>"
    # Use python to preserve YAML structure safely.
    python3 - "$journal" "$summary" <<'PYEOF' || warn "close: frontmatter update failed"
import sys, re, pathlib
path = pathlib.Path(sys.argv[1])
summary = sys.argv[2]
text = path.read_text()
m = re.match(r'^---\n([\s\S]*?)\n---\n([\s\S]*)$', text)
if not m:
    sys.exit(0)
fm, body = m.group(1), m.group(2)
fm = re.sub(r'^status: active$', 'status: closed', fm, flags=re.MULTILINE)
# Replace empty summary OR keep existing if non-empty
if summary:
    if re.search(r'^summary: ""$', fm, flags=re.MULTILINE):
        fm = re.sub(r'^summary: ""$', f'summary: "{summary}"', fm, flags=re.MULTILINE)
    elif re.search(r'^summary: ', fm, flags=re.MULTILINE):
        # Already has a summary — only overwrite if it was the placeholder
        pass
path.write_text(f'---\n{fm}\n---\n{body}')
PYEOF

    # Clear pointer only if it still points at this file
    if [ -f "$POINTER" ]; then
      cur=$(cat "$POINTER" 2>/dev/null | tr -d '\n')
      if [ "$cur" = "$journal" ]; then
        rm -f "$POINTER" 2>/dev/null || true
      fi
    fi
    ;;

  path)
    p=$(active_path) || exit 1
    printf '%s\n' "$p"
    ;;

  attach)
    caller_project="${1:-}"
    kind="${2:-}"
    shift 2 || true
    src=""
    # Only consume $1 as src if it's not a flag (e.g. --ext)
    if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then
      src="$1"
      shift
    fi
    ext=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --ext) ext="${2:-}"; shift 2 || break ;;
        *) shift ;;
      esac
    done

    [ -z "$caller_project" ] || [ -z "$kind" ] && { warn "attach: project_dir and kind required (research|attachment)"; exit 0; }
    case "$kind" in
      research|attachment) ;;
      *) warn "attach: invalid kind '$kind' (use research|attachment)"; exit 0 ;;
    esac

    journal=$(owned_journal "$caller_project" 1) || { warn "attach: no owned active journal"; exit 0; }

    # Extract project path from frontmatter (line: 'project: <path>')
    proj=$(journal_project_dir "$journal") || { warn "attach: no valid 'project:' field in journal frontmatter"; exit 0; }

    if [ "$kind" = "research" ]; then
      target_dir="$proj/research"
      section_header="## Findings"
    else
      target_dir="$proj/journal/attachments"
      section_header="## Auto-capture"
    fi
    mkdir -p "$target_dir" 2>/dev/null || { warn "attach: mkdir failed: $target_dir"; exit 0; }

    ts_file=$(date -u +%Y-%m-%d-%H%M%S)

    # Stage content: file copy OR stdin to temp
    tmp=""
    if [ -n "$src" ] && [ "$src" != "-" ]; then
      [ -f "$src" ] || { warn "attach: source not found: $src"; exit 0; }
      [ -z "$ext" ] && { base=$(basename "$src"); case "$base" in *.*) ext="${base##*.}" ;; *) ext="bin" ;; esac; }
      hash=$(shasum -a 256 "$src" 2>/dev/null | cut -c1-6)
    else
      tmp=$(mktemp 2>/dev/null) || { warn "attach: mktemp failed"; exit 0; }
      cat > "$tmp"
      [ -s "$tmp" ] || { rm -f "$tmp"; warn "attach: empty stdin, nothing written"; exit 0; }
      [ -z "$ext" ] && ext="txt"
      hash=$(shasum -a 256 "$tmp" 2>/dev/null | cut -c1-6)
    fi
    [ -z "$hash" ] && hash="aaaaaa"

    out="$target_dir/${ts_file}-${kind}-${hash}.${ext}"

    if [ -n "$tmp" ]; then
      mv "$tmp" "$out" 2>/dev/null || { warn "attach: move failed: $out"; rm -f "$tmp"; exit 0; }
    else
      cp "$src" "$out" 2>/dev/null || { warn "attach: copy failed: $out"; exit 0; }
    fi

    # Project-relative path for the cross-reference bullet
    relpath="${out#$proj/}"
    line="- $(now_iso) attached: $relpath"

    if grep -qF "$section_header" "$journal" 2>/dev/null; then
      awk -v h="$section_header" -v l="$line" '
        BEGIN { inserted = 0 }
        { print }
        $0 == h && !inserted { print l; inserted = 1 }
      ' "$journal" > "$journal.tmp" && mv "$journal.tmp" "$journal" || warn "attach: cross-ref rewrite failed"
    else
      {
        printf '\n%s\n' "$section_header"
        printf '%s\n' "$line"
      } >> "$journal" 2>/dev/null || warn "attach: section-add failed"
    fi

    printf '%s\n' "$out"
    ;;

  *)
    cat >&2 <<USAGE
journal.sh: usage:
  journal.sh open <skill_name> <project_dir> [thread_id]
  journal.sh append <project_dir> <decisions|open|findings|rejected> <entry_text>
  journal.sh close <project_dir> <summary>
  journal.sh path
  journal.sh attach <project_dir> <research|attachment> [<source_path>|-] [--ext <ext>]
USAGE
    exit 1
    ;;
esac
