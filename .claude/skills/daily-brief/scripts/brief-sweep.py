#!/usr/bin/env python3
"""Daily Brief data sweep.

Collects one person's past N days into a normalized brief-data.json that the
brief generator consumes. Every source is optional: failures are recorded in
`sources[name].error` and never silently dropped.

Usage:
  python3 -I brief-sweep.py --all --hq-root /path/to/HQ --out brief-data.json
  python3 -I brief-sweep.py --company <slug> --days 7 --hours 24 --hq-root /path/to/HQ --out brief-data.json
  python3 -I brief-sweep.py --personal [--welcome] --hq-root /path/to/HQ --out brief-data.json

`--hours` is the session, PR and meeting window (the person's day); `--days` is
the per-day rollup for the week arc. `--catch-up` widens the meetings window
to the first rollup day.

In explicit personal mode (`--personal`) the sweep reads what is
the person's own: local sessions that are bound to no company, their PRs,
personal DMs (no company on the message), main-branch CI for the repos of
those PRs, prefs and brief history. Meetings, meeting signals, fleet and
integrations are recorded as skipped with `skipped_reason: "needs a company"`,
and `company` is null. `--welcome` (or `--personal` with no ready run in
index.jsonl) adds a `welcome` block built from the local session scan and the
latest workspace/imports/<date>/report.json.

A company brief keeps only inbox messages tagged with that company's slug.
When the inbox page has messages and none of them carry a company slug field,
the dms source is skipped with `skipped_reason: "inbox has no company tag"`
instead of an empty success. A personal brief still keeps those messages.

`--company` must be in the session lock (`core/scripts/hq-session.sh get
company_slugs`). A slug outside that set is refused before any source runs.

Besides the raw sources the file carries derived data the app's widgets read:
sessions[].project/product/cwd/has_handoff, prs[].merge_hours/reviewDecision,
prs_summary.median_merge_hours/by_product, releases, main_health[].red objects
with since/merges_on_top and a delta vs the previous ready run, fleet.stuck/
delta/series, meetings[].attended/duration_min (window-filtered, deduped),
dms[].need_you with a truncation note in sources.dms, and previous_run.

Rules baked in:
- Company isolation: sessions that belong to another company (or none) are
  counted only (no titles, project or cwd). Without a company, sessions bound
  to any company are counted only and unbound ones are the person's own.
- No secrets are read or printed. gh runs with the user's own login.
- Previous runs are read only, through workspace/brief/index.jsonl.
"""
import argparse, json, os, re, subprocess, sys, tempfile, datetime as dt
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed

def run(cmd, timeout=90):
    env = {k: v for k, v in os.environ.items() if k not in ('GH_TOKEN', 'GITHUB_TOKEN')}
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout).strip()[:400])
    return p.stdout

def jrun(cmd, timeout=90):
    out = run(cmd, timeout)
    i = min([x for x in (out.find('{'), out.find('[')) if x >= 0], default=-1)
    if i < 0:
        raise RuntimeError('no JSON in output: ' + out[:200])
    return json.loads(out[i:])

SOURCES = {}
NEEDS_COMPANY = 'needs a company'
# Company briefs cannot filter `hq dm inbox` until messages carry a slug field.
INBOX_NO_COMPANY_TAG = 'inbox has no company tag'
# Slug fields the inbox would have to expose. `companyUid` is an opaque id, not one of these.
COMPANY_TAG_KEYS = ('company', 'companySlug', 'company_slug')
# Sources that read one company's data; a brief with no company skips them.
COMPANY_SOURCES = ('meetings', 'meeting_signals', 'fleet', 'integrations')
# sessions[].company for the person's own rows when the brief has no company.
PERSONAL_TAG = 'personal'


def own_tag(company):
    """The sessions[].company value that marks the person's own rows."""
    return company or PERSONAL_TAG


class SourceSkipped(Exception):
    """Raised by a source that looked, then decided it cannot answer.
    The wrapper records `state: skipped` instead of an empty success or a failure."""

    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def skip_source(name, reason=NEEDS_COMPANY):
    """Record a source left out on purpose. Nothing was read, so `ok` is false,
    but there is no error: `state` is 'skipped' and `skipped_reason` says why."""
    SOURCES[name] = {'ok': False, 'state': 'skipped', 'skipped_reason': reason, 'count': None}
    return None


def count_of(v):
    """Rows in a source result: list length, or `total` for a dict that has one
    (the fleet source returns {total, by_status, agents}, so its count is the
    number of agents, not the number of keys)."""
    if isinstance(v, dict):
        return v['total'] if isinstance(v.get('total'), int) else len(v)
    return len(v) if hasattr(v, '__len__') else None


# Plain names for failure notes. Exception text never reaches brief data; it
# goes to stderr.
SOURCE_LABELS = {'signals_alltime': 'signals', 'main_health': 'main-branch builds', 'prs': 'pull requests',
                 'dms': 'DMs', 'fleet': 'agents', 'brief_history': 'brief history', 'welcome': 'welcome history'}


def plain_note(name):
    return f"Couldn't read {SOURCE_LABELS.get(name, name.replace('_', ' '))}."


def failure(name, exc):
    """{note, error} for a failed read, both plain. The exception goes to stderr."""
    print(f'[sweep] {name} failed: {exc}', file=sys.stderr)
    note = plain_note(name)
    return {'note': note, 'error': note}


def source(name):
    def deco(fn):
        def wrapped(*a, **k):
            try:
                v = fn(*a, **k)
                SOURCES[name] = {'ok': True, 'state': 'ok', 'count': count_of(v)}
                return v
            except SourceSkipped as e:
                return skip_source(name, e.reason)
            except Exception as e:  # recorded, not swallowed
                note = plain_note(name)
                SOURCES[name] = {'ok': False, 'state': 'failed', 'note': note, 'error': note}
                print(f'[sweep] {name} failed: {e}', file=sys.stderr)
                return None
        return wrapped
    return deco

