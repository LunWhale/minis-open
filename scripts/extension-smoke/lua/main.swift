import Foundation

var pass = 0, fail = 0
func check(_ n: String, _ ok: Bool, _ d: String = "") { if ok { pass += 1; print("  [ok  ] \(n)") } else { fail += 1; print("  [FAIL] \(n) \(d)") } }

final class Log: @unchecked Sendable {
    static let shared = Log()
    private let lock = NSLock()
    private(set) var shellCalls: [(cmd: String, opts: [String: Any])] = []
    private(set) var settings: [String: Any] = ["greetingPrefix": "Hi"]
    func record(_ cmd: String, _ opts: [String: Any]) { lock.lock(); shellCalls.append((cmd, opts)); lock.unlock() }
    func set(_ key: String, _ value: Any) { lock.lock(); settings[key] = value; lock.unlock() }
    func get(_ key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return settings[key] }
}

let bridge = ExtensionJSRuntime.Bridge(
    shell: { cmd, opts in Log.shared.record(cmd, opts); return ("shell-out:" + cmd, false) },
    fileRead: { path in ("file:" + path, false) },
    fileWrite: { path, content, _ in ("wrote:\(path):\(content.count)", false) },
    fileList: { _ in ("[{\"name\":\"a\",\"isDirectory\":false,\"size\":1}]", false) },
    fileDelete: { path in ("deleted:" + path, false) },
    requestPermission: { _ in true }, hasPermission: { _ in true },
    postToUI: { _, _ in }, emitEvent: { _, _ in },
    settingsGet: { _, key in Log.shared.get(key) },
    settingsSet: { _, key, value in Log.shared.set(key, value) },
    settingsAll: { _ in Log.shared.settings }
)

let rt = ExtensionLuaRuntime(extensionID: "lua.smoke")
rt.bridge = bridge

print("=== 1. lua-demo status.lua positional shell + timeout ===")
do {
    let repoRoot = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/Users/brooks/Documents/agentprojects/饭袋/OpenMinis"
    let src = try String(contentsOfFile: repoRoot + "/examples/lua-demo/agent/commands/status.lua", encoding: .utf8)
    try rt.evaluate(src, chunkName: "status.lua")
    if let cmd = rt.registeredCommands.first {
        let (out, _) = rt.callCommand(cmd, args: [])
        print("  output: \(out.prefix(200))")
    }
    let calls = Log.shared.shellCalls
    check("shell called", calls.count == 1, "calls=\(calls)")
    check("shell cmd positional", calls.first?.cmd == "uname -s -m", "cmd=\(calls.first?.cmd ?? "nil")")
    check("shell timeout forwarded", (calls.first?.opts["timeout"] as? Int) == 15, "opts=\(calls.first?.opts ?? [:])")
} catch { check("status.lua eval", false, "\(error)") }

print("")
print("=== 2. api.file table shape ===")
do {
    try rt.evaluate("""
    minis.register_command({ name = "fileOps", handler = function()
      local r = minis.api.file.read("/var/minis/shared/x.txt")
      local w = minis.api.file.write("/var/minis/shared/y.txt", "hello")
      local l = minis.api.file.list("/var/minis/shared")
      local d = minis.api.file.delete("/var/minis/shared/y.txt")
      local t = minis.api.file.read{path="/var/minis/shared/z.txt"}
      return r .. "|" .. w .. "|" .. l .. "|" .. d .. "|" .. t
    end })
    """, chunkName: "file.lua")
    if let cmd = rt.registeredCommands.first(where: { $0.name == "fileOps" }) {
        let (out, _) = rt.callCommand(cmd, args: [])
        check("file.read positional", out.contains("file:/var/minis/shared/x.txt"), "out=\(out)")
        check("file.write positional", out.contains("wrote:/var/minis/shared/y.txt:5"), "out=\(out)")
        check("file.list", out.contains("isDirectory"), "out=\(out)")
        check("file.delete", out.contains("deleted:/var/minis/shared/y.txt"), "out=\(out)")
        check("file.read table form", out.contains("file:/var/minis/shared/z.txt"), "out=\(out)")
    }
} catch { check("file eval", false, "\(error)") }

print("")
print("=== 3. api.permission.request positional ===")
do {
    try rt.evaluate("""
    minis.register_command({ name = "perm", handler = function()
      return "granted=" .. tostring(minis.api.permission.request("shell"))
    end })
    """, chunkName: "perm.lua")
    if let cmd = rt.registeredCommands.first(where: { $0.name == "perm" }) {
        let (out, _) = rt.callCommand(cmd, args: [])
        check("permission.request positional", out == "granted=true", "out=\(out)")
    }
} catch { check("perm eval", false, "\(error)") }

print("")
print("=== 4. api.settings get/set/all positional ===")
do {
    try rt.evaluate("""
    minis.register_command({ name = "set1", handler = function()
      local before = tostring(minis.api.settings.get("greetingPrefix"))
      minis.api.settings.set("greetingPrefix", "Yo")
      local after = tostring(minis.api.settings.get("greetingPrefix"))
      local all = minis.api.settings.all()
      return "before=" .. before .. "|after=" .. after .. "|allType=" .. type(all)
    end })
    """, chunkName: "settings.lua")
    if let cmd = rt.registeredCommands.first(where: { $0.name == "set1" }) {
        let (out, _) = rt.callCommand(cmd, args: [])
        check("settings.get positional", out.contains("before=Hi"), "out=\(out)")
        check("settings.set positional", out.contains("after=Yo"), "out=\(out)")
        check("settings.all table", out.contains("allType=table"), "out=\(out)")
        check("value stored on bridge", (Log.shared.get("greetingPrefix") as? String) == "Yo")
    }
} catch { check("settings eval", false, "\(error)") }

print("")
print("=== 5. tool args + async-ish ===")
do {
    try rt.evaluate("""
    minis.register_tool({ name = "t", description = "d", execute = function(a)
      return "name=" .. tostring(a and a.name)
    end })
    """, chunkName: "tool.lua")
    if let tool = rt.registeredTools.first {
        let (out, _) = rt.callTool(tool, args: ["name": "Bob"])
        check("tool args table", out == "name=Bob", "got: \(out)")
    }
} catch { check("tool eval", false, "\(error)") }

print("")
print("PASS \(pass) / FAIL \(fail)")
exit(fail == 0 ? 0 : 1)
