# minis-open 插件（扩展）开发指南

> 适用版本：**minis-open 1.14+（iOS）**。
> 一个插件 = 一个 `.minisx` 文件（zip 包）= `manifest.json` + 若干脚本/资源。
> agent 侧脚本默认运行在 **JavaScriptCore**（与浏览器无关），也可用内置的 **Lua 5.4**。
> 读完本文即可从零写出可安装的插件；文末附**可直接粘贴给 AI 的提示词模板**。

---

## 1. 插件能做什么

| 能力 | `kinds` 值 | 说明 |
|---|---|---|
| Agent 工具 | `agent-tool` | 注册一个工具，模型在对话中可调用（命名空间 `extension_<id>_<name>`） |
| 斜杠命令 | `command` | 注册 `/命令`，用户输入 `/名字 参数…` 即执行；也出现在 `/` 菜单 |
| 事件钩子 | `event-hook` | 订阅 agent 生命周期事件（`agent_start` / `agent_end` / `tool_call` / `tool_result`）及自定义事件 |
| **请求拦截** | 任意 kind（拦截器在已加载的脚本里注册，通常在 hooks 文件） | **1.13.2 引入**（1.14 起继续提供）：改写发往模型的 HTTP 请求（URL / 方法 / 请求头 / 请求体）；需声明 `requests` 权限 |
| UI 组件 | `ui-widget` | 在聊天页渲染一个 WKWebView 小面板，可与插件双向收发消息 |
| 主题 | `theme` | 用 JSON 声明语义色，原生聊天 UI 实时应用 |
| 扩展设置 | （伴随能力） | manifest 声明设置项，用户在扩展管理页 ⚙️ 修改，脚本读取 |
| KV 存储 | （伴随能力） | 按插件隔离的键值持久化 |
| 主机 API | （伴随能力） | 沙箱 shell、文件读写、HTTP、权限申请、扩展间事件总线 |

---

## 2. 五分钟上手

### 2.1 目录结构

```
my-plugin/                  ← 打包后的 my-plugin.minisx（zip）
├── manifest.json           ← 必需
├── agent/
│   ├── tools/hello.js      ← 工具（minis.registerTool）
│   ├── commands/hello.js   ← 命令（minis.registerCommand）
│   └── hooks/log.js        ← 事件钩子（minis.on）
├── ui/
│   ├── widget.html         ← WebView 组件（可选）
│   └── theme.json          ← 主题（可选）
└── assets/                 ← 其余资源（可选）
```

### 2.2 最小 manifest.json

```json
{
  "id": "com.example.hello",
  "name": "Hello 插件",
  "version": "1.0.0",
  "description": "示例：一个命令 + 一个工具 + 一个钩子",
  "author": "you",
  "kinds": ["agent-tool", "command", "event-hook"],
  "permissions": ["shell"],
  "tools": [
    {
      "file": "agent/tools/hello.js",
      "name": "hello_world",
      "description": "返回一句问候",
      "schema": {
        "type": "object",
        "properties": { "name": { "type": "string", "description": "问候对象" } }
      }
    }
  ],
  "commands": [
    { "file": "agent/commands/hello.js", "name": "ext-hello", "description": "打招呼" }
  ],
  "hooks": [
    { "file": "agent/hooks/log.js", "events": ["agent_start", "tool_call"] }
  ]
}
```

### 2.3 三个脚本

`agent/tools/hello.js`：

```js
// 工具 handler 收到的是「模型传入的 args 对象」（宿主自动解包）。
// 可以直接返回字符串，也可以返回 Promise；抛异常 = 工具失败。
minis.registerTool({
  name: "hello_world",
  description: "Returns a greeting.",
  execute: function (args) {
    var who = (args && args.name) || "world";
    return "Hello, " + who + "!";
  },
});
```

`agent/commands/hello.js`：

```js
// 命令 handler 收到的是「按空格切分后的参数数组」：/ext-hello Alice → ["Alice"]
// 返回值会作为系统消息显示在聊天里。
minis.registerCommand({
  name: "ext-hello",
  description: "Says hello.",
  handler: function (args) {
    var who = (args && args.length ? args.join(" ") : "world");
    return "Hello, " + who + "!";
  },
});
```

`agent/hooks/log.js`：

```js
// 订阅生命周期事件。钩子文件在加载时执行一次，
// 这里注册的 handler 在事件发生时被逐一调用。
minis.on("agent_start", function (event) {
  minis.log("[hello] round", event.round, "session", event.sessionId);
});
minis.on("tool_call", function (event) {
  minis.log("[hello] tool", event.tool, "args", event.args);
});
```

