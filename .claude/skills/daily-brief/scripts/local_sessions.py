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
import re
import unicodedata

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


# ---------- secret filter ----------
# Titles can come from the person's own prompt text, and prompts sometimes hold
# credentials. The filter is safe by default: any line that names a credential
# or holds a long random-looking run is dropped, and the caller falls back to
# "Session in <project>". Some good titles are dropped; no credential is shown.
# This is stricter than housekeeping.py's _SECRETISH, which masks values in
# place; here the whole line is dropped.
_SECRET_PATTERNS = re.compile(
    r'(?<![A-Za-z0-9])(?:sk-ant-[A-Za-z0-9_-]{4,}|sk-[A-Za-z0-9_-]{8,}|sk_(?:live|test)_[A-Za-z0-9]{8,}'
    r'|gh[pousr]_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,}|glpat-[A-Za-z0-9_-]{8,}|npm_[A-Za-z0-9]{8,}'
    r'|xox[abeprs]-[A-Za-z0-9-]{8,}|(?:AKIA|ASIA)[0-9A-Z]{12,}|AIza[0-9A-Za-z_-]{20,}'
    r'|eyJ[A-Za-z0-9_-]{8})'
    r'|-----BEGIN [A-Z ]*PRIVATE KEY'
    r'|://[^\s/:@]+:[^\s/@]+@')
# A credential word anywhere in the line, in any case and inside identifiers
# such as API_KEY or GITHUB_TOKEN. "key" and "pass" count only as whole words
# or identifier parts, so "monkey" and "passing" do not.
_SECRET_WORDS = re.compile(
    r'(?i)password|passwd|passphrase|passcode|pwd|secret|token|api[\s_.-]*key|bearer'
    r'|private[\s_.-]*key|access[\s_.-]*key|auth|credential|(?<![a-z])creds(?![a-z])'
    r'|(?<![a-z])keys?(?![a-z])|(?<![a-z])pass(?![a-z])|sshpass'
    r'|(?<![a-z])(?:pin|otp|2fa|mfa|pw|cred)(?![a-z])|passwort|contrase(?:ñ|n)a|mot de passe')
# NAME= or NAME: where the name holds a credential part with no separator,
# such as DBPASS=, PGPASS: or MYKEY=. Each maximal name run is found once and the
# separator is checked at its end, so a long run with no = or : stays linear.
_ASSIGN_NAME = re.compile(r'[A-Za-z0-9_.-]+')
_ASSIGN_SEP = re.compile(r'\s*[=:]')
_ASSIGN_PARTS = ('pass', 'key', 'pwd', 'pw', 'cred', 'secret', 'token', 'auth', 'pin')
# 16+ letters and digits mixed, such as a short API token or a base32 TOTP seed.
_MIXED_RUN = re.compile(r'[A-Za-z0-9]{16,}')
_HEX_RUN = re.compile(r'[0-9A-Fa-f]{24,}')
# base64 and base62 runs, including the / + = _ - that split AWS keys and URL-safe tokens.
_TOKEN_RUN = re.compile(r'[A-Za-z0-9_+/=-]{20,}')


# Letters that NFKC leaves alone but that read as ASCII: dotless i, long s,
# Kelvin sign, dotted capital I.
_LOOKALIKES = str.maketrans({'\u0131': 'i', '\u017f': 's', '\u212a': 'K', '\u0130': 'I'})


def _random_run(run):
    """A 20+ character run that holds a digit or a capital letter. Lowercase
    words joined by - _ or / (branch names, paths) are not matched."""
    return any(ch.isdigit() or ch.isupper() for ch in run)


def looks_secret(text):
    """True when text may hold a credential: a credential word (password,
    passwd, passphrase, passcode, pwd, secret, token, api key, bearer, private
    key, access key, auth, credential, creds, key, pass, pin, otp, 2fa, mfa),
    a known API key prefix, a private-key header, a URL
    with a password in it, a hex run of 24+ characters, or a base64/base62 run
    of 20+ characters with a digit or capital letter."""
    if not isinstance(text, str) or not text:
        return False
    # Check the raw text and a folded copy (full-width and other compatibility
    # forms folded, accents dropped). Folding can join a letter onto a key
    # prefix, as in an accented letter before sk-, so the raw check stays too.
    if text.isascii():
        return _looks_secret(text)
    folded = unicodedata.normalize('NFKC', ''.join(
        ch for ch in unicodedata.normalize('NFD', text.translate(_LOOKALIKES))
        if unicodedata.category(ch) != 'Mn'))
    return _looks_secret(text) or (folded != text and _looks_secret(folded))


