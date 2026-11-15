# JavaScript client

Import `connect`, `GodotValue` and `RpcError` from `client.mjs`, or import the local
package `godot-stagehand`. Node 22+ needs no dependency installation.
Keep a client connected to reuse handles and subscriptions; call `close()` when done.

The client is only a few hundred straightforward lines of JavaScript. The
WebSocket/JSON-RPC protocol is simple to port to another language with WebSocket
support; see the [wire protocol](../docs/protocol.md) for message and value formats.

`await game.findObject(label)` looks up the current registered objects and returns
the first matching object, or `null` if none matches. Use `game.objects()` for
descriptors and `game.object(id)` when you already have a specific handle.

`connect(url, { token })` accepts a local or remote WebSocket URL. The game listener
defaults to loopback; remote use requires an explicit game-side bind address. Use
`ws://game-host:PORT` on a trusted network or through an encrypted tunnel, or
`wss://game-host` when TLS termination fronts the addon. See
[remote setup](../addons/stagehand/README.md#remote-connections).

See the [addon usage guide](../addons/stagehand/README.md),
[protocol](../docs/protocol.md) and [development commands](../docs/development.md).
From the repository root, `npm test` runs the isolated integration suite.
No build or dependency installation is hidden in that command.

For ordinary wheel scrolling, `await input.scroll({vertical: 2, position})` delivers
one press/release wheel pulse with factor 2. Positive factors scroll down/right;
negative scroll up/left. `horizontal` is optional. Coordinates follow the same
main-window event convention as mouse motion. This is native event injection,
not OS cursor movement or guaranteed pixel displacement.

Calling a subscription's cancel function detaches its local event router
immediately. Its Promise still reports the host unsubscribe acknowledgment or
failure; a lost acknowledgment does not reinstall local delivery.

## Wrapper factories

Wrapper factories are optional: ordinary remote objects already support `invoke()`,
`observe()` and subscriptions. To add your own client-side methods, pass an object
literal mapping remote types to synchronous wrapper functions:

```js
const game = await connect(url, {
  token,
  wrappers: {
    Dingus: remote => ({
      hello: () => remote.invoke('hello'),
    }),
  },
});

const dingus = await game.findObject('My dingus');
console.log(await dingus.hello());
// => Hello from Godot!
```

On the Godot side, register that object's `kind` as `"Dingus"`. Its label
(`"My dingus"`) is independent of its type. The factory receives a generic
`RemoteObject` and returns whatever object you want callers to use: a class
instance or a small facade, with no inheritance requirement.
Each returned wrapper represents one remote object on one connection. If caching
wrappers, keep a separate cache per connection keyed by object identity.

The same factory path handles discovery, returned references, nested arrays/maps,
observations and events. Wrapped objects can also be passed back as RPC arguments;
the client encodes their original references. Wrapping needs no extra RPCs. Types
without a factory remain ordinary `RemoteObject`s.

Input and Screen helpers live on `InputObject` and `ScreenObject`, supplied through
the default `Input` and `Screen` factories. Your entries override or extend those
defaults for this connection only. Builtin handles are cached, and each lookup
uses the current factories. You can also assign `game.wrappers.Dingus = factory`
for subsequent lookups; objects you've already received keep their wrappers.

Factories must synchronously return an object. Factory errors reject the affected
RPC result; errors while wrapping a notification are emitted through the client's
`error` event. Install an error listener if your factories can fail on event data.
