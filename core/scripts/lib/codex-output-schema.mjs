// Codex structured-output ("strict") schema adaptation for the workflow runner.
//
// WHY THIS EXISTS
// `codex exec --output-schema <file>` forwards that file to the model provider
// as a STRICT structured-output schema (`text.format.schema`). Strict is a
// NARROWER dialect than the ordinary JSON Schema a workflow script writes, and
// the provider rejects the whole request — before the agent takes a single turn
// of work — when a node breaks one of its structural rules. Verified live
// against codex-cli 0.144.5 on 2026-08-19 (HTTP 400 `invalid_json_schema`):
//
//   1. every object node must carry `additionalProperties: false`
//        In context=(), 'additionalProperties' is required to be supplied and
//        to be false.
//   2. every object node's `required` must list EVERY key in `properties`
//        In context=(), 'required' is required to be supplied and to be an
//        array including every key in properties. Missing 'b'.
//   3. every schema node must declare a type
//        In context=('properties', 'a'), schema must have a 'type' key.
//
// Rule 1 killed the first agent of every /orchestrate run on the codex engine;
// rule 2 is what the same run hits the moment rule 1 is satisfied. The stdout
// engines (grok, claude) have no schema flag — they are asked for the shape
// in-prompt and validated locally — so the dialect problem is codex-only, and
// so is this module.
//
// THE TRANSLATION
// Ordinary JSON Schema says "optional" by leaving a key out of `required`.
// Strict has no notion of optionality, so the faithful translation of an
// optional property is "required, but nullable": the key is always present and
// the model answers null when it has nothing to say. A plain typed node gets
// `null` added to its type; a composed node (`anyOf`/`oneOf`/`allOf`/`$ref`)
// gets a `{type: 'null'}` alternative instead, since a composed node carries no
// type of its own to widen. Both forms were confirmed accepted by the provider.
// `strictifySchemaForCodex()` makes that translation on the way out;
// `stripStrictNulls()` undoes it on the way back, deleting exactly the nulls
// the widening invited. A script therefore keeps declaring optionality the
// normal way, sees the same result shape on every engine (an optional field the
// model had nothing for is ABSENT, not null), and only the codex wire format
// changes.
//
// WHAT IT REFUSES TO TRANSLATE
// Two shapes have no strict equivalent, and both are rejected loudly here
// rather than quietly reinterpreted — a schema silently stripped of meaning
// returns data that looks complete and is not:
//
//   - a free-form map (`additionalProperties: true`, or an additionalProperties
//     sub-schema). Strict permits no dynamic keys at all; forcing `false` would
//     drop exactly the keys the author asked for.
//   - a `required` name with no matching property. Strict rejects the extra
//     name, and dropping it would leave the runner's own validator demanding a
//     key the model can no longer emit — a result that could never validate.
//
// Both throw before the agent is spawned, naming the offending path, so the
// author sees a fixable contract error instead of an opaque 400 or a silently
// truncated result.
//
// Both exported functions are pure — they never mutate their arguments —
// because the runner keeps using the script's own schema for the in-prompt copy
// and for local result validation, and workflow scripts routinely share one
// schema constant across several agent() calls.

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function typesOf(node) {
  if (!isPlainObject(node) || node.type === undefined) return [];
  return Array.isArray(node.type) ? node.type.slice() : [node.type];
}

// An object node is one that declares type "object" (possibly among others,
// e.g. ["object","null"]), or that declares no type but carries `properties` —
// the shorthand a hand-written schema often uses.
function isObjectNode(node) {
  const types = typesOf(node);
  if (types.length) return types.includes('object');
  return isPlainObject(node.properties);
}

function isComposed(node) {
  return isPlainObject(node)
    && (Array.isArray(node.anyOf) || Array.isArray(node.oneOf)
        || Array.isArray(node.allOf) || typeof node.$ref === 'string');
}

// Sub-schema positions to recurse through. Keyed by how the value is shaped so
// a `properties` map named "items" (a legal property name) is never mistaken
// for the `items` keyword.
const SUBSCHEMA_MAPS = ['properties', '$defs', 'definitions'];
const SUBSCHEMA_LISTS = ['anyOf', 'oneOf', 'allOf', 'prefixItems'];
const SUBSCHEMA_SINGLES = ['items', 'not', 'if', 'then', 'else', 'contains', 'propertyNames'];

function schemaError(at, message) {
  return new Error(`codex output schema at ${at}: ${message}`);
}

