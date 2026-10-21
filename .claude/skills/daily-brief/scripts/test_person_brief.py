"""Person-mode orchestration tests: no live services or machine configuration."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('sweep', Path(__file__).with_name('brief-sweep.py'))
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)

class PersonBrief(unittest.TestCase):
    def build(self, members=(), locked=(), flags=(), prior_mode=None, membership_error=None, lock_error=None, fail_company=None):
        with tempfile.TemporaryDirectory() as root:
            out = Path(root) / 'workspace/brief/current/brief-data.json'
            out.parent.mkdir(parents=True)
            if prior_mode:
                previous = out.parent.parent / 'previous'
                previous.mkdir()
                (previous / 'brief-data.json').write_text(json.dumps({'mode': prior_mode, 'company': None, 'personal': {}, 'companies': {}}))
                (out.parent.parent / 'index.jsonl').write_text(json.dumps({'state': 'ready', 'run_id': 'previous', 'company': None}) + '\n')
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(sweep, 'membership_slugs', return_value=list(members), side_effect=membership_error))
                stack.enter_context(patch.object(sweep, 'read_session_lock', return_value=list(locked), side_effect=lock_error))
                for name, result in [('sessions', []), ('meetings', []), ('meeting_signals', []), ('dms', []), ('fleet', None), ('prs', []), ('main_health', {})]:
                    stack.enter_context(patch.object(sweep, name, return_value=result))
                meeting = stack.enter_context(patch.object(sweep, 'meetings', side_effect=lambda co, since: []))
                def messages(co):
                    if co is not None and co == fail_company:
                        raise RuntimeError('private upstream details\nsecond line')
                    return [{'title': 'private-' + str(co), 'company': co}]
                stack.enter_context(patch.object(sweep, 'dms', side_effect=messages))
                self.progress_snapshots = []
                original_write = sweep.Status._write
                def record_status(instance, fn):
                    original_write(instance, fn)
                    if instance.path:
                        self.progress_snapshots.append(json.loads(Path(instance.path).read_text()))
                stack.enter_context(patch.object(sweep.Status, '_write', record_status))
                stack.enter_context(patch.object(sweep, 'latest_import', return_value=None))
                local = sweep._load_local_sessions()
                stack.enter_context(patch.object(local, 'scan', return_value=[]))
                stack.enter_context(patch.object(local, 'inventory', side_effect=AssertionError('inventory read')))
                stack.enter_context(patch.object(sweep, '_load_local_sessions', return_value=local))
                stack.enter_context(patch.object(sweep, 'welcome_inputs', return_value={
                    'inv': None, 'recent': [], 'tree': None, 'company_for': None, 'notes': []}))
                stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                sweep.main(list(flags) + ['--hq-root', root, '--out', str(out), '--me', 'Test', '--status', str(out.parent / 'status.json')])
                return json.loads(out.read_text()), meeting.call_args_list

    def test_zero_companies_default_welcome(self):
        data, calls = self.build()
        self.assertEqual(data['mode'], 'person')
        self.assertEqual(data['companies'], {})
        self.assertEqual(data['welcome']['getting_started'], sweep.GETTING_STARTED)
        self.assertFalse(calls)

    def test_one_company(self):
        data, calls = self.build(['alpha'], ['alpha'], ['--all'])
        self.assertEqual(list(data['companies']), ['alpha'])
        self.assertEqual([c.args[0] for c in calls], ['alpha'])

    def test_three_company_isolation(self):
        data, _ = self.build(['a', 'b', 'c'], ['a', 'b', 'c'])
        for slug, section in data['companies'].items():
            self.assertEqual(section['dms'], [{'title': 'private-' + slug, 'company': slug}])
        self.assertEqual(data['personal']['dms'][0]['company'], None)

    def test_partial_lock(self):
        data, calls = self.build(['a', 'b', 'c'], ['b'])
        self.assertEqual(list(data['companies']), ['b'])
        self.assertEqual([c.args[0] for c in calls], ['b'])
        self.assertEqual([r['company'] for r in data['not_included']], ['a', 'c'])

    def test_back_compat(self):
        for flags, mode in [(['--personal'], 'personal'), (['--company', 'a'], 'company')]:
            data, _ = self.build(['a'], ['a'], flags)
            self.assertEqual(data['mode'], mode)
            self.assertTrue(data['welcome']['first_run'])

    def test_welcome_person_history_any_mode(self):
        data, _ = self.build(['a'], ['a'], ['--company', 'a'], prior_mode='personal')
        self.assertIsNone(data['welcome'])

    def test_previous_run_person_only(self):
        data, _ = self.build(prior_mode='personal')
        self.assertIsNone(data['previous_run'])
        data, _ = self.build(prior_mode='person')
        self.assertEqual(data['previous_run']['run_id'], 'previous')

    def test_personal_history_excludes_person_runs(self):
        data, _ = self.build(flags=['--personal'], prior_mode='person')
        self.assertIsNone(data['previous_run'])

    def test_person_validator_rejects_cross_company_item(self):
        rank = sweep._sibling('brief_rank')
        brief = {'mode': 'person', 'personal': {}, 'companies': {
            'a': {'items': {'reminders': [{'id': 'x', 'company': 'b'}]}}}}
        self.assertEqual(len(rank.check_brief(brief)['isolation_problems']), 1)
        brief['companies']['a']['items']['reminders'][0]['company'] = 'a'
        self.assertEqual(rank.check_brief(brief)['isolation_problems'], [])

    def test_isolation_drops_conflicting_rows_without_relabelling(self):
        leaked = {'company': 'b', 'title': 'private'}
        participant = {'name': 'Guest', 'company': 'b'}
        untagged_participant = {'name': 'Other guest'}
        section = {'dms': [leaked, {'title': 'untagged'}, {'company': 'a'}],
                   'meetings': [{'title': 'Meeting', 'participants': [participant, untagged_participant]}]}
        sweep.tag_items(section, 'a')
        self.assertEqual(len(section['dms']), 2)
        self.assertTrue(all(row['company'] == 'a' for row in section['dms']))
        self.assertEqual(leaked['company'], 'b')
        self.assertEqual(section['isolation_errors'][0]['source'], 'dms')
        self.assertEqual(participant, {'name': 'Guest', 'company': 'b'})
        self.assertNotIn('company', untagged_participant)

    def test_failed_memberships_keep_getting_started_and_plain_error(self):
        data, calls = self.build(membership_error=RuntimeError('signed out\nprivate detail'))
        self.assertEqual(data['welcome']['getting_started'], sweep.GETTING_STARTED)
        error = data['sources']['memberships']['error']
        self.assertEqual(error, 'Could not load your companies. Sign in or try again when connected.')
        self.assertNotIn('\n', error)
        self.assertFalse(calls)
        self.assertFalse(any(step['kind'] == 'connect_company' for step in data['welcome']['next_steps']))

    def test_failed_lock_keeps_personal_and_lists_exclusions(self):
        data, calls = self.build(['a', 'b'], lock_error=RuntimeError('lock failed\ntrace'))
        self.assertEqual(data['companies'], {})
        self.assertEqual(len(data['not_included']), 2)
        self.assertIn('personal', data)
        self.assertNotIn('\n', data['sources']['company_lock']['error'])
        self.assertFalse(calls)

    def test_company_failure_preserves_other_sections_and_progress(self):
        data, _ = self.build(['a', 'b', 'c'], ['a', 'b', 'c'], fail_company='b')
        self.assertIn('error', data['companies']['b'])
        self.assertNotIn('\n', data['companies']['b']['error'])
        self.assertEqual(data['companies']['c']['dms'][0]['company'], 'c')
        updates = [row for row in self.progress_snapshots if row.get('mode') == 'person']
        self.assertEqual(len(updates), 4)
        self.assertEqual([row['step'] for row in updates[1:]],
                         ['Finished company a', 'Finished company b', 'Finished company c'])
        self.assertEqual(sorted(row['progress'] for row in updates), [row['progress'] for row in updates])
        self.assertAlmostEqual(updates[-1]['progress'], 0.7)

    def test_one_welcome_and_connect_company_only_for_zero_memberships(self):
        for members in ([], ['a', 'b']):
            data, _ = self.build(members, members)
            self.assertIsNotNone(data['welcome'])
            self.assertNotIn('welcome', data['personal'])
            self.assertTrue(all('welcome' not in part for part in data['companies'].values()))
            connect = any(step['kind'] == 'connect_company' for step in data['welcome']['next_steps'])
            self.assertEqual(connect, not members)

    def test_explicit_personal_welcome_does_not_offer_existing_company(self):
        data, _ = self.build(['a'], ['a'], flags=['--personal'])
        self.assertFalse(any(step['kind'] == 'connect_company' for step in data['welcome']['next_steps']))

    def test_personal_rank_allows_null_company_but_requires_field(self):
        rank = sweep._sibling('brief_rank')
        item = {'id': 'x', 'title': 'Review the draft', 'product': 'Work', 'company': None}
        brief = {'mode': 'personal', 'items': {'decisions': [item]}}
        problems = rank.check_brief(brief)['title_problems']
        self.assertFalse(any(row['field'] == 'company' for row in problems))
        del item['company']
        self.assertTrue(any(row['field'] == 'company' for row in rank.check_brief(brief)['title_problems']))
        item['company'] = None
        brief['mode'] = 'company'
        self.assertTrue(any(row['field'] == 'company' for row in rank.check_brief(brief)['title_problems']))

    def test_history_reads_at_most_fourteen_files_even_when_missing(self):
        runs = [{'run_id': str(i)} for i in range(100)]
        with patch('builtins.open', side_effect=FileNotFoundError) as opened:
            self.assertEqual(sweep.load_prior_data('/tmp/brief', runs), [])
            self.assertEqual(opened.call_count, 14)
            self.assertTrue(opened.call_args_list[0].args[0].endswith('/99/brief-data.json'))
            self.assertTrue(opened.call_args_list[-1].args[0].endswith('/86/brief-data.json'))

    def test_membership_inventory(self):
        with patch.object(sweep, 'run', return_value='COMPANY  MODE  UPDATED  MEMBERSHIP\n────  ───  ───  ───\na  all  —  key\nb  shared  —  key2'):
            self.assertEqual(sweep.membership_slugs('/tmp'), ['a', 'b'])
        with patch.object(sweep, 'run', return_value='No memberships found. Run `hq onboard` or accept an invite first.'):
            self.assertEqual(sweep.membership_slugs('/tmp'), [])
        with patch.object(sweep, 'run', return_value='Authentication failed'):
            with self.assertRaises(RuntimeError):
                sweep.membership_slugs('/tmp')

if __name__ == '__main__':
    unittest.main()
