#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'decision-queue.sh'
DECISIONS = Path(__file__).resolve().parents[1] / 'super-conductor-decisions.mjs'
FAKE = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p=Path(os.environ['FAKE_DB']); db=json.loads(p.read_text()); a=sys.argv[1:]
db['calls'].append(a); p.write_text(json.dumps(db))
assert a[0]=='decide'
if a[1]=='list':
 assert a[2:]==['--open','--json']
 if db.get('list_fail'): sys.exit(1)
 print(json.dumps([r for r in db['records'] if r['state'] in ('open','talking')]))
elif a[1]=='ask':
 assert '--company' in a and a[a.index('--company')+1].strip()
 assert '--expires' in a and a[a.index('--expires')+1].strip()
 if db.get('fail'): print('asker_not_allowed',file=sys.stderr); sys.exit(1)
 if db.get('malformed'): print('not json'); sys.exit(0)
 r={'id':'d'+str(len(db['records'])), 'state':'open'}; db['records'].append(r); p.write_text(json.dumps(db)); print(json.dumps(r))
elif a[1]=='show': print(json.dumps(next(r for r in db['records'] if r['id']==a[2])))
elif a[1]=='withdraw':
 next(r for r in db['records'] if r['id']==a[2])['state']='withdrawn'; p.write_text(json.dumps(db)); print('withdrawn')
