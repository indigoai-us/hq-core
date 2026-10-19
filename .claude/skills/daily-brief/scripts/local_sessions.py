"""Session history from the HQ workspace folder on this Mac.

Python port of the HQ desktop app's local session scanner. Same sources,
same rules:

- `workspace/sessions/<id>/meta.yaml`: session_id, started_at, company_slug,
  project, task, title, company_source (`parent` marks a dispatched lane).
- `workspace/threads/T-<date>-*.json` checkpoint/handoff records, read only
  for file-name dates inside the window (plus one day): their
  `metadata.title` wins over meta.yaml, their timestamps set last activity.
- Claude Code transcripts `~/.claude/projects/<dir>/<id>.jsonl`: only the
  `custom-title` / `agent-name` records, the `cwd` field, the file mtime, and
  the first user prompt (head only) as a one-line, 80-character fallback title.
  `"entrypoint":"sdk-cli"` marks a headless agent.
- Codex: `~/.codex/session_index.jsonl` thread names and
  `~/.codex/sessions/YYYY/MM/DD/rollout-*-<id>.jsonl` (cwd, mtime, first prompt).

kind: "you" (interactive), "agent" (headless background run) or "lane"
(a worker a parent session dispatched).

Run with `python3 -I`. Reads no secrets; prints nothing.
"""
import datetime as dt
import json
import os

KIND_YOU, KIND_AGENT, KIND_LANE = 'you', 'agent', 'lane'
PROMPT_SUMMARY_CHARS = 80
TRANSCRIPT_HEAD = 256 * 1024
TRANSCRIPT_TAIL = 512 * 1024
TRANSCRIPT_SCAN_CAP = 32 * 1024 * 1024


# ---------- small helpers ----------
def meta_fields(text):
    """Top-level `key: value` pairs of a small YAML file, quotes stripped."""
    out = {}
    for line in text.splitlines():
        if line.startswith((' ', '\t', '#')) or ':' not in line:
            continue
        key, value = line.split(':', 1)
        key = key.strip()
        if not key or not all((c.isascii() and c.isalnum()) or c in '_-' for c in key):
            continue
        value = value.strip().strip('"').strip("'").strip()
        if value and value not in ('null', '~'):
            out[key] = value
    return out


def _day(ts):
    return ts[:10]


def name_day(name):
    """Date in a thread file name: `T-2026-09-01-...` or `T-20261001-...`."""
    if not name.startswith('T-'):
        return None
    rest = name[2:]
    dashed = rest[:10]
    if len(dashed) == 10 and dashed[4] == '-' and dashed[7] == '-':
        return dashed
    compact = rest[:8]
    if len(compact) == 8 and compact.isdigit():
        return f'{compact[:4]}-{compact[4:6]}-{compact[6:8]}'
    return None


def shift_day(day, delta):
    try:
        return (dt.date.fromisoformat(day) + dt.timedelta(days=delta)).isoformat()
    except ValueError:
        return day


def parse_iso(ts):
    try:
        t = dt.datetime.fromisoformat(ts.replace('Z', '+00:00'))
    except (ValueError, AttributeError):
        return None
    if t.tzinfo is None:
        t = t.replace(tzinfo=dt.timezone.utc)
    return t.astimezone(dt.timezone.utc)


