# minis-open

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%20%7C%20Android-lightgrey.svg)](#从源码构建)

[English](README.md) | **中文**

**OpenMinis 的开放分支。同一个应用，更深的 agent 工具链。**

本仓库是 [OpenMinis](https://github.com/OpenMinis/OpenMinis) 的一个 fork。
保留上游全部功能——端侧模型、Alpine Linux 沙箱、设备集成、技能、记忆、
浏览器自动化——并加上这个分支的用户实际需要的东西：todo 系统、子 agent
委派、完整的扩展系统、以及沙箱里的编码工具链。

> **这个 fork 是怎么来的。** 本分支区别于上游的几乎所有代码，都是由
> **deepseek-v4-flash**（经第三方中转站访问）驱动 **pi-agent** 编码工具，
> 经过多轮评审—修复循环（配有独立审计）写出来的。逐条提交记录见
> [CHANGELOG.md](CHANGELOG.md)。

---

## 相比上游新增了什么

相对上游 v1.10，本分支新增：

| 模块 | 说明 |
|---|---|
| **Todo 系统** | 会话级 todo，四个 agent 工具（`todo_create/update/list/clear`）、聊天菜单面板、系统提示引导。agent 会把复杂任务拆成步骤并持续更新状态。 |
| **子 agent 委派** | `agent_delegate` / `agent_status` 工具。父 agent 可以把一个有边界的子任务（最多约 25 轮，不能再派生子 agent）交给拥有独立上下文、按角色运行的子 agent。运行记录可在聊天菜单查看。 |
| **扩展系统** | 从扩展管理器安装 `.minisx` 包（带 `manifest.json` 的 zip）。扩展可以添加 agent 工具、斜杠命令、事件钩子、WebView 组件和主题。脚本运行在 JavaScriptCore 或内置的 Lua 5.4 解释器里。 |
| **扩展 API** | `minis.api.shell/file/permission/event/offload/ui.postMessage/settings` 和 `minis.http.fetch`——JS 和 Lua 两个运行时共用同一套原生桥。 |
| **每个扩展的设置** | 扩展作者在 manifest 里声明 `settings`；管理器会显示一个齿轮按钮，打开按声明渲染的表单，agent 代码通过 `minis.api.settings.get` 读取。 |
| **内置插件** | todo 和子 agent 是扩展管理器里的默认插件。关掉任何一个：它的 agent 工具消失、菜单入口消失、系统提示也不再提起它。 |
| **编码工具链** | `minis-toolchain` 按需在沙箱里装 bun/node/python/git/ripgrep，支持 npm/pip/apk 镜像。工作区里的 `AGENTS.md` / `CLAUDE.md` 会注入 agent 上下文。 |
| **iSH ARM64 内核工作** | `deps/ish` 固定到带 FCVTN/FCVTXN ARM64 解码和 `/proc/<pid>/mem` seek 支持的分支——上面的编码流程依赖它。 |
| **终端按钮** | iOS 和 Android 的聊天输入栏都有一步进入终端的按钮。 |

---

## 从源码构建

沙箱（iOS 用 iSH、Android 用 PRoot）、FFmpeg、LAME 和 Alpine rootfs 都从
源码构建，不提交任何二进制。

**首次构建完整指南见 [BUILDING.md](BUILDING.md)。**

简版：

```sh
git clone --recurse-submodules https://github.com/LunWhale/minis-open.git
cd minis-open

# iOS — 注意顺序：FFmpeg 链接 LAME
./deps/build_lame.sh && ./deps/build_ffmpeg.sh
./deps/build_ish.sh && ./deps/prepare_alpine_rootfs.sh
open src/ios/Minis.xcodeproj

# Android — 需要 NDK r28+
./deps/build_proot.sh && ./scripts/prepare_android_sandbox.sh
cd src/android && ./gradlew :app:assembleDebug
```

本分支的 iOS 应用及其扩展名为 **Minis Open**。

---

## 仓库结构

```
src/ios/          iOS 应用（Swift / SwiftUI）+ 分享、小组件、文件提供器扩展
src/android/      Android 应用（Kotlin / Compose）+ JNI 原生代码
src/shared/       双平台共享资源
deps/             原生依赖构建脚本与 vendored 源码
docs/             架构与接口文档
examples/         示例 .minisx 扩展包（demo-extension、lua-demo）
scripts/          rootfs 准备与开发者工具
```

---

## 致谢

这里的大部分工作来自上游 OpenMinis 及其依赖的开源项目：
[iSH](https://github.com/ish-app/ish)（GPLv3，经 ARM64 分支）、
[PRoot](https://github.com/termux/proot)（GPLv2）、talloc（LGPLv3+）、
Alpine Linux、FFmpeg（LGPL-2.1+）、LAME（LGPL）、cppjieba（MIT）、
KaTeX（MIT），以及 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)
里列出的 Swift/Android 包。

---

## 许可

GPLv3。应用链接了 GPL 组件（iSH、PRoot），因此整体以 GPLv3 发布。
全文见 [LICENSE](LICENSE)；打包的第三方许可见
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。
