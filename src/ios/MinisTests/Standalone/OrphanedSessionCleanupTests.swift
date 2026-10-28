#!/usr/bin/env swift
// [T-storage-orphan-cleanup] Settings › Storage showed "Orphaned Session
// Files" (126.6 MB for the user who reported it) with nothing to clear them.
// They are session directories whose row is gone from the database, so they
// are not in the Sessions list either - the only way to get the space back was
// to reinstall the app.
//
// The page now has "Clean Up Orphaned Session Files". Because it removes
// directories the user did not pick, the rules are deliberately narrow:
//   - only UUID-named real directories directly under MinisChat/minis
//     (never shared / skills / memory, loose files, or symlinks);
//   - only when no session has that id, compared without case;
//   - never a session the app is using right now;
//   - never one that changed in the last hour (its row may still be syncing);
//   - the directories are listed BEFORE the session ids are read.
//
// [1] compiles the shipping Agent/Chat/SessionDeletionSupport.swift with a
//     harness and runs those rules against a real directory tree in tmp.
// [2] pins how the Storage page uses them.
//
// Run: swift OrphanedSessionCleanupTests.swift   (needs swiftc)
import Foundation

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
func code(_ src: String) -> String {
    src.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
}
func block(_ src: String, _ marker: String) -> String {
    guard let start = src.range(of: marker) else { return "" }
    var depth = 0, seenOpen = false
    var i = start.lowerBound
    while i < src.endIndex {
        let c = src[i]
        if c == "{" { depth += 1; seenOpen = true }
        if c == "}" { depth -= 1; if seenOpen && depth == 0 { return String(src[start.lowerBound...i]) } }
        i = src.index(after: i)
    }
    return ""
}
func index(_ hay: String, _ needle: String) -> Int {
    hay.range(of: needle).map { hay.distance(from: hay.startIndex, to: $0.lowerBound) } ?? -1
}

let support = source("Agent/Chat/SessionDeletionSupport.swift")
let view = source("Views/Settings/StorageManagementView.swift")

// MARK: - 1. The shipping rules against a real directory tree

let harness = #"""
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}

let fm = FileManager.default
let base = fm.temporaryDirectory.appendingPathComponent("minis-orphan-\(UUID().uuidString)", isDirectory: true)
try! fm.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: base) }

func write(_ dir: String, _ rel: String) {
    let url = base.appendingPathComponent(dir).appendingPathComponent(rel)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(repeating: 0xCD, count: 256).write(to: url)
}
/// Set the modification date of `root` and everything beneath it.
func age(_ root: URL, by seconds: TimeInterval) {
    let then = Date().addingTimeInterval(-seconds)
    var all = [root]
    if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) { for case let u as URL in e { all.append(u) } }
    for u in all where (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true {
        try! fm.setAttributes([.modificationDate: then], ofItemAtPath: u.path)
    }
}
func exists(_ rel: String) -> Bool { fm.fileExists(atPath: base.appendingPathComponent(rel).path) }

let live = UUID().uuidString, orphanA = UUID().uuidString, orphanB = UUID().uuidString
let fresh = UUID().uuidString, busy = UUID().uuidString
let uuidFile = UUID().uuidString, uuidLink = UUID().uuidString
write(live, "workspace/keep.txt")
write(orphanA, "workspace/old.txt")
write(orphanB, "offloads/.hidden/deep.bin")
write(fresh, "attachments/just-synced.png")
write(busy, "workspace/running.log")
let globals = ["shared", "skills", "memory", "not-a-uuid"]
for g in globals { write(g, "data/file.md") }
try! Data("{}".utf8).write(to: base.appendingPathComponent("mounted-folders.json"))
try! Data("x".utf8).write(to: base.appendingPathComponent(uuidFile))
try! fm.createSymbolicLink(at: base.appendingPathComponent(uuidLink), withDestinationURL: base.appendingPathComponent("shared"))
age(base, by: 2 * 86_400)
write(fresh, "attachments/second.png")          // touched just now

print("1a. What can be a session directory at all")
let names = SessionStorageCleanup.sessionDirectoryNames(minisBase: base)
check("the five UUID-named directories, sorted", Set(names) == [live, orphanA, orphanB, fresh, busy] && names == names.sorted())
check("no global folder is listed", globals.allSatisfy { !names.contains($0) })
check("a FILE with a UUID name is not a directory", !names.contains(uuidFile))
check("a SYMLINK with a UUID name is not followed or listed", !names.contains(uuidLink))
check("a missing base lists nothing", SessionStorageCleanup.sessionDirectoryNames(minisBase: base.appendingPathComponent("missing")).isEmpty)

