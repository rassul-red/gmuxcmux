#!/usr/bin/env bash
set -euo pipefail

# scripts/demo/ghost-projects-walkthrough.sh
#
# Drives the AC walkthrough for Ghost Projects dashboard:
#   - Creates 4 throwaway project CWDs
#   - Launches Claude Code in each via osascript
#   - Sets CMUX_AUTO_SHOW_GHOST=1 so the next cmux launch auto-opens the dashboard
#   - 'tail' subcommand: writes /tmp/gmux-demo/transcripts/<project>.tail.jsonl
#
# Usage:
#   ghost-projects-walkthrough.sh            # full walkthrough
#   ghost-projects-walkthrough.sh tail       # capture transcripts only

PROJECTS=(web api infra docs)
ROOT=/tmp/gmux-demo
TRANSCRIPTS_DIR="$ROOT/transcripts"

cmd="${1:-run}"

case "$cmd" in
  run)
    for project in "${PROJECTS[@]}"; do
      dir="$ROOT/$project"
      mkdir -p "$dir"
      if [[ ! -f "$dir/README.md" ]]; then
        printf '# gmux-demo: %s\n' "$project" > "$dir/README.md"
      fi
    done

    # Launch Claude Code in each CWD via Terminal.app
    for project in "${PROJECTS[@]}"; do
      dir="$ROOT/$project"
      escaped_dir=$(printf '%s' "$dir" | sed 's/[\\"]/\\&/g')
      osascript -e "tell application \"Terminal\" to do script \"cd \\\"$escaped_dir\\\" && claude\""
    done

    cat <<'EOF'
=======================================================
NEXT STEPS (perform while recording):
  1. Set CMUX_AUTO_SHOW_GHOST=1, then launch the cmux DEV build:
       CMUX_AUTO_SHOW_GHOST=1 open "/Users/<you>/Library/Developer/Xcode/DerivedData/cmux-<tag>/Build/Products/Debug/cmux DEV <tag>.app"
     Or click View > Ghost Projects Dashboard from the menubar.
  2. Verify each project room appears in the 2x2 grid.
  3. Wait for ghost activity (tool_use events update ghost state within 5s).
  4. Select the 'web' project -> click New Task -> enter a prompt -> ghost should turn Coding (green pulse).
  5. Click Interrupt -> ghost should return to Idle (blue).
  6. Run: scripts/demo/ghost-projects-walkthrough.sh tail
     (writes /tmp/gmux-demo/transcripts/<project>.tail.jsonl as proof).
=======================================================
EOF
    ;;

  tail)
    mkdir -p "$TRANSCRIPTS_DIR"
    # Heuristic: Claude Code transcripts live under ~/.claude/projects/*.
    # If ClaudeTranscriptWatcher.swift uses a different root, adjust below.
    # Use `find` (BSD-portable) instead of bash 4 globstar — macOS ships 3.2.
    base="$HOME/.claude/projects"
    for project in "${PROJECTS[@]}"; do
      dir="$ROOT/$project"
      out="$TRANSCRIPTS_DIR/$project.tail.jsonl"
      latest=""
      if [[ -d "$base" ]]; then
        # find -print0 | xargs -0 keeps filenames-with-spaces safe.
        latest=$(find "$base" -type f -name '*.jsonl' -print0 2>/dev/null \
          | xargs -0 grep -lF "$dir" 2>/dev/null \
          | head -1 || true)
      fi
      if [[ -n "${latest:-}" && -f "$latest" ]]; then
        tail -n 200 "$latest" > "$out"
        echo "wrote $out  (from $latest)"
      else
        echo "no transcript found for $project (looked under $base)"
      fi
    done
    ;;

  *)
    echo "Usage: $0 [run|tail]" >&2
    exit 2
    ;;
esac
