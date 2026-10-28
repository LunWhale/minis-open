#!/usr/bin/env swift
// [T-bubble-span] One locator for retry, delete-from-here and edit.
//
// Field report 2026-09-28: the user stopped a turn, edited the message that
// started it and re-sent; the next request carried the whole previous prompt
// (old message included) plus the new text. All three operations matched chat
// bubbles to agentHistory entries by ordinal ("the n-th user bubble is the
// n-th bubble entry"), which breaks when the two are not 1:1 — a queue drain
// folds several queued bubbles into one entry. Every user bubble is now linked
// to its entry by anchor; the ordinal rule is only the unlinked fallback.
// Edit = delete-from-here + an ordinary send.
//
//   [1] locateUserBubble — pure unit tests (linked / pending / unlinked,
//       merged group first/middle/last, first/last message, empty history)
//   [2] cutPoints — pure unit tests (every span × keep/remove, edges)
//   [3] retry — end-to-end over a session
//   [4] delete-from-here — end-to-end
//   [5] edit — end-to-end
//   [6] regression: the field report (queue merge + stop + edit leaked)
//   [7] Stop race: a stopped send landing after an edit / delete
//   [8] source guards: link sites, bubble-creation allowlist, wiring
//
// [3]–[7] drive the byte-identical ports of the two pure functions through a
// session model that mirrors AIChatViewModel.cutAtUserBubble and send()'s
// landing step (the view model itself cannot be instantiated in a script);
// [8] pins the view model to exactly those calls.
//
// Run: swift BubbleSpanTests.swift
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

/// The sources that used to be the single file Agent/Chat/AIChatViewModel.swift -
/// the class body plus the AIChatViewModel+<Concern>.swift files it was split
/// into (the older extension files are NOT included) - read as one text.
func chatViewModelSource() -> String {
    let chat = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Agent/Chat")
    let names = ["AIChatViewModel", "AIChatViewModel+Lifecycle", "AIChatViewModel+ContextUsage",
                 "AIChatViewModel+StreamingUI", "AIChatViewModel+Speech", "AIChatViewModel+AutoPlayAudio",
                 "AIChatViewModel+SystemPrompt", "AIChatViewModel+Send", "AIChatViewModel+Rerun",
                 "AIChatViewModel+EditMessage", "AIChatViewModel+Cancel", "AIChatViewModel+PromptQueue",
                 "AIChatViewModel+DebugDumps", "AIChatViewModel+TurnCompletion", "AIChatViewModel+AgentLoop",
                 "AIChatViewModel+ThinkingLevel", "LLMProviderError"]
    return names.compactMap { try? String(contentsOf: chat.appendingPathComponent($0 + ".swift"), encoding: .utf8) }
        .joined(separator: "\n")
}

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}

// MARK: - Port (byte-identical with AIChatViewModel.swift, guarded in [8])

enum AIChatViewModel {
    enum UserBubbleSpan: Equatable {
        case linked(entry: Int, firstBubble: Int, lastBubble: Int)
        case pending
        case unlinked(entry: Int?)
    }

    // BEGIN locateUserBubble
    static func locateUserBubble(at idx: Int, uiRows: [(isUser: Bool, anchor: UUID?)], pending: Bool,
                                 historyRows: [(anchor: UUID, isBubble: Bool)]) -> UserBubbleSpan {
        if let anchor = uiRows[idx].anchor,
           let entry = historyRows.firstIndex(where: { $0.anchor == anchor }) {
            let group = uiRows.indices.filter { uiRows[$0].isUser && uiRows[$0].anchor == anchor }
            return .linked(entry: entry, firstBubble: group.first ?? idx, lastBubble: group.last ?? idx)
        }
        if pending { return .pending }
        let n = uiRows[...idx].filter { $0.isUser }.count
        var seen = 0
        for (i, row) in historyRows.enumerated() where row.isBubble {
            seen += 1
            if seen == n { return .unlinked(entry: i) }
        }
        return .unlinked(entry: nil)
    }
    // END locateUserBubble

    // BEGIN cutPoints
    static func cutPoints(for span: UserBubbleSpan, at idx: Int, keepBubble: Bool,
                          historyCount: Int) -> (uiFrom: Int, historyFrom: Int?, keptEntry: Int?) {
        switch span {
        case .linked(let entry, let first, let last):
            return (keepBubble ? last + 1 : first, keepBubble ? entry + 1 : entry, entry)
        case .pending:
            return (keepBubble ? idx + 1 : idx, nil, nil)
        case .unlinked(let entry?):
            return (keepBubble ? idx + 1 : idx, keepBubble ? entry + 1 : entry, entry)
        case .unlinked(nil):
            return (keepBubble ? idx + 1 : idx, nil, historyCount - 1)
        }
    }
    // END cutPoints
}
typealias VM = AIChatViewModel
typealias Span = AIChatViewModel.UserBubbleSpan

