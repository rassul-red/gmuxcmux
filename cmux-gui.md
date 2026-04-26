# cmux-gui

A game-like alternate presentation mode for cmux. Replaces the standard terminal grid with a "living agents world" where each workspace is a room and each terminal panel is a pixel-art ghost agent. Toggled in DEBUG builds via **Debug menu → Enable/Disable Agents Canvas**.

## Why this exists

cmux users routinely run many workspaces at once, each with multiple terminal panels. The default grid surface answers "what's on screen right now?" but not "what's happening across all my work?". The agents canvas is a glanceable secondary surface: agents wander when idle, sit at desks when commands are running, and emit a chime + DONE bubble when commands finish. The goal is a calm, ambient overview that feels alive rather than a static dashboard.

## Mental model

| cmux concept | Canvas representation |
|---|---|
| Workspace | A room (720×480 pt rectangle of office scenery) |
| Terminal panel | A ghost agent inside that workspace's room |
| Panel role (user-assigned) | Sprite variant (Builder / Debugger / Orchestrator / Reviewer) |
| Panel shell activity | Pose (wandering vs. seated at a chair) |
| Notification on a panel | Green halo + DONE bubble + chime |

The "world" is a horizontal row of rooms inside one big scrollable + zoomable view. Every workspace gets its own room.

## Status model

Each agent's pose is derived per-tick from the workspace + panel state:

```
hasNotification(workspace, panel)              → .completed   (halo + DONE)
panelShellActivityState(panel) == .commandRunning → .running   (sit at desk)
otherwise                                      → .thinking   (wander)
```

`asking` is also part of the enum and maps to seated; it's reserved for future "agent is waiting on a question" wiring.

Important: bare keyboard focus does **not** put an agent at a desk. A freshly-opened terminal sitting at a prompt is `.promptIdle` → wanders. Only a real running command (`.commandRunning`) sits the ghost down.

## Architecture

### Single source of truth: `AgentWorldStore`

`AgentWorldStore` (a `@MainActor ObservableObject` singleton) owns every ghost's `(position, target, facingLeft, arrived, nextWanderAt)` in room-local coordinates. It exposes one entry point:

```swift
worldStore.tick(now: Date, drivers: [AgentWorldDriver])
```

`AgentsCanvasView` subscribes to a `Timer.publish(every: 1/30, on: .main, in: .common)` and calls `tick(...)` on each fire. The store advances every position toward its target by `min(distance, 30 pt/s × dt)`, snaps on arrival, picks a new wander target every 4–8 s when idle, and updates `facingLeft` from the velocity sign.

State writes happen **only** inside `tick(...)`. Never inside a SwiftUI `body`. This is required by the project's "no state mutation in view-body computations" rule (see `CLAUDE.md`).

### Snapshot boundary

