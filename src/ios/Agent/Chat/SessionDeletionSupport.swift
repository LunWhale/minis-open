import Foundation

// [T-child-delete-storage] Pure helpers behind "delete a session" and
// "how much does a session weigh": walking the parent/child tree of agent
// sessions, measuring and removing a session's on-disk directory, and
// rolling child sizes up onto their root parent. Kept free of ChatStore /
// UI so they can be unit-tested against a temp directory and a dictionary.

enum SessionTree {
    /// `roots` plus every descendant, any depth, cycle-safe. `children`
    /// returns the direct children of an id.
    static func withDescendants(_ roots: some Sequence<String>,
                                children: (String) -> [String]) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        var queue = Array(roots)
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            order.append(id)
            queue.append(contentsOf: children(id))
        }
        return order
    }

    /// Walk `parentOf` (child → parent) up to the top-level session.
    /// A dangling or cyclic parent chain resolves to the last id reached.
    static func rootId(of id: String, parentOf: [String: String]) -> String {
        var cur = id
        var seen: Set<String> = [id]
        while let p = parentOf[cur], !p.isEmpty, seen.insert(p).inserted {
            cur = p
        }
        return cur
    }

    /// Per-session byte sizes folded onto their root parent. Children are
    /// not listed separately in the result.
    static func aggregateOntoRoots(_ sizes: [String: Int64], parentOf: [String: String]) -> [String: Int64] {
        var out: [String: Int64] = [:]
        for (id, size) in sizes {
            out[rootId(of: id, parentOf: parentOf), default: 0] += size
        }
        return out
    }
}

enum SessionStorageCleanup {
    /// Only real session ids (UUID strings) name a per-session directory
    /// under `MinisChat/minis`; `shared`, `skills`, `memory` … are global
    /// buckets and must never be removed by a session delete.
    static func isSessionDirectoryName(_ name: String) -> Bool {
        UUID(uuidString: name) != nil
    }

    static func directory(for sessionId: String, minisBase: URL) -> URL {
        minisBase.appendingPathComponent(sessionId, isDirectory: true)
    }

    /// Remove `<minisBase>/<sessionId>` in full (workspace, offloads,
    /// browser, attachments, …). Idempotent; refuses non-session names.
    /// Returns true when something was removed.
    @discardableResult
    static func removeSessionDirectory(_ sessionId: String, minisBase: URL,
                                       fm: FileManager = .default) -> Bool {
        guard isSessionDirectoryName(sessionId) else { return false }
        let dir = directory(for: sessionId, minisBase: minisBase)
        guard fm.fileExists(atPath: dir.path) else { return false }
        do {
            try fm.removeItem(at: dir)
            return true
        } catch {
            return false
        }
    }

    // MARK: Orphaned session directories  [T-storage-orphan-cleanup]
    //
    // A session directory with no session row. They come from deletes by old
    // builds that removed the row but only part of the directory, from an
    // interrupted delete, and from iCloud: a SessionFile record is written to
    // `<minis>/<sessionId>/…` whether or not that session exists here, so files
    // of a session deleted on another device land with nothing to own them.
    // The Sessions list is built from the database, so these never appear in
    // it and could not be cleared from the Storage page at all.
    //
    // Removing them is the one place a storage action deletes directories the
    // user did not pick, so every rule here errs towards leaving things alone.

    /// How long after its last change an orphan is left in place. A session's
    /// files can arrive from iCloud before its row does (records are applied in
    /// arrival order), and for that window the directory looks exactly like an
    /// orphan. Real leftovers are old; waiting costs nothing.
    static let orphanGracePeriod: TimeInterval = 3600

    /// What `orphanedSessionDirectories` found.
    struct OrphanScan: Equatable {
        /// Session directories with no session: removed by a clean-up.
        var removable: [String] = []
        /// Orphans left alone for now: something in them changed within the
        /// grace period.
        var recentlyChanged: [String] = []
    }

