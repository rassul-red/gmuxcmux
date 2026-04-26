# Project Memory

This file captures non-obvious project context that is useful for future agent sessions. Keep it tight and update entries when they become stale.

## cmux

cmux is a macOS terminal/workspace app built in Swift/SwiftUI with Ghostty integration. The project includes:

- `Sources/` for the main macOS app.
- `Packages/` for local Swift packages.
- `CLI/` and `daemon/` for command-line and daemon pieces.
- `ghostty/` and `vendor/` submodules.
- `Resources/Localizable.xcstrings` for localized UI strings.
- `tests/`, `tests_v2/`, `cmuxTests/`, and `cmuxUITests/` for test coverage run mainly through CI or VM workflows.

Use the root agent guide through `AGENTS.md` (symlinked to `CLAUDE.md`) for build, reload, testing, localization, snapshot-boundary, socket, and submodule rules.

## cmux-gui mode

`cmux-gui` is an alternate DEBUG presentation mode for cmux, toggled from the Debug menu with "Enable/Disable Agents Canvas". It replaces the standard terminal grid with a living agents world where each workspace is a room and each terminal panel is a ghost agent.

Purpose: provide a game-like surface for monitoring many workspaces at once. `running` and `asking` agents sit at desks; `thinking` and `completed` agents wander. The intended feel is alive, not a static dashboard.

Implementation notes:

- Treat the canvas as a separate UI surface, not a terminal-core refactor target.
- World and walk state lives in `AgentWorldStore`, which is the single source of truth and is ticked from a `Timer.publish`.
- Row subviews should remain snapshot-only per the snapshot-boundary rule in `CLAUDE.md`.
- Sprites live under `Assets.xcassets/AgentWorkers/` for standing sprites and `Assets.xcassets/AgentOffice/` for desk-composed sprites and props.
- Status mapping is `running` / `asking` to at-desk seated sprites, and `thinking` / `completed` to standing/wandering sprites.
- v2 layout is one horizontal `ScrollView` of `720x480` rooms with no four-room cap.
- Zoom uses `MagnificationGesture`, clamped to `0.5x` through `2.5x`.
- The walk cycle is faked with horizontal mirroring and a 4 Hz jiggle because no walk-frame assets exist.
