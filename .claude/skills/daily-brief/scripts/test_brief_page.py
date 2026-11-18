"""The brief page (brief_page.py): skeleton, candidates, validator and attach. No live services."""
import contextlib
import copy
import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import random
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


bp = load('brief_page', 'brief_page.py')
rank = load('brief_rank', 'brief_rank.py')
bg = load('brief_gate', 'brief_gate.py')

NOW = dt.datetime(2026, 10, 2, 12, 0, tzinfo=dt.timezone.utc)


def card(id, **kw):
    w = {'id': id, 'kind': 'stat', 'size': 'M', 'type': 'landed', 'symbol': 'git-merge', 'company': 'acme',
         'title': 'Ship the billing page', 'data': {}}
    w.update(kw)
    return w


def ball(id, **kw):
    w = card(id, kind='ball', type='dropped', symbol='hand-palm', title='Answer Ann about the memo',
             data={'hours': 30, 'usual': 4, 'people': [{'name': 'Ann', 'state': 'waiting'}], 'pickup': 'Reply to Ann'})
    w.update(kw)
    return w


def page(**kw):
    p = {'version': 1, 'companies': {'acme': {'name': 'Acme'}, 'beta': {'name': 'Beta'}, 'personal': {'name': 'Personal'}},
         'person': {'name': 'Sam'},
         'window': {'from': '2026-10-01T12:00:00+00:00', 'to': '2026-10-02T12:00:00+00:00', 'zoom': 'stretch',
                    'label': 'The last 24 hours', 'hoursAway': 24},
         'theme': {'style': 'merged'},
         'summary': [{'id': 'lead', 'kind': 'focus', 'size': 'XL', 'type': 'summary', 'symbol': 'sun-horizon',
                      'title': 'Billing is where people wait on you', 'data': {'headline': 'Billing waits on you', 'spark': [0, 1, 2],
                                                                                 'ticks': ['Fri morning', 'Sat night']}},
                     card('waiting', kind='people', type='ask', title='Two people wait on you',
                          data={'people': [{'name': 'Ann', 'state': 'waiting'}, {'name': 'Bo', 'state': 'waiting'}]}),
                     {'id': 'merged', 'kind': 'stat', 'size': 'S', 'type': 'landed', 'symbol': 'git-merge', 'title': 'Four shipped',
                      'data': {'value': 4, 'unit': 'merged'}},
                     {'id': 'red', 'kind': 'stat', 'size': 'S', 'type': 'broke', 'symbol': 'warning', 'title': 'One check is red',
                      'data': {'value': 1}}],
         'dropped': [ball('b1')],
         'stream': [card('s1', data={'value': 4, 'unit': 'merged', 'visual': 'stack'}),
                    card('s2', kind='ask', type='ask', company='beta', title='Review the pricing change',
                         data={'hours': 6, 'usual': 4, 'people': [{'name': 'Bo'}], 'visual': 'clock'},
                         drill={'signals': [{'source': 'pr', 'text': 'Pricing change ready'}], 'prompt': 'Open the PR'}),
                    card('s3', kind='note', type='decided', company='personal', title='Keep the old sign-in for now',
                         data={'from': 'New sign-in', 'to': 'Old sign-in'})]}
    p.update(kw)
    return p


def problems(p):
    return [e['where'] + ': ' + e['problem'] for e in bp.validate_page(p)['errors']]


class Validator(unittest.TestCase):
    def test_good_page(self):
        r = bp.validate_page(page())
        self.assertTrue(r['ok'], r['errors'])

    def test_needs_a_lead_first(self):
        p = page()
        p['summary'] = [card('x')]
        self.assertTrue(any('lead card' in e for e in problems(p)))
        p = page()
        p['summary'][-1] = card('xl2', kind='focus', size='XL', type='summary')
        out = problems(p)
        self.assertTrue(any('only the lead card is XL' in e for e in out))
        self.assertTrue(any('type summary is the lead card only' in e for e in out))

    def test_dropped_band_max_five(self):
        p = page(dropped=[ball(f'b{i}') for i in range(5)])
        self.assertTrue(bp.validate_page(p)['ok'], problems(p))
        p = page(dropped=[ball(f'b{i}') for i in range(6)])
        self.assertTrue(any('max 5' in e for e in problems(p)))

    def test_band_caps(self):
        p = page(stream=[card(f's{i}') for i in range(13)])
        self.assertTrue(any('max 12' in e for e in problems(p)))
        p = page()
        p['summary'] += [card(f'x{i}') for i in range(2)]
        self.assertTrue(any('max 4' in e for e in problems(p)))

    def test_dropped_ball_shape_and_pickup(self):
        p = page(dropped=[ball('b1', data={'hours': 3})])
        self.assertTrue(any('pick-up' in e for e in problems(p)))
        p = page(dropped=[ball('b1', kind='ask')])
        self.assertTrue(any('kind ball, type dropped' in e for e in problems(p)))
        p = page()
        p['stream'].append(ball('b9'))
        self.assertTrue(any('goes in the dropped band' in e for e in problems(p)))

    def test_one_meaning_per_colour(self):
        p = page()
        p['stream'][1]['field'] = 'teal'  # an ask is violet: your move
        self.assertTrue(any('means something else' in e for e in problems(p)))
        p['stream'][1]['field'] = 'violet'
        self.assertTrue(bp.validate_page(p)['ok'], problems(p))
        p['stream'][0]['field'] = 'pink'  # pink is dropped only
        self.assertTrue(any('means something else' in e for e in problems(p)))

    def test_merged_field(self):
        f = bp.merged_field
        self.assertEqual(f({'kind': 'focus', 'type': 'summary', 'data': {}}), 'dusk')
        self.assertEqual(f({'kind': 'ball', 'type': 'dropped', 'data': {}}), 'pink')
        self.assertEqual(f({'kind': 'note', 'type': 'broke', 'data': {}}), 'sunset')
        self.assertEqual(f({'kind': 'countdown', 'type': 'launch', 'data': {'days': 3}}), 'sunset')
        self.assertEqual(f({'kind': 'countdown', 'type': 'launch', 'data': {'days': 30}}), 'mono')
        self.assertEqual(f({'kind': 'countdown', 'type': 'task', 'data': {'days': 2}}), 'violet')
        self.assertEqual(f({'kind': 'ask', 'type': 'ask', 'data': {}}), 'violet')
        self.assertEqual(f({'kind': 'stat', 'type': 'learning', 'data': {}}), 'teal')
        self.assertEqual(f({'kind': 'stat', 'type': 'stalled', 'data': {}}), 'mono')

    def test_every_card_carries_a_known_company(self):
        p = page()
        del p['stream'][0]['company']
        self.assertTrue(any('every card carries its company' in e for e in problems(p)))
        p = page()
        p['stream'][0]['company'] = 'gamma'
        self.assertTrue(any("'gamma' is not in page.companies" in e for e in problems(p)))
        p = page()
        p['summary'][0]['company'] = 'acme'  # the lead may carry one, or none
        self.assertTrue(bp.validate_page(p)['ok'])
        # A count-only summary card may span companies; one that names people may not.
        p = page()
        self.assertNotIn('company', p['summary'][2])
        self.assertTrue(bp.validate_page(p)['ok'], problems(p))
        del p['summary'][1]['company']
        self.assertTrue(any('summary[1] waiting.company' in e for e in problems(p)))

    def test_drawing_must_hold_real_info(self):
        p = page()
        p['stream'][1]['data'] = {'people': [{'name': 'Bo'}], 'visual': 'clock'}  # a clock with no wait
        self.assertTrue(any('nothing real to draw' in e for e in problems(p)))
        p['stream'][1]['data']['visual'] = 'sparkle'
        self.assertTrue(any("unknown drawing 'sparkle'" in e for e in problems(p)))
        p['stream'][1]['data']['visual'] = 'harbor'  # draws landed stats, not asks
        self.assertTrue(any('draws' in e and 'not ask/ask' in e for e in problems(p)))
        p['stream'][1]['data']['visual'] = 'letters'  # one envelope per person waiting
        self.assertTrue(bp.validate_page(p)['ok'], problems(p))

    def test_family_caps_are_warnings(self):
        p = page(stream=[card(f's{i}', data={'value': 3, 'visual': 'harbor'}) for i in range(4)])
        r = bp.validate_page(p)
        self.assertTrue(r['ok'], r['errors'])
        found = sorted(w['problem'].split(';')[0] for w in r['warnings'])
        self.assertEqual(found, ['harbor is named three times', 'more than 3 pixel drawings'])

    def test_title_rule(self):
        p = page()
        p['stream'][0]['title'] = 'Merge #123 on the web app today please now ok'
        out = problems(p)
        self.assertTrue(any('PR number' in e for e in out))
        self.assertTrue(any('words (max 8)' in e for e in out))
        p['stream'][0]['title'] = 'feat(api): ship it'
        self.assertTrue(any('commit prefix' in e for e in problems(p)))

    def test_summary_band_fills_beside_the_lead(self):
        lead = page()['summary'][0]
        s = lambda size, i: {'id': f'x{i}', 'kind': 'stat', 'size': size, 'type': 'landed', 'symbol': 'x', 'title': 'Four shipped',
                             'data': {'value': 4}}
        for sizes, ok in [((), False), (('M',), False), (('M', 'S'), False), (('S', 'S', 'S'), False),
                          (('M', 'S', 'S'), True), (('M', 'M'), True), (('L',), True), (('S', 'M', 'S'), True), (('L', 'S'), False)]:
            p = page(summary=[lead] + [s(z, i) for i, z in enumerate(sizes)])
            self.assertEqual(bp.validate_page(p)['ok'], ok, (sizes, problems(p)))
        p = page(summary=[lead])
        self.assertTrue(any('fill 0 of its 4 cells' in e for e in problems(p)))

    def test_chart_labels_are_human(self):
        p = page()
        p['summary'][0]['data']['ticks'] = ['2026-10-26T15:15+00:00', 'Sat night']
        self.assertTrue(any('is a timestamp' in e for e in problems(p)))
        p = page()
        p['stream'][0]['hover'] = [{'kind': 'spark', 'values': [1, 2], 'ticks': ['10:00', '14:00']}]
        self.assertTrue(any('hover[0].ticks[0]' in e for e in problems(p)))

    def test_handle_looking_names_warn(self):
        p = page()
        p['stream'][1]['data']['people'] = [{'name': 'jdoe1234'}, {'name': 'Bo'}, {'name': 'helper', 'agent': True}]
        r = bp.validate_page(p)
        self.assertTrue(r['ok'], r['errors'])
        self.assertEqual([w['where'] for w in r['warnings']], ['stream[1] s2.data.people[0].name'])

    def test_tick_labels(self):
        tz = dt.timezone.utc
        a = dt.datetime(2026, 10, 23, 8, 0, tzinfo=tz)  # a Friday
        self.assertEqual(bp.tick_labels(a, a + dt.timedelta(hours=37), 4, tz),
                         ['Fri morning', 'Fri evening', 'Sat morning', 'Sat night'])
        # Night until 5 am belongs to the evening before.
        # 11 pm and 2 am are both Friday night, so the labels name the hour instead.
        self.assertEqual(bp.tick_labels(a.replace(hour=23), a.replace(hour=23) + dt.timedelta(hours=3), 2, tz),
                         ['Fri 11 pm', 'Sat 2 am'])
        short = bp.tick_labels(a.replace(hour=9), a.replace(hour=15), 3, tz)
        self.assertEqual(short, ['Fri 9 am', 'Fri 12 pm', 'Fri 3 pm'])
        self.assertEqual(bp.day_part(a.replace(hour=2))[1], 'night')
        self.assertEqual(bp.day_part(a.replace(hour=2))[0], dt.date(2026, 10, 22))
        for t in bp.tick_labels(a, a + dt.timedelta(hours=24), 4, tz):
            self.assertIsNone(bp._ISO_TICK.search(t))

    def test_person_name(self):
        self.assertEqual(bp.person_name('Ann', 'annlee99'), 'Ann')
        self.assertEqual(bp.person_name(None, 'Ann Lee'), 'Ann')
        self.assertEqual(bp.person_name(None, 'jdoe42'), 'jdoe42')  # nothing resolves: the handle
        self.assertEqual(bp.person_name(None, None), 'Someone')

    def test_drill_hover_and_data_shapes(self):
        p = page()
        p['stream'][1]['drill']['signals'].append({'source': 'slack', 'text': 'x'})
        p['stream'][1]['hover'] = [{'kind': 'chart'}]
        p['stream'][0]['data']['spark'] = [1, 'x']
        p['stream'][0]['data']['bets'] = [{'label': 'a', 'share': 2}]
        out = problems(p)
        for want in ('signals[1]', 'hover[0]', 'data.spark', 'data.bets[0]'):
            self.assertTrue(any(want in e for e in out), (want, out))

    def test_window_and_header(self):
        p = page()
        p['window']['zoom'] = 'week'
        p['version'] = 2
        del p['person']['name']
        out = problems(p)
        for want in ('window.zoom', 'version', 'person.name'):
            self.assertTrue(any(e.startswith(want) for e in out), (want, out))
        p = page()
        p['window']['zoom'] = 'arc'  # 24 hours away is the stretch: the app re-reads it, so a warning
        r = bp.validate_page(p)
        self.assertTrue(r['ok'])
        self.assertEqual(r['warnings'][0]['where'], 'window.zoom')

    def test_duplicate_ids(self):
        p = page()
        p['stream'].append(card('s1'))
        self.assertTrue(any("duplicate id 's1'" in e for e in problems(p)))

    def test_not_a_page(self):
        self.assertFalse(bp.validate_page(None)['ok'])
        self.assertFalse(bp.validate_page({'version': 1})['ok'])

    def test_zoom_for(self):
        self.assertEqual([bp.zoom_for(h) for h in (0, 17.9, 18, 72, 72.1)], ['today', 'today', 'stretch', 'stretch', 'arc'])

    def test_recipe_ids_match_the_app_library(self):
        # The app's RECIPES (packages/ui/src/brief/widgets/visuals/index.ts), round 9.
        app = {'bell', 'book', 'fork', 'agenda', 'trace', 'tally', 'compare', 'checklist', 'sparkline', 'letters', 'clock',
               'track', 'stack', 'siren', 'harbor', 'tide', 'train', 'garden', 'mailbox', 'fuse', 'dawn', 'switch', 'weather',
               'lighthouse', 'skyline', 'constellation', 'dial', 'breaker', 'lock', 'drawers', 'scale', 'rocket'}
        self.assertEqual(set(bp.RECIPES), app)


