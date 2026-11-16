import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect } from '../client.mjs';
import { launchFixture } from './fixture.mjs';

test('default builtin installation includes Script and conditional Input', async () => {
  const fixture = await launchFixture();
  const game = await connect(fixture.url, { token: fixture.token });

  try {
    const script = await game.builtin('Script');
    const input = await game.builtin('Input');
    const source = `extends RefCounted

func evaluate(_bindings: Dictionary) -> int:
    return 42
`;

    assert.equal(await script.invoke('evaluate', { source }), 42);
    assert.ok((await input.describe()).operations.includes('hold_until'));
  } finally {
    game.close();
    await fixture.stop();
  }
});

test('facade-only configuration refuses undeclared signals through raw RPC', async () => {
  const fixture = await launchFixture({ builtins: [] });
  const game = await connect(fixture.url, { token: fixture.token });

  try {
    const registry = await game.builtin('Registry');
    const b = await game.findObject('B');

    for (const [object, event] of [[registry, 'connection_closed'], [b, 'native_changed']]) {
      await assert.rejects(
        game.request('object.subscribe', { object: object.id, event }),
        { code: -32602 },
      );
    }

    assert.equal(await game.findObject('Object'), null);
    assert.ok((await registry.invoke('list')).some((root) => root.id === b.id));
    await assert.rejects(registry.invoke('get_tree'), { code: -32601 });
  } finally {
    game.close();
    await fixture.stop();
  }
});

test('declared native signals and published events work without Object', async () => {
  const fixture = await launchFixture({ builtins: [] });
  const game = await connect(fixture.url, { token: fixture.token });
  const observer = await connect(fixture.url, { token: fixture.token });
  const a = await game.findObject('A');
  const watched = await observer.findObject('A');
  const native = [];
  const observed = [];
  const published = [];
  const stopNative = await a.subscribe('native_changed', ({ value }) => native.push(value));
  const stopObserved = await watched.subscribe('native_changed', ({ value }) => observed.push(value));
  const stopPublished = await a.subscribe('changed', ({ value }) => published.push(value));

  try {
    await a.invoke('emit_native', { value: 7 });
    await a.invoke('increment', { amount: 3 });

    assert.deepEqual(native, [[7]]);
    assert.deepEqual(published, [3]);
    // A response on the observer's connection follows its queued native event.
    await watched.observe();
    assert.deepEqual(observed, [[7]]);
    await assert.rejects(a.subscribe('native_empty', () => {}), { code: -32602 });

    await stopNative();
    await a.invoke('emit_native', { value: 8 });
    await watched.observe();

    assert.deepEqual(native, [[7]]);
    assert.deepEqual(observed, [[7], [8]]);
  } finally {
    await stopObserved();
    await stopPublished();
    observer.close();
    game.close();
    await fixture.stop();
  }
});

test('Object enables arbitrary native signals on unlisted references', async () => {
  const fixture = await launchFixture({ builtins: ['Object'] });
  const game = await connect(fixture.url, { token: fixture.token });
  let stop;

  try {
    const registry = await game.builtin('Registry');
    const tree = await registry.call('get_tree');
    const frames = [];
    let resolve;
    const arrived = new Promise((done) => { resolve = done; });
    stop = await tree.subscribe('physics_frame', ({ value }) => {
      frames.push(value);
      resolve();
    });

    await arrived;

    assert.deepEqual(frames[0], []);
    assert.ok(!(await game.objects()).some((root) => root.id === tree.id));
    assert.equal(await game.findObject('Script'), null);
  } finally {
    await stop?.();
    game.close();
    await fixture.stop();
  }
});
