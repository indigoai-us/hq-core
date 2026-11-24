"""Plain-assert tests for the pure helpers in brief-sweep.py, housekeeping.py and
brief_rank.py. Run: python3 -I test_brief_helpers.py"""
import datetime as dt
import importlib.util
import json
import os
import sys
import tempfile
import time


def _ts(day, clock):
    """A YYYYMMDD-HHMMSS stamp from its two halves (keeps long digit runs out of the source)."""
    return day + '-' + clock


# ssh remote prefix, joined so the source holds no address-shaped literal
GH_SSH = 'git' + '@github.com:'

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


sweep = load('brief_sweep', 'brief-sweep.py')
hk = load('housekeeping', 'housekeeping.py')
rank = load('brief_rank', 'brief_rank.py')
UTC = dt.timezone.utc


def test_sessions_count_only_you_in_company():
    rows = ([{'company': 'acme', 'kind': 'you'}] * 3 + [{'company': 'acme', 'kind': 'agent'}] * 2
            + [{'company': 'acme', 'kind': 'lane'}] + [{'company': 'other', 'kind': 'you'}] * 4
            + [{'company': 'unknown', 'kind': 'agent'}] * 5 + [{'company': 'acme'}])  # missing kind = you
    findings, samples = {}, []
    label, detail = sweep.summarize('sessions', rows, 'acme', findings, samples)
    assert label == 'Read 4 of 16 sessions', label
    assert detail == 'only counted: 3 agent runs, 9 outside this brief', detail
    assert findings['sessions'] == 4 and samples == []
    label, detail = sweep.summarize('sessions', [{'company': 'other', 'kind': 'you'}], 'acme', {}, [])
    assert (label, detail) == ('Read 0 of 1 session', 'it was outside this brief, so only counted'), (label, detail)


def test_sessions_line_numbers_add_up():
    # 7 agent runs and no human sessions: the Desktop done-test case
    rows = [{'company': 'acme', 'kind': 'agent'}] * 5 + [{'company': 'acme', 'kind': 'lane'}] * 2
    findings = {}
    label, detail = sweep.summarize('sessions', rows, 'acme', findings, [])
    assert (label, detail) == ('Read 0 of 7 sessions', 'all 7 were agent runs, so only counted'), (label, detail)
    assert findings['sessions'] == 0
    # a mix of the person's own sessions and agent runs
    rows = [{'company': 'acme', 'kind': 'you'}] * 2 + [{'company': 'acme', 'kind': 'agent'}]
    assert sweep.summarize('sessions', rows, 'acme', {}, []) == ('Read 2 of 3 sessions', 'only counted: 1 agent run')
    # every session is the person's own; an empty kind counts as the person's, like the week arc
    rows = [{'company': 'acme', 'kind': 'you'}] * 2 + [{'company': 'acme', 'kind': None}]
    assert sweep.summarize('sessions', rows, 'acme', {}, []) == ('Read 3 of 3 sessions', '')
    # personal brief: the person's rows carry the personal tag, company rows are outside
    rows = [{'company': 'personal', 'kind': 'you'}, {'company': 'other', 'kind': 'you'}] * 2
    assert sweep.summarize('sessions', rows, None, {}, []) == ('Read 2 of 4 sessions', 'only counted: 2 outside this brief')
    # one agent run alone
    assert sweep.sessions_line(1, 0, 1) == ('Read 0 of 1 session', 'it was an agent run, so only counted')
    # no sessions at all
    findings = {}
    assert sweep.summarize('sessions', [], 'acme', findings, []) == ('Found no work sessions', '')
    assert findings['sessions'] == 0


def test_pr_summary_uses_window():
    start, end = dt.datetime(2026, 10, 9, 20, tzinfo=UTC), dt.datetime(2026, 10, 10, 20, tzinfo=UTC)
    prs = [
        {'state': 'merged', 'created': '2026-10-08T10:00:00Z', 'closed': '2026-10-09T21:00:00Z', 'authored_by_me': True, 'repo': 'hq-cloud', 'product': 'HQ Cloud', 'title': 'Placeholders'},
        {'state': 'merged', 'created': '2026-10-09T10:00:00Z', 'closed': '2026-10-09T12:00:00Z', 'authored_by_me': True},  # before window
        {'state': 'open', 'created': '2026-10-10T08:00:00Z', 'closed': None, 'authored_by_me': True},
        {'state': 'open', 'created': '2026-10-01T08:00:00Z', 'closed': None, 'authored_by_me': True},
        {'state': 'closed', 'created': '2026-10-10T01:00:00Z', 'closed': '2026-10-10T02:00:00Z', 'authored_by_me': True},
        {'state': 'open', 'created': '2026-10-10T09:00:00Z', 'authored_by_me': False, 'review_requested': True},
    ]
    s = sweep.pr_summary(prs, start, end)
    assert {k: s[k] for k in ('merged', 'opened', 'open', 'review_requested')} == \
        {'merged': 1, 'opened': 2, 'open': 2, 'review_requested': 1}, s
    assert s['median_merge_hours'] == 35.0 and s['by_product'][0]['product'] == 'HQ Cloud', s
    findings = {}
    label, detail = sweep.summarize('prs', prs, 'acme', findings, [], (start, end))
    assert label == 'Found 1 merged PRs in the last day', label
    assert findings['prs']['merged'] == s['merged'] and findings['prs']['opened'] == 2
    assert 'waiting on your review' in detail


