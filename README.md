# minis-open

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%20%7C%20Android-lightgrey.svg)](#building-from-source)

**An open fork of OpenMinis. Same app, deeper agent tooling.**

This repository is a fork of [OpenMinis](https://github.com/OpenMinis/OpenMinis).
It keeps the upstream feature set — on-device models, the Alpine Linux sandbox,
device integrations, skills, memory, browser automation — and adds the pieces
this fork's users actually asked for: a todo system, sub-agent delegation, a
first-class extension system, and a coding toolchain inside the sandbox.

> **How this fork was made.** Nearly all of the code that distinguishes this
> fork from upstream was written by **deepseek-v4-flash** (accessed through a
> third-party relay/proxy) driving the **pi-agent** coding harness, over a
> series of review-and-fix rounds with an independent auditor. See
> [CHANGELOG.md](CHANGELOG.md) for the commit-by-commit record.

---

## What this fork adds

Compared to upstream v1.10, this fork ships:

| Piece | What it does |
|---|---|
| **Todo system** | Session-scoped todos with four agent tools (`todo_create/update/list/clear`), a panel in the chat menu, and system-prompt guidance. The agent breaks work into steps and keeps them updated. |
| **Sub-agent delegation** | `agent_delegate` / `agent_status` tools. The parent agent can hand a bounded subtask (max ~25 turns, no grandchildren) to a sub-agent with its own context and a chosen role. Runs show up in the chat menu. |
| **Extension system** | Install `.minisx` bundles (a zip with a `manifest.json`) from the Extensions manager. Extensions can add agent tools, slash commands, event hooks, WebView widgets, and themes. Scripts run in JavaScriptCore or a vendored Lua 5.4 interpreter. |
| **Extension APIs** | `minis.api.shell/file/permission/event/offload/ui.postMessage/settings` and `minis.http.fetch` — the same native bridge surface for both JS and Lua runtimes. |
| **Per-extension settings** | An extension author declares `settings` in its manifest; the manager shows a gear button that opens a form, and agent code reads them via `minis.api.settings.get`. |
| **Built-in plugins** | Todo and sub-agents are default plugins in the Extensions manager. Turn either off and its tools disappear from the agent, its menu entries vanish, and the system prompt stops mentioning it. |
| **Coding toolchain** | `minis-toolchain` installs bun/node/python/git/ripgrep inside the sandbox on demand, with mirror support for npm/pip/apk. Workspace `AGENTS.md` / `CLAUDE.md` files are injected into the agent context. |
| **iSH ARM64 kernel work** | Pinned `deps/ish` to a fork with FCVTN/FCVTXN ARM64 decoding and `/proc/<pid>/mem` seek support — required for the coding workflows above. |
| **Terminal buttons** | A one-tap terminal button in the chat composer on iOS and Android. |

---

## Building from source

The sandbox (iSH on iOS, PRoot on Android), FFmpeg, LAME, and the Alpine
rootfs are all built from source. Nothing binary is committed.

**See [BUILDING.md](BUILDING.md) for the full first-build guide.**

The short version:

```sh
git clone --recurse-submodules https://github.com/LunWhale/minis-open.git
cd minis-open

# iOS — order matters: FFmpeg links against LAME
./deps/build_lame.sh && ./deps/build_ffmpeg.sh
./deps/build_ish.sh && ./deps/prepare_alpine_rootfs.sh
open src/ios/Minis.xcodeproj

# Android — needs NDK r28+
./deps/build_proot.sh && ./scripts/prepare_android_sandbox.sh
cd src/android && ./gradlew :app:assembleDebug
```

The iOS app and its extensions are named **Minis Open** in this fork.

---

## Repository layout

```
src/ios/          iOS app (Swift / SwiftUI) + share, widget and file-provider extensions
src/android/      Android app (Kotlin / Compose) + JNI native code
src/shared/       Assets shared by both platforms
deps/             Native dependency build scripts and vendored sources
docs/             Architecture and interface specifications
examples/         Sample .minisx extension bundles (demo-extension, lua-demo)
scripts/          Rootfs preparation and developer tooling
```

---

## Acknowledgements

The bulk of the work here is upstream OpenMinis plus the open-source projects
it stands on: [iSH](https://github.com/ish-app/ish) (GPLv3, via an ARM64
fork), [PRoot](https://github.com/termux/proot) (GPLv2), talloc (LGPLv3+),
Alpine Linux, FFmpeg (LGPL-2.1+), LAME (LGPL), cppjieba (MIT), KaTeX (MIT),
and the Swift/Android packages listed in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

---

## License

GPLv3. The app links GPL components (iSH, PRoot), so the combined work is
GPLv3. Full text in [LICENSE](LICENSE); bundled third-party licenses in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
