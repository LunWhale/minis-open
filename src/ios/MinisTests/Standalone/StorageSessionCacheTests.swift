#!/usr/bin/env swift
// [T-storage-session-cache] Settings › Storage used to rescan the whole app
// container on every onAppear (so also when a session's detail page was
// popped) and again after each "clear files". The page now scans once per
// visit and applies each session action to a SessionStorageLedger: only the
// touched directories are re-measured, the row updates or leaves, the list
// re-sorts, and the totals move by the measured difference.
//
// Compiles the shipping Agent/Chat/SessionDeletionSupport.swift with a
// harness, so the real ledger is what's tested.
//
// Run: swift StorageSessionCacheTests.swift   (needs swiftc)
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
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
func source(_ rel: String) -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: here.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

let support = source("Agent/Chat/SessionDeletionSupport.swift")
let view = source("Views/Settings/StorageManagementView.swift")
let content = contentViewSource()

let harness = #"""
import Foundation
typealias Row = SessionStorageLedger.Row
func out(_ k: String, _ v: Any) { print("\(k)=\(v)") }
func ids(_ l: SessionStorageLedger) -> String { l.rows.map { "\($0.id):\($0.minisSize)" }.joined(separator: ",") }

// A (300, with child a1 of 200 → 500), B (400), C (100), D (0).
let base = SessionStorageLedger(
    rows: [Row(id: "C", title: "c", minisSize: 100),
           Row(id: "A", title: "a", minisSize: 500, descendantIds: ["a1"]),
           Row(id: "D", title: "d", minisSize: 0),
           Row(id: "B", title: "b", minisSize: 400)],
    directoryBytes: ["A": 300, "a1": 200, "B": 400, "C": 100])
out("INIT", ids(base))
out("INIT_TOTAL", base.totalBytes)
out("DIRS_A", base.directoryIds(of: ["A"]).joined(separator: ","))

// Clear A's files (A and its child both gone from disk).
var l1 = base
let c1 = l1.apply(remeasured: [:], rowIds: ["A"], removeRows: false)
out("CLEAR_A", ids(l1)); out("CLEAR_A_TOTAL", l1.totalBytes)
out("CLEAR_A_CHANGE", "\(c1.fileDelta)|\(c1.freed)|\(c1.stranded)")

// Clear B, but a file survived (e.g. recreated): partial.
var l2 = base
let c2 = l2.apply(remeasured: ["B": 50], rowIds: ["B"], removeRows: false)
out("PARTIAL_B", ids(l2)); out("PARTIAL_B_CHANGE", "\(c2.fileDelta)|\(c2.freed)|\(c2.stranded)")

// Delete B and C together.
var l3 = base
let c3 = l3.apply(remeasured: [:], rowIds: ["B", "C"], removeRows: true)
out("DELETE_BC", ids(l3)); out("DELETE_BC_TOTAL", l3.totalBytes)
out("DELETE_BC_CHANGE", "\(c3.fileDelta)|\(c3.freed)|\(c3.stranded)")
out("DELETE_BC_DIRS", l3.directoryBytes.keys.sorted().joined(separator: ","))

// Delete A but its child's directory could not be removed: stranded bytes.
var l4 = base
let c4 = l4.apply(remeasured: ["a1": 200], rowIds: ["A"], removeRows: true)
out("DELETE_A_STRANDED", "\(c4.fileDelta)|\(c4.freed)|\(c4.stranded)")

// A session grew since the scan: freed never negative.
var l5 = base
let c5 = l5.apply(remeasured: ["C": 900], rowIds: ["C"], removeRows: false)
out("GREW_C", ids(l5)); out("GREW_C_CHANGE", "\(c5.fileDelta)|\(c5.freed)")

