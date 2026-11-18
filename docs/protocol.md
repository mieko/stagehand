# Stagehand protocol 1

One UTF-8 JSON-RPC 2.0 text message per WebSocket message. The listener is explicit,
loopback by default, with game-configured authentication. See [connection setup](../addons/stagehand/README.md)
for binding and transport options. Authentication and wire semantics are identical
for local and remote clients.

Given the game's HTTP or HTTPS base address, use `ws` or `wss` on the same host
and port to open `/rpc`. On that base address, HTTP `/` returns Markdown discovery
with links to the supplied assets. The fixed paths are `/client.mjs` for the
client, `/api.md` for Stagehand, and `/game.md` for the game-specific reference. The
listener rejects browser WebSocket origins before upgrade. WebSocket version 13
supports standard frame lengths and fragmentation. The assembled text message
is limited to 8 MiB. Binary messages and extensions such as compression are
outside Stagehand's text-only protocol.

```json
{
  "jsonrpc": "2.0",
  "id": "1",
  "method": "session.hello",
  "params": { "token": "PRIVATE_LAUNCH_TOKEN", "protocol": 1 }
}
```

The result contains protocol, random running-instance identity, engine version,
clock, physics tick rate, and currently registered endpoint descriptors. A descriptor
has `id`, `label`, `kind`, `operations`, `operation_info`, and `events`. An optional
`version` is an opaque string declared by the game at registration; unversioned
roots omit it. It is independent of the Stagehand protocol version and involves
no negotiation. Labels are discovery hints; requests target a specific opaque `id`.
Authentication and wire-protocol version mismatches fail before inspection.
Complete the handshake within five seconds of connection. A server started with
an empty token disables authentication and accepts an omitted token; protocol
validation and all other session rules still apply.

## Wire methods

| Method               | Named parameters                         | Result                       |
| -------------------- | ---------------------------------------- | ---------------------------- |
| `session.hello`      | optional `token`, optional `protocol:1`  | Session snapshot             |
| `objects.list`       | none                                     | Fresh registered descriptors |
| `object.describe`    | `object` handle                          | Descriptor                   |
| `object.observe`     | `object` handle                          | `{object,value,clock}`       |
| `object.call`        | `object`, `method`, optional `params:{}` | Registered operation's value |
| `object.subscribe`   | `object`, `event`                        | Ready subscription ID        |
| `object.unsubscribe` | `subscription`                           | Whether removed              |

Ordinary operations execute synchronously on Godot's main thread and return ordinary
RPC results. There is no universal action wrapper or polling requirement. Registered
callbacks must be bounded; a long callback blocks the game and listener. GDScript
errors cannot be caught generically here: endpoints must validate their parameters
and return `bridge.fail(...)` for domain failures. An async game action needs its
own explicit acceptance/completion interface.

Server notifications:

- `objects.added`: descriptor of a newly registered endpoint.
- `objects.removed`: `{object}`. Client subscriptions and handles become stale.
- `object.event`: `{subscription,object,event,value,clock}`.
- `stream.error`: `{method,subscription,object,code,message}` when an event value
  cannot be encoded. That event was lost; obtain a fresh observation as appropriate.

Subscriptions are installed before acknowledgment. Each connection has independent
subscriptions. Native signals deliver an array of their emitted arguments, including
an empty array for a signal with no arguments. Explicit endpoint events deliver
their published value.
Declared event names matching native signals are connected automatically. Other
declared names use `bridge.publish()`. Undeclared native signals require the Object
builtin; with Object enabled the same subscription method supports arbitrary
native signals on known references, including unlisted objects. Registry alone
does not expose signals on its backing Node.

## Registry

`Registry` is an always-present registered root, with label and kind `Registry`.
Its ordinary `list({})` operation returns current registered descriptors, including
itself; observation and `objects.list` return the same list. Registry is present
even without optional builtins and cannot be unregistered. It shares the bridge's
lifetime. Builtin API versions are advertised through discovery, independently of
the Stagehand release and wire protocol versions.

