"""Plain-assert tests for local_sessions.py. Run: python3 -I test_local_sessions.py"""
import importlib.util
import json
import os
import tempfile


def _ts(day, clock):
    """A YYYYMMDD-HHMMSS stamp from its two halves (keeps long digit runs out of the source)."""
    return day + '-' + clock

_spec = importlib.util.spec_from_file_location(
    'local_sessions', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'local_sessions.py'))
ls = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ls)


def write(path, body):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(body)


def jl(*records):
    return ''.join(json.dumps(r, separators=(',', ':')) + '\n' for r in records)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        hq, tx, codex = os.path.join(tmp, 'hq'), os.path.join(tmp, 'projects', '-x-HQ'), os.path.join(tmp, 'codex')

        def meta(sid, extra=''):
            write(os.path.join(hq, 'workspace/sessions', sid, 'meta.yaml'),
                  f'session_id: {sid}\nstarted_at: "2026-10-09T15:00:00Z"\n{extra}senior: user\n')

        # custom-title wins over the first prompt; meta.yaml company honored.
        meta('s-titled', 'company_slug: acme\n')
        write(os.path.join(tx, 's-titled.jsonl'), jl(
            {'type': 'user', 'cwd': '/x/HQ/repos/private/widget-app', 'message': {'content': 'secret prompt text'}},
            {'type': 'custom-title', 'customTitle': 'ACME · Widget · fix signup', 'sessionId': 's-titled'}))
        # sdk-cli => agent.
        meta('s-agent')
        write(os.path.join(tx, 's-agent.jsonl'), jl(
            {'type': 'user', 'entrypoint': 'sdk-cli', 'message': {'content': 'summarize the logs\nmore'}}))
        # Lane brief path => lane named after the lane.
        meta('s-lane', 'company_slug: acme\n')
        write(os.path.join(tx, 's-lane.jsonl'), jl(
            {'type': 'user', 'entrypoint': 'claude-desktop', 'message': {'content':
             'Working directory: /x/repo\n\n---\n\nRead your brief at /x/HQ/workspace/tmp/workflow-runner/run-1/conduct-charts-viz/brief.md and carry it out now.'}}))
        # Unnamed interactive session: first human line, reminders skipped.
        meta('s-prompt', 'company_slug: other-co\n')
        write(os.path.join(tx, 's-prompt.jsonl'), jl(
            {'type': 'user', 'isMeta': True, 'message': {'content': '<command-name>x</command-name>'}},
            {'type': 'user', 'message': {'content': [{'type': 'text', 'text': '<system-reminder>\nskip\n</system-reminder>\nfix the   export button\nsecond line private'}]}}))
        # Outside the window: excluded.
        write(os.path.join(hq, 'workspace/sessions/s-old/meta.yaml'), 'session_id: s-old\nstarted_at: "2026-10-01T10:00:00Z"\n')
        # Codex named thread.
        meta('c-codex', 'company_slug: acme\n')
        write(os.path.join(codex, 'session_index.jsonl'), jl({'id': 'c-codex', 'thread_name': 'Old'}, {'id': 'c-codex', 'thread_name': 'Fix deploy script'}))
        write(os.path.join(codex, 'sessions/2026/10/09/rollout-2026-10-09T15-00-00-c-codex.jsonl'),
              jl({'type': 'session_meta', 'payload': {'id': 'c-codex', 'cwd': '/x/HQ/repos/public/deploy-kit'}}))

        rows = ls.scan(hq, '2026-10-09T00:00:00Z', '2026-10-10T00:00:00Z',
                       claude_root=os.path.join(tmp, 'projects'), codex_root=codex)
        by = {r['id']: r for r in rows}
        assert 's-old' not in by, by.keys()

        t = by['s-titled']
        assert t['title'] == 'ACME · Widget · fix signup', t
        assert t['company'] == 'acme' and t['kind'] == 'you' and t['project'] == 'widget-app', t
        assert t['cwd'] == '/x/HQ/repos/private/widget-app' and t['last_activity'], t

        a = by['s-agent']
        assert a['kind'] == 'agent' and a['title'] == 'summarize the logs', a

        lane = by['s-lane']
        assert lane['kind'] == 'lane' and lane['title'] == 'conduct-charts-viz' and lane['company'] == 'acme', lane

        p = by['s-prompt']
        assert p['title'] == 'fix the export button' and p['kind'] == 'you' and p['company'] == 'other-co', p

        c = by['c-codex']
        assert c['title'] == 'Fix deploy script' and c['project'] == 'deploy-kit', c

        dump = json.dumps(rows)
        assert 'secret prompt text' not in dump and 'second line private' not in dump

    # Pure helpers.
    assert ls.prompt_summary('<ctx>\n\n  hello   world \nmore') == 'hello world'
    s = ls.prompt_summary('x' * 200)
    assert len(s) == ls.PROMPT_SUMMARY_CHARS and s.endswith('…')
    assert ls.classify_prompt('You are the HQ checkpoint sibling — a background agent for this\nHQ install. Work quietly.') == \
        ('HQ checkpoint sibling — a background agent for this HQ install', 'agent')
    assert ls.name_day('T-' + _ts('20261003', '101500') + '-x.json') == '2026-10-03'
    assert ls.repo_from_cwd('/x/HQ/repos/private/hq-desktop-app/a') == 'hq-desktop-app'
    print('ok')


if __name__ == '__main__':
    main()
