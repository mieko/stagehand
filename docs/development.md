# Development and compatibility

The addon is pure GDScript. The integration runner is external Node 22+ code;
it stages a temporary copy of the standalone fixture and addon, uses an ephemeral
port/private token, and cleans its own process, files and macOS user directory.
It never launches a consuming game's main project. Tests run headless by default.
Rendered fixture windows are offscreen, but launching Godot graphically can
still activate the app and take keyboard focus on macOS.

Tests import the client from the checkout. A focused transport check downloads
the served module and connects with it to verify distribution.

## Run the checks

Choose the Godot executable explicitly if `godot` is not on PATH:

```sh
STAGEHAND_GODOT=/path/to/Godot npm test
```

Headless runs skip the rendered-pixel assertion. To check an exported release,
supply an editor and matching release-template executable:

```sh
STAGEHAND_GODOT=/path/to/Godot \
STAGEHAND_RELEASE=/path/to/release-template npm test
```

Recorder memory measurements require an engine exposing static-memory counters;
release engines without them report that measurement as unavailable. Capture,
encoding, lifecycle and retrieval checks still run.

The runner exports a fixture PCK, copies the template beside it and runs it without
the project source or an editor/debugger connection. Set `STAGEHAND_GRAPHICAL=1`
when you want rendered checks and the desktop is available. These checks decode PNGs and inspect fixture
colors before and after input. Test files run serially because parallel Godot
exports can overwrite shared temporary output.

Network checks use a non-loopback local IPv4 address and skip explicitly if none
is available. They need no second machine or firewall changes.

`STAGEHAND_REQUIRE_NON_DOTNET=1` additionally verifies that the selected engine has
no C# support.

`STAGEHAND_KEEP_FIXTURE=1` retains staged files/logs for diagnosis. The test
suite uses temporary projects; do not point tests at an active game's state.

The fixtures run without an attached editor debugger. When using Stagehand from
an editor, invalid dynamic source can pause it under normal break-on-error behavior.
See [runtime GDScript](protocol.md#runtime-gdscript) for execution limits.

Use `node --check` for edited JavaScript. Use [GDQuest’s GDScript Formatter](https://github.com/GDQuest/GDScript-formatter)
for GDScript formatting and linting (`gdscript-formatter --verify-structure` and
`gdscript-formatter lint`). The repository's `.editorconfig` sets a 100-column
target for code. Style checks are distinct from Godot runtime checks.

## Compatibility and limits

The addon selects its JSON value codec and signal adapter at startup. Godot 4.3
uses compatibility scripts for native value conversion and variable-arity
signals. Modern engines use the native implementations when available. Run the
fixture and export checks against the engine and matching template you ship.

Release builds may omit native argument metadata. Screenshots require a rendered
viewport, and image readback/PNG encoding can block the main thread. Injected mouse
events do not move the OS cursor. See [the protocol](protocol.md) for these contracts.

Graphical/export checks have focused on macOS arm64. Captured-mouse gameplay,
DPI/scaled windows and non-macOS exports need further qualification. Secondary-window
input routing, IME composition, gamepad/touch, pause/step and replay are not implemented.
