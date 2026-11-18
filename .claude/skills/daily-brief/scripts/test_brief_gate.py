"""Signals gate for the Daily Brief: fake HQ roots in temp dirs, no live services."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location('brief_gate', HERE / 'brief_gate.py')
bg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bg)

TODAY = '2026-10-31'
NOW = '2026-10-31T13:05:00Z'


def steps(status='ok', failed_at=None):
    out = []
    for name in ('garden', 'adapters', 'extract', 'garden', 'upload'):
        s = {'name': name, 'itemsIn': 3, 'itemsOut': 2, 'durationMs': 10, 'status': status}
        if name == failed_at:
            s.update(status='failed', error='Slack refused the connection')
            out.append(s)
            break
        out.append(s)
    return out


def dead_pid():
    """A pid that belonged to a process that has already exited."""
    p = subprocess.Popen([sys.executable, '-c', 'pass'])
    p.wait()
    return p.pid


def rec2(status, **kw):
    """A run record in the v2 shape (schemaVersion 2) from the run record contract."""
    finished = None if status == 'running' else kw.pop('finishedAt', NOW)
    out = {'schemaVersion': 2, 'company': 'acme', 'status': status, 'trigger': 'job',
           'startedAt': kw.pop('startedAt', '2026-10-31T12:50:00Z'), 'finishedAt': finished,
           'pid': kw.pop('pid', 4242), 'jobRanAt': None, 'errorKind': None, 'failureReason': None,
           'nextRetryAt': None, 'partialReason': None, 'skipReason': None,
           'counts': {'sourcesIn': 3, 'signalsOut': 2}, 'currentStep': None,
           'steps': steps() if status != 'running' else steps()[:2]}
    out.update(kw)
    return out


class GateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / 'core/settings').mkdir(parents=True)
        (self.root / 'core/settings/signals.yaml').write_text('briefWaitMinutes: 20\nmaxBudgetUsd: 2.00\n')
        # The gate rules below assume the engine job is on; EngineFlagTest covers it off.
        self.env = mock.patch.dict(os.environ, {bg.ENGINE_FLAG_ENV: 'true'})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def record(self, day, co, rec):
        p = self.root / 'workspace/signals/runs' / day / f'{co}.json'
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(rec))

    def lock(self, co, pid, started_at=NOW, trigger='job'):
        p = self.root / 'workspace/signals/runs' / TODAY / f'{co}.lock'
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps({'pid': pid, 'startedAt': started_at, 'trigger': trigger}))

    def run_gate(self, *extra, now=NOW):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = bg.safe_main(['check', '--hq-root', str(self.root), '--today', TODAY, '--now', now, *extra])
        gate = json.loads((self.root / 'workspace/signals/runs' / TODAY / 'brief-gate.json').read_text())
        return code, gate

    def test_no_record_today_is_waiting_and_nonzero(self):
        code, gate = self.run_gate('--companies', 'acme')
        self.assertNotEqual(code, 0)
        self.assertEqual(gate['state'], 'waiting')
        self.assertFalse((self.root / 'workspace/brief').exists())

    def test_no_record_and_no_scope_is_waiting(self):
        code, gate = self.run_gate()
        self.assertEqual((code, gate['state']), (1, 'waiting'))

    def test_complete_record_is_ready(self):
        self.record(TODAY, 'acme', {'startedAt': NOW, 'finishedAt': NOW, 'steps': steps()})
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state']), (0, 'ready'))

    def test_one_company_missing_is_waiting(self):
        self.record(TODAY, 'acme', {'finishedAt': NOW, 'steps': steps()})
        code, gate = self.run_gate('--companies', 'acme,beta')
        self.assertEqual((code, gate['state']), (1, 'waiting'))
        self.assertIn('beta', gate['reason'])

    def test_v1_running_record_is_running_with_step(self):
        # v1 record (no schemaVersion, lock or pid): live while startedAt is under 3 hours old.
        self.record(TODAY, 'acme', {'startedAt': NOW, 'finishedAt': None, 'currentStep': 'extract', 'steps': steps()[:2]})
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state'], gate['currentStep']), (3, 'running', 'extract'))

    def test_failed_record_writes_failed_with_next_retry(self):
        self.record(TODAY, 'acme', {'finishedAt': NOW, 'steps': steps(failed_at='adapters'),
                                    'errorKind': 'reconnect', 'nextRetryAt': '2026-10-31T13:27:00Z'})
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state']), (2, 'failed'))
        self.assertEqual(gate['nextRetryAt'], '2026-10-31T13:27:00Z')
        self.assertIn('Slack refused', gate['reason'])

    def test_partial_record_with_failed_garden_is_failed(self):
        st = steps()
        st[0].update(status='failed', error='garden failed')
        self.record(TODAY, 'acme', {'finishedAt': NOW, 'status': 'partial', 'steps': st,
                                    'nextRetryAt': '2026-10-31T13:30:00Z'})
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state'], gate['currentStep']), (2, 'failed', 'garden'))
        self.assertEqual(gate['nextRetryAt'], '2026-10-31T13:30:00Z')

    def test_failed_record_without_retry_gets_one(self):
        self.record(TODAY, 'acme', {'finishedAt': NOW, 'steps': steps(failed_at='extract')})
        _, gate = self.run_gate('--companies', 'acme')
        self.assertEqual(gate['nextRetryAt'], '2026-10-31T13:20:00Z')

    def test_wait_timeout_is_failed(self):
        self.record(TODAY, 'acme', rec2('running', pid=os.getpid()))
        self.lock('acme', os.getpid())
        polls = []
        orig, bg.time.sleep = bg.time.sleep, polls.append
        try:
            code, gate = self.run_gate('--companies', 'acme', '--wait', '--poll-seconds', '600')
        finally:
            bg.time.sleep = orig
        self.assertEqual((code, gate['state']), (2, 'failed'))
        self.assertEqual(len(polls), 2)  # 20 minutes of 10-minute polls
        self.assertIn('timed out after 20 minutes', gate['reason'])
        self.assertTrue(gate['nextRetryAt'])

    def test_wait_polls_until_the_run_finishes(self):
        self.record(TODAY, 'acme', rec2('running', pid=os.getpid()))
        self.lock('acme', os.getpid())

        def finish(_seconds):
            (self.root / 'workspace/signals/runs' / TODAY / 'acme.lock').unlink()
            self.record(TODAY, 'acme', rec2('complete'))
        orig, bg.time.sleep = bg.time.sleep, finish
        try:
            code, gate = self.run_gate('--companies', 'acme', '--wait')
        finally:
            bg.time.sleep = orig
        self.assertEqual((code, gate['state']), (0, 'ready'))

    def test_wait_after_run_without_record_is_failed_with_kept_retry(self):
        code, gate = self.run_gate('--companies', 'acme', '--wait', now='2026-10-31T13:05:00Z')
        self.assertEqual((code, gate['state'], gate['nextRetryAt']), (2, 'failed', '2026-10-31T13:20:00Z'))
        code, gate = self.run_gate('--companies', 'acme', now='2026-10-31T13:10:00Z')
        self.assertEqual((code, gate['nextRetryAt']), (2, '2026-10-31T13:20:00Z'))
        code, _ = self.run_gate('--companies', 'acme', now='2026-10-31T13:20:00Z')
        self.assertEqual(code, 1)

    def test_scope_from_summary(self):
        self.record(TODAY, 'summary', {'companies': ['acme'], 'status': 'ok'})
        self.record(TODAY, 'acme', {'finishedAt': NOW, 'steps': steps()})
        code, _ = self.run_gate()
        self.assertEqual(code, 0)

    def test_prefs_off_skip_counts_as_complete(self):
        self.record(TODAY, 'acme', {'finishedAt': NOW, 'steps': [
            {'name': 'garden', 'status': 'skipped', 'skippedReason': 'prefs-off'}]})
        code, _ = self.run_gate('--companies', 'acme')
        self.assertEqual(code, 0)

    def test_summary_folds_yesterday_and_reads_freshness(self):
        ext = {'name': 'extract', 'itemsIn': 41, 'itemsOut': 9, 'status': 'ok', 'estimatedSpendUsd': 0.62}
        ad = {'name': 'adapters', 'status': 'ok', 'byAdapter': {'slack': 13, 'gmail': 22}}
        self.record('2026-10-30', 'acme', {'finishedAt': NOW, 'catchUp': True, 'maxBudgetUsd': 2.0, 'steps': [ad, ext]})
        wm = self.root / 'workspace/signals/watermarks/acme/slack.json'
        wm.parent.mkdir(parents=True)
        wm.write_text(json.dumps({'updatedAt': '2026-10-30T13:01:00Z'}))
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            bg.main(['summary', '--hq-root', str(self.root), '--today', TODAY])
        out = json.loads(buf.getvalue())
        self.assertEqual((out['itemsIn'], out['signalsOut'], out['catchUp'], out['estimatedSpendUsd']), (41, 9, True, 0.62))
        self.assertEqual(out['byAdapter']['gmail'], 22)
        self.assertEqual(out['freshness'][0]['adapter'], 'slack')
        self.assertEqual(out['freshness'][0]['lastSynced'], '2026-10-30T13:01:00Z')

    # C-1: a failed run keeps one retry time and retries on the next poll once it is due.
    def test_failed_retry_time_is_persisted_across_polls(self):
        # A transient failure with no nextRetryAt on the record: the gate's slot is finishedAt + 15 minutes.
        self.record(TODAY, 'acme', rec2('failed', finishedAt='2026-10-31T13:00:00Z', errorKind='transient',
                                        failureReason='Slack timed out.', steps=steps(failed_at='adapters')))
        first = self.run_gate('--companies', 'acme', now='2026-10-31T13:05:00Z')
        second = self.run_gate('--companies', 'acme', now='2026-10-31T13:10:00Z')
        self.assertEqual((first[0], second[0]), (2, 2))
        self.assertEqual(second[1]['nextRetryAt'], first[1]['nextRetryAt'])
        self.assertEqual(first[1]['nextRetryAt'], '2026-10-31T13:15:00Z')
        self.assertEqual(second[1]['nextRetryAt'], '2026-10-31T13:15:00Z')

    def test_second_poll_after_retry_is_due_starts_one_run(self):
        self.record(TODAY, 'acme', rec2('failed', finishedAt='2026-10-31T13:00:00Z', errorKind='transient',
                                        nextRetryAt='2026-10-31T13:15:00Z', steps=steps(failed_at='extract')))
        code, gate = self.run_gate('--companies', 'acme', now='2026-10-31T13:05:00Z')
        self.assertEqual((code, gate['state'], gate['nextRetryAt']), (2, 'failed', '2026-10-31T13:15:00Z'))
        code, gate = self.run_gate('--companies', 'acme', now='2026-10-31T13:16:00Z')
        self.assertEqual(code, 1)
        self.assertEqual(gate['action'], 'start-run')
        # A check that starts no run reads the due slot and leaves it, so the poll after it
        # still asks for the start. The slot is used by the call that starts the run
        # (PremergeReviewTest.test_plain_check_then_start_run_on_a_due_slot_starts_one_run).
        code, gate = self.run_gate('--companies', 'acme', now='2026-10-31T13:17:00Z')
        self.assertEqual((code, gate['action']), (1, 'start-run'))
        self.assertEqual(gate['retries']['acme']['at'], '2026-10-31T13:15:00Z')
        # The start uses the slot: the same failed record is not started again until the next one.
        run = ['--start-run', '--poll-seconds', '0.05', '--run-cmd', json.dumps([sys.executable, '-c', 'pass'])]
        code, gate = self.run_gate('--companies', 'acme', *run, now='2026-10-31T13:17:00Z')
        self.assertEqual((code, gate['state'], gate['nextRetryAt']), (2, 'failed', '2026-10-31T13:32:00Z'))
        code, gate = self.run_gate('--companies', 'acme', now='2026-10-31T13:31:00Z')
        self.assertEqual((code, gate['state'], gate['nextRetryAt']), (2, 'failed', '2026-10-31T13:32:00Z'))
        code, gate = self.run_gate('--companies', 'acme', now='2026-10-31T13:32:00Z')
        self.assertEqual((code, gate['action']), (1, 'start-run'))

    def test_new_failure_gets_its_own_retry_slot(self):
        self.record(TODAY, 'acme', rec2('failed', finishedAt='2026-10-31T13:00:00Z', nextRetryAt='2026-10-31T13:15:00Z',
                                        errorKind='transient', steps=steps(failed_at='extract')))
        self.run_gate('--companies', 'acme', now='2026-10-31T13:16:00Z')
        self.record(TODAY, 'acme', rec2('failed', trigger='brief', startedAt='2026-10-31T13:16:00Z',
                                        finishedAt='2026-10-31T13:18:00Z', nextRetryAt='2026-10-31T13:33:00Z',
                                        errorKind='transient', steps=steps(failed_at='extract')))
        code, gate = self.run_gate('--companies', 'acme', now='2026-10-31T13:19:00Z')
        self.assertEqual((code, gate['nextRetryAt']), (2, '2026-10-31T13:33:00Z'))

    # C-2: a run in progress is waited on, never started a second time.
    def test_running_record_with_live_lock_waits_without_start(self):
        self.record(TODAY, 'acme', rec2('running', pid=os.getpid(), currentStep='extract'))
        self.lock('acme', os.getpid(), started_at='2026-10-31T12:50:00Z')
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual(code, 3)
        self.assertEqual((gate['state'], gate['action']), ('running', 'wait'))
        self.assertEqual(gate['currentStep'], 'extract')

    def test_running_record_with_dead_lock_pid_starts_run(self):
        pid = dead_pid()
        self.record(TODAY, 'acme', rec2('running', pid=pid))
        self.lock('acme', pid, started_at='2026-10-31T12:50:00Z')
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state'], gate['action']), (1, 'waiting', 'start-run'))
        self.assertIn('stale', gate['reason'])

    def test_running_record_with_old_lock_starts_run(self):
        self.record(TODAY, 'acme', rec2('running', pid=os.getpid(), startedAt='2026-10-31T09:00:00Z'))
        self.lock('acme', os.getpid(), started_at='2026-10-31T09:00:00Z')
        code, _ = self.run_gate('--companies', 'acme')
        self.assertEqual(code, 1)

    def test_running_anywhere_waits_before_starting_another(self):
        self.record(TODAY, 'acme', rec2('running', pid=os.getpid()))
        self.lock('acme', os.getpid())
        code, gate = self.run_gate('--companies', 'acme,beta')
        self.assertEqual((code, gate['state']), (3, 'running'))

    def test_no_record_is_start_run(self):
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state'], gate['action']), (1, 'waiting', 'start-run'))

    # Contract readiness rules on v2 records.
    def test_v2_complete_is_ready(self):
        self.record(TODAY, 'acme', rec2('complete'))
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state'], gate['action']), (0, 'ready', 'build'))

    def test_v2_partial_with_step_failure_is_ready(self):
        st = steps()
        st[0].update(status='failed', error='garden failed')
        self.record(TODAY, 'acme', rec2('partial', partialReason='step-failed:garden', steps=st))
        code, _ = self.run_gate('--companies', 'acme')
        self.assertEqual(code, 0)

    def test_late_start_partial_is_not_ready(self):
        self.record(TODAY, 'acme', rec2('partial', partialReason='late-start', jobRanAt=NOW,
                                        steps=[{'name': 'garden', 'status': 'ok', 'itemsIn': 1, 'itemsOut': 0}]))
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual(code, 1)
        self.assertEqual(gate['action'], 'start-run')

    def test_skipped_records_from_the_engine_are_ready(self):
        # hq-cli's engine writes skipReason prefs-off, nothing-to-run, or the first step's skippedReason.
        for reason in ('prefs-off', 'nothing-to-run', 'no-sources'):
            self.record(TODAY, 'acme', rec2('skipped', skipReason=reason, steps=[]))
            code, _ = self.run_gate('--companies', 'acme')
            self.assertEqual(code, 0, reason)

    def test_skipped_late_start_is_not_ready(self):
        self.record(TODAY, 'acme', rec2('skipped', skipReason='late-start', steps=[]))
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['action']), (1, 'start-run'))

    def test_no_scope_after_run_is_failed_with_kept_retry(self):
        code, gate = self.run_gate('--wait', now='2026-10-31T13:05:00Z')
        self.assertEqual((code, gate['state'], gate['nextRetryAt']), (2, 'failed', '2026-10-31T13:20:00Z'))
        code, gate = self.run_gate(now='2026-10-31T13:10:00Z')
        self.assertEqual((code, gate['nextRetryAt']), (2, '2026-10-31T13:20:00Z'))
        code, gate = self.run_gate(now='2026-10-31T13:20:00Z')
        self.assertEqual((code, gate['action']), (1, 'start-run'))

    def test_v2_failed_carries_failure_reason(self):
        fields = {'errorKind': 'auth'}
        fields['failureReason'] = 'You are signed out of HQ.'
        self.record(TODAY, 'acme', rec2('failed', steps=steps(failed_at='adapters'), **fields))
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state'], gate['errorKind']), (2, 'failed', 'auth'))
        self.assertIn('signed out', gate['reason'])

    def test_summary_aggregates_each_company_budget(self):
        for co in ('acme', 'beta'):
            self.record('2026-10-30', co, rec2('complete', maxBudgetUsd=2,
                steps=[{'name': 'extract', 'status': 'ok', 'estimatedSpendUsd': 1.5}]))
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            bg.main(['summary', '--hq-root', str(self.root), '--today', TODAY])
        summary = json.loads(buf.getvalue())
        self.assertEqual(summary['estimatedSpendUsd'], 3)
        self.assertEqual(summary['maxBudgetUsd'], 4)

    def test_summary_scope_skips_gate_and_brief_run_files(self):
        self.record('2026-10-30', 'acme', rec2('complete'))
        self.record('2026-10-30', 'brief-run', {'status': 'running', 'startedAt': NOW, 'trigger': 'brief'})
        self.record('2026-10-30', 'brief-gate', {'state': 'ready'})
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            bg.main(['summary', '--hq-root', str(self.root), '--today', TODAY])
        self.assertEqual(json.loads(buf.getvalue())['companies'], ['acme'])

    def test_settings_parsed(self):
        s = bg.load_settings(self.root)
        self.assertEqual((s['briefWaitMinutes'], s['maxBudgetUsd'], s['maxTurns']), (20, 2.0, 40))


def fake_run(root, body):
    """A stand-in for `hq signals run --trigger brief --json`: a python snippet run as a subprocess."""
    return json.dumps([sys.executable, '-c', body, str(root)])


WRITE_RECORD = (
    "import json, sys, pathlib\n"
    "d = pathlib.Path(sys.argv[1]) / 'workspace/signals/runs/" + TODAY + "'\n"
    "d.mkdir(parents=True, exist_ok=True)\n"
    "(d / 'acme.json').write_text(json.dumps(REC))\n"
    "print(json.dumps({'status': REC['status']}))\n"
)


def touch(marker):
    return f"import pathlib; pathlib.Path({str(marker)!r}).write_text('x')"


class StartRunTest(unittest.TestCase):
    """check --start-run starts one run, waits within briefWaitMinutes, and never blocks past it."""

    record = GateTest.record
    lock = GateTest.lock
    run_gate = GateTest.run_gate

    def setUp(self):
        GateTest.setUp(self)

    def tearDown(self):
        GateTest.tearDown(self)

    def start(self, body, *extra, now=NOW):
        return self.run_gate('--companies', 'acme', '--start-run', '--poll-seconds', '0.05',
                             '--run-cmd', fake_run(self.root, body), *extra, now=now)

    def runs(self):
        return self.root / 'workspace/signals/runs' / TODAY

    def test_starts_the_run_and_is_ready_when_it_completes(self):
        body = 'REC = ' + repr(rec2('complete', trigger='brief')) + '\n' + WRITE_RECORD
        code, gate = self.start(body)
        self.assertEqual((code, gate['state'], gate['action']), (0, 'ready', 'build'))
        [out] = gate['runOutput']
        self.assertTrue(out.startswith('workspace/signals/runs/2026-10-31/brief-runs/acme-'))
        self.assertEqual(json.loads((self.root / out).read_text()), {'status': 'complete'})

    def test_failed_run_is_failed_with_reason_and_retry(self):
        rec = rec2('failed', trigger='brief', finishedAt='2026-10-31T13:04:00Z', errorKind='transient',
                   failureReason='The extract step failed: model refused.', nextRetryAt='2026-10-31T13:19:00Z',
                   steps=steps(failed_at='extract'))
        body = 'REC = ' + repr(rec) + '\n' + WRITE_RECORD + 'sys.exit(1)\n'
        code, gate = self.start(body)
        self.assertEqual((code, gate['state'], gate['nextRetryAt']), (2, 'failed', '2026-10-31T13:19:00Z'))
        self.assertIn('model refused', gate['reason'])
        self.assertFalse((self.root / 'workspace/brief').exists())

    def test_run_that_writes_nothing_is_failed(self):
        code, gate = self.start('pass')
        self.assertEqual((code, gate['state'], gate['nextRetryAt']), (2, 'failed', '2026-10-31T13:20:00Z'))
        self.assertIn('without a finished record', gate['reason'])

    def test_usage_error_is_failed_with_the_message(self):
        code, gate = self.start("import sys; sys.stderr.write('error: invalid company slug\\n'); sys.exit(2)")
        self.assertEqual((code, gate['state']), (2, 'failed'))
        self.assertIn('invalid company slug', gate['reason'])

    def test_missing_command_is_failed_not_a_crash(self):
        code, gate = self.run_gate('--companies', 'acme', '--start-run',
                                   '--run-cmd', json.dumps(['/nonexistent/hq-not-installed']))
        self.assertEqual((code, gate['state']), (2, 'failed'))
        self.assertIn('could not start hq signals run', gate['reason'])

    def test_slow_run_times_out_and_is_left_running(self):
        marker = self.root / 'still-running'
        body = touch(marker) + '; import time; time.sleep(30)'
        t0 = time.monotonic()
        code, gate = self.start(body, '--wait-seconds', '0.5')
        self.assertLess(time.monotonic() - t0, 10)
        self.assertEqual((code, gate['state']), (2, 'failed'))
        self.assertIn('timed out after 20 minutes', gate['reason'])
        self.assertTrue(gate['nextRetryAt'])
        for _ in range(100):
            if marker.exists():
                break
            time.sleep(0.05)
        self.assertTrue(marker.exists())  # the run started
        pid = gate['runPids']['acme']
        self.assertTrue(bg.pid_alive(pid))  # and the time limit did not kill it
        os.kill(pid, signal.SIGTERM)

    def test_ready_gate_starts_nothing(self):
        marker = self.root / 'ran'
        self.record(TODAY, 'acme', rec2('complete'))
        code, _ = self.start(touch(marker))
        self.assertEqual(code, 0)
        self.assertFalse(marker.exists())

    def test_failed_gate_before_retry_starts_nothing(self):
        marker = self.root / 'ran'
        self.record(TODAY, 'acme', rec2('failed', finishedAt='2026-10-31T13:00:00Z', errorKind='transient',
                                        nextRetryAt='2026-10-31T13:15:00Z', steps=steps(failed_at='extract')))
        code, _ = self.start(touch(marker))
        self.assertEqual(code, 2)
        self.assertFalse(marker.exists())

    def test_engine_off_starts_nothing_and_builds(self):
        marker = self.root / 'ran'
        with mock.patch.dict(os.environ, {bg.ENGINE_FLAG_ENV: 'false'}):
            code, gate = self.start(touch(marker))
        self.assertEqual((code, gate['state'], gate['action']), (0, 'off', 'build'))
        self.assertFalse(marker.exists())


class ReviewFixTest(unittest.TestCase):
    """Engine-on fixes from the independent review of the first version."""

    record = GateTest.record
    lock = GateTest.lock
    run_gate = GateTest.run_gate
    start = StartRunTest.start
    runs = StartRunTest.runs

    def setUp(self):
        GateTest.setUp(self)

    def tearDown(self):
        GateTest.tearDown(self)

    def started(self):
        d = self.runs() / bg.RUN_OUTPUT_DIR
        return sorted(p.name for p in d.glob('*.json')) if d.is_dir() else []

    def wait_dead(self, pid):
        for _ in range(200):
            # The run is a child of this test process, so reap it; a real brief check has exited
            # by the next poll and the run is reaped by the system.
            try:
                os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                pass
            if not bg.pid_alive(pid):
                return
            time.sleep(0.05)
        self.fail(f'pid {pid} still alive')

    # Extract or adapters failed: the run produced no fresh signals, so it is not ready.
    def test_partial_with_failed_extract_or_adapters_is_failed(self):
        for name in ('extract', 'adapters'):
            st = steps(failed_at=name)
            self.record(TODAY, 'acme', rec2('partial', partialReason=f'step-failed:{name}', errorKind='transient',
                                            failureReason=f'The {name} step failed: boom.', steps=st,
                                            finishedAt='2026-10-31T13:00:00Z'))
            code, gate = self.run_gate('--companies', 'acme')
            self.assertEqual((code, gate['state'], gate['nextRetryAt']), (2, 'failed', '2026-10-31T13:15:00Z'), name)
            self.assertIn('boom', gate['reason'])

    def test_partial_with_failed_garden_is_still_ready(self):
        st = steps()
        st[0].update(status='failed')
        self.record(TODAY, 'acme', rec2('partial', partialReason='step-failed:garden', steps=st))
        self.assertEqual(self.run_gate('--companies', 'acme')[0], 0)

    # config and auth failures: the engine sets no retry, so neither does the gate.
    def test_config_or_auth_failure_waits_for_the_person(self):
        for kind in ('config', 'auth'):
            self.record(TODAY, 'acme', rec2('failed', errorKind=kind, finishedAt='2026-10-31T06:31:00Z',
                                            failureReason='You are signed out of HQ.', steps=steps(failed_at='adapters')))
            for now in ('2026-10-31T06:35:00Z', '2026-10-31T08:00:00Z', '2026-10-31T13:00:00Z'):
                code, gate = self.run_gate('--companies', 'acme', now=now)
                self.assertEqual((code, gate['state'], gate['retry'], gate['nextRetryAt']),
                                 (2, 'failed', 'manual', None), (kind, now))

    def test_config_failure_starts_no_run(self):
        marker = self.root / 'ran'
        self.record(TODAY, 'acme', rec2('failed', errorKind='config', finishedAt='2026-10-31T06:31:00Z',
                                        steps=steps(failed_at='adapters')))
        code, _ = self.start(touch(marker))
        self.assertEqual(code, 2)
        self.assertFalse(marker.exists())

    def test_new_record_after_try_now_is_judged_again(self):
        self.record(TODAY, 'acme', rec2('failed', errorKind='auth', finishedAt='2026-10-31T06:31:00Z',
                                        steps=steps(failed_at='adapters')))
        self.run_gate('--companies', 'acme')
        self.record(TODAY, 'acme', rec2('complete', trigger='chat'))
        self.assertEqual(self.run_gate('--companies', 'acme')[0], 0)

    # Short calls: --max-seconds returns while the run goes on; the limit spans calls.
    def test_max_seconds_returns_running_and_the_next_call_starts_nothing(self):
        body = 'import time; time.sleep(30)'
        code, gate = self.start(body, '--max-seconds', '0.1')
        self.assertEqual((code, gate['state']), (3, 'running'))
        pid = gate['runPids']['acme']
        try:
            self.assertEqual(gate['waitStartedAt'], '2026-10-31T13:05:00Z')
            # A caller polling every few minutes keeps the same wait.
            for now in ('2026-10-31T13:09:00Z', '2026-10-31T13:13:00Z', '2026-10-31T13:17:00Z',
                        '2026-10-31T13:21:00Z'):
                code, gate = self.start(body, '--max-seconds', '0.1', now=now)
                self.assertEqual((code, gate['state']), (3, 'running'), now)
                self.assertEqual(gate['waitStartedAt'], '2026-10-31T13:05:00Z')
            self.assertEqual(len(self.started()), 1)
            # 20 minutes after the wait began: past the limit counted across calls.
            code, gate = self.start(body, '--max-seconds', '0.1', now='2026-10-31T13:25:00Z')
            self.assertEqual((code, gate['state']), (2, 'failed'))
            self.assertIn('timed out after 20 minutes', gate['reason'])
            self.assertEqual(len(self.started()), 1)
        finally:
            os.kill(pid, signal.SIGTERM)

    def test_earlier_call_run_that_ended_without_record_is_failed_not_restarted(self):
        code, gate = self.start('import time; time.sleep(0.4)', '--max-seconds', '0.05')
        self.assertEqual(code, 3)
        self.wait_dead(gate['runPids']['acme'])
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state']), (2, 'failed'))
        self.assertIn('without a finished record', gate['reason'])
        code, _ = self.start('pass', now='2026-10-31T13:06:00Z')
        self.assertEqual(code, 2)
        self.assertEqual(len(self.started()), 1)

    # The brief's run covers only the companies that need one.
    def test_run_passes_company_for_each_waiting_company(self):
        log = self.root / 'argv.log'
        body = f"import sys; open({str(log)!r}, 'a').write(' '.join(sys.argv[2:]) + '\\n')"
        self.record(TODAY, 'beta', rec2('complete', company='beta'))
        self.run_gate('--companies', 'acme,beta,gamma', '--start-run', '--poll-seconds', '0.05',
                      '--run-cmd', fake_run(self.root, body))
        self.assertEqual(sorted(log.read_text().split('\n')[:-1]), ['--company acme', '--company gamma'])

    def test_default_command_names_the_company_and_resolves_hq(self):
        a = bg.argparse.Namespace(run_cmd=None, hq_root='/r')
        with mock.patch.object(bg.shutil, 'which', return_value='C:\\npm\\hq.cmd'):
            cmd = bg.run_command(a, 'acme')
        self.assertEqual(cmd, ['C:\\npm\\hq.cmd', 'signals', 'run', '--trigger', 'brief', '--json',
                               '--hq-root', '/r', '--company', 'acme'])

    def test_each_start_gets_its_own_output_files(self):
        body = 'REC = ' + repr(rec2('failed', trigger='brief', errorKind='transient', finishedAt=NOW,
                                    steps=steps(failed_at='extract'))) + '\n' + WRITE_RECORD
        self.start(body)
        self.start(body, now='2026-10-31T13:25:00Z')  # the retry slot (13:20) is due
        self.assertEqual(len(self.started()), 2)

    # A live lock means a run is going, whatever the last record says.
    def test_failed_record_with_live_lock_is_running(self):
        self.record(TODAY, 'acme', rec2('failed', errorKind='transient', finishedAt='2026-10-31T12:00:00Z',
                                        steps=steps(failed_at='extract')))
        self.lock('acme', os.getpid(), started_at='2026-10-31T13:00:00Z')
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state']), (3, 'running'))

    # Windows: no os.kill(pid, 0) probe.
    def test_windows_liveness_does_not_use_os_kill(self):
        with mock.patch.object(bg.os, 'name', 'nt'), \
                mock.patch.object(bg, '_win_pid_alive', return_value=True) as probe, \
                mock.patch.object(bg.os, 'kill', side_effect=AssertionError('os.kill used')):
            self.assertTrue(bg.pid_alive(4242))
        probe.assert_called_once_with(4242)

    # Incremental passes rewrite the record with extract only.
    def test_incremental_record_without_job_run_asks_for_a_full_run(self):
        self.record(TODAY, 'acme', rec2('complete', trigger='chat', steps=[
            {'name': 'extract', 'status': 'ok', 'itemsIn': 1, 'itemsOut': 1, 'durationMs': 5}]))
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['action']), (1, 'start-run'))
        self.assertIn('incremental', gate['reason'])

    def test_incremental_record_after_a_job_run_is_ready(self):
        self.record(TODAY, 'acme', rec2('complete', trigger='chat', jobRanAt='2026-10-31T06:40:00Z', steps=[
            {'name': 'extract', 'status': 'ok', 'itemsIn': 1, 'itemsOut': 1, 'durationMs': 5}]))
        self.assertEqual(self.run_gate('--companies', 'acme')[0], 0)


def steps_adapters_failed(extract_status='ok'):
    out = []
    for name in ('garden', 'adapters', 'extract', 'garden', 'upload'):
        s = {'name': name, 'itemsIn': 3, 'itemsOut': 2, 'durationMs': 10, 'status': 'ok'}
        if name == 'adapters':
            s.update(status='failed', error='Slack needs to be reconnected', errorKind='reconnect')
        if name == 'extract':
            s['status'] = extract_status
        out.append(s)
    return out


class RoundTwoTest(unittest.TestCase):
    """Fail-open errors, stale waits, adapters-only failures, Try now, Windows flags."""

    record = GateTest.record
    lock = GateTest.lock
    run_gate = GateTest.run_gate
    start = StartRunTest.start
    runs = StartRunTest.runs
    started = ReviewFixTest.started

    def setUp(self):
        GateTest.setUp(self)

    def tearDown(self):
        GateTest.tearDown(self)

    def gate_file(self):
        return json.loads((self.runs() / 'brief-gate.json').read_text())

    def write_prev_gate(self, **kw):
        self.runs().mkdir(parents=True, exist_ok=True)
        (self.runs() / 'brief-gate.json').write_text(json.dumps(dict(state='running', **kw)))

    # (1) The gate fails open: an error in the script builds the brief, never holds it.
    def test_unexpected_error_exits_4_and_records_error(self):
        with mock.patch.object(bg, 'decide', side_effect=RuntimeError('boom')):
            code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state'], gate['action']), (4, 'error', 'build'))
        self.assertIn('boom', gate['reason'])

    def test_usage_error_exits_4(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
            code = bg.safe_main(['check', '--hq-root', str(self.root), '--today', TODAY, '--max-seconds', 'x'])
        self.assertEqual((code, json.loads(buf.getvalue())['state']), (4, 'error'))

    def test_unwritable_run_folder_with_flag_off_exits_4_from_the_real_entry(self):
        blocker = self.root / 'not-a-folder'
        blocker.write_text('x')
        env = dict(os.environ, **{bg.ENGINE_FLAG_ENV: 'false'})
        r = subprocess.run([sys.executable, '-I', str(HERE / 'brief_gate.py'), 'check', '--hq-root', str(blocker),
                            '--today', TODAY], capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 4, r.stderr)
        self.assertEqual(json.loads(r.stdout)['state'], 'error')

    # (2) A wait left by an abandoned call does not make a later pass time out at once.
    def test_abandoned_wait_starts_fresh(self):
        self.write_prev_gate(waitStartedAt='2026-10-31T07:00:00Z', checkedAt='2026-10-31T07:05:00Z', runPids={})
        body = 'REC = ' + repr(rec2('complete', trigger='brief')) + '\n' + WRITE_RECORD
        code, gate = self.start(body, now='2026-10-31T13:00:00Z')
        self.assertEqual((code, gate['state']), (0, 'ready'))

    def test_wait_with_no_live_run_restarts_the_clock(self):
        self.write_prev_gate(waitStartedAt='2026-10-31T12:40:00Z', checkedAt='2026-10-31T13:04:00Z', runPids={})
        code, gate = self.start('import time; time.sleep(30)', '--max-seconds', '0.1')
        try:
            self.assertEqual((code, gate['state'], gate['waitStartedAt']), (3, 'running', '2026-10-31T13:05:00Z'))
        finally:
            for pid in gate.get('runPids', {}).values():
                os.kill(pid, signal.SIGTERM)

    def test_wait_on_a_live_lock_keeps_its_clock(self):
        self.record(TODAY, 'acme', rec2('running', pid=os.getpid()))
        self.lock('acme', os.getpid(), started_at='2026-10-31T12:50:00Z')
        self.write_prev_gate(waitStartedAt='2026-10-31T12:46:00Z', checkedAt='2026-10-31T13:04:00Z', runPids={})
        code, gate = self.start('pass', '--max-seconds', '0.1')
        self.assertEqual((code, gate['waitStartedAt']), (3, '2026-10-31T12:46:00Z'))

    # (3) Adapters failed but extract finished: signals are fresh for what synced.
    def test_adapters_failed_with_extract_ok_is_ready_with_a_warning(self):
        for kind in ('transient', 'auth'):
            self.record(TODAY, 'acme', rec2('partial', partialReason='step-failed:adapters', errorKind=kind,
                                            failureReason='The adapters step failed: Slack needs to be reconnected.',
                                            steps=steps_adapters_failed()))
            code, gate = self.run_gate('--companies', 'acme')
            self.assertEqual((code, gate['state']), (0, 'ready'), kind)
            self.assertEqual(gate['warnings'], ['acme: The adapters step failed: Slack needs to be reconnected.'])

    def test_adapters_failed_and_extract_failed_is_failed(self):
        self.record(TODAY, 'acme', rec2('partial', partialReason='step-failed:adapters', errorKind='transient',
                                        finishedAt='2026-10-31T13:00:00Z', steps=steps_adapters_failed('failed')))
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state']), (2, 'failed'))

    # (4) Try now reuses the chunked start path, for the failed companies only.
    def test_retry_now_starts_only_failed_companies_in_short_calls(self):
        log = self.root / 'argv.log'
        body = f"import sys; open({str(log)!r}, 'a').write(' '.join(sys.argv[2:]) + '\\n')"
        self.record(TODAY, 'acme', rec2('failed', errorKind='auth', finishedAt='2026-10-31T06:31:00Z',
                                        steps=steps(failed_at='adapters')))
        self.record(TODAY, 'beta', rec2('complete', company='beta'))
        self.run_gate('--companies', 'acme,beta', '--start-run', '--poll-seconds', '0.05',
                      '--run-cmd', fake_run(self.root, body))
        self.assertFalse(log.exists())  # manual: no run without Try now
        self.run_gate('--companies', 'acme,beta', '--start-run', '--retry-now', '--max-seconds', '90',
                      '--poll-seconds', '0.05', '--run-cmd', fake_run(self.root, body))
        self.assertEqual(log.read_text(), '--company acme\n')

    # (5) Windows: no console window for the run, still in its own process group.
    def test_windows_run_has_no_console_window(self):
        with mock.patch.object(bg.os, 'name', 'nt'), mock.patch.object(bg.subprocess, 'Popen') as popen:
            bg.popen_detached(['hq'], cwd='.')
        flags = popen.call_args.kwargs['creationflags']
        self.assertTrue(flags & bg.CREATE_NO_WINDOW)
        self.assertTrue(flags & bg.CREATE_NEW_PROCESS_GROUP)
        self.assertFalse(flags & 0x00000008)  # DETACHED_PROCESS would make Windows ignore CREATE_NO_WINDOW
        self.assertNotIn('start_new_session', popen.call_args.kwargs)

    def test_windows_falls_back_when_the_job_refuses_breakaway(self):
        with mock.patch.object(bg.os, 'name', 'nt'), \
                mock.patch.object(bg.subprocess, 'Popen', side_effect=[PermissionError(5, 'denied'), 'proc']) as popen:
            self.assertEqual(bg.popen_detached(['hq']), 'proc')
        self.assertTrue(popen.call_args_list[0].kwargs['creationflags'] & bg.CREATE_BREAKAWAY_FROM_JOB)
        self.assertFalse(popen.call_args_list[1].kwargs['creationflags'] & bg.CREATE_BREAKAWAY_FROM_JOB)


class RoundThreeTest(unittest.TestCase):
    """The Step 0 probe never resets retry slots; Try now restarts failed companies only; --today is checked."""

    record = GateTest.record
    run_gate = GateTest.run_gate
    start = StartRunTest.start
    runs = StartRunTest.runs
    started = ReviewFixTest.started
    gate_file = RoundTwoTest.gate_file

    def setUp(self):
        GateTest.setUp(self)

    def tearDown(self):
        GateTest.tearDown(self)

    def fail_once(self):
        """A brief run that writes no record: failed with a retry slot at 13:20."""
        code, gate = self.start('pass')
        self.assertEqual((code, gate['state'], gate['nextRetryAt']), (2, 'failed', '2026-10-31T13:20:00Z'))
        self.assertEqual(len(self.started()), 1)

    def test_check_without_companies_keeps_slots_and_the_failed_state(self):
        self.fail_once()
        # A call with no company list and no summary.json (the earlier Step 0 probe).
        code, gate = self.run_gate(now='2026-10-31T13:06:00Z')
        self.assertEqual((code, gate['state'], gate['nextRetryAt']), (2, 'failed', '2026-10-31T13:20:00Z'))
        code, gate = self.start('pass', now='2026-10-31T13:07:00Z')
        self.assertEqual((code, gate['state'], gate['nextRetryAt']), (2, 'failed', '2026-10-31T13:20:00Z'))
        self.assertEqual(len(self.started()), 1)  # no second paid run before the retry time

    def test_engine_probe_writes_nothing(self):
        self.fail_once()
        before = (self.runs() / 'brief-gate.json').read_bytes()
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = bg.safe_main(['engine', '--hq-root', str(self.root), '--today', TODAY, '--now', NOW])
        self.assertEqual((code, json.loads(buf.getvalue())['on']), (0, True))
        self.assertEqual((self.runs() / 'brief-gate.json').read_bytes(), before)
        code, gate = self.start('pass', now='2026-10-31T13:07:00Z')
        self.assertEqual((code, len(self.started())), (2, 1))

    def test_a_company_brief_keeps_other_companies_slots(self):
        self.fail_once()
        self.record(TODAY, 'beta', rec2('complete', company='beta'))
        self.run_gate('--companies', 'beta', now='2026-10-31T13:06:00Z')
        self.assertEqual(self.gate_file()['retries']['acme']['at'], '2026-10-31T13:20:00Z')
        code, _ = self.start('pass', now='2026-10-31T13:07:00Z')
        self.assertEqual((code, len(self.started())), (2, 1))

    def test_retry_now_leaves_waiting_companies_alone(self):
        log = self.root / 'argv.log'
        body = f"import sys; open({str(log)!r}, 'a').write(' '.join(sys.argv[2:]) + '\\n')"
        self.record(TODAY, 'acme', rec2('failed', errorKind='auth', finishedAt='2026-10-31T06:31:00Z',
                                        steps=steps(failed_at='adapters')))
        code, gate = self.run_gate('--companies', 'acme,beta', '--start-run', '--retry-now', '--max-seconds', '90',
                                   '--poll-seconds', '0.05', '--run-cmd', fake_run(self.root, body))
        self.assertEqual(log.read_text(), '--company acme\n')
        self.assertEqual(gate['companies']['beta']['state'], 'waiting')
        self.assertEqual(gate['companies']['beta']['reason'], 'no run record yet')

    def test_retry_now_with_nothing_failed_starts_nothing(self):
        marker = self.root / 'ran'
        code, gate = self.run_gate('--companies', 'acme', '--start-run', '--retry-now', '--poll-seconds', '0.05',
                                   '--run-cmd', fake_run(self.root, touch(marker)))
        self.assertEqual((code, gate['state']), (1, 'waiting'))
        self.assertFalse(marker.exists())

    def test_bad_today_exits_4_and_writes_nowhere(self):
        for bad in ('garbage', '../x', '2026-13-01', '2026-10-31\n', '2026-1-31'):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = bg.safe_main(['check', '--hq-root', str(self.root), '--today', bad])
            self.assertEqual((code, json.loads(buf.getvalue())['state']), (4, 'error'), bad)
        self.assertFalse((self.root / 'workspace').exists())

    def test_broken_settings_do_not_touch_the_off_path(self):
        (self.root / 'core/settings/signals.yaml').write_text('briefWaitMinutes: 1.2.3\n')
        with mock.patch.dict(os.environ, {bg.ENGINE_FLAG_ENV: 'false'}):
            code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state']), (0, 'off'))


class RoundFourTest(unittest.TestCase):
    """Try now for failures with no record, error passes keep the scope, flag off replaces a stale gate."""

    record = GateTest.record
    run_gate = GateTest.run_gate
    start = StartRunTest.start
    runs = StartRunTest.runs
    started = ReviewFixTest.started
    gate_file = RoundTwoTest.gate_file
    fail_once = RoundThreeTest.fail_once

    def setUp(self):
        GateTest.setUp(self)

    def tearDown(self):
        GateTest.tearDown(self)

    def retry_now(self, body, *extra, now='2026-10-31T13:06:00Z'):
        return self.run_gate(*extra, '--start-run', '--retry-now', '--max-seconds', '90', '--poll-seconds', '0.05',
                             '--run-cmd', fake_run(self.root, body), now=now)

    def engine(self, now=NOW):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = bg.safe_main(['engine', '--hq-root', str(self.root), '--today', TODAY, '--now', now])
        return code, json.loads(buf.getvalue())

    # (1) Try now starts a run for a company that failed without writing a record.
    def test_retry_now_restarts_a_run_that_wrote_no_record(self):
        self.fail_once()
        code, gate = self.retry_now('pass', '--companies', 'acme')
        self.assertEqual(len(self.started()), 2)
        self.assertEqual((code, gate['state'], gate['nextRetryAt']), (2, 'failed', '2026-10-31T13:21:00Z'))
        # The next poll before the new slot starts nothing.
        code, gate = self.start('pass', now='2026-10-31T13:07:00Z')
        self.assertEqual((code, len(self.started())), (2, 2))

    def test_retry_now_restarts_a_run_that_refused_to_start(self):
        code, gate = self.start("import sys; sys.stderr.write('error: bad flag\\n'); sys.exit(2)")
        self.assertEqual((code, gate['state']), (2, 'failed'))
        self.retry_now('pass', '--companies', 'acme')
        self.assertEqual(len(self.started()), 2)

    def test_retry_now_starts_a_run_that_could_not_be_started(self):
        missing = json.dumps(['/nonexistent/hq-not-installed'])
        code, gate = self.run_gate('--companies', 'acme', '--start-run', '--run-cmd', missing)
        self.assertEqual((code, gate['state'], gate['companies']['acme']['state']), (2, 'failed', 'failed'))
        self.assertEqual(gate['retries']['acme']['at'], '2026-10-31T13:20:00Z')
        # An ordinary poll before the retry time starts nothing.
        marker = self.root / 'ran'
        code, _ = self.start(touch(marker), now='2026-10-31T13:06:00Z')
        self.assertEqual(code, 2)
        self.assertFalse(marker.exists())
        self.retry_now(touch(marker), '--companies', 'acme', now='2026-10-31T13:07:00Z')
        self.assertTrue(marker.exists())

    def test_retry_now_restarts_a_run_for_every_company_with_no_list(self):
        log = self.root / 'argv.log'
        body = f"import sys; open({str(log)!r}, 'a').write(repr(sys.argv[2:]) + '\\n')"
        code, gate = self.run_gate('--start-run', '--poll-seconds', '0.05', '--run-cmd', fake_run(self.root, body))
        self.assertEqual((code, gate['state']), (2, 'failed'))
        self.retry_now(body)
        self.assertEqual(log.read_text(), '[]\n[]\n')  # two runs, neither names a company
        code, gate = self.run_gate('--start-run', '--poll-seconds', '0.05', '--run-cmd', fake_run(self.root, body),
                                   now='2026-10-31T13:07:00Z')
        self.assertEqual((code, log.read_text().count('\n')), (2, 2))

    # (2) After the gate errors, a call with no list keeps the scope and starts no run for a manual failure.
    def test_error_pass_keeps_the_scope_and_the_manual_failure(self):
        self.record(TODAY, 'acme', rec2('failed', errorKind='auth', finishedAt='2026-10-31T06:31:00Z',
                                        steps=steps(failed_at='adapters')))
        self.assertEqual(self.run_gate('--companies', 'acme')[1]['retry'], 'manual')
        with mock.patch.object(bg, 'decide', side_effect=RuntimeError('boom')):
            code, gate = self.run_gate(now='2026-10-31T13:06:00Z')
        self.assertEqual((code, list(gate['companies'])), (4, ['acme']))
        marker = self.root / 'ran'
        code, gate = self.run_gate('--start-run', '--poll-seconds', '0.05',
                                   '--run-cmd', fake_run(self.root, touch(marker)), now='2026-10-31T13:07:00Z')
        self.assertEqual((code, gate['state'], gate['retry']), (2, 'failed', 'manual'))
        self.assertFalse(marker.exists())

    def test_no_list_and_no_gate_judges_the_companies_with_records(self):
        self.record(TODAY, 'acme', rec2('failed', errorKind='config', finishedAt='2026-10-31T06:31:00Z',
                                        steps=steps(failed_at='adapters')))
        marker = self.root / 'ran'
        code, gate = self.run_gate('--start-run', '--poll-seconds', '0.05',
                                   '--run-cmd', fake_run(self.root, touch(marker)))
        self.assertEqual((code, gate['retry'], list(gate['companies'])), (2, 'manual', ['acme']))
        self.assertFalse(marker.exists())

    # (3) Flag off: the read-only probe replaces a stale same-day gate once, and otherwise writes nothing.
    def test_engine_off_replaces_a_stale_gate_once(self):
        self.fail_once()
        with mock.patch.dict(os.environ, {bg.ENGINE_FLAG_ENV: 'false'}):
            code, out = self.engine(now='2026-10-31T13:06:00Z')
            self.assertEqual((code, out['on']), (0, False))
            gate = self.gate_file()
            self.assertEqual((gate['state'], gate['action'], list(gate['companies'])), ('off', 'build', ['acme']))
            self.assertEqual(gate['retries']['acme']['at'], '2026-10-31T13:20:00Z')  # kept for a later flag-on
            before = (self.runs() / 'brief-gate.json').read_bytes()
            self.engine(now='2026-10-31T13:30:00Z')
            self.assertEqual((self.runs() / 'brief-gate.json').read_bytes(), before)

    def test_engine_off_with_no_gate_file_writes_nothing(self):
        with mock.patch.dict(os.environ, {bg.ENGINE_FLAG_ENV: 'false'}):
            self.assertEqual(self.engine()[1]['on'], False)
        self.assertFalse((self.root / 'workspace').exists())

    # Review of the engine-on fixes.
    # (a) A wait another session is still polling is not replaced by the probe.
    def test_engine_off_leaves_a_recent_running_gate_alone(self):
        self.runs().mkdir(parents=True, exist_ok=True)
        (self.runs() / 'brief-gate.json').write_text(json.dumps(
            {'state': 'running', 'today': TODAY, 'checkedAt': '2026-10-31T13:03:00Z', 'companies': {},
             'runPids': {'acme': 4242}, 'waitStartedAt': '2026-10-31T13:01:00Z', 'retries': {}}))
        before = (self.runs() / 'brief-gate.json').read_bytes()
        with mock.patch.dict(os.environ, {bg.ENGINE_FLAG_ENV: 'false'}):
            self.engine(now='2026-10-31T13:05:00Z')
            self.assertEqual((self.runs() / 'brief-gate.json').read_bytes(), before)
            # Past the abandon time nobody is polling it, so it is replaced.
            self.engine(now='2026-10-31T13:09:00Z')
        self.assertEqual(self.gate_file()['state'], 'off')

    # (b) Two writers never share a temp file.
    def test_concurrent_gate_writers_do_not_collide(self):
        real_replace = os.replace
        calls = []

        def replace(src, dst):
            calls.append(str(src))
            if len(calls) == 1:
                # A second writer finishes between the first writer's write and its rename.
                bg.write_gate(self.root, TODAY, {'state': 'off', 'writer': 'second'})
            return real_replace(src, dst)

        with mock.patch('os.replace', side_effect=replace):
            bg.write_gate(self.root, TODAY, {'state': 'failed', 'writer': 'first'})
        self.assertNotEqual(calls[0], calls[1])
        self.assertEqual(self.gate_file()['writer'], 'first')
        self.assertEqual(sorted(p.name for p in self.runs().iterdir()), ['brief-gate.json'])

    # (c) An off gate keeps the company list, so a failure with no record stays in scope.
    def test_off_gate_keeps_a_no_record_failure_in_scope_for_a_later_flag_on(self):
        self.fail_once()
        with mock.patch.dict(os.environ, {bg.ENGINE_FLAG_ENV: 'false'}):
            self.engine(now='2026-10-31T13:06:00Z')
            code, gate = self.run_gate(now='2026-10-31T13:06:30Z')  # the check off path keeps it too
        self.assertEqual((code, gate['state'], list(gate['companies'])), (0, 'off', ['acme']))
        # The engine is on again; a call with no list keeps acme and its 13:20 slot.
        code, gate = self.run_gate('--start-run', '--poll-seconds', '0.05', '--run-cmd', fake_run(self.root, 'pass'),
                                   now='2026-10-31T13:07:00Z')
        self.assertEqual((code, gate['state'], gate['nextRetryAt']), (2, 'failed', '2026-10-31T13:20:00Z'))
        self.assertEqual(len(self.started()), 1)


class EngineOffAfterFlagOffTest(unittest.TestCase):
    """Yesterday's job record turns the gate on only until today's job time has passed."""

    record = GateTest.record
    run_gate = GateTest.run_gate

    def setUp(self):
        GateTest.setUp(self)
        os.environ.pop(bg.ENGINE_FLAG_ENV, None)
        self.record('2026-10-30', 'acme', rec2('complete', startedAt='2026-10-30T06:30:00Z',
                                                jobRanAt='2026-10-30T06:40:00Z'))

    def tearDown(self):
        GateTest.tearDown(self)

    def test_before_todays_job_time_the_gate_is_on(self):
        code, gate = self.run_gate('--companies', 'acme', now='2026-10-31T07:00:00Z')
        self.assertEqual((code, gate['engine']['on']), (1, True))

    def test_after_todays_job_time_without_a_job_record_the_gate_is_off(self):
        code, gate = self.run_gate('--companies', 'acme', now='2026-10-31T09:00:00Z')
        self.assertEqual((code, gate['state']), (0, 'off'))
        self.assertEqual(gate['engine'], {'on': False, 'source': 'job-not-seen-today'})

    def test_todays_job_record_keeps_it_on(self):
        self.record(TODAY, 'acme', rec2('complete', startedAt='2026-10-31T06:30:00Z'))
        code, gate = self.run_gate('--companies', 'acme', now='2026-10-31T09:00:00Z')
        self.assertEqual((code, gate['state']), (0, 'ready'))


class EngineFlagTest(unittest.TestCase):
    """hq-cli runs the engine in the bot job only behind cli.bot-signals-engine-job (default off)."""

    record = GateTest.record
    lock = GateTest.lock
    run_gate = GateTest.run_gate

    def setUp(self):
        GateTest.setUp(self)
        os.environ.pop(bg.ENGINE_FLAG_ENV, None)

    def tearDown(self):
        GateTest.tearDown(self)

    def engine(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = bg.main(['engine', '--hq-root', str(self.root), '--today', TODAY, '--now', NOW])
        return code, json.loads(buf.getvalue())

    def test_no_job_record_is_off_and_builds_without_a_run(self):
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state'], gate['action']), (0, 'off', 'build'))
        self.assertEqual(gate['engine'], {'on': False, 'source': 'no-job-record'})
        self.assertIn('cli.bot-signals-engine-job', gate['reason'])

    def test_off_with_no_scope_does_not_ask_for_a_run(self):
        code, gate = self.run_gate()
        self.assertEqual((code, gate['state']), (0, 'off'))

    def test_wait_is_off_too(self):
        code, gate = self.run_gate('--companies', 'acme', '--wait', '--wait-seconds', '0')
        self.assertEqual((code, gate['state']), (0, 'off'))

    def test_brief_or_chat_runs_do_not_turn_the_gate_on(self):
        self.record(TODAY, 'acme', rec2('failed', trigger='brief', failureReason='Slack refused the connection'))
        self.record('2026-10-30', 'acme', rec2('complete', trigger='chat'))
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state']), (0, 'off'))

    def test_env_false_is_off_even_with_job_records(self):
        self.record(TODAY, 'acme', rec2('failed', failureReason='Slack refused the connection'))
        with mock.patch.dict(os.environ, {bg.ENGINE_FLAG_ENV: 'false'}):
            code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state'], gate['engine']['source']), (0, 'off', 'env'))

    def test_env_true_turns_the_gate_on(self):
        with mock.patch.dict(os.environ, {bg.ENGINE_FLAG_ENV: '1'}):
            code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state'], gate['engine']), (1, 'waiting', {'on': True, 'source': 'env'}))

    def test_yesterdays_job_record_turns_the_gate_on(self):
        self.record('2026-10-30', 'acme', rec2('complete'))
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state']), (1, 'waiting'))
        self.assertEqual(gate['engine']['source'], 'job-record:2026-10-30')

    def test_todays_job_record_gates_as_before(self):
        self.record(TODAY, 'acme', rec2('complete'))
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state']), (0, 'ready'))

    def test_job_lock_turns_the_gate_on(self):
        self.record(TODAY, 'acme', rec2('running', trigger='brief'))
        self.lock('acme', os.getpid())
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state'], gate['engine']['source']), (3, 'running', f'job-lock:{TODAY}'))

    def test_gate_and_brief_run_files_do_not_count_as_job_records(self):
        self.record(TODAY, 'brief-run', {'status': 'complete', 'trigger': 'job'})
        self.record(TODAY, 'summary', {'trigger': 'job'})
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state']), (0, 'off'))

    def test_engine_command_reports_state(self):
        self.assertEqual(self.engine(), (0, {'on': False, 'source': 'no-job-record', 'flag': 'cli.bot-signals-engine-job'}))
        self.record('2026-10-30', 'acme', rec2('complete', trigger='manual', jobRanAt=NOW))
        self.assertEqual(self.engine()[1]['on'], True)


class PremergeReviewTest(unittest.TestCase):
    """Step 0 as the skill runs it: a plain check, then the --start-run wait call."""

    record = GateTest.record
    lock = GateTest.lock
    run_gate = GateTest.run_gate
    start = StartRunTest.start
    runs = StartRunTest.runs
    started = ReviewFixTest.started
    gate_file = RoundTwoTest.gate_file
    write_prev_gate = RoundTwoTest.write_prev_gate
    fail_once = RoundThreeTest.fail_once

    def setUp(self):
        GateTest.setUp(self)

    def tearDown(self):
        GateTest.tearDown(self)

    def transient_failure(self):
        self.record(TODAY, 'acme', rec2('failed', finishedAt='2026-10-31T13:00:00Z', errorKind='network',
                                        failureReason='network', nextRetryAt='2026-10-31T13:15:00Z',
                                        steps=steps(failed_at='adapters')))

    # C1: Step 0 item 1 (plain check) must not use the retry that item 2 (--start-run) starts.
    def test_plain_check_then_start_run_on_a_due_slot_starts_one_run(self):
        self.transient_failure()
        code, gate = self.run_gate('--companies', 'acme', now='2026-10-31T13:16:00Z')
        self.assertEqual((code, gate['state']), (1, 'waiting'))
        self.assertEqual(gate['retries']['acme']['at'], '2026-10-31T13:15:00Z')
        body = 'REC = ' + repr(rec2('complete', trigger='brief')) + '\n' + WRITE_RECORD
        code, gate = self.start(body, '--max-seconds', '90', now='2026-10-31T13:16:00Z')
        self.assertEqual(len(self.started()), 1)
        self.assertEqual((code, gate['state']), (0, 'ready'))

    def test_any_number_of_plain_checks_leave_a_due_slot_for_the_start(self):
        self.transient_failure()
        for now in ('2026-10-31T13:16:00Z', '2026-10-31T13:40:00Z', '2026-10-31T15:00:00Z'):
            code, gate = self.run_gate('--companies', 'acme', now=now)
            self.assertEqual((code, gate['state']), (1, 'waiting'), now)
        code, gate = self.start('pass', now='2026-10-31T15:00:00Z')
        self.assertEqual(len(self.started()), 1)
        # The start used the slot: the record is unchanged, so the next retry is 15 minutes on,
        # and neither a plain check nor a wait call starts a second run before it.
        self.assertEqual((code, gate['state'], gate['nextRetryAt']), (2, 'failed', '2026-10-31T15:15:00Z'))
        self.assertEqual(self.run_gate('--companies', 'acme', now='2026-10-31T15:01:00Z')[0], 2)
        code, _ = self.start('pass', now='2026-10-31T15:02:00Z')
        self.assertEqual((code, len(self.started())), (2, 1))

    def test_plain_check_then_start_run_on_a_due_slot_with_no_record(self):
        self.fail_once()  # a brief-started run that wrote no record: slot at 13:20
        code, gate = self.run_gate('--companies', 'acme', now='2026-10-31T13:21:00Z')
        self.assertEqual((code, gate['state']), (1, 'waiting'))
        code, gate = self.start('pass', now='2026-10-31T13:21:00Z')
        self.assertEqual(len(self.started()), 2)
        self.assertEqual((code, gate['state'], gate['nextRetryAt']), (2, 'failed', '2026-10-31T13:36:00Z'))

    def test_plain_check_then_start_run_on_a_due_slot_with_no_company_list(self):
        run = ['--start-run', '--poll-seconds', '0.05', '--run-cmd', fake_run(self.root, 'pass')]
        code, gate = self.run_gate(*run)
        self.assertEqual((code, gate['state'], gate['nextRetryAt']), (2, 'failed', '2026-10-31T13:20:00Z'))
        code, gate = self.run_gate(now='2026-10-31T13:21:00Z')
        self.assertEqual((code, gate['action']), (1, 'start-run'))
        code, gate = self.run_gate(*run, now='2026-10-31T13:21:00Z')
        self.assertEqual(len(self.started()), 2)
        self.assertEqual((code, gate['state'], gate['nextRetryAt']), (2, 'failed', '2026-10-31T13:36:00Z'))

    def test_a_due_slot_is_kept_while_another_company_is_running(self):
        # The wait call starts nothing while a run holds another company's lock, so the due
        # slot must still be there when that run ends.
        self.transient_failure()
        self.record(TODAY, 'beta', rec2('running', pid=os.getpid()))
        self.lock('beta', os.getpid())
        marker = self.root / 'ran'
        code, gate = self.run_gate('--companies', 'acme,beta', '--start-run', '--max-seconds', '0', '--poll-seconds',
                                   '0.05', '--run-cmd', fake_run(self.root, touch(marker)), now='2026-10-31T13:16:00Z')
        self.assertEqual((code, gate['state']), (3, 'running'))
        self.assertEqual(gate['retries']['acme']['at'], '2026-10-31T13:15:00Z')
        self.assertEqual(self.started(), [])
        (self.runs() / 'beta.lock').unlink()
        self.record(TODAY, 'beta', rec2('complete'))
        body = 'REC = ' + repr(rec2('complete', trigger='brief')) + '\n' + WRITE_RECORD
        code, gate = self.run_gate('--companies', 'acme,beta', '--start-run', '--max-seconds', '90', '--poll-seconds',
                                   '0.05', '--run-cmd', fake_run(self.root, body), now='2026-10-31T13:17:00Z')
        self.assertEqual((code, gate['state'], len(self.started())), (0, 'ready', 1))

    # C2: the wait call fails open like every other call, and SKILL.md says so for every exit.
    def test_wait_call_fails_open_on_a_record_with_an_unexpected_shape(self):
        self.record(TODAY, 'acme', dict(rec2('complete'), steps='not-a-list'))
        marker = self.root / 'ran'
        code, gate = self.start(touch(marker), '--max-seconds', '90')
        self.assertEqual((code, gate['state'], gate['action']), (4, 'error', 'build'))
        self.assertFalse(marker.exists())

    def test_skill_step_0_sends_gate_errors_to_step_1_in_the_wait_path(self):
        text = (HERE.parent / 'SKILL.md').read_text()
        step0 = text[text.index('## Step 0. Signals gate'):text.index('## Step 1')]
        self.assertNotIn('any other exit goes to 3', step0)
        wait = step0[step0.index('2. On exit 1 or 3'):step0.index('3. On exit 2')]
        for needle in ('| 0 |', '| 1 |', '| 2 |', '| 3 |', '| 4 |', 'any other exit',
                       'output that is not gate JSON with a `state`', 'go to Step 1'):
            self.assertIn(needle, wait, needle)
        # Item 3 (build with stale signals) is entered on exit 2, or a second exit 1 in a row.
        stale = step0[step0.index('3. On exit 2'):]
        self.assertNotIn('or when the wait does not end `ready`', stale)
        self.assertIn('No other exit comes here', stale)

    # A hung run holding its lock costs one wait, not one per pass.
    def timed_out_wait(self):
        self.record(TODAY, 'acme', rec2('running', pid=os.getpid()))
        self.lock('acme', os.getpid(), started_at='2026-10-31T12:50:00Z')
        with mock.patch.object(bg.time, 'sleep'):
            code, gate = self.run_gate('--companies', 'acme', '--wait', '--poll-seconds', '600')
        self.assertEqual((code, gate['state']), (2, 'failed'))
        self.assertEqual(gate['waitTimedOut']['locks'], {'acme': '2026-10-31T12:50:00Z'})

    def test_after_a_timeout_the_same_lock_fails_at_once(self):
        self.timed_out_wait()
        for extra in ((), ('--start-run', '--max-seconds', '90', '--run-cmd', fake_run(self.root, 'pass'))):
            with mock.patch.object(bg.time, 'sleep') as sleep:
                code, gate = self.run_gate('--companies', 'acme', *extra, now='2026-10-31T13:10:00Z')
            self.assertEqual((code, gate['state'], gate['retry']), (2, 'failed', 'auto'), extra)
            self.assertIn('still going', gate['reason'])
            self.assertEqual(gate['nextRetryAt'], '2026-10-31T13:20:00Z')  # the timeout's time, not moved
            sleep.assert_not_called()
        self.assertEqual(self.started(), [])
        # Still held hours later, inside the lock's 3 hours: no new wait, a later retry time.
        with mock.patch.object(bg.time, 'sleep') as sleep:
            code, gate = self.run_gate('--companies', 'acme', '--wait', now='2026-10-31T15:00:00Z')
        self.assertEqual((code, gate['nextRetryAt']), (2, '2026-10-31T15:05:00Z'))
        sleep.assert_not_called()

    def test_after_a_timeout_a_finished_run_is_ready(self):
        self.timed_out_wait()
        (self.runs() / 'acme.lock').unlink()
        self.record(TODAY, 'acme', rec2('complete'))
        code, gate = self.run_gate('--companies', 'acme', now='2026-10-31T13:10:00Z')
        self.assertEqual((code, gate['state']), (0, 'ready'))
        self.assertNotIn('waitTimedOut', gate)

    def test_after_a_timeout_a_new_run_or_try_now_waits_again(self):
        self.timed_out_wait()
        # Try now waits on the same lock again.
        with mock.patch.object(bg.time, 'sleep') as sleep:
            code, gate = self.run_gate('--companies', 'acme', '--start-run', '--retry-now', '--poll-seconds', '600',
                                       '--run-cmd', fake_run(self.root, 'pass'), now='2026-10-31T13:10:00Z')
        self.assertEqual((code, sleep.call_count), (2, 2))
        self.assertIn('timed out after 20 minutes', gate['reason'])
        # A different run holding the lock (new startedAt) is waited for.
        self.lock('acme', os.getpid(), started_at='2026-10-31T13:30:00Z')
        code, gate = self.run_gate('--companies', 'acme', '--wait', '--max-seconds', '0', now='2026-10-31T13:31:00Z')
        self.assertEqual((code, gate['state']), (3, 'running'))

    # I2: a v1 running record (no lock, no pid) keeps the wait clock across calls.
    def test_v1_running_record_keeps_the_wait_clock(self):
        self.record(TODAY, 'acme', {'startedAt': '2026-10-31T12:45:00Z', 'finishedAt': None,
                                    'currentStep': 'extract', 'steps': steps()[:2]})
        self.write_prev_gate(waitStartedAt='2026-10-31T12:46:00Z', checkedAt='2026-10-31T13:04:00Z', runPids={})
        code, gate = self.start('pass', '--max-seconds', '0')
        self.assertEqual((code, gate['waitStartedAt']), (3, '2026-10-31T12:46:00Z'))
        code, gate = self.start('pass', '--max-seconds', '0', now='2026-10-31T13:06:00Z')
        self.assertEqual((code, gate['state']), (2, 'failed'))
        self.assertIn('timed out after 20 minutes', gate['reason'])

    # I4: a company slug never names a path outside the run folder.
    def test_companies_with_path_parts_exit_4_and_touch_nothing(self):
        (self.root / 'outside.json').write_text(json.dumps(rec2('complete')))
        marker = self.root / 'ran'
        for bad in ('../../../../outside', 'acme,../x', '/abs', 'a/b', '.hidden', 'a\\b'):
            code, gate = self.run_gate('--companies', bad, '--start-run', '--poll-seconds', '0.05',
                                       '--run-cmd', fake_run(self.root, touch(marker)))
            self.assertEqual((code, gate['state'], gate['action']), (4, 'error', 'build'), bad)
        self.assertFalse(marker.exists())
        self.assertEqual(sorted(p.name for p in self.runs().iterdir()), ['brief-gate.json'])
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ['core', 'outside.json', 'workspace'])

    # I9: briefWaitMinutes stays inside 1 to 180.
    def test_wait_minutes_are_bounded(self):
        for raw, want in (('0', 1), ('600', 180), ('20', 20), ('0.5', 1)):
            (self.root / 'core/settings/signals.yaml').write_text(f'briefWaitMinutes: {raw}\n')
            self.assertEqual(bg.load_settings(self.root)['briefWaitMinutes'], want, raw)


class StaleSignalsTest(unittest.TestCase):
    """A failed signals run never costs the brief: the gate says build, and carries the stale notice."""

    record = GateTest.record
    lock = GateTest.lock
    run_gate = GateTest.run_gate
    start = StartRunTest.start
    runs = StartRunTest.runs

    YESTERDAY = '2026-10-30'

    def started(self):
        d = self.runs() / bg.RUN_OUTPUT_DIR
        return sorted(p.name for p in d.glob('*.json')) if d.is_dir() else []

    def setUp(self):
        GateTest.setUp(self)

    def tearDown(self):
        GateTest.tearDown(self)

    def good_run(self, day, co='acme'):
        self.record(day, co, rec2('complete', company=co, startedAt=f'{day}T12:50:00Z', finishedAt=f'{day}T13:05:00Z'))

    def transient_failure(self, finished='2026-10-31T13:00:00Z', retry='2026-10-31T13:15:00Z'):
        return rec2('failed', finishedAt=finished, errorKind='network', failureReason='network',
                    nextRetryAt=retry, steps=steps(failed_at='adapters'))

    def assert_builds_stale(self, code, gate, want_code):
        self.assertEqual((code, gate['state'], gate['action']), (2, 'failed', 'build-stale'))
        stale = gate['signals_stale']
        self.assertEqual(stale['code'], want_code)
        self.assertIs(stale['try_now'], True)
        self.assertTrue(stale['line'].startswith(f"Signals are stale: {stale['reason']}. "))
        # The line is shown where there is no Try now control; the reply's sentence carries it.
        self.assertNotIn('Try now', stale['line'])
        self.assertIn('Try now', stale['try_now_line'])
        return stale

    def test_auth_or_config_failure_builds_with_a_stale_notice(self):
        self.good_run(self.YESTERDAY)
        for kind, fix in (('auth', 'Sign in again'), ('config', 'Fix the setup')):
            self.record(TODAY, 'acme', rec2('failed', errorKind=kind, finishedAt='2026-10-31T06:31:00Z',
                                            failureReason='You are signed out of HQ.', steps=steps(failed_at='adapters')))
            code, gate = self.run_gate('--companies', 'acme')
            stale = self.assert_builds_stale(code, gate, kind)
            self.assertEqual((stale['retry'], stale['next_retry_at']), ('manual', None))
            self.assertEqual(stale['last_good_run'], {'date': self.YESTERDAY, 'finished_at': '2026-10-30T13:05:00Z'})
            self.assertIn(fix, stale['line'])
            self.assertIn('last good run on Oct 30', stale['line'])
            self.assertNotIn('2026-10-30', stale['line'])
            self.assertEqual(stale['section_line'], 'From the last good signals run on Oct 30, not from today.')
            self.assertEqual(stale['detail'], 'acme: You are signed out of HQ.')
            self.assertEqual(stale['companies']['acme']['line'], stale['line'])

    def test_transient_failure_whose_retry_also_failed_builds_with_a_stale_notice(self):
        self.good_run(self.YESTERDAY)
        self.record(TODAY, 'acme', self.transient_failure())
        # Before the retry time: the brief builds now and the retry stays where it is.
        code, gate = self.run_gate('--companies', 'acme')
        stale = self.assert_builds_stale(code, gate, 'run-failed')
        self.assertEqual((stale['retry'], stale['next_retry_at']), ('auto', '2026-10-31T13:15:00Z'))
        # At the retry time the wait call starts one run, and that run fails too.
        again = self.transient_failure(finished='2026-10-31T13:16:00Z', retry='2026-10-31T13:31:00Z')
        body = 'REC = ' + repr(again) + '\n' + WRITE_RECORD + 'sys.exit(1)\n'
        code, gate = self.start(body, now='2026-10-31T13:16:00Z')
        stale = self.assert_builds_stale(code, gate, 'run-failed')
        self.assertEqual(len(self.started()), 1)
        self.assertEqual(stale['reason'], "today's signals run failed")
        self.assertEqual(stale['last_good_run']['date'], self.YESTERDAY)

    def test_wait_that_timed_out_on_a_live_run_builds_with_a_stale_notice(self):
        self.good_run(self.YESTERDAY)
        self.record(TODAY, 'acme', rec2('running', pid=os.getpid()))
        self.lock('acme', os.getpid(), started_at='2026-10-31T12:50:00Z')
        with mock.patch.object(bg.time, 'sleep'):
            code, gate = self.run_gate('--companies', 'acme', '--wait', '--poll-seconds', '600')
        stale = self.assert_builds_stale(code, gate, 'timed-out')
        self.assertEqual(stale['reason'],
                         "today's signals run did not finish within 20 minutes and is still going")
        self.assertIn('Press Try now to wait for the run', stale['try_now_line'])
        # A later pass while the same run holds its lock answers at once, with the same notice.
        with mock.patch.object(bg.time, 'sleep') as sleep:
            code, gate = self.run_gate('--companies', 'acme', now='2026-10-31T13:10:00Z')
        self.assertEqual(self.assert_builds_stale(code, gate, 'timed-out')['line'], stale['line'])
        sleep.assert_not_called()

    def test_run_that_died_without_a_record_builds_with_a_stale_notice(self):
        code, gate = self.start('pass')
        stale = self.assert_builds_stale(code, gate, 'no-record')
        self.assertEqual(stale['reason'], "today's signals run stopped without finishing")
        self.assertIsNone(stale['last_good_run'])
        self.assertIn('No earlier good signals run was found.', stale['line'])
        self.assertEqual(stale['section_line'], 'No good signals run was found, so these signals may be out of date.')
        # The next pass, before the retry time, still builds with the notice and starts nothing.
        code, gate = self.start('pass', now='2026-10-31T13:07:00Z')
        self.assert_builds_stale(code, gate, 'no-record')
        self.assertEqual(len(self.started()), 1)

    def test_run_that_died_with_no_company_list_builds_with_a_stale_notice(self):
        self.good_run(self.YESTERDAY)
        code, gate = self.run_gate('--start-run', '--poll-seconds', '0.05', '--run-cmd', fake_run(self.root, 'pass'))
        stale = self.assert_builds_stale(code, gate, 'no-record')
        self.assertEqual(stale['companies'], {})
        self.assertEqual(stale['last_good_run']['date'], self.YESTERDAY)

    def test_run_that_could_not_be_started_builds_with_a_stale_notice(self):
        code, gate = self.run_gate('--companies', 'acme', '--start-run',
                                   '--run-cmd', json.dumps(['/nonexistent/hq-not-installed']))
        stale = self.assert_builds_stale(code, gate, 'start-failed')
        self.assertEqual(stale['reason'], "today's signals run could not be started")
        code, gate = self.start("import sys; sys.stderr.write('error: invalid company slug\\n'); sys.exit(2)",
                                now='2026-10-31T13:30:00Z')
        self.assert_builds_stale(code, gate, 'start-failed')

    def test_wait_that_ends_still_waiting_carries_the_notice(self):
        # The wait call could start nothing and the company still has no record: the skill
        # builds on a second exit 1 in a row, and the notice for it is already in the gate.
        code, gate = self.run_gate('--companies', 'acme', '--start-run', '--retry-now', '--poll-seconds', '0.05',
                                   '--run-cmd', fake_run(self.root, 'pass'))
        self.assertEqual((code, gate['state'], gate['action']), (1, 'waiting', 'start-run'))
        self.assertEqual(gate['signals_stale']['code'], 'not-run')
        self.assertEqual(gate['signals_stale']['reason'], "today's signals run has not finished")
        self.assertEqual(self.started(), [])

    def test_only_the_companies_without_fresh_signals_are_in_the_notice(self):
        self.good_run('2026-10-29', 'beta')
        self.record(self.YESTERDAY, 'beta', rec2('failed', company='beta', errorKind='network',
                                                 steps=steps(failed_at='extract')))
        self.record(TODAY, 'acme', rec2('complete'))
        self.record(TODAY, 'beta', rec2('failed', company='beta', errorKind='auth',
                                        finishedAt='2026-10-31T06:31:00Z', steps=steps(failed_at='adapters')))
        code, gate = self.run_gate('--companies', 'acme,beta')
        stale = self.assert_builds_stale(code, gate, 'auth')
        self.assertEqual(list(stale['companies']), ['beta'])
        # Yesterday's run failed too, so the last good run is the day before.
        self.assertEqual(stale['companies']['beta']['last_good_run']['date'], '2026-10-29')
        self.assertEqual(stale['last_good_run']['date'], '2026-10-29')

    def test_last_good_run_skips_days_that_were_not_ready_and_stops_at_the_lookback(self):
        self.record(self.YESTERDAY, 'acme', rec2('partial', partialReason='late-start', steps=steps()[:1]))
        self.record('2026-10-28', 'acme', {'steps': 'not a list'})
        self.good_run('2026-10-20')
        now = bg.now_utc(NOW)
        self.assertEqual(bg.last_good_run(self.root, TODAY, 'acme', now)['date'], '2026-10-20')
        self.assertIsNone(bg.last_good_run(self.root, '2026-12-25', 'acme', now))
        self.assertIsNone(bg.last_good_run(self.root, TODAY, 'beta', now))

    def test_ready_running_off_and_error_gates_carry_no_notice(self):
        self.record(TODAY, 'acme', rec2('complete'))
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['action']), (0, 'build'))
        self.assertNotIn('signals_stale', gate)
        self.lock('acme', os.getpid())
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['action']), (3, 'wait'))
        self.assertNotIn('signals_stale', gate)
        with mock.patch.object(bg, 'decide', side_effect=RuntimeError('boom')):
            code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state'], gate['action']), (4, 'error', 'build'))
        self.assertNotIn('signals_stale', gate)
        with mock.patch.dict(os.environ, {bg.ENGINE_FLAG_ENV: 'false'}):
            code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['state'], gate['action']), (0, 'off', 'build'))
        self.assertNotIn('signals_stale', gate)

    def test_engine_off_probe_stays_read_only_next_to_past_run_folders(self):
        self.good_run(self.YESTERDAY)
        self.record(self.YESTERDAY, 'acme', rec2('complete', trigger='brief'))
        before = sorted(str(p) for p in self.root.rglob('*'))
        buf = io.StringIO()
        with mock.patch.dict(os.environ, {bg.ENGINE_FLAG_ENV: 'false'}), contextlib.redirect_stdout(buf):
            code = bg.safe_main(['engine', '--hq-root', str(self.root), '--today', TODAY, '--now', NOW])
        self.assertEqual((code, json.loads(buf.getvalue())['on']), (0, False))
        self.assertEqual(sorted(str(p) for p in self.root.rglob('*')), before)

    def test_try_now_from_a_stale_brief_reruns_signals_and_clears_the_notice(self):
        self.good_run(self.YESTERDAY)
        self.record(TODAY, 'acme', rec2('failed', errorKind='auth', finishedAt='2026-10-31T06:31:00Z',
                                        failureReason='You are signed out of HQ.', steps=steps(failed_at='adapters')))
        code, gate = self.run_gate('--companies', 'acme')
        self.assert_builds_stale(code, gate, 'auth')
        body = 'REC = ' + repr(rec2('complete', trigger='brief')) + '\n' + WRITE_RECORD
        code, gate = self.start(body, '--retry-now', '--max-seconds', '90')
        self.assertEqual((code, gate['state'], gate['action']), (0, 'ready', 'build'))
        self.assertNotIn('signals_stale', gate)
        self.assertEqual(len(self.started()), 1)
        # The rebuild's own check reads the same ready gate.
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual(code, 0)
        self.assertNotIn('signals_stale', gate)

    def test_try_now_that_fails_again_keeps_the_notice(self):
        self.record(TODAY, 'acme', rec2('failed', errorKind='auth', finishedAt='2026-10-31T06:31:00Z',
                                        steps=steps(failed_at='adapters')))
        again = rec2('failed', trigger='brief', errorKind='auth', finishedAt='2026-10-31T13:05:00Z',
                     steps=steps(failed_at='adapters'))
        body = 'REC = ' + repr(again) + '\n' + WRITE_RECORD + 'sys.exit(1)\n'
        code, gate = self.start(body, '--retry-now', '--max-seconds', '90')
        self.assert_builds_stale(code, gate, 'auth')
        self.assertEqual(len(self.started()), 1)

    def test_skill_step_0_builds_the_brief_on_every_exit(self):
        text = (HERE.parent / 'SKILL.md').read_text()
        step0 = text[text.index('## Step 0. Signals gate'):text.index('## Step 1')]
        for old in ('do not write `brief-data.json`', 'Your brief is waiting for signals',
                    'Your brief is not built until', 'stop (3 below)', 'replies with the waiting message'):
            self.assertNotIn(old, step0, old)
        item3 = step0[step0.index('3. On exit 2'):]
        for needle in ('go to Step 1', '`signals_stale`', '`build-stale`', 'Try now', '--retry-now',
                       'never write the notice yourself'):
            self.assertIn(needle, item3, needle)
        for table in (step0[step0.index('1. Check the gate'):step0.index('2. On exit 1 or 3')],
                      step0[step0.index('2. On exit 1 or 3'):step0.index('3. On exit 2')]):
            self.assertIn('build with stale signals (3 below)', table)
        rest = text[text.index('## Step 1'):]
        for needle in ('`signals_stale.line`', '`signals_stale.section_line`', '`brief-data.json.signals_stale`'):
            self.assertIn(needle, rest, needle)


class StaleNoticeKeepingTest(unittest.TestCase):
    """What counts as the last good run, and who may change a company's notice in the shared gate file."""

    record = GateTest.record
    lock = GateTest.lock
    run_gate = GateTest.run_gate

    def setUp(self):
        GateTest.setUp(self)

    def tearDown(self):
        GateTest.tearDown(self)

    def auth_failure(self, co):
        self.record(TODAY, co, rec2('failed', company=co, errorKind='auth', finishedAt='2026-10-31T06:31:00Z',
                                    steps=steps(failed_at='adapters')))

    def notice_for(self, co):
        """What the sweep reads for one company: brief_signals.gate_stale over the gate file."""
        spec = importlib.util.spec_from_file_location('brief_signals', HERE / 'brief_signals.py')
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.gate_stale(str(self.root), TODAY, co)

    def test_a_skipped_run_is_not_the_last_good_run(self):
        self.record('2026-10-29', 'acme', rec2('complete', finishedAt='2026-10-29T13:05:00Z'))
        self.record('2026-10-30', 'acme', rec2('skipped', skipReason='nothing-to-run', steps=[]))
        self.auth_failure('acme')
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual(code, 2)
        self.assertEqual(gate['signals_stale']['last_good_run'], {'date': '2026-10-29', 'finished_at': '2026-10-29T13:05:00Z'})
        self.assertIn('last good run on Oct 29', gate['signals_stale']['line'])
        # With only the skipped run behind it there is no good run at all.
        (self.root / 'workspace/signals/runs/2026-10-29/acme.json').unlink()
        code, gate = self.run_gate('--companies', 'acme')
        self.assertIsNone(gate['signals_stale']['last_good_run'])
        self.assertIn('No earlier good signals run was found.', gate['signals_stale']['line'])

    def test_a_run_whose_extract_step_did_not_finish_is_not_the_last_good_run(self):
        self.record('2026-10-30', 'acme', rec2('partial', partialReason='step-failed:upload', steps=steps()[:2]))
        self.auth_failure('acme')
        _, gate = self.run_gate('--companies', 'acme')
        self.assertIsNone(gate['signals_stale']['last_good_run'])

    def test_a_check_for_another_company_keeps_this_companys_notice(self):
        self.auth_failure('acme')
        self.record(TODAY, 'beta', rec2('complete', company='beta'))
        code, gate = self.run_gate('--companies', 'acme,beta')
        self.assertEqual((code, list(gate['staleCompanies'])), (2, ['acme']))
        line = self.notice_for('acme')['line']
        self.assertIsNone(self.notice_for('beta'))
        # Another session's brief checks beta alone: the file turns ready, acme's notice stays.
        code, gate = self.run_gate('--companies', 'beta')
        self.assertEqual((code, gate['state']), (0, 'ready'))
        self.assertNotIn('signals_stale', gate)
        self.assertEqual(self.notice_for('acme')['line'], line)
        self.assertIsNone(self.notice_for('beta'))
        # The same while beta's run is going, and after an error pass for beta.
        self.lock('beta', os.getpid())
        code, _ = self.run_gate('--companies', 'beta')
        self.assertEqual(code, 3)
        self.assertEqual(self.notice_for('acme')['line'], line)
        with mock.patch.object(bg, 'decide', side_effect=RuntimeError('boom')):
            code, _ = self.run_gate('--companies', 'beta')
        self.assertEqual(code, 4)
        self.assertEqual(self.notice_for('acme')['line'], line)

    def test_only_a_check_of_the_company_itself_clears_its_notice(self):
        self.auth_failure('acme')
        self.run_gate('--companies', 'acme')
        self.assertEqual(self.notice_for('acme')['code'], 'auth')
        self.record(TODAY, 'acme', rec2('complete'))
        code, gate = self.run_gate('--companies', 'acme')
        self.assertEqual((code, gate['staleCompanies']), (0, {}))
        self.assertIsNone(self.notice_for('acme'))

    def test_an_error_pass_or_an_off_gate_for_the_company_leaves_no_notice(self):
        self.auth_failure('acme')
        self.run_gate('--companies', 'acme')
        with mock.patch.object(bg, 'decide', side_effect=RuntimeError('boom')):
            code, _ = self.run_gate('--companies', 'acme')
        self.assertEqual(code, 4)
        self.assertIsNone(self.notice_for('acme'))
        self.run_gate('--companies', 'acme')
        self.assertEqual(self.notice_for('acme')['code'], 'auth')
        with mock.patch.dict(os.environ, {bg.ENGINE_FLAG_ENV: 'false'}):
            code, _ = self.run_gate('--companies', 'acme')
        self.assertEqual(code, 0)
        self.assertIsNone(self.notice_for('acme'))

    def test_no_written_gate_says_stop(self):
        self.auth_failure('acme')
        _, gate = self.run_gate('--companies', 'acme')
        self.assertEqual(gate['action'], 'build-stale')
        self.assertNotIn("'stop'", (HERE / 'brief_gate.py').read_text())

    def test_skill_says_where_the_notice_goes_on_the_page_and_in_the_closing_reply(self):
        text = (HERE.parent / 'SKILL.md').read_text()
        step0 = text[text.index('## Step 0. Signals gate'):text.index('## Step 1')]
        self.assertIn('"label":"Keep this brief"', step0)
        self.assertIn('"label":"Try now"', step0)
        self.assertNotIn('Wait for', text)
        self.assertIn('`staleCompanies`', step0)
        step4 = text[text.index('## Step 4. Synthesize'):text.index('## Step 4b.')]
        for needle in ('`signals_notices`', 'brief_page.py notice --brief', '`signals_notice_problems`',
                       '{company, code, reason, last_good_run: {date, finished_at} or null, try_now, line, try_now_line, section_line}'):
            self.assertIn(needle, step4, needle)
        self.assertNotIn('signals_stale}`', step4)
        step4b = text[text.index('## Step 4b.'):text.index('## Step 5.')]
        for needle in ('`signals-stale`', '`summary[1]`', '`section_line`', 'Last updated <date>'):
            self.assertIn(needle, step4b, needle)
        step6 = text[text.index('## Step 6. Finish'):text.index('## Learning, weekly')]
        for needle in ('stale reply', '`signals_stale.line`', 'BRIEF READY', 'Try now'):
            self.assertIn(needle, step6, needle)
        # The notice is never typed by the agent into brief.json.
        self.assertNotIn('copied unchanged from `brief-data.json.signals_stale`', text)
        self.assertNotIn('as the first line of that company', text)


