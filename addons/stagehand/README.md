# Stagehand

A pure GDScript addon for Godot 4.5+. It provides an explicitly enabled runtime
endpoint for external bots, interactive JS sessions, and automated tests, using
JSON-RPC 2.0 over a persistent WebSocket connection.

The addon is the scripts in this directory. Copy this directory into a Godot
project; create the bridge from a game-owned startup node when control is wanted:

```gdscript
const Stagehand = preload("res://addons/stagehand/bridge.gd")


func _ready() -> void:
	var token := OS.get_environment("STAGEHAND_TOKEN")
	if token.is_empty():
		return

	var bridge := Stagehand.new()
	bridge.name = "Stagehand"
	add_child(bridge)
	bridge.enable_builtins() # All five builtin endpoints; see the explicit form below.
	var error := bridge.start(token, 0) # Loopback; 0 selects an available port.
	if error != OK:
		push_error(error_string(error))
		bridge.queue_free()

		return

	print("Stagehand port: ", bridge.get_port())
```

Nothing starts merely because the addon is present. For scene transitions, put the
bridge under a deliberately persistent game node if the connection should survive.
Removing it closes connections and releases its synthetic inputs. No autoload or
project settings are installed by this package.

The no-argument `enable_builtins()` call is shorthand for:

```gdscript
bridge.enable_builtins(["Runtime", "SceneTree", "Object", "Screen", "Input"])
```

