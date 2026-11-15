# Stagehand

A pure GDScript addon for Godot 4.5+. It provides external bots, automated tests
and interactive agents with a persistent, authenticated WebSocket connection.

Expose your own game objects and high-level operations, alongside optional builtins
for scene inspection, events, screenshots and synthetic input.
It starts explicitly from your game's code.

## Add it to a Godot project

Copy `addons/stagehand` into your project's `addons/` directory.

Create the bridge explicitly from your game's startup code:

```gdscript
const Stagehand = preload("res://addons/stagehand/bridge.gd")


func _ready() -> void:
	var token := OS.get_environment("STAGEHAND_TOKEN")
	if token.is_empty():
		return

	var bridge := Stagehand.new()
	add_child(bridge)
	bridge.enable_builtins()

	var error := bridge.start(token, 0)
	if error != OK:
		bridge.queue_free()
		push_error(error_string(error))

		return

	print("Stagehand port: ", bridge.get_port())
```

The addon does nothing merely because its files are present. Keep the bridge node
under an intentionally persistent node if connections should survive scene changes.
Removing it closes connections and releases its synthetic inputs. You may omit
builtins or enable a selected subset.

`enable_builtins()` enables all five builtin endpoints. Its explicit form is:

```gdscript
bridge.enable_builtins(["Runtime", "SceneTree", "Object", "Screen", "Input"])
```

| Name | Exposes |
| --- | --- |
| `Runtime` | Engine version, current scene, pause state and timing settings. |
| `SceneTree` | Current scene/root references and node queries. |
| `Object` | Property inspection, property reads/writes and method calls on live objects. |
| `Screen` | Viewport discovery, dimensions and screenshots. |
| `Input` | Synthetic keyboard, mouse and InputMap actions, including bounded sequences. |

Pass only the names you want, for example
`bridge.enable_builtins(["Runtime", "Screen", "Input"])`. Call it once with the
desired set; later calls do not add or replace endpoints. Pass `[]`, or omit the
call entirely, to expose only the game-owned objects you register yourself.

The token grants powerful control over the running game's normal authority.
Choose a private, unpredictable launch token. The listener defaults to
`127.0.0.1`; do not expose the token to untrusted browser code.

For remote clients, use Godot's `"*"` convention to listen on all IPv4 and IPv6
interfaces: `bridge.start(token, 49152, "*")`. Use `"0.0.0.0"` for IPv4 only,
`"::"` for IPv6 only, or a specific interface IP. Clients connect to the machine's
hostname or IP. See [remote connections](addons/stagehand/README.md#remote-connections)
for transport details.

## Connect from JavaScript

Node 22+ provides the required WebSocket implementation; the client has no npm
dependencies. It's only a few hundred straightforward lines of JavaScript, and
the WebSocket/JSON-RPC protocol makes it simple to port to another language with
WebSocket support. Import once and retain the connection:

```js
import { connect } from './client/client.mjs';

const game = await connect('ws://127.0.0.1:49152', {
  token: process.env.STAGEHAND_TOKEN,
});

const tree = await game.builtin('SceneTree');
console.log(await tree.invoke('current'));
// => { root: RemoteObject { id: '…', … }, scene: RemoteObject { id: '…', … } }
// Reuse game for later calls, then game.close().
```

An environment without a global WebSocket can supply `{WebSocket: constructor}`.
Ordinary Node scripts, persistent JS sessions and bots use the same API;

See [usage and registration](addons/stagehand/README.md),
[wire protocol](docs/protocol.md), [the executable example](client/examples.mjs),
and [development/testing](docs/development.md).

## Expose your own objects

After creating the bridge, register an existing object and the operations you want
clients to call. Here, `self` is the current node:

```gdscript
var operations := {
	"hello": func(_params):
		return "Hello from Godot!"
}
bridge.register_object(self, "Greeter", "example", operations)
```

Each operation receives a Dictionary of named parameters and returns a result.
The connected JS client can discover the object and call it:

```js
const greeter = await game.findObject('Greeter');

console.log(await greeter.invoke('hello'));
// => Hello from Godot!
```

Client-side wrappers are optional. As an alternative to the plain connection above,
you can give the registered `example` kind a custom `hello()` method:

```js
const game = await connect('ws://127.0.0.1:49152', {
  token: process.env.STAGEHAND_TOKEN,
  wrappers: {
    example: remote => ({
      hello: () => remote.invoke('hello'),
    }),
  },
});

const greeter = await game.findObject('Greeter');
console.log(await greeter.hello());
// => Hello from Godot!
```

See [wrapper factories](client/README.md#wrapper-factories) for details. Builtin
Input and Screen helpers use the same mechanism.

See [registration details](addons/stagehand/README.md#registering-game-owned-objects)
for observations, events and object lifetimes.
