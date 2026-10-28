import XCTest
@testable import Minis

/// [T-ctx-real-user-turns] [T-ctx-pin-request] What a compaction keeps in
/// front of its summary.
///
/// Two gaps (Android 2e13ae7b6, same on iOS):
///  - `<system-reminder>` and `<agent_callback>` user messages counted as
///    "user turns" and filled the 3 warm-up slots.
///  - one round longer than the 100-message cap kept NO warm-up, so the
///    user's request survived only as the summary's paraphrase of it.
@MainActor
final class ContextSliceRulesTests: XCTestCase {

    private func user(_ text: String, _ id: String) -> AgentMessage {
        var m = AgentMessage(role: .user, parts: [.text(text)])
        m.dbMessageId = id
        return m
    }
    private func assistantText(_ text: String, _ id: String) -> AgentMessage {
        var m = AgentMessage(role: .assistant, parts: [.text(text)])
        m.dbMessageId = id
        return m
    }
    private func round(_ i: Int) -> [AgentMessage] {
        var a = AgentMessage(role: .assistant, parts: [.toolUse(id: "call_\(i)", name: "shell_execute", input: ["command": "echo \(i)"])])
        a.dbMessageId = "a\(i)"
        var r = AgentMessage(role: .user, parts: [.toolResult(id: "call_\(i)", name: "shell_execute", content: "ok \(i)", isError: false)])
        r.dbMessageId = "r\(i)"
        return [a, r]
    }
    private func text(_ m: AgentMessage) -> String {
        m.parts.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined(separator: "\n")
    }
    private func marker(anchor: String) -> CompactMarker {
        CompactMarker(id: "marker-1", sessionId: "s", summary: "SUMMARY", firstKeptSortOrder: 0, compactedCount: 0,
                      createdAt: Date(timeIntervalSince1970: 0), uiBoundarySortOrder: nil, boundaryMessageId: nil,
                      firstKeptMessageId: nil, lastCompactedMessageId: anchor, version: 2)
    }
    /// The slice the request is built from, with the real walk-back and no warm-up fit.
    private func slice(_ history: [AgentMessage], anchor: String) -> [AgentMessage] {
        var drop: [String: Int] = [:]
        let helpers = AIChatViewModel.EffectiveHistoryHelpers(
            walkBack: { AIChatViewModel.walkBackUserTurnsBounded(in: history, anchorIdx: $0, maxUserTextTurns: $1, maxMessages: $2) },
            nthFromLastUserText: { AIChatViewModel.indexOfNthFromLastUserText($0, upToIncluding: history.count - 1, in: history) },
            trimWarmUp: { warmUp, _, _ in (warmUp, true) })
        return AIChatViewModel.effectiveHistory(history, marker: marker(anchor: anchor), warmUpDrop: &drop, helpers: helpers)
    }

    // MARK: - Real user text

    func testOnlyWhatTheUserTypedIsRealUserText() {
        XCTAssertTrue(AIChatViewModel.isRealUserText(user("please finish the plan", "u")))
        XCTAssertTrue(AIChatViewModel.isRealUserText(user("继续", "u")))
        XCTAssertFalse(AIChatViewModel.isRealUserText(user("<system-reminder>SOUL.md still applies</system-reminder>", "u")))
        XCTAssertFalse(AIChatViewModel.isRealUserText(user("\n  <system-reminder>x</system-reminder>", "u")),
                       "leading whitespace does not hide the tag")
        XCTAssertFalse(AIChatViewModel.isRealUserText(user("<agent_callback job=\"1\">done</agent_callback>", "u")))
        XCTAssertFalse(AIChatViewModel.isRealUserText(user("", "u")))
        XCTAssertFalse(AIChatViewModel.isRealUserText(user("   \n", "u")))
        XCTAssertFalse(AIChatViewModel.isRealUserText(round(0)[1]), "a tool result carrier")
        XCTAssertFalse(AIChatViewModel.isRealUserText(assistantText("hello", "a")))
    }

    func testAMessageThatQuotesATagLaterIsStillReal() {
        XCTAssertTrue(AIChatViewModel.isRealUserText(user("what does <system-reminder> mean?", "u")))
    }

    func testTextNextToAReminderPartStillCounts() {
        var m = AgentMessage(role: .user, parts: [.text("<system-reminder>note</system-reminder>"), .text("and do this too")])
        m.dbMessageId = "u"
        XCTAssertTrue(AIChatViewModel.isRealUserText(m))
    }

    // MARK: - Warm-up slots

