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
// Function values are stored as references in the Lua registry and invoked
// through the same executor paths as JS tools (callTool/callCommand).

// MARK: - Lua C API declarations (subset used by this runtime)
//
// These mirror lua.h / lauxlib.h for the vendored Lua 5.4.7 build.

private let LUA_REGISTRYINDEX: Int32 = -1001000
private let LUA_TFUNCTION: Int32 = 6

@_silgen_name("luaL_newstate") private func luaL_newstate() -> OpaquePointer?
@_silgen_name("luaL_openlibs") private func luaL_openlibs(_ L: OpaquePointer?)
@_silgen_name("luaL_loadbuffer") private func luaL_loadbuffer(_ L: OpaquePointer?, _ buff: UnsafePointer<CChar>?, _ size: Int, _ name: UnsafePointer<CChar>?) -> Int32
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
@_silgen_name("lua_createtable") private func lua_createtable(_ L: OpaquePointer?, _ narr: Int32, _ nrec: Int32)
@_silgen_name("lua_setfield") private func lua_setfield(_ L: OpaquePointer?, _ idx: Int32, _ k: UnsafePointer<CChar>?)
@_silgen_name("lua_getfield") private func lua_getfield(_ L: OpaquePointer?, _ idx: Int32, _ k: UnsafePointer<CChar>?)
@_silgen_name("lua_close") private func lua_close(_ L: OpaquePointer?)
@_silgen_name("lua_pushlightuserdata") private func lua_pushlightuserdata(_ L: OpaquePointer?, _ p: UnsafeMutableRawPointer?)
@_silgen_name("lua_touserdata") private func lua_touserdata(_ L: OpaquePointer?, _ idx: Int32) -> UnsafeMutableRawPointer?
@_silgen_name("lua_pushinteger") private func lua_pushinteger(_ L: OpaquePointer?, _ n: Int)
@_silgen_name("lua_tointeger") private func lua_tointeger(_ L: OpaquePointer?, _ idx: Int32) -> Int
@_silgen_name("lua_pushboolean") private func lua_pushboolean(_ L: OpaquePointer?, _ b: Int32)
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
    private var eventHandlers: [String: [Int32]] = [:]

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
            luaL_loadbuffer(L, buf.baseAddress.map { UnsafePointer<CChar>($0) }, buf.count, chunkName)
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
        return invoke(ref: tool.ref, argsTable: args)
    }

    func callCommand(_ command: RegisteredCommand, args: [String]) -> (String, Bool) {
        return invoke(ref: command.ref, argsTable: ["args": args])
    }

    private func invoke(ref: Int32, argsTable: [String: Any]) -> (String, Bool) {
        guard ref > 0 else { return ("Lua runtime: function not registered", true) }
        // Push registry[ref]
        lua_rawgeti(L, LUA_REGISTRYINDEX, Int(ref))
        if lua_type(L, -1) != LUA_TFUNCTION {
            lua_pop(L, 1)
            return ("Lua runtime: invalid function ref", true)
        }
        // Push args as a table
        pushTable(argsTable)
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
            return 0
        }
        lua_pushlightuserdata(L, selfPtr)
        lua_pushcclosure(L, log, 1)
        lua_setfield(L, -2, "log")

        // minis.api = {} (reserved surface; shell/file/offload async bridges
        // are provided by the JS runtime — Lua scripts should expose host
        // operations through registered tools instead.)
        lua_newtable(L)
        lua_pushstring(L, "async bridge not available in Lua; use a registered tool for shell/file")
        lua_setfield(L, -2, "note")
        lua_setfield(L, -2, "api")

        // globals.minis = minis
        lua_setglobal(L, "minis")
    }
}

// MARK: - Weak self helper (used from C closures via unretained pointer)

private extension ExtensionLuaRuntime {
    /// Non-nil wrapper so `Unmanaged.fromOpaque(...).takeUnretainedValue()`
    /// can be chained without force-unwraps inside C callbacks.
    var optionalSelf: ExtensionLuaRuntime? { self }
}
