#!/usr/bin/env python3
"""Daily Brief housekeeping checks, each under a hard time budget.

Runs the every-run checks non-interactively and in parallel, then writes
`housekeeping.json` and a one-line summary into `status.json.housekeeping`.

Usage:
  python3 -I housekeeping.py [--company <slug>] --hq-root "$PWD" \
    --run-dir workspace/brief/<run_id> [--budget SECONDS]   (overrides BUDGETS_S)

Without --company the health check and sync are recorded as skipped (both
need a company); the worktree scan still runs.

Every check ends in exactly one honest status:
  "ran clean"                 finished, nothing to report
  "found N things"            finished, N findings (e.g. failing doctor checks)
  "skipped (took too long)"   hit its time budget and was stopped
  "failed: <reason>"          could not run (command missing, error exit)
  "skipped (needs a company)" not run because the brief has no company

Rules:
- stdin is /dev/null and every interactive prompt is pre-answered by flags, so
  nothing can wait on a TTY.
- Command output is parsed, never printed. Error text is trimmed and passed
  through redact() before it is stored.
- Nothing is deleted, killed or removed here. Destructive cleanup stays a
  proposal the user launches.
"""
import argparse, datetime as dt, json, os, re, signal, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

DEFAULT_BUDGET_S = 20
# hq doctor --json can take 12-18s alone and over 20s when the worktree scan
# runs beside it, so it gets more room.
BUDGETS_S = {'hq_doctor': 40, 'hq_sync': 30, 'worktree_scan': DEFAULT_BUDGET_S}
STALE_WORKTREE_DAYS = 7
NEEDS_COMPANY = 'needs a company'
# Checks that run against one company; without --company they are skipped.
COMPANY_CHECKS = ('hq_doctor', 'hq_sync')
LABELS = {'hq_doctor': 'Health check', 'hq_sync': 'Sync', 'worktree_scan': 'Worktree scan'}

# ---------- pure helpers (tested in test_brief_helpers.py) ----------
_SECRETISH = re.compile(
    r'(?i)(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{16,}|sk_(live|test)_[A-Za-z0-9]{8,}'
    r'|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+'
    r'|((?:token|secret|password|passwd|api[_-]?key|authorization)\s*[=:]\s*)\S+)')


def redact(text, limit=160):
    """Trim and mask anything that looks like a credential."""
    s = re.sub(r'\s+', ' ', str(text or '')).strip()
    s = _SECRETISH.sub(lambda m: (m.group(3) or '') + '[redacted]', s)
    return s[:limit]


def status_text(timed_out=False, error=None, found=0, skipped=None):
    if skipped:
        return f'skipped ({skipped})'
    if timed_out:
        return 'skipped (took too long)'
    if error:
        return f'failed: {error}'
    return f'found {found} thing{"" if found == 1 else "s"}' if found else 'ran clean'


def task_record(name, timed_out=False, error=None, found=0, summary='', duration_s=0.0, skipped=None):
    st = status_text(timed_out, redact(error, 120) if error else None, found, skipped)
    rec = {'ok': not (timed_out or error or skipped), 'status': st,
           'found': found if not (timed_out or error or skipped) else None,
           'summary': summary or f'{LABELS.get(name, name)}: {st}', 'error': redact(error) if error else None,
           'duration_s': round(duration_s, 1)}
    if skipped:
        rec['skipped_reason'] = skipped
    return rec


def skipped_record(name, reason=NEEDS_COMPANY):
    """A check left out on purpose, e.g. doctor or sync on a brief with no company."""
    return task_record(name, skipped=reason)


def headline(tasks):
    """One line for the app: '2 of 3 checks ran clean. Health check found 28 things.'"""
    clean = [n for n, t in tasks.items() if t['status'] == 'ran clean']
    rest = [f"{LABELS.get(n, n)} {t['status']}" for n, t in tasks.items() if t['status'] != 'ran clean']
    line = f'{len(clean)} of {len(tasks)} checks ran clean.'
    return line + (' ' + '; '.join(rest) + '.' if rest else '')


def doctor_findings(doc):
    """Failing checks in `hq doctor --json` output. Exit 1 only means FAIL > 0."""
    summ = (doc or {}).get('summary') or {}
    return int(summ.get('FAIL', 0) or 0)


