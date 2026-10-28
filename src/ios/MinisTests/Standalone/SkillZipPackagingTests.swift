#!/usr/bin/env swift
// [T-skill-zip-off-main] Whenever a task ended, the whole app froze for a
// moment - no scrolling, no taps - in whatever session was on screen.
//
// Device log (iPhone 17 Pro, 2026-10-05): the hang detector recorded twelve
// main-thread hangs of 2.4 to 2.7 s in 75 minutes, all with one stack:
//   ChatStoreSyncHydrators.buildSkill -> SkillStore.buildSkillZipData
//   -> buildZipArchive -> crc32      (inside MainActor.run)
// each followed by "[ZIP] 'shortcuts-playground-minis' ZIP built: 5105525
// bytes" (106 files). Sync's push is held while a task runs and released when
// it ends, so the first batch after a task carried the edited skill and packed
// it on the main thread; CloudKit then kept failing the batch (partial
// failure, 429), and every retry ~13 s later packed the identical skill again.
//
// Three causes, three fixes:
//   1. the packing ran on the main actor        -> a detached background task;
//   2. CRC-32 was eight Swift steps per byte    -> zlib's crc32;
//   3. every batch packed the skill from scratch -> an unchanged skill reuses
//      the file built last time (fingerprint: path, size, modification time).
//
// [1] compiles the shipping packaging block and runs it against real
//     directories, /usr/bin/unzip and the previous implementation.
// [2] pins the wiring in the shipping sources.
//
// Run: swift SkillZipPackagingTests.swift
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
let iosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String {
    (try? String(contentsOf: iosRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func code(_ src: String) -> String {
    src.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
}
func between(_ s: String, _ a: String, _ b: String) -> String {
    guard let ra = s.range(of: a), let rb = s.range(of: b, range: ra.upperBound..<s.endIndex) else { return "" }
    return String(s[ra.lowerBound..<rb.lowerBound])
}

let store = source("Agent/Session/SkillStore.swift")
let packaging = between(store, "// BEGIN SkillZipPackaging", "// END SkillZipPackaging")

// MARK: - 1. The shipping packaging block

let scenario = #"""

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("SkillZipPackagingScenario-\(ProcessInfo.processInfo.processIdentifier)")
try? fm.removeItem(at: root)
defer { try? fm.removeItem(at: root) }
func write(_ rel: String, _ data: Data, in dir: URL) {
    let url = dir.appendingPathComponent(rel)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url)
}
func run(_ tool: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}
/// The app's exclusion rule, reduced to what the fixture uses.
let excluded: (String) -> Bool = { ["node_modules", ".git", "build"].contains($0) || $0.hasSuffix(".egg-info") }

// The implementation this replaces, kept as the reference for "same bytes".
func oldCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 != 0 ? 0xEDB88320 : 0) }
    }
    return crc ^ 0xFFFFFFFF
}
func u16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
func u32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
func oldArchive(_ files: [(relativePath: String, data: Data)]) -> Data {
    var archive = Data(), central = Data()
    var offset: UInt32 = 0
    for file in files {
        let name = Data(file.relativePath.utf8)
        let size = UInt32(file.data.count)
        let crc = oldCRC32(file.data)
        var local = Data()
        local.append(u32(0x04034B50)); local.append(u16(20)); local.append(u16(0)); local.append(u16(0))
        local.append(u16(0)); local.append(u16(0)); local.append(u32(crc)); local.append(u32(size)); local.append(u32(size))
        local.append(u16(UInt16(name.count))); local.append(u16(0)); local.append(name); local.append(file.data)
        var cd = Data()
        cd.append(u32(0x02014B50)); cd.append(u16(20)); cd.append(u16(20)); cd.append(u16(0)); cd.append(u16(0))
        cd.append(u16(0)); cd.append(u16(0)); cd.append(u32(crc)); cd.append(u32(size)); cd.append(u32(size))
        cd.append(u16(UInt16(name.count))); cd.append(u16(0)); cd.append(u16(0)); cd.append(u16(0)); cd.append(u16(0))
        cd.append(u32(0)); cd.append(u32(offset)); cd.append(name)
        archive.append(local); central.append(cd); offset += UInt32(local.count)
    }
    let cdOffset = offset
    archive.append(central)
    archive.append(u32(0x06054B50)); archive.append(u16(0)); archive.append(u16(0))
    archive.append(u16(UInt16(files.count))); archive.append(u16(UInt16(files.count)))
    archive.append(u32(UInt32(central.count))); archive.append(u32(cdOffset)); archive.append(u16(0))
    return archive
}
var seed: UInt64 = 0x9E3779B97F4A7C15
func noise(_ count: Int) -> Data {
    var d = Data(capacity: count)
    for _ in 0..<count { seed = seed &* 6364136223846793005 &+ 1442695040888963407; d.append(UInt8(truncatingIfNeeded: seed >> 33)) }
    return d
}