// Optional -> "required but nullable". A typed node widens its own type; a
// composed node has no type to widen, so it gains a null ALTERNATIVE instead.
function widenToNullable(node, at) {
  if (!isPlainObject(node)) {
    // A boolean schema (`true`/`false`) carries no shape to widen. `true`
    // already admits null; `false` admits nothing and is the author's business.
    return;
  }

  const types = typesOf(node);
  if (types.length) {
    if (!types.includes('null')) node.type = [...types, 'null'];
    // An enum must gain null too, or the widened type is unusable: no enum
    // member could satisfy it.
    if (Array.isArray(node.enum) && !node.enum.some((v) => v === null)) node.enum = [...node.enum, null];
    return;
  }

  for (const key of ['anyOf', 'oneOf']) {
    if (!Array.isArray(node[key]) || node[key].length === 0) continue;
    if (!node[key].some((branch) => typesOf(branch).includes('null'))) node[key].push({ type: 'null' });
    return;
  }

  // `$ref` and `allOf` cannot take a sibling type (and `allOf` is an AND, so a
  // null branch inside it would contradict the others) — wrap the whole node in
  // an anyOf whose second branch is null.
  if (typeof node.$ref === 'string' || Array.isArray(node.allOf)) {
    const inner = { ...node };
    for (const key of Object.keys(node)) delete node[key];
    node.anyOf = [inner, { type: 'null' }];
    return;
  }

  // Object shorthand: `properties` with no declared type. Strict requires a
  // type key anyway, so naming it here fixes two problems at once.
  if (isPlainObject(node.properties)) {
    node.type = ['object', 'null'];
    return;
  }

  throw schemaError(at,
    'this property is optional (absent from `required`) but its schema declares '
    + 'neither a type nor a composition, so there is no way to express "no answer" '
    + 'in the strict dialect. Give it a type, or list it in `required`.');
}

function strictifyInPlace(node, at) {
  if (Array.isArray(node)) {
    node.forEach((child, i) => strictifyInPlace(child, `${at}[${i}]`));
    return node;
  }
  if (!isPlainObject(node)) return node;

  for (const key of SUBSCHEMA_MAPS) {
    if (!isPlainObject(node[key])) continue;
    for (const [name, child] of Object.entries(node[key])) strictifyInPlace(child, `${at}.${key}.${name}`);
  }
  for (const key of SUBSCHEMA_LISTS) {
    if (Array.isArray(node[key])) node[key].forEach((child, i) => strictifyInPlace(child, `${at}.${key}[${i}]`));
  }
  for (const key of SUBSCHEMA_SINGLES) {
    if (node[key] !== undefined) strictifyInPlace(node[key], `${at}.${key}`);
  }

  if (!isObjectNode(node)) return node;

  // A free-form map is the one thing strict cannot express. Say so instead of
  // narrowing it away and returning an object missing its dynamic keys.
  if (node.additionalProperties !== undefined && node.additionalProperties !== false) {
    throw schemaError(at,
      'strict structured output permits no dynamic keys, so `additionalProperties` '
      + `must be false (got ${JSON.stringify(node.additionalProperties)}). Model a map `
      + 'as an array of {key, value} entries, or run this agent on the grok or '
      + 'claude engine, which have no strict-schema flag.');
  }
  node.additionalProperties = false;
  // Strict requires an explicit type; the object shorthand omits it.
  if (typesOf(node).length === 0) node.type = 'object';

  const props = isPlainObject(node.properties) ? node.properties : null;
  if (!props) return node;

  const keys = Object.keys(props);
  const declared = Array.isArray(node.required) ? node.required : [];
  const orphans = declared.filter((key) => !keys.includes(key));
  if (orphans.length) {
    throw schemaError(at,
      `\`required\` lists ${orphans.map((k) => JSON.stringify(k)).join(', ')} with no matching `
      + 'property. Strict rejects a required name that is not in `properties`, and dropping it '
      + 'would leave the result validator demanding a key the model can no longer emit. '
      + 'Add the property, or remove the name from `required`.');
  }

  // Declared-required first (stable order), then the rest — each widened so the
  // model can still answer "nothing here" for a property the script left optional.
  const required = [];
  for (const key of declared) if (!required.includes(key)) required.push(key);
  for (const key of keys) {
    if (required.includes(key)) continue;
    widenToNullable(props[key], `${at}.properties.${key}`);
    required.push(key);
  }
  node.required = required;
  return node;
}

