#!/bin/bash
# Journal auto-capture hook — appends a one-line digest of meta-thinking tool calls
# (Agent, AskUserQuestion, WebFetch, WebSearch) to the active session journal's
# `## Auto-capture` section.
#
# Spec: knowledge/public/hq-core/journal-spec.md
#
# Activation:
#   Reads `.claude/state/active-journal` (single-line absolute path) to find target.
#   If pointer is missing, file is missing, file is stale (>2h since mtime), or
#   the journal's frontmatter has `auto_capture: false`, the hook exits silently.
#
# Skipped tools (noisy or secret-risky):
#   Bash, Read, Edit, Write, Grep, Glob, NotebookEdit, TodoWrite, anything else
#   not in the allowlist below.
#
# Non-blocking: failures are logged to /tmp/hq-journal-autocapture.log but never
# propagate. Hook always exits 0.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
POINTER="$PROJECT_DIR/.claude/state/active-journal"
LOG_FILE="/tmp/hq-journal-autocapture.log"
STALE_SECONDS=7200  # 2 hours
OVERFLOW_BYTES=1024  # spill raw tool output to journal/attachments/ when above this

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] journal-autocapture: $*" >> "$LOG_FILE" 2>/dev/null || true
}

trap 'exit 0' EXIT

# 1. Pointer check
[ -f "$POINTER" ] || exit 0
JOURNAL=$(cat "$POINTER" 2>/dev/null | tr -d '\n')
[ -z "$JOURNAL" ] && exit 0
[ -f "$JOURNAL" ] || { log "pointer references missing file: $JOURNAL"; exit 0; }

# 2. Stale check
NOW=$(date +%s)
MTIME=$(stat -f %m "$JOURNAL" 2>/dev/null || stat -c %Y "$JOURNAL" 2>/dev/null || echo 0)
if [ "$MTIME" -gt 0 ] && [ $((NOW - MTIME)) -gt $STALE_SECONDS ]; then
  log "journal stale (mtime $((NOW - MTIME))s ago): $JOURNAL — skipping"
  exit 0
fi

# 3. auto_capture frontmatter check
if ! head -20 "$JOURNAL" 2>/dev/null | grep -q '^auto_capture: true'; then
  exit 0
fi

# 4. Status check — only append to active journals
if head -20 "$JOURNAL" 2>/dev/null | grep -qE '^status: (closed|abandoned)'; then
  exit 0
fi

# 5. Read tool JSON from stdin
INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('tool_name', ''))
except Exception:
    print('')
" 2>/dev/null)

case "$TOOL_NAME" in
  Agent|AskUserQuestion|WebFetch|WebSearch) ;;
  *) exit 0 ;;
esac

# 6. Build digest line (with overflow spill into journal/attachments/)
# Project dir = parent of the journal dir (journal lives at {proj}/journal/*.md)
JOURNAL_DIR=$(dirname "$JOURNAL")
PROJ_ROOT=$(dirname "$JOURNAL_DIR")
export JOURNAL_PROJECT="$PROJ_ROOT"
export JOURNAL_OVERFLOW_BYTES="$OVERFLOW_BYTES"