### 2.4 打包

```bash
# 仓库自带打包脚本（推荐；会自动加一条兼容清单并校验 manifest）
./scripts/build_extension.sh my-plugin my-plugin.minisx

# 等价的手工方式（注意：必须把 manifest.json 放在 zip 根目录）
cd my-plugin && zip -r ../my-plugin.minisx .
```

### 2.5 安装与验证

1. 把 `.minisx` 传到 iPhone（AirDrop / 文件 App / iCloud 均可）。
2. App 内：**设置 → Agent Runtime → Extensions → 右上角 ➕ → 选择该文件**。安装后默认启用。
3. 聊天输入框输入 `/ext-hello Alice` 并发送 → 出现 `Extension command: ext-hello` 与问候语。
4. 让模型调用 `hello_world` 工具 → 返回答复。
5. 若任一步失败，打开 **Extensions 右上角 📜（调试日志）** 查看加载错误。
（也可用深链 `minis://extensions` 直接打开扩展管理器。）

---

## 3. 包格式与 manifest 参考

### 3.1 manifest.json 顶层字段

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | ✅ | 全局唯一；仅允许 `A-Za-z0-9.-_`；用作目录名与工具命名空间前缀 |
| `name` / `version` | ✅ | 显示名 / 版本。同 id 同版本会拒绝安装；不同版本 = 升级覆盖 |
| `description` / `author` | | 展示用 |
| `kinds` | ✅ | 能力声明：`agent-tool` `command` `event-hook` `ui-widget` `theme` |
| `permissions` | ✅ | 权限声明：`shell` `files` `network` `requests` `ui`（见 §6） |
| `settings` | | 设置项声明，见 §3.2 |
| `tools` | | 工具声明，见 §3.3 |
| `commands` | | 命令声明，见 §3.4 |
| `hooks` | | 事件钩子声明，见 §3.5 |
| `ui` | | WebView 组件声明，见 §7 |
| `theme` | | 主题声明，见 §7 |

### 3.2 settings（扩展设置）

```json
{
  "settings": [
    { "key": "prefix", "label": "前缀", "type": "text", "default": "Hello",
      "placeholder": "例如 你好", "description": "问候前缀" },
    { "key": "uppercase", "label": "全部大写", "type": "boolean", "default": false },
    { "key": "count", "label": "次数", "type": "number", "default": 3 },
    { "key": "mode", "label": "语气", "type": "select", "default": "friendly",
      "options": ["friendly", "formal", "laconic"] }
  ]
}
```

- `type`：`text` | `boolean` | `number` | `select`（`select` 必须给出 `options`）。
- 用户在 **Extensions → 该插件 → ⚙️** 修改；存 UserDefaults，按 `插件id.键` 隔离。
- 脚本读取：`minis.api.settings.get(key)`；写入：`minis.api.settings.set(key, value)`；
  全部：`minis.api.settings.all()`。未设置的键返回声明里的 `default`。

### 3.3 tools（Agent 工具）

```json
{ "file": "agent/tools/foo.js", "name": "foo", "description": "做什么",
  "schema": { "type": "object", "properties": { "x": { "type": "string" } } },
  "language": "js" }
```

- `language` 可省略（默认 `js`）；`lua` 则加载 `.lua` 文件。
- `schema` 会附在模型可见的工具说明里（帮助模型正确传参）。
- 工具在模型侧的名字是 `extension_<id>_<name>`；模型传参为 `{tool_title, args}`，
  宿主把 `args`（JSON 字符串或对象）解包后交给你的 `execute(args)`。

### 3.4 commands（斜杠命令）

```json
{ "file": "agent/commands/foo.js", "name": "ext-foo", "description": "说明", "language": "js" }
```

- 建议以 `ext-` 开头以避免和内置命令（`/compact` 等）重名。
- 打字 `/ext-foo a b` → handler 收到 `["a", "b"]`；在 `/` 菜单点选该行会帮你填入 `/ext-foo `。

### 3.5 hooks（事件钩子）

```json
{ "file": "agent/hooks/log.js", "events": ["agent_start", "tool_call"], "language": "js" }
```

- `events` 只是声明/展示；实际订阅以脚本里的 `minis.on(...)` 为准。
- 内建事件与载荷见 §4.4。

---

## 4. Agent 侧 JS API 完整参考

