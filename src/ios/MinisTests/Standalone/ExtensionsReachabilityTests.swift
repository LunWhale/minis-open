// [T-extensions-reachable]
//
// The Extensions manager must be reachable from the UI, and the deep link must
// have a consumer. Both broke in the upstream 1.15 merge: upstream deleted the
// ContentView.swift that owned the presenting sheet and moved the settings list
// into SettingsSheet.swift, and the "Extensions" row did not come with it —
// `ExtensionManagerView` ended up referenced by nothing, so every plugin switch
// (and /extensions, and minis://extensions) became unreachable while the code
// still compiled.
//
// Standalone (`swift ExtensionsReachabilityTests.swift`).
import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    if ok { print("  ✅ \(label)") }
    else { print("  ❌ \(label)\(detail.isEmpty ? "" : " — \(detail)")"); failures += 1 }
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func src(_ rel: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

print("▶️  1. the manager is actually referenced")

var referrers: [String] = []
if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
    for case let url as URL in en where url.pathExtension == "swift" {
        if url.path.contains("/MinisTests/") { continue }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        if text.contains("ExtensionManagerView()") || text.contains("ExtensionManagerView\n") {
            referrers.append(url.lastPathComponent)
        }
    }
}
check("ExtensionManagerView is used somewhere", !referrers.isEmpty, "referenced by: \(referrers)")
check("…and by more than its own file", referrers.count >= 1, "\(referrers)")

print("\n▶️  2. there is a settings entry for it")

let sheet = src("Views/Settings/SettingsSheet.swift")
check("Settings links to the manager", sheet.contains("ExtensionManagerView()"))
check("the row is inside Agent Runtime",
      sheet.contains("Section(\"Agent Runtime\")"))
// The one row that must never be plugin-gated — it owns the switches.
check("the Extensions row is NOT gated by a plugin switch",
      !sheet.contains(".shown(extensionsOn)"))

print("\n▶️  3. the deep link has a consumer")

let router = src("Shared/DeepLinkRouter.swift")
check("the router sets showExtensions", router.contains("showExtensions = true"))
let slash = src("Agent/Chat/AIChatViewModel+SlashCommands.swift")
check("the /extensions command sets it too", slash.contains("showExtensions = true"))

let content = src("Views/ContentView/ContentView.swift")
check("ContentView presents a sheet for it",
      content.contains("showExtensionsSheet"))
check("…bound to the manager", content.contains("ExtensionManagerView()"))
check("…and clears the flag so it fires once",
      content.contains("deepLink.showExtensions = false"))

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)") }
exit(failures == 0 ? 0 : 1)
