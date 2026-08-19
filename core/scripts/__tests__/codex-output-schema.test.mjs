// Unit tests for core/scripts/lib/codex-output-schema.mjs — the strict-dialect
// adaptation the workflow runner applies to every schema it hands the codex
// engine.
//
// The rules under test are the provider's, observed live against codex-cli
// 0.144.5 on 2026-08-19 (HTTP 400 invalid_json_schema, param
// text.format.schema):
//   'additionalProperties' is required to be supplied and to be false.
//   'required' is required to be supplied and to be an array including every
//   key in properties. Missing 'b'.
//
// Run: node --test core/scripts/__tests__/codex-output-schema.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { strictifySchemaForCodex, stripStrictNulls } from '../lib/codex-output-schema.mjs';

// The provider's two structural rules live in the shared checker, written from
// its error messages rather than from the adapter under test — so a bug in the
// adapter's own walk cannot hide behind a checker that shares it.
import { strictSchemaViolations as strictViolations } from '../tests/assert-strict-output-schema.mjs';

test('top-level object gains additionalProperties:false and a complete required', () => {
  const out = strictifySchemaForCodex({
    type: 'object',
    required: ['boardId'],
    properties: { boardId: { type: 'string' }, title: { type: 'string' } },
  });
  assert.equal(out.additionalProperties, false);
  assert.deepEqual(out.required, ['boardId', 'title']);
  assert.deepEqual(strictViolations(out), []);
});

test('an optional property is widened to nullable rather than dropped', () => {
  const out = strictifySchemaForCodex({
    type: 'object',
    required: ['question'],
    properties: { question: { type: 'string' }, recommended: { type: 'string' } },
  });
  assert.deepEqual(out.properties.question.type, 'string', 'a required property keeps its exact type');
  assert.deepEqual(out.properties.recommended.type, ['string', 'null']);
});

test('an optional enum property gets null added to its enum too', () => {
  const out = strictifySchemaForCodex({
    type: 'object',
    properties: { verdict: { type: 'string', enum: ['STRONG', 'WEAK'] } },
  });
  assert.deepEqual(out.properties.verdict.type, ['string', 'null']);
  assert.deepEqual(out.properties.verdict.enum, ['STRONG', 'WEAK', null]);
});

test('a required enum property is left exactly as written', () => {
  const out = strictifySchemaForCodex({
    type: 'object',
    required: ['status'],
    properties: { status: { type: 'string', enum: ['passed', 'blocked'] } },
  });
  assert.equal(out.properties.status.type, 'string');
  assert.deepEqual(out.properties.status.enum, ['passed', 'blocked']);
});

test('nested object nodes under items and properties are fixed too', () => {
  const out = strictifySchemaForCodex({
    type: 'object',
    required: ['approaches'],
    properties: {
      approaches: {
        type: 'array',
        items: {
          type: 'object',
          required: ['name'],
          properties: { name: { type: 'string' }, whenToChoose: { type: 'string' } },
        },
      },
      meta: { type: 'object', properties: { note: { type: 'string' } } },
    },
  });
  assert.deepEqual(strictViolations(out), []);
  assert.equal(out.properties.approaches.items.additionalProperties, false);
  assert.deepEqual(out.properties.approaches.items.required, ['name', 'whenToChoose']);
  assert.deepEqual(out.properties.approaches.items.properties.whenToChoose.type, ['string', 'null']);
  assert.equal(out.properties.meta.additionalProperties, false);
});

test('object nodes inside $defs, anyOf, oneOf and allOf are fixed', () => {
  const out = strictifySchemaForCodex({
    $defs: { story: { type: 'object', properties: { id: { type: 'string' } } } },
    anyOf: [{ type: 'object', properties: { a: { type: 'string' } } }],
    oneOf: [{ type: 'object', properties: { b: { type: 'string' } } }],
    allOf: [{ type: 'object', properties: { c: { type: 'string' } } }],
  });
  assert.deepEqual(strictViolations(out), []);
  assert.equal(out.$defs.story.additionalProperties, false);
  assert.equal(out.anyOf[0].additionalProperties, false);
  assert.equal(out.oneOf[0].additionalProperties, false);
  assert.equal(out.allOf[0].additionalProperties, false);
});

