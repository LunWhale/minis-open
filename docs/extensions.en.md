# minis-open Plugin (Extension) Development Guide

> Applies to **minis-open 1.14+ (iOS)**.
> One plugin = one `.minisx` file (a zip) = `manifest.json` + scripts/assets.
> Agent-side scripts run in **JavaScriptCore** (nothing to do with a browser);
> a bundled **Lua 5.4** runtime is also supported.
> After reading this you can build a working plugin from scratch. The file ends
> with an **AI prompt template** you can paste into any AI to have it write one.

---

## 1. What Plugins Can Do

| Capability | `kinds` value | Description |
|---|---|---|
| Agent tool | `agent-tool` | A tool the model can call in chat (namespaced `extension_<id>_<name>`) |
| Slash command | `command` | A `/name` command the user runs with args; also listed in the `/` menu |
| Event hook | `event-hook` | Subscribe to lifecycle events (`agent_start` / `agent_end` / `tool_call` / `tool_result`) and custom events |
| **Request interception** | any kind (register from any loaded script; a hooks file is typical) | **New in 1.13.2**: rewrite outgoing model requests (URL / method / headers / body); needs the `requests` permission |
| UI widget | `ui-widget` | A WKWebView panel in the chat, with two-way messaging |
| Theme | `theme` | Semantic color tokens applied to the native chat UI live |
| Extension settings | (supporting) | Declare settings in the manifest; users edit them via ⚙️; scripts read them |
| KV store | (supporting) | Per-plugin key/value persistence |
| Host APIs | (supporting) | Sandbox shell, file I/O, HTTP, permission prompts, cross-plugin event bus |

---

## 2. Five-Minute Quick Start

### 2.1 Layout

```
my-plugin/                  ← packaged as my-plugin.minisx (zip)
├── manifest.json           ← required
├── agent/
│   ├── tools/hello.js      ← tool (minis.registerTool)
│   ├── commands/hello.js   ← command (minis.registerCommand)
│   └── hooks/log.js        ← event hook (minis.on)
├── ui/
│   ├── widget.html         ← WebView widget (optional)
│   └── theme.json          ← theme (optional)
└── assets/                 ← other resources (optional)
```

### 2.2 Minimal manifest.json

```json
{
  "id": "com.example.hello",
  "name": "Hello Plugin",
  "version": "1.0.0",
  "description": "Demo: one command + one tool + one hook",
  "author": "you",
  "kinds": ["agent-tool", "command", "event-hook"],
  "permissions": ["shell"],
  "tools": [
    {
      "file": "agent/tools/hello.js",
      "name": "hello_world",
      "description": "Returns a greeting.",
      "schema": {
        "type": "object",
        "properties": { "name": { "type": "string", "description": "Who to greet" } }
      }
    }
  ],
  "commands": [
    { "file": "agent/commands/hello.js", "name": "ext-hello", "description": "Say hello" }
  ],
  "hooks": [
    { "file": "agent/hooks/log.js", "events": ["agent_start", "tool_call"] }
  ]
}
```

### 2.3 Three scripts

`agent/tools/hello.js`:

```js
// A tool handler receives the model's args object (the host unwraps it).
// Return a string or a Promise; throwing marks the tool as failed.
minis.registerTool({
  name: "hello_world",
  description: "Returns a greeting.",
  execute: function (args) {
    var who = (args && args.name) || "world";
    return "Hello, " + who + "!";
  },
});
```

`agent/commands/hello.js`:

```js
// A command handler receives whitespace-split args: /ext-hello Alice → ["Alice"]
// The return value is shown in chat as a system message.
minis.registerCommand({
  name: "ext-hello",
  description: "Says hello.",
  handler: function (args) {
    var who = (args && args.length ? args.join(" ") : "world");
    return "Hello, " + who + "!";
  },
});
```

`agent/hooks/log.js`:

```js
// Hooks are evaluated once at load time; the handlers registered here run
// when the events fire.
minis.on("agent_start", function (event) {
  minis.log("[hello] round", event.round, "session", event.sessionId);
});
minis.on("tool_call", function (event) {
  minis.log("[hello] tool", event.tool, "args", event.args);
});
```