# ---------- sources ----------
def _load_local_sessions():
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'local_sessions.py')
    spec = importlib.util.spec_from_file_location('local_sessions', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

def handoff_session_ids(hq_root, start, end, mod):
    """Session ids with a `handoff` thread record dated inside [start, end]
    (plus one day each side, like local_sessions.scan reads threads). Read-only."""
    tdir = os.path.join(hq_root, 'workspace', 'threads')
    try:
        names = os.listdir(tdir)
    except OSError:
        return set()
    low = mod.shift_day(start.date().isoformat(), -1)
    high = mod.shift_day(end.date().isoformat(), 1)
    out = set()
    for name in names:
        if not name.startswith('T-') or not name.endswith('.json'):
            continue
        d = mod.name_day(name)
        if d is None or d < low or d > high:
            continue
        s = mod.summarize_thread(os.path.join(tdir, name))
        if s and s.get('kind') == 'handoff':
            out.add(s['session_id'])
    return out


def session_row(r, company, handoff_ids=()):
    """One scan row -> brief-data sessions[] row. Rows outside the company keep
    only counts and times: no title, project, cwd or product (company isolation).
    With no company, rows bound to no company are the person's own (tagged
    'personal') and rows bound to any company are 'other', counted only.
    `product` is the human name for the repo in `project` (brief_rank.product_for)."""
    co = r.get('company')
    if company:
        tag = company if co == company else ('other' if co else 'unknown')
    else:
        tag = 'other' if co else PERSONAL_TAG
    t = dt.datetime.fromisoformat(r['started_at'].replace('Z', '+00:00')).astimezone()
    own = tag == own_tag(company)
    project = r.get('project') if own else None
    if 'has_handoff' in r:
        has_handoff = bool(r['has_handoff'])
    else:
        has_handoff = r.get('id') in handoff_ids
    return {'id': r['id'], 'started_at': r['started_at'], 'date': t.date().isoformat(),
            'time': t.strftime('%H:%M'), 'company': tag,
            'title': _sibling('local_sessions').safe_title(r.get('title')) if own else None, 'kind': r['kind'],
            'project': project, 'product': _product_for(project) if project else None,
            'cwd': r.get('cwd') if own else None,
            'last_activity': r.get('last_activity'),
            'has_handoff': has_handoff if own else None}


@source('sessions')
def sessions(root, start, end, company):
    """Sessions started in [start, end] from workspace/sessions + transcripts.
    Rows outside the brief's own scope are counted only (no titles)."""
    mod = _load_local_sessions()
    rows = mod.scan(root, start.isoformat(), end.isoformat())
    handoffs = set() if all('has_handoff' in r for r in rows) else handoff_session_ids(root, start, end, mod)
    out = [session_row(r, company, handoffs) for r in rows]
    out.sort(key=lambda x: x['started_at'])
    return out

@source('meetings')
def meetings(company, since):
    data = jrun(['hq', 'meetings', 'list', '--company', company, '--limit', '60', '--json'])
    rows = data.get('meetings', data) if isinstance(data, dict) else data
    keep = []
    for m in rows:
        start = m.get('startTime') or m.get('start') or m.get('date') or ''
        if start[:10] >= since:
            keep.append({'id': m.get('id') or m.get('meetingId'), 'title': m.get('title'), 'start': start,
                         'status': m.get('status'), 'participants': m.get('participants') or m.get('participantCount')})
    return keep


# ---------- meeting enrichment (pure helpers tested in test_brief_helpers.py) ----------
def _names(participants):
    """Participant names from `hq meetings get` ([{name, email, role}]), plain
    strings, or a bare count (which carries no names)."""
    out = []
    for p in participants if isinstance(participants, list) else []:
        if isinstance(p, dict):
            n = p.get('name') or p.get('displayName') or p.get('email')
        else:
            n = p
        if isinstance(n, str) and n.strip():
            out.append(n.strip())
    return out


def meeting_detail_fields(detail):
    """participants, end and duration_min from one `hq meetings get` payload.
    `duration` is seconds in the CLI; `durationMin` or start/end are also read."""
    d = detail if isinstance(detail, dict) else {}
    names = _names(d.get('participants') or d.get('attendees'))
    dur = None
    if isinstance(d.get('durationMin'), (int, float)):
        dur = round(d['durationMin'])
    elif isinstance(d.get('duration'), (int, float)):
        dur = round(d['duration'] / 60)
    start, end = _ts(d.get('startTime') or d.get('start')), _ts(d.get('endTime') or d.get('end'))
    if dur is None and start and end:
        dur = round((end - start).total_seconds() / 60)
    if end is None and start and dur is not None:
        end = start + dt.timedelta(minutes=dur)
    return {'participants': names or None, 'end': end.isoformat() if end else None,
            'duration_min': dur}


def attended(meeting, signals, me_names):
    """True when the person is in the participants, named in the title, or owns
    one of the meeting's decisions or action items."""
    for n in _names(meeting.get('participants')):
        if is_mine(n, me_names):
            return True
    title = meeting.get('title') or ''
    for n in me_names or ():
        parts = n.split()
        if parts and re.search(r'(?<![\w])' + re.escape(parts[0]) + r'(?![\w])', title, re.I):
            return True
    for sig in signals or ():
        for key in ('decisions', 'action_items'):
            if any(x.get('mine') for x in sig.get(key) or [] if isinstance(x, dict)):
                return True
    return False


def _meeting_key(m):
    return (re.sub(r'\s+', ' ', (m.get('title') or '').strip().lower()), (m.get('start') or '')[:19])


def dedupe_meetings(rows, signals_by_id=None):
    """Collapse rows that share title+start (the recorder sometimes stores one
    call twice). The row with the most signals wins; the others' ids are kept in
    `duplicate_ids` so their signals still map back to the meeting."""
    signals_by_id = signals_by_id or {}

    def weight(m):
        s = signals_by_id.get(m.get('id')) or {}
        return sum(v for v in (s.get('counts') or {}).values() if isinstance(v, int))

    kept = {}
    order = []
    for m in rows or []:
        k = _meeting_key(m)
        if k not in kept:
            kept[k] = dict(m)
            kept[k].setdefault('duplicate_ids', [])
            order.append(k)
            continue
        cur = kept[k]
        if weight(m) > weight(cur):
            dups = cur['duplicate_ids'] + [cur['id']]
            kept[k] = dict(m)
            kept[k]['duplicate_ids'] = dups
        else:
            cur['duplicate_ids'].append(m.get('id'))
    return [kept[k] for k in order]


def in_window(start, lo, hi):
    """True when the ISO `start` falls inside [lo, hi] (timezone-aware)."""
    t = _ts(start)
    return bool(t) and lo <= t <= hi


def enrich_meetings(rows, signals, me_names, lo, hi):
    """meetings[] for brief-data.json: participants, end and duration_min from the
    `hq meetings get` details the signals step already fetched, `attended`, only
    meetings whose start is inside [lo, hi] (the session window, or the catch-up
    gap), deduped by title+start."""
    by_id = {s.get('meeting_id'): s for s in signals or [] if isinstance(s, dict) and s.get('meeting_id')}
    out = []
    for m in rows or []:
        if not in_window(m.get('start'), lo, hi):
            continue
        sig = by_id.get(m.get('id')) or {}
        row = dict(m)
        det = sig.get('detail') or {}
        if det.get('participants'):
            row['participants'] = det['participants']
        elif not isinstance(row.get('participants'), list):
            row['participants'] = _names(row.get('participants')) or None
        row['end'] = det.get('end')
        row['duration_min'] = det.get('duration_min')
        out.append(row)
    out = dedupe_meetings(out, by_id)
    for row in out:
        sigs = [by_id[i] for i in [row.get('id')] + row.get('duplicate_ids', []) if i in by_id]
        row['attended'] = attended(row, sigs, me_names)
    return out

# ---------- meeting signal text (pure helpers tested in test_brief_helpers.py) ----------
SIGNAL_TEXT_TYPES = ('decision', 'action_item')
SIGNALS_PER_TYPE = 5
SIGNAL_TEXT_CHARS = 240
BODY_FETCH_TIMEOUT_S = 8
BODY_BUDGET_S = 20          # per meeting, all bodies together


def _frontmatter(md):
    """Flat `key: value` pairs from a leading YAML block (no nested lists)."""
    fm = {}
    if not md.startswith('---'):
        return fm
    end = md.find('\n---', 3)
    for line in md[3:end if end > 0 else 0].splitlines():
        m = re.match(r'^([A-Za-z_][\w-]*):\s*(.*)$', line)
        if m and m.group(2).strip():
            fm[m.group(1)] = m.group(2).strip().strip('"\'')
    return fm


def infer_owner(text):
    """'Sam Rivera to build X' or 'Sam Rivera decided to X' -> 'Sam Rivera'.
    None when no clear owner."""
    m = re.match(r"^\s*([A-Z][\w'.-]+(?:\s+[A-Z][\w'.-]+){0,2})\s+(?:to|will|should|must|owns|is to|decided|agreed to)\s",
                 text or '')
    if not m or m.group(1).lower() in ('the', 'we', 'team', 'everyone', 'they'):
        return None
    return m.group(1)


def parse_signal_md(md, me_names=()):
    """Signal markdown -> {text, owner, mine}. Uses canonical_content (a summary)
    or the first heading. Citations and transcript text are never returned."""
    fm = _frontmatter(md or '')
    text = fm.get('canonical_content') or fm.get('title') or ''
    if not text:
        h = re.search(r'^#+\s*(?:[\w ]+:\s*)?(.+)$', md or '', re.M)
        text = h.group(1).strip() if h else ''
    text = re.sub(r'\s+', ' ', text).strip()[:SIGNAL_TEXT_CHARS]
    owner = fm.get('owner') or fm.get('assignee') or fm.get('assigned_to') or infer_owner(text)
    return {'text': text, 'owner': owner, 'mine': is_mine(owner, me_names)}


def is_mine(owner, me_names):
    """True when the owner names the user (full name, first name or person slug)."""
    if not owner:
        return False
    o = re.sub(r'[^a-z ]', ' ', owner.lower().replace('person/', '').replace('-', ' ')).split()
    for n in me_names or ():
        parts = re.sub(r'[^a-z ]', ' ', n.lower().replace('-', ' ')).split()
        if parts and (o == parts or o == parts[:1] or o[:len(parts)] == parts):
            return True
    return False


def signal_entry_text(entry, fetch, me_names=()):
    """One signals[] entry -> {text, owner, mine} or None. Inline title/text wins;
    otherwise read the signal body through its presigned URL with `fetch`."""
    if not isinstance(entry, dict):
        return None
    inline = entry.get('title') or entry.get('text') or entry.get('canonical_content')
    if inline:
        owner = entry.get('owner') or entry.get('assignee') or infer_owner(inline)
        return {'text': re.sub(r'\s+', ' ', inline).strip()[:SIGNAL_TEXT_CHARS], 'owner': owner,
                'mine': is_mine(owner, me_names)}
    url = entry.get('presigned_url') or entry.get('url')
    if not url or not str(url).startswith('https://'):
        return None
    r = parse_signal_md(fetch(url), me_names)
    return r if r['text'] else None


def _fetch_body(url):
    import urllib.request
    with urllib.request.urlopen(url, timeout=BODY_FETCH_TIMEOUT_S) as resp:
        return resp.read(64 * 1024).decode('utf-8', 'replace')


@source('meeting_signals')
def meeting_signals(company, mtgs, on_progress=None, me_names=()):
    # One `hq meetings get` per meeting takes seconds each; fetch in parallel and
    # report each completion so the app's counters keep moving during this step.
    # Up to 5 decisions and 5 action items per meeting carry their text (from the
    # signal summary, never the transcript); presigned URLs are never stored.
    todo = [m for m in mtgs or [] if m.get('id')]

    def texts(sig):
        import time
        deadline = time.monotonic() + BODY_BUDGET_S
        out = {t: [] for t in SIGNAL_TEXT_TYPES}
        jobs = [(t, e) for t in SIGNAL_TEXT_TYPES for e in (sig.get(t) or sig.get(t + 's') or [])[:SIGNALS_PER_TYPE]]
        with ThreadPoolExecutor(max_workers=5) as ex:
            futs = [(t, ex.submit(signal_entry_text, e, _fetch_body, me_names)) for t, e in jobs]
            for t, f in futs:
                try:
                    r = f.result(timeout=max(0.1, deadline - time.monotonic()))
                except Exception:
                    continue
                if r:
                    out[t].append(r)
        return out

    def one(m):
        try:
            d = jrun(['hq', 'meetings', 'get', m['id'], '--company', company, '--json'], timeout=60)
        except Exception as e:
            return {'meeting': m['title'], **failure('meeting', e)}
        sig = d.get('signals') or {}
        t = texts(sig)
        return {'meeting': m['title'], 'meeting_id': m['id'], 'start': m['start'],
                'counts': {k: len(v) for k, v in sig.items() if isinstance(v, list)},
                'decisions': t['decision'], 'action_items': t['action_item'],
                # participants, end and duration for meetings[] (no second `get`)
                'detail': meeting_detail_fields(d)}

    out = [None] * len(todo)
    with ThreadPoolExecutor(max_workers=6) as ex:
        futs = {ex.submit(one, m): i for i, m in enumerate(todo)}
        for n, f in enumerate(as_completed(futs), 1):
            out[futs[f]] = f.result()
            if on_progress:
                on_progress(n, len(todo), [x for x in out if x])
    return out

@source('signals_alltime')
def signals(company):
    out = {}
    for t in ['decision', 'action_item', 'risk', 'commitment', 'key_point']:
        try:
            d = jrun(['hq', 'signals', 'list', '--entity', company, '--type', t, '--limit', '25', '--format', 'json'])
            out[t] = d.get('entries', d) if isinstance(d, dict) else d
        except Exception as e:
            out[t] = failure(t.replace('_', ' ') + ' signals', e)
    return out

DM_LIMIT = 40
# A DM that asks the person for something. The writer confirms every flag by
# reading the preview; the regex only narrows the list.
_NEED_YOU = re.compile(r"\?|\bcan you\b|\bcould you\b|\bplease\b|\bneed you\b|\bneed your\b|\bwaiting on\b|\bwaiting for you\b", re.I)


def need_you(text):
    """True when the message looks like an ask ('?', 'can you', 'please', 'need you', 'waiting on')."""
    return bool(_NEED_YOU.search(text or ''))


def dm_row(m):
    """One inbox message -> brief-data dms[] row. Body text is cut to a preview.
    `direction` and `thread_id` are null until `hq dm inbox` exposes them."""
    uid = m.get('fromPersonUid')
    preview = (m.get('body') or m.get('text') or '')[:280]
    raw_channel = m.get('channel')
    if isinstance(raw_channel, str) and raw_channel.strip():
        channel = raw_channel
    elif isinstance(raw_channel, dict):
        channel = raw_channel.get('name') or raw_channel.get('channelName')
    else:
        channel = m.get('channelName')
    return {'from': m.get('fromDisplayName') or m.get('fromEmail') or uid, 'from_uid': uid,
            'is_agent': str(uid or '').startswith('agt_'),
            'at': m.get('createdAt') or m.get('sentAt'),
            'preview': preview, 'need_you': need_you(preview),
            'channel': channel,
            'direction': m.get('direction'),
            'thread_id': m.get('threadId') or m.get('thread_id')}


def message_company(message):
    """Company slug on one inbox message, or None when the message is personal.

    The inbox command does not take a company. The slug is read from the message
    (`company`, `companySlug`, `company_slug`) or from a channel object. A blank
    slug and the tag `personal` are personal. `companyUid` is not a slug."""
    if not isinstance(message, dict):
        return None
    sources = [message]
    channel = message.get('channel')
    if isinstance(channel, dict):
        sources.append(channel)
    for src in sources:
        for key in COMPANY_TAG_KEYS:
            value = src.get(key)
            if isinstance(value, str) and value.strip():
                slug = value.strip()
                return None if slug.lower() == 'personal' else slug
    return None


def has_company_tag(message):
    """True when this inbox item has a company slug field, even if the value is blank.

    A present key means the inbox can tag companies. `companyUid` does not count:
    it is an id, and a page that only has that id still cannot be filtered."""
    if not isinstance(message, dict):
        return False
    blobs = [message]
    channel = message.get('channel')
    if isinstance(channel, dict):
        blobs.append(channel)
    return any(key in blob for blob in blobs for key in COMPANY_TAG_KEYS)


def inbox_lacks_company_tag(rows):
    """True when the page has messages and none of them carry a company slug field.

    An empty page is not this case: there is nothing to tag, so an empty result
    is honest. A page that tags even one message can be filtered."""
    items = [m for m in rows or [] if isinstance(m, dict)]
    return bool(items) and not any(has_company_tag(m) for m in items)


def scope_dms(rows, company):
    """dms[] rows that belong in this brief.

    A company brief keeps only that company's messages, so another company's
    text never becomes a preview. A personal brief keeps only personal messages.
    """
    out = []
    for message in rows or []:
        if not isinstance(message, dict):
            continue
        slug = message_company(message)
        if company:
            if slug != company:
                continue
        elif slug is not None:
            continue
        out.append(dm_row(message))
    return out


def inbox_rows(payload):
    """The message list from `hq dm inbox --json` (a list, or messages/items/events)."""
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in ('messages', 'items', 'events'):
            rows = payload.get(key)
            if isinstance(rows, list):
                return rows
    raise RuntimeError('inbox JSON was not a list of messages')


def dm_truncation(rows, limit, sessions_from):
    """Inbox truncation note for sources.dms: the inbox returned a full page and
    its oldest message is still inside the window, so older DMs were cut off."""
    ats = [r.get('at') for r in rows or [] if r.get('at')]
    oldest = min(ats) if ats else None
    t = _ts(oldest) if oldest else None
    truncated = bool(rows) and len(rows) >= limit and t is not None and t > sessions_from
    note = None
    if truncated:
        note = f'Inbox cut at {limit} messages; DMs before {oldest[:16]}Z are not in this brief.'
    return {'limit': limit, 'oldest': oldest, 'truncated': truncated, 'note': note,
            'need_you': sum(1 for r in rows or [] if r.get('need_you'))}


@source('dms')
def dms(company):
    """Inbox messages for this brief only.

    `hq dm inbox` has no company flag. When messages carry a company slug,
    out-of-scope rows are dropped and never written. When a company brief's
    page has messages and none carry that field, the source is skipped with
    `inbox has no company tag` instead of an empty success. A personal brief
    still keeps messages with no company. An empty page stays an empty result.
    """
    payload = jrun(['hq', 'dm', 'inbox', '--limit', str(DM_LIMIT), '--json'])
    rows = inbox_rows(payload)
    if company and inbox_lacks_company_tag(rows):
        raise SourceSkipped(INBOX_NO_COMPANY_TAG)
    return scope_dms(rows, company)


# ---------- fleet (pure helpers tested in test_brief_helpers.py) ----------
STUCK_STATUSES = {'provisioning', 'error', 'failed', 'unhealthy', 'stuck', 'degraded'}
STUCK_PHASES = {'failed', 'waiting', 'error', 'stuck'}


def agent_row(a):
    return {'name': a.get('name'), 'status': a.get('agentStatus') or a.get('status'),
            'phase': a.get('setupPhase') or a.get('phase'),
            'runtime': a.get('runtimeKind') or a.get('runtime'),
            'since': a.get('stuckSince') or a.get('statusChangedAt') or a.get('updatedAt') or a.get('since')}


def is_stuck(agent):
    """An agent that cannot work: setup failed or waiting, or a status that is
    not a resting one. Dormant and idle agents are not stuck."""
    st = str(agent.get('status') or '').lower()
    ph = str(agent.get('phase') or '').lower()
    return ph in STUCK_PHASES or st in STUCK_STATUSES


def stuck_agents(agents):
    return [{'name': a.get('name'), 'status': a.get('status'), 'phase': a.get('phase'), 'since': a.get('since')}
            for a in agents or [] if is_stuck(a)]


def fleet_delta(current_stuck, previous_fleet, previous_at=None):
    """Delta by agent name against the previous run's fleet block, and `since`
    carried forward for agents that were already stuck then (the earliest known
    sighting, or the previous run's time when it recorded none)."""
    prev = previous_fleet or {}
    prev_stuck = prev.get('stuck')
    if prev_stuck is None:
        prev_stuck = stuck_agents(prev.get('agents') or [])
    prev_by = {s.get('name'): s for s in prev_stuck if s.get('name')}
    now_names = {s.get('name') for s in current_stuck if s.get('name')}
    for s in current_stuck:
        p = prev_by.get(s.get('name'))
        if p is None:
            continue
        cands = [x for x in (s.get('since'), p.get('since'), previous_at) if x]
        s['since'] = min(cands) if cands else None
    return {'newly_stuck': sorted(now_names - set(prev_by)),
            'still_stuck': sorted(now_names & set(prev_by)),
            'recovered': sorted(set(prev_by) - now_names)}


def fleet_series(prior_runs):
    """One bucket per prior ready run: {generated_at, stuck}. `prior_runs` is
    [(generated_at, fleet_block)]; runs without a fleet block are skipped."""
    out = []
    for at, fl in prior_runs or []:
        if not isinstance(fl, dict):
            continue
        stuck = fl.get('stuck')
        n = len(stuck) if isinstance(stuck, list) else len(stuck_agents(fl.get('agents') or []))
        out.append({'generated_at': at, 'stuck': n})
    out.sort(key=lambda b: b['generated_at'] or '')
    return out


@source('fleet')
def fleet(company):
    d = jrun(['hq', 'agents', 'list', '--company', company, '--json'])
    rows = d.get('agents', d) if isinstance(d, dict) else d
    st = Counter((a.get('agentStatus') or a.get('entityStatus') or 'unknown') for a in rows)
    phase = Counter((a.get('setupPhase') or 'none') for a in rows)
    agents = [agent_row(a) for a in rows]
    return {'total': len(rows), 'by_status': dict(st), 'by_setup_phase': dict(phase),
            'agents': agents, 'stuck': stuck_agents(agents)}

_SIBLINGS = {}


def _sibling(name):
    """Load a helper module that sits next to this script (cached)."""
    if name not in _SIBLINGS:
        import importlib.util
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + '.py')
        spec = importlib.util.spec_from_file_location(name, path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _SIBLINGS[name] = mod
    return _SIBLINGS[name]


def _product_for(repo):
    try:
        return _sibling('brief_rank').product_for(repo)
    except Exception:
        return None


PR_FIELDS = 'number,title,repository,state,createdAt,closedAt,isDraft,url,author'
REVIEW_META_MAX = 20        # open PRs enriched with gh pr view
REVIEW_META_BUDGET_S = 20   # all of them together
_NO_DATE = '0001-01-01'


def _ts(s):
    """Aware datetime from an ISO string; None for empty, placeholder or bad values."""
    if not s or str(s).startswith(_NO_DATE):
        return None
    try:
        t = dt.datetime.fromisoformat(str(s).replace('Z', '+00:00'))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


def merge_hours(created, closed):
    """Hours from created to closed, one decimal; None when either is missing."""
    a, b = _ts(created), _ts(closed)
    if not a or not b:
        return None
    return round(max(0.0, (b - a).total_seconds() / 3600), 1)


def pr_row(p, authored_by_me, review_requested):
    """One gh search row -> brief-data prs[] row. `closed` is null on open rows
    (gh prints 0001-01-01 there), `isDraft` is kept, `merge_hours` is set on
    merged rows, and `reviewDecision`/`reviewers` start null until enriched."""
    repo = p['repository']['name']
    repo_full = p['repository'].get('nameWithOwner') or None
    state = p.get('state')
    closed = p.get('closedAt') if state != 'open' and _ts(p.get('closedAt')) else None
    return {'repo': repo, 'repo_full': repo_full, 'product': _product_for(repo),
            'number': p['number'], 'title': p['title'],
            'state': state, 'created': p.get('createdAt'), 'closed': closed, 'url': p['url'],
            'isDraft': bool(p.get('isDraft')),
            'author': (p.get('author') or {}).get('login'), 'authored_by_me': authored_by_me,
            'review_requested': review_requested, 'reviewRequests': ['@me'] if review_requested else [],
            'reviewDecision': None, 'reviewers': [],
            'merge_hours': merge_hours(p.get('createdAt'), closed) if state == 'merged' else None,
            'is_release': bool(re.match(r'(?i)^\s*(release|chore\(release\))\b', p['title'] or ''))}


def apply_review_meta(rows, meta_by_url):
    """Merge `gh pr view --json reviewDecision,reviewRequests` payloads (keyed by
    PR url) onto rows. Missing or failed payloads leave the row unchanged."""
    for r in rows or []:
        m = meta_by_url.get(r.get('url'))
        if not isinstance(m, dict):
            continue
        r['reviewDecision'] = m.get('reviewDecision') or None
        logins = []
        for x in m.get('reviewRequests') or []:
            if isinstance(x, dict):
                n = x.get('login') or x.get('name') or x.get('slug')
            else:
                n = x
            if n:
                logins.append(str(n))
        r['reviewers'] = logins
        if 'isDraft' in m:
            r['isDraft'] = bool(m['isDraft'])
    return rows


def _review_meta(rows):
    """Bounded enrichment: one `gh pr view` per open row, at most REVIEW_META_MAX
    rows and REVIEW_META_BUDGET_S seconds together. Returns {url: payload}."""
    import time
    urls = [r['url'] for r in rows if r.get('state') == 'open' and r.get('url')][:REVIEW_META_MAX]
    out = {}
    if not urls:
        return out
    deadline = time.monotonic() + REVIEW_META_BUDGET_S

    def one(u):
        return jrun(['gh', 'pr', 'view', u, '--json', 'reviewDecision,reviewRequests,isDraft'], timeout=15)

    with ThreadPoolExecutor(max_workers=5) as ex:
        futs = {ex.submit(one, u): u for u in urls}
        for f in futs:
            try:
                out[futs[f]] = f.result(timeout=max(0.1, deadline - time.monotonic()))
            except Exception:
                continue
    return out


@source('prs')
def prs(org, since):
    """The user's PRs (author) plus open PRs where the user is a requested reviewer.
    Read-only gh search, across every owner unless `org` is set. `author` is the login; `review_requested` marks the
    PRs that came from the review-request search (gh search has no reviewRequests
    field, so the search itself is the evidence). Open rows are then enriched
    with reviewDecision and reviewers through a bounded `gh pr view`."""
    owner = ['--owner', org] if org else []
    mine = jrun(['gh', 'search', 'prs', '--author', '@me', *owner, '--updated', f'>={since}',
                 '--limit', '1000', '--json', PR_FIELDS])
    try:
        asked = jrun(['gh', 'search', 'prs', '--review-requested', '@me', *owner, '--state', 'open',
                      '--limit', '200', '--json', PR_FIELDS])
    except Exception as e:
        print(f'[sweep] review-requested search failed: {e}', file=sys.stderr)
        asked = []
    out, seen = [], {}
    for p, is_mine_, asked_ in [(p, True, False) for p in mine] + [(p, False, True) for p in asked]:
        k = (p['repository'].get('nameWithOwner') or p['repository']['name'], p['number'])
        if k in seen:
            seen[k]['review_requested'] = seen[k]['review_requested'] or asked_
            if asked_:
                seen[k]['reviewRequests'] = ['@me']
            continue
        row = pr_row(p, is_mine_, asked_)
        seen[k] = row
        out.append(row)
    try:
        apply_review_meta(out, _review_meta(out))
    except Exception as e:
        print(f'[sweep] review meta failed: {e}', file=sys.stderr)
    return out


def scope_prs(rows, company, owners):
    """(kept rows, count dropped). Rows whose repo owner belongs to another
    company (any company on a personal brief) are dropped, so their titles and
    repos never reach brief-data.json. Rows with no owner are kept."""
    is_in = _sibling('housekeeping').owner_in_scope
    kept = [r for r in rows or [] if is_in((r.get('repo_full') or '').split('/', 1)[0] if r.get('repo_full') else None,
                                          company, owners)]
    return kept, len(rows or []) - len(kept)


def _median(xs):
    xs = sorted(x for x in xs if isinstance(x, (int, float)))
    if not xs:
        return None
    n = len(xs)
    mid = n // 2
    return round(xs[mid] if n % 2 else (xs[mid - 1] + xs[mid]) / 2, 1)


def _in(p, field, start, end):
    t = _ts(p.get(field))
    return t is not None and start <= t <= end


def pr_summary(rows, start, end):
    """Counts for the brief window, from the user's own PRs only.
    merged = merged with closedAt in [start, end]; opened = created in the window;
    open = still open now. The app's loader and the writer both read this.
    Also median_merge_hours over the merged rows and the same counts by product."""
    own = [p for p in rows or [] if p.get('authored_by_me', True)]
    merged_rows = [p for p in own if p.get('state') == 'merged' and _in(p, 'closed', start, end)]
    opened_rows = [p for p in own if _in(p, 'created', start, end)]
    open_rows = [p for p in own if p.get('state') == 'open']
    review = sum(1 for p in rows or [] if p.get('review_requested') and p.get('state') == 'open')
    hours = lambda ps: [p.get('merge_hours') if p.get('merge_hours') is not None
                        else merge_hours(p.get('created'), p.get('closed')) for p in ps]
    by_product = {}
    for key, ps in (('merged', merged_rows), ('opened', opened_rows), ('open', open_rows)):
        for p in ps:
            prod = p.get('product') or _product_for(p.get('repo')) or 'Other'
            b = by_product.setdefault(prod, {'product': prod, 'merged': 0, 'opened': 0, 'open': 0, 'median_merge_hours': None})
            b[key] += 1
    for prod, b in by_product.items():
        b['median_merge_hours'] = _median(hours([p for p in merged_rows if (p.get('product') or _product_for(p.get('repo')) or 'Other') == prod]))
    return {'merged': len(merged_rows), 'opened': len(opened_rows), 'open': len(open_rows), 'review_requested': review,
            'median_merge_hours': _median(hours(merged_rows)),
            'by_product': sorted(by_product.values(), key=lambda b: (-b['merged'], -b['opened'], b['product']))}


# ---------- releases (pure helper tested in test_brief_helpers.py) ----------
_RELEASE_VERSION = re.compile(r'(?i)release\s+v?(\d+\.\d+\.\d+)')
_THEME_WORDS = {'fix': 'fixes', 'feat': 'features', 'chore': 'maintenance', 'docs': 'docs', 'refactor': 'cleanup',
                'perf': 'speed', 'test': 'tests', 'ci': 'build checks', 'build': 'build', 'style': 'style', 'revert': 'reverts'}


def pr_theme(titles):
    """One plain word for a group of PR titles: the most common commit scope
    ('onboarding'), else the most common type ('fixes'), else 'changes'."""
    scopes, types = Counter(), Counter()
    for t in titles or []:
        m = re.match(r'^\s*([a-z]+)(?:\(([^)]*)\))?!?:', t or '', re.I)
        if not m:
            continue
        types[m.group(1).lower()] += 1
        if m.group(2):
            scopes[m.group(2).strip().lower().replace('-', ' ').replace('_', ' ')] += 1
    if scopes:
        return scopes.most_common(1)[0][0]
    if types:
        k = types.most_common(1)[0][0]
        return _THEME_WORDS.get(k, k)
    return 'changes'


def releases(rows):
    """One row per repo that has a merged Release PR: the latest release and the
    merged PRs that landed after it (pending for the next release), by local day."""
    by_repo = defaultdict(list)
    for p in rows or []:
        if p.get('repo'):
            by_repo[p['repo']].append(p)
    out = []
    for repo, ps in sorted(by_repo.items()):
        rel = [p for p in ps if p.get('is_release') and p.get('state') == 'merged' and _ts(p.get('closed'))]
        if not rel:
            continue
        latest = max(rel, key=lambda p: _ts(p['closed']))
        at = _ts(latest['closed'])
        m = _RELEASE_VERSION.search(latest.get('title') or '')
        pending = [p for p in ps if p.get('state') == 'merged' and not p.get('is_release')
                   and _ts(p.get('closed')) and _ts(p['closed']) > at]
        by_day = defaultdict(list)
        for p in pending:
            by_day[_ts(p['closed']).astimezone().date().isoformat()].append(p.get('title'))
        out.append({'product': latest.get('product') or _product_for(repo), 'repo': repo,
                    'version': m.group(1) if m else None, 'merged_at': latest['closed'], 'url': latest.get('url'),
                    'pending_count': len(pending),
                    'pending_by_day': [{'day': d, 'count': len(ts), 'theme': pr_theme(ts)} for d, ts in sorted(by_day.items())]})
    return out


# ---------- main-branch health (pure helpers tested in test_brief_helpers.py) ----------
RED = ('failure', 'timed_out')


def red_workflows(runs):
    """Red workflows from a newest-first `gh run list`: those whose latest finished
    run failed, with `since` = createdAt of the oldest run in that red streak
    (runs still in progress are skipped, not counted as green)."""
    by_name = defaultdict(list)
    for x in runs or []:
        if x.get('name'):
            by_name[x['name']].append(x)
    out = []
    for name, xs in by_name.items():
        done = [x for x in xs if x.get('conclusion')]
        if not done or done[0].get('conclusion') not in RED:
            continue
        since = None
        for x in done:
            if x.get('conclusion') in RED:
                since = x.get('createdAt') or since
            else:
                break
        out.append({'workflow': name, 'since': since, 'merges_on_top': None})
    return out


def merges_on_top(prs_rows, repo, since):
    """Merged PRs in `repo` closed after `since` (from the sweep's PR list, so the
    user's own merges: a lower bound). None when `since` is unknown."""
    t = _ts(since)
    if t is None:
        return None
    return sum(1 for p in prs_rows or [] if p.get('repo') == repo and p.get('state') == 'merged'
               and _ts(p.get('closed')) and _ts(p['closed']) > t)


def red_names(red):
    """Workflow names from a red list in either shape (strings or objects)."""
    return [r.get('workflow') if isinstance(r, dict) else r for r in red or [] if r]


def main_health_delta(current, previous):
    """Per repo: {newly_red, still_red, recovered} against the previous run's
    main_health, and `since` carried back to the previous run's earlier value
    for workflows that were already red. Repos with errors are left alone."""
    for repo, cur in (current or {}).items():
        if not isinstance(cur, dict) or 'red' not in cur:
            continue
        prev = (previous or {}).get(repo) if isinstance(previous, dict) else None
        if not isinstance(prev, dict) or 'red' not in prev:
            cur['delta'] = None
            continue
        now_names = set(red_names(cur['red']))
        prev_names = set(red_names(prev['red']))
        prev_since = {r['workflow']: r.get('since') for r in prev['red'] if isinstance(r, dict)}
        for r in cur['red']:
            if isinstance(r, dict) and r['workflow'] in prev_names:
                cands = [x for x in (r.get('since'), prev_since.get(r['workflow'])) if x]
                r['since'] = min(cands) if cands else None
        cur['delta'] = {'newly_red': sorted(now_names - prev_names), 'still_red': sorted(now_names & prev_names),
                        'recovered': sorted(prev_names - now_names)}
    return current


HEALTH_REPOS_MAX = 8


def health_repos(explicit, org, prs_rows, cap=HEALTH_REPOS_MAX):
    """(short, full) pairs for main_health, where full is the owner-qualified
    repo name. `explicit` is the --repos list: a qualified name is used as given,
    a bare name takes --org when set, otherwise its owner comes from the PR rows
    (bare names that resolve nowhere are dropped). With no --repos, the repos of
    the person's own PRs in the window, most PRs first, at most `cap`."""
    full_by_short, counts = {}, {}
    for p in prs_rows or []:
        full = p.get('repo_full')
        if not full or '/' not in full:
            continue
        full_by_short.setdefault(p.get('repo') or full.split('/', 1)[1], full)
        if p.get('authored_by_me'):
            counts[full] = counts.get(full, 0) + 1
    if explicit:
        picked = []
        for r in explicit:
            r = r.strip()
            if not r:
                continue
            full = r if '/' in r else (f'{org}/{r}' if org else full_by_short.get(r))
            if full:
                picked.append(full)
    else:
        picked = [full for full, _ in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))]
    out, seen = [], set()
    for full in picked:
        if full not in seen:
            seen.add(full)
            out.append((full.split('/', 1)[1], full))
    return out[:cap]


