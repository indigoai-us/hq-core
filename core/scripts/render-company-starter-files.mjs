#!/usr/bin/env node

import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { isServerOwnedPath } from './server-owned-path-prefixes.mjs';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, '../..');
const TEMPLATE_ROOT = path.join(REPO_ROOT, 'companies/_template');
const MANIFEST_FILE = '.hq-seed.yaml';
const EMPTY_PIPELINE_DIRECTORIES = ['sources/_index', 'sources/meetings'];
const MANIFEST_SECTIONS = new Set([
  'placeholders',
  'seed',
  'newcompany_only',
  'substitute',
  'never_seeded',
  'seed_exceptions',
]);
const PLACEHOLDER_PATTERN = /\{([A-Za-z][A-Za-z0-9_]*)\}/g;

function fail(message) {
  throw new Error(message);
}

function parseManifest(source) {
  const manifest = {
    version: null,
    placeholders: {},
    seed: [],
    newcompany_only: [],
    substitute: [],
    never_seeded: [],
    seed_exceptions: [],
  };
  let section = null;

  for (const [index, originalLine] of source.split(/\r?\n/).entries()) {
    const line = originalLine.trimEnd();
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;

    if (!line.startsWith(' ')) {
      const match = /^([a-z][a-z_]*)\s*:\s*(.*?)\s*$/.exec(line);
      if (!match) fail(`Invalid seed manifest line ${index + 1}`);
      const [, key, value] = match;
      if (key === 'version') {
        manifest.version = Number(value);
        section = null;
      } else if (key === 'placeholders' && value === '') {
        section = 'placeholders';
      } else if (MANIFEST_SECTIONS.has(key) && value === '') {
        section = key;
      } else {
        fail(`Unknown seed manifest section or value on line ${index + 1}: ${key}`);
      }
      continue;
    }

    if (section === 'placeholders') {
      const match = /^\s+([a-z][a-z0-9_]*)\s*:\s*(\S(?:.*\S)?)\s*$/.exec(line);
      if (!match) fail(`Invalid placeholder description on line ${index + 1}`);
      const [, key, description] = match;
      manifest.placeholders[key] = description;
      continue;
    }

    if (section && MANIFEST_SECTIONS.has(section)) {
      const match = /^\s+-\s+("(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^\s#]+)\s*$/.exec(line);
      if (!match) fail(`Invalid ${section} entry on line ${index + 1}`);
      const scalar = match[1];
      let value = scalar;
      if (scalar.startsWith('"')) {
        try {
          value = JSON.parse(scalar);
        } catch {
          fail(`Invalid quoted ${section} entry on line ${index + 1}`);
        }
      } else if (scalar.startsWith("'")) {
        value = scalar.slice(1, -1).replaceAll("''", "'");
      }
      if (!value) fail(`Empty ${section} entry on line ${index + 1}`);
      manifest[section].push(value);
      continue;
    }

    fail(`Unexpected seed manifest content on line ${index + 1}`);
  }

  if (manifest.version !== 1) fail(`Unsupported seed manifest version: ${manifest.version}`);
  if (Object.keys(manifest.placeholders).length === 0) fail('Seed manifest has no placeholders');
  return manifest;
}

function matchesNeverSeededRule(relativePath, rule) {
  if (rule === '**/_example/**') {
    const parts = relativePath.split('/');
    return parts.some((part, index) => part === '_example' && index < parts.length - 1);
  }
  if (rule.endsWith('/**')) return relativePath.startsWith(`${rule.slice(0, -3)}/`);
  return relativePath === rule;
}

export function isNeverSeededPath(relativePath, manifest) {
  if (manifest.seed_exceptions.includes(relativePath)) return false;
  return manifest.never_seeded.some((rule) => matchesNeverSeededRule(relativePath, rule));
}

export function walkTemplatePaths(templateRoot = TEMPLATE_ROOT) {
  const result = [];
  const visit = (absoluteDirectory, relativeDirectory = '') => {
    for (const entry of readdirSync(absoluteDirectory, { withFileTypes: true })) {
      const relativePath = path.posix.join(relativeDirectory, entry.name);
      if (relativePath === MANIFEST_FILE || relativePath.startsWith('.hq-seed/')) continue;
      if (entry.isDirectory()) {
        visit(path.join(absoluteDirectory, entry.name), relativePath);
      } else if (entry.isFile() || entry.isSymbolicLink()) {
        result.push(relativePath);
      }
    }
  };
  visit(templateRoot);
  return result.sort();
}

function assertRelativeTemplatePath(relativePath) {
  if (
    !relativePath ||
    path.posix.isAbsolute(relativePath) ||
    relativePath.includes('\\') ||
    relativePath.split('/').some((part) => !part || part === '.' || part === '..')
  ) {
    fail(`Unsafe company template path: ${relativePath}`);
  }
}

function isWithinPath(parent, child) {
  const relative = path.relative(parent, child);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function sourcePath(templateRoot, relativePath) {
  assertRelativeTemplatePath(relativePath);
  const absolutePath = path.resolve(templateRoot, ...relativePath.split('/'));
  const realTemplateRoot = realpathSync(templateRoot);
  const realSourcePath = realpathSync(absolutePath);
  if (!isWithinPath(realTemplateRoot, realSourcePath)) {
    fail(`Company template path escapes its root: ${relativePath}`);
  }
  const stat = lstatSync(absolutePath);
  if (!stat.isFile()) fail(`Company template entry must be a regular file: ${relativePath}`);
  return absolutePath;
}

function resolveDestinationPath(destination) {
  let existingParent = path.resolve(destination);
  const suffix = [];
  while (!existsSync(existingParent)) {
    const parent = path.dirname(existingParent);
    if (parent === existingParent) fail(`Cannot resolve destination: ${destination}`);
    suffix.unshift(path.basename(existingParent));
    existingParent = parent;
  }
  return path.resolve(realpathSync(existingParent), ...suffix);
}

export function loadSeedManifest(templateRoot = TEMPLATE_ROOT) {
  const manifestPath = path.join(templateRoot, MANIFEST_FILE);
  const manifest = parseManifest(readFileSync(manifestPath, 'utf8'));
  const seeded = new Set(manifest.seed);
  const localOnly = new Set(manifest.newcompany_only);
  const substituted = new Set(manifest.substitute);
  const paths = [...seeded, ...localOnly];

  if (seeded.size !== manifest.seed.length || localOnly.size !== manifest.newcompany_only.length) {
    fail('Seed manifest contains duplicate output paths');
  }
  if (paths.some((item) => seeded.has(item) && localOnly.has(item))) {
    fail('A path cannot be both shared and local-only');
  }

  for (const relativePath of paths) sourcePath(templateRoot, relativePath);
  for (const relativePath of substituted) {
    if (!seeded.has(relativePath) && !localOnly.has(relativePath)) {
      fail(`Substitution path is not rendered: ${relativePath}`);
    }
  }

  for (const relativePath of manifest.seed_exceptions) {
    if (!seeded.has(relativePath)) fail(`Seed exception is not in the seed list: ${relativePath}`);
    if (!manifest.never_seeded.some((rule) => matchesNeverSeededRule(relativePath, rule))) {
      fail(`Seed exception does not match a never-seeded rule: ${relativePath}`);
    }
  }

  for (const relativePath of manifest.seed) {
    if (isNeverSeededPath(relativePath, manifest)) {
      fail(`Never-seeded path is in the server seed: ${relativePath}`);
    }
  }
  for (const relativePath of manifest.newcompany_only) {
    if (!isNeverSeededPath(relativePath, manifest)) {
      fail(`Local-only path lacks a never-seeded rule: ${relativePath}`);
    }
  }

  for (const relativePath of walkTemplatePaths(templateRoot)) {
    if (seeded.has(relativePath) || localOnly.has(relativePath)) continue;
    if (!isNeverSeededPath(relativePath, manifest)) {
      fail(`Template path is not classified in the seed manifest: ${relativePath}`);
    }
  }

  for (const relativePath of [...seeded, ...localOnly]) {
    const contents = readFileSync(sourcePath(templateRoot, relativePath), 'utf8');
    // Validate tokens in template text before substituting user-provided values.
    const tokens = [...contents.matchAll(PLACEHOLDER_PATTERN)].map((match) => match[1]);
    if (tokens.length > 0 && !substituted.has(relativePath)) {
      fail(`Template file has placeholders but is not marked for substitution: ${relativePath}`);
    }
    for (const token of tokens) {
      if (!(token in manifest.placeholders)) {
        fail(`Unknown placeholder {${token}} in ${relativePath}`);
      }
    }
  }

  return manifest;
}

function resolvePlaceholders(contents, relativePath, manifest, values) {
  if (!manifest.substitute.includes(relativePath)) return contents;
  return contents.replace(PLACEHOLDER_PATTERN, (placeholder, key) => {
    if (!(key in values)) fail(`No value supplied for placeholder {${key}} in ${relativePath}`);
    return values[key];
  });
}

export function renderCompanyStarterFiles({
  slug,
  companyName,
  destination,
  mode = 'seed',
  templateRoot = TEMPLATE_ROOT,
}) {
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug ?? '')) {
    fail(`Invalid company slug: ${slug ?? ''}`);
  }
  if (typeof companyName !== 'string' || !companyName.trim() || /[\r\n\0]/.test(companyName)) {
    fail('Company display name must be non-empty and stay on one line');
  }
  if (!['seed', 'newcompany', 'newcompany-cloud-first'].includes(mode)) {
    fail(`Unsupported rendering mode: ${mode}`);
  }
  if (!destination) fail('Destination is required');

  const manifest = loadSeedManifest(templateRoot);
  const absoluteTemplateRoot = path.resolve(templateRoot);
  const realTemplateRoot = realpathSync(templateRoot);
  const absoluteDestination = path.resolve(destination);
  const resolvedDestination = resolveDestinationPath(absoluteDestination);
  if (
    isWithinPath(realTemplateRoot, resolvedDestination) ||
    isWithinPath(absoluteTemplateRoot, absoluteDestination)
  ) {
    fail('Destination cannot be inside the company template');
  }

  const values = { company: slug, company_name: companyName.trim() };
  for (const placeholder of Object.keys(manifest.placeholders)) {
    if (!(placeholder in values)) fail(`No CLI value is defined for placeholder {${placeholder}}`);
  }
  const outputPaths = mode === 'seed'
    ? manifest.seed
    : mode === 'newcompany'
      ? [...manifest.seed, ...manifest.newcompany_only]
      : manifest.newcompany_only;
  const renderPaths = mode === 'seed'
    ? outputPaths
    : outputPaths.filter((item) => !isServerOwnedPath(item));
  mkdirSync(absoluteDestination, { recursive: true });

  for (const relativePath of renderPaths) {
    const source = sourcePath(templateRoot, relativePath);
    const target = path.join(absoluteDestination, ...relativePath.split('/'));
    let contents = resolvePlaceholders(readFileSync(source, 'utf8'), relativePath, manifest, values);
    if (mode === 'newcompany-cloud-first' && relativePath === 'company.yaml') {
      if (!/^cloud: false\s*$/m.test(contents)) {
        fail('Cloud-first company template must start with cloud: false');
      }
      contents = contents.replace(/^cloud: false\s*$/m, 'cloud: true');
    }
    mkdirSync(path.dirname(target), { recursive: true });
    writeFileSync(target, contents, 'utf8');
  }
  if (mode !== 'seed') {
    for (const relativePath of EMPTY_PIPELINE_DIRECTORIES) {
      mkdirSync(path.join(absoluteDestination, ...relativePath.split('/')), { recursive: true });
    }
  }
  return renderPaths;
}

function runCli(args) {
  if (args.length !== 3 && args.length !== 5) {
    fail('Usage: node core/scripts/render-company-starter-files.mjs <slug> <display-name> <destination> [--mode newcompany|newcompany-cloud-first]');
  }
  let mode = 'seed';
  if (args.length === 5) {
    if (args[3] !== '--mode' || !['newcompany', 'newcompany-cloud-first'].includes(args[4])) {
      fail('Supported modes are --mode newcompany and --mode newcompany-cloud-first');
    }
    mode = args[4];
  }
  const [slug, companyName, destination] = args;
  const written = renderCompanyStarterFiles({ slug, companyName, destination, mode });
  process.stdout.write(`Rendered ${written.length} company starter files for ${slug} (${mode})\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    runCli(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  }
}
