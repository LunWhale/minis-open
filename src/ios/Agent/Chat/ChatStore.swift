//
//  ChatStore.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore - the SQLite-backed store (an actor) for chat sessions, messages,
//  folders, media and compaction markers, plus the bookkeeping iCloud sync
//  and backup restore need.
//
//  Map of the ChatStore files (all in Agent/Chat/)
//  ==============================================
//
//    ChatStore.swift          this file: the actor - every stored property,
//        init / deinit, the protected-data reboot guard, reload / close for
//        backup restore, sync zone name and the deferred sync dirty marks
//    ChatStoreModels.swift    the persisted data model (ChatSession,
//        ChatFolder, RawMessage, ContentPart, CompactMarker, ...)
//    Storage
//        ChatStore+Schema           open, createTables, migrations, backfills
//        ChatStore+SessionCRUD      create session, part_flags bitmask
//        ChatStore+SessionList      listSessions, row decoding, preview text
//        ChatStore+StoredPreview    persisted list preview
//        ChatStore+SessionQueries   sessions-tool queries, getSession, updates
//        ChatStore+Search           session search and snippets
//        ChatStore+Folders          folders (groups)
//        ChatStore+SessionDeletion  memory flag, delete sessions (local / cloud)
//        ChatStore+Messages         message CRUD
//        ChatStore+Media            media files
//        ChatStore+CompactMarkers   compaction markers
//        ChatStore+Tombstones       delete tombstones (resurrection guard)
//        ChatStore+WebAppShortcuts  web-app shortcuts
//        ChatStore+Maintenance      pruning, session repair
//        ChatStore+UsageStats       token usage statistics
//        ChatStore+Helpers          shared helpers (sort order, touch, binding)
//    Sync and restore
//        ChatStore+SyncDirty          dirty tracking, backlog, force sync / pull
//        ChatStore+SyncRemoteSessions inbound sessions and messages
//        ChatStore+SyncRemoteRecords  devices, media, skills, memories,
//                                     provider configs, env vars, sizes
//        ChatStore+BackupRestore      backup restore writes
//    Conversion
//        ContentPart+ProviderConversion  [ContentPart] -> Anthropic / Gemini
//        RawMessage+Conversion           RawMessage -> ChatMessage / AgentMessage
//
//  Rules that keep this split working
//  ==================================
//
//  - Stored properties stay in this actor body (extensions cannot hold them),
//    in the order they had before the split. Extension members stay
//    actor-isolated exactly like members declared here.
//  - Each file declares its own file-private loggers (`logger` "ChatStore",
//    `memDiagLogger`, `iCloudLogger`) where it logs.
//  - Members used from another file are internal; treat them as private to
//    the store. Methods that used to be private live in extensions (direct
//    calls); a method declared in the actor body is dispatched through the
//    actor's method table in unoptimised builds.
//  - New code goes into the file of its concern (or a new ChatStore+X file).
//  - Source-scanning tests (MinisTests/Standalone) read the files split out of
//    the old ChatStore.swift together (chatStoreSource() lists them).
//
//  History: the files above other than this one were split out of
//  ChatStore.swift (~8.8k lines). The code was moved verbatim; the differences
//  are the repeated import list, per-file logger copies, dropped `private` /
//  `fileprivate`, the extension wrappers (the sync extension, one
//  `extension ChatStore` before, is three now) and one doc comment put back on
//  its function (see ChatStore+CompactMarkers.swift).
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

private let iCloudLogger = AppLogger(category: "iCloud")

private let logger = AppLogger(category: "ChatStore")
/// [T-memory-enabled-new-session-bug DIAG] dedicated category so the
/// memory-toggle trace is grep-able (`[MemDiag]`) without ChatStore noise.
private let memDiagLogger = AppLogger(category: "MemDiag")

// MARK: - ChatStore Actor

