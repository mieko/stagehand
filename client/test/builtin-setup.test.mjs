import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect } from '../client.mjs';
import { launchFixture } from './fixture.mjs';

// Godot Error values; setup is a local game API, not a JSON-RPC error.
const OK = 0;
const ALREADY_IN_USE = 22;
const INVALID_PARAMETER = 31;

test('invalid builtin setup installs nothing and can be corrected and retried', async () => {
  const fixture = await launchFixture({ builtins: null });
  const game = await connect(fixture.url, { token: fixture.token });

  try {
    const setup = await game.findObject('A');
    const invalid = await setup.invoke('configure_builtins', { names: ['Object', 'Scrip'] });

    assert.equal(invalid, INVALID_PARAMETER);
    assert.equal(await game.findObject('Object'), null);
    assert.equal(await game.findObject('Script'), null);

    const before = await setup.invoke('builtin_configuration');

    assert.equal(before.configured, false);
    assert.deepEqual(before.selected, []);
    assert.ok(before.available.includes('Script'));

    const corrected = await setup.invoke('configure_builtins', { names: ['Script', 'Input', 'Input'] });
    const configured = await setup.invoke('builtin_configuration');

    assert.equal(corrected, OK);
    assert.equal(configured.configured, true);
    assert.deepEqual(configured.selected, ['Input', 'Script']);
    assert.ok((await (await game.builtin('Input')).describe()).operations.includes('hold_until'));

    const repeated = await setup.invoke('configure_builtins', { names: ['Object'] });

    assert.equal(repeated, ALREADY_IN_USE);
    assert.equal(await game.findObject('Object'), null);
    assert.deepEqual(await setup.invoke('builtin_configuration'), configured);
  } finally {
    game.close();
    await fixture.stop();
  }
});

test('an explicit empty setup is configured and query results are independent copies', async () => {
  const fixture = await launchFixture({ builtins: null });
  const game = await connect(fixture.url, { token: fixture.token });

  try {
    const setup = await game.findObject('A');

    assert.equal(await setup.invoke('configure_builtins', { names: [] }), OK);

    const original = await setup.invoke('builtin_configuration');
    const changedCopy = await setup.invoke('builtin_configuration', { mutate_copy: true });

    assert.equal(original.configured, true);
    assert.deepEqual(original.selected, []);
    assert.deepEqual(original.available, ['Runtime', 'SceneTree', 'Object', 'Screen', 'Input', 'Script', 'PropertyRecorder']);
    assert.deepEqual(changedCopy.available, []);
    assert.deepEqual(changedCopy.selected, ['Changed copy']);
    assert.deepEqual(await setup.invoke('builtin_configuration'), original);
    assert.equal(await setup.invoke('configure_builtins', { names: [] }), ALREADY_IN_USE);
  } finally {
    game.close();
    await fixture.stop();
  }
});