> 运行时：**JavaScriptCore**（iOS 自带）。每个插件一个独立 JSContext，
> 同一插件的所有脚本共享同一全局作用域；加载顺序为 tools → commands → hooks。

### 4.1 注册函数（加载时调用一次）

```js
minis.registerTool({ name, description, execute })
// execute(args) -> string | object | Promise<string|object>
// - 返回值直接作为工具结果交给模型；对象会被 JSON.stringify。
// - 抛异常或 Promise reject → 工具失败，错误文本返回给模型。

minis.registerCommand({ name, description, handler })
// handler(args: string[]) -> string | Promise<string>
// - 返回值以系统消息形式显示在聊天中。

minis.on(event: string, handler(event: object))
// 订阅内建或自定义事件；同一事件可注册多个 handler。
```

### 4.2 工具调用约定（模型视角）

- 工具以 `extension_<id>_<name>` 出现在模型工具列表里。
- 模型传入 `{ "tool_title": "…", "args": "{\"name\":\"Bob\"}" }`；
  宿主解析 `args` 后调用你的 `execute({ name: "Bob" })`。
- 若模型偷懒直接把参数平铺（没有 `args` 字段），宿主会把除 `tool_title` 外的字段整体传入。
- 返回 `"Error: ..."` 不算失败；要表达失败请 `throw new Error("...")` 或返回被 reject 的 Promise。

### 4.3 命令调用约定（用户视角）

- 用户输入 `/ext-hello Alice Bob` → `handler(["Alice", "Bob"])`。
- 命令输出以 `Extension command: <name>` 系统消息展示。
- 命令不会发给模型（除非你把内容再发出去）。

### 4.4 事件（内建）

| 事件 | 触发时机 | 载荷 |
|---|---|---|
| `agent_start` | 每轮 agent 循环开始 | `{ sessionId, round }` |
| `agent_end` | 每轮 agent 循环结束（成功或失败） | `{ sessionId, round }` |
| `tool_call` | 任一工具调用**派发前**（含内置工具） | `{ sessionId, tool, toolId, args }` |
| `tool_result` | 任一工具调用**完成后** | `{ sessionId, tool, toolId, success, output }`（output 截断至 2000 字符） |

自定义事件：`minis.api.event.emit(name, data)` 会派发给所有订阅了该 `name` 的插件（包括自己）。

### 4.5 日志与存储

```js
minis.log("hello", 42, { a: 1 }, ["x", "y"])   // 变参；非字符串会被序列化，空格分隔
// 输出到「Extensions → 📜 调试日志」以及系统日志（分类 Ext[<id>]）。

minis.store.get(key)          // -> string | null（未设置返回 null）
minis.store.set(key, value)   // value 会被转成字符串；传 null 删除
```

### 4.6 主机 API（`minis.api.*`）

> 除特别说明外都返回 **Promise**；失败时 reject（错误文本为字符串）。

| API | 说明 |
|---|---|
| `minis.api.shell(cmd, {timeout})` | 在沙箱（Alpine/iSH）执行 shell。`timeout` 秒，默认 900。resolve 输出文本。需 `shell` 权限 |
| `minis.api.file.read(path)` | 读文件 → 文本。需 `files` 权限 |
| `minis.api.file.write(path, content)` | 写文件（自动建父目录）→ 描述性文本。需 `files` 权限 |
| `minis.api.file.list(path)` | 列目录 → JSON 字符串 `[{name, isDirectory, size}]`。需 `files` 权限 |
| `minis.api.file.delete(path)` | 删除文件/目录。需 `files` 权限 |
| `minis.api.permission.request(kind)` | 主动申请权限 → `boolean`（复用系统确认弹窗） |
| `minis.api.settings.get(key)` | 读取设置（无则返回 default） |
| `minis.api.settings.set(key, value)` | 写入设置 |
| `minis.api.settings.all()` | 全部设置 → 对象 |
| `minis.api.event.emit(name, data)` | 扩展间事件总线 |
| `minis.api.offload(name, args)` | 把 `name args` 当作 shell 命令执行（apple-* CLI 等）。需 `shell` 权限 |
| `minis.api.ui.postMessage(data)` | 广播消息给本插件的 WebView 组件（可用 `minis.api.ui(data)` 简写） |
| `minis.http.fetch(url, {method, headers, body})` | HTTP 请求 → `{status, headers, body}`。需 `network` 权限 |
| `minis.api.request.intercept(handler)` | **请求拦截**，见 §4.7。需 `requests` 权限 |

