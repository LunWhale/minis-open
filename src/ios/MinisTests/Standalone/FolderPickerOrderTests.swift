// Tests for [T-folder-picker-recency] — the Move-to-Group picker lists groups
// most recently active first. Compiles the REAL FolderPickerOrder out of
// Views/ContentView/Sidebar/FolderPickerSheet.swift and runs it; also checks the picker (and only the picker)
// uses it.
//
// Standalone: `swift FolderPickerOrderTests.swift` from this directory.
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
func check(_ l: String, _ ok: Bool) {
    if ok { print("  ✅ \(l)") } else { print("  ❌ \(l)"); failures += 1 }
}
let root = FileManager.default.currentDirectoryPath + "/../../"
let view = contentViewSource()
check("ContentView sources readable", !view.isEmpty)
guard let s = view.range(of: "enum FolderPickerOrder {"),
      let e = view.range(of: "// END FolderPickerOrder", range: s.upperBound..<view.endIndex) else {
    print("❌ FolderPickerOrder not found"); exit(1)
}
let helper = String(view[s.lowerBound..<e.lowerBound])

let harness = "import Foundation\n" + helper + #"""
struct G { let name: String; let updated: Date; let created: Date; let newestMember: Date? }
func t(_ m: Double) -> Date { Date(timeIntervalSince1970: m * 60) }
func order(_ gs: [G]) -> String {
    FolderPickerOrder.byRecentActivity(gs) {
        FolderPickerOrder.lastActive(folderUpdatedAt: $0.updated, folderCreatedAt: $0.created,
                                     newestMemberUpdatedAt: $0.newestMember)
    }.map(\.name).joined(separator: ",")
}
// Incoming order = the home list's group order.
print("members=" + order([
    G(name: "A", updated: t(1), created: t(1), newestMember: t(10)),
    G(name: "B", updated: t(1), created: t(1), newestMember: t(30)),
    G(name: "C", updated: t(1), created: t(1), newestMember: t(20)),
]))
print("folderEdit=" + order([
    G(name: "A", updated: t(40), created: t(1), newestMember: t(10)),   // renamed recently
    G(name: "B", updated: t(1), created: t(1), newestMember: t(30)),
]))
print("empty=" + order([
    G(name: "Old", updated: t(5), created: t(5), newestMember: t(8)),
    G(name: "Empty", updated: t(9), created: t(9), newestMember: nil),  // new, no members
    G(name: "EmptyOld", updated: t(2), created: t(2), newestMember: nil),
]))
print("ties=" + order([
    G(name: "X", updated: t(1), created: t(1), newestMember: t(7)),
    G(name: "Y", updated: t(1), created: t(1), newestMember: t(7)),
    G(name: "Z", updated: t(1), created: t(1), newestMember: t(7)),
]))
"""#
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fpo-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let main = tmp.appendingPathComponent("main.swift"); try! harness.write(to: main, atomically: true, encoding: .utf8)
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try! p.run(); p.waitUntilExit()
    return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}
let bin = tmp.appendingPathComponent("t").path
let (cs, cout) = run("/usr/bin/xcrun", ["swiftc", "-o", bin, main.path])
check("FolderPickerOrder compiles standalone", cs == 0)
if cs != 0 { print(cout); exit(1) }
let (_, o) = run(bin, [])

print("▶️  ordering")
check("newest member activity first (B 30 > C 20 > A 10)", o.contains("members=B,C,A"))
check("a group edited recently counts too (max of folder and members)", o.contains("folderEdit=A,B"))
check("an empty group uses its own updated/created time", o.contains("empty=Empty,Old,EmptyOld"))
check("equal activity keeps the incoming (home list) order", o.contains("ties=X,Y,Z"))

print("▶️  wiring")
check("the picker items are ordered by FolderPickerOrder",
      view.contains("return FolderPickerOrder.byRecentActivity(items) { activity[$0.folder.id] ?? .distantPast }"))
check("…using the newest member's updatedAt and the folder's own times",
      view.contains("newestMemberUpdatedAt: m.first?.updatedAt)")
      && view.contains("folderUpdatedAt: folder.updatedAt, folderCreatedAt: folder.createdAt,"))
check("only the picker uses it (the home list's group order is untouched)",
      view.components(separatedBy: "FolderPickerOrder.byRecentActivity(").count - 1 == 1) // one call site

print(failures == 0 ? "\n🎉 all checks passed" : "\n❌ \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
