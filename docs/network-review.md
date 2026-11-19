# 网络子系统复核 — 合并上游 v1.15.1 之后

上游这一版把「Tailscale 出口节点」修完了，全部落在 Go 侧。iOS fork 里这套东西
**编译进去了、没有任何入口**，所以本轮要回答的不是「改哪一行」，而是三件事：
哪些不用动、哪些不能动、哪些该做插件。下面每条结论都附了可复现的命令。

---

## 1. 上游这次改了什么

| 提交 | 内容 | 对 iOS 的意义 |
|---|---|---|
| `ee718c6` | fix(network,go)：经出口节点的流量能跑通 | 唯一有代码的提交 |
| `b518a7c` | Android 1.15 versionCode 37 | 无（Android 已删） |
| `1a71df0` | PR #495 的合并提交，即 v1.15.1 发布点 | 版本标记 |

`ee718c6` 改了 8 个文件、+540/−13，四组修正：

1. **主机名先解析 IPv4**：出口节点上 IPv6 往往不可用，原来拿到的 AAAA 会让 dial 直接失败。
2. **loopback 留在本地**：`127.0.0.1`/`::1` 走 direct 通道，`rule="loopback"`，不再被路由进隧道。
3. **出口节点离线时拒绝连接**，而不是悄悄退回直连（泄漏）。
4. **shell 的 DNS 在 IPv6 出不去时对 AAAA 返回空答**，让 curl/pip 走 A 记录，而不是等超时。

文件清单：`deps/rclone-mobile/nethub/{nethub.go,dns.go,udp.go,dial_tailnet_test.go}`、
`deps/rclone-mobile/tsnet/{tsnet.go,proxyview.go}`、`src/shared/network/{README.md,route_vectors.json}`、
`src/android/app/build.gradle.kts`。

## 2. 这些改动落到 iOS 的哪里

- **`deps/rclone-mobile/**`** → 只进 `deps/frameworks/Rclone.xcframework`，由
  `./deps/build_rclone_ios.sh` 重编（device + simulator 两片）。框架**导出了 43 个
  `MinisNet*` / `MinisTs*` C 符号**（12 个 nethub + 12 个 tsnet + 19 个 netfs：
  `MinisTsSetExitNode`、`MinisNetDecide`、`MinisNetDiagnose` …），但 Swift 侧没有任何调用点：

  ```sh
  grep -rn "MinisNet\|MinisTs" --include=*.swift src/ios   # 空
  ```

  即：能力在库里，入口不存在——`MinisNetfs*` 同样是「编进框架、Swift 零调用」的状态。
  Android 才是这套 API 的消费者。
- **`src/shared/network/route_vectors.json`** → 只有 `deps/rclone-mobile/nethub/spec_vectors_test.go`
  读它，用于把共享 spec 跑成 Go 测试用例（本轮已跑，见 §5）。
- **`src/android/app/build.gradle.kts`** → fork 已删 Android；合并时是唯一的冲突
  （modify/delete），用 `git rm` 解决，不产生 iOS 侧任何改动。

## 3. iOS 现有网络面（谁在真正发包）

| 层 | 入口文件 | 传输 | 说明 |
|---|---|---|---|
| Provider | `src/ios/Providers/OpenAI/OpenAIProvider.swift:40,79`、`Anthropic/OAuthHTTPClient.swift:83,684,1840,1867`、`Gemini/GeminiProvider.swift:15`、`Voice/VoiceProvider.swift:25`、`Quota/QuotaAdapters.swift:127` | URLSession（部分 ephemeral） | 43 个 Swift 文件 import/使用 URLSession；SSE 流式、工具调用增量、OAuth 都在这一层 |
| MCP | `src/ios/Agent/Session/MCPStore.swift` + `MCPOAuth*` | HTTP/SSE + stdio（经 iSH shell） | 服务器由用户配置，等于「已经插件化」 |
| 浏览器 | `Agent/Chat/AIChatViewModel+BrowserUse*` | WKWebView | 必须原生，WebKit 无 JS 替代 |
| 沙箱网络 | `src/ios/Shared/NetworkMonitor.swift`（`ContainerDnsSettings`）、`src/ios/Views/Rootfs/RootfsManagementView.swift` | iSH 内核 slirp/loopback + resolv.conf 注入 | 配置键 `network.dnsMode` / `network.dnsCustomServers` |
| rclone | `RcloneBridge` / `RcloneRPC` / `RcloneRemoteStore` / `RcloneTransfer` | Go 框架 | 备份上传与远端凭据管理；`MinisNetfs*` 与 nethub 一样只编译、Swift 侧无调用 |
| 挂载 | `Views/Settings/MountedFoldersManager.swift` | FileProvider / 系统网络共享 | 不经过 rclone netfs，走系统文件提供者 |
| 扩展 | `Agent/Extension/ExtensionJSRuntime.swift`（`makeHTTPBridge`）、`ExtensionRegistry.swift:603` | URLSession.shared / 请求改写 | 权限名 `network`、`requests`；示例 `dist/extensions/request-interceptor.minisx` |

