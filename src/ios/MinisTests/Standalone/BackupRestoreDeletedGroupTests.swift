// [T-backup-restore-tombstone] "Delete a model group, restore the backup: the
// group does not come back" (Telegram report 2026-09-24, re-reported 09-25).
//
// Root cause: ProviderConfigStore.removeGroup records the id in
// `deletedModelGroups`, and CloudSyncEngine.mergeProviderConfigBody, which the
// restore shares with iCloud sync, dropped every incoming group whose id was in
// the local+package tombstone union. The package held the group intact; the
// merge skipped it and the restore still reported success.
//
//   A. The shipping rule (ProviderConfigTombstone.survivingRestore), compiled
//      from ProviderConfigStore.swift itself, against the reported scenario
//      and its edges.
//   B. Wiring: the merger uses that rule for all three tombstone kinds on
//      restore (and the sync union otherwise), the iOS 16 restore path clears
//      the same tombstones, and the restore emits per-record v3 upserts.
//
// Standalone: `swift BackupRestoreDeletedGroupTests.swift` (needs swiftc).

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}

let root = FileManager.default.currentDirectoryPath
func source(_ rel: String) -> String {
    var dir = URL(fileURLWithPath: root)
    for _ in 0..<7 {
        let p = dir.appendingPathComponent("src/ios/" + rel).path
        if let s = try? String(contentsOfFile: p, encoding: .utf8) { return s }
        dir = dir.deletingLastPathComponent()
    }
    fatalError("source not found: \(rel)")
}
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
    return String(s[r1.upperBound..<r2.lowerBound])
}

// MARK: - A. Shipping rule, compiled and exercised

print("A. ProviderConfigTombstone.survivingRestore (compiled from shipping source)")
let store = source("Providers/ProviderConfigStore.swift")
let structSrc = between(store, "struct ProviderConfigTombstone: Codable, Hashable {", "\n}\n").map {
    "struct ProviderConfigTombstone: Codable, Hashable {" + $0 + "\n}\n"
}
let ruleSrc = between(store, "// [T-backup-restore-tombstone] BEGIN restore-tombstone-rule",
                      "// [T-backup-restore-tombstone] END restore-tombstone-rule")
check("rule and struct found in ProviderConfigStore.swift", structSrc != nil && ruleSrc != nil)

if let structSrc, let ruleSrc {
    let harness = """
    import Foundation
    \(structSrc)
    \(ruleSrc)
    func t(_ id: String) -> ProviderConfigTombstone { .init(id: id, deletedAt: Date(timeIntervalSince1970: 1)) }
    var out: [String] = []
    // The report: group G deleted on this device, then the backup holding G is restored.
    let afterDelete = [t("G")]
    out.append("reported=\\(ProviderConfigTombstone.survivingRestore(afterDelete, restoring: ["G", "OTHER"]).map(\\.id))")
    // A tombstone for something the backup does NOT carry must survive.
    out.append("unrelated=\\(ProviderConfigTombstone.survivingRestore([t("G"), t("X")], restoring: ["G"]).map(\\.id).sorted())")
    // Empty package: nothing is cleared.
    out.append("empty=\\(ProviderConfigTombstone.survivingRestore([t("G")], restoring: []).map(\\.id))")
    // No local tombstones: nothing invented.
    out.append("none=\\(ProviderConfigTombstone.survivingRestore([], restoring: ["G"]).map(\\.id))")
    print(out.joined(separator: "\\n"))
    """
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("restore-tombstone-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let main = tmp.appendingPathComponent("main.swift")
    try harness.write(to: main, atomically: true, encoding: .utf8)
    let bin = tmp.appendingPathComponent("t")

    func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", main.path, "-o", bin.path])
    check("shipping rule compiles standalone", cc == 0)
    if cc != 0 { print(ccOut) }
    let (rc, out) = run(bin.path, [])
    let lines = Dictionary(uniqueKeysWithValues: out.split(separator: "\n").compactMap { line -> (String, String)? in
        let parts = line.split(separator: "=", maxSplits: 1)
        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
    })
    check("ran", rc == 0)
    check("reported scenario: restoring G clears G's tombstone (got \(lines["reported"] ?? "?"))", lines["reported"] == "[]")
    check("tombstone for an id the package lacks survives (got \(lines["unrelated"] ?? "?"))", lines["unrelated"] == "[\"X\"]")
    check("empty package clears nothing (got \(lines["empty"] ?? "?"))", lines["empty"] == "[\"G\"]")
    check("no local tombstones stays empty (got \(lines["none"] ?? "?"))", lines["none"] == "[]")
}

// MARK: - B. Wiring

print("B. Restore paths use the rule")
let engine = source("Agent/Sync/CloudSyncEngine.swift")
let body = between(engine, "private static func mergeProviderConfigBody(", "private static func mergeTombstones(") ?? ""
check("merge body located", !body.isEmpty)
let restoreBranch = between(body, "if isRestore {\n            mergedInstanceTombstones", "} else {") ?? ""
check("restore branch uses survivingRestore for instances",
      restoreBranch.contains("survivingRestore(\n                local.deletedInstances, restoring: Set(remote.instances.map(\\.id)))"))
check("restore branch uses survivingRestore for entries",
      restoreBranch.contains("survivingRestore(\n                local.deletedModelEntries, restoring: Set(remote.modelEntries.map(\\.id)))"))
check("restore branch uses survivingRestore for groups",
      restoreBranch.contains("survivingRestore(\n                local.deletedModelGroups, restoring: Set(remote.modelGroups.map(\\.id)))"))
check("restore branch does not union the package's tombstones",
      !restoreBranch.contains("remote.deleted"))
check("sync keeps the tombstone union",
      body.contains("mergedGroupTombstones    = mergeTombstones(local.deletedModelGroups, remote.deletedModelGroups)"))
check("group filter still keyed on the merged tombstones",
      body.contains("let tombstonedGroupIds    = Set(mergedGroupTombstones.map(\\.id))")
      && body.contains("if tombstonedGroupIds.contains(rg.id) { continue }"))
check("restore emits per-record v3 upserts",
      body.contains("await store.markRestoredRecordsDirty(prior: prior)")
      && body.contains("let preRestoreConfig = local"))
check("markRestoredRecordsDirty diffs through emitV3MarkDirty",
      store.contains("func markRestoredRecordsDirty(prior: ProviderConfig) async {\n        let current = config\n        await Self.emitV3MarkDirty(prior: prior, current: current)"))

let importer = source("Agent/Backup/BackupImporter+Categories.swift")
// [T-group-order-log] The call now also names its reason for the
// `[GroupOrder]` log; the anchor follows it.
let fallback = between(importer, "static func mergeProviderConfigFallback(", "store.applyConfig(local, orderReason: \"restore-merge\")") ?? ""
check("iOS 16 path clears restored group tombstones",
      fallback.contains("local.deletedModelGroups = ProviderConfigTombstone.survivingRestore("))
check("iOS 16 path clears restored instance and entry tombstones",
      fallback.contains("local.deletedInstances = ProviderConfigTombstone.survivingRestore(")
      && fallback.contains("local.deletedModelEntries = ProviderConfigTombstone.survivingRestore("))

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