## Optional builtin operations

Builtins are ordinary registered objects, with their names as both label and kind
(`Input`, `Screen`, etc.), invoked through the same `object.call` method. A game
may enable any subset or none.

Registry lists the currently exposed roots. See the [addon guide](../addons/stagehand/README.md)
for builtin selection and setup errors, and [security](security.md) for what each
builtin lets a client do. When Script and Input are both selected, Input also
advertises `hold_until` as described under [conditional input](#conditional-input).

| Label              | Operations and parameters                                                                                                                                                                                                                                                                                        |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Runtime`          | `info()` — engine name/version, save directory, display server, scene, pause/time-scale/tick-rate state. Its observer returns the same information.                                                                                                                                                              |
| `SceneTree`        | `current()` — root/current scene refs. `query({root?,name?:glob,class?:nativeClass,internal?:false,offset?:0,limit?:100})` — breadth-first live node records with node reference, name, path, class, groups and parent. Returns `{nodes, more}`; offsets count matching nodes, including the root if it matches. |
| `Object`           | `inspect({target})` — property/method/signal metadata. `get({target,property})`, `set({target,property,value})`, `call({target,method,args?:[]})`.                                                                                                                                                               |
| `Screen`           | `viewports()` — up to 100 live viewports. `dimensions({viewport?})` — logical/texture sizes. `capture({viewport?})` and `capture_chunk({capture,offset})` — see [screenshots](#observations-images-and-limits).                         |
| `Script`           | `evaluate({source,bindings?:{}})` — compile a RefCounted evaluator and return its synchronous native result.                                                                                                                                                                                                     |
| `Input`            | `actions()`, `press(input)`, `release(input)`, `move_mouse({relative?,position?})`, `move_mouse_to({position,duration_ms,from?})`, `scroll({vertical?,horizontal?,position?})`, `sequence({ticks,events,max_wall_ms?})`, `status({action})`, `cancel({action})`.                                                 |
| `PropertyRecorder` | Captures and one-shot readings inside Godot. See [recording](recording.md) for operations, selectors and lifecycle.                                                                                                                                                                                              |

Runtime `engine` metadata uses ordinary string keys and includes `name`, `major`,
`minor` and `patch` alongside Godot's remaining version fields. `save_directory`
is the current game's user-data directory. Scene queries accept limits up to
1,000 and fail explicitly beyond 10,000 visited nodes; use a smaller root for a
large tree. Separate pages are live queries, not a retained tree snapshot.

Reflected access follows actual live references, including ordinary non-exported
GDScript fields in a release build. Native argument names/defaults/type information
can be reduced in release builds. Calls validate known signatures and argument
counts; missing native signature information limits validation. A method may report
its own failure through logs or return null.
Generic property getters and method calls may have side effects. Object construction
via the value codec is disabled; reflected calls can still reach filesystem and process APIs.
The registration argument `discoverable` controls listing, not authorization.
Known handles can use their declared operations/events whether listed or not.

### Runtime GDScript

`Script.evaluate({source,bindings?:{}})` accepts complete GDScript with an
`evaluate(bindings)` method taking one Dictionary or Variant argument. Its native
base must derive from RefCounted and its constructor must accept no arguments.
Source compiles once per request; there is no persistent namespace or script cache.
The result uses the ordinary value codec, including null and live object references.
New RefCounted results still need a game owner to outlive the request.

```gdscript
extends RefCounted

func evaluate(bindings: Dictionary) -> Variant:
	return bindings.capsule.global_position
```

Bindings are decoded data and live object references, retained for the call or
bounded input operation. Their containers are mutable; source owns validity checks
such as `is_instance_valid`. Returned object references remain live handles,
not snapshots of object state.

Callbacks must return synchronously. Direct coroutine results are rejected; this
does not cancel unrelated coroutines or undo side effects. Initialization also
executes code. Neither compilation nor execution is a sandbox or a preemptible job:
a non-returning callback blocks the main thread, listener and wall-time cleanup.
Compilation/signature failures return invalid-parameter errors. Runtime faults
may log and default-return, including apparently valid results after an inner
failure; there is no general exception catcher. Invalid source can pause an
attached editor debugger under its normal break behavior.

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
Basis, Projection, Color, and Godot packed arrays. Native components must be finite
numbers within ±(2^53−1) (packed strings must be strings). PackedInt64 elements beyond
the safe JSON range are rejected rather than rounded; use an ordinary array of
BigInts instead. Callable, Signal, RID, arbitrary constructed objects, cycles,
oversized values, and invalid native encodings fail explicitly.

### Input and bounded execution

An input descriptor selects one InputMap action, key or mouse button.

| Example                                   | Meaning                                                                    |
| ----------------------------------------- | -------------------------------------------------------------------------- |
| `{action: 'move_forward', strength: 0.7}` | An existing InputMap action. Strength defaults to 1.                       |
| `{key: 'W', physical: true}`              | A physical key. Key names use logical keys by default.                     |
| `{key: 'A', ctrl: true}`                  | A key with a modifier flag. Available flags are shift, ctrl, alt and meta. |
| `{button: 'left', position: vector2}`     | Left, right or middle mouse button at an optional position.                |

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
the root viewport's `get_final_transform()` to obtain an input position.
Physical desktop coordinates and OS cursor movement are separate; no automatic
monitor/DPI conversion is supplied.
Mouse button events default to the same synthetic position. Motion carries the
current button mask, so a held button can be dragged.

`scroll` takes signed `vertical` and/or `horizontal` wheel factors in -100..100
(at least one nonzero). Positive means down/right. Optional `position` uses the
same main-window event coordinates as mouse movement. Each nonzero axis delivers
a native wheel-button press/release pair with `factor = abs(amount)`; this is not a
pixel-distance or touchpad-pan contract. The receiving control determines scroll
distance. It preserves independently held buttons, shares Input writer ownership,
and refuses during an active scheduled input operation. It does not move the OS cursor.
The JS convenience is `input.scroll({vertical: 1, position})`.

`move_mouse_to` takes a finite Vector2 destination and 1–60000ms duration. It uses
linear wall-time interpolation inside Godot, once per process callback, with a final
exact-destination event. Origin is optional `from`, otherwise the synthetic position
above. It works for paused UI, shares Input ownership and cancellation, and preserves
separately held buttons. The runtime allows duration+1000ms wall budget; a stall
beyond that fails rather than claiming arrival. Sample count depends on frame rate.
No RPC is needed for intermediate positions.

On macOS, motion/position events reach `_input` and GUI hit testing, while the main
viewport's `get_mouse_position()` still uses DisplayServer's OS pointer. The addon
does not warp that pointer. `absolute_cursor_polling:false` and
`physical_cursor_moved:false` communicate this limitation. Scripts that poll cursor position
need game-side support for synthetic positions. Secondary-window routing is not implemented.

Scheduled input operations return `{action,status:"accepted"}` and later publish one
`completed` event containing action identity, terminal status, reason, wall time,
applied physics ticks, simulation seconds, release status, and final Input state. Mouse results also
include position, duration, and sample count. Terminal reasons are:
`sequence_exhausted`, `destination_events_delivered`, `requested`,
`connection_closed`, and `wall_time_budget`. They describe execution, not gameplay
success. `status` retains the active action and latest terminal result only.
Disconnect cancels active work and releases all connection-owned holds. The client
rejects waiting promises when the connection or endpoint disappears; it does not
pretend to know an unreceived terminal outcome.

### Conditional input

With both Script and Input selected, `hold_until` accepts `source`, optional
`bindings`, `hold` (1–256 existing input descriptors), a positive finite
`max_simulation_seconds`, optional `response:{ticks,events}`, and optional
`max_wall_ms` (1–60000, default 10000). Source uses the same evaluator as Script,
but each call must return `{matched:bool,value:Variant}`. Nothing coerces truthiness.

Preparation and input validation precede acceptance and pressing. Input reserves
its existing writer for the whole accepted action, refusing independently held
matching inputs. The first unpaused callback evaluates before pressing: an
immediate match never presses the initial inputs. Otherwise those inputs remain
held until the predicate matches, its simulation limit is reached, or work ends.

Evaluation runs at Input's pre-gameplay physics priority (-10000), seeing the
previous movement result before ordinary default-priority game callbacks. This
is not post-animation/IK or continuous threshold detection. Simulation time is
counted at the boundary following each issued interval, including an interval
just before a pause. While paused, no new interval or predicate evaluation runs.
A match wins at the first boundary reaching/exceeding the simulation limit;
otherwise false ends normally. A nonintegral bound can overshoot by one interval.

On match, initial owned holds release before response offset-zero events at that
same boundary. The optional response uses existing finite sequence rules and
retains the same action identity. Completion waits for its requested intervals,
then releases its holds. The simulation limit covers only waiting/holding;
the independent wall budget covers the whole action, including response and pause.
Wall expiry suppresses response even after a slow callback returns true.

The usual accepted/completed, status and cancellation interface applies. Reasons:
`condition_matched`, `simulation_time_limit` (both completed), `predicate_failed`
or `unsupported_result` (failed), plus existing wall/disconnect/cancel reasons.
Normal completion is not assertion or gameplay success.

Terminal results add `condition:{matched,value,clock,phase,simulation_seconds}`
(null if never evaluated), `response_started`, and `response_ticks`. Condition
phase is `physics_before`; the ordinary clock keeps its coarse physics/process
phase. The latest observation is retained through response/cancellation, with
container values captured at evaluation time. If value encoding fails or the
completion event exceeds the message limit, completion instead reports
`unsupported_result`, an `error:{code,message}`, and condition metadata without
the unrepresentable value.

`response_started` means the response phase was entered, not that it finished.
Overall completion tick/time and Input state are distinct from the condition's
sample clock/time.

The JS helpers are `input.startHoldUntil(params)` (accepted action plus finished
promise/cancel/status) and `input.holdUntil(params)` (wait for completion).
[`gdPredicate`](../client/README.md#gdscript-predicates) optionally generates source;
raw source and the same wire operations are available to any language.

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
no-render capture returns unavailable. The root window is the default viewport.

Small captures return a PNG in `base64` alongside metadata. A PNG over 5 MiB
returns the same metadata with `byte_length` in place of `base64`. Call
`capture_chunk({capture, offset})` starting at offset 0, decode each chunk's
`base64` separately, and continue at its `next_offset` until `byte_length`.
Stagehand keeps the latest large capture per connection until its final chunk
is read or the connection closes. A PNG over 32 MiB returns a resource-limit
error. The JS `screen.capture()` helper returns the complete PNG as a Buffer in
both cases.

Limits: 8 connections, 5s authentication deadline, 8MiB inbound/outbound messages,
64 requests per batch, 64 WebSocket frames parsed per peer per engine frame, 128 subscriptions per
connection, value depth 16, collections/native argument arrays of 1024 entries.
Tree queries stop at 10000 visited nodes and return at most 1000 matches. The
viewport list stops at 100 entries. These bounds do not make arbitrary reflected
calls cheap. Screenshots and expensive getters can block a frame.

Event delivery/backpressure failure closes the connection (1011). Obtain fresh
observations after reconnecting; there is no replay or durable event history.

Errors: JSON-RPC `-32700` parse, `-32600` invalid request, `-32601` unknown method,
`-32602` invalid params; addon `-32001` auth, `-32002` version, `-32004` stale/unknown
handle or action, `-32010` unsupported value/resource limit, `-32020` no rendered
image, `-32030` Input conflict. Empty/nested/oversized batches are rejected.
Notifications have no response. Batches have no portable ordering/atomicity promise;
use a bounded Input operation for timed ordering. Request timeout is uncertainty,
not cancellation.
