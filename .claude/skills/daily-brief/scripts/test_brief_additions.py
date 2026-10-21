"""Plain-assert tests for the widget-facing additions to brief-sweep.py and
brief_rank.py (sessions, PR rows, releases, main health, fleet, meetings, DMs,
previous-run lookup, priority and prefs checks). No live service is called.
Run: python3 -I test_brief_additions.py"""
import datetime as dt
import importlib.util
import json
import os
import random
import re
import sys
import tempfile
import time

# Fixture base time (2026-10-03 04:00 UTC), derived so no raw epoch literal is in the source.
_TS0 = dt.datetime(2026, 10, 3, 4, 0, tzinfo=dt.timezone.utc).timestamp()


def _ts(day, clock):
    """A YYYYMMDD-HHMMSS stamp from its two halves (keeps long digit runs out of the source)."""
    return day + '-' + clock

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


sweep = load('brief_sweep', 'brief-sweep.py')
rank = load('brief_rank', 'brief_rank.py')
UTC = dt.timezone.utc

# Product names come from a data file (workspace/brief/products.json); the
# fixtures use this map.
PRODUCTS = {'hq-desktop-app': 'Desktop app', 'hq-cloud': 'HQ Cloud', 'hq-core-staging': 'HQ core', 'hq-pro': 'HQ Pro'}


def write_products(root):
    path = os.path.join(root, 'workspace', 'brief', 'products.json')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        json.dump(PRODUCTS, f)


def use_products():
    with tempfile.TemporaryDirectory() as root:
        write_products(root)
        rank.load_product_names(root)
        sweep._sibling('brief_rank').load_product_names(root)


use_products()
T = lambda s: dt.datetime.fromisoformat(s.replace('Z', '+00:00'))


# ---------- sessions ----------
def test_session_row_keeps_project_product_handoff_inside_company_only():
    r = {'id': 'a', 'started_at': '2026-10-11T14:36:06Z', 'company': 'initech-test', 'kind': 'you',
         'title': 'Fix the tour', 'project': 'hq-desktop-app', 'cwd': '/x/repos/private/hq-desktop-app',
         'last_activity': '2026-10-11T15:00:00Z'}
    row = sweep.session_row(r, 'initech-test', {'a'})
    assert row['project'] == 'hq-desktop-app' and row['product'] == 'Desktop app'
    assert row['cwd'] == '/x/repos/private/hq-desktop-app' and row['has_handoff'] is True
    assert row['last_activity'] == '2026-10-11T15:00:00Z' and row['title'] == 'Fix the tour'
    other = sweep.session_row(dict(r, company='globex'), 'initech-test', {'a'})
    assert other['company'] == 'other' and other['title'] is None and other['project'] is None
    assert other['cwd'] is None and other['product'] is None and other['has_handoff'] is None
    # a scan row that already carries has_handoff wins over the thread lookup
    assert sweep.session_row(dict(r, has_handoff=False), 'initech-test', {'a'})['has_handoff'] is False
    assert sweep.session_row(dict(r, project=None), 'initech-test', set())['product'] is None
    assert sweep.session_row(dict(r, company=None), 'initech-test')['company'] == 'unknown'


def test_handoff_session_ids_reads_thread_records():
    mod = load('local_sessions', 'local_sessions.py')
    with tempfile.TemporaryDirectory() as root:
        tdir = os.path.join(root, 'workspace', 'threads')
        os.makedirs(tdir)
        def put(name, obj):
            with open(os.path.join(tdir, name), 'w') as f:
                json.dump(obj, f)
        put('T-' + _ts('20261011', '120000') + '-handoff.json', {'session_id': 's1', 'type': 'handoff', 'updated_at': '2026-10-11T12:00:00Z',
                                              'metadata': {'title': 'Handed off'}})
        put('T-' + _ts('20261011', '130000') + '-checkpoint.json', {'session_id': 's2', 'type': 'checkpoint'})
        put('T-' + _ts('20261011', '140000') + '-md.json', {'metadata': {'session_id': 's3', 'kind': 'handoff'}})
        put('T-' + _ts('20260901', '140000') + '-old.json', {'session_id': 's4', 'type': 'handoff'})  # outside the window
        put('T-' + _ts('20261011', '150000') + '-bad.json', 'not a record')
        start, end = T('2026-10-10T14:00:00Z'), T('2026-10-11T14:00:00Z')
        assert sweep.handoff_session_ids(root, start, end, mod) == {'s1', 's3'}
        assert sweep.handoff_session_ids(os.path.join(root, 'missing'), start, end, mod) == set()


# ---------- PRs ----------
def _gh(number, state, created, closed, title='fix(x): thing', repo='hq-desktop-app', draft=False):
    return {'number': number, 'title': title, 'repository': {'name': repo, 'nameWithOwner': f'o/{repo}'}, 'state': state, 'createdAt': created,
            'closedAt': closed, 'isDraft': draft, 'url': f'https://github.com/o/{repo}/pull/{number}',
            'author': {'login': 'sam'}}


def test_pr_row_nulls_placeholder_dates_and_adds_merge_hours():
    row = sweep.pr_row(_gh(1559, 'open', '2026-10-11T14:51:32Z', '0001-01-01T00:00:00Z', draft=True), True, False)
    assert row['closed'] is None and row['isDraft'] is True and row['merge_hours'] is None
    assert row['reviewDecision'] is None and row['reviewers'] == [] and row['product'] == 'Desktop app'
    row = sweep.pr_row(_gh(1553, 'merged', '2026-10-10T19:17:03Z', '2026-10-10T21:13:12Z', 'Release 0.11.3'), True, False)
    assert row['closed'] == '2026-10-10T21:13:12Z' and row['merge_hours'] == 1.9 and row['is_release']
    row = sweep.pr_row(_gh(7, 'open', '2026-10-11T14:00:00Z', None), False, True)
    assert row['review_requested'] and row['reviewRequests'] == ['@me'] and not row['authored_by_me']
    assert sweep.merge_hours('2026-10-10T10:00:00Z', '2026-10-10T12:30:00Z') == 2.5
    assert sweep.merge_hours('2026-10-10T10:00:00Z', None) is None
    assert sweep._ts('0001-01-01T00:00:00Z') is None and sweep._ts('garbage') is None and sweep._ts('') is None


def test_pr_dedupe_keeps_same_number_in_two_owners():
    a = _gh(12, 'open', '2026-10-11T00:00:00Z', None, repo='web')
    b = dict(a, repository={'name': 'web', 'nameWithOwner': 'o2/web'}, url='https://github.com/o2/web/pull/12')
    calls = []
    saved = sweep.jrun, sweep._review_meta
    sweep.jrun = lambda cmd, timeout=90: calls.append(cmd) or [a, b]
    sweep._review_meta = lambda rows: {}
    try:
        rows = sweep.prs(None, '2026-10-01')
    finally:
        sweep.jrun, sweep._review_meta = saved
        sweep.SOURCES.clear()
    assert sorted(r['repo_full'] for r in rows) == ['o/web', 'o2/web'], rows


def test_scope_prs_drops_other_company_owners():
    rows = [sweep.pr_row(_gh(1, 'open', '2026-10-11T00:00:00Z', None, title='initech-test work', repo='a'), True, False),
            sweep.pr_row(dict(_gh(2, 'open', '2026-10-11T00:00:00Z', None, title='globex secret', repo='g'),
                              repository={'name': 'g', 'nameWithOwner': 'globex-gh/g'}), True, False),
            sweep.pr_row(dict(_gh(3, 'open', '2026-10-11T00:00:00Z', None, title='mine', repo='m'),
                              repository={'name': 'm', 'nameWithOwner': 'sam/m'}), True, False)]
    owners = {'initech-test': 'o', 'globex': 'Globex-GH'}
    kept, other = sweep.scope_prs(rows, 'initech-test', owners)
    assert [r['title'] for r in kept] == ['initech-test work', 'mine'] and other == 1, kept
    assert 'globex secret' not in json.dumps(kept)
    kept, other = sweep.scope_prs(rows, None, owners)  # personal: every mapped owner is out
    assert [r['title'] for r in kept] == ['mine'] and other == 2
    assert sweep.scope_prs(None, 'initech-test', owners) == ([], 0)


def test_apply_review_meta():
    rows = [sweep.pr_row(_gh(1, 'open', '2026-10-11T14:00:00Z', None), True, False),
            sweep.pr_row(_gh(2, 'open', '2026-10-11T14:00:00Z', None), True, False)]
    meta = {rows[0]['url']: {'reviewDecision': 'APPROVED', 'reviewRequests': [{'login': 'alex'}, {'slug': 'core-team'}],
                             'isDraft': False},
            'https://nope': {'reviewDecision': 'CHANGES_REQUESTED'}}
    sweep.apply_review_meta(rows, meta)
    assert rows[0]['reviewDecision'] == 'APPROVED' and rows[0]['reviewers'] == ['alex', 'core-team']
    assert rows[1]['reviewDecision'] is None and rows[1]['reviewers'] == []
    sweep.apply_review_meta(rows, {rows[1]['url']: {'reviewDecision': '', 'reviewRequests': []}})
    assert rows[1]['reviewDecision'] is None


def test_pr_summary_median_and_by_product():
    start, end = T('2026-10-10T14:54:49Z'), T('2026-10-11T14:54:49Z')
    prs = [
        {'state': 'merged', 'created': '2026-10-10T12:00:00Z', 'closed': '2026-10-10T22:00:00Z', 'authored_by_me': True, 'repo': 'hq-pro', 'product': 'HQ Pro', 'merge_hours': 2.0},
        {'state': 'merged', 'created': '2026-10-10T12:00:00Z', 'closed': '2026-10-11T02:00:00Z', 'authored_by_me': True, 'repo': 'hq-pro', 'product': 'HQ Pro'},
        {'state': 'merged', 'created': '2026-10-10T12:00:00Z', 'closed': '2026-10-11T04:00:00Z', 'authored_by_me': True, 'repo': 'hq-pro', 'product': 'HQ Pro'},
        {'state': 'merged', 'created': '2026-10-11T01:00:00Z', 'closed': '2026-10-11T02:00:00Z', 'authored_by_me': True, 'repo': 'hq-desktop-app', 'product': 'Desktop app'},
        {'state': 'open', 'created': '2026-10-11T08:00:00Z', 'closed': None, 'authored_by_me': True, 'repo': 'hq-desktop-app', 'product': 'Desktop app'},
        {'state': 'merged', 'created': '2026-10-01T00:00:00Z', 'closed': '2026-10-02T00:00:00Z', 'authored_by_me': True, 'repo': 'hq-cloud', 'product': 'HQ Cloud'},  # before window
        {'state': 'open', 'created': '2026-10-11T09:00:00Z', 'authored_by_me': False, 'review_requested': True, 'repo': 'hq-core'},
    ]
    s = sweep.pr_summary(prs, start, end)
    assert (s['merged'], s['opened'], s['open'], s['review_requested']) == (4, 2, 1, 1), s
    # hours: 2.0 (row's own merge_hours wins), 14, 16, 1 -> sorted 1, 2, 14, 16 -> (2+14)/2
    assert s['median_merge_hours'] == 8.0, s
    assert [b['product'] for b in s['by_product']] == ['HQ Pro', 'Desktop app'], s['by_product']
    pro = s['by_product'][0]
    assert pro == {'product': 'HQ Pro', 'merged': 3, 'opened': 0, 'open': 0, 'median_merge_hours': 14.0}, pro
    desk = s['by_product'][1]
    assert desk == {'product': 'Desktop app', 'merged': 1, 'opened': 2, 'open': 1, 'median_merge_hours': 1.0}, desk
    assert sweep.pr_summary([], start, end)['median_merge_hours'] is None
    assert sweep._median([]) is None and sweep._median([3]) == 3 and sweep._median([1, 2, 3, 4]) == 2.5


def test_releases_and_pending_by_day():
    rows = [
        sweep.pr_row(_gh(1553, 'merged', '2026-10-10T19:17:03Z', '2026-10-10T21:13:12Z', 'Release 0.11.3'), True, False),
        sweep.pr_row(_gh(1536, 'closed', '2026-10-09T23:37:20Z', '2026-10-10T19:15:55Z', 'Release 0.11.2'), True, False),
        sweep.pr_row(_gh(1529, 'merged', '2026-10-09T15:40:45Z', '2026-10-09T21:56:50Z', 'Release 0.11.1: fixes release'), True, False),
        sweep.pr_row(_gh(1554, 'merged', '2026-10-10T21:30:00Z', '2026-10-10T23:00:00Z', 'fix(onboarding): tour'), True, False),
        sweep.pr_row(_gh(1555, 'merged', '2026-10-11T01:00:00Z', '2026-10-11T02:00:00Z', 'fix(onboarding): starter card'), True, False),
        sweep.pr_row(_gh(1556, 'merged', '2026-10-11T01:00:00Z', '2026-10-11T03:00:00Z', 'feat(storage): page'), True, False),
        sweep.pr_row(_gh(1557, 'open', '2026-10-11T13:26:50Z', '0001-01-01T00:00:00Z', 'fix(marketplace): name'), True, False),
        sweep.pr_row(_gh(1540, 'merged', '2026-10-10T10:00:00Z', '2026-10-10T12:00:00Z', 'fix: before the release'), True, False),
        sweep.pr_row(_gh(4890, 'merged', '2026-10-10T20:00:00Z', '2026-10-10T22:00:00Z', 'fix(auth): keys', repo='hq-pro'), True, False),
    ]
    rel = sweep.releases(rows)
    assert len(rel) == 1 and rel[0]['repo'] == 'hq-desktop-app' and rel[0]['product'] == 'Desktop app', rel
    r = rel[0]
    assert r['version'] == '0.11.3' and r['merged_at'] == '2026-10-10T21:13:12Z' and r['url'].endswith('/1553')
    assert r['pending_count'] == 3, r
    days = {d['day']: d for d in r['pending_by_day']}
    assert sum(d['count'] for d in days.values()) == 3 and len(days) in (1, 2)
    assert all(d['theme'] in ('onboarding', 'storage') for d in days.values()), days
    assert sweep.pr_theme(['fix(onboarding): a', 'fix(onboarding): b', 'feat(storage): c']) == 'onboarding'
    assert sweep.pr_theme(['fix: a', 'fix: b', 'feat: c']) == 'fixes'
    assert sweep.pr_theme(['Plain title']) == 'changes' and sweep.pr_theme([]) == 'changes'
    assert sweep.releases([rows[1]]) == []   # a closed, unmerged Release PR is not a release
    assert sweep.releases(None) == []


# ---------- main-branch health ----------
def test_red_workflows_since_and_merges_on_top():
    runs = [  # newest first, like gh run list
        {'name': 'gate', 'conclusion': '', 'status': 'in_progress', 'createdAt': '2026-10-11T14:00:00Z'},
        {'name': 'gate', 'conclusion': 'failure', 'createdAt': '2026-10-11T10:00:00Z'},
        {'name': 'gate', 'conclusion': 'failure', 'createdAt': '2026-10-10T10:00:00Z'},
        {'name': 'gate', 'conclusion': 'success', 'createdAt': '2026-10-09T10:00:00Z'},
        {'name': 'gate', 'conclusion': 'failure', 'createdAt': '2026-10-08T10:00:00Z'},  # older streak, not counted
        {'name': 'build', 'conclusion': 'success', 'createdAt': '2026-10-11T09:00:00Z'},
        {'name': 'build', 'conclusion': 'failure', 'createdAt': '2026-10-10T09:00:00Z'},
        {'name': 'nightly', 'conclusion': 'timed_out', 'createdAt': '2026-10-11T03:00:00Z'},
        {'name': 'queued', 'conclusion': '', 'status': 'queued', 'createdAt': '2026-10-11T03:00:00Z'},
    ]
    red = sweep.red_workflows(runs)
    assert red == [{'workflow': 'gate', 'since': '2026-10-10T10:00:00Z', 'merges_on_top': None},
                   {'workflow': 'nightly', 'since': '2026-10-11T03:00:00Z', 'merges_on_top': None}], red
    prs = [{'repo': 'hq-core-staging', 'state': 'merged', 'closed': '2026-10-10T12:00:00Z'},
           {'repo': 'hq-core-staging', 'state': 'merged', 'closed': '2026-10-10T09:00:00Z'},
           {'repo': 'hq-core-staging', 'state': 'open', 'closed': None},
           {'repo': 'hq-cloud', 'state': 'merged', 'closed': '2026-10-11T00:00:00Z'}]
    assert sweep.merges_on_top(prs, 'hq-core-staging', '2026-10-10T10:00:00Z') == 1
    assert sweep.merges_on_top(prs, 'hq-core-staging', None) is None
    assert sweep.red_workflows([]) == []


def test_main_health_delta_and_since_carry():
    cur = {'hq-core-staging': {'workflows': 6, 'red': [
                {'workflow': 'Recheck hq-core release gate', 'since': '2026-10-10T18:00:00Z', 'merges_on_top': 2},
                {'workflow': 'pr-checks', 'since': '2026-10-11T08:00:00Z', 'merges_on_top': 0}]},
           'hq-cloud': {'workflows': 3, 'red': [{'workflow': 'Sync nightly', 'since': None, 'merges_on_top': None}]},
           'hq-pro': {'workflows': 4, 'red': []},
           'hq-new': {'workflows': 1, 'red': []},
           'hq-broken': {'error': 'boom'}}
    prev = {'hq-core-staging': {'workflows': 2, 'red': ['Recheck hq-core release gate']},            # old shape
            'hq-cloud': {'workflows': 3, 'red': [{'workflow': 'Sync nightly', 'since': '2026-10-09T03:00:00Z'}]},
            'hq-pro': {'workflows': 9, 'red': ['Deploy']}}
    sweep.main_health_delta(cur, prev)
    core = cur['hq-core-staging']
    assert core['delta'] == {'newly_red': ['pr-checks'], 'still_red': ['Recheck hq-core release gate'], 'recovered': []}, core['delta']
    assert core['red'][0]['since'] == '2026-10-10T18:00:00Z'   # previous shape had no since: keep ours
    assert cur['hq-cloud']['red'][0]['since'] == '2026-10-09T03:00:00Z'  # carried back to the first red sighting
    assert cur['hq-pro']['delta'] == {'newly_red': [], 'still_red': [], 'recovered': ['Deploy']}
    assert cur['hq-new']['delta'] is None and 'delta' not in cur['hq-broken']
    sweep.main_health_delta(cur, None)
    assert cur['hq-pro']['delta'] is None
    assert sweep.red_names(['a', {'workflow': 'b'}, None]) == ['a', 'b']


# ---------- fleet ----------
def test_fleet_stuck_delta_series_and_count():
    agents = [{'name': 'Scout', 'status': 'active', 'phase': 'ready'},
              {'name': 'copybot', 'status': 'dormant', 'phase': 'ready'},
              {'name': 'newbie', 'status': 'provisioning', 'phase': 'waiting', 'since': '2026-10-11T10:00:00Z'},
              {'name': 'broken', 'status': 'provisioning', 'phase': 'failed', 'since': None},
              {'name': 'slow', 'status': 'active', 'phase': 'waiting'}]
    stuck = sweep.stuck_agents(agents)
    assert [s['name'] for s in stuck] == ['newbie', 'broken', 'slow'], stuck
    assert not sweep.is_stuck({'status': 'dormant', 'phase': 'ready'})
    prev = {'total': 5, 'agents': [{'name': 'broken', 'status': 'provisioning', 'phase': 'failed'},
                                   {'name': 'gone', 'status': 'provisioning', 'phase': 'waiting'},
                                   {'name': 'newbie', 'status': 'provisioning', 'phase': 'waiting', 'since': '2026-10-10T09:00:00Z'}]}
    delta = sweep.fleet_delta(stuck, prev, '2026-10-10T20:27:28+00:00')
    assert delta == {'newly_stuck': ['slow'], 'still_stuck': ['broken', 'newbie'], 'recovered': ['gone']}, delta
    by = {s['name']: s['since'] for s in stuck}
    assert by['broken'] == '2026-10-10T20:27:28+00:00'   # no timestamp anywhere: first seen at the previous run
    assert by['newbie'] == '2026-10-10T09:00:00Z'         # the earlier known sighting wins
    assert by['slow'] is None
    # previous run already carried a stuck list: it is used as is
    delta = sweep.fleet_delta([{'name': 'x', 'since': None}], {'stuck': [{'name': 'x', 'since': '2026-10-01T00:00:00Z'}]})
    assert delta['still_stuck'] == ['x']
    series = sweep.fleet_series([('2026-10-10T20:27:28+00:00', prev), ('2026-10-09T20:00:00+00:00', {'stuck': [{'name': 'a'}]}),
                                 ('2026-10-08T20:00:00+00:00', None)])
    assert series == [{'generated_at': '2026-10-09T20:00:00+00:00', 'stuck': 1},
                      {'generated_at': '2026-10-10T20:27:28+00:00', 'stuck': 3}], series
    assert sweep.count_of({'total': 48, 'agents': []}) == 48 and sweep.count_of([1, 2]) == 2
    assert sweep.count_of({'a': 1}) == 1 and sweep.count_of(None) is None
    row = sweep.agent_row({'name': 'A', 'agentStatus': 'active', 'setupPhase': 'ready', 'runtimeKind': 'hosted', 'updatedAt': 't'})
    assert row == {'name': 'A', 'status': 'active', 'phase': 'ready', 'runtime': 'hosted', 'since': 't'}


