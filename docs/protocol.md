# Stagehand protocol 1

One UTF-8 JSON-RPC 2.0 text message per WebSocket message. The listener is explicit,
loopback by default, and authenticated. JSONRPC's Godot helpers produce envelopes; this
addon validates and dispatches its small named-parameter API itself because native
JSONRPC dispatch does not expose the callback-error contract needed here.

`start(token, port = 0, bind_address = "127.0.0.1")` selects the game listener.
Godot's `"*"` wildcard listens on all IPv4 and IPv6 interfaces; `"0.0.0.0"` and
`"::"` select all IPv4 or IPv6 interfaces respectively. A specific interface IP
restricts the listener to that address.
The JS client connects to the supplied WebSocket URL without a loopback restriction.
The addon serves unencrypted `ws://`; encrypted tunnels or TLS termination belong
to the deployment. Authentication and wire semantics are identical for local and
remote clients.

```json
{"jsonrpc":"2.0","id":"1","method":"session.hello","params":{"token":"PRIVATE_LAUNCH_TOKEN","protocol":1}}
```

The result contains protocol, random running-instance identity, engine version,
clock, physics tick rate, and currently registered endpoint descriptors. A descriptor
has `id`, `label`, `kind`, `operations`, `operation_info`, and `events`. Labels are discovery hints;
requests target a specific opaque `id`. Authentication and version mismatches fail
before inspection. Authenticate within five seconds of connection.

## Wire methods

| Method | Named parameters | Result |
| --- | --- | --- |
| `session.hello` | `token`, optional `protocol:1` | Session snapshot |
| `objects.list` | none | Fresh registered descriptors |
| `object.describe` | `object` handle | Descriptor |
| `object.observe` | `object` handle | `{object,value,clock}` |
| `object.call` | `object`, `method`, optional `params:{}` | Registered operation's value |
| `object.subscribe` | `object`, `event` | Ready subscription ID |
| `object.unsubscribe` | `subscription` | Whether removed |

Ordinary operations execute synchronously on the main thread and return ordinary
RPC results. There is no universal action wrapper or polling requirement. Registered
callbacks must be bounded; a long callback blocks the game and listener. GDScript
errors cannot be caught generically here: endpoints must validate their parameters
and return `bridge.fail(...)` for domain failures. An async game action needs its
own explicit acceptance/completion interface.

Server notifications:

- `objects.added`: descriptor of a newly registered endpoint.
- `objects.removed`: `{object}`. Local subscriptions and handles become stale.
- `object.event`: `{subscription,object,event,value,clock}`.
- `stream.error`: `{method,subscription,object,code,message}` when an event value
  cannot be encoded. That event was lost; obtain a fresh observation as appropriate.

Subscriptions are installed before acknowledgment. Each connection has independent
subscriptions. Native signals deliver an array of their emitted arguments, including
an empty array for a signal with no arguments. Explicit endpoint events deliver
their published value.

## Optional builtin operations

Builtins are ordinary registered objects, with their names as both label and kind
(`Input`, `Screen`, etc.), invoked through the same `object.call` method. A game
may enable any subset or none.

| Label | Operations and parameters |
| --- | --- |
| `Runtime` | `info()` — engine, display server, scene, pause/time-scale/tick-rate state. Its observer returns the same information. |
| `SceneTree` | `current()` — root/current scene refs. `query({root?,name?:glob,class?:nativeClass,internal?:false,limit?:100})` — bounded breadth-first live node records with ref, path, native class, groups, parent; includes root if matching. |
| `Object` | `inspect({target})` — property/method/signal metadata. `get({target,property})`, `set({target,property,value})`, `call({target,method,args?:[]})`. |
| `Screen` | `viewports()` — up to 100 live viewports. `dimensions({viewport?})` — logical/texture sizes. `capture({viewport?})` — PNG base64, capture ID, viewport, width/height, MIME, timing. Root window is default. |
| `Input` | `actions()`, `press(input)`, `release(input)`, `move_mouse({relative?,position?})`, `move_mouse_to({position,duration_ms,from?})`, `scroll({vertical?,horizontal?,position?})`, `sequence({ticks,events,max_wall_ms?})`, `status({action})`, `cancel({action})`. |