print("1b. The orphan test")
check("a UUID name no session has is an orphan", SessionStorageCleanup.isOrphanDirectoryName(orphanA, knownSessionIds: [live]))
check("a session's own id is not", !SessionStorageCleanup.isOrphanDirectoryName(live, knownSessionIds: [live]))
check("neither is its lowercase twin (one directory on a case-insensitive volume)",
      !SessionStorageCleanup.isOrphanDirectoryName(live.lowercased(), knownSessionIds: [live])
      && !SessionStorageCleanup.isOrphanDirectoryName(live, knownSessionIds: [live.lowercased()]))
check("no non-UUID name is ever an orphan, with an empty database too",
      (globals + ["mounted-folders.json", "", "..", ".", "media"]).allSatisfy { !SessionStorageCleanup.isOrphanDirectoryName($0, knownSessionIds: []) })

print("1c. What a clean-up removes and what it leaves")
let scan = SessionStorageCleanup.orphanedSessionDirectories(among: names, minisBase: base,
                                                            knownSessionIds: [live], inUse: [busy.lowercased()])
check("the two old orphans are removable", Set(scan.removable) == [orphanA, orphanB])
check("the one changed just now waits", scan.recentlyChanged == [fresh])
check("the session with a row is in neither list", !scan.removable.contains(live) && !scan.recentlyChanged.contains(live))
check("the one in use is in neither list, matched without case", !scan.removable.contains(busy) && !scan.recentlyChanged.contains(busy))
let later = SessionStorageCleanup.orphanedSessionDirectories(among: names, minisBase: base, knownSessionIds: [live], inUse: [busy],
                                                             now: Date().addingTimeInterval(SessionStorageCleanup.orphanGracePeriod + 60))
check("after the grace period the waiting one is an ordinary orphan", Set(later.removable) == [orphanA, orphanB, fresh] && later.recentlyChanged.isEmpty)
check("the grace period is one hour", SessionStorageCleanup.orphanGracePeriod == 3600)
let emptyDB = SessionStorageCleanup.orphanedSessionDirectories(among: names, minisBase: base, knownSessionIds: [])
check("an empty id set (a database that failed to read) still cannot reach a global folder",
      Set(emptyDB.removable + emptyDB.recentlyChanged) == [live, orphanA, orphanB, fresh, busy])
let injected = SessionStorageCleanup.orphanedSessionDirectories(among: names + globals + ["..", uuidFile], minisBase: base, knownSessionIds: [live], inUse: [busy])
check("names that are not session directories are ignored even when handed in",
      globals.allSatisfy { !injected.removable.contains($0) } && !injected.removable.contains(".."))

let ghost = UUID().uuidString
let withGhost = SessionStorageCleanup.orphanedSessionDirectories(among: names + [ghost], minisBase: base, knownSessionIds: [live], inUse: [busy])
check("a directory that vanished since the listing is neither removed nor reported",
      !withGhost.removable.contains(ghost) && !withGhost.recentlyChanged.contains(ghost))
check("a directory's last change can be read (an unreadable one is left alone, see [2])",
      SessionStorageCleanup.lastChange(under: base.appendingPathComponent(orphanA)) != nil
      && SessionStorageCleanup.lastChange(under: base.appendingPathComponent(ghost)) == nil)

print("1d. A change deep inside counts")
write(orphanB, "offloads/.hidden/new.bin")
let touched = SessionStorageCleanup.orphanedSessionDirectories(among: names, minisBase: base, knownSessionIds: [live], inUse: [busy])
check("a new file in a hidden sub-folder moves the orphan to 'wait'", touched.removable == [orphanA] && Set(touched.recentlyChanged) == [orphanB, fresh])
age(base.appendingPathComponent(orphanB), by: 2 * 86_400)

print("1e. Removing")
for sid in scan.removable { _ = SessionStorageCleanup.removeSessionDirectory(sid, minisBase: base) }
check("both orphans are gone", !exists(orphanA) && !exists(orphanB))
check("the live session, the recent one and the busy one are untouched",
      exists(live + "/workspace/keep.txt") && exists(fresh + "/attachments/just-synced.png") && exists(fresh + "/attachments/second.png") && exists(busy + "/workspace/running.log"))
