# Building Minis

Minis ships a full Linux sandbox inside the app, so a first build is not just
"open the project and press Run": the native dependencies (iSH, FFmpeg,
LAME) and the Alpine rootfs are **built from source by the
scripts in `deps/`**, not committed as binaries. Budget ~30–60 minutes for the
first build; afterwards the artifacts are cached on disk and normal builds are
fast.

Read the iOS section end to end before starting — the steps are
ordered by dependency, and skipping one produces confusing link errors later.

---

## iOS-only fork

This fork ships **iOS only**. Upstream OpenMinis also carries an Android app;
this fork deliberately does not, and an upstream merge will re-add it.

After every upstream merge, re-apply the policy:

```sh
./scripts/drop-android.sh --check   # exits 1 if Android came back
./scripts/drop-android.sh           # remove it again
```

The script deletes the Android platform only — `src/android/`, the `deps/proot`
and `deps/talloc` submodules/vendored trees, the Android build scripts, and the
rclone `gomobile` binding. It never touches `src/shared/`: the bashism rules
there are a real iOS bundle resource.

---

## Common setup

Clone with submodules — the iSH fork is a submodule, and a clone
without it will fail at the native build step:

```sh
git clone --recurse-submodules https://github.com/LunWhale/minis-open.git
cd OpenMinis

# Already cloned without --recurse-submodules?
git submodule update --init --recursive
```

