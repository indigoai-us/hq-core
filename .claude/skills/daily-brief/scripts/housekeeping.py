#!/usr/bin/env python3
"""Daily Brief housekeeping checks, each under a hard time budget.

Runs the every-run checks non-interactively and in parallel. As each check
ends, its record is written into the housekeeping file (`pending` lists the
checks still running), so a slow check never holds back the ones that finished.

Usage:
  python3 -I housekeeping.py [--company <slug>] --hq-root "$PWD" \
    --run-dir workspace/brief/<run_id> [--out <file in the run dir>] \
    [--budget SECONDS]   (overrides BUDGETS_S)
  python3 -I housekeeping.py --merge-proposals --run-dir workspace/brief/<run_id> [--out <file>]

Files:
  --out (default <run-dir>/housekeeping.json)  written only by this script, always
                                                under an exclusive lock on <out>.lock
  <out stem>.proposals.json                     written only by the brief writer;
                                                copied into --out on every write and
                                                by --merge-proposals
  status.json                                   never touched here
--out is housekeeping.json or housekeeping-<section>.json (lower case letters,
digits, - and _). The proposals file's extra dot means no --out name can ever
be a proposals file.

The lock is taken without blocking and retried until a deadline. The check
loop writes without it, after one warning on stderr, when the lock file cannot
be opened, locking is not supported there, or the lock stays held past the
deadline. --merge-proposals only ever writes under the lock: when it cannot
hold it, for any of those reasons, it exits 2 ("merge skipped") and writes
nothing, and the loop's next write copies the proposals in.

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
- A file that exists but cannot be parsed is never replaced: the write is
  skipped and retried on the next check.
"""
import argparse, datetime as dt, errno, json, os, re, signal, subprocess, sys, time
from contextlib import contextmanager
try:
    import fcntl
except ImportError:  # Windows
    fcntl = None
    import msvcrt
from concurrent.futures import ThreadPoolExecutor, as_completed

DEFAULT_BUDGET_S = 60
# Each budget covers what the check takes on a large HQ tree on a loaded
# machine. Each check's record is written as soon as it ends, so a long
# budget never holds back the other checks or brief.json.
BUDGETS_S = {'hq_doctor': 150, 'hq_sync': 480, 'worktree_scan': DEFAULT_BUDGET_S}
# `hq sync now --max-runtime` stops the sync itself (exit 124) after recording
# a failed pass, which is safer than a SIGTERM/SIGKILL in the middle of a
# transfer. It is set this far under the hard budget so the CLI's own report
# (bounded to 10s) finishes first; run_bounded's kill stays as the backstop.
# A budget too short to leave that margin gets no --max-runtime: the kill alone.
SYNC_RUNTIME_MARGIN_S = 20
SYNC_WATCHDOG_EXIT = 124
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


def headline(tasks, pending=()):
    """One line for the app: '2 of 3 checks ran clean. Health check found 28 things.'
    With checks still running: '1 of 3 checks ran clean so far. Sync still running.'"""
    clean = [n for n, t in tasks.items() if t['status'] == 'ran clean']
    rest = [f"{LABELS.get(n, n)} {t['status']}" for n, t in tasks.items() if t['status'] != 'ran clean']
    rest += [f"{LABELS.get(n, n)} still running" for n in pending]
    line = f"{len(clean)} of {len(tasks) + len(pending)} checks ran clean{' so far' if pending else ''}."
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


def sync_command(company, root, budget):
    """`hq sync now` for housekeeping. --max-runtime only when the budget leaves
    SYNC_RUNTIME_MARGIN_S for the CLI's own report before the hard kill."""
    cmd = ['hq', 'sync', 'now', '--company', company, '--hq-root', root,
           '--on-conflict', 'abort', '--lock-timeout', '0']
    max_runtime = int(budget) - SYNC_RUNTIME_MARGIN_S
    if max_runtime >= SYNC_RUNTIME_MARGIN_S:
        cmd += ['--max-runtime', str(max_runtime)]
    return cmd + ['--message', 'daily-brief housekeeping']


def check_sync(company, root, budget):
    # --on-conflict abort: never prompt, never overwrite; --lock-timeout 0: never
    # wait on another HQ operation (the HQ Sync app often holds the lock).
    # --max-runtime: the CLI stops itself cleanly before the hard budget.
    t0 = time.monotonic()
    cmd = sync_command(company, root, budget)
    try:
        rc, out, err, to = run_bounded(cmd, budget, cwd=root)
    except FileNotFoundError:
        return task_record('hq_sync', error='hq is not installed')
    d = time.monotonic() - t0
    if to or rc == SYNC_WATCHDOG_EXIT:
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


READ_TRIES, READ_WAIT_S = 3, 0.1
OUT_NAME = re.compile(r'^housekeeping(-[a-z0-9][a-z0-9_-]*)?\.json$')
_NOFOLLOW = getattr(os, 'O_NOFOLLOW', 0)