# ---------- meetings ----------
def test_meeting_detail_fields_attended_dedupe_and_window():
    det = {'meetingId': 'm1', 'title': 'Alex/Sam Standup', 'startTime': '2026-10-10T15:15:00-04:00', 'duration': 1800,
           'participants': [{'name': 'Alex Park', 'email': 'j@example.com', 'role': 'organizer'}, {'email': 'sam@example.com'}]}
    f = sweep.meeting_detail_fields(det)
    assert f == {'participants': ['Alex Park', 'sam@example.com'], 'end': '2026-10-10T15:45:00-04:00', 'duration_min': 30}, f
    f = sweep.meeting_detail_fields({'startTime': '2026-10-10T15:00:00Z', 'endTime': '2026-10-10T16:30:00Z'})
    assert f['duration_min'] == 90 and f['end'] == '2026-10-10T16:30:00+00:00'
    assert sweep.meeting_detail_fields(None) == {'participants': None, 'end': None, 'duration_min': None}
    me = ['Sam Rivera']
    assert sweep.attended({'title': 'Alex/Sam Standup', 'participants': None}, [], me)
    assert sweep.attended({'title': 'HQ Dev Standup', 'participants': ['Sam Rivera', 'Alex']}, [], me)
    assert sweep.attended({'title': 'HQ Dev Standup', 'participants': ['Alex']},
                          [{'action_items': [{'text': 'x', 'mine': True}]}], me)
    assert not sweep.attended({'title': 'HQ Dev Standup', 'participants': ['Alex']}, [{'decisions': [{'mine': False}]}], me)
    assert not sweep.attended({'title': 'Sams Bakery sync', 'participants': []}, [], me)  # no whole-word match
    rows = [{'id': 'a', 'title': '30 Min. Meeting w/ Robin Hale  (Sam Rivera)', 'start': '2026-10-10T14:40:00-06:00'},
            {'id': 'b', 'title': '30 Min. Meeting w/ Robin Hale (Sam Rivera)', 'start': '2026-10-10T14:40:00-06:00'},
            {'id': 'c', 'title': 'Other', 'start': '2026-10-10T16:00:00-06:00'}]
    sig = {'b': {'meeting_id': 'b', 'counts': {'decision': 3, 'summary': 1}}, 'a': {'meeting_id': 'a', 'counts': {'summary': 1}}}
    d = sweep.dedupe_meetings(rows, sig)
    assert [m['id'] for m in d] == ['b', 'c'] and d[0]['duplicate_ids'] == ['a'], d
    d = sweep.dedupe_meetings(rows[:2])  # no signal counts: the first row wins
    assert d[0]['id'] == 'a' and d[0]['duplicate_ids'] == ['b']
    lo, hi = T('2026-10-10T14:54:49Z'), T('2026-10-11T14:54:49Z')
    assert sweep.in_window('2026-10-10T14:40:00-06:00', lo, hi) and not sweep.in_window('2026-10-09T14:40:00-06:00', lo, hi)
    assert not sweep.in_window(None, lo, hi) and not sweep.in_window('bad', lo, hi)


def test_enrich_meetings_filters_window_and_fills_details():
    lo, hi = T('2026-10-10T14:54:49Z'), T('2026-10-11T14:54:49Z')
    meetings = [{'id': 'old', 'title': 'Jordan Lee / Sam Rivera', 'start': '2026-10-09T13:00:00-06:00', 'participants': None},
                {'id': 'a', 'title': 'Robin Hale (Sam Rivera)', 'start': '2026-10-10T14:40:00-06:00', 'participants': None},
                {'id': 'b', 'title': 'Robin Hale (Sam Rivera)', 'start': '2026-10-10T14:40:00-06:00', 'participants': None},
                {'id': 'c', 'title': 'HQ Dev Standup', 'start': '2026-10-11T09:00:00-04:00', 'participants': 4},
                {'id': 'd', 'title': 'Sales sync', 'start': '2026-10-11T10:00:00-04:00', 'participants': None},
                {'id': 'late', 'title': 'After the window', 'start': '2026-10-11T11:00:00-04:00', 'participants': None}]
    signals = [{'meeting_id': 'b', 'counts': {'decision': 3}, 'decisions': [{'text': 'x', 'mine': True}], 'action_items': [],
                'detail': {'participants': ['Robin Hale', 'Sam Rivera'], 'end': '2026-10-10T15:10:00-06:00', 'duration_min': 30}},
               {'meeting_id': 'a', 'counts': {'summary': 1}, 'decisions': [], 'action_items': [], 'detail': {'participants': None, 'end': None, 'duration_min': None}},
               {'meeting_id': 'c', 'counts': {}, 'decisions': [], 'action_items': [],
                'detail': {'participants': ['Alex Park', 'Jamie Cole'], 'end': None, 'duration_min': 45}},
               {'meeting_id': 'old', 'counts': {'decision': 3}, 'decisions': [{'text': 'x', 'mine': True}], 'action_items': []}]
    out = sweep.enrich_meetings(meetings, signals, ['Sam Rivera'], lo, hi)
    ids = [m['id'] for m in out]
    assert ids == ['b', 'c', 'd'], ids                       # 'old' is outside the window, 'a' folded into 'b'
    b = out[0]
    assert b['participants'] == ['Robin Hale', 'Sam Rivera'] and b['duration_min'] == 30 and b['attended'] is True
    assert b['end'] == '2026-10-10T15:10:00-06:00' and b['duplicate_ids'] == ['a']
    c = out[1]
    assert c['participants'] == ['Alex Park', 'Jamie Cole'] and c['attended'] is False and c['duration_min'] == 45
    d = out[2]
    assert d['participants'] is None and d['attended'] is False and d['duration_min'] is None
    assert sweep.enrich_meetings(None, None, [], lo, hi) == []
    # catch-up: a wider lower bound keeps the older meeting
    out = sweep.enrich_meetings(meetings, signals, ['Sam Rivera'], T('2026-10-08T00:00:00Z'), hi)
    assert out[0]['id'] == 'old' and out[0]['attended'] is True


def test_infer_owner_matches_decided_and_agreed():
    assert sweep.infer_owner('Sam Rivera decided to engage Robin Hale') == 'Sam Rivera'
    assert sweep.infer_owner('Jordan Lee agreed to review the lease with the lawyer') == 'Jordan Lee'
    assert sweep.infer_owner('Sam Rivera to build a page') == 'Sam Rivera'
    assert sweep.infer_owner('Sam Rivera and Robin Hale agreed to meet') is None
    assert sweep.infer_owner('We decided to ship Monday') is None


# ---------- DMs ----------
def test_dm_row_need_you_and_truncation():
    m = {'fromDisplayName': 'Jamie Cole', 'fromPersonUid': 'prs_1', 'createdAt': '2026-10-11T14:34:45.655Z',
         'body': 'Can you sign in and check the dashboard?', 'channelName': None}
    r = sweep.dm_row(m)
    assert r['from'] == 'Jamie Cole' and r['need_you'] is True and r['is_agent'] is False
    assert r['direction'] is None and r['thread_id'] is None and r['preview'].startswith('Can you')
    r = sweep.dm_row({'fromPersonUid': 'agt_1', 'body': 'Working on it, I will reply here when done.', 'threadId': 't9', 'direction': 'in'})
    assert r['is_agent'] and r['need_you'] is False and r['thread_id'] == 't9' and r['direction'] == 'in'
    for t in ('please take a look', 'I need you on this', 'Waiting on your answer', 'what do you think?', 'Could you approve'):
        assert sweep.need_you(t), t
    for t in ('Shipped the fix.', 'FYI the deploy finished', ''):
        assert not sweep.need_you(t), t
    sess_from = T('2026-10-10T14:54:49Z')
    rows = [{'at': f'2026-10-11T{h:02d}:00:00.000Z', 'need_you': h % 2 == 0} for h in range(40)][:40]
    rows = [{'at': '2026-10-10T16:11:35.309Z', 'need_you': False}] + rows[:39]
    t = sweep.dm_truncation(rows, 40, sess_from)
    assert t['truncated'] is True and t['oldest'] == '2026-10-10T16:11:35.309Z' and '2026-10-10T16:11' in t['note'], t
    assert t['need_you'] == 20 and t['limit'] == 40
    t = sweep.dm_truncation(rows[:10], 40, sess_from)
    assert t['truncated'] is False and t['note'] is None
    rows[0]['at'] = '2026-10-09T10:00:00Z'  # a full page that reaches before the window is complete
    assert sweep.dm_truncation(rows, 40, sess_from)['truncated'] is False
    assert sweep.dm_truncation([], 40, sess_from) == {'limit': 40, 'oldest': None, 'truncated': False, 'note': None, 'need_you': 0}
    findings = {}
    label, detail = sweep.summarize('dms', [sweep.dm_row(m), sweep.dm_row({'fromPersonUid': 'agt_1', 'body': 'done?'})], 'initech-test', findings, [])
    assert findings['dms'] == {'total': 2, 'need_you': 1} and detail == '1 may need you', (findings, detail)


def test_scope_dms_drops_another_companys_inbox_item():
    """A company brief keeps only that company's messages. A personal brief keeps
    only messages with no company. The other company's text is not kept."""
    rows = [
        {'fromDisplayName': 'Alex', 'fromPersonUid': 'prs_a', 'body': 'Please review the initech-test page', 'company': 'initech-test'},
        {'fromDisplayName': 'Sam', 'fromPersonUid': 'prs_s', 'body': 'globex-only secret note', 'companySlug': 'globex'},
        {'fromDisplayName': 'Jamie', 'fromPersonUid': 'prs_j', 'body': 'note to self', 'company': 'personal'},
        {'fromDisplayName': 'Robin', 'fromPersonUid': 'prs_r', 'body': 'channel ask for initech-test',
         'channel': {'name': 'launch', 'company_slug': 'initech-test'}},
    ]
    kept = sweep.scope_dms(rows, 'initech-test')
    assert [r['from'] for r in kept] == ['Alex', 'Robin'], kept
    blob = json.dumps(kept)
    assert 'globex-only' not in blob and 'note to self' not in blob, blob
    assert kept[0]['need_you'] is True and 'initech-test page' in kept[0]['preview']
    personal = sweep.scope_dms(rows, None)
    assert [r['from'] for r in personal] == ['Jamie'], personal
    assert 'globex-only' not in json.dumps(personal) and 'initech-test page' not in json.dumps(personal)
    calls = []

    def fake_jrun(cmd, timeout=90):
        calls.append(cmd)
        return {'events': [
            {'fromDisplayName': 'Alex', 'body': 'initech-test ping', 'company': 'initech-test'},
            {'fromDisplayName': 'Sam', 'body': 'globex ping', 'company': 'globex'},
        ]}

    saved = sweep.jrun
    sweep.SOURCES.clear()
    sweep.jrun = fake_jrun
    try:
        got = sweep.dms('initech-test')
        tagged_src = dict(sweep.SOURCES['dms'])
    finally:
        sweep.jrun = saved
        sweep.SOURCES.clear()
    assert calls and calls[0][:4] == ['hq', 'dm', 'inbox', '--limit'], calls
    assert [r['from'] for r in got] == ['Alex'] and 'globex ping' not in json.dumps(got), got
    assert tagged_src['state'] == 'ok' and tagged_src['count'] == 1, tagged_src
    assert sweep.inbox_rows([{'company': 'initech-test'}]) == [{'company': 'initech-test'}]
    assert sweep.inbox_rows({'messages': [{'company': 'initech-test'}]}) == [{'company': 'initech-test'}]


def _untagged_inbox():
    """Real `hq dm inbox --json` key layout, with neutral stand-ins for every value.

    Captured keys: every message has eventId, fromPersonUid, fromEmail,
    fromDisplayName, body, createdAt. Some also have details, prompt, companyUid,
    attachment and attachments. None have company, companySlug or company_slug.
    companyUid is an id, not a company slug."""
    with open(os.path.join(HERE, 'fixtures', 'dm-inbox-no-company.json'), encoding='utf-8') as f:
        rows = json.load(f)
    assert isinstance(rows, list) and rows
    keys = set().union(*(m.keys() for m in rows))
    for key in ('eventId', 'fromPersonUid', 'fromEmail', 'fromDisplayName', 'body', 'createdAt',
                'details', 'prompt', 'companyUid', 'attachment', 'attachments'):
        assert key in keys, key
    for key in ('company', 'companySlug', 'company_slug'):
        assert key not in keys, key
    assert any('companyUid' in m for m in rows)
    return rows


def test_untagged_inbox_is_skipped_in_company_mode_and_kept_when_personal():
    """A company brief must not report success with 0 DMs when the inbox has no
    company slug. Personal mode still includes those messages."""
    rows = _untagged_inbox()
    assert sweep.inbox_lacks_company_tag(rows) is True
    assert sweep.inbox_lacks_company_tag([]) is False
    assert sweep.inbox_lacks_company_tag([{'body': 'hi', 'company': 'initech-test'}]) is False
    assert sweep.has_company_tag({'companyUid': 'uid_example_not_a_slug', 'body': 'x'}) is False
    calls = []

    def fake_jrun(cmd, timeout=90):
        calls.append(list(cmd))
        return json.loads(json.dumps(rows))

    saved = sweep.jrun
    sweep.SOURCES.clear()
    sweep.jrun = fake_jrun
    try:
        skipped = sweep.dms('initech-test')
        company_src = dict(sweep.SOURCES['dms'])
        sweep.SOURCES.clear()
        sweep.jrun = lambda cmd, timeout=90: calls.append(list(cmd)) or []
        empty = sweep.dms('initech-test')
        empty_src = dict(sweep.SOURCES['dms'])
        sweep.SOURCES.clear()
        sweep.jrun = fake_jrun
        kept = sweep.dms(None)
        personal_src = dict(sweep.SOURCES['dms'])
    finally:
        sweep.jrun = saved
        sweep.SOURCES.clear()
    assert skipped is None
    assert company_src == {'ok': False, 'state': 'skipped', 'skipped_reason': 'inbox has no company tag', 'count': None}, company_src
    assert empty == [] and empty_src['state'] == 'ok' and empty_src['count'] == 0, empty_src
    assert [r['from'] for r in kept] == ['Alex', 'Sam', 'Alex'], kept
    assert personal_src['state'] == 'ok' and personal_src['count'] == 3, personal_src
    assert any('take a look' in r['preview'] for r in kept)
    assert calls and all(c[:4] == ['hq', 'dm', 'inbox', '--limit'] for c in calls), calls


def test_skipped_dms_status_says_skipped_not_empty():
    with tempfile.TemporaryDirectory() as root:
        path = os.path.join(root, 'status.json')
        st = sweep.Status(path, 'initech-test')
        st.start('Checking your DMs', 0.4)
        st.finish('dms', None, {'ok': False, 'state': 'failed', 'note': "Couldn't read DMs.",
                                'error': "Couldn't read DMs."}, 0.45)
        st.start('Checking your DMs', 0.5)
        st.finish('dms', None, {'ok': False, 'state': 'skipped',
                                'skipped_reason': 'inbox has no company tag', 'count': None}, 0.55)
        got = json.load(open(path))
    failed, skipped = got['activity']
    assert failed['state'] == 'failed' and failed['label'] == 'Checking your DMs' and failed['detail'] == "Couldn't read DMs.", failed
    assert skipped['state'] == 'skipped' and skipped['label'] == 'Skipped DMs', skipped
    assert skipped['detail'] == 'inbox has no company tag'
    assert '0 DMs' not in skipped['label'] and 'no message' not in json.dumps(skipped).lower()
    assert got['sources']['dms']['state'] == 'skipped'
    assert 'dms' not in got['findings']


# ---------- previous runs ----------
def test_ready_runs_and_prior_data():
    with tempfile.TemporaryDirectory() as ws:
        brief = os.path.join(ws, 'brief')
        os.makedirs(os.path.join(brief, 'r1'))
        os.makedirs(os.path.join(brief, 'r3'))
        with open(os.path.join(brief, 'index.jsonl'), 'w') as f:
            f.write(json.dumps({'run_id': 'r1', 'state': 'ready', 'created_at': '2026-10-09T10:00:00Z'}) + '\n')
            f.write('not json\n\n')
            f.write(json.dumps({'run_id': 'r2', 'state': 'failed', 'created_at': '2026-10-10T10:00:00Z'}) + '\n')
            f.write(json.dumps({'run_id': 'r3', 'state': 'ready', 'created_at': '2026-10-10T20:27:08Z'}) + '\n')
            f.write(json.dumps({'run_id': 'r4', 'state': 'ready', 'created_at': '2026-10-11T14:54:28Z'}) + '\n')  # current
            f.write(json.dumps({'run_id': 'r0', 'state': 'ready', 'created_at': '2026-10-08T10:00:00Z'}) + '\n')  # no folder
        runs = sweep.ready_runs(os.path.join(brief, 'index.jsonl'), 'r4')
        assert [r['run_id'] for r in runs] == ['r0', 'r1', 'r3'], runs
        with open(os.path.join(brief, 'r1', 'brief-data.json'), 'w') as f:
            json.dump({'generated_at': '2026-10-09T10:00:00+00:00', 'fleet': {'stuck': [{'name': 'a'}]}}, f)
        with open(os.path.join(brief, 'r3', 'brief-data.json'), 'w') as f:
            json.dump({'generated_at': '2026-10-10T20:27:28+00:00', 'main_health': {'hq-cloud': {'red': ['Sync nightly']}}}, f)
        prior = sweep.load_prior_data(brief, runs)
        assert [(i, at) for i, at, _ in prior] == [('r1', '2026-10-09T10:00:00+00:00'), ('r3', '2026-10-10T20:27:28+00:00')]
        assert prior[-1][2]['main_health']['hq-cloud']['red'] == ['Sync nightly']
        assert sweep.load_prior_data(brief, runs, limit=1)[0][0] == 'r3'
        assert sweep.ready_runs(os.path.join(ws, 'missing.jsonl')) == []


