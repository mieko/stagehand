import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runInNewContext } from 'node:vm';
import { gdPredicate } from '../../addons/stagehand/client.mjs';

test('predicate generation passes bindings unchanged and emits typed local aliases', () => {
  const bindings = {capsule: {opaque: 'object reference'}};
  const generated = gdPredicate('capsule.global_position.y >= 1.5', bindings);

  assert.equal(generated.bindings, bindings);
  assert.match(generated.source, /var capsule: Variant = bindings\["capsule"\]/);
  assert.match(generated.source, /"matched": capsule.global_position.y >= 1.5, "value": null/);
  assert.ok(!generated.source.includes('opaque'));
});

test('observed predicates sample their value once without boolean coercion', () => {
  const generated = gdPredicate({value: 'capsule.sample()', matched: 'value >= 1.5'}, {capsule: {}});

  assert.equal(generated.source.match(/capsule\.sample\(\)/g).length, 1);
  assert.match(generated.source, /var value: Variant = capsule.sample\(\)/);
  assert.match(generated.source, /"matched": value >= 1.5, "value": value/);
  assert.ok(!generated.source.includes('bool('));
});

test('binding identifiers reject keywords and generated names without rewriting expressions', () => {
  for (const name of ['bindings', 'evaluate', 'self', 'await', 'true', 'PI', '_', 'bad-name', '1a']) {
    assert.throws(() => gdPredicate('true', {[name]: 1}), /binding name/);
  }

  assert.throws(() => gdPredicate({value: '1', matched: 'true'}, {value: 2}), /binding name/);
  assert.throws(() => gdPredicate('true', {[Symbol('binding')]: 1}), /names must be strings/);
  assert.match(gdPredicate('value == 2', {value: 2}).source, /var value: Variant/);
  assert.match(gdPredicate('höhe > 1', {höhe: 2}).source, /var höhe: Variant/);
});

test('invalid predicate and binding shapes fail before generating source', () => {
  const invalidPredicates = [
    '', null, false, {}, {value: '1'}, {matched: 'true'},
    {value: '1', matched: 'true', typo: 'x'},
  ];

  for (const predicate of invalidPredicates) {
    assert.throws(() => gdPredicate(predicate), TypeError);
  }

  for (const bindings of [null, [], new Map(), 1]) {
    assert.throws(() => gdPredicate('true', bindings), /Bindings/);
  }
});

test('named binding records can come from a persistent session in another JS realm', () => {
  const bindings = runInNewContext('({capsule: 1})');
  const predicate = runInNewContext('({value: "capsule", matched: "value == 1"})');

  assert.equal(gdPredicate(predicate, bindings).bindings, bindings);
});