def iso_z(t):
    return t.astimezone(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def _mtime_iso(path):
    try:
        return iso_z(dt.datetime.fromtimestamp(os.stat(path).st_mtime, dt.timezone.utc))
    except OSError:
        return None


def _loads(line):
    try:
        return json.loads(line)
    except ValueError:
        return None


def read_head(path, n):
    try:
        with open(path, 'rb') as f:
            return f.read(n).decode('utf-8', errors='replace')
    except OSError:
        return ''


# ---------- prompt text ----------
def _tag_name(rest):
    out = []
    for c in rest:
        if (c.isascii() and c.isalnum()) or c in '-_':
            out.append(c)
        else:
            break
    return ''.join(out)


def human_text(text):
    """Prompt text with injected `<tag>…</tag>` blocks, the Codex AGENTS.md
    header, policy digest lines and the local-command caveat removed."""
    out, close = [], None
    for line in text.splitlines():
        t = line.strip()
        if close is not None:
            if close in t:
                close = None
            continue
        if t.startswith('<'):
            name = _tag_name(t[1:])
            if name:
                end = f'</{name}>'
                i = t.find(end)
                if i >= 0:
                    tail = t[i + len(end):].strip()
                    if tail:
                        out.append(tail)
                elif t.endswith('/>') or end not in text:
                    pass
                else:
                    close = end
                continue
        if t.startswith('# AGENTS.md instructions') or t.startswith('> Policy ') or t.startswith('Caveat: The messages below were generated'):
            continue
        out.append(line)
    return '\n'.join(out)


def lane_name(text):
    """Lane from a dispatcher brief path `…/workflow-runner/<run>/<lane>/brief.md`."""
    at = text.find('workflow-runner/')
    if at < 0:
        return None
    parts = text[at:].split('/')[:4]
    if len(parts) == 4 and parts[3].startswith('brief') and parts[2]:
        return parts[2]
    return None


def cap_line(line):
    collapsed = ' '.join(line.split())
    if len(collapsed) <= PROMPT_SUMMARY_CHARS:
        return collapsed
    return collapsed[:PROMPT_SUMMARY_CHARS - 1].rstrip() + '…'


def prompt_summary(text):
    """First meaningful text line of a prompt, whitespace collapsed and capped."""
    for line in human_text(text).splitlines():
        line = line.strip()
        if line and not line.startswith('<') and not line.startswith('```') and line != '---':
            return cap_line(line)
    return None


def classify_prompt(text):
    """(title, kind) for a never-named session from its first prompt."""
    human = human_text(text)
    lane = lane_name(human)
    if lane:
        return cap_line(lane), KIND_LANE
    lead = human.lstrip()
    if lead.startswith('EXECUTE NOW'):
        return prompt_summary('\n'.join(lead.splitlines()[1:])), KIND_LANE
    for opener in ('You are the HQ ', 'You are an HQ ', 'You are a HQ '):
        if lead.startswith(opener):
            flat = ' '.join(lead[len(opener):].split())
            sentence = flat.split('. ')[0].rstrip('.')
            return cap_line(f'HQ {sentence}'), KIND_AGENT
    return prompt_summary(human), None


def claude_first_prompt(text):
    """(title, kind) from the first user prompt in a Claude Code transcript head."""
    headless = '"entrypoint":"sdk-cli"' in text
    for line in text.splitlines():
        if '"type":"user"' not in line:
            continue
        value = _loads(line)
        if not isinstance(value, dict) or value.get('isMeta') is True:
            continue
        content = (value.get('message') or {}).get('content') if isinstance(value.get('message'), dict) else None
        if isinstance(content, str):
            parts = [content]
        elif isinstance(content, list):
            parts = [p.get('text') for p in content
                     if isinstance(p, dict) and p.get('type') == 'text' and isinstance(p.get('text'), str)]
        else:
            parts = []
        title, kind = classify_prompt('\n'.join(parts))
        if title is not None:
            return title, kind or (KIND_AGENT if headless else None)
    return None, (KIND_AGENT if headless else None)


def codex_first_prompt(text):
    """(title, kind) from the first user prompt in a Codex rollout head."""
    lines = text.splitlines()
    first = _loads(lines[0]) if lines else None
    payload = first.get('payload') if isinstance(first, dict) else None
    headless = isinstance(payload, dict) and (payload.get('source') == 'exec' or payload.get('originator') == 'codex_exec')
    for line in lines:
        if '"role":"user"' not in line:
            continue
        value = _loads(line)
        parts = ((value or {}).get('payload') or {}).get('content') if isinstance(value, dict) else None
        if not isinstance(parts, list):
            continue
        for part in parts:
            t = part.get('text') if isinstance(part, dict) else None
            if not isinstance(t, str):
                continue
            title, kind = classify_prompt(t)
            if title is not None:
                return title, kind or (KIND_AGENT if headless else None)
    return None, (KIND_AGENT if headless else None)


# ---------- transcripts ----------
def scan_transcript_lines(text, out):
    """Title and cwd from transcript lines, latest record wins. Only metadata
    records are parsed; message text never reaches the result."""
    for line in text.splitlines():
        if '"type":"custom-title"' in line or '"type":"agent-name"' in line:
            value = _loads(line)
            if isinstance(value, dict):
                t = value.get('customTitle')
                if t is None:
                    t = value.get('agentName')
                if isinstance(t, str) and t.strip():
                    out['title'] = t.strip()
            continue
        idx = line.find('"cwd":"')
        if idx >= 0:
            rest = line[idx + 7:]
            end = rest.find('"')
            if end > 0:
                out['cwd'] = rest[:end].replace('\\\\', '\\')


def summarize_transcript(path):
    try:
        size = os.stat(path).st_size
    except OSError:
        return None
    s = {'title': None, 'first_prompt': None, 'kind': None, 'cwd': None, 'last_at': _mtime_iso(path)}
    start = max(0, size - TRANSCRIPT_TAIL)
    with open(path, 'rb') as f:
        f.seek(start)
        scan_transcript_lines(f.read(TRANSCRIPT_TAIL).decode('utf-8', errors='replace'), s)
        if s['title'] is None and start > 0:
            # Title records can sit only near the start of a long transcript.
            f.seek(0)
            early = {'title': None, 'cwd': None}
            scan_transcript_lines(f.read(min(start, TRANSCRIPT_SCAN_CAP)).decode('utf-8', errors='replace'), early)
            s['title'] = early['title']
            if s['cwd'] is None:
                s['cwd'] = early['cwd']
    first_prompt, kind = claude_first_prompt(read_head(path, TRANSCRIPT_HEAD))
    s['kind'] = kind
    if s['title'] is None:
        s['first_prompt'] = first_prompt
    return s


def summarize_codex_rollout(path):
    head = read_head(path, TRANSCRIPT_HEAD)
    lines = head.splitlines()
    first = _loads(lines[0]) if lines else None
    payload = first.get('payload') if isinstance(first, dict) else None
    cwd = payload.get('cwd') if isinstance(payload, dict) and isinstance(payload.get('cwd'), str) else None
    first_prompt, kind = codex_first_prompt(head)
    return {'title': None, 'first_prompt': first_prompt, 'kind': kind, 'cwd': cwd, 'last_at': _mtime_iso(path)}


def transcript_paths(root, wanted):
    out = {}
    try:
        dirs = [os.path.join(root, d) for d in os.listdir(root)]
    except OSError:
        return out
    for d in dirs:
        for sid in wanted:
            if sid in out:
                continue
            p = os.path.join(d, sid + '.jsonl')
            if os.path.isfile(p):
                out[sid] = p
    return out


def codex_thread_names(codex, wanted):
    out = {}
    try:
        f = open(os.path.join(codex, 'session_index.jsonl'), encoding='utf-8', errors='replace')
    except OSError:
        return out
    with f:
        for line in f:
            v = _loads(line)
            if not isinstance(v, dict):
                continue
            sid, name = v.get('id'), v.get('thread_name')
            if isinstance(sid, str) and isinstance(name, str) and sid in wanted and name.strip():
                out[sid] = name.strip()
    return out


def codex_rollouts(codex, rows):
    out, by_dir = {}, {}
    for r in rows:
        for delta in (-1, 0, 1):
            y, m, d = (shift_day(_day(r['started_at']), delta).split('-') + ['', '', ''])[:3]
            if not (y and m and d):
                continue
            by_dir.setdefault(os.path.join(codex, 'sessions', y, m, d), []).append(r['id'])
    for d, ids in by_dir.items():
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for name in names:
            if not name.startswith('rollout-') or not name.endswith('.jsonl'):
                continue
            for sid in ids:
                if name.endswith(f'-{sid}.jsonl'):
                    out.setdefault(sid, os.path.join(d, name))
                    break
    return out


def repo_from_cwd(cwd):
    parts = [p for p in cwd.replace('\\', '/').split('/') if p]
    if 'repos' not in parts:
        return None
    i = parts.index('repos')
    if i + 1 >= len(parts):
        return None
    nxt = parts[i + 1]
    if nxt in ('public', 'private'):
        return parts[i + 2] if i + 2 < len(parts) else None
    return nxt


def product_from_title(title):
    parts = [p.strip() for p in title.split(' · ')]
    return parts[1] if len(parts) >= 3 and parts[1] else None


def enrich_from_transcript(row, s):
    if row['title'] is None:
        row['title'] = s.get('title')
    named = row['title'] is not None
    if row['project'] is None:
        row['project'] = (repo_from_cwd(s['cwd']) if s.get('cwd') else None) or (product_from_title(row['title']) if row['title'] else None)
    if not named:
        row['title'] = s.get('first_prompt')
    kind = s.get('kind')
    if kind and not (row['kind'] == KIND_LANE and kind == KIND_AGENT):
        row['kind'] = kind
    t = s.get('last_at')
    if t and (row['last_activity'] is None or t > row['last_activity']):
        row['last_activity'] = t
    if s.get('cwd'):
        row['cwd'] = s['cwd']


# ---------- thread records ----------
def summarize_thread(path):
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            obj = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(obj, dict):
        return None
    md = obj.get('metadata') if isinstance(obj.get('metadata'), dict) else {}
    sid = obj['session_id'] if 'session_id' in obj else md.get('session_id')
    if not isinstance(sid, str):
        return None
    kind = obj['type'] if 'type' in obj else md.get('kind', 'checkpoint')
    kind = kind if isinstance(kind, str) else 'checkpoint'
    at = obj['updated_at'] if 'updated_at' in obj else obj.get('created_at')
    title = md.get('title')
    title = title.strip() if isinstance(title, str) and title.strip() else None
    return {'session_id': sid, 'kind': kind, 'at': at if isinstance(at, str) else '', 'title': title}


# ---------- scan ----------
def scan(hq_root, start_iso, end_iso, claude_root=None, codex_root=None):
    """Sessions whose started_at falls in [start_iso, end_iso], newest first,
    enriched from thread records and agent-runtime transcripts."""
    home = os.path.expanduser('~')
    claude_root = claude_root if claude_root is not None else os.path.join(home, '.claude', 'projects')
    codex_root = codex_root if codex_root is not None else os.path.join(home, '.codex')
    lo, hi = parse_iso(start_iso), parse_iso(end_iso)
    rows = []
    sdir = os.path.join(hq_root, 'workspace', 'sessions')
    try:
        entries = os.listdir(sdir)
    except OSError:
        entries = []
    for name in entries:
        try:
            with open(os.path.join(sdir, name, 'meta.yaml'), encoding='utf-8', errors='replace') as f:
                fields = meta_fields(f.read())
        except OSError:
            continue
        started = parse_iso(fields.get('started_at', ''))
        if started is None or started < lo or started > hi:
            continue
        rows.append({
            'id': fields.get('session_id', name),
            'started_at': iso_z(started),
            'last_activity': None,
            'company': fields.get('company_slug'),
            'project': fields.get('project'),
            'title': fields.get('title') or fields.get('task'),
            # `company_source: parent` is written when a parent session
            # spawned this one with its company (HQ_SPAWN_COMPANY).
            'kind': KIND_LANE if fields.get('company_source') == 'parent' else KIND_YOU,
            'cwd': None,
        })

    # Thread records, read only inside the window (plus one day each side).
    wanted = {r['id'] for r in rows}
    by_session = {}
    if wanted:
        low, high = shift_day(iso_z(lo)[:10], -1), shift_day(iso_z(hi)[:10], 1)
        tdir = os.path.join(hq_root, 'workspace', 'threads')
        try:
            tnames = os.listdir(tdir)
        except OSError:
            tnames = []
        for name in tnames:
            if not name.startswith('T-') or not name.endswith('.json'):
                continue
            d = name_day(name)
            if d is None or d < low or d > high:
                continue
            s = summarize_thread(os.path.join(tdir, name))
            if s and s['session_id'] in wanted:
                by_session.setdefault(s['session_id'], []).append(s)
    for r in rows:
        threads = by_session.get(r['id'])
        if not threads:
            continue
        threads.sort(key=lambda t: t['at'])
        ats = [t['at'] for t in threads if t['at']]
        r['last_activity'] = max(ats) if ats else None
        handoff = next((t for t in reversed(threads) if t['kind'] == 'handoff'), None)
        pick = handoff or threads[-1]
        if pick['title'] is not None:
            r['title'] = pick['title']

    rows.sort(key=lambda r: r['id'])
    rows.sort(key=lambda r: r['started_at'], reverse=True)
    claude = transcript_paths(claude_root, wanted) if claude_root else {}
    codex_names = codex_thread_names(codex_root, wanted) if codex_root else {}
    codex_files = codex_rollouts(codex_root, rows) if codex_root else {}
    for r in rows:
        s = summarize_transcript(claude[r['id']]) if r['id'] in claude else None
        if s is not None:
            r['tool'] = 'claude'
            enrich_from_transcript(r, s)
            continue
        r['tool'] = 'codex' if r['id'] in codex_files else None
        s = summarize_codex_rollout(codex_files[r['id']]) if r['id'] in codex_files else None
        s = s or {'title': None, 'first_prompt': None, 'kind': None, 'cwd': None, 'last_at': None}
        s['title'] = codex_names.get(r['id'])
        enrich_from_transcript(r, s)
    return rows
