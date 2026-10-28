// Tests for [T-ios-moveto-perf] — the "Move to…" picker sometimes sat on a
// spinner because it fetched EVERY session through the serialized ChatStore
// actor before it could draw anything.
//
// Standalone (`swift MoveToSessionPerfTests.swift`) like its neighbours:
// deps/libs/libish_emu.a is device-only arm64, so the app cannot link for a
// simulator and an XCTest bundle has nowhere to run.

import Foundation

/// The chat page's sources, read as one text: AIChatView.swift (state and
/// `body`) first, then every other file under Views/Chat/AIChatView/ - the
/// old single AIChatView.swift was split into them.
func chatViewSource() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Views/Chat/AIChatView")
    let main = dir.appendingPathComponent("AIChatView.swift")
    let rest = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "AIChatView.swift" }
        .sorted { $0.path < $1.path }
    return ([main] + rest).compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

/// The sources that used to be the single file Agent/Chat/ChatStore.swift -
/// the actor plus the files it was split into - read as one text.
func chatStoreSource() -> String {
    let chat = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Agent/Chat")
    let names = ["ChatStore", "ChatStore+Schema", "ChatStore+SessionCRUD", "ChatStore+SessionList",
                 "ChatStore+Search", "ChatStore+SessionQueries", "ChatStore+Folders",
                 "ChatStore+SessionDeletion", "ChatStore+StoredPreview", "ChatStore+Messages",
                 "ChatStore+Media", "ChatStore+CompactMarkers", "ChatStore+Tombstones",
                 "ChatStore+WebAppShortcuts", "ChatStore+Maintenance", "ChatStore+Helpers",
                 "ChatStore+UsageStats", "ChatStoreModels", "ContentPart+ProviderConversion",
                 "RawMessage+Conversion", "ChatStore+SyncDirty", "ChatStore+SyncRemoteSessions",
                 "ChatStore+SyncRemoteRecords", "ChatStore+BackupRestore"]
    return names.compactMap { try? String(contentsOf: chat.appendingPathComponent($0 + ".swift"), encoding: .utf8) }
        .joined(separator: "\n")
}

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
func check(_ l: String, _ a: Bool, _ e: Bool = true) {
    if a == e { print("  ✅ \(l)") } else { print("  ❌ \(l) — expected \(e), got \(a)"); failures += 1 }
}
func checkEq<T: Equatable>(_ l: String, _ a: T, _ b: T) {
    if a == b { print("  ✅ \(l)") } else { print("  ❌ \(l)\n     expected: \(b)\n     actual:   \(a)"); failures += 1 }
}

// MARK: - Reproduced pieces

struct Sess: Equatable { let id: String; let isChild: Bool; let updatedAt: Int }

/// Mirrors the SQL tail assembly in listSessions(limit:).
func sqlTail(limit: Int?) -> String {
    let base = "FROM sessions s ORDER BY s.updated_at DESC"
    return base + (limit.map { "\nLIMIT \(max(1, $0))" } ?? "")
}

/// Mirrors the cache gate: only the unlimited shape reads or writes the cache.
final class StoreModel {
    var rows: [Sess]
    var cache: [Sess]?
    var dirty = true
    var queries = 0
    init(rows: [Sess]) { self.rows = rows }

    func listSessions(limit: Int? = nil) -> [Sess] {
        if limit == nil, !dirty, let c = cache { return c }
        queries += 1
        let ordered = rows.sorted { $0.updatedAt > $1.updatedAt }
        let out = limit.map { Array(ordered.prefix(max(1, $0))) } ?? ordered
        if limit == nil { cache = out; dirty = false }
        return out
    }
}

/// Mirrors MoveToSessionSheet.displayedSessions after the fix.
func displayed(recent: [Sess], searchResults: [Sess]?, currentId: String?) -> [Sess] {
    let source = searchResults ?? recent
    return source.filter { $0.id != currentId && !$0.isChild }
}

let corpus = (0..<200).map { Sess(id: "s\($0)", isChild: $0 % 37 == 0, updatedAt: 1000 - $0) }

print("\n[1] The SQL tail")
do {
    checkEq("no limit leaves the statement untouched",
            sqlTail(limit: nil), "FROM sessions s ORDER BY s.updated_at DESC")
    check("a limit appends LIMIT", sqlTail(limit: 50).hasSuffix("\nLIMIT 50"))
    // The value is interpolated, so a bad one must not silently return nothing.
    check("zero is clamped to 1", sqlTail(limit: 0).hasSuffix("LIMIT 1"))
    check("negative is clamped to 1", sqlTail(limit: -5).hasSuffix("LIMIT 1"))
}