### 2.4 Package

```bash
# Recommended: the repo script validates the manifest and adds a
# compatibility entry automatically.
./scripts/build_extension.sh my-plugin my-plugin.minisx

# Manual equivalent (manifest.json must be at the zip root)
cd my-plugin && zip -r ../my-plugin.minisx .
```

### 2.5 Install and verify

1. Get the `.minisx` onto the iPhone (AirDrop / Files / iCloud).
2. In the app: **Settings → Agent Runtime → Extensions → ➕ (top-right) → pick the file**. Enabled on install.
3. In chat, type `/ext-hello Alice` and send → a `Extension command: ext-hello`
   system message appears with the greeting.
4. Ask the model to use the `hello_world` tool.
5. If anything fails, open **Extensions → 📜 (debug log)** and read the load errors.
   (The `minis://extensions` deep link opens the manager directly too.)

---

## 3. Bundle Format and Manifest Reference

### 3.1 Top-level fields

| Field | Required | Notes |
|---|---|---|
| `id` | ✅ | Globally unique; `[A-Za-z0-9.-_]` only; used as the directory name and tool namespace prefix |
| `name` / `version` | ✅ | Display name / version. Same id + same version is rejected; a different version = upgrade (overwrite) |
| `description` / `author` | | Display only |
| `kinds` | ✅ | Capability declaration: `agent-tool` `command` `event-hook` `ui-widget` `theme` |
| `permissions` | ✅ | Permission declaration: `shell` `files` `network` `requests` `ui` (see §5) |
| `settings` | | Setting declarations, see §3.2 |
| `tools` | | Tool declarations, see §3.3 |
| `commands` | | Command declarations, see §3.4 |
| `hooks` | | Hook declarations, see §3.5 |
| `ui` | | WebView widget declarations, see §7 |
| `theme` | | Theme declaration, see §7 |

### 3.2 settings

```json
{
  "settings": [
    { "key": "prefix", "label": "Prefix", "type": "text", "default": "Hello",
      "placeholder": "e.g. Hey", "description": "Greeting prefix" },
    { "key": "uppercase", "label": "Uppercase", "type": "boolean", "default": false },
    { "key": "count", "label": "Count", "type": "number", "default": 3 },
    { "key": "mode", "label": "Tone", "type": "select", "default": "friendly",
      "options": ["friendly", "formal", "laconic"] }
  ]
}
```

- `type`: `text` | `boolean` | `number` | `select` (`select` requires `options`).
- Users edit them under **Extensions → plugin → ⚙️**; stored in UserDefaults,
  namespaced per plugin.
- Scripts read with `minis.api.settings.get(key)`, write with
  `minis.api.settings.set(key, value)`, or read all with
  `minis.api.settings.all()`. Missing values return the declared `default`.

### 3.3 tools

```json
{ "file": "agent/tools/foo.js", "name": "foo", "description": "What it does",
  "schema": { "type": "object", "properties": { "x": { "type": "string" } } },
  "language": "js" }
```

- `language` defaults to `js`; set `lua` to load a `.lua` file.
- `schema` is appended to the model-visible tool description (helps the model
  pass the right arguments).
- The model sees the tool as `extension_<id>_<name>` and calls it with
  `{tool_title, args}`; the host unwraps `args` (JSON string or object) and
  hands it to your `execute(args)`.

### 3.4 commands

```json
{ "file": "agent/commands/foo.js", "name": "ext-foo", "description": "…", "language": "js" }
```

- Prefix with `ext-` to avoid clashing with built-in commands (`/compact`, ...).
- Typing `/ext-foo a b` → handler receives `["a", "b"]`; tapping the row in the
  `/` menu fills the composer with `/ext-foo `.

### 3.5 hooks

```json
{ "file": "agent/hooks/log.js", "events": ["agent_start", "tool_call"], "language": "js" }
```

