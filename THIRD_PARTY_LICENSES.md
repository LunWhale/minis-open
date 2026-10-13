# Third-Party Licenses

OpenMinis bundles, links, or depends on the following third-party components. Versions reflect the current source tree; license types were verified against each project's repository (GitHub license metadata / LICENSE files).

## Native C/C++ dependencies (`deps/`)

| Component | Version / Source | License | Notes |
|---|---|---|---|
| [iSH](https://github.com/OpenMinis/ish-arm64) (ARM64 fork) | git submodule `deps/ish` | **GPL-3.0** (post-`0e3a414` contributions also under GPL-2.0), with an App Store distribution exception (`LICENSE.IOS`) | Linux usermode emulation on iOS (ARM64 fork, aarch64 guest); core reason the app is GPLv3 |
| [rclone](https://github.com/rclone/rclone) | v1.75.0 (`deps/rclone-mobile/go.mod`), built by `deps/build_rclone_ios.sh` | **MIT** (its Go module dependencies are under MIT / BSD / Apache-2.0) | Backup remote destinations: `Rclone.xcframework` |
| [FFmpeg](https://ffmpeg.org) | 6.1.2, built by `deps/build_ffmpeg.sh` | **LGPL-2.1-or-later** (built without `--enable-gpl` / `--enable-nonfree`) | Dynamic frameworks on iOS; keep the LGPL configuration |
| [LAME](https://lame.sourceforge.io) | 3.100, vendored at `deps/lame-3.100` | **LGPL-2.0-or-later** | MP3 encoder, linked into FFmpeg via `--enable-libmp3lame` |
| [cppjieba](https://github.com/yanyiwu/cppjieba) | vendored at iOS `Vendor/cppjieba` | **MIT** | Chinese word segmentation (header-only + dictionaries) |
| Alpine Linux minirootfs | downloaded at build time by `deps/prepare_alpine_rootfs.sh` | Aggregate of package licenses (musl **MIT**, BusyBox **GPL-2.0**, etc.) | Not stored in this repo; bundled into app builds as the default rootfs |

## iOS — Swift Package Manager dependencies

Direct packages declared in `src/ios/Minis.xcodeproj`:

| Package | Version | Repository | License |
|---|---|---|---|
| SwiftAnthropic | 2.2.0 (exact) | https://github.com/jamesrochabrun/SwiftAnthropic | **MIT** |
| swift-cmark (`cmark-gfm`, `cmark-gfm-extensions`) | 0.7.1 | https://github.com/swiftlang/swift-cmark | **BSD-2-Clause** (with some MIT-licensed vendored files, see its `COPYING`) |
| SwiftMath | 1.7.3 | https://github.com/mgriebling/SwiftMath | **MIT** |
| RealTimeCutVADLibrary | 1.0.14 | https://github.com/helloooideeeeea/RealTimeCutVADLibrary | **MIT** |

RealTimeCutVADLibrary bundles [ONNX Runtime](https://github.com/microsoft/onnxruntime) (**MIT**), the [WebRTC audio processing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing) module (**BSD-3-Clause**) and the [Silero VAD](https://github.com/snakers4/silero-vad) model (**MIT**).

Transitive packages (pinned in `Package.resolved`), all **Apache-2.0**, maintained by Apple / the Swift Server Workgroup: `async-http-client`, `swift-algorithms`, `swift-asn1`, `swift-async-algorithms`, `swift-atomics`, `swift-certificates`, `swift-collections`, `swift-crypto`, `swift-distributed-tracing`, `swift-http-structured-headers`, `swift-http-types`, `swift-log`, `swift-nio` (+ `-extras`, `-http2`, `-ssl`, `-transport-services`), `swift-numerics`, `swift-service-context`, `swift-service-lifecycle`, `swift-system`.

## Bundled web/UI assets

| Asset | Location | License |
|---|---|---|
| KaTeX | iOS `src/ios/Resources/KaTeX/` | **MIT** |
| jieba dictionaries | iOS bundle | **MIT** (cppjieba distribution) |
| [tiktoken](https://github.com/openai/tiktoken) `cl100k_base` BPE ranks | iOS `src/ios/Shared/cl100k_base.tiktoken`; the tokenizer in `BPETokenizer.swift` is ported from tiktoken | **MIT** |

## Removed / historical

- **swift-markdown-ui** (MIT) — formerly vendored under `deps/swift-markdown-ui`; no longer referenced by the Xcode project or imported by any source file, and is not part of the open-source tree.