These strings select the builtin endpoints to register. Pass a subset such as
`["Runtime", "Screen", "Input"]` to expose only those endpoints. Call this method
once with the desired set; subsequent calls do nothing. Passing `[]`, or omitting
the call, leaves builtin endpoints disabled. `Registry` remains available, along
with your game-owned registrations. Its `list` operation returns the current
registered-root descriptors, including itself; its observation returns the same
list. The [protocol reference](../../docs/protocol.md#optional-builtin-operations)
lists each builtin's operations.

The token grants powerful developer control, especially with Object enabled:
reflected methods can reach the game's normal filesystem and process APIs. Supply
a private, unpredictable launch token. The listener defaults to `127.0.0.1`.
The first RPC authenticates before inspection or mutation. Native WebSocketPeer
does not expose the accepted Origin header here;
the token is the boundary that prevents an unrelated webpage from controlling the
game. Do not give that token to untrusted browser code.

## Remote connections

`start(token, port = 0, bind_address = "127.0.0.1")` keeps remote access opt-in.
Use Godot's `"*"` convention to listen on all IPv4 and IPv6 interfaces. For a
narrower binding, use `"0.0.0.0"` for IPv4 only, `"::"` for IPv6 only, or a specific
interface IP. Port `0` still selects an available port, returned by `get_port()`.

For example, start the game-side bridge with:

```gdscript
var error := bridge.start(token, 49152, "*")
```

The client connects using the game's reachable hostname or IP, with the same token:

```js
const game = await connect('ws://game-host:49152', {
  token: process.env.STAGEHAND_TOKEN,
});
```

The explicit URL selects the destination; there is no separate client remote mode.
The addon serves plain `ws://`, which does not encrypt the token or traffic. Use a
trusted network or an encrypted tunnel; for TLS termination in front of the addon,
the client can use a `wss://` URL. Remote listeners retain the same authentication,
connection limits, and Input ownership rules.

## JavaScript

Use Node 22+ with its built-in WebSocket; no npm dependencies are required. The
source package lives at `client/` in this repository. Output comments are abbreviated
examples; scene data varies by game. The input example assumes a `move_forward` action.

```js
import { connect, GodotValue } from './client/client.mjs';
import { writeFile } from 'node:fs/promises';

const game = await connect('ws://127.0.0.1:49152', {
  token: process.env.STAGEHAND_TOKEN,
});

try {
  // Handshake snapshot, not a live cache.
  console.log(game.session);
  // => { protocol: 1, instance: '…', engine: { … }, clock: { … }, objects: [ … ], … }

  const tree = await game.builtin('SceneTree');
  const { nodes } = await tree.invoke('query', { name: '*Menu*', limit: 20 });
  if (nodes.length) console.log(await nodes[0].node.inspect());
  // => { class: '…', properties: [ … ], methods: [ … ], signals: [ … ] }

  const input = await game.builtin('Input');
  console.log(await input.invoke('actions'));
  // => { actions: [{ name: 'move_forward', bindings: [ … ], … }, …], … }

  await input.invoke('press', { key: 'W', physical: true });
  // This stays held across RPCs. Use release or a bounded sequence for a duration.
  await input.invoke('release', { key: 'W', physical: true });

  const movement = await input.sequence({
    ticks: 12,
    events: [{ at_tick: 0, pressed: true, input: { action: 'move_forward' } }],
  });
  console.log(movement); // Sequence exhausted, not "arrived".
  // => { action: '…', status: 'completed', reason: 'sequence_exhausted', applied_ticks: 12, … }

  await input.moveMouseTo({
    position: new GodotValue({ type: 'Vector2', args: [160, 120] }),
    duration_ms: 250,
  });

  // Runtime interpolates; one command.

  const screen = await game.builtin('Screen');
  const capture = await screen.capture();
  await writeFile('/tmp/stagehand.png', capture.image);
} finally {
  game.close();
}
```

`startSequence()` and `startMouseMove()` return acceptance plus `finished`,
`cancel()`, and `getStatus()`. The shorter helpers above await the terminal result.
Cancellation stops runtime execution; an RPC timeout does not cancel anything.
No mutation is retried or replayed, and connections never migrate or reconnect
automatically to another game instance. Builtin handles are cached; observations
and property reads always make fresh requests.

```js
const action = await input.startMouseMove({
  position: new GodotValue({ type: 'Vector2', args: [400, 200] }),
  duration_ms: 1000,
});
// ...other local work...
await action.cancel();
console.log(await action.finished);
```

For signals, install the subscription before triggering the operation:

```js
const stop = await object.subscribe('changed', (event) => console.log(event.value));
await object.call('emit_changed');
await stop();
```

Subscribe resolves only once both ends are ready. Native signals arrive as an array
of their emitted arguments, including an empty array for a signal with no arguments;
explicitly published events carry the value supplied by the registered endpoint.

## Registering game-owned objects

Registration supplies a label, kind, named operations, optional observation
callback, and events. Operation callbacks receive one Dictionary, execute on the
main thread, and return a normal value or `bridge.fail(code, message)`.
The `kind` also selects optional [client wrapper factories](../../client/README.md#wrapper-factories).

```gdscript
var handle := bridge.register_object(
	counter,
	"Counter B",
	"counter",
	{ "increment": counter.increment },
	counter.observe,
	["changed"],
	{ }, # Optional operation descriptions.
	true, # Registered root; false is used internally for reflected references.
	"1.0", # Optional game-owned contract version.
)

bridge.publish(handle, "changed", counter.count)
# Explicit removal is also available:
# bridge.unregister_object(handle)
```

`counter.increment(params)` owns numeric validation and mutation;
`counter.observe()` returns its current state. See the standalone fixture for a
complete working example of both callbacks and immediate event publication.

The optional `operation_info` Dictionary supplies game-owned argument/return
descriptions in discovery, independent of native release reflection. It describes
the operations; their callbacks still own validation.

The trailing `version` string defaults to empty, which omits it from the descriptor.
Supply a version when your game wants clients to identify an exposed contract.
Stagehand treats it as an opaque string: there is no required version format,
comparison, negotiation or protocol-version change. It describes the root's API,
independently of the running game's build or the object's instance handle.

Node removal invalidates its handles and subscriptions. Other Objects use weak
references and are pruned once freed. Registration retains operation callbacks;
when those retain a RefCounted target, unregister it explicitly at its owner's
lifecycle boundary. Handles are scoped to this running bridge instance, not durable
NodePaths or JavaScript numbers. Reflection can follow unregistered live nodes and
resources too; `Registry.list` includes only registered roots. `objects.list`
returns the same descriptors for existing clients. Registry is tied to the bridge's
lifetime and cannot be removed by `unregister_object`.

Game logic and asynchronous semantic actions belong to game-owned endpoints.
Character selection/ownership, navigation, placement, camera control, MCP, debugger
bridges, and pause/step are not implemented here. Global Input can affect the
human-controlled character; it does not create independent virtual character controls.

See [the protocol](../../docs/protocol.md) for methods, types, timing, limits, and input
semantics. See [development](../../docs/development.md) for tested scope and commands.
