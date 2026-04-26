<h1 align="center">gmuxcmux</h1>
<p align="center"><b>A GUI-first fork of <a href="https://github.com/manaflow-ai/cmux">cmux</a> — workspaces are rooms, terminal panels are wandering ghosts.</b></p>

<p align="center">
  English | <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/badge/upstream-manaflow--ai%2Fcmux-555?logo=github" alt="Upstream cmux" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-blue" alt="License" /></a>
</p>

---

## Why GUI-first?

cmux is already a beautiful terminal — vertical tabs, notifications, splits, an in-app browser, GPU-accelerated rendering through libghostty. But the moment you run *many* agents in parallel, the answer to "what is happening right now?" is still **a wall of text inside a wall of tabs**. You read tab titles to figure out who needs you.

gmuxcmux flips that. The terminal grid stops being the only first-class surface. The new primary surface is a **living world** where every workspace is a room and every terminal panel is a pixel-art ghost. You glance, you don't read. At one look you can see who is busy at a desk, who is wandering the floor, and who just finished — across every workspace at once.

> **Terminal-first asks:** _What is on this pane?_
>
> **GUI-first asks:** _What is happening across all of my work?_

Both questions still matter. cmux answers the first one beautifully. gmuxcmux adds a calm, ambient surface that answers the second one — without taking the terminal away.

---

## The mental model

| cmux concept              | gmuxcmux representation                                       |
|---|---|
| Workspace                 | A **room** (720×480 pt office scenery)                        |
| Terminal panel            | A **ghost agent** standing inside that room                   |
| Panel role (user-set)     | Sprite variant: Builder · Debugger · Orchestrator · Reviewer  |
| Shell is running a command| Ghost **walks to a desk and sits down**                       |
| Shell is idle at a prompt | Ghost **wanders the floor**                                   |
| Notification fires        | Green **halo + DONE bubble + chime**                          |

Every state is derived from cmux's existing prompt-idle / command-running detector and OSC 9/99/777 notifications. There is **no new shell instrumentation, no agent-side configuration**. If your shell already shows up correctly in cmux, it shows up correctly here.

---

## Two GUI surfaces, one source of truth

gmuxcmux does not replace the terminal. It adds two GUI surfaces alongside it:

1. **Agents Panel** — a compact map in the right sidebar, always available. Each workspace is a labeled room, each panel is a clickable agent box. Tap to focus that terminal. Safe in Release builds.
2. **Agents Canvas** — the full game-like world. Pinch to zoom (0.5×–2.5×), two-finger to pan, ghosts walk to chairs and back, halos pulse, the Glass chime plays when an agent finishes. DEBUG-only, toggled in **Debug → Enable Agents Canvas**.

Both surfaces read from the same status feed as the terminal grid. There is no separate "agent state" anywhere — the GUI is just a different rendering of the same truth that drives the terminal.

---

## Architecture, in one breath

- **`AgentWorldStore`** is a `@MainActor` singleton that owns every ghost's `(position, target, facingLeft, arrived)` in room-local coordinates. Its only mutation entry point is `tick(now:drivers:)`.
- A **30 fps `Timer.publish`** drives `tick`. Position interpolates at 30 pt/s, snaps on arrival, and picks a new wander target every 4–8 s when idle.
- **Snapshot boundary**: `AgentsCanvasRoomView` and `AgentAvatarView` are `Equatable` value-snapshot views. They never hold an `ObservableObject`. This is the same rule that protects cmux's Sessions panel and workspace sidebar from `LazyLayoutViewCache` thrashing — see upstream issue [manaflow-ai/cmux#2586](https://github.com/manaflow-ai/cmux/issues/2586).
- **Animation layering** is strict. World position is driven by `tick`. "Looks alive" (idle bob, walk jiggle, DONE bubble timing) lives in `TimelineView(.animation)`. State writes never happen inside view bodies.

Full design notes — sprite system, room layout, walk cycle, world canvas, manual test plan — live in [`cmux-gui.md`](./cmux-gui.md).

---

## Build and run

```bash
./scripts/setup.sh                                  # init submodules + GhosttyKit
./scripts/reload.sh --tag cmux-gui --launch         # build the DEBUG app and open it
```

Then in the running app: **Debug → Enable Agents Canvas**.

> Always pass `--tag`. Untagged `xcodebuild` or `open cmux DEV.app` will collide with any other tagged debug instance over the shared socket and bundle ID.

---

## Status

This is a personal fork. There is **no signed DMG, no Homebrew tap, no auto-update**. Build from source. The Agents Canvas is DEBUG-only by design; the Agents Panel is safe in Release.

Known limitations of the canvas:

- No real pathfinding — a ghost walking from a chair to the floor passes straight through other desks.
- No multi-frame walk animation — walking is faked with horizontal mirroring + a 4 Hz vertical jiggle.
- Furniture layout and the wander zone are hard-coded constants.
- Role assignment is per-panel manual via right-click on the agent.
- Per-panel shell activity comes from cmux's existing detector. If that detector misfires for a particular shell or prompt, the agent will wander when it should sit.

Everything in upstream cmux still works. Vertical tabs, splits, notifications, in-app browser, SSH, Claude Code Teams — all unchanged. For upstream features and full keyboard shortcuts, see the [upstream cmux README](https://github.com/manaflow-ai/cmux#readme).

---

## Credits

- Upstream terminal everything is built on: [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux).
- Forked from: [rassul-red/gmuxcmux](https://github.com/rassul-red/gmuxcmux).
- Agents Panel concept: PR #1 by [@dbekzhan](https://github.com/dbekzhan).
- Sprite system, world store, and Agents Canvas: this fork.

## License

GPL-3.0-or-later, inherited from upstream cmux. See [LICENSE](./LICENSE).
