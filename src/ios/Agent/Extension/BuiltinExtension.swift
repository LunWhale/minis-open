import Foundation

// MARK: - Built-in Extension Support

/// Built-in ("default") extensions are first-class plugins shipped with the
/// app. They appear in the extension manager like installed .minisx bundles,
/// can be enabled/disabled, and their agent tools are gated on that switch.
/// They have no zip bundle — their capabilities are native code.
enum BuiltinExtension {
    static let todoID = "builtin.todo"
    static let subagentsID = "builtin.subagents"

    /// ID → display name.
    static func displayName(id: String) -> String {
        switch id {
        case todoID: return "Todo System"
        case subagentsID: return "Sub-agent Delegation"
        default: return id
        }
    }

    /// ID → short description shown in the manager.
    static func summary(id: String) -> String {
        switch id {
        case todoID: return "Session-scoped todo list: create/update/list/clear tools plus the Todos panel."
        case subagentsID: return "Delegate work to bounded sub-agents (agent_delegate/agent_status) with run history."
        default: return ""
        }
    }

    /// ID → capability kinds (mirrors .minisx manifests).
    static func kinds(id: String) -> [String] {
        switch id {
        case todoID: return ["agent-tool", "ui-panel"]
        case subagentsID: return ["agent-tool", "ui-panel"]
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

    static var all: [String] { [todoID, subagentsID] }

    static func isBuiltin(_ id: String) -> Bool { all.contains(id) }
}
