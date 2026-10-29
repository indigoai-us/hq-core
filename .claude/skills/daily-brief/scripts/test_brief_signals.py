"""Synced-signal reads for the Daily Brief: fixture vaults only, no live services."""
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

HERE = Path(__file__).parent
bs_spec = importlib.util.spec_from_file_location('brief_signals', HERE / 'brief_signals.py')
bs = importlib.util.module_from_spec(bs_spec)
bs_spec.loader.exec_module(bs)
sweep_spec = importlib.util.spec_from_file_location('sweep', HERE / 'brief-sweep.py')
sweep = importlib.util.module_from_spec(sweep_spec)
sweep_spec.loader.exec_module(sweep)

NOW = dt.datetime(2026, 10, 27, 15, 0, tzinfo=dt.timezone.utc)
EMAIL = 'pat@example.com'
# sha256('pat@example.com')[:16] and sha256('lee@example.com')[:16], pinned.
PAT = 'fe9733fcc9650127'
LEE = '556740ed46f084c7'


def write(root, rel, text):
    p = Path(root) / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)
    return p


def signal(root, key, sid, typ, ref, content, at, owner=None):
    fm = [f'signal_id: {sid}', f'type: {typ}', f'source_ref: {ref}' if ref else None,
          f'canonical_content: {content}', f'written_at: {at}', f'owner: {owner}' if owner else None]
    write(root, key, '---\n' + '\n'.join(x for x in fm if x) + '\n---\n\n# ' + content + '\n')


def index(root, day, rows):
    write(root, f'signals/_index/{day}.json', json.dumps(rows))


def row(sid, typ, ref, key, at):
    return {'signal_id': sid, 'type': typ, 'source_ref': ref, 'key': key, 'written_at': at}


def build_today(root):
    """Today's index: a company signal, one in the person's own folder, one in
    someone else's folder, a meeting decision and action item, and an uncited row."""
    at = '2026-10-27T13:00:00Z'
    rows = [
        ('s-co', 'decision', 'sources/slack/C1/1700.raw.json', 'signals/decision/s-co.md', 'Ship the sync on Friday', None),
        ('s-own', 'action_item', 'sources/gmail/msg-42.md', f'signals/@{PAT}/action_item/s-own.md', 'Reply to the vendor', 'Pat Lane'),
        ('s-other', 'action_item', 'sources/gmail/msg-77.md', f'signals/@{LEE}/action_item/s-other.md', 'Private to Lee', 'Lee'),
        ('s-mtg-d', 'decision', 'sources/meeting-events/evt-1.md', 'signals/decision/s-mtg-d.md', 'Keep the weekly cadence', None),
        ('s-mtg-a', 'action_item', 'sources/meeting-events/evt-1.md', 'signals/action_item/s-mtg-a.md', 'Pat drafts the plan', 'Pat Lane'),
        ('s-nocite', 'risk', None, 'signals/risk/s-nocite.md', 'No source', None),
    ]
    for sid, typ, ref, key, content, owner in rows:
        signal(root, key, sid, typ, ref, content, at, owner)
    index(root, '2026-10-27', [row(sid, typ, ref, key, at) for sid, typ, ref, key, _, _ in rows])
    write(root, 'sources/meeting-events/evt-1.md',
          '---\ntitle: Weekly planning\npayload_ref: sources/meetings/tr-9.md\n---\n')
    write(root, 'sources/_cursors/@' + PAT + '/slack.conn-a.json',
          json.dumps({'cursor': 'x', 'updatedAt': '2026-10-27T14:30:00Z', 'lastEventKey': 'k'}))
    p = write(root, 'sources/_cursors/@' + PAT + '/gmail.json', json.dumps({'cursor': 'y'}))
    mt = dt.datetime(2026, 10, 27, 9, 0, tzinfo=dt.timezone.utc).timestamp()
    os.utime(p, (mt, mt))