print("1a. The checksum and the archive are what they were")
let samples: [Data] = [Data(), Data([0x00]), Data([0xFF]), Data("123456789".utf8),
                       Data("# Skill\n中文 and emoji 🙂\n".utf8), Data(count: 70_000), noise(40_000)]
check("zlib's CRC-32 equals the old bit-by-bit one on empty, one byte, text, zeros and noise",
      samples.allSatisfy { SkillZipPackager.crc32($0) == oldCRC32($0) })
check("the standard check value holds: CRC-32(\"123456789\") = 0xCBF43926",
      SkillZipPackager.crc32(Data("123456789".utf8)) == 0xCBF43926)
let listing: [(relativePath: String, data: Data)] = [
    ("SKILL.md", Data("---\nname: demo\n---\nbody\n".utf8)),
    ("empty.txt", Data()),
    ("scripts/run.sh", Data("#!/bin/sh\necho hi\n".utf8)),
    ("参考/说明.md", Data("中文路径\n".utf8)),
    ("assets/blob.bin", noise(30_000)),
]
let archive = SkillZipPackager.buildZipArchive(files: listing)
check("the archive is byte-for-byte the one the old writer produced", archive == oldArchive(listing))
check("no files: the same 22-byte empty archive as before",
      SkillZipPackager.buildZipArchive(files: []) == oldArchive([]) && SkillZipPackager.buildZipArchive(files: []).count == 22)

print("1b. Packing a skill directory")
let skill = root.appendingPathComponent("skills/demo")
write("SKILL.md", Data("---\nname: demo\n---\nbody\n".utf8), in: skill)
write("scripts/run.sh", Data("#!/bin/sh\necho hi\n".utf8), in: skill)
write("references/deep/notes.md", Data("notes\n".utf8), in: skill)
write("a-first-by-name.txt", Data("a\n".utf8), in: skill)
write(".hidden", Data("no\n".utf8), in: skill)
write("node_modules/pkg/index.js", Data("no\n".utf8), in: skill)
write("demo.egg-info/PKG-INFO", Data("no\n".utf8), in: skill)
let cache = root.appendingPathComponent("cache")
let packager = SkillZipPackager(cacheDirectory: cache)
var logs: [String] = []
func pack(_ id: String = "demo", _ dir: URL? = nil) -> URL? {
    packager.zipFile(skillId: id, skillDir: dir ?? skill, isExcludedDir: excluded, log: { logs.append($0) })
}
let first = pack()
check("a ZIP file comes back, in the cache directory", first?.path == cache.appendingPathComponent("demo.zip").path
      && fm.fileExists(atPath: first?.path ?? ""))
let tested = run("/usr/bin/unzip", ["-t", first?.path ?? ""])
check("unzip accepts it with no errors", tested.status == 0 && tested.out.contains("No errors detected"))
let names = run("/usr/bin/unzip", ["-Z1", first?.path ?? ""]).out.split(separator: "\n").map(String.init)
check("SKILL.md first, the rest by path; hidden files and excluded directories left out",
      names == ["SKILL.md", "a-first-by-name.txt", "references/deep/notes.md", "scripts/run.sh"])
let out = root.appendingPathComponent("unzipped")
_ = run("/usr/bin/unzip", ["-q", "-o", first?.path ?? "", "-d", out.path])
check("every file unpacks to its original bytes",
      ["SKILL.md", "a-first-by-name.txt", "references/deep/notes.md", "scripts/run.sh"].allSatisfy {
          (try? Data(contentsOf: out.appendingPathComponent($0))) == (try? Data(contentsOf: skill.appendingPathComponent($0)))
      })
check("the build is logged with its size and how long it took, and names what it left out",
      logs.contains { $0.contains("[ZIP] 'demo' packing 4 files") }
      && logs.contains { $0.contains("[ZIP] 'demo' ZIP built: ") && $0.hasSuffix("ms") }
      && logs.contains { $0.contains("excluded dirs: ") && $0.contains("node_modules") && $0.contains("demo.egg-info") })