def test_prior_runs_stay_inside_the_briefs_company():
    with tempfile.TemporaryDirectory() as ws:
        brief = os.path.join(ws, 'brief')
        data = {'a1': 'initech-test', 'g1': 'globex', 'a2': 'initech-test', 'p1': None, 'old': 'initech-test'}
        for rid, co in data.items():
            os.makedirs(os.path.join(brief, rid))
            with open(os.path.join(brief, rid, 'brief-data.json'), 'w') as f:
                json.dump({'generated_at': '2026-10-10T00:00:00+00:00', 'company': co}, f)
        with open(os.path.join(brief, 'index.jsonl'), 'w') as f:
            # older line: no company field
            f.write(json.dumps({'run_id': 'old', 'state': 'ready', 'created_at': '2026-10-09T00:00:00Z'}) + '\n')
            for h, rid in enumerate(('a1', 'g1', 'a2', 'p1')):
                f.write(json.dumps({'run_id': rid, 'state': 'ready', 'company': data[rid],
                                    'created_at': f'2026-10-10T0{h}:00:00Z'}) + '\n')
            f.write(json.dumps({'run_id': 'g2', 'state': 'ready', 'company': 'globex', 'created_at': '2026-10-10T09:00:00Z'}) + '\n')
        idx = os.path.join(brief, 'index.jsonl')
        assert [r['run_id'] for r in sweep.ready_runs(idx)] == ['old', 'a1', 'g1', 'a2', 'p1', 'g2']
        assert [r['run_id'] for r in sweep.ready_runs(idx, company='initech-test')] == ['old', 'a1', 'a2']
        assert [r['run_id'] for r in sweep.ready_runs(idx, company=None)] == ['old', 'p1']
        runs = sweep.ready_runs(idx)
        assert [x[0] for x in sweep.load_prior_data(brief, runs, company='initech-test')] == ['old', 'a1', 'a2']
        assert [x[0] for x in sweep.load_prior_data(brief, runs, company='globex')] == ['g1']
        assert [x[0] for x in sweep.load_prior_data(brief, runs, company=None)] == ['p1']
        # the limit counts matching runs only, newest kept
        assert [x[0] for x in sweep.load_prior_data(brief, runs, limit=1, company='initech-test')] == ['a2']


# ---------- brief_rank additions ----------
def _brief():
    return {
        'today': '2026-10-11',
        'lead_hint': 'Close out the lease allotment first; investors wait on it.',
        'priorities': [
            {'rank': 1, 'text': 'Close out the lease allotment', 'item_id': 'd1', 'because': 'investors wait', 'score': 4},
            {'rank': 2, 'text': 'Unstick five fleet agents', 'item_id': 'p2', 'because': 'five agents idle', 'score': 1},
            {'rank': 3, 'text': 'Take over the finance handoff', 'item_id': 'h1', 'because': 'Jamie waits', 'score': 0},
            {'rank': 4, 'text': 'Fix the red release checks', 'item_id': 'c1', 'because': 'still red', 'score': 1},
        ],
        'counts': {'merged': 23, 'opened': 18, 'open': 6, 'review_requested': 0},
        'prefs_applied': {'widgets': {'pinned': ['runway'], 'muted': ['focus'], 'weights': {'team': -1}, 'density': 'auto'}},
        'items': {
            'decisions': [{'id': 'd1', 'title': 'Close out the lease allotment', 'product': 'Fundraise', 'company': 'initech-test',
                           'action': 'go', 'unlocks': ['round close'], 'people_waiting': 1, 'revenue': True},
                          {'id': 'd3', 'title': 'Fix the red release checks', 'product': 'HQ core', 'company': 'initech-test',
                           'action': 'decide', 'choices': ['Retry now', 'Hold a day'], 'unlocks': ['promotion']}],
            'waiting': [{'id': 'w1', 'who': 'Jamie', 'what': 'to review the pricing page', 'product': 'Marketing site', 'company': 'initech-test',
                         'age_hours': 26, 'kind': 'review'}],
            'incidents': [{'id': 'p2', 'title': 'Unstick five fleet agents', 'product': 'Fleet', 'company': 'initech-test', 'unlocks': ['x']}],
            'handoffs': [{'id': 'h1', 'object': 'Finance dashboard deploy', 'from': 'Jamie', 'to': 'Sam', 'me': True}],
            'carry': [{'id': 'c1', 'title': 'Fix the red release checks', 'item_id': 'd3', 'carried_from': 'brief-1'}],
            'shipped': [{'id': 's1', 'title': 'Desktop app: 6 changes shipped', 'product': 'Desktop app',
                         'highlights': ['The first-run tour no longer covers the Install Claude card', 'Starter plan limits now come from live pricing']}],
            'recovered': [{'id': 'f1', 'title': 'HQ Pro builds are green again'}],
            'releases': [{'product': 'Desktop app', 'version': '0.11.3', 'released_at': '2026-10-10T21:13:12Z',
                          'held': [{'title': 'Ship the storage page', 'why': 'held until the release'}]}],
            'reminders': [{'id': 'r1', 'text': 'remind me to check hq-desktop-app #1559 --force tomorrow', 'said_at': 't', 'where': 'dm'}],
        },
    }


def test_check_brief_clean_brief_passes():
    r = rank.check_brief(_brief())
    assert r['dangling_priorities'] == [] and r['priority_problems'] == [], r
    assert r['title_problems'] == [] and r['lead_hint_problem'] is None and r['widget_problems'] == []
    assert r['field_problems'] == [], r['field_problems']
    assert r['today_problem'] is None
    assert r['scores'] == {'d1': 4, 'd3': 1, 'p2': 1, 'h1': 0, 'c1': 1}, r['scores']
    assert r['index_counts'] == {'decisions': 2, 'shipped': 23, 'incidents': 1, 'carry': 1, 'recovered': 1}
    assert r['landed'] is True
    assert [p['item_id'] for p in r['priorities']] == ['d1', 'd3', 'p2']   # score 4, then two 1s by id


def test_check_brief_reports_dangling_scores_lead_and_widgets():
    b = _brief()
    b['priorities'][0]['item_id'] = 'd9'
    b['priorities'][1]['score'] = 3
    del b['priorities'][2]['score']
    b['priorities'][3]['because'] = ''
    b['priorities'][3]['text'] = 'Fix hq-core-staging #1239 gate'
    b['lead_hint'] = 'Investors wait on the lease allotment.'
    b['prefs_applied']['widgets'] = {'pinned': [], 'muted': ['needs', 'sunrise', 'team'], 'weights': {'team': -3, 'risk': 'x'}, 'density': 'dense'}
    b['today'] = '10/11/2026'
    r = rank.check_brief(b)
    assert r['dangling_priorities'] == [{'rank': 1, 'item_id': 'd9'}], r['dangling_priorities']
    pp = {p['rank']: p['problems'] for p in r['priority_problems']}
    assert pp[2] == ['score 3 should be 1'] and pp[3] == ['missing score (should be 0)'], pp
    assert 'missing because' in pp[4] and 'PR number' in pp[4] and any(x.startswith('repo name') for x in pp[4]), pp[4]
    assert pp[1] == [] if 1 in pp else True
    assert r['lead_hint_problem'].startswith('lead_hint must start with priority 1 text')
    assert r['widget_problems'] == ['needs cannot be muted', 'sunrise cannot be muted', 'weight team=-3 outside -2..2',
                                    "weight risk='x' outside -2..2", "density 'dense' not one of auto, calm, full"], r['widget_problems']
    assert r['today_problem'] == 'today must be YYYY-MM-DD'
    assert rank.check_brief({})['widget_problems'] == ['prefs_applied.widgets missing']
    assert rank.check_brief({})['lead_hint_problem'] is None and rank.check_brief({})['landed'] is False


def test_title_lint_extends_to_new_lists_and_exempts_reminders():
    b = _brief()
    b['items']['shipped'][0]['title'] = 'hq-desktop-app: 6 merged'
    b['items']['shipped'][0]['highlights'].append('feat(storage): add the Storage settings page #1550')
    b['items']['shipped'][0]['highlights'].append('A long plain line with more than eight words in it is still fine here')
    b['items']['handoffs'][0]['object'] = 'repos/private/billing-app deploy'
    b['items']['recovered'][0]['title'] = 'fix: hq-pro builds green'
    b['items']['releases'][0]['held'][0]['title'] = 'Ship storage page from hq-desktop-app #1550'
    r = rank.check_brief(b)
    got = {(p['list'], p['field']) for p in r['title_problems']}
    assert got == {('shipped', 'title'), ('shipped', 'highlights'), ('handoffs', 'object'), ('recovered', 'title'),
                   ('releases', 'held.title')}, got
    hl = [p for p in r['title_problems'] if p['field'] == 'highlights']
    assert len(hl) == 1 and 'commit prefix' in hl[0]['problems'] and 'PR number' in hl[0]['problems'], hl
    assert not any(p['list'] == 'reminders' for p in r['title_problems'])
    assert rank.lint_title('one two three four five six seven eight nine', max_words=None) == []
    assert rank.lint_title('one two three four five six seven eight nine') == ['9 words (max 8)']


def test_field_problems_action_and_waiting_who_what():
    b = _brief()
    del b['items']['decisions'][0]['action']
    b['items']['decisions'][1]['action'] = 'ship'
    # What every historical run wrote for a wait: title and why, nobody named. The app drops it.
    b['items']['waiting'].append({'id': 'w0', 'title': 'Review of the pricing page', 'why': 'It has sat a day', 'product': 'Marketing site', 'company': 'initech-test'})
    b['items']['waiting'].append({'id': 'w2', 'who': 'Casey', 'what': 'hq-cloud #913 review', 'product': 'HQ Cloud', 'company': 'initech-test'})
    r = rank.check_brief(b)
    got = [(p['list'], p['id'], p['field']) for p in r['field_problems']]
    assert got == [('decisions', 'd1', 'action'), ('decisions', 'd3', 'action'), ('waiting', 'w0', 'who')], got
    assert r['field_problems'][0]['problem'] == 'missing action (one of cut, go, decide, reply, prep)'
    assert r['field_problems'][1]['problem'].startswith("action 'ship' not one of")
    assert r['field_problems'][2]['problem'] == 'missing who (the app drops the row)'
    # The wait's `what` follows the title rule (title is read when `what` is missing).
    lint = {(p['id'], p['field']): p['problems'] for p in r['title_problems'] if p['list'] == 'waiting'}
    assert ('w2', 'what') in lint and 'PR number' in lint[('w2', 'what')] and 'repo name: hq-cloud' in lint[('w2', 'what')], lint
    assert ('w0', 'what') not in lint
    assert rank.field_problems({}) == []
    assert rank.field_problems({'waiting': [{'id': 'w9', 'who': 'Bo'}]}) == [{'list': 'waiting', 'id': 'w9', 'field': 'what', 'problem': 'missing what'}]


def test_apply_widget_prefs_refuses_unmutable_and_clamps():
    prefs = {'density': 'calm', 'pinned_widgets': ['runway'], 'muted_widgets': ['sunrise', 'focus', 'needs', 'catchup'],
             'widget_weights': {'team': -5, 'risk': 2, 'focus': 'lots'}}
    w, notes = rank.apply_widget_prefs(prefs)
    assert w == {'pinned': ['runway'], 'muted': ['focus'], 'weights': {'team': -2, 'risk': 2}, 'density': 'calm'}, w
    assert len(notes) == 5 and all('sunrise' in n or 'needs' in n or 'catchup' in n or 'team' in n or 'focus' in n for n in notes), notes
    assert rank.widget_problems(w) == []
    w, notes = rank.apply_widget_prefs({'density': 'dense'})
    assert w == {'pinned': [], 'muted': [], 'weights': {}, 'density': 'auto'} and notes == []
    assert rank.apply_widget_prefs(None)[0]['density'] == 'auto'


def test_index_counts_and_landed():
    assert rank.index_counts({'items': {'decisions': [{}], 'shipped': [{}, {}]}}) == \
        {'decisions': 1, 'shipped': 2, 'incidents': 0, 'carry': 0, 'recovered': 0}
    assert rank.landed({'counts': {'merged': 0}, 'items': {}}) is False
    assert rank.landed({'counts': {'merged': 0}, 'landed_days': ['2026-10-10']}) is True
    assert rank.landed({'counts': {'merged': 0}, 'items': {'releases': [{'released_at': '2026-10-10T21:13:12Z'}]}}) is True
    assert rank.landed({'counts': {'merged': 0}, 'items': {'releases': [{'released_at': None}]}}) is False


# ---------- the sweep's main() with every live source stubbed ----------
def test_main_offline_wires_derived_data():
    """Runs brief-sweep.main() against stubbed sources (no hq, gh or network) and
    checks the derived blocks land where the writer-additions contract says."""
    now = '2026-10-11T14:54:49Z'
    sess_rows = [{'id': 's1', 'started_at': '2026-10-11T04:39:34Z', 'company': 'initech-test', 'kind': 'you', 'title': 'Fix it',
                  'project': 'hq-desktop-app', 'cwd': '/r/repos/private/hq-desktop-app', 'last_activity': '2026-10-11T05:00:00Z'},
                 {'id': 's2', 'started_at': '2026-10-10T16:00:00Z', 'company': 'globex', 'kind': 'you', 'title': 'Secret', 'project': 'globex-app'},
                 {'id': 's3', 'started_at': '2026-10-11T05:00:00Z', 'company': 'initech-test', 'kind': 'agent', 'title': '[Owner context, checked by this bot]'},
                 {'id': 's4', 'started_at': '2026-10-11T05:30:00Z', 'company': 'initech-test', 'kind': 'lane', 'title': 'Execute the lane brief'}]
    mtgs = [{'id': 'old', 'title': 'Jordan / Sam Rivera', 'start': '2026-10-09T13:00:00-06:00', 'status': None, 'participants': None},
            {'id': 'new', 'title': 'Alex/Sam Standup', 'start': '2026-10-10T15:15:00-04:00', 'status': None, 'participants': None}]
    sigs = [{'meeting': 'Jordan / Sam Rivera', 'meeting_id': 'old', 'start': mtgs[0]['start'], 'counts': {'decision': 1},
             'decisions': [{'text': 'Sam Rivera decided to close the lease', 'owner': 'Sam Rivera', 'mine': True}], 'action_items': [],
             'detail': {'participants': ['Jordan Lee', 'Sam Rivera'], 'end': None, 'duration_min': 15}},
            {'meeting': 'Alex/Sam Standup', 'meeting_id': 'new', 'start': mtgs[1]['start'], 'counts': {'risk': 2},
             'decisions': [], 'action_items': [], 'detail': {'participants': ['Alex Park'], 'end': None, 'duration_min': 30}}]
    dm_rows = [sweep.dm_row({'fromDisplayName': 'Jamie', 'fromPersonUid': 'prs_1', 'createdAt': f'2026-10-11T{h:02d}:10:00.000Z',
                             'body': 'Can you check?' if h % 2 else 'Done.'}) for h in range(14)] * 3
    dm_rows = dm_rows[:40]
    fleet_block = {'total': 3, 'by_status': {'active': 2, 'provisioning': 1}, 'by_setup_phase': {'ready': 2, 'failed': 1},
                   'agents': [{'name': 'Scout', 'status': 'active', 'phase': 'ready', 'runtime': 'hosted', 'since': None},
                              {'name': 'broken', 'status': 'provisioning', 'phase': 'failed', 'runtime': 'hosted', 'since': None},
                              {'name': 'fixed', 'status': 'active', 'phase': 'ready', 'runtime': 'hosted', 'since': None}]}
    fleet_block['stuck'] = sweep.stuck_agents(fleet_block['agents'])
    pr_rows = [sweep.pr_row(_gh(1553, 'merged', '2026-10-10T19:17:03Z', '2026-10-10T21:13:12Z', 'Release 0.11.3'), True, False),
               sweep.pr_row(_gh(1554, 'merged', '2026-10-10T21:30:00Z', '2026-10-10T23:00:00Z', 'fix(onboarding): tour'), True, False),
               sweep.pr_row(_gh(1559, 'open', '2026-10-11T14:51:32Z', '0001-01-01T00:00:00Z', 'fix(onboarding): card'), True, False),
               sweep.pr_row(_gh(1239, 'merged', '2026-10-10T10:00:00Z', '2026-10-11T01:00:00Z', 'fix(gate): retry', repo='hq-core-staging'), True, False)]
    runs = {'hq-core-staging': [{'name': 'Recheck hq-core release gate', 'conclusion': 'failure', 'createdAt': '2026-10-11T02:00:00Z'},
                                {'name': 'Recheck hq-core release gate', 'conclusion': 'failure', 'createdAt': '2026-10-10T22:00:00Z'},
                                {'name': 'Recheck hq-core release gate', 'conclusion': 'success', 'createdAt': '2026-10-10T12:00:00Z'},
                                {'name': 'pr-checks', 'conclusion': 'success', 'createdAt': '2026-10-11T02:00:00Z'}],
            'hq-cloud': [{'name': 'Sync nightly', 'conclusion': 'success', 'createdAt': '2026-10-11T03:00:00Z'}]}

    def fake_main_health(repos, prs_rows=None):
        out = {}
        for r, full in repos:
            red = sweep.red_workflows(runs.get(r, []))
            for w in red:
                w['merges_on_top'] = sweep.merges_on_top(prs_rows, r, w['since'])
            out[r] = {'workflows': len({x['name'] for x in runs.get(r, [])}), 'product': sweep._product_for(r), 'red': red}
        return out

    saved = {k: getattr(sweep, k) for k in ('sessions', 'meetings', 'meeting_signals', 'dms', 'fleet', 'prs', 'main_health', 'read_session_lock')}
    sweep.SOURCES.clear()
    sweep.read_session_lock = lambda hq_root=None: ['initech-test']
    sweep.sessions = sweep.source('sessions')(lambda root, start, end, company: sorted(
        [sweep.session_row(r, company, {'s1'}) for r in sess_rows], key=lambda x: x['started_at']))
    sweep.meetings = sweep.source('meetings')(lambda company, since: list(mtgs))
    sweep.meeting_signals = sweep.source('meeting_signals')(lambda company, m, on_progress=None, me_names=(): list(sigs))
    sweep.dms = sweep.source('dms')(lambda *a, **k: list(dm_rows))
    sweep.fleet = sweep.source('fleet')(lambda company: json.loads(json.dumps(fleet_block)))
    sweep.prs = sweep.source('prs')(lambda org, since: json.loads(json.dumps(pr_rows)))
    sweep.main_health = sweep.source('main_health')(fake_main_health)
    try:
        with tempfile.TemporaryDirectory() as root:
            write_products(root)
            brief = os.path.join(root, 'workspace', 'brief')
            os.makedirs(os.path.join(brief, 'brief-' + _ts('20261010', '142540')))
            os.makedirs(os.path.join(brief, 'brief-' + _ts('20261011', '085324')))
            prev = {'generated_at': '2026-10-10T20:27:28+00:00', 'company': 'initech-test',
                    'main_health': {'hq-core-staging': {'workflows': 2, 'red': ['Recheck hq-core release gate']},
                                    'hq-cloud': {'workflows': 3, 'red': ['Sync nightly']}},
                    'fleet': {'total': 3, 'agents': [{'name': 'broken', 'status': 'provisioning', 'phase': 'failed'},
                                                     {'name': 'fixed', 'status': 'provisioning', 'phase': 'waiting'}]}}
            with open(os.path.join(brief, 'brief-' + _ts('20261010', '142540'), 'brief-data.json'), 'w') as f:
                json.dump(prev, f)
            os.makedirs(os.path.join(brief, 'brief-' + _ts('20261011', '010000')))
            with open(os.path.join(brief, 'brief-' + _ts('20261011', '010000'), 'brief-data.json'), 'w') as f:
                json.dump({'generated_at': '2026-10-11T01:00:00+00:00', 'company': 'globex',
                           'main_health': {'hq-core-staging': {'workflows': 1, 'red': []}}}, f)
            with open(os.path.join(brief, 'index.jsonl'), 'w') as f:
                f.write(json.dumps({'run_id': 'brief-' + _ts('20261010', '142540'), 'state': 'ready', 'created_at': '2026-10-10T20:27:08Z'}) + '\n')
                f.write(json.dumps({'run_id': 'brief-' + _ts('20261011', '010000'), 'state': 'ready', 'created_at': '2026-10-11T01:00:00Z'}) + '\n')
                f.write(json.dumps({'run_id': 'brief-' + _ts('20261011', '085324'), 'state': 'ready', 'created_at': '2026-10-11T14:54:28Z'}) + '\n')
            out = os.path.join(brief, 'brief-' + _ts('20261011', '085324'), 'brief-data.json')
            status = os.path.join(brief, 'brief-' + _ts('20261011', '085324'), 'status.json')
            argv = sys.argv
            sys.argv = ['brief-sweep.py', '--company', 'initech-test', '--days', '7', '--hours', '24', '--today', '2026-10-11',
                        '--now', now, '--hq-root', root, '--out', out, '--status', status, '--me', 'Sam Rivera',
                        '--org', 'o', '--repos', 'hq-core-staging,hq-cloud']
            try:
                import io, contextlib
                with contextlib.redirect_stdout(io.StringIO()):
                    sweep.main()
            finally:
                sys.argv = argv
            d = json.load(open(out))
            st = json.load(open(status))
    finally:
        for k, v in saved.items():
            setattr(sweep, k, v)
        sweep.SOURCES.clear()
    w = d['window']
    assert w['today'] == '2026-10-11' and w['attended_meetings_from'] == w['sessions_from'] == '2026-10-10T14:54:49+00:00', w
    # sessions: own row enriched, other-company row counted only
    s = {x['id']: x for x in d['sessions']}
    assert s['s1']['product'] == 'Desktop app' and s['s1']['has_handoff'] is True and s['s1']['cwd']
    assert s['s2']['company'] == 'other' and s['s2']['title'] is None and s['s2']['project'] is None
    # meetings: only the in-window one, enriched; the rollup still counts both
    assert [m['id'] for m in d['meetings']] == ['new'] and d['meetings'][0]['attended'] is True
    assert d['meetings'][0]['participants'] == ['Alex Park'] and d['meetings'][0]['duration_min'] == 30
    assert d['days']['2026-10-09']['meetings'] == 1 and d['days']['2026-10-10']['meetings'] == 1
    # the week arc counts the user's own sessions only; agent and lane rows stay out of the rollup
    assert sum(v['sessions'] for v in d['days'].values()) == 1, d['days']
    assert sum(v.get('other_sessions', 0) for v in d['days'].values()) == 1, d['days']
    assert d['sources']['meetings']['in_window'] == 1 and len(d['meeting_signals']) == 2
    # DMs: need_you flags and the truncation note
    assert d['sources']['dms']['truncated'] is True and 'Inbox cut at 40' in d['sources']['dms']['note']
    assert d['sources']['dms']['need_you'] == sum(1 for r in d['dms'] if r['need_you']) > 0
    # PRs, summary, releases
    assert d['prs_summary']['merged'] == 3 and d['prs_summary']['median_merge_hours'] is not None
    assert {b['product'] for b in d['prs_summary']['by_product']} == {'Desktop app', 'HQ core'}
    assert d['releases'][0]['version'] == '0.11.3' and d['releases'][0]['pending_count'] == 1
    # main health: red objects with since/merges_on_top and the delta vs the previous run
    core = d['main_health']['hq-core-staging']
    assert core['red'] == [{'workflow': 'Recheck hq-core release gate', 'since': '2026-10-10T22:00:00Z', 'merges_on_top': 1}], core
    assert core['delta'] == {'newly_red': [], 'still_red': ['Recheck hq-core release gate'], 'recovered': []}
    assert d['main_health']['hq-cloud']['delta'] == {'newly_red': [], 'still_red': [], 'recovered': ['Sync nightly']}
    # fleet: stuck list, delta by name, series over prior runs, agent count in sources
    fl = d['fleet']
    assert [x['name'] for x in fl['stuck']] == ['broken'] and fl['stuck'][0]['since'] == '2026-10-10T20:27:28+00:00'
    assert fl['delta'] == {'newly_stuck': [], 'still_stuck': ['broken'], 'recovered': ['fixed']}, fl['delta']
    assert fl['series'] == [{'generated_at': '2026-10-10T20:27:28+00:00', 'stuck': 2}]
    assert d['sources']['fleet']['count'] == 3
    # the globex run in between is skipped: the delta and previous run are initech-test's
    assert d['previous_run'] == {'run_id': 'brief-' + _ts('20261010', '142540'), 'generated_at': '2026-10-10T20:27:28+00:00'}
    assert st['findings']['dms']['need_you'] > 0 and st['findings']['ci_red'] == 1 and st['sources']['fleet']['count'] == 3
    # a company brief keeps every source, says so in `mode`, and adds no welcome unless asked
    assert d['company'] == 'initech-test' and d['mode'] == 'company' and d['welcome'] is None
    assert all(d['sources'][k]['state'] == 'ok' for k in ('meetings', 'meeting_signals', 'fleet')), d['sources']


