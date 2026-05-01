#!/usr/bin/env bash
# Apply patches/ghostty/*.patch to the ghostty submodule.
# Idempotent: skips a patch if it is already applied.
#
# Used by scripts/setup.sh and scripts/dev-up.sh so a fresh clone reaches
# BUILD SUCCEEDED on macOS Tahoe + zig 0.15.2 without manual steps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PATCH_DIR="$PROJECT_DIR/patches/ghostty"
GHOSTTY_DIR="$PROJECT_DIR/ghostty"

if [[ ! -d "$GHOSTTY_DIR" ]]; then
  echo "error: ghostty submodule not initialized at $GHOSTTY_DIR" >&2
  echo "       run: git submodule update --init --recursive" >&2
  exit 1
fi

if [[ ! -d "$PATCH_DIR" ]]; then
  echo "==> No patches/ghostty directory; nothing to apply."
  exit 0
fi

shopt -s nullglob
PATCHES=("$PATCH_DIR"/*.patch)
shopt -u nullglob

if [[ "${#PATCHES[@]}" -eq 0 ]]; then
  echo "==> No patches found in $PATCH_DIR; nothing to apply."
  exit 0
fi

cd "$GHOSTTY_DIR"

for patch in "${PATCHES[@]}"; do
  name="$(basename "$patch")"
  if git apply --check --reverse "$patch" >/dev/null 2>&1; then
    echo "==> Already applied: $name"
    continue
  fi
  if ! git apply --check "$patch" >/dev/null 2>&1; then
    echo "error: patch does not apply cleanly: $name" >&2
    echo "       inspect 'git -C ghostty status' and resolve manually." >&2
    exit 1
  fi
  echo "==> Applying: $name"
  git apply "$patch"
done
