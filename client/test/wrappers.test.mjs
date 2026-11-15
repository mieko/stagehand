import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { connect, RemoteObject } from '../client.mjs';
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

    const scene = (await (await game.builtin('SceneTree')).invoke('current')).scene;
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
    const tree = await game.builtin('SceneTree');
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

test('builtin factories can be overridden through the same object literal', async () => {
  const game = await connect(fixture.url, {
    token: fixture.token,
    wrappers: {
      Input: (remote) => ({ snapshot: () => remote.observe() }),
    },
  });

  try {
    const input = await game.builtin('Input');

    assert.equal((await input.snapshot()).value.active_action, null);
    const probe = await game.findObject('A');
    const returned = await probe.invoke('echo', { value: input });
    assert.equal((await returned.snapshot()).value.active_action, null);

    const defaultClient = await connect(fixture.url, { token: fixture.token });
    try {
      assert.equal(
        (await (await defaultClient.builtin('Input')).scroll({ vertical: 1 })).delivered,
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
    const tree = await game.builtin('SceneTree');
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
    const tree = await game.builtin('SceneTree');
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