@source('main_health')
def main_health(repos, prs_rows=None):
    """Red workflows on main for each (short, full) pair, keyed by short name."""
    out = {}
    for r, full in repos:
        try:
            d = jrun(['gh', 'run', 'list', '-R', full, '--branch', 'main', '--limit', '15',
                      '--json', 'name,conclusion,status,createdAt,headSha'])
            latest = {}
            for x in d:
                latest.setdefault(x['name'], x)
            red = red_workflows(d)
            for w in red:
                w['merges_on_top'] = merges_on_top(prs_rows, r, w['since'])
            out[r] = {'workflows': len(latest), 'product': _product_for(r), 'red': red}
        except Exception as e:
            out[r] = failure(f'{r} build status', e)
    return out


# ---------- previous runs (pure helpers tested in test_brief_helpers.py) ----------
ANY_COMPANY = object()


def ready_runs(index_path, exclude_run_id=None, company=ANY_COMPANY):
    """`ready` lines of workspace/brief/index.jsonl, oldest first, without the
    current run. Unreadable lines are skipped; a missing file is an empty list.
    With `company` (None = personal briefs), a line whose `company` field names
    another company is left out. Lines with no `company` field (older runs) stay;
    load_prior_data checks their brief-data.json."""
    out = []
    try:
        with open(index_path, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict) and row.get('state') == 'ready' and row.get('run_id') \
                        and row.get('run_id') != exclude_run_id \
                        and (company is ANY_COMPANY or 'company' not in row or row.get('company') == company):
                    out.append(row)
    except OSError:
        return []
    out.sort(key=lambda r: (r.get('created_at') or '', r.get('run_id') or ''))
    return out


