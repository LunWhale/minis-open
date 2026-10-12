import Foundation

// MARK: - Lua Extension Runtime
//
// Hosts an extension's Lua scripts (agent/tools/xxx.lua, commands, hooks)
// in the vendored Lua 5.4 interpreter compiled into the app (see the Lua/
// directory of C sources added to the target). Each extension gets its own
// lua_State so extensions can't touch each other's globals.
//
// The `minis` table mirrors the JS API:
// ```lua
// minis.register_tool({ name="my_tool", description="...",
//                       execute=function(args) return "result" end })
// minis.register_command({ name="mycmd",
//                          handler=function(args) return "output" end })
// minis.on("agent_start", function(event) minis.log("started") end)
// minis.log("hello", 42)
// ```
//
// Host bridges (synchronous; each call blocks on the async native bridge):
// ```lua
// minis.api.shell("uname -s", { timeout = 15 })   -- string output
// minis.api.file.read("/var/minis/shared/x.txt")  -- string content
// minis.api.file.write("/var/minis/shared/x.txt", "hi")
// minis.api.file.list("/var/minis/shared")
// minis.api.file.delete("/var/minis/shared/x.txt")
// minis.api.permission.request("shell")           -- boolean
// minis.api.settings.get("greetingPrefix")        -- value | nil
// minis.api.settings.set("greetingPrefix", "Hi")
// ```
//
// Function values are stored as references in the Lua registry and invoked
// through the same executor paths as JS tools (callTool/callCommand).

// MARK: - Lua C API declarations (subset used by this runtime)
//
// These mirror lua.h / lauxlib.h for the vendored Lua 5.4.7 build.

private let LUA_REGISTRYINDEX: Int32 = -1001000
private let LUA_TFUNCTION: Int32 = 6
private let LUA_TTABLE: Int32 = 5
private let LUA_TNUMBER: Int32 = 3
private let LUA_TSTRING: Int32 = 4
private let LUA_TBOOLEAN: Int32 = 1
private let LUA_TNIL: Int32 = 0

