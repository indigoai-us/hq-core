#!/usr/bin/env python3
"""Mechanical parts of writing brief.json: product names, title lint, ranking.

The writer (an LLM following SKILL.md) owns the wording. This file owns the
rules a script can check, so every run applies them the same way.

Usage:
  python3 -I brief_rank.py --check workspace/brief/<run_id>/brief.json
    Prints JSON: {"priorities": [...ranked item ids with scores...],
    "scores": {item_id: unblock score}, "title_problems": [...],
    "over_cap": {...}, "dangling_priorities": [...], "priority_problems": [...],
    "lead_hint_problem": str|null, "widget_problems": [...], "today_problem": str|null,
    "index_counts": {...}, "landed": bool}. Exit 0 always; the writer fixes what it reports.
"""
import argparse, json, os, re, sys

MAX_PER_LIST = 5
MAX_TITLE_WORDS = 8
WEIGHT_MIN, WEIGHT_MAX = -2, 2
DENSITIES = ('auto', 'calm', 'full')
# Widgets the person cannot mute: the hero, the welcome-back hero and the calls list.
UNMUTABLE_WIDGETS = ('sunrise', 'catchup', 'needs')
# Lists whose item ids a priority may point at.
PRIORITY_ID_LISTS = ('decisions', 'incidents', 'problems', 'handoffs', 'carry')
# Lists whose `title` follows the title rule (plus the field-level ones in check_brief).
TITLE_LISTS = ('decisions', 'incidents', 'problems', 'watch', 'waiting', 'meetings', 'shipped', 'recovered')
# The kind of call a decision is; the app's buttons and the picker's release rule key on it.
DECISION_ACTIONS = ('cut', 'go', 'decide', 'reply', 'prep')
_DATE = re.compile(r'^\d{4}-\d{2}-\d{2}$')

# Repo slug -> the product name the person uses. Empty by default, so every
# slug becomes 'Word word'; load_product_names() fills it from optional files.
PRODUCT_NAMES = {}
# Read in order; a later file wins on the same slug. The company file is read
# only when the run has a company.
COMPANY_PRODUCT_FILE = ('settings', 'brief-products.json')
PERSONAL_PRODUCT_FILE = ('workspace', 'brief', 'products.json')


def read_product_file(path):
    """{repo slug: product name} from one JSON object file; {} when the file is
    missing or unreadable. Entries that are not non-empty strings are dropped."""
    try:
        with open(path, encoding='utf-8') as f:
            d = json.load(f)
    except (OSError, ValueError):
        return {}
    if not isinstance(d, dict):
        return {}
    return {k.strip().split('/')[-1]: v.strip() for k, v in d.items()
            if isinstance(k, str) and k.strip() and isinstance(v, str) and v.strip()}


def load_product_names(hq_root, company=None):
    """Fill PRODUCT_NAMES from companies/<company>/settings/brief-products.json
    (only with a company), then workspace/brief/products.json. Returns a copy."""
    names = {}
    if company:
        names.update(read_product_file(os.path.join(hq_root, 'companies', company, *COMPANY_PRODUCT_FILE)))
    names.update(read_product_file(os.path.join(hq_root, *PERSONAL_PRODUCT_FILE)))
    PRODUCT_NAMES.clear()
    PRODUCT_NAMES.update(names)
    return dict(names)


def product_for(repo):
    """Human product name for a repo slug; unknown slugs become 'Word word'."""
    if not repo:
        return None
    r = repo.split('/')[-1]
    if r in PRODUCT_NAMES:
        return PRODUCT_NAMES[r]
    return r.replace('-', ' ').replace('_', ' ').strip().capitalize()