def brief_data():
    sec = lambda **kw: dict({'window': {'sessions_from': '2026-10-01T12:00:00+00:00', 'sessions_to': '2026-10-02T12:00:00+00:00',
                                        'prs_from': '2026-10-01T12:00:00+00:00', 'prs_to': '2026-10-02T12:00:00+00:00'},
                             'prs': [], 'dms': [], 'main_health': {}, 'meetings': [], 'meeting_signals': [], 'fleet': None}, **kw)
    return {
        'mode': 'person', 'company': None,
        'window': {'sessions_from': '2026-10-01T12:00:00+00:00', 'sessions_to': '2026-10-02T12:00:00+00:00',
                   'prs_from': '2026-10-01T12:00:00+00:00', 'prs_to': '2026-10-02T12:00:00+00:00'},
        'previous_run': {'run_id': 'r0', 'generated_at': '2026-09-30T12:00:00+00:00'},
        'personal': sec(dms=[{'from': 'Di', 'from_uid': 'prs_d', 'is_agent': False, 'need_you': True,
                              'at': '2026-10-02T10:00:00Z', 'preview': 'dinner on friday?', 'company_basis': None}]),
        'companies': {
            'acme': sec(
                dms=[{'from': 'Ann', 'from_uid': 'prs_a', 'is_agent': False, 'need_you': True, 'at': '2026-10-01T06:00:00Z',
                      'preview': 'can you look at the memo?', 'company_basis': 'sender', 'company': 'acme'},
                     {'from': 'Ann', 'from_uid': 'prs_a', 'is_agent': False, 'need_you': True, 'at': '2026-10-01T09:00:00Z',
                      'preview': 'ping', 'company_basis': 'sender', 'company': 'acme'},
                     {'from': 'Bot', 'from_uid': 'agt_x', 'is_agent': True, 'need_you': True, 'at': '2026-10-02T09:00:00Z',
                      'preview': 'please approve', 'company': 'acme'}],
                prs=[{'repo': 'web', 'repo_full': 'acme-org/web', 'product': 'Web app', 'number': 7, 'title': 'Add billing page',
                      'state': 'merged', 'created': '2026-10-01T13:00:00Z', 'closed': '2026-10-02T08:00:00Z', 'authored_by_me': True,
                      'company': 'acme'},
                     {'repo': 'web', 'repo_full': 'acme-org/web', 'product': 'Web app', 'number': 8, 'title': 'Fix login',
                      'state': 'merged', 'created': '2026-10-01T13:00:00Z', 'closed': '2026-10-02T11:00:00Z', 'authored_by_me': True,
                      'company': 'acme'},
                     {'repo': 'api', 'repo_full': 'acme-org/api', 'product': 'API', 'number': 9, 'title': 'Rate limits',
                      'state': 'open', 'created': '2026-10-01T02:00:00Z', 'closed': None, 'authored_by_me': False,
                      'review_requested': True, 'author': 'bo', 'company': 'acme'}],
                main_health={'api': {'product': 'API', 'red': [{'workflow': 'CI', 'since': '2026-10-02T06:00:00Z', 'merges_on_top': 2}]}}),
            'beta': {'error': "Could not collect this company's work. Try again later."},
        }}


class Skeleton(unittest.TestCase):
    def test_frame(self):
        p = bp.skeleton(brief_data(), 'Sam', NOW, {'acme': 'Acme Inc'}, tz=dt.timezone.utc)
        self.assertEqual(p['companies'], {'personal': {'name': 'Personal'}, 'acme': {'name': 'Acme Inc'}})
        self.assertEqual(p['window']['hoursAway'], 48.0)  # since the previous brief
        self.assertEqual(p['window']['zoom'], 'stretch')
        self.assertEqual(p['window']['from'], '2026-09-30T12:00:00+00:00')
        lead = p['summary'][0]
        self.assertEqual((lead['kind'], lead['size'], lead['type']), ('focus', 'XL', 'summary'))
        # The lead is about the person's day: their meetings and the people waiting on them
        # in DMs. Merges, review requests and CI stay out of it.
        self.assertEqual(lead['data']['stats'], [{'value': 0, 'label': 'your meetings'}, {'value': 2, 'label': 'waiting on you'}])
        self.assertEqual(lead['data']['sparkLabel'], 'your day')
        self.assertEqual(lead['data']['spark'], [0, 0, 2, 0, 0, 1])  # Ann's two asks, Di's ask; never the merges
        self.assertEqual(lead['data']['ticks'], ['Wed afternoon', 'Wed night', 'Thu evening', 'Fri afternoon'])
        self.assertEqual((p['dropped'], p['stream']), ([], []))
        side = p['summary'][1:]
        # No broken or merged counts beside the lead.
        self.assertEqual([(w['id'], w['size']) for w in side], [('waiting', 'L')])
        self.assertEqual(side[0]['company'], 'acme')
        # bo is a login nothing resolves, so the handle stays (and the validator warns).
        self.assertEqual(sorted(x['name'] for x in side[0]['data']['people']), ['Ann', 'bo'])

    def test_lead_counts_own_meetings_and_todos(self):
        data = brief_data()
        acme = data['companies']['acme']
        acme['meetings'] = [{'title': 'Pricing review', 'start': '2026-10-02T09:00:00Z', 'attended': True},
                            {'title': 'Team sync', 'start': '2026-10-02T10:00:00Z', 'attended': False}]
        acme['meeting_signals'] = [{'title': 'Pricing review', 'start': '2026-10-02T09:00:00Z',
                                    'action_items': [{'text': 'Send the price sheet', 'mine': True},
                                                     {'text': 'Book the room', 'mine': False}]}]
        p = bp.skeleton(data, 'Sam', NOW, {'acme': 'Acme Inc'}, tz=dt.timezone.utc)
        lead = p['summary'][0]
        self.assertEqual(lead['data']['stats'], [{'value': 1, 'label': 'your meetings'}, {'value': 2, 'label': 'waiting on you'},
                                                 {'value': 1, 'label': 'to-dos for you'}])
        self.assertEqual(sum(lead['data']['spark']), 4)  # 3 asks + the one meeting that was the person's
        side = p['summary'][1:]
        self.assertEqual([(w['id'], w['size']) for w in side], [('waiting', 'M'), ('todos', 'S'), ('meetings', 'S')])
        self.assertEqual(side[2]['data'], {'value': 1, 'unit': 'your meetings'})
        mtg = next(c for c in bp.candidates(data, NOW) if c['type'] == 'meeting')
        self.assertEqual(mtg['facts'], {'meetings': 1, 'team_meetings': 1})

    def test_summary_side_sizes(self):
        mk = lambda t, **d: {'type': t, 'company': 'a', 'rank': 1, 'data': dict(d), 'drill': {'signals': []}}
        ask = mk('ask', people=[{'name': 'Ann'}], hours=3)
        sizes = lambda cs: [w['size'] for w in bp.summary_side(cs, {})]
        self.assertEqual(sizes([ask]), ['L'])
        self.assertEqual(sizes([ask, mk('task')]), ['M', 'M'])
        self.assertEqual(sizes([ask, mk('task'), mk('meeting', value=2)]), ['M', 'S', 'S'])
        self.assertEqual(sizes([mk('task'), mk('meeting', value=2)]), ['M', 'M'])
        self.assertEqual(sizes([mk('meeting', value=2)]), ['L'])
        self.assertEqual(sizes([]), [])
        # Broken builds, unreviewed PRs and merges never take a summary cell.
        self.assertEqual(sizes([ask, mk('broke'), mk('stalled'), mk('landed', value=2)]), ['L'])
        self.assertEqual(sizes([mk('broke'), mk('stalled'), mk('landed', value=2)]), [])
        # Two asks from one person are one row, at their longest wait.
        two = [mk('ask', people=[{'name': 'Ann', 'hours': 3}], hours=3), mk('ask', people=[{'name': 'Ann', 'hours': 9}], hours=9)]
        w = bp.summary_side(two, {})[0]
        self.assertEqual((w['data']['people'], w['data']['value']), ([{'name': 'Ann', 'hours': 9}], 1))

    def test_merge_spark_buckets(self):
        prs = [{'state': 'merged', 'closed': '2026-10-01T12:30:00Z'}, {'state': 'merged', 'closed': '2026-10-02T12:00:00Z'},
               {'state': 'merged', 'closed': '2026-09-01T00:00:00Z'}, {'state': 'open', 'closed': None},
               {'state': 'merged', 'closed': '2026-10-02T00:00:00Z', 'authored_by_me': False}]
        self.assertEqual(bp.merge_spark(prs, '2026-10-01T12:00:00Z', '2026-10-02T12:00:00Z'), [1, 0, 0, 0, 0, 1])

    def test_candidates_carry_company_and_computed_facts(self):
        cands = bp.candidates(brief_data(), NOW)
        by = {(c['company'], c['type'], c['kind']): c for c in cands}
        asks = [c for c in cands if c['type'] == 'ask']
        names = sorted((c['company'], c['data']['people'][0]['name']) for c in asks)
        self.assertEqual(names, [('acme', 'Ann'), ('acme', 'bo'), ('personal', 'Di')])  # the agent is not a person waiting
        ann = next(c for c in asks if c['data']['people'][0]['name'] == 'Ann')
        self.assertEqual(ann['data']['hours'], 30.0)  # from the first message
        self.assertTrue(ann['dropped_candidate'])
        self.assertEqual(ann['basis'], 'sender')
        self.assertEqual(len(ann['drill']['signals']), 2)
        landed = by[('acme', 'landed', 'stat')]
        self.assertEqual(landed['data']['value'], 2)
        self.assertEqual(landed['data']['visual'], 'stack')
        broke = by[('acme', 'broke', 'stat')]
        self.assertEqual((broke['data']['value'], broke['data']['hours'], broke['data']['visual']), (2, 6.0, 'siren'))
        # Only cards one recipe clearly carries get a suggested drawing; asks are left to the app's picker.
        self.assertTrue(all('visual' not in c['data'] for c in asks))
        self.assertTrue(all(c['company'] in ('acme', 'personal') for c in cands))  # the failed company has none
        self.assertEqual(len({c['id'] for c in cands}), len(cands))
        # Ranked: cards about people first (dropped balls by longest wait, then other asks),
        # then PR and CI cards, even a review request that has waited a day.
        self.assertEqual([(c['type'], c.get('dropped_candidate', False), bp.is_code_card(c)) for c in cands],
                         [('ask', True, False), ('ask', False, False), ('ask', True, True), ('broke', False, True),
                          ('landed', False, True)])
        self.assertEqual([c['id'] for c in cands], [f'c{i + 1}' for i in range(len(cands))])
        hours = [c['data']['hours'] for c in cands if c.get('dropped_candidate') and not bp.is_code_card(c)]
        self.assertEqual(hours, sorted(hours, reverse=True))
        self.assertLess(next(i for i, c in enumerate(cands) if c['type'] == 'broke'),
                        next(i for i, c in enumerate(cands) if c['type'] == 'landed'))

    def test_candidate_names_use_resolved_display_names(self):
        data = brief_data()
        data['companies']['acme']['dms'][0]['from'] = 'annlee77'
        data['companies']['acme']['dms'][0]['from_name'] = 'Ann'
        data['companies']['acme']['prs'][2]['author_name'] = 'Bo'
        names = sorted(c['data']['people'][0]['name'] for c in bp.candidates(data, NOW) if c['type'] == 'ask')
        self.assertEqual(names, ['Ann', 'Bo', 'Di'])

    def test_suggested_drawing_dropped_when_it_has_nothing_to_draw(self):
        data = brief_data()
        data['companies']['acme']['main_health']['api']['red'][0].update(merges_on_top=0, since=None)
        broke = next(c for c in bp.candidates(data, NOW) if c['type'] == 'broke')
        self.assertNotIn('visual', broke['data'])
        self.assertNotIn('hours', broke['data'])

    def test_writer_page_from_skeleton_validates(self):
        """A page built the way SKILL.md says (skeleton + candidates + titles) passes the check."""
        data = brief_data()
        p = bp.skeleton(data, 'Sam', NOW, {'acme': 'Acme Inc'})
        p['summary'][0]['title'] = 'Billing is where people wait on you'
        for w in p['summary'][1:]:
            w['title'] = 'People wait on you'
        cands = bp.candidates(data, NOW)
        titles = {'ask': 'Answer the open question', 'landed': 'Two changes shipped', 'broke': 'Fix the red checks'}
        for c in cands:
            w = {k: copy.deepcopy(c[k]) for k in ('company', 'type', 'kind', 'size', 'symbol', 'data', 'drill')}
            w['id'] = c['id']
            w['title'] = titles[c['type']]
            if c.get('dropped_candidate') and len(p['dropped']) < bp.DROPPED_MAX:
                w.update(kind='ball', type='dropped')
                w['data']['pickup'] = 'Reply now'
                p['dropped'].append(w)
            else:
                p['stream'].append(w)
        r = bp.validate_page(p)
        self.assertTrue(r['ok'], r['errors'])


