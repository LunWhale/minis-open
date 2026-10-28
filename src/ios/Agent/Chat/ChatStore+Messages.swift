//
//  ChatStore+Messages.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore, message CRUD: append (single / batch), load, interrupted-tail
//  detection, delete, update parts, delete after a point.
//
//  Map of the ChatStore files: ChatStore.swift.
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

private let logger = AppLogger(category: "ChatStore")

extension ChatStore {
    // MARK: - Message CRUD

    func appendMessage(_ message: RawMessage) {
        appendMessages([message])
    }

    /// Batch-insert multiple messages in a single SQLite transaction.
    /// This reduces disk I/O by coalescing multiple writes into one fsync.
    func appendMessages(_ messages: [RawMessage]) {
        guard !messages.isEmpty else { return }
        // PER-SESSION: a batch can span sessions, so mark each one it touches.
        // Moved below the empty guard — an empty batch changes nothing and
        // should not invalidate at all.
        for sessionId in Set(messages.map(\.sessionId)) {
            invalidateSessionListCache(sessionId: sessionId)
        }
        // Drop assistant messages that carry no content the model could echo back —
        // a stream that aborts before producing any text or tool_use leaves an
        // assistant row with empty parts. On the next turn DeepSeek/OpenAI-compat
        // servers reject that history with `400 content or tool_calls must be set`.
        let messages = messages.filter { msg in
            guard msg.role == .assistant else { return true }
            return msg.parts.contains { part in
                switch part {
                case .text(let s): return !s.isEmpty
                case .toolUse, .toolResult, .mediaRef: return true
                }
            }
        }
        guard !messages.isEmpty else {
            logger.info("[Store] appendMessages: all messages dropped after empty-assistant filter")
            return
        }
        let dbOK = (db != nil)
        let firstSid = messages.first?.sessionId.prefix(8) ?? "?"
        logger.info("[Store] appendMessages enter count=\(messages.count) dbOpen=\(dbOK) sid=\(firstSid)")

        let sql = """
            INSERT INTO messages (id, session_id, role, parts_json, created_at, token_usage, sort_order, reasoning_content, stream_interrupt_count, updated_at, error_info, part_flags, model_id, model_display_name, provider_type, provider_instance_id, reasoning_echo)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

        exec("BEGIN TRANSACTION")

        var touchedSessions = Set<String>()
        for message in messages {
            let sortOrder = nextSortOrder(sessionId: message.sessionId)

            let partsJSON: String
            do {
                let data = try JSONEncoder().encode(message.parts)
                partsJSON = String(data: data, encoding: .utf8) ?? "[]"
            } catch {
                logger.error("Failed to encode message parts: \(error)")
                continue
            }
            // [T-ios-listsessions-part-flags] derived from the parts we just encoded.
            let partFlags = Self.partFlags(for: message.parts)

            let usageJSON: String?
            if let usage = message.tokenUsage {
                usageJSON = (try? JSONEncoder().encode(usage)).flatMap { String(data: $0, encoding: .utf8) }
            } else {
                usageJSON = nil
            }

            var stmt: OpaquePointer?
            let prepRC = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            if prepRC == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (message.id as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (message.sessionId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (message.role.rawValue as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (partsJSON as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 5, message.createdAt.timeIntervalSince1970)
                bindOptionalText(stmt, index: 6, value: usageJSON)
                sqlite3_bind_int64(stmt, 7, Int64(sortOrder))
                bindOptionalText(stmt, index: 8, value: message.reasoningContent)
                sqlite3_bind_int64(stmt, 9, Int64(message.streamInterruptCount))
                sqlite3_bind_double(stmt, 10, message.createdAt.timeIntervalSince1970)
                bindOptionalText(stmt, index: 11, value: message.errorInfo)  // [T-error-persist-ios]
                sqlite3_bind_int64(stmt, 12, Int64(partFlags))  // [T-ios-listsessions-part-flags]
                // [T-token-attribution-snapshot] Written from the message the
                // caller built, which carries the model that actually served
                // the turn. Never re-read from the session here — failover can
                // already have repointed it.
                bindOptionalText(stmt, index: 13, value: message.modelId)
                bindOptionalText(stmt, index: 14, value: message.modelDisplayName)
                bindOptionalText(stmt, index: 15, value: message.providerType)
                bindOptionalText(stmt, index: 16, value: message.providerInstanceId)
                // [T-responses-echo-persist]
                bindOptionalText(stmt, index: 17, value: message.reasoningEchoJSON)
                let stepRC = sqlite3_step(stmt)
                if stepRC != SQLITE_DONE {
                    let errMsg = String(cString: sqlite3_errmsg(db))
                    logger.error("[Store] INSERT step failed rc=\(stepRC) sid=\(message.sessionId.prefix(8)) mid=\(message.id.prefix(8)) so=\(sortOrder) err=\(errMsg)")
                } else {
                    logger.info("[Store] INSERT ok sid=\(message.sessionId.prefix(8)) mid=\(message.id.prefix(8)) so=\(sortOrder) role=\(message.role.rawValue)")
                }
            } else {
                let errMsg = String(cString: sqlite3_errmsg(db))
                logger.error("[Store] INSERT prepare failed rc=\(prepRC) sid=\(message.sessionId.prefix(8)) err=\(errMsg)")
            }
            sqlite3_finalize(stmt)

            // [T-ios-listsessions-perf] Fold this message into the session's
            // stored preview while its parts and sort_order are in hand — the
            // work listSessions used to redo for every session on every
            // refresh. Inside the same transaction as the INSERT, so the row
            // and its preview can never disagree after a crash.
            updateStoredPreview(
                sessionId: message.sessionId, parts: message.parts,
                partsJSON: partsJSON, role: message.role, sortOrder: sortOrder
            )

            touchedSessions.insert(message.sessionId)
            // Always write dirty mark to DB immediately (crash-safe).
            // Only the CloudKit upload trigger (scheduleSend) is deferred.
            markDirty(recordType: "Message", recordId: message.id)
        }

        // Touch sessions once per session
        for sessionId in touchedSessions {
            touchSession(sessionId)
            markDirty(recordType: "Session", recordId: sessionId)
            // Track for file scanning on flush
            pendingSyncSessionIds.insert(sessionId)
        }

        exec("COMMIT")

        // Prune oldest messages if any session exceeds the threshold
        for sessionId in touchedSessions {
            pruneOldMessages(sessionId: sessionId)
        }

        // Post notifications after commit
        for sessionId in touchedSessions {
            NotificationCenter.default.post(name: .sessionDidUpdate, object: sessionId)
        }
    }

    /// Diagnostic helper: returns (count, maxSortOrder) for a session. Used to detect
    /// silent write failures where appendMessage returns but the DB row never lands.
    func sessionWriteStats(sessionId: String) -> (count: Int, maxSortOrder: Int) {
        let sql = "SELECT COUNT(*), COALESCE(MAX(sort_order), -1) FROM messages WHERE session_id = ?"
        var stmt: OpaquePointer?
        var count = 0
        var maxSo = -1
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(stmt, 0))
                maxSo = Int(sqlite3_column_int64(stmt, 1))
            }
        }
        sqlite3_finalize(stmt)
        return (count, maxSo)
    }

    func loadMessages(sessionId: String) -> [RawMessage] {
        let totalStart = CFAbsoluteTimeGetCurrent()
        let sql = """
            SELECT id, session_id, role, parts_json, created_at, token_usage, reasoning_content, stream_interrupt_count, sort_order, error_info, model_id, model_display_name, provider_type, provider_instance_id, reasoning_echo
            FROM messages WHERE session_id = ? ORDER BY sort_order ASC, created_at ASC, id ASC
        """
        var stmt: OpaquePointer?
        var messages: [RawMessage] = []
        var jsonDecodeTime: Double = 0

        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if prepareResult == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let sessId = String(cString: sqlite3_column_text(stmt, 1))
                let roleStr = String(cString: sqlite3_column_text(stmt, 2))
                let partsStr = String(cString: sqlite3_column_text(stmt, 3))
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                let usageStr = sqlite3_column_text(stmt, 5).map { String(cString: $0) }

                guard let role = MessageRole(rawValue: roleStr) else { continue }

                let decodeStart = CFAbsoluteTimeGetCurrent()
                let parts: [ContentPart]
                if let data = partsStr.data(using: .utf8) {
                    parts = (try? JSONDecoder().decode([ContentPart].self, from: data)) ?? []
                } else {
                    parts = []
                }

                let tokenUsage: StoredTokenUsage?
                if let usageData = usageStr?.data(using: .utf8) {
                    tokenUsage = try? JSONDecoder().decode(StoredTokenUsage.self, from: usageData)
                } else {
                    tokenUsage = nil
                }
                jsonDecodeTime += CFAbsoluteTimeGetCurrent() - decodeStart

                let reasoningContent = sqlite3_column_text(stmt, 6).map { String(cString: $0) }

                let streamInterruptCount = Int(sqlite3_column_int64(stmt, 7))
                let sortOrder = Int(sqlite3_column_int64(stmt, 8))
                let errorInfo = sqlite3_column_text(stmt, 9).map { String(cString: $0) }  // [T-error-persist-ios]
                var msg = RawMessage(
                    id: id, sessionId: sessId, role: role, parts: parts,
                    createdAt: createdAt, tokenUsage: tokenUsage,
                    reasoningContent: reasoningContent,
                    streamInterruptCount: streamInterruptCount
                )
                msg.sortOrder = sortOrder
                msg.errorInfo = errorInfo
                // [T-token-attribution-snapshot] Hydrated because backup export
                // serializes RawMessage straight through — dropping these here
                // would silently strip attribution from every exported package.
                msg.modelId = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
                msg.modelDisplayName = sqlite3_column_text(stmt, 11).map { String(cString: $0) }
                // [T-responses-echo-persist] Rehydrate the native reasoning
                // head so a reopened session can replay REAL server-minted ids
                // instead of falling back to the id-less placeholder.
                msg.reasoningEchoJSON = sqlite3_column_text(stmt, 14).map { String(cString: $0) }
                msg.providerType = sqlite3_column_text(stmt, 12).map { String(cString: $0) }
                msg.providerInstanceId = sqlite3_column_text(stmt, 13).map { String(cString: $0) }
                messages.append(msg)
            }
        } else {
            let errMsg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
            logger.error("[ChatStore.loadMessages] sqlite3_prepare_v2 FAILED for session \(sessionId): \(errMsg) (code=\(prepareResult))")
            // Fallback: try simpler query without newer migration columns
            sqlite3_finalize(stmt)
            stmt = nil
            let fallbackSql = """
                SELECT id, session_id, role, parts_json, created_at, token_usage
                FROM messages WHERE session_id = ? ORDER BY sort_order ASC, created_at ASC, id ASC
            """
            if sqlite3_prepare_v2(db, fallbackSql, -1, &stmt, nil) == SQLITE_OK {
                logger.info("[ChatStore.loadMessages] Fallback query succeeded for session \(sessionId)")
                sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let sessId = String(cString: sqlite3_column_text(stmt, 1))
                    let roleStr = String(cString: sqlite3_column_text(stmt, 2))
                    let partsStr = String(cString: sqlite3_column_text(stmt, 3))
                    let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                    let usageStr = sqlite3_column_text(stmt, 5).map { String(cString: $0) }

                    guard let role = MessageRole(rawValue: roleStr) else { continue }

                    let decodeStart = CFAbsoluteTimeGetCurrent()
                    let parts: [ContentPart]
                    if let data = partsStr.data(using: .utf8) {
                        parts = (try? JSONDecoder().decode([ContentPart].self, from: data)) ?? []
                    } else {
                        parts = []
                    }
                    let tokenUsage: StoredTokenUsage?
                    if let usageData = usageStr?.data(using: .utf8) {
                        tokenUsage = try? JSONDecoder().decode(StoredTokenUsage.self, from: usageData)
                    } else {
                        tokenUsage = nil
                    }
                    jsonDecodeTime += CFAbsoluteTimeGetCurrent() - decodeStart

                    messages.append(RawMessage(
                        id: id, sessionId: sessId, role: role, parts: parts,
                        createdAt: createdAt, tokenUsage: tokenUsage,
                        reasoningContent: nil,
                        streamInterruptCount: 0
                    ))
                }
            } else {
                let fallbackErr = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
                logger.error("[ChatStore.loadMessages] Fallback query ALSO FAILED for session \(sessionId): \(fallbackErr)")
            }
        }
        sqlite3_finalize(stmt)

        let totalElapsed = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
        let jsonElapsed = jsonDecodeTime * 1000
        // Only report loads that are actually slow. This fired on every
        // loadMessages regardless of duration, and the overwhelming majority are
        // a few milliseconds — noise that buries the outliers worth seeing.
        if totalElapsed > 20 {
            logger.info("[ChatStore.loadMessages] \(sessionId) — \(messages.count) messages in \(String(format: "%.1f", totalElapsed))ms (JSON decode: \(String(format: "%.1f", jsonElapsed))ms, SQL+IO: \(String(format: "%.1f", totalElapsed - jsonElapsed))ms)")
        }

        // DIAG: Detect sortOrder anomalies (duplicates, gaps). Small cost — O(n) scan.
        // loadMessages doesn't populate sortOrder on RawMessage, so re-query it.
        var sortOrders: [Int] = []
        let soSql = "SELECT sort_order FROM messages WHERE session_id = ? ORDER BY sort_order ASC, created_at ASC, id ASC"
        var soStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, soSql, -1, &soStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(soStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(soStmt) == SQLITE_ROW {
                sortOrders.append(Int(sqlite3_column_int64(soStmt, 0)))
            }
        }
        sqlite3_finalize(soStmt)
        if !sortOrders.isEmpty {
            let uniq = Set(sortOrders)
            let dupCount = sortOrders.count - uniq.count
            let minSo = sortOrders.first!
            let maxSo = sortOrders.last!
            let expectedIfDense = maxSo - minSo + 1
            let gaps = expectedIfDense - sortOrders.count
            if dupCount > 0 || gaps > 0 {
                // Count duplicates per sortOrder value
                var counts: [Int: Int] = [:]
                for so in sortOrders { counts[so, default: 0] += 1 }
                let dupSamples = counts.filter { $0.value > 1 }.sorted(by: { $0.key < $1.key }).prefix(20)
                let dupStr = dupSamples.map { "\($0.key)×\($0.value)" }.joined(separator: ",")
                logger.error("[SortOrder] ANOMALY sid=\(sessionId.prefix(8)) count=\(sortOrders.count) uniq=\(uniq.count) dup=\(dupCount) min=\(minSo) max=\(maxSo) gaps=\(gaps)")
                logger.error("[SortOrder] duplicates (first 20): \(dupStr)")
                // Dump first 15 and last 5 sortOrder values to see structure
                let headSO = sortOrders.prefix(15).map(String.init).joined(separator: ",")
                let tailSO = sortOrders.suffix(5).map(String.init).joined(separator: ",")
                logger.error("[SortOrder] head 15: \(headSO)")
                logger.error("[SortOrder] tail 5:  \(tailSO)")
            }
            // The healthy branch used to log an "[SortOrder] OK …" line on every
            // loadMessages — 6,628 lines in a single day (2026-08-11), the
            // largest single source of log noise. The ANOMALY branch above is
            // what carries signal: duplicates and gaps are real data problems.
        }

        return messages
    }

    /// [T-ios-session-paused-badge-hardkill] Returns the set of session ids whose
    /// agent loop was left interrupted, derived purely from the persisted message
    /// tail — so it survives a hard kill (jetsam/SIGKILL) where the background-
    /// task expiry handler never ran to push the `.paused` badge.
    ///
    /// Lightweight: fetches ONLY the last message row per session (one query with
    /// a correlated max(sort_order) subquery), not the full history. Applies the
    /// SAME predicate as `AIChatViewModel.loadSession`'s interrupted-agent-loop
    /// detection (kept in sync intentionally):
    ///   - last row is a user message of ALL toolResult parts (tools ran, the
    ///     next model call never happened), OR
    ///   - last row is the synthetic "Continue" stop message, OR
    ///   - last row is an assistant message containing a toolUse (model asked for
    ///     tools that never executed).
    func interruptedSessionIds() -> Set<String> {
        Set(interruptedSessionsWithTailDate().keys)
    }

    /// [T-ios-group-pause-badge-reconcile-stamp] Same scan as
    /// `interruptedSessionIds`, but each id carries the `created_at` of the
    /// interrupted tail message — i.e. WHEN the session was left hanging.
    ///
    /// The badge store needs this because reconcile is the only writer that can
    /// see a session's paused state without having witnessed the interruption:
    /// after a hard kill (or on the first launch after the freshness window
    /// shipped) it restores the marker for sessions interrupted arbitrarily long
    /// ago. Stamping those `Date()` declares a days-old pause "just happened",
    /// which is exactly what kept stale badges lighting their group cards. The
    /// tail's own timestamp is the real entry time and is already in the row we
    /// read, so recovering it costs one extra column, not another query.
    func interruptedSessionsWithTailDate() -> [String: Date] {
        // Last row per session = the message with the maximum (sort_order,
        // created_at, id) ordering used everywhere else. Correlated subquery on
        // sort_order is enough in practice; ties are vanishingly rare and a
        // mis-pick there only changes a transient badge, never data.
        let sql = """
            SELECT m.session_id, m.role, m.parts_json, m.created_at
            FROM messages m
            WHERE m.sort_order = (
                SELECT MAX(m2.sort_order) FROM messages m2 WHERE m2.session_id = m.session_id
            )
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let err = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
            logger.error("[ChatStore.interruptedSessionIds] prepare failed: \(err)")
            return [:]
        }

