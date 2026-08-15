import Foundation

// MARK: - Extension Manifest

/// Parsed `manifest.json` from a `.minisx` extension bundle.
///
/// An extension is a zip archive (`*.minisx`) with this layout:
/// ```
/// my-extension.minisx/
/// ├── manifest.json            (required)
/// ├── agent/                   agent-side extensions
/// │   ├── tools/xxx.js
/// │   ├── commands/xxx.js
/// │   └── hooks/xxx.js
/// ├── ui/                      UI-side extensions
/// │   ├── widget.html          (WebView component)
/// │   └── theme.json           (theme tokens)
/// └── assets/
/// ```
struct ExtensionManifest: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var version: String
    var description: String?
    var author: String?
    /// Extension capabilities. Values: "agent-tool", "command", "event-hook",
    /// "ui-widget", "theme".
    var kinds: [String]
    /// Declared permissions: "shell", "network", "files", "device.health",
    /// "device.calendar", "ui", etc. Enforced at first use via the standard
    /// permission dialog.
    var permissions: [String]
    /// Agent-side tool definitions.
    var tools: [ToolDef]?
    /// Slash commands.
    var commands: [CommandDef]?
    /// Event hooks.
    var hooks: [HookDef]?
    /// UI widgets.
    var ui: [UIDef]?
    /// Theme file.
    var theme: ThemeDef?
    /// Per-extension settings the author declares; rendered as a form on the
    /// extension's Settings page (see ExtensionSettingsView). Agents read
    /// them via `minis.api.settings.get`.
    var settings: [SettingDef]?

    struct SettingDef: Codable, Equatable, Sendable {
        var key: String
        var label: String
        /// "text", "boolean", "number", "select" (options required).
        var type: String
        var `default`: AnyCodable?
        /// Options for "select".
        var options: [String]?
        var placeholder: String?
        var description: String?
    }

    struct ToolDef: Codable, Equatable, Sendable {
        /// Script file relative to the extension root, e.g. "agent/tools/my_tool.js"
        /// or "agent/tools/my_tool.lua".
        var file: String
        var name: String
        var description: String
        /// Runtime language: "js" (JavaScriptCore, default) or "lua" (vendored 5.4).
        var language: String?
        /// JSON Schema for parameters (typebox-like subset).
        var schema: [String: AnyCodable]?
    }

    struct CommandDef: Codable, Equatable, Sendable {
        var file: String
        var name: String
        var description: String?
        /// Runtime language: "js" (default) or "lua".
        var language: String?
    }

    struct HookDef: Codable, Equatable, Sendable {
        var file: String
        /// Events to subscribe to: "tool_call", "agent_start", "agent_end", ...
        var events: [String]
        /// Runtime language: "js" (default) or "lua".
        var language: String?
    }

    struct UIDef: Codable, Equatable, Sendable {
        var type: String  // "widget"
        var file: String
        /// Placement: "chat-panel", "settings", "home", "message".
        var placement: String?
    }

    struct ThemeDef: Codable, Equatable, Sendable {
        var file: String
        var scope: String?  // "chat" (default), "app"
    }

    // MARK: - Parsing

    /// Parse a manifest from raw JSON data.
    static func parse(data: Data) throws -> ExtensionManifest {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(ExtensionManifest.self, from: data)
        guard !manifest.id.isEmpty, !manifest.name.isEmpty, !manifest.version.isEmpty else {
            throw ExtensionError.invalidManifest("id, name, version are required")
        }
        // id must be a safe identifier (used as a directory name + tool prefix).
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard manifest.id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ExtensionError.invalidManifest("id contains invalid characters")
        }
        return manifest
    }

    /// Validate that declared files exist in the unpacked bundle.
    func validateFileReferences(bundleRoot: URL) throws {
        let fm = FileManager.default
        func check(_ file: String?) throws {
            guard let file, !file.isEmpty else { return }
            let url = bundleRoot.appendingPathComponent(file)
            guard fm.fileExists(atPath: url.path) else {
                throw ExtensionError.invalidManifest("referenced file missing: \(file)")
            }
        }
        for t in tools ?? [] { try check(t.file) }
        for c in commands ?? [] { try check(c.file) }
        for h in hooks ?? [] { try check(h.file) }
        for u in ui ?? [] { try check(u.file) }
        if let theme { try check(theme.file) }
    }
}

/// Minimal type-erased Codable for arbitrary JSON schema values.
struct AnyCodable: Codable, Equatable, Sendable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = NSNull() }
        else if let b = try? c.decode(Bool.self) { self.value = b }
        else if let i = try? c.decode(Int.self) { self.value = i }
        else if let d = try? c.decode(Double.self) { self.value = d }
        else if let s = try? c.decode(String.self) { self.value = s }
        else if let a = try? c.decode([AnyCodable].self) { self.value = a.map(\.value) }
        else if let o = try? c.decode([String: AnyCodable].self) { self.value = o.mapValues(\.value) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported value") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let arr as [Any]: try c.encode(arr.map(AnyCodable.init))
        case let dict as [String: Any]: try c.encode(dict.mapValues(AnyCodable.init))
        default: try c.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        if let l = lhs.value as? String, let r = rhs.value as? String { return l == r }
        if let l = lhs.value as? Int, let r = rhs.value as? Int { return l == r }
        if let l = lhs.value as? Double, let r = rhs.value as? Double { return l == r }
        if let l = lhs.value as? Bool, let r = rhs.value as? Bool { return l == r }
        return false
    }
}

// MARK: - Errors

enum ExtensionError: LocalizedError {
    case invalidArchive
    case invalidManifest(String)
    case missingManifest
    case duplicateID(String)
    case notFound(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "Invalid .minisx archive"
        case .invalidManifest(let m): return "Invalid manifest: \(m)"
        case .missingManifest: return "manifest.json not found"
        case .duplicateID(let id): return "An extension with id '\(id)' is already installed"
        case .notFound(let id): return "Extension '\(id)' not found"
        case .runtime(let m): return "Extension runtime error: \(m)"
        }
    }
}