    func testRemindersAndCallbacksDoNotEatTheWarmUpSlots() {
        // Three real requests, then three app-written user messages, then the anchor.
        var history: [AgentMessage] = [user("old question", "u0"), assistantText("old answer", "x0")]
        for i in 1...3 { history += [user("request \(i)", "u\(i)"), assistantText("answer \(i)", "x\(i)")] }
        history += [user("<system-reminder>persona</system-reminder>", "n1"), assistantText("noted", "y1"),
                    user("<agent_callback job=\"7\">result</agent_callback>", "n2"), assistantText("got it", "y2"),
                    user("<system-reminder>again</system-reminder>", "n3"), assistantText("anchor", "y3")]
        let anchorIdx = history.count - 1
        let walk = AIChatViewModel.walkBackUserTurnsBounded(in: history, anchorIdx: anchorIdx, maxUserTextTurns: 3, maxMessages: 100)
        XCTAssertEqual(walk.stopReason, "userTextTargetMet")
        XCTAssertEqual(walk.userTextTurnsFound, 3)
        XCTAssertEqual(walk.priorIdx.map { history[$0].dbMessageId }, "u1", "the three REAL requests are kept")

        let sent = slice(history + [user("new question", "u9")], anchor: "y3")
        XCTAssertEqual(sent.first?.dbMessageId, "u1")
        XCTAssertFalse(sent.contains { $0.dbMessageId == "u0" })
        XCTAssertTrue(text(sent.last!).contains("SUMMARY") && text(sent.last!).contains("new question"))
    }

    func testNthFromLastUserTextSkipsAppWrittenMessages() {
        let history = [user("first", "u1"), assistantText("a", "x1"), user("second", "u2"), assistantText("b", "x2"),
                       user("<system-reminder>r</system-reminder>", "n1"), user("<agent_callback>c</agent_callback>", "n2")]
        XCTAssertEqual(AIChatViewModel.indexOfNthFromLastUserText(1, upToIncluding: 5, in: history), 2)
        XCTAssertEqual(AIChatViewModel.indexOfNthFromLastUserText(2, upToIncluding: 5, in: history), 0)
        XCTAssertNil(AIChatViewModel.indexOfNthFromLastUserText(3, upToIncluding: 5, in: history))
    }

    // MARK: - Pinned request

    func testARoundOverTheCapKeepsTheUsersRequestVerbatim() {
        // One "continue" driving 60 tool rounds = 121 messages before the anchor.
        var history: [AgentMessage] = [user("earlier topic", "u0"), assistantText("earlier answer", "x0"),
                                       user("请把计划表写完", "u1")]
        for i in 0..<60 { history += round(i) }
        let anchor = "r59"
        let anchorIdx = history.count - 1
        let walk = AIChatViewModel.walkBackUserTurnsBounded(in: history, anchorIdx: anchorIdx, maxUserTextTurns: 3, maxMessages: 100)
        XCTAssertNil(walk.priorIdx, "the walk-back alone keeps nothing")
        XCTAssertEqual(walk.stopReason, "messageCapWouldExceed")

        let sent = slice(history + round(60), anchor: anchor)
        XCTAssertEqual(sent.first?.dbMessageId, "u1")
        XCTAssertEqual(text(sent[0]), "请把计划表写完", "verbatim, not a paraphrase")
        XCTAssertEqual(sent.map(\.dbMessageId), ["u1", "a60", "r60"], "request + the round after the anchor")
        XCTAssertTrue(text(sent[2]).contains("SUMMARY"), "the summary rides on the first user message after the anchor")
        XCTAssertFalse(sent.contains { $0.dbMessageId == "a0" }, "the compacted rounds are not sent")
    }

    func testThePinnedRequestIsTheLastRealOneNotAReminderInsideTheRound() {
        var history: [AgentMessage] = [user("real request", "u1")]
        for i in 0..<30 { history += round(i) }
        history.append(user("<system-reminder>persona</system-reminder>", "n1"))
        for i in 30..<85 { history += round(i) }
        let sent = slice(history + round(90), anchor: "r84")
        XCTAssertEqual(sent.first?.dbMessageId, "u1")
        XCTAssertEqual(AIChatViewModel.lastRealUserTextIndex(in: history, upToIncluding: history.count - 1), 0)
    }

    func testARoundUnderTheCapIsUnchanged() {
        var history: [AgentMessage] = [user("the request", "u1")]
        for i in 0..<20 { history += round(i) }
        let sent = slice(history + round(20), anchor: "r19")
        XCTAssertEqual(sent.first?.dbMessageId, "u1")
        XCTAssertTrue(sent.contains { $0.dbMessageId == "a0" }, "the whole round is still the warm-up")
        XCTAssertEqual(sent.filter { $0.dbMessageId?.hasPrefix("a") == true }.count, 21)
    }

    func testNoRealRequestBeforeTheAnchorKeepsNothingAsBefore() {
        var history: [AgentMessage] = [user("<system-reminder>only a note</system-reminder>", "n0")]
        for i in 0..<60 { history += round(i) }
        XCTAssertNil(AIChatViewModel.lastRealUserTextIndex(in: history, upToIncluding: history.count - 1))
        let sent = slice(history + round(60), anchor: "r59")
        XCTAssertEqual(sent.first?.dbMessageId, "a60")
    }

    func testEveryCallInTheSliceStillHasItsResult() {
        var history: [AgentMessage] = [user("the request", "u1")]
        for i in 0..<70 { history += round(i) }
        let sent = slice(history + round(70) + round(71), anchor: "r69")
        var useIds = Set<String>(), resultIds = Set<String>()
        for p in sent.flatMap(\.parts) {
            if case .toolUse(let id, _, _, _) = p { useIds.insert(id) }
            if case .toolResult(let id, _, _, _, _, _, _, _, _) = p { resultIds.insert(id) }
        }
        XCTAssertEqual(useIds, resultIds)
        XCTAssertEqual(useIds, ["call_70", "call_71"])
    }
}
