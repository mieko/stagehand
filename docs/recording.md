# Property recording

Select `PropertyRecorder` to capture readings inside Godot for later inspection or plotting.
Client polling does not determine the sampling resolution.
It is a developer tool: property getters and method reads can execute game code.
See [security](security.md) before exposing it to clients.

## Capture and retrieve

Choose actual objects using SceneTree or your game's registered operations:

```js
const recorder = await game.root('PropertyRecorder');
const tree = await game.root('SceneTree');
const body = (await tree.query({class: 'CharacterBody3D'})).nodes[0].node;

await recorder.start({
  tracks: [
    {object: body, property: 'global_position', label: 'position'},
    {object: body, property: 'velocity', label: 'velocity'},
  ],
  phase: 'physics', every_n: 2, max_samples: 600, max_seconds: 15,
});
// Exercise the game, then stop. Limits can also stop capture automatically.
const status = await recorder.stop();

let offset = 0;
const samples = [];
do {
  const page = await recorder.read({offset});
  samples.push(...page.samples);
  offset = page.next_offset;
} while (offset < status.count);

await recorder.discard();
```

Each row contains `index`, `elapsed_usec`, `physics_frame`, `process_frame`,
`callback_index`, and `values` in track order. `status.started_usec + elapsed_usec`
is a monotonic engine timestamp. Native vectors/transforms use the ordinary value
codec (`GodotValue` in JS). All tracks are read sequentially at the same callback;
this is not atomic sampling across getters with side effects.

One capture is shared by clients of the bridge. Disconnecting does not stop it.
Stopped samples remain retrievable until discard or endpoint destruction. Starting
another requires discard; history is never silently overwritten. `stop()` is
idempotent and takes no final sample. `read()` during capture returns its available
prefix. Subscribe to `recorder.subscribe('stopped', listener)` before starting if
waiting for an automatic stop; `observe()` returns status under `value`.

## Readings

Each track chooses exactly one selector; `label` is optional. The same spec works
with `recorder.inspect(spec)`, returning `{value, access}` without starting capture.

| Selector | Meaning |
| --- | --- |
| `{object, property: 'global_position'}` | Native property read, including nullable properties. |
| `{object, indexed: 'global_transform:origin'}` | Godot `get_indexed`, using a cached property path. No node traversal or custom expression parser. Null leaves are rejected because Godot cannot distinguish missing paths from legitimate null values. |
| `{object, method: 'get_bone_global_pose', args: [index]}` | Bound synchronous getter; arguments default to `[]`. The pose is skeleton-relative. |
| `{source, bindings, label}` | A scripted reading, available when Script is selected too. |

Names and property paths are bound once, up to 128 characters. Method argument
data is snapshotted and reused; it cannot contain live objects. Reflection validates
known signatures, not domain constraints such as bone-index validity. Typed container
parameters require matching native types; the wire codec does not preserve typed
Array/Dictionary declarations. No contents-based type coercion is performed.

For AnimationTree, read `parameters/...` on the actual tree instance, not its
shared AnimationNode resource. Dynamic owners must call
`notify_property_list_changed()` when their properties change. Property/script
changes invalidate native bindings; lost targets stop capture visibly.

Script readings use the same [GDScript evaluator](../addons/stagehand/api.md#runtime-gdscript):

```js
const source = `extends RefCounted

func evaluate(bindings: Dictionary) -> float:
    return bindings.body.velocity.length()
`;
await recorder.start({
  tracks: [{source, bindings: {body}, label: 'speed'}],
  phase: 'physics', max_samples: 600,
});
```

Each evaluator is compiled and instantiated once per track. Admission evaluates
each reading once to report its initial type; subsequent evaluations
run only on selected callbacks. Script tracks keep ordinary mutable bindings and
own validity checks such as `is_instance_valid`. Recorder-owned evaluator/binding
references are released when capture stops; source can retain references elsewhere.
Status retains labels/type metadata, not script
source or bindings. No expression language or separate script runner is involved.

Readings should be synchronous and observational. The recorder cannot infer purity,
catch arbitrary GDScript VM faults, or preempt a blocked getter/script. A getter
that stops or replaces capture cannot append its interrupted row to either capture.

## Sampling and limits

| Option | Behavior |
| --- | --- |
| `phase: 'physics'` (default) | Late physics callback, priority 2147483647. Follows lower-priority callbacks in the same main-thread group, not a physics-server completion barrier. |
| `phase: 'process'` | Late process callback at the same priority. Does not guarantee animation/IK completion or ordering across thread groups. |
| `phase: 'signal', source, signal` | Sample synchronously on an existing zero-argument signal. Use `skeleton_updated` for completed Skeleton3D modifications. |
| `every_n` | Callbacks 0, N, 2N, etc.; default 1, range 1–10000. Skipped callbacks invoke no readings. |
| `max_samples` | Default 3600, range 1–10000; 1–32 tracks. |
| `max_seconds` | Default 60, range 0.001–600; monotonic wall time, monitored while paused. |
| Data budget | 16 MiB conservatively charged against wire size; at most 64 KiB per row. Preallocated storage overhead is additional. |
| `read({offset, limit})` | Defaults 0/32; at most 32 rows, keeping pages below the transport message limit. |

Callbacks continue while paused and may sample unchanged game state. Signal sources
must emit on Godot's main thread.

Mutable arrays, dictionaries and packed arrays are copied at capture time. Samples
cannot contain Objects, Callables, Signals, RIDs or cyclic containers. Native target
and signal references are weak. Script bindings follow normal GDScript ownership.

Status reports counts, limits, track metadata, timestamps, error details and an
explicit stop reason: requested, sample/duration/byte limit, oversized sample,
lost source, track/value error, or endpoint removal. Failed rows are omitted;
the preceding complete rows remain available. A blocked Godot main thread also blocks
the duration monitor.

## Capture cost

Capture preallocates native value columns and shared clock columns. Common scalar,
vector and transform samples build no row dictionaries or JSON. Retrieval builds
and encodes pages separately. Container snapshots, string size accounting, getters
and scripts can allocate. `status.bytes` is a conservative wire charge, not measured
RAM usage. Nothing samples or serializes per frame outside active capture.

Coordinate conversion, bone interpretation and other game-specific observables
belong to game systems or explicitly supplied scripts, not recorder policy.