def _looks_secret(text):
    if _SECRET_WORDS.search(text) or _SECRET_PATTERNS.search(text) or _HEX_RUN.search(text):
        return True
    for m in _ASSIGN_NAME.finditer(text):
        if _ASSIGN_SEP.match(text, m.end()) and any(p in m.group().lower() for p in _ASSIGN_PARTS):
            return True
    if any(any(c.isdigit() for c in run) and any(c.isalpha() for c in run)
           for run in _MIXED_RUN.findall(text)):
        return True
    return any(_random_run(run) for run in _TOKEN_RUN.findall(text))


def safe_title(text):
    """text, or None when it looks like it holds a credential."""
    return None if looks_secret(text) else text


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
    """The line collapsed and capped, or '' (found, but withheld) when the full
    line looks like it holds a credential."""
    collapsed = ' '.join(line.split())
    if looks_secret(collapsed):
        return ''
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
    """Title, summary and cwd from transcript lines, latest record wins. Only
    metadata records are parsed; message text never reaches the result."""
    for line in text.splitlines():
        if '"type":"summary"' in line:
            value = _loads(line)
            t = value.get('summary') if isinstance(value, dict) and value.get('type') == 'summary' else None
            if isinstance(t, str) and t.strip():
                out['summary'] = t.strip()
            continue
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


def summarize_transcript(path, scan_cap=TRANSCRIPT_SCAN_CAP):
    try:
        size = os.stat(path).st_size
    except OSError:
        return None
    s = {'title': None, 'first_prompt': None, 'kind': None, 'cwd': None, 'last_at': _mtime_iso(path)}
    start = max(0, size - TRANSCRIPT_TAIL)
    early = {'title': None, 'cwd': None}
    with open(path, 'rb') as f:
        f.seek(start)
        scan_transcript_lines(f.read(TRANSCRIPT_TAIL).decode('utf-8', errors='replace'), s)
        if s['title'] is None and start > 0:
            # Title and summary records can sit only near the start of a long transcript.
            f.seek(0)
            scan_transcript_lines(f.read(min(start, scan_cap)).decode('utf-8', errors='replace'), early)
            s['title'] = early['title']
            if s['cwd'] is None:
                s['cwd'] = early['cwd']
    # A custom title wins over Claude Code's own summary of the session.
    summary = s.pop('summary', None) or early.get('summary')
    if s['title'] is None:
        s['title'] = summary
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


def codex_thread_names(codex, wanted, cap=None):
    out = {}
    if not wanted:
        return out
    try:
        f = open(os.path.join(codex, 'session_index.jsonl'), encoding='utf-8', errors='replace')
    except OSError:
        return out
    read = 0
    with f:
        for line in f:
            read += len(line)
            if cap is not None and read > cap:
                break
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
        row['title'] = safe_title(s.get('title'))
    named = row['title'] is not None
    if row['project'] is None:
        row['project'] = (repo_from_cwd(s['cwd']) if s.get('cwd') else None) or (product_from_title(row['title']) if row['title'] else None)
    if not named:
        row['title'] = s.get('first_prompt') or None
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
    # Default: every Claude Code projects folder, including CLAUDE_CONFIG_DIR's.
    claude_roots = [claude_root] if claude_root is not None else claude_project_roots(home)
    codex_root = codex_root if codex_root is not None else codex_home(home)
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
            'title': safe_title(fields.get('title') or fields.get('task')),
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
        if safe_title(pick['title']) is not None:
            r['title'] = pick['title']

    rows.sort(key=lambda r: r['id'])
    rows.sort(key=lambda r: r['started_at'], reverse=True)
    claude = {}
    for root in claude_roots:
        if root:
            for sid, path in transcript_paths(root, wanted - set(claude)).items():
                claude[sid] = path
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


# ---------- machine inventory (welcome edition) ----------
# Bounds for the welcome inventory. Counts come from directory listings and
# stat calls only. File contents are read for a few files per project at most.
INVENTORY_NEWEST = 3          # newest Claude transcripts per project read for the cwd
INVENTORY_CODEX_HEADS = 300   # newest Codex rollouts read for the cwd
INVENTORY_RECENT = 15         # newest transcripts read for titles (recent work)
RECENT_TITLES_BUDGET_S = 20.0  # all title reads together
RECENT_SCAN_CAP = 1024 * 1024  # bytes read from the start of a long transcript for its title
CODEX_INDEX_CAP = 16 * 1024 * 1024  # bytes of Codex session_index.jsonl read for thread names
INVENTORY_CWD_HEAD = 64 * 1024
INVENTORY_BUDGET_S = 30.0
HARNESS_CLAUDE, HARNESS_CODEX, HARNESS_CURSOR = 'claude_code', 'codex', 'cursor'


