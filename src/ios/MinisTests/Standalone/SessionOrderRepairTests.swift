// [T-session-order-repair-prune] A session over ChatStore's 2048-row prune
// threshold must not have its sort_orders rewritten on every open, and its list
// preview must keep following new messages.
//
// Field case (FD704863 "GitHub Issue 回复与分类处理", 2026-10-04): the session
// held 2048 rows; each append pruned the oldest, so its sort_orders ran
// 35..2082, later 56..2103. The old repair check expected exactly 0..n-1, so the
// first open after every launch rewrote all 2048 rows down to 0..2047
// ("[Repair] sortOrderFixed=2048"). Nothing was out of order - the rewrite only
// lowered every sort_order. The stored list preview remembers the sort_order
// of the message it shows and only moves forward, so after the rewrite every
// new message lost to it: the list kept showing an 11:50 reply ("6 分钟前")
// while the chat had moved on to 12:35.
//
// This test compiles the production block `// BEGIN SessionOrderRules` from
// Agent/Chat/ChatStore+Maintenance.swift verbatim and runs its SQL against an
// in-memory SQLite database shaped like minis.db. The pre-fix rules are kept
// here as literals so the replay shows both behaviours. The append / prune /
// repair steps around the rules are a minimal stand-in for ChatStore's (same
// statements, no actor); section 5 checks the production files still wire the
// rules in.
//
// Run: swift SessionOrderRepairTests.swift   (macOS; uses the system SQLite)

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}