def worktree_verdict(entries, now_ts, stale_days=STALE_WORKTREE_DAYS):
    """entries: [{path, dirty, last_commit_ts}] -> counts. Stale = clean and idle."""
    cutoff = now_ts - stale_days * 86400
    stale = [e for e in entries if not e.get('dirty') and (e.get('last_commit_ts') or 0) < cutoff]
    dirty = [e for e in entries if e.get('dirty')]
    return {'total': len(entries), 'stale': len(stale), 'dirty': len(dirty),
            'stale_paths': [e['path'] for e in stale][:50]}


def company_owners(hq_root):
    """{company slug: GitHub owner} from the `github_org` keys in
    companies/manifest.yaml. A missing or unreadable manifest is {}."""
    try:
        lines = open(os.path.join(hq_root, 'companies', 'manifest.yaml'), encoding='utf-8').read().splitlines()
    except OSError:
        return {}
    out, cur, inside, field_indent = {}, None, False, None
    for raw in lines:
        line = raw.split('#', 1)[0].rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 0:
            inside, cur = line.strip() == 'companies:', None
            continue
        if not inside:
            continue
        m = re.match(r'^ {2}([A-Za-z0-9_.-]+):$', line)
        if m:
            cur, field_indent = m.group(1), None
            continue
        if cur and field_indent is None:
            field_indent = indent  # the company's own keys; deeper lines (repos:) are not the company's owner
        m = re.match(r'^\s+github_org:\s*["\']?([A-Za-z0-9_.-]+)["\']?$', line)
        if cur and indent == field_indent and m:
            out[cur] = m.group(1)
    return out


def owner_in_scope(owner, company, owners):
    """True when GitHub `owner` may show in a brief for `company` (None = a
    personal brief). An owner mapped to another company, or to any company on a
    personal brief, is out of scope. Unmapped owners are the person's own."""
    if not owner:
        return True
    mapped = {o.lower(): c for c, o in (owners or {}).items()}
    c = mapped.get(owner.lower())
    return c is None or c == company


def remote_owner(url):
    """GitHub owner from a git remote URL (https or ssh), or None."""
    m = re.search(r'github\.com[:/]+([^/:\s]+)/[^/\s]+?(?:\.git)?/?$', (url or '').strip())
    return m.group(1) if m else None


def brief_reset_state(workspace_dir, current_run=None):
    """Detect a deliberate reset of workspace/brief.

    A missing or empty workspace/brief (no earlier run folders and no ready line
    in index.jsonl) with a sibling workspace/brief-backup-* folder is a reset the
    person did on purpose. It is a housekeeping note, never an incident.
    """
    brief = os.path.join(workspace_dir, 'brief')
    backups = sorted(d for d in (os.listdir(workspace_dir) if os.path.isdir(workspace_dir) else [])
                     if d.startswith('brief-backup-') and os.path.isdir(os.path.join(workspace_dir, d)))
    runs = []
    if os.path.isdir(brief):
        runs = [d for d in os.listdir(brief) if d.startswith('brief-') and d != current_run
                and os.path.isdir(os.path.join(brief, d))]
    ready = 0
    idx = os.path.join(brief, 'index.jsonl')
    if os.path.exists(idx):
        for line in open(idx, encoding='utf-8', errors='replace'):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if not isinstance(r, dict):
                continue
            if r.get('state') == 'ready' and r.get('run_id') != current_run:
                ready += 1
    empty = not runs and not ready
    reset = empty and bool(backups)
    note = (f'Brief history was reset on purpose; the old briefs are backed up in workspace/{backups[-1]}.'
            if reset else None)
    return {'prior_runs': len(runs), 'prior_ready': ready, 'empty': empty,
            'reset_on_purpose': reset, 'backups': backups, 'note': note}


# ---------- runners ----------
def _env():
    env = {k: v for k, v in os.environ.items() if k not in ('GH_TOKEN', 'GITHUB_TOKEN')}
    env.update({'CI': '1', 'NO_COLOR': '1', 'GIT_TERMINAL_PROMPT': '0'})
    return env


def run_bounded(cmd, budget_s, cwd=None):
    """Run cmd with no stdin; on timeout SIGTERM the process group, then SIGKILL.
    Returns (rc, stdout, stderr, timed_out)."""
    p = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, env=_env(), start_new_session=True)
    try:
        out, err = p.communicate(timeout=budget_s)
        return p.returncode, out, err, False
    except subprocess.TimeoutExpired:
        for sig, wait in ((signal.SIGTERM, 3), (signal.SIGKILL, 2)):
            try:
                os.killpg(p.pid, sig)
            except ProcessLookupError:
                break
            try:
                p.communicate(timeout=wait)
                break
            except subprocess.TimeoutExpired:
                continue
        return None, '', '', True


