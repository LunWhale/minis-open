#!/usr/bin/env swift
// [T-search-hit-line] [T-search-folder-expand] Search results show WHY a
// session matched.
//
// Before: a body hit showed the matched message's generic 100-char preview,
// which often did not contain the keyword (it sat further down, or the hit
// was in a tool call), so nothing was highlighted; a title hit dropped the
// body line entirely; folders stayed collapsed, hiding the matching rows.
//
// Follow-up (T-search-visible-only): real-device repro, search "GPT" listed
// sessions whose subtitle showed no keyword at all. `parts_json LIKE` also
// matched opaque fields — tool-call ids and Gemini thought signatures, random
// base64 in which "gpt" turns up by chance — and a late hit on a long line
// was windowed to the end of the 90 characters, past the row's two lines.
//
// Follow-up (T-search-multi-keyword): the whole entry, spaces included, was
// one substring - "apple banana" found only sessions holding exactly that
// text. Whitespace now separates keywords and a session matching ANY of them
// is a result (OR); a line holding several has all of them highlighted; and
// `%` / `_` in a keyword are matched as themselves, not as LIKE wildcards.
//
//   [1] searchHitLine — pure: the hit's line, windowed around the hit
//   [2] toolInputStrings — pure: tool input searched as text, not JSON
//   [3] the search SQL, run for real against an in-memory SQLite: only
//       visible fields match; opaque-field-only sessions are not results
//   [4] source guards — snippet extraction order, fallback, the drop rule,
//       folder expansion gated on search results, normal list untouched
//   [5] keywords — pure: the split, the highlight ranges, the hit line with
//       several keywords
//   [6] multi-keyword OR and wildcard escaping, against the same SQLite
//
// Run: swift SearchHitLineTests.swift
import Foundation

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
import SQLite3

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
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}

// MARK: - Port (byte-identical with ChatStore.swift, guarded in [2])

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

enum ChatStore {
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
}
func hit(_ t: String, _ q: String, _ max: Int = 90, _ lead: Int = 18) -> String? {
    ChatStore.searchHitLine(in: t, terms: SearchKeywords.terms(q), maxLength: max, lead: lead)
}
func contains(_ s: String?, _ q: String) -> Bool { s?.range(of: q, options: .caseInsensitive) != nil }
func count(_ hay: String, _ needle: String) -> Int { hay.components(separatedBy: needle).count - 1 }

// MARK: - [1] searchHitLine

print("▶️  1. searchHitLine — pure")
check("no hit → nil", hit("hello world", "gpt") == nil)
check("empty / blank query → nil", hit("hello", "") == nil && hit("hello", "   ") == nil)
check("short single line → the whole line", hit("Switch to GPT-5 now", "gpt") == "Switch to GPT-5 now")
check("case-insensitive, original casing kept", hit("use Gpt here", "GPT") == "use Gpt here")
check("query is trimmed", hit("a GPT b", " GPT ") == "a GPT b")
let multi = "first line\nsecond has the GPT keyword\nthird line"
check("multi-line → only the line holding the hit", hit(multi, "gpt") == "second has the GPT keyword")
check("CRLF line breaks", hit("one\r\ntwo GPT two\r\nthree", "gpt") == "two GPT two")
check("hit on the first line", hit("GPT first\nsecond", "gpt") == "GPT first")
check("hit on the last line", hit("first\nlast GPT", "gpt") == "last GPT")
check("first hit wins when there are several", hit("a\nGPT one\nGPT two", "gpt") == "GPT one")