// Unknown ids are ignored; other rows are untouched by any action.
var l6 = base
let c6 = l6.apply(remeasured: ["X": 5], rowIds: ["X"], removeRows: true)
out("UNKNOWN", "\(ids(l6))|\(c6.fileDelta)")
out("UNTOUCHED", l1.rows.filter { $0.id != "A" } == base.rows.filter { $0.id != "A" })
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("storage-cache-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let supportFile = tmp.appendingPathComponent("support.swift")
let mainFile = tmp.appendingPathComponent("main.swift")
try support.write(to: supportFile, atomically: true, encoding: .utf8)
try harness.write(to: mainFile, atomically: true, encoding: .utf8)
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
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", supportFile.path, mainFile.path, "-o", bin.path])
check("shipping SessionDeletionSupport.swift compiles standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, outText) = run(bin.path, [])
check("harness ran", rc == 0)
var r: [String: String] = [:]
for line in outText.split(separator: "\n") {
    let kv = line.split(separator: "=", maxSplits: 1)
    if kv.count == 2 { r[String(kv[0])] = String(kv[1]) }
}

print("\n1. Ledger")
check("rows sorted largest first, ties by id: \(r["INIT"] ?? "")", r["INIT"] == "A:500,B:400,C:100,D:0")
check("total = sum of rows (children folded in)", r["INIT_TOTAL"] == "1000")
check("a row's directories include its agent children", r["DIRS_A"] == "A,a1")

print("\n2. Clear one session: only it changes, list re-sorts, totals move")
check("A drops to 0 and moves to the bottom: \(r["CLEAR_A"] ?? "")", r["CLEAR_A"] == "B:400,C:100,A:0,D:0")
check("session total 1000 → 500", r["CLEAR_A_TOTAL"] == "500")
check("container delta −500, freed 500, nothing stranded", r["CLEAR_A_CHANGE"] == "-500|500|0")
check("other rows untouched", r["UNTOUCHED"] == "true")
check("partial clear keeps the re-measured size: \(r["PARTIAL_B"] ?? "")", r["PARTIAL_B"] == "A:500,C:100,B:50,D:0")
check("…freed = old − new", r["PARTIAL_B_CHANGE"] == "-350|350|0")
check("a session that grew is re-sorted up, freed never negative", r["GREW_C"] == "C:900,A:500,B:400,D:0" && r["GREW_C_CHANGE"] == "800|0")

print("\n3. Delete sessions: rows leave, totals move")
check("B and C removed: \(r["DELETE_BC"] ?? "")", r["DELETE_BC"] == "A:500,D:0")
check("session total 1000 → 500", r["DELETE_BC_TOTAL"] == "500")
check("delta −500, freed 500", r["DELETE_BC_CHANGE"] == "-500|500|0")
check("their directory entries are dropped from the cache", r["DELETE_BC_DIRS"] == "A,a1")
check("bytes left on disk after a delete are reported as stranded (→ orphaned)", r["DELETE_A_STRANDED"] == "-300|300|200")
check("unknown ids change nothing", r["UNKNOWN"] == "A:500,B:400,C:100,D:0|0")

print("\n4. Wiring in the shipping code")
check("onAppear scans only the first time", view.contains(".onAppear { vm.loadIfNeeded() }") && !view.contains(".onAppear { vm.load() }"))
check("loadIfNeeded guards on hasLoaded", view.contains("guard !hasLoaded else { return }"))
check("pull to refresh is the explicit full rescan", view.contains("await vm.load().value"))
check("the detail page no longer triggers a full reload",
      !view.contains("onFilesCleared") && view.contains("await vm.perform(.clearFiles, on: [sessionId])"))
check("actions re-measure only the touched directories",
      view.contains("for sid in directories { sizes[sid] = self.directorySize(sid) }")
      && view.contains("ledger.apply(remeasured: measured.sizes, rowIds: ids, removeRows: action == .delete)"))
check("totals move by the measured delta (plus the database after a delete)",
      view.contains("containerTotalSize = max(0, containerTotalSize + totalDelta)") && view.contains("totalDelta += db - chatDatabaseSize"))
check("delete goes through the sidebar's teardown + store funnel",
      view.contains("await ContentView.tearDownForDeletion(Set(ids))") && view.contains("for id in ids { await ChatStore.shared.deleteSession(id) }"))
check("the sidebar hears about it and closes a deleted open conversation",
      content.contains(".onReceive(NotificationCenter.default.publisher(for: .sessionsDeletedElsewhere), perform: handleSessionsDeletedElsewhere)")
      && content.contains("if !isWideLayout, let current = currentStackSessionId, ids.contains(current) {"))
check("multi-select: Select toggle, bottom bar with Clear Files / Delete",
      view.contains("isSelecting ? AppLocalized(\"Done\") : AppLocalized(\"Select\")")
      && view.contains("confirm(.clearFiles, Array(selection))") && view.contains("confirm(.delete, Array(selection))"))
check("every action is confirmed and reports its result",
      view.contains("run(pending)") && view.contains("actionResult = result"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