## 4. 结论

### 4.1 不用动

1. **Android 版本号**（`b518a7c`）—— 目录已删，随冲突解决消失。
2. **`src/shared/network/README.md` + `route_vectors.json`** —— 共享 spec，iOS 不做镜像实现；
   唯一消费者是 Go 测试，已通过。改动接受即可，无需在 Swift 里「跟进语义」。
3. **iOS 的容器 DNS 行为** —— 与出口节点路由无关：沙箱的 DNS 由内核写 `resolv.conf`
   （`configureDns` + bind-mount fallback），上游改的是 Go 侧隧道的解析顺序。
   43 项断言的 `ISHContainerNetworkDnsTests` 全绿即为证据。
4. **Swift 代码一行都不用改** —— 本次合并零 Swift 冲突、零 Swift 编译告警新增。

### 4.2 不能动

1. **`deps/rclone-mobile/nethub`、`tsnet`** —— iOS/Android 共用同一份 Go 运行时和同一套
   spec 向量。为「iOS 用不到」去裁剪，会：破坏 `spec_vectors_test.go` 的共享契约；
   让以后想接出口路由时无库可用；而 Go 静态库只会链接被引用到的包，
   实测框架体积没有变化（仍 108 MB）。**保留，只是不接线。**
2. **Provider / URLSession 栈** —— 43 个文件的流式实现，改造为统一「会话工厂」是一次
   大重构，收益只在「代理支持」一个场景，风险覆盖全部对话路径。本轮不动。
3. **MCP 传输与 OAuth** —— 依赖 `ASWebAuthenticationSession`、钥匙串、回调 URL scheme，
   与扩展的 JS 运行时不同生命周期，不适合搬。
4. **iSH 内核网络（slirp / loopback / DNS 接管）** —— 沙箱的命脉；DNS 注入必须留在内核侧，
   否则 `apk`、`pip`、`git` 全部受影响。
5. **rclone 备份 / 挂载路径** —— 数据面，不是策略面。

### 4.3 需要插件化

判定原则：**所有用户都要 → 核心；要账号/外部设备/合规开关 → 扩展；只做诊断观测 → 扩展工具。**

1. **出口路由（Tailscale exit node / 自定义代理）** — 插件
   现状：Go 侧 43 个符号完备（`MinisTsStart/Stop/SetExitNode/Routes`、`MinisNetDecide`…），
   iOS 侧 0 入口。**不要**做进 Settings 核心：它需要 Tailscale 账号、要 NetworkExtension
   权限、绝大多数用户永远不点。做法是扩展包（`ui-widget` 配置页 + `agent-tool`
   `net_route_status` / `net_route_set`，permissions 声明 `network`），核心只保留一层薄桥
   —— C 符号已经在了，需要的是约 3 个 Swift 转发函数。
2. **网络诊断** — 插件
   `MinisNetDiagnose` / `MinisNetHealth` / `MinisNetProbe` / `MinisNetShellProbe`
   都是纯函数式接口，天然适合做成 `net_diagnose` 工具，而不是再加一个 Settings 页面。
3. **请求改写 / 观测** — 已插件化，不要再造
   `requests` 权限（`ExtensionRegistry.swift:603`）已经能读改发往模型的请求，
   `dist/extensions/request-interceptor.minisx` 是现成样例。
4. **DNS 服务器自定义** — 保留核心
   沙箱基础能力，插件关掉时也必须能改 DNS；UI 已在 Rootfs 页的 Container Network 区。
5. **备份远端** — 保留核心
   `RcloneRemoteStore` 已经是「可增删的远端列表」，属于数据面配置。

## 5. 本轮验证记录