else: sys.exit(2)
'''


class QueueTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'hq').write_text(FAKE)
        (self.root / 'hq').chmod(0o755)
        self.db = self.root / 'db.json'
        self.db.write_text(json.dumps({'records': [{'id': 'foreign', 'state': 'open'}], 'calls': []}))
        self.state = self.root / 'state.json'
        self.state.write_text(json.dumps({'children': {'child': 'session'}}))
        self.env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ['PATH'], FAKE_DB=str(self.db))

    def call(self, *args, ok=True):
        r = subprocess.run(['bash', str(SCRIPT), '--state', str(self.state), *args], env=self.env, capture_output=True, text=True)
        self.assertEqual(r.returncode == 0, ok, r.stderr)
        return json.loads(r.stdout) if ok else r.stderr

    def edit(self, fn):
        db = json.loads(self.db.read_text()); fn(db); self.db.write_text(json.dumps(db))

    def enqueue(self, step='first', **kwargs):
        kwargs.setdefault('company', 'example-company')
        item = dict(step_id=step, statement='Publish $(touch unsafe)?', source='child', relay_target='child', options=[{'id':'A','label':'Publish | now'}, {'id':'B','label':'Hold'}], recommend='A', context_links=['https://example.com/review','https://example.com/draft'], **kwargs)
        path = self.root / (step + '.json'); path.write_text(json.dumps(item))
        return self.call('enqueue', str(path))

    def calls(self, operation):
        return [a for a in json.loads(self.db.read_text())['calls'] if a[1] == operation]

    def answer(self):
        self.edit(lambda db: db['records'][-1].update(state='answered', answer={'choiceId':'A','source':'tap'}))

    def test_order_answer_receipt_and_ledger(self):
        self.enqueue(company='example-company', commitment_id='cm-example'); self.enqueue('second'); self.enqueue()
        self.assertEqual(self.call('sweep')['status'], 'open')
        args = self.calls('ask')[0]
        self.assertEqual(args[args.index('--company')+1], 'example-company')
        self.assertEqual(args[args.index('--expires')+1], '72h')
        self.assertIn('A|Publish | now', args)
        self.assertIn('--recommend', args); self.assertIn('cm-example', args)
        self.assertEqual(args.count('--context-link'), 2)
        self.call('sweep'); self.assertEqual(len(self.calls('ask')), 1)
        self.answer()
        self.assertEqual(self.call('sweep')['step']['answer']['choiceId'], 'A')
        self.call('sweep'); self.assertEqual(len(self.calls('ask')), 1)
        self.call('ack', 'first', '--evidence', 'relay:123', '--ledger-evidence', 'commitment:cm-example:decision:d1')
        self.assertEqual(self.call('sweep')['status'], 'open')
        self.assertEqual(len(self.calls('ask')), 2)
        self.assertEqual(json.loads(self.state.read_text())['children'], {'child':'session'})
        self.call('ack', 'first', '--evidence', 'relay:123', ok=False)

    def test_fallback_only_after_failed_ask(self):
        self.enqueue(); self.enqueue('second'); self.edit(lambda db: db.update(fail=True))
        self.assertEqual(self.call('sweep')['status'], 'fallback')
        self.call('sweep'); self.assertEqual(len(self.calls('ask')), 1)
        self.assertIn('asker_not_allowed', json.loads(self.state.read_text())['decision_queue']['failures'][0]['error'])
        self.call('fallback-answer', 'first', '--choice', 'bad', ok=False)
        self.call('fallback-answer', 'first', '--choice', 'B')
        self.call('ack', 'first', '--evidence', 'chat:receipt')
        self.edit(lambda db: db.update(fail=False)); self.assertEqual(self.call('sweep')['status'], 'open')

    def test_api_404_falls_back_to_chat_picker_cleanly(self):
        # Prod returns 404 for the decisions API until hq-pro 5060 deploys.
        self.edit(lambda db: db.update(list_fail=True, fail=True))
        idle = self.call('sweep')  # nothing queued: the desk must still go on to claim a row
        self.assertEqual(idle['status'], 'idle'); self.assertIn('read_error', idle)
        self.enqueue(); self.enqueue('second')
        out = self.call('sweep')
        self.assertEqual(out['status'], 'fallback'); self.assertEqual(out['step']['step_id'], 'first')
        self.assertEqual(self.calls('ask'), [])
        failure = json.loads(self.state.read_text())['decision_queue']['failures'][-1]
        self.assertEqual((failure['operation'], failure['step_id']), ('list', 'first'))
        self.assertEqual(self.call('sweep')['status'], 'fallback')  # stays on the first step
        self.call('fallback-answer', 'first', '--text', 'Hold until Monday')
        self.assertEqual(self.call('sweep')['step']['answer']['text'], 'Hold until Monday')
        self.call('ack', 'first', '--evidence', 'chat-fallback:first')
        self.edit(lambda db: db.update(list_fail=False))  # list works, ask still 404s
        out = self.call('sweep')
        self.assertEqual((out['status'], out['step']['step_id']), ('fallback', 'second'))
        self.assertEqual(len(self.calls('ask')), 1)
        self.call('fallback-answer', 'second', '--choice', 'B'); self.call('ack', 'second', '--evidence', 'chat-fallback:second')
        self.assertEqual(self.call('sweep')['status'], 'idle')

    def test_enqueue_row_from_desk_queue_and_cancel(self):
        row = {'id': 'dq_1', 'source': 'ask', 'ref': 's1:a1', 'question': 'Ship the fix?', 'asked_by': 'child release',
               'options': [{'label': 'Hold', 'recommended': False}, {'label': 'Ship', 'description': 'merge now', 'recommended': True}],
               'priority': 'normal'}
        path = self.root / 'row.json'; path.write_text(json.dumps([row]))
        self.call('enqueue-row', str(path), ok=False)  # no company anywhere
        self.assertEqual(self.call('enqueue-row', str(path), '--company', 'example-company')['status'], 'queued')
        self.assertEqual(self.call('enqueue-row', str(path), '--company', 'example-company')['status'], 'already_queued')
        row2 = dict(row, id='dq_2', company='row-company'); path2 = self.root / 'row2.json'; path2.write_text(json.dumps(row2))
        self.call('enqueue-row', str(path2))
        self.assertEqual(self.call('sweep')['status'], 'open')
        args = self.calls('ask')[0]
        self.assertEqual(args[args.index('--recommend')+1], 'B')
        self.assertIn('A|Hold', args); self.assertIn('B|Ship', args)
        self.assertEqual(args[-1], 'child release: Ship the fix?')
        self.assertIn('Ship: merge now', args[args.index('--context')+1])
        self.call('cancel', 'dq_1', '--reason', 'answered in source', ok=False)  # open card: withdraw instead
        self.call('cancel', 'dq_2', '--reason', 'answered in source')
        self.call('withdraw', 'd1'); self.assertEqual(self.call('sweep')['status'], 'idle')
        self.assertEqual(len(self.calls('ask')), 1)

    def test_dropped_or_withdrawn_row_is_asked_again_while_still_open(self):
        # Regression: a row whose picker was dismissed after a fallback, or whose
        # card was withdrawn, used to stay 'already_queued' and was never asked again.
        row = {'id': 'dq_9', 'source': 'conductor', 'ref': 'r9', 'question': 'Go?', 'company': 'example-company',
               'options': [{'label': 'Go', 'recommended': True}, {'label': 'Hold'}]}
        path = self.root / 'row9.json'; path.write_text(json.dumps([row]))
        self.edit(lambda db: db.update(list_fail=True, fail=True))  # API 404
        self.call('enqueue-row', str(path))
        self.assertEqual(self.call('sweep')['status'], 'fallback')
        self.call('cancel', 'dq_9', '--reason', 'hq decide failed; asked on the desk')
        # Picker dismissed: the row is still open on the next wake.
        out = self.call('enqueue-row', str(path))
        self.assertEqual((out['status'], out['attempt']), ('queued', 2))
        self.assertEqual(self.call('sweep')['status'], 'fallback')
        self.edit(lambda db: db.update(list_fail=False, fail=False))  # API deployed
        self.call('cancel', 'dq_9', '--reason', 'retry')
        self.call('enqueue-row', str(path)); self.assertEqual(self.call('sweep')['status'], 'open')
        self.call('withdraw', 'd1')
        self.assertEqual(self.call('enqueue-row', str(path))['status'], 'queued')
        self.assertEqual(self.call('sweep')['status'], 'open'); self.assertEqual(len(self.calls('ask')), 2)
        self.answer(); self.call('sweep'); self.call('ack', 'dq_9', '--evidence', 'd2')
        self.assertEqual(self.call('enqueue-row', str(path))['status'], 'already_relayed')
        self.assertEqual(self.call('sweep')['status'], 'idle')

    def desk(self, *args, ok=True):
        r = subprocess.run(['node', str(DECISIONS), *args], env=self.env, capture_output=True, text=True)
        self.assertEqual(r.returncode == 0, ok, r.stdout + r.stderr)
        return r.stdout

    def test_desk_flow_answer_after_claim_ttl_needs_reclaim_before_ack(self):
        # Regression: a Queue card outlives the 15-minute desk claim. The desk
        # re-claims the row before writing the answer, and acks only after the
        # answer write succeeded, so a late answer is never lost.
        queue = self.root / 'decisions.jsonl'
        self.desk('add', '--file', str(queue), '--source', 'conductor', '--ref', 'r1', '--question', 'Ship?',
                  '--option', 'Ship', '--option', 'Hold', '--company', 'example-company', '--no-standing')
        old = '2020-01-01T00:00:00Z'  # claim dated long ago: already lapsed
        rows = self.desk('next', '--file', str(queue), '--json', '--claim', 'desk', '--count', '1', '--now', old)
        row_file = self.root / 'claimed.json'; row_file.write_text(rows)
        self.call('enqueue-row', str(row_file)); self.assertEqual(self.call('sweep')['status'], 'open')
        self.answer()
        step = self.call('sweep')['step']; self.assertEqual(step['status'], 'answer_pending')
        label = next(o['label'] for o in step['options'] if o['id'] == step['answer']['choiceId'])
        row_id = step['step_id']
        self.desk('answer', '--file', str(queue), '--id', row_id, '--answer', label, '--desk', 'desk', ok=False)
        self.desk('claim', '--file', str(queue), '--id', row_id, '--desk', 'desk')
        self.desk('answer', '--file', str(queue), '--id', row_id, '--answer', label, '--desk', 'desk')
        self.call('ack', row_id, '--evidence', step['decision_id'])
        answered = [json.loads(l) for l in self.desk('list', '--file', str(queue), '--status', 'answered', '--json').splitlines()]
        self.assertEqual([(r['id'], r.get('answer')) for r in answered], [(row_id, 'Ship')])

    def test_answered_card_whose_row_closed_elsewhere_does_not_block_next(self):
        self.enqueue(); self.enqueue('second'); self.call('sweep'); self.answer()
        self.assertEqual(self.call('sweep')['status'], 'answer_pending')
        self.call('cancel', 'first', '--reason', 'row answered elsewhere; Queue pick A not written')
        self.assertEqual(self.call('sweep')['status'], 'open')
        self.assertEqual(len(self.calls('ask')), 2)

    def test_talking_expiry_and_ownership(self):
        self.enqueue(); self.enqueue('second'); self.call('sweep')
        self.call('withdraw', 'foreign', ok=False); self.assertEqual(self.calls('withdraw'), [])
        self.edit(lambda db: db['records'][-1].update(state='talking'))
        self.assertEqual(self.call('sweep')['status'], 'open')
        self.edit(lambda db: db['records'][-1].update(state='expired'))
        self.assertEqual(self.call('sweep')['status'], 'expired')
        self.assertEqual(self.call('sweep')['status'], 'expired')
        self.assertEqual(len(self.calls('ask')), 1)
        self.call('resolve-expired', 'first', '--action', 'drop', '--reason', 'Request obsolete')
        self.call('sweep'); self.assertEqual(len(self.calls('ask')), 2)
        self.call('withdraw', 'd2'); self.assertEqual(self.call('sweep')['status'], 'idle')

    def test_read_error_with_open_card_and_uncertain_ask_do_not_advance(self):
        self.enqueue(); self.enqueue('second'); self.call('sweep')
        self.edit(lambda db: db.update(list_fail=True)); self.call('sweep', ok=False)
        self.assertEqual(len(self.calls('ask')), 1)
        self.assertEqual(json.loads(self.state.read_text())['decision_queue']['items'][0]['status'], 'open')
        self.call('fallback-answer', 'first', '--choice', 'A', ok=False)
        self.edit(lambda db: db.update(list_fail=False)); self.call('withdraw', 'd1')
        self.edit(lambda db: db.update(malformed=True))
        self.assertEqual(self.call('sweep')['status'], 'ask_uncertain')
        self.assertEqual(self.call('sweep')['status'], 'reconcile_required')
        self.assertEqual(len(self.calls("ask")), 2)
        self.call('fallback-answer', 'second', '--choice', 'A', ok=False)

    def test_missing_ledger_receipt_preserves_relay_and_blocks(self):
        self.enqueue(company='example-company', commitment_id='cm-example'); self.call('sweep'); self.answer(); self.call('sweep')
        self.call('ack', 'first', '--evidence', 'relay:123', ok=False)
        current = self.call('sweep')['step']
        self.assertEqual(current['relay_evidence'], 'relay:123')
        self.assertEqual(current['status'], 'answer_pending')
        self.assertEqual(len(self.calls('ask')), 1)

    def test_locked_queue_cannot_issue_second_ask(self):
        self.enqueue()
        lock = Path(str(self.state) + '.decision-lock'); lock.mkdir()
        error = self.call('sweep', ok=False)
        self.assertIn(str(lock), error)
        self.assertIn('if stale', error)
        self.assertEqual(self.calls('ask'), [])
        lock.rmdir()
        self.assertEqual(self.call('sweep')['status'], 'open')

    def test_idle_sweep_still_reads_decisions(self):
        self.assertEqual(self.call('sweep')['status'], 'idle')
        self.assertEqual(len(self.calls('list')), 1)

    def test_context_links_rejected_without_saving_or_asking(self):
        self.enqueue()
        original = self.state.read_text()
        item_path = self.root / 'first.json'
        item = json.loads(item_path.read_text())
        item['step_id'] = 'unsafe'
        links = [
            'https://example.com/file?X-Amz-Signature=fixture',
            'https://example.com/file?sig=fixture',
            'https://example.com/file#access_token=fixture',
            'https://fixture:fixture@example.com/file',
            'https://example.com/' + 'ghp_' + 'a' * 36,
        ]
        for link in links:
            with self.subTest(link_kind=links.index(link)):
                item['context_links'] = [link]
                item_path.write_text(json.dumps(item))
                error = self.call('enqueue', str(item_path), ok=False)
                self.assertNotIn(link, error)
                self.assertEqual(self.state.read_text(), original)
                self.assertEqual(self.calls('ask'), [])

    def test_saved_context_links_rechecked_before_ask(self):
        self.enqueue()
        state = json.loads(self.state.read_text())
        state['decision_queue']['items'][0]['context_links'] = ['https://example.com/?signature=fixture']
        self.state.write_text(json.dumps(state))
        self.call('sweep', ok=False)
        self.assertEqual(self.calls('ask'), [])
        self.assertEqual(json.loads(self.state.read_text())['decision_queue']['items'][0]['status'], 'queued')

    def test_reask_expired_preserves_order_and_history(self):
        self.enqueue(expires='24h'); self.enqueue('second'); self.call('sweep')
        self.assertEqual(self.calls('ask')[0][self.calls('ask')[0].index('--expires')+1], '24h')
        self.call('resolve-expired', 'first', '--action', 'drop', '--reason', 'Too early', ok=False)
        self.edit(lambda db: db['records'][-1].update(state='expired'))
        self.call('sweep')
        self.call('resolve-expired', 'second', '--action', 'reask', '--reason', 'Wrong step', ok=False)
        self.call('resolve-expired', 'first', '--action', 'reask', '--reason', 'Approval still needed', '--expires', '48h')
        fresh = self.call('sweep')['step']
        self.assertEqual(fresh['step_id'], 'first')
        self.assertEqual(fresh['decision_id'], 'd2')
        self.assertEqual(fresh['expiry_resolutions'][0]['decision_id'], 'd1')
        self.assertEqual(self.calls('ask')[1][self.calls('ask')[1].index('--expires')+1], '48h')
        self.call('sweep'); self.assertEqual(len(self.calls('ask')), 2)
        self.answer(); self.call('sweep'); self.call('ack', 'first', '--evidence', 'relay:retry')
        self.assertEqual(self.call('sweep')['step']['step_id'], 'second')

    def test_company_required_without_commitment_and_expiry_override(self):
        self.enqueue(expires='2099-01-01T00:00:00Z', company='cmp_example')
        item_path = self.root / 'first.json'; item = json.loads(item_path.read_text())
        del item['company']; item['step_id'] = 'missing-company'; item_path.write_text(json.dumps(item))
        self.assertIn('company is required', self.call('enqueue', str(item_path), ok=False))
        self.call('sweep')
        args = self.calls('ask')[0]
        self.assertEqual(args[args.index('--expires')+1], '2099-01-01T00:00:00Z')
        self.assertEqual(args[args.index('--company')+1], 'cmp_example')


if __name__ == '__main__':
    unittest.main()
