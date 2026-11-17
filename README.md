# Stagehand

Inspect and control a running Godot game over a JSON WebSocket. Use it to test a
menu, drive a character with a bot or agent, or debug a live scene from a REPL.
You can query nodes, subscribe to signals, send input and capture a viewport.
You can also expose game-specific actions so a client can ask to play a card or
start a level by name.

The addon is pure GDScript. A client can inspect a running game much like
browser DevTools can inspect a page. Stagehand speaks its own
[JSON-RPC protocol](docs/protocol.md).

## Add it to a Godot project

Clone the repository and copy the addon into your project:

```sh
git clone https://github.com/mieko/stagehand.git
mkdir -p /path/to/game/addons
cp -R stagehand/addons/stagehand /path/to/game/addons/
```

Create the bridge from a startup node. The example enables all optional builtins
when the game's environment contains a nonempty `STAGEHAND_TOKEN`.
**Every authenticated client can then execute arbitrary code in the game
process.** Share the token only with clients you trust with the game's
operating-system permissions. See [security](docs/security.md).

```gdscript
const Stagehand = preload("res://addons/stagehand/bridge.gd")


func _ready() -> void:
	var token := OS.get_environment("STAGEHAND_TOKEN")
	if token.is_empty():
		return

	var bridge := Stagehand.new()
	add_child(bridge)

	var error := bridge.enable_builtins()
	if error == OK:
		error = bridge.start(token, 0)

	if error != OK:
		bridge.queue_free()
		push_error(error_string(error))
		return

	print("Stagehand port: ", bridge.get_port())
```

Launch the game from a shell with a private token in its environment. For
example, with Node.js installed, generate a fresh token in the shell you will
use for the game and client:

```sh
export STAGEHAND_TOKEN="$(node -p "require('node:crypto').randomBytes(32).toString('hex')")"
```

Port `0` chooses an available loopback port. Keep the node alive across scene
changes if clients should stay connected. Removing the bridge closes its connections and releases held synthetic input.
See the [addon guide](addons/stagehand/README.md) for setup and remote connections.

## Connect from JavaScript

From the Stagehand checkout, launch `node` (22 or newer) with the same token in
its environment. Substitute the port printed by the game:

```js
const { connect } = await import('./client/client.mjs');
const game = await connect('ws://127.0.0.1:49152', {
  token: process.env.STAGEHAND_TOKEN,
});
const tree = await game.builtin('SceneTree');
console.log((await tree.query({ class: 'Camera3D' })).nodes.map((node) => node.path));
```

Reuse the connection for later calls, then call `game.close()`. The small JS client
has no npm dependencies. To write a client in another language, use its WebSocket
and JSON libraries. The [wire reference](docs/protocol.md) describes the handshake,
requests, events and encoding of Godot values.

## Choose what to expose

Every bridge provides a `Registry` for discovering registered objects, their
operations and events. To select a subset of builtins, specify it once during
startup, for example `bridge.enable_builtins(["SceneTree", "Screen"])`.
Omitting the call leaves only the Registry and the objects you register.

| Builtin            | Use                                                                                     |
| ------------------ | --------------------------------------------------------------------------------------- |
| `Runtime`          | Read engine information, pause state and timing settings.                               |
| `SceneTree`        | Find nodes and get references to the root and current scene.                            |
| `Screen`           | Find viewports and capture screenshots.                                                 |
| `Input`            | Send keyboard, mouse or InputMap events and schedule input sequences.                   |
| `Object`           | Read and write properties, call methods and subscribe to native signals.                |
| `Script`           | Evaluate GDScript. With Input enabled, hold input until a game-state condition matches. |
| `PropertyRecorder` | Sample properties and getters inside Godot, then retrieve the recording.                |

For examples of input and sampling inside the game, see [conditional
input](docs/protocol.md#conditional-input) and [recording](docs/recording.md).

## Expose a game operation

Register a game object on the bridge and name the operations clients may call.
Each callback receives a Dictionary of named arguments:

```gdscript
var operations := {
	"hello": func(_params):
		return "Hello from Godot!"
}
bridge.register_object(self, "Greeter", "example", operations)
```

```js
const greeter = await game.findObject('Greeter');
console.log(await greeter.invoke('hello')); // Hello from Godot!
```

See [object registration](addons/stagehand/README.md#registering-game-owned-objects)
for observations, events and handle lifetimes. The [client guide](client/README.md)
covers JS wrappers, input completion and cancellation. See the [client example](client/examples.mjs)
and [development and compatibility guide](docs/development.md) for fixture usage and engine versions.
