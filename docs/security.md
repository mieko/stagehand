# Security

A Stagehand connection can carry anything from a single game-defined action to
full debugger access. Your startup code chooses the available operations. Calling
`enable_builtins()` with no arguments gives every authenticated client **arbitrary
code execution in the game process**. A client can change game state, read and
write files and launch programs with the game's operating-system permissions.
A separate game profile selects where ordinary saves go. It places no restriction
on files a script can open.

## What each builtin lets a client do

| Builtin          | What a connected client can do                                                                                                                                                                      |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Registry         | List the objects, operations and events you have exposed. Always present.                                                                                                                           |
| Runtime          | Read engine version, save-directory path, timing settings and the current scene reference.                                                                                                          |
| SceneTree        | Find nodes and read their names, paths, classes and groups; receive references to them.                                                                                                             |
| Screen           | Take screenshots of game viewports and read their dimensions.                                                                                                                                       |
| Input            | Press keys and mouse buttons, send mouse motion and wheel events, and trigger InputMap actions. This can play the game and operate its menus.                                                       |
| Object           | Read and change properties, call methods and listen to native signals on reachable game objects. Treat this as letting the client run code.                                                         |
| Script           | Run supplied GDScript inside the game.                                                                                                                                                              |
| PropertyRecorder | Read properties and invoke supplied method names on live references; run supplied readings when Script is enabled too. A "getter" can have side effects. Treat this as letting the client run code. |

Runtime, SceneTree and Screen provide inspection, not general property writes,
method calls or scripting. They can still reveal information you intended to
keep private. For example, SceneTree may reveal hidden nodes and Screen may
capture UI containing private information.

Input is not necessarily harmless. If your game has a debug console, mod loader
or file-writing UI that accepts synthetic input, a client may be able to operate
it. Check what those controls can do before giving Input to an untrusted client.

Object and PropertyRecorder can reach script resources and call game/engine
methods; Script makes execution direct. PropertyRecorder's method selector is
not restricted to pure getters. Disabling SceneTree does not make these safe:
they can traverse the tree themselves.

## Select the builtins deliberately

Creating a bridge installs Registry. Nothing listens until you call `start()`.
Calling `enable_builtins()` with no arguments enables **all optional builtins**,
including Object, Script and PropertyRecorder. That is appropriate for a trusted developer or bot.

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

Without Object, Script or PropertyRecorder, returning a node reference does not let the client call
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

The listener defaults to `127.0.0.1`. An explicit `"localhost"` binding serves both
available loopback families on the same port. Binding `"*"`, `"0.0.0.0"`, `"::"` or another
interface can let other machines connect. Use a private, unpredictable token for
private access. Starting with an empty token disables authentication for every
client; it is an explicit choice by the game. Publishing a fixed token lets anyone who knows it use the API
you enabled.

Stagehand rejects WebSocket requests that carry a browser `Origin`. Loopback
bindings check the HTTP `Host` against the loopback addresses and listening port.
Local processes that can reach the listener can still attempt RPC connections.
Keep private tokens out of webpages, logs and source control.

HTTP discovery and any configured client and API reference are public to
clients that can reach the listener. Package public files for these routes.
RPC authentication applies to the WebSocket session.

Stagehand serves plain HTTP and WebSocket. Tokens and game traffic are
unencrypted. For remote access, use a trusted network, an encrypted tunnel,
or a TLS proxy with an HTTPS base address.

## Timeouts do not stop code

Calls, getters and scripts run on the game's main thread. An endless loop or
blocking call can freeze the game and its connector. A timeout cannot interrupt
that code or roll back changes already made. Message and connection limits do not make untrusted scripts safe to run.

A timeout or lost connection also does not mean an action failed to happen.
Do not automatically replay an uncertain action. Game-owned operations must
provide their own completion and cancellation behavior.