def check_doctor(company, root, budget):
    t0 = time.monotonic()
    try:
        rc, out, err, to = run_bounded(['hq', 'doctor', '--json', '--company', company], budget, cwd=root)
    except FileNotFoundError:
        return task_record('hq_doctor', error='hq is not installed')
    if to:
        return task_record('hq_doctor', timed_out=True, duration_s=time.monotonic() - t0)
    try:
        doc = json.loads(out[out.find('{'):])
    except ValueError:
        return task_record('hq_doctor', error=err or f'exit {rc}, no report', duration_s=time.monotonic() - t0)
    n = doctor_findings(doc)
    s = doc.get('summary') or {}
    summary = (f"Health check: {n} failing and {s.get('WARN', 0)} warnings out of {sum(v for v in s.values() if isinstance(v, int))} checks"
               if n else 'Health check: all checks pass')
    return task_record('hq_doctor', found=n, summary=summary, duration_s=time.monotonic() - t0)


def check_sync(company, root, budget):
    # --on-conflict abort: never prompt, never overwrite; --lock-timeout 0: never
    # wait on another HQ operation (the HQ Sync app often holds the lock).
    t0 = time.monotonic()
    cmd = ['hq', 'sync', 'now', '--company', company, '--hq-root', root,
           '--on-conflict', 'abort', '--lock-timeout', '0', '--message', 'daily-brief housekeeping']
    try:
        rc, out, err, to = run_bounded(cmd, budget, cwd=root)
    except FileNotFoundError:
        return task_record('hq_sync', error='hq is not installed')
    d = time.monotonic() - t0
    if to:
        return task_record('hq_sync', timed_out=True, duration_s=d)
    if rc != 0:
        text = (err or out or '').strip().splitlines()
        reason = text[-1] if text else f'exit {rc}'
        if re.search(r'(?i)conflict', err + out):
            m = re.search(r'(\d+)\s+conflict', err + out)
            n = int(m.group(1)) if m else 1
            return task_record('hq_sync', found=n, summary=f'Sync stopped on {n} conflict(s); nothing was overwritten', duration_s=d)
        if re.search(r'(?i)lock', err + out):
            return task_record('hq_sync', error='another HQ operation was running', duration_s=d)
        return task_record('hq_sync', error=reason, duration_s=d)
    return task_record('hq_sync', summary='Sync: up to date', duration_s=d)


def _git(path, args, timeout):
    return subprocess.run(['git', '--no-optional-locks', '-C', path] + args, capture_output=True, text=True,
                          stdin=subprocess.DEVNULL, timeout=timeout, env=_env())


def find_worktrees(root, max_depth=3):
    base = os.path.join(root, 'workspace', 'worktrees')
    found = []
    if not os.path.isdir(base):
        return found
    for cur, dirs, files in os.walk(base):
        depth = cur[len(base):].count(os.sep)
        if '.git' in files or '.git' in dirs:
            found.append(cur)
            dirs[:] = []
            continue
        if depth >= max_depth:
            dirs[:] = []
    return sorted(found)


def check_worktrees(root, budget, company=None, owners=None):
    """Worktrees under workspace/worktrees. A worktree whose origin owner is
    out of scope for the brief (owner_in_scope) is counted in `other` only:
    its path is never listed."""
    t0 = time.monotonic()
    deadline = t0 + budget
    paths = find_worktrees(root)

    def one(p):
        left = deadline - time.monotonic()
        if left <= 0.2:
            raise TimeoutError
        st = _git(p, ['status', '--porcelain', '--untracked-files=no'], min(5, left))
        lg = _git(p, ['log', '-1', '--format=%ct'], min(5, max(0.2, deadline - time.monotonic())))
        rm = _git(p, ['remote', 'get-url', 'origin'], min(5, max(0.2, deadline - time.monotonic())))
        return {'path': os.path.relpath(p, root), 'dirty': bool(st.stdout.strip()),
                'last_commit_ts': int(lg.stdout.strip() or 0), 'owner': remote_owner(rm.stdout)}

    entries, timed_out = [], False
    ex = ThreadPoolExecutor(max_workers=8)
    futs = [ex.submit(one, p) for p in paths]
    for f in futs:
        try:
            entries.append(f.result(timeout=max(0.1, deadline - time.monotonic())))
        except Exception:
            timed_out = time.monotonic() >= deadline - 0.2 or timed_out
            if timed_out:
                break
    ex.shutdown(wait=False, cancel_futures=True)
    d = time.monotonic() - t0
    if timed_out:
        return task_record('worktree_scan', timed_out=True, duration_s=d,
                           summary=f'Worktree scan: stopped after {len(entries)} of {len(paths)} worktrees')
    mine = [e for e in entries if owner_in_scope(e.get('owner'), company, owners)]
    v = worktree_verdict(mine, time.time())
    v['other'] = len(entries) - len(mine)
    rec = task_record('worktree_scan', found=v['stale'], duration_s=d,
                      summary=f"Worktree scan: {v['total']} worktrees, {v['stale']} idle over {STALE_WORKTREE_DAYS} days with no local changes, {v['dirty']} with local changes")
    rec['detail'] = v
    return rec


