//
//  ChatStore+SessionCRUD.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore, creating sessions and the part_flags bitmask (what a message
//  contains) that list previews are computed from.
//
//  Map of the ChatStore files: ChatStore.swift.
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

private let memDiagLogger = AppLogger(category: "MemDiag")

extension ChatStore {
    // MARK: - Session CRUD

    @discardableResult
    func createSession(modelId: String, title: String? = nil, source: String? = nil,
                       parentSessionId: String? = nil, parentToolUseId: String? = nil) -> ChatSession {
        // FULL: adds a row to the set.
        invalidateSessionListCache()
        let now = Date()
        var session = ChatSession(
            id: UUID().uuidString,
            title: title,
            category: nil,
            modelId: modelId,
            createdAt: now,
            updatedAt: now,
            source: source
        )
        session.parentSessionId = parentSessionId
        session.parentToolUseId = parentToolUseId

        // [T-memory-enabled-new-session-bug] Explicitly write memory_enabled
        // from the global default. Previously the INSERT omitted the column
        // and relied on the SQL `DEFAULT 1`, so every new session was
        // memory_enabled=1 regardless of the Settings → Memory global toggle
        // (UserDefaults "memory.global.enabled"). That also made
        // getMemoryEnabled()'s "no row → read global default" fallback dead
        // code, since the row always existed with 1. Read the global default
        // here (mirroring that fallback) so turning the toggle off actually
        // starts new sessions with memory disabled. Existing sessions keep
        // their stored value; iCloud-synced sessions (the INSERT at ~L4492)
        // intentionally use the remote record's memory_enabled and are NOT
        // changed.
        let globalMemoryEnabled = (UserDefaults.standard.object(forKey: "memory.global.enabled") as? Bool) ?? true

        // [T-memory-enabled-new-session-bug DIAG] Trace what we read from
        // UserDefaults and what we bind, so a live repro shows whether the
        // global default is reaching createSession.
        let rawObj = UserDefaults.standard.object(forKey: "memory.global.enabled")
        memDiagLogger.info("[MemDiag] createSession sid=\(session.id.prefix(8)) rawDefaults=\(String(describing: rawObj)) resolved=\(globalMemoryEnabled) → bind memory_enabled=\(globalMemoryEnabled ? 1 : 0)")

        let sql = "INSERT INTO sessions (id, title, model_id, created_at, updated_at, source, memory_enabled, parent_session_id, parent_tool_use_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (session.id as NSString).utf8String, -1, nil)
            bindOptionalText(stmt, index: 2, value: session.title)
            sqlite3_bind_text(stmt, 3, (session.modelId as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 4, now.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 5, now.timeIntervalSince1970)
            bindOptionalText(stmt, index: 6, value: source)
            sqlite3_bind_int(stmt, 7, globalMemoryEnabled ? 1 : 0)
            bindOptionalText(stmt, index: 8, value: parentSessionId)
            bindOptionalText(stmt, index: 9, value: parentToolUseId)
            let rc = sqlite3_step(stmt)
            memDiagLogger.info("[MemDiag] createSession INSERT step rc=\(rc) (101=DONE) sid=\(session.id.prefix(8))")
        } else {
            memDiagLogger.error("[MemDiag] createSession prepare FAILED sid=\(session.id.prefix(8))")
        }
        sqlite3_finalize(stmt)

        // Deliberately NOT marking the Session dirty here. A freshly-created
        // session has no messages yet — it's a placeholder the user may never
        // actually use. Syncing it to iCloud would leak ghost "New Chat /
        // No messages yet" rows to every signed-in device, visible forever
        // since we don't auto-delete empty sessions.
        //
        // iCloud upload is instead triggered by:
        //   - appendMessages() — marks Session dirty when the first message lands
        //   - updateSessionTitle() / toggleSessionPin() — explicit user intent
        //   - deleteSession() — tombstone upload
        // This way, only sessions with actual content or explicit user intent
        // propagate across devices.
        return session
    }

    // MARK: - part_flags (message preview bitmask)

    /// [T-ios-listsessions-part-flags] Bit positions in `messages.part_flags`.
    /// Only text/toolUse are tracked — those are the only types listSessions'
    /// preview picker cares about. mediaRef/toolResult intentionally set no bit
    /// (a user row with only toolResult parts stays flag 0, exactly matching the
    /// old `LIKE '%"type":"text"%'` filter that excluded tool_result-only rows).
    static let partFlagHasText: Int = 1      // bit0
    static let partFlagHasToolUse: Int = 2   // bit1

    /// Compute the part_flags bitmask from a decoded `[ContentPart]` (Swift
    /// write paths). Zero-cost: the caller is already iterating the parts.
    static func partFlags(for parts: [ContentPart]) -> Int {
        var flags = 0
        for part in parts {
            switch part {
            case .text(let s):
                // Match the old SQL: the LIKE only fired on the presence of a
                // text part, regardless of emptiness. Keep that (an empty text
                // part still set the bit under LIKE), so preview selection is
                // byte-for-byte identical.
                _ = s
                flags |= partFlagHasText
            case .toolUse:
                flags |= partFlagHasToolUse
            case .mediaRef, .toolResult:
                break
            }
        }
        return flags
    }

    /// Compute part_flags from a raw parts_json string (iCloud merge/backfill
    /// paths only have the JSON, not a decoded array). Uses the SAME
    /// substring test the old listSessions LIKE patterns used, so the derived
    /// flags exactly reproduce the previous behavior — including the JSON-key-
    /// order robustness of matching just `"type":"text"` / `"type":"toolUse"`.
    static func partFlags(fromPartsJSON json: String) -> Int {
        var flags = 0
        if json.contains("\"type\":\"text\"") { flags |= partFlagHasText }
        if json.contains("\"type\":\"toolUse\"") { flags |= partFlagHasToolUse }
        return flags
    }

    /// SQL expression that computes part_flags for a row in a pure-SQL
    /// INSERT…SELECT (the two remote-backfill paths). `col` is the qualified
    /// parts_json column reference (e.g. "rm.parts_json"). Mirrors
    /// `partFlags(fromPartsJSON:)` exactly, so SQL-inserted rows match Swift-
    /// inserted rows.
    static func partFlagsSQLExpr(_ col: String) -> String {
        "((CASE WHEN \(col) LIKE '%\"type\":\"text\"%' THEN \(partFlagHasText) ELSE 0 END) "
        + "| (CASE WHEN \(col) LIKE '%\"type\":\"toolUse\"%' THEN \(partFlagHasToolUse) ELSE 0 END))"
    }

    /// Total session count via a bare `COUNT(*)` — ~1ms even on a 100k-message
    /// DB, versus `listSessions().count` which runs 4 un-indexable
    /// `parts_json LIKE '%…%'` subqueries per session (~0.5s cold on a large
    /// DB). Callers that only need the number MUST use this: on the
    /// serialized ChatStore actor a full listSessions() head-of-line-blocks
    /// loadSession, which was the ~3s session-open stall
    /// [T-ios-session-coldload-listsessions-block].
    func sessionCount() -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sessions", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }
}
