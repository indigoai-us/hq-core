"""Company tagging for PR and DM rows (brief_company.py and its use in brief-sweep.py).
No live services: every CLI read is stubbed."""
import importlib.util
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

HERE = Path(__file__).parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


bc = load('brief_company', 'brief_company.py')
sweep = load('sweep', 'brief-sweep.py')

MANIFEST = """\
owner_summary: x
companies:
  personal:
    name: Personal
    repos:
      - repos/private/hobby
  acme:
    name: "Acme Inc"
    repos:
      - repos/private/acme-web
      - repos/private/acme-api   # trailing comment
      - repos/private/shared-lib
    knowledge: companies/acme/knowledge/
  beta:
    name: Beta
    repos: [repos/private/beta-app, repos/private/shared-lib]
  empty:
    name: Empty
    repos: []
unaffiliated_repos:
  - repos/public/tool
"""

REMOTES = {
    'repos/private/hobby': 'me/hobby',
    'repos/private/acme-web': 'acme-org/acme-web',
    'repos/private/acme-api': 'acme-org/acme-api',
    'repos/private/shared-lib': 'shared/shared-lib',
    'repos/private/beta-app': None,  # no readable remote: never matched by folder name
}
TYPES = {'acme-org': 'Organization', 'shared': 'Organization', 'me': 'User'}


def repo_map(explicit=None, types=TYPES, me='me', other=()):
    return bc.build_repo_map(bc.manifest_repos(MANIFEST), REMOTES, explicit, types, me, other)


def pr(full, number=1):
    return {'repo_full': full, 'repo': full.split('/', 1)[1], 'number': number, 'title': 't'}


class Manifest(unittest.TestCase):
    def test_repos_block_and_inline_lists(self):
        repos = bc.manifest_repos(MANIFEST)
        self.assertEqual(repos['acme'], ['repos/private/acme-web', 'repos/private/acme-api', 'repos/private/shared-lib'])
        self.assertEqual(repos['beta'], ['repos/private/beta-app', 'repos/private/shared-lib'])
        self.assertEqual(repos['empty'], [])
        self.assertEqual(repos['personal'], ['repos/private/hobby'])
        self.assertNotIn('repos/public/tool', sum(repos.values(), []))

    def test_names(self):
        self.assertEqual(bc.manifest_names(MANIFEST), {'personal': 'Personal', 'acme': 'Acme Inc', 'beta': 'Beta', 'empty': 'Empty'})

    def test_remote_full(self):
        self.assertEqual(bc.remote_full('https://github.com/o/r.git'), 'o/r')
        ssh_user = 'git'
        self.assertEqual(bc.remote_full(ssh_user + '@' + 'github.com:o/r.git'), 'o/r')  # scp-style SSH
        self.assertEqual(bc.remote_full('ssh://' + ssh_user + '@' + 'github.com/o/r.git'), 'o/r')
        self.assertIsNone(bc.remote_full('https://gitlab.com/o/r.git'))
        self.assertIsNone(bc.remote_full(None))


