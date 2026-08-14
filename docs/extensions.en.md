# OpenMinis Extension System

> OpenMinis' extension system is an **independently designed** native extension
> framework: `.minisx` zip bundles that can extend both the **agent** (tools /
> commands / event hooks) and the **UI** (WebView widgets / themes), installed
> from a zip with no store review. Agent-side scripts run in JavaScriptCore
> (JS) or a vendored Lua 5.4 interpreter (Lua), in-process.

---

## 1. Quick Start

1. Write a folder containing `manifest.json` + scripts/assets (see §2).
2. Zip it: `zip -r my-extension.minisx .` (or use `scripts/build_extension.sh`).
3. In the app: **Settings → Agent Runtime → Extensions → "+"** pick the
   `.minisx` file.
4. It takes effect immediately: agent tools join the tool set, commands join
   the `/` menu, themes apply to the chat UI.

## 2. Bundle Format (.minisx = zip)

```
my-extension.minisx/
├── manifest.json            ← required
├── agent/                   ← agent side
│   ├── tools/xxx.js|lua     ← tools (minis.registerTool / register_tool)
│   ├── commands/xxx.js|lua  ← commands (minis.registerCommand / register_command)
│   └── hooks/xxx.js|lua     ← event hooks (minis.on)
├── ui/                      ← UI side
│   ├── widget.html          ← WebView widget
│   └── theme.json           ← theme
└── assets/                  ← other resources
```

### manifest.json

```json
{
  "id": "com.example.myext",
  "name": "My Extension",
  "version": "1.0.0",
  "description": "One-liner",
  "author": "you",
  "kinds": ["agent-tool", "command", "event-hook", "ui-widget", "theme"],
  "permissions": ["shell", "files", "ui"],
  "tools": [
    { "file": "agent/tools/hello.js", "name": "hello_world",
      "description": "Tool description", "schema": { "type": "object", "properties": {} } }
  ],
  "commands": [
    { "file": "agent/commands/hello.js", "name": "ext-hello", "description": "..." }
  ],
  "hooks": [
    { "file": "agent/hooks/log.js", "events": ["agent_start", "agent_end"] }
  ],
  "ui": [ { "type": "widget", "file": "ui/widget.html", "placement": "chat-panel" } ],
  "theme": { "file": "ui/theme.json", "scope": "chat" }
}
```

Field reference: `id` (unique, `[A-Za-z0-9.-_]`), `name`/`version` (required),
`kinds` (capability declarations), `permissions` (shell/files/network/ui/...),
`tools`/`commands`/`hooks`/`ui`/`theme` (optional). Each script entry accepts
an optional `language` field: `"js"` (default) or `"lua"`.

---

## 3. Agent Side: Dual Runtime (JS / Lua)

Agent-side scripts run in **JavaScriptCore** (`language: "js"`, default) or the
**vendored Lua 5.4** interpreter (`language: "lua"`), one isolated context per
extension. The `minis` global API is equivalent in both:

| API | Status | Description |
|---|---|---|
| `registerTool` / `register_tool` | ✅ | Register an agent tool (surfaced as `extension_<id>_<name>`) |
| `registerCommand` / `register_command` | ✅ | Register a `/` command (executes and echoes the result) |
| `on` | ✅ | Subscribe to lifecycle events (`agent_start` / `agent_end` fire every round) |
| `api.shell(cmd, {timeout})` | ✅ | Run a sandbox shell command (`shell` permission) |
| `api.file.read(path)` | ✅ | Read a sandbox file (`files` permission, `/var/minis/**`) |
| `api.file.write(path, content)` | ✅ | Write a sandbox file (`files` permission) |
| `api.permission.request(kind)` | ✅ | Ask for a permission (reuses OffloadPermissionDialog) |
| `api.event.emit(name, data)` | ✅ | Cross-extension event bus |
| `api.offload(name, args)` | ✅ | Bridge to sandbox commands (apple-* CLIs, `shell` permission) |
| `api.ui.postMessage(data)` | ✅ | Broadcast to this extension's rendered widgets |
| `store.get/set(key, value)` | ✅ | KV persistence (UserDefaults, per-extension scoped) |
| `http.fetch(url, {method, body})` | ✅ | HTTP via URLSession (`network` permission) |
| `log(...)` | ✅ | Log under `Ext[<id>]` / `ExtLua[<id>]` |

Permissions are declared in the manifest and confirmed on first use via the
standard dialog (30s timeout); undeclared permissions are rejected.

## 4. UI Side: WebView Widgets + Themes

**Widgets** (`ui/widget.html`) render in a WKWebView with a `window.minisBridge`
bridge: `postMessage(data)` widget→native, `onMessage = fn` native→widget.
Enabled widgets appear under the chat **… menu → Extension Widgets**; each
widget confirms the `ui` permission on first show. Agent-side
`minis.api.ui.postMessage` reaches the rendered widget live.

**Themes** (`ui/theme.json`) declare semantic color tokens; the native renderer
applies them reactively via `ThemeManager` (no restart). Tokens: `background`,
`text`, `textSecondary`, `accent`, `userBubble`, `inputBackground`, ...,
`scope: "chat"`.

## 5. Lifecycle & Permissions

Install → zip validation → manifest parse → unpack to
`Library/MinisChat/extensions/<id>/` → file-reference validation → register
(same id+version rejected). Enable/disable/uninstall from the manager. Updates
are overwrite installs. Security: isolated JS/Lua contexts + declared
permissions + first-use confirmation + audit log.

## 6. Examples

- `examples/demo-extension/` — tool + command + hook + widget + theme.
- `examples/lua-demo/` — Lua tool + Lua command.
- Build: `./scripts/build_extension.sh <src-dir> [output]`.

## 7. Debugging

- **Debug log panel**: scroll icon in the Extension Manager (or the
  `minis://extensions/debug` deep link) shows the last 500 entries.
- **`/extensions`** slash command opens the manager.
- Console categories: `Ext[<id>]` (JS), `ExtLua[<id>]` (Lua).
- Install errors surface inline in the manager; script syntax errors are
  logged at load time — toggle the extension off/on to reload after a fix.
