#!/usr/bin/env python3
# hq-core: public
"""garden-policy-deep.py: helpers for `/garden policies --deep`.

The deep pass is a reviewed trim of personal and company policies. Subagents
read every policy in full and assign a verdict; the user approves each verdict
group; approved files are backed up to a tarball and deleted. This script does
the mechanical parts only. It never judges a policy.

Subcommands:
  inventory --dir DIR [--dir DIR ...] --out RUN [--batch-size N]
      Parse every policy, attach retrieval evidence, write RUN/inventory.json
      and RUN/batch-NN.txt review batches, print a summary.
  merge --out RUN
      Combine RUN/review-*.json, check every inventoried file has exactly one
      verdict, keep any duplicate whose named twin is also being removed,
      write RUN/verdicts.json, print counts per verdict and enforcement.
  apply --out RUN --verdict V [--verdict V ...] [--enforcement hard|soft]
        [--exclude FILE ...] [--confirm]
      Without --confirm: print the files that would be deleted.
      With --confirm: back up those files to a tarball, verify the tarball,
      delete them, append the list to RUN/applied.log, re-check parsing.
  restore --backup TARBALL
      Extract a backup tarball back into the HQ root.

Scope: personal/policies and companies/<co>/policies only. core/policies is
refused; core rules change through hq-core-staging, never by local deletion.
"""
import argparse, glob, json, os, re, shutil, subprocess, sys, tarfile, time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
HQ_ROOT = os.environ.get('HQ_ROOT') or os.environ.get('CLAUDE_PROJECT_DIR') or os.path.abspath(os.path.join(SCRIPT_DIR, '..', '..'))
ALLOWED = re.compile(r'^(personal/policies|companies/[^/]+/policies)/[^/]+\.md$')
VERDICTS = ('keep', 'personal-keep', 'delete-stale', 'delete-dup', 'delete-covered',
            'delete-generic', 'delete-narrow', 'core-policy', 'core-fix', 'move-company')


def die(msg, rc=2):
    print('garden-policy-deep: ' + msg, file=sys.stderr)
    sys.exit(rc)


def rel(path):
    return os.path.relpath(os.path.abspath(path), HQ_ROOT)


def check_dir(d):
    r = rel(d if os.path.isabs(d) else os.path.join(HQ_ROOT, d))
    if not re.match(r'^(personal/policies|companies/[^/]+/policies)$', r):
        die(f'refusing {r}: only personal/policies and companies/<co>/policies are in scope')
    if not os.path.isdir(os.path.join(HQ_ROOT, r)):
        die(f'no such directory: {r}')
    return r


def frontmatter(text):
    if not text.startswith('---'):
        return None, {}
    parts = re.split(r'^---\s*$', text, maxsplit=2, flags=re.M)
    if len(parts) < 3:
        return None, {}
    raw = parts[1]
    fields = {}
    for line in raw.splitlines():
        m = re.match(r'^([A-Za-z_]+):\s*(.*)$', line)
        if m:
            fields.setdefault(m.group(1), m.group(2).strip().strip('\'"'))
    return raw, fields


def yaml_errors(paths):
    """Return {path: error} for frontmatter that a real YAML parser rejects.

    Uses Ruby's bundled Psych when available (no Python YAML dependency).
    Returns None when no parser is available.
    """
    ruby = shutil.which('ruby')
    if not ruby or not paths:
        return None if not ruby else {}
    prog = ('require "yaml"; require "date"; ARGV.each { |f| t = File.read(f, encoding: "UTF-8").scrub; '
            'next unless t.start_with?("---"); fm = t.split(/^---\\s*$/, 3)[1].to_s; '
            'begin; YAML.safe_load(fm, permitted_classes: [Date, Time]); '
            'rescue => e; puts "#{f}\\t#{e.message.lines.first.to_s.strip}"; end }')
    out = {}
    for i in range(0, len(paths), 200):
        r = subprocess.run([ruby, '-e', prog] + paths[i:i + 200], capture_output=True, text=True)
        for line in r.stdout.splitlines():
            p, _, err = line.partition('\t')
            out[p] = err
    return out


def evidence():
    """Per-policy retrieval evidence: {id: [count, last_epoch]}."""
    ev = {}
    def hit(pid, ts):
        c = ev.setdefault(pid, [0, 0])
        c[0] += 1
        c[1] = max(c[1], ts)
    ledger = os.path.join(HQ_ROOT, 'workspace/orchestrator/policy-retrieval-ledger.jsonl')
    if os.path.isfile(ledger):
        for line in open(ledger, errors='ignore'):
            try:
                row = json.loads(line)
                ts = time.mktime(time.strptime(row.get('ts', '')[:19], '%Y-%m-%dT%H:%M:%S'))
                hit(row['policy'], ts)
            except Exception:
                continue
    state = os.path.join(HQ_ROOT, 'workspace/orchestrator/policy-trigger-state')
    for f in glob.glob(os.path.join(state, '*')):
        try:
            m = os.path.getmtime(f)
            for pid in set(open(f, errors='ignore').read().split()):
                hit(pid, m)
        except Exception:
            continue
    return ev


