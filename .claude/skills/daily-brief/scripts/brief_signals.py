"""Synced signals for the Daily Brief (hot-signal-sync US-015).

The brief reads the signals the hot-channel sync already wrote into the
company vault instead of calling integrations live. Pure file reads: no
subprocess, no network.

Layout (written by `hq sources sync` and the local signals pass):
- `signals/_index/{YYYY-MM-DD}.json`: array of {signal_id, type, source_ref,
  key, written_at}; `key` is the vault-relative path of the signal file.
- Company signals: `signals/{type}/{id}.md` and the legacy
  `signals/slack-dm/{type}/{id}.md`.
- Person signals: `signals/@{audienceKey}/{type}/{id}.md`.
- Cursors: `sources/_cursors/@{personKey}/{adapter}[.{connection}].json` with
  {cursor, updatedAt, lastEventKey}.
- Run ledger: `sources/_runs/@{personKey}/{YYYY-MM-DD}.jsonl`.

The brief belongs to the person: only the `company` key and the person's own
keys are read: key(email), which hq-cli uses for runs and cursors, and
key(personUid), which cloud-written signals use. A signal under any other
`signals/@{key}/` folder is skipped even when the index lists it.
"""
import datetime as dt
import hashlib
import json
import os
import posixpath
import re
import sys
from collections import Counter

COMPANY_KEY = 'company'
# Landed meeting pointers (US-008) and the transcripts they point at.
MEETING_SOURCE_PREFIXES = ('sources/meeting-events/', 'sources/meetings/')
LINE_CHARS = 240
# Upper bound on signal files the legacy folder scan reads per run, so a vault
# with a huge pre-index backlog cannot stall the brief.
LEGACY_SCAN_MAX_FILES = 400
_KEY_RE = re.compile(r'^[0-9a-f]{16}$')


def audience_key(principals):
    """First 16 hex chars of sha256 over the sorted, unique, trimmed principals
    joined with ','. Emails are lowercased; the literal `company` stays as is.
    Matches hq-cli `audienceKey` (byte order sort)."""
    trimmed = [p.strip() for p in principals if isinstance(p, str) and p.strip()]
    if not trimmed:
        raise ValueError('audience key needs at least one principal')
    if len(trimmed) == 1 and trimmed[0].lower() == COMPANY_KEY:
        return COMPANY_KEY
    norm = sorted({p.lower() if '@' in p else p for p in trimmed}, key=lambda s: s.encode('utf-8'))
    return hashlib.sha256(','.join(norm).encode('utf-8')).hexdigest()[:16]


def audience_keys(email, uid=None):
    """The person's own keys: `company`, key(email), key(uid), deduped, missing
    ones skipped. Nothing else."""
    keys = [COMPANY_KEY]
    if isinstance(email, str) and '@' in email:
        keys.append(audience_key([email]))
    if isinstance(uid, str) and uid.strip():
        k = audience_key([uid])
        if k not in keys:
            keys.append(k)
    return keys


def _ts(v):
    if not isinstance(v, str) or not v.strip():
        return None
    try:
        t = dt.datetime.fromisoformat(v.strip().replace('Z', '+00:00'))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


def _frontmatter(md):
    """Flat `key: value` pairs from a leading YAML block."""
    fm = {}
    if not md.startswith('---'):
        return fm, md
    end = md.find('\n---', 3)
    if end < 0:
        return fm, md
    for line in md[3:end].splitlines():
        m = re.match(r'^([A-Za-z_][\w-]*):\s*(.*)$', line)
        if m and m.group(2).strip():
            fm[m.group(1)] = m.group(2).strip().strip('"\'')
    body = md[end + 4:]
    return fm, body[body.find('\n') + 1:] if '\n' in body else ''


def _read(path, limit=64 * 1024):
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            return f.read(limit)
    except OSError:
        return None


def normalize_key(key):
    """The vault-relative signal key in normal form, or None. Rejects absolute
    paths, backslashes, and any empty, `.` or `..` segment, so a key such as
    `signals/./@other/...` cannot pass as a company folder and then resolve to
    someone else's folder."""
    if not isinstance(key, str) or not key or '\\' in key or key.startswith('/'):
        return None
    parts = key.split('/')
    if any(p in ('', '.', '..') for p in parts):
        return None
    norm = posixpath.normpath(key)
    if norm != key or posixpath.isabs(norm):
        return None
    return norm


