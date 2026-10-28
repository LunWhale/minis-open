import SwiftUI
import WebKit

// MARK: - View Model

private let storageLogger = AppLogger(category: "Storage")

class StorageManagementViewModel: ObservableObject {
    /// [T-child-delete-storage] A top-level session with its hidden agent
    /// children folded in (their ids, for cascading "clear files").
    typealias SessionStorage = SessionStorageLedger.Row

    /// [T-storage-session-cache] What a clear/delete on the Sessions list did.
    enum SessionAction { case clearFiles, delete }
    struct ActionResult: Equatable {
        var action: SessionAction
        var sessionCount: Int
        var freedBytes: Int64
    }

    @Published var shellContainerSize: Int64 = 0
    @Published var chatDatabaseSize: Int64 = 0
    @Published var logsAndCachesSize: Int64 = 0
    @Published var temporarySize: Int64 = 0
    @Published var orphanedSessionSize: Int64 = 0
    /// [T-storage-orphan-cleanup] Everything under MinisChat/minis that is not
    /// a session's directory: skills, memory, shared files, loose files. It
    /// used to be added to "orphaned", which made that row promise space a
    /// clean-up must never free.
    @Published var sharedDataSize: Int64 = 0
    @Published var staleRootfsSize: Int64 = 0
    @Published var otherSize: Int64 = 0
    @Published var containerTotalSize: Int64 = 0
    /// [T-storage-session-cache] Per-session sizes from the last full scan,
    /// kept current by re-measuring only what an action touched.
    @Published private(set) var ledger = SessionStorageLedger()
    @Published var isLoading = true
    /// Rows a clear/delete is working on; the list disables them meanwhile.
    @Published private(set) var processingIds: Set<String> = []
    /// Set once the first full scan starts. The model lives as long as the
    /// page (the view's @StateObject), so returning from a pushed detail page
    /// finds it set and shows the cached numbers instead of rescanning.
    private(set) var hasLoaded = false

    var sessions: [SessionStorage] { ledger.rows }

    private let fm = FileManager.default
    private let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    func format(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }

    var totalSessionSize: Int64 { ledger.totalBytes }

    // MARK: - Scanning
    //
    // [T-ios-storage-page-undercount] This page used to sum three whitelisted
    // paths — Documents/alpine-rootfs, Library/MinisChat/minis.db, and the
    // per-session dirs under Library/MinisChat/minis — and present the result as
    // if it were the app's footprint. Measured on a real device (iPhone 11,
    // 2026-08-29, cross-checked against
    // `xcrun devicectl device info files --domain-type appDataContainer`), those
    // three paths covered 573.70 MB of a 747.88 MB container: 23.3% of the user's
    // storage was invisible in-app, and the only way to see the real number was
    // iOS Settings. A user reported a ~11.7 GB discrepancy from exactly this.
    //
    // Four separate causes, all fixed here:
    //
    //  1. WHITELIST. Library/Logs, tmp/, Library/Caches, WebKit, HTTPStorages and
    //     a stranded `.alpine-rootfs-broken-*` tree were in no bucket at all. We
    //     now walk the WHOLE container (Documents + Library + tmp) and classify
    //     every file into exactly one bucket, so the buckets sum to the true
    //     total by construction rather than by hope.
    //  2. `.skipsHiddenFiles`. FileManager's enumerator skips an entire hidden
    //     SUBTREE, so a `.git` inside the shell container vanished — 18.95 MB on
    //     the test device, and a shell used for real work is full of
    //     `.git`/`.cache`/`.npm`/`.venv`. This is why "Shell Container" always
    //     read low. The option is gone; hidden files are storage too.
    //  3. LOGICAL vs ALLOCATED size. `fileSizeKey` is the logical length; iOS
    //     Settings reports blocks actually occupied. With 2,701 of 4,923 files
    //     under one 4 KB block the difference measured +1.6% — small, but it is a
    //     systematic undercount and it is free to fix by asking for
    //     `totalFileAllocatedSizeKey`.
    //  4. ORPHANS. Session dirs whose row is gone from the DB were skipped by an
    //     `if sessionIds.contains(sid)`, so they could never be seen OR cleared
    //     from this screen — an unbounded leak. They now get their own bucket.
    //
    // The residual bucket (`otherSize`) is what makes the guarantee hold: it is
    // computed as total-minus-classified, never summed independently, so anything
    // we failed to anticipate still shows up in the total instead of silently
    // disappearing. If a future release adds a new directory, this page stays
    // honest without being taught about it.

    /// One file's contribution, in the same units iOS Settings uses.
    ///
    /// Falls back logical-size → 0 rather than skipping the file: an
    /// unreadable attribute should cost us precision, never a whole entry.
    private func allocatedSize(_ values: URLResourceValues?) -> Int64 {
        if let a = values?.totalFileAllocatedSize { return Int64(a) }
        if let a = values?.fileAllocatedSize { return Int64(a) }
        if let s = values?.fileSize { return Int64(s) }
        return 0
    }

