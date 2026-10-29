#!/usr/bin/env python3
"""Company tagging for Daily Brief sweep rows: which company a PR or a DM belongs to.

PRs: the manifest lists each company's local repos (`repos:`). For the companies in
the session lock only, each listed repo's `origin` remote gives its owner-qualified
GitHub name, so a PR row's `repo_full` maps to exactly one company. A GitHub owner maps
to a company only when it is an organization (never a personal account, never the
person's own login) and every known repo under it belongs to that one company, or when
it is that company's explicit `github_org`. Everything else matches on the full
owner/name only; an unmatched PR is the person's own. A repo listed under two companies
is ambiguous and is tagged by neither. Repos of companies outside the lock are never
read: their manifest folder names only keep a matching PR out of the personal section.

DMs: `hq dm inbox` carries no company or channel. A sender who is an active member of
exactly one of the person's included companies is attributed to that company, read
from `hq members --company <slug> list --json` for the included companies only (never
for a company outside the session lock). A sender in two included companies, or in
none, is not attributed. When any included roster cannot be read, attribution is off
for the run: a sender who looks unique might be in the roster that failed.

Pure helpers take parsed inputs and are unit-tested in test_brief_company.py.
"""
import json
import os
import re
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed, TimeoutError as FuturesTimeout

PERSONAL = 'personal'
AMBIGUOUS = object()          # a repo or owner that maps to more than one company
OTHER = object()              # a repo of a company outside the session lock
OWNER_BUDGET_S = 15           # every GitHub account-type read together
ROSTER_TIMEOUT_S = 20         # one `hq members list` call
ROSTER_BUDGET_S = 30          # every roster together
REMOTE_TIMEOUT_S = 3          # one `git remote get-url`
REMOTE_BUDGET_S = 20          # every remote read together

_SLUG = re.compile(r'^[A-Za-z0-9_.-]+$')
_REMOTE = re.compile(r'github\.com[:/]+([^/:\s]+)/([^/\s]+?)(?:\.git)?/?$')


# ---------- manifest ----------

def manifest_repos(text):
    """{company slug: [repo path]} from the `repos:` list of each company in
    companies/manifest.yaml text. Hand-parsed (the sweep runs with python3 -I and no
    YAML library): block lists (`- path`) and inline lists (`[a, b]`) are read; any
    other shape for a company yields no repos for it."""
    out, cur, inside, field_indent, in_repos = {}, None, False, None, False
    for raw in (text or '').splitlines():
        line = raw.split('#', 1)[0].rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 0:
            inside, cur, in_repos = line.strip() == 'companies:', None, False
            continue
        if not inside:
            continue
        m = re.match(r'^ {2}([A-Za-z0-9_.-]+):\s*$', line)
        if m:
            cur, field_indent, in_repos = m.group(1), None, False
            continue
        if cur is None:
            continue
        if field_indent is None:
            field_indent = indent
        if indent == field_indent:
            in_repos = False
            m = re.match(r'^\s+repos:\s*(.*)$', line)
            if m:
                rest = m.group(1).strip()
                out.setdefault(cur, [])
                if rest.startswith('[') and rest.endswith(']'):
                    out[cur] += [x.strip().strip('"\'') for x in rest[1:-1].split(',') if x.strip()]
                elif not rest:
                    in_repos = True
            continue
        if in_repos and indent > field_indent:
            m = re.match(r'^\s+-\s+["\']?([^"\']+?)["\']?\s*$', line)
            if m:
                out[cur].append(m.group(1))
    return out


def manifest_names(text):
    """{company slug: display name} from the `name:` key of each company."""
    out, cur, inside, field_indent = {}, None, False, None
    for raw in (text or '').splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 0:
            inside, cur = line.strip() == 'companies:', None
            continue
        if not inside:
            continue
        m = re.match(r'^ {2}([A-Za-z0-9_.-]+):\s*$', line)
        if m:
            cur, field_indent = m.group(1), None
            continue
        if cur is None:
            continue
        if field_indent is None:
            field_indent = indent
        m = re.match(r'^\s+name:\s*["\']?(.+?)["\']?\s*$', line)
        if indent == field_indent and m:
            out[cur] = m.group(1)
    return out


def read_manifest(hq_root):
    try:
        with open(os.path.join(hq_root, 'companies', 'manifest.yaml'), encoding='utf-8') as f:
            return f.read()
    except OSError:
        return ''


# ---------- repos -> company ----------

def remote_full(url):
    """'owner/name' from a GitHub remote URL (https or ssh), or None."""
    m = _REMOTE.search((url or '').strip())
    return f'{m.group(1)}/{m.group(2)}' if m else None


