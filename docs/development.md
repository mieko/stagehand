# Development and compatibility

The addon is pure GDScript. The integration runner is external Node 22+ code;
it stages a temporary copy of the standalone fixture and addon, uses an ephemeral
port/private token, and cleans its own process, files and macOS user directory.
It never launches a consuming game's main project. Rendered fixture windows are
offscreen and do not take focus; synthetic events do not warp the OS pointer.

## Run the checks

Choose the Godot executable explicitly if `godot` is not on PATH:

```sh
STAGEHAND_GODOT=/path/to/Godot npm test
```

Headless runs skip the rendered-pixel assertion. To check an exported release,
supply an editor and matching release-template executable:

```sh
STAGEHAND_GODOT=/path/to/Godot \
STAGEHAND_RELEASE=/path/to/release-template \
STAGEHAND_GRAPHICAL=1 npm test
```

The runner exports a fixture PCK, copies the template beside it and runs it without
an editor/debugger connection. Image checks decode actual PNGs
and inspect known colors before/after real fixture input. The other checks cover
RPC correlation, references/types/errors, ready subscriptions, input ownership,
holds/sequences/mouse movement, cancellation/disconnection and addon removal.
Test files run serially because Godot exports share a temporary `project.binary`
filename; parallel exporters can corrupt one another's output.
Network tests also verify the loopback default and opt-in interface/wildcard
listeners through a non-loopback local IPv4 address, including authentication and
ordinary RPCs. These checks skip explicitly if no such interface is available;
they do not require a second machine or change firewall settings.

`STAGEHAND_REQUIRE_NON_DOTNET=1` additionally verifies that the selected engine has
no C# support.

`STAGEHAND_KEEP_FIXTURE=1` retains staged files/logs for diagnosis. The test
suite uses temporary projects; do not point tests at an active game's state.
Use `node --check` for edited JavaScript. Use [GDQuest’s GDScript Formatter](https://github.com/GDQuest/GDScript-formatter)
for GDScript formatting and linting (`gdscript-formatter --verify-structure` and
`gdscript-formatter lint`). The repository's `.editorconfig` sets a 100-column
target for code. Style checks are distinct from Godot runtime checks.

## Compatibility and limits

Runtime/release behavior has been checked on macOS arm64 with Godot
4.8 master build (`960f4db5be16e2f1f7b46f9db7c824c2e0af1035`). Headless Godot
4.5.2 was checked too; a separate consumer uses shipping MegaDot 4.5.1. These are
concrete tested builds, not a promise about every engine/platform combination.
No installed editor/templates are changed by the tests.

Release reflection metadata may omit native argument details. Generic calls expose
what the engine retains; they do not guarantee semantic success. Screenshots need
a rendered viewport, and image readback/PNG encoding can block the main thread.
Injected mouse events are distinct from OS cursor polling. Captured mouse gameplay,
DPI/scaled or secondary windows, IME, gamepad/touch and non-macOS exports need
further qualification. Pause/step and replay are not implemented.