class TodayIndex(unittest.TestCase):
    def test_audience_key_is_pinned_and_own_keys_are_company_plus_email(self):
        self.assertEqual(bs.audience_key([EMAIL]), PAT)
        self.assertEqual(bs.audience_key(['  PAT@Example.com ']), PAT)
        self.assertEqual(bs.audience_keys(EMAIL), ['company', PAT])
        self.assertEqual(bs.audience_keys(None), ['company'])

    def test_lines_carry_source_ref_and_cite_for_own_keys_only(self):
        with tempfile.TemporaryDirectory() as root:
            build_today(root)
            res = bs.collect(root, NOW, 24, EMAIL)
        ids = {x['signal_id']: x for x in res['lines']}
        self.assertEqual(set(ids), {'s-co', 's-own', 's-mtg-d', 's-mtg-a'})
        self.assertNotIn('s-other', ids)
        for x in res['lines']:
            self.assertTrue(x['source_ref'], x)
            self.assertTrue(x['cite'], x)
        self.assertEqual(ids['s-co']['cite'], '1700')
        self.assertEqual(ids['s-own']['source_ref'], 'sources/gmail/msg-42.md')
        self.assertEqual(ids['s-own']['text'], 'Reply to the vendor')
        self.assertEqual(ids['s-mtg-d']['meeting'], {'title': 'Weekly planning', 'transcript_id': 'tr-9'})
        self.assertEqual(res['dropped_uncited'], 1)
        self.assertIsNone(res['lag'])
        self.assertEqual(res['keys'], sorted(['company', PAT]))
        # The window reaches back into yesterday, which has no index file.
        self.assertEqual(res['legacy_days'], ['2026-10-26'])

    def test_no_email_reads_company_folders_only(self):
        with tempfile.TemporaryDirectory() as root:
            build_today(root)
            res = bs.collect(root, NOW, 24, None)
        self.assertNotIn('s-own', {x['signal_id'] for x in res['lines']})
        self.assertEqual(res['freshness'], [])

    def test_rows_outside_the_window_are_left_out(self):
        with tempfile.TemporaryDirectory() as root:
            signal(root, 'signals/decision/old.md', 'old', 'decision', 'sources/slack/C1/1.raw.json', 'Old', '2026-10-26T10:00:00Z')
            signal(root, 'signals/decision/new.md', 'new', 'decision', 'sources/slack/C1/2.raw.json', 'New', '2026-10-26T16:00:00Z')
            index(root, '2026-10-26', [row('old', 'decision', 'sources/slack/C1/1.raw.json', 'signals/decision/old.md', '2026-10-26T10:00:00Z'),
                                       row('new', 'decision', 'sources/slack/C1/2.raw.json', 'signals/decision/new.md', '2026-10-26T16:00:00Z')])
            index(root, '2026-10-27', [])
            res = bs.read_window(root, NOW, 24, EMAIL)
        self.assertEqual([x['signal_id'] for x in res['lines']], ['new'])


class Freshness(unittest.TestCase):
    def test_cursor_updated_at_wins_and_mtime_is_the_fallback(self):
        with tempfile.TemporaryDirectory() as root:
            build_today(root)
            marks = {m['adapter']: m for m in bs.freshness(root, PAT)}
        self.assertEqual(marks['slack'], {'adapter': 'slack', 'connection': 'conn-a',
                                          'last_synced': '2026-10-27T14:30:00+00:00', 'source': 'cursor'})
        self.assertEqual(marks['gmail'], {'adapter': 'gmail', 'connection': None,
                                          'last_synced': '2026-10-27T09:00:00+00:00', 'source': 'mtime'})

    def test_other_person_cursors_are_not_read(self):
        with tempfile.TemporaryDirectory() as root:
            write(root, f'sources/_cursors/@{LEE}/slack.json', json.dumps({'updatedAt': '2026-10-27T14:00:00Z'}))
            self.assertEqual(bs.freshness(root, PAT), [])


