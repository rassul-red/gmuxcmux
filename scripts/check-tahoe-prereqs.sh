#!/usr/bin/env bash
# Verify the macOS Tahoe (26.x) + zig 0.15.2 dev environment contract.
# Exits non-zero (and prints a remediation hint) on the first failure.

set -uo pipefail

ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILED=1; }

FAILED=0

echo "==> macOS"
PRODUCT_VERSION="$(sw_vers -productVersion 2>/dev/null || true)"
MAJOR="${PRODUCT_VERSION%%.*}"
if [[ "$MAJOR" =~ ^[0-9]+$ ]] && (( MAJOR >= 26 )); then
  ok "macOS ${PRODUCT_VERSION} (Tahoe-class)"
else
  fail "macOS ${PRODUCT_VERSION:-unknown} — expected 26.x (Tahoe)"
fi

echo "==> zig"
ZIG_BIN="$(command -v zig 2>/dev/null || true)"
if [[ -z "$ZIG_BIN" ]]; then
  fail "zig not found in PATH (install ~/.local/zig/zig-aarch64-macos-0.15.2/zig)"
else
  ZIG_VERSION="$(zig version 2>/dev/null || true)"
  if [[ "$ZIG_VERSION" == "0.15.2" ]]; then
    ok "zig 0.15.2 at $ZIG_BIN"
  else
    fail "zig version is $ZIG_VERSION at $ZIG_BIN — expected 0.15.2"
  fi
fi

echo "==> DEVELOPER_DIR"
DEV_DIR="${DEVELOPER_DIR:-}"
if [[ "$DEV_DIR" == "/Library/Developer/CommandLineTools" ]]; then
  ok "DEVELOPER_DIR=$DEV_DIR"
else
  fail "DEVELOPER_DIR='${DEV_DIR}' — expected /Library/Developer/CommandLineTools"
fi

echo "==> Xcode (for Metal)"
if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  ok "Xcode present at /Applications/Xcode.app"
else
  fail "/Applications/Xcode.app not found — install Xcode 26.4"
fi

echo "==> xcrun / xcodebuild wrappers"
WRAPPER_DIR="$HOME/.local/cmux-bin"
for tool in xcrun xcodebuild; do
  WRAPPER="$WRAPPER_DIR/$tool"
  if [[ -x "$WRAPPER" ]]; then
    RESOLVED="$(command -v "$tool" 2>/dev/null || true)"
    if [[ "$RESOLVED" == "$WRAPPER" ]]; then
      ok "$tool wrapper active at $WRAPPER"
    else
      fail "$tool wrapper exists but PATH resolves to $RESOLVED (expected $WRAPPER)"
    fi
  else
    fail "$tool wrapper missing at $WRAPPER (see docs/dev-build-tahoe.md)"
  fi
done

echo "==> CMUX_GHOSTTYKIT_TARGET"
TARGET="${CMUX_GHOSTTYKIT_TARGET:-}"
if [[ "$TARGET" == "native" ]]; then
  ok "CMUX_GHOSTTYKIT_TARGET=native"
else
  fail "CMUX_GHOSTTYKIT_TARGET='${TARGET}' — expected 'native' for local dev (universal is CI default)"
fi

echo
if [[ "$FAILED" -ne 0 ]]; then
  echo "FAIL — see docs/dev-build-tahoe.md for remediation steps."
  exit 1
fi
echo "OK — environment matches the Tahoe + zig 0.15.2 contract."
