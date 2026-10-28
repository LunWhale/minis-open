//
//  ChatStore+SessionQueries.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore, session reads and small updates: the metadata / message queries
//  behind the agent's sessions tools (querySessionsMeta, searchMessages,
//  loadMessagePage), counts, scheduled-fire messages, getSession, and model /
//  title / pin updates.
//
//  Map of the ChatStore files: ChatStore.swift.
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

extension ChatStore {
    // MARK: - Sessions Get Tool

    /// Lightweight session metadata for the minis-sessions-cli offload.
    struct SessionMeta {
        let id: String
        let title: String?
        let preview: String?
        let source: String?
        let startedAt: Date
        let lastActive: Date
        let messageCount: Int
    }

    /// Query sessions with optional filtering by IDs and keywords, ordered by updatedAt DESC.
    func querySessionsMeta(sessionIds: [String]? = nil, keywords: [String]? = nil, limit: Int = 100, startDate: Date? = nil, endDate: Date? = nil) -> [SessionMeta] {
        var conditions: [String] = []
        var bindings: [(Int32, String)] = []
        var doubleBindings: [(Int32, Double)] = []
        var bindIndex: Int32 = 1

        // Filter by session IDs
        if let ids = sessionIds, !ids.isEmpty {
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            conditions.append("s.id IN (\(placeholders))")
            for id in ids {
                bindings.append((bindIndex, id))
                bindIndex += 1
            }
        }

        // Filter by date range
        if let start = startDate {
            conditions.append("s.updated_at >= ?")
            doubleBindings.append((bindIndex, start.timeIntervalSince1970))
            bindIndex += 1
        }
        if let end = endDate {
            conditions.append("s.updated_at <= ?")
            doubleBindings.append((bindIndex, end.timeIntervalSince1970))
            bindIndex += 1
        }

        // Filter by keywords (AND: all keywords must match in title or message content)
        if let kws = keywords, !kws.isEmpty {
            for kw in kws {
                let pattern = "%\(kw)%"
                conditions.append("(s.title LIKE ? OR EXISTS (SELECT 1 FROM messages m WHERE m.session_id = s.id AND m.parts_json LIKE ?))")
                bindings.append((bindIndex, pattern))
                bindIndex += 1
                bindings.append((bindIndex, pattern))
                bindIndex += 1
            }
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
            SELECT s.id, s.title,
                   (SELECT m2.parts_json FROM messages m2
                    WHERE m2.session_id = s.id AND m2.role = 'user'
                    ORDER BY m2.sort_order ASC LIMIT 1) AS first_user_msg,
                   s.source, s.created_at, s.updated_at,
                   (SELECT COUNT(*) FROM messages m3 WHERE m3.session_id = s.id) AS msg_count
            FROM sessions s
            \(whereClause)
            ORDER BY s.updated_at DESC
            LIMIT ?
        """

        var stmt: OpaquePointer?
        var results: [SessionMeta] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for (idx, value) in bindings {
                sqlite3_bind_text(stmt, idx, (value as NSString).utf8String, -1, nil)
            }
            for (idx, value) in doubleBindings {
                sqlite3_bind_double(stmt, idx, value)
            }
            sqlite3_bind_int(stmt, bindIndex, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let firstUserPartsJSON = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let source = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                let msgCount = Int(sqlite3_column_int(stmt, 6))

                let preview = firstUserPartsJSON.flatMap { extractTextFromPartsJSON($0) }
                let previewTruncated = preview.map { String($0.prefix(60)) }

                results.append(SessionMeta(
                    id: id, title: title, preview: previewTruncated, source: source,
                    startedAt: createdAt, lastActive: updatedAt, messageCount: msgCount
                ))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    /// Search messages across sessions, returning up to `limit` matching messages with keyword-context snippets (max 600 chars each).
    func searchMessages(sessionIds: [String]? = nil, keywords: [String], limit: Int = 50, startDate: Date? = nil, endDate: Date? = nil) -> [(sessionId: String, sessionTitle: String?, messageId: String, role: String, createdAt: Date, snippet: String)] {
        guard !keywords.isEmpty else { return [] }

        var conditions: [String] = ["m.parts_json LIKE ?"]
        var bindings: [(Int32, String)] = []
        var doubleBindings: [(Int32, Double)] = []
        var bindIndex: Int32 = 1

        // First keyword for initial filter
        bindings.append((bindIndex, "%\(keywords[0])%"))
        bindIndex += 1

        // Additional keyword conditions
        for kw in keywords.dropFirst() {
            conditions.append("m.parts_json LIKE ?")
            bindings.append((bindIndex, "%\(kw)%"))
            bindIndex += 1
        }

        if let ids = sessionIds, !ids.isEmpty {
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            conditions.append("m.session_id IN (\(placeholders))")
            for id in ids {
                bindings.append((bindIndex, id))
                bindIndex += 1
            }
        }

        // Filter by date range
        if let start = startDate {
            conditions.append("m.created_at >= ?")
            doubleBindings.append((bindIndex, start.timeIntervalSince1970))
            bindIndex += 1
        }
        if let end = endDate {
            conditions.append("m.created_at <= ?")
            doubleBindings.append((bindIndex, end.timeIntervalSince1970))
            bindIndex += 1
        }

        let whereClause = conditions.joined(separator: " AND ")
        // [T-search-cli-title] LEFT JOIN sessions so each hit can report its
        // owning session's title to minis-sessions-cli — otherwise the CLI
        // user sees only session_id values and can't tell which conversation
        // a hit belongs to. LEFT JOIN (not INNER) so a stray message whose
        // session row is missing still surfaces with sessionTitle=nil rather
        // than vanishing from the result set.
        let sql = """
            SELECT m.session_id, s.title, m.id, m.role, m.created_at, m.parts_json
            FROM messages m
            LEFT JOIN sessions s ON s.id = m.session_id
            WHERE \(whereClause)
            ORDER BY m.created_at DESC
            LIMIT ?
        """

        var stmt: OpaquePointer?
        var results: [(sessionId: String, sessionTitle: String?, messageId: String, role: String, createdAt: Date, snippet: String)] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for (idx, value) in bindings {
                sqlite3_bind_text(stmt, idx, (value as NSString).utf8String, -1, nil)
            }
            for (idx, value) in doubleBindings {
                sqlite3_bind_double(stmt, idx, value)
            }
            // Over-fetch to compensate for rows filtered out due to empty text extraction
            sqlite3_bind_int(stmt, bindIndex, Int32(limit * 3))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let sessionId = String(cString: sqlite3_column_text(stmt, 0))
                let sessionTitle: String? = {
                    guard sqlite3_column_type(stmt, 1) != SQLITE_NULL else { return nil }
                    let s = String(cString: sqlite3_column_text(stmt, 1))
                    return s.isEmpty ? nil : s
                }()
                let messageId = String(cString: sqlite3_column_text(stmt, 2))
                let role = String(cString: sqlite3_column_text(stmt, 3))
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                let partsJSON = String(cString: sqlite3_column_text(stmt, 5))

                let fullText = extractTextFromPartsJSON(partsJSON) ?? ""
                // Skip messages where keyword matched in non-text parts (tool_use JSON, etc.)
                guard !fullText.isEmpty else { continue }
                let snippet = Self.keywordSnippet(from: fullText, keywords: keywords, maxLength: 600)
                guard !snippet.isEmpty else { continue }

                results.append((sessionId: sessionId, sessionTitle: sessionTitle, messageId: messageId, role: role, createdAt: createdAt, snippet: snippet))
                if results.count >= limit { break }
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    /// Extract a snippet around the first keyword match, up to maxLength characters.
    private static func keywordSnippet(from text: String, keywords: [String], maxLength: Int) -> String {
        guard !text.isEmpty else { return "" }
        let lower = text.lowercased()

        // Find earliest keyword match position
        var earliest = text.count
        for kw in keywords {
            if let range = lower.range(of: kw.lowercased()) {
                let pos = text.distance(from: text.startIndex, to: range.lowerBound)
                earliest = min(earliest, pos)
            }
        }

        if earliest == text.count {
            // No match found in extracted text, return head
            return String(text.prefix(maxLength))
        }

        // Center snippet around the match
        let halfWindow = maxLength / 2
        let start = max(0, earliest - halfWindow)
        let startIdx = text.index(text.startIndex, offsetBy: start)
        let endIdx = text.index(startIdx, offsetBy: min(maxLength, text.distance(from: startIdx, to: text.endIndex)))
        var snippet = String(text[startIdx..<endIdx])
        if start > 0 { snippet = "…" + snippet }
        if endIdx < text.endIndex { snippet += "…" }
        return snippet
    }

    /// Load a page of messages for a session, ordered by sort_order ASC.
    /// `maxChars` caps each message's text length; if truncated, `truncated`
    /// is true so callers can append a sentinel like "…[truncated]".
    /// [T-sessions-cli-messages-date-filter] (GH#200) `startDate`/`endDate` are
    /// an inclusive `created_at` range, mirroring `searchMessages` above (which
    /// already supported it — only this messages path did not, so the CLI's
    /// documented `--start/--end` silently returned the whole session).
    /// Both default to nil, so every existing caller keeps its behavior.
    ///
    /// [T-sessions-cli-tool-calls] `includeTools` also decodes each message's
    /// tool_use / tool_result parts UNSUMMARIZED into `toolUses` /
    /// `toolResults`. `text` is unchanged either way (it still carries the
    /// one-line tool summary for tool-only messages), so existing callers see
    /// exactly the same fields; the arrays are empty when the flag is off.
    func loadMessagePage(sessionId: String, offset: Int = 0, limit: Int = 20, maxChars: Int = 1000,
                         startDate: Date? = nil, endDate: Date? = nil,
                         includeTools: Bool = false) -> [(messageId: String, role: String, createdAt: Date, text: String, truncated: Bool, toolUses: [ToolUse], toolResults: [ToolResult])] {
        // Date predicates are appended BEFORE the LIMIT/OFFSET binds, so the
        // bind indices shift — hence the running `bindIndex` instead of the
        // previous hardcoded 1/2/3.
        var conditions = ["session_id = ?"]
        var doubleBindings: [(Int32, Double)] = []
        var bindIndex: Int32 = 2
        if let startDate {
            conditions.append("created_at >= ?")
            doubleBindings.append((bindIndex, startDate.timeIntervalSince1970))
            bindIndex += 1
        }
        if let endDate {
            conditions.append("created_at <= ?")
            doubleBindings.append((bindIndex, endDate.timeIntervalSince1970))
            bindIndex += 1
        }
        let sql = """
            SELECT id, role, created_at, parts_json
            FROM messages WHERE \(conditions.joined(separator: " AND "))
            ORDER BY sort_order ASC, created_at ASC
            LIMIT ? OFFSET ?
        """
        var stmt: OpaquePointer?
        var results: [(messageId: String, role: String, createdAt: Date, text: String, truncated: Bool, toolUses: [ToolUse], toolResults: [ToolResult])] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            for (idx, value) in doubleBindings {
                sqlite3_bind_double(stmt, idx, value)
            }
            sqlite3_bind_int(stmt, bindIndex, Int32(limit))
            sqlite3_bind_int(stmt, bindIndex + 1, Int32(offset))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let messageId = String(cString: sqlite3_column_text(stmt, 0))
                let role = String(cString: sqlite3_column_text(stmt, 1))
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                let partsJSON = String(cString: sqlite3_column_text(stmt, 3))

                // [T-sessions-cli-truncate] Must NOT go through
                // extractTextFromPartsJSON — that's the session-LIST preview
                // helper: it hard-caps at 100 chars, keeps only the FIRST text
                // part, and strips markdown, so the CLI's documented 1000 /
                // 50000 (--full) caps never applied and every exported message
                // came out as a 100-char preview.
                let fullText = extractFullTextFromPartsJSON(partsJSON) ?? ""
                guard !fullText.isEmpty else { continue }
                let truncated = fullText.count > maxChars
                let text = truncated ? String(fullText.prefix(maxChars)) : fullText

                var toolUses: [ToolUse] = []
                var toolResults: [ToolResult] = []
                if includeTools,
                   let data = partsJSON.data(using: .utf8),
                   let parts = try? JSONDecoder().decode([ContentPart].self, from: data) {
                    for part in parts {
                        switch part {
                        case .toolUse(let tu): toolUses.append(tu)
                        case .toolResult(let tr): toolResults.append(tr)
                        default: continue
                        }
                    }
                }

                results.append((messageId: messageId, role: role, createdAt: createdAt, text: text, truncated: truncated,
                                toolUses: toolUses, toolResults: toolResults))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    /// Get total message count for a session.
    ///
    /// [T-sessions-cli-messages-date-filter] (GH#200) Takes the same optional
    /// range as `loadMessagePage` so a filtered query reports the count WITHIN
    /// the range. Without this the CLI would page against a `total` describing
    /// the whole session — the caller would think there were more pages of
    /// in-range messages than exist. Both default to nil (unfiltered).
    func messageCount(sessionId: String, startDate: Date? = nil, endDate: Date? = nil) -> Int {
        var conditions = ["session_id = ?"]
        var doubleBindings: [(Int32, Double)] = []
        var bindIndex: Int32 = 2
        if let startDate {
            conditions.append("created_at >= ?")
            doubleBindings.append((bindIndex, startDate.timeIntervalSince1970))
            bindIndex += 1
        }
        if let endDate {
            conditions.append("created_at <= ?")
            doubleBindings.append((bindIndex, endDate.timeIntervalSince1970))
            bindIndex += 1
        }
        let sql = "SELECT COUNT(*) FROM messages WHERE \(conditions.joined(separator: " AND "))"
        var stmt: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            for (idx, value) in doubleBindings {
                sqlite3_bind_double(stmt, idx, value)
            }
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return count
    }

    /// [T-scheduled-task-detail] Every persisted fire of a scheduled job, in
    /// any session: the user rows whose text is that job's
    /// `<agent_callback kind="scheduled" … job="<jobId>" …>` envelope.
    /// Covers follow-up fires (the same chat) and new-session fires (one
    /// session per fire). Rerun fires write no envelope and are not found here.
    /// The LIKE pre-filter is on the job's UUID; each hit is then parsed and
    /// kept only if its envelope really names this job. Newest first.
    func scheduledFireMessages(jobId: String, limit: Int = 500)
        -> [(sessionId: String, messageId: String, createdAt: Date, text: String)] {
        guard !jobId.isEmpty else { return [] }
        let sql = """
            SELECT session_id, id, created_at, parts_json FROM messages
            WHERE role = 'user' AND parts_json LIKE ? AND parts_json LIKE ?
            ORDER BY created_at DESC LIMIT ?
            """
        var stmt: OpaquePointer?
        var out: [(sessionId: String, messageId: String, createdAt: Date, text: String)] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return []
        }
        // SQLITE_TRANSIENT: SQLite copies the pattern, so the temporary
        // NSString backing it may go away before the statement steps.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, "%\(AgentCallback.tag)%", -1, transient)
        sqlite3_bind_text(stmt, 2, "%\(jobId)%", -1, transient)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let sid = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let mid = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let json = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                  let data = json.data(using: .utf8),
                  let parts = try? JSONDecoder().decode([ContentPart].self, from: data) else { continue }
            let text = parts.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }.joined(separator: "\n")
            guard let cb = AgentCallback.parse(text), cb.kind == .scheduled, cb.jobId == jobId else { continue }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            out.append((sid, mid, createdAt, text))
        }
        sqlite3_finalize(stmt)
        return out
    }

    func getSession(_ id: String) -> ChatSession? {
        let sql = "SELECT id, title, model_id, created_at, updated_at, category, source, pinned_at, folder_id, parent_session_id, parent_tool_use_id FROM sessions WHERE id = ?"
        var stmt: OpaquePointer?
        var session: ChatSession?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let modelId = String(cString: sqlite3_column_text(stmt, 2))
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                let category = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                let source = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                let pinnedAt: Date? = sqlite3_column_type(stmt, 7) != SQLITE_NULL
                    ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)) : nil
                let folderId = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
                let parentSessionId = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
                let parentToolUseId = sqlite3_column_text(stmt, 10).map { String(cString: $0) }

                session = ChatSession(
                    id: id, title: title, category: category, modelId: modelId,
                    createdAt: createdAt, updatedAt: updatedAt, source: source,
                    pinnedAt: pinnedAt, folderId: folderId
                )
                session?.parentSessionId = parentSessionId
                session?.parentToolUseId = parentToolUseId
            }
        }
        sqlite3_finalize(stmt)

        return session
    }

    func updateSessionModelId(_ id: String, modelId: String) {
        // PER-SESSION: changes one row's displayed model. Row set and order
        // (updated_at) are untouched.
        invalidateSessionListCache(sessionId: id)
        let sql = "UPDATE sessions SET model_id = ? WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (modelId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func updateSessionTitle(_ id: String, title: String, category: String? = nil) {
        // PER-SESSION: title/category are this row's own fields. It also bumps
        // updated_at, which reorders — the incremental patch re-sorts, so that
        // is expressible without a full rebuild.
        invalidateSessionListCache(sessionId: id)
        let sql = "UPDATE sessions SET title = ?, category = COALESCE(?, category), updated_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (title as NSString).utf8String, -1, nil)
            bindOptionalText(stmt, index: 2, value: category)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 4, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        markDirty(recordType: "Session", recordId: id)
        NotificationCenter.default.post(name: .sessionDidUpdate, object: id)
    }

    /// Toggle pin state for a session. Returns the new pinned state.
    @discardableResult
    func toggleSessionPin(_ id: String) -> Bool {
        // FULL: pinning changes the sidebar's ordering rules, not just a field.
        invalidateSessionListCache()
        // Check current pin state
        var isPinned = false
        let checkSql = "SELECT pinned_at FROM sessions WHERE id = ?"
        var checkStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(checkStmt, 1, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(checkStmt) == SQLITE_ROW {
                isPinned = sqlite3_column_type(checkStmt, 0) != SQLITE_NULL
            }
        }
        sqlite3_finalize(checkStmt)

        let newPinned = !isPinned
        let sql = "UPDATE sessions SET pinned_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if newPinned {
                sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        markDirty(recordType: "Session", recordId: id)
        return newPinned
    }
}
