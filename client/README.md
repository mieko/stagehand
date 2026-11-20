# JavaScript client

Import `addons/stagehand/client.mjs` from the Stagehand checkout or use your game's local
client package. If all you have is a game address, you can download
`/client.mjs` when the game serves it. The client runs as one module in Node
22 or newer. The core module exports `connect`,
`GodotValue` and `RpcError`. A runtime without a
global WebSocket can pass a constructor in `connect(address, {token, WebSocket})`.
Keep a client connected to reuse handles and subscriptions; call `close()` when done.

See the [wire protocol](../addons/stagehand/api.md) for message and value formats when
writing clients in other languages.

`await game.findObject(label)` looks up the current registered objects and returns
the first matching object, or `null` if none matches. Use `game.objects()` for
descriptors and `game.object(id)` when you already have a specific handle.

Every bridge exposes a `Registry` root, including when optional builtins are off:

```js
const registry = await game.root('Registry');
const roots = await registry.list();

console.log(roots.map(({ label, kind, version }) => ({ label, kind, version })));
```

The list includes Registry itself and reflects current registrations/removals.
`game.objects()` returns the same descriptors, including any declared API version.
`game.session` is the initial handshake snapshot, not a live cache.

`await game.root(label)` uses the same first-match lookup, caches the handle
until the object is removed or the connection closes, and throws if it is absent.
It's a convenience for required named endpoints, including ordinary game-owned
registrations. Builtins use their names as both label and kind; for example,
`findObject('Input')` and `builtin('Input')` both use the default `Input` wrapper.