test('a property literally named "items" or "properties" is not mistaken for a keyword', () => {
  const out = strictifySchemaForCodex({
    type: 'object',
    properties: {
      items: { type: 'array', items: { type: 'string' } },
      properties: { type: 'object', properties: { deep: { type: 'string' } } },
    },
  });
  assert.deepEqual(strictViolations(out), []);
  assert.equal(out.properties.items.type[0], 'array');
  assert.equal(out.properties.properties.additionalProperties, false);
  // strict also requires an explicit type key on every node (verified live:
  // "schema must have a 'type' key"), which the object shorthand omits — and
  // this one is optional, so it is nullable as well
  assert.deepEqual(out.properties.properties.type, ['object', 'null']);
});

test('an object node typed ["object","null"] still gets the strict treatment', () => {
  const out = strictifySchemaForCodex({
    type: 'object',
    properties: { blocked: { type: ['object', 'null'], properties: { id: { type: 'string' } } } },
  });
  assert.equal(out.properties.blocked.additionalProperties, false);
  assert.deepEqual(out.properties.blocked.required, ['id']);
});

test('a free-form map is rejected, not silently stripped of its dynamic keys', () => {
  assert.throws(
    () => strictifySchemaForCodex({ type: 'object', additionalProperties: true, properties: {} }),
    /permits no dynamic keys/);
  assert.throws(
    () => strictifySchemaForCodex({
      type: 'object', properties: {}, additionalProperties: { type: 'string' },
    }),
    /permits no dynamic keys/);
});

test('the rejection names the offending path', () => {
  assert.throws(
    () => strictifySchemaForCodex({
      type: 'object', required: ['bag'],
      properties: { bag: { type: 'object', properties: {}, additionalProperties: true } },
    }),
    /<root>\.properties\.bag/);
});

test('a required name with no matching property is rejected, not dropped', () => {
  // Dropping it would ship a wire schema the model can satisfy and a local
  // validator that still demands the key — a result that can never validate.
  assert.throws(
    () => strictifySchemaForCodex({
      type: 'object',
      required: ['ghost', 'real'],
      properties: { real: { type: 'string' } },
    }),
    /required.*"ghost".*no matching property/s);
});

test('an already-strict schema is returned unchanged (idempotent)', () => {
  const strict = {
    type: 'object',
    additionalProperties: false,
    required: ['a', 'b'],
    properties: { a: { type: 'string' }, b: { type: ['string', 'null'] } },
  };
  const once = strictifySchemaForCodex(strict);
  const twice = strictifySchemaForCodex(once);
  assert.deepEqual(once, strict);
  assert.deepEqual(twice, once);
});

test('the input schema is never mutated', () => {
  const original = {
    type: 'object',
    required: ['a'],
    properties: { a: { type: 'string' }, b: { type: 'string' } },
  };
  const snapshot = JSON.parse(JSON.stringify(original));
  strictifySchemaForCodex(original);
  assert.deepEqual(original, snapshot);
});

test('non-object schemas pass through untouched', () => {
  assert.deepEqual(strictifySchemaForCodex({ type: 'string' }), { type: 'string' });
  assert.equal(strictifySchemaForCodex(null), null);
  assert.equal(strictifySchemaForCodex(true), true);
});

test('stripStrictNulls deletes a null answer for an optional property', () => {
  const schema = {
    type: 'object',
    required: ['question'],
    properties: { question: { type: 'string' }, recommended: { type: 'string' } },
  };
  const out = stripStrictNulls({ question: 'Auth provider?', recommended: null }, schema);
  assert.deepEqual(out, { question: 'Auth provider?' });
  assert.equal('recommended' in out, false);
});

test('stripStrictNulls keeps a null the original schema allowed or required', () => {
  const nullable = { type: 'object', properties: { note: { type: ['string', 'null'] } } };
  assert.deepEqual(stripStrictNulls({ note: null }, nullable), { note: null });

  const requiredNull = { type: 'object', required: ['note'], properties: { note: { type: 'string' } } };
  assert.deepEqual(stripStrictNulls({ note: null }, requiredNull), { note: null },
    'a null where the script demanded a value must survive to fail validation');
});

