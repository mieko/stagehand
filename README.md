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

	var error := bridge.enable_builtins()
	if error == OK:
		error = bridge.start(token, 0)

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

`enable_builtins()` enables all optional builtin endpoints:

| Name | Exposes |
| --- | --- |
| `Runtime` | Engine version, current scene, pause state and timing settings. |
| `SceneTree` | Current scene/root references and node queries. |
| `Object` | Property inspection, reads/writes, method calls and arbitrary native-signal subscriptions. |
| `Screen` | Viewport discovery, dimensions and screenshots. |
| `Input` | Synthetic keyboard, mouse and InputMap actions, including bounded sequences. |
| `Script` | Runtime GDScript evaluation; enables conditional input when Input is selected too. |
| `PropertyRecorder` | Capture native or scripted readings inside Godot for later retrieval. |

Pass only the names you want, for example
`bridge.enable_builtins(["Runtime", "Screen", "Input"])`. Call it once with the
desired set; later calls do not add or replace endpoints. Pass `[]`, or omit the
call entirely, to expose `Registry` and the game-owned objects you register yourself.

Only enable Object, Script or PropertyRecorder for clients you trust to run code on your machine.
Input can play the game and operate its menus.
See [security](docs/security.md) for what each builtin lets a client do.

The listener defaults to loopback. See
[remote connections](addons/stagehand/README.md#remote-connections) for binding and
transport options.

## Connect from JavaScript

Node 22+ provides the required WebSocket implementation; the client has no npm
dependencies. It's only a few hundred straightforward lines of JavaScript, and
the WebSocket/JSON-RPC protocol makes it simple to port to another language with
WebSocket support. Use the printed port in the URL, then retain the connection:

```js
import { connect } from './client/client.mjs';

const game = await connect('ws://127.0.0.1:49152', {
  token: process.env.STAGEHAND_TOKEN,
});

const tree = await game.builtin('SceneTree');
console.log(await tree.current());
// => { root: RemoteObject { id: '…', … }, scene: RemoteObject { id: '…', … } }
// Reuse game for later calls, then game.close().
```

An environment without a global WebSocket can supply `{WebSocket: constructor}`.
Ordinary Node scripts, persistent JS sessions and bots use the same API.

`Registry` is an always-present root for discovery, independent of optional builtins:

```js
const registry = await game.builtin('Registry');

for (const object of await registry.list()) {
  console.log(object.label, object.kind);
}
// => Registry Registry
// => Runtime Runtime
// => …
```

Discovery describes each root's operations, events and optional contract version.

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

See [registration details](addons/stagehand/README.md#registering-game-owned-objects)
for observations, events and object lifetimes, and
[wrapper factories](client/README.md#wrapper-factories) to add convenient JavaScript
methods for your object's kind.

## React to game state inside Godot

Select both `Script` and `Input` to hold input until a game-state condition matches,
without a client round trip per sample. The condition runs as ordinary GDScript
inside the game, with a simulation-time limit and automatic input release.
See the [JavaScript example](client/README.md#gdscript-predicates) and
[conditional-input contract](docs/protocol.md#conditional-input).

## Record measurements

Select `PropertyRecorder` to sample native properties, indexed paths or synchronous
getters inside Godot, then retrieve retained pages for plotting. Selecting Script too
allows derived readings through the same GDScript evaluator. See
[recording](docs/recording.md) for selectors, sampling phases and capture limits.