# ---------- company-optional (personal) briefs ----------
class _FakeLocalSessions:
    """Stands in for local_sessions.py in the welcome scan."""

    def __init__(self, rows):
        self.rows = rows

    def scan(self, root, start, end):
        return [dict(r) for r in self.rows]

    def repo_from_cwd(self, cwd):
        parts = cwd.rstrip('/').split('/')
        return parts[parts.index('repos') + 2] if 'repos' in parts and len(parts) > parts.index('repos') + 2 else None


def _run_personal(root, extra_argv=(), scan_rows=(), mode=('--personal',), seen=None, stub_dms=True):
    now = '2026-10-11T14:54:49Z'
    sess_rows = [{'id': 'p1', 'started_at': '2026-10-11T04:39:34Z', 'company': None, 'kind': 'you', 'title': 'Fix it',
                  'project': 'hq-desktop-app', 'cwd': '/r/repos/private/hq-desktop-app'},
                 {'id': 'p2', 'started_at': '2026-10-11T05:00:00Z', 'company': 'globex', 'kind': 'you', 'title': 'Secret'}]
    pr_rows = [sweep.pr_row(_gh(1553, 'merged', '2026-10-11T05:17:03Z', '2026-10-11T07:13:12Z', 'fix(x): y'), True, False)]
    called = []
    names = ('sessions', 'meetings', 'meeting_signals', 'dms', 'fleet', 'prs', 'main_health', '_load_local_sessions', 'read_session_lock', 'membership_slugs')
    saved = {k: getattr(sweep, k) for k in names}
    sweep.SOURCES.clear()
    sweep.membership_slugs = lambda hq_root: []
    locked = mode[mode.index('--company') + 1] if '--company' in mode else None
    sweep.read_session_lock = lambda hq_root=None, _c=locked: ([_c] if _c else [])
    sweep.sessions = sweep.source('sessions')(lambda root_, start, end, company: [sweep.session_row(r, company, set()) for r in sess_rows])
    for k in ('meetings', 'meeting_signals', 'fleet'):
        setattr(sweep, k, sweep.source(k)(lambda *a, _k=k, **kw: called.append(_k) or (
            {'total': 0, 'by_status': {}, 'by_setup_phase': {}, 'agents': []} if _k == 'fleet' else [])))
    if stub_dms:
        sweep.dms = sweep.source('dms')(lambda *a, **k: [])
    seen = {} if seen is None else seen
    sweep.prs = sweep.source('prs')(lambda org, since: seen.setdefault('org', org) and False or json.loads(json.dumps(pr_rows)))
    sweep.main_health = sweep.source('main_health')(lambda repos, prs_rows=None: {r: {'workflows': 0, 'red': []} for r, _ in repos})
    sweep._load_local_sessions = lambda: _FakeLocalSessions(list(scan_rows))
    brief = os.path.join(root, 'workspace', 'brief', 'brief-' + _ts('20261011', '085324'))
    os.makedirs(brief, exist_ok=True)
    out = os.path.join(brief, 'brief-data.json')
    status = os.path.join(brief, 'status.json')
    argv = sys.argv
    sys.argv = ['brief-sweep.py', *mode, '--today', '2026-10-11', '--now', now, '--hq-root', root,
                '--out', out, '--status', status, '--me', 'Sam Rivera', *extra_argv]
    try:
        import io, contextlib
        with contextlib.redirect_stdout(io.StringIO()):
            sweep.main()
    finally:
        sys.argv = argv
        for k, v in saved.items():
            setattr(sweep, k, v)
        sweep.SOURCES.clear()
    return json.load(open(out)), json.load(open(status)), called


def test_company_brief_marks_an_untagged_inbox_skipped_in_the_brief():
    """The written brief and status say DMs were skipped, not that there were no messages.
    A personal run of the same page keeps the rows."""
    rows = _untagged_inbox()
    saved = sweep.jrun
    sweep.jrun = lambda cmd, timeout=90: json.loads(json.dumps(rows))
    try:
        with tempfile.TemporaryDirectory() as root:
            write_products(root)
            d, st, _ = _run_personal(root, mode=('--company', 'initech-test'), stub_dms=False)
            personal, _, _ = _run_personal(root, stub_dms=False)
    finally:
        sweep.jrun = saved
        sweep.SOURCES.clear()
    assert d['dms'] is None and d['mode'] == 'company'
    assert d['sources']['dms'] == {'ok': False, 'state': 'skipped',
                                   'skipped_reason': 'inbox has no company tag', 'count': None}, d['sources']['dms']
    assert 'take a look' not in json.dumps(d)
    skipped = [a for a in st['activity'] if a.get('label') == 'Skipped DMs']
    assert len(skipped) == 1 and skipped[0]['state'] == 'skipped', st['activity']
    assert skipped[0]['detail'] == 'inbox has no company tag'
    assert 'dms' not in st['findings']
    blob = json.dumps(st['activity']).lower()
    assert '0 dms' not in blob and 'no message' not in blob
    assert personal['mode'] == 'personal' and personal['sources']['dms']['state'] == 'ok'
    assert [r['from'] for r in personal['dms']] == ['Alex', 'Sam', 'Alex']
    assert any('take a look' in r['preview'] for r in personal['dms'])


def test_personal_brief_skips_company_sources_and_adds_the_welcome():
    scan_rows = [{'id': 'p1', 'started_at': '2026-10-11T04:39:34Z', 'company': None, 'tool': 'claude',
                  'cwd': '/r/repos/private/hq-desktop-app', 'project': None},
                 {'id': 'p3', 'started_at': '2026-10-09T10:00:00Z', 'company': None, 'tool': 'codex', 'cwd': None, 'project': 'notes'},
                 {'id': 'p2', 'started_at': '2026-10-11T05:00:00Z', 'company': 'globex', 'tool': 'claude',
                  'cwd': '/r/repos/private/globex-app', 'project': 'globex-app'}]
    with tempfile.TemporaryDirectory() as root:
        write_products(root)
        d, st, called = _run_personal(root, scan_rows=scan_rows)
    assert called == [], called
    assert d['company'] is None and d['mode'] == 'personal'
    for k in ('meetings', 'meeting_signals', 'fleet', 'integrations'):
        assert d['sources'][k] == {'ok': False, 'state': 'skipped', 'skipped_reason': 'needs a company', 'count': None}, k
        if k != 'integrations':
            assert d[k] is None, k
    assert d['sources']['sessions']['state'] == 'ok' and d['sources']['prs']['state'] == 'ok'
    # the person's own unbound rows carry the personal tag; another company's rows are counted only
    s = {x['id']: x for x in d['sessions']}
    assert s['p1']['company'] == 'personal' and s['p1']['title'] == 'Fix it'
    assert s['p2']['company'] == 'other' and s['p2']['title'] is None
    assert sum(v['sessions'] for v in d['days'].values()) == 1 and d['main_health'] == {'hq-desktop-app': {'workflows': 0, 'red': [], 'delta': None}}
    w = d['welcome']
    # no report, but past sessions are on this Mac: they count as imported
    assert w['first_run'] is True and w['import']['source'] == 'detected', w['import']
    assert w['import']['sessions']['total'] == 3 and w['import']['path'] is None, w['import']
    assert w['sessions'] == {'total': 3, 'local': 3, 'imported': 3, 'claude': 2, 'codex': 1, 'cursor': 0,
                             'days_seen': 2}, w['sessions']
    assert w['repos'] == [{'name': 'hq-desktop-app', 'sessions': 1}, {'name': 'notes', 'sessions': 1}], w['repos']
    assert w['apps'] == ['Claude Code', 'Codex']
    assert [x['kind'] for x in w['next_steps']] == ['connect_company']
    assert w['headline'].startswith('HQ found 3 past sessions') and 'Claude Code' in w['headline'], w['headline']
    # the other company's folder is counted, never named
    assert [x['name'] for x in w['top_projects']] == ['hq-desktop-app'], w['top_projects']
    assert 'globex' not in json.dumps(w), w
    assert sum(x['primary'] for x in w['actions']) == 1, w['actions']
    assert 'getting_started' not in w and 'note' not in w
    assert 'meetings' not in [a.get('key') for a in st.get('activity', [])]


def test_personal_brief_after_a_ready_run_has_no_welcome_unless_asked():
    with tempfile.TemporaryDirectory() as root:
        write_products(root)
        idx = os.path.join(root, 'workspace', 'brief', 'index.jsonl')
        os.makedirs(os.path.dirname(idx), exist_ok=True)
        with open(idx, 'w') as f:
            f.write(json.dumps({'run_id': 'brief-' + _ts('20261010', '142540'), 'state': 'ready', 'created_at': '2026-10-10T20:27:08Z'}) + '\n')
        d, _, _ = _run_personal(root)
        assert d['welcome'] is None
        d, _, _ = _run_personal(root, ['--welcome'])
        assert d['welcome']['first_run'] is False and d['welcome']['sessions']['total'] == 0


def _write_manifest(root, owners):
    os.makedirs(os.path.join(root, 'companies'), exist_ok=True)
    with open(os.path.join(root, 'companies', 'manifest.yaml'), 'w') as f:
        f.write('version: 1\ncompanies:\n')
        for co, owner in owners.items():
            f.write(f'  {co}:\n    name: {co.title()}\n    github_org: {owner}  # GitHub owner\n    repos: []\n')


def test_company_brief_defaults_org_from_the_manifest():
    with tempfile.TemporaryDirectory() as root:
        write_products(root)
        _write_manifest(root, {'initech-test': 'o', 'globex': 'globex-gh'})
        seen = {}
        d, _, _ = _run_personal(root, mode=('--company', 'initech-test'), seen=seen)
        assert seen['org'] == 'o', seen
        assert [p['repo_full'] for p in d['prs']] == ['o/hq-desktop-app'] and d['prs_other'] == 0
        seen = {}
        _run_personal(root, ['--org', 'x'], mode=('--company', 'initech-test'), seen=seen)
        assert seen['org'] == 'x', seen


def test_personal_brief_drops_prs_from_company_owners():
    with tempfile.TemporaryDirectory() as root:
        write_products(root)
        _write_manifest(root, {'initech-test': 'o'})
        seen = {}
        d, st, _ = _run_personal(root, seen=seen)
    assert seen['org'] is None
    assert d['prs'] == [] and d['prs_other'] == 1, (d['prs'], d['prs_other'])
    assert d['sources']['prs']['count'] == 0 and d['sources']['prs']['other'] == 1, d['sources']['prs']
    assert 'fix(x): y' not in json.dumps(d)


def test_days_outside_1_to_14_is_refused():
    import io, contextlib
    for days in ('0', '15'):
        saved, sys.argv = sys.argv, ['brief-sweep.py', '--personal', '--days', days, '--out', '/dev/null']
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                sweep.main()
        except SystemExit as e:
            assert e.code == 2
        else:
            raise AssertionError(f'--days {days} should exit')
        finally:
            sys.argv = saved


def test_company_outside_the_session_lock_is_refused():
    """--company must be one of the slugs `hq-session.sh get company_slugs` prints."""
    import io, contextlib
    sweep.enforce_company_lock(None, [])
    sweep.enforce_company_lock('initech-test', ['initech-test', 'globex'])
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            sweep.enforce_company_lock('globex', ['initech-test'])
    except SystemExit as e:
        assert e.code == 1, e.code
    else:
        raise AssertionError('a company outside the lock should be refused')
    msg = err.getvalue()
    assert 'globex' in msg and 'outside' in msg and 'initech-test' in msg, msg
    with tempfile.TemporaryDirectory() as root:
        script_dir = os.path.join(root, 'core', 'scripts')
        os.makedirs(script_dir)
        with open(os.path.join(script_dir, 'hq-session.sh'), 'w') as f:
            f.write('#!/bin/bash\nprintf %s "initech-test,globex"\n')
        assert sweep.read_session_lock(root) == ['initech-test', 'globex']
        saved, sys.argv = sys.argv, ['brief-sweep.py', '--company', 'other', '--hq-root', root,
                                     '--out', os.path.join(root, 'out.json')]
        err = io.StringIO()
        try:
            with contextlib.redirect_stderr(err):
                sweep.main()
        except SystemExit as e:
            assert e.code == 1, e.code
        else:
            raise AssertionError('--company outside the lock should be refused')
        finally:
            sys.argv = saved
        msg = err.getvalue()
        assert 'other' in msg and 'outside' in msg and 'initech-test' in msg and 'globex' in msg, msg
        assert not os.path.exists(os.path.join(root, 'out.json'))


def test_company_personal_and_all_flags_are_exclusive():
    import io, contextlib
    for argv in (['brief-sweep.py', '--all', '--personal', '--out', '/dev/null'],
                 ['brief-sweep.py', '--company', 'initech-test', '--personal', '--out', '/dev/null']):
        saved, sys.argv = sys.argv, argv
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                sweep.main()
        except SystemExit as e:
            assert e.code == 2
        else:
            raise AssertionError(f'{argv} should exit')
        finally:
            sys.argv = saved


def test_health_repos_resolves_owners_without_a_default_org():
    rows = [dict(sweep.pr_row(_gh(1, 'open', '2026-10-11T00:00:00Z', None, repo='a'), True, False)),
            dict(sweep.pr_row(_gh(2, 'open', '2026-10-11T00:00:00Z', None, repo='a'), True, False)),
            dict(sweep.pr_row(_gh(3, 'open', '2026-10-11T00:00:00Z', None, repo='b'), True, False)),
            dict(sweep.pr_row(_gh(4, 'open', '2026-10-11T00:00:00Z', None, repo='c'), False, True))]
    assert rows[0]['repo_full'] == 'o/a'
    # no --repos: the person's own PR repos, most PRs first; review-only repos stay out
    assert sweep.health_repos(None, None, rows) == [('a', 'o/a'), ('b', 'o/b')]
    # bare names resolve through the PR rows; unknown bare names are dropped
    assert sweep.health_repos(['b', 'nope', 'x/y', 'b'], None, rows) == [('b', 'o/b'), ('y', 'x/y')]
    # --org qualifies bare names
    assert sweep.health_repos(['nope'], 'z', rows) == [('nope', 'z/nope')]
    assert len(sweep.health_repos([f'o/r{i}' for i in range(20)], None, [])) == sweep.HEALTH_REPOS_MAX
    assert sweep.health_repos(None, None, None) == []


def test_prs_searches_every_owner_unless_org_is_set():
    calls = []
    saved = sweep.jrun, sweep._review_meta
    sweep.jrun = lambda cmd, timeout=90: calls.append(cmd) or []
    sweep._review_meta = lambda rows: {}
    try:
        assert sweep.prs(None, '2026-10-01') == [] and sweep.SOURCES['prs']['state'] == 'ok', sweep.SOURCES
        assert calls and all('--owner' not in c for c in calls), calls
        calls.clear()
        assert sweep.prs('o', '2026-10-01') == [] and sweep.SOURCES['prs']['state'] == 'ok', sweep.SOURCES
        assert calls and all(c[c.index('--owner') + 1] == 'o' for c in calls), calls
    finally:
        sweep.jrun, sweep._review_meta = saved
        sweep.SOURCES.clear()