// MARK: - [1] locateUserBubble

print("▶️  1. locateUserBubble — pure")
do {
    let a1 = UUID(), g = UUID(), a2 = UUID()
    // chat:    0 u1 | 1 asst | 2 q1 | 3 q2 | 4 q3 | 5 asst | 6 u2
    // history: 0 u1 | 1 asst | 2 tool_result | 3 q1+q2+q3 | 4 asst | 5 u2
    let ui: [(isUser: Bool, anchor: UUID?)] = [(true, a1), (false, nil), (true, g), (true, g), (true, g), (false, nil), (true, a2)]
    let hist: [(anchor: UUID, isBubble: Bool)] = [(a1, true), (UUID(), false), (UUID(), false), (g, true), (UUID(), false), (a2, true)]
    func loc(_ i: Int, pending: Bool = false, _ u: [(isUser: Bool, anchor: UUID?)]? = nil,
             _ h: [(anchor: UUID, isBubble: Bool)]? = nil) -> Span {
        VM.locateUserBubble(at: i, uiRows: u ?? ui, pending: pending, historyRows: h ?? hist)
    }

    // linked
    check("linked: first message", loc(0) == .linked(entry: 0, firstBubble: 0, lastBubble: 0))
    check("linked: last message", loc(6) == .linked(entry: 5, firstBubble: 6, lastBubble: 6))
    check("linked: merged group — FIRST bubble reports the whole group", loc(2) == .linked(entry: 3, firstBubble: 2, lastBubble: 4))
    check("linked: merged group — MIDDLE bubble, same", loc(3) == .linked(entry: 3, firstBubble: 2, lastBubble: 4))
    check("linked: merged group — LAST bubble, same", loc(4) == .linked(entry: 3, firstBubble: 2, lastBubble: 4))
    check("linked: synthetic history rows before the entry are counted in its index", loc(6) == .linked(entry: 5, firstBubble: 6, lastBubble: 6))
    check("linked wins over a (stale) pending flag", loc(6, pending: true) == .linked(entry: 5, firstBubble: 6, lastBubble: 6))
    let split: [(isUser: Bool, anchor: UUID?)] = [(true, g), (false, nil), (true, g)]
    check("linked: a group split by another row still spans both bubbles",
          loc(2, split, [(g, true)]) == .linked(entry: 0, firstBubble: 0, lastBubble: 2))
    check("linked: an assistant row never joins a group, even with a stray anchor",
          loc(0, [(true, g), (false, g)], [(g, true)]) == .linked(entry: 0, firstBubble: 0, lastBubble: 0))

    // pending
    let pendUI: [(isUser: Bool, anchor: UUID?)] = [(true, a1), (false, nil), (true, nil)]
    check("pending: send() has not landed the entry", loc(2, pending: true, pendUI, [(a1, true), (UUID(), false)]) == .pending)
    check("pending: an anchor whose entry is gone does not hide the pending state",
          loc(0, pending: true, [(true, UUID())], [(a1, true)]) == .pending)
    check("pending: on an empty history", loc(0, pending: true, [(true, nil)], []) == .pending)

    // unlinked (ordinal fallback)
    let plainUI: [(isUser: Bool, anchor: UUID?)] = [(true, nil), (false, nil), (true, nil), (false, nil), (true, nil)]
    let plainH: [(anchor: UUID, isBubble: Bool)] = [(UUID(), true), (UUID(), false), (UUID(), false), (UUID(), true), (UUID(), false), (UUID(), true)]
    check("unlinked: first message → first bubble entry", loc(0, plainUI, plainH) == .unlinked(entry: 0))
    check("unlinked: middle message skips tool_result rows", loc(2, plainUI, plainH) == .unlinked(entry: 3))
    check("unlinked: last message", loc(4, plainUI, plainH) == .unlinked(entry: 5))
    check("unlinked: assistant chat rows are not counted",
          loc(2, plainUI, plainH) == loc(1, [(true, nil), (true, nil), (true, nil)], plainH)
          && loc(4, plainUI, plainH) == loc(2, [(true, nil), (true, nil), (true, nil)], plainH))
    check("unlinked: an anchor missing from history falls back to the ordinal",
          loc(2, [(true, nil), (false, nil), (true, UUID())], plainH) == .unlinked(entry: 3))
    check("unlinked: more chat bubbles than bubble entries → not found",
          loc(4, plainUI, [(UUID(), true), (UUID(), false)]) == .unlinked(entry: nil))
    check("unlinked: empty history → not found", loc(0, [(true, nil)], []) == .unlinked(entry: nil))
    check("unlinked: an anchor on an empty history → not found", loc(0, [(true, a1)], []) == .unlinked(entry: nil))
}

// MARK: - [2] cutPoints