| 项 | 命令 | 结果 |
|---|---|---|
| 合并 | `git merge upstream/main` | 1 处冲突（android gradle modify/delete），`git rm` 后得 `09340af` |
| Go 测试 | `cd deps/rclone-mobile && go test ./nethub/... ./tsnet/...` | ok（nethub 16.099s、tsnet 0.048s），含 `spec_vectors_test` |
| 重编框架 | `./deps/build_rclone_ios.sh` | `Rclone.xcframework` 108 MB，`strings` 命中 `the exit node is offline` |
| 构建 | `xcodebuild -project src/ios/Minis.xcodeproj -scheme Minis -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` | **BUILD SUCCEEDED**（arm64 原生，见下节根因）；`Minis.debug.dylib` 内同样命中该字符串，`nm` 导出 43 个 `MinisNet*`/`MinisTs*` |
| 容器 DNS 回归 | `./scripts/ios-unit-tests.sh --no-xctest --standalone 'ISHContainerNetworkDnsTests'` | ✅ 43 / ❌ 0（含「mode custom + servers → 内核写的 resolv.conf」端到端） |
| 测试卫生 | `python3 scripts/ios-unit-tests/static_check.py` | 63 hits / 63 allowlisted / 0 stale |

### 环境缺陷（不是代码问题，但会挡住 Xcode 测试）

- **`~/.zshrc` 里的 `export DYLD_LIBRARY_PATH=/opt/homebrew/lib:$DYLD_LIBRARY_PATH`
  污染了每一个 arm64 进程**：Homebrew 的 `libpng16` / `liblzma` / `libjpeg` / `libzstd`
  会顶掉系统动态库，`ImageIO` 的 PNG 写入插件随后踩到 `0x0bad4007`，
  报 `EXC_BAD_ACCESS` / `EXC_ARM_DA_ALIGN` / `SIGBUS`。三个"症状"其实是同一个根因：
  - `actool` / `ibtool` / `ibtoold --version` 启动即崩 → `BUILD FAILED`；
  - `ImageRealIosA` 的 Catalyst harness 在 `CGImageDestinationFinalize` 崩；
  - Rosetta 下的 x86_64 进程不读 arm64 的 Homebrew 库，所以 `arch -x86_64` "看起来"是解药。

  清理后验证：`env -u DYLD_LIBRARY_PATH ibtool --version` 与 `actool --version` 立即正常，
  `xcodebuild …`（原生 arm64）**BUILD SUCCEEDED**，`ImageRealIosATests` ✅23/❌0。
  **正确的修法是把这行从 `~/.zshrc` 删掉**（或只在该 shell 里临时 `export`），
  不再需要 `arch -x86_64`。
- **XCTest 仍然跑不起来，但原因不是目的地**：摘掉 `DYLD_LIBRARY_PATH` 之后
  `My Mac (Designed for iPad)` 目的地重新出现（之前它是跟着 `ibtool` 一起崩在
  xcodebuild 的发现阶段）。现在走得比之前远：
  `build-for-testing -destination 'id=<My Mac>' CODE_SIGNING_ALLOWED=NO` 能产
  `.xctestrun`；`test-without-building` 却停在安装：

  ```
  无法安装 "com.openminis.MinisTestHost"
  Failed to verify code signature of …/MinisTestHost.app : 0xe800801c
  (No code signature found.)
  ```

  用 `codesign -f -s - --entitlements`（application-identifier /
  com.apple.developer.team-identifier / get-task-allow）做 ad-hoc 签名也不被接受
  （`无法验证其完整性`）。iOS-on-Mac 的安装需要 **com.openminis.\* 的 provisioning
  profile**，本机 3 个 profile 只覆盖 `com.brooks.idsh*` 与 `tg.tgqq7885.tool6`。
  模拟器路线也不通：`-destination 'platform=iOS Simulator…'` 的
  `build-for-testing` 直接报 `Unable to find module dependency: 'Minis'`（app target
  的 iSH arm64 依赖只有 device 片）。

  结论：本机能验的是「静态守卫 + 319 个 standalone 脚本 + arm64 `xcodebuild build`
  + IPA 打包」；XCTest 套件需要一台配了 `com.openminis.*` 描述文件的机器。
- `timeout(1)` 在 macOS 上不存在，脚本改用内置的 `scripts/ios-unit-tests/timeout.sh`
  （perl `alarm` 垫片）。

### 5.1 standalone 套件（`scripts/ios-unit-tests.sh --no-xctest --standalone '*'`）

本轮把整条 standalone 测试链跑通并逐个修到绿。除环境根因（见上）之外，另有
**一处真实代码缺陷**由测试抓出：

