# GMUX

It is 2026, and we are still managing AI agents like it is the MS-DOS era: terminals, commands, logs, and fragmented sessions.

GMUX is the transition to a GUI.

GMUX is a graphical control layer for AI agents. Instead of juggling CLI panes, users can see, control, and coordinate many agents in one live visual workspace. Agents become visible entities: you can assign tasks, monitor progress, spot blocked work, and see when jobs are complete.

The goal is simple: make multi-agent work visual, scalable, and accessible for both technical and non-technical users.

## What Problem Does It Solve?

CLI-based agent control creates cognitive strain. It is hard to track what every agent is doing, which ones are idle, which ones are blocked, and which tasks are finished.

GMUX replaces terminal-heavy orchestration with a visual interface that makes agent state clear at a glance. It turns managing agents from a text-heavy technical workflow into a simple, human-friendly experience.

## Why Now?

AI agents are becoming parallel workers, but the way we control them is still stuck in terminal workflows. That does not scale when users are managing many agents at once.

Just like Windows made computers easier to use after MS-DOS, GMUX makes agent orchestration easier after CLI-first tools.

## Setup

```bash
./scripts/setup.sh
./scripts/reload.sh --tag cmux-gui --launch
```