check("shared, skills, memory and the other non-UUID folder are untouched", globals.allSatisfy { exists($0 + "/data/file.md") })
check("loose files are untouched", exists("mounted-folders.json") && exists(uuidFile))
check("the UUID-named symlink and its target are untouched",
      (try? fm.destinationOfSymbolicLink(atPath: base.appendingPathComponent(uuidLink).path)) != nil && exists("shared/data/file.md"))
check("removal still refuses anything that is not a session id",
      !SessionStorageCleanup.removeSessionDirectory("shared", minisBase: base) && !SessionStorageCleanup.removeSessionDirectory("..", minisBase: base)
      && !SessionStorageCleanup.removeSessionDirectory("", minisBase: base) && exists("shared/data/file.md"))
let again = SessionStorageCleanup.orphanedSessionDirectories(among: SessionStorageCleanup.sessionDirectoryNames(minisBase: base),
                                                             minisBase: base, knownSessionIds: [live], inUse: [busy])
check("a second pass finds nothing to remove", again.removable.isEmpty && again.recentlyChanged == [fresh])

exit(failures == 0 ? 0 : 1)
"""#

print("1. The shipping rules against a real directory tree")
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("OrphanedSessionCleanup-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let supportFile = tmp.appendingPathComponent("support.swift")
let mainFile = tmp.appendingPathComponent("main.swift")
try? support.write(to: supportFile, atomically: true, encoding: .utf8)
try? harness.write(to: mainFile, atomically: true, encoding: .utf8)
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
print(outText, terminator: "")
check("harness ran to the end (\(outText.components(separatedBy: "✅").count - 1) checks) and exited 0",
      rc == 0 && outText.components(separatedBy: "✅").count - 1 >= 27)

// MARK: - 2. How the Storage page uses them

print("\n2. The Storage page")
let clean = block(view, "    func cleanOrphanedSessions() async -> OrphanCleanupResult? {")
let find = block(view, "    private func findOrphans(minisBase: URL, inUse: Set<String>) async -> SessionStorageCleanup.OrphanScan {")
let inUse = block(view, "    private func sessionsInUse() -> Set<String> {")
let preview = block(view, "    func previewOrphanCleanup() async -> OrphanPreview? {")
let helperScan = block(support, "    static func orphanedSessionDirectories(among names: [String], minisBase: URL,")
check("the directories are listed before the session ids are read",
      index(find, "SessionStorageCleanup.sessionDirectoryNames(minisBase: minisBase)") > 0
      && index(find, "SessionStorageCleanup.sessionDirectoryNames(minisBase: minisBase)") < index(find, "ChatStore.shared.allSessionIds()")
      && index(find, "SessionStorageCleanup.sessionDirectoryNames(minisBase: minisBase)") < index(find, "ChatStore.shared.listSessions()"))
check("ids come from the raw table AND the session list",
      find.contains("Set(await ChatStore.shared.allSessionIds())\n            .union(await ChatStore.shared.listSessions().map(\\.id))"))
check("sessions in use are protected: active, open, mounted in the shell",
      inUse.contains("var inUse = SessionActivityTracker.shared.activeSessions")
      && inUse.contains("if let open = AIChatViewModel.activeSessionId { inUse.insert(open) }")
      && inUse.contains("if let mounted = ISHExecutionCoordinator.mountedSessionIdSnapshot { inUse.insert(mounted) }")
      && find.contains("knownSessionIds: known, inUse: inUse)"))
check("the preview and the clean-up run the same scan; the clean-up scans again instead of trusting the preview",
      preview.contains("let scan = await self.findOrphans(minisBase: minisBase, inUse: inUse)")
      && clean.contains("let scan = await self.findOrphans(minisBase: minisBase, inUse: inUse)"))
check("the preview deletes nothing",
      !code(preview).contains("removeSessionDirectory") && !code(preview).contains("removeItem"))
check("only the scan's removable list is deleted, through the helper that refuses non-session names",
      clean.contains("for sid in scan.removable {")
      && clean.contains("guard SessionStorageCleanup.removeSessionDirectory(sid, minisBase: minisBase) else { continue }")
      && !code(clean).contains("removeItem") && !code(clean).contains("contentsOfDirectory"))
check("a directory whose dates cannot be read is left alone, never removed",
      helperScan.contains("guard let changed = lastChange(under: dir, fm: fm),\n                  now.timeIntervalSince(changed) >= grace else {\n                scan.recentlyChanged.append(name)\n                continue\n            }\n            scan.removable.append(name)")
      && helperScan.contains("guard fm.fileExists(atPath: dir.path) else { continue }"))
check("one clean-up at a time, and not during a scan",
      clean.contains("guard !isCleaningOrphans, !isLoading else { return nil }") && clean.contains("defer { isCleaningOrphans = false }"))
check("the orphan row and the total drop by what was measured, with no rescan",
      clean.contains("orphanedSessionSize = max(0, orphanedSessionSize - outcome.freedBytes)")
      && clean.contains("containerTotalSize = max(0, containerTotalSize - outcome.freedBytes)")
      && !code(clean).contains("load()"))
let scan = block(view, "    func load() -> Task<Void, Never> {")
check("the page's scan calls a directory orphaned by the same test the clean-up uses",
      scan.contains("} else if SessionStorageCleanup.isOrphanDirectoryName(sid, knownSessionIds: sessionIds) {\n")
      && scan.contains("orphaned += size"))
check("skills / memory / shared are their own bucket, not 'orphaned', and still add up in the total",
      scan.contains("sharedData += size")
      && scan.contains("let classified = shell + staleRootfs + db + logsCaches + tmpTotal + orphaned + sharedData + sessionsTotal")
      && view.contains("label: \"Skills, Memory & Shared Files\", value: vm.format(vm.sharedDataSize)"))
check("the button exists only while there is something to clean, and is disabled while cleaning or scanning",
      view.contains("if vm.orphanedSessionSize > 0 || vm.isCleaningOrphans {\n            Section {")
      && view.contains("Label(\"Clean Up Orphaned Session Files\", systemImage: \"trash\")")
      && view.contains(".disabled(vm.isCleaningOrphans || vm.isLoading)"))
let begin = block(view, "    private func beginOrphanCleanup() {")
check("the tap looks first: it confirms only when something is removable, with the amount that will really go",
      view.contains("Button(role: .destructive) {\n                    beginOrphanCleanup()\n                }")
      && begin.contains("guard let preview = await vm.previewOrphanCleanup() else { return }")
      && begin.contains("if preview.removableCount > 0 {\n                orphanPreview = preview\n                showCleanOrphansConfirmation = true")
      && !code(begin).contains("cleanOrphanedSessions")
      && view.contains("vm.format(orphanPreview?.removableBytes ?? 0)"))
check("deleting happens only from the confirmation's destructive button",
      view.components(separatedBy: "vm.cleanOrphanedSessions()").count - 1 == 1
      && view.contains(".alert(\"Clean Up Orphaned Session Files?\", isPresented: $showCleanOrphansConfirmation) {\n                Button(\"Clean Up\", role: .destructive) {\n                    Task { orphanCleanupResult = await vm.cleanOrphanedSessions() }"))
check("a loading state while it runs, and a result afterwards",
      view.contains("if vm.isCleaningOrphans {\n            HStack {\n                ProgressView()")
      && view.contains("Text(orphanResultMessage(result))"))
check("pull-to-refresh waits for a running clean-up",
      view.contains("guard !isSelecting, vm.processingIds.isEmpty, !vm.isCleaningOrphans else { return }"))

// Every new string has zh-Hans and zh-Hant.
let catalog = source("Localizable.xcstrings")
let keys = ["Skills, Memory & Shared Files", "Clean Up Orphaned Session Files", "Clean Up Orphaned Session Files?", "Clean Up", "Cleaning…",
            "Orphaned Session Files Cleaned", "Nothing Was Cleaned", "Freed %@.", "No orphaned session files were found.",
            "This permanently deletes %@ of files left behind by conversations that no longer exist. Your chats, skills, memory and settings are not affected.",
            "%@ changed within the last hour and was left in place in case it belongs to a conversation that is still syncing. Try again later."]
if let data = catalog.data(using: .utf8),
   let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let strings = root["strings"] as? [String: Any] {
    let missing = keys.filter { key in
        let loc = (strings[key] as? [String: Any])?["localizations"] as? [String: Any]
        return loc?["zh-Hans"] == nil || loc?["zh-Hant"] == nil
    }
    check("every new string is in the catalog with zh-Hans and zh-Hant\(missing.isEmpty ? "" : " — missing: \(missing)")", missing.isEmpty)
    check("the long footer is there too", strings.keys.contains { $0.hasPrefix("Orphaned session files were left behind by conversations that no longer exist") })
} else {
    check("the string catalog could be read", false)
}

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