- `events` is declarative; the actual subscriptions are the `minis.on(...)`
  calls in the script.
- Built-in events and payloads: §4.4.

---

## 4. Agent-Side JS API Reference

> Runtime: **JavaScriptCore** (built into iOS). Each plugin gets its own
> JSContext; all files of one plugin share one global scope. Load order:
> tools → commands → hooks.

### 4.1 Registration (called once at load time)

```js
minis.registerTool({ name, description, execute })
// execute(args) -> string | object | Promise<string|object>
// - The return value is handed to the model as the tool result; objects are
//   JSON-stringified.
// - Throw / reject to mark the tool as failed (the error text goes to the model).

minis.registerCommand({ name, description, handler })
// handler(args: string[]) -> string | Promise<string>
// - The return value is shown in chat as a system message.

minis.on(event: string, handler(event: object))
// Subscribe to built-in or custom events; multiple handlers per event allowed.
```

### 4.2 Tool calling convention (model side)

- The model sees the tool as `extension_<id>_<name>`.
- The model sends `{ "tool_title": "…", "args": "{\"name\":\"Bob\"}" }`; the
  host parses `args` and calls `execute({ name: "Bob" })`.
- If the model flattens the arguments (no `args` field), the host passes
  everything except `tool_title` as the args object.
- Returning `"Error: ..."` is not failure; to signal failure `throw` or reject.

### 4.3 Command calling convention (user side)

- `/ext-hello Alice Bob` → `handler(["Alice", "Bob"])`.
- Output is shown as an `Extension command: <name>` system message.
- Commands are not sent to the model (unless you route them there yourself).

### 4.4 Events (built-in)

| Event | When | Payload |
|---|---|---|
| `agent_start` | Start of every agent loop round | `{ sessionId, round }` |
| `agent_end` | End of every round (success or failure) | `{ sessionId, round }` |
| `tool_call` | Before any tool call is dispatched (built-ins included) | `{ sessionId, tool, toolId, args }` |
| `tool_result` | After any tool call completes | `{ sessionId, tool, toolId, success, output }` (output capped at 2000 chars) |

Custom events: `minis.api.event.emit(name, data)` reaches every plugin that
subscribed to that `name` (including the emitter).

### 4.5 Logging and storage

```js
minis.log("hello", 42, { a: 1 }, ["x", "y"])   // variadic; non-strings serialized, space-joined
// Goes to Extensions → 📜 debug log and the system log (category Ext[<id>]).

minis.store.get(key)          // -> string | null (null when unset)
minis.store.set(key, value)   // value is stringified; pass null to delete
```

### 4.6 Host APIs (`minis.api.*`)

> All return **Promises** unless noted; failures reject with a string.

| API | Description |
|---|---|
| `minis.api.shell(cmd, {timeout})` | Run a shell command in the sandbox (Alpine/iSH). `timeout` in seconds, default 900. Resolves with output. Needs `shell` |
| `minis.api.file.read(path)` | Read a file → text. Needs `files` |
| `minis.api.file.write(path, content)` | Write a file (parents auto-created) → descriptive text. Needs `files` |
| `minis.api.file.list(path)` | List a directory → JSON string `[{name, isDirectory, size}]`. Needs `files` |
| `minis.api.file.delete(path)` | Delete a file/directory. Needs `files` |
| `minis.api.permission.request(kind)` | Ask for a permission → `boolean` (reuses the native prompt) |
| `minis.api.settings.get(key)` | Read a setting (falls back to `default`) |
| `minis.api.settings.set(key, value)` | Persist a setting |
| `minis.api.settings.all()` | All settings → object |
| `minis.api.event.emit(name, data)` | Cross-plugin event bus |
| `minis.api.offload(name, args)` | Runs `name args` as a shell command (apple-* CLIs etc.). Needs `shell` |
| `minis.api.ui.postMessage(data)` | Broadcast to this plugin's WebView widgets (`minis.api.ui(data)` works too) |
| `minis.http.fetch(url, {method, headers, body})` | HTTP request → `{status, headers, body}`. Needs `network` |
| `minis.api.request.intercept(handler)` | **Request interception**, see §4.7. Needs `requests` |