def own_key_allowed(key, own):
    """True for a company folder (`signals/{type}/...`) or one of the person's
    own `signals/@{key}/...` folders. The check runs on the normalised key."""
    norm = normalize_key(key)
    if norm is None:
        return False
    parts = norm.split('/')
    if len(parts) < 3 or parts[0] != 'signals':
        return False
    seg = parts[1]
    if seg.startswith('@'):
        return seg[1:] in own
    return not seg.startswith('_')


def _window_days(lo, hi):
    d, out = lo.date(), []
    while d <= hi.date():
        out.append(d.isoformat())
        d += dt.timedelta(days=1)
    return out


def _body_line(body):
    """Heading plus first paragraph, flattened to one line."""
    head, para = '', ''
    for block in re.split(r'\n\s*\n', body or ''):
        b = block.strip()
        if not b:
            continue
        if b.startswith('#') and not head and '\n' not in b:
            head = b.lstrip('#').strip()
            continue
        para = b
        break
    text = f'{head}: {para}' if head and para else (para or head)
    return re.sub(r'\s+', ' ', text).strip()[:LINE_CHARS]


def cite(source_ref):
    """Short citation: the source file stem."""
    base = os.path.basename(source_ref.rstrip('/'))
    for ext in ('.raw.json', '.md', '.json'):
        if base.endswith(ext):
            return base[:-len(ext)]
    return base


def safe_vault_path(vault, rel, top):
    """Absolute path of `rel` when it resolves inside `vault/top` (symlinks
    followed), else None. `rel` comes from synced files other people write."""
    if not isinstance(rel, str) or not rel or os.path.isabs(rel) or '..' in rel.replace('\\', '/').split('/'):
        return None
    base = os.path.realpath(vault)
    root = os.path.realpath(os.path.join(vault, top))
    path = os.path.realpath(os.path.join(vault, rel))
    if not root.startswith(base + os.sep):
        return None
    return path if path.startswith(root + os.sep) else None


def _meeting_of(vault, source_ref):
    """{title, transcript_id} for a meeting-derived signal, read from the landed
    pointer's frontmatter (or the transcript itself). None for other sources."""
    if not source_ref.startswith(MEETING_SOURCE_PREFIXES):
        return None
    path = safe_vault_path(vault, source_ref, 'sources')
    if not path:
        return None
    md = _read(path) or ''
    fm, _ = _frontmatter(md)
    payload = fm.get('payload_ref') or (source_ref if source_ref.startswith('sources/meetings/') else '')
    return {'title': fm.get('title'), 'transcript_id': cite(payload) if payload else None}


def _line(vault, row):
    """Index row -> brief line, or None when the file is missing. `source_ref`
    comes from the row, then the file frontmatter."""
    path = safe_vault_path(vault, row.get('key'), 'signals')
    md = _read(path) if path else None
    if md is None:
        return None
    fm, body = _frontmatter(md)
    ref = row.get('source_ref') or fm.get('source_ref')
    text = fm.get('canonical_content') or _body_line(body)
    out = {'signal_id': row.get('signal_id') or fm.get('signal_id'), 'type': row.get('type') or fm.get('type'),
           'text': re.sub(r'\s+', ' ', text or '').strip()[:LINE_CHARS], 'source_ref': ref or None,
           'cite': cite(ref) if ref else None, 'written_at': row.get('written_at') or fm.get('written_at'),
           'key': row['key'], 'owner': fm.get('owner') or fm.get('assignee')}
    if ref:
        mtg = _meeting_of(vault, ref)
        if mtg:
            out['meeting'] = mtg
    return out


def _legacy_rows(vault, own, lo, hi):
    """Rows for days with no index file: scan the type folders (company,
    legacy slack-dm, and the person's own @key folders) and keep files written
    inside the window (frontmatter `written_at`, else file mtime)."""
    base = os.path.join(vault, 'signals')
    dirs = []
    try:
        top = sorted(os.listdir(base))
    except OSError:
        return []
    for seg in top:
        p = os.path.join(base, seg)
        if not os.path.isdir(p) or seg.startswith('_'):
            continue
        if seg.startswith('@') and seg[1:] not in own:
            continue
        if seg.startswith('@') or seg == 'slack-dm':
            try:
                subs = sorted(os.listdir(p))
            except OSError:
                continue
            dirs += [(f'signals/{seg}/{t}', os.path.join(p, t)) for t in subs if os.path.isdir(os.path.join(p, t))]
        else:
            dirs.append((f'signals/{seg}', p))
    rows, scanned = [], 0
    for rel, d in dirs:
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for name in names:
            if not name.endswith('.md'):
                continue
            if scanned >= LEGACY_SCAN_MAX_FILES:
                return rows
            scanned += 1
            path = safe_vault_path(vault, f'{rel}/{name}', 'signals')
            if not path:
                continue
            fm, _ = _frontmatter(_read(path, 8 * 1024) or '')
            at = _ts(fm.get('written_at'))
            if at is None:
                try:
                    at = dt.datetime.fromtimestamp(os.path.getmtime(path), dt.timezone.utc)
                except OSError:
                    continue
            if lo <= at <= hi:
                rows.append({'signal_id': fm.get('signal_id') or name[:-3], 'type': fm.get('type') or rel.rsplit('/', 1)[1],
                             'source_ref': fm.get('source_ref'), 'key': f'{rel}/{name}',
                             'written_at': at.isoformat()})
    return rows


