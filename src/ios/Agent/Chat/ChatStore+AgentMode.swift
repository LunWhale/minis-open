//
//  ChatStore+AgentMode.swift
//  Minis
//
//  [T-minimal-mode] Persistence for a session's `AgentMode`.
//
//  Mirrors `setMemoryEnabled` / `getMemoryEnabled` deliberately: a second stored
//  session flag should not invent a second storage mechanism.
//
//  The mode is written once, while the session is still empty, and is immutable
//  afterwards. `setAgentMode` therefore refuses to change a mode that is already
//  `minimal`, and refuses to set one on a session that already has messages —
//  that refusal is the invariant, so it lives here rather than only in the UI.
//

import Foundation
import SQLite3

extension ChatStore {

    /// The mode stored for a session, or `.normal` when the row or column is
    /// missing (a session created before minimal mode existed).
    func agentMode(sessionId: String) -> AgentMode {
        let sql = "SELECT agent_mode FROM sessions WHERE id = ?"
        var stmt: OpaquePointer?
        var mode = AgentMode.normal
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW,
               let cstr = sqlite3_column_text(stmt, 0) {
                mode = AgentMode(rawValue: String(cString: cstr)) ?? .normal
            }
        }
        sqlite3_finalize(stmt)
        return mode
    }

    /// How many messages a session already holds.
    ///
    /// Used for the lock: a mode chosen while the thread is empty is the only
    /// honest moment to choose it, because the schema and system prompt that the
    /// existing turns were produced under cannot be retroactively changed.
    func messageCount(sessionId: String) -> Int {
        let sql = "SELECT COUNT(*) FROM messages WHERE session_id = ?"
        var stmt: OpaquePointer?
        var n = 0
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW { n = Int(sqlite3_column_int(stmt, 0)) }
        }
        sqlite3_finalize(stmt)
        return n
    }

    /// Why a requested mode change was refused, or nil when it was applied.
    enum AgentModeChangeResult: Equatable {
        case applied
        /// The session is already minimal — the mode is locked for good.
        case lockedMinimal
        /// The session already has messages, so the mode can no longer change.
        case threadStarted
        /// The session id does not exist (yet).
        case noSuchSession
    }

    @discardableResult
    func setAgentMode(sessionId: String, mode: AgentMode) -> AgentModeChangeResult {
        let current = agentMode(sessionId: sessionId)

        // Idempotent no-op: re-selecting the mode you already have is fine and
        // must not report a lock, or `/minimal` twice would look like an error.
        if current == mode { return .applied }

        // The one-way door. Deliberately checked before the message count so the
        // message the user gets is the real reason ("locked"), not a symptom.
        if current == .minimal { return .lockedMinimal }
        if messageCount(sessionId: sessionId) > 0 { return .threadStarted }

        let sql = "UPDATE sessions SET agent_mode = ? WHERE id = ?"
        var stmt: OpaquePointer?
        var updated = false
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (mode.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, nil)
            updated = sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) > 0
        }
        sqlite3_finalize(stmt)
        if !updated { return .noSuchSession }

        // The sidebar shows the mode, so the list cache must not keep serving a
        // row that still says "normal".
        invalidateSessionListCache()
        return .applied
    }
}
