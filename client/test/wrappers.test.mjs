import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import {
  connect, forwardMethods, GodotValue, InputObject, RemoteObject, ScreenObject,
} from '../../addons/stagehand/client.mjs';
import { launchFixture } from './fixture.mjs';

let fixture;

before(
  async () => {
    fixture = await launchFixture();
  },
  { timeout: 40_000 },
);

after(async () => {
  await fixture?.stop();
});

class Dingus {
  constructor(remote) {
    this.remote = remote;
  }

  echo(value) {
    return this.remote.invoke('echo', { value });
  }
}

test('operation wrappers forward calls, results and errors through ordinary remote handles', async () => {
  const game = await connect(fixture.url, {
    token: fixture.token,
    wrappers: { probe: forwardMethods(['echo', 'spawn', 'remove', 'missing']) },
  });
  let child;

  try {
    const probe = await game.root('A');
    assert.ok(probe.remote instanceof RemoteObject);

    const returned = await probe.echo({ value: { self: probe, number: 9007199254740993n } });
    assert.equal(returned.self.remote.id, probe.remote.id);
    assert.equal(returned.number, 9007199254740993n);
    assert.equal(await returned.self.echo({ value: 'nested' }), 'nested');
    assert.equal(await probe.echo(), null);
    await assert.rejects(probe.missing(), { code: -32601 });
    assert.equal(await probe.echo({ value: 'after error' }), 'after error');

    child = game.object(await probe.spawn());
    const remove = child.remove;
    await remove();
    await assert.rejects(child.remote.observe(), { code: -32004 });
    child = null;
  } finally {
    if (child) await child.remove();
    game.close();
  }
});

test('operation wrapper factories retain their own method selection', () => {
  const names = ['echo'];
  const factory = forwardMethods(names);
  names[0] = 'changed';
  const expected = Promise.resolve(42);
  const params = { value: 42 };
  const remote = {
    invoke(method, received) {
      assert.equal(method, 'echo');
      assert.equal(received, params);
      return expected;
    },
  };

  assert.equal(factory(remote).echo(params), expected);
});

test('operation wrappers reject invalid names and names reserved by the facade or promises', () => {
  for (const names of ['echo', [null], [''], ['remote'], ['then']]) {
    assert.throws(() => forwardMethods(names), TypeError);
  }
});

test('large screenshots on one connection finish before the next capture starts', async () => {
  let current;
  const client = {
    async request(_method, { method, params }) {
      if (method === 'capture') {
        current = params.viewport;
        return { capture: current, byte_length: 2 };
      }

      assert.equal(method, 'capture_chunk');
      assert.equal(params.capture, current);
      const bytes = Buffer.from(current);
      return {
        base64: bytes.subarray(params.offset, params.offset + 1).toString('base64'),
        next_offset: params.offset + 1,
      };
    },
  };

  const firstScreen = new ScreenObject(client, 'screen');
  const secondScreen = new ScreenObject(client, 'screen');
  const captures = await Promise.all([
    firstScreen.capture({ viewport: 'ab' }),
    secondScreen.capture({ viewport: 'cd' }),
  ]);
  assert.deepEqual(captures.map(({ image }) => image.toString()), ['ab', 'cd']);
});

test('standard endpoints use their registered kinds through ordinary discovery and references', async () => {
  const game = await connect(fixture.url, { token: fixture.token });

  try {
    const descriptors = await game.objects();
    for (const label of ['Runtime', 'SceneTree', 'Object', 'Screen', 'Input']) {
      assert.equal(descriptors.find((object) => object.label === label).kind, label);
    }

    const input = await game.findObject('Input');
    const screen = await game.findObject('Screen');
    assert.ok(input instanceof InputObject);
    assert.ok(screen instanceof ScreenObject);
    assert.equal(input.id, (await game.root('Input')).id);

    const probe = await game.findObject('A');
    const returned = await probe.invoke('echo', { value: { input } });
    assert.ok(returned.input instanceof InputObject);
    assert.equal(returned.input.id, input.id);
  } finally {
    game.close();
  }
});

