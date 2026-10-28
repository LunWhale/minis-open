import XCTest
@testable import Minis

/// [T-ctx-trim-collapse-first] Collapse before paying for a summary that
/// would free almost nothing, and never undo a collapse on the next re-plan.
/// Port of Android f9cb31a87 (ContextTrimWiringTest).
///
/// Android replay 2026-10-07: two in-loop compactions cost a model call each
/// and took the history only 244K -> 226K, because inside one long user turn
/// the turn itself is the slice a compaction keeps; and an after-compact plan
/// that had collapsed 26 iterations was rebuilt without collapse by the next
/// in-loop re-plan, 72K -> 92K.
@MainActor
final class ContextCollapseFirstTests: XCTestCase {

    private typealias P = ContextTrimPlanner

    private func user(_ text: String, _ id: String?) -> AgentMessage {
        var m = AgentMessage(role: .user, parts: [.text(text)])
        m.dbMessageId = id
        return m
    }
    private func answer(_ n: Int, _ id: String) -> AgentMessage {
        var m = AgentMessage(role: .assistant, parts: [.text(String(repeating: "答", count: n))])
        m.dbMessageId = id
        return m
    }
    /// One tool round; `result` CJK characters of output (1 token each).
    private func round(_ i: Int, result: Int, tag: String = "") -> [AgentMessage] {
        let id = "call_\(tag)\(i)"
        var a = AgentMessage(role: .assistant, parts: [.toolUse(id: id, name: "shell_execute", input: ["command": "echo \(i)"])])
        a.dbMessageId = "a\(tag)\(i)"
        var r = AgentMessage(role: .user, parts: [.toolResult(id: id, name: "shell_execute",
                                                             content: String(repeating: "结", count: result), isError: false)])
        r.dbMessageId = "r\(tag)\(i)"
        return [a, r]
    }
    private func gain(_ history: [AgentMessage], marker: CompactMarker? = nil) -> Int? {
        AIChatViewModel.simulatedSummaryGain(history: history, current: marker, warmUpDrop: [:],
                                             summaryTokens: P.simulatedSummaryTokens)
    }

    // MARK: - Simulated compaction

    /// One "continue" driving 40 tool rounds: the turn is the kept slice.
    func testInsideOneLongTurnASummaryFreesLessThanItsOwnSize() throws {
        var history = [user("请把计划表写完", "u0")]
        for i in 0..<40 { history += round(i, result: 900) }
        let g = try XCTUnwrap(gain(history))
        XCTAssertLessThan(g, P.simulatedSummaryTokens, "nothing but the summary's own cost changes: gain \(g)")
        let measured = ContextSizeMeter.estimateTokens(history)
        XCTAssertTrue(P.summaryFreesLittle(gain: g, measured: measured, target: measured / 2))
    }

    /// Several older turns with large answers: the summary really replaces them.
    func testOlderTurnsWithLargeOutputsSimulateALargeGain() throws {
        var history: [AgentMessage] = []
        for t in 0..<8 {
            history += [user("question \(t)", "u\(t)"), answer(6_000, "x\(t)")]
        }
        history += [user("继续", "u9")] + round(0, result: 200)
        let g = try XCTUnwrap(gain(history))
        XCTAssertGreaterThan(g, 20_000, "five 6K answers fall behind the summary: gain \(g)")
        let measured = ContextSizeMeter.estimateTokens(history)
        XCTAssertFalse(P.summaryFreesLittle(gain: g, measured: measured, target: measured / 2))
    }

    func testARoundOverTheCapKeepsOnlyTheRequestSoTheGainIsLarge() throws {
        // 121 messages in one round: the real compaction would keep the request only.
        var history = [user("请把计划表写完", "u0")]
        for i in 0..<60 { history += round(i, result: 900) }
        let g = try XCTUnwrap(gain(history))
        XCTAssertGreaterThan(g, 40_000)
    }

    func testWithoutAnAnchorIdNothingIsSimulated() {
        var history = [user("请把计划表写完", "u0")] + round(0, result: 900)
        history[history.count - 1].dbMessageId = nil   // newest message not persisted yet
        XCTAssertNil(gain(history))
        XCTAssertNil(gain([]))
    }

    func testTheSimulationDoesNotTouchTheHistoryOrTheWarmUpCache() throws {
        var history = [user("请把计划表写完", "u0")]
        for i in 0..<10 { history += round(i, result: 500) }
        let before = history.map { "\($0.dbMessageId ?? "-")|\($0.parts.count)" }
        _ = try XCTUnwrap(gain(history))
        XCTAssertEqual(history.map { "\($0.dbMessageId ?? "-")|\($0.parts.count)" }, before)
    }

