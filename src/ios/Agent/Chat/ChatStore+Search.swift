//
//  ChatStore+Search.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore, session search: searchSessions over titles and message text,
//  and the hit-line / snippet helpers for search results.
//
//  Map of the ChatStore files: ChatStore.swift.
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

private let logger = AppLogger(category: "ChatStore")

// [T-search-multi-keyword] A search box entry is a list of keywords separated
// by whitespace, and a session is a result when ANY of them is found (OR): in
// its title, or in a message field the user can see. One keyword behaves
// exactly as the whole-string search did before.
// Pure (strings in, strings out) so the split, the escaping, the SQL and the
// highlight ranges are tested without the store.
// Kept byte-identical with MinisTests/Standalone/SearchHitLineTests.swift.
// BEGIN searchKeywords
enum SearchKeywords {
    /// Keywords past this many are ignored: each one adds a LIKE per message.
    static let maxTerms = 10

    /// The keywords of `query`: split on any whitespace (runs of it, tabs,
    /// newlines, the full-width space), empties dropped, a keyword repeated
    /// in another letter case kept once. Empty for a blank query.
    static func terms(_ query: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for piece in query.split(whereSeparator: \.isWhitespace) {
            let term = String(piece)
            guard seen.insert(term.lowercased()).inserted else { continue }
            out.append(term)
            if out.count == maxTerms { break }
        }
        return out
    }

    /// `%term%` for LIKE ... ESCAPE '\': `%` and `_` in the keyword are
    /// matched as themselves, not as wildcards ("100%" used to match
    /// "1000 items", "a_b" matched "axb").
    static func likePattern(_ term: String) -> String {
        var escaped = ""
        for ch in term {
            if ch == "\\" || ch == "%" || ch == "_" { escaped.append("\\") }
            escaped.append(ch)
        }
        return "%\(escaped)%"
    }

    /// `(column LIKE ?1 ESCAPE '\' OR column LIKE ?2 ESCAPE '\' ...)`: the
    /// column holds any of the `termCount` patterns bound to ?1...?n.
    static func anyLike(_ column: String, termCount: Int) -> String {
        "(" + (1...max(1, termCount)).map { "\(column) LIKE ?\($0) ESCAPE '\\'" }.joined(separator: " OR ") + ")"
    }

    // [T-search-visible-only] SQL condition: message `m` holds one of the
    // patterns in a field the user can see - a text part, a tool call's input
    // or a tool's output. `parts_json LIKE` alone also matched opaque fields
    // (tool-call ids, Gemini thought signatures - random base64 in which a
    // short case-insensitive keyword like "gpt" turns up by chance), listing
    // sessions that never mention the keyword. The plain LIKE stays first as
    // the cheap prefilter; json_each only runs on its survivors.
    static func visibleHitClause(termCount n: Int) -> String {
        """
        \(anyLike("m.parts_json", termCount: n)) AND EXISTS (
            SELECT 1 FROM json_each(m.parts_json) p
            WHERE (json_extract(p.value, '$.type') = 'text' AND \(anyLike("json_extract(p.value, '$.value')", termCount: n)))
               OR (json_extract(p.value, '$.type') = 'toolUse' AND \(anyLike("json_extract(p.value, '$.value.input')", termCount: n)))
               OR (json_extract(p.value, '$.type') = 'toolResult' AND \(anyLike("json_extract(p.value, '$.value.output')", termCount: n))))
        """
    }

    // [T-search-visible-only] Sessions whose title matches, or holding a
    // message that shows a keyword in a visible field, with the newest such
    // message (SQLite's bare column beside MAX() is that row's).
    static func visibleSQL(termCount n: Int) -> String {
        """
        WITH newest AS (
            SELECT m.session_id, m.parts_json, MAX(m.sort_order)
            FROM messages m
            WHERE \(visibleHitClause(termCount: n))
            GROUP BY m.session_id)
        SELECT s.id, s.title, s.model_id, s.created_at, s.updated_at, s.category, n.parts_json
        FROM sessions s
        LEFT JOIN newest n ON n.session_id = s.id
        WHERE \(anyLike("s.title", termCount: n)) OR n.session_id IS NOT NULL
        ORDER BY s.updated_at DESC
        """
    }

