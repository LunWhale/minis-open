import Foundation

// MARK: - Built-in Extension Support

/// Built-in ("default") extensions are first-class plugins shipped with the
/// app. They appear in the extension manager like installed .minisx bundles,
/// can be enabled/disabled, and their agent tools are gated on that switch.
/// They have no zip bundle — their capabilities are native code.
///
/// Two kinds of built-in plugin exist:
///
/// 1. **Feature plugins** (`todoID`, `subagentsID`) — real native features
///    (tools + UI panels) that are fully gated: disabling removes the agent
///    tools, blocks dispatch, hides menu entries and drops the system-prompt
///    guidance.
///
/// 2. **Prompt modules** (`prompt.*ID`) — sections of the system prompt that
///    teach the model how to use an existing capability (shell discipline,
///    workspace layout, memory rules, coding workflow, apple-* tools, minis
///    CLI tools, env secrets, style, scheduled tasks, extension tools).
///    Disabling a prompt module ONLY removes that guidance text from the
///    prompt (saving tokens and keeping the core clean). The underlying
///    functionality is native and always available — the model simply is not
///    instructed about it, so "closing a plugin never breaks a feature".
enum BuiltinExtension {
    static let todoID = "builtin.todo"
    static let subagentsID = "builtin.subagents"

    // Prompt-module plugins. These gate sections of baseSystemPrompt only;
    // the features they describe stay functional regardless of the switch.
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
        case todoID: return "Session-scoped todo list: create/update/list/clear tools plus the Todos panel."
        case subagentsID: return "Delegate work to bounded sub-agents (agent_delegate/agent_status) with run history."
        case promptShellID: return "Shell discipline guidance (delay polling, 1000-char limit, bash fallback, background SIGPIPE, apk-vs-pip)."
        case promptWorkspaceID: return "Workspace layout, minis:// URL rules, and file create/edit conventions."
        case promptMemoryID: return "Memory system rules (daily log, GLOBAL.md, what not to remember)."
        case promptCodingID: return "Coding workflow guidance (read-before-write, verify after change, AGENTS.md)."
        case promptAppleID: return "Native Apple framework tools (apple-healthkit/homekit/alarm/vision/...)."
        case promptMinisCLIID: return "Minis CLI tools (minis-config, model-use, sessions-cli, browser-use, terminal)."
        case promptEnvSecretsID: return "Environment-variable secrecy rules and settings deep links."
        case promptStyleID: return "Tool-call style and tone guidance."
        case promptScheduledID: return "Scheduled-task warning (app suspension, Apple Shortcuts)."
        case promptExtensionsID: return "Extension tool guidance (extension_<id>_<name>)."
        default: return ""
        }
    }

    /// ID → capability kinds (mirrors .minisx manifests).
    static func kinds(id: String) -> [String] {
        switch id {
        case todoID: return ["agent-tool", "ui-panel"]
        case subagentsID: return ["agent-tool", "ui-panel"]
        case promptShellID: return ["prompt"]
        case promptWorkspaceID: return ["prompt"]
        case promptMemoryID: return ["prompt"]
        case promptCodingID: return ["prompt"]
        case promptAppleID: return ["prompt"]
        case promptMinisCLIID: return ["prompt"]
        case promptEnvSecretsID: return ["prompt"]
        case promptStyleID: return ["prompt"]
        case promptScheduledID: return ["prompt"]
        case promptExtensionsID: return ["prompt"]
        default: return []
        }
    }

    /// ID → declared permissions.
    static func permissions(id: String) -> [String] {
        switch id {
        case todoID: return ["storage"]
        case subagentsID: return ["shell", "files"]
        default: return []
        }
    }

    static var all: [String] {
        [todoID, subagentsID,
         promptShellID, promptWorkspaceID, promptMemoryID, promptCodingID,
         promptAppleID, promptMinisCLIID, promptEnvSecretsID, promptStyleID,
         promptScheduledID, promptExtensionsID]
    }

    static func isBuiltin(_ id: String) -> Bool { all.contains(id) }

    /// Whether a plugin is a prompt module (only gates prompt text).
    static func isPromptModule(_ id: String) -> Bool {
        id.hasPrefix("builtin.prompt.")
    }

    /// Declared settings schema for each built-in plugin. Prompt modules
    /// (and todo/sub-agents, whose guidance lives in baseSystemPrompt) expose
    /// a `promptText` textarea so the user can freely edit the injected
    /// system-prompt guidance. The default value is the built-in text (via
    /// ExtensionRegistry.promptModuleBody / the hardcoded todo+subagents
    /// sections); editing stores an override in ExtensionSettingsStore.
    static func settings(id: String) -> [ExtensionManifest.SettingDef] {
        let promptTextDef = ExtensionManifest.SettingDef(
            key: "promptText",
            label: "System-prompt guidance",
            type: "textarea",
            default: AnyCodable(defaultPromptText(id)),
            options: nil,
            placeholder: "Guidance text injected into the system prompt when this plugin is enabled.",
            description: "Edit the text the model sees for this capability. Empty string removes this section from the prompt. Restore default reverts to the built-in wording."
        )
        switch id {
        case todoID, subagentsID,
             promptShellID, promptWorkspaceID, promptMemoryID, promptCodingID,
             promptAppleID, promptMinisCLIID, promptEnvSecretsID, promptStyleID,
             promptScheduledID, promptExtensionsID:
            return [promptTextDef]
        default:
            return []
        }
    }

    /// The default guidance text for a built-in plugin's `promptText`
    /// setting. For prompt modules this delegates to the registry's default
    /// body; for todo/sub-agents it returns the section built into
    /// baseSystemPrompt.
    static func defaultPromptText(_ id: String) -> String {
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
