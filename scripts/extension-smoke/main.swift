import Foundation
import JavaScriptCore

// Smoke test against the REAL ExtensionJSRuntime.swift (compiled with stubs).
//
// Part A — runtime API surface (#25/#26):
//   - variadic minis.log (scalars / arrays / objects / zero-arg)
//   - async command results (Promise return values awaited)
//   - async tool results + Promise rejection
//   - request interception: patch return, in-place mutation, async patch,
//     unintercept, clear
//   - store get/set (UserDefaults roundtrip)
//   - event hooks fire and can write to the store
//   - settings.get bridge
//
// Part B — example plugins loaded with the real runtime (repo files):
//   - examples/request-interceptor: interceptor registers, header injected,
//     provider filter, enabled=false leaves request untouched, command output
//   - examples/demo-extension: tools/commands/hooks register, async command
//     args, file-api tool returns data, widget tool posts to UI

var pass = 0
var fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1; print("  [ok  ] \(name)") }
    else { fail += 1; print("  [FAIL] \(name) \(detail)") }
}

let repoRoot = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/Users/brooks/Documents/agentprojects/饭袋/OpenMinis"

// MARK: - Bridge mock

final class SettingsBox: @unchecked Sendable {
    static let shared = SettingsBox()
    private let lock = NSLock()
    private var values: [String: Any] = [
        "greeting": "hi",
        "count": 3,
        "greetingPrefix": "Hi",
        "uppercase": false,
        "replyMode": "friendly",
        "tag": "minis-open",
        "enabled": true,
        "provider": "openai",
    ]
    func get(_ key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func set(_ key: String, _ value: Any) { lock.lock(); values[key] = value; lock.unlock() }
}

final class UILog: @unchecked Sendable {
    static let shared = UILog()
    private let lock = NSLock()
    private(set) var messages: [[String: Any]] = []
    func post(_ payload: [String: Any]) { lock.lock(); messages.append(payload); lock.unlock() }
}

final class FileStore: @unchecked Sendable {
    static let shared = FileStore()
    private let lock = NSLock()
    private var files: [String: String] = ["/var/minis/shared/demo-notes/note.txt": "pre-existing note"]
    func read(_ path: String) -> String? { lock.lock(); defer { lock.unlock() }; return files[path] }
    func write(_ path: String, _ content: String) { lock.lock(); files[path] = content; lock.unlock() }
    func delete(_ path: String) { lock.lock(); files.removeValue(forKey: path); lock.unlock() }
    func list(_ dir: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return files.filter { $0.key.hasPrefix(dir + "/") }.map { entry in
            ["name": String(entry.key.dropFirst(dir.count + 1)), "isDirectory": false, "size": entry.value.count]
        }
    }
}

func makeBridge() -> ExtensionJSRuntime.Bridge {
    ExtensionJSRuntime.Bridge(
        shell: { cmd, _ in ("shell-ok:" + cmd, false) },
        fileRead: { path in
            if let content = FileStore.shared.read(path) { return (content, false) }
            return ("Error: cannot read \(path)", true)
        },
        fileWrite: { path, content, _ in
            FileStore.shared.write(path, content)
            return ("Wrote \(path) (\(content.count) chars)", false)
        },
        fileList: { path in
            let entries = FileStore.shared.list(path)
            if let data = try? JSONSerialization.data(withJSONObject: entries),
               let json = String(data: data, encoding: .utf8) { return (json, false) }
            return ("[]", false)
        },
        fileDelete: { path in
            FileStore.shared.delete(path)
            return ("Deleted \(path)", false)
        },
        requestPermission: { _ in true },
        hasPermission: { _ in true },
        postToUI: { _, payload in UILog.shared.post(payload) },
        emitEvent: { _, _ in },
        settingsGet: { _, key in SettingsBox.shared.get(key) },
        settingsSet: { _, key, value in SettingsBox.shared.set(key, value) },
        settingsAll: { _ in ["greeting": "hi"] }
    )
}

@discardableResult
func eval(_ rt: ExtensionJSRuntime, _ js: String, _ file: String) -> Bool {
    do { try rt.evaluateScript(js, fileName: file); return true }
    catch { print("EVAL FAIL \(file): \(error)"); return false }
}

func evalFile(_ rt: ExtensionJSRuntime, _ path: String) -> Bool {
    guard let source = try? String(contentsOfFile: repoRoot + "/" + path, encoding: .utf8) else {
        print("READ FAIL \(path)"); return false
    }
    return eval(rt, source, path)
}

func storeValue(_ key: String) -> String? {
    UserDefaults.standard.string(forKey: "ext.kv.smoke.\(key)")
}

// ============================ Part A ============================

let rt = ExtensionJSRuntime(extensionID: "smoke", bridge: makeBridge())

// ---- 1. variadic minis.log ----
LogSink.shared.reset()
eval(rt, "minis.log('hello', 42, {a: 1}, ['x','y']);", "log1.js")
eval(rt, "minis.log();", "log2.js")
eval(rt, "minis.log(['a']);", "log3.js")
let logLines = LogSink.shared.lines
check("minis.log variadic joined",
      logLines.contains(where: { $0.contains("hello 42") && $0.contains("x y") }),
      "lines=\(logLines)")
check("minis.log zero-arg no crash", logLines.contains(where: { $0 == "INFO " }), "lines=\(logLines)")
check("minis.log single array", logLines.contains(where: { $0 == "INFO a" }), "lines=\(logLines)")

// ---- 2. async commands ----
eval(rt, """
minis.registerCommand({
  name: "slow",
  handler: function (args) {
    return new Promise(function (resolve) { resolve("done:" + (args || []).join(",")); });
  }
});
minis.registerCommand({
  name: "boom",
  handler: function () { return Promise.reject("kaboom"); }
});
minis.registerCommand({
  name: "plain",
  handler: function () { return "plain-ok"; }
});
""", "commands.js")

check("3 commands registered", rt.registeredCommands.count == 3, "count=\(rt.registeredCommands.count)")

if let slow = rt.registeredCommands.first(where: { $0.name == "slow" }) {
    let (out, err) = await rt.callCommand(slow, args: ["a", "b"])
    check("async command awaited", out == "done:a,b" && !err, "out=\(out) err=\(err)")
} else { check("async command registered", false) }

if let boom = rt.registeredCommands.first(where: { $0.name == "boom" }) {
    let (out, err) = await rt.callCommand(boom, args: [])
    check("rejected command -> error", err && out.contains("kaboom"), "out=\(out) err=\(err)")
} else { check("rejected command registered", false) }

if let plain = rt.registeredCommands.first(where: { $0.name == "plain" }) {
    let (out, err) = await rt.callCommand(plain, args: [])
    check("plain command", out == "plain-ok" && !err, "out=\(out) err=\(err)")
} else { check("plain command registered", false) }

// ---- 3. async tool ----
eval(rt, """
minis.registerTool({
  name: "slow_tool",
  description: "t",
  execute: function (args) {
    return new Promise(function (resolve) { resolve("tool:" + args.x); });
  }
});
""", "tools.js")
if let tool = rt.registeredTools.first(where: { $0.name == "slow_tool" }) {
    let (out, err) = await rt.callTool(tool, args: ["x": 7])
    check("async tool awaited", out == "tool:7" && !err, "out=\(out) err=\(err)")
} else { check("async tool registered", false) }

// ---- 4. request interception ----
eval(rt, """
var rid = minis.api.request.intercept(function (req) {
  return {
    url: req.url.replace("api.example.com", "relay.local"),
    headers: { "x-injected": "yes" },
    bodyJSON: { model: req.model, extra: true }
  };
});
""", "intercept1.js")
check("intercept registered", rt.requestInterceptors.count == 1, "count=\(rt.requestInterceptors.count)")

var req = URLRequest(url: URL(string: "https://api.example.com/v1/chat/completions")!)
req.httpMethod = "POST"
req.httpBody = "{\"model\":\"gpt-x\",\"messages\":[]}".data(using: .utf8)
var rewritten = await rt.applyRequestInterceptors(to: req, provider: "openai", model: "gpt-x", sessionId: "sid1")
check("intercept rewrote url", rewritten.url?.absoluteString == "https://relay.local/v1/chat/completions",
      "url=\(rewritten.url?.absoluteString ?? "nil")")
check("intercept added header", rewritten.value(forHTTPHeaderField: "x-injected") == "yes",
      "headers=\(rewritten.allHTTPHeaderFields ?? [:])")
let rewrittenBody = rewritten.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
check("intercept rewrote body JSON",
      rewrittenBody.contains("\"model\":\"gpt-x\"") && rewrittenBody.contains("\"extra\":true"),
      "body=\(rewrittenBody)")

eval(rt, """
var rid2 = minis.api.request.intercept(function (req) {
  req.headers["x-mutated"] = "1";
  req.url = req.url + "?mut=1";
});
""", "intercept2.js")
var r2 = URLRequest(url: URL(string: "https://api.example.com/x")!)
r2.httpMethod = "GET"
r2 = await rt.applyRequestInterceptors(to: r2, provider: "openai", model: "m", sessionId: nil)
check("in-place mutation url", r2.url?.absoluteString == "https://relay.local/x?mut=1",
      "url=\(r2.url?.absoluteString ?? "nil")")
check("in-place mutation header", r2.value(forHTTPHeaderField: "x-mutated") == "1",
      "headers=\(r2.allHTTPHeaderFields ?? [:])")

eval(rt, """
var rid3 = minis.api.request.intercept(function (req) {
  return new Promise(function (resolve) { resolve({ headers: { "x-async": "1" } }); });
});
""", "intercept3.js")
var r3 = URLRequest(url: URL(string: "https://api.example.com/y")!)
r3.httpMethod = "GET"
r3 = await rt.applyRequestInterceptors(to: r3, provider: "openai", model: "m", sessionId: nil)
check("async interceptor header", r3.value(forHTTPHeaderField: "x-async") == "1",
      "headers=\(r3.allHTTPRequestFieldsDebug)")

eval(rt, "minis.api.request.unintercept(rid2);", "unintercept.js")
check("unintercept by id", rt.requestInterceptors.count == 2, "count=\(rt.requestInterceptors.count)")

eval(rt, "minis.api.request.clear();", "clear.js")
check("intercept clear all", rt.requestInterceptors.isEmpty, "count=\(rt.requestInterceptors.count)")

// ---- 5. store get/set ----
eval(rt, "minis.store.set('k', 'v');", "store1.js")
check("store set", storeValue("k") == "v", "got=\(storeValue("k") ?? "nil")")
eval(rt, "minis.store.set('k', null);", "store2.js")
check("store remove via null", storeValue("k") == nil, "got=\(storeValue("k") ?? "nil")")

// ---- 6. events + hook side effects ----
eval(rt, """
minis.on("tool_call", function (e) { minis.store.set("lastTool", e.tool); });
""", "hook.js")
rt.emitEvent("tool_call", data: ["tool": "shell_execute", "sessionId": "s"])
check("hook fired and wrote store", storeValue("lastTool") == "shell_execute",
      "stored=\(storeValue("lastTool") ?? "nil")")

// ---- 7. settings ----
eval(rt, "minis.store.set('greetingSeen', String(minis.api.settings.get('greeting')));", "settings.js")
check("settings.get bridge", storeValue("greetingSeen") == "hi", "got=\(storeValue("greetingSeen") ?? "nil")")

// ============================ Part B ============================
// Example plugins, loaded with the real runtime + real repo files.

print("")
print("Part B: example plugins")

// ---- B1. examples/request-interceptor ----
let ri = ExtensionJSRuntime(extensionID: "com.example.request-interceptor", bridge: makeBridge())
evalFile(ri, "examples/request-interceptor/agent/hooks/inject_header.js")
evalFile(ri, "examples/request-interceptor/agent/commands/intercept-status.js")

check("RI interceptor registered", ri.requestInterceptors.count == 1, "count=\(ri.requestInterceptors.count)")
check("RI command registered", ri.registeredCommands.contains { $0.name == "ext-intercept-status" })
check("RI hooks registered (agent_start/agent_end)",
      (ri.eventHandlers["agent_start"]?.count ?? 0) == 1 && (ri.eventHandlers["agent_end"]?.count ?? 0) == 1)

var riReq = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
riReq.httpMethod = "POST"
var riOut = await ri.applyRequestInterceptors(to: riReq, provider: "openai", model: "m", sessionId: "s")
check("RI injects header for matching provider", riOut.value(forHTTPHeaderField: "X-Plugin-Tag") == "minis-open",
      "headers=\(riOut.allHTTPHeaderFields ?? [:])")

var riReq2 = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1")!)
riReq2.httpMethod = "POST"
var riOut2 = await ri.applyRequestInterceptors(to: riReq2, provider: "gemini", model: "m", sessionId: "s")
check("RI skips non-matching provider", riOut2.value(forHTTPHeaderField: "X-Plugin-Tag") == nil,
      "headers=\(riOut2.allHTTPHeaderFields ?? [:])")

SettingsBox.shared.set("enabled", false)
var riOut3 = await ri.applyRequestInterceptors(to: riReq, provider: "openai", model: "m", sessionId: "s")
check("RI enabled=false leaves request untouched", riOut3.value(forHTTPHeaderField: "X-Plugin-Tag") == nil,
      "headers=\(riOut3.allHTTPHeaderFields ?? [:])")
SettingsBox.shared.set("enabled", true)

if let statusCmd = ri.registeredCommands.first(where: { $0.name == "ext-intercept-status" }) {
    let (out, err) = await ri.callCommand(statusCmd, args: [])
    check("RI status command (async) works",
          !err && out.contains("X-Plugin-Tag: minis-open") && out.contains("openai"),
          "out=\(out) err=\(err)")
} else { check("RI status command registered", false) }

// ---- B2. examples/demo-extension ----
let demo = ExtensionJSRuntime(extensionID: "com.example.demo", bridge: makeBridge())
evalFile(demo, "examples/demo-extension/agent/tools/hello.js")
evalFile(demo, "examples/demo-extension/agent/tools/notify_widget.js")
evalFile(demo, "examples/demo-extension/agent/tools/notes.js")
evalFile(demo, "examples/demo-extension/agent/commands/hello.js")
evalFile(demo, "examples/demo-extension/agent/hooks/log.js")

check("demo 3 tools registered", demo.registeredTools.count == 3, "count=\(demo.registeredTools.count)")
check("demo 1 command registered", demo.registeredCommands.count == 1)
check("demo 4 hook events registered",
      demo.eventHandlers.keys.sorted() == ["agent_end", "agent_start", "tool_call", "tool_result"],
      "keys=\(demo.eventHandlers.keys.sorted())")

if let helloCmd = demo.registeredCommands.first(where: { $0.name == "ext-hello" }) {
    let (out, err) = await demo.callCommand(helloCmd, args: ["Alice"])
    check("demo ext-hello async + args",
          !err && out.contains("Hi, Alice!") && out.contains("[mode=friendly]"),
          "out=\(out) err=\(err)")
} else { check("demo ext-hello registered", false) }

if let hello = demo.registeredTools.first(where: { $0.name == "hello_world" }) {
    let (out, err) = await demo.callTool(hello, args: ["name": "Bob"])
    check("demo hello_world async tool", !err && out.contains("Hello, Bob!"), "out=\(out)")
} else { check("demo hello_world registered", false) }

if let notes = demo.registeredTools.first(where: { $0.name == "demo_notes" }) {
    let (out1, e1) = await demo.callTool(notes, args: ["action": "list"])
    check("demo notes list", !e1 && out1.contains("note.txt"), "out=\(out1)")
    let (out2, e2) = await demo.callTool(notes, args: ["action": "write", "name": "new.txt", "content": "abc"])
    check("demo notes write", !e2 && out2.contains("Wrote"), "out=\(out2)")
    let (out3, e3) = await demo.callTool(notes, args: ["action": "read", "name": "new.txt"])
    check("demo notes read", !e3 && out3 == "abc", "out=\(out3)")
    let (out4, e4) = await demo.callTool(notes, args: ["action": "delete", "name": "new.txt"])
    check("demo notes delete", !e4 && out4.contains("Deleted"), "out=\(out4)")
} else { check("demo notes registered", false) }

if let notify = demo.registeredTools.first(where: { $0.name == "notify_widget" }) {
    let before = UILog.shared.messages.count
    let (out, err) = await demo.callTool(notify, args: ["text": "ping"])
    check("demo notify_widget posts to UI",
          !err && out.contains("Sent to widget: ping") && UILog.shared.messages.count == before + 1,
          "out=\(out)")
} else { check("demo notify_widget registered", false) }

// Hooks fire without throwing and can be observed through store writes.
demo.emitEvent("tool_call", data: ["tool": "shell_execute", "args": ["a": 1]])
check("demo tool_call hook fired", true)

// ---- B3. opencode-go relay plugin (regression guard) ----
// The relay plugin predates the new runtime APIs; loading it with the real
// runtime proves the shipped .minisx still parses and registers.
let relay = ExtensionJSRuntime(extensionID: "com.minis-open.opencode-go", bridge: makeBridge())
evalFile(relay, "extensions/opencode-go-relay/build/opencode-go-relay/agent/commands/opencode-go.js")
evalFile(relay, "extensions/opencode-go-relay/build/opencode-go-relay/agent/commands/opencode-go-off.js")
evalFile(relay, "extensions/opencode-go-relay/build/opencode-go-relay/agent/hooks/relay_guard.js")

check("relay 2 commands registered", relay.registeredCommands.count == 2,
      "names=\(relay.registeredCommands.map { $0.name })")
check("relay agent_start hook registered", (relay.eventHandlers["agent_start"]?.count ?? 0) == 1)

if let install = relay.registeredCommands.first(where: { $0.name == "opencode-go" }) {
    let (out, err) = await relay.callCommand(install, args: [])
    check("relay install command runs", !err && !out.isEmpty, "out=\(out.prefix(120)) err=\(err)")
} else { check("relay install command registered", false) }

// The agent_start guard runs shell commands through the mock bridge and must
// not throw with the new runtime.
relay.emitEvent("agent_start", data: ["sessionId": "sess-1", "round": 1])
check("relay agent_start guard fires", true)

print("")
print("PASS \(pass) / FAIL \(fail)")
exit(fail == 0 ? 0 : 1)

// Debug helper to keep the file compiling if referenced.
extension URLRequest {
    var allHTTPRequestFieldsDebug: [String: String] { allHTTPHeaderFields ?? [:] }
}