    // Pre-JSON1 fallback: raw-JSON LIKE, as before. Rows it lists without a
    // visible line are still dropped by the caller.
    static func legacySQL(termCount n: Int) -> String {
        """
        SELECT DISTINCT s.id, s.title, s.model_id, s.created_at, s.updated_at, s.category,
               (SELECT m2.parts_json FROM messages m2
                WHERE m2.session_id = s.id AND \(anyLike("m2.parts_json", termCount: n))
                ORDER BY m2.sort_order DESC LIMIT 1)
        FROM sessions s
        LEFT JOIN messages m ON m.session_id = s.id
        WHERE \(anyLike("s.title", termCount: n)) OR \(anyLike("m.parts_json", termCount: n))
        GROUP BY s.id
        ORDER BY s.updated_at DESC
        """
    }

    /// The newest matching messages of one session (its id is bound after
    /// the patterns, to ?n+1).
    static func olderSQL(termCount n: Int, visibleOnly: Bool) -> String {
        """
        SELECT m.parts_json FROM messages m
        WHERE m.session_id = ?\(n + 1) AND \(visibleOnly ? visibleHitClause(termCount: n) : anyLike("m.parts_json", termCount: n))
        ORDER BY m.sort_order DESC LIMIT 20
        """
    }

    /// The first keyword, in the order typed, that occurs in `text`, with
    /// where it first occurs. Case-insensitive.
    static func firstHit(in text: String, terms: [String]) -> (range: Range<String.Index>, term: String)? {
        for term in terms where !term.isEmpty {
            if let range = text.range(of: term, options: .caseInsensitive) { return (range, term) }
        }
        return nil
    }