@_silgen_name("luaL_newstate") private func luaL_newstate() -> OpaquePointer?
@_silgen_name("luaL_openlibs") private func luaL_openlibs(_ L: OpaquePointer?)
@_silgen_name("luaL_loadbufferx") private func luaL_loadbuffer(_ L: OpaquePointer?, _ buff: UnsafePointer<CChar>?, _ size: Int, _ name: UnsafePointer<CChar>?, _ mode: UnsafePointer<CChar>?) -> Int32
@_silgen_name("lua_pcall") private func lua_pcall(_ L: OpaquePointer?, _ nargs: Int32, _ nresults: Int32, _ errfunc: Int32) -> Int32
@_silgen_name("lua_getglobal") private func lua_getglobal(_ L: OpaquePointer?, _ name: UnsafePointer<CChar>?)
@_silgen_name("lua_setglobal") private func lua_setglobal(_ L: OpaquePointer?, _ name: UnsafePointer<CChar>?)
@_silgen_name("lua_pushstring") private func lua_pushstring(_ L: OpaquePointer?, _ s: UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
@_silgen_name("lua_tostring") private func lua_tostring(_ L: OpaquePointer?, _ idx: Int32) -> UnsafePointer<CChar>?
@_silgen_name("lua_tonumber") private func lua_tonumber(_ L: OpaquePointer?, _ idx: Int32) -> Double
@_silgen_name("lua_type") private func lua_type(_ L: OpaquePointer?, _ idx: Int32) -> Int32
@_silgen_name("lua_pushcclosure") private func lua_pushcclosure(_ L: OpaquePointer?, _ f: @convention(c) (OpaquePointer?) -> Int32, _ n: Int32)
@_silgen_name("lua_settable") private func lua_settable(_ L: OpaquePointer?, _ idx: Int32)
@_silgen_name("lua_gettable") private func lua_gettable(_ L: OpaquePointer?, _ idx: Int32)
@_silgen_name("lua_createtable") private func lua_createtable(_ L: OpaquePointer?, _ narr: Int32, _ nrec: Int32) -> Int32
@_silgen_name("lua_setfield") private func lua_setfield(_ L: OpaquePointer?, _ idx: Int32, _ k: UnsafePointer<CChar>?)
@_silgen_name("lua_getfield") private func lua_getfield(_ L: OpaquePointer?, _ idx: Int32, _ k: UnsafePointer<CChar>?)
@_silgen_name("lua_close") private func lua_close(_ L: OpaquePointer?)
@_silgen_name("lua_pushlightuserdata") private func lua_pushlightuserdata(_ L: OpaquePointer?, _ p: UnsafeMutableRawPointer?)
@_silgen_name("lua_touserdata") private func lua_touserdata(_ L: OpaquePointer?, _ idx: Int32) -> UnsafeMutableRawPointer?
@_silgen_name("lua_pushinteger") private func lua_pushinteger(_ L: OpaquePointer?, _ n: Int)
@_silgen_name("lua_tointeger") private func lua_tointeger(_ L: OpaquePointer?, _ idx: Int32) -> Int
@_silgen_name("lua_pushboolean") private func lua_pushboolean(_ L: OpaquePointer?, _ b: Int32)
@_silgen_name("lua_pushnil") private func lua_pushnil(_ L: OpaquePointer?)
@_silgen_name("lua_pushnumber") private func lua_pushnumber(_ L: OpaquePointer?, _ n: Double)
@_silgen_name("lua_toboolean") private func lua_toboolean(_ L: OpaquePointer?, _ idx: Int32) -> Int32
@_silgen_name("lua_rawgeti") private func lua_rawgeti(_ L: OpaquePointer?, _ idx: Int32, _ n: Int)
@_silgen_name("lua_rawseti") private func lua_rawseti(_ L: OpaquePointer?, _ idx: Int32, _ n: Int)
@_silgen_name("lua_gettop") private func lua_gettop(_ L: OpaquePointer?) -> Int32
@_silgen_name("lua_settop") private func lua_settop(_ L: OpaquePointer?, _ idx: Int32)
@_silgen_name("luaL_ref") private func luaL_ref(_ L: OpaquePointer?, _ t: Int32) -> Int32
@_silgen_name("luaL_unref") private func luaL_unref(_ L: OpaquePointer?, _ t: Int32, _ ref: Int32)
@_silgen_name("lua_pushvalue") private func lua_pushvalue(_ L: OpaquePointer?, _ idx: Int32)
@_silgen_name("lua_pop") private func lua_pop(_ L: OpaquePointer?, _ n: Int32)
@_silgen_name("lua_newtable") private func lua_newtable(_ L: OpaquePointer?)
@_silgen_name("lua_error") private func lua_error(_ L: OpaquePointer?) -> Int32

// MARK: - Runtime

final class ExtensionLuaRuntime {
    private let L: OpaquePointer
    private let extensionID: String
    /// Native bridge shared with the JS runtime (shell/file/permission).
    /// Lua calls are synchronous, so async bridges are awaited via a
    /// semaphore inside the C callbacks.
    var bridge: ExtensionJSRuntime.Bridge?

    struct RegisteredTool {
        let name: String
        let description: String
        let ref: Int32
    }

    struct RegisteredCommand {
        let name: String
        let ref: Int32
    }

    private(set) var registeredTools: [RegisteredTool] = []
    private(set) var registeredCommands: [RegisteredCommand] = []
    private(set) var eventHandlers: [String: [Int32]] = [:]

    init(extensionID: String) {
        self.extensionID = extensionID
        guard let L = luaL_newstate() else {
            fatalError("luaL_newstate failed")
        }
        self.L = L
        luaL_openlibs(L)
        installMinisAPI()
    }

    deinit {
        lua_close(L)
    }

    // MARK: - Evaluation

    func evaluateFile(_ path: String) throws {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ExtensionError.runtime("cannot read Lua file \(path)")
        }
        try evaluate(content, chunkName: path)
    }

    func evaluate(_ source: String, chunkName: String = "chunk") throws {
        let bytes = Array(source.utf8)
        let rc = bytes.withUnsafeBufferPointer { buf in
            luaL_loadbuffer(L, buf.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, buf.count, chunkName, nil)
        }
        if rc != 0 {
            let err = currentError()
            throw ExtensionError.runtime("Lua load error: \(err)")
        }
        if lua_pcall(L, 0, 0, 0) != 0 {
            let err = currentError()
            throw ExtensionError.runtime("Lua run error: \(err)")
        }
    }

    private func currentError() -> String {
        if let s = lua_tostring(L, -1) {
            return String(cString: s)
        }
        return "unknown Lua error"
    }

    // MARK: - Tool/Command execution
    //
    // The registered functions are stored as registry refs. We invoke by
    // pushing registry[ref] onto the stack, pushing the args table, calling
    // via lua_pcall, and reading the single returned string.

    func callTool(_ tool: RegisteredTool, args: [String: Any]) -> (String, Bool) {
        let result = invoke(ref: tool.ref, pushArgs: { [self] in pushTable(args) })
        ExtensionLogStore.shared.log(
            "tool \(tool.name) \(result.1 ? "failed" : "ok")",
            level: result.1 ? .warn : .info,
            category: "ExtTool"
        )
        return result
    }

    func callCommand(_ command: RegisteredCommand, args: [String]) -> (String, Bool) {
        let result = invoke(ref: command.ref, pushArgs: { [self] in pushArray(args) })
        ExtensionLogStore.shared.log(
            "command \(command.name) \(result.1 ? "failed" : "ok")",
            level: result.1 ? .warn : .info,
            category: "ExtCmd"
        )
        return result
    }

    private func invoke(ref: Int32, pushArgs: () -> Void) -> (String, Bool) {
        guard ref > 0 else { return ("Lua runtime: function not registered", true) }
        // Push registry[ref]
        lua_rawgeti(L, LUA_REGISTRYINDEX, Int(ref))
        if lua_type(L, -1) != LUA_TFUNCTION {
            lua_pop(L, 1)
            return ("Lua runtime: invalid function ref", true)
        }
        // Push the handler's argument table (tools: args dict, commands:
        // positional word array — same shapes as the JS runtime).
        pushArgs()
        if lua_pcall(L, 1, 1, 0) != 0 {
            let err = currentError()
            return (err, true)
        }
        if let s = lua_tostring(L, -1) {
            let result = String(cString: s)
            lua_pop(L, 1)
            return (result, false)
        }
        let isNumber = lua_type(L, -1) == 3 // LUA_TNUMBER
        if isNumber {
            let n = lua_tonumber(L, -1)
            lua_pop(L, 1)
            return (String(format: "%.17g", n), false)
        }
        lua_pop(L, 1)
        return ("", false)
    }

    func emitEvent(_ event: String, data: [String: Any]) {
        guard let handlers = eventHandlers[event] else { return }
        for ref in handlers {
            guard ref > 0 else { continue }
            lua_rawgeti(L, LUA_REGISTRYINDEX, Int(ref))
            if lua_type(L, -1) != LUA_TFUNCTION {
                lua_pop(L, 1)
                continue
            }
            pushTable(data)
            if lua_pcall(L, 1, 0, 0) != 0 {
                let err = currentError()
                AppLogger(category: "ExtLua[\(extensionID)]").error("hook \(event): \(err)")
            }
        }
    }

    // MARK: - Stack helpers

    /// Read a string argument at `index`: positional (`f("x")`) or the named
    /// field of a table argument (`f{key="x"}`). Used by host bridges so both
    /// call styles work.
    private func stringArg(_ index: Int32, field: String, from L: OpaquePointer?) -> String {
        guard let L else { return "" }
        if lua_type(L, index) == LUA_TTABLE {
            lua_getfield(L, index, field)
            let value = lua_tostring(L, -1).map { String(cString: $0) } ?? ""
            lua_pop(L, 1)
            return value
        }
        return lua_tostring(L, index).map { String(cString: $0) } ?? ""
    }

    /// Read a numeric argument at `index`: positional number or a table
    /// field. Returns nil when absent/not numeric.
    private func numberArg(_ index: Int32, field: String, from L: OpaquePointer?) -> Double? {
        guard let L else { return nil }
        if lua_type(L, index) == LUA_TTABLE {
            lua_getfield(L, index, field)
            let value = lua_type(L, -1) == LUA_TNUMBER ? lua_tonumber(L, -1) : nil
            lua_pop(L, 1)
            return value
        }
        return lua_type(L, index) == LUA_TNUMBER ? lua_tonumber(L, index) : nil
    }

    /// Read any Lua value at `index` as a Swift value (bool/number/string).
    private func anyArg(_ index: Int32, from L: OpaquePointer?) -> Any? {
        guard let L else { return nil }
        if lua_type(L, index) == LUA_TBOOLEAN { return lua_toboolean(L, index) != 0 }
        if lua_type(L, index) == LUA_TNUMBER { return lua_tonumber(L, index) }
        if let s = lua_tostring(L, index) { return String(cString: s) }
        return nil
    }

    /// Push a Lua array table (1-indexed) — command args positional shape.
    private func pushArray(_ items: [String]) {
        lua_newtable(L)
        for (i, item) in items.enumerated() {
            lua_pushstring(L, item)
            lua_rawseti(L, -2, i + 1)
        }
    }

    private func pushTable(_ dict: [String: Any]) {
        lua_newtable(L)
        for (k, v) in dict {
            lua_pushstring(L, k)
            switch v {
            case let s as String:
                lua_pushstring(L, s)
            case let n as Int:
                lua_pushinteger(L, n)
            case let d as Double:
                lua_pushstring(L, String(format: "%.17g", d))
            case let b as Bool:
                lua_pushboolean(L, b ? 1 : 0)
            case let arr as [String]:
                lua_newtable(L)
                for (i, item) in arr.enumerated() {
                    lua_pushstring(L, item)
                    lua_rawseti(L, -2, i + 1)
                }
            default:
                lua_pushstring(L, "\(v)")
            }
            lua_settable(L, -3)
        }
    }

    // MARK: - minis table installation

    private func installMinisAPI() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // minis = {}
        lua_newtable(L)

        // minis.register_tool = function(def)
        let registerTool: @convention(c) (OpaquePointer?) -> Int32 = { L in
            guard let L else { return 1 }
            // self from upvalue 1
            let upval = LUA_REGISTRYINDEX - 1 // lua_upvalueindex(1)
            guard let ud = lua_touserdata(L, upval),
                  let runtime = Unmanaged<ExtensionLuaRuntime>.fromOpaque(ud).takeUnretainedValue().optionalSelf else {
                lua_pushboolean(L, 0)
                return 1
            }
            let state = runtime.L
            lua_getfield(state, 1, "name")
            let name = lua_tostring(state, -1).map { String(cString: $0) } ?? ""
            lua_pop(state, 1)
            lua_getfield(state, 1, "description")
            let desc = lua_tostring(state, -1).map { String(cString: $0) } ?? ""
            lua_pop(state, 1)
            // execute = def.execute (index 1)
            lua_getfield(state, 1, "execute")
            if lua_type(state, -1) == LUA_TFUNCTION {
                // store as registry ref
                let ref = luaL_ref(state, LUA_REGISTRYINDEX)
                runtime.registeredTools.append(.init(name: name, description: desc, ref: ref))
                lua_pushboolean(state, 1)
            } else {
                lua_pop(state, 1)
                lua_pushboolean(state, 0)
            }
            return 1
        }
        lua_pushlightuserdata(L, selfPtr)
        lua_pushcclosure(L, registerTool, 1)
        lua_setfield(L, -2, "register_tool")

        // minis.register_command = function(def)
        let registerCommand: @convention(c) (OpaquePointer?) -> Int32 = { L in
            guard let L else { return 1 }
            let upval = LUA_REGISTRYINDEX - 1
            guard let ud = lua_touserdata(L, upval),
                  let runtime = Unmanaged<ExtensionLuaRuntime>.fromOpaque(ud).takeUnretainedValue().optionalSelf else {
                lua_pushboolean(L, 0)
                return 1
            }
            let state = runtime.L
            lua_getfield(state, 1, "name")
            let name = lua_tostring(state, -1).map { String(cString: $0) } ?? ""
            lua_pop(state, 1)
            lua_getfield(state, 1, "handler")
            if lua_type(state, -1) == LUA_TFUNCTION {
                let ref = luaL_ref(state, LUA_REGISTRYINDEX)
                runtime.registeredCommands.append(.init(name: name, ref: ref))
                lua_pushboolean(state, 1)
            } else {
                lua_pop(state, 1)
                lua_pushboolean(state, 0)
            }
            return 1
        }
        lua_pushlightuserdata(L, selfPtr)
        lua_pushcclosure(L, registerCommand, 1)
        lua_setfield(L, -2, "register_command")

        // minis.on = function(event, handler)
        let on: @convention(c) (OpaquePointer?) -> Int32 = { L in
            guard let L else { return 0 }
            let upval = LUA_REGISTRYINDEX - 1
            guard let ud = lua_touserdata(L, upval),
                  let runtime = Unmanaged<ExtensionLuaRuntime>.fromOpaque(ud).takeUnretainedValue().optionalSelf else {
                return 0
            }
            let state = runtime.L
            lua_getfield(state, 1, "event")
            let event = lua_tostring(state, -1).map { String(cString: $0) } ?? ""
            lua_pop(state, 1)
            if lua_type(state, 2) == LUA_TFUNCTION {
                let ref = luaL_ref(state, LUA_REGISTRYINDEX)
                runtime.eventHandlers[event, default: []].append(ref)
            }
            return 0
        }
        lua_pushlightuserdata(L, selfPtr)
        lua_pushcclosure(L, on, 1)
        lua_setfield(L, -2, "on")

        // minis.log = function(...)
        let log: @convention(c) (OpaquePointer?) -> Int32 = { L in
            guard let L else { return 0 }
            let upval = LUA_REGISTRYINDEX - 1
            guard let ud = lua_touserdata(L, upval),
                  let runtime = Unmanaged<ExtensionLuaRuntime>.fromOpaque(ud).takeUnretainedValue().optionalSelf else {
                return 0
            }
            let state = runtime.L
            let n = Int(lua_gettop(state))
            var parts: [String] = []
            for i in 1...n {
                lua_pushvalue(state, Int32(i))
                if let s = lua_tostring(state, -1) {
                    parts.append(String(cString: s))
                }
                lua_pop(state, 1)
            }
            AppLogger(category: "ExtLua[\(runtime.extensionID)]").info("\(parts.joined(separator: " "))")
            ExtensionLogStore.shared.log(
                parts.joined(separator: " "),
                category: "ExtLua[\(runtime.extensionID)]"
            )
            return 0
        }
        lua_pushlightuserdata(L, selfPtr)
        lua_pushcclosure(L, log, 1)
        lua_setfield(L, -2, "log")

        // minis.api = { shell, file, permission } — real bridges. Lua calls
        // are synchronous; each async host operation is awaited on a
        // DispatchSemaphore inside the C callback.
        lua_newtable(L)
        // api.shell(cmd, opts) → string
        let shell: @convention(c) (OpaquePointer?) -> Int32 = { L in
            guard let L else { return 1 }
            let upval = LUA_REGISTRYINDEX - 1
            guard let ud = lua_touserdata(L, upval),
                  let runtime = Unmanaged<ExtensionLuaRuntime>.fromOpaque(ud).takeUnretainedValue().optionalSelf else {
                lua_pushstring(L, "Error: runtime unavailable")
                return 1
            }
            let state = runtime.L
            // Positional form `shell("cmd", {timeout=15})`; a
            // `{cmd=..., timeout=...}` table is also accepted (compat).
            let cmd = runtime.stringArg(1, field: "cmd", from: state)
            let timeout = runtime.numberArg(2, field: "timeout", from: state)
                ?? runtime.numberArg(1, field: "timeout", from: state)
            var opts: [String: Any] = [:]
            if let timeout, timeout > 0 { opts["timeout"] = Int(timeout) }
            guard !cmd.isEmpty, let bridge = runtime.bridge else {
                lua_pushstring(L, "Error: shell bridge unavailable")
                return 1
            }
            let semaphore = DispatchSemaphore(value: 0)
            var output = "Error: shell timeout"
            Task {
                let (out, isErr) = await bridge.shell(cmd, opts)
                output = isErr ? "Error: \(out)" : out
                semaphore.signal()
            }
            semaphore.wait()
            lua_pushstring(L, output)
            return 1
        }
        lua_pushlightuserdata(L, selfPtr)
        lua_pushcclosure(L, shell, 1)
        lua_setfield(L, -2, "shell")
        // api.file = { read, write, list, delete } — mirrors the JS API.
        // Paths are positional (`file.read("/var/minis/x")`) or table-style
        // (`file.read{path="/var/minis/x"}`).
        _ = lua_newtable(L)
        // file.read(path) → string
        let fileRead: @convention(c) (OpaquePointer?) -> Int32 = { L in
            guard let L else { return 1 }
            let upval = LUA_REGISTRYINDEX - 1
            guard let ud = lua_touserdata(L, upval),
                  let runtime = Unmanaged<ExtensionLuaRuntime>.fromOpaque(ud).takeUnretainedValue().optionalSelf else {
                lua_pushstring(L, "Error: runtime unavailable")
                return 1
            }
            let state = runtime.L
            let path = runtime.stringArg(1, field: "path", from: state)
            guard !path.isEmpty, let bridge = runtime.bridge else {
                lua_pushstring(L, "Error: file bridge unavailable")
                return 1
            }
            let semaphore = DispatchSemaphore(value: 0)
            var output = "Error: file read timeout"
            Task {
                let (out, isErr) = await bridge.fileRead(path)
                output = isErr ? "Error: \(out)" : out
                semaphore.signal()
            }
            semaphore.wait()
            lua_pushstring(L, output)
            return 1
        }
        lua_pushlightuserdata(L, selfPtr)
        lua_pushcclosure(L, fileRead, 1)
        lua_setfield(L, -2, "read")
        // file.write(path, content) → string
        let fileWrite: @convention(c) (OpaquePointer?) -> Int32 = { L in
            guard let L else { return 1 }
            let upval = LUA_REGISTRYINDEX - 1
            guard let ud = lua_touserdata(L, upval),
                  let runtime = Unmanaged<ExtensionLuaRuntime>.fromOpaque(ud).takeUnretainedValue().optionalSelf else {
                lua_pushstring(L, "Error: runtime unavailable")
                return 1
            }
            let state = runtime.L
            let path = runtime.stringArg(1, field: "path", from: state)
            let content = runtime.stringArg(2, field: "content", from: state)
            guard !path.isEmpty, let bridge = runtime.bridge else {
                lua_pushstring(L, "Error: file bridge unavailable")
                return 1
            }
            let semaphore = DispatchSemaphore(value: 0)
            var output = "Error: file write timeout"
            Task {
                let (out, isErr) = await bridge.fileWrite(path, content, false)
                output = isErr ? "Error: \(out)" : out
                semaphore.signal()
            }
            semaphore.wait()
            lua_pushstring(L, output)
            return 1
        }
        lua_pushlightuserdata(L, selfPtr)
        lua_pushcclosure(L, fileWrite, 1)
        lua_setfield(L, -2, "write")
        // file.list(path) → JSON string [{name, isDirectory, size}]
        let fileList: @convention(c) (OpaquePointer?) -> Int32 = { L in
            guard let L else { return 1 }
            let upval = LUA_REGISTRYINDEX - 1
            guard let ud = lua_touserdata(L, upval),
                  let runtime = Unmanaged<ExtensionLuaRuntime>.fromOpaque(ud).takeUnretainedValue().optionalSelf else {
                lua_pushstring(L, "Error: runtime unavailable")
                return 1
            }
            let state = runtime.L
            let path = runtime.stringArg(1, field: "path", from: state)
            guard !path.isEmpty, let bridge = runtime.bridge else {
                lua_pushstring(L, "Error: file bridge unavailable")
                return 1
            }
            let semaphore = DispatchSemaphore(value: 0)
            var output = "Error: file list timeout"
            Task {
                let (out, isErr) = await bridge.fileList(path)
                output = isErr ? "Error: \(out)" : out
                semaphore.signal()
            }
            semaphore.wait()
            lua_pushstring(L, output)
            return 1
        }
        lua_pushlightuserdata(L, selfPtr)
        lua_pushcclosure(L, fileList, 1)
        lua_setfield(L, -2, "list")
        // file.delete(path) → string
        let fileDelete: @convention(c) (OpaquePointer?) -> Int32 = { L in
            guard let L else { return 1 }
            let upval = LUA_REGISTRYINDEX - 1
            guard let ud = lua_touserdata(L, upval),
                  let runtime = Unmanaged<ExtensionLuaRuntime>.fromOpaque(ud).takeUnretainedValue().optionalSelf else {
                lua_pushstring(L, "Error: runtime unavailable")
                return 1
            }
            let state = runtime.L
            let path = runtime.stringArg(1, field: "path", from: state)
            guard !path.isEmpty, let bridge = runtime.bridge else {
                lua_pushstring(L, "Error: file bridge unavailable")
                return 1
            }
            let semaphore = DispatchSemaphore(value: 0)
            var output = "Error: file delete timeout"
            Task {
                let (out, isErr) = await bridge.fileDelete(path)
                output = isErr ? "Error: \(out)" : out
                semaphore.signal()
            }
            semaphore.wait()
            lua_pushstring(L, output)
            return 1
        }
        lua_pushlightuserdata(L, selfPtr)
        lua_pushcclosure(L, fileDelete, 1)
        lua_setfield(L, -2, "delete")
        lua_setfield(L, -2, "file")
        // api.permission = { request } — mirrors the JS API.
        // permission.request(kind) → boolean
        _ = lua_newtable(L)
        let permission: @convention(c) (OpaquePointer?) -> Int32 = { L in
            guard let L else { return 1 }
            let upval = LUA_REGISTRYINDEX - 1
            guard let ud = lua_touserdata(L, upval),
                  let runtime = Unmanaged<ExtensionLuaRuntime>.fromOpaque(ud).takeUnretainedValue().optionalSelf else {
                lua_pushboolean(L, 0)
                return 1
            }
            let state = runtime.L
            let kind = runtime.stringArg(1, field: "kind", from: state)
            guard let bridge = runtime.bridge else {
                lua_pushboolean(L, 0)
                return 1
            }
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            Task {
                granted = await bridge.requestPermission(kind)
                semaphore.signal()
            }
            semaphore.wait()
            lua_pushboolean(L, granted ? 1 : 0)
            return 1
        }
        lua_pushlightuserdata(L, selfPtr)
        lua_pushcclosure(L, permission, 1)
        lua_setfield(L, -2, "request")
        lua_setfield(L, -2, "permission")

        // api.settings = { get, set } — per-extension settings declared in
        // manifest.json and editable from the extension's Settings page.
        _ = lua_createtable(L, 0, 2)
        // settings.get(key) → value | nil
        let settingsGet: @convention(c) (OpaquePointer?) -> Int32 = { L in
            guard let L else { return 1 }
            let upval = LUA_REGISTRYINDEX - 1
            guard let ud = lua_touserdata(L, upval),
                  let runtime = Unmanaged<ExtensionLuaRuntime>.fromOpaque(ud).takeUnretainedValue().optionalSelf else {
                return 1
            }
            let state = runtime.L
            let key = runtime.stringArg(1, field: "key", from: state)
            if let bridge = runtime.bridge, let value = bridge.settingsGet(runtime.extensionID, key) {
                runtime.pushNativeValue(value, into: state)
            } else {
                lua_pushnil(state)
            }
            return 1
        }
        lua_pushlightuserdata(L, selfPtr)
        lua_pushcclosure(L, settingsGet, 1)
        lua_setfield(L, -2, "get")
        // settings.all() → table of current values
        let settingsAll: @convention(c) (OpaquePointer?) -> Int32 = { L in
            guard let L else { return 1 }
            let upval = LUA_REGISTRYINDEX - 1
            guard let ud = lua_touserdata(L, upval),
                  let runtime = Unmanaged<ExtensionLuaRuntime>.fromOpaque(ud).takeUnretainedValue().optionalSelf,
                  let bridge = runtime.bridge else {
                lua_pushnil(L)
                return 1
            }
            runtime.pushTable(bridge.settingsAll(runtime.extensionID))
            return 1
        }
        lua_pushlightuserdata(L, selfPtr)
        lua_pushcclosure(L, settingsAll, 1)
        lua_setfield(L, -2, "all")
        // settings.set(key, value)
        let settingsSet: @convention(c) (OpaquePointer?) -> Int32 = { L in
            guard let L else { return 0 }
            let upval = LUA_REGISTRYINDEX - 1
            guard let ud = lua_touserdata(L, upval),
                  let runtime = Unmanaged<ExtensionLuaRuntime>.fromOpaque(ud).takeUnretainedValue().optionalSelf else {
                return 0
            }
            let state = runtime.L
            let key = runtime.stringArg(1, field: "key", from: state)
            // Positional `set("key", value)` or table `set{key=..., value=...}`.
            let value: Any?
            if lua_gettop(state) >= 2, lua_type(state, 2) != LUA_TNIL {
                value = runtime.anyArg(2, from: state)
            } else if lua_type(state, 1) == LUA_TTABLE {
                lua_getfield(state, 1, "value")
                value = runtime.anyArg(-1, from: state)
                lua_pop(state, 1)
            } else {
                value = nil
            }
            if let bridge = runtime.bridge, let value {
                bridge.settingsSet(runtime.extensionID, key, value)
            }
            return 0
        }
        lua_pushlightuserdata(L, selfPtr)
        lua_pushcclosure(L, settingsSet, 1)
        lua_setfield(L, -2, "set")
        lua_setfield(L, -2, "settings")
        lua_setfield(L, -2, "api")

        // globals.minis = minis
        lua_setglobal(L, "minis")
    }

    /// Push a Swift value onto the Lua stack (String/Int/Double/Bool).
    private func pushNativeValue(_ value: Any, into L: OpaquePointer) {
        switch value {
        case let s as String:
            lua_pushstring(L, s)
        case let i as Int:
            lua_pushinteger(L, i)
        case let d as Double:
            lua_pushnumber(L, d)
        case let b as Bool:
            lua_pushboolean(L, b ? 1 : 0)
        default:
            lua_pushnil(L)
        }
    }
}

// MARK: - Weak self helper (used from C closures via unretained pointer)

private extension ExtensionLuaRuntime {
    /// Non-nil wrapper so `Unmanaged.fromOpaque(...).takeUnretainedValue()`
    /// can be chained without force-unwraps inside C callbacks.
    var optionalSelf: ExtensionLuaRuntime? { self }
}