**文件路径规则（重点）**：文件 API 只接受 `/var/minis/` 开头的路径，映射到以下真实位置：

| 路径 | 生命周期 | 真实位置 |
|---|---|---|
| `/var/minis/shared/**` | 持久（跨会话共享） | App Group 共享目录 |
| `/var/minis/memory/**` | 持久 | 记忆目录 |
| `/var/minis/skills/**` | 持久 | 技能目录 |
| `/var/minis/workspace/**` | 当前会话 | 会话工作目录 |
| `/var/minis/attachments/**` | 当前会话 | 会话附件目录 |
| `/var/minis/offloads/**` | 当前会话 | 会话 offload 目录 |
| `/var/minis/browser/**` | 当前会话 | 浏览器下载/截图目录 |

### 4.7 请求拦截（1.13.2 引入，1.14 起继续提供）

插件可以改写**发往 AI 模型服务**的 HTTP 请求——URL、方法、请求头、请求体。
这使纯 JS 插件可以完成以前必须借助本地代理才能做的事：注入自定义请求头、
把 Base URL 指向自建网关、按模型改写请求体等。

```js
// 注册拦截器（可在脚本顶层执行，加载即生效）：
var id = minis.api.request.intercept(function (req) {
  // req = { provider, model, sessionId?, url, method, headers, body? }
  //   provider: "openai" | "anthropic" | "gemini" | "antigravity"
  //   body 仅在请求体是合法 UTF-8 文本时存在（二进制体不暴露）
  // 三种写法任选：
  //   1) 原地修改 req（如 req.headers["X-Foo"] = "1"）
  //   2) 返回 patch 对象（与原地修改可叠加，patch 优先）
  //   3) 返回 Promise<patch>（异步，60 秒超时）
  return {
    url: req.url,                       // 改 URL（如把官方域名换成自建网关）
    method: "POST",                     // 改方法
    headers: { "X-Plugin-Tag": "demo",  // 与现有头合并；值写 null = 删除该头
               "X-Old-Header": null },
    body: "…",                          // 直接替换请求体（字符串）
    bodyJSON: { model: req.model }      // 或给对象：宿主自动 JSON.stringify
  };
});

minis.api.request.unintercept(id);      // 按注册 id 取消
minis.api.request.clear();              // 取消本插件全部拦截器
```

要点：

- **能力范围**：覆盖 OpenAI 兼容通道（对话/Responses/透传/图片生成与编辑）、
  Anthropic（含 OAuth 流式）、Gemini、Antigravity。
- **权限**：需在 manifest 声明 `"requests"`；首次真正拦到请求时会弹一次确认，允许后**长期保留**。
  未声明/被拒绝时拦截器被跳过（不报错）。
- **只读不写**：不修改就返回 patch 的拦截器不会影响请求，可当观察钩子用。
- **多插件**：按插件 id 排序依次应用；单个插件内按注册顺序。
- **注意**：拦截器在模型请求发出前运行，不要在其中调用 `minis.api.shell` 长任务，
  必要时用 `Promise` 快速返回。

示例：给所有 OpenAI 请求加一个请求头（完整示例见 `examples/request-interceptor/`）：

```js
minis.api.request.intercept(function (req) {
  if (req.provider !== "openai") return null;
  return { headers: { "X-Plugin-Tag": "minis-open" } };
});
```

### 4.8 JS 运行环境限制（重要）

JavaScriptCore **不是浏览器、也不是 Node.js**。以下 API **不存在**，用了会 `ReferenceError`：

- `fetch` / `XMLHttpRequest` / `WebSocket` → 用 `minis.http.fetch`
- `setTimeout` / `setInterval` / `queueMicrotask` → 用 `Promise`
- `require` / `module` / `import`（JS 模块） → 同一插件所有脚本共享全局作用域
- `URL` / `URLSearchParams` / `atob` / `btoa` / `TextEncoder` / `TextDecoder`
- `localStorage` / `sessionStorage` → 用 `minis.store`
- `document` / `window` / DOM（组件 HTML 里才有 DOM，脚本里没有）

**可用**：`Promise`、`async/await`、类、可选链 `?.`、展开、解构、模板字符串、
`Map/Set`、`Proxy/Reflect`、`BigInt`、`Intl`、生成器、`Object.fromEntries`、
`Array.prototype.at/flat`、`String.replaceAll/matchAll/padStart` 等现代特性。