JUNK = [None, 0, -1, 2.5, True, '', 'x', [], [1, 'a'], {}, {'a': 1}, [[]], [{}], float('nan')]


def _paths(o, pre=()):
    yield pre
    if isinstance(o, dict):
        for k, v in o.items():
            yield from _paths(v, pre + (k,))
    elif isinstance(o, list):
        for i, v in enumerate(o):
            yield from _paths(v, pre + (i,))


def _mutate(obj, rnd, times):
    for _ in range(times):
        where = rnd.choice([p for p in _paths(obj) if p])
        o = obj
        for k in where[:-1]:
            o = o[k]
        o[where[-1]] = copy.deepcopy(rnd.choice(JUNK))
    return obj


class Robustness(unittest.TestCase):
    """Malformed input is rejected with a reason, never raised (review of PR 1704)."""

    def test_reported_crashes_are_rejections(self):
        cases = [('stream', 0, 'data', 'visual', ['stack'], 'data.visual'),
                 ('summary', 0, 'data', 'bets', 3, 'data.bets'),
                 ('stream', 0, 'data', 'steps', 3, 'data.steps'),
                 ('stream', 0, None, 'size', ['M'], '.size')]
        for band, i, sub, key, value, want in cases:
            p = page()
            (p[band][i][sub] if sub else p[band][i])[key] = value
            r = bp.validate_page(p)
            self.assertFalse(r['ok'], key)
            self.assertTrue(any(want in e['where'] for e in r['errors']), (key, r['errors']))
            self.assertFalse(any('malformed' in e['problem'] for e in r['errors']), r['errors'])

    def test_fuzzed_pages_never_raise(self):
        rnd = random.Random(1704)
        for _ in range(1500):
            r = bp.validate_page(_mutate(page(), rnd, rnd.randint(1, 3)))
            self.assertIsInstance(r['ok'], bool)
            # Every shape is handled by an explicit check, not by the last-resort catch.
            self.assertFalse([e for e in r['errors'] if 'malformed' in e['problem']], r['errors'])
        for junk in JUNK + [[page()], 'page']:
            self.assertFalse(bp.validate_page(copy.deepcopy(junk))['ok'])

    def test_fuzzed_brief_data_never_raises(self):
        rnd = random.Random(27)
        for _ in range(800):
            data = _mutate(brief_data(), rnd, rnd.randint(1, 3))
            cands = bp.candidates(data, NOW)
            bp.skeleton(data, 'Sam', NOW, {}, cands, tz=dt.timezone.utc)
        for junk in JUNK:
            self.assertEqual(bp.candidates(copy.deepcopy(junk), NOW), [])

    def test_fleet_shapes(self):
        for fleet in ('down', 3, ['x'], {'stuck': 'x'}, {'stuck': ['agent', None, {'name': 'a', 'status': 'error'}]}):
            data = brief_data()
            data['companies']['acme']['fleet'] = fleet
            stuck = [c for c in bp.candidates(data, NOW) if c['symbol'] == 'robot']
            self.assertEqual(len(stuck), 1 if isinstance(fleet, dict) and isinstance(fleet['stuck'], list) else 0)

    def test_attach_and_rank_never_raise(self):
        brief = {'run_id': 'r', 'items': {}}
        for bad in (None, 'page', [1], {'version': 1, 'summary': 'x'}):
            out, r = bp.attach(dict(brief), bad)
            self.assertNotIn('page', out)
            self.assertTrue(out['page_problems'])
            self.assertTrue(rank.check_brief({'mode': 'personal', 'items': {}, 'page': bad})['page_problems'])
        # Even if the validator itself raised, attach and --check record it instead.
        with patch.object(bp, '_validate', side_effect=RuntimeError('boom')):
            out, _ = bp.attach(dict(brief), page())
        self.assertIn('malformed page', out['page_problems'][0]['problem'])


class Attach(unittest.TestCase):
    BRIEF = {'run_id': 'r1', 'items': {'decisions': []}, 'lead_hint': 'x', 'page_problems': [{'old': 1}]}

    def test_attach_valid_keeps_every_field(self):
        out, r = bp.attach(copy.deepcopy(self.BRIEF), page())
        self.assertTrue(r['ok'])
        self.assertEqual(out['page']['version'], 1)
        self.assertNotIn('page_problems', out)
        for k in ('run_id', 'items', 'lead_hint'):
            self.assertEqual(out[k], self.BRIEF[k])

    def test_attach_invalid_fails_soft(self):
        brief = dict(copy.deepcopy(self.BRIEF), page={'stale': True})
        bad = page(dropped=[ball(f'b{i}') for i in range(6)])
        out, r = bp.attach(brief, bad)
        self.assertFalse(r['ok'])
        self.assertNotIn('page', out)
        self.assertTrue(out['page_problems'])
        self.assertEqual(out['items'], self.BRIEF['items'])

    def test_cli_attach_check_and_skeleton(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / 'brief.json').write_text(json.dumps(self.BRIEF))
            (d / 'page.json').write_text(json.dumps(page()))
            (d / 'bad.json').write_text(json.dumps(page(summary=[])))
            (d / 'brief-data.json').write_text(json.dumps(brief_data()))
            err = io.StringIO()
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
                self.assertEqual(bp.main(['check', str(d / 'page.json')]), 0)
                self.assertEqual(bp.main(['check', str(d / 'bad.json')]), 1)
                self.assertEqual(bp.main(['attach', '--brief', str(d / 'brief.json'), '--page', str(d / 'bad.json')]), 0)
                self.assertNotIn('page', json.loads((d / 'brief.json').read_text()))
                self.assertIn('[page] left out of brief.json', err.getvalue())
                self.assertEqual(bp.main(['attach', '--brief', str(d / 'brief.json'), '--page', str(d / 'page.json')]), 0)
                self.assertEqual(json.loads((d / 'brief.json').read_text())['page']['person']['name'], 'Sam')
                self.assertEqual(bp.main(['attach', '--brief', str(d / 'brief.json'), '--page', str(d / 'missing.json')]), 0)
                self.assertNotIn('page', json.loads((d / 'brief.json').read_text()))
                self.assertEqual(bp.main(['skeleton', '--data', str(d / 'brief-data.json'), '--out', str(d / 'draft.json'),
                                          '--person', 'Sam', '--now', NOW.isoformat(), '--hq-root', str(d)]), 0)
            draft = json.loads((d / 'draft.json').read_text())
            self.assertEqual(draft['page']['person']['name'], 'Sam')
            self.assertTrue(draft['candidates'])

    def test_brief_rank_reports_page_problems(self):
        brief = {'mode': 'personal', 'items': {}, 'today': '2026-10-02', 'page': page(summary=[])}
        self.assertTrue(rank.check_brief(brief)['page_problems'])
        brief['page'] = page()
        self.assertEqual(rank.check_brief(brief)['page_problems'], [])
        self.assertEqual(rank.check_brief({'mode': 'personal', 'items': {}})['page_problems'], [])
        person = {'mode': 'person', 'personal': {}, 'companies': {}, 'page': page(summary=[])}
        self.assertTrue(rank.check_brief(person)['page_problems'])


STALE_LINE = ("Signals are stale: today's signals run could not sign in to a connected account. This brief uses signals "
              "from the last good run on Oct 1. Sign in again to clear it.")
TRY_NOW_LINE = 'Sign in again, then press Try now to re-run signals and rebuild the brief.'
STALE_LABEL = 'From the last good signals run on Oct 1, not from today.'
NO_RUN_LABEL = 'No good signals run was found, so these signals may be out of date.'
AUTH = "today's signals run could not sign in to a connected account"
TIMED_OUT = "today's signals run did not finish within 20 minutes and is still going"


def short(good):
    """The date as the gate writes it into sentences (the page's year is 2026)."""
    return bg.human_date(good, '2026-10-02')


def stale_entry(good='2026-10-01', code='auth', reason=AUTH):
    line = STALE_LINE.replace(AUTH, reason)
    if good:
        line = line.replace('Oct 1', short(good))
    else:
        line = line.replace('This brief uses signals from the last good run on Oct 1.',
                            'No earlier good signals run was found.')
    return {'code': code, 'reason': reason,
            'last_good_run': {'date': good, 'finished_at': f'{good}T13:05:00Z'} if good else None,
            'try_now': True, 'line': line, 'try_now_line': TRY_NOW_LINE,
            'section_line': STALE_LABEL.replace('Oct 1', short(good)) if good else NO_RUN_LABEL}


