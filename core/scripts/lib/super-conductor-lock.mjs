// A small cross-process lock for the super-conductor files that several
// writers share (the save file, the request ledger): the conductor, the
// message watcher, sweep workers. `mkdir` is atomic on every platform, so the
// lock is a directory next to the file. A lock older than STALE_MS belongs to
// a dead process and is taken over.
//
//   withLockSync(file, () => { read; modify; write });
//   await withLock(file, async () => { ... });
import fs from 'node:fs';
import path from 'node:path';

const STALE_MS = 30_000;
// Waiters outlast a stale lock, so a killed holder costs one takeover, never
// a failed write.
const WAIT_MS = 40_000;

const lockPath = (file) => `${file}.lock`;

// Locks held by this process, released on exit as well as in `finally`, so a
// `process.exit` inside the locked section (a usage error) leaves no lock.
const held = new Set();
// Installed on the first acquire, not at import: a script that only imports
// this module keeps its own signal behaviour. Each signal exits with its
// conventional code (SIGINT 130, SIGTERM 143, SIGHUP 129).
const EXIT_CODE = { SIGINT: 130, SIGTERM: 143, SIGHUP: 129 };
let handlersInstalled = false;
function installHandlers() {
  if (handlersInstalled) return;
  handlersInstalled = true;
  process.on('exit', () => { for (const f of held) release(f); });
  for (const sig of Object.keys(EXIT_CODE)) {
    process.on(sig, () => { for (const f of held) release(f); process.exit(EXIT_CODE[sig]); });
  }
}

// Move a finished temp file over `file`. `renameSync` over a file another
// process holds open fails with EPERM on Windows; fall back to copying the
// bytes into place and removing the temp file, so a state save never fails
// because a reader had the file open.
export function replaceFile(tmp, file) {
  try { fs.renameSync(tmp, file); } catch (e) {
    if (e.code !== 'EPERM' && e.code !== 'EACCES' && e.code !== 'EBUSY') throw e;
    fs.copyFileSync(tmp, file);
    try { fs.unlinkSync(tmp); } catch { /* leave the temp file; the next save overwrites it */ }
  }
}

function tryAcquire(file) {
  installHandlers();
  const dir = lockPath(file);
  try { fs.mkdirSync(dir); held.add(file); return true; } catch (e) {
    // The file's folder may not exist yet (first write): create it and retry.
    if (e.code === 'ENOENT') { fs.mkdirSync(path.dirname(file), { recursive: true }); return tryAcquire(file); }
    if (e.code !== 'EEXIST') throw e;
    // A dead holder's lock is taken over: rename it away first, so two
    // waiters cannot both remove a lock a third one has just created.
    let mtime = 0;
    try { mtime = fs.statSync(dir).mtimeMs; } catch { return false; }
    if (Date.now() - mtime > STALE_MS) {
      const gone = `${dir}.stale.${process.pid}`;
      try {
        if (fs.statSync(dir).mtimeMs === mtime) { fs.renameSync(dir, gone); fs.rmdirSync(gone); }
      } catch { /* someone else took it over */ }
    }
    return false;
  }
}

function release(file) {
  held.delete(file);
  try { fs.rmdirSync(lockPath(file)); } catch { /* already gone */ }
}

const sleepSync = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

export function withLockSync(file, fn) {
  const until = Date.now() + WAIT_MS;
  while (!tryAcquire(file)) {
    if (Date.now() > until) throw new Error(`lock on ${file} held too long`);
    sleepSync(20 + Math.floor(Math.random() * 30));
  }
  try { return fn(); } finally { release(file); }
}

export async function withLock(file, fn) {
  const until = Date.now() + WAIT_MS;
  while (!tryAcquire(file)) {
    if (Date.now() > until) throw new Error(`lock on ${file} held too long`);
    await new Promise((r) => setTimeout(r, 20 + Math.floor(Math.random() * 30)));
  }
  try { return await fn(); } finally { release(file); }
}