    /// The direct children of `minisBase` that can be a session's directory:
    /// real directories (not symlinks) named by a UUID. `shared`, `skills`,
    /// `memory`, loose files and anything else are not listed, and nothing
    /// below this function ever looks at them.
    static func sessionDirectoryNames(minisBase: URL, fm: FileManager = .default) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let children = (try? fm.contentsOfDirectory(at: minisBase, includingPropertiesForKeys: keys)) ?? []
        return children.compactMap { url -> String? in
            let name = url.lastPathComponent
            guard isSessionDirectoryName(name) else { return nil }
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isDirectory == true, v?.isSymbolicLink != true else { return nil }
            return name
        }.sorted()
    }

    /// Whether a name under `minisBase` is an orphaned session directory:
    /// UUID-named, and no known session has that id. Compared without case -
    /// on a case-insensitive volume (the Mac build) `abc…` and `ABC…` are the
    /// same directory, and a lowercase twin of a live session's id must never
    /// count as an orphan. The Storage page's scan uses the same test, so what
    /// it shows as orphaned is what a clean-up may remove.
    static func isOrphanDirectoryName(_ name: String, knownSessionIds: Set<String>) -> Bool {
        guard isSessionDirectoryName(name) else { return false }
        if knownSessionIds.contains(name) { return false }
        let upper = name.uppercased()
        return !knownSessionIds.contains { $0.uppercased() == upper }
    }

    /// Sort `names` - a listing from `sessionDirectoryNames` - into what a
    /// clean-up removes and what it leaves for now.
    ///
    /// Read the session ids AFTER taking that listing, never before: a session
    /// created in between then has its id in `knownSessionIds`. The other
    /// order would list its brand-new directory against a set of ids that does
    /// not contain it yet, and delete it.
    ///
    /// `inUse` are ids the app is working with right now (the open chat, a
    /// running agent, the mounted shell session); they are skipped even with no
    /// row, since something is still writing there.
    static func orphanedSessionDirectories(among names: [String], minisBase: URL,
                                           knownSessionIds: Set<String>,
                                           inUse: Set<String> = [],
                                           now: Date = Date(),
                                           grace: TimeInterval = orphanGracePeriod,
                                           fm: FileManager = .default) -> OrphanScan {
        let inUseUpper = Set(inUse.map { $0.uppercased() })
        var scan = OrphanScan()
        for name in names where isOrphanDirectoryName(name, knownSessionIds: knownSessionIds) {
            guard !inUseUpper.contains(name.uppercased()) else { continue }
            let dir = directory(for: name, minisBase: minisBase)
            // Gone since the listing: nothing to do, and nothing to report.
            guard fm.fileExists(atPath: dir.path) else { continue }
            // A directory whose dates cannot be read is left alone, like one
            // that changed recently: "do not know" must never mean "delete".
            guard let changed = lastChange(under: dir, fm: fm),
                  now.timeIntervalSince(changed) >= grace else {
                scan.recentlyChanged.append(name)
                continue
            }
            scan.removable.append(name)
        }
        return scan
    }

    /// The newest modification date of `dir` or anything beneath it (hidden
    /// files included, symlinks not followed). nil when it cannot be read.
    static func lastChange(under dir: URL, fm: FileManager = .default) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var newest = (try? dir.resourceValues(forKeys: Set(keys)))?.contentModificationDate
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: keys, options: []) else { return newest }
        for case let url as URL in e {
            guard let d = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate else { continue }
            if newest == nil || d > newest! { newest = d }
        }
        return newest
    }

    struct Measurement: Equatable {
        var fileCount = 0
        var bytes: Int64 = 0
        var sampleNames: [String] = []
    }

    /// Regular files under each session directory: count, bytes, and the
    /// first few names (for the confirmation sheet).
    static func measure(_ sessionIds: some Sequence<String>, minisBase: URL,
                        sampleLimit: Int = 3, fm: FileManager = .default) -> Measurement {
        var m = Measurement()
        for id in sessionIds {
            let dir = directory(for: id, minisBase: minisBase)
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard v?.isRegularFile == true else { continue }
                m.fileCount += 1
                m.bytes += Int64(v?.fileSize ?? 0)
                if m.sampleNames.count < sampleLimit { m.sampleNames.append(url.lastPathComponent) }
            }
        }
        return m
    }
}