test('builtin methods expose the known operations without invoke', async () => {
  const game = await connect(fixture.url, {token: fixture.token});

  try {
    const registry = await game.root('Registry');
    const runtime = await game.root('Runtime');
    const tree = await game.root('SceneTree');
    const objects = await game.root('Object');
    const script = await game.root('Script');

    assert.ok((await registry.list()).some((root) => root.label === 'Script'));
    assert.equal(typeof (await runtime.info()).physics_ticks_per_second, 'number');

    const {scene} = await tree.current();
    const matches = await tree.query({root: scene, name: 'Fixture'});
    assert.equal(matches.nodes[0].node.id, scene.id);
    assert.ok((await objects.inspect({target: scene})).properties.some((p) => p.name === 'name'));

    await objects.set({target: scene, property: 'clicks', value: 17});
    assert.equal(await objects.get({target: scene, property: 'clicks'}), 17);
    assert.equal(await objects.call({target: scene, method: 'get_class'}), 'Node');
    assert.equal(await objects.remote.call('get_class'), 'RefCounted');
    assert.equal(await scene.get('clicks'), 17);

    const source = `extends RefCounted

func evaluate(bindings: Dictionary) -> int:
    return bindings.n * 2
`;
    assert.equal(await script.evaluate({source, bindings: {n: 21}}), 42);
  } finally {
    game.close();
  }
});

test('input and screen wrappers include immediate methods as well as scheduled helpers', async () => {
  const game = await connect(fixture.url, {token: fixture.token});

  try {
    const input = await game.root('Input');
    const screen = await game.root('Screen');
    assert.ok((await input.actions()).actions.some((action) => action.name === 'jump'));

    await input.press({action: 'jump'});
    assert.deepEqual((await input.observe()).value.held_inputs, ['action:jump']);
    await input.release({action: 'jump'});

    const position = new GodotValue({type: 'Vector2', args: [30, 25]});
    await input.moveMouse({position});
    assert.deepEqual((await input.observe()).value.synthetic_position.args, position.args);

    const action = await input.startSequence({ticks: 600});
    assert.equal((await input.status({action: action.action})).status, 'running');
    assert.equal((await input.cancel({action: action.action})).status, 'cancelled');
    assert.equal((await action.finished).status, 'cancelled');

    const viewport = (await screen.viewports()).find((entry) => entry.path.endsWith('/TestViewport'));
    assert.deepEqual((await screen.dimensions({viewport: viewport.viewport})).logical_size.args,
      [320, 240]);
  } finally {
    game.close();
  }
});

test('consumer factories can extend the standard wrapper and keep its helpers on returned refs', async () => {
  const game = await connect(fixture.url, {
    token: fixture.token,
    wrappers: {
      Input: input => Object.assign(input, {
        tap: descriptor => input.sequence({
          ticks: 1,
          events: [{at_tick: 0, pressed: true, input: descriptor}],
        }),
      }),
    },
  });

  try {
    const input = await game.root('Input');
    assert.ok(input instanceof InputObject);
    assert.equal((await input.tap({action: 'jump'})).status, 'completed');
    assert.ok((await input.actions()).actions.some((action) => action.name === 'jump'));

    const probe = await game.findObject('A');
    const nested = await probe.invoke('echo', {value: {input}});
    assert.ok(nested.input instanceof InputObject);
    assert.equal((await nested.input.tap({action: 'jump'})).status, 'completed');
    assert.deepEqual((await input.observe()).value.held_inputs, []);
  } finally {
    game.close();
  }
});