def stale_data(good='2026-10-01', stale=True, beta=None):
    """brief_data() with a to-do from a meeting signal in acme, and acme's signals stale.

    `beta` adds a second company with the same to-do and no asks: 'fresh' (signals not
    stale), or a stale_entry() for it."""
    data = brief_data()
    todo = [{'title': 'Weekly planning', 'start': '2026-10-02T09:00:00Z',
             'action_items': [{'text': 'Send the budget', 'mine': True, 'source_ref': 'sources/meeting-events/e1.md'}]}]
    data['companies']['acme']['meeting_signals'] = copy.deepcopy(todo)
    data['companies']['acme']['signals_stale'] = stale_entry(good) if stale else None
    if beta is not None:
        sec = copy.deepcopy(data['companies']['acme'])
        sec.update(dms=[], prs=[], main_health={}, meeting_signals=copy.deepcopy(todo),
                   signals_stale=None if beta == 'fresh' else beta)
        data['companies']['beta'] = sec
    return data


NAMES = {'acme': 'Acme Inc', 'beta': 'Beta Co'}


def written_page(data):
    """A page the way the writer builds it: the frame, plus every candidate as a stream card."""
    p = bp.skeleton(data, 'Sam', NOW, NAMES)
    p['summary'][0]['title'] = 'Billing is where people wait on you'
    for w in p['summary'][1:]:
        w['title'] = w['title'] or 'People wait on you'
    titles = {'ask': 'Answer the open question', 'landed': 'Two changes shipped', 'broke': 'Fix the red checks',
              'task': 'Send the budget'}
    for c in bp.candidates(data, NOW)[:bp.STREAM_MAX]:
        w = {k: copy.deepcopy(c[k]) for k in ('company', 'type', 'kind', 'size', 'symbol', 'data', 'drill')}
        w.update(id=c['id'], title=titles[c['type']])
        p['stream'].append(w)
    return p


def written_page_at(data, now):
    """written_page for a brief whose window ends at `now`: a company brief's frame and its to-do."""
    p = bp.skeleton(data, 'Sam', now, NAMES)
    p['summary'][0]['title'] = 'Billing is where people wait on you'
    for w in p['summary'][1:]:
        w['title'] = w['title'] or 'People wait on you'
    for c in bp.candidates(data, now):
        if c['type'] == 'task':
            w = {k: copy.deepcopy(c[k]) for k in ('company', 'type', 'kind', 'size', 'symbol', 'data', 'drill')}
            w.update(id=c['id'], title='Send the budget')
            p['stream'].append(w)
    return p


def all_cards(p):
    return [w for band in ('summary', 'dropped', 'stream') for w in p[band]]


def notice_cards(p):
    return [w for w in all_cards(p) if str(w.get('id')).startswith('signals-stale')]


def closed_text(p):
    """What the app draws on closed cards: each card's corner tag (label) and title."""
    return ' | '.join(f"{w.get('label', '')} {w.get('title', '')}" for w in all_cards(p))