def _git_remote(path):
    try:
        r = subprocess.run(['git', '-C', path, 'remote', 'get-url', 'origin'], capture_output=True, text=True,
                           timeout=REMOTE_TIMEOUT_S, stdin=subprocess.DEVNULL)
        return r.stdout.strip() if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def build_repo_map(repos_by_company, remotes, explicit_owners=None, owner_types=None, me=None, other_names=()):
    """The PR -> company map.

    `repos_by_company`: {slug: [local repo path]} for the locked companies.
    `remotes`: {local repo path: 'owner/name' or None} (None: no readable remote).
    `explicit_owners`: {slug: github_org}, the manifest's explicit owner mapping.
    `owner_types`: {owner lower: 'Organization' | 'User'}; an owner with no known type
    is treated as a personal account. `me`: the person's own GitHub login.
    `other_names`: repo folder names of companies outside the lock.

    Returns {'full': {owner/name: slug|AMBIGUOUS}, 'owner': {owner: slug|AMBIGUOUS},
    'other': {name}}, keys lower case. `owner` holds only organizations whose every
    known repo is one company's, plus explicit owners; never a personal account or `me`."""
    full, owner_sets = {}, {}
    types = {k.lower(): v for k, v in (owner_types or {}).items()}
    mine = (me or '').lower()

    def put(table, key, slug):
        prev = table.get(key)
        table[key] = slug if prev in (None, slug) else AMBIGUOUS

    for slug, paths in (repos_by_company or {}).items():
        for path in paths or []:
            fn = remotes.get(path)
            if fn:
                put(full, fn.lower(), slug)
                owner_sets.setdefault(fn.split('/', 1)[0].lower(), set()).add(slug)
    owner = {}
    for o, slugs in owner_sets.items():
        if o == mine or types.get(o) != 'Organization':
            continue  # a personal account (or unknown): match its repos by full name only
        owner[o] = next(iter(slugs)) if len(slugs) == 1 else AMBIGUOUS
    for slug, org in (explicit_owners or {}).items():
        if org and org.lower() != mine and types.get(org.lower(), 'Organization') == 'Organization':
            owner[org.lower()] = slug
    other = {str(n).lower() for n in other_names or () if n}
    return {'full': full, 'owner': owner, 'other': other}


def _gh_json(cmd, timeout=10):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    if r.returncode != 0:
        raise RuntimeError('gh failed')
    return json.loads(r.stdout)


def owner_types(owners, run_json, budget_s=OWNER_BUDGET_S):
    """({owner lower: account type}, my login or None) from `gh api users/<owner>` and
    `gh api user`, within `budget_s`. A failed read leaves the owner untyped."""
    todo = sorted({o for o in owners or () if isinstance(o, str) and re.fullmatch(r'[A-Za-z0-9-]{1,39}', o)})
    jobs = [('user', None)] + [(f'users/{o}', o) for o in todo]
    got = _bounded(lambda job: run_json(['gh', 'api', job[0]]), jobs, budget_s)
    types, me = {}, None
    for (path, o), v in got.items():
        if not isinstance(v, dict):
            continue
        if o is None:
            me = v.get('login') if isinstance(v.get('login'), str) else None
        elif isinstance(v.get('type'), str):
            types[o.lower()] = v['type']
    return types, me


def company_repo_map(hq_root, explicit_owners=None, companies=None, run_json=None):
    """build_repo_map over the manifest, reading git remotes only for the repos of
    `companies` (the session lock), and GitHub account types for their owners."""
    text = read_manifest(hq_root)
    all_repos = manifest_repos(text)
    locked = {c for c in companies or () if c != PERSONAL}
    repos = {slug: ps for slug, ps in all_repos.items() if slug in locked}
    locked_paths = {p for ps in repos.values() for p in ps}
    other_names = {os.path.basename(str(p).rstrip('/')) for slug, ps in all_repos.items()
                   if slug not in locked and slug != PERSONAL for p in ps if p not in locked_paths}
    paths = sorted(locked_paths)
    remotes = {}
    deadline = time.monotonic() + REMOTE_BUDGET_S
    for p in paths:
        if time.monotonic() > deadline:
            remotes[p] = None
            continue
        abs_p = p if os.path.isabs(p) else os.path.join(hq_root, p)
        remotes[p] = remote_full(_git_remote(abs_p)) if os.path.isdir(abs_p) else None
    explicit = {k: v for k, v in (explicit_owners or {}).items() if k in locked}
    owners = {fn.split('/', 1)[0] for fn in remotes.values() if fn} | {v for v in explicit.values() if v}
    types, me = owner_types(owners, run_json or _gh_json) if owners else ({}, None)
    return build_repo_map(repos, remotes, explicit, types, me, other_names)