class PrCompany(unittest.TestCase):
    def test_exact_repo_wins(self):
        m = repo_map()
        self.assertEqual(bc.pr_company(pr('acme-org/acme-web'), m), 'acme')
        self.assertEqual(bc.pr_company(pr('ACME-ORG/Acme-Api'), m), 'acme')

    def test_owner_whose_repos_are_all_one_company(self):
        # A repo not cloned here, under an organization whose known repos are all Acme's.
        self.assertEqual(bc.pr_company(pr('acme-org/acme-docs'), repo_map()), 'acme')

    def test_personal_account_owner_is_never_inferred(self):
        # Regression: Acme lists one repo under the person's own account. Every other repo
        # there (side projects, dotfiles, another company's work) must stay personal.
        repos = {'acme': ['repos/private/acme-site'], 'beta': ['repos/private/beta-app']}
        remotes = {'repos/private/acme-site': 'me/acme-site', 'repos/private/beta-app': 'teammate/beta-app'}
        for types, me in [({'me': 'User', 'teammate': 'User'}, 'me'),   # typed as a user account
                          ({}, 'me'),                                     # type unknown
                          ({'me': 'Organization'}, 'me'),                 # own login, whatever the type
                          ({'teammate': 'User'}, None)]:                  # another person's account
            m = bc.build_repo_map(repos, remotes, None, types, me)
            self.assertEqual(bc.pr_company(pr('me/acme-site'), m), 'acme')
            self.assertIsNone(bc.pr_company(pr('me/dotfiles'), m), (types, me))
            self.assertIsNone(bc.pr_company(pr('teammate/other'), m), (types, me))
            kept, _ = bc.route_prs([pr('me/dotfiles'), pr('me/side-project')], 'acme', m)
            self.assertEqual(kept, [])
            kept, _ = bc.route_prs([pr('me/dotfiles')], None, m)
            self.assertEqual([r['repo_full'] for r in kept], ['me/dotfiles'])

    def test_explicit_owner_that_is_my_login_is_ignored(self):
        m = repo_map({'beta': 'me'})
        self.assertIsNone(bc.pr_company(pr('me/anything'), m))

    def test_repo_of_a_company_outside_the_lock_stays_out_of_personal(self):
        m = repo_map(other=['gamma-app'])
        self.assertIs(bc.pr_company(pr('gamma-org/gamma-app'), m), bc.OTHER)
        kept, dropped = bc.route_prs([pr('gamma-org/gamma-app')], None, m)
        self.assertEqual((kept, dropped), ([], 1))

    def test_repo_in_two_companies_is_ambiguous(self):
        self.assertIs(bc.pr_company(pr('shared/shared-lib'), repo_map()), bc.AMBIGUOUS)

    def test_no_folder_name_match_without_a_remote(self):
        # Matching is on the full owner/name only: a same-named repo elsewhere is not Beta's.
        self.assertIsNone(bc.pr_company(pr('someone/beta-app'), repo_map()))

    def test_personal_and_unmapped_are_the_persons_own(self):
        m = repo_map()
        self.assertIsNone(bc.pr_company(pr('me/hobby'), m))
        self.assertIsNone(bc.pr_company(pr('stranger/thing'), m))
        self.assertIsNone(bc.pr_company(pr('acme-org/x'), None))

    def test_explicit_github_org_wins_for_its_owner(self):
        m = repo_map({'beta': 'acme-org'})
        self.assertEqual(bc.pr_company(pr('acme-org/acme-docs'), m), 'beta')
        # The exact repo listing still wins over the owner.
        self.assertEqual(bc.pr_company(pr('acme-org/acme-web'), m), 'acme')

    def test_route_prs_per_section(self):
        rows = [pr('acme-org/acme-web', 1), pr('me/hobby', 2), pr('shared/shared-lib', 3), pr('stranger/x', 4),
                pr('someone/beta-app', 5)]
        m = repo_map()
        kept, dropped = bc.route_prs([dict(r) for r in rows], 'acme', m)
        self.assertEqual([(r['number'], r['company']) for r in kept], [(1, 'acme')])
        self.assertEqual(dropped, 4)
        kept, dropped = bc.route_prs([dict(r) for r in rows], None, m)
        self.assertEqual([(r['number'], r['company']) for r in kept], [(2, None), (4, None), (5, None)])
        self.assertEqual(dropped, 2)
        # Unmapped rows under the company's explicit org belong to it.
        kept, _ = bc.route_prs([dict(r) for r in rows], 'beta', m, org='stranger')
        self.assertEqual(sorted(r['number'] for r in kept), [4])
        self.assertEqual(bc.route_prs(['not a row', None], None, m), ([], 2))


class RepoMapReads(unittest.TestCase):
    def test_reads_only_locked_companies_repos(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, 'companies'))
            with open(os.path.join(root, 'companies', 'manifest' + '.yaml'), 'w') as f:
                f.write(MANIFEST)
            for path in REMOTES:
                os.makedirs(os.path.join(root, path))
            read, asked = [], []
            remotes = {os.path.join(root, k): ('https://github.com/' + v + '.git' if v else None) for k, v in REMOTES.items()}

            def fake_remote(path):
                read.append(os.path.relpath(path, root))
                return remotes[path]

            def run_json(cmd):
                asked.append(cmd[2])
                return {'login': 'me'} if cmd[2] == 'user' else {'type': 'Organization'}
            with patch.object(bc, '_git_remote', side_effect=fake_remote):
                m = bc.company_repo_map(root, {'beta': 'beta-org'}, companies=['acme'], run_json=run_json)
            self.assertEqual(sorted(read), ['repos/private/acme-api', 'repos/private/acme-web', 'repos/private/shared-lib'])
            self.assertEqual(sorted(asked), ['user', 'users/acme-org', 'users/shared'])  # never beta's owner
            self.assertEqual(m['owner'], {'acme-org': 'acme', 'shared': 'acme'})
            self.assertEqual(m['other'], {'beta-app'})  # beta's folder names only, from the manifest
            self.assertNotIn('hobby', m['other'])