_CONV_PREFIX = re.compile(r'^\s*(feat|fix|chore|docs|refactor|perf|test|build|ci|style|revert)(\([^)]*\))?!?:', re.I)
_PR_NUMBER = re.compile(r'(^|\s)#\d+\b|\bPR\s*\d+\b', re.I)
_PATH_OR_FLAG = re.compile(r'(^|\s)[~.]?/\w|\w+/[\w.-]+/|\b[\w-]+\.(py|ts|tsx|js|json|md|ya?ml|sh|rs|toml|lock)\b|(^|\s)--?[a-z][\w-]*|`')


def lint_title(title, repos=(), max_words=MAX_TITLE_WORDS):
    """Reasons a title breaks the title rule (empty list = fine).

    Rule: the ask in plain English, verb first, at most 8 words, no repo names,
    PR numbers, conventional-commit prefixes, file paths or flags. `max_words`
    None skips the length check (shipped highlights are lines, not titles).
    """
    t = (title or '').strip()
    out = []
    if not t:
        return ['empty title']
    words = t.replace('—', ' ').split()
    if max_words is not None and len(words) > max_words:
        out.append(f'{len(words)} words (max {max_words})')
    if _CONV_PREFIX.search(t):
        out.append('commit prefix')
    if _PR_NUMBER.search(t):
        out.append('PR number')
    low = t.lower()
    slugs = set(PRODUCT_NAMES) | {r.split('/')[-1] for r in repos if r}
    hit = sorted(s for s in slugs if re.search(r'(?<![\w-])' + re.escape(s) + r'(?![\w-])', low))
    if hit:
        out.append('repo name: ' + ', '.join(hit))
    if _PATH_OR_FLAG.search(t):
        out.append('path, flag or code')
    return out


def unblock_score(item):
    """How much an item unblocks: people waiting + things it unlocks, revenue counts double."""
    people = int(item.get('people_waiting') or 0)
    unlocks = len(item.get('unlocks') or [])
    return people + unlocks + (2 if item.get('revenue') else 0)


_EFFORT = {'large': 0, 'medium': 1, 'small': 2, 'quick': 2}


def rank_priorities(items, limit=MAX_PER_LIST):
    """Order candidate items for `priorities`.

    Most unblocked people/revenue first, then oldest, then effort. A quick win
    that unblocks nothing goes after everything that does.
    Returns [{'rank', 'item_id', 'score'}], at most `limit`.
    """
    def key(it):
        score = unblock_score(it)
        effort = _EFFORT.get((it.get('effort') or 'medium').lower(), 1)
        quick_idle = 1 if effort == 2 and score == 0 else 0
        return (quick_idle, -score, -float(it.get('age_hours') or 0), effort, str(it.get('id') or ''))

    cands = [it for it in items if it.get('id')]
    ranked = sorted(cands, key=key)[:limit]
    return [{'rank': i + 1, 'item_id': it['id'], 'score': unblock_score(it)} for i, it in enumerate(ranked)]


def _rows(items, name):
    return [it for it in items.get(name) or [] if isinstance(it, dict)]


def _origin_repos(items):
    out = set()
    for lst in items.values():
        if not isinstance(lst, list):
            continue
        for it in lst:
            if not isinstance(it, dict):
                continue
            if it.get('repo'):
                out.add(it['repo'])
            if isinstance(it.get('origin'), dict) and it['origin'].get('repo'):
                out.add(it['origin']['repo'])
    return out


def priority_ids(items):
    """Every item id a priority may reference: decisions, incidents, handoffs, carry."""
    return {it['id'] for name in PRIORITY_ID_LISTS for it in _rows(items, name) if it.get('id')}


def dangling_priorities(brief):
    """Priorities whose item_id names no decision, incident, handoff or carry item."""
    ids = priority_ids(brief.get('items') or {})
    return [{'rank': p.get('rank'), 'item_id': p.get('item_id')} for p in brief.get('priorities') or []
            if isinstance(p, dict) and p.get('item_id') not in ids]