class StaleIndex(unittest.TestCase):
    def test_lag_line_names_the_last_ledger_run(self):
        with tempfile.TemporaryDirectory() as root:
            index(root, '2026-10-25', [])
            write(root, f'sources/_runs/@{PAT}/2026-10-25.jsonl', '\n'.join(json.dumps(e) for e in [
                {'runId': 'run-a', 'trigger': 'schedule', 'adapter': 'slack', 'status': 'ok',
                 'startedAt': '2026-10-25T08:00:00Z', 'finishedAt': '2026-10-25T08:01:00Z'},
                {'runId': 'run-b', 'trigger': 'schedule', 'adapter': 'gmail', 'status': 'error',
                 'startedAt': '2026-10-25T09:00:00Z', 'finishedAt': '2026-10-25T09:02:00Z', 'error': 'x'},
            ]) + '\n')
            res = bs.collect(root, NOW, 24, EMAIL)
        lag = res['lag']
        self.assertEqual(lag['newest_index_date'], '2026-10-25')
        self.assertEqual(lag['days_behind'], 2)
        self.assertEqual(lag['last_run']['run_id'], 'run-b')
        self.assertEqual(lag['line'], 'Signals are behind: newest index is 2026-10-25 (last sync run 2026-10-25, gmail, error).')

    def test_lag_with_no_index_and_no_runs(self):
        with tempfile.TemporaryDirectory() as root:
            lag = bs.lag(root, NOW, PAT)
        self.assertEqual(lag['line'], 'Signals are behind: no signal index yet (no sync run recorded).')


class LegacyFolders(unittest.TestCase):
    def test_days_without_an_index_fall_back_to_type_folders(self):
        with tempfile.TemporaryDirectory() as root:
            signal(root, 'signals/slack-dm/decision/d1.md', 'd1', 'decision', 'sources/slack/D1/5.raw.json', 'Legacy DM decision', '2026-10-27T10:00:00Z')
            signal(root, f'signals/@{PAT}/risk/r1.md', 'r1', 'risk', 'sources/gmail/m1.md', 'Own risk', '2026-10-27T11:00:00Z')
            signal(root, f'signals/@{LEE}/risk/r2.md', 'r2', 'risk', 'sources/gmail/m2.md', 'Other risk', '2026-10-27T11:00:00Z')
            signal(root, 'signals/key_point/k1.md', 'k1', 'key_point', 'sources/slack/C1/9.raw.json', 'Too old', '2026-10-20T11:00:00Z')
            res = bs.read_window(root, NOW, 24, EMAIL)
        self.assertEqual(sorted(x['signal_id'] for x in res['lines']), ['d1', 'r1'])
        self.assertEqual(res['legacy_days'], ['2026-10-26', '2026-10-27'])
        self.assertTrue(all(x['source_ref'] for x in res['lines']))


