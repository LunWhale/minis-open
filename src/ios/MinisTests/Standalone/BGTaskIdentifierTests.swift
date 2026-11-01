// [T-bka-continued-fixed-id]
//
// Guards the one launch-time invariant that cannot be caught at runtime.
//
// `BGTaskSchedulerPermittedIdentifiers` in Info.plist is matched LITERALLY: the
// string the app registers must appear there verbatim. A `*` is just an asterisk.
// When it does not match, `BGTaskScheduler.register(forTaskWithIdentifier:)` raises
// an NSInternalInconsistencyException — an Objective-C exception Swift cannot
// catch — so the app dies instead of logging a failure.
//
// This shipped once: the plist listed `com.openminis.app.continued.*` while the
// code built `com.openminis.app.continued.` + a random UUID per request, so the
// iOS 26 background feature could never register, and the failure was a crash
// rather than the `register` returning false that the caller checked for.
//
// Standalone (`swift BGTaskIdentifierTests.swift`).
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

print("▶️  1. every registered identifier is permitted, literally")

// Parse the plist without needing the app bundle.
let plist = src("Info.plist")
let plistIDs: [String] = {
    guard let a = plist.range(of: "<key>BGTaskSchedulerPermittedIdentifiers</key>"),
          let b = plist.range(of: "</array>", range: a.upperBound..<plist.endIndex) else { return [] }
    let block = String(plist[a.upperBound..<b.lowerBound])
    var out: [String] = []
    var rest = Substring(block)
    while let s = rest.range(of: "<string>"), let e = rest.range(of: "</string>", range: s.upperBound..<rest.endIndex) {
        out.append(String(rest[s.upperBound..<e.lowerBound]))
        rest = rest[e.upperBound...]
    }
    return out
}()

check("the plist declares at least one identifier", !plistIDs.isEmpty, "found \(plistIDs.count)")
check("no wildcard in the list (Apple matches literally)", !plistIDs.contains { $0.contains("*") },
      "found \(plistIDs.filter { $0.contains("*") })")

let bka = src("Agent/Background/BackgroundKeepAliveManager.swift")
// The identifier the code actually registers.
let continuedID: String? = {
    guard let r = bka.range(of: "static let continuedId = \""),
          let e = bka.range(of: "\"", range: r.upperBound..<bka.endIndex) else { return nil }
    return String(bka[r.upperBound..<e.lowerBound])
}()
check("the code declares one fixed continued-processing id", continuedID != nil)
if let id = continuedID {
    check("…and that exact string is in the plist", plistIDs.contains(id), "plist=\(plistIDs)")
}

print("\n▶️  2. the per-request UUID is gone")

check("no random identifier is generated any more",
      !bka.contains("continuedIdPrefix + UUID()"))
check("registration is guarded by continuedRegistered (register twice kills the app)",
      bka.contains("if !continuedRegistered {"))
check("…and the flag is stored on the class, not an extension",
      bka.contains("private var continuedRegistered = false"))

print("\n▶️  3. a wrong plist cannot crash the app")

check("the code checks the plist before registering (uncatchable ObjC exception otherwise)",
      bka.contains("BGTaskSchedulerPermittedIdentifiers")
        && bka.contains("guard permitted.contains(id) else {"))
check("a mismatch logs and gives up instead of throwing",
      bka.contains("is not in BGTaskSchedulerPermittedIdentifiers"))

print("\n▶️  4. the live-activity identifier is covered too")

let registerCalls: [String] = {
    var out: [String] = []
    var rest = Substring(bka)
    let needle = "register(forTaskWithIdentifier: "
    while let r = rest.range(of: needle) {
        let after = rest[r.upperBound...]
        let arg = after.prefix { $0 != "," }
        out.append(String(arg))
        rest = after
    }
    return out
}()
check("every register call uses a constant (not an interpolated value)",
      registerCalls.allSatisfy { !$0.contains("\\(") },
      "calls=\(registerCalls)")

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)") }
exit(failures == 0 ? 0 : 1)