def test_latest_import_reads_the_newest_report_counts():
    with tempfile.TemporaryDirectory() as root:
        assert sweep.latest_import(root) is None
        base = os.path.join(root, 'workspace', 'imports')
        for stamp, rep in (('20261001T000000Z', {'scan_id': 'old', 'counts': {'skills': 1}}),
                           ('20261010T000000Z', {'scan_id': 'scan-1', 'counts': {'skills': 4, 'conversations': 12, 'plans': 'x'}}),
                           ('20261011T000000Z', None)):
            os.makedirs(os.path.join(base, stamp))
            if rep is not None:
                _write_json(os.path.join(base, stamp, 'report.json'), rep)
        got = sweep.latest_import(root)
        assert got['path'] == os.path.join('workspace', 'imports', '20261010T000000Z', 'report.json')
        assert got['scanned_at'] == '2026-10-10T00:00:00Z' and got['skills'] == 4 and got['conversations'] == 12 and got['plans'] == 0
        assert list(got) == list(sweep.IMPORT_FIELDS), list(got)
        # an /import-context report with no categories: no session total, no tools
        assert got['source'] == 'import-context' and got['sessions']['total'] is None and got['tools'] == []
        with open(os.path.join(base, '20261011T000000Z', 'report.json'), 'w') as f:
            f.write('not json')
        assert sweep.latest_import(root)['scanned_at'] == '2026-10-10T00:00:00Z'


def test_welcome_block_names_only_the_brief_companys_repos():
    rows = [{'company': 'initech-test', 'tool': 'claude', 'started_at': '2026-10-11T01:00:00Z', 'cwd': '/r/repos/public/web'},
            {'company': 'globex', 'tool': 'codex', 'started_at': '2026-10-10T01:00:00Z', 'cwd': '/r/repos/private/secret'},
            {'company': None, 'tool': None, 'started_at': '2026-10-10T02:00:00Z', 'project': 'loose'}]
    saved = sweep._load_local_sessions
    sweep._load_local_sessions = lambda: _FakeLocalSessions([])
    try:
        w = sweep.welcome_block(rows, 'initech-test', False, {'path': 'p', 'scanned_at': 's'})
    finally:
        sweep._load_local_sessions = saved
    assert w['repos'] == [{'name': 'web', 'sessions': 1}]
    assert w['sessions'] == {'total': 3, 'local': 3, 'imported': 0, 'claude': 1, 'codex': 1, 'cursor': 0,
                             'days_seen': 2}
    assert [x['kind'] for x in w['next_steps']] == ['connect_integration', 'sync']
    assert [x['name'] for x in w['top_projects']] == ['web'] and 'secret' not in json.dumps(w)
    assert all(x['id'] and x['reason'] for x in w['next_steps'])


def _write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        json.dump(obj, f)


def test_fixtures_use_neutral_names():
    """Daily-brief fixtures name people Alex and Sam. Owner given-names are not
    written in the test files; this check assembles them so the source does not
    store the words."""
    banned = [a + b for a, b in (('Cor', 'ey'), ('Jac', 'ob'), ('Geo', 'ff'), ('Rac', 'hel'))]
    pat = re.compile(r'\b(' + '|'.join(map(re.escape, banned)) + r')\b')
    here = os.path.dirname(os.path.abspath(__file__))
    files = [os.path.join(here, n) for n in sorted(os.listdir(here)) if n.startswith('test_') and n.endswith('.py')]
    fixture_dir = os.path.join(here, 'fixtures')
    if os.path.isdir(fixture_dir):
        files.extend(os.path.join(fixture_dir, n) for n in sorted(os.listdir(fixture_dir)) if n.endswith('.json'))
    hits = []
    for path in files:
        with open(path, encoding='utf-8') as f:
            for i, line in enumerate(f, 1):
                if pat.search(line):
                    hits.append(f'{os.path.basename(path)}:{i}')
    assert not hits, '\n'.join(hits)
    text = open(os.path.join(here, 'test_brief_additions.py'), encoding='utf-8').read()
    assert 'Alex' in text and 'Sam' in text


def test_shipped_files_carry_no_owner_values():
    """The skill ships to every HQ install: no owner org, people or pronouns.
    Fixture people are Alex and Sam; those names are allowed in the skill text."""
    here = os.path.dirname(os.path.abspath(__file__))
    files = [os.path.join(here, n) for n in sorted(os.listdir(here)) if n.endswith('.py') and not n.startswith('test_')]
    files.append(os.path.join(os.path.dirname(here), 'SKILL.md'))
    words = ['initech-co', 'Initech Co', 'CEO', 'him', 'his']
    pat = re.compile(r'\b(' + '|'.join(map(re.escape, words)) + r')\b')
    hits = []
    for path in files:
        with open(path, encoding='utf-8') as f:
            for i, line in enumerate(f, 1):
                for m in pat.finditer(line):
                    hits.append(f'{os.path.basename(path)}:{i}: {m.group(0)}')
    assert not hits, '\n'.join(hits)


# ---------- welcome edition: machine inventory and the person's work ----------
ls_mod = load('local_sessions_welcome', 'local_sessions.py')


def _jl(*records):
    return ''.join(json.dumps(r, separators=(',', ':')) + '\n' for r in records)


def _put(path, text, mtime=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)
    if mtime is not None:
        os.utime(path, (mtime, mtime))


def _claude_transcript(cwd, title=None):
    recs = [{'type': 'user', 'cwd': cwd, 'message': {'content': 'Tidy the release notes'}}]
    if title:
        recs.append({'type': 'custom-title', 'customTitle': title})
    return _jl(*recs)


def _codex_rollout(cwd, prompt='Plan the launch checklist'):
    return _jl({'type': 'session_meta', 'payload': {'cwd': cwd}},
               {'type': 'response_item', 'payload': {'role': 'user', 'content': [{'type': 'input_text', 'text': prompt}]}})


def _fixture_home(home):
    """A synthetic Mac: two Claude Code config folders, Codex and Cursor."""
    base = _TS0
    web, notes = os.path.join(home, 'code', 'web'), os.path.join(home, 'code', 'notes')
    os.makedirs(os.path.join(web, '.git'))
    os.makedirs(notes)
    for i in range(3):
        _put(os.path.join(home, '.claude', 'projects', '-code-web', f'c-web-{i}.jsonl'),
             _claude_transcript(web, f'Ship the web fix {i}'), base + i * 3600)
    _put(os.path.join(home, 'alt-config', 'projects', '-code-notes', 'c-notes-0.jsonl'),
         _claude_transcript(notes, 'Write the notes index'), base + 20 * 3600)
    for i in range(2):
        _put(os.path.join(home, '.codex', 'sessions', '2026', '10', '01', f'rollout-2026-10-01T10-00-0{i}-x-{i}.jsonl'),
             _codex_rollout(web), base + (10 + i) * 3600)
    _put(os.path.join(home, '.codex', 'history.jsonl'), _jl({'a': 1}, {'a': 2}, {'a': 3}))
    _put(os.path.join(home, 'cursor-ws', 'w1', 'state.vscdb'), '')
    os.makedirs(os.path.join(home, 'cursor-ws', 'w2'))  # no chat state: not counted
    return web, notes


def _inventory(home, **kw):
    roots = ls_mod.claude_project_roots(home, {'CLAUDE_CONFIG_DIR': os.path.join(home, 'alt-config')})
    return ls_mod.inventory(claude_roots=roots, codex_root=os.path.join(home, '.codex'),
                            cursor_root=os.path.join(home, 'cursor-ws'), **kw)


def test_inventory_counts_every_harness_in_a_fixture_home():
    """The first brief counted only HQ-started sessions. The inventory counts
    every Claude Code transcript (both config folders), Codex rollout and Cursor
    workspace."""
    with tempfile.TemporaryDirectory() as home:
        web, notes = _fixture_home(home)
        inv = _inventory(home)
    assert inv['counts'] == {'claude_code': 4, 'codex': 2, 'cursor': 1}, inv['counts']
    assert 'history_lines' not in inv and inv['unplaced'] == 0 and inv['notes'] == []
    assert len(inv['sessions']) == 6 and inv['sessions']['c-notes-0'] == 'claude_code'
    assert inv['sessions']['x-1'] == 'codex', inv['sessions']
    assert inv['projects'][web]['sessions'] == 5 and inv['projects'][web]['by_harness'] == {'claude_code': 3, 'codex': 2}
    assert inv['projects'][notes]['sessions'] == 1
    assert [r['id'] for r in inv['recent']][0] == 'c-notes-0'


def test_claude_project_roots_reads_claude_config_dir():
    with tempfile.TemporaryDirectory() as home:
        _fixture_home(home)
        alt = os.path.join(home, 'alt-config')
        assert ls_mod.claude_project_roots(home, {}) == [os.path.realpath(os.path.join(home, '.claude', 'projects'))]
        both = ls_mod.claude_project_roots(home, {'CLAUDE_CONFIG_DIR': alt})
        assert both[1] == os.path.realpath(os.path.join(alt, 'projects')), both
        # the same folder twice is listed once
        assert len(ls_mod.claude_project_roots(home, {'CLAUDE_CONFIG_DIR': os.path.join(home, '.claude')})) == 1


def test_inventory_counts_everything_after_the_time_budget():
    """Past the budget, sessions are still counted; only their project is left
    out, with a plain note."""
    ticks = iter(range(0, 10 ** 6))
    with tempfile.TemporaryDirectory() as home:
        _fixture_home(home)
        inv = _inventory(home, budget_s=1, clock=lambda: next(ticks))
    assert sum(inv['counts'].values()) == 7 and len(inv['sessions']) == 6
    assert inv['unplaced'] > 0 and inv['notes'] == ['Some older sessions were counted without their project'], inv


def test_inventory_runtime_stays_bounded():
    """Benchmark: 40 projects x 30 transcripts plus 200 Codex rollouts in well
    under the brief's 3-minute budget (reads are capped per project)."""
    import time
    with tempfile.TemporaryDirectory() as home:
        for p in range(40):
            cwd = os.path.join(home, 'code', f'p{p}')
            for i in range(30):
                _put(os.path.join(home, '.claude', 'projects', f'-code-p{p}', f's-{p}-{i}.jsonl'), _claude_transcript(cwd))
        for i in range(200):
            _put(os.path.join(home, '.codex', 'sessions', '2026', '10', '02', f'rollout-2026-10-02T10-00-00-r-{i}.jsonl'),
                 _codex_rollout(os.path.join(home, 'code', 'p1')))
        t0 = time.monotonic()
        inv = ls_mod.inventory(claude_roots=[os.path.join(home, '.claude', 'projects')],
                               codex_root=os.path.join(home, '.codex'), cursor_root=os.path.join(home, 'none'))
        recent = ls_mod.recent_titles(inv['recent'], codex_root=os.path.join(home, '.codex'))
        took = time.monotonic() - t0
    assert inv['counts']['claude_code'] == 1200 and inv['counts']['codex'] == 200
    assert len(inv['projects']) == 40 and len(recent) == 5
    assert took < 5, took


def _welcome_inv(hq, home):
    """An inventory with personal, HQ-root, own-company and other-company folders."""
    return {'counts': {'claude_code': 9, 'codex': 2, 'cursor': 0}, 'unplaced': 0, 'notes': [],
            'projects': {
                os.path.join(home, 'code', 'web'): {'path': '', 'sessions': 6, 'last_ts': _TS0,
                                                    'by_harness': {'claude_code': 4, 'codex': 2},
                                                    'ids': ['s0', 's1', 's2', 's3', 'k1', 'k2']},
                hq: {'path': '', 'sessions': 3, 'last_ts': (_TS0 + 3600), 'by_harness': {'claude_code': 3},
                     'ids': ['s6', 's7', 's8']},
                os.path.join(hq, 'companies', 'globex', 'projects', 'x'): {
                    'path': '', 'sessions': 1, 'last_ts': (_TS0 + 7200), 'by_harness': {'claude_code': 1}, 'ids': ['s5']},
                os.path.join(home, 'code', 'theirs'): {'path': '', 'sessions': 1, 'last_ts': (_TS0 + 7200),
                                                       'by_harness': {'claude_code': 1}, 'ids': ['s4']}},
            'sessions': {f's{i}': 'claude_code' for i in range(9)} | {'k1': 'codex', 'k2': 'codex'},
            'days': {'2026-10-01', '2026-10-02'}, 'recent': []}


def _recent(hq, home):
    return [{'id': 'r1', 'title': 'Ship the web fix ' + 'x' * 100, 'cwd': os.path.join(home, 'code', 'web'),
             'at': '2026-10-02T09:00:00Z', 'harness': 'claude_code'},
            {'id': 'r2', 'title': 'Globex plan', 'cwd': os.path.join(hq, 'companies', 'globex'),
             'at': '2026-10-03T09:00:00Z', 'harness': 'claude_code'},
            {'id': 'r3', 'title': 'Morning setup', 'cwd': hq, 'at': '2026-10-02T10:00:00Z', 'harness': 'codex'}]


def _welcome(company=None, **kw):
    saved, saved_home = sweep._load_local_sessions, os.environ.get('HOME')
    sweep._load_local_sessions = lambda: _FakeLocalSessions([])
    try:
        with tempfile.TemporaryDirectory() as tmp:
            hq, home = os.path.join(tmp, 'hq'), os.path.join(tmp, 'home')
            os.environ['HOME'] = home
            os.makedirs(os.path.join(home, 'code', 'web', '.git'))
            os.makedirs(os.path.join(home, 'code', 'theirs', '.git'))
            os.makedirs(os.path.join(hq, 'companies', 'globex'))
            # HQ-root sessions recorded as personal work (no company).
            for sid in ('s6', 's7', 's8', 'r3'):
                _put(os.path.join(hq, 'workspace', 'sessions', sid, 'meta.yaml'), 'company_slug: \n')
            orgs = {os.path.join(home, 'code', 'theirs'): 'globex-org', os.path.join(home, 'code', 'web'): 'alex'}
            args = dict(inv=_welcome_inv(hq, home), recent=_recent(hq, home), hq_root=hq,
                        tree={'companies': 1, 'projects': 2, 'knowledge_files': 7},
                        owners={'globex': 'globex-org'}, remote_org=orgs.get,
                        commit_at=lambda path: '2026-10-02T08:00:00+00:00')
            rows = kw.pop('rows', [])
            args.update(kw)
            return sweep.welcome_block(rows, company, True, None, **args), home
    finally:
        sweep._load_local_sessions = saved
        if saved_home is None:
            os.environ.pop('HOME', None)
        else:
            os.environ['HOME'] = saved_home


def test_welcome_names_the_persons_projects_repos_and_recent_work():
    w, home = _welcome()
    assert list(w) == [f for f in sweep.WELCOME_FIELDS if f in w], list(w)
    assert w['sessions'] == {'total': 11, 'local': 11, 'imported': 11, 'claude': 9, 'codex': 2, 'cursor': 0,
                             'days_seen': 2}
    # the globex folder's session counts, but the folder is not one of the person's projects
    assert w['headline'] == 'HQ found 11 past sessions across 3 projects on this Mac, most of them in Claude Code.'
    assert w['import']['projects'] == 3, w['import']
    assert w['harness']['primary'] == 'claude-code' and w['harness']['counts'] == {'claude_code': 9, 'codex': 2, 'cursor': 0}
    assert w['harness']['action'] == {'id': 'open-hq-in-harness', 'kind': 'open_harness', 'harness': 'claude-code',
                                      'label': 'Open HQ in Claude Code', 'launch_prompt': sweep.OPEN_HQ_PROMPT}
    # the other company's folder and its GitHub owner's repo are counted, never named
    assert [(p['name'], p['sessions'], p['harness']) for p in w['top_projects']] == [
        ('web', 6, 'claude-code'), ('HQ', 3, 'claude-code')], w['top_projects']
    assert w['top_projects'][0]['path'] == '~/code/web', w['top_projects']
    # the HQ folder sits outside this fixture's home folder: its name only
    assert w['top_projects'][1]['path'] == 'hq', w['top_projects']
    assert all(set(p) == set(sweep.WELCOME_PROJECT_FIELDS) for p in w['top_projects'])
    assert [r['name'] for r in w['top_repos']] == ['web'] and w['top_repos'][0]['last_commit_at'].startswith('2026-10-02')
    assert all(set(r) == set(sweep.WELCOME_REPO_FIELDS) for r in w['top_repos'])
    assert [r['project'] for r in w['recent_work']] == ['HQ', 'web'], w['recent_work']
    assert [r['harness'] for r in w['recent_work']] == ['codex', 'claude-code'], w['recent_work']
    assert len(w['recent_work'][1]['title']) == sweep.WELCOME_TITLE_CHARS
    assert all(set(r) == set(sweep.WELCOME_RECENT_FIELDS) for r in w['recent_work'])
    blob = json.dumps(w)
    assert 'globex' not in blob.lower() and 'theirs' not in blob and 'Globex plan' not in blob
    assert w['tree'] == {'companies': 1, 'projects': 2, 'knowledge_files': 7}
    assert w['apps'] == ['Claude Code', 'Codex']


def test_welcome_harness_ids_are_hyphenated_outside_counts():
    ids = {'claude-code', 'codex', 'cursor'}
    w, _ = _welcome()
    assert set(w['harness']['counts']) == {'claude_code', 'codex', 'cursor'}
    assert w['harness']['primary'] in ids and w['harness']['action']['harness'] in ids
    assert w['top_projects'] and all(p['harness'] in ids for p in w['top_projects']), w['top_projects']
    assert w['recent_work'] and all(r['harness'] in ids for r in w['recent_work']), w['recent_work']
    assert all(a['harness'] in ids for a in w['actions'] if a['kind'] == 'open_harness'), w['actions']
    counts_free = dict(w, harness={k: v for k, v in w['harness'].items() if k != 'counts'})
    assert 'claude_code' not in json.dumps(counts_free), counts_free


def test_welcome_actions_have_one_primary_and_known_kinds():
    w, _ = _welcome()
    kinds = [a['kind'] for a in w['actions']]
    # 11 past sessions on this Mac already count as imported: no import action
    assert kinds == ['open_harness', 'connect_ai_apps', 'connect_company', 'open_tree'], kinds
    assert set(kinds) <= set(sweep.WELCOME_ACTION_KINDS)
    assert [a['kind'] for a in w['actions'] if a['primary']] == ['connect_company']
    assert all(set(a) - {'harness', 'integration'} == set(sweep.WELCOME_ACTION_FIELDS) for a in w['actions']), w['actions']
    apps = next(a for a in w['actions'] if a['kind'] == 'connect_ai_apps')
    assert 'integration' not in apps and 'Cursor' in apps['reason'], apps
    company, _ = _welcome('globex', inv=None, recent=[], owners={})
    gh = next(a for a in company['actions'] if a['kind'] == 'connect_integration')
    assert gh['integration'] == {'slug': 'github', 'name': 'GitHub'} and sum(a['primary'] for a in company['actions']) == 1
    imported, _ = _welcome(has_companies=True)
    imported_kinds = [a['kind'] for a in imported['actions']]
    assert 'connect_company' not in imported_kinds and 'connect_company' not in [s['kind'] for s in imported['next_steps']]


def test_welcome_with_zero_sessions_gives_getting_started_copy():
    empty = {'counts': {'claude_code': 0, 'codex': 0, 'cursor': 0}, 'unplaced': 0, 'notes': [],
             'projects': {}, 'sessions': {}, 'days': set(), 'recent': []}
    w, _ = _welcome(inv=empty, recent=[])
    assert w['sessions']['total'] == 0 and w['headline'] == sweep.WELCOME_FIRST_STEPS
    assert w['getting_started'] == sweep.GETTING_STARTED_NO_SESSIONS
    assert w['harness']['primary'] is None and w['harness']['action']['label'] == 'Open HQ in Claude Code'
    assert [a['kind'] for a in w['actions'] if a['primary']] == ['connect_ai_apps']
    assert w['top_projects'] == [] and w['recent_work'] == []
    assert rank.welcome_problems({'welcome': w}) == []