        var result: [String: Date] = [:]
        // A session can have >1 row sharing the max sort_order (tie); take the
        // last one seen, mirroring the ASC ordering's final element.
        var lastBySession: [String: (role: MessageRole, parts: [ContentPart], createdAt: Double)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sid = String(cString: sqlite3_column_text(stmt, 0))
            let roleStr = String(cString: sqlite3_column_text(stmt, 1))
            let partsStr = String(cString: sqlite3_column_text(stmt, 2))
            let createdAt = sqlite3_column_double(stmt, 3)
            guard let role = MessageRole(rawValue: roleStr) else { continue }
            let parts: [ContentPart] = partsStr.data(using: .utf8)
                .flatMap { try? JSONDecoder().decode([ContentPart].self, from: $0) } ?? []
            lastBySession[sid] = (role, parts, createdAt)
        }

        for (sid, entry) in lastBySession {
            if Self.isInterruptedTail(role: entry.role, parts: entry.parts) {
                // created_at of 0 (or a garbage row) would read as 1970 and make
                // the badge permanently stale rather than permanently fresh —
                // the safe direction, but still wrong, so fall back to "now" and
                // let the normal window govern it.
                result[sid] = entry.createdAt > 0
                    ? Date(timeIntervalSince1970: entry.createdAt)
                    : Date()
            }
        }
        logger.info("[ChatStore.interruptedSessionIds] scanned \(lastBySession.count) sessions → \(result.count) interrupted")
        return result
    }

    /// [T-ios-session-paused-badge-hardkill] The interrupted-tail predicate,
    /// factored out so it stays identical to `loadSession`'s inline logic. Keep
    /// the two in sync if either changes.
    static func isInterruptedTail(role: MessageRole, parts: [ContentPart]) -> Bool {
        if role == .user {
            let allToolResults = !parts.isEmpty && parts.allSatisfy {
                if case .toolResult = $0 { return true }; return false
            }
            let isContinueMessage = parts.count == 1 && {
                if case .text(let t) = parts.first,
                   t.contains("The user stopped the previous response") {
                    return true
                }
                return false
            }()
            return allToolResults || isContinueMessage
        } else if role == .assistant {
            return parts.contains {
                if case .toolUse = $0 { return true }; return false
            }
        }
        return false
    }

    func deleteMessages(sessionId: String) {
        // PER-SESSION: empties one session's messages, changing its preview.
        // The session row itself stays in the list.
        invalidateSessionListCache(sessionId: sessionId)
        // [T-ios-listsessions-perf] Every message is going, so the stored
        // preview must go with it — otherwise the sidebar keeps showing the
        // text of a message that no longer exists. Empty string, not NULL:
        // NULL means "never computed" and would send this row back through
        // the slow backfill path on the next refresh (see listSessions).
        defer { storePreview(sessionId: sessionId, text: "", sortOrder: nil) }
        // Mark every message dirty for cloud deletion BEFORE the DELETE so other
        // devices remove them on next sync. Without this, Clear Chat wipes
        // locally but iCloud re-hydrates the rows on the next pull.
        let selSql = "SELECT id FROM messages WHERE session_id = ?"
        var selStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, selSql, -1, &selStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(selStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(selStmt) == SQLITE_ROW {
                let msgId = String(cString: sqlite3_column_text(selStmt, 0))
                markDirty(recordType: "Message", recordId: msgId, operation: "delete")
            }
        }
        sqlite3_finalize(selStmt)

        let sql = "DELETE FROM messages WHERE session_id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// [T-ios-rerun-from-tool-block-position] Rewrite a single message row's
    /// parts in place. Used by retryFromToolBlock's sub-message cut: when the
    /// re-run anchor is a tool_use that is NOT the first block of its assistant
    /// turn, we keep the earlier blocks and must persist the trimmed parts back
    /// to that exact row (deleteMessagesAfter only drops whole rows after the
    /// boundary; it does not rewrite a kept row). Mirrors appendMessage's
    /// parts_json encoding.
    func updateMessageParts(messageId: String, parts: [ContentPart]) {
        // PER-SESSION: the row's session is resolved here once and reused by
        // the preview recompute at the end. This runs on every assistant-turn
        // finalize — the hottest path after appendMessages — and a FULL
        // rebuild here would re-mint every ChatSession value each turn,
        // undoing the incremental patch on exactly the path it exists for.
        // Falls back to FULL only if the row cannot be resolved.
        let previewSession = sessionIdForMessage(messageId)
        if let sid = previewSession {
            // PER-SESSION: parts rewrite on a known session.
            invalidateSessionListCache(sessionId: sid)
        } else {
            // FULL: row could not be resolved — conservative fallback.
            invalidateSessionListCache()
        }
        let partsJSON: String
        do {
            let data = try JSONEncoder().encode(parts)
            partsJSON = String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            logger.error("[updateMessageParts] encode failed id=\(messageId.prefix(8)): \(error)")
            return
        }
        // [T-ios-listsessions-part-flags] keep the bitmask in lockstep with parts_json.
        let partFlags = Self.partFlags(for: parts)
        let sql = "UPDATE messages SET parts_json = ?, updated_at = ?, part_flags = ? WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (partsJSON as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 3, Int64(partFlags))
            sqlite3_bind_text(stmt, 4, (messageId as NSString).utf8String, -1, nil)
            let rc = sqlite3_step(stmt)
            logger.info("[updateMessageParts] id=\(messageId.prefix(8)) parts=\(parts.count) stepRC=\(rc)")
        }
        sqlite3_finalize(stmt)
        // Mark dirty so the rewritten row syncs to iCloud.
        markDirty(recordType: "Message", recordId: messageId)
        // [T-ios-listsessions-perf] Rewriting a message's parts can change the
        // preview in either direction (text replaced, or emptied out), so
        // recompute rather than fold forward.
        if let sid = previewSession { recomputeStoredPreview(sessionId: sid) }
    }

    /// Delete all message rows AFTER the first `keepCount` rows (ordered by
    /// sort_order). Callers pass `agentHistory.count` meaning "keep the first N
    /// rows"; they do NOT pass a sort_order value.
    ///
    /// [T-19-chat-content-lost-34328] This used to treat `keepCount` directly as
    /// the sort_order cutoff (`DELETE WHERE sort_order >= keepCount`). That is
    /// only correct when sort_order is dense and 0-based (0..count-1). After a
    /// prune drops the oldest rows, min(sort_order) > 0 and the live range
    /// shifts right, so `keepCount` (a row COUNT) no longer equals
    /// `max(sort_order)+1`. A real session hit this: keepCount=2048 while
    /// maxSortOrder=2703 → the old `>= 2048` predicate nuked 656 still-live
    /// recent messages (count 2048→1392) — silent user-data loss on resend/edit.
    ///
    /// Fix: resolve the ACTUAL boundary sort_order = the sort_order of the
    /// keepCount-th row (ascending, 1-based), then delete strictly AFTER it.
    /// This is correct regardless of whether sort_order is dense or shifted.
    func deleteMessagesAfter(sessionId: String, keepCount: Int) {
        // PER-SESSION: truncates one session's tail, changing its preview only.
        invalidateSessionListCache(sessionId: sessionId)
        // [T-ios-listsessions-perf] A truncation can delete the very message
        // the preview came from, so the preview has to move BACKWARDS. The
        // incremental rule only ever moves it forward, so recompute here.
        defer { recomputeStoredPreview(sessionId: sessionId) }
        // DIAG: snapshot state before delete
        let beforeStats = sessionWriteStats(sessionId: sessionId)
        logger.warning("[EditSync] [DeleteAfter] ENTER sid=\(sessionId.prefix(8)) keepCount=\(keepCount) — before: count=\(beforeStats.count) maxSortOrder=\(beforeStats.maxSortOrder)")

        // keepCount <= 0 → keep nothing: delete every row. Use a boundary of
        // Int64.min so `sort_order > boundary` matches all rows.
        // Otherwise resolve the keepCount-th row's sort_order (OFFSET keepCount-1,
        // ascending). If there are <= keepCount rows, the SELECT returns no row
        // and we delete nothing.
        var boundarySortOrder: Int64? = nil  // nil → no row to delete after; keep all
        var deleteAll = false
        if keepCount <= 0 {
            deleteAll = true
        } else {
            // ORDER BY must match loadMessages / the repair canonical order
            // (sort_order ASC, created_at ASC, id ASC). sort_order CAN have
            // duplicates between repairs (remote-merge races; the prune path
            // even documents itself as "immune to sort_order duplicates"), so a
            // single-key sort could pick a different keepCount-th row than the
            // one the caller counted in agentHistory. Tie-breaking on
            // (created_at, id) keeps the boundary row identical to the caller's
            // view. The DELETE below still filters on `sort_order >`, so if the
            // boundary row shares its sort_order with later rows those rows are
            // NOT deleted — i.e. duplicates make truncation conservative (keep
            // more), never destructive.
            let boundarySql = """
                SELECT sort_order FROM messages
                WHERE session_id = ?
                ORDER BY sort_order ASC, created_at ASC, id ASC
                LIMIT 1 OFFSET ?
                """
            var bStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, boundarySql, -1, &bStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(bStmt, 1, (sessionId as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(bStmt, 2, Int64(keepCount - 1))
                if sqlite3_step(bStmt) == SQLITE_ROW {
                    boundarySortOrder = sqlite3_column_int64(bStmt, 0)
                }
            }
            sqlite3_finalize(bStmt)
            // No keepCount-th row exists (session has <= keepCount rows): nothing
            // is after the kept set, so there is nothing to delete.
            if boundarySortOrder == nil {
                logger.warning("[EditSync] [DeleteAfter] DONE sid=\(sessionId.prefix(8)) keepCount=\(keepCount) — session has \(beforeStats.count) rows (<= keepCount), nothing to delete")
                return
            }
        }

        // Mark deleted messages for iCloud sync removal before deleting locally.
        let selectSql = deleteAll
            ? "SELECT id FROM messages WHERE session_id = ?"
            : "SELECT id FROM messages WHERE session_id = ? AND sort_order > ?"
        var selectStmt: OpaquePointer?
        var toDelete: [String] = []
        if sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(selectStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            if let boundary = boundarySortOrder {
                sqlite3_bind_int64(selectStmt, 2, boundary)
            }
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                let msgId = String(cString: sqlite3_column_text(selectStmt, 0))
                toDelete.append(msgId)
                markDirty(recordType: "Message", recordId: msgId, operation: "delete")
                logger.warning("[EditSync] markDirty Message id=\(msgId.prefix(8)) op=delete — will push tombstone")
            }
        }
        sqlite3_finalize(selectStmt)

        let sql = deleteAll
            ? "DELETE FROM messages WHERE session_id = ?"
            : "DELETE FROM messages WHERE session_id = ? AND sort_order > ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            if let boundary = boundarySortOrder {
                sqlite3_bind_int64(stmt, 2, boundary)
            }
            sqlite3_step(stmt)
        }
        let deletedRows = Int(sqlite3_changes(db))
        sqlite3_finalize(stmt)

        let afterStats = sessionWriteStats(sessionId: sessionId)
        let boundaryDesc = deleteAll ? "ALL" : String(boundarySortOrder ?? -1)
        logger.warning("[EditSync] [DeleteAfter] DONE sid=\(sessionId.prefix(8)) keepCount=\(keepCount) boundarySortOrder=\(boundaryDesc) deletedRows=\(deletedRows) toDeleteMarked=\(toDelete.count) — after: count=\(afterStats.count) maxSortOrder=\(afterStats.maxSortOrder)")
        if deletedRows > 0 {
            let idSample = toDelete.prefix(10).map { String($0.prefix(8)) }.joined(separator: ",")
            logger.warning("[EditSync] [DeleteAfter] deleted msg ids (first 10): \(idSample) — these tombstones should appear in next SyncCore outbound batch.deletes")
        }
    }
}