/// Persistent store for chat sessions, messages, and media files.
/// All methods are synchronous SQLite operations (call from background if needed).
actor ChatStore {
    #if DEBUG
    /// [T-ios-unit-test-infra] Test-only injection point. The unit-test host
    /// sets this to `ChatStore(baseURL: <temp dir>)` before a test runs, so the
    /// app helpers that reach for `ChatStore.shared` internally (snapshot media,
    /// browser screenshots) write under that temp dir too. Nil in the app: then
    /// `shared` is the same lazily created default store as before. Release
    /// builds keep the plain `static let` below.
    nonisolated(unsafe) static var testOverride: ChatStore?
    private static let defaultShared = ChatStore()
    static var shared: ChatStore { testOverride ?? defaultShared }
    #else
    static let shared = ChatStore()
    #endif

    var db: OpaquePointer?
    /// Base URL for per-session media storage: Library/MinisChat/minis/
    let minisBaseURL: URL

    let dbURL: URL

    // [T-ios-listsessions-cache] Cache the last listSessions() result and only
    // recompute when a mutation that can change the list has fired. listSessions
    // parses every session's parts_json into fresh preview Strings (~1772 String
    // allocations per call); ContentView fires it from many refresh paths, and a
    // malloc_history stack proved these Strings dominated the heap (hundreds of
    // MB) — every redundant call minted a whole new batch that SwiftUI kept
    // referencing across body passes. With this cache, back-to-back calls with
    // no intervening write return the SAME array (no new Strings). Guarded by
    // `sessionListCacheDirty`, set true by every list-affecting mutation below.
    // ChatStore is an actor, so these fields need no extra locking.
    var sessionListCache: [ChatSession]?
    /// [T-ios-listsessions-perf] Sessions whose ROW CONTENT changed since the
    /// cache was built (a new message, a retitle, a model switch). Only these
    /// are re-queried; every other cached ChatSession value is reused as-is.
    var dirtySessionIds: Set<String> = []
    /// Set when the row SET or the ORDERING RULES change — a session created or
    /// deleted, a folder move, a pin, a bulk restore or merge. An incremental
    /// patch cannot express those, so the next listSessions() rebuilds fully.
    /// Starts true so the first call after launch does one full build.
    var sessionListNeedsFullRebuild = true

    /// [T-ios-listsessions-cache] Mark the cached session list stale. Called by
    /// every mutation that can change what listSessions() returns — the row set
    /// (create/delete), ordering (updated_at via touchSession), or a displayed
    /// field (title/category/pin/model/preview text from new messages).
    /// `internal` rather than `private` so the backup restore path
    /// (ChatStore+BackupRestore.swift) can invalidate after its own row writes —
    /// Swift's `private` is file-scoped, so an extension in another file cannot
    /// see it.
    /// Full invalidation: the next listSessions() re-queries every row.
    /// Use ONLY where the set of rows or their relative order can change.
    func invalidateSessionListCache() {
        sessionListNeedsFullRebuild = true
    }

    /// [T-ios-listsessions-perf] Targeted invalidation: only `sessionId`'s row
    /// content changed, so the next listSessions() re-queries that one row and
    /// reuses the rest of the cached array verbatim.
    ///
    /// Why this matters beyond the SQL saved: a full rebuild mints a brand-new
    /// ChatSession (and a brand-new preview String) for every session, so
    /// SwiftUI sees every row as changed and re-diffs the entire sidebar — 28.6
    /// G cycles of `erasedSessionRow` work in the profiled trace. Patching one
    /// element leaves the other values IDENTICAL, so the diff is O(changed).
    ///
    /// `updated_at` moves when a message lands, which reorders the list. That
    /// is handled by re-sorting the patched array with the same rules the SQL
    /// uses, NOT by falling back to a full rebuild — reordering is exactly the
    /// common case here.
    func invalidateSessionListCache(sessionId: String) {
        dirtySessionIds.insert(sessionId)
    }

    /// [T-ios27-scene-create-watchdog] Everything here runs inside the
    /// `dispatch_once` for `ChatStore.shared`, so ANY thread that touches the
    /// singleton afterwards — the main thread during scene creation, most
    /// importantly — blocks until this returns. It must therefore never do
    /// anything of unbounded duration.
    ///
    /// The crash this guards against: on iOS 27.0 a background task entered
    /// this initializer first, and an `iCloudLogger.info` inside `createTables`
    /// went NSLog -> libtrace -> NSNotificationCenter post ->
    /// `-[NSOperation waitUntilFinished]` and parked there. The main thread hit
    /// `ChatStore.shared` from `ContentView.body` and sat in
    /// `_dispatch_once_wait` until the 10 s scene-create watchdog killed the
    /// app (0.161 s of app CPU against 10 s of wall clock).
    ///
    /// Two rules keep this bounded, both enforced below:
    ///   1. No logging escapes to the system stack — `withDeferredLogging`
    ///      buffers it and flushes after the once token is released.
    ///   2. No optional/bulk work runs here. Schema creation must stay (nothing
    ///      can query before it), but data backfills are deferred to
    ///      `runDeferredMigrations()`, called off the init path.
    init() {
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let baseURL = libraryURL.appendingPathComponent("MinisChat", isDirectory: true)
        self.dbURL = baseURL.appendingPathComponent("minis.db")
        self.minisBaseURL = baseURL.appendingPathComponent("minis", isDirectory: true)

        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: minisBaseURL, withIntermediateDirectories: true)

        AppLogger.withDeferredLogging {
            openDatabase()
            createTables()
            armRebootGuardIfDegraded()
        }
    }

    // MARK: - [T-ios-reboot-config-loss] Protected-data reboot guard

    /// True when the DB cannot actually serve queries after open. After a
    /// device reboot iOS can relaunch the app in the background BEFORE first
    /// unlock (BGTask / CloudKit push / location session). minis.db carries
    /// the default completeUntilFirstUserAuthentication protection class, so
    /// sqlite3_open "succeeds" lazily but every statement fails — the session
    /// list reads as empty and the home screen looks freshly installed until
    /// the process is killed. Nothing is deleted (we never drop/recreate on
    /// failure), so a post-unlock reopen fully restores the store.
    private var dbDegraded = false

    private func probeDBUsable() -> Bool {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "SELECT count(*) FROM sessions", -1, &stmt, nil)
        sqlite3_finalize(stmt)
        return rc == SQLITE_OK
    }

    private func armRebootGuardIfDegraded() {
        guard !probeDBUsable() else { return }
        dbDegraded = true
        logger.error("[RebootGuard] minis.db unusable after open — likely launched before first unlock; arming post-unlock reopen")
        // Recover when protected data unlocks, plus on every foreground
        // activation (covers the unlock racing observer registration).
        // Observers stay registered after recovery; reopenIfDegraded no-ops.
        for name in [UIApplication.protectedDataDidBecomeAvailableNotification,
                     UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { await ChatStore.shared.reopenIfDegraded() }
            }
        }
    }

    func reopenIfDegraded() {
        guard dbDegraded else { return }
        reloadDatabase()
        guard probeDBUsable() else {
            logger.warning("[RebootGuard] reopen attempt still degraded — will retry on the next unlock/activation signal")
            return
        }
        dbDegraded = false
        // FULL: the database just came back after being unusable — nothing
        // about the cached list can be trusted.
        invalidateSessionListCache()
        logger.info("[RebootGuard] minis.db reopened after unlock — session store restored")
    }

    /// Initialize with a custom base URL (for testing).
    init(baseURL: URL) {
        self.dbURL = baseURL.appendingPathComponent("minis.db")
        self.minisBaseURL = baseURL.appendingPathComponent("minis", isDirectory: true)

        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: minisBaseURL, withIntermediateDirectories: true)

        openDatabase()
        createTables()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Reload / Close (for backup & restore)

    func closeDatabase() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    func reloadDatabase() {
        closeDatabase()
        openDatabase()
        createTables()
    }

    // MARK: - Sync Zone Name

    /// Zone name for dirty record tracking. Set by CloudSyncEngine on init.
    var syncZoneName: String = ""

    func setSyncZoneName(_ name: String) {
        syncZoneName = name
    }

    // MARK: - Deferred Sync Dirty Marks

    /// When true, markDirty writes to the dirty table but does NOT trigger scheduleSend.
    /// Set during agent processing to defer CloudKit upload triggers while streaming.
    /// Dirty marks are always written to DB immediately (crash-safe); only the
    /// scheduleSend() call is deferred until the agent loop finishes.
    private(set) var syncSendDeferred = false

    /// [T-p0-sync-defer-refcount] Owners (one per AIChatViewModel instance)
    /// currently holding the send deferral. `syncSendDeferred` is true while
    /// this is non-empty. A set rather than a counter so a double begin/end
    /// from the same vm (new turn superseding a post-stop hold) is idempotent.
    private var syncDeferralOwners = Set<String>()

    func beginSyncSendDeferral(owner: String) {
        syncDeferralOwners.insert(owner)
        syncSendDeferred = true
    }

    func endSyncSendDeferral(owner: String) {
        syncDeferralOwners.remove(owner)
        syncSendDeferred = !syncDeferralOwners.isEmpty
    }

    /// Session IDs touched during agent processing — used to scan file directories
    /// for changes when the agent loop finishes.
    var pendingSyncSessionIds = Set<String>()

    /// Flush deferred sync: scan session file directories and trigger CloudKit upload.
    /// Dirty marks for messages/sessions are already persisted in DB (written at
    /// appendMessage/touchSession time), so this only handles file scanning and
    /// the final scheduleSend trigger.
    func flushPendingSyncDirty() {
        // [T-p0-sync-defer-refcount] Another loop still holds the deferral:
        // keep the pending session ids and let that loop's release flush them.
        guard syncDeferralOwners.isEmpty else {
            iCloudLogger.info("[iCloud] flushPendingSyncDirty: deferred — \(self.syncDeferralOwners.count) loop(s) still running, \(self.pendingSyncSessionIds.count) sessions pending")
            return
        }
        syncSendDeferred = false
        let f0 = CFAbsoluteTimeGetCurrent()
        var fileCount = 0
        for sessionId in pendingSyncSessionIds {
            fileCount += scanAndMarkSessionFiles(sessionId: sessionId)
        }
        let f1 = CFAbsoluteTimeGetCurrent()
        let sessionCount = pendingSyncSessionIds.count
        pendingSyncSessionIds.removeAll()
        iCloudLogger.info("[iCloud] flushPendingSyncDirty: \(sessionCount) sessions, \(fileCount) files — scanFiles=\(String(format: "%.0f", (f1-f0)*1000))ms")
        // Trigger a single debounced send for all the dirty records
        if #available(iOS 17.0, *) {
            Task { @MainActor in
                CloudSyncEngine.shared.scheduleSend()
            }
        }
    }
}