def load_prior_data(brief_dir, runs, limit=14, company=ANY_COMPANY):
    """[(run_id, generated_at, brief-data dict)] for the newest `limit` ready runs
    whose files can be read, oldest first. At most 14 candidate files are opened. With `company`
    (None = personal briefs), runs whose brief-data.json belongs to another
    company are skipped, so deltas never compare two companies."""
    out = []
    for r in reversed(runs[-14:]):
        if len(out) >= limit:
            break
        p = os.path.join(brief_dir, r['run_id'], 'brief-data.json')
        try:
            with open(p, encoding='utf-8') as f:
                d = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(d, dict) or (company is not ANY_COMPANY and d.get('company') != company):
            continue
        out.append((r['run_id'], d.get('generated_at') or r.get('finished_at') or r.get('created_at'), d))
    return out[::-1]

# ---------- live status ----------
def _now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')

class Status:
    """Merges live progress into the run's status.json so the app can animate it."""
    def __init__(self, path, company, window=None):
        self.path, self.company, self.window = path, company, window

    def _write(self, fn):
        if not self.path:
            return
        try:
            s = json.load(open(self.path)) if os.path.exists(self.path) else {}
        except Exception:
            s = {}
        s.setdefault('state', 'running')
        s.setdefault('activity', []); s.setdefault('samples', [])
        s.setdefault('findings', {}); s.setdefault('sources', {})
        fn(s)
        s['activity'] = s['activity'][-12:]
        s['samples'] = s['samples'][-8:]
        s['updated_at'] = _now()
        tmp = self.path + '.tmp'
        with open(tmp, 'w') as f:
            json.dump(s, f, default=str)
        os.replace(tmp, self.path)

    def start(self, label, progress):
        def f(s):
            s['step'] = 'Sweeping your day'
            s['progress'] = round(progress, 3)
            s['activity'].append({'at': _now(), 'label': label, 'state': 'running'})
        self._write(f)

    def tick(self, detail, progress, findings_fn=None):
        """Mid-step update: moves the bar and the running activity's detail."""
        def f(s):
            s['progress'] = round(progress, 3)
            if s['activity']:
                s['activity'][-1]['detail'] = detail
            if findings_fn:
                findings_fn(s['findings'])
        self._write(f)

    def finish(self, key, value, src, progress):
        def f(s):
            s['progress'] = round(progress, 3)
            s['sources'][key] = src
            act = s['activity'][-1] if s['activity'] else {}
            if src.get('state') == 'skipped':
                # Not a failure and not "no messages": the activity says it was left out, and why.
                reason = (src.get('skipped_reason') or '')[:80]
                label = 'Skipped DMs' if key == 'dms' else f"Skipped {key.replace('_', ' ')}"
                act.update({'at': _now(), 'label': label, 'state': 'skipped', 'detail': reason})
                return
            ok = src.get('ok', False)
            label, detail = summarize(key, value, self.company, s['findings'], s['samples'], self.window)
            act.update({'at': _now(), 'label': label if ok else act.get('label', key),
                        'state': 'done' if ok else 'failed',
                        'detail': detail if ok else (src.get('note') or plain_note(key))[:80]})
        self._write(f)

def summarize(key, v, company, findings, samples, window=None):
    """Plain label + findings counts + company-only samples for one source.
    `window` is (start, end) datetimes; PR counts use it so the loader shows the
    same numbers as brief-data.json's prs_summary and the brief."""
    if v is None:
        return key, ''
    if key == 'sessions':
        own = own_tag(company)
        mine = [x for x in v if x.get('company') == own and x.get('kind', 'you') == 'you']
        runs = [x for x in v if x.get('company') == own and x.get('kind') in ('agent', 'lane')]
        findings['sessions'] = len(mine)
        bits = [f'{len(runs)} agent runs'] if runs else []
        bits.append(f'{len(v) - len(mine) - len(runs)} elsewhere, counted only')
        return f'Read {len(mine)} work sessions', ', '.join(bits)
    if key == 'meetings':
        findings['meetings'] = len(v)
        for m in v[-2:]:
            samples.append({'kind': 'meeting', 'title': (m.get('title') or 'Meeting')[:70], 'company': company, 'at': m.get('start')})
        return f'Found {len(v)} meetings', ''
    if key == 'meeting_signals':
        tot = Counter()
        for m in v:
            tot.update(m.get('counts') or {})
        sig = findings.setdefault('signals', {})
        for t in ('decision', 'action_item', 'risk', 'commitment', 'key_point'):
            sig[t] = tot.get(t, 0) + tot.get(t + 's', 0)
        n = sum(sig.values())
        return f'Pulled {n} signals from meetings', ', '.join(f"{c} {t.replace('_', ' ')}s" for t, c in sig.items() if c)
    if key == 'dms':
        people = Counter(m.get('from') for m in v if m.get('from'))
        asks = sum(1 for m in v if m.get('need_you') and not m.get('is_agent'))
        findings['dms'] = {'total': len(v), 'need_you': asks}
        for name, c in people.most_common(2):
            samples.append({'kind': 'dm', 'title': f'{c} messages from {name}', 'company': company, 'at': _now()})
        return f'Read {len(v)} DMs from {len(people)} people', f'{asks} may need you' if asks else ''
    if key == 'fleet':
        bad = sum(c for st_, c in (v.get('by_status') or {}).items() if st_ not in ('active', 'running', 'ready'))
        findings['agents'] = {'total': v.get('total', 0), 'attention': bad}
        return f"Checked {v.get('total', 0)} agents", f'{bad} need attention' if bad else 'all healthy'
    if key == 'prs':
        far = dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc), dt.datetime(9999, 1, 1, tzinfo=dt.timezone.utc)
        start, end = window or far
        ps = pr_summary(v, start, end)
        findings['prs'] = {'merged': ps['merged'], 'opened': ps['opened'], 'open': ps['open'],
                           'review_requested': ps['review_requested']}
        merged = [p for p in v if p.get('state') == 'merged' and p.get('authored_by_me', True)
                  and p.get('closed') and start <= _ts(p['closed']) <= end]
        for p in merged[:2]:
            samples.append({'kind': 'shipped', 'title': f"{p.get('product') or p['repo']}: {p['title']}"[:80],
                            'company': company, 'at': p.get('closed')})
        detail = f"{ps['opened']} opened, {ps['open']} still open"
        if ps['review_requested']:
            detail += f", {ps['review_requested']} waiting on your review"
        return f"Found {ps['merged']} merged PRs in the last day", detail
    if key == 'main_health':
        red = [r for r, x in v.items() if x.get('red')]
        findings['ci_red'] = len(red)
        for r in red[:1]:
            samples.append({'kind': 'incident', 'title': f'{r} main is red', 'company': company, 'at': _now()})
        return f'Checked {len(v)} main branches', f"{len(red)} red: {', '.join(red)}" if red else 'all green'
    return key, ''

# ---------- welcome edition (pure helpers tested in test_brief_additions.py) ----------
IMPORT_COUNT_KEYS = ('plans', 'commands', 'skills', 'hooks', 'policies', 'agents', 'claude_md',
                     'settings_fragments', 'mcp_servers', 'knowledge_dirs', 'claude_repos', 'conversations')
TOOL_NAMES = {'claude': 'Claude Code', 'codex': 'Codex'}