class StaleSignalsPage(unittest.TestCase):
    """The page shows stale signals: a notice card per stale company at the top, and each of that
    company's signal cards labelled or left out. What a closed card shows is its tag and title."""

    def test_frame_puts_the_companys_notice_card_first_beside_the_lead(self):
        p = bp.skeleton(stale_data(), 'Sam', NOW, NAMES)
        notice = p['summary'][1]
        self.assertEqual((notice['id'], notice['kind'], notice['type'], notice['symbol'], notice['company']),
                         ('signals-stale-acme', 'note', 'broke', 'warning', 'acme'))
        # The closed card: the tag and a title that carries the last good run's date.
        self.assertEqual((notice['label'], notice['title']),
                         ('Stale signals', 'Last updated Oct\u00a01 ·\u00a0Acme\u00a0Inc'))
        # Opened: stale and since when first, then the reason in few words; no company name.
        self.assertEqual(notice['why'], 'Acme Inc: sign-in to a connected account failed.')
        self.assertEqual([(w['id'], w['size']) for w in p['summary'][1:]],
                         [('signals-stale-acme', 'M'), ('waiting', 'M')])
        self.assertNotIn('to-dos for you', [x['label'] for x in p['summary'][0]['data']['stats']])

    def test_written_page_has_the_notice_and_the_label_and_validates(self):
        data = stale_data()
        brief, r = bp.attach({'run_id': 'r1'}, written_page(data), data)
        self.assertTrue(r['ok'], r['errors'])
        p = brief['page']
        self.assertIn('Stale signals Last updated Oct\u00a01 ·\u00a0Acme\u00a0Inc', closed_text(p))
        self.assertIn('From Oct 1 Send the budget', closed_text(p))
        self.assertEqual(p['summary'][1]['id'], 'signals-stale-acme')
        tasks = [w for w in all_cards(p) if w['type'] == 'task']
        self.assertEqual(len(tasks), 1)
        self.assertEqual((tasks[0]['label'], tasks[0]['why']), ('From Oct 1', STALE_LABEL))
        # A card that does not come from signals carries neither the tag nor the sentence.
        others = [w for w in all_cards(p) if w['type'] != 'task' and not str(w['id']).startswith('signals-stale')]
        self.assertTrue(others)
        self.assertFalse([w for w in others if 'label' in w or STALE_LABEL in (w.get('why') or '')])

    def test_page_without_stale_signals_has_neither_the_notice_nor_the_label(self):
        data = stale_data(stale=False)
        frame = bp.skeleton(data, 'Sam', NOW, NAMES)
        brief, r = bp.attach({'run_id': 'r1'}, written_page(data), data)
        self.assertTrue(r['ok'], r['errors'])
        self.assertFalse(r['fallback'])
        for p in (frame, brief['page']):
            text = json.dumps(p)
            for absent in ('Signals are stale', 'Signals stale', 'Stale signals', 'Signals from', 'From Oct', 'Stale since',
                           'stale since', 'last updated', 'cards left out', 'No signals yet', 'signal cards',
                           'last good', 'signals-stale'):
                self.assertNotIn(absent, text)
        self.assertEqual(brief['signals_notices'], [])
        self.assertIn('to-dos for you', [x['label'] for x in frame['summary'][0]['data']['stats']])
        self.assertTrue([w for w in all_cards(brief['page']) if w['type'] == 'task'])
        self.assertNotIn('signals_from', json.dumps(bp.candidates(data, NOW)))

    def test_with_no_good_run_signal_cards_are_left_out_and_the_notice_says_so(self):
        data = stale_data(good=None)
        self.assertFalse([c for c in bp.candidates(data, NOW) if c['type'] == 'task'])
        # A writer that adds a to-do card anyway: attach removes it.
        p = written_page(data)
        p['stream'].append(card('t9', kind='note', type='task', symbol='list-checks', title='Send the budget',
                                data={'hours': 3}, drill={'signals': [{'source': 'meeting', 'text': 'Send the budget'}]}))
        brief, r = bp.attach({'run_id': 'r1'}, p, data)
        self.assertTrue(r['ok'], r['errors'])
        self.assertFalse([w for w in all_cards(brief['page']) if w['type'] == 'task'])
        notice = brief['page']['summary'][1]
        self.assertEqual(notice['title'], 'No signals yet ·\u00a0Acme\u00a0Inc')
        self.assertEqual(notice['why'], 'No run has finished yet, so signal cards are hidden. Sign-in failed.')
        for absent in ('last good run', 'Signals from', 'From Oct', 'Stale since', 'since Oct', 'last updated'):
            self.assertNotIn(absent, json.dumps(brief['page']))

    def test_one_stale_company_and_one_fresh_only_the_stale_one_is_marked(self):
        for good, title in (('2026-10-01', 'Last updated Oct\u00a01 ·\u00a0Acme\u00a0Inc'),
                            (None, 'No signals yet ·\u00a0Acme\u00a0Inc')):
            data = stale_data(good=good, beta='fresh')
            brief, r = bp.attach({'run_id': 'r1'}, written_page(data), data)
            self.assertTrue(r['ok'], r['errors'])
            p = brief['page']
            # One notice card, for acme, under acme's badge; nothing says beta is stale.
            self.assertEqual([(w['id'], w['company'], w['title']) for w in notice_cards(p)],
                             [('signals-stale-acme', 'acme', title)])
            # The notice names its company in words, in the title and in the opened text, and
            # names no other company.
            self.assertNotIn('Beta', json.dumps(notice_cards(p)[0]))
            self.assertTrue(notice_cards(p)[0]['title'].endswith(' ·\u00a0Acme\u00a0Inc'))
            # The opened text names it unless the title does (the never-good case).
            self.assertTrue(notice_cards(p)[0]['why'].startswith('Acme Inc: ') if good
                            else notice_cards(p)[0]['why'] == 'No run has finished yet, so signal cards are hidden. Sign-in failed.')
            self.assertNotIn("Acme Inc's", json.dumps(notice_cards(p)[0]))
            # beta's fresh to-do is shown exactly as written: no tag, no sentence.
            beta_tasks = [w for w in all_cards(p) if w['type'] == 'task' and w['company'] == 'beta']
            self.assertEqual(len(beta_tasks), 1)
            self.assertNotIn('label', beta_tasks[0])
            self.assertNotIn('why', beta_tasks[0])
            # acme's to-do is labelled with its date, or left out when acme has no good run.
            acme_tasks = [w for w in all_cards(p) if w['type'] == 'task' and w['company'] == 'acme']
            self.assertEqual([w.get('label') for w in acme_tasks], ['From Oct 1'] if good else [])
            self.assertEqual([n['company'] for n in brief['signals_notices']], ['acme'])

    def test_two_stale_companies_each_get_their_own_card_reason_and_date(self):
        data = stale_data(beta=stale_entry(good='2026-09-20', code='timed-out', reason=TIMED_OUT))
        brief, r = bp.attach({'run_id': 'r1'}, written_page(data), data)
        self.assertTrue(r['ok'], r['errors'])
        p = brief['page']
        acme, beta = p['summary'][1], p['summary'][2]
        self.assertEqual([w['id'] for w in p['summary']], ['lead', 'signals-stale-acme', 'signals-stale-beta'])
        self.assertEqual((acme['company'], acme['size'], acme['title']),
                         ('acme', 'M', 'Last updated Oct\u00a01 ·\u00a0Acme\u00a0Inc'))
        self.assertEqual((beta['company'], beta['size'], beta['title']),
                         ('beta', 'M', 'Last updated Sep\u00a020 ·\u00a0Beta\u00a0Co'))
        self.assertEqual(acme['why'], 'Acme Inc: sign-in to a connected account failed.')
        self.assertEqual(beta['why'], "Beta Co: today's signals run has not finished yet.")
        labels = {w['company']: (w['label'], w['why']) for w in all_cards(p) if w['type'] == 'task'}
        self.assertEqual(labels, {'acme': ('From Oct 1', STALE_LABEL),
                                  'beta': ('From Sep 20', STALE_LABEL.replace('Oct 1', 'Sep 20'))})
        # No company's notice or date sits on another company's card.
        for w in all_cards(p):
            if w.get('company') == 'acme':
                self.assertNotIn('Sep', json.dumps(w))
                self.assertNotIn('Beta', json.dumps(w))
            if w.get('company') == 'beta':
                self.assertNotIn('Oct', json.dumps(w))
                self.assertNotIn('Acme', json.dumps(w))

    def test_one_stale_with_a_date_and_one_with_no_good_run(self):
        data = stale_data(good=None, beta=stale_entry(good='2026-09-20'))
        brief, r = bp.attach({'run_id': 'r1'}, written_page(data), data)
        self.assertTrue(r['ok'], r['errors'])
        p = brief['page']
        self.assertEqual({w['company']: w['title'] for w in notice_cards(p)},
                         {'acme': 'No signals yet ·\u00a0Acme\u00a0Inc',
                          'beta': 'Last updated Sep\u00a020 ·\u00a0Beta\u00a0Co'})
        # What each card says is what happened: acme's to-do is gone, beta's is shown with its date.
        self.assertEqual([(w['company'], w['label']) for w in all_cards(p) if w['type'] == 'task'],
                         [('beta', 'From Sep 20')])

    def test_more_stale_companies_than_fit_beside_the_lead_go_to_the_head_of_the_stream(self):
        data = stale_data(beta=stale_entry(good='2026-09-20'))
        for slug in ('cyan', 'delta'):
            data['companies'][slug] = copy.deepcopy(data['companies']['beta'])
        p = bp.skeleton(data, 'Sam', NOW, NAMES)
        self.assertEqual([(w['id'], w['size']) for w in p['summary'][1:]],
                         [('signals-stale-acme', 'M'), ('signals-stale-beta', 'S'), ('signals-stale-cyan', 'S')])
        self.assertEqual([w['id'] for w in p['stream']], ['signals-stale-delta'])
        p['summary'][0]['title'] = 'Billing is where people wait on you'
        self.assertTrue(bp.validate_page(p)['ok'], bp.validate_page(p)['errors'])

    def test_attach_restores_a_notice_the_writer_dropped_or_changed(self):
        data = stale_data()
        want = bp.attach({}, written_page(data), data)[0]['page']
        dropped = written_page(data)
        dropped['summary'] = [dropped['summary'][0], card('x1', size='L', title='Four changes shipped')]
        edited = written_page(data)
        edited['summary'][1].update(title='All signals are fresh', why='Nothing to see', size='S', label='Fresh')
        edited['summary'].append(card('x2', size='S', title='One more count', company=None, data={'value': 1}))
        moved = written_page(data)
        moved['stream'].insert(0, moved['summary'].pop(1))
        for p in (dropped, edited, moved):
            brief, r = bp.attach({}, p, data)
            self.assertTrue(r['ok'], r['errors'])
            got = brief['page']['summary']
            self.assertEqual(got[1], want['summary'][1])
            self.assertEqual(sum(bp.SIZE_CELLS[w['size']] for w in got[1:]), bp.BESIDE_LEAD)
            self.assertEqual(len(notice_cards(brief['page'])), 1)
        # Applying the notice again changes nothing.
        self.assertEqual(bp.apply_notices(want, bp.stale_notices(data), bp.notice_context(data)), want)

    def test_label_goes_before_the_writers_why_and_only_on_the_stale_company(self):
        data = stale_data(beta='fresh')
        p = written_page(data)
        for w in p['stream']:
            if w['type'] == 'task':
                w['why'] = 'You said you would send it.'
        p['stream'] = [w for w in p['stream'] if w['type'] == 'task']
        brief, r = bp.attach({}, p, data)
        self.assertTrue(r['ok'], r['errors'])
        why = {w['company']: w['why'] for w in brief['page']['stream']}
        self.assertEqual(why, {'acme': f'{STALE_LABEL} You said you would send it.', 'beta': 'You said you would send it.'})

    def test_decided_cards_and_cards_citing_a_meeting_or_an_email_count_as_signal_cards(self):
        sig = lambda src: {'signals': [{'source': src, 'text': 'From a source'}]}
        self.assertTrue(bp.from_signals(card('t1', kind='note', type='task')))
        self.assertTrue(bp.from_signals(card('d1', kind='note', type='decided', data={'from': 'A', 'to': 'B'})))
        self.assertTrue(bp.from_signals(ball('b9', drill=sig('meeting'))))
        self.assertTrue(bp.from_signals(card('e1', kind='ask', type='ask', drill=sig('email'))))
        self.assertFalse(bp.from_signals(ball('b8')))
        self.assertFalse(bp.from_signals(card('a1', kind='ask', type='ask', drill=sig('dm'))))
        self.assertFalse(bp.from_signals(card('p1', drill=sig('pr'))))
        # The meetings count is calendar facts, though it cites meetings.
        self.assertFalse(bp.from_signals(card('m1', kind='note', type='meeting', drill=sig('meeting'))))
        decided = card('d1', kind='note', type='decided', symbol='gavel', title='Keep the old sign-in for now',
                       data={'from': 'New sign-in', 'to': 'Old sign-in'})
        for good, want in (('2026-10-01', [('d1', 'From Oct 1', STALE_LABEL)]), (None, [])):
            data = stale_data(good=good)
            p = written_page(data)
            p['stream'] = [copy.deepcopy(decided)]
            brief, r = bp.attach({}, p, data)
            self.assertTrue(r['ok'], r['errors'])
            self.assertEqual([(w['id'], w.get('label'), w.get('why')) for w in brief['page']['stream']], want)

    def test_signal_cards_under_personal_or_no_company_are_left_out_when_signals_are_stale(self):
        data = stale_data()
        p = written_page(data)
        p['stream'] = [card('t1', kind='note', type='task', symbol='list-checks', company='personal', title='Send the budget',
                            data={'hours': 3}),
                       card('s1', company='personal', title='Two changes shipped', data={'value': 2})]
        brief, r = bp.attach({}, p, data)
        self.assertTrue(r['ok'], r['errors'])
        self.assertEqual([w['id'] for w in brief['page']['stream']], ['s1'])

    def test_stale_brief_with_an_invalid_page_ships_the_page_written_by_code(self):
        for data in (stale_data(), stale_data(good=None), stale_data(beta=stale_entry(good='2026-09-20'))):
            for bad in (page(summary=[]), dict(written_page(data), version=99), {'stale': True}, None, 'x', []):
                brief, r = bp.attach({'run_id': 'r1'}, bad, data)
                self.assertFalse(r['ok'])
                self.assertTrue(r['fallback'])
                self.assertTrue(brief['page_problems'])
                p = brief['page']
                check = bp.validate_page(p)
                self.assertTrue(check['ok'], check['errors'])
                stale = [n['company'] for n in brief['signals_notices']]
                self.assertEqual([w['company'] for w in p['summary'][1:1 + len(stale)]], stale)
                self.assertTrue(all(str(w['id']).startswith('signals-stale-') for w in p['summary'][1:1 + len(stale)]))
                self.assertEqual(bp.notice_problems(brief, data), [])
                # The computed cards are on it too, so the reader does not lose the day.
                self.assertTrue([w for w in p['stream'] if w['type'] == 'ask'])
        # With fresh signals an invalid page is left out, as before.
        brief, r = bp.attach({'run_id': 'r1'}, page(summary=[]), stale_data(stale=False))
        self.assertFalse(r['fallback'])
        self.assertNotIn('page', brief)

    def test_stale_brief_with_no_page_gets_one_from_the_notice_command(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            data = stale_data()
            (d / 'brief-data.json').write_text(json.dumps(data))
            (d / 'brief.json').write_text(json.dumps({'run_id': 'r1', 'mode': 'person', 'items': {}}))
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(bp.main(['notice', '--brief', str(d / 'brief.json')]), 0)
            self.assertEqual(json.loads(out.getvalue()), {'signals_notices': 1, 'page': True})
            brief = json.loads((d / 'brief.json').read_text())
            p = brief['page']
            self.assertTrue(bp.validate_page(p)['ok'], bp.validate_page(p)['errors'])
            self.assertEqual((p['summary'][1]['id'], p['summary'][1]['title']),
                             ('signals-stale-acme', 'Last updated Oct\u00a01 ·\u00a0acme'))
            self.assertEqual(rank.signals_notice_problems(brief, str(d / 'brief.json')), [])
            # page-draft.json is a file a writer may have edited, so the code's page never reads it:
            # a sound draft beside the brief changes nothing.
            draft = {'page': bp.skeleton(data, 'Sam', NOW, NAMES), 'candidates': []}
            (d / 'page-draft.json').write_text(json.dumps(draft))
            (d / 'brief.json').write_text(json.dumps({'run_id': 'r1', 'mode': 'person', 'items': {}}))
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(bp.main(['notice', '--brief', str(d / 'brief.json')]), 0)
                self.assertEqual(json.loads((d / 'brief.json').read_text())['page'], p)
                self.assertEqual(p['person']['name'], 'here is your brief')
                # An invalid written page through the command line: the code's page is attached.
                (d / 'page.json').write_text(json.dumps(page(summary=[])))
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    self.assertEqual(bp.main(['attach', '--brief', str(d / 'brief.json'), '--page', str(d / 'page.json')]), 0)
                self.assertIn('a page written by code', err.getvalue())
                brief = json.loads((d / 'brief.json').read_text())
                self.assertEqual(brief['page']['summary'][1]['id'], 'signals-stale-acme')
                self.assertTrue(bp.validate_page(brief['page'])['ok'])
            # A fresh brief gets no page from the notice command.
            (d / 'brief-data.json').write_text(json.dumps(stale_data(stale=False)))
            (d / 'brief.json').write_text(json.dumps({'run_id': 'r1', 'mode': 'person', 'items': {}}))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(bp.main(['notice', '--brief', str(d / 'brief.json')]), 0)
            self.assertNotIn('page', json.loads((d / 'brief.json').read_text()))

    def test_fallback_page_holds_without_a_frame_or_usable_data(self):
        notices = bp.stale_notices(stale_data())
        for data in (stale_data(), {}, {'mode': 'person', 'companies': 'x'}, None):
            p = bp.fallback_page(data, notices)
            check = bp.validate_page(p)
            self.assertTrue(check['ok'], check['errors'])
            self.assertEqual(p['summary'][1]['id'], 'signals-stale-acme')

    def test_brief_json_carries_the_notice_field_with_or_without_a_valid_page(self):
        data = stale_data()
        want = [dict({'company': 'acme'}, **stale_entry())]
        good, r = bp.attach({'run_id': 'r1', 'learned_notes': ['Muted the agenda card.']}, written_page(data), data)
        self.assertTrue(r['ok'])
        bad, r = bp.attach({'run_id': 'r1'}, page(summary=[]), data)
        self.assertFalse(r['ok'])
        for brief in (good, bad):
            self.assertEqual(brief['signals_notices'], want)
            self.assertEqual(brief['learned_notes'][0], STALE_LINE)
        self.assertEqual(good['learned_notes'], [STALE_LINE, 'Muted the agenda card.'])
        # Without brief-data.json nothing about the notice is touched.
        self.assertNotIn('signals_notices', bp.attach({'run_id': 'r1'}, page())[0])

    def test_cli_notice_and_attach_read_the_brief_data_beside_the_brief(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            data = stale_data()
            (d / 'brief-data.json').write_text(json.dumps(data))
            (d / 'brief.json').write_text(json.dumps({'run_id': 'r1', 'mode': 'person', 'items': {}}))
            (d / 'page.json').write_text(json.dumps(written_page(data)))
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(bp.main(['notice', '--brief', str(d / 'brief.json')]), 0)
                brief = json.loads((d / 'brief.json').read_text())
                self.assertEqual([n['line'] for n in brief['signals_notices']], [STALE_LINE])
                self.assertEqual(brief['learned_notes'], [STALE_LINE])
                self.assertEqual(bp.main(['attach', '--brief', str(d / 'brief.json'), '--page', str(d / 'page.json')]), 0)
                brief = json.loads((d / 'brief.json').read_text())
                self.assertEqual(brief['page']['summary'][1]['id'], 'signals-stale-acme')
                # The writer's page replaced the code's one: its cards are there.
                self.assertTrue([w for w in brief['page']['stream'] if w['title'] == 'Send the budget'])
                self.assertEqual(brief['learned_notes'], [STALE_LINE])
                # A rebuild after a good run: the data has no notice, so the field is empty and the line is gone.
                (d / 'brief-data.json').write_text(json.dumps(stale_data(stale=False)))
                self.assertEqual(bp.main(['notice', '--brief', str(d / 'brief.json')]), 0)
                brief = json.loads((d / 'brief.json').read_text())
                self.assertEqual((brief['signals_notices'], brief['learned_notes']), ([], []))

    def test_notice_exits_1_and_attach_keeps_exit_0_when_brief_data_cannot_be_read(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / 'brief.json').write_text(json.dumps({'run_id': 'r1'}))
            (d / 'page.json').write_text(json.dumps(page()))
            for argv, code in ((['notice', '--brief', str(d / 'brief.json')], 1),
                               (['notice', '--brief', str(d / 'brief.json'), '--data', str(d / 'missing.json')], 1),
                               # attach exited 0 here before the notice existed, and still does.
                               (['attach', '--brief', str(d / 'brief.json'), '--page', str(d / 'page.json')], 0)):
                out = io.StringIO()
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(bp.main(argv), code, argv)
                said = json.loads(out.getvalue())
                self.assertIsNone(said['signals_notices'])
                self.assertIn('could not read brief-data.json', said['problem'])
            # attach attached the valid page it was given and added nothing about the notice.
            brief = json.loads((d / 'brief.json').read_text())
            self.assertEqual(brief['page'], page())
            self.assertEqual(sorted(brief), ['page', 'run_id'])
            # An invalid page with no data beside it: left out with exit 0, as before.
            (d / 'bad.json').write_text(json.dumps(page(summary=[])))
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(bp.main(['attach', '--brief', str(d / 'brief.json'), '--page', str(d / 'bad.json')]), 0)
            self.assertNotIn('page', json.loads((d / 'brief.json').read_text()))

    def run_dir(self, d, data, draft='absent', written='absent', brief=None):
        """A run folder: brief-data.json, brief.json, and page-draft.json / page.json as text
        ('absent' writes none)."""
        d = Path(d)
        (d / 'brief-data.json').write_text(json.dumps(data))
        (d / 'brief.json').write_text(json.dumps(brief or {'run_id': 'r1', 'mode': 'person', 'items': {}}))
        for name, text in (('page-draft.json', draft), ('page.json', written)):
            if (d / name).exists():
                (d / name).unlink()
            if text != 'absent':
                (d / name).write_text(text)
        return d

    def run_cli(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = bp.main(list(argv))
        return code, json.loads(out.getvalue())

    def drafts(self, data):
        frame = bp.skeleton(data, 'Sam', NOW, NAMES)
        return {'missing': 'absent', 'not json': '{"page": {"version": 1,',
                'window emptied': json.dumps({'page': dict(frame, window={}), 'candidates': []}),
                'not an object': json.dumps([1, 2]), 'page is text': json.dumps({'page': 'x'}),
                'lead removed': json.dumps({'page': dict(frame, summary=[]), 'candidates': []}),
                'person emptied': json.dumps({'page': dict(frame, person={}, companies='x'), 'candidates': []})}

    def test_a_damaged_missing_or_unparsable_draft_still_ends_with_a_valid_page(self):
        for data in (stale_data(), stale_data(good=None, beta=stale_entry(good='2026-09-20'))):
            stale = [n['company'] for n in bp.stale_notices(data)]
            pages = []
            for name, draft in self.drafts(data).items():
                # The writer copied the same damage into page.json, or wrote no page at all.
                for written in ('absent', '{"version": 1,', json.dumps(dict(written_page(data), window={}))):
                    with tempfile.TemporaryDirectory() as d:
                        d = self.run_dir(d, data, draft, written)
                        code, said = self.run_cli('notice', '--brief', str(d / 'brief.json'))
                        self.assertEqual((code, said), (0, {'signals_notices': len(stale), 'page': True}), name)
                        after_notice = json.loads((d / 'brief.json').read_text())
                        code, said = self.run_cli('attach', '--brief', str(d / 'brief.json'), '--page', str(d / 'page.json'))
                        self.assertEqual((code, said['attached'], said['fallback_page']), (0, False, True), name)
                        after_attach = json.loads((d / 'brief.json').read_text())
                        for brief in (after_notice, after_attach):
                            p = brief['page']
                            check = bp.validate_page(p)
                            self.assertTrue(check['ok'], (name, check['errors']))
                            self.assertEqual([(w['id'], w['company']) for w in p['summary'][1:1 + len(stale)]],
                                             [(f'signals-stale-{co}', co) for co in stale], name)
                            self.assertEqual(rank.signals_notice_problems(brief, str(d / 'brief.json')), [], name)
                            pages.append(p)
            # The draft never reaches the page: every run gave the same one.
            self.assertTrue(all(p == pages[0] for p in pages))

    def test_every_page_notice_or_attach_writes_passes_the_validator(self):
        rnd = random.Random(11)
        for i in range(120):
            data = stale_data(good=rnd.choice(['2026-10-01', None]),
                              beta=rnd.choice([None, 'fresh', stale_entry(good='2026-09-20')]))
            if i % 3 == 0:
                data = _mutate(data, rnd, rnd.randint(1, 3))
            stale = bool(bp.stale_notices(data))
            draft = json.dumps({'page': _mutate(bp.skeleton(stale_data(), 'Sam', NOW, NAMES), rnd, rnd.randint(0, 3))})
            written = rnd.choice(['absent', 'not json', json.dumps(_mutate(written_page(stale_data()), rnd, rnd.randint(0, 3))),
                                  json.dumps(written_page(stale_data()))])
            start = rnd.choice([None, {'run_id': 'r1', 'page': _mutate(written_page(stale_data()), rnd, 2)}])
            with tempfile.TemporaryDirectory() as d:
                d = self.run_dir(d, data, draft, written, start)
                for argv in (['notice', '--brief', str(d / 'brief.json')],
                             ['attach', '--brief', str(d / 'brief.json'), '--page', str(d / 'page.json')],
                             ['notice', '--brief', str(d / 'brief.json')]):
                    had = json.loads((d / 'brief.json').read_text()).get('page')
                    code, said = self.run_cli(*argv)
                    brief = json.loads((d / 'brief.json').read_text())
                    self.assertIn(code, (0, 2))
                    if stale:
                        # Exit 0 means a valid page with the notice was written; exit 2 means none was.
                        self.assertEqual(code == 0, 'page' in brief, (argv[0], said))
                    if 'page' in brief and (stale or argv[0] == 'attach'):
                        self.assertTrue(bp.validate_page(brief['page'])['ok'], (argv[0], said))
                    elif 'page' in brief:
                        # A fresh brief: notice leaves the page field exactly as it found it.
                        self.assertEqual(brief['page'], had)
                    if stale and code == 0:
                        self.assertEqual(bp.notice_problems(brief, data), [])

    def test_exit_2_and_no_page_when_no_valid_page_can_be_built(self):
        data = stale_data()
        with tempfile.TemporaryDirectory() as d:
            d = self.run_dir(d, data, written=json.dumps(page(summary=[])),
                             brief={'run_id': 'r1', 'page': {'version': 99}})
            with patch.object(bp, 'fallback_page', return_value=None):
                for argv in (['notice', '--brief', str(d / 'brief.json')],
                             ['attach', '--brief', str(d / 'brief.json'), '--page', str(d / 'page.json')]):
                    code, said = self.run_cli(*argv)
                    self.assertEqual(code, 2, argv[0])
                    self.assertIn('no valid page could be built', said['problem'])
                    self.assertIn('do not run this again', said['problem'])
                    brief = json.loads((d / 'brief.json').read_text())
                    # No invalid page is left behind, and the notice is still recorded for the reply.
                    self.assertNotIn('page', brief)
                    self.assertEqual([n['company'] for n in brief['signals_notices']], ['acme'])
        # fallback_page returns only a page that passes the validator, or nothing.
        with patch.object(bp, 'validate_page', return_value={'ok': False, 'errors': [{'where': 'x', 'problem': 'y'}], 'warnings': []}):
            self.assertIsNone(bp.fallback_page(data, bp.stale_notices(data)))
            brief, r = bp.attach({'run_id': 'r1'}, written_page(data), data)
            self.assertEqual((r['no_page'], r['fallback'], 'page' in brief), (True, False, False))
            self.assertNotIn('page', bp.with_notices({'page': written_page(data)}, data))
        self.assertIsNone(bp.fallback_page(data, []))

    def test_check_reports_a_notice_that_is_missing_edited_or_not_on_the_page(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            data = stale_data()
            (d / 'brief-data.json').write_text(json.dumps(data))
            path = str(d / 'brief.json')
            base = {'mode': 'person', 'items': {}, 'today': '2026-10-02'}
            where = lambda b: [x['where'] for x in rank.signals_notice_problems(b, path)]
            # A stale brief with no page is a problem, even with the field stamped.
            self.assertEqual(where(base), ['signals_notices', 'learned_notes', 'page'])
            stamped = bp.stamp_notices(base, bp.stale_notices(data))
            self.assertEqual(where(stamped), ['page'])
            self.assertEqual(where(bp.with_notices(base, data)), [])
            attached = bp.attach(base, written_page(data), data)[0]
            self.assertEqual(where(attached), [])
            edited = copy.deepcopy(attached)
            edited['signals_notices'][0]['line'] = 'Signals are fine.'
            self.assertEqual(where(edited), ['signals_notices'])
            self.assertEqual(where(dict(attached, learned_notes=[])), ['learned_notes'])
            unlabelled = copy.deepcopy(attached)
            for w in unlabelled['page']['stream']:
                w.pop('label', None)
            self.assertEqual(where(unlabelled), ['page'])
            no_card = copy.deepcopy(attached)
            no_card['page']['summary'][1] = card('x1', title='Four changes shipped')
            self.assertEqual(where(no_card), ['page'])
            no_page = {k: v for k, v in attached.items() if k != 'page'}
            self.assertEqual(where(no_page), ['page'])
            self.assertEqual(where(dict(attached, page=dict(attached['page'], version=99))), ['page'])
            # Fresh signals: an empty list is what the check wants, and a leftover notice is a problem.
            (d / 'brief-data.json').write_text(json.dumps(stale_data(stale=False)))
            self.assertEqual(where(dict(base, signals_notices=[])), [])
            self.assertEqual(where(stamped), ['signals_notices', 'learned_notes'])
            (d / 'brief-data.json').unlink()
            self.assertEqual(where(base), [])

    def test_fuzzed_notices_and_pages_never_raise(self):
        rnd = random.Random(7)
        for _ in range(300):
            data = _mutate(stale_data(good=rnd.choice(['2026-10-01', None]),
                                      beta=rnd.choice([None, 'fresh', stale_entry(good='2026-09-20')])),
                           rnd, rnd.randint(1, 4))
            p = _mutate(written_page(stale_data()), rnd, rnd.randint(0, 4))
            notices = bp.stale_notices(data)
            bp.apply_notices(p, notices)
            bp.skeleton(data, 'Sam', NOW, {})
            brief, r = bp.attach({}, p, data)
            if notices:
                # Whatever the writer's page was, a stale brief ends with a valid page that shows the notice.
                self.assertTrue(bp.validate_page(brief['page'])['ok'])
                self.assertEqual(bp.notice_problems(brief, data), [])
            bp.with_notices({}, data)


class StaleWording(unittest.TestCase):
    """What a person reads about stale signals: short dates, a tag that fits a small card, a
    drill sentence that fits two lines, no company possessive, and no control the page lacks."""

    CODES = ('auth', 'config', 'run-failed', 'start-failed', 'timed-out', 'no-record', 'not-run')
    LONG_NAME = 'Cyan Laboratories and Partners Holdings Group'[:40]

    def every_day(self, year):
        d = dt.date(year, 1, 1)
        while d.year == year:
            yield d.isoformat()
            d += dt.timedelta(days=1)

    def test_one_helper_formats_every_date_shown_to_a_person(self):
        self.assertEqual(bg.human_date('2026-10-01', '2026-10-31'), 'Oct 1')
        self.assertEqual(bg.human_date('2026-09-30', '2026-10-31'), 'Sep 30')
        self.assertEqual(bg.human_date('2025-10-01', '2026-01-02'), 'Oct 1, 2025')
        self.assertEqual(bg.human_date('2026-10-01T13:05:00Z', '2026-10-31'), 'Oct 1')
        # With no known "today" the year is kept; text that is not a date comes back as it was.
        self.assertEqual(bg.human_date('2026-10-01'), 'Oct 1, 2026')
        self.assertEqual(bg.human_date('2026-10-01', 'garbage'), 'Oct 1, 2026')
        self.assertEqual(bg.human_date('not a date', '2026-10-31'), 'not a date')
        self.assertEqual(bp.shown_date('2026-10-01', '2026-10-02'), 'Oct 1')

    def test_date_tag_fits_the_smallest_card_with_a_badge(self):
        # S card 190 px at the grid minimum; the tag starts 20 px in, a badge is 24 px, about 8 px a character.
        fits = lambda tag: 20 + 24 + 8 * len(tag) <= 190 - 10
        self.assertEqual(bp.TAG_MAX_CHARS, 17)
        longest = ''
        for today, year in (('2026-11-14', 2026), ('2026-11-14', 2025), ('2027-01-02', 2026)):
            for day in self.every_day(year):
                tag = bp.signal_label({'last_good_run': {'date': day}}, today)
                self.assertLessEqual(len(tag), bp.TAG_MAX_CHARS, tag)
                self.assertTrue(fits(tag), tag)
                self.assertTrue(tag.startswith('From '), tag)
                if year == int(today[:4]):
                    self.assertLessEqual(len(tag), len('From Sep 30'), tag)
                longest = max(longest, tag, key=len)
        self.assertEqual(len(longest), 17)
        self.assertEqual(bp.signal_label({'last_good_run': {'date': '2026-10-01'}}, '2026-10-02'), 'From Oct 1')
        self.assertEqual(bp.signal_label({'last_good_run': {'date': '2025-09-30'}}, '2026-10-02'), 'From Sep 30, 2025')
        # The old tag did not fit: that is what this guards.
        self.assertFalse(fits('Signals from 2026-10-01'))

    def company_brief(self, good='2026-10-01', code='auth'):
        """brief-data.json of a brief for one company only."""
        sec = stale_data(good=good)['companies']['acme']
        sec['signals_stale']['code'] = code
        return dict(sec, mode='company', company='acme', previous_run=None)

    def test_caps_hold_for_every_reason_date_form_and_a_sixty_character_name(self):
        self.assertEqual((bp.NOTICE_WHY_MAX_CHARS, bp.NAME_MAX_CHARS, bp.DRILL_LINE_CHARS), (76, 27, 19))
        self.assertEqual(set(bp.NEVER_GOOD_REASON), set(self.CODES))
        self.assertEqual(len(bp.NEVER_GOOD_WHY) + 1 + max(len(r) for r in list(bp.NEVER_GOOD_REASON.values())
                                                           + [bp.NEVER_GOOD_REASON_DEFAULT]), 76)
        self.assertEqual((bp.NOTICE_TITLE_MAX_CHARS, bp.TITLE_NAME_MAX_CHARS, bp.TITLE_NAME_MAX_WORDS), (43, 15, 2))
        self.assertEqual((bp.TITLE_LINE_CHARS, bp.TITLE_LINES), (17, 2))
        self.assertEqual(set(bp.NOTICE_REASON), set(self.CODES))
        self.assertEqual(max(len(r) for r in list(bp.NOTICE_REASON.values()) + [bp.NOTICE_REASON_DEFAULT]), 47)
        names = ('Cyan Laboratories and Partners Holdings Group International X'[:60], 'A' * 60, 'A B C D E F G H I J', 'Acme Inc',
                 'Cyan Laboratories', 'Fix', 'Refactor Partners Worldwide', 'acme')
        self.assertEqual(len(names[0]), 60)
        dates = [('2026-10-01', '2026-10-02'), ('2025-09-30', '2026-10-02'), ('2026-12-31', '2027-01-01'),
                 ('2026-10-01', None), (None, '2026-10-02')]
        dates += [(day, '2026-12-31') for day in self.every_day(2026)] + [(day, '2026-06-01') for day in self.every_day(2025)]
        longest_why = longest_title = ''
        for code in self.CODES + ('unknown', None):
            reason = bp.NOTICE_REASON.get(code, bp.NOTICE_REASON_DEFAULT)
            for good, today in dates:
                when = bg.human_date(good, today) if good else None
                for name in (names if len(dates) and (good, today) in dates[:5] else names[:2]):
                    for multi in (True, False):
                        notice = dict(stale_entry(good=good), company='acme', code=code)
                        card = bp.notice_card(notice, today, name, multi)
                        why, title, bot = card['why'], card['title'], card['drill']['bot']
                        self.assertLessEqual(len(why), bp.NOTICE_WHY_MAX_CHARS, why)
                        self.assertLessEqual(len(title), bp.NOTICE_TITLE_MAX_CHARS, title)
                        self.assertLessEqual(len(title.split()), 8, title)
                        self.assertEqual(rank.lint_title(title), [], title)
                        # The reason is whole; only the name gives way, and it is cut between words.
                        if good or title == 'No signals yet':
                            self.assertTrue(why.endswith(f': {reason}'), why)
                            lead = why[:-len(f': {reason}')]
                            self.assertLessEqual(len(lead), bp.NAME_MAX_CHARS)
                            if lead != name:
                                self.assertTrue(lead.endswith('\u2026'), why)
                                kept = lead[:-1]
                                self.assertTrue(name.startswith(kept), why)
                                # Between words, unless one word alone is longer than the room.
                                self.assertTrue(name[len(kept)] == ' ' or ' ' not in kept, why)
                        else:
                            # No run has ever finished: say so, then the reason; the title names the company.
                            self.assertEqual(why, f"{bp.NEVER_GOOD_WHY} {bp.NEVER_GOOD_REASON.get(code, bp.NEVER_GOOD_REASON_DEFAULT)}")
                            self.assertTrue(title.startswith('No signals yet ·\u00a0'), title)
                        # The date comes first and is whole, and the title says what the date is.
                        fixed = when.replace(' ', '\u00a0') if good else None
                        if good:
                            self.assertTrue(title.startswith('Last updated ' + fixed),
                                            title)
                        else:
                            self.assertTrue(title.startswith('No signals yet ·\u00a0') or title == 'No signals yet', title)
                        # Wrapped at the line budget the app's narrowest S card surely holds, the date
                        # ends within the two lines the app draws; only the name can fall past them.
                        lines = bp.title_lines(title)
                        self.assertTrue(all(len(x) <= bp.TITLE_LINE_CHARS for x in lines[:2] if ' ' in x), lines)
                        if good:
                            self.assertIn(fixed, ' '.join(lines[:bp.TITLE_LINES]), lines)
                            self.assertTrue(bp.date_shown(title, fixed), lines)
                        # A line never starts with a bare dot: the dot stays with the name's first word.
                        for line in lines:
                            self.assertFalse(line == '·' or line.startswith('· '), lines)
                        # The opened card draws the same title at DRILL_LINE_CHARS a line: two lines,
                        # except a named title with a prior-year date, which takes three (the date
                        # block alone is 12 characters and cannot share a line with "Last updated").
                        drill = bp.title_lines(title, bp.DRILL_LINE_CHARS)
                        year = bool(good) and ',' in when
                        self.assertLessEqual(len(drill), 3 if (year and ' ·\u00a0' in title) else 2, drill)
                        if good:
                            self.assertIn(fixed, ' '.join(drill[:2]), drill)
                        for line in drill:
                            self.assertGreater(len(line), 4, drill)  # no lone short word on a line
                        if ' ·\u00a0' in title:
                            tail = title[title.index(' ·\u00a0') + 3:]
                            self.assertLessEqual(len(tail), bp.TITLE_NAME_MAX_CHARS, title)
                            self.assertTrue(tail.rstrip('\u2026').rstrip().replace('\u00a0', ' ') in name, title)
                            self.assertNotIn(' ', tail, title)  # one unbreakable block
                            # The name comes after the whole date, so a clamp can only cut the name.
                            if good:
                                self.assertLess(title.index(fixed) + len(fixed), title.index(tail), title)
                        # Nothing is said twice: the opened text does not repeat the title, and the
                        # message Ask my bot sends states each fact once.
                        self.assertNotIn('last updated', why)
                        self.assertNotIn('stale since', (why + title + bot).lower())
                        self.assertEqual(bot.count(reason[1:]), 1, bot)
                        if not good:
                            self.assertIn('From my Daily Brief: No signals run has finished yet for ', bot)
                        self.assertEqual(bot.count('last updated') + bot.count('has finished yet for'), 1, bot)
                        self.assertTrue(bot.startswith('From my Daily Brief: ') and bot.endswith(' What should I do about it?'))
                        if good:
                            self.assertIn(f' were last updated {when}. ', bot)
                            self.assertTrue(bot.startswith('From my Daily Brief: Signals for '), bot)
                        # No possessive of the company name, whole or cut.
                        for text in (why, title, bot):
                            self.assertNotIn(name + "'", text)
                            self.assertNotIn("\u2026'", text)
                            self.assertNotRegex(text.replace("oday's signals run", ''), r"'s\b")
                        self.assertNotIn('still going', why + bot)
                        longest_why, longest_title = max(longest_why, why, key=len), max(longest_title, title, key=len)
        self.assertEqual(len(longest_why), 76)
        self.assertTrue(longest_why.endswith(": today's signals run stopped before it finished."), longest_why)
        self.assertEqual(len(longest_why.split(':')[0]), bp.NAME_MAX_CHARS)
        self.assertEqual(len(longest_title), 43)
        self.assertEqual(longest_title, 'Last updated Sep\u00a030,\u00a02025 ·\u00a0Cyan\u00a0Laborator\u2026')
        # A short name is never cut; a long one keeps whole words where it can.
        self.assertEqual(bp.short_name('Acme Inc', 24), 'Acme Inc')
        self.assertEqual(bp.short_name('Delta Group International', 16, 2), 'Delta Group\u2026')
        self.assertEqual(bp.short_name('Cyan Laboratories', 16, 2), 'Cyan Laboratori\u2026')
        # A name that starts a title can no longer read as a commit prefix: the date leads.
        self.assertEqual(bp.notice_card(dict(stale_entry(), company='fix'), '2026-10-02', 'Fix', True)['title'],
                         'Last updated Oct\u00a01 ·\u00a0Fix')
        # The reviewed case: a 16-character name and a prior-year date keep the date in two lines.
        t = bp.notice_card(dict(stale_entry(good='2025-12-31'), company='nw'), '2026-01-02', 'Northwind Traders Global', True)
        self.assertEqual(t['title'], 'Last updated Dec\u00a031,\u00a02025 ·\u00a0Northwind\u00a0Trad\u2026')
        self.assertEqual(bp.title_lines(t['title']), ['Last updated', 'Dec\u00a031,\u00a02025', '·\u00a0Northwind\u00a0Trad\u2026'])
        self.assertEqual(bp.title_lines(t['title'], bp.DRILL_LINE_CHARS), bp.title_lines(t['title']))
        # Current-year, the opened card keeps it to two lines with the longest name.
        t = bp.notice_card(dict(stale_entry(good='2026-09-30'), company='nw'), '2026-10-02', 'Northwind Traders Global', True)
        self.assertEqual(bp.title_lines(t['title'], bp.DRILL_LINE_CHARS),
                         ['Last updated Sep\u00a030', '·\u00a0Northwind\u00a0Trad\u2026'])
        # The opened text cuts a long name between words, with room for 27 characters.
        t = bp.notice_card(dict(stale_entry(), company='nw', code='no-record'), '2026-10-02',
                           'Delta Group International Holdings', True)
        self.assertEqual(t['why'], "Delta Group International\u2026: today's signals run stopped before it finished.")
        t = bp.notice_card(dict(stale_entry(), company='nw'), '2026-10-02', 'Northwind Traders Holdings Group', True)
        self.assertEqual(t['why'], 'Northwind Traders Holdings\u2026: sign-in to a connected account failed.')
        # A name the title rule would refuse is left to the badge and the opened text.
        t = bp.notice_card(dict(stale_entry(), company='x'), '2026-10-02', 'src/app.py', True)
        self.assertEqual(t['title'], 'Last updated Oct\u00a01')

    def test_each_part_of_the_notice_says_something_the_others_do_not(self):
        entry = lambda good, code: dict(stale_entry(good=good), company='acme', code=code)
        one = bp.notice_card(entry('2026-10-01', 'auth'), '2026-10-02', 'Acme Inc', False)
        self.assertEqual((one['title'], one['why'], one['drill']),
                         ('Last updated Oct\u00a01', 'Acme Inc: sign-in to a connected account failed.',
                          {'signals': [], 'bot': 'From my Daily Brief: Signals for Acme Inc were last updated Oct 1. '
                                                 'Sign-in to a connected account failed. What should I do about it?'}))
        many = bp.notice_card(entry('2026-10-01', 'auth'), '2026-10-02', 'Acme Inc', True)
        self.assertEqual((many['title'], many['why'], many['drill']['bot']),
                         ('Last updated Oct\u00a01 ·\u00a0Acme\u00a0Inc', one['why'], one['drill']['bot']))
        never = bp.notice_card(entry(None, 'auth'), '2026-10-02', 'Acme Inc', False)
        self.assertEqual((never['title'], never['why'], never['drill']['bot']),
                         ('No signals yet ·\u00a0Acme\u00a0Inc', 'No run has finished yet, so signal cards are hidden. Sign-in failed.',
                          'From my Daily Brief: No signals run has finished yet for Acme Inc, so its signal cards are '
                          'not shown. Sign-in to a connected account failed. What should I do about it?'))
        self.assertEqual(bp.notice_card(entry(None, 'auth'), '2026-10-02', 'Acme Inc', True)['title'],
                         'No signals yet ·\u00a0Acme\u00a0Inc')
        # timed-out and not-run mean the same to the reader: today's run is still under way.
        self.assertEqual(bp.NOTICE_REASON['timed-out'], bp.NOTICE_REASON['not-run'])
        self.assertEqual(bp.NEVER_GOOD_REASON['timed-out'], bp.NEVER_GOOD_REASON['not-run'])
        late = bp.notice_card(entry('2026-09-20', 'timed-out'), '2026-10-02', 'Beta Co', True)
        self.assertEqual((late['title'], late['why'], late['drill']['bot']),
                         ('Last updated Sep\u00a020 ·\u00a0Beta\u00a0Co', "Beta Co: today's signals run has not finished yet.",
                          "From my Daily Brief: Signals for Beta Co were last updated Sep 20. Today's signals run has not "
                          'finished yet. What should I do about it?'))
        self.assertEqual({code: bp.NOTICE_REASON[code] for code in self.CODES}, {
            'auth': 'sign-in to a connected account failed.', 'config': 'the signals setup is not complete.',
            'run-failed': "today's signals run failed.", 'start-failed': "today's signals run could not start.",
            'timed-out': "today's signals run has not finished yet.",
            'no-record': "today's signals run stopped before it finished.",
            'not-run': "today's signals run has not finished yet."})
        # The card with its message is a valid card on a page, and attach keeps it as written.
        data = stale_data()
        brief, r = bp.attach({'run_id': 'r1'}, written_page(data), data)
        self.assertTrue(r['ok'], r['errors'])
        self.assertEqual(brief['page']['summary'][1]['drill']['bot'], one['drill']['bot'])

    def test_a_brief_for_one_company_keeps_the_plain_title_and_names_it_when_opened(self):
        data = self.company_brief()
        self.assertEqual(bp.notice_context(data)['multi'], False)
        p = bp.skeleton(data, 'Sam', NOW, {'acme': 'Acme Inc'})
        card = p['summary'][1]
        self.assertEqual(card['title'], 'Last updated Oct\u00a01')
        self.assertEqual(card['why'], 'Acme Inc: sign-in to a connected account failed.')
        gone = bp.skeleton(self.company_brief(good=None, code='timed-out'), 'Sam', NOW, {'acme': 'Acme Inc'})['summary'][1]
        self.assertEqual((gone['title'], gone['why']),
                         ('No signals yet ·\u00a0Acme\u00a0Inc', 'No run has finished yet, so signal cards are hidden. The run is not done.'))

    def test_a_stale_company_is_named_when_the_other_company_has_no_cards(self):
        # A person brief over Acme and Beta: Acme stale, Beta fresh and quiet, nothing personal. Every
        # company card on the page is Acme's, so the app draws no badge; the words must name Acme.
        for good in ('2026-10-01', None):
            data = stale_data(good=good)
            data['personal'].update(dms=[], prs=[])
            data['companies']['beta'].update(dms=[], prs=[], main_health={}, meetings=[], meeting_signals=[], fleet=None)
            self.assertEqual(bp.notice_context(data)['multi'], True)
            written, fallback = written_page(data), bp.fallback_page(data, bp.stale_notices(data), NAMES)
            brief, r = bp.attach({'run_id': 'r1'}, written, data)
            self.assertTrue(r['ok'], r['errors'])
            for p in (brief['page'], fallback):
                self.assertEqual({w['company'] for w in all_cards(p) if w.get('company')}, {'acme'})
                [card] = notice_cards(p)
                # Closed: the title. Opened, and in the message Ask my bot builds from title and why: both.
                self.assertTrue(card['title'].endswith(' ·\u00a0Acme\u00a0Inc'), card['title'])
                self.assertTrue(card['why'].startswith('Acme Inc: ') if good else card['why'] == 'No run has finished yet, so signal cards are hidden. Sign-in failed.', card['why'])
                ask_my_bot = card['drill']['bot']  # the app sends drill.bot as written
                self.assertEqual(ask_my_bot.count('Acme Inc'), 1)
                self.assertNotIn('Beta', json.dumps(card))

    def test_two_stale_companies_with_the_same_reason_and_date_still_read_differently(self):
        names = {'acme': 'Acme Inc', 'beta': 'Apex Industries'}  # the same initials, so the same badge
        data = stale_data(beta=stale_entry())
        p = bp.skeleton(data, 'Sam', NOW, names)
        acme, beta = p['summary'][1], p['summary'][2]
        self.assertEqual((acme['title'], beta['title']),
                         ('Last updated Oct\u00a01 ·\u00a0Acme\u00a0Inc', 'Last updated Oct\u00a01 ·\u00a0Apex\u00a0Industries'))
        self.assertEqual((acme['why'], beta['why']), ('Acme Inc: sign-in to a connected account failed.',
                                                      'Apex Industries: sign-in to a connected account failed.'))

    def test_the_page_and_the_gate_agree_on_the_year_around_new_year(self):
        # The sweep writes window.today as the local day and the window's end in UTC. The gate judges
        # by the local day, so the page must too.
        cases = (('2026-12-31', '2027-01-01T04:00:00+00:00', '2026-12-30', 'Dec 30'),          # evening, west of UTC
                 ('2027-01-01', '2026-12-31T22:00:00+00:00', '2026-12-31', 'Dec 31, 2026'))     # morning, east of UTC
        for today, window_to, good, want in cases:
            gate = bg._stale_entry('auth', {'date': good, 'finished_at': None}, 20, today)
            self.assertIn(f'last good run on {want}.', gate['line'])
            data = self.company_brief(good=good)
            data['signals_stale'].update(line=gate['line'], section_line=gate['section_line'])
            data['window'].update(today=today, sessions_to=window_to)
            self.assertEqual(bp.notice_context(data)['today'], today)
            page_now = dt.datetime.fromisoformat(window_to)
            p = bp.skeleton(data, 'Sam', page_now, {'acme': 'Acme Inc'})
            self.assertEqual(p['window']['to'][:10], window_to[:10])  # the page's own day is the other one
            self.assertEqual(p['summary'][1]['title'], 'Last updated ' + want.replace(' ', '\u00a0'))
            self.assertEqual(p['summary'][1]['why'], 'Acme Inc: sign-in to a connected account failed.')
            written = written_page_at(data, page_now)
            brief, r = bp.attach({'run_id': 'r1'}, written, data)
            self.assertTrue(r['ok'], r['errors'])
            [task] = [w for w in all_cards(brief['page']) if w['type'] == 'task']
            self.assertEqual(task['label'], f'From {want}')
            self.assertIn(f'on {want},', task['why'])  # the gate's sentence and the tag show the same date
            self.assertEqual(bp.notice_problems(brief, data), [])
        # With no local day in the data the page's own day stands in.
        self.assertNotIn('today', bp.notice_context(stale_data()))

    def test_no_sentence_needs_a_company_possessive(self):
        names = {'acme': 'Cyan Laboratories', 'beta': 'Delta Group International'}
        data = stale_data(beta=stale_entry(good=None, code='timed-out', reason=TIMED_OUT))
        for p in (bp.skeleton(data, 'Sam', NOW, names), bp.fallback_page(data, bp.stale_notices(data), names)):
            cards = notice_cards(p)
            text = json.dumps(cards, ensure_ascii=False)
            for bad in ("s's", "Laboratories'", "International'", "'s signal cards", "\u2026'"):
                self.assertNotIn(bad, text, bad)
            # Each is named by a lead-in, the long one cut with an ellipsis.
            self.assertEqual([c['why'] for c in cards], ['Cyan Laboratories: sign-in to a connected account failed.',
                                                         'No run has finished yet, so signal cards are hidden. The run is not done.'])
            self.assertEqual([c['title'] for c in cards], ['Last updated Oct\u00a01 ·\u00a0Cyan\u00a0Laborator\u2026',
                                                           'No signals yet ·\u00a0Delta\u00a0Group\u2026'])
        for code in self.CODES:
            entry = bg._stale_entry(code, {'date': '2026-10-30', 'finished_at': None}, 20, '2026-10-31')
            for field in ('line', 'try_now_line', 'section_line', 'reason'):
                self.assertNotRegex(entry[field], r"[A-Z][a-z]+'s? ", (code, field))

    def test_page_text_names_no_try_now_and_the_reply_line_does(self):
        for code in self.CODES:
            for good in ({'date': '2026-10-30', 'finished_at': None}, None):
                entry = bg._stale_entry(code, good, 20, '2026-10-31')
                self.assertNotIn('Try now', entry['line'], code)
                self.assertNotIn('press', entry['line'].lower(), code)
                self.assertIn('Try now', entry['try_now_line'], code)
                self.assertNotIn('2026-', entry['line'] + entry['section_line'] + entry['try_now_line'])
                if good:
                    self.assertIn('last good run on Oct 30.', entry['line'])
                    self.assertEqual(entry['section_line'], 'From the last good signals run on Oct 30, not from today.')
                    self.assertEqual(entry['last_good_run'], good)  # the machine field keeps the ISO date
        data = stale_data(beta=stale_entry(good='2026-09-20'))
        brief, r = bp.attach({'run_id': 'r1'}, written_page(data), data)
        self.assertTrue(r['ok'], r['errors'])
        self.assertNotIn('Try now', json.dumps(brief['page']))
        # No machine date in anything the page says about stale signals.
        for w in all_cards(brief['page']):
            if str(w['id']).startswith('signals-stale') or w['type'] == 'task':
                self.assertNotRegex(json.dumps([w.get('label'), w['title'], w.get('why')]), r'\d{4}-\d{2}-\d{2}')
        # The reply's sentence is carried to brief.json for Step 6.
        self.assertEqual([n['try_now_line'] for n in brief['signals_notices']], [TRY_NOW_LINE, TRY_NOW_LINE])

    def test_fallback_page_greets_by_name_when_the_data_has_one_and_names_nobody_otherwise(self):
        data = stale_data()
        notices = bp.stale_notices(data)
        nameless = bp.fallback_page(data, notices)
        # The app draws "<greeting>, <name>." and rejects a blank name, so with no name the field
        # holds a phrase: the headline is "Good morning, here is your brief.", in every time of day.
        self.assertEqual(nameless['person']['name'], 'here is your brief')
        for greeting in ('Good morning', 'Good afternoon', 'Good evening'):
            headline = f"{greeting}, {nameless['person']['name']}."
            self.assertEqual(headline, f'{greeting}, here is your brief.')
            self.assertNotRegex(headline, r', \.|,\.|  |, (You|there|friend|all)\.')
        self.assertEqual(nameless['person']['name'], nameless['person']['name'].strip())
        self.assertNotIn(nameless['person']['name'], ('You', 'there'))
        named = bp.fallback_page(dict(data, person={'name': 'Sam Rivers'}), notices)
        self.assertEqual(named['person']['name'], 'Sam')
        for odd in ({'name': '  '}, {'name': 7}, 'Sam', None, {}):
            self.assertEqual(bp.fallback_page(dict(data, person=odd), notices)['person']['name'], 'here is your brief', odd)
        for p in (nameless, named):
            self.assertTrue(bp.validate_page(p)['ok'])
        self.assertEqual(bp.fallback_page({}, notices)['person']['name'], 'here is your brief')

    def test_a_brief_with_fresh_signals_is_unchanged_by_any_of_this(self):
        data = stale_data(stale=False)
        frame = bp.skeleton(data, 'Sam', NOW, NAMES)
        self.assertEqual(bp.apply_notices(frame, bp.stale_notices(data)), frame)
        brief, r = bp.attach({'run_id': 'r1'}, written_page(data), data)
        self.assertEqual(brief['page'], written_page(data))
        self.assertEqual(brief['signals_notices'], [])


if __name__ == '__main__':
    unittest.main()
