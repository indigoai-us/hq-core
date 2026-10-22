import { afterEach, test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const script = fileURLToPath(new URL('../knowledge-pulse-stale.mjs', import.meta.url));
const dirs = [];
const now = Date.parse('2026-10-22T00:00:00Z');
afterEach(() => { for (const d of dirs.splice(0))
    fs.rmSync(d, { recursive: true, force: true }); });
function fixture() { const base = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'pulse-stale-'))); dirs.push(base); const root = path.join(base, 'knowledge'); fs.mkdirSync(root); return { base, root }; }
function file(root, name, body, days = 100) { const p = path.join(root, name); fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, body); fs.utimesSync(p, new Date(now - days * 86400000), new Date(now - days * 86400000)); return p; }
function run(root, p) { const r = spawnSync(process.execPath, [script, '--knowledge-root', root, '--file', p, '--as-of', '2026-10-22'], { encoding: 'utf8', timeout: 5000, env: { PATH: process.env.PATH } }); assert.equal(r.status, 0, r.stderr); return JSON.parse(r.stdout); }
for (const status of ['plan-awaiting-approval', 'recommendation', 'archived', 'draft', 'active', 'custom-lifecycle'])
    test(`preserves ${status} and annotates age once`, () => {
        const { root } = fixture();
        const original = `---\nstatus: ${status} # semantic state\ntags: [one, two]\n---\n# Café\nBody is unchanged.\n`;
        const p = file(root, 'plan.md', original);
        assert.equal(run(root, p).state, 'flagged');
        assert.equal(fs.readFileSync(p, 'utf8'), original.replace('\n---\n#', '\nstale_since: 2026-10-22\n---\n#'));
        const before = fs.statSync(p);
        assert.equal(run(root, p).state, 'already_flagged');
        assert.equal(fs.statSync(p).mtimeMs, before.mtimeMs);
    });
test('frontmatter without status gains only the age annotation; CRLF survives', () => { const { root } = fixture(); const p = file(root, 'note.md', '---\r\ntitle: Notes\r\n---\r\nText\r\n'); assert.equal(run(root, p).state, 'flagged'); assert.equal(fs.readFileSync(p, 'utf8'), '---\r\ntitle: Notes\r\nstale_since: 2026-10-22\r\n---\r\nText\r\n'); });
test('existing quoted age marker is preserved byte for byte', () => { const { root } = fixture(); const body = '---\nstatus: recommendation\n"stale_since": 2026-01-01\n---\nText\n'; const p = file(root, 'old.md', body); assert.equal(run(root, p).state, 'already_flagged'); assert.equal(fs.readFileSync(p, 'utf8'), body); });
test('recent and exactly sixty-day-old content is not changed', () => { const { root } = fixture(); for (const days of [1, 60, -1]) {
    const body = '---\nstatus: active\n---\nText\n', p = file(root, `age${days}.md`, body, days);
    assert.equal(run(root, p).state, 'fresh');
    assert.equal(fs.readFileSync(p, 'utf8'), body);
} });
test('missing or unterminated frontmatter is preserved', () => { const { root } = fixture(); for (const [name, body] of [['none.md', '# Text\n'], ['broken.md', '---\nstatus: recommendation\nText\n']]) {
    const p = file(root, name, body);
    assert.equal(run(root, p).state, 'no_frontmatter');
    assert.equal(fs.readFileSync(p, 'utf8'), body);
} });
test('INDEX.md is never annotated', () => { const { root } = fixture(); const body = '---\nstatus: active\n---\nIndex\n', p = file(root, 'INDEX.md', body); assert.equal(run(root, p).state, 'excluded'); assert.equal(fs.readFileSync(p, 'utf8'), body); });
test('another knowledge root and symlink files or directories are refused', () => { const { base, root } = fixture(); const other = path.join(base, 'other'); fs.mkdirSync(other); const body = '---\nstatus: recommendation\n---\nPreserve\n', p = file(other, 'other.md', body); assert.equal(run(root, p).state, 'refused'); fs.symlinkSync(p, path.join(root, 'alias.md')); assert.equal(run(root, path.join(root, 'alias.md')).state, 'refused'); fs.symlinkSync(other, path.join(root, 'linked')); assert.equal(run(root, path.join(root, 'linked/other.md')).state, 'refused'); assert.equal(fs.readFileSync(p, 'utf8'), body); });
test('a symlink knowledge root is refused without writes', () => { const { base, root } = fixture(); const p = file(root, 'old.md', '---\nstatus: active\n---\nText\n'); const alias = path.join(base, 'alias'); fs.symlinkSync(root, alias); assert.equal(run(alias, path.join(alias, 'old.md')).state, 'refused'); assert.ok(!fs.readFileSync(p, 'utf8').includes('stale_since')); });
test('atomic annotation preserves permissions and leaves hardlink aliases untouched', () => { const { root } = fixture(); const original = '---\nstatus: recommendation\n---\nText\n'; const p = file(root, 'old.md', original); fs.chmodSync(p, 0o640); const alias = path.join(root, 'alias.md'); fs.linkSync(p, alias); assert.equal(run(root, p).state, 'flagged'); assert.equal(fs.statSync(p).mode & 0o777, 0o640); assert.equal(fs.readFileSync(alias, 'utf8'), original); });
