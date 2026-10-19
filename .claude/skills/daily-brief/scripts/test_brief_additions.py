"""Plain-assert tests for the widget-facing additions to brief-sweep.py and
brief_rank.py (sessions, PR rows, releases, main health, fleet, meetings, DMs,
previous-run lookup, priority and prefs checks). No live service is called.
Run: python3 -I test_brief_additions.py"""
import datetime as dt
import importlib.util
import json
import os
import re
import sys
import tempfile


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
    r = {'id': 'a', 'started_at': '2026-10-11T14:36:06Z', 'company': 'acme', 'kind': 'you',
         'title': 'Fix the tour', 'project': 'hq-desktop-app', 'cwd': '/x/repos/private/hq-desktop-app',
         'last_activity': '2026-10-11T15:00:00Z'}
    row = sweep.session_row(r, 'acme', {'a'})
    assert row['project'] == 'hq-desktop-app' and row['product'] == 'Desktop app'
    assert row['cwd'] == '/x/repos/private/hq-desktop-app' and row['has_handoff'] is True
    assert row['last_activity'] == '2026-10-11T15:00:00Z' and row['title'] == 'Fix the tour'
    other = sweep.session_row(dict(r, company='globex'), 'acme', {'a'})
    assert other['company'] == 'other' and other['title'] is None and other['project'] is None
    assert other['cwd'] is None and other['product'] is None and other['has_handoff'] is None
    # a scan row that already carries has_handoff wins over the thread lookup
    assert sweep.session_row(dict(r, has_handoff=False), 'acme', {'a'})['has_handoff'] is False
    assert sweep.session_row(dict(r, project=None), 'acme', set())['product'] is None
    assert sweep.session_row(dict(r, company=None), 'acme')['company'] == 'unknown'


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
    rows = [sweep.pr_row(_gh(1, 'open', '2026-10-11T00:00:00Z', None, title='acme work', repo='a'), True, False),
            sweep.pr_row(dict(_gh(2, 'open', '2026-10-11T00:00:00Z', None, title='globex secret', repo='g'),
                              repository={'name': 'g', 'nameWithOwner': 'globex-gh/g'}), True, False),
            sweep.pr_row(dict(_gh(3, 'open', '2026-10-11T00:00:00Z', None, title='mine', repo='m'),
                              repository={'name': 'm', 'nameWithOwner': 'sam/m'}), True, False)]
    owners = {'acme': 'o', 'globex': 'Globex-GH'}
    kept, other = sweep.scope_prs(rows, 'acme', owners)
    assert [r['title'] for r in kept] == ['acme work', 'mine'] and other == 1, kept
    assert 'globex secret' not in json.dumps(kept)
    kept, other = sweep.scope_prs(rows, None, owners)  # personal: every mapped owner is out
    assert [r['title'] for r in kept] == ['mine'] and other == 2
    assert sweep.scope_prs(None, 'acme', owners) == ([], 0)


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
    label, detail = sweep.summarize('dms', [sweep.dm_row(m), sweep.dm_row({'fromPersonUid': 'agt_1', 'body': 'done?'})], 'acme', findings, [])
    assert findings['dms'] == {'total': 2, 'need_you': 1} and detail == '1 may need you', (findings, detail)