    private static let sizeKeys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
    ]

    /// Every non-directory entry under `root`, as (path relative to `root`,
    /// allocated bytes).
    ///
    /// Returns the listing instead of taking a callback so the caller's
    /// accumulators stay plain local `var`s: a closure that mutates captured vars
    /// is an error under the Swift 6 language mode, and threading `inout` state
    /// through a callback to dodge that would be harder to read than just
    /// iterating the result.
    ///
    /// Symlinks are counted at their own (tiny) size and never followed —
    /// following them would double-count `/var/minis/*`, which are symlinks into
    /// the per-session directories this same walk already visits.
    private func entries(under root: URL) -> [(rel: String, size: Int64)] {
        // Recurse explicitly, carrying the relative path DOWN as we descend,
        // instead of enumerating and deriving it from absolute paths afterwards.
        //
        // Deriving it is where this went wrong on device: `FileManager.urls(for:)`
        // hands back `/var/mobile/…`, while `FileManager.enumerator` yields the
        // resolved `/private/var/mobile/…`. Stripping the root as a string prefix
        // therefore matched nothing and every `rel` stayed absolute — so no
        // `hasPrefix("MinisChat/…")` test fired, every category rendered
        // "0 bytes", and the entire 736 MB container landed in the residual
        // bucket. Counting path COMPONENTS instead has the same defect (the
        // resolved form is one component longer), and anchoring on the root's
        // directory NAME breaks whenever a nested directory repeats it.
        //
        // Building each child from its parent sidesteps the whole class of bug:
        // the relative path is constructed, never parsed, so no prefix form can
        // affect it. Verified against a fixture containing a nested directory
        // named identically to the root.
        //
        // Symlinks are counted at their own (tiny) size and never followed —
        // following them would double-count `/var/minis/*`, which point into the
        // per-session directories this walk already visits.
        var out: [(rel: String, size: Int64)] = []
        var stack: [(dir: URL, prefix: String)] = [(root, "")]
        while let (dir, prefix) = stack.popLast() {
            let kids = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: Self.sizeKeys,
                options: []      // NOT .skipsHiddenFiles — see (2) above
            )) ?? []
            for kid in kids {
                let name = kid.lastPathComponent
                let rel = prefix.isEmpty ? name : prefix + "/" + name
                let v = try? kid.resourceValues(forKeys: Set(Self.sizeKeys))
                // Descend into real directories only. `isDirectory` is true for a
                // symlink POINTING at a directory too, and `/var/minis/*` are
                // exactly that — following them would re-walk the per-session
                // trees (double-counting them) and, for any link that points at
                // an ancestor, never terminate.
                if v?.isDirectory == true, v?.isSymbolicLink != true {
                    stack.append((kid, rel))
                } else {
                    out.append((rel, allocatedSize(v)))
                }
            }
        }
        return out
    }

    @Published var isClearingLogsAndCaches = false

    /// [T-storage-clear-logs-caches] "Logs & Caches" used to be display-only:
    /// users could see it grow but had nothing on this screen to reclaim it.
    ///
    /// Deliberately NOT a blind wipe of Library/Caches. On device it holds
    /// `InputAttachments` (attachments sitting in an unsent composer draft),
    /// CloudKit's and the system's own caches, and URLCache/WebKit stores that
    /// are open while the app runs. So:
    ///   * all logs (daily + crash) via LoggingManager, which also drops the
    ///     open file handle so logging continues into a fresh file;
    ///   * URLCache and WebKit's disk/fetch caches through their own APIs
    ///     (cookies, local storage and logins are other data types and stay);
    ///   * the app's own regenerable caches (`com.openminis.app.*`: model
    ///     lists, models.dev), which are refetched on demand.
    @MainActor
    func clearLogsAndCaches() async {
        guard !isClearingLogsAndCaches else { return }
        isClearingLogsAndCaches = true
        defer { isClearingLogsAndCaches = false }

        LoggingManager.shared.deleteAllLogs()
        URLCache.shared.removeAllCachedResponses()
        await WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeFetchCache],
            modifiedSince: .distantPast)
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let children = (try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? []
            for url in children where url.lastPathComponent.hasPrefix("com.openminis.app.") {
                try? fm.removeItem(at: url)
            }
        }.value
        load()
    }

    /// [T-storage-session-cache] The page's `onAppear` entry: a full scan the
    /// first time only. `onAppear` also fires when a pushed session detail
    /// page is popped, and each of those used to rescan the whole container.
    func loadIfNeeded() {
        guard !hasLoaded else { return }
        load()
    }

    /// Full scan of the container. Runs on the first appearance, on
    /// pull-to-refresh, and after "Clear Logs & Caches" — never after a
    /// session action, which re-measures only its own directories.
    @discardableResult
    func load() -> Task<Void, Never> {
        hasLoaded = true
        isLoading = true
        return Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let started = Date()

            let libraryURL = self.fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
            let documentsURL = self.fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            let tmpURL = self.fm.temporaryDirectory

            let chatSessions = await ChatStore.shared.listSessions()
            let sessionIds = Set(chatSessions.map(\.id))
            // [T-child-delete-storage] child → parent, to fold agent child
            // sessions onto their root parent's row.
            let parentOf: [String: String] = Dictionary(uniqueKeysWithValues:
                chatSessions.compactMap { s in s.parentSessionId.flatMap { p in p.isEmpty ? nil : (s.id, p) } })

            var shell: Int64 = 0
            var staleRootfs: Int64 = 0
            var db: Int64 = 0
            var logsCaches: Int64 = 0
            var tmpTotal: Int64 = 0
            var orphaned: Int64 = 0
            var sharedData: Int64 = 0
            var minisSizes: [String: Int64] = [:]
            var total: Int64 = 0

            // ---- Documents ----------------------------------------------------
            // alpine-rootfs is the live shell; `.alpine-rootfs-broken-<stamp>` is a
            // tree RootfsManager could neither delete nor reuse and moved aside.
            // Each occurrence leaves a full rootfs copy behind, so it gets its own
            // line rather than being folded into "other".
            for (rel, size) in self.entries(under: documentsURL) {
                total += size
                if rel.hasPrefix("alpine-rootfs/") || rel == "alpine-rootfs" {
                    shell += size
                } else if rel.hasPrefix(".alpine-rootfs-broken-") {
                    staleRootfs += size
                }
                // anything else in Documents falls through to `other`
            }

            // ---- Library ------------------------------------------------------
            for (rel, size) in self.entries(under: libraryURL) {
                total += size
                if rel.hasPrefix("MinisChat/minis/") {
                    // Library/MinisChat/minis/<sessionId>/…
                    let parts = rel.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false)
                    guard parts.count >= 3 else { continue }
                    let sid = String(parts[2])
                    if sessionIds.contains(sid) {
                        minisSizes[sid, default: 0] += size
                    } else if SessionStorageCleanup.isOrphanDirectoryName(sid, knownSessionIds: sessionIds) {
                        // A session's directory with no DB row: invisible in the
                        // sessions list, which is built from the DB. The same
                        // test `cleanOrphanedSessions` removes by, so this row
                        // is exactly what that button can free.
                        orphaned += size
                    } else {
                        // [T-storage-orphan-cleanup] skills / memory / shared /
                        // loose files: in use, not orphaned, never cleaned.
                        sharedData += size
                    }
                } else if rel.hasPrefix("MinisChat/minis.db") {
                    // Covers minis.db plus its -wal / -shm siblings, which are as
                    // much "the database" as the main file is and can be large
                    // mid-transaction.
                    db += size
                } else if rel.hasPrefix("Logs/") || rel.hasPrefix("Caches/") {
                    logsCaches += size
                }
            }

            // ---- tmp ----------------------------------------------------------
            for (_, size) in self.entries(under: tmpURL) {
                total += size
                tmpTotal += size
            }

            // Rows: top-level sessions only; each carries its own files plus
            // every descendant's. The global total below still sums raw
            // per-directory sizes once, so nothing is counted twice.
            let rolledUp = SessionTree.aggregateOntoRoots(minisSizes, parentOf: parentOf)
            var childrenOf: [String: [String]] = [:]
            for (c, p) in parentOf { childrenOf[p, default: []].append(c) }
            let rows: [SessionStorage] = chatSessions
                .filter { !$0.isChild }
                .map { session in
                    SessionStorage(
                        id: session.id,
                        title: session.title,
                        minisSize: rolledUp[session.id] ?? 0,
                        descendantIds: Array(SessionTree.withDescendants([session.id]) { childrenOf[$0] ?? [] }.dropFirst())
                    )
                }
            let ledger = SessionStorageLedger(rows: rows, directoryBytes: minisSizes)

            let sessionsTotal = minisSizes.values.reduce(0, +)
            let classified = shell + staleRootfs + db + logsCaches + tmpTotal + orphaned + sharedData + sessionsTotal
            // Residual, never negative: a file counted into two buckets would
            // otherwise render as a nonsensical negative "Other".
            let other = max(0, total - classified)

            // Snapshot into immutable bindings before the hop. Capturing the
            // accumulator `var`s directly is an error under the Swift 6 language
            // mode, and the values are final at this point anyway.
            let finalShell = shell, finalStale = staleRootfs, finalDB = db
            let finalLogs = logsCaches, finalTmp = tmpTotal, finalOrphaned = orphaned
            let finalShared = sharedData
            let finalTotal = total
            storageLogger.info("📦 [Storage] full scan: \(rows.count) sessions, \(finalTotal) bytes in \(Int(Date().timeIntervalSince(started) * 1000))ms")

            await MainActor.run {
                self.shellContainerSize = finalShell
                self.staleRootfsSize = finalStale
                self.chatDatabaseSize = finalDB
                self.logsAndCachesSize = finalLogs
                self.temporarySize = finalTmp
                self.orphanedSessionSize = finalOrphaned
                self.sharedDataSize = finalShared
                self.otherSize = other
                self.containerTotalSize = finalTotal
                self.ledger = ledger
                self.isLoading = false
            }
        }
    }

    // MARK: - Session actions ([T-storage-session-cache])

    private var minisBaseURL: URL {
        fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MinisChat/minis", isDirectory: true)
    }

    /// Allocated bytes under one session directory, counted exactly as the
    /// full scan counts them, so an incremental update and a rescan agree.
    private func directorySize(_ sessionId: String) -> Int64 {
        entries(under: SessionStorageCleanup.directory(for: sessionId, minisBase: minisBaseURL))
            .reduce(0) { $0 + $1.size }
    }

    /// minis.db with its -wal / -shm siblings, as the full scan buckets it.
    private func databaseSize() -> Int64 {
        let dir = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MinisChat", isDirectory: true)
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Self.sizeKeys)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("minis.db") }
            .reduce(0) { $0 + allocatedSize(try? $1.resourceValues(forKeys: Set(Self.sizeKeys))) }
    }

    /// Clear the files of, or delete, the sessions behind `rowIds`, then
    /// re-measure only their directories (and the database after a delete):
    /// the rows update or leave, the list re-sorts, and the totals move by
    /// the measured difference. No other session is rescanned.
    @MainActor
    @discardableResult
    func perform(_ action: SessionAction, on rowIds: [String]) async -> ActionResult? {
        let ids = rowIds.filter { ledger.row($0) != nil && !processingIds.contains($0) }
        guard !ids.isEmpty, !isLoading else { return nil }
        processingIds.formUnion(ids)
        defer { processingIds.subtract(ids) }

        let directories = ledger.directoryIds(of: ids)
        let minisBase = minisBaseURL
        switch action {
        case .clearFiles:
            await Task.detached(priority: .userInitiated) {
                for sid in directories {
                    SessionStorageCleanup.removeSessionDirectory(sid, minisBase: minisBase)
                }
            }.value
        case .delete:
            // The sidebar's delete funnel: stop agents and drop in-memory
            // state, then the store removes rows, children and directories.
            await ContentView.tearDownForDeletion(Set(ids))
            for id in ids { await ChatStore.shared.deleteSession(id) }
            // With descendants: an agent child can be the open conversation too.
            NotificationCenter.default.post(name: .sessionsDeletedElsewhere, object: nil, userInfo: ["ids": directories])
        }

        let started = Date()
        let measured = await Task.detached(priority: .userInitiated) { [weak self] () -> (sizes: [String: Int64], db: Int64?) in
            guard let self else { return ([:], nil) }
            var sizes: [String: Int64] = [:]
            for sid in directories { sizes[sid] = self.directorySize(sid) }
            return (sizes, action == .delete ? self.databaseSize() : nil)
        }.value

        let change = ledger.apply(remeasured: measured.sizes, rowIds: ids, removeRows: action == .delete)
        var totalDelta = change.fileDelta
        if let db = measured.db {
            totalDelta += db - chatDatabaseSize
            chatDatabaseSize = db
        }
        orphanedSessionSize += change.stranded
        containerTotalSize = max(0, containerTotalSize + totalDelta)
        storageLogger.info("📦 [Storage] incremental \(action == .delete ? "delete" : "clear"): \(ids.count) sessions, re-measured \(directories.count) dirs in \(Int(Date().timeIntervalSince(started) * 1000))ms, freed \(change.freed) bytes, total Δ \(totalDelta)")
        return ActionResult(action: action, sessionCount: ids.count, freedBytes: change.freed)
    }

    // MARK: - Orphaned session files ([T-storage-orphan-cleanup])

    /// What `cleanOrphanedSessions` did.
    struct OrphanCleanupResult: Equatable {
        /// Orphaned session directories removed.
        var removedCount: Int
        var freedBytes: Int64
        /// Orphans left in place because they changed within the grace period.
        var keptCount: Int
        var keptBytes: Int64
    }

    @Published var isCleaningOrphans = false

    /// What a clean-up would do right now, for the confirmation: the amount it
    /// shows is what will really be deleted, not the whole orphan row (part of
    /// which may be waiting out the grace period).
    struct OrphanPreview: Equatable {
        var removableCount: Int
        var removableBytes: Int64
        var keptCount: Int
        var keptBytes: Int64
    }

    /// Ids the app is working with right now: never cleaned, row or no row.
    @MainActor
    private func sessionsInUse() -> Set<String> {
        var inUse = SessionActivityTracker.shared.activeSessions
        if let open = AIChatViewModel.activeSessionId { inUse.insert(open) }
        if let mounted = ISHExecutionCoordinator.mountedSessionIdSnapshot { inUse.insert(mounted) }
        return inUse
    }

    /// The orphan scan both the preview and the clean-up run. The order is the
    /// safety rule: list the directories FIRST, read the session ids AFTER. A
    /// session created in between is then in the id set; the other order
    /// would list its new directory against ids that do not contain it yet.
    /// Ids come from both the raw `sessions` table and the session list, so a
    /// row either of them knows protects its directory.
    private func findOrphans(minisBase: URL, inUse: Set<String>) async -> SessionStorageCleanup.OrphanScan {
        let names = SessionStorageCleanup.sessionDirectoryNames(minisBase: minisBase)
        let known = Set(await ChatStore.shared.allSessionIds())
            .union(await ChatStore.shared.listSessions().map(\.id))
        return SessionStorageCleanup.orphanedSessionDirectories(
            among: names, minisBase: minisBase, knownSessionIds: known, inUse: inUse)
    }

    /// Look, delete nothing. nil while a scan or a clean-up is running.
    @MainActor
    func previewOrphanCleanup() async -> OrphanPreview? {
        guard !isCleaningOrphans, !isLoading else { return nil }
        isCleaningOrphans = true
        defer { isCleaningOrphans = false }
        let minisBase = minisBaseURL
        let inUse = sessionsInUse()
        return await Task.detached(priority: .userInitiated) { [weak self] () -> OrphanPreview in
            var preview = OrphanPreview(removableCount: 0, removableBytes: 0, keptCount: 0, keptBytes: 0)
            guard let self else { return preview }
            let scan = await self.findOrphans(minisBase: minisBase, inUse: inUse)
            preview.removableCount = scan.removable.count
            preview.keptCount = scan.recentlyChanged.count
            for sid in scan.removable { preview.removableBytes += self.directorySize(sid) }
            for sid in scan.recentlyChanged { preview.keptBytes += self.directorySize(sid) }
            return preview
        }.value
    }

    /// Remove the session directories that no session owns - "Orphaned Session
    /// Files". They have no row in the database, so they are missing from the
    /// Sessions list below and nothing else on this page could clear them; a
    /// user with 126 MB of them had reinstalling as the only way out.
    ///
    /// Which directories qualify is decided by SessionStorageCleanup (UUID-named
    /// real directories only; `shared`, `skills`, `memory` are never listed)
    /// and by `findOrphans` above, run again here: the preview the user
    /// confirmed is not trusted, what is removed is what is orphaned NOW.
    /// Sessions in use are skipped even without a row, and so is anything
    /// changed within `orphanGracePeriod` (see there).
    ///
    /// The totals move by what was measured before and after: no full rescan.
    @MainActor
    @discardableResult
    func cleanOrphanedSessions() async -> OrphanCleanupResult? {
        guard !isCleaningOrphans, !isLoading else { return nil }
        isCleaningOrphans = true
        defer { isCleaningOrphans = false }

        let minisBase = minisBaseURL
        let inUse = sessionsInUse()

        let started = Date()
        let outcome = await Task.detached(priority: .userInitiated) { [weak self] () -> OrphanCleanupResult in
            guard let self else { return OrphanCleanupResult(removedCount: 0, freedBytes: 0, keptCount: 0, keptBytes: 0) }
            let scan = await self.findOrphans(minisBase: minisBase, inUse: inUse)
            var result = OrphanCleanupResult(removedCount: 0, freedBytes: 0, keptCount: scan.recentlyChanged.count, keptBytes: 0)
            for sid in scan.removable {
                let before = self.directorySize(sid)
                guard SessionStorageCleanup.removeSessionDirectory(sid, minisBase: minisBase) else { continue }
                result.removedCount += 1
                result.freedBytes += max(0, before - self.directorySize(sid))
            }
            for sid in scan.recentlyChanged { result.keptBytes += self.directorySize(sid) }
            return result
        }.value

        // The scan's orphan bucket and these measurements count the same files
        // the same way, so the row drops by exactly what was removed.
        orphanedSessionSize = max(0, orphanedSessionSize - outcome.freedBytes)
        containerTotalSize = max(0, containerTotalSize - outcome.freedBytes)
        storageLogger.info("📦 [Storage] orphan clean-up: removed \(outcome.removedCount) dirs, freed \(outcome.freedBytes) bytes, kept \(outcome.keptCount) recently changed (\(outcome.keptBytes) bytes), in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return outcome
    }
}