def test_welcome_inputs_reads_titles_only_for_the_briefs_company():
    seen = []

    class Mod(_FakeLocalSessions):
        meta_fields = staticmethod(ls_mod.meta_fields)

        def inventory(self):
            return {'recent': self.recent}

        def recent_titles(self, recent, keep=None):
            assert keep(None, None) is False
            for r in recent:
                seen.append((r['id'], keep(r['id'], r['cwd'])))
            return []

    saved = sweep._load_local_sessions
    with tempfile.TemporaryDirectory() as tmp:
        hq, home = os.path.join(tmp, 'hq'), os.path.join(tmp, 'home')
        _put(os.path.join(hq, 'workspace', 'sessions', 'm-globex', 'meta.yaml'), 'company_slug: globex\n')
        _put(os.path.join(hq, 'workspace', 'sessions', 'm-mine', 'meta.yaml'), 'company_slug: \n')
        os.makedirs(os.path.join(home, 'code'))
        mod = Mod([])
        mod.recent = [{'id': 'row-initech-test', 'cwd': hq}, {'id': 'm-globex', 'cwd': hq}, {'id': 'm-mine', 'cwd': hq},
                      {'id': 'u-initech-test', 'cwd': os.path.join(hq, 'companies', 'initech-test', 'x')},
                      {'id': 'u-hq', 'cwd': hq}, {'id': 'u-out', 'cwd': os.path.join(home, 'code')}]
        sweep._load_local_sessions = lambda: mod
        try:
            sweep.welcome_inputs(hq, [{'id': 'row-initech-test', 'company': 'initech-test'}], None)
            personal = dict(seen)
            seen.clear()
            sweep.welcome_inputs(hq, [{'id': 'row-initech-test', 'company': 'initech-test'}], 'initech-test')
            company = dict(seen)
        finally:
            sweep._load_local_sessions = saved
    assert personal == {'row-initech-test': False, 'm-globex': False, 'm-mine': True, 'u-initech-test': False,
                        'u-hq': False, 'u-out': True}, personal
    assert company == {'row-initech-test': True, 'm-globex': False, 'm-mine': False, 'u-initech-test': True,
                       'u-hq': False, 'u-out': False}, company


def test_failed_sources_write_a_plain_note_and_send_details_to_stderr():
    import io, contextlib
    err = io.StringIO()
    sweep.SOURCES.clear()

    def boom(*a):
        raise RuntimeError('Traceback: KeyError at /private/secret/path')

    try:
        with contextlib.redirect_stderr(err):
            assert sweep.source('dms')(boom)() is None
            got = sweep.failure('main-branch builds', ValueError('Errno 2 nope'))
        src = dict(sweep.SOURCES['dms'])
    finally:
        sweep.SOURCES.clear()
    assert src == {'ok': False, 'state': 'failed', 'note': "Couldn't read DMs.", 'error': "Couldn't read DMs."}, src
    assert got == {'note': "Couldn't read main-branch builds.", 'error': "Couldn't read main-branch builds."}
    assert 'secret/path' in err.getvalue() and 'Errno 2' in err.getvalue()


def test_welcome_failure_is_a_plain_note():
    saved = sweep.welcome_inputs
    sweep.welcome_inputs = lambda *a, **k: (_ for _ in ()).throw(OSError('Errno 13 /home/x/.codex denied'))
    try:
        import io, contextlib
        with tempfile.TemporaryDirectory() as root, contextlib.redirect_stderr(io.StringIO()):
            write_products(root)
            d, _, _ = _run_personal(root)
    finally:
        sweep.welcome_inputs = saved
    assert d['welcome'] == {'first_run': True, 'note': "Couldn't read welcome history."}, d['welcome']
    assert rank.welcome_problems(d) == []


def test_check_brief_flags_empty_state_lines_and_exception_text_on_a_first_run():
    w = {'first_run': True, 'sessions': {'total': 4}}
    brief = {'welcome': w, 'lead': 'Nothing owed', 'sections': [{'label': 'LAST 24H', 'text': 'No sessions'}]}
    probs = rank.welcome_problems(brief)
    assert [p['text'] for p in probs] == ['Nothing owed', 'No sessions'], probs
    assert rank.welcome_problems(dict(brief, welcome=dict(w, first_run=False))) == []
    assert rank.welcome_problems(dict(brief, welcome=dict(w, sessions={'total': 0}))) == []
    bad = rank.welcome_problems({'welcome': {'first_run': False, 'note': 'Traceback (most recent call last)'}})
    assert len(bad) == 1 and bad[0]['problem'].startswith('exception text'), bad
    errno = rank.welcome_problems({'welcome': {'first_run': False, 'note': "[Errno 13] Permission denied: '/x'"}})
    assert len(errno) == 1, errno
    # the person's own session titles and folder names are data, not empty-state copy
    own = dict(w, headline='HQ found 4 past sessions on this Mac.',
               recent_work=[{'title': 'Error: nothing yet in the Exception handler', 'project': 'No sessions'}],
               top_projects=[{'name': 'nothing-owed', 'path': '~/code/nothing-owed'}])
    assert rank.welcome_problems({'welcome': own, 'items': {'shipped': [{'title': 'No sessions bug'}]}}) == []
    assert 'welcome_problems' in rank.check_brief(_brief())
    assert 'welcome_problems' in rank.check_brief({'mode': 'person', 'welcome': w, 'lead': 'Nothing needs a call'})


def test_welcome_never_names_a_folder_with_an_out_of_window_other_company_session():
    # No GitHub owners on record, and the other company's session is not in the scan rows.
    saved = sweep._load_local_sessions
    sweep._load_local_sessions = lambda: _FakeLocalSessions([])
    try:
        with tempfile.TemporaryDirectory() as tmp:
            hq, home = os.path.join(tmp, 'hq'), os.path.join(tmp, 'home')
            shared = os.path.join(hq, 'repos', 'private', 'shared-app')
            worktree = os.path.join(hq, 'workspace', 'worktrees', 'side-work')
            mine = os.path.join(home, 'code', 'mine')
            for d in (shared, worktree, mine):
                os.makedirs(os.path.join(d, '.git'))
            _put(os.path.join(hq, 'workspace', 'sessions', 'a1', 'meta.yaml'), 'company_slug: globex\n')
            _put(os.path.join(hq, 'workspace', 'sessions', 'a2', 'meta.yaml'), 'company_slug: \n')
            _put(os.path.join(hq, 'workspace', 'sessions', 'a2b', 'meta.yaml'), 'company_slug: \n')

            def proj(n, ids):
                return {'path': '', 'sessions': n, 'last_ts': _TS0, 'by_harness': {'claude_code': n}, 'ids': ids}

            inv = {'counts': {'claude_code': 6, 'codex': 0, 'cursor': 0}, 'unplaced': 0, 'notes': [],
                   'projects': {shared: proj(3, ['a2', 'a2b', 'a1']), worktree: proj(2, ['u1', 'u2']),
                                mine: proj(1, ['m1'])},
                   'sessions': {k: 'claude_code' for k in ('a1', 'a2', 'a2b', 'u1', 'u2', 'm1')},
                   'days': {'2026-10-01'}, 'recent': []}
            recent = [{'id': 'a1', 'title': 'Globex launch plan', 'cwd': shared, 'at': '2026-10-03T00:00:00Z',
                       'harness': 'claude_code'},
                      {'id': 'u1', 'title': 'Worktree chore', 'cwd': worktree, 'at': '2026-10-02T00:00:00Z',
                       'harness': 'claude_code'},
                      {'id': 'm1', 'title': 'My own fix', 'cwd': mine, 'at': '2026-10-01T00:00:00Z',
                       'harness': 'claude_code'}]
            rows = [{'id': 'a2', 'company': None, 'cwd': shared, 'tool': 'claude', 'started_at': '2026-10-01T00:00:00Z'}]
            w = sweep.welcome_block(rows, None, True, None, inv=inv, recent=recent, hq_root=hq, owners={},
                                    commit_at=lambda path: None, remote_org=lambda path: None)
    finally:
        sweep._load_local_sessions = saved
    assert [p['name'] for p in w['top_projects']] == ['mine'], w['top_projects']
    assert [r['name'] for r in w['top_repos']] == ['mine'], w['top_repos']
    assert [r['title'] for r in w['recent_work']] == ['My own fix'], w['recent_work']
    blob = json.dumps(w)
    assert 'shared-app' not in blob and 'side-work' not in blob and 'Globex' not in blob, blob
    assert w['sessions']['local'] == 6


def test_company_brief_names_its_own_folders_and_recent_work():
    w, _ = _welcome('globex', owners={})
    assert [p['name'] for p in w['top_projects']] == ['x'], w['top_projects']
    assert [r['title'] for r in w['recent_work']] == ['Globex plan'], w['recent_work']
    blob = json.dumps(w)
    assert '/code/web' not in blob and 'Morning setup' not in blob and 'theirs' not in blob, blob


def test_welcome_git_reads_stop_at_the_budget():
    ticks = iter([0.0] + [sweep.WELCOME_GIT_BUDGET_S + 1] * 1000)
    calls = []
    w, _ = _welcome(clock=lambda: next(ticks), commit_at=lambda path: calls.append(path) or 'x',
                    remote_org=lambda path: calls.append(path) or 'alex')
    # past the budget no git read runs, and a repo whose owner is unknown is not named
    assert calls == [] and [p['name'] for p in w['top_projects']] == ['HQ'], (calls, w['top_projects'])
    assert w['top_repos'] == []


def test_welcome_inputs_guards_each_read_with_a_plain_note():
    import io, contextlib

    class Mod(_FakeLocalSessions):
        def inventory(self):
            raise PermissionError("[Errno 13] Permission denied: '/home/x/.codex'")

    saved = sweep._load_local_sessions
    sweep._load_local_sessions = lambda: Mod([])
    err = io.StringIO()
    try:
        with tempfile.TemporaryDirectory() as hq, contextlib.redirect_stderr(err):
            got = sweep.welcome_inputs(hq, [], None)
            w = sweep.welcome_block([], None, True, None, hq_root=hq, **got)
    finally:
        sweep._load_local_sessions = saved
    assert got['inv'] is None and got['recent'] == [] and got['notes'] == ["Couldn't count every past session"], got
    assert got['tree'] == {'companies': 0, 'projects': 0, 'knowledge_files': 0}, got
    assert w['note'] == "Couldn't count every past session." and 'Errno' not in json.dumps(w)
    assert 'Errno 13' in err.getvalue()
    assert rank.welcome_problems({'welcome': w}) == []


def test_session_company_resolver_puts_a_companies_folder_ahead_of_a_personal_record():
    with tempfile.TemporaryDirectory() as hq:
        _put(os.path.join(hq, 'workspace', 'sessions', 'g1', 'meta.yaml'), 'company_slug: \n')
        launch = os.path.join(hq, 'companies', 'globex', 'projects', 'launch')
        company_for = sweep.session_company_resolver(hq, [{'id': 'g2', 'company': None, 'cwd': launch},
                                                          {'id': 'a1', 'company': 'initech-test', 'cwd': launch}])
        assert company_for('g1', launch) == 'globex'
        assert company_for('g2', launch) == 'globex'
        assert company_for('a1', launch) == 'initech-test'
        # recorded as personal and outside companies/: personal
        assert company_for('g1', hq) is None and company_for('g1', '/elsewhere/code') is None
        # no record inside HQ: unresolved; no record outside HQ: personal
        assert company_for('zz', os.path.join(hq, 'repos', 'private', 'x')) is sweep.UNRESOLVED
        assert company_for('zz', '/elsewhere/code') is None
        assert company_for('zz', None) is sweep.UNRESOLVED


def test_welcome_never_names_a_companies_folder_recorded_as_personal():
    """A session run under companies/globex without a company lock has an empty
    company_slug. Its folder, title and repo are counted and never named on a
    personal or person brief."""
    saved = sweep._load_local_sessions
    sweep._load_local_sessions = lambda: _FakeLocalSessions([])
    try:
        with tempfile.TemporaryDirectory() as tmp:
            hq = os.path.join(tmp, 'hq')
            launch = os.path.join(hq, 'companies', 'globex', 'projects', 'launch')
            plan = os.path.join(hq, 'companies', 'globex', 'projects', 'plan')
            mine = os.path.join(tmp, 'home', 'code', 'mine')
            for d in (launch, plan, mine):
                os.makedirs(d)
            _put(os.path.join(hq, 'workspace', 'sessions', 'g1', 'meta.yaml'), 'company_slug: \n')

            def proj(n, ids):
                return {'path': '', 'sessions': n, 'last_ts': _TS0, 'by_harness': {'claude_code': n}, 'ids': ids}

            inv = {'counts': {'claude_code': 3, 'codex': 0, 'cursor': 0}, 'unplaced': 0, 'notes': [],
                   'projects': {launch: proj(1, ['g1']), plan: proj(1, ['g2']), mine: proj(1, ['m1'])},
                   'sessions': {'g1': 'claude_code', 'g2': 'claude_code', 'm1': 'claude_code'},
                   'days': {'2026-10-01'}, 'recent': []}
            recent = [{'id': 'g1', 'title': 'Globex secret launch', 'cwd': launch, 'at': '2026-10-03T00:00:00Z',
                       'harness': 'claude_code'},
                      {'id': 'm1', 'title': 'My own fix', 'cwd': mine, 'at': '2026-10-01T00:00:00Z',
                       'harness': 'claude_code'}]
            rows = [{'id': 'g2', 'company': None, 'cwd': plan, 'project': 'plan', 'tool': 'claude',
                     'started_at': '2026-10-01T00:00:00Z'}]
            briefs = [sweep.welcome_block(rows, None, True, None, inv=inv, recent=recent, hq_root=hq, owners={},
                                          also=also, commit_at=lambda path: None, remote_org=lambda path: None)
                      for also in ((), ('initech-test',))]
    finally:
        sweep._load_local_sessions = saved
    for w in briefs:
        assert [p['name'] for p in w['top_projects']] == ['mine'], w['top_projects']
        assert [r['title'] for r in w['recent_work']] == ['My own fix'], w['recent_work']
        blob = json.dumps(w)
        assert '"launch"' not in blob and 'projects/launch' not in blob, blob
        assert 'Globex' not in blob and 'globex' not in blob, blob
        assert '"plan"' not in blob, w.get('repos')
        assert w['sessions']['local'] == 3


def test_welcome_counts_cursor_workspaces_as_sessions():
    w, _ = _welcome()
    base = w['sessions']['local']
    cursor = {'counts': {'claude_code': 2, 'codex': 0, 'cursor': 10}, 'unplaced': 0, 'notes': [], 'projects': {},
              'sessions': {'c1': 'claude_code', 'c2': 'claude_code'}, 'days': set(), 'recent': []}
    only = dict(cursor, counts={'claude_code': 0, 'codex': 0, 'cursor': 4}, sessions={})
    with tempfile.TemporaryDirectory() as hq:
        a = sweep.welcome_block([], None, True, None, inv=cursor, recent=[], hq_root=hq, owners={})
        b = sweep.welcome_block([], None, True, None, inv=only, recent=[], hq_root=hq, owners={})
    assert base == 11
    assert a['sessions']['local'] == 12 and a['sessions']['cursor'] == 10 and a['harness']['primary'] == 'cursor'
    assert a['headline'] == 'HQ found 12 past sessions on this Mac, most of them in Cursor.', a['headline']
    # a Cursor-only Mac gets the person's work, not the first-steps copy
    assert b['sessions']['total'] == 4 and b['headline'] != sweep.WELCOME_FIRST_STEPS and 'getting_started' not in b
    assert [x['kind'] for x in b['actions'] if x['primary']] != ['connect_ai_apps'], b['actions']


def test_recent_titles_reads_a_capped_head_and_stops_at_the_budget():
    pad = _jl(*[{'type': 'assistant', 'message': {'content': 'x' * 1000}} for _ in range(1500)])
    with tempfile.TemporaryDirectory() as home:
        web, _ = _fixture_home(home)
        # a long transcript whose title sits past the 1 MB head and outside the tail
        long_path = os.path.join(home, '.claude', 'projects', '-code-web', 'c-long.jsonl')
        _put(long_path, _claude_transcript(web) + pad + _jl({'type': 'custom-title', 'customTitle': 'Deep title'})
             + pad, _TS0 + 30 * 3600)
        assert ls_mod.summarize_transcript(long_path)['title'] == 'Deep title'
        inv = _inventory(home)
        codex = os.path.join(home, '.codex')
        got = ls_mod.recent_titles(inv['recent'], codex_root=codex)
        assert got[0]['id'] == 'c-long' and got[0]['title'] == 'Tidy the release notes', got[0]
        ticks = iter([0.0, 0.0] + [ls_mod.RECENT_TITLES_BUDGET_S + 1] * 100)
        cut = ls_mod.recent_titles(inv['recent'], codex_root=codex, clock=lambda: next(ticks))
    assert [r['id'] for r in cut] == ['c-long'], cut

# Credential-shaped strings are built from pieces and seeded random values so
# secret scanners do not flag this file. None of them is a real credential.
_FAKE_RNG = random.Random(1432)


def _fake(alphabet, n):
    """n seeded random characters; mixes letters and digits when the alphabet has both."""
    mixed = any(c.isdigit() for c in alphabet) and any(c.isalpha() for c in alphabet)
    while True:
        out = ''.join(_FAKE_RNG.choice(alphabet) for _ in range(n))
        if not mixed or (any(c.isdigit() for c in out) and any(c.isalpha() for c in out)):
            return out


_AZ09 = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
_HEXD = '0123456789abcdef'
_FAKE = {
    'anthropic export': 'export ANTHROPIC_API_KEY=' + 'sk-' + 'ant-' + 'api03-' + _fake(_AZ09, 16),
    'openai key': 'try this key ' + 'sk-' + 'proj' + _fake(_AZ09, 16),
    'github token': 'use token ' + 'gh' + 'p_' + _fake(_AZ09, 20),
    'github oauth': 'auth with ' + 'gh' + 'o_' + _fake(_AZ09, 20),
    'github pat': 'the pat is ' + 'github' + '_pat_' + _fake(_AZ09, 20),
    'slack token': 'post with ' + 'xo' + 'xb-' + _fake('0123456789', 4) + '-' + _fake(_AZ09, 8),
    'aws key': 'creds ' + 'AK' + 'IA' + _fake('ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789', 16) + ' in us-east-1',
    'password assign': 'log in with ' + 'password' + '=' + _fake(_AZ09, 8),
    'pass assign': 'DB_' + 'PASS' + '=' + _fake(_AZ09, 10) + ' and run migrate',
    'auth assign': 'set MY_' + 'AUTH' + '=' + _fake(_AZ09, 7),
    'secret colon': 'client_' + 'secret' + ': ' + _fake(_AZ09, 11),
    'token colon': 'API ' + 'token' + ': ' + _fake(_AZ09, 9),
    'bearer header': 'curl -H "Authorization: ' + 'Bearer ' + _fake(_AZ09, 18) + '"',
    'private key': '-----BEGIN ' + 'OPENSSH ' + 'PRIVATE KEY-----',
    'url credentials': 'clone https://alex:' + _fake(_AZ09, 8) + '@git.example.com/web.git',
    'high entropy': 'try ' + _fake(_AZ09, 32),
}
_CLEAN = ['Tidy the release notes', 'Fix the signup page', 'Review PR 1432', 'Rename the welcome headline',
          'Update feat/welcome-brief-knows-person notes', 'Add a monkey patch for the passing tests',
          'Plan the Q4 launch for Initech', 'Why does the build fail on CI?', 'Write the onboarding email']
# Safe by default: these are ordinary titles, but they name a credential word or
# hold a long random-looking run, so they are withheld too.
_WITHHELD = ['auth: fix the login redirect', 'Fix the token refresh bug in the passkey flow',
             'Review commit ' + _fake(_HEXD, 40),
             'Rename getUserAuthTokenFromHeaderValue', 'Trace request ' + '-'.join(_fake(_HEXD, n) for n in (8, 4, 4, 4, 12)),
             'Set up the API key screen']


def test_looks_secret_rejects_each_credential_pattern_and_keeps_clean_prompts():
    # a long scheme made only of punctuation must not hide a URL password
    for scheme in ('a' + '+' * 40, 'a' + '.' * 40, 'x' + '-' * 31, 'https'):
        assert ls_mod.looks_secret('clone ' + scheme + '://bob:' + _fake(_AZ09, 8) + '@db.example'), scheme
    for label, text in _FAKE.items():
        assert ls_mod.looks_secret(text), label
        assert ls_mod.cap_line(text) == '', label
    for text in _CLEAN:
        assert not ls_mod.looks_secret(text), text
        assert ls_mod.cap_line(text) == text, text
    for text in _WITHHELD:
        assert ls_mod.looks_secret(text), text
    assert not ls_mod.looks_secret(None) and not ls_mod.looks_secret('')