Reflected access follows actual live references, including ordinary non-exported
GDScript fields in a release build. It does not expose arbitrary C++ memory or all
private engine internals. Metadata is what the selected engine retains: native
argument names/defaults/type information can be reduced in release builds. Calls
validate known signatures and argument counts; missing native signature information
limits validation. A method may report its own failure through logs or return null.
Generic property getters and method calls may have side effects; null is not a
universal semantic success signal. Object construction via the value codec is
disabled. Reflected calls still intentionally have the game's normal authority.

### Values

- JSON primitives, arrays, and ordinary string-key dictionaries remain JSON.
- `{"$ref":"opaque-instance-scoped-handle","$type":"Dingus"}` follows a live
  Godot object and supplies its client wrapper type. Registered objects use their
  `kind`; unregistered objects use `object`. Clients can send just `{"$ref":"handle"}`
  back: the server resolves the handle and does not trust client-supplied type
  information.
- `{"$godot":"i:9223372036854775807"}` preserves a signed 64-bit integer;
  JS receives BigInt. Unsafe numbers must be sent as BigInt, not rounded JS numbers.
- `{"$godot":"f:inf"}`, `f:-inf`, `f:nan` preserve scalar nonfinite floats.
- StringName and NodePath use Godot's `sn:` / `np:` scalar prefixes.
- Math and packed values use Godot JSON native value encoding, e.g.
  `{"$godot":{"type":"Vector2","args":[12,34]}}` or Transform3D's 12 components.
  JS receives `GodotValue` with `.type`, `.args`, and `.native`.
- Nonstring dictionary keys and reserved `$ref`/`$godot`/`$dictionary` keys use
  `{"$dictionary":[[key,value],...]}`; JS receives Map.

Supported native values are vectors, rects, transforms, Plane, Quaternion, AABB,
Basis, Projection, Color, and Godot packed arrays. Native components must be finite numbers within ±(2^53−1) (packed strings must be strings). PackedInt64 elements beyond
the safe JSON range are rejected rather than rounded; use an ordinary array of
BigInts instead. Callable, Signal, RID, arbitrary constructed objects, cycles,
oversized values, and invalid native encodings fail explicitly.

### Input and bounded execution

An input descriptor contains exactly one of:

```js
{ action: 'move_forward', strength: 0.7 } // Existing InputMap action; default 1.
{ key: 'W', physical: true }            // OS key name; logical by default.
{ key: 'A', ctrl: true }                // shift/ctrl/alt/meta are event flags.
{ button: 'left', position: vector2 }   // left/right/middle; position optional.
```

Keys have no automatic repeat; presses are not text composition. Modifier flags
are not separate held modifier-key events. InputEventAction, InputEventKey, and
InputEventMouseButton go through `Input.parse_input_event` and buffered-event flush,
updating Input state and delivering events to normal consumers. Named action
injection does not synthesize its bound physical key. Gamepad/touch are absent.

Standalone presses survive their responses until matching release, connection
loss, endpoint removal, or bridge shutdown. A sequence owns only its own holds;
it cannot modify a separately held matching input. There is one external Input
writer while holds or an operation are active. Other connections may observe but
cannot steal/cancel it. Input is the real global singleton: synthetic and physical
events can conflict on the same controls. This is not per-character arbitration.

`sequence` accepts 1–3600 physics ticks, at most 256 events, and a 1–60000ms wall
budget (default 10000ms). Each event is `{at_tick,pressed,input}`; offsets are
zero-based and inside the sequence. Equal-offset events execute in supplied order.
The next physics callback applies offset zero; the endpoint's priority is -10000,
before ordinary default-priority gameplay nodes. Completion occurs at the following
boundary after the requested last gameplay tick. Scene pause stops advancement;
network handling, cancellation, and wall-budget cleanup continue. Completion
releases sequence-owned holds, preserving separate standalone holds.

`move_mouse` delivers an immediate motion event. Position defaults to the last
synthetic position, initially the viewport's polled cursor. Relative defaults zero;
the caller controls both fields independently. Coordinates are main-window
input-event coordinates; relative is copied into both `relative` and
`screen_relative`. Godot applies the receiving viewport's input transform. A
Control's global rectangle uses logical viewport units: transform its center with
the root viewport's `get_final_transform()` to obtain an input position. The STS2
proof exercises this with a stretched window. Physical desktop coordinates and OS
cursor movement are separate; no automatic monitor/DPI conversion is supplied.
Mouse button events default to the same synthetic position. Motion carries the
current button mask, so a held button can be dragged.