class Budgets(unittest.TestCase):
    def slow(self, *_):
        time.sleep(1.5)
        return {'members': [], 'name': 'Late'}

    def test_bounded_does_not_wait_past_its_budget(self):
        t = time.monotonic()
        got = bc._bounded(lambda j: self.slow() if j == 'slow' else j, ['fast', 'slow'], 0.2)
        self.assertLess(time.monotonic() - t, 1.0)
        self.assertEqual(got, {'fast': 'fast'})

    def test_read_rosters_and_github_names_keep_their_budget(self):
        t = time.monotonic()
        self.assertEqual(bc.read_rosters(['a'], self.slow, budget_s=0.2)[0], {})
        self.assertTrue(bc.read_rosters(['a'], self.slow, budget_s=0.2)[1])
        self.assertEqual(bc.github_names(['bokim'], self.slow, budget_s=0.2), {})
        self.assertLess(time.monotonic() - t, 2.0)


class Senders(unittest.TestCase):
    def test_roster_ids_active_only(self):
        payload = {'members': [{'person_id': 'PRS_A', 'email': 'A@example.com', 'status': 'active'},
                               {'person_id': 'prs_gone', 'status': 'revoked'}]}
        self.assertEqual(bc.roster_ids(payload), {'prs_a', 'a@example.com'})
        self.assertEqual(bc.roster_ids([{'personUid': 'prs_b'}]), {'prs_b'})
        with self.assertRaises(ValueError):
            bc.roster_ids({'nothing': 1})

    def test_sender_map_keeps_only_one_company_senders(self):
        m = bc.sender_map({'a': {'x', 'both'}, 'b': {'y', 'both'}, 'personal': {'z'}})
        self.assertEqual(m, {'x': 'a', 'y': 'b'})

    def test_read_rosters_reads_included_only_and_fails_closed(self):
        calls = []

        def ok(cmd):
            calls.append(cmd)
            return {'members': [{'person_id': 'prs_' + cmd[3]}]}
        rosters, err = bc.read_rosters(['a', 'personal', 'b'], ok)
        self.assertIsNone(err)
        self.assertEqual(rosters, {'a': {'prs_a'}, 'b': {'prs_b'}})
        self.assertEqual(sorted(c[3] for c in calls), ['a', 'b'])
        self.assertTrue(all(c[:2] == ['hq', 'members'] and c[4:] == ['list', '--json'] for c in calls))

        def flaky(cmd):
            if cmd[3] == 'b':
                raise RuntimeError('signed out')
            return {'members': []}
        rosters, err = bc.read_rosters(['a', 'b'], flaky)
        self.assertEqual(rosters, {})
        self.assertTrue(err)
        self.assertEqual(bc.read_rosters([], ok), ({}, None))

    def test_dm_company(self):
        senders = {'prs_a': 'a', 'b@example.com': 'b'}
        self.assertEqual(bc.dm_company({'fromPersonUid': 'PRS_A'}, senders), ('a', 'sender'))
        self.assertEqual(bc.dm_company({'fromPersonUid': 'prs_q', 'fromEmail': 'B@example.com'}, senders), ('b', 'sender'))
        self.assertEqual(bc.dm_company({'fromPersonUid': 'prs_q'}, senders), (None, None))
        self.assertEqual(bc.dm_company({'fromPersonUid': 'prs_a'}, None), (None, None))


class DisplayNames(unittest.TestCase):
    def test_looks_like_handle(self):
        for n in ('jdoe42', 'zqhandle', 'a.lee', 'bo', 'x_y', 'me@example.com'):
            self.assertTrue(bc.looks_like_handle(n), n)
        for n in ('Ann', 'Ann Lee', 'ann lee', 'Bo', 'OK'):
            self.assertFalse(bc.looks_like_handle(n), n)

    def test_display_name_sources_in_order(self):
        names = {'prs_a': 'Ann Lee', 'prs_h': 'annhandle'}
        self.assertEqual(bc.display_name('Ann Lee'), 'Ann')
        self.assertEqual(bc.display_name('annlee77', ids=['PRS_A'], names=names), 'Ann')
        self.assertEqual(bc.display_name('bokim', github={'bokim': 'Bo Kim'}), 'Bo')
        self.assertEqual(bc.display_name('bkim', full_names=['Bo Kim']), 'Bo')
        self.assertEqual(bc.display_name('cyz9', ids=['cy.zed@example.com']), 'Cy')
        self.assertEqual(bc.display_name('qq123', ids=['prs_h'], names=names), 'qq123')  # nothing resolves

    def test_full_name_match_needs_exactly_one(self):
        self.assertEqual(bc.full_name_match('annlee', ['Ann Lee', 'Bo Kim']), 'Ann Lee')
        self.assertEqual(bc.full_name_match('alee', ['Ann Lee', 'Al Lee']), None)  # ambiguous: Ann or Al
        self.assertIsNone(bc.full_name_match('abc', ['Ab C']))

    def test_github_names_bounded(self):
        calls = []

        def run(cmd):
            calls.append(cmd)
            return {'name': 'Bo Kim'} if cmd[2] == 'users/bokim' else {'name': None}
        self.assertEqual(bc.github_names(['bokim', 'noname', 'bad name!', None], run), {'bokim': 'Bo Kim'})
        self.assertEqual(sorted(c[2] for c in calls), ['users/bokim', 'users/noname'])
        self.assertEqual(len(bc.github_names([f'u{i}' for i in range(40)], lambda c: {}, limit=20)), 0)

    def test_resolve_names_on_a_section(self):
        sec = {'dms': [{'from': 'annlee77', 'from_uid': 'prs_a'}], 'prs': [{'author': 'bokim'}, {'title': 'no author'}]}
        bc.resolve_names(sec, {'prs_a': 'Ann Lee'}, [], {'bokim': 'Bo Kim'})
        self.assertEqual(sec['dms'][0]['from_name'], 'Ann')
        self.assertEqual(sec['prs'][0]['author_name'], 'Bo')
        self.assertNotIn('author_name', sec['prs'][1])

    def test_roster_ids_records_names(self):
        names = {}
        bc.roster_ids({'members': [{'person_id': 'PRS_A', 'email': 'a@example.com', 'name': 'Ann Lee'}]}, names)
        self.assertEqual(names, {'prs_a': 'Ann Lee', 'a@example.com': 'Ann Lee'})
        # read_rosters keeps each company's names apart.
        out = {}
        bc.read_rosters(['a', 'b'], lambda cmd: {'members': [{'person_id': 'prs_' + cmd[3], 'name': cmd[3].upper() + ' Lee'}]},
                        names_out=out)
        self.assertEqual(out, {'a': {'prs_a': 'A Lee'}, 'b': {'prs_b': 'B Lee'}})