IMPORT_SESSION_FIELDS = ('total', 'claude', 'codex', 'cursor', 'days_seen', 'first_at', 'last_at')
# welcome.import, in output order. SKILL.md "Import report contract" documents each one.
IMPORT_FIELDS = ('path', 'scanned_at', 'source', 'written_at', *IMPORT_COUNT_KEYS, 'sessions', 'tools', 'projects')
SESSION_ID_ENV = ('CLAUDE_CODE_SESSION_ID', 'CLAUDE_SESSION_ID', 'CODEX_THREAD_ID', 'CODEX_SESSION_ID')
IMPORT_REPORT_MAX_BYTES = 1024 * 1024  # a larger report.json is skipped
IMPORT_REPORT_MAX_DEPTH = 32           # so is one nested deeper than this
# With no harness id for the running session, a transcript written to in the
# last LIVE_SESSION_S seconds may be that session, so it is not past work.
LIVE_SESSION_S = 600
_TOOL_ID = re.compile(r'^[a-z0-9][a-z0-9_-]{0,31}$')
_ISO_TIME = re.compile(r'^\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d{1,9})?)?(?:Z|[+-]\d{2}:?\d{2})?)?$')


def _int(v):
    return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else None


def _iso(v):
    """An ISO date or date-time from the report, else None. Free text never passes."""
    return v if isinstance(v, str) and len(v) <= 40 and _ISO_TIME.match(v) else None


def _tool_id(v):
    return v if isinstance(v, str) and _TOOL_ID.match(v) else None


_IMPORT_STAMP = re.compile(r'^(?:(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z'
                           r'|(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2}))(?:-([1-9]\d{0,3}))?$')


def _import_stamp_key(name):
    """Sort key for a report folder, or None when the name is not a stamp.
    Folders are named by UTC time, as 20261019T150028Z (/import-context) or
    2026-10-19T15-00-28 (the desktop tree step); a second import in the same
    second adds -2, -3, ... and sorts after the base name."""
    m = _IMPORT_STAMP.match(name)
    if not m:
        return None
    parts = [int(g) for g in (m.groups()[:6] if m.group(1) else m.groups()[6:12])]
    try:
        when = dt.datetime(*parts, tzinfo=dt.timezone.utc)
    except ValueError:
        return None
    return (when, int(m.group(13) or 1))


def _report_sessions(rep):
    """The report's sessions block. `sessions` (the desktop tree step) wins; an
    older /import-context report gives only a total, summed from
    categories.conversations[].sessions. counts.conversations counts session
    stores, not sessions, so it is never used here."""
    block = rep.get('sessions') if isinstance(rep.get('sessions'), dict) else None
    out = dict.fromkeys(IMPORT_SESSION_FIELDS)
    if block is not None:
        for k in ('total', 'claude', 'codex', 'cursor', 'days_seen'):
            out[k] = _int(block.get(k))
        for k in ('first_at', 'last_at'):
            out[k] = _iso(block.get(k))
    if out['total'] is None:
        cats = rep.get('categories') if isinstance(rep.get('categories'), dict) else {}
        stores = cats.get('conversations') if isinstance(cats.get('conversations'), list) else []
        found = [_int(c.get('sessions')) for c in stores if isinstance(c, dict)]
        if any(n is not None for n in found):
            out['total'] = sum(n or 0 for n in found)
    return out


def _json_depth_ok(value, limit):
    """False when a parsed JSON value nests arrays or objects deeper than `limit`.
    Iterative, so a deep value cannot exhaust the stack."""
    stack = [(value, 1)]
    while stack:
        v, depth = stack.pop()
        if isinstance(v, (dict, list)):
            if depth > limit:
                return False
            stack.extend((c, depth + 1) for c in (v.values() if isinstance(v, dict) else v))
    return True


def _read_report(folder):
    """The parsed report.json in an import folder, or None. A symlinked folder
    or file is not followed. A file over IMPORT_REPORT_MAX_BYTES, nested deeper
    than IMPORT_REPORT_MAX_DEPTH, or that does not parse to an object is skipped."""
    path = os.path.join(folder, 'report.json')
    try:
        if os.path.islink(folder) or os.path.islink(path) or not os.path.isfile(path):
            return None
        if os.path.getsize(path) > IMPORT_REPORT_MAX_BYTES:
            return None
        fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
        with os.fdopen(fd, 'rb') as f:
            raw = f.read(IMPORT_REPORT_MAX_BYTES + 1)
        if len(raw) > IMPORT_REPORT_MAX_BYTES:
            return None
        # json.loads is linear in the input, and raises RecursionError on very
        # deep nesting; the depth limit is then checked on the parsed value.
        rep = json.loads(raw.decode('utf-8'))
        if not _json_depth_ok(rep, IMPORT_REPORT_MAX_DEPTH):
            return None
    except (OSError, ValueError, RecursionError) as e:
        print(f'[sweep] import report skipped: {path}: {type(e).__name__}', file=sys.stderr)
        return None
    return rep if isinstance(rep, dict) else None


def latest_import(hq_root):
    """welcome.import (IMPORT_FIELDS) from the newest workspace/imports/<stamp>/report.json,
    or None. Never raises: a report that cannot be read is skipped, and any
    other failure gives None, so the brief falls back to direct detection."""
    try:
        return _latest_import(hq_root)
    except Exception as e:
        print(f'[sweep] import report read failed: {e}', file=sys.stderr)
        return None


def _latest_import(hq_root):
    """Reads per-category counts, the sessions block and the tool list.
    `scanned_at` is the folder's UTC time; the report's scan_id is never
    copied. Project names in the report are counted, never copied: the report
    covers every company on the machine. A symlinked imports folder is not
    followed."""
    base = os.path.join(hq_root, 'workspace', 'imports')
    try:
        if os.path.islink(base):
            return None
        stamps = sorted(((n, k) for n in os.listdir(base) for k in [_import_stamp_key(n)] if k),
                        key=lambda x: x[1], reverse=True)
    except OSError:
        return None
    for n, key in stamps:
        rep = _read_report(os.path.join(base, n))
        if rep is None:
            continue
        path = os.path.join(base, n, 'report.json')
        counts = rep.get('counts') if isinstance(rep.get('counts'), dict) else {}
        out = {'path': os.path.relpath(path, hq_root), 'scanned_at': key[0].strftime('%Y-%m-%dT%H:%M:%SZ'),
               'source': _tool_id(rep.get('source')) or 'import-context',
               'written_at': _iso(rep.get('written_at'))}
        for k in IMPORT_COUNT_KEYS:
            out[k] = _int(counts.get(k)) or 0
        out['sessions'] = _report_sessions(rep)
        tools = rep.get('tools') if isinstance(rep.get('tools'), list) else []
        out['tools'] = sorted({t for t in tools if _tool_id(t)})
        projects = rep.get('projects') if isinstance(rep.get('projects'), list) else []
        out['projects'] = len([x for x in projects if isinstance(x, str) and x.strip()]) if projects else None
        return out
    return None


def current_session_ids(environ=None):
    """Ids of the session running the brief, from the harness environment."""
    environ = os.environ if environ is None else environ
    return {environ[k] for k in SESSION_ID_ENV if environ.get(k)}


def detected_import(other, sessions, tools, n_projects, first_day, last_day):
    """welcome.import when no report exists but past sessions are on this Mac.
    The transcripts stay where the harness wrote them, so the machine inventory
    is the import: there is nothing left for /import-context to bring in."""
    out = {'path': None, 'scanned_at': None, 'source': 'detected', 'written_at': None}
    out.update(dict.fromkeys(IMPORT_COUNT_KEYS))
    out['sessions'] = {'total': other, 'claude': sessions['claude'], 'codex': sessions['codex'],
                       'cursor': sessions['cursor'], 'days_seen': sessions['days_seen'],
                       'first_at': first_day, 'last_at': last_day}
    out['tools'] = tools
    out['projects'] = n_projects
    return out


# Every field the welcome object can carry, in output order. Desktop hides an
# absent field. SKILL.md "Welcome edition" documents each one.
WELCOME_FIELDS = ('first_run', 'headline', 'import', 'sessions', 'harness', 'top_projects', 'top_repos',
                  'recent_work', 'repos', 'apps', 'tree', 'actions', 'next_steps', 'getting_started', 'note')
WELCOME_SESSION_FIELDS = ('total', 'local', 'imported', 'claude', 'codex', 'cursor', 'days_seen')
WELCOME_PROJECT_FIELDS = ('name', 'path', 'sessions', 'last_active_at', 'harness')
WELCOME_REPO_FIELDS = ('name', 'path', 'sessions', 'last_commit_at')
WELCOME_RECENT_FIELDS = ('title', 'project', 'at', 'harness')
WELCOME_TREE_FIELDS = ('companies', 'projects', 'knowledge_files')
WELCOME_ACTION_FIELDS = ('id', 'kind', 'label', 'reason', 'launch_prompt', 'primary')
WELCOME_ACTION_KINDS = ('open_harness', 'connect_ai_apps', 'connect_integration', 'connect_company',
                        'import_history', 'open_tree')
WELCOME_TOP = 5
WELCOME_TITLE_CHARS = 80
WELCOME_TREE_CAP = 20000      # entries walked when counting the HQ tree
WELCOME_GIT_TIMEOUT_S = 5
WELCOME_GIT_BUDGET_S = 30     # all git reads together; past it, repos are not named
WELCOME_SCAN_PROJECTS = 60  # busiest project folders checked for ownership
HARNESS_CLAUDE, HARNESS_CODEX, HARNESS_CURSOR = 'claude_code', 'codex', 'cursor'
HARNESSES = (HARNESS_CLAUDE, HARNESS_CODEX, HARNESS_CURSOR)
HARNESS_NAMES = {HARNESS_CLAUDE: 'Claude Code', HARNESS_CODEX: 'Codex', HARNESS_CURSOR: 'Cursor'}
# Output ids are hyphenated; the underscore keys above appear only inside harness.counts.
HARNESS_IDS = {HARNESS_CLAUDE: 'claude-code', HARNESS_CODEX: 'codex', HARNESS_CURSOR: 'cursor'}
ROW_HARNESS = {'claude': HARNESS_CLAUDE, 'codex': HARNESS_CODEX}
OPEN_HQ_PROMPT = 'Catch me up on what I worked on recently and suggest what to do next.'
CONNECT_AI_APPS_PROMPT = 'Help me connect Claude Code, Codex and Cursor to HQ.'
OPEN_TREE_PROMPT = 'Give me a short tour of my HQ: companies, projects and knowledge.'
WELCOME_FIRST_STEPS = 'Welcome to HQ. Open Claude Code, Codex or Cursor in your HQ folder and your first session starts here.'
GETTING_STARTED_NO_SESSIONS = ('Start with one small task in Claude Code, Codex or Cursor from your HQ folder. '
                               "Tomorrow's brief will show what you did and what to pick up next.")


def _plural(n, one, many=None):
    return f"{n:,} {one if n == 1 else (many or one + 's')}"


def _join(names, word='and'):
    names = list(names)
    return names[0] if len(names) == 1 else ', '.join(names[:-1]) + f' {word} ' + names[-1]


def _iso_from_ts(ts):
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def _display_path(path):
    """~/... inside the home folder; outside it, the folder name only."""
    home = os.path.expanduser('~')
    if home and (path == home or path.startswith(home + os.sep)):
        return '~' + path[len(home):]
    return os.path.basename(path.rstrip('/')) or path


def _repo_root(cwd, hq_real=None):
    """The git repo folder holding cwd: cwd or up to 3 parents with a .git entry.
    The HQ root and the home folder are not repos here."""
    home = os.path.realpath(os.path.expanduser('~'))
    d = cwd
    for _ in range(4):
        real = os.path.realpath(d)
        if real in (hq_real, home, os.sep):
            return None
        if os.path.exists(os.path.join(d, '.git')):
            return d
        parent = os.path.dirname(d.rstrip('/\\'))
        if not parent or parent == d:
            return None
        d = parent
    return None


def _last_commit_at(path):
    """Newest commit time in the repo (ISO), or None. Bounded by WELCOME_GIT_TIMEOUT_S."""
    try:
        p = subprocess.run(['git', '-C', path, 'log', '-1', '--format=%cI'], capture_output=True, text=True,
                           timeout=WELCOME_GIT_TIMEOUT_S)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p.stdout.strip() or None if p.returncode == 0 else None


def _remote_org(path):
    """GitHub owner of the repo's origin remote, or None."""
    try:
        p = subprocess.run(['git', '-C', path, 'config', '--get', 'remote.origin.url'], capture_output=True,
                           text=True, timeout=WELCOME_GIT_TIMEOUT_S)
    except (OSError, subprocess.TimeoutExpired):
        return None
    m = re.search(r'github\.com[:/]([^/]+)/', p.stdout.strip()) if p.returncode == 0 else None
    return m.group(1) if m else None