test('stripStrictNulls recurses into arrays and nested objects', () => {
  const schema = {
    type: 'object',
    required: ['approaches'],
    properties: {
      approaches: {
        type: 'array',
        items: {
          type: 'object',
          required: ['name'],
          properties: { name: { type: 'string' }, whenToChoose: { type: 'string' } },
        },
      },
      meta: { type: 'object', properties: { note: { type: 'string' } } },
    },
  };
  const out = stripStrictNulls({
    approaches: [{ name: 'a', whenToChoose: null }, { name: 'b', whenToChoose: 'at scale' }],
    meta: { note: null },
  }, schema);
  assert.deepEqual(out, { approaches: [{ name: 'a' }, { name: 'b', whenToChoose: 'at scale' }], meta: {} });
});

test('stripStrictNulls does not mutate the value it is given', () => {
  const schema = { type: 'object', properties: { a: { type: 'string' } } };
  const value = { a: null };
  stripStrictNulls(value, schema);
  assert.deepEqual(value, { a: null });
});

// The round trip is the actual contract: a script writes ordinary JSON Schema,
// codex answers the strict rewrite (every key present, optional ones null), and
// the script gets back exactly what its own schema describes.
test('round trip: strict answer maps back to the shape the script declared', () => {
  const scriptSchema = {
    type: 'object',
    required: ['name', 'openQuestions'],
    properties: {
      name: { type: 'string' },
      openQuestions: {
        type: 'array',
        items: {
          type: 'object',
          required: ['question'],
          properties: {
            question: { type: 'string' },
            options: { type: 'array', items: { type: 'string' } },
            recommended: { type: 'string' },
          },
        },
      },
    },
  };
  const wire = strictifySchemaForCodex(scriptSchema);
  assert.deepEqual(strictViolations(wire), []);

  const codexAnswer = {
    name: 'demo',
    openQuestions: [{ question: 'Auth provider?', options: null, recommended: 'existing' }],
  };
  assert.deepEqual(stripStrictNulls(codexAnswer, scriptSchema), {
    name: 'demo',
    openQuestions: [{ question: 'Auth provider?', recommended: 'existing' }],
  });
});

// ---- composed optional properties -------------------------------------------
// A composed node (anyOf/oneOf/allOf/$ref) carries no `type` of its own, so
// widening has to add a null ALTERNATIVE rather than a null type. Both forms
// were confirmed accepted by the live provider on 2026-08-19; a node with
// neither type nor composition is rejected by it outright ("schema must have a
// 'type' key"), which is why widenToNullable refuses that shape locally.

test('an optional anyOf property gains a null branch', () => {
  const out = strictifySchemaForCodex({
    type: 'object',
    properties: { pick: { anyOf: [{ type: 'string' }, { type: 'number' }] } },
  });
  assert.deepEqual(out.required, ['pick']);
  assert.deepEqual(out.properties.pick.anyOf, [{ type: 'string' }, { type: 'number' }, { type: 'null' }]);
});

test('an optional oneOf property that already admits null is left alone', () => {
  const out = strictifySchemaForCodex({
    type: 'object',
    properties: { pick: { oneOf: [{ type: 'string' }, { type: 'null' }] } },
  });
  assert.deepEqual(out.properties.pick.oneOf, [{ type: 'string' }, { type: 'null' }]);
});

test('an optional $ref property is wrapped rather than given a sibling type', () => {
  const out = strictifySchemaForCodex({
    type: 'object',
    properties: { story: { $ref: '#/$defs/story' } },
    $defs: { story: { type: 'object', required: ['id'], properties: { id: { type: 'string' } } } },
  });
  assert.deepEqual(out.properties.story, { anyOf: [{ $ref: '#/$defs/story' }, { type: 'null' }] });
  assert.equal(out.properties.story.type, undefined, '$ref must not gain a sibling type');
  assert.equal(out.$defs.story.additionalProperties, false, '$defs targets are strictified too');
});