def item_scores(items):
    """unblock_score for every referenceable item. A carry row that points at
    today's decision or incident takes that item's score."""
    scores = {}
    for name in ('decisions', 'incidents', 'problems', 'handoffs'):
        for it in _rows(items, name):
            if it.get('id'):
                scores[it['id']] = unblock_score(it)
    for it in _rows(items, 'carry'):
        if it.get('id'):
            scores[it['id']] = scores.get(it.get('item_id'), unblock_score(it))
    return scores


def priority_problems(brief, scores):
    """Per priority: missing or wrong score, missing because, text that breaks the title rule."""
    out = []
    repos = _origin_repos(brief.get('items') or {})
    for p in brief.get('priorities') or []:
        if not isinstance(p, dict):
            continue
        why = []
        want = scores.get(p.get('item_id'))
        if p.get('score') is None:
            why.append('missing score' + (f' (should be {want})' if want is not None else ''))
        elif want is not None and p.get('score') != want:
            why.append(f'score {p.get("score")} should be {want}')
        if not (p.get('because') or '').strip():
            why.append('missing because')
        why += lint_title(p.get('text'), repos)
        if why:
            out.append({'rank': p.get('rank'), 'item_id': p.get('item_id'), 'problems': why})
    return out


def lead_hint_problem(brief):
    """lead_hint's first clause must be priority 1's text verbatim (the hero quotes it)."""
    pri = [p for p in brief.get('priorities') or [] if isinstance(p, dict)]
    if not pri:
        return None
    first = sorted(pri, key=lambda p: p.get('rank') or 99)[0]
    text = (first.get('text') or '').strip()
    hint = (brief.get('lead_hint') or '').strip()
    if text and not hint.startswith(text):
        return f'lead_hint must start with priority 1 text: "{text}"'
    return None


def widget_problems(prefs_widgets):
    """prefs_applied.widgets rule breaks: unmutable kinds muted, weights outside
    -2..2, an unknown density."""
    w = prefs_widgets if isinstance(prefs_widgets, dict) else None
    if w is None:
        return ['prefs_applied.widgets missing']
    out = []
    for k in w.get('muted') or []:
        if k in UNMUTABLE_WIDGETS:
            out.append(f'{k} cannot be muted')
    for k, v in (w.get('weights') or {}).items():
        if not isinstance(v, int) or v < WEIGHT_MIN or v > WEIGHT_MAX:
            out.append(f'weight {k}={v!r} outside {WEIGHT_MIN}..{WEIGHT_MAX}')
    if w.get('density') not in DENSITIES:
        out.append(f'density {w.get("density")!r} not one of {", ".join(DENSITIES)}')
    return out


def apply_widget_prefs(prefs):
    """brief-prefs.yaml fields -> prefs_applied.widgets plus learned_notes lines.
    Unmutable kinds are dropped from muted with a note; weights are clamped to -2..2."""
    prefs = prefs or {}
    notes = []
    muted = []
    for k in prefs.get('muted_widgets') or []:
        if k in UNMUTABLE_WIDGETS:
            notes.append(f'Kept the {k} card: it cannot be muted, so the muted_widgets entry was dropped.')
        else:
            muted.append(k)
    weights = {}
    for k, v in (prefs.get('widget_weights') or {}).items():
        try:
            n = int(v)
        except (TypeError, ValueError):
            notes.append(f'Ignored widget_weights.{k}={v!r}: weights are whole numbers from -2 to 2.')
            continue
        c = max(WEIGHT_MIN, min(WEIGHT_MAX, n))
        if c != n:
            notes.append(f'Clamped widget_weights.{k} from {n} to {c}: weights run from -2 to 2.')
        weights[k] = c
    density = prefs.get('density') if prefs.get('density') in DENSITIES else 'auto'
    return {'pinned': list(prefs.get('pinned_widgets') or []), 'muted': muted, 'weights': weights,
            'density': density}, notes