def welcome_tree(hq_root, allowed):
    """{companies, projects, knowledge_files}. Companies are counted across the
    HQ; projects and knowledge files only for the `allowed` companies and the
    personal folder (None in `allowed`). Walks at most WELCOME_TREE_CAP entries."""
    out = {'companies': 0, 'projects': 0, 'knowledge_files': 0}
    cdir = os.path.join(hq_root, 'companies')
    try:
        slugs = sorted(n for n in os.listdir(cdir) if not n.startswith(('.', '_')) and os.path.isdir(os.path.join(cdir, n)))
    except OSError:
        slugs = []
    out['companies'] = len(slugs)
    bases = [os.path.join(cdir, s) for s in slugs if s in allowed]
    if None in allowed:
        bases.append(os.path.join(hq_root, 'personal'))
    budget = WELCOME_TREE_CAP
    for base in bases:
        try:
            out['projects'] += sum(1 for e in os.scandir(os.path.join(base, 'projects')) if e.is_dir() and not e.name.startswith('.'))
        except OSError:
            pass
        for dirpath, dirnames, filenames in os.walk(os.path.join(base, 'knowledge')):
            dirnames[:] = [d for d in dirnames if not d.startswith('.') and d != 'node_modules']
            budget -= len(dirnames) + len(filenames)
            out['knowledge_files'] += sum(1 for f in filenames if not f.startswith('.'))
            if budget <= 0:
                break
    return out


UNRESOLVED = object()   # a session whose company HQ cannot tell


def _row_key(r, i):
    return r.get('id') or f'row:{i}'


def session_company_resolver(hq_root, rows, meta_fields=None):
    """company_for(sid, cwd): the company a session belongs to, None for
    personal work, or UNRESOLVED. The company comes from the scan row, then the
    session's HQ meta.yaml, then a cwd under companies/<slug>. A cwd under
    companies/<slug> is that company's even when the record says personal. Any
    other folder inside HQ (the HQ root, repos/, worktrees) with no record of
    its company is UNRESOLVED, so it is counted and never named."""
    row_company = {_row_key(r, i): r.get('company') for i, r in enumerate(rows)}
    hq_real = os.path.realpath(hq_root) if hq_root else None
    memo = {}

    def from_meta(sid):
        if sid not in memo:
            memo[sid] = UNRESOLVED
            try:
                with open(os.path.join(hq_root, 'workspace', 'sessions', os.path.basename(sid), 'meta.yaml'),
                          encoding='utf-8', errors='replace') as f:
                    text = f.read()
            except OSError:
                return UNRESOLVED
            if meta_fields:
                memo[sid] = meta_fields(text).get('company_slug') or None
            else:
                m = re.search(r'^company_slug:[ \t]*["\']?([^"\'\s]*)', text, re.M)
                memo[sid] = (m.group(1) if m else '') or None
        return memo[sid]

    def company_for(sid, cwd):
        record = UNRESOLVED
        if sid in row_company:
            record = row_company[sid]
        elif sid and hq_root:
            record = from_meta(sid)
        if record is not UNRESOLVED and record:
            return record
        place = None if cwd else UNRESOLVED
        if cwd and hq_real:
            rel = os.path.relpath(os.path.realpath(cwd), hq_real).replace('\\', '/').split('/')
            if rel[0] == 'companies' and len(rel) > 1:
                return rel[1]
            if rel[0] != '..':
                place = UNRESOLVED
        # recorded as personal, and not under companies/
        return None if record is None else place

    return company_for


def welcome_inputs(hq_root, rows, company, also=()):
    """{inv, recent, tree, company_for, notes, current_session} for welcome_block. Recent titles
    are read only for sessions in the brief's own company. Each read is bounded
    and guarded: a failure leaves that part out, adds a plain note and sends
    the details to stderr."""
    mod = _load_local_sessions()
    allowed = {company} | set(also)
    company_for = session_company_resolver(hq_root, rows, getattr(mod, 'meta_fields', None))
    notes, inv, recent, tree = [], None, [], None

    def keep(sid, cwd):
        c = company_for(sid, cwd)
        return c is not UNRESOLVED and c in allowed

    try:
        inv = mod.inventory() if hasattr(mod, 'inventory') else None
    except Exception as e:
        print(f'[sweep] welcome inventory failed: {e}', file=sys.stderr)
        notes.append("Couldn't count every past session")
    try:
        if inv and hasattr(mod, 'recent_titles'):
            recent = mod.recent_titles(inv['recent'], keep=keep)
    except Exception as e:
        print(f'[sweep] welcome recent titles failed: {e}', file=sys.stderr)
        notes.append("Couldn't read your recent work")
    try:
        tree = welcome_tree(hq_root, allowed)
    except Exception as e:
        print(f'[sweep] welcome tree failed: {e}', file=sys.stderr)
        notes.append("Couldn't count your HQ folders")
    return {'inv': inv, 'recent': recent, 'tree': tree, 'company_for': company_for, 'notes': notes,
            'current_session': current_session_ids()}


def welcome_block(rows, company, first_run, imported, repo_cap=8, inv=None, recent=None, tree=None,
                  hq_root=None, also=(), has_companies=False, commit_at=None, owners=None, remote_org=None,
                  company_for=None, notes=(), clock=None, current_session=(), now=None):
    """The brief's welcome object (field names in WELCOME_FIELDS).

    `rows` are HQ-started sessions (local_sessions.scan shape). `inv` is the
    machine inventory (local_sessions.inventory) and `recent` the newest titled
    sessions (local_sessions.recent_titles); both are optional. Every session is
    counted. Names, paths and titles come only from the brief's own company
    (`company`, plus `also` in person mode); other companies are counted only.
    A folder is named only when every one of its sessions resolves, through
    `company_for` (session_company_resolver), to an allowed company.
    `has_companies` is False when membership lookup confirmed zero companies.
    `owners` maps company → GitHub owner; a repo whose remote owner belongs to
    another company is not named. Pure apart from `commit_at(path)` and
    `remote_org(path)` (git reads with a timeout).

    `imported` is latest_import(). Without a report, past sessions on this Mac
    count as imported: welcome.import is then a detected_import() object, and
    "Bring in your past work" is offered only when neither exists. Past
    sessions are the inventory's transcripts (HQ-started rows only when there
    is no inventory, so a row and its transcript count once) other than
    `current_session` (ids of the session running the brief). When no such id
    is in the inventory, transcripts written to in the last LIVE_SESSION_S
    seconds before `now` (epoch seconds) are left out instead."""
    mod = _load_local_sessions()
    allowed = {company} | set(also)
    if company_for is None:
        company_for = session_company_resolver(hq_root, rows, getattr(mod, 'meta_fields', None))
    import time
    clock = clock or time.monotonic
    git_deadline = clock() + WELCOME_GIT_BUDGET_S
    tools = Counter(r.get('tool') for r in rows if r.get('tool'))

    # Sessions: HQ-started rows and the machine inventory, one count per session id.
    ids = {}
    for r in rows:
        ids[r.get('id') or id(r)] = ROW_HARNESS.get(r.get('tool'))
    for sid, h in ((inv or {}).get('sessions') or {}).items():
        ids[sid] = h or ids.get(sid)
    by_harness = Counter(h for h in ids.values() if h)
    days = {r['started_at'][:10] for r in rows if r.get('started_at')} | set((inv or {}).get('days') or ())
    n_cursor = ((inv or {}).get('counts') or {}).get(HARNESS_CURSOR, 0)
    local = len(ids) + n_cursor
    cur = set(current_session or ())
    if inv:
        inv_ids = set(inv.get('sessions') or ())
        past = inv_ids - cur
        if not cur & inv_ids:
            now = time.time() if now is None else now
            past -= {r.get('id') for r in inv.get('recent') or () if (r.get('ts') or 0) >= now - LIVE_SESSION_S}
    else:
        past = set(ids) - cur
    other = len(past) + n_cursor
    n_imported = (((imported or {}).get('sessions') or {}).get('total') or 0) if imported else other
    total = max(local, n_imported)
    sessions = {'total': total, 'local': local, 'imported': n_imported,
                'claude': by_harness.get(HARNESS_CLAUDE, 0), 'codex': by_harness.get(HARNESS_CODEX, 0),
                'cursor': n_cursor, 'days_seen': len(days)}

    counts = {HARNESS_CLAUDE: sessions['claude'], HARNESS_CODEX: sessions['codex'], HARNESS_CURSOR: n_cursor}
    primary = max(HARNESSES, key=lambda h: (counts[h], -HARNESSES.index(h))) if any(counts.values()) else None
    open_label = f'Open HQ in {HARNESS_NAMES[primary or HARNESS_CLAUDE]}'
    harness = {'primary': HARNESS_IDS.get(primary), 'counts': counts,
               'action': {'id': 'open-hq-in-harness', 'kind': 'open_harness', 'harness': HARNESS_IDS[primary or HARNESS_CLAUDE],
                          'label': open_label, 'launch_prompt': OPEN_HQ_PROMPT}}

    # Projects: one per working folder. The inventory already holds HQ-started
    # sessions, so rows add projects only when there is no inventory.
    projects = {}
    if inv:
        for cwd, p in (inv.get('projects') or {}).items():
            projects[cwd] = {'sessions': p['sessions'], 'last': p['last_ts'] and _iso_from_ts(p['last_ts']),
                             'by': Counter(p.get('by_harness') or {}), 'ids': list(p.get('ids') or ())}
    else:
        for i, r in enumerate(rows):
            if r.get('cwd'):
                p = projects.setdefault(r['cwd'], {'sessions': 0, 'last': None, 'by': Counter(), 'ids': []})
                p['sessions'] += 1
                p['ids'].append(_row_key(r, i))
                p['last'] = max(filter(None, [p['last'], r.get('last_activity') or r.get('started_at')]), default=None)
                if ROW_HARNESS.get(r.get('tool')):
                    p['by'][ROW_HARNESS[r['tool']]] += 1
    hq_real = os.path.realpath(hq_root) if hq_root else None
    org_company = {str(o).lower(): co for co, o in (owners or {}).items() if o}
    org_memo = {}

    def org_ok(cwd):
        """False when the folder's repo belongs to another company's GitHub owner.
        Past the git budget a repo is not named."""
        root = _repo_root(cwd, hq_real) if org_company else None
        if not root:
            return True
        if root not in org_memo:
            if clock() >= git_deadline:
                org_memo[root] = False
            else:
                org = (remote_org or _remote_org)(root)
                org_memo[root] = org_company.get((org or '').lower(), company) in allowed
        return org_memo[root]

    def owned(cwd, ids):
        """Every session in the folder is in an allowed company, and its repo is too."""
        if not cwd:
            return False
        for sid in ids or [None]:
            c = company_for(sid, cwd)
            if c is UNRESOLVED or c not in allowed:
                return False
        return org_ok(cwd)

    # Legacy repos list: the brief's own HQ-started sessions, by repo. A folder
    # that also holds another company's session is not named.
    repos = Counter()
    for i, r in enumerate(rows):
        if r.get('company') != company if company else r.get('company'):
            continue
        if r.get('cwd') and not owned(r['cwd'], (projects.get(r['cwd']) or {}).get('ids') or [_row_key(r, i)]):
            continue
        name = (mod.repo_from_cwd(r['cwd']) if r.get('cwd') else None) or r.get('project')
        if name:
            repos[name] += 1

    def project_name(cwd):
        if hq_real and os.path.realpath(cwd) == hq_real:
            return 'HQ'
        return mod.repo_from_cwd(cwd) or os.path.basename(cwd.rstrip('/\\')) or cwd

    ranked = sorted(projects.items(), key=lambda kv: kv[1]['last'] or '', reverse=True)
    ranked.sort(key=lambda kv: -kv[1]['sessions'])
    # Ownership checks are bounded: the busiest WELCOME_SCAN_PROJECTS folders.
    ranked = [kv for kv in ranked[:WELCOME_SCAN_PROJECTS] if owned(kv[0], kv[1]['ids'])]
    top_projects = [{'name': project_name(cwd), 'path': _display_path(cwd), 'sessions': p['sessions'],
                     'last_active_at': p['last'],
                     'harness': HARNESS_IDS.get(max(p['by'], key=lambda h: (p['by'][h], -HARNESSES.index(h)))) if p['by'] else None}
                    for cwd, p in ranked[:WELCOME_TOP]]

    # Repos: the git repo each owned project sits in.
    repo_rows = {}
    for cwd, p in ranked:
        root = _repo_root(cwd, hq_real)
        if not root:
            continue
        x = repo_rows.setdefault(root, {'sessions': 0, 'last': None})
        x['sessions'] += p['sessions']
        x['last'] = max(filter(None, [x['last'], p['last']]), default=None)
    top_repos = []
    for root, x in sorted(repo_rows.items(), key=lambda kv: (-kv[1]['sessions'], kv[0]))[:WELCOME_TOP]:
        top_repos.append({'name': mod.repo_from_cwd(root) or os.path.basename(root), 'path': _display_path(root),
                          'sessions': x['sessions'],
                          'last_commit_at': (commit_at or _last_commit_at)(root) if clock() < git_deadline else None})

    recent_work = []
    for r in sorted(recent or [], key=lambda r: r.get('at') or '', reverse=True):
        if len(recent_work) >= WELCOME_TOP:
            break
        if not owned(r.get('cwd'), [r.get('id')]):
            continue
        project = project_name(r['cwd'])
        title = r.get('title')
        # Titles can come from prompt text; one that looks like a credential is never shown.
        if not isinstance(title, str) or not title.strip() or _sibling('local_sessions').looks_secret(title):
            title = f'Session in {project}'
        recent_work.append({'title': title[:WELCOME_TITLE_CHARS], 'project': project,
                            'at': r.get('at'), 'harness': HARNESS_IDS.get(r.get('harness'))})

    # Project count: folders with a session resolved to another company are left
    # out. Personal and unresolved folders still count; they are just not named.
    def elsewhere(cwd, ids):
        return any(c is not UNRESOLVED and c is not None and c not in allowed
                   for c in (company_for(sid, cwd) for sid in ids or [None]))
    n_projects = sum(1 for cwd, p in projects.items() if not elsewhere(cwd, p['ids']))
    if not imported and other > 0:
        # Per-harness counts leave out the running session, as `other` does.
        past_by = Counter(ids.get(sid) for sid in past)
        past_sessions = dict(sessions, claude=past_by.get(HARNESS_CLAUDE, 0), codex=past_by.get(HARNESS_CODEX, 0))
        imported = detected_import(other, past_sessions, [HARNESS_IDS[h] for h in HARNESSES if counts[h]], n_projects,
                                   min(days) if days else None, max(days) if days else None)
    tree = tree or {'companies': 0, 'projects': 0, 'knowledge_files': 0}
    actions = [dict(harness['action'], reason='Pick up where you left off, with your HQ context loaded.')]
    missing = [HARNESS_NAMES[h] for h in HARNESSES if not counts[h]]
    if missing:
        found = [HARNESS_NAMES[h] for h in HARNESSES if counts[h]]
        actions.append({'id': 'connect-ai-apps', 'kind': 'connect_ai_apps', 'label': 'Connect your AI apps',
                        'reason': (f"HQ already sees your {_join(found)} work. Connect {_join(missing, 'or')} too, so the brief covers everything."
                                   if found else 'Connect Claude Code, Codex or Cursor so HQ can start learning how you work.'),
                        'launch_prompt': CONNECT_AI_APPS_PROMPT})
    if not imported:
        actions.append({'id': 'import-history', 'kind': 'import_history', 'label': 'Bring in your past work',
                        'reason': 'Importing past Claude Code and Codex work fills in your history.',
                        'launch_prompt': '/import-context'})
    if not company and not has_companies:
        actions.append({'id': 'connect-company', 'kind': 'connect_company', 'label': 'Create or join a company',
                        'reason': 'Meetings, team context and agents live in a company.', 'launch_prompt': '/onboard'})
    if company:
        actions.append({'id': 'connect-github', 'kind': 'connect_integration', 'label': 'Connect GitHub',
                        'integration': {'slug': 'github', 'name': 'GitHub'},
                        'reason': 'Connected apps add pull requests, meetings and messages to the brief.',
                        'launch_prompt': '/hq-integrations'})
    actions.append({'id': 'open-tree', 'kind': 'open_tree', 'label': 'Look around your HQ',
                    'reason': f"{_plural(tree['companies'], 'company', 'companies')}, {_plural(tree['projects'], 'project')} "
                              f"and {_plural(tree['knowledge_files'], 'knowledge file')} so far.",
                    'launch_prompt': OPEN_TREE_PROMPT})
    kinds = [x['kind'] for x in actions]
    if not total:
        pick = 'connect_ai_apps'
    elif 'import_history' in kinds:
        pick = 'import_history'
    elif 'connect_company' in kinds:
        pick = 'connect_company'
    else:
        pick = 'open_harness'
    for x in actions:
        x['primary'] = x['kind'] == pick

    if total:
        where = f" across {_plural(n_projects, 'project')}" if n_projects else ''
        most = ((f", in {HARNESS_NAMES[primary]}" if total == 1 else f", most of them in {HARNESS_NAMES[primary]}")
                if primary else '')
        headline = f"HQ found {_plural(total, 'past session')}{where} on this Mac{most}."
    else:
        headline = WELCOME_FIRST_STEPS

    steps = []
    if not company and not has_companies:
        steps.append({'id': 'connect-company', 'kind': 'connect_company',
                      'reason': 'Meetings, meeting signals, agents and integrations need a company.'})
    if not imported:
        steps.append({'id': 'import', 'kind': 'import',
                      'reason': 'No import report yet. Importing past Claude Code and Codex work fills in the history.'})
    if company:
        steps.append({'id': 'connect-integration', 'kind': 'connect_integration',
                      'reason': 'Connected apps add meetings and messages to the brief.'})
        steps.append({'id': 'sync', 'kind': 'sync',
                      'reason': "Syncing brings in the company's shared context."})
    out = {'first_run': bool(first_run), 'headline': headline, 'import': imported, 'sessions': sessions,
           'harness': harness, 'top_projects': top_projects, 'top_repos': top_repos, 'recent_work': recent_work,
           'repos': [{'name': n, 'sessions': c} for n, c in sorted(repos.items(), key=lambda kv: (-kv[1], kv[0]))[:repo_cap]],
           'apps': [TOOL_NAMES[t] for t in ('claude', 'codex') if tools.get(t)] if not inv else
                   [HARNESS_NAMES[h] for h in HARNESSES if counts[h]],
           'tree': tree, 'actions': actions, 'next_steps': steps}
    if not total:
        out['getting_started'] = GETTING_STARTED_NO_SESSIONS
    notes = list((inv or {}).get('notes') or ()) + list(notes or ())
    if notes:
        out['note'] = notes[0] + '.'
    assert set(out) <= set(WELCOME_FIELDS), sorted(set(out) - set(WELCOME_FIELDS))
    return out