def cmd_inventory(a):
    dirs = [check_dir(d) for d in a.dir]
    os.makedirs(a.out, exist_ok=True)
    ev = evidence()
    files = []
    for d in dirs:
        for p in sorted(glob.glob(os.path.join(HQ_ROOT, d, '*.md'))):
            if os.path.basename(p).startswith('_'):
                continue  # generated files such as _digest.md
            files.append(p)
    errs = yaml_errors(files)
    now = time.time()
    inv = []
    for p in files:
        text = open(p, errors='ignore').read()
        raw, fm = frontmatter(text)
        pid = fm.get('id') or os.path.basename(p)[:-3]
        c, last = ev.get(pid, ev.get(os.path.basename(p)[:-3], [0, 0]))
        inv.append(dict(
            path=rel(p), id=pid, title=fm.get('title', ''),
            enforcement=fm.get('enforcement', 'soft') or 'soft',
            status=fm.get('status', 'active') or 'active',
            created=fm.get('created', ''), bytes=len(text.encode()),
            retrievals=c, last_retrieved_days=(round((now - last) / 86400) if last else None),
            frontmatter=('missing' if raw is None else 'error' if errs and p in errs else 'ok'),
            frontmatter_error=(errs or {}).get(p, '')))
    json.dump(inv, open(os.path.join(a.out, 'inventory.json'), 'w'), indent=1)
    for old in glob.glob(os.path.join(a.out, 'batch-*.txt')):
        os.remove(old)
    n = 0
    for n, i in enumerate(range(0, len(inv), a.batch_size)):
        with open(os.path.join(a.out, f'batch-{n:02d}.txt'), 'w') as fh:
            fh.write('\n'.join(x['path'] for x in inv[i:i + a.batch_size]) + '\n')
    hard = sum(x['enforcement'] == 'hard' for x in inv)
    print(f'policies: {len(inv)} ({hard} hard / {len(inv) - hard} soft) in {", ".join(dirs)}')
    print(f'already retired: {sum(x["status"] == "retired" for x in inv)}')
    if errs is None:
        print('frontmatter check: skipped (ruby not found)')
    else:
        bad = [x for x in inv if x['frontmatter'] != 'ok']
        print(f'frontmatter that does not parse: {len(bad)}')
        for x in bad:
            print(f'  {x["path"]}: {x["frontmatter_error"] or "no frontmatter"}')
    bands = {'never': 0, '1-5': 0, '6-50': 0, '51+': 0}
    for x in inv:
        r = x['retrievals']
        bands['never' if r == 0 else '1-5' if r <= 5 else '6-50' if r <= 50 else '51+'] += 1
    print('retrievals: ' + ', '.join(f'{k}={v}' for k, v in bands.items()))
    months = {}
    for x in inv:
        months[x['created'][:7] or 'unknown'] = months.get(x['created'][:7] or 'unknown', 0) + 1
    print('created: ' + ', '.join(f'{k}={v}' for k, v in sorted(months.items())))
    print(f'review batches: {n + 1 if inv else 0} x up to {a.batch_size} -> {a.out}/batch-NN.txt')


def load_inventory(run):
    p = os.path.join(run, 'inventory.json')
    if not os.path.isfile(p):
        die(f'no inventory at {p}; run inventory first')
    return {x['path']: x for x in json.load(open(p))}


def cmd_merge(a):
    inv = load_inventory(a.out)
    verdicts, seen = {}, {}
    for f in sorted(glob.glob(os.path.join(a.out, 'review-*.json'))):
        for r in json.load(open(f)):
            path = r.get('path') or r.get('file', '')
            if path not in inv:
                cand = [k for k in inv if os.path.basename(k) == os.path.basename(path)]
                path = cand[0] if len(cand) == 1 else path
            if path not in inv:
                die(f'{os.path.basename(f)} names a file not in the inventory: {r.get("file") or r.get("path")}')
            if r.get('verdict') not in VERDICTS:
                die(f'{path}: unknown verdict {r.get("verdict")!r}')
            if path in seen:
                die(f'{path}: verdict given twice ({seen[path]} and {os.path.basename(f)})')
            seen[path] = os.path.basename(f)
            verdicts[path] = dict(r, path=path)
    missing = [p for p in inv if p not in verdicts]
    if missing:
        die(f'{len(missing)} inventoried files have no verdict, e.g. {missing[0]}')
    removed = {p for p, r in verdicts.items() if r['verdict'] not in ('keep', 'personal-keep')}
    by_name = {os.path.basename(p)[:-3]: p for p in inv}
    for p, r in verdicts.items():
        if r['verdict'] != 'delete-dup':
            continue
        t = os.path.basename((r.get('target') or '').strip())
        t = t[:-3] if t.endswith('.md') else t
        twin = by_name.get(t)
        if twin and twin in removed:
            r['verdict'] = 'keep'
            r['reason'] = f'kept: its twin {t} is also flagged for removal'
            removed.discard(p)
            print(f'kept {p}: twin {t} is also flagged')
    json.dump(sorted(verdicts.values(), key=lambda r: r['path']),
              open(os.path.join(a.out, 'verdicts.json'), 'w'), indent=1)
    counts = {}
    for p, r in verdicts.items():
        k = (r['verdict'], inv[p]['enforcement'])
        counts[k] = counts.get(k, 0) + 1
    print(f'{len(verdicts)} verdicts')
    for v in VERDICTS:
        h, s = counts.get((v, 'hard'), 0), sum(c for (vv, e), c in counts.items() if vv == v and e != 'hard')
        if h or s:
            print(f'  {v:15} {h + s:4}  (hard {h}, soft {s})')


