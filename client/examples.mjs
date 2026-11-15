// Run in a persistent JS session or as an ordinary external bot:
// STAGEHAND_URL=ws://127.0.0.1:PORT STAGEHAND_TOKEN=... node examples.mjs
// Abbreviated outputs below show the standalone fixture; other games differ.
import { connect, GodotValue } from './client.mjs';

const game = await connect(process.env.STAGEHAND_URL, { token: process.env.STAGEHAND_TOKEN });

try {
  const input = await game.builtin('Input');
  const actions = await input.invoke('actions');
  console.log(
    'Available actions:',
    actions.actions.map((action) => action.name),
  );
  // => Available actions: [ …, 'move_forward', 'jump' ]

  const tree = await game.builtin('SceneTree');
  const scene = (await tree.invoke('current')).scene;
  console.log('Scene:', await scene.get('name'));
  // => Scene: Fixture

  // This branch is the conventional deterministic fixture bot. The game owns
  // movement; the local program schedules input and checks an observed effect.
  if (actions.actions.some((action) => action.name === 'move_forward')) {
    const fixture = (await scene.get('name')) === 'Fixture';
    const before = fixture ? await scene.get('input_ticks') : null;
    const result = await input.sequence({
      ticks: 12,
      events: [{ at_tick: 0, pressed: true, input: { action: 'move_forward' } }],
    });
    console.log('Input outcome:', result);
    // => Input outcome: { status: 'completed', reason: 'sequence_exhausted', applied_ticks: 12, … }
    console.log('Fresh input state:', await input.observe());
    // => Fresh input state: {
    //      object: '…', value: { active_action: null, held_inputs: [], … }, clock: { … }
    //    }
    if (fixture && (await scene.get('input_ticks')) - before !== 12) {
      throw new Error('Fixture did not receive 12 movement ticks');
    }
  }

  // The same client is usable by an interactive agent. One request performs the
  // entire interpolated move; synthetic events never warp the macOS OS pointer.
  console.log(
    await input.moveMouseTo({
      position: new GodotValue({ type: 'Vector2', args: [30, 25] }),
      duration_ms: 250,
    }),
  );
  // => { status: 'completed', reason: 'destination_events_delivered', duration_ms: 250, … }
} finally {
  game.close();
}