`AgentsCanvasRoomView` and `AgentAvatarView` are `Equatable` value-snapshot views. They never hold an `ObservableObject` reference. Each render, `AgentsCanvasView` reads `worldStore.statesByPanelId` and builds plain-value snapshots (`AgentsCanvasRoomSnapshot`, `AgentsCanvasAgentSnapshot`) that flow down. This keeps `LazyLayoutViewCache` from thrashing on unrelated `@Published` changes — the same class of bug that took down the Sessions panel and the workspace sidebar (issue #2586).

### Animation layering

| Layer | Driven by |
|---|---|
| World position (where the ghost is in its room) | `AgentWorldStore.tick` from `Timer.publish` |
| Idle bob / pulse / walk jiggle / DONE bubble timing | `TimelineView(.animation)` inside `AgentAvatarView` |
| Pinch zoom / scroll pan | `MagnificationGesture` + `ScrollView` |

The store handles "where", the timeline view handles "looks alive". Mixing them would put state writes inside view bodies.

## Room layout

Every room shares the same fixed office layout (defined as a static `[AgentRoomDecoration]` literal in `AgentsCanvasView.roomFurniture`):

- **Top wall:** bookshelf, wall task board, server rack
- **Top desk row (y ≈ 130):** two desk stations, each = `desk + monitor + lamp + keyboard + coffee mug + chair`
- **Mid desk row (y ≈ 240):** two more identical desk stations
- **Side walls:** floor lamps flanking the open central floor
- **Bottom strip (y ≈ 430):** storage cabinet, side tables, potted plants

Four fixed chair slots (`chairSlots[0..3]`) line up with the four desk stations. Panels are assigned `chairSlots[panelIndex % 4]`; with 5+ panels, slots are reused.

The wander zone is a tightly clamped strip in the middle of the floor (~`x ∈ [80, 640]`, `y ∈ [320, 410]`) so wandering ghosts don't clip into furniture. Walking from a mid-row chair down to the floor still passes through the mid desks visually — known limitation, no real pathfinding.

## Sprite system

All sprites are pixel-art `.imageset`s under `Assets.xcassets/`:

| Asset prefix | Purpose | Frame |
|---|---|---|
| `AgentWorkers/AgentWorker{Role}{State}` | Standing ghost (wandering) | 64 pt |
| `AgentWorkers/AgentWorkerSeated{Role}{State}` | Seated ghost on a chair, no desk | 64 pt |
| `AgentOffice/AgentDesk{Role}{State}` | Composed seated ghost + desk + monitor | 96 pt — **unused in v2**, retained as legacy |
| `AgentOffice/OfficeProp*` | Room furniture (desk, monitor, lamp, mug, plant, etc.) | per-kind sizes |

`Role ∈ { Builder, Debugger, Orchestrator, Reviewer }`. `State ∈ { Idle, Working, Attention }`. `AgentRole` exposes both `assetPrefix` (e.g. `AgentWorkerBuilder`) and `assetCoreName` (e.g. `Builder`) helpers.

When seated, the avatar uses `AgentWorkerSeated{Role}{State}` placed on top of the room's pre-existing chair sprite. Earlier iterations used the composed `AgentDesk*` sprite — that made the agent look like it transformed into a desk and was abandoned.

## Walk cycle

There are no multi-frame walk imagesets. "Walking" is faked with two cheap effects applied to the standing sprite:

- `scaleEffect(x: -1)` mirror when `facingLeft` is true
- 4 Hz vertical sine jiggle, ±2 pt, only while actively moving

Idle bob (1.5–2 Hz, ±3 pt) plays when standing-still-not-walking. Both are suppressed when seated.

## World canvas (zoom + pan)

The HStack of rooms lives inside a `ScrollView([.horizontal, .vertical], showsIndicators: false)`. Zoom uses `MagnificationGesture` clamped to `0.5×–2.5×`, with `baseZoom` captured on `.onEnded` so successive pinches compose. The inner content gets `.scaleEffect(zoom, anchor: .topLeading)` and the outer frame is sized `contentWidth * zoom × contentHeight * zoom` so the scrollable region grows/shrinks with the zoom level.

A floating zoom HUD anchored bottom-right has `−` / `+` / `⌘0` reset buttons and a live `XXX%` label.

## File map

| File | Role |
|---|---|
| `Sources/AgentsCanvasView.swift` | Top-level world view. Owns timer subscription, builds room/agent snapshots, holds the static `roomFurniture` layout + `chairSlots`, defines the wander zone, derives `AgentStatus` per panel, hosts the zoom HUD |
| `Sources/AgentsCanvasRoomView.swift` | One room. Renders tinted floor + rug + decorations + agents at their `worldPosition`. Pure snapshot view, `Equatable` |
| `Sources/AgentAvatarView.swift` | One ghost. Picks standing vs. seated sprite, applies bob / pulse / walk-jiggle, renders halo + thought bubble + DONE bubble + role context menu. Pure snapshot view, `Equatable` |
| `Sources/AgentWorldStore.swift` | World state singleton. Per-panel position + walk target + arrival flags. `tick(...)` is the only mutating entry point |
| `Sources/AgentRole.swift` | `enum AgentRole` + `assetPrefix` / `assetCoreName` / `bouncePeriod` / `localizedName` helpers |
| `Sources/AgentStatus.swift` | `enum AgentStatus`, sprite-variant mapping, aura color, overlay glyph, `isAtDeskStatus` |
| `Sources/AgentRoleStore.swift` | Persists per-panel role assignments |
| `Sources/Workspace.swift` | Source of `panelShellActivityState(forPanelId:) -> PanelShellActivityState` (`.unknown` / `.promptIdle` / `.commandRunning`) — drives the wander-vs-sit decision |
| `Sources/TerminalNotificationStore.swift` | Source of `hasVisibleNotificationIndicator(forTabId:surfaceId:)` — drives the `.completed` halo |
| `Assets.xcassets/AgentWorkers/` | Standing + seated ghost sprites (4 roles × 3 states × 2 poses) |
| `Assets.xcassets/AgentOffice/` | Furniture / decoration sprites and the legacy composed desk sprites |
| `Resources/Localizable.xcstrings` | Zoom HUD strings, role labels, DONE bubble copy (en + ja) |

## Building

Always build through `reload.sh` with a tag. Never run a bare `xcodebuild` or `open` an untagged `cmux DEV.app` — it conflicts with whichever debug instance the user is already running.

```bash
./scripts/reload.sh --tag cmux-gui          # build only; prints app path
./scripts/reload.sh --tag cmux-gui --launch # build and open
```

Toggle the canvas in the running app via **Debug → Enable Agents Canvas**.

## Manual test plan

1. Open a workspace, don't run anything → ghost wanders the central floor strip; never sits.
2. Run a long-running command (`yes | head -1000000`) → ghost walks to a chair and switches to the seated sprite. Ctrl+C → ghost stands and resumes wandering.
3. Trigger a notification → green halo + DONE bubble + Glass chime; halo persists until cleared.
4. Split the workspace 4 ways and run a command in each → each ghost picks a different chair (slots 0/1/2/3 by `panelIndex % 4`).
5. Pinch trackpad → zoom 0.5×–2.5× clamped; HUD `−` / `+` / `⌘0` works; two-finger drag pans both axes.
6. Open 6+ workspaces → world is smooth at 30 fps, idle CPU < 5%.
7. Focus a terminal in the right rail with the canvas visible; hold a key → keystrokes remain instant.
8. Disable canvas → original layout returns clean. Re-enable → ghosts respawn from initial positions, not stuck at old desk slots.

## Known limitations

- No real pathfinding: walking from a chair to the floor passes straight through other desks.
- No multi-frame walk-cycle assets. The 4 Hz jiggle is a placeholder.
- Furniture layout and wander zone are hard-coded constants. Editing one without the other will leave ghosts clipping into props or stranded outside the floor.
- Per-panel shell activity comes from cmux's existing prompt-idle / command-running detector. If that detector misfires (some shells, some prompts), the agent will wander when it should sit.
- Role assignment is per-panel manual via right-click. There's no automatic role inference.

## Out of scope (future work)

- Multi-frame walk-cycle animation
- Obstacle-aware path planning around desks
- Drag-to-rearrange rooms in the world
- "Camera follows focused agent" auto-pan
- Day/night lighting cycle
- Per-room custom decoration picker
- Shared open-plan mode with no per-workspace dividers
- Keyboard shortcuts for zoom (`⌘0` / `⌘+` / `⌘-`)