def test_meeting_signal_text():
    md = ('---\ncanonical_content: Sam Rivera to build a new page for Robin, targeting next week.\n'
          'citations:\n  - location: 00:00:25\n    text: private transcript words\n'
          'type: action_item\n---\n## Action: build page\n\nBody.\n')
    r = sweep.parse_signal_md(md, ['Sam Rivera'])
    assert r['text'].startswith('Sam Rivera to build') and r['owner'] == 'Sam Rivera' and r['mine'] is True
    assert 'transcript' not in json.dumps(r)
    r = sweep.parse_signal_md(md.replace('Sam Rivera', 'Alex Smith'), ['Sam Rivera'])
    assert r['owner'] == 'Alex Smith' and r['mine'] is False
    # heading fallback when there is no canonical_content
    r = sweep.parse_signal_md('---\ntype: decision\n---\n## Decision: Ship 0.11.3 Monday\n', [])
    assert r['text'] == 'Ship 0.11.3 Monday' and r['owner'] is None and r['mine'] is False
    assert sweep.infer_owner('The team to review pricing') is None
    assert sweep.is_mine('person/sam-rivera', ['Sam Rivera'])
    assert sweep.is_mine('Sam', ['Sam Rivera'])
    assert not sweep.is_mine('Samx', ['Sam Rivera'])
    # inline entries skip the fetch; URL entries use it; non-https is refused
    calls = []
    fetch = lambda u: calls.append(u) or md
    assert sweep.signal_entry_text({'title': 'Sam to send deck'}, fetch, ['Sam Rivera'])['mine'] is True
    assert calls == []
    assert sweep.signal_entry_text({'slug': 'x', 'presigned_url': 'https://s3/x'}, fetch, ['Sam Rivera'])['mine']
    assert calls == ['https://s3/x']
    assert sweep.signal_entry_text({'presigned_url': 'file:///etc/hosts'}, fetch) is None


def test_housekeeping_status_words():
    assert hk.status_text() == 'ran clean'
    assert hk.status_text(found=1) == 'found 1 thing'
    assert hk.status_text(found=28) == 'found 28 things'
    assert hk.status_text(timed_out=True, found=3) == 'skipped (took too long)'
    assert hk.status_text(error='hq is not installed') == 'failed: hq is not installed'
    t = {'hq_doctor': hk.task_record('hq_doctor', found=28), 'hq_sync': hk.task_record('hq_sync'),
         'worktree_scan': hk.task_record('worktree_scan', timed_out=True)}
    assert t['hq_doctor']['ok'] and t['worktree_scan']['ok'] is False and t['worktree_scan']['found'] is None
    assert hk.headline(t) == '1 of 3 checks ran clean. Health check found 28 things; Worktree scan skipped (took too long).', hk.headline(t)
    assert hk.doctor_findings({'summary': {'PASS': 121, 'FAIL': 28}}) == 28
    assert hk.doctor_findings({}) == 0


def test_redact():
    s = hk.redact('auth failed token=abc123secret and ghp_' + 'a' * 36 + ' plus sk_live_' + 'b' * 20)
    assert 'abc123secret' not in s and 'ghp_' not in s and 'sk_live_' not in s and '[redacted]' in s, s
    assert len(hk.redact('x' * 500)) == 160


def test_worktree_verdict():
    now = 1_000_000_000
    v = hk.worktree_verdict([
        {'path': 'a', 'dirty': False, 'last_commit_ts': now - 30 * 86400},
        {'path': 'b', 'dirty': True, 'last_commit_ts': now - 30 * 86400},
        {'path': 'c', 'dirty': False, 'last_commit_ts': now - 3600},
    ], now)
    assert v == {'total': 3, 'stale': 1, 'dirty': 1, 'stale_paths': ['a']}, v


def test_company_owners_and_owner_scope():
    with tempfile.TemporaryDirectory() as root:
        assert hk.company_owners(root) == {}
        os.makedirs(os.path.join(root, 'companies'))
        with open(os.path.join(root, 'companies', 'manifest.yaml'), 'w') as f:
            f.write('version: 1\ncompanies:\n'
                    '  acme:\n    name: Acme\n    github_org: acme-gh\n    repos:\n      - name: web\n        github_org: nested\n'
                    '  globex:\n    github_org: "globex-gh"  # quoted\n'
                    '  initech:\n    name: Initech\n'
                    'other:\n  stray:\n    github_org: nope\n')
        owners = hk.company_owners(root)
    assert owners == {'acme': 'acme-gh', 'globex': 'globex-gh'}, owners
    assert hk.owner_in_scope('acme-gh', 'acme', owners) and hk.owner_in_scope('ACME-GH', 'acme', owners)
    assert not hk.owner_in_scope('globex-gh', 'acme', owners)
    assert not hk.owner_in_scope('acme-gh', None, owners)
    assert hk.owner_in_scope('sam', 'acme', owners) and hk.owner_in_scope(None, None, owners)
    assert hk.remote_owner(GH_SSH + 'acme-gh/web.git') == 'acme-gh'
    assert hk.remote_owner('https://github.com/globex-gh/app\n') == 'globex-gh'
    assert hk.remote_owner('') is None and hk.remote_owner('/local/path') is None


def test_check_worktrees_counts_other_company_trees_without_paths():
    class R:
        def __init__(self, out):
            self.stdout = out

    with tempfile.TemporaryDirectory() as root:
        for name in ('mine', 'theirs', 'local'):
            os.makedirs(os.path.join(root, 'workspace', 'worktrees', name))
            open(os.path.join(root, 'workspace', 'worktrees', name, '.git'), 'w').close()
        remotes = {'mine': GH_SSH + 'acme-gh/a.git', 'theirs': 'https://github.com/globex-gh/secret-repo.git', 'local': ''}
        old = str(int(time.time()) - 60 * 86400)

        def fake_git(path, args, timeout):
            if args[0] == 'remote':
                return R(remotes[os.path.basename(path)])
            return R(old if args[0] == 'log' else '')

        saved, hk._git = hk._git, fake_git
        try:
            rec = hk.check_worktrees(root, 10, 'acme', {'acme': 'acme-gh', 'globex': 'globex-gh'})
        finally:
            hk._git = saved
    v = rec['detail']
    assert v['total'] == 2 and v['other'] == 1 and v['stale'] == 2, v
    assert 'theirs' not in json.dumps(rec) and 'secret-repo' not in json.dumps(rec), rec