**File path rules (important)**: the file APIs only accept `/var/minis/` paths,
which map to real locations:

| Path | Lifetime | Real location |
|---|---|---|
| `/var/minis/shared/**` | Persistent (shared across sessions) | App Group shared dir |
| `/var/minis/memory/**` | Persistent | Memory dir |
| `/var/minis/skills/**` | Persistent | Skills dir |
| `/var/minis/workspace/**` | Current session | Session workspace |
| `/var/minis/attachments/**` | Current session | Session attachments |
| `/var/minis/offloads/**` | Current session | Session offloads |
| `/var/minis/browser/**` | Current session | Browser downloads/screenshots |

### 4.7 Request interception (introduced in 1.13.2, still current in 1.14)

Plugins can rewrite the HTTP requests sent to AI model providers — URL, method,
headers and body. This lets a pure-JS plugin do what previously required a local
proxy: inject custom headers, point the base URL at your own gateway, tweak the
request body per model, and so on.

```js
// Register an interceptor (at script top level; takes effect on load):
var id = minis.api.request.intercept(function (req) {
  // req = { provider, model, sessionId?, url, method, headers, body? }
  //   provider: "openai" | "anthropic" | "gemini" | "antigravity"
  //   body exists only when the request body is valid UTF-8 (binary bodies are omitted)
  // Any of the three styles:
  //   1) mutate req in place (e.g. req.headers["X-Foo"] = "1")
  //   2) return a patch object (merged over in-place mutations; patch wins)
  //   3) return a Promise<patch> (async, 60s timeout)
  return {
    url: req.url,                       // change the URL (e.g. your own gateway)
    method: "POST",                     // change the method
    headers: { "X-Plugin-Tag": "demo",  // merged into existing headers; null deletes a header
               "X-Old-Header": null },
    body: "…",                          // replace the raw body (string)
    bodyJSON: { model: req.model }      // or pass an object: the host JSON-stringifies it
  };
});

minis.api.request.unintercept(id);      // remove one interceptor by id
minis.api.request.clear();              // remove all of this plugin's interceptors
```

Key points:

- **Coverage**: the OpenAI-compatible path (chat / Responses / raw passthrough /
  image generation and edits), Anthropic (including OAuth streaming), Gemini,
  and Antigravity.
- **Permission**: declare `"requests"` in the manifest; the first actual
  intercepted request prompts once, and the grant **persists across launches**.
  Without the declaration (or if denied) interceptors are skipped silently.
- **Read-only use**: an interceptor that returns nothing still works as an
  observation hook.
- **Ordering**: extensions are applied in id order; within one plugin,
  registration order.
- **Note**: interceptors run right before the model request is sent. Avoid long
  `minis.api.shell` work inside them; return quickly (a Promise is fine).

Example — add a header to all OpenAI requests (full version in
`examples/request-interceptor/`):

```js
minis.api.request.intercept(function (req) {
  if (req.provider !== "openai") return null;
  return { headers: { "X-Plugin-Tag": "minis-open" } };
});
```

### 4.8 JavaScript environment limits (important)

JavaScriptCore is **not a browser and not Node.js**. The following do **not
exist** and will throw `ReferenceError`:

- `fetch` / `XMLHttpRequest` / `WebSocket` → use `minis.http.fetch`
- `setTimeout` / `setInterval` / `queueMicrotask` → use `Promise`
- `require` / `module` / `import` (ES modules) → all files of a plugin share
  one global scope
- `URL` / `URLSearchParams` / `atob` / `btoa` / `TextEncoder` / `TextDecoder`
- `localStorage` / `sessionStorage` → use `minis.store`
- `document` / `window` / DOM (the DOM exists only inside widget HTML, not in
  scripts)