print("\n▶️  2. cutPoints — pure")
do {
    func cp(_ s: Span, _ i: Int, keep: Bool, n: Int = 10) -> (Int, Int?, Int?) {
        let r = VM.cutPoints(for: s, at: i, keepBubble: keep, historyCount: n)
        return (r.uiFrom, r.historyFrom, r.keptEntry)
    }
    func eq(_ a: (Int, Int?, Int?), _ b: (Int, Int?, Int?)) -> Bool { a.0 == b.0 && a.1 == b.1 && a.2 == b.2 }
    let grp = Span.linked(entry: 3, firstBubble: 2, lastBubble: 4)
    check("linked, keep (retry): chat after the group's LAST bubble, history after the entry",
          eq(cp(grp, 3, keep: true), (5, 4, 3)))
    check("linked, remove (delete/edit): chat from the group's FIRST bubble, history from the entry",
          eq(cp(grp, 3, keep: false), (2, 3, 3)))
    check("linked single bubble, keep", eq(cp(.linked(entry: 5, firstBubble: 6, lastBubble: 6), 6, keep: true), (7, 6, 5)))
    check("linked first message, remove: everything goes", eq(cp(.linked(entry: 0, firstBubble: 0, lastBubble: 0), 0, keep: false), (0, 0, 0)))
    check("pending, keep: chat after the bubble, history untouched, nothing to re-run", eq(cp(.pending, 4, keep: true), (5, nil, nil)))
    check("pending, remove: chat from the bubble, history untouched", eq(cp(.pending, 4, keep: false), (4, nil, nil)))
    check("unlinked found, keep", eq(cp(.unlinked(entry: 3), 2, keep: true), (3, 4, 3)))
    check("unlinked found, remove", eq(cp(.unlinked(entry: 3), 2, keep: false), (2, 3, 3)))
    check("unlinked not found, keep: history kept whole, re-run from its last entry (fail open)",
          eq(cp(.unlinked(entry: nil), 4, keep: true, n: 6), (5, nil, 5)))
    check("unlinked not found, remove: history kept whole (fail open)", eq(cp(.unlinked(entry: nil), 4, keep: false, n: 6), (4, nil, 5)))
    check("unlinked not found on an empty history: kept entry -1 (the caller guards an empty history)",
          eq(cp(.unlinked(entry: nil), 0, keep: true, n: 0), (1, nil, -1)))
}

// MARK: - Session model (mirrors cutAtUserBubble + send()'s landing step)

struct UIRow { let label: String; let isUser: Bool; var anchor: UUID?; var pending = false }
struct HRow { let label: String; let anchor: UUID; let isBubble: Bool; var dbId: String? = nil }

struct Session {
    var ui: [UIRow] = []
    var history: [HRow] = []
    var abandoned: Set<String> = []   // abandonedPendingSendIds
    var keptEntry: Int?
    var span: Span?

    /// send() whose entry landed (linked).
    mutating func user(_ l: String) { let a = UUID(); ui.append(UIRow(label: l, isUser: true, anchor: a)); history.append(HRow(label: l, anchor: a, isBubble: true)) }
    mutating func asst(_ l: String) { ui.append(UIRow(label: l, isUser: false, anchor: nil)); history.append(HRow(label: l, anchor: UUID(), isBubble: false)) }
    /// History-only rows: tool_result carriers, reminders, the preempt bridge.
    mutating func synthetic(_ l: String) { history.append(HRow(label: l, anchor: UUID(), isBubble: false)) }
    /// A queue drain: N bubbles, ONE entry.
    mutating func merged(_ ls: [String]) {
        let a = UUID()
        for l in ls { ui.append(UIRow(label: l, isUser: true, anchor: a)) }
        history.append(HRow(label: ls.joined(separator: "+"), anchor: a, isBubble: true))
    }
    /// send() showed the bubble; its entry has not landed yet.
    mutating func pendingSend(_ l: String) { ui.append(UIRow(label: l, isUser: true, anchor: nil, pending: true)) }
    /// send()'s landing step: the abandon check, then append + link.
    @discardableResult
    mutating func land(_ l: String) -> Bool {
        if abandoned.remove(l) != nil { return false }
        let a = UUID()
        history.append(HRow(label: l, anchor: a, isBubble: true))
        if let i = ui.firstIndex(where: { $0.label == l }) { ui[i].anchor = a; ui[i].pending = false }
        return true
    }
    mutating func unlinkAll() { for i in ui.indices { ui[i].anchor = nil } }

