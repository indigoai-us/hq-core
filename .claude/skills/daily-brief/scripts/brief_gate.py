#!/usr/bin/env python3
"""Signals gate for the Daily Brief.

The brief waits for today's signals run to complete for every in-scope
company. When the run fails or the wait ends without fresh signals, the brief
still builds from its other sources, and the gate JSON carries `signals_stale`,
the notice the brief shows. This script reads the run records `hq signals run` writes
under workspace/signals/runs/{date}/ and writes the gate state the desktop
reads to workspace/signals/runs/{today}/brief-gate.json.

  check    Decide the gate for today. The gate JSON carries `state` and
           `action`; the exit code says what the caller does next:
             0 ready    build the brief
             0 off      build the brief: no morning job runs the signals
                        engine on this computer (see `engine`), so the brief
                        does not wait for a run and never starts one
             1 waiting  no usable record (none, stale lock, late start, an
                        incremental pass only, or a retry slot is due): start
                        a run
             2 failed   build the brief without fresh signals and do not start
                        a run (action build-stale). signals_stale holds the
                        notice. nextRetryAt says when the gate retries on its
                        own; it is null when the failure needs the person
                        (errorKind config or auth)
             3 running  a run holds the company lock: wait, never start a run
             4 error    the gate itself failed (an unexpected error or a usage
                        error): build the brief as with `off`. The gate fails
                        open, so an error here never holds the brief
           --retry-now (with --start-run) is the person's "Try now": failed
           companies are started again at once, whatever their retry slot,
           including one whose run wrote no record, refused to start or could
           not be started.
           --wait polls while the state is running, up to briefWaitMinutes
           (a timeout is written as failed). Use it after starting a run: a
           record that is still missing then is written as failed with a retry.
           --start-run (implies --wait) starts `hq signals run --trigger brief
           --json --company <slug>` in the background for each waiting company,
           at most once per call, and waits for it. The briefWaitMinutes limit
           counts from the first call that saw the run going (waitStartedAt in
           brief-gate.json), so it holds across calls. --max-seconds N returns
           exit 3 after N seconds of this call while the run is still going, so
           a caller with a short command timeout polls in short calls. A run
           still going at the limit is left running (its lock makes the next
           poll wait for it) and the gate is written as failed.
           signals_stale is written whenever the state is failed or waiting and
           never otherwise: {code, reason, detail, last_good_run, try_now, retry,
           next_retry_at, line, try_now_line, section_line, companies}. code is auth, config,
           run-failed, start-failed, timed-out, no-record or not-run. reason,
           line, try_now_line and section_line are fixed plain sentences the
           brief copies as given; line names no control (the brief page has no
           Try now), try_now_line is the Try now sentence for the closing reply.
           Dates in sentences are short ("Oct 1", human_date); last_good_run
           keeps the ISO date. last_good_run is {date, finished_at} of the newest earlier run
           folder (up to 30 days back) where the company was ready, or null.
           companies holds the same fields for each company that is not ready.
           A skipped run is not a good run: last_good_run needs a finished extract
           step. Every gate this command writes also carries staleCompanies, the
           notice of each company that has one: this call's, plus those of
           companies outside this call's scope, kept from the file as it was. The
           sweep reads a company's notice from there, so another session's check
           for a different company cannot drop it.
           Retry times are kept in brief-gate.json and never recomputed. A
           check without --start-run reads a due retry slot (exit 1) and leaves
           it; the slot is used only when a --start-run call starts the run, so
           a failed run is retried once per slot.
           After a wait timed out on a run that still holds its lock, later
           calls answer failed at once while that same lock is held, instead of
           waiting briefWaitMinutes again. --retry-now waits again.
  summary  Print yesterday's run summary and per-adapter freshness as JSON
           for the brief's signals section. Writes nothing.
  engine   Print whether a morning job runs the signals engine here, as JSON
           ({"on": bool, "source": ...}). Writes nothing, except when the engine
           is off and today's brief-gate.json is in another state (left from
           earlier in the day): that file is replaced once with an `off` gate.

The signals engine job is gated in hq-cli by the default-off flag
cli.bot-signals-engine-job. With the flag off, the bot's morning
hot-signal-sync job runs `hq sources sync` only and writes no run record, so
the gate is only enforced when the engine is known to run as a job:
HQ_FLAG_CLI_BOT_SIGNALS_ENGINE_JOB=true|1 in the environment (false|0 turns the
gate off), or else a run record or lock from a `--trigger job` run in today's
run folder, or in yesterday's until 2 hours past that job's time of day today.
So after the flag is turned off, the gate turns off once today's job time has
passed without a job record.

Known limit (hq-cli writes one record per company per day): an incremental
pass (`hq signals run --source ... --incremental`) rewrites {company}.json with
an extract-only record. The gate treats such a record as ready only when it
carries jobRanAt (a full job run finished earlier today); otherwise it asks for
a full run. A full run that failed earlier in the day and was then overwritten
by an incremental pass is not visible, and `summary` totals only the steps of
the last record of the day, so it undercounts on days with incremental passes.

Standard library only.
"""
import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DEFAULTS = {'maxTurns': 40, 'maxBudgetUsd': 2.0, 'lateStartHour': 22, 'briefWaitMinutes': 20}
# briefWaitMinutes is kept inside these bounds: 0 would fail every wait at once, and a wait
# longer than the lock's stale age (LOCK_STALE_HOURS) can never be reached.
WAIT_MINUTES_MIN, WAIT_MINUTES_MAX = 1, 180
# A company slug names files in the run folder, so it never holds a path separator.
SLUG_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]*')
RETRY_MINUTES = 15
LOCK_STALE_HOURS = 3
# Yesterday's job record keeps the engine "on" until this long past its time of day today.
JOB_GRACE_HOURS = 2
OK_STEP = {'ok', 'skipped', 'partial'}
# A skipped v2 record is ready unless the skip is a late start: running again
# would skip the same way (prefs-off, nothing-to-run, every step skipped).
NOT_READY_SKIPS = {'late-start'}
# A partial record whose adapters or extract step failed: ready (with a warning) only when
# the extract step still finished, else failed.
NO_SIGNALS_PARTIALS = {'step-failed:adapters', 'step-failed:extract'}
# Record-level error kinds the engine does not retry on its own (nextRetryAt null):
# a run started again would fail the same way until the person fixes it.
MANUAL_ERROR_KINDS = {'config', 'auth'}
STATE_OF = {'ready': 'ready', 'running': 'running', 'start': 'waiting', 'failed': 'failed'}
ENGINE_FLAG = 'cli.bot-signals-engine-job'
ENGINE_FLAG_ENV = 'HQ_FLAG_CLI_BOT_SIGNALS_ENGINE_JOB'
# Files in a run folder that are not per-company records.
NOT_COMPANY_FILES = {'summary', 'brief-gate', 'brief-run'}
RUN_OUTPUT_DIR = 'brief-runs'
EXIT = {'ready': 0, 'off': 0, 'waiting': 1, 'failed': 2, 'running': 3, 'error': 4}
# A running gate nobody has polled for this long was abandoned; the next call starts a fresh wait.
ABANDON_MINUTES = 5
# How far back the stale notice looks for the last good run.
STALE_LOOKBACK_DAYS = 30
# Fixed plain wording per reason code; the brief copies it as given.
STALE_REASON = {
    'auth': "today's signals run could not sign in to a connected account",
    'config': "today's signals run stopped on a setup problem",
    'run-failed': "today's signals run failed",
    'start-failed': "today's signals run could not be started",
    'timed-out': "today's signals run did not finish within {minutes} minutes and is still going",
    'no-record': "today's signals run stopped without finishing",
    'not-run': "today's signals run has not finished",
}
# What the reader can do about it without any control: the brief page has no Try now.
STALE_FIX = {
    'auth': 'Sign in again to clear it.',
    'config': 'Fix the setup to clear it.',
}
# The Try now sentence, for the closing reply only, where that option is offered.
STALE_TRY_NOW = {
    'auth': 'Sign in again, then press Try now to re-run signals and rebuild the brief.',
    'config': 'Fix the setup, then press Try now to re-run signals and rebuild the brief.',
    'timed-out': 'Press Try now to wait for the run and rebuild the brief.',
}
STALE_TRY_NOW_DEFAULT = 'Press Try now to re-run signals and rebuild the brief.'
# The gate-level code is the first of these any company has.
STALE_CODE_ORDER = ('auth', 'config', 'start-failed', 'timed-out', 'run-failed', 'no-record', 'not-run')
# Windows process creation flags (subprocess only defines them on Windows).
CREATE_NEW_PROCESS_GROUP = 0x00000200
CREATE_NO_WINDOW = 0x08000000
CREATE_BREAKAWAY_FROM_JOB = 0x01000000
NO_SCOPE_KEY = '*'