def claude_project_roots(home=None, env=None):
    """Every Claude Code projects folder on this machine: ~/.claude/projects, and
    the projects folder under CLAUDE_CONFIG_DIR when that is set. Missing folders
    are dropped."""
    home = home or os.path.expanduser('~')
    env = os.environ if env is None else env
    roots = [os.path.join(home, '.claude', 'projects')]
    if env.get('CLAUDE_CONFIG_DIR'):
        roots.append(os.path.join(env['CLAUDE_CONFIG_DIR'], 'projects'))
    out = []
    for r in roots:
        real = os.path.realpath(r)
        if os.path.isdir(real) and real not in out:
            out.append(real)
    return out


def codex_home(home=None, env=None):
    home = home or os.path.expanduser('~')
    env = os.environ if env is None else env
    return env.get('CODEX_HOME') or os.path.join(home, '.codex')


def cursor_workspaces_dir(home=None):
    home = home or os.path.expanduser('~')
    return os.path.join(home, 'Library', 'Application Support', 'Cursor', 'User', 'workspaceStorage')


def _cwd_from_head(path, n=INVENTORY_CWD_HEAD):
    """The first `"cwd":"…"` value in the head of a transcript, or None."""
    out = {'title': None, 'cwd': None}
    for line in read_head(path, n).splitlines():
        if '"cwd":"' in line:
            scan_transcript_lines(line, out)
            if out['cwd']:
                return out['cwd']
    return None


def _scandir_files(d, suffix):
    """[(path, mtime)] for regular files in d ending in suffix. Stat only."""
    out = []
    try:
        with os.scandir(d) as it:
            for e in it:
                if not e.name.endswith(suffix):
                    continue
                try:
                    if e.is_file():
                        out.append((e.path, e.stat().st_mtime))
                except OSError:
                    continue
    except OSError:
        pass
    return out


def _iso_ts(ts):
    return iso_z(dt.datetime.fromtimestamp(ts, dt.timezone.utc))


def codex_session_id(path):
    """`rollout-2026-10-01T12-34-56-<id>.jsonl` → `<id>`."""
    return os.path.basename(path)[:-len('.jsonl')].split('-', 6)[-1]


def _add_project(projects, cwd, harness, ids, last_ts):
    p = projects.setdefault(cwd, {'path': cwd, 'sessions': 0, 'last_ts': 0.0, 'by_harness': {}, 'ids': []})
    n = len(ids)
    p['sessions'] += n
    p['ids'].extend(ids)
    p['last_ts'] = max(p['last_ts'], last_ts)
    p['by_harness'][harness] = p['by_harness'].get(harness, 0) + n