- `src/ios/Providers/Anthropic/OAuthHTTPClient.swift`：`EagerStreamingHTTPClient.startLoading()`
  与 `DualAuthHTTPClient.startLoading()` 先手写跑了一遍 8 个 request patcher，紧接着又
  调 `RequestBodyPatcher.applyKeyAuthBodyPatches(to:)`（同样 8 个），等于每个请求
  **双重打补丁**（图片被压两次、占位符被替换两次）。已删掉两处内联链，只保留 helper
  调用；`ImageRealIosD` 的 "no protocol runs its own patch list any more" 因此由红转绿。

其余 20 余处是上游重构导致的断言漂移（不是回归），按测试逐个对齐到新代码：

| 套件 | 漂移点 → 新事实 |
|---|---|
| `BrowserCLIReclaimScopeTests` | 会话键从进程级 `mountedSessionIdSnapshot` 改为 `ISHExecutionCoordinator.callerSessionId(fsContext:)`，先查 `MinisFsRouter.shared.sid(for:)`，无 fs_context 才回落快照 |
| `ContextMeasureOutboundTests` | `lastContextTokens: dispatchInputTokens` 由 6 处变 7 处（多一处 compat-proxy fallback 重建） |
| `CodexEmptyResponseReproTests` | 预算结果改名 `reminderHistory`，再作为 `messages:` 传入 |
| `CodexModelDiscoveryTests` | iOS-only fork 没有 `src/android`，Android 可见性对拍降级为 KNOWN GAP |
| `ShortcutBackgroundTitleTests` | StreamEnd 收尾块插入 FINAL FLUSH 日志/自动播放，断言语义放宽为「两次 flush 之间没有第二个 title 或 flush 调用」 |
| `ModelsRefreshWindowTests` | 门限改为 `!versionChanged, let lastRefresh, Date().timeIntervalSince(lastRefresh) < modelsRefreshWindow` |
| `SearchFolderPagesTests` | 卡片收尾统一走 `isLastInFolder: group.isLastMemberRow(`（stack/split 两处） |
| `SidebarRowLookupHangTests` | iPhone 行由 `NavigationLink(value:)` 改为 `Button { menuActions.send(.open(sid)) }` |
| `ResponsesReasoningPassbackTests` | banner 语料改为只读文件名含 `Banner` 的文件，避免被别处的 `.lineLimit(2)` 误伤 |
| `OffloadReadbackLoopTests` / `OffloadWriteIntegrityTests` | 回读重建点 4→5；answered-id 扫描改为 warm-up 计划 |
| `ProviderQuotaTests` / `GeminiProviderFactoryChokepointTests` | 配额打标收敛到 `LLMProviderFactory`；provider 重建点 3→4 |
| `HistoryRebuildKeepsIdsTests` | retry 清理与 in-loop 清扫搬进 `+Send.swift` / `+AgentLoop.swift`，测试改为拼接读取 |
| `ImageBudgetBase64Tests` | 预算 id 从「位置键」改为「位置索引」：`position` / `droppedIds`；主发送点、reminder 预算点同步 |
| `ImageRealIosB/C/D` | harness 白名单补 `AgentMode.swift`，并桩掉 `BuiltinExtension`（16 个 builtin id） |
| `ImageCtxIosE` | 抽取基线 commit `f7d3541` 被 squash 掉，基线缺失降级为 KNOWN GAP |
| `ChatShareModelTests` | 混合 Int/CGFloat 表达式触发 type-check 超时，拆成显式 `CGFloat` 常量 |
| `ImagePipelineReproTests` | **退役**：它 splice 的生产代码（`readImageInference` 等）已整体挪走，覆盖由 `ImageRealIosA/B/C/D` + `ImageBudgetBase64Tests` 承接，文件头写明 `SUPERSEDED-BY` |

工具链侧修了三处：macOS 没有 `timeout(1)`（改用 `scripts/ios-unit-tests/timeout.sh`
perl 垫片）；`pipefail` 下 `grep` 无匹配会让脚本静默退出（补 `|| true`）；
`--standalone '*'` 现在会跳过只吃模拟器的 UIKit 驱动和 `SUPERSEDED-BY` 套件。

## 6. 后续

- 想要 Tailscale 出口：Swift 桥 3 个函数 + 扩展包，另需评估 NetworkExtension 权限的
  审核与描述文件成本。
- 等 Xcode 26.3 之后再跑完整 XCTest；在那之前 CI 用真机/模拟器目的地。构建本身
  已不需要 `arch -x86_64` —— 先把 `DYLD_LIBRARY_PATH` 摘干净。