print("\n[2] The two list shapes never share a cache slot")
do {
    let st = StoreModel(rows: corpus)
    let full = st.listSessions()
    checkEq("the full list is everything", full.count, 200)
    // A limited call must not overwrite the sidebar's cached full list…
    let limited = st.listSessions(limit: 50)
    checkEq("the limited list is capped", limited.count, 50)
    checkEq("the cache still holds the FULL list", st.cache?.count, 200)
    let fullAgain = st.listSessions()
    checkEq("the sidebar still gets every session", fullAgain.count, 200)
    // Query accounting: full (1) + limited (2). The third call is the sidebar
    // reading its still-valid cache, so it costs nothing — proving the limited
    // call neither consumed nor invalidated it.
    checkEq("the limited call ran its own query", st.queries, 2)
    checkEq("…and the sidebar's later read was free", st.cache?.count, 200)

    // The reverse pollution: a cached full list must not satisfy a limited call.
    let st2 = StoreModel(rows: corpus)
    _ = st2.listSessions()                    // warms the cache
    checkEq("limited call after a warm cache is still capped",
            st2.listSessions(limit: 10).count, 10)

    // Ordering is newest-first in both shapes.
    checkEq("limited returns the NEWEST rows", limited.first?.id, "s0")
    checkEq("…not an arbitrary slice", limited.last?.id, "s49")
}

print("\n[3] Search keeps full-corpus reach")
do {
    // The regression this guards: displayedSessions used to INTERSECT search
    // ids with `sessions`. With `sessions` capped at 50, a match at position
    // 120 would have vanished — search would silently mean "search the newest
    // 50", which is the opposite of what someone searching wants.
    let recent = Array(corpus.prefix(50))
    let deepMatch = corpus[120]
    check("the match is NOT in the recent window", !recent.contains(deepMatch))
    let shown = displayed(recent: recent, searchResults: [deepMatch], currentId: nil)
    checkEq("it is still shown, because search supplies its own rows",
            shown.map(\.id), [deepMatch.id])

    // The OLD behaviour, for contrast.
    let oldStyle = recent.filter { [deepMatch.id].contains($0.id) }
    check("PRE-FIX: the intersection would have dropped it", oldStyle.isEmpty)
}

print("\n[4] Exclusions still apply, in both modes")
do {
    let recent = Array(corpus.prefix(50))
    let cur = recent[3].id
    let shown = displayed(recent: recent, searchResults: nil, currentId: cur)
    check("the current session is never a move target", !shown.contains { $0.id == cur })
    check("child sessions are excluded from the recent list", !shown.contains { $0.isChild })
    // Search results go through the same filter — they did not before, since
    // the intersection inherited the recent list's already-filtered rows.
    let realMatch = corpus[1]      // s1 — not a child
    let childMatch = corpus[37]     // s37 — a child
    check("fixture sanity: one child, one not",
          childMatch.isChild && !realMatch.isChild)
    let withChild = displayed(recent: recent, searchResults: [realMatch, childMatch], currentId: nil)
    check("a child session matched by search is still excluded",
          !withChild.contains { $0.isChild })
    checkEq("…leaving only the real match", withChild.map(\.id), [realMatch.id])
}

print("\n[5] Optimistic first frame")
do {
    // Before: `sessions` started empty, so the sheet drew a blank list until
    // the actor got round to the query. Now the caller can seed it.
    let seeded = Array(corpus.prefix(8))
    checkEq("a seeded sheet has rows on frame one",
            displayed(recent: seeded, searchResults: nil, currentId: nil).isEmpty, false)
    checkEq("an unseeded sheet is still empty (the default is unchanged)",
            displayed(recent: [], searchResults: nil, currentId: nil).isEmpty, true)
}

print("\n[5b] The seed store [T-ios-moveto-seed]")
do {
    // Mirrors ViewModelCache.noteSessionsLoaded.
    final class SeedBox {
        private(set) var seed: [Sess] = []
        let cap = 50
        func note(_ rows: [Sess]) {
            let visible = rows.filter { !$0.isChild }
            guard !visible.isEmpty else { return }
            seed = Array(visible.prefix(cap))
        }
    }
    let box = SeedBox()
    checkEq("starts empty, so an unseeded first run is unchanged", box.seed.isEmpty, true)

    box.note(corpus)
    check("a load fills the seed", !box.seed.isEmpty)
    checkEq("capped at the picker's own limit", box.seed.count, 50)
    check("child sessions never enter the seed", !box.seed.contains { $0.isChild })
    checkEq("newest first, matching the query order", box.seed.first?.id, "s1")  // s0 is a child

    // An empty load must not wipe a good seed: a transient failure or a
    // filtered-to-nothing refresh would otherwise send the picker back to a
    // blank first frame.
    let before = box.seed
    box.note([])
    checkEq("an empty load leaves the previous seed intact", box.seed, before)
    box.note(corpus.filter { $0.isChild })
    checkEq("a child-only load does too", box.seed, before)

    // The seed is a placeholder, not a source of truth: the sheet's task
    // overwrites it. Model that hand-off.
    var shown = displayed(recent: box.seed, searchResults: nil, currentId: nil)
    check("frame one is populated from the seed", !shown.isEmpty)
    let authoritative = Array(corpus.prefix(50)).filter { !$0.isChild }
    shown = displayed(recent: authoritative, searchResults: nil, currentId: nil)
    checkEq("…and is replaced by the query result", shown.count, authoritative.count)

    // The seed goes through the SAME exclusions as the query result.
    let cur = box.seed[2].id
    check("the current session is excluded from a seeded frame too",
          !displayed(recent: box.seed, searchResults: nil, currentId: cur).contains { $0.id == cur })
}

