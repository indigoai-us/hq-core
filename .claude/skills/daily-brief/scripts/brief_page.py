#!/usr/bin/env python3
"""The Daily Brief page: the card layout the desktop app draws (`brief.json.page`).

The page format is the desktop app's BriefPage (packages/ui/src/brief/widgets/brief-page.ts):

  {version: 1, companies: {slug: {name}}, person: {name}, window: {from, to, zoom, label, hoursAway},
   theme: {style}, summary: [widget], dropped: [widget], stream: [widget]}

Each widget: {id, kind, size, type, symbol, company, title, why?, data, hover?, drill?}.

This module holds the deterministic parts; the model writes titles, kinds, sizes and the
choice of cards (SKILL.md, Step 4b):

  skeleton  brief-data.json -> page frame (companies, person, window, theme, the lead card's
            real numbers) plus `candidates`: one card's worth of computed facts per signal,
            each already tagged with its company.
  check     validate a page against the format and the design rules. Exit 1 on errors.
  attach    validate a page and write it into brief.json as `page`. Fail soft: an invalid
            page is left out, brief.json keeps every other field, and the reasons go to
            `page_problems` and stderr. With brief-data.json (--data, or the file beside
            brief.json) it also writes `brief.json.signals_notices` and, when a company's
            signals are stale, puts that company's notice card at the top of the page and
            labels or leaves out the cards that come from its signals. A stale brief always
            gets a valid page: when the written one is invalid, a page written by code is
            attached in its place. No page is written unless it passed the validator;
            exit 2 when signals are stale and no valid page could be built.
  notice    write `brief.json.signals_notices` from brief-data.json; when a company is
            stale and brief.json has no valid page yet, also the page written by code.
            Exit 1 when brief-data.json cannot be read, 2 as for attach.

Pure helpers are unit-tested in test_brief_page.py.
"""
import argparse
import copy
import datetime as dt
import importlib.util
import json
import os
import re
import sys
import tempfile

# ---------- the format (mirrors brief-page.ts) ----------

KINDS = ('focus', 'stat', 'ball', 'ask', 'trend', 'people', 'countdown', 'strip', 'progress', 'note')
SIZES = ('S', 'M', 'L', 'XL')
TYPES = ('summary', 'ask', 'dropped', 'stalled', 'broke', 'landed', 'moved', 'decided', 'campaign', 'launch',
         'task', 'learning', 'meeting', 'client')
FIELDS = ('violet', 'dusk', 'pink', 'sunset', 'sky', 'teal', 'peri', 'mono')
ZOOMS = ('today', 'stretch', 'arc')
STYLES = ('merged', 'calm', 'fields')
PALETTES = ('default', 'tide')
DENSITIES = ('comfortable', 'compact')
SIGNAL_SOURCES = ('dm', 'meeting', 'session', 'pr', 'ci', 'calendar', 'task', 'email', 'analytics', 'doc')
HOVER_KINDS = ('text', 'facts', 'spark', 'bars', 'flow', 'people', 'wait', 'strip', 'steps')
PERSON_STATES = ('waiting', 'blocked', 'done', 'idle', 'new')
TONES = ('ok', 'warn', 'red', 'neutral')

# Band caps. The app draws at most this many cards per band; a card past a cap is not drawn
# at all (there is no "+N more"), so the writer ranks each band and keeps the most important.
SUMMARY_MAX = 4      # the lead plus up to three
DROPPED_MAX = 5      # the dropped balls band
STREAM_MAX = 12
# Grid cells per size on the six-column grid (S 1x1, M 2x1, L 2x2, XL 4x2). The lead is XL, so
# the cards beside it must fill the remaining two columns by two rows: 4 cells, no hole.
SIZE_CELLS = {'S': 1, 'M': 2, 'L': 4, 'XL': 8}
BESIDE_LEAD = 4
TITLE_MAX_CHARS = 80
WHY_MAX_CHARS = 200
DUE_DAYS = 7         # a countdown this close is "due" (sunset); further out it is the record
PERSONAL = 'personal'

# Visual recipes (packages/ui/src/brief/widgets/visuals): id -> (family, kinds, types, fits).
# `fits` mirrors each recipe's own fits(): the card must hold the data the drawing shows.