| Submodule | Repository | Used by |
|---|---|---|
| `deps/ish` | [OpenMinis/ish-arm64](https://github.com/OpenMinis/ish-arm64) | iOS sandbox kernel |

### Build-time customization

Some values are injected at build time and are **not** in this repository.
Copy the templates before building:

```sh
cp src/ios/Configs/ProviderCustomization.xcconfig.example \
   src/ios/Configs/ProviderCustomization.xcconfig
```

Leaving the values empty is fine — **the app compiles and runs**. A value is
only required by the feature that uses it, and that feature fails loudly at
runtime when it is missing. API-key based sign-in works without any
customization.

### `ANTHROPIC_OAUTH_IDENTIFIER_PROMPT`

Only relevant if you want to **sign in with Claude OAuth credentials** rather
than an Anthropic API key.

When a request is authenticated with OAuth, Anthropic's endpoint expects the
system prompt to begin with the identifying line that Claude Code itself
sends; without it the request is rejected. The build injects that line from
this value, so OAuth sign-in fails at runtime while it is empty.

We do not ship a value. Supply your own if you need this path — other
open-source projects that talk to the same endpoint declare the same
identifier, for example
[claude-relay-service](https://github.com/Wei-Shaw/claude-relay-service),
which you can consult for the exact wording.

Everything else — Anthropic API keys, and every other provider — works
without setting this.

---

## iOS

### Requirements

| Tool | Version / notes |
|---|---|
| macOS | Apple Silicon strongly recommended (see the simulator note below) |
| Xcode | With the iOS SDK; the project targets **iOS 26.2** and **Swift 6.0** |
| Metal Toolchain | `xcodebuild -downloadComponent MetalToolchain` — recent Xcode ships it as a separate component |
| Homebrew packages | `brew install ninja llvm libarchive pkg-config` |
| Python 3 + Meson | `pip3 install meson` |
| Go | **1.25+** (`brew install go`), for rclone |

`llvm` is needed to compile the guest VDSO, `libarchive` to unpack the rootfs,
and Meson/Ninja to build the iSH kernel.

The Metal Toolchain matters even though the build succeeds without it: FFmpeg's
`configure` probes for the `metal` compiler and, when it is missing, **silently
drops** the Metal-backed `yadif_videotoolbox` deinterlace filter. Check with
`xcrun -sdk iphoneos metal --version` before running `build_ffmpeg.sh`.

### 1. Build the native dependencies

Run these from the repository root, **in this order** — FFmpeg links against
LAME, so LAME must exist first or MP3 encoding is silently dropped:

```sh
./deps/build_lame.sh          # → deps/lame-build/lib/libmp3lame.a
./deps/build_ffmpeg.sh        # → deps/frameworks/*.framework  (LGPL config)
./deps/build_ish.sh           # → deps/libs/*.a, deps/include/, deps/resources/
./deps/prepare_alpine_rootfs.sh   # → deps/resources/alpine-rootfs.zip
./deps/build_rclone_ios.sh    # → deps/frameworks/Rclone.xcframework
```

What each produces:

- **`build_lame.sh`** — LAME 3.100 as a static library for arm64.
- **`build_ffmpeg.sh`** — FFmpeg 6.1.2 as per-library `.framework` bundles plus
  an umbrella `FFmpeg.framework`. Configured **LGPL**: do not add
  `--enable-gpl` or `--enable-nonfree` — see [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
- **`build_ish.sh`** — `libish`, `libish_emu`, `libfakefs` from the `deps/ish`
  submodule, plus headers and the VDSO.
- **`prepare_alpine_rootfs.sh`** — downloads Alpine aarch64 minirootfs and
  converts it to iSH's fakefs format.
- **`build_rclone_ios.sh`** — rclone as a static-library XCFramework (device
  and simulator slices) for the backup feature's remote destinations (SMB /
  WebDAV / SFTP / S3 / FTP). Needs only the Go toolchain. The
  linked backends are listed in `deps/rclone-mobile/backends/backends.go`.

The Xcode project references `deps/libs/`, `deps/include/`, `deps/frameworks/`
and `deps/resources/` relative to the project, so nothing needs to be copied
by hand.

### 2. Build the app

```sh
open src/ios/Minis.xcodeproj
```

Select the **Minis** scheme and build. For a device build, set your own team
under *Signing & Capabilities* — the project ships with an empty
`DEVELOPMENT_TEAM`.

From the command line:

```sh
xcodebuild -project src/ios/Minis.xcodeproj -scheme Minis \
           -configuration Debug -destination 'generic/platform=iOS' \
           CODE_SIGNING_ALLOWED=NO build
```

> **Simulator builds need simulator-architecture dependencies.** The scripts
> above build for **device arm64**. Linking a simulator build against them
> fails with `building for 'iOS-simulator', but linking in object file built
> for 'iOS'` (or a missing-symbol error for x86_64 on Intel Macs). Build for a
> device destination, or rebuild the native deps for the simulator SDK.

### Targets

`Minis` (app), `MinisShare` (share extension), `AgentWidgetExtension`,
`MinisFileProvider`, plus `MinisTests` / `MinisUITests`.

---

## Troubleshooting

**`deps/ish` is empty** — the submodules were not initialised:
`git submodule update --init --recursive`.

**iOS: `Undefined symbols … _vstats_version` / `symbol(s) not found`** — FFmpeg
was not built, or was built for a different architecture than the one you are
linking. Rerun `./deps/build_ffmpeg.sh` and build for a device destination.

**iOS: `linking in object file built for 'iOS'` on a simulator build** — see
the simulator note above.

**iOS: MP3 encoding unavailable** — `build_lame.sh` did not run before
`build_ffmpeg.sh`. Rerun both in order.

**iOS: `There is no XCFramework found at '…/deps/frameworks/Rclone.xcframework'`**
— rclone was not built. Run `./deps/build_rclone_ios.sh`.

**iOS: `cannot execute tool 'metal' due to missing Metal Toolchain`** in the
FFmpeg build log, or the `yadif_videotoolbox` filter is absent — install it with
`xcodebuild -downloadComponent MetalToolchain`, then rerun
`./deps/build_ffmpeg.sh`.

**A feature throws about a missing configuration value** — that value comes
from the customization file; see [Build-time customization](#build-time-customization).

---

## Licensing note

Minis is **GPLv3** because it links iSH (GPLv3). If you
change how the native dependencies are built, keep FFmpeg on its LGPL
configuration and preserve the vendored `LICENSE` files. See
[LICENSE](LICENSE) and [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