print("\n[6] Shipping sources match these assumptions")
func source(_ rel: String) -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
let store = chatStoreSource()
let view  = chatViewSource()

if store.isEmpty || view.isEmpty { print("  ⏭  sources not readable") } else {
    check("listSessions takes an optional limit defaulting to nil",
          store.contains("func listSessions(limit: Int? = nil) -> [ChatSession] {"))
    // [T-ios-listsessions-perf] The single `sessionListCacheDirty` flag was
    // split in two: `sessionListNeedsFullRebuild` covers row-SET/ordering
    // changes, while `dirtySessionIds` covers row-CONTENT changes that the
    // incremental patch splices into the cached array. The gate is still
    // "unlimited shape only" — a bounded caller must never be served the
    // unbounded cache — and the write is still gated the same way.
    check("the cache READ is gated on the unlimited shape",
          store.contains("if limit == nil, !sessionListNeedsFullRebuild, let cached = sessionListCache {"))
    check("…a clean cache is returned verbatim",
          store.contains("if dirtySessionIds.isEmpty { return cached }"))
    check("…a dirty one goes through the incremental patch",
          store.contains("if let patched = patchedSessionList(cached, dirtyIds: dirtySessionIds) {"))
    check("a full rebuild clears the incremental state",
          store.contains("sessionListNeedsFullRebuild = false")
          && store.contains("dirtySessionIds.removeAll()"))
    check("the cache WRITE is too", store.contains("if limit == nil {\n            sessionListCache = sessions"))
    check("the limit is clamped", store.contains("LIMIT \\(max(1, $0))"))
    check("the updated_at index exists",
          store.contains("CREATE INDEX IF NOT EXISTS idx_sessions_updated_at ON sessions(updated_at DESC)"))
    // The index must be in the always-run schema block, not behind a version
    // check, or existing installs would never get it.
    if let idx = store.range(of: "idx_sessions_updated_at"),
       let msg = store.range(of: "idx_msg_sess_role_sort") {
        check("…alongside the other CREATE INDEX statements", idx.lowerBound > msg.lowerBound)
    }

    check("the sheet asks for a bounded list",
          view.contains("ChatStore.shared.listSessions(limit: Self.recentLimit)"))
    check("search holds ROWS, not an id set",
          view.contains("@State private var searchResults: [ChatSession]?")
          && !view.contains("searchMatchedIds"))
    check("displayedSessions prefers the search rows",
          view.contains("let source = searchResults ?? sessions"))
    check("the sheet can be seeded for the first frame",
          view.contains("var initialSessions: [ChatSession] = []")
          && view.contains("_sessions = State(initialValue: initialSessions)"))

    // [T-ios-moveto-seed] The wiring the previous commit left undone.
    check("the call site actually passes a seed",
          view.contains("initialSessions: ViewModelCache.recentSessionsSeed"))
    let lifecycle = source("Agent/Chat/ChatLifecycleSupport.swift")
    check("the seed lives on the @MainActor holder, not the actor",
          lifecycle.contains("private(set) static var recentSessionsSeed: [ChatSession] = []"))
    check("it filters children centrally",
          lifecycle.contains("let visible = sessions.filter { !$0.isChild }"))
    check("an empty load cannot wipe it",
          lifecycle.contains("guard !visible.isEmpty else { return }"))
    // ChatStore must NOT have grown a nonisolated cache accessor — that was the
    // tempting shortcut and it would hand out an array DB writes mutate.
    check("no nonisolated cache escape hatch was added",
          !store.contains("nonisolated") || !store.contains("sessionListCache\n"))
    let content = contentViewSource()
    checkEq("both sidebar load paths keep the seed fresh",
            content.components(separatedBy: "ViewModelCache.noteSessionsLoaded(sessions)").count - 1, 2)
}

print("\n\(failures == 0 ? "✅ ALL PASSED" : "❌ \(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
