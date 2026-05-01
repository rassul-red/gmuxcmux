# GMUX

![GMUX preview](https://github.com/user-attachments/assets/69a4215b-caf3-40e3-85be-d0b6f34df7de)

GMUX is a visual control layer for AI agents.

Instead of managing agent work through scattered terminals, logs, and shell commands, GMUX gives you one live workspace where agents can be seen, monitored, and directed. It is built for the next stage of AI-assisted work: many agents running in parallel, each with its own task, state, and context.

## Why GMUX Exists

AI agents are becoming parallel workers, but most agent workflows still look like the MS-DOS era: terminal panes, command history, scrollback, and manual tracking.

That works for one or two agents. It breaks down when you are coordinating many of them.

GMUX makes agent orchestration visual. You can see which agents are running, which are blocked, which are waiting for input, and which jobs are complete without hunting through terminal output.

## What It Helps With

- Monitor many agent sessions in one place.
- Spot blocked or idle agents quickly.
- Track progress across projects and workspaces.
- Reduce the cognitive load of terminal-heavy workflows.
- Make multi-agent work easier for technical and non-technical users.

## Project Direction

The goal is to move from CLI-first agent control to a graphical environment where agents feel like visible collaborators instead of hidden background processes.

GMUX is not just a terminal wrapper. It is an experiment in making multi-agent work more understandable, scalable, and accessible through a live GUI.

## Setup

```bash
./scripts/setup.sh
./scripts/reload.sh --tag cmux-gui --launch
```

## License

This repository follows the license included in [`LICENSE`](LICENSE). The upstream code is dual-licensed by Manaflow, Inc. under GPL-3.0-or-later for open source use and a commercial license for organizations that need different terms.

## Fork Notice

This project is a fork of the original cmux repository by Manaflow, Inc. Original copyright and license notices are preserved.
