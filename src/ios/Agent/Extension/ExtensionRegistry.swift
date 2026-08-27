import Foundation
import JavaScriptCore

// MARK: - Extension Registry

/// Loads enabled extensions, hosts their JS runtimes, and exposes their
/// registered tools to the agent as `AgentToolDefinition`s. Also provides
/// the native bridge callbacks (shell/file/permission) the JS `minis.api`
/// routes to.
///
/// Lifecycle: `reload()` after install/uninstall/enable/disable. The agent
/// tool dispatcher asks `extensionToolDefinitions` for the current tool set
/// and routes `extension:<id>:<tool>` calls to `executeExtensionTool`.
final class ExtensionRegistry {
    static let shared = ExtensionRegistry()

    /// Live runtimes keyed by extension id (only enabled extensions).
    private var runtimes: [String: ExtensionJSRuntime] = [:]
    /// Live Lua runtimes keyed by extension id (only enabled extensions).
    private var luaRuntimes: [String: ExtensionLuaRuntime] = [:]
    /// Extension id → registered tool name → RegisteredTool.
    private var toolIndex: [String: [String: ExtensionJSRuntime.RegisteredTool]] = [:]
    /// Extension id → registered Lua tool name → RegisteredTool.
    private var luaToolIndex: [String: [String: ExtensionLuaRuntime.RegisteredTool]] = [:]
    /// Extension id → registered command name → RegisteredCommand.
    private var commandIndex: [String: [String: ExtensionJSRuntime.RegisteredCommand]] = [:]
    /// Extension id → registered Lua command name → RegisteredCommand.
    private var luaCommandIndex: [String: [String: ExtensionLuaRuntime.RegisteredCommand]] = [:]
    private var manifests: [String: ExtensionManifest] = [:]

    private init() {}

    // MARK: - Loading

    /// (Re)load all enabled extensions from the store. Call after any
    /// install/uninstall/enable/disable change.
    func reload() async {
        // Built-in plugins (todo / sub-agents) have no zip bundle — their
        // capabilities are native and served via builtinToolDefinitions();
        // skip them here so reload doesn't try to read a missing manifest.
        let records = await ExtensionStore.shared.list()
            .filter(\.enabled)
            .filter { !BuiltinExtension.isBuiltin($0.id) }
        runtimes.removeAll()
        luaRuntimes.removeAll()
        toolIndex.removeAll()
        luaToolIndex.removeAll()
        commandIndex.removeAll()
        luaCommandIndex.removeAll()
        manifests.removeAll()

        for record in records {
            do {
                try await load(record)
            } catch {
                AppLogger(category: "ExtensionRegistry").error("Failed to load \(record.id): \(error.localizedDescription)")
                ExtensionLogStore.shared.log("Failed to load \(record.id): \(error.localizedDescription)", level: .error)
            }
        }
    }

    private func load(_ record: ExtensionStore.Record) async throws {
        let manifestURL = record.bundleURL.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw ExtensionError.missingManifest
        }
        let manifest = try ExtensionManifest.parse(data: manifestData)
        manifests[record.id] = manifest

        let runtime = ExtensionJSRuntime(
            extensionID: record.id,
            bridge: makeBridge(extensionID: record.id, manifest: manifest)
        )
        let luaRuntime = ExtensionLuaRuntime(extensionID: record.id)
        // Share the native bridge (shell/file/permission) so Lua's
        // minis.api.shell/file/permission are real, not stubs.
        luaRuntime.bridge = makeBridge(extensionID: record.id, manifest: manifest)