def _num(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return v
    try:
        return float(str(v).replace(',', '').strip())
    except (TypeError, ValueError):
        return None


def _n(d, k):
    return _num(d.get(k)) or 0


def _len(d, k):
    v = d.get(k)
    return len(v) if isinstance(v, list) else 0


def _people(w):
    return _len(w['data'], 'people')


def _compare_rows(d):
    usual = _num(d.get('usual'))
    if usual and usual > 0 and (_num(d.get('hours')) or 0) > 0:
        return True
    if usual and usual > 0 and _num(d.get('value')) is not None and _num(d.get('value')) >= 0:
        return True
    return 2 <= _len(d, 'bars') <= 5


def _steps_or_ms(d):
    steps = [s for s in d.get('steps') or [] if isinstance(s, dict)]
    ms = [m for m in d.get('milestones') or [] if isinstance(m, dict)]
    return steps, ms


RECIPES = {
    # line icons
    'bell': ('line', ('note',), ('landed',), lambda w: w['kind'] == 'note' and w['type'] == 'landed'),
    'book': ('line', ('note',), ('learning',), lambda w: w['kind'] == 'note' and w['type'] == 'learning'),
    'fork': ('line', ('note',), ('decided', 'moved'), lambda w: w['kind'] == 'note' and w['type'] in ('decided', 'moved')),
    'agenda': ('line', ('note', 'countdown'), ('meeting',), lambda w: w['type'] == 'meeting'),
    'trace': ('line', ('note',), ('broke',), lambda w: w['kind'] == 'note' and w['type'] == 'broke' and bool(w['data'].get('to'))),
    'tally': ('line', ('stat', 'trend'), ('landed', 'moved', 'campaign', 'launch', 'task', 'summary', 'client', 'learning', 'ask'),
              lambda w: (lambda v: v is not None and float(v).is_integer() and 1 <= v <= 500)(_num(w['data'].get('value')))),
    'compare': ('line', ('stat', 'ask', 'ball', 'trend'), ('stalled', 'dropped', 'ask', 'broke', 'client', 'task', 'campaign', 'moved'),
                lambda w: _compare_rows(w['data'])),
    'checklist': ('line', ('progress',), ('learning', 'task', 'stalled', 'ask', 'campaign', 'launch'),
                  lambda w: _len(w['data'], 'steps') >= 2),
    'sparkline': ('line', ('trend', 'stat'), ('landed', 'moved', 'campaign', 'summary', 'learning', 'launch', 'task'),
                  lambda w: _len(w['data'], 'spark') >= 3),
    'letters': ('line', ('people', 'ask', 'ball', 'stat'), ('ask', 'client', 'dropped', 'stalled', 'moved', 'learning', 'task'),
                lambda w: _people(w) >= 1),
    'clock': ('line', ('ball', 'ask', 'stat', 'people'), ('dropped', 'ask', 'stalled', 'client', 'task', 'broke'),
              lambda w: _n(w['data'], 'hours') > 0),
    'track': ('line', ('progress', 'countdown'), ('launch', 'campaign', 'task', 'learning', 'stalled', 'ask', 'meeting', 'moved'),
              lambda w: _len(w['data'], 'steps') >= 2 or _len(w['data'], 'milestones') >= 1
              or (w['data'].get('days') is not None and _n(w['data'], 'total') > 0)),
    'stack': ('line', ('stat', 'trend'), ('landed',), lambda w: w['type'] == 'landed' and _n(w['data'], 'value') >= 1),
    'siren': ('line', ('stat', 'note', 'ball', 'strip'), ('broke',), lambda w: w['type'] == 'broke' and _n(w['data'], 'value') >= 1),
    # pixel scenes
    'harbor': ('pixel', ('trend', 'stat'), ('landed',), lambda w: w['type'] == 'landed' and _n(w['data'], 'value') >= 2),
    'tide': ('pixel', ('ball', 'ask', 'stat'), ('stalled', 'ask', 'dropped', 'client', 'task'),
             lambda w: _n(w['data'], 'hours') > 0 or _n(w['data'], 'value') > 0),
    'train': ('pixel', ('progress', 'countdown'), ('launch', 'campaign', 'task', 'moved'),
              lambda w: (lambda s, m: (len(s) >= 2 or len(m) >= 2) and any(x.get('done') for x in s + m))(*_steps_or_ms(w['data']))),
    'garden': ('pixel', ('stat', 'trend', 'progress'), ('landed', 'learning'),
               lambda w: _n(w['data'], 'value') >= 2 or _len(w['data'], 'bars') >= 2 or _len(w['data'], 'steps') >= 2
               or _len(w['data'], 'spark') >= 2),
    'mailbox': ('pixel', ('people', 'ask', 'ball'), ('ask', 'client', 'dropped', 'stalled'), lambda w: _people(w) >= 2),
    'fuse': ('pixel', ('countdown', 'progress'), ('launch', 'campaign', 'task'),
             lambda w: (w['data'].get('days') is not None and _n(w['data'], 'days') >= 0 and _n(w['data'], 'total') > 0)
             or _len(w['data'], 'milestones') > 0),
    'dawn': ('pixel', ('progress', 'countdown'), ('learning', 'task', 'campaign', 'launch', 'stalled', 'ask'),
             lambda w: (lambda s: len(s) >= 2 and any(x.get('done') for x in s))(_steps_or_ms(w['data'])[0])
             or (_n(w['data'], 'total') >= 2 and _n(w['data'], 'done') >= 1)),
    'switch': ('pixel', ('note',), ('decided', 'moved'), lambda w: w['kind'] == 'note' and w['type'] in ('decided', 'moved')),
    'weather': ('pixel', ('stat', 'note', 'strip'), ('broke',),
                lambda w: w['type'] == 'broke' and _num(w['data'].get('value')) is not None and _num(w['data'].get('value')) >= 0),
    'lighthouse': ('pixel', ('note', 'stat', 'ball'), ('broke',), lambda w: w['type'] == 'broke' and _n(w['data'], 'value') >= 1),
    'skyline': ('pixel', ('trend', 'stat'), ('landed', 'moved', 'campaign', 'summary', 'learning', 'launch'),
                lambda w: _len(w['data'], 'spark') >= 4 and max([_num(x) or 0 for x in w['data']['spark']] or [0]) > 0),
    'constellation': ('pixel', ('people', 'ask', 'ball'), ('ask', 'client', 'stalled', 'dropped'), lambda w: _people(w) >= 2),
    # iso objects
    'dial': ('iso', ('ball', 'ask', 'stat', 'people'), ('dropped', 'ask', 'stalled', 'client', 'task'),
             lambda w: _n(w['data'], 'hours') > 0),
    'breaker': ('iso', ('note', 'stat'), ('broke',), lambda w: w['type'] == 'broke' and bool(w['data'].get('to'))),
    'lock': ('iso', ('ask', 'people', 'ball', 'stat'), ('ask', 'stalled', 'decided', 'task', 'client'), lambda w: _people(w) >= 1),
    'drawers': ('iso', ('people', 'ask', 'ball'), ('ask', 'dropped', 'stalled', 'client', 'task'),
                lambda w: _people(w) >= 2 and any((_num((p or {}).get('hours')) or 0) > 0 for p in w['data']['people'])),
    'scale': ('iso', ('stat', 'trend', 'people'), ('decided', 'moved', 'summary', 'landed', 'campaign', 'learning'),
              lambda w: _len(w['data'], 'bars') >= 2 or (_num(w['data'].get('value')) is not None and _n(w['data'], 'usual') > 0)),
    'rocket': ('iso', ('countdown', 'progress'), ('launch', 'campaign'),
               lambda w: _len(w['data'], 'milestones') >= 1 and w['data'].get('days') is not None and _n(w['data'], 'days') >= 0),
}
FAMILY_CAP = {'pixel': 3, 'iso': 2}


def merged_field(w):
    """The colour a card wears in the merged style (brief-page.ts mergedField): one meaning
    each. Dusk the lead; pink dropped; sunset broke, a launch, or a task due within a week;
    violet your move; teal landed or learned; graphite (mono) the record."""
    kind, typ, data = w.get('kind'), w.get('type'), w.get('data') if isinstance(w.get('data'), dict) else {}
    if kind == 'focus' or typ == 'summary':
        return 'dusk'
    if typ == 'dropped':
        return 'pink'
    if typ == 'broke':
        return 'sunset'
    if typ in ('launch', 'task'):
        days = _num(data.get('days'))
        if kind == 'countdown' and days is not None and days > DUE_DAYS:
            return 'mono'
        return 'sunset' if typ == 'launch' else 'violet'
    if typ in ('ask', 'client'):
        return 'violet'
    if typ in ('landed', 'learning'):
        return 'teal'
    return 'mono'


def zoom_for(hours_away):
    if hours_away < 18:
        return 'today'
    if hours_away <= 72:
        return 'stretch'
    return 'arc'


# ---------- validator ----------

def _sibling(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + '.py')
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_LINT = []


def _lint_title(title):
    if not _LINT:
        try:
            _LINT.append(_sibling('brief_rank').lint_title)
        except Exception:
            _LINT.append(lambda t, repos=(): [] if (t or '').strip() else ['empty title'])
    return _LINT[0](title)


def _is_str(v, allow_empty=False):
    return isinstance(v, str) and (allow_empty or bool(v.strip()))


def _check_people(people, where, err, warn=None):
    if not isinstance(people, list):
        err(where, 'must be a list')
        return
    for i, p in enumerate(people):
        if not isinstance(p, dict) or not _is_str(p.get('name')):
            err(f'{where}[{i}]', 'a person needs a name')
            continue
        if warn and not p.get('agent') and _bc().looks_like_handle(p['name']):
            warn(f'{where}[{i}].name', f'{p["name"]!r} looks like a handle; use the person\'s first name')
        if p.get('state') is not None and p['state'] not in PERSON_STATES:
            err(f'{where}[{i}].state', f'unknown state {p["state"]!r}')
        for k in ('hours', 'usual'):
            if p.get(k) is not None and (_num(p[k]) is None or _num(p[k]) < 0):
                err(f'{where}[{i}].{k}', 'must be a number of hours, 0 or more')


def _check_ticks(ticks, where, err):
    if ticks is None:
        return
    if not isinstance(ticks, list) or not all(isinstance(t, str) for t in ticks):
        err(where, 'must be a list of labels')
        return
    for i, t in enumerate(ticks):
        if _ISO_TICK.search(t):
            err(f'{where}[{i}]', f'{t!r} is a timestamp; chart labels read like "Fri morning" or "Mon 3 pm"')


def _items(v, where, err):
    """`v` when it is a list, [] when absent; anything else is an error and reads as []."""
    if v is None:
        return []
    if not isinstance(v, list):
        err(where, 'must be a list')
        return []
    return v


def _check_data(w, where, err, warn=None):
    d = w.get('data')
    if not isinstance(d, dict):
        err(f'{where}.data', 'must be an object')
        return
    for k in ('hours', 'usual', 'days', 'done', 'total'):
        if d.get(k) is not None and (_num(d[k]) is None or _num(d[k]) < 0):
            err(f'{where}.data.{k}', 'must be a number, 0 or more')
    if d.get('ring') is not None and not (0 <= (_num(d['ring']) if _num(d['ring']) is not None else -1) <= 1):
        err(f'{where}.data.ring', 'must be between 0 and 1')
    if d.get('spark') is not None and (not isinstance(d['spark'], list) or any(_num(x) is None for x in d['spark'])):
        err(f'{where}.data.spark', 'must be a list of numbers')
    for k in ('bars',):
        for i, b in enumerate(_items(d.get(k), f'{where}.data.{k}', err)):
            if not isinstance(b, dict) or not _is_str(b.get('label')) or _num(b.get('value')) is None:
                err(f'{where}.data.{k}[{i}]', 'needs a label and a number value')
    for i, b in enumerate(_items(d.get('bets'), f'{where}.data.bets', err)):
        if not isinstance(b, dict) or not _is_str(b.get('label')) or _num(b.get('share')) is None \
                or not 0 <= _num(b.get('share')) <= 1:
            err(f'{where}.data.bets[{i}]', 'needs a label and a share between 0 and 1')
    for i, m in enumerate(_items(d.get('milestones'), f'{where}.data.milestones', err)):
        if not isinstance(m, dict) or not _is_str(m.get('label')) or _num(m.get('at')) is None or not 0 <= _num(m.get('at')) <= 1:
            err(f'{where}.data.milestones[{i}]', 'needs a label and `at` between 0 and 1')
    for i, s in enumerate(_items(d.get('steps'), f'{where}.data.steps', err)):
        if not isinstance(s, dict) or not _is_str(s.get('label')) or not isinstance(s.get('done'), bool):
            err(f'{where}.data.steps[{i}]', 'needs a label and done true or false')
    if d.get('people') is not None:
        _check_people(d['people'], f'{where}.data.people', err, warn)
    for k in ('stats',):
        for i, x in enumerate(_items(d.get(k), f'{where}.data.{k}', err)):
            if not isinstance(x, dict) or not isinstance(x.get('label'), str) or not isinstance(x.get('value'), (str, int, float)):
                err(f'{where}.data.{k}[{i}]', 'needs a label and a value')
    for k in ('headline', 'accent', 'unit', 'caption', 'delta', 'pickup', 'from', 'to', 'date', 'sparkLabel'):
        if d.get(k) is not None and not isinstance(d[k], str):
            err(f'{where}.data.{k}', 'must be text')
    _check_ticks(d.get('ticks'), f'{where}.data.ticks', err)
    if d.get('quote') is not None and (not isinstance(d['quote'], dict) or not _is_str(d['quote'].get('text'))):
        err(f'{where}.data.quote', 'needs text')
    marks = d.get('marks')
    if marks is not None:
        n = len(d['spark']) if isinstance(d.get('spark'), list) else 0
        for i, m in enumerate(marks if isinstance(marks, list) else [None]):
            if not isinstance(m, dict) or not _is_str(m.get('label')) or not isinstance(m.get('i'), int) or not 0 <= m['i'] < max(n, 1):
                err(f'{where}.data.marks[{i}]', 'needs a label and an index into spark')


def _check_hover(blocks, where, err, warn=None):
    if not isinstance(blocks, list):
        err(where, 'must be a list')
        return
    for i, b in enumerate(blocks):
        if not isinstance(b, dict) or b.get('kind') not in HOVER_KINDS:
            err(f'{where}[{i}]', f'kind must be one of {", ".join(HOVER_KINDS)}')
            continue
        k = b['kind']
        if k == 'text' and not _is_str(b.get('text')):
            err(f'{where}[{i}]', 'text block needs text')
        if k == 'facts' and not all(isinstance(x, dict) and _is_str(x.get('label')) and isinstance(x.get('value'), str)
                                    for x in (b.get('items') if isinstance(b.get('items'), list) and b['items'] else [None])):
            err(f'{where}[{i}]', 'facts need items of {label, value}')
        if k == 'spark' and (not isinstance(b.get('values'), list) or any(_num(x) is None for x in b['values'])):
            err(f'{where}[{i}]', 'spark needs numeric values')
        if k == 'bars' and not all(isinstance(x, dict) and _is_str(x.get('label')) and _num(x.get('value')) is not None
                                   for x in (b.get('items') if isinstance(b.get('items'), list) and b['items'] else [None])):
            err(f'{where}[{i}]', 'bars need items of {label, value}')
        if k == 'people':
            _check_people(b.get('people'), f'{where}[{i}].people', err, warn)
        if k == 'spark':
            _check_ticks(b.get('ticks'), f'{where}[{i}].ticks', err)
        if k == 'wait' and (_num(b.get('hours')) is None or _num(b['hours']) < 0):
            err(f'{where}[{i}]', 'wait needs hours')
        if k == 'flow':
            flow = b.get('flow')
            if not isinstance(flow, dict) or not isinstance(flow.get('nodes'), list) or not isinstance(flow.get('edges'), list):
                err(f'{where}[{i}]', 'flow needs nodes and edges')
        if k == 'steps' and not all(isinstance(s, dict) and _is_str(s.get('label')) and isinstance(s.get('done'), bool)
                                    for s in (b.get('steps') if isinstance(b.get('steps'), list) and b['steps'] else [None])):
            err(f'{where}[{i}]', 'steps need {label, done}')
        if k == 'strip' and not isinstance(b.get('days'), list):
            err(f'{where}[{i}]', 'strip needs days')


def _check_drill(drill, where, err, warn=None):
    if not isinstance(drill, dict):
        err(where, 'must be an object')
        return
    sigs = drill.get('signals')
    if not isinstance(sigs, list):
        err(f'{where}.signals', 'must be a list')
        sigs = []
    for i, s in enumerate(sigs):
        if not isinstance(s, dict) or s.get('source') not in SIGNAL_SOURCES or not _is_str(s.get('text')):
            err(f'{where}.signals[{i}]', f'needs text and a source of {", ".join(SIGNAL_SOURCES)}')
    for i, c in enumerate(_items(drill.get('changed'), f'{where}.changed', err)):
        if not isinstance(c, dict) or not _is_str(c.get('label')) or not isinstance(c.get('to'), str):
            err(f'{where}.changed[{i}]', 'needs a label and to')
    if drill.get('people') is not None:
        _check_people(drill['people'], f'{where}.people', err, warn)
    for k in ('prompt', 'bot'):
        if drill.get(k) is not None and not _is_str(drill[k]):
            err(f'{where}.{k}', 'must be text')


def validate_page(page):
    """_validate, which never raises here: malformed input of any shape is an error."""
    try:
        return _validate(page)
    except Exception as e:  # a gap in the checks below: still a rejection, never a crash
        return {'ok': False, 'errors': [{'where': 'page', 'problem': f'malformed page ({type(e).__name__})'}], 'warnings': []}


def _validate(page):
    """{'ok': bool, 'errors': [{where, problem}], 'warnings': [...]} for one page.

    Errors are format breaks and design-rule breaks the app would draw wrong: a missing lead,
    a colour that means something else, a card with no company, a drawing with nothing real
    to draw, a title that names a repo. Warnings are things the app corrects on its own."""
    errors, warnings = [], []

    def err(where, problem):
        errors.append({'where': where, 'problem': problem})

    def warn(where, problem):
        warnings.append({'where': where, 'problem': problem})

    if not isinstance(page, dict):
        err('page', 'must be an object')
        return {'ok': False, 'errors': errors, 'warnings': warnings}
    if page.get('version') != 1:
        err('version', 'must be 1')
    person = page.get('person')
    if not isinstance(person, dict) or not _is_str(person.get('name')):
        err('person.name', 'required')
    win = page.get('window')
    if not isinstance(win, dict):
        err('window', 'required')
    else:
        for k in ('from', 'to', 'label'):
            if not _is_str(win.get(k)):
                err(f'window.{k}', 'required text')
        if win.get('zoom') not in ZOOMS:
            err('window.zoom', f'must be one of {", ".join(ZOOMS)}')
        h = _num(win.get('hoursAway'))
        if h is None or h < 0:
            err('window.hoursAway', 'must be a number of hours, 0 or more')
        elif win.get('zoom') in ZOOMS and win['zoom'] != zoom_for(h):
            warn('window.zoom', f'{h} hours away reads as {zoom_for(h)}')
    theme = page.get('theme')
    if theme is not None:
        if not isinstance(theme, dict):
            err('theme', 'must be an object')
        else:
            for k, allowed in (('style', STYLES), ('palette', PALETTES), ('density', DENSITIES)):
                if theme.get(k) is not None and theme[k] not in allowed:
                    err(f'theme.{k}', f'must be one of {", ".join(allowed)}')
    companies = page.get('companies')
    if companies is not None and (not isinstance(companies, dict)
                                  or not all(isinstance(v, dict) and _is_str(v.get('name')) for v in companies.values())):
        err('companies', 'must map each slug to {name}')
        companies = {}
    companies = companies or {}

    bands = {}
    for band in ('summary', 'dropped', 'stream'):
        v = page.get(band)
        if not isinstance(v, list):
            err(band, 'must be a list')
            v = []
        bands[band] = v
    if len(bands['summary']) > SUMMARY_MAX:
        err('summary', f'{len(bands["summary"])} cards (max {SUMMARY_MAX}: the lead and up to three)')
    if len(bands['dropped']) > DROPPED_MAX:
        err('dropped', f'{len(bands["dropped"])} dropped balls (max {DROPPED_MAX})')
    if len(bands['stream']) > STREAM_MAX:
        err('stream', f'{len(bands["stream"])} cards (max {STREAM_MAX})')

    lead = bands['summary'][0] if bands['summary'] else None
    if not isinstance(lead, dict) or lead.get('size') != 'XL' or lead.get('kind') not in ('focus', 'strip') \
            or lead.get('type') != 'summary':
        err('summary[0]', 'the page needs a lead card first: size XL, kind focus (or strip), type summary')
    else:
        beside = bands['summary'][1:]
        cells = sum(SIZE_CELLS.get(w.get('size'), 0) for w in beside if isinstance(w, dict) and isinstance(w.get('size'), str))
        if cells != BESIDE_LEAD:
            err('summary', f'the cards beside the lead fill {cells} of its {BESIDE_LEAD} cells (S 1, M 2, L 4); '
                           'use M+S+S, M+M or one L so the band has no gap')

    seen, used_family, named_ids = set(), {'pixel': 0, 'iso': 0}, {}
    for band, ws in bands.items():
        for i, w in enumerate(ws):
            where = f'{band}[{i}]'
            if not isinstance(w, dict):
                err(where, 'must be an object')
                continue
            try:
                _check_card(w, band, i, where, companies, seen, used_family, named_ids, err, warn)
            except Exception as e:  # never crash on a malformed card: reject it
                err(where, f'malformed card ({type(e).__name__})')
    return {'ok': not errors, 'errors': errors, 'warnings': warnings}


def _check_card(w, band, i, where, companies, seen, used_family, named_ids, err, warn):
    """Every check on one card; errors and warnings go through err and warn."""
    wid = w.get('id')
    if not _is_str(wid):
        err(f'{where}.id', 'required')
    elif not isinstance(wid, str):
        err(f'{where}.id', 'must be text')
    elif wid in seen:
        err(f'{where}.id', f'duplicate id {wid!r}')
    else:
        seen.add(wid)
        where = f'{band}[{i}] {wid}'
    kind, size, typ = (v if isinstance(v, str) else None for v in (w.get('kind'), w.get('size'), w.get('type')))
    if kind not in KINDS:
        err(f'{where}.kind', f'must be one of {", ".join(KINDS)}')
    if size not in SIZES:
        err(f'{where}.size', f'must be one of {", ".join(SIZES)}')
    if typ not in TYPES:
        err(f'{where}.type', f'must be one of {", ".join(TYPES)}')
    if not _is_str(w.get('symbol')):
        err(f'{where}.symbol', 'required (a Phosphor glyph name)')
    title = w.get('title')
    if not _is_str(title):
        err(f'{where}.title', 'required')
    else:
        if len(title) > TITLE_MAX_CHARS:
            err(f'{where}.title', f'{len(title)} characters (max {TITLE_MAX_CHARS})')
        problems = _lint_title(title)
        if problems:
            err(f'{where}.title', 'title rule: ' + '; '.join(problems))
    if w.get('why') is not None and (not isinstance(w['why'], str) or len(w['why']) > WHY_MAX_CHARS):
        err(f'{where}.why', f'must be one sentence (max {WHY_MAX_CHARS} characters)')
    is_lead = band == 'summary' and i == 0
    # One meaning per colour: a card wears its type's colour, never another.
    if w.get('field') is not None:
        if w['field'] not in FIELDS:
            err(f'{where}.field', f'must be one of {", ".join(FIELDS)}')
        elif isinstance(w.get('data'), dict) and w['field'] != merged_field(w):
            err(f'{where}.field', f'{w["field"]} means something else here; a {typ} card is {merged_field(w)}. '
                                  'Leave field out and let the type pick it')
    if size == 'XL' and not is_lead:
        err(f'{where}.size', 'only the lead card is XL')
    if typ == 'dropped' and band != 'dropped':
        err(f'{where}.type', 'a dropped ball goes in the dropped band (pink means dropped)')
    if band == 'dropped':
        if typ != 'dropped' or kind != 'ball':
            err(where, 'a dropped ball is kind ball, type dropped')
        if not _is_str(_dict(w.get('data')).get('pickup')):
            err(f'{where}.data.pickup', 'a dropped ball needs its one-press pick-up')
    if typ == 'summary' and not is_lead:
        err(f'{where}.type', 'type summary is the lead card only')
    company = w.get('company')
    d0 = w.get('data') if isinstance(w.get('data'), dict) else {}
    names_people = bool(d0.get('people') or d0.get('quote') or _dict(w.get('drill')).get('people')
                        or _dict(w.get('drill')).get('signals'))
    if company is None:
        if not is_lead and not (band == 'summary' and not names_people):
            err(f'{where}.company', 'every card carries its company slug (personal for your own work); '
                                    'only a count-only summary card may span companies')
    elif not _is_str(company) or company not in companies:
        err(f'{where}.company', f'{company!r} is not in page.companies')
    _check_data(w, where, err, warn)
    if w.get('hover') is not None:
        _check_hover(w['hover'], f'{where}.hover', err, warn)
    if w.get('drill') is not None:
        _check_drill(w['drill'], f'{where}.drill', err, warn)
    vis = w['data'].get('visual') if isinstance(w.get('data'), dict) else None
    if vis is not None and not isinstance(vis, str):
        err(f'{where}.data.visual', 'must be a drawing id (text)')
    elif vis is not None:
        spec = RECIPES.get(vis)
        if spec is None:
            err(f'{where}.data.visual', f'unknown drawing {vis!r}; use one of {", ".join(sorted(RECIPES))} or leave it out')
        elif kind in KINDS and typ in TYPES and isinstance(w.get('data'), dict):
            family, kinds, types, fits = spec
            if kind not in kinds and typ not in types:
                err(f'{where}.data.visual', f'{vis} draws {"/".join(kinds)} or {"/".join(types)} cards, not {kind}/{typ}')
            elif not fits(w):
                err(f'{where}.data.visual', f'{vis} has nothing real to draw on this card; add the data it reads or leave it out')
            else:
                named_ids[vis] = named_ids.get(vis, 0) + 1
                if named_ids[vis] == 3:
                    warn(f'{where}.data.visual', f'{vis} is named three times; leave visual out on some cards so the page varies')
                if family in FAMILY_CAP:
                    used_family[family] += 1
                    if used_family[family] > FAMILY_CAP[family]:
                        warn(f'{where}.data.visual', f'more than {FAMILY_CAP[family]} {family} drawings; the app picks another')


# ---------- skeleton ----------

def _ts(s):
    if not s:
        return None
    try:
        t = dt.datetime.fromisoformat(str(s).replace('Z', '+00:00'))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


def _hours(since, now):
    t = _ts(since)
    return round(max(0.0, (now - t).total_seconds() / 3600), 1) if t else None


_ISO_TICK = re.compile(r'\d{4}-\d{2}-\d{2}|T\d{2}:\d{2}|\d{1,2}:\d{2}(:\d{2})?(\+|Z|$)')
_BC = []


def _bc():
    if not _BC:
        _BC.append(_sibling('brief_company'))
    return _BC[0]


def _local_tz():
    return dt.datetime.now().astimezone().tzinfo


def day_part(t):
    """(date the part belongs to, part): morning 5-12, afternoon 12-17, evening 17-21, and
    night until 5 the next morning, which belongs to the evening's day."""
    h = t.hour
    if h < 5:
        return t.date() - dt.timedelta(days=1), 'night'
    if h < 12:
        return t.date(), 'morning'
    if h < 17:
        return t.date(), 'afternoon'
    if h < 21:
        return t.date(), 'evening'
    return t.date(), 'night'


def _hour_label(t):
    h = t.hour % 12 or 12
    return f'{h} {"am" if t.hour < 12 else "pm"}'


def tick_labels(start, end, n=4, tz=None):
    """`n` chart labels evenly across start..end in local time, the way the fixtures
    write them: "Fri morning", "Sat night". When two would read the same (a short
    window), every label names the hour instead: "Mon 9 am", "Mon 3 pm"."""
    tz = tz or _local_tz()
    a, b = start.astimezone(tz), end.astimezone(tz)
    pts = [a + (b - a) * (i / (n - 1)) for i in range(n)] if n > 1 else [b]
    parts = [day_part(t) for t in pts]
    labels = [f'{d.strftime("%a")} {part}' for d, part in parts]
    if len(set(labels)) < len(labels):
        labels = [f'{t.strftime("%a")} {_hour_label(t)}' for t in pts]
    if len(set(labels)) < len(labels):
        labels = [_hour_label(t) for t in pts]
    return labels


def person_name(*raw):
    """The first usable display name: a resolved name, else the raw name's first word."""
    bc = _bc()
    raw = [r for r in raw if isinstance(r, str) and r.strip()]
    for r in raw:
        if not bc.looks_like_handle(r):
            return bc.first_name(r)
    return raw[0] if raw else 'Someone'


TYPE_RANK = {'ask': 0, 'task': 1, 'meeting': 2, 'broke': 3, 'stalled': 4, 'landed': 5}
# Pull requests and CI matter to the few people who run builds; for everyone else they are
# background. Cards whose evidence is only PRs or CI rank after every card about people,
# meetings and tasks.
CODE_SOURCES = ('pr', 'ci')


def is_code_card(c):
    sigs = _dict(c.get('drill')).get('signals') or []
    return bool(sigs) and all(_dict(s).get('source') in CODE_SOURCES for s in sigs)


def rank_candidates(cands):
    """Most important first, so the cards that fit under the band caps are the right ones:
    cards about people, meetings and tasks before PR and CI cards; within each, dropped-ball
    candidates by longest wait, then by type (asks, your tasks, meetings, broke, stalled,
    landed), then by longest wait. Ids are renumbered c1.. in that order."""
    def key(c):
        h = c['data'].get('hours') or 0
        return (1 if is_code_card(c) else 0, 0 if c.get('dropped_candidate') else 1, TYPE_RANK.get(c['type'], 9), -h)
    out = sorted(cands, key=key)
    for i, c in enumerate(out):
        c['id'] = f'c{i + 1}'
        c['rank'] = i + 1
    return out


def _dicts(v):
    """The dict rows of a list; [] for anything that is not a list."""
    return [x for x in v if isinstance(x, dict)] if isinstance(v, list) else []


def _dict(v):
    return v if isinstance(v, dict) else {}


def sections(data):
    """[(slug, section)] for brief-data.json: personal first, then each company. A personal
    section's slug is `personal`. Sections that failed (an `error`) are skipped, and so is
    anything that is not an object."""
    data = _dict(data)
    if data.get('mode') == 'person':
        out = [(PERSONAL, _dict(data.get('personal')))]
        out += [(slug, s) for slug, s in sorted(_dict(data.get('companies')).items()) if isinstance(slug, str)]
    else:
        co = data.get('company')
        out = [(co if isinstance(co, str) and co else PERSONAL, data)]
    return [(slug, s) for slug, s in out if isinstance(s, dict) and not s.get('error')]


def window_label(hours_away):
    if hours_away < 18:
        return f'Since your last brief, {round(hours_away)} hours ago'
    if hours_away <= 72:
        return f'The last {round(hours_away)} hours'
    return f'Back after {round(hours_away / 24)} days'


def day_spark(secs, start, end, buckets=6):
    """The person's own day per slice of the window, oldest first (the lead's pulse line):
    their meetings, their work sessions and the DMs that ask something of them."""
    a, b = _ts(start), _ts(end)
    if not a or not b or b <= a:
        return [0] * buckets
    span = (b - a).total_seconds()
    out = [0] * buckets
    stamps = []
    for _, s in secs or []:
        stamps += [m.get('start') for m in _dicts(s.get('meetings')) if m.get('attended')]
        stamps += [x.get('started_at') for x in _dicts(s.get('sessions')) if x.get('kind', 'you') == 'you']
        stamps += [m.get('at') for m in _dicts(s.get('dms')) if m.get('need_you') and not m.get('is_agent')]
    for st in stamps:
        t = _ts(st)
        if t and a <= t <= b:
            out[min(buckets - 1, int((t - a).total_seconds() / span * buckets))] += 1
    return out


def merge_spark(prs, start, end, buckets=6):
    """Your merged PRs per slice of the window, oldest first (the lead's pulse line)."""
    a, b = _ts(start), _ts(end)
    if not a or not b or b <= a:
        return [0] * buckets
    span = (b - a).total_seconds()
    out = [0] * buckets
    for p in prs or []:
        if p.get('state') != 'merged' or not p.get('authored_by_me', True):
            continue
        t = _ts(p.get('closed'))
        if t and a <= t <= b:
            out[min(buckets - 1, int((t - a).total_seconds() / span * buckets))] += 1
    return out


def _signal(source, text, at=None, limit=140):
    s = {'source': source, 'text': ' '.join(str(text or '').split())[:limit]}
    if at:
        s['at'] = at
    return s


def candidates(data, now):
    """Computed facts for every card the writer may place, each tagged with its company.

    Every number comes from brief-data.json (ages from timestamps, counts from rows). The
    writer picks among these, writes the title and why, and may merge or drop candidates;
    it never adds a fact that is not here or in brief-data.json."""
    data = _dict(data)
    out = []

    def add(c):
        c['id'] = f'c{len(out) + 1}'
        out.append(c)

    for slug, s in sections(data):
        # People waiting on you in DMs: one candidate per human sender with an ask.
        asks = {}
        for m in _dicts(s.get('dms')):
            if m.get('is_agent') or not m.get('need_you'):
                continue
            key = str(m.get('from_uid') or m.get('from'))
            asks.setdefault(key, []).append(m)
        for key, ms in asks.items():
            ms.sort(key=lambda m: str(m.get('at') or ''))
            h = _hours(ms[0].get('at'), now)
            name = person_name(ms[0].get('from_name'), ms[0].get('from'))
            add({'company': slug, 'type': 'ask', 'kind': 'ask', 'size': 'M', 'symbol': 'chat-circle-dots',
                 'basis': ms[0].get('company_basis'), 'dropped_candidate': bool(h and h >= 24),
                 'data': {'hours': h, 'people': [{'name': name, 'state': 'waiting', 'hours': h}]},
                 'drill': {'signals': [_signal('dm', m.get('preview'), m.get('at')) for m in ms[:4]]},
                 'facts': {'from': name, 'messages': len(ms), 'age_hours': h}})
        prs = _dicts(s.get('prs'))
        for p in prs:
            if p.get('state') != 'open':
                continue
            h = _hours(p.get('created'), now)
            origin = {'repo': p.get('repo_full') or p.get('repo'), 'number': p.get('number'), 'url': p.get('url')}
            if p.get('review_requested') and not p.get('authored_by_me'):
                who = person_name(p.get('author_name'), p.get('author')) if p.get('author') else 'A teammate'
                add({'company': slug, 'type': 'ask', 'kind': 'ask', 'size': 'M', 'symbol': 'git-pull-request',
                     'dropped_candidate': bool(h and h >= 24),
                     'data': {'hours': h, 'people': [{'name': who, 'state': 'waiting', 'hours': h}]},
                     'drill': {'signals': [_signal('pr', p.get('title'), p.get('created'))]},
                     'facts': {'product': p.get('product'), 'age_hours': h, 'origin': origin}})
            elif p.get('authored_by_me') and not p.get('isDraft') and p.get('reviewDecision') != 'APPROVED' and h and h >= 24:
                add({'company': slug, 'type': 'stalled', 'kind': 'stat', 'size': 'S', 'symbol': 'hourglass',
                     'data': {'hours': h, 'value': round(h), 'unit': 'h'},
                     'drill': {'signals': [_signal('pr', p.get('title'), p.get('created'))]},
                     'facts': {'product': p.get('product'), 'reviewers': p.get('reviewers') or [], 'age_hours': h, 'origin': origin}})
        win = _dict(s.get('window')) or _dict(data.get('window'))
        merged = [p for p in prs if p.get('state') == 'merged' and p.get('authored_by_me', True)
                  and _ts(p.get('closed')) and _ts(win.get('prs_from')) and _ts(p['closed']) >= _ts(win['prs_from'])]
        if merged:
            by_product = {}
            for p in merged:
                label = str(p.get('product') or p.get('repo') or 'Other')
                by_product[label] = by_product.get(label, 0) + 1
            bars = [{'label': k, 'value': v} for k, v in sorted(by_product.items(), key=lambda kv: -kv[1])[:5]]
            n = len(merged)
            add({'company': slug, 'type': 'landed', 'kind': 'stat', 'size': 'M' if n >= 2 else 'S', 'symbol': 'git-merge',
                 'data': {'value': n, 'unit': 'merged', 'bars': bars,
                          'spark': merge_spark(merged, win.get('prs_from'), win.get('prs_to')),
                          'visual': 'stack'},
                 'drill': {'signals': [_signal('pr', p.get('title'), p.get('closed')) for p in merged[:4]]},
                 'facts': {'merged': n, 'by_product': by_product}})
        for repo, h in sorted((k, v) for k, v in _dict(s.get('main_health')).items() if isinstance(k, str)):
            h = _dict(h)
            for r in _dicts(h.get('red')):
                hrs = _hours(r.get('since'), now)
                on_top = _num(r.get('merges_on_top')) or 0
                add({'company': slug, 'type': 'broke', 'kind': 'stat', 'size': 'M', 'symbol': 'warning',
                     'data': {'hours': hrs, 'value': on_top, 'unit': 'merged on top',
                              'visual': 'siren' if on_top >= 1 else None},
                     'drill': {'signals': [_signal('ci', f'{r.get("workflow")} red on main', r.get('since'))]},
                     'facts': {'product': (h or {}).get('product'), 'workflow': r.get('workflow'), 'age_hours': hrs, 'repo': repo}})
        # Stale signals: with a last good run the to-do cards say where they are from; with none
        # they are left out, and the notice card says so.
        stale = _dict(s.get('signals_stale'))
        stale = stale if _is_str(stale.get('line')) else {}
        left_out = bool(stale) and not _good_date(stale)
        for mtg in ([] if left_out else _dicts(s.get('meeting_signals'))):
            for a in _dicts(mtg.get('action_items')):
                if not a.get('mine'):
                    continue
                h = _hours(mtg.get('start') or mtg.get('date'), now)
                facts = {'meeting': mtg.get('title'), 'age_hours': h}
                if stale:
                    facts['signals_from'] = stale.get('section_line')
                add({'company': slug, 'type': 'task', 'kind': 'note', 'size': 'M', 'symbol': 'list-checks',
                     'data': {'hours': h},
                     'drill': {'signals': [_signal('meeting', a.get('text'), mtg.get('start'))]},
                     'facts': facts})
        attended = [m for m in _dicts(s.get('meetings')) if m.get('attended')]
        team = sum(1 for m in _dicts(s.get('meetings')) if not m.get('attended'))
        if attended:
            add({'company': slug, 'type': 'meeting', 'kind': 'note', 'size': 'S', 'symbol': 'video-camera',
                 'data': {'value': len(attended), 'unit': 'meetings', 'visual': 'agenda'},
                 'drill': {'signals': [_signal('meeting', m.get('title'), m.get('start')) for m in attended[:4]]},
                 'facts': {'meetings': len(attended), 'team_meetings': team}})
        for a in _dicts(_dict(s.get('fleet')).get('stuck')):
            h = _hours(a.get('since'), now)
            add({'company': slug, 'type': 'broke', 'kind': 'note', 'size': 'S', 'symbol': 'robot',
                 'data': {'hours': h, 'to': a.get('status') or a.get('phase')},
                 'drill': {'signals': [_signal('session', f'{a.get("name")} is {a.get("status") or a.get("phase")}', a.get('since'))]},
                 'facts': {'agent': a.get('name'), 'age_hours': h}})
    # A drawing is suggested only where one recipe clearly carries the card (a landed count, a red
    # main with merges on top, meetings); elsewhere the app's picker spreads the page across the
    # library. Keep a suggestion only when it has something real to draw.
    for c in out:
        vis = c['data'].get('visual')
        spec = RECIPES.get(vis)
        if vis and (not spec or not spec[3](c)):
            del c['data']['visual']
        c['data'] = {k: v for k, v in c['data'].items() if v is not None}
    return rank_candidates(out)


def summary_side(cands, data):
    """The cards beside the lead, filling its two columns by two rows (4 cells): the people
    waiting on you in the company with the most of them (M, with that company), then count
    cards (red checks, your PRs waiting for review, merged, meetings) that span the page and
    name nobody. Sizes: people M + two counts S, people M + one count M, people alone L,
    or with no people M + S + S, M + M or L. Titles are the writer's."""
    side = []
    asks = {}
    for c in cands:
        if c['type'] == 'ask':
            asks.setdefault(c['company'], []).append(c)
    if asks:
        slug, cs = max(asks.items(), key=lambda kv: (len(kv[1]), -min(c['rank'] for c in kv[1])))
        # One row per person (their longest wait), longest first.
        by_name = {}
        for c in cs:
            p = c['data']['people'][0]
            if p['name'] not in by_name or (p.get('hours') or 0) > (by_name[p['name']].get('hours') or 0):
                by_name[p['name']] = dict(p)
        people = sorted(by_name.values(), key=lambda p: -(p.get('hours') or 0))[:5]
        side.append({'id': 'waiting', 'kind': 'people', 'type': 'ask', 'size': 'M', 'symbol': 'users-three',
                     'company': slug, 'title': '',
                     'data': {k: v for k, v in {'people': people, 'value': len(by_name), 'hours': max((p.get('hours') or 0) for p in people) or None}.items() if v is not None},
                     'drill': {'signals': [c['drill']['signals'][0] for c in cs[:4] if c['drill']['signals']]}})
    # Counts about the person's own day only: their to-dos and their meetings. PR and CI
    # counts stay out of the summary band; those cards, when they matter, sit in the stream.
    counts = []
    n = sum(1 for c in cands if c['type'] == 'task')
    if n:
        counts.append({'id': 'todos', 'kind': 'stat', 'type': 'task', 'symbol': 'list-checks',
                       'data': {'value': n, 'unit': 'to-dos for you'}})
    n = sum(c['data'].get('value', 0) for c in cands if c['type'] == 'meeting')
    if n:
        counts.append({'id': 'meetings', 'kind': 'stat', 'type': 'meeting', 'symbol': 'video-camera',
                       'data': {'value': n, 'unit': 'your meetings'}})
    for c in counts:
        c['title'] = ''
    if side:
        if len(counts) >= 2:
            side += [dict(counts[0], size='S'), dict(counts[1], size='S')]
        elif counts:
            side.append(dict(counts[0], size='M'))
        else:
            side[0]['size'] = 'L'
    elif len(counts) >= 3:
        side = [dict(counts[0], size='M'), dict(counts[1], size='S'), dict(counts[2], size='S')]
    elif len(counts) == 2:
        side = [dict(counts[0], size='M'), dict(counts[1], size='M')]
    elif counts:
        side = [dict(counts[0], size='L')]
    return side


def skeleton(data, person, now, names=None, cands=None, tz=None):
    """The page frame: everything deterministic. The lead card carries the window's real
    numbers with human chart labels, and the summary band is filled beside it with real
    cards (summary_side); their titles, the lead's headline and bets are the writer's.
    The dropped and stream bands start empty."""
    names = names or {}
    cands = candidates(data, now) if cands is None else cands
    secs = sections(data)
    companies = {slug: {'name': 'Personal' if slug == PERSONAL else names.get(slug, slug)} for slug, _ in secs}
    data = _dict(data)
    win = _dict(data.get('window'))
    prev = _dict(data.get('previous_run')).get('generated_at')
    end = _ts(win.get('sessions_to')) or now
    start = _ts(prev) or _ts(win.get('sessions_from')) or (end - dt.timedelta(hours=24))
    hours_away = round(max(0.0, (end - start).total_seconds() / 3600), 1)
    spark = day_spark(secs, start.isoformat(), end.isoformat())
    # People waiting on you: each human DM sender with an ask. Review requests are left to
    # the PR cards further down the page.
    waiting = len({(slug, str(m.get('from_uid') or m.get('from'))) for slug, s in secs for m in _dicts(s.get('dms'))
                   if m.get('need_you') and not m.get('is_agent')})
    meetings = sum(1 for _, s in secs for m in _dicts(s.get('meetings')) if m.get('attended'))
    todos = sum(1 for c in cands if c['type'] == 'task')
    stats = [{'value': meetings, 'label': 'your meetings'}, {'value': waiting, 'label': 'waiting on you'}]
    if todos:
        stats.append({'value': todos, 'label': 'to-dos for you'})
    lead = {'id': 'lead', 'kind': 'focus', 'size': 'XL', 'type': 'summary', 'symbol': 'sun-horizon', 'title': '',
            'data': {'stats': stats,
                     'spark': spark, 'sparkLabel': 'your day', 'unit': 'things',
                     'ticks': tick_labels(start, end, 4, tz)}}
    page = {'version': 1, 'companies': companies, 'person': {'name': person},
            'window': {'from': start.isoformat(timespec='seconds'), 'to': end.isoformat(timespec='seconds'),
                       'zoom': zoom_for(hours_away), 'label': window_label(hours_away), 'hoursAway': hours_away},
            'theme': {'style': 'merged'}, 'summary': [lead] + summary_side(cands, data), 'dropped': [], 'stream': []}
    return apply_notices(page, stale_notices(data), notice_context(data))


# ---------- stale signals ----------
#
# Everything here is designed against what the desktop app draws on a closed card in the
# merged style: the corner tag (`label`, else the type's name, with the company badge when the
# card has `company`), the glyph and the `title`. `why` is drawn only when a card is opened.

NOTICE_ID = 'signals-stale'           # one card per stale company: signals-stale-<slug>
NOTICE_LABEL = 'Stale signals'        # the notice card's corner tag
# The corner tag of a stale signal card must fit the smallest card with a company badge. The
# app draws an S card 190 px wide at its narrowest; the tag starts 20 px in, a badge takes
# 24 px and the mono text about 8 px a character, so 17 characters end at 180 px.
TAG_MAX_CHARS = 17
# An opened card shows two lines of `why`. In the 904 px drill those two lines held about 85
# characters before the app cut the text; 76 leaves room for a word that wraps early. It is
# a hard cap: the reason is fixed and at most 47 characters, and the company name is what
# gives way, cut at a word boundary with an ellipsis at NAME_MAX_CHARS (27 + ": " + 47 = 76).
NOTICE_WHY_MAX_CHARS = 76
NAME_MAX_CHARS = 27
# A closed card shows at most two lines of title (the app clamps the rest). At an S card on
# the narrowest grid a title line holds about 114 px of text in the app's font: "last
# updated Sep 30, 2025" measured 130 px over 25 characters, 5.2 px a character on average;
# taking the widest glyphs at 1.25 times that, 6.5 px, a line surely holds 114 / 6.5 = 17
# characters. So the date always comes first in a title, as one unbreakable block of at most
# 14 characters ("Sep 30, 2025 ·"), behind a lead word of at most 12 ("Last updated"): it
# ends by line 2 whatever the font does, and only the company name after it can be clamped.
# The name, which is also on the badge and in the opened text, follows as one unbreakable
# block of "· " and at most 15 characters and two words (17, one S line), and the whole title
# is at most 43 characters: "Last updated Sep 30, 2025 · Cyan Laborator…" (25 + 3 + 15 = 43).
NOTICE_TITLE_MAX_CHARS = 43
TITLE_NAME_MAX_CHARS = 15
TITLE_NAME_MAX_WORDS = 2
TITLE_LINE_CHARS = 17
TITLE_LINES = 2
# The opened card draws the same title in a large serif face. Round 3 measured its line in
# the 904 px drill: "Echo Partners: last" (19 characters) held one line and "Contoso
# Pharmac…: last" (22) did not, so a drill line is taken as 19 characters.
DRILL_LINE_CHARS = 19
# Ask my bot sends this card's `drill.bot` as written; a name there is cut only past this.
BOT_NAME_MAX_CHARS = 60
# Why today's signals are missing, one plain sentence per gate code. It follows the company
# name and a colon in the opened text ("Acme Inc: sign-in to a connected account failed.").
NOTICE_REASON = {
    'auth': 'sign-in to a connected account failed.',
    'config': 'the signals setup is not complete.',
    'run-failed': "today's signals run failed.",
    'start-failed': "today's signals run could not start.",
    'timed-out': "today's signals run has not finished yet.",
    'no-record': "today's signals run stopped before it finished.",
    'not-run': "today's signals run has not finished yet.",
}
NOTICE_REASON_DEFAULT = "today's signals run did not finish."
# timed-out and not-run read the same on purpose: to the reader both mean today's run is
# still under way and may yet finish. The gate keeps them apart in `code`.
# When no signals run has ever finished, the opened text says that first and then gives the
# reason in short form, all within NOTICE_WHY_MAX_CHARS: 52 + 1 + 23 = 76 at most.
NEVER_GOOD_WHY = 'No run has finished yet, so signal cards are hidden.'
NEVER_GOOD_REASON = {
    'auth': 'Sign-in failed.',
    'config': 'Setup is not complete.',
    'run-failed': 'The run failed.',
    'start-failed': 'The run did not start.',
    'timed-out': 'The run is not done.',
    'no-record': 'The run stopped early.',
    'not-run': 'The run is not done.',
}
NEVER_GOOD_REASON_DEFAULT = 'The run did not finish.'
# The fallback page has no name to greet unless brief-data.json carries one. The app always
# draws its headline as "<greeting>, <person.name>." and rejects a page whose name is blank,
# so a bare "Good morning." cannot be produced from this side. With no name the field holds
# a phrase instead, and the headline reads "Good morning, here is your brief.": no name, no
# word standing in for one, no stray comma or space.
NO_NAME = 'here is your brief'
TODO_STAT = 'to-dos for you'
NOTE_PREFIX = 'Signals are stale: '
# Card types written from signals, and the drill sources only signals carry on a company
# brief (connected apps are read through synced signals, never live).
SIGNAL_TYPES = ('task', 'decided')
SIGNAL_SOURCES_ONLY = ('meeting', 'email')
# Titles for the page code writes when the writer's page is missing or invalid.
FALLBACK_LEAD = 'Your day at a glance'
FALLBACK_TITLES = {'ask': 'Answer the open question', 'stalled': 'Move the stalled work', 'landed': 'See what shipped',
                   'broke': 'Fix what is broken', 'task': 'Do your to-do', 'meeting': 'See your meetings'}


def _good_date(notice):
    d = _dict(_dict(notice).get('last_good_run')).get('date')
    return d if _is_str(d) else None


_SIGNALS = []  # brief_signals, loaded once


def stale_notices(data):
    """brief_signals.notices(data): one notice per company whose signals are stale; [] on any error."""
    try:
        if not _SIGNALS:
            _SIGNALS.append(_sibling('brief_signals'))
        return [n for n in _SIGNALS[0].notices(data) if isinstance(n, dict) and _is_str(n.get('company'))]
    except Exception:
        return []


_GATE = []  # brief_gate, loaded once


def shown_date(iso, today=None):
    """brief_gate.human_date: the one helper for a date shown to a person ("Oct 1")."""
    try:
        if not _GATE:
            _GATE.append(_sibling('brief_gate'))
        return _GATE[0].human_date(iso, today)
    except Exception:
        return str(iso)


def page_today(page):
    """The day of the end of the page's window. Only a stand-in for the brief's local day
    when brief-data.json is not at hand (notice_context has the real one)."""
    to = _dict(_dict(page).get('window')).get('to')
    return to[:10] if _is_str(to) else None


def notice_context(data):
    """What the notice wording needs from brief-data.json, as {today, multi}.

    `today` is `window.today`, the local day the sweep was given: the same day the gate
    judges by, so a date gets its year in the page's wording exactly when it does in the
    gate's sentences. `multi` is True when this brief covers more than one company (the
    company sections of a person brief), whether or not each has cards today."""
    data = _dict(data)
    today = _dict(data.get('window')).get('today')
    if not (_is_str(today) and re.fullmatch(r'\d{4}-\d{2}-\d{2}', today)):
        today = None
    cos = data.get('companies') if data.get('mode') == 'person' else None
    count = len([k for k in cos if isinstance(k, str)]) if isinstance(cos, dict) else (1 if _is_str(data.get('company')) else 0)
    ctx = {'multi': count > 1}
    if today:
        ctx['today'] = today  # absent: apply_notices reads the page's own day instead
    return ctx


def short_name(name, max_chars, max_words=None, whole_words=False):
    """A company name cut to fit, with an ellipsis when anything was cut. With `whole_words`
    the cut falls between words (a single word too long for the room is still cut inside)."""
    name = ' '.join(str(name).split())
    words = name.split(' ')
    out = ' '.join(words[:max_words]) if max_words else name
    cut = out != name
    if len(out) + (1 if cut else 0) > max_chars:
        kept = []
        if whole_words:
            for word in out.split(' '):
                if len(' '.join(kept + [word])) + 1 > max_chars:
                    break
                kept.append(word)
        out = ' '.join(kept) if kept else out[:max_chars - 1].rstrip()
        cut = True
    return out + '\u2026' if cut else out


def signal_label(notice, today=None):
    """The corner tag of a card written from a stale company's signals: "From Oct 1", with
    the year only when it is not this year's ("From Sep 30, 2025", the longest it gets)."""
    return f'From {shown_date(_good_date(notice), today)}'[:TAG_MAX_CHARS]


def title_lines(title, width=TITLE_LINE_CHARS):
    """`title` wrapped the way a browser does it, at `width` characters a line: lines break
    at ordinary spaces only, so text joined by no-break spaces stays on one line."""
    lines = []
    for word in title.split(' '):
        if lines and len(lines[-1]) + 1 + len(word) <= width:
            lines[-1] += ' ' + word
        else:
            lines.append(word)
    return lines


def date_shown(title, date):
    """True when `date` (with its no-break spaces) ends within the lines the app draws."""
    seen = ''
    for line in title_lines(title)[:TITLE_LINES]:
        seen += line + ' '
    return date in seen


def notice_card(notice, today=None, name=None, multi=False):
    """The notice card of one stale company. It carries that company's slug, the page's
    existing warning look (a `broke` note with the warning glyph) and only sentences fixed in
    code. Each part says something the others do not:

    - `title`, on the closed and the opened card, says how old the signals are, date first:
      "Last updated Oct 1" (the date of the last good run, when they were last updated, not
      when anything broke). When the brief covers more than one company (`multi`) the name
      follows: "Last updated Oct 1 · Acme Inc". When no run has ever finished it is "No
      signals yet · Acme Inc", in every brief, so the opened text need not repeat the name.
    - `why`, on the opened card, says why: "Acme Inc: sign-in to a connected account failed."
      When no run has ever finished: "No run has finished yet, so signal cards are hidden.
      Sign-in failed." It names the company unless the title already does.
    - `drill.bot` is what Ask my bot sends, one statement with nothing said twice.

    No possessive of a company name. A long name is cut with an ellipsis; the date and the
    reason are never cut, and the caps are enforced here."""
    slug = notice['company']
    code = notice.get('code')
    code = code if isinstance(code, str) else None
    reason = NOTICE_REASON.get(code, NOTICE_REASON_DEFAULT)
    good = _good_date(notice)
    who = name if _is_str(name) else slug
    bot_name = short_name(who, BOT_NAME_MAX_CHARS, whole_words=True)
    if good:
        when = shown_date(good, today)[:len('Sep 30, 2025')]
        fixed = when.replace(' ', '\u00a0')  # a no-break space keeps the date on one line
        lead = f'Last updated {fixed}'
        ask = f'Signals for {bot_name} were last updated {when}.'
    else:
        fixed, lead = None, 'No signals yet'
        ask = f'No signals run has finished yet for {bot_name}, so its signal cards are not shown.'
    title = lead
    if multi or not good:
        # "·" stays with the name, so a line may start with "· Acme Inc" but never with a bare
        # dot, and the date block stays whole.
        room = NOTICE_TITLE_MAX_CHARS - len(f'{lead} · ')
        named = short_name(who, min(TITLE_NAME_MAX_CHARS, room), TITLE_NAME_MAX_WORDS).replace(' ', '\u00a0')
        # The name is one unbreakable block too ("· " + 15 = 17, one line at the narrowest S
        # card), so no line holds a lone word of it.
        title = f'{lead} ·\u00a0{named}'
        if _lint_title(title) or (fixed and not date_shown(title, fixed)):
            title = lead  # the name is on the badge and in the opened text
    if good:
        why = f'{short_name(who, min(NAME_MAX_CHARS, NOTICE_WHY_MAX_CHARS - len(reason) - 2), whole_words=True)}: {reason}'
    else:
        why = f'{NEVER_GOOD_WHY} {NEVER_GOOD_REASON.get(code, NEVER_GOOD_REASON_DEFAULT)}'
        if title == lead:  # the title could not name the company, so the opened text does
            why = f'{short_name(who, NAME_MAX_CHARS, whole_words=True)}: {reason}'
    bot = f'From my Daily Brief: {ask} {reason[:1].upper()}{reason[1:]} What should I do about it?'
    return {'id': f'{NOTICE_ID}-{slug}', 'kind': 'note', 'type': 'broke', 'size': 'M', 'symbol': 'warning',
            'company': slug, 'label': NOTICE_LABEL, 'title': title[:NOTICE_TITLE_MAX_CHARS],
            'why': why[:NOTICE_WHY_MAX_CHARS], 'data': {}, 'drill': {'signals': [], 'bot': bot}}


def is_notice(w):
    return isinstance(w, dict) and isinstance(w.get('id'), str) and w['id'].startswith(NOTICE_ID)


def from_signals(w):
    """True for a card whose facts come from signals: a to-do or a decision, or any card (but
    the meetings count, which is calendar facts) that cites a meeting or an email."""
    typ = w.get('type')
    if typ in SIGNAL_TYPES:
        return True
    if typ in ('meeting', 'summary'):
        return False
    return any(s.get('source') in SIGNAL_SOURCES_ONLY for s in _dicts(_dict(w.get('drill')).get('signals')))


def apply_notices(page, notices, ctx=None):
    """The page with stale signals shown, company by company. Returns the page unchanged when
    no company is stale.

    - One notice card per stale company, by slug, first beside the lead. One company: its
      card and one more card. Two: both. Three or more: the first three beside the lead and
      the rest at the head of the stream.
    - A card written from a stale company's signals gets the corner tag "Signals from
      <date>" (`label`, drawn on the closed card) and its `why` starts with that company's
      `section_line`. When the company has no good run the card is left out.
    - A company whose signals are fresh is not touched: its cards keep their tag and `why`.
    - A signal card that names no company (the to-do count), or sits under `personal`, which
      has no signals of its own, cannot be tied to one company's run and is left out; so is
      the lead's to-do count.
    Applying it twice gives the same page, which is how the check tells it was applied.
    `ctx` is notice_context(brief-data.json): the local day and whether the brief covers more
    than one company. Without it both are read off the page as a stand-in.
    """
    notices = sorted((n for n in notices or [] if isinstance(n, dict) and _is_str(n.get('company'))),
                     key=lambda n: n['company'])
    if not notices or not isinstance(page, dict):
        return page
    page = copy.deepcopy(page)
    names = _dict(page.get('companies'))
    ctx = _dict(ctx)
    today = ctx.get('today') if 'today' in ctx else page_today(page)
    multi = ctx.get('multi') if 'multi' in ctx else len([k for k in names if k != PERSONAL]) > 1
    by = {n['company']: n for n in notices}
    for band in ('summary', 'dropped', 'stream'):
        ws = page.get(band)
        if not isinstance(ws, list):
            continue
        kept = []
        for i, w in enumerate(ws):
            if not isinstance(w, dict) or (band == 'summary' and i == 0):
                kept.append(w)
                continue
            if is_notice(w):
                continue
            if from_signals(w):
                co = w.get('company')
                if co is None or co == PERSONAL:
                    continue
                n = by.get(co) if isinstance(co, str) else None
                if n is not None:
                    line = n.get('section_line')
                    if not _good_date(n) or not _is_str(line):
                        continue
                    w['label'] = signal_label(n, today)
                    why = w.get('why') if _is_str(w.get('why')) else ''
                    if not why.startswith(line):
                        joined = f'{line} {why}'.strip()
                        w['why'] = joined if len(joined) <= WHY_MAX_CHARS else line[:WHY_MAX_CHARS]
            kept.append(w)
        page[band] = kept
    summary = page.get('summary')
    if isinstance(summary, list) and summary and isinstance(summary[0], dict):
        lead = summary[0]
        stats = _dict(lead.get('data')).get('stats')
        if isinstance(stats, list):
            lead['data']['stats'] = [x for x in stats if not (isinstance(x, dict) and x.get('label') == TODO_STAT)]
        cards = [notice_card(n, today, _dict(names.get(n['company'])).get('name'), bool(multi)) for n in notices]
        top, rest = cards[:SUMMARY_MAX - 1], cards[SUMMARY_MAX - 1:]
        side = []
        if len(top) == 1:
            side = [w for w in summary[1:] if isinstance(w, dict)][:1]
            if side:
                side[0]['size'] = 'M'
            else:
                top[0]['size'] = 'L'
        elif len(top) == 3:
            top[1]['size'] = top[2]['size'] = 'S'
        page['summary'] = [lead] + top + side
        if rest:
            stream = page.get('stream') if isinstance(page.get('stream'), list) else []
            page['stream'] = (rest + stream)[:STREAM_MAX]
    return page


def _constant_frame(now):
    """A page frame that holds nothing read from any file: the last 24 hours, a bare lead."""
    end = now.isoformat(timespec='seconds')
    start = (now - dt.timedelta(hours=24)).isoformat(timespec='seconds')
    return {'version': 1, 'companies': {}, 'person': {'name': NO_NAME},
            'window': {'from': start, 'to': end, 'zoom': zoom_for(24), 'label': window_label(24), 'hoursAway': 24},
            'theme': {'style': 'merged'},
            'summary': [{'id': 'lead', 'kind': 'focus', 'size': 'XL', 'type': 'summary', 'symbol': 'sun-horizon',
                         'title': '', 'data': {}}], 'dropped': [], 'stream': []}


def reader_name(data):
    """The name the fallback page greets: `brief-data.json.person.name` when the data carries
    one, as a display first name (person_name, the same means the cards' names use). With
    none, NO_NAME, so the greeting names nobody ("Good morning, here is your brief.")."""
    raw = _dict(_dict(data).get('person')).get('name')
    if _is_str(raw):
        try:
            name = person_name(raw.strip())
        except Exception:
            name = None
        if _is_str(name):
            return name.strip()[:40]
    return NO_NAME


def _valid(page):
    try:
        return validate_page(page)['ok']
    except Exception:
        return False


def fallback_page(data, notices, names=None, now=None):
    """A valid page written by code alone, or None when none can be built. It is for a stale
    brief whose written page is missing or invalid, so the notice is always on a page the
    app draws.

    Nothing in it comes from a file a writer may have edited (page.json, page-draft.json):
    the frame is the one `skeleton` builds from brief-data.json, with a fixed lead title, the
    notice cards, and one card per candidate with a fixed title by type. Each attempt is
    checked with validate_page, and only a page that passes is returned: first that page,
    then the same frame with the notice cards alone, then a constant frame with the notice
    cards alone. `names` is {slug: company name} from the manifest."""
    data = _dict(data)
    notices = [n for n in notices or [] if isinstance(n, dict) and _is_str(n.get('company'))]
    if not notices:
        return None
    now = now or _ts(_dict(data.get('window')).get('sessions_to')) or dt.datetime.now(dt.timezone.utc)
    names = {k: v for k, v in _dict(names).items() if _is_str(k) and _is_str(v)}
    ctx = notice_context(data)
    attempts = []
    try:
        cands = candidates(data, now)
        base = skeleton(data, reader_name(data), now, names, cands)
        base['summary'][0]['title'] = FALLBACK_LEAD
        base['summary'], base['dropped'] = base['summary'][:1], []
        stream, per_type = [], {}
        for c in cands:
            title = FALLBACK_TITLES.get(c.get('type'))
            if not title or c.get('company') not in base['companies'] or per_type.get(c['type'], 0) >= 3:
                continue
            per_type[c['type']] = per_type.get(c['type'], 0) + 1
            w = {k: copy.deepcopy(c[k]) for k in ('company', 'type', 'kind', 'size', 'symbol', 'data', 'drill') if k in c}
            w.update(id=f'f-{c.get("id")}', title=title)
            _dict(w.get('data')).pop('visual', None)
            stream.append(w)
        attempts += [dict(base, stream=stream[:max(0, STREAM_MAX - len(notices))]), dict(base, stream=[])]
    except Exception:
        pass
    attempts.append(_constant_frame(now))
    for frame in attempts:
        try:
            frame = copy.deepcopy(frame)
            frame['summary'][0]['title'] = FALLBACK_LEAD
            companies = _dict(frame.get('companies'))
            for n in notices:
                if not _is_str(_dict(companies.get(n['company'])).get('name')):
                    companies[n['company']] = {'name': names.get(n['company'], n['company'])}
            frame['companies'] = companies
            page = apply_notices(frame, notices, ctx)
        except Exception:
            continue
        if _valid(page) and apply_notices(page, notices, ctx) == page:
            return page
    return None


def stamp_notices(brief, notices):
    """brief with `signals_notices` set and each notice `line` first in `learned_notes`.

    The app does not draw either today; the page is what the reader sees. They are the
    machine-readable record. A stale line that is no longer current is removed."""
    out = dict(brief) if isinstance(brief, dict) else {}
    out['signals_notices'] = notices
    lines = list(dict.fromkeys(n['line'] for n in notices if _is_str(n.get('line'))))
    old = out.get('learned_notes')
    rest = [x for x in old if not (isinstance(x, str) and (x.startswith(NOTE_PREFIX) or x in lines))] \
        if isinstance(old, list) else []
    if lines or isinstance(old, list):
        out['learned_notes'] = lines + rest
    return out


def with_notices(brief, data, names=None):
    """brief with the notice written by code: `signals_notices`, and, when a company is
    stale, a valid page that shows it. A page already on the brief gets the notice applied;
    when that page is missing or invalid, the fallback page takes its place. Any page this
    leaves on a stale brief has passed validate_page; when no valid page can be built the
    brief is left with no page (callers report that: see main)."""
    notices = stale_notices(data)
    out = stamp_notices(brief, notices)
    if not notices:
        return out
    page = out.get('page')
    try:
        page = apply_notices(page, notices, notice_context(data)) if isinstance(page, dict) else None
    except Exception:
        page = None
    if page is None or not _valid(page):
        page = fallback_page(data, notices, names)
    if page is None:
        out.pop('page', None)
    else:
        out['page'] = page
    return out


def notice_problems(brief, data):
    """Problems with how brief.json carries the stale-signals notice, against brief-data.json.

    `signals_notices` must equal what the code derives from brief-data.json, and when a
    company is stale the brief must have a valid page that is the page apply_notices gives.
    [] when all is in place."""
    out = []
    if not isinstance(brief, dict):
        return out
    want = stale_notices(data)
    if brief.get('signals_notices') != want:
        out.append({'where': 'signals_notices',
                    'problem': 'does not match brief-data.json; run brief_page.py notice (never edit it by hand)'})
    if stamp_notices(brief, want).get('learned_notes') != brief.get('learned_notes'):
        out.append({'where': 'learned_notes',
                    'problem': 'the stale-signals lines are missing, changed or left over; run brief_page.py notice'})
    if want:
        page = brief.get('page')
        try:
            shown = isinstance(page, dict) and validate_page(page)['ok'] \
                and apply_notices(page, want, notice_context(data)) == page
        except Exception:
            shown = False
        if not shown:
            out.append({'where': 'page', 'problem': 'signals are stale and the brief has no valid page showing each '
                                                    "company's notice card and signal card labels; run brief_page.py "
                                                    'notice (or attach) again'})
    return out


# ---------- attach ----------

def _write_json(path, obj):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix='.brief-', dir=d)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=1)
    os.replace(tmp, path)