test('an optional allOf property is wrapped, never given a contradictory null member', () => {
  const out = strictifySchemaForCodex({
    type: 'object',
    properties: { merged: { allOf: [{ type: 'object', properties: { a: { type: 'string' } } }] } },
  });
  assert.equal(Array.isArray(out.properties.merged.anyOf), true);
  assert.deepEqual(out.properties.merged.anyOf[1], { type: 'null' });
  assert.equal(out.properties.merged.anyOf[0].allOf.length, 1);
});

test('an optional object-shorthand property gains an explicit nullable object type', () => {
  const out = strictifySchemaForCodex({
    type: 'object',
    properties: { meta: { properties: { note: { type: 'string' } } } },
  });
  assert.deepEqual(out.properties.meta.type, ['object', 'null']);
  assert.deepEqual(out.properties.meta.required, ['note']);
  assert.deepEqual(strictViolations(out), []);
});

test('an optional property with neither type nor composition is rejected', () => {
  assert.throws(
    () => strictifySchemaForCodex({ type: 'object', properties: { mystery: { description: 'hm' } } }),
    /no way to express "no answer"/);
});

test('stripStrictNulls removes the null a composed optional was widened with', () => {
  const schema = {
    type: 'object',
    required: ['name'],
    properties: { name: { type: 'string' }, pick: { anyOf: [{ type: 'string' }, { type: 'number' }] } },
  };
  assert.deepEqual(stripStrictNulls({ name: 'a', pick: null }, schema), { name: 'a' });
});

test('stripStrictNulls keeps a null a composed schema declared for itself', () => {
  const schema = {
    type: 'object',
    properties: { pick: { anyOf: [{ type: 'string' }, { type: 'null' }] } },
  };
  assert.deepEqual(stripStrictNulls({ pick: null }, schema), { pick: null });
});

test('stripStrictNulls follows a local $ref into its definition', () => {
  const schema = {
    type: 'object',
    required: ['story'],
    properties: { story: { $ref: '#/$defs/story' } },
    $defs: {
      story: {
        type: 'object', required: ['id'],
        properties: { id: { type: 'string' }, note: { type: 'string' } },
      },
    },
  };
  assert.deepEqual(stripStrictNulls({ story: { id: 'US-001', note: null } }, schema),
    { story: { id: 'US-001' } });
});

test('stripStrictNulls descends the single non-null branch of an optional union', () => {
  const schema = {
    type: 'object',
    properties: {
      blocked: {
        anyOf: [
          { type: 'object', required: ['id'], properties: { id: { type: 'string' }, why: { type: 'string' } } },
          { type: 'null' },
        ],
      },
    },
  };
  assert.deepEqual(stripStrictNulls({ blocked: { id: 'US-002', why: null } }, schema),
    { blocked: { id: 'US-002' } });
});

test('stripStrictNulls leaves an ambiguous union alone rather than guessing', () => {
  const schema = {
    type: 'object',
    properties: {
      either: {
        anyOf: [
          { type: 'object', properties: { a: { type: 'string' } } },
          { type: 'object', properties: { b: { type: 'string' } } },
        ],
      },
    },
  };
  const value = { either: { a: null } };
  assert.deepEqual(stripStrictNulls(value, schema), { either: { a: null } });
});

test('a self-referential $ref terminates instead of recursing forever', () => {
  const schema = {
    type: 'object',
    required: ['node'],
    properties: { node: { $ref: '#/$defs/node' } },
    $defs: { node: { $ref: '#/$defs/node' } },
  };
  assert.deepEqual(stripStrictNulls({ node: { anything: null } }, schema), { node: { anything: null } });
});

test('stripStrictNulls removes the null an object-shorthand optional was widened with', () => {
  // Regression: the live provider answered `"meta": null` for a property whose
  // script schema was `{properties: {...}}` with no declared type. A typeless
  // node reads as "shape unknown" — but the object shorthand is not unknown,
  // and it is a shape this module widens, so the null is ours to remove.
  const schema = {
    type: 'object',
    required: ['slug'],
    properties: { slug: { type: 'string' }, meta: { properties: { note: { type: 'string' } } } },
  };
  assert.deepEqual(stripStrictNulls({ slug: 'probe', meta: null }, schema), { slug: 'probe' });
});