    /// Every occurrence of every keyword in `text`, in text order, with
    /// overlapping and touching occurrences joined ("gpt" and "gpt-5" in
    /// "GPT-5" are one range). What a row highlights.
    static func hitRanges(in text: String, terms: [String]) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for term in terms where !term.isEmpty {
            var from = text.startIndex
            while from < text.endIndex,
                  let range = text.range(of: term, options: .caseInsensitive, range: from..<text.endIndex) {
                found.append(range)
                from = range.upperBound > range.lowerBound ? range.upperBound : text.index(after: range.lowerBound)
            }
        }
        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in found {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
// END searchKeywords

extension ChatStore {
    /// Search sessions by keyword across title and message text content.
    /// Returns matching sessions with the line of the newest matching message
    /// that holds the keyword (if a message matched).
    struct SearchResult {
        let session: ChatSession
        /// [T-search-hit-line] The line of the newest matching message that
        /// holds the query, windowed around the hit (see searchHitLine), or
        /// nil when no message shows the query (title-only match, or a hit
        /// inside JSON structure the user never sees).
        let matchSnippet: String?
        /// Whether the title matched the query.
        let titleMatched: Bool
    }

    // [T-search-hit-line] The line of `text` holding the first
    // case-insensitive hit of a keyword, cut to at most `maxLength` characters
    // that keep the hit visible: up to `lead` characters of context before
    // it, the rest after, "…" marking every cut. nil when `text` contains
    // none of `terms`. A search result shows THIS instead of the session's
    // generic preview, so the user sees where the keyword was found.
    // [T-search-multi-keyword] With several keywords the line is the one of
    // the first keyword (in the order typed) that occurs at all; the row then
    // highlights every keyword that falls inside the window.
    // Kept byte-identical with MinisTests/Standalone/SearchHitLineTests.swift.
    // BEGIN searchHitLine
    static func searchHitLine(in text: String, terms: [String], maxLength: Int = 90, lead: Int = 18) -> String? {
        guard let found = SearchKeywords.firstHit(in: text, terms: terms) else { return nil }
        let hit = found.range
        let q = found.term
        let lineStart = text[..<hit.lowerBound].lastIndex(where: \.isNewline).map { text.index(after: $0) }
            ?? text.startIndex
        let lineEnd = text[hit.upperBound...].firstIndex(where: \.isNewline) ?? text.endIndex
        let line = Array(text[lineStart..<lineEnd])
        let hitStart = text.distance(from: lineStart, to: hit.lowerBound)
        let hitLength = text.distance(from: hit.lowerBound, to: hit.upperBound)
        var from = 0
        var to = line.count
        if line.count > maxLength {
            // Always `lead` characters before the hit, even near the line's
            // end: the row shows two lines, so a window that back-fills to
            // maxLength before a late hit pushes the keyword out of view.
            from = max(0, hitStart - lead)
            to = min(line.count, max(from + maxLength, hitStart + hitLength))
        }
        var window = String(line[from..<to])
        // Trim the window's own edge whitespace, but never into the hit.
        let body = window.trimmingCharacters(in: .whitespaces)
        if body.range(of: q, options: .caseInsensitive) != nil { window = body }
        return (from > 0 ? "…" : "") + window + (to < line.count ? "…" : "")
    }
    // END searchHitLine

    /// [T-search-hit-line] The display line for a matched message: the first
    /// hit in its visible text, then in its tool calls' inputs, then in their
    /// outputs. Tool hits are prefixed with 🔧 (and the tool name where the
    /// part carries it) so the user can tell a hit in a command or its
    /// output from one in the conversation. Markdown syntax is stripped from
    /// the line when that keeps a hit intact. nil when no part shows any
    /// keyword — `parts_json LIKE` also matches JSON keys and escapes.
    private func searchSnippet(fromPartsJSON json: String, terms: [String]) -> String? {
        guard let data = json.data(using: .utf8),
              let parts = try? JSONDecoder().decode([ContentPart].self, from: data) else { return nil }
        func readable(_ line: String) -> String {
            let plain = MarkdownStripper.plainText(line, inlinePassCap: MarkdownStripper.inlinePassCap)
                .trimmingCharacters(in: .whitespaces)
            return SearchKeywords.firstHit(in: plain, terms: terms) != nil ? plain : line
        }
        for part in parts {
            guard case .text(var t) = part else { continue }
            t = RawMessage.stripSystemReminders(t)
            if let start = t.range(of: "<user-attached-files>") {
                let endBound = t.range(of: "</user-attached-files>")?.upperBound ?? t.endIndex
                t = String(t[t.startIndex..<start.lowerBound] + t[endBound...])
            }
            t = RawMessage.stripAttachmentMarkers(t)
            if let line = Self.searchHitLine(in: t, terms: terms) { return readable(line) }
        }
        for part in parts {
            guard case .toolUse(let tu) = part else { continue }
            // Search the input's string values (what the tool card shows), so
            // the line is real text rather than escaped JSON ("…\\n4. …");
            // the raw JSON only as a last resort (a hit in a key name).
            for text in Self.toolInputStrings(tu.input) + [tu.input] {
                if let line = Self.searchHitLine(in: text, terms: terms) { return "🔧 \(tu.name): \(line)" }
            }
        }
        for part in parts {
            guard case .toolResult(let tr) = part,
                  let line = Self.searchHitLine(in: tr.output, terms: terms) else { continue }
            return "🔧 \(line)"
        }
        return nil
    }

    /// [T-search-visible-only] The string values of a tool call's JSON input,
    /// depth-first, keys in sorted order for determinism. Empty when the
    /// input is not JSON.
    // Kept byte-identical with MinisTests/Standalone/SearchHitLineTests.swift.
    // BEGIN toolInputStrings
    static func toolInputStrings(_ input: String) -> [String] {
        guard let data = input.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [] }
        var out: [String] = []
        func walk(_ v: Any) {
            if let s = v as? String { out.append(s) }
            else if let a = v as? [Any] { a.forEach(walk) }
            else if let d = v as? [String: Any] { for k in d.keys.sorted() { if let x = d[k] { walk(x) } } }
        }
        walk(obj)
        return out
    }
    // END toolInputStrings

    /// [T-search-hit-line] When the newest matching message shows nothing
    /// (its hit was in JSON structure), look further back through a few more
    /// matching messages for a line that does.
    private func olderSearchSnippet(sessionId: String, terms: [String], visibleOnly: Bool) -> String? {
        let sql = SearchKeywords.olderSQL(termCount: terms.count, visibleOnly: visibleOnly)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        Self.bindSearchPatterns(terms, to: stmt)
        sqlite3_bind_text(stmt, Int32(terms.count + 1), sessionId, -1, Self.searchBindTransient)
        var first = true
        while sqlite3_step(stmt) == SQLITE_ROW {
            // The newest one was already tried by the caller.
            if first { first = false; continue }
            guard let json = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { continue }
            if let snippet = searchSnippet(fromPartsJSON: json, terms: terms) { return snippet }
        }
        return nil
    }

    // SQLITE_TRANSIENT: SQLite copies each pattern, so the temporary string
    // backing it may go away before the statement steps.
    private static let searchBindTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// [T-search-multi-keyword] Bind keyword k's LIKE pattern to ?k (1-based).
    private static func bindSearchPatterns(_ terms: [String], to stmt: OpaquePointer?) {
        for (i, term) in terms.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), SearchKeywords.likePattern(term), -1, searchBindTransient)
        }
    }

    func searchSessions(query: String) -> [SearchResult] {
        // [T-search-multi-keyword] Whitespace separates keywords; a session
        // matching ANY of them is a result. Nothing but whitespace: no search.
        let terms = SearchKeywords.terms(query)
        guard !terms.isEmpty else { return [] }
        let visibleSQL = SearchKeywords.visibleSQL(termCount: terms.count)
        let legacySQL = SearchKeywords.legacySQL(termCount: terms.count)
        var stmt: OpaquePointer?
        var results: [SearchResult] = []
        var visibleOnly = true
        if sqlite3_prepare_v2(db, visibleSQL, -1, &stmt, nil) != SQLITE_OK {
            logger.warning("[Search] visible-field query unavailable (\(String(cString: sqlite3_errmsg(db)))) — raw-JSON fallback")
            sqlite3_finalize(stmt)
            stmt = nil
            visibleOnly = false
            guard sqlite3_prepare_v2(db, legacySQL, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                return []
            }
        }
        Self.bindSearchPatterns(terms, to: stmt)

        // [T-search-hit-line] Bound the look-further-back work: each attempt
        // decodes up to 20 messages on this actor. Results are newest first,
        // so the budget goes to the rows users see.
        var fallbackBudget = 40
        var dropped = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let modelId = String(cString: sqlite3_column_text(stmt, 2))
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            let category = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let matchedPartsJSON = sqlite3_column_text(stmt, 6).map { String(cString: $0) }

            let titleMatched = title.map { SearchKeywords.firstHit(in: $0, terms: terms) != nil } ?? false
            // [T-search-hit-line] The line that actually holds a keyword,
            // not the matched message's generic preview (which often did
            // not contain it, so nothing could be highlighted).
            var snippet = matchedPartsJSON.flatMap { searchSnippet(fromPartsJSON: $0, terms: terms) }
            if snippet == nil, matchedPartsJSON != nil, fallbackBudget > 0 {
                fallbackBudget -= 1
                snippet = olderSearchSnippet(sessionId: id, terms: terms, visibleOnly: visibleOnly)
            }
            // [T-search-visible-only] Every result must show why it is one:
            // a highlighted title or a line holding a keyword. A session whose
            // only hits are in text the user never sees (a <system-reminder>,
            // an opaque field on the legacy path) is not a result.
            guard titleMatched || snippet != nil else {
                dropped += 1
                continue
            }

            let session = ChatSession(
                id: id, title: title, category: category, modelId: modelId,
                createdAt: createdAt, updatedAt: updatedAt, lastMessage: snippet
            )
            results.append(SearchResult(session: session, matchSnippet: snippet, titleMatched: titleMatched))
        }
        sqlite3_finalize(stmt)
        if dropped > 0 {
            logger.info("[Search] dropped \(dropped) session(s) with no visible hit (visibleOnly=\(visibleOnly), budgetLeft=\(fallbackBudget))")
        }
        return results
    }
}
