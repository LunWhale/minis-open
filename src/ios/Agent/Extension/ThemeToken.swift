import Foundation
import SwiftUI

// MARK: - Theme Tokens

/// Declarative theme support for extensions. A `theme.json` maps semantic
/// tokens to hex colors; the app applies them to the chat UI. Kept minimal:
/// the extension system ships the parsing + a documented application point,
/// and the chat UI reads tokens via `ThemeTokens.active`.
///
/// Example theme.json:
/// ```json
/// {
///   "name": "Solarized Dark",
///   "scope": "chat",
///   "tokens": {
///     "background": "#002B36",
///     "text": "#93A1A1",
///     "accent": "#268BD2",
///     "userBubble": "#073642",
///     "assistantBubble": "#002B36",
///     "inputBackground": "#073642",
///     "border": "#073642"
///   }
/// }
/// ```
struct ThemeTokens {
    let name: String
    let scope: String
    var tokens: [String: String]

    /// Parse from raw JSON.
    static func parse(data: Data) -> ThemeTokens? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String,
              let tokens = obj["tokens"] as? [String: String] else {
            return nil
        }
        return ThemeTokens(
            name: name,
            scope: obj["scope"] as? String ?? "chat",
            tokens: tokens
        )
    }

    /// Resolve a token to a SwiftUI Color, falling back to a default.
    func color(_ key: String, fallback: Color) -> Color {
        guard let hex = tokens[key] else { return fallback }
        return Self.hexColor(hex) ?? fallback
    }

    /// Resolve a token to a UIColor, falling back to nil.
    func uiColor(_ key: String) -> UIColor? {
        guard let hex = tokens[key] else { return nil }
        return Self.hexUIColor(hex)
    }

    // MARK: - Hex parsing

    static func hexColor(_ hex: String) -> Color? {
        guard let ui = hexUIColor(hex) else { return nil }
        return Color(ui)
    }

    static func hexUIColor(_ hex: String) -> UIColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let val = UInt64(s, radix: 16) else { return nil }
        let r = CGFloat((val >> 16) & 0xFF) / 255
        let g = CGFloat((val >> 8) & 0xFF) / 255
        let b = CGFloat(val & 0xFF) / 255
        let a = s.count == 8 ? CGFloat((val >> 24) & 0xFF) / 255 : 1
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
}

extension Notification.Name {
    static let themeChanged = Notification.Name("minis.theme.changed")
}

// MARK: - Theme Manager (reactive)

/// Observable holder for the currently applied extension theme. Views that
/// depend on theme tokens observe this (via @ObservedObject) so applying a
/// theme during an install takes effect immediately, without a navigation
/// or view-body re-evaluation from another source.
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    /// Last applied extension theme (or nil for the default look).
    @Published var active: ThemeTokens? {
        didSet {
            NotificationCenter.default.post(name: .themeChanged, object: nil)
        }
    }

    private init() {}

    /// Apply a theme (or clear with nil).
    func apply(_ theme: ThemeTokens?) {
        active = theme
    }
}

extension ThemeTokens {
    /// Convenience: current active theme via the reactive manager.
    static var active: ThemeTokens? { ThemeManager.shared.active }
}