let long = String(repeating: "x", count: 200) + " GPT " + String(repeating: "y", count: 200)
let w = hit(long, "gpt")
check("long line: hit kept in view", contains(w, "GPT"))
check("long line: cut on both sides", w?.hasPrefix("…") == true && w?.hasSuffix("…") == true)
check("long line: window is maxLength plus the two ellipses", (w?.count ?? 0) <= 92)
check("long line: about `lead` characters before the hit", {
    guard let w, let r = w.range(of: "GPT") else { return false }
    let before = w.distance(from: w.startIndex, to: r.lowerBound) - 1  // minus the leading …
    return before >= 17 && before <= 18
}())
let early = "GPT " + String(repeating: "z", count: 300)
check("hit at the start of a long line: no leading ellipsis", hit(early, "gpt")?.hasPrefix("GPT") == true
      && hit(early, "gpt")?.hasSuffix("…") == true)
let late = String(repeating: "z", count: 300) + " GPT"
check("hit at the end of a long line: no trailing ellipsis, window ends on the hit",
      hit(late, "gpt")?.hasSuffix("GPT") == true && hit(late, "gpt")?.hasPrefix("…") == true)
let nearEnd = String(repeating: "a", count: 150) + " GPT " + String(repeating: "b", count: 20)
check("REGRESSION: a late hit stays near the window's start (row shows 2 lines)", {
    guard let w = hit(nearEnd, "gpt"), let r = w.range(of: "GPT") else { return false }
    return w.distance(from: w.startIndex, to: r.lowerBound) <= 19
}())
let cjk = String(repeating: "这是一段很长的中文内容", count: 20) + "关键字命中" + String(repeating: "后面还有更多文字", count: 20)
check("CJK long line: hit kept, bounded", contains(hit(cjk, "关键字"), "关键字") && (hit(cjk, "关键字")?.count ?? 0) <= 92)
let emoji = String(repeating: "🙂", count: 150) + "GPT" + String(repeating: "🎉", count: 150)
check("emoji (multi-scalar graphemes): hit kept, no crash", contains(hit(emoji, "gpt"), "GPT"))
let longQuery = String(repeating: "q", count: 120)
let lq = hit("aa " + longQuery + " bb", longQuery)
check("query longer than the window: the whole hit is still shown", contains(lq, longQuery))
check("edge whitespace trimmed", hit("    GPT is here    ", "gpt") == "GPT is here")
check("two keywords: the line of the first one, whitespace inside the line kept", hit("say  hello world  end", "hello world") == "say  hello world  end")
check("tiny window still returns the hit", contains(hit("0123456789 GPT 0123456789", "gpt", 5, 2), "GPT"))

// MARK: - [2] toolInputStrings