def _inside(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def _project_dir_ok(entry, home_real):
    """A real project folder, or a symlink to one inside the home folder."""
    try:
        if not entry.is_dir():
            return False
        return not entry.is_symlink() or _inside(os.path.realpath(entry.path), home_real)
    except OSError:
        return False


def inventory(claude_roots=None, codex_root=None, cursor_root=None, budget_s=INVENTORY_BUDGET_S, clock=None,
              home=None):
    """Agent sessions on this machine, counted from file listings.

    Returns {counts: {claude_code, codex, cursor}, projects:
    {cwd: {path, sessions, last_ts, by_harness, ids}}, unplaced, sessions: {id:
    harness}, days, recent: [{id, path, harness, cwd, ts}], notes}.

    Claude Code: one transcript per session in <projects>/<dir>/*.jsonl. The
    project folder is read from the cwd of the newest transcripts in each dir.
    Codex: one rollout per session in sessions/YYYY/MM/DD. The newest rollouts
    are read for their cwd. Cursor: workspaces with chat state, counted only.
    Message text is never read here. Reads stop at the time budget; later
    sessions are still counted, without a project. A folder that cannot be read
    adds a plain note. A project folder that is a symlink to somewhere outside
    the home folder is not followed."""
    import time
    clock = clock or time.monotonic
    deadline = clock() + budget_s
    home = home or os.path.expanduser('~')
    home_real = os.path.realpath(home)
    claude_roots = claude_project_roots(home) if claude_roots is None else claude_roots
    codex_root = codex_home(home) if codex_root is None else codex_root
    cursor_root = cursor_workspaces_dir(home) if cursor_root is None else cursor_root
    counts = {HARNESS_CLAUDE: 0, HARNESS_CODEX: 0, HARNESS_CURSOR: 0}
    projects, sessions, days, notes, files = {}, {}, set(), [], []
    unplaced = 0
    timed_out = False

    for root in claude_roots:
        try:
            with os.scandir(root) as it:
                dirs = sorted(e.path for e in it if _project_dir_ok(e, home_real))
        except OSError:
            notes.append("Couldn't read Claude Code history")
            continue
        for d in dirs:
            found = [x for x in _scandir_files(d, '.jsonl') if os.path.basename(x[0])[:-6] not in sessions]
            if not found:
                continue
            found.sort(key=lambda x: -x[1])
            for path, mt in found:
                sessions[os.path.basename(path)[:-6]] = HARNESS_CLAUDE
                days.add(_iso_ts(mt)[:10])
            counts[HARNESS_CLAUDE] += len(found)
            cwd = None
            for path, _ in found[:INVENTORY_NEWEST]:
                if clock() >= deadline:
                    timed_out = True
                    break
                cwd = _cwd_from_head(path)
                if cwd:
                    break
            if cwd:
                _add_project(projects, cwd, HARNESS_CLAUDE, [os.path.basename(x[0])[:-6] for x in found], found[0][1])
            else:
                unplaced += len(found)
            files.extend((mt, path, HARNESS_CLAUDE, cwd) for path, mt in found[:INVENTORY_RECENT])

    rollouts = []
    sroot = os.path.join(codex_root, 'sessions')
    if os.path.isdir(sroot):
        for dirpath, dirnames, filenames in os.walk(sroot):
            dirnames.sort()
            for name in filenames:
                if name.startswith('rollout-') and name.endswith('.jsonl'):
                    path = os.path.join(dirpath, name)
                    try:
                        rollouts.append((os.stat(path).st_mtime, path))
                    except OSError:
                        continue
        rollouts.sort(reverse=True)
    for i, (mt, path) in enumerate(rollouts):
        sessions[codex_session_id(path)] = HARNESS_CODEX
        days.add(_iso_ts(mt)[:10])
        cwd = None
        if i < INVENTORY_CODEX_HEADS:
            if clock() < deadline:
                cwd = _cwd_from_head(path)
            else:
                timed_out = True
        if cwd:
            _add_project(projects, cwd, HARNESS_CODEX, [codex_session_id(path)], mt)
        else:
            unplaced += 1
        if i < INVENTORY_RECENT:
            files.append((mt, path, HARNESS_CODEX, cwd))
    counts[HARNESS_CODEX] = len(rollouts)

    if os.path.isdir(cursor_root):
        try:
            with os.scandir(cursor_root) as it:
                counts[HARNESS_CURSOR] = sum(1 for e in it if e.is_dir()
                                             and os.path.isfile(os.path.join(e.path, 'state.vscdb')))
        except OSError:
            notes.append("Couldn't read Cursor history")

    if timed_out:
        notes.append('Some older sessions were counted without their project')
    files.sort(key=lambda x: -x[0])
    recent = [{'id': codex_session_id(p) if h == HARNESS_CODEX else os.path.basename(p)[:-6],
               'path': p, 'harness': h, 'cwd': cwd, 'ts': mt} for mt, p, h, cwd in files[:INVENTORY_RECENT]]
    return {'counts': counts, 'projects': projects, 'unplaced': unplaced,
            'sessions': sessions, 'days': days, 'recent': recent, 'notes': notes}


def recent_titles(recent, codex_root=None, keep=None, limit=5, budget_s=RECENT_TITLES_BUDGET_S, clock=None):
    """[{id, title, cwd, at, harness}] for the person's recent sessions, newest
    first. Headless agent runs and lanes are skipped, and so is any session
    `keep(id, cwd)` rejects (company isolation: its title is never read into the
    result). Titles prefer the Codex thread name, then the Claude Code custom
    title or summary, then the first prompt line. One that looks like it holds
    a credential is dropped; the session is kept with title None, for the
    caller's "Session in <project>" fallback. Reads at most len(recent) files, at most RECENT_SCAN_CAP bytes from
    the start of each long transcript, and stops at the time budget."""
    import time
    clock = clock or time.monotonic
    deadline = clock() + budget_s
    codex_root = codex_home() if codex_root is None else codex_root
    names = codex_thread_names(codex_root, {r['id'] for r in recent if r['harness'] == HARNESS_CODEX},
                               cap=CODEX_INDEX_CAP)
    out = []
    for r in recent:
        if len(out) >= limit or clock() >= deadline:
            break
        try:
            s = (summarize_transcript(r['path'], scan_cap=RECENT_SCAN_CAP) if r['harness'] == HARNESS_CLAUDE
                 else summarize_codex_rollout(r['path']))
        except OSError:
            continue
        if not s or s.get('kind') in (KIND_AGENT, KIND_LANE):
            continue
        cwd = s.get('cwd') or r['cwd']
        if keep is not None and not keep(r['id'], cwd):
            continue
        found = [t for t in (names.get(r['id']), s.get('title'), s.get('first_prompt')) if t is not None]
        if not found:
            continue
        title = next((t for t in found if t and not looks_secret(t)), None)
        out.append({'id': r['id'], 'title': title, 'cwd': cwd, 'at': _iso_ts(r['ts']), 'harness': r['harness']})
    return out