    mutating func cut(_ label: String, keepBubble: Bool) {
        let idx = ui.firstIndex(where: { $0.label == label })!
        let span = VM.locateUserBubble(
            at: idx, uiRows: ui.map { ($0.isUser, $0.isUser ? $0.anchor : nil) }, pending: ui[idx].pending,
            historyRows: history.map { ($0.anchor, $0.isBubble) })
        let c = VM.cutPoints(for: span, at: idx, keepBubble: keepBubble, historyCount: history.count)
        self.span = span
        keptEntry = c.keptEntry
        if c.uiFrom < ui.count {
            for r in ui[c.uiFrom...] where r.isUser && r.pending { abandoned.insert(r.label) }
            ui.removeSubrange(c.uiFrom...)
        }
        if let h = c.historyFrom, h < history.count { history.removeSubrange(h...) }
    }
    /// retryFromMessage: a pending bubble is ignored.
    mutating func retry(_ l: String) {
        if let r = ui.first(where: { $0.label == l }), r.pending { return }
        cut(l, keepBubble: true)
    }
    mutating func delete(_ l: String) { cut(l, keepBubble: false) }
    /// send()'s edit branch: delete-from-here, then the ordinary send.
    mutating func edit(_ l: String, to new: String) { cut(l, keepBubble: false); user(new) }

    var uiLabels: [String] { ui.map(\.label) }
    var historyLabels: [String] { history.map(\.label) }
    /// What the chat shows is what the model keeps: every linked bubble's entry
    /// is in history, and every bubble entry is shown by at least one bubble.
    var consistent: Bool {
        let bubbleAnchors = Set(ui.filter(\.isUser).compactMap(\.anchor))
        let entryAnchors = Set(history.filter(\.isBubble).map(\.anchor))
        return bubbleAnchors == entryAnchors
    }
}

// The pre-fix ordinal rules, for before/after comparisons: the history each
// operation used to leave.
func oldRetry(_ s: Session, _ label: String) -> [String] {
    let idx = s.ui.firstIndex(where: { $0.label == label })!
    let n = s.ui[...idx].filter(\.isUser).count
    var seen = 0
    for (i, h) in s.history.enumerated() where h.isBubble { seen += 1; if seen == n { return s.history[...i].map(\.label) } }
    return s.historyLabels
}
func oldDelete(_ s: Session, _ label: String) -> [String] {
    let idx = s.ui.firstIndex(where: { $0.label == label })!
    let n = s.ui[..<idx].filter(\.isUser).count + 1
    var seen = 0
    for (i, h) in s.history.enumerated() where h.isBubble { seen += 1; if seen == n { return s.history[..<i].map(\.label) } }
    return s.historyLabels
}
func oldEdit(_ s: Session, _ label: String, to new: String) -> [String] { oldDelete(s, label) + [new] }

/// u1 a1 (tool) u2 a2 u3 a3 — aligned, linked.
func aligned() -> Session {
    var s = Session()
    s.user("u1"); s.asst("a1"); s.synthetic("tool_result"); s.asst("a1b"); s.user("u2"); s.asst("a2"); s.user("u3"); s.asst("a3")
    return s
}
/// u1 a1 [q1 q2 q3 → one entry] a2 u3 a3 u4 a4 — misaligned for the ordinal rule.
func mergedSession() -> Session {
    var s = Session()
    s.user("u1"); s.asst("a1"); s.merged(["q1", "q2", "q3"]); s.asst("a2"); s.user("u3"); s.asst("a3"); s.user("u4"); s.asst("a4")
    return s
}

// MARK: - [3] retry

print("\n▶️  3. retry — end-to-end")
do {
    let base = aligned()
    var r = base; r.retry("u2")
    check("aligned middle: chat and context end at U2", r.uiLabels == ["u1", "a1", "a1b", "u2"]
          && r.historyLabels == ["u1", "a1", "tool_result", "a1b", "u2"] && r.keptEntry == 4 && r.consistent)
    check("aligned middle: same result as the old rule", r.historyLabels == oldRetry(base, "u2"))
    var f = base; f.retry("u1")
    check("first message", f.uiLabels == ["u1"] && f.historyLabels == ["u1"] && f.keptEntry == 0)
    var l = base; l.retry("u3")
    check("last message", l.uiLabels == ["u1", "a1", "a1b", "u2", "a2", "u3"] && l.historyLabels.last == "u3" && l.consistent)

    let m = mergedSession()
    var mr = m; mr.retry("u3")
    check("after a merged entry: context ends at U3 (old rule kept A3+U4)",
          mr.historyLabels == ["u1", "a1", "q1+q2+q3", "a2", "u3"] && oldRetry(m, "u3").contains("u4") && mr.consistent)
    for (name, label) in [("first", "q1"), ("middle", "q2"), ("last", "q3")] {
        var g = m; g.retry(label)
        check("merged group, \(name) bubble: keeps through the group's last bubble",
              g.uiLabels == ["u1", "a1", "q1", "q2", "q3"] && g.historyLabels == ["u1", "a1", "q1+q2+q3"] && g.consistent)
    }

    var p = Session(); p.user("u1"); p.asst("a1"); p.pendingSend("u2")
    let before = p; p.retry("u2")
    check("pending bubble: retry ignored", p.uiLabels == before.uiLabels && p.historyLabels == before.historyLabels)

    var u = aligned(); u.unlinkAll(); u.retry("u2")
    check("unlinked aligned: ordinal fallback gives the same cut", u.span == .unlinked(entry: 4) && u.historyLabels.last == "u2")
    var um = mergedSession(); um.unlinkAll(); let umBefore = um.historyLabels; um.retry("u4")
    check("unlinked misaligned, not found: history kept whole, re-run from its end",
          um.span == .unlinked(entry: nil) && um.historyLabels == umBefore && um.keptEntry == umBefore.count - 1)
}