def pr_company(row, repo_map):
    """The company a PR row belongs to: a slug, None (unmapped: the person's own) or
    AMBIGUOUS. `personal` in the manifest means the person's own (None)."""
    if not repo_map:
        return None
    rf = str(row.get('repo_full') or '').lower()
    hit = None
    if rf and rf in repo_map.get('full', {}):
        hit = repo_map['full'][rf]
    elif rf and '/' in rf and rf.split('/', 1)[0] in repo_map.get('owner', {}):
        hit = repo_map['owner'][rf.split('/', 1)[0]]
    else:
        nm = str(row.get('repo') or (rf.split('/', 1)[1] if '/' in rf else '')).lower()
        if nm and nm in repo_map.get('other', ()):
            return OTHER
    if hit == PERSONAL:
        return None
    return hit


def route_prs(rows, company, repo_map, org=None):
    """(kept, dropped count) of PR rows for one brief section.

    A company section keeps rows mapped to it, and unmapped rows under its explicit
    `org`. The personal section (company None) keeps only unmapped rows. AMBIGUOUS
    and OTHER rows are kept by no section. Kept rows get `company` (None for personal)."""
    kept, dropped = [], 0
    for r in rows or []:
        if not isinstance(r, dict):
            dropped += 1
            continue
        c = pr_company(r, repo_map)
        owner = str(r.get('repo_full') or '').split('/', 1)[0].lower()
        if c is AMBIGUOUS or c is OTHER:
            ok = False
        elif company:
            ok = c == company or (c is None and bool(org) and owner == org.lower())
        else:
            ok = c is None
        if ok:
            r['company'] = company
            kept.append(r)
        else:
            dropped += 1
    return kept, dropped


# ---------- DM sender -> company ----------

def roster_ids(payload, names_out=None):
    """Person ids and emails of active members in one `hq members list --json` payload.
    With `names_out`, also records {id: member name} for each id."""
    rows = payload if isinstance(payload, list) else next(
        (payload[k] for k in ('members', 'items', 'rows', 'data') if isinstance(payload, dict) and isinstance(payload.get(k), list)),
        None)
    if rows is None:
        raise ValueError('members JSON had no member list')
    ids = set()
    for r in rows:
        if not isinstance(r, dict):
            continue
        status = str(r.get('status') or 'active').lower()
        if status not in ('active', 'accepted'):
            continue
        name = r.get('name') if isinstance(r.get('name'), str) and r.get('name').strip() else None
        for k in ('person_id', 'personUid', 'person_uid', 'email'):
            v = r.get(k)
            if isinstance(v, str) and v.strip():
                ids.add(v.strip().lower())
                if names_out is not None and name:
                    names_out.setdefault(v.strip().lower(), name.strip())
    return ids


def sender_map(rosters):
    """{sender id: slug} for ids in exactly one roster. `rosters` is {slug: set(ids)}."""
    seen = {}
    for slug, ids in (rosters or {}).items():
        if slug == PERSONAL:
            continue
        for i in ids:
            seen[i] = slug if seen.get(i) in (None, slug) else AMBIGUOUS
    return {i: s for i, s in seen.items() if s is not AMBIGUOUS}


def _bounded(fn, jobs, budget_s, workers=6):
    """{job: result} for the jobs that finished inside `budget_s`. A job that raised or
    is still running at the deadline is left out; the call never waits past the budget."""
    out = {}
    if not jobs:
        return out
    ex = ThreadPoolExecutor(max_workers=workers)
    try:
        futs = {ex.submit(fn, j): j for j in jobs}
        try:
            for f in as_completed(futs, timeout=budget_s):
                try:
                    out[futs[f]] = f.result()
                except Exception:
                    continue
        except FuturesTimeout:
            pass
    finally:
        ex.shutdown(wait=False, cancel_futures=True)
    return out


def read_rosters(included, run_json, names_out=None, budget_s=ROSTER_BUDGET_S):
    """({slug: ids}, error or None) for the included companies. `run_json(cmd)` runs one
    CLI command and returns parsed JSON. With `names_out`, records {slug: {id: name}}.
    Any failure or a roster still unread at the budget returns ({}, reason): the caller
    must then turn sender attribution off."""
    slugs = [s for s in included or [] if isinstance(s, str) and s != PERSONAL and _SLUG.match(s)]
    if not slugs:
        return {}, None
    got = _bounded(lambda s: run_json(['hq', 'members', '--company', s, 'list', '--json']), slugs, budget_s)
    out = {}
    for s in slugs:
        if s not in got:
            return {}, 'could not read the member list of one company'
        try:
            names = names_out.setdefault(s, {}) if names_out is not None else None
            out[s] = roster_ids(got[s], names)
        except Exception:
            return {}, 'could not read the member list of one company'
    return out, None