class Meetings(unittest.TestCase):
    def test_meeting_rows_group_synced_meeting_signals(self):
        with tempfile.TemporaryDirectory() as root:
            build_today(root)
            lines = bs.read_window(root, NOW, 24, EMAIL)['lines']
        mtgs = [{'id': 'tr-9', 'title': 'Weekly planning', 'start': '2026-10-27T12:00:00Z'}]
        rows = bs.meeting_rows(lines, mtgs, lambda o: o == 'Pat Lane')
        self.assertEqual(len(rows), 1)
        r = rows[0]
        self.assertEqual((r['meeting_id'], r['title'], r['start']), ('tr-9', 'Weekly planning', '2026-10-27T12:00:00Z'))
        self.assertEqual(r['counts'], {'decision': 1, 'action_item': 1})
        self.assertEqual(r['decisions'][0]['source_ref'], 'sources/meeting-events/evt-1.md')
        self.assertEqual(r['decisions'][0]['cite'], 'evt-1')
        self.assertTrue(r['action_items'][0]['mine'])

    def test_source_ref_outside_the_vault_sources_is_never_read(self):
        with tempfile.TemporaryDirectory() as root:
            vault = Path(root) / 'vault'
            (vault / 'sources/meeting-events').mkdir(parents=True)
            (vault / 'signals/@0123456789abcdef/decision').mkdir(parents=True)
            (vault / 'signals/@0123456789abcdef/decision/x.md').write_text('---\ntitle: Other person\n---\n')
            (vault / 'sources/meeting-events/ok.md').write_text('---\ntitle: Planning\n---\n')
            (Path(root) / 'outside.md').write_text('---\ntitle: Outside\n---\n')
            os.symlink(Path(root) / 'outside.md', vault / 'sources/meeting-events/link.md')
            v = str(vault)
            self.assertEqual(bs._meeting_of(v, 'sources/meeting-events/ok.md')['title'], 'Planning')
            for ref in ('sources/meeting-events/../../signals/@0123456789abcdef/decision/x.md',
                        'sources/meeting-events/../../../outside.md',
                        'sources/meeting-events/link.md'):
                self.assertIsNone(bs._meeting_of(v, ref), ref)
            self.assertIsNone(bs.safe_vault_path(v, str(Path(root) / 'outside.md'), 'sources'))

    def test_signal_keys_and_folders_that_link_outside_the_vault_are_never_read(self):
        with tempfile.TemporaryDirectory() as root:
            vault = Path(root) / 'vault'
            (vault / 'signals/decision').mkdir(parents=True)
            (vault / 'signals/decision/ok.md').write_text('---\ncanonical_content: Inside\n---\n')
            (Path(root) / 'outside').mkdir()
            (Path(root) / 'outside/x.md').write_text('---\ncanonical_content: Outside\n---\n')
            os.symlink(Path(root) / 'outside/x.md', vault / 'signals/decision/link.md')
            os.symlink(Path(root) / 'outside', vault / 'signals/risk')
            v = str(vault)
            self.assertEqual(bs._line(v, {'key': 'signals/decision/ok.md'})['text'], 'Inside')
            self.assertIsNone(bs._line(v, {'key': 'signals/decision/link.md'}))
            self.assertIsNone(bs._line(v, {'key': 'signals/risk/x.md'}))
            # files carry no written_at, so the scan uses mtime: a window around the real now
            real_now = dt.datetime.now(dt.timezone.utc)
            lo, hi = real_now - dt.timedelta(days=1), real_now + dt.timedelta(days=1)
            keys = {r['key'] for r in bs._legacy_rows(v, {'company'}, lo, hi)}
            self.assertIn('signals/decision/ok.md', keys)
            self.assertNotIn('signals/risk/x.md', keys)
            self.assertNotIn('signals/decision/link.md', keys)
            # a sources/ folder that is itself a link out of the vault is refused
            (Path(root) / 'elsewhere').mkdir()
            os.symlink(Path(root) / 'elsewhere', vault / 'sources')
            (Path(root) / 'elsewhere/m.md').write_text('---\ntitle: Elsewhere\n---\n')
            self.assertIsNone(bs.safe_vault_path(v, 'sources/m.md', 'sources'))

    def test_meeting_rows_skip_title_match_for_a_repeated_title(self):
        line = {'type': 'decision', 'text': 'Ship it', 'owner': None, 'source_ref': 'sources/meeting-events/e.md',
                'cite': 'e', 'meeting': {'title': 'Standup', 'transcript_id': None}}
        mtgs = [{'id': 'a', 'title': 'Standup', 'start': '2026-10-26T15:00:00Z'},
                {'id': 'b', 'title': 'Standup', 'start': '2026-10-27T15:00:00Z', 'recorded_by_me': True}]
        self.assertIsNone(bs.meeting_rows([line], mtgs)[0]['meeting_id'])
        rows = bs.meeting_rows([line], mtgs[1:])
        self.assertEqual((rows[0]['meeting_id'], rows[0]['recorded_by_me']), ('b', True))

    def test_meeting_signals_fail_when_synced_signals_were_not_read(self):
        sweep.SYNCED.clear()
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertIsNone(sweep.meeting_signals('acme-test', [{'id': 'm1', 'title': 'x', 'start': ''}]))
        self.assertEqual(sweep.SOURCES['meeting_signals']['state'], 'failed')
        sweep.SOURCES.clear()

    def test_meetings_with_no_meeting_signals_get_one_plain_line(self):
        with tempfile.TemporaryDirectory() as root:
            signal(root, 'signals/decision/s1.md', 's1', 'decision', 'sources/slack/C1/1.raw.json', 'Slack only', '2026-10-27T13:00:00Z')
            index(root, '2026-10-27', [row('s1', 'decision', 'sources/slack/C1/1.raw.json', 'signals/decision/s1.md', '2026-10-27T13:00:00Z')])
            lines = bs.read_window(root, NOW, 24, EMAIL)['lines']
        self.assertEqual(len(lines), 1)
        mtgs = [{'id': 'm1', 'title': 'Design review'}, {'id': 'm2', 'title': 'Standup'}]
        self.assertEqual(bs.meetings_without_signals(lines, mtgs),
                         {'count': 2, 'line': 'Signals not yet generated for 2 meetings.'})
        self.assertEqual(bs.meetings_without_signals(lines, mtgs[:1])['line'], 'Signals not yet generated for 1 meeting.')
        self.assertIsNone(bs.meetings_without_signals(lines, []))

    def test_no_line_when_meeting_signals_exist(self):
        with tempfile.TemporaryDirectory() as root:
            build_today(root)
            lines = bs.read_window(root, NOW, 24, EMAIL)['lines']
        self.assertIsNone(bs.meetings_without_signals(lines, [{'id': 'tr-9', 'title': 'Weekly planning'}]))