def read_window(vault, now, hours=24, email=None, uid=None):
    """Signals written in the last `hours` up to `now`, the person's own keys only.
    Returns {lines, dropped_uncited, legacy_days, keys}."""
    own = set(audience_keys(email, uid))
    hi = now.astimezone(dt.timezone.utc)
    lo = hi - dt.timedelta(hours=hours)
    rows, legacy_days, seen = [], [], set()
    for day in _window_days(lo, hi):
        path = os.path.join(vault, 'signals', '_index', f'{day}.json')
        raw = _read(path, 16 * 1024 * 1024)
        if raw is None:
            legacy_days.append(day)
            continue
        try:
            data = json.loads(raw)
        except ValueError:
            data = []
        if not isinstance(data, list):
            print(f'brief_signals: ignoring {day}.json index, not a list', file=sys.stderr)
            data = []
        rows += [r for r in data if isinstance(r, dict) and isinstance(r.get('key'), str)]
    if legacy_days:
        rows += [r for r in _legacy_rows(vault, own, lo, hi) if r['written_at'][:10] in legacy_days]
    lines, dropped = [], 0
    for r in rows:
        at = _ts(r.get('written_at'))
        if at is None or not lo <= at <= hi or not own_key_allowed(r['key'], own):
            continue
        sid = r.get('signal_id')
        if sid is not None and not isinstance(sid, str):
            continue
        sid = sid or r['key']
        if sid in seen:
            continue
        seen.add(sid)
        line = _line(vault, r)
        if line is None:
            continue
        if not line['source_ref']:
            dropped += 1
            continue
        lines.append(line)
    lines.sort(key=lambda x: x['written_at'] or '', reverse=True)
    return {'lines': lines, 'dropped_uncited': dropped, 'legacy_days': legacy_days,
            'keys': sorted(own)}


def last_ledger_run(vault, person_key):
    """Newest run across `sources/_runs/@{personKey}/*.jsonl`, or None."""
    d = os.path.join(vault, 'sources', '_runs', f'@{person_key}')
    try:
        files = sorted(f for f in os.listdir(d) if f.endswith('.jsonl'))
    except OSError:
        return None
    best, best_at = None, None
    for f in reversed(files):
        for line in (_read(os.path.join(d, f), 8 * 1024 * 1024) or '').splitlines():
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if not isinstance(e, dict):
                continue
            raw = e.get('finishedAt') or e.get('startedAt')
            at = _ts(raw)
            if at is None:
                continue
            if best is None or at > best_at:
                best_at = at
                best = {'run_id': e.get('runId'), 'adapter': e.get('adapter'), 'status': e.get('status'),
                        'finished_at': raw.strip(), 'trigger': e.get('trigger')}
        if best:
            break
    return best


def lag(vault, now, person_key):
    """None when today's (UTC) index exists. Otherwise {newest_index_date,
    days_behind, last_run, line}."""
    d = os.path.join(vault, 'signals', '_index')
    dates = []
    try:
        names = os.listdir(d)
    except OSError:
        names = []
    for f in names:
        if not re.match(r'^\d{4}-\d{2}-\d{2}\.json$', f):
            continue
        try:
            dates.append(dt.date.fromisoformat(f[:-5]))
        except ValueError:
            continue  # e.g. 2026-99-99.json
    dates.sort()
    # The index writer (hq-cli hot-channels landing) names files by UTC date.
    today = now.astimezone(dt.timezone.utc).date()
    newest = dates[-1] if dates else None
    # A newest date after today is clock skew between machines: treat it as current.
    if newest is not None and newest >= today:
        return None
    behind = (today - newest).days if newest else None
    newest = newest.isoformat() if newest else None
    run = last_ledger_run(vault, person_key) if person_key else None
    if run:
        tail = f"last sync run {run['finished_at'][:10] or 'unknown date'}, {run['adapter']}, {run['status']}"
    else:
        tail = 'no sync run recorded'
    head = f'Signals are behind: newest index is {newest}' if newest else 'Signals are behind: no signal index yet'
    return {'newest_index_date': newest, 'days_behind': behind, 'last_run': run, 'line': f'{head} ({tail}).'}