        // Evaluate tool/command/hook scripts, dispatching by language.
        // .js → JavaScriptCore runtime; .lua → vendored Lua 5.4 runtime.
        for tool in manifest.tools ?? [] {
            let url = record.bundleURL.appendingPathComponent(tool.file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if (tool.language ?? "js") == "lua" {
                try luaRuntime.evaluate(source, chunkName: tool.file)
            } else {
                try runtime.evaluateScript(source, fileName: tool.file)
            }
        }
        for command in manifest.commands ?? [] {
            let url = record.bundleURL.appendingPathComponent(command.file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if (command.language ?? "js") == "lua" {
                try luaRuntime.evaluate(source, chunkName: command.file)
            } else {
                try runtime.evaluateScript(source, fileName: command.file)
            }
        }
        for hook in manifest.hooks ?? [] {
            let url = record.bundleURL.appendingPathComponent(hook.file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if (hook.language ?? "js") == "lua" {
                try luaRuntime.evaluate(source, chunkName: hook.file)
            } else {
                try runtime.evaluateScript(source, fileName: hook.file)
            }
        }

        // Register JS + Lua tools/commands in their indexes.
        runtimes[record.id] = runtime
        if !luaRuntime.registeredTools.isEmpty || !luaRuntime.registeredCommands.isEmpty || !luaRuntime.eventHandlers.isEmpty {
            luaRuntimes[record.id] = luaRuntime
        }
        var byName: [String: ExtensionJSRuntime.RegisteredTool] = [:]
        for tool in runtime.registeredTools {
            byName[tool.name] = tool
        }
        toolIndex[record.id] = byName
        var cmdByName: [String: ExtensionJSRuntime.RegisteredCommand] = [:]
        for command in runtime.registeredCommands {
            cmdByName[command.name] = command
        }
        commandIndex[record.id] = cmdByName

        // Lua tools/commands (from .lua scripts in this extension).
        var luaToolByName: [String: ExtensionLuaRuntime.RegisteredTool] = [:]
        for tool in luaRuntime.registeredTools {
            luaToolByName[tool.name] = tool
        }
        luaToolIndex[record.id] = luaToolByName
        var luaCmdByName: [String: ExtensionLuaRuntime.RegisteredCommand] = [:]
        for command in luaRuntime.registeredCommands {
            luaCmdByName[command.name] = command
        }
        luaCommandIndex[record.id] = luaCmdByName

        // Apply the extension's theme (if any) — last loaded wins. Uses
        // ThemeManager so ChatColors (which observes it) re-evaluates
        // immediately.
        if let themeDef = manifest.theme {
            let themeURL = record.bundleURL.appendingPathComponent(themeDef.file)
            if let data = try? Data(contentsOf: themeURL),
               let theme = ThemeTokens.parse(data: data) {
                ThemeManager.shared.apply(theme)
                AppLogger(category: "ExtensionTheme").info("Applied theme '\(theme.name)' from \(record.id)")
            }
        }
    }

    // MARK: - Tool surface for the agent

    /// Built-in default plugins (todo / sub-agents) are native capabilities
    /// registered like extensions. This returns their tool definitions when
    /// the corresponding built-in plugin is enabled. (MainActor because the
    /// todo/sub-agent tool builders live in @MainActor AIChatViewModel.)
    @MainActor
    func builtinToolDefinitions() -> [AgentToolDefinition] {
        var defs: [AgentToolDefinition] = []
        if isBuiltinEnabled(BuiltinExtension.todoID) {
            defs.append(contentsOf: AIChatViewModel.makeTodoToolDefinitions())
        }
        if isBuiltinEnabled(BuiltinExtension.subagentsID) {
            defs.append(AIChatViewModel.makeSubagentToolDefinition())
            defs.append(AIChatViewModel.makeAgentStatusToolDefinition())
        }
        return defs
    }

    /// Whether a built-in default plugin is enabled (falls back to true on
    /// store errors so disabling is a deliberate opt-out). Backed by a
    /// UserDefaults mirror kept in sync by ExtensionStore.setEnabled.
    func isBuiltinEnabled(_ id: String) -> Bool {
        guard BuiltinExtension.isBuiltin(id) else { return false }
        // default true unless explicitly disabled
        if UserDefaults.standard.object(forKey: "builtin.enabled.\(id)") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "builtin.enabled.\(id)")
    }

    // MARK: - Prompt modules

    /// Returns the system-prompt guidance text for one built-in plugin
    /// (prompt module or todo/sub-agents), or nil when the plugin is
    /// disabled. The text is user-editable: if an override is stored under
    /// `minis.extsettings.<id>.promptText`, that is returned; otherwise the
    /// built-in default (`BuiltinExtension.defaultPromptText`) is used.
    /// (Static so AIChatViewModel.baseSystemPrompt can call it without an
    /// actor hop; the switch state is read from UserDefaults synchronously.)
    static func builtinGuidanceText(_ id: String) -> String? {
        guard BuiltinExtension.isBuiltin(id) else { return nil }
        let enabled: Bool
        if UserDefaults.standard.object(forKey: "builtin.enabled.\(id)") == nil {
            enabled = true
        } else {
            enabled = UserDefaults.standard.bool(forKey: "builtin.enabled.\(id)")
        }
        guard enabled else { return nil }
        if let override = ExtensionSettingsStore.shared.stringValue(extensionID: id, key: "promptText") {
            return override
        }
        return BuiltinExtension.defaultPromptText(id)
    }

    /// Back-compat alias: prompt modules are served by builtinGuidanceText.
    static func promptModuleText(_ id: String) -> String? {
        guard BuiltinExtension.isBuiltin(id), BuiltinExtension.isPromptModule(id) else { return nil }
        return builtinGuidanceText(id)
    }

    /// The actual guidance text for each prompt module (see BuiltinExtension
    /// docs for the plugin-model rationale). Kept terse — the model can run
    /// `--help` / `minis-config topic-help` for full details.
    static func promptModuleBody(_ id: String) -> String? {
        switch id {
        case BuiltinExtension.promptShellID:
            return "Shell execution:\n"
                + "- Each shell_execute is an isolated process; the filesystem persists. `which <cmd>` before `apk add` — many packages persist. "
                + "For waits use the `delay` parameter (not `sleep`) so concurrent tasks can use the shell. "
                + "Never end a turn with a promise of future action — nothing runs after your turn. Poll with delay-then-check, or state honestly that background work only resumes when the user messages again.\n"
                + "- Commands over 1000 chars: write a script with file_write first, then run it. Multi-line commands are fine. "
                + "The default shell is BusyBox ash; bashisms (arrays, [[ ]], (( )), brace ranges, process substitution) auto-run under bash. Only globstar (**) has no fallback — use `find`.\n"
                + "- Python: prefer Alpine packages (`apk search py3-<name>`, `apk add py3-numpy ...`) — many PyPI wheels lack musllinux_aarch64. "
                + "Use pip only for pure-Python packages. matplotlib: set `matplotlib.use('Agg')` (no display server).\n"
                + "- Background servers must redirect stdout/stderr (`python3 -m http.server 8765 > /dev/null 2>&1 &`) or they die on shell exit (SIGPIPE).\n"
                + "- File search: look under /var/minis/ first (workspace/attachments/shared, mounts/*); widen only if clearly not there.\n\n"
        case BuiltinExtension.promptWorkspaceID:
            return "Shared directory /var/minis/ (bidirectional between shell and app):\n"
                + "  attachments/ — media; workspace/ — working files; offloads/ — auto-saved large outputs; browser/ — screenshots; "
                + "  shared/ — cross-session artifacts; memory/GLOBAL.md — persistent global memory; memory/YYYY-MM-DD.md — daily log; "
                + "  mounts/<name>/ — user-mounted external folders (presence varies; some read-only). Check mounts first for external/user files.\n"
                + "minis:// URLs are app-internal, NOT web URLs: resource URLs (attachments/workspace/shared/...) can be opened in browser_use; "
                + "action URLs (open_terminal, views, settings) must be Markdown links in chat, never browser_use. "
                + "Percent-encode non-ASCII in manually-built minis:// URLs; prefer the `minis_url` from tool results. "
                + "Embed files as Markdown links/images: images/audio/video inline with ![](minis://...); append `?auto_play=true` for immediate audio; "
                + "other files as [name](minis://...). Supported inline: png/jpg/gif/webp, mp3/m4a/wav, mp4/mov/m4v. Tap previews open natively.\n"
                + "File creation: file_write CREATES, file_edit MODIFIES (exact old→new replacement; file_read first). "
                + "Prefer file_write over echo/heredoc for contents (atomic, no quoting pitfalls); heredocs work but write-to-file is safer for long content.\n\n"
        case BuiltinExtension.promptMemoryID:
            return "Memory system:\n"
                + "- memory_write saves to today's daily log (YYYY-MM-DD.md) — use proactively for preferences, project context, action items. "
                + "- GLOBAL.md holds persistent preferences; read with file_read (NOT memory_get), update via file_read→file_edit. "
                + "Only write GLOBAL.md when the user explicitly asks; keep it concise, deduplicated, no session logs.\n"
                + "- memory_get recalls past knowledge before starting tasks.\n"
                + "- Never remember passwords/API keys/tokens/secrets — warn first. Keep memories concise and factual.\n\n"
        case BuiltinExtension.promptCodingID:
            return "Coding workflow (projects in /var/minis/workspace):\n"
                + "- Read before you write (file_read first; use file_edit with exact replacement). One concern per file; small focused modules.\n"
                + "- Verify after every change: run it or syntax-check (`python3 -m py_compile f.py`, `node --check f.js`, `swiftc -parse f.swift`) — never report code as working without executing. "
                + "Iterate edit→run→fix; read full errors before retrying.\n"
                + "- Use todo_create/todo_update/todo_list for multi-file or multi-step work. Keep build outputs/caches in /tmp; deliverables in workspace.\n"
                + "- Follow AGENTS.md / CLAUDE.md conventions when present in the project.\n\n"
        case BuiltinExtension.promptAppleID:
            return "Native Apple tools (CLIs at /usr/local/bin, `apple-` prefix): alarm, bluetooth, calendar, clipboard, device, healthkit, homekit, location, maps, media, nfc, nlp, notification, open, photos, player, reminders, speak, speech, vision, weather. "
                + "All output JSON (--compact minify, -q data-only); run any with --help. "
                + "apple-open <url> opens via system handler; for tappable links write a Markdown link instead (maps://, tel:, https: handled natively). "
                + "apple-player play <file> opens native player (session_id; pause/resume/seek/status/stop). "
                + "apple-healthkit covers 100+ quantity types, 60+ categories, characteristics, workouts/ECG/GAD-7; `types` discovers them; prefer `batch --types ... --days N` (one auth prompt); `log --type --value` writes. "
                + "apple-homekit: list → search --query/--type/--room → get --name → set --name --characteristic --value; scenes/trigger. "
                + "apple-alarm sets alarms/timers (iOS 26+); visible on the Minis home screen (alarm icon) or minis://views/alarm — tell the user. "
                + "apple-vision: ocr/barcode/classify/detect/faces/analyze/similarity/overlap.\n\n"
        case BuiltinExtension.promptMinisCLIID:
            return "Minis CLI tools:\n"
                + "- minis-config: read/change settings programmatically; `--help`, `topic-help <topic>`; `--filter/--page/--page-size` for arrays; "
                + "writes trigger an in-app confirmation sheet and revertable audit log (relay the `user_message`); `permission_denied` means the user disabled it. "
                + "Can add providers + write API keys (literal or `$$ENV_VAR`); secrets are write-only — never read API keys/OAuth tokens.\n"
                + "- minis-model-use: invoke other user-configured models; `list`/`search`/`run --model <id> --input <json>`; OpenAI Chat Completions `messages` is the primary input; "
                + "`extra_body`/`--endpoint`/`passthrough` escape hatches exist; read `warnings`/`applied_extras`; image generation is slow (1-5 min) — one long call with a big timeout.\n"
                + "- minis-sessions-cli: list/search/messages/send/retry/status/open for chat sessions (`--help`).\n"
                + "- minis-browser-use: CLI wrapper for browser_use — same actions, `<action> --flag value` or `--json`; prefer it for multi-step/batch flows (chain in bash scripts).\n"
                + "- Interactive terminal: [Open Terminal](minis://open_terminal?init_command=<percent-encoded>) for interactive stdin (ssh, htop, vi); "
                + "use shell_execute for everything else.\n\n"
        case BuiltinExtension.promptEnvSecretsID:
            return "Environment variables:\n"
                + "- NEVER echo/print/cat env var values (API keys, tokens, passwords) — reference by name ($API_KEY) in scripts.\n"
                + "- Missing var? Tell the user + provide a tappable link: [Set ENV_NAME](minis://settings/environments?create_key=ENV_NAME&create_value=&create_note=...).\n"
                + "- Settings deep links: prefer [Label](minis://settings/<path>) over prose — paths: providers, model-groups, usage, skills, memory, storage, shared-folders, mount-external, logs, appearance, background, about, permissions, environments, rootfs. "
                + "These are app deep links: Markdown links in chat, never browser_use.\n"
                + "- Check a var with `[ -n \"$VAR\" ] && echo set || echo not-set` — never output its value.\n\n"
        case BuiltinExtension.promptStyleID:
            return "Tool call style:\n"
                + "- Default: call tools directly without narrating routine low-risk calls. Narrate only when it helps (multi-step, complex, sensitive). "
                + "Keep narration brief; use a tool instead of explaining or asking when one exists. "
                + "Fill missing details with reasonable defaults; ask only when genuinely ambiguous.\n"
                + "Tone: reply in the user's language; be concise; prefer action over explanation.\n\n"
        case BuiltinExtension.promptScheduledID:
            return "Scheduled tasks: crontab/at/nohup stop when the app suspends — in-app scheduled scripts may not run. "
                + "For recurring tasks beyond this conversation, point the user to an Apple Shortcuts automation (the only reliable periodic trigger on iOS). "
                + "Polling within a turn is different: that's shell_execute `delay` chains.\n\n"
        case BuiltinExtension.promptExtensionsID:
            return "Extension tools (extension_<id>_<name>):\n"
                + "- Call them like any other tool, args as a JSON string. They run in a sandboxed JS/Lua runtime; failures return an error string — read it and adapt, or use built-in tools instead.\n"
                + "- Do not fabricate extension tool names — only call extension_ tools that appear in your tool list.\n\n"
        default:
            return nil
        }
    }

    /// `AgentToolDefinition`s for all registered extension tools, namespaced
    /// as `extension_<id>_<name>` so collisions across extensions are avoided.
    func extensionToolDefinitions() -> [AgentToolDefinition] {
        var defs: [AgentToolDefinition] = []
        for (extID, tools) in toolIndex {
            guard let manifest = manifests[extID] else { continue }
            for (toolName, _) in tools {
                let apiName = "extension_\(extID)_\(toolName)"
                defs.append(AgentToolDefinition(
                    name: apiName,
                    description: "Extension tool '\(toolName)' from '\(manifest.name)'. Executes JavaScript in the extension's sandboxed runtime.",
                    parameters: [
                        "tool_title": AgentToolParam(type: .string, description: "Concise summary shown to the user."),
                        "args": AgentToolParam(type: .string, description: "JSON object of arguments to pass to the extension tool."),
                    ],
                    required: ["tool_title", "args"]
                ))
            }
        }
        // Lua tools.
        for (extID, tools) in luaToolIndex {
            guard let manifest = manifests[extID] else { continue }
            for (toolName, _) in tools {
                let apiName = "extension_\(extID)_\(toolName)"
                defs.append(AgentToolDefinition(
                    name: apiName,
                    description: "Extension tool '\(toolName)' from '\(manifest.name)'. Executes Lua in the extension's sandboxed runtime.",
                    parameters: [
                        "tool_title": AgentToolParam(type: .string, description: "Concise summary shown to the user."),
                        "args": AgentToolParam(type: .string, description: "JSON object of arguments to pass to the extension tool."),
                    ],
                    required: ["tool_title", "args"]
                ))
            }
        }
        return defs
    }

    /// Execute an extension tool by its namespaced API name
    /// (`extension_<id>_<tool>`). Returns (output, isError).
    func executeExtensionTool(apiName: String, argsJSON: String) async -> (String, Bool) {
        // apiName = "extension_<id>_<tool>"
        let parts = apiName.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return ("Error: malformed extension tool name", true) }
        // The extension id itself may contain underscores (e.g. com_example_myext),
        // so split from the front: "extension" + id + rest. We reconstruct by
        // finding the registry entry whose id matches a prefix.
        let prefix = "extension_"
        guard apiName.hasPrefix(prefix) else { return ("Error: not an extension tool", true) }
        let tail = String(apiName.dropFirst(prefix.count))
        // Longest matching extension id prefix wins.
        var matched: (String, String)?
        for extID in toolIndex.keys where tail.hasPrefix(extID + "_") {
            let toolName = String(tail.dropFirst(extID.count + 1))
            if toolIndex[extID]?[toolName] != nil {
                matched = (extID, toolName)
                break
            }
        }
        guard let (extID, toolName) = matched else {
            return ("Error: extension tool '\(apiName)' not found", true)
        }

        // Parse args JSON.
        var args: [String: Any] = [:]
        if let data = argsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = obj
        }