`scroll` takes signed `vertical` and/or `horizontal` wheel factors in -100..100
(at least one nonzero). Positive means down/right. Optional `position` uses the
same main-window event coordinates as mouse movement. Each nonzero axis delivers
a native wheel-button press/release pair with `factor = abs(amount)`; this is not a
pixel-distance or touchpad-pan contract. The receiving control determines scroll
distance. It preserves independently held buttons, shares Input writer ownership,
and refuses during an active sequence/mouse move. It does not move the OS cursor.
The JS convenience is `input.scroll({vertical: 1, position})`.

`move_mouse_to` takes a finite Vector2 destination and 1–60000ms duration. It uses
linear wall-time interpolation locally, once per process callback, with a final
exact-destination event. Origin is optional `from`, otherwise the synthetic position
above. It works for paused UI, shares Input ownership and cancellation, and preserves
separately held buttons. The runtime allows duration+1000ms wall budget; a stall
beyond that fails rather than claiming arrival. Sample count depends on frame rate.
No RPC is needed for intermediate positions.

On macOS, motion/position events reach `_input` and GUI hit testing, while the main
viewport's `get_mouse_position()` still uses DisplayServer's OS pointer. The addon
does not warp that pointer. `absolute_cursor_polling:false` and
`physical_cursor_moved:false` communicate this limitation. Scripts consuming polled
cursor position need an appropriate game-owned seam; event injection cannot stand
in for every pointer consumer. Secondary-window routing is not implemented.

Both scheduled operations return `{action,status:"accepted"}` and later publish one
`completed` event containing action identity, terminal status, reason, wall time,
applied physics ticks, simulation seconds, release status, and final Input state. Mouse results also
include position, duration, and sample count. Reasons implemented now:
`sequence_exhausted`, `destination_events_delivered`, `requested`,
`connection_closed`, and `wall_time_budget`. They describe execution, not gameplay
success. `status` retains the active action and latest terminal result only.
Disconnect cancels active work and releases all connection-owned holds. The client
rejects waiting promises when the connection or endpoint disappears; it does not
pretend to know an unreceived terminal outcome.

### Observations, images, and limits

Observation/event clocks include instance, observed current-scene generation,
physics tick, process frame, rendered-frame counter, main-loop phase, and monotonic
microseconds as a string. Scene generation increments when a clock read observes a
different current scene; it is not a content-mutation counter or universal reset ID.
Physics counters can advance while gameplay is paused. Scheduled-input simulation
seconds accumulate the actual callback deltas; deterministic commands do not make
Godot physics deterministic.

Screen capture returns the last available viewport image through ordinary rendering
APIs. Render/physics counters are sampled at readback; the image is not guaranteed
to be an atomic snapshot of another observation or the current physics tick.
Dimensions are viewport/texture pixels, not physical monitor dimensions. Headless
no-render capture returns unavailable. PNGs are correlated inline responses; the JS
capture helper returns a Buffer.

Limits: 8 connections, 5s authentication deadline, 8MiB inbound/outbound messages,
64 requests per batch, 64 packets processed per peer/frame, 128 subscriptions per
connection, value depth 16, collections/native argument arrays of 1024 entries.
Tree queries stop at 10000 visited nodes and return at most 1000 matches. The
viewport list stops at 100 entries. These bounds do not make arbitrary reflected
calls cheap. Screenshots and expensive getters can block a frame.

There is no background observation poller or unbounded addon event queue. Events
are sent through bounded WebSocket buffers; delivery/backpressure failure closes
the connection (1011), explicitly invalidating the stream. Obtain fresh observations
after reconnecting; no replay, automatic mutation retry, state coalescer, or durable
event history is provided.

Errors: JSON-RPC `-32700` parse, `-32600` invalid request, `-32601` unknown method,
`-32602` invalid params; addon `-32001` auth, `-32002` version, `-32004` stale/unknown
handle or action, `-32010` unsupported value/resource limit, `-32020` no rendered
image, `-32030` Input conflict. Empty/nested/oversized batches are rejected.
Notifications have no response. Batches have no portable ordering/atomicity promise;
use a bounded Input operation for timed ordering. Request timeout is uncertainty,
not cancellation.
