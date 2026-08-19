// Shared test checker: does a JSON Schema satisfy the codex structured-output
// ("strict") dialect the provider enforces on --output-schema?
//
// Written from the provider's error messages rather than from the shipped
// adapter, so it can fail the adapter. Observed live against codex-cli 0.144.5
// on 2026-08-19 (HTTP 400 invalid_json_schema, param text.format.schema):
//
//   In context=(), 'additionalProperties' is required to be supplied and to be
//   false.
//   In context=(), 'required' is required to be supplied and to be an array
//   including every key in properties. Missing 'b'.
//
// Used by core/scripts/__tests__/codex-output-schema.test.mjs (unit) and by the
// workflow-runner / orchestrate-pipeline shell suites, which point it at the
// schema files the runner actually wrote during a fake-engine run:
//
//   node core/scripts/tests/assert-strict-output-schema.mjs <schema.json>...
//
// Exit 0 when every file is strict-valid; exit 1 with one violation per line.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Positions that hold sub-schemas. A `properties` MAP is walked by value, never
// treated as a schema itself — otherwise a property legitimately named "type"
// or "properties" reads as a malformed node.
const SUBSCHEMA_MAPS = ['properties', '$defs', 'definitions'];
const SUBSCHEMA_LISTS = ['anyOf', 'oneOf', 'allOf', 'prefixItems'];
const SUBSCHEMA_SINGLES = ['items', 'not', 'if', 'then', 'else', 'contains', 'propertyNames'];

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

export function strictSchemaViolations(node, at = '<root>', errs = []) {
  if (!isPlainObject(node)) return errs;

  const types = node.type === undefined ? [] : (Array.isArray(node.type) ? node.type : [node.type]);
  const isObjectNode = types.length ? types.includes('object') : isPlainObject(node.properties);
  if (isObjectNode) {
    if (node.additionalProperties !== false) {
      errs.push(`${at}: additionalProperties is ${JSON.stringify(node.additionalProperties)}, want false`);
    }
    const props = isPlainObject(node.properties) ? Object.keys(node.properties) : [];
    const required = Array.isArray(node.required) ? node.required : [];
    for (const key of props) if (!required.includes(key)) errs.push(`${at}: required is missing "${key}"`);
    for (const key of required) if (!props.includes(key)) errs.push(`${at}: required has extra key "${key}"`);
  }

  for (const key of SUBSCHEMA_MAPS) {
    if (!isPlainObject(node[key])) continue;
    for (const [name, child] of Object.entries(node[key])) {
      strictSchemaViolations(child, `${at}.${key}.${name}`, errs);
    }
  }
  for (const key of SUBSCHEMA_LISTS) {
    if (!Array.isArray(node[key])) continue;
    node[key].forEach((child, i) => strictSchemaViolations(child, `${at}.${key}[${i}]`, errs));
  }
  for (const key of SUBSCHEMA_SINGLES) {
    const child = node[key];
    if (Array.isArray(child)) child.forEach((c, i) => strictSchemaViolations(c, `${at}.${key}[${i}]`, errs));
    else if (isPlainObject(child)) strictSchemaViolations(child, `${at}.${key}`, errs);
  }
  return errs;
}

function runCli(files) {
  if (!files.length) {
    process.stderr.write('assert-strict-output-schema: no schema files given\n');
    return 1;
  }
  let bad = 0;
  for (const file of files) {
    let schema;
    try {
      schema = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (e) {
      process.stderr.write(`${file}: unreadable (${e.message})\n`);
      bad++;
      continue;
    }
    const errs = strictSchemaViolations(schema);
    for (const err of errs) process.stderr.write(`${file}: ${err}\n`);
    if (errs.length) bad++;
  }
  return bad ? 1 : 0;
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : '';
const selfPath = fileURLToPath(import.meta.url);
if (invokedPath === selfPath || (invokedPath && fs.existsSync(invokedPath)
    && fs.realpathSync(invokedPath) === fs.realpathSync(selfPath))) {
  process.exit(runCli(process.argv.slice(2)));
}