def test_run_bounded_times_out():
    t0 = time.monotonic()
    rc, out, err, to = hk.run_bounded([sys.executable, '-c', 'import time; time.sleep(30)'], 1)
    assert to is True and rc is None and time.monotonic() - t0 < 8
    rc, out, err, to = hk.run_bounded([sys.executable, '-c', 'import sys; print(sys.stdin.read() == "")'], 10)
    assert to is False and rc == 0 and out.strip() == 'True'  # stdin is /dev/null, never a prompt


def _fake_sync(rc, err=''):
    seen = {}

    def fake_run(cmd, budget_s, cwd=None):
        seen['cmd'], seen['budget'] = cmd, budget_s
        return rc, '', err, False
    return seen, fake_run


def test_check_sync_stops_itself_before_the_budget():
    """hq sync now gets --max-runtime under the hard budget, and the CLI's own
    watchdog exit (124) is recorded as took-too-long, not as a failure."""
    seen, fake = _fake_sync(124, 'sync stopped: still running after the --max-runtime limit')
    saved, hk.run_bounded = hk.run_bounded, fake
    try:
        rec = hk.check_sync('acme', '/tmp/hq', 360)
    finally:
        hk.run_bounded = saved
    cmd = seen['cmd']
    assert '--max-runtime' in cmd, cmd
    limit = int(cmd[cmd.index('--max-runtime') + 1])
    assert 0 < limit <= seen['budget'] - 10, (limit, seen['budget'])  # CLI report (<=10s) ends before the kill
    assert '--lock-timeout' in cmd and cmd[cmd.index('--lock-timeout') + 1] == '0', cmd
    assert rec['status'] == 'skipped (took too long)' and rec['error'] is None, rec


def test_check_sync_other_exit_codes_still_fail():
    """Only the watchdog's 124 reads as took-too-long; any other error exit stays failed."""
    seen, fake = _fake_sync(1, 'Sync failed: remote listing returned 503')
    saved, hk.run_bounded = hk.run_bounded, fake
    try:
        rec = hk.check_sync('acme', '/tmp/hq', 360)
    finally:
        hk.run_bounded = saved
    assert rec['status'].startswith('failed: ') and 'took too long' not in rec['status'], rec
    assert rec['ok'] is False and rec['error'], rec


def test_sync_command_short_budget_has_no_max_runtime():
    """A --budget too short to leave the report margin gets no --max-runtime
    (never a 1-second limit); the hard kill is the only stop."""
    for budget in (1, 5, 20, 39):
        cmd = hk.sync_command('acme', '/tmp/hq', budget)
        assert '--max-runtime' not in cmd, (budget, cmd)
    cmd = hk.sync_command('acme', '/tmp/hq', 40)
    assert cmd[cmd.index('--max-runtime') + 1] == '20', cmd


def test_skill_budget_table_matches_script():
    """The SKILL.md housekeeping table states the script's budgets and sync flag."""
    with open(os.path.join(HERE, '..', 'SKILL.md'), encoding='utf-8') as f:
        skill = f.read()
    for name, budget in hk.BUDGETS_S.items():
        row = next(l for l in skill.splitlines() if l.startswith('| `' + name + '`'))
        assert row.rstrip().endswith('| ' + str(budget) + 's |'), (name, row)
    sync_row = next(l for l in skill.splitlines() if l.startswith('| `hq_sync`'))
    assert '--max-runtime ' + str(hk.BUDGETS_S['hq_sync'] - hk.SYNC_RUNTIME_MARGIN_S) in sync_row, sync_row


def _run_housekeeping(root, run_dir, slow_sync, extra=()):
    """main() with fake checks: doctor finds 2, the worktree scan is clean, the
    sync is `slow_sync`."""
    import io, contextlib
    saved = hk.check_doctor, hk.check_sync, hk.check_worktrees
    hk.check_doctor = lambda *a: hk.task_record('hq_doctor', found=2, summary='Health check: 2 failing')
    hk.check_sync = slow_sync
    hk.check_worktrees = lambda *a: hk.task_record('worktree_scan', summary='Worktree scan: 0 worktrees')
    argv = sys.argv
    sys.argv = ['housekeeping.py', '--company', 'acme', '--hq-root', root, '--run-dir', run_dir] + list(extra)
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            hk.main()
    finally:
        sys.argv = argv
        hk.check_doctor, hk.check_sync, hk.check_worktrees = saved