// MARK: - Storage Management View

struct StorageManagementView: View {
    @StateObject private var vm = StorageManagementViewModel()
    @State private var showClearLogsConfirmation = false
    // [T-storage-session-cache] Multi-select on the Sessions list, Mail-style:
    // "Select" in the navigation bar, tap rows to tick them, act from the bar
    // at the bottom.
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var pendingAction: PendingSessionAction?
    @State private var actionResult: StorageManagementViewModel.ActionResult?
    // [T-storage-orphan-cleanup]
    @State private var showCleanOrphansConfirmation = false
    @State private var orphanPreview: StorageManagementViewModel.OrphanPreview?
    @State private var orphanCleanupResult: StorageManagementViewModel.OrphanCleanupResult?

    /// A clear/delete waiting for its confirmation.
    struct PendingSessionAction: Identifiable {
        let id = UUID()
        let action: StorageManagementViewModel.SessionAction
        let sessionIds: [String]
        let bytes: Int64
    }

    /// [T-storage-orphan-cleanup] The page plus the two alerts of the orphan
    /// clean-up. They hang here and not on `storageContent`'s own chain: with
    /// five alerts on one expression the type checker gave up on it.
    var body: some View {
        storageContent
            .alert("Clean Up Orphaned Session Files?", isPresented: $showCleanOrphansConfirmation) {
                Button("Clean Up", role: .destructive) {
                    Task { orphanCleanupResult = await vm.cleanOrphanedSessions() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(orphanConfirmationMessage)
            }
            .alert(orphanCleanupResult.map(orphanResultTitle) ?? "", isPresented: Binding(
                get: { orphanCleanupResult != nil },
                set: { if !$0 { orphanCleanupResult = nil } }
            ), presenting: orphanCleanupResult) { _ in
                Button("OK", role: .cancel) { }
            } message: { result in
                Text(orphanResultMessage(result))
            }
    }

    private var storageContent: some View {
        List {
            Section {
                storageRow(icon: "terminal", color: .gray, label: "Shell Container", value: vm.format(vm.shellContainerSize))
                storageRow(icon: "cylinder", color: .blue, label: "Chat Database", value: vm.format(vm.chatDatabaseSize))
                storageRow(icon: "doc", color: .indigo, label: "Session Files", value: vm.format(vm.totalSessionSize))
                storageRow(icon: "doc.text", color: .orange, label: "Logs & Caches", value: vm.format(vm.logsAndCachesSize))
                storageRow(icon: "clock", color: .teal, label: "Temporary Files", value: vm.format(vm.temporarySize))
                conditionalOverviewRows
                storageRow(icon: "ellipsis", color: .gray, label: "Other", value: vm.format(vm.otherSize))
                HStack {
                    Text("Total")
                        .fontWeight(.semibold)
                    Spacer()
                    Text(vm.format(vm.containerTotalSize))
                        .fontWeight(.semibold)
                }
            } header: {
                Text("Overview")
            } footer: {
                Text("Total is the app's full container size and should match the figure iOS Settings shows for Minis. \"Other\" covers everything not itemized above, so the categories always add up to the total.")
            }

            // [T-storage-clear-logs-caches]
            Section {
                Button(role: .destructive) {
                    showClearLogsConfirmation = true
                } label: {
                    HStack {
                        if vm.isClearingLogsAndCaches {
                            ProgressView()
                                .controlSize(.small)
                            Text("Clearing…")
                        } else {
                            Label("Clear Logs & Caches", systemImage: "trash")
                        }
                    }
                }
                .disabled(vm.isClearingLogsAndCaches)
            } footer: {
                Text("Deletes all logs, including crash reports, and cached data such as model lists and web page caches. Logs older than 15 days are also deleted automatically. Chats, files and settings are not affected.")
            }

            orphanCleanupSection

            Section("Sessions") {
                if vm.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if vm.sessions.isEmpty {
                    Text("No sessions")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.sessions) { session in
                        sessionRow(session)
                    }
                }
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        // [T-storage-session-cache] Scan once per visit: onAppear fires again
        // when a session's detail page is popped, and that used to rescan
        // the whole container. Pull to refresh forces a full rescan.
        .onAppear { vm.loadIfNeeded() }
        .refreshable {
            guard !isSelecting, vm.processingIds.isEmpty, !vm.isCleaningOrphans else { return }
            await vm.load().value
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isSelecting || (!vm.isLoading && !vm.sessions.isEmpty) {
                    Button(isSelecting ? AppLocalized("Done") : AppLocalized("Select")) {
                        withAnimation {
                            isSelecting.toggle()
                            selection = []
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting { selectionBar }
        }
        .onChange(of: vm.sessions.map(\.id)) { ids in
            // Rows removed by a delete leave the selection too.
            selection.formIntersection(ids)
        }
        .alert(pendingAction.map(confirmationTitle) ?? "", isPresented: Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        ), presenting: pendingAction) { pending in
            Button(pending.action == .delete ? AppLocalized("Delete") : AppLocalized("Clear \(vm.format(pending.bytes))"), role: .destructive) {
                run(pending)
            }
            Button("Cancel", role: .cancel) { }
        } message: { pending in
            Text(confirmationMessage(pending))
        }
        .alert(actionResult.map(resultTitle) ?? "", isPresented: Binding(
            get: { actionResult != nil },
            set: { if !$0 { actionResult = nil } }
        ), presenting: actionResult) { _ in
            Button("OK", role: .cancel) { }
        } message: { result in
            Text(resultMessage(result))
        }
        .alert("Clear Logs & Caches?", isPresented: $showClearLogsConfirmation) {
            Button("Clear", role: .destructive) {
                Task { await vm.clearLogsAndCaches() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Crash reports are deleted too, so send any you need first. Chats, files and settings are not affected.")
        }
    }

    /// The overview rows that only exist when non-zero. Split out of `body`:
    /// with a third conditional row the type checker gave up on the section.
    @ViewBuilder
    private var conditionalOverviewRows: some View {
        // Only shown when non-zero: these two are failure residue, and a
        // permanent "0 bytes" row would read as a normal part of the app.
        if vm.orphanedSessionSize > 0 {
            storageRow(icon: "questionmark.folder", color: .brown, label: "Orphaned Session Files", value: vm.format(vm.orphanedSessionSize))
        }
        if vm.staleRootfsSize > 0 {
            storageRow(icon: "exclamationmark.triangle", color: .red, label: "Stale Shell Leftovers", value: vm.format(vm.staleRootfsSize))
        }
        // [T-storage-orphan-cleanup] Was folded into "orphaned".
        if vm.sharedDataSize > 0 {
            storageRow(icon: "square.stack.3d.up", color: .purple, label: "Skills, Memory & Shared Files", value: vm.format(vm.sharedDataSize))
        }
    }

    // MARK: Orphaned session files ([T-storage-orphan-cleanup])

    /// Only while there is something to clean (or a clean-up is running): like
    /// the overview row, a permanent button would read as a normal part of the
    /// app. Its own property, with the label split out below: inline in `body`
    /// the type checker gave up on the expression.
    @ViewBuilder
    private var orphanCleanupSection: some View {
        if vm.orphanedSessionSize > 0 || vm.isCleaningOrphans {
            Section {
                Button(role: .destructive) {
                    beginOrphanCleanup()
                } label: {
                    orphanCleanupLabel
                }
                .disabled(vm.isCleaningOrphans || vm.isLoading)
            } footer: {
                Text("Orphaned session files were left behind by conversations that no longer exist, for example ones deleted by an older version of the app or on another device. They are not in the list below. Cleaning them up does not touch your chats, skills, memory or shared files.")
            }
        }
    }

    /// Look first, then ask: the confirmation names what will really be
    /// deleted. With nothing removable right now there is nothing to confirm,
    /// so the explanation is shown directly.
    private func beginOrphanCleanup() {
        Task {
            guard let preview = await vm.previewOrphanCleanup() else { return }
            if preview.removableCount > 0 {
                orphanPreview = preview
                showCleanOrphansConfirmation = true
            } else {
                orphanCleanupResult = .init(removedCount: 0, freedBytes: 0,
                                            keptCount: preview.keptCount, keptBytes: preview.keptBytes)
            }
        }
    }

    @ViewBuilder
    private var orphanCleanupLabel: some View {
        if vm.isCleaningOrphans {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Cleaning…")
            }
        } else {
            HStack {
                Label("Clean Up Orphaned Session Files", systemImage: "trash")
                Spacer()
                Text(vm.format(vm.orphanedSessionSize))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Sessions list ([T-storage-session-cache])

    @ViewBuilder
    private func sessionRow(_ session: StorageManagementViewModel.SessionStorage) -> some View {
        let busy = vm.processingIds.contains(session.id)
        if isSelecting {
            let selected = selection.contains(session.id)
            Button {
                if selected { selection.remove(session.id) } else { selection.insert(session.id) }
            } label: {
                HStack {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .font(.title3)
                    sessionLabel(session, busy: busy)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
        } else {
            NavigationLink {
                SessionStorageDetailView(sessionId: session.id, fallback: session, vm: vm)
            } label: {
                sessionLabel(session, busy: busy)
            }
            .disabled(busy)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // Not `role: .destructive`: that animates the row away before
                // the confirmation is answered.
                Button {
                    confirm(.delete, [session.id])
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
                Button {
                    confirm(.clearFiles, [session.id])
                } label: {
                    Label("Clear Files", systemImage: "xmark.bin")
                }
                .tint(.orange)
                .disabled(session.totalSize == 0)
            }
        }
    }

    private func sessionLabel(_ session: StorageManagementViewModel.SessionStorage, busy: Bool) -> some View {
        HStack {
            Text(session.title ?? "Untitled")
                .lineLimit(1)
                .foregroundStyle(.primary)
            Spacer()
            if busy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(vm.format(session.totalSize))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectionBar: some View {
        let allIds = vm.sessions.map(\.id)
        let allSelected = !allIds.isEmpty && selection.count == allIds.count
        let selectedBytes = vm.sessions.filter { selection.contains($0.id) }.reduce(Int64(0)) { $0 + $1.totalSize }
        return VStack(spacing: 0) {
            Divider()
            HStack {
                Button(allSelected ? AppLocalized("Deselect All") : AppLocalized("Select All")) {
                    selection = allSelected ? [] : Set(allIds)
                }
                Spacer()
                Button {
                    confirm(.clearFiles, Array(selection))
                } label: {
                    Text("Clear Files")
                }
                .disabled(selection.isEmpty || selectedBytes == 0 || !vm.processingIds.isEmpty)
                Spacer()
                Button(role: .destructive) {
                    confirm(.delete, Array(selection))
                } label: {
                    Text("Delete")
                }
                .disabled(selection.isEmpty || !vm.processingIds.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            if !selection.isEmpty {
                Text("\(selection.count) selected · \(vm.format(selectedBytes))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
        .background(.bar)
    }

    private func confirm(_ action: StorageManagementViewModel.SessionAction, _ ids: [String]) {
        let rows = vm.sessions.filter { ids.contains($0.id) }
        guard !rows.isEmpty else { return }
        pendingAction = PendingSessionAction(action: action, sessionIds: rows.map(\.id),
                                             bytes: rows.reduce(0) { $0 + $1.totalSize })
    }

    private func run(_ pending: PendingSessionAction) {
        Task { @MainActor in
            guard let result = await vm.perform(pending.action, on: pending.sessionIds) else { return }
            if isSelecting {
                selection.subtract(pending.sessionIds)
                if vm.sessions.isEmpty { isSelecting = false }
            }
            actionResult = result
        }
    }

    private func confirmationTitle(_ pending: PendingSessionAction) -> String {
        let n = pending.sessionIds.count
        switch pending.action {
        case .clearFiles: return n == 1 ? AppLocalized("Clear Session Files?") : AppLocalized("Clear Files of \(n) Sessions?")
        case .delete: return n == 1 ? AppLocalized("Delete Session?") : AppLocalized("Delete \(n) Sessions?")
        }
    }

    private func confirmationMessage(_ pending: PendingSessionAction) -> String {
        let size = vm.format(pending.bytes)
        switch pending.action {
        case .clearFiles: return AppLocalized("This will delete \(size) of files. This action cannot be undone.")
        case .delete: return AppLocalized("The conversations and \(size) of their files will be deleted. This action cannot be undone.")
        }
    }

    // [T-storage-orphan-cleanup]
    private var orphanConfirmationMessage: String {
        AppLocalized("This permanently deletes \(vm.format(orphanPreview?.removableBytes ?? 0)) of files left behind by conversations that no longer exist. Your chats, skills, memory and settings are not affected.")
    }

    private func orphanResultTitle(_ result: StorageManagementViewModel.OrphanCleanupResult) -> String {
        result.removedCount > 0 ? AppLocalized("Orphaned Session Files Cleaned") : AppLocalized("Nothing Was Cleaned")
    }

    private func orphanResultMessage(_ result: StorageManagementViewModel.OrphanCleanupResult) -> String {
        var parts: [String] = []
        if result.removedCount > 0 {
            parts.append(AppLocalized("Freed \(vm.format(result.freedBytes))."))
        }
        if result.keptCount > 0 {
            // Why the row may still show something right after a clean-up.
            parts.append(AppLocalized("\(vm.format(result.keptBytes)) changed within the last hour and was left in place in case it belongs to a conversation that is still syncing. Try again later."))
        }
        if parts.isEmpty {
            parts.append(AppLocalized("No orphaned session files were found."))
        }
        return parts.joined(separator: " ")
    }

    private func resultTitle(_ result: StorageManagementViewModel.ActionResult) -> String {
        result.action == .delete ? AppLocalized("Sessions Deleted") : AppLocalized("Files Cleared")
    }

    private func resultMessage(_ result: StorageManagementViewModel.ActionResult) -> String {
        let size = vm.format(result.freedBytes)
        let n = result.sessionCount
        switch result.action {
        case .clearFiles:
            return n == 1 ? AppLocalized("Cleared the session's files, freeing \(size).")
                : AppLocalized("Cleared the files of \(n) sessions, freeing \(size).")
        case .delete:
            return n == 1 ? AppLocalized("Deleted the session, freeing \(size).")
                : AppLocalized("Deleted \(n) sessions, freeing \(size).")
        }
    }

    private func storageRow(icon: String, color: Color, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(.white)
                .frame(width: 21, height: 21)
                .background(color, in: Circle())
            // [T-storage-orphan-cleanup] `Text(label)` with a String shows the
            // key itself: every overview row was English in every language,
            // although all of them are in the catalog.
            Text(AppLocalized(String.LocalizationValue(label)))
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Session Storage Detail View

struct SessionStorageDetailView: View {
    let sessionId: String
    /// The row as it was when the page was pushed; shown if the row leaves
    /// the list while this page is open.
    let fallback: StorageManagementViewModel.SessionStorage
    /// [T-storage-session-cache] The list's model: this page reads the cached
    /// row and clears through it, so the list is updated in place (size,
    /// order, totals) and popping back needs no rescan.
    @ObservedObject var vm: StorageManagementViewModel

    @State private var showClearConfirmation = false

    private var session: StorageManagementViewModel.SessionStorage { vm.ledger.row(sessionId) ?? fallback }
    private var currentMinisSize: Int64 { session.minisSize }
    private var isClearing: Bool { vm.processingIds.contains(sessionId) }

    private let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    private var minisURL: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return lib.appendingPathComponent("MinisChat/minis/\(session.id)", isDirectory: true)
    }

    private var totalFileSize: Int64 { currentMinisSize }
    private var hasFiles: Bool { totalFileSize > 0 }

    var body: some View {
        List {
            Section("Minis Files") {
                if currentMinisSize > 0 {
                    NavigationLink {
                        FileBrowserView(rootPath: minisURL)
                    } label: {
                        HStack {
                            Label("Browse Files", systemImage: "folder")
                            Spacer()
                            Text(formatter.string(fromByteCount: currentMinisSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("No minis files")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    HStack {
                        if isClearing {
                            ProgressView()
                                .controlSize(.small)
                            Text("Clearing…")
                        } else {
                            Label("Clear Session Files", systemImage: "trash")
                        }
                        Spacer()
                        if !isClearing {
                            Text(formatter.string(fromByteCount: totalFileSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!hasFiles || isClearing)
            } footer: {
                Text("Removes all files generated by this session. The conversation itself will be preserved.")
            }
        }
        .navigationTitle(session.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Clear Session Files?", isPresented: $showClearConfirmation) {
            Button("Clear \(formatter.string(fromByteCount: totalFileSize))", role: .destructive) {
                clearFiles()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will delete \(formatter.string(fromByteCount: totalFileSize)) of files. This action cannot be undone.")
        }
    }

    private func clearFiles() {
        // [T-child-delete-storage] The row aggregates its agent children, so
        // this clears their directories too; only those are re-measured.
        Task { @MainActor in
            await vm.perform(.clearFiles, on: [sessionId])
        }
    }
}
