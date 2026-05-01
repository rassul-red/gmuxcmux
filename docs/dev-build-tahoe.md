# Dev Build on macOS Tahoe (26.x) + zig 0.15.2

This guide takes a fresh checkout of `g-mux/gmux` to a `BUILD SUCCEEDED` cmux Debug
build on macOS Tahoe (26.x). It is the canonical environment contract for the
`dev_jung` branch — every prerequisite, env var, and script invocation below is
required.

If you only want the one-shot pipeline, run:

```bash
bash scripts/dev-up.sh
```

`scripts/dev-up.sh` performs every step in this document (submodule init, patch
apply, build via `./scripts/reload.sh --tag dev_jung`) and tees the build log to
`/tmp/cmux-dev_jung-build.log`.

## Prerequisites

- **Xcode 26.4** — primary toolchain for Metal/xcodebuild.
  Confirm with: `xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`.
- **Command Line Tools 26.x** — `xcode-select --install` if missing.
- **zig 0.15.2** — installed at `~/.local/zig/zig-aarch64-macos-0.15.2/`
  (see next section). Do not rely on `brew install zig`; Homebrew may resolve
  a different version. Homebrew zig is acceptable only as a last-resort fallback.
- **gh CLI authenticated** to `g-mux/gmux` (only required for PR work, not the
  build itself).

Verify everything in one shot:

```bash
bash scripts/check-tahoe-prereqs.sh
```

## Install zig 0.15.2

```bash
ZIG_ARCHIVE=zig-aarch64-macos-0.15.2.tar.xz
ZIG_URL=https://ziglang.org/download/0.15.2/${ZIG_ARCHIVE}
mkdir -p ~/.local/zig
curl -L "$ZIG_URL" -o /tmp/${ZIG_ARCHIVE}
tar -xf /tmp/${ZIG_ARCHIVE} -C ~/.local/zig/
# Result: ~/.local/zig/zig-aarch64-macos-0.15.2/zig
```

Verify:

```bash
~/.local/zig/zig-aarch64-macos-0.15.2/zig version
# expected: 0.15.2
```

## xcrun / xcodebuild wrappers