// MARK: - [4] delete-from-here

print("\n▶️  4. delete-from-here — end-to-end")
do {
    let base = aligned()
    var d = base; d.delete("u2")
    check("aligned middle", d.uiLabels == ["u1", "a1", "a1b"] && d.historyLabels == ["u1", "a1", "tool_result", "a1b"]
          && d.historyLabels == oldDelete(base, "u2") && d.consistent)
    var f = base; f.delete("u1")
    check("first message: chat and context empty", f.uiLabels.isEmpty && f.historyLabels.isEmpty)
    var l = base; l.delete("u3")
    check("last message", l.uiLabels == ["u1", "a1", "a1b", "u2", "a2"] && l.historyLabels.last == "a2" && l.consistent)

    let m = mergedSession()
    var md = m; md.delete("u3")
    check("after a merged entry: U3 leaves the context (old rule kept it)",
          md.historyLabels == ["u1", "a1", "q1+q2+q3", "a2"] && oldDelete(m, "u3").contains("u3") && md.consistent)
    for (name, label) in [("first", "q1"), ("middle", "q2"), ("last", "q3")] {
        var g = m; g.delete(label)
        check("merged group, \(name) bubble: the whole group goes",
              g.uiLabels == ["u1", "a1"] && g.historyLabels == ["u1", "a1"] && g.consistent)
    }

    var p = Session(); p.user("u1"); p.asst("a1"); p.pendingSend("u2"); p.delete("u2")
    check("pending bubble: chat cut, history untouched, send abandoned",
          p.uiLabels == ["u1", "a1"] && p.historyLabels == ["u1", "a1"] && p.abandoned == ["u2"])

    var um = mergedSession(); um.unlinkAll(); let umBefore = um.historyLabels; um.delete("u4")
    check("unlinked misaligned, not found: chat cut, history kept whole (fail open)",
          um.historyLabels == umBefore && um.uiLabels.last == "a3")
}

// MARK: - [5] edit

print("\n▶️  5. edit — end-to-end (delete-from-here + ordinary send)")
do {
    let base = aligned()
    var e = base; e.edit("u2", to: "E")
    check("aligned middle: E takes U2's place", e.uiLabels == ["u1", "a1", "a1b", "E"]
          && e.historyLabels == ["u1", "a1", "tool_result", "a1b", "E"] && e.historyLabels == oldEdit(base, "u2", to: "E") && e.consistent)
    var f = base; f.edit("u1", to: "E")
    check("first message", f.uiLabels == ["E"] && f.historyLabels == ["E"])
    var l = base; l.edit("u3", to: "E")
    check("last message", l.historyLabels == ["u1", "a1", "tool_result", "a1b", "u2", "a2", "E"] && !l.historyLabels.contains("u3"))

    let m = mergedSession()
    var me = m; me.edit("u3", to: "E")
    check("after a merged entry: no trace of U3 (old rule leaked it)",
          !me.historyLabels.contains("u3") && oldEdit(m, "u3", to: "E").contains("u3") && me.consistent)
    for (name, label) in [("first", "q1"), ("middle", "q2"), ("last", "q3")] {
        var g = m; g.edit(label, to: "E")
        check("merged group, \(name) bubble: the group is replaced by E",
              g.uiLabels == ["u1", "a1", "E"] && g.historyLabels == ["u1", "a1", "E"] && g.consistent)
    }

    var p = Session(); p.user("u1"); p.asst("a1"); p.pendingSend("old"); p.edit("old", to: "E")
    check("pending bubble: E sent, old never enters the context",
          p.historyLabels == ["u1", "a1", "E"] && p.abandoned == ["old"])

    var un = aligned(); un.unlinkAll(); un.edit("u2", to: "E")
    check("unlinked aligned: ordinal fallback, same result", un.historyLabels == ["u1", "a1", "tool_result", "a1b", "E"])
    var um = mergedSession(); um.unlinkAll(); um.edit("u4", to: "E")
    check("unlinked misaligned, not found: fail open — E appended, history otherwise kept (the only leak left)",
          um.historyLabels.suffix(2) == ["a4", "E"])
}

// MARK: - [6] regression: the field report