def now_utc(override=None):
    if override:
        return dt.datetime.fromisoformat(override.replace('Z', '+00:00')).astimezone(dt.timezone.utc)
    return dt.datetime.now(dt.timezone.utc)


def iso(t):
    return t.astimezone(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def load_settings(root):
    out = dict(DEFAULTS)
    p = Path(root) / 'core/settings/signals.yaml'
    if p.exists():
        for line in p.read_text().splitlines():
            m = re.match(r'^([A-Za-z]+):\s*([0-9.]+)\s*(#.*)?$', line)
            if m and m.group(1) in out:
                out[m.group(1)] = float(m.group(2)) if '.' in m.group(2) else int(m.group(2))
    out['briefWaitMinutes'] = min(max(out['briefWaitMinutes'], WAIT_MINUTES_MIN), WAIT_MINUTES_MAX)
    return out


def valid_slug(s):
    return isinstance(s, str) and SLUG_RE.fullmatch(s) is not None


def read_json(p):
    try:
        v = json.loads(Path(p).read_text())
    except (OSError, ValueError):
        return None
    return v if isinstance(v, dict) else None


def runs_dir(root, day):
    return Path(root) / 'workspace/signals/runs' / day


def parse_iso(s):
    try:
        return dt.datetime.fromisoformat(str(s).replace('Z', '+00:00')).astimezone(dt.timezone.utc)
    except (TypeError, ValueError):
        return None


def _win_pid_alive(pid):
    """Windows: os.kill(pid, 0) sends a console control event, so ask the kernel instead."""
    import ctypes
    from ctypes import wintypes
    kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel32.GetExitCodeProcess.restype = wintypes.BOOL
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL
    handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        return ctypes.get_last_error() == 5  # ERROR_ACCESS_DENIED: the process exists
    try:
        code = wintypes.DWORD()
        if not kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
            return True
        return code.value == 259  # STILL_ACTIVE
    finally:
        kernel32.CloseHandle(handle)


def pid_alive(pid):
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    if os.name == 'nt':
        return _win_pid_alive(pid)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def fresh(started_at, now):
    t = parse_iso(started_at)
    return t is not None and now - t < dt.timedelta(hours=LOCK_STALE_HOURS)


def failed_step(rec):
    return next((s for s in rec.get('steps') or [] if s.get('status') == 'failed'), None)


def extract_ran(rec):
    """True when the record's last extract step finished (ok or partial), so its signals are fresh."""
    ex = [s for s in rec.get('steps') or [] if s.get('name') == 'extract']
    return bool(ex) and ex[-1].get('status') in ('ok', 'partial')


def full_run(rec):
    """A run of every step starts with garden and adapters; an incremental pass runs extract only."""
    return any(s.get('name') in ('garden', 'adapters') for s in rec.get('steps') or [])


def company_state(d, co, rec, now):
    """Return (kind, detail) for one company: ready | running | start | failed.

    A live company lock ({pid, startedAt, trigger}, stale when the pid is gone or
    startedAt is older than 3 hours) means a run is going whatever the record says.
    `start` means no usable record: the caller may start a run. `failed` records get a
    retry slot in decide().
    """
    lock = read_json(d / f'{co}.lock')
    if lock is not None and pid_alive(lock.get('pid')) and fresh(lock.get('startedAt'), now):
        return 'running', {'reason': 'signals run in progress', 'step': (rec or {}).get('currentStep')}
    if rec is None:
        return 'start', {'reason': 'no run record yet'}
    v2 = (rec.get('schemaVersion') or 1) >= 2
    status = rec.get('status')
    if (v2 and status == 'running') or (not v2 and not rec.get('finishedAt')):
        # v2 runs hold the lock for the whole run, so a running record without a live lock is stale.
        # v1 records have no lock: the run counts as live while startedAt is under 3 hours old.
        if not v2 and lock is None and fresh(rec.get('startedAt'), now):
            return 'running', {'reason': 'signals run in progress', 'step': rec.get('currentStep')}
        return 'start', {'reason': 'stale lock: the last run stopped without finishing',
                         'step': rec.get('currentStep')}
    fs = failed_step(rec)
    late = rec.get('partialReason') if v2 else rec.get('partial')
    if v2:
        def failed(reason_default):
            return 'failed', {'reason': rec.get('failureReason') or (fs or {}).get('error') or reason_default,
                              'step': (fs or {}).get('name') or rec.get('currentStep'),
                              'errorKind': rec.get('errorKind'), 'nextRetryAt': rec.get('nextRetryAt'),
                              'v2': True}
        if status in ('complete', 'partial') and late != 'late-start' and not full_run(rec) \
                and not rec.get('jobRanAt'):
            return 'start', {'reason': 'only an incremental pass ran today, not a full signals run'}
        if status == 'complete':
            return 'ready', {}
        if status == 'partial' and late in NO_SIGNALS_PARTIALS:
            # The engine keeps going after a failed step, so judge by what ran: when extract
            # finished, signals are fresh for every source that did sync, and the brief builds
            # with a warning naming the failure instead of waiting on a reconnect all day.
            if extract_ran(rec):
                return 'ready', {'warning': rec.get('failureReason') or f'step {late.split(":", 1)[1]} failed',
                                 'errorKind': rec.get('errorKind')}
            return failed(f'step {late.split(":", 1)[1]} failed')
        if status == 'partial' and late != 'late-start':
            return 'ready', {}
        if status == 'skipped' and rec.get('skipReason') not in NOT_READY_SKIPS:
            return 'ready', {}
        if status == 'failed':
            return failed(f"step {fs.get('name')} failed" if fs else 'signals run failed')
    elif fs:
        return 'failed', {'reason': fs.get('error') or f"step {fs.get('name')} failed",
                          'step': fs.get('name'), 'errorKind': rec.get('errorKind'),
                          'nextRetryAt': rec.get('nextRetryAt')}
    if late == 'late-start':
        if rec.get('trigger') == 'brief':
            return 'failed', {'reason': 'the run started late and ran the garden step only',
                              'step': 'garden', 'errorKind': rec.get('errorKind'), 'nextRetryAt': None}
        return 'start', {'reason': 'late start: the morning job ran the garden step only'}
    if v2:
        return 'start', {'reason': f"signals run {status or 'unknown'}"
                         + (f" ({rec.get('skipReason')})" if rec.get('skipReason') else '')}
    if any(s.get('status') not in OK_STEP for s in rec.get('steps') or []):
        return 'start', {'reason': 'signals run incomplete', 'step': rec.get('currentStep')}
    return 'ready', {}


def in_scope(root, day, companies):
    if companies:
        return [c for c in companies.split(',') if c]
    summary = read_json(runs_dir(root, day) / 'summary.json') or {}
    names = []
    for c in summary.get('companies') or []:
        names.append(c if isinstance(c, str) else c.get('company') or c.get('slug'))
    names = [n for n in names if valid_slug(n)]
    if names:
        return names
    # No list and no summary.json: keep the companies the last gate judged, so a call
    # without --companies never drops their retry slots or a failed state the desktop shows.
    # An error pass carries that list forward (safe_main), so it never widens the set.
    prev = (read_json(runs_dir(root, day) / 'brief-gate.json') or {}).get('companies')
    names = [c for c in prev if valid_slug(c)] if isinstance(prev, dict) else []
    if names:
        return names
    # Nothing judged yet today: the companies with a record in today's run folder. Only
    # when no company is known at all does the caller fall back to one run for every
    # company, and then no record exists, so no company can be waiting on a manual fix.
    d = runs_dir(root, day)
    return sorted(p.stem for p in d.glob('*.json')
                  if p.stem not in NOT_COMPANY_FILES and valid_slug(p.stem)) if d.is_dir() else []


def slot_key(kind, rec, detail):
    rec = rec or {}
    if kind == 'failed':
        return f"failed|{rec.get('startedAt')}|{rec.get('finishedAt')}"
    return f"start|{rec.get('startedAt')}|{detail.get('reason')}"


def current_slot_key(root, day, co, now):
    d = runs_dir(root, day)
    rec = read_json(d / f'{co}.json')
    kind, detail = company_state(d, co, rec, now)
    return slot_key(kind, rec, detail)


def decide(root, day, companies, now, after_run=False, retry_now=False):
    """Build the gate. Retry slots persist in brief-gate.json and are never recomputed.

    A failed record's first slot is the record's nextRetryAt, or finishedAt + 15 minutes
    when the record has none. When a slot is due the gate answers start and leaves the
    slot where it is: decide() only reads slots, so a check that cannot start a run (no
    --start-run) never uses one. cmd_check moves the slot 15 minutes on when it starts the
    run (use_slot), so a run that never lands is retried at most once per slot.
    A new record (different startedAt or finishedAt) gets its own slot. A v2 record that
    failed with errorKind config or auth and no nextRetryAt gets no slot: it stays failed
    with retry "manual" until the person starts a run (a new record). With after_run
    (check --wait after a run was started), a company that still has no usable record
    is written as failed with a slot instead of asking for another start.
    """
    d = runs_dir(root, day)
    prev = (read_json(d / 'brief-gate.json') or {}).get('retries') or {}
    scope = in_scope(root, day, companies)
    if not isinstance(prev, dict):
        prev = {}
    # Slots of companies outside this call's scope are kept as they are.
    per, retries = {}, {k: v for k, v in prev.items() if k not in scope and k != NO_SCOPE_KEY}
    if isinstance(after_run, bool):
        after_all, after_set = after_run, set()
    else:
        after_set = set(after_run)
        after_all = NO_SCOPE_KEY in after_set
    for co in scope:
        rec = read_json(d / f'{co}.json')
        kind, detail = company_state(d, co, rec, now)
        v2_record = detail.pop('v2', False)
        co_after_run = after_all or co in after_set
        if kind == 'failed' and retry_now:
            # The person pressed Try now: start one run for this company whatever its slot says.
            kind, detail = 'start', dict(detail, reason=f"retry requested: {detail['reason']}", nextRetryAt=None,
                                         retryNow=True)
        elif kind == 'failed' and v2_record and detail.get('errorKind') in MANUAL_ERROR_KINDS \
                and not detail.get('nextRetryAt'):
            detail.update(nextRetryAt=None, retry='manual')
        elif kind in ('failed', 'start'):
            key = slot_key(kind, rec, detail)
            old = prev.get(co) if (prev.get(co) or {}).get('key') == key else None
            if kind == 'start' and old and retry_now:
                # Try now for a company the gate shows as failed with no record of its own (the
                # run wrote nothing, refused to start, or could not be started): start one run
                # now. Starting it uses the slot (use_slot), so the next automatic retry is
                # 15 minutes after the start.
                retries[co] = {'key': key, 'at': old.get('at')}
                kind, detail = 'start', dict(detail, reason=f"retry requested: {detail['reason']}",
                                             nextRetryAt=None, retryNow=True)
            elif kind == 'failed' or old or co_after_run:
                if old:
                    at = parse_iso(old.get('at'))
                elif kind == 'failed':
                    fin = parse_iso(rec.get('finishedAt'))
                    at = parse_iso(detail.get('nextRetryAt')) or (
                        fin + dt.timedelta(minutes=RETRY_MINUTES) if fin else now + dt.timedelta(minutes=RETRY_MINUTES))
                else:
                    at = now + dt.timedelta(minutes=RETRY_MINUTES)
                    detail = dict(detail, reason=f"the signals run ended without a finished record ({detail['reason']})")
                if at is None:
                    at = now + dt.timedelta(minutes=RETRY_MINUTES)
                due = now >= at
                if due and not co_after_run:
                    # Due: ask for a start and keep the slot. The call that starts the run
                    # moves it (use_slot); a read-only check must not use the retry.
                    kind, detail = 'start', dict(detail, reason=f"retry due: {detail['reason']}")
                    detail['nextRetryAt'] = None
                else:
                    if due:
                        # A run of this call just ended without a usable record: next slot.
                        at = now + dt.timedelta(minutes=RETRY_MINUTES)
                    kind = 'failed'
                    detail['nextRetryAt'] = iso(at)
                detail['retry'] = 'auto'
                retries[co] = {'key': key, 'at': iso(at)}
        per[co] = dict(state=STATE_OF[kind], **detail)
    gate = {'state': 'ready', 'action': 'build', 'today': day, 'checkedAt': iso(now), 'companies': per,
            'reason': None, 'currentStep': None, 'nextRetryAt': None, 'retry': None, 'errorKind': None,
            'retries': retries,
            'warnings': [f"{co}: {v['warning']}" for co, v in per.items() if v.get('warning')]}
    if not scope:
        # No company list and no summary.json. After a run this is a failure with a kept
        # retry slot, so a run that writes nothing is not started again on every poll.
        old = prev.get(NO_SCOPE_KEY) or {}
        at = parse_iso(old.get('at'))
        if at and retry_now and not after_all:
            # Try now after a no-company run that wrote nothing: start it again now.
            gate.update(state='waiting', action='start-run', retryNow=True,
                        reason='retry requested: the signals run ended without writing a company record')
            retries[NO_SCOPE_KEY] = {'key': NO_SCOPE_KEY, 'at': iso(at)}  # moved when the run starts
        elif after_all or at:
            if at is None or (after_all and now >= at):
                at = now + dt.timedelta(minutes=RETRY_MINUTES)
            if now >= at:
                # Due: the slot stays where it is until a call starts the run (use_slot).
                gate.update(state='waiting', action='start-run', reason='retry due: no run record yet')
            else:
                gate.update(state='failed', action='build-stale', nextRetryAt=iso(at), retry='auto',
                            reason='the signals run ended without writing a company record')
            retries[NO_SCOPE_KEY] = {'key': NO_SCOPE_KEY, 'at': iso(at)}
        else:
            gate.update(state='waiting', action='start-run', reason='no run record yet')
    for state, action in (('running', 'wait'), ('failed', 'build-stale'), ('waiting', 'start-run')):
        hits = [(k, v) for k, v in per.items() if v['state'] == state]
        if hits:
            if state == 'failed':
                # A failure the person must fix comes first: no automatic retry can clear the gate.
                hits.sort(key=lambda kv: kv[1].get('retry') != 'manual')
            co, v = hits[0]
            gate.update(state=state, action=action, reason=f'{co}: {v["reason"]}', currentStep=v.get('step'),
                        nextRetryAt=v.get('nextRetryAt') if state == 'failed' else None,
                        retry=v.get('retry') if state == 'failed' else None,
                        errorKind=v.get('errorKind'))
            break
    return gate


def _job_time(rec):
    return parse_iso(rec.get('jobRanAt')) or parse_iso(rec.get('startedAt'))


def engine_job_on(root, day, now, env=None):
    """Return (on, source): does a morning job run the signals engine on this computer?

    The local override HQ_FLAG_CLI_BOT_SIGNALS_ENGINE_JOB decides when set (true/1 on,
    false/0 off), the same override hq-cli reads for cli.bot-signals-engine-job. Otherwise
    the engine counts as on when today's run folder holds a company record from a
    `--trigger job` run (or one with jobRanAt set) or a lock held by a job run, or when
    yesterday's does and today's job time (yesterday's job time plus JOB_GRACE_HOURS) has
    not passed yet. A brief- or chat-started run does not turn the gate on.
    """
    env = os.environ if env is None else env
    raw = str(env.get(ENGINE_FLAG_ENV, '')).strip().lower()
    if raw in ('true', '1'):
        return True, 'env'
    if raw in ('false', '0'):
        return False, 'env'
    try:
        yesterday = (dt.date.fromisoformat(day) - dt.timedelta(days=1)).isoformat()
    except ValueError:
        yesterday = None
    source = 'no-job-record'
    for d in [day, yesterday]:
        if d is None:
            continue
        folder = runs_dir(root, d)
        if not folder.is_dir():
            continue
        times = []
        for p in sorted(folder.glob('*.json')):
            if p.stem in NOT_COMPANY_FILES:
                continue
            rec = read_json(p) or {}
            if rec.get('trigger') == 'job' or rec.get('jobRanAt'):
                times.append(('job-record', _job_time(rec)))
        for p in sorted(folder.glob('*.lock')):
            lock = read_json(p) or {}
            if lock.get('trigger') == 'job':
                times.append(('job-lock', parse_iso(lock.get('startedAt'))))
        if not times:
            continue
        kind = times[0][0]
        if d == day:
            return True, f'{kind}:{d}'
        latest = max((t for _, t in times if t is not None), default=None)
        if latest is not None and now <= latest + dt.timedelta(days=1, hours=JOB_GRACE_HOURS):
            return True, f'{kind}:{d}'
        source = 'job-not-seen-today'
    return False, source


def off_gate(day, now, source, retries=None, companies=None):
    # Retry slots and the company list are kept, so when the engine is turned on again later
    # the same day a call with no --companies still judges the same companies (including one
    # whose failure left no record) and uses their slots. The desktop ignores them for `off`.
    return {'state': 'off', 'action': 'build', 'today': day, 'checkedAt': iso(now),
            'companies': companies if isinstance(companies, dict) else {},
            'reason': ('no morning job runs the signals engine on this computer '
                       f'({ENGINE_FLAG} is off or no job run is recorded), so the brief does not wait for signals'),
            'engine': {'on': False, 'source': source}, 'currentStep': None, 'nextRetryAt': None,
            'retry': None, 'errorKind': None, 'retries': retries if isinstance(retries, dict) else {}}


def replace_stale_gate(root, day, now, source):
    """Engine off: replace a same-day gate file left in another state with an `off` gate.

    The desktop reads brief-gate.json first, so a `failed` or `running` file from earlier in
    the day (the engine was on, then turned off) would show "Waiting for signals" next to a
    finished brief. Only that case writes: with no file, or a file already `off`, nothing is
    written, so a normal flag-off brief still writes nothing. Retry slots are kept in case
    the engine is turned on again later the same day. A `running` or `waiting` gate checked
    in the last ABANDON_MINUTES is left alone: another session may still be polling that wait,
    and replacing it would drop its runPids, so its next call could start a second run.
    Returns True when it wrote.
    """
    prev = read_json(runs_dir(root, day) / 'brief-gate.json')
    if prev is None or prev.get('state') == 'off':
        return False
    checked = parse_iso(prev.get('checkedAt'))
    if prev.get('state') in ('running', 'waiting') and checked is not None \
            and now - checked < dt.timedelta(minutes=ABANDON_MINUTES):
        return False
    write_gate(root, day, off_gate(day, now, source, prev.get('retries'), prev.get('companies')))
    return True


def _past_days(day):
    try:
        d0 = dt.date.fromisoformat(day)
    except ValueError:
        return []
    return [(d0 - dt.timedelta(days=i)).isoformat() for i in range(1, STALE_LOOKBACK_DAYS + 1)]


def _ready_record(folder, co, now):
    """The company's record in a past run folder when it was a good run, else None.

    A good run is ready and its extract step finished, so it produced signals. A skipped
    run is ready for the gate (running again would skip the same way) but is not a good run.
    """
    rec = read_json(folder / f'{co}.json')
    if rec is None:
        return None
    try:
        return rec if company_state(folder, co, rec, now)[0] == 'ready' and extract_ran(rec) else None
    except Exception:  # noqa: BLE001 - an old record with an unexpected shape is not a good run
        return None


def last_good_run(root, day, co, now):
    """{date, finished_at} of the newest run folder before `day` where `co` was ready, or None.

    With co None (no company is known) it is the newest folder that holds company records
    and where every one of them was ready. Reads only.
    """
    for past in _past_days(day):
        folder = runs_dir(root, past)
        if not folder.is_dir():
            continue
        if co is not None:
            rec = _ready_record(folder, co, now)
            if rec is not None:
                return {'date': past, 'finished_at': rec.get('finishedAt')}
            continue
        names = sorted(p.stem for p in folder.glob('*.json')
                       if p.stem not in NOT_COMPANY_FILES and valid_slug(p.stem))
        recs = [_ready_record(folder, n, now) for n in names]
        if recs and all(r is not None for r in recs):
            ends = sorted(str(r.get('finishedAt')) for r in recs if r.get('finishedAt'))
            return {'date': past, 'finished_at': ends[-1] if ends else None}
    return None


MONTHS = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec')


def human_date(iso, today=None):
    """A date as a person reads it: "Oct 1", with the year only when it is not today's year
    ("Oct 1, 2025"). `iso` and `today` are YYYY-MM-DD (longer ISO strings are cut to the
    date). Every date this feature shows to a person goes through here; machine fields keep
    the ISO date. Text that is not a date comes back unchanged."""
    try:
        d = dt.date.fromisoformat(str(iso)[:10])
    except ValueError:
        return str(iso)
    try:
        this_year = dt.date.fromisoformat(str(today)[:10]).year
    except ValueError:
        this_year = None
    short = f'{MONTHS[d.month - 1]} {d.day}'
    return short if d.year == this_year else f'{short}, {d.year}'


def _stale_entry(code, good, minutes, day=None):
    reason = STALE_REASON[code].format(minutes=minutes)
    if good:
        when = human_date(good['date'], day)
        used = f"This brief uses signals from the last good run on {when}."
        section = f"From the last good signals run on {when}, not from today."
    else:
        used = 'No earlier good signals run was found.'
        section = 'No good signals run was found, so these signals may be out of date.'
    return {'code': code, 'reason': reason, 'last_good_run': good, 'try_now': True,
            # `line` names nothing the brief page does not have; `try_now_line` is for the reply.
            'line': f"Signals are stale: {reason}. {used} {STALE_FIX.get(code, '')}".strip(),
            'try_now_line': STALE_TRY_NOW.get(code, STALE_TRY_NOW_DEFAULT),
            'section_line': section}


def _stale_code(root, day, co, entry, now, hint):
    state = entry.get('state')
    if state == 'failed' and entry.get('retry') == 'manual' and entry.get('errorKind') in MANUAL_ERROR_KINDS:
        return entry['errorKind']
    if hint == 'start-failed':
        return hint
    d = runs_dir(root, day)
    if state == 'failed' and company_state(d, co, read_json(d / f'{co}.json'), now)[0] == 'failed':
        return 'run-failed'
    if hint:
        return hint
    return 'no-record' if state == 'failed' else 'not-run'


def stale_notice(root, day, gate, now, hint=None):
    """The `signals_stale` object for a gate that is failed or waiting.

    The brief builds without fresh signals and shows this notice, so every sentence in it
    is fixed here. `hint` is the code of a failure only cmd_check can see (a wait that
    timed out, a run that could not be started). Reads only.
    """
    minutes = gate.get('waitMinutes', DEFAULTS['briefWaitMinutes'])
    per = {}
    for co, entry in gate['companies'].items():
        if not isinstance(entry, dict) or entry.get('state') == 'ready':
            continue
        code = _stale_code(root, day, co, entry, now, hint)
        per[co] = _stale_entry(code, last_good_run(root, day, co, now), minutes, day)
    if per:
        code = next(c for c in STALE_CODE_ORDER if any(v['code'] == c for v in per.values()))
        goods = [v['last_good_run'] for v in per.values()]
        # The notice names the oldest of the companies' last good runs, or none when one has none.
        good = min(goods, key=lambda g: g['date']) if all(goods) else None
    else:
        code = hint or ('no-record' if gate['state'] == 'failed' else 'not-run')
        good = last_good_run(root, day, None, now)
    out = _stale_entry(code, good, minutes, day)
    out.update(detail=gate.get('reason'), retry=gate.get('retry'), next_retry_at=gate.get('nextRetryAt'),
               companies=per)
    return out


def kept_stale(root, day, in_scope_now):
    """Stale notices of companies outside this call's scope, read from the gate file as it is now.

    brief-gate.json is one file per day for every session. A check for one company must
    not drop the notice another company's brief still reads, so every write carries the
    other companies' entries forward in `staleCompanies`. A company in this call's scope
    is judged again and gets its entry only from this call.
    """
    old = (read_json(runs_dir(root, day) / 'brief-gate.json') or {}).get('staleCompanies')
    if not isinstance(old, dict):
        return {}
    return {k: v for k, v in old.items() if valid_slug(k) and isinstance(v, dict) and k not in in_scope_now}


def write_gate(root, day, gate):
    p = runs_dir(root, day) / 'brief-gate.json'
    p.parent.mkdir(parents=True, exist_ok=True)
    # A temp file of its own in the same folder, then an atomic rename: two writers (a check
    # and the engine probe, or two checks) never share a temp file, so neither can rename the
    # other's half-written file into place or lose its own.
    fd, tmp = tempfile.mkstemp(dir=str(p.parent), prefix='.brief-gate.', suffix='.tmp')
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(json.dumps(gate, indent=2) + '\n')
        os.replace(tmp, p)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return p


def run_command(a, company=None):
    if a.run_cmd:
        cmd = json.loads(a.run_cmd)
    else:
        # shutil.which applies PATHEXT, so the npm shim hq.cmd is found on Windows.
        cmd = [shutil.which('hq') or 'hq', 'signals', 'run', '--trigger', 'brief', '--json',
               '--hq-root', str(a.hq_root)]
    return cmd + (['--company', company] if company else [])


def popen_detached(cmd, **kw):
    """Start cmd so it outlives this check.

    POSIX: its own session. Windows: its own process group with no console window
    (CREATE_NO_WINDOW; DETACHED_PROCESS is not used because Windows ignores CREATE_NO_WINDOW
    with it, and hq.cmd's node child would then open a visible console). Windows does not
    end a child when its parent exits; CREATE_BREAKAWAY_FROM_JOB also takes it out of a
    kill-on-close job the agent host may run commands in, and is dropped when that job
    does not allow breakaway.
    """
    if os.name != 'nt':
        return subprocess.Popen(cmd, start_new_session=True, **kw)
    flags = CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW
    try:
        return subprocess.Popen(cmd, creationflags=flags | CREATE_BREAKAWAY_FROM_JOB, **kw)
    except PermissionError:
        return subprocess.Popen(cmd, creationflags=flags, **kw)


def start_signals_run(root, day, cmd, company=None):
    """Start one signals run detached from this check, so it outlives the check and its time limit.

    Output goes to a new file pair under {run folder}/brief-runs/ per start, so two
    callers never truncate each other's output.
    """
    out_dir = runs_dir(root, day) / RUN_OUTPUT_DIR
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = f"{company or 'all'}-{int(time.time() * 1000)}-{os.getpid()}"
    with open(out_dir / f'{stem}.json', 'x') as out, open(out_dir / f'{stem}.log', 'x') as err:
        proc = popen_detached(cmd, cwd=str(root), stdin=subprocess.DEVNULL, stdout=out, stderr=err)
    proc.log_path = out_dir / f'{stem}.log'
    proc.out_rel = str((out_dir / f'{stem}.json').relative_to(root))
    return proc


def log_tail(path):
    try:
        lines = [ln.strip() for ln in Path(path).read_text().splitlines() if ln.strip()]
    except OSError:
        lines = []
    return lines[-1][:300] if lines else 'no message'


def live_locks(root, day, companies, now):
    """{company: lock startedAt} for every in-scope company whose lock is held by a live run."""
    d, out = runs_dir(root, day), {}
    for co in in_scope(root, day, companies):
        lock = read_json(d / f'{co}.lock')
        if lock is not None and pid_alive(lock.get('pid')) and fresh(lock.get('startedAt'), now):
            out[co] = str(lock.get('startedAt'))
    return out


def any_run_going(root, day, companies, now):
    """True while any in-scope company counts as running: a live lock, or a v1 running record."""
    d = runs_dir(root, day)
    return any(company_state(d, co, read_json(d / f'{co}.json'), now)[0] == 'running'
               for co in in_scope(root, day, companies))


def use_slot(gate, key, now):
    """A run was started for this slot: the next automatic retry is 15 minutes on."""
    slot = gate['retries'].get(key)
    if isinstance(slot, dict):
        slot['at'] = iso(now + dt.timedelta(minutes=RETRY_MINUTES))


def timed_out_retry_at(timed, now):
    """The retry time for a wait that already timed out: 15-minute steps from the timeout."""
    at = (parse_iso(timed.get('at')) or now) + dt.timedelta(minutes=RETRY_MINUTES)
    while at <= now:
        at += dt.timedelta(minutes=RETRY_MINUTES)
    return at


def cmd_check(a):
    root = a.hq_root
    wait = a.wait or a.start_run
    start = now_utc(a.now)
    on, source = engine_job_on(root, a.today, start)
    if not on:
        # Settings are not read on the off path, so a broken signals.yaml cannot touch it.
        prev = read_json(runs_dir(root, a.today) / 'brief-gate.json') or {}
        gate = off_gate(a.today, start, source, prev.get('retries'), prev.get('companies'))
        write_gate(root, a.today, gate)
        print(json.dumps(gate))
        return EXIT['off']
    settings = load_settings(root)
    wait_s = a.wait_seconds if a.wait_seconds is not None else settings['briefWaitMinutes'] * 60
    # A wait an earlier call left running (for example one cut off by a command timeout)
    # carries its run pids and start time, so this call neither starts a second run nor
    # restarts the time limit. A wait nobody has polled for ABANDON_MINUTES was abandoned
    # (the session ended), and a wait whose runs have all ended with no lock held has
    # nothing left to wait for: either way this call starts a fresh wait.
    prev = read_json(runs_dir(root, a.today) / 'brief-gate.json') or {}
    prev_running = prev.get('state') == 'running'
    last_poll = parse_iso(prev.get('checkedAt'))
    if prev_running and (last_poll is None or start - last_poll > dt.timedelta(minutes=ABANDON_MINUTES)):
        prev_running = False
    inherited = {k: v for k, v in (prev.get('runPids') or {}).items()} if prev_running else {}
    wait_started = parse_iso(prev.get('waitStartedAt')) if prev_running else None
    if wait_started is not None and not any(pid_alive(v) for v in inherited.values()) \
            and not any_run_going(root, a.today, a.companies, start):
        wait_started = None
    # A wait that timed out on a run still holding its lock: while that same lock is held,
    # later calls answer failed at once instead of waiting briefWaitMinutes again, so a hung
    # run costs one wait, not one per pass until its lock goes stale. Try now waits again.
    timed = prev.get('waitTimedOut') if not a.retry_now else None
    if not (isinstance(timed, dict) and isinstance(timed.get('locks'), dict) and timed['locks']):
        timed = None
    outputs = list(prev.get('runOutput') or []) if prev_running else []
    procs = {}
    tried = bool(inherited)
    waited = 0.0
    while True:
        hint = None  # the stale notice's code for a failure only this call can see
        now = now_utc(a.now) if a.now else dt.datetime.now(dt.timezone.utc)
        # With a fixed test clock, elapsed time is the sum of the polls slept.
        call_elapsed = waited if a.now else (now - start).total_seconds()
        live = {k: v for k, v in inherited.items() if pid_alive(v)}
        live.update({k: p.pid for k, p in procs.items() if p.poll() is None})
        # A missing record counts as "the run wrote nothing" only once no run of ours is going,
        # and only for the companies a run was started for.
        started = set(procs) | set(inherited)
        if live:
            after_run = False
        elif a.wait:
            after_run = True
        elif tried:
            after_run = started or True
        else:
            after_run = False
        gate = decide(root, a.today, a.companies, now, after_run=after_run,
                      retry_now=a.retry_now and not tried)
        gate['waitMinutes'] = settings['briefWaitMinutes']
        gate['engine'] = {'on': True, 'source': source}
        gate['staleCompanies'] = kept_stale(root, a.today, gate['companies'])
        if a.retry_now and not tried:
            # Try now restarts the failed companies only (with or without a record of their
            # own); a company that is only waiting keeps waiting for the brief job's own start.
            targets = [k for k, v in gate['companies'].items() if v.get('retryNow')]
            if not gate['companies'] and gate.get('retryNow'):
                targets = [None]
        elif gate['companies']:
            targets = [k for k, v in gate['companies'].items() if v['state'] == 'waiting']
        else:
            targets = [None]  # no company list at all: one run for every company
        if a.start_run and not tried and gate['state'] == 'waiting' and targets:
            tried = True
            try:
                for co in targets:
                    p = start_signals_run(root, a.today, run_command(a, co), co)
                    procs[co or NO_SCOPE_KEY] = p
                    outputs.append(p.out_rel)
                    use_slot(gate, co or NO_SCOPE_KEY, now)
            except OSError as e:
                at = iso(now + dt.timedelta(minutes=RETRY_MINUTES))
                reason = f'could not start hq signals run: {e.strerror or e}'
                gate.update(state='failed', action='build-stale', currentStep=None, errorKind='config', retry='auto',
                            reason=reason, nextRetryAt=at)
                hint = 'start-failed'
                # Give each company that was not started a slot, so the next poll does not start
                # it before the retry time and Try now knows it failed.
                for co in targets:
                    if co is not None and co in procs:
                        continue
                    if co is None:
                        gate['retries'][NO_SCOPE_KEY] = {'key': NO_SCOPE_KEY, 'at': at}
                        continue
                    gate['retries'][co] = {'key': current_slot_key(root, a.today, co, now), 'at': at}
                    entry = {k: v for k, v in gate['companies'][co].items() if k != 'retryNow'}
                    gate['companies'][co] = dict(entry, state='failed', reason=reason, nextRetryAt=at, retry='auto')
                break
            live.update({k: p.pid for k, p in procs.items()})
        refused = [p for p in procs.values() if p.poll() == 2]
        if live and gate['state'] in ('waiting', 'failed'):
            # Our run has not written its record yet, or the record is the earlier one it replaces.
            gate.update(state='running', action='wait', reason='signals run in progress', nextRetryAt=None,
                        retry=None)
        elif refused and gate['state'] != 'ready':
            gate.update(state='failed', action='build-stale', errorKind='config', retry='auto',
                        reason=f'hq signals run refused to start: {log_tail(refused[0].log_path)}',
                        nextRetryAt=gate.get('nextRetryAt') or iso(now + dt.timedelta(minutes=RETRY_MINUTES)))
            hint = 'start-failed'
        gate['runOutput'] = outputs
        if timed and gate['state'] == 'running' and not live:
            held = live_locks(root, a.today, a.companies, now)
            if held and all(timed['locks'].get(co) == at for co, at in held.items()):
                gate.update(state='failed', action='build-stale', retry='auto',
                            reason=(f"timed out after {settings['briefWaitMinutes']} minutes and the run "
                                    f"is still going: {gate['reason']}"),
                            nextRetryAt=iso(timed_out_retry_at(timed, now)), waitTimedOut=timed)
                hint = 'timed-out'
        if gate['state'] == 'running':
            wait_started = wait_started or now
            gate['waitStartedAt'] = iso(wait_started)
            gate['runPids'] = live
        if gate['state'] != 'running' or not wait:
            break
        total = (now - wait_started).total_seconds() + (waited if a.now else 0)
        if total >= wait_s:
            gate.update(state='failed', action='build-stale', retry='auto',
                        reason=f"timed out after {settings['briefWaitMinutes']} minutes: {gate['reason']}",
                        nextRetryAt=iso(now + dt.timedelta(minutes=RETRY_MINUTES)))
            gate.pop('waitStartedAt', None)  # runPids stays: the run left going
            hint = 'timed-out'
            held = live_locks(root, a.today, a.companies, now)
            if held:
                gate['waitTimedOut'] = {'at': iso(now), 'locks': held}
            break
        if a.max_seconds is not None and call_elapsed >= a.max_seconds:
            break
        write_gate(root, a.today, gate)
        time.sleep(a.poll_seconds)
        waited += a.poll_seconds
    if gate['state'] in ('failed', 'waiting'):
        # No fresh signals: the brief builds from its other sources and shows this notice.
        gate['signals_stale'] = stale_notice(root, a.today, gate, now, hint)
        gate['staleCompanies'].update(gate['signals_stale']['companies'])
    write_gate(root, a.today, gate)
    print(json.dumps(gate))
    return EXIT[gate['state']]


def step(rec, name):
    for s in rec.get('steps') or []:
        if s.get('name') == name:
            return s
    return {}


def cmd_summary(a):
    day = a.date or (dt.date.fromisoformat(a.today) - dt.timedelta(days=1)).isoformat()
    d = runs_dir(a.hq_root, day)
    scope = in_scope(a.hq_root, day, a.companies) or sorted(
        p.stem for p in d.glob('*.json') if p.stem not in NOT_COMPANY_FILES)
    out = {'date': day, 'found': False, 'companies': [], 'itemsIn': 0, 'signalsOut': 0,
           'catchUp': False, 'estimatedSpendUsd': 0.0, 'maxBudgetUsd': None, 'status': None,
           'byAdapter': {}, 'freshness': [], 'source': str(d.relative_to(a.hq_root))}
    for co in scope:
        rec = read_json(d / f'{co}.json')
        if not rec:
            continue
        out['found'] = True
        ex, ad = step(rec, 'extract'), step(rec, 'adapters')
        out['companies'].append(co)
        out['itemsIn'] += ex.get('itemsIn') or 0
        out['signalsOut'] += ex.get('itemsOut') or 0
        out['estimatedSpendUsd'] += ex.get('estimatedSpendUsd') or 0
        out['catchUp'] = out['catchUp'] or bool(rec.get('catchUp'))
        if rec.get('maxBudgetUsd') is not None:
            out['maxBudgetUsd'] = (out['maxBudgetUsd'] or 0) + rec['maxBudgetUsd']
        for k, v in (ad.get('byAdapter') or {}).items():
            out['byAdapter'][k] = out['byAdapter'].get(k, 0) + (v or 0)
    summary = read_json(d / 'summary.json')
    if summary:
        out['status'] = summary.get('status')
    out['estimatedSpendUsd'] = round(out['estimatedSpendUsd'], 2)
    wm = Path(a.hq_root) / 'workspace/signals/watermarks'
    for co in scope:
        for p in sorted((wm / co).glob('*.json')):
            cur = read_json(p) or {}
            at = cur.get('updatedAt') or cur.get('cursorAt') or cur.get('lastSyncedAt')
            out['freshness'].append({'company': co, 'adapter': p.stem, 'lastSynced': at,
                                     'source': str(p.relative_to(a.hq_root))})
    print(json.dumps(out))
    return 0


def cmd_engine(a):
    now = now_utc(a.now)
    on, source = engine_job_on(a.hq_root, a.today, now)
    if not on:
        try:
            replace_stale_gate(a.hq_root, a.today, now, source)
        except OSError:
            pass  # best effort: the probe's answer still stands and the brief builds
    print(json.dumps({'on': on, 'source': source, 'flag': ENGINE_FLAG}))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    for name in ('check', 'summary', 'engine'):
        p = sub.add_parser(name)
        p.add_argument('--hq-root', default='.')
        p.add_argument('--today', required=True, help='local date YYYY-MM-DD')
        p.add_argument('--companies', default='', help='comma-separated in-scope company slugs')
        if name in ('check', 'engine'):
            p.add_argument('--now', default=None, help='fixed clock for tests (ISO UTC)')
        if name == 'check':
            p.add_argument('--wait', action='store_true')
            p.add_argument('--start-run', action='store_true',
                           help='when waiting, start hq signals run --trigger brief once and wait for it')
            p.add_argument('--max-seconds', type=float, default=None,
                           help='return exit 3 after this many seconds of this call while the run is going')
            p.add_argument('--wait-seconds', type=float, default=None)
            p.add_argument('--poll-seconds', type=float, default=15)
            p.add_argument('--retry-now', action='store_true',
                           help='with --start-run: start a run for failed companies now (Try now)')
            p.add_argument('--run-cmd', default=None, help=argparse.SUPPRESS)
        elif name == 'summary':
            p.add_argument('--date', default=None, help='run date to summarise (default: yesterday)')
    a = ap.parse_args(argv)
    # --today names a folder under workspace/signals/runs/, so accept a real YYYY-MM-DD date only.
    if not valid_day(a.today):
        raise ValueError(f'--today must be a YYYY-MM-DD date: {a.today!r}')
    # --companies names files in the run folder: a slug with a path part is refused.
    bad = [c for c in a.companies.split(',') if c and not valid_slug(c)]
    if bad:
        raise ValueError(f'--companies holds a value that is not a company slug: {bad[0]!r}')
    return {'check': cmd_check, 'summary': cmd_summary, 'engine': cmd_engine}[a.cmd](a)


def valid_day(s):
    if not isinstance(s, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', s):
        return False
    try:
        dt.date.fromisoformat(s)
    except ValueError:
        return False
    return True


def _arg(argv, name):
    if name in argv[:-1]:
        return argv[argv.index(name) + 1]
    return None


def safe_main(argv=None):
    """Fail open: an error in the gate itself never holds the brief.

    Any unexpected error (or a usage error) prints {"state": "error", ...} and exits 4,
    which the skill treats like `off`: build the brief as before. The error is also written
    to brief-gate.json when the run folder can be written.
    """
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        return main(argv)
    except SystemExit as e:
        if e.code in (0, None):
            return 0
        err = f'usage error (exit {e.code})'
    except Exception as e:  # noqa: BLE001 - the gate must fail open on anything
        err = f'{type(e).__name__}: {e}'
    gate = {'state': 'error', 'action': 'build', 'reason': f'the signals gate failed, so the brief builds without it: {err}'[:500],
            'today': _arg(argv, '--today'), 'checkedAt': iso(dt.datetime.now(dt.timezone.utc)), 'companies': {},
            'currentStep': None, 'nextRetryAt': None, 'retry': None, 'errorKind': None, 'retries': {}}
    if argv[:1] == ['check'] and valid_day(gate['today']):
        try:
            root = _arg(argv, '--hq-root') or '.'
            # Keep the retry slots, so an error pass never makes the next pass start a run early,
            # and the company list, so a later call with no list keeps the same scope (including
            # a company waiting on a manual fix) instead of starting a run for every company.
            prev = read_json(runs_dir(root, gate['today']) / 'brief-gate.json') or {}
            kept, kept_cos = prev.get('retries'), prev.get('companies')
            gate['retries'] = kept if isinstance(kept, dict) else {}
            gate['companies'] = kept_cos if isinstance(kept_cos, dict) else {}
            # An error pass for named companies keeps the other companies' stale notices; with
            # no list its scope is every company, and an error builds with no notice.
            named = [c for c in (_arg(argv, '--companies') or '').split(',') if c]
            if named:
                gate['staleCompanies'] = kept_stale(root, gate['today'], named)
            write_gate(root, gate['today'], gate)
        except Exception:  # noqa: BLE001 - best effort; stdout and the exit code still carry it
            pass
    print(json.dumps(gate))
    return EXIT['error']


if __name__ == '__main__':
    sys.exit(safe_main())