/// [T-storage-session-cache] The Storage page's per-session numbers, kept
/// current without walking the container again.
///
/// The page used to rescan the whole app container (every rootfs file) on
/// each `onAppear` — so also on the way back from a session's detail page —
/// and again after every "clear files". The full scan now runs once per visit;
/// afterwards only the directories an action touched are re-measured and
/// applied here: the row's size, the order, and the byte deltas the page adds
/// to its totals.
struct SessionStorageLedger: Equatable {
    /// One top-level session. Agent child sessions are folded in: their
    /// directories count toward the row and are cleared with it.
    struct Row: Identifiable, Equatable {
        let id: String
        let title: String?
        var minisSize: Int64 = 0
        var descendantIds: [String] = []
        var totalSize: Int64 { minisSize }
    }

    /// What one re-measure changed.
    struct Change: Equatable {
        /// New minus old bytes over the re-measured directories: what the
        /// container total moves by.
        var fileDelta: Int64 = 0
        /// Old minus new bytes, never negative: what the action released.
        var freed: Int64 = 0
        /// Bytes still on disk under directories whose row was removed. They
        /// have no row any more, so the page counts them as orphaned.
        var stranded: Int64 = 0
    }

    /// Largest first; ties by id so equal sizes keep a stable order.
    private(set) var rows: [Row] = []
    /// Bytes of each session's own directory, children listed separately.
    private(set) var directoryBytes: [String: Int64] = [:]

    init() {}

    init(rows: [Row], directoryBytes: [String: Int64]) {
        self.rows = Self.sorted(rows)
        self.directoryBytes = directoryBytes
    }

    static func sorted(_ rows: [Row]) -> [Row] {
        rows.sorted { $0.totalSize != $1.totalSize ? $0.totalSize > $1.totalSize : $0.id < $1.id }
    }

    var totalBytes: Int64 { rows.reduce(0) { $0 + $1.totalSize } }

    func row(_ id: String) -> Row? { rows.first { $0.id == id } }

    /// The directories behind `rowIds`: each row's own plus its descendants'.
    func directoryIds(of rowIds: some Sequence<String>) -> [String] {
        let wanted = Set(rowIds)
        return rows.filter { wanted.contains($0.id) }.flatMap { [$0.id] + $0.descendantIds }
    }

    /// Apply fresh sizes for the directories of `rowIds` (a directory missing
    /// from `remeasured` is gone: 0 bytes). With `removeRows` the rows leave
    /// the list (their sessions were deleted); otherwise each row takes its
    /// re-measured size and the list is re-sorted.
    @discardableResult
    mutating func apply(remeasured: [String: Int64], rowIds: some Sequence<String>, removeRows: Bool) -> Change {
        let ids = Set(rowIds)
        var change = Change()
        var released: Int64 = 0
        for dir in directoryIds(of: ids) {
            let old = directoryBytes[dir] ?? 0
            let new = remeasured[dir] ?? 0
            change.fileDelta += new - old
            released += old - new
            if removeRows {
                directoryBytes[dir] = nil
                change.stranded += new
            } else {
                directoryBytes[dir] = new
            }
        }
        change.freed = max(0, released)
        if removeRows {
            rows.removeAll { ids.contains($0.id) }
        } else {
            for i in rows.indices where ids.contains(rows[i].id) {
                rows[i].minisSize = ([rows[i].id] + rows[i].descendantIds).reduce(0) { $0 + (directoryBytes[$1] ?? 0) }
            }
            rows = Self.sorted(rows)
        }
        return change
    }
}
