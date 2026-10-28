#!/usr/bin/env swift
// [T-queued-candidate-spacing] With "<name> is thinking…" on screen, a prompt
// sent as a queued candidate (dashed bubble with a withdraw button) made the
// rows close up: the "is thinking…" row sat directly under the last tool row
// with no gap, and when that row was not drawn the candidate bubble itself
// touched the tool row.
//
// Root cause: the list decided "this is the message in progress" by
// `messages.last`. A queued candidate is appended to `messages` at once, so
// from that moment the reply still being written was not "last" any more:
//   - its footer was seeded as a quiet footer (hug = no gap above it);
//   - it left the streaming ranges (the second rule that keeps that gap),
//     unless a tool happened to be running;
//   - the next bridge refresh switched its "active" flag off.
// And an EMPTY hugging footer added no gap after itself either, so whatever
// followed it touched the reply.
//
// Fix: one rule for "the message in progress" - the last message that is not
// a queued candidate (LiveTail) - used by the bridge, the footer seed and the
// streaming ranges; and an empty hugging footer hands on the gap the row above
// withheld for it (MessageRowGap).
//
// [1] runs the two shipping rules against a model of the list's layout pass.
// [2] pins the wiring in the shipping sources.
//
// Run: swift QueuedCandidateSpacingTests.swift
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
let iosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String {
    (try? String(contentsOf: iosRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func code(_ src: String) -> String {
    src.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
}
/// The body of the function / block that starts with `header`, up to the next
/// line that starts a sibling declaration at the same indentation.
func block(_ src: String, _ header: String) -> String {
    guard let r = src.range(of: header) else { return "" }
    let indent = String(header.prefix { $0 == " " })
    var out: [String] = []
    for (i, line) in src[r.lowerBound...].components(separatedBy: "\n").enumerated() {
        if i > 0, line.hasPrefix(indent + "}") { out.append(line); break }
        out.append(line)
    }
    return out.joined(separator: "\n")
}

let V3 = "Agent/MessageList/CollectionViewMessageListV3/"
let rules = source(V3 + "Support/QueuedCandidateSpacing.swift")

// MARK: - 1. The shipping rules against a model of the layout pass

let scenario = #"""

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }

let spacing: CGFloat = 8

/// One message as the list sees it.
struct Msg {
    var id: String
    var isAssistant: Bool
    var isQueued = false
    var showsTyping = false      // ChatMessage.shouldShowTypingIndicator
    var hasLiveTool = false
}

/// One list row. `footerOf` is set on a footer row.
struct Row {
    var name: String
    var height: CGFloat
    var owner: String
    var footerOf: String? = nil
}

/// How "the message in progress" is found: the shipping rule, or the old one.
enum TailRule { case liveTail, literalLast }

func tail(_ messages: [Msg], _ rule: TailRule) -> Msg? {
    switch rule {
    case .liveTail: return LiveTail.index(in: messages, isQueuedCandidate: { $0.isQueued }).map { messages[$0] }
    case .literalLast: return messages.last
    }
}

/// Mirrors liveAssistantMessageIds.
func liveIds(_ messages: [Msg], _ rule: TailRule, processing: Bool = true) -> Set<String> {
    guard processing else { return [] }
    var ids: Set<String> = []
    let t = tail(messages, rule)
    if let t, t.isAssistant { ids.insert(t.id) }
    for m in messages where m.isAssistant && m.id != t?.id && m.hasLiveTool { ids.insert(m.id) }
    return ids
}

/// Mirrors MessageListLayout.prepare(): the y of every row.
/// `oldGapRule` reproduces the rule before the fix.
func layout(_ messages: [Msg], _ rows: [Row], rule: TailRule, oldGapRule: Bool = false,
            processing: Bool = true) -> [String: (top: CGFloat, bottom: CGFloat)] {
    // Streaming range: from the first row of the last live message, open-ended.
    let live = liveIds(messages, rule, processing: processing)
    let streamingStart = rows.lastIndex(where: { r in live.contains(r.owner) })
        .flatMap { last in rows.firstIndex(where: { $0.owner == rows[last].owner }) }
    func isStreaming(_ i: Int) -> Bool { streamingStart.map { i >= $0 } ?? false }
    // Footer hug flag, as the snapshot seeds it: quiet footer hugs.
    func hugs(_ i: Int) -> Bool {
        guard let fid = rows[i].footerOf, let m = messages.first(where: { $0.id == fid }) else { return false }
        let isActive = processing && tail(messages, rule)?.id == fid && m.showsTyping
        return !isActive
    }
    var out: [String: (top: CGFloat, bottom: CGFloat)] = [:]
    var y: CGFloat = 0
    var gapWithheld = false
    for i in rows.indices {
        let h = rows[i].height
        out[rows[i].name] = (y, y + h)
        y += h
        let isLast = i + 1 == rows.count
        let nextIsFooter = !isLast && rows[i + 1].footerOf != nil && hugs(i + 1) && !isStreaming(i + 1)
        if oldGapRule {
            if !isLast, !nextIsFooter, h > 0 { y += spacing }
        } else {
            y += MessageRowGap.after(height: h, isLast: isLast, nextIsHuggingFooter: nextIsFooter,
                                     gapWithheldBefore: gapWithheld, spacing: spacing)
            gapWithheld = nextIsFooter && h > 0
        }
    }
    out["#end"] = (y, y)
    return out
}
func gap(_ l: [String: (top: CGFloat, bottom: CGFloat)], _ a: String, _ b: String) -> CGFloat {
    l[b]!.top - l[a]!.bottom
}

print("1a. Which message is in progress")
let u = Msg(id: "u1", isAssistant: false)
let a = Msg(id: "a1", isAssistant: true, showsTyping: true)
let q1 = Msg(id: "q1", isAssistant: false, isQueued: true)
let q2 = Msg(id: "q2", isAssistant: false, isQueued: true)
check("no queued candidate: the last message", tail([u, a], .liveTail)?.id == "a1")
check("one candidate below the reply: still the reply", tail([u, a, q1], .liveTail)?.id == "a1")
check("several candidates: still the reply", tail([u, a, q1, q2], .liveTail)?.id == "a1")
check("the old rule called the candidate the message in progress", tail([u, a, q1], .literalLast)?.id == "q1")
check("nothing but candidates, or nothing at all: none",
      tail([q1, q2], .liveTail) == nil && tail([], .liveTail) == nil)
var drained = q1; drained.isQueued = false
check("once the turn takes the candidate it is an ordinary last message", tail([u, a, drained], .liveTail)?.id == "q1")
check("the reply counts as live with a candidate below it (it did not, unless a tool was running)",
      liveIds([u, a, q1], .liveTail) == ["a1"] && liveIds([u, a, q1], .literalLast).isEmpty)

print("1b. The reported screen: tool rows, \"is thinking…\", a queued candidate")
let rowsThinking = [
    Row(name: "tool1", height: 36, owner: "a1"),
    Row(name: "tool2", height: 36, owner: "a1"),
    Row(name: "thinking", height: 22, owner: "a1", footerOf: "a1"),
    Row(name: "candidate", height: 48, owner: "q1"),
]
let before = layout([u, a, q1], rowsThinking, rule: .literalLast, oldGapRule: true)
check("before: \"is thinking…\" sat right under the tool row (the report)", near(gap(before, "tool2", "thinking"), 0))
let after = layout([u, a, q1], rowsThinking, rule: .liveTail)
check("now: the normal gap between the tool row and \"is thinking…\"", near(gap(after, "tool2", "thinking"), spacing))
check("now: the normal gap between \"is thinking…\" and the candidate", near(gap(after, "thinking", "candidate"), spacing))
check("tool rows keep their own gap", near(gap(after, "tool1", "tool2"), spacing))
let noCandidate = layout([u, a], Array(rowsThinking.dropLast()), rule: .liveTail)
check("same gap above \"is thinking…\" as with no candidate at all",
      near(gap(noCandidate, "tool2", "thinking"), gap(after, "tool2", "thinking")))
let twoCandidates = layout([u, a, q1, q2], rowsThinking + [Row(name: "candidate2", height: 48, owner: "q2")], rule: .liveTail)
check("a second candidate is one gap below the first", near(gap(twoCandidates, "candidate", "candidate2"), spacing)
      && near(gap(twoCandidates, "tool2", "thinking"), spacing))

print("1c. No \"is thinking…\" row: the footer is empty")
var quiet = a; quiet.showsTyping = false
let rowsEmptyFooter = [
    Row(name: "tool2", height: 36, owner: "a1"),
    Row(name: "footer", height: 0, owner: "a1", footerOf: "a1"),
    Row(name: "candidate", height: 48, owner: "q1"),
]
let beforeEmpty = layout([u, quiet, q1], rowsEmptyFooter, rule: .literalLast, oldGapRule: true)
check("before: the candidate touched the tool row", near(gap(beforeEmpty, "tool2", "candidate"), 0))
let afterEmpty = layout([u, quiet, q1], rowsEmptyFooter, rule: .liveTail)
check("now: one normal gap, not zero and not two", near(gap(afterEmpty, "tool2", "candidate"), spacing))

print("1d. The same rule for a finished reply followed by a user bubble")
let done = Msg(id: "a1", isAssistant: true)
let next = Msg(id: "u2", isAssistant: false)
let rowsDone = [
    Row(name: "text", height: 200, owner: "a1"),
    Row(name: "footer", height: 0, owner: "a1", footerOf: "a1"),
    Row(name: "bubble", height: 48, owner: "u2"),
]
check("before: an empty footer in between left the bubble touching the reply",
      near(gap(layout([u, done, next], rowsDone, rule: .literalLast, oldGapRule: true), "text", "bubble"), 0))
check("now: one gap, the same as with no footer row at all",
      near(gap(layout([u, done, next], rowsDone, rule: .liveTail), "text", "bubble"), spacing)
      && near(gap(layout([u, done, next], [rowsDone[0], rowsDone[2]], rule: .liveTail), "text", "bubble"), spacing))
var usage = rowsDone; usage[1].height = 22
let withUsage = layout([u, done, next], usage, rule: .liveTail)
check("the usage row still hugs the text, and the bubble is one gap below it",
      near(gap(withUsage, "text", "footer"), 0) && near(gap(withUsage, "footer", "bubble"), spacing))
let tailFooter = layout([u, done], Array(rowsDone.dropLast()), rule: .liveTail, processing: false)
check("an empty footer at the very end adds nothing", near(tailFooter["#end"]!.top, 200))

print("1e. What must not change")
let emptyBlock = [
    Row(name: "a", height: 40, owner: "a1"),
    Row(name: "empty", height: 0, owner: "a1"),
    Row(name: "b", height: 40, owner: "a1"),
]
check("an empty text block between two rows still does not double their gap",
      near(gap(layout([u, done], emptyBlock, rule: .liveTail), "a", "b"), spacing))
check("the gap rule itself: last row none, hugging footer next none, a row with height one gap",
      MessageRowGap.after(height: 40, isLast: true, nextIsHuggingFooter: false, gapWithheldBefore: false, spacing: 8) == 0
      && MessageRowGap.after(height: 40, isLast: false, nextIsHuggingFooter: true, gapWithheldBefore: false, spacing: 8) == 0
      && MessageRowGap.after(height: 40, isLast: false, nextIsHuggingFooter: false, gapWithheldBefore: false, spacing: 8) == 8
      && MessageRowGap.after(height: 40, isLast: false, nextIsHuggingFooter: false, gapWithheldBefore: true, spacing: 8) == 8)
check("an empty row hands a gap on only when one was withheld for it, and never as the last row",
      MessageRowGap.after(height: 0, isLast: false, nextIsHuggingFooter: false, gapWithheldBefore: false, spacing: 8) == 0
      && MessageRowGap.after(height: 0, isLast: false, nextIsHuggingFooter: false, gapWithheldBefore: true, spacing: 8) == 8
      && MessageRowGap.after(height: 0, isLast: true, nextIsHuggingFooter: false, gapWithheldBefore: true, spacing: 8) == 0)

exit(failures == 0 ? 0 : 1)
"""#

print("1. The shipping rules against a model of the layout pass")
check("the rules source was found", rules.contains("enum LiveTail {") && rules.contains("enum MessageRowGap {"))
if failures == 0 {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QueuedCandidateSpacing-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("main.swift")
    try? ("import Foundation\n" + rules + scenario).write(to: file, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["swift", file.path]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try? p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    print(text, terminator: "")
    let passed = text.components(separatedBy: "✅").count - 1
    check("harness ran to the end (\(passed) checks) and exited 0", p.terminationStatus == 0 && passed >= 22)
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - 2. Wiring

print("\n2. Wiring in the shipping sources")
let layoutSrc = source("Agent/MessageList/MessageListLayout.swift")
let estimation = source(V3 + "Coordinator/MessageListV3Coordinator+HeightEstimation.swift")
let snapshot = source(V3 + "Coordinator/MessageListV3Coordinator+Snapshot.swift")
let bridges = source(V3 + "Coordinator/MessageListV3Coordinator+BridgeUpdates.swift")
let models = source("Agent/Chat/ChatModels.swift")
let enqueue = source("Agent/Chat/AIChatViewModel+Misc.swift")

check("premise: a queued candidate is appended to messages at once, flagged isQueued",
      enqueue.contains("let chatMsg = ChatMessage(role: .user, content: text, isQueued: true)")
      && enqueue.contains("messages.append(chatMsg)")
      && models.contains("@Published var isQueued = false"))

let prepare = block(layoutSrc, "    override func prepare() {")
check("the layout pass asks MessageRowGap for every gap and tracks the withheld one",
      prepare.contains("y += MessageRowGap.after(height: h, isLast: isLast, nextIsHuggingFooter: nextIsFooter,\n                                     gapWithheldBefore: gapWithheld, spacing: itemSpacing)")
      && prepare.contains("gapWithheld = nextIsFooter && h > 0")
      && prepare.contains("var gapWithheld = false")
      && !code(prepare).contains("y += itemSpacing"))
check("a footer in a streaming range never hugs (the second rule that keeps the gap)",
      prepare.contains("&& (footerHugByIndex[i + 1] ?? true)\n                && !isStreamingCell(i + 1)"))

let tailFn = block(estimation, "        static func liveTailMessage(in messages: [ChatMessage]) -> ChatMessage? {")
check("the list's live tail is LiveTail over isQueued",
      tailFn.contains("LiveTail.index(in: messages, isQueuedCandidate: { $0.isQueued }).map { messages[$0] }"))
let liveFn = block(estimation, "        static func liveAssistantMessageIds(messages: [ChatMessage], isProcessing: Bool) -> Set<UUID> {")
check("live message ids start from the live tail, not messages.last",
      liveFn.contains("let tail = liveTailMessage(in: messages)")
      && liveFn.contains("if let tail, tail.role == .assistant {")
      && liveFn.contains("for msg in messages where msg.role == .assistant && msg.id != tail?.id {")
      && !code(liveFn).contains("messages.last"))
check("the streaming ranges are built from those ids",
      snapshot.contains("let streamingIds = Array(Self.liveAssistantMessageIds(messages: messages,"))

// [T-interrupt-banner-gap] The policy moved to `isFooterProminent`
// (+FooterHeight), shared by the snapshot seed and updateBridge.
let footerHeight = source(V3 + "Coordinator/MessageListV3Coordinator+FooterHeight.swift")
check("the footer seed calls the live tail's typing row prominent (no hug, full gap)",
      footerHeight.contains("let isLiveTail = Self.liveTailMessage(in: messages)?.id == footerMsgId\n            let isActive = isLiveTail && vm.isProcessing\n                && (footerMsg?.shouldShowTypingIndicator ?? false)")
      && footerHeight.contains("return hasError || showsResume || isActive")
      && snapshot.contains("footerProminent = isFooterProminent(footerMsgId, footerMessage: footerMsg,")
      && snapshot.contains("layout.setFooterHug(!footerProminent, at: i)"))
check("Resume stays on the literal last message",
      footerHeight.contains("let isLastMsg = messages.last?.id == footerMsgId")
      && footerHeight.contains("let showsResume = isLastMsg && !hasError"))

let update = block(bridges, "        func updateBridge(_ bridge: CellStateBridgeV2, message: ChatMessage, in messages: [ChatMessage],")
check("the bridge's active flag and retry row follow the live tail",
      update.contains("let isLiveTail = message.id == Self.liveTailMessage(in: messages)?.id\n            let isActive = isLiveTail && vm.isProcessing")
      && update.contains("bridge.autoRetryAttempt = isLiveTail ? vm.autoRetryAttempt : 0")
      && update.contains("bridge.autoRetryCountdown = isLiveTail ? vm.autoRetryCountdown : 0")
      && update.contains("bridge.isActiveMessage = isActive"))
check("Resume and Retry on the bridge stay on the literal last message",
      update.contains("bridge.canResume = isLast ? (vm.canResume && !vm.isProcessing && !trackerActive) : false")
      && update.contains("} else if isLast {\n                    bridge.onRetry = { retryLast?() }"))
let refresh = block(bridges, "        func updateLastCellBridge() {")
check("a state change refreshes the live tail's bridge too, and no longer switches it off",
      refresh.contains("let liveTail = Self.liveTailMessage(in: messages)")
      && refresh.contains("if let liveTail, liveTail.id != lastMsg.id, let bridge = cellBridges[liveTail.id] {\n                updateBridge(bridge, message: liveTail, in: messages)")
      && refresh.contains("for msg in messages.dropLast() where msg.id != liveTail?.id {"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