_ALNUM = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
_B64 = _ALNUM + '+/'


def _gen_secret_forms(rng):
    """(form, text) pairs for the forms the r2 review measured as leaking.
    Values are generated, so no real credential is in the file."""
    def pick(alphabet, n):
        return ''.join(rng.choice(alphabet) for _ in range(n))
    letters = 'abcdefghijklmnopqrstuvwxyz'
    hexd = '0123456789abcdef'
    pw = 'pass' + 'word'
    for _ in range(200):
        value = pick(_ALNUM + '!@#$%', rng.randint(4, 16))
        yield 'prose password', 'my ' + pw + ' is ' + value
        yield 'bare password', pw + ' ' + value
        yield 'prose password caps', 'The ' + pw.upper() + ' for staging is ' + value
        phrase = ' '.join(pick(letters, rng.randint(3, 8)) for _ in range(rng.randint(1, 4)))
        yield 'password colon passphrase', pw + ': ' + phrase
        for n in (32, 40, 64):
            h = pick(hexd, n)
            if rng.random() < 0.5:
                h = h.upper()
            yield f'hex {n}', 'use ' + h
            yield f'hex {n} api key', 'api ' + 'key ' + h
            yield f'hex {n} token', 'to' + 'ken ' + h
        aws = list(pick(_B64, 40))
        for i in rng.sample(range(1, 39), 3):
            aws[i] = '/'
        yield 'aws secret after space', 'aws ' + 'secret ' + ''.join(aws)
        yield 'aws secret bare', 'use ' + ''.join(aws) + ' for the deploy'
        yield 'short bearer', 'Authorization: ' + 'Bea' + 'rer ' + pick(_ALNUM, rng.randint(1, 7))
        yield 'short bearer lower', 'bea' + 'rer ' + pick(_ALNUM, rng.randint(1, 7))
        yield 'glpat low variety', 'clone with ' + 'gl' + 'pat-' + rng.choice('ab') * rng.randint(8, 20)
        yield 'base62 run', 'paste ' + pick(_ALNUM, rng.randint(20, 48))
        yield 'base64 run', 'paste ' + pick(_B64, rng.randint(20, 48)) + '=='
        yield 'secret word', 'the client ' + 'sec' + 'ret is ' + pick(letters, 10)
        yield 'credential word', 'here are my ' + 'cred' + 'entials ' + pick(letters, 8)


def test_looks_secret_catches_every_generated_form_from_the_r2_review():
    import random
    rng = random.Random(1432)
    misses = {}
    total = 0
    for form, text in _gen_secret_forms(rng):
        total += 1
        if not ls_mod.looks_secret(text) or ls_mod.cap_line(text) != '':
            misses.setdefault(form, 0)
            misses[form] += 1
    assert total > 3000 and not misses, misses


def test_registry_lane_and_thread_titles_use_the_secret_filter():
    pw = 'pass' + 'word'
    for bad in ('my ' + pw + ' is ' + _fake(_AZ09, 8), 'use ' + 'ab12' * 8):
        assert ls_mod.safe_title(bad) is None, bad
    for good in _CLEAN:
        assert ls_mod.safe_title(good) == good, good
    with tempfile.TemporaryDirectory() as hq:
        empty = os.path.join(hq, 'none')
        sess = os.path.join(hq, 'workspace', 'sessions')
        for sid, field, text in (('s-title', 'title', 'my ' + pw + ' is ' + _fake(_AZ09, 8)),
                                 ('s-task', 'task', 'use ' + 'ab12' * 8),
                                 ('s-ok', 'title', 'Fix the signup page'),
                                 ('s-thread', 'title', 'Review PR 1432')):
            os.makedirs(os.path.join(sess, sid))
            with open(os.path.join(sess, sid, 'meta.yaml'), 'w', encoding='utf-8') as f:
                f.write(f'session_id: {sid}\nstarted_at: 2026-10-01T10:00:00Z\n{field}: "{text}"\n')
        tdir = os.path.join(hq, 'workspace', 'threads')
        os.makedirs(tdir)
        with open(os.path.join(tdir, 'T-20261001-110000-x.json'), 'w', encoding='utf-8') as f:
            json.dump({'session_id': 's-thread', 'type': 'handoff', 'updated_at': '2026-10-01T11:00:00Z',
                       'metadata': {'title': 'Bea' + 'rer ' + _fake(_AZ09, 4)}}, f)
        rows = {r['id']: r for r in ls_mod.scan(hq, '2026-10-01T00:00:00Z', '2026-10-02T00:00:00Z',
                                                claude_root=empty, codex_root=empty)}
    assert rows['s-ok']['title'] == 'Fix the signup page', rows
    assert rows['s-title']['title'] is None and rows['s-task']['title'] is None, rows
    # the thread title looks secret, so the registry title stays
    assert rows['s-thread']['title'] == 'Review PR 1432', rows
    base = {'id': 'a', 'started_at': '2026-10-01T10:00:00Z', 'company': 'initech-test', 'kind': 'you',
            'project': 'hq-desktop-app', 'cwd': '/x/repos/private/hq-desktop-app'}
    assert sweep.session_row(dict(base, title='my ' + pw + ' is ' + _fake(_AZ09, 8)), 'initech-test')['title'] is None
    assert sweep.session_row(dict(base, title='use ' + 'ab12' * 8), 'initech-test')['title'] is None
    assert sweep.session_row(dict(base, title='Fix the signup page'), 'initech-test')['title'] == 'Fix the signup page'


def test_looks_secret_folds_wide_forms_and_short_codes():
    wide = ''.join(chr(ord(c) + 0xFEE0) for c in 'pass' + 'word')
    for text in ('my ' + wide + ' is x', 'the ' + 'pi' + 'n is 4821', 'o' + 'tp 993104',
                 '2' + 'fa code 551203', 'ssh' + 'pass -p x host'):
        assert ls_mod.looks_secret(text), text
    for name in ('DB' + 'PASS', 'db' + 'pass', 'SMTP' + 'PASS', 'PG' + 'PASS', 'MY' + 'KEY', 'X' + 'PWD'):
        for sep in ('=', ': ', ' = '):
            for value in (_fake(_AZ09, 8), 'abc', 'x'):
                for text in (name + sep + value, 'export ' + name + sep + value + ' and rerun'):
                    assert ls_mod.looks_secret(text) and ls_mod.cap_line(text) == '', text
    for text in ('p' + 'w: correcthorse', 'p' + 'w=' + _fake(_AZ09, 8), 'cr' + 'ed: hunter', 'pass' + 'wort ist x',
                 'contrase' + 'ña es x', 'mot de ' + 'passe x', 'p' + 'ássword is x',
                 'use ' + _fake('abcdefghijklmnopqrstuvwxyz0123456789', 16),
                 'seed ' + _fake('ABCDEFGHIJKLMNOPQRSTUVWXYZ234567', 16)):
        assert ls_mod.looks_secret(text), text
    for text in ('Fix the spinner', 'Update the topic list'):
        assert not ls_mod.looks_secret(text), text
    # safe by default: the whole word pin is withheld even when it is harmless
    assert ls_mod.looks_secret('Pin the header')
    import time
    start = time.monotonic()
    ls_mod.looks_secret('a' * 200000)
    ls_mod.looks_secret('a:' * 100000)
    ls_mod.looks_secret('a-' * 100000 + '=')
    ls_mod.looks_secret('a1' * 100000)
    # long name-like runs with no = or : must stay linear too
    for text in ('-' * 100000, 'ab-' * 40000, 'abc.' * 30000, 'x_y' * 40000, 'ey' + 'J_' * 50000,
                 'ey' + 'J-' * 50000, ('ey' + 'J_') * 50000, '\ufdfa' * 20000):
        ls_mod.looks_secret(text)
    assert time.monotonic() - start < 2.0
    # folding an accented or full-width letter onto a key prefix must not hide it
    tail = 'abcdefghij'
    for lead in ('\u00e9', 'caf\u00e9', '\uff21', 'x \u00e9'):
        for prefix in ('sk' + '-', 'gh' + 'p_', 'xo' + 'xb-'):
            assert ls_mod.looks_secret(lead + prefix + tail), (lead, prefix)
        jwt = 'ey' + 'J' + tail + '.' + tail + '.' + tail
        assert ls_mod.looks_secret(lead + jwt), lead
    # lookalike letters that NFKC leaves alone (dotless i, long s) must not hide a credential word
    for text in ('key\u0131=x', 'pass\u0131: x', 'export key\u0131=x', '\u017f' + 'ecret is x',
                 'pa\u017f\u017f' + 'word is x'):
        assert ls_mod.looks_secret(text), text


def test_a_prompt_with_a_secret_is_never_a_title():
    """The first-prompt fallback drops a line that looks like a credential and
    does not fall through to a later prompt. The session is still listed, with
    no title, so the welcome can name it by its project."""
    with tempfile.TemporaryDirectory() as home:
        web = os.path.join(home, 'code', 'web')
        os.makedirs(web)
        base = _TS0
        for i, (label, text) in enumerate(_FAKE.items()):
            _put(os.path.join(home, '.claude', 'projects', '-code-web', f'c-{i}.jsonl'),
                 _jl({'type': 'user', 'cwd': web, 'message': {'content': text}},
                     {'type': 'user', 'cwd': web, 'message': {'content': 'Second prompt'}}), base + i)
            s = ls_mod.summarize_transcript(os.path.join(home, '.claude', 'projects', '-code-web', f'c-{i}.jsonl'))
            assert s['first_prompt'] == '' and s['title'] is None, label
        _put(os.path.join(home, '.codex', 'sessions', '2026', '10', '01', 'rollout-2026-10-01T10-00-00-x-0.jsonl'),
             _codex_rollout(web, prompt=_FAKE['github token']), base + 100)
        _put(os.path.join(home, '.claude', 'projects', '-code-web', 'c-clean.jsonl'),
             _claude_transcript(web), base + 200)
        inv = ls_mod.inventory(claude_roots=[os.path.join(home, '.claude', 'projects')],
                               codex_root=os.path.join(home, '.codex'), cursor_root=os.path.join(home, 'none'),
                               home=home)
        got = ls_mod.recent_titles(inv['recent'], codex_root=os.path.join(home, '.codex'), limit=50)
    assert got[0]['id'] == 'c-clean' and got[0]['title'] == 'Tidy the release notes', got[0]
    # every listed session is kept (the scan reads the newest INVENTORY_RECENT), the withheld ones untitled
    assert len(got) == min(len(_FAKE) + 2, ls_mod.INVENTORY_RECENT) and got[1]['id'] == 'x-0', got
    assert all(r['title'] is None for r in got[1:]), got
    blob = json.dumps(got)
    for text in _FAKE.values():
        assert text not in blob and text[:40] not in blob
    # session rows (the regular brief) drop the prompt the same way
    row = {'title': None, 'project': None, 'kind': None, 'last_activity': None, 'cwd': None}
    ls_mod.enrich_from_transcript(row, {'title': None, 'first_prompt': '', 'cwd': web})
    assert row['title'] is None and row['cwd'] == web, row
    row = {'title': None, 'project': None, 'kind': None, 'last_activity': None, 'cwd': None}
    ls_mod.enrich_from_transcript(row, {'title': _FAKE['slack token'], 'first_prompt': None, 'cwd': None})
    assert row['title'] is None, row


def test_titles_prefer_custom_titles_summaries_and_codex_thread_names():
    with tempfile.TemporaryDirectory() as home:
        web = os.path.join(home, 'code', 'web')
        os.makedirs(web)
        base = _TS0
        proj = os.path.join(home, '.claude', 'projects', '-code-web')
        _put(os.path.join(proj, 'c-sum.jsonl'),
             _jl({'type': 'summary', 'summary': 'Release notes cleanup', 'leafUuid': 'u1'},
                 {'type': 'user', 'cwd': web, 'message': {'content': 'Tidy the release notes'}}), base)
        _put(os.path.join(proj, 'c-both.jsonl'),
             _jl({'type': 'summary', 'summary': 'Auto summary'},
                 {'type': 'user', 'cwd': web, 'message': {'content': 'Tidy the release notes'}},
                 {'type': 'custom-title', 'customTitle': 'My own name'}), base + 1)
        codex = os.path.join(home, '.codex')
        _put(os.path.join(codex, 'sessions', '2026', '10', '01', 'rollout-2026-10-01T10-00-00-x-0.jsonl'),
             _codex_rollout(web, prompt='Plan the launch checklist'), base + 2)
        _put(os.path.join(codex, 'sessions', '2026', '10', '01', 'rollout-2026-10-01T10-00-01-x-1.jsonl'),
             _codex_rollout(web, prompt='Plan the launch checklist'), base + 3)
        _put(os.path.join(codex, 'session_index.jsonl'),
             _jl({'id': 'x-0', 'thread_name': 'Launch plan'}, {'id': 'x-1', 'thread_name': _FAKE['aws key']}))
        assert ls_mod.summarize_transcript(os.path.join(proj, 'c-sum.jsonl'))['first_prompt'] is None
        inv = ls_mod.inventory(claude_roots=[os.path.join(home, '.claude', 'projects')], codex_root=codex,
                               cursor_root=os.path.join(home, 'none'), home=home)
        got = {r['id']: r['title'] for r in ls_mod.recent_titles(inv['recent'], codex_root=codex)}
    # a thread name that looks like a credential falls to the next candidate
    assert got == {'c-sum': 'Release notes cleanup', 'c-both': 'My own name', 'x-0': 'Launch plan',
                   'x-1': 'Plan the launch checklist'}, got


def test_welcome_names_a_session_with_a_withheld_title_by_its_project():
    def recent(hq, home):
        web = os.path.join(home, 'code', 'web')
        return [{'id': 'r1', 'title': None, 'cwd': web, 'at': '2026-10-03T09:00:00Z', 'harness': 'claude_code'},
                {'id': 'r2', 'title': _FAKE['anthropic export'], 'cwd': web, 'at': '2026-10-02T09:00:00Z',
                 'harness': 'codex'},
                {'id': 'r3', 'title': 'Ship the web fix', 'cwd': web, 'at': '2026-10-01T09:00:00Z',
                 'harness': 'claude_code'}]
    with tempfile.TemporaryDirectory() as tmp:
        hq, home = os.path.join(tmp, 'hq'), os.path.join(tmp, 'home')
        w, _ = _welcome(recent=recent(hq, home))
    assert [r['title'] for r in w['recent_work']] == ['Session in web', 'Session in web', 'Ship the web fix'], \
        w['recent_work']
    blob = json.dumps(w)
    assert 'ANTHROPIC' not in blob and 'sk-' not in blob


def test_welcome_headline_for_one_session_does_not_say_most_of_them():
    one = {'counts': {'claude_code': 0, 'codex': 1, 'cursor': 0}, 'unplaced': 1, 'notes': [],
           'projects': {}, 'sessions': {'k1': 'codex'}, 'days': {'2026-10-01'}, 'recent': []}
    w, _ = _welcome(inv=one, recent=[])
    assert w['headline'] == 'HQ found 1 past session on this Mac, in Codex.', w['headline']


def test_display_path_outside_home_is_the_folder_name():
    saved = os.environ.get('HOME')
    try:
        os.environ['HOME'] = '/home/alex'
        assert sweep._display_path('/home/alex/code/web') == '~/code/web'
        assert sweep._display_path('/home/alex') == '~'
        assert sweep._display_path('/Volumes/work/client-site') == 'client-site'
        assert sweep._display_path('/home/alexandra/code/app/') == 'app'
    finally:
        if saved is None:
            os.environ.pop('HOME', None)
        else:
            os.environ['HOME'] = saved


def test_inventory_does_not_follow_a_project_symlink_outside_home():
    with tempfile.TemporaryDirectory() as tmp:
        home, outside = os.path.join(tmp, 'home'), os.path.join(tmp, 'elsewhere')
        web = os.path.join(home, 'code', 'web')
        os.makedirs(web)
        projects = os.path.join(home, '.claude', 'projects')
        _put(os.path.join(projects, '-code-web', 'c-0.jsonl'), _claude_transcript(web), _TS0)
        _put(os.path.join(outside, 'c-out.jsonl'), _claude_transcript(outside, 'Outside'), (_TS0 + 1))
        _put(os.path.join(home, 'real-proj', 'c-in.jsonl'), _claude_transcript(web, 'Inside'), (_TS0 + 2))
        os.symlink(outside, os.path.join(projects, '-linked-out'))
        os.symlink(os.path.join(home, 'real-proj'), os.path.join(projects, '-linked-in'))
        inv = ls_mod.inventory(claude_roots=[projects], codex_root=os.path.join(home, '.codex'),
                               cursor_root=os.path.join(home, 'none'), home=home)
    assert sorted(inv['sessions']) == ['c-0', 'c-in'], inv['sessions']
    assert outside not in inv['projects'], inv['projects']


def _bulk_inv(home, n, harness='claude_code'):
    """n past sessions spread over three personal folders and n days."""
    folders = [os.path.join(home, 'code', x) for x in ('web', 'api', 'notes')]
    projects = {f: {'path': '', 'sessions': 0, 'last_ts': None, 'by_harness': {}, 'ids': []} for f in folders}
    sessions, days = {}, set()
    for i in range(n):
        sid, f = f'b{i}', folders[i % 3]
        p = projects[f]
        p['sessions'] += 1
        p['ids'].append(sid)
        p['by_harness'][harness] = p['by_harness'].get(harness, 0) + 1
        p['last_ts'] = max(p['last_ts'] or 0, _TS0 + i * 3600)
        sessions[sid] = harness
        days.add(dt.datetime.fromtimestamp(_TS0 + i * 3600, dt.timezone.utc).strftime('%Y-%m-%d'))
    counts = {'claude_code': 0, 'codex': 0, 'cursor': 0}
    counts[harness] = n
    return {'counts': counts, 'unplaced': 0, 'notes': [], 'projects': projects, 'sessions': sessions,
            'days': days, 'recent': []}


def _bulk_welcome(n, imported=None, current=(), recent=None, rows=(), inv_recent=(), now=None, company_for=None,
                  company=None, extra_projects=None):
    saved, saved_home = sweep._load_local_sessions, os.environ.get('HOME')
    sweep._load_local_sessions = lambda: _FakeLocalSessions([])
    try:
        with tempfile.TemporaryDirectory() as tmp:
            hq, home = os.path.join(tmp, 'hq'), os.path.join(tmp, 'home')
            os.environ['HOME'] = home
            for x in ('web', 'api', 'notes'):
                os.makedirs(os.path.join(home, 'code', x))
            os.makedirs(hq)
            recent = recent(home) if callable(recent) else (recent or [])
            inv = _bulk_inv(home, n)
            inv['recent'] = list(inv_recent)
            if extra_projects:
                extra_projects(hq, inv)
            return sweep.welcome_block(list(rows), company, True, imported, inv=inv, recent=recent,
                                       hq_root=hq, owners={}, has_companies=True, current_session=set(current),
                                       company_for=company_for or (lambda sid, cwd: None), now=now)
    finally:
        sweep._load_local_sessions = saved
        if saved_home is None:
            os.environ.pop('HOME', None)
        else:
            os.environ['HOME'] = saved_home