def attach(brief, page, data=None, names=None):
    """(brief, report): `page` set on brief when it validates; otherwise `page` removed and
    `page_problems` set. Every other field of brief is left as it was.

    With `data` (brief-data.json) it also sets `signals_notices` and, when a company's
    signals are stale, applies the notice to the page first (apply_notices). A stale brief
    ends with a valid page: when the written page is missing or invalid, the page code
    writes (fallback_page) is attached in its place, and `page_problems` still says what
    was wrong with the written one. Only a page that passed validate_page is ever set;
    report['no_page'] is True when signals are stale and no valid page could be built."""
    notices = None if data is None else stale_notices(data)
    if notices:
        try:
            page = apply_notices(page, notices, notice_context(data))
        except Exception:  # a page too malformed to change is rejected by the check below
            pass
    try:
        report = validate_page(page)
    except Exception as e:  # validate_page does not raise; this is a second line of defence
        report = {'ok': False, 'errors': [{'where': 'page', 'problem': f'could not check the page ({type(e).__name__})'}],
                  'warnings': []}
    out = dict(brief) if notices is None else stamp_notices(brief, notices)
    report['fallback'] = report['no_page'] = False
    if report['ok']:
        out['page'] = page
        out.pop('page_problems', None)
    else:
        out.pop('page', None)
        out['page_problems'] = report['errors'][:20]
        if notices:
            fallback = fallback_page(data, notices, names)
            if fallback is None:
                report['no_page'] = True
            else:
                out['page'] = fallback
                report['fallback'] = True
    return out, report