class SweepWiring(unittest.TestCase):
    def setUp(self):
        sweep.SOURCES.clear()
        self.saved = (sweep.jrun, sweep.DM_SENDERS, sweep._INBOX_CACHE, sweep._PR_CACHE)

    def tearDown(self):
        sweep.jrun, sweep.DM_SENDERS, sweep._INBOX_CACHE, sweep._PR_CACHE = self.saved

    def test_scope_dms_explicit_tag_beats_sender(self):
        rows = [{'fromPersonUid': 'prs_a', 'body': 'x', 'company': 'personal'},
                {'fromPersonUid': 'prs_a', 'body': 'y'}]
        senders = {'prs_a': 'a'}
        self.assertEqual([r['preview'] for r in sweep.scope_dms(rows, 'a', senders)], ['y'])
        personal = sweep.scope_dms(rows, None, senders)
        self.assertEqual([(r['preview'], r['company_basis']) for r in personal], [('x', 'tag')])
        # Without senders, the untagged message stays personal, as before.
        self.assertEqual([r['preview'] for r in sweep.scope_dms(rows, None, None)], ['x', 'y'])

    def test_company_dms_skipped_only_without_attribution(self):
        sweep.jrun = lambda cmd, timeout=90: [{'fromPersonUid': 'prs_a', 'body': 'hi'}]
        sweep._INBOX_CACHE = None
        sweep.DM_SENDERS = None
        self.assertIsNone(sweep.dms('a'))
        self.assertEqual(sweep.SOURCES['dms']['skipped_reason'], sweep.INBOX_NO_COMPANY_TAG)
        sweep.DM_SENDERS = {}
        self.assertEqual(sweep.dms('a'), [])  # rosters read, nobody unique: an honest empty
        self.assertEqual(sweep.SOURCES['dms']['state'], 'ok')
        sweep.DM_SENDERS = {'prs_a': 'a'}
        self.assertEqual([r['from_uid'] for r in sweep.dms('a')], ['prs_a'])

    def test_pr_search_cached_only_inside_a_person_run(self):
        calls = []
        sweep.jrun = lambda cmd, timeout=90: calls.append(cmd) or []
        with patch.object(sweep, '_review_meta', return_value={}):
            sweep._PR_CACHE = None
            sweep.prs(None, '2026-10-01')
            sweep.prs(None, '2026-10-01')
            self.assertEqual(len(calls), 4)  # author + review-requested, twice
            sweep._PR_CACHE = {}
            sweep.prs(None, '2026-10-01')
            sweep.prs(None, '2026-10-01')
            self.assertEqual(len(calls), 6)

    def test_company_has_repos(self):
        m = repo_map()
        self.assertTrue(sweep.company_has_repos(m, 'acme'))
        self.assertFalse(sweep.company_has_repos(m, 'beta'))  # its only repos: no remote, or shared
        self.assertTrue(sweep.company_has_repos(repo_map({'beta': 'beta-org'}), 'beta'))
        self.assertFalse(sweep.company_has_repos(m, 'empty'))
        self.assertFalse(sweep.company_has_repos(None, 'acme'))


if __name__ == '__main__':
    unittest.main()
