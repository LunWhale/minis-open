import XCTest
@testable import Minis

// [T-child-delete-storage] Tree walking, root aggregation, and per-session
// directory measurement / removal — the helpers every delete and storage
// path relies on to cover hidden agent child sessions.
final class SessionDeletionSupportTests: XCTestCase {

    // parent → children, three levels deep plus an unrelated session.
    private let children: [String: [String]] = [
        "P": ["C1", "C2"],
        "C1": ["G1"],
        "G1": ["GG1"],
        "X": ["XC"],
    ]

    func testWithDescendantsWalksEveryLevelOnce() {
        let all = SessionTree.withDescendants(["P"]) { children[$0] ?? [] }
        XCTAssertEqual(Set(all), ["P", "C1", "C2", "G1", "GG1"])
        XCTAssertEqual(all.first, "P")
        XCTAssertEqual(all.count, 5, "no duplicates")
        XCTAssertFalse(all.contains("X"))
    }

    func testWithDescendantsIsCycleSafe() {
        let cyclic: [String: [String]] = ["A": ["B"], "B": ["A"]]
        let all = SessionTree.withDescendants(["A"]) { cyclic[$0] ?? [] }
        XCTAssertEqual(Set(all), ["A", "B"])
    }

    func testRootIdAndAggregation() {
        let parentOf = ["C1": "P", "C2": "P", "G1": "C1", "GG1": "G1", "XC": "X"]
        XCTAssertEqual(SessionTree.rootId(of: "GG1", parentOf: parentOf), "P")
        XCTAssertEqual(SessionTree.rootId(of: "P", parentOf: parentOf), "P")
        XCTAssertEqual(SessionTree.rootId(of: "Q", parentOf: ["Q": "R", "R": "Q"]), "R", "cycle resolves without hanging")

        let sizes: [String: Int64] = ["P": 100, "C1": 10, "C2": 20, "G1": 1, "GG1": 2, "X": 5, "XC": 7]
        let rolled = SessionTree.aggregateOntoRoots(sizes, parentOf: parentOf)
        XCTAssertEqual(rolled["P"], 133)
        XCTAssertEqual(rolled["X"], 12)
        XCTAssertNil(rolled["C1"], "children are folded, not listed")
        XCTAssertEqual(rolled.values.reduce(0, +), sizes.values.reduce(0, +), "totals never double-count")
    }

    func testMeasureAndRemoveCoverParentAndChildOnly() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("minis-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let parent = UUID().uuidString, child = UUID().uuidString, other = UUID().uuidString
        func write(_ sid: String, _ rel: String, bytes: Int) throws {
            let url = base.appendingPathComponent(sid).appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0xAB, count: bytes).write(to: url)
        }
        try write(parent, "workspace/report.md", bytes: 1_000)
        try write(parent, "offloads/big.bin", bytes: 5_000)
        try write(child, "workspace/notes.txt", bytes: 300)
        try write(child, "browser/shot.jpg", bytes: 700)
        try write(other, "workspace/keep.txt", bytes: 42)
        try write("shared", "docs/global.md", bytes: 9)   // global bucket

        let both = SessionStorageCleanup.measure([parent, child], minisBase: base)
        XCTAssertEqual(both.fileCount, 4)
        XCTAssertEqual(both.bytes, 7_000)
        XCTAssertEqual(both.sampleNames.count, 3)

        XCTAssertTrue(SessionStorageCleanup.removeSessionDirectory(parent, minisBase: base))
        XCTAssertTrue(SessionStorageCleanup.removeSessionDirectory(child, minisBase: base))
        XCTAssertFalse(SessionStorageCleanup.removeSessionDirectory(child, minisBase: base), "idempotent")
        XCTAssertFalse(SessionStorageCleanup.removeSessionDirectory("shared", minisBase: base), "never a global bucket")
        XCTAssertFalse(SessionStorageCleanup.removeSessionDirectory("", minisBase: base))