def cmd_apply(a):
    inv = load_inventory(a.out)
    vp = os.path.join(a.out, 'verdicts.json')
    if not os.path.isfile(vp):
        die('no verdicts.json; run merge first')
    keepish = {'keep', 'personal-keep'}
    if set(a.verdict) & keepish:
        die('refusing to apply a keep verdict')
    excl = set(a.exclude or [])
    sel = []
    for r in json.load(open(vp)):
        p = r['path']
        if r['verdict'] not in a.verdict or p in excl or os.path.basename(p) in excl:
            continue
        if a.enforcement and inv.get(p, {}).get('enforcement') != a.enforcement:
            continue
        if not ALLOWED.match(p):
            die(f'refusing {p}: outside personal/policies and companies/<co>/policies')
        if os.path.isfile(os.path.join(HQ_ROOT, p)):
            sel.append(p)
    if not sel:
        print('nothing to delete')
        return
    if not a.confirm:
        print(f'would delete {len(sel)} files (dry run; add --confirm):')
        for p in sel:
            print('  ' + p)
        return
    bdir = os.path.join(HQ_ROOT, 'workspace/orchestrator/policy-lifecycle/backups')
    os.makedirs(bdir, exist_ok=True)
    tarpath = os.path.join(bdir, 'garden-deep-' + time.strftime('%Y%m%dT%H%M%S') + '.tar.gz')
    with tarfile.open(tarpath, 'w:gz') as t:
        for p in sel:
            t.add(os.path.join(HQ_ROOT, p), arcname=p)
    with tarfile.open(tarpath) as t:
        names = set(t.getnames())
    if names != set(sel):
        die(f'backup verification failed for {tarpath}; nothing deleted', 1)
    for p in sel:
        os.remove(os.path.join(HQ_ROOT, p))
    with open(os.path.join(a.out, 'applied.log'), 'a') as fh:
        fh.write(f'# {time.strftime("%Y-%m-%dT%H:%M:%S")} verdicts={",".join(a.verdict)} '
                 f'enforcement={a.enforcement or "any"} backup={rel(tarpath)}\n')
        fh.write('\n'.join(sel) + '\n')
    left = [os.path.join(HQ_ROOT, p) for p in inv if os.path.isfile(os.path.join(HQ_ROOT, p))]
    errs = yaml_errors(left)
    print(f'deleted {len(sel)} files; backup {rel(tarpath)}')
    print(f'remaining in scope: {len(left)}' + ('' if errs is None else f'; frontmatter errors: {len(errs)}'))


def cmd_restore(a):
    if not os.path.isfile(a.backup):
        die(f'no such backup: {a.backup}')
    with tarfile.open(a.backup) as t:
        members = t.getmembers()
        for m in members:
            if not ALLOWED.match(m.name) or not m.isfile():
                die(f'refusing to restore {m.name}: outside policy scope')
        t.extractall(HQ_ROOT, members=members)
    print(f'restored {len(members)} files from {a.backup}')


def main():
    ap = argparse.ArgumentParser(description='Helpers for /garden policies --deep')
    sp = ap.add_subparsers(dest='cmd', required=True)
    p = sp.add_parser('inventory'); p.add_argument('--dir', action='append', required=True)
    p.add_argument('--out', required=True); p.add_argument('--batch-size', type=int, default=175)
    p = sp.add_parser('merge'); p.add_argument('--out', required=True)
    p = sp.add_parser('apply'); p.add_argument('--out', required=True)
    p.add_argument('--verdict', action='append', required=True, choices=VERDICTS)
    p.add_argument('--enforcement', choices=('hard', 'soft'))
    p.add_argument('--exclude', action='append'); p.add_argument('--confirm', action='store_true')
    p = sp.add_parser('restore'); p.add_argument('--backup', required=True)
    a = ap.parse_args()
    {'inventory': cmd_inventory, 'merge': cmd_merge, 'apply': cmd_apply, 'restore': cmd_restore}[a.cmd](a)


if __name__ == '__main__':
    main()