`connect(address, { token })` accepts the game's HTTP or HTTPS base address,
such as `http://localhost:49152`. The client opens WebSocket at `/rpc`. Remote use
requires an explicit [game-side bind address](../addons/stagehand/README.md#remote-connections).

See the [addon usage guide](../addons/stagehand/README.md) for game-side setup and
[development commands](../docs/development.md) for the isolated integration suite.

## Builtin methods

Builtin wrappers expose [their operations](../addons/stagehand/api.md#optional-builtin-operations)
as named methods with the same parameters, for example `runtime.info()` or
`script.evaluate({source, bindings})`. See [recording](../docs/recording.md) for a
complete capture/retrieval example.

`input.moveMouse()` invokes `move_mouse`; the scheduled helpers below also wait
for completion. `screen.capture()` decodes the PNG into `image: Buffer` alongside
its capture metadata. Generic `invoke()`, observations and subscriptions remain
available, and `.remote` exposes the original handle.

The Object root takes an explicit target, for example
`await objects.get({target: node, property: 'name'})`. In contrast,
`await node.get('name')` inspects that node through the same root.

## Input completion and cancellation

`startSequence()`, `startMouseMove()` and `startHoldUntil()` return acceptance plus
`finished`, `cancel()` and `getStatus()`. Their shorter forms `sequence()`,
`moveMouseTo()` and `holdUntil()` await the terminal result directly.

```js
const accepted = await input.startSequence({
  ticks: 120,
  events: [{ at_tick: 0, pressed: true, input: { action: 'move_forward' } }],
});
// ...other client-side work...
await accepted.cancel();
console.log(await accepted.finished);
```

Completion describes input execution, not gameplay success. A lost connection or
removed endpoint rejects `finished` if the terminal result was not received.
An RPC timeout does not cancel work. The client never retries mutations or
reconnects automatically; an uncertain action may already have happened.

For ordinary wheel scrolling, `await input.scroll({vertical: 2, position})` delivers
one press/release wheel pulse with factor 2. Positive factors scroll down/right;
negative scroll up/left. `horizontal` is optional. Coordinates follow the same
main-window event convention as mouse motion. This is native event injection,
not OS cursor movement or guaranteed pixel displacement.

## GDScript predicates

`gdPredicate(predicate, bindings = {})` returns `{source, bindings}` for spreading
into `input.holdUntil()`, `startHoldUntil()` or the underlying wire operation.
Select Script and Input in the game first. The helper generates complete GDScript;
the game compiles and runs it. This example assumes a live `capsule` reference:

```js
import { gdPredicate } from '../addons/stagehand/client.mjs';

const input = await game.root('Input');
const accepted = await input.startHoldUntil({
  ...gdPredicate(
    {
      value: 'capsule.global_position.y',
      matched: 'value >= 1.5',
    },
    { capsule },
  ),
  hold: [{ key: 'W', physical: true }],
  max_simulation_seconds: 3,
});
const result = await accepted.finished;
console.log(result.reason, result.condition?.value);
```

Use `input.holdUntil(params)` when you only need the final result.

The object form samples `value` once, then uses that local in `matched`. The
string form `gdPredicate('capsule.position.y >= 1.5', {capsule})` returns matched
with `value:null`, because no separate observation was requested. The game's
predicate contract requires a real bool; the helper does not coerce truthiness.

Named bindings become typed local variables inside each evaluator invocation.
Values remain normal native bindings, never source literals. Invalid identifiers,
GDScript reserved words and generated-name conflicts (`bindings`, `evaluate`, and
object-form `value`) are rejected. The engine remains the source compiler and
checks game-specific symbols. Use raw `{source,bindings}` for more involved
evaluators or other binding keys.

See [the wire contract](../addons/stagehand/api.md#conditional-input) for response sequences,
budgets, snapshots, cleanup and synchronous execution limits.

## Subscribing to native signals

`remote.subscribe(name, listener)` supports both declared endpoint events and native
signals. Without the Object builtin, the game must declare that name in the
endpoint's `events`; matching native signals are connected automatically. With
Object enabled, clients can inspect and subscribe to arbitrary native signals on
known objects. `remote.inspect()`, `get(property)`, `set(property, value)` and
`call(method, ...args)` also require Object and provide native inspection and calls.
See [security](../docs/security.md) for builtin permissions.

Install the subscription before triggering the operation:

```js
const stop = await object.subscribe('changed', (event) => console.log(event.value));
await object.invoke('increment', { amount: 1 });
await stop();
```

Subscribe resolves when both ends are ready. Native signals deliver an array of
arguments; published events carry the supplied value. Calling `stop()` immediately
detaches the client listener; its Promise reports the server's unsubscribe
acknowledgment or failure.

## Wrapper factories

Wrapper factories are optional: ordinary remote objects already support `invoke()`,
`observe()` and subscriptions. To add your own client-side methods, pass an object
literal mapping remote types to synchronous wrapper functions:

```js
const game = await connect(address, {
  token,
  wrappers: {
    Dingus: (remote) => ({
      hello: () => remote.invoke('hello'),
    }),
  },
});

const dingus = await game.findObject('My dingus');
console.log(await dingus.hello());
// => Hello from Godot!
```

On the Godot side, register that object's `kind` as `"Dingus"`. Its label
(`"My dingus"`) is independent of its type. For builtin kinds, the factory receives
Stagehand's default wrapper; other kinds receive a generic `RemoteObject`. Return
whatever object you want callers to use: a class instance or a plain object, with
no inheritance requirement.
Each returned wrapper represents one remote object on one connection. If caching
wrappers, keep a separate cache per connection keyed by object identity.

For methods that simply forward named parameters, use `forwardMethods`:

```js
import { connect, forwardMethods } from '../addons/stagehand/client.mjs';

const game = await connect(address, {
  token,
  wrappers: {
    example: forwardMethods(['hello']),
  },
});

const greeter = await game.root('Greeter');
console.log(await greeter.hello());
console.log(await greeter.remote.describe());
```

`forwardMethods(names)` returns a wrapper factory. Each generated method accepts
one named-parameter object and returns `remote.invoke(name, params)` unchanged;
omitting parameters sends an empty object. Results, errors and native values follow
the ordinary client behavior. The underlying `RemoteObject` is available as
`.remote` for observations, subscriptions and other generic operations. Names are
required to be nonempty strings; `remote` and `then` are reserved.
Operations are not discovered or validated against the endpoint until invoked.
Use a custom factory when methods need argument or result conversion.

The same factory path handles discovery, returned references, nested arrays/maps,
observations and events. Wrapped objects can also be passed back as RPC arguments.
Types without a factory remain ordinary `RemoteObject`s.

To add consumer methods while retaining Stagehand's builtin helpers, extend the
wrapper you receive:

```js
const game = await connect(address, {
  token,
  wrappers: {
    Input: (input) =>
      Object.assign(input, {
        tap: (descriptor) =>
          input.sequence({
            ticks: 1,
            events: [{ at_tick: 0, pressed: true, input: descriptor }],
          }),
      }),
  },
});

const input = await game.root('Input');
await input.tap({ key: 'W', physical: true });
console.log(await input.actions());
```

`Object.assign` retains class methods, including Input's completion helpers and
Screen's PNG decoding; spreading the instance into a plain object does not.
Return a different object when you intentionally want a replacement. Factories
apply to discovery and references returned in results/events alike.

Your `wrappers` entries affect this connection only. Builtin handles are cached,
and each lookup uses the current factories. Assign `game.wrappers.Dingus = factory`
for subsequent lookups; objects you've already received keep their wrappers.

Factories must synchronously return an object. Factory errors reject the affected
RPC result; errors while wrapping a notification are emitted through the client's
`error` event. Install an error listener if your factories can fail on event data.