test('required named lookup caches ordinary handles and refreshes after removal or a miss', async () => {
  const game = await connect(fixture.url, {
    token: fixture.token,
    wrappers: { Dingus: (remote) => ({ name: () => remote.get('name') }) },
  });
  let bridge;
  const handles = [];

  try {
    const tree = await game.root('SceneTree');
    const scene = (await tree.invoke('current')).scene;
    bridge = (await tree.invoke('query', { name: 'Stagehand' })).nodes[0].node;
    handles.push(await bridge.call('register_object', scene, 'Named fixture', 'Dingus'));
    handles.push(await bridge.call('register_object', bridge, 'Named fixture', 'Dingus'));

    let discoveries = 0;
    const objects = game.objects.bind(game);
    game.objects = () => {
      discoveries += 1;
      return objects();
    };

    const first = await game.root('Named fixture');
    assert.equal(await first.name(), 'Fixture');
    assert.equal(await (await game.root('Named fixture')).name(), 'Fixture');
    assert.equal(discoveries, 1);

    await bridge.call('unregister_object', handles.shift());
    assert.equal(await (await game.root('Named fixture')).name(), 'Stagehand');
    assert.equal(discoveries, 2);

    await bridge.call('unregister_object', handles.shift());
    await assert.rejects(game.root('Named fixture'), /Root is unavailable: Named fixture/);
    assert.equal(await game.findObject('Named fixture'), null);

    handles.push(await bridge.call('register_object', scene, 'Named fixture', 'Dingus'));
    assert.equal(await (await game.root('Named fixture')).name(), 'Fixture');
  } finally {
    for (const handle of handles) await bridge.call('unregister_object', handle);
    game.close();
  }
});

test('factory objects wrap discovery, nested results, observations and event arguments', async () => {
  const game = await connect(fixture.url, {
    token: fixture.token,
    wrappers: { probe: (remote) => new Dingus(remote) },
  });
  let stop;

  try {
    const dingus = await game.findObject('A');
    assert.ok(dingus instanceof Dingus);

    const requests = [];
    const request = game.request.bind(game);
    game.request = (method, ...args) => {
      requests.push(method);
      return request(method, ...args);
    };
    const nested = await dingus.echo({
      single: dingus,
      array: [dingus],
      map: new Map([[dingus, dingus]]),
    });

    assert.deepEqual(requests, ['object.call']);
    assert.ok(nested.single instanceof Dingus);
    assert.ok(nested.array[0] instanceof Dingus);
    assert.ok([...nested.map.keys()][0] instanceof Dingus);
    assert.ok([...nested.map.values()][0] instanceof Dingus);
    assert.equal(nested.single.remote.id, dingus.remote.id);
    assert.equal(await nested.single.echo('hello'), 'hello');
    assert.ok((await dingus.remote.observe()).value.self instanceof Dingus);

    let received;
    stop = await dingus.remote.subscribe('native_payload', (event) => {
      received = event.value;
    });
    await dingus.remote.call('emit_signal', 'native_payload', dingus, [dingus], null, 4, false);

    assert.ok(received[0] instanceof Dingus);
    assert.ok(received[1][0] instanceof Dingus);
    assert.equal(received[2], null);

    const scene = (await (await game.root('SceneTree')).invoke('current')).scene;
    assert.ok(scene instanceof RemoteObject);
    assert.equal(await scene.get('name'), 'Fixture');
  } finally {
    await stop?.();
    game.close();
  }
});

test('live registration supplies wrapper types for ID lookups without another discovery request', async () => {
  const game = await connect(fixture.url, {
    token: fixture.token,
    wrappers: { probe: (remote) => new Dingus(remote) },
  });
  let child;

  try {
    const parent = await game.findObject('A');
    const id = await parent.remote.invoke('spawn');
    child = game.object(id);

    assert.ok(child instanceof Dingus);
    assert.equal((await child.remote.describe()).kind, 'probe');
    await child.remote.invoke('remove');
    await assert.rejects(child.remote.observe(), { code: -32004 });
    child = null;
  } finally {
    if (child) await child.remote.invoke('remove');
    game.close();
  }
});

test('first-seen native references carry their wrapper type without discovery', async () => {
  const game = await connect(fixture.url, {
    token: fixture.token,
    wrappers: { object: (remote) => ({ name: () => remote.get('name') }) },
  });

  try {
    const tree = await game.root('SceneTree');
    const current = await tree.invoke('current');

    assert.equal(await current.scene.name(), 'Fixture');
    assert.equal(await current.root.name(), 'root');
  } finally {
    game.close();
  }
});

test('a wrapper instance cannot silently change which remote object it represents', async () => {
  const shared = {};
  const game = await connect(fixture.url, {
    token: fixture.token,
    wrappers: { probe: () => shared },
  });

  try {
    await game.findObject('A');
    await assert.rejects(game.findObject('B'), /different remote object/);
  } finally {
    game.close();
  }
});

