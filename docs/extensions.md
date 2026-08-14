# OpenMinis 扩展系统（Extension System）

> OpenMinis 的扩展系统是**独立设计**的原生扩展框架：`.minisx` zip 包，可同时作用于 **agent**（工具/命令/事件钩子）与 **UI**（WebView 组件/主题），zip 安装，无需上架审查。JS 运行时为内置的 JavaScriptCore（iOS）。

---

## 1. 快速开始

1. 写一个文件夹，包含 `manifest.json` + 脚本/资源（见 §2 示例）。
2. 打成 zip：`zip -r my-extension.minisx .`（或在仓库 `scripts/` 用 `build_extension.sh`）。
3. 在 App 内：**设置 → Agent Runtime → Extensions → "+"** 选择 `.minisx` 文件。
4. 扩展自动生效：agent 工具进入模型工具集，命令进 `/` 菜单，主题应用于聊天。

## 2. 包格式（.minisx = zip）

```
my-extension.minisx/
├── manifest.json            ← 必填
├── agent/                   ← agent 侧
│   ├── tools/xxx.js         ← 工具（minis.registerTool）
│   ├── commands/xxx.js      ← 命令（minis.registerCommand）
│   └── hooks/xxx.js         ← 事件钩子（minis.on）
├── ui/                      ← UI 侧
│   ├── widget.html          ← WebView 组件
│   └── theme.json           ← 主题
└── assets/                  ← 其它资源
```

### manifest.json

```json
{
  "id": "com.example.myext",
  "name": "我的扩展",
  "version": "1.0.0",
  "description": "一句话描述",
  "author": "你",
  "kinds": ["agent-tool", "command", "event-hook", "ui-widget", "theme"],
  "permissions": ["shell", "files", "ui"],
  "tools": [
    {
      "file": "agent/tools/hello.js",
      "name": "hello_world",
      "description": "工具描述（注入 agent 系统提示）",
      "schema": { "type": "object", "properties": {} }
    }
  ],
  "commands": [
    { "file": "agent/commands/hello.js", "name": "ext-hello", "description": "说明" }
  ],
  "hooks": [
    { "file": "agent/hooks/log.js", "events": ["agent_start", "agent_end"] }
  ],
  "ui": [
    { "type": "widget", "file": "ui/widget.html", "placement": "chat-panel" }
  ],
  "theme": { "file": "ui/theme.json", "scope": "chat" }
}
```

### 字段说明

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | ✅ | 全局唯一，仅含 `[A-Za-z0-9.-_]`，用作目录名与工具名前缀 |
| `name` / `version` | ✅ | 显示名 / 版本（重复同版本安装会拒绝） |
| `kinds` | ✅ | 能力声明：`agent-tool` `command` `event-hook` `ui-widget` `theme` |
| `permissions` | ✅ | 权限声明：`shell` `files` `network` `device.health` `device.calendar` `ui` … |
| `tools` | | 每个工具一个 JS 文件，`registerTool` 注册 |
| `commands` | | 斜杠命令 |
| `hooks` | | 事件订阅 |
| `ui` | | WebView 组件 |
| `theme` | | 主题文件 |

---

## 3. agent 侧：双语言运行时（JS / Lua）

agent 侧脚本支持两种语言，在 manifest 的 `tools`/`commands`/`hooks` 条目里用
`language` 字段声明：

- **`js`（默认）**：JavaScriptCore（iOS 内置，独立 JSContext）
- **`lua`**：vendored Lua 5.4 解释器（随 App 编译，独立 lua_State）

```json
{
  "tools": [{"file": "agent/tools/greet.lua", "name": "lua_greet", "language": "lua"}],
  "commands": [{"file": "agent/commands/status.lua", "name": "ext-lua-status", "language": "lua"}]
}
```

两个运行时的 `minis` 全局 API 语义一致（JS 用 `minis.registerTool`，Lua 用
`minis.register_tool`）。示例见 `examples/lua-demo/`（Lua 工具 + Lua 命令）。

### JS API（JavaScriptCore）

每个扩展一个独立 JSContext，全局 `minis` 对象可用：

```js
// 注册工具 —— execute(args) 返回字符串；出错时抛异常或返回 {error:"..."}
minis.registerTool({
  name: "my_tool",
  description: "Do something useful.",
  parameters: {},
  execute: function (args) {
    return "result string";
  },
});

// 注册斜杠命令
minis.registerCommand({
  name: "mycmd",
  handler: function () {
    return "command output";
  },
});

// 事件钩子（agent 生命周期：agent_start / agent_end / turn_start / tool_call …）
minis.on("agent_start", function (event) {
  minis.log("agent started", event.sessionId);
});
```

### minis 全局 API

状态标注：**✅ 已实现** / **⏳ 预留**（API 已定义但功能未接线，调用返回空或 no-op）。