def dm_company(message, senders):
    """(slug or None, basis) for one inbox message: the explicit slug on the message
    or its channel ('tag'), else the sender's one shared company ('sender'), else
    (None, None). `senders` None means attribution is off."""
    from_keys = ('fromPersonUid', 'fromEmail')
    if senders:
        for k in from_keys:
            v = message.get(k)
            if isinstance(v, str) and v.strip().lower() in senders:
                return senders[v.strip().lower()], 'sender'
    return None, None


# ---------- display names ----------

_HANDLE_CHARS = re.compile(r'[0-9_@./\\]')


def looks_like_handle(name):
    """True for a login or handle rather than a person's name: one word that is lower
    case, or holds digits, underscores, dots or an @ ("jdoe42", "zqhandle", "a.lee")."""
    if not isinstance(name, str):
        return False
    n = name.strip()
    if not n:
        return False
    if ' ' in n:
        return bool(_HANDLE_CHARS.search(n.split()[0]))
    return bool(_HANDLE_CHARS.search(n)) or n[:1].islower() or (n.isupper() and len(n) > 3)


def first_name(name):
    """The first word of a person's name, capitalised ("ann lee" -> "Ann")."""
    words = re.sub(r'\(.*?\)', ' ', name if isinstance(name, str) else '').split()
    if not words:
        return None
    w = words[0]
    return w[:1].upper() + w[1:] if w[:1].islower() else w


def _norm(s):
    return re.sub(r'[^a-z]', '', (s or '').lower())


def full_name_match(handle, full_names):
    """The one full name whose usual login shapes match `handle` (firstlast, flast,
    firstl, first.last), or None when none or several match."""
    h = _norm(handle)
    if len(h) < 4:
        return None
    hits = set()
    for full in full_names or []:
        words = [_norm(w) for w in (full or '').split() if _norm(w)]
        if len(words) < 2:
            continue
        f, l = words[0], words[-1]
        if h in (f + l, f[0] + l, f + l[0], l + f):
            hits.add(full)
    return hits.pop() if len(hits) == 1 else None


def display_name(raw, *, ids=(), names=None, full_names=(), github=None):
    """A person's display first name, from the best source that has a real name:
    the name itself, then the member lists (`names`, by id or email), then the GitHub
    profile name (`github`, by login), then a full name on a member list whose login
    shape matches the handle, then an email of the form first.last. Falls back to the
    raw handle when nothing resolves."""
    names, github = names or {}, github or {}
    cands = [raw]
    for i in ids:
        if isinstance(i, str) and i.strip():
            cands.append(names.get(i.strip().lower()))
    if raw:
        cands.append(github.get(str(raw).lower()))
    for c in cands:
        if c and not looks_like_handle(c):
            return first_name(c)
    for c in cands:
        hit = full_name_match(c, full_names) if c else None
        if hit:
            return first_name(hit)
    for i in list(ids) + [raw]:
        local = str(i or '').split('@')[0] if '@' in str(i or '') else ''
        parts = [p for p in re.split(r'[._-]', local) if p.isalpha() and len(p) > 1]
        if len(parts) >= 2:
            return first_name(parts[0])
    return raw


def github_names(logins, run_json, budget_s=15, limit=20):
    """{login lower: profile name} from `gh api users/<login>` for at most `limit`
    logins within `budget_s` seconds. Failures and blank names are left out."""
    out = {}
    todo = sorted({l for l in logins or [] if isinstance(l, str) and re.fullmatch(r'[A-Za-z0-9-]{1,39}', l)})[:limit]
    for l, v in _bounded(lambda l: run_json(['gh', 'api', f'users/{l}']), todo, budget_s, workers=5).items():
        name = v.get('name') if isinstance(v, dict) else None
        if isinstance(name, str) and name.strip():
            out[l.lower()] = name.strip()
    return out


def resolve_names(section, names, full_names, github):
    """Add `from_name` to each DM row and `author_name` to each PR row of one section.
    `names` and `full_names` must come from this section's own company only (empty for
    the personal section), so one company's member list never names another's people."""
    if not isinstance(section, dict):
        return section
    for m in section.get('dms') or []:
        if isinstance(m, dict) and (m.get('from') or m.get('from_uid')):
            name = display_name(m.get('from'), ids=[m.get('from_uid')], names=names, full_names=full_names)
            if name:
                m['from_name'] = name
    for p in section.get('prs') or []:
        if isinstance(p, dict) and p.get('author'):
            p['author_name'] = display_name(p['author'], names=names, full_names=full_names, github=github)
    return section


if __name__ == '__main__':
    import sys
    # Usage: brief_company.py <hq root> <locked company slug>...
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    m = company_repo_map(root, companies=sys.argv[2:])
    show = lambda v: '<ambiguous>' if v is AMBIGUOUS else v
    print(json.dumps({'full': {k: show(v) for k, v in m['full'].items()}, 'owner': {k: show(v) for k, v in m['owner'].items()},
                      'other': sorted(m['other'])}, indent=1, sort_keys=True))