def _hq_session_script(hq_root):
    """`core/scripts/hq-session.sh` under the brief's HQ root, else next to this skill."""
    rel = os.path.join('core', 'scripts', 'hq-session.sh')
    if hq_root:
        candidate = os.path.join(hq_root, rel)
        if os.path.isfile(candidate):
            return candidate
    here = os.path.dirname(os.path.abspath(__file__))
    candidate = os.path.normpath(os.path.join(here, '..', '..', '..', '..', rel))
    return candidate if os.path.isfile(candidate) else None


def read_session_lock(hq_root=None):
    """Company slugs this session is locked to (`hq-session.sh get company_slugs`).

    Raises RuntimeError when the script is missing or fails. An empty lock is
    a successful read of a session with no companies."""
    script = _hq_session_script(hq_root)
    if not script:
        raise RuntimeError('core/scripts/hq-session.sh was not found')
    try:
        proc = subprocess.run(['bash', script, 'get', 'company_slugs'],
                              capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(str(exc)[:200]) from exc
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or 'hq-session.sh failed').strip()[:200]
        raise RuntimeError(detail or 'hq-session.sh failed')
    return [slug.strip() for slug in proc.stdout.split(',') if slug.strip()]


def enforce_company_lock(company, locked):
    """Refuse `--company` when it is outside the session lock. No company
    (`--personal`) is not checked."""
    if not company or company in (locked or []):
        return
    shown = ', '.join(locked) if locked else 'none'
    print(f"refusing --company {company}: it is outside this session's company lock ({shown}). "
          f"Lock it with: bash core/scripts/hq-session.sh add company {company}",
          file=sys.stderr)
    raise SystemExit(1)


GETTING_STARTED = "HQ brings your work, shared context and AI tools together. Start with a personal task, then create or join a company with /onboard when you are ready."


def membership_slugs(hq_root):
    """Read the caller's memberships, not pending invitations or vault content.

    HQ's read-only sync-mode table is the supported CLI membership inventory.
    Reject unknown output rather than mistake a failed lookup for zero companies.
    """
    output = run(['hq', 'sync', 'mode', '--show', '--hq-root', hq_root])
    output = re.sub(r'\x1b\[[0-9;]*m', '', output).strip()
    if output.startswith('No memberships found.'):
        return []
    lines = output.splitlines()
    if not lines or lines[0].split() != ['COMPANY', 'MODE', 'UPDATED', 'MEMBERSHIP']:
        raise RuntimeError('unrecognized membership inventory')
    slugs = []
    for line in lines[2:]:
        cells = line.split()
        if len(cells) < 4 or cells[1] not in ('all', 'shared', 'custom') or not re.fullmatch(r'[A-Za-z0-9_.-]+', cells[0]):
            raise RuntimeError('invalid membership company slug')
        slugs.append(cells[0])
    return sorted(set(slugs))


def tag_items(section, company):
    """Validate only brief-item collections; participant and metadata rows stay intact."""
    errors = []

    def rows(items, source):
        kept = []
        for item in items or []:
            if not isinstance(item, dict):
                kept.append(item)
                continue
            existing = item.get('company', company)
            # Local sessions use this legacy marker for unbound personal work.
            if source == 'sessions' and company is None and existing == PERSONAL_TAG:
                existing = None
            if existing != company:
                errors.append({'source': source, 'error': 'Dropped an item belonging to another company.'})
                continue
            item['company'] = company
            kept.append(item)
        return kept

    for key in ('sessions', 'meetings', 'meeting_signals', 'dms', 'prs', 'releases'):
        if isinstance(section.get(key), list):
            section[key] = rows(section[key], key)
    for meeting in section.get('meeting_signals') or []:
        for key in ('decisions', 'action_items'):
            if isinstance(meeting.get(key), list):
                meeting[key] = rows(meeting[key], 'meeting_signals.' + key)
    fleet_data = section.get('fleet')
    if isinstance(fleet_data, dict):
        for key in ('agents', 'stuck'):
            if isinstance(fleet_data.get(key), list):
                fleet_data[key] = rows(fleet_data[key], 'fleet.' + key)
    health = section.get('main_health')
    if isinstance(health, dict):
        for repo, row in list(health.items()):
            if isinstance(row, dict) and not rows([row], 'main_health'):
                del health[repo]
    if errors:
        section.setdefault('isolation_errors', []).extend(errors)
    return section


def person_sweep(a):
    errors = {}
    try:
        members = membership_slugs(a.hq_root)
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
        members = []
        errors['memberships'] = 'Could not load your companies. Sign in or try again when connected.'
    try:
        locked = read_session_lock(a.hq_root)
    except RuntimeError as exc:
        locked = []
        errors['company_lock'] = 'Could not check company access. Only personal work is included.'
    included = sorted(set(members) & set(locked))
    data = {'mode': 'person', 'company': None, 'companies': {},
            'generated_at': _now(), 'sources': {},
            'not_included': [{'company': slug, 'reason': 'not included: open HQ in that company to include it'}
                             for slug in members if slug not in locked]}
    for key, error in errors.items():
        data['sources'][key] = {'state': 'failed', 'ok': False, 'error': error}
    brief_dir = os.path.join(a.hq_root, 'workspace', 'brief')
    run_id = os.path.basename(os.path.dirname(os.path.abspath(a.out)))
    runs = ready_runs(os.path.join(brief_dir, 'index.jsonl'), run_id)
    prior = [row for row in load_prior_data(brief_dir, runs) if row[2].get('mode') == 'person'][-14:]
    prev_id, prev_at, prev = prior[-1] if prior else (None, None, None)
    data['previous_run'] = {'run_id': prev_id, 'generated_at': prev_at} if prev else None
    # Child outputs are temporary. Only the person run participates in history.
    with tempfile.TemporaryDirectory(prefix='brief-person-') as temp:
        for index, slug in enumerate([None] + included):
            out = os.path.join(temp, 'brief-data.json')
            args = ['--company', slug] if slug else ['--personal']
            args += ['--hq-root', a.hq_root, '--out', out, '--days', str(a.days),
                     '--hours', str(a.hours), '--today', a.today]
            for flag, value in [('--now', a.now), ('--org', a.org if not slug else None), ('--repos', a.repos if not slug else None)]:
                if value:
                    args += [flag, value]
            for name in a.me or []:
                args += ['--me', name]
            if a.catch_up:
                args += ['--catch-up']
            try:
                main(args, person_section=True)
                with open(out, encoding='utf-8') as f:
                    section = json.load(f)
                for day in section.get('days', {}).values():
                    day.pop('other_sessions', None)
                    day.pop('unknown_sessions', None)
                old = ((prev.get('companies') or {}).get(slug) if slug else prev.get('personal')) if prev else None
                section['previous_run'] = data['previous_run'] if old else None
                health = section.get('main_health')
                if isinstance(health, dict):
                    main_health_delta(health, old.get('main_health') if old else None)
                fl = section.get('fleet')
                if isinstance(fl, dict):
                    fl['delta'] = fleet_delta(fl['stuck'], old.get('fleet'), prev_at) if old else None
                    fl['series'] = fleet_series([(at, ((d.get('companies') or {}).get(slug) or {}).get('fleet')) for _, at, d in prior])
                tag_items(section, slug)
                section.pop('welcome', None)
            except (Exception, SystemExit):
                if slug is None:
                    raise
                section = {'company': slug, 'mode': 'company',
                           'error': "Could not collect this company's work. Try again later.",
                           'sources': {'sweep': {'state': 'failed', 'ok': False,
                                               'error': "Could not collect this company's work. Try again later."}}}
            if slug:
                data['companies'][slug] = section
            else:
                data['personal'] = section
                data['window'] = section['window']
            if a.status:
                Status(a.status, None)._write(lambda status: status.update(
                    mode='person', progress=0.25 + 0.45 * (index + 1) / (len(included) + 1),
                    step='Collected personal work' if slug is None else 'Finished company ' + slug,
                    companies={co: {'sources': part['sources']} for co, part in data['companies'].items()},
                    not_included=data['not_included'], sources=data['sources']))
    data['welcome'] = None
    if a.welcome or not runs or not members:
        try:
            window = data['window']
            rows = _load_local_sessions().scan(a.hq_root, window['sessions_from'], window['sessions_to'])
            inputs = welcome_inputs(a.hq_root, rows, None, included)
            data['welcome'] = welcome_block(rows, None, not runs, latest_import(a.hq_root), **inputs,
                                            hq_root=a.hq_root, also=included,
                                            has_companies=bool(members) or 'memberships' in errors,
                                            owners=_sibling('housekeeping').company_owners(a.hq_root))
        except Exception as e:
            data['welcome'] = {'first_run': not runs, 'note': failure('welcome', e)['note']}
        if not members:
            data['welcome']['getting_started'] = GETTING_STARTED
    with open(a.out, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=1)
    print(json.dumps({'out': a.out, 'mode': 'person', 'companies': included, 'not_included': data['not_included']}))