**Available**: `Promise`, `async/await`, classes, optional chaining `?.`,
spread, destructuring, template literals, `Map/Set`, `Proxy/Reflect`, `BigInt`,
`Intl`, generators, `Object.fromEntries`, `Array.prototype.at/flat`,
`String.replaceAll/matchAll/padStart` and other modern features.

---

## 5. Permission Model

| Permission | Covers | First-use behavior |
|---|---|---|
| `shell` | `api.shell`, `api.offload` | Native prompt; granted grants persist across launches |
| `files` | `api.file.*` | Native prompt; grants persist |
| `network` | `minis.http.fetch` | Declaration only (no prompt) |
| `requests` | `api.request.intercept` | Prompted on the first intercepted request; grants persist |
| `ui` | Rendering a WebView widget | Prompted on first render; grants persist |

- A denied record lasts for the current launch only (asked again next launch);
  **uninstalling** (and reinstalling after an uninstall) clears granted
  permissions; a version upgrade keeps them.
- Calling an API whose permission was **not declared** is rejected immediately
  (the error says "declare it in manifest.json") — no prompt appears.
- The prompt auto-denies after 30 seconds of inaction.

---

## 6. Lifecycle: Install / Update / Disable / Uninstall / Debug

| Action | Behavior |
|---|---|
| Install | Validate zip → parse manifest → unpack to `Library/MinisChat/extensions/<id>/` → validate file references → register and enable. Same id + same version is rejected |
| Where to open | **Settings → Agent Runtime → Extensions** (or the `minis://extensions` deep link; the `/extensions` slash command works too) |
| Update | Same id, different version = overwrite install (settings and KV store are kept) |
| Disable/Enable | Toggle in the Extensions page; disabled plugins' tools/commands/widgets disappear immediately |
| Uninstall | Removes the registration, the directory, and granted permissions |
| Debug log | Extensions → 📜 (scroll icon, or `minis://extensions/debug`): load errors, tool/command invocations, `minis.log` output |
| Load errors | Shown inline in the settings page (missing manifest / missing referenced files / id conflicts); script syntax errors are logged — fix and toggle off/on to reload |

---

## 7. UI Side: WebView Widgets and Themes

### 7.1 WebView widgets

`ui/widget.html` renders in a WKWebView, shown under the chat **… menu →
Extension Widgets**. The first render prompts for the `ui` permission. The
two-way bridge protocol:

```html
<script>
  // widget → native (the host shows it in the widget panel's debug line and
  // you can use it for your own round-trips)
  window.minisBridge.postMessage({ type: "hello", text: "from widget" });

  // native → widget (from an agent script calling minis.api.ui.postMessage(data))
  window.minisBridge.onMessage = function (data) {
    console.log("native said:", data);
  };

  // optional: called once the bridge is live
  window.minisBridge.onReady(function () {
    document.getElementById("out").textContent = "bridge ready";
  });
</script>
```

### 7.2 Themes

`ui/theme.json` declares semantic colors; the chat UI applies them live
(no restart):

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

Supported tokens (what the chat UI actually reads): `background`,
`secondaryBackground`, `inputBackground`, `text`, `textSecondary`,
`userBubble`, `accent`.

---

## 8. Lua Runtime (optional)

Same `minis.*` ideas, **Lua 5.4** syntax, snake_case function names. Lua calls
are **synchronous** (no Promises). Supported subset:

```lua
-- registration
minis.register_tool({ name = "lua_greet", description = "greeting",
  execute = function(args) return "Hello, " .. (args.name or "world") end })
minis.register_command({ name = "ext-lua", description = "demo",
  handler = function(args)   -- args is a 1-based array table
    return "first=" .. tostring(args[1])
  end })
minis.on("agent_start", function(event) minis.log("started", event.sessionId) end)

-- logging
minis.log("hello", 42)

-- host APIs (all synchronous)
minis.api.shell("uname -s", { timeout = 15 })        -- string
minis.api.file.read("/var/minis/shared/x.txt")       -- string
minis.api.file.write("/var/minis/shared/x.txt", "hi")
minis.api.file.list("/var/minis/shared")             -- JSON string
minis.api.file.delete("/var/minis/shared/x.txt")
minis.api.permission.request("shell")                -- boolean
minis.api.settings.get("prefix")                     -- value | nil
minis.api.settings.set("prefix", "Hi")
minis.api.settings.all()                             -- table
```

