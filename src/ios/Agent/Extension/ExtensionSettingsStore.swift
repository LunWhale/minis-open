import Foundation

// MARK: - Extension Settings Store

/// Per-extension settings persistence. Values are stored in UserDefaults under
/// a per-extension domain (`minis.extsettings.<id>`) so each plugin's settings
/// page (ExtensionSettingsView) and agent-side `minis.api.settings.get/set`
/// read and write the same backing store.
final class ExtensionSettingsStore {
    static let shared = ExtensionSettingsStore()

    private let defaults: UserDefaults

    private init() {
        // Suite key stable across app launches; plain UserDefaults is fine
        // since extensions are app-local.
        self.defaults = UserDefaults.standard
    }

    private func domain(for id: String) -> String { "minis.extsettings.\(id)" }

    /// All declared settings with current values (defaults when unset).
    func values(extensionID: String, settings: [ExtensionManifest.SettingDef]) -> [String: Any] {
        var out: [String: Any] = [:]
        let domain = domain(for: extensionID)
        for def in settings {
            if let stored = defaults.object(forKey: "\(domain).\(def.key)") {
                out[def.key] = stored
            } else if let d = def.default {
                out[def.key] = d.value
            } else {
                switch def.type {
                case "boolean": out[def.key] = false
                case "number": out[def.key] = 0.0
                default: out[def.key] = ""
                }
            }
        }
        return out
    }

    func get(extensionID: String, key: String, settings: [ExtensionManifest.SettingDef]) -> Any? {
        values(extensionID: extensionID, settings: settings)[key]
    }

    func set(extensionID: String, key: String, value: Any) {
        let domain = domain(for: extensionID)
        defaults.set(value, forKey: "\(domain).\(key)")
    }

    /// Drop every stored value for the extension's DECLARED setting keys.
    ///
    /// Removed by exact key rather than by prefix: extension ids may contain
    /// dots (`com.foo` and `com.foo.bar` are both valid), so a prefix sweep on
    /// `minis.extsettings.com.foo.` would also wipe the settings of
    /// `com.foo.bar`. Only declared keys are ever written (both the settings
    /// UI and `minis.api.settings.set` are gated on the manifest), so this
    /// covers the whole writable set.
    func reset(extensionID: String, declaredKeys: [String]) {
        let domain = domain(for: extensionID)
        for key in declaredKeys { defaults.removeObject(forKey: "\(domain).\(key)") }
    }

    /// Remove a single key override so the declared default takes effect
    /// again (used by the per-field "Restore default" action in settings).
    func reset(extensionID: String, key: String) {
        let domain = domain(for: extensionID)
        defaults.removeObject(forKey: "\(domain).\(key)")
    }

    /// Raw string value for a single key, or nil when no override is stored.
    /// Used by ExtensionRegistry.builtinPromptText to read the user-edited
    /// system-prompt guidance without going through the full values() path.
    func stringValue(extensionID: String, key: String) -> String? {
        let domain = domain(for: extensionID)
        return defaults.string(forKey: "\(domain).\(key)")
    }

    /// Boolean value for a single key, falling back to `default` when the
    /// user has not touched it. Agent-side gating (does this feature inject
    /// its prompt fragment, expose its tools, …) reads through this so a
    /// plugin's settings sheet is the only place its sub-switches live.
    /// The settings sheet writes Bools with `UserDefaults.set(Bool:)`, so the
    /// stored object is a real Bool and `object(forKey:) as? Bool` is exact.
    func boolValue(extensionID: String, key: String, default def: Bool = true) -> Bool {
        let domain = domain(for: extensionID)
        guard let stored = defaults.object(forKey: "\(domain).\(key)") as? Bool else { return def }
        return stored
    }
}
