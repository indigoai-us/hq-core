#!/usr/bin/env node
// Patch the super-conductor save file one key at a time, so a wakeup never
// rewrites the whole file from memory (which drifted: a stale monitor_id, lost
// keys after a compaction, 12 KB rewritten every tick).
//
//   node core/scripts/super-conductor-state.mjs get <file> [dotted.key]
//   node core/scripts/super-conductor-state.mjs set <file> <dotted.key> <json|string>
//   node core/scripts/super-conductor-state.mjs push <file> <dotted.key> <json|string>
//   node core/scripts/super-conductor-state.mjs del <file> <dotted.key>
//
// `get` prints the value (or the whole file) as JSON. `set` replaces the value
// at the key, creating parents; `push` appends to an array (created when
// missing); `del` removes the key. A value that is not valid JSON is stored as
// a string, so `set f heartbeat.monitor_id mon_abc` works. Every write is
// atomic (temp file + rename) and bumps `updated_at`. Keys are plain names;
// `__proto__`, `constructor` and `prototype` are refused.
// Exit: 0, 2 on bad arguments or a key that does not exist for `del`.
import fs from 'node:fs';
import path from 'node:path';
import { isMain } from './lib/super-conductor-scope.mjs';
import { withLockSync, replaceFile } from './lib/super-conductor-lock.mjs';

const BAD = new Set(['__proto__', 'constructor', 'prototype']);

function die(msg) { process.stderr.write(`super-conductor-state: ${msg}\n`); process.exit(2); }

export function load(file) {
  try {
    const j = JSON.parse(fs.readFileSync(file, 'utf8'));
    return j && typeof j === 'object' && !Array.isArray(j) ? j : {};
  } catch (e) {
    if (e.code === 'ENOENT') return {};
    throw e;
  }
}

export function save(file, state) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(state, null, 2)}\n`);
  replaceFile(tmp, file);
}

export function splitKey(key) {
  const parts = String(key || '').split('.').filter(Boolean);
  if (!parts.length) die('a key is required');
  for (const p of parts) if (BAD.has(p)) die(`refusing key ${p}`);
  return parts;
}

export function parseValue(raw) {
  try { return JSON.parse(raw); } catch { return String(raw); }
}

export function getAt(obj, parts) {
  let cur = obj;
  for (const p of parts) {
    if (!cur || typeof cur !== 'object' || !Object.hasOwn(cur, p)) return undefined;
    cur = cur[p];
  }
  return cur;
}

function parent(obj, parts, create) {
  let cur = obj;
  for (const p of parts.slice(0, -1)) {
    if (!Object.hasOwn(cur, p) || !cur[p] || typeof cur[p] !== 'object') {
      if (!create) return null;
      cur[p] = {};
    }
    cur = cur[p];
  }
  return cur;
}

export function setAt(obj, parts, value) {
  parent(obj, parts, true)[parts[parts.length - 1]] = value;
}

export function pushAt(obj, parts, value) {
  const p = parent(obj, parts, true);
  const last = parts[parts.length - 1];
  if (!Array.isArray(p[last])) p[last] = [];
  p[last].push(value);
}

export function delAt(obj, parts) {
  const p = parent(obj, parts, false);
  const last = parts[parts.length - 1];
  if (!p || !Object.hasOwn(p, last)) return false;
  delete p[last];
  return true;
}

function main() {
  const [cmd, file, key, raw] = process.argv.slice(2);
  if (!cmd || !file) die('usage: get|set|push|del <file> [key] [value]');
  if (cmd === 'get') {
    const state = load(file);
    const v = key ? getAt(state, splitKey(key)) : state;
    process.stdout.write(`${JSON.stringify(v === undefined ? null : v)}\n`);
    return;
  }
  const parts = splitKey(key);
  if (!['set', 'push', 'del'].includes(cmd)) die(`unknown command ${cmd}`);
  if (cmd !== 'del' && raw === undefined) die(`${cmd} needs a value`);
  // The watcher's `record` and sweep workers write the same file: read,
  // modify and rename under its lock.
  withLockSync(file, () => {
    const state = load(file);
    if (cmd === 'set') setAt(state, parts, parseValue(raw));
    else if (cmd === 'push') pushAt(state, parts, parseValue(raw));
    else if (!delAt(state, parts)) die(`no key ${key}`);
    state.updated_at = new Date().toISOString();
    save(file, state);
  });
  process.stdout.write(`${cmd} ${key}\n`);
}

if (isMain(import.meta.url)) main();
