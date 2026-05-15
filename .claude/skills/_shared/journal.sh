#!/bin/bash
# Session journal helper — open/append/close for the per-session thinking trail.
# Spec: core/knowledge/public/hq-core/journal-spec.md
#
# Usage:
#   journal.sh open <skill_name> <project_dir> [thread_id]
#     Creates journal file at <project_dir>/journal/<ts>-<skill>-<short>.md and
#     sets .claude/state/active-journal to its absolute path. Prints the absolute
#     path on stdout.
#
#   journal.sh append <section> <entry_text>
#     Appends one timestamped bullet to the active journal under the section header.
#     <section> ∈ {decisions, open, findings, rejected}
#     <entry_text> is wrapped: "- <ISO8601> <entry_text>"
#
#   journal.sh close <summary>
#     Sets status: closed in frontmatter, fills summary, clears the pointer.
#
#   journal.sh path
#     Prints the active journal path (or empty + exit 1 if none).
#
#   journal.sh attach <kind> [<source_path>] [--ext <ext>]
#     Persists reference material into the active journal's project tree.
#     <kind> ∈ {research, attachment}:
#       research    → {project_dir}/research/{ts}-research-{hash6}.{ext}
#                     cross-ref appended under '## Findings'
#       attachment  → {project_dir}/journal/attachments/{ts}-attachment-{hash6}.{ext}
#                     cross-ref appended under '## Auto-capture'
#     If <source_path> is omitted or '-', content is read from stdin.
#     If --ext is omitted, inferred from source extension (file) or 'txt' (stdin).
#     Project dir is read from the active journal's frontmatter — caller does
#     not need to know it. Prints the absolute path of the written file.
#     Spec: core/knowledge/public/hq-core/journal-spec.md (## Reference material)
#
# All commands fail-soft: on any unexpected error, print a one-line warning to
# stderr and exit 0 — the journal must never block the calling skill.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
POINTER="$PROJECT_DIR/.claude/state/active-journal"
LOG_FILE="/tmp/hq-journal.log"

warn() {
  echo "journal: $*" >&2
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG_FILE" 2>/dev/null || true
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

active_path() {
  [ -f "$POINTER" ] || return 1
  local p
  p=$(cat "$POINTER" 2>/dev/null | tr -d '\n')
  [ -z "$p" ] && return 1
  [ -f "$p" ] || return 1
  printf '%s' "$p"
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
    mkdir -p "$PROJECT_DIR/.claude/state" 2>/dev/null || true
    printf '%s' "$abs_path" > "$POINTER" 2>/dev/null || warn "open: pointer write failed"

    printf '%s\n' "$abs_path"
    ;;

  append)
    section="${1:-}"
    entry="${2:-}"
    [ -z "$section" ] || [ -z "$entry" ] && { warn "append: section and entry required"; exit 0; }

    journal=$(active_path) || { warn "append: no active journal"; exit 0; }

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
    summary="${1:-}"
    journal=$(active_path) || { warn "close: no active journal"; exit 0; }

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
    kind="${1:-}"
    shift || true
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

    [ -z "$kind" ] && { warn "attach: kind required (research|attachment)"; exit 0; }
    case "$kind" in
      research|attachment) ;;
      *) warn "attach: invalid kind '$kind' (use research|attachment)"; exit 0 ;;
    esac

    journal=$(active_path) || { warn "attach: no active journal"; exit 0; }

    # Extract project path from frontmatter (line: 'project: <path>')
    proj=$(awk '/^project: / { sub(/^project: /, ""); print; exit }' "$journal" 2>/dev/null)
    [ -z "$proj" ] && { warn "attach: no 'project:' field in journal frontmatter"; exit 0; }
    [ -d "$proj" ] || { warn "attach: project dir does not exist: $proj"; exit 0; }

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
  journal.sh append <decisions|open|findings|rejected> <entry_text>
  journal.sh close <summary>
  journal.sh path
  journal.sh attach <research|attachment> [<source_path>|-] [--ext <ext>]
USAGE
    exit 1
    ;;
esac