let ios = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String {
    (try? String(contentsOf: ios.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

let maintenance = source("Agent/Chat/ChatStore+Maintenance.swift")
guard let b = maintenance.range(of: "// BEGIN SessionOrderRules"),
      let e = maintenance.range(of: "// END SessionOrderRules") else {
    print("❌ SessionOrderRules block not found in ChatStore+Maintenance.swift"); exit(1)
}
let rulesBlock = String(maintenance[b.lowerBound..<e.upperBound])

// MARK: - Harness (compiled with the production block)

let harness = #"""
import Foundation
import SQLite3

var results: [String: String] = [:]
func R(_ k: String, _ v: Any) { results[k] = "\(v)" }

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
let pruneThreshold = 2048          // ChatStore.pruneThreshold
let sid = "FD704863-9C1A-4A7A-BE26-652FACFFC042"

/// Pre-fix rules, verbatim from the old ChatStore+Maintenance / +StoredPreview.
enum OldRules {
    static let inversionProbeSQL = """
        SELECT 1 FROM (
          SELECT sort_order,
                 ROW_NUMBER() OVER (ORDER BY created_at ASC, id ASC) - 1 AS expected
          FROM messages WHERE session_id = ?
        ) WHERE sort_order != expected LIMIT 1
        """
    static func repairBaseSortOrder(rowCount: Int, oldMaxSortOrder: Int) -> Int { 0 }
    static func storedPreviewUpdateSQL(comparison: String) -> String {
        """
        UPDATE sessions
           SET preview_text = ?, preview_sort_order = ?
         WHERE id = ?
           AND (preview_sort_order IS NULL OR ? \(comparison) preview_sort_order)
        """
    }
}

final class Store {
    var db: OpaquePointer?
    let newRules: Bool
    var clock: Double = 1_791_000_000
    var serial = 0

    init(newRules: Bool) {
        self.newRules = newRules
        sqlite3_open(":memory:", &db)
        exec("CREATE TABLE messages (id TEXT PRIMARY KEY, session_id TEXT, role TEXT, created_at REAL, sort_order INTEGER, text TEXT)")
        exec("CREATE INDEX idx_messages_session ON messages(session_id, sort_order)")
        exec("CREATE TABLE sessions (id TEXT PRIMARY KEY, preview_text TEXT, preview_sort_order INTEGER)")
        exec("INSERT INTO sessions (id) VALUES ('\(sid)')")
    }
    func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    func ints(_ sql: String, _ binds: [Any] = []) -> [Int?] {
        var st: OpaquePointer?; var out: [Int?] = []
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [-999] }
        for (i, v) in binds.enumerated() {
            if let s = v as? String { sqlite3_bind_text(st, Int32(i + 1), s, -1, SQLITE_TRANSIENT) }
            else if let n = v as? Int { sqlite3_bind_int64(st, Int32(i + 1), Int64(n)) }
        }
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(sqlite3_column_type(st, 0) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(st, 0)))
        }
        sqlite3_finalize(st); return out
    }
    func text(_ sql: String) -> String? {
        var st: OpaquePointer?; var out: String?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) { out = String(cString: c) }
        sqlite3_finalize(st); return out
    }
    func run(_ sql: String, _ binds: [Any]) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            R("sqlError", String(cString: sqlite3_errmsg(db))); return
        }
        for (i, v) in binds.enumerated() {
            if let s = v as? String { sqlite3_bind_text(st, Int32(i + 1), s, -1, SQLITE_TRANSIENT) }
            else if let n = v as? Int { sqlite3_bind_int64(st, Int32(i + 1), Int64(n)) }
            else if let d = v as? Double { sqlite3_bind_double(st, Int32(i + 1), d) }
        }
        sqlite3_step(st); sqlite3_finalize(st)
    }

    // ChatStore.appendMessages: sort_order = MAX+1, created_at at persist time,
    // then the incremental preview update, then the prune.
    func append(_ role: String, _ text: String) {
        serial += 1; clock += 7
        let id = String(format: "%08X-0000-0000-0000-%012d", UInt32.random(in: 0...UInt32.max), serial)
        let so = ints("SELECT COALESCE(MAX(sort_order), -1) + 1 FROM messages WHERE session_id = ?", [sid])[0]!
        run("INSERT INTO messages (id, session_id, role, created_at, sort_order, text) VALUES (?, ?, ?, ?, ?, ?)",
            [id, sid, role, clock, so, text])
        let cmp = role == "assistant" ? ">=" : ">"
        if newRules {
            run(SessionOrderRules.storedPreviewUpdateSQL(comparison: cmp), [text, so, sid, so, sid])
        } else {
            run(OldRules.storedPreviewUpdateSQL(comparison: cmp), [text, so, sid, so])
        }
        let total = ints("SELECT COUNT(*) FROM messages WHERE session_id = ?", [sid])[0]!
        if total > pruneThreshold {
            run("""
                DELETE FROM messages WHERE id IN (
                    SELECT id FROM messages WHERE session_id = ?
                    ORDER BY sort_order ASC, created_at ASC, id ASC LIMIT ?)
                """, [sid, total - pruneThreshold])
        }
    }

    func needsRepair() -> Bool {
        let dup = ints("SELECT COUNT(*) - COUNT(DISTINCT sort_order) FROM messages WHERE session_id = ?", [sid])[0]!
        if dup > 0 { return true }
        let probe = newRules ? SessionOrderRules.inversionProbeSQL : OldRules.inversionProbeSQL
        return !ints(probe, [sid]).isEmpty
    }

    /// ChatStore.repairSession step 1/2 (+ the preview recompute the fix adds).
    @discardableResult
    func repair() -> Int {
        var st: OpaquePointer?; var rows: [(String, Int)] = []
        sqlite3_prepare_v2(db, "SELECT id, sort_order FROM messages WHERE session_id = ? ORDER BY created_at ASC, id ASC", -1, &st, nil)
        sqlite3_bind_text(st, 1, sid, -1, SQLITE_TRANSIENT)
        while sqlite3_step(st) == SQLITE_ROW {
            rows.append((String(cString: sqlite3_column_text(st, 0)), Int(sqlite3_column_int64(st, 1))))
        }
        sqlite3_finalize(st)
        let oldMax = rows.map(\.1).max() ?? -1
        let base = newRules ? SessionOrderRules.repairBaseSortOrder(rowCount: rows.count, oldMaxSortOrder: oldMax)
                            : OldRules.repairBaseSortOrder(rowCount: rows.count, oldMaxSortOrder: oldMax)
        var fixed = 0
        for (i, r) in rows.enumerated() where r.1 != base + i {
            run("UPDATE messages SET sort_order = ? WHERE id = ?", [base + i, r.0]); fixed += 1
        }
        if newRules && fixed > 0 { recomputePreview() }
        return fixed
    }

    /// The new open path: heal a stale preview, then cheap-check-then-repair.
    func openSession() {
        if newRules, !ints(SessionOrderRules.stalePreviewProbeSQL, [sid]).isEmpty { recomputePreview() }
        if needsRepair() { repair() }
    }

    // recomputeStoredPreview, reduced to "latest row by sort_order".
    func recomputePreview() {
        run("UPDATE sessions SET preview_text = (SELECT text FROM messages WHERE session_id = ?1 ORDER BY sort_order DESC LIMIT 1), preview_sort_order = (SELECT MAX(sort_order) FROM messages WHERE session_id = ?1) WHERE id = ?1", [sid])
    }

    var preview: String? { text("SELECT preview_text FROM sessions") }
    var lastText: String? { text("SELECT text FROM messages ORDER BY sort_order DESC LIMIT 1") }
    var minSO: Int { ints("SELECT MIN(sort_order) FROM messages")[0] ?? -1 }
    var maxSO: Int { ints("SELECT MAX(sort_order) FROM messages")[0] ?? -1 }
    var count: Int { ints("SELECT COUNT(*) FROM messages")[0] ?? -1 }
    var canonicalMatchesSortOrder: Bool {
        text("SELECT group_concat(id) FROM (SELECT id FROM messages ORDER BY sort_order, created_at, id)")
            == text("SELECT group_concat(id) FROM (SELECT id FROM messages ORDER BY created_at, id)")
    }
}