// Returns a strict-dialect copy of `schema`, safe to write to --output-schema.
// Non-object inputs (a boolean schema, a stray string) pass through untouched.
// Throws on a schema whose meaning strict cannot carry — see the header.
export function strictifySchemaForCodex(schema) {
  if (!isPlainObject(schema) && !Array.isArray(schema)) return schema;
  // A JSON round-trip is a faithful clone here: the result is about to be
  // JSON.stringify'd into the schema file, so anything it would drop could not
  // have reached codex anyway.
  return strictifyInPlace(JSON.parse(JSON.stringify(schema)), '<root>');
}

const MAX_REF_DEPTH = 16;

// Resolve a local `#/$defs/x` (or `#/definitions/x`) reference against the root
// schema. Anything else — a remote or pointer-nested ref — is left alone, which
// makes the caller treat it as "shape unknown" and leave the value untouched.
function resolveRef(node, root, depth = 0) {
  if (!isPlainObject(node) || typeof node.$ref !== 'string' || depth >= MAX_REF_DEPTH) return node;
  const match = /^#\/(\$defs|definitions)\/([^/]+)$/.exec(node.$ref);
  if (!match || !isPlainObject(root)) return node;
  const bucket = root[match[1]];
  const target = isPlainObject(bucket) ? bucket[match[2]] : undefined;
  return isPlainObject(target) ? resolveRef(target, root, depth + 1) : node;
}

// A property may legitimately hold null when its own schema says so — only the
// nulls our widening invited get removed. Composition-aware: a union that has
// no null branch does not allow null either.
function allowsNull(node, root, depth = 0) {
  const resolved = resolveRef(node, root, depth);
  if (!isPlainObject(resolved)) return true;
  const types = typesOf(resolved);
  if (types.length) return types.includes('null');
  for (const key of ['anyOf', 'oneOf']) {
    if (Array.isArray(resolved[key])) {
      return resolved[key].some((branch) => depth < MAX_REF_DEPTH && allowsNull(branch, root, depth + 1));
    }
  }
  // Object shorthand (`properties`, no declared type) is an object node, not a
  // nullable one — and it is a shape this module widens, so the null it comes
  // back with is ours to remove. Missing this made a live codex answer keep
  // `"meta": null` for a property the script had declared as an object.
  if (isPlainObject(resolved.properties)) return false;
  return true; // nothing declared — do not touch the value
}

// The schema to descend into for a value. A `$ref` resolves; a union resolves
// only when exactly one branch is non-null (the "optional X" shape, including
// the one our own widening produces). A genuinely ambiguous union returns null
// and the subtree is left alone rather than stripped on a guess.
function effectiveSchema(node, root, depth = 0) {
  const resolved = resolveRef(node, root, depth);
  if (!isPlainObject(resolved)) return null;
  for (const key of ['anyOf', 'oneOf']) {
    if (!Array.isArray(resolved[key])) continue;
    const branches = resolved[key]
      .map((branch) => resolveRef(branch, root, depth + 1))
      .filter((branch) => isPlainObject(branch))
      .filter((branch) => !(typesOf(branch).length === 1 && typesOf(branch)[0] === 'null'));
    if (branches.length !== 1 || depth >= MAX_REF_DEPTH) return null;
    return effectiveSchema(branches[0], root, depth + 1);
  }
  return resolved;
}

// Mirrors the runner's own validator (properties + items), plus the `$ref` and
// single-alternative union forms this module can widen — so a value that
// survives this walk is shaped the way that validator will read it.
function stripInPlace(value, schema, root, depth = 0) {
  const effective = effectiveSchema(schema, root, depth);
  if (!isPlainObject(effective)) return value;
  if (Array.isArray(value)) {
    if (effective.items !== undefined) {
      for (const item of value) stripInPlace(item, effective.items, root, depth + 1);
    }
    return value;
  }
  if (!isPlainObject(value)) return value;
  const props = isPlainObject(effective.properties) ? effective.properties : null;
  if (!props) return value;
  const required = Array.isArray(effective.required) ? effective.required : [];
  for (const [key, sub] of Object.entries(props)) {
    if (!(key in value)) continue;
    if (value[key] === null && !required.includes(key) && !allowsNull(sub, root)) {
      delete value[key];
      continue;
    }
    stripInPlace(value[key], sub, root, depth + 1);
  }
  return value;
}

// Undoes the optional -> nullable widening on a codex result: a null answer for
// a property the ORIGINAL schema left optional (and did not itself declare
// nullable) becomes an absent key, which is what the script asked for and what
// every other engine returns.
export function stripStrictNulls(value, schema) {
  if (!isPlainObject(schema)) return value;
  if (value === null || typeof value !== 'object') return value;
  return stripInPlace(JSON.parse(JSON.stringify(value)), schema, schema);
}
