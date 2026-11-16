import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { connect, gdPredicate } from '../client.mjs';
import { launchFixture } from './fixture.mjs';

let fixture, game, script;

before(async () => {
  fixture = await launchFixture({
    builtins: ['Script', 'Input', 'SceneTree', 'Object'],
    expectedErrors: [/Parse Error:/, /Trying to call an async function without/],
  });
  game = await connect(fixture.url, {token: fixture.token});
  script = await game.builtin('Script');

  if (process.env.STAGEHAND_REQUIRE_NON_DOTNET === '1') {
    const source = `extends RefCounted

func evaluate(_bindings: Dictionary) -> Dictionary:
    return {"mono": OS.has_feature("mono"), "csharp": ClassDB.class_exists("CSharpScript")}
`;
    const features = await script.invoke('evaluate', {source});

    assert.deepEqual(features, {mono: false, csharp: false});
  }
});

after(async () => {
  game?.close();
  await fixture?.stop();
});

test('Script evaluates ordinary GDScript with native bindings and results', async () => {
  const source = `extends RefCounted

func evaluate(bindings: Dictionary) -> Variant:
    return bindings.value * 2
`;

  assert.equal(await script.invoke('evaluate', {source, bindings: {value: 21}}), 42);
});

test('one-shot evaluation preserves an intentional null result', async () => {
  const source = `extends RefCounted

func evaluate(_bindings: Dictionary) -> Variant:
    return null
`;

  assert.equal(await script.invoke('evaluate', {source}), null);
});

test('a zero-argument child constructor can initialize its parameterized base', async () => {
  const source = `extends "res://evaluator_base.gd"

func _init() -> void:
    super(2)
`;

  assert.equal(await script.invoke('evaluate', {source, bindings: {value: 21}}), 42);
});

test('both predicate helper forms use the common evaluator with live native bindings', async () => {
  const tree = await game.builtin('SceneTree');
  const {scene} = await tree.invoke('current');
  const predicate = gdPredicate('fixture.heartbeat >= 0', {fixture: scene});

  assert.deepEqual(await script.invoke('evaluate', predicate), {matched: true, value: null});

  const observed = gdPredicate(
    {value: 'fixture.heartbeat', matched: 'value >= 0'}, {fixture: scene},
  );
  const result = await script.invoke('evaluate', observed);

  assert.equal(result.matched, true);
  assert.equal(typeof result.value, 'number');
});

test('invalid source and evaluator signatures return admission errors', async () => {
  const sources = [
    'extends RefCounted\nfunc evaluate(:\n',
    'extends RefCounted\n',
    `extends Node

func evaluate(bindings):
    return bindings
`,
    `extends RefCounted

func evaluate():
    return 1
`,
    `extends RefCounted

func _init(required):
    pass

func evaluate(bindings):
    return bindings
`,
  ];

  for (const source of sources) {
    await assert.rejects(script.invoke('evaluate', {source}), (error) => error.code === -32602);
  }
});

test('an accidental coroutine does not become a remote function-state result', async () => {
  const tree = await game.builtin('SceneTree');
  const {scene} = await tree.invoke('current');
  const source = `extends RefCounted

func evaluate(bindings: Dictionary) -> Variant:
    await bindings.scene.get_tree().process_frame
    bindings.scene.set_meta("coroutine_resumed", true)
    return 42
`;

  await assert.rejects(
    script.invoke('evaluate', {source, bindings: {scene}}), /synchronously|await/,
  );

  const treeObject = await scene.call('get_tree');
  let resolve;
  const frame = new Promise((done) => { resolve = done; });
  const stop = await treeObject.subscribe('process_frame', resolve);

  try {
    await frame;
    assert.equal(await scene.call('has_meta', 'coroutine_resumed'), false);
  } finally {
    await stop();
  }
});

test('generated evaluators work with strict consumer declaration warnings', async () => {
  const strict = await launchFixture({builtins: ['Script'], strictDeclarations: true});
  const connection = await connect(strict.url, {token: strict.token});

  try {
    const endpoint = await connection.builtin('Script');
    const predicate = gdPredicate({value: 'höhe', matched: 'value > 1'}, {höhe: 2});
    const result = await endpoint.invoke('evaluate', predicate);

    assert.deepEqual(result, {matched: true, value: 2});
  } finally {
    connection.close();
    await strict.stop();
  }
});

test('Input can be selected independently without enabling Script', async () => {
  const ordinary = await launchFixture({builtins: ['Input']});
  const connection = await connect(ordinary.url, {token: ordinary.token});

  try {
    assert.equal(await connection.findObject('Script'), null);

    const input = await connection.builtin('Input');

    assert.ok(!(await input.describe()).operations.includes('hold_until'));
  } finally {
    connection.close();
    await ordinary.stop();
  }
});
