# Security

Choose builtins according to what you want a connected client to be able to do.
**Enable Object or Script only for clients you trust to run code on your machine.**
They can read and write the same files and start the same programs that the game can,
subject to the game's operating-system permissions.

## What each builtin lets a client do

| Builtin | What a connected client can do |
| --- | --- |
| Registry | List the objects, operations and events you have exposed. Always present. |
| Runtime | Read engine version, timing settings and the current scene reference. |
| SceneTree | Find nodes and read their names, paths, classes and groups; receive references to them. |
| Screen | Take screenshots of game viewports and read their dimensions. |
| Input | Press keys and mouse buttons, send mouse motion and wheel events, and trigger InputMap actions. This can play the game and operate its menus. |
| Object | Read and change properties, call methods and listen to native signals on reachable game objects. Treat this as letting the client run code. |
| Script | Run supplied GDScript inside the game. |

Runtime, SceneTree and Screen provide inspection, not general property writes,
method calls or scripting. They can still reveal information you intended to
keep private. For example, SceneTree may reveal hidden nodes and Screen may
capture UI containing private information.

Input is not necessarily harmless. If your game has a debug console, mod loader
or file-writing UI that accepts synthetic input, a client may be able to operate
it. Check what those controls can do before giving Input to an untrusted client.

Object and Script both let a client execute code. Object can reach script
resources and call game/engine methods; Script makes execution direct. Disabling
SceneTree does not make Object safe: Object can traverse the tree itself.

## Select the builtins deliberately

Creating a bridge installs Registry. Nothing listens until you call `start()`.
Calling `enable_builtins()` with no arguments enables **all six optional builtins**,
including Object and Script. That is appropriate for a trusted developer or bot.

Pass an explicit list to expose less:

```gdscript
bridge.enable_builtins(["Screen"])
```

To let clients use only your game's registered operations, omit optional builtin
installation entirely. Registry will still let them discover your objects.

Select builtins once, before accepting clients. See [setup](../addons/stagehand/README.md)
for configuration queries, return values and examples.

Every client with the token gets the same exposed API. Separate bridges and tokens
do not isolate clients that can execute code inside the same game process.

## Expose your own operations

Without Object or Script, returning a node reference does not let the client call
arbitrary methods on it. Clients can call only the operations you register.
They cannot create arbitrary Godot Objects through the value encoding.

Without Object, clients can subscribe only to the event names you declare.
With Object enabled, they can inspect and subscribe to arbitrary native signals.
See [registration](../addons/stagehand/README.md#registering-game-owned-objects)
for declaring events.

Your callbacks must check their arguments and perform only the intended actions.
For example, accept a card reference for a card-play operation, rather than a
method name or script to execute. The client can still spend resources, change
saves or abandon a run if your registered operations let it.

`discoverable: false` only hides an object from listings and registration
notifications. A client that knows its handle can still use its registered
operations and events. Handles are identifiers, not passwords.

## Protect the connection

The listener defaults to `127.0.0.1`. Binding `"*"`, `"0.0.0.0"`, `"::"` or another
interface can let other machines connect. Use a private, unpredictable token for
private access. Publishing a fixed token lets anyone who knows it use the API
you enabled.

Do not assume localhost prevents browser connections. Stagehand does not check
browser Origins; keep private tokens out of webpages, logs and source control.

Stagehand uses plain `ws://`: the token and game traffic are not encrypted.
For remote access, use a trusted network or an encrypted tunnel/TLS termination.

## Timeouts do not stop code

Calls, getters and scripts run on the game's main thread. An endless loop or
blocking call can freeze the game and its connector. A timeout cannot interrupt
that code. Message and connection limits do not make untrusted scripts safe to run.

A timeout or lost connection also does not mean an action failed to happen.
Do not automatically replay an uncertain action. Game-owned operations must
provide their own completion and cancellation behavior.