def freshness(vault, person_key):
    """One marker per cursor file: {adapter, connection, last_synced, source}.
    `updatedAt` from the file wins; mtime only when it is missing or unreadable."""
    d = os.path.join(vault, 'sources', '_cursors', f'@{person_key}')
    try:
        names = sorted(f for f in os.listdir(d) if f.endswith('.json'))
    except OSError:
        return []
    out = []
    for name in names:
        stem = name[:-5]
        adapter, _, conn = stem.partition('.')
        path = os.path.join(d, name)
        try:
            rec = json.loads(_read(path) or '')
        except ValueError:
            rec = {}
        at = _ts(rec.get('updatedAt')) if isinstance(rec, dict) else None
        src = 'cursor'
        if at is None:
            at = dt.datetime.fromtimestamp(os.path.getmtime(path), dt.timezone.utc)
            src = 'mtime'
        out.append({'adapter': adapter, 'connection': conn or None,
                    'last_synced': at.astimezone(dt.timezone.utc).isoformat(), 'source': src})
    return out


def _norm(s):
    return re.sub(r'\s+', ' ', (s or '').strip().lower())


def meeting_rows(lines, mtgs, is_mine=None):
    """meeting_signals[] rows built from synced meeting-derived lines, matched to
    `hq meetings list` rows by transcript id, then by title. Shape matches the
    old per-meeting fetch (minus `detail`), and every item keeps its source_ref."""
    by_id = {m.get('id'): m for m in mtgs or [] if m.get('id')}
    # Title is only a fallback, and only for a title one meeting has (a recurring
    # "Standup" would otherwise attach to the wrong day).
    titles = Counter(_norm(m.get('title')) for m in mtgs or [] if m.get('title'))
    by_title = {_norm(m.get('title')): m for m in mtgs or [] if m.get('title') and titles[_norm(m.get('title'))] == 1}
    groups = {}
    for ln in lines or []:
        mt = ln.get('meeting')
        if not mt:
            continue
        m = by_id.get(mt.get('transcript_id')) or by_title.get(_norm(mt.get('title'))) or {}
        k = m.get('id') or mt.get('transcript_id') or mt.get('title')
        g = groups.setdefault(k, {'meeting': m.get('title') or mt.get('title'), 'title': m.get('title') or mt.get('title'),
                                  'meeting_id': m.get('id'), 'start': m.get('start'),
                                  'recorded_by_me': bool(m.get('recorded_by_me')), 'counts': {},
                                  'decisions': [], 'action_items': []})
        g['counts'][ln['type']] = g['counts'].get(ln['type'], 0) + 1
        bucket = {'decision': 'decisions', 'action_item': 'action_items'}.get(ln['type'])
        if bucket and len(g[bucket]) < 5:
            mine = bool(is_mine(ln.get('owner'))) if is_mine else False
            g[bucket].append({'text': ln['text'], 'owner': ln.get('owner'), 'mine': mine,
                              'source_ref': ln['source_ref'], 'cite': ln['cite']})
    return list(groups.values())


def meetings_without_signals(lines, meetings_in_window):
    """The operator's plain line: when meetings exist in the window but no synced
    meeting signals do, say how many meetings are still waiting. None otherwise."""
    n = len(meetings_in_window or [])
    if n == 0 or any(ln.get('meeting') for ln in lines or []):
        return None
    return {'count': n, 'line': f"Signals not yet generated for {n} meeting{'s' if n != 1 else ''}."}


def collect(vault, now, hours=24, email=None, uid=None, identity_source=None):
    """Everything the brief needs from synced signals in one dict. The ledger
    and cursors use key(email), which is what hq-cli writes."""
    person_key = audience_key([email]) if isinstance(email, str) and '@' in email else None
    res = read_window(vault, now, hours, email, uid)
    res['identity_source'] = identity_source
    res['lag'] = lag(vault, now, person_key)
    res['freshness'] = freshness(vault, person_key) if person_key else []
    res['person_key'] = person_key
    res['total'] = len(res['lines'])
    return res