| API | 状态 | 说明 |
|---|---|---|
| `minis.registerTool({name, description, parameters, execute})` | ✅ | 注册 agent 工具（`extension_<id>_<name>` 命名空间挂入工具集） |
| `minis.registerCommand({name, handler})` | ✅ | 注册 `/` 命令（出现在斜杠菜单，输入 `/name` 直接执行并回显结果） |
| `minis.on(event, handler)` | ✅ | 订阅 agent 生命周期事件（已接线：`agent_start` / `agent_end` 每轮触发） |
| `minis.api.shell(cmd, {timeout})` | ✅ | 执行沙箱 shell（需要 `shell` 权限）→ Promise\<string\> |
| `minis.api.file.read(path)` | ✅ | 读沙箱文件（需要 `files` 权限）→ Promise\<string\> |
| `minis.api.permission.request(kind)` | ✅ | 请求权限 → Promise\<boolean\>（复用 OffloadPermissionDialog） |
| `minis.api.event.emit(name, data)` | ✅ | 扩展间事件总线（发布到所有订阅了该事件的扩展） |
| `minis.api.offload(name, args)` | ✅ | 桥到沙箱命令执行（apple-* CLI 等，需要 `shell` 权限） |
| `minis.api.ui.postMessage(data)` | ✅ | 向 WebView 组件广播消息（组件用 window.minisBridge 接收，见 §4） |
| `minis.api.file.write(path, content)` | ✅ | 写沙箱文件（需要 `files` 权限，仅 /var/minis/ 路径） |
| `minis.log(...)` | ✅ | 打日志（`Ext[<id>]` 分类） |
| `minis.store.get/set(key, value)` | ✅ | KV 持久化（UserDefaults，按扩展 id 隔离） |
| `minis.http.fetch(url, {method, body})` | ✅ | HTTP 请求（需要 `network` 权限）→ Promise\<{status, body}\> |

> 权限：`shell`/`files`/`ui` 等**首次使用时**触发原生确认弹窗（复用
> OffloadPermissionDialog，30 秒超时）；未声明权限的调用直接报错。

---

## 4. UI 侧：WebView 组件 + 主题

### WebView 组件（功能型 UI）

`ui/widget.html` 在 WKWebView 中渲染（Android 用 WebView），注入桥。
已启用扩展的组件显示在聊天页 **… 菜单 → Extension Widgets** 面板；
每个组件在首次展示时确认 `ui` 权限。

```html
<script>
  // 发送消息到原生
  window.minisBridge.postMessage({ type: "demo:hi", text: "hello" });
  // 接收原生消息
  window.minisBridge.onMessage = function (data) { /* ... */ };
</script>
```

### 主题（美化型 UI）

`ui/theme.json` 声明语义 token，原生渲染器应用：

```json
{
  "name": "Solarized Dark",
  "scope": "chat",
  "tokens": {
    "background": "#002B36",
    "text": "#93A1A1",
    "accent": "#268BD2",
    "userBubble": "#073642",
    "assistantBubble": "#002B36",
    "inputBackground": "#073642",
    "border": "#073642"
  }
}
```

可用 token：`background` `text` `accent` `userBubble` `assistantBubble` `inputBackground` `border`（`scope: "chat"` 应用于聊天 UI）。

---

## 5. 生命周期与权限

| 操作 | 行为 |
|---|---|
| 安装 | zip 校验 → manifest 解析 → 解压到 `Library/MinisChat/extensions/<id>/` → 校验引用文件 → 注册（同 id 同版本拒绝） |
| 启用/停用 | 设置页开关；停用后工具/命令/组件从 agent 与 UI 移除 |
| 更新 | 覆盖安装（版本号不同） |
| 卸载 | 删除注册 + 删除目录 |

**安全**：扩展 JS 运行在 JavaScriptCore 隔离上下文；`shell`/`files` 等能力通过 manifest 权限 + 首次使用弹窗双重门控。请仅安装可信来源的扩展。

---

## 6. 示例

仓库 `examples/demo-extension/` 是一个三合一示例（工具 + 命令 + 钩子 + 组件 + 主题），打包命令：

```bash
cd examples/demo-extension && zip -r ../demo-extension.minisx .
```

或使用 `scripts/build_extension.sh`：

```bash
./scripts/build_extension.sh examples/demo-extension examples/demo-extension.minisx
```

## 7. 调试

- **Debug Log 面板**：扩展管理器右上角 📜 按钮（或 `minis://extensions/debug` 深度链接）打开
  内存日志面板（最近 500 条：安装/卸载/加载错误、工具/命令调用、权限决策、JS/Lua 运行时消息）。
- **`/extensions` 斜杠命令**：聊天里输入 `/extensions` 直接打开扩展管理器。
- 扩展日志：控制台分类 `Ext[<id>]`（JS）、`ExtLua[<id>]`（Lua）。
- 安装错误会在设置页内联显示（manifest 缺失 / 引用文件缺失 / id 冲突等）。
- JS/Lua 语法错误会在加载时以 `ExtensionRegistry` 错误日志报出，安装仍成功但该脚本不生效——修好脚本后停用再启用即可重新加载。