        // JS runtime first, then Lua runtime.
        if let runtime = runtimes[extID], let tool = toolIndex[extID]?[toolName] {
            return runtime.callTool(tool, args: args)
        }
        if let luaRuntime = luaRuntimes[extID], let luaTool = luaToolIndex[extID]?[toolName] {
            return luaRuntime.callTool(luaTool, args: args)
        }
        return ("Error: extension tool '\(apiName)' not found", true)
    }

    // MARK: - Commands

    /// All registered extension slash commands: [(name, extensionID)]
    /// Names are prefixed with `ext-` by the extension author; exposed as-is.
    func extensionCommands() -> [(name: String, extensionID: String)] {
        var out: [(String, String)] = []
        for (extID, cmds) in commandIndex {
            for (cmdName, _) in cmds {
                out.append((cmdName, extID))
            }
        }
        for (extID, cmds) in luaCommandIndex {
            for (cmdName, _) in cmds {
                out.append((cmdName, extID))
            }
        }
        return out
    }

    /// Execute a registered extension command by name. Returns (output, isError).
    func executeExtensionCommand(name: String, args: [String]) async -> (String, Bool) {
        for (extID, cmds) in commandIndex {
            if let cmd = cmds[name], let runtime = runtimes[extID] {
                return runtime.callCommand(cmd, args: args)
            }
        }
        for (extID, cmds) in luaCommandIndex {
            if let cmd = cmds[name], let luaRuntime = luaRuntimes[extID] {
                return luaRuntime.callCommand(cmd, args: args)
            }
        }
        return ("Error: extension command '\(name)' not found", true)
    }

    // MARK: - Events

    /// Fire an agent lifecycle event to all extensions with matching hooks.
    func emitLifecycleEvent(_ event: String, data: [String: Any]) {
        for runtime in runtimes.values {
            runtime.emitEvent(event, data: data)
        }
        for luaRuntime in luaRuntimes.values {
            luaRuntime.emitEvent(event, data: data)
        }
    }

    /// Publish an extension-to-extension event (minis.api.event.emit).
    /// Routes to every extension whose runtime has a handler for the event
    /// name, mirroring lifecycle events.
    func emitExtensionEvent(_ event: String, data: [String: Any]) {
        emitLifecycleEvent(event, data: data)
    }

    // MARK: - UI widgets

    /// All enabled UI widgets: (extensionID, UIDef, bundleURL).
    func uiWidgets() -> [(extensionID: String, widget: ExtensionManifest.UIDef, bundleURL: URL)] {
        var out: [(String, ExtensionManifest.UIDef, URL)] = []
        for (extID, manifest) in manifests {
            for widget in manifest.ui ?? [] {
                let bundle = ExtensionStore.shared.extensionsDir.appendingPathComponent(extID, isDirectory: true)
                out.append((extID, widget, bundle))
            }
        }
        return out
    }

    /// Declared permissions of an installed extension (from its manifest).
    func manifestPermissions(for extensionID: String) -> [String] {
        manifests[extensionID]?.permissions ?? []
    }

    // MARK: - Native bridge

    private func makeBridge(extensionID: String, manifest: ExtensionManifest) -> ExtensionJSRuntime.Bridge {
        ExtensionJSRuntime.Bridge(
            shell: { cmd, opts in
                // Permission gate: "shell" must be declared + granted.
                guard manifest.permissions.contains("shell") else {
                    return ("Error: extension '\(extensionID)' needs 'shell' permission (declare it in manifest.json)", true)
                }
                // First-use confirmation via the standard permission dialog.
                let granted = await PermissionGate.request("shell", extensionID: extensionID)
                guard granted else {
                    return ("Permission denied: shell", true)
                }
                guard let sessionID = await ActiveSession.id() else {
                    return ("Error: no active session", true)
                }
                do {
                    let timeout = (opts["timeout"] as? Int) ?? 900
                    let result = try await ISHExecutionCoordinator.shared.execute(
                        sessionId: sessionID,
                        command: cmd,
                        timeout: TimeInterval(timeout),
                        lineCallback: { _ in },
                        pidCallback: { _ in }
                    )
                    return (result.output, result.exitCode != 0)
                } catch {
                    return ("Error: \(error.localizedDescription)", true)
                }
            },
            fileRead: { path in
                guard manifest.permissions.contains("files") else {
                    return ("Error: extension '\(extensionID)' needs 'files' permission", true)
                }
                let granted = await PermissionGate.request("files", extensionID: extensionID)
                guard granted else { return ("Permission denied: files", true) }
                guard let host = Self.resolveSandboxPath(path) else {
                    return ("Error: only /var/minis/ paths are readable", true)
                }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: host)),
                      let text = String(data: data, encoding: .utf8) else {
                    return ("Error: cannot read \(path)", true)
                }
                return (text, false)
            },
            fileWrite: { path, content, _ in
                guard manifest.permissions.contains("files") else {
                    return ("Error: extension '\(extensionID)' needs 'files' permission", true)
                }
                let granted = await PermissionGate.request("files", extensionID: extensionID)
                guard granted else { return ("Permission denied: files", true) }
                guard let host = Self.resolveSandboxPath(path) else {
                    return ("Error: only /var/minis/ paths are writable", true)
                }
                do {
                    try FileManager.default.createDirectory(
                        at: URL(fileURLWithPath: host).deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try content.write(toFile: host, atomically: true, encoding: .utf8)
                    return ("Wrote \(path) (\(content.count) chars)", false)
                } catch {
                    return ("Error: cannot write \(path): \(error.localizedDescription)", true)
                }
            },
            requestPermission: { kind in
                await PermissionGate.request(kind, extensionID: extensionID)
            },
            hasPermission: { kind in
                manifest.permissions.contains(kind)
            },
            postToUI: { extID, payload in
                // Route agent-side minis.api.ui.postMessage to the rendered
                // widgets of this extension (see ExtensionWidgetMessageCenter).
                ExtensionWidgetMessageCenter.shared.post(to: extID, payload: payload)
            },
            emitEvent: { name, data in
                // Cross-extension events via the event bus (routes to every
                // extension runtime with a matching handler).
                ExtensionRegistry.shared.emitExtensionEvent(name, data: data)
            },
            settingsGet: { extID, key in
                let defs = manifest.settings ?? []
                guard let def = defs.first(where: { $0.key == key }) else { return nil }
                return ExtensionSettingsStore.shared.get(extensionID: extID, key: key, settings: defs)
            },
            settingsSet: { extID, key, value in
                let defs = manifest.settings ?? []
                guard defs.contains(where: { $0.key == key }) else { return }
                ExtensionSettingsStore.shared.set(extensionID: extID, key: key, value: value)
            },
            settingsAll: { extID in
                ExtensionSettingsStore.shared.values(extensionID: extID, settings: manifest.settings ?? [])
            }
        )
    }

    /// Resolve a sandbox Linux path to a host path (only /var/minis/**).
    static func resolveSandboxPath(_ linuxPath: String) -> String? {
        let prefix = "/var/minis/"
        guard linuxPath.hasPrefix(prefix) else { return nil }
        let tail = String(linuxPath.dropFirst(prefix.count))
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return library.appendingPathComponent("MinisChat/minis/\(tail)").path
    }
}