def test_scope_dms_drops_another_companys_inbox_item():
    """A company brief keeps only that company's messages. A personal brief keeps
    only messages with no company. The other company's text is not kept."""
    rows = [
        {'fromDisplayName': 'Alex', 'fromPersonUid': 'prs_a', 'body': 'Please review the acme page', 'company': 'acme'},
        {'fromDisplayName': 'Sam', 'fromPersonUid': 'prs_s', 'body': 'globex-only secret note', 'companySlug': 'globex'},
        {'fromDisplayName': 'Jamie', 'fromPersonUid': 'prs_j', 'body': 'note to self', 'company': 'personal'},
        {'fromDisplayName': 'Robin', 'fromPersonUid': 'prs_r', 'body': 'channel ask for acme',
         'channel': {'name': 'launch', 'company_slug': 'acme'}},
    ]
    kept = sweep.scope_dms(rows, 'acme')
    assert [r['from'] for r in kept] == ['Alex', 'Robin'], kept
    blob = json.dumps(kept)
    assert 'globex-only' not in blob and 'note to self' not in blob, blob
    assert kept[0]['need_you'] is True and 'acme page' in kept[0]['preview']
    personal = sweep.scope_dms(rows, None)
    assert [r['from'] for r in personal] == ['Jamie'], personal
    assert 'globex-only' not in json.dumps(personal) and 'acme page' not in json.dumps(personal)
    calls = []

    def fake_jrun(cmd, timeout=90):
        calls.append(cmd)
        return {'events': [
            {'fromDisplayName': 'Alex', 'body': 'acme ping', 'company': 'acme'},
            {'fromDisplayName': 'Sam', 'body': 'globex ping', 'company': 'globex'},
        ]}

    saved = sweep.jrun
    sweep.SOURCES.clear()
    sweep.jrun = fake_jrun
    try:
        got = sweep.dms('acme')
        tagged_src = dict(sweep.SOURCES['dms'])
    finally:
        sweep.jrun = saved
        sweep.SOURCES.clear()
    assert calls and calls[0][:4] == ['hq', 'dm', 'inbox', '--limit'], calls
    assert [r['from'] for r in got] == ['Alex'] and 'globex ping' not in json.dumps(got), got
    assert tagged_src['state'] == 'ok' and tagged_src['count'] == 1, tagged_src
    assert sweep.inbox_rows([{'company': 'acme'}]) == [{'company': 'acme'}]
    assert sweep.inbox_rows({'messages': [{'company': 'acme'}]}) == [{'company': 'acme'}]


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
    assert sweep.inbox_lacks_company_tag([{'body': 'hi', 'company': 'acme'}]) is False
    assert sweep.has_company_tag({'companyUid': 'uid_example_not_a_slug', 'body': 'x'}) is False
    calls = []

    def fake_jrun(cmd, timeout=90):
        calls.append(list(cmd))
        return json.loads(json.dumps(rows))

    saved = sweep.jrun
    sweep.SOURCES.clear()
    sweep.jrun = fake_jrun
    try:
        skipped = sweep.dms('acme')
        company_src = dict(sweep.SOURCES['dms'])
        sweep.SOURCES.clear()
        sweep.jrun = lambda cmd, timeout=90: calls.append(list(cmd)) or []
        empty = sweep.dms('acme')
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
        st = sweep.Status(path, 'acme')
        st.start('Checking your DMs', 0.4)
        st.finish('dms', None, {'ok': False, 'state': 'failed', 'error': 'inbox down'}, 0.45)
        st.start('Checking your DMs', 0.5)
        st.finish('dms', None, {'ok': False, 'state': 'skipped',
                                'skipped_reason': 'inbox has no company tag', 'count': None}, 0.55)
        got = json.load(open(path))
    failed, skipped = got['activity']
    assert failed['state'] == 'failed' and failed['label'] == 'Checking your DMs' and failed['detail'] == 'inbox down', failed
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
        data = {'a1': 'acme', 'g1': 'globex', 'a2': 'acme', 'p1': None, 'old': 'acme'}
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
        assert [r['run_id'] for r in sweep.ready_runs(idx, company='acme')] == ['old', 'a1', 'a2']
        assert [r['run_id'] for r in sweep.ready_runs(idx, company=None)] == ['old', 'p1']
        runs = sweep.ready_runs(idx)
        assert [x[0] for x in sweep.load_prior_data(brief, runs, company='acme')] == ['old', 'a1', 'a2']
        assert [x[0] for x in sweep.load_prior_data(brief, runs, company='globex')] == ['g1']
        assert [x[0] for x in sweep.load_prior_data(brief, runs, company=None)] == ['p1']
        # the limit counts matching runs only, newest kept
        assert [x[0] for x in sweep.load_prior_data(brief, runs, limit=1, company='acme')] == ['a2']


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
            'decisions': [{'id': 'd1', 'title': 'Close out the lease allotment', 'product': 'Fundraise', 'company': 'acme',
                           'action': 'go', 'unlocks': ['round close'], 'people_waiting': 1, 'revenue': True},
                          {'id': 'd3', 'title': 'Fix the red release checks', 'product': 'HQ core', 'company': 'acme',
                           'action': 'decide', 'choices': ['Retry now', 'Hold a day'], 'unlocks': ['promotion']}],
            'waiting': [{'id': 'w1', 'who': 'Jamie', 'what': 'to review the pricing page', 'product': 'Marketing site', 'company': 'acme',
                         'age_hours': 26, 'kind': 'review'}],
            'incidents': [{'id': 'p2', 'title': 'Unstick five fleet agents', 'product': 'Fleet', 'company': 'acme', 'unlocks': ['x']}],
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
    b['items']['waiting'].append({'id': 'w0', 'title': 'Review of the pricing page', 'why': 'It has sat a day', 'product': 'Marketing site', 'company': 'acme'})
    b['items']['waiting'].append({'id': 'w2', 'who': 'Casey', 'what': 'hq-cloud #913 review', 'product': 'HQ Cloud', 'company': 'acme'})
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
    sess_rows = [{'id': 's1', 'started_at': '2026-10-11T04:39:34Z', 'company': 'acme', 'kind': 'you', 'title': 'Fix it',
                  'project': 'hq-desktop-app', 'cwd': '/r/repos/private/hq-desktop-app', 'last_activity': '2026-10-11T05:00:00Z'},
                 {'id': 's2', 'started_at': '2026-10-10T16:00:00Z', 'company': 'globex', 'kind': 'you', 'title': 'Secret', 'project': 'globex-app'},
                 {'id': 's3', 'started_at': '2026-10-11T05:00:00Z', 'company': 'acme', 'kind': 'agent', 'title': '[Owner context, checked by this bot]'},
                 {'id': 's4', 'started_at': '2026-10-11T05:30:00Z', 'company': 'acme', 'kind': 'lane', 'title': 'Execute the lane brief'}]
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
    sweep.read_session_lock = lambda hq_root=None: ['acme']
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
            prev = {'generated_at': '2026-10-10T20:27:28+00:00', 'company': 'acme',
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
            sys.argv = ['brief-sweep.py', '--company', 'acme', '--days', '7', '--hours', '24', '--today', '2026-10-11',
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
    # the globex run in between is skipped: the delta and previous run are acme's
    assert d['previous_run'] == {'run_id': 'brief-' + _ts('20261010', '142540'), 'generated_at': '2026-10-10T20:27:28+00:00'}
    assert st['findings']['dms']['need_you'] > 0 and st['findings']['ci_red'] == 1 and st['sources']['fleet']['count'] == 3
    # a company brief keeps every source, says so in `mode`, and adds no welcome unless asked
    assert d['company'] == 'acme' and d['mode'] == 'company' and d['welcome'] is None
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
            d, st, _ = _run_personal(root, mode=('--company', 'acme'), stub_dms=False)
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
    assert w['first_run'] is True and w['import'] is None
    assert w['sessions'] == {'total': 3, 'claude': 2, 'codex': 1, 'days_seen': 2}, w['sessions']
    assert w['repos'] == [{'name': 'hq-desktop-app', 'sessions': 1}, {'name': 'notes', 'sessions': 1}], w['repos']
    assert w['apps'] == ['Claude Code', 'Codex']
    assert [x['kind'] for x in w['next_steps']] == ['connect_company', 'import']
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
        _write_manifest(root, {'acme': 'o', 'globex': 'globex-gh'})
        seen = {}
        d, _, _ = _run_personal(root, mode=('--company', 'acme'), seen=seen)
        assert seen['org'] == 'o', seen
        assert [p['repo_full'] for p in d['prs']] == ['o/hq-desktop-app'] and d['prs_other'] == 0
        seen = {}
        _run_personal(root, ['--org', 'x'], mode=('--company', 'acme'), seen=seen)
        assert seen['org'] == 'x', seen


def test_personal_brief_drops_prs_from_company_owners():
    with tempfile.TemporaryDirectory() as root:
        write_products(root)
        _write_manifest(root, {'acme': 'o'})
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
    sweep.enforce_company_lock('acme', ['acme', 'globex'])
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            sweep.enforce_company_lock('globex', ['acme'])
    except SystemExit as e:
        assert e.code == 1, e.code
    else:
        raise AssertionError('a company outside the lock should be refused')
    msg = err.getvalue()
    assert 'globex' in msg and 'outside' in msg and 'acme' in msg, msg
    with tempfile.TemporaryDirectory() as root:
        script_dir = os.path.join(root, 'core', 'scripts')
        os.makedirs(script_dir)
        with open(os.path.join(script_dir, 'hq-session.sh'), 'w') as f:
            f.write('#!/bin/bash\nprintf %s "acme,globex"\n')
        assert sweep.read_session_lock(root) == ['acme', 'globex']
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
        assert 'other' in msg and 'outside' in msg and 'acme' in msg and 'globex' in msg, msg
        assert not os.path.exists(os.path.join(root, 'out.json'))


def test_company_personal_and_all_flags_are_exclusive():
    import io, contextlib
    for argv in (['brief-sweep.py', '--all', '--personal', '--out', '/dev/null'],
                 ['brief-sweep.py', '--company', 'acme', '--personal', '--out', '/dev/null']):
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
        for stamp, rep in ((_ts('20261001', '000000'), {'scan_id': 'old', 'counts': {'skills': 1}}),
                           (_ts('20261010', '000000'), {'scan_id': 'scan-1', 'counts': {'skills': 4, 'conversations': 12, 'plans': 'x'}}),
                           (_ts('20261011', '000000'), None)):
            os.makedirs(os.path.join(base, stamp))
            if rep is not None:
                _write_json(os.path.join(base, stamp, 'report.json'), rep)
        got = sweep.latest_import(root)
        assert got['path'] == os.path.join('workspace', 'imports', _ts('20261010', '000000'), 'report.json')
        assert got['scanned_at'] == 'scan-1' and got['skills'] == 4 and got['conversations'] == 12 and got['plans'] == 0
        assert set(got) == {'path', 'scanned_at', *sweep.IMPORT_COUNT_KEYS}
        with open(os.path.join(base, _ts('20261011', '000000'), 'report.json'), 'w') as f:
            f.write('not json')
        assert sweep.latest_import(root)['scanned_at'] == 'scan-1'


def test_welcome_block_names_only_the_brief_companys_repos():
    rows = [{'company': 'acme', 'tool': 'claude', 'started_at': '2026-10-11T01:00:00Z', 'cwd': '/r/repos/public/web'},
            {'company': 'globex', 'tool': 'codex', 'started_at': '2026-10-10T01:00:00Z', 'cwd': '/r/repos/private/secret'},
            {'company': None, 'tool': None, 'started_at': '2026-10-10T02:00:00Z', 'project': 'loose'}]
    saved = sweep._load_local_sessions
    sweep._load_local_sessions = lambda: _FakeLocalSessions([])
    try:
        w = sweep.welcome_block(rows, 'acme', False, {'path': 'p', 'scanned_at': 's'})
    finally:
        sweep._load_local_sessions = saved
    assert w['repos'] == [{'name': 'web', 'sessions': 1}]
    assert w['sessions'] == {'total': 3, 'claude': 1, 'codex': 1, 'days_seen': 2}
    assert [x['kind'] for x in w['next_steps']] == ['connect_integration', 'sync']
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
    words = ['acme-co', 'Acme Co', 'CEO', 'him', 'his']
    pat = re.compile(r'\b(' + '|'.join(map(re.escape, words)) + r')\b')
    hits = []
    for path in files:
        with open(path, encoding='utf-8') as f:
            for i, line in enumerate(f, 1):
                for m in pat.finditer(line):
                    hits.append(f'{os.path.basename(path)}:{i}: {m.group(0)}')
    assert not hits, '\n'.join(hits)


def main():
    for name, fn in sorted(globals().items()):
        if name.startswith('test_') and callable(fn):
            fn()
    print('ok')


if __name__ == '__main__':
    main()