Lua does **not** currently have: `store`, `http.fetch`, `offload`, `ui`,
`event.emit`, or request interception. Use the JS runtime for those.
(The standard libraries `string`/`table`/`math`/`os`/`io` etc. are available.)

---

## 9. Examples

| Example | Contents |
|---|---|
| `examples/demo-extension/` | Three tools (async greeting + widget notify + file API) + async command + four event hooks + widget + theme |
| `examples/request-interceptor/` | **Request interception**: inject a header per provider; toggleable in settings; by default each intercepted/skipped request is written to the debug log (can be turned off) |
| `examples/lua-demo/` | Lua tool + Lua command (including a sandbox shell call) |

Self-test (for developers on a Mac; compiles the real runtime and runs 40+
assertions):

```bash
./scripts/extension-smoke/run.sh
```

---

## 10. Common Pitfalls (for authors and AI)

1. **Don't use `fetch`/`setTimeout`/`require`** — none exist in JavaScriptCore (§4.8).
2. **A tool handler receives the unwrapped args object**, not the
   `{tool_title, args}` envelope.
3. **A command handler receives a string array** (whitespace-split), not the
   raw input line.
4. **File APIs only accept `/var/minis/` paths**; anything else is rejected.
5. **Declare every capability in the manifest** first, or the call is rejected
   with an error telling you to do so.
6. **Request interception needs the `requests` permission**; without it,
   interceptors are skipped silently.
7. **Binary request bodies (e.g. image multipart) are not exposed as text**;
   don't blindly `JSON.parse` the body — check it first. Returning `bodyJSON`
   is the safest way to rewrite a body.
8. **`headers` patches merge rather than replace**; set a value to `null` to
   delete a header.
9. **Same id + same version cannot be overwritten**; bump `version` when you
   change code.
10. **`minis.log` output appears in the debug panel** — it is the easiest way
    to debug a plugin.

---

## 11. AI Prompt Template (hand this to an AI to write a plugin)

How to use: give the AI **this whole document** (or at least §3–8) along with
the template below, and describe what you want in the "My requirement" slot.
The AI will then produce a complete, installable plugin.

```text
You are a plugin developer for minis-open (an iOS AI assistant app).
Write a complete .minisx plugin that fulfills my requirement.

[Output requirements]
1. First a directory tree, then the full contents of every file (manifest.json
   and all scripts), one code block per file.
2. Finish with the packaging command:
   ./scripts/build_extension.sh <dir> <output>.minisx

[Hard rules]
- Use ONLY the minis APIs listed in the document. Do NOT use fetch,
  XMLHttpRequest, setTimeout, setInterval, require, import, URL, atob/btoa,
  localStorage, document/window — scripts run in JavaScriptCore, which has no
  browser or Node APIs. Use Promise / async-await for asynchrony.
- manifest.json must include id (com.example.xxx form, [A-Za-z0-9.-_] only),
  name, version, kinds, permissions. Only declared capabilities may be used
  (shell/files/network/requests/ui).
- Tool names in snake_case; command names prefixed with ext-; the name in the
  manifest must match the name registered in the script.
- A tool handler receives the model's argument object (the host has already
  unwrapped `args`); a command handler receives a whitespace-split string
  array. Both may return a string or a Promise; signal failure by throwing /
  rejecting.
- File I/O only under /var/minis/ (shared/memory/skills are persistent;
  workspace/attachments/offloads/browser are per-session).
- To rewrite model requests (inject headers, change the base URL, edit the
  body), use minis.api.request.intercept and declare the "requests" permission.
- Never write code that handles "tool_title"; that envelope is between the
  host and the model.

[My requirement]
<describe the plugin here: what it does, how it is triggered (tool / command /
hook / widget), which permissions it needs, and any UI text>
```