def _read_data(path):
    """brief-data.json as a dict, or None when it cannot be read."""
    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _manifest_names(run_dir):
    """{slug: company name} from the company manifest of the HQ root this run folder is in
    (workspace/brief/<run_id>/); {} when it cannot be read."""
    try:
        bc = _sibling('brief_company')
        root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(run_dir))))
        names = bc.manifest_names(bc.read_manifest(root))
        return {k: v for k, v in names.items() if _is_str(k) and _is_str(v)} if isinstance(names, dict) else {}
    except Exception:
        return {}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    sk = sub.add_parser('skeleton', help='page frame and card candidates from brief-data.json')
    sk.add_argument('--data', required=True)
    sk.add_argument('--out', required=True)
    sk.add_argument('--person', default=None)
    sk.add_argument('--now', default=None)
    sk.add_argument('--hq-root', default=os.getcwd())
    ck = sub.add_parser('check', help='validate a page JSON (exit 1 on errors)')
    ck.add_argument('page')
    at = sub.add_parser('attach', help='validate a page and write it into brief.json (fail soft)')
    at.add_argument('--brief', required=True)
    at.add_argument('--page', required=True)
    at.add_argument('--data', default=None, help='brief-data.json (default: the one beside --brief)')
    nt = sub.add_parser('notice', help='write brief.json.signals_notices from brief-data.json')
    nt.add_argument('--brief', required=True)
    nt.add_argument('--data', default=None, help='brief-data.json (default: the one beside --brief)')
    a = ap.parse_args(argv)
    if a.cmd == 'skeleton':
        with open(a.data, encoding='utf-8') as f:
            data = json.load(f)
        now = _ts(a.now) if a.now else dt.datetime.now(dt.timezone.utc)
        person = a.person or 'You'
        try:
            bc = _sibling('brief_company')
            names = bc.manifest_names(bc.read_manifest(a.hq_root))
        except Exception:
            names = {}
        cands = candidates(data, now)
        out = {'page': skeleton(data, person, now, names, cands), 'candidates': cands}
        _write_json(a.out, out)
        print(json.dumps({'out': a.out, 'candidates': len(out['candidates']),
                          'companies': sorted(out['page']['companies'])}))
        return 0
    if a.cmd == 'check':
        with open(a.page, encoding='utf-8') as f:
            page = json.load(f)
        if isinstance(page, dict) and 'page' in page and 'version' not in page:
            page = page['page']
        report = validate_page(page)
        print(json.dumps(report, indent=1))
        return 0 if report['ok'] else 1
    with open(a.brief, encoding='utf-8') as f:
        brief = json.load(f)
    run_dir = os.path.dirname(os.path.abspath(a.brief))
    data = _read_data(a.data or os.path.join(run_dir, 'brief-data.json'))
    names = _manifest_names(run_dir)
    # Without brief-data.json the notice cannot be written or checked. `notice` says so and
    # exits 1; `attach` says so and keeps the exit code it always had.
    no_data = {'problem': 'could not read brief-data.json, so the stale-signals notice was not written; '
                          'pass --data and run this again'}
    # Signals are stale and no valid page could be built: exit 2, never an invalid page.
    no_page = {'problem': 'signals are stale and no valid page could be built, so brief.json has no page; do not '
                          'run this again: finish the brief and start the closing reply with the notice'}
    if a.cmd == 'notice':
        if data is None:
            print(json.dumps(dict(no_data, signals_notices=None)))
            return 1
        brief = with_notices(brief, data, names)
        _write_json(a.brief, brief)
        result = {'signals_notices': len(brief['signals_notices']), 'page': 'page' in brief}
        if brief['signals_notices'] and 'page' not in brief:
            print(json.dumps(dict(result, **no_page)))
            return 2
        print(json.dumps(result))
        return 0
    try:
        with open(a.page, encoding='utf-8') as f:
            page = json.load(f)
    except (OSError, ValueError) as e:
        page = None
        print(f'[page] could not read the page: {type(e).__name__}', file=sys.stderr)
    out, report = attach(brief, page, data, names)
    _write_json(a.brief, out)
    if not report['ok']:
        print(f'[page] left out of brief.json: {len(report["errors"])} problems; see page_problems', file=sys.stderr)
        if report['fallback']:
            print('[page] signals are stale, so a page written by code (the notice and the computed cards) '
                  'was attached instead', file=sys.stderr)
        for e in report['errors'][:10]:
            print(f'[page]   {e["where"]}: {e["problem"]}', file=sys.stderr)
    result = {'attached': report['ok'], 'errors': len(report['errors']), 'warnings': len(report['warnings']),
              'signals_notices': len(out.get('signals_notices') or []), 'fallback_page': report['fallback']}
    if report['no_page']:
        print(json.dumps(dict(result, **no_page)))
        return 2
    if data is None:
        result.update(no_data, signals_notices=None)
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    sys.exit(main())