print("\n▶️  2. toolInputStrings — pure")
check("string leaves, keys sorted, depth-first",
      ChatStore.toolInputStrings(#"{"b":"two","a":["one",{"c":"three"}],"n":5}"#) == ["one", "three", "two"])
check("escaped newlines become real ones (so the hit LINE is found)",
      ChatStore.toolInputStrings(#"{"text":"line one\n4. GPT-5 cache"}"#) == ["line one\n4. GPT-5 cache"]
      && hit(ChatStore.toolInputStrings(#"{"text":"line one\n4. GPT-5 cache"}"#)[0], "gpt") == "4. GPT-5 cache")
check("not JSON → empty (caller falls back to the raw input)", ChatStore.toolInputStrings("ls -la").isEmpty)
check("a bare JSON string fragment", ChatStore.toolInputStrings(#""just text""#) == ["just text"])

// MARK: - [3] search SQL against a real SQLite

print("\n▶️  3. the search SQL, run against an in-memory SQLite")
let iosRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let storeSrc = chatStoreSource()
// [T-search-multi-keyword] The SQL is built per keyword count by the shipping
// generator (ported above, guarded byte-identical in [4]); one keyword gives
// the statement the app always ran, plus ESCAPE.
let visibleSQL = SearchKeywords.visibleSQL
let legacySQL = SearchKeywords.legacySQL
check("SQL built by the shipping generator", visibleSQL(1).contains("json_each") && visibleSQL(1).contains("WITH newest AS")
      && legacySQL(1).contains("LIKE ?1") && !visibleSQL(1).contains("?2") && visibleSQL(3).contains("?3"))

var db: OpaquePointer?
sqlite3_open(":memory:", &db)
func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }
exec("CREATE TABLE sessions (id TEXT, title TEXT, model_id TEXT, created_at REAL, updated_at REAL, category TEXT)")
exec("CREATE TABLE messages (session_id TEXT, sort_order INTEGER, parts_json TEXT)")
func text(_ v: String) -> String { #"{"type":"text","value":\#(jsonString(v))}"# }
func jsonString(_ v: String) -> String { String(data: try! JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]), encoding: .utf8)! }
func toolUse(id: String, input: String, sig: String? = nil) -> String {
    var o: [String: Any] = ["toolUseId": id, "name": "shell_execute", "input": input]
    if let sig { o["thoughtSignature"] = sig }
    return #"{"type":"toolUse","value":\#(String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!)}"#
}
func toolResult(id: String, output: String) -> String {
    let o: [String: Any] = ["toolUseId": id, "output": output, "success": true]
    return #"{"type":"toolResult","value":\#(String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!)}"#
}
var t0 = 1000.0
func session(_ id: String, _ title: String, _ messages: [[String]]) {
    t0 += 1
    exec("INSERT INTO sessions VALUES ('\(id)', '\(title)', 'm', \(t0), \(t0), NULL)")
    for (i, parts) in messages.enumerated() {
        let pj = "[" + parts.joined(separator: ",") + "]"
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO messages VALUES (?, ?, ?)", -1, &st, nil)
        sqlite3_bind_text(st, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(st, 2, Int32(i))
        sqlite3_bind_text(st, 3, pj, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(st); sqlite3_finalize(st)
    }
}
session("text", "Plain chat", [[text("hello")], [text("switch to GPT-5 please")], [text("ok")]])
session("toolid", "iPad split view port", [[toolUse(id: "call_x9GpTq2", input: #"{"command":"ls"}"#)], [toolResult(id: "call_x9GpTq2", output: "done")]])
session("sig", "Backup plan review", [[toolUse(id: "t1", input: #"{"command":"pwd"}"#, sig: "CiQB0e2Kbgpt7Hx")]])
session("input", "Shell work", [[toolUse(id: "t2", input: #"{"command":"grep -r gpt-5 src"}"#)]])
session("output", "Model list", [[toolResult(id: "t3", output: "gpt-5.1-codex\nclaude")]])
session("title", "GPT pricing notes", [[text("nothing here")]])
session("reminder", "Runtime", [[text("<system-reminder>model: gpt-5</system-reminder>")]])
session("newest", "Two hits", [[text("old GPT line")], [text("unrelated")], [text("new GPT line")], [text("tail")]])

/// Runs a search the way searchSessions does: split into keywords, one
/// statement for that many, keyword k's escaped pattern bound to ?k.
func run(_ sqlFor: (Int) -> String, _ q: String) -> [(id: String, hit: String?)] {
    let terms = SearchKeywords.terms(q)
    guard !terms.isEmpty else { return [] }
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, sqlFor(terms.count), -1, &st, nil) == SQLITE_OK else {
        print("    prepare failed: \(String(cString: sqlite3_errmsg(db)))"); return []
    }
    defer { sqlite3_finalize(st) }
    for (i, term) in terms.enumerated() {
        sqlite3_bind_text(st, Int32(i + 1), SearchKeywords.likePattern(term), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    var out: [(String, String?)] = []
    while sqlite3_step(st) == SQLITE_ROW {
        out.append((String(cString: sqlite3_column_text(st, 0)), sqlite3_column_text(st, 6).map { String(cString: $0) }))
    }
    return out
}
let v = run(visibleSQL, "GPT")
let vIds = Set(v.map(\.id))
let legacyIds = Set(run(legacySQL, "GPT").map(\.id))
check("OLD: reproduces — tool-call id and thought signature sessions were results",
      legacyIds.contains("toolid") && legacyIds.contains("sig"))
check("NEW: a hit only in a tool-call id is not a result", !vIds.contains("toolid"))
check("NEW: a hit only in a thought signature is not a result", !vIds.contains("sig"))
check("NEW: text, tool input, tool output and title hits are results",
      ["text", "input", "output", "title", "newest"].allSatisfy(vIds.contains))
check("NEW: title-only result carries no message", v.first { $0.id == "title" }?.hit == nil)
check("NEW: the NEWEST visible hit message is returned", v.first { $0.id == "newest" }?.hit?.contains("new GPT line") == true)
check("a hit hidden in a <system-reminder> still passes SQL (Swift drops it — see [4])", vIds.contains("reminder"))
check("results newest session first", v.first?.id == "newest")
check("case-insensitive like the app (LIKE is ASCII case-insensitive)", Set(run(visibleSQL, "gpt").map(\.id)) == vIds)

// MARK: - [4] source guards

print("\n▶️  4. source guards")
func source(_ rel: String) -> String { (try? String(contentsOf: iosRoot.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
func between(_ s: String, _ a: String, _ b: String) -> String {
    guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return "" }
    return String(s[r1.upperBound..<r2.lowerBound])
}
let store = chatStoreSource()
let view = contentViewSource()
let me = (try? String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)) ?? ""
let appFn = between(store, "// BEGIN searchHitLine", "// END searchHitLine")
check("searchHitLine port is byte-identical with ChatStore", !appFn.isEmpty && appFn == between(me, "// BEGIN searchHitLine", "// END searchHitLine"))
let appKeywords = between(store, "// BEGIN searchKeywords", "// END searchKeywords")
check("SearchKeywords port is byte-identical with ChatStore", !appKeywords.isEmpty && appKeywords == between(me, "// BEGIN searchKeywords", "// END searchKeywords"))
let appTool = between(store, "// BEGIN toolInputStrings", "// END toolInputStrings")
check("toolInputStrings port is byte-identical with ChatStore", !appTool.isEmpty && appTool == between(me, "// BEGIN toolInputStrings", "// END toolInputStrings"))

let snip = between(store, "private func searchSnippet(fromPartsJSON", "\n    }\n\n")
check("snippet order: visible text, then tool inputs, then tool outputs", {
    guard let t = snip.range(of: "guard case .text(var t) = part"),
          let u = snip.range(of: "guard case .toolUse(let tu) = part"),
          let r = snip.range(of: "guard case .toolResult(let tr) = part") else { return false }
    return t.lowerBound < u.lowerBound && u.lowerBound < r.lowerBound
}())
check("hidden reminders / attachment XML are not searched as visible text",
      snip.contains("RawMessage.stripSystemReminders(t)") && snip.contains("<user-attached-files>"))
check("tool hits are marked 🔧", snip.contains("return \"🔧 \\(tu.name): \\(line)\"") && snip.contains("return \"🔧 \\(line)\""))
check("tool input searched as parsed text first, raw JSON last", snip.contains("for text in Self.toolInputStrings(tu.input) + [tu.input] {"))
let search = between(store, "func searchSessions(query: String) -> [SearchResult] {", "\n    }\n")
check("searchSessions uses the hit line, not the generic preview",
      search.contains("searchSnippet(fromPartsJSON: $0, terms: terms)") && !search.contains("extractTextFromPartsJSON"))
check("…and looks further back when the newest match shows nothing",
      search.contains("olderSearchSnippet(sessionId: id, terms: terms, visibleOnly: visibleOnly)"))
check("REGRESSION: a result must show why — no title hit and no visible line → dropped",
      search.contains("guard titleMatched || snippet != nil else {\n                dropped += 1\n                continue"))
check("the visible-field query is tried first, raw-JSON LIKE only if JSON1 is unavailable", {
    guard search.contains("let visibleSQL = SearchKeywords.visibleSQL(termCount: terms.count)"),
          search.contains("let legacySQL = SearchKeywords.legacySQL(termCount: terms.count)"),
          let v = search.range(of: "sqlite3_prepare_v2(db, visibleSQL"),
          let l = search.range(of: "sqlite3_prepare_v2(db, legacySQL") else { return false }
    return v.lowerBound < l.lowerBound
}())
check("older-message look-back uses the same visible-field rule",
      between(store, "private func olderSearchSnippet(", "\n    }\n").contains("SearchKeywords.olderSQL(termCount: terms.count, visibleOnly: visibleOnly)")
      && appKeywords.contains("AND \\(visibleOnly ? visibleHitClause(termCount: n) : anyLike(\"m.parts_json\", termCount: n))"))
check("fallback scan is bounded per session and per search",
      appKeywords.contains("ORDER BY m.sort_order DESC LIMIT 20")
      && search.contains("var fallbackBudget = 40")
      && search.contains("if snippet == nil, matchedPartsJSON != nil, fallbackBudget > 0 {\n                fallbackBudget -= 1"))

let schedule = between(view, "func scheduleSearch() {", "\n    }\n")
check("snippet kept for title matches too", schedule.contains("if let snip = r.matchSnippet, !snip.isEmpty {")
      && !schedule.contains("!r.titleMatched"))
check("folder-name hits bring their members", schedule.contains("SearchKeywords.firstHit(in: $0.name, terms: terms) != nil")
      && schedule.contains("ids.formUnion(sessions.filter { $0.folderId.map(folderHits.contains) == true }.map(\\.id))"))
check("search state reset clears folder hits",
      between(view, "func dismissSearch() {", "\n    }\n").contains("searchMatchedFolderIds = []"))
check("expansion keys on results being on screen, not just typed text",
      view.contains("var searchResultsActive: Bool { isSearching && searchMatchedIds != nil }"))
check("folders forced open only while results are on screen; saved state untouched",
      view.contains("g.isCollapsed = searchResultsActive ? false : collapsedFolderIds.contains(fid)")
      && !between(view, "func scheduleSearch() {", "\n    }\n").contains("collapsedFolderIds ="))
check("folder toggle is a no-op in a result set",
      between(view, "func toggleFolderCollapsed(", "let willExpand").contains("guard !searchResultsActive else { return }"))
check("memo key tracks the search state it depends on",
      between(view, "struct SidebarGroupsMemoKey: Equatable {", "}").contains("let searchResultsActive: Bool")
      && between(view, "struct SidebarGroupsMemoKey: Equatable {", "}").contains("let searchMatchedFolderIds: Set<String>"))
check("non-search list: empty folders still padded in, exactly as before",
      view.contains("if !isSearching {\n            for f in folders.sorted(by: { $0.updatedAt > $1.updatedAt }) where members[f.id] == nil {"))
check("rows highlight the trimmed query, only while searching",
      view.components(separatedBy: "highlightQuery: isSearching ? searchQuery : nil,").count - 1 == 2
      && !view.contains("highlightQuery: isSearching ? searchText : nil"))
check("folder header: name highlight and match count only in a result set",
      view.contains("if searchResultsActive,\n                           SearchKeywords.firstHit(in: group.label, terms: SearchKeywords.terms(searchQuery)) != nil {")
      && view.contains("if searchResultsActive {\n                            // In a result set the members are the matches.\n                            Text(\"\\(group.totalCount) matching chats\")"))
check("\"%lld matching chats\" is in the string catalog", source("Localizable.xcstrings").contains("\"%lld matching chats\" : {"))

// MARK: - [5] keywords

print("\n▶️  5. keywords — pure")
typealias K = SearchKeywords
check("one keyword: itself (single-keyword search is unchanged)", K.terms("gpt") == ["gpt"] && K.terms("  gpt  ") == ["gpt"])
check("split on spaces, however many", K.terms("a b c d e f") == ["a", "b", "c", "d", "e", "f"] && K.terms("apple    banana") == ["apple", "banana"])
check("tabs, newlines and the full-width space separate too", K.terms("apple\tbanana\ncherry\u{3000}枣") == ["apple", "banana", "cherry", "枣"])
check("nothing but whitespace: no keywords", K.terms("").isEmpty && K.terms("     ").isEmpty && K.terms(" \t\n ").isEmpty)
check("a keyword repeated in another case is kept once, first spelling", K.terms("GPT gpt Gpt claude") == ["GPT", "claude"])
check("keywords past the cap are ignored", K.terms((1...30).map { "k\($0)" }.joined(separator: " ")).count == K.maxTerms && K.maxTerms == 10)
check("the order typed is kept", K.terms("zeta alpha") == ["zeta", "alpha"])

check("% _ and \\ are escaped for LIKE ... ESCAPE", K.likePattern("100%") == "%100\\%%" && K.likePattern("a_b") == "%a\\_b%" && K.likePattern("c:\\x") == "%c:\\\\x%")
check("an ordinary keyword is just wrapped", K.likePattern("gpt-5") == "%gpt-5%")
check("anyLike: one OR'd LIKE per keyword, each with ESCAPE",
      K.anyLike("t", termCount: 1) == "(t LIKE ?1 ESCAPE '\\')"
      && K.anyLike("t", termCount: 3) == "(t LIKE ?1 ESCAPE '\\' OR t LIKE ?2 ESCAPE '\\' OR t LIKE ?3 ESCAPE '\\')")

func ranges(_ text: String, _ q: String) -> [String] { K.hitRanges(in: text, terms: K.terms(q)).map { String(text[$0]) } }
check("one line holding two keywords: BOTH are highlighted", ranges("install apple then banana now", "apple banana") == ["apple", "banana"])
check("... in text order, whatever order they were typed in", ranges("install apple then banana now", "banana apple") == ["apple", "banana"])
check("every occurrence of every keyword", ranges("gpt and GPT and Claude, then gPt", "gpt claude") == ["gpt", "GPT", "Claude", "gPt"])
check("a keyword that is not there adds nothing", ranges("only apple here", "apple banana cherry") == ["apple"])
check("overlapping keywords are one highlight, not two fighting ones", ranges("use GPT-5 today", "gpt gpt-5") == ["GPT-5"] && ranges("abcd", "abc bcd") == ["abcd"])
check("touching keywords join", ranges("foobar", "foo bar") == ["foobar"])
check("CJK and emoji keywords", ranges("今天吃苹果🍎和香蕉", "苹果 香蕉 🍎") == ["苹果🍎", "香蕉"])
check("no keywords, or none present: nothing", ranges("text", "   ").isEmpty && ranges("text", "zzz").isEmpty)
check("single keyword: the same ranges as before", ranges("a GPT b gpt c", "gpt") == ["GPT", "gpt"])

check("firstHit: the first keyword TYPED that occurs, not the first in the text",
      K.firstHit(in: "banana first, apple later", terms: ["apple", "banana"])?.term == "apple"
      && K.firstHit(in: "banana only", terms: ["apple", "banana"])?.term == "banana"
      && K.firstHit(in: "neither", terms: ["apple", "banana"]) == nil)

let twoLines = "first line has banana\nsecond line has apple and banana together"
check("hit line with several keywords: the line of the first keyword that occurs", hit(twoLines, "apple banana") == "second line has apple and banana together")
check("... and that line shows both, so both get highlighted", ranges(hit(twoLines, "apple banana") ?? "", "apple banana") == ["apple", "banana"])
check("when the first keyword is absent the next one decides", hit(twoLines, "cherry banana") == "first line has banana")
check("none of the keywords: nil", hit(twoLines, "cherry durian") == nil)
let longTwo = String(repeating: "x", count: 100) + " apple " + String(repeating: "y", count: 30) + " banana " + String(repeating: "z", count: 100)
check("long line: the window is cut around the first keyword and still carries a second one that is close",
      ranges(hit(longTwo, "apple banana") ?? "", "apple banana") == ["apple", "banana"] && (hit(longTwo, "apple banana")?.count ?? 0) <= 92)

// MARK: - [6] multi-keyword OR and escaping against SQLite

print("\n▶️  6. multi-keyword OR and wildcard escaping, against the SQLite of [3]")
session("fruit-text", "Lunch", [[text("we had apple pie")]])
session("fruit-tool", "Shell two", [[toolResult(id: "t9", output: "banana split\nserved")]])
session("fruit-input", "Shell three", [[toolUse(id: "t8", input: #"{"command":"echo durian"}"#)]])
session("fruit-title", "Cherry notes", [[text("nothing to see")]])
session("fruit-none", "Vegetables", [[text("carrot and leek")]])
session("fruit-both", "Mixed", [[text("pie of banana, then apple")]])
session("fruit-opaque", "Opaque", [[toolUse(id: "call_apple77", input: #"{"command":"ls"}"#, sig: "QmFuYW5hbanana")]])
session("pct", "Progress", [[text("now 100% done")]])
session("pct-not", "Inventory", [[text("1000 items left")]])
session("under", "Names", [[text("use a_b here")]])
session("under-not", "Names two", [[text("use axb here")]])
session("pct-title", "50%_off sale", [[text("unrelated")]])
func ids(_ q: String, _ sqlFor: (Int) -> String = SearchKeywords.visibleSQL) -> Set<String> { Set(run(sqlFor, q).map(\.id)) }
let fruits: Set<String> = ["fruit-text", "fruit-tool", "fruit-input", "fruit-title", "fruit-both"]

check("keywords hitting different fields of different sessions: every one of them is a result (text, tool output, tool input, title)",
      ids("apple banana durian cherry") == fruits)
check("a session that matches none of them is not", !ids("apple banana durian cherry").contains("fruit-none"))
check("OR, not AND: two keywords that never share a session still find both", ids("pie served") == ["fruit-text", "fruit-tool", "fruit-both"])
check("no order and no adjacency required: \"apple pie\" finds \"pie of banana, then apple\"", ids("apple pie").contains("fruit-both"))
check("the old whole-string search found neither of those", {
    var st: OpaquePointer?
    sqlite3_prepare_v2(db, SearchKeywords.visibleSQL(termCount: 1), -1, &st, nil)
    defer { sqlite3_finalize(st) }
    sqlite3_bind_text(st, 1, "%pie served%", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    return sqlite3_step(st) != SQLITE_ROW
}())
check("one keyword, no space: the same sessions as a one-keyword search always gave",
      ids("apple") == ["fruit-text", "fruit-both"] && ids("cherry") == ["fruit-title"] && ids("durian") == ["fruit-input"])
check("runs of spaces, tabs and edge whitespace change nothing", ids("  apple \t  banana  ") == ids("apple banana") && ids("apple banana") == ["fruit-text", "fruit-tool", "fruit-both"])
check("a repeated keyword changes nothing", ids("apple APPLE apple") == ids("apple"))
check("nothing but spaces: no search at all", ids("     ").isEmpty && ids("").isEmpty)
check("a keyword absent everywhere beside one that is present: the present one still finds its sessions", ids("zzzzqq banana") == ["fruit-tool", "fruit-both"])
check("visible fields only, per keyword: a hit in a tool-call id or a thought signature is still not a result",
      !ids("apple77 QmFuYW5h").contains("fruit-opaque") && !ids("apple banana").contains("fruit-opaque"))
check("... though the raw-JSON fallback would list it (the caller drops it for showing no line)", ids("apple77", SearchKeywords.legacySQL).contains("fruit-opaque"))
check("the newest matching message is the one handed over, whichever keyword it holds", {
    session("fruit-newest", "Order", [[text("old apple line")], [text("middle")], [text("new banana line")]])
    return run(SearchKeywords.visibleSQL, "apple banana").first { $0.id == "fruit-newest" }?.hit?.contains("new banana line") == true
}())
check("multi-keyword through the fallback statement too", ids("apple cherry", SearchKeywords.legacySQL).isSuperset(of: ["fruit-text", "fruit-title", "fruit-both"]))

check("% in a keyword is a percent sign: \"100%\" finds \"100% done\", not \"1000 items\"", ids("100%") == ["pct"])
check("_ in a keyword is an underscore: \"a_b\" finds \"a_b\", not \"axb\"", ids("a_b") == ["under"])
check("escaping applies to the title match as well", ids("50%_off") == ["pct-title"] && ids("%_") == ["pct-title"])
check("escaping holds inside a multi-keyword search", ids("100% a_b") == ["pct", "under"])
check("before: unescaped, the same input matched the wrong sessions too", {
    func raw(_ pattern: String) -> Set<String> {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, SearchKeywords.visibleSQL(termCount: 1), -1, &st, nil)
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var out = Set<String>()
        while sqlite3_step(st) == SQLITE_ROW { out.insert(String(cString: sqlite3_column_text(st, 0))) }
        return out
    }
    return raw("%100%%").contains("pct-not") && raw("%a_b%").contains("under-not")
}())
check("the fallback statement escapes too", ids("100%", SearchKeywords.legacySQL) == ["pct"] && ids("a_b", SearchKeywords.legacySQL) == ["under"])
sqlite3_close(db)

print("\n▶️  7. source guards for the keyword search")
check("searchSessions splits first and does not search for nothing",
      search.contains("let terms = SearchKeywords.terms(query)\n        guard !terms.isEmpty else { return [] }"))
check("every keyword's escaped pattern is bound, copied by SQLite",
      store.contains("sqlite3_bind_text(stmt, Int32(i + 1), SearchKeywords.likePattern(term), -1, searchBindTransient)")
      && store.contains("private static let searchBindTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)")
      && search.contains("Self.bindSearchPatterns(terms, to: stmt)")
      && between(store, "private func olderSearchSnippet(", "\n    }\n").contains("sqlite3_bind_text(stmt, Int32(terms.count + 1), sessionId, -1, Self.searchBindTransient)"))
check("a title counts when it holds any keyword",
      search.contains("let titleMatched = title.map { SearchKeywords.firstHit(in: $0, terms: terms) != nil } ?? false"))
check("the snippet looks for any keyword in each visible part, in the same part order",
      count(snip, "Self.searchHitLine(in:") == 3 && count(snip, ", terms: terms)") >= 3 && !snip.contains("query:"))
let row = source("Views/ContentView/Sidebar/SessionRow.swift")
check("rows highlight every keyword: title, snippet and preview go through the same ranges",
      row.contains("SearchKeywords.firstHit(in: text, terms: SearchKeywords.terms(query)) != nil {")
      && row.contains("for range in SearchKeywords.hitRanges(in: text, terms: SearchKeywords.terms(query)) {")
      && !row.contains("text.range(of: query, options: .caseInsensitive"))
let moveSheet = source("Views/Chat/AIChatView/Sheets/MoveToSessionSheet.swift")
check("the move-to-session sheet searches and highlights the same way",
      moveSheet.contains("await ChatStore.shared.searchSessions(query: query)")
      && moveSheet.contains("for range in SearchKeywords.hitRanges(in: text, terms: SearchKeywords.terms(query)) {")
      && !moveSheet.contains("lower.range(of: lowerQ"))
check("the search entry still does nothing for a blank field",
      schedule.contains("let query = searchText.trimmingCharacters(in: .whitespaces)\n        guard !query.isEmpty else {"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