Place these two scripts in `~/.local/cmux-bin/` and prepend that directory to
`PATH`. The wrappers route Metal-related `xcrun` invocations to the full Xcode
toolchain while keeping the default `DEVELOPER_DIR` pointed at Command Line
Tools (where Ghostty's zig build expects to find C headers).

`~/.local/cmux-bin/xcrun`:

```bash
#!/bin/bash
# cmux build wrapper: route metal/metallib to Xcode dev dir, others to CLT
for arg in "$@"; do
  case "$arg" in
    metal|metallib)
      exec /usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun "$@"
      ;;
  esac
done
exec /usr/bin/xcrun "$@"
```

`~/.local/cmux-bin/xcodebuild`:

```bash
#!/bin/bash
exec /usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild "$@"
```

```bash
chmod +x ~/.local/cmux-bin/xcrun ~/.local/cmux-bin/xcodebuild
```

## Env contract

All three variables must be set before running any build script. `dev-up.sh`
relies on these being in your shell — it does not export them itself, so the
contract is identical for direct invocations of `./scripts/reload.sh`.

| Variable | Required value | Purpose |
|---|---|---|
| `PATH` | `~/.local/cmux-bin:~/.local/zig/zig-aarch64-macos-0.15.2:$PATH` | Wrapper xcrun/xcodebuild and zig 0.15.2 take precedence |
| `DEVELOPER_DIR` | `/Library/Developer/CommandLineTools` | Ghostty's zig build uses CLT headers; Metal steps use Xcode via the xcrun wrapper |
| `CMUX_GHOSTTYKIT_TARGET` | `native` | `scripts/ensure-ghosttykit.sh` passes `-Dxcframework-target=native` to `zig build`, skipping iOS/simulator slices and halving build time |

Add to `~/.zshrc` (or `~/.bashrc`):

```bash
export PATH="$HOME/.local/cmux-bin:$HOME/.local/zig/zig-aarch64-macos-0.15.2:$PATH"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export CMUX_GHOSTTYKIT_TARGET=native
```

> **Note:** the default for `CMUX_GHOSTTYKIT_TARGET` in
> `scripts/ensure-ghosttykit.sh` is `universal` — that is intentional, so CI keeps
> producing a fat xcframework. `native` is local-dev-only.

## Build

The supported one-shot pipeline:

```bash
bash scripts/dev-up.sh 2>&1 | tee /tmp/cmux-dev_jung-build.log
tail -5 /tmp/cmux-dev_jung-build.log    # expect: ** BUILD SUCCEEDED **
```

Equivalent step-by-step:

```bash
git submodule update --init --recursive
(cd ghostty \
  && git apply ../patches/ghostty/0001-cmux-tahoe-native-only-target.patch \
  && git apply ../patches/ghostty/0002-cmux-tahoe-xcrun-pathrelative.patch)
./scripts/reload.sh --tag dev_jung 2>&1 | tee /tmp/cmux-dev_jung-build.log
```

Patches **must** be reapplied after every `git submodule update` —
`scripts/setup.sh` and `scripts/dev-up.sh` both do this for you. Do not commit
the patched files inside the submodule (it is detached HEAD).

The full xcodebuild log is tee'd to `/tmp/cmux-xcodebuild-dev-jung.log` for
deeper inspection.

## Reproducibility check (clean DerivedData)

> `reload.sh` sanitizes the tag for filesystem paths (`dev_jung` → `dev-jung`),
> so the on-disk DerivedData directory is `cmux-dev-jung`, not `cmux-dev_jung`.
> Build-log paths use the same hyphenated slug
> (`/tmp/cmux-xcodebuild-dev-jung.log`).

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/cmux-dev-jung
bash scripts/dev-up.sh 2>&1 | tee /tmp/cmux-dev_jung-build.log
tail -5 /tmp/cmux-dev_jung-build.log
```

Pass criterion: output contains `** BUILD SUCCEEDED **`.

## Parallel-run socket check

While the user's existing Ghostty.app is running, launch the newly built tagged
app and assert socket isolation:

```bash
open "$HOME/Library/Developer/Xcode/DerivedData/cmux-dev-jung/Build/Products/Debug/cmux DEV dev_jung.app"
lsof -U | grep -E 'cmux|ghostty' | sort -u
```

Expected socket partition (no overlap):

| Process | Socket path |
|---|---|
| `cmux DEV dev_jung` | `/tmp/cmux-debug-dev-jung.sock` |
| `cmuxd` (dev_jung) | `~/Library/Application Support/cmux/cmuxd-dev-dev-jung.sock` |
| `Ghostty` | its own socket (e.g. `/tmp/ghostty-*.sock`) — no path shared with cmux DEV dev_jung |

No socket path may appear in both rows. Bundle IDs are isolated:
`com.cmuxterm.app.debug.dev.jung` (tagged app) vs `com.mitchellh.ghostty`.

## Troubleshooting

- **`xcrun: error: unable to find utility 'metal'`** — `~/.local/cmux-bin/xcrun`
  is not earlier in `PATH` than `/usr/bin`. Re-source your shell rc.
- **`error: no such module 'GhosttyKit'`** — run
  `scripts/ensure-ghosttykit.sh` manually and confirm
  `CMUX_GHOSTTYKIT_TARGET=native`. If `GhosttyKit.xcframework` symlink at the
  repo root is broken, delete it and rerun.
- **`zig: command not found`** — confirm
  `~/.local/zig/zig-aarch64-macos-0.15.2` is in `PATH` (and that `zig version`
  prints `0.15.2`).
- **`BUILD FAILED` with Metal linker error** — confirm `DEVELOPER_DIR` is **not**
  globally exported as `/Applications/Xcode.app/Contents/Developer`. The xcrun
  wrapper handles Xcode routing for Metal calls; a global override breaks the
  Ghostty zig build.
- **`patch does not apply`** in `scripts/setup.sh` /
  `scripts/dev-up.sh` — the submodule is already patched. Run
  `git -C ghostty status` to inspect; if both `src/build/GhosttyXCFramework.zig`
  and `src/build/MetallibStep.zig` are modified, the patches are in place and
  it is safe to skip the apply step.
- **Two `cmux DEV.app` instances stealing focus from each other** — you launched
  an untagged build. Always pass `--tag dev_jung` to `reload.sh`. The shared
  default Debug socket and bundle ID otherwise collide with any other agent's
  Debug instance.
