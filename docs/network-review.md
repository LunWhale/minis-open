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
  `./deps/build_rclone_ios.sh` 重编（device + simulator 两片）。框架**导出了 31 个
  `MinisNet*` / `MinisTs*` C 符号**（`MinisTsSetExitNode`、`MinisNetDecide`、
  `MinisNetDiagnose`、`MinisNetfs*` …），但 Swift 侧没有任何调用点：

  ```sh
  grep -rn "MinisNet\|MinisTs" --include=*.swift src/ios   # 空
  ```

  即：能力在库里，入口不存在。Android 才是这套 API 的消费者。
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
| rclone | `RcloneBridge` / `RcloneRPC` / `RcloneRemoteStore` | Go 框架（含 `MinisNetfs*`） | 备份上传、网盘挂载 |
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
   现状：Go 侧 31 个符号完备（`MinisTsStart/Stop/SetExitNode/Routes`、`MinisNetDecide`…），
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
| 构建 | `arch -x86_64 xcodebuild -project src/ios/Minis.xcodeproj -scheme Minis -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` | **BUILD SUCCEEDED**；`Minis.debug.dylib` 内同样命中该字符串，`nm` 导出 31 个 `_MinisNet*` |
| 容器 DNS 回归 | `./scripts/ios-unit-tests.sh --no-xctest --standalone 'ISHContainerNetworkDnsTests'` | ✅ 43 / ❌ 0（含「mode custom + servers → 内核写的 resolv.conf」端到端） |
| 测试卫生 | `python3 scripts/ios-unit-tests/static_check.py` | 63 hits / 63 allowlisted / 0 stale |

### 环境缺陷（不是代码问题，但会挡住 Xcode 测试）

- **arm64 的 `actool` / `ibtool` / `ibtoold` 启动即崩**：`EXC_ARM_DA_ALIGN`、PC 落在
  `0x0bad4007`，导致 `BUILD FAILED`。x86_64 slice 在 Rosetta 下正常，因此所有
  `xcodebuild` 调用前面加 `arch -x86_64`。
- **`My Mac (Designed for iPad)` 目的地不出现**：Xcode 26.2 (17C52) 配 macOS 26.3 (25D125)
  时，`MinisUnitTests` 的 destination 列表里只有真机和模拟器，
  `scripts/ios-unit-tests.sh` 会停在 `no 'My Mac (Designed for iPad)' destination`。
  XCTest 套件在本机暂时跑不了，standalone 脚本（`swift <file>`）不受影响。
- `timeout(1)` 在 macOS 上不存在，脚本改用内置的 `scripts/ios-unit-tests/timeout.sh`
  （perl `alarm` 垫片）。

## 6. 后续

- 想要 Tailscale 出口：Swift 桥 3 个函数 + 扩展包，另需评估 NetworkExtension 权限的
  审核与描述文件成本。
- 等 Xcode 26.3 之后再跑完整 XCTest；在那之前 CI 用 `arch -x86_64` 或真机目的地。