def index_counts(brief):
    """counts for the index.jsonl line: decisions, shipped (= counts.merged, the
    prs_summary number), incidents, carry, recovered."""
    items = brief.get('items') or {}
    counts = brief.get('counts') or {}
    merged = counts.get('merged')
    return {'decisions': len(_rows(items, 'decisions')),
            'shipped': merged if isinstance(merged, int) else len(_rows(items, 'shipped')),
            'incidents': len(_rows(items, 'incidents') or _rows(items, 'problems')),
            'carry': len(_rows(items, 'carry')), 'recovered': len(_rows(items, 'recovered'))}


def landed(brief):
    """True when the run saw at least one merged PR or a release."""
    counts = brief.get('counts') or {}
    if isinstance(counts.get('merged'), int) and counts['merged'] > 0:
        return True
    if brief.get('landed_days'):
        return True
    return any(r.get('released_at') for r in _rows(brief.get('items') or {}, 'releases'))


def field_problems(items):
    """Fields the app reads that the writer must set, or the card renders wrong or not at all.

    decisions[].action must be one of DECISION_ACTIONS (the app defaults a
    missing one to `decide`, so the release call could never be read as a
    cut); waiting[] rows need `who` and `what` (or `title`), else the app
    drops the row and the Waiting card never shows writer data.
    Returns [{'list', 'id', 'field', 'problem'}].
    """
    out = []
    for it in _rows(items, 'decisions'):
        action = it.get('action')
        if not action:
            out.append({'list': 'decisions', 'id': it.get('id'), 'field': 'action',
                        'problem': 'missing action (one of ' + ', '.join(DECISION_ACTIONS) + ')'})
        elif action not in DECISION_ACTIONS:
            out.append({'list': 'decisions', 'id': it.get('id'), 'field': 'action',
                        'problem': f'action {action!r} not one of ' + ', '.join(DECISION_ACTIONS)})
    for it in _rows(items, 'waiting'):
        if not (it.get('who') or '').strip():
            out.append({'list': 'waiting', 'id': it.get('id'), 'field': 'who', 'problem': 'missing who (the app drops the row)'})
        if not ((it.get('what') or it.get('title') or '').strip()):
            out.append({'list': 'waiting', 'id': it.get('id'), 'field': 'what', 'problem': 'missing what'})
    return out


# A first brief for someone with past sessions never says there is nothing.
EMPTY_STATE_PHRASES = ('nothing owed', 'no sessions', 'nothing needs', 'nothing to show', 'no activity',
                       'nothing happened', 'no work yet', 'nothing yet')
# Exception text never reaches the brief; failures get a plain note.
EXCEPTION_MARKERS = (re.compile(r'Traceback \(most recent call last\)'), re.compile(r'File ".*", line \d+'),
                     re.compile(r'\[Errno \d+\]'))
# The person's own words and names (session titles, folder and repo names) and
# raw source rows are data, not brief copy, so they are not checked.
WELCOME_DATA_KEYS = ('recent_work', 'top_projects', 'top_repos', 'repos', 'import', 'items', 'sources')


def _strings(value, skip=()):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for k, v in value.items():
            if k not in skip:
                yield from _strings(v, skip)
    elif isinstance(value, list):
        for v in value:
            yield from _strings(v, skip)


def welcome_problems(brief):
    """Problems with a welcome edition: empty-state copy on a first run that has
    sessions, and exception text inside `welcome`. [] when there is no welcome."""
    w = brief.get('welcome')
    if not isinstance(w, dict):
        return []
    out = []
    for text in _strings(w, WELCOME_DATA_KEYS):
        for m in EXCEPTION_MARKERS:
            if m.search(text):
                out.append({'field': 'welcome', 'text': text[:120], 'problem': f'exception text ({m.pattern})'})
                break
    if w.get('first_run') and ((w.get('sessions') or {}).get('total') or 0) > 0:
        rest = {k: v for k, v in brief.items() if k != 'welcome'}
        for text in list(_strings(rest, WELCOME_DATA_KEYS)) + list(_strings(w, WELCOME_DATA_KEYS)):
            low = text.lower()
            for phrase in EMPTY_STATE_PHRASES:
                if phrase in low:
                    out.append({'field': 'brief', 'text': text[:120],
                                'problem': f'empty-state line ({phrase!r}) on a first run with sessions'})
                    break
    return out


