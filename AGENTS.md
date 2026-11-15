# Agent directions

Read README.md, docs/protocol.md and docs/development.md before changing contracts.
This repository owns the reusable pure-GDScript addon, generic external JS client
and standalone fixtures. Keep game-specific behavior and dependencies in consumers.
Preserve explicit runtime enablement; do not add an editor-plugin dependency.

Leave a blank line after guard returns before continuing work. Group code into
logical stanzas, separating distinct steps while keeping related statements together.
Aim for 100 columns; allow longer lines when wrapping would make the code harder to read.

Use `npm test` with a selected Godot executable. Check exported release behavior
with a standard Godot build when runtime or export contracts change. Fixtures use
isolated state; never substitute a user's running game for the standalone test project.
Test acceptance separately from completion, subscription readiness, input cleanup
and object lifetimes. Do not automatically replay uncertain mutations.

Keep documentation oriented toward use and maintenance. Plans, review packets,
checklists, private sessions/tokens, game assets and local build logs do not belong
in this repository. Commit or publish only when explicitly requested.