print("1c. An unchanged skill is not packed again")
func modified(_ url: URL?) -> Date? { (try? fm.attributesOfItem(atPath: url?.path ?? ""))?[.modificationDate] as? Date }
let builtAt = modified(first)
logs = []
let again = pack()
check("same file back, nothing read or written, and the log says reused",
      again == first && modified(again) == builtAt
      && logs.contains { $0.contains("unchanged since the last build — reusing") }
      && !logs.contains { $0.contains("packing") })
logs = []
check("ten retries of a failing batch: still no rebuild",
      (0..<10).allSatisfy { _ in pack() == first } && !logs.contains { $0.contains("packing") })

print("1d. Anything that changes the skill packs it again")
func rebuilds(_ label: String, _ change: () -> Void) {
    change()
    logs = []
    let url = pack()
    check(label, url != nil && logs.contains { $0.contains("packing") } && !logs.contains { $0.contains("reusing") })
    logs = []
    _ = pack()
    check("  ... and is reused again afterwards", logs.contains { $0.contains("reusing") })
}
rebuilds("a file rewritten with different bytes of the same length") {
    write("scripts/run.sh", Data("#!/bin/sh\necho ho\n".utf8), in: skill)
    try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: skill.appendingPathComponent("scripts/run.sh").path)
}
check("  ... and the new bytes are the ones in the archive", {
    _ = run("/usr/bin/unzip", ["-q", "-o", pack()?.path ?? "", "-d", out.path])
    return (try? String(contentsOf: out.appendingPathComponent("scripts/run.sh"), encoding: .utf8)) == "#!/bin/sh\necho ho\n"
}())
rebuilds("a file that grew") { write("SKILL.md", Data("---\nname: demo\n---\nbody, longer\n".utf8), in: skill) }
rebuilds("a file added") { write("references/new.md", Data("new\n".utf8), in: skill) }
rebuilds("a file removed") { try? fm.removeItem(at: skill.appendingPathComponent("a-first-by-name.txt")) }
rebuilds("a file renamed") {
    try? fm.moveItem(at: skill.appendingPathComponent("references/new.md"), to: skill.appendingPathComponent("references/renamed.md"))
}
rebuilds("the cached ZIP deleted (the temporary directory was emptied)") { try? fm.removeItem(at: cache.appendingPathComponent("demo.zip")) }
rebuilds("the cached ZIP cut short") { try? Data("PK".utf8).write(to: cache.appendingPathComponent("demo.zip")) }
logs = []
write("node_modules/pkg/other.js", Data("still excluded\n".utf8), in: skill)
write(".hidden", Data("still hidden, changed\n".utf8), in: skill)
_ = pack()
check("a change in a hidden file or an excluded directory is not a change", logs.contains { $0.contains("reusing") })

print("1e. Nothing to pack, and several skills")
logs = []
check("a missing directory: nil, and it says so",
      pack("gone", root.appendingPathComponent("skills/gone")) == nil && logs.contains { $0.contains("directory missing") })
let bare = root.appendingPathComponent("skills/bare")
write(".hidden", Data("x".utf8), in: bare)
write("node_modules/x.js", Data("x".utf8), in: bare)
logs = []
check("only hidden and excluded content: nil, nothing cached",
      pack("bare", bare) == nil && logs.contains { $0.contains("no files found") }
      && !fm.fileExists(atPath: cache.appendingPathComponent("bare.zip").path))
let other = root.appendingPathComponent("skills/other")
write("SKILL.md", Data("other\n".utf8), in: other)
let otherZip = pack("other", other)
logs = []
check("each skill has its own file and its own memory of it",
      otherZip?.lastPathComponent == "other.zip" && pack("other", other) == otherZip && pack() == first
      && logs.filter { $0.contains("reusing") }.count == 2)
check("a second packager (a fresh launch) trusts nothing it did not build itself", {
    var l: [String] = []
    let fresh = SkillZipPackager(cacheDirectory: cache)
    _ = fresh.zipFile(skillId: "other", skillDir: other, isExcludedDir: excluded, log: { l.append($0) })
    return l.contains { $0.contains("packing") }
}())

print("1f. The size from the report")
let big = root.appendingPathComponent("skills/big")
write("SKILL.md", Data("big\n".utf8), in: big)
for i in 0..<105 { write("data/part-\(i).bin", noise(48_500), in: big) }
logs = []
let t0 = Date()
let bigZip = pack("big", big)
let buildMs = Date().timeIntervalSince(t0) * 1000
let bigSize = ((try? fm.attributesOfItem(atPath: bigZip?.path ?? ""))?[.size] as? Int) ?? 0
print(String(format: "     106 files, %.1f MB packed in %.0f ms (unoptimised script; the device took 2400-2700 ms on the main thread)", Double(bigSize) / 1_048_576, buildMs))
check("a 5 MB, 106-file skill packs in well under a second, even unoptimised", bigSize > 5_000_000 && buildMs < 1000)
let t1 = Date()
let reused = pack("big", big)
let reuseMs = Date().timeIntervalSince(t1) * 1000
print(String(format: "     reused in %.1f ms", reuseMs))
check("and the retry after it costs a directory listing, not a rebuild", reused == bigZip && reuseMs < 200)
check("unzip accepts the large archive", run("/usr/bin/unzip", ["-tq", bigZip?.path ?? ""]).status == 0)