LOOP_LOCK_WAIT_S = 2.0   # the check loop's writes
MERGE_LOCK_WAIT_S = 5.0  # --merge-proposals
LOCK_RETRY_S = 0.05
MERGE_SKIPPED = 2
# errno values that mean "someone else holds it" rather than "cannot lock here"
_BUSY = {errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES, getattr(errno, 'EDEADLK', -1), getattr(errno, 'EDEADLOCK', -1)}
_warned = set()


class LockTimeout(Exception):
    """The lock is held by another process past the deadline."""


def _warn_once(key, text):
    if key not in _warned:
        _warned.add(key)
        print(f'housekeeping: {text}', file=sys.stderr)


def _try_lock(fd):
    if fcntl:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    else:
        os.lseek(fd, 0, 0)
        msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)


def _unlock(fd):
    if fcntl:
        fcntl.flock(fd, fcntl.LOCK_UN)
    else:
        os.lseek(fd, 0, 0)
        msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)


@contextmanager
def out_lock(out_path, wait_s=LOOP_LOCK_WAIT_S, on_timeout='raise'):
    """Exclusive lock on <out>.lock, shared by the check loop and
    --merge-proposals. Non-blocking, retried until `wait_s`. When the lock file
    cannot be opened or locking is unsupported, warn once and go on unlocked.
    When another process holds it past the deadline: raise LockTimeout
    (on_timeout='raise') or warn once and go on unlocked ('unlocked')."""
    try:
        fd = os.open(out_path + '.lock', os.O_RDWR | os.O_CREAT | _NOFOLLOW, 0o600)
    except OSError as e:
        _warn_once('open', f'cannot open the lock file ({e.strerror or e}); writing without a lock')
        yield False
        return
    locked = False
    try:
        deadline = time.monotonic() + wait_s
        while True:
            try:
                _try_lock(fd)
                locked = True
                break
            except OSError as e:
                if e.errno not in _BUSY:
                    _warn_once('lock', f'file locking is not available here ({e.strerror or e}); writing without a lock')
                    break
                if time.monotonic() >= deadline:
                    if on_timeout == 'raise':
                        raise LockTimeout(out_path) from None
                    _warn_once('busy', 'the lock is still held by another process; writing without it')
                    break
                time.sleep(LOCK_RETRY_S)
        yield locked
    finally:
        try:
            if locked:
                _unlock(fd)
        except OSError:
            pass
        finally:
            os.close(fd)


def read_json(path, tries=READ_TRIES, wait=READ_WAIT_S):
    """(ok, data). A missing file is (True, {}). A symlink, or a file that stays
    unreadable or is not a JSON object after `tries` reads, is (False, None)."""
    for i in range(tries):
        if os.path.islink(path):
            return False, None
        if not os.path.exists(path):
            return True, {}
        try:
            with open(path, encoding='utf-8') as f:
                d = json.load(f)
            if isinstance(d, dict):
                return True, d
        except (OSError, ValueError):
            pass
        if i < tries - 1:
            time.sleep(wait)
    return False, None


def write_owned_json(path, fn):
    """Read, update and atomically replace a file this script owns. Returns
    False, leaving the file untouched, when it exists but cannot be parsed."""
    ok, d = read_json(path)
    if not ok:
        print(f'housekeeping: {os.path.basename(path)} is not a readable JSON file; left as it is', file=sys.stderr)
        return False
    fn(d)
    tmp = f'{path}.{os.getpid()}.tmp'
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | _NOFOLLOW, 0o644)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        json.dump(d, f, indent=1, default=str)
    if os.path.islink(path):  # replaced by a link since the read: leave it
        os.unlink(tmp)
        return False
    os.replace(tmp, path)
    return True


def proposals_path(out_path):
    """The writer-owned proposals file beside a housekeeping file:
    housekeeping-acme.json -> housekeeping-acme.proposals.json."""
    return out_path[:-len('.json')] + '.proposals.json'


def resolve_out(run_dir, out):
    """--out as an absolute path directly in the run dir, or None unless its
    name is housekeeping.json or housekeeping-<section>.json in lower case,
    and it is not a symlink."""
    if not out:
        path = os.path.join(run_dir, 'housekeeping.json')
    elif os.path.dirname(out) == '':
        path = os.path.join(run_dir, out)  # a bare file name is taken inside the run dir
    else:
        path = os.path.abspath(out)
    if os.path.dirname(path) != run_dir or not OUT_NAME.match(os.path.basename(path)):
        return None
    if os.path.islink(path):
        return None
    return path


def copy_proposals(d, prop_path):
    """Copy the writer's proposals into d. An unreadable proposals file keeps
    what d already has. Returns False when it could not be read."""
    ok, prop = read_json(prop_path)
    if ok and isinstance(prop.get('proposals'), list):
        d['proposals'] = prop['proposals']
    d.setdefault('proposals', [])
    return ok


