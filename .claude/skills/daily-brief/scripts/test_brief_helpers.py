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
    assert label == 'Read 4 work sessions', label
    assert detail == '3 agent runs, 9 elsewhere, counted only', detail
    assert findings['sessions'] == 4 and samples == []
    label, detail = sweep.summarize('sessions', [{'company': 'other', 'kind': 'you'}], 'acme', {}, [])
    assert label == 'Read 0 work sessions' and detail == '1 elsewhere, counted only'


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
        with open(os.path.join(run_dir, 'status.json')) as f:
            st = json.load(f)
        assert st['housekeeping']['checks']['hq_sync'] == 'skipped (needs a company)', st
        assert st['activity'][0]['label'] == 'Housekeeping'


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


def main():
    for name, fn in sorted(globals().items()):
        if name.startswith('test_') and callable(fn):
            fn()
    print('ok')


if __name__ == '__main__':
    main()
