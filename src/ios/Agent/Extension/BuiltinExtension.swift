import Foundation

// MARK: - Built-in Extension Support

/// Built-in ("default") extensions are first-class plugins shipped with the
/// app. They appear in the extension manager like installed .minisx bundles,
/// can be enabled/disabled, and gate real surfaces on that switch.
/// They have no zip bundle — their capabilities are native code.
///
/// Three kinds of built-in plugin exist:
///
/// 1. **Feature plugins** (`builtin.soul`, `builtin.mcp`, `builtin.mounts`,
///    `builtin.memory`, `builtin.skills`, `builtin.env-vars`,
///    `builtin.shared-folders`, `todoID`, `subagentsID`) — native features
///    with a UI surface and (usually) agent tools. Disabling one:
///      * removes its **Settings entry** (and other UI) — the surface is
///        gone from the interface and reappears when re-enabled,
///      * stops its **agent-side surface** (tool registration, prompt
///        fragments it owns),
///      * and drops its guidance text.
///    On-disk data is never deleted, so re-enabling restores everything.
///
/// 2. **Prompt modules** (`builtin.prompt.*`) — sections of the system prompt
///    that teach the model how to use an existing capability (shell
///    discipline, workspace layout, memory rules, coding workflow, apple-*
///    tools, minis CLI tools, env secrets, style, scheduled tasks, extension
///    tools). Disabling a prompt module ONLY removes that guidance text from
///    the prompt (saving tokens and keeping the core clean). The underlying
///    functionality is native and always available — the model simply is not
///    instructed about it.
///
/// 3. Every built-in plugin also exposes an editable `promptText` so the user
///    can rewrite the guidance the model sees. For prompt modules the default
///    is that module's built-in body; for feature plugins the default is
///    empty, i.e. their `promptText` is *additive* guidance.
///
/// The switch itself lives in the extensions DB with a UserDefaults mirror
/// (`builtin.enabled.<id>`, written by `ExtensionStore.setEnabled`), so
/// synchronous call sites — including SwiftUI `@AppStorage` — can gate on it
/// without an actor hop. Read it through `ExtensionRegistry.isBuiltinEnabled`.
enum BuiltinExtension {
    // MARK: Feature plugins
    static let todoID = "builtin.todo"
    static let subagentsID = "builtin.subagents"
    static let soulID = "builtin.soul"
    static let mcpID = "builtin.mcp"
    static let mountsID = "builtin.mounts"
    static let memoryID = "builtin.memory"
    static let skillsID = "builtin.skills"
    static let envVarsID = "builtin.env-vars"
    static let sharedFoldersID = "builtin.shared-folders"

    // MARK: Prompt-module plugins
    // These gate sections of baseSystemPrompt only; the features they
    // describe stay functional regardless of the switch.
    static let promptShellID = "builtin.prompt.shell"
    static let promptWorkspaceID = "builtin.prompt.workspace"
    static let promptMemoryID = "builtin.prompt.memory"
    static let promptCodingID = "builtin.prompt.coding"
    static let promptAppleID = "builtin.prompt.apple"
    static let promptMinisCLIID = "builtin.prompt.minis-cli"
    static let promptEnvSecretsID = "builtin.prompt.env-secrets"
    static let promptStyleID = "builtin.prompt.style"
    static let promptScheduledID = "builtin.prompt.scheduled"
    static let promptExtensionsID = "builtin.prompt.extensions"

    /// ID → display name.
    static func displayName(id: String) -> String {
        switch id {
        case todoID: return "Todo System"
        case subagentsID: return "Sub-agent Delegation"
        case soulID: return "Soul (Persona)"
        case mcpID: return "MCP Integrations"
        case mountsID: return "Mount External Folders"
        case memoryID: return "Memory System"
        case skillsID: return "Skills"
        case envVarsID: return "Environment Variables"
        case sharedFoldersID: return "Shared Folders"
        case promptShellID: return "Prompt: Shell"
        case promptWorkspaceID: return "Prompt: Workspace & Files"
        case promptMemoryID: return "Prompt: Memory"
        case promptCodingID: return "Prompt: Coding Workflow"
        case promptAppleID: return "Prompt: Apple Tools"
        case promptMinisCLIID: return "Prompt: Minis CLI"
        case promptEnvSecretsID: return "Prompt: Env Secrets"
        case promptStyleID: return "Prompt: Style"
        case promptScheduledID: return "Prompt: Scheduled Tasks"
        case promptExtensionsID: return "Prompt: Extensions"
        default: return id
        }
    }