def check_brief(brief):
    if brief.get('mode') == 'person':
        sections = dict(brief.get('companies') or {})
        reports = {}
        isolation = []
        for slug, section in [(None, brief.get('personal') or {})] + list(sections.items()):
            for name, rows in (section.get('items') or {}).items():
                for row in rows if isinstance(rows, list) else []:
                    if isinstance(row, dict) and ('company' not in row or row['company'] != slug):
                        isolation.append({'section': slug, 'list': name, 'id': row.get('id'),
                                          'problem': 'item company does not match section'})
            reports[slug or 'personal'] = check_brief(dict(section, mode='company' if slug else 'personal'))
        return {'sections': reports, 'isolation_problems': isolation, 'welcome_problems': welcome_problems(brief)}
    items = brief.get('items') or {}
    repos = _origin_repos(items)
    problems = []

    def flag(lst_name, it, field, value, max_words=MAX_TITLE_WORDS):
        why = lint_title(value, repos, max_words)
        if why:
            problems.append({'list': lst_name, 'id': it.get('id'), 'field': field, 'title': value, 'problems': why})

    for lst_name in TITLE_LISTS:
        for it in _rows(items, lst_name):
            if lst_name == 'waiting':
                # A wait is `who` + `what`; the app reads `title` as `what` when `what` is missing.
                flag(lst_name, it, 'what', it.get('what') or it.get('title'))
            else:
                flag(lst_name, it, 'title', it.get('title'))
            if lst_name in ('decisions', 'incidents', 'problems', 'watch', 'waiting'):
                for f in ('product', 'company'):
                    if not it.get(f) and not (f == 'company' and brief.get('mode') == 'personal' and 'company' in it and it['company'] is None):
                        problems.append({'list': lst_name, 'id': it.get('id'), 'field': f, 'title': it.get('title'),
                                         'problems': [f'missing {f}']})
            if lst_name == 'shipped':
                for line in it.get('highlights') or []:
                    flag(lst_name, it, 'highlights', line, max_words=None)
    for it in _rows(items, 'handoffs'):
        flag('handoffs', it, 'object', it.get('object'))
    for it in _rows(items, 'releases'):
        for h in it.get('held') or []:
            if isinstance(h, dict):
                flag('releases', it, 'held.title', h.get('title'))
    # reminders are the person's own words, verbatim: exempt.
    over = {k: len(v) for k, v in items.items() if isinstance(v, list) and len(v) > MAX_PER_LIST
            and k not in ('shipped', 'people', 'other_company')}
    cands = (items.get('decisions') or []) + (items.get('incidents') or items.get('problems') or [])
    scores = item_scores(items)
    today = brief.get('today')
    return {'priorities': rank_priorities(cands), 'scores': scores, 'title_problems': problems, 'over_cap': over,
            'field_problems': field_problems(items),
            'priorities_count': len(brief.get('priorities') or []),
            'dangling_priorities': dangling_priorities(brief),
            'priority_problems': priority_problems(brief, scores),
            'lead_hint_problem': lead_hint_problem(brief),
            'widget_problems': widget_problems((brief.get('prefs_applied') or {}).get('widgets')),
            'today_problem': None if isinstance(today, str) and _DATE.match(today) else 'today must be YYYY-MM-DD',
            'index_counts': index_counts(brief), 'landed': landed(brief),
            'welcome_problems': welcome_problems(brief)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', required=True, help='brief.json to check')
    a = ap.parse_args()
    print(json.dumps(check_brief(json.load(open(a.check))), indent=1))


if __name__ == '__main__':
    sys.exit(main())
