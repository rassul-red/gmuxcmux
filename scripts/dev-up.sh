#!/usr/bin/env bash
# Tahoe (26.x) + zig 0.15.2 reproducible build pipeline for the dev_jung branch.
#
# Steps:
#   1. fetch + recurse-update submodules (idempotent)
#   2. apply patches/ghostty/*.patch in order (skip if already applied)
#   3. run ./scripts/reload.sh --tag dev_jung
#
# Env contract (must be set in caller's shell — see docs/dev-build-tahoe.md):
#   PATH must contain ~/.local/cmux-bin and ~/.local/zig/zig-aarch64-macos-0.15.2
#   DEVELOPER_DIR=/Library/Developer/CommandLineTools
#   CMUX_GHOSTTYKIT_TARGET=native

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TAG="${CMUX_DEV_UP_TAG:-dev_jung}"

cd "$PROJECT_DIR"

echo "==> [dev-up] Updating submodules (recursive)"
git submodule update --init --recursive

echo "==> [dev-up] Applying patches/ghostty/*.patch"
"$SCRIPT_DIR/apply-ghostty-patches.sh"

echo "==> [dev-up] Building cmux DEV ${TAG} via reload.sh"
"$SCRIPT_DIR/reload.sh" --tag "$TAG"

echo "==> [dev-up] Done. Build log: /tmp/cmux-xcodebuild-${TAG//_/-}.log"