---

## 5. 权限模型

| 权限 | 覆盖范围 | 首次使用行为 |
|---|---|---|
| `shell` | `api.shell`、`api.offload` | 弹窗确认；允许后**跨启动保留** |
| `files` | `api.file.*` | 弹窗确认；允许后跨启动保留 |
| `network` | `minis.http.fetch` | 仅需在 manifest 声明（不弹窗） |
| `requests` | `api.request.intercept` | 首次拦截请求时弹窗；允许后跨启动保留 |
| `ui` | 渲染 WebView 组件 | 首次渲染时弹窗；允许后跨启动保留 |

- 拒绝的记录仅当次启动有效（下次会再问）；**卸载**（及卸载后重装）会清空已授予的权限，
  覆盖升级（同 id 新版本）保留已授予的权限。
- **未声明**的权限直接拒绝（错误文本提示"declare it in manifest.json"），不会弹窗。
- 确认弹窗 30 秒无操作视为拒绝。

---

## 6. 生命周期：安装 / 更新 / 停用 / 卸载 / 调试

| 操作 | 行为 |
|---|---|
| 安装 | 校验 zip → 解析 manifest → 解压到 `Library/MinisChat/extensions/<id>/` → 校验引用文件 → 注册并启用。同 id 同版本拒绝安装 |
| 打开入口 | **设置 → Agent Runtime → Extensions**（或深链 `minis://extensions`；聊天里输 `/extensions` 也可） |
| 更新 | 同 id 不同版本 = 覆盖安装（保留设置与 KV 存储） |
| 停用/启用 | Extensions 页开关；停用后工具/命令/组件立即从 agent 与 UI 移除 |
| 卸载 | 删除注册 + 目录 + 已授予权限 |
| 调试日志 | Extensions 右上角 📜（scroll 图标，或 `minis://extensions/debug`）；显示加载错误、工具/命令调用、`minis.log` 输出 |
| 加载报错 | 设置页内联显示（manifest 缺失/引用文件缺失/id 冲突等）；脚本语法错误记录在日志里，修好后停用再启用即重载 |

---

## 7. UI 侧：WebView 组件与主题

### 7.1 WebView 组件

`ui/widget.html` 在 WKWebView 中渲染，展示在聊天页 **… 菜单 → Extension Widgets**。
首次渲染会确认 `ui` 权限。组件与 native 的双向通信协议：

```html
<script>
  // 组件 → native（宿主会显示在组件面板的调试行，也可以在你的逻辑里用作回传）
  window.minisBridge.postMessage({ type: "hello", text: "from widget" });

  // native → 组件（来源：agent 脚本里的 minis.api.ui.postMessage(data)）
  window.minisBridge.onMessage = function (data) {
    console.log("native said:", data);
  };

  // 桥就绪后的首次回调（可选）
  window.minisBridge.onReady(function () {
    document.getElementById("out").textContent = "bridge ready";
  });
</script>
```

### 7.2 主题

`ui/theme.json` 声明语义色，聊天 UI 实时应用（无需重启）：

```json
{
  "name": "Solarized Dark",
  "scope": "chat",
  "tokens": {
    "background": "#002B36",
    "secondaryBackground": "#073642",
    "inputBackground": "#073642",
    "text": "#93A1A1",
    "textSecondary": "#839496",
    "userBubble": "#073642",
    "accent": "#268BD2"
  }
}
```

可用 token 以聊天界面实际读取的为准：`background`、`secondaryBackground`、
`inputBackground`、`text`、`textSecondary`、`userBubble`、`accent`。

---

## 8. Lua 运行时（可选）

同一套 `minis.*` 思路，但 **Lua 5.4** 语法；函数名用下划线风格。
Lua 调用是**同步**的（不需要 Promise）。支持子集：

```lua
-- 注册
minis.register_tool({ name = "lua_greet", description = "问候",
  execute = function(args) return "Hello, " .. (args.name or "world") end })
minis.register_command({ name = "ext-lua", description = "说明",
  handler = function(args)   -- args 是 1 起始的数组表
    return "first=" .. tostring(args[1])
  end })
minis.on("agent_start", function(event) minis.log("started", event.sessionId) end)

-- 日志
minis.log("hello", 42)

-- 主机 API（全部同步返回）
minis.api.shell("uname -s", { timeout = 15 })        -- string
minis.api.file.read("/var/minis/shared/x.txt")       -- string
minis.api.file.write("/var/minis/shared/x.txt", "hi")
minis.api.file.list("/var/minis/shared")             -- JSON 字符串
minis.api.file.delete("/var/minis/shared/x.txt")
minis.api.permission.request("shell")                -- boolean
minis.api.settings.get("prefix")                     -- 值 | nil
minis.api.settings.set("prefix", "Hi")
minis.api.settings.all()                             -- 表
```

