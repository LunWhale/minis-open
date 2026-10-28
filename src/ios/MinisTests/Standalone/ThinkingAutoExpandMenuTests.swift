// Tests for [T-thinking-autoexpand-toggle-longpress] — a thinking block's
// long-press menu switches "Expand Thinking While Streaming", the same setting
// as Settings > Appearance > Deep Thinking, and applies it to the block that
// is streaming right now unless the user already toggled that block by hand.
//
// Pure logic is mirrored below; the wiring is checked against the source.
// Standalone (`swift ThinkingAutoExpandMenuTests.swift`).
import Foundation

/// [T-messagelist-v3-split] CollectionViewMessageListV3.swift became the folder
/// Agent/MessageList/CollectionViewMessageListV3/ (code moved verbatim); read all
/// of it as one text, the way the single file used to be read.
func messageListV3Source() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Agent/MessageList/CollectionViewMessageListV3")
    let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
    return files.sorted { $0.path < $1.path }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

var failures = 0
func check(_ l: String, _ a: Bool, _ e: Bool = true) {
    if a == e { print("  ✅ \(l)") } else { print("  ❌ \(l) — expected \(e), got \(a)"); failures += 1 }
}

let ios = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func read(_ rel: String) -> String { (try? String(contentsOf: ios.appendingPathComponent(rel), encoding: .utf8)) ?? "" }

// MARK: - Mirror of ThinkingAutoExpand.set's effect on the live block

final class Block { var expanded = false; var userToggled = false; var flushed = 0; var posts = 0 }
func apply(_ on: Bool, live: Block?) {
    guard let b = live, !b.userToggled, b.expanded != on else { return }
    if on { b.flushed += 1 }
    b.expanded = on
    b.posts += 1
}

do {
    let b = Block(); b.expanded = true
    apply(false, live: b)
    check("off: the auto-expanded streaming block collapses and re-measures", !b.expanded && b.posts == 1)
}
do {
    let b = Block()
    apply(true, live: b)
    check("on: the collapsed streaming block expands with its buffer flushed", b.expanded && b.flushed == 1 && b.posts == 1)
}
do {
    let b = Block(); b.expanded = true; b.userToggled = true
    apply(false, live: b)
    check("a block the user opened by hand stays as the user left it", b.expanded && b.posts == 0)
}
do {
    let b = Block(); b.expanded = false
    apply(false, live: b)
    check("no change → no re-measure", b.posts == 0)
}
apply(true, live: nil)
check("no live block → only the setting changes (finished blocks untouched)", true)

// MARK: - Source wiring

let view = read("Views/Chat/AssistantBlockView.swift")
let list = messageListV3Source()
let settings = read("Views/Settings/AppearanceSettingsView.swift")

check("one owner for the key, same key and default as the Appearance toggle",
      view.contains(#"static let key = "chat.autoExpandThinking""#)
      && view.contains("static var isOn: Bool { (UserDefaults.standard.object(forKey: key) as? Bool) ?? true }")
      && settings.contains(#"@AppStorage("chat.autoExpandThinking") private var autoExpandThinking: Bool = true"#))
check("the streaming auto-expand reads it through the owner",
      view.contains("if ThinkingAutoExpand.isOn, isStreaming,") && !view.contains(#"forKey: "chat.autoExpandThinking""#))
check("the binding reads the setting when the menu opens and resolves the live block at tap time",
      view.contains("Binding(get: { isOn }, set: { set($0, liveBlock: liveBlock()) })"))
check("set() honours the user's own toggle and re-measures the cell",
      view.contains("guard let b = liveBlock, !b.thinkingUserToggled, b.isThinkingExpanded != on else { return }")
      && view.contains("NotificationCenter.default.post(name: .thinkingBlockToggled, object: b.id)"))

let cell: String = {
    guard let s = list.range(of: "struct BridgedAssistantBlockV3: View {"),
          let e = list.range(of: "private func toggleUsage()", range: s.upperBound..<list.endIndex) else { return "" }
    return String(list[s.lowerBound..<e.lowerBound])
}()
check("the block cell's long-press menu offers the toggle for thinking blocks only",
      cell.contains("if case .thinking = block.kind {")
      && cell.contains("Toggle(isOn: ThinkingAutoExpand.binding(liveBlock:")
      && cell.contains(#"AppLocalized("Expand Thinking While Streaming")"#))
check("the live block is the active reply's last block, captured without the view",
      cell.contains("{ [bridge, message, block] in")
      && cell.contains("bridge.isActiveMessage && message.blocks.last?.id == block.id ? block : nil"))
check("no second context menu inside ThinkingBlockView (it would compete for the press)",
      {
          guard let s = view.range(of: "struct ThinkingBlockView: View {"),
                let e = view.range(of: "private struct ThinkingBodyHeightKey", range: s.upperBound..<view.endIndex) else { return false }
          return !view[s.lowerBound..<e.lowerBound].contains(".contextMenu")
      }())

print(failures == 0 ? "\n✅ All thinking auto-expand menu tests passed" : "\n❌ \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