def merge_proposals(hk_path, wait_s=MERGE_LOCK_WAIT_S):
    """--merge-proposals: under the lock, re-read both files and copy the
    proposals into the housekeeping file. 0 on success, 1 when either file
    could not be read, 2 ("merge skipped") when it could not hold the lock:
    held by another process past `wait_s`, unsupported, or the lock file could
    not be opened. Nothing is written unless it returns 0."""
    prop_path = proposals_path(hk_path)
    try:
        with out_lock(hk_path, wait_s, on_timeout='raise') as locked:
            if not locked:
                print('housekeeping: merge skipped: no lock on this file system; a later check write copies the proposals',
                      file=sys.stderr)
                return MERGE_SKIPPED
            ok, prop = read_json(prop_path)
            if not ok:
                print(f'housekeeping: {os.path.basename(prop_path)} is not a readable JSON file; nothing merged', file=sys.stderr)
                return 1

            def f(d):
                copy_proposals(d, prop_path)
                d['updated_at'] = _now()
            return 0 if write_owned_json(hk_path, f) else 1
    except LockTimeout:
        print('housekeeping: merge skipped: the housekeeping file is locked by another process', file=sys.stderr)
        return MERGE_SKIPPED
    except OSError as e:
        print(f'housekeeping: merge failed ({e.strerror or e}); nothing merged', file=sys.stderr)
        return 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--company', default=None, help='company slug; without it doctor and sync are skipped')
    ap.add_argument('--hq-root', default=os.getcwd())
    ap.add_argument('--run-dir', required=True)
    ap.add_argument('--out', default=None,
                    help='housekeeping file in the run dir (default housekeeping.json)')
    ap.add_argument('--budget', type=float, default=None, help='hard seconds per check (default: BUDGETS_S)')
    ap.add_argument('--only', default='hq_doctor,hq_sync,worktree_scan')
    ap.add_argument('--merge-proposals', action='store_true',
                    help='only copy the writer\'s proposals file into the housekeeping file, then exit')
    a = ap.parse_args()
    root = os.path.abspath(a.hq_root)
    run_dir = os.path.abspath(a.run_dir)
    run_id = os.path.basename(run_dir.rstrip(os.sep))
    hk_path = resolve_out(run_dir, a.out)
    if hk_path is None:
        ap.error('--out must be housekeeping.json or housekeeping-<section>.json (lower case) directly in --run-dir, not a symlink')
    prop_path = proposals_path(hk_path)
    if a.merge_proposals:
        return merge_proposals(hk_path, MERGE_LOCK_WAIT_S)
    b = lambda n: a.budget or BUDGETS_S.get(n, DEFAULT_BUDGET_S)
    checks = {'hq_doctor': lambda: check_doctor(a.company, root, b('hq_doctor')),
              'hq_sync': lambda: check_sync(a.company, root, b('hq_sync')),
              'worktree_scan': lambda: check_worktrees(root, b('worktree_scan'), a.company, company_owners(root))}
    wanted = [n for n in a.only.split(',') if n in checks]
    skipped = {}
    if not a.company:
        skipped = {n: skipped_record(n) for n in wanted if n in COMPANY_CHECKS}
        wanted = [n for n in wanted if n not in COMPANY_CHECKS]
    reset = brief_reset_state(os.path.join(root, 'workspace'), run_id)
    notes = [reset['note']] if reset['note'] else []
    tasks = dict(skipped)

    def write(pending):
        """Write what has finished so far. Called after every check, so the
        brief can use early checks while a slow one runs. The writer's
        proposals are copied in read-only; a proposals file that cannot be
        parsed keeps the last copy."""
        line = headline(tasks, pending)

        def hk(d):
            d['run_id'] = run_id
            d['state'] = 'running' if pending else 'done'
            d['tasks'] = {**(d.get('tasks') or {}), **tasks}
            d['pending'] = list(pending)
            d['notes'] = list(dict.fromkeys((d.get('notes') or []) + notes))
            d['headline'] = line
            copy_proposals(d, prop_path)
            d['updated_at'] = _now()
        try:
            with out_lock(hk_path, LOOP_LOCK_WAIT_S, on_timeout='unlocked'):
                write_owned_json(hk_path, hk)
        except OSError as e:  # one failed write never stops the checks; the next write retries
            _warn_once('write', f'could not write {os.path.basename(hk_path)} ({e.strerror or e})')
        return line

    with ThreadPoolExecutor(max_workers=len(wanted) or 1) as ex:
        futs = {ex.submit(checks[n]): n for n in wanted}
        pending = list(wanted)
        line = write(pending)  # every check pending: the files exist from the start
        for f in as_completed(futs):
            n = futs[f]
            try:
                tasks[n] = f.result()
            except Exception as e:  # recorded, never raised past the brief
                tasks[n] = task_record(n, error=str(e))
            pending.remove(n)
            line = write(pending)
    # Statuses only; command output never reaches stdout.
    print(json.dumps({'housekeeping': hk_path, 'headline': line,
                      'checks': {n: t['status'] for n, t in tasks.items()}, 'notes': notes}))


if __name__ == '__main__':
    sys.exit(main())