/// FD704863's shape: a long conversation past the prune threshold, then an
/// app relaunch + open, then a few more turns.
func replay(_ s: Store, tag: String) {
    for i in 0..<2104 { s.append(i % 2 == 0 ? "user" : "assistant", "turn \(i)") }
    R("\(tag).beforeOpen.count", s.count); R("\(tag).beforeOpen.min", s.minSO); R("\(tag).beforeOpen.max", s.maxSO)
    R("\(tag).beforeOpen.previewIsLast", s.preview == s.lastText)
    R("\(tag).needsRepairOnOpen", s.needsRepair())
    s.openSession()
    R("\(tag).afterOpen.min", s.minSO); R("\(tag).afterOpen.max", s.maxSO)
    for i in 0..<9 { s.append(i % 2 == 0 ? "user" : "assistant", "after reopen \(i)") }
    R("\(tag).after.preview", s.preview ?? "nil"); R("\(tag).after.last", s.lastText ?? "nil")
    R("\(tag).after.previewIsLast", s.preview == s.lastText)
    R("\(tag).after.count", s.count)
    R("\(tag).needsRepairOnSecondOpen", s.needsRepair())
}

replay(Store(newRules: false), tag: "old")
replay(Store(newRules: true), tag: "new")

// A device already in the frozen state (old build ran the rewrite), now on the
// new build: the open path heals it, and so does the next write on its own.
do {
    let s = Store(newRules: false)
    for i in 0..<2104 { s.append(i % 2 == 0 ? "user" : "assistant", "turn \(i)") }
    s.openSession()                                    // old rewrite
    s.append("user", "frozen 1"); s.append("assistant", "frozen 2")
    R("upgrade.frozenBefore", s.preview != s.lastText)
    let healedByOpen = Store(newRules: true); healedByOpen.db = s.db
    R("upgrade.staleProbe", !healedByOpen.ints(SessionOrderRules.stalePreviewProbeSQL, [sid]).isEmpty)
    healedByOpen.openSession()
    R("upgrade.openHealed", healedByOpen.preview == healedByOpen.lastText)
}
do {
    let s = Store(newRules: false)
    for i in 0..<2104 { s.append(i % 2 == 0 ? "user" : "assistant", "turn \(i)") }
    s.openSession()
    let n = Store(newRules: true); n.db = s.db; n.serial = 9000; n.clock = s.clock
    n.append("assistant", "first write on the new build")
    R("upgrade.writeHealed", n.preview == "first write on the new build")
}

// A genuine inversion is still repaired, in canonical order, without the
// maximum moving down.
do {
    let s = Store(newRules: true)
    for i in 0..<2100 { s.append(i % 2 == 0 ? "user" : "assistant", "turn \(i)") }
    let maxBefore = s.maxSO
    // Two rows whose created_at disagrees with their sort_order.
    let ids = s.ints("SELECT rowid FROM messages ORDER BY sort_order LIMIT 2 OFFSET 1000")
    s.run("UPDATE messages SET created_at = created_at + 100 WHERE rowid = ?", [ids[0]!])
    R("inv.detected", s.needsRepair())
    let fixed = s.repair()
    R("inv.fixed", fixed); R("inv.canonical", s.canonicalMatchesSortOrder)
    R("inv.maxNotLowered", s.maxSO >= maxBefore); R("inv.dense", s.maxSO - s.minSO + 1 == s.count)
    R("inv.previewIsLast", s.preview == s.lastText)
    R("inv.cleanAfter", !s.needsRepair())
}

