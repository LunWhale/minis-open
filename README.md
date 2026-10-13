# minis-open

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/Platforms-iOS-lightgrey.svg)](#building-from-source)

**English** | [中文](README-ZH.md)

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

> **Pluggable and token-lean.** Upstream is feature-complete, but in real-world
> use it burns a lot of tokens per request. This fork borrows the minimalist
> philosophy of **pi-agent** and the **deepseek harness**: the system prompt and
> the agent's feature surface are split into pluggable modules (Todo, sub-agents,
> Memory, Skills, MCP, Soul, mounted folders, environment variables, coding
> toolchain…), each toggleable in the Extensions manager. Turning off what you
> don't use — or trimming the prompt modules — can noticeably lower token
> consumption. A single unified "minimal mode" may be added later.

Compared to upstream v1.14, this fork ships:

| Piece | What it does |
|---|---|
| **Todo system** | Session-scoped todos with four agent tools (`todo_create/update/list/clear`), a panel in the chat menu, and system-prompt guidance. The agent breaks work into steps and keeps them updated. |
| **Sub-agent delegation** | Upstream v1.14 ships its own Helper system (`subagent_task`: delegate/status/steer/cancel/resume, background runs, per-agent definitions). This fork gates it behind the "Sub-agent Delegation" plugin switch so it can be turned off token-lean. |
| **Extension system** | Install `.minisx` bundles (a zip with a `manifest.json`) from the Extensions manager. Extensions can add agent tools, slash commands, event hooks, WebView widgets, and themes. Scripts run in JavaScriptCore or a vendored Lua 5.4 interpreter. |
| **Extension APIs** | `minis.api.shell/file/permission/event/offload/ui.postMessage/settings` and `minis.http.fetch` — the same native bridge surface for both JS and Lua runtimes. |
| **Per-extension settings** | An extension author declares `settings` in its manifest; the manager shows a gear button that opens a form, and agent code reads them via `minis.api.settings.get`. |
| **Built-in plugins** | Todo and sub-agents are default plugins in the Extensions manager. Turn either off and its tools disappear from the agent, its menu entries vanish, and the system prompt stops mentioning it. |
| **Coding toolchain** | `minis-toolchain` installs bun/node/python/git/ripgrep inside the sandbox on demand, with mirror support for npm/pip/apk. Workspace `AGENTS.md` / `CLAUDE.md` files are injected into the agent context. |
| **iSH ARM64 kernel work** | The fork contributed FCVTN/FCVTXN ARM64 decoding and `/proc/<pid>/mem` seek support to iSH — both are now upstream (PR #22 and the proc-seek fixes), so `deps/ish` tracks upstream directly. |
| **Terminal buttons** | A one-tap terminal button in the chat composer. |

---

## Building from source

The sandbox (iSH), FFmpeg, LAME, rclone, and the
Alpine rootfs are all built from source. Nothing binary is committed.

**See [BUILDING.md](BUILDING.md) for the full first-build guide.**

The short version:

```sh
git clone --recurse-submodules https://github.com/LunWhale/minis-open.git
cd minis-open

# iOS  — needs Go 1.25+ and Xcode's Metal Toolchain
#        (xcodebuild -downloadComponent MetalToolchain)
#        order matters: FFmpeg links against LAME
./deps/build_lame.sh && ./deps/build_ffmpeg.sh
./deps/build_ish.sh && ./deps/prepare_alpine_rootfs.sh
./deps/build_rclone_ios.sh
open src/ios/Minis.xcodeproj
```

The iOS app and its extensions are named **Minis Open** in this fork.

---

## Repository layout

```
src/ios/          iOS app (Swift / SwiftUI) + share, widget and file-provider extensions
src/shared/       Assets shared with upstream's iOS build (bashism rules)
deps/             Native dependency build scripts and vendored sources
docs/             Architecture and interface specifications
examples/         Sample .minisx extension bundles (demo-extension, lua-demo)
scripts/          Rootfs preparation and developer tooling
```

---

## Acknowledgements

The bulk of the work here is upstream OpenMinis plus the open-source projects
it stands on: [iSH](https://github.com/ish-app/ish) (GPLv3, via an ARM64
fork),
Alpine Linux, FFmpeg (LGPL-2.1+), LAME (LGPL), cppjieba (MIT), KaTeX (MIT),
and the Swift packages listed in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

---

## License

GPLv3. The app links GPL components (iSH), so the combined work is
GPLv3. Full text in [LICENSE](LICENSE); bundled third-party licenses in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