exit(failures == 0 ? 0 : 1)
"""#

print("1. The shipping packaging block")
check("the packaging block was found", packaging.contains("final class SkillZipPackager: @unchecked Sendable {")
      && packaging.contains("private extension Data {"))
if failures == 0 {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SkillZipPackaging-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("main.swift")
    try? ("import Foundation\nimport zlib\n" + packaging + scenario).write(to: file, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["swift", file.path]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try? p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    print(text, terminator: "")
    let passed = text.components(separatedBy: "✅").count - 1
    check("harness ran to the end (\(passed) checks) and exited 0", p.terminationStatus == 0 && passed >= 34)
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - 2. Wiring

print("\n2. Wiring in the shipping sources")
let hydrators = source("Agent/Sync/V2/ChatStoreSyncHydrators.swift")
let engine = source("Agent/Sync/CloudSyncEngine.swift")

let entry = between(store, "    nonisolated static func skillZipFile(skillId: String, skillDir: URL) async -> URL? {", "    /// SKILL.md of the skill at `skillDir`")
check("SkillStore's entry point is nonisolated and packs on a detached background task",
      entry.contains("await Task.detached(priority: .utility) {\n            SkillZipPackager.shared.zipFile(")
      && entry.contains("isExcludedDir: { SkillStore.isExcludedDir($0) }")
      && !entry.contains("MainActor"))
check("the app's exclusion rule can be called from that task", store.contains("nonisolated static func isExcludedDir(_ name: String) -> Bool {"))
check("the old main-actor builder and the bit-by-bit checksum are gone from SkillStore",
      !store.contains("func buildSkillZipData(") && !code(store).contains("for _ in 0..<8")
      && code(packaging).contains("zlib.crc32(0, base, uInt(buf.count))"))
check("the ZIP is written atomically, and remembered only when it matches the listing",
      packaging.contains("try zipData.write(to: destination, options: .atomic)")
      && packaging.contains("built[skillId] = matchesListing ? (fingerprint, zipData.count) : nil"))

let buildSkill = between(hydrators, "    private static func buildSkill(id: String) async -> PortableRecord? {", "    private static func mergeSkill(record: PortableRecord) async {")
let mainHop = between(buildSkill, "let snapshot = await MainActor.run { () -> SkillSnapshot? in", "guard let snap = snapshot else { return nil }")
check("V2 sync: the main actor hands over the skill's row and directory, nothing else",
      mainHop.contains("skillDir: SkillStore.shared.skillDirectoryURL(for: s.id)")
      && !mainHop.contains("Zip") && !mainHop.contains("readSkillContent") && !mainHop.contains("Data("))
check("V2 sync: SKILL.md and the ZIP are produced after leaving it",
      buildSkill.contains("let bodyText = SkillStore.readSkillContent(in: snap.skillDir) ?? \"\"")
      && buildSkill.contains("let bundleAssetURL = await SkillStore.skillZipFile(skillId: id, skillDir: snap.skillDir)")
      && buildSkill.contains("bodyText: bodyText, bundleZipURL: bundleAssetURL"))
check("V1 sync: the same entry point, no ZIP inside MainActor.run",
      engine.contains("let skillDir = await MainActor.run { SkillStore.shared.skillDirectoryURL(for: id) }\n            if let zipURL = await SkillStore.skillZipFile(skillId: id, skillDir: skillDir) {\n                record[\"bundleAsset\"] = CKAsset(fileURL: zipURL)")
      && !engine.contains("buildSkillZipData"))
var strays: [String] = []
if let walker = FileManager.default.enumerator(at: iosRoot, includingPropertiesForKeys: nil) {
    for case let url as URL in walker where url.pathExtension == "swift" && !url.path.contains("/MinisTests/") {
        if (try? String(contentsOf: url, encoding: .utf8))?.contains("buildSkillZipData") == true { strays.append(url.lastPathComponent) }
    }
}
check("no caller of the old builder is left anywhere in the app", strays.isEmpty)

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
