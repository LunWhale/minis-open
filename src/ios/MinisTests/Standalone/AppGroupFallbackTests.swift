// [T-appgroup-no-force-unwrap]
//
// Guards the launch crash reported on a re-signed build (1.15 build 7):
//
//   EXC_BREAKPOINT / SIGTRAP
//   0 libswiftCore  _assertionFailure
//   1 AIChatViewModel.minisAppGroupRoot.getter
//   2 AIChatViewModel.minisMemoryPersistentDir.getter
//   3 SoulStore.fileURL.getter
//   4 SoulStore.load()
//   5 SoulStore.refreshCache()
//   6 MinisApp.init()
//
// `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil whenever the
// binary is re-signed under a different bundle id — the report showed
// `com.openminis.appp` — because `group.com.openminis.app` is then not entitled.
// A force unwrap on that path kills the process inside `App.init()`, before any
// UI, so no in-app log can ever be read.
//
// Standalone (`swift AppGroupFallbackTests.swift`).
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

print("▶️  1. the group container is never force-unwrapped")

/// Every Swift file in the app target.
func swiftSources() -> [(String, String)] {
    var out: [(String, String)] = []
    let base = root
    guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return out }
    for case let url as URL in en where url.pathExtension == "swift" {
        if url.path.contains("/MinisTests/") { continue }
        if let text = try? String(contentsOf: url, encoding: .utf8) { out.append((url.lastPathComponent, text)) }
    }
    return out
}

let sources = swiftSources()
check("scanned the app sources (\(sources.count) files)", sources.count > 50)

// The exact shape that crashed: a group-container lookup followed by `!`.
var offenders: [String] = []
for (name, text) in sources {
    for line in text.components(separatedBy: "\n") {
        if line.contains("forSecurityApplicationGroupIdentifier"), line.contains(")!") {
            offenders.append("\(name): \(line.trimmingCharacters(in: .whitespaces))")
        }
    }
}
check("no `containerURL(...)!` anywhere", offenders.isEmpty, offenders.joined(separator: " | "))

print("\n▶️  2. the two getters route through the fallback")

let budget = src("Agent/Chat/AIChatViewModel+RequestBudget.swift")
for getter in ["minisAppGroupRoot", "minisConfigRoot"] {
    let start = budget.range(of: "static var \(getter): URL {")
    if let start {
        let tail = String(budget[start.upperBound...].prefix(400))
        check("\(getter) uses SharedContainerStore.resolvedContainerRoot",
              tail.contains("SharedContainerStore.resolvedContainerRoot"))
    } else {
        check("\(getter) found", false)
    }
}

print("\n▶️  3. the fallback itself cannot return nil")

let store = src("Shared/SharedContainerStore.swift")
check("resolvedContainerRoot tries the real group first",
      store.contains("if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)"))
check("…and falls back to a real directory",
      store.contains("AppGroupFallback"))
check("…creating it so callers can write immediately",
      store.contains("createDirectory(at: fallback"))
check("…with a last-resort that is still non-optional",
      store.contains("FileManager.default.temporaryDirectory"))

print("\n▶️  4. the launch path that crashed is documented")

let soul = src("Agent/Session/SoulStore.swift")
check("SoulStore.fileURL resolves through the memory dir (the crash chain)",
      soul.contains("AIChatViewModel.minisMemoryPersistentDir.appendingPathComponent(\"SOUL.md\")"))

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)") }
exit(failures == 0 ? 0 : 1)