// Gaps are healthy: middle deletions do not trigger a rewrite.
do {
    let s = Store(newRules: true)
    for i in 0..<300 { s.append(i % 2 == 0 ? "user" : "assistant", "turn \(i)") }
    s.run("DELETE FROM messages WHERE sort_order BETWEEN 100 AND 120", [])
    R("gap.needsRepair", s.needsRepair())
}

// Duplicates: maximum below n-1, so the base is 0 and the new maximum is n-1.
do {
    let s = Store(newRules: true)
    for i in 0..<10 { s.append(i % 2 == 0 ? "user" : "assistant", "turn \(i)") }
    s.run("UPDATE messages SET sort_order = 3 WHERE sort_order = 4", [])
    R("dup.needsRepair", s.needsRepair())
    s.repair()
    R("dup.min", s.minSO); R("dup.max", s.maxSO); R("dup.canonical", s.canonicalMatchesSortOrder)
}

// The incremental preview rule itself is unchanged for ordinary writes.
do {
    let s = Store(newRules: true)
    s.append("user", "hi"); s.append("assistant", "hello")
    R("rule.assistantWins", s.preview == "hello")
    let so = s.maxSO
    s.run(SessionOrderRules.storedPreviewUpdateSQL(comparison: ">"), ["user same so", so, sid, so, sid])
    R("rule.userTieLoses", s.preview == "hello")
    s.run(SessionOrderRules.storedPreviewUpdateSQL(comparison: ">="), ["older merge", so - 1, sid, so - 1, sid])
    R("rule.olderLoses", s.preview == "hello")
}
R("base.empty", SessionOrderRules.repairBaseSortOrder(rowCount: 0, oldMaxSortOrder: -1))
R("base.pruned", SessionOrderRules.repairBaseSortOrder(rowCount: 2048, oldMaxSortOrder: 2103))

