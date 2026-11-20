# Stagehand

The Stagehand addon exposes a Godot game to external clients over a persistent
JSON-RPC 2.0 WebSocket connection. It is written in GDScript. See
[engine compatibility](../../docs/development.md#compatibility-and-limits).

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

	var error := bridge.enable_builtins() # All optional endpoints.
	if error == OK:
		error = bridge.start(token, 0) # Loopback; 0 selects an available port.

	if error != OK:
		push_error(error_string(error))
		bridge.queue_free()

		return

	print("Stagehand address: http://127.0.0.1:", bridge.get_port())
```

Nothing starts merely because the addon is present. For scene transitions, put the
bridge under a deliberately persistent game node if the connection should survive.
Removing it closes connections and releases its synthetic inputs. No autoload or
project settings are installed by this package.

The no-argument `enable_builtins()` call is shorthand for:

```gdscript
bridge.enable_builtins(
	["Runtime", "SceneTree", "Object", "Screen", "Input", "Script", "PropertyRecorder"],
)
```

Pass a subset such as `["Runtime", "Screen", "Input"]` to expose only those
endpoints. Call this method once with the desired set. Passing `[]`, or omitting
the call, leaves optional builtins disabled; Registry and your game-owned
registrations remain available. The
[protocol reference](api.md#optional-builtin-operations) lists
each builtin's operations.

`enable_builtins()` returns `OK`, `ERR_INVALID_PARAMETER` for unknown names, or
`ERR_ALREADY_IN_USE` if already configured. Validation happens before installation,
so a failed initial attempt can be corrected and retried. Repeated names in a valid
list are deduplicated. These are Godot `Error` values, not JSON-RPC failure codes.

The game-side query is available before and after setup:

```gdscript
print(bridge.builtin_configuration())
```

It returns `{configured, available, selected}`. The lists are copies in canonical
name order. `configured` is false until setup succeeds; an explicit `[]` succeeds
with `configured: true` and an empty selection. This reports the startup selection, not the lifetime of each endpoint;
Registry lists the currently exposed objects.

Selecting both Input and Script adds `hold_until` to Input. See
[conditional input](api.md#conditional-input) for its GDScript
condition and bounded execution rules.

Every client with the token can use the selected endpoints. Enable Object, Script
or PropertyRecorder only for clients you trust to run code on your machine. Use a private,
unpredictable launch token; the listener defaults to `127.0.0.1`.
See [security](../../docs/security.md) for what each builtin lets a client do.

## Serve the matching client and API reference

The addon ships its standalone Node.js 22+ client and Stagehand API reference.
Call `serve_client()` before starting the listener to publish them. Supply a
game reference if you have one:

```gdscript
bridge.app_name = "My Game"
var error := bridge.serve_client("res://docs/game.md")
```

Check the return value before advertising the downloads. RPC can start without
publishing assets. In an export preset, include
`addons/stagehand/client.mjs,addons/stagehand/api.md` in the non-resource file
filter and add the path to your game reference if supplied.

The index at `/` links to the published `/client.mjs`, `/api.md`, and optional
`/game.md`. These downloads are public to clients that can reach the listener.
Pass the same HTTP base address to `connect()` for RPC at `/rpc`. Set
`app_name` before `start()` to name the game on the index.

### Bundle a game-specific client

The core client can call any registered operation. To add named methods for
your game, save an entry point such as `game-client.mjs` in your project root.
This example adds a method for the [Greeter example](../../README.md#expose-a-game-operation)
and keeps the core module's named exports.

```js
import { connect as connectStagehand, forwardMethods } from './addons/stagehand/client.mjs';
export * from './addons/stagehand/client.mjs';

export function connect(address, options = {}) {
  return connectStagehand(address, {
    ...options,
    wrappers: {
      example: forwardMethods(['hello']),
      ...options.wrappers,
    },
  });
}
```

With esbuild available as a development tool, run this from the Godot project root:

```sh
npx esbuild game-client.mjs --bundle --platform=node --format=esm \
  --outfile=stagehand/client.mjs
```

Pass `"res://stagehand/client.mjs"` as the second argument to `serve_client()`
and include that file in the export preset in place of the default client.
If your mod mounts its assets under a different resource directory, pass the
packaged core reference path as the third argument.
The bundle includes the imported modules. Users download and import one file.
[esbuild's Node guide](https://esbuild.github.io/getting-started/#bundling-for-node)

## Remote connections

`start(token, port = 0, bind_address = "127.0.0.1")` keeps remote access opt-in.
`"localhost"` listens on both available loopback families using the same port and
bridge instance. If either available family cannot bind, startup fails without
leaving a partial listener. Use Godot's `"*"` convention to listen on all IPv4 and IPv6 interfaces. For a
narrower binding, use `"0.0.0.0"` for IPv4 only, `"::"` for IPv6 only, or a specific
interface IP. Port `0` still selects an available port, returned by `get_port()`.

For example, start the game-side bridge with:

```gdscript
var error := bridge.start(token, 49152, "*")
```

The client connects using the game's reachable hostname or IP, with the same token:

```js
const game = await connect("http://game-host:49152", {
  token: process.env.STAGEHAND_TOKEN,
});
```

The addon serves plain HTTP and WebSocket, which do not encrypt the token or traffic. Use a
trusted network or an encrypted tunnel; for TLS termination in front of the addon,
the client can use the proxy's `https://` base address. Mount Stagehand at the root. Forward HTTP/1.1
upgrades on `/rpc` and preserve any incoming `Origin` header. For a loopback
backend, use its loopback host in the upstream `Host` header. An SSH local
forward can use a different local port; connect to its loopback address.

`start()` requires a nonempty token. Use `start_local(port = 0)` to explicitly
allow tokenless access on the available loopback interfaces. Any local process
that can reach that listener can use the registered operations. Both modes
reject WebSocket upgrades carrying an `Origin` header. See [security](../../docs/security.md).

## JavaScript

Use Node 22+ and the [downloaded or copied client module](../../README.md#connect-from-javascript).
This example assumes a `move_forward` InputMap action and a rendered viewport.

```js
import { connect } from "./stagehand-client.mjs";
import { writeFile } from "node:fs/promises";

const game = await connect("http://127.0.0.1:49152", {
  token: process.env.STAGEHAND_TOKEN,
});

try {
  const input = await game.root("Input");
  const movement = await input.sequence({
    ticks: 12,
    events: [{ at_tick: 0, pressed: true, input: { action: "move_forward" } }],
  });
  console.log(movement.reason); // => sequence_exhausted

  const screen = await game.root("Screen");
  const capture = await screen.capture();
  await writeFile("/tmp/stagehand.png", capture.image);
} finally {
  game.close();
}
```

`sequence()` awaits completion. Completion reports input execution, not whether
the character reached a destination. See the [client guide](../../client/README.md)
for acceptance, cancellation, subscriptions and wrappers.

## Registering game-owned objects

Registration supplies a label, kind, named operations, optional observation
callback, and events. Operation callbacks receive one Dictionary, execute on
Godot's main thread, and return a normal value or `bridge.fail(code, message)`.
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
	true, # Listed in Registry.
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

Declare native signal names in `events` to expose them without Object; Stagehand
connects those signals automatically. Other declared event names use `publish()`.
Use one publication path per event. The `discoverable` argument controls listing
and registration notifications; an unlisted handle's declared operations/events
remain available to callers who know it.

The optional `version` identifies your object's API contract. Empty strings are
omitted from discovery; Stagehand does not interpret or negotiate versions.

Node removal invalidates its handles and subscriptions. Other Objects use weak
references and are pruned once freed. Registration retains operation callbacks;
when those retain a RefCounted target, unregister it explicitly at its owner's
lifecycle boundary. Handles are scoped to this running bridge instance, not durable
NodePaths or JavaScript numbers. `Registry.list` includes only registered roots,
not every live reference a client has received.

Game logic and asynchronous actions belong to game-owned endpoints.
`bridge.clock()` supplies observation metadata for their game-side callbacks.
Global Input can affect the human-controlled character; independent character
controls belong in your game's operations.

See [the protocol](api.md) for methods, types, timing, limits, and input
semantics. See [development](../../docs/development.md) for tested scope and commands.
