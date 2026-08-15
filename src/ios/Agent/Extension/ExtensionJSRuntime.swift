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
        /// Check whether the extension declared a permission in its manifest.
        var hasPermission: @Sendable (String) -> Bool
        var postToUI: @Sendable (String, [String: Any]) -> Void
        var emitEvent: @Sendable (String, [String: Any]) -> Void
        /// Read one declared setting value (or its default).
        var settingsGet: @Sendable (String, String) -> Any?
        /// Persist one declared setting value.
        var settingsSet: @Sendable (String, String, Any) -> Void
        /// All declared settings with current values.
        var settingsAll: @Sendable (String) -> [String: Any]
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
    private(set) var registeredCommands: [RegisteredCommand] = []
    private(set) var eventHandlers: [String: [JSValue]] = [:]

    struct RegisteredTool {
        let name: String
        let description: String
        let execute: JSValue  // JS function
    }

    struct RegisteredCommand {
        let name: String
        let handler: JSValue  // JS function
    }

    /// Execute a registered slash command. Returns output string.
    func callCommand(_ command: RegisteredCommand, args: [String]) -> (String, Bool) {
        let jsArgs = JSValue(object: args, in: context)!
        guard let result = command.handler.call(withArguments: [jsArgs]) else {
            return ("Error: command execution failed", true)
        }
        if result.isUndefined || result.isNull {
            return ("", false)
        }
        if let str = result.toString() {
            return (str, false)
        }
        return (result.toObject() as? String ?? "\(result)", false)
    }

    /// Fire an event to all registered `minis.on(event, handler)` hooks.
    /// Handlers run synchronously on the JS thread; results are logged.
    func emitEvent(_ event: String, data: [String: Any]) {
        guard let handlers = eventHandlers[event], !handlers.isEmpty else { return }
        let jsData = JSValue(object: data, in: context)!
        for handler in handlers {
            guard let result = handler.call(withArguments: [jsData]) else { continue }
            if result.isString, let str = result.toString(), !str.isEmpty {
                AppLogger(category: "ExtHook[\(event)]").info("\(str)")
            }
        }
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
            guard !name.isEmpty, let execute, !execute.isUndefined else { return }
            self.registeredTools.append(RegisteredTool(name: name, description: desc, execute: execute))
        }
        minis.setObject(registerTool, forKeyedSubscript: "registerTool" as NSString)

        // registerCommand
        let registerCommand: @convention(block) (JSValue) -> Void = { [weak self] def in
            guard let self else { return }
            let name = def.objectForKeyedSubscript("name").toString() ?? ""
            let handler = def.objectForKeyedSubscript("handler")
            guard !name.isEmpty, let handler, !handler.isUndefined else { return }
            self.registeredCommands.append(RegisteredCommand(name: name, handler: handler))
        }
        minis.setObject(registerCommand, forKeyedSubscript: "registerCommand" as NSString)

        // on(event, handler) — event hook subscription
        let on: @convention(block) (JSValue, JSValue) -> Void = { [weak self] nameVal, handlerVal in
            guard let self else { return }
            let name = nameVal.toString() ?? ""
            guard !name.isEmpty, !handlerVal.isUndefined else { return }
            self.eventHandlers[name, default: []].append(handlerVal)
        }
        minis.setObject(on, forKeyedSubscript: "on" as NSString)

        // log
        let log: @convention(block) (JSValue) -> Void = { [extensionID] args in
            let joined = (0..<args.toArray().count).map { args.objectAtIndexedSubscript($0).toString() ?? "" }.joined(separator: " ")
            AppLogger(category: "Ext[\(extensionID)]").info("\(joined)")
        }
        minis.setObject(log, forKeyedSubscript: "log" as NSString)

        // api.* — file is an object {read, write}; others are functions.
        let api = JSValue(newObjectIn: context)!
        api.setObject(makeShellBridge(), forKeyedSubscript: "shell" as NSString)
        let fileObj = JSValue(newObjectIn: context)!
        fileObj.setObject(makeFileReadBridge(), forKeyedSubscript: "read" as NSString)
        fileObj.setObject(makeFileWriteBridge(), forKeyedSubscript: "write" as NSString)
        api.setObject(fileObj, forKeyedSubscript: "file" as NSString)
        api.setObject(makePermissionBridge(), forKeyedSubscript: "permission" as NSString)
        api.setObject(makeEventBridge(), forKeyedSubscript: "event" as NSString)
        api.setObject(makeOffloadBridge(), forKeyedSubscript: "offload" as NSString)
        api.setObject(makeUIBridge(), forKeyedSubscript: "ui" as NSString)
        let settingsObj = JSValue(newObjectIn: context)!
        settingsObj.setObject(makeSettingsGetBridge(), forKeyedSubscript: "get" as NSString)
        settingsObj.setObject(makeSettingsSetBridge(), forKeyedSubscript: "set" as NSString)
        api.setObject(settingsObj, forKeyedSubscript: "settings" as NSString)
        minis.setObject(api, forKeyedSubscript: "api" as NSString)

        // minis.store = { get, set } — small KV persistence scoped to the
        // extension (UserDefaults keyed by extension id).
        let store = JSValue(newObjectIn: context)!
        store.setObject(makeStoreGetBridge(), forKeyedSubscript: "get" as NSString)
        store.setObject(makeStoreSetBridge(), forKeyedSubscript: "set" as NSString)
        minis.setObject(store, forKeyedSubscript: "store" as NSString)

        // minis.http = { fetch } — HTTP via URLSession (network permission).
        let http = JSValue(newObjectIn: context)!
        http.setObject(makeHTTPBridge(), forKeyedSubscript: "fetch" as NSString)
        minis.setObject(http, forKeyedSubscript: "http" as NSString)

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
            return promise ?? JSValue(undefinedIn: context)
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
            return promise ?? JSValue(undefinedIn: context)
        }
    }

    private func makeFileWriteBridge() -> @convention(block) (JSValue, JSValue) -> JSValue {
        let bridge = self.bridge
        let context = self.context
        return { pathVal, contentVal in
            let path = pathVal.toString() ?? ""
            let content = contentVal.toString() ?? ""
            let promise = JSValue(newPromiseIn: context) { resolve, reject in
                Task {
                    let (out, isErr) = await bridge.fileWrite(path, content, false)
                    if isErr { reject?.call(withArguments: [out]) } else { resolve?.call(withArguments: [out]) }
                }
            }
            return promise ?? JSValue(undefinedIn: context)
        }
    }

    private func makeOffloadBridge() -> @convention(block) (JSValue, JSValue) -> JSValue {
        // Reserved surface: routes to the shell bridge (apple-* CLIs run in
        // the sandbox like any other command). Returns a promise.
        let bridge = self.bridge
        let context = self.context
        return { nameVal, argsVal in
            let name = nameVal.toString() ?? ""
            let args = argsVal.toString() ?? ""
            let cmd = "\(name) \(args)".trimmingCharacters(in: .whitespaces)
            let promise = JSValue(newPromiseIn: context) { resolve, reject in
                Task {
                    let (out, isErr) = await bridge.shell(cmd, [:])
                    if isErr { reject?.call(withArguments: [out]) } else { resolve?.call(withArguments: [out]) }
                }
            }
            return promise ?? JSValue(undefinedIn: context)
        }
    }

    private func makeUIBridge() -> @convention(block) (JSValue) -> Void {
        let bridge = self.bridge
        let extID = self.extensionID
        return { dataVal in
            let payload = dataVal.toObject() as? [String: Any] ?? [:]
            bridge.postToUI(extID, payload)
        }
    }

    private func makeSettingsGetBridge() -> @convention(block) (JSValue) -> JSValue {
        let bridge = self.bridge
        let extID = self.extensionID
        return { keyVal in
            let key = keyVal.toString() ?? ""
            let value = bridge.settingsGet(extID, key)
            if let value {
                return JSValue(object: value, in: self.context) ?? JSValue(undefinedIn: self.context)
            }
            return JSValue(undefinedIn: self.context)
        }
    }

    private func makeSettingsSetBridge() -> @convention(block) (JSValue, JSValue) -> Void {
        let bridge = self.bridge
        let extID = self.extensionID
        return { keyVal, valueVal in
            let key = keyVal.toString() ?? ""
            let value = valueVal.toObject()
            bridge.settingsSet(extID, key, value as Any)
        }
    }

    private func makeStoreGetBridge() -> @convention(block) (JSValue) -> JSValue {
        let extID = self.extensionID
        return { keyVal in
            let key = keyVal.toString() ?? ""
            let fullKey = "ext.kv.\(extID).\(key)"
            let value = UserDefaults.standard.string(forKey: fullKey)
            return JSValue(object: value as Any, in: self.context)!
        }
    }

    private func makeStoreSetBridge() -> @convention(block) (JSValue, JSValue) -> Void {
        let extID = self.extensionID
        return { keyVal, valueVal in
            let key = keyVal.toString() ?? ""
            let fullKey = "ext.kv.\(extID).\(key)"
            if valueVal.isUndefined || valueVal.isNull {
                UserDefaults.standard.removeObject(forKey: fullKey)
            } else {
                UserDefaults.standard.set(valueVal.toString() ?? "", forKey: fullKey)
            }
        }
    }

    private func makeHTTPBridge() -> @convention(block) (JSValue, JSValue) -> JSValue {
        let context = self.context
        let bridge = self.bridge
        return { urlVal, optsVal in
            let urlStr = urlVal.toString() ?? ""
            // Network permission gate (declared in manifest).
            guard bridge.hasPermission("network") else {
                let promise = JSValue(newPromiseIn: context) { _, reject in
                    reject?.call(withArguments: ["Error: extension needs 'network' permission (declare it in manifest.json)"])
                }
                return promise ?? JSValue(undefinedIn: context)
            }
            let method = (optsVal.objectForKeyedSubscript("method").toString() ?? "GET").uppercased()
            let body = optsVal.objectForKeyedSubscript("body").toString()
            let promise = JSValue(newPromiseIn: context) { resolve, reject in
                guard let url = URL(string: urlStr) else {
                    reject?.call(withArguments: ["Error: invalid URL"])
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = method
                if let body, !body.isEmpty {
                    request.httpBody = body.data(using: .utf8)
                }
                Task {
                    do {
                        let (data, response) = try await URLSession.shared.data(for: request)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        let text = String(data: data, encoding: .utf8) ?? ""
                        let result: [String: Any] = ["status": status, "body": text]
                        resolve?.call(withArguments: [JSValue(object: result, in: context)!])
                    } catch {
                        reject?.call(withArguments: [error.localizedDescription])
                    }
                }
            }
            return promise ?? JSValue(undefinedIn: context)
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
            return promise ?? JSValue(undefinedIn: context)
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