class SweepRun(unittest.TestCase):
    """A company sweep over the fixture vault with every live path stubbed."""

    def run_sweep(self, root, mtgs, extra=()):
        out = Path(root) / 'workspace/brief/run-1/brief-data.json'
        out.parent.mkdir(parents=True)
        live_calls = []

        def no_subprocess(cmd, *a, **k):
            live_calls.append(cmd)
            raise AssertionError(f'live call: {cmd}')

        def no_network(*a, **k):
            live_calls.append(a)
            raise AssertionError('network call')

        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(sweep, 'read_session_lock', return_value=['acme-test']))
            # Identity comes from the HQ login; pin it so the run stays hermetic.
            stack.enter_context(patch.object(sweep, 'hq_identity', lambda: None))
            for name, result in [('sessions', []), ('dms', []), ('fleet', None), ('prs', []), ('main_health', {})]:
                stack.enter_context(patch.object(sweep, name, sweep.source(name)(lambda *a, _r=result, **k: _r)))
            stack.enter_context(patch.object(sweep, 'meetings', sweep.source('meetings')(lambda co, since: list(mtgs))))
            stack.enter_context(patch.object(sweep, 'jrun', side_effect=no_subprocess))
            stack.enter_context(patch.object(sweep.subprocess, 'run', side_effect=no_subprocess))
            stack.enter_context(patch('urllib.request.urlopen', side_effect=no_network))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            t0 = time.monotonic()
            sweep.main(['--company', 'acme-test', '--hq-root', root, '--out', str(out), '--today', '2026-10-27',
                        '--now', '2026-10-27T15:00:00Z', '--email', EMAIL, '--me', 'Pat Lane', '--org', 'acme',
                        '--repos', 'app', *extra])
            secs = time.monotonic() - t0
        sweep.SOURCES.clear()
        self.assertEqual(live_calls, [])
        return json.loads(out.read_text()), secs

    def test_timed_company_run_reads_synced_signals(self):
        with tempfile.TemporaryDirectory() as root:
            build_today(str(Path(root) / 'companies/acme-test'))
            mtgs = [{'id': 'tr-9', 'title': 'Weekly planning', 'start': '2026-10-27T12:00:00Z'}]
            d, secs = self.run_sweep(root, mtgs)
        print(f'\n[timed] fixture company sweep: {secs:.2f}s')
        self.assertLess(secs, 120)
        syn = d['synced_signals']
        self.assertEqual({x['signal_id'] for x in syn['lines']}, {'s-co', 's-own', 's-mtg-d', 's-mtg-a'})
        self.assertTrue(all(x['source_ref'] and x['cite'] for x in syn['lines']))
        self.assertIsNone(syn['lag'])
        self.assertIsNone(syn['meetings_without_signals'])
        self.assertEqual({m['adapter'] for m in syn['freshness']}, {'slack', 'gmail'})
        self.assertEqual(d['sources']['synced_signals']['state'], 'ok')
        self.assertEqual(len(d['meeting_signals']), 1)
        self.assertEqual(d['meeting_signals'][0]['decisions'][0]['source_ref'], 'sources/meeting-events/evt-1.md')
        self.assertTrue(d['meetings'][0]['attended'])

    def test_company_run_says_when_meetings_have_no_signals_yet(self):
        with tempfile.TemporaryDirectory() as root:
            vault = str(Path(root) / 'companies/acme-test')
            signal(vault, 'signals/decision/s1.md', 's1', 'decision', 'sources/slack/C1/1.raw.json', 'Slack only', '2026-10-27T13:00:00Z')
            index(vault, '2026-10-25', [])
            mtgs = [{'id': 'm1', 'title': 'Design review', 'start': '2026-10-27T10:00:00Z'},
                    {'id': 'm2', 'title': 'Standup', 'start': '2026-10-27T11:00:00Z'}]
            d, _ = self.run_sweep(root, mtgs)
        syn = d['synced_signals']
        self.assertEqual(syn['meetings_without_signals']['line'], 'Signals not yet generated for 2 meetings.')
        self.assertTrue(syn['lag']['line'].startswith('Signals are behind: newest index is 2026-10-25'))
        self.assertEqual(d['meeting_signals'], [])

    def test_personal_mode_skips_synced_signals(self):
        with tempfile.TemporaryDirectory() as root:
            out = Path(root) / 'brief-data.json'
            with contextlib.ExitStack() as stack:
                for name, result in [('sessions', []), ('dms', []), ('prs', []), ('main_health', {})]:
                    stack.enter_context(patch.object(sweep, name, sweep.source(name)(lambda *a, _r=result, **k: _r)))
                stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                sweep.main(['--personal', '--hq-root', root, '--out', str(out), '--today', '2026-10-27',
                            '--now', '2026-10-27T15:00:00Z', '--email', EMAIL, '--me', 'Pat Lane'])
            d = json.loads(out.read_text())
        sweep.SOURCES.clear()
        self.assertIsNone(d['synced_signals'])
        self.assertEqual(d['sources']['synced_signals']['state'], 'skipped')


