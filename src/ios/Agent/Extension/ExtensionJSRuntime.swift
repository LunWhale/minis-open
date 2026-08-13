import Foundation
import JavaScriptCore

// MARK: - Extension JS Runtime

/// Hosts a single extension's agent-side JavaScript (tools, commands, hooks)
/// in a JavaScriptCore context with a `minis` global API. Each extension gets
/// its own isolated context so extensions can't touch each other's globals.
///
/// The `minis` API mirrors what the manifest declares:
/// ```js
/// minis.registerTool({ name, description, parameters, execute })
/// minis.registerCommand({ name, handler })
/// minis.on("tool_call", (event) => {})
/// minis.api.shell(cmd, {timeout})            → Promise<string>
/// minis.api.file.read(path)                  → Promise<string>
/// minis.api.offload(name, args)              → Promise<any>
/// minis.api.permission.request(kind)         → Promise<boolean>
/// minis.api.ui.postMessage(data)             → broadcast to UI widgets
/// minis.api.event.emit(name, data)
/// minis.log(...)
/// minis.store.get/set(key, value)            → small KV persistence
/// ```
final class ExtensionJSRuntime {
    private let context: JSContext
    private let extensionID: String
    private let bridge: Bridge

    /// Native callbacks the JS bridge routes to.
    struct Bridge {
        var shell: @Sendable (String, [String: Any]) async -> (String, Bool)
        var fileRead: @Sendable (String) async -> (String, Bool)
        var fileWrite: @Sendable (String, String, Bool) async -> (String, Bool)
        var requestPermission: @Sendable (String) async -> Bool
        var postToUI: @Sendable (String, [String: Any]) -> Void
        var emitEvent: @Sendable (String, [String: Any]) -> Void
    }

    init(extensionID: String, bridge: Bridge) {
        self.extensionID = extensionID
        self.bridge = bridge
        self.context = JSContext()!
        installMinisAPI()
    }

    // MARK: - Evaluation

    /// Evaluate a JS file from the extension bundle.
    func evaluateScript(_ js: String, fileName: String) throws {
        let result = context.evaluateScript(js, withSourceURL: URL(fileURLWithPath: fileName))
        if context.exception != nil {
            let msg = context.exception.toString() ?? "unknown JS error"
            context.exception = nil
            throw ExtensionError.runtime("\(fileName): \(msg)")
        }
        _ = result
    }

    // MARK: - Tool registry

    /// Registered tools collected from `minis.registerTool` calls.
    private(set) var registeredTools: [RegisteredTool] = []

    struct RegisteredTool {
        let name: String
        let description: String
        let execute: JSValue  // JS function
    }

    /// Execute a registered tool. `args` is bridged to JS, result string
    /// returned (or an error string).
    func callTool(_ tool: RegisteredTool, args: [String: Any]) -> (String, Bool) {
        let jsArgs = JSValue(object: args, in: context)!
        guard let result = tool.execute.call(withArguments: [jsArgs]) else {
            return ("Error: tool execution failed", true)
        }
        if result.isUndefined || result.isNull {
            return ("", false)
        }
        if let str = result.toString() {
            return (str, false)
        }
        return (result.toObject() as? String ?? "\(result)", false)
    }

    // MARK: - minis global API

    private func installMinisAPI() {
        let minis = JSValue(newObjectIn: context)!

        // registerTool
        let registerTool: @convention(block) (JSValue) -> Void = { [weak self] def in
            guard let self else { return }
            let name = def.objectForKeyedSubscript("name").toString() ?? ""
            let desc = def.objectForKeyedSubscript("description").toString() ?? ""
            let execute = def.objectForKeyedSubscript("execute")
            guard !name.isEmpty, !execute.isUndefined else { return }
            self.registeredTools.append(RegisteredTool(name: name, description: desc, execute: execute))
        }
        minis.setObject(registerTool, forKeyedSubscript: "registerTool" as NSString)

        // log
        let log: @convention(block) (JSValue) -> Void = { [extensionID] args in
            let joined = (0..<args.toArray().count).map { args.objectAtIndexedSubscript($0).toString() ?? "" }.joined(separator: " ")
            AppLogger(category: "Ext[\(extensionID)]").info("\(joined)")
        }
        minis.setObject(log, forKeyedSubscript: "log" as NSString)

        // api.*
        let api = JSValue(newObjectIn: context)!
        api.setObject(makeShellBridge(), forKeyedSubscript: "shell" as NSString)
        api.setObject(makeFileReadBridge(), forKeyedSubscript: "file" as NSString)
        api.setObject(makePermissionBridge(), forKeyedSubscript: "permission" as NSString)
        api.setObject(makeEventBridge(), forKeyedSubscript: "event" as NSString)
        minis.setObject(api, forKeyedSubscript: "api" as NSString)

        context.setObject(minis, forKeyedSubscript: "minis" as NSString)
    }

    private func makeShellBridge() -> @convention(block) (JSValue, JSValue) -> JSValue {
        let bridge = self.bridge
        let context = self.context
        return { cmdVal, optsVal in
            let cmd = cmdVal.toString() ?? ""
            let timeout = optsVal.objectForKeyedSubscript("timeout").toInt32() > 0
                ? Int(optsVal.objectForKeyedSubscript("timeout").toInt32()) : 900
            let promise = JSValue(newPromiseIn: context) { resolve, reject in
                Task {
                    let (out, isErr) = await bridge.shell(cmd, ["timeout": timeout])
                    if isErr {
                        reject?.call(withArguments: [out])
                    } else {
                        resolve?.call(withArguments: [out])
                    }
                }
            }
            return promise
        }
    }

    private func makeFileReadBridge() -> @convention(block) (JSValue) -> JSValue {
        let bridge = self.bridge
        let context = self.context
        return { pathVal in
            let path = pathVal.toString() ?? ""
            let promise = JSValue(newPromiseIn: context) { resolve, reject in
                Task {
                    let (out, isErr) = await bridge.fileRead(path)
                    if isErr { reject?.call(withArguments: [out]) } else { resolve?.call(withArguments: [out]) }
                }
            }
            return promise
        }
    }

    private func makePermissionBridge() -> @convention(block) (JSValue) -> JSValue {
        let bridge = self.bridge
        let context = self.context
        return { kindVal in
            let kind = kindVal.toString() ?? ""
            let promise = JSValue(newPromiseIn: context) { resolve, _ in
                Task {
                    let granted = await bridge.requestPermission(kind)
                    resolve?.call(withArguments: [granted])
                }
            }
            return promise
        }
    }

    private func makeEventBridge() -> @convention(block) (JSValue, JSValue) -> JSValue {
        let bridge = self.bridge
        return { nameVal, dataVal in
            let name = nameVal.toString() ?? ""
            let data = dataVal.toObject() as? [String: Any] ?? [:]
            bridge.emitEvent(name, data)
            return JSValue(undefinedIn: self.context)
        }
    }
}