print("\n▶️  6. regression — queue merge, stop, edit (field report 2026-09-28)")
do {
    // The reported session's shape: a task with tool rounds, a mid-task user
    // interjection (preempt bridge), two sub-agent callbacks, a later queue
    // drain that merged two queued messages, then the message that was
    // stopped before any answer and edited.
    var s = Session()
    s.user("telegram task"); s.asst("tool_use"); s.synthetic("tool_result")
    s.synthetic("bridge: interrupted mid-task"); s.user("不要用关键字过滤，仔细阅读")
    s.asst("tool_use 2"); s.synthetic("tool_result 2"); s.asst("batches dispatched")
    s.user("<agent_callback 1>"); s.asst("batch 1 done"); s.user("<agent_callback 2>"); s.asst("report")
    s.merged(["恢复备份…他原话怎么说", "这个应该修复过了？去看看commit"]); s.asst("answer")
    s.user("review the always-on fix"); s.asst("要不要我把这个用户感知层面的困惑…")
    s.user("关闭不用持久化，否则太多了")   // request #4 — stopped: its answer never committed
    let prefix = Array(s.historyLabels.dropLast())
    check("OLD: reproduces — request #5 carried the old message AND the new one",
          oldEdit(s, "关闭不用持久化，否则太多了", to: "现在关闭之后的设置持久化放在哪里?").suffix(2)
            == ["关闭不用持久化，否则太多了", "现在关闭之后的设置持久化放在哪里?"])

    var e = s; e.edit("关闭不用持久化，否则太多了", to: "现在关闭之后的设置持久化放在哪里?")
    check("NEW: context = the unchanged prefix + the edited message only",
          e.historyLabels == prefix + ["现在关闭之后的设置持久化放在哪里?"])
    check("NEW: the chat shows the same thing", e.uiLabels.last == "现在关闭之后的设置持久化放在哪里?"
          && !e.uiLabels.contains("关闭不用持久化，否则太多了") && e.consistent)
    check("NEW: the cut was an exact anchor match", e.span == .linked(entry: prefix.count, firstBubble: e.uiLabels.count - 1, lastBubble: e.uiLabels.count - 1))

    // Variant: the answer to #4 WAS committed before the edit.
    var a = s; a.asst("answer to #4"); a.edit("关闭不用持久化，否则太多了", to: "现在关闭之后的设置持久化放在哪里?")
    check("variant, answered: old message and its answer both leave the context",
          a.historyLabels == prefix + ["现在关闭之后的设置持久化放在哪里?"])

    // Variant: Stop hit before the old message's entry even landed.
    var p = s; p.history.removeLast(); p.ui.removeLast(); p.pendingSend("关闭不用持久化，否则太多了")
    p.edit("关闭不用持久化，否则太多了", to: "现在关闭之后的设置持久化放在哪里?")
    p.land("关闭不用持久化，否则太多了")
    check("variant, not landed yet: the late landing is dropped",
          p.historyLabels == prefix + ["现在关闭之后的设置持久化放在哪里?"])
}

// MARK: - [7] Stop race

print("\n▶️  7. Stop race — a stopped send landing after the cut")
do {
    var base = Session(); base.user("u1"); base.asst("a1"); base.pendingSend("old")

    var o = base; o.ui.removeLast(); o.user("new"); o.history.append(HRow(label: "old", anchor: UUID(), isBubble: true))
    check("OLD: reproduces — without the abandon check the old message lands behind the edit", o.historyLabels.contains("old"))

    var e = base; e.edit("old", to: "new")
    check("Stop → edit: span is .pending and the send is marked abandoned", e.span == .pending && e.abandoned == ["old"])
    check("…the late landing is dropped", !e.land("old") && e.historyLabels == ["u1", "a1", "new"])
    check("…and consumes its mark", e.abandoned.isEmpty)

    var d = base; d.delete("old")
    check("Stop → delete: the late landing is dropped", !d.land("old") && d.historyLabels == ["u1", "a1"] && d.uiLabels == ["u1", "a1"])

    var n = base
    check("Stop, nothing else: the send lands and links", n.land("old") && n.ui.last?.anchor != nil && n.ui.last?.pending == false)
    var ne = n; ne.edit("old", to: "new")
    check("…then an edit is an exact linked cut", ne.historyLabels == ["u1", "a1", "new"] && ne.span != .pending)

    var older = Session(); older.user("u1"); older.asst("a1"); older.user("u2"); older.asst("a2"); older.pendingSend("late")
    older.edit("u2", to: "E")
    check("editing an OLDER message abandons the pending send the cut removed",
          older.abandoned == ["late"] && !older.land("late") && older.historyLabels == ["u1", "a1", "E"])

    var other = base; other.delete("old")
    other.pendingSend("fresh")
    check("an abandon mark only affects its own send", other.land("fresh") && other.historyLabels.last == "fresh")

    var rr = base; rr.retry("old")
    check("retry on a pending bubble is ignored", rr.historyLabels == ["u1", "a1"] && rr.uiLabels == ["u1", "a1", "old"])
    rr.land("old"); rr.retry("old")
    check("…and works once the entry landed", rr.historyLabels == ["u1", "a1", "old"] && rr.keptEntry == 2)

    // DB-id write-back: send() awaits persist AFTER appending; a Stop + edit
    // in that window replaces the entry at the same index.
    var h: [HRow] = [HRow(label: "u1", anchor: UUID(), isBubble: true), HRow(label: "a1", anchor: UUID(), isBubble: false)]
    let oldAnchor = UUID(); let oldIdx = h.count
    h.append(HRow(label: "old", anchor: oldAnchor, isBubble: true))   // appended, persist in flight
    h.removeLast(); h.append(HRow(label: "new", anchor: UUID(), isBubble: true))  // edit cut + new send
    var byIndex = h; if oldIdx < byIndex.count { byIndex[oldIdx].dbId = "db-old" }
    check("OLD: reproduces — index write-back stamps the old row's id on the new entry", byIndex[oldIdx].dbId == "db-old")
    var byAnchor = h; if let i = byAnchor.firstIndex(where: { $0.anchor == oldAnchor }) { byAnchor[i].dbId = "db-old" }
    check("NEW: anchor write-back finds nothing — the new entry keeps its own id", byAnchor.allSatisfy { $0.dbId == nil })
}

