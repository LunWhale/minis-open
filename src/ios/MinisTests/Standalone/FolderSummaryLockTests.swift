#!/usr/bin/env swift
// [T-folder-summary-lock] A group's "N chats · <newest member title>" line
// showed a Face ID locked member's title in plain text — on the home group card
// and in the Move-to-Group picker — while that member's own row is blurred.
// Source guards (the views are SwiftUI; the lock rule itself is
// SessionLockStore.isVisuallyLocked, shared with the member row).
//
// Run: swift FolderSummaryLockTests.swift
import Foundation

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
func check(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let cv = contentViewSource()
let xc = (try? String(contentsOf: root.appendingPathComponent("Localizable.xcstrings"), encoding: .utf8)) ?? ""
check("sources readable", !cv.isEmpty && !xc.isEmpty)

func count(_ s: String) -> Int { cv.components(separatedBy: s).count - 1 }
func body(of name: String) -> String {
    guard let a = cv.range(of: "struct \(name): View {"),
          let b = cv.range(of: "\n}\n", range: a.upperBound..<cv.endIndex) else { return "" }
    return String(cv[a.upperBound..<b.lowerBound])
}

print("▶️  summary line")
let line = body(of: "FolderSummaryLine")
check("FolderSummaryLine exists", !line.isEmpty)
check("uses the SAME lock rule as the member row (isVisuallyLocked)", line.contains("lockStore.isVisuallyLocked(sessionId)"))
check("observes the lock store, so unlock / relock updates it in place",
      line.contains("@ObservedObject private var lockStore = SessionLockStore.shared"))
check("locked: the title gets the member row's blur", line.contains(".modifier(LockedRowEffect(isLocked: true))"))
check("locked: prefix is the SAME localized line with an empty title",
      line.contains("AppLocalized(\"\\(count) chats · \\(noTitle)\")"))
check("unlocked: the original single localized line", line.contains("Text(\"\\(count) chats · \\(title)\")"))

print("\n▶️  both surfaces route through it")
check("no plain summary line left outside FolderSummaryLine",
      count("chats · \\(") == line.components(separatedBy: "chats · \\(").count - 1)
check("home group card passes the newest member's id",
      cv.contains("g.summarySessionId = m.first?.id")
      && cv.contains("FolderSummaryLine(count: group.totalCount, title: title,\n                                              sessionId: group.summarySessionId)"))
check("picker passes the member id only when the subtitle IS the member title (not the folder description)",
      cv.contains("subtitleSessionId: desc.isEmpty ? m.first?.id : nil)")
      && cv.contains("FolderSummaryLine(count: item.count, title: sub,\n                                                                  sessionId: item.subtitleSessionId)"))

print("\n▶️  localization: the locked prefix is valid in every locale")
// The locked form formats "%lld chats · %@" with an empty title and puts the
// blurred title after it, so every locale must END with the title placeholder.
func values(_ key: String) -> [String: String] {
    guard let json = try? JSONSerialization.jsonObject(with: Data(xc.utf8)) as? [String: Any],
          let strings = json["strings"] as? [String: Any],
          let entry = strings[key] as? [String: Any],
          let locs = entry["localizations"] as? [String: Any] else { return [:] }
    var out: [String: String] = [:]
    for (l, v) in locs {
        if let unit = (v as? [String: Any])?["stringUnit"] as? [String: Any], let s = unit["value"] as? String { out[l] = s }
    }
    return out
}
let joined = values("%lld chats · %@")
check("key translated in all \(joined.count) locales", joined.count >= 18)
let bad = joined.keys.sorted().filter { !(joined[$0] ?? "").hasSuffix(" · %@") }
check("every locale ends with \" · %@\"\(bad.isEmpty ? "" : " — not: \(bad)")", bad.isEmpty)

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