def test_welcome_counts_400_imported_sessions_without_a_report():
    token = 'use token ' + 'gh' + 'p_' + _fake(_AZ09, 20)

    def recent(home):
        return [{'id': 'b1', 'title': 'Fix the signup page', 'cwd': os.path.join(home, 'code', 'api'),
                 'at': '2026-10-05T09:00:00Z', 'harness': 'claude_code'},
                {'id': 'b2', 'title': token, 'cwd': os.path.join(home, 'code', 'notes'),
                 'at': '2026-10-04T09:00:00Z', 'harness': 'claude_code'}]
    w = _bulk_welcome(400, imported=None, current=('b0',), recent=recent)
    # the tree step's sessions count as imported even though no report was written
    imp = w['import']
    assert imp['source'] == 'detected' and imp['path'] is None, imp
    assert list(imp) == list(sweep.IMPORT_FIELDS), list(imp)
    assert imp['sessions']['total'] == 399 and imp['projects'] == 3 and imp['tools'] == ['claude-code'], imp
    assert imp['sessions']['claude'] == 399 and imp['sessions']['codex'] == 0, imp
    assert imp['sessions']['first_at'] == '2026-10-03' and imp['sessions']['last_at'], imp
    assert w['sessions']['total'] == 400 and w['sessions']['imported'] == 399, w['sessions']
    assert w['headline'] == 'HQ found 400 past sessions across 3 projects on this Mac, most of them in Claude Code.', w['headline']
    assert 'import_history' not in [a['kind'] for a in w['actions']], w['actions']
    assert 'import' not in [s['kind'] for s in w['next_steps']], w['next_steps']
    assert 'Bring in your past work' not in json.dumps(w)
    assert [(p['name'], p['sessions']) for p in w['top_projects']] == [('web', 134), ('notes', 133), ('api', 133)], w['top_projects']
    # recent work comes from the imported sessions, and a credential-shaped title is never shown
    assert [r['title'] for r in w['recent_work']] == ['Fix the signup page', 'Session in notes'], w['recent_work']
    assert token not in json.dumps(w)


def test_welcome_offers_import_only_when_no_other_session_exists():
    for n, current in ((0, ()), (1, ('b0',))):
        w = _bulk_welcome(n, imported=None, current=current)
        assert w['import'] is None, (n, w['import'])
        assert [a['kind'] for a in w['actions'] if a['kind'] == 'import_history'] == ['import_history'], (n, w['actions'])
        assert 'import' in [s['kind'] for s in w['next_steps']], (n, w['next_steps'])
    assert w['sessions']['total'] == 1 and w['sessions']['imported'] == 0, w['sessions']
    empty = _bulk_welcome(0)
    assert empty['headline'] == sweep.WELCOME_FIRST_STEPS
    assert [a['kind'] for a in empty['actions'] if a['primary']] == ['connect_ai_apps'], empty['actions']
    # one past session that is not the one running the brief counts
    other = _bulk_welcome(1, current=('someone-else',))
    assert other['import']['source'] == 'detected' and other['import']['sessions']['total'] == 1
    assert 'import_history' not in [a['kind'] for a in other['actions']]


def test_welcome_uses_the_import_report_when_present():
    with tempfile.TemporaryDirectory() as root:
        base = os.path.join(root, 'workspace', 'imports')
        # an older /import-context report: counts.conversations counts stores, not sessions
        _write_json(os.path.join(base, '20261001T000000Z', 'report.json'),
                    {'scan_id': '20261001T000000Z', 'counts': {'conversations': 2, 'skills': 3},
                     'categories': {'conversations': [{'source': 'claude-code', 'path': '~/.claude/projects', 'sessions': 150},
                                                      {'source': 'codex', 'path': '~/.codex/sessions', 'sessions': 250}]}})
        old = sweep.latest_import(root)
        assert old['conversations'] == 2 and old['sessions']['total'] == 400 and old['source'] == 'import-context', old
        # the desktop tree step names its folder differently; it is still the newest
        _write_json(os.path.join(base, '2026-10-19T15-00-28', 'report.json'),
                    {'scan_id': 'tree-1', 'counts': {'conversations': 3}, 'categories': {}, 'discovery': {'ok': True, 'errors': []},
                     'sessions': {'total': 412, 'claude': 300, 'codex': 100, 'cursor': 12, 'days_seen': 90,
                                  'first_at': '2026-07-01T00:00:00Z', 'last_at': '2026-10-18T22:00:00Z'},
                     'tools': ['claude-code', 'codex', 'cursor', 'Not A Tool!'], 'projects': ['web', 'api'],
                     'source': 'desktop-tree-step', 'written_at': '2026-10-19T15:00:30Z'})
        rep = sweep.latest_import(root)
    assert rep['scanned_at'] == '2026-10-19T15:00:28Z' and rep['source'] == 'desktop-tree-step', rep
    assert rep['sessions'] == {'total': 412, 'claude': 300, 'codex': 100, 'cursor': 12, 'days_seen': 90,
                               'first_at': '2026-07-01T00:00:00Z', 'last_at': '2026-10-18T22:00:00Z'}, rep
    assert rep['tools'] == ['claude-code', 'codex', 'cursor'] and rep['projects'] == 2, rep
    w = _bulk_welcome(5, imported=rep)
    assert w['import'] is rep
    assert w['sessions']['total'] == 412 and w['sessions']['imported'] == 412 and w['sessions']['local'] == 5, w['sessions']
    assert w['headline'].startswith('HQ found 412 past sessions'), w['headline']
    assert 'import_history' not in [a['kind'] for a in w['actions']]
    assert 'import' not in [s['kind'] for s in w['next_steps']]
    # a report with zero sessions still means the import already ran
    none = dict(rep, sessions=dict(rep['sessions'], total=0))
    w = _bulk_welcome(0, imported=none)
    assert w['import'] is none and 'import_history' not in [a['kind'] for a in w['actions']], w['actions']
    assert 'import' not in [s['kind'] for s in w['next_steps']]


def test_latest_import_drops_free_text_from_report_string_fields():
    with tempfile.TemporaryDirectory() as root:
        _write_json(os.path.join(root, 'workspace', 'imports', '2026-10-19T15-00-28', 'report.json'),
                    {'scan_id': 'tree-1', 'source': 'deploy key sk-live-123 for the db',
                     'written_at': 'yesterday, password hunter2',
                     'sessions': {'total': 7, 'first_at': 'my api token abc', 'last_at': '2026-10-18'},
                     'tools': ['claude-code', 'token=abc']})
        rep = sweep.latest_import(root)
    assert rep['source'] == 'import-context' and rep['written_at'] is None, rep
    assert rep['sessions']['first_at'] is None and rep['sessions']['last_at'] == '2026-10-18', rep['sessions']
    assert rep['sessions']['total'] == 7 and rep['tools'] == ['claude-code'], rep


def _newest_import(*names):
    with tempfile.TemporaryDirectory() as root:
        for n in names:
            _write_json(os.path.join(root, 'workspace', 'imports', n, 'report.json'), {'scan_id': n})
        rep = sweep.latest_import(root)
    return rep and os.path.basename(os.path.dirname(rep['path']))


def test_latest_import_orders_both_folder_formats_by_time():
    # a compact name sorts after a dashed one as text; time order must win
    assert _newest_import('20261019T150000Z', '2026-10-19T16-00-00') == '2026-10-19T16-00-00'
    assert _newest_import('2026-10-19T15-00-00', '20261019T160000Z') == '20261019T160000Z'
    assert _newest_import('2026-10-19T09-59-59', '2026-10-19T10-00-00') == '2026-10-19T10-00-00'


def test_latest_import_second_import_in_the_same_second_wins():
    assert _newest_import('2026-10-19T15-00-28', '2026-10-19T15-00-28-2') == '2026-10-19T15-00-28-2'
    assert _newest_import('2026-10-19T15-00-28-2', '2026-10-19T15-00-28-3', '2026-10-19T15-00-28') == '2026-10-19T15-00-28-3'
    # numeric, not text: -10 beats -9
    assert _newest_import('2026-10-19T15-00-28-9', '2026-10-19T15-00-28-10') == '2026-10-19T15-00-28-10'
    # a later second still beats any suffix
    assert _newest_import('2026-10-19T15-00-28-3', '2026-10-19T15-00-29') == '2026-10-19T15-00-29'


def test_latest_import_ignores_folders_that_are_not_stamps():
    junk = ('zzz-latest', 'notes', '2026-13-40T99-99-99', '20261019T150028', '2026-10-19T15-00-28-x', '2026-10-19T15-00-28-0')
    assert _newest_import('2026-10-19T15-00-28', *junk) == '2026-10-19T15-00-28'
    assert _newest_import(*junk) is None
    assert sweep._import_stamp_key('2026-02-30T00-00-00') is None


def test_latest_import_never_copies_scan_id():
    secret = 'sk-' + 'live-' + _fake(_AZ09, 24)
    for scan_id in ('companies/globex/projects/secret-launch', secret,
                    {'path': 'companies/globex/projects/secret-launch', 'key': secret}, ['companies/globex'], 12345):
        with tempfile.TemporaryDirectory() as root:
            _write_json(os.path.join(root, 'workspace', 'imports', '2026-10-19T15-00-28', 'report.json'),
                        {'scan_id': scan_id, 'counts': {'skills': 2}})
            rep = sweep.latest_import(root)
            w = _bulk_welcome(3, imported=rep)
        assert rep['scanned_at'] == '2026-10-19T15:00:28Z', rep
        for text in (json.dumps(rep), json.dumps(w)):
            assert 'globex' not in text and 'secret-launch' not in text and secret not in text and '12345' not in text, text
    # a compact folder name gives the same ISO form
    with tempfile.TemporaryDirectory() as root:
        _write_json(os.path.join(root, 'workspace', 'imports', '20261019T150028Z-2', 'report.json'), {'scan_id': 'x'})
        assert sweep.latest_import(root)['scanned_at'] == '2026-10-19T15:00:28Z'


def test_latest_import_skips_oversized_and_deeply_nested_reports():
    with tempfile.TemporaryDirectory() as root:
        base = os.path.join(root, 'workspace', 'imports')
        _write_json(os.path.join(base, '2026-10-01T00-00-00', 'report.json'), {'counts': {'skills': 5}})
        big = os.path.join(base, '2026-10-02T00-00-00', 'report.json')
        _write_json(big, {'counts': {'skills': 1}, 'pad': 'x' * sweep.IMPORT_REPORT_MAX_BYTES})
        deep = os.path.join(base, '2026-10-03T00-00-00', 'report.json')
        os.makedirs(os.path.dirname(deep))
        with open(deep, 'w') as f:
            f.write('{"counts": {"skills": 2}, "x": ' + '[' * 10000 + ']' * 10000 + '}')
        # brackets inside strings do not count as nesting
        ok = os.path.join(base, '2026-10-04T00-00-00', 'report.json')
        _write_json(ok, {'counts': {'skills': 7}, 'note': '[' * 100 + '\\"{' * 50})
        assert sweep._json_depth_ok(json.loads('{"a": [[1]], "b": "[[[[[["}'), 3)
        assert not sweep._json_depth_ok(json.loads('[[[[1]]]]'), 3)
        assert sweep.latest_import(root)['skills'] == 7
        os.remove(ok)
        # the oversized and deep reports are skipped; the older valid one is used
        got = sweep.latest_import(root)
        assert got['skills'] == 5 and got['path'].endswith(os.path.join('2026-10-01T00-00-00', 'report.json')), got
        os.remove(os.path.join(base, '2026-10-01T00-00-00', 'report.json'))
        assert sweep.latest_import(root) is None
        # with no usable report the welcome step falls back to direct detection
        w = _bulk_welcome(4, imported=sweep.latest_import(root))
        assert w['import']['source'] == 'detected' and w['import']['sessions']['total'] == 4, w['import']


def test_latest_import_skips_malformed_reports_quickly():
    # an unterminated string of escaped quotes, a truncated report and 100k
    # nested arrays, each just under the size cap, are skipped in under a second
    head = '{"scan_id": "x", "categories": {"plans": ["'
    room = sweep.IMPORT_REPORT_MAX_BYTES - len(head) - 8
    bad = {'quotes': '"' + '\\"' * (room // 2),
           'truncated': head + 'a\\"b ' * (room // 5),
           'nested': '[' * 100000 + ']' * 100000}
    for kind, text in bad.items():
        assert len(text.encode()) <= sweep.IMPORT_REPORT_MAX_BYTES, kind
        with tempfile.TemporaryDirectory() as root:
            base = os.path.join(root, 'workspace', 'imports')
            _write_json(os.path.join(base, '2026-10-01T00-00-00', 'report.json'), {'counts': {'skills': 5}})
            path = os.path.join(base, '2026-10-02T00-00-00', 'report.json')
            os.makedirs(os.path.dirname(path))
            with open(path, 'w') as f:
                f.write(text)
            start = time.monotonic()
            got = sweep.latest_import(root)
            took = time.monotonic() - start
        assert took < 1.0, (kind, took)
        assert got['skills'] == 5 and '2026-10-01T00-00-00' in got['path'], (kind, got)


def test_detected_import_harness_counts_leave_out_the_running_session():
    def add_codex(hq, inv):
        for i in range(2):
            inv['sessions'][f'c{i}'] = 'codex'
        inv['counts']['codex'] = 2
    for current, claude, codex in ((('b0',), 4, 2), (('c0',), 5, 1), (('someone-else',), 5, 2)):
        w = _bulk_welcome(5, current=current, extra_projects=add_codex)
        s = w['import']['sessions']
        assert (s['total'], s['claude'], s['codex']) == (claude + codex, claude, codex), (current, s)
        # the welcome session counts still cover every session on this Mac
        assert (w['sessions']['claude'], w['sessions']['codex']) == (5, 2), (current, w['sessions'])


def test_latest_import_never_raises():
    with tempfile.TemporaryDirectory() as root:
        base = os.path.join(root, 'workspace', 'imports', '2026-10-19T15-00-28')
        os.makedirs(base)
        with open(os.path.join(base, 'report.json'), 'wb') as f:
            f.write(b'\xff\xfe{"counts": 1}')
        assert sweep.latest_import(root) is None
        saved = sweep._report_sessions

        def boom(rep):
            raise TypeError('bad report')
        sweep._report_sessions = boom
        try:
            _write_json(os.path.join(base, 'report.json'), {'counts': {}})
            assert sweep.latest_import(root) is None
        finally:
            sweep._report_sessions = saved
    assert sweep.latest_import(os.path.join('no', 'such', 'root')) is None


def test_latest_import_counts_are_non_negative_integers():
    with tempfile.TemporaryDirectory() as root:
        _write_json(os.path.join(root, 'workspace', 'imports', '2026-10-19T15-00-28', 'report.json'),
                    {'counts': {'skills': -4, 'conversations': True, 'plans': 2.5, 'commands': '9', 'hooks': 3},
                     'sessions': {'total': -1, 'claude': False, 'codex': 4.0, 'cursor': 2, 'days_seen': -3}})
        rep = sweep.latest_import(root)
    assert [rep[k] for k in ('skills', 'conversations', 'plans', 'commands', 'hooks')] == [0, 0, 0, 0, 3], rep
    assert all(type(rep[k]) is int and rep[k] >= 0 for k in sweep.IMPORT_COUNT_KEYS), rep
    s = rep['sessions']
    assert s['total'] is None and s['claude'] is None and s['codex'] is None and s['days_seen'] is None, s
    assert s['cursor'] == 2, s


def test_latest_import_does_not_follow_symlinks():
    with tempfile.TemporaryDirectory() as tmp:
        outside = os.path.join(tmp, 'outside')
        _write_json(os.path.join(outside, '2026-10-19T15-00-28', 'report.json'), {'counts': {'skills': 9}})
        # a symlinked imports folder
        root = os.path.join(tmp, 'a')
        os.makedirs(os.path.join(root, 'workspace'))
        os.symlink(outside, os.path.join(root, 'workspace', 'imports'))
        assert sweep.latest_import(root) is None
        # a symlinked stamp folder
        root = os.path.join(tmp, 'b')
        os.makedirs(os.path.join(root, 'workspace', 'imports'))
        os.symlink(os.path.join(outside, '2026-10-19T15-00-28'), os.path.join(root, 'workspace', 'imports', '2026-10-19T15-00-28'))
        assert sweep.latest_import(root) is None
        # a symlinked report.json
        root = os.path.join(tmp, 'c')
        os.makedirs(os.path.join(root, 'workspace', 'imports', '2026-10-19T15-00-28'))
        os.symlink(os.path.join(outside, '2026-10-19T15-00-28', 'report.json'),
                   os.path.join(root, 'workspace', 'imports', '2026-10-19T15-00-28', 'report.json'))
        assert sweep.latest_import(root) is None


def _offers_import(w):
    return (w['import'] is None and 'import_history' in [a['kind'] for a in w['actions']]
            and 'import' in [s['kind'] for s in w['next_steps']])


def test_welcome_without_a_session_id_leaves_out_the_live_transcript():
    now = _TS0 + 30 * 86400
    live = [{'id': 'b0', 'path': '/t/b0.jsonl', 'harness': 'claude_code', 'cwd': None, 'ts': now - 60}]
    # no harness id set: the only transcript was written to a minute ago, so it is this session
    w = _bulk_welcome(1, current=(), inv_recent=live, now=now)
    assert _offers_import(w), (w['import'], w['actions'])
    # a transcript last written an hour ago is past work
    old = [dict(live[0], ts=now - 3600)]
    w = _bulk_welcome(1, current=(), inv_recent=old, now=now)
    assert w['import']['source'] == 'detected' and w['import']['sessions']['total'] == 1, w['import']
    # a known session id wins over the time window: another live transcript is past work
    w = _bulk_welcome(2, current=('b1',), inv_recent=live, now=now)
    assert w['import']['source'] == 'detected' and w['import']['sessions']['total'] == 1, w['import']


def test_welcome_counts_an_hq_row_and_its_transcript_once():
    now = _TS0 + 30 * 86400
    row = {'id': 'hq-1', 'company': None, 'tool': 'claude', 'started_at': '2026-11-02T04:00:00Z', 'cwd': None}
    # the HQ row id differs from the transcript id the harness reports
    w = _bulk_welcome(1, current=('b0',), rows=[row], now=now)
    assert _offers_import(w), (w['import'], w['actions'])
    # no harness id, an HQ row, and the live transcript
    live = [{'id': 'b0', 'path': '/t/b0.jsonl', 'harness': 'claude_code', 'cwd': None, 'ts': now - 30}]
    w = _bulk_welcome(1, current=(), rows=[row], inv_recent=live, now=now)
    assert _offers_import(w), (w['import'], w['actions'])
    # rows alone (no inventory) still leave out the running session
    saved = sweep._load_local_sessions
    sweep._load_local_sessions = lambda: _FakeLocalSessions([])
    try:
        w = sweep.welcome_block([row], None, True, None, hq_root=None, current_session={'hq-1'},
                                company_for=lambda sid, cwd: None)
    finally:
        sweep._load_local_sessions = saved
    assert w['import'] is None, w['import']


def test_welcome_project_count_leaves_out_other_companies():
    def add_other(hq, inv):
        cwd = os.path.join(hq, 'companies', 'globex', 'projects', 'roadmap')
        inv['projects'][cwd] = {'path': '', 'sessions': 5, 'last_ts': _TS0, 'by_harness': {'claude_code': 5},
                                'ids': [f'g{i}' for i in range(5)]}
        for i in range(5):
            inv['sessions'][f'g{i}'] = 'claude_code'
        inv['counts']['claude_code'] += 5

    def company_for(sid, cwd):
        return 'globex' if str(sid).startswith('g') else None
    w = _bulk_welcome(6, current=('b0',), extra_projects=add_other, company_for=company_for, company='initech-test')
    assert w['import']['projects'] == 3, w['import']
    assert ' across 3 projects ' in w['headline'], w['headline']
    assert 'globex' not in json.dumps(w) and 'roadmap' not in json.dumps(w)
    # when globex is in the brief, its folder counts
    w = _bulk_welcome(6, current=('b0',), extra_projects=add_other, company_for=company_for, company='globex')
    assert w['import']['projects'] == 4 and ' across 4 projects ' in w['headline'], (w['import'], w['headline'])


def test_current_session_ids_reads_the_harness_environment():
    assert sweep.current_session_ids({}) == set()
    assert sweep.current_session_ids({'CLAUDE_CODE_SESSION_ID': 'a', 'CODEX_THREAD_ID': 'b', 'CLAUDE_SESSION_ID': ''}) == {'a', 'b'}


def main():
    for name, fn in sorted(globals().items()):
        if name.startswith('test_') and callable(fn):
            fn()
    print('ok')


if __name__ == '__main__':
    main()