        XCTAssertFalse(fm.fileExists(atPath: base.appendingPathComponent(parent).path))
        XCTAssertFalse(fm.fileExists(atPath: base.appendingPathComponent(child).path))
        XCTAssertTrue(fm.fileExists(atPath: base.appendingPathComponent(other).path))
        XCTAssertTrue(fm.fileExists(atPath: base.appendingPathComponent("shared/docs/global.md").path))
        XCTAssertEqual(SessionStorageCleanup.measure([parent, child], minisBase: base), .init())
    }

    // MARK: - Orphaned session directories  [T-storage-orphan-cleanup]

    /// A `minis` base with one of everything a clean-up can meet. Everything
    /// is aged two days unless a test touches it again.
    private struct OrphanFixture {
        let fm = FileManager.default
        let base: URL
        let live = UUID().uuidString, orphanA = UUID().uuidString, orphanB = UUID().uuidString
        let fresh = UUID().uuidString, busy = UUID().uuidString
        let looseUUIDFile = UUID().uuidString, linkName = UUID().uuidString

        init() throws {
            base = fm.temporaryDirectory.appendingPathComponent("minis-orphan-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            try write(live, "workspace/keep.txt")
            try write(orphanA, "workspace/old.txt")
            try write(orphanB, "offloads/.hidden/deep.bin")
            try write(fresh, "attachments/just-synced.png")
            try write(busy, "workspace/running.log")
            for global in ["shared", "skills", "memory", "not-a-uuid"] { try write(global, "data/file.md") }
            try Data("{}".utf8).write(to: base.appendingPathComponent("mounted-folders.json"))
            try Data("x".utf8).write(to: base.appendingPathComponent(looseUUIDFile))        // a FILE with a UUID name
            try fm.createSymbolicLink(at: base.appendingPathComponent(linkName),
                                      withDestinationURL: base.appendingPathComponent("shared"))   // a LINK with a UUID name
            try age(base, by: 2 * 86_400)
        }

        func write(_ dir: String, _ rel: String) throws {
            let url = base.appendingPathComponent(dir).appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0xCD, count: 256).write(to: url)
        }

        /// Set the modification date of `root` and everything beneath it.
        func age(_ root: URL, by seconds: TimeInterval) throws {
            let then = Date().addingTimeInterval(-seconds)
            var all = [root]
            if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let url as URL in e { all.append(url) }
            }
            for url in all where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true {
                try fm.setAttributes([.modificationDate: then], ofItemAtPath: url.path)
            }
        }

        func exists(_ rel: String) -> Bool { fm.fileExists(atPath: base.appendingPathComponent(rel).path) }
        func cleanUp() { try? fm.removeItem(at: base) }
    }

    func testOnlyUUIDNamedRealDirectoriesAreSessionDirectories() throws {
        let f = try OrphanFixture()
        defer { f.cleanUp() }
        let names = SessionStorageCleanup.sessionDirectoryNames(minisBase: f.base)
        XCTAssertEqual(Set(names), [f.live, f.orphanA, f.orphanB, f.fresh, f.busy],
                       "no shared / skills / memory, no loose file, no UUID-named file, no UUID-named symlink")
        XCTAssertEqual(names, names.sorted())
        XCTAssertEqual(SessionStorageCleanup.sessionDirectoryNames(minisBase: f.base.appendingPathComponent("missing")), [])
    }

    func testOrphanNameTest() {
        let id = UUID().uuidString
        XCTAssertTrue(SessionStorageCleanup.isOrphanDirectoryName(id, knownSessionIds: []))
        XCTAssertFalse(SessionStorageCleanup.isOrphanDirectoryName(id, knownSessionIds: [id]))
        XCTAssertFalse(SessionStorageCleanup.isOrphanDirectoryName(id.lowercased(), knownSessionIds: [id]),
                       "a case twin of a live session is the same directory on a case-insensitive volume")
        XCTAssertFalse(SessionStorageCleanup.isOrphanDirectoryName(id, knownSessionIds: [id.lowercased()]))
        for global in ["shared", "skills", "memory", "mounted-folders.json", "", "..", "not-a-uuid"] {
            XCTAssertFalse(SessionStorageCleanup.isOrphanDirectoryName(global, knownSessionIds: []), global)
        }
    }

    func testOrphanScanLeavesLiveBusyAndRecentAlone() throws {
        let f = try OrphanFixture()
        defer { f.cleanUp() }
        try f.write(f.fresh, "attachments/second.png")          // touched now
        let names = SessionStorageCleanup.sessionDirectoryNames(minisBase: f.base)
        let scan = SessionStorageCleanup.orphanedSessionDirectories(
            among: names, minisBase: f.base, knownSessionIds: [f.live], inUse: [f.busy.lowercased()])
        XCTAssertEqual(Set(scan.removable), [f.orphanA, f.orphanB])
        XCTAssertEqual(scan.recentlyChanged, [f.fresh])

        // Past the grace period the fresh one is an ordinary orphan.
        let later = SessionStorageCleanup.orphanedSessionDirectories(
            among: names, minisBase: f.base, knownSessionIds: [f.live], inUse: [f.busy],
            now: Date().addingTimeInterval(SessionStorageCleanup.orphanGracePeriod + 60))
        XCTAssertEqual(Set(later.removable), [f.orphanA, f.orphanB, f.fresh])
        XCTAssertEqual(later.recentlyChanged, [])

        // A change deep inside, in a hidden folder, counts as a change.
        try f.write(f.orphanB, "offloads/.hidden/new.bin")
        let touched = SessionStorageCleanup.orphanedSessionDirectories(
            among: names, minisBase: f.base, knownSessionIds: [f.live], inUse: [f.busy])
        XCTAssertEqual(touched.removable, [f.orphanA])
        XCTAssertEqual(Set(touched.recentlyChanged), [f.orphanB, f.fresh])
    }

    func testCleaningOrphansRemovesOnlyThem() throws {
        let f = try OrphanFixture()
        defer { f.cleanUp() }
        try f.write(f.fresh, "attachments/second.png")
        let names = SessionStorageCleanup.sessionDirectoryNames(minisBase: f.base)
        let scan = SessionStorageCleanup.orphanedSessionDirectories(
            among: names, minisBase: f.base, knownSessionIds: [f.live], inUse: [f.busy])
        for sid in scan.removable {
            XCTAssertTrue(SessionStorageCleanup.removeSessionDirectory(sid, minisBase: f.base))
        }
        XCTAssertFalse(f.exists(f.orphanA))
        XCTAssertFalse(f.exists(f.orphanB))
        for kept in [f.live + "/workspace/keep.txt", f.fresh + "/attachments/just-synced.png", f.busy + "/workspace/running.log",
                     "shared/data/file.md", "skills/data/file.md", "memory/data/file.md", "not-a-uuid/data/file.md",
                     "mounted-folders.json", f.looseUUIDFile] {
            XCTAssertTrue(f.exists(kept), kept)
        }
        XCTAssertNotNil(try? f.fm.destinationOfSymbolicLink(atPath: f.base.appendingPathComponent(f.linkName).path),
                        "the UUID-named symlink is still there, and so is what it points to")
        // Nothing left to remove; a second pass is a no-op.
        let again = SessionStorageCleanup.orphanedSessionDirectories(
            among: SessionStorageCleanup.sessionDirectoryNames(minisBase: f.base),
            minisBase: f.base, knownSessionIds: [f.live], inUse: [f.busy])
        XCTAssertEqual(again.removable, [])
    }
}