class ReviewHardening(unittest.TestCase):
    AT = '2026-10-27T13:00:00Z'

    def _lee_secret(self, root):
        signal(root, f'signals/@{LEE}/decision/x.md', 'lee-x', 'decision', 'sources/gmail/m9.md', 'Lee secret text', self.AT)

    def test_traversal_keys_into_another_person_folder_are_rejected(self):
        for key in (f'signals/./@{LEE}/decision/x.md', f'signals//@{LEE}/decision/x.md'):
            self.assertFalse(bs.own_key_allowed(key, {'company', PAT}), key)
        with tempfile.TemporaryDirectory() as root:
            self._lee_secret(root)
            index(root, '2026-10-27', [
                row('t1', 'decision', 'sources/gmail/m9.md', f'signals/./@{LEE}/decision/x.md', self.AT),
                row('t2', 'decision', 'sources/gmail/m9.md', f'signals//@{LEE}/decision/x.md', self.AT)])
            index(root, '2026-10-26', [])
            res = bs.read_window(root, NOW, 24, EMAIL)
        self.assertEqual(res['lines'], [])
        self.assertNotIn('Lee secret', json.dumps(res))

    def test_non_list_index_is_treated_as_empty(self):
        for raw in ('null', '7', '{"key": "signals/decision/a.md"}'):
            with tempfile.TemporaryDirectory() as root:
                write(root, 'signals/_index/2026-10-27.json', raw)
                index(root, '2026-10-26', [])
                with contextlib.redirect_stderr(io.StringIO()) as err:
                    res = bs.read_window(root, NOW, 24, EMAIL)
            self.assertEqual(res['lines'], [], raw)
            self.assertEqual(err.getvalue().count('not a list'), 1, raw)

    def test_rows_with_non_string_signal_id_are_skipped(self):
        with tempfile.TemporaryDirectory() as root:
            signal(root, 'signals/decision/a.md', 'a', 'decision', 'sources/slack/C1/1.raw.json', 'Good one', self.AT)
            r_list = row(['x'], 'decision', 'sources/slack/C1/1.raw.json', 'signals/decision/a.md', self.AT)
            r_dict = row({'x': 1}, 'decision', 'sources/slack/C1/1.raw.json', 'signals/decision/a.md', self.AT)
            index(root, '2026-10-27', [r_list, r_dict, row('a', 'decision', 'sources/slack/C1/1.raw.json', 'signals/decision/a.md', self.AT)])
            index(root, '2026-10-26', [])
            res = bs.read_window(root, NOW, 24, EMAIL)
        self.assertEqual([x['signal_id'] for x in res['lines']], ['a'])

    def test_invalid_index_filename_date_is_skipped(self):
        with tempfile.TemporaryDirectory() as root:
            index(root, '2026-99-99', [])
            index(root, '2026-10-25', [])
            lag = bs.lag(root, NOW, PAT)
        self.assertEqual(lag['newest_index_date'], '2026-10-25')
        self.assertEqual(lag['days_behind'], 2)

    def test_future_index_date_is_treated_as_current(self):
        with tempfile.TemporaryDirectory() as root:
            index(root, '2026-10-28', [])
            self.assertIsNone(bs.lag(root, NOW, PAT))

    def test_ledger_numeric_finished_at_is_skipped_and_offsets_compare_as_times(self):
        with tempfile.TemporaryDirectory() as root:
            write(root, f'sources/_runs/@{PAT}/2026-10-25.jsonl', '\n'.join(json.dumps(e) for e in [
                {'runId': 'num', 'adapter': 'slack', 'status': 'ok', 'finishedAt': 42},
                # 09:30Z is later than 10:00+01:00 (09:00Z) though it sorts lower as a string.
                {'runId': 'late', 'adapter': 'gmail', 'status': 'ok', 'finishedAt': '2026-10-25T09:30:00Z'},
                {'runId': 'early', 'adapter': 'slack', 'status': 'ok', 'finishedAt': '2026-10-25T10:00:00+01:00'},
            ]) + '\n')
            run = bs.last_ledger_run(root, PAT)
            index(root, '2026-10-25', [])
            lag = bs.lag(root, NOW, PAT)
        self.assertEqual(run['run_id'], 'late')
        self.assertIn('last sync run 2026-10-25, gmail, ok', lag['line'])

    def test_legacy_scan_skips_unlistable_folder(self):
        with tempfile.TemporaryDirectory() as root:
            signal(root, 'signals/decision/d1.md', 'd1', 'decision', 'sources/slack/C1/1.raw.json', 'Kept', self.AT)
            signal(root, 'signals/risk/r1.md', 'r1', 'risk', 'sources/slack/C1/2.raw.json', 'Lost', self.AT)
            real = os.listdir
            bad = os.path.join(root, 'signals', 'risk')

            def fake(p='.'):
                if os.fspath(p) == bad:
                    raise PermissionError(p)
                return real(p)
            with patch.object(bs.os, 'listdir', fake):
                res = bs.read_window(root, NOW, 24, EMAIL)
        self.assertEqual([x['signal_id'] for x in res['lines']], ['d1'])

    def test_legacy_scan_is_capped(self):
        with tempfile.TemporaryDirectory() as root:
            for i in range(5):
                signal(root, f'signals/decision/d{i}.md', f'd{i}', 'decision', f'sources/slack/C1/{i}.raw.json', 'x', self.AT)
            lo = NOW - dt.timedelta(hours=24)
            with patch.object(bs, 'LEGACY_SCAN_MAX_FILES', 3):
                rows = bs._legacy_rows(root, {'company'}, lo, NOW)
        self.assertEqual(len(rows), 3)
        self.assertEqual(bs.LEGACY_SCAN_MAX_FILES, 400)


