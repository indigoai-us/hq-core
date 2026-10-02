import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('../../..', import.meta.url));
const TEMPLATE = path.join(ROOT, 'companies/_template');
const RENDERER = path.join(ROOT, 'core/scripts/render-company-starter-files.mjs');
const GOLDEN = path.join(TEMPLATE, '.hq-seed/golden/acme');

function temporaryDirectory() {
  return mkdtempSync(path.join(os.tmpdir(), 'company-starter-'));
}

function render(destination, mode, companyName = 'Acme Corp') {
  const args = [RENDERER, 'acme', companyName, destination];
  if (mode) args.push('--mode', mode);
  return spawnSync(process.execPath, args, { cwd: ROOT, encoding: 'utf8' });
}

function filesUnder(directory, relative = '') {
  return readdirSync(path.join(directory, relative), { withFileTypes: true })
    .flatMap((entry) => {
      const name = path.posix.join(relative, entry.name);
      return entry.isDirectory() ? filesUnder(directory, name) : [name];
    })
    .sort();
}

function assertTreesEqual(actual, expected) {
  assert.deepEqual(filesUnder(actual), filesUnder(expected), 'rendered file paths match the golden');
  for (const relative of filesUnder(expected)) {
    assert.deepEqual(
      readFileSync(path.join(actual, relative)),
      readFileSync(path.join(expected, relative)),
      `${relative} matches the golden bytes`,
    );
  }
}

test('the acme seed render matches the committed golden bytes', (t) => {
  const temporary = temporaryDirectory();
  t.after(() => rmSync(temporary, { recursive: true, force: true }));
  const destination = path.join(temporary, 'acme');
  const result = render(destination);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assertTreesEqual(destination, GOLDEN);
});

test('the manifest classifies every template path and excludes every never-seeded path', async () => {
  const { loadSeedManifest, isNeverSeededPath, walkTemplatePaths } = await import(
    '../render-company-starter-files.mjs'
  );
  const manifest = loadSeedManifest(TEMPLATE);
  const seeded = new Set(manifest.seed);

  for (const relative of walkTemplatePaths(TEMPLATE)) {
    if (isNeverSeededPath(relative, manifest)) {
      assert.equal(seeded.has(relative), false, `${relative} is excluded from the server seed`);
    } else {
      assert.equal(seeded.has(relative), true, `${relative} is explicitly server-seeded`);
    }
  }

  for (const relative of [
    'company.yaml',
    '.hq-seed.yaml',
    'settings/communication/preferences.yaml',
    'data/.gitkeep',
    'workers/.gitkeep',
    '.hq/local-state.json',
    'people/_example/meta.yaml',
    'projects/_example/share-policy.yaml',
    'policies/example-policy.md',
    'ontology/entities/person/.gitkeep',
    'signals/_index/.gitkeep',
    'sources/_index/.gitkeep',
  ]) {
    assert.equal(isNeverSeededPath(relative, manifest), true, `${relative} is never seeded`);
    assert.equal(seeded.has(relative), false, `${relative} is absent from the seed list`);
  }

  assert.equal(isNeverSeededPath('sources/meetings/source.yaml', manifest), false);
  assert.equal(seeded.has('sources/meetings/source.yaml'), true);
});

test('manifest and golden files are not hidden by gitignore rules', async () => {
  const { loadSeedManifest } = await import('../render-company-starter-files.mjs');
  const manifest = loadSeedManifest(TEMPLATE);
  const goldenFiles = filesUnder(GOLDEN).map((relative) =>
    path.posix.join('.hq-seed/golden/acme', relative),
  );
  const paths = [
    ...manifest.seed.map((relative) => path.posix.join('companies/_template', relative)),
    ...manifest.newcompany_only.map((relative) => path.posix.join('companies/_template', relative)),
    ...goldenFiles.map((relative) => path.posix.join('companies/_template', relative)),
  ];

  for (const relative of paths) {
    const result = spawnSync('git', ['check-ignore', '--no-index', '-q', '--', relative], {
      cwd: ROOT,
      encoding: 'utf8',
    });
    assert.equal(result.status, 1, `${relative} must not be ignored by git${result.stderr ? `: ${result.stderr}` : ''}`);
  }
});

test('core golden shared seed matches the pinned hq-cli fixture contract', async () => {
  const { loadSeedManifest } = await import('../render-company-starter-files.mjs');
  const manifest = loadSeedManifest(TEMPLATE);
  const contract = JSON.parse(readFileSync(path.join(ROOT, 'core/scripts/company-seed-golden-sha256.json'), 'utf8'));
  assert.deepEqual(Object.keys(contract.files).sort(), [...manifest.seed].sort());
  for (const relative of manifest.seed) {
    const hash = createHash('sha256').update(readFileSync(path.join(GOLDEN, relative))).digest('hex');
    assert.equal(hash, contract.files[relative], `${relative} matches the hq-cli fixture contract`);
  }
});