    /// ID → short description shown in the manager.
    static func summary(id: String) -> String {
        switch id {
        // Feature plugins — say what disappears when switched off, because
        // that is the contract the user can actually observe.
        case todoID: return "Session-scoped todo list: create/update/list/clear tools plus the Todos panel and its menu entry."
        case subagentsID: return "Delegate work to bounded sub-agents (agent_delegate/agent_status) with run history and roles UI."
        case soulID: return "Assistant identity + personality (SOUL.md): the Settings → Soul editor, the name shown in the sidebar and chat headers, and persona injection into the system prompt."
        case mcpID: return "Model Context Protocol servers: Settings → MCP Integrations, the minis-mcp-cli bridge, and the per-session server list injected into the prompt."
        case mountsID: return "Bind host folders into the sandbox at /var/minis/mounts: Settings → Mount External Folders plus the mounts paragraph in the workspace guidance."
        case memoryID: return "Long-term memory: Settings → Memory browser, memory_write/memory_get tools, and GLOBAL.md + daily-log injection. The per-session /memory switch still applies on top."
        case skillsID: return "Reusable skill packages: Settings → Skills manager and the skill catalogue offered to the model."
        case envVarsID: return "User-managed environment variables: Settings → Environment Variables editor, and exporting those values into every shell command. Off hides the editor and stops the export; stored values (Keychain included) are kept. The agent still reads any env var from the shell itself."
        case sharedFoldersID: return "Shared Folders: the Settings → Shared Folders editor for host directories exposed to the sandbox. Off hides the editor but leaves existing shares mounted, so unmount one before switching this off."
        // Prompt modules
        case promptShellID: return "Shell discipline guidance (delay polling, 1000-char limit, bash fallback, background SIGPIPE, apk-vs-pip)."
        case promptWorkspaceID: return "Workspace layout, minis:// URL rules, and file create/edit conventions."
        case promptMemoryID: return "Memory system rules (daily log, GLOBAL.md, what not to remember)."
        case promptCodingID: return "Coding workflow guidance (read-before-write, verify after change, AGENTS.md)."
        case promptAppleID: return "Native Apple framework tools (apple-healthkit/homekit/alarm/vision/...)."
        case promptMinisCLIID: return "Minis CLI tools (minis-config, model-use, sessions-cli, browser-use, terminal)."
        case promptEnvSecretsID: return "Environment-variable secrecy rules and settings deep links."
        case promptStyleID: return "Tool-call style and tone guidance."
        case promptScheduledID: return "Guidance for scheduled/background tasks. That capability is Android-only, so this ships empty — editable if you port it."
        case promptExtensionsID: return "Extension tool guidance (extension_<id>_<name>)."
        default: return ""
        }
    }

    /// ID → capability kinds (mirrors .minisx manifests).
    static func kinds(id: String) -> [String] {
        switch id {
        // "prompt" is listed wherever the plugin exposes a promptText setting,
        // i.e. everywhere — see settings(id:).
        case todoID: return ["agent-tool", "ui-panel", "prompt"]
        case subagentsID: return ["agent-tool", "ui-panel", "prompt"]
        case soulID: return ["ui-panel", "prompt"]
        case mcpID: return ["agent-tool", "ui-panel", "prompt"]
        case mountsID: return ["ui-panel", "prompt"]
        case memoryID: return ["agent-tool", "ui-panel", "prompt"]
        case skillsID: return ["ui-panel", "prompt"]
        case envVarsID: return ["ui-panel", "prompt"]
        case sharedFoldersID: return ["ui-panel", "prompt"]
        case promptShellID, promptWorkspaceID, promptMemoryID, promptCodingID,
             promptAppleID, promptMinisCLIID, promptEnvSecretsID, promptStyleID,
             promptScheduledID, promptExtensionsID:
            return ["prompt"]
        default: return []
        }
    }