class Identity(unittest.TestCase):
    UID = 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d'
    OTHER_UID = 'prs_test_other_person'
    AT = '2026-10-27T13:00:00Z'

    def test_whoami_json_gives_email_and_uid_keys(self):
        out = json.dumps({'authenticated': True, 'email': EMAIL, 'personUid': self.UID, 'sub': 's'})
        done = type('R', (), {'returncode': 0, 'stdout': out})()
        with patch.object(sweep.subprocess, 'run', return_value=done) as run:
            who = sweep.hq_identity()
        self.assertEqual(run.call_args[0][0], ['hq', 'whoami', '--json'])
        self.assertEqual(who, (EMAIL, self.UID))
        email, uid, src = sweep.resolve_identity('flag@example.com', whoami=lambda: who)
        self.assertEqual((email, uid, src), (EMAIL, self.UID, 'hq-whoami'))
        self.assertEqual(bs.audience_keys(email, uid), ['company', PAT, bs.audience_key([self.UID])])
        self.assertEqual(bs.audience_key([self.UID]), '53cc8fd729d533ec')

    def test_plain_whoami_line_is_parsed(self):
        done = type('R', (), {'returncode': 0, 'stdout': f'Logged in as {EMAIL} ({self.UID})\n'})()
        with patch.object(sweep.subprocess, 'run', return_value=done):
            self.assertEqual(sweep.hq_identity(), (EMAIL, self.UID))

    def test_falls_back_to_git_when_whoami_fails(self):
        def run(cmd, **k):
            if cmd[0] == 'hq':
                raise FileNotFoundError('hq')
            return type('R', (), {'returncode': 0, 'stdout': EMAIL + '\n'})()
        with patch.object(sweep.subprocess, 'run', run):
            self.assertEqual(sweep.resolve_identity(None), (EMAIL, None, 'git'))
            self.assertEqual(sweep.resolve_identity('f@example.com'), ('f@example.com', None, 'flag'))

    def test_uid_key_folder_is_own_and_other_uid_is_not(self):
        mine, other = bs.audience_key([self.UID]), bs.audience_key([self.OTHER_UID])
        with tempfile.TemporaryDirectory() as root:
            signal(root, f'signals/@{mine}/decision/u1.md', 'u1', 'decision', 'sources/gmail/a.md', 'Mine by uid', self.AT)
            signal(root, f'signals/@{other}/decision/u2.md', 'u2', 'decision', 'sources/gmail/b.md', 'Other uid', self.AT)
            index(root, '2026-10-27', [row('u1', 'decision', 'sources/gmail/a.md', f'signals/@{mine}/decision/u1.md', self.AT),
                                       row('u2', 'decision', 'sources/gmail/b.md', f'signals/@{other}/decision/u2.md', self.AT)])
            index(root, '2026-10-26', [])
            res = bs.collect(root, NOW, 24, EMAIL, self.UID, 'hq-whoami')
        self.assertEqual([x['signal_id'] for x in res['lines']], ['u1'])
        self.assertEqual(res['person_key'], PAT)
        self.assertEqual(res['identity_source'], 'hq-whoami')


if __name__ == '__main__':
    unittest.main()
