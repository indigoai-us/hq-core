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


if __name__ == '__main__':
    unittest.main()