let json = try! JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: json)
"""#

// MARK: - Compile and run

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("session-order-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
try! ("import Foundation\n" + rulesBlock).write(to: tmp.appendingPathComponent("Rules.swift"), atomically: true, encoding: .utf8)
try! harness.write(to: tmp.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

func sh(_ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try! p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}
let bin = tmp.appendingPathComponent("harness").path
let (rc, out) = sh(["xcrun", "swiftc", "-O", "-o", bin,
                    tmp.appendingPathComponent("Rules.swift").path, tmp.appendingPathComponent("main.swift").path])
guard rc == 0 else { print("❌ harness did not compile:\n\(out)"); exit(1) }
let resultsPath = tmp.appendingPathComponent("r.json").path
let (rc2, out2) = sh([bin, resultsPath])
guard rc2 == 0, let data = FileManager.default.contents(atPath: resultsPath),
      let r = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
    print("❌ harness failed:\n\(out2)"); exit(1)
}
func v(_ k: String) -> String { r[k] ?? "<missing \(k)>" }

print("▶️  1. replay of FD704863 under the OLD rules (reproduces the field state)")
check("past the threshold the session holds 2048 rows starting above 0 (min=\(v("old.beforeOpen.min")), max=\(v("old.beforeOpen.max")))",
      v("old.beforeOpen.count") == "2048" && v("old.beforeOpen.min") == "56" && v("old.beforeOpen.max") == "2103")
check("old check: a pruned session 'needs repair' on open", v("old.needsRepairOnOpen") == "true")
check("old repair rewrites it down to 0..2047", v("old.afterOpen.min") == "0" && v("old.afterOpen.max") == "2047")
check("old: the list preview freezes - later messages never replace it (shows '\(v("old.after.preview"))', last is '\(v("old.after.last"))')",
      v("old.after.previewIsLast") == "false")
check("old: and the next open rewrites again", v("old.needsRepairOnSecondOpen") == "true")

print("\n▶️  2. the same replay under the NEW rules")
check("a pruned, in-order session does not need repair", v("new.needsRepairOnOpen") == "false")
check("opening it leaves every sort_order where it was",
      v("new.afterOpen.min") == "56" && v("new.afterOpen.max") == "2103")
check("the list preview follows the last message", v("new.after.previewIsLast") == "true")
check("still 2048 rows, still no repair on the next open",
      v("new.after.count") == "2048" && v("new.needsRepairOnSecondOpen") == "false")

print("\n▶️  3. devices already frozen by an old build")
check("the frozen state is reproduced (preview ≠ last message)", v("upgrade.frozenBefore") == "true")
check("the stale-preview probe sees it", v("upgrade.staleProbe") == "true")
check("opening the session heals the preview", v("upgrade.openHealed") == "true")
check("…and so does the next message written, without an open", v("upgrade.writeHealed") == "true")

print("\n▶️  4. what repair still does")
check("a real created_at / sort_order inversion is still detected", v("inv.detected") == "true")
check("…and repaired into canonical order", v("inv.canonical") == "true" && v("inv.cleanAfter") == "true")
check("…dense, ending at or above the old maximum (never moved down)",
      v("inv.maxNotLowered") == "true" && v("inv.dense") == "true")
check("…and the preview is recomputed after a repair", v("inv.previewIsLast") == "true")
check("gaps in the middle are not an anomaly", v("gap.needsRepair") == "false")
check("duplicates are repaired to 0..n-1 (base 0, max n-1)",
      v("dup.needsRepair") == "true" && v("dup.min") == "0" && v("dup.max") == "9" && v("dup.canonical") == "true")
check("base: empty session → 0; 2048 rows ending at 2103 → 56",
      v("base.empty") == "0" && v("base.pruned") == "56")
check("preview rule unchanged: assistant wins its own position, a user row at the same position loses, an older merge loses",
      v("rule.assistantWins") == "true" && v("rule.userTieLoses") == "true" && v("rule.olderLoses") == "true")
check("no SQL error in the harness", r["sqlError"] == nil)

print("\n▶️  5. production wiring")
let preview = source("Agent/Chat/ChatStore+StoredPreview.swift")
let persistence = source("Agent/Chat/AIChatViewModel+Persistence.swift")
let send = source("Agent/Chat/AIChatViewModel+Send.swift")
check("sessionNeedsRepair runs SessionOrderRules.inversionProbeSQL",
      maintenance.contains("sqlite3_prepare_v2(db, SessionOrderRules.inversionProbeSQL"))
check("the old dense-from-0 probe is gone",
      !maintenance.replacingOccurrences(of: rulesBlock, with: "").contains("ROW_NUMBER() OVER (ORDER BY created_at ASC, id ASC) - 1 AS expected"))
check("repairSession numbers from SessionOrderRules.repairBaseSortOrder",
      maintenance.contains("let base = SessionOrderRules.repairBaseSortOrder(")
      && maintenance.contains("where row.oldSortOrder != base + idx"))
check("repairSession recomputes the stored preview when rows moved",
      maintenance.contains("if report.sortOrderFixed > 0 {\n            recomputeStoredPreview(sessionId: sessionId)"))
check("repairSessionIfNeeded heals a stale preview first",
      maintenance.contains("if storedPreviewIsStale(sessionId: sessionId) {"))
check("updateStoredPreview uses the shared SQL and binds the 5th parameter",
      preview.contains("SessionOrderRules.storedPreviewUpdateSQL(comparison: comparison)")
      && preview.contains("sqlite3_bind_text(stmt, 5, (sessionId as NSString).utf8String, -1, nil)"))
check("persistAgentMessage caps the count baseline at the post-prune count",
      persistence.contains("lastKnownDbCount = min(lastKnownDbCount + 1, stats.count)"))
check("loadSession sets the order-hash baseline from the rows it loaded",
      persistence.contains("lastKnownDbOrderHash = Self.computeOrderHash(of: rawMessages)"))
let resumeTail: String = {
    guard let a = send.range(of: "func resume() {"),
          let z = send.range(of: "resume DONE session=", range: a.upperBound..<send.endIndex) else { return "" }
    return String(send[a.lowerBound..<z.lowerBound])
}()
check("resume()'s epilogue refreshes the reload baseline before finishing",
      resumeTail.contains("await self.refreshDbBaselineFromStore()"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
