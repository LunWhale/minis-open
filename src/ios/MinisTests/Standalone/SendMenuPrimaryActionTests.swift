// [T-send-menu-stale-primary-action] On iOS 16-18 tapping Send did nothing.
//
// The send button became `Menu(primaryAction:)` for the long-press Return-mode
// menu. On iOS 16-18 the Menu keeps the primaryAction closure from its FIRST
// render. That render has an empty composer, so `{ if canSend { onSend() } }`
// captured canSend == false for good: the button turned black once text was
// typed, but every tap was dropped. (iOS 26 refreshes the closure, which is why
// it only showed on older systems.) A live action box alone did NOT fix it on
// iOS 16.1: the Menu's tap never reached the action at all. So below iOS 26 the
// control is a plain Button (tap) + .contextMenu (long-press); iOS 26 keeps the
// Liquid Glass Menu, calling through a class box every render refreshes.
//
// Standalone: `cd src/ios/MinisTests/Standalone && swift SendMenuPrimaryActionTests.swift`

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

var failures = 0
func check(_ label: String, _ actual: Bool, _ expected: Bool = true) {
    if actual == expected { print("  ✅ \(label)") }
    else { print("  ❌ \(label) — expected \(expected), got \(actual)"); failures += 1 }
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let chat = chatViewSource()
check("source found", !chat.isEmpty)

print("\n▶️  1. model: a Menu that keeps its first closure")
final class Box { var action: () -> Void = {} }
final class StaleMenu {
    private var stored: (() -> Void)?
    func render(primaryAction: @escaping () -> Void) { if stored == nil { stored = primaryAction } }
    func tap() { stored?() }
}
do {
    var sent = 0
    let old = StaleMenu()
    for canSend in [false, true] { old.render(primaryAction: { if canSend { sent += 1 } }) }
    old.tap()
    check("before: closure from the empty-composer render drops the tap", sent == 0)

    let box = Box()
    let fixed = StaleMenu()
    for canSend in [false, true] {
        box.action = { if canSend { sent += 1 } }
        fixed.render(primaryAction: { [box] in box.action() })
    }
    fixed.tap()
    check("after: the box forwards to the latest closure", sent == 1)
}

print("\n▶️  2. source invariants")
check("box is @State in ChatSendButton", chat.contains("@State private var primaryActionBox = SendPrimaryActionBox()"))
check("every render stores the fresh action", chat.contains("primaryActionBox.action = primaryAction\n        return Menu {"))
check("Menu calls through the box, not the captured closure",
      chat.contains("} primaryAction: { [primaryActionBox] in\n            primaryActionBox.action()\n        }"))
check("box type is a class", chat.contains("final class SendPrimaryActionBox {"))
check("Menu only on iOS 26+", chat.contains("if #available(iOS 26, *) {\n            glassReturnModeMenu(primaryAction: primaryAction, label: label)"))
check("iOS 16-25: plain Button taps, context menu for the long-press",
      chat.contains("Button(action: primaryAction) { label() }\n                .keyboardShortcut(.return, modifiers: .command)\n                .contextMenu { returnModePicker }"))

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)"); exit(1) }