def _wait_for_tasks(path, names, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with open(path) as f:
                if set(names) <= set(json.load(f).get('tasks', {})):
                    return True
        except (OSError, ValueError):
            pass
        time.sleep(0.02)
    return False


def _run_dir(root):
    run_dir = os.path.join(root, 'workspace', 'brief', 'brief-' + _ts('20261016', '090000'))
    os.makedirs(run_dir)
    return run_dir


def test_housekeeping_writes_each_check_as_it_finishes():
    """A finished check is in housekeeping.json while the sync is still
    running; the final write marks it done. status.json is never written."""
    seen = {}
    with tempfile.TemporaryDirectory() as root:
        run_dir = _run_dir(root)
        hk_path, st_path = os.path.join(run_dir, 'housekeeping.json'), os.path.join(run_dir, 'status.json')

        def slow_sync(*a):
            assert _wait_for_tasks(hk_path, ['hq_doctor', 'worktree_scan'])
            with open(hk_path) as f:
                seen['hk'] = json.load(f)
            return hk.task_record('hq_sync', summary='Sync: up to date')

        _run_housekeeping(root, run_dir, slow_sync)
        early = seen['hk']
        assert set(early['tasks']) == {'hq_doctor', 'worktree_scan'} and early['pending'] == ['hq_sync'], early
        assert early['state'] == 'running', early
        assert 'Sync still running' in early['headline'] and 'so far' in early['headline'], early['headline']
        with open(hk_path) as f:
            final = json.load(f)
        assert set(final['tasks']) == {'hq_doctor', 'hq_sync', 'worktree_scan'} and final['pending'] == [], final
        assert final['state'] == 'done', final
        assert final['headline'] == '2 of 3 checks ran clean. Health check found 2 things.', final['headline']
        assert not os.path.exists(st_path)


def test_housekeeping_never_clobbers_files_it_does_not_own():
    """status.json, rewritten by the brief writer while the sync runs, is left
    exactly as the writer left it. The writer's proposals are copied into
    housekeeping.json, the proposals file itself is never written, and an
    unreadable proposals file keeps the last good copy."""
    with tempfile.TemporaryDirectory() as root:
        run_dir = _run_dir(root)
        hk_path = os.path.join(run_dir, 'housekeeping.json')
        st_path = os.path.join(run_dir, 'status.json')
        prop_path = os.path.join(run_dir, 'housekeeping.proposals.json')
        _write_json(st_path, {'run_id': 'r', 'state': 'running', 'activity': [{'label': 'Writing'}]})
        writer_status = {'run_id': 'r', 'state': 'ready', 'progress': 1.0, 'activity': [{'label': 'Ready'}]}
        proposal = {'id': 'p1', 'title': 'Remove 3 idle worktrees', 'prompt': 'Remove them after checking'}

        def slow_sync(*a):
            assert _wait_for_tasks(hk_path, ['hq_doctor', 'worktree_scan'])
            # the writer finishes the brief while the sync still runs
            _write_json(st_path, '{"run_id": "r", "state": "rea')  # mid-write, not valid JSON yet
            _write_json(prop_path, {'proposals': [proposal]})
            return hk.task_record('hq_sync', summary='Sync: up to date')

        _run_housekeeping(root, run_dir, slow_sync)
        with open(st_path) as f:
            assert f.read() == '{"run_id": "r", "state": "rea'  # untouched, even half-written
        _write_json(st_path, writer_status)
        with open(hk_path) as f:
            d = json.load(f)
        assert d['proposals'] == [proposal] and d['state'] == 'done', d
        with open(prop_path) as f:
            assert json.load(f) == {'proposals': [proposal]}
        with open(st_path) as f:
            assert json.load(f) == writer_status

        # an unreadable proposals file: the last good copy stays
        _write_json(prop_path, '{not json')
        _run_housekeeping(root, run_dir, lambda *a: hk.task_record('hq_sync', summary='Sync: up to date'))
        with open(hk_path) as f:
            assert json.load(f)['proposals'] == [proposal]


def test_housekeeping_leaves_an_unreadable_own_file_alone():
    """A housekeeping file that exists but cannot be parsed is never replaced."""
    with tempfile.TemporaryDirectory() as root:
        run_dir = _run_dir(root)
        hk_path = os.path.join(run_dir, 'housekeeping.json')
        _write_json(hk_path, '{"tasks": {"hq_doctor": ')
        saved = hk.READ_WAIT_S
        hk.READ_WAIT_S = 0.01
        try:
            _run_housekeeping(root, run_dir, lambda *a: hk.task_record('hq_sync', summary='Sync: up to date'))
        finally:
            hk.READ_WAIT_S = saved
        with open(hk_path) as f:
            assert f.read() == '{"tasks": {"hq_doctor": '
        assert hk.write_owned_json(hk_path, lambda d: d.update(x=1)) is False
        assert hk.read_json(os.path.join(run_dir, 'missing.json')) == (True, {})


def test_housekeeping_out_writes_one_file_per_section():
    """Person mode: each section's run writes straight to its own --out file in
    the run dir, including the late sync; nothing goes to housekeeping.json."""
    with tempfile.TemporaryDirectory() as root:
        run_dir = _run_dir(root)
        out = os.path.join(run_dir, 'housekeeping-acme.json')
        late = {}

        def slow_sync(*a):
            assert _wait_for_tasks(out, ['hq_doctor', 'worktree_scan'])
            with open(out) as f:
                late['before'] = json.load(f)
            return hk.task_record('hq_sync', summary='Sync: up to date')

        _run_housekeeping(root, run_dir, slow_sync, ['--out', out])
        assert late['before']['pending'] == ['hq_sync'], late
        with open(out) as f:
            d = json.load(f)
        assert d['tasks']['hq_sync']['status'] == 'ran clean' and d['pending'] == [], d
        assert not os.path.exists(os.path.join(run_dir, 'housekeeping.json'))
        assert hk.proposals_path(out) == os.path.join(run_dir, 'housekeeping-acme.proposals.json')
        assert hk.resolve_out(run_dir, 'housekeeping-personal.json') == os.path.join(run_dir, 'housekeeping-personal.json')
        assert hk.resolve_out(run_dir, None) == os.path.join(run_dir, 'housekeeping.json')
        assert hk.resolve_out(run_dir, os.path.join(root, 'housekeeping.json')) is None  # outside the run dir
        assert hk.resolve_out(run_dir, os.path.join(run_dir, 'sub', 'housekeeping.json')) is None


def test_housekeeping_out_names():
    """--out is housekeeping.json or housekeeping-<section>.json in lower case
    only, never a symlink, and never a proposals file, whatever the section is
    called."""
    with tempfile.TemporaryDirectory() as root:
        run_dir = _run_dir(root)
        for good in ('housekeeping.json', 'housekeeping-acme.json', 'housekeeping-personal.json',
                     'housekeeping-big_box-2.json', 'housekeeping-acme-proposals.json'):
            assert hk.resolve_out(run_dir, good) == os.path.join(run_dir, good), good
        for bad in ('status.json', 'Status.json', 'STATUS.JSON', 'brief.json', 'Brief.json', 'brief-data.json',
                    'Housekeeping.json', 'Housekeeping-Acme.json', 'housekeeping-Acme.json', 'HOUSEKEEPING.JSON',
                    'page.json', 'housekeeping.proposals.json', 'housekeeping-acme.proposals.json',
                    'Housekeeping.Proposals.json', 'housekeeping.txt', 'housekeeping-.json', 'housekeeping--x.json',
                    'housekeeping-a b.json', 'housekeeping-../x.json', 'housekeepingx.json', 'housekeeping.json.lock'):
            assert hk.resolve_out(run_dir, bad) is None, bad
        # a section whose slug ends in -proposals gets its own file, never another section's proposals file
        a, b = hk.resolve_out(run_dir, 'housekeeping-acme.json'), hk.resolve_out(run_dir, 'housekeeping-acme-proposals.json')
        assert hk.proposals_path(a) != b and hk.proposals_path(b) not in (a, b), (a, b)
        # symlinks are refused as --out, and never read or replaced
        target = os.path.join(root, 'elsewhere.json')
        _write_json(target, {'keep': True})
        link = os.path.join(run_dir, 'housekeeping-link.json')
        os.symlink(target, link)
        assert hk.resolve_out(run_dir, 'housekeeping-link.json') is None
        assert hk.read_json(link) == (False, None)
        import io, contextlib
        with contextlib.redirect_stderr(io.StringIO()):
            assert hk.write_owned_json(link, lambda d: d.update(x=1)) is False
        with open(target) as f:
            assert json.load(f) == {'keep': True}


class _NoFlock:
    """Stands in for the fcntl module where flock is not supported."""
    LOCK_EX, LOCK_NB, LOCK_UN = 2, 4, 8

    @staticmethod
    def flock(fd, op):
        import errno as _e
        raise OSError(_e.ENOTSUP if hasattr(_e, 'ENOTSUP') else _e.EINVAL, 'Operation not supported')


def test_housekeeping_runs_without_a_working_lock():
    """flock raising (unsupported filesystem), or a lock file that cannot be
    opened (a planted symlink): the checks still write housekeeping.json; the
    merge, which only writes under the lock, exits 2 and writes nothing; the
    next check write copies the proposals in."""
    import io, contextlib
    proposal = {'id': 'p1', 'title': 'Remove 3 idle worktrees', 'prompt': 'Remove them after checking'}
    for case in ('flock-raises', 'lock-is-a-symlink'):
        with tempfile.TemporaryDirectory() as root:
            run_dir = _run_dir(root)
            hk_path = os.path.join(run_dir, 'housekeeping.json')
            saved_fcntl, saved_warned = hk.fcntl, set(hk._warned)
            hk._warned.clear()
            if case == 'flock-raises':
                if hk.fcntl is None:
                    continue  # Windows: no fcntl to patch; msvcrt errors take the same branch
                hk.fcntl = _NoFlock
            else:
                os.symlink(os.path.join(root, 'nowhere'), hk_path + '.lock')
            err = io.StringIO()
            try:
                with contextlib.redirect_stderr(err):
                    _run_housekeeping(root, run_dir, lambda *a: hk.task_record('hq_sync', summary='Sync: up to date'))
                    with open(hk_path) as f:
                        d = json.load(f)
                    assert d['state'] == 'done' and set(d['tasks']) == {'hq_doctor', 'hq_sync', 'worktree_scan'}, (case, d)
                    assert hk._warned & {'lock', 'open'}, (case, hk._warned)  # the run warned (its stderr is captured)
                    hk._warned.clear()
                    _write_json(os.path.join(run_dir, 'housekeeping.proposals.json'), {'proposals': [proposal]})
                    with open(hk_path) as f:
                        before = f.read()
                    assert hk.merge_proposals(hk_path) == hk.MERGE_SKIPPED == 2, case
                    with open(hk_path) as f:
                        assert f.read() == before, case  # nothing written without the lock
                    assert hk._warned & {'lock', 'open'}, case
                    # a later check write (still unlocked) copies the proposals in
                    _run_housekeeping(root, run_dir, lambda *a: hk.task_record('hq_sync', summary='Sync: up to date'))
            finally:
                hk.fcntl = saved_fcntl
                hk._warned.clear()
                hk._warned.update(saved_warned)
            with open(hk_path) as f:
                assert json.load(f)['proposals'] == [proposal], case
            assert err.getvalue().count('merge skipped') == 1, (case, err.getvalue())
            assert err.getvalue().count('without a lock') == 1, (case, err.getvalue())  # warned once
            if case == 'lock-is-a-symlink':
                assert not os.path.exists(os.path.join(root, 'nowhere'))  # the link target was never created


def test_merge_skips_when_another_process_holds_the_lock():
    """A lock held by another process: the merge gives up within its deadline,
    exits 2 and writes nothing. The check loop's own writes go on."""
    import subprocess, io, contextlib
    if hk.fcntl is None:
        return  # the holder below uses flock; the msvcrt path shares the same retry loop
    with tempfile.TemporaryDirectory() as root:
        run_dir = _run_dir(root)
        hk_path = os.path.join(run_dir, 'housekeeping.json')
        _write_json(hk_path, {'tasks': {}, 'proposals': []})
        _write_json(os.path.join(run_dir, 'housekeeping.proposals.json'), {'proposals': [{'id': 'p', 'title': 't', 'prompt': 'x'}]})
        holder = subprocess.Popen(
            [sys.executable, '-I', '-c',
             'import fcntl, os, sys, time\n'
             'fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT)\n'
             'fcntl.flock(fd, fcntl.LOCK_EX)\n'
             'print("held", flush=True)\n'
             'time.sleep(30)\n', hk_path + '.lock'],
            stdout=subprocess.PIPE, text=True)
        try:
            assert holder.stdout.readline().strip() == 'held'
            saved = hk.MERGE_LOCK_WAIT_S
            hk.MERGE_LOCK_WAIT_S = 1.0
            err = io.StringIO()
            try:
                t0 = time.monotonic()
                with contextlib.redirect_stderr(err):
                    rc = _merge(run_dir)
                took = time.monotonic() - t0
            finally:
                hk.MERGE_LOCK_WAIT_S = saved
            assert rc == hk.MERGE_SKIPPED == 2 and 0.9 <= took < 3, (rc, took)
            with open(hk_path) as f:
                assert json.load(f)['proposals'] == []  # nothing written
            # the default deadline is the bounded 5s the writer waits at most
            assert hk.MERGE_LOCK_WAIT_S == 5.0 and hk.LOOP_LOCK_WAIT_S <= 5.0
        finally:
            holder.kill()
            holder.wait()


def _merge(run_dir, extra=()):
    import io, contextlib
    argv = sys.argv
    sys.argv = ['housekeeping.py', '--merge-proposals', '--run-dir', run_dir] + list(extra)
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            return hk.main()
    finally:
        sys.argv = argv


def test_merge_proposals_after_the_script_finished():
    """Proposals saved after every check has ended reach housekeeping.json
    through --merge-proposals, with the check results kept."""
    proposal = {'id': 'p1', 'title': 'Remove 3 idle worktrees', 'prompt': 'Remove them after checking'}
    with tempfile.TemporaryDirectory() as root:
        run_dir = _run_dir(root)
        _run_housekeeping(root, run_dir, lambda *a: hk.task_record('hq_sync', summary='Sync: up to date'))
        hk_path = os.path.join(run_dir, 'housekeeping.json')
        with open(hk_path) as f:
            assert json.load(f)['proposals'] == []
        _write_json(os.path.join(run_dir, 'housekeeping.proposals.json'), {'proposals': [proposal]})
        assert _merge(run_dir) == 0
        with open(hk_path) as f:
            d = json.load(f)
        assert d['proposals'] == [proposal], d
        assert set(d['tasks']) == {'hq_doctor', 'hq_sync', 'worktree_scan'} and d['state'] == 'done', d
        # a section file works the same way
        out = os.path.join(run_dir, 'housekeeping-acme.json')
        _run_housekeeping(root, run_dir, lambda *a: hk.task_record('hq_sync', summary='Sync: up to date'), ['--out', out])
        _write_json(os.path.join(run_dir, 'housekeeping-acme.proposals.json'), {'proposals': [proposal]})
        assert _merge(run_dir, ['--out', 'housekeeping-acme.json']) == 0
        with open(out) as f:
            assert json.load(f)['proposals'] == [proposal]
        # an unreadable proposals file merges nothing and says so
        _write_json(os.path.join(run_dir, 'housekeeping.proposals.json'), '{not json')
        saved, hk.READ_WAIT_S = hk.READ_WAIT_S, 0.01
        try:
            assert _merge(run_dir) == 1
        finally:
            hk.READ_WAIT_S = saved
        with open(hk_path) as f:
            assert json.load(f)['proposals'] == [proposal]


def test_merge_proposals_during_a_run_loses_nothing():
    """Merges racing the check loop's writes, under the shared lock: the final
    file has every check result and the last proposals."""
    import threading
    with tempfile.TemporaryDirectory() as root:
        run_dir = _run_dir(root)
        hk_path = os.path.join(run_dir, 'housekeeping.json')
        prop_path = os.path.join(run_dir, 'housekeeping.proposals.json')
        stop, merged, errors = threading.Event(), [], []

        def merger():
            n = 0
            while not stop.is_set():
                n += 1
                _write_json(prop_path + '.tmp', {'proposals': [{'id': f'p{n}', 'title': 't', 'prompt': 'x'}]})
                os.replace(prop_path + '.tmp', prop_path)
                try:
                    rc = hk.merge_proposals(hk_path)
                except Exception as e:  # recorded, so a crash fails the test
                    errors.append(e)
                    return
                merged.append((n, rc))

        def slow_sync(*a):
            assert _wait_for_tasks(hk_path, ['hq_doctor', 'worktree_scan'])
            th = threading.Thread(target=merger)
            seen['th'] = th
            th.start()
            deadline = time.monotonic() + 5
            while len(merged) < 30 and time.monotonic() < deadline:
                time.sleep(0.005)
            seen['during'] = len(merged)
            return hk.task_record('hq_sync', summary='Sync: up to date')

        seen = {}
        import io, contextlib
        saved = hk.check_doctor, hk.check_sync, hk.check_worktrees
        hk.check_doctor = lambda *a: hk.task_record('hq_doctor', found=2, summary='Health check: 2 failing')
        hk.check_sync = slow_sync
        hk.check_worktrees = lambda *a: hk.task_record('worktree_scan', summary='Worktree scan: 0 worktrees')
        argv = sys.argv
        sys.argv = ['housekeeping.py', '--company', 'acme', '--hq-root', root, '--run-dir', run_dir]
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                hk.main()
                stop.set()
                seen['th'].join(10)  # the merger must be done before the temp dir goes
                assert not seen['th'].is_alive()
                last = merged[-1][0] if merged else None
                assert hk.merge_proposals(hk_path) == 0  # the writer's final merge
        finally:
            stop.set()
            if seen.get('th'):
                seen['th'].join(10)
            sys.argv = argv
            hk.check_doctor, hk.check_sync, hk.check_worktrees = saved
        assert not errors and seen['during'] >= 30, (errors, seen)
        assert all(rc == 0 for _, rc in merged), merged
        with open(hk_path) as f:
            d = json.load(f)
        with open(prop_path) as f:
            want = json.load(f)['proposals']
        assert set(d['tasks']) == {'hq_doctor', 'hq_sync', 'worktree_scan'} and d['state'] == 'done', d
        assert d['proposals'] == want and last is not None, (d['proposals'], want)


def test_brief_reset_state():
    with tempfile.TemporaryDirectory() as ws:
        os.makedirs(os.path.join(ws, 'brief', 'brief-' + _ts('20261010', '142540')))
        r = hk.brief_reset_state(ws, 'brief-' + _ts('20261010', '142540'))
        assert r['empty'] and not r['reset_on_purpose'] and r['note'] is None  # no backup: not a reset
        os.makedirs(os.path.join(ws, 'brief-backup-20261009a'))
        os.makedirs(os.path.join(ws, 'brief-backup-20261010a'))
        r = hk.brief_reset_state(ws, 'brief-' + _ts('20261010', '142540'))
        assert r['reset_on_purpose'] and r['backups'] == ['brief-backup-20261009a', 'brief-backup-20261010a']
        assert 'brief-backup-20261010a' in r['note'] and 'on purpose' in r['note']
        with open(os.path.join(ws, 'brief', 'index.jsonl'), 'w') as f:
            f.write('[1, 2]\n"ready"\n')  # valid JSON that is not an object is skipped
        r = hk.brief_reset_state(ws, 'brief-' + _ts('20261010', '142540'))
        assert r['empty'] and r['reset_on_purpose']
        with open(os.path.join(ws, 'brief', 'index.jsonl'), 'a') as f:
            f.write(json.dumps({'run_id': 'brief-' + _ts('20261010', '090000'), 'state': 'ready'}) + '\n')
        r = hk.brief_reset_state(ws, 'brief-' + _ts('20261010', '142540'))
        assert not r['empty'] and not r['reset_on_purpose']
    with tempfile.TemporaryDirectory() as ws:  # folder missing entirely
        os.makedirs(os.path.join(ws, 'brief-backup-20261010a'))
        assert hk.brief_reset_state(ws)['reset_on_purpose']


def _write_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(value if isinstance(value, str) else json.dumps(value))


def test_product_names_come_from_data_files():
    with tempfile.TemporaryDirectory() as root:
        # no data files: the title rule only
        assert rank.load_product_names(root) == {} and rank.PRODUCT_NAMES == {}
        assert rank.product_for('hq-desktop-app') == 'Hq desktop app'
        _write_json(os.path.join(root, 'companies', 'acme', 'settings', 'brief-products.json'),
                    {'hq-desktop-app': 'Desktop app', 'hq-cloud': 'HQ Cloud', 'bad': 3, '': 'x'})
        _write_json(os.path.join(root, 'workspace', 'brief', 'products.json'),
                    {'hq-cloud': 'Cloud (mine)', 'example-org/hq-shepherd': 'HQ Shepherd'})
        # the company file is read only with a company; the personal file wins on a clash
        assert rank.load_product_names(root, 'acme') == {'hq-desktop-app': 'Desktop app', 'hq-cloud': 'Cloud (mine)',
                                                          'hq-shepherd': 'HQ Shepherd'}, rank.PRODUCT_NAMES
        assert rank.product_for('hq-desktop-app') == 'Desktop app'
        assert rank.product_for('example-org/hq-cloud') == 'Cloud (mine)'
        assert rank.product_for('hq-shepherd') == 'HQ Shepherd'
        assert rank.product_for('some-new-repo') == 'Some new repo'
        assert rank.load_product_names(root) == {'hq-cloud': 'Cloud (mine)', 'hq-shepherd': 'HQ Shepherd'}
        # an unreadable file is ignored
        _write_json(os.path.join(root, 'workspace', 'brief', 'products.json'), '{not json')
        assert rank.load_product_names(root) == {}
        rank.load_product_names(os.path.join(root, 'missing'))


def test_housekeeping_skips_company_checks_without_a_company():
    r = hk.skipped_record('hq_doctor')
    assert r['ok'] is False and r['found'] is None and r['skipped_reason'] == 'needs a company'
    assert r['status'] == 'skipped (needs a company)', r
    with tempfile.TemporaryDirectory() as root:
        run_dir = os.path.join(root, 'workspace', 'brief', 'brief-' + _ts('20261016', '090000'))
        os.makedirs(run_dir)
        called = []
        saved = hk.check_doctor, hk.check_sync
        hk.check_doctor = lambda *a: called.append('doctor')
        hk.check_sync = lambda *a: called.append('sync')
        argv = sys.argv
        sys.argv = ['housekeeping.py', '--hq-root', root, '--run-dir', run_dir]
        try:
            import io, contextlib
            with contextlib.redirect_stdout(io.StringIO()):
                hk.main()
        finally:
            sys.argv = argv
            hk.check_doctor, hk.check_sync = saved
        assert called == []
        with open(os.path.join(run_dir, 'housekeeping.json')) as f:
            tasks = json.load(f)['tasks']
        assert tasks['hq_doctor']['skipped_reason'] == 'needs a company' and tasks['hq_sync']['ok'] is False
        assert 'skipped_reason' not in tasks['worktree_scan'], tasks['worktree_scan']
        with open(os.path.join(run_dir, 'housekeeping.json')) as f:
            d = json.load(f)
        assert d['state'] == 'done' and d['pending'] == [], d
        assert not os.path.exists(os.path.join(run_dir, 'status.json'))  # the brief writer owns status.json


def test_titles_and_products():
    ok = ['Approve the desktop 0.11.3 release', 'Decide: can cloud placeholders ever count as deletes?',
          'Fix the red release gate on staging', 'Give Alex a go/no-go on desktop 0.11.3',
          "Unblock Jamie's finance dashboard"]
    for t in ok:
        assert rank.lint_title(t) == [], (t, rank.lint_title(t))
    bad = rank.lint_title('hq-cloud #919: feat(sync): cloud-only .hqcloud placeholders; ignore .hq-offload/ now please',
                          ['example-org/hq-cloud'])
    assert any('words' in b for b in bad) and 'PR number' in bad and any(b.startswith('repo name') for b in bad)
    assert 'commit prefix' in rank.lint_title('fix(release-gate): ignore cancels')
    assert 'path, flag or code' in rank.lint_title('Check workspace/brief/ folder')
    assert 'path, flag or code' in rank.lint_title('Run sync with --force')


def test_rank_priorities():
    items = [
        {'id': 'quick', 'unlocks': [], 'age_hours': 90, 'effort': 'quick'},
        {'id': 'old', 'unlocks': ['x'], 'age_hours': 50},
        {'id': 'new', 'unlocks': ['x'], 'age_hours': 2},
        {'id': 'big', 'unlocks': ['x'], 'people_waiting': 2, 'age_hours': 1},
        {'id': 'rev', 'unlocks': [], 'revenue': True, 'age_hours': 1},
        {'id': 'quickhelp', 'unlocks': ['a', 'b', 'c', 'd'], 'effort': 'quick', 'age_hours': 1},
        {'id': 'seventh', 'unlocks': [], 'age_hours': 1},
        {'title': 'no id is skipped'},
    ]
    r = rank.rank_priorities(items)
    assert [x['item_id'] for x in r] == ['quickhelp', 'big', 'rev', 'old', 'new'], r
    assert [x['rank'] for x in r] == [1, 2, 3, 4, 5]
    r = rank.rank_priorities(items, limit=10)
    assert r[-1]['item_id'] == 'quick'  # quick win that unblocks nothing goes last


def test_check_brief():
    brief = {'items': {'decisions': [
        {'id': 'd1', 'title': 'hq-desktop-app #1553: Release 0.11.3', 'repo': 'hq-desktop-app', 'company': 'acme'},
        {'id': 'd2', 'title': 'Approve the desktop 0.11.3 release', 'product': 'Desktop app', 'company': 'acme'},
    ] + [{'id': f'x{i}', 'title': 'Approve it', 'product': 'HQ core', 'company': 'acme'} for i in range(4)]}}
    r = rank.check_brief(brief)
    assert r['over_cap'] == {'decisions': 6}
    ids = {p['id'] for p in r['title_problems']}
    assert 'd1' in ids and 'd2' not in ids


def test_week_rollup_counts_only_your_meetings():
    # The brief once reported every meeting the company recorded as the person's own,
    # because the per-day rollup counted every meeting the company recorded.
    # Only the ones they attended or own an item in are theirs.
    me = ['Sam Rivera']
    day = '2026-10-27'
    team = [{'id': f't{i}', 'title': f'Client sync {i}', 'start': f'{day}T{10 + i % 8:02d}:{i:02d}:00Z',
             'participants': ['Ann Lee', 'Bo Park'], 'recorded_by_me': False} for i in range(44)]
    mine = [
        {'id': 'm1', 'title': 'Dev standup', 'start': f'{day}T15:00:00Z', 'participants': 3,
         'recorded_by_me': True},
        {'id': 'm2', 'title': 'Pricing review', 'start': f'{day}T16:00:00Z',
         'participants': ['Ann Lee', 'Sam Rivera'], 'recorded_by_me': False},
        {'id': 'm3', 'title': 'Roadmap', 'start': f'{day}T17:00:00Z', 'participants': 2,
         'recorded_by_me': False},
    ]
    # the same standup stored twice by the recorder counts once
    dup = dict(mine[0], id='m1b')
    signals = [{'meeting_id': 'm3', 'action_items': [{'text': 'send deck', 'owner': 'Sam', 'mine': True}]}]
    rows = sweep.rollup_meetings(team + mine + [dup], signals, me)
    assert len(rows) == 47
    assert sum(1 for d, m in rows if m) == 3
    assert sum(1 for d, m in rows if not m) == 44
    assert {d for d, _ in rows} == {day}
    # a teammate's signal row with no item of theirs does not make the meeting theirs
    assert sweep.rollup_meetings(team[:1], [{'meeting_id': 't0', 'action_items': [{'owner': 'Ann', 'mine': False}]}], me) == [(day, False)]


def main():
    for name, fn in sorted(globals().items()):
        if name.startswith('test_') and callable(fn):
            fn()
    print('ok')


if __name__ == '__main__':
    main()