test('consumer factories can deliberately replace a standard wrapper', async () => {
  const game = await connect(fixture.url, {
    token: fixture.token,
    wrappers: {
      Input: (remote) => ({ snapshot: () => remote.observe() }),
    },
  });

  try {
    const input = await game.root('Input');

    assert.equal((await input.snapshot()).value.active_action, null);
    const probe = await game.findObject('A');
    const returned = await probe.invoke('echo', { value: input });
    assert.equal((await returned.snapshot()).value.active_action, null);

    const defaultClient = await connect(fixture.url, { token: fixture.token });
    try {
      assert.equal(
        (await (await defaultClient.root('Input')).scroll({ vertical: 1 })).delivered,
        true,
      );
    } finally {
      defaultClient.close();
    }
  } finally {
    game.close();
  }
});

test('a throwing factory rejects its RPC result and leaves later requests usable', async () => {
  const game = await connect(fixture.url, {
    token: fixture.token,
    wrappers: {
      probe: () => {
        throw new Error('Dingus construction failed');
      },
    },
  });

  try {
    const descriptor = (await game.objects()).find((object) => object.label === 'A');
    const remote = new RemoteObject(game, descriptor.id);

    await assert.rejects(remote.invoke('echo', { value: remote }), /Dingus construction failed/);
    assert.equal(await remote.invoke('echo', { value: 42 }), 42);
  } finally {
    game.close();
  }
});

test('event factory errors reach the client error listener without losing the connection', async () => {
  let fail = false;
  const game = await connect(fixture.url, {
    token: fixture.token,
    wrappers: {
      probe: (remote) => {
        if (fail) {
          throw new Error('Event construction failed');
        }

        return remote;
      },
    },
  });
  let stop;

  try {
    const probe = await game.findObject('A');
    const errors = [];
    const delivered = [];
    game.on('error', (error) => errors.push(error));
    stop = await probe.subscribe('native_payload', (event) => delivered.push(event));
    fail = true;
    await probe.call('emit_signal', 'native_payload', probe, null, null, null, null);

    assert.equal(errors.length, 1);
    assert.match(errors[0].message, /Event construction failed/);
    assert.deepEqual(delivered, []);
    assert.equal(await probe.invoke('echo', { value: 42 }), 42);
  } finally {
    await stop?.();
    game.close();
  }
});

test('factories must synchronously return objects', async () => {
  for (const factory of [
    () => null,
    () => 42,
    async () => ({}),
    async () => {
      throw new Error('Async failure');
    },
  ]) {
    const game = await connect(fixture.url, {
      token: fixture.token,
      wrappers: { probe: factory },
    });

    try {
      await assert.rejects(game.findObject('A'), /synchronously return an object/);
    } finally {
      game.close();
    }
  }
});

test('explicit registration supplies the type even after a node was inspected generically', async () => {
  const game = await connect(fixture.url, {
    token: fixture.token,
    wrappers: { Dingus: (remote) => ({ name: () => remote.get('name') }) },
  });
  let bridge, registered;

  try {
    const tree = await game.root('SceneTree');
    const scene = (await tree.invoke('current')).scene;
    bridge = (await tree.invoke('query', { name: 'Stagehand' })).nodes[0].node;
    registered = await bridge.call('register_object', scene, 'Scene facade', 'Dingus');

    const returned = (await tree.invoke('current')).scene;

    assert.equal(await returned.name(), 'Fixture');
  } finally {
    if (registered) await bridge.call('unregister_object', registered);
    game.close();
  }
});

test('removing a node invalidates all of its registered handles', async () => {
  const game = await connect(fixture.url, { token: fixture.token });
  let child;

  try {
    const parent = await game.findObject('A');
    child = game.object(await parent.invoke('spawn'));
    const tree = await game.root('SceneTree');
    const bridge = (await tree.invoke('query', { name: 'Stagehand' })).nodes[0].node;
    const alias = game.object(await bridge.call('register_object', child, 'Alias', 'Dingus'));
    await child.invoke('remove');

    await assert.rejects(child.observe(), { code: -32004 });
    await assert.rejects(alias.observe(), { code: -32004 });
    child = null;
  } finally {
    if (child) await child.invoke('remove');
    game.close();
  }
});