# ---------- main ----------
def main(argv=None, person_section=False):
    ap = argparse.ArgumentParser()
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument('--all', action='store_true', help='personal plus every permitted company (default)')
    mode.add_argument('--company', default=None)
    mode.add_argument('--personal', action='store_true',
                      help='no company: local sessions, PRs, DMs and main CI only')
    ap.add_argument('--welcome', action='store_true',
                    help='add the welcome object (default: personal mode with no earlier ready run)')
    ap.add_argument('--days', type=int, default=7, help='local days in the per-day rollup (the week arc)')
    ap.add_argument('--catch-up', action='store_true',
                    help='catch-up brief: keep meetings since the first --days day, not only the --hours window')
    ap.add_argument('--hq-root', default=os.getcwd())
    ap.add_argument('--org', default=None, help='limit the PR search to one GitHub owner (default: every owner)')
    ap.add_argument('--repos', default=None,
                    help='comma-separated repos for main_health (default: repos of your PRs in the window)')
    ap.add_argument('--today', default=dt.date.today().isoformat())
    ap.add_argument('--hours', type=int, default=24, help='session window length, ending at --now')
    ap.add_argument('--now', default=None, help='ISO end of the session window (default: real now)')
    ap.add_argument('--out', required=True)
    ap.add_argument('--status', default=None, help='status.json to update live with activity, findings and samples')
    ap.add_argument('--me', action='append', default=None,
                    help='name(s) that mean the user in meeting signals (default: git user.name)')
    a = ap.parse_args(argv)
    if not 1 <= a.days <= 14:
        ap.error('--days must be between 1 and 14')
    if not a.company and not a.personal:
        return person_sweep(a)
    SOURCES.clear()
    if a.company:
        try:
            locked = read_session_lock(a.hq_root)
        except RuntimeError as exc:
            print(f"refusing --company {a.company}: cannot read the session company lock ({exc}).",
                  file=sys.stderr)
            raise SystemExit(1)
        enforce_company_lock(a.company, locked)
    _sibling('brief_rank').load_product_names(a.hq_root, a.company)
    # A company brief searches that company's GitHub owner unless --org says
    # otherwise; rows from owners mapped to other companies are dropped below.
    owners = _sibling('housekeeping').company_owners(a.hq_root)
    org = a.org or (owners.get(a.company) if a.company else None)
    me_names = a.me or []
    if not me_names:
        try:
            n = subprocess.run(['git', 'config', 'user.name'], capture_output=True, text=True, timeout=5).stdout.strip()
            me_names = [n] if n else []
        except Exception:
            me_names = []
    today = dt.date.fromisoformat(a.today)
    days = [(today - dt.timedelta(days=i)).isoformat() for i in range(a.days, 0, -1)]
    now = dt.datetime.fromisoformat(a.now.replace('Z', '+00:00')) if a.now else dt.datetime.now(dt.timezone.utc)
    if now.tzinfo is None:
        now = now.astimezone()
    now = now.astimezone(dt.timezone.utc).replace(microsecond=0)
    sess_from = now - dt.timedelta(hours=a.hours)
    # gh search filters by date only; reach one day earlier, then cut to the window.
    since = min(days[0], (sess_from - dt.timedelta(days=1)).date().isoformat())
    # Meetings count as the person's day only when they start inside the session
    # window; a catch-up brief widens that to the first rollup day.
    meetings_from = sess_from
    if a.catch_up:
        day0 = dt.datetime.combine(dt.date.fromisoformat(days[0]), dt.time.min).astimezone()
        meetings_from = min(sess_from, day0.astimezone(dt.timezone.utc))
    st = Status(a.status, a.company, (sess_from, now))
    run_id = os.path.basename(os.path.dirname(os.path.abspath(a.out)))
    data = {
        'generated_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
        'company': a.company, 'mode': 'company' if a.company else 'personal', 'window': {'from': since, 'to': days[-1], 'today': a.today,
                                         'sessions_from': sess_from.isoformat(), 'sessions_to': now.isoformat(), 'hours': a.hours,
                                         'prs_from': sess_from.isoformat(), 'prs_to': now.isoformat(),
                                         'attended_meetings_from': meetings_from.isoformat()},
        'signals': None, 'prs_other': None,
    }
    steps = [
        ('sessions', 'Reading your work sessions', lambda: sessions(a.hq_root, sess_from, now, a.company)),
        ('meetings', 'Finding your meetings', lambda: meetings(a.company, since)),
        ('meeting_signals', 'Pulling decisions and action items from meetings', lambda: meeting_signals(a.company, data.get('meetings'), on_meeting, me_names)),
        ('dms', 'Checking your DMs', lambda: dms(a.company)),
        ('fleet', 'Checking your agents', lambda: fleet(a.company)),
        ('prs', 'Looking at your PRs', lambda: prs(org, since)),
        ('main_health', 'Checking main-branch builds',
         lambda: main_health(health_repos(a.repos.split(',') if a.repos else None, org, data.get('prs')),
                             data.get('prs'))),
    ]
    if not a.company:
        # Personal mode: the company-only sources are recorded as skipped and
        # left out of the live activity list.
        for name in COMPANY_SOURCES:
            skip_source(name)
            data[name] = None
        steps = [s for s in steps if s[0] not in COMPANY_SOURCES]
    keys = [k for k, _, _ in steps]
    sig_i = keys.index('meeting_signals') if 'meeting_signals' in keys else 0

    def on_meeting(n, total, done):
        lo = 0.25 + 0.45 * sig_i / len(steps)
        p = lo + (0.45 / len(steps)) * n / max(total, 1)
        st.tick(f'{n} of {total} meetings read', p,
                lambda fd: summarize('meeting_signals', done, a.company, fd, [], (sess_from, now)))

    for i, (key, label, fn) in enumerate(steps):
        st.start(label, 0.25 + 0.45 * i / len(steps))
        if person_section and a.company and key == 'prs' and not org:
            skip_source('prs')
            SOURCES['prs']['skipped_reason'] = 'company has no GitHub owner mapping'
            data[key] = None
        else:
            data[key] = fn()
        if key == 'prs' and data['prs'] is not None:
            if person_section and a.company:
                data['prs'] = [p for p in data['prs'] if (p.get('repo_full') or '').split('/')[0].lower() == org.lower()]
            data['prs'], data['prs_other'] = scope_prs(data['prs'], a.company, owners)
            SOURCES.get('prs', {}).update(count=len(data['prs']), other=data['prs_other'])
        if person_section:
            tag_items(data, a.company)
        st.finish(key, data[key], SOURCES.get(key, {}), 0.25 + 0.45 * (i + 1) / len(steps))
    # Every meeting fetched feeds the per-day rollup; meetings[] itself keeps only
    # the ones inside the window, with participants, duration and `attended`.
    all_meetings = data['meetings']
    if all_meetings is not None:
        data['meetings'] = enrich_meetings(all_meetings, data.get('meeting_signals'), me_names, meetings_from, now)
        SOURCES.setdefault('meetings', {})['in_window'] = len(data['meetings'])
    if data.get('dms') is not None and 'dms' in SOURCES:
        SOURCES['dms'].update(dm_truncation(data['dms'], DM_LIMIT, sess_from))
    # per-day rollup the generator uses for density and the week arc
    roll = defaultdict(lambda: {'sessions': 0, 'other_sessions': 0, 'meetings': 0, 'merged': 0, 'opened': 0})
    for s in data['sessions'] or []:
        # The week arc counts the user's own sessions; agent and lane runs are the
        # bot's heartbeats and would swamp the bars.
        if (s.get('kind') or 'you') != 'you':
            continue
        key = {'other': 'other_sessions', 'unknown': 'unknown_sessions'}.get(s['company'], 'sessions')
        roll[s['date']][key] = roll[s['date']].get(key, 0) + 1
    for m in all_meetings or []:
        roll[m['start'][:10]]['meetings'] += 1
    for p in data['prs'] or []:
        if not p.get('authored_by_me', True):
            continue
        roll[p['created'][:10]]['opened'] += 1
        if p['state'] == 'merged' and p.get('closed'):
            roll[p['closed'][:10]]['merged'] += 1
    # today is included too: the session window usually reaches into it
    data['days'] = {d: roll[d] for d in days + ([a.today] if a.today not in days else [])}
    # The brief's merged/opened numbers: the 24-hour window, the user's own PRs.
    # `days` is for the week arc only and can differ (it buckets by local date).
    data['prs_summary'] = pr_summary(data['prs'], sess_from, now) if data['prs'] is not None else None
    data['releases'] = releases(data['prs']) if data['prs'] is not None else None
    # Deltas against the previous ready run (found through index.jsonl), read-only.
    brief_dir = os.path.join(a.hq_root, 'workspace', 'brief')
    prior = [] if person_section else load_prior_data(brief_dir, ready_runs(os.path.join(brief_dir, 'index.jsonl'), run_id, a.company),
                            company=a.company)
    prior = [row for row in prior if row[2].get('mode') != 'person']
    prev_id, prev_at, prev = prior[-1] if prior else (None, None, None)
    data['previous_run'] = {'run_id': prev_id, 'generated_at': prev_at} if prev else None
    if isinstance(data.get('main_health'), dict):
        main_health_delta(data['main_health'], prev.get('main_health') if prev else None)
    if isinstance(data.get('fleet'), dict):
        fl = data['fleet']
        fl['delta'] = fleet_delta(fl['stuck'], prev.get('fleet'), prev_at) if prev else None
        fl['series'] = fleet_series([(at, d.get('fleet')) for _, at, d in prior])
    # A missing/empty workspace/brief next to workspace/brief-backup-* is a deliberate reset.
    try:
        data['brief_history'] = _sibling('housekeeping').brief_reset_state(
            os.path.join(a.hq_root, 'workspace'), run_id)
    except Exception as e:
        data['brief_history'] = failure('brief_history', e)
    # Welcome belongs to the person: first ready run across every mode.
    first_run = not ready_runs(os.path.join(brief_dir, 'index.jsonl'), run_id)
    if not person_section and (a.welcome or first_run):
        try:
            day0 = dt.datetime.combine(dt.date.fromisoformat(days[0]), dt.time.min).astimezone()
            rows = _load_local_sessions().scan(a.hq_root, day0.astimezone(dt.timezone.utc).isoformat(), now.isoformat())
            has_companies, lookup_failed = True, False
            if not a.company:
                try:
                    has_companies = bool(membership_slugs(a.hq_root))
                except (RuntimeError, OSError, subprocess.TimeoutExpired):
                    lookup_failed = True  # Unknown membership is not proof of zero companies.
                    SOURCES['memberships'] = {'state': 'failed', 'ok': False,
                                             'error': 'Could not load your companies. Sign in or try again when connected.'}
            inputs = welcome_inputs(a.hq_root, rows, a.company)
            data['welcome'] = welcome_block(rows, a.company, first_run, latest_import(a.hq_root), **inputs,
                                            hq_root=a.hq_root,
                                            has_companies=has_companies, owners=owners)
            if lookup_failed:
                data['welcome']['getting_started'] = GETTING_STARTED
        except Exception as e:
            data['welcome'] = {'first_run': first_run, 'note': failure('welcome', e)['note']}
    else:
        data['welcome'] = None
    data['sources'] = SOURCES
    with open(a.out, 'w') as f:
        json.dump(data, f, indent=1, default=str)
    print(json.dumps({'out': a.out, 'sources': SOURCES, 'days': data['days']}, indent=1))

if __name__ == '__main__':
    main()