Lua 当前**没有**：`store`、`http.fetch`、`offload`、`ui`、`event.emit`、
请求拦截（`request.intercept`）。需要这些能力时请用 JS 运行时。
（标准库 `string`/`table`/`math`/`os`/`io` 等可用。）

---

## 9. 示例索引

| 示例 | 内容 |
|---|---|
| `examples/demo-extension/` | 三工具（异步问候 + 组件通知 + 文件 API）+ 异步命令 + 四个事件钩子 + 组件 + 主题 |
| `examples/request-interceptor/` | **请求拦截**：按 provider 注入请求头；设置页可开关、可改标签；默认把每条被拦截/跳过的请求写进调试日志（可关） |
| `examples/lua-demo/` | Lua 工具 + Lua 命令（含沙箱 shell 调用） |

自测（开发者在 Mac 上跑，编译真实运行时并跑 40+ 项断言）：

```bash
./scripts/extension-smoke/run.sh
```

---

## 10. 常见陷阱（写给作者和 AI）

1. **不要用 `fetch`/`setTimeout`/`require`** —— JavaScriptCore 里都不存在（见 §4.8）。
2. **工具 handler 收到的是解包后的参数对象**，不是 `{tool_title, args}` 包装。
3. **命令 handler 收到的是字符串数组**（按空格切分），不是原始输入行。
4. **文件 API 只接受 `/var/minis/` 路径**，其它路径一律拒绝。
5. **能力必须先在 manifest 声明**，否则调用直接被拒（错误文本会提示）。
6. **请求拦截需要 `requests` 权限**；不声明时拦截器静默跳过。
7. **二进制请求体（如图片 multipart）不会以文本暴露**；不要盲目对 `body` 做 `JSON.parse`，
   先判空。改写请求体时用 `bodyJSON` 返回对象最稳妥。
8. **`headers` patch 合并而非替换**；删除某个头把值写成 `null`。
9. **同 id 同版本无法覆盖安装**；改代码时记得提升 `version`。
10. **`minis.log` 输出在调试面板**，写插件时用它排查比 `throw` 更省事。

---

## 11. 提示词模板（把它交给 AI 写插件）

使用方法：把**本文件全文**（或至少第 3–8 节）连同下面这段模板一起发给 AI，
在【我的需求】处描述你想要的插件，AI 就能输出可直接打包安装的完整插件。

```text
你是一名 minis-open（iOS AI 助手）插件开发者。请根据我的需求，写出一个完整的 .minisx 插件。

【输出要求】
1. 先给出目录树，再按文件逐个给出完整内容（manifest.json 与全部脚本，用代码块）。
2. 最后给出一句打包命令：./scripts/build_extension.sh <目录> <输出>.minisx

【硬性规则】
- 只用文档里列出的 minis API；禁止使用 fetch、XMLHttpRequest、setTimeout、setInterval、
  require、import、URL、atob/btoa、localStorage、document/window（JS 运行在 JavaScriptCore，
  没有浏览器与 Node API）。异步一律用 Promise / async-await。
- manifest.json 必须含 id（com.example.xxx 形式、仅字母数字.-_）、name、version、
  kinds、permissions；声明了什么能力才允许调用对应 API（shell/files/network/requests/ui）。
- 工具名用 snake_case；命令名以 ext- 开头；工具与命令的 name 要和脚本里注册的 name 一致。
- 工具 handler 收到的是模型参数对象（宿主已解包 args）；命令 handler 收到按空格切分的
  字符串数组。两者都可以直接返回字符串或 Promise；失败请 throw / reject。
- 文件读写只用 /var/minis/ 开头的路径（shared/memory/skills 持久，workspace/attachments/
  offloads/browser 会话级）。
- 需要改写模型请求（注入请求头、改 Base URL、改请求体）时，用
  minis.api.request.intercept，并在 permissions 里声明 "requests"。
- 代码里不要写 "tool_title" 处理逻辑；那是宿主与模型之间的包装。

【我的需求】
<在这里描述插件：功能、触发方式（工具/命令/钩子/组件）、需要的权限、界面文案等>
```