/// Permission gate for extension first-use confirmation. Reuses the
/// standard OffloadPermissionDialog sheet: constructs a PermissionRequest
/// into `OffloadPermissionManager.pendingRequest` (the dialog modifier is
/// attached to AIChatView), awaits the Allow/Deny continuation, and caches
/// per-extension grants for the session. Times out after 30s (deny).
enum PermissionGate {
    private static var grantedCache: [String: Set<String>] = [:]  // extID → kinds
    private static let logger = AppLogger(category: "ExtensionPermission")

    static func request(_ kind: String, extensionID: String) async -> Bool {
        if grantedCache[extensionID, default: []].contains(kind) { return true }

        let allowed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let request = PermissionRequest(
                id: UUID().uuidString,
                commandName: "extension:\(extensionID)",
                displayLabel: extensionID,
                description: "The extension requests **\(kind)** access. This lets its agent-side code \(kindDescription(kind)).",
                fullCommand: "extension \(extensionID) requests \(kind) access",
                continuation: cont
            )
            Task { @MainActor in
                OffloadPermissionManager.shared.pendingRequest = request
                // 30s timeout (mirrors OffloadPermissionManager.checkPermission)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if OffloadPermissionManager.shared.pendingRequest?.id == request.id {
                        OffloadPermissionManager.shared.pendingRequest = nil
                        cont.resume(returning: false)
                    }
                }
            }
        }

        logger.info("\(extensionID) \(kind) -> \(allowed ? "granted" : "denied")")
        if allowed {
            grantedCache[extensionID, default: []].insert(kind)
        }
        return allowed
    }

    private static func kindDescription(_ kind: String) -> String {
        switch kind {
        case "shell": return "run shell commands in the sandbox"
        case "files": return "read and write files under /var/minis/"
        case "network": return "make network requests"
        case "ui": return "render UI widgets in this session"
        default: return "use device capabilities"
        }
    }
}

/// Active session id snapshot, kept in sync by AIChatViewModel.
enum ActiveSession {
    private static var current: String?
    static func set(_ id: String?) { current = id }
    static func id() -> String? { current }
}