class StalePageSkillTextTest(unittest.TestCase):
    """SKILL.md on the page of a stale brief: always a page, one notice card per stale company."""

    def setUp(self):
        self.text = (HERE.parent / 'SKILL.md').read_text()

    def part(self, start, end):
        return self.text[self.text.index(start):self.text.index(end)]

    def test_a_stale_brief_always_has_a_page(self):
        step4 = self.part('## Step 4. Synthesize', '## Step 4b.')
        step4b = self.part('## Step 4b.', '## Step 5.')
        self.assertIn('also writes `brief.json.page`', step4)
        self.assertIn('It is optional only while `brief.json.signals_notices` is empty', step4b)
        self.assertIn('`"fallback_page": true`', step4b)
        self.assertIn('The app draws neither `signals_notices` nor `learned_notes`', step4b)
        self.assertNotIn('does not lose the notice', self.text)
        self.assertNotIn('The page is optional and additive', self.text)
        # notice says what exit 1 means; attach keeps its exit code and says what a problem means.
        self.assertIn('Exit 1 with a `problem` in the output', step4)
        self.assertIn('`attach` exits 0 on every brief whose signals are not stale', step4b)
        self.assertIn('saying `brief-data.json` could not be read', step4b)
        self.assertIn('After `attach`, run `brief_rank.py --check` once more', step4b)
        # Exit 2 is terminal: one defined action, no loop.
        self.assertIn('Exit 2 means no valid page could be built', step4)
        for needle in ('never reads `page.json` or `page-draft.json`', 'It is terminal: do not run either command again',
                       'run `attach` one more time', 'do not repeat', 'end with the stale reply'):
            self.assertIn(needle, step4b, needle)
        self.assertNotIn('(and `page-draft.json`, for the frame)', self.text)

    def test_each_stale_company_has_its_own_card_and_closed_card_text(self):
        step4b = self.part('## Step 4b.', '## Step 5.')
        for needle in ('`signals-stale-<slug>`', 'Each stale company has its own notice card',
                       '"Last updated <date>"', '"No signals yet · Acme Inc" in every brief', 'The date always comes first',
                       'On the opened card a line holds 19 characters', 'which takes three',
                       '"No run has finished yet, so signal cards are hidden. Sign-in failed."',
                       '"From my Daily Brief: Signals for Acme Inc were last updated Oct 1.',
                       'a line surely holds 17 characters',
                       '"Last updated Oct 1 · Acme Inc"; a brief for one company keeps "Last updated Oct 1"', 'It does not repeat the title',
                       '`drill.bot`', 'not the day anything broke', "today's signals run has not finished yet.",
                       'A title is at most 43 characters',
                       '`label: "From <date>"`', '`label: "Stale signals"`', 'at most 17 characters', 'at most 76 characters',
                       'No sentence uses a possessive of a company name', 'Nothing on the page mentions "Try now"',
                       'The notice names its company in words', '"Acme Inc: sign-in to a connected account failed."',
                       'in the `why` at 27 characters, between words; in the title at 15 characters and two words',
                       '`brief-data.json.window.today`',
                       'A company whose signals are fresh has no notice card',
                       'it leaves the cards of a company with fresh signals alone'):
            self.assertIn(needle, step4b, needle)

    def test_the_closing_reply_follows_the_file_and_names_each_company(self):
        step0 = self.part('## Step 0. Signals gate', '## Step 1')
        step6 = self.part('## Step 6. Finish', '## Learning, weekly')
        self.assertIn('When the finished `brief.json.signals_notices` is not empty', step0)
        self.assertIn("with the company's name and a colon in front when the brief covers more than one company", step0)
        self.assertIn('When `brief.json.signals_notices` is not empty', step6)
        # Try now is named in the reply only; the page line has no control to name.
        for part in (step0, step6):
            self.assertIn('`try_now_line`', part)
        self.assertIn('The reply is the only place `try_now_line` is used', step0)
        self.assertIn('`brief_gate.human_date`', step0)
        self.assertNotIn('2026-10-30. Sign in again, then press Try now', self.text)
        self.assertNotIn('Signals from <date>', self.text)
        self.assertNotIn('Signals are stale, last good run', self.text)
        for gone in ('Signals stale since', 'Stale since', 'cards left out', 'No good run found', 'is still going."'):
            self.assertNotIn(gone, self.text, gone)
        self.assertIn('one line per stale company', step6)
        self.assertNotIn('When Step 0 ended in item 3 (the brief was built with stale signals), end with', step6)


if __name__ == '__main__':
    unittest.main()