ENTRY=$(echo "$INPUT" | python3 -c "
import sys, json, datetime, os, hashlib, pathlib

OVERFLOW = int(os.environ.get('JOURNAL_OVERFLOW_BYTES', '1024'))
PROJ = os.environ.get('JOURNAL_PROJECT', '')

def truncate(s, n=200):
    s = ' '.join(str(s or '').split())
    return s if len(s) <= n else s[:n].rstrip() + '...'

def safe_get(obj, *keys, default=''):
    cur = obj
    for k in keys:
        if isinstance(cur, dict) and k in cur:
            cur = cur[k]
        else:
            return default
    return cur or default

def spill(tool, raw):
    '''Write raw content to {proj}/journal/attachments/ if oversized.
    Returns project-relative path or '' when no spill happened.'''
    if not PROJ or not raw:
        return ''
    try:
        body = raw if isinstance(raw, str) else json.dumps(raw, default=str)
    except Exception:
        return ''
    if len(body.encode('utf-8')) <= OVERFLOW:
        return ''
    try:
        ts = datetime.datetime.utcnow().strftime('%Y-%m-%d-%H%M%S')
        h = hashlib.sha256(body.encode('utf-8')).hexdigest()[:6]
        att_dir = pathlib.Path(PROJ) / 'journal' / 'attachments'
        att_dir.mkdir(parents=True, exist_ok=True)
        att_path = att_dir / f'{ts}-{tool.lower()}-{h}.txt'
        att_path.write_text(body)
        return f'journal/attachments/{att_path.name}'
    except Exception as e:
        sys.stderr.write(f'spill-error: {e}\n')
        return ''

def with_spill(line, tool, raw):
    rel = spill(tool, raw)
    return f'{line} (full: {rel})' if rel else line

try:
    data = json.load(sys.stdin)
    tool = data.get('tool_name', '')
    inp = data.get('tool_input', {}) or {}
    resp = data.get('tool_response', {}) or data.get('tool_output', {}) or {}
    ts = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')

    if tool == 'Agent':
        desc = safe_get(inp, 'description') or safe_get(inp, 'subagent_type') or 'agent'
        if isinstance(resp, str):
            result_text = resp
        elif isinstance(resp, dict):
            result_text = resp.get('content') or resp.get('result') or json.dumps(resp)[:500]
        elif isinstance(resp, list):
            result_text = ' '.join(str(x) for x in resp)
        else:
            result_text = ''
        line = f'- {ts} [Agent] {truncate(desc, 80)}: {truncate(result_text, 200)}'
        print(with_spill(line, 'agent', result_text))

    elif tool == 'AskUserQuestion':
        questions = inp.get('questions', []) or []
        first_q = questions[0] if questions else {}
        header = safe_get(first_q, 'header') or safe_get(first_q, 'question') or 'question'
        answer = ''
        if isinstance(resp, list) and resp:
            answer = safe_get(resp[0], 'answer') or safe_get(resp[0], 'label') or str(resp[0])[:100]
        elif isinstance(resp, dict):
            answers = resp.get('answers') or resp.get('responses') or []
            if isinstance(answers, list) and answers:
                a0 = answers[0]
                if isinstance(a0, dict):
                    answer = a0.get('answer') or a0.get('label') or ''
                else:
                    answer = str(a0)
            else:
                answer = resp.get('answer') or ''
        # Q&A answers are short — no spill
        print(f'- {ts} [AskUserQuestion] {truncate(header, 80)} -> {truncate(answer, 120)}')

    elif tool == 'WebFetch':
        url = safe_get(inp, 'url')
        prompt = safe_get(inp, 'prompt')
        if isinstance(resp, str):
            content = resp
        elif isinstance(resp, dict):
            content = resp.get('content') or resp.get('result') or ''
        else:
            content = ''
        line = f'- {ts} [WebFetch] {truncate(url, 100)} ({truncate(prompt, 60)}): {truncate(content, 150)}'
        print(with_spill(line, 'webfetch', content))

    elif tool == 'WebSearch':
        query = safe_get(inp, 'query')
        title = ''
        full_results = ''
        if isinstance(resp, dict):
            results = resp.get('results') or []
            if isinstance(results, list) and results:
                title = safe_get(results[0], 'title') or safe_get(results[0], 'url') or ''
                try:
                    full_results = json.dumps(results, default=str)
                except Exception:
                    full_results = ''
        elif isinstance(resp, list) and resp:
            title = safe_get(resp[0], 'title') or str(resp[0])[:100]
            try:
                full_results = json.dumps(resp, default=str)
            except Exception:
                full_results = ''
        line = f'- {ts} [WebSearch] \"{truncate(query, 100)}\" -> {truncate(title, 120)}'
        print(with_spill(line, 'websearch', full_results))

except Exception as e:
    sys.stderr.write(f'parse-error: {e}\n')
    sys.exit(0)
" 2>>"$LOG_FILE")

[ -z "$ENTRY" ] && exit 0

# 7. Append under `## Auto-capture`
if grep -q '^## Auto-capture' "$JOURNAL" 2>/dev/null; then
  printf '%s\n' "$ENTRY" >> "$JOURNAL" 2>>"$LOG_FILE" || log "append failed: $JOURNAL"
else
  {
    printf '\n## Auto-capture\n'
    printf '%s\n' "$ENTRY"
  } >> "$JOURNAL" 2>>"$LOG_FILE" || log "append-with-header failed: $JOURNAL"
fi

exit 0