test('leading-wildcard manifest globs are quoted and parsed as values', async () => {
  const source = readFileSync(path.join(TEMPLATE, '.hq-seed.yaml'), 'utf8');
  const neverSeeded = source.split(/^never_seeded:\s*$/m)[1]?.split(/^seed_exceptions:\s*$/m)[0] ?? '';
  const entries = [...neverSeeded.matchAll(/^\s+-\s+(.+?)\s*$/gm)].map((match) => match[1]);
  assert.deepEqual(
    entries.filter((entry) => entry.startsWith('*')),
    [],
    'leading-wildcard glob scalars must be quoted for YAML',
  );

  const { loadSeedManifest } = await import('../render-company-starter-files.mjs');
  const manifest = loadSeedManifest(TEMPLATE);
  assert.ok(manifest.never_seeded.includes('**/_example/**'));
});

test('the /newcompany render preserves shared bytes and fills all declared placeholders', async (t) => {
  const temporary = temporaryDirectory();
  t.after(() => rmSync(temporary, { recursive: true, force: true }));
  const seedDestination = path.join(temporary, 'seed');
  const localDestination = path.join(temporary, 'newcompany');
  const seedResult = render(seedDestination);
  const localResult = render(localDestination, 'newcompany');
  assert.equal(seedResult.status, 0, seedResult.stderr || seedResult.stdout);
  assert.equal(localResult.status, 0, localResult.stderr || localResult.stdout);

  const { loadSeedManifest } = await import('../render-company-starter-files.mjs');
  const manifest = loadSeedManifest(TEMPLATE);
  for (const relative of manifest.seed) {
    assert.deepEqual(
      readFileSync(path.join(localDestination, relative)),
      readFileSync(path.join(seedDestination, relative)),
      `${relative} has identical bytes in both creation paths`,
    );
  }
  for (const relative of manifest.newcompany_only) {
    assert.ok(filesUnder(localDestination).includes(relative), `${relative} stays in local setup`);
  }

  for (const relative of filesUnder(localDestination)) {
    const contents = readFileSync(path.join(localDestination, relative), 'utf8');
    for (const placeholder of Object.keys(manifest.placeholders)) {
      assert.equal(
        contents.includes(`{${placeholder}}`),
        false,
        `${relative} has no unresolved {${placeholder}} placeholder`,
      );
    }
  }
});

test('cloud-first rendering writes only local paths and marks the company cloud-backed', async (t) => {
  const temporary = temporaryDirectory();
  t.after(() => rmSync(temporary, { recursive: true, force: true }));
  const destination = path.join(temporary, 'cloud-first');
  const result = render(destination, 'newcompany-cloud-first');
  assert.equal(result.status, 0, result.stderr || result.stdout);

  const { loadSeedManifest } = await import('../render-company-starter-files.mjs');
  const manifest = loadSeedManifest(TEMPLATE);
  for (const relative of manifest.seed) {
    assert.equal(filesUnder(destination).includes(relative), false, `${relative} is left to cloud seed`);
  }
  for (const relative of manifest.newcompany_only) {
    assert.ok(filesUnder(destination).includes(relative), `${relative} is rendered locally`);
  }
  assert.match(readFileSync(path.join(destination, 'company.yaml'), 'utf8'), /^cloud: true$/m);
});

test('display-name braces are kept as literal output text', (t) => {
  const temporary = temporaryDirectory();
  t.after(() => rmSync(temporary, { recursive: true, force: true }));
  const destination = path.join(temporary, 'acme');
  const result = render(destination, undefined, 'Acme {West}');
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(readFileSync(path.join(destination, 'README.md'), 'utf8'), /^# Acme \{West\}$/m);
});

test('/newcompany uses the renderer and step 0.7 leaves the rendered README alone', () => {
  const skill = readFileSync(path.join(ROOT, '.claude/skills/newcompany/SKILL.md'), 'utf8');
  const phase03 = skill.split('### 0.3 Scaffold Directory\n')[1]?.split('### 0.4 ')[0] ?? '';
  const phase04 = skill.split('### 0.4 Create Knowledge Directory\n')[1]?.split('### 0.5 ')[0] ?? '';
  const phase07 = skill.split('### 0.7 ')[1]?.split('\n---')[0] ?? '';

  assert.match(phase03, /newcompany-bootstrap\.cjs/);
  assert.doesNotMatch(phase03, /find \. -type|companies\/_template\/settings|updated_at.*date -u/s);
  assert.match(phase04, /plain real directory/);
  assert.doesNotMatch(phase04, /git\s+(init|add|commit)|git -C/);
  assert.doesNotMatch(phase04, /printf '# %s Knowledge|: > design-styles\/packs\/\.gitkeep/);
  assert.doesNotMatch(phase07, /write `companies\/\{slug\}\/README\.md`/);
});