// MARK: - [8] source guards

print("\n▶️  8. source guards")
let iosRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String {
    (try? String(contentsOf: iosRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func between(_ s: String, _ a: String, _ b: String) -> String {
    guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return "" }
    return String(s[r1.upperBound..<r2.lowerBound])
}
let vm = chatViewModelSource()
let me = (try? String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)) ?? ""
for name in ["locateUserBubble", "cutPoints"] {
    let app = between(vm, "// BEGIN \(name)", "// END \(name)")
    check("\(name) port is byte-identical with the app", !app.isEmpty && app == between(me, "// BEGIN \(name)", "// END \(name)"))
}
let cutFn = between(vm, "func cutAtUserBubble(", "\n    }\n")
check("the view model's cut = locateUserBubble + cutPoints + the same removals as the model",
      cutFn.contains("Self.locateUserBubble(") && cutFn.contains("Self.cutPoints(for: span, at: idx, keepBubble: keepBubble,")
      && cutFn.contains("for msg in messages[uiFrom...] where msg.role == .user && msg.awaitingHistoryEntry {\n                abandonedPendingSendIds.insert(msg.id)")
      && cutFn.contains("messages.removeSubrange(uiFrom...)")
      && cutFn.contains("if let historyFrom, historyFrom < agentHistory.count {\n            agentHistory.removeSubrange(historyFrom...)"))
check("…feeding it user-only anchors and bubble entries",
      cutFn.contains("uiRows: messages.map { ($0.role == .user, $0.role == .user ? $0.historyAnchorId : nil) }")
      && cutFn.contains("pending: messages[idx].awaitingHistoryEntry")
      && cutFn.contains("historyRows: agentHistory.map { ($0.anchorId, Self.isUserBubbleEntry($0)) }"))

// Link sites.
let persistence = source("Agent/Chat/AIChatViewModel+Persistence.swift")
check("AgentMessage carries an in-memory anchorId", source("Providers/AgentProvider.swift").contains("    var anchorId = UUID()\n}"))
check("ChatMessage carries historyAnchorId + awaitingHistoryEntry",
      source("Agent/Chat/ChatModels.swift").contains("var historyAnchorId: UUID?")
      && source("Agent/Chat/ChatModels.swift").contains("var awaitingHistoryEntry = false"))
check("link 1/5 send(): bubble born pending, linked when its entry lands",
      vm.contains("userMsg.awaitingHistoryEntry = true")
      && vm.contains("self.agentHistory.append(userMessage)\n            userMsg.historyAnchorId = userMessage.anchorId\n            userMsg.awaitingHistoryEntry = false"))
check("link 2/5 drainQueuedPromptsInner: every drained bubble → the merged entry",
      vm.contains("self.agentHistory.append(queueAgentMsg)\n            // [T-edit-anchor-link] Every drained bubble links to the one entry.\n            for msg in self.messages where msg.queuedPromptId.map(queuedIds.contains) == true {\n                msg.historyAnchorId = queueAgentMsg.anchorId"))
check("link 3/5 injectQueuedPromptsAsNewTurn: same",
      vm.contains("agentHistory.append(queueMsg)\n        // [T-edit-anchor-link] Every injected bubble links to the one entry.\n        for msg in messages where msg.queuedPromptId.map(queuedIds.contains) == true {\n            msg.historyAnchorId = queueMsg.anchorId"))
check("link 4/5 steer", vm.contains("let uiMsg = ChatMessage(role: .user, content: note)\n                uiMsg.historyAnchorId = steerMsg.anchorId"))
check("link 5/5 loadSession: bubble and entry from the same row",
      persistence.contains("msg.historyAnchorId = agentMsg.anchorId\n            loadedUIMessages.append(msg)"))
check("anchors are never persisted (ChatStore does not know them)",
      !chatStoreSource().contains("anchorId"))

// Bubble-creation allowlist: a new site must be linked and listed here.
var creations: [String: Int] = [:]
var loadCalls: [String: Int] = [:]
if let walker = FileManager.default.enumerator(at: iosRoot, includingPropertiesForKeys: nil) {
    for case let url as URL in walker where url.pathExtension == "swift" {
        let rel = url.path.replacingOccurrences(of: iosRoot.path + "/", with: "")
        if rel.hasPrefix("MinisTests/") || rel.contains("/build/") { continue }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        let c = text.components(separatedBy: "ChatMessage(role: .user").count - 1
        if c > 0 { creations[rel] = c }
        let l = text.components(separatedBy: ".toChatMessage(").count - 1
        if l > 0 { loadCalls[rel] = l }
    }
}
let allowed: [String: Int] = [
    "Agent/Chat/AIChatViewModel+Send.swift": 1,        // send() (link 1)
    "Agent/Chat/AIChatViewModel+AgentLoop.swift": 1,   // steer (link 4)
    "Agent/Chat/AIChatViewModel+Misc.swift": 1,        // enqueuePrompt → linked at drain / inject (2, 3)
    "Agent/Chat/AIChatViewModel+Compaction.swift": 1,  // compact-and-send queue → drain (2)
    "Debug/SessionDataSimulator.swift": 1,             // debug playback, UI only, no agentHistory
]
check("every user-bubble creation site is on the allowlist (new site? link it, then list it) — found \(creations)",
      creations == allowed)
check("toChatMessage is only called by loadSession (link 5) — found \(loadCalls)",
      loadCalls == ["Agent/Chat/AIChatViewModel+Persistence.swift": 3])
check("queued bubbles (enqueue / compact-and-send) carry the queuedPromptId the drain links by",
      source("Agent/Chat/AIChatViewModel+Misc.swift").contains("chatMsg.queuedPromptId = prompt.id")
      && source("Agent/Chat/AIChatViewModel+Compaction.swift").contains("chatMsg.queuedPromptId ="))

// Operations.
let retryFn = between(vm, "    func retryFromMessage(", "\n    }\n")
let deleteFn = between(vm, "    func deleteFromMessage(", "\n    }\n")
let sendFn = between(vm, "    func send(overrideText: String? = nil) {", "\n    }\n")
check("retry uses the shared cut, keeping the bubble", retryFn.contains("cutAtUserBubble(idx, keepBubble: true, site: \"retryFromMessage\")"))
check("retry ignores a pending bubble before cutting", {
    guard let p = retryFn.range(of: "if messages[idx].awaitingHistoryEntry {"),
          let c = retryFn.range(of: "cutAtUserBubble(") else { return false }
    return p.lowerBound < c.lowerBound
}())
check("delete uses the shared cut, removing the bubble", deleteFn.contains("cutAtUserBubble(idx, keepBubble: false, site: \"deleteFromMessage\")"))
check("edit = delete-from-here + the ordinary send (no return in the edit branch)", {
    let branch = between(sendFn, "if editingMessageIndex != nil {", "// Close any stale tool blocks")
    return branch.contains("cutAtUserBubble(editIdx, keepBubble: false, site: \"edit\")") && !branch.contains("return")
}())
check("the edit is re-found by id first",
      between(vm, "func resolveEditedBubbleIndex()", "\n    }\n").contains("messages.firstIndex(where: { $0.id == id })"))
check("send() checks the abandon mark BEFORE appending its entry", {
    guard let chk = sendFn.range(of: "if self.abandonedPendingSendIds.remove(userMsg.id) != nil {"),
          let app = sendFn.range(of: "self.agentHistory.append(userMessage)") else { return false }
    return chk.lowerBound < app.lowerBound
}())
check("…and drops the turn without touching isProcessing",
      between(sendFn, "if self.abandonedPendingSendIds.remove(userMsg.id) != nil {", "}").contains("return")
      && !between(sendFn, "if self.abandonedPendingSendIds.remove(userMsg.id) != nil {", "}").contains("isProcessing"))
check("send() writes the DB id back by anchor, not index",
      sendFn.contains("let i = self.agentHistory.firstIndex(where: { $0.anchorId == userMessage.anchorId })"))
check("the three ordinal copies are gone",
      !vm.contains("targetUserCount") && !vm.contains("keepUserCount") && !vm.contains("remainingUserCount"))
check("the 8a1bf2e8b multi-rule code is gone",
      !vm.contains("resolveEditHistoryCut") && !vm.contains("planEdit") && !vm.contains("editSupersedeNote"))
check("its refusal string is gone from the catalog",
      !source("Localizable.xcstrings").contains("Couldn't find the original message in this chat's history"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
