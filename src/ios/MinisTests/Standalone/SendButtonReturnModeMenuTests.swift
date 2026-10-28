// [T-send-longpress-return-mode] Long-pressing the chat Send button opens a
// single-choice menu for the Return key (send / new line) — also from the
// grey, not-yet-sendable button — and the switch takes effect in the open
// composer at once.
//
// Standalone: `cd src/ios/MinisTests/Standalone && swift SendButtonReturnModeMenuTests.swift`

import Foundation

/// The chat page's sources, read as one text: AIChatView.swift (state and
/// `body`) first, then every other file under Views/Chat/AIChatView/ - the
/// old single AIChatView.swift was split into them.
func chatViewSource() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Views/Chat/AIChatView")
    let main = dir.appendingPathComponent("AIChatView.swift")
    let rest = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "AIChatView.swift" }
        .sorted { $0.path < $1.path }
    return ([main] + rest).compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

/// The home screen sources - Views/ContentView/ plus Views/Settings/SettingsSheet.swift
/// and AppearanceSettingsView.swift, formerly the single file ContentView.swift -
/// read as one text with the files in path order.
func contentViewSource() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Views/ContentView")
    var files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
    files += ["Views/Settings/SettingsSheet.swift", "Views/Settings/AppearanceSettingsView.swift"]
        .map { ios.appendingPathComponent($0) }
    return files.sorted { $0.path < $1.path }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

var failures = 0
func check(_ label: String, _ actual: Bool, _ expected: Bool = true) {
    if actual == expected { print("  ✅ \(label)") }
    else { print("  ❌ \(label) — expected \(expected), got \(actual)"); failures += 1 }
}
let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let chat = chatViewSource()
let input = (try? String(contentsOf: root.appendingPathComponent("Views/Chat/ChatInputBar.swift"), encoding: .utf8)) ?? ""
let settings = contentViewSource()
check("sources found", !chat.isEmpty && !input.isEmpty && !settings.isEmpty)

func slice(_ t: String, _ a: String, _ b: String) -> String {
    guard let r = t.range(of: a), let e = t.range(of: b, range: r.upperBound..<t.endIndex) else { return "" }
    return String(t[r.lowerBound..<e.upperBound])
}
let button = slice(chat, "struct ChatSendButton: View {", "\n}\n")
check("ChatSendButton located", !button.isEmpty)

print("\n▶️  one setting, shared with Settings and the composer")
check("menu uses the Settings key", button.contains("@AppStorage(\"returnKeyBehavior\") private var returnKeyBehavior: Int = 0"))
check("Settings uses the same key", settings.contains("@AppStorage(\"returnKeyBehavior\") private var returnKeyBehavior: Int = 0"))
check("composer Return handling reads the same key", input.contains("UserDefaults.standard.integer(forKey: \"returnKeyBehavior\")"))
check("single choice: send = 1, new line = 0",
      button.contains("systemImage: \"paperplane\").tag(1)") && button.contains("systemImage: \"return\").tag(0)"))

print("\n▶️  gesture split")
check("tap = primary action, long-press = menu (iOS 26 Menu; iOS 16-25 Button + contextMenu)",
      button.contains("} primaryAction: { [primaryActionBox] in\n            primaryActionBox.action()\n        }")
      && button.contains("Button(action: primaryAction) { label() }"))
check("send and queue buttons both use it",
      button.contains("returnModeMenu(primaryAction: onEnqueue)") && button.contains("returnModeMenu(primaryAction: { if canSend { onSend() } })"))
let codeLines = button.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
check("grey button is NOT .disabled (that would kill the long-press too)",
      !codeLines.contains { $0.contains(".disabled(!canSend)") })
check("tap on the grey button does nothing", button.contains("{ if canSend { onSend() } }"))
check("⌘Return still sends via a hidden button",
      button.contains("Button(\"\", action: primaryAction)\n                .keyboardShortcut(.return, modifiers: .command)"))
check("Stop button keeps its plain tap (no menu)", slice(button, "} else if isBusy && !canSend {", "} else {").contains("returnModeMenu") == false)
check("VoiceOver can switch without the long-press", button.contains(".accessibilityAction(named:"))

print("\n▶️  takes effect in the open composer")
check("AIChatView observes the setting", chat.contains("    @AppStorage(\"returnKeyBehavior\") private var returnKeyBehavior: Int = 0\n") )
check("…and reads it where the composer is built",
      chat.contains("_ = returnKeyBehavior  // [T-send-longpress-return-mode] dependency, see declaration\n        let field = PastableTextView("))
check("composer reloads the keyboard when the Return type changes",
      input.contains("tv.returnKeyType = desiredReturnKey\n            if tv.isFirstResponder { tv.reloadInputViews() }"))

/// Port of setReturnMode: only a real change writes and ticks the haptic.
var writes = 0
func setMode(_ current: inout Int, _ mode: Int) { guard mode != current else { return }; current = mode; writes += 1 }
var mode = 0
setMode(&mode, 1); setMode(&mode, 1); setMode(&mode, 0)
check("re-selecting the current mode is a no-op", writes == 2 && mode == 0)

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)"); exit(1) }