    /// ID → declared permissions.
    static func permissions(id: String) -> [String] {
        switch id {
        case todoID: return ["storage"]
        case subagentsID: return ["shell", "files"]
        case soulID, memoryID, skillsID: return ["files"]
        case mcpID: return ["network"]
        case mountsID, sharedFoldersID: return ["files"]
        case envVarsID: return ["secrets"]
        default: return []
        }
    }

    /// Every built-in plugin id. Feature plugins are listed first so the
    /// manager reads "features, then prompt modules".
    static var all: [String] {
        [todoID, subagentsID, soulID, mcpID, mountsID, memoryID, skillsID,
         envVarsID, sharedFoldersID,
         promptShellID, promptWorkspaceID, promptMemoryID, promptCodingID,
         promptAppleID, promptMinisCLIID, promptEnvSecretsID, promptStyleID,
         promptScheduledID, promptExtensionsID]
    }

    static func isBuiltin(_ id: String) -> Bool { all.contains(id) }

    /// Whether a plugin is a prompt module (only gates prompt text).
    static func isPromptModule(_ id: String) -> Bool {
        id.hasPrefix("builtin.prompt.")
    }

    /// Whether a plugin is a feature plugin (gates UI + agent surface too).
    static func isFeaturePlugin(_ id: String) -> Bool {
        isBuiltin(id) && !isPromptModule(id)
    }

    /// The feature plugin a prompt module describes. When that feature is
    /// switched off its guidance would tell the model to use tools and files
    /// that no longer exist, so the module's default text is suppressed too.
    ///
    /// Deliberately sparse. `builtin.prompt.env-secrets` is *not* mapped to
    /// `builtin.env-vars`, for example: hiding the env-var editor UI does not
    /// remove environment variables from the shell, so the secrecy rules stay
    /// correct and must keep being injected.
    static func describedFeature(ofModule id: String) -> String? {
        switch id {
        case promptMemoryID: return memoryID
        default: return nil
        }
    }

    /// Feature plugins whose `promptText` carries the guidance that lives in
    /// `baseSystemPrompt` verbatim (rather than an additive extra).
    static let ownedPromptTextIDs: Set<String> = [todoID, subagentsID]

    // MARK: - Settings schema

    /// Declared settings for each built-in plugin.
    ///
    /// * Every plugin exposes an editable `promptText` textarea — the text
    ///   the model sees. For prompt modules and todo/sub-agents the default
    ///   is the built-in section; empty removes it. For other feature plugins
    ///   the default is empty and any text is appended as extra guidance.
    /// * Feature plugins additionally expose `boolean` sub-switches that
    ///   control which parts of the feature the plugin owns, rendered as
    ///   in-place toggles in the plugin's settings sheet.
    static func settings(id: String) -> [ExtensionManifest.SettingDef] {
        var defs: [ExtensionManifest.SettingDef] = []

        let isOwned = isPromptModule(id) || ownedPromptTextIDs.contains(id)
        defs.append(ExtensionManifest.SettingDef(
            key: "promptText",
            label: "System-prompt guidance",
            type: "textarea",
            default: AnyCodable(defaultPromptText(id)),
            options: nil,
            placeholder: isOwned
                ? "Guidance text injected into the system prompt when this plugin is enabled."
                : "Optional extra guidance appended when this plugin is enabled. Leave empty to add nothing.",
            description: isOwned
                ? "Edit the text the model sees for this capability. Empty string removes this section from the prompt. Restore default reverts to the built-in wording."
                : "Free-form guidance appended to the prompt while this feature is enabled. Empty string (the default) adds nothing."
        ))

        defs.append(contentsOf: featureToggles(id: id))
        return defs
    }