    func testReasoningIsLeftOutOnBothSides() throws {
        var history = [user("请把计划表写完", "u0")]
        for i in 0..<10 { history += round(i, result: 500) }
        let plain = try XCTUnwrap(gain(history))
        for i in history.indices where history[i].role == .assistant {
            history[i].reasoningContent = String(repeating: "想", count: 5_000)
        }
        XCTAssertEqual(gain(history), plain, "the ladder handles reasoning either way")
    }

    // MARK: - The decision

    func testASummaryIsWorthItOnlyWhenItFreesAtLeastHalfOfWhatIsNeeded() {
        XCTAssertTrue(P.summaryFreesLittle(gain: 18_000, measured: 226_000, target: 66_000), "the field case")
        XCTAssertTrue(P.summaryFreesLittle(gain: -2_000, measured: 110_000, target: 64_000), "a summary that costs more than it frees")
        XCTAssertFalse(P.summaryFreesLittle(gain: 30_000, measured: 110_000, target: 64_000))
        XCTAssertFalse(P.summaryFreesLittle(gain: 23_000, measured: 110_000, target: 64_000), "exactly half is enough")
        XCTAssertEqual(P.simulatedSummaryTokens, 3_000)
    }

    // MARK: - A plan belongs to one window

    func testAPlanMadeForAnotherWindowDoesNotFit() {
        XCTAssertTrue(P.planFitsWindow(planWindow: 128_000, window: 128_000))
        XCTAssertFalse(P.planFitsWindow(planWindow: 128_000, window: 1_000_000), "the cap was removed: the trim must go")
        XCTAssertFalse(P.planFitsWindow(planWindow: 1_000_000, window: 128_000), "a cap was added: plan afresh")
        XCTAssertFalse(P.planFitsWindow(planWindow: nil, window: 128_000))
    }

    /// The on-device case in numbers: what a 128K plan leaves is far below
    /// anything a 1M window would trim to.
    func testUnderALargerWindowTheSameHistoryNeedsNoTrim() {
        let small = P.watermarks(window: 128_000, fixed: 18_049, maxOutput: 128_000)!
        let large = P.watermarks(window: 1_000_000, fixed: 18_049, maxOutput: 128_000)!
        let untrimmed = 278_193
        XCTAssertGreaterThan(untrimmed, small.trigger)
        XCTAssertLessThan(untrimmed, large.target, "278K fits a 1M window with room to spare")
    }

    // MARK: - Escalation

    func testAPlanThatRecoversLessThanHalfTheRoomEscalates() {
        // The on-device case: re-plan at 100,967 came back to 83,919; target 63,279, trigger 99,695.
        XCTAssertTrue(P.shouldEscalate(after: 83_919, target: 63_279, trigger: 99_695))
        // The first run's second plan missed the target by 2.9K only: no escalation.
        XCTAssertFalse(P.shouldEscalate(after: 67_462, target: 64_580, trigger: 99_877))
        XCTAssertFalse(P.shouldEscalate(after: 63_000, target: 63_279, trigger: 99_695), "target reached")
        XCTAssertFalse(P.shouldEscalate(after: 81_487, target: 63_279, trigger: 99_695), "exactly the midpoint")
        XCTAssertTrue(P.shouldEscalate(after: 81_488, target: 63_279, trigger: 99_695))
    }

    // MARK: - Sticky collapse

    func testOnceAllowedCollapseStaysAllowedForThatSessionAndMarker() {
        let unlock = P.CollapseUnlock(sessionId: "s1", markerId: "m1")
        XCTAssertTrue(P.collapseAllowed(requested: false, tight: false, unlock: unlock, sessionId: "s1", markerId: "m1"),
                      "the plain in-loop re-plan must not expand what was collapsed")
        XCTAssertFalse(P.collapseAllowed(requested: false, tight: false, unlock: nil, sessionId: "s1", markerId: "m1"))
        XCTAssertTrue(P.collapseAllowed(requested: true, tight: false, unlock: nil, sessionId: "s1", markerId: nil))
        XCTAssertTrue(P.collapseAllowed(requested: false, tight: true, unlock: nil, sessionId: "s1", markerId: nil))
    }

    func testTheUnlockDoesNotCarryToAnotherSessionOrMarker() {
        let unlock = P.CollapseUnlock(sessionId: "s1", markerId: "m1")
        XCTAssertFalse(P.collapseAllowed(requested: false, tight: false, unlock: unlock, sessionId: "s2", markerId: "m1"))
        XCTAssertFalse(P.collapseAllowed(requested: false, tight: false, unlock: unlock, sessionId: "s1", markerId: "m2"))
        XCTAssertFalse(P.collapseAllowed(requested: false, tight: false, unlock: unlock, sessionId: "s1", markerId: nil))
        let noMarker = P.CollapseUnlock(sessionId: "s1", markerId: nil)
        XCTAssertTrue(P.collapseAllowed(requested: false, tight: false, unlock: noMarker, sessionId: "s1", markerId: nil))
    }
}