# ---------- files ----------
def _now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')


def _merge_json(path, fn):
    try:
        d = json.load(open(path)) if os.path.exists(path) else {}
    except Exception:
        d = {}
    fn(d)
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(d, f, indent=1, default=str)
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--company', default=None, help='company slug; without it doctor and sync are skipped')
    ap.add_argument('--hq-root', default=os.getcwd())
    ap.add_argument('--run-dir', required=True)
    ap.add_argument('--budget', type=float, default=None, help='hard seconds per check (default: BUDGETS_S)')
    ap.add_argument('--only', default='hq_doctor,hq_sync,worktree_scan')
    a = ap.parse_args()
    root = os.path.abspath(a.hq_root)
    run_dir = os.path.abspath(a.run_dir)
    run_id = os.path.basename(run_dir.rstrip(os.sep))
    status_path = os.path.join(run_dir, 'status.json')
    hk_path = os.path.join(run_dir, 'housekeeping.json')

    def act(label, state, detail=None):
        def f(s):
            s.setdefault('activity', []).append({'at': _now(), 'label': label, 'state': state, **({'detail': detail} if detail else {})})
            s['activity'] = s['activity'][-12:]
            s['housekeeping'] = {**(s.get('housekeeping') or {}), 'state': 'running' if state == 'running' else 'done', 'updated_at': _now()}
            s['updated_at'] = _now()
        _merge_json(status_path, f)

    act('Housekeeping', 'running', 'Health check, sync and worktree scan' if a.company else 'Worktree scan')
    b = lambda n: a.budget or BUDGETS_S.get(n, DEFAULT_BUDGET_S)
    checks = {'hq_doctor': lambda: check_doctor(a.company, root, b('hq_doctor')),
              'hq_sync': lambda: check_sync(a.company, root, b('hq_sync')),
              'worktree_scan': lambda: check_worktrees(root, b('worktree_scan'), a.company, company_owners(root))}
    wanted = [n for n in a.only.split(',') if n in checks]
    skipped = {}
    if not a.company:
        skipped = {n: skipped_record(n) for n in wanted if n in COMPANY_CHECKS}
        wanted = [n for n in wanted if n not in COMPANY_CHECKS]
    with ThreadPoolExecutor(max_workers=len(wanted) or 1) as ex:
        futs = {n: ex.submit(checks[n]) for n in wanted}
        tasks = dict(skipped)
        for n, f in futs.items():
            try:
                tasks[n] = f.result()
            except Exception as e:  # recorded, never raised past the brief
                tasks[n] = task_record(n, error=str(e))
    reset = brief_reset_state(os.path.join(root, 'workspace'), run_id)
    notes = [reset['note']] if reset['note'] else []
    line = headline(tasks)

    def hk(d):
        d['run_id'] = run_id
        d['tasks'] = {**(d.get('tasks') or {}), **tasks}
        d['notes'] = list(dict.fromkeys((d.get('notes') or []) + notes))
        d['headline'] = line
        d.setdefault('proposals', [])
        d['updated_at'] = _now()
    _merge_json(hk_path, hk)

    def st(s):
        s['housekeeping'] = {**(s.get('housekeeping') or {}), 'state': 'done', 'headline': line,
                             'checks': {n: t['status'] for n, t in tasks.items()}, 'updated_at': _now()}
        if s.get('activity') and s['activity'][-1].get('label') == 'Housekeeping':
            s['activity'][-1].update({'at': _now(), 'state': 'done', 'detail': line})
        s['updated_at'] = _now()
    _merge_json(status_path, st)
    # Statuses only; command output never reaches stdout.
    print(json.dumps({'housekeeping': hk_path, 'headline': line,
                      'checks': {n: t['status'] for n, t in tasks.items()}, 'notes': notes}))


if __name__ == '__main__':
    sys.exit(main())