    /// `boolean` sub-switches for feature plugins. These are the
    /// "buttons inside the plugin's own settings" that let a user keep a
    /// feature switched on but trim the parts of it they do not want.
    static func featureToggles(id: String) -> [ExtensionManifest.SettingDef] {
        func toggle(_ key: String, _ label: String, _ desc: String, on: Bool = true) -> ExtensionManifest.SettingDef {
            ExtensionManifest.SettingDef(
                key: key,
                label: label,
                type: "boolean",
                default: AnyCodable(on),
                options: nil,
                placeholder: nil,
                description: desc
            )
        }

        switch id {
        case soulID:
            return [
                toggle("injectPersonality", "Inject personality", "Put the SOUL.md personality body into the system prompt. Off keeps the identity line only."),
                toggle("injectStyle", "Inject style", "Put the SOUL.md style frontmatter into the prompt as a voice/tone constraint."),
                toggle("showEditHint", "Teach the model to edit SOUL.md", "Append the hint that name/style/body can be changed via minis-config or Settings → Soul."),
            ]
        case mcpID:
            return [
                toggle("injectServerList", "Inject server list", "Add the enabled MCP servers (and their tool names) to the system prompt. Off keeps the UI working but stops auto-advertising servers to the model."),
            ]
        case mountsID:
            return [
                toggle("mentionInPrompt", "Mention mounts in prompt", "Keep the mounts/<name>/ sentence in the workspace guidance. Off leaves mounted folders usable but unadvertised."),
            ]
        case memoryID:
            return [
                toggle("injectFiles", "Inject memory files", "Prepend GLOBAL.md and recent daily logs to the conversation context. Tools stay available either way."),
            ]
        case skillsID:
            return [
                toggle("listInPrompt", "Advertise skills", "List available skills to the model. Off keeps the Skills manager for manual use only."),
            ]
        case todoID, subagentsID, envVarsID, sharedFoldersID:
            return []
        default:
            return []
        }
    }

    /// Setting keys that gate agent-side behaviour, per plugin. Empty for
    /// plugins without toggles.
    static func toggleKeys(id: String) -> [String] {
        featureToggles(id: id).map(\.key)
    }

    /// The default guidance text for a built-in plugin's `promptText`
    /// setting. Prompt modules delegate to the registry's default body;
    /// todo/sub-agents return the section built into baseSystemPrompt;
    /// other feature plugins default to no extra guidance.
    static func defaultPromptText(_ id: String) -> String {
        // [T-builtin-plugin-audit A6] `builtin.prompt.scheduled` used to hand
        // the model a ~30-line spec for `schedule_create` / `schedule_list` /
        // `schedule_delete` / `watch_start` / `watch_stop` / `watch_list` and a
        // "Scheduled Tasks settings page". None of that exists on iOS:
        // makeAgentTools() registers eight tools (shell / three file tools /
        // two memory tools / browser_use, plus read_image), there is no
        // schedule handler in NativeOffloads/, and no such settings row.
        // Scheduling lives in src/android/.../scheduled/ only. So every model
        // turn paid ~30 lines of guidance for tools that cannot be called, and
        // any attempt to follow it was a guaranteed error. Shipped empty;
        // the extension_<id>_<name> guidance in builtin.prompt.extensions is
        // still accurate because those tools really are registered.
        //
        // The id stays in `all` on purpose: dropping it would leave a row in
        // extensions.db that isBuiltin() no longer recognises, which would
        // surface as an uninstallable ghost "extension". The textarea remains
        // live so a future iOS port can restore the wording without a code
        // change.
        if id == promptScheduledID { return "" }

        if isPromptModule(id) {
            return ExtensionRegistry.promptModuleBody(id) ?? ""
        }
        switch id {
        case todoID:
            return "Todo usage:\n"
                + "- For complex, multi-step work (3+ steps), create a todo list up front with todo_create, then update each item as you complete it (todo_update) and list what remains when starting or resuming (todo_list).\n"
                + "- Mark items in_progress while actively working on them, done when finished, blocked when stuck on a dependency.\n"
                + "- Keep the todo list concise — one line per step, no more than ~10 items. The user can view the list in the chat UI at any time.\n"
                + "- Clear completed items with todo_clear status=done to keep the list focused.\n\n"
        case subagentsID:
            return "Sub-agent delegation:\n"
                + "- Use agent_delegate for well-scoped subtasks that would bloat this conversation: research, isolated coding tasks, reviews, or planning. The sub-agent runs with its own context and returns a summary.\n"
                + "- Pick a role (researcher/coder/reviewer/planner) or pass a custom system_prompt. Use foreground mode to wait for the result; background mode to continue while it runs.\n"
                + "- Delegate only when it clearly helps — small tasks are faster done directly. Sub-agents cannot spawn sub-agents.\n\n"
        default:
            return ""
        }
    }
}
